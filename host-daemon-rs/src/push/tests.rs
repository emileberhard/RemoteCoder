use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use axum::http::StatusCode;
use axum::{
    Json, Router,
    extract::State,
    routing::{get, post},
};
use serde_json::{Value, json};

use super::*;
use crate::devices::{DeviceRegistration, fixture_registration_json};

struct MockBroker {
    requests: std::sync::Mutex<Vec<Value>>,
    in_flight: AtomicUsize,
    peak: AtomicUsize,
    delay: Duration,
    rejected: Vec<String>,
    relevance: bool,
}

impl MockBroker {
    fn new(delay: Duration, rejected: Vec<String>) -> Arc<Self> {
        Arc::new(Self {
            requests: std::sync::Mutex::default(),
            in_flight: AtomicUsize::new(0),
            peak: AtomicUsize::new(0),
            delay,
            rejected,
            relevance: false,
        })
    }

    fn requests(&self) -> Vec<Value> {
        self.requests.lock().expect("recorded requests").clone()
    }
}

async fn record(
    State(broker): State<Arc<MockBroker>>,
    Json(body): Json<Value>,
) -> (StatusCode, Json<Value>) {
    let now = broker.in_flight.fetch_add(1, Ordering::SeqCst) + 1;
    broker.peak.fetch_max(now, Ordering::SeqCst);
    tokio::time::sleep(broker.delay).await;
    broker.in_flight.fetch_sub(1, Ordering::SeqCst);
    let token = body["device_token"].as_str().unwrap_or_default().to_owned();
    broker
        .requests
        .lock()
        .expect("recorded requests")
        .push(body);
    if broker.rejected.contains(&token) {
        (
            StatusCode::BAD_REQUEST,
            Json(json!({"apns_reason": "BadDeviceToken"})),
        )
    } else {
        (StatusCode::OK, Json(json!({"apns_id": "fixture-delivery"})))
    }
}

async fn capabilities(State(broker): State<Arc<MockBroker>>) -> Json<Value> {
    Json(if broker.relevance {
        json!({"capabilities":{"live_activity_relevance_score":true}})
    } else {
        json!({"status":"ok"})
    })
}

async fn service(broker: &Arc<MockBroker>) -> (PushService, tokio::task::JoinHandle<()>) {
    let app = Router::new()
        .route("/healthz", get(capabilities))
        .route("/v1/internal/alert", post(record))
        .route("/v1/internal/live-activity", post(record))
        .with_state(Arc::clone(broker));
    let (address, server) = crate::test_support::serve(app).await;
    let service =
        PushService::fixture_broker(format!("http://{address}"), Journal::disabled(), None).await;
    (service, server)
}

fn alert_token(seed: u8) -> String {
    format!("a1{seed:02x}").repeat(16)
}

fn device(seed: u8, host: &str) -> DeviceRegistration {
    let mut value = fixture_registration_json(seed);
    value["appHostId"] = json!(host);
    serde_json::from_value(value).expect("fixture registration")
}

#[tokio::test]
async fn a_completion_reaches_every_alert_device_stamped_with_its_own_host() {
    let broker = MockBroker::new(Duration::ZERO, Vec::new());
    let (service, server) = service(&broker).await;
    let second_host = "BBBBBBBB-0000-0000-0000-000000000002";
    service
        .devices()
        .register(device(2, second_host))
        .await
        .unwrap();

    service
        .send_task_completion(
            "thread",
            "Done",
            "",
            "Finished",
            &json!({"eventID":"thread:turn","sessionID":"thread","source":"claude","hostID":"unproven"}),
        )
        .await;

    let requests = broker.requests();
    assert_eq!(requests.len(), 2);
    for (seed, host) in [
        (1, "AAAAAAAA-0000-0000-0000-000000000001"),
        (2, second_host),
    ] {
        let request = requests
            .iter()
            .find(|request| request["device_token"] == alert_token(seed))
            .expect("request for device");
        let payload: Value =
            serde_json::from_str(request["custom_data"][PAYLOAD_KEY].as_str().unwrap()).unwrap();
        assert_eq!(payload["source"], "claude");
        assert_eq!(payload["hostID"], host);
    }
    server.abort();
}

