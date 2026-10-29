use super::{TestSocket, connect_client, next_json, send_json};
use crate::agents::jobs::model::*;
use crate::test_support::TestGateway;
use serde_json::{Value, json};

fn root(gateway: &TestGateway) -> &std::path::Path {
    gateway.turn_state_path.as_ref().unwrap().parent().unwrap()
}

async fn request(socket: &mut TestSocket, method: &str, params: Value) -> Value {
    send_json(socket, json!({"id":1,"method":method,"params":params})).await;
    loop {
        let response = next_json(socket).await;
        if response["id"] == 1 {
            return response;
        }
    }
}

fn spec(root: &std::path::Path) -> JobSpec {
    JobSpec {
        prompt: "Read the fixture".into(),
        cwd: root.into(),
        settings: ExecutionSettings::Codex {
            model: "gpt-6.1-sol".into(),
            model_provider: "openai".into(),
            effort: "medium".into(),
            service_tier: None,
            cyber_access_program: None,
        },
        tool_scope: ToolScope::Full,
        title: None,
    }
}

async fn completed_agent(host: &TestGateway, name: &str, scope: ToolScope) -> JobRecord {
    let mut job_spec = spec(root(host));
    job_spec.tool_scope = scope;
    let admitted = host
        .jobs
        .start(
            crate::wire::agent_jobs::StartParams {
                job_id: JobId::for_mutation(Provider::Codex, name).unwrap(),
                spec: job_spec,
                caller: crate::wire::agent_jobs::Caller::Operator,
            },
            Origin::TopLevel,
        )
        .await
        .unwrap();
    let at_ms = admitted.job.updated_at_ms;
    let store = host.jobs.store().await.unwrap();
    let bound = store
        .bind(
            admitted.job.job_id,
            admitted.job.revision,
            host.agent_conversation(&crate::ids::new_session_uuid())
                .unwrap(),
            at_ms,
        )
        .await
        .unwrap();
    store
        .advance(
            bound.job_id,
            bound.revision,
            ExecutionState::Terminal {
                terminal: Terminal {
                    at_ms: Some(at_ms + 1),
                    execution: None,
                    git: GitSnapshot::Unknown {
                        reason: "fixture".into(),
                    },
                    outcome: JobOutcome::Completed,
                    result: ResultEvidence::Available {
                        result: JobResult {
                            text: "Fixture result".into(),
                            truncated: false,
                        },
                    },
                    completion: Completion::NotRequired,
                    cleanup: CleanupState::Complete,
                },
            },
            at_ms + 1,
        )
        .await
        .unwrap()
}

fn dispatch(host: &str, method: &str, request: Value, caller: Value) -> Value {
    json!({"host":host,"method":method,"request":request,"caller":caller})
}

