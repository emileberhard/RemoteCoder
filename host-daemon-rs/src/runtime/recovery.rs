use std::collections::HashSet;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};

const SCHEMA_VERSION: u8 = 2;
const SHUTDOWN_MARKER_SCHEMA_VERSION: u8 = 1;
const MAX_RECOVERY_DEPTH: usize = 64;
const MAX_RECOVERY_ATTEMPTS: u8 = 5;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RecoveryJournal {
    pub schema_version: u8,
    pub generation_id: String,
    pub capability: String,
    pub created_at_unix_ms: u128,
    pub phase: RecoveryPhase,
    pub tasks: Vec<RecoveryTask>,
    pub runtime_swap: Option<RuntimeSwap>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub package_identity: Option<super::identity::PackageIdentity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<AccountRecovery>,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct AccountRecovery {
    pub account_id: String,
    pub enrollment_generation: u64,
    pub native_directory: PathBuf,
    pub source_sha256: String,
    pub target_sha256: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum RecoveryPhase {
    Captured,
    Suspending,
    Suspended,
    DaemonStopped,
    RuntimeInstalled,
    DaemonStarted,
    Recovering,
    Recovered,
    Completed,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RecoveryTask {
    pub thread_id: String,
    pub turn_id: String,
    pub parent_thread_id: Option<String>,
    pub depth: usize,
    pub recovery_attempts: u8,
    pub status: RecoveryTaskStatus,
    pub error: Option<String>,
}

impl RecoveryTask {
    pub(crate) fn update_status(&mut self, status: RecoveryTaskStatus, error: Option<String>) {
        if self.status.is_terminal() {
            return;
        }
        self.status = status;
        self.error = error;
    }

    pub(crate) fn record_failure(&mut self, retryable: bool, error: String) -> RecoveryTaskStatus {
        if self.status.is_terminal() {
            return self.status;
        }
        self.recovery_attempts = self.recovery_attempts.saturating_add(1);
        let status = if retryable && self.recovery_attempts < MAX_RECOVERY_ATTEMPTS {
            RecoveryTaskStatus::Retryable
        } else {
            RecoveryTaskStatus::Failed
        };
        self.update_status(status, Some(error));
        status
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum RecoveryTaskStatus {
    Captured,
    Suspended,
    Retryable,
    Running,
    Completed,
    Failed,
}

impl RecoveryTaskStatus {
    fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RuntimeSwap {
    pub had_release: bool,
    pub had_current: bool,
    pub previous_current_target: Option<PathBuf>,
    pub had_gateway_env: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_identity: Option<super::identity::PackageIdentity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_identity: Option<super::identity::PackageIdentity>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ShutdownRecoveryMarker<'a> {
    schema_version: u8,
    generation_id: &'a str,
    prepared_at_unix_ms: u128,
}

impl RecoveryJournal {
    pub(super) fn prepare_failed_retry(&mut self, captured: Vec<RecoveryTask>) -> Result<()> {
        for previous in self.pending_tasks() {
            ensure!(
                captured.iter().any(|current| {
                    current.thread_id == previous.thread_id && current.turn_id == previous.turn_id
                }),
                "previous recovery task {}:{} has no matching active capture; reconcile it before retrying failed tasks",
                previous.thread_id,
                previous.turn_id
            );
        }
        for current in &captured {
            if let Some(previous) = self.tasks.iter().find(|task| {
                task.thread_id == current.thread_id && task.status == RecoveryTaskStatus::Failed
            }) {
                ensure!(
                    previous.turn_id == current.turn_id,
                    "failed recovery thread {} is running a different turn",
                    current.thread_id
                );
            }
        }
        for task in &mut self.tasks {
            if task.status == RecoveryTaskStatus::Failed {
                task.status = RecoveryTaskStatus::Suspended;
                task.recovery_attempts = 0;
                task.error = None;
            }
        }
        for task in captured {
            if let Some(existing) = self
                .tasks
                .iter_mut()
                .find(|existing| existing.thread_id == task.thread_id)
            {
                *existing = task;
            } else {
                self.tasks.push(task);
            }
        }
        self.phase = RecoveryPhase::Suspending;
        self.error = None;
        self.validate()
    }

    pub fn new(
        generation_id: String,
        capability: String,
        tasks: Vec<RecoveryTask>,
    ) -> Result<Self> {
        let journal = Self {
            schema_version: SCHEMA_VERSION,
            generation_id,
            capability,
            created_at_unix_ms: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis(),
            phase: RecoveryPhase::Captured,
            tasks,
            runtime_swap: None,
            package_identity: None,
            account: None,
            error: None,
        };
        journal.validate()?;
        Ok(journal)
    }

    pub(crate) fn validate(&self) -> Result<()> {
        if self.schema_version != SCHEMA_VERSION {
            bail!(
                "unsupported recovery journal schema {}",
                self.schema_version
            );
        }
        if self.generation_id.is_empty() || self.generation_id.len() > 128 {
            bail!("invalid recovery generation id");
        }
        if self.capability.len() < 32 {
            bail!("recovery capability is too short");
        }
        if let Some(account) = &self.account
            && (account.account_id.len() != 36
                || account.enrollment_generation == 0
                || !account.native_directory.is_absolute()
                || account.source_sha256.len() != 64
                || !account
                    .source_sha256
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit())
                || account.target_sha256.len() != 64
                || !account
                    .target_sha256
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit())
                || self.runtime_swap.is_some())
        {
            bail!("invalid account recovery identity");
        }
        if let Some(identity) = &self.package_identity {
            identity.validate()?;
        }
        if let Some(identity) = self
            .runtime_swap
            .as_ref()
            .and_then(|swap| swap.source_identity.as_ref())
        {
            identity.validate()?;
        }
        if let Some(identity) = self
            .runtime_swap
            .as_ref()
            .and_then(|swap| swap.target_identity.as_ref())
        {
            identity.validate()?;
        }
        let mut thread_ids = HashSet::with_capacity(self.tasks.len());
        if self.tasks.len() > 10_000 {
            bail!("recovery journal exceeds the 10000-task safety bound");
        }
        for task in &self.tasks {
            if task.thread_id.is_empty()
                || task.thread_id.len() > 128
                || task.turn_id.is_empty()
                || task.turn_id.len() > 128
            {
                bail!("recovery task has an empty thread or turn id");
            }
            if task.depth > MAX_RECOVERY_DEPTH {
                bail!("recovery task depth exceeds {MAX_RECOVERY_DEPTH}");
            }
            if task.recovery_attempts > MAX_RECOVERY_ATTEMPTS {
                bail!("recovery task exceeds the retry-attempt safety bound");
            }
            if !thread_ids.insert(task.thread_id.as_str()) {
                bail!("duplicate recovery thread {}", task.thread_id);
            }
        }
        Ok(())
    }

    pub(crate) fn is_planned_transition(&self) -> bool {
        self.phase != RecoveryPhase::Completed && self.error.is_none()
    }

    pub(crate) fn is_prepared_handoff(&self) -> bool {
        self.phase == RecoveryPhase::DaemonStopped
            && self.error.is_none()
            && self.tasks.iter().all(|task| {
                matches!(
                    task.status,
                    RecoveryTaskStatus::Suspended | RecoveryTaskStatus::Completed
                )
            })
    }

    pub(crate) fn pending_tasks(&self) -> impl Iterator<Item = &RecoveryTask> {
        self.tasks.iter().filter(|task| {
            matches!(
                task.status,
                RecoveryTaskStatus::Captured
                    | RecoveryTaskStatus::Suspended
                    | RecoveryTaskStatus::Retryable
                    | RecoveryTaskStatus::Running
            )
        })
    }
}

#[derive(Clone, Debug)]
pub(crate) struct RecoveryStore {
    path: PathBuf,
    lock_path: PathBuf,
    #[cfg(test)]
    fail_next_write: std::sync::Arc<std::sync::atomic::AtomicBool>,
    #[cfg(test)]
    fail_after_next_rename: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

impl RecoveryStore {
    pub fn new(path: PathBuf) -> Self {
        let lock_path = path.with_extension("lock");
        Self {
            path,
            lock_path,
            #[cfg(test)]
            fail_next_write: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            #[cfg(test)]
            fail_after_next_rename: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
        }
    }

    #[cfg(test)]
    pub(crate) fn fail_next_write(&self) {
        self.fail_next_write
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(crate) fn fail_after_next_rename(&self) {
        self.fail_after_next_rename
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    pub(crate) fn default_path() -> Result<PathBuf> {
        Ok(crate::config::HostPaths::from_env()?.state("codex-restart-recovery.json"))
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn load(&self) -> Result<Option<RecoveryJournal>> {
        self.with_lock(|| self.load_unlocked())
    }

    pub(crate) fn write(&self, journal: &RecoveryJournal) -> Result<()> {
        journal.validate()?;
        self.with_lock(|| self.write_unlocked(journal))
    }

    pub(crate) fn update(
        &self,
        generation_id: &str,
        update: impl FnOnce(&mut RecoveryJournal) -> Result<()>,
    ) -> Result<RecoveryJournal> {
        self.with_lock(|| {
            let mut journal = self
                .load_unlocked()?
                .context("restart recovery journal is missing")?;
            if journal.generation_id != generation_id {
                bail!(
                    "recovery generation changed from {generation_id} to {}",
                    journal.generation_id
                );
            }
            update(&mut journal)?;
            journal.validate()?;
            self.write_unlocked(&journal)?;
            Ok(journal)
        })
    }

    pub(crate) fn set_phase(
        &self,
        generation_id: &str,
        phase: RecoveryPhase,
    ) -> Result<RecoveryJournal> {
        self.update(generation_id, |journal| {
            journal.phase = phase;
            Ok(())
        })
    }

    pub(crate) fn write_shutdown_marker(&self, generation_id: &str) -> Result<()> {
        self.with_lock(|| {
            let journal = self
                .load_unlocked()?
                .context("restart recovery journal is missing")?;
            if journal.generation_id != generation_id
                || journal.phase != RecoveryPhase::DaemonStopped
            {
                bail!("shutdown marker requires the matching stopped recovery generation");
            }
            let marker = ShutdownRecoveryMarker {
                schema_version: SHUTDOWN_MARKER_SCHEMA_VERSION,
                generation_id,
                prepared_at_unix_ms: SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis(),
            };
            self.write_private_json_unlocked(&self.shutdown_marker_path(), &marker)
        })
    }

    fn shutdown_marker_path(&self) -> PathBuf {
        self.path.with_file_name("nightly-reboot-recovery.json")
    }

    fn with_lock<T>(&self, operation: impl FnOnce() -> Result<T>) -> Result<T> {
        let parent = self
            .path
            .parent()
            .context("recovery journal has no parent directory")?;
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOFOLLOW)
            .mode(0o600)
            .open(&self.lock_path)
            .with_context(|| format!("failed to open {}", self.lock_path.display()))?;
        lock.lock()
            .with_context(|| format!("failed to lock {}", self.lock_path.display()))?;
        operation()
    }

    fn load_unlocked(&self) -> Result<Option<RecoveryJournal>> {
        let metadata = match std::fs::symlink_metadata(&self.path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("failed to inspect {}", self.path.display()));
            }
        };
        if !metadata.file_type().is_file() {
            bail!(
                "recovery journal is not a regular file: {}",
                self.path.display()
            );
        }
        if metadata.uid() != unsafe { libc::getuid() } || metadata.permissions().mode() & 0o077 != 0
        {
            bail!(
                "recovery journal must be owned by the current user and private: {}",
                self.path.display()
            );
        }
        let bytes = std::fs::read(&self.path)
            .with_context(|| format!("failed to read {}", self.path.display()))?;
        let journal: RecoveryJournal = serde_json::from_slice(&bytes)
            .with_context(|| format!("failed to parse {}", self.path.display()))?;
        journal.validate()?;
        Ok(Some(journal))
    }

    fn write_unlocked(&self, journal: &RecoveryJournal) -> Result<()> {
        self.write_private_json_unlocked(&self.path, journal)
    }

    fn write_private_json_unlocked(&self, path: &Path, value: &impl Serialize) -> Result<()> {
        #[cfg(test)]
        if self
            .fail_next_write
            .swap(false, std::sync::atomic::Ordering::SeqCst)
        {
            bail!("injected recovery journal write failure");
        }
        let mut bytes = serde_json::to_vec_pretty(value)?;
        bytes.push(b'\n');
        let published = crate::storage::private_state::replace(path, &bytes);
        #[cfg(test)]
        let published = published.and_then(|()| {
            if self
                .fail_after_next_rename
                .swap(false, std::sync::atomic::Ordering::SeqCst)
            {
                bail!("injected recovery journal directory-sync failure after rename");
            }
            Ok(())
        });
        published.with_context(|| format!("failed to write {}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task() -> RecoveryTask {
        RecoveryTask {
            thread_id: "018f0000-0000-7000-8000-000000000001".to_string(),
            turn_id: "turn-1".to_string(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 0,
            status: RecoveryTaskStatus::Captured,
            error: None,
        }
    }

    #[test]
    fn journal_round_trip_preserves_typed_state() {
        let directory = tempfile::tempdir().expect("tempdir");
        let store = RecoveryStore::new(directory.path().join("recovery.json"));
        let journal = RecoveryJournal::new(
            "generation-1".to_string(),
            "0123456789abcdef0123456789abcdef".to_string(),
            vec![task()],
        )
        .expect("journal");
        store.write(&journal).expect("write journal");

        assert_eq!(store.load().expect("load journal"), Some(journal));
    }

    #[test]
    fn update_rejects_a_different_generation() {
        let directory = tempfile::tempdir().expect("tempdir");
        let store = RecoveryStore::new(directory.path().join("recovery.json"));
        store
            .write(
                &RecoveryJournal::new(
                    "generation-1".to_string(),
                    "0123456789abcdef0123456789abcdef".to_string(),
                    vec![task()],
                )
                .expect("journal"),
            )
            .expect("write journal");

        assert!(store.update("generation-2", |_| Ok(())).is_err());
    }

    #[test]
    fn duplicate_targets_fail_validation() {
        let task = task();
        assert!(
            RecoveryJournal::new(
                "generation-1".to_string(),
                "0123456789abcdef0123456789abcdef".to_string(),
                vec![task.clone(), task],
            )
            .is_err()
        );
    }

    #[test]
    fn sparse_active_descendant_depth_is_valid() {
        let mut active_descendant = task();
        active_descendant.depth = 2;

        RecoveryJournal::new(
            "generation-1".to_string(),
            "0123456789abcdef0123456789abcdef".to_string(),
            vec![active_descendant],
        )
        .expect("one active descendant may have idle ancestors");
    }

    #[test]
    fn only_nonterminal_tasks_are_pending() {
        let statuses = [
            RecoveryTaskStatus::Captured,
            RecoveryTaskStatus::Suspended,
            RecoveryTaskStatus::Retryable,
            RecoveryTaskStatus::Running,
            RecoveryTaskStatus::Completed,
            RecoveryTaskStatus::Failed,
        ];
        let tasks = statuses
            .into_iter()
            .enumerate()
            .map(|(index, status)| RecoveryTask {
                thread_id: format!("thread-{index}"),
                turn_id: format!("turn-{index}"),
                parent_thread_id: None,
                depth: 0,
                recovery_attempts: 0,
                status,
                error: None,
            })
            .collect();
        let journal = RecoveryJournal::new(
            "generation-1".to_string(),
            "0123456789abcdef0123456789abcdef".to_string(),
            tasks,
        )
        .expect("journal");

        assert_eq!(
            journal
                .pending_tasks()
                .map(|task| task.thread_id.as_str())
                .collect::<Vec<_>>(),
            ["thread-0", "thread-1", "thread-2", "thread-3"]
        );
    }

    #[test]
    fn prepared_handoff_requires_stopped_recoverable_tasks() {
        let mut journal = RecoveryJournal::new(
            "generation-1".to_string(),
            "0123456789abcdef0123456789abcdef".to_string(),
            vec![task()],
        )
        .expect("recovery journal");
        journal.phase = RecoveryPhase::DaemonStopped;
        journal.tasks[0].status = RecoveryTaskStatus::Suspended;
        assert!(journal.is_prepared_handoff());

        journal.tasks[0].status = RecoveryTaskStatus::Running;
        assert!(!journal.is_prepared_handoff());
        journal.tasks[0].status = RecoveryTaskStatus::Suspended;
        journal.phase = RecoveryPhase::Completed;
        assert!(!journal.is_prepared_handoff());
        journal.phase = RecoveryPhase::DaemonStopped;
        journal.error = Some("failed".to_string());
        assert!(!journal.is_prepared_handoff());
    }

    #[test]
    fn a_terminal_task_cannot_regress_to_running() {
        for terminal in [RecoveryTaskStatus::Completed, RecoveryTaskStatus::Failed] {
            let mut task = task();
            task.status = terminal;
            task.update_status(
                RecoveryTaskStatus::Running,
                Some("late acknowledgement".to_string()),
            );

            assert_eq!(task.status, terminal);
            assert_eq!(task.error, None);
        }
    }

    #[test]
    fn retryable_failures_have_a_persisted_budget() {
        let mut task = task();
        for attempt in 1..MAX_RECOVERY_ATTEMPTS {
            assert_eq!(
                task.record_failure(true, format!("attempt {attempt}")),
                RecoveryTaskStatus::Retryable
            );
        }
        assert_eq!(
            task.record_failure(true, "last attempt".to_string()),
            RecoveryTaskStatus::Failed
        );
        assert_eq!(task.recovery_attempts, MAX_RECOVERY_ATTEMPTS);
    }

    #[test]
    fn explicit_failed_retry_preserves_exact_targets_and_captures_current_work() {
        let mut failed = task();
        failed.status = RecoveryTaskStatus::Failed;
        failed.recovery_attempts = 1;
        failed.error = Some("restart recovery is not authorized".to_owned());
        let mut current = task();
        current.thread_id = "current-thread".to_owned();
        current.turn_id = "current-turn".to_owned();
        let mut journal = RecoveryJournal::new(
            "original-generation".to_owned(),
            "0123456789abcdef0123456789abcdef".to_owned(),
            vec![failed.clone()],
        )
        .unwrap();
        journal.phase = RecoveryPhase::Completed;
        let before = journal.clone();
        let mut changed = current.clone();
        changed.thread_id.clone_from(&failed.thread_id);
        assert!(journal.prepare_failed_retry(vec![changed]).is_err());
        assert_eq!(journal, before);

        journal.prepare_failed_retry(vec![current.clone()]).unwrap();

        assert_eq!(journal.generation_id, "original-generation");
        assert_eq!(journal.capability, before.capability);
        assert_eq!(journal.tasks[0].thread_id, failed.thread_id);
        assert_eq!(journal.tasks[0].turn_id, failed.turn_id);
        assert_eq!(journal.tasks[0].status, RecoveryTaskStatus::Suspended);
        assert_eq!(journal.tasks[0].recovery_attempts, 0);
        assert_eq!(journal.tasks[1], current);
        assert_eq!(journal.phase, RecoveryPhase::Suspending);
    }

    #[test]
    fn failed_retry_refuses_unreconciled_previous_work() {
        let mut failed = task();
        failed.status = RecoveryTaskStatus::Failed;
        let mut previous = task();
        previous.thread_id = "previous-thread".to_owned();
        previous.status = RecoveryTaskStatus::Running;
        let mut journal = RecoveryJournal::new(
            "generation-1".to_owned(),
            "0123456789abcdef0123456789abcdef".to_owned(),
            vec![failed, previous],
        )
        .unwrap();
        journal.phase = RecoveryPhase::Completed;
        let original = journal.clone();

        assert!(journal.prepare_failed_retry(Vec::new()).is_err());
        assert_eq!(journal, original);
    }

    #[test]
    fn shutdown_marker_names_the_stopped_generation() {
        let directory = tempfile::tempdir().expect("tempdir");
        let store = RecoveryStore::new(directory.path().join("recovery.json"));
        let mut journal = RecoveryJournal::new(
            "generation-1".to_string(),
            "0123456789abcdef0123456789abcdef".to_string(),
            vec![task()],
        )
        .expect("journal");
        journal.phase = RecoveryPhase::DaemonStopped;
        store.write(&journal).expect("write journal");

        store
            .write_shutdown_marker("generation-1")
            .expect("write shutdown marker");

        let marker: serde_json::Value = serde_json::from_slice(
            &std::fs::read(directory.path().join("nightly-reboot-recovery.json"))
                .expect("read marker"),
        )
        .expect("parse marker");
        assert_eq!(marker["generationId"], "generation-1");
        assert_eq!(marker["schemaVersion"], 1);
    }
}
