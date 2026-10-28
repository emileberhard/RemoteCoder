use std::path::PathBuf;

use axum::Router;
use axum::extract::ws::WebSocketUpgrade;
use axum::routing::get;
use serde_json::json;
use tokio::net::{TcpStream, UnixListener};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, accept_async, connect_async};

use super::*;
use crate::gateway::turn_state::{
    is_terminal_turn_for_pending, note_item_completed, note_turn_started,
    resumed_turn_terminal_status,
};
use crate::notifications::history::NotificationOrigin;
use crate::observability::journal::Source;
use crate::providers::codex::daemon::CodexAppServer;
use crate::rpc::PENDING_REQUEST_TTL;
use crate::rpc::dispatch::{
    ClaudeMethod, DispatchPlan, OwnedRoute, RequestLifetime, method_spec, starts_new_work,
};
use crate::rpc::error::RpcCode;
use crate::rpc::{
    HISTORY_PAGE_RESPONSE_BUDGET, PendingRequest, RpcError, oversized_history_page_error,
    prune_pending_requests,
};
use crate::runtime::recovery::{RecoveryJournal, RecoveryPhase, RecoveryTaskStatus};
use crate::time::unix_seconds;
use crate::turns::MAX_UNTRACKED_TURN_CONTEXTS;
use crate::turns::PromptContext;
use crate::voice::handoff::VoiceDelegations;
use crate::voice::session::{
    VOICE_CALL_AGENT_ENDED_ERROR, VOICE_MODE_GREETING, VOICE_MODE_PROMPT, VoiceSession,
    VoiceSessionOrigin, VoiceSessionOwner,
};
use crate::wire::gateway::RealtimeVoiceStartRequest;
use futures_util::{SinkExt, StreamExt};
use std::time::Instant;
use tokio::task::JoinSet;

const PHONE: NotificationOrigin = NotificationOrigin::Client {
    id: 1,
    opened_after: 0,
};
pub(super) const CONTROL: NotificationOrigin = NotificationOrigin::Control { opened_after: 0 };

pub(super) fn test_client(id: u64, tx: mpsc::Sender<ClientCommand>) -> ClientTx {
    ClientTx {
        grant: crate::auth::installation_credentials::Grant::Operator,
        content_subscriptions: Arc::default(),
        query_response: None,
        installation_id: None,
        id,
        tx,
        closed: tokio_util::sync::CancellationToken::new(),
    }
}

fn test_gateway() -> crate::test_support::TestGateway {
    crate::test_support::TestGateway::new()
}

fn request(method: &str, params: Value) -> serde_json::Map<String, Value> {
    let Value::Object(obj) = json!({"id": 1, "method": method, "params": params}) else {
        unreachable!()
    };
    obj
}

async fn next_client_reply(websocket: &mut WebSocketStream<MaybeTlsStream<TcpStream>>) -> Value {
    loop {
        let frame = next_client_json(websocket).await;
        if frame.get("method").is_none() {
            return frame;
        }
    }
}

async fn next_client_json(websocket: &mut WebSocketStream<MaybeTlsStream<TcpStream>>) -> Value {
    loop {
        let frame = websocket
            .next()
            .await
            .expect("client WebSocket closed")
            .expect("client frame");
        if let UpstreamMessage::Text(raw) = frame {
            let value: Value = serde_json::from_str(&raw).expect("client JSON");
            if value["method"] != "daemon/ready" {
                return value;
            }
        }
    }
}

async fn send_client_json(
    websocket: &mut WebSocketStream<MaybeTlsStream<TcpStream>>,
    value: Value,
) {
    websocket
        .send(UpstreamMessage::Text(
            serde_json::to_string(&value).expect("JSON"),
        ))
        .await
        .expect("client send");
}

#[test]
fn claude_route_respects_thread_identity_provider_and_owned_methods() {
    // A Codex thread id wins over a mislabelled provider: the id is authoritative.
    for (method, params, expected) in [
        ("turn/start", json!({"threadId": "claude_abc"}), true),
        ("turn/steer", json!({"threadId": "claude_abc"}), true),
        (
            "claude/thread/release",
            json!({"threadId": "claude_abc"}),
            true,
        ),
        (
            "thread/name/set",
            json!({"threadId": "claude_abc", "name": "Nightly"}),
            false,
        ),
        (
            "thread/name/set",
            json!({"threadId": "0199-codex-thread", "name": "Nightly"}),
            false,
        ),
        (
            "turn/start",
            json!({"threadId": "0199-codex-thread"}),
            false,
        ),
        (
            "thread/start",
            json!({"provider": "claude", "cwd": "/tmp"}),
            true,
        ),
        ("thread/start", json!({"cwd": "/tmp"}), false),
        (
            "turn/start",
            json!({"threadId": "0199-codex-thread", "provider": "claude"}),
            false,
        ),
        ("initialize", json!({"provider": "claude"}), false),
        ("command/exec", json!({"provider": "claude"}), false),
        ("fs/readDirectory", json!({"provider": "claude"}), false),
        ("daemon/activeTurns", json!({"provider": "claude"}), false),
        ("thread/fork", json!({"threadId": "claude_abc"}), true),
        (
            "thread/fork",
            json!({"threadId": "0199-codex-thread"}),
            false,
        ),
        ("thread/archive", json!({"threadId": "claude_abc"}), false),
        ("thread/unarchive", json!({"threadId": "claude_abc"}), false),
    ] {
        assert_eq!(
            crate::rpc::dispatch::claude_route(method, &request(method, params.clone())),
            expected,
            "{method}: {params}"
        );
    }
}

#[test]
fn draining_rejects_only_new_work() {
    assert!(starts_new_work("turn/start"));
    assert!(starts_new_work("voice/session/start"));
    assert!(starts_new_work("conversation/title/regenerate"));
    assert!(starts_new_work("thread/fork"));
    assert!(!starts_new_work("turn/steer"));
    assert!(!starts_new_work("turn/interrupt"));
    assert!(!starts_new_work("daemon/activeTurns"));
}

#[test]
fn method_specs_keep_owned_routing_and_request_budgets() {
    for (method, expected) in [
        ("calls/status", Some(RequestLifetime::Query)),
        ("calls/stop", Some(RequestLifetime::Urgent)),
        ("calls/media/attach", Some(RequestLifetime::Command)),
        ("navigation/status", Some(RequestLifetime::Query)),
        ("navigation/stop", Some(RequestLifetime::Urgent)),
        ("conversation/metadata/read", Some(RequestLifetime::Query)),
        ("conversation/marks/read", Some(RequestLifetime::Query)),
        ("conversation/marks/update", Some(RequestLifetime::Command)),
        ("directory/favorites/read", Some(RequestLifetime::Query)),
        ("directory/favorites/update", Some(RequestLifetime::Command)),
        ("preferences/read", Some(RequestLifetime::Query)),
        ("preferences/update", Some(RequestLifetime::Command)),
        (
            "conversation/projects/resolve",
            Some(RequestLifetime::Query),
        ),
        (
            "conversation/metadata/custom",
            Some(RequestLifetime::Command),
        ),
        ("voice/session/start", Some(RequestLifetime::Command)),
        ("voice/session/stop", Some(RequestLifetime::Urgent)),
        ("devices/register", Some(RequestLifetime::Command)),
        ("devices/unregister", Some(RequestLifetime::Urgent)),
        ("host/info", Some(RequestLifetime::Status)),
        ("thread/name/set", Some(RequestLifetime::Command)),
        (
            "conversation/title/regenerate",
            Some(RequestLifetime::Command),
        ),
        ("command/exec", None),
    ] {
        let lifetime = match DispatchPlan::parse(&json!({"id": 1, "method": method}).to_string()) {
            DispatchPlan::Request(request) => request.owned.map(|owned| owned.lifetime),
            _ => panic!("{method} is not a request"),
        };
        assert_eq!(lifetime, expected, "{method}");
    }
    assert!(matches!(
        method_spec("thread/name/set").route,
        OwnedRoute::Rename
    ));
    assert!(matches!(method_spec("calls/host").route, OwnedRoute::Calls));
    assert!(matches!(
        method_spec("devices/register").route,
        OwnedRoute::Devices
    ));
    assert!(matches!(
        method_spec("navigation/next").route,
        OwnedRoute::Navigation
    ));
    assert!(matches!(
        method_spec("turn/interrupt").route,
        OwnedRoute::Interrupt
    ));
    assert!(matches!(
        method_spec("daemon/activeTurns").route,
        OwnedRoute::ActiveTurns
    ));
}

#[tokio::test]
async fn host_info_reports_the_gateway_home_directory() {
    let gateway = test_gateway();
    let (tx, mut rx) = mpsc::channel(1);
    let mut object = request("host/info", json!({}));
    object.insert("id".to_string(), json!(7));
    let target = match DispatchPlan::parse(&Value::Object(object.clone()).to_string()) {
        DispatchPlan::Request(request) => request.owned.expect("gateway-owned method").target,
        _ => panic!("host/info is not a request"),
    };
    gateway
        .handle_owned_rpc(1, &test_client(1, tx), "host/info", target, &object)
        .await
        .expect("host/info");
    let Some(ClientCommand::Text(text)) = rx.recv().await else {
        panic!("expected a JSON reply")
    };
    let reply: Value = serde_json::from_str(&text).expect("reply json");
    let home = std::env::var("HOME").expect("HOME");
    assert_eq!(reply["id"], 7);
    assert_eq!(reply["result"]["homeDirectory"], home);
    assert_eq!(reply["result"]["speechAvailable"], true);
    assert_eq!(
        reply["result"]["automationsAuthority"],
        json!(crate::config::host_profile::AutomationAuthority::authority().unwrap())
    );
}

#[test]
fn resumed_history_proves_only_an_exact_terminal_turn() {
    let response = json!({
        "result": {
            "thread": {
                "turns": [
                    {"id": "older", "status": "completed"},
                    {"id": "target", "status": "interrupted"},
                    {"id": "newer", "status": "inProgress"}
                ]
            }
        }
    });

    assert_eq!(
        resumed_turn_terminal_status(&response, "target"),
        Some("interrupted")
    );
    assert_eq!(resumed_turn_terminal_status(&response, "newer"), None);
    assert_eq!(resumed_turn_terminal_status(&response, "missing"), None);
}

#[tokio::test]
async fn active_turn_inventory_unions_gateway_and_app_server_sources() {
    let gateway = test_gateway();
    {
        let mut core = gateway.core.lock().await;
        core.turns.mark_active(
            &TurnKey::new("thread-gateway", "turn-gateway"),
            10.0,
            None,
            Some(1),
        );
        core.app_server_active_turns_by_thread.insert(
            "thread-direct".to_string(),
            AppServerActiveTurn {
                thread_id: "thread-direct".to_string(),
                turn_id: "turn-direct".to_string(),
                started_at_unix_seconds: Some(11.0),
                last_seen_at_unix_seconds: 12.0,
            },
        );
        core.app_server_inventory_bootstrapped = true;
    }

    assert_eq!(gateway.reported_active_turn_status().await, (2, true));

    let (tx, mut rx) = mpsc::channel(1);
    gateway
        .handle_daemon_active_turns(&test_client(1, tx), Some(json!(9)))
        .await
        .expect("active-turn response");
    let Some(ClientCommand::Text(payload)) = rx.recv().await else {
        panic!("missing active-turn response");
    };
    let response: Value = serde_json::from_str(&payload).expect("active-turn JSON");
    assert_eq!(response["result"]["appServerInventoryAvailable"], true);
    let active = response["result"]["activeTurns"]
        .as_array()
        .expect("active turns");
    assert_eq!(active.len(), 2);
    assert!(active.iter().any(|turn| turn["source"] == "gateway"));
    assert!(active.iter().any(|turn| turn["source"] == "appServer"));
}

#[tokio::test]
async fn inactive_app_server_status_removes_the_passive_turn() {
    let gateway = test_gateway();
    {
        let mut core = gateway.core.lock().await;
        core.app_server_active_turns_by_thread.insert(
            "thread-direct".to_string(),
            AppServerActiveTurn {
                thread_id: "thread-direct".to_string(),
                turn_id: "turn-direct".to_string(),
                started_at_unix_seconds: None,
                last_seen_at_unix_seconds: 1.0,
            },
        );
        core.app_server_inventory_bootstrapped = true;
    }

    gateway
        .handle_app_server_status_notification(&json!({
            "method": "thread/status/changed",
            "params": {
                "threadId": "thread-direct",
                "status": {"type": "idle"}
            }
        }))
        .await;

    let core = gateway.core.lock().await;
    assert!(core.app_server_active_turns_by_thread.is_empty());
    assert!(core.app_server_inventory_bootstrapped);
    assert!(core.app_server_inventory_unresolved_threads.is_empty());
}

#[tokio::test]
async fn active_status_keeps_inventory_unavailable_when_lookup_fails() {
    let gateway = test_gateway();
    gateway.core.lock().await.app_server_inventory_bootstrapped = true;
    let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 1)
        .await
        .requests;

    gateway
        .handle_app_server_status_notification(&json!({
            "method": "thread/status/changed",
            "params": {
                "threadId": "thread-direct",
                "status": {"type": "active"}
            }
        }))
        .await;

    let request: Value =
        serde_json::from_str(&out_rx.recv().await.expect("turn inventory request"))
            .expect("request JSON");
    assert_eq!(gateway.reported_active_turn_status().await, (0, false));
    gateway
        .handle_control_text(
            serde_json::to_string(&json!({
                "jsonrpc": "2.0",
                "id": request["id"],
                "error": {"code": -32000, "message": "projection unavailable"}
            }))
            .expect("response JSON"),
            CONTROL,
        )
        .await;
    tokio::task::yield_now().await;
    assert_eq!(gateway.reported_active_turn_status().await, (0, false));

    gateway
        .handle_app_server_status_notification(&json!({
            "method": "thread/status/changed",
            "params": {
                "threadId": "thread-direct",
                "status": {"type": "idle"}
            }
        }))
        .await;
    assert_eq!(gateway.reported_active_turn_status().await, (0, true));
}

#[tokio::test]
async fn threads_without_turn_history_require_authoritative_idle_readback() {
    let claude_test =
        Arc::new(crate::providers::claude::settings::ClaudeSettings::isolated_for_test());
    let unmaterialized = "thread ephemeral is not materialized yet; thread/turns/list is unavailable before first user message";
    let ephemeral_error = "ephemeral threads do not support thread/turns/list";
    for (error, ephemeral, status, succeeds, resolved) in [
        (ephemeral_error, true, json!({"type":"idle"}), true, true),
        (ephemeral_error, true, json!({"type":"active"}), true, false),
        (ephemeral_error, true, Value::Null, true, false),
        (ephemeral_error, false, json!({"type":"idle"}), false, false),
        (unmaterialized, false, json!({"type":"idle"}), true, true),
        (unmaterialized, false, json!({"type":"active"}), true, false),
    ] {
        let codex = Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        ));
        let gateway = crate::test_support::TestGateway::with_settings(
            codex,
            claude_test.settings.clone(),
            Arc::clone(&claude_test),
        );
        {
            let mut core = gateway.core.lock().await;
            core.app_server_inventory_bootstrapped = true;
            core.app_server_inventory_unresolved_threads
                .insert("ephemeral".into());
        }
        let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 1)
            .await
            .requests;
        let worker_gateway = gateway.clone();
        let worker = tokio::spawn(async move {
            worker_gateway
                .refresh_app_server_active_turn("ephemeral".into(), 0)
                .await
        });
        for (method, reply) in [
            (
                "thread/turns/list",
                json!({"error":{"code":-32600,"message":error}}),
            ),
            (
                "thread/read",
                json!({"result":{"thread":{"ephemeral":ephemeral,"status":status}}}),
            ),
        ] {
            let request: Value =
                serde_json::from_str(&out_rx.recv().await.expect("inventory request"))
                    .expect("request JSON");
            assert_eq!(request["method"], method);
            let mut response = reply;
            response["id"] = request["id"].clone();
            gateway
                .handle_control_text(response.to_string(), CONTROL)
                .await;
        }
        assert_eq!(worker.await.expect("inventory task").is_ok(), succeeds);
        assert_eq!(gateway.reported_active_turn_status().await, (0, resolved));
    }
}

#[tokio::test]
async fn inactive_thread_finishes_its_unobserved_turn_exactly_once() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let state_dir = tempfile::tempdir().expect("state directory");
    let state_path = state_dir.path().join("turn-state.json");
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let gateway = Gateway::with_turn_state(
        codex,
        claude_test.settings.clone(),
        Journal::disabled(),
        Some(state_path.clone()),
    );
    let mut control = crate::test_support::FakeControl::attach(&gateway, 1).await;
    let (completion_tx, mut completion_rx) = mpsc::channel(4);
    *gateway.apns_completion_tx.lock().await = Some(completion_tx);
    let (live_activity_tx, mut live_activity_rx) =
        tokio::sync::watch::channel(ActiveTasksLiveActivitySnapshot::default());
    *gateway.apns_live_activity_tx.lock().await = Some(live_activity_tx);

    gateway
        .capture_agent_message(&message(
            "turn/started",
            json!({
                "threadId": "thread-desktop",
                "turn": {"id": "019a-desktop", "status": "inProgress"}
            }),
        ))
        .await
        .expect("passively observed turn start");
    gateway
        .handle_app_server_status_notification(&json!({
            "method": "thread/status/changed",
            "params": {"threadId": "thread-desktop", "status": {"type": "idle"}}
        }))
        .await;

    let request: Value = serde_json::from_str(
        &tokio::time::timeout(Duration::from_secs(30), control.requests.recv())
            .await
            .expect("turn lookup was not requested")
            .expect("turn lookup request"),
    )
    .expect("request JSON");
    assert_eq!(request["method"], "thread/turns/list");
    assert_eq!(request["params"]["threadId"], "thread-desktop");
    gateway
        .handle_control_text(
            serde_json::to_string(&json!({
                "jsonrpc": "2.0",
                "id": request["id"],
                "result": {"data": [{"id": "019a-desktop", "status": "completed"}]}
            }))
            .expect("response JSON"),
            CONTROL,
        )
        .await;

    let push = tokio::time::timeout(Duration::from_secs(30), completion_rx.recv())
        .await
        .expect("completion push was not sent")
        .expect("completion push");
    assert_eq!(push.payload["sessionID"], "thread-desktop");
    assert_eq!(push.payload["outcome"], "success");
    live_activity_rx
        .changed()
        .await
        .expect("Live Activity update");
    assert!(live_activity_rx.borrow_and_update().running.is_empty());
    let finished: Value = serde_json::from_slice(
        &tokio::fs::read(state_path.with_file_name("live-activity-finished-turns.json"))
            .await
            .expect("persisted finished turns"),
    )
    .expect("finished turns JSON");
    assert!(finished.get("thread-desktop").is_some());
    {
        let core = gateway.core.lock().await;
        assert_eq!(core.turns.active_count(), 0);
        assert_eq!(core.turns.context_count(), 0);
    }
    let persisted: DurableTurnState =
        serde_json::from_slice(&tokio::fs::read(&state_path).await.expect("persisted state"))
            .expect("persisted state JSON");
    assert!(persisted.active_turns_by_key.is_empty());
    assert!(persisted.turn_ctx_by_key.is_empty());

    gateway
        .record_agent_notification(
            &frame(
                "turn/completed",
                json!({
                    "threadId": "thread-desktop",
                    "turn": {"id": "019a-desktop", "status": "completed"}
                }),
            ),
            CONTROL,
        )
        .await;
    assert!(completion_rx.try_recv().is_err());
}

#[tokio::test]
async fn ended_turn_lookup_never_finishes_a_running_recovering_or_draining_turn() {
    let gateway = test_gateway();
    let mut control = crate::test_support::FakeControl::attach(&gateway, 1).await;
    let (completion_tx, mut completion_rx) = mpsc::channel(4);
    *gateway.apns_completion_tx.lock().await = Some(completion_tx);
    let turn = {
        let mut core = gateway.core.lock().await;
        core.turns.mark_active(
            &TurnKey::new("thread-1", "019a-running"),
            10.0,
            None,
            Some(1),
        );
        core.turns
            .active_turn(&TurnKey::new("thread-1", "019a-running"))
            .cloned()
            .expect("active turn")
    };

    answer_ended_turn_lookup(
        &gateway,
        &mut control.requests,
        &turn,
        json!([
            {"id": "019a-running", "status": "inProgress"},
            {"id": "019a-previous", "status": "completed"}
        ]),
    )
    .await;
    assert_eq!(gateway.reported_active_turn_status().await.0, 1);

    gateway
        .core
        .lock()
        .await
        .recovered_turn_keys
        .insert(TurnKey::new("thread-1", "019a-running"));
    answer_ended_turn_lookup(
        &gateway,
        &mut control.requests,
        &turn,
        json!([{"id": "019a-running", "status": "interrupted"}]),
    )
    .await;
    assert_eq!(gateway.reported_active_turn_status().await.0, 1);

    gateway
        .core
        .lock()
        .await
        .recovered_turn_keys
        .remove(&TurnKey::new("thread-1", "019a-running"));
    gateway.draining.store(true, Ordering::Release);
    answer_ended_turn_lookup(
        &gateway,
        &mut control.requests,
        &turn,
        json!([{"id": "019a-running", "status": "interrupted"}]),
    )
    .await;
    assert_eq!(gateway.reported_active_turn_status().await.0, 1);
    assert!(completion_rx.try_recv().is_err());
}

async fn answer_ended_turn_lookup(
    gateway: &Arc<Gateway>,
    control_rx: &mut mpsc::Receiver<String>,
    turn: &ActiveTurn,
    page: Value,
) {
    let reconcile = gateway.finish_turns_the_app_server_ended(&turn.thread_id, vec![turn.clone()]);
    let respond = async {
        let request: Value =
            serde_json::from_str(&control_rx.recv().await.expect("lookup request"))
                .expect("request JSON");
        gateway
            .handle_control_text(
                serde_json::to_string(&json!({
                    "jsonrpc": "2.0",
                    "id": request["id"],
                    "result": {"data": page}
                }))
                .expect("response JSON"),
                CONTROL,
            )
            .await;
    };
    let (result, ()) = tokio::join!(reconcile, respond);
    result.expect("ended-turn lookup");
}

#[tokio::test]
async fn rejected_turn_start_drops_only_its_correlated_pending_context() {
    let gateway = test_gateway();
    {
        let mut core = gateway.core.lock().await;
        core.turns.mark_active(
            &TurnKey::new("thread-1", "existing"),
            unix_seconds(),
            None,
            Some(7),
        );
    }
    let first = request(
        "turn/start",
        json!({"threadId": "thread-1", "input": [{"type": "text", "text": "first"}]}),
    );
    let mut second = request(
        "turn/start",
        json!({"threadId": "thread-1", "input": [{"type": "text", "text": "second"}]}),
    );
    second.insert("id".to_string(), json!(2));

    gateway
        .capture_client_request_locked(7, &first)
        .await
        .expect("capture first request");
    gateway
        .capture_client_request_locked(7, &second)
        .await
        .expect("capture second request");
    gateway
        .capture_turn_start_response(
            7,
            &json!({"id": 1, "error": {"code": -32602, "message": "rejected"}}),
        )
        .await
        .expect("capture rejection");

    let core = gateway.core.lock().await;
    assert_eq!(core.turns.pending().count(), 1);
    assert_eq!(
        core.turns
            .pending()
            .next()
            .map(|(_, pending)| pending.context.preview.as_str()),
        Some("second")
    );
    assert_eq!(
        core.turns
            .pending()
            .next()
            .and_then(|(_, pending)| pending.previous_turn_id.as_deref()),
        Some("existing")
    );
}

#[tokio::test]
async fn claude_start_responses_clear_their_correlated_pending_context() {
    let gateway = test_gateway();
    let (tx, _rx) = mpsc::channel(4);
    let client = test_client(7, tx);
    let first = request(
        "turn/start",
        json!({"threadId": "claude_session", "input": [{"type": "text", "text": "first"}]}),
    );
    gateway
        .capture_client_request_locked(client.id, &first)
        .await
        .expect("capture first Claude request");
    gateway
        .respond(
            &client,
            json!(1),
            Err(RpcError::new(RpcCode::InvalidParams, "rejected")),
            Some("turn/start"),
        )
        .await
        .expect("send Claude rejection");
    assert!(gateway.core.lock().await.turns.pending().next().is_none());

    let mut second = request(
        "turn/start",
        json!({"threadId": "claude_session", "input": [{"type": "text", "text": "second"}]}),
    );
    second.insert("id".to_string(), json!(2));
    gateway
        .capture_client_request_locked(client.id, &second)
        .await
        .expect("capture second Claude request");
    gateway
        .respond(
            &client,
            json!(2),
            Ok(json!({"turn": {"id": "turn_2", "status": "inProgress", "items": []}})),
            Some("turn/start"),
        )
        .await
        .expect("send accepted Claude start");

    let core = gateway.core.lock().await;
    assert!(core.turns.pending().next().is_none());
    let active = core
        .turns
        .active_turn(&TurnKey::new("claude_session", "turn_2"))
        .expect("accepted Claude turn");
    assert_eq!(active.owner_client_id, client.id);
    assert_eq!(
        core.turns
            .context(&TurnKey::new("claude_session", "turn_2"))
            .map(|context| context.prompt_preview.as_str()),
        Some("second")
    );
}

#[tokio::test]
async fn claude_disconnects_never_spawn_codex_recovery_observers() {
    let gateway = test_gateway();
    {
        let mut core = gateway.core.lock().await;
        core.turns.mark_active(
            &TurnKey::new("claude_session", "turn"),
            unix_seconds(),
            None,
            Some(7),
        );
        core.turns.insert_pending(
            "7:1".to_string(),
            PendingTurnStart {
                thread_id: "claude_pending".to_string(),
                context: PromptContext {
                    compaction: false,
                    preview: "pending".to_string(),
                    cwd: None,
                    owner_client_id: 7,
                },
                previous_turn_id: None,
                client_user_message_id: None,
                created_at_unix_seconds: unix_seconds(),
            },
        );
    }

    gateway.spawn_observers_for_client(7).await;
    gateway.spawn_persisted_observers().await;
    assert!(gateway.observer_tasks.lock().await.is_empty());
}

#[tokio::test]
async fn accepted_turn_start_is_durable_before_notifications_arrive() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let directory = tempfile::tempdir().expect("turn state directory");
    let state_path = directory.path().join("active-turns.json");
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let gateway = Gateway::with_turn_state(
        Arc::clone(&codex),
        claude_test.settings.clone(),
        Journal::disabled(),
        Some(state_path.clone()),
    );
    let start = request(
        "turn/start",
        json!({"threadId": "thread-1", "input": [{"type": "text", "text": "persist me"}]}),
    );
    gateway
        .capture_client_request_locked(7, &start)
        .await
        .expect("capture start request");
    gateway
        .capture_turn_start_response(
            7,
            &json!({"id": 1, "result": {"turn": {"id": "turn-1", "status": "inProgress"}}}),
        )
        .await
        .expect("capture accepted start");

    let restored = Gateway::with_turn_state(
        codex,
        claude_test.settings.clone(),
        Journal::disabled(),
        Some(state_path),
    );
    restored.load_turn_state().await.expect("restore state");
    let core = restored.core.lock().await;
    assert!(core.turns.pending().next().is_none());
    assert_eq!(
        core.turns
            .active_turn(&TurnKey::new("thread-1", "turn-1"))
            .map(|turn| turn.turn_id.as_str()),
        Some("turn-1")
    );
    assert_eq!(
        core.turns
            .context(&TurnKey::new("thread-1", "turn-1"))
            .map(|context| context.prompt_preview.as_str()),
        Some("persist me")
    );
    assert_eq!(
        std::fs::metadata(directory.path().join("active-turns.json"))
            .expect("state metadata")
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
}

