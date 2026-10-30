use tokio::io::AsyncReadExt;
use tokio::process::Command;

use super::*;
use crate::ids::new_session_uuid;
use crate::providers::claude::ClaudeUserInput;
use crate::providers::claude::settings::ClaudeTestSettings;
use crate::providers::claude::supervisor::input_writer::UnconsumedInputs;
use crate::providers::claude::translate::TurnResult;
use std::process::Stdio;
use std::time::SystemTime;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio_util::sync::CancellationToken;

fn isolated_agent(
    notifications: mpsc::Sender<crate::providers::claude::ClaudeNotification>,
) -> (ClaudeTestSettings, Arc<ClaudeSupervisor>) {
    let home = ClaudeSettings::isolated_for_test();
    let agent = ClaudeSupervisor::new(
        home.settings.clone(),
        notifications,
        Journal::disabled(),
        McpTokens::default(),
    );
    (home, agent)
}

fn live_subscription_settings(workspace: &Path) -> ClaudeSettings {
    let paths = crate::config::HostPaths::from_env().expect("live Claude home");
    let home = paths.home();
    let claude_home = home.join(".claude");
    let defaults = ClaudeSettings::isolated_for_test().settings;
    ClaudeSettings {
        enabled: true,
        claude_home: claude_home.clone(),
        config_dir: None,
        router: Some(
            crate::providers::router::RouterConfig::unreachable_for_test(
                home.join(".remote-coder/llm-router.key"),
            ),
        ),
        mcp_config_dir: workspace.join("mcp"),
        mcp_endpoint: "http://127.0.0.1:1/mcp".to_string(),
        ..defaults
    }
}

fn selection(model: &str, effort: Option<&str>) -> ClaudeSelection {
    ClaudeSelection {
        model: model.to_owned(),
        effort: effort.map(str::to_owned),
        fast: false,
    }
}

fn request(thread_id: &str, first_turn: bool) -> ClaudeTurnRequest {
    ClaudeTurnRequest {
        thread_id: thread_id.to_string(),
        session_uuid: "11111111-2222-4333-8444-555555555555".to_string(),
        first_turn,
        input: ClaudeUserInput::text("hi"),
        selection: selection("claude-fable-5", Some("high")),
        cwd: "/tmp".to_string(),
    }
}

#[test]
fn persistent_runtime_uses_bidirectional_stream_json() {
    let args = claude_stream_args(&request("claude_a", true), None);

    assert!(
        args.windows(2)
            .any(|pair| pair == ["--input-format", "stream-json"])
    );
    assert!(
        args.windows(2)
            .any(|pair| pair == ["--output-format", "stream-json"])
    );
    assert!(args.iter().any(|arg| arg == "--replay-user-messages"));
    assert!(
        args.windows(2)
            .any(|pair| pair == ["--thinking-display", "summarized"])
    );
    assert!(args.iter().any(|arg| arg == "--session-id"));
    assert!(!args.iter().any(|arg| arg == "hi"));
}

#[test]
fn an_echo_or_a_frame_that_lists_an_input_marks_it_consumed() {
    assert_eq!(
        consumed_input_ids(&json!({"type":"user", "uuid":"steer"})),
        ["steer"]
    );
    assert_eq!(
        consumed_input_ids(&json!({"type":"result", "user_message_uuids":["prompt", "steer"]})),
        ["prompt", "steer"]
    );
    assert_eq!(
        consumed_input_ids(
            &json!({"type":"assistant", "uuid":"reply", "user_message_uuids":["delivery"]})
        ),
        ["delivery"]
    );
    assert_eq!(
        consumed_input_ids(&json!({"type":"result", "user_message_uuid":"prompt"})),
        ["prompt"]
    );
    assert!(consumed_input_ids(&json!({"type":"assistant", "uuid":"reply"})).is_empty());
}

#[test]
fn a_dispatched_turn_skips_only_a_result_that_answers_other_work() {
    let queue = UnconsumedInputs::default();
    for id in ["earlier", "prompt", "steer"] {
        queue
            .queue(
                Some(ClaudeUserInput {
                    client_id: Some(id.to_owned()),
                    ..ClaudeUserInput::text(id)
                }),
                || (),
            )
            .unwrap();
    }
    let awaiting = || RuntimeTurn {
        agent_initiated: false,
        awaiting_input: Some("prompt".to_owned()),
        ..wake_turn("claude-turn-1")
    };
    let admits = |turn: &mut RuntimeTurn, frame: Value| {
        let consumed = consumed_input_ids(&frame);
        let taken = queue.take(&consumed);
        let evidence = consumed
            .iter()
            .copied()
            .chain(taken.iter().map(String::as_str))
            .collect::<Vec<_>>();
        turn.admits(&frame, &evidence)
    };
    let mut steered = awaiting();
    let mut unanswered = awaiting();

    let leftover = admits(
        &mut steered,
        json!({"type":"result", "num_turns":0, "origin":{"kind":"task-notification"}}),
    );
    let earlier = admits(
        &mut steered,
        json!({"type":"result", "user_message_uuids":["earlier"]}),
    );
    let streamed = admits(&mut steered, json!({"type":"stream_event"}));
    let steer = admits(&mut steered, json!({"type":"user", "uuid":"steer"}));
    let failed = admits(
        &mut unanswered,
        json!({"type":"result", "is_error":true, "origin":{"kind":"unclassified"}}),
    );

    assert!(!leftover && !earlier);
    assert!(streamed);
    assert!(steer && steered.awaiting_input.is_none());
    assert!(queue.pending().is_empty());
    assert!(failed);
}

#[tokio::test]
async fn an_input_that_could_not_be_written_is_not_carried() {
    let (writer, reader) = tokio::io::duplex(64);
    drop(reader);
    let input = InputWriter::spawn(writer);

    let written = input
        .send_input(&ClaudeUserInput {
            client_id: Some("steer".to_owned()),
            ..ClaudeUserInput::text("never arrives")
        })
        .await;

    assert_eq!(
        written.expect_err("the reader is gone").kind(),
        std::io::ErrorKind::BrokenPipe
    );
    assert!(input.unconsumed().pending().is_empty());
    assert_eq!(
        input
            .send_input(&ClaudeUserInput::text("after the failure"))
            .await
            .expect_err("a failed writer stays stopped")
            .kind(),
        std::io::ErrorKind::BrokenPipe
    );
}

#[tokio::test]
async fn a_cancelled_caller_never_leaves_a_partial_frame() {
    let (writer, mut reader) = tokio::io::duplex(16);
    let input = InputWriter::spawn(writer);
    let long = "a".repeat(4096);
    let cancelled = tokio::spawn({
        let input = input.clone();
        let long = long.clone();
        async move { input.send_input(&ClaudeUserInput::text(long)).await }
    });
    let mut bytes = vec![0_u8; 1];
    reader
        .read_exact(&mut bytes)
        .await
        .expect("the write began");
    cancelled.abort();
    let _ = cancelled.await;
    let collected = tokio::spawn(async move {
        reader.read_to_end(&mut bytes).await.expect("read to end");
        bytes
    });
    input
        .send_input(&ClaudeUserInput::text("second"))
        .await
        .expect("the next frame follows the cancelled one intact");
    drop(input);

    let lines: Vec<Value> = String::from_utf8(collected.await.expect("reader"))
        .expect("utf8")
        .lines()
        .map(|line| serde_json::from_str(line).expect("every line is one whole frame"))
        .collect();

    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0]["message"]["content"], long);
    assert_eq!(lines[1]["message"]["content"], "second");
}

#[test]
fn applied_models_must_match_the_requested_identity_or_family() {
    assert!(claude_model_matches("sonnet", "claude-sonnet-5"));
    assert!(claude_model_matches("fable", "claude-fable-5-1"));
    assert!(claude_model_matches("haiku", "claude-haiku-5-5"));
    assert!(!claude_model_matches("haiku", "claude-sonnet-5-5"));
    assert!(!claude_model_matches(
        "claude-haiku-4-5-20251001",
        "claude-haiku-5-5"
    ));
    assert!(!claude_model_matches("fable", "claude-sonnet-5"));
    assert!(!claude_model_matches(
        "claude-sonnet-4-6",
        "claude-sonnet-5"
    ));
}

#[tokio::test]
#[ignore = "uses the local Claude subscription: Sonnet 5 high and Sonnet 4.6 medium"]
async fn live_settings_switch_preserves_the_process_and_completes_real_input_once()
-> anyhow::Result<()> {
    use anyhow::{Context, ensure};
    let dir = tempfile::TempDir::new()?;
    let (tx, mut rx) = mpsc::channel(1024);
    let settings = live_subscription_settings(dir.path());
    let agent = ClaudeSupervisor::new(settings, tx, Journal::disabled(), McpTokens::default());
    let session_uuid = agent.mint_session().await?;
    let thread_id = format!("claude_{session_uuid}");
    let result = tokio::time::timeout(Duration::from_secs(150), async {
        let turn_id = agent.start_turn(ClaudeTurnRequest {
            thread_id: thread_id.clone(), session_uuid: session_uuid.clone(), first_turn: true,
            input: ClaudeUserInput::text("Tiny integration probe: say BEFORE_SWITCH, run Bash command /bin/sleep 6, then answer exactly AFTER_SWITCH. Do not inspect files or use other tools."),
            selection: selection("sonnet", Some("high")), cwd: dir.path().display().to_string(),
        }).await.map_err(|error| anyhow::anyhow!(error.message))?;
        let pid = agent.runtimes.lock().await[&thread_id].process_group_id;
        loop {
            let frame: Value = crate::test_support::claude_event(rx.recv().await.context("notification stream ended")?);
            ensure!(frame["method"] != "turn/completed", "internal context falsely completed the real turn: {frame}");
            if frame["method"] == "item/started" && frame["params"]["item"]["type"] == "commandExecution" { break; }
        }
        let applied = agent.update_settings(&thread_id, &selection("claude-sonnet-4-6", Some("medium"))).await.map_err(anyhow::Error::msg)?;
        ensure!(applied["applied"]["model"] == "claude-sonnet-4-6", "wrong applied model: {applied}");
        ensure!(agent.runtimes.lock().await[&thread_id].process_group_id == pid, "settings restarted the runtime");
        let mut assistant = String::new();
        loop {
            let frame: Value = crate::test_support::claude_event(rx.recv().await.context("notification stream ended")?);
            if frame["method"] == "item/completed" && frame["params"]["item"]["type"] == "agentMessage" {
                assistant = frame["params"]["item"]["text"].as_str().unwrap_or_default().to_string();
            }
            if frame["method"] == "turn/completed" {
                ensure!(frame["params"]["turn"]["id"] == turn_id && frame["params"]["turn"]["status"] == "completed", "wrong completion: {frame}");
                break;
            }
        }
        ensure!(assistant.contains("AFTER_SWITCH"), "real input did not complete: {assistant}");
        ensure!(agent.active_turn_id(&thread_id).await.is_none(), "turn remained active");
        let path = crate::providers::claude::timeline::resolve_session_path(&session_uuid, &agent.settings.claude_home)?;
        let records = fs::read_to_string(path)?;
        let final_model = records.lines().filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .filter(|record| record["type"] == "assistant")
            .filter_map(|record| record["message"]["model"].as_str().map(str::to_string)).next_back();
        ensure!(final_model.as_deref() == Some("claude-sonnet-5"), "the ongoing query changed unexpectedly: {final_model:?}");
        ensure!(applied["status"] == "nextTurn" && applied["currentTurnId"] == turn_id, "active change was not reported as pending: {applied}");
        let input_id = new_session_uuid();
        let mut followup = ClaudeUserInput::text("Reply exactly SECOND_ACK without tools.");
        followup.client_id = Some(input_id.clone());
        let next_turn_id = agent.start_voice_turn(ClaudeTurnRequest {
            thread_id: thread_id.clone(), session_uuid: session_uuid.clone(), first_turn: false,
            input: followup, selection: selection("sonnet", Some("high")),
            cwd: dir.path().display().to_string(),
        }).await.map_err(|error| anyhow::anyhow!(error.message))?;
        let mut consumed = false;
        loop {
            let frame: Value = crate::test_support::claude_event(rx.recv().await.context("notification stream ended")?);
            if frame["method"] == "item/completed" && frame["params"]["item"]["clientId"] == input_id {
                ensure!(frame["params"]["turnId"] == next_turn_id, "input replay belongs to the wrong turn");
                consumed = true;
            }
            if frame["method"] == "turn/completed" {
                ensure!(consumed, "turn completed before the exact input replay");
                ensure!(frame["params"]["turn"]["id"] == next_turn_id && frame["params"]["turn"]["status"] == "completed", "wrong follow-up completion: {frame}");
                break;
            }
        }
        let path = crate::providers::claude::timeline::resolve_session_path(&session_uuid, &agent.settings.claude_home)?;
        let records = fs::read_to_string(path)?;
        let final_model = records.lines().filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .filter(|record| record["type"] == "assistant")
            .filter_map(|record| record["message"]["model"].as_str().map(str::to_string)).next_back();
        ensure!(final_model.as_deref() == Some("claude-sonnet-4-6"), "the next turn did not switch model: {final_model:?}");
        let applied = agent.update_settings(&thread_id, &selection("sonnet", Some("high"))).await.map_err(anyhow::Error::msg)?;
        ensure!(applied["applied"]["effort"] == "high", "idle effort update failed");
        let automatic = agent.update_settings(&thread_id, &selection("sonnet", None)).await.map_err(anyhow::Error::msg)?;
        ensure!(automatic["status"] == "applied", "automatic effort could not be restored");
        ensure!(agent.runtimes.lock().await[&thread_id].process_group_id == pid, "idle update restarted the runtime");
        ensure!(agent.active_turn_id(&thread_id).await.is_none(), "settings command echo manufactured a task");
        println!("live Claude settings probe passed: session={session_uuid} pid={pid}, actual model={final_model:?}, two exact completed turns");
        Ok::<(), anyhow::Error>(())
    }).await;
    agent.stop_all().await;
    result.context("live Claude settings probe exceeded 150 seconds")?
}

