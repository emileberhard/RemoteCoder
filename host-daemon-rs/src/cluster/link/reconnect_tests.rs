use super::*;
use tokio::net::TcpListener;

struct Peer {
    _directory: tempfile::TempDir,
    link: Link,
    listener: TcpListener,
    identity: crate::http::lan_identity::LanIdentity,
    hello: HelloReceipt,
    membership: String,
}

impl Peer {
    async fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let link = Link::new(
            directory.path(),
            HostIdentity {
                host_id: crate::ids::new_session_uuid(),
                incarnation: crate::ids::new_session_uuid(),
            },
        );
        let host = crate::ids::new_session_uuid();
        let membership = crate::ids::new_session_uuid();
        let credential = link
            .store
            .issue(IssueParams {
                protocol: PROTOCOL,
                r#for: host.clone(),
                name: "peer".into(),
                membership: membership.clone(),
            })
            .await
            .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let identity = crate::http::lan_identity::LanIdentity::load(
            &directory.path().join("tls.der"),
            "127.0.0.1".into(),
        )
        .unwrap();
        link.store
            .accept(AcceptParams {
                protocol: PROTOCOL,
                host: host.clone(),
                name: "peer".into(),
                membership: membership.clone(),
                pin: identity.spki_sha256.clone(),
                routes: vec![format!("wss://{}/ws", listener.local_addr().unwrap())],
                credential,
            })
            .await
            .unwrap();
        Self {
            _directory: directory,
            link,
            listener,
            identity,
            membership,
            hello: HelloReceipt {
                protocol: PROTOCOL,
                version: "test".into(),
                host,
                incarnation: crate::ids::new_session_uuid(),
                capabilities: CAPABILITIES.iter().map(|value| (*value).into()).collect(),
                routes: vec![],
                load: HostLoad {
                    cpu_percent: None,
                    memory_pressure: None,
                    active_agents: 0,
                },
            },
        }
    }
}

type PeerSocket = WebSocketStream<tokio_rustls::server::TlsStream<tokio::net::TcpStream>>;

async fn accept_peer(
    listener: &TcpListener,
    identity: &crate::http::lan_identity::LanIdentity,
    hello: &HelloReceipt,
) -> PeerSocket {
    let (stream, _) = listener.accept().await.unwrap();
    let stream = identity.acceptor.accept(stream).await.unwrap();
    let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
    socket
        .send(Message::Text(json!({"method":"daemon/ready"}).to_string()))
        .await
        .unwrap();
    let request = receive(&mut socket).await;
    assert_eq!(request["method"], "cluster/hello");
    reply(&mut socket, &request, serde_json::to_value(hello).unwrap()).await;
    socket
}

async fn receive(socket: &mut PeerSocket) -> Value {
    loop {
        match socket.next().await.unwrap().unwrap() {
            Message::Text(text) => return serde_json::from_str(&text).unwrap(),
            Message::Pong(_) => {}
            message => panic!("unexpected peer message: {message:?}"),
        }
    }
}

async fn reply(socket: &mut PeerSocket, request: &Value, result: Value) {
    socket
        .send(Message::Text(
            json!({"jsonrpc":"2.0","id":request["id"],"result":result}).to_string(),
        ))
        .await
        .unwrap();
}

#[tokio::test]
async fn cluster_peer_restart_evicts_cached_connection_before_immediate_inventory() {
    let Peer {
        _directory,
        link,
        listener,
        identity,
        hello,
        membership,
    } = Peer::new().await;
    let host = hello.host.clone();
    let (restart, restarting) = tokio::sync::oneshot::channel();
    let (closed, observed_close) = tokio::sync::oneshot::channel();
    let server = tokio::spawn(async move {
        let mut socket = accept_peer(&listener, &identity, &hello).await;
        let request = receive(&mut socket).await;
        assert_eq!(request["method"], "agent/cluster/inventory");
        reply(&mut socket, &request, json!({"agents":[],"generation":1})).await;
        restarting.await.unwrap();
        socket.close(None).await.unwrap();
        drop(socket);
        closed.send(()).unwrap();
        let mut socket = accept_peer(&listener, &identity, &hello).await;
        let request = receive(&mut socket).await;
        assert_eq!(request["method"], "agent/cluster/inventory");
        reply(&mut socket, &request, json!({"agents":[],"generation":2})).await;
    });
    assert_eq!(
        link.call(&host, "agent/cluster/inventory", json!({}))
            .await
            .unwrap()["generation"],
        1
    );
    let slot = link.connections.lock().await[&membership].clone();
    assert!(slot.lock().await.is_some());
    restart.send(()).unwrap();
    observed_close.await.unwrap();
    tokio::time::timeout(Duration::from_secs(2), async {
        while slot.lock().await.is_some() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("idle reader evicts the closed socket without a caller");
    assert_eq!(
        link.call(&host, "agent/cluster/inventory", json!({}))
            .await
            .unwrap()["generation"],
        2
    );
    server.await.unwrap();
}

#[tokio::test]
async fn cluster_transport_reconnect_preserves_mutation_uncertainty() {
    for (method, fail_before_send, attempts) in [
        ("agent/cluster/inventory", false, 2),
        ("agent/jobs/admit", false, 1),
        ("agent/jobs/admit", true, 2),
    ] {
        let Peer {
            _directory,
            link,
            listener,
            identity,
            hello,
            ..
        } = Peer::new().await;
        let host = hello.host.clone();
        let (finished, call_finished) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(async move {
            if fail_before_send {
                let (stream, _) = listener.accept().await.unwrap();
                drop(stream);
            } else {
                let mut socket = accept_peer(&listener, &identity, &hello).await;
                let request = receive(&mut socket).await;
                assert_eq!(request["method"], method);
                drop(socket);
            }
            if attempts == 2 {
                let mut socket = accept_peer(&listener, &identity, &hello).await;
                let request = receive(&mut socket).await;
                assert_eq!(request["method"], method);
                reply(&mut socket, &request, json!({"accepted":true})).await;
            } else {
                tokio::select! {
                    _ = listener.accept() => panic!("a transmitted mutation must not reconnect"),
                    _ = call_finished => {},
                }
            }
        });
        let result = link.call(&host, method, json!({})).await;
        let _ = finished.send(());
        if attempts == 1 {
            let error = result.unwrap_err();
            assert_eq!(error.class, ErrorClass::Uncertain);
            assert!(error.transmitted);
        } else {
            assert_eq!(result.unwrap()["accepted"], true);
        }
        server.await.unwrap();
    }
}
