use super::agent_gateway::native_error;
use super::transport::ClientFrame;
use super::{ClientTx, Gateway, claude_effort_wire_value, claude_fast_mode, thread_cwd};
use crate::devices::{DeviceRegistration, RegisterError};
use crate::navigation::{
    NavigationManager, NavigationSessionParams, NextNavigationEventParams,
    RegisterNavigationDeviceParams, StartNavigationParams,
};
use crate::observability::journal::Source;
use crate::providers::claude::TurnControlError;
use crate::rpc::dispatch::{ClaudeMethod, OwnedRoute, OwnedTarget};
use crate::rpc::error::{ErrorKind, RETRY_AFTER_MS, RpcCode, RpcData};
use crate::rpc::{HISTORY_PAGE_RESPONSE_BUDGET, HistoryPageRequest, RpcError, RpcResult};
use crate::time::unix_seconds;
use crate::wire::gateway::{ConversationSettingsUpdate, HostInfoResponse};
use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Instant;
use tracing::{info, warn};

impl Gateway {
    pub(super) async fn handle_owned_rpc(
        self: &Arc<Self>,
        client_id: u64,
        out: &ClientTx,
        method: &str,
        target: OwnedTarget,
        object: &serde_json::Map<String, Value>,
    ) -> Result<()> {
        let id = object.get("id").cloned().unwrap_or(Value::Null);
        let params = object.get("params").cloned().unwrap_or(Value::Null);
        let route = match target {
            OwnedTarget::Claude(claude) => {
                self.capture_client_request_locked(client_id, object)
                    .await?;
                return self.handle_claude_rpc(out, claude, object).await;
            }
            OwnedTarget::Gateway(route) => route,
        };
        let response = match route {
            OwnedRoute::NativeMutation if id.is_null() => return Ok(()),
            OwnedRoute::NativeMutation => self.native_mutation_rpc(method, params).await,
            OwnedRoute::NativeQueue => self.queue_rpc(client_id, method, params).await,
            OwnedRoute::NativeCompaction => {
                self.codex_compact_start(client_id, object, params).await
            }
            OwnedRoute::Agents => self.agent_service().agents_rpc(method, params).await,
            OwnedRoute::Calls => {
                return self.handle_calls_rpc(client_id, out, method, object).await;
            }
            OwnedRoute::Voice | OwnedRoute::VoiceSession => {
                return self.handle_voice_rpc(client_id, out, method, object).await;
            }
            OwnedRoute::Questions => return self.handle_questions_rpc(out, method, object).await,
            OwnedRoute::ActiveTurns => {
                return self.handle_daemon_active_turns(out, Some(id)).await;
            }
            OwnedRoute::Execution => self.inspect_execution(params).await,
            OwnedRoute::LiveActivity => {
                let snapshot = self.apns.live_activity_updates().borrow().clone();
                Ok(json!(snapshot))
            }
            OwnedRoute::ReplayNotifications => {
                return self
                    .handle_daemon_replay_notifications(out, Some(id), Some(params))
                    .await;
            }
            OwnedRoute::HostInfo => host_info(self.claude_settings.router.is_some()),
            OwnedRoute::ModelList => self.model_list(params).await,
            OwnedRoute::Rename => self.rename_thread(&params).await,
            OwnedRoute::RegenerateTitle => self.regenerate_title_rpc(&params).await,
            OwnedRoute::Subscriptions => out.content_subscriptions.replace(params),
            OwnedRoute::ClaudeLiveCheckpoint => self.claude_live_checkpoint_rpc(params).await,
            OwnedRoute::Automations => crate::automations::rpc(method, params).await,
            OwnedRoute::TakeOver => self.take_over_conversation(params).await,
            OwnedRoute::Navigation => {
                let params = object.get("params").cloned().unwrap_or_else(|| json!({}));
                self.navigation_rpc(method, params).await
            }
            OwnedRoute::DeviceTools => match method {
                "device/tools/declare" => decode_params(params)
                    .and_then(|declaration| self.device_tools.declare(client_id, declaration)),
                "device/tool/result" => self.device_tools.result(client_id, params),
                _ => Err(RpcError::new(
                    RpcCode::MethodNotFound,
                    "Unknown device tool method",
                )),
            },
            OwnedRoute::Devices => self.devices_rpc(method, params).await,
            OwnedRoute::Metadata => self.metadata_rpc(method, params).await,
            OwnedRoute::Marks => self.marks_rpc(method, params).await,
            OwnedRoute::Favorites => self.favorites_rpc(method, params).await,
            OwnedRoute::Preferences => self.preferences_rpc(method, params).await,
            OwnedRoute::Projects => self.projects_rpc(params).await,
            OwnedRoute::Settings => self.update_conversation_settings(params).await,
            OwnedRoute::Interrupt => self.interrupt_codex_turn(params).await,
            OwnedRoute::Native => return Err(anyhow!("unclassified gateway request")),
        };
        self.respond(out, id, response, Some(method))
            .await
            .map(|_| ())
    }

    async fn metadata_rpc(&self, method: &str, params: Value) -> RpcResult {
        use crate::conversations::{Read, Snapshot, Update, UpdateResult};
        match method {
            "conversation/metadata/read" => {
                let request: Read = if params.is_null() {
                    Read::default()
                } else {
                    decode_params(params)?
                };
                Ok(match self.metadata.read(request.known_revision).await? {
                    Snapshot::Full { entries, revision } => {
                        json!({"entries": entries, "revision": revision})
                    }
                    Snapshot::Unchanged { revision } => {
                        json!({"unchanged": true, "revision": revision})
                    }
                })
            }
            "conversation/metadata/update" => {
                let request = serde_json::from_value::<Update>(params)
                    .ok()
                    .filter(|request| request.validate().is_ok())
                    .ok_or_else(|| {
                        RpcError::new(RpcCode::InvalidParams, "Invalid session metadata update")
                    })?;
                match self.metadata.update(request).await? {
                    UpdateResult::Applied(record) => Ok(json!(record)),
                    UpdateResult::Conflict(current) => Err(RpcError::new(
                        RpcCode::Conflict,
                        "Conversation settings changed on another client. Review before replacing them.",
                    )
                    .with_data(RpcData::MetadataConflict(json!(current)))),
                }
            }
            _ => Err(RpcError::new(
                RpcCode::MethodNotFound,
                "Unknown session metadata method",
            )),
        }
    }

    async fn marks_rpc(&self, method: &str, params: Value) -> RpcResult {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Update {
            changes: Vec<crate::conversation_marks::Change>,
        }
        let now = unix_seconds() as i64;
        match method {
            "conversation/marks/read" => {
                let mut snapshot = json!(self.marks.read(now).await?);
                snapshot["supportsRetiredScopeRead"] = true.into();
                Ok(snapshot)
            }
            "conversation/marks/update" => {
                let Update { changes } = decode_params(params)?;
                crate::conversation_marks::validate(&changes)
                    .map_err(|error| RpcError::new(RpcCode::InvalidParams, format!("{error:#}")))?;
                let delta = self.marks.update(changes, now).await?;
                if let Some(delta) = &delta {
                    self.publish_marks(delta).await;
                }
                Ok(json!({ "delta": delta }))
            }
            _ => Err(RpcError::new(
                RpcCode::MethodNotFound,
                "Unknown conversation marks method",
            )),
        }
    }

