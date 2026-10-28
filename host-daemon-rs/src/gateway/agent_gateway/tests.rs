use super::*;
use crate::agents::Capabilities;
use crate::gateway::{ApnsSend, GatewayConstruction};
use crate::observability::journal::Journal;
use crate::providers::codex::daemon::CodexAppServer;
use std::collections::HashSet;
use std::sync::Arc;
use tokio::sync::mpsc;

#[tokio::test]
async fn sidecar_and_unrecognized_ids_never_route_to_codex() {
    let gateway = crate::test_support::TestGateway::new();
    let mut control = crate::test_support::FakeControl::attach(&gateway, 4).await;
    for thread in [
        "claude:11111111-2222-4333-8444-555555555555:a123456",
        "unknown-provider:11111111-2222-4333-8444-555555555555",
        "unrecognized-id",
    ] {
        let error = gateway.agent_conversation(thread).unwrap_err();
        let error = error.downcast_ref::<RpcError>().unwrap();
        assert_eq!(
            serde_json::to_value(error).unwrap()["data"]["class"],
            "unsupported"
        );
    }
    assert!(control.requests.try_recv().is_err());
}

async fn respond_control(
    gateway: &Arc<Gateway>,
    count: usize,
    mut answer: impl FnMut(&Value) -> Value + Send + 'static,
) -> tokio::task::JoinHandle<()> {
    answer_control(gateway, count, move |request| Ok(answer(request))).await
}

async fn answer_control(
    gateway: &Arc<Gateway>,
    count: usize,
    mut answer: impl FnMut(&Value) -> std::result::Result<Value, Value> + Send + 'static,
) -> tokio::task::JoinHandle<()> {
    let mut requests = crate::test_support::FakeControl::attach(gateway, 4)
        .await
        .requests;
    let owner = Arc::clone(gateway);
    tokio::spawn(async move {
        for _ in 0..count {
            let request: Value = serde_json::from_str(&requests.recv().await.unwrap()).unwrap();
            let result = answer(&request).map_err(|error| error.to_string());
            owner
                .control_requests
                .lock()
                .unwrap()
                .remove(request["id"].as_str().unwrap())
                .unwrap()
                .send(result)
                .unwrap();
        }
    })
}

type Stops = Arc<std::sync::Mutex<Vec<(String, String)>>>;

fn stopped_family(
    reachable: bool,
) -> (
    Stops,
    impl FnMut(&Value) -> std::result::Result<Value, Value> + Send + 'static,
) {
    let stops = Arc::new(std::sync::Mutex::new(Vec::new()));
    let recorded = Arc::clone(&stops);
    let child = |id: &str, status: Value| json!({"id": id, "parentThreadId": "root", "name": id, "updatedAt": 1, "status": status});
    let answer = move |request: &Value| {
        let params = &request["params"];
        let thread = params["threadId"].as_str().unwrap_or_default();
        match request["method"].as_str().unwrap() {
            "turn/interrupt" => {
                let turn = params["turnId"].as_str().unwrap();
                recorded
                    .lock()
                    .unwrap()
                    .push((thread.to_owned(), turn.to_owned()));
                if thread == "ended" {
                    return Err(json!({"code": -32600, "message": NO_ACTIVE_TURN}));
                }
                Ok(json!({}))
            }
            "thread/backgroundTerminals/clean" => {
                recorded
                    .lock()
                    .unwrap()
                    .push((thread.to_owned(), "commands".to_owned()));
                match thread {
                    "ended" => Err(json!({"code": -32600, "message": "thread not found: ended"})),
                    "root" | "waiting" if !reachable => {
                        Err(json!({"code": -32603, "message": "terminals unavailable"}))
                    }
                    _ => Ok(json!({})),
                }
            }
            "thread/list" => {
                assert_eq!(params["ancestorThreadId"], "root");
                Ok(json!({"data": [
                    child("working", json!({"type": "active", "activeFlags": []})),
                    child("waiting", json!({"type": "active", "activeFlags": ["waitingOnApproval"]})),
                    child("idle", json!({"type": "idle"})),
                    child("ended", json!({"type": "active", "activeFlags": []})),
                    child("nested", json!({"type": "active", "activeFlags": []})),
                ], "nextCursor": null}))
            }
            "thread/turns/list" if thread == "nested" && !reachable => {
                Err(json!({"code": -32603, "message": "history unavailable"}))
            }
            "thread/turns/list" => {
                let status = if thread == "idle" {
                    "completed"
                } else {
                    "inProgress"
                };
                Ok(json!({"data": [{"id": format!("turn-{thread}"), "status": status}]}))
            }
            other => panic!("unexpected control request {other}"),
        }
    };
    (stops, answer)
}

