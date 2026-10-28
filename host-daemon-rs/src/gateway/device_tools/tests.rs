use super::*;
use crate::providers::Provider;
use crate::test_support::TestGateway;
use tokio::sync::mpsc;

const JPEG: &[u8] = include_bytes!("../../../../dev-tools/fixtures/device-photo.jpg");

fn caller(thread: &str, turn: &str) -> Caller {
    Caller {
        provider: Provider::Codex,
        thread_id: Some(thread.into()),
        turn_id: Some(turn.into()),
    }
}

fn connect(
    gateway: &Gateway,
    id: u64,
    installation: Option<&str>,
) -> (ClientTx, mpsc::Receiver<ClientCommand>) {
    let (tx, receiver) = mpsc::channel(16);
    let client = ClientTx {
        grant: crate::auth::installation_credentials::Grant::Operator,
        content_subscriptions: Arc::default(),
        query_response: None,
        id,
        installation_id: installation.map(str::to_string),
        tx,
        closed: CancellationToken::new(),
    };
    gateway.device_tools.connected(client.clone()).unwrap();
    gateway.clients.insert(id, client.clone());
    (client, receiver)
}

fn declare(gateway: &Gateway, client: u64) {
    gateway
        .device_tools
        .declare(
            client,
            serde_json::from_value(json!({"tools":[{"name":"take_photo","version":1}]})).unwrap(),
        )
        .unwrap();
}

fn invoke(
    gateway: &Arc<Gateway>,
    thread: &str,
    turn: &str,
) -> tokio::task::JoinHandle<ToolOutcome> {
    let gateway = Arc::clone(gateway);
    let caller = caller(thread, turn);
    tokio::spawn(async move {
        gateway
            .invoke_device_photo(&caller, PhotoArguments::default())
            .await
    })
}

async fn notification(receiver: &mut mpsc::Receiver<ClientCommand>) -> Value {
    match receiver.recv().await.unwrap() {
        ClientCommand::Text(text) => serde_json::from_str(&text).unwrap(),
        other => panic!("expected device notification, got {other:?}"),
    }
}

fn photo_result(id: &Value) -> Value {
    json!({"operationId":id,"outcome":"succeeded","content":[
        {"type":"image","mimeType":"image/jpeg","data":base64::engine::general_purpose::STANDARD.encode(JPEG)}
    ]})
}

#[tokio::test]
async fn admitted_input_updates_the_driver_while_internal_delivery_keeps_it_and_operator_input_clears_it()
 {
    for method in [
        "turn/start",
        "turn/steer",
        "claude/message",
        "thread/queue/add",
    ] {
        let gateway = TestGateway::new();
        let (_phone, mut receiver) = connect(&gateway, 1, Some("phone"));
        let (_operator, _) = connect(&gateway, 2, None);
        declare(&gateway, 1);
        let request = json!({"id":7,"method":method,"params":{"threadId":"thread"}});
        gateway
            .device_tools
            .record_input(1, method, &request["params"]);
        for internal in [
            "thread/queue/start",
            "thread/resume",
            "thread/compact/start",
        ] {
            let request = json!({"id":8,"method":internal,"params":{"threadId":"thread"}});
            gateway
                .capture_client_request_locked(2, request.as_object().unwrap())
                .await
                .unwrap();
        }
        let work = invoke(&gateway, "thread", "turn");
        let message = notification(&mut receiver).await;
        assert_eq!(message["method"], "device/tool/invoke", "{method}");
        assert_eq!(
            message["params"]["arguments"],
            json!({"camera":"back","lens":"wide"})
        );
        gateway
            .device_tools
            .result(1, photo_result(&message["params"]["operationId"]))
            .unwrap();
        assert!(!work.await.unwrap().is_error);
        let request = json!({"id":9,"method":method,"params":{"threadId":"thread"}});
        gateway
            .device_tools
            .record_input(2, method, &request["params"]);
        assert_eq!(
            gateway
                .invoke_device_photo(&caller("thread", "turn2"), PhotoArguments::default())
                .await,
            ToolOutcome::error(NO_DRIVER)
        );
    }
}