    async fn favorites_rpc(&self, method: &str, params: Value) -> RpcResult {
        use crate::directory_favorites::{Applied, Change};
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Update {
            changes: Vec<Change>,
        }
        let store = self.favorites.as_ref().ok_or_else(|| {
            RpcError::new(
                RpcCode::MethodNotFound,
                "Directory favorites are served by the host connection",
            )
        })?;
        match method {
            "directory/favorites/read" => Ok(json!(store.read().await?)),
            "directory/favorites/update" => {
                let Update { changes } = decode_params(params)?;
                crate::directory_favorites::validate(&changes)
                    .map_err(|error| RpcError::new(RpcCode::InvalidParams, format!("{error:#}")))?;
                let Applied { favorites, changed } = store.update(changes).await?;
                if changed {
                    let notification = json!({
                        "method": "directory/favorites/changed",
                        "params": &favorites,
                    });
                    self.broadcast_json_awaiting_capacity(&notification, Source::Gateway)
                        .await;
                }
                Ok(json!(favorites))
            }
            _ => Err(RpcError::new(
                RpcCode::MethodNotFound,
                "Unknown directory favorites method",
            )),
        }
    }

    async fn preferences_rpc(&self, method: &str, params: Value) -> RpcResult {
        use crate::user_preferences::{Applied, Entry};
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Update {
            entries: std::collections::BTreeMap<String, Entry>,
        }
        let store = self.preferences.as_ref().ok_or_else(|| {
            RpcError::new(
                RpcCode::MethodNotFound,
                "Preferences are served by the host connection",
            )
        })?;
        match method {
            "preferences/read" => Ok(json!(store.read().await?)),
            "preferences/update" => {
                let Update { entries } = decode_params(params)?;
                crate::user_preferences::validate(&entries)
                    .map_err(|error| RpcError::new(RpcCode::InvalidParams, format!("{error:#}")))?;
                let Applied {
                    preferences,
                    changed,
                } = store.update(entries).await?;
                if changed {
                    let notification = json!({
                        "method": "preferences/changed",
                        "params": &preferences,
                    });
                    self.broadcast_json_awaiting_capacity(&notification, Source::Gateway)
                        .await;
                }
                Ok(json!(preferences))
            }
            _ => Err(RpcError::new(
                RpcCode::MethodNotFound,
                "Unknown preferences method",
            )),
        }
    }

    pub(super) async fn publish_marks(&self, delta: &crate::conversation_marks::Marks) {
        let notification = json!({ "method": "conversation/marks/changed", "params": delta });
        self.broadcast_json_awaiting_capacity(&notification, Source::Gateway)
            .await;
        self.refresh_live_activity().await;
    }

    pub(super) async fn record_thread_lifecycle(&self, method: &str, thread_id: &str) {
        let now = unix_seconds() as i64;
        let thread = thread_id.to_string();
        let recorded = match method {
            "thread/deleted" => {
                self.forget_finished_turn(thread_id).await;
                self.marks.forget(thread, now).await
            }
            _ => return,
        };
        match recorded {
            Ok(Some(delta)) => self.publish_marks(&delta).await,
            Ok(None) => {}
            Err(error) => warn!(
                thread_id,
                method, "conversation marks lifecycle record failed: {error:#}"
            ),
        }
    }

    pub(super) async fn drain_pending_native_unarchives(&self) {
        let pending = match self
            .marks
            .pending_native_unarchives(unix_seconds() as i64)
            .await
        {
            Ok(pending) => pending,
            Err(error) => {
                warn!("settled conversations awaiting native unarchive are unreadable: {error:#}");
                return;
            }
        };
        if pending.is_empty() {
            return;
        }
        let mut completed = Vec::new();
        for thread_id in pending {
            match self
                .call_control(
                    "thread/unarchive",
                    json!({ "threadId": thread_id.as_str() }),
                )
                .await
            {
                Ok(_) => completed.push(thread_id),
                Err(error) if leaves_nothing_to_unarchive(&error) => completed.push(thread_id),
                Err(error) => warn!(
                    thread_id = thread_id.as_str(),
                    "settled conversation stays natively archived until the next start: {error:#}"
                ),
            }
        }
        let restored = completed.len();
        match self
            .marks
            .complete_native_unarchives(completed, unix_seconds() as i64)
            .await
        {
            Ok(remaining) => info!(
                restored,
                remaining, "settled conversations restored to the native thread list"
            ),
            Err(error) => warn!(
                restored,
                "native unarchive progress was not recorded: {error:#}"
            ),
        }
    }