#[tokio::test]
async fn alert_fan_out_never_exceeds_four_concurrent_sends() {
    let broker = MockBroker::new(Duration::from_millis(100), Vec::new());
    let (service, server) = service(&broker).await;
    for seed in 2..=8 {
        service
            .devices()
            .register(device(seed, "AAAAAAAA-0000-0000-0000-000000000001"))
            .await
            .unwrap();
    }

    service
        .send_user_alert("Title", "Body", Some("thread"))
        .await
        .unwrap();

    assert_eq!(broker.requests().len(), 8);
    let peak = broker.peak.load(Ordering::SeqCst);
    assert!((2..=MAX_CONCURRENT_SENDS).contains(&peak), "peak {peak}");
    server.abort();
}

#[tokio::test]
async fn a_rejected_token_is_removed_and_the_other_device_still_gets_the_alert() {
    let broker = MockBroker::new(Duration::ZERO, vec![alert_token(2)]);
    let (service, server) = service(&broker).await;
    service
        .devices()
        .register(device(2, "AAAAAAAA-0000-0000-0000-000000000001"))
        .await
        .unwrap();

    service
        .send_user_alert("Title", "Body", None)
        .await
        .expect("one device accepted the alert");

    let remaining = service.devices().alert_targets().await.unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].destination.token.as_str(), alert_token(1));
    server.abort();
}

#[tokio::test]
async fn a_user_alert_fails_with_the_broker_reason_when_every_device_rejects_it() {
    let broker = MockBroker::new(Duration::ZERO, vec![alert_token(1)]);
    let (service, server) = service(&broker).await;

    let failure = service
        .send_user_alert("Title", "Body", None)
        .await
        .unwrap_err();

    assert!(matches!(failure, DeliveryFailure::Rejected(_)), "{failure}");
    assert!(service.devices().alert_targets().await.unwrap().is_empty());
    server.abort();
}

const LOCAL: &str = "aaaaaaaa-0000-4000-8000-00000000000a";
const PEER: &str = "bbbbbbbb-0000-4000-8000-00000000000b";
const UNJOINED: &str = "cccccccc-0000-4000-8000-00000000000c";

