use super::*;
use crate::test_support::{FakeControl, TestGateway};

#[tokio::test]
async fn capture_passes_linux_birth_to_codex_and_rejects_stale_or_missing_proof() {
    let directory = tempfile::tempdir().unwrap();
    let gateway = TestGateway::with_native_runtime(directory.path());
    let pid = std::process::id();
    let identity = crate::platform::process::identify(pid as i32)
        .unwrap()
        .unwrap();
    let birth = identity.linux_birth;
    let mut control = FakeControl::attach(&gateway, 2).await;
    let provider = gateway.clone();
    let responder = tokio::spawn(async move {
        let raw = control.requests.recv().await.unwrap();
        let request: Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(request["method"], "daemon/toolContext");
        assert_eq!(request["params"], json!({"pid":pid,"linuxBirth":birth}));
        provider.control_requests.lock().unwrap()
            .remove(request["id"].as_str().unwrap()).unwrap()
            .send(Ok(json!({"context":{"threadId":"fixture-thread","turnId":"fixture-turn","toolCallId":"fixture-tool","rootProcessIdentity":{"pid":pid,"linuxBirth":birth}}}))).unwrap();
    });
    let captured = gateway
        .capture_job_context(CaptureParams {
            pid,
            started_at_unix_micros: None,
            linux_birth: Some(birth),
        })
        .await
        .unwrap();
    responder.await.unwrap();
    assert_eq!(captured.thread_id, "fixture-thread");
    assert_eq!(captured.turn_id.as_deref(), Some("fixture-turn"));
    let mut stale = birth;
    stale.start_ticks += 1;
    assert!(
        gateway
            .capture_job_context(CaptureParams {
                pid,
                started_at_unix_micros: None,
                linux_birth: Some(stale),
            })
            .await
            .is_err()
    );
    assert!(
        gateway
            .capture_job_context(CaptureParams {
                pid,
                started_at_unix_micros: None,
                linux_birth: None,
            })
            .await
            .is_err()
    );
}
