use super::{ClaudeSupervisor, PROCESS_POLL_INTERVAL, group_exists};
use crate::providers::claude::restart::{PausedTask, TaskKind};
use nix::unistd::Pid;
use serde_json::Value;
use std::time::Duration;

const REAP_WAIT: Duration = Duration::from_secs(5);
const MAX_LABEL_CHARS: usize = 160;

#[derive(Clone, Debug, PartialEq)]
pub(super) struct BackgroundTask {
    id: String,
    task_type: String,
    description: String,
    ambient: bool,
}

impl BackgroundTask {
    pub(super) fn id(&self) -> &str {
        &self.id
    }

    pub(super) fn paused(&self) -> Option<PausedTask> {
        let label = self.description.trim();
        (!self.ambient).then(|| PausedTask {
            id: self.id.clone(),
            kind: if self.task_type == "local_agent" {
                TaskKind::Agent
            } else {
                TaskKind::Command
            },
            label: if label.is_empty() {
                "background task"
            } else {
                label
            }
            .chars()
            .take(MAX_LABEL_CHARS)
            .collect(),
        })
    }
}

pub(super) fn background_tasks(value: &Value) -> Option<Vec<BackgroundTask>> {
    value
        .get("tasks")?
        .as_array()?
        .iter()
        .map(|task| {
            let text = |key: &str| {
                task.get(key)
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned()
            };
            Some(BackgroundTask {
                id: task.get("task_id").and_then(Value::as_str)?.to_owned(),
                task_type: text("task_type"),
                description: text("description"),
                ambient: task.get("ambient").and_then(Value::as_bool) == Some(true),
            })
        })
        .collect()
}

impl ClaudeSupervisor {
    pub(crate) async fn suspend(&self, thread_id: &str) -> bool {
        let Some(group) = self
            .runtimes
            .lock()
            .await
            .get(thread_id)
            .map(|runtime| runtime.process_group_id)
        else {
            return true;
        };
        let mut admission =
            super::ProcessAdmission::new(group, std::sync::Arc::clone(&self.process_registry));
        let Some((runtime, stopped_turn)) = self
            .take_runtime_recording_turn(thread_id, Some(group), "interrupted", None)
            .await
        else {
            admission.accept();
            return true;
        };
        self.terminate_group(Pid::from_raw(group)).await;
        let reaped = tokio::time::timeout(REAP_WAIT, async {
            while self
                .process_registry
                .lock()
                .expect("Claude process registry poisoned")
                .groups
                .contains(&group)
            {
                tokio::time::sleep(PROCESS_POLL_INTERVAL).await;
            }
        })
        .await
        .is_ok();
        self.retire_stopped_runtime(thread_id, group, runtime, "suspended", stopped_turn)
            .await;
        admission.accept();
        reaped && !group_exists(Pid::from_raw(group))
    }
}

#[cfg(test)]
pub(crate) mod suspend_test_support {
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::time::Duration;

    use serde_json::Value;
    use tokio::sync::mpsc;

    use crate::agents::mcp::McpTokens;
    use crate::observability::journal::Journal;
    use crate::providers::claude::settings::ClaudeSettings;
    use crate::providers::claude::{
        ClaudeSelection, ClaudeSupervisor, ClaudeTurnRequest, ClaudeUserInput,
    };

    pub(crate) const SESSION: &str = "11111111-2222-4333-8444-555555555555";
    pub(crate) const THREAD: &str = "claude_11111111-2222-4333-8444-555555555555";

    pub(crate) async fn nothing_suspended()
    -> anyhow::Result<Vec<crate::providers::claude::restart::SuspendedTurn>> {
        Ok(Vec::new())
    }

    pub(crate) struct SuspendStub {
        root: crate::providers::claude::settings::ClaudeTestSettings,
        pub cwd: String,
        state: PathBuf,
        executable: PathBuf,
    }

    impl SuspendStub {
        pub fn new() -> Self {
            let root = ClaudeSettings::isolated_for_test();
            let cwd = root.root_path().join("work");
            let state = root.root_path().join("state");
            std::fs::create_dir_all(&cwd).unwrap();
            std::fs::create_dir_all(&state).unwrap();
            let cwd = cwd.to_string_lossy().into_owned();
            let stub = root.root_path().join("claude-stub");
            crate::test_support::write_claude_cli_stub(
                &stub,
                crate::test_support::ClaudeCliMode::SuspendLogsInterrupt,
            );
            let executable = root.root_path().join("claude");
            std::fs::write(
                &executable,
                format!(
                    "#!/bin/sh\nRC_TEST_STATE_DIR='{}' RC_TEST_CWD='{}' exec '{}' \"$@\"\n",
                    state.display(),
                    cwd,
                    stub.display()
                ),
            )
            .unwrap();
            std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
            Self {
                root,
                cwd,
                state,
                executable,
            }
        }

        pub(crate) fn home(&self, name: &str) -> PathBuf {
            let home = self.root.root_path().join(name);
            std::fs::create_dir_all(&home).unwrap();
            home
        }

