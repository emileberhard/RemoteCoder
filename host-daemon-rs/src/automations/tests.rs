use super::*;
use crate::rpc::dispatch::{DispatchPlan, OwnedRoute, OwnedTarget, RequestLifetime};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;

// This fixture exercises actual Unix HTTP delivery, without live homes or service processes.
async fn read_request(stream: &mut tokio::net::UnixStream) -> (String, Value) {
    let mut bytes = Vec::new();
    loop {
        let mut chunk = [0; 4096];
        let count = stream.read(&mut chunk).await.unwrap();
        assert!(count > 0, "HTTP request ended before its body");
        bytes.extend_from_slice(&chunk[..count]);
        if let Some(end) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            let headers = String::from_utf8(bytes[..end].to_vec()).unwrap();
            let length: usize = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse().unwrap())
                })
                .unwrap();
            if bytes.len() >= end + 4 + length {
                let body = serde_json::from_slice(&bytes[end + 4..end + 4 + length]).unwrap();
                return (headers, body);
            }
        }
        assert!(bytes.len() <= REQUEST_LIMIT + 16_384);
    }
}

#[tokio::test]
async fn unix_http_preserves_revision_conflicts_health_definition_fields_and_actor() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("control.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let envelope = json!({"ok":false,"error":{"code":"conflict","current_revision":7},
        "health":{"status":"degraded","reasons":["worker"]}});
    let response = envelope.clone();
    let peer = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let (headers, body) = read_request(&mut stream).await;
        assert!(headers.starts_with("POST /rpc HTTP/1.1"));
        let actor = headers
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("x-automations-actor")
                    .then(|| value.trim())
            })
            .expect("trusted attribution header");
        assert_eq!(
            serde_json::from_str::<Value>(actor).unwrap(),
            json!({"surface":"remotecoder","authenticated":true})
        );
        assert_eq!(
            body,
            json!({"op":"set","id":"digest","expected_revision":6,
            "request_id":"save-1","replace_definition":true,"reason":"edited prompt","data":{"action":{"provider":"codex",
            "future_setting":{"snake_case":true}},"prompt":"$HOME remains literal"}})
        );
        let bytes = serde_json::to_vec(&response).unwrap();
        stream
            .write_all(
                format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", bytes.len()).as_bytes(),
            )
            .await
            .unwrap();
        stream.write_all(&bytes).await.unwrap();
    });
    let request = prepare("automations/set", json!({"id":"digest","expectedRevision":6,
        "requestId":"save-1","replaceDefinition":true,"reason":"edited prompt","data":{"action":{"provider":"codex",
        "future_setting":{"snake_case":true}},"prompt":"$HOME remains literal"}})).unwrap();
    assert_eq!(call(&socket, request).await.unwrap(), envelope);
    peer.await.unwrap();
}

#[tokio::test]
async fn lost_mutation_acknowledgement_keeps_exact_request_id() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("control.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let peer = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let (_, body) = read_request(&mut stream).await;
        assert_eq!(body["request_id"], "admit-1");
        // Simulate commit followed by transport loss, before any acknowledgement.
    });
    let request = prepare(
        "automations/run",
        json!({"id":"digest","requestId":"admit-1"}),
    )
    .unwrap();
    let error = call(&socket, request).await.unwrap_err();
    assert_eq!(error.kind(), Some("automationAcknowledgementUnknown"));
    let error = error.response(&json!(9));
    assert_eq!(
        error["error"]["data"],
        json!({"kind":"automationAcknowledgementUnknown",
        "retryable":true,"authority":AutomationAuthority::authority().unwrap(),"requestId":"admit-1"})
    );
    peer.await.unwrap();
}

#[tokio::test]
async fn absent_socket_reports_unavailable_without_claiming_a_mutation_was_sent() {
    let directory = tempfile::tempdir().unwrap();
    let request = prepare(
        "automations/remove",
        json!({"id":"digest","expectedRevision":4,"requestId":"remove-1"}),
    )
    .unwrap();
    let error = call(&directory.path().join("absent.sock"), request)
        .await
        .unwrap_err();
    assert_eq!(error.kind(), Some("automationUnavailable"));
    let error = error.response(&json!(1));
    assert_eq!(error["error"]["code"], -32003);
    assert_eq!(
        error["error"]["data"],
        json!({"kind":"automationUnavailable",
        "retryable":true,"authority":AutomationAuthority::authority().unwrap()})
    );
}

#[tokio::test]
async fn oversized_response_is_bounded_and_does_not_claim_mutation_failure() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("control.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let peer = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        read_request(&mut stream).await;
        stream
            .write_all(
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n",
                    RESPONSE_LIMIT + 1
                )
                .as_bytes(),
            )
            .await
            .unwrap();
    });
    let request = prepare(
        "automations/restore",
        json!({"id":"digest","expectedRevision":4,"targetRevision":2,"requestId":"restore-1"}),
    )
    .unwrap();
    let error = call(&socket, request)
        .await
        .unwrap_err()
        .response(&json!(1));
    assert_eq!(
        error["error"]["data"]["kind"],
        "automationAcknowledgementUnknown"
    );
    peer.await.unwrap();
}

