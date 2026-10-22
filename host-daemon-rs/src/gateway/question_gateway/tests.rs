use std::sync::atomic::AtomicBool;

use tokio::sync::Notify;
use tokio::task::JoinHandle;

use super::*;
use crate::gateway::tests::CONTROL;
use crate::providers::codex::daemon::CodexAppServer;
use crate::questions::Resolution;

struct Provider {
    entries: Mutex<Vec<Value>>,
    frozen: Mutex<HashMap<String, Vec<Value>>>,
    calls: Mutex<Vec<String>>,
    changed: Notify,
    active: AtomicBool,
    loaded: AtomicBool,
    paused: AtomicBool,
    resumed: Notify,
}

impl Provider {
    fn incident() -> Arc<Self> {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../protocol-fixtures/questions/answered-outside-viewport.json"
        ))
        .unwrap();
        Arc::new(Self {
            entries: Mutex::new(fixture["canonicalItems"].as_array().unwrap().clone()),
            frozen: Mutex::new(HashMap::new()),
            calls: Mutex::new(Vec::new()),
            changed: Notify::new(),
            active: AtomicBool::new(true),
            loaded: AtomicBool::new(true),
            paused: AtomicBool::new(false),
            resumed: Notify::new(),
        })
    }

    async fn wait_for_call(&self, method: &str) {
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let notified = self.changed.notified();
                if self.calls.lock().await.iter().any(|call| call == method) {
                    break;
                }
                notified.await;
            }
        })
        .await
        .unwrap();
    }
}

async fn gateway(
    root: &std::path::Path,
    provider: Arc<Provider>,
) -> (crate::test_support::TestGateway, JoinHandle<()>) {
    let gateway = crate::test_support::TestGateway::with_codex(
        Arc::new(CodexAppServer::new("/bin/true".into(), HashMap::new())),
        Some(root.join("turn-state.json")),
    );
    let responder = respond(&gateway, provider).await;
    (gateway, responder)
}

async fn respond(gateway: &Arc<Gateway>, provider: Arc<Provider>) -> JoinHandle<()> {
    let mut control = crate::test_support::FakeControl::attach(gateway, 32).await;
    let weak = Arc::downgrade(gateway);
    tokio::spawn(async move {
        while let Some(raw) = control.requests.recv().await {
            let request: Value = serde_json::from_str(&raw).unwrap();
            let method = request["method"].as_str().unwrap();
            provider.calls.lock().await.push(method.into());
            provider.changed.notify_waiters();
            if provider.paused.load(Ordering::Acquire) {
                provider.resumed.notified().await;
            }
            let result = match method {
                "thread/subscribe" => {
                    let data = provider.entries.lock().await.clone();
                    let mut frozen = provider.frozen.lock().await;
                    let token = format!("boundary-{}", frozen.len());
                    frozen.insert(token.clone(), data);
                    json!({"status":"subscribed","subscriptionId":provider.loaded.load(Ordering::Acquire).then(||format!("sub-{token}")),"checkpoint":{
                        "itemsBackwardsCursor":format!("{token}/0"),"activeTurn": if provider.active.load(Ordering::Acquire) {json!({"id":"turn"})} else {Value::Null},
                        "liveItems":[],"historyUnavailable":false}})
                }
                "thread/items/list" => {
                    let cursor = request["params"]["cursor"].as_str().unwrap();
                    let (token, offset) = cursor.split_once('/').unwrap();
                    let offset: usize = offset.parse().unwrap();
                    let frozen = provider.frozen.lock().await;
                    let mut data = frozen[token].clone();
                    data.sort_by_key(|entry| {
                        std::cmp::Reverse(entry["startedAtOrdinal"].as_i64().unwrap())
                    });
                    let end = (offset + 50).min(data.len());
                    json!({"data":data[offset..end],"nextCursor":(end < data.len()).then(||format!("{token}/{end}")),"backwardsCursor":Value::Null})
                }
                "thread/read" => {
                    json!({"thread":{"id":"thread","name":"Pending question","source":"cli"}})
                }
                "thread/subscription/close" => json!({}),
                _ => panic!("Question observation must never execute {method}"),
            };
            let Some(gateway) = weak.upgrade() else {
                break;
            };
            gateway
                .handle_control_text(
                    json!({"id":request["id"],"result":result}).to_string(),
                    CONTROL,
                )
                .await;
        }
    })
}

