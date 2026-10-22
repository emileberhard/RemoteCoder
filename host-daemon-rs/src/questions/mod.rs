//! Question meaning is independent of transcript retention and execution state.
mod source;
mod store;
#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, BTreeSet};

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

pub(crate) use source::{Entry, Fact, normalize, relevant};
pub(crate) use store::{Anchor, Document, QuestionStore, Scan};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Choice {
    pub title: String,
    pub options: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Definition {
    pub item_id: String,
    pub turn_id: String,
    pub ordinal: i64,
    pub asked_at_ms: Option<i64>,
    pub questions: Vec<Choice>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Answer {
    pub text: String,
    pub item_id: String,
    pub client_id: Option<String>,
    pub ordinal: i64,
    pub at_ms: Option<i64>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Resolution {
    Pending,
    Answered,
    Dismissed,
    Superseded,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Slot {
    pub index: usize,
    pub title: String,
    pub options: Vec<String>,
    pub resolution: Resolution,
    pub answer: Option<Answer>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Record {
    pub item_id: String,
    pub turn_id: String,
    pub ordinal: i64,
    pub asked_at_ms: Option<i64>,
    pub revision: u64,
    pub questions: Vec<Slot>,
}

impl Record {
    pub(crate) fn is_pending(&self) -> bool {
        self.questions
            .iter()
            .any(|slot| slot.resolution == Resolution::Pending)
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Facts {
    pub definitions: BTreeMap<String, Definition>,
    // Answers can precede their definitions during descending native pagination.
    pub answers: BTreeMap<String, BTreeMap<usize, Answer>>,
    pub plain_boundary: Option<i64>,
}

impl Facts {
    pub(crate) fn apply(&mut self, fact: Fact) -> Result<()> {
        match fact {
            Fact::Asked(definition) => {
                if let Some(previous) = self.definitions.get_mut(&definition.item_id) {
                    ensure!(
                        previous.item_id == definition.item_id
                            && previous.turn_id == definition.turn_id
                            && previous.ordinal == definition.ordinal
                            && previous.questions == definition.questions,
                        "question item identity changed within one history lineage"
                    );
                    previous.asked_at_ms = previous.asked_at_ms.or(definition.asked_at_ms);
                } else {
                    self.definitions
                        .insert(definition.item_id.clone(), definition);
                }
            }
            Fact::Answered(entries) => {
                for (id, index, answer) in entries {
                    let slots = self.answers.entry(id).or_default();
                    match slots.get(&index) {
                        Some(previous) if previous.ordinal > answer.ordinal => {}
                        Some(previous) if previous.ordinal == answer.ordinal => {
                            ensure!(
                                previous.item_id == answer.item_id
                                    && previous.text == answer.text
                                    && (previous.client_id.is_none()
                                        || answer.client_id.is_none()
                                        || previous.client_id == answer.client_id),
                                "conflicting answers at one canonical source position"
                            );
                            let mut enriched = answer;
                            enriched.at_ms = previous.at_ms.or(enriched.at_ms);
                            enriched.client_id = previous.client_id.clone().or(enriched.client_id);
                            slots.insert(index, enriched);
                        }
                        _ => {
                            slots.insert(index, answer);
                        }
                    }
                }
            }
            Fact::Plain { ordinal } => {
                self.plain_boundary =
                    Some(self.plain_boundary.map_or(ordinal, |old| old.max(ordinal)));
            }
        }
        Ok(())
    }

    pub(crate) fn records(
        &self,
        dismissals: &BTreeMap<String, Dismissal>,
        revisions: &BTreeMap<String, u64>,
    ) -> Vec<Record> {
        let mut records: Vec<_> = self
            .definitions
            .values()
            .map(|definition| {
                let questions = definition
                    .questions
                    .iter()
                    .enumerate()
                    .map(|(index, choice)| {
                        let answer = self
                            .answers
                            .get(&definition.item_id)
                            .and_then(|slots| slots.get(&index))
                            .filter(|answer| answer.ordinal > definition.ordinal)
                            .cloned();
                        let resolution = if answer.is_some() {
                            Resolution::Answered
                        } else if dismissals
                            .get(&definition.item_id)
                            .is_some_and(|dismissal| dismissal.indices.contains(&index))
                        {
                            Resolution::Dismissed
                        } else if self
                            .plain_boundary
                            .is_some_and(|position| position > definition.ordinal)
                        {
                            Resolution::Superseded
                        } else {
                            Resolution::Pending
                        };
                        Slot {
                            index,
                            title: choice.title.clone(),
                            options: choice.options.clone(),
                            resolution,
                            answer,
                        }
                    })
                    .collect();
                Record {
                    item_id: definition.item_id.clone(),
                    turn_id: definition.turn_id.clone(),
                    ordinal: definition.ordinal,
                    asked_at_ms: definition.asked_at_ms,
                    revision: revisions.get(&definition.item_id).copied().unwrap_or(0),
                    questions,
                }
            })
            .collect();
        records.sort_by_key(|record| record.ordinal);
        records
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Dismissal {
    pub indices: BTreeSet<usize>,
    pub mutation_id: String,
    pub expected_record_revision: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DismissRequest {
    pub expected_epoch: String,
    pub thread_id: String,
    pub item_id: String,
    pub expected_record_revision: u64,
    pub mutation_id: String,
}

impl DismissRequest {
    pub(crate) fn validate(&self) -> Result<()> {
        validate_id(&self.expected_epoch)?;
        validate_id(&self.thread_id)?;
        validate_id(&self.item_id)?;
        validate_id(&self.mutation_id)
    }
}

pub(crate) fn validate_id(id: &str) -> Result<()> {
    ensure!(
        !id.is_empty() && id.trim() == id && id.len() <= 512,
        "identity must contain 1–512 trimmed bytes"
    );
    Ok(())
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Snapshot {
    pub thread_id: String,
    pub epoch: String,
    pub revision: u64,
    pub coverage: Coverage,
    pub reason: Option<String>,
    pub records: Vec<Record>,
    pub pending_item_ids: Option<Vec<String>>,
    pub missing_item_ids: Vec<String>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Coverage {
    Ready,
    CatchingUp,
    Unavailable,
}

impl Snapshot {
    pub(crate) fn select(mut self, requested: &[String]) -> Self {
        self.missing_item_ids = if self.coverage == Coverage::Ready {
            requested
                .iter()
                .filter(|id| !self.records.iter().any(|record| &record.item_id == *id))
                .cloned()
                .collect()
        } else {
            Vec::new()
        };
        self.records
            .retain(|record| record.is_pending() || requested.contains(&record.item_id));
        self
    }
}
