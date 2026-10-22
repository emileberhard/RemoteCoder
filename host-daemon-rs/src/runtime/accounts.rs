use std::path::PathBuf;

use anyhow::{Context, Result, ensure};

use crate::accounts::codex_migration;
use crate::config::{HostPaths, Settings};
use crate::providers::codex::daemon::CodexAppServer;
use crate::runtime::bootstrap::RuntimeLease;
use crate::runtime::recovery::{RecoveryJournal, RecoveryPhase, RecoveryStore, RecoveryTaskStatus};
use crate::runtime::rpc::RpcClient;
use crate::runtime::transaction::{
    RecoveryTransaction, RuntimeDestination, suspend_captured_tasks,
};

pub(crate) async fn retire_codex_accounts(settings: &Settings) -> Result<()> {
    let paths = HostPaths::from_env()?;
    let home = paths.home();
    let target = settings
        .codex_child_env
        .get("CODEX_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("CODEX_HOME").map(PathBuf::from))
        .unwrap_or_else(|| home.join(".codex"));
    if codex_migration::is_committed(home)? {
        crate::accounts::registry::Registry::retire_codex(
            &paths.state("account-enrollments.json"),
        )?;
        return Ok(());
    }
    let profiles = codex_migration::profiles(home)?;
    let store = RecoveryStore::new(RecoveryStore::default_path()?);
    let _lease = RuntimeLease::acquire(&store)?;
    let default_server = CodexAppServer::for_runtime(
        settings.codex_path.clone(),
        settings.codex_child_env.clone(),
    )?;
    let enrollments = crate::accounts::registry::Registry::snapshot_entries(
        &paths.state("account-enrollments.json"),
    )?;
    let mut sources = Vec::new();
    for (id, profile) in &profiles {
        let mut environment = settings.codex_child_env.clone();
        environment.insert("CODEX_HOME".into(), profile.join("c").display().to_string());
        let server =
            CodexAppServer::isolated_for_runtime(settings.codex_path.clone(), environment)?;
        let source = RecoveryStore::new(profile.join("state/codex-restart-recovery.json"));
        let previous = source.load()?;
        if server.recorded_daemon_is_live().await? {
            server.verify_ready().await?;
            server.verify_package_provenance().await?;
            server.run_lifecycle("prepare-restart").await?;
            let journal = match previous {
                Some(journal)
                    if matches!(
                        journal.phase,
                        RecoveryPhase::Captured
                            | RecoveryPhase::Suspending
                            | RecoveryPhase::Suspended
                    ) =>
                {
                    journal
                }
                previous => {
                    let mut tasks = previous
                        .as_ref()
                        .filter(|journal| journal.phase != RecoveryPhase::Completed)
                        .map(|journal| journal.tasks.clone())
                        .unwrap_or_default();
                    for task in &mut tasks {
                        if matches!(
                            task.status,
                            RecoveryTaskStatus::Running
                                | RecoveryTaskStatus::Retryable
                                | RecoveryTaskStatus::Suspended
                        ) {
                            task.status = RecoveryTaskStatus::Captured;
                        }
                    }
                    let mut journal = RecoveryJournal::new(
                        super::random_hex(16)?,
                        super::random_hex(32)?,
                        tasks,
                    )?;
                    let identity = super::identity::PackageIdentity::read(&settings.codex_path)?;
                    if let Some(entry) = enrollments.iter().find(|entry| entry.id.as_str() == id) {
                        journal.account = Some(super::recovery::AccountRecovery {
                            account_id: entry.id.as_str().to_owned(),
                            enrollment_generation: entry.generation,
                            native_directory: profile.join("c"),
                            source_sha256: identity.codex_sha256.clone(),
                            target_sha256: identity.codex_sha256.clone(),
                        });
                    }
                    journal.package_identity = Some(identity);
                    source.write(&journal)?;
                    journal
                }
            };
            let mut rpc = RpcClient::connect(&server).await?;
            finish_account_capture(&mut rpc, &source, &journal.generation_id).await?;
            drop(rpc);
            server.stop().await?;
            source.set_phase(&journal.generation_id, RecoveryPhase::DaemonStopped)?;
        } else if let Some(journal) = previous.as_ref() {
            if matches!(
                journal.phase,
                RecoveryPhase::Captured
                    | RecoveryPhase::Suspending
                    | RecoveryPhase::DaemonStarted
                    | RecoveryPhase::Recovering
                    | RecoveryPhase::Recovered
                    | RecoveryPhase::RuntimeInstalled
            ) {
                ensure!(
                    !journal.tasks.is_empty() || journal.phase != RecoveryPhase::Captured,
                    "enrollment capture is unknown after source daemon died"
                );
                let journal = source.update(&journal.generation_id, |current| {
                    for task in &mut current.tasks {
                        if matches!(
                            task.status,
                            RecoveryTaskStatus::Running | RecoveryTaskStatus::Retryable
                        ) {
                            task.status = RecoveryTaskStatus::Captured;
                        }
                    }
                    current.phase = RecoveryPhase::Suspending;
                    Ok(())
                })?;
                RecoveryTransaction::new(&server, &source)
                    .finish_dead_source_capture(&journal)
                    .await?;
                source.set_phase(&journal.generation_id, RecoveryPhase::DaemonStopped)?;
            } else if journal.phase == RecoveryPhase::Suspended {
                source.set_phase(&journal.generation_id, RecoveryPhase::DaemonStopped)?;
            }
        }
        if let Some(journal) = source.load()?
            && journal.phase != RecoveryPhase::Completed
        {
            ensure!(
                journal.phase == RecoveryPhase::DaemonStopped,
                "enrollment recovery is not stopped: {}",
                source.path().display()
            );
            ensure!(
                journal.tasks.iter().all(|task| matches!(
                    task.status,
                    RecoveryTaskStatus::Suspended | RecoveryTaskStatus::Completed
                )),
                "enrollment has unresolved captured work: {}",
                source.path().display()
            );
            sources.push((source, journal));
        }
    }
    super::install::claude_state::ClaudeStateBackup::for_host()?.preserve_source_recoveries()?;
    let prior = store.load()?;
    let needs_transfer = sources
        .iter()
        .flat_map(|(_, journal)| journal.pending_tasks())
        .any(|task| {
            prior.as_ref().is_none_or(|journal| {
                !journal.tasks.iter().any(|existing| {
                    existing.thread_id == task.thread_id && existing.turn_id == task.turn_id
                })
            })
        });
    let needs_native_adoption = !codex_migration::is_settled(home)? && !profiles.is_empty();
    if needs_transfer || needs_native_adoption {
        if let Some(journal) = &prior
            && matches!(
                journal.phase,
                RecoveryPhase::Captured | RecoveryPhase::Suspending | RecoveryPhase::Suspended
            )
        {
            RecoveryTransaction::new(&default_server, &store)
                .prepare_stopped_handoff(journal)
                .await?;
        }
        if prior
            .as_ref()
            .is_none_or(|journal| journal.phase == RecoveryPhase::Completed)
        {
            if default_server.recorded_daemon_is_live().await? {
                RecoveryTransaction::new(&default_server, &store)
                    .restart_transaction(RuntimeDestination::Stopped)
                    .await?;
            } else {
                let mut journal = RecoveryJournal::new(
                    super::random_hex(16)?,
                    super::random_hex(32)?,
                    Vec::new(),
                )?;
                journal.phase = RecoveryPhase::DaemonStopped;
                journal.package_identity = Some(super::identity::PackageIdentity::read(
                    &settings.codex_path,
                )?);
                store.write(&journal)?;
            }
        }
        ensure!(
            store
                .load()?
                .is_some_and(|journal| journal.is_prepared_handoff()),
            "default recovery must be stopped before adopting enrollment state"
        );
        ensure!(
            !default_server.recorded_daemon_is_live().await?,
            "default daemon must be stopped before adopting enrollment state"
        );
    }
    if !codex_migration::is_settled(home)? {
        super::install::claude_state::ClaudeStateBackup::for_host()?.extend_codex_snapshot()?;
        codex_migration::run(home, &target, &settings.claude.claude_home)?;
    }
    if needs_transfer {
        let journal = store
            .load()?
            .context("default recovery disappeared during enrollment retirement")?;
        store.update(&journal.generation_id, |current| {
            for (_, source) in &sources {
                for task in source.pending_tasks() {
                    if let Some(existing) = current
                        .tasks
                        .iter()
                        .find(|existing| existing.thread_id == task.thread_id)
                    {
                        ensure!(
                            existing.turn_id == task.turn_id,
                            "retired enrollment conflicts with default turn for {}",
                            task.thread_id
                        );
                    } else {
                        current.tasks.push(task.clone());
                    }
                }
            }
            Ok(())
        })?;
    }
    crate::accounts::registry::Registry::retire_codex(&paths.state("account-enrollments.json"))?;
    for (source, journal) in sources {
        source.set_phase(&journal.generation_id, RecoveryPhase::Completed)?;
    }
    Ok(())
}

pub(super) async fn finish_account_capture(
    rpc: &mut RpcClient,
    store: &RecoveryStore,
    generation_id: &str,
) -> Result<()> {
    let tasks = super::rpc::snapshot_active_tasks(rpc).await?;
    store.update(generation_id, |journal| {
        for task in tasks {
            if let Some(existing) = journal
                .tasks
                .iter()
                .find(|existing| existing.thread_id == task.thread_id)
            {
                ensure!(
                    existing.status == RecoveryTaskStatus::Captured,
                    "suspended enrollment thread became active again"
                );
            } else {
                journal.tasks.push(task);
            }
        }
        Ok(())
    })?;
    store.set_phase(generation_id, RecoveryPhase::Suspending)?;
    suspend_captured_tasks(rpc, store, generation_id).await
}