#[tokio::test]
async fn an_explicit_empty_mac_declaration_clears_the_driver_but_an_old_phone_stays_unsupported() {
    let gateway = TestGateway::new();
    let (_phone, _) = connect(&gateway, 1, Some("phone"));
    let (_mac, _) = connect(&gateway, 2, Some("mac"));
    gateway.device_tools.record_driver(1, "thread");
    assert_eq!(
        gateway
            .invoke_device_photo(&caller("thread", "turn"), PhotoArguments::default())
            .await,
        ToolOutcome::error(UNSUPPORTED)
    );
    gateway
        .device_tools
        .declare(2, serde_json::from_value(json!({"tools":[]})).unwrap())
        .unwrap();
    gateway
        .device_tools
        .record_input(2, "turn/steer", &json!({"threadId":"thread"}));
    assert_eq!(
        gateway
            .invoke_device_photo(&caller("thread", "turn"), PhotoArguments::default())
            .await,
        ToolOutcome::error(NO_DRIVER)
    );
}

#[tokio::test]
async fn voice_utterance_and_handoff_use_the_voice_session_owner_for_both_providers() {
    for external in [false, true] {
        let gateway = TestGateway::new();
        let (_phone, mut receiver) = connect(&gateway, 11, Some("phone"));
        declare(&gateway, 11);
        let mut session = crate::gateway::tests::external_voice_session();
        session.owner_client_id = 11;
        session.conversation_thread_id = "thread".into();
        session.realtime_thread_id = "realtime".into();
        session.uses_external_executor = external;
        gateway.voice.seed(None, Some(session));
        gateway
            .handle_voice_control_notification(
                &json!({"method":"thread/realtime/transcript/done","params":{
                    "threadId":"realtime","role":"user","text":"Take a photo"
                }})
                .to_string(),
            )
            .await;
        let work = invoke(&gateway, "thread", "turn");
        let message = notification(&mut receiver).await;
        gateway
            .device_tools
            .result(11, photo_result(&message["params"]["operationId"]))
            .unwrap();
        assert!(!work.await.unwrap().is_error);
        gateway.device_tools.record_driver(0, "thread");
        gateway.handle_voice_control_notification(&json!({"method":"thread/realtime/itemAdded","params":{
            "threadId":"realtime","item":{"type":"handoff_request","handoff_id":"h","input_transcript":""}
        }}).to_string()).await;
        let work = invoke(&gateway, "thread", "turn2");
        let message = notification(&mut receiver).await;
        gateway
            .device_tools
            .result(11, photo_result(&message["params"]["operationId"]))
            .unwrap();
        assert!(!work.await.unwrap().is_error);
    }
}

#[tokio::test]
async fn availability_reports_unknown_driver_offline_unsupported_and_busy_without_dispatch() {
    let gateway = TestGateway::new();
    assert_eq!(
        gateway
            .invoke_device_photo(&caller("thread", "turn"), PhotoArguments::default())
            .await,
        ToolOutcome::error(UNKNOWN_DRIVER)
    );
    let (phone, mut receiver) = connect(&gateway, 1, Some("phone"));
    gateway.device_tools.record_driver(1, "thread");
    assert_eq!(
        gateway
            .invoke_device_photo(&caller("thread", "turn"), PhotoArguments::default())
            .await,
        ToolOutcome::error(UNSUPPORTED)
    );
    declare(&gateway, 1);
    let work = invoke(&gateway, "thread", "turn");
    let message = notification(&mut receiver).await;
    assert_eq!(
        gateway
            .invoke_device_photo(&caller("thread", "turn"), PhotoArguments::default())
            .await,
        ToolOutcome::error(BUSY)
    );
    assert!(receiver.try_recv().is_err());
    gateway
        .device_tools
        .result(1, photo_result(&message["params"]["operationId"]))
        .unwrap();
    assert!(!work.await.unwrap().is_error);
    gateway.device_tools.disconnected(phone.id);
    assert_eq!(
        gateway
            .invoke_device_photo(&caller("thread", "turn2"), PhotoArguments::default())
            .await,
        ToolOutcome::error(OFFLINE)
    );
    gateway
        .device_tools
        .record_input(phone.id, "turn/steer", &json!({"threadId":"thread"}));
    assert_eq!(
        gateway
            .invoke_device_photo(&caller("thread", "turn3"), PhotoArguments::default())
            .await,
        ToolOutcome::error(UNKNOWN_DRIVER)
    );
}

