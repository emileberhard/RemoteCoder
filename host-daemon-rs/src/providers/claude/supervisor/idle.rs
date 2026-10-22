use super::{
    ClaudeRuntime, ClaudeSupervisor, IDLE_WARM_RUNTIME_CAP, IdleArm, IdleEligibility, IdlePolicy,
    IdleRetirement, IdleRuntime, RUNTIME_IDLE_TIMEOUT, RUNTIME_START_TIMEOUT, StoppedTurn,
    WAKE_EVIDENCE_RETRY, WakeEvidence, suspend,
};
use nix::unistd::Pid;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::SystemTime;
use tracing::{info, warn};

impl ClaudeSupervisor {
    pub(super) async fn schedule_runtime_idle_timeout(
        self: &Arc<Self>,
        thread_id: String,
        process_group_id: i32,
        lifecycle_generation: u64,
    ) {
        let (idle, cancelled) = {
            let mut runtimes = self.runtimes.lock().await;
            let Some(runtime) = runtimes.get_mut(&thread_id).filter(|runtime| {
                runtime.process_group_id == process_group_id
                    && runtime.is_idle()
                    && runtime.lifecycle_generation == lifecycle_generation
            }) else {
                return;
            };
            let since = tokio::time::Instant::now();
            let timer = tokio_util::sync::CancellationToken::new();
            runtime.idle = Some(IdleArm {
                since,
                timer: timer.clone(),
            });
            let idle = IdleRuntime {
                thread_id,
                process_group_id,
                lifecycle_generation,
                since,
            };
            (idle, timer)
        };
        let agent = Arc::clone(self);
        self.timers.spawn("Claude idle expiry", async move {
            let mut deadline = idle.since + RUNTIME_IDLE_TIMEOUT;
            loop {
                tokio::select! {
                    _ = cancelled.cancelled() => return Ok(()),
                    _ = tokio::time::sleep_until(deadline) => {},
                }
                match agent.retire_idle_runtime(&idle, "idle timeout").await {
                    IdleRetirement::Held(until) => deadline = until,
                    IdleRetirement::Retired | IdleRetirement::NotIdle => return Ok(()),
                }
            }
        });
        let agent = Arc::clone(self);
        self.timers.spawn("Claude idle cap", async move {
            for idle in agent.idle_runtimes_beyond_cap().await {
                agent.retire_idle_runtime(&idle, "idle cap").await;
            }
            Ok(())
        });
    }

    pub(super) async fn idle_runtimes_beyond_cap(&self) -> Vec<IdleRuntime> {
        let now = tokio::time::Instant::now();
        let runtimes = self.runtimes.lock().await;
        let mut idle: Vec<IdleRuntime> = runtimes
            .iter()
            .filter(|(_, runtime)| runtime.is_idle() && runtime.wakes.held_until(now).is_none())
            .filter_map(|(thread_id, runtime)| {
                runtime.idle.as_ref().map(|arm| IdleRuntime {
                    thread_id: thread_id.clone(),
                    process_group_id: runtime.process_group_id,
                    lifecycle_generation: runtime.lifecycle_generation,
                    since: arm.since,
                })
            })
            .collect();
        idle.sort_by_key(|runtime| std::cmp::Reverse(runtime.since));
        idle.split_off(IDLE_WARM_RUNTIME_CAP.min(idle.len()))
    }