#[tokio::test]
async fn a_codex_stop_ends_the_turn_its_running_agents_and_their_commands() {
    let gateway = gateway();
    let (stops, answer) = stopped_family(true);
    let responder = answer_control(&gateway, 17, answer).await;

    let stopped = gateway
        .interrupt_codex_turn(json!({"threadId": "root", "turnId": "turn-root"}))
        .await;
    responder.await.unwrap();

    assert_eq!(stopped, Ok(json!({})));
    let stops = stops.lock().unwrap().clone();
    for thread in ["root", "working", "waiting", "ended", "nested"] {
        let order = stops
            .iter()
            .filter(|(stopped, _)| stopped == thread)
            .map(|(_, action)| action.as_str())
            .collect::<Vec<_>>();
        assert_eq!(order, [format!("turn-{thread}").as_str(), "commands"]);
    }
    assert_eq!(stops.len(), 10);
}

#[tokio::test]
async fn a_codex_stop_that_cannot_reach_a_running_agent_or_command_says_so() {
    let gateway = gateway();
    let (stops, answer) = stopped_family(false);
    let responder = answer_control(&gateway, 16, answer).await;

    let stopped = gateway
        .interrupt_codex_turn(json!({"threadId": "root", "turnId": "turn-root"}))
        .await
        .unwrap_err();
    responder.await.unwrap();

    assert_eq!(stopped.code, RpcCode::Internal);
    assert_eq!(
        stopped.message,
        "The turn stopped, but some of its work may still be running: its commands: terminals unavailable; nested has no known running turn; waiting's commands: terminals unavailable"
    );
    assert!(
        stops
            .lock()
            .unwrap()
            .contains(&("nested".to_owned(), "commands".to_owned()))
    );
}

#[tokio::test]
async fn a_codex_stop_that_does_not_name_the_running_turn_interrupts_nothing() {
    let cases = [
        (
            "turn-earlier",
            Ok(json!({"data": [{"id": "turn-root", "status": "inProgress"}]})),
            RpcError::new(
                RpcCode::InvalidRequest,
                "expected active turn id turn-earlier but found turn-root",
            ),
        ),
        (
            "turn-root",
            Ok(json!({"data": [{"id": "turn-root", "status": "completed"}]})),
            RpcError::turn_not_running(NO_ACTIVE_TURN, "root", Some("turn-root")),
        ),
        (
            "turn-root",
            Err(json!({"code": -32603, "message": "history unavailable"})),
            RpcError::new(
                RpcCode::Internal,
                "The turn's state could not be read, so nothing was stopped: history unavailable",
            ),
        ),
    ];
    for (turn, latest, refusal) in cases {
        let gateway = gateway();
        let responder = answer_control(&gateway, 1, move |request| {
            assert_eq!(request["method"], "thread/turns/list");
            assert_eq!(request["params"]["threadId"], "root");
            latest.clone()
        })
        .await;

        let stopped = tokio::time::timeout(
            Duration::from_secs(2),
            gateway.interrupt_codex_turn(json!({"threadId": "root", "turnId": turn})),
        )
        .await
        .expect("a refused Stop answers without waiting on an interrupt");
        responder.await.unwrap();

        assert_eq!(stopped, Err(refusal));
    }
}

#[tokio::test]
async fn a_codex_stop_names_every_child_whose_activity_it_cannot_read() {
    let gateway = gateway();
    let responder = answer_control(&gateway, 6, |request| {
        let params = &request["params"];
        match (request["method"].as_str().unwrap(), params["threadId"].as_str()) {
            ("thread/turns/list", Some("root")) => {
                Ok(json!({"data": [{"id": "turn-root", "status": "inProgress"}]}))
            }
            ("thread/turns/list", _) => {
                Err(json!({"code": -32603, "message": "history unavailable"}))
            }
            ("turn/interrupt" | "thread/backgroundTerminals/clean", _) => Ok(json!({})),
            ("thread/list", _) => Ok(json!({"data": [
                {"id": "idle", "parentThreadId": "root", "name": "idle", "updatedAt": 1, "status": {"type": "idle"}},
                {"id": "cold", "parentThreadId": "root", "name": "cold", "updatedAt": 1, "status": {"type": "notLoaded"}},
            ], "nextCursor": null})),
            (other, _) => panic!("unexpected control request {other}"),
        }
    })
    .await;

    let stopped = gateway
        .interrupt_codex_turn(json!({"threadId": "root", "turnId": "turn-root"}))
        .await
        .unwrap_err();
    responder.await.unwrap();

    assert_eq!(stopped.code, RpcCode::Internal);
    assert_eq!(
        stopped.message,
        "The turn stopped, but some of its work may still be running: cold's activity could not be read; idle's activity could not be read"
    );
}