        pub(crate) fn settings(&self, home: &Path) -> ClaudeSettings {
            ClaudeSettings {
                enabled: true,
                claude_path: self.executable.clone(),
                claude_home: home.to_path_buf(),
                config_dir: Some(home.to_path_buf()),
                mcp_endpoint: "http://127.0.0.1:8787/mcp".to_owned(),
                mcp_config_dir: self.root.root_path().join("mcp"),
                ..self.root.settings.clone()
            }
        }

        pub(crate) fn agent(
            &self,
            home: &Path,
        ) -> (
            Arc<ClaudeSupervisor>,
            mpsc::Receiver<crate::providers::claude::ClaudeNotification>,
        ) {
            let (sender, events) = mpsc::channel(1024);
            let agent = ClaudeSupervisor::new(
                self.settings(home),
                sender,
                Journal::disabled(),
                McpTokens::default(),
            );
            (agent, events)
        }

        pub(crate) fn history(&self, home: &Path) -> PathBuf {
            crate::providers::claude::timeline::session_path_for_cwd(home, &self.cwd, SESSION)
        }

        pub(crate) fn write_history(&self, home: &Path, contents: &str) {
            let path = self.history(home);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, contents).unwrap();
        }

        pub(crate) fn turn(&self, text: &str) -> ClaudeTurnRequest {
            ClaudeTurnRequest {
                thread_id: THREAD.to_owned(),
                session_uuid: SESSION.to_owned(),
                first_turn: false,
                input: ClaudeUserInput::text(text),
                selection: ClaudeSelection {
                    model: "sonnet".to_owned(),
                    effort: None,
                    fast: false,
                },
                cwd: self.cwd.clone(),
            }
        }

