use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use futures_util::future::BoxFuture;
use serde_json::json;
use tokio::sync::{Mutex, watch};
use tracing::{error, info, warn};

use super::conversation_index::TurnRecovery;
use super::restart::{
    self, Cause, Item, ItemStatus, MAX_DISPATCH_ATTEMPTS, RecoveryAccount, Store,
};
use super::{ClaudeSupervisor, ResumeDelivery};
use crate::gateway::admission::{ConversationAdmission, ConversationBusy};
use crate::observability::journal::Journal;
use crate::rpc::error::RpcCode;

const RESTART_ALERT_TIMEOUT: Duration = Duration::from_secs(3);
const DISPATCH_RETRY_DELAYS: [Duration; 2] = [Duration::from_secs(2), Duration::from_secs(5)];
const ADMISSION_RETRY_DELAY: Duration = Duration::from_millis(500);

pub(crate) type RestartAlert = Arc<dyn Fn(String, String) -> BoxFuture<'static, ()> + Send + Sync>;

pub(crate) struct ClaudeRestartDriver {
    store: Option<Store>,
    store_lock: Arc<Mutex<()>>,
    admission: Arc<ConversationAdmission>,
    journal: Journal,
    alert: RestartAlert,
}

async fn wait_until_listening(mut listening: watch::Receiver<bool>) {
    let _ = listening.wait_for(|listening| *listening).await;
}

impl ClaudeRestartDriver {
    pub(crate) fn new(
        store: Option<Store>,
        admission: Arc<ConversationAdmission>,
        journal: Journal,
        alert: RestartAlert,
    ) -> Self {
        Self {
            store,
            store_lock: Arc::new(Mutex::new(())),
            admission,
            journal,
            alert,
        }
    }