#[tokio::test]
async fn live_activity_updates_reach_every_registered_activity() {
    let broker = MockBroker::new(Duration::ZERO, Vec::new());
    let (service, server) = service(&broker).await;
    service
        .devices()
        .register(device(2, "AAAAAAAA-0000-0000-0000-000000000001"))
        .await
        .unwrap();

    service.report_live_activity(None, content(1, &[])).await;

    let requests = broker.requests();
    assert!(
        requests
            .iter()
            .all(|request| request.get("relevance_score").is_none())
    );
    let tokens: Vec<_> = requests
        .iter()
        .map(|request| request["device_token"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(tokens.len(), 2);
    assert!(tokens.iter().all(|token| token.starts_with("a2")));
    assert_eq!(requests[0]["content_state"]["activeTaskCount"], 1);
    assert!(
        requests[0]["content_state"]
            .get("unavailableHostIDs")
            .is_none()
    );
    server.abort();
}

fn content(running: usize, rows: &[(&str, i64)]) -> SourceProjection {
    SourceProjection {
        content: LiveActivityContent {
            active_task_count: running,
            attention: rows
                .iter()
                .map(|(thread, completed_at)| AttentionRow {
                    host_id: None,
                    thread_id: (*thread).into(),
                    title: None,
                    reason: AttentionReason::FinishedUnread {
                        completed_at: *completed_at,
                    },
                })
                .collect(),
            attention_count: rows.len(),
        },
        running_roots: (0..running)
            .map(|index| (format!("root-{index}"), format!("root-{index}")))
            .collect(),
        ..SourceProjection::default()
    }
}

fn sent(broker: &MockBroker) -> Vec<(Value, Value, Vec<Value>)> {
    broker
        .requests()
        .into_iter()
        .map(|request| {
            let state = &request["content_state"];
            let threads = state["attention"]
                .as_array()
                .unwrap()
                .iter()
                .map(|row| row["threadID"].clone())
                .collect();
            (
                request["event"].clone(),
                state["attentionCount"].clone(),
                threads,
            )
        })
        .collect()
}

fn fleet_device(seed: u8, hosts: &[&str]) -> DeviceRegistration {
    let mut value = fixture_registration_json(seed);
    value["tokens"] = json!({
        "alert": alert_token(seed),
        "fleetActivity": {"token": fleet_token(seed), "hosts": hosts},
    });
    serde_json::from_value(value).expect("fleet registration")
}

fn fleet_token(seed: u8) -> String {
    format!("f1{seed:02x}").repeat(16)
}

fn fleet_requests(broker: &MockBroker, seed: u8) -> Vec<Value> {
    broker
        .requests()
        .into_iter()
        .filter(|request| request["device_token"] == fleet_token(seed))
        .collect()
}

fn peer(service: &PushService, client: u64, projection: Option<SourceProjection>) -> PeerOutcome {
    service.receive_peer_live_activity(PEER, client, projection)
}

#[tokio::test]
async fn fleet_tokens_receive_their_declared_hosts_with_exact_row_hosts() {
    let broker = MockBroker::new(Duration::ZERO, Vec::new());
    let (service, server) = service(&broker).await;
    service
        .devices()
        .register(fleet_device(2, &[LOCAL, PEER]))
        .await
        .unwrap();
    service
        .devices()
        .register(fleet_device(3, &[LOCAL]))
        .await
        .unwrap();
    service
        .devices()
        .register(device(4, "AAAAAAAA-0000-0000-0000-000000000001"))
        .await
        .unwrap();
    peer(&service, 1, Some(content(2, &[("shared", 30)])));
    service
        .report_live_activity(Some(LOCAL), content(1, &[("shared", 20), ("local", 10)]))
        .await;

    let both = fleet_requests(&broker, 2);
    let state = &both.last().unwrap()["content_state"];
    assert_eq!(state["activeTaskCount"], 3);
    assert_eq!(state["attentionCount"], 3);
    assert_eq!(
        state["attention"],
        json!([
            {"hostID": PEER, "threadID": "shared", "reason": "finishedUnread", "completedAtUnixSeconds": 30},
            {"hostID": LOCAL, "threadID": "shared", "reason": "finishedUnread", "completedAtUnixSeconds": 20},
            {"hostID": LOCAL, "threadID": "local", "reason": "finishedUnread", "completedAtUnixSeconds": 10},
        ])
    );
    assert_eq!(state["unavailableHostIDs"], json!([]));
    let local_only = fleet_requests(&broker, 3).last().unwrap()["content_state"].clone();
    assert_eq!(local_only["activeTaskCount"], 1);
    assert_eq!(local_only["attentionCount"], 2);
    let legacy = broker
        .requests()
        .into_iter()
        .rfind(|request| request["device_token"].as_str().unwrap().starts_with("a2"))
        .unwrap();
    assert!(
        legacy["content_state"]["attention"][0]
            .get("hostID")
            .is_none()
    );
    assert!(legacy["content_state"].get("unavailableHostIDs").is_none());
    server.abort();
}

#[tokio::test]
async fn unavailable_hosts_keep_their_last_known_work_and_only_certified_empty_ends() {
    let broker = MockBroker::new(Duration::ZERO, Vec::new());
    let (service, server) = service(&broker).await;
    service
        .devices()
        .register(fleet_device(2, &[LOCAL, PEER, UNJOINED]))
        .await
        .unwrap();
    peer(&service, 1, Some(content(1, &[("remote", 30)])));
    service.peer_live_activity_closed(PEER, 1);
    service
        .report_live_activity(Some(LOCAL), content(0, &[]))
        .await;
    let state = fleet_requests(&broker, 2).last().unwrap()["content_state"].clone();
    assert_eq!(state["activeTaskCount"], 1);
    assert_eq!(state["attention"][0]["hostID"], PEER);
    assert_eq!(state["unavailableHostIDs"], json!([PEER, UNJOINED]));

    peer(&service, 2, Some(content(0, &[])));
    service.publish_fleet_live_activity(Some(LOCAL)).await;
    let last = fleet_requests(&broker, 2).last().unwrap().clone();
    assert_eq!(last["event"], "update");
    assert_eq!(
        last["content_state"]["unavailableHostIDs"],
        json!([UNJOINED])
    );

    service
        .devices()
        .register(fleet_device(2, &[LOCAL, PEER]))
        .await
        .unwrap();
    service.publish_fleet_live_activity(Some(LOCAL)).await;
    assert_eq!(fleet_requests(&broker, 2).last().unwrap()["event"], "end");
    server.abort();
}

#[tokio::test]
async fn peer_currency_follows_the_newest_connection_and_restarts_as_last_known() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("live-activity-fleet.json");
    let make = || {
        PushService::new(
            crate::push::PushConfiguration::Disabled,
            Journal::disabled(),
            Arc::new(DeviceRegistry::temporary()),
            Some(path.clone()),
        )
    };
    let service = make();
    assert_eq!(
        peer(&service, 5, Some(content(1, &[]))),
        PeerOutcome::Accepted
    );
    assert_eq!(peer(&service, 4, Some(content(0, &[]))), PeerOutcome::Stale);
    service.peer_live_activity_closed(PEER, 4);
    let current = fleet(&service, &[PEER]);
    assert_eq!(current.content.active_task_count, 1);
    assert!(current.unavailable_host_ids.is_empty());

    let mut inconsistent = content(1, &[]);
    inconsistent.content.active_task_count = 3;
    assert!(matches!(
        peer(&service, 5, Some(inconsistent)),
        PeerOutcome::Rejected(_)
    ));
    let withdrawn = fleet(&service, &[PEER]);
    assert_eq!(withdrawn.content.active_task_count, 1);
    assert_eq!(withdrawn.unavailable_host_ids, vec![PEER.to_owned()]);
    assert_eq!(peer(&service, 4, Some(content(0, &[]))), PeerOutcome::Stale);

    assert_eq!(
        peer(&service, 6, Some(content(2, &[]))),
        PeerOutcome::Accepted
    );
    assert!(fleet(&service, &[PEER]).unavailable_host_ids.is_empty());
    service
        .report_live_activity(Some(LOCAL), content(0, &[]))
        .await;

    let restarted = make();
    let restored = fleet(&restarted, &[PEER]);
    assert_eq!(restored.content.active_task_count, 2);
    assert_eq!(restored.unavailable_host_ids, vec![PEER.to_owned()]);
    assert_eq!(
        peer(&restarted, 1, Some(content(3, &[]))),
        PeerOutcome::Accepted
    );
    let fresh = fleet(&restarted, &[PEER]);
    assert_eq!(fresh.content.active_task_count, 3);
    assert!(fresh.unavailable_host_ids.is_empty());
}

fn fleet(service: &PushService, hosts: &[&str]) -> super::live_activity::FleetContent {
    let hosts: Vec<String> = hosts.iter().map(|host| (*host).to_owned()).collect();
    service.fleet_live_activity_snapshot(&hosts, LOCAL).content
}

fn delegated(roots: &[&str], parents: &[(&str, &str, &str)]) -> SourceProjection {
    let mut projection = SourceProjection {
        content: LiveActivityContent::default(),
        running_roots: roots
            .iter()
            .map(|root| ((*root).to_owned(), (*root).to_owned()))
            .collect(),
        remote_parents: parents
            .iter()
            .map(|(root, host, thread)| {
                (
                    (*root).to_owned(),
                    crate::wire::cluster::AgentAddress {
                        host_id: (*host).into(),
                        thread_id: (*thread).into(),
                    },
                )
            })
            .collect(),
        ..SourceProjection::default()
    };
    projection.content.active_task_count = projection.running_trees(LOCAL).len();
    projection
}

#[tokio::test]
async fn delegated_trees_count_once_under_their_owning_root() {
    let service = PushService::fixture_disabled(Journal::disabled());
    let third = "dddddddd-0000-4000-8000-00000000000d";
    let hosts = [LOCAL, PEER, third];
    service
        .report_live_activity(Some(LOCAL), delegated(&["child"], &[("child", PEER, "b")]))
        .await;
    assert_eq!(
        *service.referenced_thread_changes().borrow(),
        std::collections::BTreeSet::new()
    );
    peer(&service, 1, Some(delegated(&[], &[])));
    let unresolved = fleet(&service, &hosts);
    assert_eq!(unresolved.content.active_task_count, 1);
    assert_eq!(
        unresolved.unavailable_host_ids,
        vec![PEER.to_owned(), third.to_owned()]
    );

    let mut idle_middle = delegated(&[], &[("b", third, "c")]);
    idle_middle.ancestry.insert("b".into(), "b".into());
    peer(&service, 1, Some(idle_middle));
    service.receive_peer_live_activity(third, 2, Some(delegated(&["c"], &[])));
    let nested = fleet(&service, &hosts);
    assert_eq!(nested.content.active_task_count, 1);
    assert!(nested.unavailable_host_ids.is_empty());
    assert!(
        service
            .referenced_threads()
            .contains(&crate::wire::cluster::AgentAddress {
                host_id: third.into(),
                thread_id: "c".into(),
            })
    );
}

#[tokio::test]
async fn a_new_activity_token_receives_the_current_content_once() {
    let broker = MockBroker::new(Duration::ZERO, Vec::new());
    let (service, server) = service(&broker).await;
    service.report_live_activity(None, content(1, &[])).await;
    service.report_live_activity(None, content(1, &[])).await;
    assert_eq!(broker.requests().len(), 1);

    service
        .devices()
        .register(device(2, "AAAAAAAA-0000-0000-0000-000000000001"))
        .await
        .unwrap();
    service.report_live_activity(None, content(1, &[])).await;
    service.report_live_activity(None, content(1, &[])).await;

    assert_eq!(broker.requests().len(), 2);
    server.abort();
}

#[tokio::test]
async fn a_token_registered_after_the_end_is_ended_too() {
    let broker = MockBroker::new(Duration::ZERO, Vec::new());
    let (service, server) = service(&broker).await;
    service.report_live_activity(None, content(1, &[])).await;
    service.report_live_activity(None, content(0, &[])).await;
    service
        .devices()
        .register(device(2, "AAAAAAAA-0000-0000-0000-000000000001"))
        .await
        .unwrap();
    service.report_live_activity(None, content(0, &[])).await;

    let events: Vec<Value> = broker
        .requests()
        .iter()
        .map(|request| request["event"].clone())
        .collect();
    assert_eq!(events, vec![json!("update"), json!("end"), json!("end")]);
    server.abort();
}

#[tokio::test]
async fn restored_content_waits_for_a_fresh_projection_before_any_delivery() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("live-activity-fleet.json");
    let probe = crate::test_support::LiveActivityProbe::new(Some(path.clone())).await;
    probe
        .service
        .report_live_activity(Some(LOCAL), content(0, &[("old", 20)]))
        .await;
    drop(probe);

    let restarted = crate::test_support::LiveActivityProbe::new(Some(path)).await;
    let restored = restarted
        .service
        .fleet_live_activity_snapshot(&[LOCAL.to_owned()], LOCAL);
    assert_eq!(restored.content.content.attention_count, 1);
    assert_eq!(
        restored.content.unavailable_host_ids,
        vec![LOCAL.to_owned()]
    );
    assert!(restarted.service.live_activity_updates().borrow().is_none());
    restarted
        .service
        .publish_fleet_live_activity(Some(LOCAL))
        .await;
    assert!(restarted.requests.lock().unwrap().is_empty());
    restarted
        .service
        .report_live_activity(Some(LOCAL), content(0, &[("fresh", 30)]))
        .await;
    let requests = restarted.requests.lock().unwrap().clone();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0]["content_state"]["attention"][0]["threadID"],
        "fresh"
    );
}

