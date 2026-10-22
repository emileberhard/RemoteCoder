use super::{
    ClaudeSupervisor, INTERRUPT_GRACE, IdleEligibility, IdlePolicy, ProcessAdmission,
    STOP_GRACE_PERIOD, STOP_KILL_PERIOD, TurnControlError, TurnPhase, TurnStartError, other_turn,
    signal_group, wait_for_group_exit,
};
use crate::providers::claude::restart::SuspendedTurn;
use crate::rpc::error::RpcCode;
use futures_util::StreamExt;
use nix::sys::signal::Signal;
use nix::unistd::Pid;
use serde_json::{Value, json};
use tracing::{error, warn};

impl ClaudeSupervisor {
    pub(crate) async fn child_agents(
        &self,
        thread: &str,
    ) -> Option<(crate::agents::claude::Projection, u128)> {
        self.runtimes
            .lock()
            .await
            .get(thread)
            .map(|r| (r.children.clone(), r.children_generation))
    }

    pub(crate) async fn stop_child(
        &self,
        thread: &str,
        task: &str,
        generation: u128,
        revision: u64,
    ) -> Result<Value, String> {
        let _lifecycle = self.lifecycles.lock(thread).await;
        let group = {
            let runtimes = self.runtimes.lock().await;
            let runtime = runtimes
                .get(thread)
                .filter(|runtime| runtime.children_generation == generation)
                .ok_or("Claude execution changed; refresh before stopping")?;
            if !runtime.children.children.values().any(|child| {
                child.task_id.as_deref() == Some(task)
                    && child.execution_revision == revision
                    && child.state.is_running()
            }) {
                return Err("This child task is no longer running".into());
            }
            runtime.process_group_id
        };
        self.runtime_control(thread, group, json!({"subtype":"stop_task","task_id":task}))
            .await
            .map_err(|error| error.message)
    }

    pub(super) async fn observe_child_agents(&self, thread: &str, group: i32, value: &Value) {
        if !matches!(
            value["type"].as_str(),
            Some("assistant" | "user" | "system")
        ) {
            return;
        }
        let snapshot = {
            let mut runtimes = self.runtimes.lock().await;
            let Some(runtime) = runtimes
                .get_mut(thread)
                .filter(|r| r.process_group_id == group)
            else {
                return;
            };
            runtime
                .children
                .ingest(value)
                .then(|| (runtime.children_generation, runtime.children.clone()))
        };
        if let Some((generation, snapshot)) = snapshot {
            let home = self.settings.claude_home.clone();
            let owned_thread = thread.to_owned();
            match tokio::task::spawn_blocking(move || {
                crate::agents::claude::store::save(&home, &owned_thread, generation, snapshot)
            })
            .await
            {
                Ok(Ok(())) => {}
                error => warn!(thread, ?error, "Could not persist Claude child state"),
            }
        }
    }

    /// Interrupts the thread's running turn, only when it is or continues
    /// `turn_id`, and retires its warm process. With no process running,
    /// `suspended` lists the turns this account's pending resumes continue; a
    /// Stop naming one is recorded so that resume never runs.
    pub(crate) async fn interrupt(
        &self,
        thread_id: &str,
        turn_id: &str,
        suspended: impl AsyncFnOnce() -> anyhow::Result<Vec<SuspendedTurn>>,
    ) -> Result<(), TurnControlError> {
        let group = match self.claim_running_stop(thread_id, turn_id).await? {
            Some(group) => group,
            None => {
                let lifecycle = self.lifecycles.lock(thread_id).await;
                match self.claim_running_stop(thread_id, turn_id).await? {
                    Some(group) => {
                        drop(lifecycle);
                        group
                    }
                    None => {
                        return self
                            .stop_suspended_turn(thread_id, turn_id, suspended)
                            .await;
                    }
                }
            }
        };
        let mut admission =
            ProcessAdmission::new(group, std::sync::Arc::clone(&self.process_registry));
        let recorded = self.stop_parent(thread_id).await;
        let stopped = tokio::time::timeout(
            INTERRUPT_GRACE,
            self.runtime_control(
                thread_id,
                group,
                json!({ "subtype": "interrupt", "cancel_queued": true }),
            ),
        )
        .await;
        if !matches!(stopped, Ok(Ok(_))) {
            warn!(%thread_id, pid = group, "Claude did not confirm the interrupt; ending its process");
        }
        self.fail_runtime(thread_id, group, "interrupted", None)
            .await;
        admission.accept();
        recorded.map_err(|error| {
            TurnStartError {
                data: None,
                code: RpcCode::Internal,
                message: format!(
                    "The turn stopped, but the Stop was not saved, so a subagent's message can wake it again: {error:#}"
                ),
            }
            .into()
        })
    }

