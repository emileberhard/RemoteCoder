use super::{
    RECOVERY_TIMEOUT, completed_journal_if_absent, ensure_gateway_running, random_hex,
    require_gateway_env, wait_for_phase,
};
use crate::config::HostPaths;
use crate::providers::codex::daemon::CodexAppServer;
use crate::runtime::bootstrap::{RuntimeLease, disable_remote_control, ensure_normal_daemon};
use crate::runtime::desktop::{reconcile_desktop, stop_desktop};
use crate::runtime::install::claude_state::ClaudeStateBackup;
use crate::runtime::install::package::{RuntimePaths, restore_previous_runtime};
use crate::runtime::install::{
    recover_through_temporary_gateway, wait_for_temporary_recovery_exit,
};
use crate::runtime::launchd::unload_gateway_launchagent;
use crate::runtime::recovery::{RecoveryJournal, RecoveryPhase, RecoveryStore, RecoveryTaskStatus};
use crate::runtime::rpc::{RpcClient, SuspendOutcome, SuspendResponse, snapshot_active_tasks};
use anyhow::{Context, Result, bail, ensure};
use std::path::Path;
use tracing::warn;

const PLANNED_HANDOFF_TICKET: &str = "gateway-launch-state/planned-handoff";

#[derive(Clone, Copy)]
pub(crate) struct RecoveryTransaction<'a> {
    pub(super) app_server: &'a CodexAppServer,
    pub(super) store: &'a RecoveryStore,
}

#[derive(Clone, Copy)]
pub(super) enum StoppedPreparation {
    Shutdown,
    Handoff,
}

#[derive(Clone, Copy, Eq, PartialEq)]
pub(super) enum RuntimeDestination {
    Running,
    Stopped,
}

impl<'a> RecoveryTransaction<'a> {
    pub(crate) fn new(app_server: &'a CodexAppServer, store: &'a RecoveryStore) -> Self {
        Self { app_server, store }
    }

    pub(super) async fn restart(&self) -> Result<()> {
        self.transition(RuntimeDestination::Running).await
    }

    pub(super) async fn retry_failed(&self, generation_id: &str) -> Result<()> {
        let original = self
            .store
            .load()?
            .context("restart recovery journal is missing")?;
        let mut journal = original.clone();
        ensure!(
            journal.generation_id == generation_id
                && journal.phase == RecoveryPhase::Completed
                && journal.account.is_none()
                && journal.runtime_swap.is_none(),
            "failed recovery retry requires the exact completed default generation without a pending runtime swap"
        );
        ensure!(
            journal
                .tasks
                .iter()
                .any(|task| task.status == RecoveryTaskStatus::Failed),
            "recovery generation has no failed tasks"
        );
        journal
            .package_identity
            .as_ref()
            .context("failed recovery has no bound package identity")?
            .verify(self.app_server.executable_path())?;
        self.app_server.verify_package_provenance().await?;
        self.app_server.run_lifecycle("prepare-restart").await?;
        let captured = async {
            let mut rpc = RpcClient::connect(self.app_server).await?;
            super::rpc::verify_failed_recovery_targets(&mut rpc, &journal).await?;
            journal.prepare_failed_retry(snapshot_active_tasks(&mut rpc).await?)
        }
        .await;
        match captured {
            Ok(()) => {}
            Err(error) => {
                return self.abort_failed_retry(&original, error).await;
            }
        }
        self.persist_failed_retry(&original, journal.clone())
            .await?;
        self.prepare_stopped_handoff(&journal).await?;
        self.reconcile().await?;
        let settled = self
            .store
            .load()?
            .context("retried recovery journal disappeared")?;
        ensure!(
            settled.generation_id == generation_id
                && !settled
                    .tasks
                    .iter()
                    .any(|task| task.status == RecoveryTaskStatus::Failed),
            "exact recovery retry settled with failed tasks; inspect the retained journal"
        );
        Ok(())
    }

    pub(super) async fn persist_failed_retry(
        &self,
        original: &RecoveryJournal,
        prepared: RecoveryJournal,
    ) -> Result<()> {
        let result = self.store.update(&original.generation_id, |current| {
            ensure!(
                current == original,
                "recovery state changed while preparing failed retry; no task was overwritten"
            );
            *current = prepared;
            Ok(())
        });
        match result {
            Ok(_) => Ok(()),
            Err(error) => self.abort_failed_retry(original, error).await,
        }
    }

