use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Weak};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, ensure};
use futures_util::FutureExt;
use serde_json::Value;
use tracing::{info, warn};

use super::{Gateway, GatewayCoreState, RESTARTING_CLOSE_CODE, RESTARTING_CLOSE_REASON};
use crate::providers::claude::restart_driver::RestartAlert;
use crate::runtime::gateway_recovery::{
    finish_before_ingress, record_notification_status, record_recovery_task_failure,
    recovery_control_error_is_retryable, recovery_control_error_is_unauthorized, recovery_status,
    update_recovery_phase, update_recovery_task,
};
use crate::runtime::gateway_shutdown::{self, CodexRestart};
use crate::runtime::recovery::{RecoveryJournal, RecoveryPhase, RecoveryTaskStatus};
use crate::turns::TurnKey;

pub(super) fn restart_alert(gateway: Weak<Gateway>) -> RestartAlert {
    Arc::new(move |thread_id: String, body: String| {
        let gateway = gateway.clone();
        async move {
            let Some(gateway) = gateway.upgrade() else {
                return;
            };
            if let Err(error) = gateway
                .send_user_alert("Claude task was not resumed", &body, Some(&thread_id))
                .await
            {
                warn!(%error, thread_id = %thread_id, "restart recovery alert was not delivered");
            }
        }
        .boxed()
    })
}

impl Gateway {
    pub(crate) fn mark_listening(&self) {
        self.listening.send_replace(true);
    }

    fn listening_receiver(&self) -> tokio::sync::watch::Receiver<bool> {
        self.listening.subscribe()
    }

    pub(super) fn is_planned_interruption(&self, method: &str, message: &Value) -> bool {
        method == "turn/completed"
            && message
                .pointer("/params/turn/status")
                .and_then(Value::as_str)
                == Some("interrupted")
            && self.is_draining()
    }

    pub(crate) async fn shutdown_for_restart(&self) {
        if self.draining.swap(true, Ordering::AcqRel) {
            return;
        }
        let active_turns = self.active_turn_count().await;
        info!(
            active_turns,
            "gateway restart interrupting active work for automatic resume"
        );
        self.stop_voice_for_shutdown().await;
        let task = self.claude_recovery_task.lock().await.take();
        if let Some(task) = task {
            task.abort();
            let _ = task.await;
        }
        tokio::join!(
            self.suspend_claude_for_restart(),
            self.suspend_codex_for_restart()
        );
        let remaining = self.active_turn_count().await;
        info!(remaining, "gateway restart drain finished");
        self.close_all_clients(RESTARTING_CLOSE_CODE, RESTARTING_CLOSE_REASON);
    }

    async fn codex_restart_decision(&self) -> CodexRestart {
        if self.recovery_store.is_none() {
            return CodexRestart::NotOwner;
        }
        if self.prepared_handoff_is_durable().await {
            return CodexRestart::PreparedHandoff;
        }
        if codex_work_may_be_active(&*self.core.lock().await) {
            CodexRestart::Suspend
        } else {
            CodexRestart::Idle
        }
    }

    async fn suspend_codex_for_restart(&self) {
        let decision = self.codex_restart_decision().await;
        gateway_shutdown::suspend_codex(
            &self.codex,
            self.recovery_store.as_ref(),
            &self.journal,
            decision,
        )
        .await;
    }

    pub(super) async fn claude_suspended_turns(
        &self,
        thread_id: &str,
    ) -> Result<Vec<crate::providers::claude::restart::SuspendedTurn>> {
        self.claude_restart.suspended_turns(thread_id).await
    }

    async fn suspend_claude_for_restart(&self) {
        let Some(agent) = self.claude_agent() else {
            return;
        };
        self.claude_restart.capture_and_suspend(&agent).await;
    }

    pub(super) async fn claude_recovery_complete(&self) -> Result<bool> {
        Ok(!self.claude_restart.has_pending().await?
            && (!self.claude_settings.enabled
                || self.claude_recovery_ready.load(Ordering::Acquire)))
    }

