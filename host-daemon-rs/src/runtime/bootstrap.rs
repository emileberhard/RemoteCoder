use super::{LEASE_WAIT_TIMEOUT, write_grant};
use crate::config::Settings;
use crate::providers::codex::daemon::CodexAppServer;
use crate::runtime::recovery::{RecoveryJournal, RecoveryPhase, RecoveryStore, RecoveryTaskStatus};
use crate::runtime::rpc::RpcClient;
use crate::runtime::transaction::{RecoveryTransaction, suspend_captured_tasks};
use anyhow::{Context, Result, bail, ensure};
use std::fs::File;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::time::Duration;
use tracing::warn;

pub(crate) async fn bootstrap(settings: &Settings, recovery_only: bool) -> Result<()> {
    let app_server = if recovery_only {
        CodexAppServer::for_runtime(
            settings.codex_path.clone(),
            settings.codex_child_env.clone(),
        )?
    } else {
        CodexAppServer::new(
            settings.codex_path.clone(),
            settings.codex_child_env.clone(),
        )
    };
    let store = RecoveryStore::new(RecoveryStore::default_path()?);
    let _lease = acquire_bootstrap_lease(&app_server, &store, recovery_only).await?;
    if _lease.is_none() {
        app_server.verify_ready().await?;
        app_server.verify_package_provenance().await?;
        return Ok(());
    }
    app_server.prepare_selected_package()?;
    match store.load()? {
        Some(journal) if journal.phase != RecoveryPhase::Completed => {
            RecoveryTransaction::new(&app_server, &store)
                .prepare_incomplete_recovery(&journal)
                .await?;
        }
        _ => ensure_normal_daemon(&app_server).await?,
    }
    app_server.verify_ready().await?;
    app_server.verify_package_provenance().await?;
    Ok(())
}

