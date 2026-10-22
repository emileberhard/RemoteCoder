use super::{Gateway, voice_append_request};
use crate::gateway::turn_state::text_preview;
use crate::notifications::is_realtime_item_stream_notification;
use crate::providers::claude::TurnControlError;
use crate::time::unix_seconds;
use crate::voice::handoff::BoundTurn;
use crate::voice::handoff::{
    TranscriptEntry, VoiceAppend, VoiceCompletion, VoiceOutputTarget, tool_activity_label,
};
use crate::voice::session::{
    VOICE_STOP_TAIL_GRACE_SECONDS, VOICE_WATCHDOG_ORPHAN_TICKS, VOICE_WATCHDOG_TICK_SECONDS,
    VoiceSessionOwner, VoiceTransportEnd,
};
use anyhow::Context;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tracing::{debug, info, warn};

#[derive(Debug, Clone, Copy)]
pub(super) enum HandoffFailureScope {
    NotRegistered,
    Registered,
    WhileUnconsumed,
}

impl Gateway {
    /// Removes the draining session once the tail-flush grace window passes.
    /// A dispatched tail turn keeps running in the normal chat regardless.
    pub(super) fn spawn_voice_finalize(self: &Arc<Self>, realtime_thread_id: String) {
        let gateway = Arc::clone(self);
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(VOICE_STOP_TAIL_GRACE_SECONDS)).await;
            if let Some(session) = gateway.voice.finish_draining(&realtime_thread_id) {
                session.close_log("stopped");
            }
        });
    }

    /// Periodic tick that synthesizes progress commentary when the executor
    /// has been silent too long during a running voice-delegated turn, and
    /// force-completes delegations whose bound turn is gone from the executor
    /// (their `turn/completed` can never match). Exits when its session is
    /// gone or replaced.
    pub(super) fn spawn_voice_watchdog(self: &Arc<Self>, realtime_thread_id: String) {
        let gateway = Arc::clone(self);
        tokio::spawn(async move {
            let mut missing: Option<(BoundTurn, u32)> = None;
            loop {
                tokio::time::sleep(Duration::from_secs(VOICE_WATCHDOG_TICK_SECONDS)).await;
                let Some((bound_turn, conversation_thread_id, unconsumed_handoff)) = gateway
                    .voice
                    .with_live_realtime_thread(&realtime_thread_id, |active| {
                        (
                            active.delegations.bound_turn(),
                            active.conversation_thread_id.clone(),
                            active
                                .delegations
                                .unconsumed_handoff_id()
                                .map(str::to_string),
                        )
                    })
                else {
                    return;
                };
                if let Some(handoff_id) = unconsumed_handoff {
                    let agent = gateway.claude_agent();
                    let exists = match agent {
                        Some(agent) => agent.has_runtime(&conversation_thread_id).await,
                        None => false,
                    };
                    if !exists {
                        gateway
                            .fail_external_voice_handoff(
                                &realtime_thread_id,
                                &handoff_id,
                                "Claude stopped before accepting the spoken input",
                                HandoffFailureScope::WhileUnconsumed,
                            )
                            .await;
                    }
                }
                let executor_turn_id = match (&bound_turn, gateway.claude_agent()) {
                    (Some(_), Some(agent)) => agent.active_turn_id(&conversation_thread_id).await,
                    _ => None,
                };
                let missing_turn =
                    bound_turn.filter(|bound| executor_turn_id.as_deref() != Some(bound.turn_id()));
                missing = match (missing_turn, missing.take()) {
                    (Some(bound), Some((previous, ticks))) if previous == bound => {
                        Some((bound, ticks + 1))
                    }
                    (Some(bound), _) => Some((bound, 1)),
                    (None, _) => None,
                };
                let expired = missing
                    .as_ref()
                    .filter(|(_, ticks)| *ticks >= VOICE_WATCHDOG_ORPHAN_TICKS)
                    .map(|(bound, _)| bound.clone());

                let Some((append, orphan_completion)) = gateway.voice.with_live_realtime_thread(
                    &realtime_thread_id,
                    |active| {
                        if let Some(expected) = expired.as_ref() {
                            let completion = active
                                .delegations
                                .fail_missing_turn(expected, unix_seconds());
                            if let Some(completion) = completion.as_ref() {
                                warn!(
                                    handoff_id = ?completion.target.handoff_id(),
                                    "interrupting orphaned voice delegation; its bound turn is gone"
                                );
                                active.log_event(
                                    "handoff/orphaned",
                                    serde_json::json!({
                                        "handoffId": completion.target.handoff_id(),
                                        "status": "interrupted",
                                        "outcome": "unknown",
                                    }),
                                );
                            }
                            (None, completion)
                        } else {
                            (active.delegations.watchdog_append(unix_seconds()), None)
                        }
                    },
                ) else {
                    return;
                };
                if expired.is_some() {
                    missing = None;
                }
                if let Some(append) = append {
                    gateway
                        .send_voice_append(&realtime_thread_id, append, true)
                        .await;
                }
                if let Some(completion) = orphan_completion {
                    gateway
                        .send_voice_completion(&realtime_thread_id, completion)
                        .await;
                }
            }
        });
    }

    pub(super) async fn clear_voice_session_or_drop(
        &self,
        client_id: u64,
        thread_id: Option<&str>,
    ) {
        if let Some(record) = self.clear_voice_session(client_id, thread_id).await {
            self.publish_call_state_or_drop(&record);
        }
    }

    async fn clear_voice_session(
        &self,
        client_id: u64,
        thread_id: Option<&str>,
    ) -> Option<super::calls::CallRecord> {
        let session = self.voice.clear(client_id, thread_id)?;
        session.close_log("cleared");
        self.record_voice_session_end(&VoiceSessionOwner {
            client_id: session.owner_client_id,
            realtime_session_id: session.realtime_session_id,
        })
        .await
    }

    async fn record_voice_session_end(
        &self,
        owner: &VoiceSessionOwner,
    ) -> Option<super::calls::CallRecord> {
        match self
            .record_call_transport_end(owner, "voice session closed")
            .await
        {
            Ok(record) => record,
            Err(error) => {
                warn!(%error, "failed to persist call closure");
                None
            }
        }
    }

    pub(super) async fn handle_voice_control_notification(self: &Arc<Self>, raw: &str) {
        let Ok(message) = serde_json::from_str::<Value>(raw) else {
            return;
        };
        let Some(method) = message.get("method").and_then(Value::as_str) else {
            return;
        };
        let Some(params) = message.get("params") else {
            return;
        };

        if method.starts_with("thread/realtime/") {
            let thread_id = params
                .get("threadId")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            match method {
                "thread/realtime/sdp" => info!(
                    thread_id,
                    sdp_bytes = params
                        .get("sdp")
                        .and_then(|value| value.as_str())
                        .map_or(0, str::len),
                    "realtime SDP answer received from Codex"
                ),
                "thread/realtime/error" => warn!(
                    thread_id,
                    message = params
                        .get("message")
                        .and_then(|value| value.as_str())
                        .unwrap_or("unknown realtime error"),
                    "realtime Codex error notification"
                ),
                "thread/realtime/closed" => info!(
                    thread_id,
                    reason = params
                        .get("reason")
                        .and_then(|value| value.as_str())
                        .unwrap_or("unspecified"),
                    "realtime Codex session closed"
                ),
                "thread/realtime/transcript/delta" | "thread/realtime/outputAudio/delta" => {}
                method if is_realtime_item_stream_notification(method) => {}
                _ => info!(thread_id, method, "realtime Codex notification"),
            }
        }

        let device_input = (method == "thread/realtime/transcript/done"
            && params.get("role").and_then(Value::as_str) == Some("user"))
            || (method == "thread/realtime/itemAdded"
                && params.pointer("/item/type").and_then(Value::as_str) == Some("handoff_request"));
        if device_input
            && let Some((client, thread)) =
                params
                    .get("threadId")
                    .and_then(Value::as_str)
                    .and_then(|thread| {
                        self.voice.with_realtime_thread(thread, |session| {
                            (
                                session.owner_client_id,
                                session.conversation_thread_id.clone(),
                            )
                        })
                    })
        {
            self.device_tools.record_driver(client, &thread);
        }

        if matches!(
            method,
            "thread/realtime/transcript/delta" | "thread/realtime/outputAudio/delta"
        ) {
            let thread_id = params
                .get("threadId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let user = params.get("role").and_then(Value::as_str) == Some("user");
            let now = tokio::time::Instant::now();
            self.voice.with_live_realtime_thread(thread_id, |active| {
                match active.farewell.as_mut() {
                    Some(farewell) if user => farewell.user_speech(),
                    Some(farewell) => farewell.voice_speech(now),
                    None => {}
                }
            });
            return;
        }

        if method == "thread/realtime/transcript/done" {
            let thread_id = params
                .get("threadId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let role = params
                .get("role")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let text = params
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let now = tokio::time::Instant::now();
            let farewell_armed = self.voice.with_realtime_thread(thread_id, |active| {
                active.log_event(
                    "transcript",
                    serde_json::json!({ "role": role, "text": text }),
                );
                let armed = match (role, active.farewell.as_mut()) {
                    ("user", Some(farewell)) => {
                        farewell.user_line();
                        false
                    }
                    ("assistant", Some(farewell)) => farewell.voice_line(text, now),
                    _ => false,
                };
                if armed {
                    active.log_event("farewell/armed", serde_json::json!({ "text": text }));
                }
                armed
            }) == Some(true);
            if farewell_armed {
                self.spawn_farewell_close(thread_id.to_string());
            }
            return;
        }

        if method == "thread/realtime/itemAdded" {
            if let Some(item) = params
                .get("item")
                .filter(|item| item.get("type").and_then(Value::as_str) == Some("handoff_request"))
            {
                self.start_external_voice_handoff(params, item).await;
            }
            return;
        }

        if matches!(method, "thread/realtime/closed" | "thread/realtime/error") {
            let thread_id = params
                .get("threadId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if method == "thread/realtime/error"
                && params.get("terminal").and_then(Value::as_bool) == Some(false)
            {
                self.voice.with_realtime_thread(thread_id, |active| {
                    active.log_event("session/error", params.clone());
                });
                return;
            }
            self.voice.with_realtime_thread(thread_id, |active| {
                active.log_event("session/closed", params.clone());
            });
            let end = if method == "thread/realtime/error" {
                VoiceTransportEnd::Error
            } else if params.get("providerClosed").and_then(Value::as_bool) == Some(true) {
                VoiceTransportEnd::ProviderClosed
            } else {
                VoiceTransportEnd::Closed(params.get("reason").and_then(Value::as_str))
            };
            let Some((owner, session)) = self.voice.end_realtime_thread(thread_id, end) else {
                return;
            };
            if let Some(session) = session {
                session.close_log("realtime closure");
            }
            let record = self.record_voice_session_end(&owner).await;
            if let Some(record) = record {
                self.publish_call_state_awaiting_capacity(&record).await;
            }
        }
    }

    async fn start_external_voice_handoff(&self, params: &Value, item: &Value) {
        let realtime_thread_id = params
            .get("threadId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let handoff_id = item
            .get("handoff_id")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let input = item
            .get("input_transcript")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string();
        if realtime_thread_id.is_empty() || handoff_id.is_empty() || input.is_empty() {
            return;
        }
        if self.is_draining() {
            self.fail_external_voice_handoff(
                realtime_thread_id,
                handoff_id,
                "Gateway is restarting; reconnect and try again",
                HandoffFailureScope::NotRegistered,
            )
            .await;
            return;
        }
        let transcript_entries: Vec<TranscriptEntry> = item
            .get("active_transcript")
            .and_then(Value::as_array)
            .map(|entries| {
                entries
                    .iter()
                    .filter_map(|entry| {
                        Some(TranscriptEntry {
                            role: entry.get("role").and_then(Value::as_str)?.to_string(),
                            text: entry.get("text").and_then(Value::as_str)?.to_string(),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();

        let input_id = crate::ids::new_session_uuid();
        let Some((session, inherited_turn_id, transcript_delta, session_draining)) = self
            .voice
            .with_realtime_thread_draining(realtime_thread_id, |session, draining| {
                if !session.uses_external_executor {
                    return None;
                }
                let transcript_delta = session
                    .delegations
                    .take_transcript_delta(&transcript_entries);
                let session_draining =
                    draining || crate::voice::handoff::transcript_tail_envelope(&input).is_some();
                let inherited_turn_id = if session_draining {
                    // Post-stop transcript-tail flush: dispatch to the executor so
                    // the chat records how the call ended, but register no
                    // delegation — the realtime side is gone.
                    session.tail_flush_dispatched = true;
                    session.log_event(
                        "handoff/tailFlush",
                        serde_json::json!({ "handoffId": handoff_id, "input": input }),
                    );
                    None
                } else {
                    let outcome = session
                        .delegations
                        .begin(handoff_id, &input_id, unix_seconds());
                    if let Some(superseded) = outcome.superseded_handoff_id.as_deref() {
                        info!(
                            handoff_id,
                            superseded, "voice delegation supersedes a pending one"
                        );
                        session.log_event(
                        "handoff/superseded",
                        serde_json::json!({ "handoffId": superseded, "supersededBy": handoff_id }),
                    );
                    }
                    session.log_event(
                        "handoff/requested",
                        serde_json::json!({
                            "handoffId": handoff_id,
                            "input": input,
                            "transcriptDeltaCount": transcript_delta.len(),
                        }),
                    );
                    outcome.inherited_turn_id
                };
                Some((
                    session.clone(),
                    inherited_turn_id,
                    transcript_delta,
                    session_draining,
                ))
            })
            .flatten()
        else {
            return;
        };
        let failure_scope = if session_draining {
            HandoffFailureScope::NotRegistered
        } else {
            HandoffFailureScope::Registered
        };
        info!(
            handoff_id,
            input_preview = %text_preview(&input, 80),
            tail_flush = session_draining,
            "voice delegation requested"
        );
        let envelope = if session_draining {
            crate::voice::handoff::transcript_tail_envelope(&input).map(str::to_string)
        } else {
            None
        };
        let is_tail = envelope.is_some();
        let text = envelope.unwrap_or_else(|| {
            crate::voice::handoff::delegation_envelope(&input, &transcript_delta)
        });
        let text = match self
            .call_handoff_context(&session.realtime_session_id)
            .await
            .and_then(|context| match context {
                Some(context) => crate::voice::handoff::envelope_with_call_context(&text, &context)
                    .context("call handoff requires a canonical delegation envelope"),
                None => Ok(text),
            }) {
            Ok(text) => text,
            Err(error) => {
                warn!(%error, "call handoff context unavailable");
                self.fail_external_voice_handoff(
                    realtime_thread_id,
                    handoff_id,
                    "Call context could not be loaded",
                    failure_scope,
                )
                .await;
                return;
            }
        };
        let mut delegation = if is_tail {
            crate::providers::claude::ClaudeUserInput::transcript_tail(text)
        } else {
            crate::providers::claude::ClaudeUserInput::text(text)
        };
        delegation.client_id = Some(input_id.clone());

        let Some(session_uuid) =
            crate::providers::claude::session_uuid_from_thread_id(&session.conversation_thread_id)
        else {
            return;
        };
        let _admission = match self.admission.admit(&session.conversation_thread_id) {
            Ok(admission) => admission,
            Err(error) => {
                self.fail_external_voice_handoff(
                    realtime_thread_id,
                    handoff_id,
                    &error.to_string(),
                    failure_scope,
                )
                .await;
                return;
            }
        };
        let first_turn = self
            .claude_history
            .session_path(session_uuid.to_string())
            .await
            .is_err();
        let Some(agent) = self.claude_agent() else {
            self.fail_external_voice_handoff(
                realtime_thread_id,
                handoff_id,
                "Claude agent is not running",
                failure_scope,
            )
            .await;
            return;
        };

        let active_turn_id = match inherited_turn_id {
            Some(turn_id) => Some(turn_id),
            None => agent.active_turn_id(&session.conversation_thread_id).await,
        };
        let steered = active_turn_id.is_some();
        let turn_request = crate::providers::claude::ClaudeTurnRequest {
            thread_id: session.conversation_thread_id.clone(),
            session_uuid: session_uuid.to_string(),
            first_turn,
            input: delegation.clone(),
            selection: crate::providers::claude::ClaudeSelection {
                model: session.model.clone(),
                effort: session.effort.clone(),
                fast: agent
                    .fast_mode(&session.conversation_thread_id, &session.model)
                    .await,
            },
            cwd: session.cwd.clone(),
        };
        let started_turn = if let Some(active_turn_id) = active_turn_id {
            match agent
                .steer(
                    &session.conversation_thread_id,
                    &active_turn_id,
                    &delegation,
                )
                .await
            {
                Ok(()) => Ok(active_turn_id),
                // The inherited turn finished between binding and steering.
                // The utterance must still reach the executor.
                Err(TurnControlError::NotRunning { .. }) => {
                    agent.start_voice_turn(turn_request).await
                }
                Err(TurnControlError::Failed(err)) => Err(err),
            }
        } else {
            agent.start_voice_turn(turn_request).await
        };
        match started_turn {
            Ok(turn_id) => {
                if session_draining {
                    return;
                }
                self.voice.with_realtime_thread(realtime_thread_id, |active| {
                    active.delegations.note_dispatched(handoff_id);
                    active.log_event(
                        "handoff/dispatched",
                        serde_json::json!({ "handoffId": handoff_id, "turnId": turn_id, "inputId": input_id, "steered": steered }),
                    );
                    active.delegations.mark_started(handoff_id, unix_seconds());
                });
            }
            Err(err) => {
                if session_draining {
                    warn!(error = %err.message, "transcript tail flush could not reach the executor");
                    return;
                }
                self.fail_external_voice_handoff(
                    realtime_thread_id,
                    handoff_id,
                    &err.message,
                    HandoffFailureScope::Registered,
                )
                .await;
            }
        }
    }

    /// The failure completion of a registered delegation is only sent while it
    /// is still the active one, so a completed or superseded delegation can
    /// never be re-completed with failure text.
    async fn fail_external_voice_handoff(
        &self,
        realtime_thread_id: &str,
        handoff_id: &str,
        message: &str,
        scope: HandoffFailureScope,
    ) {
        let retired = self
            .voice
            .with_realtime_thread(realtime_thread_id, |session| {
                let still_active = match scope {
                    HandoffFailureScope::NotRegistered => true,
                    HandoffFailureScope::Registered => session.delegations.remove(handoff_id),
                    HandoffFailureScope::WhileUnconsumed => {
                        session.delegations.remove_unconsumed(handoff_id)
                    }
                };
                if !still_active {
                    return true;
                }
                session.log_event(
                    "handoff/failed",
                    serde_json::json!({ "handoffId": handoff_id, "message": message }),
                );
                false
            })
            .unwrap_or(false);
        if retired {
            info!(
                handoff_id,
                message, "skipping failure completion for a retired delegation"
            );
            return;
        }
        warn!(handoff_id, message, "voice delegation failed to start");
        let _ = self
            .send_control_request_untracked(
                "thread/realtime/handoff/complete",
                serde_json::json!({
                    "threadId": realtime_thread_id,
                    "handoffId": handoff_id,
                    "text": format!("The delegated task could not start: {message}"),
                    "phase": "final_answer",
                }),
            )
            .await;
    }

    pub(super) async fn forward_voice_agent_notification(&self, message: &Value) {
        let Some(method) = message.get("method").and_then(Value::as_str) else {
            return;
        };
        let Some(params) = message.get("params") else {
            return;
        };
        let thread_id = params
            .get("threadId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let turn_id = params
            .get("turnId")
            .and_then(Value::as_str)
            .or_else(|| {
                params
                    .get("turn")
                    .and_then(|turn| turn.get("id"))
                    .and_then(Value::as_str)
            })
            .unwrap_or_default();

        match method {
            "item/agentMessage/delta" => {
                let delta = params
                    .get("delta")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if delta.is_empty() {
                    return;
                }
                let Some(append) = self.voice.with_live_conversation(thread_id, |session| {
                    session
                        .delegations
                        .append_delta(turn_id, delta, unix_seconds())
                        .map(|append| (session.realtime_thread_id.clone(), append))
                }) else {
                    return;
                };
                if let Some((realtime_thread_id, append)) = append {
                    self.send_voice_append(&realtime_thread_id, append, false)
                        .await;
                }
            }
            "item/started" => {
                let Some(item) = params.get("item") else {
                    return;
                };
                let Some(label) = tool_activity_label(item) else {
                    return;
                };
                self.voice.with_live_conversation(thread_id, |session| {
                    session.delegations.note_tool_activity(turn_id, label);
                });
            }
            "item/completed" => {
                let Some(item) = params.get("item") else {
                    return;
                };
                if item["type"] == "userMessage" {
                    if let Some(input_id) = item["clientId"].as_str() {
                        self.voice.with_live_conversation(thread_id, |session| {
                            if session.delegations.bind_input(input_id, turn_id) {
                                session.log_event(
                                    "handoff/bound",
                                    json!({ "inputId": input_id, "turnId": turn_id }),
                                );
                            }
                        });
                    }
                    return;
                }
                if item.get("type").and_then(Value::as_str) != Some("agentMessage") {
                    return;
                }
                let text = item.get("text").and_then(Value::as_str).unwrap_or_default();
                // Mid-turn messages are commentary and completion candidates,
                // never completions: the turn boundary is authoritative.
                let Some(append) = self.voice.with_live_conversation(thread_id, |session| {
                    session
                        .delegations
                        .note_agent_message(turn_id, text, unix_seconds())
                        .map(|append| (session.realtime_thread_id.clone(), append))
                }) else {
                    return;
                };
                if let Some((realtime_thread_id, append)) = append {
                    self.send_voice_append(&realtime_thread_id, append, false)
                        .await;
                }
            }
            "turn/started" => {
                self.voice.with_live_conversation(thread_id, |session| {
                    session.delegations.observe_turn(turn_id, unix_seconds());
                    session.log_event("turn/started", serde_json::json!({ "turnId": turn_id }));
                });
            }
            "turn/completed" => {
                let turn = params.get("turn").cloned().unwrap_or(Value::Null);
                let status = turn
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or("completed");
                let error_message = turn
                    .get("error")
                    .and_then(|error| error.get("message"))
                    .and_then(Value::as_str);
                let Some(completion) = self.voice.with_live_conversation(thread_id, |session| {
                    session.log_event(
                        "turn/finished",
                        serde_json::json!({ "turnId": turn_id, "status": status }),
                    );
                    session
                        .delegations
                        .complete_turn(turn_id, status, error_message, unix_seconds())
                        .map(|completion| (session.realtime_thread_id.clone(), completion))
                }) else {
                    return;
                };
                if let Some((realtime_thread_id, completion)) = completion {
                    self.send_voice_completion(&realtime_thread_id, completion)
                        .await;
                }
            }
            _ => {}
        }
    }

    async fn log_voice_append(
        &self,
        realtime_thread_id: &str,
        append: &VoiceAppend,
        synthesized: bool,
    ) {
        self.voice
            .with_realtime_thread(realtime_thread_id, |session| {
                session.log_event(
                    if append.target.handoff_id().is_some() {
                        "handoff/append"
                    } else {
                        "conversation/append"
                    },
                    serde_json::json!({
                        "handoffId": append.target.handoff_id(),
                        "text": append.text,
                        "synthesized": synthesized,
                    }),
                );
            });
    }

    async fn send_voice_append(
        &self,
        realtime_thread_id: &str,
        append: VoiceAppend,
        synthesized: bool,
    ) {
        self.log_voice_append(realtime_thread_id, &append, synthesized)
            .await;
        let (method, params) = voice_append_request(realtime_thread_id, &append);
        if let Err(error) = self.call_control(method, params).await {
            debug!(%error, "voice update arrived after realtime closed");
        }
    }

    async fn send_voice_completion(&self, realtime_thread_id: &str, completion: VoiceCompletion) {
        info!(
            handoff_id = ?completion.target.handoff_id(),
            latency_ms = completion.latency_seconds_x1000,
            text_preview = %text_preview(&completion.text, 80),
            "voice delegation completed"
        );
        self.voice
            .with_realtime_thread(realtime_thread_id, |session| {
                session.log_event(
                    if completion.target.handoff_id().is_some() {
                        "handoff/complete"
                    } else {
                        "conversation/complete"
                    },
                    serde_json::json!({
                        "handoffId": completion.target.handoff_id(),
                        "text": completion.text,
                        "latencyMs": completion.latency_seconds_x1000,
                    }),
                );
            });
        let (method, params) = match &completion.target {
            VoiceOutputTarget::Handoff(handoff_id) => (
                "thread/realtime/handoff/complete",
                serde_json::json!({
                    "threadId": realtime_thread_id,
                    "handoffId": handoff_id,
                    "text": completion.text,
                    "phase": "final_answer",
                }),
            ),
            VoiceOutputTarget::Conversation => (
                "thread/realtime/appendSpeech",
                serde_json::json!({ "threadId": realtime_thread_id, "text": completion.text }),
            ),
        };
        if let Err(err) = self.call_control(method, params).await {
            debug!(error = %err, "voice handoff completion arrived after realtime closed");
        }
    }
}
