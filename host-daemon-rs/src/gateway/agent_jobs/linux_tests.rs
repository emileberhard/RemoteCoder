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
    let crate::platform::process::ProcessBirth::Linux { birth } = identity.birth else {
        panic!("Linux process birth expected");
    };
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
            birth: crate::platform::process::ProcessBirth::Linux { birth },
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
                birth: crate::platform::process::ProcessBirth::Linux { birth: stale },
            })
            .await
            .is_err()
    );
    assert!(serde_json::from_value::<CaptureParams>(json!({"pid":pid})).is_err());
    assert!(
        serde_json::from_value::<CaptureParams>(json!({"pid":pid,"birth":{"platform":"linux"}}))
            .is_err()
    );
}

#[tokio::test]
#[ignore = "requires system bubblewrap and enabled unprivileged PID namespaces"]
async fn sandboxed_capture_uses_the_kernel_host_pid_instead_of_the_namespace_pid() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let gateway = TestGateway::with_native_runtime(directory.path());
    gateway.jobs.initialize().await.unwrap();
    let socket = gateway.job_coordination_socket().unwrap();
    let mut control = FakeControl::attach(&gateway, 2).await;
    let provider = gateway.clone();
    let responder = tokio::spawn(async move {
        let raw = control.requests.recv().await.unwrap();
        let request: Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(request["method"], "daemon/toolContext");
        let pid = request["params"]["pid"].as_i64().unwrap() as i32;
        let peer = crate::platform::process::identify_instance(pid)
            .unwrap()
            .unwrap();
        assert_eq!(request["params"], peer.native_value());
        provider.control_requests.lock().unwrap()
            .remove(request["id"].as_str().unwrap()).unwrap()
            .send(Ok(json!({"context":{"threadId":"sandbox-thread","turnId":"sandbox-turn","toolCallId":"sandbox-tool","rootProcessIdentity":peer.native_value()}}))).unwrap();
        peer
    });
    let script = r#"import json,os,socket,sys
stream=socket.socket(socket.AF_UNIX)
stream.connect(sys.argv[1])
stream.sendall(b'{"method":"capture","params":{}}\n')
response=json.load(stream.makefile())
print(json.dumps({"namespacePid":os.getpid(),"response":response}))
"#;
    let child = tokio::process::Command::new("/usr/bin/bwrap")
        .args([
            "--ro-bind",
            "/",
            "/",
            "--dev",
            "/dev",
            "--proc",
            "/proc",
            "--unshare-pid",
            "--die-with-parent",
            "--",
            "/usr/bin/python3",
            "-c",
            script,
        ])
        .arg(socket)
        .env_clear()
        .kill_on_drop(true)
        .output();
    let output = tokio::time::timeout(std::time::Duration::from_secs(10), child)
        .await
        .unwrap()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let output: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(output["response"].get("error").is_none(), "{output}");
    let context: CapturedContext =
        serde_json::from_value(output["response"]["result"].clone()).unwrap();
    let peer = responder.await.unwrap();
    assert_ne!(
        i64::from(peer.pid),
        output["namespacePid"].as_i64().unwrap()
    );
    assert_eq!(context.thread_id, "sandbox-thread");
    assert_eq!(context.turn_id.as_deref(), Some("sandbox-turn"));
    let saved = gateway
        .jobs
        .contexts
        .get(&context.context_id)
        .await
        .unwrap();
    assert_eq!(saved.process, peer);
}