    async fn retire_idle_runtime(&self, idle: &IdleRuntime, reason: &str) -> IdleRetirement {
        let _lifecycle = self.lifecycles.lock(&idle.thread_id).await;
        let evidence = self
            .refresh_wakes(&idle.thread_id, idle.process_group_id)
            .await;
        let now = tokio::time::Instant::now();
        {
            let mut runtimes = self.runtimes.lock().await;
            let Some(runtime) = runtimes.get(&idle.thread_id).filter(|runtime| {
                runtime.process_group_id == idle.process_group_id
                    && runtime.lifecycle_generation == idle.lifecycle_generation
                    && runtime
                        .idle
                        .as_ref()
                        .is_some_and(|arm| arm.since == idle.since)
            }) else {
                return IdleRetirement::NotIdle;
            };
            match IdlePolicy::eligibility(runtime, evidence, now) {
                IdleEligibility::Busy => return IdleRetirement::NotIdle,
                IdleEligibility::HeldUntil(until) => {
                    info!(thread_id = %idle.thread_id, reason, "holding idle Claude runtime for a pending scheduled wake");
                    self.journal.runtime(
                        "hold",
                        serde_json::json!({
                            "reason": reason,
                            "threadId": idle.thread_id,
                            "pid": idle.process_group_id,
                            "holdSeconds": until.duration_since(now).as_secs(),
                            "generation": idle.lifecycle_generation,
                        }),
                    );
                    return IdleRetirement::Held(until);
                }
                IdleEligibility::WakesUnreadable => {
                    warn!(thread_id = %idle.thread_id, reason, "holding idle Claude runtime because its scheduled wakes could not be read");
                    self.journal.runtime(
                        "hold",
                        serde_json::json!({
                            "reason": reason,
                            "threadId": idle.thread_id,
                            "pid": idle.process_group_id,
                            "holdSeconds": WAKE_EVIDENCE_RETRY.as_secs(),
                            "generation": idle.lifecycle_generation,
                            "wakeEvidence": "unreadable",
                        }),
                    );
                    return IdleRetirement::Held(now + WAKE_EVIDENCE_RETRY);
                }
                IdleEligibility::Eligible => {}
            }
            runtimes.remove(&idle.thread_id);
        }
        let idle_seconds = now.duration_since(idle.since).as_secs();
        info!(thread_id = %idle.thread_id, idle_seconds, reason, "retiring idle Claude runtime");
        self.journal.runtime(
            "retire",
            serde_json::json!({
                "reason": reason,
                "threadId": idle.thread_id,
                "pid": idle.process_group_id,
                "idleSeconds": idle_seconds,
                "generation": idle.lifecycle_generation,
            }),
        );
        self.terminate_group(Pid::from_raw(idle.process_group_id))
            .await;
        IdleRetirement::Retired
    }

    pub(super) async fn refresh_wakes(
        &self,
        thread_id: &str,
        process_group_id: i32,
    ) -> WakeEvidence {
        let snapshot = self
            .runtimes
            .lock()
            .await
            .get(thread_id)
            .filter(|runtime| runtime.process_group_id == process_group_id)
            .map(|runtime| {
                (
                    runtime.wakes.clone(),
                    runtime.cwd.clone(),
                    runtime.session_uuid.clone(),
                )
            });
        let Some((mut wakes, cwd, session_uuid)) = snapshot else {
            return WakeEvidence::Fresh;
        };
        let Some(path) = self.session_history(&cwd, &session_uuid) else {
            return if wakes.offset() == 0 {
                WakeEvidence::Fresh
            } else {
                warn!(%thread_id, "the Claude transcript that scheduled wakes were read from is gone");
                WakeEvidence::Unreadable
            };
        };
        let read_from = wakes.offset();
        let (now, wall_now) = (tokio::time::Instant::now(), SystemTime::now());
        let refreshed = tokio::task::spawn_blocking(move || {
            wakes.read_transcript(&path, now, wall_now).map(|()| wakes)
        })
        .await;
        match refreshed {
            Ok(Ok(wakes)) => {
                if let Some(runtime) =
                    self.runtimes
                        .lock()
                        .await
                        .get_mut(thread_id)
                        .filter(|runtime| {
                            runtime.process_group_id == process_group_id
                                && runtime.wakes.offset() == read_from
                        })
                {
                    runtime.wakes = wakes;
                }
                WakeEvidence::Fresh
            }
            Ok(Err(error)) => {
                warn!(%thread_id, %error, "reading scheduled wakes from the Claude transcript failed");
                WakeEvidence::Unreadable
            }
            Err(error) => {
                warn!(%thread_id, %error, "reading scheduled wakes from the Claude transcript did not finish");
                WakeEvidence::Unreadable
            }
        }
    }

