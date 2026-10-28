use super::*;
use crate::agents::jobs::model::*;
use crate::test_support::TestGateway;

fn request(target: MessageTarget, id: &str, text: &str) -> serde_json::Value {
    json!(MessageParams {
        target,
        caller: Caller::Operator,
        delivery_id: id.into(),
        text: text.into()
    })
}

#[tokio::test]
async fn missing_target_has_a_durable_failure_receipt_and_conflicting_retry_is_rejected() {
    let gateway = TestGateway::new();
    let target = MessageTarget::Selector {
        selector: "agent-claude-1793127141860775000-00000001".into(),
    };
    let params = request(target, "missing-delivery", "original message");
    let first = gateway
        .agent_jobs_rpc("agent/jobs/message", params.clone())
        .await
        .unwrap();
    assert_eq!(first["deliveryId"], "missing-delivery");
    assert_eq!(first["deliveryState"]["kind"], "failed");
    assert!(
        first["deliveryState"]["reason"]
            .as_str()
            .unwrap()
            .contains("does not exist")
    );
    let reason = first["deliveryState"]["reason"].as_str().unwrap();
    assert!(reason.contains("host:id or --host"));
    assert_eq!(
        gateway
            .agent_jobs_rpc(
                "agent/messages/read",
                json!({"deliveryId":"missing-delivery"})
            )
            .await
            .unwrap(),
        first
    );
    assert_eq!(
        gateway
            .agent_jobs_rpc("agent/jobs/message", params.clone())
            .await
            .unwrap(),
        first
    );
    let mut changed = params;
    changed["text"] = json!("different message");
    assert_eq!(
        gateway
            .agent_jobs_rpc("agent/jobs/message", changed)
            .await
            .unwrap_err()
            .code,
        RpcCode::Conflict
    );
}

async fn terminal_job(gateway: &Gateway, outcome: JobOutcome) -> JobId {
    let id = JobId::for_mutation(Provider::Claude, "finished-source").unwrap();
    let admitted = gateway
        .jobs
        .start(
            StartParams {
                job_id: id.clone(),
                spec: JobSpec {
                    prompt: "Completed fixture invocation".into(),
                    cwd: std::env::temp_dir(),
                    settings: ExecutionSettings::Claude {
                        model: "opus".into(),
                        effort: Some("xhigh".into()),
                        fast: false,
                    },
                    tool_scope: ToolScope::ReadOnly {
                        root: std::env::temp_dir(),
                    },
                    title: Some("Fixture".into()),
                },
                caller: Caller::Operator,
            },
            Origin::TopLevel,
        )
        .await
        .unwrap();
    let store = gateway.jobs.store().await.unwrap();
    let bound = store
        .bind(
            id.clone(),
            admitted.job.revision,
            gateway.job_new_claude_conversation().unwrap(),
            now_ms(),
        )
        .await
        .unwrap();
    store
        .advance(
            id.clone(),
            bound.revision,
            ExecutionState::Terminal {
                terminal: Terminal {
                    at_ms: Some(now_ms()),
                    execution: None,
                    git: GitSnapshot::Unknown {
                        reason: "test fixture does not read Git".into(),
                    },
                    outcome,
                    result: ResultEvidence::Available {
                        result: JobResult {
                            text: "Completed fixture result".into(),
                            truncated: false,
                        },
                    },
                    completion: Completion::NotRequired,
                    cleanup: CleanupState::Complete,
                },
            },
            now_ms(),
        )
        .await
        .unwrap();
    id
}

async fn finished_job(gateway: &Gateway) -> JobId {
    terminal_job(gateway, JobOutcome::Completed).await
}