#[tokio::test]
async fn durable_state_excludes_claude_and_seeds_client_ids() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let directory = tempfile::tempdir().expect("turn state directory");
    let state_path = directory.path().join("active-turns.json");
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let gateway = Gateway::with_turn_state(
        Arc::clone(&codex),
        claude_test.settings.clone(),
        Journal::disabled(),
        Some(state_path.clone()),
    );
    {
        let mut core = gateway.core.lock().await;
        core.turns.mark_active(
            &TurnKey::new("thread-codex", "turn-codex"),
            unix_seconds(),
            None,
            Some(41),
        );
        core.turns.mark_active(
            &TurnKey::new("claude_session", "turn-claude"),
            unix_seconds(),
            None,
            Some(99),
        );
        core.turns.insert_pending(
            "52:1".to_string(),
            PendingTurnStart {
                thread_id: "thread-pending".to_string(),
                context: PromptContext {
                    compaction: false,
                    preview: "pending".to_string(),
                    cwd: None,
                    owner_client_id: 52,
                },
                previous_turn_id: None,
                client_user_message_id: None,
                created_at_unix_seconds: unix_seconds(),
            },
        );
        core.turns.note_last_message(
            TurnKey::new("claude_session", "turn-claude"),
            "claude".to_string(),
            unix_seconds(),
        );
    }
    gateway.commit_turn_state().await.expect("persist state");

    let restored = Gateway::with_turn_state(
        codex,
        claude_test.settings.clone(),
        Journal::disabled(),
        Some(state_path),
    );
    restored.load_turn_state().await.expect("restore state");
    let core = restored.core.lock().await;
    assert!(
        core.turns
            .is_active(&TurnKey::new("thread-codex", "turn-codex"))
    );
    assert!(
        !core
            .turns
            .is_active(&TurnKey::new("claude_session", "turn-claude"))
    );
    assert!(
        core.turns
            .context(&TurnKey::new("claude_session", "turn-claude"))
            .is_none()
    );
    assert_eq!(restored.next_client_id.load(Ordering::Acquire), 53);
}

#[tokio::test]
async fn recovered_terminal_turn_is_recorded_without_removing_a_replacement() {
    let gateway = test_gateway();
    let pending = PendingTurnStart {
        thread_id: "thread-1".to_string(),
        context: PromptContext {
            compaction: false,
            preview: "new work".to_string(),
            cwd: Some("/tmp".to_string()),
            owner_client_id: 7,
        },
        previous_turn_id: Some("old-turn".to_string()),
        client_user_message_id: None,
        created_at_unix_seconds: unix_seconds(),
    };
    gateway
        .core
        .lock()
        .await
        .turns
        .insert_pending("7:1".to_string(), pending.clone());
    let terminal = json!({
        "id": "new-turn",
        "status": "completed",
        "startedAt": pending.created_at_unix_seconds,
        "items": [{"type": "agentMessage", "id": "message", "text": "finished"}],
    });

    gateway
        .record_recovered_terminal_turn("7:1", &pending, &terminal)
        .await
        .expect("record terminal turn");
    let replacement = PendingTurnStart {
        created_at_unix_seconds: pending.created_at_unix_seconds + 1.0,
        ..pending.clone()
    };
    gateway
        .core
        .lock()
        .await
        .turns
        .insert_pending("7:1".to_string(), replacement.clone());
    assert!(
        !gateway
            .remove_pending_turn_if_matches("7:1", &pending)
            .await
            .expect("compare pending")
    );

    let core = gateway.core.lock().await;
    assert_eq!(core.turns.pending_start("7:1"), Some(&replacement));
    assert_eq!(core.turns.active_count(), 0);
    assert_eq!(core.turns.context_count(), 0);
    assert!(
        core.turns
            .completion_recorded(&TurnKey::new("thread-1", "new-turn"))
    );
    assert_eq!(core.notification_history.len(), 2);
}

#[tokio::test]
async fn pending_turn_recovery_keeps_the_exact_start_when_resume_is_incomplete() {
    let claude_test =
        Arc::new(crate::providers::claude::settings::ClaudeSettings::isolated_for_test());
    for (name, thread) in [
        (
            "missing turns",
            json!({"id": "thread-pending", "status": {"type": "idle"}}),
        ),
        (
            "missing status",
            json!({"id": "thread-pending", "turns": []}),
        ),
        (
            "unresolved status",
            json!({"id": "thread-pending", "status": {"type": "systemError"}, "turns": []}),
        ),
    ] {
        let codex_home = tempfile::tempdir().expect("Codex home");
        let socket_dir = codex_home.path().join("app-server-control");
        tokio::fs::create_dir_all(&socket_dir)
            .await
            .expect("socket directory");
        let listener =
            UnixListener::bind(socket_dir.join("app-server-control.sock")).expect("Codex listener");
        let fake_codex = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("pending accept");
            let mut websocket = accept_async(stream).await.expect("pending WebSocket");
            let initialize: Value = loop {
                let frame = websocket
                    .next()
                    .await
                    .expect("initialize frame")
                    .expect("initialize");
                let UpstreamMessage::Text(raw) = frame else {
                    continue;
                };
                let message: Value = serde_json::from_str(&raw).expect("initialize JSON");
                if message.get("id").is_some() {
                    break message;
                }
            };
            websocket
                .send(UpstreamMessage::Text(
                    json!({"jsonrpc": "2.0", "id": initialize["id"], "result": {}}).to_string(),
                ))
                .await
                .expect("initialize response");
            let resume: Value = loop {
                let frame = websocket
                    .next()
                    .await
                    .expect("resume frame")
                    .expect("resume");
                let UpstreamMessage::Text(raw) = frame else {
                    continue;
                };
                let message: Value = serde_json::from_str(&raw).expect("resume JSON");
                if message["method"] == "thread/resume" {
                    break message;
                }
            };
            websocket
                .send(UpstreamMessage::Text(
                    json!({"jsonrpc": "2.0", "id": resume["id"], "result": {"thread": thread}})
                        .to_string(),
                ))
                .await
                .expect("resume response");
        });
        let codex = Arc::new(CodexAppServer::new_for_test_socket(
            codex_home.path().to_path_buf(),
        ));
        let gateway = crate::test_support::TestGateway::with_settings(
            codex,
            claude_test.settings.clone(),
            Arc::clone(&claude_test),
        );
        let pending = PendingTurnStart {
            thread_id: "thread-pending".to_string(),
            context: PromptContext {
                compaction: false,
                preview: "unconfirmed work".to_string(),
                cwd: None,
                owner_client_id: 7,
            },
            previous_turn_id: None,
            client_user_message_id: None,
            created_at_unix_seconds: unix_seconds(),
        };
        gateway
            .core
            .lock()
            .await
            .turns
            .insert_pending("7:1".to_string(), pending.clone());
        assert!(
            gateway
                .reconcile_pending_turn("7:1", &pending)
                .await
                .is_err(),
            "{name} must leave exact recovery pending"
        );
        assert_eq!(
            gateway.core.lock().await.turns.pending_start("7:1"),
            Some(&pending),
            "{name} must preserve the accepted start"
        );
        fake_codex.await.expect("fake Codex");
    }
}

#[test]
fn terminal_pending_recovery_requires_new_turn_evidence() {
    let pending = PendingTurnStart {
        thread_id: "thread-1".to_string(),
        context: PromptContext {
            compaction: false,
            preview: "new work".to_string(),
            cwd: None,
            owner_client_id: 7,
        },
        previous_turn_id: None,
        client_user_message_id: None,
        created_at_unix_seconds: 100.0,
    };
    assert!(!is_terminal_turn_for_pending(
        &json!({"id": "historical", "status": "completed", "startedAt": 50}),
        &pending
    ));
    assert!(is_terminal_turn_for_pending(
        &json!({"id": "new", "status": "completed", "startedAt": 100}),
        &pending
    ));
}

#[tokio::test]
async fn replay_history_pairs_each_origins_copy_and_keeps_repeated_states() {
    let gateway = test_gateway();
    let thread = || Some("thread-1".to_string());
    let active = frame(
        "thread/status/changed",
        json!({"threadId": "thread-1", "status": {"type": "active"}}),
    );
    let completed = frame(
        "turn/completed",
        json!({"threadId": "thread-1", "turn": {"id": "turn-1", "status": "completed"}}),
    );
    let phone = PHONE;
    let observer = NotificationOrigin::Observer { opened_after: 0 };

    let mut sequences = Vec::new();
    for (raw, origin) in [
        (&active, phone),
        (&active, phone),
        (&active, observer),
        (&active, observer),
        (&completed, observer),
        (&completed, phone),
    ] {
        sequences.push(
            gateway
                .push_notification_history(raw, thread(), origin)
                .await,
        );
    }

    assert_eq!(sequences, vec![1, 2, 1, 2, 3, 3]);
    let core = gateway.core.lock().await;
    assert_eq!(core.notification_history.len(), 3);
    assert!((0..3).all(|index| core.notification_history.origins_for_test(index).len() == 2));
}

#[tokio::test]
async fn full_marks_reads_advertise_retirement_support_but_deltas_do_not() {
    let directory = tempfile::tempdir().unwrap();
    let gateway = crate::test_support::TestGateway::with_codex(
        Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        )),
        Some(directory.path().join("turn-state.json")),
    );
    for (method, params) in [
        ("conversation/marks/read", json!({})),
        (
            "conversation/marks/update",
            json!({"changes":[{"op":"markUnread","threadId":"thread"}]}),
        ),
    ] {
        let object = request(method, params);
        let target = match DispatchPlan::parse(&Value::Object(object.clone()).to_string()) {
            DispatchPlan::Request(request) => request.owned.unwrap().target,
            _ => panic!("marks request is not gateway-owned"),
        };
        let (tx, mut rx) = mpsc::channel(1);
        gateway
            .handle_owned_rpc(1, &test_client(1, tx), method, target, &object)
            .await
            .unwrap();
        let Some(ClientCommand::Text(text)) = rx.recv().await else {
            panic!("expected a marks reply");
        };
        let response: Value = serde_json::from_str(&text).unwrap();
        assert!(response.get("error").is_none(), "{response}");
        if method == "conversation/marks/read" {
            assert_eq!(response["result"]["supportsRetiredScopeRead"], true);
        } else {
            assert!(response["result"]["delta"].is_object());
            assert!(
                response["result"]["delta"]
                    .get("supportsRetiredScopeRead")
                    .is_none()
            );
        }
    }
}

#[tokio::test]
async fn native_archive_notifications_keep_marks_and_deletion_clears_them() {
    let directory = tempfile::tempdir().unwrap();
    let gateway = crate::test_support::TestGateway::with_codex(
        Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        )),
        Some(directory.path().join("turn-state.json")),
    );
    let thread = json!({"threadId": "thread-1"});
    gateway
        .marks
        .update(
            vec![crate::conversation_marks::Change::MarkUnread {
                thread_id: "thread-1".into(),
            }],
            10,
        )
        .await
        .unwrap();
    let marked = gateway.marks.read(20).await.unwrap();
    for method in ["thread/archived", "thread/unarchived"] {
        gateway
            .record_agent_notification(&frame(method, thread.clone()), CONTROL)
            .await;
    }
    assert_eq!(gateway.marks.read(20).await.unwrap(), marked);

    gateway
        .record_agent_notification(&frame("thread/deleted", thread), CONTROL)
        .await;
    assert!(gateway.marks.read(20).await.unwrap().threads.is_empty());
}

#[tokio::test]
async fn the_native_unarchive_drain_keeps_only_ids_codex_failed_to_restore() {
    let directory = tempfile::tempdir().unwrap();
    std::fs::write(
        directory.path().join("conversation-marks.json"),
        json!({
            "schemaVersion": 1,
            "revision": 4,
            "readBaseline": 0,
            "threads": {
                "codex-restored": {"revision": 1, "archivedAt": 10},
                "codex-gone": {"revision": 2, "archivedAt": 20},
                "codex-failing": {"revision": 3, "archivedAt": 30},
                "claude_settled": {"revision": 4, "archivedAt": 40}
            }
        })
        .to_string(),
    )
    .unwrap();
    let gateway = crate::test_support::TestGateway::with_codex(
        Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        )),
        Some(directory.path().join("turn-state.json")),
    );
    let mut requests = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;
    let codex = async {
        for _ in 0..3 {
            let request: Value = serde_json::from_str(&requests.recv().await.unwrap()).unwrap();
            assert_eq!(request["method"], "thread/unarchive");
            let reply = match request["params"]["threadId"].as_str().unwrap() {
                "codex-restored" => json!({
                    "id": request["id"],
                    "result": {"thread": {"id": "codex-restored"}}
                }),
                "codex-gone" => json!({
                    "id": request["id"],
                    "error": {
                        "code": -32600,
                        "message": "no archived rollout found for thread id codex-gone"
                    }
                }),
                _ => json!({
                    "id": request["id"],
                    "error": {"code": -32603, "message": "failed to unarchive thread: disk full"}
                }),
            };
            gateway
                .handle_control_text(reply.to_string(), CONTROL)
                .await;
        }
    };
    tokio::join!(gateway.drain_pending_native_unarchives(), codex);

    assert_eq!(
        gateway.marks.pending_native_unarchives(50).await.unwrap(),
        ["codex-failing"]
    );
    assert!(requests.try_recv().is_err());
}

#[tokio::test]
async fn replay_history_never_pairs_a_copy_with_an_occurrence_its_stream_could_not_have_seen() {
    let gateway = test_gateway();
    let thread = || Some("thread-1".to_string());
    let active = frame(
        "thread/status/changed",
        json!({"threadId": "thread-1", "status": {"type": "active"}}),
    );
    let idle = frame(
        "thread/status/changed",
        json!({"threadId": "thread-1", "status": {"type": "idle"}}),
    );
    let observer = NotificationOrigin::Observer { opened_after: 0 };

    assert_eq!(
        gateway
            .push_notification_history(&idle, thread(), observer)
            .await,
        1
    );
    assert_eq!(
        gateway
            .push_notification_history(&active, thread(), observer)
            .await,
        2
    );
    let reconnected = NotificationOrigin::Client {
        id: 2,
        opened_after: gateway.notification_floor().await,
    };
    assert_eq!(
        gateway
            .push_notification_history(&active, thread(), reconnected)
            .await,
        3,
        "a stream opened after an occurrence starts a new one"
    );
    assert_eq!(
        gateway
            .push_notification_history(&active, thread(), observer)
            .await,
        3
    );

    let early = NotificationOrigin::Client {
        id: 3,
        opened_after: 0,
    };
    assert_eq!(
        gateway
            .push_notification_history(&active, thread(), early)
            .await,
        2
    );
    assert_eq!(
        gateway
            .push_notification_history(&idle, thread(), early)
            .await,
        4,
        "a copy never pairs with an occurrence before its stream's previous copy"
    );
}

#[tokio::test]
async fn forwarded_notifications_stamp_history_sequences_only_when_stored() {
    let gateway = test_gateway();

    let stored = frame(
        "account/updated",
        json!({"authMode": "chatgpt", "name": "Åsa 🚀"}),
    );
    let stored_value: Value = serde_json::from_str(&stored).expect("stored JSON");
    let first = gateway
        .prepare_forwarded_notification(&stored, &stored_value, PHONE)
        .await
        .expect("stored notification");
    let first = first.text().unwrap();
    assert_eq!(
        first,
        format!("{},\"rcSequence\":1}}", &stored[..stored.len() - 1]),
        "stamping appends to the original bytes without re-encoding them"
    );
    let first_value: Value = serde_json::from_str(first).expect("stamped JSON");
    assert_eq!(first_value["rcSequence"], 1);
    assert_eq!(first_value["params"], stored_value["params"]);

    for method in [
        "item/reasoning/summaryTextDelta",
        "item/agentMessage/delta",
        "thread/realtime/item/started",
        "thread/realtime/item/transcript/delta",
        "thread/realtime/item/completed",
    ] {
        let live = frame(
            method,
            json!({"threadId": "thread-1", "turnId": "turn-1", "delta": "same"}),
        );
        let value: Value = serde_json::from_str(&live).expect("live JSON");
        assert_eq!(
            gateway
                .prepare_forwarded_notification(&live, &value, PHONE)
                .await
                .expect("live notification")
                .text()
                .unwrap(),
            live,
            "{method}"
        );
    }

    let repeat = gateway
        .prepare_forwarded_notification(&stored, &stored_value, CONTROL)
        .await
        .expect("deduplicated notification");
    let repeat_value: Value =
        serde_json::from_str(repeat.text().unwrap()).expect("deduplicated JSON");
    assert_eq!(repeat_value["rcSequence"], 1);

    let response = " { \"jsonrpc\": \"2.0\", \"id\": 7, \"result\": {} } ";
    let response_value: Value = serde_json::from_str(response).expect("response JSON");
    assert_eq!(
        gateway
            .prepare_forwarded_notification(response, &response_value, PHONE)
            .await
            .expect("response frame")
            .text()
            .unwrap(),
        response
    );

    for (method, params, expected_sequence) in [
        (
            "thread/realtime/itemAdded",
            json!({"threadId": "thread-1", "item": {"id": "item-1"}}),
            2,
        ),
        (
            "turn/completed",
            json!({"threadId": "thread-1", "turn": {"id": "turn-1", "status": "completed"}}),
            3,
        ),
    ] {
        let stored = frame(method, params);
        let value: Value = serde_json::from_str(&stored).expect("stored JSON");
        let forwarded = gateway
            .prepare_forwarded_notification(&stored, &value, PHONE)
            .await
            .expect("stored notification");
        let forwarded: Value =
            serde_json::from_str(forwarded.text().unwrap()).expect("forwarded JSON");
        assert_eq!(forwarded["rcSequence"], expected_sequence, "{method}");
    }
}

#[tokio::test]
async fn tool_images_are_compact_in_forwarding_and_control_recorded_replay() {
    let gateway = test_gateway();
    let original = json!({"method": "item/completed", "params": {
        "threadId": "thread-images", "turnId": "turn-images", "item": {
            "id": "tool-images", "type": "mcpToolCall", "result": {"content": [
                {"type": "image", "mimeType": "image/jpeg", "data": "YWJj"}
            ]}
        }
    }});
    let raw = original.to_string();
    assert_eq!(
        gateway
            .record_agent_notification_value(&raw, &original, CONTROL)
            .await,
        Some(1)
    );
    let forwarded = gateway
        .prepare_forwarded_notification(&raw, &original, PHONE)
        .await
        .expect("forwarded image notification");
    let forwarded: Value = serde_json::from_str(forwarded.text().unwrap()).expect("forwarded JSON");
    assert_eq!(forwarded["rcSequence"], 1);
    let request = crate::notifications::history::ReplayRequest::from_params(None);
    let replay = gateway
        .core
        .lock()
        .await
        .notification_history
        .replay(&request, unix_seconds())
        .into_wire(unix_seconds());
    assert_eq!(replay["notifications"].as_array().unwrap().len(), 1);
    assert_eq!(
        replay["notifications"][0]["message"]["params"],
        forwarded["params"]
    );
    assert_eq!(
        forwarded["params"]["item"]["result"]["content"][0],
        json!({
            "type": "image", "mimeType": "image/jpeg", "data": "",
            "rcImageOmitted": {"mimeType": "image/jpeg", "omittedBytes": 4}
        })
    );
    assert_eq!(
        original["params"]["item"]["result"]["content"][0]["data"],
        "YWJj"
    );
}

#[tokio::test]
async fn codex_image_views_forward_their_saved_snapshot() {
    let gateway = test_gateway();
    let original = json!({"method": "item/completed", "params": {
        "threadId": "thread-images", "turnId": "turn-images", "item": {
            "id": "view", "type": "imageView", "path": "/tmp/view.png",
            "savedPath": "/codex/viewed_images/thread-images/abc.png"
        }
    }});
    let forwarded = gateway
        .prepare_forwarded_notification(&original.to_string(), &original, PHONE)
        .await
        .expect("forwarded image view");
    let forwarded: Value = serde_json::from_str(forwarded.text().unwrap()).expect("forwarded JSON");
    assert_eq!(
        forwarded["params"]["item"],
        json!({
            "id": "view", "type": "imageView", "path": "/tmp/view.png",
            "savedPath": "/codex/viewed_images/thread-images/abc.png",
            "rcMedia": [{"path": "/codex/viewed_images/thread-images/abc.png", "mimeType": "image/png"}]
        })
    );
}

#[tokio::test]
async fn a_broadcast_a_client_cannot_queue_closes_its_connection() {
    let gateway = test_gateway();
    let (tx, _rx) = mpsc::channel(1);
    let client = test_client(1, tx);
    gateway.clients.insert(1, client.clone());

    gateway
        .broadcast_json_or_drop(&json!({"method":"first"}), Source::Gateway)
        .unwrap();
    assert!(!client.closed.is_cancelled());
    gateway
        .broadcast_json_or_drop(&json!({"method":"second"}), Source::Gateway)
        .unwrap();

    assert!(client.closed.is_cancelled());
    assert!(gateway.clients.is_empty());
}

#[tokio::test]
async fn a_local_response_a_client_cannot_queue_closes_its_connection() {
    let gateway = test_gateway();
    let (tx, _rx) = mpsc::channel(1);
    let client = test_client(1, tx);
    gateway.clients.insert(1, client.clone());

    gateway
        .send_json_awaiting_capacity(&client, &json!({"id": 1, "result": {}}))
        .await
        .expect("first response");
    assert!(!client.closed.is_cancelled());
    gateway
        .send_json_awaiting_capacity(&client, &json!({"id": 2, "result": {}}))
        .await
        .expect_err("a full queue cannot take the second response");

    assert!(client.closed.is_cancelled());
    assert!(gateway.clients.is_empty());
}

#[tokio::test]
async fn closing_all_clients_cancels_one_whose_close_cannot_be_queued() {
    let gateway = test_gateway();
    let (full_tx, _full_rx) = mpsc::channel(1);
    let full = test_client(1, full_tx);
    full.try_send(ClientCommand::Text("queued".into()))
        .expect("fill the queue");
    let (open_tx, mut open_rx) = mpsc::channel(1);
    let open = test_client(2, open_tx);
    gateway.clients.insert(1, full.clone());
    gateway.clients.insert(2, open.clone());

    gateway.close_all_clients(RESTARTING_CLOSE_CODE, RESTARTING_CLOSE_REASON);

    assert!(full.closed.is_cancelled());
    assert!(!open.closed.is_cancelled());
    assert!(gateway.clients.is_empty());
    assert!(matches!(
        open_rx.recv().await,
        Some(ClientCommand::Close {
            code: RESTARTING_CLOSE_CODE,
            ..
        })
    ));
}

#[tokio::test]
async fn prepared_handoff_shutdown_does_not_suspend_codex_again() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let directory = tempfile::tempdir().expect("state directory");
    let recovery_path = directory.path().join("recovery.json");
    let mut prepared = RecoveryJournal::new(
        "generation-1".to_owned(),
        "0123456789abcdef0123456789abcdef".to_owned(),
        Vec::new(),
    )
    .expect("recovery journal");
    prepared.phase = RecoveryPhase::DaemonStopped;
    RecoveryStore::new(recovery_path.clone())
        .write(&prepared)
        .expect("prepared handoff");
    let gateway = Gateway::with_state_paths(
        Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        )),
        claude_test.settings.clone(),
        Journal::disabled(),
        Some(directory.path().join("active-codex-turns.json")),
        Some(recovery_path.clone()),
        None,
    );
    {
        let mut core = gateway.core.lock().await;
        core.app_server_inventory_bootstrapped = true;
        core.turns
            .mark_active(&TurnKey::new("thread", "turn"), unix_seconds(), None, None);
    }

    tokio::time::timeout(Duration::from_millis(500), gateway.shutdown_for_restart())
        .await
        .expect("a prepared handoff must not wait for or suspend the active turn");
    assert!(gateway.is_draining());
    assert_eq!(gateway.active_turn_count().await, 1);
    assert_eq!(
        RecoveryStore::new(recovery_path)
            .load()
            .expect("recovery journal")
            .expect("prepared journal")
            .generation_id,
        "generation-1"
    );
}

#[tokio::test]
async fn upstream_large_frames_and_capacity_errors_preserve_client_isolation() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    use crate::providers::codex::daemon::{MAX_WEBSOCKET_BYTES, websocket_config};
    use tokio_tungstenite::connect_async_with_config;

    let codex_home = tempfile::tempdir().expect("Codex home");
    let socket_dir = codex_home.path().join("app-server-control");
    tokio::fs::create_dir_all(&socket_dir)
        .await
        .expect("socket directory");
    let listener =
        UnixListener::bind(socket_dir.join("app-server-control.sock")).expect("Codex listener");
    let fake_codex = tokio::spawn(async move {
        let mut peers = JoinSet::new();
        for _ in 0..2 {
            let (stream, _) = listener.accept().await.expect("accept upstream");
            peers.spawn(async move {
                let mut ws = accept_async(stream).await.expect("upstream handshake");
                while let Some(Ok(frame)) = ws.next().await {
                    let UpstreamMessage::Text(raw) = frame else {
                        continue;
                    };
                    let request: Value = serde_json::from_str(&raw).unwrap();
                    let size = request["params"]["bytes"].as_u64().unwrap_or(2) as usize;
                    let result = if request["method"] == "thread/items/list" {
                        json!({"data": [{"turnId": "turn-1", "item": {
                            "id": "item-1", "type": "agentMessage", "text": "x".repeat(size)
                        }}], "nextCursor": null, "backwardsCursor": null})
                    } else {
                        json!({"text": "x".repeat(size)})
                    };
                    let response = json!({"id": request["id"], "result": result}).to_string();
                    if request["params"]["fragmented"] == true {
                        use tokio_tungstenite::tungstenite::protocol::frame::{
                            Frame,
                            coding::{Data, OpCode},
                        };
                        let midpoint = response.len() / 2;
                        let first = Frame::message(
                            response.as_bytes()[..midpoint].to_vec(),
                            OpCode::Data(Data::Text),
                            false,
                        );
                        let last = Frame::message(
                            response.as_bytes()[midpoint..].to_vec(),
                            OpCode::Data(Data::Continue),
                            true,
                        );
                        if ws.send(UpstreamMessage::Frame(first)).await.is_err()
                            || ws.send(UpstreamMessage::Frame(last)).await.is_err()
                        {
                            break;
                        }
                    } else if ws.send(UpstreamMessage::Text(response)).await.is_err() {
                        break;
                    }
                }
            });
        }
        while peers.join_next().await.is_some() {}
    });
    let codex = Arc::new(CodexAppServer::new_for_test_socket(
        codex_home.path().into(),
    ));
    let gateway = crate::test_support::TestGateway::with_settings(
        codex,
        claude_test.settings.clone(),
        Arc::new(claude_test),
    );
    *gateway.control_init_result.lock().await = Some(json!({}));
    let app_gateway = Arc::clone(&gateway);
    let app = Router::new().route(
        "/ws",
        get(move |ws: WebSocketUpgrade| {
            let gateway = Arc::clone(&app_gateway);
            async move {
                ws.max_message_size(MAX_WEBSOCKET_BYTES)
                    .max_frame_size(MAX_WEBSOCKET_BYTES)
                    .on_upgrade(move |socket| {
                        gateway.handle_ws(
                            socket,
                            tokio_util::sync::CancellationToken::new(),
                            crate::auth::installation_credentials::Grant::Operator,
                        )
                    })
            }
        }),
    );
    let (address, server) = crate::test_support::serve(app).await;
    let (mut client, _) = connect_async_with_config(
        format!("ws://{address}/ws"),
        Some(websocket_config()),
        false,
    )
    .await
    .unwrap();
    let (mut other, _) = connect_async(format!("ws://{address}/ws")).await.unwrap();

    send_client_json(
        &mut client,
        json!({"id": 1, "method": "thread/items/list", "params": {"bytes": 17 * 1024 * 1024}}),
    )
    .await;
    let announcement = next_client_json(&mut client).await;
    assert_eq!(announcement["method"], "connection/largeFrame");
    let response = next_client_json(&mut client).await;
    assert_eq!(announcement["params"]["bytes"], response.to_string().len());
    assert_eq!(response["id"], 1);
    assert_eq!(
        response["result"]["data"][0]["item"]["text"]
            .as_str()
            .unwrap()
            .len(),
        17 * 1024 * 1024
    );

    send_client_json(&mut client, json!({"id": "large-page", "method": "thread/items/list", "params": {"bytes": 25 * 1024 * 1024}})).await;
    let error = next_client_json(&mut client).await;
    assert_eq!(error["id"], "large-page");
    assert_eq!(error["error"]["code"], -32003);
    assert_eq!(error["error"]["data"]["kind"], "historyPageTooLarge");
    assert_eq!(
        error["error"]["data"]["limitBytes"],
        HISTORY_PAGE_RESPONSE_BUDGET
    );
    assert!(error["error"]["data"]["actualBytes"].as_u64().unwrap() > 25 * 1024 * 1024);
    // A request-local budget failure leaves the very same connection usable.
    send_client_json(
        &mut client,
        json!({"id": 3, "method": "thread/read", "params": {}}),
    )
    .await;
    assert_eq!(next_client_json(&mut client).await["id"], 3);

    send_client_json(&mut client, json!({"id": 4, "method": "thread/items/list", "params": {"bytes": MAX_WEBSOCKET_BYTES + 1}})).await;
    let notification = tokio::time::timeout(Duration::from_secs(60), next_client_json(&mut client))
        .await
        .unwrap();
    assert_eq!(notification["method"], "daemon/transportError");
    assert!(notification.get("id").is_none());
    assert_eq!(notification["params"]["kind"], "messageTooLarge");
    assert_eq!(notification["params"]["limitBytes"], MAX_WEBSOCKET_BYTES);
    assert_eq!(notification["params"]["retryable"], false);
    assert!(notification["params"]["actualBytes"].as_u64().unwrap() > MAX_WEBSOCKET_BYTES as u64);
    loop {
        if let UpstreamMessage::Close(frame) = client.next().await.unwrap().unwrap() {
            assert_eq!(u16::from(frame.unwrap().code), 1009);
            break;
        }
    }
    send_client_json(
        &mut other,
        json!({"id": 5, "method": "thread/read", "params": {}}),
    )
    .await;
    assert_eq!(next_client_json(&mut other).await["id"], 5);
    // Two individually legal frames must still obey the assembled ceiling.
    send_client_json(
        &mut other,
        json!({"id": 6, "method": "thread/items/list", "params": {
            "bytes": MAX_WEBSOCKET_BYTES + 1, "fragmented": true
        }}),
    )
    .await;
    let fragmented_error = next_client_json(&mut other).await;
    assert_eq!(fragmented_error["method"], "daemon/transportError");
    assert!(
        fragmented_error["params"]["actualBytes"].as_u64().unwrap() > MAX_WEBSOCKET_BYTES as u64
    );
    other.close(None).await.ok();
    server.abort();
    fake_codex.abort();
}