#[tokio::test]
async fn every_device_refusal_failure_and_cancellation_reaches_the_model() {
    let gateway = TestGateway::new();
    let (_phone, mut receiver) = connect(&gateway, 1, Some("phone"));
    declare(&gateway, 1);
    gateway.device_tools.record_driver(1, "thread");
    for (outcome, reason, expected) in [
        (
            "refused",
            Some("foreground_required"),
            "RemoteCoder must be open on the iPhone screen",
        ),
        (
            "refused",
            Some("permission_denied"),
            "Camera access for RemoteCoder is off",
        ),
        (
            "refused",
            Some("camera_unavailable"),
            "requested iPhone camera is unavailable",
        ),
        (
            "refused",
            Some("lens_unavailable"),
            "requested iPhone camera lens is unavailable",
        ),
        ("refused", Some("busy"), BUSY),
        (
            "refused",
            Some("invalid_arguments"),
            "rejected take_photo's arguments",
        ),
        (
            "refused",
            Some("deadline_passed"),
            "no photo was taken by this operation",
        ),
        ("failed", None, "could not take the photo"),
        ("cancelled", None, "cancelled take_photo"),
    ] {
        let work = invoke(&gateway, "thread", "turn");
        let message = notification(&mut receiver).await;
        let result = json!({"operationId":message["params"]["operationId"],"outcome":outcome,"reason":reason,"detail":"Fixture detail"});
        assert_eq!(
            gateway.device_tools.result(1, result).unwrap(),
            json!({"accepted":true})
        );
        let result = work.await.unwrap();
        assert!(result.is_error);
        let text = result.audit()["text"].as_str().unwrap().to_string();
        assert!(text.contains(expected), "{text}");
        assert!(text.contains("Fixture detail"));
    }
}

