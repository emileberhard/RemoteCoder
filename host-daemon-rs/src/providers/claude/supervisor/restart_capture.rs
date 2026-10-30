use super::{
    CAPTURE_CONCURRENCY, ClaudeSupervisor, TurnOrigin, TurnPhase, TurnStartError, suspend,
};
use crate::ids::new_session_uuid;
use crate::providers::claude::restart::{Cause, Item, ItemStatus, ScheduledWake};
use crate::providers::claude::supervisor::input_writer::InputWriter;
use crate::providers::claude::wake_hold::ScheduledWork;
use crate::providers::claude::{ClaudeSelection, ClaudeTurnRequest, ClaudeUserInput};
use crate::rpc::error::RpcCode;
use futures_util::StreamExt;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tracing::warn;

pub(crate) enum ResumeDelivery {
    Started(String),
    Steered(String),
    Recorded,
    Stopped,
}

impl ClaudeSupervisor {
    pub(crate) async fn capture_for_restart(&self) -> Vec<Item> {
        self.process_registry
            .lock()
            .expect("Claude process registry poisoned")
            .closing = true;
        self.admitted_starts.close();
        self.admitted_starts.wait().await;
        self.capture().await
    }

    pub(super) async fn capture(&self) -> Vec<Item> {
        let groups = self
            .runtimes
            .lock()
            .await
            .iter()
            .map(|(thread_id, runtime)| (thread_id.clone(), runtime.process_group_id))
            .collect::<Vec<_>>();
        let stop_generations = futures_util::stream::iter(groups)
            .map(|(thread_id, group)| async move {
                self.refresh_wakes(&thread_id, group).await;
                let generation = self
                    .stop_generation(&thread_id)
                    .await
                    .inspect_err(|error| {
                        warn!(%thread_id, error = %format!("{error:#}"), "the Claude stop state is unreadable; a later Stop cannot cancel this resume");
                    })
                    .ok();
                (thread_id, generation)
            })
            .buffer_unordered(CAPTURE_CONCURRENCY)
            .collect::<HashMap<_, _>>()
            .await;
        let (now, wall_now) = (tokio::time::Instant::now(), SystemTime::now());
        let captured = {
            let runtimes = self.runtimes.lock().await;
            runtimes
                .iter()
                .filter_map(|(thread_id, runtime)| {
                    let paused = runtime
                        .background_tasks
                        .iter()
                        .filter_map(suspend::BackgroundTask::paused)
                        .collect::<Vec<_>>();
                    let scheduled = runtime
                        .wakes
                        .scheduled(now, wall_now)
                        .into_iter()
                        .map(|work| match work {
                            ScheduledWork::Loop { next_wake } => ScheduledWake::Loop {
                                next_wake_unix_ms: next_wake.and_then(|wake| {
                                    wake.duration_since(UNIX_EPOCH)
                                        .ok()
                                        .and_then(|since| u64::try_from(since.as_millis()).ok())
                                }),
                            },
                            ScheduledWork::Cron { schedule } => ScheduledWake::Cron { schedule },
                        })
                        .collect::<Vec<_>>();
                    // A manual native command is interrupted on restart, never
                    // replayed as a model prompt or implicitly reissued.
                    let turn = runtime
                        .running_turn()
                        .filter(|turn| !turn.translator.is_manual_compaction());
                    let queued = runtime
                        .input
                        .unconsumed()
                        .pending()
                        .into_iter()
                        .filter(|input| input.text != "/compact")
                        .collect::<Vec<_>>();
                    if turn.is_none()
                        && paused.is_empty()
                        && scheduled.is_empty()
                        && queued.is_empty()
                    {
                        return None;
                    }
                    let selection = runtime
                        .settings
                        .as_ref()
                        .map(|settings| settings.effective().clone());
                    Some((
                        thread_id.clone(),
                        runtime.session_uuid.clone(),
                        runtime.cwd.clone(),
                        selection,
                        turn.map(|turn| {
                            (turn.translator.turn_id().to_owned(), turn.agent_initiated)
                        }),
                        paused,
                        scheduled,
                        queued,
                    ))
                })
                .collect::<Vec<_>>()
        };
        let mut items = Vec::with_capacity(captured.len());
        for (
            thread_id,
            session_uuid,
            cwd,
            selection,
            turn,
            background_tasks,
            scheduled_wakes,
            queued,
        ) in captured
        {
            let selection = match selection {
                Some(selection) => selection,
                None => {
                    self.parent_selection(&thread_id)
                        .await
                        .unwrap_or_else(|| ClaudeSelection {
                            model: self.settings.default_model.clone(),
                            effort: None,
                            fast: false,
                        })
                }
            };
            let (notices, queued_inputs): (Vec<_>, Vec<_>) =
                queued.into_iter().partition(|input| input.notice.is_some());
            let mut item = Item {
                recovery_id: new_session_uuid(),
                stop_generation: stop_generations.get(&thread_id).copied().flatten(),
                thread_id,
                session_uuid,
                cwd,
                model: selection.model,
                effort: selection.effort,
                fast: selection.fast,
                cause: Cause::Restart,
                interrupted_turn_id: turn.as_ref().map(|(turn_id, _)| turn_id.clone()),
                agent_initiated: turn.is_some_and(|(_, agent_initiated)| agent_initiated),
                background_tasks,
                scheduled_wakes,
                queued_inputs,
                earlier_events: Vec::new(),
                captured_at_unix_ms: crate::time::unix_millis() as u64,
                status: ItemStatus::Captured,
                attempts: 0,
                resumed_turn_id: None,
                error: None,
            };
            for earlier in notices.into_iter().filter_map(|input| input.notice) {
                item.absorb(*earlier);
            }
            items.push(item);
        }
        items
    }

