use super::*;
use crate::config::ConfigSources;
use std::collections::HashMap;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::{TcpListener, UnixListener};

type Server = tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>;

async fn read(socket: &mut Server) -> Value {
    let Message::Text(text) = socket.next().await.unwrap().unwrap() else {
        panic!("expected RPC frame");
    };
    serde_json::from_str(&text).unwrap()
}

async fn register(socket: &mut Server, process: ProcessInstance, thread: &str, result: Value) {
    socket
        .send(Message::Text(json!({"method":"daemon/ready"}).to_string()))
        .await
        .unwrap();
    let initialize = read(socket).await;
    assert_eq!(initialize["method"], "initialize");
    socket
        .send(Message::Text(json!({"id":0,"result":{}}).to_string()))
        .await
        .unwrap();
    assert_eq!(read(socket).await["method"], "initialized");
    assert_eq!(
        read(socket).await,
        json!({"id":1,"method":"agent/context/capture","params":{"pid":process.pid,"startedAtUnixMicros":process.started_micros}})
    );
    socket.send(Message::Text(json!({"id":1,"result":{"contextId":"captured-context","provider":"claude","threadId":thread,"turnId":null}}).to_string())).await.unwrap();
    assert_eq!(
        read(socket).await,
        json!({"id":2,"method":"agent/routes/register","params":{"caller":{"kind":"captured","contextId":"captured-context"}}})
    );
    socket
        .send(Message::Text(json!({"id":2,"result":result}).to_string()))
        .await
        .unwrap();
}

#[tokio::test]
async fn retained_holder_reconnects_without_replaying_a_forwarded_native_input() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let native_socket = directory.path().join("native");
    let native_listener = UnixListener::bind(&native_socket).unwrap();
    let process = current_process().unwrap();
    let session = "11111111-2222-4333-8444-555555555555";
    let conversation = ConversationIdentity {
        provider: Provider::Claude,
        provider_home: ProviderHome::Known {
            path: directory.path().into(),
        },
        thread_id: crate::providers::claude::claude_thread_id(session),
    };
    let owner = NativeSessionOwner {
        pid: process.pid,
        started_micros: process.started_micros,
        session_uuid: session.into(),
        cwd: directory.path().into(),
        socket_path: native_socket.clone(),
    };
    let format = time::format_description::parse_owned::<3>("[weekday repr:short] [month repr:short] [day padding:space] [hour]:[minute]:[second] [year]").unwrap();
    let started =
        time::OffsetDateTime::from_unix_timestamp((process.started_micros / 1_000_000) as i64)
            .unwrap()
            .format(&format)
            .unwrap();
    std::fs::create_dir(directory.path().join("sessions")).unwrap();
    std::fs::write(directory.path().join("sessions").join(format!("{}.json",process.pid)), serde_json::to_vec(&json!({"pid":process.pid,"sessionId":session,"cwd":directory.path(),"messagingSocketPath":native_socket,"pidDomain":"darwin","procStart":started})).unwrap()).unwrap();
    let (submitted, mut submissions) = tokio::sync::mpsc::channel(4);
    let native_server = tokio::spawn(async move {
        loop {
            let (stream, _) = native_listener.accept().await.unwrap();
            let mut lines = BufReader::new(stream).lines();
            let Some(auth) = lines.next_line().await.unwrap() else {
                continue;
            };
            assert_eq!(
                serde_json::from_str::<Value>(&auth).unwrap(),
                json!({"type":"auth","token":"isolated-process-token"})
            );
            let user: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            submitted.send(user).await.unwrap();
        }
    });
    let gateway = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = GatewayEndpoint::load(&ConfigSources::from_file_vars(HashMap::from([
        ("RC_CODEX_GATEWAY_BIND_HOST".into(), "127.0.0.1".into()),
        (
            "RC_CODEX_GATEWAY_PORT".into(),
            gateway.local_addr().unwrap().port().to_string(),
        ),
        (
            "RC_CODEX_GATEWAY_AUTH_TOKEN".into(),
            "isolated-agent-holder-token-01234567890123".into(),
        ),
    ])))
    .unwrap();
    let message = NativeMessage::new(
        conversation.clone(),
        "completion-1".into(),
        "finished delegated work".into(),
    )
    .unwrap();
    let thread = conversation.thread_id.clone();
    let expected_uuid = message.input_id().to_owned();
    let server = tokio::spawn(async move {
        let (stream, _) = gateway.accept().await.unwrap();
        let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
        register(
            &mut socket,
            process,
            &thread,
            json!({"kind":"native","routeId":"route-1"}),
        )
        .await;
        socket.send(Message::Text(json!({"method":"agent/routes/deliver","params":{"routeId":"route-1","attemptId":"22222222-2222-4333-8444-555555555555","message":message}}).to_string())).await.unwrap();
        let ack = read(&mut socket).await;
        assert_eq!(
            ack,
            json!({"id":3,"method":"agent/routes/ack","params":{"routeId":"route-1","attemptId":"22222222-2222-4333-8444-555555555555","state":{"kind":"submitted"}}})
        );
        assert!(!ack.to_string().contains("isolated-process-token"));
        socket.close(None).await.unwrap();
        let (stream, _) = gateway.accept().await.unwrap();
        let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
        register(
            &mut socket,
            process,
            &thread,
            json!({"kind":"native","routeId":"route-2"}),
        )
        .await;
        assert!(
            tokio::time::timeout(Duration::from_millis(30), socket.next())
                .await
                .is_err()
        );
        socket.close(None).await.unwrap();
    });
    let forwarder = NativeParentForwarder::new(
        conversation.clone(),
        owner.clone(),
        "isolated-process-token".into(),
    )
    .unwrap();
    for _ in 0..2 {
        let mut socket = transport::connect(&endpoint).await.unwrap();
        assert!(matches!(
            serve(
                &mut socket,
                process,
                &conversation,
                directory.path(),
                &owner,
                &forwarder
            )
            .await
            .unwrap(),
            SessionEnd::Disconnected
        ));
    }
    server.await.unwrap();
    assert_eq!(submissions.recv().await.unwrap()["uuid"], expected_uuid);
    assert!(submissions.try_recv().is_err());
    native_server.abort();
    let _ = native_server.await;
}
