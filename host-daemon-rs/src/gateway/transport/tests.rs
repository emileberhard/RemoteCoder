use super::*;
use crate::agents::tools::{Caller, ToolOutcome};
use crate::gateway::RESTARTING_CLOSE_CODE;
use crate::gateway::device_tools::PhotoArguments;
use crate::providers::Provider;
use crate::test_support::TestGateway;
use tokio_util::sync::CancellationToken;

async fn buffered_codex_frames(
    frames: Vec<Value>,
) -> futures_util::stream::SplitStream<CodexWebSocket> {
    use tokio_tungstenite::tungstenite::protocol::{
        Role,
        frame::{
            Frame,
            coding::{Data, OpCode},
        },
    };
    let (_server, client) = tokio::net::UnixStream::pair().unwrap();
    let mut buffered = Vec::new();
    for frame in frames {
        Frame::message(
            frame.to_string().into_bytes(),
            OpCode::Data(Data::Text),
            true,
        )
        .format(&mut buffered)
        .unwrap();
    }
    Frame::close(None).format(&mut buffered).unwrap();
    CodexWebSocket::from_partially_read(client, buffered, Role::Client, None)
        .await
        .split()
        .1
}

#[tokio::test]
async fn outbound_codex_burst_does_not_disconnect_a_reading_client() {
    let gateway = TestGateway::new();
    let (tx, mut rx) = mpsc::channel(CLIENT_OUTBOUND_QUEUE_SIZE);
    let client = super::super::tests::test_client(1, tx);
    gateway.clients.insert(1, client.clone());
    let frames = (0..140)
        .map(|index| {
            json!({"method":"item/agentMessage/delta", "params":{
                "threadId":"thread", "turnId":"turn", "itemId":"reply", "delta":index.to_string()
            }})
        })
        .collect();
    let stream = buffered_codex_frames(frames).await;
    let reader = tokio::spawn(async move {
        for index in 0..140 {
            let Some(ClientCommand::Text(raw)) = rx.recv().await else {
                panic!("missing Codex delta {index}");
            };
            let frame: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(frame["params"]["delta"], index.to_string());
        }
    });
    let (upstream, _replies) = mpsc::channel(4);
    gateway
        .codex_to_client_loop(
            1,
            NotificationOrigin::Client {
                id: 1,
                opened_after: 0,
            },
            stream,
            client.clone(),
            upstream,
            Arc::default(),
        )
        .await;
    assert!(!client.closed.is_cancelled());
    tokio::time::timeout(Duration::from_secs(1), reader)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn outbound_rpc_response_survives_a_full_claude_queue() {
    for source in [Source::Gateway, Source::Codex] {
        let gateway = TestGateway::new();
        let (tx, mut rx) = mpsc::channel(CLIENT_OUTBOUND_QUEUE_SIZE);
        let client = super::super::tests::test_client(1, tx);
        gateway.clients.insert(1, client.clone());
        let stream =
            buffered_codex_frames(vec![json!({"id": 99, "result": {"accepted": true}})]).await;
        for index in 0..CLIENT_OUTBOUND_QUEUE_SIZE {
            gateway
                .broadcast_json_awaiting_capacity(&json!({"method":"item/agentMessage/delta", "params":{
                    "threadId":"claude_other", "turnId":"turn", "itemId":"reply", "delta":index.to_string()
                }}), Source::Claude)
                .await;
        }
        assert_eq!(client.tx.capacity(), 0);
        let reader = tokio::spawn(async move {
            for index in 0..CLIENT_OUTBOUND_QUEUE_SIZE {
                let Some(ClientCommand::Text(raw)) = rx.recv().await else {
                    panic!("missing preceding delta {index}");
                };
                let frame: Value = serde_json::from_str(&raw).unwrap();
                assert_eq!(frame["params"]["delta"], index.to_string());
            }
            let Some(ClientCommand::Text(raw)) = rx.recv().await else {
                panic!("missing response");
            };
            assert_eq!(
                serde_json::from_str::<Value>(&raw).unwrap(),
                json!({"id": 99, "result": {"accepted": true}})
            );
        });
        match source {
            Source::Gateway => {
                gateway
                    .respond(&client, json!(99), Ok(json!({"accepted": true})), None)
                    .await
                    .unwrap();
            }
            Source::Codex => {
                let (upstream, _replies) = mpsc::channel(4);
                gateway
                    .codex_to_client_loop(
                        1,
                        NotificationOrigin::Client {
                            id: 1,
                            opened_after: 0,
                        },
                        stream,
                        client.clone(),
                        upstream,
                        Arc::default(),
                    )
                    .await;
            }
            _ => unreachable!(),
        }
        assert!(!client.closed.is_cancelled());
        tokio::time::timeout(Duration::from_secs(1), reader)
            .await
            .unwrap()
            .unwrap();
    }
}

#[tokio::test]
async fn marks_publication_survives_a_full_claude_queue() {
    let gateway = TestGateway::new();
    let (tx, mut rx) = mpsc::channel(CLIENT_OUTBOUND_QUEUE_SIZE);
    let client = super::super::tests::test_client(1, tx);
    gateway.clients.insert(1, client.clone());
    for index in 0..CLIENT_OUTBOUND_QUEUE_SIZE {
        gateway
            .broadcast_json_awaiting_capacity(
                &json!({"method": "item/agentMessage/delta", "params": {"delta": index}}),
                Source::Claude,
            )
            .await;
    }
    let marks = crate::conversation_marks::Marks {
        schema_version: 2,
        revision: 1,
        read_baseline: 123,
        threads: Default::default(),
    };
    let notification = json!({"method": "conversation/marks/changed", "params": &marks});
    let reader = tokio::spawn(async move {
        for index in 0..CLIENT_OUTBOUND_QUEUE_SIZE {
            let Some(ClientCommand::Text(raw)) = rx.recv().await else {
                panic!("missing preceding delta {index}");
            };
            assert_eq!(
                serde_json::from_str::<Value>(&raw).unwrap()["params"]["delta"],
                index
            );
        }
        let Some(ClientCommand::Text(raw)) = rx.recv().await else {
            panic!("missing committed marks notification");
        };
        assert_eq!(serde_json::from_str::<Value>(&raw).unwrap(), notification);
    });
    gateway.publish_marks(&marks).await;
    assert!(!client.closed.is_cancelled());
    tokio::time::timeout(Duration::from_secs(1), reader)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test(start_paused = true)]
async fn guarded_control_fanout_never_waits_on_saturated_clients() {
    let gateway = TestGateway::new();
    let mut receivers = Vec::new();
    for id in 1..=255 {
        let (tx, rx) = mpsc::channel(CLIENT_OUTBOUND_QUEUE_SIZE);
        let client = super::super::tests::test_client(id, tx);
        for _ in 0..CLIENT_OUTBOUND_QUEUE_SIZE {
            client.try_send(ClientCommand::Text("{}".into())).unwrap();
        }
        gateway.clients.insert(id, client);
        receivers.push(rx);
    }
    let (tx, mut healthy) = mpsc::channel(CLIENT_OUTBOUND_QUEUE_SIZE);
    gateway
        .clients
        .insert(256, super::super::tests::test_client(256, tx));
    let start = tokio::time::Instant::now();
    gateway
        .broadcast_json_or_drop(&json!({}), Source::Gateway)
        .unwrap();
    assert_eq!(start.elapsed(), Duration::ZERO);
    assert!(healthy.try_recv().is_ok());
    assert_eq!(gateway.clients.len(), 1);
}

#[tokio::test]
async fn outbound_burst_does_not_disconnect_a_reading_client() {
    let gateway = TestGateway::new();
    let (tx, mut rx) = mpsc::channel(CLIENT_OUTBOUND_QUEUE_SIZE);
    let client = super::super::tests::test_client(1, tx);
    gateway.clients.insert(1, client.clone());
    let reader = tokio::spawn(async move {
        for index in 0..140 {
            let Some(ClientCommand::Text(raw)) = rx.recv().await else {
                panic!("missing delta {index}");
            };
            let frame: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(frame["params"]["delta"], index.to_string());
        }
    });
    for index in 0..140 {
        gateway
            .broadcast_json_awaiting_capacity(
                &json!({"method":"item/agentMessage/delta", "params":{
                    "threadId":"claude_other", "turnId":"turn", "itemId":"reply", "delta":index.to_string()
                }}), Source::Claude,
            )
            .await;
    }
    assert!(!client.closed.is_cancelled());
    tokio::time::timeout(Duration::from_secs(1), reader)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn outbound_overflow_sends_a_close_without_waiting_for_client_input() {
    use crate::providers::codex::daemon::CodexAppServer;
    use axum::{Router, extract::ws::WebSocketUpgrade, routing::get};
    use tokio::net::UnixListener;
    use tokio_tungstenite::{accept_async, connect_async};

    let home = tempfile::tempdir().unwrap();
    let directory = home.path().join("app-server-control");
    tokio::fs::create_dir_all(&directory).await.unwrap();
    let listener = UnixListener::bind(directory.join("app-server-control.sock")).unwrap();
    let upstream = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = accept_async(stream).await.unwrap();
        while socket.next().await.is_some() {}
    });
    let gateway = TestGateway::with_codex(
        Arc::new(CodexAppServer::new_for_test_socket(home.path().into())),
        None,
    );
    *gateway.control_init_result.lock().await = Some(json!({}));
    let owner = Arc::clone(&gateway);
    let app = Router::new().route(
        "/ws",
        get(move |ws: WebSocketUpgrade| {
            let owner = Arc::clone(&owner);
            async move {
                ws.on_upgrade(move |socket| {
                    owner.handle_ws(
                        socket,
                        CancellationToken::new(),
                        crate::auth::installation_credentials::Grant::Operator,
                    )
                })
            }
        }),
    );
    let (address, server) = crate::test_support::serve(app).await;
    let (mut socket, _) = connect_async(format!("ws://{address}/ws")).await.unwrap();
    loop {
        if matches!(
            socket.next().await.unwrap().unwrap(),
            UpstreamMessage::Text(_)
        ) {
            break;
        }
    }
    let client = gateway.clients.iter().next().unwrap().value().clone();
    for _ in 0..=CLIENT_OUTBOUND_QUEUE_SIZE {
        let _ = gateway.deliver_or_drop(&client, ClientCommand::Text("{}".into()));
    }
    assert!(client.closed.is_cancelled());
    let closed = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            match socket.next().await.unwrap().unwrap() {
                UpstreamMessage::Close(frame) => break frame.unwrap(),
                UpstreamMessage::Text(raw) => {
                    let _: Value = serde_json::from_str(&raw).unwrap();
                }
                _ => {}
            }
        }
    })
    .await;
    server.abort();
    upstream.abort();
    let frame = closed.expect("client must learn the drop without sending");
    assert_eq!(u16::from(frame.code), 1013);
}

