use super::agent_gateway::AgentOwners;
use super::{ClientTx, Gateway};
use crate::activity::external::{
    ActivityState, SessionActivity, SessionOwner, Snapshot as ExternalSnapshot,
};
use crate::observability::journal::Source;
use crate::observability::read_phase::ReadPhase;
use crate::rpc::RpcError;
use crate::rpc::error::RpcCode;
use crate::time::{unix_millis, unix_seconds};
use crate::turns::agent_label;
use anyhow::{Context, Result};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tokio::sync::Mutex;
use tokio::sync::Notify;
use tokio::task::JoinHandle;
use tokio::time::Instant;
use tracing::warn;

const WORKING_ACTIVITY_TICK: Duration = Duration::from_secs(2);
const IDLE_ACTIVITY_TICK: Duration = Duration::from_secs(8);

#[derive(Default)]
pub(super) struct ActivityPublisher {
    published: Mutex<Option<Published>>,
    wake: Notify,
    task: Mutex<Option<JoinHandle<()>>>,
    discovery_task: Mutex<Option<JoinHandle<()>>>,
    discovery_wake: Notify,
    discovery: std::sync::Mutex<Discovery>,
}

#[derive(Default)]
struct Discovery {
    at: Option<Instant>,
    external: ExternalSnapshot,
    owners: HashMap<String, String>,
    owners_at: Option<Instant>,
    owners_available: bool,
    owner_threads: HashSet<String>,
    claude_recovery_complete: bool,
}

impl ActivityPublisher {
    pub(super) fn mark_changed(&self) {
        self.wake.notify_one();
        self.discovery_wake.notify_one();
    }

    async fn tick(&self) -> Duration {
        let published = self.published.lock().await;
        if published
            .as_ref()
            .is_some_and(|current| current.content.is_idle())
        {
            IDLE_ACTIVITY_TICK
        } else {
            WORKING_ACTIVITY_TICK
        }
    }
}

struct Published {
    epoch: String,
    revision: u64,
    generated_at_unix_seconds: f64,
    content: ActivityContent,
}

#[derive(PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct ActivityContent {
    active_turns: Vec<ActiveTurnEntry>,
    agent_owners: HashMap<String, String>,
    agent_owners_coverage: OwnersCoverage,
    app_server_inventory_available: bool,
    coverage: Coverage,
    external_activity: ExternalSnapshot,
}

#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
enum OwnersCoverage {
    Complete,
    Unavailable,
}

#[derive(PartialEq, Serialize)]
struct Coverage {
    codex: bool,
    claude: bool,
}

