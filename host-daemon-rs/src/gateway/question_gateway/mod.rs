//! The existing gateway owns these workers; their passive membership never owns turns.
mod recovery;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::{Mutex, Semaphore, mpsc, watch};
use tokio_util::sync::CancellationToken;

use super::{ApnsSend, ClientTx, Gateway};
use crate::notifications::notification_thread_id;
use crate::observability::journal::Source;
use crate::questions::{
    Anchor, Coverage, DismissRequest, Document, Entry, Fact, QuestionStore, Snapshot, normalize,
    relevant,
};
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};
use crate::time::unix_seconds;

const MAXIMUM_THREADS: usize = 32;
const QUIESCENT_SNAPSHOT_MAX_AGE: Duration = Duration::from_secs(10);
const MAXIMUM_RESPONSE_BYTES: usize = 2 * 1024 * 1024;

pub(super) struct Runtime {
    gateway: Weak<Gateway>,
    store: QuestionStore,
    entries: Mutex<HashMap<String, Watch>>,
    generation: AtomicU64,
    sequence: AtomicU64,
    tasks: crate::tasks::owned_tasks::OwnedTasks,
    scans: Arc<Semaphore>,
    events: crate::rpc::RequestBudget,
}

struct ObservationIdentity {
    thread: String,
    owner: String,
    generation: u64,
}

struct Watch {
    id: String,
    generation: u64,
    sender: Option<mpsc::Sender<Signal>>,
    snapshot: watch::Sender<Option<Snapshot>>,
    invalid: Arc<AtomicBool>,
    cancelled: CancellationToken,
    clients: HashMap<u64, Instant>,
    retry_after: Instant,
    verified_at: Option<Instant>,
}

