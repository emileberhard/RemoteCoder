use super::notifications::compact_notification;
use super::transport::ClientFrame;
use super::{
    AppServerActiveTurn, CODEX_UPSTREAM_INIT_TIMEOUT_SECONDS, ClientCommand, ClientTx, Gateway,
    NativeMutationTransport, PendingControlReply, SEND_TIMEOUT_SECONDS,
    UPSTREAM_OUTBOUND_QUEUE_SIZE, UPSTREAM_SEND_TIMEOUT_SECONDS, send_client_upstream,
};
use crate::notifications::history::NotificationOrigin;
use crate::notifications::{notification_thread_id, realtime_notification_method};
use crate::observability::journal::Source;
use crate::providers::codex::daemon::CodexWebSocket;
use crate::rpc::error::{CodexUnavailable, RpcCode};
use crate::rpc::log_diagnostic_ws_frame;
use crate::tasks::owned_tasks::OwnedTasks;
use crate::time::unix_seconds;
use crate::turns::{TurnKey, is_durable_codex_thread};
use anyhow::{Context, Result, anyhow, bail, ensure};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::Message as UpstreamMessage;
use tracing::{debug, info, warn};

const INVENTORY_BOOTSTRAP_FIRST_RETRY: Duration = Duration::from_secs(1);
const INVENTORY_BOOTSTRAP_MAX_RETRY: Duration = Duration::from_secs(60);

pub(super) struct ControlGeneration {
    pub(super) out_tx: mpsc::Sender<String>,
    pub(super) auth: std::sync::Mutex<super::external_auth::InstalledAuth>,
    pub(super) auth_change: tokio::sync::Mutex<()>,
    pub(super) auth_changed: tokio::sync::Notify,
    pub(super) auth_refresh_slots: Arc<tokio::sync::Semaphore>,
    tasks: OwnedTasks,
}

impl ControlGeneration {
    pub(super) fn spawn(
        &self,
        label: &'static str,
        work: impl std::future::Future<Output = Result<()>> + Send + 'static,
    ) -> bool {
        self.tasks.spawn(label, work)
    }
}

#[derive(Default)]
pub(super) struct ControlConnection {
    current: std::sync::Mutex<Option<Arc<ControlGeneration>>>,
}

impl ControlConnection {
    pub(super) fn publish(&self, out_tx: mpsc::Sender<String>) -> Arc<ControlGeneration> {
        let generation = Arc::new(ControlGeneration {
            out_tx,
            auth: std::sync::Mutex::default(),
            auth_change: tokio::sync::Mutex::new(()),
            auth_changed: tokio::sync::Notify::new(),
            auth_refresh_slots: Arc::new(tokio::sync::Semaphore::new(16)),
            tasks: OwnedTasks::default(),
        });
        let previous = self
            .current
            .lock()
            .expect("control generation poisoned")
            .replace(Arc::clone(&generation));
        debug_assert!(
            previous.is_none(),
            "a control generation was published before its predecessor retired"
        );
        generation
    }

    pub(super) fn current(&self) -> Option<Arc<ControlGeneration>> {
        self.current
            .lock()
            .expect("control generation poisoned")
            .clone()
    }

    pub(super) async fn retire(&self) {
        let generation = self
            .current
            .lock()
            .expect("control generation poisoned")
            .take();
        if let Some(generation) = generation {
            generation.tasks.stop().await;
        }
    }
}

fn active_turn_in(thread_id: &str, turns: &[Value]) -> Result<Option<AppServerActiveTurn>> {
    for turn in turns {
        let status = turn
            .get("status")
            .and_then(Value::as_str)
            .context("thread/turns/list returned a turn without a status")?;
        if status != "inProgress" {
            continue;
        }
        let turn_id = turn
            .get("id")
            .and_then(Value::as_str)
            .context("thread/turns/list returned an in-progress turn without an id")?;
        return Ok(Some(AppServerActiveTurn {
            thread_id: thread_id.to_string(),
            turn_id: turn_id.to_string(),
            started_at_unix_seconds: turn.get("startedAt").and_then(Value::as_f64),
            last_seen_at_unix_seconds: unix_seconds(),
        }));
    }
    Ok(None)
}

pub(super) async fn send_control_frame(tx: &mpsc::Sender<String>, text: String) -> Result<()> {
    tokio::time::timeout(Duration::from_secs_f64(SEND_TIMEOUT_SECONDS), tx.send(text))
        .await
        .context("Codex control send timed out")?
        .context("Codex control send failed")
}