#[test]
fn abandoned_history_requests_expire_without_removing_live_correlation() {
    let now = Instant::now();
    let mut pending = HashMap::from([
        (
            "old".to_owned(),
            PendingRequest {
                method: "thread/items/list",
                bounded_preview: false,
                thread_id: None,
                turn_id: None,
                issued_at: now - PENDING_REQUEST_TTL,
            },
        ),
        (
            "live".to_owned(),
            PendingRequest {
                method: "thread/turns/list",
                bounded_preview: false,
                thread_id: None,
                turn_id: None,
                issued_at: now,
            },
        ),
    ]);
    prune_pending_requests(&mut pending, now);
    assert!(!pending.contains_key("old"));
    assert_eq!(pending.get("live").unwrap().method, "thread/turns/list");
}

#[test]
fn history_budget_requires_correlated_responses_and_skips_method_frames() {
    let response = json!({"id": 7, "result": {"data": []}});
    assert!(
        oversized_history_page_error(
            &response,
            HISTORY_PAGE_RESPONSE_BUDGET + 1,
            Some("thread/items/list")
        )
        .is_some()
    );
    assert!(
        oversized_history_page_error(&response, HISTORY_PAGE_RESPONSE_BUDGET + 1, None).is_none()
    );
    assert!(
        oversized_history_page_error(
            &response,
            HISTORY_PAGE_RESPONSE_BUDGET + 1,
            Some("command/exec")
        )
        .is_none()
    );
    let method_frame = json!({"id": 7, "method": "item/tool/call", "result": {}});
    assert!(
        oversized_history_page_error(
            &method_frame,
            HISTORY_PAGE_RESPONSE_BUDGET + 1,
            Some("thread/items/list")
        )
        .is_none()
    );
}

#[tokio::test]
async fn client_connections_preserve_protocol_identity_and_isolation() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let codex_home = tempfile::tempdir().expect("Codex home");
    let socket_dir = codex_home.path().join("app-server-control");
    tokio::fs::create_dir_all(&socket_dir)
        .await
        .expect("socket directory");
    let listener =
        UnixListener::bind(socket_dir.join("app-server-control.sock")).expect("Codex listener");
    let (observed_tx, mut observed_rx) = mpsc::channel::<(String, Value)>(4);

    let fake_codex =
        tokio::spawn(async move {
            let mut peers = Vec::new();
            for _ in 0..2 {
                let (stream, _) = listener.accept().await.expect("accept Codex client");
                let observed_tx = observed_tx.clone();
                peers.push(tokio::spawn(async move {
                    let mut websocket = accept_async(stream).await.expect("Codex WebSocket");
                    let initialize = loop {
                        let frame = websocket
                            .next()
                            .await
                            .expect("initialize frame")
                            .expect("initialize");
                        if let UpstreamMessage::Text(raw) = frame {
                            break serde_json::from_str::<Value>(&raw).expect("initialize JSON");
                        }
                    };
                    let name = initialize["params"]["clientInfo"]["name"]
                        .as_str()
                        .expect("client name")
                        .to_string();
                    observed_tx
                        .send((name.clone(), initialize.clone()))
                        .await
                        .expect("observe initialize");
                    websocket
                        .send(UpstreamMessage::Text(
                            serde_json::to_string(&json!({
                                "jsonrpc": "2.0",
                                "id": initialize["id"],
                                "result": { "owner": name }
                            }))
                            .expect("response JSON"),
                        ))
                        .await
                        .expect("initialize response");

                    let request = loop {
                        let frame = websocket
                            .next()
                            .await
                            .expect("request frame")
                            .expect("request");
                        let UpstreamMessage::Text(raw) = frame else {
                            continue;
                        };
                        let message: Value = serde_json::from_str(&raw).expect("request JSON");
                        if message.get("id").is_some() {
                            break message;
                        }
                    };
                    observed_tx
                        .send((name.clone(), request.clone()))
                        .await
                        .expect("observe request");
                    websocket
                        .send(UpstreamMessage::Text(
                            serde_json::to_string(&json!({
                                "jsonrpc": "2.0",
                                "id": request["id"],
                                "result": { "owner": name }
                            }))
                            .expect("response JSON"),
                        ))
                        .await
                        .expect("request response");
                    if name == "client-a" {
                        websocket
                            .send(UpstreamMessage::Text(
                                serde_json::to_string(&json!({
                                    "jsonrpc": "2.0",
                                    "id": 99,
                                    "method": "item/commandExecution/requestApproval",
                                    "params": { "threadId": "thread-a" }
                                }))
                                .expect("server request JSON"),
                            ))
                            .await
                            .expect("server request");
                    }

                    while let Some(Ok(frame)) = websocket.next().await {
                        let UpstreamMessage::Text(raw) = frame else {
                            continue;
                        };
                        let message: Value = serde_json::from_str(&raw).expect("forwarded JSON");
                        observed_tx
                            .send((name.clone(), message.clone()))
                            .await
                            .expect("observe forwarded frame");
                        if message["method"] == "foreign/request" {
                            websocket
                            .send(UpstreamMessage::Text(json!({
                                "jsonrpc": "2.0", "id": message["id"], "result": {"owner": name}
                            }).to_string()))
                            .await
                            .expect("foreign response");
                        }
                    }
                }));
            }
            for peer in peers {
                peer.await.expect("Codex peer");
            }
        });

    let codex = Arc::new(CodexAppServer::new_for_test_socket(
        codex_home.path().to_path_buf(),
    ));
    let gateway = crate::test_support::TestGateway::with_settings(
        codex,
        claude_test.settings.clone(),
        Arc::new(claude_test),
    );
    *gateway.control_init_result.lock().await = Some(json!({}));
    let app_gateway = Arc::clone(&gateway);
    let app = Router::new().route(
        "/ws",
        get(move |ws: WebSocketUpgrade| {
            let gateway = Arc::clone(&app_gateway);
            async move {
                ws.on_upgrade(move |socket| {
                    gateway.handle_ws(
                        socket,
                        tokio_util::sync::CancellationToken::new(),
                        crate::auth::installation_credentials::Grant::Operator,
                    )
                })
            }
        }),
    );
    let (address, gateway_server) = crate::test_support::serve(app).await;

    let (mut client_a, _) = connect_async(format!("ws://{address}/ws"))
        .await
        .expect("client A");
    let (mut client_b, _) = connect_async(format!("ws://{address}/ws"))
        .await
        .expect("client B");
    for (client, name, opt_out) in [
        (&mut client_a, "client-a", "turn/plan/updated"),
        (&mut client_b, "client-b", "item/reasoning/textDelta"),
    ] {
        send_client_json(
            client,
            json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": { "name": name, "version": "1" },
                    "capabilities": { "optOutNotificationMethods": [opt_out] }
                }
            }),
        )
        .await;
    }

    for (client, name) in [(&mut client_a, "client-a"), (&mut client_b, "client-b")] {
        let response = next_client_json(client).await;
        assert_eq!(response["id"], 1);
        assert_eq!(response["result"]["owner"], name);
        send_client_json(client, json!({ "jsonrpc": "2.0", "method": "initialized" })).await;
        send_client_json(
            client,
            json!({
                "jsonrpc": "2.0",
                "id": 7,
                "method": "thread/list",
                "params": {}
            }),
        )
        .await;
    }

    for (client, name) in [(&mut client_a, "client-a"), (&mut client_b, "client-b")] {
        let response = next_client_json(client).await;
        assert_eq!(response["id"], 7);
        assert_eq!(response["result"]["owner"], name);
    }
    let server_request = next_client_json(&mut client_a).await;
    assert_eq!(
        server_request["method"],
        "item/commandExecution/requestApproval"
    );
    assert!(
        tokio::time::timeout(Duration::from_millis(100), next_client_json(&mut client_b))
            .await
            .is_err(),
        "client B received client A's server request"
    );

    let mut observed = Vec::new();
    for _ in 0..4 {
        observed.push(observed_rx.recv().await.expect("observed request"));
    }
    observed.sort_by(|left, right| left.0.cmp(&right.0));
    for (name, opt_out) in [
        ("client-a", "turn/plan/updated"),
        ("client-b", "item/reasoning/textDelta"),
    ] {
        let initialize = observed
            .iter()
            .find(|(owner, message)| owner == name && message["method"] == "initialize")
            .expect("client initialize reached its own Codex connection");
        assert_eq!(
            initialize.1["params"]["capabilities"]["optOutNotificationMethods"],
            json!([opt_out])
        );
    }
    assert_eq!(
        observed
            .iter()
            .filter(|(name, message)| name == "client-a" && message["id"] == 7)
            .count(),
        1
    );
    assert_eq!(
        observed
            .iter()
            .filter(|(name, message)| name == "client-b" && message["id"] == 7)
            .count(),
        1
    );

    client_a
        .send(UpstreamMessage::Text(
            r#"{"id":8,"m\u0065thod":"daemon/activeTurns","params":{}}"#.to_string(),
        ))
        .await
        .expect("escaped local request");
    let local = tokio::time::timeout(Duration::from_secs(2), next_client_reply(&mut client_a))
        .await
        .expect("local response");
    assert_eq!(local["id"], 8);
    assert!(local["result"].is_object());

    for malformed in [
        r#"{"method":"daemon/activeTurns"}"#,
        r#"{"id":null,"method":"daemon/activeTurns"}"#,
        r#"{"id":10,"method":13}"#,
    ] {
        client_a
            .send(UpstreamMessage::Text(malformed.to_string()))
            .await
            .expect("invalid request");
        let refusal =
            tokio::time::timeout(Duration::from_secs(2), next_client_reply(&mut client_a))
                .await
                .expect("invalid request refusal");
        assert_eq!(refusal["error"]["code"], RpcCode::InvalidRequest.value());
    }
    client_a
        .send(UpstreamMessage::Text(
            r#"{"id":11,"method":"daemon/activeTurns""#.to_string(),
        ))
        .await
        .expect("malformed JSON");
    let parse_error =
        tokio::time::timeout(Duration::from_secs(2), next_client_reply(&mut client_a))
            .await
            .expect("parse error");
    assert_eq!(parse_error["error"]["code"], -32700);

    gateway.draining.store(true, Ordering::Release);
    client_a
        .send(UpstreamMessage::Text(
            r#"{"id":12,"m\u0065thod":"turn/start","params":{}}"#.to_string(),
        ))
        .await
        .expect("escaped turn start");
    let refusal = tokio::time::timeout(Duration::from_secs(2), next_client_reply(&mut client_a))
        .await
        .expect("draining refusal");
    assert_eq!(refusal["error"]["code"], RpcCode::ServerBusy.value());
    gateway.draining.store(false, Ordering::Release);

    client_a
        .send(UpstreamMessage::Text(
            r#"{"id":99,"result":{}}"#.to_string(),
        ))
        .await
        .expect("server reply");
    client_a
        .send(UpstreamMessage::Text(
            r#"{"id":13,"m\u0065thod":"foreign/request","params":{}}"#.to_string(),
        ))
        .await
        .expect("foreign request");
    let foreign = tokio::time::timeout(Duration::from_secs(2), next_client_reply(&mut client_a))
        .await
        .expect("foreign response");
    assert_eq!(foreign["id"], 13);
    assert_eq!(foreign["result"]["owner"], "client-a");
    let forwarded_reply = observed_rx.recv().await.expect("forwarded server reply");
    let forwarded_foreign = observed_rx.recv().await.expect("forwarded foreign request");
    assert_eq!(forwarded_reply.1["id"], 99);
    assert_eq!(forwarded_reply.1["result"], json!({}));
    assert_eq!(forwarded_foreign.1["method"], "foreign/request");

    client_a.close(None).await.expect("close client A");
    client_b.close(None).await.expect("close client B");
    tokio::time::timeout(Duration::from_secs(1), fake_codex)
        .await
        .expect("Codex peers did not close")
        .expect("fake Codex task");
    gateway_server.abort();
    let _ = gateway_server.await;
}

#[tokio::test]
async fn disconnected_turn_observer_reconciles_idle_resume() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let codex_home = tempfile::tempdir().expect("Codex home");
    let socket_dir = codex_home.path().join("app-server-control");
    tokio::fs::create_dir_all(&socket_dir)
        .await
        .expect("socket directory");
    let listener =
        UnixListener::bind(socket_dir.join("app-server-control.sock")).expect("Codex listener");
    let (unsubscribe_tx, unsubscribe_rx) = oneshot::channel();
    let fake_codex = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("observer accept");
        let mut websocket = accept_async(stream).await.expect("observer WebSocket");

        let initialize: Value = loop {
            let frame = websocket
                .next()
                .await
                .expect("initialize frame")
                .expect("initialize");
            let UpstreamMessage::Text(raw) = frame else {
                continue;
            };
            let message: Value = serde_json::from_str(&raw).expect("initialize JSON");
            if message.get("id").is_some() {
                break message;
            }
        };
        websocket
            .send(UpstreamMessage::Text(
                serde_json::to_string(&json!({
                    "jsonrpc": "2.0",
                    "id": initialize["id"],
                    "result": {}
                }))
                .expect("initialize response"),
            ))
            .await
            .expect("initialize response send");

        let resume: Value = loop {
            let frame = websocket
                .next()
                .await
                .expect("resume frame")
                .expect("resume");
            let UpstreamMessage::Text(raw) = frame else {
                continue;
            };
            let message: Value = serde_json::from_str(&raw).expect("resume JSON");
            if message.get("method").and_then(Value::as_str) == Some("thread/resume") {
                break message;
            }
        };
        websocket
            .send(UpstreamMessage::Text(
                serde_json::to_string(&json!({
                    "jsonrpc": "2.0",
                    "id": resume["id"],
                    "result": {
                        "thread": {
                            "id": "thread-observed",
                            "status": { "type": "idle" }
                        }
                    }
                }))
                .expect("resume response"),
            ))
            .await
            .expect("resume response send");
        loop {
            let frame = websocket
                .next()
                .await
                .expect("unsubscribe frame")
                .expect("unsubscribe");
            let UpstreamMessage::Text(raw) = frame else {
                continue;
            };
            let message: Value = serde_json::from_str(&raw).expect("unsubscribe JSON");
            if message.get("method").and_then(Value::as_str) == Some("thread/unsubscribe") {
                assert_eq!(message["params"]["threadId"], "thread-observed");
                let _ = unsubscribe_tx.send(());
                break;
            }
        }
    });

    let codex = Arc::new(CodexAppServer::new_for_test_socket(
        codex_home.path().to_path_buf(),
    ));
    let gateway = crate::test_support::TestGateway::with_settings(
        codex,
        claude_test.settings.clone(),
        Arc::new(claude_test),
    );
    {
        let mut core = gateway.core.lock().await;
        core.turns.mark_active(
            &TurnKey::new("thread-observed", "observed"),
            unix_seconds(),
            Some(unix_seconds()),
            Some(42),
        );
    }
    gateway.spawn_observers_for_client(42).await;
    gateway.spawn_observers_for_client(42).await;
    assert_eq!(gateway.observer_tasks.lock().await.len(), 1);

    tokio::time::timeout(Duration::from_secs(2), unsubscribe_rx)
        .await
        .expect("observer did not unsubscribe")
        .expect("unsubscribe signal");
    fake_codex.await.expect("fake Codex");
    for _ in 0..20 {
        if gateway.observer_tasks.lock().await.is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(gateway.observer_tasks.lock().await.is_empty());
    assert_eq!(gateway.core.lock().await.turns.active_count(), 0);
}

#[tokio::test]
async fn a_disconnect_observer_follows_the_queued_successor_turn() {
    for started_during_disconnect in [false, true] {
        let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
        let codex_home = tempfile::tempdir().expect("Codex home");
        let socket_dir = codex_home.path().join("app-server-control");
        tokio::fs::create_dir_all(&socket_dir)
            .await
            .expect("socket directory");
        let listener =
            UnixListener::bind(socket_dir.join("app-server-control.sock")).expect("Codex listener");
        let thread = "thread-queued";
        let (unsubscribe_tx, unsubscribe_rx) = oneshot::channel();
        let fake_codex = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("observer accept");
            let mut websocket = accept_async(stream).await.expect("observer WebSocket");
            async fn next_request(
                websocket: &mut WebSocketStream<tokio::net::UnixStream>,
                method: &str,
            ) -> Value {
                loop {
                    let frame = websocket
                        .next()
                        .await
                        .expect("observer frame")
                        .expect("observer receive");
                    let UpstreamMessage::Text(raw) = frame else {
                        continue;
                    };
                    let message: Value = serde_json::from_str(&raw).expect("observer JSON");
                    if message.get("id").is_some() && message["method"] == method {
                        return message;
                    }
                }
            }
            let initialize = next_request(&mut websocket, "initialize").await;
            websocket
                .send(UpstreamMessage::Text(
                    json!({"id": initialize["id"], "result": {}}).to_string(),
                ))
                .await
                .expect("initialize response send");
            let resume_id = next_request(&mut websocket, "thread/resume").await["id"].clone();
            let mut frames = vec![
                json!({"id": resume_id, "result": {"thread": {
                    "id": thread,
                    "status": {"type": "active"},
                    "turns": [{"id": "first", "status": "inProgress", "items": []}],
                }}}),
                message(
                    "turn/completed",
                    json!({"threadId": thread, "turn": {"id": "first", "status": "completed"}}),
                ),
                message(
                    "turn/started",
                    json!({"threadId": thread, "turn": {"id": "queued", "status": "inProgress"}}),
                ),
                message(
                    "item/started",
                    json!({"threadId": thread, "turnId": "queued", "item": {
                        "type": "userMessage", "id": "user-1", "clientId": "queued-message", "content": []
                    }}),
                ),
                message(
                    "item/completed",
                    json!({"threadId": thread, "turnId": "queued", "item": {
                        "type": "agentMessage", "id": "agent-1", "text": "Queued reply"
                    }}),
                ),
                message(
                    "turn/completed",
                    json!({"threadId": thread, "turn": {"id": "queued", "status": "completed"}}),
                ),
            ];
            if started_during_disconnect {
                frames[0]["result"]["thread"]["turns"] = json!([
                    {"id": "first", "status": "completed", "items": []},
                    {"id": "queued", "status": "inProgress", "items": [{
                        "type": "userMessage", "id": "user-1", "clientId": "queued-message", "content": []
                    }]}
                ]);
                frames.drain(1..4);
            }
            for frame in frames {
                websocket
                    .send(UpstreamMessage::Text(frame.to_string()))
                    .await
                    .expect("observer frame send");
            }
            loop {
                let frame = websocket
                    .next()
                    .await
                    .expect("unsubscribe frame")
                    .expect("unsubscribe");
                let UpstreamMessage::Text(raw) = frame else {
                    continue;
                };
                let message: Value = serde_json::from_str(&raw).expect("unsubscribe JSON");
                if message["method"] == "thread/unsubscribe" {
                    assert_eq!(message["params"]["threadId"], thread);
                    let _ = unsubscribe_tx.send(());
                    break;
                }
            }
        });

        let codex = Arc::new(CodexAppServer::new_for_test_socket(
            codex_home.path().to_path_buf(),
        ));
        let gateway = crate::test_support::TestGateway::with_settings(
            codex,
            claude_test.settings.clone(),
            Arc::new(claude_test),
        );
        let (completion_tx, mut completion_rx) = mpsc::channel(4);
        *gateway.apns_completion_tx.lock().await = Some(completion_tx);
        {
            let mut core = gateway.core.lock().await;
            core.turns.mark_active(
                &TurnKey::new(thread, "first"),
                unix_seconds(),
                Some(unix_seconds()),
                Some(42),
            );
            core.turns
                .enqueue(
                    thread,
                    crate::turns::QueuedSubmission {
                        client_user_message_id: "queued-message".to_owned(),
                        queued_submission_id: Some("native-1".to_owned()),
                        context: PromptContext {
                            compaction: false,
                            preview: "Queued work".to_owned(),
                            cwd: Some("/repo".to_owned()),
                            owner_client_id: 42,
                        },
                        created_at_unix_seconds: unix_seconds(),
                    },
                )
                .expect("queue lease");
        }
        gateway.spawn_observers_for_client(42).await;
        assert_eq!(gateway.observer_tasks.lock().await.len(), 1);

        tokio::time::timeout(Duration::from_secs(5), unsubscribe_rx)
            .await
            .expect("observer did not unsubscribe")
            .expect("unsubscribe signal");
        fake_codex.await.expect("fake Codex");
        let first = completion_rx.recv().await.expect("first completion");
        let queued = completion_rx.recv().await.expect("queued completion");
        assert_eq!(first.payload["eventID"], format!("{thread}:first"));
        assert_eq!(queued.payload["eventID"], format!("{thread}:queued"));
        assert_eq!(queued.subtitle, "Queued work");
        assert_eq!(queued.body, "Queued reply");
        assert_eq!(queued.payload["workingDirectory"], "/repo");
        let core = gateway.core.lock().await;
        assert_eq!(core.turns.active_count(), 0);
        assert!(!core.turns.awaits_queued_successor(thread));
    }
}

#[tokio::test]
async fn draining_gateway_does_not_recover_persisted_observers() {
    let gateway = test_gateway();
    {
        let mut core = gateway.core.lock().await;
        core.turns.mark_active(
            &TurnKey::new("thread-observed", "observed"),
            unix_seconds(),
            Some(unix_seconds()),
            Some(42),
        );
    }
    gateway.draining.store(true, Ordering::Release);

    gateway.spawn_persisted_observers().await;
    gateway.schedule_persisted_observer_scan();
    tokio::task::yield_now().await;

    assert!(gateway.observer_tasks.lock().await.is_empty());
}

#[test]
fn claude_effort_is_clamped_to_what_the_cli_accepts() {
    assert_eq!(claude_effort_wire_value("xhigh"), "xhigh");
    // The app offers an "ultra" step that `claude --effort` does not know.
    assert_eq!(claude_effort_wire_value("ultra"), "max");
}

fn message(method: &str, params: Value) -> Value {
    json!({"method": method, "params": params})
}

fn frame(method: &str, params: Value) -> String {
    message(method, params).to_string()
}

pub(super) fn external_voice_session() -> VoiceSession {
    VoiceSession {
        owner_client_id: 1,
        realtime_session_id: "session-1".to_string(),
        realtime_thread_id: "realtime-1".to_string(),
        conversation_thread_id: "claude-session-1".to_string(),
        model: "sonnet".to_string(),
        effort: Some("high".to_string()),
        cwd: "/tmp".to_string(),
        uses_external_executor: true,
        delegations: VoiceDelegations::new(),
        tail_flush_dispatched: false,
        greeted: false,
        farewell: Some(crate::voice::farewell::FarewellWatch::default()),
        started_at_unix_seconds: 0.0,
        log: None,
    }
}

#[tokio::test]
async fn control_connection_delivers_one_realtime_notification_to_its_owner() {
    let gateway = test_gateway();
    let (client_tx, mut client_rx) = mpsc::channel(4);
    gateway.clients.insert(1, test_client(1, client_tx));
    gateway.voice.seed(None, Some(external_voice_session()));
    let notification = frame(
        "thread/realtime/sdp",
        json!({"threadId": "realtime-1", "sdp": "answer"}),
    );

    gateway
        .handle_control_text(notification.clone(), CONTROL)
        .await;

    let ClientCommand::Text(delivered) = client_rx.recv().await.expect("notification") else {
        panic!("expected a text notification");
    };
    let delivered_value: Value = serde_json::from_str(&delivered).expect("notification JSON");
    assert_eq!(delivered_value["rcSequence"], 1);
    let notification_value: Value = serde_json::from_str(&notification).expect("source JSON");
    assert_eq!(delivered_value["params"], notification_value["params"]);
    assert!(client_rx.try_recv().is_err());
}

/// Answers every control request with an empty result and records it.
pub(crate) fn spawn_control_responder(
    gateway: &Arc<Gateway>,
    mut out_rx: mpsc::Receiver<String>,
) -> Arc<Mutex<Vec<Value>>> {
    let captured = Arc::new(Mutex::new(Vec::new()));
    let task_captured = Arc::clone(&captured);
    let task_gateway = Arc::clone(gateway);
    tokio::spawn(async move {
        while let Some(raw) = out_rx.recv().await {
            let request: Value = serde_json::from_str(&raw).expect("control request JSON");
            task_captured.lock().await.push(request.clone());
            let result = if request["method"] == "thread/read" {
                json!({ "thread": { "id": request["params"]["threadId"], "model": "gpt-5.6-luna", "reasoningEffort": "high" } })
            } else {
                json!({})
            };
            answer_internal_request(&task_gateway, &request, result).await;
        }
    });
    captured
}

