use super::{ActiveTasksLiveActivitySnapshot, ApnsSend, ENDED_TURN_LOOKUP_PAGE_SIZE, Gateway};
use crate::gateway::turn_state::{
    active_tasks_live_activity_snapshot, complete_tracked_turn, ended_turn_status,
    is_other_turn_terminal_on_thread, is_terminal_turn_for_pending, resumed_turn_terminal_status,
    turn_carries_user_message, user_message_client_ids,
};
use crate::notifications::history::NotificationOrigin;
use crate::providers::codex::daemon::CodexWebSocket;
use crate::time::unix_seconds;
use crate::turns::{ActiveTurn, PendingTurnStart, TurnKey, is_durable_codex_thread};
use anyhow::{Context, Result, anyhow, ensure};
use futures_util::{FutureExt, SinkExt, StreamExt};
use serde_json::Value;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::oneshot;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::Message as UpstreamMessage;
use tracing::{info, warn};

const QUEUED_SUCCESSOR_WAIT: Duration = Duration::from_secs(30);

enum Observed {
    Turn(ActiveTurn),
    QueuedSuccessor { deadline: Instant },
}

struct ThreadObservation {
    thread_id: String,
    observed: Observed,
}

impl ThreadObservation {
    fn turn(turn: ActiveTurn) -> Self {
        Self {
            thread_id: turn.thread_id.clone(),
            observed: Observed::Turn(turn),
        }
    }

    fn queued_successor(thread_id: String) -> Self {
        Self {
            thread_id,
            observed: Observed::QueuedSuccessor {
                deadline: Instant::now() + QUEUED_SUCCESSOR_WAIT,
            },
        }
    }
}

impl Gateway {
    pub(super) async fn spawn_observers_for_client(self: &Arc<Self>, client_id: u64) {
        let (turns, pending, queues) = {
            let core = self.core.lock().await;
            (
                core.turns
                    .active()
                    .filter(|turn| {
                        turn.owner_client_id == client_id
                            && is_durable_codex_thread(&turn.thread_id)
                    })
                    .cloned()
                    .collect::<Vec<_>>(),
                core.turns
                    .pending()
                    .filter(|(_, pending)| {
                        pending.context.owner_client_id == client_id
                            && is_durable_codex_thread(&pending.thread_id)
                    })
                    .map(|(key, pending)| (key.clone(), pending.clone()))
                    .collect::<Vec<_>>(),
                core.turns.observable_queue_threads(Some(client_id)),
            )
        };

        for (key, pending) in pending {
            self.spawn_pending_observer(key, pending, client_id).await;
        }
        for turn in turns {
            self.spawn_thread_observer(ThreadObservation::turn(turn), client_id)
                .await;
        }
        for thread_id in queues {
            self.spawn_thread_observer(ThreadObservation::queued_successor(thread_id), client_id)
                .await;
        }
    }

    pub(super) async fn spawn_persisted_observers(self: &Arc<Self>) {
        if self.is_draining() {
            return;
        }
        let (turns, pending, queues) = {
            let core = self.core.lock().await;
            (
                core.turns
                    .active()
                    .filter(|turn| is_durable_codex_thread(&turn.thread_id))
                    .cloned()
                    .collect::<Vec<_>>(),
                core.turns
                    .pending()
                    .filter(|(_, pending)| is_durable_codex_thread(&pending.thread_id))
                    .map(|(key, pending)| (key.clone(), pending.clone()))
                    .collect::<Vec<_>>(),
                core.turns.observable_queue_threads(None),
            )
        };
        for (key, pending) in pending {
            if self.is_draining() {
                return;
            }
            let client_id = pending.context.owner_client_id;
            self.spawn_pending_observer(key, pending, client_id).await;
        }
        for turn in turns {
            if self.is_draining() {
                return;
            }
            let client_id = turn.owner_client_id;
            self.spawn_thread_observer(ThreadObservation::turn(turn), client_id)
                .await;
        }
        for thread_id in queues {
            if self.is_draining() {
                return;
            }
            self.spawn_thread_observer(ThreadObservation::queued_successor(thread_id), 0)
                .await;
        }
    }