    pub(crate) async fn resume_with_notice(
        self: &Arc<Self>,
        item: &Item,
    ) -> Result<ResumeDelivery, TurnStartError> {
        let _lifecycle = self.lifecycles.lock(&item.thread_id).await;
        let parent = self
            .conversation_index
            .parent(&item.thread_id)
            .await
            .map_err(|error| {
                resume_error(format!("Claude job ownership could not be read: {error:#}"))
            })?;
        if let Some(handle) = parent.active_job {
            let saved = self
                .conversation_index
                .job(&item.thread_id, &handle)
                .await
                .map_err(|error| {
                    resume_error(format!("Claude job evidence could not be read: {error:#}"))
                })?
                .ok_or_else(|| resume_error("Claude job evidence is missing".into()))?;
            if matches!(
                saved.phase,
                crate::providers::claude::conversation_index::job::JobPhase::Stopping
                    | crate::providers::claude::conversation_index::job::JobPhase::Finished { .. }
            ) {
                return Ok(ResumeDelivery::Stopped);
            }
            if !self.has_runtime(&item.thread_id).await
                && let Some(owner) = saved.owner
            {
                let group = owner.pid;
                let alive = tokio::task::spawn_blocking(move || owner.alive())
                    .await
                    .map_err(|error| resume_error(error.to_string()))?
                    .map_err(|error| {
                        resume_error(format!(
                            "Claude's exact execution owner is unknown: {error:#}"
                        ))
                    })?;
                if alive {
                    return Err(TurnStartError::unresponsive(
                        "Claude's exact job process still lives; refusing a second execution",
                    ));
                }
                if super::group_exists(nix::unistd::Pid::from_raw(group)) {
                    return Err(TurnStartError::unresponsive(
                        "Claude's execution process group still exists; refusing a second execution",
                    ));
                }
            }
        }
        let stop_generation = self
            .stop_generation(&item.thread_id)
            .await
            .map_err(|error| {
                resume_error(format!("the Stop state could not be read: {error:#}"))
            })?;
        if let Some(captured) = item.stop_generation
            && stop_generation > captured
        {
            return Ok(ResumeDelivery::Stopped);
        }
        let mut frames = self
            .undelivered(item)
            .await
            .map_err(|error| {
                resume_error(format!(
                    "the resumed messages could not be checked against the history: {error:#}"
                ))
            })?
            .into_iter();
        let Some(first) = frames.next() else {
            return Ok(ResumeDelivery::Recorded);
        };
        let active = self
            .runtimes
            .lock()
            .await
            .get_mut(&item.thread_id)
            .and_then(|runtime| {
                runtime
                    .active_turn
                    .as_mut()
                    .filter(|turn| turn.phase == TurnPhase::Running)
                    .map(|turn| {
                        if turn.continues.is_none() {
                            turn.continues = item.interrupted_turn_id.clone();
                        }
                        (
                            turn.translator.turn_id().to_owned(),
                            runtime.input.clone(),
                            runtime.process_group_id,
                        )
                    })
            });
        let (delivery, input, group) = match active {
            Some((turn_id, input, group)) => {
                self.write_resumed(&item.thread_id, group, &input, &first, stop_generation)
                    .await?;
                (ResumeDelivery::Steered(turn_id), input, group)
            }
            None => {
                let request = ClaudeTurnRequest {
                    thread_id: item.thread_id.clone(),
                    session_uuid: item.session_uuid.clone(),
                    first_turn: false,
                    input: first,
                    selection: item.selection(),
                    cwd: item.cwd.clone(),
                };
                let turn_id = self
                    .start_turn_locked(request, TurnOrigin::Callback { stop_generation })
                    .await?;
                let (input, group) = self
                    .runtimes
                    .lock()
                    .await
                    .get_mut(&item.thread_id)
                    .map(|runtime| {
                        if let Some(turn) = runtime
                            .active_turn
                            .as_mut()
                            .filter(|turn| turn.translator.turn_id() == turn_id)
                        {
                            turn.continues = item.interrupted_turn_id.clone();
                        }
                        (runtime.input.clone(), runtime.process_group_id)
                    })
                    .ok_or_else(|| {
                        resume_error(
                            "the resumed Claude process ended before its messages were delivered"
                                .to_owned(),
                        )
                    })?;
                (ResumeDelivery::Started(turn_id), input, group)
            }
        };
        for frame in frames {
            self.write_resumed(&item.thread_id, group, &input, &frame, stop_generation)
                .await?;
        }
        Ok(delivery)
    }