    async fn abort_failed_retry(
        &self,
        original: &RecoveryJournal,
        error: anyhow::Error,
    ) -> Result<()> {
        match self.store.load() {
            Ok(Some(current))
                if current.generation_id == original.generation_id
                    && current.phase == RecoveryPhase::Completed
                    && current.capability == original.capability
                    && current.package_identity == original.package_identity
                    && current.runtime_swap == original.runtime_swap
                    && current.account == original.account =>
            {
                if let Err(cancellation) = self.app_server.run_lifecycle("cancel-restart").await {
                    return Err(error).context(format!(
                        "failed retry was not committed, but reopening admission failed: {cancellation:#}"
                    ));
                }
                Err(error).context("failed retry was not committed; original admission was restored")
            }
            Ok(_) => Err(error).context(
                "retry state changed or publication may have committed; admission remains fenced; run runtime reconcile with this candidate",
            ),
            Err(read_error) => Err(error).context(format!(
                "retry journal could not be reread ({read_error:#}); admission remains fenced; repair journal access and run runtime reconcile with this candidate"
            )),
        }
    }

    pub(super) async fn prepare_shutdown(&self) -> Result<()> {
        self.prepare_stopped(StoppedPreparation::Shutdown).await
    }

    pub(super) async fn prepare_handoff(&self) -> Result<()> {
        self.prepare_stopped(StoppedPreparation::Handoff).await
    }

    pub(crate) async fn prepare_handoff_for_shutdown(&self) -> Result<()> {
        let Some(_lease) = RuntimeLease::try_acquire(self.store)? else {
            bail!("another Codex runtime transaction holds the lease");
        };
        if let Some(journal) = self.store.load()?
            && journal.phase != RecoveryPhase::Completed
        {
            bail!(
                "unfinished Codex restart transaction {} must be recovered by the next bootstrap",
                journal.generation_id
            );
        }
        self.transition(RuntimeDestination::Stopped).await
    }

    async fn prepare_stopped(&self, preparation: StoppedPreparation) -> Result<()> {
        if self
            .store
            .load()?
            .is_some_and(|journal| journal.phase != RecoveryPhase::Completed)
        {
            self.reconcile().await?;
        }
        let result = self
            .transition(RuntimeDestination::Stopped)
            .await
            .and_then(|()| {
                if matches!(preparation, StoppedPreparation::Handoff) {
                    return self.record_planned_handoff();
                }
                let journal = self
                    .store
                    .load()?
                    .context("shutdown recovery journal disappeared after preparation")?;
                self.store.write_shutdown_marker(&journal.generation_id)
            });
        if let Err(error) = result {
            let operation = match preparation {
                StoppedPreparation::Shutdown => "shutdown preparation",
                StoppedPreparation::Handoff => "gateway handoff preparation",
            };
            return match self.reconcile().await {
                Ok(()) => Err(error).context(format!(
                    "{operation} failed; the normal daemon and Desktop state were restored"
                )),
                Err(recovery_error) => Err(error).context(format!(
                    "{operation} failed and restoring normal service also failed: {recovery_error:#}"
                )),
            };
        }
        Ok(())
    }

    fn record_planned_handoff(&self) -> Result<()> {
        let journal = self
            .store
            .load()?
            .context("gateway handoff journal disappeared after preparation")?;
        ensure!(
            journal.is_prepared_handoff(),
            "runtime prepare-handoff did not leave a stopped recovery generation"
        );
        write_planned_handoff_ticket(
            &HostPaths::from_env()?.state(PLANNED_HANDOFF_TICKET),
            &journal.generation_id,
        )
    }

    pub(super) async fn rollback(&self, env_file: Option<&Path>) -> Result<()> {
        self.restore_codex_state_before_recovery().await?;
        self.rollback_runtime(env_file).await?;
        self.restore_claude_state().await
    }

