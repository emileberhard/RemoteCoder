use super::{
    CLIENT_OUTBOUND_QUEUE_SIZE, CLIENT_UPSTREAM_QUEUE_SIZE, ClientCommand, ClientRequests,
    ClientTx, Gateway, NativeRequest, SEND_TIMEOUT_SECONDS, TRANSPORT_ERROR_CLOSE_TIMEOUT,
    UPSTREAM_SEND_TIMEOUT_SECONDS, UpstreamFrame, VoiceRequest, account_context,
    send_client_upstream,
};
use crate::notifications::history::NotificationOrigin;
use crate::notifications::realtime_notification_method;
use crate::observability::journal::Source;
use crate::providers::codex::daemon::{CodexWebSocket, MAX_WEBSOCKET_BYTES};
use crate::rpc::dispatch::{
    ClientRequest, DispatchPlan, OwnedRoute, OwnedTarget, RequestLifetime, starts_new_work,
};
use crate::rpc::error::{RpcCode, RpcData};
use crate::rpc::upstream_errors::tag_upstream_error;
use crate::rpc::{
    HISTORY_PAGE_RESPONSE_BUDGET, MAX_PENDING_REQUESTS, PendingRequest, PendingRequests, RpcError,
    TransportCapacityError, correlated_method, log_diagnostic_ws_frame,
    oversized_history_page_error, prune_pending_requests,
};
use anyhow::{Context, Result, anyhow};
use axum::extract::ws::{CloseFrame, Message, WebSocket};
use futures_util::{FutureExt, SinkExt, StreamExt};
use serde_json::Value;
#[cfg(test)]
use serde_json::json;
use std::borrow::Cow;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinSet;
use tokio_tungstenite::tungstenite::Message as UpstreamMessage;
use tracing::{debug, error, info, warn};

const CLIENT_CAPACITY_WAIT: Duration = Duration::from_millis(100);
const CLIENT_CLOSE_WAIT: Duration = Duration::from_millis(750);
const QUERY_DEADLINE: Duration = Duration::from_secs(60);

mod encoding;
pub(super) mod queries;
pub(super) use encoding::{ClientFrame, RejectedFrame};
use queries::{ConnectionQueries, QueryEvent};

pub(super) struct RequestBudgets {
    query: crate::rpc::RequestBudget,
    status: crate::rpc::RequestBudget,
    command: crate::rpc::RequestBudget,
    urgent: crate::rpc::RequestBudget,
}

impl Default for RequestBudgets {
    fn default() -> Self {
        Self {
            query: crate::rpc::RequestBudget::new(32, 16 * 1024 * 1024),
            status: crate::rpc::RequestBudget::new(16, 256 * 1024),
            command: crate::rpc::RequestBudget::new(16, 32 * 1024 * 1024),
            urgent: crate::rpc::RequestBudget::new(8, 1024 * 1024),
        }
    }
}

