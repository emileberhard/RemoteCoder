use crate::storage::no_follow::{EntryKind, Root};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
#[cfg(test)]
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};

const RECEIPT: &str = "claude-profile-migration.json";

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Receipt {
    pub(crate) retired_ids: BTreeSet<String>,
    pub(crate) sessions: BTreeSet<String>,
    pub(crate) conflicts: Vec<Conflict>,
    pub(crate) memory_indexes: BTreeSet<PathBuf>,
    metadata_threads: BTreeSet<String>,
    #[serde(default)]
    complete: bool,
    #[serde(default)]
    pub(crate) ambiguous_sessions: BTreeMap<String, AmbiguousSession>,
    completed: BTreeSet<String>,
    pending: Vec<Operation>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AmbiguousSession {
    pub(crate) paths: BTreeSet<PathBuf>,
    pub(crate) reason: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Conflict {
    pub(crate) canonical: PathBuf,
    pub(crate) preserved: PathBuf,
    pub(crate) owner: Option<String>,
    pub(crate) selection: String,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
enum Operation {
    Copy { source: PathBuf, target: PathBuf },
    Replace { source: PathBuf, target: PathBuf },
    Bytes { target: PathBuf, value: Vec<u8> },
    Write { target: PathBuf, value: Value },
}

struct MigrationFiles {
    home: Root,
    home_path: PathBuf,
    profile_path: PathBuf,
    profile: Option<Root>,
}

impl MigrationFiles {
    fn open(home: &Path, target: &Path) -> Result<Self> {
        Ok(Self {
            home: Root::open(home)?,
            home_path: home.to_owned(),
            profile_path: target.to_owned(),
            profile: if target.starts_with(home) {
                None
            } else {
                Some(Root::open(target)?)
            },
        })
    }

    fn root(&self, path: &Path) -> Result<&Root> {
        if path.starts_with(&self.home_path) {
            Ok(&self.home)
        } else {
            self.profile
                .as_ref()
                .context("Claude migration path is outside its owned roots")
        }
    }

    fn read_json(&self, path: &Path) -> Result<Option<Value>> {
        read_json_from(self.root(path)?, path)
    }

    fn write_json(&self, path: &Path, value: &impl Serialize) -> Result<()> {
        self.root(path)?.write_json(path, value)
    }

    fn clone_file(&self, source: &Path, target: &Path) -> Result<()> {
        self.root(target)?
            .clone_from(self.root(source)?, source, target)
    }
}

fn read_json_from(root: &Root, path: &Path) -> Result<Option<Value>> {
    root.read(path)?
        .map(|bytes| {
            serde_json::from_slice(&bytes)
                .with_context(|| format!("Reading Claude migration state {}", path.display()))
        })
        .transpose()
}

impl Receipt {
    fn is_settled(&self) -> bool {
        self.complete && self.pending.is_empty()
    }
}

fn host_receipt(home: &Path) -> Result<Receipt> {
    load_receipt(
        &Root::open(home)?,
        &home.join(".remote-coder").join(RECEIPT),
    )
}

pub(crate) fn retired_ids(home: &Path) -> Result<BTreeSet<String>> {
    Ok(host_receipt(home)?.retired_ids)
}

pub(crate) fn is_settled(home: &Path) -> Result<bool> {
    Ok(host_receipt(home)?.is_settled())
}

pub(crate) fn run(home: &Path, claude_home: &Path) -> Result<Receipt> {
    let files = MigrationFiles::open(home, claude_home)?;
    let state = home.join(".remote-coder");
    let receipt_path = state.join(RECEIPT);
    let _lock = files.home.lock_file(&receipt_path.with_extension("lock"))?;
    let mut receipt = load_receipt(&files.home, &receipt_path)?;
    if receipt.is_settled() {
        return Ok(receipt);
    }
    if receipt.complete {
        apply_pending(&files, &mut receipt)?;
        files.write_json(&receipt_path, &receipt)?;
        return Ok(receipt);
    }
    migrate(
        &files,
        home,
        claude_home,
        &state,
        &receipt_path,
        &mut receipt,
    )?;
    files.write_json(&receipt_path, &receipt)?;
    Ok(receipt)
}

fn load_receipt(root: &Root, path: &Path) -> Result<Receipt> {
    match read_json_from(root, path)? {
        Some(value) => serde_json::from_value(value).context("Invalid Claude migration receipt"),
        None => Ok(Receipt::default()),
    }
}

fn migrate(
    files: &MigrationFiles,
    home: &Path,
    target: &Path,
    state: &Path,
    receipt_path: &Path,
    receipt: &mut Receipt,
) -> Result<()> {
    apply_pending(files, receipt)?;
    let registry_path = state.join("account-enrollments.json");
    let mut registry = files.read_json(&registry_path)?;
    let handoff_path = state.join("conversation-handoffs.json");
    let handoffs = files
        .read_json(&handoff_path)?
        .unwrap_or(Value::Array(Vec::new()));
    let mut owners = handoff_owners(&handoffs)
        .with_context(|| format!("Reading Claude handoff owners {}", handoff_path.display()))?;
    let profiles = discover_profiles(files, home, &registry, receipt)?;
    restart_owners(files, &mut owners, &handoffs, &profiles, state)?;
    let mut fallback_reasons = BTreeMap::new();
    native_owners(
        files,
        target,
        &profiles,
        &mut owners,
        &mut fallback_reasons,
        receipt,
    )?;
    ensure!(
        receipt.ambiguous_sessions.is_empty(),
        "Claude migration cannot select canonical history: {}",
        receipt
            .ambiguous_sessions
            .iter()
            .map(|(session, ambiguity)| format!(
                "{session}: {} [{}]",
                ambiguity.reason,
                ambiguity
                    .paths
                    .iter()
                    .map(|path| path.display().to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            ))
            .collect::<Vec<_>>()
            .join("; ")
    );
    files.write_json(receipt_path, receipt)?;
    apply_pending(files, receipt)?;
    merge_handoff_recovery(files, &handoffs, state)?;
    files.write_json(receipt_path, receipt)?;
    for (id, profile) in profiles {
        if receipt.completed.contains(&id) {
            continue;
        }
        let conflicts = state.join("claude-profile-conflicts").join(&id);
        let mut operations = Vec::new();
        for directory in [
            "projects",
            "remotecoder-agents",
            "session-env",
            "remotecoder-history",
            "memory",
        ] {
            plan_tree(
                &profile.join("claude").join(directory),
                &target.join(directory),
                &conflicts.join(directory),
                &mut FilePlan {
                    files,
                    id: &id,
                    owners: &owners,
                    fallback_reasons: &fallback_reasons,
                    receipt,
                    operations: &mut operations,
                },
            )
            .with_context(|| {
                format!(
                    "Planning Claude profile {id} directory {}",
                    profile.join("claude").join(directory).display()
                )
            })?;
        }
        let profile_state = profile.join("state");
        for name in [
            "session-metadata-v2.json",
            "agent-calls.json",
            "conversation-marks.json",
            "claude-restart-recovery.json",
        ] {
            if let Some(mut incoming) = files.read_json(&profile_state.join(name))? {
                if name == "claude-restart-recovery.json" {
                    incoming["account"] = Value::Null;
                }
                let destination = state.join(name);
                let existing = files.read_json(&destination)?;
                if existing
                    .as_ref()
                    .is_some_and(|existing| existing != &incoming)
                {
                    preserve_state_variants(
                        &profile_state.join(name),
                        &destination,
                        &conflicts.join("state").join(name),
                        receipt,
                        &mut operations,
                    );
                }
                let mut merged = existing.unwrap_or_else(|| incoming.clone());
                if name == "claude-restart-recovery.json" {
                    merged["account"] = Value::Null;
                }
                if name == "session-metadata-v2.json" {
                    receipt.metadata_threads.extend(
                        incoming["records"]
                            .as_object()
                            .with_context(|| {
                                format!(
                                    "Invalid Claude profile {id} metadata {}",
                                    profile_state.join(name).display()
                                )
                            })?
                            .keys()
                            .cloned(),
                    );
                }
                merge_state(name, &mut merged, incoming, &id, &owners).with_context(|| {
                    format!(
                        "Merging Claude profile {id} state {}",
                        profile_state.join(name).display()
                    )
                })?;
                operations.push(Operation::Write {
                    target: destination,
                    value: merged,
                });
            }
        }
        operations.extend(
            plan_questions(
                files,
                &profile_state.join("questions"),
                &state.join("questions"),
                &id,
                &owners,
                &conflicts.join("state/questions"),
                receipt,
            )
            .with_context(|| {
                format!(
                    "Merging Claude profile {id} questions {}",
                    profile_state.join("questions").display()
                )
            })?,
        );
        receipt.pending = operations;
        files.write_json(receipt_path, receipt)?;
        apply_pending(files, receipt)?;
        receipt.completed.insert(id);
        files.write_json(receipt_path, receipt)?;
    }
    if let Some(document) = registry.as_mut() {
        let accounts = document["accounts"]
            .as_array_mut()
            .context("Invalid account registry")?;
        accounts.retain(|entry| entry["provider"] != "claude");
        receipt.pending.push(Operation::Write {
            target: registry_path,
            value: document.clone(),
        });
    }
    if files.home.open_file(&handoff_path)?.is_some() {
        let mut retained = handoffs;
        retained
            .as_array_mut()
            .context("Invalid handoff records")?
            .retain(|transfer| !is_claude_transfer(transfer));
        receipt.pending.push(Operation::Write {
            target: handoff_path,
            value: retained,
        });
    }
    let metadata_path = state.join("session-metadata-v2.json");
    if !receipt.metadata_threads.is_empty() {
        let mut metadata = files
            .read_json(&metadata_path)?
            .context("Missing migrated session metadata")?;
        for thread in &receipt.metadata_threads {
            let record = &mut metadata["records"][thread];
            let revision = record["serverRevision"]
                .as_u64()
                .context("Invalid merged metadata revision")?
                .checked_add(1)
                .context("Metadata revision exhausted")?;
            record["serverRevision"] = revision.into();
        }
        receipt.pending.push(Operation::Write {
            target: metadata_path,
            value: metadata,
        });
    }
    receipt.complete = true;
    files.write_json(receipt_path, receipt)?;
    apply_pending(files, receipt)?;
    Ok(())
}

fn discover_profiles(
    files: &MigrationFiles,
    home: &Path,
    registry: &Option<Value>,
    receipt: &mut Receipt,
) -> Result<BTreeMap<String, PathBuf>> {
    let mut profiles = BTreeMap::new();
    if let Some(accounts) = registry.as_ref().and_then(|v| v["accounts"].as_array()) {
        for entry in accounts
            .iter()
            .filter(|entry| entry["provider"] == "claude")
        {
            let id = entry["id"]
                .as_str()
                .context("Claude enrollment has no ID")?
                .to_owned();
            receipt.retired_ids.insert(id.clone());
            profiles.insert(id.clone(), home.join(".rca").join(id.replace('-', "")));
        }
    }
    let root = home.join(".rca");
    for name in files.home.read_directory(&root)? {
        let profile = root.join(&name);
        if files.home.entry_kind(&profile)? != Some(EntryKind::Directory)
            || files.home.entry_kind(&profile.join("claude"))? != Some(EntryKind::Directory)
        {
            continue;
        }
        let name = name
            .into_string()
            .map_err(|_| anyhow::anyhow!("Invalid Claude profile directory name"))?;
        ensure!(
            name.len() == 32 && name.bytes().all(|byte| byte.is_ascii_hexdigit()),
            "Invalid Claude profile ID"
        );
        let uuid = format!(
            "{}-{}-{}-{}-{}",
            &name[..8],
            &name[8..12],
            &name[12..16],
            &name[16..20],
            &name[20..]
        )
        .to_ascii_lowercase();
        receipt.retired_ids.insert(uuid.clone());
        profiles.insert(uuid, profile);
    }
    Ok(profiles)
}

pub(crate) fn rollback_profile_files(home: &Path, target: &Path) -> Result<BTreeSet<PathBuf>> {
    let state = home.join(".remote-coder");
    let files = MigrationFiles::open(home, target)?;
    let mut receipt = load_receipt(&files.home, &state.join(RECEIPT))?;
    if receipt.complete && receipt.pending.is_empty() {
        return Ok(BTreeSet::new());
    }
    let registry = files.read_json(&state.join("account-enrollments.json"))?;
    let profiles = discover_profiles(&files, home, &registry, &mut receipt)?;
    let mut targets = BTreeSet::new();
    for (id, profile) in profiles {
        if receipt.completed.contains(&id) {
            continue;
        }
        for directory in [
            "projects",
            "remotecoder-agents",
            "session-env",
            "remotecoder-history",
            "memory",
        ] {
            let source = profile.join("claude").join(directory);
            let mut incoming = Vec::new();
            regular_files(files.root(&source)?, &source, &mut incoming)?;
            for file in incoming {
                let destination = target.join(directory).join(file.strip_prefix(&source)?);
                let destination = resolve_project_target(&files, &file, &destination)?;
                targets.insert(destination);
            }
        }
    }
    for operation in receipt.pending {
        if let Operation::Replace { target, .. }
        | Operation::Write { target, .. }
        | Operation::Bytes { target, .. } = operation
        {
            targets.insert(target);
        }
    }
    let mut existing = BTreeSet::new();
    for path in targets {
        if path.starts_with(target) && files.root(&path)?.open_file(&path)?.is_some() {
            existing.insert(path);
        }
    }
    Ok(existing)
}

fn copy_operation(source: PathBuf, target: PathBuf) -> Operation {
    Operation::Copy { source, target }
}

fn apply_pending(files: &MigrationFiles, receipt: &mut Receipt) -> Result<()> {
    for operation in &receipt.pending {
        match operation {
            Operation::Copy { source, target } => {
                if files.root(target)?.open_file(target)?.is_some() {
                    continue;
                }
                files.clone_file(source, target)?;
            }
            Operation::Replace { source, target } => {
                files.clone_file(source, target)?;
            }
            Operation::Write { target, value } => {
                files.write_json(target, value)?;
            }
            Operation::Bytes { target, value } => {
                files.root(target)?.replace(target, value)?;
            }
        }
    }
    receipt.pending.clear();
    Ok(())
}

fn merge_handoff_recovery(files: &MigrationFiles, handoffs: &Value, state: &Path) -> Result<()> {
    let items = handoffs
        .as_array()
        .context("Invalid handoff records")?
        .iter()
        .filter(|transfer| is_claude_transfer(transfer))
        .filter_map(|transfer| transfer.get("recovery"))
        .filter(|item| item["status"] == "captured" || item["status"] == "dispatching")
        .cloned()
        .collect::<Vec<_>>();
    if items.is_empty() {
        return Ok(());
    }
    let path = state.join("claude-restart-recovery.json");
    let mut journal = files.read_json(&path)?.unwrap_or_else(|| serde_json::json!({
        "schemaVersion": 2, "generationId": crate::ids::new_session_uuid(), "account": null, "items": []
    }));
    journal["account"] = Value::Null;
    let incoming = serde_json::json!({"schemaVersion":2,"generationId":crate::ids::new_session_uuid(),"account":null,"items":items});
    journal = merge_restart(journal, incoming, &BTreeSet::new())?;
    files.write_json(&path, &journal)
}

fn is_claude_transfer(transfer: &Value) -> bool {
    transfer["request"]["threadId"]
        .as_str()
        .is_some_and(|id| id.starts_with("claude_"))
}

fn handoff_owners(handoffs: &Value) -> Result<BTreeMap<String, Option<String>>> {
    let mut sorted = handoffs
        .as_array()
        .context("Invalid handoff records")?
        .iter()
        .filter(|transfer| is_claude_transfer(transfer))
        .collect::<Vec<_>>();
    sorted.sort_by(|a, b| {
        a["fork_started_at"]
            .as_f64()
            .unwrap_or(0.0)
            .total_cmp(&b["fork_started_at"].as_f64().unwrap_or(0.0))
    });
    let mut owners = BTreeMap::new();
    for transfer in sorted {
        let thread = transfer["request"]["threadId"]
            .as_str()
            .context("Handoff has no thread ID")?;
        let side = if transfer["aborted"] == true || transfer["complete"] != true {
            "source"
        } else {
            "target"
        };
        let account = transfer["request"][side]["accountId"]
            .as_str()
            .map(str::to_owned);
        owners.insert(
            thread.trim_start_matches("claude_").to_owned(),
            account.clone(),
        );
        owners.insert(format!("{:x}", Sha256::digest(thread.as_bytes())), account);
    }
    Ok(owners)
}

fn restart_owners(
    files: &MigrationFiles,
    owners: &mut BTreeMap<String, Option<String>>,
    handoffs: &Value,
    profiles: &BTreeMap<String, PathBuf>,
    state: &Path,
) -> Result<()> {
    let mut recorded = BTreeMap::<String, u64>::new();
    for transfer in handoffs
        .as_array()
        .context("Invalid handoff records")?
        .iter()
        .filter(|transfer| is_claude_transfer(transfer))
    {
        let thread = transfer["request"]["threadId"]
            .as_str()
            .context("Handoff has no thread ID")?
            .to_owned();
        let timestamp = transfer["fork_started_at"].as_f64().unwrap_or(0.0) * 1000.0;
        recorded
            .entry(thread)
            .and_modify(|old| *old = (*old).max(timestamp as u64))
            .or_insert(timestamp as u64);
    }
    let paths = profiles
        .iter()
        .map(|(id, profile)| {
            (
                Some(id.clone()),
                profile.join("state/claude-restart-recovery.json"),
            )
        })
        .chain(std::iter::once((
            None,
            state.join("claude-restart-recovery.json"),
        )));
    for (profile_id, path) in paths {
        let Some(value) = files.read_json(&path)? else {
            continue;
        };
        let journal: crate::providers::claude::restart::Journal =
            serde_json::from_value(crate::providers::claude::restart::migrate(value))
                .with_context(|| {
                    format!("Invalid Claude recovery owner journal {}", path.display())
                })?;
        let account = journal.account.as_ref().map(|account| account.id.clone());
        ensure!(
            account == profile_id,
            "Claude recovery owner does not match profile {}; original preserved",
            path.display()
        );
        for item in journal
            .items
            .into_iter()
            .filter(|item| item.status.is_pending())
        {
            let latest = recorded.entry(item.thread_id.clone()).or_insert(0);
            if item.captured_at_unix_ms >= *latest {
                *latest = item.captured_at_unix_ms;
                owners.insert(
                    item.thread_id.trim_start_matches("claude_").to_owned(),
                    account.clone(),
                );
                owners.insert(
                    format!("{:x}", Sha256::digest(item.thread_id.as_bytes())),
                    account.clone(),
                );
            }
        }
    }
    Ok(())
}

fn native_sessions(files: &MigrationFiles, home: &Path) -> Result<Vec<(String, PathBuf)>> {
    let mut sessions = Vec::new();
    let projects = home.join("projects");
    let root = files.root(&projects)?;
    for name in root.read_directory(&projects)? {
        let project = projects.join(name);
        if root.entry_kind(&project)? != Some(EntryKind::Directory) {
            continue;
        }
        for name in root.read_directory(&project)? {
            let file = project.join(name);
            if root.entry_kind(&file)? != Some(EntryKind::File) {
                continue;
            }
            if file
                .extension()
                .is_none_or(|extension| extension != "jsonl")
            {
                continue;
            }
            let Some(session) = file
                .file_stem()
                .and_then(|name| name.to_str())
                .filter(|session| crate::ids::is_session_uuid(session))
            else {
                continue;
            };
            sessions.push((session.to_owned(), file));
        }
    }
    Ok(sessions)
}

pub(crate) fn thread_ids(home: &Path, claude_home: &Path) -> Result<BTreeSet<String>> {
    let files = MigrationFiles::open(home, claude_home)?;
    Ok(native_sessions(&files, claude_home)?
        .into_iter()
        .map(|(session, _)| crate::providers::claude::claude_thread_id(&session))
        .collect())
}

pub(crate) fn retired_read_scopes(home: &Path) -> Result<BTreeMap<String, BTreeSet<String>>> {
    let root = Root::open(home)?;
    let mut scopes = BTreeMap::new();
    for id in host_receipt(home)?.retired_ids {
        let profile = home.join(".rca").join(id.replace('-', ""));
        let claude = profile.join("claude");
        if root.entry_kind(&claude)? != Some(EntryKind::Directory) {
            continue;
        }
        let mut threads = thread_ids(home, &claude)?;
        if let Some(marks) = crate::conversation_marks::migration_document(&profile.join("state"))?
        {
            threads.extend(
                marks["threads"]
                    .as_object()
                    .context("Invalid retired Claude marks")?
                    .keys()
                    .cloned(),
            );
        }
        scopes.insert(id, threads);
    }
    Ok(scopes)
}

fn native_owners(
    files: &MigrationFiles,
    target: &Path,
    profiles: &BTreeMap<String, PathBuf>,
    owners: &mut BTreeMap<String, Option<String>>,
    reasons: &mut BTreeMap<String, String>,
    receipt: &mut Receipt,
) -> Result<()> {
    let mut sessions = BTreeMap::<String, Vec<(Option<String>, PathBuf)>>::new();
    let homes = profiles
        .iter()
        .map(|(id, profile)| (Some(id.clone()), profile.join("claude")))
        .chain(std::iter::once((None, target.to_owned())));
    for (id, home) in homes {
        for (session, file) in native_sessions(files, &home)? {
            sessions
                .entry(session)
                .or_default()
                .push((id.clone(), file));
        }
    }
    for (session, candidates) in sessions.into_iter().filter(|(_, candidates)| {
        candidates.len() > 1 && candidates.iter().any(|(id, _)| id.is_some())
    }) {
        let paths = candidates
            .iter()
            .map(|(_, path)| path.clone())
            .collect::<BTreeSet<_>>();
        if candidates.iter().filter(|(id, _)| id.is_none()).count() > 1 {
            receipt.ambiguous_sessions.insert(
                session.clone(),
                AmbiguousSession {
                    paths,
                    reason: "Multiple host project paths prevent exact session ownership"
                        .to_owned(),
                },
            );
            continue;
        }
        if owners.contains_key(&session) {
            continue;
        }
        let sizes = candidates
            .iter()
            .map(|candidate| -> Result<_> {
                Ok((
                    files
                        .root(&candidate.1)?
                        .open_file(&candidate.1)?
                        .context("Missing transcript candidate")?
                        .metadata()?
                        .len(),
                    candidate,
                ))
            })
            .collect::<Result<Vec<_>>>()?;
        let longest = sizes
            .into_iter()
            .max_by_key(|(bytes, _)| *bytes)
            .context("Missing transcript candidate")?
            .1;
        let mut all_prefixes = true;
        for (_, path) in &candidates {
            if !matches!(
                prefix_comparison(files, path, &longest.1)?,
                Comparison::Equal | Comparison::SourcePrefix
            ) {
                all_prefixes = false;
                break;
            }
        }
        if all_prefixes {
            let owner = longest.0.clone();
            let thread = format!("claude_{session}");
            let reason = "Byte-prefix transcript merge; kept the longer copy".to_owned();
            owners.insert(session.clone(), owner.clone());
            owners.insert(format!("{:x}", Sha256::digest(thread.as_bytes())), owner);
            reasons.insert(session, reason.clone());
            reasons.insert(format!("{:x}", Sha256::digest(thread.as_bytes())), reason);
            continue;
        }
        let mut ambiguous = false;
        let mut canonical: Option<(Option<String>, PathBuf, NativeHistory)> = None;
        let mut metadata_only = true;
        for (id, path) in candidates {
            let history = match native_history(files, &path) {
                Ok(history) => history,
                Err(_) => {
                    receipt.ambiguous_sessions.insert(
                        session.clone(),
                        AmbiguousSession {
                            paths: paths.clone(),
                            reason: "Native root transcript cannot establish historical ownership"
                                .to_owned(),
                        },
                    );
                    ambiguous = true;
                    break;
                }
            };
            if let Some((canonical_id, _, previous)) = &canonical {
                let same_history = history.messages == previous.messages;
                metadata_only &= same_history;
                if !same_history
                    && (history.latest.is_none()
                        || previous.latest.is_none()
                        || history.latest == previous.latest)
                {
                    receipt.ambiguous_sessions.insert(session.clone(), AmbiguousSession { paths: paths.clone(), reason: "Divergent root histories lack an authoritative owner and distinct conversation timestamps".to_owned() });
                    ambiguous = true;
                    break;
                }
                if history.latest > previous.latest
                    || (same_history && id.is_none() && canonical_id.is_some())
                {
                    canonical = Some((id, path, history));
                }
            } else {
                canonical = Some((id, path, history));
            }
        }
        if ambiguous {
            continue;
        }
        let (owner, _, history) = canonical.context("Missing canonical session candidate")?;
        let reason = if metadata_only {
            "Identical root conversation identities; metadata-only conflict".to_owned()
        } else {
            format!(
                "No recorded handoff/recovery owner; latest native root conversation timestamp {}",
                history
                    .latest
                    .context("Missing selected conversation timestamp")?
            )
        };
        let thread = format!("claude_{session}");
        owners.insert(session.clone(), owner.clone());
        owners.insert(format!("{:x}", Sha256::digest(thread.as_bytes())), owner);
        reasons.insert(session, reason.clone());
        reasons.insert(format!("{:x}", Sha256::digest(thread.as_bytes())), reason);
    }
    Ok(())
}

struct NativeHistory {
    messages: BTreeSet<String>,
    latest: Option<i64>,
}

fn native_history(files: &MigrationFiles, path: &Path) -> Result<NativeHistory> {
    let mut reader = BufReader::new(
        files
            .root(path)?
            .open_file(path)?
            .context("Missing Claude transcript")?,
    );
    let mut line = Vec::new();
    let mut history = NativeHistory {
        messages: BTreeSet::new(),
        latest: None,
    };
    loop {
        line.clear();
        if reader.read_until(b'\n', &mut line)? == 0 {
            break;
        }
        let record: Value = serde_json::from_slice(&line)
            .with_context(|| format!("Reading Claude transcript {}", path.display()))?;
        if record["isSidechain"] == true
            || !matches!(record["type"].as_str(), Some("user" | "assistant"))
        {
            continue;
        }
        let identity = format!(
            "{}:{:x}",
            record["uuid"]
                .as_str()
                .context("Native root message has no UUID")?,
            Sha256::digest(serde_json::to_vec(&record["message"])?)
        );
        history.messages.insert(identity);
        if let Some(timestamp) = record["timestamp"]
            .as_str()
            .and_then(crate::time::parse_rfc3339_millis)
        {
            history.latest = history.latest.max(Some(timestamp));
        }
    }
    Ok(history)
}

struct FilePlan<'a> {
    files: &'a MigrationFiles,
    id: &'a str,
    owners: &'a BTreeMap<String, Option<String>>,
    fallback_reasons: &'a BTreeMap<String, String>,
    receipt: &'a mut Receipt,
    operations: &'a mut Vec<Operation>,
}

fn regular_files(root: &Root, path: &Path, output: &mut Vec<PathBuf>) -> Result<()> {
    match root.entry_kind(path)? {
        None => Ok(()),
        Some(EntryKind::Directory) => {
            for name in root.read_directory(path)? {
                regular_files(root, &path.join(name), output)?;
            }
            Ok(())
        }
        Some(EntryKind::File) => {
            output.push(path.to_owned());
            Ok(())
        }
        Some(_) => anyhow::bail!(
            "Claude migration refuses nonregular entry {}",
            path.display()
        ),
    }
}

fn plan_tree(
    source: &Path,
    target: &Path,
    conflicts: &Path,
    plan: &mut FilePlan<'_>,
) -> Result<()> {
    let mut incoming = Vec::new();
    regular_files(plan.files.root(source)?, source, &mut incoming)?;
    for file in incoming {
        let relative = file.strip_prefix(source)?;
        plan_file(
            &file,
            &target.join(relative),
            &conflicts.join(relative),
            plan,
        )?;
    }
    Ok(())
}

fn plan_file(
    source: &Path,
    target: &Path,
    conflicts: &Path,
    plan: &mut FilePlan<'_>,
) -> Result<()> {
    let resolved = resolve_project_target(plan.files, source, target)?;
    let target = resolved.as_path();
    plan.files.root(target)?.validate_path(target)?;
    let existing = plan.files.root(target)?.open_file(target)?;
    let session = source
        .file_stem()
        .and_then(|s| s.to_str())
        .filter(|s| crate::ids::is_session_uuid(s));
    if let Some(session) = session {
        plan.receipt.sessions.insert(session.to_owned());
    }
    if source.file_name().is_some_and(|name| name == "MEMORY.md")
        && source
            .parent()
            .is_some_and(|parent| parent.file_name().is_some_and(|name| name == "memory"))
    {
        let existing =
            String::from_utf8(plan.files.root(target)?.read(target)?.unwrap_or_default())
                .with_context(|| format!("Reading memory index {}", target.display()))?;
        let incoming = String::from_utf8(
            plan.files
                .root(source)?
                .read(source)?
                .context("Missing memory index")?,
        )
        .with_context(|| format!("Reading memory index {}", source.display()))?;
        let mut seen = BTreeSet::new();
        let lines = existing
            .lines()
            .chain(incoming.lines())
            .filter(|line| seen.insert((*line).to_owned()))
            .collect::<Vec<_>>();
        plan.operations.push(Operation::Bytes {
            target: target.to_owned(),
            value: format!("{}\n", lines.join("\n")).into_bytes(),
        });
        plan.receipt.memory_indexes.insert(target.to_owned());
        return Ok(());
    }
    if existing.is_none() {
        plan.operations
            .push(copy_operation(source.to_owned(), target.to_owned()));
        return Ok(());
    }
    if source
        .extension()
        .is_some_and(|extension| extension == "parent")
    {
        let incoming = plan
            .files
            .read_json(source)?
            .context("Missing parent ledger")?;
        let existing = plan
            .files
            .read_json(target)?
            .context("Missing host parent ledger")?;
        let owner = source
            .file_stem()
            .and_then(|name| name.to_str())
            .and_then(|name| plan.owners.get(name))
            .and_then(|owner| owner.as_deref());
        let merged = merge_parent(existing, incoming, owner == Some(plan.id))?;
        plan.operations.push(Operation::Write {
            target: target.to_owned(),
            value: merged,
        });
        return Ok(());
    }
    let comparison = prefix_comparison(plan.files, source, target)?;
    if comparison == Comparison::Equal || comparison == Comparison::SourcePrefix {
        return Ok(());
    }
    let owner = source
        .ancestors()
        .filter_map(|path| path.file_stem().and_then(|name| name.to_str()))
        .find_map(|name| plan.owners.get(name))
        .cloned()
        .flatten();
    let incoming_wins = comparison == Comparison::TargetPrefix || owner.as_deref() == Some(plan.id);
    if comparison == Comparison::Diverged {
        let preserved = conflicts.to_owned();
        plan.receipt.conflicts.push(Conflict {
            canonical: target.to_owned(),
            preserved: preserved.clone(),
            selection: source
                .ancestors()
                .filter_map(|path| path.file_stem().and_then(|name| name.to_str()))
                .find_map(|name| plan.fallback_reasons.get(name))
                .cloned()
                .unwrap_or_else(|| {
                    owner
                        .as_deref()
                        .map(|owner| {
                            format!("Latest recorded handoff or pending recovery owner: {owner}")
                        })
                        .unwrap_or_else(|| {
                            "Recorded host-default owner or metadata-only existing copy".to_owned()
                        })
                }),
            owner,
        });
        if !incoming_wins {
            plan.operations
                .push(copy_operation(source.to_owned(), preserved));
        }
    }
    if incoming_wins {
        if comparison == Comparison::Diverged {
            plan.operations
                .push(copy_operation(target.to_owned(), conflicts.to_owned()));
        }
        plan.operations.push(Operation::Replace {
            source: source.to_owned(),
            target: target.to_owned(),
        });
    }
    Ok(())
}

fn resolve_project_alias(
    files: &MigrationFiles,
    projects: &Path,
    target: &Path,
) -> Result<PathBuf> {
    let relative = target.strip_prefix(projects)?;
    let mut parts = relative.components();
    let Some(std::path::Component::Normal(project)) = parts.next() else {
        return Ok(target.to_owned());
    };
    let alias = projects.join(project);
    let root = files.root(&alias)?;
    if root.entry_kind(&alias)? != Some(EntryKind::Symlink) {
        return Ok(target.to_owned());
    }
    let link = root.read_link(&alias)?;
    let destination = if link.is_absolute() {
        link
    } else {
        projects.join(link)
    };
    ensure!(
        destination.parent() == Some(projects)
            && root.entry_kind(&destination)? == Some(EntryKind::Directory),
        "Claude project alias {} must point directly to a real directory in {}",
        alias.display(),
        projects.display()
    );
    Ok(destination.join(parts.as_path()))
}

fn resolve_project_target(files: &MigrationFiles, source: &Path, target: &Path) -> Result<PathBuf> {
    let projects = files.profile_path.join("projects");
    if !target.starts_with(&projects) {
        return Ok(target.to_owned());
    }
    let target = resolve_project_alias(files, &projects, target)?;
    let Some(session_path) = source.ancestors().find(|path| {
        path.file_stem()
            .and_then(|name| name.to_str())
            .is_some_and(crate::ids::is_session_uuid)
    }) else {
        return Ok(target.to_owned());
    };
    let session = session_path
        .file_stem()
        .and_then(|name| name.to_str())
        .context("Invalid transcript session")?;
    let mut candidates = Vec::new();
    let root = files.root(&projects)?;
    for name in root.read_directory(&projects)? {
        let project = projects.join(name);
        if root.entry_kind(&project)? != Some(EntryKind::Directory) {
            continue;
        }
        let candidate = project.join(format!("{session}.jsonl"));
        if root.entry_kind(&candidate)? == Some(EntryKind::File) {
            candidates.push(candidate);
        }
    }
    ensure!(
        candidates.len() <= 1,
        "Claude host already contains duplicate session {session} in multiple projects; reconcile before migration"
    );
    let Some(transcript) = candidates.pop() else {
        return Ok(target.to_owned());
    };
    if session_path == source
        && source
            .extension()
            .is_some_and(|extension| extension == "jsonl")
    {
        return Ok(transcript);
    }
    Ok(transcript
        .parent()
        .context("Transcript has no project")?
        .join(session)
        .join(source.strip_prefix(session_path)?))
}

#[derive(PartialEq)]
enum Comparison {
    Equal,
    SourcePrefix,
    TargetPrefix,
    Diverged,
}

fn prefix_comparison(files: &MigrationFiles, source: &Path, target: &Path) -> Result<Comparison> {
    let mut left = BufReader::new(
        files
            .root(source)?
            .open_file(source)?
            .context("Missing source history")?,
    );
    let mut right = BufReader::new(
        files
            .root(target)?
            .open_file(target)?
            .context("Missing target history")?,
    );
    let mut a = [0; 65536];
    let mut b = [0; 65536];
    loop {
        let an = fill(&mut left, &mut a)?;
        let bn = fill(&mut right, &mut b)?;
        let shared = an.min(bn);
        if a[..shared] != b[..shared] {
            return Ok(Comparison::Diverged);
        }
        if an == 0 && bn == 0 {
            return Ok(Comparison::Equal);
        }
        if an < bn {
            return Ok(Comparison::SourcePrefix);
        }
        if bn < an {
            return Ok(Comparison::TargetPrefix);
        }
    }
}

fn fill(reader: &mut impl Read, buffer: &mut [u8]) -> Result<usize> {
    let mut used = 0;
    while used < buffer.len() {
        let count = reader.read(&mut buffer[used..])?;
        if count == 0 {
            break;
        }
        used += count;
    }
    Ok(used)
}

fn preserve_state_variants(
    source: &Path,
    target: &Path,
    conflicts: &Path,
    receipt: &mut Receipt,
    operations: &mut Vec<Operation>,
) {
    for (original, side) in [(target, "host"), (source, "incoming")] {
        let preserved = conflicts.with_extension(format!("{side}.json"));
        receipt.conflicts.push(Conflict {
            canonical: target.to_owned(),
            preserved: preserved.clone(),
            owner: None,
            selection: "Merged state document; preserved pre-merge variant".into(),
        });
        operations.push(copy_operation(original.to_owned(), preserved));
    }
}

fn plan_questions(
    files: &MigrationFiles,
    source: &Path,
    target: &Path,
    id: &str,
    owners: &BTreeMap<String, Option<String>>,
    conflicts: &Path,
    receipt: &mut Receipt,
) -> Result<Vec<Operation>> {
    let mut operations = Vec::new();
    for name in files.root(source)?.read_directory(source)? {
        let entry = source.join(name);
        if entry
            .extension()
            .is_some_and(|extension| extension == "json")
        {
            let incoming = files.read_json(&entry)?.context("Missing question state")?;
            let destination = target.join(entry.file_name().context("Question file has no name")?);
            let existing = files.read_json(&destination)?;
            if existing
                .as_ref()
                .is_some_and(|existing| existing != &incoming)
            {
                preserve_state_variants(
                    &entry,
                    &destination,
                    &conflicts.join(entry.file_name().context("Question file has no name")?),
                    receipt,
                    &mut operations,
                );
            }
            let mut merged = existing.unwrap_or_else(|| incoming.clone());
            let owner = incoming["threadId"]
                .as_str()
                .and_then(|thread| owners.get(thread.trim_start_matches("claude_")))
                .and_then(|owner| owner.as_deref());
            let incoming_owner = owner == Some(id);
            merged = merge_questions(merged, incoming, incoming_owner)?;
            operations.push(Operation::Write {
                target: destination,
                value: merged,
            });
        }
    }
    Ok(operations)
}

fn merge_restart(
    existing: Value,
    incoming: Value,
    incoming_owners: &BTreeSet<String>,
) -> Result<Value> {
    use crate::providers::claude::restart::{Item, Journal};
    let existing: Journal =
        serde_json::from_value(crate::providers::claude::restart::migrate(existing))
            .context("Invalid host restart journal")?;
    let incoming: Journal =
        serde_json::from_value(crate::providers::claude::restart::migrate(incoming))
            .context("Invalid migrated restart journal")?;
    let mut threads = BTreeMap::<String, Item>::new();
    for item in existing.items {
        threads.insert(item.thread_id.clone(), item);
    }
    for item in incoming.items {
        if let Some(previous) = threads.remove(&item.thread_id) {
            let same = previous.recovery_id == item.recovery_id;
            let choose_incoming = item.stop_generation > previous.stop_generation
                || (item.stop_generation == previous.stop_generation
                    && (incoming_owners.contains(&item.thread_id)
                        || item.captured_at_unix_ms > previous.captured_at_unix_ms));
            let (mut canonical, other) = if choose_incoming {
                (item, previous)
            } else {
                (previous, item)
            };
            for input in &other.queued_inputs {
                if !canonical.queued_inputs.contains(input) {
                    canonical.queued_inputs.push(input.clone());
                }
            }
            canonical.stop_generation = canonical.stop_generation.max(other.stop_generation);
            if same {
                canonical.attempts = canonical.attempts.max(other.attempts);
                if let (Some(current), Some(previous)) =
                    (&canonical.resumed_turn_id, &other.resumed_turn_id)
                {
                    ensure!(
                        current == previous,
                        "Claude recovery has conflicting resumed turn IDs; originals preserved"
                    );
                }
                canonical.resumed_turn_id =
                    canonical.resumed_turn_id.or(other.resumed_turn_id.clone());
                if recovery_progress(other.status) > recovery_progress(canonical.status) {
                    canonical.status = other.status;
                    canonical.error = other.error.clone();
                }
                for task in other.background_tasks {
                    if !canonical
                        .background_tasks
                        .iter()
                        .any(|existing| existing.id == task.id)
                    {
                        canonical.background_tasks.push(task);
                    }
                }
                for wake in other.scheduled_wakes {
                    if !canonical.scheduled_wakes.contains(&wake) {
                        canonical.scheduled_wakes.push(wake);
                    }
                }
                canonical.earlier_events.extend(other.earlier_events);
            } else {
                canonical.absorb(other);
            }
            canonical
                .earlier_events
                .sort_by_key(|event| event.captured_at_unix_ms);
            canonical.earlier_events.dedup();
            threads.insert(canonical.thread_id.clone(), canonical);
        } else {
            threads.insert(item.thread_id.clone(), item);
        }
    }
    let journal = Journal::capture(None, threads.into_values().collect(), None)?;
    serde_json::to_value(journal).context("Encoding migrated restart journal")
}

fn recovery_progress(status: crate::providers::claude::restart::ItemStatus) -> u8 {
    use crate::providers::claude::restart::ItemStatus;
    match status {
        ItemStatus::Captured => 0,
        ItemStatus::Dispatching => 1,
        ItemStatus::Failed => 2,
        ItemStatus::Dispatched => 3,
        ItemStatus::Stopped => 4,
    }
}

fn merge_parent(existing: Value, incoming: Value, incoming_owner: bool) -> Result<Value> {
    ensure!(
        existing["threadId"] == incoming["threadId"],
        "Mismatched Claude parent threads"
    );
    let mut canonical = if incoming_owner {
        incoming.clone()
    } else {
        existing.clone()
    };
    let old = if incoming_owner {
        existing.clone()
    } else {
        incoming.clone()
    };
    let incoming_generation = incoming["parent"]["stopGeneration"].as_u64().unwrap_or(0);
    let existing_generation = existing["parent"]["stopGeneration"].as_u64().unwrap_or(0);
    let latest = if incoming_generation > existing_generation
        || (incoming_generation == existing_generation && incoming_owner)
    {
        &incoming
    } else {
        &existing
    };
    canonical["parent"]["stopped"] = latest["parent"]["stopped"].clone();
    canonical["parent"]["stopGeneration"] = incoming_generation.max(existing_generation).into();
    let deliveries = canonical["parent"]["deliveries"]
        .as_array_mut()
        .context("Invalid parent deliveries")?;
    for delivery in old["parent"]["deliveries"]
        .as_array()
        .context("Invalid incoming parent deliveries")?
    {
        match deliveries
            .iter()
            .find(|existing| existing["id"] == delivery["id"])
        {
            Some(existing) => ensure!(
                existing["fingerprint"] == delivery["fingerprint"],
                "Claude parent delivery ID has conflicting fingerprints"
            ),
            None => deliveries.push(delivery.clone()),
        }
    }
    ensure!(
        deliveries.len() <= 256,
        "Merged Claude parent delivery ledger exceeds 256 entries; original ledgers preserved, reconcile before startup"
    );
    serde_json::from_value::<crate::providers::claude::conversation_index::Parent>(
        canonical["parent"].clone(),
    )
    .context("Invalid merged parent ledger")?;
    Ok(canonical)
}

pub(super) fn merge_questions(
    existing: Value,
    incoming: Value,
    incoming_owner: bool,
) -> Result<Value> {
    ensure!(
        existing["threadId"] == incoming["threadId"],
        "Mismatched question threads"
    );
    let mut canonical = if incoming_owner {
        incoming.clone()
    } else {
        existing.clone()
    };
    let other = if incoming_owner { existing } else { incoming };
    for field in ["dismissals", "incomplete"] {
        let target = canonical[field]
            .as_object_mut()
            .context("Invalid question map")?;
        for (key, value) in other[field]
            .as_object()
            .context("Invalid incoming question map")?
        {
            target.entry(key.clone()).or_insert_with(|| value.clone());
        }
    }
    for field in ["definitions", "answers"] {
        let target = canonical["facts"][field]
            .as_object_mut()
            .context("Invalid question facts")?;
        for (key, value) in other["facts"][field]
            .as_object()
            .context("Invalid incoming question facts")?
        {
            target.entry(key.clone()).or_insert_with(|| value.clone());
        }
    }
    let alerted = canonical["alerted"]
        .as_array_mut()
        .context("Invalid alerted questions")?;
    for value in other["alerted"]
        .as_array()
        .context("Invalid incoming alerted questions")?
    {
        if !alerted.contains(value) {
            alerted.push(value.clone());
        }
    }
    let revision = canonical["revision"]
        .as_u64()
        .context("Invalid question revision")?
        .max(
            other["revision"]
                .as_u64()
                .context("Invalid incoming question revision")?,
        )
        .checked_add(1)
        .context("Question revision exhausted")?;
    canonical["epoch"] = crate::ids::new_session_uuid().replace('-', "").into();
    canonical["revision"] = revision.into();
    canonical["writer"] = Value::Null;
    canonical["scan"] = Value::Null;
    let revisions = canonical["facts"]["definitions"]
        .as_object()
        .context("Invalid question definitions")?
        .keys()
        .map(|key| (key.clone(), Value::from(revision)))
        .collect::<serde_json::Map<_, _>>();
    canonical["recordRevisions"] = Value::Object(revisions);
    serde_json::from_value::<crate::questions::Document>(canonical.clone())
        .context("Invalid merged question document")?;
    Ok(canonical)
}

pub(super) fn merge_state(
    name: &str,
    target: &mut Value,
    incoming: Value,
    id: &str,
    owners: &BTreeMap<String, Option<String>>,
) -> Result<()> {
    if name == "claude-restart-recovery.json" {
        let incoming_owners = incoming["items"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|item| item["threadId"].as_str())
            .filter(|thread| {
                owners
                    .get(thread.trim_start_matches("claude_"))
                    .and_then(|owner| owner.as_deref())
                    == Some(id)
            })
            .map(str::to_owned)
            .collect::<BTreeSet<_>>();
        *target = merge_restart(target.clone(), incoming, &incoming_owners)?;
        return Ok(());
    }
    if name == "session-metadata-v2.json" {
        let records = target["records"]
            .as_object_mut()
            .context("Invalid session metadata records")?;
        for (thread, record) in incoming["records"]
            .as_object()
            .context("Invalid incoming session metadata records")?
        {
            let existing = records.get(thread);
            let revision = record["serverRevision"]
                .as_u64()
                .context("Invalid incoming metadata revision")?
                .max(
                    existing
                        .map(|record| {
                            record["serverRevision"]
                                .as_u64()
                                .context("Invalid metadata revision")
                        })
                        .transpose()?
                        .unwrap_or(0),
                );
            let newer = existing.is_none_or(|existing| {
                record["updatedAt"].as_f64().unwrap_or(0.0)
                    > existing["updatedAt"].as_f64().unwrap_or(0.0)
            });
            if newer {
                records.insert(thread.clone(), record.clone());
            }
            records
                .get_mut(thread)
                .context("Missing merged metadata record")?["serverRevision"] = revision.into();
        }
        return Ok(());
    }
    if name == "conversation-marks.json" {
        let baseline = target["readBaseline"]
            .as_i64()
            .context("Invalid marks baseline")?
            .min(
                incoming["readBaseline"]
                    .as_i64()
                    .context("Invalid incoming marks baseline")?,
            );
        let revision = target["revision"]
            .as_u64()
            .context("Invalid marks revision")?
            .max(
                incoming["revision"]
                    .as_u64()
                    .context("Invalid incoming marks revision")?,
            )
            .checked_add(1)
            .context("Marks revision exhausted")?;
        let threads = target["threads"]
            .as_object_mut()
            .context("Invalid conversation marks")?;
        for (thread, marks) in incoming["threads"]
            .as_object()
            .context("Invalid incoming conversation marks")?
        {
            let owner = owners
                .get(thread.trim_start_matches("claude_"))
                .and_then(|owner| owner.as_deref());
            if !threads.contains_key(thread) || owner == Some(id) {
                threads.insert(thread.clone(), marks.clone());
            }
        }
        for marks in threads.values_mut() {
            marks["revision"] = revision.into();
        }
        target["revision"] = revision.into();
        target["readBaseline"] = baseline.into();
        return Ok(());
    }
    merge(target, incoming);
    Ok(())
}

fn merge(target: &mut Value, incoming: Value) {
    match (target, incoming) {
        (Value::Object(target), Value::Object(incoming)) => {
            for (key, value) in incoming {
                match target.get_mut(&key) {
                    Some(existing) => merge(existing, value),
                    None => {
                        target.insert(key, value);
                    }
                }
            }
        }
        (Value::Array(target), Value::Array(incoming)) => {
            for value in incoming {
                let identity = value.get("callId").or_else(|| value.get("recoveryId"));
                if let Some(index) = identity.and_then(|id| {
                    target.iter().position(|existing| {
                        existing
                            .get("callId")
                            .or_else(|| existing.get("recoveryId"))
                            == Some(id)
                    })
                }) {
                    merge(&mut target[index], value);
                } else if !target.contains(&value) {
                    target.push(value);
                }
            }
        }
        (target, incoming) => {
            if target.is_null() {
                *target = incoming;
            } else if let (Some(a), Some(b)) = (target.as_f64(), incoming.as_f64())
                && b > a
            {
                *target = incoming;
            }
        }
    }
}

#[cfg(test)]
fn read_json(path: &Path) -> Result<Option<Value>> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .with_context(|| format!("Reading Claude migration state {}", path.display()))
            .map(Some),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => {
            Err(error).with_context(|| format!("Reading Claude migration state {}", path.display()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const ID: &str = "c4d47fdb-aaaa-4444-8888-000000000001";
    const SESSION: &str = "aaaaaaaa-bbbb-4444-8888-cccccccccccc";

    fn write(path: &Path, bytes: &[u8]) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }

    fn native_rows(timestamps: &[u8]) -> Vec<u8> {
        timestamps.iter().flat_map(|timestamp| { let mut row = serde_json::to_vec(&json!({"type":"user","uuid":format!("message-{timestamp}"),"timestamp":format!("2026-10-05T00:00:{timestamp:02}.000Z"),"message":{"content":format!("message-{timestamp}")},"isSidechain":false})).unwrap(); row.push(b'\n'); row }).collect()
    }

    fn metadata_record(thread: &str, updated: f64) -> Value {
        json!({"sessionID":thread,"modelID":"claude-sonnet-4-6","reasoningSelectionID":"high","fastModeEnabled":false,"source":"runtime","updatedAt":updated,"serverRevision":1,"mutationId":null})
    }

    fn restart_item(thread: &str, recovery: &str, timestamp: u64) -> Value {
        json!({"recoveryId":recovery,"threadId":thread,"sessionUuid":SESSION,"cwd":"/tmp","model":"claude-sonnet-4-6","effort":"high","cause":"restart","interruptedTurnId":null,"agentInitiated":false,"backgroundTasks":[],"capturedAtUnixMs":timestamp,"status":"captured","attempts":0,"resumedTurnId":null,"error":null})
    }

    fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let directory = tempfile::tempdir().unwrap();
        let profile = directory.path().join(".rca").join(ID.replace('-', ""));
        let host = directory.path().join(".claude");
        (directory, profile, host)
    }

    #[tokio::test]
    async fn claude_migration_orphan_prefix_metadata_and_restart_are_preserved() {
        let (home, profile, host) = fixture();
        let transcript = format!("projects/project/{SESSION}.jsonl");
        write(
            &profile.join("claude").join(&transcript),
            native_rows(&[1, 2]).as_slice(),
        );
        write(&host.join(&transcript), native_rows(&[1]).as_slice());
        write(
            &profile.join("claude/session-env").join(SESSION).join("env"),
            b"environment",
        );
        write(
            &profile.join("state/session-metadata-v2.json"),
            &serde_json::to_vec(
                &json!({"schemaVersion":1,"records":{"claude_a":metadata_record("claude_a", 2.0)}}),
            )
            .unwrap(),
        );
        write(
            &home.path().join(".remote-coder/session-metadata-v2.json"),
            &serde_json::to_vec(
                &json!({"schemaVersion":1,"records":{"claude_b":metadata_record("claude_b", 1.0)}}),
            )
            .unwrap(),
        );
        write(&profile.join("state/claude-restart-recovery.json"), &serde_json::to_vec(&json!({"schemaVersion":2,"generationId":"generation","account":{"id":ID,"generation":4},"items":[restart_item("claude_a", "pending", 2)]})).unwrap());
        let thread = crate::providers::claude::claude_thread_id(SESSION);
        crate::providers::claude::conversation_index::Store::new(profile.join("claude"))
            .record_minted(&thread)
            .await
            .unwrap();
        let receipt = run(home.path(), &host).unwrap();
        assert!(
            crate::providers::claude::conversation_index::Store::new(host.clone())
                .is_minted(&thread)
                .unwrap()
        );
        assert_eq!(
            fs::read(host.join(&transcript)).unwrap(),
            native_rows(&[1, 2]).as_slice()
        );
        assert!(host.join("session-env").join(SESSION).join("env").exists());
        assert!(receipt.retired_ids.contains(ID));
        assert!(receipt.sessions.contains(SESSION));
        assert!(profile.join("claude").exists());
        let metadata = read_json(&home.path().join(".remote-coder/session-metadata-v2.json"))
            .unwrap()
            .unwrap();
        assert_eq!(metadata["records"].as_object().unwrap().len(), 2);
        let journal = read_json(
            &home
                .path()
                .join(".remote-coder/claude-restart-recovery.json"),
        )
        .unwrap()
        .unwrap();
        assert!(journal["account"].is_null());
        assert_eq!(journal["items"][0]["recoveryId"], "pending");
        let read = crate::conversations::ConversationMetadataStore::new(Some(
            home.path().join(".remote-coder/session-metadata-v2.json"),
        ))
        .read()
        .await
        .unwrap();
        assert_eq!(read.len(), 2);
        let journal = crate::providers::claude::restart::Store::beside(
            &home.path().join(".remote-coder/active-codex-turns.json"),
        )
        .load()
        .unwrap()
        .unwrap();
        assert_eq!(journal.items.len(), 1);
        let rerun = run(home.path(), &host).unwrap();
        assert_eq!(receipt.memory_indexes, rerun.memory_indexes);
        assert_eq!(receipt.sessions, rerun.sessions);
    }

    #[test]
    fn claude_migration_handoff_owner_selects_divergence_and_keeps_other_copy() {
        let (home, profile, host) = fixture();
        let transcript = format!("projects/project/{SESSION}.jsonl");
        write(
            &profile.join("claude").join(&transcript),
            native_rows(&[2]).as_slice(),
        );
        write(&host.join(&transcript), native_rows(&[1]).as_slice());
        write(&home.path().join(".remote-coder/conversation-handoffs.json"), &serde_json::to_vec(&json!([
            {"request":{"threadId":format!("claude_{SESSION}"),"source":{"accountId":null},"target":{"accountId":ID}},"fork_started_at":2,"destination":{},"aborted":false,"complete":true},
            {"request":{"threadId":"codex-thread"},"fork_started_at":3}
        ])).unwrap());
        let receipt = run(home.path(), &host).unwrap();
        assert_eq!(
            fs::read(host.join(&transcript)).unwrap(),
            native_rows(&[2]).as_slice()
        );
        assert_eq!(receipt.conflicts.len(), 1);
        assert_eq!(
            fs::read(&receipt.conflicts[0].preserved).unwrap(),
            native_rows(&[1]).as_slice()
        );
        assert_eq!(
            read_json(&home.path().join(".remote-coder/conversation-handoffs.json"))
                .unwrap()
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn claude_migration_resumes_between_replacement_copies() {
        let (home, profile, host) = fixture();
        let source = profile
            .join("claude/projects/project")
            .join(format!("{SESSION}.jsonl"));
        let target = host
            .join("projects/project")
            .join(format!("{SESSION}.jsonl"));
        let archive = home
            .path()
            .join(".remote-coder/claude-profile-conflicts/old.jsonl");
        write(&source, b"new");
        write(&target, b"old");
        let mut receipt = Receipt::default();
        receipt
            .pending
            .push(copy_operation(target.clone(), archive.clone()));
        receipt.pending.push(Operation::Replace {
            source: source.clone(),
            target: target.clone(),
        });
        fs::create_dir_all(archive.parent().unwrap()).unwrap();
        let root = Root::open(home.path()).unwrap();
        root.clone_from(&root, &target, &archive).unwrap();
        root.clone_from(&root, &source, &target).unwrap();
        let path = home.path().join(".remote-coder").join(RECEIPT);
        crate::storage::private_state::write_json(&path, &receipt).unwrap();
        run(home.path(), &host).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"new");
        assert_eq!(fs::read(&archive).unwrap(), b"old");
        assert!(retired_ids(home.path()).unwrap().contains(ID));
    }

    #[test]
    fn claude_migration_never_removes_codex_enrollment_or_native_profile() {
        let (home, profile, host) = fixture();
        write(
            &profile
                .join("claude/projects/project")
                .join(format!("{SESSION}.jsonl")),
            b"claude",
        );
        write(&profile.join("c/rollouts/native.jsonl"), b"codex");
        let registry = home.path().join(".remote-coder/account-enrollments.json");
        write(&registry, &serde_json::to_vec(&json!({"schemaVersion":1,"accounts":[{"id":ID,"provider":"claude"},{"id":"codex","provider":"codex"}]})).unwrap());
        run(home.path(), &host).unwrap();
        assert_eq!(
            read_json(&registry).unwrap().unwrap()["accounts"],
            json!([{"id":"codex","provider":"codex"}])
        );
        assert_eq!(
            fs::read(profile.join("c/rollouts/native.jsonl")).unwrap(),
            b"codex"
        );
    }
    #[test]
    fn claude_migration_parent_deliveries_and_owner_stop_state_survive() {
        let existing = json!({"threadId":"claude_a","parent":{"selection":null,"stopped":true,"stopGeneration":2,"deliveries":[{"id":"one","fingerprint":"first","receipt":{}}]}});
        let incoming = json!({"threadId":"claude_a","parent":{"selection":{"cwd":"/tmp","model":"sonnet","effort":"high"},"stopped":false,"stopGeneration":2,"deliveries":[{"id":"two","fingerprint":"second","receipt":{}}]}});
        let merged = merge_parent(existing, incoming, true).unwrap();
        let parent: crate::providers::claude::conversation_index::Parent =
            serde_json::from_value(merged["parent"].clone()).unwrap();
        assert!(!parent.stopped);
        assert!(parent.delivery("one").is_some());
        assert!(parent.delivery("two").is_some());
        assert_eq!(parent.selection.unwrap().model, "sonnet");
    }

    #[test]
    fn claude_migration_ignores_host_project_aliases_and_snapshots_only_incoming_targets() {
        let (home, profile, host) = fixture();
        let source = profile.join(format!("claude/projects/work/{SESSION}.jsonl"));
        let canonical = host.join(format!("projects/canonical/{SESSION}.jsonl"));
        write(&source, &native_rows(&[1, 2]));
        write(&canonical, &native_rows(&[1]));
        write(
            &host.join("projects/canonical/untouched.json"),
            b"untouched",
        );
        let alias = host.join("projects/alias");
        std::os::unix::fs::symlink(host.join("projects/canonical"), &alias).unwrap();
        let planned = rollback_profile_files(home.path(), &host).unwrap();
        assert_eq!(planned, BTreeSet::from([canonical.clone()]));
        let receipt = run(home.path(), &host).unwrap();
        assert!(receipt.ambiguous_sessions.is_empty());
        assert_eq!(fs::read(canonical).unwrap(), native_rows(&[1, 2]));
        assert_eq!(
            fs::read_link(alias).unwrap(),
            host.join("projects/canonical")
        );
        assert_eq!(
            fs::read(host.join("projects/canonical/untouched.json")).unwrap(),
            b"untouched"
        );
    }

    #[test]
    fn claude_migration_snapshot_restores_history_when_source_appends_after_capture() {
        let (home, profile, host) = fixture();
        let source = profile.join(format!("claude/projects/work/{SESSION}.jsonl"));
        let canonical = host.join(format!("projects/work/{SESSION}.jsonl"));
        write(&source, &native_rows(&[1]));
        write(&canonical, &native_rows(&[1]));
        let backup = crate::runtime::install::claude_state::ClaudeStateBackup::new(
            &crate::config::HostPaths::from_home(home.path().to_owned()).unwrap(),
        );
        backup
            .capture(&host, &host.parent().unwrap().join(".codex"))
            .unwrap();
        std::io::Write::write_all(
            &mut fs::OpenOptions::new().append(true).open(&source).unwrap(),
            &native_rows(&[2]),
        )
        .unwrap();
        run(home.path(), &host).unwrap();
        assert_eq!(fs::read(&canonical).unwrap(), native_rows(&[1, 2]));
        backup.restore().unwrap();
        assert_eq!(fs::read(canonical).unwrap(), native_rows(&[1]));
        assert_eq!(fs::read(source).unwrap(), native_rows(&[1, 2]));
    }

    #[test]
    fn claude_migration_alias_targets_use_canonical_paths_for_snapshot_and_rollback() {
        let (home, profile, host) = fixture();
        let source = profile.join(format!("claude/projects/alias/{SESSION}.jsonl"));
        let canonical = host.join(format!("projects/canonical/{SESSION}.jsonl"));
        write(&source, &native_rows(&[1]));
        write(&canonical, &native_rows(&[1]));
        let added_session = "aaaaaaaa-bbbb-4444-8888-dddddddddddd";
        write(
            &profile.join(format!("claude/projects/alias/{added_session}.jsonl")),
            &native_rows(&[3]),
        );
        let alias = host.join("projects/alias");
        std::os::unix::fs::symlink("canonical", &alias).unwrap();
        assert_eq!(
            rollback_profile_files(home.path(), &host).unwrap(),
            BTreeSet::from([canonical.clone()])
        );
        let backup = crate::runtime::install::claude_state::ClaudeStateBackup::new(
            &crate::config::HostPaths::from_home(home.path().to_owned()).unwrap(),
        );
        backup
            .capture(&host, &host.parent().unwrap().join(".codex"))
            .unwrap();
        std::io::Write::write_all(
            &mut fs::OpenOptions::new().append(true).open(&source).unwrap(),
            &native_rows(&[2]),
        )
        .unwrap();
        run(home.path(), &host).unwrap();
        assert_eq!(fs::read(&canonical).unwrap(), native_rows(&[1, 2]));
        let added = host.join(format!("projects/canonical/{added_session}.jsonl"));
        assert_eq!(fs::read(&added).unwrap(), native_rows(&[3]));
        backup.restore().unwrap();
        assert_eq!(fs::read(canonical).unwrap(), native_rows(&[1]));
        assert_eq!(fs::read(source).unwrap(), native_rows(&[1, 2]));
        assert_eq!(fs::read(added).unwrap(), native_rows(&[3]));
        assert_eq!(fs::read_link(alias).unwrap(), PathBuf::from("canonical"));
    }

    #[test]
    fn claude_migration_refuses_an_incoming_project_alias_without_changing_originals() {
        let (home, profile, host) = fixture();
        let source = profile.join(format!("claude/projects/alias/{SESSION}.jsonl"));
        write(&source, &native_rows(&[1]));
        let outside = tempfile::tempdir().unwrap();
        write(&outside.path().join("sentinel"), b"untouched");
        fs::create_dir_all(host.join("projects")).unwrap();
        let alias = host.join("projects/alias");
        std::os::unix::fs::symlink(outside.path(), &alias).unwrap();
        let snapshot_error = rollback_profile_files(home.path(), &host).unwrap_err();
        assert!(format!("{snapshot_error:#}").contains("projects/alias"));
        let error = run(home.path(), &host).err().unwrap();
        assert!(format!("{error:#}").contains("projects/alias"));
        assert_eq!(fs::read(&source).unwrap(), native_rows(&[1]));
        assert_eq!(
            fs::read(outside.path().join("sentinel")).unwrap(),
            b"untouched"
        );
        assert!(!outside.path().join(format!("{SESSION}.jsonl")).exists());
        assert_eq!(fs::read_link(alias).unwrap(), outside.path());
    }

    #[test]
    fn claude_migration_refuses_a_linked_memory_file_without_writing_its_target() {
        let (home, profile, host) = fixture();
        write(&profile.join("claude/memory/MEMORY.md"), b"incoming\n");
        let outside = home.path().join("outside.md");
        write(&outside, b"original\n");
        fs::create_dir_all(host.join("memory")).unwrap();
        std::os::unix::fs::symlink(&outside, host.join("memory/MEMORY.md")).unwrap();
        let error = run(home.path(), &host).err().unwrap();
        assert!(format!("{error:#}").contains("memory/MEMORY.md"));
        assert_eq!(fs::read(outside).unwrap(), b"original\n");
    }

    #[test]
    fn claude_migration_restart_same_thread_keeps_latest_and_background_work() {
        let mut older = restart_item("claude_a", "old", 1);
        older["backgroundTasks"] = json!([{"id":"task","kind":"agent","label":"Review"}]);
        older["cause"] = "move".into();
        older["accountSwitch"] =
            json!({"fromEmail":"old@example.test","toEmail":"new@example.test"});
        let newer = restart_item("claude_a", "new", 2);
        let merged = merge_restart(
            json!({"schemaVersion":2,"generationId":"one","account":null,"items":[older]}),
            json!({"schemaVersion":2,"generationId":"two","account":null,"items":[newer]}),
            &BTreeSet::from(["claude_a".to_owned()]),
        )
        .unwrap();
        let journal: crate::providers::claude::restart::Journal =
            serde_json::from_value(merged).unwrap();
        assert_eq!(journal.items.len(), 1);
        assert_eq!(journal.items[0].recovery_id, "new");
        assert_eq!(journal.items[0].background_tasks[0].id, "task");
        assert_eq!(
            journal.items[0].earlier_events[0].cause,
            crate::providers::claude::restart::Cause::Migration
        );
    }

    #[test]
    fn claude_migration_pending_restart_profile_owns_divergent_active_transcript() {
        let (home, first, host) = fixture();
        let latest_id = "f70f7d35-060f-4c63-8638-f50cc6b7ee59";
        let latest = home.path().join(".rca").join(latest_id.replace('-', ""));
        let transcript = format!("projects/project/{SESSION}.jsonl");
        write(&first.join("claude").join(&transcript), b"old branch");
        write(&latest.join("claude").join(&transcript), b"active branch");
        let pending = restart_item(&format!("claude_{SESSION}"), "latest", 1000);
        write(&latest.join("state/claude-restart-recovery.json"), &serde_json::to_vec(&json!({"schemaVersion":2,"generationId":"restart","account":{"id":latest_id,"generation":1},"items":[pending]})).unwrap());
        let receipt = run(home.path(), &host).unwrap();
        assert_eq!(fs::read(host.join(&transcript)).unwrap(), b"active branch");
        assert_eq!(receipt.conflicts[0].owner.as_deref(), Some(latest_id));
        let journal = crate::providers::claude::restart::Store::beside(
            &home.path().join(".remote-coder/active-codex-turns.json"),
        )
        .load()
        .unwrap()
        .unwrap();
        assert!(journal.account.is_none());
        assert_eq!(journal.items[0].recovery_id, "latest");
    }

    #[test]
    fn claude_migration_no_handoff_prefers_newest_native_root_history() {
        let (home, profile, host) = fixture();
        let transcript = format!("projects/project/{SESSION}.jsonl");
        write(&host.join(&transcript), &native_rows(&[1]));
        write(
            &profile.join("claude").join(&transcript),
            &native_rows(&[2]),
        );
        let receipt = run(home.path(), &host).unwrap();
        assert_eq!(fs::read(host.join(&transcript)).unwrap(), native_rows(&[2]));
        assert!(
            receipt.conflicts[0]
                .selection
                .contains("latest native root conversation timestamp")
        );
        assert_eq!(
            fs::read(&receipt.conflicts[0].preserved).unwrap(),
            native_rows(&[1])
        );
    }

    #[test]
    fn claude_migration_refuses_ambiguous_history_without_changing_originals() {
        let (home, profile, host) = fixture();
        let transcript = format!("projects/project/{SESSION}.jsonl");
        write(&host.join(&transcript), &native_rows(&[1]));
        let mut competing: Value = serde_json::from_slice(&native_rows(&[1])).unwrap();
        competing["uuid"] = "different-message".into();
        let incoming = serde_json::to_vec(&competing).unwrap();
        write(&profile.join("claude").join(&transcript), &incoming);
        let error = run(home.path(), &host).err().unwrap().to_string();
        assert!(error.contains(SESSION));
        assert!(error.contains(&profile.display().to_string()));
        assert!(error.contains(&host.display().to_string()));
        assert_eq!(fs::read(host.join(&transcript)).unwrap(), native_rows(&[1]));
        assert_eq!(
            fs::read(profile.join("claude").join(&transcript)).unwrap(),
            incoming
        );
    }

    #[test]
    fn claude_migration_byte_prefix_beats_identical_timestamps() {
        let (home, profile, host) = fixture();
        let transcript = format!("projects/project/{SESSION}.jsonl");
        let prefix = native_rows(&[1]);
        let mut longer = prefix.clone();
        let mut next: Value = serde_json::from_slice(&prefix).unwrap();
        next["uuid"] = "new-message-at-same-time".into();
        longer.extend(serde_json::to_vec(&next).unwrap());
        longer.push(b'\n');
        write(&host.join(&transcript), &prefix);
        write(&profile.join("claude").join(&transcript), &longer);
        let receipt = run(home.path(), &host).unwrap();
        assert!(receipt.ambiguous_sessions.is_empty());
        assert_eq!(fs::read(host.join(&transcript)).unwrap(), longer);
    }

    #[test]
    fn claude_migration_refuses_multiple_host_paths_without_changing_them() {
        let (home, profile, host) = fixture();
        for project in ["one", "two"] {
            write(
                &host
                    .join("projects")
                    .join(project)
                    .join(format!("{SESSION}.jsonl")),
                &native_rows(&[1]),
            );
        }
        write(
            &profile
                .join("claude/projects/three")
                .join(format!("{SESSION}.jsonl")),
            &native_rows(&[2]),
        );
        assert!(run(home.path(), &host).is_err());
        for project in ["one", "two"] {
            assert_eq!(
                fs::read(
                    host.join("projects")
                        .join(project)
                        .join(format!("{SESSION}.jsonl"))
                )
                .unwrap(),
                native_rows(&[1])
            );
        }
    }

    #[test]
    fn claude_migration_merges_memory_indexes_in_profile_order_and_runs_once() {
        let (home, profile, host) = fixture();
        let second = home.path().join(".rca/ffffffffaaaa44448888000000000002");
        write(&host.join("memory/MEMORY.md"), b"host\nshared\nhost\n");
        write(&profile.join("claude/memory/MEMORY.md"), b"shared\nfirst\n");
        write(&second.join("claude/memory/MEMORY.md"), b"second\nfirst\n");
        write(&profile.join("handoff-backups/original"), b"backup");
        let receipt = run(home.path(), &host).unwrap();
        assert_eq!(
            fs::read(host.join("memory/MEMORY.md")).unwrap(),
            b"host\nshared\nfirst\nsecond\n"
        );
        assert_eq!(receipt.memory_indexes.len(), 1);
        assert_eq!(
            fs::read(profile.join("claude/memory/MEMORY.md")).unwrap(),
            b"shared\nfirst\n"
        );
        assert_eq!(
            fs::read(profile.join("handoff-backups/original")).unwrap(),
            b"backup"
        );
        let late = home
            .path()
            .join(".rca/00000000aaaa44448888000000000003/claude/memory/MEMORY.md");
        write(&late, b"later\n");
        run(home.path(), &host).unwrap();
        assert_eq!(
            fs::read(host.join("memory/MEMORY.md")).unwrap(),
            b"host\nshared\nfirst\nsecond\n"
        );
        assert_eq!(fs::read(late).unwrap(), b"later\n");
    }

    #[tokio::test]
    async fn claude_migration_metadata_revision_exceeds_every_source_once() {
        let (home, profile, host) = fixture();
        write(&profile.join("claude/memory/MEMORY.md"), b"memory");
        let mut original = metadata_record("claude_a", 1.0);
        original["serverRevision"] = 9.into();
        let mut incoming = metadata_record("claude_a", 2.0);
        incoming["serverRevision"] = 3.into();
        let path = home.path().join(".remote-coder/session-metadata-v2.json");
        write(
            &path,
            &serde_json::to_vec(&json!({"schemaVersion":1,"records":{"claude_a":original}}))
                .unwrap(),
        );
        write(
            &profile.join("state/session-metadata-v2.json"),
            &serde_json::to_vec(&json!({"schemaVersion":1,"records":{"claude_a":incoming}}))
                .unwrap(),
        );
        let second = home.path().join(".rca/ffffffffaaaa44448888000000000002");
        write(&second.join("claude/memory/MEMORY.md"), b"second");
        let mut newer = metadata_record("claude_a", 3.0);
        newer["serverRevision"] = 2.into();
        write(
            &second.join("state/session-metadata-v2.json"),
            &serde_json::to_vec(&json!({"schemaVersion":1,"records":{"claude_a":newer}})).unwrap(),
        );
        run(home.path(), &host).unwrap();
        let read = read_json(&path).unwrap().unwrap();
        assert_eq!(read["records"]["claude_a"]["updatedAt"], 3.0);
        assert_eq!(read["records"]["claude_a"]["serverRevision"], 10);
        let mut update = read["records"]["claude_a"].clone();
        update.as_object_mut().unwrap().remove("mutationId");
        update["source"] = "selection".into();
        update.as_object_mut().unwrap().remove("updatedAt");
        update.as_object_mut().unwrap().remove("serverRevision");
        let request = serde_json::from_value(serde_json::json!({"selection":update,"expectedRevision":9,"mutationId":"queued-old-update"})).unwrap();
        let store = crate::conversations::ConversationMetadataStore::new(Some(path.clone()));
        assert!(matches!(
            store.update(request).await.unwrap(),
            crate::conversations::UpdateResult::Conflict(_)
        ));
        run(home.path(), &host).unwrap();
        assert_eq!(read_json(&path).unwrap().unwrap(), read);
    }

    #[test]
    fn claude_migration_same_recovery_never_revives_terminal_progress_or_resets_attempts() {
        for state in ["stopped", "dispatched", "failed"] {
            let mut progressed = restart_item("claude_a", "same", 2);
            progressed["status"] = state.into();
            progressed["attempts"] = 3.into();
            progressed["resumedTurnId"] = "known-turn".into();
            let stale = restart_item("claude_a", "same", 2);
            let merged = merge_restart(
                json!({"schemaVersion":2,"generationId":"one","account":null,"items":[progressed]}),
                json!({"schemaVersion":2,"generationId":"two","account":null,"items":[stale]}),
                &BTreeSet::from(["claude_a".to_owned()]),
            )
            .unwrap();
            assert_eq!(merged["items"][0]["status"], state);
            assert_eq!(merged["items"][0]["attempts"], 3);
            assert_eq!(merged["items"][0]["resumedTurnId"], "known-turn");
        }
    }

    #[tokio::test]
    async fn claude_migration_question_owner_state_has_valid_lineage_and_union() {
        let document = |epoch: &str, item: &str| json!({"schemaVersion":1,"threadId":"claude_a","epoch":epoch,"revision":1,"writer":null,"facts":{"definitions":{(item):{"itemId":item,"turnId":"turn","ordinal":1,"askedAtMs":1,"questions":[{"title":"Choose","options":[]}]}},"answers":{},"plainBoundary":null},"anchor":null,"incomplete":{},"scan":null,"dismissals":{},"alerted":[item],"recordRevisions":{(item):1}});
        let merged =
            merge_questions(document("first", "one"), document("second", "two"), true).unwrap();
        let home = tempfile::tempdir().unwrap();
        let path = home
            .path()
            .join(format!("{:x}.json", Sha256::digest(b"claude_a")));
        crate::storage::private_state::write_json(&path, &merged).unwrap();
        let read = crate::questions::QuestionStore::new(Some(home.path().to_owned()))
            .read("claude_a")
            .await
            .unwrap();
        assert_eq!(read.facts.definitions.len(), 2);
        assert_eq!(read.alert_attempted.len(), 2);
        assert_eq!(read.epoch.len(), 32);
        assert!(read.scan.is_none());
    }
}

#[cfg(test)]
#[test]
#[ignore]
fn claude_migration_real_data_copy() {
    let home = PathBuf::from(
        std::env::var_os("RC_CLAUDE_MIGRATION_FIXTURE_HOME")
            .expect("RC_CLAUDE_MIGRATION_FIXTURE_HOME is required"),
    );
    let home = home.canonicalize().unwrap();
    assert!(
        home.join(".migration-fixture").is_file(),
        "Only a prepared migration fixture may be used"
    );
    assert!(
        home.file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("claude-migration-fixture-")
    );
    assert_ne!(
        home,
        PathBuf::from(std::env::var_os("HOME").unwrap())
            .canonicalize()
            .unwrap()
    );
    let host = home.join(".claude");
    let root = Root::open(&home).unwrap();
    let manifest = read_json_from(&root, &home.join(".fixture-manifest.json"))
        .unwrap()
        .unwrap();
    let entries = manifest["entries"].as_object().unwrap();
    let planned = rollback_profile_files(&home, &host).unwrap();
    let backup = crate::runtime::install::claude_state::ClaudeStateBackup::new(
        &crate::config::HostPaths::from_home(home.clone()).unwrap(),
    );
    backup
        .capture(&host, &host.parent().unwrap().join(".codex"))
        .unwrap();
    let receipt = run(&home, &host).unwrap();
    let mut source_files = 0;
    let mut symlinks = 0;
    let mut changed_host_files = 0;
    for (relative, entry) in entries {
        let path = home.join(relative);
        if entry["type"] == "symlink" {
            assert_eq!(root.entry_kind(&path).unwrap(), Some(EntryKind::Symlink));
            assert_eq!(
                root.read_link(&path).unwrap(),
                PathBuf::from(entry["target"].as_str().unwrap())
            );
            symlinks += 1;
        } else if entry["type"] == "file" {
            let digest = fixture_digest(&root, &path);
            if relative.starts_with(".rca/") {
                assert_eq!(
                    digest,
                    entry["sha256"].as_str().unwrap(),
                    "source changed: {relative}"
                );
                source_files += 1;
            } else if relative.starts_with(".claude/")
                && digest != entry["sha256"].as_str().unwrap()
            {
                assert!(
                    planned.contains(&path),
                    "host replacement was not snapshotted: {relative}"
                );
                changed_host_files += 1;
            }
        }
    }
    let restart = crate::providers::claude::restart::Store::beside(
        &home.join(".remote-coder/active-codex-turns.json"),
    )
    .load()
    .unwrap();
    let metadata =
        read_json_from(&root, &home.join(".remote-coder/session-metadata-v2.json")).unwrap();
    if let Some(metadata) = metadata {
        for record in metadata["records"].as_object().unwrap().values() {
            serde_json::from_value::<crate::conversations::Record>(record.clone()).unwrap();
        }
    }
    let _ = restart;
    let before = serde_json::to_value(&receipt).unwrap();
    let rerun = run(&home, &host).unwrap();
    assert_eq!(before, serde_json::to_value(&rerun).unwrap());
    backup.restore().unwrap();
    for (relative, entry) in entries {
        let path = home.join(relative);
        if entry["type"] == "file" {
            assert_eq!(
                fixture_digest(&root, &path),
                entry["sha256"].as_str().unwrap(),
                "rollback changed original: {relative}"
            );
        } else if entry["type"] == "symlink" {
            assert_eq!(
                root.read_link(&path).unwrap(),
                PathBuf::from(entry["target"].as_str().unwrap())
            );
        }
    }
    for name in ["claude-profile-migration.json", "claude-profile-conflicts"] {
        let relative = format!(".remote-coder/{name}");
        if !entries.contains_key(&relative) {
            assert_eq!(root.entry_kind(&home.join(&relative)).unwrap(), None);
        }
    }
    let reupgrade = run(&home, &host).unwrap();
    assert!(reupgrade.ambiguous_sessions.is_empty());
    println!(
        "Claude migration copied-data evidence: {}",
        serde_json::json!({
            "retiredIds": receipt.retired_ids.len(), "sessions": receipt.sessions.len(),
            "conflicts": receipt.conflicts.len(), "ambiguousSessions": receipt.ambiguous_sessions.len(),
            "memoryIndexes": receipt.memory_indexes.len(), "sourceFilesVerified": source_files,
            "symlinksPreserved": symlinks, "snapshotHostFiles": planned.len(),
            "changedHostFiles": changed_host_files, "refusals": 0, "snapshot": true,
            "rollbackRestoredOriginals": true, "idempotent": true, "reupgrade": true, "fixture": home
        })
    );
}

#[cfg(test)]
fn fixture_digest(root: &Root, path: &Path) -> String {
    let file = root.open_file(path).unwrap().unwrap();
    let output = std::process::Command::new("/usr/bin/openssl")
        .args(["dgst", "-sha256"])
        .stdin(std::process::Stdio::from(file))
        .output()
        .unwrap();
    assert!(output.status.success(), "Fixture hash command failed");
    let output = String::from_utf8(output.stdout).unwrap();
    let digest = output.split_whitespace().last().unwrap();
    assert_eq!(digest.len(), 64);
    assert!(digest.bytes().all(|byte| byte.is_ascii_hexdigit()));
    digest.to_owned()
}