#[tokio::test]
#[ignore = "uses the local Claude subscription: Sonnet medium"]
async fn live_synthetic_tail_queries_and_replays_without_a_user_bubble() -> anyhow::Result<()> {
    use anyhow::{Context, ensure};
    let dir = tempfile::TempDir::new()?;
    let (tx, mut rx) = mpsc::channel(1024);
    let settings = live_subscription_settings(dir.path());
    let agent = ClaudeSupervisor::new(settings, tx, Journal::disabled(), McpTokens::default());
    let session_uuid = agent.mint_session().await?;
    let thread_id = format!("claude_{session_uuid}");
    let input_id = new_session_uuid();
    let mut input = ClaudeUserInput::transcript_tail(
        "<realtime_delegation><source>transcript_tail_flush</source><input>Reply exactly TAIL_ACK. Do not use tools.</input><transcript_delta>user: Goodbye.</transcript_delta></realtime_delegation>",
    );
    input.client_id = Some(input_id.clone());
    let result = tokio::time::timeout(Duration::from_secs(90), async {
        let turn_id = agent.start_voice_turn(ClaudeTurnRequest {
            thread_id: thread_id.clone(), session_uuid: session_uuid.clone(), first_turn: true,
            input, selection: selection("sonnet", Some("medium")),
            cwd: dir.path().display().to_string(),
        }).await.map_err(|error| anyhow::anyhow!(error.message))?;
        let mut assistant = String::new();
        loop {
            let frame: Value = crate::test_support::claude_event(rx.recv().await.context("notification stream ended")?);
            ensure!(frame["params"]["item"]["type"] != "userMessage", "synthetic tail became user input: {frame}");
            if frame["method"] == "item/completed" && frame["params"]["item"]["type"] == "agentMessage" {
                assistant = frame["params"]["item"]["text"].as_str().unwrap_or_default().to_string();
            }
            if frame["method"] == "turn/completed" {
                ensure!(frame["params"]["turn"]["id"] == turn_id && frame["params"]["turn"]["status"] == "completed", "wrong completion: {frame}");
                break;
            }
        }
        ensure!(assistant.contains("TAIL_ACK"), "synthetic tail did not query: {assistant}");
        ensure!(agent.active_turn_id(&thread_id).await.is_none(), "tail turn remained active");
        let path = crate::providers::claude::timeline::resolve_session_path(&session_uuid, &agent.settings.claude_home)?;
        let records = fs::read_to_string(path)?;
        let tail = records.lines().filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .find(|record| record["uuid"] == input_id).context("tail missing from canonical session")?;
        ensure!(crate::providers::claude::timeline::is_injected_user_record(&tail, tail.pointer("/message/content")), "canonical tail lost synthetic metadata: {tail}");
        println!("live synthetic tail passed: session={session_uuid}, exact completion, hidden live/replay input");
        Ok::<(), anyhow::Error>(())
    }).await;
    agent.stop_all().await;
    result.context("synthetic tail probe exceeded 90 seconds")?
}

#[test]
fn resumed_runtime_uses_the_existing_session() {
    let args = claude_stream_args(&request("claude_a", false), None);

    assert!(args.iter().any(|arg| arg == "--resume"));
    assert!(!args.iter().any(|arg| arg == "--session-id"));
}

#[tokio::test]
async fn typed_and_spoken_inputs_are_the_only_frames_and_are_not_synthetic() {
    let mut child = Command::new("/bin/cat")
        .kill_on_drop(true)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .expect("input capture");
    let input = InputWriter::spawn(child.stdin.take().expect("stdin"));
    for text in [
        "Start in text",
        "<realtime_delegation><input>Status?</input></realtime_delegation>",
        "Continue in text",
    ] {
        input
            .send_input(&ClaudeUserInput::text(text))
            .await
            .expect("write input");
    }
    drop(input);
    let output = tokio::time::timeout(Duration::from_secs(5), child.wait_with_output())
        .await
        .expect("capture exits")
        .expect("capture output");
    let lines: Vec<Value> = String::from_utf8(output.stdout)
        .expect("utf8")
        .lines()
        .map(|line| serde_json::from_str(line).expect("input json"))
        .collect();
    assert_eq!(lines.len(), 3);
    assert_eq!(lines[0]["message"]["content"], "Start in text");
    assert_eq!(
        lines[1]["message"]["content"],
        "<realtime_delegation><input>Status?</input></realtime_delegation>"
    );
    assert_eq!(lines[2]["message"]["content"], "Continue in text");
    assert!(lines.iter().all(|line| line.get("isSynthetic").is_none()));
}

fn scratch_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("rc-mcp-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    dir
}

fn agent_with_mcp_dir(dir: &Path) -> (ClaudeTestSettings, Arc<ClaudeSupervisor>, McpTokens) {
    let (tx, _rx) = mpsc::channel(8);
    let tokens = McpTokens::default();
    let home = ClaudeSettings::isolated_for_test();
    let settings = ClaudeSettings {
        mcp_endpoint: "http://127.0.0.1:8787/mcp".to_string(),
        mcp_config_dir: dir.to_path_buf(),
        ..home.settings.clone()
    };
    (
        home,
        ClaudeSupervisor::new(settings, tx, Journal::disabled(), tokens.clone()),
        tokens,
    )
}

#[test]
fn the_mcp_token_travels_in_a_private_file_never_in_argv() {
    use std::os::unix::fs::PermissionsExt;

    let dir = scratch_dir("private");
    let (_home, agent, tokens) = agent_with_mcp_dir(&dir);
    let turn = request("claude_a", true);

    let access = agent.prepare_mcp_access(&turn).expect("mcp access");
    let args = claude_stream_args(&turn, Some(access.config_path.as_path()));

    let position = args
        .iter()
        .position(|arg| arg == "--mcp-config")
        .expect("the config is passed by path");
    assert_eq!(args[position + 1], access.config_path.display().to_string());
    assert!(
        !args.iter().any(|arg| arg.contains(&access.token)),
        "the token must never be visible in ps output"
    );
    assert!(
        !args.iter().any(|arg| arg == "--strict-mcp-config"),
        "the host's own MCP servers and skills must survive"
    );

    let written = fs::read_to_string(&access.config_path).expect("config written");
    let config: Value = serde_json::from_str(&written).expect("config json");
    let server = &config["mcpServers"][crate::agents::tools::NAMESPACE];
    assert_eq!(server["type"], "http");
    assert_eq!(server["url"], "http://127.0.0.1:8787/mcp");
    assert_eq!(
        server["headers"]["Authorization"],
        format!("Bearer {}", access.token)
    );
    let mode = fs::metadata(&access.config_path)
        .expect("metadata")
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600, "the file carries a bearer token");

    let identity = tokens.identify(&access.token).expect("token identifies");
    assert_eq!(identity.thread_id, turn.thread_id);
    let settings_path = runtime_settings_path(&access.config_path);
    let settings_position = args.iter().position(|arg| arg == "--settings").unwrap();
    assert_eq!(
        args[settings_position + 1],
        settings_path.display().to_string()
    );
    let settings: Value =
        serde_json::from_str(&fs::read_to_string(&settings_path).unwrap()).unwrap();
    assert_eq!(settings["fastMode"], false);
    assert_eq!(
        settings["hooks"]["PreToolUse"][0]["matcher"],
        "^mcp__remotecoder__notify_user$"
    );
    assert_eq!(
        settings["hooks"]["SessionStart"][0]["hooks"][0]["args"],
        json!(["claude-session-context"])
    );
    assert_eq!(
        fs::metadata(&settings_path).unwrap().permissions().mode() & 0o777,
        0o600
    );

    // Dropping the runtime's access is what revokes it — there is no
    // separate cleanup call for a retire path to forget.
    let path = access.config_path.clone();
    let token = access.token.clone();
    drop(access);
    assert!(tokens.identify(&token).is_none(), "the token is revoked");
    assert!(!path.exists(), "the config file is removed");
    assert!(
        !settings_path.exists(),
        "the owned runtime settings are removed"
    );

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn startup_sweeps_config_files_no_runtime_owns() {
    let dir = scratch_dir("sweep");
    fs::create_dir_all(&dir).expect("dir");
    fs::write(dir.join("abandoned.json"), "{}").expect("write");
    fs::write(dir.join("notes.txt"), "keep").expect("write");

    // The sweep runs from ClaudeSupervisor::new: at startup no runtime exists, so
    // every config present is a leftover holding an already-dead token.
    let (_home, _agent, _tokens) = agent_with_mcp_dir(&dir);

    assert!(!dir.join("abandoned.json").exists());
    assert!(dir.join("notes.txt").exists(), "only configs are swept");

    let _ = fs::remove_dir_all(&dir);
}

/// A runtime whose stdin is a throwaway `cat`, for paths that need a
/// registered runtime but no real Claude process.
async fn placeholder_runtime(
    request: &ClaudeTurnRequest,
) -> (ClaudeRuntime, tokio::process::Child) {
    let mut command = Command::new("/bin/cat");
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .kill_on_drop(true);
    unsafe {
        command.pre_exec(|| {
            nix::unistd::setsid().map_err(std::io::Error::other)?;
            Ok(())
        });
    }
    let mut child = command.spawn().expect("spawn placeholder process");
    let process_group_id = child.id().expect("placeholder pid") as i32;
    let stdin = child.stdin.take().expect("stdin");
    let runtime = ClaudeRuntime {
        input: InputWriter::spawn(stdin),
        pending_controls: HashMap::new(),
        process_group_id,
        process_started_micros: crate::platform::process::identify(process_group_id)
            .unwrap()
            .map(|identity| identity.started_micros),
        reaped: tokio::sync::watch::channel(super::process::ReapState::Running).1,
        launch: super::jobs::LaunchPolicy::Conversation {
            scope: crate::agents::jobs::model::ToolScope::Full,
        },
        session_uuid: request.session_uuid.clone(),
        settings: Some(ClaudeRuntimeSettings::requested(request)),
        cwd: request.cwd.clone(),
        initialized: true,
        active_turn: None,
        background_tasks: Vec::new(),
        children: crate::agents::claude::Projection::default(),
        children_generation: 1,
        lifecycle_generation: 1,
        _mcp: None,
        idle: None,
        wakes: WakeHold::default(),
        stderr_ring: Arc::new(Mutex::new(Vec::new())),
    };
    (runtime, child)
}

#[tokio::test]
async fn discovery_opus_command_settings_recover_unknown_readback() {
    let (tx, _rx) = mpsc::channel(4);
    let (_home, agent) = isolated_agent(tx);
    let request = request("claude_a", true);
    let (mut runtime, mut process) = placeholder_runtime(&request).await;
    runtime.settings = None;
    agent
        .runtimes
        .lock()
        .await
        .insert(request.thread_id.clone(), runtime);
    let result = agent.runtime_settings_for_command(&request.thread_id);
    let response = async {
        tokio::time::timeout(Duration::from_millis(500), async {
            loop {
                let sender = agent.runtimes.lock().await.get_mut(&request.thread_id).unwrap().pending_controls.drain().next().map(|(_, sender)| sender);
                if let Some(sender) = sender {
                    sender.send(Ok(json!({"applied":{"model":"recovered","effort":"high"},"effective":{"fastMode":true}}))).unwrap();
                    break;
                }
                tokio::task::yield_now().await;
            }
        }).await
    };
    let (observed, response) = tokio::join!(result, response);
    let snapshot = agent.runtime_settings_snapshot(&request.thread_id).await;
    agent.stop_all().await;
    process.wait().await.unwrap();
    assert!(
        response.is_ok(),
        "command did not request settings readback"
    );
    let observed = observed
        .expect("command could not recover settings")
        .unwrap();
    assert_eq!(observed.model, "recovered");
    assert!(observed.fast);
    assert_eq!(snapshot.unwrap(), Some(observed));
}

#[tokio::test]
async fn runtime_settings_snapshot_never_waits_for_a_lifecycle_exchange() {
    let (tx, _rx) = mpsc::channel(4);
    let (_home, agent) = isolated_agent(tx);
    let request = request("claude_a", true);
    let (runtime, mut process) = placeholder_runtime(&request).await;
    agent
        .runtimes
        .lock()
        .await
        .insert(request.thread_id.clone(), runtime);
    let held = agent.lock_lifecycle(&request.thread_id).await;
    let observed = tokio::time::timeout(
        Duration::from_millis(500),
        agent.runtime_settings_snapshot(&request.thread_id),
    )
    .await;
    agent
        .runtimes
        .lock()
        .await
        .get_mut(&request.thread_id)
        .unwrap()
        .settings = None;
    let unknown = tokio::time::timeout(
        Duration::from_millis(500),
        agent.runtime_settings_snapshot(&request.thread_id),
    )
    .await;
    drop(held);
    agent.stop_all().await;
    process.wait().await.unwrap();
    assert_eq!(
        observed
            .expect("settings waited for lifecycle lock")
            .unwrap(),
        Some(request.selection)
    );
    assert!(
        unknown
            .expect("unknown settings waited for lifecycle lock")
            .unwrap_err()
            .contains("not been observed")
    );
}