        pub(crate) fn controls(&self) -> Vec<Value> {
            std::fs::read_to_string(self.state.join("controls.jsonl"))
                .unwrap_or_default()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect()
        }
    }

    pub(crate) async fn completion(
        events: &mut mpsc::Receiver<crate::providers::claude::ClaudeNotification>,
    ) -> Value {
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let event = crate::test_support::claude_event(events.recv().await.unwrap());
                if event["method"] == "turn/completed" {
                    return event;
                }
            }
        })
        .await
        .expect("the turn never completed")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::claude::ClaudeUserInput;
    use crate::providers::claude::restart::ScheduledWake;
    use crate::providers::claude::restart::{Cause, PausedTask, TaskKind};
    use crate::providers::claude::supervisor::restart_capture::ResumeDelivery;
    use serde_json::json;
    use std::fs;

    async fn background_work(agent: &ClaudeSupervisor) {
        tokio::time::timeout(Duration::from_secs(10), async {
            while agent
                .runtimes
                .lock()
                .await
                .get(suspend_test_support::THREAD)
                .is_none_or(|runtime| runtime.background_tasks.is_empty())
            {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn a_restart_captures_running_work_before_suspending_without_a_cli_interrupt() {
        let stub = suspend_test_support::SuspendStub::new();
        let home = stub.home("default");
        stub.write_history(&home, "{\"type\":\"user\",\"message\":\"existing\"}\n");
        let (agent, mut events) = stub.agent(&home);
        agent
            .start_turn(stub.turn("start background work and hold"))
            .await
            .unwrap();
        background_work(&agent).await;
        let turn = agent
            .active_turn_id(suspend_test_support::THREAD)
            .await
            .unwrap();
        let history = stub.history(&home);

        let item = agent.capture().await.pop().unwrap();
        assert!(agent.has_runtime(suspend_test_support::THREAD).await);
        assert!(!fs::read_to_string(&history).unwrap().contains("\"exit\""));
        let exited = agent.suspend(suspend_test_support::THREAD).await;

        assert!(exited);
        assert_eq!(item.cause, Cause::Restart);
        assert_eq!(item.interrupted_turn_id.as_deref(), Some(turn.as_str()));
        assert_eq!(
            item.background_tasks,
            [
                PausedTask {
                    id: "agent-task".to_owned(),
                    kind: TaskKind::Agent,
                    label: "Review the diff".to_owned(),
                },
                PausedTask {
                    id: "shell-task".to_owned(),
                    kind: TaskKind::Command,
                    label: "npm run dev".to_owned(),
                },
            ]
        );
        assert!(stub.controls().is_empty(), "{:?}", stub.controls());
        let completion = suspend_test_support::completion(&mut events).await;
        assert_eq!(completion["params"]["turn"]["status"], "interrupted");
        assert!(!agent.has_runtime(suspend_test_support::THREAD).await);
        assert!(agent.process_registry.lock().unwrap().groups.is_empty());
        let history = fs::read_to_string(history).unwrap();
        let last: Value = serde_json::from_str(history.lines().last().unwrap()).unwrap();
        assert_eq!(
            last["subtype"], "exit",
            "the process exited through SIGTERM"
        );
        let children =
            crate::agents::claude::store::load(&home, suspend_test_support::THREAD).unwrap();
        assert_eq!(
            children.children["agent-task"].state,
            crate::agents::State::Unknown,
            "a paused agent is not reported as stopped"
        );
    }

    #[tokio::test]
    async fn an_idle_runtime_holding_a_loop_and_a_cron_is_captured_to_resume_them() {
        let stub = suspend_test_support::SuspendStub::new();
        let home = stub.home("default");
        stub.write_history(&home, "{\"type\":\"user\",\"message\":\"existing\"}\n");
        let (agent, mut events) = stub.agent(&home);
        agent
            .start_turn(stub.turn("schedule a wakeup and create a cron"))
            .await
            .unwrap();
        suspend_test_support::completion(&mut events).await;

        let item = agent.capture().await.pop().unwrap();
        let exited = agent.suspend(suspend_test_support::THREAD).await;

        assert!(exited);
        assert!(item.interrupted_turn_id.is_none() && item.background_tasks.is_empty());
        assert!(matches!(
            item.scheduled_wakes.as_slice(),
            [
                ScheduledWake::Loop { next_wake_unix_ms: Some(_) },
                ScheduledWake::Cron { schedule },
            ] if schedule == "Every 10 minutes"
        ));
        let notice = item.notice();
        assert!(notice.contains("call ScheduleWakeup again"), "{notice}");
        assert!(notice.contains("Every 10 minutes"), "{notice}");
    }

    #[tokio::test]
    async fn an_idle_runtime_without_background_work_is_released_with_nothing_to_resume() {
        let stub = suspend_test_support::SuspendStub::new();
        let home = stub.home("default");
        stub.write_history(&home, "{\"type\":\"user\",\"message\":\"existing\"}\n");
        let (agent, mut events) = stub.agent(&home);
        agent.start_turn(stub.turn("hello")).await.unwrap();
        suspend_test_support::completion(&mut events).await;

        let item = agent.capture().await.pop();
        let exited = agent.suspend(suspend_test_support::THREAD).await;

        assert!(item.is_none() && exited);
        assert!(!agent.has_runtime(suspend_test_support::THREAD).await);
        assert!(agent.suspend(suspend_test_support::THREAD).await);
    }

    #[tokio::test]
    async fn a_notice_the_process_never_read_folds_into_the_next_capture() {
        let stub = suspend_test_support::SuspendStub::new();
        let home = stub.home("default");
        stub.write_history(&home, "{\"type\":\"user\",\"message\":\"existing\"}\n");
        let (agent, mut events) = stub.agent(&home);
        agent
            .start_turn(stub.turn("start background work and hold"))
            .await
            .unwrap();
        background_work(&agent).await;
        let mut earlier = agent.capture().await.pop().unwrap();
        assert!(agent.suspend(suspend_test_support::THREAD).await);
        earlier.queued_inputs = vec![ClaudeUserInput {
            client_id: Some("queued-steer".to_owned()),
            ..ClaudeUserInput::text("also update the changelog")
        }];
        agent
            .start_turn(stub.turn("stall on a long step"))
            .await
            .unwrap();
        let history = stub.history(&home);
        tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                let event =
                    crate::test_support::claude_event(events.recv().await.expect("CLI user echo"));
                if event["method"] == "item/completed"
                    && event["params"]["item"]["type"] == "userMessage"
                    && event["params"]["item"]["content"][0]["text"] == "stall on a long step"
                {
                    break;
                }
            }
        })
        .await
        .expect("the supervisor consumes the running input before the notice is queued");
        assert!(matches!(
            agent.resume_with_notice(&earlier).await.unwrap(),
            ResumeDelivery::Steered(_)
        ));

        let latest = agent.capture().await.pop().unwrap();
        assert!(agent.suspend(suspend_test_support::THREAD).await);
        let notice = latest.notice();

        assert_eq!(latest.earlier_events.len(), 1);
        assert_eq!(
            latest
                .queued_inputs
                .iter()
                .map(|input| input.client_id.as_deref())
                .collect::<Vec<_>>(),
            [Some("queued-steer")]
        );
        assert_eq!(notice.matches("gateway restarted").count(), 2, "{notice}");
        assert!(notice.contains("agent-task (Review the diff)"), "{notice}");
        assert!(
            !fs::read_to_string(&history)
                .unwrap()
                .contains(&earlier.recovery_id)
        );
    }

    #[test]
    fn ambient_tasks_are_not_listed_and_blank_labels_are_named() {
        let tasks = background_tasks(&json!({"tasks": [
            {"task_id": "agent", "task_type": "local_agent", "description": "  "},
            {"task_id": "remote", "task_type": "monitor_ws", "description": "Socket"},
            {"task_id": "memory", "task_type": "local_agent", "description": "memory", "ambient": true},
        ]}))
        .unwrap();

        let paused = tasks
            .iter()
            .filter_map(BackgroundTask::paused)
            .map(|task| (task.kind, task.label))
            .collect::<Vec<_>>();

        assert_eq!(
            paused,
            [
                (TaskKind::Agent, "background task".to_owned()),
                (TaskKind::Command, "Socket".to_owned()),
            ]
        );
    }
}
