use super::{ClaudeSupervisor, TurnOrigin, TurnStartError};
use crate::providers::claude::conversation_index::{Delivery, ParentSelection};
use crate::providers::claude::{
    ClaudeSelection, ClaudeTurnRequest, ClaudeUserInput, session_uuid_from_thread_id,
};
use crate::rpc::error::RpcCode;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::sync::Arc;
use tracing::error;

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ParentMessage {
    pub thread_id: String,
    pub delivery_id: String,
    pub text: String,
}

impl ClaudeSupervisor {
    pub(super) async fn remember_parent(
        &self,
        request: &ClaudeTurnRequest,
        origin: TurnOrigin,
        stop_generation: u64,
    ) {
        let selection = ParentSelection {
            cwd: request.cwd.clone(),
            model: request.selection.model.clone(),
            effort: request.selection.effort.clone(),
            fast: request.selection.fast,
        };
        let user_turn = matches!(origin, TurnOrigin::Dispatched);
        self.update_parent(&request.thread_id, move |parent| {
            if parent.stop_generation != stop_generation {
                return;
            }
            parent.selection = Some(selection);
            if user_turn {
                parent.stopped = false;
            }
        })
        .await;
    }

    pub(super) async fn remember_parent_settings(
        &self,
        thread_id: &str,
        selection: &ClaudeSelection,
    ) {
        let ClaudeSelection {
            model,
            effort,
            fast,
        } = selection.clone();
        self.update_parent(thread_id, move |parent| {
            if let Some(selection) = parent.selection.as_mut() {
                selection.model = model;
                selection.effort = effort;
                selection.fast = fast;
            }
        })
        .await;
    }

    pub(crate) async fn stop_parent(&self, thread_id: &str) -> anyhow::Result<()> {
        self.conversation_index
            .update_parent(thread_id, |parent| {
                parent.stopped = true;
                parent.stop_generation += 1;
            })
            .await
    }

    pub(crate) async fn stop_generation(&self, thread_id: &str) -> anyhow::Result<u64> {
        Ok(self
            .conversation_index
            .parent(thread_id)
            .await?
            .stop_generation)
    }

    pub(super) async fn parent_selection(&self, thread_id: &str) -> Option<ClaudeSelection> {
        self.conversation_index
            .parent(thread_id)
            .await
            .ok()?
            .selection
            .map(ParentSelection::selection)
    }

    pub(crate) async fn fast_mode(&self, thread_id: &str, model: &str) -> bool {
        self.parent_selection(thread_id)
            .await
            .is_some_and(|selection| {
                selection.fast && super::claude_model_matches(&selection.model, model)
            })
    }

    async fn update_parent(
        &self,
        thread_id: &str,
        update: impl FnOnce(&mut crate::providers::claude::conversation_index::Parent) + Send + 'static,
    ) {
        if let Err(error) = self
            .conversation_index
            .update_parent(thread_id, update)
            .await
        {
            error!(%thread_id, error = %format!("{error:#}"), "Claude parent record was not saved");
        }
    }