    pub(super) fn schedule_persisted_observer_scan(self: &Arc<Self>) {
        if self.is_draining() {
            return;
        }
        let gateway = Arc::clone(self);
        tokio::spawn(
            async move {
                if !gateway.is_draining() {
                    gateway.spawn_persisted_observers().await;
                }
            }
            .boxed(),
        );
    }

    async fn spawn_thread_observer(
        self: &Arc<Self>,
        observation: ThreadObservation,
        client_id: u64,
    ) {
        let thread_id = observation.thread_id.clone();
        let (start_tx, start_rx) = oneshot::channel();
        let mut tasks = self.observer_tasks.lock().await;
        tasks.retain(|_, task| !task.is_finished());
        if tasks.contains_key(&thread_id) {
            return;
        }
        let gateway = Arc::clone(self);
        let task_thread_id = thread_id.clone();
        let task = tokio::spawn(async move {
            let _ = start_rx.await;
            gateway.observe_thread(observation).await;
            gateway.observer_tasks.lock().await.remove(&task_thread_id);
            gateway.schedule_persisted_observer_scan();
        });
        tasks.insert(thread_id.clone(), task);
        drop(tasks);
        let _ = start_tx.send(());
        info!(client_id, %thread_id, "Codex completion observer started");
    }

    async fn spawn_pending_observer(
        self: &Arc<Self>,
        key: String,
        pending: PendingTurnStart,
        client_id: u64,
    ) {
        let thread_id = pending.thread_id.clone();
        let (start_tx, start_rx) = oneshot::channel();
        let mut tasks = self.observer_tasks.lock().await;
        tasks.retain(|_, task| !task.is_finished());
        if tasks.contains_key(&thread_id) {
            return;
        }
        let gateway = Arc::clone(self);
        let task_thread_id = thread_id.clone();
        let task = tokio::spawn(async move {
            let _ = start_rx.await;
            let retry = match gateway.reconcile_pending_turn(&key, &pending).await {
                Ok(Some(turn)) => {
                    gateway.observe_thread(ThreadObservation::turn(turn)).await;
                    false
                }
                Ok(None) => false,
                Err(error) => {
                    warn!(
                        thread_id = pending.thread_id,
                        %error,
                        "failed to reconcile pending turn"
                    );
                    true
                }
            };
            if retry {
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
            gateway.observer_tasks.lock().await.remove(&task_thread_id);
            gateway.schedule_persisted_observer_scan();
        });
        tasks.insert(thread_id.clone(), task);
        drop(tasks);
        let _ = start_tx.send(());
        info!(client_id, %thread_id, "pending Codex turn reconciliation started");
    }

    pub(super) async fn reconcile_pending_turn(
        self: &Arc<Self>,
        key: &str,
        pending: &PendingTurnStart,
    ) -> Result<Option<ActiveTurn>> {
        let websocket = self.codex.connect_ws().await?;
        let (mut sink, mut stream) = websocket.split();
        self.initialize_codex_connection(&mut sink, &mut stream)
            .await?;
        let resume_id = format!("pending:resume:{key}");
        let mut params = serde_json::json!({ "threadId": pending.thread_id });
        self.admit_native("thread/resume", &mut params)
            .await
            .map_err(|error| super::external_providers::admission_failure(&error))?;
        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "id": resume_id,
            "method": "thread/resume",
            "params": params,
        });
        sink.send(UpstreamMessage::Text(serde_json::to_string(&request)?))
            .await
            .context("pending thread/resume send failed")?;

        let thread = loop {
            let frame = tokio::time::timeout(Duration::from_secs(10), stream.next())
                .await
                .context("pending thread/resume timed out")?
                .context("pending Codex stream ended")?
                .context("pending Codex receive failed")?;
            let UpstreamMessage::Text(raw) = frame else {
                continue;
            };
            let message: Value =
                serde_json::from_str(&raw).context("pending Codex response was invalid JSON")?;
            if message.get("id").and_then(Value::as_str) != Some(&resume_id) {
                continue;
            }
            if message.get("error").is_some() {
                self.remove_pending_turn_if_matches(key, pending).await?;
                self.unsubscribe_observer(&mut sink, &pending.thread_id)
                    .await?;
                return Ok(None);
            }
            break message
                .pointer("/result/thread")
                .and_then(Value::as_object)
                .cloned()
                .context("pending thread/resume returned no thread")?;
        };

