use super::judge::{DECISIONS, decision_request};
use super::titles::valid_title;
use super::*;
use crate::conversation_marks::{Change, Purpose};
use crate::notifications::history::NotificationOrigin;
use crate::test_support::{FakeControl, TestGateway};
use axum::{Json, Router, routing::post};
use std::fs::OpenOptions;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::atomic::AtomicU64;
use std::time::Duration;

fn user(text: &str) -> Value {
    json!({"type":"userMessage","content":[{"type":"text","text":text}]})
}
fn turn(id: &str, text: &str) -> Value {
    json!({"id":id,"status":"completed","completedAt":1234,"items":[user(text),
        {"type":"agentMessage","text":"Implemented and tested."},
        {"type":"commandExecution","aggregatedOutput":"SECRET TOOL OUTPUT"}]})
}

#[test]
fn context_keeps_full_dialogue_and_compacts_tools() {
    let turns = [
        turn("initial", "Fix automatic conversation naming"),
        turn("middle", "Include every user correction"),
        turn("latest", &"x".repeat(20_000)),
    ];
    let messages = turns
        .iter()
        .flat_map(|turn| turn["items"].as_array().unwrap())
        .filter_map(conversation_message)
        .collect::<Vec<_>>();
    assert_eq!(messages[0]["text"], "Fix automatic conversation naming");
    assert_eq!(messages[3]["text"], "Include every user correction");
    assert_eq!(messages[6]["text"].as_str().unwrap().len(), 20_000);
    assert_eq!(messages[2]["role"], "tool");
    assert!(
        !serde_json::to_string(&messages)
            .unwrap()
            .contains("SECRET TOOL OUTPUT")
    );
}

#[test]
fn context_only_trims_the_middle_when_needed_and_preserves_unicode_bookends() {
    let original = (0..100)
        .map(|i| json!({"role":"user","text":format!("message {i}: {}", "é🙂".repeat(80))}))
        .collect::<Vec<_>>();
    let mut messages = original.clone();
    assert!(!trim_middle(&mut messages, MAX_CONTEXT_BYTES).unwrap());
    assert_eq!(messages, original);
    assert!(trim_middle(&mut messages, 8 * 1024).unwrap());
    assert_eq!(messages.first(), original.first());
    assert_eq!(messages.last(), original.last());
    assert!(messages.len() < original.len());
    assert!(messages.iter().all(|message| original.contains(message)));
    assert!(serde_json::to_vec(&messages).unwrap().len() <= 8 * 1024 + 2);

    // A bookend may use more than half the budget without being sliced.
    let first = json!({"role":"user","text":"x".repeat(6000)});
    let last = json!({"role":"assistant","text":"Latest answer"});
    let mut uneven = vec![
        first.clone(),
        json!({"role":"user","text":"y".repeat(6000)}),
        last.clone(),
    ];
    assert!(trim_middle(&mut uneven, 8 * 1024).unwrap());
    assert_eq!(uneven, [first, last]);

    let mut oversized =
        vec![json!({"role":"user","text":format!("INITIAL {} LATEST", "é🙂".repeat(100_000))})];
    assert!(trim_middle(&mut oversized, MAX_CONTEXT_BYTES).unwrap());
    let text = oversized[0]["text"].as_str().unwrap();
    assert!(text.starts_with("INITIAL "));
    assert!(text.ends_with(" LATEST"));
    assert!(text.contains("message middle omitted"));
    assert!(serde_json::to_vec(&oversized).unwrap().len() <= MAX_CONTEXT_BYTES);
}

#[test]
fn review_budget_oversized_dialogue_keeps_bookends_within_the_available_budget() {
    let mut messages = vec![
        json!({"role":"user","text":format!("INITIAL {} LATEST", "x".repeat(40 * 1024 * 1024))}),
    ];
    assert!(trim_middle(&mut messages, MAX_CONTEXT_BYTES).unwrap());
    let bytes = serde_json::to_vec(&messages[0]).unwrap().len() + 1;
    assert!(bytes <= MAX_CONTEXT_BYTES);
    assert!(
        bytes >= MAX_CONTEXT_BYTES - 1024,
        "oversized bookends were over-trimmed despite available budget"
    );
    let text = messages[0]["text"].as_str().unwrap();
    assert!(text.starts_with("INITIAL "));
    assert!(text.ends_with(" LATEST"));
    assert!(text.contains("message middle omitted"));
}

fn judge_api(address: std::net::SocketAddr, key: &str) -> JudgeApi {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("router-key");
    std::fs::write(&path, key).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    JudgeApi::new(&RouterConfig::local_for_test(address, path)).unwrap()
}

async fn api_fixture(
    key: &str,
    decision: Value,
) -> (
    JudgeApi,
    tokio::task::JoinHandle<()>,
    tokio::sync::mpsc::Receiver<Value>,
) {
    let (tx, rx) = tokio::sync::mpsc::channel(8);
    let router = Router::new().route(
        DECISIONS,
        post(move |headers: axum::http::HeaderMap, Json(body): Json<Value>| {
            let tx = tx.clone();
            let response = decision.clone();
            async move {
                let _ = tx.send(json!({"authorization":headers["authorization"].to_str().unwrap(),"body":body})).await;
                Json(response)
            }
        }),
    );
    let (address, server) = crate::test_support::serve(router).await;
    (judge_api(address, key), server, rx)
}
fn decision(misleading: Value, vague: Value) -> Value {
    json!({"answers":{"misleading":{"type":"noul","noul":misleading},"vague":{"type":"noul","noul":vague},"unsuitable":{"type":"noul","noul":0.1},"done":{"type":"noul","noul":0.99}}})
}

async fn trace_records(journal: crate::observability::journal::Journal, dir: &Path) -> Vec<Value> {
    journal.drain(Duration::from_secs(5)).await;
    let mut files = std::fs::read_dir(dir)
        .unwrap()
        .map(|file| file.unwrap().path())
        .collect::<Vec<_>>();
    files.sort();
    files
        .into_iter()
        .flat_map(|path| {
            std::fs::read_to_string(path)
                .unwrap()
                .lines()
                .map(|line| serde_json::from_str::<Value>(line).unwrap())
                .collect::<Vec<_>>()
        })
        .filter(|record| record["kind"] == "review")
        .collect()
}

#[tokio::test]
async fn model_trace_preserves_frozen_input_and_outputs_and_redacts_the_echoed_router_key() {
    use crate::observability::journal::Journal;
    let directory = tempfile::tempdir().unwrap();
    let journal = Journal::open_in(directory.path().to_owned(), 30);
    let mut trace = Trace::new(
        journal.clone(),
        json!({"threadId":"thread","turnId":"turn"}),
    );
    let secret = "private-router-key";
    let state = json!({"title":"New chat","messages":[{"role":"user",
        "text":format!("Keep the whole input {} and {secret}", "x".repeat(80 * 1024))}]});
    let mut response = decision(json!(0.1), json!(0.1));
    response["id"] = json!("generation-123");
    response["model"] = json!("actual-model");
    response["usage"] = json!({"prompt_tokens":20000,"cost":0.001});
    response["debug"] = json!(secret);
    let (api, server, mut requests) = api_fixture(secret, response).await;
    assert!(
        !api.judge(
            &state,
            Questions {
                title: true,
                done: false
            },
            &trace
        )
        .await
        .unwrap()
        .title
        .unwrap()
        .unwrap()
    );
    assert_eq!(
        requests.recv().await.unwrap()["body"]["state"],
        state,
        "logging cannot alter the submitted model view"
    );
    trace.finish("kept", "judgeKeptTitle");
    let records = trace_records(journal, directory.path()).await;
    let request = records
        .iter()
        .find(|record| record["event"] == "request")
        .unwrap();
    let response = records
        .iter()
        .find(|record| record["event"] == "response")
        .unwrap();
    assert_eq!(request["requestId"], response["requestId"]);
    assert_eq!(
        request["body"]["questions"],
        decision_request(
            &state,
            Questions {
                title: true,
                done: false
            }
        )["questions"]
    );
    assert_eq!(
        request["body"]["state"]["messages"][0]["text"]
            .as_str()
            .unwrap(),
        state["messages"][0]["text"]
            .as_str()
            .unwrap()
            .replace(secret, "[redacted]")
    );
    assert_eq!(response["generationId"], "generation-123");
    assert_eq!(response["usage"]["cost"], 0.001);
    assert_eq!(response["status"], 200);
    assert_eq!(response["payloadComplete"], true);
    assert_eq!(records.last().unwrap()["outcome"], "kept");
    assert!(
        records
            .iter()
            .all(|record| record["traceId"] == records[0]["traceId"])
    );
    assert!(!serde_json::to_string(&records).unwrap().contains(secret));
    server.abort();
}