#[tokio::test]
async fn an_alert_without_a_registered_device_reports_no_destination() {
    let service =
        PushService::fixture_broker("http://127.0.0.1:1".into(), Journal::disabled(), None).await;
    service
        .devices()
        .unregister("00000000-0000-4000-8000-000000000001")
        .await
        .unwrap();
    assert!(matches!(
        service.send_user_alert("Title", "Body", None).await,
        Err(DeliveryFailure::NoDestination)
    ));
    assert_eq!(
        service.check_alert_registration("alert").await,
        Err(NO_ALERT_DEVICE)
    );
}

#[test]
fn an_attention_row_uses_the_widget_keys_and_omits_an_unknown_host() {
    let mut row = AttentionRow {
        host_id: None,
        thread_id: "thread-1".into(),
        title: Some("Title".into()),
        reason: AttentionReason::Question { completed_at: None },
    };
    assert_eq!(
        serde_json::to_value(&row).unwrap(),
        json!({"threadID": "thread-1", "title": "Title", "reason": "question"})
    );

    row.host_id = Some(PEER.into());
    row.reason = AttentionReason::FinishedUnread { completed_at: 20 };
    assert_eq!(
        serde_json::to_value(&row).unwrap(),
        json!({
            "hostID": PEER,
            "threadID": "thread-1",
            "title": "Title",
            "reason": "finishedUnread",
            "completedAtUnixSeconds": 20,
        })
    );
}

