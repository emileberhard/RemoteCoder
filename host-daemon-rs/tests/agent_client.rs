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
                    let output = std::fs::read_to_string(&stdout).unwrap();
                    let errors = std::fs::read_to_string(root.join("stderr")).unwrap();
                    let payload = if exit == 0 {
                        assert!(errors.is_empty(), "{errors}");
                        output
                    } else {
                        assert!(output.is_empty(), "{output}");
                        errors
                    };
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
    assert_eq!(exit, 4);
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
    assert_eq!(exit, 4);
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
                json!({"id":1,"result":{"deliveryId":"stable-detached-message","deliveryState":{"kind":"accepted","receipt":"fixture-native-custody"}}}).to_string(),
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
    assert_eq!(payload["deliveryId"], "stable-detached-message");
    assert_eq!(payload["deliveryState"]["kind"], "accepted");
    assert!(
        tokio::time::timeout(Duration::from_millis(100), stale.accept())
            .await
            .is_err()
    );
    server.await.unwrap();
}

#[test]
fn agent_client_format_only_reserves_stdout_for_envelopes() {
    let binary = env!("CARGO_BIN_EXE_remote-coder-codex-gateway");
    for text in ["", "Fixture message"] {
        let output = Command::new(binary)
            .env_clear()
            .args(["agent", "message", "parent", text, "--format-only"])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2));
        assert!(output.stdout.is_empty());
        let diagnostic: Value = serde_json::from_slice(&output.stderr).unwrap();
        assert_eq!(diagnostic["ok"], false);
        assert_eq!(diagnostic["error"]["kind"], "usage");
    }
    let output = Command::new(binary)
        .env_clear()
        .args([
            "agent",
            "message",
            "parent",
            "Fixture message",
            "--format-only",
            "--sender-id",
            "/root/fixture",
            "--reply-tool",
            "collaboration.send_message",
            "--reply-target",
            "/root/fixture",
            "--delivery-id",
            "format-fixture",
        ])
        .output()
        .unwrap();
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let envelope = String::from_utf8(output.stdout).unwrap();
    assert!(envelope.starts_with("<agent_message"));
    assert!(envelope.contains("Fixture message"));
    assert!(envelope.trim_end().ends_with("</agent_message>"));
}