    pub(crate) async fn undelivered(&self, item: &Item) -> anyhow::Result<Vec<ClaudeUserInput>> {
        let frames = std::iter::once(ClaudeUserInput::recovery_notice(item))
            .chain(item.queued_inputs.iter().cloned())
            .collect::<Vec<_>>();
        let Some(history) = self.session_history(&item.cwd, &item.session_uuid) else {
            return Ok(frames);
        };
        tokio::task::spawn_blocking(move || {
            let recorded = {
                let ids = frames
                    .iter()
                    .filter_map(|frame| frame.client_id.as_deref())
                    .collect::<Vec<_>>();
                crate::providers::claude::delivery_evidence::recorded_ids(&history, &ids)?
                    .into_iter()
                    .map(str::to_owned)
                    .collect::<HashSet<_>>()
            };
            anyhow::Ok(
                frames
                    .into_iter()
                    .filter(|frame| {
                        frame
                            .client_id
                            .as_ref()
                            .is_none_or(|id| !recorded.contains(id))
                    })
                    .collect(),
            )
        })
        .await?
    }

    async fn write_resumed(
        &self,
        thread_id: &str,
        group: i32,
        input: &InputWriter,
        frame: &ClaudeUserInput,
        stop_generation: u64,
    ) -> Result<(), TurnStartError> {
        let prepared =
            super::input_writer::InputWriter::prepare_input(frame).map_err(TurnStartError::from)?;
        let slot = input.reserve().await.map_err(TurnStartError::from)?;
        let policy = self
            .runtimes
            .lock()
            .await
            .get(thread_id)
            .filter(|runtime| runtime.process_group_id == group && runtime.running_turn().is_some())
            .map(|runtime| runtime.launch.clone())
            .ok_or_else(|| {
                resume_error("Claude's recovery runtime stopped before input submission".into())
            })?;
        let pending = self
            .submit_callback_input(
                thread_id,
                &policy,
                TurnOrigin::Callback { stop_generation },
                slot,
                prepared,
            )
            .await?;
        let Err(error) = pending.written().await else {
            return self.ensure_runtime_current(thread_id, group).await;
        };
        if InputWriter::stall_was_queued(&error) {
            self.input_stalled(thread_id, group, "restart/resume", error);
            return self.ensure_runtime_current(thread_id, group).await;
        }
        if InputWriter::is_stalled(&error) {
            return Err(self.input_stalled(thread_id, group, "restart/resume", error));
        }
        let message = format!("failed writing a resumed message to Claude: {error}");
        self.retire_after_write_failure(thread_id, group, &message)
            .await;
        Err(resume_error(message))
    }
}

