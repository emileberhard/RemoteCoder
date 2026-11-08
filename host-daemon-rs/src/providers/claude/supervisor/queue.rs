use std::collections::HashSet;
use std::sync::Arc;

use anyhow::{Context, Result};
use serde_json::{Value, json};
use tracing::warn;

use super::{ClaudeSupervisor, TurnErrorData, TurnOrigin, TurnStartError};
use crate::providers::claude::queued_messages::{HoldReason, Queue, QueueHold, QueuedMessage};
use crate::providers::claude::{ClaudeTurnRequest, ClaudeUserInput, session_uuid_from_thread_id};
use crate::rpc::error::RpcCode;

#[derive(Default)]
pub(crate) struct DrainRequests {
    threads: std::sync::Mutex<HashSet<String>>,
    ready: tokio::sync::Notify,
}

impl DrainRequests {
    fn request(&self, thread_id: &str) {
        self.threads
            .lock()
            .expect("queue drain requests poisoned")
            .insert(thread_id.to_owned());
        self.ready.notify_one();
    }

    async fn next(&self) -> Vec<String> {
        loop {
            let ready = self.ready.notified();
            let threads =
                std::mem::take(&mut *self.threads.lock().expect("queue drain requests poisoned"));
            if !threads.is_empty() {
                return threads.into_iter().collect();
            }
            ready.await;
        }
    }
}

pub(crate) enum QueuedStart {
    Next(String),
    Now(Option<String>),
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum QueuedOutcome {
    Started(String),
    Waiting,
    Changed,
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
    pub(crate) fn queued_threads(&self) -> Vec<String> {
        self.queued_messages.threads()
    }

    pub(crate) async fn queue_drain_requests(&self) -> Vec<String> {
        self.queue_drains.next().await
    }

    pub(crate) fn request_queue_drain(&self, thread_id: &str) {
        if self.queued_messages.has(thread_id) {
            self.queue_drains.request(thread_id);
        }
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
        let (result, changed) = tokio::task::spawn_blocking(move || {
            store.update(&thread, |queue| {
                let previous = queue.clone();
                let result = operation(queue)?;
                Ok((result, *queue != previous))
            })
        })
        .await
        .context("Claude queue worker failed")??;
        if changed {
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
            enqueued_at_ms: crate::time::unix_millis(),
            starting: false,
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
                .retain(|entry| entry.id != id || entry.starting);
            if queue.entries.is_empty() {
                queue.hold = None;
            }
            Ok(queue.entries.len() < before)
        })
        .await
    }