impl ActivityContent {
    fn is_idle(&self) -> bool {
        self.active_turns.is_empty()
            && self
                .external_activity
                .sessions
                .iter()
                .all(|session| session.state != ActivityState::Working)
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ActiveTurnEntry {
    thread_id: String,
    turn_id: String,
    started_at_unix_seconds: Option<f64>,
    started_at_sequence: Option<u64>,
    last_seen_at_unix_seconds: f64,
    prompt_preview: String,
    cwd: Option<String>,
    source: TurnSource,
}

impl PartialEq for ActiveTurnEntry {
    fn eq(&self, other: &Self) -> bool {
        (
            &self.thread_id,
            &self.turn_id,
            self.started_at_unix_seconds,
            self.started_at_sequence,
            &self.prompt_preview,
            &self.cwd,
            &self.source,
        ) == (
            &other.thread_id,
            &other.turn_id,
            other.started_at_unix_seconds,
            other.started_at_sequence,
            &other.prompt_preview,
            &other.cwd,
            &other.source,
        )
    }
}

#[derive(PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
enum TurnSource {
    Gateway,
    AppServer,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ActivityPayload<'a> {
    epoch: &'a str,
    revision: u64,
    generated_at_unix_seconds: f64,
    #[serde(flatten)]
    content: &'a ActivityContent,
}

impl Published {
    fn payload(&self) -> Result<Value> {
        Ok(serde_json::to_value(ActivityPayload {
            epoch: &self.epoch,
            revision: self.revision,
            generated_at_unix_seconds: self.generated_at_unix_seconds,
            content: &self.content,
        })?)
    }
}

impl Discovery {
    fn observe_owners(&mut self, threads: &[String], observation: Option<AgentOwners>) {
        self.owners_available = observation.as_ref().is_some_and(|owners| owners.complete);
        if let Some(observation) = observation {
            self.owner_threads = threads.iter().cloned().collect();
            self.owners = observation.owners;
            self.owners_at = Some(Instant::now());
        }
    }
}

fn first_revision() -> u64 {
    u64::try_from(unix_millis()).unwrap_or(0).max(1)
}

impl Gateway {
    pub(super) async fn start_activity_publisher(self: &Arc<Self>) {
        let gateway = Arc::clone(self);
        let task = tokio::spawn(
            Arc::clone(self).run_task_logged("activity_publisher_loop", async move {
                gateway.activity_publisher_loop().await
            }),
        );
        *self.activity.task.lock().await = Some(task);
        let gateway = Arc::clone(self);
        let task = tokio::spawn(
            Arc::clone(self).run_task_logged("activity_discovery_loop", async move {
                gateway.activity_discovery_loop().await
            }),
        );
        *self.activity.discovery_task.lock().await = Some(task);
    }

    pub(super) async fn stop_activity_publisher(&self) {
        let discovery = self.activity.discovery_task.lock().await.take();
        if let Some(task) = discovery {
            task.abort();
            let _ = task.await;
        }
        let task = self.activity.task.lock().await.take();
        if let Some(task) = task {
            task.abort();
            let _ = task.await;
        }
    }

    async fn activity_publisher_loop(self: Arc<Self>) {
        loop {
            let pause = self.activity.tick().await;
            tokio::select! {
                () = self.activity.wake.notified() => {}
                () = tokio::time::sleep(pause) => {}
            }
            if self.clients.is_empty() {
                continue;
            }
            if let Err(error) = self.refresh_activity().await {
                warn!(%error, "failed to publish activity");
            }
        }
    }

    async fn activity_discovery_loop(self: Arc<Self>) {
        loop {
            if !self.clients.is_empty() {
                self.refresh_activity_discovery().await;
            }
            tokio::time::sleep(WORKING_ACTIVITY_TICK).await;
            tokio::select! {
                () = self.activity.discovery_wake.notified() => {}
                () = tokio::time::sleep(self.activity.tick().await.saturating_sub(WORKING_ACTIVITY_TICK)) => {}
            }
        }
    }

    async fn refresh_activity_discovery(&self) {
        let claude_recovery_complete = matches!(
            tokio::time::timeout(Duration::from_secs(1), self.claude_recovery_complete()).await,
            Ok(Ok(true))
        );
        let external =
            match tokio::time::timeout(Duration::from_secs(5), self.external_snapshot()).await {
                Ok(Ok(snapshot)) => snapshot,
                _ => ExternalSnapshot::default(),
            };
        let mut threads: Vec<String> = {
            let core = self.core.lock().await;
            core.turns
                .active_with_context()
                .map(|(turn, _)| turn.thread_id.clone())
                .chain(core.app_server_active_turns_by_thread.keys().cloned())
                .collect()
        };
        threads.extend(
            external
                .sessions
                .iter()
                .filter(|session| {
                    matches!(
                        session.state,
                        ActivityState::Working | ActivityState::Waiting
                    )
                })
                .map(|session| session.thread_id.clone()),
        );
        threads.sort();
        threads.dedup();
        let owners = tokio::time::timeout(
            Duration::from_secs(2),
            self.agent_service().agent_owners(&threads),
        )
        .await;
        {
            let mut discovery = self
                .activity
                .discovery
                .lock()
                .expect("Activity discovery poisoned");
            discovery.at = Some(Instant::now());
            discovery.external = external;
            discovery.claude_recovery_complete = claude_recovery_complete;
            discovery.observe_owners(&threads, owners.ok());
        }
        self.activity.wake.notify_one();
    }

    pub(super) async fn handle_daemon_active_turns(
        &self,
        out_tx: &ClientTx,
        req_id: Option<Value>,
    ) -> Result<()> {
        self.activity.discovery_wake.notify_one();
        let mut phase = ReadPhase::new(&self.journal, "daemon/activeTurns", "publicationLock");
        let result = {
            let mut published = self.activity.published.lock().await;
            phase.advance("turnState");
            self.publish_activity(&mut published)
                .await
                .and_then(Published::payload)
        }
        .map_err(|error| RpcError::new(RpcCode::Internal, error.to_string()));
        phase.complete();
        self.respond(out_tx, req_id.unwrap_or(Value::Null), result, None)
            .await
            .map(|_| ())
    }

    async fn refresh_activity(&self) -> Result<()> {
        let mut published = self.activity.published.lock().await;
        self.publish_activity(&mut published).await?;
        Ok(())
    }

    async fn publish_activity<'a>(
        &self,
        published: &'a mut Option<Published>,
    ) -> Result<&'a Published> {
        let (epoch, content) = self.activity_content().await?;
        let current = match published.take() {
            Some(current) if current.content == content => return Ok(published.insert(current)),
            previous => published.insert(Published {
                epoch,
                revision: previous.map_or_else(first_revision, |previous| {
                    previous.revision.saturating_add(1)
                }),
                generated_at_unix_seconds: unix_seconds(),
                content,
            }),
        };
        self.broadcast_json_or_drop(
            &json!({ "method": "daemon/activeTurns/changed", "params": current.payload()? }),
            Source::Gateway,
        )?;
        Ok(current)
    }