async fn refusal_code(gateway: &Arc<Gateway>) -> u16 {
    use axum::{Router, extract::ws::WebSocketUpgrade, routing::get};
    use tokio_tungstenite::connect_async;

    let owner = Arc::clone(gateway);
    let app = Router::new().route(
        "/ws",
        get(move |ws: WebSocketUpgrade| {
            let owner = Arc::clone(&owner);
            async move {
                ws.on_upgrade(move |socket| {
                    owner.handle_ws(
                        socket,
                        CancellationToken::new(),
                        crate::auth::installation_credentials::Grant::Operator,
                    )
                })
            }
        }),
    );
    let (address, server) = crate::test_support::serve(app).await;
    let (mut socket, _) = connect_async(format!("ws://{address}/ws")).await.unwrap();
    let frame = loop {
        if let UpstreamMessage::Close(frame) = socket.next().await.unwrap().unwrap() {
            break frame.unwrap();
        }
    };
    server.abort();
    u16::from(frame.code)
}

#[tokio::test]
async fn a_draining_gateway_refuses_clients_as_a_planned_restart() {
    let gateway = TestGateway::new();
    *gateway.control_init_result.lock().await = Some(json!({}));
    gateway.draining.store(true, Ordering::Release);

    assert_eq!(refusal_code(&gateway).await, RESTARTING_CLOSE_CODE);
}

type TestSocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect_client(gateway: &Arc<Gateway>) -> (TestSocket, tokio::task::JoinHandle<()>) {
    use axum::{Router, extract::ws::WebSocketUpgrade, routing::get};

    let owner = Arc::clone(gateway);
    let app = Router::new().route(
        "/ws",
        get(move |ws: WebSocketUpgrade| {
            let owner = Arc::clone(&owner);
            async move {
                ws.on_upgrade(move |socket| {
                    owner.handle_ws(
                        socket,
                        CancellationToken::new(),
                        crate::auth::installation_credentials::Grant::Operator,
                    )
                })
            }
        }),
    );
    let (address, server) = crate::test_support::serve(app).await;
    let (socket, _) = tokio_tungstenite::connect_async(format!("ws://{address}/ws"))
        .await
        .unwrap();
    (socket, server)
}

async fn next_frame(socket: &mut TestSocket) -> UpstreamMessage {
    loop {
        let frame = tokio::time::timeout(Duration::from_secs(5), socket.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        if matches!(frame, UpstreamMessage::Text(_) | UpstreamMessage::Close(_)) {
            return frame;
        }
    }
}

async fn next_json(socket: &mut TestSocket) -> Value {
    match next_frame(socket).await {
        UpstreamMessage::Text(text) => serde_json::from_str(text.as_str()).unwrap(),
        other => panic!("expected a JSON frame, got {other:?}"),
    }
}

async fn send_json(socket: &mut TestSocket, message: Value) {
    socket
        .send(UpstreamMessage::Text(message.to_string()))
        .await
        .unwrap();
}

#[tokio::test]
async fn a_client_without_codex_is_served_and_moved_to_codex_once_it_is_ready() {
    let gateway = TestGateway::new();
    let (mut socket, server) = connect_client(&gateway).await;
    let not_running = json!({"state": "unavailable", "reason": "Codex app-server is not running"});

    let ready = next_json(&mut socket).await;
    assert_eq!(ready["method"], "daemon/ready");
    assert_eq!(ready["params"]["providers"]["codex"], not_running);

    send_json(
        &mut socket,
        json!({"id": 1, "method": "initialize", "params": {}}),
    )
    .await;
    assert_eq!(next_json(&mut socket).await, json!({"id": 1, "result": {}}));
    send_json(&mut socket, json!({"method": "initialized"})).await;
    send_json(
        &mut socket,
        json!({"id": 2, "method": "thread/list", "params": {}}),
    )
    .await;
    let refused = next_json(&mut socket).await;
    assert_eq!(refused["id"], 2);
    assert_eq!(
        refused["error"]["data"],
        json!({"kind": "providerUnavailable", "retryable": false, "provider": "codex",
            "reason": "Codex app-server is not running"})
    );
    send_json(
        &mut socket,
        json!({"id": 3, "method": "host/info", "params": {}}),
    )
    .await;
    let info = next_json(&mut socket).await;
    assert_eq!(info["id"], 3);
    assert!(info["result"]["homeDirectory"].is_string(), "{info}");

    *gateway.control_init_result.lock().await = Some(json!({}));
    gateway.refresh_provider_health().await;
    gateway.close_degraded_clients();
    let health = next_json(&mut socket).await;
    assert_eq!(health["method"], "gateway/providerHealth");
    assert_eq!(
        health["params"]["providers"]["codex"],
        json!({"state": "ready"})
    );
    let UpstreamMessage::Close(Some(close)) = next_frame(&mut socket).await else {
        panic!("expected the planned close");
    };
    assert_eq!(u16::from(close.code), RESTARTING_CLOSE_CODE);
    server.abort();
}

#[tokio::test]
async fn a_stuck_recovery_journal_still_admits_clients_without_codex() {
    use crate::runtime::recovery::{RecoveryJournal, RecoveryPhase, RecoveryStore};

    let directory = tempfile::tempdir().unwrap();
    let recovery = directory.path().join("codex-restart-recovery.json");
    let claude = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let gateway = Gateway::with_state_paths(
        Arc::new(crate::providers::codex::daemon::CodexAppServer::new(
            std::path::PathBuf::from("/bin/true"),
            std::collections::HashMap::new(),
        )),
        claude.settings.clone(),
        crate::observability::journal::Journal::disabled(),
        None,
        Some(recovery.clone()),
        None,
    );
    let mut journal = RecoveryJournal::new(
        "generation-1".to_string(),
        "0123456789abcdef0123456789abcdef".to_string(),
        Vec::new(),
    )
    .unwrap();
    journal.phase = RecoveryPhase::DaemonStopped;
    RecoveryStore::new(recovery).write(&journal).unwrap();
    assert!(gateway.restart_in_progress().await);

    let (mut socket, server) = connect_client(&gateway).await;
    assert_eq!(next_json(&mut socket).await["method"], "daemon/ready");
    send_json(
        &mut socket,
        json!({"id": 1, "method": "turn/start", "params": {"threadId": "thr_codex"}}),
    )
    .await;
    let refused = next_json(&mut socket).await;
    assert_eq!(refused["error"]["data"]["kind"], "providerUnavailable");
    server.abort();
}

#[tokio::test]
async fn new_codex_work_waits_for_a_ready_codex_and_claude_work_does_not() {
    let gateway = TestGateway::new();
    let request = |thread: &str| {
        json!({"id": 1, "method": "turn/start", "params": {"threadId": thread}})
            .as_object()
            .unwrap()
            .clone()
    };
    let unavailable = RpcError::codex_unavailable("Codex app-server is not running");

    assert_eq!(
        gateway
            .validate_dispatch("turn/start", &request("thr_codex"))
            .await,
        Err(unavailable.clone())
    );
    assert_ne!(
        gateway
            .validate_dispatch(
                "turn/start",
                &request("claude_0f5c2b8e-6d0e-4c43-9d54-2b1f0d6a7e11")
            )
            .await,
        Err(unavailable)
    );
}

#[tokio::test(start_paused = true)]
async fn outbound_stuck_client_delays_a_healthy_client_only_once() {
    let gateway = TestGateway::new();
    let (stuck_tx, _stuck_rx) = mpsc::channel(CLIENT_OUTBOUND_QUEUE_SIZE);
    let stuck = super::super::tests::test_client(1, stuck_tx);
    for _ in 0..CLIENT_OUTBOUND_QUEUE_SIZE {
        stuck.try_send(ClientCommand::Text("{}".into())).unwrap();
    }
    let (healthy_tx, mut healthy_rx) = mpsc::channel(CLIENT_OUTBOUND_QUEUE_SIZE);
    let healthy = super::super::tests::test_client(2, healthy_tx);
    gateway.clients.insert(1, stuck.clone());
    gateway.clients.insert(2, healthy.clone());
    let started = tokio::time::Instant::now();
    let reader = tokio::spawn(async move {
        for index in 0..140 {
            let Some(ClientCommand::Text(raw)) = healthy_rx.recv().await else {
                panic!("missing healthy-client delta {index}");
            };
            assert!(started.elapsed() <= CLIENT_CAPACITY_WAIT);
            let frame: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(frame["params"]["delta"], index.to_string());
        }
    });
    for index in 0..140 {
        gateway
            .broadcast_json_awaiting_capacity(
                &json!({"method":"item/agentMessage/delta", "params":{
                    "threadId": if index % 2 == 0 {"claude_a"} else {"claude_b"},
                    "turnId":"turn", "itemId":"reply", "delta":index.to_string()
                }}),
                Source::Claude,
            )
            .await;
    }
    assert!(stuck.closed.is_cancelled());
    assert!(!healthy.closed.is_cancelled());
    assert!(started.elapsed() <= CLIENT_CAPACITY_WAIT);
    reader.await.unwrap();
}

#[tokio::test]
async fn refused_native_starts_leave_no_durable_pending_turns() {
    let directory = tempfile::tempdir().unwrap();
    let state_path = directory.path().join("active-codex-turns.json");
    let gateway = TestGateway::with_native_runtime(directory.path());
    *gateway.control_init_result.lock().await = Some(json!({}));
    gateway.commit_turn_state().await.unwrap();
    let original_state = std::fs::read(&state_path).unwrap();
    let pending: PendingRequests = Arc::default();
    for id in 0..MAX_PENDING_REQUESTS {
        pending
            .lock()
            .await
            .insert(id.to_string(), PendingRequest::new("thread/read", None));
    }
    let (tx, mut responses) = mpsc::channel(4);
    let out = super::super::tests::test_client(1, tx);
    let (upstream, mut forwarded) = mpsc::channel(4);
    for id in [1000, 1001, 1002] {
        let raw = json!({"id":id,"method":"turn/start","params":{
            "threadId":"thread","input":[{"type":"text","text":"capacity retry"}]
        }})
        .to_string();
        let DispatchPlan::Request(request) = DispatchPlan::parse(&raw) else {
            panic!("request")
        };
        gateway
            .forward_native_request(
                1,
                &out,
                NativeRequest {
                    raw,
                    request,
                    _admission: None,
                },
                &upstream,
                &pending,
            )
            .await
            .unwrap();
        let Some(ClientCommand::Text(raw)) = responses.recv().await else {
            panic!("capacity response")
        };
        let response: Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(response["id"], id);
        assert_eq!(
            response["error"]["data"],
            json!({"kind":"capacity","retryable":true,"resource":"connection pending native requests"}),
            "{response}"
        );
    }
    assert!(forwarded.try_recv().is_err());
    assert_eq!(std::fs::read(&state_path).unwrap(), original_state);
    assert!(gateway.core.lock().await.turns.pending().next().is_none());
    assert_eq!(pending.lock().await.len(), MAX_PENDING_REQUESTS);
}

#[tokio::test]
async fn forwarded_codex_input_changes_the_driver_only_on_its_exact_success_response() {
    let gateway = TestGateway::new();
    let (outbound, mut replies) = mpsc::channel(16);
    let client = ClientTx {
        content_subscriptions: Arc::default(),
        query_response: None,
        id: 2,
        installation_id: None,
        tx: outbound,
        closed: CancellationToken::new(),
    };
    let (phone_outbound, _phone_replies) = mpsc::channel(4);
    let phone = ClientTx {
        content_subscriptions: Arc::default(),
        query_response: None,
        id: 1,
        installation_id: Some("phone".into()),
        tx: phone_outbound,
        closed: CancellationToken::new(),
    };
    gateway.device_tools.connected(phone).unwrap();
    gateway.device_tools.connected(client.clone()).unwrap();
    let (server, stream) = tokio::net::UnixStream::pair().unwrap();
    let (server, stream) = tokio::join!(
        tokio_tungstenite::accept_async(server),
        tokio_tungstenite::client_async("ws://localhost", stream)
    );
    let mut server = server.unwrap();
    let (_, stream) = stream.unwrap().0.split();
    let (upstream, _upstream_replies) = mpsc::channel(4);
    let pending: PendingRequests = Arc::default();
    let owner = Arc::clone(&gateway);
    let requests = Arc::clone(&pending);
    let read = tokio::spawn(async move {
        owner
            .codex_to_client_loop(
                2,
                NotificationOrigin::Client {
                    id: 2,
                    opened_after: 0,
                },
                stream,
                client,
                upstream,
                requests,
            )
            .await;
    });
    let caller = Caller {
        provider: Provider::Codex,
        thread_id: Some("thread".into()),
        turn_id: Some("turn".into()),
    };
    for (index, method) in ["turn/start", "turn/steer"].into_iter().enumerate() {
        for accepted in [false, true] {
            gateway.device_tools.record_driver(1, "thread");
            let id = json!(index * 2 + usize::from(accepted));
            let request = json!({"id":id,"method":method,"params":{"threadId":"thread","expectedTurnId":"turn"}});
            gateway
                .capture_client_request_locked(2, request.as_object().unwrap())
                .await
                .unwrap();
            assert_eq!(
                gateway
                    .invoke_device_photo(&caller, PhotoArguments::default())
                    .await,
                ToolOutcome::error(
                    "The RemoteCoder app on The user's iPhone doesn't support take_photo; it needs an update."
                )
            );
            pending.lock().await.insert(
                id.to_string(),
                PendingRequest::new(method, request.get("params")),
            );
            server
                .send(UpstreamMessage::Text(
                    json!({"id":"unrelated","result":{}}).to_string(),
                ))
                .await
                .unwrap();
            assert!(matches!(
                replies.recv().await.unwrap(),
                ClientCommand::Text(_)
            ));
            assert_eq!(
                gateway
                    .invoke_device_photo(&caller, PhotoArguments::default())
                    .await,
                ToolOutcome::error(
                    "The RemoteCoder app on The user's iPhone doesn't support take_photo; it needs an update."
                )
            );
            let response = if accepted {
                json!({"id":id,"result":{"turnId":"turn"}})
            } else {
                json!({"id":id,"error":{"code":-32600,"message":"No active turn"}})
            };
            server
                .send(UpstreamMessage::Text(response.to_string()))
                .await
                .unwrap();
            let ClientCommand::Text(text) = replies.recv().await.unwrap() else {
                panic!("expected response");
            };
            assert_eq!(serde_json::from_str::<Value>(&text).unwrap()["id"], id);
            let outcome = gateway
                .invoke_device_photo(&caller, PhotoArguments::default())
                .await;
            assert_eq!(
                outcome,
                ToolOutcome::error(if accepted {
                    "This turn did not come from the RemoteCoder iPhone app, so iPhone tools can't run. If a photo is needed, ask the user to send their next message from the iPhone."
                } else {
                    "The RemoteCoder app on The user's iPhone doesn't support take_photo; it needs an update."
                })
            );
        }
    }
    server.close(None).await.unwrap();
    read.await.unwrap();
}

type TestClientSocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn writer_connection(
    gateway: &Arc<Gateway>,
    client_id: u64,
) -> (ClientTx, TestClientSocket, tokio::task::JoinHandle<()>) {
    use axum::{Router, extract::ws::WebSocketUpgrade, routing::get};
    let (tx, rx) = mpsc::channel(8);
    let client = super::super::tests::test_client(client_id, tx);
    gateway.clients.insert(client_id, client.clone());
    let receiver = Arc::new(tokio::sync::Mutex::new(Some(rx)));
    let owner = Arc::clone(gateway);
    let closed = client.closed.clone();
    let app = Router::new().route(
        "/ws",
        get(move |ws: WebSocketUpgrade| {
            let owner = Arc::clone(&owner);
            let receiver = Arc::clone(&receiver);
            let closed = closed.clone();
            async move {
                ws.on_upgrade(move |socket| async move {
                    let (sink, _stream) = socket.split();
                    owner
                        .client_writer_loop(
                            client_id,
                            sink,
                            receiver.lock().await.take().unwrap(),
                            closed,
                        )
                        .await;
                })
            }
        }),
    );
    let (address, server) = crate::test_support::serve(app).await;
    let (socket, _) = tokio_tungstenite::connect_async(format!("ws://{address}/ws"))
        .await
        .unwrap();
    (client, socket, server)
}

async fn writer_json(socket: &mut TestClientSocket) -> Value {
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if let UpstreamMessage::Text(text) = socket.next().await.unwrap().unwrap() {
                break serde_json::from_str::<Value>(&text).unwrap();
            }
        }
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn rpc_capacity_writer_refuses_an_oversized_response_and_keeps_the_next_response_alive() {
    use crate::providers::claude::ClaudeSupervisor;
    use crate::providers::codex::daemon::MAX_WEBSOCKET_BYTES;
    use crate::rpc::dispatch::ClaudeMethod;
    let mut home = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    home.settings.enabled = true;
    let gateway = TestGateway::with_settings(
        Arc::new(crate::providers::codex::daemon::CodexAppServer::new(
            "/bin/true".into(),
            std::collections::HashMap::new(),
        )),
        home.settings.clone(),
        Arc::new(home),
    );
    let (notifications, _rx) = mpsc::channel(1);
    gateway.set_claude_agent(ClaudeSupervisor::new(
        gateway.claude_settings.clone(),
        notifications,
        gateway.journal.clone(),
        gateway.mcp_tokens.clone(),
    ));
    let (tx, mut queued) = mpsc::channel(1);
    let producer = super::super::tests::test_client(30, tx);
    gateway
        .handle_claude_rpc(
            &producer,
            ClaudeMethod::ThreadStart,
            json!({"id":"bounded-id","params":{"cwd":"x".repeat(12 * 1024 * 1024)}})
                .as_object()
                .unwrap(),
        )
        .await
        .unwrap();
    let command = queued.recv().await.unwrap();
    let ClientCommand::FrameCapacity(rejection) = &command else {
        panic!("oversized result must queue only capacity metadata")
    };
    assert!(rejection.bytes > MAX_WEBSOCKET_BYTES);
    assert_eq!(rejection.id, Some(json!("bounded-id")));
    let (client, mut socket, server) = writer_connection(&gateway, 1).await;
    client.try_send(command).unwrap();
    let response = writer_json(&mut socket).await;
    assert_eq!(response["id"], "bounded-id");
    assert_eq!(response["error"]["code"], -32001);
    assert_eq!(response["error"]["data"]["kind"], "capacity");
    assert_eq!(
        response["error"]["data"]["resource"],
        "outbound message bytes"
    );
    assert!(
        response["error"]["data"]["actualBytes"].as_u64().unwrap() > MAX_WEBSOCKET_BYTES as u64
    );
    assert_eq!(response["error"]["data"]["limit"], MAX_WEBSOCKET_BYTES);
    assert_eq!(response["error"]["data"]["retryable"], false);
    client
        .try_send(ClientCommand::Text(
            json!({"id":2,"result":{"healthy":true}}).to_string(),
        ))
        .unwrap();
    let response = writer_json(&mut socket).await;
    assert_eq!(response["id"], 2);
    assert_eq!(response["result"]["healthy"], true);
    assert!(gateway.clients.contains_key(&1));
    assert!(!client.closed.is_cancelled());
    client.closed.cancel();
    server.abort();
}

#[tokio::test]
async fn rpc_capacity_notification_close_reconnect_converges_and_journals_metadata_once() {
    use crate::observability::journal::Journal;
    use crate::providers::claude::settings::ClaudeSettings;
    use crate::providers::codex::daemon::{CodexAppServer, MAX_WEBSOCKET_BYTES};
    use crate::rpc::dispatch::ClaudeMethod;
    use std::collections::HashMap;
    let logs = tempfile::tempdir().unwrap();
    let journal = Journal::open_in(logs.path().to_owned(), 1);
    let mut home = ClaudeSettings::isolated_for_test();
    home.settings.enabled = true;
    let gateway = TestGateway::with_journal(
        Arc::new(CodexAppServer::new("/bin/true".into(), HashMap::new())),
        home.settings.clone(),
        Arc::new(home),
        journal.clone(),
    );
    let (first, mut socket, first_server) = writer_connection(&gateway, 1).await;
    first
        .content_subscriptions
        .replace(json!({"threadIds":["claude_a"]}))
        .unwrap();
    let marker = "PRIVATE-NOTIFICATION-CONTENT";
    let huge = marker.to_owned() + &"x".repeat(MAX_WEBSOCKET_BYTES - 256);
    let notification = json!({"method":"item/completed","params":{
        "threadId":"claude_a","turnId":"turn-a","item":{"id":"m".repeat(4090),"type":"agentMessage","text":huge}}});
    let bytes = ClientFrame::encode(&notification).unwrap().bytes() + r#","rcSequence":1"#.len();
    assert!(bytes > MAX_WEBSOCKET_BYTES);
    gateway.ingest_agent_notification(notification).await;
    let close = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            match socket.next().await.unwrap().unwrap() {
                UpstreamMessage::Close(close) => break close.unwrap(),
                UpstreamMessage::Text(_) => {
                    panic!("oversized content must never be delivered or announced")
                }
                _ => {}
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(u16::from(close.code), 1009);
    assert!(!gateway.clients.contains_key(&first.id));
    first_server.abort();
    drop((socket, first));

    let project = gateway
        .claude_settings
        .claude_home
        .join("projects")
        .join("fixture");
    std::fs::create_dir_all(&project).unwrap();
    let records = [
        json!({"type":"user","uuid":"old-prompt","timestamp":"2026-10-08T02:00:00Z","cwd":"/tmp","message":{"role":"user","content":"Old prompt"}}),
        json!({"type":"assistant","uuid":"old-answer","timestamp":"2026-10-08T02:00:01Z","message":{"id":"old-message","role":"assistant","content":[{"type":"text","text":huge}]}}),
        json!({"type":"user","uuid":"new-prompt","timestamp":"2026-10-08T02:00:02Z","cwd":"/tmp","message":{"role":"user","content":"New prompt"}}),
        json!({"type":"assistant","uuid":"new-answer","timestamp":"2026-10-08T02:00:03Z","message":{"id":"new-message","role":"assistant","content":[{"type":"text","text":"Recovered tail"}]}}),
    ];
    std::fs::write(
        project.join("a.jsonl"),
        records
            .iter()
            .map(|record| format!("{record}\n"))
            .collect::<String>(),
    )
    .unwrap();
    let (client, mut socket, server) = writer_connection(&gateway, 2).await;
    for (id, method, target, params) in [
        (
            1,
            "conversation/subscriptions/set",
            OwnedTarget::Gateway(OwnedRoute::Subscriptions),
            json!({"threadIds":["claude_a"]}),
        ),
        (
            2,
            "daemon/replayNotifications",
            OwnedTarget::Gateway(OwnedRoute::ReplayNotifications),
            json!({"threadId":"claude_a","afterSequence":0}),
        ),
        (
            3,
            "thread/items/list",
            OwnedTarget::Claude(ClaudeMethod::ItemsPage),
            json!({"threadId":"claude_a","limit":10,"sortDirection":"desc"}),
        ),
        (
            4,
            "thread/items/list",
            OwnedTarget::Claude(ClaudeMethod::ItemsPage),
            json!({"threadId":"claude_a","limit":1,"sortDirection":"desc"}),
        ),
        (
            5,
            "host/info",
            OwnedTarget::Gateway(OwnedRoute::HostInfo),
            json!({}),
        ),
    ] {
        gateway
            .handle_owned_rpc(
                client.id,
                &client,
                method,
                target,
                json!({"id":id,"params":params}).as_object().unwrap(),
            )
            .await
            .unwrap();
        let response = writer_json(&mut socket).await;
        assert_eq!(response["id"], id);
        match id {
            2 => {
                assert_eq!(response["result"]["notifications"], json!([]));
                assert_eq!(response["result"]["evictedBefore"], true);
                assert_eq!(response["result"]["latestSequence"], 1);
            }
            3 => assert_eq!(response["error"]["data"]["kind"], "historyPageTooLarge"),
            4 => assert_eq!(
                response["result"]["data"][0]["item"]["text"],
                "Recovered tail"
            ),
            _ => assert!(response.get("error").is_none(), "{response}"),
        }
    }
    assert!(gateway.clients.contains_key(&2));
    assert!(!client.closed.is_cancelled());
    journal.drain(Duration::from_secs(3)).await;
    let mut capacities = Vec::new();
    for entry in std::fs::read_dir(logs.path()).unwrap() {
        let log = std::fs::read_to_string(entry.unwrap().path()).unwrap();
        assert!(!log.contains(marker));
        for line in log.lines() {
            let event: Value = serde_json::from_str(line).unwrap();
            if event["event"] == "outboundFrameCapacity" {
                capacities.push(event);
            }
        }
    }
    assert_eq!(capacities.len(), 1);
    assert_eq!(capacities[0]["method"], "item/completed");
    assert_eq!(capacities[0]["threadId"], "claude_a");
    assert_eq!(capacities[0]["actualBytes"], bytes);
    assert_eq!(capacities[0]["limitBytes"], MAX_WEBSOCKET_BYTES);
    client.closed.cancel();
    server.abort();
}

#[tokio::test]
async fn rpc_capacity_nested_history_page_rejects_and_live_notification_closes() {
    use crate::providers::claude::settings::ClaudeSettings;
    use crate::providers::codex::daemon::{CodexAppServer, MAX_WEBSOCKET_BYTES};
    use crate::rpc::dispatch::ClaudeMethod;
    use std::io::Write;
    let mut home = ClaudeSettings::isolated_for_test();
    home.settings.enabled = true;
    let gateway = TestGateway::with_settings(
        Arc::new(CodexAppServer::new(
            "/bin/true".into(),
            std::collections::HashMap::new(),
        )),
        home.settings.clone(),
        Arc::new(home),
    );
    let nested = json!({"content":[
        {"type":"text","text":"x".repeat(40 * 1024 * 1024)},
        {"type":"image","mimeType":"image/png","data":"YWJj"}
    ]})
    .to_string();
    let project = gateway.claude_settings.claude_home.join("projects/fixture");
    std::fs::create_dir_all(&project).unwrap();
    let mut file = std::fs::File::create(project.join("a.jsonl")).unwrap();
    for record in [
        json!({"type":"user","uuid":"prompt","timestamp":"2026-10-08T02:00:00Z","cwd":"/tmp","message":{"role":"user","content":"Use the tool"}}),
        json!({"type":"assistant","uuid":"use","timestamp":"2026-10-08T02:00:01Z","message":{"id":"assistant","role":"assistant","content":[{"type":"tool_use","id":"tool","name":"mcp__fixture__read","input":{}}]}}),
        json!({"type":"user","uuid":"result","timestamp":"2026-10-08T02:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool","content":nested,"is_error":false}]}}),
    ] {
        serde_json::to_writer(&mut file, &record).unwrap();
        file.write_all(b"\n").unwrap();
    }
    drop(file);
    let (client, mut socket, server) = writer_connection(&gateway, 1).await;
    gateway
        .handle_owned_rpc(
            client.id,
            &client,
            "thread/items/list",
            OwnedTarget::Claude(ClaudeMethod::ItemsPage),
            json!({"id":1,"params":{"threadId":"claude_a","limit":1,"sortDirection":"desc"}})
                .as_object()
                .unwrap(),
        )
        .await
        .unwrap();
    let response = writer_json(&mut socket).await;
    assert_eq!(response["id"], 1);
    assert_eq!(response["error"]["data"]["kind"], "historyPageTooLarge");
    assert_eq!(
        response["error"]["data"]["resource"],
        "nested tool JSON bytes"
    );
    assert!(
        response["error"]["data"]["actualBytes"].as_u64().unwrap() > MAX_WEBSOCKET_BYTES as u64
    );
    gateway
        .send_json_awaiting_capacity(&client, &json!({"id":2,"result":{"healthy":true}}))
        .await
        .unwrap();
    assert_eq!(writer_json(&mut socket).await["result"]["healthy"], true);
    assert!(gateway.clients.contains_key(&1));
    gateway.ingest_agent_notification(json!({"method":"item/completed","params":{
        "threadId":"claude_a","turnId":"turn","item":{"type":"mcpToolCall","id":"tool","result":{"content":[{"type":"text","text":nested}]}}
    }})).await;
    let close = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            match socket.next().await.unwrap().unwrap() {
                UpstreamMessage::Close(close) => break close.unwrap(),
                UpstreamMessage::Text(_) => {
                    panic!("nested capacity must close before content or announcement")
                }
                _ => {}
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(u16::from(close.code), 1009);
    assert!(!gateway.clients.contains_key(&1));
    let replay = gateway
        .core
        .lock()
        .await
        .notification_history
        .replay(
            &crate::notifications::history::ReplayRequest::from_params(None),
            crate::time::unix_seconds(),
        )
        .into_wire(crate::time::unix_seconds());
    assert_eq!(replay["notifications"], json!([]));
    assert_eq!(replay["evictedBefore"], true);
    assert_eq!(replay["latestSequence"], 1);
    server.abort();
}

