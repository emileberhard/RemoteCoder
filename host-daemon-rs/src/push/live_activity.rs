use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::storage::private_state;

pub(crate) const MAX_ATTENTION_ROWS: usize = 3;
const MAX_STATE_BYTES: u64 = 256 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct AttentionRow {
    #[serde(rename = "threadID")]
    pub thread_id: String,
    #[serde(rename = "accountID", default, skip_serializing_if = "Option::is_none")]
    pub account_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(flatten)]
    pub reason: AttentionReason,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "reason", rename_all = "camelCase")]
pub(crate) enum AttentionReason {
    FinishedUnread {
        #[serde(rename = "completedAtUnixSeconds")]
        completed_at: i64,
    },
    Question {
        #[serde(
            rename = "completedAtUnixSeconds",
            default,
            skip_serializing_if = "Option::is_none"
        )]
        completed_at: Option<i64>,
    },
}

impl AttentionReason {
    pub(crate) fn completed_at(self) -> Option<i64> {
        match self {
            Self::FinishedUnread { completed_at } => Some(completed_at),
            Self::Question { completed_at } => completed_at,
        }
    }
}

impl AttentionRow {
    pub(crate) fn attention_order(&self, other: &Self) -> Ordering {
        match (self.reason.completed_at(), other.reason.completed_at()) {
            (Some(left), Some(right)) => right.cmp(&left),
            (left, right) => right.is_some().cmp(&left.is_some()),
        }
        .then_with(|| self.thread_id.cmp(&other.thread_id))
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct LiveActivityContent {
    pub active_task_count: usize,
    pub attention: Vec<AttentionRow>,
    pub attention_count: usize,
}

impl LiveActivityContent {
    pub(crate) fn is_empty(&self) -> bool {
        self.active_task_count == 0 && self.attention_count == 0
    }

    pub(crate) fn relevance_score(&self) -> u8 {
        if self.attention_count > 0 {
            100
        } else if self.active_task_count > 0 {
            25
        } else {
            0
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LiveActivitySnapshot {
    pub epoch: String,
    pub revision: u64,
    pub content: LiveActivityContent,
    pub relevance_score: u8,
    pub updated_at_unix_seconds: f64,
}

#[derive(Debug)]
pub(super) struct Aggregate {
    path: Option<PathBuf>,
    scopes: Option<BTreeMap<String, LiveActivityContent>>,
    pub(super) delivered_tokens: BTreeSet<String>,
    last_timestamp: i64,
    pub(super) required_scopes: Option<BTreeSet<String>>,
    validated_scopes: BTreeSet<String>,
    unavailable_scopes: BTreeSet<String>,
    revision: u64,
    #[cfg(test)]
    pub(super) persistence_gate: Option<(
        std::sync::Arc<tokio::sync::Notify>,
        std::sync::Arc<tokio::sync::Notify>,
    )>,
}

impl Aggregate {
    pub(super) fn load(path: Option<PathBuf>) -> Self {
        let scopes = match path.as_deref() {
            Some(path) => match read_scopes(path) {
                Ok(scopes) => Some(scopes),
                Err(error) => {
                    warn!(error = %format!("{error:#}"), "Live Activity state unavailable; preserving state");
                    None
                }
            },
            None => Some(BTreeMap::new()),
        };
        Self {
            path,
            scopes,
            delivered_tokens: BTreeSet::new(),
            last_timestamp: 0,
            required_scopes: None,
            validated_scopes: BTreeSet::new(),
            unavailable_scopes: BTreeSet::new(),
            revision: 0,
            #[cfg(test)]
            persistence_gate: None,
        }
    }

    pub(super) fn next_timestamp(&mut self, now: i64) -> i64 {
        self.last_timestamp = now.max(self.last_timestamp + 1);
        self.last_timestamp
    }

    pub(super) async fn report(
        &mut self,
        scope: &str,
        content: LiveActivityContent,
    ) -> Result<bool> {
        let scopes = self
            .scopes
            .as_mut()
            .context("Live Activity state unavailable")?;
        let changed = if content.is_empty() {
            scopes.remove(scope).is_some()
        } else {
            scopes.insert(scope.to_owned(), content.clone()) != Some(content)
        };
        self.validated_scopes.insert(scope.to_owned());
        self.unavailable_scopes.remove(scope);
        if changed {
            self.persist().await;
        }

        Ok(changed)
    }

    pub(super) async fn retain_scopes(&mut self, retained: &BTreeSet<String>) -> Result<bool> {
        let scopes = self
            .scopes
            .as_mut()
            .context("Live Activity state unavailable")?;
        self.required_scopes = Some(retained.clone());
        let before = scopes.len();
        scopes.retain(|scope, _| retained.contains(scope));
        let changed = scopes.len() != before;
        self.validated_scopes
            .retain(|scope| retained.contains(scope));
        self.unavailable_scopes
            .retain(|scope| retained.contains(scope));
        if changed {
            self.persist().await;
        }
        Ok(changed)
    }

    pub(super) fn mark_unavailable(&mut self, scope: &str) {
        if self.unavailable_scopes.insert(scope.to_owned()) {
            self.delivered_tokens.clear();
        }
    }

    pub(super) fn next_revision(&mut self) -> u64 {
        self.revision += 1;
        self.revision
    }

    pub(super) fn is_ready(&self) -> bool {
        self.unavailable_scopes.is_empty()
            && self.required_scopes.as_ref().is_some_and(|required| {
                required
                    .iter()
                    .all(|scope| self.validated_scopes.contains(scope))
            })
            && self.scopes.as_ref().is_some_and(|scopes| {
                scopes
                    .keys()
                    .all(|scope| self.validated_scopes.contains(scope))
            })
    }

    async fn persist(&self) {
        #[cfg(test)]
        if let Some((started, release)) = &self.persistence_gate {
            started.notify_one();
            release.notified().await;
        }
        if let Some(path) = self.path.clone() {
            let scopes = self.scopes.clone();
            let persisted = tokio::task::spawn_blocking(move || {
                private_state::ensure_private_directory(
                    path.parent()
                        .context("Live Activity state path has no parent")?,
                )?;
                private_state::write_json(&path, &scopes)
            })
            .await
            .context("Live Activity state writer failed")
            .and_then(|result| result);
            if let Err(error) = persisted {
                warn!(error = %format!("{error:#}"), "failed to persist Live Activity state");
            }
        }
    }

    pub(super) fn merged(&self) -> Result<LiveActivityContent> {
        let mut merged = LiveActivityContent::default();
        for content in self
            .scopes
            .as_ref()
            .context("Live Activity state unavailable")?
            .values()
        {
            merged.active_task_count += content.active_task_count;
            merged.attention_count += content.attention_count;
            merged.attention.extend(content.attention.iter().cloned());
        }
        merged.attention.sort_by(AttentionRow::attention_order);
        merged.attention.truncate(MAX_ATTENTION_ROWS);
        Ok(merged)
    }
}

fn read_scopes(path: &Path) -> Result<BTreeMap<String, LiveActivityContent>> {
    let bytes = private_state::read_bounded(path, MAX_STATE_BYTES)
        .map_err(|error| anyhow::anyhow!("{error:?}"))
        .with_context(|| format!("reading {}", path.display()))?;
    match bytes {
        Some(bytes) => {
            serde_json::from_slice(&bytes).with_context(|| format!("parsing {}", path.display()))
        }
        None => Ok(BTreeMap::new()),
    }
}