#[tokio::test]
async fn automatic_reconnect_cannot_replace_a_newer_call() {
    let gateway = test_gateway();
    let mut existing = external_voice_session();
    existing.owner_client_id = 7;
    existing.realtime_session_id = "existing-session".into();
    gateway.voice.seed(None, Some(existing));

    let request: RealtimeVoiceStartRequest = serde_json::from_value(json!({
        "conversationThreadId": "codex-provisional-thread",
        "realtimeSessionId": "session-codex-provisional",
        "replaceExistingSession": false,
        "cwd": "/tmp/project",
        "model": "gpt-5.6-terra",
        "effort": "medium",
        "sdp": "v=0\r\no=remote-coder\r\n",
        "voice": "cove",
        "initialItems": []
    }))
    .expect("voice start request");

    let error = gateway
        .start_voice_session(8, request, VoiceSessionOrigin::VoiceMode)
        .await
        .expect_err("an old automatic reconnect must not replace the call");
    assert!(
        error
            .to_string()
            .contains("superseded by a newer voice call")
    );
    assert_eq!(
        gateway.voice.owner(),
        Some(VoiceSessionOwner {
            client_id: 7,
            realtime_session_id: "existing-session".to_string(),
        })
    );
}

#[tokio::test]
async fn automatic_reconnect_cannot_reclaim_an_agent_ended_call() {
    let gateway = test_gateway();
    gateway.voice.seed_ended_call("session-ended");

    let request: RealtimeVoiceStartRequest = serde_json::from_value(json!({
        "conversationThreadId": "codex-provisional-thread",
        "realtimeSessionId": "session-ended",
        "replaceExistingSession": false,
        "cwd": "/tmp/project",
        "model": "gpt-5.6-terra",
        "sdp": "v=0\r\n"
    }))
    .expect("voice start request");

    let error = gateway
        .start_voice_session(8, request, VoiceSessionOrigin::VoiceMode)
        .await
        .expect_err("an automatic reconnect must not resurrect an agent-ended call");
    assert!(error.to_string().contains(VOICE_CALL_AGENT_ENDED_ERROR));
    assert_eq!(gateway.voice.ended_call().as_deref(), Some("session-ended"));
}

#[tokio::test]
async fn voice_provider_nonterminal_error_keeps_the_call_and_independent_activity() {
    let gateway = test_gateway();
    let (client_tx, mut client_rx) = mpsc::channel(4);
    gateway.clients.insert(1, test_client(1, client_tx));
    gateway.voice.seed(None, Some(external_voice_session()));
    let mut control = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;
    let params = json!({
        "threadId": "realtime-1", "message": "Provider diagnostic", "terminal": false,
        "providerError": {"code": "provider_code"}
    });
    gateway
        .handle_control_text(frame("thread/realtime/error", params.clone()), CONTROL)
        .await;
    let ClientCommand::Text(delivered) = client_rx.recv().await.expect("original error") else {
        panic!("expected a text notification");
    };
    let delivered: Value = serde_json::from_str(&delivered).unwrap();
    assert_eq!(delivered["params"], params);
    assert!(client_rx.try_recv().is_err());
    assert!(gateway.voice.live_realtime_thread("session-1").is_some());
    assert!(gateway.voice.ended_call().is_none());
    gateway
        .handle_voice_control_notification(&frame(
            "thread/realtime/transcript/done",
            json!({
                "threadId": "realtime-1", "role": "user", "text": "An independent question"
            }),
        ))
        .await;
    assert!(gateway.voice.live_realtime_thread("session-1").is_some());
    assert!(
        control.try_recv().is_err(),
        "a diagnostic must not retry output or restart media"
    );
}

#[tokio::test]
async fn voice_terminal_error_defaults_to_terminal_for_legacy_runtime_notifications() {
    for terminal in [None, Some(json!(true))] {
        let gateway = test_gateway();
        gateway.voice.seed(None, Some(external_voice_session()));
        let mut params = json!({"threadId": "realtime-1", "message": "Internal failure"});
        if let Some(terminal) = terminal {
            params["terminal"] = terminal;
        }
        gateway
            .handle_voice_control_notification(&frame("thread/realtime/error", params))
            .await;
        assert!(gateway.voice.session().is_none());
        let transition = gateway.voice.transition().await;
        assert!(
            gateway
                .voice
                .begin_start(&transition, 1, "session-1", false)
                .is_err()
        );
    }
}

#[tokio::test]
async fn voice_provider_closure_preserves_the_reason_and_fences_automatic_reclaim() {
    for reason in [
        None,
        Some(Value::Null),
        Some(json!("close_requested")),
        Some(json!("expired")),
        Some(json!("content")),
        Some(json!("remote_hangup")),
        Some(json!("connection_lost")),
        Some(json!("future_reason")),
        Some(json!("requested")),
        Some(json!("error")),
    ] {
        let gateway = test_gateway();
        let (client_tx, mut client_rx) = mpsc::channel(4);
        gateway.clients.insert(1, test_client(1, client_tx));
        gateway.voice.seed(None, Some(external_voice_session()));
        let mut params = json!({"threadId": "realtime-1"});
        if let Some(reason) = reason {
            params["reason"] = reason;
        }
        gateway
            .handle_control_text(frame("thread/realtime/closed", params.clone()), CONTROL)
            .await;
        let ClientCommand::Text(delivered) = client_rx.recv().await.expect("original closure")
        else {
            panic!("expected a text notification");
        };
        let delivered: Value = serde_json::from_str(&delivered).unwrap();
        assert_eq!(delivered["params"], params);
        assert!(
            client_rx.try_recv().is_err(),
            "closure must not fabricate another error"
        );
        assert!(gateway.voice.session().is_none());
        let request = serde_json::from_value(json!({
            "conversationThreadId": "codex-thread", "realtimeSessionId": "session-1",
            "replaceExistingSession": false, "cwd": "/tmp/project",
            "model": "gpt-5.6-terra", "sdp": "v=0\r\n"
        }))
        .unwrap();
        let error = gateway
            .start_voice_session(1, request, VoiceSessionOrigin::VoiceMode)
            .await
            .expect_err("provider closure refuses automatic reclaim");
        assert!(error.to_string().contains(VOICE_CALL_AGENT_ENDED_ERROR));
    }
}

#[tokio::test]
async fn voice_provider_reserved_reasons_fence_every_session_phase() {
    for reason in ["transport_closed", "requested", "error"] {
        for phase in ["active", "draining", "starting", "retiring"] {
            let gateway = test_gateway();
            let (client_tx, mut client_rx) = mpsc::channel(4);
            gateway.clients.insert(1, test_client(1, client_tx));
            gateway.voice.seed(None, Some(external_voice_session()));
            if phase == "retiring" {
                let transition = gateway.voice.transition().await;
                gateway
                    .voice
                    .begin_start(&transition, 1, "session-1", false)
                    .unwrap();
            }
            let transition = gateway.voice.transition().await;
            match phase {
                "draining" => {
                    gateway.voice.begin_stop(&transition, 1);
                }
                "starting" => {
                    gateway
                        .voice
                        .begin_start(&transition, 1, "session-1", false)
                        .unwrap();
                }
                _ => {}
            }
            let params = json!({
                "threadId": "realtime-1", "reason": reason, "providerClosed": true
            });
            gateway
                .handle_control_text(frame("thread/realtime/closed", params.clone()), CONTROL)
                .await;
            let ClientCommand::Text(delivered) = client_rx.recv().await.expect("provider closure")
            else {
                panic!("expected a text notification");
            };
            let delivered: Value = serde_json::from_str(&delivered).unwrap();
            assert_eq!(delivered["params"], params);
            assert_eq!(
                gateway.voice.ended_call().as_deref(),
                Some("session-1"),
                "{phase}: {reason}"
            );
            assert!(gateway.voice.session().is_none());
            assert!(gateway.voice.owner().is_none());
            assert!(
                gateway
                    .voice
                    .begin_start(&transition, 1, "session-1", false)
                    .is_err()
            );
            let admission = gateway
                .voice
                .begin_start(&transition, 1, "session-1", true)
                .unwrap();
            assert!(admission.predecessor_closed.is_none());
            assert!(gateway.voice.install(&transition, external_voice_session()));
        }
    }
}

#[tokio::test]
async fn voice_provider_closure_allows_a_new_explicit_user_start() {
    let gateway = test_gateway();
    let (client_tx, _client_rx) = mpsc::channel(4);
    gateway.clients.insert(1, test_client(1, client_tx));
    gateway.voice.seed(None, Some(external_voice_session()));
    gateway
        .handle_voice_control_notification(&frame(
            "thread/realtime/closed",
            json!({
                "threadId": "realtime-1", "reason": "content"
            }),
        ))
        .await;
    let control = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;
    let captured = spawn_control_responder(&gateway, control);
    let request = serde_json::from_value(json!({
        "conversationThreadId": "codex-thread", "realtimeSessionId": "session-1",
        "replaceExistingSession": true, "cwd": "/tmp/project",
        "model": "gpt-5.6-terra", "sdp": "v=0\r\n"
    }))
    .unwrap();
    let response = gateway
        .start_voice_session(1, request, VoiceSessionOrigin::VoiceMode)
        .await
        .expect("explicit user start may begin a new session");
    assert_eq!(response.realtime_thread_id, "codex-thread");
    assert!(gateway.voice.ended_call().is_none());
    assert_eq!(
        captured
            .lock()
            .await
            .iter()
            .filter(|frame| frame["method"] == "thread/realtime/start")
            .count(),
        1
    );
}

#[tokio::test]
async fn voice_local_stop_during_automatic_reclaim_keeps_the_pending_start() {
    for reason in ["requested", "transport_closed"] {
        let gateway = test_gateway();
        gateway.voice.seed(None, Some(external_voice_session()));
        let transition = gateway.voice.transition().await;
        gateway
            .voice
            .begin_start(&transition, 1, "session-1", false)
            .unwrap();
        gateway
            .handle_voice_control_notification(&frame(
                "thread/realtime/closed",
                json!({
                    "threadId": "realtime-1", "reason": reason
                }),
            ))
            .await;
        assert!(
            gateway.voice.install(&transition, external_voice_session()),
            "{reason}"
        );
        assert!(gateway.voice.ended_call().is_none());
    }
}

#[tokio::test]
async fn voice_same_thread_replacement_uses_closed_as_its_receipt_and_keeps_error_distinct() {
    for (replace, reason, provider_closed, proceeds) in [
        (false, json!("requested"), None, true),
        (false, json!("transport_closed"), None, true),
        (false, json!("close_requested"), None, false),
        (false, json!("content"), None, false),
        (false, Value::Null, None, false),
        (true, json!("content"), None, true),
        (false, json!("requested"), Some(true), false),
        (false, json!("transport_closed"), Some(true), false),
        (false, json!("error"), Some(true), false),
        (true, json!("transport_closed"), Some(true), true),
    ] {
        let gateway = test_gateway();
        let mut session = external_voice_session();
        session.realtime_thread_id = "codex-thread".into();
        session.conversation_thread_id = "codex-thread".into();
        session.uses_external_executor = false;
        gateway.voice.seed(None, Some(session.clone()));
        let transition = gateway.voice.transition().await;
        let mut admission = gateway
            .voice
            .begin_start(&transition, 1, "session-1", replace)
            .unwrap();
        let mut receipt = admission
            .predecessor_closed
            .take()
            .expect("predecessor receipt");
        assert!(
            !gateway.voice.install(&transition, session.clone()),
            "queue admission cannot replace closure"
        );
        if replace {
            gateway
                .handle_voice_control_notification(&frame(
                    "thread/realtime/error",
                    json!({
                        "threadId": "codex-thread", "message": "Terminal predecessor error"
                    }),
                ))
                .await;
            assert!(matches!(
                receipt.try_recv(),
                Err(tokio::sync::oneshot::error::TryRecvError::Empty)
            ));
            assert!(
                !gateway.voice.install(&transition, session.clone()),
                "Error is not a Closed receipt"
            );
        }
        let mut params = json!({"threadId": "codex-thread", "reason": reason});
        if let Some(provider_closed) = provider_closed {
            params["providerClosed"] = json!(provider_closed);
        }
        gateway
            .handle_voice_control_notification(&frame("thread/realtime/closed", params))
            .await;
        assert_eq!(receipt.await.is_ok(), proceeds);
        assert_eq!(gateway.voice.install(&transition, session), proceeds);
    }
}

#[tokio::test]
async fn voice_automatic_reclaim_cannot_switch_sessions_on_the_same_client() {
    let gateway = test_gateway();
    gateway.voice.seed(None, Some(external_voice_session()));
    let transition = gateway.voice.transition().await;
    assert!(
        gateway
            .voice
            .begin_start(&transition, 1, "other-session", false)
            .is_err()
    );
    assert_eq!(
        gateway.voice.live_realtime_thread("session-1").as_deref(),
        Some("realtime-1")
    );
}

#[tokio::test]
async fn voice_cancelled_start_keeps_the_predecessor_until_its_actual_close() {
    let gateway = test_gateway();
    gateway.voice.seed(None, Some(external_voice_session()));
    {
        let transition = gateway.voice.transition().await;
        gateway
            .voice
            .begin_start(&transition, 1, "session-1", false)
            .unwrap();
    }
    assert!(gateway.voice.owner().is_none());
    assert!(gateway.voice.session().is_none());
    let transition = gateway.voice.transition().await;
    let mut admission = gateway
        .voice
        .begin_start(&transition, 1, "session-1", true)
        .unwrap();
    let receipt = admission
        .predecessor_closed
        .take()
        .expect("unclosed predecessor retained");
    assert!(!gateway.voice.install(&transition, external_voice_session()));
    gateway
        .handle_voice_control_notification(&frame(
            "thread/realtime/closed",
            json!({
                "threadId": "realtime-1", "reason": "requested"
            }),
        ))
        .await;
    receipt.await.unwrap();
    assert!(gateway.voice.install(&transition, external_voice_session()));
}

#[tokio::test]
async fn voice_terminal_error_still_requires_closed_before_the_next_explicit_start() {
    let gateway = test_gateway();
    gateway.voice.seed(None, Some(external_voice_session()));
    gateway
        .handle_voice_control_notification(&frame(
            "thread/realtime/error",
            json!({
                "threadId": "realtime-1", "message": "Terminal failure"
            }),
        ))
        .await;
    let transition = gateway.voice.transition().await;
    let mut admission = gateway
        .voice
        .begin_start(&transition, 1, "session-1", true)
        .unwrap();
    let receipt = admission
        .predecessor_closed
        .take()
        .expect("Error is not a Closed receipt");
    assert!(!gateway.voice.install(&transition, external_voice_session()));
    gateway
        .handle_voice_control_notification(&frame(
            "thread/realtime/closed",
            json!({
                "threadId": "realtime-1", "reason": "error"
            }),
        ))
        .await;
    receipt.await.unwrap();
    assert!(gateway.voice.install(&transition, external_voice_session()));
}

#[tokio::test(start_paused = true)]
async fn voice_start_timeout_preserves_the_pending_transport_and_sends_no_successor_start() {
    let gateway = test_gateway();
    let mut previous = external_voice_session();
    previous.realtime_thread_id = "codex-thread".into();
    previous.conversation_thread_id = "codex-thread".into();
    previous.uses_external_executor = false;
    gateway.voice.seed(None, Some(previous));
    let (client_tx, _client_rx) = mpsc::channel(4);
    gateway.clients.insert(1, test_client(1, client_tx));
    let mut control = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;
    let request = serde_json::from_value(json!({
        "conversationThreadId": "codex-thread", "realtimeSessionId": "session-1",
        "replaceExistingSession": false, "cwd": "/tmp/project",
        "model": "gpt-5.6-terra", "sdp": "v=0\r\n"
    }))
    .unwrap();
    let start = {
        let gateway = Arc::clone(&gateway);
        tokio::spawn(async move {
            gateway
                .start_voice_session(1, request, VoiceSessionOrigin::VoiceMode)
                .await
        })
    };
    let stop: Value = serde_json::from_str(&control.recv().await.unwrap()).unwrap();
    assert_eq!(stop["method"], "thread/realtime/stop");
    answer_internal_request(&gateway, &stop, json!({})).await;
    let error = start
        .await
        .unwrap()
        .expect_err("queue admission must not permit successor startup");
    assert!(
        error
            .to_string()
            .contains("previous voice transport did not close")
    );
    assert!(control.try_recv().is_err());
    assert!(gateway.voice.owner().is_none());
    assert_eq!(
        gateway
            .voice
            .owner_client_of_realtime_thread("codex-thread"),
        Some(1)
    );
    gateway
        .handle_voice_control_notification(&frame(
            "thread/realtime/closed",
            json!({
                "threadId": "other-thread", "reason": "requested"
            }),
        ))
        .await;
    assert_eq!(
        gateway
            .voice
            .owner_client_of_realtime_thread("codex-thread"),
        Some(1)
    );
    gateway
        .handle_voice_control_notification(&frame(
            "thread/realtime/closed",
            json!({
                "threadId": "codex-thread", "reason": "requested"
            }),
        ))
        .await;
    assert_eq!(
        gateway
            .voice
            .owner_client_of_realtime_thread("codex-thread"),
        None
    );
}

#[tokio::test]
async fn voice_restart_after_the_drain_observed_closed_does_not_require_a_duplicate_receipt() {
    let gateway = test_gateway();
    gateway.voice.seed(None, Some(external_voice_session()));
    let transition = gateway.voice.transition().await;
    gateway.voice.begin_stop(&transition, 1);
    gateway
        .handle_voice_control_notification(&frame(
            "thread/realtime/closed",
            json!({
                "threadId": "realtime-1", "reason": "requested"
            }),
        ))
        .await;
    let admission = gateway
        .voice
        .begin_start(&transition, 1, "session-1", true)
        .unwrap();
    assert!(admission.predecessor_closed.is_none());
    assert!(gateway.voice.install(&transition, external_voice_session()));
}

#[tokio::test]
async fn voice_provider_closure_invalidates_an_automatic_start_without_waiting() {
    let gateway = test_gateway();
    let (client_tx, mut client_rx) = mpsc::channel(4);
    gateway.clients.insert(1, test_client(1, client_tx));
    gateway.voice.seed(None, Some(external_voice_session()));
    let transition = gateway.voice.transition().await;
    gateway
        .voice
        .begin_start(&transition, 1, "session-1", false)
        .unwrap();
    tokio::time::timeout(
        Duration::from_secs(1),
        gateway.handle_control_text(
            frame(
                "thread/realtime/closed",
                json!({"threadId": "realtime-1", "reason": "content"}),
            ),
            CONTROL,
        ),
    )
    .await
    .expect("control notifications must not wait for a start's transition lock");
    let ClientCommand::Text(delivered) = client_rx.recv().await.expect("closure during reclaim")
    else {
        panic!("expected a text notification");
    };
    let delivered: Value = serde_json::from_str(&delivered).unwrap();
    assert_eq!(delivered["params"]["reason"], "content");
    assert!(!gateway.voice.install(&transition, external_voice_session()));
    assert!(
        gateway
            .voice
            .begin_start(&transition, 1, "session-1", false)
            .is_err()
    );
}

#[tokio::test]
async fn voice_provider_stale_closure_does_not_end_a_replacement_call_or_explicit_start() {
    for starting in [false, true] {
        let gateway = test_gateway();
        let mut current = external_voice_session();
        current.realtime_session_id = "new-session".into();
        current.realtime_thread_id = "new-realtime".into();
        gateway.voice.seed(
            None,
            Some(if starting {
                external_voice_session()
            } else {
                current.clone()
            }),
        );
        let transition = gateway.voice.transition().await;
        if starting {
            gateway
                .voice
                .begin_start(&transition, 1, "new-session", true)
                .unwrap();
        }
        gateway
            .handle_voice_control_notification(&frame(
                "thread/realtime/closed",
                json!({
                    "threadId": "realtime-1", "reason": "content"
                }),
            ))
            .await;
        assert!(gateway.voice.ended_call().is_none());
        if starting {
            assert!(gateway.voice.install(&transition, current));
        }
        assert_eq!(
            gateway.voice.live_realtime_thread("new-session").as_deref(),
            Some("new-realtime")
        );
    }
}

#[tokio::test]
async fn voice_legacy_transport_loss_can_reconnect_but_provider_closure_overrides_draining() {
    let gateway = test_gateway();
    gateway.voice.seed(None, Some(external_voice_session()));
    gateway
        .handle_voice_control_notification(&frame(
            "thread/realtime/closed",
            json!({
                "threadId": "realtime-1", "reason": "transport_closed"
            }),
        ))
        .await;
    assert!(gateway.voice.session().is_none());
    let transition = gateway.voice.transition().await;
    gateway
        .voice
        .begin_start(&transition, 1, "session-1", false)
        .unwrap();
    assert!(gateway.voice.install(&transition, external_voice_session()));
    gateway.voice.begin_stop(&transition, 1);
    gateway
        .handle_voice_control_notification(&frame(
            "thread/realtime/closed",
            json!({
                "threadId": "realtime-1", "reason": "requested"
            }),
        ))
        .await;
    assert!(gateway.voice.is_draining());
    gateway
        .handle_voice_control_notification(&frame(
            "thread/realtime/closed",
            json!({
                "threadId": "realtime-1", "reason": "content"
            }),
        ))
        .await;
    assert!(gateway.voice.session().is_none());
    assert!(
        gateway
            .voice
            .begin_start(&transition, 1, "session-1", false)
            .is_err()
    );
}

#[tokio::test]
async fn owned_error_kinds_match_the_shared_protocol_fixtures() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    async fn next_reply(rx: &mut mpsc::Receiver<ClientCommand>) -> Value {
        let Some(ClientCommand::Text(text)) = rx.recv().await else {
            panic!("expected a JSON reply")
        };
        serde_json::from_str(&text).expect("reply json")
    }
    async fn owned_reply(gateway: &Arc<Gateway>, id: &Value, method: &str, params: Value) -> Value {
        let (tx, mut rx) = mpsc::channel(1);
        let mut object = request(method, params);
        object.insert("id".to_string(), id.clone());
        let target = match DispatchPlan::parse(&Value::Object(object.clone()).to_string()) {
            DispatchPlan::Request(request) => request.owned.expect("gateway-owned method").target,
            _ => panic!("{method} is not a request"),
        };
        gateway
            .handle_owned_rpc(1, &test_client(1, tx), method, target, &object)
            .await
            .expect("owned rpc");
        next_reply(&mut rx).await
    }
    fn fixture(raw: &str) -> Value {
        serde_json::from_str(raw).expect("fixture json")
    }
    fn assert_fixture_shape(reply: &Value, fixture: &Value) {
        let mut expected = fixture.clone();
        let message = &reply["error"]["message"];
        assert!(
            message.as_str().is_some_and(|message| !message.is_empty()),
            "{reply}"
        );
        expected["error"]["message"] = message.clone();
        if let Some(updated_at) = expected.pointer_mut("/error/data/current/updatedAt") {
            let emitted = &reply["error"]["data"]["current"]["updatedAt"];
            assert!(emitted.is_f64(), "{reply}");
            *updated_at = emitted.clone();
        }
        assert_eq!(reply, &expected);
    }

    let directory = tempfile::tempdir().expect("state directory");
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let gateway = Gateway::with_turn_state(
        codex,
        claude_test.settings.clone(),
        Journal::disabled(),
        Some(directory.path().join("turn-state.json")),
    );

    let update = fixture(include_str!(
        "../../../protocol-fixtures/metadata-update.json"
    ));
    let applied_revision = update["expectedRevision"]
        .as_u64()
        .expect("expected revision");
    for revision in 0..=applied_revision {
        let mut seed = update.clone();
        seed["expectedRevision"] = json!(revision);
        if revision < applied_revision {
            seed["mutationId"] = json!(format!("seed-{revision}"));
        }
        let reply = owned_reply(
            &gateway,
            &json!(revision),
            "conversation/metadata/update",
            seed,
        )
        .await;
        assert_eq!(reply["result"]["serverRevision"], revision + 1, "{reply}");
    }
    let conflict = fixture(include_str!(
        "../../../protocol-fixtures/metadata-conflict.json"
    ));
    let mut competing = update;
    competing["mutationId"] = json!("competing-client");
    let reply = owned_reply(
        &gateway,
        &conflict["id"],
        "conversation/metadata/update",
        competing,
    )
    .await;
    assert_fixture_shape(&reply, &conflict);

    let voice_ended = fixture(include_str!(
        "../../../protocol-fixtures/voice-call-ended.json"
    ));
    gateway.voice.seed_ended_call("session-ended");
    let reply = owned_reply(
        &gateway,
        &voice_ended["id"],
        "voice/session/start",
        json!({
            "conversationThreadId": "codex-provisional-thread",
            "realtimeSessionId": "session-ended",
            "replaceExistingSession": false,
            "cwd": "/tmp/project",
            "model": "gpt-5.6-terra",
            "sdp": "v=0\r\n"
        }),
    )
    .await;
    assert_fixture_shape(&reply, &voice_ended);

    let capacity = fixture(include_str!(
        "../../../protocol-fixtures/request-capacity.json"
    ));
    let (tx, mut rx) = mpsc::channel(1);
    gateway
        .respond(
            &test_client(1, tx),
            capacity["id"].clone(),
            Err(RpcError::capacity()),
            None,
        )
        .await
        .expect("capacity reply");
    assert_fixture_shape(&next_reply(&mut rx).await, &capacity);
}

#[tokio::test]
async fn devices_register_and_unregister_round_trip_the_shared_fixture() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let gateway = Gateway::with_turn_state(
        Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        )),
        claude_test.settings.clone(),
        Journal::disabled(),
        None,
    );
    let registration: Value = serde_json::from_str(include_str!(
        "../../../protocol-fixtures/devices/register.json"
    ))
    .expect("fixture json");
    for (method, params) in [
        ("devices/register", registration.clone()),
        (
            "devices/unregister",
            json!({"deviceId": registration["deviceId"]}),
        ),
    ] {
        let (tx, mut rx) = mpsc::channel(1);
        let mut object = request(method, params);
        object.insert("id".to_string(), json!(1));
        let target = match DispatchPlan::parse(&Value::Object(object.clone()).to_string()) {
            DispatchPlan::Request(request) => request.owned.expect("gateway-owned method").target,
            _ => panic!("{method} is not a request"),
        };
        gateway
            .handle_owned_rpc(1, &test_client(1, tx), method, target, &object)
            .await
            .expect("owned rpc");
        let Some(ClientCommand::Text(text)) = rx.recv().await else {
            panic!("expected a JSON reply")
        };
        let reply: Value = serde_json::from_str(&text).expect("reply json");
        assert!(reply["error"].is_null(), "{reply}");
        if method == "devices/register" {
            assert!(
                reply["result"]["hostId"]
                    .as_str()
                    .is_some_and(|host| !host.is_empty())
            );
            assert_eq!(
                gateway.apns.devices().alert_targets().await.unwrap().len(),
                1
            );
        } else {
            assert_eq!(reply["result"], json!({}));
            assert!(
                gateway
                    .apns
                    .devices()
                    .alert_targets()
                    .await
                    .unwrap()
                    .is_empty()
            );
        }
    }
}