    async fn claim_running_stop(
        &self,
        thread_id: &str,
        turn_id: &str,
    ) -> Result<Option<i32>, TurnControlError> {
        let mut runtimes = self.runtimes.lock().await;
        let Some(runtime) = runtimes.get_mut(thread_id) else {
            return Ok(None);
        };
        let group = runtime.process_group_id;
        let Some(active) = runtime.running_turn_mut() else {
            return Err(TurnControlError::NotRunning {
                message: "no active turn to interrupt".into(),
            });
        };
        if !active.is(turn_id) {
            return Err(other_turn(turn_id, active.translator.turn_id()).into());
        }
        active.phase = TurnPhase::Stopping;
        runtime.lifecycle_generation = runtime.lifecycle_generation.wrapping_add(1);
        Ok(Some(group))
    }

    async fn stop_suspended_turn(
        &self,
        thread_id: &str,
        turn_id: &str,
        suspended: impl AsyncFnOnce() -> anyhow::Result<Vec<SuspendedTurn>>,
    ) -> Result<(), TurnControlError> {
        let failed = |message: String| TurnStartError {
            data: None,
            code: RpcCode::Internal,
            message,
        };
        let suspended = suspended().await.map_err(|error| {
            failed(format!(
                "The pending resume could not be checked, so the Stop was not recorded: {error:#}"
            ))
        })?;
        match suspended.iter().find(|turn| turn.turn_id == turn_id) {
            Some(turn) if turn.stoppable => self.stop_parent(thread_id).await.map_err(|error| {
                failed(format!(
                    "The Stop was not recorded, so the pending resume will continue the turn: {error:#}"
                ))
                .into()
            }),
            Some(_) => Err(failed(
                "The pending resume was saved without its Stop state, so it cannot be cancelled."
                    .to_owned(),
            )
            .into()),
            None => Err(match suspended.first() {
                Some(other) => other_turn(turn_id, &other.turn_id).into(),
                None => TurnControlError::NotRunning {
                    message: "no active turn to interrupt".to_string(),
                },
            }),
        }
    }

    /// Retires a warm runtime without deleting the resumable Claude session.
    pub(crate) async fn release_idle_runtime(&self, thread_id: &str) -> bool {
        let _lifecycle = self.lifecycles.lock(thread_id).await;
        let Some(group) = self
            .runtimes
            .lock()
            .await
            .get(thread_id)
            .map(|runtime| runtime.process_group_id)
        else {
            return false;
        };
        let evidence = self.refresh_wakes(thread_id, group).await;
        let process_group_id = {
            let mut runtimes = self.runtimes.lock().await;
            let Some(runtime) = runtimes
                .get(thread_id)
                .filter(|runtime| runtime.process_group_id == group)
            else {
                return false;
            };
            if !matches!(
                IdlePolicy::eligibility(runtime, evidence, tokio::time::Instant::now()),
                IdleEligibility::Eligible
            ) {
                return false;
            }
            self.journal.runtime(
                "retire",
                serde_json::json!({
                    "reason": "released",
                    "threadId": thread_id,
                    "pid": group,
                    "settings": runtime.settings,
                    "cwd": runtime.cwd,
                    "generation": runtime.lifecycle_generation,
                }),
            );
            runtimes.remove(thread_id);
            group
        };
        self.terminate_group(Pid::from_raw(process_group_id)).await;
        true
    }

    /// Stops every active or idle Claude runtime. Used on gateway shutdown.
    pub(crate) async fn stop_all(&self) {
        let processes: Vec<i32> = {
            let mut registry = self
                .process_registry
                .lock()
                .expect("Claude process registry poisoned");
            registry.closing = true;
            self.reapers.close();
            registry.groups.iter().copied().collect()
        };
        self.timers.stop().await;
        // Reapers already own children that have not reached the runtime map.
        futures_util::stream::iter(processes)
            .for_each_concurrent(8, |group| async move {
                self.terminate_group(Pid::from_raw(group)).await;
            })
            .await;
        let registered: Vec<_> = self
            .runtimes
            .lock()
            .await
            .iter()
            .map(|(thread, runtime)| (thread.clone(), runtime.process_group_id))
            .collect();
        for (thread, group) in registered {
            self.fail_runtime(&thread, group, "interrupted", None).await;
        }
        self.reapers.wait().await;
        self.io_tasks.stop().await;
    }

    pub(super) async fn terminate_group(&self, process_group_id: Pid) {
        signal_group(process_group_id, Signal::SIGTERM);
        if wait_for_group_exit(process_group_id, STOP_GRACE_PERIOD).await {
            return;
        }
        warn!(
            pgid = process_group_id.as_raw(),
            "claude runtime survived SIGTERM; sending SIGKILL"
        );
        signal_group(process_group_id, Signal::SIGKILL);
        if !wait_for_group_exit(process_group_id, STOP_KILL_PERIOD).await {
            error!(
                pgid = process_group_id.as_raw(),
                "claude process group survived SIGKILL"
            );
        }
    }
}
