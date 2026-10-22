use super::{RECOVERY_TIMEOUT, require_gateway_env, wait_for_phase};
use crate::config::{ConfigSources, HostPaths};
use crate::runtime::bootstrap::ensure_normal_daemon;
use crate::runtime::desktop::{reconcile_desktop, stop_desktop};
use crate::runtime::install::package::{
    RuntimePaths, StagedRuntime, activate_staged_runtime, sha256_file, stage_runtime_package,
};
use crate::runtime::launchd::{
    gateway_launchagent_is_loaded, restore_gateway_launchagent, unload_gateway_launchagent,
};
use crate::runtime::recovery::{RecoveryJournal, RecoveryPhase, RecoveryStore};
use crate::runtime::rpc::{RpcClient, snapshot_active_tasks};
use crate::runtime::transaction::{RecoveryTransaction, RuntimeDestination};
use anyhow::{Context, Result, bail};
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command as TokioCommand;

mod bundle;
pub(crate) mod call_worker;
pub(crate) mod claude_state;
pub(super) mod package;
pub(crate) mod pair;
pub(crate) mod staging;
pub(super) mod transaction;
pub(super) mod uninstall;

pub(super) const RECOVERY_GATEWAY_EXIT_TIMEOUT: Duration = Duration::from_secs(15);

pub(super) async fn install(
    recovery: RecoveryTransaction<'_>,
    package_dir: &Path,
    env_file: Option<&Path>,
) -> Result<()> {
    let RecoveryTransaction { app_server, store } = recovery;
    let prepared_on_entry = store
        .load()?
        .is_some_and(|journal| journal.is_prepared_handoff());
    let source_codex = match RuntimePaths::load() {
        Ok(paths) => paths.current.join("codex"),
        Err(error) if prepared_on_entry => {
            return restore_prepared_entry_after_error(recovery, env_file, error).await;
        }
        Err(error) => return Err(error),
    };
    let source_identity = if prepared_on_entry {
        match sha256_file(&source_codex) {
            Ok(identity) => Some(identity),
            Err(error) => {
                return restore_prepared_entry_after_error(recovery, env_file, error).await;
            }
        }
    } else {
        None
    };
    if !prepared_on_entry {
        if !app_server.recorded_daemon_is_live().await? {
            app_server.run_lifecycle("start").await?;
        }
        app_server.verify_identity().await?;
    }
    let staged = match stage_runtime_package(package_dir) {
        Ok(staged) => staged,
        Err(error) if prepared_on_entry => {
            let journal = store
                .load()
                .context("prepared handoff journal became unreadable; ingress remains fenced")?;
            if journal.as_ref().is_some_and(|journal| {
                journal.phase != RecoveryPhase::Completed && journal.runtime_swap.is_none()
            }) && source_identity.as_deref() == Some(sha256_file(&source_codex)?.as_str())
            {
                return restore_prepared_entry_after_error(recovery, env_file, error).await;
            }
            return Err(error).context("candidate staging failed after source identity changed; exact recovery remains fenced");
        }
        Err(error) => return Err(error),
    };
    let result = install_version_matched_runtime(recovery, &staged, env_file).await;
    if staged.path.exists() {
        let _ = std::fs::remove_dir_all(&staged.path);
    }
    result
}

async fn restore_prepared_entry_after_error(
    recovery: RecoveryTransaction<'_>,
    env_file: Option<&Path>,
    error: anyhow::Error,
) -> Result<()> {
    match recovery.rollback_unactivated(env_file).await {
        Ok(()) => {
            claude_state::ClaudeStateBackup::for_host()?.restore()?;
            restore_gateway_launchagent(true).await?;
            Err(error).context(
                "candidate install failed before activation; prepared source handoff was recovered",
            )
        }
        Err(recovery_error) => Err(error).context(format!(
            "candidate install failed; exact prepared handoff remains fenced: {recovery_error:#}"
        )),
    }
}