#[test]
fn agent_client_message_dash_reads_stdin_and_rejects_blank_input() {
    use std::io::Write;
    for input in ["A multiline\nmessage from stdin", " \n\t"] {
        let mut child = Command::new(env!("CARGO_BIN_EXE_remote-coder-codex-gateway"))
            .env_clear()
            .args([
                "agent",
                "message",
                "parent",
                "-",
                "--format-only",
                "--sender-id",
                "native-fixture",
                "--reply-tool",
                "message_agent",
                "--reply-target",
                "native-fixture",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(input.as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        if input.trim().is_empty() {
            assert!(!output.status.success());
            assert!(output.stdout.is_empty());
        } else {
            assert!(output.status.success(), "{output:?}");
            assert!(String::from_utf8(output.stdout).unwrap().contains(input));
        }
    }
}

#[tokio::test]
async fn agent_client_listing_preserves_cluster_coverage_and_cursor() {
    let root = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    configuration(root.path(), listener.local_addr().unwrap().port());
    let server = tokio::spawn(async move {
        for local in [false, true] {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            initialize(&mut socket).await;
            let Message::Text(text) = socket.next().await.unwrap().unwrap() else {
                panic!("No list request")
            };
            let request: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(request["method"], "agent/cluster/list");
            assert_eq!(request["params"]["local"], local);
            assert_eq!(request["params"]["active"], true);
            assert_eq!(request["params"]["cursor"], "previous");
            socket.send(Message::Text(json!({"id":request["id"],"result":{"agents":[],"coverage":[{"hostId":"peer","state":"unreachable"}],"nextCursor":"next","warnings":[]}}).to_string())).await.unwrap();
        }
    });
    for local in [false, true] {
        let mut command =
            tokio::process::Command::new(env!("CARGO_BIN_EXE_remote-coder-codex-gateway"));
        command
            .env_clear()
            .env("HOME", root.path())
            .arg("--env-file")
            .arg(root.path().join("gateway.env"))
            .args([
                "agent", "list", "--active", "--cursor", "previous", "--json",
            ]);
        if local {
            command.arg("--local");
        }
        let output = command.output().await.unwrap();
        assert!(output.status.success(), "{output:?}");
        let page: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(page["coverage"][0]["state"], "unreachable");
        assert_eq!(page["nextCursor"], "next");
    }
    server.await.unwrap();
}

fn formatting_context() -> Value {
    json!({
        "context":{"contextId":"proven-context","provider":"codex","threadId":"proven-thread","turnId":"proven-turn"},
        "conversation":{"provider":"codex","providerHome":{"kind":"known","path":"/fixture/codex"},"threadId":"proven-thread"},
        "senderId":"agent-codex-1700000000000000000-aabbccdd",
        "jobId":"agent-codex-1700000000000000000-aabbccdd"
    })
}

#[tokio::test]
async fn agent_client_format_only_uses_gateway_proof_and_owning_host() {
    for explicit_context in [false, true] {
        let host = if explicit_context {
            "owning-gateway-host".to_owned()
        } else {
            nix::unistd::gethostname()
                .unwrap()
                .to_str()
                .unwrap()
                .split('.')
                .next()
                .unwrap()
                .to_ascii_lowercase()
        };
        let expected_host = host.clone();
        let root = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        configuration(root.path(), listener.local_addr().unwrap().port());
        let server = tokio::spawn(async move {
            let methods = if explicit_context {
                vec!["host/info", "agent/context/read"]
            } else {
                vec!["host/info", "agent/context/capture", "agent/context/read"]
            };
            for method in methods {
                let (stream, _) = listener.accept().await.unwrap();
                let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
                initialize(&mut socket).await;
                let Message::Text(text) = socket.next().await.unwrap().unwrap() else {
                    panic!("No proof request")
                };
                let request: Value = serde_json::from_str(&text).unwrap();
                assert_eq!(request["method"], method);
                let result = match method {
                    "agent/context/capture" => {
                        assert_eq!(request["params"].as_object().unwrap().len(), 2);
                        assert!(request["params"]["pid"].as_u64().unwrap() > 0);
                        assert!(request["params"]["startedAtUnixMicros"].as_u64().unwrap() > 0);
                        formatting_context()["context"].clone()
                    }
                    "agent/context/read" => {
                        assert_eq!(
                            request["params"]["caller"],
                            json!({"kind":"captured","contextId":"proven-context"})
                        );
                        formatting_context()
                    }
                    "host/info" => {
                        json!({"homeDirectory":"/fixture/home","hostname":host,"automationsAuthority":null,"speechAvailable":false})
                    }
                    _ => unreachable!(),
                };
                socket
                    .send(Message::Text(
                        json!({"id":request["id"],"result":result}).to_string(),
                    ))
                    .await
                    .unwrap();
            }
        });
        let env_file = root.path().join("gateway.env");
        let output = tokio::task::spawn_blocking(move || {
            let mut command = Command::new(env!("CARGO_BIN_EXE_remote-coder-codex-gateway"));
            command
                .env_clear()
                .env("HOME", env_file.parent().unwrap())
                .env("CODEX_THREAD_ID", "forged-codex")
                .env("CLAUDE_CODE_SESSION_ID", "forged-claude")
                .arg("--env-file")
                .arg(env_file)
                .args([
                    "agent",
                    "message",
                    "parent",
                    "Fixture message",
                    "--format-only",
                    "--delivery-id",
                    "proven-format",
                ]);
            if explicit_context {
                command.args(["--caller-context", "proven-context"]);
            }
            command.output().unwrap()
        })
        .await
        .unwrap();
        assert!(output.status.success(), "{output:?}");
        assert!(output.stderr.is_empty());
        let envelope = String::from_utf8(output.stdout).unwrap();
        assert!(envelope.contains(&format!("id=\"agent-codex-1700000000000000000-aabbccdd\" provider=\"codex\" host=\"{expected_host}\"")));
        assert!(envelope.contains(
            "tool=\"message_agent\" target=\"agent-codex-1700000000000000000-aabbccdd\""
        ));
        assert!(!envelope.contains("forged"));
        tokio::time::timeout(Duration::from_secs(10), server)
            .await
            .unwrap()
            .unwrap();
    }
}

#[tokio::test]
async fn agent_client_format_only_rejects_unproven_or_peer_host_environment_identity_on_stderr() {
    for peer_host in [false, true] {
        let root = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        configuration(root.path(), listener.local_addr().unwrap().port());
        let server = tokio::spawn(async move {
            let methods = if peer_host {
                vec!["host/info"]
            } else {
                vec!["host/info", "agent/context/capture"]
            };
            for method in methods {
                let (stream, _) = listener.accept().await.unwrap();
                let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
                initialize(&mut socket).await;
                let Message::Text(text) = socket.next().await.unwrap().unwrap() else {
                    panic!("No identity request")
                };
                let request: Value = serde_json::from_str(&text).unwrap();
                assert_eq!(request["method"], method);
                let reply = if method == "host/info" {
                    let host = if peer_host {
                        "peer-gateway-host".to_owned()
                    } else {
                        nix::unistd::gethostname()
                            .unwrap()
                            .to_str()
                            .unwrap()
                            .split('.')
                            .next()
                            .unwrap()
                            .to_ascii_lowercase()
                    };
                    json!({"id":request["id"],"result":{"homeDirectory":"/fixture/home","hostname":host,"automationsAuthority":null,"speechAvailable":false}})
                } else {
                    json!({"id":request["id"],"error":{"code":-32003,"message":"No proven local caller","data":{"kind":"unprovenCaller"}}})
                };
                socket.send(Message::Text(reply.to_string())).await.unwrap();
            }
        });
        let env_file = root.path().join("gateway.env");
        let output = tokio::task::spawn_blocking(move || {
            Command::new(env!("CARGO_BIN_EXE_remote-coder-codex-gateway"))
                .env_clear()
                .env("HOME", env_file.parent().unwrap())
                .env("CODEX_THREAD_ID", "forged-thread")
                .arg("--env-file")
                .arg(env_file)
                .args([
                    "agent",
                    "message",
                    "parent",
                    "Fixture message",
                    "--format-only",
                ])
                .output()
                .unwrap()
        })
        .await
        .unwrap();
        assert_eq!(output.status.code(), Some(if peer_host { 2 } else { 4 }));
        assert!(output.stdout.is_empty());
        let diagnostic: Value = serde_json::from_slice(&output.stderr).unwrap();
        if peer_host {
            assert!(
                diagnostic["error"]["message"]
                    .as_str()
                    .unwrap()
                    .contains("another host's gateway")
            );
        } else {
            assert_eq!(diagnostic["error"]["data"]["kind"], "unprovenCaller");
        }
        tokio::time::timeout(Duration::from_secs(10), server)
            .await
            .unwrap()
            .unwrap();
    }
}

#[tokio::test]
async fn agent_client_format_only_reads_scoped_proof_without_bearer_credentials() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("scoped.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut line = String::new();
        BufReader::new(&mut stream)
            .read_line(&mut line)
            .await
            .unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&line).unwrap()["method"],
            "readSelf"
        );
        stream
            .write_all(format!("{}\n", json!({"result":formatting_context()})).as_bytes())
            .await
            .unwrap();
    });
    let output = tokio::task::spawn_blocking(move || {
        Command::new(env!("CARGO_BIN_EXE_remote-coder-codex-gateway"))
            .env_clear()
            .env("HOME", root.path())
            .env("RC_AGENT_JOB_SOCKET", path)
            .env("CLAUDE_CODE_SESSION_ID", "forged-claude")
            .args([
                "agent",
                "message",
                "parent",
                "Fixture message",
                "--format-only",
            ])
            .output()
            .unwrap()
    })
    .await
    .unwrap();
    assert!(output.status.success(), "{output:?}");
    assert!(output.stderr.is_empty());
    let envelope = String::from_utf8(output.stdout).unwrap();
    assert!(
        envelope.contains("id=\"agent-codex-1700000000000000000-aabbccdd\" provider=\"codex\"")
    );
    assert!(!envelope.contains("forged"));
    tokio::time::timeout(Duration::from_secs(10), server)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn agent_client_resume_agent_id_continues_latest_but_explicit_stale_jobs_stay_fenced() {
    let root = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    configuration(root.path(), listener.local_addr().unwrap().port());
    let first = "agent-claude-1793127141860775000-00000001";
    let stale = "agent-claude-1793127141860775000-00000002";
    let latest = "agent-claude-1793127141860775000-00000003";
    let next = "agent-claude-1793127141860775000-00000004";
    let server = tokio::spawn(async move {
        let job = |id: &str| {
            json!({
                "jobId":id,"agentId":first,"requestFingerprint":null,"createdAtMs":100,
                "updatedAtMs":100,"revision":0,"previousJobId":null,"source":"imported",
                "admissionOrigin":null,"unconfirmedResult":null,"notices":[],
                "spec":{"kind":"known","spec":{"prompt":"fixture","cwd":"/tmp",
                    "settings":{"provider":"claude","model":"opus","effort":"high","fast":false},
                    "toolScope":{"kind":"full"},"title":null}},
                "recipient":{"kind":"none"},"execution":{"kind":"admitted"},"stop":{"kind":"notRequested"}
            })
        };
        for target in [first, stale] {
            let mut source_id = target;
            for method in if target == first {
                vec![
                    "agent/cluster/resolve",
                    "cluster/list",
                    "agent/jobs/read",
                    "agent/jobs/read",
                    "agent/jobs/continue",
                ]
            } else {
                vec![
                    "agent/cluster/resolve",
                    "cluster/list",
                    "agent/jobs/read",
                    "agent/jobs/continue",
                ]
            } {
                let (stream, _) = listener.accept().await.unwrap();
                let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
                initialize(&mut socket).await;
                let Message::Text(text) = socket.next().await.unwrap().unwrap() else {
                    panic!("No request");
                };
                let request: Value = serde_json::from_str(&text).unwrap();
                assert_eq!(request["method"], method);
                let response = if method == "agent/cluster/resolve" {
                    json!({"result":{"ownerHostId":"fixture-host","jobId":target,"agentId":first}})
                } else if method == "cluster/list" {
                    json!({"result":{"self":{"hostId":"fixture-host"},"members":[]}})
                } else if method == "agent/jobs/read" {
                    assert_eq!(request["params"]["jobId"], source_id);
                    let result = json!({"job":job(source_id),"agent":{
                        "agentId":first,"conversation":{"kind":"unknown","reason":"fixture"},
                        "origin":{"kind":"topLevel"},"toolScope":{"kind":"full"},
                        "originJobId":first,"latestJobId":latest
                    }});
                    source_id = latest;
                    json!({"result":result})
                } else {
                    let expected = if target == first { latest } else { stale };
                    assert_eq!(request["params"]["expectedPreviousJobId"], expected);
                    if target == first {
                        let mut continued = job(next);
                        continued["previousJobId"] = json!(latest);
                        json!({"result":{"protocol":1,"ownerHostId":"fixture-host","jobId":next,"address":null,"state":"waiting","incarnation":"fixture-incarnation","job":continued,"duplicate":false}})
                    } else {
                        json!({"error":{"code":-32603,"message":"Continue target was superseded"}})
                    }
                };
                let mut response = response;
                response["id"] = request["id"].clone();
                socket
                    .send(Message::Text(response.to_string()))
                    .await
                    .unwrap();
            }
        }
    });
    for target in [first, stale] {
        let output = tokio::process::Command::new(env!("CARGO_BIN_EXE_remote-coder-codex-gateway"))
            .env_clear()
            .env("HOME", root.path())
            .arg("--env-file")
            .arg(root.path().join("gateway.env"))
            .args([
                "agent",
                "spawn",
                "--resume",
                target,
                "Continue fixture",
                "--operator",
                "--json",
                "--job-id",
                next,
            ])
            .output()
            .await
            .unwrap();
        if target == first {
            assert!(output.status.success(), "{output:?}");
            assert!(output.stderr.is_empty());
            let receipt: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(receipt["previous_run_id"], latest);
        } else {
            assert_eq!(output.status.code(), Some(4));
            assert!(output.stdout.is_empty());
            let error: Value = serde_json::from_slice(&output.stderr).unwrap();
            assert_eq!(error["error"]["message"], "Continue target was superseded");
        }
    }
    server.await.unwrap();
}