    async fn restore_codex_state_before_recovery(&self) -> Result<()> {
        let backup = ClaudeStateBackup::for_host()?;
        if !backup.has_codex_files()? {
            return Ok(());
        }
        if crate::accounts::codex_migration::is_committed(HostPaths::from_env()?.home())? {
            return backup.restore();
        }
        unload_gateway_launchagent().await?;
        super::control_owner::wait_for_control_owner_exit(
            self.store,
            super::install::RECOVERY_GATEWAY_EXIT_TIMEOUT,
        )
        .await?;
        if self.app_server.recorded_daemon_is_live().await? {
            if let Some(journal) = self.store.load()?
                && journal.phase != RecoveryPhase::Completed
            {
                self.app_server.run_lifecycle("prepare-restart").await?;
                self.store.update(&journal.generation_id, |current| {
                    for task in &mut current.tasks {
                        if matches!(
                            task.status,
                            RecoveryTaskStatus::Running
                                | RecoveryTaskStatus::Retryable
                                | RecoveryTaskStatus::Suspended
                        ) {
                            task.status = RecoveryTaskStatus::Captured;
                        }
                    }
                    current.phase = RecoveryPhase::Captured;
                    Ok(())
                })?;
                let mut rpc = RpcClient::connect(self.app_server).await?;
                super::accounts::finish_account_capture(
                    &mut rpc,
                    self.store,
                    &journal.generation_id,
                )
                .await?;
                drop(rpc);
                self.app_server.stop().await?;
                self.store
                    .set_phase(&journal.generation_id, RecoveryPhase::DaemonStopped)?;
            } else {
                self.restart_transaction(RuntimeDestination::Stopped)
                    .await?;
            }
        }
        backup.restore()
    }

    async fn restore_claude_state(&self) -> Result<()> {
        let backup = ClaudeStateBackup::for_host()?;
        if !backup.is_pending()? {
            return Ok(());
        }
        unload_gateway_launchagent().await?;
        super::control_owner::wait_for_control_owner_exit(
            self.store,
            super::install::RECOVERY_GATEWAY_EXIT_TIMEOUT,
        )
        .await?;
        backup.restore()
    }

    async fn rollback_runtime(&self, env_file: Option<&Path>) -> Result<()> {
        let Some(previous) = self.store.load()? else {
            return Ok(());
        };
        let Some(swap) = previous.runtime_swap.as_ref() else {
            if previous.phase == RecoveryPhase::Completed {
                return super::identity::release_source_journal_identities(
                    self.store,
                    HostPaths::from_env()?.home(),
                );
            }
            return self.rollback_unactivated(env_file).await;
        };
        ensure!(swap.had_current, "runtime rollback has no previous package");
        let paths = RuntimePaths::load()?;
        let previous_codex = super::install::package::previous_runtime_codex(&paths, swap)?;
        let source_identity = swap
            .source_identity
            .as_ref()
            .context("runtime rollback has no source package identity")?;
        source_identity.verify(&previous_codex)?;
        ensure!(
            previous.is_prepared_handoff() || previous.phase == RecoveryPhase::Completed,
            "rollback requires a completed or prepared Codex recovery generation"
        );
        let env = env_file.context("runtime rollback requires a gateway env file")?;
        require_gateway_env(env)?;
        stop_desktop(self.app_server, "rollback").await?;
        unload_gateway_launchagent().await?;
        let journal = self.store.load()?.context("rollback journal disappeared")?;
        let generation_id = if journal.is_prepared_handoff() {
            journal.generation_id
        } else if journal.phase == RecoveryPhase::Completed {
            self.restart_transaction(RuntimeDestination::Stopped)
                .await?;
            self.store
                .load()?
                .context("rollback handoff journal disappeared")?
                .generation_id
        } else {
            bail!("rollback requires a completed or prepared Codex recovery generation");
        };
        let journal = restore_previous_runtime(self.store, &generation_id, &paths)?;
        let source_server = CodexAppServer::for_runtime(
            paths.current.join("codex"),
            self.app_server.child_environment().clone(),
        )?;
        let recovery = RecoveryTransaction::new(&source_server, self.store);
        recovery.start_recovery_daemon(&journal).await?;
        source_server.verify_package_provenance().await?;
        let needs_gateway_recovery = journal.pending_tasks().next().is_some();
        if needs_gateway_recovery {
            let mut child = recover_through_temporary_gateway(
                env_file.context("rollback recovery requires a gateway env file")?,
                self.store,
                &generation_id,
                "rollback recovery remains fenced",
            )
            .await?;
            recovery.complete_recovery(&generation_id).await?;
            wait_for_temporary_recovery_exit(&mut child).await?;
        } else {
            recovery.complete_recovery(&generation_id).await?;
        }
        super::identity::release_source_journal_identities(
            self.store,
            HostPaths::from_env()?.home(),
        )
    }

