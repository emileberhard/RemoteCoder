use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Map, Value, json};
use tokio::task::JoinSet;
use tracing::warn;

use super::Gateway;
use crate::providers::claude::queued_messages::{QueueWriteUncertain, QueuedMessage};
use crate::providers::claude::{ClaudeSupervisor, QueueAddError, QueuedOutcome};
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};

const DRAIN_CONCURRENCY: usize = 4;
const SWEEP_INTERVAL: Duration = Duration::from_secs(30);
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
            .map_err(|error| queue_unread(&error))?
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
        self.capture_queued_start(
            client_id,
            &object,
            Box::pin(agent.start_queued_now(thread, &entry.id)),
            |started| started.as_ref().ok().cloned(),
        )
        .await
        .map(|turn_id| started_turn(&turn_id))
        .map_err(RpcError::from)
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

    async fn capture_queued_start<T>(
        &self,
        client_id: u64,
        object: &Map<String, Value>,
        start: impl Future<Output = T>,
        started: impl FnOnce(&T) -> Option<String>,
    ) -> T {
        let id = object.get("id").cloned().unwrap_or(Value::Null);
        let thread = object
            .get("params")
            .and_then(|params| params.get("threadId"))
            .cloned()
            .unwrap_or(Value::Null);
        if let Err(error) = self.capture_client_request_locked(client_id, object).await {
            warn!(%thread, error = %format!("{error:#}"), "queued Claude start context was not recorded");
        }
        let outcome = start.await;
        let response = match started(&outcome) {
            Some(turn_id) => json!({"id": id, "result": started_turn(&turn_id)}),
            None => {
                json!({"id": id, "error": {"code": -32600, "message": "queued message not started"}})
            }
        };
        if let Err(error) = self.capture_turn_start_response(client_id, &response).await {
            warn!(%thread, error = %format!("{error:#}"), "queued Claude start context was not settled");
        }
        outcome
    }

    pub(super) async fn claude_queue_loop(self: Arc<Self>, agent: Arc<ClaudeSupervisor>) {
        let permits = Arc::new(tokio::sync::Semaphore::new(DRAIN_CONCURRENCY));
        let mut tasks = JoinSet::new();
        let mut sweep = tokio::time::interval(SWEEP_INTERVAL);
        sweep.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                threads = agent.queue_drain_requests() => {
                    for thread in threads {
                        let (gateway, agent, permits) =
                            (Arc::clone(&self), Arc::clone(&agent), Arc::clone(&permits));
                        tasks.spawn(async move {
                            loop {
                                let Ok(_permit) = permits.acquire().await else {
                                    return;
                                };
                                gateway.drain_claude_queue(&agent, &thread).await;
                                if !agent.finish_queue_drain(&thread) {
                                    return;
                                }
                            }
                        });
                    }
                }
                _ = sweep.tick() => agent.sweep_queue_drains(),
                Some(_) = tasks.join_next(), if !tasks.is_empty() => {}
            }
        }
    }

    async fn drain_claude_queue(&self, agent: &Arc<ClaudeSupervisor>, thread: &str) {
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
            let _admission = match self.admit_request(Some("turn/start"), &object) {
                Ok(admission) => admission,
                Err(error) => {
                    self.defer_claude_queue(agent, thread, &format!("{error:#}"));
                    return;
                }
            };
            if let Err(error) = self.validate_dispatch("turn/start", &object).await {
                self.defer_claude_queue(agent, thread, &error.message);
                return;
            }
            let outcome = self
                .capture_queued_start(
                    0,
                    &object,
                    agent.start_next_queued(thread, &head.id),
                    |outcome| match outcome {
                        QueuedOutcome::Started(turn_id) => Some(turn_id.clone()),
                        _ => None,
                    },
                )
                .await;
            match outcome {
                QueuedOutcome::Started(turn_id) => {
                    self.journal.runtime(
                        "queued_start",
                        json!({"provider":"claude","threadId":thread,"turnId":turn_id,"clientUserMessageId":head.id}),
                    );
                    return;
                }
                QueuedOutcome::Waiting => return,
                QueuedOutcome::Changed => {}
                QueuedOutcome::Failed { error, held } => {
                    self.journal.runtime(
                        "queued_start_failed",
                        json!({"provider":"claude","threadId":thread,"clientUserMessageId":head.id,"error":error.message}),
                    );
                    if let Some(message) = held {
                        self.alert_claude_queue_hold(thread, &error.message, &message)
                            .await;
                    }
                    return;
                }
            }
        }
    }

    fn defer_claude_queue(&self, agent: &ClaudeSupervisor, thread: &str, reason: &str) {
        if agent.defer_queue(thread, reason) {
            self.journal.runtime(
                "queued_start_deferred",
                json!({"provider":"claude","threadId":thread,"error":reason}),
            );
        }
    }

    async fn alert_claude_queue_hold(&self, thread: &str, error: &str, message: &str) {
        self.journal.runtime(
            "queued_held",
            json!({"provider":"claude","threadId":thread,"error":error,"hold":message}),
        );
        if let Err(error) = self
            .send_user_alert("Queued Claude message paused", message, Some(thread))
            .await
        {
            warn!(%thread, %error, "queued Claude hold alert was not delivered");
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
    if error.is::<QueueWriteUncertain>() {
        return RpcError::queue_change_uncertain(thread, &error);
    }
    match error.downcast::<crate::providers::claude::CapacityExceeded>() {
        Ok(capacity) => capacity.into(),
        Err(error) => queue_unread(&error),
    }
}

fn queue_unread(error: &anyhow::Error) -> RpcError {
    RpcError::new(
        RpcCode::Internal,
        format!("The queue could not be read, so nothing changed: {error:#}"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::mcp::McpTokens;
    use crate::observability::journal::Journal;
    use crate::providers::claude::ClaudeNotification;
    use crate::test_support::TestGateway;
    use tokio::sync::mpsc;

    const THREAD: &str = "claude_11111111-2222-4333-8444-555555555555";

    fn claude_gateway() -> (TestGateway, mpsc::Receiver<ClaudeNotification>) {
        let gateway = TestGateway::new();
        let (sender, events) = mpsc::channel(64);
        gateway.set_claude_agent(ClaudeSupervisor::new(
            gateway.claude_settings.clone(),
            sender,
            Journal::disabled(),
            McpTokens::new(),
        ));
        (gateway, events)
    }

    fn add(id: &str) -> Value {
        json!({"threadId": THREAD, "clientUserMessageId": id,
            "input": [{"type": "text", "text": format!("queued {id}")}]})
    }

    #[tokio::test]
    async fn a_busy_conversation_returns_its_drain_instead_of_retrying_in_place() {
        let (gateway, _events) = claude_gateway();
        let agent = gateway.claude_agent().unwrap();
        agent
            .queue_add(THREAD, "m", add("m")["input"].clone())
            .await
            .unwrap();
        let _compaction = gateway.admission.admit_compaction(THREAD).unwrap();
        tokio::time::timeout(
            Duration::from_secs(5),
            gateway.drain_claude_queue(&agent, THREAD),
        )
        .await
        .expect("a busy conversation releases its drain permit");
        assert!(
            !agent.defer_queue(
                THREAD,
                "This conversation has a pending command; retry after it finishes"
            ),
            "the drain reached admission and recorded why it deferred"
        );
        assert_eq!(
            agent.queued_messages(THREAD).await.unwrap().entries.len(),
            1
        );
    }

    #[tokio::test]
    async fn an_unreadable_queue_refuses_an_add_definitely() {
        let (gateway, _events) = claude_gateway();
        let file = crate::providers::claude::queued_messages::path(
            &gateway.claude_settings.claude_home,
            THREAD,
        );
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(
            &file,
            json!({"version": 2, "threadId": THREAD, "entries": []}).to_string(),
        )
        .unwrap();
        let error = gateway.claude_queue_add(&add("m")).await.unwrap_err();
        assert_eq!(error.code, RpcCode::Internal, "{error:?}");
        assert_eq!(
            error.kind(),
            None,
            "nothing was written, so nothing is uncertain"
        );
        let error = gateway
            .claude_queue_delete(&json!({"threadId": THREAD, "queuedSubmissionId": "m"}))
            .await
            .unwrap_err();
        assert_eq!(error.code, RpcCode::Internal, "{error:?}");
        assert_eq!(error.kind(), None);
    }
}
