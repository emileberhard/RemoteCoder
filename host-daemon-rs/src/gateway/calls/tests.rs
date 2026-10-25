use super::*;
use crate::gateway::tests::CONTROL;
use crate::providers::codex::daemon::CodexAppServer;
use crate::voice::handoff::VoiceDelegations;
use crate::voice::session::{VoiceSession, VoiceSessionOwner};
use std::collections::HashMap;
use std::time::Duration;

fn record(to: &str) -> CallRecord {
    CallRecord {
        call_id: new_session_uuid(),
        conversation_thread_id: "thread-owned".into(),
        provider: "codex".into(),
        request: RequestCall {
            request_id: "attempt-one".into(),
            to: to.into(),
            brief: CallBrief {
                purpose: "Verify calls".into(),
                language: "English".into(),
                context: "Synthetic test".into(),
                scope: "Only this test".into(),
                stop_conditions: "Stop on request".into(),
                opening: None,
            },
        },
        cwd: "/tmp".into(),
        model: "gpt-5.6-luna".into(),
        effort: Some("medium".into()),
        state: CallState::Requested,
        created_at: unix_seconds(),
        expires_at: unix_seconds() + 60.0,
        connected_at: None,
        ended_at: None,
        reason: None,
        delivery_receipt: None,
        voice_log_path: None,
        device_id: Some("device-one".into()),
        media_client_id: None,
    }
}

fn gateway() -> crate::test_support::TestGateway {
    gateway_with_state_path(None)
}

fn gateway_with_state_path(path: Option<PathBuf>) -> crate::test_support::TestGateway {
    crate::test_support::TestGateway::with_codex(
        Arc::new(CodexAppServer::new(
            PathBuf::from("/bin/true"),
            HashMap::new(),
        )),
        path,
    )
}

#[test]
fn call_identity_is_neutral_for_self_and_required_for_third_parties() {
    let call = record("self");
    assert!(
        call.request
            .brief
            .voice_instructions("call", false, None)
            .unwrap()
            .contains("the user's assistant")
    );
    assert!(
        call.backend_context(None)
            .unwrap()
            .contains("the user in RemoteCoder")
    );
    assert!(
        call.request
            .brief
            .voice_instructions("call", true, None)
            .unwrap_err()
            .to_string()
            .contains("RC_CODEX_GATEWAY_USER_NAME")
    );
    for telephone in [false, true] {
        assert!(
            call.request
                .brief
                .voice_instructions("call", telephone, Some("Maya Chen"))
                .unwrap()
                .contains("Identify yourself as Maya Chen's assistant")
        );
    }
    assert!(
        call.backend_context(Some("Maya Chen"))
            .unwrap()
            .contains("Maya Chen in RemoteCoder")
    );
}

#[tokio::test]
async fn telephone_calls_without_a_user_name_fail_before_preflight_or_delivery() {
    let gateway = gateway();
    let control = crate::test_support::FakeControl::attach(&gateway, 4).await;
    let caller = Caller {
        turn_id: None,
        provider: Provider::Codex,
        thread_id: Some("thread-owned".into()),
    };
    let error = gateway
        .request_agent_call(&caller, record("+12025550123").request)
        .await
        .unwrap_err();
    assert!(error.to_string().contains("RC_CODEX_GATEWAY_USER_NAME"));
    assert!(gateway.calls.state.lock().await.records.is_empty());
    let mut requests = control.requests;
    assert!(requests.try_recv().is_err());
}

#[tokio::test]
async fn voice_transport_end_cannot_stop_another_call_on_the_same_client() {
    let gateway = gateway();
    let mut newer = record("self");
    newer.state = CallState::Connected;
    newer.media_client_id = Some(1);
    gateway.calls.state.lock().await.records.push(newer.clone());
    let ended = gateway
        .record_call_transport_end(
            &VoiceSessionOwner {
                client_id: 1,
                realtime_session_id: "old-call".into(),
            },
            "old provider closure",
        )
        .await
        .unwrap();
    assert!(ended.is_none());
    assert_eq!(
        gateway.calls.get(&newer.call_id).await.unwrap().state,
        CallState::Connected
    );
}

