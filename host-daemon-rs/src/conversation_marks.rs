use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result, ensure};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use tokio::sync::Semaphore;

mod migration;

const SCHEMA_VERSION: u32 = 3;
const FILE_NAME: &str = "conversation-marks.v3.json";
const MAXIMUM_STORE_BYTES: u64 = 8 * 1024 * 1024;
const MAXIMUM_THREAD_ID_BYTES: usize = 512;
const MAXIMUM_PIN_NAME_BYTES: usize = 256;
pub(crate) const MAXIMUM_CHANGES_PER_UPDATE: usize = 500;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Purpose {
    Probe,
    Automation,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum SettlementState {
    Settled,
    Active,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Settlement {
    pub state: SettlementState,
    pub through: i64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ThreadMarks {
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seen_through: Option<i64>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub marked_unread: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pin_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub purpose: Option<Purpose>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub settlement: Option<Settlement>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub done_through: Option<i64>,
}

impl ThreadMarks {
    fn is_empty(&self) -> bool {
        self.seen_through.is_none()
            && !self.marked_unread
            && self.pin_name.is_none()
            && self.purpose.is_none()
            && self.settlement.is_none()
            && self.done_through.is_none()
    }

    fn mark_read_through(&mut self, through: i64) {
        self.marked_unread = false;
        if self.seen_through.is_none_or(|seen| through > seen) {
            self.seen_through = Some(through);
        }
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(tag = "op", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub(crate) enum Change {
    MarkRead { thread_id: String, through: i64 },
    MarkUnread { thread_id: String },
    MarkAllRead { through: i64 },
    MarkRetiredScopeRead { scope_id: String, through: i64 },
    Pin { thread_id: String, name: String },
    Unpin { thread_id: String },
    SetPurpose { thread_id: String, purpose: Purpose },
    Settle { thread_id: String, through: i64 },
    Unsettle { thread_id: String, through: i64 },
}

impl Change {
    fn thread_id(&self) -> Option<&str> {
        match self {
            Self::MarkRead { thread_id, .. }
            | Self::MarkUnread { thread_id }
            | Self::Pin { thread_id, .. }
            | Self::Unpin { thread_id }
            | Self::SetPurpose { thread_id, .. }
            | Self::Settle { thread_id, .. }
            | Self::Unsettle { thread_id, .. } => Some(thread_id),
            Self::MarkAllRead { .. } | Self::MarkRetiredScopeRead { .. } => None,
        }
    }

    fn validate(&self) -> Result<()> {
        if let Some(thread_id) = self.thread_id() {
            validate_thread_id(thread_id)?;
        }
        if let Self::MarkRetiredScopeRead { scope_id, .. } = self
            && scope_id != "default"
        {
            let id = crate::accounts::types::AccountId::try_from(scope_id.clone())?;
            ensure!(
                id.as_str() == scope_id,
                "scopeId must be default or a canonical retired UUID"
            );
        }
        if let Self::Pin { name, .. } = self {
            ensure!(
                !name.trim().is_empty() && name.len() <= MAXIMUM_PIN_NAME_BYTES,
                "pin name must be nonempty and at most {MAXIMUM_PIN_NAME_BYTES} bytes"
            );
        }
        Ok(())
    }
}

fn validate_thread_id(thread_id: &str) -> Result<()> {
    ensure!(
        !thread_id.is_empty()
            && thread_id.trim() == thread_id
            && thread_id.len() <= MAXIMUM_THREAD_ID_BYTES,
        "threadId must be nonempty, trimmed and at most {MAXIMUM_THREAD_ID_BYTES} bytes"
    );
    Ok(())
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Marks {
    pub schema_version: u32,
    pub revision: u64,
    pub read_baseline: i64,
    pub threads: BTreeMap<String, ThreadMarks>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Document {
    schema_version: u32,
    revision: u64,
    read_baseline: i64,
    threads: BTreeMap<String, ThreadMarks>,
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pending_native_unarchive: BTreeSet<String>,
}

impl Document {
    fn created(now: i64) -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            revision: 0,
            read_baseline: now,
            threads: BTreeMap::new(),
            pending_native_unarchive: BTreeSet::new(),
        }
    }

    fn snapshot(&self) -> Marks {
        Marks {
            schema_version: SCHEMA_VERSION,
            revision: self.revision,
            read_baseline: self.read_baseline,
            threads: self.threads.clone(),
        }
    }

    fn validate(&self) -> Result<()> {
        for (id, marks) in &self.threads {
            validate_thread_id(id)?;
            ensure!(
                marks.revision > 0 && marks.revision <= self.revision && !marks.is_empty(),
                "invalid conversation marks entry"
            );
        }
        for id in &self.pending_native_unarchive {
            validate_thread_id(id)?;
        }
        Ok(())
    }
}

struct Transition<'a> {
    document: &'a mut Document,
    revision: u64,
    touched: BTreeMap<String, ThreadMarks>,
    baseline_moved: bool,
}

impl<'a> Transition<'a> {
    fn new(document: &'a mut Document) -> Result<Self> {
        let revision = document
            .revision
            .checked_add(1)
            .context("conversation marks revision exhausted")?;
        Ok(Self {
            document,
            revision,
            touched: BTreeMap::new(),
            baseline_moved: false,
        })
    }

    fn update(&mut self, thread_id: &str, change: impl FnOnce(&mut ThreadMarks)) {
        let current = self
            .document
            .threads
            .get(thread_id)
            .cloned()
            .unwrap_or_default();
        let mut next = current.clone();
        change(&mut next);
        if next
            .seen_through
            .is_some_and(|seen| seen <= self.document.read_baseline)
        {
            next.seen_through = None;
        }
        if next == current {
            return;
        }
        next.revision = self.revision;
        if next.is_empty() {
            self.document.threads.remove(thread_id);
        } else {
            self.document
                .threads
                .insert(thread_id.to_string(), next.clone());
        }
        self.touched.insert(thread_id.to_string(), next);
    }

    fn apply(
        &mut self,
        change: Change,
        now: i64,
        read_scopes: &BTreeMap<String, BTreeSet<String>>,
    ) -> Result<()> {
        match change {
            Change::MarkRead { thread_id, through } => {
                self.update(&thread_id, |marks| marks.mark_read_through(through))
            }
            Change::MarkRetiredScopeRead { scope_id, through } => {
                let threads = read_scopes
                    .get(&scope_id)
                    .with_context(|| format!("Retired read scope {scope_id} is unavailable"))?;
                for thread in threads {
                    validate_thread_id(thread)?;
                    self.update(thread, |marks| marks.mark_read_through(through.min(now)));
                }
            }
            Change::MarkUnread { thread_id } => {
                self.update(&thread_id, |marks| marks.marked_unread = true)
            }
            Change::MarkAllRead { through } => {
                let through = through.min(now);
                if through > self.document.read_baseline {
                    self.document.read_baseline = through;
                    self.baseline_moved = true;
                }
                let affected: Vec<String> = self
                    .document
                    .threads
                    .iter()
                    .filter(|(_, marks)| {
                        marks.marked_unread
                            || marks
                                .seen_through
                                .is_some_and(|seen| seen <= self.document.read_baseline)
                    })
                    .map(|(id, _)| id.clone())
                    .collect();
                for thread_id in affected {
                    self.update(&thread_id, |marks| marks.marked_unread = false);
                }
            }
            Change::Pin { thread_id, name } => {
                let name = name.trim().to_string();
                self.update(&thread_id, |marks| marks.pin_name = Some(name));
            }
            Change::Unpin { thread_id } => self.update(&thread_id, |marks| marks.pin_name = None),
            Change::SetPurpose { thread_id, purpose } => {
                self.update(&thread_id, |marks| marks.purpose = Some(purpose))
            }
            Change::Settle { thread_id, through } => self.update(&thread_id, |marks| {
                marks.mark_read_through(through);
                marks.pin_name = None;
                marks.settlement = Some(Settlement {
                    state: SettlementState::Settled,
                    through,
                });
            }),
            Change::Unsettle { thread_id, through } => self.update(&thread_id, |marks| {
                marks.done_through = None;
                marks.settlement = Some(Settlement {
                    state: SettlementState::Active,
                    through,
                });
            }),
        }
        Ok(())
    }

    fn finish(self) -> (Option<Marks>, bool) {
        let changed = !self.touched.is_empty() || self.baseline_moved;
        if changed {
            self.document.revision = self.revision;
        }
        let delta = Marks {
            schema_version: SCHEMA_VERSION,
            revision: self.document.revision,
            read_baseline: self.document.read_baseline,
            threads: self.touched,
        };
        (changed.then_some(delta), changed)
    }
}

pub(crate) fn validate(changes: &[Change]) -> Result<()> {
    ensure!(
        !changes.is_empty() && changes.len() <= MAXIMUM_CHANGES_PER_UPDATE,
        "an update carries 1 to {MAXIMUM_CHANGES_PER_UPDATE} changes"
    );
    for change in changes {
        change.validate()?;
    }
    Ok(())
}

#[derive(Clone)]
pub(crate) struct Location {
    pub(crate) directory: PathBuf,
    pub(crate) handoff_records: PathBuf,
}

#[derive(Clone)]
pub(crate) struct ConversationMarksStore {
    location: Option<Location>,
    admission: Arc<Semaphore>,
}

impl ConversationMarksStore {
    pub(crate) fn new(location: Option<Location>) -> Self {
        Self {
            location,
            admission: Arc::new(Semaphore::new(1)),
        }
    }

    pub(crate) async fn read(&self, now: i64) -> Result<Marks> {
        self.transaction(now, |document, created| Ok((document.snapshot(), created)))
            .await
    }

    pub(crate) async fn update(&self, changes: Vec<Change>, now: i64) -> Result<Option<Marks>> {
        validate(&changes)?;
        let directory = self
            .location
            .as_ref()
            .map(|location| location.directory.clone());
        self.transaction(now, move |document, created| {
            let read_scopes = if changes
                .iter()
                .any(|change| matches!(change, Change::MarkRetiredScopeRead { .. }))
            {
                crate::accounts::codex_migration::read_scopes(
                    directory
                        .as_deref()
                        .context("conversation marks storage is not configured")?,
                )?
            } else {
                BTreeMap::new()
            };
            let mut transition = Transition::new(document)?;
            for change in changes {
                transition.apply(change, now, &read_scopes)?;
            }
            let (delta, changed) = transition.finish();
            Ok((delta, changed || created))
        })
        .await
    }

    pub(crate) async fn forget(&self, thread_id: String, now: i64) -> Result<Option<Marks>> {
        validate_thread_id(&thread_id)?;
        self.transaction(now, move |document, created| {
            let mut transition = Transition::new(document)?;
            transition.update(&thread_id, |marks| {
                *marks = ThreadMarks {
                    revision: marks.revision,
                    ..ThreadMarks::default()
                }
            });
            let (delta, changed) = transition.finish();
            Ok((delta, changed || created))
        })
        .await
    }

    pub(crate) async fn record_done(
        &self,
        thread_id: String,
        through: Option<i64>,
        now: i64,
    ) -> Result<Option<Marks>> {
        validate_thread_id(&thread_id)?;
        self.transaction(now, move |document, created| {
            let marks = document.threads.get(&thread_id);
            if marks.is_some_and(|marks| {
                marks.pin_name.is_some()
                    || marks.purpose.is_some()
                    || through.is_some_and(|through| {
                        matches!(marks.settlement, Some(Settlement {
                            state: SettlementState::Active, through: active,
                        }) if active >= through)
                    })
            }) {
                return Ok((None, created));
            }
            let mut transition = Transition::new(document)?;
            transition.update(&thread_id, |marks| marks.done_through = through);
            let (delta, changed) = transition.finish();
            Ok((delta, changed || created))
        })
        .await
    }

    pub(crate) async fn pending_native_unarchives(&self, now: i64) -> Result<Vec<String>> {
        if self.location.is_none() {
            return Ok(Vec::new());
        }
        self.transaction(now, |document, created| {
            Ok((
                document.pending_native_unarchive.iter().cloned().collect(),
                created,
            ))
        })
        .await
    }

    pub(crate) async fn complete_native_unarchives(
        &self,
        thread_ids: Vec<String>,
        now: i64,
    ) -> Result<usize> {
        self.transaction(now, move |document, created| {
            let mut changed = created;
            for thread_id in &thread_ids {
                changed |= document.pending_native_unarchive.remove(thread_id);
            }
            Ok((document.pending_native_unarchive.len(), changed))
        })
        .await
    }

    async fn transaction<T: Send + 'static>(
        &self,
        now: i64,
        operation: impl FnOnce(&mut Document, bool) -> Result<(T, bool)> + Send + 'static,
    ) -> Result<T> {
        let location = self
            .location
            .clone()
            .context("conversation marks storage is not configured")?;
        let permit = Arc::clone(&self.admission).acquire_owned().await?;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            crate::storage::private_state::transaction(
                &location.directory.join(FILE_NAME),
                "conversation marks path has no parent",
                |path| {
                    Ok(match load(path)? {
                        Some(document) => (document, false),
                        None => (
                            migration::import(&location)?.unwrap_or_else(|| Document::created(now)),
                            true,
                        ),
                    })
                },
                |(document, created)| operation(document, *created),
                |path, (document, _)| {
                    validate_capacity(document)?;
                    crate::storage::private_state::write_json(path, document)
                },
            )
        })
        .await
        .context("conversation marks worker failed")?
    }
}

fn read_json<T: DeserializeOwned>(path: &Path, name: &str) -> Result<Option<T>> {
    use crate::storage::private_state::ReadError;

    let bytes = crate::storage::private_state::read_bounded(path, MAXIMUM_STORE_BYTES).map_err(
        |error| match error {
            ReadError::Io(error) => anyhow::Error::from(error),
            ReadError::NotRegular => anyhow::anyhow!("{name} must be a regular file"),
            ReadError::TooLargeBeforeRead | ReadError::TooLargeAfterRead => {
                anyhow::anyhow!("{name} file exceeds its size limit")
            }
        },
    )?;
    let Some(bytes) = bytes else { return Ok(None) };
    serde_json::from_slice::<T>(&bytes)
        .map(Some)
        .with_context(|| format!("unreadable {name}; original preserved"))
}

fn load(path: &Path) -> Result<Option<Document>> {
    let Some(document) = read_json::<Document>(path, "conversation marks")? else {
        return Ok(None);
    };
    ensure!(
        document.schema_version == SCHEMA_VERSION,
        "unsupported conversation marks version"
    );
    document.validate()?;
    Ok(Some(document))
}

fn validate_capacity(value: &impl Serialize) -> Result<()> {
    ensure!(
        (serde_json::to_vec(value)?.len() as u64) < MAXIMUM_STORE_BYTES,
        "conversation marks capacity exceeded"
    );
    Ok(())
}

pub(crate) fn validate_migration_document(value: &serde_json::Value) -> Result<()> {
    validate_capacity(value)?;
    let document: Document =
        serde_json::from_value(value.clone()).context("Invalid migrated conversation marks")?;
    ensure!(
        document.schema_version == SCHEMA_VERSION,
        "unsupported conversation marks version"
    );
    document.validate()
}

pub(crate) fn migration_document(directory: &Path) -> Result<Option<serde_json::Value>> {
    let document = match load(&directory.join(FILE_NAME))? {
        Some(document) => Some(document),
        None => migration::import(&Location {
            directory: directory.to_owned(),
            handoff_records: directory.join("conversation-handoffs.json"),
        })?,
    };
    document
        .map(serde_json::to_value)
        .transpose()
        .map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn store(directory: &tempfile::TempDir) -> ConversationMarksStore {
        ConversationMarksStore::new(Some(Location {
            directory: directory.path().to_path_buf(),
            handoff_records: directory.path().join("conversation-handoffs.json"),
        }))
    }

    fn change(value: serde_json::Value) -> Change {
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn changes_decode_from_their_wire_names() {
        assert_eq!(
            change(serde_json::json!({"op": "markRead", "threadId": "a", "through": 5})),
            Change::MarkRead {
                thread_id: "a".into(),
                through: 5
            }
        );
        assert_eq!(
            change(serde_json::json!({"op": "markAllRead", "through": 7})),
            Change::MarkAllRead { through: 7 }
        );
        assert_eq!(
            change(
                serde_json::json!({"op":"markRetiredScopeRead","scopeId":"default","through":7})
            ),
            Change::MarkRetiredScopeRead {
                scope_id: "default".into(),
                through: 7
            }
        );
        for scope in [
            "",
            "default-codex",
            "unrecognized",
            "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
        ] {
            assert!(
                validate(&[Change::MarkRetiredScopeRead {
                    scope_id: scope.into(),
                    through: 7
                }])
                .is_err()
            );
        }
        assert_eq!(
            change(serde_json::json!({"op": "setPurpose", "threadId": "a", "purpose": "probe"})),
            Change::SetPurpose {
                thread_id: "a".into(),
                purpose: Purpose::Probe
            }
        );
        assert_eq!(
            change(serde_json::json!({"op": "settle", "threadId": "a", "through": 9})),
            Change::Settle {
                thread_id: "a".into(),
                through: 9
            }
        );
        assert_eq!(
            change(serde_json::json!({"op": "unsettle", "threadId": "a", "through": 9})),
            Change::Unsettle {
                thread_id: "a".into(),
                through: 9
            }
        );
    }

    #[tokio::test]
    async fn retired_scope_reads_are_atomic_idempotent_and_distinguish_empty_from_unknown() {
        let directory = tempfile::tempdir().unwrap();
        let store = store(&directory);
        let before = store.read(100).await.unwrap();
        let receipt = directory.path().join("codex-profile-migration.json");
        let original = fs::read(directory.path().join(FILE_NAME)).unwrap();
        let update = || {
            vec![
                Change::Pin {
                    thread_id: "unrelated".into(),
                    name: "Keep".into(),
                },
                Change::MarkRetiredScopeRead {
                    scope_id: "default".into(),
                    through: 300,
                },
            ]
        };
        assert!(store.update(update(), 300).await.is_err());
        assert_eq!(
            fs::read(directory.path().join(FILE_NAME)).unwrap(),
            original
        );
        crate::storage::private_state::write_json(
            &receipt,
            &serde_json::json!({
                "retiredIds":[],"profiles":{},"complete":true,
                "readScopes":{"default":["uncached","claude_mark-only"],
                    "11111111-1111-1111-1111-111111111111":[]}
            }),
        )
        .unwrap();
        let delta = store
            .update(
                vec![Change::MarkRetiredScopeRead {
                    scope_id: "default".into(),
                    through: 900,
                }],
                300,
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(delta.read_baseline, before.read_baseline);
        assert_eq!(delta.threads.len(), 2);
        assert!(
            delta
                .threads
                .values()
                .all(|marks| marks.seen_through == Some(300))
        );
        assert!(
            store
                .update(
                    vec![Change::MarkRetiredScopeRead {
                        scope_id: "default".into(),
                        through: 300
                    }],
                    400
                )
                .await
                .unwrap()
                .is_none()
        );
        let original = fs::read(directory.path().join(FILE_NAME)).unwrap();
        let empty = Change::MarkRetiredScopeRead {
            scope_id: "11111111-1111-1111-1111-111111111111".into(),
            through: 500,
        };
        assert!(store.update(vec![empty], 500).await.unwrap().is_none());
        assert_eq!(
            fs::read(directory.path().join(FILE_NAME)).unwrap(),
            original
        );
        let unknown = Change::MarkRetiredScopeRead {
            scope_id: "22222222-2222-2222-2222-222222222222".into(),
            through: 500,
        };
        assert!(
            store
                .update(
                    vec![
                        Change::MarkUnread {
                            thread_id: "uncached".into()
                        },
                        unknown
                    ],
                    500
                )
                .await
                .is_err()
        );
        assert_eq!(
            fs::read(directory.path().join(FILE_NAME)).unwrap(),
            original
        );
        let mut legacy: serde_json::Value =
            serde_json::from_slice(&fs::read(&receipt).unwrap()).unwrap();
        legacy.as_object_mut().unwrap().remove("readScopes");
        crate::storage::private_state::write_json(&receipt, &legacy).unwrap();
        assert!(store.update(update(), 500).await.is_err());
        assert_eq!(
            fs::read(directory.path().join(FILE_NAME)).unwrap(),
            original
        );
    }

    #[tokio::test]
    async fn the_first_read_fixes_the_baseline_and_later_reads_keep_it() {
        let directory = tempfile::tempdir().unwrap();
        let store = store(&directory);
        assert_eq!(store.read(100).await.unwrap().read_baseline, 100);
        assert_eq!(store.read(900).await.unwrap().read_baseline, 100);
    }

    #[tokio::test]
    async fn read_marks_only_advance_and_mark_all_read_drops_what_the_baseline_covers() {
        let directory = tempfile::tempdir().unwrap();
        let store = store(&directory);
        store.read(100).await.unwrap();
        let first = store
            .update(
                vec![Change::MarkRead {
                    thread_id: "a".into(),
                    through: 300,
                }],
                400,
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(first.threads["a"].seen_through, Some(300));
        assert!(
            store
                .update(
                    vec![Change::MarkRead {
                        thread_id: "a".into(),
                        through: 200
                    }],
                    400
                )
                .await
                .unwrap()
                .is_none()
        );
        store
            .update(
                vec![
                    Change::MarkUnread {
                        thread_id: "b".into(),
                    },
                    Change::Pin {
                        thread_id: "a".into(),
                        name: " Release ".into(),
                    },
                ],
                400,
            )
            .await
            .unwrap();
        let delta = store
            .update(vec![Change::MarkAllRead { through: 900 }], 500)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(delta.read_baseline, 500);
        assert_eq!(delta.threads["a"].seen_through, None);
        assert_eq!(delta.threads["a"].pin_name.as_deref(), Some("Release"));
        assert!(delta.threads["b"].is_empty());
        let marks = store.read(600).await.unwrap();
        assert_eq!(marks.threads.keys().collect::<Vec<_>>(), ["a"]);
        assert_eq!(marks.revision, delta.revision);
        assert!(
            store
                .update(vec![Change::MarkAllRead { through: 450 }], 700)
                .await
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn forgetting_a_thread_publishes_a_tombstone_at_a_new_revision() {
        let directory = tempfile::tempdir().unwrap();
        let store = store(&directory);
        let pinned = store
            .update(
                vec![Change::Pin {
                    thread_id: "a".into(),
                    name: "Keep".into(),
                }],
                10,
            )
            .await
            .unwrap()
            .unwrap();
        let delta = store.forget("a".into(), 20).await.unwrap().unwrap();
        assert!(delta.threads["a"].is_empty());
        assert!(delta.threads["a"].revision > pinned.threads["a"].revision);
        assert!(store.read(30).await.unwrap().threads.is_empty());
        assert!(store.forget("a".into(), 40).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn settling_reads_through_and_unpins_and_only_unsettling_replaces_it() {
        let directory = tempfile::tempdir().unwrap();
        let store = store(&directory);
        store.read(100).await.unwrap();
        store
            .update(
                vec![
                    Change::Pin {
                        thread_id: "a".into(),
                        name: "Keep".into(),
                    },
                    Change::MarkRead {
                        thread_id: "a".into(),
                        through: 300,
                    },
                    Change::MarkUnread {
                        thread_id: "a".into(),
                    },
                ],
                400,
            )
            .await
            .unwrap();
        let settled = store
            .update(
                vec![Change::Settle {
                    thread_id: "a".into(),
                    through: 250,
                }],
                400,
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            serde_json::to_value(&settled).unwrap(),
            serde_json::json!({
                "schemaVersion": 3,
                "revision": settled.revision,
                "readBaseline": 100,
                "threads": {"a": {
                    "revision": settled.revision,
                    "seenThrough": 300,
                    "settlement": {"state": "settled", "through": 250}
                }}
            })
        );
        let raised = store
            .update(
                vec![Change::Settle {
                    thread_id: "a".into(),
                    through: 500,
                }],
                600,
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(raised.threads["a"].seen_through, Some(500));
        let unsettled = store
            .update(
                vec![Change::Unsettle {
                    thread_id: "a".into(),
                    through: 700,
                }],
                800,
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            unsettled.threads["a"],
            ThreadMarks {
                revision: unsettled.revision,
                seen_through: Some(500),
                settlement: Some(Settlement {
                    state: SettlementState::Active,
                    through: 700
                }),
                ..ThreadMarks::default()
            }
        );
        let unread = store
            .update(
                vec![
                    Change::MarkUnread {
                        thread_id: "a".into(),
                    },
                    Change::Pin {
                        thread_id: "a".into(),
                        name: "Again".into(),
                    },
                ],
                800,
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            unread.threads["a"].settlement,
            unsettled.threads["a"].settlement
        );
        let covered = store
            .update(
                vec![Change::Settle {
                    thread_id: "b".into(),
                    through: 50,
                }],
                800,
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            covered.threads["b"],
            ThreadMarks {
                revision: covered.revision,
                settlement: Some(Settlement {
                    state: SettlementState::Settled,
                    through: 50
                }),
                ..ThreadMarks::default()
            }
        );
    }

    #[tokio::test]
    async fn done_verdicts_write_only_changes_and_unsettle_suppresses_its_activity() {
        let directory = tempfile::tempdir().unwrap();
        let store = store(&directory);
        store.read(100).await.unwrap();
        let delta = store
            .record_done("a".into(), Some(300), 400)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(delta.schema_version, 3);
        assert_eq!(delta.threads["a"].done_through, Some(300));
        assert!(
            store
                .record_done("a".into(), Some(300), 500)
                .await
                .unwrap()
                .is_none()
        );
        let cleared = store
            .record_done("a".into(), None, 500)
            .await
            .unwrap()
            .unwrap();
        assert!(cleared.threads["a"].is_empty());
        store
            .record_done("a".into(), Some(600), 700)
            .await
            .unwrap()
            .unwrap();
        let explicit = store
            .update(
                vec![Change::Unsettle {
                    thread_id: "a".into(),
                    through: 600,
                }],
                700,
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(explicit.threads["a"].done_through, None);
        assert!(
            store
                .record_done("a".into(), Some(600), 800)
                .await
                .unwrap()
                .is_none()
        );
        assert_eq!(
            store.read(800).await.unwrap().threads["a"],
            explicit.threads["a"]
        );
        assert!(
            store
                .record_done("a".into(), Some(599), 800)
                .await
                .unwrap()
                .is_none()
        );
        let newer = store
            .record_done("a".into(), Some(601), 800)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(newer.threads["a"].done_through, Some(601));
        assert_eq!(
            newer.threads["a"].settlement,
            explicit.threads["a"].settlement
        );
        assert!(
            serde_json::from_value::<Change>(
                serde_json::json!({"op":"done","threadId":"a","through":800})
            )
            .is_err()
        );
    }

    #[test]
    fn persisted_capacity_includes_the_json_writers_trailing_newline() {
        let mut payload = "x".repeat(MAXIMUM_STORE_BYTES as usize - 3);
        validate_capacity(&payload).unwrap();
        payload.push('x');
        assert!(validate_capacity(&payload).is_err());
    }

    #[tokio::test]
    async fn invalid_changes_are_refused_without_writing() {
        let directory = tempfile::tempdir().unwrap();
        let store = store(&directory);
        for changes in [
            vec![],
            vec![Change::Pin {
                thread_id: "a".into(),
                name: "  ".into(),
            }],
            vec![Change::MarkUnread {
                thread_id: " a".into(),
            }],
        ] {
            assert!(store.update(changes, 10).await.is_err());
        }
        assert!(!directory.path().join(FILE_NAME).exists());
    }

    #[tokio::test]
    async fn invalid_files_and_future_formats_are_never_replaced() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join(FILE_NAME);
        for bytes in [
            b"not json".as_slice(),
            br#"{"schemaVersion":99,"revision":0,"readBaseline":0,"threads":{}}"#,
        ] {
            fs::write(&path, bytes).unwrap();
            let store = store(&directory);
            assert!(
                store
                    .update(vec![Change::MarkAllRead { through: 10 }], 10)
                    .await
                    .is_err()
            );
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
    }

    #[tokio::test]
    async fn competing_store_instances_preserve_independent_changes() {
        let directory = tempfile::tempdir().unwrap();
        let first = store(&directory);
        let second = store(&directory);
        let (a, b) = tokio::join!(
            first.update(
                vec![Change::MarkUnread {
                    thread_id: "a".into()
                }],
                10
            ),
            second.update(
                vec![Change::MarkUnread {
                    thread_id: "b".into()
                }],
                10
            )
        );
        a.unwrap();
        b.unwrap();
        assert_eq!(first.read(20).await.unwrap().threads.len(), 2);
    }
}
