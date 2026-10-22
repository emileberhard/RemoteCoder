use super::*;
use crate::agents::Capabilities;
use crate::gateway::{ApnsSend, GatewayConstruction};
use crate::observability::journal::Journal;
use crate::providers::claude::ClaudeSupervisor;
use crate::providers::codex::daemon::CodexAppServer;
use std::collections::HashSet;
use tokio::sync::mpsc;

fn install_launcher_fixture(gateway: &Gateway, directory: &std::path::Path, responses: Value) {
    use std::os::unix::fs::PermissionsExt;
    let program = directory.join("agent-work-fixture");
    std::fs::write(program.with_extension("json"), responses.to_string()).unwrap();
    std::fs::write(
        &program,
        r#"#!/usr/bin/python3
import json,pathlib,sys
request=json.load(sys.stdin)
assert request['schemaVersion']==2
responses=json.loads(pathlib.Path(__file__).with_suffix('.json').read_text())
if request['operation']=='status':
    response=responses['status']
else:
    assert request['operation']=='classify'
    assert len(request['threadIds'])==1 and len(request['homes'])==1
    response=responses[request['threadIds'][0]]
    assert response['coverage']['subjects'][0]['providerHome']==request['homes'][0]
print(json.dumps(response))
"#,
    )
    .unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
    gateway.use_agent_launcher(program);
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

#[tokio::test]
async fn preflight_updates_state_but_journals_only_transitions() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let directory = tempfile::tempdir().unwrap();
    let gateway = crate::test_support::TestGateway::with_journal(
        Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        )),
        claude_test.settings.clone(),
        Arc::new(claude_test),
        Journal::open_in(directory.path().to_path_buf(), 1),
    );
    for (status, time) in [("available", 1), ("available", 2), ("unavailable", 3)] {
        gateway
            .record_notification_ancestry_preflight(json!({"status":status,
            "reasonCodes":if status == "available" { vec![] } else { vec!["indexBuilding"] },
            "checkedAtUnixSeconds":time}))
            .await;
        let index = gateway
            .agents
            .notification_health
            .lock()
            .await
            .index
            .clone();
        assert_eq!(index.unwrap()["checkedAtUnixSeconds"], time);
    }
    tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let records: Vec<Value> = std::fs::read_dir(directory.path())
                .unwrap()
                .flatten()
                .filter_map(|entry| std::fs::read_to_string(entry.path()).ok())
                .flat_map(|text| {
                    text.lines()
                        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
                        .collect::<Vec<_>>()
                })
                .filter(|record| record["event"] == "ancestryPreflight")
                .collect();
            if records
                .last()
                .is_some_and(|record| record["status"] == "unavailable")
            {
                assert_eq!(records.len(), 2);
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn minted_claude_thread_is_a_root_while_a_launch_in_its_home_is_unresolved() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let directory = tempfile::tempdir().unwrap();
    let gateway = gateway();
    let (notifications, _receiver) = mpsc::channel(1);
    let agent = ClaudeSupervisor::new(
        claude_test.settings.clone(),
        notifications,
        Journal::disabled(),
        crate::agents::mcp::McpTokens::default(),
    );
    let minted = crate::providers::claude::claude_thread_id(&agent.mint_session().await.unwrap());
    let resumed = crate::providers::claude::claude_thread_id(&crate::ids::new_session_uuid());
    gateway.set_claude_agent(agent);
    let home = gateway.agent_home_for_thread(&minted).unwrap();
    let pending = |thread: &str| {
        json!({"schemaVersion":2,"coverage":{"status":"incomplete","reasonCodes":["identityPending"],
        "subjects":[{"providerHome":home,"threadId":thread,"status":"incomplete",
        "reasonCodes":["identityPending"],"relation":{"kind":"unknown"}}]}})
    };
    let mut responses = serde_json::Map::new();
    responses.insert(minted.clone(), pending(&minted));
    responses.insert(resumed.clone(), pending(&resumed));
    install_launcher_fixture(&gateway, directory.path(), Value::Object(responses));

    assert!(!gateway.is_agent_thread(&minted).await.unwrap());
    let error = gateway.is_agent_thread(&resumed).await.unwrap_err();
    assert_eq!(coverage_failure_codes(&error), ["identityPending"]);
}