#[test]
fn management_routes_stay_host_owned_and_mutations_survive_connection_lifetime() {
    for (method, lifetime, new_work, params) in [
        (
            "automations/status",
            RequestLifetime::Query,
            false,
            json!({}),
        ),
        (
            "automations/list",
            RequestLifetime::Query,
            false,
            json!({"state":"paused"}),
        ),
        (
            "automations/show",
            RequestLifetime::Query,
            false,
            json!({"id":"digest"}),
        ),
        (
            "automations/history",
            RequestLifetime::Query,
            false,
            json!({"id":"digest"}),
        ),
        (
            "automations/set",
            RequestLifetime::Command,
            true,
            json!({"id":"digest"}),
        ),
        (
            "automations/remove",
            RequestLifetime::Command,
            true,
            json!({"id":"digest"}),
        ),
        (
            "automations/restore",
            RequestLifetime::Command,
            true,
            json!({"id":"digest"}),
        ),
        (
            "automations/run",
            RequestLifetime::Command,
            true,
            json!({"id":"digest"}),
        ),
        (
            "automations/run",
            RequestLifetime::Command,
            false,
            json!({"runId":"exact","cancel":true}),
        ),
        (
            "automations/run",
            RequestLifetime::Command,
            true,
            json!({"id":"digest","runId":null}),
        ),
    ] {
        let raw = json!({"id":1,"method":method,"params":params}).to_string();
        let DispatchPlan::Request(request) = DispatchPlan::parse(&raw) else {
            panic!("host RPC was refused");
        };
        let owned = request.owned.expect("automation RPC forwarded to provider");
        assert!(matches!(
            owned.target,
            OwnedTarget::Gateway(OwnedRoute::Automations)
        ));
        assert_eq!(owned.lifetime, lifetime);
        assert_eq!(request.starts_new_work, new_work);
    }
}

#[test]
fn request_boundary_rejects_unsafe_writes_and_top_level_contract_drift() {
    for (method, params) in [
        ("automations/set", json!({"id":"x","requestId":"one"})),
        ("automations/remove", json!({"id":"x","expectedRevision":2})),
        (
            "automations/restore",
            json!({"id":"x","requestId":"one","expectedRevision":2,"targetRevision":0}),
        ),
        ("automations/list", json!({"limit":201})),
        ("automations/list", json!({"search":"x".repeat(201)})),
        ("automations/show", json!({"id":"x","search":"digest"})),
        ("automations/show", json!({"id":"x","outputLimit":262145})),
        ("automations/status", json!({"data":{"x":1}})),
        (
            "automations/remove",
            json!({"id":"x","expectedRevision":2,"requestId":"one","replaceDefinition":true}),
        ),
        (
            "automations/run",
            json!({"id":"x","requestId":"one","replaceDefinition":false}),
        ),
        (
            "automations/set",
            json!({"id":"x","request_id":"one","expectedRevision":0}),
        ),
        (
            "automations/set",
            json!({"id":"x","requestId":"one","expectedRevision":0,"actor":{"name":"spoof"}}),
        ),
    ] {
        assert_eq!(
            prepare(method, params).unwrap_err().code,
            RpcCode::InvalidParams
        );
    }
}

#[tokio::test]
async fn preparation_can_complete_after_a_read_would_have_timed_out() {
    // Start each real Unix request before pausing time, so reactor readiness is
    // not replaced by Tokio's automatic idle-clock advancement.
    for (method, params, delay, succeeds) in [
        ("automations/status", json!({}), 21, false),
        (
            "automations/set",
            json!({"id":"digest","expectedRevision":2,"requestId":"set-slow"}),
            75,
            true,
        ),
        (
            "automations/restore",
            json!({"id":"digest","targetRevision":1,"expectedRevision":2,"requestId":"restore-slow"}),
            75,
            true,
        ),
        (
            "automations/run",
            json!({"id":"digest","requestId":"run-slow"}),
            75,
            true,
        ),
        (
            "automations/run",
            json!({"id":"digest","requestId":"run-timeout"}),
            301,
            false,
        ),
    ] {
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("control.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let (received_tx, received_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = tokio::sync::oneshot::channel();
        let peer = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            read_request(&mut stream).await;
            received_tx.send(()).unwrap();
            release_rx.await.unwrap();
            let body = br#"{"ok":true,"data":{"admitted":true},"health":{"status":"healthy"}}"#;
            // A read or over-budget mutation may already have closed its socket.
            let _ = stream
                .write_all(
                    format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", body.len()).as_bytes(),
                )
                .await;
            let _ = stream.write_all(body).await;
        });
        let request = prepare(method, params).unwrap();
        let pending = tokio::spawn(async move { call(&socket, request).await });
        received_rx.await.unwrap();
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(delay)).await;
        tokio::task::yield_now().await;
        tokio::time::resume();
        release_tx.send(()).unwrap();
        let result = pending.await.unwrap();
        if succeeds {
            assert_eq!(result.unwrap()["data"]["admitted"], true, "{method}");
        } else {
            let error = result.unwrap_err();
            assert_eq!(
                error.kind(),
                Some(if method == "automations/status" {
                    "automationUnavailable"
                } else {
                    "automationAcknowledgementUnknown"
                })
            );
        }
        peer.await.unwrap();
    }
}

#[tokio::test]
async fn inventory_search_reaches_service_as_literal_text_before_pagination() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("control.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let peer = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let (_, body) = read_request(&mut stream).await;
        assert_eq!(
            body,
            json!({"op":"list","search":"%_☃","limit":50,"offset":200,"include_removed":true})
        );
        let bytes = br#"{"ok":true,"data":{"items":[],"offset":200,"limit":50},"health":{"status":"healthy"}}"#;
        stream
            .write_all(
                format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", bytes.len()).as_bytes(),
            )
            .await
            .unwrap();
        stream.write_all(bytes).await.unwrap();
    });
    let request = prepare(
        "automations/list",
        json!({"search":"%_☃","limit":50,"offset":200,"includeRemoved":true}),
    )
    .unwrap();
    assert_eq!(call(&socket, request).await.unwrap()["data"]["offset"], 200);
    peer.await.unwrap();
}
