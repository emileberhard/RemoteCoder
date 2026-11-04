use crate::runtime::control_owner::wait_for_control_owner_exit;
use crate::runtime::identity::PackageIdentity;
use crate::runtime::install::RECOVERY_GATEWAY_EXIT_TIMEOUT;
use crate::runtime::install::package::{
    RuntimePaths, activate_staged_runtime, remove_path, restore_previous_runtime,
    stage_runtime_package, validate_runtime_package,
};
use crate::runtime::recovery::{RecoveryJournal, RecoveryPhase};
use crate::runtime::transaction::{RecoveryTransaction, RuntimeDestination};
use anyhow::{Context, Result, ensure};
use std::path::Path;

async fn stop(recovery: RecoveryTransaction<'_>) -> Result<RecoveryJournal> {
    wait_for_control_owner_exit(recovery.store, RECOVERY_GATEWAY_EXIT_TIMEOUT).await?;
    if recovery.app_server.recorded_daemon_is_live().await? {
        ensure!(
            recovery.store.load()?.is_none_or(|journal| journal.phase == RecoveryPhase::Completed),
            "unfinished recovery must be captured by the owning gateway before activation"
        );
        recovery.restart_transaction(RuntimeDestination::Stopped).await?;
    }
    ensure!(
        !recovery.app_server.recorded_daemon_is_live().await?,
        "prepared runtime activation requires a stopped daemon"
    );
    let journal = recovery.store.load()?.context("prepared recovery generation is missing")?;
    ensure!(journal.error.is_none(), "prepared recovery generation has an error");
    Ok(journal)
}

pub(in crate::runtime) async fn activate(recovery: RecoveryTransaction<'_>, package: &Path) -> Result<()> {
    let package = validate_runtime_package(package)?;
    let candidate = PackageIdentity::read(&package.join("bin/codex"))?;
    let journal = stop(recovery).await?;
    let paths = RuntimePaths::load()?;
    if let Some(swap) = &journal.runtime_swap {
        ensure!(
            swap.target_identity.as_ref() == Some(&candidate)
                && (journal.phase == RecoveryPhase::RuntimeInstalled || journal.is_prepared_handoff()),
            "pending runtime swap belongs to another candidate or is not stopped"
        );
        candidate.verify(&paths.current.join("bin/codex"))?;
        recovery.store.set_phase(&journal.generation_id, RecoveryPhase::RuntimeInstalled)?;
        return Ok(());
    }
    ensure!(journal.is_prepared_handoff(), "runtime activation requires an exact stopped handoff");
    journal.package_identity.as_ref().context("prepared source identity is missing")?
        .verify(&paths.current.join("bin/codex"))?;
    remove_path(&paths.staging)?;
    let staged = stage_runtime_package(&package)?;
    let result = activate_staged_runtime(recovery.store, &journal.generation_id, &staged);
    if staged.path.exists() {
        remove_path(&staged.path)?;
    }
    result.map(|_| ())
}

pub(in crate::runtime) async fn restore(recovery: RecoveryTransaction<'_>) -> Result<()> {
    let journal = stop(recovery).await?;
    ensure!(
        journal.is_prepared_handoff() || journal.phase == RecoveryPhase::RuntimeInstalled,
        "runtime restore requires an exact stopped handoff"
    );
    let paths = RuntimePaths::load()?;
    if journal.runtime_swap.is_none() {
        journal.package_identity.as_ref().context("prepared source identity is missing")?
            .verify(&paths.current.join("bin/codex"))?;
        return Ok(());
    }
    restore_previous_runtime(recovery.store, &journal.generation_id, &paths)?;
    Ok(())
}
