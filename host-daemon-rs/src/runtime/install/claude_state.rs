use crate::accounts::claude_migration::{is_settled, rollback_profile_files};
use crate::config::HostPaths;
use crate::storage::no_follow::{EntryKind, Root};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};

const OWNERS: [&str; 15] = [
    "account-enrollments.json",
    "conversation-handoffs.json",
    "claude-restart-recovery.json",
    "session-metadata-v2.json",
    "conversation-marks.json",
    "questions",
    "agent-calls.json",
    "claude-profile-migration.json",
    "claude-profile-conflicts",
    "codex-profile-migration.json",
    "codex-profile-conflicts",
    "codex-restart-recovery.json",
    "active-codex-turns.json",
    "live-activity-finished-turns.json",
    "conversation-marks.v3.json",
];
const PROFILE_OWNERS: [&str; 5] = [
    "projects",
    "remotecoder-agents",
    "session-env",
    "remotecoder-history",
    "memory",
];
const BACKUP: &str = "claude-migration-install-backup";

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Manifest {
    state_owners: Vec<String>,
    profile_files: BTreeSet<PathBuf>,
    claude_home: PathBuf,
    #[serde(default)]
    codex_home: Option<PathBuf>,
    #[serde(default)]
    codex_files: BTreeSet<PathBuf>,
    #[serde(default)]
    source_recoveries: BTreeSet<PathBuf>,
}

pub(crate) struct ClaudeStateBackup {
    home: PathBuf,
    state: PathBuf,
    backup: PathBuf,
}

impl ClaudeStateBackup {
    pub(crate) fn for_host() -> Result<Self> {
        Ok(Self::new(&HostPaths::from_env()?))
    }

    pub(crate) fn new(paths: &HostPaths) -> Self {
        Self {
            home: paths.home().to_owned(),
            state: paths.state(""),
            backup: paths.state(BACKUP),
        }
    }

    pub(crate) fn capture(&self, claude_home: &Path, codex_home: &Path) -> Result<()> {
        let root = Root::open(&self.home)?;
        if root.entry_kind(&self.backup)?.is_some() {
            self.validate_home(&root, claude_home)?;
            let manifest = self.validate(&root)?;
            ensure!(
                manifest
                    .codex_home
                    .as_ref()
                    .is_none_or(|home| home == codex_home),
                "migration backup belongs to another Codex home"
            );
            return Ok(());
        }
        if is_settled(&self.home)? && crate::accounts::codex_migration::is_settled(&self.home)? {
            return Ok(());
        }
        let profile_files = rollback_profile_files(&self.home, claude_home)?;
        let (codex_files, source_recoveries) =
            if crate::accounts::codex_migration::is_settled(&self.home)? {
                (BTreeSet::new(), BTreeSet::new())
            } else {
                (
                    crate::accounts::codex_migration::rollback_profile_files(
                        &self.home, codex_home,
                    )?,
                    crate::accounts::codex_migration::profiles(&self.home)?
                        .values()
                        .map(|profile| profile.join("state/codex-restart-recovery.json"))
                        .collect(),
                )
            };
        self.capture_files(
            &root,
            claude_home,
            codex_home,
            profile_files,
            codex_files,
            source_recoveries,
        )
    }