#[tokio::test]
async fn live_activity_clients_receive_the_same_local_projection_as_pushes() {
    let service = PushService::fixture_disabled(Journal::disabled());
    let updates = service.live_activity_updates();
    assert!(updates.borrow().is_none());
    service
        .report_live_activity(None, content(0, &[("done", 10)]))
        .await;
    let first = updates.borrow().clone().unwrap();
    assert_eq!(first.content, content(0, &[("done", 10)]).content);
    service
        .report_live_activity(None, content(2, &[("other", 20), ("done", 10)]))
        .await;
    let next = updates.borrow().clone().unwrap();
    assert_eq!(next.epoch, first.epoch);
    assert!(next.revision > first.revision);
    assert_eq!(next.content.active_task_count, 2);
    assert_eq!(next.content.attention_count, 2);
    assert_eq!(next.content.attention[0].thread_id, "other");
}

#[tokio::test]
async fn review_regression_an_attention_host_always_outranks_a_running_only_host() {
    let mut broker = MockBroker::new(Duration::ZERO, vec![]);
    Arc::get_mut(&mut broker).unwrap().relevance = true;
    let (service, server) = service(&broker).await;
    service.report_live_activity(None, content(4, &[])).await;
    let mut asking = content(2, &[]);
    asking.content.attention = vec![AttentionRow {
        host_id: None,
        thread_id: "asking".into(),
        title: None,
        reason: AttentionReason::Question {
            completed_at: Some(20),
        },
    }];
    asking.content.attention_count = 1;
    service.report_live_activity(None, asking).await;
    let requests = broker.requests();
    assert_eq!(requests[0]["relevance_score"], 25);
    assert_eq!(requests[1]["relevance_score"], 100);
    server.abort();
}