        let status = thread
            .get("status")
            .and_then(Value::as_object)
            .and_then(|status| status.get("type"))
            .and_then(Value::as_str)
            .context("pending thread/resume omitted thread status")?;
        let turns = thread
            .get("turns")
            .and_then(Value::as_array)
            .context("pending thread/resume omitted turns")?;
        ensure!(
            matches!(status, "active" | "idle"),
            "pending thread/resume returned unresolved thread status {status}"
        );
        let active_turn_id = turns.iter().rev().find_map(|turn| {
            if turn.get("status").and_then(Value::as_str) == Some("inProgress") {
                turn.get("id").and_then(Value::as_str)
            } else {
                None
            }
        });
        if status == "idle" {
            if let Some(turn) = turns
                .iter()
                .rev()
                .find(|turn| is_terminal_turn_for_pending(turn, pending))
            {
                self.record_recovered_terminal_turn(key, pending, turn)
                    .await?;
            } else {
                self.remove_pending_turn_if_matches(key, pending).await?;
            }
            self.unsubscribe_observer(&mut sink, &pending.thread_id)
                .await?;
            return Ok(None);
        }
        let turn_id = active_turn_id
            .context("active thread exposed no in-progress turn")?
            .to_string();
        if let Some(client_user_message_id) = &pending.client_user_message_id
            && let Some(running) = turns
                .iter()
                .rev()
                .find(|turn| turn.get("id").and_then(Value::as_str) == Some(turn_id.as_str()))
            && !turn_carries_user_message(running, client_user_message_id)
        {
            let turn = self.adopt_running_turn(&pending.thread_id, running).await?;
            self.unsubscribe_observer(&mut sink, &pending.thread_id)
                .await?;
            return Ok(turn);
        }
        if pending.previous_turn_id.as_deref() == Some(turn_id.as_str()) {
            self.remove_pending_turn_if_matches(key, pending).await?;
            let existing = self
                .core
                .lock()
                .await
                .turns
                .active_turn(&TurnKey::new(&pending.thread_id, &turn_id))
                .cloned();
            self.unsubscribe_observer(&mut sink, &pending.thread_id)
                .await?;
            return Ok(existing);
        }
        let now = unix_seconds();
        let turn = {
            let mut core = self.core.lock().await;
            let Some(recovered) = core.turns.take_pending_matching(key, pending) else {
                return Ok(core.turns.active_on_thread(&pending.thread_id).cloned());
            };
            let turn_key = TurnKey::new(&recovered.thread_id, &turn_id);
            core.turns
                .start_from_pending(recovered, &turn_id, now, Some(now));
            core.turns.active_turn(&turn_key).cloned()
        };
        self.commit_turn_state().await?;
        self.unsubscribe_observer(&mut sink, &pending.thread_id)
            .await?;
        Ok(turn)
    }

    pub(super) async fn record_recovered_terminal_turn(
        &self,
        key: &str,
        pending: &PendingTurnStart,
        turn: &Value,
    ) -> Result<()> {
        let turn_id = turn
            .get("id")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .context("recovered terminal turn has no id")?;
        let thread_id = {
            let mut core = self.core.lock().await;
            let Some(recovered) = core.turns.take_pending_matching(key, pending) else {
                return Ok(());
            };
            let thread_id = recovered.thread_id.clone();
            core.turns.start_from_pending(
                recovered,
                &turn_id,
                unix_seconds(),
                turn.get("startedAt").and_then(Value::as_f64),
            );
            thread_id
        };
        self.commit_turn_state().await?;

        if let Some(items) = turn.get("items").and_then(Value::as_array) {
            for item in items {
                self.record_agent_notification(
                    &serde_json::to_string(&serde_json::json!({
                        "method": "item/completed",
                        "params": {
                            "threadId": thread_id,
                            "turnId": turn_id,
                            "item": item,
                        }
                    }))?,
                    NotificationOrigin::Gateway,
                )
                .await;
            }
        }
        self.record_agent_notification(
            &serde_json::to_string(&serde_json::json!({
                "method": "turn/completed",
                "params": {
                    "threadId": thread_id,
                    "turn": turn,
                }
            }))?,
            NotificationOrigin::Gateway,
        )
        .await;
        Ok(())
    }

    pub(super) async fn remove_pending_turn_if_matches(
        &self,
        key: &str,
        expected: &PendingTurnStart,
    ) -> Result<bool> {
        let removed = {
            let mut core = self.core.lock().await;
            core.turns.take_pending_matching(key, expected).is_some()
        };
        if removed {
            self.commit_turn_state().await?;
        }
        Ok(removed)
    }

    async fn turn_is_active(&self, turn: &ActiveTurn) -> bool {
        self.core.lock().await.turns.is_active(&turn.key())
    }

    async fn turn_was_recovered_after_restart(&self, turn: &ActiveTurn) -> bool {
        self.core
            .lock()
            .await
            .recovered_turn_keys
            .contains(&turn.key())
    }

    async fn observe_thread(self: &Arc<Self>, mut observation: ThreadObservation) {
        let mut backoff = Duration::from_millis(250);
        while self.continues_observing(&mut observation).await {
            match self.observe_thread_once(&mut observation).await {
                Ok(()) => break,
                Err(error) => {
                    warn!(
                        thread_id = observation.thread_id,
                        %error,
                        "Codex completion observer disconnected"
                    );
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(Duration::from_secs(5));
                }
            }
        }
    }

    async fn awaits_queued_successor(&self, thread_id: &str) -> bool {
        !self.is_draining()
            && self
                .core
                .lock()
                .await
                .turns
                .awaits_queued_successor(thread_id)
    }

    async fn continues_observing(&self, observation: &mut ThreadObservation) -> bool {
        let deadline = match &observation.observed {
            Observed::Turn(turn) if self.turn_is_active(turn).await => return true,
            Observed::Turn(_) => Instant::now() + QUEUED_SUCCESSOR_WAIT,
            Observed::QueuedSuccessor { deadline } => *deadline,
        };
        if !self.awaits_queued_successor(&observation.thread_id).await {
            return false;
        }
        if Instant::now() >= deadline {
            self.settle_unstarted_queue(&observation.thread_id).await;
            return false;
        }
        observation.observed = Observed::QueuedSuccessor { deadline };
        true
    }

    async fn adopt_running_turn(
        &self,
        thread_id: &str,
        turn: &Value,
    ) -> Result<Option<ActiveTurn>> {
        let turn_id = turn
            .get("id")
            .and_then(Value::as_str)
            .context("running turn has no id")?;
        let key = TurnKey::new(thread_id, turn_id);
        let (adopted, live_activity) = {
            let mut core = self.core.lock().await;
            if !core.turns.is_active(&key) {
                core.turns.note_started(&key, unix_seconds());
            }
            for client_user_message_id in user_message_client_ids(turn) {
                core.turns.note_user_message(&key, client_user_message_id);
            }
            (
                core.turns.active_turn(&key).cloned(),
                active_tasks_live_activity_snapshot(&core),
            )
        };
        self.publish_turn_completion(None, live_activity).await;
        Ok(adopted)
    }

    async fn observe_thread_once(
        self: &Arc<Self>,
        observation: &mut ThreadObservation,
    ) -> Result<()> {
        let thread_id = observation.thread_id.clone();
        let websocket = self.codex.connect_ws().await?;
        let (mut sink, mut stream) = websocket.split();
        self.initialize_codex_connection(&mut sink, &mut stream)
            .await?;

        let notification_origin = NotificationOrigin::Observer {
            opened_after: self.notification_floor().await,
        };
        let resume_id = format!("observer:resume:{thread_id}");
        let mut params = serde_json::json!({ "threadId": thread_id });
        self.admit_native("thread/resume", &mut params)
            .await
            .map_err(|error| super::external_providers::admission_failure(&error))?;
        let resume = serde_json::json!({
            "jsonrpc": "2.0",
            "id": resume_id,
            "method": "thread/resume",
            "params": params
        });
        sink.send(UpstreamMessage::Text(serde_json::to_string(&resume)?))
            .await
            .context("observer thread/resume send failed")?;

        let mut tool_replies = tokio::task::JoinSet::new();
        loop {
            if !self.continues_observing(observation).await {
                self.unsubscribe_observer(&mut sink, &thread_id).await?;
                return Ok(());
            }
            let frame = tokio::select! {
                reply = tool_replies.join_next(), if !tool_replies.is_empty() => {
                    let response = reply.expect("observer tool reply").context("observer tool task failed")??;
                    sink.send(UpstreamMessage::Text(response))
                        .await.context("observer tool response send failed")?;
                    continue;
                },
                frame = tokio::time::timeout(Duration::from_secs(5), stream.next()) => match frame {
                    Err(_) => continue,
                    Ok(Some(frame)) => frame,
                    Ok(None) => return Err(anyhow!("observer Codex stream ended")),
                },
            };
            let frame = frame.context("observer Codex receive failed")?;
            let UpstreamMessage::Text(raw) = frame else {
                if matches!(frame, UpstreamMessage::Close(_)) {
                    return Err(anyhow!("observer Codex connection closed"));
                }
                continue;
            };
            let Ok(message) = serde_json::from_str::<Value>(&raw) else {
                continue;
            };

            if message.get("id").and_then(Value::as_str) == Some(&resume_id) {
                if let Some(error) = message.get("error") {
                    return Err(anyhow!("observer thread/resume failed: {error}"));
                }
                let status = message
                    .pointer("/result/thread/status/type")
                    .and_then(Value::as_str);
                let mut running = message
                    .pointer("/result/thread/turns")
                    .and_then(Value::as_array)
                    .filter(|_| status == Some("active"))
                    .and_then(|turns| {
                        turns
                            .iter()
                            .rev()
                            .find(|turn| turn["status"] == "inProgress")
                    });
                if let Observed::Turn(turn) = &observation.observed {
                    let terminal = resumed_turn_terminal_status(&message, &turn.turn_id);
                    if running.is_some_and(|running| {
                        running["id"].as_str() == Some(turn.turn_id.as_str())
                    }) {
                        running = None;
                    } else if terminal.is_some() || running.is_some() || status != Some("active") {
                        if terminal.is_none() && self.turn_was_recovered_after_restart(turn).await {
                            return Err(anyhow!(
                                "recovered turn is temporarily inactive during restart handoff"
                            ));
                        }
                        self.finish_observed_turn(turn, terminal.unwrap_or("unknown"))
                            .await;
                    }
                }
                if let Some(running) = running
                    && let Some(turn) = self.adopt_running_turn(&thread_id, running).await?
                {
                    observation.observed = Observed::Turn(turn);
                }
                continue;
            }

            if let Some(call) = crate::agents::tools::codex_tool_call(&message) {
                ensure!(
                    tool_replies.len() < 64,
                    "observer tool response capacity exceeded"
                );
                let gateway = Arc::clone(self);
                tool_replies.spawn(async move { gateway.codex_tool_response(call).await });
                continue;
            }

            if message.get("method").is_some() {
                self.record_agent_notification(&raw, notification_origin)
                    .await;
            }
            if let Some(started) = started_turn_on_thread(&message, &thread_id) {
                let turn = self
                    .core
                    .lock()
                    .await
                    .turns
                    .active_turn(&TurnKey::new(&thread_id, started))
                    .cloned();
                if let Some(turn) = turn {
                    observation.observed = Observed::Turn(turn);
                }
                continue;
            }
            if let Observed::Turn(turn) = &observation.observed
                && is_other_turn_terminal_on_thread(&message, turn)
            {
                if self.turn_was_recovered_after_restart(turn).await {
                    return Err(anyhow!(
                        "observed another terminal turn while restart recovery remains active"
                    ));
                }
                self.finish_observed_turn(turn, "unknown").await;
            }
        }
    }

    async fn finish_observed_turn(&self, turn: &ActiveTurn, status: &str) {
        let hold_queue = !self.is_draining();
        let (send, live_activity) = {
            let mut core = self.core.lock().await;
            core.recovered_turn_keys.remove(&turn.key());
            complete_tracked_turn(&mut core, turn, status, hold_queue)
        };
        self.publish_turn_completion(send, live_activity).await;
    }

    pub(super) async fn finish_turns_the_app_server_ended(
        &self,
        thread_id: &str,
        tracked: Vec<ActiveTurn>,
    ) -> Result<()> {
        let response = self
            .call_control(
                "thread/turns/list",
                serde_json::json!({
                    "threadId": thread_id,
                    "limit": ENDED_TURN_LOOKUP_PAGE_SIZE,
                    "sortDirection": "desc",
                    "itemsView": "notLoaded",
                }),
            )
            .await?;
        let newest_first = response
            .get("data")
            .and_then(Value::as_array)
            .context("thread/turns/list returned no turn page")?;
        for turn in tracked {
            let Some(status) = ended_turn_status(newest_first, &turn.turn_id) else {
                continue;
            };
            let (send, live_activity) = {
                let mut core = self.core.lock().await;
                let key = turn.key();
                if self.is_draining()
                    || !core.turns.is_active(&key)
                    || core.recovered_turn_keys.contains(&key)
                {
                    continue;
                }
                complete_tracked_turn(&mut core, &turn, status, true)
            };
            info!(
                thread_id = turn.thread_id,
                turn_id = turn.turn_id,
                status,
                "finished a tracked turn the app-server reported as ended"
            );
            self.publish_turn_completion(send, live_activity).await;
        }
        Ok(())
    }

    async fn publish_turn_completion(
        &self,
        send: Option<ApnsSend>,
        live_activity: ActiveTasksLiveActivitySnapshot,
    ) {
        if let Err(error) = self.commit_turn_state().await {
            warn!(%error, "failed to persist reconciled turn state");
        }
        if let Some(send) = send
            && let Some(tx) = self.apns_completion_tx.lock().await.clone()
        {
            let _ = tx.try_send(send);
        }
        self.publish_live_activity(live_activity).await;
    }

    async fn unsubscribe_observer(
        &self,
        sink: &mut futures_util::stream::SplitSink<CodexWebSocket, UpstreamMessage>,
        thread_id: &str,
    ) -> Result<()> {
        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "id": format!("observer:unsubscribe:{thread_id}"),
            "method": "thread/unsubscribe",
            "params": { "threadId": thread_id }
        });
        sink.send(UpstreamMessage::Text(serde_json::to_string(&request)?))
            .await
            .context("observer thread/unsubscribe send failed")
    }
}