    fn capture_files(
        &self,
        root: &Root,
        claude_home: &Path,
        codex_home: &Path,
        profile_files: BTreeSet<PathBuf>,
        native_files: BTreeSet<PathBuf>,
        recovery_files: BTreeSet<PathBuf>,
    ) -> Result<()> {
        ensure!(
            claude_home.is_absolute(),
            "Claude migration profile home must be absolute: {}",
            claude_home.display()
        );
        if root.entry_kind(&self.backup)?.is_some() {
            return self.validate_home(root, claude_home);
        }
        let profile = self.profile_root(claude_home)?;
        let relative_files: BTreeSet<PathBuf> = profile_files
            .into_iter()
            .map(|path| {
                let relative = path.strip_prefix(claude_home).with_context(|| {
                    format!(
                        "Claude rollback file is outside profile: {}",
                        path.display()
                    )
                })?;
                validate_profile_file(relative)?;
                Ok(relative.to_owned())
            })
            .collect::<Result<_>>()?;
        root.ensure_directory(&self.state)?;
        let staged = self.backup.with_extension("new");
        root.remove_tree(&staged)?;
        root.ensure_directory(&staged)?;
        for name in OWNERS {
            copy_entry(root, &self.state.join(name), root, &staged.join(name)).with_context(
                || {
                    format!(
                        "snapshotting Claude migration state {}",
                        self.state.join(name).display()
                    )
                },
            )?;
        }
        for relative in &relative_files {
            let source = claude_home.join(relative);
            root.clone_from(
                &profile,
                &source,
                &staged.join("host-profile").join(relative),
            )
            .with_context(|| format!("snapshotting Claude profile {}", source.display()))?;
        }
        let mut codex_files = BTreeSet::new();
        let mut source_recoveries = BTreeSet::new();
        {
            let codex_root = self.profile_root(codex_home)?;
            for source in native_files {
                let relative = source
                    .strip_prefix(codex_home)
                    .context("Codex rollback file is outside native home")?
                    .to_owned();
                validate_relative_file(&relative)?;
                copy_entry(
                    &codex_root,
                    &source,
                    root,
                    &staged.join("codex-profile").join(&relative),
                )?;
                codex_files.insert(relative);
            }
            for source in recovery_files {
                let relative = source.strip_prefix(&self.home)?.to_owned();
                validate_relative_file(&relative)?;
                copy_entry(
                    root,
                    &source,
                    root,
                    &staged.join("source-recoveries").join(&relative),
                )?;
                source_recoveries.insert(relative);
            }
        }
        let manifest = Manifest {
            state_owners: OWNERS.map(String::from).to_vec(),
            profile_files: relative_files,
            claude_home: claude_home.to_owned(),
            codex_home: Some(codex_home.to_owned()),
            codex_files,
            source_recoveries,
        };
        root.write_json(&staged.join("manifest.json"), &manifest)?;
        root.rename_directory(&staged, &self.backup)
    }

    pub(crate) fn has_codex_files(&self) -> Result<bool> {
        let root = Root::open(&self.home)?;
        if root.entry_kind(&self.backup)?.is_none() {
            return Ok(false);
        }
        Ok(!self.validate(&root)?.codex_files.is_empty())
    }

    pub(crate) fn extend_codex_snapshot(&self) -> Result<()> {
        let root = Root::open(&self.home)?;
        if root.entry_kind(&self.backup)?.is_none() {
            return Ok(());
        }
        let mut manifest = self.validate(&root)?;
        let codex_home = manifest
            .codex_home
            .as_ref()
            .context("Migration backup has no Codex home")?;
        let profile = self.profile_root(codex_home)?;
        for source in
            crate::accounts::codex_migration::rollback_profile_files(&self.home, codex_home)?
        {
            let relative = source
                .strip_prefix(codex_home)
                .context("Codex rollback file is outside native home")?
                .to_owned();
            validate_relative_file(&relative)?;
            if manifest.codex_files.insert(relative.clone()) {
                copy_entry(
                    &profile,
                    &source,
                    &root,
                    &self.backup.join("codex-profile").join(relative),
                )?;
            }
        }
        root.write_json(&self.backup.join("manifest.json"), &manifest)
    }

    pub(crate) fn preserve_source_recoveries(&self) -> Result<()> {
        let root = Root::open(&self.home)?;
        if root.entry_kind(&self.backup)?.is_none() {
            return Ok(());
        }
        let manifest = self.validate(&root)?;
        for relative in &manifest.source_recoveries {
            let source = self.home.join(relative);
            let backup = self.backup.join("source-recoveries").join(relative);
            copy_entry(&root, &source, &root, &backup)?;
        }
        Ok(())
    }

    pub(crate) fn is_pending(&self) -> Result<bool> {
        Ok(Root::open(&self.home)?.entry_kind(&self.backup)?.is_some())
    }