fn resume_error(message: String) -> TurnStartError {
    TurnStartError {
        data: None,
        code: RpcCode::Internal,
        message,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::mcp::McpTokens;
    use crate::observability::journal::Journal;
    use crate::providers::claude::restart::Cause;
    use crate::providers::claude::restart::test_support::{SESSION, StubClaude, THREAD};
    use crate::providers::claude::supervisor::signal_group;
    use nix::sys::signal::Signal;
    use nix::unistd::Pid;
    use serde_json::{Value, json};
    use std::fs;
    use tokio::sync::mpsc;

    struct Fixture {
        stub: StubClaude,
        agent: Arc<ClaudeSupervisor>,
        events: mpsc::Receiver<crate::providers::claude::ClaudeNotification>,
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
            let stub = StubClaude::new();
            let (sender, events) = mpsc::channel(256);
            let agent = ClaudeSupervisor::new(
                stub.settings.clone(),
                sender,
                Journal::disabled(),
                McpTokens::default(),
            );
            Self {
                stub,
                agent,
                events,
            }
        }

        async fn next_completion(&mut self) -> Value {
            loop {
                let event = crate::test_support::claude_event(
                    self.events
                        .recv()
                        .await
                        .expect("a notification was emitted"),
                );
                if event["method"] == "turn/completed" {
                    return event;
                }
            }
        }

        async fn running_turn(&self) {
            self.agent
                .start_turn(ClaudeTurnRequest {
                    thread_id: THREAD.to_owned(),
                    session_uuid: SESSION.to_owned(),
                    first_turn: false,
                    input: ClaudeUserInput::text("long task"),
                    selection: ClaudeSelection {
                        model: "opus".to_owned(),
                        effort: Some("max".to_owned()),
                        fast: true,
                    },
                    cwd: self.stub.cwd.clone(),
                })
                .await
                .unwrap();
            self.stub.wait_for_log("received.jsonl", 1).await;
        }
    }

    #[tokio::test]
    async fn restart_persists_the_capture_then_suspends_and_resumes_the_exact_session() {
        let mut fixture = Fixture::new();
        fixture.running_turn().await;
        let interrupted_turn = fixture.agent.active_turn_id(THREAD).await.unwrap();
        let store =
            crate::providers::claude::restart::Store::beside(&fixture.stub.turn_state_path());

        let captured = fixture.agent.capture_for_restart().await;
        let journal =
            crate::providers::claude::restart::Journal::capture(None, captured, None).unwrap();
        store.write(&journal).unwrap();
        let exited = fixture.agent.suspend(THREAD).await;
        let completion = fixture.next_completion().await;
        fixture.agent.stop_all().await;

        let item = &journal.items[0];
        assert_eq!(item.thread_id, THREAD);
        assert_eq!(item.session_uuid, SESSION);
        assert_eq!(item.cwd, fixture.stub.cwd);
        assert_eq!(
            item.selection(),
            ClaudeSelection {
                model: "opus".to_owned(),
                effort: Some("max".to_owned()),
                fast: true,
            }
        );
        assert_eq!(
            item.interrupted_turn_id.as_deref(),
            Some(interrupted_turn.as_str())
        );
        assert!(!item.agent_initiated);
        assert_eq!(item.cause, Cause::Restart);
        assert!(exited);
        assert!(fixture.stub.log("controls.jsonl").is_empty());
        assert_eq!(completion["params"]["turn"]["status"], "interrupted");
        assert!(!fixture.agent.has_runtime(THREAD).await);

        let (sender, _events) = mpsc::channel(256);
        let replacement = ClaudeSupervisor::new(
            fixture.stub.settings.clone(),
            sender,
            Journal::disabled(),
            McpTokens::default(),
        );
        let resumed = replacement
            .resume_with_notice(&store.load().unwrap().unwrap().items[0])
            .await
            .unwrap();
        let launches = fixture.stub.wait_for_log("launches.jsonl", 2).await;
        let received = fixture.stub.wait_for_log("received.jsonl", 2).await;
        let history = fs::read_to_string(fixture.stub.history(SESSION)).unwrap();
        replacement.stop_all().await;

        assert!(matches!(resumed, ResumeDelivery::Started(_)));
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
                .any(|pair| pair == [json!("--effort"), json!("max")])
        );
        assert_eq!(launches[1]["cwd"], launches[0]["cwd"]);
        assert_eq!(
            launches[1]["configDir"],
            json!(fixture.stub.claude_home.to_string_lossy())
        );
        assert!(launches[1]["context"].get("account").is_none());
        assert_eq!(received[1]["uuid"], json!(item.recovery_id));
        assert_eq!(received[1]["isSynthetic"], true);
        let notice = received[1]["message"]["content"].as_str().unwrap();
        assert!(notice.contains("gateway restarted"), "{notice}");
        assert!(notice.contains("cut off mid-step"), "{notice}");
        assert!(history.contains(&item.recovery_id));
    }

    #[tokio::test]
    async fn capture_fences_new_starts_and_skips_idle_runtimes() {
        let mut fixture = Fixture::new();
        fixture.running_turn().await;
        let input = fixture
            .agent
            .runtimes
            .lock()
            .await
            .get(THREAD)
            .map(|runtime| runtime.input.clone())
            .unwrap();
        input
            .send_prepared_control(
                super::super::InputWriter::prepare_control(
                    "end-the-turn",
                    &json!({"subtype":"interrupt"}),
                )
                .unwrap(),
            )
            .await
            .unwrap();
        fixture.next_completion().await;
        assert!(fixture.agent.has_runtime(THREAD).await);

        let captured = fixture.agent.capture_for_restart().await;
        let refused = fixture
            .agent
            .start_turn(ClaudeTurnRequest {
                thread_id: THREAD.to_owned(),
                session_uuid: SESSION.to_owned(),
                first_turn: false,
                input: ClaudeUserInput::text("late"),
                selection: ClaudeSelection {
                    model: "opus".to_owned(),
                    effort: None,
                    fast: false,
                },
                cwd: fixture.stub.cwd.clone(),
            })
            .await
            .unwrap_err();

        assert!(captured.is_empty());
        assert_eq!(refused.code, RpcCode::ServerBusy);
        assert_eq!(fixture.stub.log("launches.jsonl").len(), 1);
        assert_eq!(
            fixture
                .stub
                .log("controls.jsonl")
                .iter()
                .map(|control| control["request"]["subtype"].clone())
                .collect::<Vec<_>>(),
            [json!("interrupt")]
        );
    }
}