#[tokio::test]
async fn agent_end_tombstones_the_call_and_notifies_clients_before_stopping() {
    let gateway = test_gateway();
    let (client_tx, mut client_rx) = mpsc::channel(4);
    gateway.clients.insert(7, test_client(7, client_tx));
    gateway.voice.seed(None, Some(external_voice_session()));
    let out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;
    let captured = spawn_control_responder(&gateway, out_rx);

    assert!(
        gateway
            .end_voice_call_for_agent(&crate::agents::tools::Caller {
                turn_id: None,
                provider: crate::providers::Provider::Claude,
                thread_id: Some("claude-session-1".to_string()),
            })
            .await
    );

    let ClientCommand::Text(notification) =
        client_rx.recv().await.expect("agent-ended notification")
    else {
        panic!("expected a text notification");
    };
    let notification: Value = serde_json::from_str(&notification).expect("agent-ended json");
    assert_eq!(notification["method"], "voice/session/agentEnded");
    assert_eq!(notification["params"]["realtimeSessionId"], "session-1");
    assert_eq!(notification["params"]["realtimeThreadId"], "realtime-1");
    assert_eq!(gateway.voice.ended_call().as_deref(), Some("session-1"));
    let stop = captured.lock().await;
    assert_eq!(stop.len(), 1);
    assert_eq!(stop[0]["method"], "thread/realtime/stop");
}

#[tokio::test(start_paused = true)]
async fn the_voice_goodbye_ends_the_call_once_its_audio_goes_quiet() {
    let gateway = test_gateway();
    let (client_tx, mut client_rx) = mpsc::channel(4);
    gateway.clients.insert(7, test_client(7, client_tx));
    gateway.voice.seed(None, Some(external_voice_session()));
    let out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;
    let captured = spawn_control_responder(&gateway, out_rx);

    for (role, text) in [
        ("user", "You can hang up the call now"),
        ("assistant", "Alright. Bye!"),
    ] {
        gateway
            .handle_voice_control_notification(
                &json!({"method":"thread/realtime/transcript/done","params":{
                    "threadId":"realtime-1","role":role,"text":text
                }})
                .to_string(),
            )
            .await;
    }
    let armed_at = tokio::time::Instant::now();
    assert!(gateway.voice.ended_call().is_none());

    let ClientCommand::Text(notification) =
        client_rx.recv().await.expect("agent-ended notification")
    else {
        panic!("expected a text notification");
    };
    assert_eq!(armed_at.elapsed(), crate::voice::farewell::FAREWELL_QUIET);
    assert!(gateway.voice.is_draining());
    let notification: Value = serde_json::from_str(&notification).expect("agent-ended json");
    assert_eq!(notification["method"], "voice/session/agentEnded");
    assert_eq!(gateway.voice.ended_call().as_deref(), Some("session-1"));
    while captured.lock().await.is_empty() {
        tokio::task::yield_now().await;
    }
    let stop = captured.lock().await;
    assert_eq!(stop.len(), 1);
    assert_eq!(stop[0]["method"], "thread/realtime/stop");
}

#[tokio::test]
async fn agent_end_refuses_missing_foreign_and_wrong_provider_identity() {
    let gateway = test_gateway();
    let owner = VoiceSessionOwner {
        client_id: 1,
        realtime_session_id: "session-1".to_string(),
    };
    gateway
        .voice
        .seed(Some(owner.clone()), Some(external_voice_session()));
    let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;

    for caller in [
        crate::agents::tools::Caller {
            turn_id: None,
            provider: crate::providers::Provider::Claude,
            thread_id: None,
        },
        crate::agents::tools::Caller {
            turn_id: None,
            provider: crate::providers::Provider::Claude,
            thread_id: Some("unrelated-thread".to_string()),
        },
        crate::agents::tools::Caller {
            turn_id: None,
            provider: crate::providers::Provider::Codex,
            thread_id: Some("claude-session-1".to_string()),
        },
    ] {
        assert!(!gateway.end_voice_call_for_agent(&caller).await);
    }

    assert_eq!(gateway.voice.owner(), Some(owner));
    assert!(gateway.voice.ended_call().is_none());
    assert!(gateway.voice.session().is_some() && !gateway.voice.is_draining());
    assert!(
        out_rx.try_recv().is_err(),
        "unauthorized hang-up must send no control request"
    );
}

#[tokio::test]
async fn user_start_restores_reclaim_authority_for_its_session() {
    let gateway = test_gateway();
    let (client_tx, _client_rx) = mpsc::channel(4);
    gateway.clients.insert(8, test_client(8, client_tx));
    gateway.voice.seed_ended_call("session-ended");
    let out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;
    let _captured = spawn_control_responder(&gateway, out_rx);

    let request: RealtimeVoiceStartRequest = serde_json::from_value(json!({
        "conversationThreadId": "codex-thread",
        "realtimeSessionId": "session-ended",
        "replaceExistingSession": true,
        "cwd": "/tmp/project",
        "model": "gpt-5.6-terra",
        "sdp": "v=0\r\n"
    }))
    .expect("voice start request");

    gateway
        .start_voice_session(8, request, VoiceSessionOrigin::VoiceMode)
        .await
        .expect("a user-initiated start reuses the stable session id");
    assert_eq!(gateway.voice.ended_call().as_deref(), None);
}

async fn answer_internal_request(gateway: &Arc<Gateway>, request: &Value, result: Value) {
    gateway
        .handle_control_text(
            serde_json::to_string(&json!({
                "id": request["id"],
                "result": result,
            }))
            .expect("response json"),
            CONTROL,
        )
        .await;
}

async fn answer_thread_load(
    gateway: &Arc<Gateway>,
    receiver: &mut mpsc::Receiver<String>,
    status: &str,
) {
    let read: Value =
        serde_json::from_str(&receiver.recv().await.expect("load check")).expect("JSON");
    assert_eq!(read["method"], "thread/read");
    assert_eq!(read["params"]["includeTurns"], false);
    answer_internal_request(
        gateway,
        &read,
        json!({"thread": {"status": {"type": status}}}),
    )
    .await;
}

async fn answer_voice_settings_read(gateway: &Arc<Gateway>, receiver: &mut mpsc::Receiver<String>) {
    let request: Value =
        serde_json::from_str(&receiver.recv().await.expect("settings read")).expect("request JSON");
    assert_eq!(request["method"], "thread/read");
    assert_eq!(request["params"]["includeTurns"], false);
    answer_internal_request(gateway, &request, json!({ "thread": { "id": request["params"]["threadId"], "model": "gpt-5.6-luna", "reasoningEffort": "high" } })).await;
}

#[tokio::test]
async fn codex_settings_do_not_request_history_until_a_thread_is_active() {
    let claude_test =
        Arc::new(crate::providers::claude::settings::ClaudeSettings::isolated_for_test());
    for (active, observed, tier) in [
        (false, false, Some(Value::Null)),
        (true, false, Some(Value::Null)),
        (true, true, Some(Value::Null)),
        (false, false, None),
        (true, true, None),
        (true, true, Some(json!("fast"))),
    ] {
        let codex = Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        ));
        let gateway = crate::test_support::TestGateway::with_settings(
            codex,
            claude_test.settings.clone(),
            Arc::clone(&claude_test),
        );
        if observed {
            let mut core = gateway.core.lock().await;
            core.turns.mark_active(
                &TurnKey::new("fresh-thread", "running-turn"),
                1.0,
                None,
                Some(1),
            );
        }
        let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
            .await
            .requests;
        let applying = {
            let gateway = Arc::clone(&gateway);
            let tier = tier.clone();
            tokio::spawn(async move {
                let mut params = json!({
                    "threadId": "fresh-thread", "model": "gpt-5.6-luna", "effort": "medium",
                });
                if let Some(tier) = tier {
                    params["serviceTier"] = tier;
                }
                gateway.update_conversation_settings(params).await
            })
        };
        answer_thread_load(
            &gateway,
            &mut out_rx,
            if active { "active" } else { "idle" },
        )
        .await;
        let defaults: Value =
            serde_json::from_str(&out_rx.recv().await.expect("future defaults")).expect("JSON");
        assert_eq!(defaults["method"], "thread/settings/update");
        assert_eq!(defaults["params"]["effort"], "medium");
        assert_eq!(defaults["params"].get("serviceTier"), tier.as_ref());
        answer_internal_request(&gateway, &defaults, json!({})).await;

        let read: Value =
            serde_json::from_str(&out_rx.recv().await.expect("live status")).expect("JSON");
        assert_eq!(read["method"], "thread/read");
        assert_eq!(read["params"]["includeTurns"], false);
        answer_internal_request(
            &gateway,
            &read,
            json!({
                "thread": { "status": { "type": if active { "active" } else { "idle" } } },
            }),
        )
        .await;

        if active {
            if !observed {
                let history: Value =
                    serde_json::from_str(&out_rx.recv().await.expect("active turn")).expect("JSON");
                assert_eq!(history["method"], "thread/turns/list");
                answer_internal_request(
                    &gateway,
                    &history,
                    json!({
                        "data": [{ "id": "running-turn", "status": "inProgress" }],
                    }),
                )
                .await;
            }
            let patch: Value =
                serde_json::from_str(&out_rx.recv().await.expect("hot settings")).expect("JSON");
            assert_eq!(patch["method"], "turn/settings/update");
            assert_eq!(patch["params"]["turnId"], "running-turn");
            assert_eq!(patch["params"]["model"], "gpt-5.6-luna");
            assert_eq!(patch["params"].get("serviceTier"), tier.as_ref());
            answer_internal_request(&gateway, &patch, json!({ "status": "applied" })).await;
        }
        let result = tokio::time::timeout(Duration::from_secs(1), applying)
            .await
            .expect("idle threads must finish without requesting an unavailable rollout")
            .expect("task")
            .expect("settings");
        assert_eq!(
            result["status"],
            if active { "applied" } else { "nextTurn" }
        );
        assert!(out_rx.try_recv().is_err());
    }
}

#[tokio::test]
async fn a_rejected_hot_change_still_acknowledges_accepted_future_defaults() {
    let gateway = test_gateway();
    let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;
    {
        let mut core = gateway.core.lock().await;
        core.turns
            .mark_active(&TurnKey::new("thread", "running-turn"), 1.0, None, Some(1));
    }
    let applying = {
        let gateway = Arc::clone(&gateway);
        tokio::spawn(async move {
            gateway
                .update_conversation_settings(json!({
                    "threadId": "thread", "model": "gpt-5.6-luna", "effort": "medium",
                }))
                .await
        })
    };
    answer_thread_load(&gateway, &mut out_rx, "active").await;
    let defaults: Value =
        serde_json::from_str(&out_rx.recv().await.expect("defaults")).expect("JSON");
    assert_eq!(defaults["method"], "thread/settings/update");
    answer_internal_request(&gateway, &defaults, json!({})).await;
    let read: Value = serde_json::from_str(&out_rx.recv().await.expect("status")).expect("JSON");
    answer_internal_request(
        &gateway,
        &read,
        json!({"thread":{"status":{"type":"active"}}}),
    )
    .await;
    let patch: Value =
        serde_json::from_str(&out_rx.recv().await.expect("hot change")).expect("JSON");
    assert_eq!(patch["method"], "turn/settings/update");
    assert_eq!(patch["params"]["turnId"], "running-turn");
    gateway.handle_control_text(json!({
        "id": patch["id"], "error": {"code":-32600,"message":"active model switching is disabled"},
    }).to_string(), CONTROL).await;
    let result = applying
        .await
        .expect("task")
        .expect("future settings were accepted");
    assert_eq!(result["status"], "nextTurn");
    let warning = result["warning"].as_str().expect("partial apply notice");
    assert!(warning.contains("saved for future turns"));
    assert!(warning.contains("active model switching is disabled"));
    assert!(out_rx.try_recv().is_err());
}

#[tokio::test]
async fn user_start_replaces_an_active_call_and_notifies_the_old_transport() {
    let gateway = test_gateway();
    let (old_tx, mut old_rx) = mpsc::channel(4);
    let (new_tx, _new_rx) = mpsc::channel(4);
    gateway.clients.insert(7, test_client(7, old_tx));
    gateway.clients.insert(8, test_client(8, new_tx));
    let mut old_session = external_voice_session();
    old_session.owner_client_id = 7;
    old_session.realtime_thread_id = "old-realtime-thread".to_string();
    gateway.voice.seed(
        Some(VoiceSessionOwner {
            client_id: 7,
            realtime_session_id: "old-session".to_string(),
        }),
        Some(old_session),
    );
    let mut upstream_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;

    let start = {
        let gateway = Arc::clone(&gateway);
        tokio::spawn(async move {
            let request: RealtimeVoiceStartRequest = serde_json::from_value(json!({
                "conversationThreadId": "new-codex-thread",
                "realtimeSessionId": "new-session",
                "replaceExistingSession": true,
                "cwd": "/tmp/project",
                "model": "gpt-5.6-terra",
                "sdp": "v=0\r\n"
            }))
            .expect("voice start request");
            gateway
                .start_voice_session(8, request, VoiceSessionOrigin::VoiceMode)
                .await
        })
    };

    let ClientCommand::Text(preempted) = old_rx.recv().await.expect("preempted notification")
    else {
        panic!("expected a text notification");
    };
    let preempted: Value = serde_json::from_str(&preempted).expect("preempted json");
    assert_eq!(preempted["method"], "voice/session/preempted");
    assert_eq!(preempted["params"]["realtimeSessionId"], "old-session");

    let stop_request: Value =
        serde_json::from_str(&upstream_rx.recv().await.expect("old stop request"))
            .expect("stop json");
    assert_eq!(stop_request["method"], "thread/realtime/stop");
    answer_internal_request(&gateway, &stop_request, json!({})).await;
    gateway
        .handle_control_text(
            frame(
                "thread/realtime/closed",
                json!({
                    "threadId": "old-realtime-thread", "reason": "requested"
                }),
            ),
            CONTROL,
        )
        .await;

    let start_request: Value =
        serde_json::from_str(&upstream_rx.recv().await.expect("new start request"))
            .expect("start json");
    assert_eq!(start_request["method"], "thread/realtime/start");
    answer_internal_request(&gateway, &start_request, json!({})).await;

    answer_voice_settings_read(&gateway, &mut upstream_rx).await;

    let response = start.await.expect("start task").expect("replacement start");
    assert_eq!(response.realtime_thread_id, "new-codex-thread");
    assert_eq!(response.model, "gpt-5.6-luna");
    assert_eq!(response.effort.as_deref(), Some("high"));
    assert_eq!(
        gateway.voice.owner(),
        Some(VoiceSessionOwner {
            client_id: 8,
            realtime_session_id: "new-session".to_string(),
        })
    );
}

#[tokio::test]
async fn realtime_handoff_request_during_restart_completes_as_a_visible_failure() {
    let gateway = test_gateway();
    gateway.voice.seed(None, Some(external_voice_session()));
    gateway.draining.store(true, Ordering::Release);

    let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 16)
        .await
        .requests;

    gateway
        .handle_voice_control_notification(&frame(
            "thread/realtime/itemAdded",
            json!({"threadId": "realtime-1", "item": {"type": "message", "role": "user"}}),
        ))
        .await;
    gateway
        .handle_voice_control_notification(&frame(
            "thread/realtime/itemAdded",
            json!({"threadId": "realtime-1", "item": {
                "type": "handoff_request",
                "handoff_id": "handoff-1",
                "item_id": "item-1",
                "input_transcript": "inspect the repository",
                "active_transcript": [{"role": "user", "text": "inspect the repository"}],
            }}),
        ))
        .await;

    let request: Value =
        serde_json::from_str(&out_rx.try_recv().expect("handoff completion")).expect("json");
    assert!(
        out_rx.try_recv().is_err(),
        "only the handoff item is handled"
    );
    assert_eq!(request["method"], "thread/realtime/handoff/complete");
    assert_eq!(request["params"]["threadId"], "realtime-1");
    assert_eq!(request["params"]["handoffId"], "handoff-1");
    assert_eq!(request["params"]["phase"], "final_answer");
    assert!(
        request["params"]["text"]
            .as_str()
            .is_some_and(|text| text.contains("Gateway is restarting")),
        "{request}"
    );
}

/// Gateway-level regression case: multiple
/// delegations steered into one Claude turn, a mid-turn status message,
/// then the real answer at turn end. Exactly one handoff/complete may go
/// upstream, carrying the answer on the newest delegation, and nothing may
/// fabricate a failure.
#[tokio::test]
async fn voice_notifications_route_one_completion_to_the_newest_delegation() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let gateway = crate::test_support::TestGateway::with_settings(
        codex,
        claude_test.settings.clone(),
        Arc::new(claude_test),
    );
    let mut session = external_voice_session();
    session
        .delegations
        .begin("handoff-original", "handoff-original", 0.0);
    session
        .delegations
        .bind_input("handoff-original", "turn-17");
    session
        .delegations
        .begin("handoff-newest", "handoff-newest", 1.0);
    session.delegations.bind_input("handoff-newest", "turn-17");
    gateway.voice.seed(None, Some(session));

    let out_rx = crate::test_support::FakeControl::attach(&gateway, 16)
        .await
        .requests;
    let captured = spawn_control_responder(&gateway, out_rx);

    let notify = message;
    gateway
        .forward_voice_agent_notification(&notify(
            "item/agentMessage/delta",
            json!({"threadId": "claude-session-1", "turnId": "turn-17", "delta": "Working on the example."}),
        ))
        .await;
    gateway
        .forward_voice_agent_notification(&notify(
            "item/completed",
            json!({"threadId": "claude-session-1", "turnId": "turn-17",
                   "item": {"type": "agentMessage", "text": "Working on the example."}}),
        ))
        .await;
    gateway
        .forward_voice_agent_notification(&notify(
            "item/completed",
            json!({"threadId": "claude-session-1", "turnId": "turn-17",
                   "item": {"type": "agentMessage", "text": "The example account is signed out."}}),
        ))
        .await;
    gateway
        .forward_voice_agent_notification(&notify(
            "turn/completed",
            json!({"threadId": "claude-session-1",
                   "turn": {"id": "turn-17", "status": "completed"}}),
        ))
        .await;

    let captured = captured.lock().await;
    let appends: Vec<&Value> = captured
        .iter()
        .filter(|request| request["method"] == "thread/realtime/handoff/append")
        .collect();
    let completes: Vec<&Value> = captured
        .iter()
        .filter(|request| request["method"] == "thread/realtime/handoff/complete")
        .collect();
    assert!(!appends.is_empty(), "commentary must stream");
    for append in &appends {
        assert_eq!(append["params"]["handoffId"], "handoff-newest");
        assert_eq!(append["params"]["phase"], "commentary");
    }
    assert_eq!(completes.len(), 1, "exactly one completion per turn");
    assert_eq!(completes[0]["params"]["handoffId"], "handoff-newest");
    assert_eq!(
        completes[0]["params"]["text"],
        "The example account is signed out."
    );
    assert!(
        !captured.iter().any(|request| request["params"]["text"]
            .as_str()
            .is_some_and(|text| text.contains("task ended"))),
        "no fabricated failure text may reach the voice model"
    );
    assert!(
        gateway
            .voice
            .with_realtime_thread("realtime-1", |session| session
                .delegations
                .complete_turn("turn-17", "completed", None, 999.0)
                .is_none())
            .expect("session stays active")
    );
}

#[tokio::test]
async fn voice_rejoin_delivers_running_text_work_without_dispatching_a_task() {
    let gateway = test_gateway();
    let mut session = external_voice_session();
    session.delegations.observe_turn("text-turn", 1.0);
    gateway.voice.seed(None, Some(session));
    let out_rx = crate::test_support::FakeControl::attach(&gateway, 16)
        .await
        .requests;
    let captured = spawn_control_responder(&gateway, out_rx);

    let update = |turn_id: &str, text: &str| {
        message(
            "item/completed",
            json!({
                "threadId": "claude-session-1", "turnId": turn_id,
                "item": {"type": "agentMessage", "text": text}
            }),
        )
    };
    gateway
        .forward_voice_agent_notification(&update("older-turn", "Stale answer"))
        .await;
    gateway
        .forward_voice_agent_notification(&update("text-turn", "Both clips are transcribed."))
        .await;
    gateway
        .forward_voice_agent_notification(&update("text-turn", "The website changes are finished."))
        .await;
    gateway
        .forward_voice_agent_notification(&message(
            "turn/completed",
            json!({
                "threadId": "claude-session-1", "turn": {"id": "text-turn", "status": "completed"}
            }),
        ))
        .await;

    // The next typed turn is audible too, without a voice delegation.
    gateway.forward_voice_agent_notification(&message("turn/started", json!({
        "threadId": "claude-session-1", "turn": {"id": "next-text-turn", "status": "inProgress"}
    }))).await;
    gateway
        .forward_voice_agent_notification(&update("next-text-turn", "Checking the mobile header."))
        .await;
    gateway.voice.drain_for_test();
    gateway
        .forward_voice_agent_notification(&update("next-text-turn", "After voice ended"))
        .await;

    let requests = captured.lock().await;
    assert_eq!(
        requests.len(),
        3,
        "one speech request per current message; no dispatch or duplicate final"
    );
    assert!(
        requests
            .iter()
            .all(|request| request["method"] == "thread/realtime/appendSpeech")
    );
    assert_eq!(requests[0]["params"]["text"], "Both clips are transcribed.");
    assert_eq!(
        requests[1]["params"]["text"],
        "The website changes are finished."
    );
    assert_eq!(requests[2]["params"]["text"], "Checking the mobile header.");
}

#[tokio::test]
async fn voice_mode_greets_once_when_its_own_audio_connects() {
    let gateway = test_gateway();
    gateway.voice.seed(None, Some(external_voice_session()));
    let out_rx = crate::test_support::FakeControl::attach(&gateway, 16)
        .await
        .requests;
    let captured = spawn_control_responder(&gateway, out_rx);

    assert!(gateway.greet_voice_session(2, "session-1").await.is_err());
    assert!(
        gateway
            .greet_voice_session(1, "older-session")
            .await
            .is_err()
    );
    gateway
        .greet_voice_session(1, "session-1")
        .await
        .expect("greeting");
    gateway
        .greet_voice_session(1, "session-1")
        .await
        .expect("repeated report");

    let requests = captured.lock().await;
    assert_eq!(requests.len(), 1, "one greeting per voice session");
    assert_eq!(requests[0]["method"], "thread/realtime/appendSpeech");
    assert_eq!(requests[0]["params"]["threadId"], "realtime-1");
    assert_eq!(requests[0]["params"]["text"], VOICE_MODE_GREETING);
}

#[tokio::test]
async fn voice_stop_drains_instead_of_dropping_the_session() {
    let gateway = test_gateway();
    gateway.voice.seed(
        Some(VoiceSessionOwner {
            client_id: 1,
            realtime_session_id: "session-1".to_string(),
        }),
        Some(external_voice_session()),
    );
    let out_rx = crate::test_support::FakeControl::attach(&gateway, 16)
        .await
        .requests;
    let captured = spawn_control_responder(&gateway, out_rx);

    tokio::time::pause();
    gateway
        .stop_voice_session(1)
        .await
        .expect("stop_voice_session");

    assert!(
        gateway.voice.session().is_some(),
        "session drains instead of dropping so the tail flush can dispatch"
    );
    assert!(gateway.voice.is_draining());
    assert!(
        captured
            .lock()
            .await
            .iter()
            .any(|request| request["method"] == "thread/realtime/stop")
    );

    // After the grace window the finalize task removes the session.
    for _ in 0..200 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        if gateway.voice.session().is_none() {
            break;
        }
    }
    assert!(gateway.voice.session().is_none());
}

#[tokio::test]
async fn claude_voice_start_uses_a_shadow_thread_and_client_owned_v3_handoffs() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let claude = ClaudeSettings {
        enabled: true,
        ..claude_test.settings.clone()
    };
    let gateway =
        crate::test_support::TestGateway::with_settings(codex, claude, Arc::new(claude_test));
    let (client_tx, _client_rx) = mpsc::channel(4);
    gateway.clients.insert(1, test_client(1, client_tx));
    let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;

    let start = {
        let gateway = Arc::clone(&gateway);
        tokio::spawn(async move {
            let request: RealtimeVoiceStartRequest = serde_json::from_value(json!({
                "conversationThreadId": "claude_74625c52-f095-4eee-a771-abc123",
                "realtimeSessionId": "session-claude",
                "replaceExistingSession": true,
                "cwd": "/tmp/project",
                "model": "claude-sonnet-5",
                "effort": "high",
                "sdp": "v=0\r\no=remote-coder\r\n",
                "voice": "ash",
                "initialItems": [
                    {"role": "user", "text": "Previous question"},
                    {"role": "assistant", "text": "Previous answer"}
                ]
            }))
            .expect("voice start request");
            gateway
                .start_voice_session(1, request, VoiceSessionOrigin::VoiceMode)
                .await
        })
    };

    let shadow_request: Value =
        serde_json::from_str(&out_rx.recv().await.expect("shadow thread request"))
            .expect("shadow request json");
    assert_eq!(shadow_request["method"], "thread/start");
    assert_eq!(shadow_request["params"]["ephemeral"], true);
    assert_eq!(shadow_request["params"]["cwd"], "/tmp/project");
    assert!(shadow_request["params"].get("dynamicTools").is_none());
    assert_eq!(
        shadow_request["params"]["config"]["features.shell_snapshot"],
        false
    );
    assert_eq!(shadow_request["params"]["config"]["mcp_servers"], json!({}));
    assert_eq!(shadow_request["params"]["config"]["hooks"], json!({}));
    answer_internal_request(
        &gateway,
        &shadow_request,
        json!({"thread": {"id": "shadow-realtime-thread"}}),
    )
    .await;

    let realtime_request: Value =
        serde_json::from_str(&out_rx.recv().await.expect("realtime start request"))
            .expect("realtime request json");
    assert_eq!(realtime_request["method"], "thread/realtime/start");
    let params = &realtime_request["params"];
    assert_eq!(params["threadId"], "shadow-realtime-thread");
    assert_eq!(params["realtimeSessionId"], "session-claude");
    assert_eq!(params["handoffOwner"], "client");
    assert_eq!(params["version"], "v3");
    assert_eq!(params["outputModality"], "audio");
    assert_eq!(params["includeStartupContext"], false);
    assert!(params.get("delegationAckFiller").is_none());
    assert_eq!(params["transport"]["type"], "webrtc");
    assert_eq!(params["transport"]["sdp"], "v=0\r\no=remote-coder\r\n");
    assert_eq!(params["voice"], "ash");
    assert_eq!(params["prompt"], VOICE_MODE_PROMPT);
    assert_eq!(params["initialItems"].as_array().map(Vec::len), Some(2));
    assert!(params.get("codexResponseHandoffMode").is_none());
    answer_internal_request(&gateway, &realtime_request, json!({})).await;

    let response = start.await.expect("start task").expect("voice start");
    assert_eq!(response.realtime_thread_id, "shadow-realtime-thread");
    let session = gateway.voice.session().expect("active voice session");
    assert!(session.uses_external_executor);
    assert_eq!(
        session.conversation_thread_id,
        "claude_74625c52-f095-4eee-a771-abc123"
    );
    assert_eq!(session.realtime_thread_id, "shadow-realtime-thread");
}