#[test]
fn attention_rows_are_newest_completion_first_whatever_their_marker() {
    let row = |thread: &str, reason| AttentionRow {
        host_id: None,
        thread_id: thread.into(),
        title: None,
        reason,
    };
    let mut rows = [
        row("legacy", AttentionReason::Question { completed_at: None }),
        row(
            "older",
            AttentionReason::FinishedUnread { completed_at: 10 },
        ),
        row(
            "asking",
            AttentionReason::Question {
                completed_at: Some(30),
            },
        ),
        row(
            "newer",
            AttentionReason::FinishedUnread { completed_at: 20 },
        ),
    ];
    rows.sort_by(AttentionRow::attention_order);
    assert_eq!(
        rows.iter()
            .map(|row| row.thread_id.as_str())
            .collect::<Vec<_>>(),
        ["asking", "newer", "older", "legacy"]
    );
}

#[tokio::test]
async fn a_damaged_cache_never_blocks_a_fresh_projection() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("live-activity-fleet.json");
    std::fs::write(&path, b"{unfinished").unwrap();
    let service = PushService::new(
        crate::push::PushConfiguration::Disabled,
        Journal::disabled(),
        Arc::new(DeviceRegistry::temporary()),
        Some(path.clone()),
    );
    assert_eq!(
        fleet(&service, &[LOCAL]).unavailable_host_ids,
        vec![LOCAL.to_owned()]
    );
    service.report_live_activity(None, content(2, &[])).await;
    assert_eq!(
        service
            .live_activity_updates()
            .borrow()
            .as_ref()
            .unwrap()
            .content
            .active_task_count,
        2
    );
    let cached: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(cached["local"]["content"]["activeTaskCount"], 2);
}

#[tokio::test]
async fn a_rejected_activity_token_stays_eligible_after_the_client_registers_it_again() {
    let rejected = fixture_registration_json(1)["tokens"]["liveActivity"]
        .as_str()
        .unwrap()
        .to_owned();
    let broker = MockBroker::new(Duration::ZERO, vec![rejected]);
    let (service, server) = service(&broker).await;
    service.report_live_activity(None, content(1, &[])).await;
    service
        .devices()
        .register(crate::devices::fixture_registration(1))
        .await
        .unwrap();
    service.report_live_activity(None, content(1, &[])).await;
    assert_eq!(broker.requests().len(), 2);
    server.abort();
}

#[tokio::test]
async fn an_unavailable_local_source_blocks_delivery_until_its_fresh_projection_returns() {
    let broker = MockBroker::new(Duration::ZERO, Vec::new());
    let (service, server) = service(&broker).await;
    service.report_live_activity(None, content(1, &[])).await;
    let first_revision = service
        .live_activity_updates()
        .borrow()
        .as_ref()
        .unwrap()
        .revision;
    service
        .mark_live_activity_unavailable_if_current(None, || true)
        .await;
    assert!(service.live_activity_updates().borrow().is_none());
    assert_eq!(broker.requests().len(), 1);
    service.report_live_activity(None, content(1, &[])).await;
    assert!(
        service
            .live_activity_updates()
            .borrow()
            .as_ref()
            .unwrap()
            .revision
            > first_revision
    );
    service.report_live_activity(None, content(0, &[])).await;
    assert_eq!(
        sent(&broker)
            .iter()
            .map(|(event, _, _)| event.clone())
            .collect::<Vec<_>>(),
        vec![json!("update"), json!("update"), json!("end")]
    );
    server.abort();
}
