use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tracing::warn;

use crate::storage::private_state;
use crate::wire::cluster::AgentAddress;

pub(crate) const MAX_ATTENTION_ROWS: usize = 3;
pub(crate) const MAX_FLEET_HOSTS: usize = 32;
const MAX_TITLE_CHARS: usize = 80;
const MAX_THREAD_ID_BYTES: usize = 64;
const MAX_STATE_BYTES: u64 = 1024 * 1024;
const MAX_REPORT_BYTES: usize = 16 * 1024;
const MAX_PEERS: usize = 32;
const FLEET_VERSION: u8 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct AttentionRow {
    #[serde(rename = "hostID", default, skip_serializing_if = "Option::is_none")]
    pub host_id: Option<String>,
    #[serde(rename = "threadID")]
    pub thread_id: String,
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

pub(crate) fn attention_title(text: &str) -> String {
    let flattened: String = text
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect();
    if flattened.chars().count() <= MAX_TITLE_CHARS {
        return flattened;
    }
    let truncated: String = flattened.chars().take(MAX_TITLE_CHARS - 1).collect();
    format!("{truncated}…")
}

impl AttentionRow {
    fn is_bounded(&self) -> bool {
        self.thread_id.len() <= MAX_THREAD_ID_BYTES
            && !self.thread_id.chars().any(char::is_control)
            && self.title.as_ref().is_none_or(|title| {
                title.chars().count() <= MAX_TITLE_CHARS && !title.chars().any(char::is_control)
            })
    }
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
        .then_with(|| self.host_id.cmp(&other.host_id))
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FleetContent {
    #[serde(flatten)]
    pub content: LiveActivityContent,
    pub active_task_subagent_counts: Vec<usize>,
    #[serde(rename = "unavailableHostIDs")]
    pub unavailable_host_ids: Vec<String>,
    #[serde(skip)]
    pub certifies: bool,
}

impl FleetContent {
    pub(crate) fn is_certified_empty(&self) -> bool {
        self.certifies && self.content.is_empty()
    }
}

#[derive(Clone)]
pub(crate) struct Freshness(Arc<dyn Fn() -> bool + Send + Sync>);

impl Freshness {
    pub(crate) fn new(is_fresh: impl Fn() -> bool + Send + Sync + 'static) -> Self {
        Self(Arc::new(is_fresh))
    }

    pub(crate) fn is_fresh(&self) -> bool {
        (self.0)()
    }
}

impl std::fmt::Debug for Freshness {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("Freshness")
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FleetSnapshot {
    pub epoch: String,
    pub revision: u64,
    pub content: FleetContent,
    pub relevance_score: u8,
    pub updated_at_unix_seconds: f64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SourceProjection {
    pub content: LiveActivityContent,
    pub running_roots: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub ancestry: BTreeMap<String, String>,
    pub remote_parents: BTreeMap<String, AgentAddress>,
}

impl SourceProjection {
    pub(crate) fn running_trees(&self, host: &str) -> BTreeSet<AgentAddress> {
        self.running_roots
            .values()
            .map(|root| {
                self.remote_parents
                    .get(root)
                    .cloned()
                    .unwrap_or_else(|| AgentAddress {
                        host_id: host.to_owned(),
                        thread_id: root.clone(),
                    })
            })
            .collect()
    }

    fn validate_report(&self, host: &str) -> Result<()> {
        let content = &self.content;
        ensure!(
            content.attention.len() <= MAX_ATTENTION_ROWS
                && content.attention_count >= content.attention.len()
                && content.active_task_count == self.running_trees(host).len(),
            "a Live Activity report is inconsistent"
        );
        ensure!(
            content
                .attention
                .iter()
                .all(|row| row.host_id.is_none() && !row.thread_id.is_empty())
                && self
                    .running_roots
                    .iter()
                    .chain(&self.ancestry)
                    .all(|(thread, root)| !thread.is_empty() && !root.is_empty())
                && self.remote_parents.values().all(|parent| {
                    parent.host_id != host && crate::ids::is_session_uuid(&parent.host_id)
                }),
            "a Live Activity report carries only its own host's projection"
        );
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_REPORT_BYTES,
            "a Live Activity report exceeds {MAX_REPORT_BYTES} bytes"
        );
        Ok(())
    }

    fn root(&self, thread: &str) -> Option<&String> {
        self.running_roots
            .get(thread)
            .or_else(|| self.ancestry.get(thread))
            .or_else(|| self.running_roots.values().find(|root| *root == thread))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PeerReport {
    pub projection: Option<SourceProjection>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PeerOutcome {
    Accepted,
    Stale,
    Rejected(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Coverage {
    Current,
    LastKnown,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LocalState {
    Restored,
    Current,
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Binding {
    client: u64,
    certifies: bool,
}

#[derive(Debug, Default)]
struct Peer {
    projection: Option<SourceProjection>,
    binding: Option<Binding>,
}

impl Peer {
    fn coverage(&self) -> Coverage {
        match (&self.projection, self.binding) {
            (
                Some(_),
                Some(Binding {
                    certifies: true, ..
                }),
            ) => Coverage::Current,
            (Some(_), _) => Coverage::LastKnown,
            (None, _) => Coverage::Unknown,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct CacheDocument {
    version: u8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    local: Option<SourceProjection>,
    peers: BTreeMap<String, SourceProjection>,
}

#[derive(Debug)]
pub(super) struct Sources {
    local: Option<SourceProjection>,
    local_freshness: Option<Freshness>,
    local_state: LocalState,
    peers: BTreeMap<String, Peer>,
}

#[derive(Debug)]
pub(super) struct Publication {
    path: Option<PathBuf>,
    cached: Option<CacheDocument>,
    pub(super) delivered: BTreeMap<String, Value>,
    last_timestamp: i64,
    revision: u64,
}

pub(super) fn load(path: Option<PathBuf>) -> (Sources, Publication) {
    let cached = path.as_deref().and_then(|path| {
        read_cache(path)
            .inspect_err(|error| {
                warn!(error = %format!("{error:#}"), "Live Activity cache unreadable; starting without last-known content");
            })
            .ok()
            .flatten()
    });
    let sources = Sources {
        local: cached.as_ref().and_then(|cache| cache.local.clone()),
        local_freshness: None,
        local_state: LocalState::Restored,
        peers: cached
            .as_ref()
            .map(|cache| {
                cache
                    .peers
                    .iter()
                    .map(|(host, projection)| {
                        (
                            host.clone(),
                            Peer {
                                projection: Some(projection.clone()),
                                binding: None,
                            },
                        )
                    })
                    .collect()
            })
            .unwrap_or_default(),
    };
    let publication = Publication {
        path,
        cached,
        delivered: BTreeMap::new(),
        last_timestamp: 0,
        revision: 0,
    };
    (sources, publication)
}

impl Sources {
    pub(super) fn is_restoring(&self) -> bool {
        self.local_state == LocalState::Restored
    }

    pub(super) fn local_content(&self) -> Option<&LiveActivityContent> {
        self.current_local().map(|local| &local.content)
    }

    pub(super) fn local_superseded(&self) -> bool {
        self.local_state == LocalState::Current
            && self
                .local_freshness
                .as_ref()
                .is_some_and(|freshness| !freshness.is_fresh())
    }

    fn current_local(&self) -> Option<&SourceProjection> {
        (self.local_state == LocalState::Current)
            .then_some(self.local.as_ref())
            .flatten()
    }

    pub(super) fn report(&self) -> PeerReport {
        PeerReport {
            projection: self.current_local().cloned(),
        }
    }

    pub(super) fn report_local(
        &mut self,
        projection: SourceProjection,
        freshness: Freshness,
    ) -> bool {
        let changed = self.local.as_ref() != Some(&projection);
        self.local = Some(projection);
        self.local_freshness = Some(freshness);
        let certified = self.local_state != LocalState::Current;
        self.local_state = LocalState::Current;
        changed || certified
    }

    pub(super) fn mark_local_unavailable(&mut self) -> bool {
        let changed = self.local_state != LocalState::Unavailable;
        self.local_state = LocalState::Unavailable;
        changed
    }

    pub(super) fn receive_peer(
        &mut self,
        host: &str,
        client: u64,
        report: Result<Option<SourceProjection>, String>,
    ) -> (PeerOutcome, bool) {
        if self
            .peers
            .get(host)
            .and_then(|peer| peer.binding)
            .is_some_and(|binding| binding.client > client)
        {
            return (PeerOutcome::Stale, false);
        }
        if !self.peers.contains_key(host) && self.peers.len() >= MAX_PEERS {
            return (
                PeerOutcome::Rejected("Live Activity peer capacity exceeded".into()),
                false,
            );
        }
        let peer = self.peers.entry(host.to_owned()).or_default();
        let before = (peer.coverage(), peer.projection.clone());
        let report = report.and_then(|projection| {
            projection
                .as_ref()
                .map(|projection| projection.validate_report(host))
                .transpose()
                .map(|_| projection)
                .map_err(|error| format!("{error:#}"))
        });
        let outcome = match report {
            Ok(projection) => {
                peer.binding = Some(Binding {
                    client,
                    certifies: projection.is_some(),
                });
                if projection.is_some() {
                    peer.projection = projection;
                }
                PeerOutcome::Accepted
            }
            Err(error) => {
                peer.binding = Some(Binding {
                    client,
                    certifies: false,
                });
                PeerOutcome::Rejected(error)
            }
        };
        let changed = before != (peer.coverage(), peer.projection.clone());
        (outcome, changed)
    }

    pub(super) fn peer_connection_closed(&mut self, host: &str, client: u64) -> bool {
        match self
            .peers
            .get_mut(host)
            .and_then(|peer| peer.binding.as_mut())
        {
            Some(binding) if binding.client == client && binding.certifies => {
                binding.certifies = false;
                true
            }
            _ => false,
        }
    }

    pub(super) fn retain_peers(&mut self, members: &BTreeSet<String>) -> bool {
        let before = self.peers.len();
        self.peers.retain(|host, _| members.contains(host));
        self.peers.len() != before
    }

    pub(super) fn referenced(&self) -> BTreeSet<AgentAddress> {
        self.peers
            .values()
            .filter_map(|peer| peer.projection.as_ref())
            .flat_map(|projection| projection.remote_parents.values().cloned())
            .collect()
    }

    fn projection(&self, host: &str, local_host: &str) -> Option<&SourceProjection> {
        if host == local_host {
            self.local.as_ref()
        } else {
            self.peers.get(host)?.projection.as_ref()
        }
    }

    fn owning_tree(
        &self,
        mut tree: AgentAddress,
        local_host: &str,
    ) -> std::result::Result<AgentAddress, AgentAddress> {
        let mut visited = BTreeSet::new();
        while visited.insert(tree.clone()) {
            let Some(root) = self
                .projection(&tree.host_id, local_host)
                .and_then(|projection| {
                    let root = projection.root(&tree.thread_id)?;
                    Some((root.clone(), projection.remote_parents.get(root)))
                })
            else {
                return Err(tree);
            };
            match root {
                (_, Some(parent)) => tree = parent.clone(),
                (root, None) => {
                    tree.thread_id = root;
                    return Ok(tree);
                }
            }
        }
        Err(tree)
    }

    pub(super) fn fleet_content(&self, hosts: &[String], local_host: &str) -> FleetContent {
        let mut trees = BTreeMap::new();
        let mut attention = Vec::new();
        let mut attention_count = 0;
        let mut unavailable_host_ids = Vec::new();
        let mut certifies = true;
        for host in hosts {
            let (projection, coverage) = if host == local_host {
                let coverage = match (self.local_state, &self.local) {
                    (LocalState::Current, Some(_)) => Coverage::Current,
                    (_, Some(_)) => Coverage::LastKnown,
                    (_, None) => Coverage::Unknown,
                };
                (self.local.as_ref(), coverage)
            } else {
                match self.peers.get(host) {
                    Some(peer) => (peer.projection.as_ref(), peer.coverage()),
                    None => (None, Coverage::Unknown),
                }
            };
            if coverage != Coverage::Current {
                if !unavailable_host_ids.contains(host) {
                    unavailable_host_ids.push(host.clone());
                }
            } else if host == local_host && self.local_superseded() {
                certifies = false;
            }
            let Some(projection) = projection else {
                continue;
            };
            for (thread, root) in &projection.running_roots {
                let tree = projection
                    .remote_parents
                    .get(root)
                    .cloned()
                    .unwrap_or_else(|| AgentAddress {
                        host_id: host.clone(),
                        thread_id: root.clone(),
                    });
                let owner = match self.owning_tree(tree, local_host) {
                    Ok(root) => root,
                    Err(unresolved) => {
                        let owner = if hosts.contains(&unresolved.host_id) {
                            &unresolved.host_id
                        } else {
                            host
                        };
                        if !unavailable_host_ids.contains(owner) {
                            unavailable_host_ids.push(owner.clone());
                        }
                        unresolved
                    }
                };
                let is_subagent = owner.host_id != *host || owner.thread_id != *thread;
                *trees.entry(owner).or_insert(0) += usize::from(is_subagent);
            }
            attention_count += projection.content.attention_count;
            attention.extend(
                projection
                    .content
                    .attention
                    .iter()
                    .filter(|row| row.is_bounded())
                    .map(|row| AttentionRow {
                        host_id: Some(host.clone()),
                        ..row.clone()
                    }),
            );
        }
        attention.sort_by(AttentionRow::attention_order);
        attention.truncate(MAX_ATTENTION_ROWS);
        FleetContent {
            content: LiveActivityContent {
                active_task_count: trees.len(),
                attention,
                attention_count,
            },
            active_task_subagent_counts: trees.into_values().collect(),
            certifies: certifies && unavailable_host_ids.is_empty(),
            unavailable_host_ids,
        }
    }

    pub(super) fn cache(&self) -> CacheDocument {
        CacheDocument {
            version: FLEET_VERSION,
            local: self
                .local
                .clone()
                .filter(|local| *local != SourceProjection::default()),
            peers: self
                .peers
                .iter()
                .filter_map(|(host, peer)| Some((host.clone(), peer.projection.clone()?)))
                .collect(),
        }
    }
}

impl Publication {
    pub(super) fn next_timestamp(&mut self, now: i64) -> i64 {
        self.last_timestamp = now.max(self.last_timestamp + 1);
        self.last_timestamp
    }

    pub(super) fn next_revision(&mut self) -> u64 {
        self.revision += 1;
        self.revision
    }

    pub(super) async fn persist(&mut self, document: CacheDocument) {
        if self.cached.as_ref() == Some(&document) {
            return;
        }
        let Some(path) = self.path.clone() else {
            return;
        };
        let written = document.clone();
        let result = tokio::task::spawn_blocking(move || {
            private_state::ensure_private_directory(
                path.parent()
                    .context("Live Activity cache path has no parent")?,
            )?;
            private_state::write_json(&path, &written)
        })
        .await
        .context("Live Activity cache writer failed")
        .and_then(|result| result);
        match result {
            Ok(()) => self.cached = Some(document),
            Err(error) => warn!(error = %format!("{error:#}"), "Live Activity cache not written"),
        }
    }
}

fn read_cache(path: &Path) -> Result<Option<CacheDocument>> {
    let Some(bytes) = private_state::read_bounded(path, MAX_STATE_BYTES)
        .map_err(|error| anyhow::anyhow!("{error:?}"))
        .with_context(|| format!("reading {}", path.display()))?
    else {
        return Ok(None);
    };
    let document: CacheDocument =
        serde_json::from_slice(&bytes).with_context(|| format!("parsing {}", path.display()))?;
    ensure!(
        document.version == FLEET_VERSION,
        "unsupported Live Activity cache in {}",
        path.display()
    );
    Ok(Some(document))
}