#[tokio::test]
async fn claude_voice_start_consumes_a_prewarmed_shadow_without_starting_a_thread() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let claude = ClaudeSettings {
        enabled: true,
        ..claude_test.settings.clone()
    };
    let gateway =
        crate::test_support::TestGateway::with_settings(codex, claude, Arc::new(claude_test));
    let (client_tx, _client_rx) = mpsc::channel(4);
    gateway.clients.insert(1, test_client(1, client_tx));
    let reservation = gateway
        .voice
        .shadows
        .reserve("/tmp/project")
        .expect("shadow reservation");
    assert!(
        gateway
            .voice
            .shadows
            .offer(reservation, "prewarmed-shadow-thread".to_string())
            .is_empty()
    );
    let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;

    let start = {
        let gateway = Arc::clone(&gateway);
        tokio::spawn(async move {
            let request: RealtimeVoiceStartRequest = serde_json::from_value(json!({
                "conversationThreadId": "claude_74625c52-f095-4eee-a771-abc123",
                "realtimeSessionId": "session-claude",
                "replaceExistingSession": true,
                "cwd": "/tmp/project",
                "model": "claude-sonnet-5",
                "sdp": "v=0\r\n"
            }))
            .expect("voice start request");
            gateway
                .start_voice_session(1, request, VoiceSessionOrigin::VoiceMode)
                .await
        })
    };

    let realtime_request: Value =
        serde_json::from_str(&out_rx.recv().await.expect("realtime start request"))
            .expect("realtime request json");
    assert_eq!(realtime_request["method"], "thread/realtime/start");
    assert_eq!(
        realtime_request["params"]["threadId"],
        "prewarmed-shadow-thread"
    );
    answer_internal_request(&gateway, &realtime_request, json!({})).await;

    let response = start.await.expect("start task").expect("voice start");
    assert_eq!(response.realtime_thread_id, "prewarmed-shadow-thread");
    assert!(gateway.voice.shadows.take("/tmp/project").is_none());
}

#[tokio::test]
async fn disconnected_client_cannot_leave_an_orphaned_voice_start() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let claude = ClaudeSettings {
        enabled: true,
        ..claude_test.settings.clone()
    };
    let gateway =
        crate::test_support::TestGateway::with_settings(codex, claude, Arc::new(claude_test));
    let (client_tx, _client_rx) = mpsc::channel(4);
    gateway.clients.insert(1, test_client(1, client_tx));
    let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;

    let mut start = {
        let gateway = Arc::clone(&gateway);
        tokio::spawn(async move {
            let request: RealtimeVoiceStartRequest = serde_json::from_value(json!({
                "conversationThreadId": "claude_74625c52-f095-4eee-a771-abc123",
                "realtimeSessionId": "session-claude",
                "replaceExistingSession": true,
                "cwd": "/tmp/project",
                "model": "claude-sonnet-5",
                "sdp": "v=0\r\n"
            }))
            .expect("voice start request");
            gateway
                .start_voice_session(1, request, VoiceSessionOrigin::VoiceMode)
                .await
        })
    };

    let shadow_request: Value =
        serde_json::from_str(&out_rx.recv().await.expect("shadow thread request"))
            .expect("shadow request json");
    gateway.clients.remove(&1);
    gateway.voice.clear(1, None);
    answer_internal_request(
        &gateway,
        &shadow_request,
        json!({"thread": {"id": "orphan-shadow-thread"}}),
    )
    .await;

    assert!(
        tokio::time::timeout(Duration::from_millis(50), &mut start)
            .await
            .is_err(),
        "voice start must await shadow cleanup"
    );
    let delete_request: Value =
        serde_json::from_str(&out_rx.recv().await.expect("shadow delete request"))
            .expect("shadow delete request json");
    assert_eq!(delete_request["method"], "thread/delete");
    assert_eq!(delete_request["params"]["threadId"], "orphan-shadow-thread");
    answer_internal_request(&gateway, &delete_request, json!({})).await;

    let error = start
        .await
        .expect("start task")
        .expect_err("disconnected client must abort startup");
    assert!(error.to_string().contains("client disconnected"));
    assert!(gateway.voice.session().is_none());
    assert!(
        tokio::time::timeout(Duration::from_millis(50), out_rx.recv())
            .await
            .is_err(),
        "realtime start must not be sent after the client disconnects"
    );
}

#[tokio::test]
async fn codex_voice_start_matches_the_desktop_provisional_thread_request() {
    let claude_test =
        Arc::new(crate::providers::claude::settings::ClaudeSettings::isolated_for_test());
    for initial_items in [
        json!([]),
        json!([
            {"role": "user", "text": "Previous question"},
            {"role": "assistant", "text": "Previous answer"}
        ]),
    ] {
        let codex = Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        ));
        let gateway = crate::test_support::TestGateway::with_settings(
            codex,
            claude_test.settings.clone(),
            Arc::clone(&claude_test),
        );
        let (client_tx, _client_rx) = mpsc::channel(4);
        gateway.clients.insert(1, test_client(1, client_tx));
        let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 2)
            .await
            .requests;

        let start = {
            let gateway = Arc::clone(&gateway);
            let initial_items = initial_items.clone();
            tokio::spawn(async move {
                let request: RealtimeVoiceStartRequest = serde_json::from_value(json!({
                    "conversationThreadId": "codex-provisional-thread",
                    "realtimeSessionId": "session-codex",
                    "replaceExistingSession": true,
                    "cwd": "/tmp/project",
                    "model": "gpt-5.6-sol",
                    "effort": "medium",
                    "sdp": "v=0\r\no=remote-coder\r\n",
                    "voice": "cove",
                    "initialItems": initial_items
                }))
                .expect("voice start request");
                gateway
                    .start_voice_session(1, request, VoiceSessionOrigin::VoiceMode)
                    .await
            })
        };

        let realtime_request: Value =
            serde_json::from_str(&out_rx.recv().await.expect("realtime start request"))
                .expect("realtime request json");
        assert_eq!(realtime_request["method"], "thread/realtime/start");
        let params = &realtime_request["params"];
        assert_eq!(params["threadId"], "codex-provisional-thread");
        assert_eq!(params["realtimeSessionId"], "session-codex");
        assert!(params.get("handoffOwner").is_none());
        assert!(params.get("delegationAckFiller").is_none());
        assert_eq!(params["version"], "v3");
        assert_eq!(params["includeStartupContext"], false);
        assert_eq!(params["codexResponseHandoffMode"], "bemTags");
        let item_count = initial_items.as_array().map_or(0, Vec::len);
        assert_eq!(
            params
                .get("initialItems")
                .map(|items| items.as_array().map(Vec::len)),
            (item_count > 0).then_some(Some(item_count))
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(50), out_rx.recv())
                .await
                .is_err(),
            "the settings read must wait for the realtime start acknowledgement"
        );
        answer_internal_request(&gateway, &realtime_request, json!({})).await;

        answer_voice_settings_read(&gateway, &mut out_rx).await;

        let response = start.await.expect("start task").expect("voice start");
        assert_eq!(response.realtime_thread_id, "codex-provisional-thread");
        assert_eq!(response.model, "gpt-5.6-luna");
        assert_eq!(response.effort.as_deref(), Some("high"));
        let session = gateway.voice.session().expect("installed voice session");
        assert_eq!(session.model, "gpt-5.6-luna");
        assert_eq!(session.effort.as_deref(), Some("high"));
    }
}

fn spawn_codex_voice_start(
    gateway: &Arc<Gateway>,
) -> tokio::task::JoinHandle<Result<crate::wire::gateway::RealtimeVoiceStartResponse>> {
    let gateway = Arc::clone(gateway);
    tokio::spawn(async move {
        let request: RealtimeVoiceStartRequest = serde_json::from_value(json!({
            "conversationThreadId": "codex-voice-thread",
            "realtimeSessionId": "session-codex",
            "replaceExistingSession": true,
            "cwd": "/tmp/project",
            "model": "gpt-5.6-sol",
            "effort": "medium",
            "sdp": "v=0\r\n"
        }))
        .expect("voice start request");
        gateway
            .start_voice_session(1, request, VoiceSessionOrigin::VoiceMode)
            .await
    })
}

#[tokio::test]
async fn failed_codex_voice_settings_read_stops_the_started_transport() {
    let claude_test =
        Arc::new(crate::providers::claude::settings::ClaudeSettings::isolated_for_test());
    for read_reply in [
        json!({"result": {"thread": {"id": "codex-voice-thread"}}}),
        json!({"error": {"code": -32603, "message": "thread read failed"}}),
    ] {
        let codex = Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        ));
        let gateway = crate::test_support::TestGateway::with_settings(
            codex,
            claude_test.settings.clone(),
            Arc::clone(&claude_test),
        );
        let (client_tx, _client_rx) = mpsc::channel(4);
        gateway.clients.insert(1, test_client(1, client_tx));
        let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
            .await
            .requests;
        let start = spawn_codex_voice_start(&gateway);

        let realtime_request: Value =
            serde_json::from_str(&out_rx.recv().await.expect("realtime start request"))
                .expect("realtime request json");
        assert_eq!(realtime_request["method"], "thread/realtime/start");
        answer_internal_request(&gateway, &realtime_request, json!({})).await;

        let read_request: Value =
            serde_json::from_str(&out_rx.recv().await.expect("settings read"))
                .expect("read request json");
        assert_eq!(read_request["method"], "thread/read");
        let mut reply = read_reply.clone();
        reply["id"] = read_request["id"].clone();
        gateway
            .handle_control_text(reply.to_string(), CONTROL)
            .await;

        let stop_request: Value =
            serde_json::from_str(&out_rx.recv().await.expect("transport stop"))
                .expect("stop request json");
        assert_eq!(stop_request["method"], "thread/realtime/stop");
        assert_eq!(stop_request["params"]["threadId"], "codex-voice-thread");
        answer_internal_request(&gateway, &stop_request, json!({})).await;

        start
            .await
            .expect("start task")
            .expect_err("an unreadable voice conversation must not start");
        assert!(gateway.voice.session().is_none(), "{read_reply}");
        assert!(gateway.voice.owner().is_none(), "{read_reply}");
    }
}

#[tokio::test]
async fn client_disconnect_during_codex_voice_settings_read_stops_the_transport() {
    let claude_test =
        Arc::new(crate::providers::claude::settings::ClaudeSettings::isolated_for_test());
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let gateway = crate::test_support::TestGateway::with_settings(
        codex,
        claude_test.settings.clone(),
        claude_test,
    );
    let (client_tx, _client_rx) = mpsc::channel(4);
    gateway.clients.insert(1, test_client(1, client_tx));
    let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;
    let start = spawn_codex_voice_start(&gateway);

    let realtime_request: Value =
        serde_json::from_str(&out_rx.recv().await.expect("realtime start request"))
            .expect("realtime request json");
    answer_internal_request(&gateway, &realtime_request, json!({})).await;
    let read_request: Value = serde_json::from_str(&out_rx.recv().await.expect("settings read"))
        .expect("read request json");
    assert_eq!(read_request["method"], "thread/read");
    gateway.clients.remove(&1);
    answer_internal_request(
        &gateway,
        &read_request,
        json!({"thread": {"id": "codex-voice-thread", "model": "gpt-5.6-luna", "reasoningEffort": "high"}}),
    )
    .await;

    let stop_request: Value = serde_json::from_str(&out_rx.recv().await.expect("transport stop"))
        .expect("stop request json");
    assert_eq!(stop_request["method"], "thread/realtime/stop");
    assert_eq!(stop_request["params"]["threadId"], "codex-voice-thread");
    answer_internal_request(&gateway, &stop_request, json!({})).await;

    let error = start
        .await
        .expect("start task")
        .expect_err("a disconnected client must not keep the call");
    assert!(error.to_string().contains("client disconnected"));
    assert!(gateway.voice.session().is_none());
    assert!(gateway.voice.owner().is_none());
}

#[tokio::test]
async fn captured_turn_events_keep_one_active_turn_and_never_revive_a_completed_one() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let gw = crate::test_support::TestGateway::with_settings(
        codex,
        claude_test.settings.clone(),
        Arc::new(claude_test),
    );
    let turn_event = |method: &str, thread: &str, turn: &str, status: &str| {
        message(
            method,
            json!({"threadId": thread, "turnId": turn, "turn": {"id": turn, "status": status}}),
        )
    };
    let agent_message = |thread: &str, turn: &str| {
        message(
            "item/completed",
            json!({"threadId": thread, "turnId": turn, "item": {"type": "agentMessage", "text": "hello"}}),
        )
    };

    let _ = gw
        .capture_agent_message(&turn_event("turn/started", "thr_1", "turn_1", "inProgress"))
        .await;
    {
        let core = gw.core.lock().await;
        assert_eq!(core.turns.active_count(), 1);
        assert!(core.turns.is_active(&TurnKey::new("thr_1", "turn_1")));
    }
    for event in [
        turn_event("turn/completed", "thr_1", "turn_1", "completed"),
        agent_message("thr_1", "turn_1"),
    ] {
        let _ = gw.capture_agent_message(&event).await;
    }
    {
        let core = gw.core.lock().await;
        assert_eq!(core.turns.active_count(), 0);
        assert_eq!(core.turns.context_count(), 0);
    }

    for turn in ["a", "b"] {
        let _ = gw
            .capture_agent_message(&turn_event("turn/started", "thr_2", turn, "inProgress"))
            .await;
    }
    {
        let core = gw.core.lock().await;
        assert!(!core.turns.is_active(&TurnKey::new("thr_2", "a")));
        assert!(core.turns.is_active(&TurnKey::new("thr_2", "b")));
    }

    let _ = gw
        .capture_agent_message(&agent_message("thr_3", "turn_0"))
        .await;
    let core = gw.core.lock().await;
    assert!(!core.turns.is_active(&TurnKey::new("thr_3", "turn_0")));
    assert!(
        core.turns
            .context(&TurnKey::new("thr_3", "turn_0"))
            .is_some_and(|context| context.last_message_preview.is_some())
    );
}

#[tokio::test]
async fn a_finished_turn_is_kept_until_another_turn_starts_on_its_thread() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let gw = crate::test_support::TestGateway::with_settings(
        codex,
        claude_test.settings.clone(),
        Arc::new(claude_test),
    );
    let snapshot = |method: &'static str, turn: Value| {
        let gw = &gw;
        async move {
            gw.capture_agent_message(&message(method, json!({"threadId": "thr_1", "turn": turn})))
                .await
                .and_then(|(_, _, _, live_activity)| live_activity)
                .expect("Live Activity snapshot")
        }
    };
    snapshot(
        "turn/started",
        json!({"id": "turn_1", "status": "inProgress"}),
    )
    .await;

    let finished = snapshot(
        "turn/completed",
        json!({"id": "turn_1", "status": "completed", "startedAt": 100, "completedAt": 160}),
    )
    .await;
    let mut expected = live_activity::FinishedTurns::default();
    expected.record(
        "thr_1",
        live_activity::FinishedTurn {
            turn_id: "turn_1".into(),
            started_at: 100,
            completed_at: 160,
        },
    );
    assert!(finished.running.is_empty());
    assert_eq!(finished.finished, expected);

    assert!(
        gw.capture_agent_message(&message(
            "turn/started",
            json!({
                "threadId":"thr_1", "turn":{"id":"turn_1", "status":"inProgress"}
            })
        ))
        .await
        .is_none()
    );
    assert_eq!(gw.core.lock().await.finished_turns, expected);

    let running = snapshot(
        "turn/started",
        json!({"id": "turn_2", "status": "inProgress"}),
    )
    .await;
    assert_eq!(running.running, BTreeSet::from(["thr_1".to_owned()]));
    assert_eq!(running.finished, live_activity::FinishedTurns::default());
}

#[tokio::test]
async fn review_regression_late_starts_cannot_resurrect_a_completed_turn_or_erase_a_newer_finish() {
    let gateway = test_gateway();
    for turn in ["old", "new"] {
        for method in ["turn/started", "turn/completed"] {
            gateway
                .capture_agent_message(&message(
                    method,
                    json!({
                        "threadId":"root", "turn":{"id":turn,"status":"completed"}
                    }),
                ))
                .await;
        }
    }
    let before =
        super::turn_state::active_tasks_live_activity_snapshot(&*gateway.core.lock().await);
    let late = gateway
        .capture_agent_message(&message(
            "turn/started",
            json!({
                "threadId":"root", "turn":{"id":"old"}
            }),
        ))
        .await;
    assert!(late.is_none());
    assert_eq!(
        super::turn_state::active_tasks_live_activity_snapshot(&*gateway.core.lock().await),
        before
    );
}

fn turn_params(value: Value) -> serde_json::Map<String, Value> {
    value.as_object().cloned().expect("params object")
}

#[test]
fn untracked_turn_contexts_are_bounded_oldest_first_and_spare_active_turns() {
    let mut core = GatewayCoreState::default();
    note_turn_started(
        &mut core,
        &turn_params(json!({"threadId": "thr_live", "turn": {"id": "turn_first"}})),
        0.0,
    )
    .expect("first turn started");
    for index in 0..MAX_UNTRACKED_TURN_CONTEXTS + 2 {
        note_item_completed(
            &mut core,
            &turn_params(json!({
                "threadId": format!("thr_{index}"),
                "turnId": "turn_1",
                "item": {"type": "agentMessage", "text": "hello"}
            })),
            1.0 + index as f64,
        );
    }
    assert_eq!(core.turns.context_count(), MAX_UNTRACKED_TURN_CONTEXTS + 1);
    assert!(
        core.turns
            .context(&TurnKey::new("thr_live", "turn_first"))
            .is_some()
    );
    assert!(
        !core
            .turns
            .context(&TurnKey::new("thr_0", "turn_1"))
            .is_some()
    );
    assert!(
        !core
            .turns
            .context(&TurnKey::new("thr_1", "turn_1"))
            .is_some()
    );
    assert!(
        core.turns
            .context(&TurnKey::new("thr_2", "turn_1"))
            .is_some()
    );

    note_turn_started(
        &mut core,
        &turn_params(json!({"threadId": "thr_live", "turn": {"id": "turn_second"}})),
        1_000.0,
    )
    .expect("second turn started");
    assert_eq!(core.turns.context_count(), MAX_UNTRACKED_TURN_CONTEXTS + 1);
    assert!(
        !core
            .turns
            .context(&TurnKey::new("thr_live", "turn_first"))
            .is_some()
    );
    assert!(
        core.turns
            .context(&TurnKey::new("thr_live", "turn_second"))
            .is_some()
    );
    assert!(
        core.turns
            .context(&TurnKey::new("thr_2", "turn_1"))
            .is_some()
    );
}

#[tokio::test]
async fn a_restored_turn_state_keeps_only_the_newest_untracked_contexts() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let directory = tempfile::tempdir().expect("state directory");
    let state_path = directory.path().join("turn-state.json");
    let context = |created: f64| {
        json!({
            "prompt_preview": "task",
            "cwd": null,
            "last_message_preview": null,
            "created_at_unix_seconds": created
        })
    };
    let mut contexts = serde_json::Map::new();
    contexts.insert("thr_live|1".to_string(), context(0.0));
    for index in 0..=MAX_UNTRACKED_TURN_CONTEXTS {
        contexts.insert(format!("thr_{index}|1"), context(1.0 + index as f64));
    }
    let leaked = json!({
        "pending_turn_starts": {},
        "active_turns_by_key": {"thr_live|1": {
            "thread_id": "thr_live",
            "turn_id": "1",
            "owner_client_id": 0,
            "started_at_unix_seconds": 0.0,
            "last_seen_at_unix_seconds": 0.0
        }},
        "turn_ctx_by_key": contexts
    });
    std::fs::write(
        &state_path,
        serde_json::to_vec(&leaked).expect("state JSON"),
    )
    .expect("write state");

    let gateway = Gateway::with_turn_state(
        Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        )),
        claude_test.settings.clone(),
        Journal::disabled(),
        Some(state_path),
    );
    gateway.load_turn_state().await.expect("restore state");
    let core = gateway.core.lock().await;
    assert_eq!(core.turns.context_count(), MAX_UNTRACKED_TURN_CONTEXTS + 1);
    assert!(core.turns.context(&TurnKey::new("thr_live", "1")).is_some());
    assert!(!core.turns.context(&TurnKey::new("thr_0", "1")).is_some());
    assert!(core.turns.context(&TurnKey::new("thr_1", "1")).is_some());
}

#[tokio::test]
async fn test_replay_notifications_preserves_order_and_thread_filter() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let gw = crate::test_support::TestGateway::with_settings(
        codex,
        claude_test.settings.clone(),
        Arc::new(claude_test),
    );

    gw.push_notification_history(&frame(
        "turn/started",
        json!({"threadId":"thr_5","turnId":"turn_1","turn":{"id":"turn_1","status":"inProgress"}}),
    ), Some("thr_5".to_string()), CONTROL)
    .await;
    gw.push_notification_history(
        &frame(
            "item/started",
            json!({"threadId":"thr_5","turnId":"turn_1","item":{"type":"reasoning","id":"rs_1"}}),
        ),
        Some("thr_5".to_string()),
        CONTROL,
    )
    .await;
    gw.push_notification_history(
        &frame(
            "item/started",
            json!({"threadId":"thr_other","turnId":"turn_1","item":{"type":"commandExecution","id":"cmd_1"}}),
        ),
        Some("thr_other".to_string()),
        CONTROL,
    )
    .await;
    gw.push_notification_history(
        &frame(
            "item/completed",
            json!({"threadId":"thr_5","turnId":"turn_1","item":{"type":"commandExecution","id":"cmd_1"}}),
        ),
        Some("thr_5".to_string()),
        CONTROL,
    )
    .await;

    let (tx, mut rx) = mpsc::channel(1);
    let tx = test_client(1, tx);
    gw.handle_daemon_replay_notifications(
        &tx,
        Some(json!(99)),
        Some(json!({"threadId":"thr_5","afterSequence":1,"limit":10,"epoch":gw.core.lock().await.notification_history.epoch().to_owned()})),
    )
    .await
    .expect("replay");

    let Some(ClientCommand::Text(payload)) = rx.recv().await else {
        panic!("missing replay payload");
    };
    let response: Value = serde_json::from_str(&payload).expect("json");
    let notifications = response["result"]["notifications"]
        .as_array()
        .expect("notifications");

    assert_eq!(notifications.len(), 2);
    assert_eq!(notifications[0]["sequence"], 2);
    assert_eq!(notifications[0]["message"]["method"], "item/started");
    assert_eq!(notifications[1]["sequence"], 4);
    assert_eq!(notifications[1]["message"]["method"], "item/completed");
    assert_eq!(response["result"]["throughSequence"], 4);
    assert_eq!(response["result"]["hasMore"], false);
}

async fn replay_result(gateway: &Gateway, params: Value) -> Value {
    let (tx, mut rx) = mpsc::channel(1);
    gateway
        .handle_daemon_replay_notifications(&test_client(1, tx), Some(json!(1)), Some(params))
        .await
        .expect("replay");
    let Some(ClientCommand::Text(payload)) = rx.recv().await else {
        panic!("missing replay payload");
    };
    serde_json::from_str::<Value>(&payload).expect("replay json")["result"].clone()
}

#[tokio::test]
async fn replay_limit_one_pages_without_advancing_past_the_delivered_entry() {
    let gateway = test_gateway();
    for index in 0..2 {
        gateway
            .push_notification_history(
                &json!({"method":"item/completed","params":{"index":index}}).to_string(),
                Some("thread".to_string()),
                CONTROL,
            )
            .await;
    }
    let epoch = gateway
        .core
        .lock()
        .await
        .notification_history
        .epoch()
        .to_owned();
    let first = replay_result(&gateway, json!({"epoch":epoch,"afterSequence":0,"limit":1})).await;
    assert_eq!(first["throughSequence"], 1);
    assert_eq!(first["hasMore"], true);
    assert_eq!(first["latestSequence"], 2);
    let second = replay_result(&gateway, json!({"epoch":epoch,"afterSequence":1,"limit":1})).await;
    assert_eq!(second["notifications"][0]["sequence"], 2);
    assert_eq!(second["throughSequence"], 2);
    assert_eq!(second["hasMore"], false);
}

#[tokio::test]
async fn replay_byte_budget_pages_more_than_eight_megabytes() {
    let gateway = test_gateway();
    for index in 0..2 {
        gateway
            .push_notification_history(
                &json!({"method":"item/completed","params":{"index":index,"text":"x".repeat(5 * 1024 * 1024)}}).to_string(),
                Some("thread".to_string()),
                CONTROL,
            )
            .await;
    }
    let epoch = gateway
        .core
        .lock()
        .await
        .notification_history
        .epoch()
        .to_owned();
    let first = replay_result(&gateway, json!({"epoch":epoch,"afterSequence":0})).await;
    assert_eq!(
        first["notifications"]
            .as_array()
            .expect("notifications")
            .len(),
        1
    );
    assert_eq!(first["throughSequence"], 1);
    assert_eq!(first["hasMore"], true);
    let second = replay_result(&gateway, json!({"epoch":epoch,"afterSequence":1})).await;
    assert_eq!(second["notifications"][0]["sequence"], 2);
    assert_eq!(second["hasMore"], false);
}