    async fn with_store<T: Send + 'static>(
        &self,
        operation: impl FnOnce(&Store) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let store = self
            .store
            .clone()
            .context("this gateway has no durable Claude restart state")?;
        let guard = Arc::clone(&self.store_lock).lock_owned().await;
        tokio::task::spawn_blocking(move || {
            let _guard = guard;
            operation(&store)
        })
        .await
        .context("Claude restart persistence worker failed")?
    }

    pub(crate) async fn has_pending(&self) -> Result<bool> {
        if self.store.is_none() {
            return Ok(false);
        }
        let journal = self
            .with_store(|store| store.load())
            .await
            .context("Claude restart recovery journal cannot be verified")?;
        Ok(
            journal
                .is_some_and(|journal| journal.items.iter().any(|item| item.status.is_pending())),
        )
    }

    pub(crate) async fn suspended_turns(
        &self,
        thread_id: &str,
    ) -> Result<Vec<restart::SuspendedTurn>> {
        let mut turns = Vec::new();
        if self.store.is_none() {
            return Ok(turns);
        }
        let journal = self
            .with_store(|store| store.load())
            .await
            .context("Claude restart recovery journal cannot be read")?;
        turns.extend(
            journal
                .into_iter()
                .flat_map(|journal| journal.items)
                .filter(|item| item.thread_id == thread_id && item.status.is_pending())
                .filter_map(|item| item.suspended_turn()),
        );
        Ok(turns)
    }

    pub(crate) async fn capture_and_suspend(&self, agent: &ClaudeSupervisor) {
        let captured = agent.capture_for_restart().await;
        let thread_ids = captured
            .iter()
            .map(|item| item.thread_id.clone())
            .collect::<Vec<_>>();
        let persisted = self
            .with_store(move |store| persist_capture(store, captured))
            .await;
        match &persisted {
            Ok(journal) => {
                self.journal
                    .runtime("restart_capture", capture_record(journal));
                for item in &journal.items {
                    if let Err(error) = self
                        .record_turn_recovery(Some(agent), item, TurnRecovery::Pending)
                        .await
                    {
                        warn!(%error, thread_id = %item.thread_id, "Claude execution recovery identity was not saved");
                    }
                }
            }
            Err(error) => {
                error!(error = %format!("{error:#}"), "Claude restart capture could not be persisted");
                self.journal.runtime(
                    "restart_failed",
                    json!({
                        "provider": "claude",
                        "threadIds": thread_ids,
                        "error": format!("capture was not persisted: {error:#}"),
                    }),
                );
            }
        }
        let outcomes = futures_util::future::join_all(thread_ids.iter().cloned().map(
            |thread_id| async move {
                let exited = agent.suspend(&thread_id).await;
                (thread_id, exited)
            },
        ))
        .await;
        for (thread_id, exited) in outcomes {
            self.journal.runtime(
                "restart_suspend",
                json!({ "provider": "claude", "threadId": thread_id, "exited": exited }),
            );
        }
        if let Err(error) = persisted {
            let body = format!(
                "The gateway restarted and could not save this interrupted Claude task for automatic resume: {error:#}"
            );
            let _ = tokio::time::timeout(
                RESTART_ALERT_TIMEOUT,
                futures_util::future::join_all(
                    thread_ids
                        .iter()
                        .map(|thread_id| self.restart_alert(thread_id, &body)),
                ),
            )
            .await;
        }
    }

    async fn restart_alert(&self, thread_id: &str, body: &str) {
        (self.alert)(thread_id.to_owned(), body.to_owned()).await;
    }

    pub(crate) async fn recover(
        &self,
        agent: Option<Arc<ClaudeSupervisor>>,
        listening: watch::Receiver<bool>,
    ) {
        if self.store.is_none() {
            return;
        }
        let journal = match self.with_store(|store| store.load()).await {
            Ok(Some(journal)) => journal,
            Ok(None) => return,
            Err(error) => {
                error!(error = %format!("{error:#}"), "Claude restart journal is unreadable");
                self.journal.runtime(
                    "restart_failed",
                    json!({ "provider": "claude", "error": format!("{error:#}") }),
                );
                return;
            }
        };
        let refusal = match (&agent, journal.account.is_none()) {
            (None, _) => Some("Claude is not enabled in the restarted gateway".to_owned()),
            (_, false) => Some(format!(
                "the task was recorded for {} but this gateway serves the host-default profile",
                describe_account(journal.account.as_ref())
            )),
            _ => None,
        };
        let pending = journal
            .items
            .iter()
            .filter(|item| item.status.is_pending())
            .cloned()
            .collect::<Vec<_>>();
        match (agent, refusal) {
            (Some(agent), None) => {
                wait_until_listening(listening).await;
                futures_util::future::join_all(
                    pending
                        .into_iter()
                        .map(|item| self.recover_item(&agent, &journal.generation_id, item)),
                )
                .await;
            }
            (agent, refusal) => {
                let refusal = refusal.unwrap_or_default();
                for item in pending {
                    self.fail_item(
                        agent.as_deref(),
                        &journal.generation_id,
                        &item,
                        refusal.clone(),
                    )
                    .await;
                }
            }
        }
        let generation_id = journal.generation_id.clone();
        if let Err(error) = self
            .with_store(move |store| store.remove_settled(&generation_id))
            .await
        {
            warn!(error = %format!("{error:#}"), "settled Claude restart journal was not removed");
        }
    }

    async fn recover_item(
        &self,
        agent: &Arc<ClaudeSupervisor>,
        generation_id: &str,
        mut item: Item,
    ) {
        let mut last_error = item.error.clone();
        loop {
            match agent.undelivered(&item).await {
                Ok(frames) if frames.is_empty() => {
                    self.settle_item(agent, generation_id, &item, ResumeDelivery::Recorded)
                        .await;
                    return;
                }
                Ok(_) => {}
                Err(error) => {
                    let message = format!(
                        "the conversation history could not be checked for an earlier delivery: {error:#}"
                    );
                    self.fail_item(Some(agent), generation_id, &item, message)
                        .await;
                    return;
                }
            }
            if item.attempts >= MAX_DISPATCH_ATTEMPTS {
                let message = last_error.unwrap_or_else(|| "dispatch attempts exhausted".into());
                self.fail_item(Some(agent), generation_id, &item, message)
                    .await;
                return;
            }
            let _admission = loop {
                match self.admission.admit(&item.thread_id) {
                    Ok(admission) => break admission,
                    Err(error) if error.is::<ConversationBusy>() => {
                        tokio::time::sleep(ADMISSION_RETRY_DELAY).await;
                    }
                    Err(error) => {
                        self.fail_item(Some(agent), generation_id, &item, error.to_string())
                            .await;
                        return;
                    }
                }
            };
            item.attempts += 1;
            item.status = ItemStatus::Dispatching;
            let attempts = item.attempts;
            if let Err(error) = self
                .update_item(generation_id, &item.recovery_id, move |persisted| {
                    persisted.status = ItemStatus::Dispatching;
                    persisted.attempts = attempts;
                })
                .await
            {
                let message = format!("the dispatch could not be recorded: {error:#}");
                self.fail_item(Some(agent), generation_id, &item, message)
                    .await;
                return;
            }
            self.journal.runtime(
                "restart_dispatch",
                json!({
                    "provider": "claude",
                    "threadId": item.thread_id,
                    "recoveryId": item.recovery_id,
                    "attempt": item.attempts,
                }),
            );
            match agent.resume_with_notice(&item).await {
                Ok(resume) => {
                    self.settle_item(agent, generation_id, &item, resume).await;
                    return;
                }
                Err(error) => {
                    warn!(thread_id = %item.thread_id, error = %error.message, "Claude restart resume attempt failed");
                    self.journal.runtime(
                        "restart_dispatch_failed",
                        json!({
                            "provider": "claude",
                            "threadId": item.thread_id,
                            "recoveryId": item.recovery_id,
                            "attempt": item.attempts,
                            "error": error.message,
                        }),
                    );
                    if error.code == RpcCode::InvalidParams {
                        self.fail_item(Some(agent), generation_id, &item, error.message)
                            .await;
                        return;
                    }
                    last_error = Some(error.message);
                    if let Some(delay) = DISPATCH_RETRY_DELAYS.get(usize::from(item.attempts) - 1) {
                        tokio::time::sleep(*delay).await;
                    }
                }
            }
        }
    }

    async fn update_item(
        &self,
        generation_id: &str,
        recovery_id: &str,
        update: impl FnOnce(&mut Item) + Send + 'static,
    ) -> Result<()> {
        let generation_id = generation_id.to_owned();
        let recovery_id = recovery_id.to_owned();
        self.with_store(move |store| {
            store
                .update_item(&generation_id, &recovery_id, update)
                .map(|_| ())
        })
        .await
    }

    async fn settle_item(
        &self,
        agent: &ClaudeSupervisor,
        generation_id: &str,
        item: &Item,
        resume: ResumeDelivery,
    ) {
        let (turn_id, delivery, status) = match resume {
            ResumeDelivery::Started(turn_id) => (Some(turn_id), "started", ItemStatus::Dispatched),
            ResumeDelivery::Steered(turn_id) => (Some(turn_id), "steered", ItemStatus::Dispatched),
            ResumeDelivery::Recorded => (None, "alreadyInHistory", ItemStatus::Dispatched),
            ResumeDelivery::Stopped => (None, "stoppedByUser", ItemStatus::Stopped),
        };
        let recovery = match &turn_id {
            Some(turn_id) => TurnRecovery::Continued {
                turn_id: turn_id.clone(),
            },
            None if status == ItemStatus::Stopped => TurnRecovery::Ended,
            None => TurnRecovery::Unresolved,
        };
        let recorded = match self.record_turn_recovery(Some(agent), item, recovery).await {
            Ok(recorded) => recorded,
            Err(error) => {
                warn!(%error, thread_id = %item.thread_id, "Claude continuation identity unavailable; execution inspection will remain unknown");
                None
            }
        };
        let turn_id = match recorded {
            Some(TurnRecovery::Continued { turn_id }) => Some(turn_id),
            _ => turn_id,
        };
        let resumed_turn_id = turn_id.clone();
        if let Err(error) = self
            .update_item(generation_id, &item.recovery_id, move |persisted| {
                persisted.status = status;
                persisted.resumed_turn_id = resumed_turn_id;
                persisted.error = None;
            })
            .await
        {
            warn!(error = %format!("{error:#}"), thread_id = %item.thread_id, "resumed Claude task was not recorded as dispatched");
        }
        info!(thread_id = %item.thread_id, delivery, cause = ?item.cause, "Claude task resumed");
        self.journal.runtime(
            "restart_resume",
            json!({
                "provider": "claude",
                "threadId": item.thread_id,
                "recoveryId": item.recovery_id,
                "cause": item.cause,
                "turnId": turn_id,
                "delivery": delivery,
            }),
        );
    }

    async fn fail_item(
        &self,
        agent: Option<&ClaudeSupervisor>,
        generation_id: &str,
        item: &Item,
        message: String,
    ) {
        if let Err(error) = self
            .record_turn_recovery(agent, item, TurnRecovery::Ended)
            .await
        {
            warn!(%error, thread_id = %item.thread_id, "Claude recovery ending unavailable; execution inspection will remain unknown");
        }
        let persisted_message = message.clone();
        if let Err(error) = self
            .update_item(generation_id, &item.recovery_id, move |persisted| {
                persisted.status = ItemStatus::Failed;
                persisted.error = Some(persisted_message);
            })
            .await
        {
            warn!(error = %format!("{error:#}"), thread_id = %item.thread_id, "failed Claude restart item was not recorded");
        }
        self.report_failure(item, message).await;
    }

    async fn record_turn_recovery(
        &self,
        agent: Option<&ClaudeSupervisor>,
        item: &Item,
        recovery: TurnRecovery,
    ) -> Result<Option<TurnRecovery>> {
        if let (Some(agent), Some(turn_id)) = (agent, item.interrupted_turn_id.as_deref())
            && agent.turn_record(&item.thread_id, turn_id).await?.is_some()
        {
            return agent
                .record_turn_recovery(&item.thread_id, turn_id, recovery)
                .await
                .map(Some);
        }
        Ok(None)
    }

    async fn report_failure(&self, item: &Item, message: String) {
        error!(thread_id = %item.thread_id, %message, cause = ?item.cause, "Claude task was not resumed");
        self.journal.runtime(
            "restart_failed",
            json!({
                "provider": "claude",
                "threadId": item.thread_id,
                "recoveryId": item.recovery_id,
                "cause": item.cause,
                "error": message,
            }),
        );
        let event = match item.cause {
            Cause::Restart => "The gateway restarted",
            Cause::Migration => "The Claude profiles were consolidated",
        };
        self.restart_alert(
            &item.thread_id,
            &format!(
                "{event} and could not resume the interrupted Claude task in {}: {message}",
                item.cwd
            ),
        )
        .await;
    }
}

