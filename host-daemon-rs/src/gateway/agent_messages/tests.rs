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
            gateway.job_new_claude_conversation(),
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
    assert_eq!(first["deliveryState"]["kind"], "accepted");
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