#[tokio::test(start_paused = true)]
async fn deadline_disconnect_and_turn_end_reject_late_results_without_recapturing() {
    for end in ["deadline", "disconnect", "turn_end"] {
        let gateway = TestGateway::new();
        let (phone, mut receiver) = connect(&gateway, 1, Some("phone"));
        declare(&gateway, 1);
        gateway.device_tools.record_driver(1, "thread");
        let work = invoke(&gateway, "thread", "turn");
        let message = notification(&mut receiver).await;
        let operation = &message["params"]["operationId"];
        assert_eq!(
            gateway
                .device_tools
                .result(99, photo_result(operation))
                .unwrap(),
            json!({"accepted":false})
        );
        match end {
            "deadline" => tokio::time::advance(DEADLINE).await,
            "disconnect" => gateway.device_tools.disconnected(phone.id),
            _ => {
                gateway.capture_agent_message(&json!({"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"turn","status":"interrupted"}}})).await;
            }
        }
        assert_eq!(
            work.await.unwrap(),
            ToolOutcome::error(if end == "turn_end" {
                CANCELLED
            } else {
                UNKNOWN
            })
        );
        assert_eq!(
            gateway
                .device_tools
                .result(1, photo_result(operation))
                .unwrap(),
            json!({"accepted":false})
        );
        if end != "disconnect" {
            let cancel = notification(&mut receiver).await;
            assert_eq!(
                cancel,
                json!({"method":"device/tool/cancel","params":{"operationId":operation}})
            );
        }
        let (_new, mut newer) = connect(&gateway, 2, Some("phone"));
        declare(&gateway, 2);
        let next = invoke(&gateway, "thread", "next-turn");
        let message = notification(&mut newer).await;
        gateway
            .device_tools
            .result(2, photo_result(&message["params"]["operationId"]))
            .unwrap();
        assert!(!next.await.unwrap().is_error);
    }
}

#[tokio::test]
async fn successful_photo_keeps_images_when_original_is_invalid_and_names_a_verified_saved_original()
 {
    let directory = tempfile::tempdir().unwrap();
    let store = UploadStore::open_in(directory.path().join("uploads")).unwrap();
    let gateway = TestGateway::new();
    gateway
        .configure_device_photos(store.clone(), directory.path().join("Pictures/RemoteCoder"))
        .unwrap();
    let (_phone, mut receiver) = connect(&gateway, 1, Some("phone"));
    declare(&gateway, 1);
    gateway.device_tools.record_driver(1, "thread");
    for valid in [false, true] {
        use sha2::{Digest, Sha256};
        let digest = format!("{:x}", Sha256::digest(JPEG));
        let stored = stored_original(&store, &digest).await;
        let work = invoke(&gateway, "thread", "turn");
        let message = notification(&mut receiver).await;
        let mut result = photo_result(&message["params"]["operationId"]);
        result["originals"] = json!([{
            "path": stored.path,
            "sha256": if valid { digest } else { "0".repeat(64) },
            "bytes": stored.bytes,
            "camera": "back",
            "lens": "wide",
            "width": 320,
            "height": 240,
        }]);
        gateway.device_tools.result(1, result).unwrap();
        let outcome = work.await.unwrap();
        assert!(!outcome.is_error);
        assert!(matches!(outcome.content[0], ToolContent::Image { .. }));
        let audit = outcome.audit();
        let text = audit["text"].as_str().unwrap();
        assert!(text.contains("Back wide camera, 320×240"));
        if valid {
            let path = text
                .split("Full-size original saved at ")
                .nth(1)
                .unwrap()
                .trim_end_matches('.');
            assert_eq!(std::fs::read(path).unwrap(), JPEG);
            assert!(!stored.path.exists());
        } else {
            assert!(text.contains("Full-size original was not saved"));
            assert!(text.contains("SHA-256"));
            assert!(stored.path.exists());
        }
    }
}

#[tokio::test]
async fn both_camera_results_match_the_phone_shape_with_optional_originals_and_detail() {
    let directory = tempfile::tempdir().unwrap();
    let store = UploadStore::open_in(directory.path().join("uploads")).unwrap();
    let gateway = TestGateway::new();
    gateway
        .configure_device_photos(store.clone(), directory.path().join("photos"))
        .unwrap();
    let (_phone, mut receiver) = connect(&gateway, 1, Some("phone"));
    declare(&gateway, 1);
    gateway.device_tools.record_driver(1, "thread");
    for missing_front in [false, true] {
        let mut originals = Vec::new();
        for camera in ["back", "front"] {
            if missing_front && camera == "front" {
                continue;
            }
            use sha2::{Digest, Sha256};
            let digest = format!("{:x}", Sha256::digest(JPEG));
            let stored = stored_original(&store, &digest).await;
            originals.push(json!({"path":stored.path,"bytes":stored.bytes,"sha256":digest,"camera":camera,"lens":"wide","width":320,"height":240}));
        }
        let turn = if missing_front {
            "missing-original"
        } else {
            "full-originals"
        };
        let identity = caller("thread", turn);
        let work = gateway.invoke_device_photo(
            &identity,
            PhotoArguments {
                camera: Camera::Both,
                lens: Lens::Wide,
            },
        );
        tokio::pin!(work);
        assert!(futures_util::poll!(&mut work).is_pending());
        let message = notification(&mut receiver).await;
        let image = photo_result(&Value::Null)["content"][0].clone();
        let result = json!({"operationId":message["params"]["operationId"],"outcome":"succeeded","content":[image.clone(),image],"originals":originals,"detail":if missing_front {Some("Front original upload failed: connection closed.")} else {None}});
        assert_eq!(
            gateway.device_tools.result(1, result).unwrap(),
            json!({"accepted":true})
        );
        gateway.device_tools.turn_ended("thread", turn);
        let outcome = work.await;
        assert!(!outcome.is_error);
        assert_eq!(outcome.audit()["imageCount"], 2);
        let audit = outcome.audit();
        let text = audit["text"].as_str().unwrap();
        assert!(
            text.find("Back wide camera, 320×240").unwrap()
                < text.find("Front wide camera, 320×240").unwrap()
        );
        assert_eq!(
            text.matches("Full-size original saved at ").count(),
            if missing_front { 1 } else { 2 }
        );
        for line in text
            .lines()
            .filter(|line| line.contains("Full-size original saved at "))
        {
            let path = line
                .split("Full-size original saved at ")
                .nth(1)
                .unwrap()
                .trim_end_matches('.');
            assert_eq!(std::fs::read(path).unwrap(), JPEG);
        }
        if missing_front {
            assert!(text.contains("the iPhone did not upload it"));
            assert!(text.contains("Front original upload failed: connection closed."));
        }
        assert!(receiver.try_recv().is_err());
    }
}

#[tokio::test]
async fn refused_claude_steer_message_and_invalid_queue_input_keep_the_previous_driver() {
    let gateway = TestGateway::new();
    let (_phone, _) = connect(&gateway, 1, Some("phone"));
    let (operator, mut replies) = connect(&gateway, 2, None);
    for (method, target, thread) in [
        (
            "turn/steer",
            crate::rpc::dispatch::OwnedTarget::Claude(
                crate::rpc::dispatch::ClaudeMethod::TurnSteer,
            ),
            "claude_74625c52-f095-4eee-a771-abc123",
        ),
        (
            "claude/message",
            crate::rpc::dispatch::OwnedTarget::Claude(crate::rpc::dispatch::ClaudeMethod::Message),
            "claude_74625c52-f095-4eee-a771-abc123",
        ),
        (
            "thread/queue/add",
            crate::rpc::dispatch::OwnedTarget::Gateway(
                crate::rpc::dispatch::OwnedRoute::NativeQueue,
            ),
            "018f4f77-7277-7333-8444-0123456789ab",
        ),
    ] {
        gateway.device_tools.record_driver(1, thread);
        let request = json!({"id":7,"method":method,"params":{"threadId":thread}});
        gateway
            .handle_owned_rpc(2, &operator, method, target, request.as_object().unwrap())
            .await
            .unwrap();
        let reply = notification(&mut replies).await;
        assert!(reply.get("error").is_some());
        assert_eq!(
            gateway
                .invoke_device_photo(&caller(thread, "turn"), PhotoArguments::default())
                .await,
            ToolOutcome::error(UNSUPPORTED)
        );
    }
}

#[tokio::test]
async fn duplicate_codex_requests_share_one_device_dispatch_and_the_tombstone_result() {
    let gateway = TestGateway::new();
    let (_phone, mut receiver) = connect(&gateway, 1, Some("phone"));
    declare(&gateway, 1);
    gateway.device_tools.record_driver(1, "thread");
    let call = |id| {
        crate::agents::tools::codex_tool_call(&json!({"id":id,"method":"item/tool/call","params":{
        "threadId":"thread","turnId":"turn","callId":"call","namespace":"remotecoder","tool":"take_photo","arguments":{}
    }})).unwrap()
    };
    let first = tokio::spawn({
        let gateway = gateway.clone();
        let call = call(1);
        async move { gateway.codex_tool_response(call).await.unwrap() }
    });
    let second = tokio::spawn({
        let gateway = gateway.clone();
        let call = call(2);
        async move { gateway.codex_tool_response(call).await.unwrap() }
    });
    let message = notification(&mut receiver).await;
    gateway
        .device_tools
        .result(1, photo_result(&message["params"]["operationId"]))
        .unwrap();
    let first: Value = serde_json::from_str(&first.await.unwrap()).unwrap();
    let second: Value = serde_json::from_str(&second.await.unwrap()).unwrap();
    assert_eq!(first["id"], 1);
    assert_eq!(second["id"], 2);
    assert_eq!(first["result"], second["result"]);
    let late: Value =
        serde_json::from_str(&gateway.codex_tool_response(call(3)).await.unwrap()).unwrap();
    assert_eq!(late["result"], first["result"]);
    assert!(receiver.try_recv().is_err());
}

#[tokio::test(start_paused = true)]
async fn invalid_results_settle_immediately_and_only_the_invoked_connection_can_complete_once() {
    let gateway = TestGateway::new();
    let (_old, mut old) = connect(&gateway, 1, Some("phone"));
    let (_new, mut newest) = connect(&gateway, 2, Some("phone"));
    declare(&gateway, 1);
    declare(&gateway, 2);
    gateway.device_tools.record_driver(1, "thread");
    for content in [
        json!([]),
        json!([{"type":"text","text":"Captured"}, photo_result(&Value::Null)["content"][0].clone()]),
        json!([{"type":"image","mimeType":"image/png","data":"bad"}]),
        json!([{"type":"image","mimeType":"image/jpeg","data":"not base64"}]),
        json!([{"type":"image","mimeType":"image/jpeg","data":"cGhvdG8="}]),
        json!([{"type":"image","mimeType":"image/jpeg","data":"x".repeat(3 * 1024 * 1024 + 1)}]),
        json!([{"type":"unknown"}]),
    ] {
        let work = invoke(&gateway, "thread", "turn");
        let message = notification(&mut newest).await;
        let id = &message["params"]["operationId"];
        assert!(old.try_recv().is_err());
        assert_eq!(
            gateway.device_tools.result(1, photo_result(id)).unwrap(),
            json!({"accepted":false})
        );
        let invalid = json!({"operationId":id,"outcome":"succeeded","content":content});
        let error = gateway.device_tools.result(2, invalid).unwrap_err();
        assert_eq!(error.code, RpcCode::InvalidParams);
        let outcome = tokio::time::timeout(Duration::from_millis(1), work)
            .await
            .unwrap()
            .unwrap();
        assert!(outcome.is_error);
        let audit = outcome.audit();
        let text = audit["text"].as_str().unwrap();
        assert!(text.contains("invalid take_photo result"));
        assert!(text.contains(&error.message));
        assert_eq!(
            gateway.device_tools.result(2, photo_result(id)).unwrap(),
            json!({"accepted":false})
        );
    }
    let work = invoke(&gateway, "thread", "turn");
    let message = notification(&mut newest).await;
    let id = &message["params"]["operationId"];
    assert_eq!(
        gateway.device_tools.result(2, photo_result(id)).unwrap(),
        json!({"accepted":true})
    );
    assert_eq!(
        gateway.device_tools.result(2, photo_result(id)).unwrap(),
        json!({"accepted":false})
    );
    assert!(!work.await.unwrap().is_error);
}

#[tokio::test(start_paused = true)]
async fn accepted_results_win_over_a_later_deadline_disconnect_or_turn_cancellation() {
    for end in ["deadline", "disconnect", "turn_end"] {
        let gateway = TestGateway::new();
        let (_phone, mut receiver) = connect(&gateway, 1, Some("phone"));
        declare(&gateway, 1);
        gateway.device_tools.record_driver(1, "thread");
        let identity = caller("thread", "turn");
        let work = gateway.invoke_device_photo(&identity, PhotoArguments::default());
        tokio::pin!(work);
        assert!(futures_util::poll!(&mut work).is_pending());
        let message = notification(&mut receiver).await;
        tokio::time::advance(DEADLINE - Duration::from_secs(1)).await;
        assert_eq!(
            gateway
                .device_tools
                .result(1, photo_result(&message["params"]["operationId"]))
                .unwrap(),
            json!({"accepted":true})
        );
        match end {
            "deadline" => tokio::time::advance(Duration::from_secs(2)).await,
            "disconnect" => gateway.device_tools.disconnected(1),
            _ => gateway.device_tools.turn_ended("thread", "turn"),
        }
        let outcome = work.await;
        assert!(!outcome.is_error, "{end}: {outcome:?}");
        assert!(matches!(outcome.content[0], ToolContent::Image { .. }));
        assert!(receiver.try_recv().is_err());
    }
}

#[tokio::test]
async fn global_camera_capacity_and_dropped_waiters_release_only_their_own_operations() {
    let gateway = TestGateway::new();
    let mut work = Vec::new();
    let mut receivers = Vec::new();
    for id in 1..=9 {
        let (_phone, mut receiver) = connect(&gateway, id, Some(&format!("phone-{id}")));
        declare(&gateway, id);
        gateway
            .device_tools
            .record_driver(id, &format!("thread-{id}"));
        if id <= 8 {
            let task = invoke(&gateway, &format!("thread-{id}"), "turn");
            let message = notification(&mut receiver).await;
            work.push(task);
            receivers.push((receiver, message));
        } else {
            assert_eq!(
                gateway
                    .invoke_device_photo(&caller("thread-9", "turn"), PhotoArguments::default())
                    .await,
                ToolOutcome::error(BUSY)
            );
        }
    }
    work.remove(0).abort();
    let cancel = notification(&mut receivers[0].0).await;
    assert_eq!(cancel["method"], "device/tool/cancel");
    assert_eq!(
        cancel["params"]["operationId"],
        receivers[0].1["params"]["operationId"]
    );
    let (phone, mut receiver) = connect(&gateway, 10, Some("phone-9"));
    declare(&gateway, 10);
    let ninth = invoke(&gateway, "thread-9", "turn");
    let message = notification(&mut receiver).await;
    gateway
        .device_tools
        .result(phone.id, photo_result(&message["params"]["operationId"]))
        .unwrap();
    assert!(!ninth.await.unwrap().is_error);
    for (index, task) in work.into_iter().enumerate() {
        gateway
            .device_tools
            .result(
                index as u64 + 2,
                photo_result(&receivers[index + 1].1["params"]["operationId"]),
            )
            .unwrap();
        assert!(!task.await.unwrap().is_error);
    }
}

async fn socket_json<S>(socket: &mut tokio_tungstenite::WebSocketStream<S>) -> Value
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    use futures_util::StreamExt;
    loop {
        let message = socket.next().await.unwrap().unwrap();
        if let tokio_tungstenite::tungstenite::Message::Text(text) = message {
            let value: Value = serde_json::from_str(&text).unwrap();
            if value["method"] != "daemon/ready" {
                return value;
            }
        }
    }
}

#[tokio::test]
async fn a_disconnect_observer_processes_turn_end_while_joining_a_pending_photo_claim() {
    use futures_util::SinkExt;
    use tokio_tungstenite::tungstenite::Message;
    let home = tempfile::tempdir().unwrap();
    let socket_directory = home.path().join("app-server-control");
    std::fs::create_dir(&socket_directory).unwrap();
    let listener =
        tokio::net::UnixListener::bind(socket_directory.join("app-server-control.sock")).unwrap();
    let (complete, completed) = oneshot::channel();
    let upstream = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
        let initialize = socket_json(&mut socket).await;
        socket
            .send(Message::Text(
                json!({"id":initialize["id"],"result":{}}).to_string(),
            ))
            .await
            .unwrap();
        let resume = loop {
            let request = socket_json(&mut socket).await;
            if request["method"] == "thread/resume" {
                break request;
            }
        };
        socket.send(Message::Text(json!({"id":resume["id"],"result":{"thread":{"id":"thread","status":{"type":"active"},"turns":[{"id":"turn","status":"inProgress"}]}}}).to_string())).await.unwrap();
        socket.send(Message::Text(json!({"id":"tool-request","method":"item/tool/call","params":{"threadId":"thread","turnId":"turn","callId":"photo","namespace":"remotecoder","tool":"take_photo","arguments":{}}}).to_string())).await.unwrap();
        completed.await.unwrap();
        socket.send(Message::Text(json!({"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"turn","status":"interrupted"}}}).to_string())).await.unwrap();
        loop {
            let request = socket_json(&mut socket).await;
            if request["method"] == "thread/unsubscribe" {
                break;
            }
        }
    });
    let settings =
        Arc::new(crate::providers::claude::settings::ClaudeSettings::isolated_for_test());
    let gateway = TestGateway::with_settings(
        Arc::new(
            crate::providers::codex::daemon::CodexAppServer::new_for_test_socket(
                home.path().into(),
            ),
        ),
        settings.settings.clone(),
        settings,
    );
    let (_phone, mut receiver) = connect(&gateway, 1, Some("phone"));
    declare(&gateway, 1);
    gateway.device_tools.record_driver(1, "thread");
    gateway.core.lock().await.turns.mark_active(
        &crate::turns::TurnKey::new("thread", "turn"),
        crate::time::unix_seconds(),
        Some(crate::time::unix_seconds()),
        Some(42),
    );
    let primary = tokio::spawn({
        let gateway = gateway.clone();
        async move {
            let call = crate::agents::tools::codex_tool_call(&json!({"id":"primary-request","method":"item/tool/call","params":{"threadId":"thread","turnId":"turn","callId":"photo","namespace":"remotecoder","tool":"take_photo","arguments":{}}})).unwrap();
            gateway.codex_tool_response(call).await.unwrap()
        }
    });
    let invocation = tokio::time::timeout(Duration::from_secs(2), notification(&mut receiver))
        .await
        .unwrap();
    gateway.spawn_observers_for_client(42).await;
    complete.send(()).unwrap();
    let cancel = tokio::time::timeout(Duration::from_secs(2), notification(&mut receiver))
        .await
        .unwrap();
    assert_eq!(
        cancel,
        json!({"method":"device/tool/cancel","params":{"operationId":invocation["params"]["operationId"]}})
    );
    tokio::time::timeout(Duration::from_secs(2), upstream)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(gateway.core.lock().await.turns.active_count(), 0);
    let reply: Value = serde_json::from_str(&primary.await.unwrap()).unwrap();
    assert_eq!(reply["result"]["success"], false);
    assert!(
        reply["result"]["contentItems"][0]["text"]
            .as_str()
            .unwrap()
            .contains("turn ended")
    );
    assert!(receiver.try_recv().is_err());
    gateway.stop().await.unwrap();
}

async fn stored_original(store: &UploadStore, digest: &str) -> crate::files::upload::StoredUpload {
    use crate::files::upload::{Append, Declaration, UploadId};
    static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(1);
    let number = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let id = UploadId::parse(&format!("00000000-0000-4000-8000-{number:012x}")).unwrap();
    let declaration = Declaration {
        name: "original.jpg",
        length: JPEG.len() as u64,
        sha256: digest,
    };
    let append = Append {
        offset: 0,
        content_length: JPEG.len() as u64,
    };
    let body = futures_util::stream::iter([Ok::<_, std::convert::Infallible>(
        axum::body::Bytes::from_static(JPEG),
    )]);
    store.append(&id, declaration, append, body).await.unwrap()
}