    pub(super) async fn rollback_unactivated(&self, env_file: Option<&Path>) -> Result<()> {
        self.restore_codex_state_before_recovery().await?;
        self.rollback_unactivated_runtime(env_file).await?;
        self.restore_claude_state().await
    }

    async fn rollback_unactivated_runtime(&self, env_file: Option<&Path>) -> Result<()> {
        let mut journal = completed_journal_if_absent(self.store)?;
        if journal.phase == RecoveryPhase::Completed {
            ensure_normal_daemon(self.app_server).await?;
            return Ok(());
        }
        let env = env_file.context("unfinished rollback requires a gateway env file")?;
        require_gateway_env(env)?;
        stop_desktop(self.app_server, "rollback").await?;
        unload_gateway_launchagent().await?;
        self.prepare_incomplete_recovery(&journal).await?;
        journal = self
            .store
            .load()?
            .context("rollback recovery disappeared")?;
        let mut child = recover_through_temporary_gateway(
            env,
            self.store,
            &journal.generation_id,
            "unactivated rollback remains fenced",
        )
        .await?;
        self.complete_recovery(&journal.generation_id).await?;
        wait_for_temporary_recovery_exit(&mut child).await?;
        super::identity::release_source_journal_identities(
            self.store,
            HostPaths::from_env()?.home(),
        )
    }

    pub(super) async fn transition(&self, destination: RuntimeDestination) -> Result<()> {
        stop_desktop(self.app_server, "transition").await?;
        let result = self.restart_transaction(destination).await;
        if let Err(error) = result {
            let safe_to_reopen = self.store.load()?.is_none_or(|journal| {
                journal.phase == RecoveryPhase::Completed
                    || (journal.phase == RecoveryPhase::Captured
                        && journal
                            .tasks
                            .iter()
                            .all(|task| task.status == RecoveryTaskStatus::Captured))
            });
            if safe_to_reopen {
                let cancellation = self.app_server.run_lifecycle("cancel-restart").await;
                let journal_cleanup = if cancellation.is_ok() {
                    complete_aborted_capture(self.store)
                } else {
                    Ok(())
                };
                let relaunch = reconcile_desktop(self.app_server, "restart-abort").await;
                if let Err(cleanup_error) = cancellation.and(journal_cleanup).and(relaunch) {
                    return Err(error).context(format!(
                        "restart failed and safe ingress restoration also failed: {cleanup_error:#}"
                    ));
                }
            }
            return Err(error).context(if safe_to_reopen {
                "restart failed before ownership transfer; the old daemon was reopened"
            } else {
                "restart failed after ownership transfer; the system remains fenced with its recovery journal"
            });
        }
        Ok(())
    }

    pub(super) async fn restart_transaction(&self, destination: RuntimeDestination) -> Result<()> {
        let mut previous = self.store.load()?;
        if previous
            .as_ref()
            .is_some_and(|journal| journal.phase != RecoveryPhase::Completed)
        {
            self.reconcile()
                .await
                .context("unfinished restart transaction must reconcile before a new restart")?;
            previous = self.store.load()?;
        }
        let package_identity =
            super::identity::PackageIdentity::read(self.app_server.executable_path())?;
        self.app_server.verify_package_provenance().await?;
        self.app_server.run_lifecycle("prepare-restart").await?;
        let mut rpc = RpcClient::connect(self.app_server).await?;
        let tasks = snapshot_active_tasks(&mut rpc).await?;
        let generation_id = random_hex(16)?;
        let capability = random_hex(32)?;
        let mut journal = RecoveryJournal::new(generation_id.clone(), capability, tasks)?;
        journal.runtime_swap = previous.and_then(|journal| journal.runtime_swap);
        journal.package_identity = Some(package_identity);
        self.store.write(&journal)?;

        self.store
            .set_phase(&generation_id, RecoveryPhase::Suspending)?;
        suspend_captured_tasks(&mut rpc, self.store, &generation_id).await?;
        drop(rpc);

        self.app_server.stop().await?;
        let journal = self
            .store
            .set_phase(&generation_id, RecoveryPhase::DaemonStopped)?;

        if destination == RuntimeDestination::Stopped {
            return Ok(());
        }

        let needs_gateway_recovery = journal.pending_tasks().next().is_some();
        self.start_recovery_daemon(&journal).await?;

        if needs_gateway_recovery
            && let Err(error) = wait_for_gateway_recovery(self.store, &generation_id).await
        {
            return self.fail_recovery_closed(&generation_id, error).await;
        }
        self.complete_recovery(&generation_id).await
    }