async fn ready(receiver: &mut watch::Receiver<Option<Snapshot>>) -> Snapshot {
    tokio::time::timeout(
        Duration::from_secs(30),
        receiver.wait_for(|value| {
            value
                .as_ref()
                .is_some_and(|snapshot| snapshot.coverage == Coverage::Ready)
        }),
    )
    .await
    .unwrap()
    .unwrap()
    .clone()
    .unwrap()
}

#[tokio::test]
async fn fresh_client_reads_answer_outside_viewport_without_execution_ownership() {
    let root = tempfile::tempdir().unwrap();
    let provider = Provider::incident();
    let (gateway, responder) = gateway(root.path(), Arc::clone(&provider)).await;
    let mut receiver = gateway
        .ensure_question_watch("thread", Some(1))
        .await
        .unwrap();
    let snapshot = ready(&mut receiver).await;
    assert_eq!(snapshot.pending_item_ids, Some(Vec::new()));
    assert_eq!(
        snapshot.records[0].questions[0].resolution,
        Resolution::Answered
    );
    assert_eq!(
        snapshot.records[0].questions[0]
            .answer
            .as_ref()
            .unwrap()
            .text,
        "External"
    );
    assert_eq!(
        provider
            .calls
            .lock()
            .await
            .iter()
            .filter(|method| *method == "thread/items/list")
            .count(),
        2
    );
    let selected = snapshot
        .clone()
        .select(&["call_question".into(), "absent".into()]);
    assert_eq!(selected.records.len(), 1);
    assert_eq!(selected.missing_item_ids, ["absent"]);
    assert_eq!(snapshot.clone().select(&[]).records.len(), 0);

    gateway.handle_control_text(json!({"method":"turn/started","params":{"threadId":"thread","turn":{"id":"turn","status":"inProgress"}}}).to_string(), CONTROL).await;
    assert_eq!(gateway.core.lock().await.turns.active_count(), 0);
    assert_eq!(gateway.core.lock().await.turns.context_count(), 0);
    assert!(gateway.core.lock().await.recovered_turn_keys.is_empty());
    let _second = gateway
        .ensure_question_watch("thread", Some(2))
        .await
        .unwrap();
    assert_eq!(
        provider
            .calls
            .lock()
            .await
            .iter()
            .filter(|method| *method == "thread/subscribe")
            .count(),
        1
    );
    gateway.questions.stop().await;
    provider.wait_for_call("thread/subscription/close").await;
    assert!(gateway.control_requests.lock().unwrap().is_empty());
    responder.abort();
    let _ = responder.await;
}

fn question_entry(id: &str, ordinal: i64) -> Value {
    json!({"turnId":"turn","startedAtOrdinal":ordinal,"isComplete":true,"startedAtMs":null,"completedAtMs":null,
        "item":{"id":id,"type":"agentMessage","delivery":"async","phase":"final_answer","text":"Next?",
            "questions":[{"title":"Next?","options":["A","B"]}]}})
}

#[tokio::test]
async fn canonical_notifications_update_all_readers_and_turn_completion_keeps_pending_questions() {
    let root = tempfile::tempdir().unwrap();
    let provider = Provider::incident();
    let (gateway, responder) = gateway(root.path(), Arc::clone(&provider)).await;
    let mut first = gateway
        .ensure_question_watch("thread", Some(1))
        .await
        .unwrap();
    let initial = ready(&mut first).await;
    let mut second = gateway
        .ensure_question_watch("thread", Some(2))
        .await
        .unwrap();
    let entry = question_entry("next-question", 1500);
    provider.entries.lock().await.push(entry.clone());
    gateway
        .handle_control_text(
            json!({"method":"item/completed","params":{
        "threadId":"thread","turnId":"turn","item":entry["item"],"startedAtOrdinal":1500}})
            .to_string(),
            CONTROL,
        )
        .await;
    let latest = tokio::time::timeout(
        Duration::from_secs(30),
        first.wait_for(|value| {
            value
                .as_ref()
                .is_some_and(|value| value.revision > initial.revision)
        }),
    )
    .await
    .unwrap()
    .unwrap()
    .clone()
    .unwrap();
    assert_eq!(latest.pending_item_ids, Some(vec!["next-question".into()]));
    assert_eq!(ready(&mut second).await, latest);
    let request = DismissRequest {
        expected_epoch: latest.epoch.clone(),
        thread_id: "thread".into(),
        item_id: "next-question".into(),
        expected_record_revision: latest
            .records
            .iter()
            .find(|record| record.item_id == "next-question")
            .unwrap()
            .revision,
        mutation_id: "dismiss-next".into(),
    };
    let reply = gateway.dismiss_question(request).await.unwrap();
    assert_eq!(reply["record"]["questions"][0]["resolution"], "dismissed");
    assert_eq!(ready(&mut second).await.pending_item_ids, Some(vec![]));

    let entry = question_entry("still-pending", 1600);
    provider.entries.lock().await.push(entry.clone());
    gateway
        .handle_control_text(
            json!({"method":"item/completed","params":{
        "threadId":"thread","turnId":"turn","item":entry["item"],"startedAtOrdinal":1600}})
            .to_string(),
            CONTROL,
        )
        .await;
    tokio::time::timeout(
        Duration::from_secs(30),
        first.wait_for(|value| {
            value.as_ref().is_some_and(|value| {
                value
                    .pending_item_ids
                    .as_ref()
                    .is_some_and(|ids| ids.contains(&"still-pending".into()))
            })
        }),
    )
    .await
    .unwrap()
    .unwrap();
    gateway.questions.client_closed(1).await;
    gateway.questions.client_closed(2).await;
    gateway.handle_control_text(json!({"method":"turn/completed","params":{"threadId":"thread","turnId":"turn","turn":{"id":"turn","status":"completed"}}}).to_string(), CONTROL).await;
    provider.wait_for_call("thread/subscription/close").await;
    let persisted = gateway.questions.store.read("thread").await.unwrap();
    assert!(
        persisted
            .records()
            .iter()
            .find(|record| record.item_id == "still-pending")
            .unwrap()
            .is_pending()
    );
    assert_eq!(gateway.core.lock().await.turns.active_count(), 0);
    gateway.questions.stop().await;
    responder.abort();
    let _ = responder.await;
}

