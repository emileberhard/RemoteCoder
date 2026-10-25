use super::{ClientTx, Gateway, UPSTREAM_SEND_TIMEOUT_SECONDS, claude_effort_wire_value};
use crate::observability::journal::Source;
use crate::observability::voice::VoiceLog;
use crate::rpc::error::{RpcCode, RpcData};
use crate::rpc::{RpcError, RpcResult};
use crate::time::unix_seconds;
use crate::voice::farewell::FarewellWatch;
use crate::voice::handoff::VoiceDelegations;
use crate::voice::session::{
    Hangup, StopRequest, VoiceCallEnded, VoiceSession, VoiceSessionOrigin, voice_mode_greeting,
    voice_mode_prompt,
};
use crate::voice::shadows::VOICE_SHADOW_REPLENISH_DELAY_SECONDS;
use crate::wire::gateway::{
    EmptyResponse, RealtimeVoiceConnectedRequest, RealtimeVoiceStartRequest,
    RealtimeVoiceStartResponse, RealtimeVoiceStatusResponse, normalize_realtime_voices,
};
use anyhow::{Context, Result, anyhow, ensure};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tracing::{debug, info, warn};

impl Gateway {
    async fn create_voice_shadow_thread(&self, cwd: &str) -> Result<String> {
        let response = self
            .call_control(
                "thread/start",
                serde_json::json!({
                    "cwd": cwd,
                    "ephemeral": true,
                    "approvalPolicy": "never",
                    "sandbox": "danger-full-access",
                    "serviceName": "RemoteCoder Voice",
                    // Claude executes every delegated task. This Codex thread is
                    // only the fresh app-server/WebRTC protocol anchor, so none
                    // of the normal agent tool initialization belongs here.
                    "config": {
                        "features.shell_snapshot": false,
                        "mcp_servers": {},
                        "hooks": {},
                    },
                }),
            )
            .await?;
        response
            .get("thread")
            .and_then(|thread| thread.get("id"))
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| anyhow!("Codex did not return the voice shadow thread id"))
    }

    pub(super) fn spawn_default_voice_shadow_prewarm(self: &Arc<Self>) {
        let Ok(paths) = crate::config::HostPaths::from_env() else {
            warn!("cannot prewarm a voice shadow thread because HOME is unset");
            return;
        };
        self.spawn_voice_shadow_replenish(paths.home().display().to_string(), Duration::ZERO);
    }

    fn spawn_voice_shadow_replenish(self: &Arc<Self>, cwd: String, delay: Duration) {
        let gateway = Arc::clone(self);
        self.voice_tasks
            .spawn("voice shadow replenish", async move {
                if !delay.is_zero() {
                    tokio::time::sleep(delay).await;
                }
                let Some(reservation) = gateway.voice.shadows.reserve(&cwd) else {
                    return Ok(());
                };

                let started_at = Instant::now();
                match gateway.create_voice_shadow_thread(&cwd).await {
                    Ok(thread_id) => {
                        let unused = gateway.voice.shadows.offer(reservation, thread_id.clone());
                        if unused.contains(&thread_id) {
                            debug!(cwd, thread_id, "discarding prewarmed voice shadow thread");
                        } else {
                            info!(
                                cwd,
                                thread_id,
                                elapsed_ms = started_at.elapsed().as_millis(),
                                "prewarmed voice shadow thread ready"
                            );
                        }
                        gateway.delete_unused_voice_shadow_threads(unused).await;
                    }
                    Err(error) => {
                        gateway.voice.shadows.release(reservation);
                        warn!(cwd, %error, "voice shadow thread prewarm failed");
                    }
                }
                Ok(())
            });
    }

    pub(super) fn spawn_stale_voice_shadow_cleanup(self: &Arc<Self>) {
        let stale = self.voice.shadows.take_stale();
        if stale.is_empty() {
            return;
        }
        let gateway = Arc::clone(self);
        self.voice_tasks
            .spawn("stale voice shadow cleanup", async move {
                gateway.delete_unused_voice_shadow_threads(stale).await;
                Ok(())
            });
    }

    pub(super) async fn handle_voice_rpc(
        self: &Arc<Self>,
        client_id: u64,
        out_tx: &ClientTx,
        method: &str,
        obj: &serde_json::Map<String, Value>,
    ) -> Result<()> {
        let req_id = obj.get("id").cloned().unwrap_or(Value::Null);
        let params = obj.get("params").cloned().unwrap_or(Value::Null);
        let response = self.voice_rpc(client_id, method, params).await;
        self.respond(out_tx, req_id, response, None)
            .await
            .map(|_| ())
    }

    async fn voice_rpc(self: &Arc<Self>, client_id: u64, method: &str, params: Value) -> RpcResult {
        match method {
            "voice/session/start" => {
                let request = serde_json::from_value::<RealtimeVoiceStartRequest>(params)
                    .map_err(anyhow::Error::from)
                    .and_then(RealtimeVoiceStartRequest::validate)
                    .map_err(|error| {
                        RpcError::new(
                            RpcCode::InvalidParams,
                            format!("invalid voice/session/start params: {error}"),
                        )
                    })?;
                let response = self
                    .start_voice_session(client_id, request, VoiceSessionOrigin::VoiceMode)
                    .await
                    .map_err(|error| {
                        if error.is::<VoiceCallEnded>() {
                            RpcError::new(RpcCode::CallEnded, error.to_string())
                                .with_data(RpcData::VoiceCallEnded)
                        } else {
                            error.into()
                        }
                    })?;
                Ok(serde_json::to_value(response).map_err(anyhow::Error::from)?)
            }
            "voice/session/connected" => {
                let request = serde_json::from_value::<RealtimeVoiceConnectedRequest>(params)
                    .map_err(|error| {
                        RpcError::new(
                            RpcCode::InvalidParams,
                            format!("invalid voice/session/connected params: {error}"),
                        )
                    })?;
                let response = self
                    .greet_voice_session(client_id, &request.realtime_session_id)
                    .await?;
                Ok(serde_json::to_value(response).map_err(anyhow::Error::from)?)
            }
            "voice/session/stop" => {
                let response = self.stop_voice_session(client_id).await?;
                Ok(serde_json::to_value(response).map_err(anyhow::Error::from)?)
            }
            "voice/session/status" => {
                let owner = self.voice.owner();
                Ok(serde_json::to_value(RealtimeVoiceStatusResponse {
                    active: owner.is_some(),
                    owned_by_current_client: owner
                        .as_ref()
                        .is_some_and(|owner| owner.client_id == client_id),
                })
                .map_err(anyhow::Error::from)?)
            }
            "voice/listVoices" => {
                info!("voice catalog requested");
                let catalog = self
                    .call_control("thread/realtime/listVoices", serde_json::json!({}))
                    .await
                    .and_then(normalize_realtime_voices)?;
                Ok(serde_json::to_value(catalog).map_err(anyhow::Error::from)?)
            }
            _ => Err(RpcError::new(
                RpcCode::MethodNotFound,
                format!("unsupported voice method: {method}"),
            )),
        }
    }

    pub(super) async fn start_voice_session(
        self: &Arc<Self>,
        client_id: u64,
        request: RealtimeVoiceStartRequest,
        origin: VoiceSessionOrigin,
    ) -> Result<RealtimeVoiceStartResponse> {
        let voice_start_started_at = Instant::now();
        let transition = self.voice.transition().await;
        self.check_voice_account().await?;
        self.admit_voice_start(client_id, &request).await?;
        let RealtimeVoiceStartRequest {
            conversation_thread_id,
            realtime_session_id,
            replace_existing_session,
            cwd,
            mut model,
            effort,
            sdp,
            voice,
            initial_items,
        } = request;
        let mut effort = effort.as_deref().map(claude_effort_wire_value);
        let uses_external_executor =
            crate::providers::claude::is_claude_thread_id(&conversation_thread_id);
        if uses_external_executor && !self.claude_settings.enabled {
            return Err(anyhow!("Claude provider is disabled on this host"));
        }

        let admission = match origin {
            VoiceSessionOrigin::VoiceMode => self.voice.begin_start(
                &transition,
                client_id,
                &realtime_session_id,
                replace_existing_session,
            )?,
            VoiceSessionOrigin::AgentCall => {
                self.voice
                    .begin_agent_call_start(&transition, client_id, &realtime_session_id)?
            }
        };
        if let Some(previous) = admission.preempted {
            info!(
                previous_client_id = previous.client_id,
                client_id,
                user_initiated = replace_existing_session,
                "realtime voice transport replaced"
            );
            if let Some(previous_tx) = self
                .clients
                .get(&previous.client_id)
                .map(|entry| entry.value().clone())
            {
                let _ = self.send_json_or_drop(
                    &previous_tx,
                    &serde_json::json!({
                        "method": "voice/session/preempted",
                        "params": {
                            "realtimeSessionId": previous.realtime_session_id,
                        }
                    }),
                );
            }
        }

        // A reconnect from the owning client replaces only its old realtime
        // transport. Any delegated agent turn keeps running in the normal chat.
        // The session was taken out before awaiting the stop so no lock is
        // held across the upstream round-trip.
        if let Some(previous) = admission.previous_session {
            previous.close_log("replaced");
        }
        if let Some(previous_thread_id) = admission.previous_realtime_thread_id {
            self.call_control(
                "thread/realtime/stop",
                serde_json::json!({ "threadId": previous_thread_id }),
            )
            .await?;
        }

        if let Some(predecessor_closed) = admission.predecessor_closed {
            tokio::time::timeout(
                Duration::from_secs_f64(UPSTREAM_SEND_TIMEOUT_SECONDS),
                predecessor_closed,
            )
            .await
            .context("previous voice transport did not close before startup timed out")?
            .context("voice start ended before the previous transport closed")?;
        }

        info!(
            provider = if uses_external_executor {
                "claude"
            } else {
                "codex"
            },
            model,
            voice = voice.as_deref().unwrap_or("default"),
            initial_item_count = initial_items.len(),
            "realtime voice session start requested"
        );
        if uses_external_executor && let Some(agent) = self.claude_agent() {
            match agent
                .runtime_settings_for_command(&conversation_thread_id)
                .await
            {
                Ok(Some(selection)) => (model, effort) = (selection.model, selection.effort),
                Ok(None) => {}
                Err(error) => {
                    self.clear_voice_session_or_drop(client_id, None).await;
                    return Err(anyhow!(error));
                }
            }
        }

        let shadow_thread_started_at = Instant::now();
        let mut used_prewarmed_shadow = false;
        let realtime_thread_id = if uses_external_executor {
            let ready_shadow = self.voice.shadows.take(&cwd);
            let thread_id = if let Some(thread_id) = ready_shadow {
                used_prewarmed_shadow = true;
                thread_id
            } else {
                match self.create_voice_shadow_thread(&cwd).await {
                    Ok(thread_id) => thread_id,
                    Err(error) => {
                        self.clear_voice_session_or_drop(client_id, None).await;
                        return Err(error);
                    }
                }
            };
            if !self.voice_start_is_owned_by_connected_client(client_id, &realtime_session_id) {
                self.delete_unused_voice_shadow_thread(&thread_id).await;
                return Err(anyhow!("voice client disconnected during session startup"));
            }
            thread_id
        } else {
            conversation_thread_id.clone()
        };
        info!(
            elapsed_ms = shadow_thread_started_at.elapsed().as_millis(),
            uses_external_executor,
            used_prewarmed_shadow,
            "realtime voice thread preparation completed"
        );
        if uses_external_executor {
            self.spawn_voice_shadow_replenish(
                cwd.clone(),
                Duration::from_secs(VOICE_SHADOW_REPLENISH_DELAY_SECONDS),
            );
        }

        let mut delegations = VoiceDelegations::new();
        if uses_external_executor {
            let agent = self.claude_agent();
            if let Some(agent) = agent
                && let Some(turn_id) = agent.active_turn_id(&conversation_thread_id).await
            {
                delegations.observe_turn(&turn_id, unix_seconds());
            }
        }
        let log = VoiceLog::open(&realtime_thread_id);
        let session = VoiceSession {
            owner_client_id: client_id,
            realtime_session_id: realtime_session_id.clone(),
            realtime_thread_id: realtime_thread_id.clone(),
            conversation_thread_id,
            model,
            effort,
            cwd,
            uses_external_executor,
            delegations,
            tail_flush_dispatched: false,
            greeted: false,
            farewell: (origin == VoiceSessionOrigin::VoiceMode)
                .then(|| FarewellWatch::for_user(self.user_name.as_deref())),
            started_at_unix_seconds: unix_seconds(),
            log,
        };
        let voice_name = voice.as_deref().unwrap_or("default").to_string();
        let initial_item_count = initial_items.len();
        if uses_external_executor {
            session.log_start(&voice_name, initial_item_count);
        }
        if !self.voice.install(&transition, session) {
            if uses_external_executor {
                self.delete_unused_voice_shadow_thread(&realtime_thread_id)
                    .await;
            }
            return Err(anyhow!("voice client disconnected during session startup"));
        }
        if uses_external_executor {
            self.spawn_voice_watchdog(realtime_thread_id.clone());
        }

        let mut realtime_params = serde_json::json!({
            "threadId": realtime_thread_id,
            "realtimeSessionId": realtime_session_id,
            "flushTranscriptTailOnSessionEnd": true,
            "outputModality": "audio",
            // Match the Codex desktop client. Startup-context generation can wait on
            // thread services that are still initializing for a provisional voice
            // thread, delaying hosted call creation indefinitely.
            "includeStartupContext": false,
            "transport": { "type": "webrtc", "sdp": sdp },
            "version": "v3",
            "model": "gpt-live-1-codex",
        });
        if !initial_items.is_empty() {
            realtime_params["initialItems"] = serde_json::to_value(&initial_items)?;
        }
        if uses_external_executor {
            realtime_params["handoffOwner"] = Value::String("client".to_string());
        } else {
            realtime_params["codexResponseHandoffMode"] = Value::String("bemTags".to_string());
        }
        if let Some(voice) = voice {
            realtime_params["voice"] = Value::String(voice);
        }
        if origin == VoiceSessionOrigin::VoiceMode {
            realtime_params["prompt"] = Value::String(voice_mode_prompt(self.user_name.as_deref()));
        }

        let upstream_realtime_started_at = Instant::now();
        if let Err(err) = self
            .call_control("thread/realtime/start", realtime_params)
            .await
        {
            self.clear_voice_session_or_drop(client_id, Some(&realtime_thread_id))
                .await;
            if uses_external_executor {
                self.delete_unused_voice_shadow_thread(&realtime_thread_id)
                    .await;
            }
            return Err(err);
        }
        info!(
            elapsed_ms = upstream_realtime_started_at.elapsed().as_millis(),
            total_elapsed_ms = voice_start_started_at.elapsed().as_millis(),
            "upstream realtime voice start completed"
        );

        let confirmed_settings = if uses_external_executor {
            Ok(None)
        } else {
            self.read_codex_voice_settings(&realtime_thread_id)
                .await
                .map(Some)
        }
        .and_then(|settings| {
            ensure!(
                self.voice_start_is_owned_by_connected_client(client_id, &realtime_session_id),
                "voice client disconnected during session startup"
            );
            Ok(settings)
        });
        let confirmed_settings = match confirmed_settings {
            Ok(settings) => settings,
            Err(error) => {
                let _ = self
                    .call_control(
                        "thread/realtime/stop",
                        serde_json::json!({ "threadId": realtime_thread_id }),
                    )
                    .await;
                self.clear_voice_session_or_drop(client_id, Some(&realtime_thread_id))
                    .await;
                if uses_external_executor {
                    self.delete_unused_voice_shadow_thread(&realtime_thread_id)
                        .await;
                }
                return Err(error);
            }
        };

        let voice_log_path = self.voice.log_path(&realtime_session_id);
        info!(
            realtime_thread_id,
            provider = if uses_external_executor {
                "claude"
            } else {
                "codex"
            },
            voice_log = voice_log_path.as_deref().unwrap_or("disabled"),
            "realtime voice session start accepted"
        );

        let settings = self
            .voice
            .with_live_owned(client_id, &realtime_session_id, |session| {
                if let Some((model, effort)) = confirmed_settings {
                    session.model = model;
                    session.effort = effort;
                    session.log_start(&voice_name, initial_item_count);
                }
                (session.model.clone(), session.effort.clone())
            })
            .context("voice session ended during startup")?;
        Ok(RealtimeVoiceStartResponse {
            realtime_thread_id,
            model: settings.0,
            effort: settings.1,
        })
    }

    async fn read_codex_voice_settings(&self, thread_id: &str) -> Result<(String, Option<String>)> {
        let response = self
            .call_control(
                "thread/read",
                json!({ "threadId": thread_id, "includeTurns": false }),
            )
            .await?;
        let model = response["thread"]["model"]
            .as_str()
            .context("Codex returned no configured model for the voice conversation")?
            .to_string();
        let effort = response["thread"]["reasoningEffort"]
            .as_str()
            .map(str::to_string);
        Ok((model, effort))
    }

    pub(super) async fn delete_unused_voice_shadow_threads(&self, thread_ids: Vec<String>) {
        for thread_id in thread_ids {
            self.delete_unused_voice_shadow_thread(&thread_id).await;
        }
    }

    async fn delete_unused_voice_shadow_thread(&self, thread_id: &str) {
        if let Err(error) = self
            .call_control(
                "thread/delete",
                serde_json::json!({ "threadId": thread_id }),
            )
            .await
        {
            warn!(%error, "failed to delete unused voice shadow thread");
        }
    }

    fn voice_start_is_owned_by_connected_client(
        &self,
        client_id: u64,
        realtime_session_id: &str,
    ) -> bool {
        self.clients.contains_key(&client_id)
            && self.voice.owns_start(client_id, realtime_session_id)
    }

    pub(super) async fn greet_voice_session(
        &self,
        client_id: u64,
        realtime_session_id: &str,
    ) -> Result<EmptyResponse> {
        let greeting = self
            .voice
            .with_live_owned(client_id, realtime_session_id, |voice| {
                if voice.greeted {
                    return None;
                }
                voice.greeted = true;
                voice.log_event("session/greeting", serde_json::json!({}));
                Some(voice.realtime_thread_id.clone())
            })
            .context("voice session is no longer active")?;
        let Some(realtime_thread_id) = greeting else {
            return Ok(EmptyResponse {});
        };
        self.call_control(
            "thread/realtime/appendSpeech",
            serde_json::json!({ "threadId": realtime_thread_id, "text": voice_mode_greeting(self.user_name.as_deref()) }),
        )
        .await?;
        Ok(EmptyResponse {})
    }

    pub(super) async fn stop_voice_session(
        self: &Arc<Self>,
        client_id: u64,
    ) -> Result<EmptyResponse> {
        let transition = self.voice.transition().await;
        let (owner, realtime_thread_id) = match self.voice.begin_stop(&transition, client_id) {
            StopRequest::Ignored {
                owner_client_id: Some(owner_client_id),
            } => {
                info!(
                    client_id,
                    owner_client_id, "ignoring voice stop from a superseded transport"
                );
                return Ok(EmptyResponse {});
            }
            StopRequest::Ignored {
                owner_client_id: None,
            } => return Ok(EmptyResponse {}),
            StopRequest::Released {
                owner,
                realtime_thread_id,
            } => (owner, realtime_thread_id),
        };
        let recorded = self
            .record_call_transport_end(&owner, "media owner disconnected or stopped")
            .await;
        if let Ok(Some(record)) = &recorded {
            self.publish_call_state_or_drop(record);
        }
        let drained = self
            .stop_draining_voice_session(realtime_thread_id, "requested")
            .await;
        // Losing the durable receipt must never prevent media cleanup.
        drained?;
        recorded?;
        Ok(EmptyResponse {})
    }

    /// Ends the active call on the agent's behalf (the `end_voice_call` tool).
    ///
    /// The caller identity comes from the runtime, not the tool arguments.
    pub(crate) async fn end_voice_call_for_agent(
        self: &Arc<Self>,
        caller: &crate::agents::tools::Caller,
    ) -> bool {
        let Some(thread_id) = caller.thread_id.as_deref() else {
            return false;
        };
        // Serialize authorization and stopping with replacement: an old
        // call's authorized hang-up must never drain its successor.
        let transition = self.voice.transition().await;
        // Agent-initiated calls require the explicit call ID. A delayed no-arg
        // hangup from an earlier call on this same thread must not end its successor.
        if self.calls.active().await.is_some() {
            return false;
        }
        let Some(hangup) = self.voice.begin_agent_hangup(
            &transition,
            thread_id,
            matches!(caller.provider, crate::providers::Provider::Claude),
        ) else {
            return false;
        };
        self.finish_hangup(hangup, "agent tool").await
    }

    pub(super) fn spawn_farewell_close(self: &Arc<Self>, realtime_thread_id: String) {
        let gateway = Arc::clone(self);
        self.voice_tasks.spawn("voice farewell", async move {
            while let Some(close_at) = gateway
                .voice
                .with_live_realtime_thread(&realtime_thread_id, |session| {
                    session.farewell.as_ref().and_then(FarewellWatch::close_at)
                })
                .flatten()
            {
                if tokio::time::Instant::now() < close_at {
                    tokio::time::sleep_until(close_at).await;
                    continue;
                }
                let transition = gateway.voice.transition().await;
                if let Some(hangup) = gateway.voice.begin_farewell_hangup(
                    &transition,
                    &realtime_thread_id,
                    tokio::time::Instant::now(),
                ) {
                    gateway.finish_hangup(hangup, "farewell").await;
                    break;
                }
            }
            Ok(())
        });
    }

    async fn finish_hangup(self: &Arc<Self>, hangup: Hangup, reason: &'static str) -> bool {
        // Tombstone the call and tell every client it ended on purpose,
        // before Codex closes the realtime transport: the app must treat the
        // coming close as final instead of auto-reconnecting the call the
        // model just hung up. Broadcast-before-stop guarantees the client
        // sees `agentEnded` ahead of `thread/realtime/closed`.
        {
            let payload = serde_json::json!({
                "method": "voice/session/agentEnded",
                "params": {
                    "realtimeSessionId": hangup.realtime_session_id,
                    "realtimeThreadId": hangup.realtime_thread_id,
                }
            });
            if let Err(error) = self.broadcast_json_or_drop(&payload, Source::Gateway) {
                warn!(%error, "failed to encode agent hangup notification");
            }
        }
        match self
            .stop_draining_voice_session(Some(hangup.realtime_thread_id), reason)
            .await
        {
            Ok(ended) => ended,
            Err(error) => {
                warn!(%error, reason, "voice hang-up failed upstream");
                // The session was still put into draining and finalized, so
                // the call is over from the user's side either way.
                true
            }
        }
    }

    /// Asks Codex to stop the realtime call of a session that is already
    /// draining. Returns whether there was a session to drain.
    pub(super) async fn stop_draining_voice_session(
        self: &Arc<Self>,
        realtime_thread_id: Option<String>,
        reason: &'static str,
    ) -> Result<bool> {
        let Some(realtime_thread_id) = realtime_thread_id else {
            info!(
                reason,
                "realtime voice stop requested without an active session"
            );
            return Ok(false);
        };
        info!(
            realtime_thread_id,
            reason, "realtime voice session stop requested; draining for the transcript tail"
        );
        // The session stays alive in a draining state so the transcript
        // tail-flush handoff emitted by the stop can still reach the executor.
        let stop_result = self
            .call_control(
                "thread/realtime/stop",
                serde_json::json!({ "threadId": realtime_thread_id }),
            )
            .await;
        self.spawn_voice_finalize(realtime_thread_id);
        stop_result?;
        Ok(true)
    }
}
