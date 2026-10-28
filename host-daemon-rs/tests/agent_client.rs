#![cfg(target_os = "macos")]

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, UnixListener};
use tokio_tungstenite::tungstenite::Message;

struct PrivateTmux {
    socket: PathBuf,
}

impl PrivateTmux {
    fn command(&self) -> Command {
        let mut command = Command::new("tmux");
        command.arg("-S").arg(&self.socket);
        command
    }

    fn start(root: &Path) -> Self {
        let tmux = Self {
            socket: root.join("tmux.sock"),
        };
        let output = tmux
            .command()
            .env_clear()
            .env("HOME", root)
            .env("PATH", "/opt/homebrew/bin:/usr/bin:/bin")
            .args([
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-s",
                "anchor",
                "/bin/sleep",
                "60",
            ])
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        assert!(
            tmux.command()
                .args(["set-option", "-g", "update-environment", ""])
                .status()
                .unwrap()
                .success()
        );
        for (name, value) in [
            (
                "CLAUDE_CODE_SESSION_ID",
                "11111111-2222-4333-8444-555555555555",
            ),
            ("CODEX_THREAD_ID", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            ("AGENT_ID", "another-agent"),
            (
                "EMILS_SUBAGENT_CONTROL_SOCKET",
                "/tmp/another-agent/control.sock",
            ),
            (
                "REMOTE_CODER_PARENT_CONTEXT",
                "/tmp/another-agent/context.json",
            ),
            ("CODEX_HOME", "/tmp/another-agent/codex"),
        ] {
            assert!(
                tmux.command()
                    .args(["set-environment", "-g", name, value])
                    .status()
                    .unwrap()
                    .success()
            );
        }
        tmux
    }

    async fn run(&self, root: &Path, arguments: &[&str]) -> (i32, Value) {
        fn quote(value: &str) -> String {
            format!("'{}'", value.replace('\'', "'\\''"))
        }
        let binary = env!("CARGO_BIN_EXE_remote-coder-codex-gateway");
        let env_file = root.join("gateway.env");
        let stdout = root.join("result.json");
        let status = root.join("status");
        let wrapper = root.join("detached.sh");
        let arguments = arguments
            .iter()
            .map(|argument| quote(argument))
            .collect::<Vec<_>>()
            .join(" ");
        std::fs::write(
            &wrapper,
            format!(
                "{} --env-file {} agent {arguments} >{} 2>{}\nprintf '%s' $? >{}\n",
                quote(binary),
                quote(env_file.to_str().unwrap()),
                quote(stdout.to_str().unwrap()),
                quote(root.join("stderr").to_str().unwrap()),
                quote(status.to_str().unwrap())
            ),
        )
        .unwrap();
        assert!(
            self.command()
                .args(["new-session", "-d", "-s", "detached", "/bin/sh"])
                .arg(&wrapper)
                .status()
                .unwrap()
                .success()
        );
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                if let Ok(code) = std::fs::read_to_string(&status)
                    && let Ok(exit) = code.parse()
                {
                    let payload = std::fs::read_to_string(&stdout).unwrap();
                    return (exit, serde_json::from_str(&payload).unwrap());
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap()
    }
}

impl Drop for PrivateTmux {
    fn drop(&mut self) {
        let _ = self
            .command()
            .arg("kill-server")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

fn configuration(root: &Path, port: u16) {
    std::fs::write(root.join("gateway.env"), format!("RC_CODEX_GATEWAY_BIND_HOST=127.0.0.1\nRC_CODEX_GATEWAY_PORT={port}\nRC_CODEX_GATEWAY_AUTH_TOKEN=isolated-agent-client-token-0123456789\n")).unwrap();
}

async fn initialize(socket: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>) {
    socket
        .send(Message::Text(json!({"method":"daemon/ready"}).to_string()))
        .await
        .unwrap();
    let Message::Text(text) = socket.next().await.unwrap().unwrap() else {
        panic!("No initialize request");
    };
    assert_eq!(
        serde_json::from_str::<Value>(&text).unwrap()["method"],
        "initialize"
    );
    socket
        .send(Message::Text(json!({"id":0,"result":{}}).to_string()))
        .await
        .unwrap();
    let Message::Text(text) = socket.next().await.unwrap().unwrap() else {
        panic!("No initialized notification");
    };
    assert_eq!(
        serde_json::from_str::<Value>(&text).unwrap()["method"],
        "initialized"
    );
}

#[tokio::test]
async fn agent_client_detached_tmux_rejects_inherited_identity_before_delivery() {
    let root = tempfile::Builder::new()
        .prefix("rc-agent-client-")
        .tempdir_in("/tmp")
        .unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    configuration(root.path(), listener.local_addr().unwrap().port());
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
        initialize(&mut socket).await;
        let Message::Text(text) = socket.next().await.unwrap().unwrap() else {
            panic!("No capture request");
        };
        let request: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(request["method"], "agent/context/capture");
        assert!(request["params"]["pid"].as_u64().unwrap() > 0);
        assert!(request["params"]["startedAtUnixMicros"].as_u64().unwrap() > 0);
        assert_eq!(request["params"].as_object().unwrap().len(), 2);
        socket.send(Message::Text(json!({"id":1,"error":{"code":-32003,"message":"Detached process has no verified caller; pass explicitly captured context","data":{"kind":"unprovenCaller"}}}).to_string())).await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(150), listener.accept())
                .await
                .is_err()
        );
    });
    let tmux = PrivateTmux::start(root.path());
    let (exit, payload) = tmux
        .run(
            root.path(),
            &["message", "parent", "Detached callback", "--json"],
        )
        .await;
    assert_eq!(exit, 69);
    assert_eq!(payload["error"]["data"]["kind"], "unprovenCaller");
    server.await.unwrap();
}