struct Signal {
    fact: Option<Fact>,
    anchor: Option<Anchor>,
    complete: bool,
    activity: Option<bool>,
    _permit: crate::rpc::RequestPermit,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Query {
    thread_id: String,
    item_ids: Vec<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadRequest {
    queries: Vec<Query>,
}

impl ReadRequest {
    fn is_bounded(&self) -> bool {
        !self.queries.is_empty()
            && self.queries.len() <= 16
            && self.queries.iter().all(|query| {
                crate::questions::validate_id(&query.thread_id).is_ok()
                    && query.item_ids.len() <= 128
                    && query
                        .item_ids
                        .iter()
                        .all(|id| crate::questions::validate_id(id).is_ok())
            })
    }
}

impl Runtime {
    pub(super) fn new(directory: Option<PathBuf>, gateway: Weak<Gateway>) -> Self {
        Self {
            gateway,
            store: QuestionStore::new(directory),
            entries: Mutex::new(HashMap::new()),
            generation: AtomicU64::new(0),
            sequence: AtomicU64::new(1),
            tasks: crate::tasks::owned_tasks::OwnedTasks::default(),
            scans: Arc::new(Semaphore::new(2)),
            events: crate::rpc::RequestBudget::new(512, 4 * 1024 * 1024),
        }
    }

    pub(super) async fn stop(&self) {
        self.tasks.stop().await;
    }

    pub(super) async fn disconnected(&self) {
        self.generation.fetch_add(1, Ordering::AcqRel);
        for entry in self.entries.lock().await.values_mut() {
            entry.invalid.store(true, Ordering::Release);
            entry.cancelled.cancel();
            entry.sender = None;
            entry.snapshot.send_modify(|value| {
                if let Some(value) = value {
                    value.coverage = Coverage::Unavailable;
                    value.pending_item_ids = None;
                    value.reason = Some("Question observation disconnected".into());
                }
            });
        }
    }

    pub(super) async fn client_closed(&self, client: u64) {
        for entry in self.entries.lock().await.values_mut() {
            entry.clients.remove(&client);
        }
    }

    pub(super) async fn latest_pending_questions(&self) -> BTreeMap<String, i64> {
        let watches = self.entries.lock().await;
        let mut latest = BTreeMap::new();
        for (thread, entry) in watches.iter() {
            if entry.invalid.load(Ordering::Acquire) {
                continue;
            }
            let observed = entry.snapshot.borrow();
            let Some(snapshot) = observed
                .as_ref()
                .filter(|snapshot| snapshot.coverage == Coverage::Ready)
            else {
                continue;
            };
            let Some(pending) = &snapshot.pending_item_ids else {
                continue;
            };
            if let Some(asked_at_ms) = snapshot
                .records
                .iter()
                .filter(|record| pending.contains(&record.item_id))
                .filter_map(|record| record.asked_at_ms)
                .max()
            {
                latest.insert(thread.clone(), asked_at_ms);
            }
        }
        latest
    }

    pub(super) async fn passive_only(&self, message: &Value) -> bool {
        if message.get("id").is_some() {
            return false;
        }
        let Some(thread) = notification_thread_id(message) else {
            return false;
        };
        let watches = self.entries.lock().await;
        watches
            .get(&thread)
            .is_some_and(|entry| entry.sender.is_some() && !entry.cancelled.is_cancelled())
    }

    pub(super) async fn ingest(&self, message: &Value) {
        if message.get("id").is_some() {
            return;
        }
        let Some(thread) =
            notification_thread_id(message).filter(|thread| !thread.starts_with("claude_"))
        else {
            return;
        };
        let method = message["method"].as_str().unwrap_or_default();
        let watched = self.entries.lock().await.contains_key(&thread);
        let is_question = method == "item/completed"
            && message["params"]["item"]["delivery"] == "async"
            && message["params"]["item"]["questions"].is_array();
        if !watched && !is_question {
            return;
        }
        if matches!(method, "thread/reverted" | "thread/deleted") {
            if let Some(entry) = self.entries.lock().await.get_mut(&thread) {
                entry.invalid.store(true, Ordering::Release);
                entry.cancelled.cancel();
                entry.sender = None;
            }
            return;
        }
        let active =
            method == "thread/status/changed" && message["params"]["status"]["type"] == "active";
        let item_event = matches!(method, "item/started" | "item/completed")
            && relevant(&message["params"]["item"]);
        let inactive = method == "turn/completed" || method == "thread/closed";
        if !active && !item_event && !inactive {
            return;
        }
        if (active || is_question)
            && let Some(entry) = self.entries.lock().await.get_mut(&thread)
            && entry.sender.is_none()
        {
            entry.invalid.store(true, Ordering::Release);
        }
        if (active || is_question)
            && let Some(gateway) = self.gateway.upgrade()
            && let Err(error) = gateway.ensure_question_watch(&thread, None).await
        {
            gateway.journal.question(
                "unavailable",
                json!({"threadId":thread,"reason":error.to_string()}),
            );
            return;
        }
        let mut fact = None;
        let mut anchor = None;
        if item_event {
            let entry: Result<Entry, _> = serde_json::from_value(json!({
                "turnId":message["params"]["turnId"], "item":message["params"]["item"],
                "startedAtOrdinal":message["params"]["startedAtOrdinal"], "startedAtMs":message["params"]["startedAtMs"],
                "completedAtMs":message["params"]["completedAtMs"], "isComplete":method == "item/completed"
            }));
            let parsed = entry.and_then(|entry| {
                if let (Some(ordinal), Some(id)) =
                    (entry.started_at_ordinal, entry.item["id"].as_str())
                {
                    anchor = Some(Anchor {
                        item_id: id.into(),
                        ordinal,
                    });
                }
                normalize(&entry).map_err(serde::de::Error::custom)
            });
            match parsed {
                Ok(value) => fact = value,
                Err(_) => {
                    if let Some(entry) = self.entries.lock().await.get_mut(&thread) {
                        entry.invalid.store(true, Ordering::Release);
                        entry.cancelled.cancel();
                    }
                    return;
                }
            }
        }
        let bytes = match &fact {
            Some(Fact::Asked(value)) => {
                crate::wire::json::encoded_len(value).unwrap_or(MAXIMUM_RESPONSE_BYTES + 1)
            }
            Some(Fact::Answered(values)) => values
                .iter()
                .map(|(_, _, answer)| answer.text.len() + 1024)
                .sum(),
            _ => 1024,
        };
        let mut watches = self.entries.lock().await;
        if let Some(entry) = watches.get_mut(&thread) {
            let permit = self.events.try_acquire(bytes);
            let delivered = permit.is_some_and(|permit| {
                entry.sender.as_ref().is_some_and(|sender| {
                    sender
                        .try_send(Signal {
                            fact,
                            anchor,
                            complete: method == "item/completed",
                            activity: if active {
                                Some(true)
                            } else if inactive {
                                Some(false)
                            } else {
                                None
                            },
                            _permit: permit,
                        })
                        .is_ok()
                })
            });
            if !delivered {
                entry.invalid.store(true, Ordering::Release);
                entry.cancelled.cancel();
                entry.snapshot.send_modify(|snapshot| {
                    if let Some(snapshot) = snapshot {
                        snapshot.coverage = Coverage::CatchingUp;
                        snapshot.pending_item_ids = None;
                    }
                });
            }
        }
    }
}

impl Gateway {
    async fn ensure_question_watch(
        self: &Arc<Self>,
        thread: &str,
        client: Option<u64>,
    ) -> Result<watch::Receiver<Option<Snapshot>>> {
        crate::questions::validate_id(thread)?;
        ensure!(
            !thread.starts_with("claude_"),
            "Async question state is available for Codex conversations only"
        );
        let generation = self.questions.generation.load(Ordering::Acquire);
        let mut watches = self.questions.entries.lock().await;
        if let Some(entry) = watches.get_mut(thread)
            && entry.generation == generation
            && (((entry.sender.is_some()
                || entry
                    .verified_at
                    .is_some_and(|verified| verified.elapsed() < QUIESCENT_SNAPSHOT_MAX_AGE))
                && !entry.invalid.load(Ordering::Acquire)
                && !entry.cancelled.is_cancelled())
                || Instant::now() < entry.retry_after)
        {
            if let Some(client) = client {
                entry.clients.insert(client, Instant::now());
            }
            return Ok(entry.snapshot.subscribe());
        }
        if watches.len() >= MAXIMUM_THREADS && !watches.contains_key(thread) {
            let removable = watches
                .iter()
                .find(|(_, entry)| entry.sender.is_none())
                .map(|(thread, _)| thread.clone());
            if let Some(thread) = removable {
                watches.remove(&thread);
            }
            ensure!(
                watches.len() < MAXIMUM_THREADS,
                "question observation capacity reached"
            );
        }
        let old = watches.remove(thread);
        if let Some(old) = &old {
            old.cancelled.cancel();
        }
        let initial = old
            .as_ref()
            .and_then(|entry| entry.snapshot.borrow().clone())
            .map(|mut snapshot| {
                snapshot.coverage = Coverage::CatchingUp;
                snapshot.pending_item_ids = None;
                snapshot
            });
        let (snapshot, receiver) = watch::channel(initial);
        let (sender, events) = mpsc::channel(128);
        let cancelled = CancellationToken::new();
        let invalid = Arc::new(AtomicBool::new(false));
        let id = format!(
            "{}-{}-{}",
            std::process::id(),
            generation,
            self.questions.sequence.fetch_add(1, Ordering::Relaxed)
        );
        let mut clients = old.map(|entry| entry.clients).unwrap_or_default();
        if let Some(client) = client {
            clients.insert(client, Instant::now());
        }
        watches.insert(
            thread.into(),
            Watch {
                id: id.clone(),
                generation,
                sender: Some(sender),
                snapshot,
                invalid: Arc::clone(&invalid),
                cancelled: cancelled.clone(),
                clients,
                retry_after: Instant::now(),
                verified_at: None,
            },
        );
        let gateway = Arc::clone(self);
        let thread = thread.to_owned();
        let admitted = self.questions.tasks.spawn_graceful(
            "question observation",
            move |shutdown| async move {
                gateway
                    .question_worker(
                        ObservationIdentity {
                            thread,
                            owner: id,
                            generation,
                        },
                        events,
                        cancelled,
                        invalid,
                        shutdown,
                    )
                    .await
            },
        );
        ensure!(admitted, "question observation is shutting down");
        Ok(receiver)
    }

    pub(super) async fn handle_questions_rpc(
        self: &Arc<Self>,
        out: &ClientTx,
        method: &str,
        object: &serde_json::Map<String, Value>,
    ) -> Result<()> {
        let id = object.get("id").cloned().unwrap_or(Value::Null);
        let params = object.get("params").cloned().unwrap_or(Value::Null);
        let response = self.questions_rpc(out.id, method, params).await;
        self.respond(out, id, response, None).await.map(|_| ())
    }

    async fn questions_rpc(
        self: &Arc<Self>,
        client: u64,
        method: &str,
        params: Value,
    ) -> RpcResult {
        let internal = |error: anyhow::Error| RpcError::new(RpcCode::Internal, error.to_string());
        let result = if method == "conversation/questions/read" {
            let request = serde_json::from_value::<ReadRequest>(params)
                .ok()
                .filter(ReadRequest::is_bounded)
                .ok_or_else(|| {
                    RpcError::new(RpcCode::InvalidParams, "Invalid bounded question query")
                })?;
            self.read_questions(client, request).await
        } else {
            let request = serde_json::from_value::<DismissRequest>(params)
                .ok()
                .filter(|request| request.validate().is_ok())
                .ok_or_else(|| {
                    RpcError::new(RpcCode::InvalidParams, "Invalid question dismissal")
                })?;
            self.dismiss_question(request).await
        }
        .map_err(internal)?;
        let bytes = crate::wire::json::encoded_len(&result).map_err(internal)?;
        if bytes > MAXIMUM_RESPONSE_BYTES {
            return Err(RpcError::new(
                RpcCode::Unavailable,
                "Question response capacity exceeded; narrow the query",
            ));
        }
        Ok(result)
    }

    async fn read_questions(self: &Arc<Self>, client: u64, request: ReadRequest) -> Result<Value> {
        let mut results = Vec::new();
        for query in request.queries {
            let receiver = self
                .ensure_question_watch(&query.thread_id, Some(client))
                .await;
            let snapshot = match receiver {
                Ok(mut receiver) => {
                    let _ = tokio::time::timeout(
                        Duration::from_millis(500),
                        receiver.wait_for(|value| {
                            value
                                .as_ref()
                                .is_some_and(|snapshot| snapshot.coverage != Coverage::CatchingUp)
                        }),
                    )
                    .await;
                    receiver.borrow().clone().unwrap_or_else(|| {
                        unavailable(
                            &query.thread_id,
                            Coverage::CatchingUp,
                            "Loading question state",
                        )
                    })
                }
                Err(error) => {
                    unavailable(&query.thread_id, Coverage::Unavailable, &error.to_string())
                }
            };
            results.push(snapshot.select(&query.item_ids));
        }
        Ok(json!({"threads":results}))
    }

    async fn dismiss_question(self: &Arc<Self>, request: DismissRequest) -> Result<Value> {
        let thread = request.thread_id.clone();
        let snapshot = self
            .questions
            .entries
            .lock()
            .await
            .get(&thread)
            .and_then(|entry| {
                (!entry.invalid.load(Ordering::Acquire))
                    .then(|| entry.snapshot.borrow().clone())
                    .flatten()
            });
        ensure!(
            snapshot.is_some_and(|snapshot| snapshot.coverage == Coverage::Ready),
            "Refresh question state before dismissing"
        );
        let (conflict, record, document) = self
            .questions
            .store
            .transaction(&thread, move |document| {
                let (conflict, record) = document.dismiss(&request)?;
                Ok((conflict, record, document.clone()))
            })
            .await?;
        self.publish_questions(&thread, None, document.snapshot(Coverage::Ready, None))
            .await;
        self.journal.question(
            if conflict {
                "dismissConflict"
            } else {
                "dismissed"
            },
            json!({"threadId":thread,"itemId":record.item_id,"revision":record.revision}),
        );
        Ok(
            json!({"status":if conflict {"conflict"} else {"applied"}, "epoch":document.epoch,"revision":document.revision,"record":record}),
        )
    }

    async fn publish_questions(&self, thread: &str, owner: Option<&str>, snapshot: Snapshot) {
        let changed = {
            let mut watches = self.questions.entries.lock().await;
            let Some(entry) = watches.get_mut(thread) else {
                return;
            };
            if owner.is_some_and(|owner| entry.id != owner) {
                return;
            }
            let previous = entry.snapshot.borrow().clone();
            if previous.as_ref().is_some_and(|previous| {
                previous.epoch == snapshot.epoch && previous.revision > snapshot.revision
            }) {
                return;
            }
            if previous.as_ref() == Some(&snapshot) {
                return;
            }
            entry.verified_at = (snapshot.coverage == Coverage::Ready).then(Instant::now);
            entry.snapshot.send_replace(Some(snapshot.clone()));
            json!({"method":"conversation/questions/changed", "params":{
                "threadId":thread,"epoch":snapshot.epoch,"revision":snapshot.revision,
                "itemIds":snapshot.records.iter().map(|record| &record.item_id).take(128).collect::<Vec<_>>()
            }})
        };
        self.broadcast_json_awaiting_capacity(&changed, Source::Codex)
            .await;
        self.refresh_live_activity().await;
    }

    async fn question_worker(
        self: Arc<Self>,
        identity: ObservationIdentity,
        mut events: mpsc::Receiver<Signal>,
        cancelled: CancellationToken,
        invalid: Arc<AtomicBool>,
        shutdown: CancellationToken,
    ) -> Result<()> {
        let ObservationIdentity {
            thread,
            owner,
            generation,
        } = identity;
        let mut subscription = None;
        let result = {
            let work = async {
                let document = self
                    .questions
                    .store
                    .transaction(&thread, {
                        let owner = owner.clone();
                        move |document| {
                            document.writer = Some(owner);
                            document.revision = document
                                .revision
                                .checked_add(1)
                                .context("question revision exhausted")?;
                            Ok(document.clone())
                        }
                    })
                    .await?;
                self.publish_questions(
                    &thread,
                    Some(&owner),
                    document.snapshot(Coverage::CatchingUp, None),
                )
                .await;
                let permit = Arc::clone(&self.questions.scans).acquire_owned().await?;
                let response = self
                    .call_control("thread/subscribe", json!({"threadId":thread}))
                    .await?;
                subscription = response["subscriptionId"].as_str().map(str::to_owned);
                let mut active = response["checkpoint"]["activeTurn"].is_object();
                let checkpoint = response.get("checkpoint").cloned();
                let mut document =
                    recovery::reconstruct(&self, &thread, &owner, checkpoint.as_ref()).await?;
                drop(permit);
                let mut batch = Vec::new();
                while let Ok(signal) = events.try_recv() {
                    batch.push(signal);
                }
                let live_ids: HashSet<_> = batch
                    .iter()
                    .filter_map(|signal| match &signal.fact {
                        Some(Fact::Asked(question)) => Some(question.item_id.clone()),
                        _ => None,
                    })
                    .collect();
                self.questions
                    .store
                    .transaction(&thread, move |document| {
                        document.alert_attempted.extend(
                            document
                                .facts
                                .definitions
                                .keys()
                                .filter(|id| !live_ids.contains(*id))
                                .cloned(),
                        );
                        Ok(())
                    })
                    .await?;
                document = self
                    .apply_question_batch(&thread, &owner, batch, &mut active)
                    .await?
                    .unwrap_or(document);
                ensure!(
                    !active || subscription.is_some(),
                    "Conversation started during an unloaded history read; retry observation"
                );
                ensure!(
                    !invalid.load(Ordering::Acquire)
                        && generation == self.questions.generation.load(Ordering::Acquire),
                    "question observation lost coverage"
                );
                self.publish_questions(
                    &thread,
                    Some(&owner),
                    document.snapshot(Coverage::Ready, None),
                )
                .await;
                loop {
                    let interested = {
                        let mut watches = self.questions.entries.lock().await;
                        watches.get_mut(&thread).is_some_and(|watch| {
                            watch
                                .clients
                                .retain(|_, seen| seen.elapsed() < Duration::from_secs(45));
                            !watch.clients.is_empty()
                        })
                    };
                    if !active && (subscription.is_none() || !interested) {
                        break;
                    }
                    let signal = tokio::select! {
                        signal = events.recv() => signal,
                        _ = tokio::time::sleep(Duration::from_secs(5)) => continue,
                    };
                    let Some(signal) = signal else {
                        break;
                    };
                    let mut batch = vec![signal];
                    while batch.len() < 128 {
                        match events.try_recv() {
                            Ok(signal) => batch.push(signal),
                            Err(_) => break,
                        }
                    }
                    if let Some(document) = self
                        .apply_question_batch(&thread, &owner, batch, &mut active)
                        .await?
                    {
                        ensure!(
                            !invalid.load(Ordering::Acquire),
                            "question observation queue lost coverage"
                        );
                        self.publish_questions(
                            &thread,
                            Some(&owner),
                            document.snapshot(Coverage::Ready, None),
                        )
                        .await;
                    }
                }
                Ok::<_, anyhow::Error>(())
            };
            tokio::pin!(work);
            tokio::select! {
                result = &mut work => result,
                _ = cancelled.cancelled() => Err(anyhow::anyhow!("Question observation needs reconciliation")),
                _ = shutdown.cancelled() => Err(anyhow::anyhow!("Question observation stopped")),
            }
        };
        if let Some(subscription) = subscription
            && generation == self.questions.generation.load(Ordering::Acquire)
            && self
                .call_control(
                    "thread/subscription/close",
                    json!({"subscriptionId":subscription}),
                )
                .await
                .is_err()
        {
            invalid.store(true, Ordering::Release);
        }
        if let Err(error) = &result {
            invalid.store(true, Ordering::Release);
            let snapshot = self
                .questions
                .entries
                .lock()
                .await
                .get(&thread)
                .and_then(|entry| entry.snapshot.borrow().clone());
            let mut snapshot = snapshot.unwrap_or_else(|| {
                unavailable(&thread, Coverage::Unavailable, "Question state unavailable")
            });
            snapshot.coverage = Coverage::Unavailable;
            snapshot.pending_item_ids = None;
            snapshot.reason = Some(error.to_string().chars().take(240).collect());
            self.publish_questions(&thread, Some(&owner), snapshot)
                .await;
            self.journal.question(
                "unavailable",
                json!({"threadId":thread,"reason":error.to_string()}),
            );
        }
        if let Some(entry) = self.questions.entries.lock().await.get_mut(&thread)
            && entry.id == owner
        {
            entry.sender = None;
            if result.is_err() {
                entry.retry_after = Instant::now() + Duration::from_secs(2);
            }
        }
        result
    }

    async fn apply_question_batch(
        &self,
        thread: &str,
        owner: &str,
        batch: Vec<Signal>,
        active: &mut bool,
    ) -> Result<Option<Document>> {
        if batch.is_empty() {
            return Ok(None);
        }
        for signal in &batch {
            if let Some(value) = signal.activity {
                *active = value;
            }
        }
        let owner = owner.to_owned();
        let (document, alerts) = self
            .questions
            .store
            .transaction(thread, move |document| {
                ensure!(
                    document.writer.as_deref() == Some(&owner),
                    "question writer superseded"
                );
                let mut facts = document.facts.clone();
                let mut anchor = document.anchor.clone();
                let mut incomplete = document.incomplete.clone();
                let mut eligible = HashSet::new();
                for signal in batch {
                    if let Some(source) = signal.anchor {
                        if signal.complete {
                            incomplete.remove(&source.item_id);
                        } else {
                            incomplete.insert(source.item_id.clone(), source.ordinal);
                        }
                        if anchor
                            .as_ref()
                            .is_none_or(|old| source.ordinal > old.ordinal)
                        {
                            anchor = Some(source);
                        }
                    }
                    if let Some(fact) = signal.fact {
                        if let Fact::Asked(question) = &fact {
                            eligible.insert(question.item_id.clone());
                        }
                        facts.apply(fact)?;
                    }
                }
                document.replace_facts(facts, anchor, incomplete)?;
                let alerts: Vec<_> = document
                    .records()
                    .into_iter()
                    .filter(|record| {
                        eligible.contains(&record.item_id)
                            && record.is_pending()
                            && document.alert_attempted.insert(record.item_id.clone())
                    })
                    .collect();
                Ok((document.clone(), alerts))
            })
            .await?;
        for record in alerts {
            let title = record
                .questions
                .first()
                .map(|slot| slot.title.clone())
                .unwrap_or_default();
            let payload = json!({"eventID":format!("question:{thread}:{}",record.item_id),"source":"codex","sessionID":thread,
                "conversationID":Value::Null,"promptPreview":"Codex question","messagePreview":title,"workingDirectory":Value::Null,
                "createdAtUnixSeconds":unix_seconds(),"questionItemID":record.item_id});
            let sender = self.apns_completion_tx.lock().await.clone();
            let dropped = match sender {
                Some(sender) => sender
                    .try_send(ApnsSend {
                        collapse_id: format!("question:{thread}:{}", record.item_id),
                        title: "Codex has a question".into(),
                        subtitle: "".into(),
                        body: title,
                        payload,
                    })
                    .err()
                    .map(|error| match error {
                        mpsc::error::TrySendError::Full(_) => "queueFull",
                        mpsc::error::TrySendError::Closed(_) => "queueClosed",
                    }),
                None => Some("queueUnavailable"),
            };
            if let Some(reason) = dropped {
                self.journal.question(
                    "alertDropped",
                    json!({"threadId":thread,"itemId":record.item_id,"reason":reason}),
                );
            }
        }
        self.journal.question(
            "reconciled",
            json!({"threadId":thread,"epoch":document.epoch,"revision":document.revision}),
        );
        Ok(Some(document))
    }
}

fn unavailable(thread: &str, coverage: Coverage, reason: &str) -> Snapshot {
    Snapshot {
        thread_id: thread.into(),
        epoch: String::new(),
        revision: 0,
        coverage,
        reason: Some(reason.chars().take(240).collect()),
        records: Vec::new(),
        pending_item_ids: None,
        missing_item_ids: Vec::new(),
    }
}

#[cfg(test)]
mod tests;