#[tokio::test]
async fn messages_cannot_clear_stop_but_explicit_continue_remains_deliberate() {
    let gateway = TestGateway::new();
    let previous = terminal_job(
        &gateway,
        JobOutcome::Stopped {
            effects: EffectEvidence::MayHaveRun,
        },
    )
    .await;
    let response = gateway
        .agent_jobs_rpc(
            "agent/jobs/message",
            request(
                MessageTarget::Job {
                    job_id: previous.clone(),
                },
                "stopped-delivery",
                "Do more work",
            ),
        )
        .await
        .unwrap();
    assert_eq!(response["deliveryState"]["kind"], "failed");
    assert!(
        response["deliveryState"]["reason"]
            .as_str()
            .unwrap()
            .contains("cannot clear Stop")
    );
    let view = gateway.jobs.read(&previous).await.unwrap();
    let explicit = gateway
        .jobs
        .continue_job(
            ContinueParams {
                job_id: JobId::for_mutation(Provider::Claude, "explicit-after-stop").unwrap(),
                agent_id: view.job.agent_id,
                prompt: "Deliberately restart".into(),
                settings: None,
                expected_previous_job_id: Some(previous),
                intent: ContinueIntent::Explicit,
                recipient: ContinueRecipient::Previous,
                caller: Caller::Operator,
            },
            Origin::TopLevel,
        )
        .await
        .unwrap();
    assert!(matches!(explicit.job.execution, ExecutionState::Admitted));
}

#[tokio::test]
async fn finished_message_admits_one_exact_continuation_and_duplicate_keeps_its_receipt() {
    let gateway = TestGateway::new();
    let previous = finished_job(&gateway).await;
    let params = request(
        MessageTarget::Job {
            job_id: previous.clone(),
        },
        "continue-delivery",
        "Additional work",
    );
    let (first, duplicate) = tokio::join!(
        gateway.agent_jobs_rpc("agent/jobs/message", params.clone()),
        gateway.agent_jobs_rpc("agent/jobs/message", params.clone())
    );
    let first = first.unwrap();
    assert_eq!(first, duplicate.unwrap());
    assert_eq!(first["deliveryState"]["kind"], "accepted", "{first:#}");
    let id: JobId =
        serde_json::from_value(first["resolved"]["continuation"]["jobId"].clone()).unwrap();
    assert_eq!(
        id,
        JobId::for_mutation(Provider::Claude, "continue-delivery").unwrap()
    );
    let continued = gateway.jobs.read(&id).await.unwrap();
    assert_eq!(continued.job.previous_job_id, Some(previous.clone()));
    assert!(matches!(continued.job.execution, ExecutionState::Admitted));
    assert_eq!(
        continued.agent.unwrap().tool_scope,
        Some(ToolScope::ReadOnly {
            root: std::env::temp_dir()
        })
    );
    assert_eq!(
        gateway
            .agent_jobs_rpc("agent/jobs/message", params)
            .await
            .unwrap(),
        first
    );
    let stale = gateway
        .agent_jobs_rpc(
            "agent/jobs/message",
            request(
                MessageTarget::Job { job_id: previous },
                "different-delivery",
                "A stale follow-up",
            ),
        )
        .await
        .unwrap();
    assert_eq!(stale["deliveryState"]["kind"], "failed");
    assert!(
        stale["deliveryState"]["reason"]
            .as_str()
            .unwrap()
            .contains("superseded")
    );
}