impl Gateway {
    pub(super) async fn send_control_request_untracked(
        &self,
        method: &str,
        params: Value,
    ) -> Result<()> {
        let seq = self.next_control_request_id.fetch_add(1, Ordering::Relaxed);
        self.send_control_text(serde_json::to_string(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": format!("gw:untracked:{seq}"),
            "method": method,
            "params": params,
        }))?)
        .await
    }

    async fn send_control_text(&self, text: String) -> Result<()> {
        log_diagnostic_ws_frame("gateway->codex", None, &text);
        let generation = self
            .control
            .current()
            .ok_or_else(|| CodexUnavailable(self.codex_unavailable_reason()))?;
        send_control_frame(&generation.out_tx, text).await
    }

    pub(super) fn snapshot_clients(&self) -> Vec<ClientTx> {
        self.clients
            .iter()
            .map(|entry| entry.value().clone())
            .collect()
    }

    pub(super) fn disconnect_client(&self, client: &ClientTx) {
        self.clients.remove(&client.id);
        client.closed.cancel();
    }

    /// The single fanout choke point: one journal `notify` line per frame, plus
    /// a `deliver_drop` and a disconnect for every client whose queue rejected it.
    pub(super) fn journal_broadcast(&self, payload: &str, source: Source, clients: &[ClientTx]) {
        if payload.len() > crate::providers::codex::daemon::MAX_WEBSOCKET_BYTES {
            return;
        }
        self.journal
            .notify(source, clients.len(), &Arc::from(payload));
        for client in clients {
            log_diagnostic_ws_frame("gateway->client", Some(client.id), payload);
        }
    }

    pub(super) fn close_all_clients(&self, code: u16, reason: &str) {
        for client in self.snapshot_clients() {
            self.clients.remove(&client.id);
            let _ = self.deliver_or_drop(
                &client,
                ClientCommand::Close {
                    code,
                    reason: reason.to_string(),
                },
            );
        }
    }

    pub(super) async fn codex_control_loop(self: Arc<Self>) {
        let mut backoff = 0.1;
        let mut connect_failures: u32 = 0;

        loop {
            let ws = match self.codex.connect_ws().await {
                Ok(ws) => ws,
                Err(err) => {
                    connect_failures = connect_failures.saturating_add(1);
                    warn!(
                        connect_failures,
                        "failed to connect to codex websocket: {err:?}"
                    );
                    tokio::time::sleep(Duration::from_secs_f64(backoff)).await;
                    backoff = (backoff * 2.0).min(5.0);
                    continue;
                }
            };
            let peer_pid = match crate::providers::codex::daemon::unix_peer_pid(ws.get_ref()) {
                Ok(pid) => pid,
                Err(error) => {
                    warn!(%error, "failed to identify Codex control socket peer");
                    tokio::time::sleep(Duration::from_secs_f64(backoff)).await;
                    backoff = (backoff * 2.0).min(5.0);
                    continue;
                }
            };

            connect_failures = 0;

            let (mut sink, mut stream) = ws.split();

            let init = match self
                .initialize_codex_connection(&mut sink, &mut stream)
                .await
            {
                Ok(v) => v,
                Err(err) => {
                    warn!("Codex control initialization failed: {err:?}");
                    let _ = sink.send(UpstreamMessage::Close(None)).await;
                    tokio::time::sleep(Duration::from_secs_f64(backoff)).await;
                    backoff = (backoff * 2.0).min(5.0);
                    continue;
                }
            };

            let notification_origin = NotificationOrigin::Control {
                opened_after: self.notification_floor().await,
            };
            let (out_tx, mut out_rx) = mpsc::channel::<String>(UPSTREAM_OUTBOUND_QUEUE_SIZE);
            let generation = self.control.publish(out_tx.clone());
            self.refresh_provider_health().await;
            *self.native_mutation_transport.lock().await = Some(NativeMutationTransport {
                pid: peer_pid,
                sender: out_tx,
            });
            let (recovery_tx, mut recovery_rx) = oneshot::channel::<Result<()>>();
            let gateway = Arc::clone(&self);
            let auth_generation = Arc::clone(&generation);
            generation.spawn("restart recovery", async move {
                let ready = async {
                    if let Err(error) = gateway.authenticate_external(&auth_generation).await {
                        warn!(%error, "Codex subscription sign-in failed; Codex starts without it");
                    }
                    gateway.recover_restart_tasks().await
                }
                .await;
                let _ = recovery_tx.send(ready);
                Ok(())
            });
            let mut recovery_pending = true;
            let mut control_ready = false;

            // Main broker loop: forward outbound frames to codex and route inbound frames to clients.
            loop {
                tokio::select! {
                    recovery = &mut recovery_rx, if recovery_pending => {
                        recovery_pending = false;
                        match recovery {
                            Ok(Ok(())) => {
                                *self.control_init_result.lock().await = Some(init.clone());
                                control_ready = true;
                                self.refresh_provider_health().await;
                                self.close_degraded_clients();
                                backoff = 0.1;
                                self.spawn_external_renewal(&generation);
                                info!("Codex control connection initialized");
                                self.spawn_persisted_observers().await;
                                let gateway = Arc::clone(&self);
                                generation.spawn("app-server inventory bootstrap", async move {
                                    gateway.bootstrap_app_server_active_turns().await;
                                    Ok(())
                                });
                                let gateway = Arc::clone(&self);
                                generation.spawn("native unarchive drain", async move {
                                    gateway.drain_pending_native_unarchives().await;
                                    Ok(())
                                });
                                self.spawn_stale_voice_shadow_cleanup();
                                if self.claude_settings.enabled {
                                    self.spawn_default_voice_shadow_prewarm();
                                }
                            }
                            Ok(Err(error)) => {
                                warn!(%error, "Codex restart recovery failed");
                                break;
                            }
                            Err(error) => {
                                warn!(%error, "Codex restart recovery task failed");
                                break;
                            }
                        }
                    }
                    outbound = out_rx.recv() => {
                        let Some(text) = outbound else {
                            warn!("Codex control outbound queue closed");
                            break;
                        };
                        let res = tokio::time::timeout(
                            Duration::from_secs_f64(UPSTREAM_SEND_TIMEOUT_SECONDS),
                            sink.send(UpstreamMessage::Text(text)),
                        )
                        .await;
                        match res {
                            Ok(Ok(())) => {}
                            Ok(Err(err)) => {
                                warn!("Codex control send failed: {err:?}");
                                break;
                            }
                            Err(_) => {
                                warn!("Codex control send timed out");
                                break;
                            }
                        }
                    }
                    inbound = stream.next() => {
                        let Some(inbound) = inbound else {
                            warn!("Codex control connection closed");
                            break;
                        };
                        let Ok(msg) = inbound else {
                            warn!("Codex control receive failed");
                            break;
                        };
                        match msg {
                            UpstreamMessage::Text(raw) => {
                                self.handle_control_text(raw, notification_origin).await;
                            }
                            UpstreamMessage::Close(_) => {
                                warn!("Codex control peer sent close");
                                break;
                            }
                            _ => continue,
                        }
                    }
                }
            }

            // Broker disconnect cleanup. The generation's work is joined first, so
            // nothing it started can publish over the cleared state below.
            self.control.retire().await;
            *self.native_mutation_transport.lock().await = None;
            *self.control_init_result.lock().await = None;
            self.control_requests
                .lock()
                .expect("control replies poisoned")
                .clear();
            self.questions.disconnected().await;
            self.clear_app_server_turn_inventory().await;
            self.voice.shadows.invalidate();
            self.refresh_provider_health().await;
            if control_ready {
                info!("Codex control connection lost after becoming ready");
            }
            tokio::time::sleep(Duration::from_secs_f64(backoff)).await;
            backoff = (backoff * 2.0).min(5.0);
        }
    }

    pub(super) async fn initialize_codex_connection(
        &self,
        sink: &mut futures_util::stream::SplitSink<CodexWebSocket, UpstreamMessage>,
        stream: &mut futures_util::stream::SplitStream<CodexWebSocket>,
    ) -> Result<Value> {
        const INIT_ID: &str = "remote-coder-gateway-init";

        let init = serde_json::json!({
            "jsonrpc": "2.0",
            "id": INIT_ID,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "remote-coder-gateway",
                    "title": "RemoteCoder gateway",
                    "version": "0.1.0",
                },
                "capabilities": {
                    "experimentalApi": true,
                }
            }
        });

        sink.send(UpstreamMessage::Text(serde_json::to_string(&init)?))
            .await
            .context("initialize send failed")?;

        let init_deadline = tokio::time::Instant::now()
            + Duration::from_secs_f64(CODEX_UPSTREAM_INIT_TIMEOUT_SECONDS);
        let result = loop {
            let now = tokio::time::Instant::now();
            if now >= init_deadline {
                return Err(anyhow!("initialize timed out"));
            }

            let remaining = init_deadline - now;
            let msg = tokio::time::timeout(remaining, stream.next())
                .await
                .context("initialize recv timeout")?
                .ok_or_else(|| anyhow!("codex websocket closed during initialize"))?
                .context("codex websocket recv failed")?;

            match msg {
                UpstreamMessage::Text(text) => {
                    let Ok(Value::Object(obj)) = serde_json::from_str::<Value>(&text) else {
                        continue;
                    };
                    let matches_id = match obj.get("id") {
                        Some(Value::String(id)) => id == INIT_ID,
                        _ => false,
                    };
                    if !matches_id {
                        continue;
                    }
                    if obj.contains_key("error") {
                        return Err(anyhow!("initialize returned error: {text}"));
                    }
                    break obj.get("result").cloned().unwrap_or(Value::Null);
                }
                UpstreamMessage::Close(_) => {
                    return Err(anyhow!("codex closed websocket during initialize"));
                }
                _ => continue,
            }
        };

        let initialized =
            serde_json::json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} });
        sink.send(UpstreamMessage::Text(serde_json::to_string(&initialized)?))
            .await
            .context("initialized send failed")?;
        Ok(result)
    }

    pub(super) async fn handle_control_text(
        self: &Arc<Self>,
        raw: String,
        origin: NotificationOrigin,
    ) {
        log_diagnostic_ws_frame("codex->gateway", None, &raw);
        let parsed = serde_json::from_str::<Value>(&raw).ok();
        if let Some(message) = parsed.as_ref() {
            if self.side_question_forks.route(message) {
                return;
            }
            if self.handle_external_refresh(message).await {
                return;
            }
            self.handle_external_account_update(message);
            if self.questions.passive_only(message).await {
                let thread = notification_thread_id(message).unwrap_or_default();
                let owns_execution = self
                    .core
                    .lock()
                    .await
                    .recovered_turn_keys
                    .iter()
                    .any(|key| key.thread_id() == thread);
                if !owns_execution
                    && matches!(message["method"].as_str(), Some(method) if method.starts_with("item/") || method.starts_with("turn/"))
                {
                    self.questions.ingest(message).await;
                    return;
                }
            }
            if message["method"] == "thread/status/changed" {
                self.questions.ingest(message).await;
            }
        }
        self.record_restart_recovery_notification(&raw).await;
        if let Some(message) = parsed.as_ref() {
            self.handle_app_server_status_notification(message).await;
        }
        let realtime_route = if let Some(message) = parsed.as_ref()
            && let Some(method) = realtime_notification_method(message)
        {
            let thread_id = notification_thread_id(message);
            let owner_client_id = thread_id
                .as_deref()
                .and_then(|thread| self.voice.owner_client_of_realtime_thread(thread));
            Some((method.to_string(), thread_id, owner_client_id))
        } else {
            None
        };
        self.handle_voice_control_notification(&raw).await;
        let notification_sequence = match parsed.as_ref() {
            Some(message) if message.get("method").is_some() => {
                self.record_agent_notification_value(&raw, message, origin)
                    .await
            }
            _ => None,
        };

        // Codex asking the gateway to run one of its own tools. Answered here
        // and never broadcast: no client declared these, so no client can
        // answer them, and an unanswered request stalls the turn.
        if raw.contains("item/tool/call")
            && let Ok(message) = serde_json::from_str::<Value>(&raw)
            && let Some(call) = crate::agents::tools::codex_tool_call(&message)
        {
            match self.control.current() {
                Some(generation) => {
                    let gateway = Arc::clone(self);
                    let reply_tx = generation.out_tx.clone();
                    generation.spawn("codex tool call", async move {
                        gateway.answer_codex_tool_call(reply_tx, call).await;
                        Ok(())
                    });
                }
                None => warn!("dropping Codex tool call: control connection unavailable"),
            }
            return;
        }

        // Recovered turns are subscribed through this persistent connection. It
        // has no interactive UI, so fail closed instead of silently dropping a
        // later approval or input request and leaving the turn hung forever.
        if let Ok(message) = serde_json::from_str::<Value>(&raw)
            && let Some(method) = message.get("method").and_then(Value::as_str)
            && let Some(id) = message.get("id")
            && (id.is_string() || id.is_number())
        {
            if !self.recovery_control_owns_request(&message).await {
                return;
            }
            warn!(
                method,
                "rejecting interactive request on recovery control connection"
            );
            let response = match serde_json::to_string(&serde_json::json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": {
                    "code": RpcCode::Internal.value(),
                    "message": format!(
                        "RemoteCoder recovery control cannot answer {method}; request rejected"
                    ),
                },
            })) {
                Ok(response) => response,
                Err(error) => {
                    warn!(method, %error, "failed to encode recovery control rejection");
                    return;
                }
            };
            if let Err(error) = self.send_control_text(response).await {
                warn!(method, %error, "failed to reject recovery control request");
            }
            return;
        }

        // Responses on this connection belong only to gateway-owned control work.
        if raw.contains("\"id\"")
            && let Ok(Value::Object(mut obj)) = serde_json::from_str::<Value>(&raw)
        {
            let has_method = obj.get("method").is_some();
            if let Some(Value::String(control_id)) = obj.get("id").cloned()
                && let Some(reply) = self
                    .control_requests
                    .lock()
                    .expect("control replies poisoned")
                    .remove(&control_id)
            {
                let result = match obj.remove("error") {
                    Some(error) => Err(error.to_string()),
                    None => Ok(obj.remove("result").unwrap_or(Value::Null)),
                };
                let _ = reply.send(result);
                return;
            }

            // A response from the control connection is never a client response.
            if !has_method {
                return;
            }
        }

        // Hosted realtime notifications reach the client only through this
        // owner-aware control route, never through its proxy connection.
        if let Some((method, thread_id, owner_client_id)) = realtime_route {
            if let Some(owner_client_id) = owner_client_id
                && let Some(tx) = self
                    .clients
                    .get(&owner_client_id)
                    .map(|entry| entry.value().clone())
            {
                let payload = match parsed.as_ref() {
                    Some(message) => {
                        let compacted = match compact_notification(
                            &raw,
                            message,
                            self.tool_media.as_ref(),
                        )
                        .await
                        {
                            Ok(compacted) => compacted,
                            Err(error) => {
                                warn!(owner_client_id, %error, "failed to encode control notification");
                                return;
                            }
                        };
                        let (frame, client_message) = match compacted {
                            Some((frame, compacted)) => (frame, Some(compacted)),
                            None => (ClientFrame::from_raw(&raw), None),
                        };
                        match frame.stamp(
                            client_message.as_ref().unwrap_or(message),
                            notification_sequence,
                        ) {
                            Ok(payload) => payload,
                            Err(error) => {
                                warn!(owner_client_id, %error, "failed to annotate control notification");
                                return;
                            }
                        }
                    }
                    None => ClientFrame::from_text(raw),
                };
                if let Some(text) = payload.text() {
                    log_diagnostic_ws_frame("gateway->client", Some(owner_client_id), text);
                    self.journal
                        .notify_client(Source::Codex, owner_client_id, &Arc::from(text));
                }
                let _ = self
                    .deliver_awaiting_capacity(&tx, payload.into_command())
                    .await;
            } else {
                debug!(%method, ?thread_id, "dropping unowned realtime notification");
            }
            return;
        }

        debug!("dropping unowned Codex control notification");
    }

    async fn recovery_control_owns_request(&self, message: &Value) -> bool {
        let Some(thread_id) = message.pointer("/params/threadId").and_then(Value::as_str) else {
            return false;
        };
        let Some(turn_id) = message.pointer("/params/turnId").and_then(Value::as_str) else {
            return false;
        };
        self.core
            .lock()
            .await
            .recovered_turn_keys
            .contains(&TurnKey::new(thread_id, turn_id))
    }

    /// Runs one Codex dynamic-tool call and returns its result upstream.
    async fn answer_codex_tool_call(
        self: &Arc<Self>,
        reply_tx: mpsc::Sender<String>,
        call: crate::agents::tools::CodexToolCall,
    ) {
        let tool = call.tool.clone();
        match self.codex_tool_response(call).await {
            Ok(payload) => {
                if let Err(error) = send_control_frame(&reply_tx, payload).await {
                    warn!(%tool, %error, "answering Codex tool call failed");
                }
            }
            Err(error) => warn!(%tool, %error, "encoding tool result failed"),
        }
    }

    pub(super) async fn answer_codex_tool_call_on(
        self: &Arc<Self>,
        upstream_tx: mpsc::Sender<UpstreamMessage>,
        call: crate::agents::tools::CodexToolCall,
    ) {
        let tool = call.tool.clone();
        match self.codex_tool_response(call).await {
            Ok(payload) => {
                if let Err(error) = send_client_upstream(&upstream_tx, payload).await {
                    warn!(%tool, %error, "answering client-scoped Codex tool call failed");
                }
            }
            Err(error) => warn!(%tool, %error, "encoding tool result failed"),
        }
    }

    pub(super) async fn codex_tool_response(
        self: &Arc<Self>,
        call: crate::agents::tools::CodexToolCall,
    ) -> Result<String> {
        let outcome = match (&call.thread_id, &call.call_id) {
            (Some(thread), Some(call_id)) if !thread.is_empty() && !call_id.is_empty() => {
                let key = (thread.clone(), call_id.clone());
                match self.tool_claims.claim(&key) {
                    Err(outcome) => Arc::new(outcome),
                    Ok((mut receiver, first)) => {
                        if first {
                            let gateway = Arc::clone(self);
                            let work_call = call.clone();
                            let work_key = key.clone();
                            if !self.tool_tasks.spawn_graceful("registry tool call", move |shutdown| async move {
                                use futures_util::FutureExt;
                                let caller = crate::agents::tools::Caller {
            turn_id: work_call.turn_id,
                                    provider: crate::providers::Provider::Codex,
                                    thread_id: work_call.thread_id,
                                };
                                let work = crate::agents::tools::dispatch(&gateway, &work_call.tool, &work_call.arguments, &caller);
                                let outcome = tokio::select! {
                                    result = std::panic::AssertUnwindSafe(work).catch_unwind() => result.unwrap_or_else(|_| crate::agents::tools::ToolOutcome::error("RemoteCoder tool execution failed.")),
                                    _ = shutdown.cancelled() => crate::agents::tools::ToolOutcome::error("RemoteCoder is stopping; tool execution was cancelled."),
                                };
                                gateway.tool_claims.complete(&work_key, outcome);
                                Ok(())
                            }) {
                                self.tool_claims.complete(&key, crate::agents::tools::ToolOutcome::error("RemoteCoder is stopping; tool execution was cancelled."));
                            }
                        }
                        loop {
                            let outcome = receiver.borrow_and_update().clone();
                            if let Some(outcome) = outcome {
                                break outcome;
                            }
                            if receiver.changed().await.is_err() {
                                break Arc::new(crate::agents::tools::ToolOutcome::error(
                                    "RemoteCoder lost the tool result.",
                                ));
                            }
                        }
                    }
                }
            }
            _ => Arc::new(crate::agents::tools::ToolOutcome::error(
                "Codex tool call is missing its exact thread or call identity.",
            )),
        };
        let response = render_codex_tool_response(&call.id, &outcome);
        Ok(serde_json::to_string(&response)?)
    }
    pub(super) async fn call_control(&self, method: &str, params: Value) -> Result<Value> {
        self.call_control_with_timeout(
            method,
            params,
            Duration::from_secs_f64(UPSTREAM_SEND_TIMEOUT_SECONDS),
        )
        .await
    }

    pub(super) async fn call_control_with_timeout(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value> {
        let (reply_rx, _pending) = self.begin_control_call(method, params).await?;
        tokio::time::timeout(timeout, reply_rx)
            .await
            .context("codex internal JSON-RPC timed out")?
            .context("codex internal JSON-RPC response channel closed")?
            .map_err(anyhow::Error::msg)
    }

    pub(super) async fn call_control_unadmitted(
        &self,
        method: &str,
        params: Value,
    ) -> Result<Value> {
        let (reply_rx, _pending) = self.send_control_call(method, params).await?;
        tokio::time::timeout(
            Duration::from_secs_f64(UPSTREAM_SEND_TIMEOUT_SECONDS),
            reply_rx,
        )
        .await
        .context("codex internal JSON-RPC timed out")?
        .context("codex internal JSON-RPC response channel closed")?
        .map_err(anyhow::Error::msg)
    }

    async fn begin_control_call(
        &self,
        method: &str,
        mut params: Value,
    ) -> Result<(
        oneshot::Receiver<Result<Value, String>>,
        PendingControlReply<'_>,
    )> {
        self.admit_native(method, &mut params)
            .await
            .map_err(|error| super::external_providers::admission_failure(&error))?;
        self.send_control_call(method, params).await
    }

    async fn send_control_call(
        &self,
        method: &str,
        params: Value,
    ) -> Result<(
        oneshot::Receiver<Result<Value, String>>,
        PendingControlReply<'_>,
    )> {
        let seq = self.next_control_request_id.fetch_add(1, Ordering::Relaxed);
        let control_id = format!("gw:internal:{seq}");
        let (reply_tx, reply_rx) = oneshot::channel();
        self.control_requests
            .lock()
            .expect("control replies poisoned")
            .insert(control_id.clone(), reply_tx);
        let pending = PendingControlReply {
            id: control_id.clone(),
            replies: &self.control_requests,
        };
        let request = json!({"jsonrpc":"2.0", "id":control_id, "method":method, "params":params});
        self.send_control_text(serde_json::to_string(&request)?)
            .await?;
        Ok((reply_rx, pending))
    }

    pub(super) async fn call_control_until_reply(
        &self,
        method: &str,
        params: Value,
    ) -> crate::rpc::RpcResult {
        let (reply_rx, _pending) = self
            .begin_control_call(method, params)
            .await
            .map_err(|error| super::agent_gateway::native_error(&error))?;
        match reply_rx.await {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(error)) => Err(serde_json::from_str::<Value>(&error)
                .map(|error| crate::rpc::RpcError::from_wire(&error))
                .unwrap_or_else(|_| crate::rpc::RpcError::from(anyhow!(error)))),
            Err(error) => Err(anyhow!("Codex rename response channel closed: {error}").into()),
        }
    }

    pub(super) async fn handle_app_server_status_notification(self: &Arc<Self>, message: &Value) {
        if message.get("method").and_then(Value::as_str) != Some("thread/status/changed") {
            return;
        }
        let Some(thread_id) = message
            .pointer("/params/threadId")
            .and_then(Value::as_str)
            .map(str::to_string)
        else {
            return;
        };
        let Some(status) = message
            .pointer("/params/status/type")
            .and_then(Value::as_str)
        else {
            return;
        };
        let (generation, possibly_ended) = {
            let mut core = self.core.lock().await;
            let generation = core
                .app_server_inventory_generation_by_thread
                .entry(thread_id.clone())
                .or_default();
            *generation = generation.wrapping_add(1);
            let current = *generation;
            if status == "active" {
                core.app_server_inventory_unresolved_threads
                    .insert(thread_id.clone());
                (current, Vec::new())
            } else {
                core.app_server_active_turns_by_thread.remove(&thread_id);
                core.app_server_inventory_unresolved_threads
                    .remove(&thread_id);
                let tracked = core
                    .turns
                    .active()
                    .filter(|turn| {
                        turn.thread_id == thread_id && is_durable_codex_thread(&turn.thread_id)
                    })
                    .cloned()
                    .collect::<Vec<_>>();
                (current, tracked)
            }
        };
        self.activity.mark_changed();
        let Some(control) = self.control.current() else {
            return;
        };
        if !possibly_ended.is_empty() {
            let gateway = Arc::clone(self);
            let thread_id = thread_id.clone();
            control.spawn("reconcile ended turns", async move {
                gateway
                    .finish_turns_the_app_server_ended(&thread_id, possibly_ended)
                    .await
                    .with_context(|| {
                        format!("failed to reconcile tracked turns of inactive thread {thread_id}")
                    })
            });
        }
        if status == "active" {
            let gateway = Arc::clone(self);
            control.spawn("resolve active turn", async move {
                gateway
                    .refresh_app_server_active_turn(thread_id.clone(), generation)
                    .await
                    .with_context(|| {
                        format!("failed to resolve active app-server turn of {thread_id}")
                    })
            });
        }
    }

    pub(super) async fn refresh_app_server_active_turn(
        &self,
        thread_id: String,
        expected_generation: u64,
    ) -> Result<()> {
        let response = self
            .call_control(
                "thread/turns/list",
                serde_json::json!({
                    "threadId": &thread_id,
                    "limit": 1,
                    "sortDirection": "desc",
                    "itemsView": "summary",
                }),
            )
            .await;
        let resolved = match response {
            Ok(response) => {
                let turns = response
                    .get("data")
                    .and_then(Value::as_array)
                    .context("thread/turns/list returned no data array")?;
                Some(active_turn_in(&thread_id, turns)?)
            }
            Err(error) => {
                // Native ephemeral threads, and threads before their first user
                // message, appear in loaded/list but have no paginated history.
                // Only explicit live idle state proves that they contribute no
                // active turn; active/unknown stays unresolved. The gateway's own
                // side-question forks never carry user work.
                let native = serde_json::from_str::<Value>(&error.to_string()).ok();
                let message = native
                    .as_ref()
                    .filter(|error| error["code"] == -32600)
                    .and_then(|error| error["message"].as_str());
                let ephemeral =
                    message == Some("ephemeral threads do not support thread/turns/list");
                let unmaterialized = message
                    == Some(&*format!(
                        "thread {thread_id} is not materialized yet; thread/turns/list is unavailable before first user message"
                    ));
                if !ephemeral && !unmaterialized {
                    return Err(error);
                }
                if self.side_question_forks.owns_thread(&thread_id) {
                    Some(None)
                } else {
                    let read = self
                        .call_control(
                            "thread/read",
                            json!({"threadId": &thread_id, "includeTurns": false}),
                        )
                        .await?;
                    ensure!(
                        unmaterialized || read["thread"]["ephemeral"] == true,
                        "Ephemeral thread activity cannot be resolved"
                    );
                    (read["thread"]["status"]["type"] == "idle").then_some(None)
                }
            }
        };
        let mut core = self.core.lock().await;
        if core
            .app_server_inventory_generation_by_thread
            .get(&thread_id)
            .copied()
            .unwrap_or_default()
            != expected_generation
        {
            return Ok(());
        }
        match resolved {
            Some(Some(active)) => {
                core.app_server_inventory_unresolved_threads
                    .remove(&thread_id);
                core.app_server_active_turns_by_thread
                    .insert(thread_id, active);
            }
            Some(None) => {
                core.app_server_inventory_unresolved_threads
                    .remove(&thread_id);
                core.app_server_active_turns_by_thread.remove(&thread_id);
            }
            None => {
                core.app_server_inventory_unresolved_threads
                    .insert(thread_id);
            }
        }
        self.activity.mark_changed();
        Ok(())
    }

    async fn bootstrap_app_server_active_turns(self: &Arc<Self>) {
        self.core.lock().await.app_server_inventory_bootstrapped = false;
        let mut retry = INVENTORY_BOOTSTRAP_FIRST_RETRY;
        loop {
            match self.resolve_loaded_app_server_threads().await {
                Ok(0) => return,
                Ok(unresolved) => debug!(
                    unresolved,
                    "app-server turn inventory has unresolved threads; retrying in {retry:?}"
                ),
                Err(error) => warn!(
                    "failed to list loaded app-server threads; retrying in {retry:?}: {error:#}"
                ),
            }
            tokio::time::sleep(retry).await;
            retry = (retry * 2).min(INVENTORY_BOOTSTRAP_MAX_RETRY);
        }
    }

    async fn resolve_loaded_app_server_threads(self: &Arc<Self>) -> Result<usize> {
        let generations = self
            .core
            .lock()
            .await
            .app_server_inventory_generation_by_thread
            .clone();
        let mut cursor: Option<String> = None;
        let mut seen_cursors = HashSet::new();
        let mut thread_ids = Vec::new();
        loop {
            let mut params = serde_json::json!({"limit": 100});
            if let Some(cursor) = cursor.as_deref() {
                params["cursor"] = Value::String(cursor.to_string());
            }
            let response = self.call_control("thread/loaded/list", params).await?;
            let page = response
                .get("data")
                .and_then(Value::as_array)
                .context("thread/loaded/list returned no data array")?;
            for entry in page {
                thread_ids.push(
                    entry
                        .as_str()
                        .context("thread/loaded/list returned a non-string thread id")?
                        .to_string(),
                );
            }
            let Some(next_cursor) = response
                .get("nextCursor")
                .and_then(Value::as_str)
                .map(str::to_string)
            else {
                break;
            };
            if !seen_cursors.insert(next_cursor.clone()) {
                bail!("thread/loaded/list repeated a pagination cursor");
            }
            cursor = Some(next_cursor);
            if thread_ids.len() > 10_000 {
                bail!("loaded thread inventory exceeded safety bound");
            }
        }

        for thread_id in thread_ids {
            let generation = generations.get(&thread_id).copied().unwrap_or_default();
            let Err(error) = self
                .refresh_app_server_active_turn(thread_id.clone(), generation)
                .await
            else {
                continue;
            };
            let mut core = self.core.lock().await;
            if core
                .app_server_inventory_generation_by_thread
                .get(&thread_id)
                .copied()
                .unwrap_or_default()
                != generation
            {
                continue;
            }
            warn!(
                thread_id,
                "failed to resolve app-server turn inventory: {error:#}"
            );
            core.app_server_inventory_unresolved_threads
                .insert(thread_id);
        }
        let unresolved = {
            let mut core = self.core.lock().await;
            core.app_server_inventory_bootstrapped = true;
            core.app_server_inventory_unresolved_threads.len()
        };
        self.activity.mark_changed();
        Ok(unresolved)
    }

    async fn clear_app_server_turn_inventory(&self) {
        let mut core = self.core.lock().await;
        core.app_server_inventory_bootstrapped = false;
        core.app_server_active_turns_by_thread.clear();
        core.app_server_inventory_unresolved_threads.clear();
        for generation in core.app_server_inventory_generation_by_thread.values_mut() {
            *generation = generation.wrapping_add(1);
        }
        self.activity.mark_changed();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;

    #[tokio::test]
    async fn retiring_a_generation_stops_its_work_before_the_next_one_is_published() {
        let control = ControlConnection::default();
        let (tx, _rx) = mpsc::channel(1);
        let generation = control.publish(tx);
        let (started_tx, started_rx) = oneshot::channel();
        let published = Arc::new(AtomicBool::new(false));
        let stale = Arc::clone(&published);
        assert!(generation.spawn("stale inventory", async move {
            started_tx.send(()).expect("test receiver");
            std::future::pending::<()>().await;
            stale.store(true, Ordering::SeqCst);
            Ok(())
        }));
        started_rx.await.expect("work started");

        control.retire().await;

        assert!(control.current().is_none());
        assert!(!generation.spawn("late work", async { Ok(()) }));
        assert!(!published.load(Ordering::SeqCst));
        let (tx, _rx) = mpsc::channel(1);
        assert!(
            control
                .publish(tx)
                .spawn("next generation", async { Ok(()) })
        );
    }

    #[tokio::test]
    async fn a_malformed_turn_page_leaves_the_thread_unresolved() {
        for page in [
            json!({}),
            json!({"data": "none"}),
            json!({"data": [{"id": "turn"}]}),
            json!({"data": [{"status": "inProgress"}]}),
        ] {
            let gateway = crate::test_support::TestGateway::new();
            gateway.core.lock().await.app_server_inventory_bootstrapped = true;
            let mut control = crate::test_support::FakeControl::attach(&gateway, 1).await;
            let worker_gateway = gateway.clone();
            let worker = tokio::spawn(async move {
                worker_gateway
                    .refresh_app_server_active_turn("thread".into(), 0)
                    .await
            });
            let request: Value =
                serde_json::from_str(&control.requests.recv().await.expect("turn page request"))
                    .expect("request JSON");
            gateway
                .handle_control_text(
                    json!({"id": request["id"], "result": page}).to_string(),
                    NotificationOrigin::Control { opened_after: 0 },
                )
                .await;
            assert!(worker.await.expect("refresh task").is_err(), "{page}");
            assert!(
                gateway
                    .core
                    .lock()
                    .await
                    .app_server_active_turns_by_thread
                    .is_empty()
            );
        }
    }

    async fn next_request(control: &mut crate::test_support::FakeControl, method: &str) -> Value {
        let request: Value =
            serde_json::from_str(&control.requests.recv().await.expect("inventory request"))
                .expect("request JSON");
        assert_eq!(request["method"], method, "{request}");
        request
    }

    async fn reply(gateway: &Arc<Gateway>, request: Value, mut response: Value) {
        response["id"] = request["id"].clone();
        gateway
            .handle_control_text(
                response.to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
    }

    #[tokio::test(start_paused = true)]
    async fn the_bootstrap_retries_until_no_loaded_thread_is_unknown() {
        let gateway = crate::test_support::TestGateway::new();
        let mut control = crate::test_support::FakeControl::attach(&gateway, 1).await;
        let worker_gateway = gateway.clone();
        let bootstrap =
            tokio::spawn(async move { worker_gateway.bootstrap_app_server_active_turns().await });
        let idle_page = json!({"result": {"data": [{"id": "turn", "status": "completed"}]}});
        let unmaterialized = json!({"error": {"code": -32600, "message": "thread fresh is not materialized yet; thread/turns/list is unavailable before first user message"}});

        let list = next_request(&mut control, "thread/loaded/list").await;
        reply(
            &gateway,
            list,
            json!({"result": {"data": ["gone", "flaky", "fresh", "idle"]}}),
        )
        .await;
        gateway
            .handle_app_server_status_notification(&json!({
                "method": "thread/status/changed",
                "params": {"threadId": "gone", "status": {"type": "notLoaded"}}
            }))
            .await;
        let gone = next_request(&mut control, "thread/turns/list").await;
        reply(
            &gateway,
            gone,
            json!({"error": {"code": -32600, "message": "thread not loaded: gone"}}),
        )
        .await;
        let flaky = next_request(&mut control, "thread/turns/list").await;
        reply(
            &gateway,
            flaky,
            json!({"error": {"code": -32603, "message": "failed to read thread"}}),
        )
        .await;
        let fresh = next_request(&mut control, "thread/turns/list").await;
        reply(&gateway, fresh, unmaterialized.clone()).await;
        let fresh = next_request(&mut control, "thread/read").await;
        reply(
            &gateway,
            fresh,
            json!({"result": {"thread": {"status": {"type": "active"}}}}),
        )
        .await;
        let idle = next_request(&mut control, "thread/turns/list").await;
        reply(&gateway, idle, idle_page.clone()).await;

        let retry = next_request(&mut control, "thread/loaded/list").await;
        assert_eq!(gateway.reported_active_turn_status().await, (0, false));
        assert_eq!(
            gateway
                .core
                .lock()
                .await
                .app_server_inventory_unresolved_threads,
            HashSet::from(["flaky".to_string(), "fresh".to_string()])
        );
        reply(
            &gateway,
            retry,
            json!({"result": {"data": ["flaky", "fresh"]}}),
        )
        .await;
        let flaky = next_request(&mut control, "thread/turns/list").await;
        reply(&gateway, flaky, idle_page).await;
        let fresh = next_request(&mut control, "thread/turns/list").await;
        reply(&gateway, fresh, unmaterialized.clone()).await;
        let fresh = next_request(&mut control, "thread/read").await;
        reply(
            &gateway,
            fresh,
            json!({"result": {"thread": {"status": {"type": "active"}}}}),
        )
        .await;

        let retry = next_request(&mut control, "thread/loaded/list").await;
        assert_eq!(
            gateway
                .core
                .lock()
                .await
                .app_server_inventory_unresolved_threads,
            HashSet::from(["fresh".to_string()])
        );
        reply(&gateway, retry, json!({"result": {"data": ["fresh"]}})).await;
        let fresh = next_request(&mut control, "thread/turns/list").await;
        reply(&gateway, fresh, unmaterialized).await;
        let fresh = next_request(&mut control, "thread/read").await;
        reply(
            &gateway,
            fresh,
            json!({"result": {"thread": {"status": {"type": "idle"}}}}),
        )
        .await;

        bootstrap.await.expect("bootstrap task");
        assert_eq!(gateway.reported_active_turn_status().await, (0, true));
    }

    #[test]
    fn a_completed_turn_page_proves_the_thread_idle() {
        let turns = [json!({"id": "turn", "status": "completed"})];
        assert!(
            active_turn_in("thread", &turns)
                .expect("well-formed page")
                .is_none()
        );
        let running = [json!({"id": "turn", "status": "inProgress", "startedAt": 5.0})];
        let active = active_turn_in("thread", &running)
            .expect("well-formed page")
            .expect("running turn");
        assert_eq!(active.turn_id, "turn");
    }
}

fn render_codex_tool_response(id: &Value, outcome: &crate::agents::tools::ToolOutcome) -> Value {
    use crate::agents::tools::ToolContent;
    serde_json::json!({"jsonrpc": "2.0", "id": id, "result": {
        "success": !outcome.is_error,
        "contentItems": outcome.content.iter().map(|content| match content {
            ToolContent::Text { text } => serde_json::json!({"type": "inputText", "text": text}),
            ToolContent::Image { mime_type, base64 } => serde_json::json!({"type": "inputImage", "imageUrl": format!("data:{mime_type};base64,{base64}")}),
        }).collect::<Vec<_>>(),
    }})
}

#[cfg(test)]
mod tool_projection_tests {
    use super::*;
    use crate::agents::tools::{ToolContent, ToolOutcome};

    #[test]
    fn provider_projections_preserve_text_and_inline_images_in_order() {
        let outcome = ToolOutcome {
            content: vec![
                ToolContent::Text {
                    text: "Captured photo".into(),
                },
                ToolContent::Image {
                    mime_type: "image/jpeg".into(),
                    base64: "cGhvdG8=".into(),
                },
            ],
            is_error: false,
            detail: None,
        };
        let id = serde_json::json!(7);
        let codex = render_codex_tool_response(&id, &outcome);
        assert_eq!(
            codex["result"],
            serde_json::json!({"success":true, "contentItems":[
                {"type":"inputText","text":"Captured photo"},
                {"type":"inputImage","imageUrl":"data:image/jpeg;base64,cGhvdG8="}
            ]})
        );
        let claude = crate::agents::mcp::tool_response(&id, &outcome);
        assert_eq!(
            claude["result"],
            serde_json::json!({"resultType":"complete","isError":false,"content":[
                {"type":"text","text":"Captured photo"},
                {"type":"image","mimeType":"image/jpeg","data":"cGhvdG8="}
            ]})
        );
        assert_eq!(
            outcome.audit(),
            serde_json::json!({"text":"Captured photo","imageCount":1,"imageBytes":8})
        );
    }
}
