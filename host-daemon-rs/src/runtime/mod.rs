use crate::config::{Args, CodexSettings, ConfigSources, RuntimeCommand};
use crate::observability::desktop::DesktopJournal;
use crate::providers::codex::daemon::CodexAppServer;
use crate::runtime::bootstrap::{RuntimeLease, wait_for_runtime_lease};
use crate::runtime::desktop::{
    record_desktop_finished, record_desktop_started, run_desktop_action,
};
use crate::runtime::install::install;
use crate::runtime::install::package::{
    RuntimePaths, commit_runtime_swap, path_exists, sha256_file, validate_runtime_package,
};
use crate::runtime::install::transaction::InstallationTransaction;
use crate::runtime::install::uninstall::UninstallTransaction;
use crate::runtime::launchd::{GATEWAY_LABEL, gui_domain, launchctl};
use crate::runtime::recovery::{RecoveryJournal, RecoveryPhase, RecoveryStore};
use crate::runtime::rpc::{RpcClient, ThreadReadResponse};
use crate::runtime::transaction::RecoveryTransaction;
use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

const RPC_TIMEOUT: Duration = Duration::from_secs(15);
const RECOVERY_TIMEOUT: Duration = Duration::from_secs(600);
const LEASE_WAIT_TIMEOUT: Duration = Duration::from_secs(120);
mod accounts;
mod bootstrap;
mod control_owner;
mod desktop;
mod gateway_probe;
pub(crate) mod gateway_recovery;
pub(crate) mod gateway_shutdown;
pub(crate) mod identity;
pub(crate) mod install;
mod launchd;
pub(crate) mod recovery;
mod rpc;
pub(crate) mod transaction;
pub(crate) use self::bootstrap::bootstrap;
pub(crate) use self::bootstrap::finish_orphaned_recovery;
pub(crate) use control_owner::ControlOwnerLease;

pub(crate) use accounts::retire_codex_accounts;

pub(crate) async fn run(
    command: RuntimeCommand,
    args: Args,
    sources: &ConfigSources,
) -> Result<()> {
    let env_file = args.env_file.clone();
    if matches!(command, RuntimeCommand::Uninstall) {
        return UninstallTransaction::new(env_file.as_deref(), sources)?
            .run()
            .await;
    }
    let store = RecoveryStore::new(RecoveryStore::default_path()?);
    let repair_lease = if matches!(
        command,
        RuntimeCommand::Rollback | RuntimeCommand::Reconcile
    ) {
        let lease = RuntimeLease::acquire(&store)?;
        install::package::settle_interrupted_activation(&store, &RuntimePaths::load()?)?;
        Some(lease)
    } else {
        None
    };
    let settings = if matches!(
        command,
        RuntimeCommand::Install { .. } | RuntimeCommand::Rollback | RuntimeCommand::Reconcile
    ) {
        CodexSettings::load_for_runtime(sources)?
    } else {
        CodexSettings::load(sources)?
    };
    let app_server = CodexAppServer::for_runtime(
        settings.codex_path.clone(),
        settings.codex_child_env.clone(),
    )?;
    let recovery = RecoveryTransaction::new(&app_server, &store);
    if let RuntimeCommand::Desktop { action } = &command {
        let action = *action;
        let journal = DesktopJournal::open(action.as_str(), "cli");
        record_desktop_started(&journal, &settings);
        let result = run_desktop_action(action, &app_server, &journal).await;
        record_desktop_finished(&journal, &result);
        return result;
    }
    if let RuntimeCommand::InstallGateway { stage_id } = &command {
        install::staging::adopt(&crate::config::HostPaths::from_env()?, *stage_id)?;
        return InstallationTransaction::new(recovery, env_file.as_deref(), sources, *stage_id)?
            .run()
            .await;
    }
    let _lease = if let Some(lease) = repair_lease {
        lease
    } else if matches!(&command, RuntimeCommand::Install { .. }) {
        wait_for_runtime_lease(&store).await?
    } else {
        RuntimeLease::acquire(&store)?
    };

    if let Some(journal) = store.load()?
        && journal.phase != RecoveryPhase::Completed
        && let Some(identity) = &journal.package_identity
    {
        identity.verify(&settings.codex_path)?;
    }

    match command {
        RuntimeCommand::Install {
            package_dir,
            check_only,
            check_installed,
        } => {
            if check_only {
                check_install_candidate(
                    &app_server,
                    &store,
                    &package_dir,
                    &settings.codex_path,
                    env_file.as_deref(),
                    check_installed,
                )
                .await
            } else {
                install(recovery, &package_dir, env_file.as_deref()).await
            }
        }
        RuntimeCommand::Restart => recovery.restart().await,
        RuntimeCommand::PrepareHandoff => recovery.prepare_handoff().await,
        RuntimeCommand::PrepareShutdown => recovery.prepare_shutdown().await,
        RuntimeCommand::Reconcile => {
            if store.load()?.is_some_and(|journal| {
                journal.phase == RecoveryPhase::Completed
                    && journal.runtime_swap.is_none()
                    && journal.package_identity.is_some()
            }) {
                let paths = crate::config::HostPaths::from_env()?;
                if let Ok(probe) = crate::config::GatewayEndpoint::load(sources)
                    .and_then(gateway_probe::GatewayProbe::new)
                {
                    let gateway = launchd::LaunchdService::new(GATEWAY_LABEL, &paths);
                    let installed = paths
                        .home()
                        .join("localbin/remote-coder-gateway/remote-coder-codex-gateway");
                    if probe
                        .healthy_installed_gateway(&gateway, &installed)
                        .await
                        .is_ok()
                    {
                        return recovery.reconcile().await;
                    }
                }
                identity::release_source_journal_identities(
                    &store,
                    crate::config::HostPaths::from_env()?.home(),
                )?;
                install::claude_state::ClaudeStateBackup::for_host()?.restore()?;
                return launchd::restore_gateway_launchagent(true).await;
            }
            recovery.reconcile().await
        }
        RuntimeCommand::RetryFailed { generation_id } => {
            recovery.retry_failed(&generation_id).await
        }
        RuntimeCommand::Desktop { .. } => {
            unreachable!("desktop command returned before lease acquisition")
        }
        RuntimeCommand::InstallGateway { .. }
        | RuntimeCommand::InstallCallWorker { .. }
        | RuntimeCommand::ConfigureCallDelivery
        | RuntimeCommand::PrepareGatewayStage { .. }
        | RuntimeCommand::ClearGatewayStage { .. } => {
            unreachable!("gateway install returned before lease acquisition")
        }
        RuntimeCommand::Uninstall => unreachable!("uninstall returned before settings load"),
        RuntimeCommand::Commit => commit_runtime_swap(&store),
        RuntimeCommand::Rollback => recovery.rollback(env_file.as_deref()).await,
    }
}