fn started_turn_on_thread<'a>(message: &'a Value, thread_id: &str) -> Option<&'a str> {
    if message.get("method").and_then(Value::as_str) != Some("turn/started")
        || message.pointer("/params/threadId").and_then(Value::as_str) != Some(thread_id)
    {
        return None;
    }
    message.pointer("/params/turn/id").and_then(Value::as_str)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TestGateway;
    use crate::turns::{PromptContext, QueuedSubmission};
    use serde_json::json;

    #[tokio::test]
    async fn queued_resume_snapshot_attributes_an_already_active_restored_turn() {
        let directory = tempfile::tempdir().unwrap();
        let gateway = TestGateway::with_native_runtime(directory.path());
        let thread = "e1741c43-3d9a-4448-9f4a-3c7e5906e852";
        let key = TurnKey::new(thread, "queued");
        {
            let mut core = gateway.core.lock().await;
            core.turns
                .enqueue(
                    thread,
                    QueuedSubmission {
                        client_user_message_id: "q1".to_owned(),
                        queued_submission_id: Some("native-q1".to_owned()),
                        context: PromptContext {
                            compaction: false,
                            preview: "Queued work".to_owned(),
                            cwd: Some("/repo".to_owned()),
                            owner_client_id: 12,
                        },
                        created_at_unix_seconds: 1.0,
                    },
                )
                .unwrap();
            core.turns.note_started(&key, 2.0);
        }
        gateway.commit_turn_state().await.unwrap();
        let restored = TestGateway::with_native_runtime(directory.path());
        restored.load_turn_state().await.unwrap();
        let turn = restored
            .adopt_running_turn(
                thread,
                &json!({
                    "id": "queued", "status": "inProgress", "items": [{
                        "type": "userMessage", "clientId": "q1"
                    }]
                }),
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(turn.owner_client_id, 12);
        let core = restored.core.lock().await;
        let context = core.turns.context(&key).unwrap();
        assert_eq!(context.prompt_preview, "Queued work");
        assert_eq!(context.cwd.as_deref(), Some("/repo"));
        assert!(!context.awaiting_attribution);
        assert!(core.turns.durable().queued_submissions.is_empty());
    }
}
