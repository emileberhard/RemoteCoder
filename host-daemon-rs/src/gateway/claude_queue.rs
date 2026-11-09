use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Map, Value, json};
use tokio::task::JoinSet;
use tracing::warn;

use super::Gateway;
use super::admission::ConversationBusy;
use crate::providers::claude::queued_messages::QueuedMessage;
use crate::providers::claude::{
    ClaudeSupervisor, QueueAddError, QueuedOutcome, QueuedStart, TurnStartError,
};
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};

const DRAIN_CONCURRENCY: usize = 4;
const SWEEP_INTERVAL: Duration = Duration::from_secs(30);
const ADMISSION_RETRY_DELAY: Duration = Duration::from_millis(500);
const MAX_START_FAILURES: u8 = 3;
const MAX_LIST_PAGE: usize = 100;

fn required<'a>(params: &'a Value, field: &str) -> Result<&'a str, RpcError> {
    params
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| RpcError::new(RpcCode::InvalidParams, format!("{field} is required")))
}

fn submission(entry: &QueuedMessage) -> Value {
    json!({"id": entry.id, "input": entry.input, "clientUserMessageId": entry.id})
}

fn started_turn(turn_id: &str) -> Value {
    json!({"turn": {"id": turn_id, "items": [], "itemsView": "full", "status": "inProgress"}})
}

#[derive(Default)]
struct Drains {
    running: Mutex<HashMap<String, bool>>,
    failures: Mutex<HashMap<String, u8>>,
}

impl Drains {
    fn begin(&self, thread_id: &str) -> bool {
        let mut running = self.running.lock().expect("queue drains poisoned");
        match running.get_mut(thread_id) {
            Some(rerun) => {
                *rerun = true;
                false
            }
            None => {
                running.insert(thread_id.to_owned(), false);
                true
            }
        }
    }

    fn finish(&self, thread_id: &str) -> bool {
        let mut running = self.running.lock().expect("queue drains poisoned");
        if running.get(thread_id).copied().unwrap_or(false) {
            running.insert(thread_id.to_owned(), false);
            return true;
        }
        running.remove(thread_id);
        false
    }

    fn failed(&self, thread_id: &str) -> bool {
        let mut failures = self.failures.lock().expect("queue drains poisoned");
        let count = failures.entry(thread_id.to_owned()).or_default();
        *count += 1;
        if *count >= MAX_START_FAILURES {
            failures.remove(thread_id);
            return true;
        }
        false
    }

    fn succeeded(&self, thread_id: &str) {
        self.failures
            .lock()
            .expect("queue drains poisoned")
            .remove(thread_id);
    }
}

impl Gateway {
    pub(super) async fn claude_queue_add(&self, params: &Value) -> RpcResult {
        let thread = required(params, "threadId")?;
        let id = required(params, "clientUserMessageId")?;
        let input = params
            .get("input")
            .filter(|input| input.is_array())
            .cloned()
            .ok_or_else(|| RpcError::new(RpcCode::InvalidParams, "input is required"))?;
        let agent = self.queue_agent()?;
        if self
            .claude_restart
            .carries_input(thread, id)
            .await
            .map_err(|error| RpcError::queue_change_uncertain(thread, &error))?
        {
            return Err(already_started());
        }
        match agent.queue_add(thread, id, input).await {
            Ok(entry) => Ok(json!({"queuedSubmission": submission(&entry)})),
            Err(QueueAddError::Invalid(message)) => {
                Err(RpcError::new(RpcCode::InvalidParams, message))
            }
            Err(QueueAddError::Started) => Err(already_started()),
            Err(QueueAddError::Conflict) => Err(RpcError::new(
                RpcCode::Conflict,
                "A different message is already queued with this clientUserMessageId",
            )),
            Err(QueueAddError::Failed(error)) => Err(queue_error(thread, error)),
        }
    }

    pub(super) async fn claude_queue_list(&self, params: &Value) -> RpcResult {
        let thread = required(params, "threadId")?;
        let offset = match params.get("cursor").filter(|cursor| !cursor.is_null()) {
            Some(cursor) => cursor
                .as_str()
                .and_then(|cursor| cursor.parse::<usize>().ok())
                .ok_or_else(|| {
                    RpcError::new(RpcCode::InvalidRequest, "invalid queue pagination cursor")
                })?,
            None => 0,
        };
        let limit = params
            .get("limit")
            .and_then(Value::as_u64)
            .map_or(MAX_LIST_PAGE, |limit| {
                (limit as usize).clamp(1, MAX_LIST_PAGE)
            });
        let queue = self
            .queue_agent()?
            .queued_messages(thread)
            .await
            .map_err(|error| RpcError::new(RpcCode::Internal, format!("{error:#}")))?;
        let data = queue
            .entries
            .iter()
            .skip(offset)
            .take(limit)
            .map(submission)
            .collect::<Vec<_>>();
        let next_cursor =
            (offset + data.len() < queue.entries.len()).then(|| (offset + data.len()).to_string());
        let mut response = json!({"data": data, "nextCursor": next_cursor});
        if let Some(hold) = queue.hold {
            response["hold"] = json!(hold);
        }
        Ok(response)
    }