#[tokio::test]
async fn stopping_an_agent_card_also_stops_that_agents_descendants() {
    let gateway = gateway();
    gateway
        .agents
        .views
        .lock()
        .await
        .push_back(AgentViewSnapshot {
            root: "root".into(),
            at: Instant::now(),
            agents: vec![Agent {
                owner_host_id: "fixture-host".into(),
                job_id: None,
                parent: None,
                recipient: None,
                kind: None,
                intent_state: None,
                id: "codex:working".into(),
                thread_id: Some("working".into()),
                title: "Working".into(),
                execution_id: Some("turn-working".into()),
                capabilities: Capabilities {
                    stop: true,
                    ..Default::default()
                },
                ..native_agent(State::Working)
            }],
        });
    let stops: Stops = Arc::default();
    let recorded = Arc::clone(&stops);
    let responder = answer_control(&gateway, 7, move |request| {
        let params = &request["params"];
        let thread = params["threadId"].as_str().unwrap_or_default();
        match request["method"].as_str().unwrap() {
            "thread/turns/list" => Ok(json!({"data": [
                {"id": format!("turn-{thread}"), "status": "inProgress"}
            ]})),
            "thread/list" => {
                assert_eq!(params["ancestorThreadId"], "working");
                Ok(json!({"data": [
                    {"id": "nested", "parentThreadId": "working", "name": "nested", "updatedAt": 1, "status": {"type": "active", "activeFlags": []}}
                ], "nextCursor": null}))
            }
            action @ ("turn/interrupt" | "thread/backgroundTerminals/clean") => {
                recorded
                    .lock()
                    .unwrap()
                    .push((thread.to_owned(), action.to_owned()));
                Ok(json!({}))
            }
            other => panic!("unexpected control request {other}"),
        }
    })
    .await;

    let stopped = gateway
        .agent_service()
        .act_on_agent(ActionParams {
            agent: AgentRef {
                agent_id: "codex:working".into(),
                thread_id: "root".into(),
            },
            action: "stop".into(),
            execution_id: Some("turn-working".into()),
            text: None,
            mutation_id: None,
        })
        .await
        .unwrap();
    responder.await.unwrap();

    assert_eq!(stopped, json!({"delivery": "stopRequested"}));
    let mut stops = stops.lock().unwrap().clone();
    stops.sort();
    assert_eq!(
        stops,
        [
            (
                "nested".to_owned(),
                "thread/backgroundTerminals/clean".to_owned()
            ),
            ("nested".to_owned(), "turn/interrupt".to_owned()),
            (
                "working".to_owned(),
                "thread/backgroundTerminals/clean".to_owned()
            ),
            ("working".to_owned(), "turn/interrupt".to_owned()),
        ]
    );
}

#[test]
fn native_non_child_proof_requires_a_valid_exact_thread_header() {
    for source in [
        json!("cli"),
        json!("vscode"),
        json!("exec"),
        json!("appServer"),
        json!("unknown"),
        json!({"custom":"client"}),
    ] {
        assert!(
            !native_agent_relation(&json!({"thread":{"id":"root","source":source}}), "root")
                .unwrap()
        );
    }
    for source in [
        Value::Null,
        json!(17),
        json!({}),
        json!("future"),
        json!({"subAgent":null}),
    ] {
        assert!(
            native_agent_relation(&json!({"thread":{"id":"root","source":source}}), "root")
                .is_err()
        );
    }
    assert!(
        native_agent_relation(
            &json!({"thread":{"id":"root","source":"cli","parentThreadId":7}}),
            "root"
        )
        .is_err()
    );
    assert!(
        native_agent_relation(
            &json!({"thread":{"id":"root","source":"cli","parentThreadId":"parent"}}),
            "root"
        )
        .unwrap()
    );
    for source in [
        json!({"subAgent":"review"}),
        json!({"subAgent":"compact"}),
        json!({"subAgent":"memory_consolidation"}),
        json!({"subAgent":{"other":"worker"}}),
    ] {
        assert!(
            native_agent_relation(&json!({"thread":{"id":"root","source":source}}), "root")
                .unwrap()
        );
    }
    assert!(
        native_agent_relation(&json!({"thread":{"id":"other","source":"cli"}}), "root").is_err()
    );
}

fn native_agent(state: State) -> Agent {
    Agent {
        owner_host_id: "fixture-host".into(),
        job_id: None,
        parent: None,
        recipient: None,
        kind: None,
        intent_state: None,
        id: "codex:child".into(),
        parent_id: None,
        owner_thread_id: "root".into(),
        thread_id: Some("child".into()),
        provider: "codex".into(),
        source: "native".into(),
        title: "Child".into(),
        model: None,
        state,
        capabilities: Capabilities::default(),
        execution_id: None,
        last_active_at: None,
    }
}

fn gateway() -> crate::test_support::TestGateway {
    crate::test_support::TestGateway::new()
}

#[tokio::test]
async fn unavailable_root_ancestry_holds_a_previously_verified_activity_child() {
    let gateway = gateway();
    gateway.agents.parents.lock().await.insert(
        "child".into(),
        ParentSnapshot {
            at: Instant::now() - Duration::from_secs(301),
            parent: Some("root".into()),
            available: true,
        },
    );
    let owners = gateway
        .agent_service()
        .agent_owners(&["child".into(), "root".into()])
        .await;
    assert!(!owners.complete);
    assert!(owners.owners.is_empty());
    assert_eq!(
        gateway.agents.parents.lock().await["child"]
            .parent
            .as_deref(),
        Some("root")
    );
    assert!(!gateway.agents.parents.lock().await["root"].available);
}

