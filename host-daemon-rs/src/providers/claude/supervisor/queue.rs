use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use anyhow::{Context, Result};
use serde_json::{Value, json};
use tracing::warn;

use super::{ClaudeSupervisor, TurnErrorData, TurnOrigin, TurnStartError};
use crate::providers::claude::queued_messages::{
    Delivery, Queue, QueueHold, QueueWriteUncertain, QueuedMessage,
};
use crate::providers::claude::{ClaudeTurnRequest, ClaudeUserInput, session_uuid_from_thread_id};
use crate::rpc::error::RpcCode;

const MAX_START_FAILURES: u8 = 3;

enum Drain {
    Requested,
    Running { again: bool },
}

#[derive(Default)]
pub(crate) struct QueueDrains {
    threads: std::sync::Mutex<HashMap<String, Drain>>,
    deferrals: std::sync::Mutex<HashMap<String, String>>,
    ready: tokio::sync::Notify,
}

impl QueueDrains {
    fn threads(&self) -> std::sync::MutexGuard<'_, HashMap<String, Drain>> {
        self.threads.lock().expect("queue drains poisoned")
    }

    fn deferrals(&self) -> std::sync::MutexGuard<'_, HashMap<String, String>> {
        self.deferrals.lock().expect("queue deferrals poisoned")
    }

    fn request(&self, thread_id: &str) {
        let mut threads = self.threads();
        match threads.get_mut(thread_id) {
            Some(Drain::Running { again }) => *again = true,
            Some(Drain::Requested) => {}
            None => {
                threads.insert(thread_id.to_owned(), Drain::Requested);
                self.ready.notify_one();
            }
        }
    }

    async fn next(&self) -> Vec<String> {
        loop {
            let ready = self.ready.notified();
            let started = self
                .threads()
                .iter_mut()
                .filter(|(_, drain)| matches!(drain, Drain::Requested))
                .map(|(thread, drain)| {
                    *drain = Drain::Running { again: false };
                    thread.clone()
                })
                .collect::<Vec<_>>();
            if !started.is_empty() {
                return started;
            }
            ready.await;
        }
    }

    fn finish(&self, thread_id: &str) -> bool {
        let mut threads = self.threads();
        if let Some(Drain::Running { again }) = threads.get_mut(thread_id)
            && *again
        {
            *again = false;
            return true;
        }
        threads.remove(thread_id);
        false
    }
}

#[derive(Default)]
pub(crate) struct QueuedWrites(std::sync::Mutex<HashMap<String, (String, i32)>>);

impl QueuedWrites {
    pub(super) fn guard(&self) -> std::sync::MutexGuard<'_, HashMap<String, (String, i32)>> {
        self.0.lock().expect("queued writes poisoned")
    }
}

#[derive(Debug)]
pub(crate) enum QueuedOutcome {
    Started(String),
    Waiting,
    Changed,
    Failed {
        error: TurnStartError,
        held: Option<String>,
    },
}

enum EntryStart {
    Started(String),
    Vanished,
    Refused(TurnStartError),
    Undecided(TurnStartError),
}

#[derive(Debug)]
pub(crate) enum QueueAddError {
    Invalid(String),
    Started,
    Conflict,
    Failed(anyhow::Error),
}

impl TurnStartError {
    pub(crate) fn holds_queue(&self) -> bool {
        self.code == RpcCode::InvalidParams
            || matches!(
                self.data,
                Some(TurnErrorData::Capacity(_) | TurnErrorData::ProviderUnavailable)
            )
    }

    fn not_idle() -> Self {
        Self {
            data: None,
            code: RpcCode::InvalidRequest,
            message: "thread already has an active or pending turn".into(),
        }
    }
}

impl ClaudeSupervisor {
    pub(crate) async fn queue_drain_requests(&self) -> Vec<String> {
        self.queue_drains.next().await
    }

    pub(crate) fn finish_queue_drain(&self, thread_id: &str) -> bool {
        self.queue_drains.finish(thread_id)
    }

    pub(crate) fn request_queue_drain(&self, thread_id: &str) {
        if self.queued_messages.has(thread_id) {
            self.queue_drains.request(thread_id);
        }
    }

    pub(crate) fn sweep_queue_drains(&self) {
        let threads = self.queued_messages.threads();
        self.queue_drains
            .deferrals()
            .retain(|thread, _| threads.contains(thread));
        for thread in &threads {
            self.queue_drains.request(thread);
        }
    }