#[tokio::test]
async fn shutdown_refuses_call_delivery_without_reacquiring_the_request_transition() {
    let gateway = gateway();
    gateway
        .apns
        .devices()
        .register(crate::devices::fixture_registration(1))
        .await
        .unwrap();
    gateway.voice_tasks.stop().await;
    let mut control = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;
    let caller = Caller {
        provider: Provider::Codex,
        thread_id: Some("thread-owned".into()),
        turn_id: None,
    };
    let preflight = async {
        for method in ["thread/read", "account/read", "config/read"] {
            let request: Value = serde_json::from_str(&control.recv().await.unwrap()).unwrap();
            assert_eq!(request["method"], method);
            let result = match method {
                "thread/read" => {
                    json!({"thread": {"modelProvider": "openai", "cwd": "/tmp", "model": "gpt-5.6-luna", "status": {"type": "idle"}}})
                }
                "account/read" => json!({"account": {"type": "chatgpt"}}),
                _ => json!({"config": {}}),
            };
            gateway
                .handle_control_text(
                    json!({"id": request["id"], "result": result}).to_string(),
                    CONTROL,
                )
                .await;
        }
    };
    let request = record("self").request;
    let admission = gateway.request_agent_call(&caller, request);
    let (result, ()) = tokio::time::timeout(Duration::from_secs(1), async {
        tokio::join!(admission, preflight)
    })
    .await
    .unwrap();
    assert_eq!(result.unwrap_err().to_string(), "gateway is restarting");
    let active = gateway.calls.state.lock().await.records[0].clone();
    assert_eq!(active.state, CallState::Unresolved);
    assert!(active.ended_at.is_some());
    assert_eq!(
        active.reason.as_deref(),
        Some("delivery failed or uncertain: gateway is stopping")
    );
    assert!(control.try_recv().is_err());
    let _transition = tokio::time::timeout(Duration::from_secs(1), gateway.voice.transition())
        .await
        .unwrap();
}

#[tokio::test]
async fn unavailable_codex_origin_is_rejected_before_call_creation_or_delivery() {
    for status in [
        json!({"type": "notLoaded"}),
        json!({"type": "systemError"}),
        json!({"type": "unknown"}),
        Value::Null,
    ] {
        let gateway = gateway();
        let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
            .await
            .requests;
        let caller = Caller {
            turn_id: None,
            provider: Provider::Codex,
            thread_id: Some("saved-but-unloaded".into()),
        };
        let request = record("self").request;
        let admission = gateway.request_agent_call(&caller, request);
        let read = async {
            let raw = out_rx.recv().await.unwrap();
            let request: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(request["method"], "thread/read");
            gateway.handle_control_text(json!({"id": request["id"], "result": {"thread": {
                "modelProvider": "openai", "cwd": "/tmp", "model": "gpt-5.6-luna", "status": status
            }}}).to_string(), CONTROL).await;
        };
        let (result, ()) = tokio::join!(admission, read);
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("not loaded and available")
        );
        assert!(gateway.calls.state.lock().await.records.is_empty());
        assert!(
            out_rx.try_recv().is_err(),
            "admission must stop before subscription/media work"
        );
    }
}

