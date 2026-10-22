use super::types::{AccountId, Enrollment};
use crate::providers::Provider;
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub(crate) const MAX_ENROLLMENTS: usize = 32;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Document {
    schema_version: u8,
    accounts: Vec<Enrollment>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RouterBinding {
    enrollment_id: AccountId,
    generation: u64,
    router_account_id: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RouterBindings {
    schema_version: u8,
    bindings: Vec<RouterBinding>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PendingCommit {
    schema_version: u8,
    previous: Option<Document>,
    document: Document,
    router_bindings: RouterBindings,
}

pub(crate) struct Registry;

impl Registry {
    pub(crate) fn retire_codex(path: &Path) -> Result<()> {
        let _commit = commit_lock(path)?;
        let home = path
            .parent()
            .and_then(Path::parent)
            .context("Account registry is outside host state")?;
        let entries = snapshot_entries_locked(path)?;
        if super::codex_migration::is_committed(home)?
            && read_pending(path)?.is_none()
            && entries
                .iter()
                .all(|entry| entry.provider != Provider::Codex)
        {
            return Ok(());
        }
        let pending = PendingCommit {
            schema_version: 1,
            previous: read_document(path)?,
            document: Document {
                schema_version: 1,
                accounts: entries
                    .into_iter()
                    .filter(|entry| entry.provider != Provider::Codex)
                    .collect(),
            },
            router_bindings: empty_bindings(),
        };
        validate_pending_contents(&pending)?;
        super::codex_migration::prepare_commit(home, serde_json::to_value(&pending)?)?;
        crate::storage::private_state::write_json(&pending_path(path), &pending)?;
        super::codex_migration::mark_committed(home)?;
        crate::storage::private_state::write_json(path, &pending.document)?;
        crate::storage::private_state::write_json(&bindings_path(path), &pending.router_bindings)?;
        crate::storage::no_follow::Root::open(home)?.remove_tree(&pending_path(path))
    }

    pub(crate) fn snapshot_entries(path: &Path) -> Result<Vec<Enrollment>> {
        let _commit = commit_lock(path)?;
        snapshot_entries_locked(path)
    }
}

fn commit_lock(path: &Path) -> Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    let parent = path.parent().context("Account registry has no parent")?;
    match std::fs::symlink_metadata(parent) {
        Ok(metadata) => {
            ensure!(
                metadata.is_dir(),
                "Account registry parent is not a directory"
            );
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => private_directory(parent)?,
        Err(error) => return Err(error).context("Reading account registry parent"),
    }
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .custom_flags(libc::O_NOFOLLOW)
        .mode(0o600)
        .open(path.with_extension("commit.lock"))?;
    lock.lock()?;
    Ok(lock)
}

fn empty_document() -> Document {
    Document {
        schema_version: 1,
        accounts: Vec::new(),
    }
}

fn empty_bindings() -> RouterBindings {
    RouterBindings {
        schema_version: 1,
        bindings: Vec::new(),
    }
}

fn read_bindings(path: &Path) -> Result<Option<RouterBindings>> {
    read_json(&bindings_path(path), "Reading router account bindings")
}

fn snapshot_entries_locked(path: &Path) -> Result<Vec<Enrollment>> {
    let current = read_document(path)?;
    if let Some(document) = &current {
        validate_document(document)?;
    }
    if let Some(pending) = read_pending(path)? {
        return match resolve_pending(path, pending, current)? {
            PendingResolution::RollForward(document, bindings)
            | PendingResolution::Superseded(document, bindings) => hydrate(document, bindings),
        };
    }
    Ok(reconcile_bindings(
        current.unwrap_or(empty_document()),
        read_bindings(path)?.unwrap_or(empty_bindings()),
    )?
    .0)
}

fn bindings_path(path: &Path) -> PathBuf {
    path.with_extension("router-bindings.json")
}

fn pending_path(path: &Path) -> PathBuf {
    path.with_extension("pending.json")
}

fn read_json<T: serde::de::DeserializeOwned>(
    path: &Path,
    context: &'static str,
) -> Result<Option<T>> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(Some(
            serde_json::from_slice(&bytes).with_context(|| context)?,
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| context),
    }
}

fn read_document(path: &Path) -> Result<Option<Document>> {
    read_json(path, "Invalid account registry")
}

fn read_pending(path: &Path) -> Result<Option<PendingCommit>> {
    read_json(
        &pending_path(path),
        "Invalid pending account registry commit",
    )
}

fn validate_document(document: &Document) -> Result<()> {
    ensure!(
        document.schema_version == 1,
        "Unsupported account registry version"
    );
    ensure!(
        document.accounts.len() <= MAX_ENROLLMENTS,
        "At most {MAX_ENROLLMENTS} account enrollments are supported on one host"
    );
    let mut seen = std::collections::HashSet::new();
    for entry in &document.accounts {
        ensure!(
            seen.insert(entry.id.clone()),
            "Duplicate account enrollment"
        );
        validate_label(&entry.label)?;
        ensure!(entry.generation > 0, "Invalid account generation");
    }
    Ok(())
}

fn hydrate(mut document: Document, bindings: RouterBindings) -> Result<Vec<Enrollment>> {
    validate_document(&document)?;
    validate_binding_contents(&bindings)?;
    for binding in bindings.bindings {
        let entry = document
            .accounts
            .iter_mut()
            .find(|entry| entry.id == binding.enrollment_id)
            .context("Router binding has no account enrollment")?;
        ensure!(
            entry.provider == Provider::Codex && entry.generation == binding.generation,
            "Router binding does not match the account generation"
        );
        ensure!(
            entry
                .identity
                .as_ref()
                .and_then(|identity| identity.workspace.as_ref())
                == Some(&binding.router_account_id),
            "Router binding differs from the enrollment workspace"
        );
        entry.router_account_id = Some(binding.router_account_id);
    }
    Ok(document.accounts)
}

fn reconcile_bindings(
    document: Document,
    mut bindings: RouterBindings,
) -> Result<(Vec<Enrollment>, RouterBindings)> {
    validate_document(&document)?;
    validate_binding_contents(&bindings)?;
    bindings.bindings.retain(|binding| {
        let entry = document.accounts.iter().find(|entry| entry.id == binding.enrollment_id);
        if entry.is_none_or(|entry| entry.generation != binding.generation) {
            tracing::warn!(account = binding.enrollment_id.as_str(), generation = binding.generation,
                "Dropping superseded router account binding; native enrollment data remains authoritative");
            false
        } else { true }
    });
    let entries = hydrate(document, bindings.clone())?;
    Ok((entries, bindings))
}

fn validate_binding_contents(bindings: &RouterBindings) -> Result<()> {
    ensure!(
        bindings.schema_version == 1,
        "Unsupported router account binding version"
    );
    ensure!(
        bindings.bindings.len() <= MAX_ENROLLMENTS,
        "Too many router account bindings"
    );
    let mut seen = std::collections::HashSet::new();
    for binding in &bindings.bindings {
        ensure!(
            seen.insert(binding.enrollment_id.clone()),
            "Duplicate router account binding"
        );
        ensure!(binding.generation > 0, "Invalid router binding generation");
        ensure!(
            !binding.router_account_id.is_empty(),
            "Router account binding is empty"
        );
    }
    Ok(())
}

fn validate_pending_contents(pending: &PendingCommit) -> Result<()> {
    ensure!(
        pending.schema_version == 1,
        "Unsupported pending account registry commit version"
    );
    validate_document(&pending.document)?;
    if let Some(previous) = &pending.previous {
        validate_document(previous)?;
    }
    hydrate(pending.document.clone(), pending.router_bindings.clone())?;
    Ok(())
}

fn pending_matches_document(pending: &PendingCommit, current: &Option<Document>) -> Result<bool> {
    let current = serde_json::to_value(current)?;
    Ok(current == serde_json::to_value(&pending.previous)?
        || current == serde_json::to_value(&pending.document)?)
}

enum PendingResolution {
    RollForward(Document, RouterBindings),
    Superseded(Document, RouterBindings),
}

fn same_native_enrollment(left: &Enrollment, right: &Enrollment) -> bool {
    left.id == right.id
        && left.provider == right.provider
        && left.label == right.label
        && left.enabled == right.enabled
        && left.generation == right.generation
        && left.identity == right.identity
        && left.voice_account_id == right.voice_account_id
}

fn resolve_pending(
    path: &Path,
    pending: PendingCommit,
    current: Option<Document>,
) -> Result<PendingResolution> {
    validate_pending_contents(&pending)?;
    if let Some(document) = &current {
        validate_document(document)?;
    }
    if pending_matches_document(&pending, &current)? {
        return Ok(PendingResolution::RollForward(
            pending.document,
            pending.router_bindings,
        ));
    }
    let document = current.unwrap_or(empty_document());
    let mut bindings = read_bindings(path)?.unwrap_or(pending.router_bindings.clone());
    validate_binding_contents(&bindings)?;
    for binding in &mut bindings.bindings {
        let Some(entry) = document
            .accounts
            .iter()
            .find(|entry| entry.id == binding.enrollment_id)
        else {
            continue;
        };
        if entry.generation == binding.generation {
            continue;
        }
        let previous = pending.previous.as_ref().and_then(|previous| {
            previous
                .accounts
                .iter()
                .find(|previous| previous.id == binding.enrollment_id)
        });
        if previous.is_some_and(|previous| same_native_enrollment(entry, previous)) {
            ensure!(
                pending
                    .router_bindings
                    .bindings
                    .iter()
                    .any(|planned| planned.enrollment_id == binding.enrollment_id
                        && planned.generation == binding.generation
                        && planned.router_account_id == binding.router_account_id),
                "Router binding cannot be reconciled with its pending commit; preserve enrollment state"
            );
            binding.generation = entry.generation;
        }
    }
    let (_, bindings) = reconcile_bindings(document.clone(), bindings)?;
    Ok(PendingResolution::Superseded(document, bindings))
}

fn validate_label(label: &str) -> Result<&str> {
    let label = label.trim();
    ensure!(
        !label.is_empty() && label.chars().count() <= 80 && !label.chars().any(char::is_control),
        "Account label must contain 1–80 visible characters"
    );
    Ok(label)
}

pub(crate) fn private_directory(path: &Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    if let Ok(metadata) = std::fs::symlink_metadata(path) {
        ensure!(
            metadata.is_dir() && !metadata.file_type().is_symlink(),
            "Account state directory must not be a symlink"
        );
        // SAFETY: geteuid has no preconditions.
        ensure!(
            metadata.uid() == unsafe { libc::geteuid() },
            "Account state directory has another owner"
        );
    }
    crate::storage::private_state::ensure_private_directory(path)
}

#[cfg(test)]
mod retirement_tests {
    use super::*;

    #[test]
    fn retirement_pending_commit_hides_sources_before_canonical_registry_write() {
        let home = tempfile::tempdir().unwrap();
        let native = home.path().join(".codex");
        std::fs::create_dir(&native).unwrap();
        super::super::codex_migration::run(home.path(), &native, &home.path().join(".claude"))
            .unwrap();
        let path = home.path().join(".remote-coder/account-enrollments.json");
        let original: Document = serde_json::from_value(serde_json::json!({
            "schemaVersion": 1,
            "accounts": [{
                "id": "11111111-1111-1111-1111-111111111111", "provider": "codex",
                "label": "Retired", "enabled": true, "generation": 1, "identity": null
            }]
        }))
        .unwrap();
        crate::storage::private_state::write_json(&path, &original).unwrap();
        let pending = PendingCommit {
            schema_version: 1,
            previous: Some(original),
            document: empty_document(),
            router_bindings: empty_bindings(),
        };
        super::super::codex_migration::prepare_commit(
            home.path(),
            serde_json::to_value(&pending).unwrap(),
        )
        .unwrap();
        assert!(!super::super::codex_migration::is_committed(home.path()).unwrap());
        crate::storage::private_state::write_json(&pending_path(&path), &pending).unwrap();
        assert!(super::super::codex_migration::is_committed(home.path()).unwrap());
        assert!(Registry::snapshot_entries(&path).unwrap().is_empty());
        assert_eq!(read_document(&path).unwrap().unwrap().accounts.len(), 1);
        Registry::retire_codex(&path).unwrap();
        assert!(read_document(&path).unwrap().unwrap().accounts.is_empty());
        assert!(!pending_path(&path).exists());
        assert!(super::super::codex_migration::is_committed(home.path()).unwrap());
        Registry::retire_codex(&path).unwrap();
        assert!(Registry::snapshot_entries(&path).unwrap().is_empty());
    }
}