    pub(crate) fn defer_queue(&self, thread_id: &str, reason: &str) -> bool {
        let mut deferrals = self.queue_drains.deferrals();
        if deferrals.get(thread_id).is_some_and(|last| last == reason) {
            return false;
        }
        deferrals.insert(thread_id.to_owned(), reason.to_owned());
        true
    }

    pub(crate) async fn queued_messages(&self, thread_id: &str) -> Result<Queue> {
        let store = Arc::clone(&self.queued_messages);
        let thread = thread_id.to_owned();
        tokio::task::spawn_blocking(move || store.load(&thread))
            .await
            .context("Claude queue worker failed")?
    }

    async fn update_queue<T: Send + 'static>(
        &self,
        thread_id: &str,
        operation: impl FnOnce(&mut Queue) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let store = Arc::clone(&self.queued_messages);
        let thread = thread_id.to_owned();
        let (result, listed) = tokio::task::spawn_blocking(move || {
            store.update(&thread, |queue| {
                let previous = queue.clone();
                let result = operation(queue)?;
                Ok((result, !queue.lists_like(&previous)))
            })
        })
        .await
        .map_err(|error| anyhow::Error::from(error).context(QueueWriteUncertain))??;
        if listed {
            let _ = self
                .deliver(json!({"method":"thread/queue/changed","params":{"threadId":thread_id}}))
                .await;
        }
        Ok(result)
    }

    pub(crate) async fn queue_add(
        &self,
        thread_id: &str,
        id: &str,
        input: Value,
    ) -> Result<QueuedMessage, QueueAddError> {
        let parsed =
            ClaudeUserInput::from_input_items(Some(&input)).map_err(QueueAddError::Invalid)?;
        if parsed.is_empty() {
            return Err(QueueAddError::Invalid(
                "input text or image is required".into(),
            ));
        }
        crate::providers::claude::queued_messages::check_entry(&input)
            .map_err(|capacity| QueueAddError::Failed(capacity.into()))?;
        let lifecycle = self.lifecycles.lock(thread_id).await;
        let queued = self
            .queued_messages(thread_id)
            .await
            .map_err(QueueAddError::Failed)?;
        if queued.entry(id).is_none()
            && self
                .input_started(thread_id, id)
                .await
                .map_err(QueueAddError::Failed)?
        {
            return Err(QueueAddError::Started);
        }
        let message = QueuedMessage {
            id: id.to_owned(),
            input,
            delivery: Delivery::Queued,
            failures: 0,
        };
        let added = self
            .update_queue(thread_id, move |queue| {
                if let Some(existing) = queue.entry(&message.id) {
                    return Ok((existing.input == message.input).then(|| existing.clone()));
                }
                queue.entries.push(message.clone());
                Ok(Some(message))
            })
            .await
            .map_err(QueueAddError::Failed)?
            .ok_or(QueueAddError::Conflict)?;
        drop(lifecycle);
        self.request_queue_drain(thread_id);
        Ok(added)
    }

    pub(crate) async fn queue_delete(&self, thread_id: &str, id: &str) -> Result<bool> {
        let id = id.to_owned();
        self.update_queue(thread_id, move |queue| {
            let before = queue.entries.len();
            queue
                .entries
                .retain(|entry| entry.id != id || entry.delivery != Delivery::Queued);
            if queue.entries.is_empty() {
                queue.hold = None;
            }
            Ok(queue.entries.len() < before)
        })
        .await
    }

    pub(super) async fn release_queue_hold(&self, thread_id: &str) {
        if !self.queued_messages.has(thread_id) {
            return;
        }
        if let Err(error) = self
            .update_queue(thread_id, |queue| {
                queue.hold = None;
                Ok(())
            })
            .await
        {
            warn!(%thread_id, error = %format!("{error:#}"), "Claude queue hold was not released");
        }
    }

    pub(crate) async fn queue_has_pending_work(&self, thread_id: &str) -> Result<bool> {
        Ok(self.unheld_head(thread_id).await?.is_some())
    }

    pub(crate) async fn queue_ready(&self, thread_id: &str) -> Result<Option<QueuedMessage>> {
        if !self.is_idle_for_queue(thread_id).await {
            return Ok(None);
        }
        self.unheld_head(thread_id).await
    }

    async fn unheld_head(&self, thread_id: &str) -> Result<Option<QueuedMessage>> {
        if !self.queued_messages.has(thread_id) {
            return Ok(None);
        }
        let queue = self.queued_messages(thread_id).await?;
        if queue.hold.is_some() || self.conversation_index.parent(thread_id).await?.stopped {
            return Ok(None);
        }
        Ok(queue.entries.into_iter().next())
    }

    async fn input_started(&self, thread_id: &str, id: &str) -> Result<bool> {
        if self.runtime_holds_input(thread_id, id).await {
            return Ok(true);
        }
        self.conversation_index.has_client_id(thread_id, id).await
    }

    async fn runtime_holds_input(&self, thread_id: &str, id: &str) -> bool {
        self.runtimes
            .lock()
            .await
            .get(thread_id)
            .is_some_and(|runtime| {
                runtime
                    .active_turn
                    .as_ref()
                    .is_some_and(|turn| turn.input.as_deref() == Some(id))
                    || runtime.input.unconsumed().holds(id)
            })
    }

    async fn is_idle_for_queue(&self, thread_id: &str) -> bool {
        let starting = self
            .starting
            .lock()
            .expect("Claude start reservations poisoned")
            .contains(thread_id);
        !starting
            && self
                .runtimes
                .lock()
                .await
                .get(thread_id)
                .is_none_or(|runtime| {
                    runtime.active_turn.is_none() && runtime.input.unconsumed().is_empty()
                })
    }

    pub(crate) async fn start_next_queued(
        self: &Arc<Self>,
        thread_id: &str,
        expected: &str,
    ) -> QueuedOutcome {
        if self.refuse_while_closing().is_err() {
            return QueuedOutcome::Waiting;
        }
        let _lifecycle = self.lifecycles.lock(thread_id).await;
        if !self.is_idle_for_queue(thread_id).await {
            return QueuedOutcome::Waiting;
        }
        let queue = match self.settle_starts(thread_id).await {
            Ok(queue) => queue,
            Err(error) => {
                return QueuedOutcome::Failed {
                    error: queue_unreadable(&error),
                    held: None,
                };
            }
        };
        let Some(head) = queue.entries.first().filter(|head| head.id == expected) else {
            return QueuedOutcome::Changed;
        };
        let stopped = match self.conversation_index.parent(thread_id).await {
            Ok(parent) => parent.stopped,
            Err(error) => {
                return QueuedOutcome::Failed {
                    error: queue_unreadable(&error),
                    held: None,
                };
            }
        };
        if queue.hold.is_some()
            || stopped
            || queue
                .entries
                .iter()
                .any(|entry| entry.delivery != Delivery::Queued)
        {
            return QueuedOutcome::Waiting;
        }
        match self.start_entry(thread_id, head).await {
            EntryStart::Started(turn_id) => {
                self.queue_drains.deferrals().remove(thread_id);
                QueuedOutcome::Started(turn_id)
            }
            EntryStart::Vanished => QueuedOutcome::Changed,
            EntryStart::Refused(error) if error.code == RpcCode::ServerBusy => {
                QueuedOutcome::Waiting
            }
            EntryStart::Refused(error) => {
                let held = self.refuse_head(thread_id, &head.id, &error).await;
                QueuedOutcome::Failed { error, held }
            }
            EntryStart::Undecided(error) => QueuedOutcome::Failed { error, held: None },
        }
    }

    pub(crate) async fn start_queued_now(
        self: &Arc<Self>,
        thread_id: &str,
        id: &str,
    ) -> Result<String, TurnStartError> {
        self.refuse_while_closing()?;
        let _lifecycle = self.lifecycles.lock(thread_id).await;
        if !self.is_idle_for_queue(thread_id).await {
            return Err(TurnStartError::not_idle());
        }
        let queue = self
            .settle_starts(thread_id)
            .await
            .map_err(|error| queue_unreadable(&error))?;
        if queue
            .entries
            .iter()
            .any(|entry| entry.delivery != Delivery::Queued)
        {
            return Err(TurnStartError::not_idle());
        }
        let not_found = || TurnStartError {
            data: None,
            code: RpcCode::InvalidRequest,
            message: format!("queued submission not found: {id}"),
        };
        let entry = queue.entry(id).ok_or_else(not_found)?;
        match self.start_entry(thread_id, entry).await {
            EntryStart::Started(turn_id) => Ok(turn_id),
            EntryStart::Vanished => Err(not_found()),
            EntryStart::Refused(error) | EntryStart::Undecided(error) => Err(error),
        }
    }

    async fn start_entry(self: &Arc<Self>, thread_id: &str, entry: &QueuedMessage) -> EntryStart {
        let prepared = async {
            let request = self.queued_request(thread_id, entry).await?;
            let policy = self.conversation_launch_policy(thread_id).await?;
            Ok::<_, TurnStartError>((request, policy))
        };
        let (request, policy) = match prepared.await {
            Ok(prepared) => prepared,
            Err(error) => return EntryStart::Refused(error),
        };
        let id = entry.id.clone();
        let claimed = self
            .update_queue(thread_id, move |queue| {
                let Some(entry) = queue.entries.iter_mut().find(|entry| entry.id == id) else {
                    return Ok(false);
                };
                entry.delivery = Delivery::Starting;
                Ok(true)
            })
            .await;
        match claimed {
            Ok(true) => {}
            Ok(false) => return EntryStart::Vanished,
            Err(error) => return EntryStart::Refused(queue_unreadable(&error)),
        }
        let error = match self
            .start_turn_with_policy(request, TurnOrigin::Queued, policy)
            .await
        {
            Ok(turn_id) => {
                self.remove_started(thread_id, &entry.id).await;
                return EntryStart::Started(turn_id);
            }
            Err(error) => error,
        };
        if self.runtime_holds_input(thread_id, &entry.id).await {
            self.remove_started(thread_id, &entry.id).await;
            return EntryStart::Undecided(error);
        }
        match self.settle_starts(thread_id).await {
            Ok(queue)
                if queue
                    .entry(&entry.id)
                    .is_some_and(|entry| entry.delivery == Delivery::Queued) =>
            {
                EntryStart::Refused(error)
            }
            Ok(_) => EntryStart::Undecided(error),
            Err(settle) => {
                warn!(%thread_id, queued = %entry.id, error = %format!("{settle:#}"), "a failed Claude queued start was not settled; the next drain settles it");
                EntryStart::Undecided(error)
            }
        }
    }

    async fn remove_started(&self, thread_id: &str, id: &str) {
        self.queued_writes.guard().remove(thread_id);
        let started = id.to_owned();
        if let Err(error) = self
            .update_queue(thread_id, move |queue| {
                queue.entries.retain(|entry| entry.id != started);
                if queue.entries.is_empty() {
                    queue.hold = None;
                }
                Ok(())
            })
            .await
        {
            warn!(%thread_id, queued = %id, error = %format!("{error:#}"), "a started Claude queued message is still listed; the next drain settles it");
        }
    }

    async fn refuse_head(
        &self,
        thread_id: &str,
        id: &str,
        error: &TurnStartError,
    ) -> Option<String> {
        let id = id.to_owned();
        let persistent = error.holds_queue();
        let message = error.message.clone();
        let held = self
            .update_queue(thread_id, move |queue| {
                let Some(head) = queue
                    .entries
                    .first_mut()
                    .filter(|head| head.id == id && head.delivery == Delivery::Queued)
                else {
                    return Ok(None);
                };
                head.failures = head.failures.saturating_add(1);
                if !persistent && head.failures < MAX_START_FAILURES {
                    return Ok(None);
                }
                head.failures = 0;
                if queue.hold.is_some() {
                    return Ok(None);
                }
                queue.hold = Some(QueueHold::new(&message));
                Ok(queue.hold.as_ref().map(|hold| hold.message.clone()))
            })
            .await;
        held.unwrap_or_else(|error| {
            warn!(%thread_id, error = %format!("{error:#}"), "a Claude queued start failure was not counted");
            None
        })
    }

    async fn queued_request(
        &self,
        thread_id: &str,
        entry: &QueuedMessage,
    ) -> Result<ClaudeTurnRequest, TurnStartError> {
        let session_uuid =
            session_uuid_from_thread_id(thread_id).ok_or_else(|| TurnStartError {
                data: None,
                code: RpcCode::InvalidParams,
                message: "threadId is required".into(),
            })?;
        let (selection, cwd) = self.recorded_selection(thread_id).await?.ok_or_else(|| {
            TurnStartError {
                data: None,
                code: RpcCode::InvalidParams,
                message: "this Claude conversation has no recorded model or folder for its queued messages".into(),
            }
        })?;
        let mut input =
            ClaudeUserInput::from_input_items(Some(&entry.input)).map_err(|message| {
                TurnStartError {
                    data: None,
                    code: RpcCode::InvalidParams,
                    message,
                }
            })?;
        input.client_id = Some(entry.id.clone());
        let first_turn = self.session_history(&cwd, session_uuid).is_none();
        Ok(ClaudeTurnRequest {
            thread_id: thread_id.to_owned(),
            session_uuid: session_uuid.to_owned(),
            first_turn,
            input,
            selection,
            cwd,
        })
    }

    pub(crate) async fn recorded_cwd(&self, thread_id: &str) -> Result<Option<String>> {
        let cwd = self
            .runtimes
            .lock()
            .await
            .get(thread_id)
            .map(|runtime| runtime.cwd.clone());
        if cwd.is_some() {
            return Ok(cwd);
        }
        Ok(self
            .conversation_index
            .parent(thread_id)
            .await?
            .selection
            .map(|selection| selection.cwd))
    }

    pub(super) async fn mark_queued_written(
        &self,
        thread_id: &str,
        id: &str,
        group: i32,
    ) -> Result<(), TurnStartError> {
        let entry = id.to_owned();
        let marked = self
            .update_queue(thread_id, move |queue| {
                let Some(entry) = queue.entries.iter_mut().find(|candidate| {
                    candidate.id == entry && candidate.delivery == Delivery::Starting
                }) else {
                    return Ok(false);
                };
                entry.delivery = Delivery::Written;
                Ok(true)
            })
            .await
            .map_err(|error| {
                TurnStartError::internal(format!(
                    "the queued message could not be marked as sent: {error:#}"
                ))
            })?;
        if !marked {
            return Err(TurnStartError::internal(
                "the queued message changed while it was starting",
            ));
        }
        self.queued_writes
            .guard()
            .insert(thread_id.to_owned(), (id.to_owned(), group));
        Ok(())
    }

    async fn settle_starts(&self, thread_id: &str) -> Result<Queue> {
        let queue = self.queued_messages(thread_id).await?;
        if queue
            .entries
            .iter()
            .all(|entry| entry.delivery == Delivery::Queued)
        {
            return Ok(queue);
        }
        let live = self.live_queued_write(thread_id).await;
        let decided = queue
            .entries
            .iter()
            .filter(|entry| entry.delivery == Delivery::Written && Some(&entry.id) != live.as_ref())
            .map(|entry| entry.id.clone())
            .collect::<HashSet<_>>();
        let recorded = self.recorded_inputs(thread_id, &decided).await?;
        if live.is_none() {
            self.queued_writes.guard().remove(thread_id);
        }
        self.update_queue(thread_id, move |queue| {
            queue.entries.retain(|entry| !recorded.contains(&entry.id));
            for entry in &mut queue.entries {
                if entry.delivery == Delivery::Starting || decided.contains(&entry.id) {
                    entry.delivery = Delivery::Queued;
                }
            }
            if queue.entries.is_empty() {
                queue.hold = None;
            }
            Ok(queue.clone())
        })
        .await
    }

    async fn live_queued_write(&self, thread_id: &str) -> Option<String> {
        let (id, group) = self.queued_writes.guard().get(thread_id).cloned()?;
        let current = self
            .runtimes
            .lock()
            .await
            .get(thread_id)
            .map(|runtime| runtime.process_group_id);
        (current != Some(group) && super::group_exists(nix::unistd::Pid::from_raw(group)))
            .then_some(id)
    }

    async fn recorded_inputs(
        &self,
        thread_id: &str,
        ids: &HashSet<String>,
    ) -> Result<HashSet<String>> {
        if ids.is_empty() {
            return Ok(HashSet::new());
        }
        let history = match (
            session_uuid_from_thread_id(thread_id),
            self.recorded_cwd(thread_id).await?,
        ) {
            (Some(session), Some(cwd)) => self.session_history(&cwd, session),
            _ => None,
        };
        let Some(history) = history else {
            return Ok(HashSet::new());
        };
        let ids = ids.iter().cloned().collect::<Vec<_>>();
        tokio::task::spawn_blocking(move || {
            let ids = ids.iter().map(String::as_str).collect::<Vec<_>>();
            crate::providers::claude::delivery_evidence::recorded_ids(&history, &ids).map(
                |recorded| {
                    recorded
                        .into_iter()
                        .map(str::to_owned)
                        .collect::<HashSet<_>>()
                },
            )
        })
        .await
        .context("Claude queue evidence worker failed")?
    }
}

fn queue_unreadable(error: &anyhow::Error) -> TurnStartError {
    TurnStartError {
        data: None,
        code: RpcCode::InvalidParams,
        message: format!("the Claude queue could not be read or updated: {error:#}"),
    }
}