#[tokio::test]
async fn stale_transport_or_preemption_snapshot_cannot_undo_terminal_confirmation() {
    for terminal in [CallState::Ended, CallState::Unresolved] {
        let calls = AgentCalls::new(None, None);
        let original = record("+46000000001");
        calls.state.lock().await.records.push(original.clone());
        let stale = calls.active().await.unwrap();
        calls
            .change(&original.call_id, move |record| {
                record.state = terminal;
                record.reason = Some("authoritative terminal evidence".into());
                record.ended_at = Some(42.0);
                Ok(())
            })
            .await
            .unwrap();
        for reason in [
            "transport ended",
            "preempted by a user-started voice call",
            "agent ended",
        ] {
            let result = calls
                .change(&stale.call_id, move |record| {
                    record.request_stop(reason);
                    Ok(())
                })
                .await
                .unwrap();
            assert_eq!(result.state, terminal);
            assert_eq!(
                result.reason.as_deref(),
                Some("authoritative terminal evidence")
            );
            assert_eq!(result.ended_at, Some(42.0));
        }
    }
}

#[test]
fn voice_cleanup_failure_preserves_confirmed_carrier_completion() {
    for recipient in ["self", "+46000000001"] {
        let mut record = record(recipient);
        record.state = CallState::Ended;
        record.reason = Some("carrier confirmed completion".into());
        record.ended_at = Some(42.0);
        record.record_media_stop_uncertainty("upstream stop failed".into());
        if recipient == "self" {
            assert_eq!(record.state, CallState::Unresolved);
            assert_eq!(record.reason.as_deref(), Some("upstream stop failed"));
        } else {
            assert_eq!(record.state, CallState::Ended);
            assert_eq!(
                record.reason.as_deref(),
                Some("carrier confirmed completion")
            );
            assert_eq!(record.ended_at, Some(42.0));
        }
    }
}

#[tokio::test]
async fn restart_preserves_identity_and_never_replays_delivery() {
    use std::os::unix::fs::PermissionsExt;
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("calls.json");
    let calls = AgentCalls::new(Some(path.clone()), None);
    let original = record("self");
    let seeded = original.clone();
    calls
        .update(move |store| {
            store.records.push(seeded);
            Ok(())
        })
        .await
        .unwrap();
    let host_id = calls.state.lock().await.host_id.clone();
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let restored = AgentCalls::new(Some(path), None);
    restored.load().await.unwrap();
    assert_eq!(restored.state.lock().await.host_id, host_id);
    let record = restored.get(&original.call_id).await.unwrap();
    assert_eq!(record.state, CallState::Unresolved);
    assert!(record.ended_at.is_some());
    assert!(restored.active().await.is_none());
}

#[tokio::test]
async fn failed_persistence_does_not_publish_a_state_transition() {
    let directory = tempfile::tempdir().unwrap();
    let not_directory = directory.path().join("file");
    std::fs::write(&not_directory, "not a directory").unwrap();
    let calls = AgentCalls::new(Some(not_directory.join("calls.json")), None);
    let original = record("self");
    calls.state.lock().await.records.push(original.clone());
    assert!(
        calls
            .change(&original.call_id, |record| {
                record.state = CallState::Ended;
                Ok(())
            })
            .await
            .is_err()
    );
    assert_eq!(
        calls.get(&original.call_id).await.unwrap().state,
        CallState::Requested
    );
}