#[tokio::test]
async fn dropped_work_has_an_abandoned_outcome_instead_of_a_keep() {
    use crate::observability::journal::Journal;
    let directory = tempfile::tempdir().unwrap();
    let journal = Journal::open_in(directory.path().to_owned(), 30);
    let mut trace = Trace::new(journal.clone(), json!({"threadId":"thread"}));
    let tasks = OwnedTasks::default();
    let (ready, started) = tokio::sync::oneshot::channel();
    tasks.spawn("cancelled title check", async move {
        let request = trace.request_id();
        trace.event("request", json!({"requestId":request,"operation":"judge"}));
        ready.send(()).unwrap();
        std::future::pending::<()>().await;
        trace.finish("kept", "unexpectedCompletion");
        Ok(())
    });
    started.await.unwrap();
    tasks.stop().await;
    let records = trace_records(journal, directory.path()).await;
    assert_eq!(records.last().unwrap()["outcome"], "abandoned");
    assert_eq!(records.last().unwrap()["lastEvent"], "request");
    assert_eq!(
        records
            .iter()
            .filter(|record| record["event"] == "finished")
            .count(),
        1
    );
}

#[tokio::test]
async fn ineligible_completions_and_busy_capacity_are_traceable_without_model_calls() {
    let directory = tempfile::tempdir().unwrap();
    let logs = directory.path().join("title-logs");
    let journal = crate::observability::journal::Journal::open_in(logs.clone(), 30);
    let gateway = TestGateway::with_native_runtime_journal(directory.path(), journal.clone());
    let _permit = Arc::clone(&gateway.review.budget)
        .try_acquire_owned()
        .unwrap();
    for (turn, status) in [("failed", "failed"), ("busy", "completed")] {
        gateway.review.ingest(
            &json!({"method":"turn/completed","params":{
            "threadId":"thread","turn":{"id":turn,"status":status}}}),
            true,
        );
    }
    let records = trace_records(journal, &logs).await;
    let finished = records
        .iter()
        .filter(|record| record["event"] == "finished")
        .collect::<Vec<_>>();
    assert_eq!(finished.len(), 2);
    assert_eq!(finished[0]["reason"], "turnNotCompleted");
    assert_eq!(finished[1]["reason"], "hostBusy");
    assert!(finished.iter().all(|record| record["outcome"] == "skipped"));
    assert!(
        records
            .iter()
            .all(|record| record["accountId"] == crate::accounts::types::DEFAULT_CODEX)
    );
    assert!(
        records
            .iter()
            .all(|record| record.get("gateway").is_some() && record["policyVersion"] == 4)
    );
    assert!(!records.iter().any(|record| record["event"] == "request"));
}

#[tokio::test]
async fn router_requests_carry_the_host_key_and_the_judged_state() {
    let state =
        json!({"title":"New chat","messages":[{"role":"user","text":"Fix conversation naming"}]});
    let (api, server, mut requests) =
        api_fixture("router-key", decision(json!(0.1), json!(0.91))).await;
    assert!(
        api.judge(
            &state,
            Questions {
                title: true,
                done: false
            },
            &Trace::silent()
        )
        .await
        .unwrap()
        .title
        .unwrap()
        .unwrap()
    );
    let judge = requests.recv().await.unwrap();
    assert_eq!(judge["authorization"], "Bearer router-key");
    assert_eq!(judge["body"]["state"], state);
    assert_eq!(judge["body"]["model"], "typesafe/jev-1.13");
    server.abort();
}

#[tokio::test]
async fn only_context_limit_errors_retry_with_smaller_bookends() {
    use axum::http::StatusCode;
    let state = json!({"title":"New chat","messages":(0..100).map(|i| json!({
        "role":"user","text":format!("message {i}: {}", "x".repeat(1000))
    })).collect::<Vec<_>>()});
    for (status, error, expected_calls) in [
        (
            StatusCode::BAD_REQUEST,
            json!({"code":"context_length_exceeded"}),
            2,
        ),
        (
            StatusCode::BAD_REQUEST,
            json!({"code":400,"message":"HTTP 400: {\"detail\":{\"error_type\":\"max_tokens_exceeded\"}}"}),
            2,
        ),
        (
            StatusCode::TOO_MANY_REQUESTS,
            json!({"code":"rate_limit_exceeded","message":"private provider body"}),
            1,
        ),
    ] {
        let directory = tempfile::tempdir().unwrap();
        let journal =
            crate::observability::journal::Journal::open_in(directory.path().to_owned(), 30);
        let mut trace = Trace::new(journal.clone(), json!({"threadId":"thread"}));
        let (tx, mut requests) = tokio::sync::mpsc::channel(4);
        let calls = Arc::new(AtomicU64::new(0));
        let count = Arc::clone(&calls);
        let router = Router::new().route(
            DECISIONS,
            post(move |Json(body): Json<Value>| {
                let tx = tx.clone();
                let count = Arc::clone(&count);
                let error = error.clone();
                async move {
                    tx.send(body).await.unwrap();
                    if count.fetch_add(1, Ordering::AcqRel) == 0 {
                        (status, Json(json!({"error":error})))
                    } else {
                        (StatusCode::OK, Json(decision(json!(0.9), json!(0.1))))
                    }
                }
            }),
        );
        let (address, server) = crate::test_support::serve(router).await;
        let result = judge_api(address, "router-key")
            .judge(
                &state,
                Questions {
                    title: true,
                    done: false,
                },
                &trace,
            )
            .await;
        match &result {
            Ok(_) => trace.finish("skipped", "fixtureOnly"),
            Err(error) => trace.failed(error),
        }
        let records = trace_records(journal, directory.path()).await;
        let sent = records
            .iter()
            .filter(|record| record["event"] == "request")
            .collect::<Vec<_>>();
        let received = records
            .iter()
            .filter(|record| record["event"] == "response")
            .collect::<Vec<_>>();
        assert_eq!(sent.len(), expected_calls as usize);
        assert_eq!(received.len(), expected_calls as usize);
        for (request, response) in sent.iter().zip(&received) {
            assert_eq!(request["requestId"], response["requestId"]);
        }
        assert_eq!(
            records.iter().any(|record| record["event"] == "retry"),
            expected_calls == 2
        );
        if expected_calls == 1 {
            assert_eq!(records.last().unwrap()["outcome"], "failed");
        }
        assert_eq!(calls.load(Ordering::Acquire), expected_calls);
        assert_eq!(requests.recv().await.unwrap()["state"], state);
        if expected_calls == 2 {
            assert!(result.unwrap().title.unwrap().unwrap());
            let retry = requests.recv().await.unwrap();
            assert_eq!(retry["state"]["middleTruncated"], true);
            let messages = retry["state"]["messages"].as_array().unwrap();
            assert_eq!(messages.first().unwrap(), &state["messages"][0]);
            assert_eq!(messages.last().unwrap(), &state["messages"][99]);
            assert!(messages.len() < 100);
        } else {
            assert!(
                !result
                    .err()
                    .unwrap()
                    .to_string()
                    .contains("private provider body")
            );
        }
        server.abort();
    }
}

