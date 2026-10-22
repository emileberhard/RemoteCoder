use super::Gateway;
use crate::providers::claude::conversation_index::TurnRecovery;
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};
use crate::runtime::recovery::RecoveryPhase;
use crate::turns::TurnKey;
use crate::wire::gateway::TerminalError;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::time::Duration;

const LOOKUP_PAGES: usize = 10;
const PAGE_SIZE: usize = 50;
const CONTINUATION_LIMIT: usize = 16;
const LOOKUP_DEADLINE: Duration = Duration::from_secs(15);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    thread_id: String,
    turn_id: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
enum Activity {
    Running,
    Recovering,
    Inactive,
    Unknown,
}

#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Status {
    Completed,
    Failed,
    Interrupted,
}

#[derive(Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
enum Outcome {
    Known {
        status: Status,
        error: Option<TerminalError>,
    },
    Unknown {
        reason: &'static str,
    },
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Inspection {
    thread_id: String,
    turn_id: String,
    execution_turn_id: String,
    activity: Activity,
    outcome: Outcome,
}

impl Inspection {
    fn new(request: Request) -> Self {
        Self {
            thread_id: request.thread_id,
            execution_turn_id: request.turn_id.clone(),
            turn_id: request.turn_id,
            activity: Activity::Unknown,
            outcome: unknown("activityUnavailable"),
        }
    }
}

fn unknown(reason: &'static str) -> Outcome {
    Outcome::Unknown { reason }
}

impl Gateway {
    pub(super) async fn inspect_execution(&self, params: Value) -> RpcResult {
        let request: Request = serde_json::from_value(params).map_err(|error| {
            RpcError::new(
                RpcCode::InvalidParams,
                format!("Invalid exact turn: {error}"),
            )
        })?;
        for id in [&request.thread_id, &request.turn_id] {
            if id.is_empty() || id.len() > 4096 {
                return Err(RpcError::new(
                    RpcCode::InvalidParams,
                    "Exact thread and turn IDs must contain 1–4096 bytes",
                ));
            }
        }
        let mut inspection = Inspection::new(request);
        let result = tokio::time::timeout(LOOKUP_DEADLINE, async {
            if crate::providers::claude::is_claude_thread_id(&inspection.thread_id) {
                self.inspect_claude(&mut inspection).await
            } else {
                self.inspect_codex(&mut inspection).await
            }
        })
        .await;
        match result {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                tracing::warn!(thread_id = %inspection.thread_id, turn_id = %inspection.turn_id, %error, "execution evidence unavailable");
                inspection.activity = Activity::Unknown;
                inspection.outcome = unknown("evidenceUnavailable");
            }
            Err(_) => {
                inspection.activity = Activity::Unknown;
                inspection.outcome = unknown("lookupTimedOut");
            }
        }
        Ok(json!(inspection))
    }

    async fn inspect_claude(&self, inspection: &mut Inspection) -> Result<()> {
        let Some(agent) = self.claude_agent() else {
            inspection.outcome = unknown("providerUnavailable");
            return Ok(());
        };
        let mut visited = HashSet::new();
        for _ in 0..CONTINUATION_LIMIT {
            let id = inspection.execution_turn_id.clone();
            if !visited.insert(id.clone()) {
                inspection.outcome = unknown("continuationCycle");
                return Ok(());
            }
            if let Some(active) = agent.execution_turn_id(&inspection.thread_id, &id).await {
                inspection.execution_turn_id = active;
                inspection.activity = if self.is_draining() {
                    Activity::Recovering
                } else {
                    Activity::Running
                };
                inspection.outcome = unknown("turnRunning");
                return Ok(());
            }
            if self.is_draining() || !self.claude_recovery_complete().await? {
                inspection.activity = Activity::Recovering;
                inspection.outcome = unknown("restartPending");
                return Ok(());
            }
            let record = agent.turn_record(&inspection.thread_id, &id).await?;
            match record.as_ref().and_then(|turn| turn.recovery.as_ref()) {
                Some(TurnRecovery::Continued { turn_id }) => {
                    inspection.execution_turn_id = turn_id.clone();
                    continue;
                }
                Some(TurnRecovery::Pending | TurnRecovery::Unresolved) => {
                    inspection.activity = self
                        .claude_unresolved_activity(&agent, &inspection.thread_id)
                        .await?;
                    inspection.outcome = unknown("continuationUnavailable");
                    return Ok(());
                }
                _ => {}
            }
            if self.is_draining() || !self.claude_recovery_complete().await? {
                inspection.activity = Activity::Recovering;
                inspection.outcome = unknown("restartPending");
                return Ok(());
            }
            // Recovery may have launched a successor while the index was read.
            if let Some(active) = agent.execution_turn_id(&inspection.thread_id, &id).await {
                inspection.execution_turn_id = active;
                inspection.activity = if self.is_draining() {
                    Activity::Recovering
                } else {
                    Activity::Running
                };
                inspection.outcome = unknown("turnRunning");
                return Ok(());
            }
            inspection.activity = Activity::Inactive;
            if record
                .as_ref()
                .is_none_or(|turn| turn.status == "interrupted" && turn.recovery.is_none())
            {
                inspection.activity = self
                    .claude_unresolved_activity(&agent, &inspection.thread_id)
                    .await?;
            }
            inspection.outcome = match record {
                Some(turn) if turn.status == "interrupted" && turn.recovery.is_none() => {
                    unknown("interruptionDispositionUnavailable")
                }
                Some(turn) if turn.completed_at_ms.is_some() => {
                    match serde_json::from_value(json!(turn.status)) {
                        Ok(status) => Outcome::Known {
                            status,
                            error: turn.error,
                        },
                        Err(_) => unknown("terminalEvidenceUnavailable"),
                    }
                }
                _ => unknown("terminalEvidenceUnavailable"),
            };
            return Ok(());
        }
        inspection.outcome = unknown("continuationLimit");
        Ok(())
    }

