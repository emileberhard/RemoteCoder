use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use tokio::sync::Semaphore;

use super::{Coverage, DismissRequest, Dismissal, Facts, Record, Resolution, Snapshot};

const MAXIMUM_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Anchor {
    pub item_id: String,
    pub ordinal: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Scan {
    pub cursor: Option<String>,
    pub initial_cursor: Option<String>,
    pub floor: Option<Anchor>,
    pub floor_found: bool,
    pub minimum_ordinal: Option<i64>,
    pub complete: bool,
    pub lineage_changed: bool,
    pub facts: Facts,
    pub anchor: Option<Anchor>,
    pub incomplete: BTreeMap<String, i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Document {
    schema_version: u32,
    pub thread_id: String,
    pub epoch: String,
    pub revision: u64,
    pub writer: Option<String>,
    pub facts: Facts,
    pub anchor: Option<Anchor>,
    pub incomplete: BTreeMap<String, i64>,
    pub scan: Option<Scan>,
    pub dismissals: BTreeMap<String, Dismissal>,
    #[serde(rename = "alerted")]
    pub alert_attempted: BTreeSet<String>,
    record_revisions: BTreeMap<String, u64>,
}

impl Document {
    fn decode(bytes: &[u8]) -> Result<Self> {
        let document: Self = serde_json::from_slice(bytes)
            .context("unreadable question state; original preserved")?;
        ensure!(
            document.schema_version == 1,
            "unsupported question state; original preserved"
        );
        super::validate_id(&document.thread_id)?;
        Ok(document)
    }

    fn new(thread_id: String) -> Result<Self> {
        Ok(Self {
            schema_version: 1,
            thread_id,
            epoch: epoch()?,
            revision: 0,
            writer: None,
            facts: Facts::default(),
            anchor: None,
            incomplete: BTreeMap::new(),
            scan: None,
            dismissals: BTreeMap::new(),
            alert_attempted: BTreeSet::new(),
            record_revisions: BTreeMap::new(),
        })
    }

    pub(crate) fn records(&self) -> Vec<Record> {
        self.facts.records(&self.dismissals, &self.record_revisions)
    }

    pub(crate) fn snapshot(&self, coverage: Coverage, reason: Option<String>) -> Snapshot {
        let records = self.records();
        let pending_item_ids = (coverage == Coverage::Ready).then(|| {
            records
                .iter()
                .filter(|record| record.is_pending())
                .map(|record| record.item_id.clone())
                .collect()
        });
        Snapshot {
            thread_id: self.thread_id.clone(),
            epoch: self.epoch.clone(),
            revision: self.revision,
            coverage,
            reason,
            records,
            pending_item_ids,
            missing_item_ids: Vec::new(),
        }
    }

    pub(crate) fn replace_facts(
        &mut self,
        facts: Facts,
        anchor: Option<Anchor>,
        incomplete: BTreeMap<String, i64>,
    ) -> Result<()> {
        let previous = self.records();
        self.facts = facts;
        self.anchor = anchor;
        self.incomplete = incomplete;
        self.revise_records(previous)
    }

    fn revise_records(&mut self, previous: Vec<Record>) -> Result<()> {
        let current = self.records();
        let changed: Vec<_> = current
            .iter()
            .filter(|record| !previous.contains(record))
            .map(|record| record.item_id.clone())
            .collect();
        if !changed.is_empty() || previous.len() != current.len() {
            self.revision = self
                .revision
                .checked_add(1)
                .context("question revision exhausted")?;
            for id in changed {
                self.record_revisions.insert(id, self.revision);
            }
        }
        Ok(())
    }

    pub(crate) fn reset_lineage(&mut self) -> Result<()> {
        self.epoch = epoch()?;
        self.revision = 0;
        self.facts = Facts::default();
        self.anchor = None;
        self.scan = None;
        self.incomplete.clear();
        self.record_revisions.clear();
        self.dismissals.clear();
        self.alert_attempted.clear();
        Ok(())
    }

    pub(crate) fn dismiss(&mut self, request: &DismissRequest) -> Result<(bool, Record)> {
        request.validate()?;
        ensure!(
            request.thread_id == self.thread_id,
            "question conversation mismatch"
        );
        ensure!(
            !self
                .dismissals
                .iter()
                .any(
                    |(id, dismissal)| dismissal.mutation_id == request.mutation_id
                        && id != &request.item_id
                ),
            "mutationId reused for a different question"
        );
        let current = self
            .records()
            .into_iter()
            .find(|record| record.item_id == request.item_id)
            .context("question not found")?;
        if self.epoch != request.expected_epoch {
            return Ok((true, current));
        }
        if let Some(previous) = self.dismissals.get(&request.item_id)
            && previous.mutation_id == request.mutation_id
        {
            ensure!(
                previous.expected_record_revision == request.expected_record_revision,
                "mutationId reused with different payload"
            );
            return Ok((false, current));
        }
        if !current.is_pending() {
            return Ok((false, current));
        }
        if current.revision != request.expected_record_revision {
            return Ok((true, current));
        }
        let before = self.records();
        self.dismissals.insert(
            request.item_id.clone(),
            Dismissal {
                indices: current
                    .questions
                    .iter()
                    .filter(|slot| slot.resolution == Resolution::Pending)
                    .map(|slot| slot.index)
                    .collect(),
                mutation_id: request.mutation_id.clone(),
                expected_record_revision: request.expected_record_revision,
            },
        );
        self.revise_records(before)?;
        let record = self
            .records()
            .into_iter()
            .find(|record| record.item_id == request.item_id)
            .context("dismissed question lost its identity")?;
        Ok((false, record))
    }
}

fn epoch() -> Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes)
        .map_err(|error| anyhow::anyhow!("question epoch entropy unavailable: {error}"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

#[derive(Clone)]
pub(crate) struct QuestionStore {
    directory: Option<PathBuf>,
    admission: Arc<Semaphore>,
}

impl QuestionStore {
    pub fn new(directory: Option<PathBuf>) -> Self {
        Self {
            directory,
            admission: Arc::new(Semaphore::new(2)),
        }
    }

    pub(crate) async fn read(&self, thread: &str) -> Result<Document> {
        self.transaction(thread, |document| Ok(document.clone()))
            .await
    }

    pub(crate) async fn transaction<T: Send + 'static>(
        &self,
        thread: &str,
        operation: impl FnOnce(&mut Document) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        super::validate_id(thread)?;
        let thread = thread.to_owned();
        let directory = self
            .directory
            .clone()
            .context("question state storage is not configured")?;
        let permit = Arc::clone(&self.admission).acquire_owned().await?;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let path = directory.join(state_name(&thread));
            crate::storage::private_state::transaction(
                &path,
                "question state path has no parent",
                |path| {
                    let existing =
                        crate::storage::private_state::read_bounded(path, MAXIMUM_BYTES as u64)
                            .map_err(|error| match error {
                                crate::storage::private_state::ReadError::Io(error) => error.into(),
                                crate::storage::private_state::ReadError::NotRegular => {
                                    anyhow::anyhow!("question state is not a regular file")
                                }
                                crate::storage::private_state::ReadError::TooLargeBeforeRead
                                | crate::storage::private_state::ReadError::TooLargeAfterRead => {
                                    anyhow::anyhow!("question state capacity exceeded")
                                }
                            })?;
                    match existing {
                        Some(bytes) => {
                            let document = Document::decode(&bytes)?;
                            ensure!(
                                document.thread_id == thread,
                                "unsupported or misaddressed question state; original preserved"
                            );
                            Ok(document)
                        }
                        None => Document::new(thread),
                    }
                },
                |document| {
                    let before = document.clone();
                    let result = operation(document)?;
                    Ok((result, *document != before || !path.exists()))
                },
                |path, document| {
                    ensure!(
                        serde_json::to_vec(document)?.len() <= MAXIMUM_BYTES,
                        "question state capacity exceeded; original preserved"
                    );
                    crate::storage::private_state::write_json(path, document)
                },
            )
        })
        .await
        .context("question state worker failed")?
    }
}

fn state_name(thread: &str) -> String {
    format!("{}.json", crate::ids::sha256_hex(thread.as_bytes()))
}