    async fn projects_rpc(&self, params: Value) -> RpcResult {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Resolve {
            directories: Vec<String>,
        }
        let Resolve { directories } = decode_params(params)?;
        if directories.len() > crate::conversation_projects::MAXIMUM_DIRECTORIES_PER_REQUEST
            || directories
                .iter()
                .any(|directory| !directory.starts_with('/'))
        {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                format!(
                    "directories must be at most {} absolute paths",
                    crate::conversation_projects::MAXIMUM_DIRECTORIES_PER_REQUEST
                ),
            ));
        }
        let projects = self.projects.resolve(directories).await?;
        Ok(json!({ "projects": projects }))
    }

    async fn devices_rpc(&self, method: &str, params: Value) -> RpcResult {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Unregister {
            device_id: String,
        }
        let devices = self.apns.devices();
        match method {
            "devices/register" => {
                let registration = decode_params::<DeviceRegistration>(params)?;
                let recorded =
                    devices
                        .register(registration)
                        .await
                        .map_err(|error| match error {
                            RegisterError::Invalid(error) => {
                                RpcError::new(RpcCode::InvalidParams, error.to_string())
                            }
                            RegisterError::Full(full) => {
                                RpcError::new(RpcCode::Capacity, full.to_string())
                            }
                            RegisterError::Unavailable(error) => {
                                warn!(%error, "device registration failed");
                                RpcError::new(
                                    RpcCode::Internal,
                                    "the device registry is unavailable",
                                )
                            }
                        })?;
                self.journal.push(
                    "devices",
                    json!({"event": "registered", "device": recorded}),
                );
                self.refresh_live_activity().await;
                Ok(json!({"hostId": self.incoming_call_routing_id().await}))
            }
            "devices/unregister" => {
                let Unregister { device_id } = decode_params(params)?;
                let removed = devices.unregister(&device_id).await.map_err(|error| {
                    warn!(%error, "device unregistration failed");
                    RpcError::new(RpcCode::InvalidParams, error.to_string())
                })?;
                self.journal.push(
                    "devices",
                    json!({"event": "unregistered", "deviceId": device_id, "removed": removed}),
                );
                Ok(json!({}))
            }
            _ => Err(RpcError::new(
                RpcCode::MethodNotFound,
                format!("unsupported devices method: {method}"),
            )),
        }
    }

    async fn navigation_rpc(&self, method: &str, params: Value) -> RpcResult {
        let result = match method {
            "navigation/device/register" => {
                let params = decode_params::<RegisterNavigationDeviceParams>(params)?;
                self.navigation.register_device(params).await
            }
            "navigation/start" => {
                let params = decode_params::<StartNavigationParams>(params)?;
                self.navigation
                    .start(params)
                    .await
                    .and_then(|started| serde_json::to_value(started).map_err(Into::into))
            }
            "navigation/status" => {
                let params = decode_params::<NavigationSessionParams>(params)?;
                self.navigation.status(params.session_id).await
            }
            "navigation/next" => {
                let params = decode_params::<NextNavigationEventParams>(params)?;
                self.navigation.next_event(params).await
            }
            "navigation/stop" => {
                let params = decode_params::<NavigationSessionParams>(params)?;
                let session_id = params.session_id.ok_or_else(|| {
                    RpcError::new(RpcCode::InvalidParams, "navigation/stop requires sessionId")
                })?;
                self.navigation.stop(session_id).await
            }
            _ => {
                return Err(RpcError::new(
                    RpcCode::MethodNotFound,
                    format!("unsupported navigation method: {method}"),
                ));
            }
        };
        result.map_err(|error| {
            warn!(method, %error, "navigation RPC failed");
            RpcError::from(error)
        })
    }

    pub(crate) fn navigation(&self) -> &Arc<NavigationManager> {
        &self.navigation
    }

    pub(super) async fn update_conversation_settings(&self, params: Value) -> RpcResult {
        let settings = ConversationSettingsUpdate::from_params(params)
            .map_err(|error| RpcError::new(RpcCode::InvalidParams, error.to_string()))?;
        self.apply_conversation_settings(settings).await
    }

    async fn apply_conversation_settings(&self, settings: ConversationSettingsUpdate) -> RpcResult {
        // Starting/replacing voice and publishing its settings share one order.
        // Settings never own the media connection or the agent's turn lifetime.
        let _transition = self.voice.transition().await;
        let result = if crate::providers::claude::is_claude_thread_id(&settings.thread_id) {
            let agent = self.claude_agent().ok_or_else(|| {
                RpcError::new(RpcCode::Internal, "Claude provider is unavailable")
            })?;
            let selection = crate::providers::claude::ClaudeSelection {
                model: settings.model.clone(),
                effort: settings.effort.as_deref().map(claude_effort_wire_value),
                fast: claude_fast_mode(
                    &agent,
                    &settings.thread_id,
                    &settings.model,
                    settings.service_tier.as_ref().map(Option::as_deref),
                )
                .await?,
            };
            agent
                .update_settings(&settings.thread_id, &selection)
                .await
                .map_err(RpcError::from)?
        } else {
            self.ensure_codex_thread_loaded(&settings.thread_id).await?;
            let effort = match settings.effort.as_deref() {
                Some(effort) => effort.to_string(),
                None => {
                    let catalog = self.model_list(json!({ "includeHidden": true })).await?;
                    catalog["data"]
                        .as_array()
                        .and_then(|models| {
                            models.iter().find(|model| {
                                model["model"] == settings.model || model["id"] == settings.model
                            })
                        })
                        .and_then(|model| model["defaultReasoningEffort"].as_str())
                        .context(
                            "Codex returned no default reasoning effort for the selected model",
                        )?
                        .to_string()
                }
            };
            let mut update = json!({
                "threadId": settings.thread_id,
                "model": settings.model,
                "effort": effort,
            });
            if let Some(service_tier) = &settings.service_tier {
                update["serviceTier"] = json!(service_tier);
            }
            if let Some(summary) = settings.summary {
                update["summary"] = json!(summary);
            }
            self.call_control("thread/settings/update", update.clone())
                .await
                .map_err(|error| native_error(&error))?;
            match self.apply_active_codex_settings(update).await {
                Ok(result) => result,
                Err(error) => json!({
                    "status": "nextTurn",
                    "warning": format!("Settings saved for future turns; the running turn could not be updated: {error}"),
                }),
            }
        };
        self.voice
            .with_conversation(&settings.thread_id, |session| {
                session.model = settings.model;
                session.effort = if session.uses_external_executor {
                    settings.effort.as_deref().map(claude_effort_wire_value)
                } else {
                    settings.effort
                };
            });
        Ok(result)
    }

    async fn ensure_codex_thread_loaded(
        &self,
        thread_id: &str,
    ) -> std::result::Result<(), RpcError> {
        let thread = self
            .call_control(
                "thread/read",
                json!({"threadId": thread_id, "includeTurns": false}),
            )
            .await
            .map_err(|error| native_error(&error))?;
        if thread
            .pointer("/thread/status/type")
            .and_then(Value::as_str)
            == Some("notLoaded")
        {
            self.call_control(
                "thread/resume",
                json!({"threadId": thread_id, "excludeTurns": true}),
            )
            .await
            .map_err(|error| native_error(&error))?;
        }
        Ok(())
    }

    async fn apply_active_codex_settings(&self, mut update: Value) -> Result<Value> {
        let thread_id = update["threadId"]
            .as_str()
            .context("threadId is required")?;
        let thread = self
            .call_control(
                "thread/read",
                json!({
                    "threadId": thread_id, "includeTurns": false,
                }),
            )
            .await?;
        match thread
            .pointer("/thread/status/type")
            .and_then(Value::as_str)
        {
            Some("idle") => return Ok(json!({ "status": "nextTurn" })),
            Some("active") => {}
            status => bail!("Codex thread activity is unavailable: {status:?}"),
        }
        let observed_turn_id = {
            let core = self.core.lock().await;
            core.turns
                .active_on_thread(thread_id)
                .map(|turn| turn.turn_id.clone())
                .or_else(|| {
                    core.app_server_active_turns_by_thread
                        .get(thread_id)
                        .map(|turn| turn.turn_id.clone())
                })
        };
        let turn_id = if let Some(turn_id) = observed_turn_id {
            Some(turn_id)
        } else {
            let turns = self.call_control("thread/turns/list", json!({
                "threadId": thread_id, "limit": 1, "sortDirection": "desc", "itemsView": "summary",
            })).await?;
            turns["data"]
                .as_array()
                .context("Codex returned no turn list")?
                .iter()
                .find(|turn| turn["status"] == "inProgress")
                .and_then(|turn| turn["id"].as_str())
                .map(str::to_string)
        };
        let Some(turn_id) = turn_id else {
            return Ok(json!({ "status": "nextTurn" }));
        };
        update["turnId"] = json!(turn_id);
        let result = self.call_control("turn/settings/update", update).await?;
        let status = result["status"]
            .as_str()
            .context("Codex returned no settings status")?;
        Ok(json!({ "status": status }))
    }

    /// Dispatches one Claude-owned JSON-RPC request.
    pub(super) async fn handle_claude_rpc(
        &self,
        out_tx: &ClientTx,
        method: ClaudeMethod,
        obj: &serde_json::Map<String, Value>,
    ) -> Result<()> {
        let req_id = obj.get("id").cloned().unwrap_or(Value::Null);
        let params = obj.get("params").cloned().unwrap_or(Value::Null);
        let rpc_method = obj.get("method").and_then(Value::as_str);

        if !self.claude_settings.enabled {
            let response = if matches!(method, ClaudeMethod::ThreadList) {
                Ok(serde_json::json!({"data": [], "nextCursor": Value::Null}))
            } else {
                Err(RpcError::new(
                    RpcCode::Internal,
                    "Claude provider is disabled on this host",
                ))
            };
            return self
                .respond(out_tx, req_id, response, rpc_method)
                .await
                .map(|_| ());
        }

        let response = match method {
            ClaudeMethod::Status => self.claude_status().await,
            ClaudeMethod::ThreadStart => self.claude_thread_start(&params).await,
            ClaudeMethod::ThreadFork => self.claude_thread_fork(&params).await,
            ClaudeMethod::ThreadRead => self.claude_thread_read(&params).await,
            ClaudeMethod::ThreadResume => {
                let response = self.claude_thread_resume(&params).await;
                let replay = match (&response, params.get("threadId").and_then(Value::as_str)) {
                    (Ok(_), Some(thread_id)) => self.claude_token_usage_replay(thread_id).await,
                    _ => None,
                };
                self.respond(out_tx, req_id, response, None).await?;
                if let Some(replay) = replay {
                    self.send_json_awaiting_capacity(out_tx, &replay).await?;
                }
                return Ok(());
            }
            ClaudeMethod::ThreadList => self.claude_thread_list(&params).await,
            ClaudeMethod::ThreadRelease => self.claude_thread_release(&params).await,
            ClaudeMethod::Message => self.claude_message(params).await,
            ClaudeMethod::TurnStart => self.claude_turn_start(&params).await,
            ClaudeMethod::ThreadCompactStart => self.claude_compact_start(params).await,
            ClaudeMethod::TurnSteer => self.claude_turn_steer(&params).await,
            ClaudeMethod::TurnInterrupt => self.claude_turn_interrupt(&params).await,
            ClaudeMethod::ItemsPage | ClaudeMethod::TurnsPage => {
                return self
                    .claude_history_page(out_tx, req_id, method, params)
                    .await;
            }
        };
        if response.is_ok() {
            let input_method = match method {
                ClaudeMethod::Message => Some("claude/message"),
                ClaudeMethod::TurnStart => Some("turn/start"),
                ClaudeMethod::TurnSteer => Some("turn/steer"),
                _ => None,
            };
            if let Some(method) = input_method {
                self.device_tools.record_input(
                    out_tx.id,
                    method,
                    obj.get("params").unwrap_or(&Value::Null),
                );
            }
        }
        self.respond(out_tx, req_id, response, rpc_method)
            .await
            .map(|_| ())
    }

    async fn claude_status(&self) -> RpcResult {
        let snapshot = self.claude_auth.snapshot_refreshing().await;
        let agent = self.claude_agent();
        let active_turns = match agent.as_ref() {
            Some(agent) => agent.active_turn_count().await,
            None => 0,
        };
        Ok(crate::providers::claude::auth::health_json(
            &self.claude_settings,
            Some(&snapshot),
            active_turns,
        ))
    }

    async fn claude_thread_release(&self, params: &Value) -> RpcResult {
        let thread_id = params
            .get("threadId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if !crate::providers::claude::is_claude_thread_id(thread_id) {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "threadId is required",
            ));
        }
        let agent = self.claude_agent();
        let released = match agent {
            Some(agent) => agent.release_idle_runtime(thread_id).await,
            None => false,
        };
        Ok(serde_json::json!({ "released": released }))
    }

    pub(super) async fn claude_thread_set_name(&self, params: &Value) -> RpcResult {
        let thread_id = params
            .get("threadId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let Some(session_uuid) = crate::providers::claude::session_uuid_from_thread_id(thread_id)
        else {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "threadId is required",
            ));
        };
        let Some(name) = params
            .get("name")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|name| !name.is_empty())
        else {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "thread name must not be empty",
            ));
        };
        let Some(agent) = self.claude_agent() else {
            return Err(RpcError::new(
                RpcCode::Internal,
                "Claude agent is not running",
            ));
        };
        match agent.rename_session(thread_id, session_uuid, name).await {
            Ok(crate::providers::claude::SessionRename::Renamed) => Ok(serde_json::json!({})),
            Ok(crate::providers::claude::SessionRename::NoConversation) => Err(RpcError::new(
                RpcCode::InvalidParams,
                format!(
                    "Claude thread {thread_id} has no conversation in this account yet; name it once its first turn has started"
                ),
            )),
            Err(error) => Err(RpcError::new(RpcCode::Internal, error)),
        }
    }

    fn claude_rpc_model<'a>(&'a self, params: &'a Value) -> Result<&'a str, RpcError> {
        let model = params
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or(&self.claude_settings.default_model);
        crate::wire::gateway::validate_model_name(model)
            .map_err(|error| RpcError::new(RpcCode::InvalidParams, error.to_string()))?;
        Ok(model)
    }

    /// Pre-assigns a session id so thread creation is local and instant.
    async fn claude_thread_start(&self, params: &Value) -> RpcResult {
        let model = self.claude_rpc_model(params)?;
        let cwd = params
            .get("cwd")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        if cwd.is_empty() {
            return Err(RpcError::new(RpcCode::InvalidParams, "cwd is required"));
        }

        let Some(agent) = self.claude_agent() else {
            return Err(RpcError::new(
                RpcCode::Internal,
                "Claude agent is not running",
            ));
        };
        let session_uuid = match agent.mint_session().await {
            Ok(session_uuid) => session_uuid,
            Err(error) => {
                return Err(RpcError::new(
                    RpcCode::Internal,
                    format!("Could not record the new Claude session: {error:#}"),
                ));
            }
        };
        let thread_id = crate::providers::claude::claude_thread_id(&session_uuid);
        let now = unix_seconds() as i64;

        let thread = serde_json::json!({
            "id": thread_id,
            "preview": "",
            "modelProvider": "claude",
            "model": model,
            "reasoningEffort": params.pointer("/config/model_reasoning_effort").and_then(Value::as_str).map(claude_effort_wire_value),
            "createdAt": now,
            "updatedAt": now,
            "path": crate::providers::claude::timeline::session_path_for_cwd(
                &self.claude_settings.claude_home, &cwd, &session_uuid
            ).to_string_lossy(),
            "cwd": cwd,
            "cliVersion": "",
            "source": "appServer",
            "status": { "type": "notLoaded" },
            "ephemeral": false,
            "turns": [],
        });

        Ok(serde_json::json!({
            "thread": thread,
            "model": model,
            "modelProvider": "claude",
            "cwd": cwd,
            "approvalPolicy": "never",
            "sandbox": { "type": "dangerFullAccess" },
            "reasoningEffort": params.pointer("/config/model_reasoning_effort").and_then(Value::as_str).map(claude_effort_wire_value),
        }))
    }

    async fn claude_thread_read(&self, params: &Value) -> RpcResult {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Params {
            thread_id: String,
            #[serde(default)]
            include_turns: bool,
        }
        let phase = crate::observability::read_phase::ReadPhase::new(
            &self.journal,
            "thread/read",
            "claudeHeader",
        );
        let mut response = self.claude_thread_header(params, Some(phase)).await?;
        let Params {
            thread_id,
            include_turns,
        } = decode_params(params.clone())?;
        if include_turns {
            let active_turn = self.claude_active_turn_id(&thread_id).await;
            let (turns, _) = self
                .claude_history
                .read_projection(&thread_id, active_turn, |projection, file, _| {
                    projection.thread_turns(file, HISTORY_PAGE_RESPONSE_BUDGET)
                })
                .await
                .map_err(claude_history_error)?;
            response["thread"]["turns"] = Value::Array(turns);
        }
        Ok(response)
    }

    pub(super) async fn claude_thread_response(&self, params: &Value) -> RpcResult {
        self.claude_thread_header(params, None).await
    }

    async fn claude_thread_resume(&self, params: &Value) -> RpcResult {
        let thread_id = params["threadId"]
            .as_str()
            .filter(|thread| {
                crate::providers::claude::session_uuid_from_thread_id(thread).is_some()
            })
            .ok_or_else(|| RpcError::new(RpcCode::InvalidParams, "threadId is required"))?;
        if let Some(agent) = self.claude_agent() {
            agent
                .runtime_settings_for_command(thread_id)
                .await
                .map_err(|error| RpcError::new(RpcCode::Internal, error))?;
        }
        self.claude_thread_response(params).await
    }

    async fn claude_thread_header(
        &self,
        params: &Value,
        mut phase: Option<crate::observability::read_phase::ReadPhase<'_>>,
    ) -> RpcResult {
        let Some(session_uuid) = params
            .get("threadId")
            .and_then(Value::as_str)
            .and_then(crate::providers::claude::session_uuid_from_thread_id)
        else {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "threadId is required",
            ));
        };

        let mut thread = self
            .claude_history
            .read_thread_header(session_uuid.to_string())
            .await
            .map_err(|err| RpcError::new(RpcCode::Internal, format!("{err:#}")))?;
        if let Some(phase) = &mut phase {
            phase.advance("claudeRuntimeSettings");
        }
        let thread_id = crate::providers::claude::claude_thread_id(session_uuid);
        if let Some(agent) = self.claude_agent() {
            match agent.runtime_settings_snapshot(&thread_id).await {
                Ok(Some(selection)) => {
                    thread["model"] = json!(selection.model);
                    thread["reasoningEffort"] = json!(selection.effort);
                    thread["status"] = if agent.active_turn_id(&thread_id).await.is_some() {
                        json!({ "type": "active", "activeFlags": [] })
                    } else {
                        json!({ "type": "idle" })
                    };
                }
                Ok(None) => {}
                Err(_) => {
                    thread["model"] = Value::Null;
                    thread["reasoningEffort"] = Value::Null;
                    thread["status"] = if agent.active_turn_id(&thread_id).await.is_some() {
                        json!({ "type": "active", "activeFlags": [] })
                    } else {
                        json!({ "type": "idle" })
                    };
                }
            }
        }
        if let Some(phase) = phase {
            phase.complete();
        }
        Ok(serde_json::json!({
            "thread": thread,
            "model": thread["model"],
            "modelProvider": "claude",
            "cwd": thread_cwd(&thread),
            "approvalPolicy": "never",
            "sandbox": { "type": "dangerFullAccess" },
            "reasoningEffort": thread["reasoningEffort"],
        }))
    }

    pub(crate) async fn claude_active_turn_id(&self, thread_id: &str) -> Option<String> {
        match self.claude_agent() {
            Some(agent) => agent.active_turn_id(thread_id).await,
            None => None,
        }
    }

    async fn claude_token_usage_replay(&self, thread_id: &str) -> Option<Value> {
        let active_turn = self.claude_active_turn_id(thread_id).await;
        let settings = self.claude_settings.clone();
        let owned_thread_id = thread_id.to_string();
        let replay = self
            .claude_history
            .read_projection(thread_id, active_turn, move |projection, _, _| {
                Ok(projection.token_usage_replay(&owned_thread_id, &settings))
            })
            .await;
        match replay {
            Ok((notification, _)) => notification,
            Err(error) => {
                warn!(thread_id, ?error, "claude token usage replay unavailable");
                None
            }
        }
    }

    async fn claude_history_page(
        &self,
        out_tx: &ClientTx,
        req_id: Value,
        method: ClaudeMethod,
        params: Value,
    ) -> Result<()> {
        let started = Instant::now();
        let (request, method) = match method {
            ClaudeMethod::ItemsPage => (
                serde_json::from_value(params).map(HistoryPageRequest::Items),
                "thread/items/list",
            ),
            _ => (
                serde_json::from_value(params).map(HistoryPageRequest::Turns),
                "thread/turns/list",
            ),
        };
        let request = match request {
            Ok(request) => request,
            Err(error) => {
                return self
                    .respond(
                        out_tx,
                        req_id,
                        Err(RpcError::new(
                            RpcCode::InvalidRequest,
                            format!("Invalid request: {error}"),
                        )),
                        None,
                    )
                    .await
                    .map(|_| ());
            }
        };
        let thread_id = request.thread_id().to_string();
        let active_turn = self.claude_active_turn_id(&thread_id).await;
        let page = self
            .claude_history
            .read_projection(
                &thread_id,
                active_turn,
                move |projection, file, _| match &request {
                    HistoryPageRequest::Items(params) => projection.items_page(file, params),
                    HistoryPageRequest::Turns(params) => projection.turns_page(file, params),
                },
            )
            .await;
        let (result, cache) = match page {
            Ok(page) => page,
            Err(crate::providers::claude::projection::HistoryError::InvalidRequest(message)) => {
                return self
                    .respond(
                        out_tx,
                        req_id,
                        Err(RpcError::new(RpcCode::InvalidRequest, message)),
                        None,
                    )
                    .await
                    .map(|_| ());
            }
            Err(crate::providers::claude::projection::HistoryError::InvalidCursor(message)) => {
                return self
                    .respond(
                        out_tx,
                        req_id,
                        Err(RpcError::new(RpcCode::InvalidRequest, message)
                            .with_data(RpcData::Kind(ErrorKind::HistoryCursorInvalid))),
                        None,
                    )
                    .await
                    .map(|_| ());
            }
            Err(crate::providers::claude::projection::HistoryError::Capacity(capacity)) => {
                return self
                    .respond(out_tx, req_id, Err(capacity.into()), None)
                    .await
                    .map(|_| ());
            }
            Err(crate::providers::claude::projection::HistoryError::Internal(error)) => {
                return self
                    .respond(
                        out_tx,
                        req_id,
                        Err(RpcError::new(RpcCode::Internal, format!("{error:#}"))),
                        None,
                    )
                    .await
                    .map(|_| ());
            }
        };
        let entries = result["data"].as_array().map_or(0, Vec::len);
        let read = started.elapsed();
        let bytes = self
            .respond(out_tx, req_id, Ok(result), Some(method))
            .await?;
        info!(
            thread_id,
            method,
            entries,
            bytes,
            cache = cache.as_str(),
            read_ms = read.as_millis(),
            send_ms = (started.elapsed() - read).as_millis(),
            "claude history page"
        );
        Ok(())
    }

    async fn claude_thread_list(&self, params: &Value) -> RpcResult {
        #[derive(Default, serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Params {
            limit: Option<u64>,
            cursor: Option<String>,
            search_term: Option<String>,
            archived: Option<bool>,
        }
        let params: Params = if params.is_null() {
            Params::default()
        } else {
            decode_params(params.clone())?
        };
        if params.archived == Some(true) {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "Claude conversations are never archived",
            ));
        }
        let query = crate::providers::claude::history::ThreadListQuery::new(
            params.limit.unwrap_or(30),
            params.cursor.as_deref(),
            params.search_term.as_deref(),
        )
        .map_err(claude_history_error)?;
        let phase = crate::observability::read_phase::ReadPhase::new(
            &self.journal,
            "claude/thread/list",
            "claudeHistoryIndex",
        );
        let result = self
            .claude_history
            .list_threads(query)
            .await
            .map_err(claude_history_error);
        phase.complete();
        result
    }

    async fn claude_message(&self, params: Value) -> RpcResult {
        let message =
            match serde_json::from_value::<crate::providers::claude::ParentMessage>(params) {
                Ok(message) => message,
                Err(error) => {
                    return Err(RpcError::new(RpcCode::InvalidParams, error.to_string()));
                }
            };
        let Some(agent) = self.claude_agent() else {
            return Err(RpcError::new(
                RpcCode::Internal,
                "Claude provider is unavailable",
            ));
        };
        match agent.deliver_parent_message(message).await {
            Ok(receipt) => Ok(receipt),
            Err(error) if error.code == RpcCode::ServerBusy => {
                warn!(message = %error.message, "claude/message deferred");
                Err(RpcError::from(error).with_data(RpcData::RetryAfterMs(RETRY_AFTER_MS)))
            }
            Err(error) => Err(RpcError::from(error)),
        }
    }

    async fn claude_turn_start(&self, params: &Value) -> RpcResult {
        let model = self.claude_rpc_model(params)?;
        let thread_id = params
            .get("threadId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let Some(session_uuid) = crate::providers::claude::session_uuid_from_thread_id(&thread_id)
        else {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "threadId is required",
            ));
        };

        let mut input = match crate::providers::claude::ClaudeUserInput::from_input_items(
            params.get("input"),
        ) {
            Ok(input) => input,
            Err(message) => {
                return Err(RpcError::new(RpcCode::InvalidParams, message));
            }
        };
        input.client_id = params
            .get("clientUserMessageId")
            .and_then(Value::as_str)
            .map(str::to_string);
        // An image-only turn is valid: the attachment is the message.
        if input.is_empty() {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "input text or image is required",
            ));
        }

        let cwd = params
            .get("cwd")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        if cwd.is_empty() {
            return Err(RpcError::new(RpcCode::InvalidParams, "cwd is required"));
        }

        // A session file exists only after its first turn has run.
        let first_turn = self
            .claude_history
            .session_path(session_uuid.to_string())
            .await
            .is_err();

        let Some(agent) = self.claude_agent() else {
            return Err(RpcError::new(
                RpcCode::Internal,
                "Claude agent is not running",
            ));
        };

        let request = crate::providers::claude::ClaudeTurnRequest {
            thread_id: thread_id.clone(),
            session_uuid: session_uuid.to_string(),
            first_turn,
            input,
            selection: crate::providers::claude::ClaudeSelection {
                model: model.to_owned(),
                effort: params
                    .get("effort")
                    .and_then(Value::as_str)
                    .map(claude_effort_wire_value),
                fast: claude_fast_mode(
                    &agent,
                    &thread_id,
                    model,
                    params.get("serviceTier").map(Value::as_str),
                )
                .await?,
            },
            cwd,
        };

        match agent.start_turn(request).await {
            Ok(turn_id) => Ok(serde_json::json!({
                "turn": {
                    "id": turn_id,
                    "items": [],
                    "itemsView": "full",
                    "status": "inProgress",
                }
            })),
            Err(err) => Err(RpcError::from(err)),
        }
    }

    async fn codex_compact_start(
        self: &Arc<Self>,
        client_id: u64,
        object: &serde_json::Map<String, Value>,
        params: Value,
    ) -> RpcResult {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Compact {
            thread_id: String,
        }
        let Compact { thread_id } = decode_params(params)?;
        {
            let core = self.core.lock().await;
            if !core.app_server_inventory_bootstrapped
                || core
                    .app_server_inventory_unresolved_threads
                    .contains(&thread_id)
            {
                return Err(RpcError::new(
                    RpcCode::Unavailable,
                    "Conversation activity is unavailable; reconnect before compacting",
                ));
            }
            if core
                .turns
                .pending()
                .any(|(_, turn)| turn.thread_id == thread_id)
                || core.turns.active().any(|turn| turn.thread_id == thread_id)
                || core
                    .app_server_active_turns_by_thread
                    .contains_key(&thread_id)
            {
                return Err(RpcError::new(
                    RpcCode::Conflict,
                    "Wait for this conversation's running response before compacting",
                ));
            }
        }
        // A fresh native read catches work started outside this gateway. Direct
        // app-server clients can still race this read: pinned Op::Compact has no
        // conditional-idle argument. Gateway admissions are mutually excluded.
        let thread = self
            .call_control(
                "thread/read",
                json!({"threadId":thread_id,"includeTurns":false}),
            )
            .await
            .map_err(|error| native_error(&error))?;
        match thread["thread"]["status"]["type"].as_str() {
            Some("idle") => {}
            Some("active") => {
                return Err(RpcError::new(
                    RpcCode::Conflict,
                    "Wait for the running response before compacting",
                ));
            }
            _ => {
                return Err(RpcError::new(
                    RpcCode::Unavailable,
                    "Open this conversation before compacting",
                ));
            }
        }
        self.capture_client_request_locked(client_id, object)
            .await
            .map_err(RpcError::from)?;
        let response = self
            .call_control("thread/compact/start", json!({"threadId":thread_id}))
            .await
            .map_err(|error| {
                super::agent_gateway::parse_native_error(&error.to_string()).unwrap_or_else(|| {
                    RpcError::new(RpcCode::Unavailable,
                        format!("Compaction delivery could not be confirmed; refresh this conversation before retrying: {error:#}"))
                        .with_data(RpcData::Kind(ErrorKind::CompactionDeliveryUncertain { thread_id: thread_id.clone() }))
                })
            });
        let uncertain = response
            .as_ref()
            .is_err_and(|error| error.kind() == Some("compactionDeliveryUncertain"));
        if uncertain || (response.is_ok() && !self.clients.contains_key(&client_id)) {
            // Uncertainty needs reconciliation even while the phone's socket
            // remains open; a failed control send may have reached no task.
            self.spawn_observers_for_client(client_id).await;
        }
        response
    }

    async fn claude_compact_start(&self, params: Value) -> RpcResult {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Compact {
            thread_id: String,
        }
        let Compact { thread_id } = decode_params(params)?;
        let session_uuid = crate::providers::claude::session_uuid_from_thread_id(&thread_id)
            .ok_or_else(|| RpcError::new(RpcCode::InvalidParams, "Claude threadId is required"))?;
        let header = self
            .claude_history
            .read_thread_header(session_uuid.to_owned())
            .await
            .map_err(|error| {
                RpcError::new(
                    RpcCode::Unavailable,
                    format!("Cannot compact this conversation: {error:#}"),
                )
            })?;
        let cwd = header["cwd"]
            .as_str()
            .filter(|cwd| !cwd.is_empty())
            .ok_or_else(|| {
                RpcError::new(
                    RpcCode::Unavailable,
                    "Conversation working directory is unavailable",
                )
            })?;
        let model = header["model"]
            .as_str()
            .filter(|model| !model.is_empty())
            .ok_or_else(|| {
                RpcError::new(RpcCode::Unavailable, "Conversation model is unavailable")
            })?;
        let agent = self
            .claude_agent()
            .ok_or_else(|| RpcError::new(RpcCode::Unavailable, "Claude provider is unavailable"))?;
        agent
            .start_compaction(crate::providers::claude::ClaudeTurnRequest {
                thread_id: thread_id.clone(),
                session_uuid: session_uuid.to_owned(),
                first_turn: false,
                input: crate::providers::claude::ClaudeUserInput::text("/compact"),
                selection: crate::providers::claude::ClaudeSelection {
                    model: model.to_owned(),
                    effort: header["reasoningEffort"].as_str().map(str::to_owned),
                    fast: false,
                },
                cwd: cwd.to_owned(),
            })
            .await
            .map_err(RpcError::from)?;
        Ok(json!({}))
    }

    async fn claude_turn_interrupt(&self, params: &Value) -> RpcResult {
        let thread_id = params
            .get("threadId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let turn_id = params
            .get("turnId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if thread_id.is_empty() || turn_id.is_empty() {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "threadId and turnId are required",
            ));
        }

        self.stop_claude_turn(thread_id, turn_id)
            .await
            .map(|()| serde_json::json!({}))
    }

    pub(crate) async fn stop_claude_turn(
        &self,
        thread_id: &str,
        turn_id: &str,
    ) -> std::result::Result<(), RpcError> {
        let Some(agent) = self.claude_agent() else {
            return Err(RpcError::new(
                RpcCode::Internal,
                "Claude agent is not running",
            ));
        };
        let stopped = agent
            .interrupt(thread_id, turn_id, async || {
                self.claude_suspended_turns(thread_id).await
            })
            .await;
        match stopped {
            Ok(()) => Ok(()),
            Err(TurnControlError::NotRunning { message }) => Err(RpcError::turn_not_running(
                message,
                thread_id,
                Some(turn_id),
            )),
            Err(TurnControlError::Failed(error)) => Err(RpcError::from(error)),
        }
    }

    async fn claude_turn_steer(&self, params: &Value) -> RpcResult {
        let thread_id = params
            .get("threadId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let expected_turn_id = params
            .get("expectedTurnId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let mut input = match crate::providers::claude::ClaudeUserInput::from_input_items(
            params.get("input"),
        ) {
            Ok(input) => input,
            Err(message) => {
                return Err(RpcError::new(RpcCode::InvalidParams, message));
            }
        };
        input.client_id = params
            .get("clientUserMessageId")
            .and_then(Value::as_str)
            .map(str::to_string);
        if thread_id.is_empty() || expected_turn_id.is_empty() || input.is_empty() {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "threadId, expectedTurnId, and input text or image are required",
            ));
        }

        let Some(agent) = self.claude_agent() else {
            return Err(RpcError::new(
                RpcCode::Internal,
                "Claude agent is not running",
            ));
        };
        match agent.steer(thread_id, expected_turn_id, &input).await {
            Ok(()) => Ok(serde_json::json!({ "turnId": expected_turn_id })),
            Err(TurnControlError::NotRunning { message }) => Err(RpcError::turn_not_running(
                message,
                thread_id,
                Some(expected_turn_id),
            )),
            Err(TurnControlError::Failed(err)) => Err(RpcError::from(err)),
        }
    }

    pub(super) async fn respond(
        &self,
        out_tx: &ClientTx,
        req_id: Value,
        response: RpcResult,
        method: Option<&str>,
    ) -> Result<Option<usize>> {
        if let Err(error) = &response {
            warn!(
                code = error.code.value(),
                message = error.message.as_str(),
                kind = ?error.kind(),
                "gateway rpc failed"
            );
        }
        if req_id.is_null() {
            return Ok(Some(0));
        }
        let mut response = match response {
            Ok(result) => serde_json::json!({ "id": req_id, "result": result }),
            Err(error) => error.response(&req_id),
        };
        if super::turn_state::captures_turn_start(method) {
            self.capture_turn_start_response(out_tx.id, &response)
                .await?;
        }
        let frame = ClientFrame::prepare(&mut response, self.tool_media.as_ref()).await?;
        self.send_response_awaiting_capacity(
            out_tx,
            &response,
            frame,
            crate::rpc::history_page_method(method),
        )
        .await
    }
}