#[tokio::test]
async fn native_inventory_uses_ancestry_and_exact_execution_state() {
    let gateway = gateway();
    let mut methods = ["thread/list", "thread/turns/list"].into_iter();
    let responder = respond_control(&gateway, 2, move |request| {
            let expected = methods.next().unwrap();
            assert_eq!(request["method"], expected);
            if expected == "thread/list" {
                assert_eq!(request["params"]["ancestorThreadId"], "root");
                json!({"data":[{"id":"child","parentThreadId":"root","name":"Review","status":{"type":"notLoaded"},"updatedAt":1_790_416_800}],"nextCursor":null})
            } else {
                assert_eq!(request["params"]["threadId"], "child");
                json!({"data":[{"id":"current-turn","status":"inProgress"}],"nextCursor":null})
            }
    })
    .await;
    let NativeInventory { agents, coverage } = gateway
        .agent_service()
        .native_codex_agents_with_freshness("root", false)
        .await
        .unwrap();
    responder.await.unwrap();
    assert!(!coverage.is_truncated() && coverage.warnings().is_empty());
    assert_eq!(agents.len(), 1);
    assert_eq!(agents[0].execution_id.as_deref(), Some("current-turn"));
    assert_eq!(agents[0].state, State::Working);
    assert_eq!(agents[0].last_active_at, Some(1_790_416_800));
    assert!(agents[0].capabilities.stop);
    assert!(agents[0].capabilities.open_conversation);
    assert!(!agents[0].capabilities.message);
}

fn seed_origin(
    root: &std::path::Path,
    conversation: crate::agents::jobs::model::ConversationIdentity,
    origin: crate::agents::jobs::model::Origin,
    index: usize,
) {
    use crate::agents::jobs::model::*;
    use crate::storage::private_state;
    let job_id = JobId::for_mutation(conversation.provider, &format!("fixture-{index}")).unwrap();
    let agent_id = job_id.as_str().to_owned();
    let job = JobRecord {
        job_id: job_id.clone(),
        agent_id: agent_id.clone(),
        request_fingerprint: None,
        unconfirmed_result: None,
        attention: None,
        notices: Vec::new(),
        created_at_ms: Some(1),
        updated_at_ms: 1,
        revision: 0,
        previous_job_id: None,
        provider_retries: Vec::new(),
        source: JobSource::Imported,
        admitted_membership: None,
        remote_fingerprint: None,
        parent_revision: 0,
        initial_parent: None,
        admission_origin: Some(origin.clone()),
        spec: SpecEvidence::Unknown {
            reason: "No execution fixture".into(),
        },
        recipient: Recipient::None,
        execution: ExecutionState::Terminal {
            terminal: Terminal {
                at_ms: Some(1),
                outcome: JobOutcome::Completed,
                result: ResultEvidence::Unavailable {
                    reason: "No fixture output".into(),
                },
                git: GitSnapshot::Unknown {
                    reason: "No Git fixture".into(),
                },
                completion: Completion::NotRequired,
                cleanup: crate::agents::jobs::model::CleanupState::Complete,
                execution: None,
            },
        },
        stop: StopState::NotRequested,
    };
    let agent = AgentRecord {
        parent: None,
        parent_revision: 0,
        parent_recipient: None,
        agent_id: agent_id.clone(),
        conversation: ConversationBinding::Known { conversation },
        origin,
        tool_scope: Some(ToolScope::Full),
        origin_job_id: Some(job_id.clone()),
        latest_job_id: Some(job_id.clone()),
    };
    for directory in [root.to_owned(), root.join("jobs"), root.join("agents")] {
        private_state::ensure_private_directory(&directory).unwrap();
    }
    private_state::replace(
        &root.join("jobs").join(format!("{}.json", job_id.as_str())),
        &serde_json::to_vec(&job).unwrap(),
    )
    .unwrap();
    private_state::replace(
        &root.join("agents").join(format!(
            "{}.json",
            crate::agents::jobs::store::fingerprint(agent_id.as_bytes())
        )),
        &serde_json::to_vec(&agent).unwrap(),
    )
    .unwrap();
}

