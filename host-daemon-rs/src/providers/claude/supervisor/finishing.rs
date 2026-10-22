use super::{
    ClaudeRuntime, ClaudeSupervisor, StoppedTurn, TurnPhase, annotate_agent_initiated,
    append_stderr_tail,
};
use serde_json::Value;

struct PendingStop {
    completed: Value,
    message: Option<String>,
}

impl ClaudeRuntime {
    async fn begin_stop(
        &mut self,
        status: &str,
        error_message: Option<String>,
    ) -> Option<PendingStop> {
        let active = self
            .active_turn
            .as_mut()
            .filter(|turn| matches!(turn.phase, TurnPhase::Running | TurnPhase::Stopping))?;
        let user_stop = active.phase == TurnPhase::Stopping;
        let status = if user_stop { "interrupted" } else { status };
        active.phase = if active.phase == TurnPhase::Stopping {
            TurnPhase::FinishingAfterStop
        } else {
            TurnPhase::Finishing
        };
        active.translator.end_live_state();
        let message = if user_stop {
            None
        } else if status == "interrupted" {
            error_message
        } else {
            append_stderr_tail(error_message, &self.stderr_ring).await
        };
        let mut completed = active
            .translator
            .turn_completed(status, message.as_deref(), None);
        if active.agent_initiated {
            annotate_agent_initiated(&mut completed, None);
        }
        Some(PendingStop { completed, message })
    }
}

impl ClaudeSupervisor {
    pub(super) async fn wait_for_finishing_turn(&self, thread_id: &str) {
        loop {
            let mut settled = std::pin::pin!(self.turn_settled.notified());
            settled.as_mut().enable();
            let finishing = self
                .runtimes
                .lock()
                .await
                .get(thread_id)
                .and_then(|runtime| runtime.active_turn.as_ref())
                .is_some_and(|turn| {
                    matches!(
                        turn.phase,
                        TurnPhase::Finishing | TurnPhase::FinishingAfterStop
                    )
                });
            if !finishing {
                return;
            }
            settled.await;
        }
    }

    pub(super) async fn take_runtime_recording_turn(
        &self,
        thread_id: &str,
        process_group_id: Option<i32>,
        status: &str,
        error_message: Option<String>,
    ) -> Option<(ClaudeRuntime, Option<StoppedTurn>)> {
        let (group, pending) = {
            let mut runtimes = self.runtimes.lock().await;
            let runtime = runtimes.get_mut(thread_id).filter(|runtime| {
                process_group_id.is_none_or(|group| runtime.process_group_id == group)
            })?;
            let group = runtime.process_group_id;
            let pending = runtime.begin_stop(status, error_message).await;
            match pending {
                Some(pending) => (group, pending),
                None => return runtimes.remove(thread_id).map(|runtime| (runtime, None)),
            }
        };
        let stopped = StoppedTurn {
            completed: self.record(pending.completed).await,
            message: pending.message,
        };
        let removed = {
            let mut runtimes = self.runtimes.lock().await;
            if runtimes
                .get(thread_id)
                .is_some_and(|runtime| runtime.process_group_id == group)
            {
                runtimes.remove(thread_id)
            } else {
                None
            }
        };
        self.turn_settled.notify_waiters();
        match removed {
            Some(runtime) => Some((runtime, Some(stopped))),
            None => {
                self.publish(stopped.completed).await;
                None
            }
        }
    }
}