pub(super) fn decode_params<T: serde::de::DeserializeOwned>(params: Value) -> Result<T, RpcError> {
    serde_json::from_value(params)
        .map_err(|error| RpcError::new(RpcCode::InvalidParams, error.to_string()))
}

fn claude_history_error(error: crate::providers::claude::projection::HistoryError) -> RpcError {
    use crate::providers::claude::projection::HistoryError;
    match error {
        HistoryError::InvalidRequest(message) => RpcError::new(RpcCode::InvalidParams, message),
        HistoryError::InvalidCursor(message) => RpcError::new(RpcCode::InvalidRequest, message)
            .with_data(RpcData::Kind(ErrorKind::HistoryCursorInvalid)),
        HistoryError::Capacity(capacity) => capacity.into(),
        HistoryError::Internal(error) => RpcError::new(RpcCode::Internal, format!("{error:#}")),
    }
}

fn host_info(speech_available: bool) -> RpcResult {
    let paths = crate::config::HostPaths::from_env()
        .map_err(|error| RpcError::new(RpcCode::Internal, format!("{error:#}")))?;
    let home_directory = paths
        .home()
        .to_str()
        .ok_or_else(|| RpcError::new(RpcCode::Internal, "The home directory is not valid UTF-8"))?
        .to_owned();
    let automations_authority = crate::config::host_profile::AutomationAuthority::authority()
        .map_err(|error| RpcError::new(RpcCode::Unavailable, format!("{error:#}")))?;
    let hostname = nix::unistd::gethostname()
        .map_err(|_| RpcError::new(RpcCode::Unavailable, "Physical hostname is unavailable"))?;
    let hostname = hostname
        .to_str()
        .and_then(|host| host.split('.').next())
        .filter(|host| !host.is_empty())
        .ok_or_else(|| RpcError::new(RpcCode::Unavailable, "Physical hostname is unavailable"))?
        .to_ascii_lowercase();
    Ok(json!(HostInfoResponse {
        home_directory,
        hostname,
        automations_authority,
        speech_available
    }))
}