#[tokio::test]
async fn both_stop_paths_drain_exact_media_even_if_call_persistence_fails() {
    for explicit_end in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let blocked = directory.path().join("not-a-directory");
        std::fs::write(&blocked, "occupied").unwrap();
        let gateway = gateway_with_state_path(Some(blocked.join("turn-state.json")));
        let mut original = record("self");
        original.state = CallState::Connected;
        original.media_client_id = Some(7);
        gateway
            .calls
            .state
            .lock()
            .await
            .records
            .push(original.clone());
        gateway.voice.seed(
            Some(VoiceSessionOwner {
                client_id: 7,
                realtime_session_id: original.call_id.clone(),
            }),
            Some(VoiceSession {
                owner_client_id: 7,
                realtime_session_id: original.call_id.clone(),
                realtime_thread_id: "realtime-owned".into(),
                conversation_thread_id: "thread-owned".into(),
                model: original.model.clone(),
                effort: original.effort.clone(),
                cwd: original.cwd.clone(),
                uses_external_executor: false,
                delegations: VoiceDelegations::new(),
                tail_flush_dispatched: false,
                greeted: false,
                farewell: None,
                started_at_unix_seconds: 0.0,
                log: None,
            }),
        );
        let mut out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
            .await
            .requests;
        let stop = async {
            if explicit_end {
                gateway
                    .end_agent_call(&original.call_id, "test end")
                    .await
                    .map(|_| ())
            } else {
                gateway.stop_voice_session(7).await.map(|_| ())
            }
        };
        let answer = async {
            let raw = tokio::time::timeout(Duration::from_secs(2), out_rx.recv())
                .await
                .unwrap()
                .unwrap();
            let request: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(request["method"], "thread/realtime/stop");
            assert_eq!(request["params"]["threadId"], "realtime-owned");
            gateway
                .handle_control_text(
                    json!({"id": request["id"], "result": {}}).to_string(),
                    CONTROL,
                )
                .await;
        };
        let (result, ()) = tokio::join!(stop, answer);
        assert!(result.is_err(), "persistence failure remains explicit");
        assert!(gateway.voice.owner().is_none());
        assert!(gateway.voice.is_draining());
    }
}

#[tokio::test]
async fn late_push_acknowledgment_failure_cannot_overwrite_native_evidence() {
    let gateway = gateway();
    let original = record("self");
    gateway
        .calls
        .state
        .lock()
        .await
        .records
        .push(original.clone());
    for state in [
        CallState::Ringing,
        CallState::Connecting,
        CallState::Connected,
    ] {
        gateway
            .calls
            .change(&original.call_id, move |record| {
                record.state = state;
                Ok(())
            })
            .await
            .unwrap();
        gateway
            .record_delivery_failure_awaiting_capacity(
                &original.call_id,
                "broker acknowledgment timeout",
            )
            .await
            .unwrap();
        assert_eq!(
            gateway.calls.get(&original.call_id).await.unwrap().state,
            state
        );
        assert!(gateway.calls.active().await.is_some());
    }
}

#[tokio::test]
async fn replacing_the_registered_device_does_not_ring_the_wrong_installation() {
    let gateway = gateway();
    let original = record("self");
    gateway
        .calls
        .state
        .lock()
        .await
        .records
        .push(original.clone());
    gateway
        .apns
        .devices()
        .register(crate::devices::fixture_registration(2))
        .await
        .unwrap();
    let error = gateway
        .deliver_native_call(&original.call_id)
        .await
        .unwrap_err();
    assert!(error.to_string().contains("enrollment changed"));
    assert_eq!(
        gateway.calls.get(&original.call_id).await.unwrap().state,
        CallState::Requested
    );
}

#[tokio::test]
async fn call_media_starts_after_an_earlier_voice_call_ended() {
    let gateway = gateway();
    gateway.voice.seed_ended_call("earlier-voice-call");
    let (client_tx, _client_rx) = tokio::sync::mpsc::channel(4);
    gateway
        .clients
        .insert(1, crate::gateway::tests::test_client(1, client_tx));
    let out_rx = crate::test_support::FakeControl::attach(&gateway, 4)
        .await
        .requests;
    let _captured = crate::gateway::tests::spawn_control_responder(&gateway, out_rx);
    let mut call = record("self");
    call.state = CallState::Connecting;
    call.media_client_id = Some(1);
    gateway.calls.state.lock().await.records.push(call.clone());

    gateway
        .start_call_media(1, call.clone(), "v=0\r\n".into(), None)
        .await
        .expect("an ended voice call does not block a new agent call");
    assert_eq!(
        gateway.voice.owner().map(|owner| owner.realtime_session_id),
        Some(call.call_id)
    );
}