#[tokio::test]
async fn concurrent_different_messages_cannot_continue_a_newer_invocation() {
    let gateway = TestGateway::new();
    let previous = finished_job(&gateway).await;
    let first = request(
        MessageTarget::Job {
            job_id: previous.clone(),
        },
        "racing-first",
        "First follow-up",
    );
    let second = request(
        MessageTarget::Job {
            job_id: previous.clone(),
        },
        "racing-second",
        "Second follow-up",
    );
    let (first, second) = tokio::join!(
        gateway.agent_jobs_rpc("agent/jobs/message", first),
        gateway.agent_jobs_rpc("agent/jobs/message", second)
    );
    let responses = [first.unwrap(), second.unwrap()];
    assert_eq!(
        responses
            .iter()
            .filter(|response| response["deliveryState"]["kind"] == "accepted")
            .count(),
        1
    );
    for response in responses
        .iter()
        .filter(|response| response["deliveryState"]["kind"] != "accepted")
    {
        assert!(matches!(
            response["deliveryState"]["kind"].as_str(),
            Some("failed" | "blocked")
        ));
        let reason = response["deliveryState"]["reason"].as_str().unwrap();
        assert!(reason.contains("superseded") || reason.contains("unresolved runtime job"));
    }
    let jobs = gateway
        .jobs
        .store()
        .await
        .unwrap()
        .list(crate::agents::jobs::store::Selection::Recent, 200, None)
        .await
        .unwrap();
    assert_eq!(jobs.jobs.len(), 2);
}

#[tokio::test]
async fn noncanonical_native_selector_keeps_provider_identity_unknown() {
    let gateway = TestGateway::new();
    let response = gateway
        .agent_jobs_rpc(
            "agent/jobs/message",
            request(
                MessageTarget::Selector {
                    selector: "not-a-native-thread".into(),
                },
                "unknown-native-provider",
                "Read-only fixture message",
            ),
        )
        .await
        .unwrap();
    assert_eq!(response["deliveryState"]["kind"], "failed");
    let reason = response["deliveryState"]["reason"].as_str().unwrap();
    assert!(reason.contains("provider is unknown"));
    assert!(reason.contains("canonical Codex UUID or claude_UUID"));
    assert!(response["resolved"].is_null());
    assert_eq!(
        gateway
            .agent_jobs_rpc(
                "agent/messages/read",
                json!({"deliveryId":"unknown-native-provider"})
            )
            .await
            .unwrap(),
        response
    );
}