    pub(super) async fn reconcile(&self) -> Result<()> {
        let Some(mut journal) = self.store.load()? else {
            ensure_normal_daemon(self.app_server).await?;
            reconcile_desktop(self.app_server, "reconcile").await?;
            return Ok(());
        };

        if !matches!(
            journal.phase,
            RecoveryPhase::DaemonStarted
                | RecoveryPhase::Recovering
                | RecoveryPhase::Recovered
                | RecoveryPhase::Completed
        ) {
            self.prepare_incomplete_recovery(&journal).await?;
            journal = self
                .store
                .load()?
                .context("recovery journal disappeared while reconciling")?;
        }
        if journal.phase == RecoveryPhase::Recovered {
            // The shared recovery owner distinguishes a confirmed dead daemon
            // from a live but temporarily unready one before changing turn state.
            self.prepare_incomplete_recovery(&journal).await?;
            journal = self
                .store
                .load()?
                .context("recovery journal disappeared after restarting a dead daemon")?;
        }

        match journal.phase {
            RecoveryPhase::DaemonStarted | RecoveryPhase::Recovering => {
                if let Err(error) =
                    wait_for_gateway_recovery(self.store, &journal.generation_id).await
                {
                    return self
                        .fail_recovery_closed(&journal.generation_id, error)
                        .await;
                }
            }
            RecoveryPhase::Recovered => {}
            RecoveryPhase::Completed => {
                ensure_normal_daemon(self.app_server).await?;
                reconcile_desktop(self.app_server, "reconcile").await?;
                return Ok(());
            }
            phase => bail!("recovery transaction cannot reconcile from phase {phase:?}"),
        }

        self.complete_recovery(&journal.generation_id).await
    }

    pub(super) async fn complete_recovery(&self, generation_id: &str) -> Result<()> {
        if let Err(error) = self.complete_recovery_inner(generation_id).await {
            return self.fail_recovery_closed(generation_id, error).await;
        }
        Ok(())
    }

    pub(super) async fn complete_recovery_inner(&self, generation_id: &str) -> Result<()> {
        // Only local daemon and turn recovery can keep admission fenced. Desktop
        // and the external relay have their own retry owners.
        let account_recovery = self
            .store
            .load()?
            .context("restart recovery journal disappeared")?
            .account
            .is_some();
        if account_recovery {
            self.app_server.verify_package_provenance().await?;
        }
        self.complete_native_finalization(generation_id).await?;
        if !account_recovery {
            disable_remote_control(self.app_server).await;
            if let Err(error) = reconcile_desktop(self.app_server, "recovery-complete").await {
                warn!(%error, "ChatGPT shared-daemon reconciliation was deferred");
            }
        }
        Ok(())
    }

    pub(super) async fn complete_native_finalization(&self, generation_id: &str) -> Result<()> {
        self.app_server.run_lifecycle("cancel-restart").await?;
        self.store.update(generation_id, |journal| {
            journal.phase = RecoveryPhase::Completed;
            journal.error = None;
            Ok(())
        })?;
        Ok(())
    }