fn persist_capture(store: &Store, captured: Vec<Item>) -> Result<restart::Journal> {
    let previous = store
        .load()
        .context("Claude restart journal cannot be read before capture")?;
    let journal = restart::Journal::capture(None, captured, previous)?;
    if !journal.items.is_empty() {
        store.write(&journal)?;
    }
    Ok(journal)
}

fn capture_record(journal: &restart::Journal) -> serde_json::Value {
    json!({
        "provider": "claude",
        "generationId": journal.generation_id,
        "account": journal.account,
        "itemCount": journal.items.len(),
        "items": journal.items.iter().map(|item| json!({
            "threadId": item.thread_id,
            "recoveryId": item.recovery_id,
            "status": item.status,
            "cause": item.cause,
            "attempts": item.attempts,
            "backgroundTasks": item.background_tasks.len(),
            "scheduledWakes": item.scheduled_wakes.len(),
            "queuedInputs": item.queued_inputs.len(),
        })).collect::<Vec<_>>(),
    })
}

fn describe_account(account: Option<&RecoveryAccount>) -> String {
    match account {
        Some(account) => format!("account {} (generation {})", account.id, account.generation),
        None => "the default account".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;
    use crate::providers::claude::restart::test_support::{SESSION, StubClaude, THREAD};

    #[tokio::test]
    async fn replayed_dispatch_preserves_the_saved_resolution_after_a_crash() {
        for saved in [
            TurnRecovery::Continued {
                turn_id: "successor".into(),
            },
            TurnRecovery::Ended,
        ] {
            let stub = StubClaude::new();
            let identities = super::super::conversation_index::Store::new(stub.claude_home.clone());
            let mut started = json!({"method":"turn/started", "params": {
                "threadId": THREAD, "turn": {"id":"claude-turn-1", "status":"inProgress",
                "startedAtMs":1}
            }});
            identities.record(&mut started).await.unwrap();
            identities
                .record_recovery(THREAD, "claude-turn-1", TurnRecovery::Pending)
                .await
                .unwrap();
            let mut terminal = json!({"method":"turn/completed", "params": {
                "threadId": THREAD, "turn": {"id":"claude-turn-1", "status":"interrupted",
                "startedAtMs":1, "completedAtMs":2}
            }});
            identities.record(&mut terminal).await.unwrap();
            assert!(matches!(
                identities
                    .turn(THREAD, "claude-turn-1")
                    .await
                    .unwrap()
                    .unwrap()
                    .recovery,
                Some(TurnRecovery::Pending)
            ));
            identities
                .record_recovery(THREAD, "claude-turn-1", saved.clone())
                .await
                .unwrap();
            let item = stub.item(SESSION, ItemStatus::Dispatching);
            stub.write_history(SESSION, &format!("{}\n", json!({
                "type":"user", "uuid":item.recovery_id, "message":{"role":"user", "content":item.notice()}
            })));
            let store = Store::beside(&stub.turn_state_path());
            store
                .write(&restart::Journal::capture(None, vec![item], None).unwrap())
                .unwrap();
            let driver = ClaudeRestartDriver::new(
                Some(store.clone()),
                Arc::new(ConversationAdmission::default()),
                Journal::disabled(),
                Arc::new(|_, _| Box::pin(async {})),
            );
            let (sender, _events) = tokio::sync::mpsc::channel(16);
            let replacement = ClaudeSupervisor::new(
                stub.settings.clone(),
                sender,
                Journal::disabled(),
                crate::agents::mcp::McpTokens::default(),
            );
            // A second restart carries the unacknowledged dispatch into a new journal.
            driver.capture_and_suspend(&replacement).await;
            let (_listening, ready) = watch::channel(true);
            driver.recover(Some(replacement.clone()), ready).await;
            let retained = replacement
                .turn_record(THREAD, "claude-turn-1")
                .await
                .unwrap()
                .unwrap();
            assert_eq!(json!(retained.recovery), json!(saved));
            assert!(!driver.has_pending().await.unwrap());
            assert!(store.load().unwrap().is_none());
            assert!(stub.log("launches.jsonl").is_empty());
        }
    }

    #[tokio::test]
    async fn one_unreadable_identity_does_not_hold_host_recovery_pending() {
        let stub = StubClaude::new();
        let identities = super::super::conversation_index::Store::new(stub.claude_home.clone());
        let mut terminal = json!({"method":"turn/completed", "params":{"threadId":THREAD,
            "turn":{"id":"claude-turn-1", "status":"interrupted", "startedAtMs":1, "completedAtMs":2}}});
        identities.record(&mut terminal).await.unwrap();
        let index_path = std::fs::read_dir(stub.claude_home.join("remotecoder-history"))
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        std::fs::write(index_path, b"{broken identity\n").unwrap();
        let item = stub.item(SESSION, ItemStatus::Dispatching);
        stub.write_history(
            SESSION,
            &format!("{}\n", json!({"type":"user", "uuid":item.recovery_id})),
        );
        let store = Store::beside(&stub.turn_state_path());
        store
            .write(&restart::Journal::capture(None, vec![item], None).unwrap())
            .unwrap();
        let driver = ClaudeRestartDriver::new(
            Some(store),
            Arc::new(ConversationAdmission::default()),
            Journal::disabled(),
            Arc::new(|_, _| Box::pin(async {})),
        );
        let (sender, _events) = tokio::sync::mpsc::channel(16);
        let replacement = ClaudeSupervisor::new(
            stub.settings.clone(),
            sender,
            Journal::disabled(),
            crate::agents::mcp::McpTokens::default(),
        );
        let (_listening, ready) = watch::channel(true);
        driver.recover(Some(replacement), ready).await;
        assert!(!driver.has_pending().await.unwrap());
        assert!(stub.log("launches.jsonl").is_empty());
    }

    #[test]
    fn unreadable_prior_restart_journal_is_kept_and_blocks_new_capture() {
        let stub = StubClaude::new();
        let path = stub.turn_state_path().with_file_name(restart::FILE_NAME);
        let corrupt = b"{broken recovery journal";
        std::fs::write(&path, corrupt).expect("corrupt journal");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .expect("private journal");
        let store = Store::beside(&stub.turn_state_path());
        let error = persist_capture(&store, vec![stub.item(SESSION, ItemStatus::Captured)])
            .expect_err("new capture must not replace unreadable work");
        assert!(format!("{error:#}").contains("cannot be read before capture"));
        assert_eq!(std::fs::read(&path).expect("retained journal"), corrupt);
    }

    #[test]
    fn the_capture_record_carries_ids_status_and_counts_only() {
        let stub = StubClaude::new();
        let item = stub.item(SESSION, ItemStatus::Captured);
        let cwd = item.cwd.clone();
        let journal = restart::Journal::capture(None, vec![item], None).expect("journal");

        let record = capture_record(&journal);

        assert_eq!(record["itemCount"], 1);
        let entry = &record["items"][0];
        assert_eq!(entry["threadId"], THREAD);
        assert_eq!(entry["status"], "captured");
        assert_eq!(entry["queuedInputs"], 0);
        assert!(!record.to_string().contains(&cwd));
        for key in ["cwd", "error", "sessionUuid", "model"] {
            assert!(entry.get(key).is_none(), "{key} must not reach the journal");
        }
    }
}