    pub(super) async fn external_snapshot(&self) -> Result<ExternalSnapshot> {
        let mut snapshot = {
            let codex_home = self
                .codex
                .socket_path()
                .parent()
                .and_then(std::path::Path::parent)
                .context("Codex socket has no home directory")?
                .to_path_buf();
            let managed_pid = self.codex.info().await.ok().map(|info| info.pid);
            self.external_activity
                .snapshot(&self.claude_settings, codex_home, managed_pid)
                .await
        };
        if let Some(agent) = self.claude_agent() {
            snapshot.attribute_to_gateway(&agent.process_group_ids());
        }
        Ok(snapshot)
    }

    async fn activity_content(&self) -> Result<(String, ActivityContent)> {
        let (
            mut external_activity,
            agent_owners,
            mut agent_owners_coverage,
            owner_threads,
            recovered,
        ) = {
            let discovery = self
                .activity
                .discovery
                .lock()
                .expect("Activity discovery poisoned");
            let mut external = discovery.external.clone();
            let fresh = discovery
                .at
                .is_some_and(|at| at.elapsed() <= Duration::from_secs(30));
            if !fresh {
                external.claude_available = false;
                external.codex_available = false;
                for session in &mut external.sessions {
                    session.state = ActivityState::Unknown;
                }
            }
            let recovered = fresh && discovery.claude_recovery_complete;
            let owners_fresh = discovery
                .owners_at
                .is_some_and(|at| at.elapsed() <= Duration::from_secs(30));
            let owners = if owners_fresh {
                discovery.owners.clone()
            } else {
                HashMap::new()
            };
            let coverage = if owners_fresh && discovery.owners_available {
                OwnersCoverage::Complete
            } else {
                OwnersCoverage::Unavailable
            };
            (
                external,
                owners,
                coverage,
                discovery.owner_threads.clone(),
                recovered,
            )
        };
        let mut pending_compactions = self.admission.compacting_threads();

        let claude_recovery_complete = !self.is_draining()
            && (!self.claude_settings.enabled
                || recovered && self.claude_recovery_ready.load(Ordering::Acquire));
        let core = self.core.lock().await;
        pending_compactions.extend(
            core.turns
                .pending()
                .filter(|(_, pending)| pending.context.compaction)
                .map(|(_, pending)| pending.thread_id.clone()),
        );
        pending_compactions.sort();
        pending_compactions.dedup();
        for thread in pending_compactions {
            let mut observed = false;
            for session in external_activity
                .sessions
                .iter_mut()
                .filter(|session| session.thread_id == thread)
            {
                observed = true;
                // Preserve every real external owner and stronger busy evidence.
                // Multiple processes can hold the same transcript; none of their
                // idle observations can settle an accepted command.
                if session.state == ActivityState::Idle {
                    session.state = ActivityState::Unknown;
                }
            }
            if !observed {
                external_activity.sessions.push(SessionActivity {
                    thread_id: thread,
                    state: ActivityState::Unknown,
                    owner: Some(SessionOwner::Gateway),
                    waiting_since: None,
                });
            }
        }
        external_activity
            .sessions
            .sort_by(|left, right| left.thread_id.cmp(&right.thread_id));
        let mut active_turns: Vec<ActiveTurnEntry> = core
            .turns
            .active_with_context()
            .map(|(turn, context)| ActiveTurnEntry {
                thread_id: turn.thread_id.clone(),
                turn_id: turn.turn_id.clone(),
                started_at_unix_seconds: Some(turn.started_at_unix_seconds),
                started_at_sequence: core
                    .notification_history
                    .turn_started_sequence(&turn.thread_id, &turn.turn_id),
                last_seen_at_unix_seconds: turn.last_seen_at_unix_seconds,
                prompt_preview: context.map_or_else(
                    || format!("{} task", agent_label(&turn.thread_id)),
                    |context| context.prompt_preview.clone(),
                ),
                cwd: context.and_then(|context| context.cwd.clone()),
                source: TurnSource::Gateway,
            })
            .collect();
        for turn in core.app_server_active_turns_by_thread.values() {
            if active_turns
                .iter()
                .any(|known| known.thread_id == turn.thread_id && known.turn_id == turn.turn_id)
            {
                continue;
            }
            active_turns.push(ActiveTurnEntry {
                thread_id: turn.thread_id.clone(),
                turn_id: turn.turn_id.clone(),
                started_at_unix_seconds: turn.started_at_unix_seconds,
                started_at_sequence: None,
                last_seen_at_unix_seconds: turn.last_seen_at_unix_seconds,
                prompt_preview: format!("{} task", agent_label(&turn.thread_id)),
                cwd: None,
                source: TurnSource::AppServer,
            });
        }
        active_turns.sort_by(|left, right| {
            (&left.thread_id, &left.turn_id).cmp(&(&right.thread_id, &right.turn_id))
        });
        if active_turns
            .iter()
            .map(|turn| &turn.thread_id)
            .chain(
                external_activity
                    .sessions
                    .iter()
                    .filter(|session| {
                        matches!(
                            session.state,
                            ActivityState::Working | ActivityState::Waiting
                        )
                    })
                    .map(|session| &session.thread_id),
            )
            .any(|thread| !owner_threads.contains(thread))
        {
            agent_owners_coverage = OwnersCoverage::Unavailable;
        }
        let app_server_inventory_available = core.app_server_inventory_bootstrapped
            && core.app_server_inventory_unresolved_threads.is_empty();
        let epoch = core.notification_history.epoch().to_owned();
        drop(core);
        Ok((
            epoch,
            ActivityContent {
                active_turns,
                agent_owners,
                agent_owners_coverage,
                app_server_inventory_available,
                coverage: Coverage {
                    codex: app_server_inventory_available,
                    claude: claude_recovery_complete,
                },
                external_activity,
            },
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gateway::ClientCommand;
    use crate::gateway::tests::test_client;
    use crate::turns::TurnKey;
    use tokio::sync::mpsc;

    fn known_owners(owners: HashMap<String, String>) -> Option<AgentOwners> {
        Some(AgentOwners {
            owners,
            complete: true,
        })
    }

    #[tokio::test]
    async fn discovery_round_two_partial_ownership_keeps_current_positive_links() {
        let gateway = gateway();
        for (thread, parent, available) in [
            ("root", None, true),
            ("child", Some("root"), true),
            ("unresolved", None, false),
        ] {
            gateway.agents.parents.lock().await.insert(
                thread.into(),
                super::super::agent_gateway::ParentSnapshot {
                    at: std::time::Instant::now(),
                    parent: parent.map(str::to_owned),
                    available,
                },
            );
        }
        let threads = ["child".into(), "unresolved".into()];
        let owners = gateway.agent_service().agent_owners(&threads).await;
        {
            let mut discovery = gateway.activity.discovery.lock().unwrap();
            discovery.observe_owners(
                &[],
                known_owners(HashMap::from([("old".into(), "root".into())])),
            );
            discovery.owners_at = Some(Instant::now() - Duration::from_secs(31));
            discovery.observe_owners(&threads, Some(owners));
        }
        let current = serde_json::to_value(gateway.activity_content().await.unwrap().1).unwrap();
        assert_eq!(current["agentOwners"]["child"], "root");
        assert_eq!(current["agentOwnersCoverage"], "unavailable");
    }

    #[test]
    fn discovery_opus_timed_out_ownership_does_not_refresh_or_clear_known_owners() {
        let mut discovery = Discovery::default();
        discovery.observe_owners(
            &[],
            known_owners(HashMap::from([("child".into(), "parent".into())])),
        );
        let at = discovery.owners_at;
        discovery.observe_owners(&[], None);
        assert_eq!(discovery.owners_at, at);
        assert_eq!(
            discovery.owners.get("child").map(String::as_str),
            Some("parent")
        );
        let mut unknown = Discovery::default();
        unknown.observe_owners(&[], None);
        assert!(unknown.owners_at.is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn discovery_opus_ownership_coverage_waits_for_newly_active_threads() {
        let gateway = gateway();
        gateway
            .activity
            .discovery
            .lock()
            .unwrap()
            .observe_owners(&[], known_owners(HashMap::new()));
        gateway.core.lock().await.turns.mark_active(
            &TurnKey::new("new-thread", "new-turn"),
            10.0,
            None,
            Some(1),
        );
        let unobserved = serde_json::to_value(gateway.activity_content().await.unwrap().1).unwrap();
        assert_eq!(unobserved["agentOwnersCoverage"], "unavailable");
        gateway
            .activity
            .discovery
            .lock()
            .unwrap()
            .observe_owners(&["new-thread".into()], known_owners(HashMap::new()));
        let observed = serde_json::to_value(gateway.activity_content().await.unwrap().1).unwrap();
        assert_eq!(observed["agentOwnersCoverage"], "complete");
    }

    #[tokio::test(start_paused = true)]
    async fn discovery_opus_ownership_coverage_is_unavailable_until_observed_and_after_expiry() {
        let gateway = gateway();
        let initial = serde_json::to_value(gateway.activity_content().await.unwrap().1).unwrap();
        assert_eq!(initial["agentOwnersCoverage"], "unavailable");
        {
            let mut discovery = gateway.activity.discovery.lock().unwrap();
            discovery.observe_owners(
                &[],
                known_owners(HashMap::from([("child".into(), "parent".into())])),
            );
        }
        let current = serde_json::to_value(gateway.activity_content().await.unwrap().1).unwrap();
        assert_eq!(current["agentOwnersCoverage"], "complete");
        assert_eq!(current["agentOwners"]["child"], "parent");
        gateway
            .activity
            .discovery
            .lock()
            .unwrap()
            .observe_owners(&[], None);
        let failed = serde_json::to_value(gateway.activity_content().await.unwrap().1).unwrap();
        assert_eq!(failed["agentOwnersCoverage"], "unavailable");
        assert_eq!(failed["agentOwners"]["child"], "parent");
        gateway
            .activity
            .discovery
            .lock()
            .unwrap()
            .observe_owners(&[], known_owners(HashMap::new()));
        let empty = serde_json::to_value(gateway.activity_content().await.unwrap().1).unwrap();
        assert_eq!(empty["agentOwnersCoverage"], "complete");
        assert_eq!(empty["agentOwners"], json!({}));
        tokio::time::advance(Duration::from_secs(31)).await;
        let expired = serde_json::to_value(gateway.activity_content().await.unwrap().1).unwrap();
        assert_eq!(expired["agentOwnersCoverage"], "unavailable");
    }

    #[test]
    fn the_snapshot_payload_matches_the_coverage_fixture() {
        let expected: Value = serde_json::from_str(include_str!(
            "../../../protocol-fixtures/activity/coverage.json"
        ))
        .expect("fixture json");
        let published = Published {
            epoch: "6f0f4b1e-2c1a-4f6e-9d55-0a1b2c3d4e5f".to_owned(),
            revision: 2,
            generated_at_unix_seconds: 1790330861.099,
            content: ActivityContent {
                active_turns: vec![ActiveTurnEntry {
                    thread_id: "claude_11111111-2222-4333-8444-555555555555".into(),
                    turn_id: "claude-turn-1".into(),
                    started_at_unix_seconds: Some(1790330800.0),
                    started_at_sequence: Some(41),
                    last_seen_at_unix_seconds: 1790330800.0,
                    prompt_preview: "working".into(),
                    cwd: None,
                    source: TurnSource::Gateway,
                }],
                agent_owners: HashMap::new(),
                agent_owners_coverage: OwnersCoverage::Complete,
                app_server_inventory_available: false,
                coverage: Coverage {
                    codex: false,
                    claude: true,
                },
                external_activity: ExternalSnapshot {
                    sessions: Vec::new(),
                    claude_available: true,
                    codex_available: true,
                },
            },
        };

        assert_eq!(published.payload().expect("payload"), expected);
    }

    #[test]
    fn unknown_turn_start_serializes_as_null() {
        let entry = ActiveTurnEntry {
            thread_id: "thread-1".into(),
            turn_id: "turn-1".into(),
            started_at_unix_seconds: None,
            started_at_sequence: None,
            last_seen_at_unix_seconds: 1.0,
            prompt_preview: "working".into(),
            cwd: None,
            source: TurnSource::AppServer,
        };

        let value = serde_json::to_value(entry).expect("activity entry");
        assert_eq!(value["startedAtUnixSeconds"], Value::Null);
    }

    fn gateway() -> crate::test_support::TestGateway {
        crate::test_support::TestGateway::new()
    }

    fn next_text(rx: &mut mpsc::Receiver<ClientCommand>) -> Value {
        match rx.try_recv() {
            Ok(ClientCommand::Text(text)) => serde_json::from_str(&text).expect("JSON frame"),
            other => panic!("expected a text frame, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn active_turn_reads_and_publications_do_not_wait_for_external_discovery() {
        crate::test_support::with_manual_time(async {
            use std::os::unix::fs::PermissionsExt;
            let settings =
                Arc::new(crate::providers::claude::settings::ClaudeSettings::isolated_for_test());
            let program = settings.root_path().join("blocked-claude");
            let gate = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = gate.local_addr().unwrap().port();
            std::fs::write(&program, format!("#!/usr/bin/python3\nimport socket\nwith socket.create_connection(('127.0.0.1', {port})) as gate: gate.recv(1)\n")).unwrap();
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
            let mut configured = settings.settings.clone();
            configured.enabled = true;
            configured.claude_path = program;
            let gateway = crate::test_support::TestGateway::with_settings(
                Arc::new(crate::providers::codex::daemon::CodexAppServer::new(
                    std::path::PathBuf::from("/bin/true"),
                    HashMap::new(),
                )),
                configured,
                settings,
            );
            let refresh_gateway = gateway.clone();
            let refresh =
                tokio::spawn(async move { refresh_gateway.refresh_activity_discovery().await });
            let (_held, _) = gate.accept().await.unwrap();
            let (read_tx, mut reads) = mpsc::channel(8);
            let reader = test_client(2, read_tx);
            gateway.core.lock().await.turns.mark_active(
                &TurnKey::new("thread-live", "turn-live"),
                10.0,
                None,
                Some(1),
            );
            gateway.handle_daemon_active_turns(&reader, Some(json!(1))).await.unwrap();
            let first = next_text(&mut reads)["result"].clone();
            assert_eq!(first["activeTurns"][0]["turnId"], "turn-live");
            assert_eq!(first["externalActivity"]["claudeAvailable"], false);
            assert_eq!(first["coverage"]["claude"], false);
            gateway
                .core
                .lock()
                .await
                .turns
                .mark_inactive(&TurnKey::new("thread-live", "turn-live"));
            gateway.handle_daemon_active_turns(&reader, Some(json!(2))).await.unwrap();
            let stopped = next_text(&mut reads)["result"].clone();
            assert!(stopped["activeTurns"].as_array().unwrap().is_empty());
            assert!(stopped["revision"].as_u64() > first["revision"].as_u64());
            assert!(!refresh.is_finished(), "discovery must remain gated through both publications");
            refresh.abort();
            let _ = refresh.await;
        }).await;
    }

    #[tokio::test]
    async fn pending_compaction_activity_stays_unknown_without_an_invented_turn() {
        let gateway = gateway();
        gateway.core.lock().await.app_server_inventory_bootstrapped = true;
        let request =
            json!({"id":1,"method":"thread/compact/start","params":{"threadId":"compact-thread"}});
        gateway
            .capture_client_request_locked(42, request.as_object().unwrap())
            .await
            .unwrap();
        gateway
            .capture_turn_start_response(42, &json!({"id":1,"result":{}}))
            .await
            .unwrap();
        let (_, content) = gateway.activity_content().await.unwrap();
        assert!(content.coverage.codex);
        assert!(content.active_turns.is_empty());
        let session = content
            .external_activity
            .sessions
            .iter()
            .find(|session| session.thread_id == "compact-thread")
            .unwrap();
        assert_eq!(session.state, ActivityState::Unknown);
        assert_eq!(session.owner, Some(SessionOwner::Gateway));
        gateway.capture_agent_message(&json!({"method":"turn/started","params":{"threadId":"compact-thread","turn":{"id":"real-turn","status":"inProgress"}}})).await;
        let (_, content) = gateway.activity_content().await.unwrap();
        assert!(
            content
                .external_activity
                .sessions
                .iter()
                .all(|session| session.thread_id != "compact-thread")
        );
        assert_eq!(content.active_turns[0].turn_id, "real-turn");
    }

    #[tokio::test]
    async fn a_change_is_pushed_once_and_reads_return_the_same_revision() {
        let gateway = gateway();
        let (push_tx, mut pushes) = mpsc::channel(8);
        gateway.clients.insert(1, test_client(1, push_tx));
        let (read_tx, mut reads) = mpsc::channel(8);
        let reader = test_client(2, read_tx);

        gateway
            .handle_daemon_active_turns(&reader, Some(json!(1)))
            .await
            .expect("first read");
        let initial = next_text(&mut pushes);
        assert_eq!(initial["method"], "daemon/activeTurns/changed");
        let first = next_text(&mut reads)["result"].clone();
        assert_eq!(initial["params"], first);
        let first_revision = first["revision"].as_u64().expect("revision");
        assert!(first_revision > 1_700_000_000_000);
        assert_eq!(first["coverage"]["claude"], true);

        gateway
            .handle_daemon_active_turns(&reader, Some(json!(2)))
            .await
            .expect("unchanged read");
        assert!(
            pushes.try_recv().is_err(),
            "an unchanged read must not push"
        );
        assert_eq!(next_text(&mut reads)["result"], first);

        gateway.core.lock().await.turns.mark_active(
            &TurnKey::new("thread-1", "turn-1"),
            10.0,
            None,
            Some(1),
        );
        gateway.refresh_activity().await.expect("publish");
        let changed = next_text(&mut pushes)["params"].clone();
        assert_eq!(changed["revision"], first_revision + 1);
        assert_eq!(changed["epoch"], first["epoch"]);
        assert_eq!(changed["activeTurns"][0]["startedAtSequence"], Value::Null);
        assert_eq!(changed["activeTurns"][0]["threadId"], "thread-1");
        assert_eq!(changed["activeTurns"][0]["source"], "gateway");

        gateway
            .handle_daemon_active_turns(&reader, Some(json!(3)))
            .await
            .expect("read after change");
        assert!(pushes.try_recv().is_err());
        assert_eq!(next_text(&mut reads)["result"], changed);
    }

    #[tokio::test]
    async fn a_gateway_turn_reports_the_sequence_of_its_stored_start() {
        let gateway = gateway();
        let (tx, mut pushes) = mpsc::channel(8);
        gateway.clients.insert(1, test_client(1, tx));
        let started = json!({
            "method": "turn/started",
            "params": {"threadId": "thread-1", "turn": {"id": "turn-1"}}
        });
        let sequence = gateway
            .push_notification_history(
                &started.to_string(),
                Some("thread-1".to_owned()),
                crate::notifications::history::NotificationOrigin::Provider,
            )
            .await;
        gateway.core.lock().await.turns.mark_active(
            &TurnKey::new("thread-1", "turn-1"),
            10.0,
            None,
            Some(1),
        );

        gateway.refresh_activity().await.expect("publish");

        let pushed = next_text(&mut pushes)["params"].clone();
        assert_eq!(pushed["activeTurns"][0]["startedAtSequence"], sequence);
        assert_eq!(pushed["epoch"], gateway.notification_position().await.0);
    }
}