#[tokio::test]
async fn replay_skips_oversized_and_unparseable_entries_without_blocking() {
    let gateway = test_gateway();
    gateway
        .push_notification_history(
            &json!({"method":"oversized","params":{"text":"x".repeat(9 * 1024 * 1024)}})
                .to_string(),
            Some("thread".to_string()),
            CONTROL,
        )
        .await;
    gateway
        .push_notification_history("{broken", Some("thread".to_string()), CONTROL)
        .await;
    gateway
        .push_notification_history(r#"{"method":"after"}"#, Some("thread".to_string()), CONTROL)
        .await;
    let epoch = gateway
        .core
        .lock()
        .await
        .notification_history
        .epoch()
        .to_owned();
    let result = replay_result(&gateway, json!({"epoch":epoch,"afterSequence":0})).await;
    assert_eq!(
        result["skipped"],
        json!([{"sequence":1,"threadId":"thread"},{"sequence":2,"threadId":"thread"}])
    );
    assert_eq!(result["notifications"][0]["sequence"], 3);
    assert_eq!(result["throughSequence"], 3);
    assert_eq!(result["hasMore"], false);
}

#[tokio::test]
async fn replay_filter_consumes_other_threads_before_the_next_page() {
    let gateway = test_gateway();
    gateway
        .push_notification_history(r#"{"method":"a"}"#, Some("wanted".to_string()), CONTROL)
        .await;
    gateway
        .push_notification_history(r#"{"method":"b"}"#, Some("other".to_string()), CONTROL)
        .await;
    gateway
        .push_notification_history(r#"{"method":"c"}"#, Some("wanted".to_string()), CONTROL)
        .await;
    let epoch = gateway
        .core
        .lock()
        .await
        .notification_history
        .epoch()
        .to_owned();
    let first = replay_result(
        &gateway,
        json!({"epoch":epoch,"threadId":"wanted","limit":1}),
    )
    .await;
    assert_eq!(first["throughSequence"], 2);
    assert_eq!(first["hasMore"], true);
    let second = replay_result(
        &gateway,
        json!({"epoch":epoch,"threadId":"wanted","afterSequence":2,"limit":1}),
    )
    .await;
    assert_eq!(second["notifications"][0]["sequence"], 3);
    assert_eq!(second["hasMore"], false);
}

#[tokio::test]
async fn replay_prunes_expired_entries_and_reports_only_a_real_gap() {
    let gateway = test_gateway();
    for index in 0..3 {
        gateway
            .push_notification_history(&json!({"method":index}).to_string(), None, CONTROL)
            .await;
    }
    let epoch = {
        let mut core = gateway.core.lock().await;
        core.notification_history.age_for_test(
            0,
            crate::notifications::history::NOTIFICATION_HISTORY_TTL_SECONDS + 1.0,
        );
        core.notification_history.epoch().to_owned()
    };
    let missing = replay_result(&gateway, json!({"epoch":epoch,"afterSequence":0})).await;
    assert_eq!(missing["oldestSequence"], 2);
    assert_eq!(missing["evictedBefore"], true);
    let contiguous = replay_result(&gateway, json!({"epoch":epoch,"afterSequence":1})).await;
    assert_eq!(contiguous["evictedBefore"], false);
    assert_eq!(contiguous["gapBefore"], false);
    assert_eq!(contiguous["notifications"][0]["sequence"], 2);
}

#[tokio::test]
async fn replay_reports_eviction_only_when_the_requested_window_lost_entries() {
    let gateway = test_gateway();
    for index in 0..2 {
        gateway
            .push_notification_history(
                &json!({"method":index}).to_string(),
                Some("thread".to_string()),
                CONTROL,
            )
            .await;
    }
    let (epoch, second_timestamp) = {
        let mut core = gateway.core.lock().await;
        core.notification_history.age_for_test(
            0,
            crate::notifications::history::NOTIFICATION_HISTORY_TTL_SECONDS + 1.0,
        );
        let second = core.notification_history.timestamp_for_test(1);
        (core.notification_history.epoch().to_owned(), second)
    };
    let later_window = replay_result(
        &gateway,
        json!({"epoch":epoch,"threadId":"thread","sinceUnixSeconds":second_timestamp}),
    )
    .await;
    assert_eq!(later_window["evictedBefore"], false);
    assert_eq!(later_window["notifications"][0]["sequence"], 2);
    let earlier_window = replay_result(
        &gateway,
        json!({"epoch":epoch,"threadId":"thread","sinceUnixSeconds":second_timestamp - 1.0}),
    )
    .await;
    assert_eq!(earlier_window["evictedBefore"], true);

    {
        let mut core = gateway.core.lock().await;
        let last = core.notification_history.len() - 1;
        core.notification_history.age_for_test(
            last,
            crate::notifications::history::NOTIFICATION_HISTORY_TTL_SECONDS + 1.0,
        );
    }
    let emptied = replay_result(&gateway, json!({"epoch":epoch,"afterSequence":1})).await;
    assert_eq!(emptied["notifications"], json!([]));
    assert_eq!(emptied["evictedBefore"], true);
    let current = replay_result(&gateway, json!({"epoch":epoch,"afterSequence":2})).await;
    assert_eq!(current["evictedBefore"], false);
}

#[tokio::test]
async fn replay_without_an_epoch_keeps_the_legacy_cursor() {
    let gateway = test_gateway();
    for index in 0..3 {
        gateway
            .push_notification_history(&json!({"method":index}).to_string(), None, CONTROL)
            .await;
    }
    let result = replay_result(&gateway, json!({"afterSequence":2})).await;
    assert_eq!(
        result["notifications"]
            .as_array()
            .expect("notifications")
            .len(),
        1
    );
    assert_eq!(result["notifications"][0]["sequence"], 3);
    assert_eq!(result["evictedBefore"], false);
    assert_eq!(result["gapBefore"], false);
}

#[tokio::test]
async fn replay_old_epoch_restarts_from_the_new_gateways_first_entry() {
    let old = test_gateway();
    let old_epoch = old
        .core
        .lock()
        .await
        .notification_history
        .epoch()
        .to_owned();
    let replacement = test_gateway();
    replacement
        .push_notification_history(r#"{"method":"new"}"#, None, CONTROL)
        .await;
    let result = replay_result(&replacement, json!({"epoch":old_epoch,"afterSequence":99})).await;
    assert_ne!(result["epoch"], old_epoch);
    assert_eq!(result["notifications"][0]["sequence"], 1);
    assert_eq!(result["throughSequence"], 1);
    assert_eq!(result["evictedBefore"], true);
}

#[tokio::test]
async fn every_connection_receives_the_notification_baseline() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let codex_home = tempfile::tempdir().expect("Codex home");
    let socket_dir = codex_home.path().join("app-server-control");
    tokio::fs::create_dir_all(&socket_dir)
        .await
        .expect("socket directory");
    let listener =
        UnixListener::bind(socket_dir.join("app-server-control.sock")).expect("Codex listener");
    let fake_codex = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept upstream");
        let mut ws = accept_async(stream).await.expect("upstream handshake");
        while let Some(Ok(_)) = ws.next().await {}
    });
    let gateway = crate::test_support::TestGateway::with_settings(
        Arc::new(CodexAppServer::new_for_test_socket(
            codex_home.path().into(),
        )),
        claude_test.settings.clone(),
        Arc::new(claude_test),
    );
    *gateway.control_init_result.lock().await = Some(json!({}));
    gateway
        .push_notification_history(r#"{"method":"before"}"#, None, CONTROL)
        .await;
    let epoch = gateway
        .core
        .lock()
        .await
        .notification_history
        .epoch()
        .to_owned();
    let app_gateway = Arc::clone(&gateway);
    let app = Router::new().route(
        "/ws",
        get(move |ws: WebSocketUpgrade| {
            let gateway = Arc::clone(&app_gateway);
            async move {
                ws.on_upgrade(move |socket| {
                    gateway.handle_ws(
                        socket,
                        tokio_util::sync::CancellationToken::new(),
                        crate::auth::installation_credentials::Grant::Operator,
                    )
                })
            }
        }),
    );
    let (address, server) = crate::test_support::serve(app).await;
    let (mut client, _) = connect_async(format!("ws://{address}/ws")).await.unwrap();
    let ready: Value = loop {
        if let UpstreamMessage::Text(raw) = client.next().await.unwrap().unwrap() {
            break serde_json::from_str(&raw).unwrap();
        }
    };
    assert_eq!(ready["method"], "daemon/ready");
    assert_eq!(ready["params"]["notificationEpoch"], epoch);
    assert_eq!(ready["params"]["notificationSequence"], 1);
    client.close(None).await.unwrap();
    server.abort();
    fake_codex.abort();
}

#[tokio::test]
async fn replay_results_carry_the_shared_protocol_fixture_fields() {
    let gateway = test_gateway();
    gateway
        .push_notification_history(
            r#"{"method":"turn/started","params":{"threadId":"thread-1"}}"#,
            Some("thread-1".to_string()),
            CONTROL,
        )
        .await;
    let epoch = gateway
        .core
        .lock()
        .await
        .notification_history
        .epoch()
        .to_owned();
    let result = replay_result(&gateway, json!({"epoch":epoch,"afterSequence":0})).await;
    let keys = |value: &Value| {
        value
            .as_object()
            .expect("object")
            .keys()
            .cloned()
            .collect::<std::collections::BTreeSet<_>>()
    };
    for fixture in [
        include_str!("../../../protocol-fixtures/replay/page-has-more.json"),
        include_str!("../../../protocol-fixtures/replay/skipped.json"),
        include_str!("../../../protocol-fixtures/replay/epoch-reset.json"),
    ] {
        let fixture: Value = serde_json::from_str(fixture).expect("fixture");
        assert_eq!(keys(&result), keys(&fixture["result"]));
        assert_eq!(
            keys(&result["notifications"][0]),
            keys(&fixture["result"]["notifications"][0])
        );
    }
}

fn tool_call_frame(namespace: &str, tool: &str, arguments: Value) -> String {
    serde_json::to_string(&json!({
        "jsonrpc": "2.0",
        "id": "codex-call-1",
        "method": "item/tool/call",
        "params": {
            "threadId": "thread-1",
            "turnId": "turn-1",
            "callId": "call-1",
            "namespace": namespace,
            "tool": tool,
            "arguments": arguments,
        }
    }))
    .expect("json")
}

#[tokio::test]
async fn a_codex_tool_call_is_answered_on_control_and_never_broadcast() {
    let gateway = test_gateway();
    let (client_tx, mut client_rx) = mpsc::channel(4);
    gateway.clients.insert(1, test_client(1, client_tx));
    let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;
    let mut session = external_voice_session();
    session.conversation_thread_id = "thread-1".to_string();
    session.uses_external_executor = false;
    gateway.voice.seed(None, Some(session));

    gateway
        .handle_control_text(
            tool_call_frame(
                crate::agents::tools::NAMESPACE,
                crate::agents::tools::END_VOICE_CALL,
                json!({}),
            ),
            CONTROL,
        )
        .await;

    // The tool runs the real drain, so the realtime stop goes out first.
    let stop: Value =
        serde_json::from_str(&out_rx.recv().await.expect("stop request")).expect("stop json");
    assert_eq!(stop["method"], "thread/realtime/stop");
    answer_internal_request(&gateway, &stop, json!({})).await;

    let answer: Value =
        serde_json::from_str(&out_rx.recv().await.expect("tool answer")).expect("answer json");
    assert_eq!(answer["id"], "codex-call-1");
    assert_eq!(answer["result"]["success"], true);
    assert_eq!(answer["result"]["contentItems"][0]["type"], "inputText");
    assert_eq!(
        answer["result"]["contentItems"][0]["text"],
        "Voice call ended."
    );
    // Ending the call notifies clients it was on purpose; that is the
    // only thing they hear — the tool call itself is never broadcast.
    let ClientCommand::Text(notification) =
        client_rx.recv().await.expect("agent-ended notification")
    else {
        panic!("expected a text notification");
    };
    let notification: Value = serde_json::from_str(&notification).expect("notification json");
    assert_eq!(notification["method"], "voice/session/agentEnded");
    assert!(
        client_rx.try_recv().is_err(),
        "a call no client declared must not reach any client"
    );
}

#[tokio::test]
async fn a_foreign_control_tool_call_never_reaches_clients() {
    let gateway = test_gateway();
    let (client_tx, mut client_rx) = mpsc::channel(4);
    gateway.clients.insert(1, test_client(1, client_tx));
    let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;

    gateway
        .handle_control_text(
            tool_call_frame("someone_else", "their_tool", json!({})),
            CONTROL,
        )
        .await;

    assert!(client_rx.try_recv().is_err());
    assert!(
        out_rx.try_recv().is_err(),
        "the control connection must not answer another client's request"
    );
}

#[tokio::test]
async fn claude_read_and_resume_report_the_conversation_model_instead_of_the_host_default() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let home = tempfile::tempdir().unwrap();
    let project = home.path().join("projects/repo");
    std::fs::create_dir_all(&project).unwrap();
    let session_id = "12345678-1234-1234-1234-123456789abc";
    let record = json!({"type":"assistant", "timestamp":"2026-09-13T10:00:00Z", "cwd":"/repo",
        "effort":"xhigh", "message":{"model":"claude-opus-5", "content":[]}});
    std::fs::write(
        project.join(format!("{session_id}.jsonl")),
        format!("{record}\n"),
    )
    .unwrap();
    let settings = ClaudeSettings {
        enabled: true,
        default_model: "fable".to_string(),
        claude_home: home.path().to_path_buf(),
        ..claude_test.settings.clone()
    };
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let gateway =
        crate::test_support::TestGateway::with_settings(codex, settings, Arc::new(claude_test));
    let (tx, mut rx) = mpsc::channel(2);
    let out = test_client(1, tx);
    let request =
        json!({"id":1, "params":{"threadId":format!("claude_{session_id}"), "includeTurns":false}});
    for method in [ClaudeMethod::ThreadRead, ClaudeMethod::ThreadResume] {
        gateway
            .handle_claude_rpc(&out, method, request.as_object().unwrap())
            .await
            .unwrap();
        let ClientCommand::Text(text) = rx.recv().await.unwrap() else {
            panic!("expected JSON response")
        };
        let response: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(response["result"]["thread"]["model"], "claude-opus-5");
        assert_eq!(response["result"]["model"], "claude-opus-5");
        assert_eq!(response["result"]["reasoningEffort"], "xhigh");
        assert_eq!(response["result"]["thread"]["reasoningEffort"], "xhigh");
    }
}

#[tokio::test]
async fn claude_thread_read_returns_every_turn_when_include_turns_is_set() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let home = tempfile::tempdir().unwrap();
    let project = home.path().join("projects/repo");
    std::fs::create_dir_all(&project).unwrap();
    let session_id = "12345678-1234-1234-1234-123456789abc";
    let transcript: String = [
        json!({"type":"user","uuid":"P1","cwd":"/repo","timestamp":"2026-09-13T10:00:00Z",
            "message":{"role":"user","content":"First"}}),
        json!({"type":"assistant","uuid":"A1","timestamp":"2026-09-13T10:00:05Z",
            "message":{"id":"m1","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"One"}]}}),
        json!({"type":"user","uuid":"P2","timestamp":"2026-09-13T10:01:00Z",
            "message":{"role":"user","content":"Second"}}),
        json!({"type":"assistant","uuid":"A2","timestamp":"2026-09-13T10:01:05Z",
            "message":{"id":"m2","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Two"}]}}),
    ]
    .iter()
    .map(|record| format!("{record}\n"))
    .collect();
    std::fs::write(project.join(format!("{session_id}.jsonl")), transcript).unwrap();
    let settings = ClaudeSettings {
        enabled: true,
        claude_home: home.path().to_path_buf(),
        ..claude_test.settings.clone()
    };
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let gateway =
        crate::test_support::TestGateway::with_settings(codex, settings, Arc::new(claude_test));
    let (tx, mut rx) = mpsc::channel(2);
    let out = test_client(1, tx);
    let mut read = async |include_turns: bool| {
        let request = json!({"id":1, "params":{"threadId":format!("claude_{session_id}"),
            "includeTurns":include_turns}});
        gateway
            .handle_claude_rpc(&out, ClaudeMethod::ThreadRead, request.as_object().unwrap())
            .await
            .unwrap();
        let ClientCommand::Text(text) = rx.recv().await.unwrap() else {
            panic!("expected JSON response")
        };
        serde_json::from_str::<Value>(&text).unwrap()["result"]["thread"]["turns"].clone()
    };

    assert_eq!(read(false).await, json!([]));
    let turns = read(true).await;
    let summary: Vec<_> = turns
        .as_array()
        .unwrap()
        .iter()
        .map(|turn| {
            let texts: Vec<_> = turn["items"]
                .as_array()
                .unwrap()
                .iter()
                .map(|item| match item["type"].as_str() {
                    Some("userMessage") => item["content"][0]["text"].clone(),
                    _ => item["text"].clone(),
                })
                .collect();
            json!([turn["id"], turn["status"], turn["itemsView"], texts])
        })
        .collect();
    assert_eq!(
        summary,
        [
            json!(["claude-turn-1", "completed", "full", ["First", "One"]]),
            json!(["claude-turn-2", "completed", "full", ["Second", "Two"]]),
        ]
    );
}

#[tokio::test]
async fn isolated_history_gateway_serves_the_shared_completion_time_on_list_and_read() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    use std::io::Write;

    let directory = tempfile::tempdir().unwrap();
    let socket_dir = directory.path().join("app-server-control");
    std::fs::create_dir_all(&socket_dir).unwrap();
    let upstream = UnixListener::bind(socket_dir.join("app-server-control.sock")).unwrap();
    let provider = tokio::spawn(async move {
        let (stream, _) = upstream.accept().await.unwrap();
        let mut socket = accept_async(stream).await.unwrap();
        while let Some(Ok(UpstreamMessage::Text(raw))) = socket.next().await {
            let request: Value = serde_json::from_str(&raw).unwrap();
            if request.get("id").is_none() {
                continue;
            }
            assert_eq!(request["method"], "initialize");
            socket
                .send(UpstreamMessage::Text(
                    json!({"id":request["id"],"result":{}}).to_string(),
                ))
                .await
                .unwrap();
        }
    });
    let project = directory.path().join("projects/fixture");
    std::fs::create_dir_all(&project).unwrap();
    let session = "00000000-0000-4000-8000-000000000001";
    let mut transcript = std::fs::File::create(project.join(format!("{session}.jsonl"))).unwrap();
    for record in [
        json!({"type":"user","cwd":"/fixture","timestamp":"2026-09-20T10:00:00Z","message":{"content":"First"}}),
        json!({"type":"assistant","timestamp":"2026-09-20T10:01:00Z","message":{"stop_reason":"end_turn","content":"Done"}}),
        json!({"type":"user","timestamp":"2026-09-20T10:02:00Z","message":{"content":"Second"}}),
    ] {
        writeln!(transcript, "{record}").unwrap();
    }
    let codex = Arc::new(CodexAppServer::new_for_test_socket(directory.path().into()));
    let gateway = crate::test_support::TestGateway::with_settings(
        codex,
        ClaudeSettings {
            enabled: true,
            claude_home: directory.path().into(),
            ..claude_test.settings.clone()
        },
        Arc::new(claude_test),
    );
    *gateway.control_init_result.lock().await = Some(json!({}));
    let app_gateway = Arc::clone(&gateway);
    let app = Router::new().route(
        "/ws",
        get(move |ws: WebSocketUpgrade| {
            let gateway = Arc::clone(&app_gateway);
            async move {
                ws.on_upgrade(move |socket| {
                    gateway.handle_ws(
                        socket,
                        tokio_util::sync::CancellationToken::new(),
                        crate::auth::installation_credentials::Grant::Operator,
                    )
                })
            }
        }),
    );
    let (address, server) = crate::test_support::serve(app).await;
    let (mut client, _) = connect_async(format!("ws://{address}/ws")).await.unwrap();
    send_client_json(&mut client, json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"history-test","version":"1"}}})).await;
    assert!(next_client_json(&mut client).await.get("result").is_some());

    send_client_json(&mut client, json!({"method":"initialized"})).await;

    for (id, appended, expected) in [
        (2, None, "2026-09-20T10:01:00Z"),
        (
            3,
            Some(
                json!({"type":"assistant","timestamp":"2026-09-20T10:05:00Z","message":{"stop_reason":"end_turn","content":"Finished"}}),
            ),
            "2026-09-20T10:05:00Z",
        ),
    ] {
        if let Some(record) = appended {
            writeln!(transcript, "{record}").unwrap();
        }
        send_client_json(
            &mut client,
            json!({"id":id,"method":"claude/thread/list","params":{"limit":30}}),
        )
        .await;
        let reply = next_client_json(&mut client).await;
        assert_eq!(reply["id"], id);
        assert_eq!(
            reply["result"]["data"][0]["lastTurnCompletedAt"],
            crate::time::parse_rfc3339_seconds(expected).unwrap()
        );
    }
    // The read path shares the same provider projection, not an independent clock.
    send_client_json(&mut client, json!({"id":4,"method":"thread/read","params":{"threadId":format!("claude_{session}"),"includeTurns":false}})).await;
    let reply = next_client_json(&mut client).await;
    assert_eq!(
        reply["result"]["thread"]["lastTurnCompletedAt"],
        crate::time::parse_rfc3339_seconds("2026-09-20T10:05:00Z").unwrap()
    );
    client.close(None).await.unwrap();
    tokio::time::timeout(Duration::from_secs(5), provider)
        .await
        .unwrap()
        .unwrap();
    gateway.stop().await.unwrap();
    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn disabled_claude_history_is_empty_but_read_failures_are_errors() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let gateway = test_gateway();
    let (tx, mut out_rx) = mpsc::channel(2);
    let out_tx = test_client(1, tx);
    let request = json!({"id": 1, "params": {"limit": 30}});
    gateway
        .handle_claude_rpc(
            &out_tx,
            ClaudeMethod::ThreadList,
            request.as_object().unwrap(),
        )
        .await
        .unwrap();
    let ClientCommand::Text(text) = out_rx.recv().await.unwrap() else {
        panic!("expected JSON response")
    };
    let response: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(response["result"]["data"], json!([]));
    assert!(response.get("error").is_none());

    let home = tempfile::tempdir().unwrap();
    std::fs::write(home.path().join("projects"), "not a directory").unwrap();
    let settings = ClaudeSettings {
        enabled: true,
        claude_home: home.path().to_path_buf(),
        ..claude_test.settings.clone()
    };
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let gateway =
        crate::test_support::TestGateway::with_settings(codex, settings, Arc::new(claude_test));
    gateway
        .handle_claude_rpc(
            &out_tx,
            ClaudeMethod::ThreadList,
            request.as_object().unwrap(),
        )
        .await
        .unwrap();
    let ClientCommand::Text(text) = out_rx.recv().await.unwrap() else {
        panic!("expected JSON response")
    };
    let response: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(response["error"]["code"], RpcCode::Internal.value());
}

#[tokio::test]
async fn claude_list_cursor_pages_beyond_five_hundred_and_finds_older_titles() {
    use std::io::Write;
    let owner = Arc::new(crate::providers::claude::settings::ClaudeSettings::isolated_for_test());
    let home = &owner.settings.claude_home;
    let project = home.join("projects/list-pages");
    std::fs::create_dir_all(&project).unwrap();
    for index in 0..601 {
        let id = format!("{index:08x}-0000-4000-8000-000000000001");
        let mut file = std::fs::File::create(project.join(format!("{id}.jsonl"))).unwrap();
        writeln!(
            file,
            "{}",
            json!({"type":"user","cwd":"/repo","timestamp":"2026-09-20T10:00:00Z",
            "message":{"content":"Initial prompt"}})
        )
        .unwrap();
        if index == 600 {
            writeln!(
                file,
                "{}",
                json!({"type":"custom-title","customTitle":"Ångström guide"})
            )
            .unwrap();
        }
    }
    let gateway = crate::test_support::TestGateway::with_settings(
        Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        )),
        ClaudeSettings {
            enabled: true,
            ..owner.settings.clone()
        },
        Arc::clone(&owner),
    );
    let (tx, mut rx) = mpsc::channel(2);
    let client = test_client(1, tx);
    let mut cursor: Option<String> = None;
    let mut first_cursor = None;
    let mut seen = Vec::new();
    for (request_id, expected_count) in [(1, 500), (2, 101)] {
        gateway
            .handle_claude_rpc(
                &client,
                ClaudeMethod::ThreadList,
                &request("claude/thread/list", json!({"limit":500,"cursor":cursor})),
            )
            .await
            .unwrap();
        let ClientCommand::Text(raw) = rx.recv().await.unwrap() else {
            panic!("expected list response")
        };
        let response: Value = serde_json::from_str(&raw).unwrap();
        let page = response["result"]["data"].as_array().unwrap();
        assert_eq!(page.len(), expected_count);
        seen.extend(
            page.iter()
                .map(|header| header["id"].as_str().unwrap().to_owned()),
        );
        cursor = response["result"]["nextCursor"].as_str().map(str::to_owned);
        assert_eq!(cursor.is_some(), request_id == 1);
        if request_id == 1 {
            first_cursor = cursor.clone();
            std::fs::write(
                project.join("ffffffff-0000-4000-8000-000000000001.jsonl"),
                format!(
                    "{}\n",
                    json!({"type":"user","cwd":"/repo","timestamp":"2026-09-21T10:00:00Z",
                    "message":{"content":"Newer arrival"}})
                ),
            )
            .unwrap();
        }
    }
    assert_eq!(
        seen,
        (0..601)
            .map(|index| format!("claude_{index:08x}-0000-4000-8000-000000000001"))
            .collect::<Vec<_>>()
    );
    gateway
        .handle_claude_rpc(
            &client,
            ClaudeMethod::ThreadList,
            &request(
                "claude/thread/list",
                json!({"limit":1,"searchTerm":"ÅNGSTRÖM repo"}),
            ),
        )
        .await
        .unwrap();
    let ClientCommand::Text(raw) = rx.recv().await.unwrap() else {
        panic!("expected search response")
    };
    let found: Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(found["result"]["data"][0]["id"], seen[600]);
    assert!(found["result"]["nextCursor"].is_null());

    let anchor = first_cursor.unwrap();
    let anchor_path = project.join("000001f3-0000-4000-8000-000000000001.jsonl");
    std::fs::write(
        &anchor_path,
        format!(
            "{}\n",
            json!({"type":"user","cwd":"/repo","timestamp":"2026-09-22T10:00:00Z",
        "message":{"content":"Changed anchor"}})
        ),
    )
    .unwrap();
    for deleted in [false, true] {
        if deleted {
            std::fs::remove_file(&anchor_path).unwrap();
        }
        gateway
            .handle_claude_rpc(
                &client,
                ClaudeMethod::ThreadList,
                &request("claude/thread/list", json!({"limit":500,"cursor":anchor})),
            )
            .await
            .unwrap();
        let ClientCommand::Text(raw) = rx.recv().await.unwrap() else {
            panic!("expected continuation")
        };
        let continued: Value = serde_json::from_str(&raw).unwrap();
        let ids: Vec<&str> = continued["result"]["data"]
            .as_array()
            .unwrap()
            .iter()
            .map(|header| header["id"].as_str().unwrap())
            .collect();
        assert_eq!(
            ids,
            seen[500..].iter().map(String::as_str).collect::<Vec<_>>()
        );
        assert!(continued["result"]["nextCursor"].is_null());
    }
    gateway
        .handle_claude_rpc(
            &client,
            ClaudeMethod::ThreadList,
            &request(
                "claude/thread/list",
                json!({"cursor":anchor,"searchTerm":"different"}),
            ),
        )
        .await
        .unwrap();
    let ClientCommand::Text(raw) = rx.recv().await.unwrap() else {
        panic!("expected query rejection")
    };
    let rejected: Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(rejected["error"]["code"], RpcCode::InvalidRequest.value());
    assert_eq!(rejected["error"]["data"]["kind"], "historyCursorInvalid");
}

#[tokio::test]
async fn claude_rpc_validation_errors_keep_their_wire_codes_and_messages() {
    let guard = Arc::new(crate::providers::claude::settings::ClaudeSettings::isolated_for_test());
    let settings = ClaudeSettings {
        enabled: true,
        ..guard.settings.clone()
    };
    let gateway = crate::test_support::TestGateway::with_settings(
        Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        )),
        settings,
        guard,
    );
    let (tx, mut rx) = mpsc::channel(4);
    let client = test_client(1, tx);
    for (method, params, code, message) in [
        (
            "thread/read",
            json!({}),
            RpcCode::InvalidParams.value(),
            "threadId is required",
        ),
        (
            "thread/name/set",
            json!({}),
            RpcCode::InvalidParams.value(),
            "threadId is required",
        ),
        (
            "thread/name/set",
            json!({"threadId":"claude_abc", "name":"  "}),
            RpcCode::InvalidParams.value(),
            "thread name must not be empty",
        ),
        (
            "turn/interrupt",
            json!({}),
            RpcCode::InvalidParams.value(),
            "threadId and turnId are required",
        ),
        (
            "thread/start",
            json!({"provider": "claude"}),
            RpcCode::InvalidParams.value(),
            "cwd is required",
        ),
    ] {
        if matches!(method_spec(method).route, OwnedRoute::Rename) {
            gateway
                .handle_owned_rpc(
                    client.id,
                    &client,
                    method,
                    crate::rpc::dispatch::OwnedTarget::Gateway(OwnedRoute::Rename),
                    &request(method, params),
                )
                .await
                .expect("Gateway rename validation response");
        } else {
            gateway
                .handle_claude_rpc(
                    &client,
                    method_spec(method)
                        .claude
                        .expect("Claude-owned method")
                        .method,
                    &request(method, params),
                )
                .await
                .expect("Claude validation response");
        }
        let ClientCommand::Text(text) = rx.recv().await.expect("Claude response") else {
            panic!("expected Claude JSON response")
        };
        let response: Value = serde_json::from_str(&text).expect("response JSON");
        assert_eq!(
            response["error"],
            json!({"code": code, "message": message}),
            "{method}"
        );
    }
}