    pub(crate) fn restore(&self) -> Result<()> {
        let root = Root::open(&self.home)?;
        if root.entry_kind(&self.backup)?.is_none() {
            return Ok(());
        }
        let manifest = self.validate(&root)?;
        if crate::accounts::codex_migration::is_committed(&self.home)? {
            crate::accounts::registry::Registry::retire_codex(
                &self.state.join("account-enrollments.json"),
            )?;
            return self.discard();
        }
        let _native_lock = manifest
            .codex_home
            .as_deref()
            .map(crate::accounts::codex_migration::lock_native)
            .transpose()?;
        let current_recovery = crate::runtime::recovery::RecoveryStore::new(
            self.state.join("codex-restart-recovery.json"),
        )
        .load()?;
        let profile = self.profile_root(&manifest.claude_home)?;
        for relative in &manifest.profile_files {
            let target = manifest.claude_home.join(relative);
            profile
                .clone_from(
                    &root,
                    &self.backup.join("host-profile").join(relative),
                    &target,
                )
                .with_context(|| format!("restoring Claude profile {}", target.display()))?;
        }
        if let Some(codex_home) = &manifest.codex_home {
            let profile = self.profile_root(codex_home)?;
            for relative in &manifest.codex_files {
                let target = codex_home.join(relative);
                profile.remove_tree(&target)?;
                copy_entry(
                    &root,
                    &self.backup.join("codex-profile").join(relative),
                    &profile,
                    &target,
                )?;
            }
        }
        for relative in &manifest.source_recoveries {
            let target = self.home.join(relative);
            root.remove_tree(&target)?;
            copy_entry(
                &root,
                &self.backup.join("source-recoveries").join(relative),
                &root,
                &target,
            )?;
        }
        for name in &manifest.state_owners {
            let target = self.state.join(name);
            root.remove_tree(&target)
                .with_context(|| format!("removing migrated Claude state {}", target.display()))?;
            copy_entry(&root, &self.backup.join(name), &root, &target).with_context(|| {
                format!("restoring Claude migration state {}", target.display())
            })?;
        }
        if let Some(current) = current_recovery
            && current.runtime_swap.is_some()
        {
            let store = crate::runtime::recovery::RecoveryStore::new(
                self.state.join("codex-restart-recovery.json"),
            );
            if let Some(restored) = store.load()? {
                store.update(&restored.generation_id, |journal| {
                    journal.runtime_swap = current.runtime_swap;
                    journal.package_identity = current.package_identity;
                    Ok(())
                })?;
            }
        }
        self.discard()
    }

    pub(crate) fn discard(&self) -> Result<()> {
        let root = Root::open(&self.home)?;
        root.remove_tree(&self.backup)?;
        root.remove_tree(&self.backup.with_extension("new"))
    }

    fn profile_root(&self, claude_home: &Path) -> Result<Root> {
        if claude_home.starts_with(&self.home) {
            let root = Root::open(&self.home)?;
            root.ensure_directory(claude_home)?;
            Ok(root)
        } else {
            Root::open(claude_home)
        }
    }

    fn validate_home(&self, root: &Root, claude_home: &Path) -> Result<()> {
        let manifest = self.validate(root)?;
        ensure!(
            manifest.claude_home == claude_home,
            "Claude migration backup belongs to {}, requested {}",
            manifest.claude_home.display(),
            claude_home.display()
        );
        Ok(())
    }

    fn validate(&self, root: &Root) -> Result<Manifest> {
        let path = self.backup.join("manifest.json");
        let manifest: Manifest =
            serde_json::from_slice(&root.read(&path)?.with_context(|| {
                format!(
                    "Claude migration backup manifest is missing: {}",
                    path.display()
                )
            })?)?;
        ensure!(
            manifest.state_owners == OWNERS || manifest.state_owners == OWNERS[..9],
            "Claude migration backup has unexpected state owners: {}",
            path.display()
        );
        ensure!(
            manifest.claude_home.is_absolute(),
            "Claude migration backup has invalid profile home: {}",
            path.display()
        );
        for relative in &manifest.profile_files {
            validate_profile_file(relative)?;
        }
        ensure!(
            manifest
                .codex_home
                .as_ref()
                .is_none_or(|home| home.is_absolute()),
            "invalid Codex backup home"
        );
        for relative in manifest
            .codex_files
            .iter()
            .chain(&manifest.source_recoveries)
        {
            validate_relative_file(relative)?;
        }
        Ok(manifest)
    }
}