#[tokio::test]
async fn late_call_media_waits_for_a_pending_compaction() {
    let gateway = gateway();
    let _compaction = gateway.admission.admit_compaction("thread-owned").unwrap();
    let error = gateway
        .start_call_media(1, record("self"), "offer".into(), None)
        .await
        .unwrap_err();
    assert!(error.to_string().contains("pending command"));
    assert!(gateway.voice.session().is_none());
    assert!(gateway.control_requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn duplicate_request_returns_original_without_preflight_or_delivery() {
    let gateway = gateway();
    let original = record("self");
    gateway
        .calls
        .state
        .lock()
        .await
        .records
        .push(original.clone());
    let caller = Caller {
        turn_id: None,
        provider: Provider::Codex,
        thread_id: Some("thread-owned".into()),
    };
    let result = gateway
        .request_agent_call(&caller, original.request.clone())
        .await
        .unwrap();
    assert_eq!(result["callId"], original.call_id);
    let mut changed = original.request.clone();
    changed.to = "+46000000001".into();
    assert!(
        gateway
            .request_agent_call(&caller, changed)
            .await
            .unwrap_err()
            .to_string()
            .contains("reused")
    );
    assert_eq!(gateway.calls.state.lock().await.records.len(), 1);
}

#[tokio::test]
async fn agent_controls_require_exact_thread_and_provider() {
    let gateway = gateway();
    let original = record("self");
    gateway
        .calls
        .state
        .lock()
        .await
        .records
        .push(original.clone());
    for caller in [
        Caller {
            turn_id: None,
            provider: Provider::Codex,
            thread_id: None,
        },
        Caller {
            turn_id: None,
            provider: Provider::Codex,
            thread_id: Some("other".into()),
        },
        Caller {
            turn_id: None,
            provider: Provider::Claude,
            thread_id: Some("thread-owned".into()),
        },
    ] {
        for error in [
            gateway
                .agent_call_status(&caller, &original.call_id)
                .await
                .err(),
            gateway
                .end_call_for_agent(&caller, &original.call_id)
                .await
                .err(),
            gateway
                .steer_call_for_agent(&caller, &original.call_id, "hello")
                .await
                .err(),
        ] {
            assert_eq!(
                error.map(|error| error.to_string()).as_deref(),
                Some("call belongs to another conversation")
            );
        }
    }
    assert_eq!(
        gateway.calls.get(&original.call_id).await.unwrap().state,
        CallState::Requested
    );
}

#[tokio::test]
async fn wrong_device_expired_and_duplicate_answer_never_start_media() {
    let gateway = gateway();
    let mut original = record("self");
    original.state = CallState::Ringing;
    gateway
        .calls
        .state
        .lock()
        .await
        .records
        .push(original.clone());
    for (device, state, expiry, expected) in [
        (
            "wrong",
            CallState::Ringing,
            unix_seconds() + 60.0,
            "call belongs to another device",
        ),
        ("device-one", CallState::Ringing, 0.0, "call expired"),
        (
            "device-one",
            CallState::Connecting,
            unix_seconds() + 60.0,
            "call is no longer answerable",
        ),
        (
            "device-one",
            CallState::Ended,
            unix_seconds() + 60.0,
            "call is no longer answerable",
        ),
    ] {
        gateway
            .calls
            .change(&original.call_id, move |record| {
                record.state = state;
                record.expires_at = expiry;
                Ok(())
            })
            .await
            .unwrap();
        let error = gateway
            .answer_agent_call(
                8,
                AnswerCall {
                    call_id: original.call_id.clone(),
                    device_id: device.into(),
                    realtime_session_id: original.call_id.clone(),
                    sdp: "offer".into(),
                    voice: None,
                },
            )
            .await
            .unwrap_err();
        assert_eq!(error.to_string(), expected);
        assert!(gateway.voice.session().is_none());
    }
}

#[tokio::test]
async fn telephone_end_waits_for_carrier_confirmation_and_old_ids_do_not_end_new_calls() {
    let gateway = gateway();
    let original = record("+46000001709");
    gateway
        .calls
        .state
        .lock()
        .await
        .records
        .push(original.clone());
    let ending = gateway
        .end_agent_call(&original.call_id, "agent ended")
        .await
        .unwrap();
    assert_eq!(ending.state, CallState::Ending);
    assert!(ending.ended_at.is_none());
    gateway
        .calls
        .change(&original.call_id, |record| {
            record.state = CallState::Ended;
            Ok(())
        })
        .await
        .unwrap();
    let newer = record("self");
    crate::test_support::seed_call(&gateway, newer.clone()).await;
    gateway
        .end_agent_call(&original.call_id, "late retry")
        .await
        .unwrap();
    assert_eq!(
        gateway.calls.get(&newer.call_id).await.unwrap().state,
        CallState::Requested
    );
}

#[tokio::test]
async fn carrier_event_needs_media_owner_and_matching_submission() {
    let gateway = gateway();
    let mut original = record("+46000001709");
    original.state = CallState::Connecting;
    original.media_client_id = Some(7);
    original.delivery_receipt = Some("cowned".into());
    gateway
        .calls
        .state
        .lock()
        .await
        .records
        .push(original.clone());
    for (client, provider_id, provider_state) in [
        (8, "cowned", "success"),
        (7, "cforeign", "success"),
        (7, "cowned", "ongoing"),
    ] {
        assert!(gateway.record_media_event(client, json!({
            "callId": original.call_id, "event": "completed", "providerCallId": provider_id, "providerState": provider_state,
        })).await.is_err());
    }
    assert_eq!(
        gateway.calls.get(&original.call_id).await.unwrap().state,
        CallState::Connecting
    );
}

#[test]
fn brief_validates_recipient_and_diagnostics_do_not_include_it() {
    let mut original = record("+46000001709");
    original.request.validate().unwrap();
    assert_eq!(original.status()["recipient"], "…1709");
    assert!(!original.status().to_string().contains("+46000001709"));
    for to in ["+1", "+4600000abc", "self ", "04600001709"] {
        original.request.to = to.into();
        assert!(original.request.validate().is_err());
    }
}

#[tokio::test]
async fn a_cancelled_call_transaction_still_commits_and_publishes_in_order() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("calls.json");
    let calls = Arc::new(AgentCalls::new(Some(path.clone()), None));
    let original = record("self");
    let seeded = original.clone();
    calls
        .update(move |store| {
            store.records.push(seeded);
            Ok(())
        })
        .await
        .unwrap();

    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path.with_extension("lock"))
        .unwrap();
    lock.lock().unwrap();
    let cancelled = tokio::time::timeout(
        Duration::from_millis(50),
        calls.change(&original.call_id, |record| {
            record.state = CallState::Ended;
            Ok(())
        }),
    )
    .await;
    assert!(
        cancelled.is_err(),
        "the transaction is blocked on the file lock"
    );
    assert!(
        calls.state.try_lock().is_err(),
        "the worker keeps the transaction after its caller is gone"
    );
    let competing = tokio::spawn({
        let calls = Arc::clone(&calls);
        let call_id = original.call_id.clone();
        async move {
            calls
                .change(&call_id, |record| {
                    record.reason = Some("competing".into());
                    Ok(())
                })
                .await
        }
    });
    drop(lock);

    let competing = competing.await.unwrap().unwrap();
    assert_eq!(competing.state, CallState::Ended);
    assert_eq!(competing.reason.as_deref(), Some("competing"));
    let restored = AgentCalls::new(Some(path), None);
    restored.load().await.unwrap();
    let restored = restored.get(&original.call_id).await.unwrap();
    assert_eq!(restored.state, CallState::Ended);
    assert_eq!(restored.reason.as_deref(), Some("competing"));
}