    pub(super) async fn claude_queue_delete(&self, params: &Value) -> RpcResult {
        let thread = required(params, "threadId")?;
        let id = required(params, "queuedSubmissionId")?;
        let deleted = self
            .queue_agent()?
            .queue_delete(thread, id)
            .await
            .map_err(|error| queue_error(thread, error))?;
        Ok(json!({"deleted": deleted}))
    }

    pub(super) async fn claude_queue_start(&self, client_id: u64, params: &Value) -> RpcResult {
        let thread = required(params, "threadId")?;
        let requested = params
            .get("queuedSubmissionId")
            .and_then(Value::as_str)
            .map(str::to_owned);
        let agent = self.queue_agent()?;
        let queue = agent
            .queued_messages(thread)
            .await
            .map_err(|error| RpcError::new(RpcCode::Internal, format!("{error:#}")))?;
        let entry = match &requested {
            Some(id) => queue.entry(id),
            None => queue.entries.first(),
        }
        .cloned();
        let Some(entry) = entry else {
            return Err(RpcError::new(
                RpcCode::InvalidRequest,
                format!(
                    "queued submission not found: {}",
                    requested.as_deref().unwrap_or("(empty queue)")
                ),
            ));
        };
        let object = self.queued_turn_start(&agent, thread, &entry).await;
        match self
            .start_claude_queued(
                &agent,
                client_id,
                thread,
                QueuedStart::Now(Some(entry.id.clone())),
                &object,
            )
            .await
        {
            Ok(QueuedOutcome::Started(turn_id)) => Ok(started_turn(&turn_id)),
            Ok(QueuedOutcome::Waiting) => Err(RpcError::new(
                RpcCode::InvalidRequest,
                "thread already has an active or pending turn",
            )),
            Ok(QueuedOutcome::Changed) => Err(RpcError::new(
                RpcCode::InvalidRequest,
                format!("queued submission not found: {}", entry.id),
            )),
            Err(error) => Err(RpcError::from(error)),
        }
    }

    fn queue_agent(&self) -> Result<Arc<ClaudeSupervisor>, RpcError> {
        self.claude_agent()
            .ok_or_else(|| RpcError::new(RpcCode::Internal, "Claude agent is not running"))
    }

    async fn queued_turn_start(
        &self,
        agent: &ClaudeSupervisor,
        thread: &str,
        entry: &QueuedMessage,
    ) -> Map<String, Value> {
        let mut params = json!({
            "threadId": thread,
            "input": entry.input,
            "clientUserMessageId": entry.id,
        });
        if let Ok(Some(cwd)) = agent.recorded_cwd(thread).await {
            params["cwd"] = json!(cwd);
        }
        Map::from_iter([
            (
                "id".to_owned(),
                json!(format!("claude-queue:{thread}:{}", entry.id)),
            ),
            ("method".to_owned(), json!("turn/start")),
            ("params".to_owned(), params),
        ])
    }

    async fn start_claude_queued(
        &self,
        agent: &Arc<ClaudeSupervisor>,
        client_id: u64,
        thread: &str,
        start: QueuedStart,
        object: &Map<String, Value>,
    ) -> Result<QueuedOutcome, TurnStartError> {
        let id = object.get("id").cloned().unwrap_or(Value::Null);
        if let Err(error) = self.capture_client_request_locked(client_id, object).await {
            warn!(%thread, error = %format!("{error:#}"), "queued Claude start context was not recorded");
        }
        let outcome = agent.start_queued(thread, start).await;
        let response = match &outcome {
            Ok(QueuedOutcome::Started(turn_id)) => {
                json!({"id": id, "result": started_turn(turn_id)})
            }
            _ => {
                json!({"id": id, "error": {"code": -32600, "message": "queued message not started"}})
            }
        };
        if let Err(error) = self.capture_turn_start_response(client_id, &response).await {
            warn!(%thread, error = %format!("{error:#}"), "queued Claude start context was not settled");
        }
        outcome
    }