#[tokio::test]
async fn recovered_interactive_request_is_rejected_instead_of_hanging() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let directory = tempfile::tempdir().expect("recovery directory");
    let recovery_path = directory.path().join("recovery.json");
    let store = RecoveryStore::new(recovery_path.clone());
    let mut journal = crate::runtime::recovery::RecoveryJournal::new(
        "generation-1".to_string(),
        "0123456789abcdef0123456789abcdef".to_string(),
        vec![crate::runtime::recovery::RecoveryTask {
            thread_id: "thread-1".to_string(),
            turn_id: "turn-1".to_string(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 0,
            status: RecoveryTaskStatus::Running,
            error: None,
        }],
    )
    .expect("recovery journal");
    journal.phase = RecoveryPhase::Recovering;
    store.write(&journal).expect("write recovery journal");
    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let gateway = Gateway::with_state_paths(
        codex,
        claude_test.settings.clone(),
        Journal::disabled(),
        None,
        Some(recovery_path),
        None,
    );
    gateway
        .core
        .lock()
        .await
        .recovered_turn_keys
        .insert(TurnKey::new("thread-1", "turn-1"));
    let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 1)
        .await
        .requests;

    gateway
        .handle_control_text(
            serde_json::to_string(&json!({
                "jsonrpc": "2.0",
                "id": 42,
                "method": "item/commandExecution/requestApproval",
                "params": {"threadId": "thread-1", "turnId": "turn-1"},
            }))
            .expect("request json"),
            CONTROL,
        )
        .await;

    let response: Value = serde_json::from_str(&out_rx.recv().await.expect("control response"))
        .expect("response json");
    assert_eq!(response["id"], 42);
    assert_eq!(response["error"]["code"], RpcCode::Internal.value());

    gateway
        .handle_control_text(
            serde_json::to_string(&json!({
                "jsonrpc": "2.0",
                "id": 43,
                "method": "item/commandExecution/requestApproval",
                "params": {"threadId": "thread-1", "turnId": "other"},
            }))
            .expect("request json"),
            CONTROL,
        )
        .await;
    assert!(out_rx.try_recv().is_err());
}

#[tokio::test]
async fn unauthorized_restart_generation_keeps_exact_tasks_pending() {
    for message in [
        "restart recovery is not authorized",
        "invalid restart recovery capability",
        "thread and turn are not authorized for this restart generation",
    ] {
        let fixture = crate::test_support::TestGateway::new();
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("recovery.json");
        let store = RecoveryStore::new(path.clone());
        let mut journal = RecoveryJournal::new(
            "generation-1".to_owned(),
            "0123456789abcdef0123456789abcdef".to_owned(),
            ["thread-1", "thread-2"]
                .into_iter()
                .map(|id| crate::runtime::recovery::RecoveryTask {
                    thread_id: id.to_owned(),
                    turn_id: format!("turn-{id}"),
                    parent_thread_id: None,
                    depth: 0,
                    recovery_attempts: 0,
                    status: RecoveryTaskStatus::Suspended,
                    error: None,
                })
                .collect(),
        )
        .unwrap();
        journal.phase = RecoveryPhase::DaemonStarted;
        store.write(&journal).unwrap();
        let gateway = Gateway::with_state_paths(
            Arc::clone(&fixture.codex),
            fixture.claude_settings.clone(),
            Journal::disabled(),
            None,
            Some(path),
            None,
        );
        let mut requests = crate::test_support::FakeControl::attach(&gateway, 1)
            .await
            .requests;
        let recovering = {
            let gateway = Arc::clone(&gateway);
            tokio::spawn(async move { gateway.recover_restart_tasks().await })
        };
        let request: Value = serde_json::from_str(&requests.recv().await.unwrap()).unwrap();
        assert_eq!(request["method"], "thread/restart/recover");
        gateway
            .handle_control_text(
                json!({"id":request["id"],"error":{"code":-32600,"message":message}}).to_string(),
                CONTROL,
            )
            .await;
        tokio::time::timeout(Duration::from_secs(1), recovering)
            .await
            .unwrap()
            .unwrap()
            .expect_err("missing generation authority must fail the generation");

        let pending = store.load().unwrap().unwrap();
        assert_eq!(pending.phase, RecoveryPhase::Recovering);
        assert_eq!(pending.tasks, journal.tasks);
        assert!(requests.try_recv().is_err());
    }
}

#[tokio::test]
async fn one_retryable_recovery_does_not_starve_an_unrelated_thread() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let directory = tempfile::tempdir().expect("recovery directory");
    let recovery_path = directory.path().join("recovery.json");
    let store = RecoveryStore::new(recovery_path.clone());
    let mut journal = crate::runtime::recovery::RecoveryJournal::new(
        "generation-1".to_string(),
        "0123456789abcdef0123456789abcdef".to_string(),
        [
            ("thread-retries", 1),
            ("thread-runs", 0),
            ("thread-invalid", 2),
        ]
        .into_iter()
        .map(
            |(thread_id, depth)| crate::runtime::recovery::RecoveryTask {
                thread_id: thread_id.to_string(),
                turn_id: format!("turn-{thread_id}"),
                parent_thread_id: match thread_id {
                    "thread-retries" => Some("thread-runs".to_string()),
                    "thread-invalid" => Some("thread-retries".to_string()),
                    _ => None,
                },
                depth,
                recovery_attempts: 0,
                status: RecoveryTaskStatus::Suspended,
                error: None,
            },
        )
        .collect(),
    )
    .expect("recovery journal");
    journal.phase = RecoveryPhase::DaemonStarted;
    store.write(&journal).expect("write recovery journal");

    let codex = Arc::new(CodexAppServer::new(
        PathBuf::from("/bin/true"),
        HashMap::new(),
    ));
    let gateway = Gateway::with_state_paths(
        codex,
        claude_test.settings.clone(),
        Journal::disabled(),
        None,
        Some(recovery_path),
        None,
    );
    let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 3)
        .await
        .requests;
    let recovery_order = Arc::new(Mutex::new(Vec::new()));
    let unsubscribe_order = Arc::new(Mutex::new(Vec::new()));
    let responder = {
        let gateway = Arc::clone(&gateway);
        let recovery_order = Arc::clone(&recovery_order);
        let unsubscribe_order = Arc::clone(&unsubscribe_order);
        tokio::spawn(async move {
            let mut failed_once = false;
            while let Some(raw) = out_rx.recv().await {
                let request: Value = serde_json::from_str(&raw).expect("control request");
                let thread_id = request["params"]["threadId"].as_str().expect("thread id");
                if request["method"] == "thread/unsubscribe" {
                    unsubscribe_order.lock().await.push(thread_id.to_string());
                    gateway
                        .handle_control_text(
                            serde_json::to_string(&json!({
                                "jsonrpc": "2.0",
                                "id": request["id"],
                                "result": {},
                            }))
                            .expect("response"),
                            CONTROL,
                        )
                        .await;
                    continue;
                }
                recovery_order.lock().await.push(thread_id.to_string());
                let response = if thread_id == "thread-retries" && !failed_once {
                    failed_once = true;
                    json!({
                        "jsonrpc": "2.0",
                        "id": request["id"],
                        "error": {"code": -32001, "message": "temporary overload"},
                    })
                } else if thread_id == "thread-invalid" {
                    json!({
                        "jsonrpc": "2.0",
                        "id": request["id"],
                        "error": {"code": -32600, "message": "invalid recovery grant"},
                    })
                } else {
                    json!({
                        "jsonrpc": "2.0",
                        "id": request["id"],
                        "result": {
                            "generationId": "generation-1",
                            "turn": {
                                "id": format!("turn-{thread_id}"),
                                "status": "inProgress",
                            },
                        },
                    })
                };
                gateway
                    .handle_control_text(
                        serde_json::to_string(&response).expect("response"),
                        CONTROL,
                    )
                    .await;
            }
        })
    };
    let completion = {
        let store = store.clone();
        tokio::spawn(async move {
            loop {
                let journal = store
                    .load()
                    .expect("load recovery journal")
                    .expect("journal exists");
                if journal.phase == RecoveryPhase::Recovered {
                    store
                        .update(&journal.generation_id, |journal| {
                            journal.phase = RecoveryPhase::Completed;
                            Ok(())
                        })
                        .expect("complete recovery journal");
                    return;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
    };

    tokio::time::timeout(Duration::from_secs(2), gateway.recover_restart_tasks())
        .await
        .expect("permanent failure must not retry forever")
        .expect("retryable task recovers on the same control connection");
    responder.abort();
    completion.await.expect("completion task");
    let journal = store
        .load()
        .expect("load recovery journal")
        .expect("journal exists");
    assert_eq!(journal.phase, RecoveryPhase::Completed);
    assert_eq!(journal.tasks[0].status, RecoveryTaskStatus::Running);
    assert_eq!(journal.tasks[1].status, RecoveryTaskStatus::Running);
    assert_eq!(journal.tasks[2].status, RecoveryTaskStatus::Failed);
    assert_eq!(
        recovery_order.lock().await.as_slice(),
        [
            "thread-runs",
            "thread-retries",
            "thread-retries",
            "thread-invalid"
        ]
    );
    assert_eq!(
        unsubscribe_order.lock().await.as_slice(),
        ["thread-invalid"]
    );
    assert_eq!(
        gateway.core.lock().await.recovered_turn_keys,
        HashSet::from([
            TurnKey::new("thread-retries", "turn-thread-retries"),
            TurnKey::new("thread-runs", "turn-thread-runs"),
        ])
    );
    gateway
        .recover_restart_tasks()
        .await
        .expect("completed recovery is a no-op");
    assert!(gateway.core.lock().await.recovered_turn_keys.is_empty());
}

#[tokio::test]
async fn codex_settings_resume_a_thread_that_is_not_loaded_before_updating_it() {
    let gateway = test_gateway();
    let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;
    let applying = {
        let gateway = Arc::clone(&gateway);
        tokio::spawn(async move {
            gateway
                .update_conversation_settings(json!({
                    "threadId": "cold-thread", "model": "gpt-5.6-luna", "effort": "medium",
                }))
                .await
        })
    };
    answer_thread_load(&gateway, &mut out_rx, "notLoaded").await;
    let resume: Value = serde_json::from_str(&out_rx.recv().await.expect("resume")).expect("JSON");
    assert_eq!(resume["method"], "thread/resume");
    assert_eq!(resume["params"]["threadId"], "cold-thread");
    assert_eq!(resume["params"]["excludeTurns"], true);
    answer_internal_request(&gateway, &resume, json!({})).await;
    let update: Value = serde_json::from_str(&out_rx.recv().await.expect("update")).expect("JSON");
    assert_eq!(update["method"], "thread/settings/update");
    answer_internal_request(&gateway, &update, json!({})).await;
    answer_thread_load(&gateway, &mut out_rx, "idle").await;
    let result = applying.await.expect("task").expect("settings");
    assert_eq!(result["status"], "nextTurn");
}

#[tokio::test]
async fn codex_settings_report_an_unknown_thread_with_the_upstream_code() {
    let gateway = test_gateway();
    let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;
    let applying = {
        let gateway = Arc::clone(&gateway);
        tokio::spawn(async move {
            gateway
                .update_conversation_settings(json!({
                    "threadId": "missing", "model": "gpt-5.6-luna", "effort": "medium",
                }))
                .await
        })
    };
    let read: Value =
        serde_json::from_str(&out_rx.recv().await.expect("load check")).expect("JSON");
    gateway
        .handle_control_text(
            json!({"id": read["id"], "error": {"code": -32600, "message": "thread not found: missing"}})
                .to_string(),
            CONTROL,
        )
        .await;
    let error = applying.await.expect("task").expect_err("unknown thread");
    assert_eq!(error.code, RpcCode::InvalidRequest);
    assert!(out_rx.try_recv().is_err());
}

#[tokio::test]
async fn codex_compaction_checks_fresh_native_activity_before_requesting_the_operation() {
    for status in ["active", "notLoaded", "idle"] {
        let gateway = test_gateway();
        gateway.core.lock().await.app_server_inventory_bootstrapped = true;
        let mut control = crate::test_support::FakeControl::attach(&gateway, 4)
            .await
            .requests;
        let (tx, mut rx) = mpsc::channel(4);
        let compacting = {
            let gateway = Arc::clone(&gateway);
            tokio::spawn(async move {
                let object = request("thread/compact/start", json!({"threadId":"compact-thread"}));
                gateway
                    .handle_owned_rpc(
                        1,
                        &test_client(1, tx),
                        "thread/compact/start",
                        crate::rpc::dispatch::OwnedTarget::Gateway(OwnedRoute::NativeCompaction),
                        &object,
                    )
                    .await
            })
        };
        let read: Value = serde_json::from_str(&control.recv().await.unwrap()).unwrap();
        assert_eq!(read["method"], "thread/read");
        answer_internal_request(
            &gateway,
            &read,
            json!({"thread":{"id":"compact-thread","status":{"type":status}}}),
        )
        .await;
        if status == "idle" {
            let native: Value = serde_json::from_str(&control.recv().await.unwrap()).unwrap();
            assert_eq!(native["method"], "thread/compact/start");
            assert_eq!(native["params"], json!({"threadId":"compact-thread"}));
            answer_internal_request(&gateway, &native, json!({})).await;
        }
        compacting.await.unwrap().unwrap();
        let ClientCommand::Text(text) = rx.recv().await.unwrap() else {
            panic!("JSON response")
        };
        let response: Value = serde_json::from_str(&text).unwrap();
        match status {
            "active" => assert_eq!(response["error"]["code"], -32009),
            "notLoaded" => assert_eq!(response["error"]["code"], -32003),
            _ => assert_eq!(response["result"], json!({})),
        }
        assert!(control.try_recv().is_err());
    }
}

#[tokio::test]
async fn empty_compaction_completion_does_not_send_an_answer_push() {
    let gateway = test_gateway();
    for message in [
        json!({"method":"turn/started","params":{"threadId":"compact-thread","turn":{"id":"compact-turn","status":"inProgress"}}}),
        json!({"method":"item/started","params":{"threadId":"compact-thread","turnId":"compact-turn","item":{"id":"compact-item","type":"contextCompaction"}}}),
        json!({"method":"item/completed","params":{"threadId":"compact-thread","turnId":"compact-turn","item":{"id":"compact-item","type":"contextCompaction"}}}),
    ] {
        gateway.capture_agent_message(&message).await;
    }
    let completed = gateway.capture_agent_message(&json!({"method":"turn/completed","params":{"threadId":"compact-thread","turn":{"id":"compact-turn","status":"completed"}}})).await.unwrap();
    assert!(completed.2.is_none());
    assert!(gateway.core.lock().await.turns.active().next().is_none());
}

#[tokio::test]
async fn compaction_acknowledgment_keeps_exact_client_ownership_until_native_turn_starts() {
    let gateway = test_gateway();
    let object = request("thread/compact/start", json!({"threadId":"compact-thread"}));
    gateway
        .capture_client_request_locked(42, &object)
        .await
        .unwrap();
    gateway
        .capture_turn_start_response(42, &json!({"id":1,"result":{}}))
        .await
        .unwrap();
    assert_eq!(gateway.core.lock().await.turns.pending().count(), 1);
    gateway.capture_agent_message(&json!({"method":"turn/started","params":{"threadId":"compact-thread","turn":{"id":"exact-native-turn","status":"inProgress"}}})).await;
    let core = gateway.core.lock().await;
    assert_eq!(core.turns.pending().count(), 0);
    let turn = core.turns.active_on_thread("compact-thread").unwrap();
    assert_eq!(turn.owner_client_id, 42);
    assert_eq!(turn.turn_id, "exact-native-turn");
    assert!(core.turns.context(&turn.key()).unwrap().compaction);
}

#[tokio::test]
async fn compaction_transport_uncertainty_retains_ownership_and_starts_connected_reconciliation() {
    for uncertain in [false, true] {
        let gateway = test_gateway();
        gateway.core.lock().await.app_server_inventory_bootstrapped = true;
        let mut control = crate::test_support::FakeControl::attach(&gateway, 4)
            .await
            .requests;
        let (tx, mut rx) = mpsc::channel(4);
        gateway.clients.insert(1, test_client(1, tx.clone()));
        let compacting = {
            let gateway = Arc::clone(&gateway);
            tokio::spawn(async move {
                let object = request("thread/compact/start", json!({"threadId":"compact-thread"}));
                gateway
                    .handle_owned_rpc(
                        1,
                        &test_client(1, tx),
                        "thread/compact/start",
                        crate::rpc::dispatch::OwnedTarget::Gateway(OwnedRoute::NativeCompaction),
                        &object,
                    )
                    .await
            })
        };
        let read: Value = serde_json::from_str(&control.recv().await.unwrap()).unwrap();
        answer_internal_request(
            &gateway,
            &read,
            json!({"thread":{"id":"compact-thread","status":{"type":"idle"}}}),
        )
        .await;
        let native: Value = serde_json::from_str(&control.recv().await.unwrap()).unwrap();
        let reply = gateway
            .control_requests
            .lock()
            .unwrap()
            .remove(native["id"].as_str().unwrap())
            .unwrap();
        let error = if uncertain {
            "Control connection closed".to_owned()
        } else {
            json!({"code":-32602,"message":"Native command rejected"}).to_string()
        };
        reply.send(Err(error)).unwrap();
        compacting.await.unwrap().unwrap();
        let ClientCommand::Text(text) = rx.recv().await.unwrap() else {
            panic!("JSON reply")
        };
        let response: Value = serde_json::from_str(&text).unwrap();
        if uncertain {
            assert_eq!(
                response["error"]["data"],
                json!({"kind":"compactionDeliveryUncertain","threadId":"compact-thread","retryable":false})
            );
            assert_eq!(gateway.core.lock().await.turns.pending().count(), 1);
            assert!(
                gateway
                    .observer_tasks
                    .lock()
                    .await
                    .contains_key("compact-thread")
            );
        } else {
            assert_eq!(response["error"]["code"], -32602);
            assert_eq!(gateway.core.lock().await.turns.pending().count(), 0);
            assert!(
                !gateway
                    .observer_tasks
                    .lock()
                    .await
                    .contains_key("compact-thread")
            );
        }
    }
}

#[test]
fn pasted_prompt_notification_subtitles_use_readable_summaries() {
    let fixtures: Vec<Value> = serde_json::from_str(include_str!(
        "../../../protocol-fixtures/attachments/pasted-text-v2-cases.json"
    ))
    .unwrap();
    for case in fixtures {
        let input = json!([{"type": "text", "text": case["prompt"]}]);
        let words: Vec<&str> = case["summary"]
            .as_str()
            .unwrap()
            .split_whitespace()
            .collect();
        let expected = if words.is_empty() {
            "Claude task".to_owned()
        } else if words.len() <= 20 {
            words.join(" ")
        } else {
            format!("{}...", words[..20].join(" "))
        };
        assert_eq!(
            turn_state::prompt_preview("claude_session", Some(&input)),
            expected,
            "{}",
            case["name"]
        );
    }
}

#[tokio::test]
async fn review_regression_opening_accounts_removes_unregistered_live_activity_scopes() {
    let gateway = test_gateway();
    gateway
        .apns
        .report_live_activity("default", crate::push::LiveActivityContent::default())
        .await;
    gateway
        .apns
        .report_live_activity(
            "removed",
            crate::push::LiveActivityContent {
                active_task_count: 1,
                attention: vec![],
                attention_count: 0,
            },
        )
        .await;
    let directory = tempfile::tempdir().unwrap();
    let _accounts = crate::accounts::Accounts::open_in(
        directory.path().to_path_buf(),
        std::sync::Arc::clone(&gateway),
        gateway.claude_settings.clone(),
    )
    .await
    .unwrap();
    let snapshot = gateway
        .apns
        .live_activity_updates()
        .borrow()
        .clone()
        .unwrap();
    assert!(snapshot.content.is_empty());
}

#[tokio::test]
async fn content_routing_ingest_runs_side_effects_once_and_reconnect_recovers_canonical_items() {
    use crate::rpc::dispatch::{ClaudeMethod, OwnedRoute, OwnedTarget};

    let mut isolated = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    isolated.settings.enabled = true;
    let gateway = crate::test_support::TestGateway::with_settings(
        Arc::new(CodexAppServer::new("/bin/true".into(), HashMap::new())),
        isolated.settings.clone(),
        Arc::new(isolated),
    );
    let mut receivers = Vec::new();
    for (id, threads) in [
        (1, Some(vec!["claude_a"])),
        (2, Some(vec!["claude_a"])),
        (3, Some(vec!["claude_other"])),
        (4, None),
    ] {
        let (tx, rx) = mpsc::channel(32);
        let client = test_client(id, tx);
        if let Some(threads) = threads {
            client
                .content_subscriptions
                .replace(json!({"threadIds":threads}))
                .unwrap();
        }
        gateway.clients.insert(id, client);
        receivers.push(rx);
    }
    let (tx, _blocked_rx) = mpsc::channel(1);
    let blocked = test_client(5, tx);
    blocked
        .try_send(ClientCommand::Text("occupied".into()))
        .unwrap();
    gateway.clients.insert(5, blocked.clone());
    let (completion_tx, mut completion_rx) = mpsc::channel(8);
    *gateway.apns_completion_tx.lock().await = Some(completion_tx);
    let (activity_tx, mut activity_rx) =
        tokio::sync::watch::channel(ActiveTasksLiveActivitySnapshot::default());
    *gateway.apns_live_activity_tx.lock().await = Some(activity_tx);
    let mut session = external_voice_session();
    session.conversation_thread_id = "claude_a".into();
    session.delegations.begin("handoff", "input", 0.0);
    session.delegations.bind_input("input", "turn-a");
    gateway.voice.seed(None, Some(session));
    let mut control = crate::test_support::FakeControl::attach(&gateway, 16).await;
    let captured = Arc::new(Mutex::new(Vec::new()));
    let weak = Arc::downgrade(&gateway);
    let calls = Arc::clone(&captured);
    let responder = tokio::spawn(async move {
        while let Some(raw) = control.requests.recv().await {
            let request: Value = serde_json::from_str(&raw).unwrap();
            calls.lock().await.push(request.clone());
            let Some(gateway) = weak.upgrade() else { break };
            answer_internal_request(&gateway, &request, json!({})).await;
        }
    });
    let floor = gateway.notification_floor().await;
    for event in [
        message(
            "turn/started",
            json!({"threadId":"claude_a","turn":{"id":"turn-a","status":"inProgress"}}),
        ),
        message(
            "conversation/questions/changed",
            json!({"threadId":"claude_a","epoch":"question-epoch","revision":7,"itemIds":["question-a"]}),
        ),
        message(
            "item/agentMessage/delta",
            json!({"threadId":"claude_a","turnId":"turn-a","itemId":"answer-a","delta":"Recovered answer"}),
        ),
        message(
            "item/completed",
            json!({"threadId":"claude_a","turnId":"turn-a","item":{"id":"answer-a","type":"agentMessage","text":"Recovered answer"}}),
        ),
        message(
            "turn/completed",
            json!({"threadId":"claude_a","turn":{"id":"turn-a","status":"completed"}}),
        ),
    ] {
        let starts_turn = event["method"] == "turn/started";
        gateway.ingest_agent_notification(event).await;
        if starts_turn {
            assert!(activity_rx.has_changed().unwrap());
            assert_eq!(
                activity_rx.borrow_and_update().running,
                BTreeSet::from(["claude_a".to_owned()])
            );
        }
    }
    assert!(blocked.closed.is_cancelled());
    assert!(!gateway.clients.contains_key(&5));
    for id in 1..=4 {
        let healthy = gateway.clients.get(&id).unwrap();
        assert!(!healthy.closed.is_cancelled());
    }
    for (index, rx) in receivers.iter_mut().enumerate() {
        let mut frames = Vec::new();
        while let Ok(ClientCommand::Text(raw)) = rx.try_recv() {
            frames.push(serde_json::from_str::<Value>(&raw).unwrap());
        }
        let methods = frames
            .iter()
            .map(|frame| frame["method"].as_str().unwrap())
            .collect::<Vec<_>>();
        let expected = if index == 2 {
            vec![
                "turn/started",
                "conversation/questions/changed",
                "turn/completed",
            ]
        } else {
            vec![
                "turn/started",
                "conversation/questions/changed",
                "item/agentMessage/delta",
                "item/completed",
                "turn/completed",
            ]
        };
        assert_eq!(methods, expected);
        assert_eq!(frames[1]["params"]["epoch"], "question-epoch");
        assert_eq!(frames[1]["params"]["itemIds"], json!(["question-a"]));
        assert_eq!(frames[1]["params"]["revision"], 7);
    }
    assert_eq!(gateway.notification_floor().await, floor + 3);
    let push = completion_rx.try_recv().unwrap();
    assert_eq!(push.payload["eventID"], "claude_a:turn-a");
    assert_eq!(push.payload["messagePreview"], "Recovered answer");
    assert!(completion_rx.try_recv().is_err());
    assert!(activity_rx.has_changed().unwrap());
    assert!(activity_rx.borrow_and_update().running.is_empty());
    assert!(!activity_rx.has_changed().unwrap());
    let calls = captured.lock().await;
    let appends = calls
        .iter()
        .filter(|call| call["method"] == "thread/realtime/handoff/append")
        .collect::<Vec<_>>();
    assert_eq!(appends.len(), 1);
    assert_eq!(appends[0]["params"]["text"], "Recovered answer");
    let completions = calls
        .iter()
        .filter(|call| call["method"] == "thread/realtime/handoff/complete")
        .collect::<Vec<_>>();
    assert_eq!(completions.len(), 1);
    assert_eq!(completions[0]["params"]["text"], "Recovered answer");
    drop(calls);
    responder.abort();

    let project = gateway
        .claude_settings
        .claude_home
        .join("projects")
        .join("fixture");
    std::fs::create_dir_all(&project).unwrap();
    let records = [
        json!({"type":"user","uuid":"prompt-a","timestamp":"2026-10-08T02:00:00Z","cwd":"/tmp","message":{"role":"user","content":"Recover"}}),
        json!({"type":"assistant","uuid":"answer-a","timestamp":"2026-10-08T02:00:01Z","message":{"id":"message-a","role":"assistant","content":[{"type":"text","text":"Recovered answer"}]}}),
    ];
    std::fs::write(
        project.join("a.jsonl"),
        records
            .iter()
            .map(|record| format!("{record}\n"))
            .collect::<String>(),
    )
    .unwrap();
    gateway.clients.remove(&1);
    let (tx, mut rx) = mpsc::channel(8);
    let reconnect = test_client(6, tx);
    gateway.clients.insert(6, reconnect.clone());
    for (id, method, target, params) in [
        (
            1,
            "conversation/subscriptions/set",
            OwnedTarget::Gateway(OwnedRoute::Subscriptions),
            json!({"threadIds":["claude_a"]}),
        ),
        (
            2,
            "thread/items/list",
            OwnedTarget::Claude(ClaudeMethod::ItemsPage),
            json!({"threadId":"claude_a","limit":10}),
        ),
        (
            3,
            "daemon/replayNotifications",
            OwnedTarget::Gateway(OwnedRoute::ReplayNotifications),
            json!({"threadId":"claude_a","afterSequence":floor}),
        ),
    ] {
        gateway
            .handle_owned_rpc(
                6,
                &reconnect,
                method,
                target,
                json!({"id":id,"params":params}).as_object().unwrap(),
            )
            .await
            .unwrap();
        let ClientCommand::Text(raw) = rx.try_recv().unwrap() else {
            panic!("expected response")
        };
        let response: Value = serde_json::from_str(&raw).unwrap();
        assert!(response.get("error").is_none(), "{response}");
        if id == 2 {
            let items = response["result"]["data"].as_array().unwrap();
            assert!(
                items
                    .iter()
                    .any(|entry| entry["item"]["text"] == "Recovered answer")
            );
        }
        if id == 3 {
            let events = response["result"]["notifications"].as_array().unwrap();
            assert_eq!(events.len(), 3);
            assert_eq!(events[1]["message"]["method"], "item/completed");
            assert_eq!(
                events[1]["message"]["params"]["item"]["text"],
                "Recovered answer"
            );
            assert!(
                !events
                    .iter()
                    .any(|event| event["message"]["method"] == "item/agentMessage/delta")
            );
        }
    }
}