async fn install_version_matched_runtime(
    recovery: RecoveryTransaction<'_>,
    staged: &StagedRuntime,
    env_file: Option<&Path>,
) -> Result<()> {
    let RecoveryTransaction { app_server, store } = recovery;
    let existing = store.load()?;
    if existing
        .as_ref()
        .is_some_and(|journal| journal.runtime_swap.is_some())
    {
        bail!("commit or roll back the previous runtime before another install");
    }
    let prepared_handoff = existing
        .as_ref()
        .is_some_and(RecoveryJournal::is_prepared_handoff);
    if !prepared_handoff
        && existing
            .as_ref()
            .is_some_and(|journal| journal.phase != RecoveryPhase::Completed)
    {
        recovery
            .reconcile()
            .await
            .context("unfinished restart transaction must reconcile before an upgrade")?;
    }
    let preflight = async {
        let source_codex_path = staged.paths.current.join("codex");
        let source_sha256 = sha256_file(&source_codex_path)?;
        if !prepared_handoff && app_server.verify_ready().await.is_ok() {
            let mut rpc = RpcClient::connect(app_server).await?;
            snapshot_active_tasks(&mut rpc).await?;
        }
        let env = env_file.context("recoverable runtime cutover requires a gateway env file")?;
        require_gateway_env(env)?;
        Ok::<_, anyhow::Error>((source_codex_path, source_sha256))
    }
    .await;
    let (source_codex_path, source_sha256) = match preflight {
        Ok(values) => values,
        Err(error) if prepared_handoff => {
            // A launchctl read failure must not skip recovery of the already
            // prepared native handoff. Prefer restoring ingress after success.
            let gateway_was_loaded = gateway_launchagent_is_loaded().await.unwrap_or(true);
            return match recovery.rollback_unactivated(env_file).await {
                Ok(()) => {
                    claude_state::ClaudeStateBackup::for_host()?.restore()?;
                    restore_gateway_launchagent(gateway_was_loaded).await?;
                    Err(error).context("candidate preflight failed; prepared source handoff was recovered")
                }
                Err(rollback_error) => Err(error).context(format!(
                    "candidate preflight failed; prepared source handoff remains fenced: {rollback_error:#}"
                )),
            };
        }
        Err(error) => return Err(error),
    };
    // The installed gateway may have prepared the default handoff before this
    // process began. Every failure through account capture is still before
    // package activation and must attempt the same source-bound rollback.
    let gateway_was_loaded = gateway_launchagent_is_loaded().await.unwrap_or(true);
    let preparation = async {
        stop_desktop("install").await?;
        unload_gateway_launchagent().await?;
        let prepared = store
            .load()?
            .as_ref()
            .is_some_and(RecoveryJournal::is_prepared_handoff);
        if !prepared {
            recovery
                .restart_transaction(RuntimeDestination::Stopped)
                .await?;
        }
        Ok::<_, anyhow::Error>(())
    }
    .await;
    match preparation {
        Ok(()) => {}
        Err(error) => {
            let rollback = restore_source_before_activation(recovery, env_file).await;
            return match rollback {
                Ok(()) => {
                    claude_state::ClaudeStateBackup::for_host()?.restore()?;
                    restore_gateway_launchagent(gateway_was_loaded).await?;
                    Err(error).context("pre-activation runtime preparation failed; source runtime was restored")
                }
                Err(rollback_error) => Err(error).context(format!(
                    "pre-activation runtime preparation failed; candidate-owned rollback remains fenced: {rollback_error:#}"
                )),
            };
        }
    };
    // The previous runtime already durably suspended every active turn.
    // Preserve that generation through activation. The installed gateway
    // belongs to the old runtime, so the candidate temporarily owns the
    // recovery connection until its tracked installation takes over.
    let result = prepared_handoff_install_transaction(recovery, staged, env_file).await;
    if result.is_err()
        && store
            .load()?
            .is_some_and(|journal| journal.runtime_swap.is_none())
        && sha256_file(&source_codex_path)? == source_sha256
    {
        let rollback = restore_source_before_activation(recovery, env_file).await;
        return match rollback {
            Ok(()) => {
                claude_state::ClaudeStateBackup::for_host()?.restore()?;
                restore_gateway_launchagent(gateway_was_loaded).await?;
                result.context("pre-activation runtime install failed; source runtime was restored")
            }
            Err(rollback_error) => result.context(format!(
                "pre-activation runtime install failed; candidate-owned rollback remains fenced: {rollback_error:#}"
            )),
        };
    }
    if result.is_err()
        && (store
            .load()?
            .is_some_and(|journal| journal.phase != RecoveryPhase::Completed))
    {
        return result.context("Codex recovery remains fenced; gateway restore was withheld");
    }
    let swap_pending = store
        .load()?
        .is_some_and(|journal| journal.runtime_swap.is_some());
    let gateway_restore = if swap_pending {
        Ok(())
    } else {
        claude_state::ClaudeStateBackup::for_host()?.restore()?;
        restore_gateway_launchagent(gateway_was_loaded).await
    };
    let result = match (result, gateway_restore) {
        (Ok(()), Ok(())) => Ok(()),
        (Ok(()), Err(error)) => Err(error).context("runtime upgraded but gateway restore failed"),
        (Err(error), Ok(())) => Err(error),
        (Err(error), Err(restore_error)) => Err(error).context(format!(
            "gateway restore also failed after the runtime transaction: {restore_error:#}"
        )),
    };
    if let Err(error) = result {
        let installed_server = crate::providers::codex::daemon::CodexAppServer::for_runtime(
            staged.paths.current.join("codex"),
            app_server.child_environment().clone(),
        )?;
        let restore = RecoveryTransaction::new(&installed_server, store)
            .reconcile()
            .await;
        match restore {
            Ok(())
                if store.load()?.is_some_and(|journal| {
                    journal.phase == RecoveryPhase::Completed && journal.runtime_swap.is_some()
                }) =>
            {
                Ok(())
            }
            Ok(()) => Err(error).context(
                "version upgrade failed; the managed daemon and Desktop state were restored",
            ),
            Err(recovery_error) => Err(error).context(format!(
                "version upgrade failed and restoring service also failed: {recovery_error:#}"
            )),
        }
    } else {
        Ok(())
    }
}

