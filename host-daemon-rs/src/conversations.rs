//! One transaction owner for session preferences. Client snapshots never replace
//! the host map. The file lock also covers a second gateway process during handoff.
use std::collections::BTreeMap;
#[cfg(test)]
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use tokio::sync::Semaphore;

const MAXIMUM_STORE_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Source {
    Selection,
    Runtime,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Selection {
    #[serde(rename = "sessionID")]
    pub session_id: String,
    #[serde(rename = "modelID")]
    pub model_id: String,
    #[serde(rename = "reasoningSelectionID")]
    pub reasoning_selection_id: String,
    pub fast_mode_enabled: Option<bool>,
    pub source: Option<Source>,
}

impl Selection {
    fn validate(&self) -> Result<()> {
        for (name, value, maximum) in [
            ("sessionID", &self.session_id, 512),
            ("modelID", &self.model_id, 256),
            ("reasoningSelectionID", &self.reasoning_selection_id, 128),
        ] {
            ensure!(
                !value.is_empty() && value.trim() == value && value.len() <= maximum,
                "{name} must be nonempty, trimmed and at most {maximum} bytes"
            );
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Record {
    #[serde(flatten)]
    pub selection: Selection,
    pub updated_at: f64,
    pub server_revision: u64,
    pub mutation_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Update {
    pub selection: Selection,
    pub expected_revision: u64,
    pub mutation_id: String,
}

impl Update {
    pub(crate) fn validate(&self) -> Result<()> {
        self.selection.validate()?;
        ensure!(
            !self.mutation_id.is_empty() && self.mutation_id.len() <= 128,
            "mutationId must contain 1 to 128 bytes"
        );
        Ok(())
    }
}

#[derive(Debug, PartialEq)]
pub(crate) enum UpdateResult {
    Applied(Record),
    Conflict(Option<Record>),
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Read {
    pub known_revision: Option<String>,
}

#[derive(Debug, PartialEq)]
pub(crate) enum Snapshot {
    Full {
        entries: Vec<Record>,
        revision: String,
    },
    Unchanged {
        revision: String,
    },
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Document {
    schema_version: u32,
    records: BTreeMap<String, Record>,
}

impl Default for Document {
    fn default() -> Self {
        Self {
            schema_version: 1,
            records: BTreeMap::new(),
        }
    }
}

#[derive(Clone)]
pub(crate) struct ConversationMetadataStore {
    path: Option<PathBuf>,
    // The permit moves into spawn_blocking. Cancelling an async waiter cannot
    // release capacity while its actual file operation is still running.
    admission: Arc<Semaphore>,
}

impl ConversationMetadataStore {
    pub fn new(path: Option<PathBuf>) -> Self {
        Self {
            path,
            admission: Arc::new(Semaphore::new(1)),
        }
    }

    pub(crate) async fn read(&self, known_revision: Option<String>) -> Result<Snapshot> {
        self.transaction(move |document| {
            let entries: Vec<_> = document.records.values().cloned().collect();
            let revision = blake3::hash(&serde_json::to_vec(&entries)?)
                .to_hex()
                .to_string();
            let snapshot = if known_revision.as_deref() == Some(revision.as_str()) {
                Snapshot::Unchanged { revision }
            } else {
                Snapshot::Full { entries, revision }
            };
            Ok((snapshot, false))
        })
        .await
    }

    pub(crate) async fn update(&self, request: Update) -> Result<UpdateResult> {
        request.validate()?;
        self.transaction(move |document| {
            let id = &request.selection.session_id;
            let current = document.records.get(id);
            if let Some(current) = current
                && current.mutation_id.as_deref() == Some(&request.mutation_id)
            {
                ensure!(
                    current.selection == request.selection,
                    "mutationId reused with different settings"
                );
                return Ok((UpdateResult::Applied(current.clone()), false));
            }
            let revision = current.map_or(0, |entry| entry.server_revision);
            if revision != request.expected_revision {
                return Ok((UpdateResult::Conflict(current.cloned()), false));
            }
            let next = Record {
                selection: request.selection,
                updated_at: SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs_f64(),
                server_revision: revision
                    .checked_add(1)
                    .context("metadata revision exhausted")?,
                mutation_id: Some(request.mutation_id),
            };
            document
                .records
                .insert(next.selection.session_id.clone(), next.clone());
            Ok((UpdateResult::Applied(next), true))
        })
        .await
    }

    pub(crate) fn is_configured(&self) -> bool {
        self.path.is_some()
    }

    pub(crate) async fn fork(&self, source_id: String, target_id: String) -> Result<()> {
        self.transaction(move |document| {
            let Some(source) = document.records.get(&source_id) else {
                return Ok(((), false));
            };
            let selection = Selection {
                session_id: target_id.clone(),
                ..source.selection.clone()
            };
            ensure!(
                !document.records.contains_key(&target_id),
                "session metadata already exists for {target_id}"
            );
            document.records.insert(
                target_id,
                Record {
                    selection,
                    updated_at: SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs_f64(),
                    server_revision: 1,
                    mutation_id: None,
                },
            );
            Ok(((), true))
        })
        .await
    }

    async fn transaction<T: Send + 'static>(
        &self,
        operation: impl FnOnce(&mut Document) -> Result<(T, bool)> + Send + 'static,
    ) -> Result<T> {
        let path = self
            .path
            .clone()
            .context("session metadata storage is not configured")?;
        let permit = Arc::clone(&self.admission).acquire_owned().await?;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            crate::storage::private_state::transaction(
                &path,
                "metadata path has no parent",
                load,
                operation,
                |path, document| {
                    ensure!(
                        serde_json::to_vec(document)?.len() as u64 <= MAXIMUM_STORE_BYTES,
                        "session metadata capacity exceeded"
                    );
                    crate::storage::private_state::write_json(path, document)
                },
            )
        })
        .await
        .context("session metadata worker failed")?
    }
}

fn read_file(path: &Path) -> Result<Option<Vec<u8>>> {
    use crate::storage::private_state::ReadError;

    crate::storage::private_state::read_bounded(path, MAXIMUM_STORE_BYTES).map_err(|error| {
        match error {
            ReadError::Io(error) => error.into(),
            ReadError::NotRegular => anyhow::anyhow!("metadata must be a regular file"),
            ReadError::TooLargeBeforeRead => {
                anyhow::anyhow!("session metadata file exceeds its size limit")
            }
            ReadError::TooLargeAfterRead => {
                anyhow::anyhow!("session metadata file grew beyond its size limit")
            }
        }
    })
}

fn load(path: &Path) -> Result<Document> {
    if let Some(bytes) = read_file(path)? {
        let document: Document =
            serde_json::from_slice(&bytes).context("unreadable metadata; original preserved")?;
        ensure!(
            document.schema_version == 1,
            "unsupported session metadata version"
        );
        for (id, record) in &document.records {
            record.selection.validate()?;
            ensure!(
                id == &record.selection.session_id
                    && record.server_revision > 0
                    && record.updated_at.is_finite(),
                "invalid session metadata record"
            );
        }
        return Ok(document);
    }
    Ok(Document::default())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn update(id: &str, model: &str, revision: u64) -> Update {
        Update {
            selection: Selection {
                session_id: id.into(),
                model_id: model.into(),
                reasoning_selection_id: "effort-high".into(),
                fast_mode_enabled: Some(false),
                source: Some(Source::Selection),
            },
            expected_revision: revision,
            mutation_id: format!("{id}-{model}-{revision}"),
        }
    }

    #[test]
    fn shared_wire_fixtures_round_trip_without_renaming_or_dropping_fields() {
        let request: Update =
            serde_json::from_str(include_str!("../../protocol-fixtures/metadata-update.json"))
                .unwrap();
        request.validate().unwrap();
        let raw: serde_json::Value =
            serde_json::from_str(include_str!("../../protocol-fixtures/metadata-record.json"))
                .unwrap();
        let record: Record = serde_json::from_value(raw.clone()).unwrap();
        assert_eq!(record.selection, request.selection);
        assert_eq!(record.server_revision, request.expected_revision + 1);
        assert_eq!(
            record.mutation_id.as_deref(),
            Some(request.mutation_id.as_str())
        );
        assert_eq!(serde_json::to_value(record).unwrap(), raw);
    }

    #[tokio::test]
    async fn competing_store_instances_preserve_independent_updates() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session-metadata-v2.json");
        let first = ConversationMetadataStore::new(Some(path.clone()));
        let second = ConversationMetadataStore::new(Some(path));
        let (a, b) = tokio::join!(
            first.update(update("alpha", "a", 0)),
            second.update(update("beta", "b", 0))
        );
        assert!(matches!(a.unwrap(), UpdateResult::Applied(_)));
        assert!(matches!(b.unwrap(), UpdateResult::Applied(_)));
        let Snapshot::Full {
            entries: records, ..
        } = first.read(None).await.unwrap()
        else {
            panic!("an unconditional read must return the snapshot");
        };
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].selection.model_id, "a");
        assert_eq!(records[1].selection.model_id, "b");
    }

    #[tokio::test]
    async fn stale_revision_conflicts_and_replayed_mutation_is_idempotent() {
        let directory = tempfile::tempdir().unwrap();
        let store =
            ConversationMetadataStore::new(Some(directory.path().join("session-metadata-v2.json")));
        let initial = update("chat", "first", 0);
        let first = store.update(initial.clone()).await.unwrap();
        assert_eq!(store.update(initial).await.unwrap(), first);
        assert!(matches!(
            store.update(update("chat", "stale", 0)).await.unwrap(),
            UpdateResult::Conflict(Some(_))
        ));
        let Snapshot::Full { entries, .. } = store.read(None).await.unwrap() else {
            panic!("an unconditional read must return the snapshot");
        };
        assert_eq!(entries[0].server_revision, 1);
        assert!(matches!(
            store.update(update("chat", "second", 1)).await.unwrap(),
            UpdateResult::Applied(_)
        ));
    }

    #[tokio::test]
    async fn a_replayed_mutation_answers_without_rewriting_the_file() {
        use std::os::unix::fs::MetadataExt;

        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session-metadata-v2.json");
        let store = ConversationMetadataStore::new(Some(path.clone()));
        let initial = update("chat", "first", 0);
        let first = store.update(initial.clone()).await.unwrap();
        let written = fs::metadata(&path).unwrap().ino();

        assert_eq!(store.update(initial).await.unwrap(), first);

        assert_eq!(fs::metadata(&path).unwrap().ino(), written);
    }

    #[tokio::test]
    async fn validators_follow_the_complete_snapshot_across_forks_and_restores() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session-metadata-v2.json");
        let store = ConversationMetadataStore::new(Some(path.clone()));
        let peer = ConversationMetadataStore::new(Some(path.clone()));
        let Snapshot::Full {
            entries,
            revision: empty,
        } = store.read(None).await.unwrap()
        else {
            panic!("an unconditional read must return the snapshot");
        };
        assert!(entries.is_empty());
        assert_eq!(
            peer.read(Some(empty.clone())).await.unwrap(),
            Snapshot::Unchanged { revision: empty }
        );

        store.update(update("high", "first", 0)).await.unwrap();
        store.update(update("high", "second", 1)).await.unwrap();
        let original = fs::read(&path).unwrap();
        let Snapshot::Full {
            revision: before_fork,
            ..
        } = store.read(None).await.unwrap()
        else {
            panic!("an unconditional read must return the snapshot");
        };
        peer.fork("high".into(), "fork".into()).await.unwrap();
        let Snapshot::Full {
            entries,
            revision: after_fork,
        } = store.read(Some(before_fork.clone())).await.unwrap()
        else {
            panic!("a lower-revision fork must invalidate the snapshot");
        };
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].server_revision, 1);
        peer.update(update("fork", "changed", 1)).await.unwrap();
        let Snapshot::Full {
            revision: before_restore,
            ..
        } = store.read(Some(after_fork)).await.unwrap()
        else {
            panic!("changing a fork must invalidate the snapshot");
        };

        fs::write(&path, original).unwrap();
        let Snapshot::Full { entries, revision } = peer.read(Some(before_restore)).await.unwrap()
        else {
            panic!("a restore must return its authoritative replacement");
        };
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].selection.session_id, "high");
        assert_eq!(revision, before_fork);
        assert_eq!(
            store.read(Some(revision.clone())).await.unwrap(),
            Snapshot::Unchanged { revision }
        );
    }

    #[tokio::test]
    async fn restored_content_changes_invalidate_a_validator_even_when_maximum_revision_is_unchanged()
     {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session-metadata-v2.json");
        let store = ConversationMetadataStore::new(Some(path.clone()));
        store.update(update("high", "original", 0)).await.unwrap();
        store.update(update("high", "current", 1)).await.unwrap();
        store.update(update("low", "first", 0)).await.unwrap();
        let Snapshot::Full { revision, .. } = store.read(None).await.unwrap() else {
            panic!("an unconditional read must return the snapshot");
        };
        let mut restored = load(&path).unwrap();
        restored.records.get_mut("low").unwrap().selection.model_id = "restored".into();
        fs::write(&path, serde_json::to_vec(&restored).unwrap()).unwrap();
        let Snapshot::Full { entries, .. } = store.read(Some(revision)).await.unwrap() else {
            panic!("content changes must invalidate a validator regardless of revisions");
        };
        assert_eq!(entries[0].server_revision, 2);
        assert_eq!(entries[1].server_revision, 1);
        assert_eq!(entries[1].selection.model_id, "restored");
    }

    #[tokio::test]
    async fn invalid_files_and_future_formats_are_never_replaced() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session-metadata-v2.json");
        for bytes in [
            b"not json".as_slice(),
            br#"{"schemaVersion":99,"records":{}}"#,
        ] {
            fs::write(&path, bytes).unwrap();
            let store = ConversationMetadataStore::new(Some(path.clone()));
            assert!(store.update(update("chat", "model", 0)).await.is_err());
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
    }
}