    pub(super) async fn claude_queue_loop(self: Arc<Self>, agent: Arc<ClaudeSupervisor>) {
        for thread in agent.queued_threads() {
            agent.request_queue_drain(&thread);
        }
        let drains = Arc::new(Drains::default());
        let permits = Arc::new(tokio::sync::Semaphore::new(DRAIN_CONCURRENCY));
        let mut tasks = JoinSet::new();
        let mut sweep = tokio::time::interval(SWEEP_INTERVAL);
        sweep.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            let threads = tokio::select! {
                threads = agent.queue_drain_requests() => threads,
                _ = sweep.tick() => agent.queued_threads(),
                Some(_) = tasks.join_next(), if !tasks.is_empty() => continue,
            };
            for thread in threads {
                if !drains.begin(&thread) {
                    continue;
                }
                let (gateway, agent, drains, permits) = (
                    Arc::clone(&self),
                    Arc::clone(&agent),
                    Arc::clone(&drains),
                    Arc::clone(&permits),
                );
                tasks.spawn(async move {
                    loop {
                        let Ok(_permit) = permits.acquire().await else {
                            return;
                        };
                        gateway.drain_claude_queue(&agent, &thread, &drains).await;
                        if !drains.finish(&thread) {
                            return;
                        }
                    }
                });
            }
        }
    }

    async fn drain_claude_queue(
        &self,
        agent: &Arc<ClaudeSupervisor>,
        thread: &str,
        drains: &Drains,
    ) {
        loop {
            if self.is_draining()
                || !matches!(self.claude_restart.has_pending_for(thread).await, Ok(false))
            {
                return;
            }
            let head = match agent.queue_ready(thread).await {
                Ok(Some(head)) => head,
                Ok(None) => return,
                Err(error) => {
                    warn!(%thread, error = %format!("{error:#}"), "queued Claude messages are unreadable");
                    return;
                }
            };
            let object = self.queued_turn_start(agent, thread, &head).await;
            let _admission = loop {
                match self.admit_request(Some("turn/start"), &object) {
                    Ok(admission) => break admission,
                    Err(error) if error.is::<ConversationBusy>() => {
                        tokio::time::sleep(ADMISSION_RETRY_DELAY).await;
                    }
                    Err(error) => {
                        warn!(%thread, error = %format!("{error:#}"), "queued Claude message waits for admission");
                        return;
                    }
                }
            };
            if let Err(error) = self.validate_dispatch("turn/start", &object).await {
                self.journal.runtime(
                    "queued_start_deferred",
                    json!({"provider":"claude","threadId":thread,"error":error.message}),
                );
                return;
            }
            match self
                .start_claude_queued(
                    agent,
                    0,
                    thread,
                    QueuedStart::Next(head.id.clone()),
                    &object,
                )
                .await
            {
                Ok(QueuedOutcome::Started(turn_id)) => {
                    drains.succeeded(thread);
                    self.journal.runtime(
                        "queued_start",
                        json!({"provider":"claude","threadId":thread,"turnId":turn_id,"clientUserMessageId":head.id}),
                    );
                    return;
                }
                Ok(QueuedOutcome::Waiting) => return,
                Ok(QueuedOutcome::Changed) => {}
                Err(error) if error.code == RpcCode::ServerBusy => return,
                Err(error) if error.holds_queue() => {
                    drains.succeeded(thread);
                    self.hold_claude_queue(agent, thread, &error.message).await;
                    return;
                }
                Err(error) => {
                    self.queued_start_failed(agent, thread, drains, &error.message)
                        .await;
                    return;
                }
            }
        }
    }

    async fn queued_start_failed(
        &self,
        agent: &ClaudeSupervisor,
        thread: &str,
        drains: &Drains,
        message: &str,
    ) {
        self.journal.runtime(
            "queued_start_failed",
            json!({"provider":"claude","threadId":thread,"error":message}),
        );
        if drains.failed(thread) {
            self.hold_claude_queue(agent, thread, message).await;
        }
    }

    async fn hold_claude_queue(&self, agent: &ClaudeSupervisor, thread: &str, message: &str) {
        match agent.hold_queue(thread, message).await {
            Ok(true) => {
                self.journal.runtime(
                    "queued_held",
                    json!({"provider":"claude","threadId":thread,"error":message}),
                );
                if let Err(error) = self
                    .send_user_alert(
                        "Queued Claude message paused",
                        &format!("The next queued message could not start: {message}"),
                        Some(thread),
                    )
                    .await
                {
                    warn!(%thread, %error, "queued Claude hold alert was not delivered");
                }
            }
            Ok(false) => {}
            Err(error) => {
                warn!(%thread, error = %format!("{error:#}"), "queued Claude messages could not be held");
            }
        }
    }
}

fn already_started() -> RpcError {
    RpcError::new(
        RpcCode::Conflict,
        "This message already started; it cannot be queued again",
    )
}

fn queue_error(thread: &str, error: anyhow::Error) -> RpcError {
    match error.downcast::<crate::providers::claude::CapacityExceeded>() {
        Ok(capacity) => capacity.into(),
        Err(error) => RpcError::queue_change_uncertain(thread, &error),
    }
}