fn require_gateway_env(env: &Path) -> Result<()> {
    ensure!(
        env.is_file(),
        "gateway env file is missing: {}",
        env.display()
    );
    Ok(())
}

fn completed_journal_if_absent(store: &RecoveryStore) -> Result<RecoveryJournal> {
    if let Some(journal) = store.load()? {
        return Ok(journal);
    }
    let mut journal = RecoveryJournal::new(random_hex(16)?, random_hex(32)?, Vec::new())?;
    journal.phase = RecoveryPhase::Completed;
    store.write(&journal)?;
    Ok(journal)
}

async fn check_install_candidate(
    app_server: &CodexAppServer,
    store: &RecoveryStore,
    package_dir: &Path,
    configured_codex_path: &Path,
    env_file: Option<&Path>,
    check_installed: bool,
) -> Result<()> {
    validate_runtime_package(package_dir)?;
    let env = env_file.context("gateway env file is required")?;
    require_gateway_env(env)?;
    let paths = RuntimePaths::load()?;
    check_install_state(&paths, store, package_dir, check_installed)?;
    let current_codex = paths.current.join("codex");
    ensure!(
        sha256_file(configured_codex_path)? == sha256_file(&current_codex)?,
        "configured source executable differs from the approved current package"
    );
    // This read-only probe checks an existing owner without starting or
    // stopping it. A fresh idle host has no daemon to verify yet.
    if app_server.recorded_daemon_is_live().await? {
        app_server.verify_ready().await?;
        app_server.verify_package_provenance().await?;
    }
    Ok(())
}