    async fn claude_unresolved_activity(
        &self,
        agent: &crate::providers::claude::ClaudeSupervisor,
        thread_id: &str,
    ) -> Result<Activity> {
        if self.is_draining() || !self.claude_recovery_complete().await? {
            Ok(Activity::Recovering)
        } else if agent.active_turn_id(thread_id).await.is_some() {
            Ok(Activity::Unknown)
        } else {
            Ok(Activity::Inactive)
        }
    }

    async fn codex_activity(&self, thread_id: &str, turn_id: &str) -> Result<Activity> {
        if self.is_draining() {
            return Ok(Activity::Recovering);
        }
        if let Some(store) = self.recovery_store.clone() {
            // A runtime transaction may start outside this gateway process.
            let journal = tokio::task::spawn_blocking(move || store.load()).await??;
            if journal.is_some_and(|journal| {
                journal.phase != RecoveryPhase::Completed
                    && journal
                        .pending_tasks()
                        .any(|task| task.thread_id == thread_id && task.turn_id == turn_id)
            }) {
                return Ok(Activity::Recovering);
            }
        }
        let core = self.core.lock().await;
        let key = TurnKey::new(thread_id, turn_id);
        if core.turns.is_active(&key)
            || core
                .app_server_active_turns_by_thread
                .get(thread_id)
                .is_some_and(|turn| turn.turn_id == turn_id)
        {
            return Ok(Activity::Running);
        }
        if core.recovered_turn_keys.contains(&key) {
            return Ok(Activity::Recovering);
        }
        if core.app_server_inventory_bootstrapped
            && core.app_server_inventory_unresolved_threads.is_empty()
        {
            Ok(Activity::Inactive)
        } else {
            Ok(Activity::Unknown)
        }
    }

    async fn inspect_codex(&self, inspection: &mut Inspection) -> Result<()> {
        inspection.activity = self
            .codex_activity(&inspection.thread_id, &inspection.turn_id)
            .await?;
        if inspection.activity != Activity::Inactive {
            if inspection.activity == Activity::Running {
                inspection.outcome = unknown("turnRunning");
            }
            return Ok(());
        }
        let mut cursor = None;
        let mut visited = HashSet::new();
        for _ in 0..LOOKUP_PAGES {
            let page = self
                .call_control(
                    "thread/turns/list",
                    json!({
                        "threadId": inspection.thread_id, "limit": PAGE_SIZE,
                        "sortDirection": "desc", "itemsView": "notLoaded", "cursor": cursor,
                    }),
                )
                .await?;
            let turns = page
                .get("data")
                .and_then(Value::as_array)
                .context("Exact turn page unavailable")?;
            if turns.len() > PAGE_SIZE {
                anyhow::bail!("Exact turn page exceeds requested bound");
            }
            if let Some(turn) = turns.iter().find(|turn| turn["id"] == inspection.turn_id) {
                inspection.outcome = codex_outcome(turn);
                break;
            }
            cursor = page
                .get("nextCursor")
                .and_then(Value::as_str)
                .map(str::to_owned);
            match cursor.as_ref() {
                None => {
                    inspection.outcome = unknown("turnNotFound");
                    break;
                }
                Some(cursor) if !visited.insert(cursor.clone()) => {
                    inspection.outcome = unknown("lookupCursorInvalid");
                    break;
                }
                Some(_) => inspection.outcome = unknown("lookupLimit"),
            }
        }
        inspection.activity = self
            .codex_activity(&inspection.thread_id, &inspection.turn_id)
            .await?;
        if inspection.activity != Activity::Inactive {
            inspection.outcome = unknown("activityChanged");
        }
        Ok(())
    }
}