#[tokio::test]
async fn uncertain_or_invalid_decisions_and_invalid_titles_do_not_authorize_renaming() {
    for (answer, expected) in [
        (decision(json!(0.59), json!(0.2)), Some(false)),
        (decision(json!(0.60), json!(0.2)), Some(true)),
        (decision(json!(1.2), json!(0.1)), None),
        (decision(json!(0.9), Value::Null), None),
        (json!({"answers":{}}), None),
    ] {
        let (api, server, _) = api_fixture("router-key", answer).await;
        assert_eq!(
            api.judge(
                &json!({}),
                Questions {
                    title: true,
                    done: false
                },
                &Trace::silent()
            )
            .await
            .ok()
            .and_then(|decision| decision.title.unwrap().ok()),
            expected
        );
        server.abort();
    }
    for answer in ["", "  \"\"  ", "a\nb", "`title`", &"x".repeat(81)] {
        assert!(valid_title(answer).is_err(), "{answer:?}");
    }
    assert_eq!(
        valid_title(" \"Cache-aware conversation titles\"\n").unwrap(),
        "Cache-aware conversation titles"
    );
    assert_eq!(
        valid_title("“Cache-aware conversation titles”").unwrap(),
        "Cache-aware conversation titles"
    );
}

#[tokio::test]
async fn unsuitable_titles_and_code_measured_length_trigger_renaming_without_topic_drift() {
    let mut formatting = decision(json!(0.1), json!(0.1));
    formatting["answers"]["unsuitable"]["noul"] = json!(0.70);
    for (answer, state, expected) in [
        (
            formatting,
            json!({"title":"Hello, I had an idea for something we could do...","titleTooLong":false}),
            Some(true),
        ),
        (
            decision(json!(0.1), json!(0.1)),
            json!({"titleTooLong":true}),
            Some(true),
        ),
        (
            decision(json!(0.1), json!(0.1)),
            json!({"title":"Automatic chat titles with Jev","titleTooLong":false}),
            Some(false),
        ),
        (
            json!({"answers":{"misleading":{"type":"noul","noul":0.1},"vague":{"type":"noul","noul":0.1}}}),
            json!({"titleTooLong":true}),
            None,
        ),
    ] {
        let (api, server, _) = api_fixture("router-key", answer).await;
        assert_eq!(
            api.judge(
                &state,
                Questions {
                    title: true,
                    done: false
                },
                &Trace::silent()
            )
            .await
            .ok()
            .and_then(|decision| decision.title.unwrap().ok()),
            expected
        );
        server.abort();
    }
}

async fn fake_pages(
    gateway: TestGateway,
    title: &'static str,
    latest: Value,
) -> tokio::task::JoinHandle<()> {
    let mut control = FakeControl::attach(&gateway, 8).await;
    tokio::spawn(async move {
        while let Some(raw) = control.requests.recv().await {
            let request: Value = serde_json::from_str(&raw).unwrap();
            let result = match request["method"].as_str().unwrap() {
                "thread/read" => {
                    json!({"thread":{"id":"thread","name":title,"status":{"type":"idle"},"ephemeral":false}})
                }
                "thread/turns/list" => {
                    if request["params"]["sortDirection"] == "asc" {
                        json!({"data":[turn("first","Fix conversation naming")]})
                    } else {
                        json!({"data":[latest.clone()]})
                    }
                }
                "thread/items/list" => {
                    let turns = [
                        turn("first", "Fix conversation naming"),
                        turn("middle", "Keep user corrections"),
                        latest.clone(),
                    ];
                    let data = turns
                        .iter()
                        .flat_map(|turn| turn["items"].as_array().unwrap())
                        .map(|item| json!({"item":item}))
                        .collect::<Vec<_>>();
                    json!({"data":data,"nextCursor":null})
                }
                other => panic!("unexpected {other}"),
            };
            gateway
                .handle_control_text(
                    json!({"id":request["id"],"result":result}).to_string(),
                    NotificationOrigin::Control { opened_after: 0 },
                )
                .await;
        }
    })
}

#[tokio::test]
async fn codex_snapshot_rejects_a_newer_turn_and_preserves_initial_goal() {
    let gateway = TestGateway::new();
    let control = fake_pages(
        gateway.clone(),
        "Code help",
        turn("latest", "Run the tests"),
    )
    .await;
    assert!(
        gateway
            .review_snapshot("thread", "old", &Trace::silent())
            .await
            .unwrap()
            .is_none()
    );
    let snapshot = gateway
        .review_snapshot("thread", "latest", &Trace::silent())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(snapshot.title, "Code help");
    assert_eq!(snapshot.latest_user_goal.as_deref(), Some("Run the tests"));
    assert_eq!(snapshot.state["titleTooLong"], false);
    assert_eq!(
        snapshot.state["messages"][0]["text"],
        "Fix conversation naming"
    );
    assert_eq!(
        snapshot.state["messages"][3]["text"],
        "Keep user corrections"
    );
    assert_eq!(snapshot.state["messages"][6]["text"], "Run the tests");
    assert_eq!(snapshot.state["middleTruncated"], false);
    control.abort();
}

#[tokio::test]
async fn latest_user_goal_survives_trimming_and_image_only_input_stays_unknown() {
    let gateway = TestGateway::new();
    let goal = format!(
        "Repair the Mac mini Recovery boot files\n{}\nKeep the WD Black data intact",
        "x".repeat(128 * 1024)
    );
    let mut latest = turn("latest", &goal);
    latest["items"][1]["text"] = json!("y".repeat(512 * 1024));
    let control = fake_pages(gateway.clone(), "Old iOS topic", latest).await;
    let snapshot = gateway
        .review_snapshot("thread", "latest", &Trace::silent())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(snapshot.state["middleTruncated"], true);
    assert!(
        snapshot
            .latest_user_goal
            .as_ref()
            .unwrap()
            .starts_with("Repair the Mac mini Recovery boot files")
    );
    assert!(
        snapshot
            .latest_user_goal
            .as_ref()
            .unwrap()
            .ends_with("Keep the WD Black data intact")
    );
    assert!(snapshot.latest_user_goal.as_ref().unwrap().len() <= MAX_USER_GOAL_BYTES);
    assert!(
        snapshot.state["messages"]
            .as_array()
            .unwrap()
            .iter()
            .all(|message| message["text"].as_str() != Some(&goal))
    );
    control.abort();
    let mut latest = turn("latest", "");
    latest["items"][0] =
        json!({"type":"userMessage","content":[{"type":"image","url":"fixture-image"}]});
    let control = fake_pages(gateway.clone(), "Old iOS topic", latest).await;
    let snapshot = gateway
        .review_snapshot("thread", "latest", &Trace::silent())
        .await
        .unwrap()
        .unwrap();
    assert!(!titles::eligible(&snapshot));
    assert_eq!(snapshot.completed_at, Some(1234));
    control.abort();
}

