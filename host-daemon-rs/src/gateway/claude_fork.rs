use super::Gateway;
use crate::providers::claude::ClaudeSupervisor;
use crate::providers::claude::projection::{ForkPoint, HistoryError};
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};
use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::{Value, json};
use std::path::PathBuf;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ForkRequest {
    #[serde(default)]
    thread_id: String,
    last_turn_id: Option<String>,
}

impl Gateway {
    pub(super) async fn claude_thread_fork(&self, params: &Value) -> RpcResult {
        let ForkRequest {
            thread_id: source_thread,
            last_turn_id: through_turn,
        } = ForkRequest::deserialize(params).map_err(|error| {
            RpcError::new(
                RpcCode::InvalidParams,
                format!("invalid thread/fork params: {error}"),
            )
        })?;
        let source_thread = source_thread.as_str();
        if !crate::providers::claude::session_uuid_from_thread_id(source_thread)
            .is_some_and(crate::ids::is_session_uuid)
        {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                format!("{source_thread:?} is not a Claude thread id"),
            ));
        }
        let Some(agent) = self.claude_agent() else {
            return Err(RpcError::new(
                RpcCode::Internal,
                "Claude agent is not running",
            ));
        };
        let (point, source, source_path) = self
            .claude_fork_source(&agent, source_thread, through_turn.clone())
            .await?;
        let failed = |error: anyhow::Error| {
            RpcError::new(
                RpcCode::Internal,
                format!("Could not fork Claude thread {source_thread}: {error:#}"),
            )
        };
        let session_uuid = agent.mint_session().await.map_err(failed)?;
        let thread_id = crate::providers::claude::claude_thread_id(&session_uuid);
        let ForkPoint { length, turns } = point;
        let kept_turns = turns.len();
        agent
            .fork_thread_records(source_thread, &thread_id, turns)
            .await
            .map_err(failed)?;
        if self.metadata.is_configured() {
            self.metadata
                .fork(source_thread.to_owned(), thread_id.clone())
                .await
                .map_err(failed)?;
        }
        let target = source_path.with_file_name(format!("{session_uuid}.jsonl"));
        let copy_session = session_uuid.clone();
        tokio::task::spawn_blocking(move || {
            crate::providers::claude::fork::copy_transcript(source, length, &target, &copy_session)
        })
        .await
        .map_err(anyhow::Error::from)
        .and_then(|copied| copied)
        .map_err(failed)?;
        self.journal.runtime(
            "thread_forked",
            json!({
                "threadId": thread_id,
                "sourceThreadId": source_thread,
                "throughTurnId": through_turn,
                "turns": kept_turns,
            }),
        );
        let mut response = self
            .claude_thread_response(&json!({ "threadId": thread_id }))
            .await?;
        response["thread"]["forkedFromId"] = json!(source_thread);
        Ok(response)
    }

    async fn claude_fork_source(
        &self,
        agent: &ClaudeSupervisor,
        source_thread: &str,
        through_turn: Option<String>,
    ) -> Result<(ForkPoint, std::fs::File, PathBuf), RpcError> {
        let turn_starts = agent.lock_lifecycle(source_thread).await;
        let active_turn = agent.active_turn_id(source_thread).await;
        let ((point, source, path), _) = self
            .claude_history
            .read_projection(
                source_thread,
                active_turn.clone(),
                move |projection, file, path| {
                    let point = projection.fork_point(through_turn.as_deref())?;
                    let file = file
                        .try_clone()
                        .context("Could not reopen the Claude session")?;
                    Ok((point, file, path.to_owned()))
                },
            )
            .await
            .map_err(|error| match error {
                HistoryError::InvalidRequest(message) | HistoryError::InvalidCursor(message) => {
                    RpcError::new(RpcCode::InvalidParams, message)
                }
                HistoryError::Capacity(capacity) => capacity.into(),
                HistoryError::Internal(error) => {
                    RpcError::new(RpcCode::Internal, format!("{error:#}"))
                }
            })?;
        if agent.active_turn_id(source_thread).await != active_turn {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "The conversation's running turn changed while the fork was being read; fork again",
            ));
        }
        drop(turn_starts);
        let length = point.length;
        let (source, crons) = tokio::task::spawn_blocking(move || {
            let crons = crate::providers::claude::fork::restored_crons(&source, length);
            (source, crons)
        })
        .await
        .map_err(|error| RpcError::new(RpcCode::Internal, error.to_string()))?;
        let crons =
            crons.map_err(|error| RpcError::new(RpcCode::Internal, format!("{error:#}")))?;
        if !crons.is_empty() {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                format!(
                    "Claude would restore this conversation's scheduled tasks ({}) in the fork and run them twice; fork from a turn before they were created or after they were deleted",
                    crons.join(", ")
                ),
            ));
        }
        Ok((point, source, path))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::mcp::McpTokens;
    use crate::conversations::{Selection, Source as SelectionSource, Update};
    use crate::gateway::ClientCommand;
    use crate::gateway::tests::test_client;
    use crate::observability::journal::Journal;
    use crate::providers::claude::restart::test_support::StubClaude;
    use crate::providers::claude::settings::ClaudeSettings;
    use crate::providers::codex::daemon::CodexAppServer;
    use std::collections::HashMap;
    use std::sync::Arc;
    use tokio::sync::mpsc;

    const SOURCE: &str = "aaaaaaaa-2222-4333-8444-555555555555";
    const SOURCE_THREAD: &str = "claude_aaaaaaaa-2222-4333-8444-555555555555";

    struct Fixture {
        stub: StubClaude,
        gateway: Arc<Gateway>,
        agent: Arc<ClaudeSupervisor>,
        _events: mpsc::Receiver<crate::providers::claude::ClaudeNotification>,
    }

    impl Fixture {
        async fn new() -> Self {
            let stub = StubClaude::new();
            let settings = ClaudeSettings {
                enabled: true,
                ..stub.settings.clone()
            };
            let gateway = Gateway::with_state_paths(
                Arc::new(CodexAppServer::new(
                    PathBuf::from("/bin/true"),
                    HashMap::new(),
                )),
                settings.clone(),
                Journal::disabled(),
                Some(stub.turn_state_path()),
                None,
                None,
            );
            let (sender, events) = mpsc::channel(256);
            let agent =
                ClaudeSupervisor::new(settings, sender, Journal::disabled(), McpTokens::default());
            gateway.set_claude_agent(Arc::clone(&agent));
            let fixture = Self {
                stub,
                gateway,
                agent,
                _events: events,
            };
            fixture.write_source().await;
            fixture
        }

        fn source_records(&self) -> Vec<Value> {
            let assistant = |uuid: &str, id: &str, text: &str, at: &str| {
                json!({"type":"assistant","uuid":uuid,"sessionId":SOURCE,"timestamp":at,
                    "message":{"id":id,"role":"assistant","model":"claude-opus-5-5",
                    "content":[{"type":"text","text":text}],"stop_reason":"end_turn"}})
            };
            vec![
                json!({"type":"user","uuid":"p1","cwd":self.stub.cwd,"sessionId":SOURCE,
                    "timestamp":"2026-09-28T10:00:00Z","message":{"role":"user","content":"Remember ALPHA"}}),
                assistant("a1", "msg_1", "ACK ALPHA", "2026-09-28T10:00:02Z"),
                json!({"type":"user","uuid":"p2","cwd":self.stub.cwd,"sessionId":SOURCE,
                    "timestamp":"2026-09-28T10:01:00Z","message":{"role":"user","content":"Remember BRAVO"}}),
                assistant("a2", "msg_2", "ACK BRAVO", "2026-09-28T10:01:02Z"),
                json!({"type":"custom-title","customTitle":"Fork source","sessionId":SOURCE}),
            ]
        }

        fn write_transcript(&self, records: &[Value]) {
            let contents: String = records.iter().map(|record| format!("{record}\n")).collect();
            self.stub.write_history(SOURCE, &contents);
        }

        async fn write_source(&self) {
            self.write_transcript(&self.source_records());
            let store = crate::providers::claude::conversation_index::Store::new(
                self.stub.claude_home.clone(),
            );
            for (turn, prompt, reasoning, message, at) in [
                ("claude-turn-a", "p1", "r1", "msg_1#0", 1_000),
                ("claude-turn-b", "p2", "r2", "msg_2#0", 2_000),
            ] {
                let item = |item: Value, at: i64| {
                    json!({"method":"item/completed","params":{"threadId":SOURCE_THREAD,
                        "turnId":turn,"item":item,"startedAtMs":at,"completedAtMs":at}})
                };
                for mut frame in [
                    json!({"method":"turn/started","params":{"threadId":SOURCE_THREAD,
                        "turn":{"id":turn,"startedAtMs":at,"status":"inProgress"}}}),
                    item(
                        json!({"type":"userMessage","id":prompt,"clientId":prompt,"content":[]}),
                        at,
                    ),
                    item(
                        json!({"type":"reasoning","id":reasoning,"summary":["Weighing it"],"content":[]}),
                        at + 1,
                    ),
                    item(
                        json!({"type":"agentMessage","id":message,"text":""}),
                        at + 2,
                    ),
                    json!({"method":"turn/completed","params":{"threadId":SOURCE_THREAD,
                        "turn":{"id":turn,"startedAtMs":at,"completedAtMs":at + 3,"status":"completed"}}}),
                ] {
                    store.record(&mut frame).await.unwrap();
                }
            }
            self.gateway
                .metadata
                .update(Update {
                    selection: Selection {
                        session_id: SOURCE_THREAD.to_owned(),
                        model_id: "opus".to_owned(),
                        reasoning_selection_id: "effort-max".to_owned(),
                        fast_mode_enabled: Some(false),
                        source: Some(SelectionSource::Selection),
                    },
                    expected_revision: 0,
                    mutation_id: "source-selection".to_owned(),
                })
                .await
                .unwrap();
        }

        async fn call(&self, method: &str, params: Value) -> Value {
            let (tx, mut rx) = mpsc::channel(8);
            let request = json!({"id": 1, "method": method, "params": params});
            self.gateway
                .handle_claude_rpc(
                    &test_client(1, tx),
                    crate::rpc::dispatch::method_spec(method)
                        .claude
                        .expect("a Claude method")
                        .method,
                    request.as_object().unwrap(),
                )
                .await
                .unwrap();
            let Some(ClientCommand::Text(text)) = rx.recv().await else {
                panic!("{method} sent no response");
            };
            serde_json::from_str(&text).unwrap()
        }

        async fn fork(&self, last_turn: Option<&str>) -> Value {
            self.call(
                "thread/fork",
                json!({"threadId": SOURCE_THREAD, "lastTurnId": last_turn,
                    "persistExtendedHistory": false, "excludeTurns": true, "threadSource": "user"}),
            )
            .await
        }

        async fn turn_ids(&self, thread: &str) -> Vec<String> {
            let page = self
                .call(
                    "thread/turns/list",
                    json!({"threadId": thread, "limit": 10, "sortDirection": "asc", "itemsView": "notLoaded"}),
                )
                .await;
            page["result"]["data"]
                .as_array()
                .unwrap()
                .iter()
                .map(|turn| turn["id"].as_str().unwrap().to_owned())
                .collect()
        }

        async fn item_ids(&self, thread: &str) -> Vec<String> {
            let page = self
                .call(
                    "thread/items/list",
                    json!({"threadId": thread, "limit": 50, "sortDirection": "asc"}),
                )
                .await;
            page["result"]["data"]
                .as_array()
                .unwrap()
                .iter()
                .map(|entry| entry["item"]["id"].as_str().unwrap().to_owned())
                .collect()
        }

        fn transcript(&self, session: &str) -> Vec<Value> {
            std::fs::read_to_string(self.stub.history(session))
                .unwrap()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect()
        }

        fn state_files(&self) -> usize {
            [
                self.stub.claude_home.join("remotecoder-history"),
                self.stub.history(SOURCE).parent().unwrap().to_path_buf(),
            ]
            .iter()
            .map(|directory| std::fs::read_dir(directory).map_or(0, Iterator::count))
            .sum()
        }
    }

    fn with_session(records: &[Value], session: &str) -> Vec<Value> {
        records
            .iter()
            .cloned()
            .map(|mut record| {
                record["sessionId"] = json!(session);
                record
            })
            .collect()
    }

    #[tokio::test]
    async fn a_thread_read_waiting_on_a_claude_thread_never_blocks_health_or_activity() {
        let fixture = Fixture::new().await;
        let held = fixture.agent.lock_lifecycle(SOURCE_THREAD).await;
        let reading = tokio::spawn({
            let gateway = Arc::clone(&fixture.gateway);
            async move {
                gateway
                    .claude_thread_response(&json!({ "threadId": SOURCE_THREAD }))
                    .await
            }
        });
        tokio::task::yield_now().await;
        let health = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            fixture.gateway.claude_health(),
        )
        .await
        .expect("health must not wait behind a Claude thread lock");
        assert_eq!(health["activeTurns"], 0);
        assert!(
            tokio::time::timeout(
                std::time::Duration::from_secs(2),
                fixture.gateway.claude_active_turn_id(SOURCE_THREAD),
            )
            .await
            .expect("active-turn reads must not wait behind a Claude thread lock")
            .is_none()
        );
        assert!(!reading.is_finished());
        drop(held);
        reading.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn a_fork_from_a_turn_is_a_new_resumable_thread_with_that_history() {
        let fixture = Fixture::new().await;
        let source_before = std::fs::read(fixture.stub.history(SOURCE)).unwrap();
        let index = crate::providers::claude::conversation_index::Store::new(
            fixture.stub.claude_home.clone(),
        );
        index
            .update_parent(SOURCE_THREAD, |parent| parent.stopped = true)
            .await
            .unwrap();

        let response = fixture.fork(Some("claude-turn-a")).await;
        let result = &response["result"];
        let fork = result["thread"]["id"].as_str().unwrap().to_owned();
        let session = crate::providers::claude::session_uuid_from_thread_id(&fork).unwrap();

        assert_ne!(fork, SOURCE_THREAD);
        assert_eq!(result["thread"]["forkedFromId"], SOURCE_THREAD);
        assert_eq!(result["thread"]["name"], "Fork source");
        assert_eq!(result["thread"]["status"], json!({"type": "notLoaded"}));
        assert_eq!(result["cwd"], json!(fixture.stub.cwd));
        let records = fixture.source_records();
        assert_eq!(
            fixture.transcript(session),
            with_session(&[&records[..2], &records[4..]].concat(), session)
        );
        assert_eq!(fixture.turn_ids(&fork).await, ["claude-turn-a"]);
        assert_eq!(fixture.item_ids(&fork).await, ["p1", "r1", "msg_1#0"]);
        assert!(fixture.agent.is_minted(&fork).unwrap());
        assert_eq!(
            index.parent(&fork).await.unwrap(),
            crate::providers::claude::conversation_index::Parent::default(),
            "a user Stop and parent deliveries stay with the source"
        );
        let crate::conversations::Snapshot::Full { entries, .. } =
            fixture.gateway.metadata.read(None).await.unwrap()
        else {
            panic!("an unconditional read must return the snapshot");
        };
        let metadata = entries
            .into_iter()
            .find(|record| record.selection.session_id == fork);
        let metadata = metadata.expect("the fork keeps its source's settings");
        assert_eq!(
            (
                metadata.selection.model_id.as_str(),
                metadata.selection.reasoning_selection_id.as_str(),
                metadata.selection.source,
                metadata.server_revision,
            ),
            ("opus", "effort-max", Some(SelectionSource::Selection), 1)
        );
        assert_eq!(
            std::fs::read(fixture.stub.history(SOURCE)).unwrap(),
            source_before
        );

        let started = fixture
            .call(
                "turn/start",
                json!({"threadId": fork, "input": [{"type": "text", "text": "Which marker?"}],
                    "cwd": fixture.stub.cwd, "model": "opus"}),
            )
            .await;
        let launches = fixture.stub.wait_for_log("launches.jsonl", 1).await;
        fixture.agent.stop_all().await;
        assert!(started["result"]["turn"]["id"].is_string(), "{started}");
        let argv = launches[0]["argv"].as_array().unwrap();
        assert!(
            argv.windows(2)
                .any(|pair| pair == [json!("--resume"), json!(session)]),
            "{argv:?}"
        );
        assert!(!argv.contains(&json!("--session-id")), "{argv:?}");
    }

    #[tokio::test]
    async fn a_whole_fork_keeps_every_finished_turn_and_never_the_running_one() {
        let fixture = Fixture::new().await;
        let started = fixture
            .call(
                "turn/start",
                json!({"threadId": SOURCE_THREAD, "input": [{"type": "text", "text": "Still running"}],
                    "cwd": fixture.stub.cwd, "model": "opus"}),
            )
            .await;
        let running = started["result"]["turn"]["id"].as_str().unwrap().to_owned();
        fixture.stub.wait_for_log("received.jsonl", 1).await;

        let refused = fixture.fork(Some(&running)).await;
        let response = fixture.fork(None).await;
        fixture.agent.stop_all().await;

        assert_eq!(
            refused["error"]["code"],
            RpcCode::InvalidParams.value(),
            "{refused}"
        );
        let fork = response["result"]["thread"]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let session = crate::providers::claude::session_uuid_from_thread_id(&fork).unwrap();
        assert_eq!(
            fixture.transcript(session),
            with_session(&fixture.source_records(), session)
        );
        assert_eq!(
            fixture.turn_ids(&fork).await,
            ["claude-turn-a", "claude-turn-b"]
        );
    }

    #[tokio::test]
    async fn a_thread_read_with_turns_reports_the_running_turn_under_its_own_id() {
        let fixture = Fixture::new().await;
        let started = fixture
            .call(
                "turn/start",
                json!({"threadId": SOURCE_THREAD, "input": [{"type": "text", "text": "Still running"}],
                    "cwd": fixture.stub.cwd, "model": "opus"}),
            )
            .await;
        let running = started["result"]["turn"]["id"].as_str().unwrap().to_owned();
        fixture.stub.wait_for_log("received.jsonl", 1).await;

        let read = fixture
            .call(
                "thread/read",
                json!({"threadId": SOURCE_THREAD, "includeTurns": true}),
            )
            .await;
        fixture.agent.stop_all().await;

        let thread = &read["result"]["thread"];
        assert_eq!(thread["status"]["type"], "active", "{read}");
        let turns: Vec<_> = thread["turns"]
            .as_array()
            .unwrap()
            .iter()
            .map(|turn| json!([turn["id"], turn["status"], turn["itemsView"]]))
            .collect();
        assert_eq!(
            turns,
            [
                json!(["claude-turn-a", "completed", "full"]),
                json!(["claude-turn-b", "completed", "full"]),
                json!([running, "inProgress", "full"]),
            ]
        );
    }

    #[tokio::test]
    async fn a_fork_that_cannot_be_made_creates_nothing() {
        let fixture = Fixture::new().await;
        let files = fixture.state_files();

        let missing = fixture
            .call(
                "thread/fork",
                json!({"threadId": "claude_bbbbbbbb-2222-4333-8444-555555555555"}),
            )
            .await;
        let unknown_turn = fixture.fork(Some("claude-turn-z")).await;

        assert_eq!(
            missing["error"]["code"],
            RpcCode::InvalidParams.value(),
            "{missing}"
        );
        assert_eq!(
            unknown_turn["error"]["code"],
            RpcCode::InvalidParams.value(),
            "{unknown_turn}"
        );
        assert_eq!(fixture.state_files(), files);
    }

    #[tokio::test]
    async fn a_fork_that_would_restore_a_scheduled_task_is_refused_before_anything_is_made() {
        let fixture = Fixture::new().await;
        let now = crate::time::rfc3339_millis(crate::time::unix_seconds());
        let mut records = fixture.source_records();
        records.splice(
            1..1,
            [
                json!({"type":"assistant","uuid":"c1","sessionId":SOURCE,"timestamp":now,
                    "message":{"id":"msg_c","role":"assistant","content":[{"type":"tool_use",
                    "id":"toolu_cron","name":"CronCreate","input":{"cron":"*/30 * * * *",
                    "prompt":"Rotate the logs","recurring":true}}]}}),
                json!({"type":"user","uuid":"c2","sessionId":SOURCE,"timestamp":now,
                    "message":{"role":"user","content":[{"type":"tool_result",
                    "tool_use_id":"toolu_cron","content":"Scheduled"}]},
                    "toolUseResult":{"id":"5d1e0c2a","humanSchedule":"every 30 minutes",
                    "recurring":true,"durable":false}}),
            ],
        );
        fixture.write_transcript(&records);
        let files = fixture.state_files();

        let refused = fixture.fork(Some("claude-turn-a")).await;

        assert_eq!(
            refused["error"]["code"],
            RpcCode::InvalidParams.value(),
            "{refused}"
        );
        assert!(
            refused["error"]["message"]
                .as_str()
                .unwrap()
                .contains("every 30 minutes"),
            "{refused}"
        );
        assert_eq!(fixture.state_files(), files);
    }

    #[tokio::test]
    async fn a_fork_that_fails_before_its_transcript_is_written_leaves_no_new_thread() {
        let fixture = Fixture::new().await;
        let project = fixture.stub.history(SOURCE).parent().unwrap().to_path_buf();
        let sessions = std::fs::read_dir(&project).unwrap().count();
        std::fs::write(
            fixture
                .stub
                .turn_state_path()
                .with_file_name("session-metadata-v2.json"),
            "unreadable",
        )
        .unwrap();

        let failed = fixture.fork(Some("claude-turn-a")).await;

        assert_eq!(
            failed["error"]["code"],
            RpcCode::Internal.value(),
            "{failed}"
        );
        assert_eq!(std::fs::read_dir(&project).unwrap().count(), sessions);
    }
}