    pub(super) async fn fail_recovery_closed(
        &self,
        generation_id: &str,
        error: anyhow::Error,
    ) -> Result<()> {
        let error_message = format!("{error:#}");
        let mut cleanup_errors = Vec::new();
        let loaded = self.store.load();
        if let Ok(Some(journal)) = &loaded
            && journal.generation_id == generation_id
            && matches!(
                journal.phase,
                RecoveryPhase::DaemonStarted
                    | RecoveryPhase::Recovering
                    | RecoveryPhase::Recovered
                    | RecoveryPhase::Completed
            )
            && journal.pending_tasks().next().is_some()
        {
            // A recovery-only gateway can exit after native exact resume already
            // started. Stopping that daemon and relabeling Running as Suspended is
            // not a native suspension and can replay external effects. Leave its
            // admission fence and original task states for same-target reconcile.
            if matches!(
                journal.phase,
                RecoveryPhase::Recovered | RecoveryPhase::Completed
            ) {
                // A cancel-restart reply may be lost after applying. Completion
                // may also have been published even when its directory sync
                // failed. Reclose admission without stopping exact native work.
                let fence_error = self.app_server.run_lifecycle("prepare-restart").await.err();
                let retry_error = if journal.phase == RecoveryPhase::Completed {
                    // A failed directory sync can leave the Completed rename
                    // visible after cancel-restart. Even if re-fencing fails, the
                    // exact generation must remain discoverable for account and
                    // default recovery rather than hiding behind Completed.
                    self.store
                        .update(generation_id, |current| {
                            ensure!(
                                current.phase == RecoveryPhase::Completed
                                    && current.pending_tasks().next().is_some(),
                                "recovery finalization state changed while re-fencing"
                            );
                            current.phase = RecoveryPhase::Recovered;
                            current.error = Some(format!("completion uncertain: {error_message}"));
                            Ok(())
                        })
                        .err()
                } else {
                    None
                };
                if let Some(fence_error) = fence_error {
                    let retry_context = retry_error
                        .as_ref()
                        .map(|write_error| {
                            format!("; retryable state could not be persisted: {write_error:#}")
                        })
                        .unwrap_or_default();
                    if matches!(self.app_server.recorded_daemon_is_live().await, Ok(false)) {
                        return Err(error).context(format!(
                            "recorded Codex daemon died during finalization; exact generation needs runtime reconcile{retry_context}"
                        ));
                    }
                    return Err(error).context(format!(
                        "native exact recovery may still be running; admission re-fence is unconfirmed and daemon was preserved: {fence_error:#}{retry_context}"
                    ));
                }
                if let Some(write_error) = retry_error {
                    return Err(error).context(format!(
                        "native exact work was preserved and admission re-fenced, but retryable recovery state could not be persisted: {write_error:#}"
                    ));
                }
            }
            return Err(error).context(
                "native exact recovery may still be running; default daemon remains fenced",
            );
        }
        let is_account = match loaded {
            Ok(Some(journal)) => journal.account.is_some(),
            Ok(None) => false,
            Err(lookup_error) => {
                cleanup_errors.push(format!("reading recovery journal failed: {lookup_error:#}"));
                false
            }
        };
        if !is_account
            && let Err(cleanup_error) = stop_desktop(self.app_server, "recovery-failed").await
        {
            cleanup_errors.push(format!("stopping ChatGPT failed: {cleanup_error:#}"));
        }
        let daemon_stopped = match self.app_server.stop().await {
            Ok(_) => true,
            Err(cleanup_error) => {
                cleanup_errors.push(format!(
                    "stopping the replacement Codex daemon failed: {cleanup_error:#}"
                ));
                false
            }
        };
        let journal_update = self.store.update(generation_id, |journal| {
            mark_recovery_failed_closed(journal, daemon_stopped, &error_message);
            Ok(())
        });
        if let Err(cleanup_error) = journal_update {
            cleanup_errors.push(format!(
                "recording the fail-closed recovery state failed: {cleanup_error:#}"
            ));
        }

        if cleanup_errors.is_empty() {
            Err(error).context(
                "replacement recovery failed; ChatGPT and the replacement daemon were stopped",
            )
        } else {
            Err(error).context(format!(
                "replacement recovery failed and fail-closed cleanup was incomplete: {}",
                cleanup_errors.join("; ")
            ))
        }
    }
}

pub(super) fn complete_aborted_capture(store: &RecoveryStore) -> Result<()> {
    let Some(journal) = store.load()? else {
        return Ok(());
    };
    if journal.phase != RecoveryPhase::Captured
        || journal
            .tasks
            .iter()
            .any(|task| task.status != RecoveryTaskStatus::Captured)
    {
        return Ok(());
    }
    store.update(&journal.generation_id, |journal| {
        journal.phase = RecoveryPhase::Completed;
        journal.error = Some("restart aborted before ownership transfer".to_string());
        Ok(())
    })?;
    Ok(())
}