    pub(super) async fn spawn_claude_restart_recovery(self: &Arc<Self>) {
        let gateway = Arc::clone(self);
        let task = tokio::spawn(async move { gateway.recover_claude_restart().await });
        *self.claude_recovery_task.lock().await = Some(task);
    }

    async fn recover_claude_restart(&self) {
        let agent = self.claude_agent();
        self.claude_restart
            .recover(agent.clone(), self.listening_receiver())
            .await;
        if let Some(agent) = agent
            && let Err(error) = agent.wait_for_notification_ingress().await
        {
            tracing::warn!(%error, "Claude recovery ingress unavailable");
            return;
        }
        self.claude_recovery_ready.store(true, Ordering::Release);
        self.activity.mark_changed();
        self.refresh_live_activity().await;
    }

    pub(super) async fn recover_restart_tasks(&self) -> Result<()> {
        let Some(store) = self.recovery_store.clone() else {
            self.core.lock().await.recovered_turn_keys.clear();
            return Ok(());
        };
        let journal = tokio::task::spawn_blocking({
            let store = store.clone();
            move || store.load()
        })
        .await
        .context("restart recovery journal read task failed")??;
        let Some(journal) = journal else {
            self.core.lock().await.recovered_turn_keys.clear();
            return Ok(());
        };
        if journal.phase == RecoveryPhase::Completed {
            self.core.lock().await.recovered_turn_keys.clear();
            return Ok(());
        }
        self.replace_recovered_turn_ownership(&journal).await;
        ensure!(
            journal.account.is_none(),
            "account recovery was opened on the default gateway"
        );
        if journal.phase == RecoveryPhase::Recovered {
            finish_before_ingress(self.codex.as_ref(), &store).await?;
            return Ok(());
        }
        if !matches!(
            journal.phase,
            RecoveryPhase::DaemonStarted | RecoveryPhase::Recovering
        ) {
            return Err(anyhow!(
                "restart recovery journal is in phase {:?}, not ready for gateway recovery",
                journal.phase
            ));
        }
        let generation_id = journal.generation_id.clone();
        let capability = journal.capability.clone();
        update_recovery_phase(
            store.clone(),
            generation_id.clone(),
            RecoveryPhase::Recovering,
            None,
        )
        .await?;

        let mut tasks = journal.pending_tasks().cloned().collect::<Vec<_>>();
        tasks.sort_by_key(|task| task.depth);
        let mut task_statuses = journal
            .tasks
            .iter()
            .map(|task| (task.thread_id.clone(), task.status))
            .collect::<HashMap<_, _>>();
        let mut retry_delay = Duration::from_millis(250);
        loop {
            let mut retryable_errors = Vec::new();
            for task in tasks {
                if let Some(parent_thread_id) = task.parent_thread_id.as_ref()
                    && let Some(parent_status) = task_statuses.get(parent_thread_id).copied()
                {
                    if parent_status == RecoveryTaskStatus::Failed {
                        let error = format!(
                            "parent recovery {parent_thread_id} failed before child {}",
                            task.thread_id
                        );
                        record_recovery_task_failure(
                            store.clone(),
                            generation_id.clone(),
                            task.thread_id.clone(),
                            task.turn_id,
                            false,
                            error,
                        )
                        .await?;
                        task_statuses.insert(task.thread_id.clone(), RecoveryTaskStatus::Failed);
                        if let Err(error) = self
                            .send_control_request_untracked(
                                "thread/unsubscribe",
                                serde_json::json!({"threadId": &task.thread_id}),
                            )
                            .await
                        {
                            warn!(%error, "failed to unsubscribe child of failed recovery parent");
                        }
                        continue;
                    }
                    if matches!(
                        parent_status,
                        RecoveryTaskStatus::Captured
                            | RecoveryTaskStatus::Suspended
                            | RecoveryTaskStatus::Retryable
                    ) {
                        let error = format!(
                            "waiting for parent recovery {parent_thread_id} before child {}",
                            task.thread_id
                        );
                        update_recovery_task(
                            store.clone(),
                            generation_id.clone(),
                            task.thread_id.clone(),
                            task.turn_id,
                            RecoveryTaskStatus::Retryable,
                            Some(error.clone()),
                        )
                        .await?;
                        task_statuses.insert(task.thread_id.clone(), RecoveryTaskStatus::Retryable);
                        retryable_errors.push(error);
                        continue;
                    }
                }
                let result = match self.load_external_thread(&task.thread_id).await {
                    Ok(()) => {
                        self.call_control(
                            "thread/restart/recover",
                            serde_json::json!({
                                "threadId": &task.thread_id,
                                "turnId": &task.turn_id,
                                "capability": &capability,
                            }),
                        )
                        .await
                    }
                    Err(error) => Err(error),
                };
                let status = match result {
                    Ok(result) => match recovery_status(
                        &result,
                        &generation_id,
                        &task.thread_id,
                        &task.turn_id,
                    ) {
                        Ok(status) => status,
                        Err(error) => {
                            let thread_id = task.thread_id;
                            record_recovery_task_failure(
                                store.clone(),
                                generation_id.clone(),
                                thread_id.clone(),
                                task.turn_id,
                                false,
                                error.to_string(),
                            )
                            .await?;
                            task_statuses.insert(thread_id.clone(), RecoveryTaskStatus::Failed);
                            if let Err(error) = self
                                .send_control_request_untracked(
                                    "thread/unsubscribe",
                                    serde_json::json!({"threadId": thread_id}),
                                )
                                .await
                            {
                                warn!(%error, "failed to unsubscribe invalid recovery thread");
                            }
                            continue;
                        }
                    },
                    Err(error) if recovery_control_error_is_unauthorized(&error) => {
                        return Err(error).context(
                            "restart generation authorization is unavailable; exact tasks remain pending and ingress stays fenced",
                        );
                    }
                    Err(error) if recovery_control_error_is_retryable(&error) => {
                        let message = error.to_string();
                        let status = record_recovery_task_failure(
                            store.clone(),
                            generation_id.clone(),
                            task.thread_id.clone(),
                            task.turn_id.clone(),
                            true,
                            message.clone(),
                        )
                        .await?;
                        if status == RecoveryTaskStatus::Retryable {
                            retryable_errors
                                .push(format!("{}:{}: {message}", task.thread_id, task.turn_id));
                        } else if let Err(error) = self
                            .send_control_request_untracked(
                                "thread/unsubscribe",
                                serde_json::json!({"threadId": &task.thread_id}),
                            )
                            .await
                        {
                            warn!(%error, "failed to unsubscribe exhausted recovery thread");
                        }
                        task_statuses.insert(task.thread_id.clone(), status);
                        continue;
                    }
                    Err(error) => {
                        record_recovery_task_failure(
                            store.clone(),
                            generation_id.clone(),
                            task.thread_id.clone(),
                            task.turn_id,
                            false,
                            error.to_string(),
                        )
                        .await?;
                        task_statuses.insert(task.thread_id.clone(), RecoveryTaskStatus::Failed);
                        if let Err(unsubscribe_error) = self
                            .send_control_request_untracked(
                                "thread/unsubscribe",
                                serde_json::json!({"threadId": &task.thread_id}),
                            )
                            .await
                        {
                            warn!(%unsubscribe_error, "failed to unsubscribe failed recovery thread");
                        }
                        continue;
                    }
                };
                let terminal = matches!(
                    status,
                    RecoveryTaskStatus::Completed | RecoveryTaskStatus::Failed
                );
                let thread_id = task.thread_id;
                update_recovery_task(
                    store.clone(),
                    generation_id.clone(),
                    thread_id.clone(),
                    task.turn_id,
                    status,
                    None,
                )
                .await?;
                task_statuses.insert(thread_id.clone(), status);
                if terminal
                    && let Err(error) = self
                        .send_control_request_untracked(
                            "thread/unsubscribe",
                            serde_json::json!({"threadId": thread_id}),
                        )
                        .await
                {
                    warn!(%error, "failed to unsubscribe terminal recovery thread");
                }
            }
            if retryable_errors.is_empty() {
                break;
            }
            let retryable_count = retryable_errors.len();
            let preview = retryable_errors
                .iter()
                .take(8)
                .cloned()
                .collect::<Vec<_>>()
                .join("; ");
            let omitted = retryable_count.saturating_sub(8);
            let message = if omitted == 0 {
                format!("{retryable_count} restart recovery task(s) remain retryable: {preview}")
            } else {
                format!(
                    "{retryable_count} restart recovery task(s) remain retryable: {preview}; and {omitted} more"
                )
            };
            warn!(retryable_count, "{message}");
            tokio::time::sleep(retry_delay).await;
            retry_delay = (retry_delay * 2).min(Duration::from_secs(5));
            let journal = tokio::task::spawn_blocking({
                let store = store.clone();
                move || store.load()
            })
            .await
            .context("restart recovery retry journal read task failed")??
            .context("restart recovery journal disappeared during retry")?;
            tasks = journal
                .tasks
                .into_iter()
                .filter(|task| task.status == RecoveryTaskStatus::Retryable)
                .collect();
            tasks.sort_by_key(|task| task.depth);
        }
        update_recovery_phase(store.clone(), generation_id, RecoveryPhase::Recovered, None).await?;
        let journal = tokio::task::spawn_blocking({
            let store = store.clone();
            move || store.load()
        })
        .await
        .context("restart recovery ownership journal read task failed")??
        .context("restart recovery journal disappeared before ownership refresh")?;
        self.replace_recovered_turn_ownership(&journal).await;
        finish_before_ingress(self.codex.as_ref(), &store).await?;
        Ok(())
    }