#[tokio::test]
async fn agent_client_stale_scoped_socket_never_falls_back_to_bearer() {
    let root = tempfile::Builder::new()
        .prefix("rc-agent-client-")
        .tempdir_in("/tmp")
        .unwrap();
    let gateway = TcpListener::bind("127.0.0.1:0").await.unwrap();
    configuration(root.path(), gateway.local_addr().unwrap().port());
    let path = root.path().join("other-job.sock");
    let scoped = UnixListener::bind(&path).unwrap();
    let server = tokio::spawn(async move {
        let (mut stream, _) = scoped.accept().await.unwrap();
        let mut line = String::new();
        BufReader::new(&mut stream)
            .read_line(&mut line)
            .await
            .unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(request["method"], "messageParent");
        assert_eq!(request["params"]["deliveryId"], "stable-detached-message");
        stream.write_all(b"{\"error\":{\"kind\":\"unprovenCaller\",\"message\":\"Peer does not belong to this job\",\"retryable\":false}}\n").await.unwrap();
    });
    let tmux = PrivateTmux::start(root.path());
    assert!(
        tmux.command()
            .args(["set-environment", "-g", "RC_AGENT_JOB_SOCKET"])
            .arg(&path)
            .status()
            .unwrap()
            .success()
    );
    let (exit, payload) = tmux
        .run(
            root.path(),
            &[
                "message",
                "parent",
                "Detached callback",
                "--delivery-id",
                "stable-detached-message",
                "--json",
            ],
        )
        .await;
    assert_eq!(exit, 69);
    assert_eq!(payload["error"]["kind"], "unprovenCaller");
    assert_eq!(payload["request_id"], "stable-detached-message");
    assert!(
        tokio::time::timeout(Duration::from_millis(100), gateway.accept())
            .await
            .is_err()
    );
    server.await.unwrap();
}

#[tokio::test]
async fn agent_client_explicit_context_uses_authenticated_owner_despite_stale_socket() {
    let root = tempfile::Builder::new()
        .prefix("rc-agent-client-")
        .tempdir_in("/tmp")
        .unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    configuration(root.path(), listener.local_addr().unwrap().port());
    let path = root.path().join("other-job.sock");
    let stale = UnixListener::bind(&path).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
        initialize(&mut socket).await;
        let Message::Text(text) = socket.next().await.unwrap().unwrap() else {
            panic!("No message request");
        };
        let request: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(request["method"], "agent/jobs/message");
        assert_eq!(
            request["params"]["caller"],
            json!({"kind":"captured","contextId":"explicit-captured-origin"})
        );
        assert_eq!(request["params"]["deliveryId"], "stable-detached-message");
        socket
            .send(Message::Text(
                json!({"id":1,"result":{"accepted":true}}).to_string(),
            ))
            .await
            .unwrap();
    });
    let tmux = PrivateTmux::start(root.path());
    assert!(
        tmux.command()
            .args(["set-environment", "-g", "RC_AGENT_JOB_SOCKET"])
            .arg(&path)
            .status()
            .unwrap()
            .success()
    );
    let (exit, payload) = tmux
        .run(
            root.path(),
            &[
                "message",
                "parent",
                "Detached callback",
                "--caller-context",
                "explicit-captured-origin",
                "--delivery-id",
                "stable-detached-message",
                "--json",
            ],
        )
        .await;
    assert_eq!(exit, 0);
    assert_eq!(payload["accepted"], true);
    assert!(
        tokio::time::timeout(Duration::from_millis(100), stale.accept())
            .await
            .is_err()
    );
    server.await.unwrap();
}