async fn acquire_bootstrap_lease(
    app_server: &CodexAppServer,
    store: &RecoveryStore,
    recovery_only: bool,
) -> Result<Option<RuntimeLease>> {
    let deadline = tokio::time::Instant::now() + LEASE_WAIT_TIMEOUT;
    loop {
        if let Some(lease) = RuntimeLease::try_acquire(store)? {
            return Ok(Some(lease));
        }
        if store.load()?.is_some_and(|journal| {
            matches!(
                journal.phase,
                RecoveryPhase::DaemonStarted | RecoveryPhase::Recovering
            ) || recovery_only
                && matches!(
                    journal.phase,
                    RecoveryPhase::Recovered | RecoveryPhase::Completed
                )
        }) && app_server.verify_ready().await.is_ok()
        {
            // The runtime owner deliberately holds the lease while this gateway
            // reconnects and recovers tasks. Starting the control loop is the
            // progress mechanism, not a competing lifecycle mutation.
            return Ok(None);
        }
        if tokio::time::Instant::now() >= deadline {
            bail!("timed out waiting for the Codex runtime transaction lease");
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

pub(super) async fn wait_for_runtime_lease(store: &RecoveryStore) -> Result<RuntimeLease> {
    let deadline = tokio::time::Instant::now() + LEASE_WAIT_TIMEOUT;
    loop {
        if let Some(lease) = RuntimeLease::try_acquire(store)? {
            return Ok(lease);
        }
        if tokio::time::Instant::now() >= deadline {
            bail!("timed out waiting for the Codex runtime transaction lease");
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

pub(crate) async fn finish_orphaned_recovery(
    app_server: &CodexAppServer,
    store: &RecoveryStore,
) -> Result<bool> {
    let Some(_lease) = RuntimeLease::try_acquire(store)? else {
        return Ok(false);
    };
    let Some(journal) = store.load()? else {
        return Ok(false);
    };
    if journal.phase != RecoveryPhase::Recovered || app_server.verify_ready().await.is_err() {
        return Ok(false);
    }
    if journal.account.is_some() {
        app_server.verify_package_provenance().await?;
    }
    RecoveryTransaction::new(app_server, store)
        .complete_recovery(&journal.generation_id)
        .await?;
    Ok(true)
}

pub(super) struct RuntimeLease {
    file: File,
}

impl Drop for RuntimeLease {
    fn drop(&mut self) {
        let _ = self.file.unlock();
    }
}

impl RuntimeLease {
    pub(super) fn acquire(store: &RecoveryStore) -> Result<Self> {
        Self::try_acquire(store)?.context("another Codex runtime transaction is active")
    }

    pub(super) fn try_acquire(store: &RecoveryStore) -> Result<Option<Self>> {
        let path = store.path().with_extension("transaction.lock");
        let parent = path.parent().context("transaction lock has no parent")?;
        std::fs::create_dir_all(parent)?;
        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
        let file = std::fs::OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOFOLLOW)
            .mode(0o600)
            .open(&path)
            .with_context(|| format!("failed to open {}", path.display()))?;
        match file.try_lock() {
            Ok(()) => {}
            Err(std::fs::TryLockError::WouldBlock) => return Ok(None),
            Err(std::fs::TryLockError::Error(error)) => {
                return Err(error).with_context(|| format!("failed to lock {}", path.display()));
            }
        }
        Ok(Some(Self { file }))
    }
}

pub(super) async fn ensure_normal_daemon(app_server: &CodexAppServer) -> Result<()> {
    if app_server.verify_ready().await.is_err() {
        app_server.run_lifecycle("start").await?;
    }
    // A runtime owner can die after closing admission but before creating its
    // journal. Reopening an unfenced daemon is idempotent and closes that gap.
    app_server.run_lifecycle("cancel-restart").await?;
    enable_remote_control(app_server).await;
    Ok(())
}

pub(super) async fn enable_remote_control(app_server: &CodexAppServer) {
    if let Err(error) = app_server.set_remote_control_enabled(true).await {
        warn!(%error, "Codex remote control remains degraded and will retry independently");
    }
}

impl RecoveryTransaction<'_> {
    pub(super) async fn prepare_incomplete_recovery(
        &self,
        journal: &RecoveryJournal,
    ) -> Result<()> {
        match journal.phase {
            RecoveryPhase::Captured | RecoveryPhase::Suspending | RecoveryPhase::Suspended => {
                self.prepare_stopped_handoff(journal).await?;
            }
            RecoveryPhase::DaemonStopped | RecoveryPhase::RuntimeInstalled => {}
            RecoveryPhase::DaemonStarted | RecoveryPhase::Recovering | RecoveryPhase::Recovered => {
                if journal.account.is_some()
                    && let Some(identity) = &journal.package_identity
                {
                    identity
                        .verify(self.app_server.executable_path())
                        .with_context(|| {
                            format!(
                                "account recovery generation {} changed its bound target package",
                                journal.generation_id
                            )
                        })?;
                }
                let readiness = self.app_server.verify_ready().await;
                if readiness.is_ok() {
                    return Ok(());
                }
                if self.app_server.recorded_daemon_is_live().await? {
                    return Err(readiness.expect_err("readiness was checked above")).context(
                        format!(
                            "recorded Codex daemon is live but not ready; exact recovery generation {} remains unchanged",
                            journal.generation_id
                        ),
                    );
                }
                self.store.update(&journal.generation_id, |journal| {
                    for task in &mut journal.tasks {
                        if matches!(
                            task.status,
                            RecoveryTaskStatus::Captured
                                | RecoveryTaskStatus::Retryable
                                | RecoveryTaskStatus::Running
                        ) {
                            task.status = RecoveryTaskStatus::Suspended;
                        }
                    }
                    journal.phase =
                        if journal.account.is_some() && journal.package_identity.is_some() {
                            RecoveryPhase::RuntimeInstalled
                        } else {
                            RecoveryPhase::DaemonStopped
                        };
                    Ok(())
                })?;
            }
            RecoveryPhase::Completed => return ensure_normal_daemon(self.app_server).await,
        }

        let journal = self
            .store
            .load()?
            .context("recovery journal disappeared before daemon startup")?;
        self.start_recovery_daemon(&journal).await
    }

    pub(super) async fn prepare_stopped_handoff(&self, journal: &RecoveryJournal) -> Result<()> {
        match journal.phase {
            RecoveryPhase::Captured | RecoveryPhase::Suspending => {
                if self.app_server.verify_ready().await.is_ok() {
                    // Reissuing an exact suspension is idempotent. A lost reply or
                    // failed status write must never turn a suspended turn into an
                    // apparently untouched capture that can reopen admission.
                    self.app_server.run_lifecycle("prepare-restart").await?;
                    if journal.phase == RecoveryPhase::Captured {
                        self.store
                            .set_phase(&journal.generation_id, RecoveryPhase::Suspending)?;
                    }
                    let mut rpc = RpcClient::connect(self.app_server).await?;
                    suspend_captured_tasks(&mut rpc, self.store, &journal.generation_id).await?;
                    drop(rpc);
                    self.app_server.stop().await?;
                } else {
                    self.finish_dead_source_capture(journal).await?;
                }
            }
            RecoveryPhase::Suspended => {
                if self.app_server.verify_ready().await.is_ok() {
                    self.app_server.stop().await?;
                }
            }
            RecoveryPhase::DaemonStopped => return Ok(()),
            phase => bail!("runtime cannot prepare a stopped handoff from phase {phase:?}"),
        }
        self.store
            .set_phase(&journal.generation_id, RecoveryPhase::DaemonStopped)?;
        Ok(())
    }

    pub(super) async fn finish_dead_source_capture(&self, journal: &RecoveryJournal) -> Result<()> {
        if journal.tasks.iter().all(|task| {
            matches!(
                task.status,
                RecoveryTaskStatus::Suspended | RecoveryTaskStatus::Completed
            )
        }) {
            return Ok(());
        }
        // The source died after capture or during an RPC. Restart it without
        // admission, then ask native to resolve each exact turn from persisted
        // state. A lost reply can be reissued safely on the next reconcile.
        self.app_server
            .run_lifecycle_with_env(
                "start",
                &[("CODEX_APP_SERVER_START_FENCED", std::ffi::OsStr::new("1"))],
            )
            .await?;
        self.app_server.run_lifecycle("prepare-restart").await?;
        if journal.phase == RecoveryPhase::Captured {
            self.store
                .set_phase(&journal.generation_id, RecoveryPhase::Suspending)?;
        }
        let mut rpc = RpcClient::connect(self.app_server).await?;
        suspend_captured_tasks(&mut rpc, self.store, &journal.generation_id).await?;
        drop(rpc);
        self.app_server.stop().await?;
        Ok(())
    }

    pub(super) async fn start_recovery_daemon(&self, journal: &RecoveryJournal) -> Result<()> {
        if journal.pending_tasks().next().is_none() {
            if let Err(error) = self.app_server.run_lifecycle("start").await {
                return self
                    .fail_recovery_closed(&journal.generation_id, error)
                    .await;
            }
            if let Err(error) = self.store.update(&journal.generation_id, |journal| {
                journal.phase = RecoveryPhase::Recovered;
                journal.error = None;
                Ok(())
            }) {
                return self
                    .fail_recovery_closed(&journal.generation_id, error)
                    .await;
            }
            return Ok(());
        }

        ensure!(
            !self.app_server.recorded_daemon_is_live().await?,
            "recovery grant requires a stopped daemon; an existing daemon cannot load startup authorization"
        );
        let grant_path = write_grant(self.store.path(), journal)?;
        let result = self
            .app_server
            .run_lifecycle_with_env(
                "start",
                &[
                    ("CODEX_APP_SERVER_START_FENCED", std::ffi::OsStr::new("1")),
                    (
                        "CODEX_INTERNAL_RESTART_RECOVERY_GRANT_FILE",
                        grant_path.as_os_str(),
                    ),
                ],
            )
            .await;
        let _ = std::fs::remove_file(&grant_path);
        if let Err(error) = result {
            return self
                .fail_recovery_closed(&journal.generation_id, error)
                .await;
        }
        if let Err(error) = self.store.update(&journal.generation_id, |journal| {
            journal.phase = RecoveryPhase::DaemonStarted;
            journal.error = None;
            Ok(())
        }) {
            return self
                .fail_recovery_closed(&journal.generation_id, error)
                .await;
        }
        Ok(())
    }
}