async fn prepared_handoff_install_transaction(
    recovery: RecoveryTransaction<'_>,
    staged: &StagedRuntime,
    env_file: Option<&Path>,
) -> Result<()> {
    let RecoveryTransaction { app_server, store } = recovery;
    let journal = store
        .load()?
        .context("prepared runtime handoff disappeared before installation")?;
    if !journal.is_prepared_handoff() {
        bail!("prepared runtime handoff changed before installation");
    }
    if journal.runtime_swap.is_some() {
        bail!("commit or roll back the previous runtime before another install");
    }
    if app_server.recorded_daemon_is_live().await? {
        bail!("prepared runtime handoff still has a reachable Codex daemon");
    }
    let needs_gateway_recovery = journal.pending_tasks().next().is_some();
    if needs_gateway_recovery && env_file.is_none() {
        bail!("a gateway env file is required for an active cross-version handoff");
    }

    super::control_owner::wait_for_control_owner_exit(store, RECOVERY_GATEWAY_EXIT_TIMEOUT).await?;
    let paths = HostPaths::from_env()?;
    let claude_home = ConfigSources::load(env_file)?
        .optional_string("RC_CLAUDE_HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| paths.home().join(".claude"));
    let codex_home = app_server
        .child_environment()
        .get("CODEX_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("CODEX_HOME").map(std::path::PathBuf::from))
        .unwrap_or_else(|| paths.home().join(".codex"));
    claude_state::ClaudeStateBackup::for_host()?.capture(&claude_home, &codex_home)?;
    let journal = activate_staged_runtime(store, &journal.generation_id, staged)?;
    let target_server = crate::providers::codex::daemon::CodexAppServer::for_runtime(
        staged.paths.current.join("codex"),
        app_server.child_environment().clone(),
    )?;
    let recovery = RecoveryTransaction::new(&target_server, store);
    let app_server = &target_server;
    recovery.start_recovery_daemon(&journal).await?;
    app_server.verify_package_provenance().await?;
    if !needs_gateway_recovery {
        recovery.complete_recovery(&journal.generation_id).await?;
        return Ok(());
    }

    let mut child =
        start_temporary_recovery_gateway(env_file.context("gateway env file disappeared")?, store)
            .await?;
    if let Err(error) =
        wait_for_temporary_gateway_recovery(store, &journal.generation_id, &mut child).await
    {
        stop_temporary_recovery_gateway(&mut child).await;
        return recovery
            .fail_recovery_closed(&journal.generation_id, error)
            .await;
    }
    recovery.complete_recovery(&journal.generation_id).await?;
    wait_for_temporary_recovery_exit(&mut child).await
}

async fn start_temporary_recovery_gateway(
    env_file: &Path,
    store: &RecoveryStore,
) -> Result<tokio::process::Child> {
    super::control_owner::wait_for_control_owner_exit(store, RECOVERY_GATEWAY_EXIT_TIMEOUT).await?;
    let current_exe = std::env::current_exe()?
        .canonicalize()
        .context("failed to resolve the runtime owner executable")?;
    let env_file = env_file
        .canonicalize()
        .with_context(|| format!("failed to resolve {}", env_file.display()))?;

    TokioCommand::new(current_exe)
        .kill_on_drop(true)
        .arg("--recovery-only")
        .arg("--env-file")
        .arg(env_file)
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
        .context("failed to start the candidate recovery gateway")
}

pub(super) async fn recover_through_temporary_gateway(
    env_file: &Path,
    store: &RecoveryStore,
    generation_id: &str,
    wait_context: &'static str,
) -> Result<tokio::process::Child> {
    let mut child = start_temporary_recovery_gateway(env_file, store).await?;
    if let Err(error) = wait_for_temporary_gateway_recovery(store, generation_id, &mut child).await
    {
        stop_temporary_recovery_gateway(&mut child).await;
        return Err(error).context(wait_context);
    }
    Ok(child)
}

async fn stop_temporary_recovery_gateway(child: &mut tokio::process::Child) {
    let _ = child.start_kill();
    let _ = tokio::time::timeout(Duration::from_secs(5), child.wait()).await;
}

pub(super) async fn wait_for_temporary_recovery_exit(
    child: &mut tokio::process::Child,
) -> Result<()> {
    match tokio::time::timeout(RECOVERY_GATEWAY_EXIT_TIMEOUT, child.wait()).await {
        Ok(Ok(status)) if status.success() => Ok(()),
        Ok(Ok(status)) => bail!("candidate recovery gateway exited with {status}"),
        Ok(Err(error)) => Err(error).context("waiting for candidate recovery gateway"),
        Err(_) => {
            stop_temporary_recovery_gateway(child).await;
            bail!("candidate recovery gateway did not exit after recovery completed")
        }
    }
}

pub(crate) async fn wait_for_recovery_completion() -> Result<()> {
    let store = RecoveryStore::new(RecoveryStore::default_path()?);
    let journal = store
        .load()?
        .context("recovery-only gateway started without a recovery journal")?;
    wait_for_phase(
        &store,
        &journal.generation_id,
        RecoveryPhase::Completed,
        RECOVERY_TIMEOUT,
    )
    .await
}

async fn wait_for_temporary_gateway_recovery(
    store: &RecoveryStore,
    generation_id: &str,
    child: &mut tokio::process::Child,
) -> Result<()> {
    let deadline = tokio::time::Instant::now() + RECOVERY_TIMEOUT;
    loop {
        let journal = store.load()?.context("recovery journal disappeared")?;
        if journal.generation_id != generation_id {
            bail!("recovery generation changed while the candidate gateway was running");
        }
        if matches!(
            journal.phase,
            RecoveryPhase::Recovered | RecoveryPhase::Completed
        ) {
            return Ok(());
        }
        if let Some(status) = child.try_wait()? {
            bail!("candidate recovery gateway exited before recovery completed: {status}");
        }
        if tokio::time::Instant::now() >= deadline {
            bail!(
                "timed out waiting for the candidate gateway; current recovery phase is {:?}",
                journal.phase
            );
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

async fn restore_source_before_activation(
    recovery: RecoveryTransaction<'_>,
    env_file: Option<&Path>,
) -> Result<()> {
    let RecoveryTransaction { app_server, store } = recovery;
    if store
        .load()?
        .as_ref()
        .is_some_and(|journal| journal.runtime_swap.is_some())
    {
        return recovery.reconcile().await;
    }
    if store
        .load()?
        .is_none_or(|journal| journal.phase == RecoveryPhase::Completed)
    {
        ensure_normal_daemon(app_server).await?;
        if let Some(journal) = store.load()? {
            store.update(&journal.generation_id, |journal| {
                journal.phase = RecoveryPhase::Completed;
                journal.error = None;
                Ok(())
            })?;
        }
        super::identity::release_source_journal_identities(store, HostPaths::from_env()?.home())?;
        if let Err(error) = reconcile_desktop(app_server, "install").await {
            tracing::warn!(%error, "source Desktop reconciliation was deferred after rollback");
        }
        return Ok(());
    }
    recovery.rollback_unactivated(env_file).await
}