#[tokio::test]
async fn launcher_preflight_is_visible_bounded_telemetry_and_has_an_owned_task() {
    let directory = tempfile::tempdir().unwrap();
    let gateway = gateway();
    install_launcher_fixture(
        &gateway,
        directory.path(),
        json!({"status":{
            "schemaVersion":2,"supportedVersions":[1,2],"supportedOperations":["status","classify","reindex"],
            "coverage":{"status":"unavailable","reasonCodes":["indexBuilding"]}
        }}),
    );
    assert!(
        gateway
            .agents
            .notification_health
            .lock()
            .await
            .index
            .is_none()
    );
    gateway.start_notification_ancestry_preflight().await;
    tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let index = gateway
                .agents
                .notification_health
                .lock()
                .await
                .index
                .clone();
            if index.is_some_and(|index| index["status"] == "unavailable") {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    let index = gateway
        .agents
        .notification_health
        .lock()
        .await
        .index
        .clone();
    assert_eq!(index.unwrap()["reasonCodes"], json!(["indexBuilding"]));
    assert!(!gateway.is_draining());
    gateway.stop_notification_ancestry_preflight().await;
    assert!(
        gateway
            .agents
            .notification_preflight_task
            .lock()
            .await
            .is_none()
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

#[test]
fn launcher_action_admits_its_actual_target_thread() {
    let gateway = gateway();
    let _compaction = gateway.admission.admit_compaction("child").unwrap();
    for action in ["message", "continue"] {
        assert!(
            gateway
                .admit_launcher_action_target(action, Some("child"))
                .is_err()
        );
        assert!(
            gateway
                .admit_launcher_action_target(action, Some("unrelated"))
                .is_ok()
        );
        assert!(gateway.admit_launcher_action_target(action, None).is_err());
    }
    assert!(
        gateway
            .admit_launcher_action_target("stop", Some("child"))
            .is_ok()
    );
}

fn gateway() -> crate::test_support::TestGateway {
    crate::test_support::TestGateway::new()
}

#[test]
fn discovery_round_two_stale_launcher_projection_is_incomplete() {
    assert_eq!(
        InventoryCoverage::read(
            false,
            &["Launcher list coverage incomplete: indexStale".into()]
        ),
        InventoryCoverage::Incomplete
    );
    assert_eq!(
        InventoryCoverage::read(false, &[]),
        InventoryCoverage::Complete
    );
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
    let gateway = Gateway::construct_with_apns(
        GatewayConstruction {
            user_name: None,
            codex: Arc::new(CodexAppServer::new(
                PathBuf::from("/bin/true"),
                HashMap::new(),
            )),
            claude_settings: claude_test.settings.clone(),
            journal,
            turn_state_path: None,
            recovery_path: None,
            call_delivery: None,

            external_auth: None,
        },
        notifier,
    );
    // Exercise the real subprocess wire against an isolated fixture; never
    // call an installed launcher or alter shared process environment.
    let cases = [
        ("native-child", false, false),
        ("codex-child", true, false),
        ("claude_child", true, false),
        ("codex-root", false, true),
        ("claude_root", false, true),
        ("same-id-other-home", true, true),
        ("unknown-coverage", false, false),
        ("wrong-native-identity", false, false),
        ("missing-native-identity", false, false),
        ("missing-native-source", false, false),
        ("native-review-child", false, false),
    ];
    let mut responses = serde_json::Map::new();
    for (thread, launcher_child, _) in cases {
        let home = gateway.agent_home_for_thread(thread).unwrap();
        let mut subject = json!({"providerHome":home,"threadId":thread,"status":"complete","reasonCodes":[],
            "relation":{"kind":if launcher_child && thread != "same-id-other-home" {"child"} else {"root"},
                "parentHome":null,"parentThreadId":null}});
        if thread == "unknown-coverage" {
            subject["status"] = json!("incomplete");
            subject["reasonCodes"] = json!(["unscopedLaunchAttempt"]);
            subject["relation"]["kind"] = json!("unknown");
        }
        responses.insert(thread.into(), json!({"schemaVersion":2,
            // Unrelated incomplete/malformed records cannot poison proof.
            "data":[{"threadId":"unknown:unrelated"}],"warnings":["Unrelated legacy warning"],
            "coverage":{"status":"incomplete","reasonCodes":["lineageUnknown"],"subjects":[subject,
                {"providerHome":"/another-provider-home","threadId":thread,"status":"complete","reasonCodes":[],"relation":{"kind":"child"}},
                {"providerHome":home,"threadId":"unrelated","status":"futureStatus","reasonCodes":["futureReason"]}]}}));
    }
    install_launcher_fixture(&gateway, directory.path(), Value::Object(responses));
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
                "wrong-native-identity" => json!({"thread":{"id":"another-thread"}}),
                "missing-native-identity" => json!({}),
                "missing-native-source" => json!({"thread":{"id":thread}}),
                "native-review-child" => {
                    json!({"thread":{"id":thread,"source":{"subAgent":"review"}}})
                }
                _ => {
                    json!({"thread":{"id":thread,"source":"appServer","parentThreadId":(thread == "native-child").then_some("parent")}})
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