#[tokio::test]
async fn replacement_history_changes_epoch_instead_of_merging_old_answers() {
    let root = tempfile::tempdir().unwrap();
    let provider = Provider::incident();
    let (first_gateway, first_responder) = gateway(root.path(), Arc::clone(&provider)).await;
    let mut receiver = first_gateway
        .ensure_question_watch("thread", Some(1))
        .await
        .unwrap();
    let first = ready(&mut receiver).await;
    first_gateway.questions.stop().await;
    first_responder.abort();
    let _ = first_responder.await;
    *provider.entries.lock().await = vec![question_entry("replacement-question", 30)];
    provider.active.store(false, Ordering::Release);
    let (second_gateway, second_responder) = gateway(root.path(), Arc::clone(&provider)).await;
    let mut receiver = second_gateway
        .ensure_question_watch("thread", Some(2))
        .await
        .unwrap();
    let second = ready(&mut receiver).await;
    assert_ne!(second.epoch, first.epoch);
    assert_eq!(second.records.len(), 1);
    assert_eq!(
        second.pending_item_ids,
        Some(vec!["replacement-question".into()])
    );
    second_gateway.questions.stop().await;
    second_responder.abort();
    let _ = second_responder.await;
}

#[tokio::test]
async fn cancelled_control_read_releases_its_reply_registration() {
    let root = tempfile::tempdir().unwrap();
    let gateway = crate::test_support::TestGateway::with_codex(
        Arc::new(CodexAppServer::new("/bin/true".into(), HashMap::new())),
        Some(root.path().join("turn-state.json")),
    );
    let mut receiver = crate::test_support::FakeControl::attach(&gateway, 1)
        .await
        .requests;
    let task = tokio::spawn({
        let gateway = Arc::clone(&gateway);
        async move { gateway.call_control("thread/items/list", json!({})).await }
    });
    receiver.recv().await.unwrap();
    assert_eq!(gateway.control_requests.lock().unwrap().len(), 1);
    task.abort();
    let _ = task.await;
    assert!(gateway.control_requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn unloaded_question_reads_reuse_verified_state_and_invalidate_on_changes() {
    let root = tempfile::tempdir().unwrap();
    let provider = Provider::incident();
    provider.active.store(false, Ordering::Release);
    provider.loaded.store(false, Ordering::Release);
    let (gateway, responder) = gateway(root.path(), Arc::clone(&provider)).await;
    let mut receiver = gateway
        .ensure_question_watch("thread", Some(1))
        .await
        .unwrap();
    let initial = ready(&mut receiver).await;
    wait_for_quiescent_watch(&gateway).await;
    for _ in 0..32 {
        let mut reader = gateway
            .ensure_question_watch("thread", Some(1))
            .await
            .unwrap();
        assert_eq!(ready(&mut reader).await, initial);
    }
    assert_eq!(
        provider
            .calls
            .lock()
            .await
            .iter()
            .filter(|method| *method == "thread/subscribe")
            .count(),
        1
    );
    gateway
        .questions
        .entries
        .lock()
        .await
        .get_mut("thread")
        .unwrap()
        .verified_at = Some(Instant::now() - QUIESCENT_SNAPSHOT_MAX_AGE);
    let mut expired = gateway
        .ensure_question_watch("thread", Some(1))
        .await
        .unwrap();
    let refreshed = ready(&mut expired).await;
    assert!(refreshed.revision > initial.revision);
    wait_for_quiescent_watch(&gateway).await;
    provider
        .entries
        .lock()
        .await
        .push(question_entry("new-question", 1500));
    gateway
        .questions
        .ingest(&json!({"method":"thread/reverted","params":{"threadId":"thread"}}))
        .await;
    let mut invalidated = gateway
        .ensure_question_watch("thread", Some(1))
        .await
        .unwrap();
    assert_eq!(
        ready(&mut invalidated).await.pending_item_ids,
        Some(vec!["new-question".into()])
    );
    gateway.questions.stop().await;
    responder.abort();
    let _ = responder.await;
}

async fn wait_for_quiescent_watch(gateway: &Gateway) {
    tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            if gateway
                .questions
                .entries
                .lock()
                .await
                .get("thread")
                .unwrap()
                .sender
                .is_none()
            {
                return;
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn a_watched_question_marks_its_unread_row_until_its_coverage_is_lost() {
    let settings = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let root = tempfile::tempdir().unwrap();
    let probe = crate::test_support::LiveActivityProbe::new(None).await;
    let gateway = Gateway::construct_with_apns(
        super::super::GatewayConstruction {
            user_name: None,
            codex: Arc::new(CodexAppServer::new("/bin/true".into(), HashMap::new())),
            claude_settings: settings.settings.clone(),
            journal: crate::observability::journal::Journal::disabled(),
            turn_state_path: Some(root.path().join("turn-state.json")),
            recovery_path: None,
            call_delivery: None,

            external_auth: None,
        },
        probe.service.clone(),
    );
    let later = unix_seconds() as i64 + 100;
    let mut asked = question_entry("pending", 2000);
    asked["startedAtMs"] = json!((later + 1) * 1000);
    let provider = Provider::incident();
    provider.entries.lock().await.push(asked);
    let responder = respond(&gateway, provider).await;
    let mut questions = gateway
        .ensure_question_watch("thread", Some(1))
        .await
        .unwrap();
    ready(&mut questions).await;
    gateway.core.lock().await.finished_turns.record(
        "thread",
        super::super::live_activity::FinishedTurn {
            turn_id: "turn".into(),
            started_at: later,
            completed_at: later + 2,
        },
    );
    gateway.agents.parents.lock().await.insert(
        "thread".into(),
        super::super::agent_gateway::ParentSnapshot {
            at: Instant::now(),
            parent: None,
            available: true,
        },
    );
    let lead = |snapshot: &Option<crate::push::LiveActivitySnapshot>| {
        snapshot
            .as_ref()
            .and_then(|snapshot| snapshot.content.attention.first())
            .map(|row| row.reason)
    };
    let mut updates = probe.service.live_activity_updates();
    gateway.start_live_activity().await;
    let marked = tokio::time::timeout(
        Duration::from_secs(30),
        updates.wait_for(|snapshot| {
            matches!(
                lead(snapshot),
                Some(crate::push::AttentionReason::Question { .. })
            )
        }),
    )
    .await
    .is_ok();
    let mut unavailable = questions.borrow().clone().unwrap();
    unavailable.coverage = Coverage::Unavailable;
    unavailable.pending_item_ids = None;
    gateway.questions.disconnected().await;
    gateway.publish_questions("thread", None, unavailable).await;
    let unmarked = tokio::time::timeout(
        Duration::from_secs(30),
        updates.wait_for(|snapshot| {
            matches!(
                lead(snapshot),
                Some(crate::push::AttentionReason::FinishedUnread { .. })
            )
        }),
    )
    .await
    .is_ok();
    let current = updates.borrow().clone();
    let requests = probe.requests.lock().unwrap().clone();
    let task = gateway.apns_live_activity_task.lock().await.take();
    if let Some(task) = task {
        task.abort();
    }
    gateway.questions.stop().await;
    responder.abort();
    assert!(marked, "{requests:?}");
    assert!(unmarked, "{requests:?}");
    assert_eq!(current.unwrap().content.attention_count, 1);
    assert!(
        requests.iter().all(|request| request["event"] != "end"),
        "{requests:?}"
    );
}