#[tokio::test]
async fn conversation_pages_keep_middle_messages_despite_unrelated_activity() {
    for changed in [false, true] {
        let gateway = TestGateway::new();
        let mut control = FakeControl::attach(&gateway, 8).await;
        let control_gateway = gateway.clone();
        let task = tokio::spawn(async move {
            while let Some(raw) = control.requests.recv().await {
                let request: Value = serde_json::from_str(&raw).unwrap();
                assert_eq!(request["method"], "thread/items/list");
                assert_eq!(request["params"]["sortDirection"], "asc");
                let page = match request["params"]["cursor"].as_str() {
                    None => json!({"data":[{"item":user("Initial goal")}],"nextCursor":"middle"}),
                    Some("middle") => {
                        json!({"data":[{"item":user("Important user correction")}],"nextCursor":"end"})
                    }
                    Some("end") => {
                        if changed {
                            control_gateway.review.ingest(
                                &json!({"method":"turn/started","params":{"threadId":"other-thread"}}),
                                true,
                            );
                        }
                        json!({"data":[{"item":user("Latest task")}],"nextCursor":null})
                    }
                    other => panic!("unexpected cursor {other:?}"),
                };
                control_gateway
                    .handle_control_text(
                        json!({"id":request["id"],"result":page}).to_string(),
                        NotificationOrigin::Control { opened_after: 0 },
                    )
                    .await;
            }
        });
        let context = gateway.review_conversation("thread").await.unwrap();
        let context = context.unwrap();
        assert!(!context.middle_truncated);
        assert_eq!(context.latest_user_goal.as_deref(), Some("Latest task"));
        assert_eq!(
            context
                .messages
                .iter()
                .map(|message| message["text"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["Initial goal", "Important user correction", "Latest task"]
        );
        task.abort();
    }
}

#[tokio::test]
async fn pinned_names_and_automation_or_probe_threads_are_ineligible() {
    for change in [
        Change::Pin {
            thread_id: "thread".into(),
            name: "My title".into(),
        },
        Change::SetPurpose {
            thread_id: "thread".into(),
            purpose: Purpose::Automation,
        },
        Change::SetPurpose {
            thread_id: "thread".into(),
            purpose: Purpose::Probe,
        },
    ] {
        let directory = tempfile::tempdir().unwrap();
        let gateway = TestGateway::with_native_runtime(directory.path());
        assert!(gateway.review_exclusion("thread").await.unwrap().is_none());
        gateway.marks.update(vec![change], 1).await.unwrap();
        assert!(!gateway.review_exclusion("thread").await.unwrap().is_none());
    }
}

#[tokio::test]
async fn shutdown_releases_review_capacity() {
    let directory = tempfile::tempdir().unwrap();
    let gateway = TestGateway::with_native_runtime(directory.path());
    let permit = Arc::clone(&gateway.review.budget)
        .try_acquire_owned()
        .unwrap();
    gateway.review.tasks.spawn("test title", async move {
        let _permit = permit;
        std::future::pending::<()>().await;
        Ok(())
    });
    gateway.review.stop().await;
    assert!(
        Arc::clone(&gateway.review.budget)
            .try_acquire_owned()
            .is_ok()
    );
}

#[tokio::test]
async fn claude_snapshot_uses_native_projection_and_detects_new_user_activity() {
    let gateway = TestGateway::new();
    let session = "11111111-2222-4333-8444-555555555555";
    let thread = format!("claude_{session}");
    let root = gateway.claude_settings.claude_home.join("projects/test");
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join(format!("{session}.jsonl"));
    let records = [
        json!({"type":"user","uuid":"user-1","sessionId":session,"cwd":"/tmp","timestamp":"2026-10-02T10:00:00Z","message":{"role":"user","content":"Fix conversation naming"}}),
        json!({"type":"assistant","uuid":"assistant-1","sessionId":session,"timestamp":"2026-10-02T10:01:00Z","message":{"id":"msg-1","role":"assistant","content":[{"type":"text","text":"Implemented."}],"stop_reason":"end_turn"}}),
    ];
    std::fs::write(
        &path,
        records
            .iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\n")
            + "\n",
    )
    .unwrap();
    let page = gateway.review_turns(&thread, "desc", 1).await.unwrap();
    let turn_id = page["data"][0]["id"].as_str().unwrap();
    let snapshot = gateway
        .review_snapshot(&thread, turn_id, &Trace::silent())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        snapshot.state["messages"][0]["text"],
        "Fix conversation naming"
    );
    use std::io::Write;
    writeln!(OpenOptions::new().append(true).open(path).unwrap(),"{}",json!({"type":"user","uuid":"user-2","sessionId":session,"timestamp":"2026-10-02T10:02:00Z","message":{"role":"user","content":"A new task"}})).unwrap();
    assert!(
        gateway
            .review_snapshot(&thread, turn_id, &Trace::silent())
            .await
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn codex_rename_applies_only_when_title_turn_activity_and_pin_are_unchanged() {
    for change in [
        "none",
        "title",
        "turn",
        "active",
        "unrelated",
        "pin",
        "tool",
        "repair",
        "repairEcho",
        "repairGoal",
        "repairLong",
        "malformedDone",
        "doneWrite",
    ] {
        let rejected_title = if change == "repairLong" {
            "iOS 27 UI, Motion Design, Performance Optimization, SwiftUI Best Practices, and Application Architecture Guide"
        } else if change.starts_with("repair") {
            "iOS 27 UI, Motion Design, and Performance Optimization Guide"
        } else {
            "New chat"
        };
        let latest_goal = if change.starts_with("repair") {
            "Repair the Mac mini WD Black Recovery boot files"
        } else {
            "Fix automatic conversation names"
        };
        let repaired_title = if change.starts_with("repair") {
            "Repair Mac mini Recovery boot files"
        } else {
            "Automatic conversation titles"
        };
        let directory = tempfile::tempdir().unwrap();
        let logs = directory.path().join("title-logs");
        let journal = crate::observability::journal::Journal::open_in(logs.clone(), 30);
        let gateway = TestGateway::with_native_runtime_journal(directory.path(), journal.clone());
        let mut trace = gateway.review_trace("thread", "latest");
        let native = Arc::new(tokio::sync::Mutex::new(json!({
            "thread":{"id":"thread","name":rejected_title,"status":{"type":"idle"},"ephemeral":false,
                "model":"gpt-6.1-sol","reasoningEffort":"xhigh"},
            "latest":turn("latest",latest_goal)
        })));
        let (renames_tx, mut renames) = tokio::sync::mpsc::channel(8);
        let (calls_tx, mut calls) = tokio::sync::mpsc::channel(32);
        let mut control = FakeControl::attach(&gateway, 8).await;
        let control_gateway = gateway.clone();
        let control_state = Arc::clone(&native);
        let control_task = tokio::spawn(async move {
            let mut attempts = 0;
            let mut fork_id = "fork".to_owned();
            while let Some(raw) = control.requests.recv().await {
                let request: Value = serde_json::from_str(&raw).unwrap();
                calls_tx.send(request.clone()).await.unwrap();
                let mut state = control_state.lock().await;
                let mut fork_events = Vec::new();
                let result = match request["method"].as_str().unwrap() {
                    "thread/read" => json!({"thread":state["thread"]}),
                    "thread/turns/list" => json!({"data":[state["latest"]]}),
                    "thread/items/list" => {
                        let mut items = vec![
                            json!({"item":user("Learn iOS 27 motion design and SwiftUI best practices")}),
                        ];
                        items.extend(
                            state["latest"]["items"]
                                .as_array()
                                .unwrap()
                                .iter()
                                .map(|item| json!({"item":item})),
                        );
                        json!({"data":items,"nextCursor":null})
                    }
                    "thread/fork" => {
                        fork_id = if attempts == 0 { "fork" } else { "fork-2" }.to_owned();
                        fork_events = vec![json!({"method":"thread/started","params":{"thread":
                            {"id":fork_id,"ephemeral":true,"forkedFromId":"thread"}}})];
                        json!({"thread":{"id":fork_id,"ephemeral":true}})
                    }
                    "turn/start" => {
                        attempts += 1;
                        let answer = if change.starts_with("repair")
                            && (attempts == 1 || change == "repairEcho")
                        {
                            rejected_title
                        } else {
                            repaired_title
                        };
                        match change {
                            "title" => state["thread"]["name"] = json!("My manual name"),
                            "turn" => state["latest"] = turn("newer", "Another task"),
                            "active" => state["thread"]["status"] = json!({"type":"active"}),
                            "unrelated" => control_gateway.review.ingest(
                                &json!({"method":"turn/started","params":{"threadId":"other","turn":{"id":"other-turn"}}}),
                                true,
                            ),
                            "repairGoal" if attempts == 2 => {
                                state["latest"]["items"][0] =
                                    user("Stop repairing and inspect a different disk");
                            }
                            "pin" => {
                                control_gateway
                                    .marks
                                    .update(
                                        vec![Change::Pin {
                                            thread_id: "thread".into(),
                                            name: "My pinned name".into(),
                                        }],
                                        1,
                                    )
                                    .await
                                    .unwrap();
                            }
                            _ => {}
                        }
                        fork_events = vec![
                            json!({"method":"thread/status/changed","params":{"threadId":fork_id,"status":{"type":"active"}}}),
                        ];
                        if change == "tool" {
                            fork_events.push(json!({"method":"item/started","params":{"threadId":fork_id,"item":{"type":"commandExecution"}}}));
                        }
                        fork_events.extend([
                            json!({"method":"item/started","params":{"threadId":fork_id,"item":{"type":"agentMessage"}}}),
                            json!({"method":"item/agentMessage/delta","params":{"threadId":fork_id,"delta":"Automatic"}}),
                            json!({"method":"item/completed","params":{"threadId":fork_id,
                                "item":{"type":"agentMessage","text":answer}}}),
                            json!({"method":"thread/tokenUsage/updated","params":{"threadId":fork_id,"turnId":"fork-turn",
                                "tokenUsage":{"last":{"inputTokens":1000,"cachedInputTokens":900}}}}),
                            json!({"method":"turn/completed","params":{"threadId":fork_id,
                                "turn":{"id":"fork-turn","status":"completed"}}}),
                        ]);
                        json!({"turn":{"id":"fork-turn"}})
                    }
                    "turn/interrupt" => json!({}),
                    "thread/unsubscribe" => {
                        fork_events = vec![
                            json!({"method":"thread/status/changed","params":{"threadId":fork_id,"status":{"type":"notLoaded"}}}),
                            json!({"method":"thread/closed","params":{"threadId":fork_id}}),
                        ];
                        json!({})
                    }
                    "thread/name/set" => {
                        assert_eq!(
                            control_gateway.review.budget.available_permits(),
                            1,
                            "a submitted rename must release title evaluation capacity"
                        );
                        state["thread"]["name"] = request["params"]["name"].clone();
                        renames_tx
                            .send(request["params"]["name"].clone())
                            .await
                            .unwrap();
                        json!({})
                    }
                    other => panic!("unexpected {other}"),
                };
                drop(state);
                control_gateway
                    .handle_control_text(
                        json!({"id":request["id"],"result":result}).to_string(),
                        NotificationOrigin::Control { opened_after: 0 },
                    )
                    .await;
                for event in fork_events {
                    control_gateway
                        .handle_control_text(
                            event.to_string(),
                            NotificationOrigin::Control { opened_after: 0 },
                        )
                        .await;
                }
            }
        });
        let marks_directory = directory.path().to_path_buf();
        let router = Router::new().route(
            DECISIONS,
            post(move || {
                let marks_directory = marks_directory.clone();
                async move {
                    let mut response = if change.starts_with("repair") {
                        decision(json!(0.63), json!(0.28))
                    } else {
                        decision(json!(0.1), json!(0.97))
                    };
                    if change == "malformedDone" {
                        response["answers"]["done"]["noul"] = json!("invalid");
                    }
                    if change == "doneWrite" {
                        std::fs::write(marks_directory.join("conversation-marks.v3.json"),
                            json!({"schemaVersion":3,"revision":u64::MAX,"readBaseline":0,"threads":{}}).to_string()).unwrap();
                    }
                    Json(response)
                }
            }),
        );
        let (address, server) = crate::test_support::serve(router).await;
        let api = judge_api(address, "router-key");
        let floor = gateway.notification_floor().await;
        let outcome = gateway
            .review_turn(
                &api,
                "thread",
                "latest",
                &trace,
                Arc::clone(&gateway.review.budget)
                    .try_acquire_owned()
                    .unwrap(),
            )
            .await;
        assert_eq!(
            gateway.notification_floor().await,
            floor,
            "side-question fork events reached notification history"
        );
        let mut requests = Vec::new();
        while let Ok(request) = calls.try_recv() {
            requests.push(request);
        }
        let call = |method: &str| {
            requests
                .iter()
                .find(|request| request["method"] == method)
                .unwrap_or_else(|| panic!("no {method}"))["params"]
                .clone()
        };
        assert_eq!(
            call("thread/fork"),
            json!({"threadId":"thread","ephemeral":true,"excludeTurns":true,
                "model":"gpt-6.1-sol","sandbox":"read-only","approvalPolicy":"never"})
        );
        let question = call("turn/start");
        assert_eq!(question["threadId"], "fork");
        assert_eq!(question["effort"], "xhigh");
        assert!(question.get("outputSchema").is_none());
        let questions = requests
            .iter()
            .filter(|request| request["method"] == "turn/start")
            .collect::<Vec<_>>();
        assert_eq!(
            questions.len(),
            if change.starts_with("repair") { 2 } else { 1 }
        );
        for question in &questions {
            let text = question["params"]["input"][0]["text"].as_str().unwrap();
            assert!(text.contains(&format!("“{rejected_title}”")));
            assert!(text.contains(latest_goal));
            assert!(!text.contains("Learn iOS 27 motion design"));
            assert!(!text.contains("Stop repairing"));
        }
        if change.starts_with("repair") {
            assert!(
                questions[1]["params"]["input"][0]["text"]
                    .as_str()
                    .unwrap()
                    .contains("Your first answer repeated the rejected title")
            );
        }
        assert_eq!(call("thread/unsubscribe"), json!({"threadId":"fork"}));
        if change == "tool" {
            assert_eq!(outcome.unwrap().status, "failed");
            assert_eq!(
                call("turn/interrupt"),
                json!({"threadId":"fork","turnId":"fork-turn"})
            );
            assert!(renames.try_recv().is_err());
            control_task.abort();
            server.abort();
            continue;
        }
        let outcome = outcome.unwrap();
        trace.finish(outcome.status, outcome.reason);
        let records = trace_records(journal, &logs).await;
        if matches!(change, "malformedDone" | "doneWrite") {
            let finished = records.last().unwrap();
            assert_eq!(finished["consumers"]["done"]["outcome"], "failed");
            assert_eq!(finished["consumers"]["title"]["outcome"], "renamed");
            assert!(
                records
                    .iter()
                    .any(|record| record["event"] == "consumerFailed"
                        && record["consumer"] == "done")
            );
        }
        assert_eq!(
            records.last().unwrap()["outcome"],
            if matches!(
                change,
                "none" | "unrelated" | "repair" | "repairLong" | "malformedDone" | "doneWrite"
            ) {
                "renamed"
            } else if change == "repairEcho" {
                "kept"
            } else {
                "skipped"
            }
        );
        let answer = records
            .iter()
            .find(|record| record["event"] == "sideAnswer")
            .unwrap();
        assert_eq!(
            answer["answer"],
            if change.starts_with("repair") {
                rejected_title
            } else {
                repaired_title
            }
        );
        if change == "repairEcho" {
            assert_eq!(
                records.last().unwrap()["reason"],
                "writerEchoedRejectedTitleAfterRepair"
            );
        }
        if change == "repairGoal" {
            assert_eq!(records.last().unwrap()["reason"], "snapshotChanged");
        }
        assert_eq!(
            answer["usage"],
            json!({"inputTokens":1000,"cachedInputTokens":900})
        );
        assert!(
            records
                .iter()
                .all(|record| record["traceId"] == records[0]["traceId"])
        );
        assert_eq!(
            records
                .iter()
                .any(|record| record["event"] == "renameRequest"),
            matches!(
                change,
                "none" | "unrelated" | "repair" | "repairLong" | "malformedDone" | "doneWrite"
            )
        );
        if matches!(
            change,
            "none" | "unrelated" | "repair" | "repairLong" | "malformedDone" | "doneWrite"
        ) {
            assert_eq!(
                records
                    .iter()
                    .find(|record| record["event"] == "renameReadback")
                    .unwrap()["matches"],
                true
            );
            assert_eq!(renames.try_recv().unwrap(), repaired_title);
        } else {
            assert!(renames.try_recv().is_err(), "stale rename after {change}");
        }
        control_task.abort();
        server.abort();
    }
}

#[tokio::test]
async fn claude_thread_without_a_warm_runtime_is_titled_through_a_detached_fork() {
    use crate::agents::mcp::McpTokens;
    use crate::providers::claude::ClaudeSupervisor;
    let directory = tempfile::tempdir().unwrap();
    let logs = directory.path().join("title-logs");
    let journal = crate::observability::journal::Journal::open_in(logs.clone(), 30);
    let gateway = TestGateway::with_native_runtime_journal(directory.path(), journal.clone());
    let session = "11111111-2222-4333-8444-555555555555";
    let thread = format!("claude_{session}");
    let home = gateway.claude_settings.claude_home.clone();
    let cwd = directory.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let cwd = cwd.to_string_lossy().into_owned();
    let path = crate::providers::claude::timeline::session_path_for_cwd(&home, &cwd, session);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let records = [
        json!({"type":"user","uuid":"user-1","sessionId":session,"cwd":cwd,"timestamp":"2026-10-02T10:00:00Z","message":{"role":"user","content":"Fix conversation naming"}}),
        json!({"type":"assistant","uuid":"assistant-1","sessionId":session,"cwd":cwd,"timestamp":"2026-10-02T10:01:00Z","message":{"id":"msg-1","role":"assistant","content":[{"type":"text","text":"Implemented."}],"stop_reason":"end_turn"}}),
    ];
    let history = records
        .iter()
        .map(Value::to_string)
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    std::fs::write(&path, &history).unwrap();
    let stub = directory.path().join("claude-stub");
    crate::test_support::write_claude_cli_stub(
        &stub,
        crate::test_support::ClaudeCliMode::SuspendLogsInterrupt,
    );
    let (tx, mut notifications) = tokio::sync::mpsc::channel(16);
    let agent = ClaudeSupervisor::new(
        crate::providers::claude::settings::ClaudeSettings {
            claude_path: stub,
            config_dir: Some(home.clone()),
            ..gateway.claude_settings.clone()
        },
        tx,
        crate::observability::journal::Journal::disabled(),
        McpTokens::default(),
    );
    gateway.set_claude_agent(agent);
    let index = crate::providers::claude::conversation_index::Store::new(home.clone());
    let start = crate::time::parse_rfc3339_seconds("2026-10-02T10:00:00Z").unwrap();
    let indexed_turn = "claude-turn-indexed";
    for mut frame in [
        json!({"method":"turn/started","params":{"threadId":thread,"turn":{"id":indexed_turn,"startedAtMs":start * 1000,"status":"inProgress"}}}),
        json!({"method":"item/completed","params":{"threadId":thread,"turnId":indexed_turn,"item":{"type":"userMessage","id":"user-1","clientId":"user-1","content":[]},"startedAtMs":start * 1000,"completedAtMs":start * 1000}}),
        json!({"method":"item/completed","params":{"threadId":thread,"turnId":indexed_turn,"item":{"type":"agentMessage","id":"msg-1#0","text":"Implemented."},"startedAtMs":(start + 60) * 1000,"completedAtMs":(start + 60) * 1000}}),
        json!({"method":"turn/completed","params":{"threadId":thread,"turn":{"id":indexed_turn,"completedAtMs":(start + 65) * 1000,"status":"completed"}}}),
    ] {
        index.record(&mut frame).await.unwrap();
    }
    let page = gateway.review_turns(&thread, "desc", 1).await.unwrap();
    let turn_id = page["data"][0]["id"].as_str().unwrap();
    let (api, server, _requests) =
        api_fixture("router-key", decision(json!(0.9), json!(0.1))).await;
    let mut trace = gateway.review_trace(&thread, turn_id);
    let outcome = gateway
        .review_turn(
            &api,
            &thread,
            turn_id,
            &trace,
            Arc::clone(&gateway.review.budget)
                .try_acquire_owned()
                .unwrap(),
        )
        .await
        .unwrap();
    trace.finish(outcome.status, outcome.reason);
    let records = trace_records(journal, &logs).await;
    assert_eq!(
        records.last().unwrap()["outcome"],
        "renamed",
        "{records:#?}"
    );
    assert!(records.iter().all(|record| record["provider"] == "claude"));
    assert_eq!(
        gateway.review_header(&thread).await.unwrap()["thread"]["name"],
        "Detached title"
    );
    let detached: Value = serde_json::from_str(
        std::fs::read_to_string(home.join("detached.jsonl"))
            .unwrap()
            .lines()
            .next()
            .unwrap(),
    )
    .unwrap();
    let argv = detached["argv"].as_array().unwrap();
    for flag in [
        "--fork-session",
        "--no-session-persistence",
        "--strict-mcp-config",
    ] {
        assert!(argv.contains(&json!(flag)), "{argv:?}");
    }
    let resume = argv.iter().position(|arg| arg == "--resume").unwrap();
    assert_eq!(argv[resume + 1], session);
    let tools = argv.iter().position(|arg| arg == "--tools").unwrap();
    assert_eq!(argv[tools + 1], "");
    assert_eq!(
        std::fs::canonicalize(detached["cwd"].as_str().unwrap()).unwrap(),
        std::fs::canonicalize(&cwd).unwrap()
    );
    assert!(
        std::fs::read_to_string(&path)
            .unwrap()
            .starts_with(&history),
        "the detached fork must not rewrite the transcript"
    );
    while let Ok(notification) = notifications.try_recv() {
        let crate::providers::claude::ClaudeNotification::Event(event) = notification else {
            continue;
        };
        assert_eq!(event["method"], "thread/name/updated", "{event}");
    }
    let done = records
        .iter()
        .position(|record| record["event"] == "doneMarks")
        .unwrap();
    let writer = records
        .iter()
        .position(|record| record["event"] == "sideQuestion")
        .unwrap();
    assert!(done < writer);
    server.abort();
}

#[tokio::test]
async fn review_questions_follow_turn_eligibility_and_malformed_done_does_not_write() {
    for kind in [
        "user",
        "agent",
        "image",
        "missingTime",
        "none",
        "notDone",
        "malformed",
        "malformedTitle",
    ] {
        let directory = tempfile::tempdir().unwrap();
        let logs = directory.path().join("review-logs");
        let journal = crate::observability::journal::Journal::open_in(logs.clone(), 30);
        let gateway = TestGateway::with_native_runtime_journal(directory.path(), journal.clone());
        let mut trace = gateway.review_trace("thread", "latest");
        let mut latest = turn("latest", "Fix naming");
        if kind == "agent" {
            latest["items"].as_array_mut().unwrap().remove(0);
        }
        if matches!(kind, "image" | "none") {
            latest["items"][0] = json!({"type":"userMessage","content":[]});
        }
        if matches!(kind, "missingTime" | "none") {
            latest.as_object_mut().unwrap().remove("completedAt");
        }
        let control = fake_pages(gateway.clone(), "Useful naming", latest).await;
        let mut response = decision(json!(0.1), json!(0.1));
        if matches!(kind, "notDone" | "malformed") {
            gateway
                .marks
                .record_done("thread".into(), Some(1000), 1100)
                .await
                .unwrap();
        }
        if kind == "notDone" {
            response["answers"]["done"]["noul"] = json!(0.1);
        }
        if kind == "malformed" {
            response["answers"]["done"] = json!({"type":"noul","noul":"yes"});
        }
        if kind == "malformedTitle" {
            response["answers"]["misleading"]["noul"] = json!("invalid");
        }
        let (api, server, mut requests) = api_fixture("router-key", response).await;
        let outcome = gateway
            .review_turn(
                &api,
                "thread",
                "latest",
                &trace,
                Arc::clone(&gateway.review.budget)
                    .try_acquire_owned()
                    .unwrap(),
            )
            .await;
        assert!(outcome.is_ok());
        assert_eq!(
            outcome.as_ref().unwrap().status == "failed",
            kind == "malformedTitle"
        );
        if kind == "none" {
            assert_eq!(outcome.unwrap().reason, "noApplicableQuestions");
            assert!(requests.try_recv().is_err());
            control.abort();
            server.abort();
            continue;
        }
        let outcome = outcome.unwrap();
        trace.finish(outcome.status, outcome.reason);
        let records = trace_records(journal, &logs).await;
        if kind == "malformedTitle" {
            let finished = records.last().unwrap();
            assert_eq!(finished["consumers"]["done"]["outcome"], "written");
            assert_eq!(finished["consumers"]["title"]["outcome"], "failed");
            assert!(
                records
                    .iter()
                    .any(|record| record["event"] == "consumerFailed"
                        && record["consumer"] == "title")
            );
        }
        if kind == "malformed" {
            let finished = records.last().unwrap();
            assert_eq!(finished["consumers"]["done"]["outcome"], "failed");
            assert_eq!(finished["consumers"]["title"]["outcome"], "kept");
        }
        let request = requests.recv().await.unwrap();
        let questions = &request["body"]["questions"];
        assert_eq!(
            questions.get("misleading").is_some(),
            !matches!(kind, "agent" | "image")
        );
        assert_eq!(questions.get("done").is_some(), kind != "missingTime");
        assert_eq!(
            gateway
                .marks
                .read(2_000)
                .await
                .unwrap()
                .threads
                .get("thread")
                .and_then(|marks| marks.done_through),
            if kind == "malformed" {
                Some(1000)
            } else {
                (!matches!(kind, "notDone" | "missingTime")).then_some(1234)
            }
        );
        control.abort();
        server.abort();
    }
    for answer in [
        json!({}),
        json!({"type":"choice","noul":1.0}),
        json!({"type":"noul","noul":1.01}),
        json!({"type":"noul","noul":-0.1}),
    ] {
        assert!(done::decision(&json!({"answers":{"done":answer}})).is_err());
    }
}

#[tokio::test]
async fn done_verdicts_survive_read_marks_and_unrelated_activity_but_respect_unsettle() {
    let mut suggested = Vec::new();
    for change in ["read", "other", "unsettle", "pin", "purpose"] {
        let directory = tempfile::tempdir().unwrap();
        let gateway = TestGateway::with_native_runtime(directory.path());
        gateway.marks.read(0).await.unwrap();
        let control = fake_pages(
            gateway.clone(),
            "Useful naming",
            turn("latest", "Fix naming"),
        )
        .await;
        let owner = gateway.clone();
        let router = Router::new().route(
            DECISIONS,
            post(move || {
                let owner = owner.clone();
                async move {
                    match change {
                        "read" => {
                            owner
                                .marks
                                .update(
                                    vec![Change::MarkRead {
                                        thread_id: "thread".into(),
                                        through: 1234,
                                    }],
                                    2000,
                                )
                                .await
                                .unwrap();
                        }
                        "other" => owner.review.ingest(
                            &json!({"method":"turn/started",
                        "params":{"threadId":"another-thread"}}),
                            true,
                        ),
                        "unsettle" => {
                            owner
                                .marks
                                .update(
                                    vec![Change::Unsettle {
                                        thread_id: "thread".into(),
                                        through: 1234,
                                    }],
                                    2000,
                                )
                                .await
                                .unwrap();
                        }
                        "pin" => {
                            owner
                                .marks
                                .update(
                                    vec![Change::Pin {
                                        thread_id: "thread".into(),
                                        name: "Keep".into(),
                                    }],
                                    2000,
                                )
                                .await
                                .unwrap();
                        }
                        "purpose" => {
                            owner
                                .marks
                                .update(
                                    vec![Change::SetPurpose {
                                        thread_id: "thread".into(),
                                        purpose: Purpose::Probe,
                                    }],
                                    2000,
                                )
                                .await
                                .unwrap();
                        }
                        _ => unreachable!(),
                    }
                    Json(decision(json!(0.1), json!(0.1)))
                }
            }),
        );
        let (address, server) = crate::test_support::serve(router).await;
        gateway
            .review_turn(
                &judge_api(address, "router-key"),
                "thread",
                "latest",
                &Trace::silent(),
                Arc::clone(&gateway.review.budget)
                    .try_acquire_owned()
                    .unwrap(),
            )
            .await
            .unwrap();
        suggested.push(
            gateway
                .marks
                .read(2000)
                .await
                .unwrap()
                .threads
                .get("thread")
                .and_then(|marks| marks.done_through)
                == Some(1234),
        );
        control.abort();
        server.abort();
    }
    assert_eq!(suggested, [true, true, false, false, false]);
}

#[tokio::test]
async fn delegated_completions_are_skipped_before_reading_dialogue_or_calling_jev() {
    let directory = tempfile::tempdir().unwrap();
    let logs = directory.path().join("review-logs");
    let journal = crate::observability::journal::Journal::open_in(logs.clone(), 30);
    let gateway = TestGateway::with_native_runtime_journal(directory.path(), journal.clone());
    let mut control = FakeControl::attach(&gateway, 4).await;
    let owner = gateway.clone();
    let task = tokio::spawn(async move {
        let request: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        assert_eq!(request["method"], "thread/read");
        owner.handle_control_text(json!({"id":request["id"],"result":{"thread":{"id":"child","source":{"subAgent":"review"}}}}).to_string(), NotificationOrigin::Control { opened_after: 0 }).await;
    });
    gateway.review.ingest(&json!({"method":"turn/completed","params":{"threadId":"child","turn":{"id":"latest","status":"completed"}}}), true);
    let _finished = tokio::time::timeout(
        Duration::from_secs(3),
        Arc::clone(&gateway.review.budget).acquire_owned(),
    )
    .await
    .unwrap()
    .unwrap();
    let records = trace_records(journal, &logs).await;
    let finished = records
        .iter()
        .find(|record| record["event"] == "finished")
        .unwrap();
    assert_eq!(finished["reason"], "delegatedAgent");
    assert!(!records.iter().any(|record| record["event"] == "request"));
    gateway.review.stop().await;
    task.abort();
}

#[tokio::test]
async fn early_title_names_only_an_untitled_running_first_turn() {
    for case in ["eligible", "named", "laterTurn", "completed", "pinned"] {
        let directory = tempfile::tempdir().unwrap();
        let logs = directory.path().join("title-logs");
        let journal = crate::observability::journal::Journal::open_in(logs.clone(), 30);
        let gateway = TestGateway::with_native_runtime_journal(directory.path(), journal.clone());
        if case == "pinned" {
            gateway
                .marks
                .update(
                    vec![Change::Pin {
                        thread_id: "thread".into(),
                        name: "Pinned".into(),
                    }],
                    1,
                )
                .await
                .unwrap();
        }
        let mut first = turn("first", "Fix automatic conversation names");
        first["status"] = json!(if case == "completed" {
            "completed"
        } else {
            "inProgress"
        });
        let turns = if case == "laterTurn" {
            json!([turn("second", "Another task"), first])
        } else {
            json!([first])
        };
        let header = json!({"id":"thread","name":if case == "named" { json!("My name") } else { Value::Null },
            "preview":"fix the names please","status":{"type":"active"},"ephemeral":false,"source":"appServer",
            "model":"gpt-6.1-sol","reasoningEffort":"low"});
        let (control_task, mut calls) = spawn_title_control(
            &gateway,
            header,
            turns,
            vec!["Automatic conversation titles"],
        )
        .await;
        tokio::time::pause();
        let started = if case == "laterTurn" {
            "second"
        } else {
            "first"
        };
        gateway.review.ingest(
            &json!({"method":"turn/started","params":{"threadId":"thread","turn":{"id":started}}}),
            true,
        );
        tokio::time::sleep(early_title::DELAY + Duration::from_secs(1)).await;
        tokio::time::resume();
        tokio::time::timeout(Duration::from_secs(30), async {
            while gateway.review.early_titles.available_permits() < early_title::MAX_PENDING {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        control_task.abort();
        let mut methods = Vec::new();
        let mut name = None;
        while let Ok(request) = calls.try_recv() {
            if request["method"] == "thread/name/set" {
                name = Some(request["params"]["name"].clone());
            }
            methods.push(request["method"].as_str().unwrap().to_owned());
        }
        let records = trace_records(journal, &logs).await;
        let finished = records.iter().find(|record| record["event"] == "finished");
        match case {
            "eligible" => {
                assert_eq!(
                    name,
                    Some(json!("Automatic conversation titles")),
                    "{methods:?} {records:#?}"
                );
                let finished = finished.unwrap();
                assert_eq!(finished["outcome"], "renamed", "{records:#?}");
                assert_eq!(finished["trigger"], "earlyTitle");
                assert!(records.iter().all(|record| record["judgeModel"].is_null()));
            }
            "pinned" => {
                assert!(
                    !methods.iter().any(|method| method == "thread/fork"),
                    "{methods:?}"
                );
                assert_eq!(finished.unwrap()["reason"], "pinned", "{records:#?}");
            }
            _ => {
                assert!(
                    !methods.iter().any(|method| method == "thread/fork"),
                    "{case}: {methods:?}"
                );
                assert!(records.is_empty(), "{case}: {records:#?}");
                let header_reads = methods
                    .iter()
                    .filter(|method| *method == "thread/read")
                    .count();
                assert_eq!(
                    header_reads,
                    if case == "completed" { 2 } else { 1 },
                    "{case}: {methods:?}"
                );
            }
        }
    }
}

async fn spawn_title_control(
    gateway: &Arc<Gateway>,
    header: Value,
    turns: Value,
    answers: Vec<&'static str>,
) -> (
    tokio::task::JoinHandle<()>,
    tokio::sync::mpsc::UnboundedReceiver<Value>,
) {
    let (calls_tx, calls) = tokio::sync::mpsc::unbounded_channel();
    let mut control = FakeControl::attach(gateway, 8).await;
    let control_gateway = Arc::clone(gateway);
    let task = tokio::spawn(async move {
        let mut answers = answers.into_iter();
        while let Some(raw) = control.requests.recv().await {
            let request: Value = serde_json::from_str(&raw).unwrap();
            calls_tx.send(request.clone()).unwrap();
            let mut events = Vec::new();
            let result = match request["method"].as_str().unwrap() {
                "thread/read" => json!({"thread":header}),
                "thread/turns/list" => json!({"data":turns}),
                "thread/fork" => {
                    events = vec![json!({"method":"thread/started","params":{"thread":
                        {"id":"fork","ephemeral":true,"forkedFromId":"thread"}}})];
                    json!({"thread":{"id":"fork","ephemeral":true}})
                }
                "turn/start" => {
                    let answer = answers.next().expect("an unexpected title question");
                    events = vec![
                        json!({"method":"item/completed","params":{"threadId":"fork",
                            "item":{"type":"agentMessage","text":answer}}}),
                        json!({"method":"turn/completed","params":{"threadId":"fork",
                            "turn":{"id":"fork-turn","status":"completed"}}}),
                    ];
                    json!({"turn":{"id":"fork-turn"}})
                }
                "thread/unsubscribe" => {
                    events = vec![json!({"method":"thread/closed","params":{"threadId":"fork"}})];
                    json!({})
                }
                "thread/name/set" => json!({}),
                other => panic!("unexpected {other}"),
            };
            control_gateway
                .handle_control_text(
                    json!({"id":request["id"],"result":result}).to_string(),
                    NotificationOrigin::Control { opened_after: 0 },
                )
                .await;
            for event in events {
                control_gateway
                    .handle_control_text(
                        event.to_string(),
                        NotificationOrigin::Control { opened_after: 0 },
                    )
                    .await;
            }
        }
    });
    (task, calls)
}

#[tokio::test]
async fn regenerating_a_name_fails_when_the_writer_keeps_repeating_it() {
    for answers in [
        vec!["Old title", "Fresh title"],
        vec!["Old title", "Old title"],
    ] {
        let directory = tempfile::tempdir().unwrap();
        let gateway = TestGateway::with_native_runtime_journal(
            directory.path(),
            crate::observability::journal::Journal::disabled(),
        );
        let header = json!({"id":"thread","name":"Old title","preview":"fix the names",
            "status":{"type":"idle"},"ephemeral":false,"model":"gpt-6.1-sol","reasoningEffort":"low"});
        let (control_task, mut calls) =
            spawn_title_control(&gateway, header, json!([]), answers.clone()).await;
        let result = gateway
            .regenerate_title_rpc(&json!({"threadId":"thread"}))
            .await;
        control_task.abort();
        let mut questions = Vec::new();
        let mut renamed = None;
        while let Ok(request) = calls.try_recv() {
            match request["method"].as_str().unwrap() {
                "turn/start" => questions.push(request["params"]["input"][0]["text"].clone()),
                "thread/name/set" => renamed = Some(request["params"]["name"].clone()),
                _ => {}
            }
        }
        assert_eq!(questions.len(), 2);
        assert!(questions[0].as_str().unwrap().contains("“Old title”"));
        assert!(
            questions[1]
                .as_str()
                .unwrap()
                .contains("Your first answer repeated the current title")
        );
        if answers[1] == "Fresh title" {
            assert_eq!(result.unwrap(), json!({"name":"Fresh title"}));
            assert_eq!(renamed, Some(json!("Fresh title")));
        } else {
            assert!(result.is_err());
            assert_eq!(renamed, None);
        }
    }
}