fn check_install_state(
    paths: &RuntimePaths,
    store: &RecoveryStore,
    package_dir: &Path,
    check_installed: bool,
) -> Result<()> {
    ensure!(
        !path_exists(&paths.staging)?,
        "pending runtime staging artifact exists: {}",
        paths.staging.display()
    );
    let journal = store.load()?;
    ensure!(
        journal
            .as_ref()
            .is_none_or(|journal| journal.phase == RecoveryPhase::Completed),
        "unfinished runtime recovery must reconcile with the exact candidate before another install"
    );
    let pending_swap = journal
        .as_ref()
        .is_some_and(|journal| journal.runtime_swap.is_some());
    if pending_swap && !check_installed {
        bail!(
            "pending runtime swap must finish the health-gated gateway commit or roll back before another install"
        );
    }
    if check_installed {
        // The shell's quick comparison is only a routing hint. The candidate
        // independently proves the installed manifest and both executable
        // bytes before allowing the existing health-gated commit path.
        for relative in [
            "codex-package.json",
            "bin/codex",
            "bin/codex-code-mode-host",
        ] {
            ensure!(
                sha256_file(&package_dir.join(relative))?
                    == sha256_file(&paths.current.join(relative))?,
                "installed Codex runtime differs from candidate at {relative}; commit or roll back the pending swap before replacement"
            );
        }
    }
    for pending in [
        &paths.previous_release,
        &paths.previous_current,
        &paths.previous_gateway_env,
    ] {
        ensure!(
            pending_swap && check_installed || !path_exists(pending)?,
            "pending runtime rollback artifact exists: {}; commit or roll back the previous runtime",
            pending.display()
        );
    }
    Ok(())
}

fn write_grant(journal_path: &Path, journal: &RecoveryJournal) -> Result<PathBuf> {
    let parent = journal_path
        .parent()
        .context("recovery journal has no parent directory")?;
    let path = parent.join(format!(
        ".codex-restart-grant.{}.json",
        journal.generation_id
    ));
    let targets = journal
        .pending_tasks()
        .map(|task| serde_json::json!({"threadId": task.thread_id, "turnId": task.turn_id}))
        .collect::<Vec<_>>();
    crate::storage::private_state::ensure_private_directory(parent)?;
    crate::storage::private_state::write_json(
        &path,
        &serde_json::json!({
            "schemaVersion": 1,
            "generationId": journal.generation_id,
            "capability": journal.capability,
            "targets": targets,
        }),
    )?;
    Ok(path)
}

fn random_hex(bytes: usize) -> Result<String> {
    let mut random = vec![0_u8; bytes];
    File::open("/dev/urandom")?.read_exact(&mut random)?;
    Ok(random.iter().map(|byte| format!("{byte:02x}")).collect())
}

async fn wait_for_phase(
    store: &RecoveryStore,
    generation_id: &str,
    expected: RecoveryPhase,
    timeout: Duration,
) -> Result<()> {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let journal = store.load()?.context("recovery journal disappeared")?;
        if journal.generation_id != generation_id {
            bail!("recovery generation changed while waiting for {expected:?}");
        }
        if journal.phase == expected {
            return Ok(());
        }
        if tokio::time::Instant::now() >= deadline {
            bail!(
                "timed out waiting for recovery phase {expected:?}; current phase is {:?}",
                journal.phase
            );
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

async fn ensure_gateway_running() -> Result<()> {
    let domain = format!("{}/{GATEWAY_LABEL}", gui_domain());
    let status = launchctl()
        .args(["kickstart", &domain])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await?;
    if !status.success() {
        bail!("failed to kickstart {GATEWAY_LABEL}");
    }
    Ok(())
}

async fn wait_for_desktop_daemon(app_server: &CodexAppServer) -> Result<()> {
    let deadline = tokio::time::Instant::now() + LEASE_WAIT_TIMEOUT;
    loop {
        match app_server.verify_ready().await {
            Ok(()) => return Ok(()),
            Err(error) if tokio::time::Instant::now() >= deadline => {
                return Err(error).context("timed out waiting for the managed Codex daemon");
            }
            Err(_) => tokio::time::sleep(Duration::from_secs(2)).await,
        }
    }
}

#[derive(Deserialize)]
struct CompatibilityThread {
    id: String,
}

#[derive(Deserialize)]
struct CompatibilityThreadPage {
    data: Vec<CompatibilityThread>,
}

async fn verify_recent_thread_compatibility(app_server: &CodexAppServer) -> Result<()> {
    let mut rpc = RpcClient::connect(app_server).await?;
    let page: CompatibilityThreadPage = rpc
        .request(
            "thread/list",
            serde_json::json!({
                "limit": 3,
                "sortKey": "recency_at",
                "sortDirection": "desc",
                "useStateDbOnly": true,
            }),
        )
        .await
        .context("failed to list recent threads for Desktop compatibility")?;
    for thread in page.data {
        let response: ThreadReadResponse = rpc
            .request(
                "thread/read",
                serde_json::json!({"threadId": &thread.id, "includeTurns": true}),
            )
            .await
            .with_context(|| {
                format!(
                    "shared runtime cannot read recent Desktop thread {}",
                    thread.id
                )
            })?;
        if response.thread.id != thread.id {
            bail!(
                "thread/read returned {} for {} during Desktop compatibility check",
                response.thread.id,
                thread.id
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod desktop_version_tests;
