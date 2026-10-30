//! Durable identity and first-position facts missing from Claude's session format.
//! Provider text/tool results stay in the provider transcript. Only reasoning and plan
//! rows, which history does not rebuild from that transcript, carry their bounded
//! presentation snapshot here.
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::providers::claude::capacity::{
    MAX_PROVIDER_ID_BYTES, MAX_PROVIDER_ITEM_ID_BYTES, validate_id,
};
use crate::providers::claude::records::read_record;
use crate::storage::file_revision::FileRevision;
use crate::storage::private_state::{self, Creation};
use crate::wire::gateway::TerminalError;
use tokio::sync::{Mutex, OwnedMutexGuard};

pub(crate) mod job;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ItemIdentity {
    pub id: String,
    pub turn_id: String,
    pub started_at_ordinal: i64,
    pub started_at_ms: i64,
    pub completed_at_ms: Option<i64>,
    pub is_complete: bool,
    pub client_id: Option<String>,
    pub synthetic_item: Option<Value>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TurnIdentity {
    pub id: String,
    pub started_at_ms: i64,
    pub completed_at_ms: Option<i64>,
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<TerminalError>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recovery: Option<TurnRecovery>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub(crate) enum TurnRecovery {
    Pending,
    Continued {
        #[serde(rename = "turnId")]
        turn_id: String,
    },
    Ended,
    Unresolved,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "camelCase")]
enum Record {
    Item(ItemIdentity),
    Turn(TurnIdentity),
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MintedSession {
    thread_id: String,
    #[serde(default)]
    origin: SessionOrigin,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum SessionOrigin {
    TopLevel,
    Job {
        job_id: crate::agents::jobs::model::JobId,
    },
    #[default]
    Unknown,
}

const MAX_PARENT_RECORD_BYTES: u64 = 512 * 1024;
const MAX_MINTED_RECORD_BYTES: u64 = 4 * 1024;
const MAX_PARENT_DELIVERIES: usize = 256;
const MAX_EXECUTION_INDEX_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ParentSelection {
    pub cwd: String,
    pub model: String,
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub fast: bool,
}

impl ParentSelection {
    pub(crate) fn selection(self) -> crate::providers::claude::ClaudeSelection {
        crate::providers::claude::ClaudeSelection {
            model: self.model,
            effort: self.effort,
            fast: self.fast,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Delivery {
    pub id: String,
    pub fingerprint: String,
    #[serde(default)]
    pub state: DeliveryState,
    pub receipt: Value,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum DeliveryState {
    Prepared,
    Sending,
    #[default]
    Submitted,
    Recorded,
    Rejected,
    Uncertain,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Parent {
    pub selection: Option<ParentSelection>,
    #[serde(default)]
    pub delivery_route: ParentDeliveryRoute,
    pub stopped: bool,
    #[serde(default)]
    pub stop_generation: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_scope: Option<crate::agents::jobs::model::ToolScope>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_job: Option<job::JobHandle>,
    deliveries: VecDeque<Delivery>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    delivery_fingerprints: HashMap<String, String>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ParentDeliveryRoute {
    #[default]
    Unknown,
    Gateway,
    Native,
}

impl Parent {
    pub(crate) fn delivery(&self, id: &str) -> Option<&Delivery> {
        self.deliveries.iter().find(|delivery| delivery.id == id)
    }

    pub(crate) fn delivery_fingerprint(&self, id: &str) -> Option<&str> {
        self.delivery(id)
            .map(|delivery| delivery.fingerprint.as_str())
            .or_else(|| {
                self.delivery_fingerprints
                    .get(&crate::ids::sha256_hex(id.as_bytes()))
                    .map(String::as_str)
            })
    }

    pub(crate) fn delivery_for_input(&self, thread: &str, input: &str) -> Option<&Delivery> {
        self.deliveries
            .iter()
            .find(|delivery| delivery_uuid(thread, &delivery.id) == input)
    }

    pub(crate) fn mark_delivery_sending(&mut self, thread: &str, input: &str) -> Result<()> {
        if let Some(delivery) = self
            .deliveries
            .iter_mut()
            .find(|delivery| delivery_uuid(thread, &delivery.id) == input)
        {
            ensure!(
                matches!(delivery.state, DeliveryState::Prepared),
                "Claude callback input is not prepared for submission"
            );
            delivery.state = DeliveryState::Sending;
        }
        Ok(())
    }

    pub(crate) fn record_delivery(&mut self, delivery: Delivery) {
        self.deliveries
            .retain(|recorded| recorded.id != delivery.id);
        self.deliveries.push_back(delivery);
        while self.deliveries.len() > MAX_PARENT_DELIVERIES {
            let Some(position) = self.deliveries.iter().position(|delivery| {
                matches!(
                    delivery.state,
                    DeliveryState::Submitted | DeliveryState::Recorded
                )
            }) else {
                break;
            };
            if let Some(delivery) = self.deliveries.remove(position) {
                self.delivery_fingerprints.insert(
                    crate::ids::sha256_hex(delivery.id.as_bytes()),
                    delivery.fingerprint,
                );
            }
        }
    }
}

pub(crate) fn delivery_uuid(thread_id: &str, delivery_id: &str) -> String {
    crate::ids::hash_uuid("remotecoder-claude-message", &[thread_id, delivery_id])
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ParentRecord {
    thread_id: String,
    parent: Parent,
}

#[derive(Default)]
pub(crate) struct Index {
    pub items: HashMap<String, ItemIdentity>,
    pub turns: HashMap<String, TurnIdentity>,
    next_position: i64,
    valid_bytes: u64,
}

impl Index {
    fn apply(&mut self, record: Record) {
        match record {
            Record::Item(item) => {
                self.next_position = self.next_position.max(item.started_at_ordinal + 1);
                self.items.insert(item.id.clone(), item);
            }
            Record::Turn(turn) => {
                self.turns.insert(turn.id.clone(), turn);
            }
        }
    }
}

fn path(home: &Path, thread_id: &str) -> PathBuf {
    let key = crate::ids::sha256_hex(thread_id.as_bytes());
    home.join("remotecoder-history")
        .join(format!("{key}.jsonl"))
}

fn minted_path(home: &Path, thread_id: &str) -> PathBuf {
    path(home, thread_id).with_extension("minted")
}

fn parent_path(home: &Path, thread_id: &str) -> PathBuf {
    path(home, thread_id).with_extension("parent")
}

fn read_parent(home: &Path, thread_id: &str) -> Result<Parent> {
    let file = parent_path(home, thread_id);
    let Some(data) = read_record(&file, MAX_PARENT_RECORD_BYTES)? else {
        return Ok(Parent::default());
    };
    let record: ParentRecord =
        serde_json::from_slice(&data).context("invalid Claude parent record")?;
    ensure!(
        record.thread_id == thread_id,
        "Claude parent record {} belongs to another thread",
        file.display()
    );
    Ok(record.parent)
}

pub(crate) fn read(home: &Path, thread_id: &str) -> Result<Index> {
    read_path(&path(home, thread_id))
}

pub(crate) fn revision(home: &Path, thread_id: &str) -> Result<Option<FileRevision>> {
    match fs::metadata(path(home, thread_id)) {
        Ok(metadata) => Ok(Some(metadata.into())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn read_path(path: &Path) -> Result<Index> {
    let data = match fs::read(path) {
        Ok(data) => data,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Index::default()),
        Err(error) => return Err(error.into()),
    };
    parse(&data)
}

fn parse(data: &[u8]) -> Result<Index> {
    let mut index = Index::default();
    for line in data.split_inclusive(|byte| *byte == b'\n') {
        // A concurrent append or interrupted final write is not a complete record.
        if line.last() != Some(&b'\n') {
            break;
        }
        let record = serde_json::from_slice(line).context("invalid Claude identity record")?;
        validate_identity_ids(&record)?;
        index.apply(record);
        index.valid_bytes += line.len() as u64;
    }
    Ok(index)
}

fn validate_identity_ids(record: &Record) -> Result<()> {
    let resource = "historical identity ID bytes";
    match record {
        Record::Item(item) => {
            validate_id(&item.id, resource, MAX_PROVIDER_ITEM_ID_BYTES)?;
            validate_id(&item.turn_id, resource, MAX_PROVIDER_ID_BYTES)?;
            if let Some(client) = &item.client_id {
                validate_id(client, resource, MAX_PROVIDER_ID_BYTES)?;
            }
        }
        Record::Turn(turn) => {
            validate_id(&turn.id, resource, MAX_PROVIDER_ID_BYTES)?;
            if let Some(TurnRecovery::Continued { turn_id }) = &turn.recovery {
                validate_id(turn_id, resource, MAX_PROVIDER_ID_BYTES)?;
            }
        }
    }
    Ok(())
}

fn read_no_follow(path: &Path) -> Result<Option<Vec<u8>>> {
    let mut data = Vec::new();
    match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(mut file) => file.read_to_end(&mut data)?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    Ok(Some(data))
}

fn check_minted(data: &[u8], thread_id: &str, file: &Path) -> Result<SessionOrigin> {
    let record: MintedSession =
        serde_json::from_slice(data).context("invalid Claude creation record")?;
    ensure!(
        record.thread_id == thread_id,
        "Claude creation record {} belongs to another thread",
        file.display()
    );
    Ok(record.origin)
}

fn fork(home: &Path, source_id: &str, target_id: &str, turns: &HashSet<String>) -> Result<()> {
    let Some(source) = read_no_follow(&path(home, source_id))? else {
        return Ok(());
    };
    let mut kept = Vec::new();
    for line in source.split_inclusive(|byte| *byte == b'\n') {
        if line.last() != Some(&b'\n') {
            break;
        }
        let record: Record =
            serde_json::from_slice(line).context("invalid Claude identity record")?;
        let turn = match &record {
            Record::Item(item) => &item.turn_id,
            Record::Turn(turn) => &turn.id,
        };
        if turns.contains(turn) {
            kept.extend_from_slice(line);
        }
    }
    if kept.is_empty() {
        return Ok(());
    }
    let target = path(home, target_id);
    ensure!(
        private_state::create_new(&target, &kept)? == Creation::Created,
        "{} already holds Claude history identities",
        target.display()
    );
    Ok(())
}

type ThreadIndex = Arc<Mutex<Option<Index>>>;
type ThreadGuard = OwnedMutexGuard<Option<Index>>;

async fn under_guards<G: Send + 'static, T: Send + 'static>(
    guards: G,
    work: impl FnOnce(&mut G) -> T + Send + 'static,
) -> Result<T> {
    let mut guards = guards;
    Ok(tokio::task::spawn_blocking(move || work(&mut guards)).await?)
}

#[derive(Default)]
struct Cache {
    threads: HashMap<String, ThreadIndex>,
    order: VecDeque<String>,
}

pub(crate) struct Store {
    home: PathBuf,
    cache: Mutex<Cache>,
}

impl Store {
    pub fn new(home: PathBuf) -> Self {
        Self {
            home,
            cache: Mutex::new(Cache::default()),
        }
    }

    async fn thread(&self, id: &str) -> ThreadIndex {
        let mut cache = self.cache.lock().await;
        let index = Arc::clone(
            cache
                .threads
                .entry(id.to_string())
                .or_insert_with(|| Arc::new(Mutex::new(None))),
        );
        cache.order.retain(|key| key != id);
        cache.order.push_back(id.to_string());
        for _ in 0..cache.order.len() {
            if cache.threads.len() <= 16 {
                break;
            }
            let Some(key) = cache.order.pop_front() else {
                break;
            };
            if cache
                .threads
                .get(&key)
                .is_some_and(|entry| Arc::strong_count(entry) == 1)
            {
                cache.threads.remove(&key);
            } else {
                cache.order.push_back(key);
            }
        }
        index
    }

    pub(crate) async fn record_minted(&self, thread_id: &str) -> Result<()> {
        self.record_creation(thread_id, SessionOrigin::TopLevel)
            .await
    }

    pub(crate) async fn record_job_session(
        &self,
        thread_id: &str,
        job_id: &crate::agents::jobs::model::JobId,
    ) -> Result<()> {
        self.record_creation(
            thread_id,
            SessionOrigin::Job {
                job_id: job_id.clone(),
            },
        )
        .await
    }

    async fn record_creation(&self, thread_id: &str, origin: SessionOrigin) -> Result<()> {
        let file = minted_path(&self.home, thread_id);
        let mut encoded = serde_json::to_vec(&MintedSession {
            thread_id: thread_id.to_owned(),
            origin: origin.clone(),
        })?;
        encoded.push(b'\n');
        let thread = thread_id.to_owned();
        tokio::task::spawn_blocking(move || match private_state::create_new(&file, &encoded)? {
            Creation::Created => Ok(()),
            Creation::AlreadyExists => {
                ensure!(
                    matches!(origin, SessionOrigin::Job { .. }),
                    "Claude thread {thread} already has a creation record"
                );
                let saved = read_record(&file, MAX_MINTED_RECORD_BYTES)?
                    .context("Claude creation record disappeared")?;
                ensure!(
                    check_minted(&saved, &thread, &file)? == origin,
                    "Claude thread {thread} already has a different creation origin"
                );
                Ok(())
            }
        })
        .await?
    }

    pub(crate) fn is_minted(&self, thread_id: &str) -> Result<bool> {
        Ok(self.creation_origin(thread_id)?.is_some())
    }

    pub(crate) fn creation_origin(&self, thread_id: &str) -> Result<Option<SessionOrigin>> {
        let file = minted_path(&self.home, thread_id);
        let Some(data) = read_record(&file, MAX_MINTED_RECORD_BYTES)? else {
            return Ok(None);
        };
        check_minted(&data, thread_id, &file).map(Some)
    }

    pub(crate) async fn parent(&self, thread_id: &str) -> Result<Parent> {
        let thread = self.thread(thread_id).await.lock_owned().await;
        let (home, id) = (self.home.clone(), thread_id.to_owned());
        under_guards(thread, move |_| read_parent(&home, &id)).await?
    }

    pub(crate) async fn turn(
        &self,
        thread_id: &str,
        turn_id: &str,
    ) -> Result<Option<TurnIdentity>> {
        let thread = self.thread(thread_id).await.lock_owned().await;
        let file = path(&self.home, thread_id);
        let turn_id = turn_id.to_owned();
        under_guards(thread, move |cached| {
            if cached.is_none() {
                **cached = Some(match read_record(&file, MAX_EXECUTION_INDEX_BYTES)? {
                    Some(data) => parse(&data)?,
                    None => Index::default(),
                });
            }
            Ok(cached
                .as_ref()
                .and_then(|index| index.turns.get(&turn_id))
                .cloned())
        })
        .await?
    }

    pub(crate) async fn record_recovery(
        &self,
        thread_id: &str,
        turn_id: &str,
        recovery: TurnRecovery,
    ) -> Result<TurnRecovery> {
        let thread = self.thread(thread_id).await.lock_owned().await;
        let file = path(&self.home, thread_id);
        let turn_id = turn_id.to_owned();
        under_guards(thread, move |cached| {
            if cached.is_none() {
                **cached = Some(read_path(&file)?);
            }
            let index = cached
                .as_mut()
                .context("Claude identity index unavailable")?;
            let mut turn = index
                .turns
                .get(&turn_id)
                .cloned()
                .context("Exact Claude turn identity unavailable")?;
            // Replaying an unsettled journal must not erase a durable resolution.
            if matches!(recovery, TurnRecovery::Pending | TurnRecovery::Unresolved)
                && let Some(saved @ (TurnRecovery::Continued { .. } | TurnRecovery::Ended)) =
                    &turn.recovery
            {
                return Ok(saved.clone());
            }
            turn.recovery = Some(recovery.clone());
            append_record(&file, index, Record::Turn(turn))?;
            Ok(recovery)
        })
        .await?
    }

    pub(crate) async fn update_parent(
        &self,
        thread_id: &str,
        update: impl FnOnce(&mut Parent) + Send + 'static,
    ) -> Result<()> {
        self.transact_parent(thread_id, move |parent| {
            update(parent);
            Ok(())
        })
        .await
    }

    pub(crate) async fn transact_parent<T: Send + 'static>(
        &self,
        thread_id: &str,
        update: impl FnOnce(&mut Parent) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let thread = self.thread(thread_id).await.lock_owned().await;
        let (home, id) = (self.home.clone(), thread_id.to_owned());
        under_guards(thread, move |_| {
            private_state::transaction(
                &parent_path(&home, &id),
                "Claude parent record has no parent directory",
                |_| read_parent(&home, &id),
                |parent| {
                    let current = parent.clone();
                    let result = update(parent)?;
                    ensure!(
                        parent.deliveries.len() <= MAX_PARENT_DELIVERIES,
                        "Claude parent has too many unresolved deliveries"
                    );
                    Ok((result, *parent != current))
                },
                |file, parent| {
                    let encoded = serde_json::to_vec(&ParentRecord {
                        thread_id: id.clone(),
                        parent: parent.clone(),
                    })?;
                    ensure!(
                        encoded.len() as u64 <= MAX_PARENT_RECORD_BYTES,
                        "Claude parent record for {id} is full; retained delivery identities cannot be discarded"
                    );
                    private_state::replace(file, &encoded)
                },
            )
        })
        .await?
    }

    pub(crate) async fn fork_thread(
        &self,
        source_id: &str,
        target_id: &str,
        turns: HashSet<String>,
    ) -> Result<()> {
        ensure!(
            source_id != target_id,
            "A Claude thread cannot fork into itself"
        );
        let source = self.thread(source_id).await.lock_owned().await;
        let target = self.thread(target_id).await.lock_owned().await;
        let (home, source_id, target_id) = (
            self.home.clone(),
            source_id.to_owned(),
            target_id.to_owned(),
        );
        under_guards((source, target), move |(_, cached)| {
            let forked = fork(&home, &source_id, &target_id, &turns);
            **cached = None;
            forked
        })
        .await?
    }

    pub(crate) async fn record(&self, notification: &mut Value) -> Result<()> {
        let method = notification
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        if !matches!(
            method.as_str(),
            "item/started" | "item/completed" | "turn/started" | "turn/completed"
        ) {
            return Ok(());
        }
        let Some(params) = notification
            .get_mut("params")
            .and_then(Value::as_object_mut)
        else {
            return Ok(());
        };
        let Some(thread_id) = params.get("threadId").and_then(Value::as_str) else {
            return Ok(());
        };
        let file = path(&self.home, thread_id);
        let thread = self.thread(thread_id).await.lock_owned().await;
        let observed = params.clone();
        let position = under_guards(thread, move |cached| {
            record_locked(&file, cached, &method, &observed)
        })
        .await??;
        if let Some((ordinal, started_at)) = position {
            params.insert("startedAtOrdinal".to_string(), ordinal.into());
            params.insert("startedAtMs".to_string(), started_at.into());
        }
        Ok(())
    }
}

fn record_locked(
    file: &Path,
    cached: &mut ThreadGuard,
    method: &str,
    params: &serde_json::Map<String, Value>,
) -> Result<Option<(i64, i64)>> {
    if cached.is_none() {
        let index = read_path(file)?;
        if file.exists() {
            OpenOptions::new()
                .write(true)
                .open(file)?
                .set_len(index.valid_bytes)?;
        }
        **cached = Some(index);
    }
    let index = cached.as_mut().expect("loaded above");
    let record = if method.starts_with("item/") {
        let Some(item) = params.get("item") else {
            return Ok(None);
        };
        let Some(id) = item.get("id").and_then(Value::as_str) else {
            return Ok(None);
        };
        let Some(turn_id) = params.get("turnId").and_then(Value::as_str) else {
            return Ok(None);
        };
        let previous = index.items.get(id);
        let complete = method == "item/completed";
        let started_at_ms = previous
            .map(|item| item.started_at_ms)
            .or_else(|| params.get("startedAtMs").and_then(Value::as_i64))
            .or_else(|| params.get("completedAtMs").and_then(Value::as_i64))
            .context("Claude item is missing its observation timestamp")?;
        let identity = ItemIdentity {
            id: id.to_string(),
            turn_id: previous
                .map(|item| item.turn_id.clone())
                .unwrap_or_else(|| turn_id.to_string()),
            started_at_ordinal: previous
                .map(|item| item.started_at_ordinal)
                .unwrap_or(index.next_position),
            started_at_ms,
            completed_at_ms: if complete {
                params.get("completedAtMs").and_then(Value::as_i64)
            } else {
                previous.and_then(|item| item.completed_at_ms)
            },
            is_complete: complete || previous.is_some_and(|item| item.is_complete),
            client_id: item
                .get("clientId")
                .and_then(Value::as_str)
                .map(str::to_string)
                .or_else(|| previous.and_then(|item| item.client_id.clone())),
            synthetic_item: matches!(
                item.get("type").and_then(Value::as_str),
                Some("reasoning" | "plan" | "contextCompaction")
            )
            .then(|| item.clone()),
        };
        if previous.is_some() && !complete {
            return Ok(Some((identity.started_at_ordinal, identity.started_at_ms)));
        }
        Record::Item(identity)
    } else {
        let Some(turn) = params.get("turn") else {
            return Ok(None);
        };
        let Some(id) = turn.get("id").and_then(Value::as_str) else {
            return Ok(None);
        };
        Record::Turn(TurnIdentity {
            id: id.to_string(),
            started_at_ms: index
                .turns
                .get(id)
                .map(|turn| turn.started_at_ms)
                .unwrap_or_else(|| turn.get("startedAtMs").and_then(Value::as_i64).unwrap_or(0)),
            completed_at_ms: turn.get("completedAtMs").and_then(Value::as_i64),
            status: turn
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("inProgress")
                .to_string(),
            error: TerminalError::from_wire(turn.get("error")),
            recovery: index.turns.get(id).and_then(|turn| turn.recovery.clone()),
        })
    };
    let position = match &record {
        Record::Item(item) => Some((item.started_at_ordinal, item.started_at_ms)),
        Record::Turn(_) => None,
    };
    append_record(file, index, record)?;
    Ok(position)
}

fn append_record(file: &Path, index: &mut Index, record: Record) -> Result<()> {
    validate_identity_ids(&record)?;
    let mut encoded = serde_json::to_vec(&record)?;
    encoded.push(b'\n');
    fs::create_dir_all(file.parent().context("index parent")?)?;
    let mut output = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(file)?;
    // A prior failed write may have left a partial suffix in this same runtime.
    output.set_len(index.valid_bytes)?;
    output.write_all(&encoded)?;
    output.sync_data()?;
    index.valid_bytes += encoded.len() as u64;
    index.apply(record);
    Ok(())
}

#[cfg(test)]
mod tests;