    pub(crate) async fn hold_queue(
        &self,
        thread_id: &str,
        reason: HoldReason,
        message: &str,
    ) -> Result<bool> {
        let hold = QueueHold::new(reason, message);
        self.update_queue(thread_id, move |queue| {
            if queue.entries.is_empty() || queue.hold.is_some() {
                return Ok(false);
            }
            queue.hold = Some(hold);
            Ok(true)
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

    pub(crate) async fn hold_if_newer_turns(&self, thread_id: &str) -> Result<bool> {
        let queue = self.queued_messages(thread_id).await?;
        let Some(head) = queue.entries.first() else {
            return Ok(false);
        };
        if queue.hold.is_some() {
            return Ok(false);
        }
        let queued = queue
            .entries
            .iter()
            .map(|entry| entry.id.clone())
            .collect::<HashSet<_>>();
        if !self
            .conversation_index
            .user_turn_since(thread_id, head.enqueued_at_ms, queued)
            .await?
        {
            return Ok(false);
        }
        self.hold_queue(
            thread_id,
            HoldReason::NewerTurns,
            "The conversation continued after these messages were queued, so they wait for Send Now.",
        )
        .await
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

    pub(crate) async fn start_queued(
        self: &Arc<Self>,
        thread_id: &str,
        start: QueuedStart,
    ) -> Result<QueuedOutcome, TurnStartError> {
        self.refuse_while_closing()?;
        let _lifecycle = self.lifecycles.lock(thread_id).await;
        if !self.is_idle_for_queue(thread_id).await {
            return match start {
                QueuedStart::Next(_) => Ok(QueuedOutcome::Waiting),
                QueuedStart::Now(_) => Err(TurnStartError::not_idle()),
            };
        }
        let queue = self
            .settle_stale_starts(thread_id)
            .await
            .map_err(|error| queue_unreadable(&error))?;
        let entry = match &start {
            QueuedStart::Next(expected) => {
                let Some(head) = queue.entries.first() else {
                    return Ok(QueuedOutcome::Changed);
                };
                if &head.id != expected {
                    return Ok(QueuedOutcome::Changed);
                }
                let stopped = self
                    .conversation_index
                    .parent(thread_id)
                    .await
                    .map_err(|error| queue_unreadable(&error))?
                    .stopped;
                if queue.hold.is_some() || stopped {
                    return Ok(QueuedOutcome::Waiting);
                }
                head.clone()
            }
            QueuedStart::Now(id) => match id {
                Some(id) => queue.entry(id).cloned(),
                None => queue.entries.first().cloned(),
            }
            .ok_or_else(|| TurnStartError {
                data: None,
                code: RpcCode::InvalidRequest,
                message: format!(
                    "queued submission not found: {}",
                    id.as_deref().unwrap_or("(empty queue)")
                ),
            })?,
        };
        let request = self.queued_request(thread_id, &entry).await?;
        let id = entry.id.clone();
        let claimed = self
            .update_queue(thread_id, move |queue| {
                let Some(entry) = queue.entries.iter_mut().find(|entry| entry.id == id) else {
                    return Ok(false);
                };
                entry.starting = true;
                Ok(true)
            })
            .await
            .map_err(|error| queue_unreadable(&error))?;
        if !claimed {
            return Ok(QueuedOutcome::Changed);
        }
        let policy = self.conversation_launch_policy(thread_id).await?;
        let started = self
            .start_turn_with_policy(request, TurnOrigin::Queued, policy)
            .await;
        let transferred = started.is_ok() || self.runtime_holds_input(thread_id, &entry.id).await;
        let id = entry.id.clone();
        let settled = self
            .update_queue(thread_id, move |queue| {
                if transferred {
                    queue.entries.retain(|entry| entry.id != id);
                } else if let Some(entry) = queue.entries.iter_mut().find(|entry| entry.id == id) {
                    entry.starting = false;
                }
                if queue.entries.is_empty() {
                    queue.hold = None;
                }
                Ok(())
            })
            .await;
        if let Err(error) = settled {
            warn!(%thread_id, queued = %entry.id, error = %format!("{error:#}"), "Claude queued start was not settled in its queue; the next drain reconciles it");
        }
        started.map(QueuedOutcome::Started)
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

    async fn settle_stale_starts(&self, thread_id: &str) -> Result<Queue> {
        let queue = self.queued_messages(thread_id).await?;
        let stale = queue
            .entries
            .iter()
            .filter(|entry| entry.starting)
            .map(|entry| entry.id.clone())
            .collect::<Vec<_>>();
        if stale.is_empty() {
            return Ok(queue);
        }
        let mut delivered = HashSet::new();
        let history = match (
            session_uuid_from_thread_id(thread_id),
            self.recorded_cwd(thread_id).await?,
        ) {
            (Some(session), Some(cwd)) => self.session_history(&cwd, session),
            _ => None,
        };
        if let Some(history) = history {
            let ids = stale.clone();
            let recorded = tokio::task::spawn_blocking(move || {
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
            .context("Claude queue evidence worker failed")??;
            delivered.extend(recorded);
        }
        self.update_queue(thread_id, move |queue| {
            queue.entries.retain(|entry| !delivered.contains(&entry.id));
            for entry in &mut queue.entries {
                entry.starting = false;
            }
            if queue.entries.is_empty() {
                queue.hold = None;
            }
            Ok(queue.clone())
        })
        .await
    }
}

fn queue_unreadable(error: &anyhow::Error) -> TurnStartError {
    TurnStartError {
        data: None,
        code: RpcCode::InvalidParams,
        message: format!("the Claude queue could not be read or updated: {error:#}"),
    }
}