    pub(crate) async fn deliver_parent_message(
        self: &Arc<Self>,
        message: ParentMessage,
    ) -> Result<Value, TurnStartError> {
        if message.delivery_id.is_empty()
            || message.delivery_id.len() > 256
            || message.text.trim().is_empty()
            || message.text.len() > 1_048_576
        {
            return Err(rejected(
                "A delivery id (1–256 bytes) and nonempty message (at most 1 MiB) are required",
            ));
        }
        let session_uuid = session_uuid_from_thread_id(&message.thread_id)
            .ok_or_else(|| rejected("Claude parent thread id is invalid"))?
            .to_owned();
        let fingerprint = format!("{:x}", Sha256::digest(message.text.as_bytes()));
        let _lifecycle = self.lifecycles.lock(&message.thread_id).await;
        let parent = self
            .conversation_index
            .parent(&message.thread_id)
            .await
            .map_err(|error| {
                rejected(&format!(
                    "Claude parent record could not be read: {error:#}"
                ))
            })?;
        if parent.stopped {
            return Err(rejected(
                "Claude parent was interrupted by the user, so this message will not wake it",
            ));
        }
        if let Some(delivery) = parent.delivery(&message.delivery_id) {
            if delivery.fingerprint != fingerprint {
                return Err(rejected(
                    "Delivery id was already used for a different message or sender",
                ));
            }
            let mut receipt = delivery.receipt.clone();
            receipt["duplicate"] = json!(true);
            return Ok(receipt);
        }
        let selection = parent.selection.ok_or_else(|| {
            rejected("Claude parent has not run a turn through this gateway, so this message cannot wake it")
        })?;
        let request = ClaudeTurnRequest {
            thread_id: message.thread_id.clone(),
            session_uuid,
            first_turn: false,
            input: ClaudeUserInput {
                client_id: Some(delivery_uuid(&message.thread_id, &message.delivery_id)),
                is_synthetic: true,
                ..ClaudeUserInput::text(message.text)
            },
            cwd: selection.cwd.clone(),
            selection: selection.selection(),
        };
        let active = {
            let runtimes = self.runtimes.lock().await;
            runtimes.get(&message.thread_id).and_then(|runtime| {
                runtime.running_turn().map(|turn| {
                    (
                        turn.translator.turn_id().to_owned(),
                        runtime.input.clone(),
                        runtime.process_group_id,
                    )
                })
            })
        };
        let (turn_id, delivery) = if let Some((turn_id, input, group)) = active {
            let prepared = super::input_writer::InputWriter::prepare_input(&request.input)
                .map_err(TurnStartError::from)?;
            if let Err(error) = input.send_prepared(prepared).await {
                if super::InputWriter::stall_was_queued(&error) {
                    self.input_stalled(&request.thread_id, group, "claude/message", error);
                } else if super::InputWriter::is_stalled(&error) {
                    return Err(self.input_stalled(
                        &request.thread_id,
                        group,
                        "claude/message",
                        error,
                    ));
                } else {
                    let failure = format!("Failed writing Claude parent message: {error}");
                    self.retire_after_write_failure(&request.thread_id, group, &failure)
                        .await;
                    return Err(TurnStartError {
                        data: None,
                        code: RpcCode::Internal,
                        message: failure,
                    });
                }
            }
            self.ensure_runtime_current(&request.thread_id, group)
                .await?;
            (turn_id, "gateway-steered")
        } else {
            let turn_id = match self.start_turn_locked(request, TurnOrigin::Callback).await {
                Ok(turn_id) => turn_id,
                Err(error) if error.is_queued_stall() => {
                    self.active_turn_id(&message.thread_id).await.ok_or(error)?
                }
                Err(error) => return Err(error),
            };
            (turn_id, "gateway-started")
        };
        let receipt = json!({
            "delivery": delivery,
            "delivery_id": message.delivery_id,
            "delivery_confirmed": false,
            "parent": "claude",
            "thread_id": message.thread_id,
            "turn_id": turn_id,
        });
        let recorded = Delivery {
            id: message.delivery_id,
            fingerprint,
            receipt: receipt.clone(),
        };
        self.conversation_index
            .update_parent(&message.thread_id, move |parent| {
                parent.record_delivery(recorded)
            })
            .await
            .map_err(|error| TurnStartError {
                data: None,
                code: RpcCode::Internal,
                message: format!(
                    "Claude parent message was delivered, but its delivery record could not be saved; do not resend it: {error:#}"
                ),
            })?;
        Ok(receipt)
    }
}

fn delivery_uuid(thread_id: &str, delivery_id: &str) -> String {
    let digest = Sha256::new()
        .chain_update(b"remotecoder-claude-message\0")
        .chain_update(thread_id.as_bytes())
        .chain_update(b"\0")
        .chain_update(delivery_id.as_bytes())
        .finalize();
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x80;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex = bytes
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    )
}