    async fn replace_recovered_turn_ownership(&self, journal: &RecoveryJournal) {
        self.core.lock().await.recovered_turn_keys = journal
            .pending_tasks()
            .map(|task| TurnKey::new(&task.thread_id, &task.turn_id))
            .collect();
    }

    pub(super) async fn record_restart_recovery_notification(self: &Arc<Self>, raw: &str) {
        let Some(store) = self.recovery_store.clone() else {
            return;
        };
        let Ok(message) = serde_json::from_str::<Value>(raw) else {
            return;
        };
        let Some(method) = message.get("method").and_then(Value::as_str) else {
            return;
        };
        let status = match method {
            "turn/started" => RecoveryTaskStatus::Running,
            "turn/completed" => {
                match message
                    .pointer("/params/turn/status")
                    .and_then(Value::as_str)
                {
                    Some("failed" | "interrupted") => RecoveryTaskStatus::Failed,
                    _ => RecoveryTaskStatus::Completed,
                }
            }
            _ => return,
        };
        let Some(thread_id) = message
            .pointer("/params/threadId")
            .and_then(Value::as_str)
            .map(str::to_string)
        else {
            return;
        };
        let Some(turn_id) = message
            .pointer("/params/turn/id")
            .or_else(|| message.pointer("/params/turnId"))
            .and_then(Value::as_str)
            .map(str::to_string)
        else {
            return;
        };
        let recovered_turn_key = TurnKey::new(&thread_id, &turn_id);
        let result = record_notification_status(store, thread_id.clone(), turn_id, status).await;
        if matches!(&result, Ok(true)) {
            let mut core = self.core.lock().await;
            if status == RecoveryTaskStatus::Running {
                core.recovered_turn_keys.insert(recovered_turn_key);
            } else if matches!(
                status,
                RecoveryTaskStatus::Completed | RecoveryTaskStatus::Failed
            ) {
                core.recovered_turn_keys.remove(&recovered_turn_key);
            }
        }
        match result {
            Err(error) => warn!(%error, "failed to persist restart recovery notification"),
            Ok(true)
                if matches!(
                    status,
                    RecoveryTaskStatus::Completed | RecoveryTaskStatus::Failed
                ) =>
            {
                let gateway = Arc::clone(self);
                tokio::spawn(async move {
                    if let Err(error) = gateway
                        .send_control_request_untracked(
                            "thread/unsubscribe",
                            serde_json::json!({"threadId": thread_id}),
                        )
                        .await
                    {
                        warn!(%error, "failed to unsubscribe terminal recovery thread");
                    }
                });
            }
            Ok(_) => {}
        }
    }
}