impl Gateway {
    pub(crate) async fn handle_ws(
        self: Arc<Self>,
        mut socket: WebSocket,
        cancelled: tokio_util::sync::CancellationToken,
        grant: crate::auth::installation_credentials::Grant,
    ) {
        let client_id = self.next_client_id.fetch_add(1, Ordering::Relaxed);
        if self.is_draining() {
            let _ = socket
                .send(Message::Close(Some(super::restarting_close())))
                .await;
            return;
        }
        let waiting_for_codex = !self.codex_ready().await;
        let upstream = if waiting_for_codex {
            None
        } else {
            let upstream_result = tokio::select! {
                result = self.codex.connect_ws() => result,
                _ = cancelled.cancelled() => return,
            };
            upstream_result
                .inspect_err(|error| {
                    warn!(client_id, %error, "Codex client connection failed; serving without Codex");
                })
                .ok()
        };
        let (notification_epoch, opened_after) = self.notification_position().await;
        let notification_origin = NotificationOrigin::Client {
            id: client_id,
            opened_after,
        };
        let (tx, out_rx) = mpsc::channel::<ClientCommand>(CLIENT_OUTBOUND_QUEUE_SIZE);
        let (lane_tx, lane_rx) = mpsc::channel::<UpstreamFrame>(CLIENT_UPSTREAM_QUEUE_SIZE);
        let out_tx = ClientTx {
            query_response: None,
            content_subscriptions: Arc::default(),
            installation_id: match grant {
                crate::auth::installation_credentials::Grant::Installation { id, .. } => Some(id),
                crate::auth::installation_credentials::Grant::Operator => None,
            },
            id: client_id,
            tx,
            closed: cancelled.clone(),
        };
        if self.device_tools.connected(out_tx.clone()).is_err() {
            let _ = socket
                .send(Message::Close(Some(CloseFrame {
                    code: 1013,
                    reason: Cow::Borrowed("Device connection capacity reached"),
                })))
                .await;
            return;
        }
        let ready = serde_json::json!({
            "notificationEpoch": notification_epoch,
            "notificationSequence": opened_after,
            "capabilities": {"cancelRequest": true}
        });
        self.admit_client(&out_tx, upstream.is_none(), ready);
        if waiting_for_codex && self.codex_ready().await {
            self.close_degraded_clients();
        }

        info!(
            client_id,
            count = self.clients.len(),
            degraded = upstream.is_none(),
            "client connected"
        );
        self.journal
            .client_event(client_id, "connect", None, self.clients.len());

        let (client_sink, client_stream) = socket.split();

        let pending_requests: PendingRequests = Arc::default();
        let queries = Arc::new(crate::tasks::owned_tasks::OwnedTasks::default());
        let (voice_tx, mut voice_rx) = mpsc::channel::<VoiceRequest>(8);
        let voice_closed = tokio_util::sync::CancellationToken::new();
        let (voice_done, voice_finished) = oneshot::channel();
        let gateway = Arc::clone(&self);
        let voice_out = out_tx.clone();
        let connection_closed = voice_closed.clone();
        if !self.voice_tasks.spawn_graceful("connection voice lifecycle", move |shutdown| async move {
            loop {
                let request = tokio::select! {
                    biased;
                    _ = shutdown.cancelled() => break,
                    _ = connection_closed.cancelled() => break,
                    request = voice_rx.recv() => match request { Some(request) => request, None => break },
                };
                // TCP order is retained. Once starting media, finish that owned
                // operation before disconnected-client cleanup can stop it.
                let VoiceRequest { method, object, .. } = &request;
                match gateway.validate_dispatch(method, object).await {
                    Ok(()) => (),
                    Err(error) => {
                        let _ = gateway.send_error_to(&voice_out, object.get("id"), &error).await;
                        continue;
                    }
                };
                if gateway.is_draining() && starts_new_work(method) {
                    let _ = gateway.reject_draining(&voice_out, object.get("id")).await;
                } else if let Err(error) = gateway.handle_voice_rpc(client_id, &voice_out, method, object).await {
                    warn!(client_id, %error, "voice request failed");
                }
            }
            if let Err(error) = gateway.stop_voice_session(client_id).await {
                warn!(client_id, %error, "disconnected voice cleanup failed");
            }
            let _ = voice_done.send(());
            Ok(())
        }) {
            self.device_tools.disconnected(client_id);
            self.forget_degraded_client(client_id);
            self.clients.remove(&client_id);
            return;
        }
        let mut tasks = JoinSet::new();
        let mut writer = JoinSet::new();
        {
            let gw = Arc::clone(&self);
            let task_gw = Arc::clone(&gw);
            let closing = cancelled.clone();
            writer.spawn(task_gw.run_task_logged("client_writer_loop", async move {
                gw.client_writer_loop(client_id, client_sink, out_rx, closing)
                    .await
            }));
        }

        {
            let gw = Arc::clone(&self);
            let out_tx = out_tx.clone();
            let queries = Arc::clone(&queries);
            let task_gw = Arc::clone(&gw);
            tasks.spawn(task_gw.run_task_logged("client_reader_loop", async move {
                gw.client_to_codex_loop(
                    client_id,
                    client_stream,
                    ClientRequests {
                        out_tx,
                        lane_tx,
                        voice_tx,
                        queries,
                    },
                )
                .await
            }));
        }

        let upstream_tx = upstream.map(|upstream| {
            let (upstream_tx, upstream_rx) =
                mpsc::channel::<UpstreamMessage>(CLIENT_UPSTREAM_QUEUE_SIZE);
            let (upstream_sink, upstream_stream) = upstream.split();
            let gw = Arc::clone(&self);
            let task_gw = Arc::clone(&gw);
            tasks.spawn(
                task_gw.run_task_logged("client_upstream_writer_loop", async move {
                    gw.client_upstream_writer_loop(client_id, upstream_sink, upstream_rx)
                        .await
                }),
            );
            let gw = Arc::clone(&self);
            let out_tx = out_tx.clone();
            let reader_tx = upstream_tx.clone();
            let pending_requests = Arc::clone(&pending_requests);
            let task_gw = Arc::clone(&gw);
            tasks.spawn(
                task_gw.run_task_logged("client_upstream_reader_loop", async move {
                    gw.codex_to_client_loop(
                        client_id,
                        notification_origin,
                        upstream_stream,
                        out_tx,
                        reader_tx,
                        pending_requests,
                    )
                    .await
                }),
            );
            upstream_tx
        });

        {
            let gw = Arc::clone(&self);
            let out_tx = out_tx.clone();
            let task_gw = Arc::clone(&gw);
            tasks.spawn(task_gw.run_task_logged("client_upstream_lane", async move {
                gw.client_upstream_lane(client_id, out_tx, lane_rx, upstream_tx, pending_requests)
                    .await
            }));
        }

        let writer_finished = tokio::select! {
            _ = writer.join_next() => true,
            _ = tasks.join_next() => false,
            _ = cancelled.cancelled() => false,
        };
        self.device_tools.disconnected(client_id);
        cancelled.cancel();
        tasks.abort_all();
        while tasks.join_next().await.is_some() {}
        if !writer_finished
            && tokio::time::timeout(CLIENT_CLOSE_WAIT, writer.join_next())
                .await
                .is_err()
        {
            writer.abort_all();
            while writer.join_next().await.is_some() {}
            warn!(client_id, "client WebSocket close timed out");
        }
        queries.stop().await;
        voice_closed.cancel();
        let _ = voice_finished.await;

        // A transport failure (broken pipe, reset, ping timeout) already
        // removed the map entry inside the reader/writer loops so fanout
        // stops immediately — but this cleanup runs exactly once per client,
        // so the disconnect is journalled here unconditionally. Gating it on
        // the remove left exactly the abrupt teardowns unrecorded.
        self.questions.client_closed(client_id).await;
        self.forget_degraded_client(client_id);
        self.clients.remove(&client_id);
        info!(client_id, count = self.clients.len(), "client disconnected");
        self.journal
            .client_event(client_id, "disconnect", None, self.clients.len());
        self.spawn_observers_for_client(client_id).await;
    }

    fn bounded_client_text(&self, client_id: u64, text: String) -> Message {
        match ClientFrame::from_text(text) {
            ClientFrame::Text(text) => Message::Text(text),
            ClientFrame::Rejected(rejected) => self.rejected_client_frame(client_id, rejected),
        }
    }