#[test]
fn admission_prunes_old_and_excess_terminal_records_but_never_a_live_call() {
    let now = unix_seconds();
    let mut store = CallStore::default();
    let mut old = record("self");
    old.state = CallState::Ended;
    old.created_at = now - RECORD_RETENTION_SECONDS - 1.0;
    let mut live = record("self");
    live.created_at = now - RECORD_RETENTION_SECONDS - 1.0;
    store.records = vec![old.clone(), live.clone()];
    for _ in 0..MAXIMUM_RECORDS {
        let mut ended = record("self");
        ended.state = CallState::Ended;
        store.records.push(ended);
    }
    let newest = record("self");
    store.admit(newest.clone(), now).unwrap();
    assert_eq!(store.records.len(), MAXIMUM_RECORDS);
    assert!(
        store
            .records
            .iter()
            .all(|record| record.call_id != old.call_id)
    );
    assert!(
        store
            .records
            .iter()
            .any(|record| record.call_id == live.call_id)
    );
    assert_eq!(store.records.last().unwrap().call_id, newest.call_id);

    store.records = (0..MAXIMUM_RECORDS).map(|_| record("self")).collect();
    assert!(store.admit(record("self"), now).is_err());
    assert_eq!(store.records.len(), MAXIMUM_RECORDS);
}