fn wake_turn(turn_id: &str) -> RuntimeTurn {
    RuntimeTurn::new(
        TurnTranslator::new(
            "claude_a".to_string(),
            turn_id.to_string(),
            "/tmp".to_string(),
            None,
            0,
            Arc::default(),
        ),
        true,
        None,
    )
}

pub(crate) async fn runtime_stderr_frame(thread_id: &str) -> Value {
    let (tx, mut rx) = mpsc::channel(2);
    let (_home, agent) = isolated_agent(tx);
    let (mut runtime, mut placeholder) = placeholder_runtime(&request(thread_id, false)).await;
    let mut child = Command::new("/bin/sh")
        .args(["-c", "printf 'provider diagnostic\\n' >&2"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let group = child.id().unwrap() as i32;
    runtime.process_group_id = group;
    agent
        .runtimes
        .lock()
        .await
        .insert(thread_id.to_owned(), runtime);
    agent
        .read_stderr(
            thread_id.to_owned(),
            group,
            child.stderr.take().unwrap(),
            CancellationToken::new(),
        )
        .await;
    let frame = next_notification(&mut rx).await;
    assert!(child.wait().await.unwrap().success());
    agent.runtimes.lock().await.remove(thread_id);
    placeholder.kill().await.unwrap();
    frame
}

/// A stdout stream carrying one init line that reports metered billing.
///
/// The stub stays alive after the line so only the guard can end the reader
/// — a stub that exited would retire the runtime through the ordinary
/// stream-ended path and the tests would pass with no guard at all. It owns
/// its process group so the guard's kill cannot reach anything else.
fn violating_init_stream() -> (ChildStdout, i32, tokio::process::Child) {
    let init = json!({
        "type": "system", "subtype": "init", "session_id": "s",
        "apiKeySource": "ANTHROPIC_API_KEY", "fast_mode_state": "off",
        "permissionMode": "bypassPermissions"
    })
    .to_string();
    let mut command = Command::new("/bin/sh");
    command
        .arg("-c")
        .arg(r#"printf '%s\n' "$0"; sleep 30"#)
        .arg(&init)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(false);
    unsafe {
        command.pre_exec(|| {
            nix::unistd::setsid().map_err(std::io::Error::other)?;
            Ok(())
        });
    }
    let mut child = command.spawn().expect("spawn the stream stub");
    let process_group_id = child.id().expect("pid") as i32;
    let stdout = child.stdout.take().expect("stdout");
    (stdout, process_group_id, child)
}

/// Runs the reader to completion, failing fast if nothing ends it.
async fn drive_stream_reader(agent: &Arc<ClaudeSupervisor>, stdout: ChildStdout, group: i32) {
    tokio::time::timeout(
        Duration::from_secs(15),
        Arc::clone(agent).read_runtime_stream(
            "claude_a".to_string(),
            group,
            stdout,
            CancellationToken::new(),
        ),
    )
    .await
    .expect("the billing guard must terminate the runtime and end the reader");
}

async fn next_notification(
    rx: &mut mpsc::Receiver<crate::providers::claude::ClaudeNotification>,
) -> Value {
    crate::test_support::claude_event(rx.recv().await.expect("a notification was emitted"))
}

#[tokio::test]
async fn a_blocked_settings_exchange_does_not_delay_an_independent_start() {
    let (tx, _rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let (mut a, mut child_a) = placeholder_runtime(&request("claude_a", false)).await;
    let (b, mut child_b) = placeholder_runtime(&request("claude_b", false)).await;
    let (blocked_writer, unread) = tokio::io::duplex(1);
    a.input = InputWriter::spawn(blocked_writer);
    agent
        .runtimes
        .lock()
        .await
        .extend([("claude_a".to_owned(), a), ("claude_b".to_owned(), b)]);
    let changing_a = tokio::spawn({
        let agent = Arc::clone(&agent);
        async move {
            agent
                .update_settings("claude_a", &selection("different-model", Some("high")))
                .await
        }
    });
    tokio::time::timeout(Duration::from_secs(2), async {
        while agent.runtimes.lock().await["claude_a"]
            .pending_controls
            .is_empty()
        {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("A reaches its deliberately blocked control write");
    let b_turn = tokio::time::timeout(
        Duration::from_secs(2),
        agent.start_turn(request("claude_b", false)),
    )
    .await
    .expect("B must not wait for A's 30-second timeout")
    .expect("B starts");
    assert_eq!(
        agent.active_turn_id("claude_b").await.as_deref(),
        Some(b_turn.as_str())
    );
    changing_a.abort();
    let _ = changing_a.await;
    drop(unread);
    agent.runtimes.lock().await.clear();
    let _ = child_a.kill().await;
    let _ = child_b.kill().await;
}

#[tokio::test]
async fn a_pending_start_holds_its_thread_and_cancellation_releases_it() {
    let (tx, _rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let (ready, waiting) = oneshot::channel();
    let start = tokio::spawn({
        let agent = Arc::clone(&agent);
        async move {
            let _reservation = agent
                .reserve_start(&request("claude_a", false))
                .await
                .unwrap();
            ready.send(()).unwrap();
            std::future::pending::<()>().await;
        }
    });
    waiting.await.unwrap();
    assert!(agent.has_pending_or_active_work("claude_a").await);
    assert!(!agent.has_pending_or_active_work("claude_b").await);
    assert!(
        agent
            .reserve_start(&request("claude_a", false))
            .await
            .is_err()
    );
    assert!(
        agent
            .reserve_start(&request("claude_b", false))
            .await
            .is_ok()
    );
    start.abort();
    let _ = start.await;
    assert!(!agent.has_pending_or_active_work("claude_a").await);
    assert!(
        agent
            .reserve_start(&request("claude_a", false))
            .await
            .is_ok()
    );
}

#[tokio::test]
async fn deleted_recorded_cwd_resumes_the_exact_transcript_in_an_existing_recorded_directory() {
    let home = ClaudeSettings::isolated_for_test();
    let cwd = home.root_path().join("repository");
    fs::create_dir_all(&cwd).unwrap();
    let missing = home.root_path().join("removed-worktree");
    let stub = home.root_path().join("claude-stub");
    fs::write(
        &stub,
        "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\"\nexec cat\n",
    )
    .unwrap();
    fs::set_permissions(&stub, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    let (tx, _rx) = mpsc::channel(16);
    let agent = ClaudeSupervisor::new(
        ClaudeSettings {
            claude_path: stub,
            ..home.settings.clone()
        },
        tx,
        Journal::disabled(),
        McpTokens::default(),
    );
    let mut turn = request("claude_a", false);
    turn.cwd = missing.to_string_lossy().into_owned();
    let transcript = crate::providers::claude::timeline::session_path_for_cwd(
        &home.settings.claude_home,
        &turn.cwd,
        &turn.session_uuid,
    );
    fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    fs::write(
        &transcript,
        format!(
            "{}\n{}\n",
            json!({"type":"user","sessionId":turn.session_uuid,"cwd":turn.cwd}),
            json!({"type":"assistant","sessionId":turn.session_uuid,"cwd":cwd}),
        ),
    )
    .unwrap();
    let full = super::jobs::LaunchPolicy::Conversation {
        scope: crate::agents::jobs::model::ToolScope::Full,
    };
    agent.recover_stored_cwd(&mut turn, &full).await.unwrap();
    assert_eq!(Path::new(&turn.cwd), cwd);
    let mut spawned = agent.spawn_runtime(&turn, &full).unwrap();
    let mut lines = BufReader::new(&mut spawned.stdout).lines();
    let observed = tokio::time::timeout(Duration::from_secs(5), async {
        let mut lines_seen = Vec::new();
        while let Some(line) = lines.next_line().await.unwrap() {
            let done = lines_seen
                .last()
                .is_some_and(|previous| previous == "--resume");
            lines_seen.push(line);
            if done {
                break;
            }
        }
        lines_seen
    })
    .await
    .unwrap();
    assert_eq!(
        Path::new(&observed[0]).canonicalize().unwrap(),
        cwd.canonicalize().unwrap()
    );
    assert_eq!(
        observed.last().unwrap(),
        &transcript
            .canonicalize()
            .unwrap()
            .to_string_lossy()
            .into_owned()
    );
    assert!(
        !observed
            .iter()
            .any(|arg| matches!(arg.as_str(), "--fork-session" | "--session-id"))
    );
    let mut arbitrary = request("claude_a", false);
    arbitrary.cwd = home
        .root_path()
        .join("never-recorded")
        .to_string_lossy()
        .into_owned();
    agent
        .recover_stored_cwd(&mut arbitrary, &full)
        .await
        .unwrap();
    let error = agent.spawn_runtime(&arbitrary, &full).err().unwrap();
    assert_eq!(error.code, RpcCode::InvalidParams);
    assert!(error.message.contains(&arbitrary.cwd));
    let restricted = super::jobs::LaunchPolicy::Conversation {
        scope: crate::agents::jobs::model::ToolScope::ReadOnly {
            root: missing.clone(),
        },
    };
    turn.cwd = missing.to_string_lossy().into_owned();
    agent
        .recover_stored_cwd(&mut turn, &restricted)
        .await
        .unwrap();
    assert_eq!(Path::new(&turn.cwd), missing);
    assert!(agent.spawn_runtime(&turn, &restricted).is_err());
    drop(spawned);
    turn.cwd = cwd.to_string_lossy().into_owned();
    let duplicate = crate::providers::claude::timeline::session_path_for_cwd(
        &home.settings.claude_home,
        &turn.cwd,
        &turn.session_uuid,
    );
    fs::create_dir_all(duplicate.parent().unwrap()).unwrap();
    fs::copy(&transcript, &duplicate).unwrap();
    let error = agent.spawn_runtime(&turn, &full).err().unwrap();
    assert!(error.message.contains("duplicate Claude session UUID"));
}

#[tokio::test]
async fn failed_spawn_releases_its_thread_reservation() {
    let claude_test = ClaudeSettings::isolated_for_test();
    let root = tempfile::tempdir().unwrap();
    let (tx, _rx) = mpsc::channel(16);
    let agent = ClaudeSupervisor::new(
        ClaudeSettings {
            claude_path: root.path().join("does-not-exist"),
            ..claude_test.settings.clone()
        },
        tx,
        Journal::disabled(),
        McpTokens::default(),
    );
    let mut first = request("claude_a", true);
    first.session_uuid = agent.mint_session().await.unwrap();
    let error = agent.start_turn(first).await.unwrap_err();
    assert!(
        error.message.contains("failed to spawn claude"),
        "{}",
        error.message
    );
    assert!(agent.starting.lock().unwrap().is_empty());
    assert!(
        agent
            .reserve_start(&request("claude_a", true))
            .await
            .is_ok()
    );
}

#[tokio::test]
async fn an_old_process_completion_cannot_remove_a_replacement_turn() {
    let (tx, _rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let (mut runtime, mut child) = placeholder_runtime(&request("claude_a", false)).await;
    let group = runtime.process_group_id;
    runtime.active_turn = Some(wake_turn("replacement-turn"));
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".into(), runtime);
    agent
        .fail_runtime("claude_a", group + 1, "failed", None)
        .await;
    assert_eq!(
        agent.active_turn_id("claude_a").await.as_deref(),
        Some("replacement-turn")
    );
    agent.runtimes.lock().await.clear();
    let _ = child.kill().await;
}

async fn agent_with_indexed_active_turn(
    home: &ClaudeTestSettings,
) -> (Arc<ClaudeSupervisor>, i32, tokio::process::Child) {
    let agent = agent_with_claude_home(home);
    let (mut runtime, child) = placeholder_runtime(&request("claude_a", false)).await;
    let group = runtime.process_group_id;
    let turn = wake_turn("indexed-turn");
    let mut started = turn.translator.turn_started();
    crate::providers::claude::conversation_index::Store::new(home.settings.claude_home.clone())
        .record(&mut started)
        .await
        .unwrap();
    runtime.active_turn = Some(turn);
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".into(), runtime);
    (agent, group, child)
}

async fn indexed_status_once_inactive(agent: &ClaudeSupervisor) -> String {
    tokio::time::timeout(Duration::from_secs(5), async {
        while agent.active_turn_id("claude_a").await.is_some() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the turn stops being active");
    crate::providers::claude::conversation_index::read(&agent.settings.claude_home, "claude_a")
        .unwrap()
        .turns["indexed-turn"]
        .status
        .clone()
}

async fn mark_finishing(agent: &ClaudeSupervisor) {
    let mut runtimes = agent.runtimes.lock().await;
    let turn = runtimes
        .get_mut("claude_a")
        .and_then(|runtime| runtime.active_turn.as_mut())
        .expect("an active turn");
    turn.phase = TurnPhase::Finishing;
}

#[tokio::test]
async fn a_finishing_turn_stays_active_refuses_steering_and_holds_new_starts() {
    let home = ClaudeSettings::isolated_for_test();
    let (agent, _group, mut child) = agent_with_indexed_active_turn(&home).await;
    mark_finishing(&agent).await;

    assert_eq!(
        agent.active_turn_id("claude_a").await.as_deref(),
        Some("indexed-turn")
    );
    assert!(agent.has_pending_or_active_work("claude_a").await);
    let refused = agent
        .steer("claude_a", "indexed-turn", &ClaudeUserInput::text("late"))
        .await
        .expect_err("a finishing turn takes no steering");
    assert!(
        matches!(refused, TurnControlError::NotRunning { .. }),
        "{refused:?}"
    );
    let waiting = tokio::spawn({
        let agent = Arc::clone(&agent);
        async move { agent.wait_for_finishing_turn("claude_a").await }
    });
    tokio::task::yield_now().await;
    assert!(!waiting.is_finished());

    agent
        .runtimes
        .lock()
        .await
        .get_mut("claude_a")
        .expect("runtime")
        .active_turn = None;
    agent.turn_settled.notify_waiters();

    tokio::time::timeout(Duration::from_secs(2), waiting)
        .await
        .expect("a settled turn releases the waiting start")
        .unwrap();
    agent.runtimes.lock().await.clear();
    let _ = child.kill().await;
}

#[tokio::test]
async fn stopping_a_runtime_whose_turn_is_finishing_records_no_second_completion() {
    let home = ClaudeSettings::isolated_for_test();
    let (agent, group, mut child) = agent_with_indexed_active_turn(&home).await;
    mark_finishing(&agent).await;

    agent
        .fail_runtime("claude_a", group, "failed", Some("gone".to_owned()))
        .await;

    assert!(!agent.has_runtime("claude_a").await);
    assert_eq!(
        crate::providers::claude::conversation_index::read(&agent.settings.claude_home, "claude_a")
            .unwrap()
            .turns["indexed-turn"]
            .status,
        "inProgress"
    );
    let _ = child.kill().await;
}

#[tokio::test]
async fn a_finished_turn_is_indexed_before_it_stops_being_active() {
    let home = ClaudeSettings::isolated_for_test();
    let (agent, group, mut child) = agent_with_indexed_active_turn(&home).await;
    let finishing = tokio::spawn({
        let agent = Arc::clone(&agent);
        async move {
            let result = TurnResult {
                status: "completed".into(),
                error_message: None,
                error_info: None,
            };
            agent.finish_turn("claude_a", group, result).await;
        }
    });
    assert_eq!(indexed_status_once_inactive(&agent).await, "completed");
    finishing.await.unwrap();
    agent.runtimes.lock().await.clear();
    let _ = child.kill().await;
}

#[tokio::test]
async fn a_failed_runtime_indexes_its_turn_before_it_is_removed() {
    let home = ClaudeSettings::isolated_for_test();
    let (agent, group, mut child) = agent_with_indexed_active_turn(&home).await;
    let failing = tokio::spawn({
        let agent = Arc::clone(&agent);
        async move {
            agent
                .fail_runtime("claude_a", group, "failed", Some("stream ended".into()))
                .await;
        }
    });
    assert_eq!(indexed_status_once_inactive(&agent).await, "failed");
    failing.await.unwrap();
    let _ = child.kill().await;
}

#[tokio::test]
async fn stream_eof_terminates_the_runtime_process_group() {
    let home = ClaudeSettings::isolated_for_test();
    let (agent, _placeholder_group, mut placeholder) = agent_with_indexed_active_turn(&home).await;
    let mut command = Command::new("perl");
    command
        .arg("-e")
        .arg("close STDOUT; sleep 300;")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(false);
    unsafe {
        command.pre_exec(|| {
            nix::unistd::setsid().map_err(std::io::Error::other)?;
            Ok(())
        });
    }
    let mut child = command.spawn().expect("stream-closed child");
    let group = child.id().expect("process group") as i32;
    let stdout = child.stdout.take().expect("stdout");
    agent
        .runtimes
        .lock()
        .await
        .get_mut("claude_a")
        .expect("runtime")
        .process_group_id = group;
    let reaper = tokio::spawn(async move { child.wait().await });

    Arc::clone(&agent)
        .read_runtime_stream(
            "claude_a".to_string(),
            group,
            stdout,
            CancellationToken::new(),
        )
        .await;
    reaper.await.expect("reaper").expect("reap process");
    assert!(!group_exists(Pid::from_raw(group)));
    assert!(!agent.has_runtime("claude_a").await);
    let _ = placeholder.kill().await;
}

#[tokio::test]
async fn stopping_all_runtimes_waits_for_a_reader_to_publish_its_exited_turn() {
    let home = ClaudeSettings::isolated_for_test();
    let (tx, mut rx) = mpsc::channel(1);
    tx.send(ClaudeNotification::Event(json!({"method": "occupied"})))
        .await
        .unwrap();
    let agent = ClaudeSupervisor::new(
        home.settings.clone(),
        tx,
        Journal::disabled(),
        McpTokens::default(),
    );
    let (mut runtime, mut placeholder) = placeholder_runtime(&request("claude_a", false)).await;
    runtime.active_turn = Some(wake_turn("exited-turn"));
    let mut command = Command::new("perl");
    command
        .arg("-e")
        .arg("close STDOUT;")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0);
    let mut child = command.spawn().expect("exiting child");
    let group = child.id().expect("process group") as i32;
    let stdout = child.stdout.take().expect("stdout");
    runtime.process_group_id = group;
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".into(), runtime);
    let reaper = tokio::spawn(async move { child.wait().await });
    agent.start_runtime_tasks("claude_a".into(), group, stdout, None);
    wait_until_retired(&agent, "claude_a", "the reader takes the exited runtime").await;

    let stopping = tokio::spawn({
        let agent = Arc::clone(&agent);
        async move { agent.stop_all().await }
    });
    tokio::time::timeout(Duration::from_secs(5), async {
        while agent.io_tasks.spawn("admission probe", async { Ok(()) }) {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("stopping closes runtime IO admission");

    assert_eq!(
        crate::test_support::claude_event(rx.recv().await.unwrap())["method"],
        "occupied"
    );
    let completed = tokio::time::timeout(Duration::from_secs(5), rx.recv())
        .await
        .expect("the exited turn's completion is published")
        .map(crate::test_support::claude_event)
        .unwrap();
    assert_eq!(completed["method"], "turn/completed");
    assert_eq!(completed["params"]["turn"]["id"], "exited-turn");
    stopping.await.unwrap();
    reaper.await.unwrap().unwrap();
    let _ = placeholder.kill().await;
}

#[test]
fn a_no_mcp_instance_does_not_sweep_a_directory_it_does_not_own() {
    let claude_test = ClaudeSettings::isolated_for_test();
    let root = tempfile::tempdir().unwrap();
    let config = root.path().join("another-runtime.json");
    fs::write(&config, "existing runtime configuration").unwrap();
    let (tx, _rx) = mpsc::channel(1);
    let _agent = ClaudeSupervisor::new(
        ClaudeSettings {
            mcp_config_dir: root.path().to_path_buf(),
            ..claude_test.settings.clone()
        },
        tx,
        Journal::disabled(),
        McpTokens::default(),
    );
    assert!(config.exists());
}

#[tokio::test]
async fn a_second_turn_on_the_same_thread_is_rejected_as_busy() {
    let (tx, _rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let (mut runtime, _child) = placeholder_runtime(&request("claude_a", false)).await;
    let mut active = wake_turn("claude-turn-1");
    active.agent_initiated = false;
    runtime.active_turn = Some(active);
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".into(), runtime);

    let error = agent
        .start_turn(request("claude_a", false))
        .await
        .expect_err("busy thread must be rejected");

    assert_eq!(error.code, RpcCode::ServerBusy);
}

#[tokio::test]
async fn manual_compaction_never_folds_into_a_running_agent_initiated_turn() {
    let (tx, _rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let (mut runtime, _child) = placeholder_runtime(&request("claude_a", false)).await;
    runtime.active_turn = Some(wake_turn("claude-turn-original"));
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".into(), runtime);
    let mut compact = request("claude_a", false);
    compact.input = ClaudeUserInput::text("/compact");
    let error = agent
        .start_compaction(compact)
        .await
        .expect_err("active compaction must be rejected");
    assert_eq!(error.code, RpcCode::ServerBusy);
    let runtimes = agent.runtimes.lock().await;
    assert_eq!(
        runtimes["claude_a"]
            .running_turn()
            .unwrap()
            .translator
            .turn_id(),
        "claude-turn-original"
    );
}

#[tokio::test]
async fn many_busy_threads_never_refuse_another_thread() {
    let (tx, _rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let mut children = Vec::new();
    for index in 0..8 {
        let thread = format!("claude_busy_{index}");
        let (mut runtime, child) = placeholder_runtime(&request(&thread, false)).await;
        let mut active = wake_turn(&format!("claude-turn-{index}"));
        active.agent_initiated = false;
        runtime.active_turn = Some(active);
        agent.runtimes.lock().await.insert(thread, runtime);
        children.push(child);
    }
    let mut reservations = Vec::new();
    for index in 0..8 {
        reservations.push(
            agent
                .reserve_start(&request(&format!("claude_starting_{index}"), false))
                .await
                .expect("starting threads hold no shared capacity"),
        );
    }

    let admitted = agent.reserve_start(&request("claude_next", false)).await;

    assert!(admitted.is_ok());
    drop(reservations);
    agent.runtimes.lock().await.clear();
    for mut child in children {
        let _ = child.kill().await;
    }
}

#[tokio::test]
async fn a_resume_without_history_in_this_account_never_spawns() {
    let claude_test = ClaudeSettings::isolated_for_test();
    let root = tempfile::tempdir().unwrap();
    let launched = root.path().join("launched");
    let executable = root.path().join("claude-stub");
    fs::write(
        &executable,
        format!("#!/bin/sh\ntouch '{}'\nexec cat\n", launched.display()),
    )
    .unwrap();
    fs::set_permissions(
        &executable,
        std::os::unix::fs::PermissionsExt::from_mode(0o700),
    )
    .unwrap();
    let claude_home = root.path().join("account");
    let other_home = root.path().join("default");
    let cwd = root.path().join("work");
    fs::create_dir_all(&cwd).unwrap();
    let cwd = cwd.to_string_lossy().into_owned();
    let session = "11111111-2222-4333-8444-555555555555";
    let elsewhere =
        crate::providers::claude::timeline::session_path_for_cwd(&other_home, &cwd, session);
    fs::create_dir_all(elsewhere.parent().unwrap()).unwrap();
    fs::write(&elsewhere, "{}\n").unwrap();
    let (tx, _rx) = mpsc::channel(16);
    let agent = ClaudeSupervisor::new(
        ClaudeSettings {
            claude_path: executable,
            claude_home: claude_home.clone(),
            config_dir: Some(claude_home.clone()),

            ..claude_test.settings.clone()
        },
        tx,
        Journal::disabled(),
        McpTokens::default(),
    );
    let turn = |first_turn| ClaudeTurnRequest {
        thread_id: format!("claude_{session}"),
        session_uuid: session.to_owned(),
        first_turn,
        input: ClaudeUserInput::text("continue"),
        selection: selection("sonnet", None),
        cwd: cwd.clone(),
    };

    let resume = agent.start_turn(turn(false)).await.unwrap_err();
    let fresh = agent.start_turn(turn(true)).await.unwrap_err();

    assert_eq!(resume.code, RpcCode::InvalidParams);
    assert!(
        resume.message.contains("host-default profile"),
        "{}",
        resume.message
    );
    assert!(resume.message.contains(&cwd), "{}", resume.message);
    assert!(
        resume
            .message
            .contains("refusing to start a new conversation"),
        "{}",
        resume.message
    );
    assert!(
        fresh.message.contains("did not create that session"),
        "{}",
        fresh.message
    );
    assert!(!launched.exists(), "no Claude process may start");
    assert!(!agent.has_runtime(&format!("claude_{session}")).await);
    assert!(agent.starting.lock().unwrap().is_empty());
}

/// Pinned against a captured wake stream: everything the CLI emits between
/// turns must stay ambient, or an idle session would manufacture turns.
#[test]
fn only_turn_content_opens_a_turn() {
    for line in [
        json!({"type": "stream_event", "event": {"type": "message_start"}}),
        json!({"type": "assistant", "message": {"content": []}}),
        json!({"type": "user", "message": {"content": []}}),
        json!({"type": "result", "subtype": "success"}),
        json!({"type": "system", "subtype": "thinking_tokens", "estimated_tokens": 4}),
    ] {
        assert!(opens_turn(&line), "must open a turn: {line}");
    }

    for line in [
        json!({"type":"user", "isReplay":true, "message":{"content":"<local-command-stdout>Set model to claude-sonnet-5</local-command-stdout>"}}),
        json!({"type":"user", "isSynthetic":true, "message":{"content":"internal context"}}),
        json!({"type": "system", "subtype": "init", "apiKeySource": "none"}),
        json!({"type": "system", "subtype": "status", "status": "requesting"}),
        json!({"type": "system", "subtype": "task_started", "task_id": "t1"}),
        json!({"type": "system", "subtype": "task_progress", "task_id": "t1"}),
        json!({"type": "system", "subtype": "task_updated", "task_id": "t1"}),
        json!({"type": "system", "subtype": "task_notification", "task_id": "t1"}),
        json!({"type": "system", "subtype": "background_tasks_changed", "tasks": []}),
        json!({"type": "system", "subtype": "commands_changed"}),
        json!({"type": "system", "subtype": "control_request_progress", "request_id": "r1", "status": "started"}),
        json!({"type": "rate_limit_event"}),
        json!({"type": "command_lifecycle", "state": "started"}),
        json!({"other": "shape"}),
    ] {
        assert!(!opens_turn(&line), "must stay ambient: {line}");
    }
}

#[test]
fn wake_reason_reads_the_typed_peer_origin() {
    let peer = json!({
        "type": "user",
        "origin": {
            "kind": "peer",
            "from": "uds:/tmp/cc-socks/24353.sock",
            "name": "remotecoder-b8",
            "verifiedPeerPid": 24353,
        },
    });

    assert_eq!(
        wake_reason(&peer),
        Some(json!({"kind": "peer", "name": "remotecoder-b8"}))
    );
    assert_eq!(wake_reason(&json!({"type": "assistant"})), None);
    assert_eq!(wake_reason(&json!({"origin": {"name": "x"}})), None);
    assert_eq!(
        wake_reason(&json!({"origin": {"kind": "cron"}})),
        Some(json!({"kind": "cron"}))
    );
}

#[tokio::test]
async fn a_peer_wake_opens_a_first_class_turn_with_its_provenance() {
    let (tx, _rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let (mut runtime, mut child) = placeholder_runtime(&request("claude_a", false)).await;

    let started = agent
        .open_agent_initiated_turn(
            &mut runtime,
            "claude_a",
            &json!({
                "type": "user",
                "isReplay": true,
                "isSynthetic": true,
                "origin": {"kind": "peer", "name": "remotecoder-b8"},
                "message": {"role": "user", "content": "Another Claude session sent a message"},
            }),
        )
        .expect("a peer wake opens a turn");

    assert_eq!(started["method"], json!("turn/started"));
    assert_eq!(started["params"]["turn"]["status"], json!("inProgress"));
    assert_eq!(started["params"]["agentInitiated"], json!(true));
    assert_eq!(
        started["params"]["wakeReason"],
        json!({"kind": "peer", "name": "remotecoder-b8"})
    );
    assert!(
        runtime
            .active_turn
            .as_ref()
            .is_some_and(|active| active.agent_initiated)
    );
    assert_eq!(
        runtime.lifecycle_generation, 2,
        "a wake must invalidate the idle timer armed by the previous turn"
    );
    let active = runtime
        .active_turn
        .as_ref()
        .expect("the wake is owned by its runtime");
    assert_eq!(
        Some(active.translator.turn_id()),
        started["params"]["turn"]["id"].as_str()
    );
    let _ = child.kill().await;
}

#[tokio::test]
async fn ambient_and_subagent_lines_leave_the_runtime_idle() {
    let (tx, _rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let (mut runtime, mut child) = placeholder_runtime(&request("claude_a", false)).await;

    for line in [
        // Inner traffic from a background subagent, on a turn-opening type.
        json!({"type": "assistant", "parent_tool_use_id": "toolu_1", "message": {"content": []}}),
        json!({"type": "user", "parent_tool_use_id": "toolu_1", "message": {"content": []}}),
        // The completion notification that precedes a subagent wake.
        json!({"type": "system", "subtype": "task_notification", "task_id": "t1"}),
    ] {
        assert!(
            agent
                .open_agent_initiated_turn(&mut runtime, "claude_a", &line)
                .is_none(),
            "must not open a turn: {line}"
        );
    }

    assert!(runtime.active_turn.is_none());
    assert_eq!(runtime.lifecycle_generation, 1);
    assert_eq!(agent.active_turn_count().await, 0);
    let _ = child.kill().await;
}

#[tokio::test(start_paused = true)]
async fn live_background_tasks_hold_the_runtime_past_the_idle_timeout() {
    let (tx, _rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let (runtime, mut child) = placeholder_runtime(&request("claude_a", false)).await;
    let pid = runtime.process_group_id;
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".to_owned(), runtime);
    let tasks = |ids: &[&str]| {
        json!({
            "type": "system",
            "subtype": "background_tasks_changed",
            "tasks": ids
                .iter()
                .map(|id| json!({"task_id": id, "task_type": "local_agent", "description": id}))
                .collect::<Vec<_>>(),
        })
    };

    agent
        .schedule_runtime_idle_timeout("claude_a".to_owned(), pid, 1)
        .await;
    agent
        .track_background_tasks("claude_a", pid, &tasks(&["agent", "shell"]))
        .await;
    agent
        .schedule_runtime_idle_timeout("claude_a".to_owned(), pid, 1)
        .await;
    agent
        .track_background_tasks("claude_a", pid, &tasks(&["agent"]))
        .await;
    tokio::time::sleep(RUNTIME_IDLE_TIMEOUT * 2).await;
    assert!(
        agent.has_runtime("claude_a").await,
        "a runtime with live background tasks is not idle"
    );
    assert!(agent.has_pending_or_active_work("claude_a").await);
    assert!(!agent.release_idle_runtime("claude_a").await);

    agent
        .track_background_tasks("claude_a", pid, &tasks(&[]))
        .await;
    assert!(!agent.has_pending_or_active_work("claude_a").await);
    tokio::time::sleep(RUNTIME_IDLE_TIMEOUT + Duration::from_secs(1)).await;
    tokio::time::timeout(Duration::from_secs(30), async {
        while agent.has_runtime("claude_a").await {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the idle timer retires the runtime once its background tasks end");
    let _ = child.kill().await;
}

#[tokio::test(start_paused = true)]
async fn the_idle_cap_retires_the_least_recently_used_idle_runtime_but_never_an_active_turn() {
    let (tx, _rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let threads = [
        "claude_active",
        "claude_oldest",
        "claude_older",
        "claude_newest",
    ];
    let mut children = Vec::new();
    let mut pids = HashMap::new();
    for thread in threads {
        let (mut runtime, child) = placeholder_runtime(&request(thread, false)).await;
        if thread == "claude_active" {
            runtime.active_turn = Some(wake_turn("turn-active"));
        }
        pids.insert(thread, runtime.process_group_id);
        agent
            .runtimes
            .lock()
            .await
            .insert(thread.to_owned(), runtime);
        children.push(child);
    }

    for thread in threads {
        agent
            .schedule_runtime_idle_timeout(thread.to_owned(), pids[thread], 1)
            .await;
        tokio::time::advance(Duration::from_secs(1)).await;
    }
    tokio::time::timeout(Duration::from_secs(30), async {
        while agent.has_runtime("claude_oldest").await {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the cap retires the least recently used idle runtime");

    assert!(
        agent.has_runtime("claude_active").await,
        "a runtime with an active turn is never an idle-cap victim"
    );
    assert!(agent.has_runtime("claude_older").await);
    assert!(agent.has_runtime("claude_newest").await);
    assert!(agent.idle_runtimes_beyond_cap().await.is_empty());
    for mut child in children {
        let _ = child.kill().await;
    }
}

fn append_transcript(path: &Path, records: &[Value]) -> u64 {
    use std::io::Write;
    fs::create_dir_all(path.parent().expect("transcript directory")).unwrap();
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .unwrap();
    for record in records {
        writeln!(file, "{record}").unwrap();
    }
    file.metadata().unwrap().len()
}

fn wake_tool_records(id: &str, name: &str, input: Value, result: Value) -> [Value; 2] {
    let timestamp = crate::observability::journal::now_rfc3339_millis();
    [
        json!({
            "type": "assistant",
            "isSidechain": false,
            "timestamp": timestamp,
            "message": {"content": [{"type": "tool_use", "id": id, "name": name, "input": input}]},
        }),
        json!({
            "type": "user",
            "isSidechain": false,
            "timestamp": timestamp,
            "message": {"content": [{"type": "tool_result", "tool_use_id": id, "content": "ok"}]},
            "toolUseResult": result,
        }),
    ]
}

fn agent_with_claude_home(home: &ClaudeTestSettings) -> Arc<ClaudeSupervisor> {
    let (tx, _rx) = mpsc::channel(16);
    ClaudeSupervisor::new(
        home.settings.clone(),
        tx,
        Journal::disabled(),
        McpTokens::default(),
    )
}

async fn wait_until_retired(agent: &ClaudeSupervisor, thread_id: &str, reason: &str) {
    tokio::time::timeout(Duration::from_secs(30), async {
        while agent.has_runtime(thread_id).await {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect(reason);
}

#[tokio::test(start_paused = true)]
async fn a_scheduled_wake_loop_in_the_transcript_holds_an_idle_runtime_past_timeout_and_cap() {
    let home = ClaudeSettings::isolated_for_test();
    let agent = agent_with_claude_home(&home);
    let turn = request("claude_a", false);
    append_transcript(
        &crate::providers::claude::timeline::session_path_for_cwd(
            &home.settings.claude_home,
            &turn.cwd,
            &turn.session_uuid,
        ),
        &wake_tool_records(
            "toolu_wake",
            "ScheduleWakeup",
            json!({"delaySeconds": 1800}),
            json!({
                "scheduledFor": crate::time::unix_millis() + 30 * 60 * 1000,
                "clampedDelaySeconds": 1800,
                "wasClamped": false,
            }),
        ),
    );
    let (runtime, mut child) = placeholder_runtime(&turn).await;
    let pid = runtime.process_group_id;
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".to_owned(), runtime);

    let mut others = Vec::new();
    for (thread, session) in [
        ("claude_b", "22222222-2222-4333-8444-555555555555"),
        ("claude_c", "33333333-2222-4333-8444-555555555555"),
    ] {
        let (mut other, other_child) = placeholder_runtime(&request(thread, false)).await;
        other.session_uuid = session.to_owned();
        let other_pid = other.process_group_id;
        agent.runtimes.lock().await.insert(thread.to_owned(), other);
        others.push((thread, other_pid, other_child));
    }
    agent
        .schedule_runtime_idle_timeout("claude_a".to_owned(), pid, 1)
        .await;
    for (thread, other_pid, _) in &others {
        tokio::time::advance(Duration::from_secs(1)).await;
        agent
            .schedule_runtime_idle_timeout((*thread).to_owned(), *other_pid, 1)
            .await;
    }

    tokio::time::sleep(RUNTIME_IDLE_TIMEOUT * 2).await;
    assert!(
        agent.has_runtime("claude_a").await,
        "a pending wake outlasts the idle timeout and the cap"
    );
    assert!(!agent.has_runtime("claude_b").await);
    assert!(!agent.has_runtime("claude_c").await);

    tokio::time::sleep(Duration::from_secs(2 * 60 * 60)).await;
    wait_until_retired(&agent, "claude_a", "a silent loop stops holding").await;
    let _ = child.kill().await;
    for (_, _, mut other_child) in others {
        let _ = other_child.kill().await;
    }
}

#[tokio::test]
async fn an_explicit_release_keeps_a_runtime_that_holds_a_scheduled_wake() {
    let home = ClaudeSettings::isolated_for_test();
    let agent = agent_with_claude_home(&home);
    let turn = request("claude_a", false);
    append_transcript(
        &crate::providers::claude::timeline::session_path_for_cwd(
            &home.settings.claude_home,
            &turn.cwd,
            &turn.session_uuid,
        ),
        &wake_tool_records(
            "toolu_wake",
            "ScheduleWakeup",
            json!({"delaySeconds": 1800}),
            json!({
                "scheduledFor": crate::time::unix_millis() + 30 * 60 * 1000,
                "clampedDelaySeconds": 1800,
                "wasClamped": false,
            }),
        ),
    );
    let (runtime, mut child) = placeholder_runtime(&turn).await;
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".to_owned(), runtime);

    assert!(!agent.release_idle_runtime("claude_a").await);
    assert!(agent.has_runtime("claude_a").await);
    let _ = child.kill().await;
}

#[tokio::test]
async fn a_transcript_that_cannot_be_read_never_proves_a_runtime_idle() {
    let home = ClaudeSettings::isolated_for_test();
    let agent = agent_with_claude_home(&home);
    let turn = request("claude_a", false);
    let transcript = crate::providers::claude::timeline::session_path_for_cwd(
        &home.settings.claude_home,
        &turn.cwd,
        &turn.session_uuid,
    );
    append_transcript(
        &transcript,
        &wake_tool_records("toolu_read", "Read", json!({}), json!({})),
    );
    let (runtime, mut child) = placeholder_runtime(&turn).await;
    let pid = runtime.process_group_id;
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".to_owned(), runtime);
    assert!(matches!(
        agent.refresh_wakes("claude_a", pid).await,
        WakeEvidence::Fresh
    ));

    std::fs::write(&transcript, b"").unwrap();

    assert!(matches!(
        agent.refresh_wakes("claude_a", pid).await,
        WakeEvidence::Unreadable
    ));
    assert!(!agent.release_idle_runtime("claude_a").await);
    assert!(agent.has_runtime("claude_a").await);
    let _ = child.kill().await;
}

#[tokio::test(start_paused = true)]
async fn a_resumed_runtime_holds_for_a_carried_cron_until_it_fires() {
    let home = ClaudeSettings::isolated_for_test();
    let agent = agent_with_claude_home(&home);
    let turn = request("claude_a", false);
    let transcript = crate::providers::claude::timeline::session_path_for_cwd(
        &home.settings.claude_home,
        &turn.cwd,
        &turn.session_uuid,
    );
    let cron = crate::providers::claude::wake_hold::pinned_cron(
        SystemTime::now() + Duration::from_secs(2 * 60 * 60),
    );
    let resumed_at = append_transcript(
        &transcript,
        &wake_tool_records(
            "toolu_cron",
            "CronCreate",
            json!({"cron": cron, "prompt": "Check the build", "recurring": false}),
            json!({"id": "b067e269", "humanSchedule": cron, "recurring": false, "durable": false}),
        ),
    );
    let (mut runtime, mut child) = placeholder_runtime(&turn).await;
    runtime.wakes = WakeHold::resuming(resumed_at);
    let pid = runtime.process_group_id;
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".to_owned(), runtime);

    agent
        .schedule_runtime_idle_timeout("claude_a".to_owned(), pid, 1)
        .await;
    tokio::time::sleep(RUNTIME_IDLE_TIMEOUT * 3).await;
    assert!(
        agent.has_runtime("claude_a").await,
        "the cron that --resume restored holds the runtime although the stream never mentioned it"
    );

    append_transcript(
        &transcript,
        &[json!({
            "type": "user",
            "isSidechain": false,
            "isMeta": true,
            "turnOrigin": "scheduled",
            "promptSource": "system",
            "timestamp": crate::observability::journal::now_rfc3339_millis(),
            "message": {"role": "user", "content": "Check the build"},
        })],
    );
    agent
        .schedule_runtime_idle_timeout("claude_a".to_owned(), pid, 1)
        .await;
    tokio::time::sleep(RUNTIME_IDLE_TIMEOUT + Duration::from_secs(1)).await;
    wait_until_retired(&agent, "claude_a", "a fired one-shot releases its hold").await;
    let _ = child.kill().await;
}

#[tokio::test]
async fn an_agent_initiated_turn_completes_with_its_provenance() {
    let (tx, mut rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let (mut runtime, mut child) = placeholder_runtime(&request("claude_a", false)).await;
    let process_group_id = runtime.process_group_id;
    runtime.active_turn = Some(wake_turn("claude-turn-wake"));
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".to_string(), runtime);

    agent
        .finish_turn(
            "claude_a",
            process_group_id,
            TurnResult {
                status: "completed".to_string(),
                error_message: None,
                error_info: None,
            },
        )
        .await;

    let completed = next_notification(&mut rx).await;
    assert_eq!(completed["method"], json!("turn/completed"));
    assert_eq!(completed["params"]["turn"]["id"], json!("claude-turn-wake"));
    assert_eq!(completed["params"]["agentInitiated"], json!(true));
    assert_eq!(agent.active_turn_count().await, 0);
    let _ = child.kill().await;
}

#[tokio::test]
async fn dispatching_during_an_agent_initiated_turn_completes_it_before_starting_a_user_turn() {
    let (tx, mut rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let dispatch = request("claude_a", false);
    let (mut runtime, mut child) = placeholder_runtime(&dispatch).await;
    runtime.active_turn = Some(wake_turn("claude-turn-wake"));
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".to_string(), runtime);

    let turn_id = agent
        .start_turn(dispatch)
        .await
        .expect("a dispatch folds into the running wake turn");
    assert!(
        agent
            .conversation_index
            .parent("claude_a")
            .await
            .unwrap()
            .selection
            .is_some()
    );

    let completed = next_notification(&mut rx).await;
    assert_eq!(completed["method"], json!("turn/completed"));
    assert_eq!(completed["params"]["turn"]["id"], json!("claude-turn-wake"));
    assert_eq!(completed["params"]["turn"]["status"], json!("completed"));
    assert_eq!(completed["params"]["agentInitiated"], json!(true));

    let started = next_notification(&mut rx).await;
    assert_eq!(started["method"], json!("turn/started"));
    assert_eq!(started["params"]["turn"]["id"], json!(turn_id));
    assert!(
        started["params"].get("agentInitiated").is_none(),
        "the dispatched turn is the user's own"
    );

    let runtimes = agent.runtimes.lock().await;
    let active = runtimes["claude_a"]
        .active_turn
        .as_ref()
        .expect("the dispatched turn owns the stream");
    assert!(!active.agent_initiated);
    drop(runtimes);
    assert_eq!(
        agent.active_turn_id("claude_a").await.as_deref(),
        Some(turn_id.as_str())
    );
    let _ = child.kill().await;
}

/// The subscription guard is the money invariant, and the stream reader is
/// the only thing enforcing it: `system/init` fires per turn, so a violating
/// init must kill the runtime whether or not a turn is open.
#[tokio::test]
async fn a_violating_init_line_kills_the_runtime() {
    let (tx, mut rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);

    let (stdout, process_group_id, mut child) = violating_init_stream();

    let (mut runtime, mut placeholder) = placeholder_runtime(&request("claude_a", false)).await;
    runtime.process_group_id = process_group_id;
    runtime.active_turn = Some(RuntimeTurn::new(
        TurnTranslator::new(
            "claude_a".to_string(),
            "claude-turn-1".to_string(),
            "/tmp".to_string(),
            None,
            0,
            Arc::default(),
        ),
        false,
        None,
    ));
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".to_string(), runtime);

    // Reap concurrently, as production does. An unreaped child can keep
    // its process group observable through the entire TERM/KILL ladder.
    let reaper = tokio::spawn(async move { child.wait().await });
    drive_stream_reader(&agent, stdout, process_group_id).await;

    let completed = next_notification(&mut rx).await;
    assert_eq!(completed["method"], json!("turn/completed"));
    assert_eq!(completed["params"]["turn"]["status"], json!("failed"));
    let message = completed["params"]["turn"]["error"]["message"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(
        message.contains("billing guard"),
        "unexpected failure message: {message}"
    );
    assert_eq!(agent.active_turn_count().await, 0);
    assert!(agent.runtimes.lock().await.is_empty());
    reaper
        .await
        .expect("billing-guard child reaper panicked")
        .expect("reap billing-guard child");
    let _ = placeholder.kill().await;
}

/// A wake's init arrives with no turn open, which is exactly the line that
/// used to reach no translator at all. The runtime must still die.
#[tokio::test]
async fn a_violating_init_line_outside_a_turn_kills_the_runtime() {
    let (tx, mut rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let (stdout, process_group_id, mut child) = violating_init_stream();

    let (mut runtime, mut placeholder) = placeholder_runtime(&request("claude_a", false)).await;
    runtime.process_group_id = process_group_id;
    assert!(runtime.active_turn.is_none());
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".to_string(), runtime);

    // Reap concurrently, as production does. An unreaped child can keep
    // its process group observable through the entire TERM/KILL ladder.
    let reaper = tokio::spawn(async move { child.wait().await });
    drive_stream_reader(&agent, stdout, process_group_id).await;

    assert!(
        agent.runtimes.lock().await.is_empty(),
        "an idle runtime that would not bill the subscription must still be retired"
    );
    assert_eq!(agent.active_turn_count().await, 0);
    assert!(
        rx.try_recv().is_err(),
        "there is no open turn to report as failed"
    );
    reaper
        .await
        .expect("billing-guard child reaper panicked")
        .expect("reap billing-guard child");
    let _ = placeholder.kill().await;
}

/// The TERM/KILL ladder must reach children that ignore SIGTERM.
#[tokio::test]
async fn terminate_group_kills_a_sigterm_ignoring_tree() {
    let (tx, _rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);

    let mut command = Command::new("perl");
    command
        .arg("-e")
        .arg(r#"$SIG{TERM}='IGNORE'; my $c=fork(); die unless defined $c; if ($c==0){ $SIG{TERM}='IGNORE'; sleep 300; exit 0; } $|=1; print "ready\n"; sleep 300;"#)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(false);
    unsafe {
        command.pre_exec(|| {
            nix::unistd::setsid().map_err(std::io::Error::other)?;
            Ok(())
        });
    }
    let mut child = command.spawn().expect("spawn test tree");
    let pid = child.id().expect("pid") as i32;
    let group = Pid::from_raw(pid);
    let mut lines = BufReader::new(child.stdout.take().expect("readiness pipe")).lines();
    let ready = tokio::time::timeout(Duration::from_secs(5), lines.next_line())
        .await
        .expect("test tree starts")
        .expect("readiness line");
    assert_eq!(ready.as_deref(), Some("ready"));
    tokio::spawn(async move {
        let _ = child.wait().await;
    });
    assert!(group_exists(group));

    agent.terminate_group(group).await;

    assert!(!group_exists(group));
}

#[tokio::test]
async fn rename_review_an_unanswered_live_rename_does_not_block_user_stop() {
    let (tx, mut notifications) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let thread = "claude_a";
    let (mut runtime, mut child) = placeholder_runtime(&request(thread, false)).await;
    runtime.active_turn = Some(wake_turn("stopped-turn"));
    agent.runtimes.lock().await.insert(thread.into(), runtime);
    let rename = tokio::spawn({
        let agent = Arc::clone(&agent);
        async move {
            agent
                .rename_session(thread, "11111111-2222-4333-8444-555555555555", "Pending")
                .await
        }
    });
    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if agent
                .runtimes
                .lock()
                .await
                .get(thread)
                .unwrap()
                .pending_controls
                .len()
                == 1
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let reaper = tokio::spawn(async move { child.wait().await });
    tokio::time::timeout(
        Duration::from_secs(6),
        agent.interrupt(thread, "stopped-turn", async || Ok(Vec::new())),
    )
    .await
    .expect("Stop must reach its interrupt/kill deadline")
    .unwrap();
    assert!(rename.await.unwrap().is_err());
    assert!(!agent.runtimes.lock().await.contains_key(thread));
    assert_eq!(
        crate::test_support::claude_event(notifications.recv().await.unwrap())["method"],
        "turn/completed"
    );
    assert!(reaper.await.unwrap().is_ok());
}

#[tokio::test]
async fn idle_rename_appends_the_sdk_title_record_and_announces_it() {
    let claude_test = ClaudeSettings::isolated_for_test();
    let root = tempfile::TempDir::new().unwrap();
    let claude_home = root.path().join("account");
    let session = "11111111-2222-4333-8444-555555555555";
    let thread_id = format!("claude_{session}");
    let path =
        crate::providers::claude::timeline::session_path_for_cwd(&claude_home, "/work", session);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let (tx, mut rx) = mpsc::channel(16);
    let agent = ClaudeSupervisor::new(
        ClaudeSettings {
            claude_home,
            ..claude_test.settings.clone()
        },
        tx,
        Journal::disabled(),
        McpTokens::default(),
    );
    let rename = || agent.rename_session(&thread_id, session, "Nightly memory");

    assert_eq!(rename().await, Ok(SessionRename::NoConversation));
    fs::write(&path, "").unwrap();
    assert_eq!(rename().await, Ok(SessionRename::NoConversation));
    fs::write(&path, "{\"type\":\"user\"").unwrap();
    assert!(rename().await.unwrap_err().contains("mid-record"));
    assert_eq!(fs::read_to_string(&path).unwrap(), "{\"type\":\"user\"");
    assert!(rx.try_recv().is_err());

    fs::write(&path, "{\"type\":\"user\"}\n").unwrap();
    assert_eq!(rename().await, Ok(SessionRename::Renamed));
    let records = fs::read_to_string(&path).unwrap();
    let last = records.lines().last().unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(last).unwrap(),
        json!({"type": "custom-title", "customTitle": "Nightly memory", "sessionId": session})
    );
    assert_eq!(
        crate::test_support::claude_event(rx.try_recv().unwrap()),
        json!({"method": "thread/name/updated",
            "params": {"threadId": thread_id, "threadName": "Nightly memory"}})
    );
    assert!(rx.try_recv().is_err());
}

#[tokio::test]
#[ignore = "uses the local Claude subscription: Sonnet low"]
async fn live_rename_reaches_unstarted_running_and_idle_sessions() -> anyhow::Result<()> {
    use anyhow::{Context, ensure};
    let dir = tempfile::TempDir::new()?;
    let (tx, mut rx) = mpsc::channel(1024);
    let settings = live_subscription_settings(dir.path());
    let agent = ClaudeSupervisor::new(settings, tx, Journal::disabled(), McpTokens::default());
    let session_uuid = agent.mint_session().await?;
    let thread_id = format!("claude_{session_uuid}");
    let rename = |name: &'static str| {
        let agent = &agent;
        let thread_id = thread_id.clone();
        let session_uuid = session_uuid.clone();
        async move {
            agent
                .rename_session(&thread_id, &session_uuid, name)
                .await
                .map_err(anyhow::Error::msg)
        }
    };
    let result = tokio::time::timeout(Duration::from_secs(150), async {
        ensure!(
            rename("Before launch").await? == SessionRename::NoConversation,
            "an unstarted session accepted a title"
        );
        let turn_id = agent
            .start_turn(ClaudeTurnRequest {
                thread_id: thread_id.clone(),
                session_uuid: session_uuid.clone(),
                first_turn: true,
                input: ClaudeUserInput::text("Reply with only READY. Do not use tools."),
                selection: selection("sonnet", Some("low")),
                cwd: dir.path().display().to_string(),
            })
            .await
            .map_err(|error| anyhow::anyhow!(error.message))?;
        ensure!(
            rename("Running title").await? == SessionRename::Renamed,
            "the running session was not renamed"
        );
        let mut announced = Vec::new();
        loop {
            let frame: Value = crate::test_support::claude_event(
                rx.recv().await.context("notification stream ended")?,
            );
            if frame["method"] == "thread/name/updated" {
                announced.push(frame["params"]["threadName"].clone());
            }
            if frame["method"] == "turn/completed" && frame["params"]["turn"]["id"] == turn_id {
                ensure!(
                    frame["params"]["turn"]["status"] == "completed",
                    "wrong completion: {frame}"
                );
                break;
            }
        }
        ensure!(
            announced == [json!("Running title")],
            "announcements: {announced:?}"
        );
        ensure!(
            agent.release_idle_runtime(&thread_id).await,
            "runtime was not released"
        );
        ensure!(
            rename("Idle title").await? == SessionRename::Renamed,
            "the idle session was not renamed"
        );
        let path = crate::providers::claude::timeline::resolve_session_path(
            &session_uuid,
            &agent.settings.claude_home,
        )?;
        let titles = fs::read_to_string(&path)?
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .filter(|record| record["type"] == "custom-title")
            .filter_map(|record| record["customTitle"].as_str().map(str::to_owned))
            .collect::<Vec<_>>();
        ensure!(
            titles.iter().any(|title| title == "Running title")
                && titles.last().map(String::as_str) == Some("Idle title"),
            "session titles: {titles:?}"
        );
        let header = crate::providers::claude::history::ClaudeHistory::new(
            agent.settings.claude_home.clone(),
            Arc::new(crate::providers::claude::projection::ProjectionCache::new(
                crate::providers::claude::projection::PROJECTION_CACHE_BUDGET_BYTES,
            )),
        )
        .read_thread_header(session_uuid.clone())
        .await?;
        ensure!(header["name"] == "Idle title", "history header: {header}");
        fs::remove_file(&path)?;
        println!("live Claude rename probe passed: session={session_uuid}");
        Ok::<(), anyhow::Error>(())
    })
    .await;
    agent.stop_all().await;
    result.context("live Claude rename probe exceeded 150 seconds")?
}

#[tokio::test]
#[ignore = "uses the local Claude subscription: Sonnet low"]
async fn live_side_question_answers_from_the_warm_runtime_without_a_turn() -> anyhow::Result<()> {
    use anyhow::{Context, ensure};
    let dir = tempfile::TempDir::new()?;
    let (tx, mut rx) = mpsc::channel(1024);
    let settings = live_subscription_settings(dir.path());
    let agent = ClaudeSupervisor::new(settings, tx, Journal::disabled(), McpTokens::default());
    let session_uuid = agent.mint_session().await?;
    let thread_id = format!("claude_{session_uuid}");
    let result = tokio::time::timeout(Duration::from_secs(150), async {
        ensure!(
            agent.side_question(&thread_id, "Unused").await.map_err(anyhow::Error::msg)?.is_none(),
            "a thread without a runtime answered"
        );
        let turn_id = agent
            .start_turn(ClaudeTurnRequest {
                thread_id: thread_id.clone(),
                session_uuid: session_uuid.clone(),
                first_turn: true,
                input: ClaudeUserInput::text(
                    "We are planning a bakery's sourdough schedule. Reply with only READY. Do not use tools.",
                ),
                selection: selection("sonnet", Some("low")),
                cwd: dir.path().display().to_string(),
            })
            .await
            .map_err(|error| anyhow::anyhow!(error.message))?;
        println!("side question probe: turn {turn_id} started");
        loop {
            let frame: Value = crate::test_support::claude_event(rx.recv().await.context("notification stream ended")?);
            if frame["method"] == "turn/completed" && frame["params"]["turn"]["id"] == turn_id {
                break;
            }
        }
        println!("side question probe: turn completed");
        let answer = agent
            .side_question(
                &thread_id,
                "Suggest a title for this conversation. Reply with only the title. Do not use tools.",
            )
            .await
            .map_err(anyhow::Error::msg)?
            .context("the warm runtime gave no side-question answer")?;
        ensure!(
            answer.to_lowercase().contains("sourdough") || answer.to_lowercase().contains("bak"),
            "answer ignored the conversation: {answer:?}"
        );
        tokio::time::sleep(Duration::from_secs(3)).await;
        let mut stray = Vec::new();
        while let Ok(frame) = rx.try_recv() {
            let frame = crate::test_support::claude_event(frame);
            stray.push(frame["method"].clone());
        }
        ensure!(
            !stray.iter().any(|method| method == "turn/started"),
            "the side question opened a turn: {stray:?}"
        );
        let path = crate::providers::claude::timeline::resolve_session_path(
            &session_uuid,
            &agent.settings.claude_home,
        )?;
        let transcript = fs::read_to_string(&path)?;
        ensure!(
            !transcript.contains("Suggest a title for this conversation"),
            "the side question reached the transcript"
        );
        fs::remove_file(&path)?;
        println!("live Claude side question passed: {answer:?}");
        Ok::<(), anyhow::Error>(())
    })
    .await;
    agent.stop_all().await;
    result.context("live Claude side question probe exceeded 150 seconds")?
}

#[tokio::test]
async fn bounds_review_capacity_failure_records_and_publishes_the_accepted_assistant_prefix() {
    let (tx, mut rx) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let (mut runtime, mut placeholder) = placeholder_runtime(&request("claude_a", false)).await;
    let group = runtime.process_group_id;
    let mut turn = wake_turn("capacity-turn");
    for index in 0..255 {
        turn.translator.handle(&json!({"type":"assistant", "message":{"content":[{"type":"tool_use", "id":index.to_string(), "name":"Bash", "input":{}}]}}));
    }
    runtime.active_turn = Some(turn);
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".into(), runtime);
    let record = json!({"type":"assistant", "uuid":"mixed", "message":{"id":"message", "content":[
        {"type":"text","text":"Accepted text"},
        {"type":"tool_use","id":"accepted","name":"Bash","input":{}},
        {"type":"tool_use","id":"rejected","name":"Bash","input":{}}
    ]}});
    let mut feeder = Command::new("/bin/echo")
        .arg(record.to_string())
        .stdout(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let stdout = feeder.stdout.take().unwrap();
    Arc::clone(&agent)
        .read_runtime_stream("claude_a".into(), group, stdout, CancellationToken::new())
        .await;
    let mut frames = Vec::new();
    while let Ok(frame) = rx.try_recv() {
        let frame = crate::test_support::claude_event(frame);
        frames.push(frame);
    }
    assert_eq!(
        frames
            .iter()
            .map(|frame| frame["method"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["item/completed", "item/started", "error", "turn/completed"]
    );
    assert_eq!(frames[0]["params"]["item"]["text"], "Accepted text");
    assert_eq!(frames[1]["params"]["item"]["id"], "accepted");
    assert_eq!(frames[2]["params"]["data"]["kind"], "capacity");
    let index =
        crate::providers::claude::conversation_index::read(&agent.settings.claude_home, "claude_a")
            .unwrap();
    assert!(index.items.contains_key("message#0"));
    assert!(index.items.contains_key("accepted"));
    assert!(!index.items.contains_key("rejected"));
    assert!(!agent.has_runtime("claude_a").await);
    let _ = feeder.wait().await;
    let _ = placeholder.wait().await;
}

#[tokio::test]
async fn live_checkpoint_snapshot_covers_a_pending_start_and_orders_the_continuation() {
    use std::io::Write;
    let (tx, mut rx) = mpsc::channel(1);
    tx.send(ClaudeNotification::Event(json!({"held":true})))
        .await
        .unwrap();
    let (_home, agent) = isolated_agent(tx);
    let dispatch = request("claude_a", false);
    let (mut runtime, mut placeholder) = placeholder_runtime(&dispatch).await;
    let group = runtime.process_group_id;
    let (_, translator) = agent.new_turn("claude_a", "/tmp");
    runtime.active_turn = Some(RuntimeTurn::new(translator, true, None));
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".into(), runtime);
    let records = [
        json!({"type":"stream_event","event":{"type":"message_start","message":{"id":"message-a"}}}),
        json!({"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"AB"}}}),
        json!({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"C"}}}),
    ];
    let (stdout, mut feeder) = std::io::pipe().unwrap();
    for record in records {
        writeln!(feeder, "{record}").unwrap();
    }
    let stdout = tokio::process::ChildStdout::from_std(std::process::ChildStdout::from(
        std::os::fd::OwnedFd::from(stdout),
    ))
    .unwrap();
    let reader = tokio::spawn(Arc::clone(&agent).read_runtime_stream(
        "claude_a".into(),
        group,
        stdout,
        CancellationToken::new(),
    ));
    let observer = Arc::clone(&agent);
    crate::test_support::wait_until("the stream to hold the pending start", move || {
        observer.runtimes.try_lock().is_ok_and(|runtimes| {
            runtimes
                .get("claude_a")
                .and_then(ClaudeRuntime::running_turn)
                .and_then(|turn| turn.translator.live_checkpoint())
                .is_some_and(|snapshot| snapshot["liveItems"][0]["item"]["text"] == "AB")
        })
    })
    .await;
    let checkpoint = agent.live_checkpoint("claude_a").await.unwrap();
    assert_eq!(checkpoint["throughSequence"], 2);
    assert_eq!(checkpoint["activeTurn"]["itemsView"], "notLoaded");
    assert_eq!(
        crate::test_support::claude_event(rx.recv().await.unwrap())["held"],
        true
    );
    let started = crate::test_support::claude_event(rx.recv().await.unwrap());
    let delta = crate::test_support::claude_event(rx.recv().await.unwrap());
    let watermark = checkpoint["throughSequence"].as_u64().unwrap();
    let mut reconstructed = checkpoint["liveItems"][0]["item"]["text"]
        .as_str()
        .unwrap()
        .to_owned();
    for frame in [started, delta] {
        assert_eq!(frame["rcClaudeLive"]["epoch"], checkpoint["epoch"]);
        if frame["rcClaudeLive"]["sequence"].as_u64().unwrap() > watermark {
            reconstructed.push_str(frame["params"]["delta"].as_str().unwrap());
        }
    }
    assert_eq!(reconstructed, "ABC");
    assert_eq!(
        agent.live_checkpoint("claude_a").await.unwrap()["liveItems"][0]["item"]["text"],
        "ABC"
    );
    reader.abort();
    let _ = reader.await;
    drop(feeder);
    let retired = agent.runtimes.lock().await.remove("claude_a").unwrap();
    drop(retired);
    assert!(agent.live_checkpoint("claude_a").await.is_none());
    assert_eq!(Arc::strong_count(&agent.live_prefix_budget), 1);
    placeholder.kill().await.unwrap();
    let _ = placeholder.wait().await;
}

#[tokio::test]
async fn live_checkpoint_stream_journals_capacity_once_without_ending_the_turn() {
    let home = ClaudeSettings::isolated_for_test();
    let logs = tempfile::tempdir().unwrap();
    let journal = Journal::open_in(logs.path().to_owned(), 1);
    let (tx, mut rx) = mpsc::channel(8);
    let agent = ClaudeSupervisor::new(
        home.settings.clone(),
        tx,
        journal.clone(),
        McpTokens::default(),
    );
    let (mut runtime, mut placeholder) = placeholder_runtime(&request("claude_a", false)).await;
    let group = runtime.process_group_id;
    let (_, translator) = agent.new_turn("claude_a", "/tmp");
    runtime.active_turn = Some(RuntimeTurn::new(translator, true, None));
    agent
        .runtimes
        .lock()
        .await
        .insert("claude_a".into(), runtime);
    let records = [
        json!({"type":"stream_event","event":{"type":"message_start","message":{"id":"message-a"}}}),
        json!({"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}),
        json!({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x".repeat(crate::providers::claude::translate::live::MAX_LIVE_BLOCK_BYTES + 1)}}}),
        json!({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"continues"}}}),
        json!({"type":"result","subtype":"success","result":"Canonical answer"}),
    ];
    fs::create_dir_all(&home.settings.claude_home).unwrap();
    let path = home.settings.claude_home.join("capacity-stream.jsonl");
    fs::write(
        &path,
        records
            .iter()
            .map(|record| format!("{record}\n"))
            .collect::<String>(),
    )
    .unwrap();
    let mut feeder = Command::new("/bin/cat")
        .arg(&path)
        .stdout(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let stdout = feeder.stdout.take().unwrap();
    Arc::clone(&agent)
        .read_runtime_stream("claude_a".into(), group, stdout, CancellationToken::new())
        .await;
    let mut frames = Vec::new();
    while let Ok(frame) = rx.try_recv() {
        frames.push(crate::test_support::claude_event(frame));
    }
    assert!(!frames.iter().any(|frame| frame["method"] == "error"));
    assert!(
        frames
            .iter()
            .any(|frame| frame["params"]["delta"] == "continues")
    );
    assert!(
        frames
            .iter()
            .any(|frame| frame["method"] == "turn/completed"
                && frame["params"]["turn"]["status"] == "completed")
    );
    journal.drain(Duration::from_secs(3)).await;
    let events = fs::read_dir(logs.path())
        .unwrap()
        .flat_map(|entry| {
            fs::read_to_string(entry.unwrap().path())
                .unwrap()
                .lines()
                .map(|line| serde_json::from_str::<Value>(line).unwrap())
                .collect::<Vec<_>>()
        })
        .filter(|event| event["event"] == "livePrefixCapacity")
        .collect::<Vec<_>>();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["threadId"], "claude_a");
    assert_eq!(events[0]["itemId"], "message-a#0");
    assert_eq!(events[0]["reason"]["kind"], "capacity");
    assert_eq!(events[0]["reason"]["resource"], "live block prefix bytes");
    let _ = feeder.wait().await;
    let _ = placeholder.wait().await;
}

#[tokio::test]
async fn input_stop_blocked_child_stdin_never_holds_stop_behind_start_fold_or_steer() {
    for mode in ["start", "fold", "steer"] {
        assert_blocked_input_retirement(mode).await;
    }
}

#[tokio::test]
async fn input_stop_planned_suspension_never_waits_for_the_blocked_child_pipe() {
    assert_blocked_input_retirement("suspend").await;
}

async fn assert_blocked_input_retirement(mode: &'static str) {
    crate::test_support::with_manual_time(async {
        let (tx, mut events) = mpsc::channel(32);
        let (_home, agent) = isolated_agent(tx);
        let thread = "claude_a";
        let request = request(thread, false);
        let (mut runtime, mut placeholder) = placeholder_runtime(&request).await;
        placeholder.kill().await.unwrap();
        placeholder.wait().await.unwrap();
        let mut command = Command::new("/usr/bin/perl");
        command
            .args(["-e", "$|=1; print qq(ready\\n); sleep 300;"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        unsafe {
            command.pre_exec(|| {
                nix::unistd::setsid().map_err(std::io::Error::other)?;
                Ok(())
            });
        }
        let mut child = command.spawn().unwrap();
        let group = child.id().unwrap() as i32;
        let mut ready = BufReader::new(child.stdout.take().unwrap()).lines();
        assert_eq!(ready.next_line().await.unwrap().as_deref(), Some("ready"));
        runtime.input = InputWriter::spawn(child.stdin.take().unwrap());
        runtime.process_group_id = group;
        let input = runtime.input.clone();
        if mode != "start" && mode != "suspend" {
            let mut active = wake_turn("existing-turn");
            active.agent_initiated = mode == "fold";
            runtime.active_turn = Some(active);
        }
        agent.process_registry.lock().unwrap().groups.insert(group);
        agent.runtimes.lock().await.insert(thread.into(), runtime);
        let writing = tokio::spawn({
            let agent = Arc::clone(&agent);
            async move {
                let mut request = request;
                request.input = ClaudeUserInput::text("a".repeat(1024 * 1024));
                if mode == "steer" {
                    agent
                        .steer(thread, "existing-turn", &request.input)
                        .await
                        .map(|()| String::new())
                        .map_err(|error| format!("{error:?}"))
                } else {
                    agent
                        .start_turn(request)
                        .await
                        .map_err(|error| format!("{error:?}"))
                }
            }
        });
        let pending = input.unconsumed().clone();
        crate::test_support::wait_until("input to enter the unread child pipe", move || {
            !pending.pending().is_empty()
        })
        .await;
        assert!(!writing.is_finished());
        let turn = agent.active_turn_id(thread).await.unwrap();
        let reaper = tokio::spawn({
            let agent = Arc::clone(&agent);
            async move {
                let result = child.wait().await;
                agent.process_registry.lock().unwrap().groups.remove(&group);
                result
            }
        });
        let stopping = tokio::spawn({
            let agent = Arc::clone(&agent);
            let turn = turn.clone();
            async move {
                if mode == "suspend" {
                    assert!(agent.suspend(thread).await);
                } else {
                    agent
                        .interrupt(thread, &turn, async || Ok(Vec::new()))
                        .await
                        .unwrap();
                }
            }
        });
        if mode != "suspend" {
            let agent = Arc::clone(&agent);
            crate::test_support::wait_until("Stop interrupt control to be queued", move || {
                agent.runtimes.try_lock().is_ok_and(|runtimes| {
                    runtimes
                        .get(thread)
                        .is_some_and(|runtime| !runtime.pending_controls.is_empty())
                })
            })
            .await;
            tokio::time::advance(INTERRUPT_GRACE + Duration::from_millis(1)).await;
        }
        reaper.await.unwrap().unwrap();
        tokio::time::advance(PROCESS_POLL_INTERVAL + Duration::from_millis(1)).await;
        stopping.await.unwrap();
        let write_result = writing.await.unwrap();
        assert!(!group_exists(Pid::from_raw(group)));
        assert!(write_result.is_err());
        assert!(!agent.has_runtime(thread).await);
        assert_eq!(
            agent
                .conversation_index
                .parent(thread)
                .await
                .unwrap()
                .stopped,
            mode != "suspend"
        );
        let completions: Vec<_> = std::iter::from_fn(|| events.try_recv().ok())
            .map(crate::test_support::claude_event)
            .filter(|event| {
                event["method"] == "turn/completed" && event["params"]["turn"]["id"] == turn
            })
            .collect();
        assert_eq!(completions.len(), 1, "{mode}: {completions:?}");
        assert_eq!(completions[0]["params"]["turn"]["status"], "interrupted");
        assert!(completions[0]["params"]["turn"]["error"].is_null());
    })
    .await;
}

async fn install_unread_runtime(
    agent: &Arc<ClaudeSupervisor>,
    thread: &str,
    active_turn: Option<RuntimeTurn>,
) -> (InputWriter, i32, tokio::process::Child) {
    let (mut runtime, mut placeholder) = placeholder_runtime(&request(thread, false)).await;
    placeholder.kill().await.unwrap();
    placeholder.wait().await.unwrap();
    let mut command = Command::new("/usr/bin/perl");
    command
        .args(["-e", "$|=1; print qq(ready\\n); sleep 300;"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    unsafe {
        command.pre_exec(|| {
            nix::unistd::setsid().map_err(std::io::Error::other)?;
            Ok(())
        });
    }
    let mut child = command.spawn().unwrap();
    let group = child.id().unwrap() as i32;
    let mut ready = BufReader::new(child.stdout.take().unwrap()).lines();
    assert_eq!(ready.next_line().await.unwrap().as_deref(), Some("ready"));
    runtime.input = InputWriter::spawn_with_stall_limit(
        child.stdin.take().unwrap(),
        Duration::from_millis(500),
    );
    runtime.process_group_id = group;
    runtime.active_turn = active_turn;
    let input = runtime.input.clone();
    agent.process_registry.lock().unwrap().groups.insert(group);
    agent.runtimes.lock().await.insert(thread.into(), runtime);
    (input, group, child)
}

#[tokio::test]
async fn input_stall_answers_unresponsive_without_holding_the_thread_or_killing_claude() {
    let (tx, _events) = mpsc::channel(32);
    let (_home, agent) = isolated_agent(tx);
    let thread = "claude_a";
    let (input, group, mut child) =
        install_unread_runtime(&agent, thread, Some(wake_turn("existing-turn"))).await;
    let steering = tokio::spawn({
        let agent = Arc::clone(&agent);
        async move {
            agent
                .steer(
                    thread,
                    "existing-turn",
                    &ClaudeUserInput::text("a".repeat(1024 * 1024)),
                )
                .await
        }
    });
    tokio::time::timeout(Duration::from_secs(3), async {
        while input.unconsumed().pending().is_empty() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the real child pipe write began");
    tokio::time::timeout(Duration::from_millis(250), agent.lock_lifecycle(thread))
        .await
        .expect("a steer waiting on stdin must not hold the thread lock");
    let error = tokio::time::timeout(Duration::from_secs(3), steering)
        .await
        .expect("a stalled steer is answered after its stall limit")
        .unwrap()
        .expect_err("an unread steer is not confirmed");
    let TurnControlError::Failed(error) = error else {
        panic!("the running turn was found: {error:?}")
    };
    let rpc = crate::rpc::error::RpcError::from(error);
    assert_eq!(rpc.code, RpcCode::Unavailable);
    assert_eq!(rpc.kind(), Some("inputDeliveryUncertain"));
    assert!(
        group_exists(Pid::from_raw(group)),
        "a stall never kills Claude"
    );
    assert_eq!(
        agent.active_turn_id(thread).await.as_deref(),
        Some("existing-turn")
    );
    let queued_behind = ClaudeUserInput {
        client_id: Some("queued-behind".into()),
        ..ClaudeUserInput::text("second")
    };
    let second = tokio::time::timeout(
        Duration::from_secs(3),
        agent.steer(thread, "existing-turn", &queued_behind),
    )
    .await
    .expect("a steer queued behind a stalled one is answered after its stall limit")
    .expect_err("a queued steer is not confirmed");
    let TurnControlError::Failed(second) = second else {
        panic!("the running turn was found: {second:?}")
    };
    assert_eq!(
        crate::rpc::error::RpcError::from(second).kind(),
        Some("inputDeliveryUncertain")
    );
    let pending = input.unconsumed().pending();
    assert_eq!(
        pending.len(),
        2,
        "every queued input is carried across a restart"
    );
    assert_eq!(pending[1].client_id.as_deref(), Some("queued-behind"));
    signal_group(Pid::from_raw(group), Signal::SIGKILL);
    child.wait().await.unwrap();
    agent.process_registry.lock().unwrap().groups.remove(&group);
}

#[tokio::test]
async fn a_turn_start_behind_a_full_unread_input_queue_is_refused_before_it_opens() {
    let (tx, _events) = mpsc::channel(32);
    let (_home, agent) = isolated_agent(tx);
    let thread = "claude_a";
    let (input, group, mut child) = install_unread_runtime(&agent, thread, None).await;
    let blocking =
        InputWriter::prepare_input(&ClaudeUserInput::text("a".repeat(1024 * 1024))).unwrap();
    let _blocked = input.reserve().await.unwrap().send_input(blocking);
    let mut queued = Vec::new();
    while let Ok(Ok(slot)) = tokio::time::timeout(Duration::from_millis(100), input.reserve()).await
    {
        queued.push(
            slot.send_input(InputWriter::prepare_input(&ClaudeUserInput::text("queued")).unwrap()),
        );
    }
    let error = tokio::time::timeout(
        Duration::from_secs(3),
        agent.start_turn(request(thread, false)),
    )
    .await
    .expect("a full queue is answered after its stall limit")
    .expect_err("a prompt that cannot be queued is refused");
    assert_eq!(
        crate::rpc::error::RpcError::from(error).kind(),
        Some("providerUnresponsive")
    );
    assert_eq!(
        agent.active_turn_id(thread).await,
        None,
        "no turn opens without its prompt"
    );
    assert!(
        group_exists(Pid::from_raw(group)),
        "a stall never kills Claude"
    );
    signal_group(Pid::from_raw(group), Signal::SIGKILL);
    child.wait().await.unwrap();
    agent.process_registry.lock().unwrap().groups.remove(&group);
}

#[tokio::test]
async fn input_stop_unanswered_settings_control_cannot_delay_the_exact_process_kill() {
    let (tx, _events) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let thread = "claude_a";
    let (mut runtime, mut child) = placeholder_runtime(&request(thread, false)).await;
    let group = runtime.process_group_id;
    runtime.active_turn = Some(wake_turn("existing-turn"));
    agent.process_registry.lock().unwrap().groups.insert(group);
    agent.runtimes.lock().await.insert(thread.into(), runtime);
    let control = tokio::spawn({
        let agent = Arc::clone(&agent);
        async move {
            agent
                .update_settings(thread, &selection("sonnet", Some("high")))
                .await
        }
    });
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if agent
                .runtimes
                .lock()
                .await
                .get(thread)
                .unwrap()
                .pending_controls
                .len()
                == 1
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let reaper = tokio::spawn({
        let agent = Arc::clone(&agent);
        async move {
            let result = child.wait().await;
            agent.process_registry.lock().unwrap().groups.remove(&group);
            result
        }
    });
    let started = tokio::time::Instant::now();
    let stopped = tokio::time::timeout(
        Duration::from_secs(6),
        agent.interrupt(thread, "existing-turn", async || Ok(Vec::new())),
    )
    .await;
    let stopped_in = started.elapsed();
    let killed_by_stop = !group_exists(Pid::from_raw(group));
    signal_group(Pid::from_raw(group), Signal::SIGKILL);
    reaper.await.unwrap().unwrap();
    if stopped.is_err() {
        agent.fail_runtime(thread, group, "interrupted", None).await;
    }
    let control = tokio::time::timeout(Duration::from_secs(3), control)
        .await
        .unwrap()
        .unwrap();
    assert!(
        stopped.is_ok(),
        "Stop waited behind the thirty-second control exchange"
    );
    stopped.unwrap().unwrap();
    assert!(stopped_in < Duration::from_secs(6));
    assert!(
        killed_by_stop,
        "the Stop path must kill the process before test cleanup"
    );
    assert!(!group_exists(Pid::from_raw(group)));
    assert!(control.is_err());
    assert!(!agent.has_runtime(thread).await);
    assert!(
        agent
            .conversation_index
            .parent(thread)
            .await
            .unwrap()
            .stopped
    );
}

#[tokio::test]
async fn input_control_capacity_refusal_preserves_the_active_process_turn_and_settings() {
    let (tx, mut events) = mpsc::channel(16);
    let (_home, agent) = isolated_agent(tx);
    let thread = "claude_a";
    let (mut runtime, mut child) = placeholder_runtime(&request(thread, false)).await;
    let group = runtime.process_group_id;
    let settings = runtime.settings.clone().unwrap();
    runtime.active_turn = Some(wake_turn("existing-turn"));
    agent.runtimes.lock().await.insert(thread.into(), runtime);
    let reaper = tokio::spawn(async move { child.wait().await });
    let result = agent
        .update_settings(
            thread,
            &selection(&"\0".repeat(6 * 1024 * 1024), Some("high")),
        )
        .await;
    let preserved = {
        let runtimes = agent.runtimes.lock().await;
        runtimes.get(thread).map(|runtime| {
            (
                runtime.process_group_id,
                runtime
                    .running_turn()
                    .unwrap()
                    .translator
                    .turn_id()
                    .to_owned(),
                runtime
                    .settings
                    .as_ref()
                    .map(|settings| (settings.observed.clone(), settings.selection.clone())),
                runtime.pending_controls.len(),
                runtime.input.unconsumed().pending().len(),
            )
        })
    };
    let alive = group_exists(Pid::from_raw(group));
    let emitted = events.try_recv();
    agent.stop_all().await;
    reaper.await.unwrap().unwrap();
    assert_eq!(
        preserved,
        Some((
            group,
            "existing-turn".into(),
            Some((settings.observed, settings.selection)),
            0,
            0
        ))
    );
    assert!(alive);
    assert!(emitted.is_err());
    let error = result.unwrap_err();
    assert_eq!(error.code, RpcCode::Capacity);
    let rpc = crate::rpc::error::RpcError::from(error);
    assert_eq!(
        rpc.response(&json!(1))["error"]["data"],
        json!({"kind":"capacity", "retryable":false, "resource":"input frame bytes", "limit":crate::providers::codex::daemon::MAX_WEBSOCKET_BYTES})
    );
}