#[tokio::test]
async fn cluster_self_dispatch_uses_local_list_read_message_and_errors() {
    let directory = tempfile::tempdir().unwrap();
    let host = TestGateway::with_native_runtime(&directory.path().canonicalize().unwrap());
    *host.control_init_result.lock().await = Some(json!({}));
    let job = completed_agent(&host, "self-address", ToolScope::Full).await;
    let identity = host.host_identity().await.unwrap();
    let caller = json!({"kind":"operator"});
    let (mut socket, server) = connect_client(&host).await;
    assert_eq!(next_json(&mut socket).await["method"], "daemon/ready");
    for (method, params) in [
        (
            "agent/jobs/list",
            json!({"selector":{"kind":"recent"},"limit":10}),
        ),
        ("agent/jobs/read", json!({"jobId":job.job_id})),
        (
            "agent/cluster/resolve",
            json!({"target":job.job_id,"local":true}),
        ),
        (
            "agent/jobs/message",
            json!({"target":{"kind":"job","jobId":job.job_id},"caller":caller,"deliveryId":"self-message","text":"Continue fixture work"}),
        ),
    ] {
        let addressed = request(
            &mut socket,
            "agent/cluster/dispatch",
            dispatch(&identity.host_id, method, params.clone(), caller.clone()),
        )
        .await;
        let local = request(&mut socket, method, params).await;
        assert_eq!(addressed, local, "{method}");
        assert!(addressed.get("error").is_none(), "{method}: {addressed}");
        if method == "agent/jobs/message" {
            assert_eq!(
                addressed["result"]["deliveryState"]["kind"], "accepted",
                "{addressed}"
            );
            assert_eq!(addressed["result"]["sender"]["kind"], "topLevel");
        }
    }
    let nested = request(
        &mut socket,
        "agent/cluster/dispatch",
        dispatch(
            &identity.host_id,
            "agent/cluster/dispatch",
            dispatch(
                &identity.host_id,
                "agent/jobs/read",
                json!({"jobId":job.job_id}),
                caller.clone(),
            ),
            caller.clone(),
        ),
    )
    .await;
    assert_eq!(nested["result"]["job"]["jobId"], job.job_id.as_str());
    let params = json!({"jobId":"invalid"});
    let addressed = request(
        &mut socket,
        "agent/cluster/dispatch",
        dispatch(&identity.host_id, "agent/jobs/read", params.clone(), caller),
    )
    .await;
    let direct = request(&mut socket, "agent/jobs/read", params).await;
    assert_eq!(addressed, direct);
    assert_eq!(addressed["error"]["code"], -32602);
    socket.close(None).await.unwrap();
    server.abort();
    assert!(
        host.jobs
            .store()
            .await
            .unwrap()
            .intents()
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn cluster_self_dispatch_preserves_captured_read_only_caller() {
    let directory = tempfile::tempdir().unwrap();
    let host = TestGateway::with_native_runtime(&directory.path().canonicalize().unwrap());
    *host.control_init_result.lock().await = Some(json!({}));
    let scope = ToolScope::ReadOnly {
        root: root(&host).into(),
    };
    let parent = completed_agent(&host, "scoped-self-parent", scope.clone()).await;
    let target = completed_agent(&host, "full-self-target", ToolScope::Full).await;
    let ConversationBinding::Known { conversation } = host
        .jobs
        .read(&parent.job_id)
        .await
        .unwrap()
        .agent
        .unwrap()
        .conversation
    else {
        panic!("parent conversation is unresolved")
    };
    let caller_thread = conversation.thread_id.clone();
    let pid = std::process::id() as i32;
    let process = crate::platform::process::identify(pid).unwrap().unwrap();
    let mut control = crate::test_support::FakeControl::attach(&host, 16).await;
    let gateway = host.clone();
    let responder = tokio::spawn(async move {
        while let Some(raw) = control.requests.recv().await {
            let request: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(request["method"], "daemon/toolContext");
            gateway.control_requests.lock().unwrap().remove(request["id"].as_str().unwrap()).unwrap()
                .send(Ok(json!({"context":{"threadId":caller_thread,"turnId":"fixture-turn","toolCallId":"fixture-tool","rootProcessIdentity":{"pid":pid,"startedAtUnixMicros":process.started_micros}}}))).unwrap();
        }
    });
    let (mut socket, server) = connect_client(&host).await;
    assert_eq!(next_json(&mut socket).await["method"], "daemon/ready");
    let captured = request(
        &mut socket,
        "agent/context/capture",
        json!({"pid":pid,"startedAtUnixMicros":process.started_micros}),
    )
    .await;
    assert!(captured.get("error").is_none(), "{captured}");
    let caller = json!({"kind":"captured","contextId":captured["result"]["contextId"]});
    let identity = host.host_identity().await.unwrap();

    let params = json!({"target":{"kind":"job","jobId":target.job_id},"caller":caller,"deliveryId":"scoped-self-message","text":"Must remain scoped"});
    let direct = request(&mut socket, "agent/jobs/message", params.clone()).await;
    let addressed = request(
        &mut socket,
        "agent/cluster/dispatch",
        dispatch(
            &identity.host_id,
            "agent/jobs/message",
            params,
            json!({"kind":"operator"}),
        ),
    )
    .await;
    assert_eq!(addressed, direct);
    assert!(
        addressed["error"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("read-only caller cannot steer")),
        "{addressed}"
    );
    let child = JobId::for_mutation(Provider::Codex, "scoped-self-child").unwrap();
    let started = request(
        &mut socket,
        "agent/cluster/dispatch",
        dispatch(
            &identity.host_id,
            "agent/jobs/start",
            json!({"jobId":child,"spec":spec(root(&host)),"caller":caller}),
            caller,
        ),
    )
    .await;
    assert!(started.get("error").is_none(), "{started}");
    let child = host.jobs.read(&child).await.unwrap();
    let SpecEvidence::Known { spec } = child.job.spec else {
        panic!("missing child spec")
    };
    assert_eq!(spec.tool_scope, scope);
    assert_eq!(child.agent.unwrap().origin, Origin::Parent { conversation });
    socket.close(None).await.unwrap();
    server.abort();
    responder.abort();
    let _ = responder.await;
}