fn rejected(message: &str) -> TurnStartError {
    TurnStartError {
        data: None,
        code: RpcCode::InvalidParams,
        message: message.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::super::suspend::suspend_test_support::nothing_suspended;
    use super::*;
    use crate::agents::mcp::McpTokens;
    use crate::ids::is_session_uuid;
    use crate::observability::journal::Journal;
    use crate::providers::claude::settings::ClaudeSettings;
    use crate::providers::claude::supervisor::{
        RUNTIME_IDLE_TIMEOUT, TurnControlError, signal_group,
    };
    use nix::sys::signal::Signal;
    use nix::unistd::Pid;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::time::Duration;
    use tokio::sync::mpsc;

    const SESSION: &str = "11111111-2222-4333-8444-555555555555";
    const THREAD: &str = "claude_11111111-2222-4333-8444-555555555555";

    struct Fixture {
        root: crate::providers::claude::settings::ClaudeTestSettings,
        agent: Arc<ClaudeSupervisor>,
        events: mpsc::Receiver<crate::providers::claude::ClaudeNotification>,
        history: PathBuf,
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            for group in &self.agent.process_registry.lock().unwrap().groups {
                signal_group(Pid::from_raw(*group), Signal::SIGKILL);
            }
        }
    }

    impl Fixture {
        fn new() -> Self {
            let root = ClaudeSettings::isolated_for_test();
            let executable = root.root_path().join("claude-stub");
            let history = crate::providers::claude::timeline::session_path_for_cwd(
                root.root_path(),
                &root.root_path().to_string_lossy(),
                SESSION,
            );
            crate::test_support::write_claude_cli_stub(
                &executable,
                crate::test_support::ClaudeCliMode::MessagesAcknowledgeInterrupt(history.clone()),
            );
            fs::create_dir_all(history.parent().unwrap()).unwrap();
            fs::write(
                &history,
                "{\"type\":\"user\",\"message\":\"existing history\"}\n",
            )
            .unwrap();
            let (agent, events) = Self::agent(&root);
            Self {
                root,
                agent,
                events,
                history,
            }
        }

        fn agent(
            test: &crate::providers::claude::settings::ClaudeTestSettings,
        ) -> (
            Arc<ClaudeSupervisor>,
            mpsc::Receiver<crate::providers::claude::ClaudeNotification>,
        ) {
            let root = test.root_path();
            let (sender, events) = mpsc::channel(128);
            let agent = ClaudeSupervisor::new(
                ClaudeSettings {
                    claude_path: root.join("claude-stub"),
                    claude_home: root.to_owned(),
                    config_dir: Some(root.to_owned()),
                    mcp_endpoint: "http://127.0.0.1:8787/mcp".to_owned(),
                    mcp_config_dir: root.join("mcp"),

                    default_model: "sonnet".to_owned(),
                    ..test.settings.clone()
                },
                sender,
                Journal::disabled(),
                McpTokens::default(),
            );
            (agent, events)
        }

        fn request(&self, text: &str, model: &str, effort: &str) -> ClaudeTurnRequest {
            ClaudeTurnRequest {
                thread_id: THREAD.to_owned(),
                session_uuid: SESSION.to_owned(),
                first_turn: false,
                input: ClaudeUserInput::text(text),
                selection: ClaudeSelection {
                    model: model.to_owned(),
                    effort: Some(effort.to_owned()),
                    fast: false,
                },
                cwd: self.root.root_path().to_string_lossy().into_owned(),
            }
        }

        async fn initial_turn(&mut self) {
            self.initial_turn_with("sonnet", "high").await;
        }

        async fn initial_turn_with(&mut self, model: &str, effort: &str) {
            self.agent
                .start_turn(self.request("initial", model, effort))
                .await
                .unwrap();
            tokio::time::timeout(Duration::from_secs(5), async {
                loop {
                    let event =
                        crate::test_support::claude_event(self.events.recv().await.unwrap());
                    if event["method"] == "turn/completed" {
                        assert_eq!(event["params"]["turn"]["status"], "completed", "{event}");
                        break;
                    }
                }
                loop {
                    if self.agent.runtimes.lock().await[THREAD].idle.is_some() {
                        break;
                    }
                    tokio::task::yield_now().await;
                }
            })
            .await
            .unwrap();
        }

        async fn expire(&self) {
            tokio::time::pause();
            tokio::time::advance(RUNTIME_IDLE_TIMEOUT + Duration::from_secs(1)).await;
            tokio::time::resume();
            tokio::time::timeout(Duration::from_secs(5), async {
                while self.agent.has_runtime(THREAD).await {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .unwrap();
        }

        async fn received(&self, count: usize) -> Vec<Value> {
            tokio::time::timeout(Duration::from_secs(5), async {
                loop {
                    let values: Vec<Value> =
                        fs::read_to_string(self.root.root_path().join("received.jsonl"))
                            .unwrap_or_default()
                            .lines()
                            .filter_map(|line| serde_json::from_str(line).ok())
                            .collect();
                    if values.len() >= count {
                        return values;
                    }
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            })
            .await
            .unwrap()
        }

        fn launches(&self) -> Vec<Value> {
            self.log("launches.jsonl")
        }

        fn controls(&self) -> Vec<Value> {
            self.log("controls.jsonl")
        }

        fn log(&self, name: &str) -> Vec<Value> {
            fs::read_to_string(self.root.root_path().join(name))
                .unwrap_or_default()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect()
        }
    }

    fn message(id: &str, text: &str) -> ParentMessage {
        ParentMessage {
            thread_id: THREAD.to_owned(),
            delivery_id: id.to_owned(),
            text: text.to_owned(),
        }
    }

    #[tokio::test]
    async fn fast_mode_carries_over_only_to_the_same_model() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        fixture.expire().await;
        fixture
            .agent
            .update_settings(
                THREAD,
                &ClaudeSelection {
                    model: "opus".to_owned(),
                    effort: Some("low".to_owned()),
                    fast: true,
                },
            )
            .await
            .unwrap();
        let same_model = fixture.agent.fast_mode(THREAD, "claude-opus-5-5").await;
        let other_model = fixture.agent.fast_mode(THREAD, "sonnet").await;
        fixture.agent.stop_all().await;
        assert!(same_model);
        assert!(!other_model);
    }

    #[tokio::test]
    async fn expired_parent_resumes_exact_history_and_latest_settings() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        fixture.expire().await;
        fixture
            .agent
            .update_settings(
                THREAD,
                &ClaudeSelection {
                    model: "opus".to_owned(),
                    effort: Some("low".to_owned()),
                    fast: true,
                },
            )
            .await
            .unwrap();
        let receipt = fixture
            .agent
            .deliver_parent_message(message("completion-one", "completed work"))
            .await
            .unwrap();
        let received = fixture.received(2).await;
        let launches = fixture.launches();
        fixture.agent.stop_all().await;
        assert_eq!(receipt["delivery"], "gateway-started");
        assert_eq!(receipt["delivery_confirmed"], false);
        assert_eq!(launches.len(), 2);
        let args = launches[1]["argv"].as_array().unwrap();
        assert!(
            args.windows(2)
                .any(|pair| pair == [json!("--resume"), json!(SESSION)])
        );
        assert!(!args.contains(&json!("--session-id")));
        assert!(
            args.windows(2)
                .any(|pair| pair == [json!("--model"), json!("opus")])
        );
        assert!(
            args.windows(2)
                .any(|pair| pair == [json!("--effort"), json!("low")])
        );
        assert_eq!(launches[0]["fastMode"], false);
        assert_eq!(launches[1]["fastMode"], true);
        assert_eq!(launches[1]["cwd"], launches[0]["cwd"]);
        assert!(launches[1]["context"].get("account").is_none());
        assert_eq!(received[1]["message"]["content"], "completed work");
        assert_eq!(received[1]["isSynthetic"], true);
    }

    #[tokio::test]
    async fn side_question_answers_from_the_idle_runtime_without_opening_a_turn() {
        let mut fixture = Fixture::new();
        assert_eq!(
            fixture.agent.side_question(THREAD, "title?").await,
            Ok(None)
        );
        fixture.initial_turn().await;
        let answer = fixture.agent.side_question(THREAD, "title?").await;
        let controls = fixture.controls();
        fixture.agent.stop_all().await;
        assert_eq!(answer, Ok(Some("Answer to title?".to_owned())));
        assert_eq!(
            controls.last(),
            Some(&json!({"subtype":"side_question","question":"title?"}))
        );
        while let Ok(event) = fixture.events.try_recv() {
            let event = crate::test_support::claude_event(event);
            assert_ne!(event["method"], "turn/started", "{event}");
        }
    }

    #[tokio::test]
    async fn side_question_answers_during_a_running_turn_without_ending_it() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        fixture
            .agent
            .start_turn(fixture.request("keep working", "sonnet", "high"))
            .await
            .unwrap();
        let answer = fixture.agent.side_question(THREAD, "title?").await;
        let running = fixture.agent.runtimes.lock().await[THREAD]
            .active_turn
            .is_some();
        fixture.agent.stop_all().await;
        assert_eq!(answer, Ok(Some("Answer to title?".to_owned())));
        assert!(running, "the side question ended the running turn");
    }

    #[tokio::test]
    async fn a_cancelled_detached_side_question_kills_its_whole_process_group() {
        let fixture = Fixture::new();
        let cwd = fixture.root.root_path().to_string_lossy().into_owned();
        let agent = Arc::clone(&fixture.agent);
        let question =
            tokio::spawn(async move { agent.detached_side_question(THREAD, &cwd, "hang").await });
        let pid_file = fixture.root.root_path().join("detached-child.pid");
        let child = tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                if let Some(pid) = fs::read_to_string(&pid_file)
                    .ok()
                    .and_then(|pid| pid.trim().parse::<i32>().ok())
                {
                    return Pid::from_raw(pid);
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        question.abort();
        assert!(question.await.unwrap_err().is_cancelled());
        let reaped = tokio::time::timeout(Duration::from_secs(10), async {
            while nix::sys::signal::kill(child, None).is_ok()
                || !fixture
                    .agent
                    .process_registry
                    .lock()
                    .unwrap()
                    .groups
                    .is_empty()
            {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await;
        assert!(
            reaped.is_ok(),
            "the hook-like grandchild outlived its side question"
        );
    }

    #[tokio::test]
    async fn detached_side_question_output_is_bounded() {
        let fixture = Fixture::new();
        let cwd = fixture.root.root_path().to_string_lossy().into_owned();
        let answer = fixture
            .agent
            .detached_side_question(THREAD, &cwd, "flood")
            .await;
        assert_eq!(
            answer,
            Err("Claude side question output exceeded 1 MiB".to_owned())
        );
    }

    #[tokio::test]
    async fn an_unanswered_side_question_is_cancelled_at_the_control_deadline() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        tokio::time::pause();
        let answer = fixture.agent.side_question(THREAD, "unanswered").await;
        tokio::time::resume();
        assert!(answer.is_err());
        let cancelled = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let controls = fixture.controls();
                if let Some(cancel) = controls
                    .iter()
                    .find(|control| control["type"] == "control_cancel_request")
                {
                    return (controls[controls.len() - 2].clone(), cancel.clone());
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        fixture.agent.stop_all().await;
        assert_eq!(
            cancelled.0,
            json!({"subtype":"side_question","question":"unanswered"})
        );
        assert!(
            cancelled.1["request_id"]
                .as_str()
                .is_some_and(|id| !id.is_empty())
        );
    }

    #[tokio::test]
    async fn failed_parent_ledger_write_does_not_acknowledge_delivery() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        let history_dir = fixture.root.root_path().join("remotecoder-history");
        fs::set_permissions(&history_dir, fs::Permissions::from_mode(0o500))
            .expect("make parent ledger unwritable");
        let outcome = fixture
            .agent
            .deliver_parent_message(message("write-failed", "the child finished"))
            .await;
        fs::set_permissions(&history_dir, fs::Permissions::from_mode(0o700))
            .expect("restore parent ledger permissions");
        let error = outcome.expect_err("delivery must not be acknowledged");
        assert_eq!(error.code, RpcCode::Internal);
        let parent = fixture
            .agent
            .conversation_index
            .parent(THREAD)
            .await
            .expect("parent record");
        assert!(parent.delivery("write-failed").is_none());
    }

    #[tokio::test]
    async fn simultaneous_messages_resume_once_then_steer_and_deduplicate() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        fixture.expire().await;
        let (one, two) = tokio::join!(
            fixture
                .agent
                .deliver_parent_message(message("one", "first child")),
            fixture
                .agent
                .deliver_parent_message(message("two", "second child")),
        );
        let (one, two) = (one.unwrap(), two.unwrap());
        let duplicate = fixture
            .agent
            .deliver_parent_message(message("one", "first child"))
            .await
            .unwrap();
        let conflict = fixture
            .agent
            .deliver_parent_message(message("one", "changed sender or message"))
            .await
            .unwrap_err();
        let received = fixture.received(3).await;
        let launches = fixture.launches();
        fixture.agent.stop_all().await;
        assert_eq!(launches.len(), 2);
        assert_eq!(one["turn_id"], two["turn_id"]);
        assert_eq!(one["delivery"], "gateway-started");
        assert_eq!(two["delivery"], "gateway-steered");
        assert_eq!(duplicate["duplicate"], true);
        assert!(conflict.message.contains("different message or sender"));
        assert_eq!(received.len(), 3);
        assert_eq!(received[1]["message"]["content"], "first child");
        assert_eq!(received[2]["message"]["content"], "second child");
    }

    #[tokio::test]
    async fn missing_history_and_interruption_reject_callbacks_without_spawning() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        fixture.expire().await;
        fs::remove_file(&fixture.history).unwrap();
        let missing = fixture
            .agent
            .deliver_parent_message(message("missing", "do not reconstruct"))
            .await
            .unwrap_err();
        fs::write(&fixture.history, "{}\n").unwrap();
        let running = fixture
            .agent
            .start_turn(fixture.request("keep working", "sonnet", "high"))
            .await
            .unwrap();
        fixture
            .agent
            .interrupt(THREAD, &running, nothing_suspended)
            .await
            .unwrap();
        let interrupted = fixture
            .agent
            .deliver_parent_message(message("stopped", "do not wake"))
            .await
            .unwrap_err();
        let launches = fixture.launches();
        fixture.agent.stop_all().await;
        assert!(
            missing.message.contains("is missing from"),
            "{}",
            missing.message
        );
        assert!(interrupted.message.contains("interrupted by the user"));
        assert_eq!(launches.len(), 2);
    }

    #[tokio::test]
    async fn a_restarted_gateway_wakes_the_parent_with_its_recorded_selection_once_per_delivery_id()
    {
        let mut fixture = Fixture::new();
        fixture.initial_turn_with("opus[1m]", "max").await;
        fixture.expire().await;
        let (restarted, _restarted_events) = Fixture::agent(&fixture.root);
        let receipt = restarted
            .deliver_parent_message(message("child-done", "review finished"))
            .await
            .unwrap();
        let received = fixture.received(2).await;
        restarted.stop_all().await;
        let (again, _again_events) = Fixture::agent(&fixture.root);
        let retried = again
            .deliver_parent_message(message("child-done", "review finished"))
            .await
            .unwrap();
        let launches = fixture.launches();
        again.stop_all().await;

        assert_eq!(receipt["delivery"], "gateway-started");
        assert_eq!(retried["duplicate"], true);
        assert_eq!(retried["turn_id"], receipt["turn_id"]);
        assert_eq!(launches.len(), 2);
        let args = launches[1]["argv"].as_array().unwrap();
        for pair in [
            ["--resume", SESSION],
            ["--model", "opus[1m]"],
            ["--effort", "max"],
        ] {
            assert!(
                args.windows(2)
                    .any(|window| window == [json!(pair[0]), json!(pair[1])]),
                "{pair:?} in {args:?}"
            );
        }
        assert_eq!(launches[1]["cwd"], launches[0]["cwd"]);
        assert_eq!(
            received[1]["uuid"],
            json!(delivery_uuid(THREAD, "child-done"))
        );
        assert!(is_session_uuid(received[1]["uuid"].as_str().unwrap()));
        assert_ne!(
            delivery_uuid(THREAD, "child-done"),
            delivery_uuid(THREAD, "child-done-2")
        );
    }

    #[tokio::test]
    async fn a_user_stop_interrupts_the_cli_and_refuses_wakes_across_restarts_until_a_user_turn() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        let running = fixture
            .agent
            .start_turn(fixture.request("keep working", "sonnet", "high"))
            .await
            .unwrap();
        fixture.received(2).await;
        fixture
            .agent
            .interrupt(THREAD, &running, nothing_suspended)
            .await
            .unwrap();
        let controls = fixture.controls();
        assert!(!fixture.agent.has_runtime(THREAD).await);

        let (restarted, mut restarted_events) = Fixture::agent(&fixture.root);
        let after_restart = restarted
            .deliver_parent_message(message("after-restart", "wake up"))
            .await
            .unwrap_err();
        restarted
            .start_turn(fixture.request("continue", "sonnet", "high"))
            .await
            .unwrap();
        let after_user_turn = restarted
            .deliver_parent_message(message("after-user-turn", "child done"))
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                let event = crate::test_support::claude_event(
                    restarted_events.recv().await.expect("restarted CLI event"),
                );
                if event["method"] == "item/completed"
                    && event["params"]["item"]["type"] == "userMessage"
                    && event["params"]["item"]["content"][0]["text"] == "continue"
                {
                    break;
                }
            }
        })
        .await
        .expect("the restarted CLI echoes the user turn after recording its launch");
        let launches = fixture.launches();
        restarted.stop_all().await;

        assert!(
            controls.contains(&json!({"subtype": "interrupt", "cancel_queued": true})),
            "{controls:?}"
        );
        assert!(
            after_restart.message.contains("interrupted by the user"),
            "{}",
            after_restart.message
        );
        assert_eq!(after_user_turn["delivery"], "gateway-steered");
        assert_eq!(launches.len(), 2);
    }

    #[tokio::test]
    async fn a_stop_names_the_running_turn_and_the_next_message_is_one_turn_with_its_reply() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        let running = fixture
            .agent
            .start_turn(fixture.request("keep working", "sonnet", "high"))
            .await
            .unwrap();
        fixture.received(2).await;

        let mismatched = fixture
            .agent
            .interrupt(THREAD, "claude-turn-earlier", nothing_suspended)
            .await
            .unwrap_err();
        let still_running = fixture.agent.active_turn_id(THREAD).await;
        let parent_after_refusal = fixture
            .agent
            .conversation_index
            .parent(THREAD)
            .await
            .unwrap();
        let controls_after_refusal = fixture.controls();
        fixture
            .agent
            .interrupt(THREAD, &running, nothing_suspended)
            .await
            .unwrap();
        let ended = fixture
            .agent
            .interrupt(THREAD, &running, nothing_suspended)
            .await
            .unwrap_err();
        let mut stop_frames = Vec::new();
        while let Ok(frame) = fixture.events.try_recv() {
            let frame = crate::test_support::claude_event(frame);
            stop_frames.push(frame);
        }

        let mut request = fixture.request("reply: after the stop", "sonnet", "high");
        request.input.client_id = Some("after-stop-input".to_owned());
        let next = fixture.agent.start_turn(request).await.unwrap();
        let frames = tokio::time::timeout(Duration::from_secs(5), async {
            let mut frames = Vec::new();
            loop {
                let frame = crate::test_support::claude_event(fixture.events.recv().await.unwrap());
                let completed = frame["method"] == "turn/completed";
                frames.push(frame);
                if completed {
                    return frames;
                }
            }
        })
        .await
        .unwrap();
        fixture.agent.stop_all().await;

        let TurnControlError::Failed(mismatched) = mismatched else {
            panic!("a mismatched turn is a refusal, got {mismatched:?}");
        };
        assert_eq!(mismatched.code, RpcCode::InvalidRequest);
        assert_eq!(
            mismatched.message,
            format!("expected active turn id claude-turn-earlier but found {running}")
        );
        assert_eq!(still_running.as_deref(), Some(running.as_str()));
        assert!(!parent_after_refusal.stopped);
        assert!(
            controls_after_refusal.is_empty(),
            "{controls_after_refusal:?}"
        );
        assert!(
            matches!(&ended, TurnControlError::NotRunning { message } if message == "no active turn to interrupt"),
            "{ended:?}"
        );
        let stopped: Vec<_> = stop_frames
            .iter()
            .filter(|frame| frame["method"] == "turn/completed")
            .map(|frame| &frame["params"]["turn"])
            .collect();
        assert_eq!(stopped.len(), 1, "{stopped:?}");
        assert_eq!(stopped[0]["id"], running);
        assert_eq!(stopped[0]["status"], "interrupted");
        let started: Vec<_> = frames
            .iter()
            .filter(|frame| frame["method"] == "turn/started")
            .map(|frame| frame["params"]["turn"]["id"].clone())
            .collect();
        assert_eq!(started, [json!(next)]);
        let completed = frames.last().unwrap();
        assert_eq!(completed["params"]["turn"]["id"], next);
        assert_eq!(completed["params"]["turn"]["status"], "completed");
        let items: Vec<_> = frames
            .iter()
            .filter(|frame| frame["method"] == "item/completed")
            .map(|frame| {
                assert_eq!(frame["params"]["turnId"], next);
                &frame["params"]["item"]
            })
            .collect();
        assert!(
            items.iter().any(|item| item["type"] == "userMessage"
                && item["clientId"] == "after-stop-input"),
            "{items:?}"
        );
        assert!(
            items
                .iter()
                .any(|item| item["type"] == "agentMessage" && item["text"] == "after the stop"),
            "{items:?}"
        );
    }
}