fn leaves_nothing_to_unarchive(error: &anyhow::Error) -> bool {
    serde_json::from_str::<Value>(&error.to_string()).is_ok_and(|reply| {
        reply["message"].as_str().is_some_and(|message| {
            message.starts_with("no archived rollout found")
                || message.starts_with("invalid session id")
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[tokio::test]
    async fn discovery_round_two_resume_recovers_settings_after_failed_apply() {
        use crate::providers::claude::{ClaudeSelection, ClaudeTurnRequest, ClaudeUserInput};
        use std::os::unix::fs::PermissionsExt;
        let settings =
            Arc::new(crate::providers::claude::settings::ClaudeSettings::isolated_for_test());
        let program = settings.root_path().join("settings-fixture");
        std::fs::write(&program, r#"#!/usr/bin/python3
import json,sys
def emit(value): print(json.dumps(value),flush=True)
emit({'type':'system','subtype':'init','apiKeySource':'none','fast_mode_state':'off','permissionMode':'bypassPermissions'})
failed=False
for line in sys.stdin:
    frame=json.loads(line)
    if frame.get('type')=='control_request':
        operation=frame['request']['subtype']
        if operation=='get_settings' and not failed:
            failed=True
            response={'subtype':'error','error':'fixture readback failed'}
        else:
            response={'subtype':'success','response':{'applied':{'model':'recovered','effort':'high'},'effective':{'fastMode':False}}}
        response['request_id']=frame['request_id']
        emit({'type':'control_response','response':response})
    elif frame.get('type')=='user': emit(frame)
"#).unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut configured = settings.settings.clone();
        configured.enabled = true;
        configured.claude_path = program;
        let gateway = crate::test_support::TestGateway::with_settings(
            Arc::new(crate::providers::codex::daemon::CodexAppServer::new(
                std::path::PathBuf::from("/bin/true"),
                std::collections::HashMap::new(),
            )),
            configured,
            settings,
        );
        let (notifications, _receiver) = tokio::sync::mpsc::channel(32);
        let agent = crate::providers::claude::ClaudeSupervisor::new(
            gateway.claude_settings.clone(),
            notifications,
            gateway.journal.clone(),
            gateway.mcp_tokens.clone(),
        );
        gateway.set_claude_agent(Arc::clone(&agent));
        let uuid = agent.mint_session().await.unwrap();
        let thread = format!("claude_{uuid}");
        let project = gateway.claude_settings.claude_home.join("projects/fixture");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(project.join(format!("{uuid}.jsonl")), format!("{}\n", json!({"type":"user","timestamp":"2026-10-17T10:00:00Z","cwd":"/tmp","message":{"role":"user","content":"Resume fixture"}}))).unwrap();
        let selection = ClaudeSelection {
            model: "claude-fable-5".into(),
            effort: Some("high".into()),
            fast: false,
        };
        agent
            .start_turn(ClaudeTurnRequest {
                thread_id: thread.clone(),
                session_uuid: uuid,
                first_turn: true,
                input: ClaudeUserInput::text("hold"),
                selection: selection.clone(),
                cwd: "/tmp".into(),
            })
            .await
            .unwrap();
        assert!(agent.update_settings(&thread, &selection).await.is_err());
        assert!(agent.runtime_settings_snapshot(&thread).await.is_err());
        let params = json!({"threadId":thread});
        let read = gateway.claude_thread_response(&params).await.unwrap();
        assert!(read["model"].is_null());
        let (tx, mut replies) = tokio::sync::mpsc::channel(8);
        let client = super::super::tests::test_client(1, tx);
        gateway
            .handle_claude_rpc(
                &client,
                ClaudeMethod::ThreadResume,
                json!({"id":1,"params":params}).as_object().unwrap(),
            )
            .await
            .unwrap();
        let response = match replies.recv().await.unwrap() {
            super::super::ClientCommand::Text(text) => {
                serde_json::from_str::<Value>(&text).unwrap()
            }
            _ => panic!("expected resume response"),
        };
        agent.stop_all().await;
        assert_eq!(response["result"]["model"], "recovered");
        assert_eq!(response["result"]["reasoningEffort"], "high");
    }

    #[tokio::test]
    async fn a_claude_header_read_never_waits_for_a_lifecycle_mutation() {
        let gateway = crate::test_support::TestGateway::new();
        let uuid = "11111111-2222-4333-8444-555555555555";
        let thread = format!("claude_{uuid}");
        let project = gateway.claude_settings.claude_home.join("projects/fixture");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(
            project.join(format!("{uuid}.jsonl")),
            format!(
                "{}\n",
                json!({"type":"user","timestamp":"2026-10-17T10:00:00Z",
                    "cwd":"/fixture","message":{"role":"user","content":"Header fixture"}})
            ),
        )
        .unwrap();
        let (notifications, _receiver) = tokio::sync::mpsc::channel(4);
        let agent = crate::providers::claude::ClaudeSupervisor::new(
            gateway.claude_settings.clone(),
            notifications,
            gateway.journal.clone(),
            gateway.mcp_tokens.clone(),
        );
        gateway.set_claude_agent(Arc::clone(&agent));
        let held = agent.lock_lifecycle(&thread).await;
        let response = tokio::time::timeout(
            Duration::from_millis(500),
            gateway.claude_thread_response(&json!({"threadId":thread})),
        )
        .await;
        drop(held);
        agent.stop_all().await;
        let response = response.expect("header waited for lifecycle lock").unwrap();
        assert_eq!(response["thread"]["preview"], "Header fixture");
        assert_eq!(response["thread"]["model"], Value::Null);
    }
}