#[tokio::test]
async fn user_alert_gate_preserves_roots_and_silences_all_child_events() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    use axum::{Json, Router, extract::State, routing::post};
    let directory = tempfile::tempdir().unwrap();
    let journal_path = directory.path().join("journal");
    let journal = Journal::open_in(journal_path.clone(), 1);
    let (broker_tx, mut broker_rx) = mpsc::channel::<Value>(32);
    let app = Router::new()
        .route(
            "/v1/internal/alert",
            post(
                |State(tx): State<mpsc::Sender<Value>>, Json(body): Json<Value>| async move {
                    tx.send(body).await.unwrap();
                    Json(json!({"apns_id":"fixture"}))
                },
            ),
        )
        .with_state(broker_tx);
    let (address, server) = crate::test_support::serve(app).await;
    let notifier = Arc::new(
        crate::push::PushService::fixture_broker(
            format!("http://{address}"),
            journal.clone(),
            None,
        )
        .await,
    );
    let home = directory.path().join("codex-home");
    std::fs::create_dir_all(&home).unwrap();
    let state_path = directory.path().join("state/turn-state.json");
    let gateway = Gateway::construct_with_apns(
        GatewayConstruction {
            user_name: None,
            codex: Arc::new(CodexAppServer::new_for_test_socket(home)),
            claude_settings: claude_test.settings.clone(),
            journal,
            turn_state_path: Some(state_path.clone()),
            recovery_path: None,
            call_delivery: None,

            external_auth: None,
            external_providers: None,
        },
        notifier,
    );
    let cases = [
        ("0e1a0399-0e3d-5aa4-ace7-0ed28835d55f", None, false),
        ("77a2f659-7b8e-5d46-8561-c26b4b7685c2", Some(true), false),
        (
            "claude_11111111-2222-4333-8444-555555555555",
            Some(true),
            false,
        ),
        ("6407bee6-488b-52bb-a3d5-27c219d415b2", Some(false), true),
        (
            "claude_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            Some(false),
            true,
        ),
        ("84ff411c-7cbe-5039-9bfa-912fc369c611", Some(true), true),
        ("1369ef40-cee5-54eb-b96c-fd8ae3910118", None, false),
        ("48bf3cf7-1b9f-555d-8344-dbaf8fd28653", None, false),
        ("0b46fc9e-7efa-56f4-b838-618003791c5b", None, false),
        ("2178375a-bde2-5ae6-bbea-aa786e82da95", None, false),
        ("da106880-212d-58d2-a240-55890388dadf", None, false),
    ];
    let job_root = state_path.parent().unwrap().join("agent-jobs/v1");
    for (index, (thread, child, _)) in cases.iter().enumerate() {
        if let Some(child) = child {
            let mut identity = gateway.agent_conversation(thread).unwrap();
            if *thread == "84ff411c-7cbe-5039-9bfa-912fc369c611" {
                identity.provider_home = crate::agents::jobs::model::ProviderHome::Known {
                    path: directory.path().join("other-provider-home"),
                };
            }
            let origin = if *child {
                crate::agents::jobs::model::Origin::Parent {
                    conversation: gateway
                        .agent_conversation("8c43d12f-8038-5d28-be95-ef14cc47faf3")
                        .unwrap(),
                }
            } else {
                crate::agents::jobs::model::Origin::TopLevel
            };
            seed_origin(&job_root, identity, origin, index);
        } else if *thread == "1369ef40-cee5-54eb-b96c-fd8ae3910118" {
            seed_origin(
                &job_root,
                gateway.agent_conversation(thread).unwrap(),
                crate::agents::jobs::model::Origin::Unknown {
                    reason: "Historical origin is unresolved".into(),
                },
                index,
            );
        }
    }
    gateway.jobs.initialize().await.unwrap();
    let mut control_rx = crate::test_support::FakeControl::attach(&gateway, 32)
        .await
        .requests;
    let responder_owner = Arc::clone(&gateway);
    let responder = tokio::spawn(async move {
        while let Some(raw) = control_rx.recv().await {
            let request: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(request["method"], "thread/read");
            let thread = request["params"]["threadId"].as_str().unwrap();
            let response = match thread {
                "48bf3cf7-1b9f-555d-8344-dbaf8fd28653" => json!({"thread":{"id":"another-thread"}}),
                "0b46fc9e-7efa-56f4-b838-618003791c5b" => json!({}),
                "2178375a-bde2-5ae6-bbea-aa786e82da95" => json!({"thread":{"id":thread}}),
                "da106880-212d-58d2-a240-55890388dadf" => {
                    json!({"thread":{"id":thread,"source":{"subAgent":"review"}}})
                }
                _ => {
                    json!({"thread":{"id":thread,"source":"appServer","parentThreadId":(thread == "0e1a0399-0e3d-5aa4-ace7-0ed28835d55f").then_some("8c43d12f-8038-5d28-be95-ef14cc47faf3")}})
                }
            };
            responder_owner
                .control_requests
                .lock()
                .unwrap()
                .remove(request["id"].as_str().unwrap())
                .unwrap()
                .send(Ok(response))
                .unwrap();
        }
    });
    let (tx, rx) = mpsc::channel(64);
    let mut expected = HashSet::new();
    for (thread, _, root) in cases {
        // Questions have no outcome; the policy must not key on success or
        // any finite list of terminal outcomes.
        for outcome in [Some("success"), Some("failure"), Some("interrupted"), None] {
            let event = format!("{thread}:{}", outcome.unwrap_or("question"));
            tx.send(ApnsSend {
                collapse_id:event.clone(),title:"Fixture".into(),subtitle:String::new(),body:"Fixture".into(),
                payload:json!({"eventID":event,"sessionID":thread,"source":if thread.starts_with("claude_") {"claude"} else {"codex"},"outcome":outcome,"questionItemID":if outcome.is_none() {Some("q")} else {None}})
            }).await.unwrap();
            if root {
                expected.insert(event);
            }
        }
    }
    drop(tx);
    gateway.apns_completion_loop(rx).await;
    for (thread, _, root) in cases {
        let caller = crate::agents::tools::Caller {
            turn_id: None,
            provider: if thread.starts_with("claude_") {
                crate::providers::Provider::Claude
            } else {
                crate::providers::Provider::Codex
            },
            thread_id: Some(thread.into()),
        };
        let result = crate::agents::tools::dispatch(
            &gateway,
            crate::agents::tools::NOTIFY_USER,
            &json!({"title":"Fixture","body":"Fixture"}),
            &caller,
        )
        .await;
        assert_eq!(
            !result.is_error,
            root,
            "{thread}: {}",
            result.audit()["text"]
        );
        if root {
            expected.insert(format!("agent-notify:{thread}"));
        }
    }
    assert_eq!(
        gateway
            .check_user_alert_ownership(None, "userAlert", None)
            .await,
        Err("missingThreadIdentity")
    );
    let deliveries: Vec<String> = std::iter::from_fn(|| broker_rx.try_recv().ok())
        .map(|body| body["collapse_id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(
        deliveries.len(),
        expected.len(),
        "one broker request per eligible event"
    );
    let actual: HashSet<String> = deliveries.into_iter().collect();
    assert_eq!(actual, expected);
    responder.abort();
    let _ = responder.await;
    drop(gateway);
    // Verify explicit suppressed reasons through the real journal writer;
    // no payload text or credentials are needed for that diagnosis.
    let records = tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let text: String = std::fs::read_dir(&journal_path)
                .unwrap()
                .flatten()
                .filter_map(|entry| std::fs::read_to_string(entry.path()).ok())
                .collect();
            let rows: Vec<Value> = text
                .lines()
                .filter_map(|line| serde_json::from_str(line).ok())
                .collect();
            if rows
                .iter()
                .filter(|row| row["outcome"] == "suppressed")
                .count()
                == 41
            {
                break rows;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(
        records
            .iter()
            .filter(|row| row["reason"] == "delegatedChild")
            .count(),
        20
    );
    assert_eq!(
        records
            .iter()
            .filter(|row| row["reason"] == "ancestryUnavailable")
            .count(),
        20
    );
    assert_eq!(
        records
            .iter()
            .filter(|row| row["reason"] == "missingThreadIdentity")
            .count(),
        1
    );
    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn unavailable_push_registration_never_starts_ancestry_work() {
    let gateway = gateway();
    let mut control_rx = crate::test_support::FakeControl::attach(&gateway, 1)
        .await
        .requests;
    let (tx, rx) = mpsc::channel(1);
    tx.send(ApnsSend {
        collapse_id: "disabled".into(),
        title: String::new(),
        subtitle: String::new(),
        body: String::new(),
        payload: json!({"sessionID":"root","eventID":"disabled"}),
    })
    .await
    .unwrap();
    drop(tx);
    gateway.apns_completion_loop(rx).await;
    let error = gateway
        .send_user_alert("Fixture", "Fixture", Some("root"))
        .await
        .unwrap_err();
    assert!(error.contains("push notifications are unavailable"));
    assert!(control_rx.try_recv().is_err());
}

#[tokio::test]
async fn stalled_ancestry_is_bounded_and_cannot_authorize_an_alert() {
    let gateway = gateway();
    let _control = crate::test_support::FakeControl::attach(&gateway, 1).await;
    let result = tokio::time::timeout(
        Duration::from_secs(3),
        gateway.check_user_alert_ownership(Some("stalled"), "alert", Some("event")),
    )
    .await
    .unwrap();
    assert_eq!(result, Err("ancestryTimeout"));
}

#[tokio::test]
async fn proven_roots_are_not_reported_as_delegated_agents() {
    let gateway = gateway();
    for (thread, parent) in [("root", None), ("child", Some("root"))] {
        gateway.agents.parents.lock().await.insert(
            thread.into(),
            ParentSnapshot {
                at: Instant::now(),
                parent: parent.map(str::to_owned),
                available: true,
            },
        );
    }
    let owners = gateway
        .agent_service()
        .agent_owners(&["root".into(), "child".into()])
        .await;
    assert_eq!(
        owners.owners,
        HashMap::from([("child".into(), "root".into())])
    );
}

#[tokio::test]
async fn unavailable_child_ancestry_is_held_even_when_its_cached_root_is_known() {
    let gateway = gateway();
    for (thread, parent, available) in [("root", None, true), ("child", Some("root"), false)] {
        gateway.agents.parents.lock().await.insert(
            thread.into(),
            ParentSnapshot {
                at: Instant::now(),
                parent: parent.map(str::to_owned),
                available,
            },
        );
    }
    let roots = gateway
        .agent_service()
        .thread_roots(&["root".into(), "child".into()])
        .await;
    assert_eq!(roots, HashMap::from([("root".into(), "root".into())]));
}

#[tokio::test]
async fn runtime_inventory_keeps_healthy_agents_when_one_continuation_is_ambiguous() {
    use crate::agents::jobs::model::*;
    let directory = tempfile::tempdir().unwrap();
    let state = directory.path().join("active-codex-turns.json");
    let gateway = crate::test_support::TestGateway::with_codex(
        Arc::new(CodexAppServer::new_for_test_socket(
            directory.path().join("codex"),
        )),
        Some(state),
    );
    let root = directory.path().join("agent-jobs/v1");
    for index in 1..=3 {
        seed_origin(
            &root,
            gateway
                .agent_conversation(&format!("00000000-0000-4000-8000-{index:012}"))
                .unwrap(),
            Origin::Parent {
                conversation: gateway
                    .agent_conversation("8c43d12f-8038-5d28-be95-ef14cc47faf3")
                    .unwrap(),
            },
            index,
        );
    }
    for (index, sequences) in [(2, vec![4, 5]), (3, vec![3])] {
        let initial = JobId::for_mutation(Provider::Codex, &format!("fixture-{index}")).unwrap();
        let file = root.join("jobs").join(format!("{}.json", initial.as_str()));
        let original: JobRecord = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        for sequence in sequences {
            let mut next = original.clone();
            next.job_id =
                JobId::for_mutation(Provider::Codex, &format!("fixture-{sequence}")).unwrap();
            next.previous_job_id = Some(initial.clone());
            std::fs::write(
                root.join("jobs")
                    .join(format!("{}.json", next.job_id.as_str())),
                serde_json::to_vec(&next).unwrap(),
            )
            .unwrap();
        }
        let file = root.join("agents").join(format!(
            "{}.json",
            crate::agents::jobs::store::fingerprint(original.agent_id.as_bytes())
        ));
        let mut agent: AgentRecord =
            serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        agent.latest_job_id = None;
        std::fs::write(file, serde_json::to_vec(&agent).unwrap()).unwrap();
    }
    let mut control = crate::test_support::FakeControl::attach(&gateway, 32)
        .await
        .requests;
    let owner = Arc::clone(&gateway);
    let responder = tokio::spawn(async move {
        while let Some(raw) = control.recv().await {
            let request: Value = serde_json::from_str(&raw).unwrap();
            let result = match request["method"].as_str().unwrap() {
                "thread/list" => json!({"data":[],"nextCursor":null}),
                "thread/read" => {
                    json!({"thread":{"id":request["params"]["threadId"],"source":"cli","status":{"type":"idle"},"turns":[]}})
                }
                method => panic!("unexpected inventory RPC {method}"),
            };
            owner
                .control_requests
                .lock()
                .unwrap()
                .remove(request["id"].as_str().unwrap())
                .unwrap()
                .send(Ok(result))
                .unwrap();
        }
    });
    let result = gateway
        .cluster_agents_rpc(
            "conversation/agents/list",
            json!({"threadId":"8c43d12f-8038-5d28-be95-ef14cc47faf3"}),
        )
        .await;
    responder.abort();
    let result = result.unwrap();
    let agents = result["agents"].as_array().unwrap();
    assert_eq!(agents.len(), 2);
    let healthy = agents
        .iter()
        .find(|agent| agent["threadId"] == "00000000-0000-4000-8000-000000000001")
        .unwrap();
    assert_eq!(healthy["state"], "completed");
    let ambiguous = agents
        .iter()
        .find(|agent| agent["threadId"] == "00000000-0000-4000-8000-000000000002")
        .unwrap();
    assert_eq!(ambiguous["state"], "unknown");
    assert!(ambiguous["executionId"].is_null());
    for capability in ["message", "continueWork", "stop"] {
        assert_eq!(ambiguous["capabilities"][capability], false);
    }
    let warnings = result["warnings"].as_array().unwrap();
    assert!(warnings.iter().any(|warning| {
        warning
            .as_str()
            .unwrap()
            .contains("conflicting continuation")
    }));
    assert!(
        warnings
            .iter()
            .any(|warning| warning.as_str().unwrap().contains("cycle"))
    );
}

#[tokio::test]
async fn current_parent_tag_overrides_native_provenance_in_headers_and_classification() {
    use crate::agents::jobs::model::*;
    use crate::wire::cluster::AgentAddress;
    let gateway = gateway();
    let identity = gateway.host_identity().await.unwrap();
    let conversation = gateway
        .agent_conversation("0e1a0399-0e3d-5aa4-ace7-0ed28835d55f")
        .unwrap();
    let original_parent = gateway
        .agent_conversation("83fd029c-0ad3-5ed2-8513-781e45c9b22a")
        .unwrap();
    let origin = Origin::Parent {
        conversation: original_parent.clone(),
    };
    let store = gateway.jobs.store().await.unwrap();
    let agent = store
        .adopt_conversation(AgentRecord {
            agent_id: "native-child-tag".into(),
            conversation: ConversationBinding::Known { conversation },
            origin: origin.clone(),
            tool_scope: None,
            origin_job_id: None,
            latest_job_id: None,
            parent: Some(AgentAddress {
                host_id: identity.host_id.clone(),
                thread_id: "83fd029c-0ad3-5ed2-8513-781e45c9b22a".into(),
            }),
            parent_revision: 0,
            parent_recipient: Some(Recipient::Conversation {
                conversation: original_parent,
            }),
        })
        .await
        .unwrap();
    store
        .set_parent(agent.agent_id.clone(), None, Recipient::None)
        .await
        .unwrap();
    let mut header = json!({"thread":{"id":"0e1a0399-0e3d-5aa4-ace7-0ed28835d55f","parentThreadId":"83fd029c-0ad3-5ed2-8513-781e45c9b22a"}});
    gateway.apply_parent_tags(&mut header).await.unwrap();
    assert!(header["thread"]["parent"].is_null());
    assert!(header["thread"]["parentThreadId"].is_null());
    assert!(
        !gateway
            .is_agent_thread("0e1a0399-0e3d-5aa4-ace7-0ed28835d55f")
            .await
            .unwrap()
    );
    let classified = gateway
        .agent_service()
        .classify_runtime(vec!["0e1a0399-0e3d-5aa4-ace7-0ed28835d55f".into()])
        .await
        .unwrap();
    assert_eq!(
        classified["knownRoots"],
        json!(["0e1a0399-0e3d-5aa4-ace7-0ed28835d55f"])
    );
    let address = AgentAddress {
        host_id: crate::ids::new_session_uuid(),
        thread_id: "remote-parent".into(),
    };
    let parent = ConversationIdentity {
        provider: Provider::Codex,
        provider_home: ProviderHome::Known {
            path: "/remote/codex".into(),
        },
        thread_id: address.thread_id.clone(),
    };
    store
        .set_parent(
            agent.agent_id.clone(),
            Some(address.clone()),
            Recipient::Remote {
                host: address.host_id.clone(),
                incarnation: crate::ids::new_session_uuid(),
                conversation: parent,
            },
        )
        .await
        .unwrap();
    let mut header = json!({"thread":{"id":"0e1a0399-0e3d-5aa4-ace7-0ed28835d55f","parentThreadId":"83fd029c-0ad3-5ed2-8513-781e45c9b22a"}});
    gateway.apply_parent_tags(&mut header).await.unwrap();
    assert_eq!(header["thread"]["parent"], json!(address));
    assert!(header["thread"]["parentThreadId"].is_null());
    assert!(header["thread"].get("parentHostID").is_none());
    assert!(
        gateway
            .is_agent_thread("0e1a0399-0e3d-5aa4-ace7-0ed28835d55f")
            .await
            .unwrap()
    );
    let classified = gateway
        .agent_service()
        .classify_runtime(vec!["0e1a0399-0e3d-5aa4-ace7-0ed28835d55f".into()])
        .await
        .unwrap();
    assert_eq!(
        classified["relations"]["0e1a0399-0e3d-5aa4-ace7-0ed28835d55f"]["parentHostID"],
        address.host_id
    );
    assert_eq!(
        classified["relations"]["0e1a0399-0e3d-5aa4-ace7-0ed28835d55f"]["parentThreadId"],
        address.thread_id
    );
    assert_eq!(store.agent(agent.agent_id).await.unwrap().origin, origin);
    let mut malformed =
        json!({"data":[null,7,"invalid",{"id":"0e1a0399-0e3d-5aa4-ace7-0ed28835d55f"}]});
    gateway.apply_parent_tags(&mut malformed).await.unwrap();
    assert_eq!(malformed["data"][0], Value::Null);
    assert_eq!(malformed["data"][3]["parent"], json!(address));
}

#[tokio::test]
async fn remote_parent_pages_have_stable_revisions_and_non_null_titles() {
    use crate::agents::jobs::model::*;
    use crate::wire::cluster::AgentAddress;
    let gateway = gateway();
    let root = gateway
        .turn_state_path
        .as_ref()
        .unwrap()
        .parent()
        .unwrap()
        .join("agent-jobs/v1");
    let conversation = gateway
        .agent_conversation("6e76341f-f81c-5418-b4cb-ebefa71be1c2")
        .unwrap();
    seed_origin(&root, conversation.clone(), Origin::TopLevel, 77);
    let store = gateway.jobs.store().await.unwrap();
    let agent = store
        .agent_for_conversation(conversation)
        .await
        .unwrap()
        .unwrap();
    let address = AgentAddress {
        host_id: crate::ids::new_session_uuid(),
        thread_id: "other-host-parent".into(),
    };
    store
        .set_parent(
            agent.agent_id.clone(),
            Some(address.clone()),
            Recipient::Unknown {
                reason: "fixture remote receiver".into(),
            },
        )
        .await
        .unwrap();
    let page = gateway
        .cluster_agents_rpc("conversation/agents/list", json!({"parent":address}))
        .await
        .unwrap();
    assert_eq!(page["agents"][0]["title"], "Agent");
    assert!(page["revision"].is_string());
    let unchanged = gateway
        .cluster_agents_rpc("conversation/agents/list", json!({"parent":address}))
        .await
        .unwrap();
    assert_eq!(page["revision"], unchanged["revision"]);
    store
        .set_parent(agent.agent_id, None, Recipient::None)
        .await
        .unwrap();
    let empty = gateway
        .cluster_agents_rpc("conversation/agents/list", json!({"parent":address}))
        .await
        .unwrap();
    assert!(empty["agents"].as_array().unwrap().is_empty());
    assert_ne!(page["revision"], empty["revision"]);
}