#[tokio::test]
async fn an_invalid_call_store_fails_to_load_and_stays_untouched() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("calls.json");
    let mut store = CallStore::default();
    let mut invalid = record("self");
    invalid.request.to = "not a recipient".into();
    store.records.push(invalid);
    let bytes = serde_json::to_vec(&store).unwrap();
    std::fs::write(&path, &bytes).unwrap();

    let calls = AgentCalls::new(Some(path.clone()), None);
    assert!(calls.load().await.is_err());
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
}

#[tokio::test]
async fn a_worker_diagnostic_is_bounded_before_it_is_buffered() {
    use super::delivery::read_diagnostic_line;
    let mut pending = Vec::new();
    let mut reader = &b"{\"event\":\"a\"}\n{\"event\":\"b\"}"[..];
    assert_eq!(
        read_diagnostic_line(&mut reader, &mut pending)
            .await
            .unwrap()
            .as_deref(),
        Some(&b"{\"event\":\"a\"}"[..])
    );
    assert_eq!(
        read_diagnostic_line(&mut reader, &mut pending)
            .await
            .unwrap()
            .as_deref(),
        Some(&b"{\"event\":\"b\"}"[..])
    );
    assert!(
        read_diagnostic_line(&mut reader, &mut pending)
            .await
            .unwrap()
            .is_none()
    );

    let unterminated = vec![b'x'; 9_000];
    let mut reader = &unterminated[..];
    let error = read_diagnostic_line(&mut reader, &mut pending)
        .await
        .unwrap_err();
    assert!(error.to_string().contains("oversized"));
}

#[test]
fn telephone_worker_handoff_uses_the_active_tls_identity_and_exact_account_route() {
    let mut delivery: CallDeliveryConfig = serde_json::from_value(json!({
        "originGatewayUrl": "ws://origin.fixture.ts.net:8787/ws",
        "workerHost": "worker-fixture",
        "workerPath": "/fixture/agent-call",
        "workerConfigPath": "/fixture/carrier.json"
    }))
    .expect("delivery fixture");
    delivery.gateway_token = "synthetic".into();
    let mut account = delivery.clone();
    account
        .origin_gateway_url
        .push_str("?accountId=owned&accountGeneration=7");
    assert!(account.worker_connection().is_err());
    delivery
        .tls_endpoint
        .set(LanEndpoint {
            host: "origin.fixture.local".into(),
            port: 8789,
            spki_sha256: "synthetic-pin".into(),
        })
        .expect("active TLS listener");
    assert_eq!(
        account.worker_connection().expect("worker handoff"),
        json!({
            "wsUrl": "wss://origin.fixture.ts.net:8789/ws?accountId=owned&accountGeneration=7",
            "bearer": "synthetic",
            "tlsIdentity": {"serverName": "origin.fixture.local", "spkiSha256": "synthetic-pin"}
        })
    );
}