#[tokio::test]
async fn canceled_message_caller_cannot_release_execution_before_provider_admission() {
    use crate::test_support::FakeControl;
    for stop_requested in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().canonicalize().unwrap();
        let gateway = TestGateway::with_native_runtime(&root);
        let store = gateway.jobs.store().await.unwrap();
        let id = JobId::for_mutation(Provider::Codex, "running-message-target").unwrap();
        let admitted = gateway
            .jobs
            .start(
                StartParams {
                    job_id: id.clone(),
                    spec: JobSpec {
                        prompt: "running fixture".into(),
                        cwd: directory.path().into(),
                        settings: ExecutionSettings::Codex {
                            model: "fixture".into(),
                            model_provider: "openai".into(),
                            effort: "medium".into(),
                            service_tier: None,
                            cyber_access_program: None,
                        },
                        tool_scope: ToolScope::Full,
                        title: None,
                    },
                    caller: Caller::Operator,
                },
                Origin::TopLevel,
            )
            .await
            .unwrap();
        let conversation = ConversationIdentity {
            provider: Provider::Codex,
            provider_home: ProviderHome::Known {
                path: gateway.job_codex_home().unwrap(),
            },
            thread_id: "11111111-2222-4333-8444-555555555555".into(),
        };
        let bound = store
            .bind(
                id.clone(),
                admitted.job.revision,
                conversation.clone(),
                now_ms(),
            )
            .await
            .unwrap();
        let input_id = bound.initial_input_id();
        let dispatching = store
            .advance(
                id.clone(),
                bound.revision,
                ExecutionState::Dispatching {
                    conversation: conversation.clone(),
                    input_id: input_id.clone(),
                },
                now_ms(),
            )
            .await
            .unwrap();
        let binding = ExecutionBinding {
            conversation,
            input_id,
            turn_id: "original-turn".into(),
        };
        let running = store
            .advance(
                id.clone(),
                dispatching.revision,
                ExecutionState::Running {
                    binding: binding.clone(),
                },
                now_ms(),
            )
            .await
            .unwrap();
        let mut control = FakeControl::attach(&gateway, 16).await;
        let sender = gateway.clone();
        let target = id.clone();
        let mut caller = tokio::spawn(async move {
            sender
                .agent_jobs_rpc(
                    "agent/jobs/message",
                    request(
                        MessageTarget::Job { job_id: target },
                        "fenced-delivery",
                        "frozen input",
                    ),
                )
                .await
        });
        let raw = tokio::select! {
            result = &mut caller => panic!("message returned before provider admission: {result:?}"),
            request = control.requests.recv() => request.unwrap(),
        };
        let rpc: serde_json::Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(rpc["method"], "thread/input/acceptance/read");
        caller.abort();
        assert!(caller.await.unwrap_err().is_cancelled());
        let current = if stop_requested {
            let stopped = store
                .request_stop(id.clone(), "stop-during-admission".into(), now_ms())
                .await
                .unwrap();
            assert!(matches!(stopped.stop, StopState::Requested { .. }));
            stopped
        } else {
            running.clone()
        };
        let finishing = store.advance(
            id.clone(),
            current.revision,
            ExecutionState::Terminal {
                terminal: Terminal {
                    at_ms: Some(now_ms()),
                    execution: Some(binding),
                    git: GitSnapshot::Unknown {
                        reason: "fixture".into(),
                    },
                    outcome: if stop_requested {
                        JobOutcome::Stopped {
                            effects: EffectEvidence::MayHaveRun,
                        }
                    } else {
                        JobOutcome::Completed
                    },
                    result: ResultEvidence::Unavailable {
                        reason: "fixture".into(),
                    },
                    completion: Completion::NotRequired,
                    cleanup: CleanupState::Complete,
                },
            },
            now_ms(),
        );
        tokio::pin!(finishing);
        tokio::select! {
            biased;
            result = &mut finishing => panic!("terminal transition overtook provider admission: {result:?}"),
            () = std::future::ready(()) => {}
        }
        assert_eq!(
            store.read(id.clone()).await.unwrap().execution,
            running.execution
        );
        gateway.control_requests.lock().unwrap().remove(rpc["id"].as_str().unwrap()).unwrap().send(Ok(json!({"acceptance": {"turnId":"original-turn","rootTurnId":"original-turn","fingerprint":"a".repeat(64),"facts":["recorded"]}}))).unwrap();
        let terminal = finishing.await.unwrap();
        assert!(matches!(
            terminal.execution,
            ExecutionState::Terminal { .. }
        ));
        let successor = JobId::for_mutation(Provider::Codex, "after-admission").unwrap();
        let continued = gateway
            .jobs
            .continue_job(
                ContinueParams {
                    job_id: successor.clone(),
                    agent_id: terminal.agent_id,
                    prompt: "explicit continuation".into(),
                    settings: None,
                    expected_previous_job_id: Some(id.clone()),
                    intent: ContinueIntent::Explicit,
                    recipient: ContinueRecipient::Previous,
                    caller: Caller::Operator,
                },
                Origin::TopLevel,
            )
            .await
            .unwrap();
        assert_eq!(continued.job.previous_job_id, Some(id.clone()));
        let receipt = gateway
            .agent_jobs_rpc(
                "agent/jobs/message",
                request(
                    MessageTarget::Job { job_id: id.clone() },
                    "fenced-delivery",
                    "frozen input",
                ),
            )
            .await
            .unwrap();
        assert_eq!(receipt["resolved"]["targetJobId"], id.as_str());
        assert_eq!(receipt["deliveryState"]["kind"], "recorded");
        assert!(matches!(
            control.requests.try_recv(),
            Err(tokio::sync::mpsc::error::TryRecvError::Empty)
        ));
    }
}