fn validate_relative_file(relative: &Path) -> Result<()> {
    ensure!(
        !relative.as_os_str().is_empty()
            && relative
                .components()
                .all(|part| matches!(part, Component::Normal(_))),
        "invalid migration backup path: {}",
        relative.display()
    );
    Ok(())
}

fn validate_profile_file(relative: &Path) -> Result<()> {
    let mut components = relative.components();
    ensure!(
        matches!(components.next(), Some(Component::Normal(name)) if PROFILE_OWNERS.iter().any(|owner| name == *owner))
            && relative.components().count() > 1
            && components.all(|part| matches!(part, Component::Normal(_))),
        "invalid Claude rollback profile path: {}",
        relative.display()
    );
    Ok(())
}

fn copy_entry(source_root: &Root, source: &Path, target_root: &Root, target: &Path) -> Result<()> {
    match source_root.entry_kind(source)? {
        None => Ok(()),
        Some(EntryKind::Directory) => {
            target_root.ensure_directory(target)?;
            for name in source_root.read_directory(source)? {
                copy_entry(
                    source_root,
                    &source.join(&name),
                    target_root,
                    &target.join(name),
                )?;
            }
            Ok(())
        }
        Some(EntryKind::File) => target_root.clone_from(source_root, source, target),
        Some(EntryKind::Symlink) => {
            target_root.create_link(target, &source_root.read_link(source)?)
        }
        Some(EntryKind::Other) => anyhow::bail!(
            "Claude migration state is not a regular file, directory or symlink: {}",
            source.display()
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::private_state;

    fn capture(backup: &ClaudeStateBackup, profile: &Path, files: BTreeSet<PathBuf>) -> Result<()> {
        backup.capture_files(
            &Root::open(&backup.home)?,
            profile,
            &backup.home.join(".codex"),
            files,
            BTreeSet::new(),
            BTreeSet::new(),
        )
    }

    #[test]
    fn native_snapshot_restore_waits_for_an_orphaned_python_adoption_writer() {
        use std::io::{BufRead, Write};
        use std::process::{Command, Stdio};
        use std::sync::mpsc;
        use std::time::Duration;

        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let backup = ClaudeStateBackup::new(&paths);
        let root = Root::open(home.path()).unwrap();
        let native = home.path().join(".codex");
        let database = native.join("state_5.sqlite");
        root.replace(&database, b"original native state").unwrap();
        backup
            .capture_files(
                &root,
                &home.path().join(".claude"),
                &native,
                BTreeSet::new(),
                [database.clone()].into_iter().collect(),
                BTreeSet::new(),
            )
            .unwrap();
        root.replace(&database, b"candidate native state").unwrap();
        let mut child = Command::new("python3").args(["-I", "-c", "import fcntl,sys\nwith open(sys.argv[1],'a') as held:\n fcntl.flock(held,fcntl.LOCK_EX)\n print('ready',flush=True)\n sys.stdin.read(1)"])
            .arg(native.join(".remotecoder-adoption.lock"))
            .stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
        let mut ready = String::new();
        std::io::BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut ready)
            .unwrap();
        assert_eq!(ready.trim(), "ready");
        let (started, starting) = mpsc::channel();
        let (completed, completion) = mpsc::channel();
        let restore = std::thread::spawn(move || {
            started.send(()).unwrap();
            let result = backup.restore();
            completed.send(result).unwrap();
        });
        starting.recv().unwrap();
        assert!(matches!(
            completion.recv_timeout(Duration::from_millis(100)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        assert_eq!(std::fs::read(&database).unwrap(), b"candidate native state");
        child.stdin.take().unwrap().write_all(b"x").unwrap();
        assert!(child.wait().unwrap().success());
        completion
            .recv_timeout(Duration::from_secs(10))
            .unwrap()
            .unwrap();
        restore.join().unwrap();
        assert_eq!(std::fs::read(database).unwrap(), b"original native state");
    }

    #[test]
    fn quiesced_snapshot_extension_removes_late_adoptions_without_replacing_original_backups() {
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let backup = ClaudeStateBackup::new(&paths);
        let root = Root::open(home.path()).unwrap();
        let native = home.path().join(".codex");
        let source = home.path().join(".rca/11111111111111111111111111111111/c");
        let original = native.join("sessions/existing.jsonl");
        root.replace(&original, b"original host rollout").unwrap();
        root.ensure_directory(&source).unwrap();
        backup
            .capture_files(
                &root,
                &home.path().join(".claude"),
                &native,
                BTreeSet::new(),
                [original.clone()].into_iter().collect(),
                BTreeSet::new(),
            )
            .unwrap();
        root.replace(&source.join("sessions/existing.jsonl"), b"new host rollout")
            .unwrap();
        root.replace(&source.join("sessions/late.jsonl"), b"late source rollout")
            .unwrap();
        root.replace(
            &source.join("attachments/late.bin"),
            b"late source attachment",
        )
        .unwrap();
        root.replace(&original, b"new host rollout").unwrap();
        backup.extend_codex_snapshot().unwrap();
        root.clone_from(
            &root,
            &source.join("sessions/late.jsonl"),
            &native.join("sessions/late.jsonl"),
        )
        .unwrap();
        root.clone_from(
            &root,
            &source.join("attachments/late.bin"),
            &native.join("attachments/late.bin"),
        )
        .unwrap();
        backup.extend_codex_snapshot().unwrap();
        backup.restore().unwrap();
        assert_eq!(std::fs::read(&original).unwrap(), b"original host rollout");
        assert!(!native.join("sessions/late.jsonl").exists());
        assert!(!native.join("attachments/late.bin").exists());
        assert_eq!(
            std::fs::read(source.join("sessions/late.jsonl")).unwrap(),
            b"late source rollout"
        );
        assert_eq!(
            std::fs::read(source.join("attachments/late.bin")).unwrap(),
            b"late source attachment"
        );
    }

    #[test]
    fn codex_backup_restores_before_adoption_commit_and_preserves_committed_work() {
        use crate::runtime::recovery::{
            RecoveryJournal, RecoveryPhase, RecoveryStore, RecoveryTask, RecoveryTaskStatus,
        };
        for committed in [false, true] {
            let home = tempfile::tempdir().unwrap();
            let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
            let backup = ClaudeStateBackup::new(&paths);
            let native = home.path().join(".codex");
            let original = native.join("state_5.sqlite");
            let incoming = native.join("sessions/imported.jsonl");
            let source = home
                .path()
                .join(".rca/11111111111111111111111111111111/state/codex-restart-recovery.json");
            private_state::ensure_private_directory(&native).unwrap();
            std::fs::write(&original, b"original database bytes").unwrap();
            backup
                .capture_files(
                    &Root::open(home.path()).unwrap(),
                    &home.path().join(".claude"),
                    &native,
                    BTreeSet::new(),
                    [original.clone(), incoming.clone()].into_iter().collect(),
                    [source.clone()].into_iter().collect(),
                )
                .unwrap();
            let mut captured = RecoveryJournal::new(
                "source-generation".into(),
                "a".repeat(64),
                vec![RecoveryTask {
                    thread_id: "thread".into(),
                    turn_id: "turn".into(),
                    parent_thread_id: None,
                    depth: 0,
                    recovery_attempts: 0,
                    status: RecoveryTaskStatus::Suspended,
                    error: None,
                }],
            )
            .unwrap();
            captured.phase = RecoveryPhase::DaemonStopped;
            RecoveryStore::new(source.clone()).write(&captured).unwrap();
            backup.preserve_source_recoveries().unwrap();
            let mut adopted = captured.clone();
            adopted.generation_id = "default-generation".into();
            if committed {
                adopted.phase = RecoveryPhase::Recovering;
                adopted.tasks[0].status = RecoveryTaskStatus::Running;
            }
            RecoveryStore::new(paths.state("codex-restart-recovery.json"))
                .write(&adopted)
                .unwrap();
            RecoveryStore::new(source.clone())
                .set_phase("source-generation", RecoveryPhase::Completed)
                .unwrap();
            std::fs::write(&original, b"candidate database bytes").unwrap();
            private_state::ensure_private_directory(incoming.parent().unwrap()).unwrap();
            std::fs::write(&incoming, b"imported rollout").unwrap();
            if committed {
                Root::open(home.path())
                    .unwrap()
                    .write_json(
                        &paths.state("codex-profile-migration.json"),
                        &serde_json::json!({"retiredIds":[],"profiles":{},"complete":true}),
                    )
                    .unwrap();
                crate::accounts::registry::Registry::retire_codex(
                    &paths.state("account-enrollments.json"),
                )
                .unwrap();
                backup.restore().unwrap();
                assert_eq!(
                    std::fs::read(&original).unwrap(),
                    b"candidate database bytes"
                );
                assert!(incoming.exists());
                assert!(!backup.is_pending().unwrap());
                assert_eq!(
                    RecoveryStore::new(source).load().unwrap().unwrap().phase,
                    RecoveryPhase::Completed
                );
                assert_eq!(
                    RecoveryStore::new(paths.state("codex-restart-recovery.json"))
                        .load()
                        .unwrap()
                        .unwrap(),
                    adopted
                );
            } else {
                backup.restore().unwrap();
                assert_eq!(
                    std::fs::read(&original).unwrap(),
                    b"original database bytes"
                );
                assert!(!incoming.exists());
                assert_eq!(
                    RecoveryStore::new(source).load().unwrap().unwrap(),
                    captured
                );
                assert!(!paths.state("codex-restart-recovery.json").exists());
            }
        }
    }

    #[test]
    fn claude_state_backup_restores_owned_files_and_absence_after_failed_startup() {
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let backup = ClaudeStateBackup::new(&paths);
        private_state::ensure_private_directory(&paths.state("questions")).unwrap();
        std::fs::write(paths.state("questions/original.json"), b"original question").unwrap();
        std::fs::write(paths.state("account-enrollments.json"), b"Claude and Codex").unwrap();
        std::fs::write(paths.state("unrelated.json"), b"original unrelated").unwrap();
        capture(&backup, &home.path().join(".claude"), BTreeSet::new()).unwrap();
        std::fs::write(paths.state("account-enrollments.json"), b"Codex only").unwrap();
        std::fs::write(paths.state("questions/original.json"), b"merged question").unwrap();
        std::fs::write(paths.state("questions/new.json"), b"new question").unwrap();
        std::fs::write(
            paths.state("claude-profile-migration.json"),
            b"completed migration",
        )
        .unwrap();
        private_state::ensure_private_directory(&paths.state("claude-profile-conflicts")).unwrap();
        std::fs::write(
            paths.state("claude-profile-conflicts/conflict"),
            b"conflict",
        )
        .unwrap();
        std::fs::write(paths.state("unrelated.json"), b"new unrelated").unwrap();
        backup.restore().unwrap();
        assert_eq!(
            std::fs::read(paths.state("account-enrollments.json")).unwrap(),
            b"Claude and Codex"
        );
        assert_eq!(
            std::fs::read(paths.state("questions/original.json")).unwrap(),
            b"original question"
        );
        assert!(!paths.state("questions/new.json").exists());
        assert!(!paths.state("claude-profile-migration.json").exists());
        assert!(!paths.state("claude-profile-conflicts").exists());
        assert_eq!(
            std::fs::read(paths.state("unrelated.json")).unwrap(),
            b"new unrelated"
        );
        assert!(!backup.backup.exists());
    }

    #[test]
    fn a_settled_migration_takes_no_backup_and_keeps_accepted_state_on_rollback() {
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let backup = ClaudeStateBackup::new(&paths);
        private_state::ensure_private_directory(&paths.state("questions")).unwrap();
        write_complete_receipt(&paths, serde_json::json!([]));
        std::fs::write(
            paths.state("codex-profile-migration.json"),
            br#"{"retiredIds":[],"profiles":{},"complete":true}"#,
        )
        .unwrap();
        std::fs::write(paths.state("questions/open.json"), b"before install").unwrap();
        backup
            .capture(&home.path().join(".claude"), &home.path().join(".codex"))
            .unwrap();
        assert!(!backup.is_pending().unwrap());
        std::fs::write(
            paths.state("questions/open.json"),
            b"answered by the candidate",
        )
        .unwrap();
        backup.restore().unwrap();
        assert_eq!(
            std::fs::read(paths.state("questions/open.json")).unwrap(),
            b"answered by the candidate"
        );
    }

    #[test]
    fn a_complete_migration_with_pending_operations_still_takes_a_backup() {
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let backup = ClaudeStateBackup::new(&paths);
        let claude_home = home.path().join(".claude");
        write_complete_receipt(
            &paths,
            serde_json::json!([{
                "kind": "write",
                "target": claude_home.join("projects/pending.jsonl"),
                "value": {}
            }]),
        );
        backup
            .capture(&claude_home, &home.path().join(".codex"))
            .unwrap();
        assert!(backup.is_pending().unwrap());
    }

    fn write_complete_receipt(paths: &HostPaths, pending: serde_json::Value) {
        private_state::ensure_private_directory(&paths.state("")).unwrap();
        let receipt = serde_json::json!({
            "retiredIds": [], "sessions": [], "conflicts": [], "memoryIndexes": [],
            "metadataThreads": [], "complete": true, "completed": [], "pending": pending
        });
        std::fs::write(
            paths.state("claude-profile-migration.json"),
            receipt.to_string(),
        )
        .unwrap();
    }

    #[test]
    fn claude_state_backup_is_reused_until_commit_and_recreated_after_rollback() {
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let backup = ClaudeStateBackup::new(&paths);
        private_state::ensure_private_directory(&paths.state("")).unwrap();
        std::fs::write(paths.state("account-enrollments.json"), b"source").unwrap();
        capture(&backup, &home.path().join(".claude"), BTreeSet::new()).unwrap();
        std::fs::write(paths.state("account-enrollments.json"), b"candidate").unwrap();
        capture(&backup, &home.path().join(".claude"), BTreeSet::new()).unwrap();
        backup.restore().unwrap();
        assert_eq!(
            std::fs::read(paths.state("account-enrollments.json")).unwrap(),
            b"source"
        );
        std::fs::write(paths.state("account-enrollments.json"), b"later source").unwrap();
        capture(&backup, &home.path().join(".claude"), BTreeSet::new()).unwrap();
        std::fs::write(paths.state("account-enrollments.json"), b"next candidate").unwrap();
        backup.restore().unwrap();
        assert_eq!(
            std::fs::read(paths.state("account-enrollments.json")).unwrap(),
            b"later source"
        );
        capture(&backup, &home.path().join(".claude"), BTreeSet::new()).unwrap();
        std::fs::write(paths.state("account-enrollments.json"), b"accepted").unwrap();
        backup.discard().unwrap();
        backup.restore().unwrap();
        assert_eq!(
            std::fs::read(paths.state("account-enrollments.json")).unwrap(),
            b"accepted"
        );
    }

    #[test]
    fn claude_state_backup_restores_custom_profile_replacements_and_keeps_additions() {
        let home = tempfile::tempdir().unwrap();
        let custom = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let backup = ClaudeStateBackup::new(&paths);
        let history = custom.path().join("projects/work/session.jsonl");
        let memory = custom.path().join("memory/MEMORY.md");
        private_state::ensure_private_directory(history.parent().unwrap()).unwrap();
        private_state::ensure_private_directory(memory.parent().unwrap()).unwrap();
        std::fs::write(&history, b"original host history").unwrap();
        std::fs::write(&memory, b"original memory index").unwrap();
        capture(
            &backup,
            custom.path(),
            [history.clone(), memory.clone()].into_iter().collect(),
        )
        .unwrap();
        assert!(
            backup
                .capture(&home.path().join(".claude"), &home.path().join(".codex"))
                .is_err()
        );
        std::fs::write(&history, b"different canonical history").unwrap();
        std::fs::write(&memory, b"merged memory index").unwrap();
        let added = custom.path().join("projects/work/new-session.jsonl");
        std::fs::write(&added, b"added history").unwrap();
        let reopened = ClaudeStateBackup::new(&paths);
        reopened.restore().unwrap();
        assert_eq!(std::fs::read(&history).unwrap(), b"original host history");
        assert_eq!(std::fs::read(&memory).unwrap(), b"original memory index");
        assert_eq!(std::fs::read(&added).unwrap(), b"added history");
        assert!(!home.path().join(".claude").exists());
    }

    #[test]
    fn claude_state_backup_ignores_unrelated_host_aliases_and_fifo() {
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::fs::{FileTypeExt, symlink};
        let home = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let backup = ClaudeStateBackup::new(&paths);
        let profile = home.path().join(".claude");
        let root = Root::open(home.path()).unwrap();
        let replaced = profile.join("memory/MEMORY.md");
        root.replace(&replaced, b"host memory").unwrap();
        let outside_file = outside.path().join("data");
        std::fs::write(&outside_file, b"outside").unwrap();
        root.ensure_directory(&profile.join("projects")).unwrap();
        let directory_link = profile.join("projects/unrelated");
        let file_link = profile.join("memory/unrelated");
        let dangling_link = profile.join("memory/dangling");
        symlink(outside.path(), &directory_link).unwrap();
        symlink(&outside_file, &file_link).unwrap();
        symlink(outside.path().join("missing"), &dangling_link).unwrap();
        let fifo = profile.join("memory/pipe");
        let fifo_name = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo_name.as_ptr(), 0o600) }, 0);
        capture(&backup, &profile, [replaced.clone()].into_iter().collect()).unwrap();
        root.replace(&replaced, b"merged memory").unwrap();
        backup.restore().unwrap();
        assert_eq!(std::fs::read(&replaced).unwrap(), b"host memory");
        assert_eq!(std::fs::read(&outside_file).unwrap(), b"outside");
        for link in [directory_link, file_link, dangling_link] {
            assert!(
                std::fs::symlink_metadata(link)
                    .unwrap()
                    .file_type()
                    .is_symlink()
            );
        }
        assert!(
            std::fs::symlink_metadata(fifo)
                .unwrap()
                .file_type()
                .is_fifo()
        );
    }

    #[test]
    fn claude_state_backup_preserves_state_links_without_dereferencing_them() {
        use std::os::unix::fs::symlink;
        let home = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let backup = ClaudeStateBackup::new(&paths);
        let root = Root::open(home.path()).unwrap();
        root.ensure_directory(&paths.state("questions")).unwrap();
        let outside_file = outside.path().join("data");
        std::fs::write(&outside_file, b"outside").unwrap();
        let link = paths.state("questions/linked");
        let dangling = paths.state("questions/dangling");
        symlink(&outside_file, &link).unwrap();
        symlink(outside.path().join("missing"), &dangling).unwrap();
        capture(&backup, &home.path().join(".claude"), BTreeSet::new()).unwrap();
        root.remove_tree(&paths.state("questions")).unwrap();
        backup.restore().unwrap();
        assert_eq!(std::fs::read_link(&link).unwrap(), outside_file);
        assert_eq!(
            std::fs::read_link(&dangling).unwrap(),
            outside.path().join("missing")
        );
        assert_eq!(std::fs::read(outside_file).unwrap(), b"outside");
    }

    #[test]
    fn claude_state_backup_refuses_selected_alias_and_restore_parent_alias() {
        use std::os::unix::fs::symlink;
        let home = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let backup = ClaudeStateBackup::new(&paths);
        let profile = home.path().join(".claude");
        let root = Root::open(home.path()).unwrap();
        let parent = profile.join("projects/work");
        root.ensure_directory(&parent).unwrap();
        let history = parent.join("session.jsonl");
        let outside_file = outside.path().join("session.jsonl");
        std::fs::write(&outside_file, b"outside").unwrap();
        symlink(&outside_file, &history).unwrap();
        assert!(capture(&backup, &profile, [history.clone()].into_iter().collect()).is_err());
        assert_eq!(std::fs::read(&outside_file).unwrap(), b"outside");
        assert!(
            std::fs::symlink_metadata(&history)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        root.remove_tree(&history).unwrap();
        root.replace(&history, b"original").unwrap();
        capture(&backup, &profile, [history.clone()].into_iter().collect()).unwrap();
        std::fs::rename(&parent, profile.join("projects/original-work")).unwrap();
        symlink(outside.path(), &parent).unwrap();
        assert!(backup.restore().is_err());
        assert!(backup.is_pending().unwrap());
        assert_eq!(std::fs::read(outside_file).unwrap(), b"outside");
    }
}