pub(super) async fn suspend_captured_tasks(
    rpc: &mut RpcClient,
    store: &RecoveryStore,
    generation_id: &str,
) -> Result<()> {
    let mut tasks = store
        .load()?
        .context("recovery journal disappeared during suspension")?
        .tasks;
    tasks.sort_by_key(|task| std::cmp::Reverse(task.depth));
    for mut task in tasks
        .into_iter()
        .filter(|task| task.status == RecoveryTaskStatus::Captured)
    {
        let mut recaptured_turn = false;
        let (task_status, task_error) = loop {
            let response: SuspendResponse = rpc
                .request(
                    "thread/restart/suspend",
                    serde_json::json!({
                        "threadId": &task.thread_id,
                        "turnId": &task.turn_id,
                    }),
                )
                .await?;
            match response.outcome {
                SuspendOutcome::Suspended { turn_id } => {
                    break if turn_id == task.turn_id {
                        (RecoveryTaskStatus::Suspended, None)
                    } else {
                        (
                            RecoveryTaskStatus::Failed,
                            Some(format!(
                                "thread {} suspended unexpected turn {turn_id}",
                                task.thread_id
                            )),
                        )
                    };
                }
                SuspendOutcome::NotActive => {
                    break (RecoveryTaskStatus::Completed, None);
                }
                SuspendOutcome::TurnChanged { actual_turn_id } if !recaptured_turn => {
                    let previous_turn_id = std::mem::replace(&mut task.turn_id, actual_turn_id);
                    store.update(generation_id, |journal| {
                        let persisted = journal
                            .tasks
                            .iter_mut()
                            .find(|persisted| persisted.thread_id == task.thread_id)
                            .context("captured recovery task disappeared")?;
                        persisted.turn_id.clone_from(&task.turn_id);
                        persisted.error = Some(format!(
                            "recaptured turn {} after captured turn {previous_turn_id} changed",
                            task.turn_id
                        ));
                        Ok(())
                    })?;
                    recaptured_turn = true;
                }
                SuspendOutcome::TurnChanged { actual_turn_id } => {
                    break (
                        RecoveryTaskStatus::Failed,
                        Some(format!(
                            "thread {} changed again from turn {} to {actual_turn_id} during a settled restart fence",
                            task.thread_id, task.turn_id,
                        )),
                    );
                }
                SuspendOutcome::HasLiveDescendants => {
                    break (
                        RecoveryTaskStatus::Failed,
                        Some(format!(
                            "thread {} still has active descendants after leaf-first suspension",
                            task.thread_id
                        )),
                    );
                }
                SuspendOutcome::UnsupportedTask => {
                    break (
                        RecoveryTaskStatus::Failed,
                        Some(format!(
                            "thread {} is not a recoverable regular turn",
                            task.thread_id
                        )),
                    );
                }
            }
        };
        store.update(generation_id, |journal| {
            let persisted = journal
                .tasks
                .iter_mut()
                .find(|persisted| persisted.thread_id == task.thread_id)
                .context("captured recovery task disappeared")?;
            persisted.update_status(task_status, task_error);
            Ok(())
        })?;
    }
    store.set_phase(generation_id, RecoveryPhase::Suspended)?;
    Ok(())
}

async fn wait_for_gateway_recovery(store: &RecoveryStore, generation_id: &str) -> Result<()> {
    ensure_gateway_running().await?;
    wait_for_phase(
        store,
        generation_id,
        RecoveryPhase::Recovered,
        RECOVERY_TIMEOUT,
    )
    .await
}

pub(super) fn mark_recovery_failed_closed(
    journal: &mut RecoveryJournal,
    daemon_stopped: bool,
    error: &str,
) {
    if daemon_stopped {
        for task in &mut journal.tasks {
            if matches!(
                task.status,
                RecoveryTaskStatus::Captured
                    | RecoveryTaskStatus::Suspended
                    | RecoveryTaskStatus::Retryable
                    | RecoveryTaskStatus::Running
            ) {
                task.status = RecoveryTaskStatus::Suspended;
            }
        }
        journal.phase = if journal.account.is_some()
            && journal.package_identity.is_some()
            && matches!(
                journal.phase,
                RecoveryPhase::RuntimeInstalled
                    | RecoveryPhase::DaemonStarted
                    | RecoveryPhase::Recovering
                    | RecoveryPhase::Recovered
                    | RecoveryPhase::Completed
            ) {
            RecoveryPhase::RuntimeInstalled
        } else {
            RecoveryPhase::DaemonStopped
        };
    }
    journal.error = Some(format!("recovery failed closed: {error}"));
}

pub(super) fn write_planned_handoff_ticket(path: &Path, generation_id: &str) -> Result<()> {
    let directory = path
        .parent()
        .context("planned handoff ticket has no parent directory")?;
    crate::storage::private_state::ensure_private_directory(directory)?;
    crate::storage::private_state::replace(path, generation_id.as_bytes())
}