#[tokio::test]
async fn historical_id_capacity_rejects_owned_identifiers_before_projection_and_keeps_rpc_usable() {
    use crate::providers::claude::settings::ClaudeSettings;
    use crate::providers::codex::daemon::CodexAppServer;
    use crate::rpc::dispatch::ClaudeMethod;
    use std::io::Write;
    let mut home = ClaudeSettings::isolated_for_test();
    home.settings.enabled = true;
    let gateway = TestGateway::with_settings(
        Arc::new(CodexAppServer::new(
            "/bin/true".into(),
            std::collections::HashMap::new(),
        )),
        home.settings.clone(),
        Arc::new(home),
    );
    let project = gateway.claude_settings.claude_home.join("projects/fixture");
    std::fs::create_dir_all(&project).unwrap();
    let path = project.join("a.jsonl");
    let (client, mut socket, server) = writer_connection(&gateway, 1).await;
    for (record_index, pointer, length) in [
        (1, "/message/id", 40 * 1024 * 1024),
        (0, "/uuid", 4097),
        (1, "/message/content/1/id", 4097),
        (2, "/message/content/0/tool_use_id", 4097),
        (3, "/attachment/source_uuid", 4097),
    ] {
        let mut records = vec![
            json!({"type":"user","uuid":"prompt","timestamp":"2026-10-08T02:00:00Z","cwd":"/tmp","message":{"role":"user","content":"Hello"}}),
            json!({"type":"assistant","uuid":"reply","timestamp":"2026-10-08T02:00:01Z","message":{"id":"assistant","role":"assistant","content":[{"type":"text","text":"Answer"},{"type":"tool_use","id":"tool","name":"Read","input":{}}]}}),
            json!({"type":"user","uuid":"result","timestamp":"2026-10-08T02:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool","content":"Read result"}]}}),
            json!({"type":"attachment","uuid":"queued","timestamp":"2026-10-08T02:00:03Z","attachment":{"type":"queued_command","commandMode":"prompt","source_uuid":"queued-prompt","prompt":"Continue"}}),
        ];
        *records[record_index].pointer_mut(pointer).unwrap() = json!("x".repeat(length));
        let mut file = std::fs::File::create(&path).unwrap();
        for record in &records {
            serde_json::to_writer(&mut file, record).unwrap();
            file.write_all(b"\n").unwrap();
        }
        drop(file);
        for (id, method, target, params) in [
            (
                1,
                "thread/items/list",
                ClaudeMethod::ItemsPage,
                json!({"threadId":"claude_a","limit":1,"sortDirection":"desc"}),
            ),
            (
                2,
                "thread/turns/list",
                ClaudeMethod::TurnsPage,
                json!({"threadId":"claude_a","limit":1,"itemsView":"full"}),
            ),
        ] {
            gateway
                .handle_owned_rpc(
                    client.id,
                    &client,
                    method,
                    OwnedTarget::Claude(target),
                    json!({"id":id,"params":params}).as_object().unwrap(),
                )
                .await
                .unwrap();
            let response = writer_json(&mut socket).await;
            assert_eq!(response["id"], id);
            assert_eq!(
                response["error"]["code"],
                crate::rpc::error::RpcCode::Capacity.value(),
                "{pointer}: {response}"
            );
            assert_eq!(
                response["error"]["data"],
                json!({"kind":"capacity","retryable":false,"resource":"historical provider ID bytes","limit":4096})
            );
            assert!(response.get("result").is_none());
        }
    }
    gateway
        .send_json_awaiting_capacity(&client, &json!({"id":3,"result":{"healthy":true}}))
        .await
        .unwrap();
    assert_eq!(writer_json(&mut socket).await["result"]["healthy"], true);
    assert!(gateway.clients.contains_key(&1));
    client.closed.cancel();
    server.abort();
}