    fn rejected_client_frame(&self, client_id: u64, rejected: RejectedFrame) -> Message {
        self.journal_frame_capacity(client_id, &rejected);
        match rejected.id {
            Some(id) => Message::Text(
                RpcError::new(
                    RpcCode::Capacity,
                    "Response exceeds the connection byte limit",
                )
                .with_data(RpcData::ByteCapacity {
                    resource: rejected.resource,
                    actual_bytes: rejected.bytes,
                    limit: MAX_WEBSOCKET_BYTES,
                })
                .response(&id)
                .to_string(),
            ),
            None => {
                self.clients.remove(&client_id);
                Message::Close(Some(CloseFrame {
                    code: 1009,
                    reason: Cow::Borrowed(
                        "Notification exceeds transport limit; reconnect and read history",
                    ),
                }))
            }
        }
    }

    async fn unavailable_close(&self, reason: &'static str) -> CloseFrame<'static> {
        if self.restart_in_progress().await {
            super::restarting_close()
        } else {
            CloseFrame {
                code: 1013,
                reason: Cow::Borrowed(reason),
            }
        }
    }

    fn journal_frame_capacity(&self, client_id: u64, rejected: &RejectedFrame) {
        self.journal.transport(
            "outboundFrameCapacity",
            serde_json::json!({
                "clientId":client_id,"method":rejected.method,"threadId":rejected.thread,
                "actualBytes":rejected.bytes,"limitBytes":MAX_WEBSOCKET_BYTES,"resource":rejected.resource
            }),
        );
    }

    async fn client_writer_loop(
        &self,
        client_id: u64,
        mut sink: futures_util::stream::SplitSink<WebSocket, Message>,
        mut rx: mpsc::Receiver<ClientCommand>,
        closing: tokio_util::sync::CancellationToken,
    ) {
        let mut ping = tokio::time::interval(Duration::from_secs(20));
        ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

        loop {
            tokio::select! {
                biased;
                _ = closing.cancelled() => {
                    let close = self.unavailable_close("Gateway connection ended; reconnect").await;
                    let code = close.code;
                    let result = sink.send(Message::Close(Some(close))).await;
                    info!(client_id, code, sent = result.is_ok(), "client WebSocket close");
                    return;
                }
                _ = ping.tick() => {
                    match tokio::time::timeout(Duration::from_secs_f64(SEND_TIMEOUT_SECONDS), sink.send(Message::Ping(Vec::new()))).await {
                        Ok(Ok(())) => {}
                        Ok(Err(err)) => {
                            warn!(client_id, ?err, "client ping failed; dropping connection");
                            self.clients.remove(&client_id);
                            return;
                        }
                        Err(_) => {
                            warn!(client_id, "client ping timed out; dropping connection");
                            self.clients.remove(&client_id);
                            return;
                        }
                    }
                }
                cmd = rx.recv() => {
                    let Some(cmd) = cmd else { return; };
                    let msg = match cmd {
                        ClientCommand::Text(text) => self.bounded_client_text(client_id, text),
                        ClientCommand::FrameCapacity(rejected) => self.rejected_client_frame(client_id, rejected),
                        ClientCommand::Pong(p) => Message::Pong(p),
                        ClientCommand::TransportError { payload, flushed } => {
                            // SinkExt::send includes flush. Do not let the reader's
                            // completion abort this writer before the diagnostic leaves.
                            let result = tokio::time::timeout(TRANSPORT_ERROR_CLOSE_TIMEOUT, async {
                                sink.send(Message::Text(payload)).await?;
                                sink.send(Message::Close(Some(CloseFrame {
                                    code: 1009,
                                    reason: Cow::Borrowed("History message exceeds transport limit"),
                                }))).await
                            }).await;
                            if matches!(result, Ok(Ok(()))) {
                                let _ = flushed.send(());
                            }
                            return;
                        }
                        ClientCommand::Close { code, reason } => {
                            let frame = CloseFrame { code, reason: Cow::Owned(reason) };
                            Message::Close(Some(frame))
                        }
                    };

                    let closing = matches!(&msg, Message::Close(_));

                    let res = tokio::time::timeout(Duration::from_secs_f64(SEND_TIMEOUT_SECONDS), async {
                        if let Message::Text(text) = &msg
                            && text.len() > 16 * 1024
                        {
                            sink.send(Message::Text(serde_json::json!({
                                "method":"connection/largeFrame", "params":{"bytes":text.len()}
                            }).to_string())).await?;
                        }
                        sink.send(msg).await
                    }).await;
                    match res {
                        Ok(Ok(())) if closing => return,
                        Ok(Ok(())) => {}
                        Ok(Err(err)) => {
                            warn!(client_id, ?err, "client send failed; dropping connection");
                            self.clients.remove(&client_id);
                            return;
                        }
                        Err(_) => {
                            warn!(client_id, "client send timed out; dropping connection");
                            self.clients.remove(&client_id);
                            return;
                        }
                    }
                }
            }
        }
    }

    async fn client_to_codex_loop(
        self: &Arc<Self>,
        client_id: u64,
        mut stream: futures_util::stream::SplitStream<WebSocket>,
        requests: ClientRequests,
    ) {
        let mut queries = ConnectionQueries::new(
            Arc::clone(self),
            requests.out_tx.clone(),
            Arc::clone(&requests.queries),
        );
        loop {
            let incoming = tokio::select! {
                incoming = stream.next() => incoming,
                event = queries.next() => {
                    match event {
                        QueryEvent::Admitted | QueryEvent::Finished(Ok(())) => {},
                        QueryEvent::Finished(Err(error)) => {
                            warn!(client_id, %error, "gateway query failed");
                        },
                        QueryEvent::Expired(info) => {
                            self.journal.transport("query_timed_out", serde_json::json!({
                                "clientId": client_id, "method": info.method, "threadId": info.thread,
                                "queueDepth": queries.queue_depth(), "limitMs": QUERY_DEADLINE.as_millis(),
                            }));
                            let _ = self.send_error_to(&requests.out_tx, Some(&info.id), &RpcError::request_timed_out(QUERY_DEADLINE)).await;
                        },
                    }
                    continue;
                }
            };
            let received = tokio::time::Instant::now();
            let msg = match incoming {
                Some(Ok(msg)) => msg,
                Some(Err(error)) => {
                    warn!(client_id, %error, "client receive failed; closing connection");
                    return;
                }
                None => {
                    info!(client_id, "client receive stream ended");
                    return;
                }
            };
            match msg {
                Message::Text(raw) => {
                    log_diagnostic_ws_frame("client->gateway", Some(client_id), &raw);
                    self.journal
                        .rpc_request(client_id, &Arc::from(raw.as_str()));
                    match DispatchPlan::parse(&raw) {
                        DispatchPlan::Refuse { id, error } => {
                            let _ = self
                                .send_error_to(&requests.out_tx, Some(&id), &error)
                                .await;
                        }
                        DispatchPlan::ForwardResponse => {
                            if requests
                                .lane_tx
                                .send(UpstreamFrame::Response(raw))
                                .await
                                .is_err()
                            {
                                warn!(
                                    client_id,
                                    "client upstream lane closed; dropping connection"
                                );
                                return;
                            }
                        }
                        DispatchPlan::Request(request) => {
                            if let Err(error) = self
                                .route_request(
                                    client_id,
                                    request,
                                    raw,
                                    &requests,
                                    &mut queries,
                                    received,
                                )
                                .await
                            {
                                warn!(client_id, "client request failed: {error:#}");
                                return;
                            }
                        }
                    }
                }
                Message::Binary(_) => continue,
                Message::Ping(payload) => {
                    let _ = requests.out_tx.try_send(ClientCommand::Pong(payload));
                }
                Message::Pong(_) => continue,
                Message::Close(frame) => {
                    info!(client_id, ?frame, "client requested websocket close");
                    return;
                }
            }
        }
    }

    async fn route_request(
        self: &Arc<Self>,
        client_id: u64,
        request: ClientRequest,
        raw: String,
        requests: &ClientRequests,
        queries: &mut ConnectionQueries,
        received: tokio::time::Instant,
    ) -> Result<()> {
        let ClientRequests {
            out_tx,
            lane_tx,
            voice_tx,
            queries: _,
        } = requests;
        let id = request.object.get("id").cloned();
        if request.method == "$/cancelRequest" {
            if id.is_some() {
                return self
                    .send_error_to(
                        out_tx,
                        id.as_ref(),
                        &RpcError::new(
                            RpcCode::InvalidRequest,
                            "$/cancelRequest must be a notification",
                        ),
                    )
                    .await;
            }
            if let Some(cancel_id) = request
                .object
                .get("params")
                .and_then(|params| params.get("id"))
                && let Some(info) = queries.cancel(cancel_id)
            {
                self.journal.transport(
                    "query_cancelled",
                    serde_json::json!({
                        "clientId": client_id, "method": info.method, "threadId": info.thread,
                        "resource": "connection query", "queueDepth": queries.queue_depth(),
                    }),
                );
                let _ = self
                    .send_error_to(out_tx, Some(&info.id), &queries::cancelled_error())
                    .await;
            }
            return Ok(());
        }
        let admission = match self.admit_request(Some(request.method.as_str()), &request.object) {
            Ok(guard) => guard,
            Err(error) => {
                let _ = self
                    .send_json_awaiting_capacity(
                        out_tx,
                        &account_context::admission_refusal(id.as_ref(), &error),
                    )
                    .await;
                return Ok(());
            }
        };
        debug!(
            client_id,
            method = request.method.as_str(),
            bytes = raw.len(),
            "rpc client->gateway received"
        );
        let Some(owned) = request.owned else {
            return lane_tx
                .send(UpstreamFrame::Request(NativeRequest {
                    raw,
                    request,
                    _admission: admission,
                }))
                .await
                .map_err(|_| anyhow!("client upstream lane closed"));
        };
        let (global, resource) = match owned.lifetime {
            RequestLifetime::Connection => {
                return self
                    .handle_owned_rpc(
                        client_id,
                        out_tx,
                        &request.method,
                        owned.target,
                        &request.object,
                    )
                    .await;
            }
            RequestLifetime::Query => {
                let method = request.method.clone();
                let thread = queries::request_thread(&request.object);
                if let Err(error) = queries.enqueue(request, raw.len(), admission, received) {
                    if let RpcData::ResourceCapacity { resource }
                    | RpcData::ByteCapacity { resource, .. } = &error.data
                    {
                        self.journal.transport(
                            "request_capacity",
                            serde_json::json!({
                                "clientId": client_id, "method": method, "threadId": thread,
                                "resource": resource,
                                "queueDepth": queries.queue_depth(),
                            }),
                        );
                    }
                    let _ = self.send_error_to(out_tx, id.as_ref(), &error).await;
                }
                return Ok(());
            }
            RequestLifetime::Status => (&self.request_budgets.status, "host status reads"),
            RequestLifetime::Command => (&self.request_budgets.command, "host commands"),
            RequestLifetime::Urgent => (&self.request_budgets.urgent, "host urgent requests"),
        };
        let Some(global_permit) = global.try_acquire(raw.len()) else {
            self.journal.transport(
                "request_capacity",
                serde_json::json!({
                    "clientId": client_id, "method": request.method,
                    "threadId": queries::request_thread(&request.object),
                    "resource": resource, "queueDepth": queries.queue_depth(),
                }),
            );
            let _ = self
                .send_error_to(out_tx, id.as_ref(), &queries::capacity_error(resource))
                .await;
            return Ok(());
        };
        let ClientRequest {
            object,
            method,
            starts_new_work,
            ..
        } = request;
        if matches!(owned.target, OwnedTarget::Gateway(OwnedRoute::VoiceSession)) {
            let voice = VoiceRequest {
                method,
                object,
                _permit: global_permit,
                _admission: admission,
            };
            if let Err(error) = voice_tx.try_send(voice) {
                let voice = error.into_inner();
                self.journal.transport("request_capacity", serde_json::json!({
                    "clientId": client_id, "method": voice.method,
                    "threadId": queries::request_thread(&voice.object),
                    "resource": "connection voice queue", "queueDepth": voice_tx.max_capacity() - voice_tx.capacity(),
                }));
                let _ = self
                    .send_error_to(
                        out_tx,
                        voice.object.get("id"),
                        &queries::capacity_error("connection voice queue"),
                    )
                    .await;
            }
            return Ok(());
        }
        let gateway = Arc::clone(self);
        let response_tx = out_tx.clone();
        let work = async move {
            let _admission = admission;
            let _permit = global_permit;
            match gateway.validate_dispatch(&method, &object).await {
                Ok(()) => (),
                Err(error) => {
                    return gateway
                        .send_error_to(&response_tx, object.get("id"), &error)
                        .await;
                }
            };
            if starts_new_work && gateway.is_draining() {
                return gateway
                    .reject_draining(&response_tx, object.get("id"))
                    .await;
            }
            gateway
                .handle_owned_rpc(client_id, &response_tx, &method, owned.target, &object)
                .await
        };
        if !self.command_tasks.spawn("gateway RPC", work) {
            let _ = self.reject_draining(out_tx, id.as_ref()).await;
        }
        Ok(())
    }

    async fn client_upstream_lane(
        self: &Arc<Self>,
        client_id: u64,
        out_tx: ClientTx,
        mut frames: mpsc::Receiver<UpstreamFrame>,
        upstream_tx: Option<mpsc::Sender<UpstreamMessage>>,
        pending_requests: PendingRequests,
    ) {
        while let Some(frame) = frames.recv().await {
            let forwarded = match (frame, &upstream_tx) {
                (UpstreamFrame::Response(raw), Some(upstream_tx)) => {
                    send_client_upstream(upstream_tx, raw)
                        .await
                        .context("forward Codex response failed")
                }
                (UpstreamFrame::Request(request), Some(upstream_tx)) => {
                    self.forward_native_request(
                        client_id,
                        &out_tx,
                        request,
                        upstream_tx,
                        &pending_requests,
                    )
                    .await
                }
                (UpstreamFrame::Response(_), None) => Ok(()),
                (UpstreamFrame::Request(request), None) => {
                    self.answer_without_codex(&out_tx, &request.request).await;
                    Ok(())
                }
            };
            if let Err(error) = forwarded {
                warn!(client_id, "client upstream lane stopped: {error:#}");
                return;
            }
        }
    }

    async fn answer_without_codex(&self, out_tx: &ClientTx, request: &ClientRequest) {
        let Some(id) = request.object.get("id") else {
            return;
        };
        if request.method == "initialize" {
            let _ = self
                .send_json_awaiting_capacity(out_tx, &serde_json::json!({"id": id, "result": {}}))
                .await;
            return;
        }
        let error = RpcError::codex_unavailable(self.codex_unavailable_reason());
        let _ = self.send_error_to(out_tx, Some(id), &error).await;
    }

    async fn forward_native_request(
        &self,
        client_id: u64,
        out_tx: &ClientTx,
        request: NativeRequest,
        upstream_tx: &mpsc::Sender<UpstreamMessage>,
        pending_requests: &PendingRequests,
    ) -> Result<()> {
        let NativeRequest {
            raw,
            request:
                ClientRequest {
                    object,
                    method,
                    starts_new_work,
                    ..
                },
            _admission,
        } = request;
        let id = object.get("id").cloned();
        match self.validate_dispatch(&method, &object).await {
            Ok(()) => (),
            Err(error) => {
                let _ = self.send_error_to(out_tx, id.as_ref(), &error).await;
                return Ok(());
            }
        };
        if starts_new_work && self.is_draining() {
            let _ = self.reject_draining(out_tx, id.as_ref()).await;
            return Ok(());
        }
        let mut object = object;
        let mut params = object.remove("params").unwrap_or(Value::Null);
        let admitted = async {
            if method == "thread/start" {
                self.start_on_fallback(&mut params).await?;
            }
            self.admit_native(&method, &mut params).await
        }
        .await;
        if !params.is_null() {
            object.insert("params".into(), params);
        }
        let rewritten = match admitted {
            Ok(rewritten) => rewritten,
            Err(error) => {
                let _ = self.send_error_to(out_tx, id.as_ref(), &error).await;
                return Ok(());
            }
        };

        if let Some(method) = correlated_method(Some(method.as_str()))
            && let Some(id) = &id
        {
            let mut pending = pending_requests.lock().await;
            prune_pending_requests(&mut pending, Instant::now());
            if pending.len() >= MAX_PENDING_REQUESTS {
                let pending_count = pending.len();
                drop(pending);
                let resource = "connection pending native requests";
                self.journal.transport(
                    "request_capacity",
                    serde_json::json!({
                        "clientId": client_id, "method": method,
                        "threadId": queries::request_thread(&object),
                        "resource": resource, "queueDepth": pending_count,
                    }),
                );
                let mut response = RpcError::new(RpcCode::Capacity, "Too many pending requests")
                    .with_data(RpcData::ResourceCapacity { resource })
                    .response(id);
                response["jsonrpc"] = serde_json::json!("2.0");
                let _ = self.send_json_awaiting_capacity(out_tx, &response).await;
                return Ok(());
            }
            pending.insert(
                id.to_string(),
                PendingRequest::new(method, object.get("params")),
            );
        }
        self.capture_client_request_locked(client_id, &object)
            .await
            .context("failed to persist pending turn start")?;

        let payload = if crate::agents::tools::declare_on_codex_request(&mut object) || rewritten {
            serde_json::to_string(&Value::Object(object))
                .context("encoding Codex request failed")?
        } else {
            raw
        };
        send_client_upstream(upstream_tx, payload)
            .await
            .context("forward to Codex failed")
    }

    pub(super) async fn validate_dispatch(
        &self,
        method: &str,
        object: &serde_json::Map<String, Value>,
    ) -> std::result::Result<(), RpcError> {
        let unavailable = |message: String| RpcError::new(RpcCode::Unavailable, message);
        if let Some(message) = self.account_request_error(method, object).await {
            return Err(unavailable(message));
        }
        if account_context::requires_admission(method, object.get("params").unwrap_or(&Value::Null))
            && !crate::rpc::dispatch::claude_route(method, object)
            && !self.codex_ready().await
        {
            return Err(RpcError::codex_unavailable(self.codex_unavailable_reason()));
        }
        // The empty compaction acknowledgment can precede its turn/started
        // notification. Keep ordinary inputs out of that accepted-command gap;
        // the durable pending ledger already owns disconnect/restart cleanup.
        if matches!(
            method,
            "turn/start"
                | "thread/resume"
                | "turn/steer"
                | "thread/queue/add"
                | "thread/queue/start"
        ) && let Some(thread) = object
            .get("params")
            .and_then(|params| params["threadId"].as_str())
            && self
                .core
                .lock()
                .await
                .turns
                .pending()
                .any(|(_, pending)| pending.thread_id == thread && pending.context.compaction)
        {
            return Err(RpcError::new(
                RpcCode::Conflict,
                "Compaction is starting; wait for it to finish before sending",
            ));
        }
        match self.other_client_refusal(method, object).await {
            Some(refusal) => Err(refusal),
            None => Ok(()),
        }
    }

    async fn send_error_to(
        &self,
        out: &ClientTx,
        id: Option<&Value>,
        error: &RpcError,
    ) -> Result<()> {
        self.send_json_awaiting_capacity(out, &error.response(id.unwrap_or(&Value::Null)))
            .await
    }

    async fn reject_draining(&self, out: &ClientTx, id: Option<&Value>) -> Result<()> {
        let Some(id) = id.filter(|id| !id.is_null()) else {
            return Ok(());
        };
        self.send_error_to(out, Some(id), &RpcError::draining())
            .await
    }

    async fn client_upstream_writer_loop(
        &self,
        client_id: u64,
        mut sink: futures_util::stream::SplitSink<CodexWebSocket, UpstreamMessage>,
        mut rx: mpsc::Receiver<UpstreamMessage>,
    ) {
        while let Some(message) = rx.recv().await {
            if let Err(error) = tokio::time::timeout(
                Duration::from_secs_f64(UPSTREAM_SEND_TIMEOUT_SECONDS),
                sink.send(message),
            )
            .await
            .context("Codex send timed out")
            .and_then(|result| result.context("Codex send failed"))
            {
                warn!(client_id, %error, "client's Codex writer stopped");
                return;
            }
        }
    }

    async fn codex_to_client_loop(
        self: &Arc<Self>,
        client_id: u64,
        notification_origin: NotificationOrigin,
        mut stream: futures_util::stream::SplitStream<CodexWebSocket>,
        out_tx: ClientTx,
        upstream_tx: mpsc::Sender<UpstreamMessage>,
        pending_requests: PendingRequests,
    ) {
        while let Some(frame) = stream.next().await {
            let frame = match frame {
                Ok(frame) => frame,
                Err(error) => {
                    warn!(client_id, %error, "Codex receive failed");
                    if let Some(capacity) = TransportCapacityError::from_upstream(&error) {
                        warn!(
                            client_id,
                            actual_bytes = capacity.actual_bytes,
                            limit_bytes = capacity.limit_bytes,
                            direction = capacity.direction,
                            "upstream WebSocket capacity exceeded"
                        );
                        let notification = serde_json::json!({
                            "method": "daemon/transportError", "params": capacity
                        });
                        let payload = notification.to_string();
                        self.journal.notify_client(
                            Source::Gateway,
                            client_id,
                            &Arc::from(payload.as_str()),
                        );
                        let (flushed, receipt) = oneshot::channel();
                        let delivery = tokio::time::timeout(TRANSPORT_ERROR_CLOSE_TIMEOUT, async {
                            out_tx
                                .tx
                                .send(ClientCommand::TransportError { payload, flushed })
                                .await
                                .map_err(|_| ())?;
                            receipt.await.map_err(|_| ())
                        })
                        .await;
                        if !matches!(delivery, Ok(Ok(()))) {
                            warn!(
                                client_id,
                                "transport capacity diagnostic could not be flushed before close deadline"
                            );
                        }
                    }
                    return;
                }
            };
            match frame {
                UpstreamMessage::Text(raw) => {
                    log_diagnostic_ws_frame("codex->gateway", Some(client_id), &raw);
                    let parsed = serde_json::from_str::<Value>(&raw).ok();

                    let request = if let Some(message) = parsed.as_ref()
                        && message.get("method").is_none()
                        && let Some(id) = message.get("id")
                    {
                        pending_requests.lock().await.remove(&id.to_string())
                    } else {
                        None
                    };
                    if let Some(message) = parsed.as_ref()
                        && message.get("result").is_some()
                        && message.get("error").is_none()
                        && let Some(request) = &request
                        && matches!(request.method, "turn/start" | "turn/steer")
                        && let Some(thread) = &request.thread_id
                    {
                        self.device_tools.record_driver(client_id, thread);
                    }
                    let history_method = request.as_ref().map(|request| request.method);
                    let tagged = parsed
                        .as_ref()
                        .zip(request.as_ref())
                        .and_then(|(message, request)| tag_upstream_error(message, request));
                    let reencode = tagged.is_some();
                    let mut parsed = tagged.or(parsed);
                    if let Some(message) = parsed.as_mut()
                        && message.get("method").is_none()
                    {
                        let compacted =
                            match ClientFrame::compact(message, self.tool_media.as_ref()).await {
                                Ok(frame) => frame,
                                Err(error) => {
                                    warn!(client_id, %error, "failed to compact upstream response");
                                    return;
                                }
                            };
                        let frame = match compacted {
                            Some(frame) => Some(frame),
                            None if reencode => match ClientFrame::encode(message) {
                                Ok(frame) => Some(frame),
                                Err(error) => {
                                    warn!(client_id, %error, "failed to encode upstream response");
                                    return;
                                }
                            },
                            None => None,
                        };
                        if let Some(frame) = frame {
                            if let Err(error) =
                                self.capture_turn_start_response(client_id, message).await
                            {
                                warn!(client_id, %error, "failed to persist accepted turn start");
                                return;
                            }
                            if self
                                .send_response_awaiting_capacity(
                                    &out_tx,
                                    message,
                                    frame,
                                    history_method,
                                )
                                .await
                                .is_err()
                            {
                                return;
                            }
                            continue;
                        }
                    }
                    if let Some(error) = parsed.as_ref().and_then(|message| {
                        oversized_history_page_error(message, raw.len(), history_method)
                    }) {
                        warn!(client_id, actual_bytes = raw.len(), limit_bytes = HISTORY_PAGE_RESPONSE_BUDGET,
                            request_id = %error["id"], "history page exceeds response budget");
                        if self
                            .send_json_awaiting_capacity(&out_tx, &error)
                            .await
                            .is_err()
                        {
                            return;
                        }
                        continue;
                    }
                    if let Some(message) = parsed.as_ref()
                        && let Err(error) =
                            self.capture_turn_start_response(client_id, message).await
                    {
                        warn!(client_id, %error, "failed to persist accepted turn start");
                        return;
                    }
                    if let Some(call) = parsed
                        .as_ref()
                        .and_then(crate::agents::tools::codex_tool_call)
                    {
                        let gateway = Arc::clone(self);
                        let response_tx = upstream_tx.clone();
                        tokio::spawn(async move {
                            gateway.answer_codex_tool_call_on(response_tx, call).await;
                        });
                        continue;
                    }

                    if parsed.as_ref().is_some_and(|message| {
                        message["method"] == crate::providers::codex::router::REFRESH_METHOD
                    }) {
                        continue;
                    }

                    // The client's app-server connection and the gateway's control
                    // connection are both subscribed during a hosted voice call.
                    // The control connection is the sole realtime delivery owner.
                    if parsed
                        .as_ref()
                        .and_then(realtime_notification_method)
                        .is_some()
                    {
                        continue;
                    }

                    if parsed
                        .as_ref()
                        .is_some_and(|message| self.side_question_forks.owns(message))
                    {
                        continue;
                    }

                    if parsed
                        .as_ref()
                        .and_then(|message| message.get("method"))
                        .is_some()
                    {
                        let payload = if let Some(message) = parsed.as_ref() {
                            match self
                                .prepare_forwarded_notification(&raw, message, notification_origin)
                                .await
                            {
                                Ok(payload) => payload,
                                Err(error) => {
                                    warn!(client_id, %error, "failed to annotate notification");
                                    return;
                                }
                            }
                        } else {
                            ClientFrame::from_text(raw)
                        };
                        if let Some(text) = payload.text() {
                            self.journal
                                .notify_client(Source::Codex, client_id, &Arc::from(text));
                        }
                        if self
                            .deliver_awaiting_capacity(&out_tx, payload.into_command())
                            .await
                            .is_err()
                        {
                            return;
                        }
                    } else {
                        self.journal
                            .rpc_response(Some(client_id), &Arc::from(raw.as_str()));
                        if self
                            .deliver_awaiting_capacity(&out_tx, ClientCommand::Text(raw))
                            .await
                            .is_err()
                        {
                            return;
                        }
                    }
                }
                UpstreamMessage::Ping(payload) => {
                    if upstream_tx
                        .try_send(UpstreamMessage::Pong(payload))
                        .is_err()
                    {
                        warn!(client_id, "Codex outbound queue is full");
                        return;
                    }
                }
                UpstreamMessage::Close(frame) => {
                    debug!(client_id, ?frame, "Codex closed client connection");
                    return;
                }
                UpstreamMessage::Binary(_)
                | UpstreamMessage::Pong(_)
                | UpstreamMessage::Frame(_) => {}
            }
        }
    }
    pub(super) async fn run_task_logged<F>(self: Arc<Self>, name: &'static str, fut: F)
    where
        F: std::future::Future<Output = ()> + Send + 'static,
    {
        let res = std::panic::AssertUnwindSafe(fut).catch_unwind().await;
        if let Err(panic) = res {
            error!(task = name, panic = ?panic, "task panicked");
        }
    }

    pub(super) fn broadcast_json_or_drop(&self, msg: &Value, source: Source) -> Result<()> {
        let frame = ClientFrame::encode(msg)?;
        let clients = self.snapshot_clients();
        if let Some(payload) = frame.text() {
            self.journal_broadcast(payload, source, &clients);
        }
        for client in clients {
            let _ = self.deliver_or_drop(&client, frame.clone().into_command());
        }
        Ok(())
    }

    pub(super) async fn broadcast_json_awaiting_capacity(&self, message: &Value, source: Source) {
        let frame = match ClientFrame::encode(message) {
            Ok(frame) => frame,
            Err(error) => {
                warn!(%error, "failed to encode broadcast notification");
                return;
            }
        };
        let clients = self.snapshot_clients();
        if let Some(payload) = frame.text() {
            self.journal_broadcast(payload, source, &clients);
        }
        for client in clients {
            let _ = self
                .deliver_awaiting_capacity(&client, frame.clone().into_command())
                .await;
        }
    }

    /// Sends one gateway-authored frame to one client. A frame carrying a
    /// `method` is a notification; anything else is a JSON-RPC response, and
    /// the journal records it as the answer to that client's request.
    pub(super) async fn send_json_awaiting_capacity(
        &self,
        tx: &ClientTx,
        msg: &Value,
    ) -> Result<()> {
        self.send_frame_awaiting_capacity(
            tx,
            msg.get("method").is_some(),
            ClientFrame::encode(msg)?,
        )
        .await
    }

    pub(super) async fn send_response_awaiting_capacity(
        &self,
        tx: &ClientTx,
        response: &Value,
        frame: ClientFrame,
        history_method: Option<&str>,
    ) -> Result<Option<usize>> {
        let bytes = frame.bytes();
        let resource = frame.capacity_resource();
        let response_bytes = if resource == Some("nested tool JSON bytes") {
            None
        } else {
            Some(bytes)
        };
        if let Some(mut error) = oversized_history_page_error(response, bytes, history_method) {
            if let Some(resource) = resource {
                error["error"]["data"]["resource"] = serde_json::json!(resource);
            }
            warn!(client_id = tx.id, actual_bytes = bytes, limit_bytes = HISTORY_PAGE_RESPONSE_BUDGET,
                request_id = %error["id"], "history page exceeds response budget");
            self.send_json_awaiting_capacity(tx, &error).await?;
        } else {
            self.send_frame_awaiting_capacity(tx, false, frame).await?;
        }
        Ok(response_bytes)
    }

    async fn send_frame_awaiting_capacity(
        &self,
        tx: &ClientTx,
        notification: bool,
        frame: ClientFrame,
    ) -> Result<()> {
        if !notification && let Some(response) = &tx.query_response {
            if response.is_claimed() {
                return Ok(());
            }
            let permit = match tokio::time::timeout(CLIENT_CAPACITY_WAIT, tx.tx.reserve()).await {
                Ok(Ok(permit)) => permit,
                Ok(Err(_)) => {
                    return self.reject_delivery(
                        tx,
                        mpsc::error::TrySendError::Closed(frame.into_command()),
                    );
                }
                Err(_) => {
                    return self.reject_delivery(
                        tx,
                        mpsc::error::TrySendError::Full(frame.into_command()),
                    );
                }
            };
            if response.claim() {
                if let Some(payload) = frame.text() {
                    self.journal_client_payload(tx, false, payload);
                }
                permit.send(frame.into_command());
            }
            return Ok(());
        }
        if let Some(payload) = frame.text() {
            self.journal_client_payload(tx, notification, payload);
        }
        self.deliver_awaiting_capacity(tx, frame.into_command())
            .await
    }

    pub(super) fn send_json_or_drop(&self, tx: &ClientTx, message: &Value) -> Result<()> {
        let frame = ClientFrame::encode(message)?;
        if let Some(payload) = frame.text() {
            self.journal_client_payload(tx, message.get("method").is_some(), payload);
        }
        self.deliver_or_drop(tx, frame.into_command())
    }

    fn journal_client_payload(&self, tx: &ClientTx, notification: bool, payload: &str) {
        log_diagnostic_ws_frame("gateway->client-local", Some(tx.id), payload);
        let raw: Arc<str> = Arc::from(payload);
        if notification {
            self.journal.notify_client(Source::Gateway, tx.id, &raw);
        } else {
            self.journal.rpc_response(Some(tx.id), &raw);
        }
    }

    pub(super) fn deliver_or_drop(&self, client: &ClientTx, command: ClientCommand) -> Result<()> {
        let Err(error) = client.try_send(command) else {
            return Ok(());
        };
        self.reject_delivery(client, error)
    }

    pub(super) async fn deliver_awaiting_capacity(
        &self,
        client: &ClientTx,
        command: ClientCommand,
    ) -> Result<()> {
        let error = match client.try_send(command) {
            Ok(()) => return Ok(()),
            Err(mpsc::error::TrySendError::Full(command)) => {
                match tokio::time::timeout(CLIENT_CAPACITY_WAIT, client.tx.reserve()).await {
                    Ok(Ok(permit)) => {
                        permit.send(command);
                        return Ok(());
                    }
                    Ok(Err(_)) => mpsc::error::TrySendError::Closed(command),
                    Err(_) => mpsc::error::TrySendError::Full(command),
                }
            }
            Err(error) => error,
        };
        self.reject_delivery(client, error)
    }

    fn reject_delivery(
        &self,
        client: &ClientTx,
        error: mpsc::error::TrySendError<ClientCommand>,
    ) -> Result<()> {
        let reason = match error {
            mpsc::error::TrySendError::Full(_) => "outbound queue full",
            mpsc::error::TrySendError::Closed(_) => "outbound queue closed",
        };
        warn!(
            client_id = client.id,
            reason, "dropping client whose outbound queue rejected a command"
        );
        match error.into_inner() {
            ClientCommand::Text(payload) => {
                self.journal
                    .deliver_drop(client.id, reason, &Arc::from(payload.as_str()))
            }
            ClientCommand::FrameCapacity(rejected) => {
                self.journal_frame_capacity(client.id, &rejected)
            }
            _ => {}
        }
        self.disconnect_client(client);
        Err(anyhow!("client {reason}"))
    }
}

#[cfg(test)]
mod tests;