    pub(super) async fn track_background_tasks(
        self: &Arc<Self>,
        thread_id: &str,
        process_group_id: i32,
        value: &Value,
    ) {
        let Some(tasks) = suspend::background_tasks(value) else {
            warn!(%thread_id, "ignoring a malformed Claude background task list");
            return;
        };
        let idle_generation = {
            let mut runtimes = self.runtimes.lock().await;
            let Some(runtime) = runtimes
                .get_mut(thread_id)
                .filter(|runtime| runtime.process_group_id == process_group_id)
            else {
                return;
            };
            if runtime.background_tasks == tasks {
                return;
            }
            runtime.background_tasks = tasks;
            self.journal.runtime(
                "background",
                json!({
                    "threadId": thread_id,
                    "pid": process_group_id,
                    "taskIds": runtime.background_task_ids(),
                }),
            );
            if !runtime.background_tasks.is_empty() {
                runtime.idle = None;
            }
            runtime.is_idle().then_some(runtime.lifecycle_generation)
        };
        if let Some(generation) = idle_generation {
            self.schedule_runtime_idle_timeout(thread_id.to_string(), process_group_id, generation)
                .await;
        }
    }

    pub(super) async fn fail_runtime(
        &self,
        thread_id: &str,
        process_group_id: i32,
        status: &str,
        error_message: Option<String>,
    ) {
        let Some((runtime, stopped_turn)) = self
            .take_runtime_recording_turn(thread_id, Some(process_group_id), status, error_message)
            .await
        else {
            return;
        };
        self.retire_stopped_runtime(thread_id, process_group_id, runtime, status, stopped_turn)
            .await;
    }

    pub(super) async fn retire_stopped_runtime(
        &self,
        thread_id: &str,
        process_group_id: i32,
        mut runtime: ClaudeRuntime,
        status: &str,
        stopped_turn: Option<StoppedTurn>,
    ) {
        let status = if runtime
            .active_turn
            .as_ref()
            .is_some_and(super::RuntimeTurn::is_stopping)
        {
            "interrupted"
        } else {
            status
        };
        self.terminate_group(Pid::from_raw(process_group_id)).await;
        if status == "interrupted" {
            runtime.children.stopped();
        } else {
            for child in runtime.children.children.values_mut() {
                if child.state.is_running() {
                    child.state = crate::agents::State::Unknown;
                }
            }
        }
        let home = self.settings.claude_home.clone();
        let owned_thread = thread_id.to_owned();
        let generation = runtime.children_generation;
        let snapshot = runtime.children.clone();
        match tokio::task::spawn_blocking(move || {
            crate::agents::claude::store::save(&home, &owned_thread, generation, snapshot)
        })
        .await
        {
            Ok(Ok(())) => {}
            error => warn!(thread_id, ?error, "Could not persist stopped child state"),
        }
        let Some(stopped_turn) = stopped_turn else {
            self.record_runtime_stop(thread_id, process_group_id, status, &runtime, None);
            return;
        };
        self.publish(stopped_turn.completed).await;
        info!(thread_id, status, "claude runtime stopped");
        self.record_runtime_stop(
            thread_id,
            process_group_id,
            status,
            &runtime,
            stopped_turn.message.as_deref(),
        );
    }

    fn record_runtime_stop(
        &self,
        thread_id: &str,
        process_group_id: i32,
        status: &str,
        runtime: &ClaudeRuntime,
        error_message: Option<&str>,
    ) {
        self.journal.runtime(
            "stop",
            serde_json::json!({
                "threadId": thread_id,
                "pid": process_group_id,
                "status": status,
                "settings": runtime.settings,
                "cwd": runtime.cwd,
                "generation": runtime.lifecycle_generation,
                "error": error_message,
            }),
        );
    }

    pub(super) fn schedule_runtime_start_timeout(
        self: &Arc<Self>,
        thread_id: String,
        process_group_id: i32,
    ) {
        let agent = Arc::clone(self);
        self.timers
            .spawn("Claude initialization timeout", async move {
                tokio::time::sleep(RUNTIME_START_TIMEOUT).await;
                let timed_out =
                    agent
                        .runtimes
                        .lock()
                        .await
                        .get(&thread_id)
                        .is_some_and(|runtime| {
                            runtime.process_group_id == process_group_id && !runtime.initialized
                        });
                if !timed_out {
                    return Ok(());
                }

                warn!(%thread_id, "Claude runtime did not initialize in time");
                agent
                    .fail_runtime(
                        &thread_id,
                        process_group_id,
                        "failed",
                        Some("Claude runtime startup timed out".to_string()),
                    )
                    .await;
                Ok(())
            });
    }
}