#[tokio::test]
async fn bare_codex_uuid_never_resolves_a_registered_claude_short_uuid() {
    use crate::test_support::FakeControl;
    let gateway = TestGateway::new();
    let claude_job = finished_job(&gateway).await;
    let view = gateway.jobs.read(&claude_job).await.unwrap();
    let ConversationBinding::Known { conversation } = view.agent.unwrap().conversation else {
        panic!("Fixture has no conversation")
    };
    let uuid = conversation.thread_id.strip_prefix("claude_").unwrap();
    let home = gateway.job_codex_home().unwrap();
    let mut control = FakeControl::attach(&gateway, 2).await.requests;
    for selector in [uuid.to_owned(), format!("codex:{uuid}")] {
        let owner = gateway.clone();
        let task = tokio::spawn(async move {
            owner
                .resolve_message_selector(&selector, "fixture-id")
                .await
        });
        let request: serde_json::Value =
            serde_json::from_str(&control.recv().await.unwrap()).unwrap();
        assert_eq!(request["method"], "thread/read");
        assert_eq!(request["params"]["threadId"], uuid);
        gateway
            .control_requests
            .lock()
            .unwrap()
            .remove(request["id"].as_str().unwrap())
            .unwrap()
            .send(Ok(
                json!({"thread":{"id":uuid,"path":home.join("sessions/fixture.jsonl")}}),
            ))
            .unwrap();
        let resolved = task.await.unwrap().unwrap();
        assert_eq!(resolved.conversation.provider, Provider::Codex);
        assert_eq!(resolved.conversation.thread_id, uuid);
        assert!(resolved.target_job_id.is_none());
    }
    let owner = gateway.clone();
    let selector = uuid.to_owned();
    let task = tokio::spawn(async move {
        owner
            .resolve_message_selector(&selector, "fixture-id")
            .await
    });
    let request: serde_json::Value = serde_json::from_str(&control.recv().await.unwrap()).unwrap();
    gateway.control_requests.lock().unwrap().remove(request["id"].as_str().unwrap()).unwrap()
        .send(Ok(json!({"thread":{"id":conversation.thread_id,"path":"/fixture/claude/projects/session.jsonl"}}))).unwrap();
    assert!(
        task.await
            .unwrap()
            .unwrap_err()
            .to_string()
            .contains("different native conversation")
    );
}

#[tokio::test]
async fn missing_native_target_retains_peer_route_guidance_without_peer_discovery() {
    use crate::test_support::FakeControl;
    let gateway = TestGateway::new();
    let mut control = FakeControl::attach(&gateway, 1).await.requests;
    let owner = gateway.clone();
    let caller = tokio::spawn(async move {
        owner
            .agent_jobs_rpc(
                "agent/jobs/message",
                request(
                    MessageTarget::Selector {
                        selector: "11111111-1111-4111-8111-111111111111".into(),
                    },
                    "missing-native-peer",
                    "Fixture message",
                ),
            )
            .await
    });
    let request: serde_json::Value = serde_json::from_str(&control.recv().await.unwrap()).unwrap();
    assert_eq!(request["method"], "thread/read");
    gateway
        .control_requests
        .lock()
        .unwrap()
        .remove(request["id"].as_str().unwrap())
        .unwrap()
        .send(Err(
            json!({"code":-32600,"message":"thread is not present in this native home"})
                .to_string(),
        ))
        .unwrap();
    let receipt = caller.await.unwrap().unwrap();
    assert_eq!(receipt["deliveryId"], "missing-native-peer");
    assert_eq!(receipt["deliveryState"]["kind"], "failed");
    let reason = receipt["deliveryState"]["reason"].as_str().unwrap();
    assert!(reason.contains("thread is not present in this native home"));
    assert!(reason.contains("host:id or --host"));
    assert!(receipt["resolved"].is_null());
    assert_eq!(
        gateway
            .agent_jobs_rpc(
                "agent/messages/read",
                json!({"deliveryId":"missing-native-peer"})
            )
            .await
            .unwrap(),
        receipt
    );
    assert!(matches!(
        control.try_recv(),
        Err(tokio::sync::mpsc::error::TryRecvError::Empty)
    ));
}
