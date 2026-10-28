use super::*;
use crate::agents::jobs::model::JobId;
use crate::agents::jobs::model::*;
use crate::agents::jobs::routes::{legacy_socket, scoped_socket};
use crate::test_support::{FakeControl, TestGateway};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

async fn register_job(gateway: &Gateway, sequence: u8, previous: Option<&JobRecord>) -> JobRecord {
    let id = JobId::for_mutation(Provider::Codex, &format!("scoped-{sequence}")).unwrap();
    let job = JobRecord {
        agent_id: previous.map_or_else(|| id.as_str().into(), |job| job.agent_id.clone()),
        job_id: id,
        request_fingerprint: Some(format!("scoped-{sequence}")),
        created_at_ms: Some(1),
        updated_at_ms: 1,
        revision: 0,
        previous_job_id: previous.map(|job| job.job_id.clone()),
        provider_retries: Vec::new(),
        source: JobSource::Runtime,
        admission_origin: previous.is_none().then_some(Origin::TopLevel),
        unconfirmed_result: None,
        notices: Vec::new(),
        recipient: Recipient::None,
        spec: SpecEvidence::Known {
            spec: JobSpec {
                prompt: "scoped fixture".into(),
                cwd: "/tmp".into(),
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
        },
        execution: ExecutionState::Admitted,
        stop: StopState::NotRequested,
    };
    let store = gateway.jobs.store().await.unwrap();
    let (job, _) = store.admit(job).await.unwrap();
    let conversation = ConversationIdentity {
        provider: Provider::Codex,
        provider_home: ProviderHome::Known {
            path: gateway.job_codex_home().unwrap(),
        },
        thread_id: "continued-thread".into(),
    };
    let job = store
        .bind(job.job_id, job.revision, conversation, 2)
        .await
        .unwrap();
    store
        .advance(
            job.job_id,
            job.revision,
            ExecutionState::Terminal {
                terminal: Terminal {
                    at_ms: Some(3),
                    execution: None,
                    git: GitSnapshot::Unknown {
                        reason: "fixture".into(),
                    },
                    outcome: JobOutcome::Completed,
                    result: ResultEvidence::Unavailable {
                        reason: "fixture".into(),
                    },
                    completion: Completion::NotRequired,
                    cleanup: CleanupState::Complete,
                },
            },
            3,
        )
        .await
        .unwrap()
}

async fn request(path: &std::path::Path, request: ScopedRequest) -> Value {
    let mut stream = UnixStream::connect(path).await.unwrap();
    let mut encoded = serde_json::to_vec(&request).unwrap();
    encoded.push(b'\n');
    stream.write_all(&encoded).await.unwrap();
    let mut response = String::new();
    BufReader::new(stream)
        .read_line(&mut response)
        .await
        .unwrap();
    serde_json::from_str(&response).unwrap()
}

#[tokio::test]
async fn scoped_route_outlives_jobs_and_legacy_title_proves_current_process_and_namespace() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let gateway = TestGateway::with_native_runtime(directory.path());
    gateway.jobs.initialize().await.unwrap();
    let path = gateway.jobs.coordination_socket().unwrap();
    assert_eq!(path, scoped_socket(&directory.path().join("agent-jobs/v1")));
    let first = register_job(&gateway, 1, None).await;
    let second = register_job(&gateway, 2, Some(&first)).await;
    assert!(path.exists());
    assert!(!legacy_socket(&first.job_id).exists());
    let pid = std::process::id() as i32;
    let peer = ProcessInstance {
        pid,
        started_micros: crate::platform::process::identify(pid)
            .unwrap()
            .unwrap()
            .started_micros,
    };
    let thread = Arc::new(Mutex::new("continued-thread".to_owned()));
    let names = Arc::new(Mutex::new(Vec::new()));
    let provider_thread = Arc::clone(&thread);
    let renamed = Arc::clone(&names);
    let provider = gateway.clone();
    let mut control = FakeControl::attach(&gateway, 16).await;
    let responder = tokio::spawn(async move {
        while let Some(raw) = control.requests.recv().await {
            let request: Value = serde_json::from_str(&raw).unwrap();
            let result = match request["method"].as_str().unwrap() {
                "daemon/toolContext" => {
                    assert_eq!(request["params"]["pid"], pid);
                    assert_eq!(
                        request["params"]["startedAtUnixMicros"],
                        peer.started_micros
                    );
                    json!({"context":{"threadId":*provider_thread.lock().unwrap(),"turnId":"new-native-turn","toolCallId":"actual-tool","rootProcessIdentity":{"pid":pid,"startedAtUnixMicros":peer.started_micros}}})
                }
                "thread/name/set" => {
                    renamed.lock().unwrap().push(request["params"].clone());
                    json!({})
                }
                method => panic!("unexpected scoped RPC {method}"),
            };
            provider
                .control_requests
                .lock()
                .unwrap()
                .remove(request["id"].as_str().unwrap())
                .unwrap()
                .send(Ok(result))
                .unwrap();
        }
    });
    let current = request(&path, ScopedRequest::ReadSelf {}).await;
    assert_eq!(
        current["result"]["jobId"],
        second.job_id.as_str(),
        "scoped ReadSelf response: {current}"
    );
    let result = request(
        &path,
        ScopedRequest::Legacy {
            socket: legacy_socket(&first.job_id),
            request: Box::new(ScopedRequest::SetTitle {
                mutation_id: "title-after-continue".into(),
                title: "Continued work".into(),
            }),
        },
    )
    .await;
    assert_eq!(result, json!({"result":{}}));
    assert_eq!(
        *names.lock().unwrap(),
        vec![json!({"threadId":"continued-thread","name":"Continued work"})]
    );
    *thread.lock().unwrap() = "different-conversation".into();
    let rejected = request(
        &path,
        ScopedRequest::Legacy {
            socket: legacy_socket(&first.job_id),
            request: Box::new(ScopedRequest::SetTitle {
                mutation_id: "wrong-conversation".into(),
                title: "Forbidden".into(),
            }),
        },
    )
    .await;
    assert!(rejected.get("error").is_some());
    let rejected = request(&path, ScopedRequest::ReadSelf {}).await;
    assert!(rejected.get("error").is_some());
    assert_eq!(names.lock().unwrap().len(), 1);
    assert!(
        gateway
            .scoped_job_rpc(
                ProcessInstance {
                    started_micros: peer.started_micros + 1,
                    ..peer
                },
                ScopedRequest::ReadSelf {}
            )
            .await
            .is_err()
    );
    assert!(
        gateway
            .scoped_job_rpc(
                ProcessInstance {
                    pid: 1,
                    started_micros: 0
                },
                ScopedRequest::ReadSelf {}
            )
            .await
            .is_err()
    );
    let isolated = TestGateway::with_native_runtime(&directory.path().join("other-instance"));
    isolated.jobs.initialize().await.unwrap();
    assert_ne!(path, isolated.jobs.coordination_socket().unwrap());
    assert!(
        isolated
            .jobs
            .store()
            .await
            .unwrap()
            .verify_legacy_socket(
                gateway.agent_conversation("continued-thread").unwrap(),
                legacy_socket(&first.job_id)
            )
            .await
            .is_err()
    );
    isolated.jobs.close_endpoints().await;
    gateway.jobs.close_endpoints().await;
    assert!(!path.exists());
    responder.abort();
}