fn codex_work_may_be_active(core: &GatewayCoreState) -> bool {
    let is_codex = |thread_id: &str| !crate::providers::claude::is_claude_thread_id(thread_id);
    core.turns.active().any(|turn| is_codex(&turn.thread_id))
        || core
            .turns
            .pending()
            .any(|(_, pending)| is_codex(&pending.thread_id))
        || !core.app_server_active_turns_by_thread.is_empty()
        || !core.app_server_inventory_bootstrapped
        || !core.app_server_inventory_unresolved_threads.is_empty()
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use serde_json::json;
    use tokio::sync::mpsc;

    use super::*;
    use crate::agents::mcp::McpTokens;
    use crate::observability::journal::Journal;
    use crate::providers::claude::ClaudeSupervisor;
    use crate::providers::claude::restart::test_support::{SESSION, StubClaude, THREAD};
    use crate::providers::claude::restart::{ItemStatus, RecoveryAccount};
    use crate::providers::codex::daemon::CodexAppServer;
    use crate::rpc::RpcError;
    use crate::rpc::error::RpcCode;
    use crate::runtime::recovery::RecoveryStore;

    fn turn_key(thread_id: &str) -> TurnKey {
        TurnKey::new(thread_id, "turn-1")
    }

    fn mark_active(core: &mut GatewayCoreState, thread_id: &str) {
        core.turns
            .mark_active(&turn_key(thread_id), 0.0, None, Some(1));
    }

    #[test]
    fn only_possible_codex_work_requires_the_codex_handoff() {
        let mut core = GatewayCoreState {
            app_server_inventory_bootstrapped: true,
            ..GatewayCoreState::default()
        };
        assert!(!codex_work_may_be_active(&core));

        mark_active(&mut core, "claude_a");
        assert!(!codex_work_may_be_active(&core));

        mark_active(&mut core, "codex-a");
        assert!(codex_work_may_be_active(&core));

        core.turns.mark_inactive(&turn_key("claude_a"));
        core.turns.mark_inactive(&turn_key("codex-a"));
        core.app_server_inventory_bootstrapped = false;
        assert!(codex_work_may_be_active(&core));

        core.app_server_inventory_bootstrapped = true;
        core.app_server_inventory_unresolved_threads
            .insert("codex-b".to_owned());
        assert!(codex_work_may_be_active(&core));
    }

    #[tokio::test]
    async fn a_sigterm_without_a_prepared_handoff_suspends_possible_codex_work() {
        let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
        let directory = tempfile::tempdir().expect("state directory");
        let codex = Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        ));
        let gateway = Gateway::with_state_paths(
            codex,
            claude_test.settings.clone(),
            Journal::disabled(),
            Some(directory.path().join("active-codex-turns.json")),
            Some(directory.path().join("recovery.json")),
            None,
        );
        gateway.core.lock().await.app_server_inventory_bootstrapped = true;
        assert_eq!(gateway.codex_restart_decision().await, CodexRestart::Idle);

        mark_active(&mut *gateway.core.lock().await, "codex-a");
        assert_eq!(
            gateway.codex_restart_decision().await,
            CodexRestart::Suspend
        );

        let mut prepared = RecoveryJournal::new(
            "generation-1".to_owned(),
            "0123456789abcdef0123456789abcdef".to_owned(),
            Vec::new(),
        )
        .expect("recovery journal");
        prepared.phase = RecoveryPhase::DaemonStopped;
        RecoveryStore::new(directory.path().join("recovery.json"))
            .write(&prepared)
            .expect("prepared handoff");
        assert_eq!(
            gateway.codex_restart_decision().await,
            CodexRestart::PreparedHandoff
        );

        let account = Gateway::with_state_paths(
            Arc::new(CodexAppServer::new(
                PathBuf::from("/bin/true"),
                HashMap::new(),
            )),
            claude_test.settings.clone(),
            Journal::disabled(),
            Some(directory.path().join("account/active-codex-turns.json")),
            None,
            None,
        );
        assert_eq!(
            account.codex_restart_decision().await,
            CodexRestart::NotOwner
        );
    }

    #[tokio::test]
    async fn only_interruptions_during_shutdown_or_an_account_change_skip_the_completion_push() {
        let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
        let gateway = crate::test_support::TestGateway::with_settings(
            Arc::new(CodexAppServer::new(
                PathBuf::from("/bin/true"),
                HashMap::new(),
            )),
            claude_test.settings.clone(),
            Arc::new(claude_test),
        );
        let completion = |status: &str| {
            json!({
                "method": "turn/completed",
                "params": { "threadId": THREAD, "turn": { "id": "turn-1", "status": status } }
            })
        };

        assert!(!gateway.is_planned_interruption("turn/completed", &completion("interrupted")));
        gateway.draining.store(true, Ordering::Release);
        assert!(gateway.is_planned_interruption("turn/completed", &completion("interrupted")));
        assert!(!gateway.is_planned_interruption("turn/completed", &completion("completed")));
        assert!(!gateway.is_planned_interruption("turn/started", &completion("interrupted")));
    }

    async fn recovering_gateway(
        stub: &StubClaude,
    ) -> (
        Arc<Gateway>,
        Arc<ClaudeSupervisor>,
        tokio_util::task::AbortOnDropHandle<()>,
    ) {
        let gateway = Gateway::with_state_paths(
            Arc::new(CodexAppServer::new(
                PathBuf::from("/bin/true"),
                HashMap::new(),
            )),
            stub.settings.clone(),
            Journal::disabled(),
            Some(stub.turn_state_path()),
            None,
            None,
        );
        let (sender, events) = mpsc::channel(256);
        let agent = ClaudeSupervisor::new(
            gateway.claude_settings.clone(),
            sender,
            Journal::disabled(),
            McpTokens::default(),
        );
        gateway.set_claude_agent(Arc::clone(&agent));
        gateway.mark_listening();
        let owner = gateway.clone();
        let ingress = tokio::spawn(async move { owner.claude_notification_loop(events).await });
        (
            gateway,
            agent,
            tokio_util::task::AbortOnDropHandle::new(ingress),
        )
    }

    #[tokio::test]
    async fn recovery_after_a_crash_redelivers_only_what_history_lacks() {
        let stub = StubClaude::new();
        let delivered_session = "22222222-2222-4333-8444-555555555555";
        let missing_session = "33333333-2222-4333-8444-555555555555";
        let mut delivered = stub.item(delivered_session, ItemStatus::Dispatching);
        delivered.attempts = 1;
        stub.write_history(
            delivered_session,
            &format!(
                "{}\n",
                json!({"type": "user", "uuid": delivered.recovery_id})
            ),
        );
        let mut undelivered = stub.item(SESSION, ItemStatus::Dispatching);
        undelivered.attempts = 1;
        let unrecoverable = stub.item(missing_session, ItemStatus::Captured);
        let store = crate::providers::claude::restart::Store::beside(&stub.turn_state_path());
        store
            .write(
                &crate::providers::claude::restart::Journal::capture(
                    None,
                    vec![delivered, undelivered.clone(), unrecoverable],
                    None,
                )
                .unwrap(),
            )
            .unwrap();
        let (gateway, agent, _ingress) = recovering_gateway(&stub).await;

        Arc::clone(&gateway).recover_claude_restart().await;
        let launches = stub.wait_for_log("launches.jsonl", 1).await;
        let received = stub.wait_for_log("received.jsonl", 1).await;
        let resumed_turn = agent.active_turn_id(THREAD).await;
        agent.stop_all().await;

        assert_eq!(launches.len(), 1, "{launches:?}");
        assert!(
            launches[0]["argv"]
                .as_array()
                .unwrap()
                .windows(2)
                .any(|pair| pair == [json!("--resume"), json!(SESSION)])
        );
        assert_eq!(received.len(), 1);
        assert_eq!(received[0]["uuid"], json!(undelivered.recovery_id));
        assert!(resumed_turn.is_some());
        assert_eq!(store.load().unwrap(), None, "a settled journal is removed");
    }

    #[tokio::test]
    async fn recovery_refuses_a_journal_recorded_for_another_account() {
        let stub = StubClaude::new();
        let store = crate::providers::claude::restart::Store::beside(&stub.turn_state_path());
        store
            .write(
                &crate::providers::claude::restart::Journal::capture(
                    Some(RecoveryAccount {
                        id: "family".to_owned(),
                        generation: 4,
                    }),
                    vec![stub.item(SESSION, ItemStatus::Captured)],
                    None,
                )
                .unwrap(),
            )
            .unwrap();
        let (gateway, agent, _ingress) = recovering_gateway(&stub).await;

        Arc::clone(&gateway).recover_claude_restart().await;
        agent.stop_all().await;

        assert!(stub.log("launches.jsonl").is_empty());
        assert_eq!(store.load().unwrap(), None);
    }

    fn pending_restart(stub: &StubClaude, stop_generation: Option<u64>) {
        let mut item = stub.item(SESSION, ItemStatus::Captured);
        item.stop_generation = stop_generation;
        crate::providers::claude::restart::Store::beside(&stub.turn_state_path())
            .write(
                &crate::providers::claude::restart::Journal::capture(None, vec![item], None)
                    .unwrap(),
            )
            .unwrap();
    }

    #[tokio::test]
    async fn a_stop_naming_the_turn_a_restart_cut_off_cancels_its_pending_resume() {
        let stub = StubClaude::new();
        pending_restart(&stub, Some(0));
        let (gateway, agent, _ingress) = recovering_gateway(&stub).await;

        let other = gateway
            .stop_claude_turn(THREAD, "claude-turn-other")
            .await
            .unwrap_err();
        gateway
            .stop_claude_turn(THREAD, "claude-turn-1")
            .await
            .unwrap();
        Arc::clone(&gateway).recover_claude_restart().await;
        let ended = gateway
            .stop_claude_turn(THREAD, "claude-turn-1")
            .await
            .unwrap_err();
        agent.stop_all().await;

        assert_eq!(
            other,
            RpcError::new(
                RpcCode::InvalidRequest,
                "expected active turn id claude-turn-other but found claude-turn-1"
            )
        );
        assert!(stub.log("launches.jsonl").is_empty());
        assert_eq!(
            ended,
            RpcError::turn_not_running(
                "no active turn to interrupt",
                THREAD,
                Some("claude-turn-1")
            )
        );
    }

    #[tokio::test]
    async fn a_stop_naming_a_cut_off_turn_ends_the_resume_that_continues_it() {
        let stub = StubClaude::new();
        pending_restart(&stub, None);
        let (gateway, agent, _ingress) = recovering_gateway(&stub).await;

        let uncancellable = gateway
            .stop_claude_turn(THREAD, "claude-turn-1")
            .await
            .unwrap_err();
        Arc::clone(&gateway).recover_claude_restart().await;
        let resumed = agent.active_turn_id(THREAD).await.unwrap();
        gateway
            .stop_claude_turn(THREAD, "claude-turn-1")
            .await
            .unwrap();
        let after = agent.active_turn_id(THREAD).await;
        agent.stop_all().await;

        assert_eq!(uncancellable.code, RpcCode::Internal);
        assert_ne!(resumed, "claude-turn-1");
        assert_eq!(after, None);
        assert!(!agent.has_runtime(THREAD).await);
    }
}
