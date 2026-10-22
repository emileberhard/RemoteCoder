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

#[tokio::test]
async fn live_activity_updates_reach_every_registered_activity() {
    let broker = MockBroker::new(Duration::ZERO, Vec::new());
    let (service, server) = service(&broker).await;
    service
        .devices()
        .register(device(2, "AAAAAAAA-0000-0000-0000-000000000001"))
        .await
        .unwrap();

    service
        .report_live_activity("default", content(1, &[]))
        .await;

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
    server.abort();
}

fn content(running: usize, rows: &[(&str, i64)]) -> LiveActivityContent {
    LiveActivityContent {
        active_task_count: running,
        attention: rows
            .iter()
            .map(|(thread, completed_at)| AttentionRow {
                thread_id: (*thread).into(),
                account_id: None,
                title: None,
                reason: AttentionReason::FinishedUnread {
                    completed_at: *completed_at,
                },
            })
            .collect(),
        attention_count: rows.len(),
    }
}

#[tokio::test]
async fn review_recheck_a_superseded_persistence_cannot_authorize_another_scopes_end() {
    let directory = tempfile::tempdir().unwrap();
    let probe =
        crate::test_support::LiveActivityProbe::new(Some(directory.path().join("activity.json")))
            .await;
    let service = probe.service.clone();
    service
        .reconcile_live_activity_scopes(&std::collections::BTreeSet::from([
            "default".into(),
            "peer".into(),
        ]))
        .await;
    service.report_live_activity("peer", content(0, &[])).await;
    service
        .report_live_activity("default", content(1, &[]))
        .await;
    let started = Arc::new(tokio::sync::Notify::new());
    let release = Arc::new(tokio::sync::Notify::new());
    service.live_activity.lock().await.persistence_gate = Some((started.clone(), release.clone()));
    let current = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let writer = {
        let service = service.clone();
        let current = current.clone();
        tokio::spawn(async move {
            service
                .report_live_activity_if_current("default", content(0, &[]), || {
                    current.load(Ordering::Acquire)
                })
                .await;
        })
    };
    tokio::time::timeout(Duration::from_secs(3), started.notified())
        .await
        .unwrap();
    current.store(false, Ordering::Release);
    release.notify_one();
    writer.await.unwrap();
    service.live_activity.lock().await.persistence_gate = None;
    service.report_live_activity("peer", content(0, &[])).await;
    let held = service.live_activity_updates().borrow().clone();
    let requests = probe.requests.lock().unwrap().clone();
    assert!(held.is_none(), "{requests:?}");
    assert!(
        requests.iter().all(|request| request["event"] != "end"),
        "{requests:?}"
    );
    service
        .report_live_activity("default", content(1, &[]))
        .await;
    assert_eq!(
        service
            .live_activity_updates()
            .borrow()
            .as_ref()
            .unwrap()
            .content
            .active_task_count,
        1
    );
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

#[tokio::test]
async fn accounts_share_one_activity_that_ends_only_when_every_account_is_empty() {
    let broker = MockBroker::new(Duration::ZERO, Vec::new());
    let (service, server) = service(&broker).await;
    let account = content(0, &[("b", 20), ("c", 5), ("d", 15)]);

    service
        .report_live_activity("default", content(1, &[("a", 10)]))
        .await;
    service
        .report_live_activity("account", account.clone())
        .await;
    service.report_live_activity("account", account).await;
    service
        .report_live_activity("default", content(0, &[]))
        .await;
    service
        .report_live_activity("account", content(0, &[]))
        .await;

    assert_eq!(
        sent(&broker),
        vec![
            (json!("update"), json!(1), vec![json!("a")]),
            (
                json!("update"),
                json!(4),
                vec![json!("b"), json!("d"), json!("a")]
            ),
            (
                json!("update"),
                json!(3),
                vec![json!("b"), json!("d"), json!("c")]
            ),
            (json!("end"), json!(0), vec![]),
        ]
    );
    server.abort();
}

#[tokio::test]
async fn a_new_activity_token_receives_the_current_content_once() {
    let broker = MockBroker::new(Duration::ZERO, Vec::new());
    let (service, server) = service(&broker).await;
    service
        .report_live_activity("default", content(1, &[]))
        .await;
    service
        .report_live_activity("default", content(1, &[]))
        .await;
    assert_eq!(broker.requests().len(), 1);

    service
        .devices()
        .register(device(2, "AAAAAAAA-0000-0000-0000-000000000001"))
        .await
        .unwrap();
    service
        .report_live_activity("default", content(1, &[]))
        .await;
    service
        .report_live_activity("default", content(1, &[]))
        .await;

    assert_eq!(broker.requests().len(), 2);
    server.abort();
}

#[tokio::test]
async fn a_token_registered_after_the_end_is_ended_too() {
    let broker = MockBroker::new(Duration::ZERO, Vec::new());
    let (service, server) = service(&broker).await;
    service
        .report_live_activity("default", content(1, &[]))
        .await;
    service
        .report_live_activity("default", content(0, &[]))
        .await;
    service
        .devices()
        .register(device(2, "AAAAAAAA-0000-0000-0000-000000000001"))
        .await
        .unwrap();
    service
        .report_live_activity("default", content(0, &[]))
        .await;

    let events: Vec<Value> = broker
        .requests()
        .iter()
        .map(|request| request["event"].clone())
        .collect();
    assert_eq!(events, vec![json!("update"), json!("end"), json!("end")]);
    server.abort();
}

#[tokio::test]
async fn reported_content_survives_a_restart() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("live-activity.json");
    let service = |path: &std::path::Path| {
        PushService::new(
            false,
            Journal::disabled(),
            Arc::new(DeviceRegistry::temporary()),
            Some(path.to_owned()),
        )
    };
    service(&path)
        .report_live_activity("account", content(0, &[("b", 20)]))
        .await;

    let restarted = service(&path);
    assert_eq!(
        restarted.live_activity.lock().await.merged().unwrap(),
        content(0, &[("b", 20)])
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
fn an_attention_row_uses_the_widget_keys_and_omits_an_unknown_account() {
    let mut row = AttentionRow {
        thread_id: "thread-1".into(),
        account_id: None,
        title: Some("Title".into()),
        reason: AttentionReason::Question { completed_at: None },
    };
    assert_eq!(
        serde_json::to_value(&row).unwrap(),
        json!({"threadID": "thread-1", "title": "Title", "reason": "question"})
    );

    row.account_id = Some("81c84f21-818e-4af5-9b5f-7413a3ea4fde".into());
    row.reason = AttentionReason::FinishedUnread { completed_at: 20 };
    assert_eq!(
        serde_json::to_value(&row).unwrap(),
        json!({
            "threadID": "thread-1",
            "accountID": "81c84f21-818e-4af5-9b5f-7413a3ea4fde",
            "title": "Title",
            "reason": "finishedUnread",
            "completedAtUnixSeconds": 20,
        })
    );
}

#[tokio::test]
async fn live_activity_clients_receive_the_same_attention_only_host_projection_as_pushes() {
    let service = PushService::fixture_disabled(Journal::disabled());
    let updates = service.live_activity_updates();
    assert!(updates.borrow().is_none());
    service
        .report_live_activity("default", content(0, &[("done", 10)]))
        .await;
    let first = updates.borrow().clone().unwrap();
    assert_eq!(first.content, content(0, &[("done", 10)]));
    service
        .report_live_activity("account", content(2, &[("other", 20)]))
        .await;
    let next = updates.borrow().clone().unwrap();
    assert_eq!(next.epoch, first.epoch);
    assert!(next.revision > first.revision);
    assert_eq!(next.content.active_task_count, 2);
    assert_eq!(next.content.attention_count, 2);
    assert_eq!(next.content.attention[0].thread_id, "other");
    assert_eq!(next.content.attention[1].thread_id, "done");
}

#[tokio::test]
async fn review_regression_an_attention_host_always_outranks_a_running_only_host() {
    let mut broker = MockBroker::new(Duration::ZERO, vec![]);
    Arc::get_mut(&mut broker).unwrap().relevance = true;
    let (service, server) = service(&broker).await;
    service
        .report_live_activity("default", content(4, &[]))
        .await;
    service
        .report_live_activity(
            "default",
            LiveActivityContent {
                active_task_count: 2,
                attention: vec![AttentionRow {
                    thread_id: "asking".into(),
                    account_id: None,
                    title: None,
                    reason: AttentionReason::Question {
                        completed_at: Some(20),
                    },
                }],
                attention_count: 1,
            },
        )
        .await;
    let requests = broker.requests();
    assert_eq!(requests[0]["relevance_score"], 25);
    assert_eq!(requests[1]["relevance_score"], 100);
    server.abort();
}

#[test]
fn attention_rows_are_newest_completion_first_whatever_their_marker() {
    let row = |thread: &str, reason| AttentionRow {
        thread_id: thread.into(),
        account_id: None,
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
async fn review_regression_unreadable_aggregate_is_never_replaced_by_an_empty_map() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("live-activity.json");
    let bytes = b"{unfinished";
    std::fs::write(&path, bytes).unwrap();
    let service = PushService::new(
        false,
        Journal::disabled(),
        Arc::new(DeviceRegistry::temporary()),
        Some(path.clone()),
    );
    service
        .report_live_activity("default", content(2, &[]))
        .await;
    assert!(service.live_activity_updates().borrow().is_none());
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
}

#[tokio::test]
async fn restored_scopes_wait_for_fresh_authoritative_projections() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("live-activity.json");
    let make = || {
        PushService::new(
            false,
            Journal::disabled(),
            Arc::new(DeviceRegistry::temporary()),
            Some(path.clone()),
        )
    };
    let original = make();
    original
        .reconcile_live_activity_scopes(&std::collections::BTreeSet::from([
            "default".into(),
            "account".into(),
        ]))
        .await;
    original
        .report_live_activity("default", content(0, &[("old-default", 10)]))
        .await;
    original
        .report_live_activity("account", content(0, &[("old-account", 20)]))
        .await;
    let restarted = make();
    restarted
        .reconcile_live_activity_scopes(&std::collections::BTreeSet::from([
            "default".into(),
            "account".into(),
        ]))
        .await;
    restarted
        .report_live_activity("default", content(0, &[("fresh-default", 30)]))
        .await;
    assert!(restarted.live_activity_updates().borrow().is_none());
    restarted
        .report_live_activity("account", content(0, &[("fresh-account", 40)]))
        .await;
    let snapshot = restarted.live_activity_updates().borrow().clone().unwrap();
    assert_eq!(
        snapshot
            .content
            .attention
            .iter()
            .map(|row| row.thread_id.as_str())
            .collect::<Vec<_>>(),
        vec!["fresh-account", "fresh-default"]
    );
    restarted
        .reconcile_live_activity_scopes(&std::collections::BTreeSet::from(["default".into()]))
        .await;
    assert_eq!(
        make().live_activity.lock().await.merged().unwrap(),
        content(0, &[("fresh-default", 30)])
    );
}

#[tokio::test]
async fn a_rejected_activity_token_stays_eligible_after_the_client_registers_it_again() {
    let rejected = fixture_registration_json(1)["tokens"]["liveActivity"]
        .as_str()
        .unwrap()
        .to_owned();
    let broker = MockBroker::new(Duration::ZERO, vec![rejected]);
    let (service, server) = service(&broker).await;
    service
        .report_live_activity("default", content(1, &[]))
        .await;
    service
        .devices()
        .register(crate::devices::fixture_registration(1))
        .await
        .unwrap();
    service
        .report_live_activity("default", content(1, &[]))
        .await;
    assert_eq!(broker.requests().len(), 2);
    server.abort();
}

#[tokio::test]
async fn an_unavailable_scope_blocks_delivery_until_its_fresh_projection_returns() {
    let broker = MockBroker::new(Duration::ZERO, Vec::new());
    let (service, server) = service(&broker).await;
    service
        .report_live_activity("default", content(1, &[]))
        .await;
    let first_revision = service
        .live_activity_updates()
        .borrow()
        .as_ref()
        .unwrap()
        .revision;
    service
        .report_live_activity("account", content(0, &[]))
        .await;
    service
        .mark_live_activity_unavailable_if_current("account", || true)
        .await;
    service
        .report_live_activity("default", content(0, &[]))
        .await;
    assert!(service.live_activity_updates().borrow().is_none());
    assert_eq!(broker.requests().len(), 1);
    service
        .report_live_activity("account", content(1, &[]))
        .await;
    assert!(
        service
            .live_activity_updates()
            .borrow()
            .as_ref()
            .unwrap()
            .revision
            > first_revision
    );
    service
        .report_live_activity("account", content(0, &[]))
        .await;
    assert_eq!(
        sent(&broker)
            .iter()
            .map(|(event, _, _)| event.clone())
            .collect::<Vec<_>>(),
        vec![json!("update"), json!("update"), json!("end")]
    );
    server.abort();
}

#[tokio::test]
async fn review_followup_required_account_absent_from_saved_content_blocks_end() {
    let broker = MockBroker::new(Duration::ZERO, vec![]);
    let (service, server) = service(&broker).await;
    service
        .report_live_activity("default", content(1, &[]))
        .await;
    service
        .reconcile_live_activity_scopes(&std::collections::BTreeSet::from([
            "default".into(),
            "account".into(),
        ]))
        .await;
    service
        .report_live_activity("default", LiveActivityContent::default())
        .await;
    let unavailable = service.live_activity_updates().borrow().is_none();
    let before_account = broker.requests();
    service
        .report_live_activity("account", content(1, &[]))
        .await;
    let snapshot = service.live_activity_updates().borrow().clone();
    server.abort();
    assert!(unavailable, "{before_account:?}");
    assert!(
        before_account
            .iter()
            .all(|request| request["event"] != "end")
    );
    assert_eq!(snapshot.unwrap().content.active_task_count, 1);
}

#[tokio::test]
async fn review_followup_an_unverified_registry_cannot_certify_an_empty_host() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("live-activity.json");
    let mut service = PushService::new(
        false,
        Journal::disabled(),
        Arc::new(DeviceRegistry::temporary()),
        Some(path),
    );
    let broker = MockBroker::new(Duration::ZERO, Vec::new());
    let app = Router::new()
        .route("/v1/internal/live-activity", post(record))
        .with_state(broker.clone());
    let (address, server) = crate::test_support::serve(app).await;
    service.broker = Some(PushBroker::new(
        format!("http://{address}"),
        "fixture".into(),
    ));
    service
        .devices()
        .register(crate::devices::fixture_registration(1))
        .await
        .unwrap();
    service
        .report_live_activity("default", LiveActivityContent::default())
        .await;
    assert!(service.live_activity_updates().borrow().is_none());
    assert!(broker.requests().is_empty());
    server.abort();
}