fn codex_outcome(turn: &Value) -> Outcome {
    if turn.get("completedAt").and_then(Value::as_i64).is_none() {
        return unknown("terminalEvidenceUnavailable");
    }
    let Ok(status) = serde_json::from_value(turn["status"].clone()) else {
        return unknown("terminalEvidenceUnavailable");
    };
    let error = TerminalError::from_wire(turn.get("error"));
    Outcome::Known { status, error }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::mcp::McpTokens;
    use crate::observability::journal::Journal;
    use crate::providers::claude::ClaudeSupervisor;
    use crate::providers::claude::conversation_index::Store;
    use crate::test_support::{FakeControl, TestGateway};
    use std::sync::Arc;
    use tokio::sync::mpsc;

    async fn claude_gateway(records: Vec<Value>) -> TestGateway {
        let gateway = TestGateway::new();
        let store = Store::new(gateway.claude_settings.claude_home.clone());
        for mut record in records {
            store.record(&mut record).await.unwrap();
        }
        let (sender, _receiver) = mpsc::channel(16);
        gateway.set_claude_agent(ClaudeSupervisor::new(
            gateway.claude_settings.clone(),
            sender,
            Journal::disabled(),
            McpTokens::new(),
        ));
        gateway
    }

    fn completed(turn_id: &str, status: &str) -> Value {
        json!({"method":"turn/completed", "params":{"threadId":"claude_exact",
            "turn":{"id":turn_id,"status":status,"startedAtMs":1,"completedAtMs":2}}})
    }

    #[tokio::test]
    async fn claude_exact_terminal_error_survives_reload_without_transcript_or_replay() {
        let mut refusal = completed("exact", "failed");
        refusal["params"]["turn"]["error"] =
            json!({"message":"Refused", "codexErrorInfo":"cyberPolicy"});
        let gateway = claude_gateway(vec![completed("other", "completed"), refusal]).await;
        let result = gateway
            .inspect_execution(json!({"threadId":"claude_exact","turnId":"exact"}))
            .await
            .unwrap();
        assert_eq!(result["activity"], "inactive");
        assert_eq!(result["outcome"]["status"], "failed");
        assert_eq!(result["outcome"]["error"]["codexErrorInfo"], "cyberPolicy");
        let missing = gateway
            .inspect_execution(json!({"threadId":"claude_exact","turnId":"missing"}))
            .await
            .unwrap();
        assert_eq!(missing["outcome"]["state"], "unknown");
    }

    #[tokio::test]
    async fn claude_pending_restart_and_recorded_successor_remain_exact() {
        let gateway = claude_gateway(vec![
            completed("original", "interrupted"),
            completed("successor", "completed"),
        ])
        .await;
        let agent = gateway.claude_agent().unwrap();
        gateway
            .draining
            .store(true, std::sync::atomic::Ordering::Release);
        agent
            .record_turn_recovery("claude_exact", "original", TurnRecovery::Pending)
            .await
            .unwrap();
        let pending = gateway
            .inspect_execution(json!({"threadId":"claude_exact","turnId":"original"}))
            .await
            .unwrap();
        assert_eq!(pending["activity"], "recovering");
        assert_eq!(pending["outcome"]["state"], "unknown");
        gateway
            .draining
            .store(false, std::sync::atomic::Ordering::Release);
        let stale = gateway
            .inspect_execution(json!({"threadId":"claude_exact","turnId":"original"}))
            .await
            .unwrap();
        assert_eq!(stale["activity"], "inactive");
        assert_eq!(stale["outcome"]["state"], "unknown");
        agent
            .record_turn_recovery(
                "claude_exact",
                "original",
                TurnRecovery::Continued {
                    turn_id: "successor".into(),
                },
            )
            .await
            .unwrap();
        let (sender, _receiver) = mpsc::channel(16);
        gateway.set_claude_agent(ClaudeSupervisor::new(
            gateway.claude_settings.clone(),
            sender,
            Journal::disabled(),
            McpTokens::new(),
        ));
        let resolved = gateway
            .inspect_execution(json!({"threadId":"claude_exact","turnId":"original"}))
            .await
            .unwrap();
        assert_eq!(resolved["turnId"], "original");
        assert_eq!(resolved["executionTurnId"], "successor");
        assert_eq!(resolved["outcome"]["status"], "completed");
    }

    #[tokio::test]
    async fn claude_incomplete_recovery_and_missing_terminal_evidence_are_unknown() {
        let mut started = completed("exact", "inProgress");
        started["method"] = json!("turn/started");
        started["params"]["turn"]["completedAtMs"] = Value::Null;
        let gateway = claude_gateway(vec![started]).await;
        let result = gateway
            .inspect_execution(json!({"threadId":"claude_exact","turnId":"exact"}))
            .await
            .unwrap();
        assert_eq!(result["activity"], "inactive");
        assert_eq!(result["outcome"]["state"], "unknown");
        let mut settings = gateway.claude_settings.clone();
        settings.enabled = true;
        let fixture =
            Arc::new(crate::providers::claude::settings::ClaudeSettings::isolated_for_test());
        let unready = TestGateway::with_settings(gateway.codex.clone(), settings, fixture);
        let index = std::fs::read_dir(
            gateway
                .claude_settings
                .claude_home
                .join("remotecoder-history"),
        )
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
        std::fs::write(index, b"{broken identity\n").unwrap();
        let (sender, _receiver) = mpsc::channel(16);
        unready.set_claude_agent(ClaudeSupervisor::new(
            unready.claude_settings.clone(),
            sender,
            Journal::disabled(),
            McpTokens::new(),
        ));
        let result = unready
            .inspect_execution(json!({"threadId":"claude_exact","turnId":"exact"}))
            .await
            .unwrap();
        assert_eq!(result["activity"], "recovering");
        assert_eq!(result["outcome"]["reason"], "restartPending");
    }

    #[tokio::test]
    async fn a_legacy_interruption_needs_recorded_recovery_disposition() {
        let gateway = claude_gateway(vec![completed("legacy", "interrupted")]).await;
        let request = json!({"threadId":"claude_exact", "turnId":"legacy"});
        let legacy = gateway.inspect_execution(request.clone()).await.unwrap();
        assert_eq!(legacy["activity"], "inactive");
        assert_eq!(legacy["outcome"]["state"], "unknown");
        gateway
            .claude_agent()
            .unwrap()
            .record_turn_recovery("claude_exact", "legacy", TurnRecovery::Ended)
            .await
            .unwrap();
        let ended = gateway.inspect_execution(request).await.unwrap();
        assert_eq!(ended["outcome"]["status"], "interrupted");
    }

    #[tokio::test]
    async fn codex_terminal_presentation_requires_recorded_completion_evidence() {
        for (status, timestamp, known) in [
            ("completed", Value::Null, false),
            ("interrupted", Value::Null, false),
            ("failed", Value::Null, false),
            ("completed", json!(2), true),
            ("failed", json!(2), true),
            ("interrupted", json!(2), true),
        ] {
            let gateway = TestGateway::new();
            gateway.core.lock().await.app_server_inventory_bootstrapped = true;
            let mut control = FakeControl::attach(&gateway, 2).await;
            let owner = gateway.clone();
            let task = tokio::spawn(async move {
                owner
                    .inspect_execution(json!({"threadId":"ours","turnId":"exact"}))
                    .await
            });
            let request: Value =
                serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
            gateway
                .handle_control_text(
                    json!({"id":request["id"],"result":{"data":[
                {"id":"other","status":"completed","completedAt":2},
                {"id":"exact","status":status,"completedAt":timestamp,"error":null}
            ],"nextCursor":null}})
                    .to_string(),
                    crate::gateway::tests::CONTROL,
                )
                .await;
            let result = task.await.unwrap().unwrap();
            assert_eq!(
                result["outcome"]["state"],
                if known { "known" } else { "unknown" }
            );
            if known {
                assert_eq!(result["outcome"]["status"], status);
            }
        }
    }

    #[tokio::test]
    async fn uncovered_codex_inventory_never_proves_inactivity() {
        let gateway = TestGateway::new();
        let result = gateway
            .inspect_execution(json!({"threadId":"ours","turnId":"exact"}))
            .await
            .unwrap();
        assert_eq!(result["activity"], "unknown");
        assert_eq!(result["outcome"]["state"], "unknown");
        gateway
            .core
            .lock()
            .await
            .recovered_turn_keys
            .insert(TurnKey::new("ours", "exact"));
        let result = gateway
            .inspect_execution(json!({"threadId":"ours","turnId":"exact"}))
            .await
            .unwrap();
        assert_eq!(result["activity"], "recovering");
    }

    #[tokio::test]
    async fn runtime_restart_inspection_tracks_pending_running_and_terminal_work() {
        use crate::runtime::recovery::{
            RecoveryJournal, RecoveryStore, RecoveryTask, RecoveryTaskStatus,
        };
        let root = tempfile::tempdir().unwrap();
        let fixture =
            Arc::new(crate::providers::claude::settings::ClaudeSettings::isolated_for_test());
        let path = root.path().join("recovery.json");
        let gateway = Gateway::with_state_paths(
            Arc::new(crate::providers::codex::daemon::CodexAppServer::new(
                "/bin/true".into(),
                std::collections::HashMap::new(),
            )),
            fixture.settings.clone(),
            Journal::disabled(),
            None,
            Some(path.clone()),
            None,
        );
        gateway.core.lock().await.app_server_inventory_bootstrapped = true;
        let store = RecoveryStore::new(path);
        let mut journal = RecoveryJournal::new(
            "restart".into(),
            "0123456789abcdef0123456789abcdef".into(),
            vec![RecoveryTask {
                thread_id: "ours".into(),
                turn_id: "exact".into(),
                parent_thread_id: None,
                depth: 0,
                recovery_attempts: 0,
                status: RecoveryTaskStatus::Captured,
                error: None,
            }],
        )
        .unwrap();
        journal.phase = RecoveryPhase::Suspending;
        store.write(&journal).unwrap();
        // The abort belongs to suspension; it must not settle the recovery task.
        assert!(
            !crate::runtime::gateway_recovery::record_notification_status(
                store.clone(),
                "ours".into(),
                "exact".into(),
                RecoveryTaskStatus::Failed,
            )
            .await
            .unwrap()
        );
        let result = gateway
            .inspect_execution(json!({"threadId":"ours","turnId":"exact"}))
            .await
            .unwrap();
        assert_eq!(result["activity"], "recovering");
        assert_eq!(result["outcome"]["state"], "unknown");
        gateway
            .core
            .lock()
            .await
            .app_server_active_turns_by_thread
            .insert(
                "ours".into(),
                crate::gateway::AppServerActiveTurn {
                    thread_id: "ours".into(),
                    turn_id: "exact".into(),
                    started_at_unix_seconds: Some(1.0),
                    last_seen_at_unix_seconds: 2.0,
                },
            );
        let result = gateway
            .inspect_execution(json!({"threadId":"ours","turnId":"exact"}))
            .await
            .unwrap();
        assert_eq!(result["activity"], "recovering");
        journal.phase = RecoveryPhase::Recovering;
        store.write(&journal).unwrap();
        assert!(
            crate::runtime::gateway_recovery::record_notification_status(
                store.clone(),
                "ours".into(),
                "exact".into(),
                RecoveryTaskStatus::Completed,
            )
            .await
            .unwrap()
        );
        assert!(
            store
                .load()
                .unwrap()
                .unwrap()
                .pending_tasks()
                .next()
                .is_none()
        );
        // Ingress reopens while recovered work is still running.
        journal.phase = RecoveryPhase::Completed;
        journal.tasks[0].status = RecoveryTaskStatus::Running;
        store.write(&journal).unwrap();
        gateway
            .core
            .lock()
            .await
            .recovered_turn_keys
            .insert(TurnKey::new("ours", "exact"));
        for (draining, activity) in [(false, "running"), (true, "recovering")] {
            gateway
                .draining
                .store(draining, std::sync::atomic::Ordering::Release);
            let result = gateway
                .inspect_execution(json!({"threadId":"ours","turnId":"exact"}))
                .await
                .unwrap();
            assert_eq!(result["activity"], activity);
            assert_eq!(result["outcome"]["state"], "unknown");
            if !draining {
                assert_eq!(result["outcome"]["reason"], "turnRunning");
            }
        }
        gateway
            .draining
            .store(false, std::sync::atomic::Ordering::Release);
        assert!(
            gateway
                .core
                .lock()
                .await
                .recovered_turn_keys
                .contains(&TurnKey::new("ours", "exact"))
        );
        gateway
            .record_restart_recovery_notification(
                &json!({"method":"turn/completed", "params":{
                    "threadId":"ours", "turn":{"id":"exact", "status":"completed"}
                }})
                .to_string(),
            )
            .await;
        assert!(gateway.core.lock().await.recovered_turn_keys.is_empty());
        assert!(
            store
                .load()
                .unwrap()
                .unwrap()
                .pending_tasks()
                .next()
                .is_none()
        );
        gateway
            .core
            .lock()
            .await
            .app_server_active_turns_by_thread
            .clear();
        assert_eq!(
            gateway.codex_activity("ours", "exact").await.unwrap(),
            Activity::Inactive
        );
    }
}
