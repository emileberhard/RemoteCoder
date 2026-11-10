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
        admitted_membership: None,
        remote_fingerprint: None,
        parent_revision: 0,
        initial_parent: None,
        admission_origin: previous.is_none().then_some(Origin::TopLevel),
        unconfirmed_result: None,
        attention: None,
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
        thread_id: "6587aec5-99c2-5919-9221-89bdf86e59b6".into(),
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
    let peer = crate::platform::process::identify_instance(pid)
        .unwrap()
        .unwrap();
    let crate::platform::process::ProcessBirth::Darwin { started_micros } = peer.birth else {
        panic!("Darwin proof expected");
    };
    let thread = Arc::new(Mutex::new(
        "6587aec5-99c2-5919-9221-89bdf86e59b6".to_owned(),
    ));
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
                    assert_eq!(request["params"]["startedAtUnixMicros"], started_micros);
                    json!({"context":{"threadId":*provider_thread.lock().unwrap(),"turnId":"new-native-turn","toolCallId":"actual-tool","rootProcessIdentity":{"pid":pid,"startedAtUnixMicros":started_micros}}})
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
        vec![json!({"threadId":"6587aec5-99c2-5919-9221-89bdf86e59b6","name":"Continued work"})]
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
                    birth: crate::platform::process::ProcessBirth::Darwin {
                        started_micros: started_micros + 1
                    },
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
                    birth: crate::platform::process::ProcessBirth::Darwin { started_micros: 0 }
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
                gateway
                    .agent_conversation("6587aec5-99c2-5919-9221-89bdf86e59b6")
                    .unwrap(),
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

#[tokio::test]
async fn provider_wait_is_visible_while_another_provider_proceeds() {
    use crate::agents::mcp::McpTokens;
    use crate::observability::journal::Journal;
    use crate::providers::claude::ClaudeSupervisor;
    use crate::providers::claude::restart::test_support::StubClaude;
    use crate::providers::codex::daemon::CodexAppServer;
    use tokio::sync::mpsc;

    let stub = StubClaude::new();
    let gateway = Gateway::with_turn_state(
        Arc::new(CodexAppServer::new_for_test_socket(
            stub.state.join("codex"),
        )),
        stub.settings.clone(),
        Journal::disabled(),
        Some(stub.turn_state_path()),
    );
    let (sender, mut events) = mpsc::channel(256);
    let notifications = tokio::spawn(async move { while events.recv().await.is_some() {} });
    gateway.set_claude_agent(ClaudeSupervisor::new(
        stub.settings.clone(),
        sender,
        Journal::disabled(),
        McpTokens::default(),
    ));
    let mut ids = Vec::new();
    for settings in [
        ExecutionSettings::Codex {
            model: "fixture".into(),
            model_provider: "openai".into(),
            effort: "medium".into(),
            service_tier: None,
            cyber_access_program: None,
        },
        ExecutionSettings::Claude {
            model: "opus".into(),
            effort: Some("max".into()),
            fast: false,
        },
    ] {
        let id = JobId::for_mutation(settings.provider(), "provider-readiness").unwrap();
        let params = json!(StartParams {
            job_id: id.clone(),
            spec: JobSpec {
                prompt: "Read this fixture".into(),
                cwd: stub.cwd.clone().into(),
                settings,
                tool_scope: ToolScope::Full,
                title: None,
            },
            caller: Caller::Operator
        });
        gateway
            .validate_dispatch(
                "agent/jobs/start",
                json!({"params":params}).as_object().unwrap(),
            )
            .await
            .unwrap();
        gateway
            .agent_jobs_rpc("agent/jobs/start", params)
            .await
            .unwrap();
        ids.push(id);
    }
    gateway.jobs.start_driver().unwrap();
    let (codex, claude) = tokio::time::timeout(std::time::Duration::from_secs(10), async {
        loop {
            let codex = gateway.jobs.read(&ids[0]).await.unwrap();
            let claude = gateway.jobs.read(&ids[1]).await.unwrap();
            if matches!(
                codex.job.execution,
                ExecutionState::WaitingForProvider {
                    provider: Provider::Codex
                }
            ) && matches!(claude.job.execution, ExecutionState::Running { .. })
            {
                break (codex, claude);
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    stub.wait_for_log("received.jsonl", 1).await;
    assert!(codex.job.execution.conversation().is_none());
    assert_eq!(
        serde_json::to_value(codex.job).unwrap()["execution"],
        json!({"kind":"waitingForProvider","provider":"codex"})
    );
    assert!(claude.job.execution.conversation().is_some());
    gateway.stop().await.unwrap();
    notifications.await.unwrap();
}

#[tokio::test]
async fn captured_native_claude_context_outlives_its_child_but_not_its_owner_or_gateway() {
    let gateway = TestGateway::new();
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let socket = directory.path().join("native");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let owner = crate::platform::process::identify(std::process::id() as i32)
        .unwrap()
        .unwrap();
    let crate::platform::process::ProcessBirth::Darwin { started_micros } = owner.birth else {
        panic!("Darwin proof expected");
    };
    let home = &gateway.claude_settings.claude_home;
    let path = home
        .join("sessions")
        .join(format!("{}.json", std::process::id()));
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let format = time::format_description::parse_owned::<3>("[weekday repr:short] [month repr:short] [day padding:space] [hour]:[minute]:[second] [year]").unwrap();
    let started = time::OffsetDateTime::from_unix_timestamp((started_micros / 1_000_000) as i64)
        .unwrap()
        .format(&format)
        .unwrap();
    let mut record = json!({"pid":std::process::id(),"sessionId":"11111111-2222-4333-8444-555555555555","cwd":directory.path(),"messagingSocketPath":socket,"pidDomain":"darwin","procStart":started});
    std::fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
    let mut child = tokio::process::Command::new("/bin/cat")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let pid = child.id().unwrap();
    let identity = crate::platform::process::identify(pid as i32)
        .unwrap()
        .unwrap();
    let captured = gateway
        .capture_job_context(CaptureParams {
            pid,
            birth: identity.birth,
        })
        .await
        .unwrap();
    let saved = gateway
        .jobs
        .contexts
        .get(&captured.context_id)
        .await
        .unwrap();
    assert_eq!(saved.process.pid, std::process::id() as i32);
    child.kill().await.unwrap();
    assert!(
        gateway
            .capture_job_context(CaptureParams {
                pid,
                birth: identity.birth,
            })
            .await
            .is_err()
    );
    let caller = Caller::Captured {
        context_id: captured.context_id,
    };
    assert_eq!(
        gateway.resolve_job_caller(&caller).await.unwrap(),
        Origin::Parent {
            conversation: saved.conversation
        }
    );
    assert!(
        TestGateway::new()
            .resolve_job_caller(&caller)
            .await
            .is_err()
    );
    record["sessionId"] = json!("22222222-2222-4333-8444-555555555555");
    std::fs::write(path, serde_json::to_vec(&record).unwrap()).unwrap();
    assert!(
        gateway
            .resolve_job_caller(&caller)
            .await
            .unwrap_err()
            .to_string()
            .contains("owner changed")
    );
    drop(listener);
}

#[tokio::test]
async fn job_owner_rejects_invalid_external_claude_starts_and_continuations_before_admission() {
    use crate::observability::journal::Journal;
    use crate::providers::claude::restart::test_support::StubClaude;
    use crate::providers::codex::daemon::CodexAppServer;
    use crate::providers::external::{ExternalProvider, ExternalProviders};

    let stub = StubClaude::new();
    let catalog_dir = stub.state.join("external-models");
    crate::storage::private_state::ensure_private_directory(&catalog_dir).unwrap();
    crate::storage::private_state::write_json(
        &catalog_dir.join("copilot.json"),
        &json!({"models": [
            {
                "slug": "copilot/gemini-4-argon",
                "display_name": "Gemini 4 Argon",
                "default_reasoning_level": "medium",
                "supported_reasoning_levels": [
                    {"effort": "low", "description": "low"},
                    {"effort": "medium", "description": "medium"},
                    {"effort": "high", "description": "high"}
                ],
                "context_window": 200000,
                "input_modalities": ["text"],
                "rc_messages": true
            },
            {
                "slug": "copilot/codex-only",
                "display_name": "Codex Only",
                "default_reasoning_level": "medium",
                "supported_reasoning_levels": [
                    {"effort": "high", "description": "high"}
                ],
                "context_window": 200000,
                "input_modalities": ["text"],
                "rc_messages": true
            }
        ]}),
    )
    .unwrap();
    let providers: Vec<ExternalProvider> = serde_json::from_value(json!([{
        "id": "copilot",
        "name": "Copilot",
        "baseUrl": "http://127.0.0.1:9/v1",
        "keyFile": "/private/copilot.key",
        "models": [
            {"id": "copilot/gemini-4-argon", "harness": "claude"},
            {"id": "copilot/other-model", "harness": "claude"},
            {"id": "copilot/codex-only", "harness": "codex"}
        ]
    }]))
    .unwrap();
    let external_providers = ExternalProviders::new(providers, &stub.state).unwrap();
    let gateway = Gateway::with_notifier(
        Arc::new(CodexAppServer::new_for_test_socket(
            stub.state.join("codex"),
        )),
        Arc::new(crate::push::PushService::fixture_disabled(
            Journal::disabled(),
        )),
        stub.settings.clone(),
        Journal::disabled(),
        crate::gateway::GatewayStorage::fixture(stub.state.clone()),
        None,
        None,
        external_providers,
        None,
        None,
    );
    let start_id = JobId::for_mutation(Provider::Claude, "valid-external-start").unwrap();
    let admitted = gateway
        .jobs
        .start(
            StartParams {
                job_id: start_id.clone(),
                spec: JobSpec {
                    prompt: "Read fixture".into(),
                    cwd: stub.cwd.clone().into(),
                    settings: ExecutionSettings::Claude {
                        model: "copilot/gemini-4-argon".into(),
                        effort: Some("high".into()),
                        fast: false,
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
    for (label, invalid_start, expected_error) in [
        (
            "invalid-start-effort",
            ExecutionSettings::Claude {
                model: "copilot/gemini-4-argon".into(),
                effort: Some("xhigh".into()),
                fast: false,
            },
            "unsupported effort for copilot/gemini-4-argon",
        ),
        (
            "invalid-start-fast",
            ExecutionSettings::Claude {
                model: "copilot/gemini-4-argon".into(),
                effort: Some("high".into()),
                fast: true,
            },
            "Copilot has no Fast mode",
        ),
        (
            "invalid-start-harness",
            ExecutionSettings::Claude {
                model: "copilot/codex-only".into(),
                effort: Some("high".into()),
                fast: false,
            },
            "copilot/codex-only is not configured for Claude",
        ),
        (
            "invalid-start-unconfigured",
            ExecutionSettings::Claude {
                model: "copilot/unconfigured".into(),
                effort: Some("high".into()),
                fast: false,
            },
            "Claude model provider is unavailable for copilot/unconfigured",
        ),
    ] {
        let error = gateway
            .jobs
            .start(
                StartParams {
                    job_id: JobId::for_mutation(Provider::Claude, label).unwrap(),
                    spec: JobSpec {
                        prompt: "Read fixture".into(),
                        cwd: stub.cwd.clone().into(),
                        settings: invalid_start,
                        tool_scope: ToolScope::Full,
                        title: None,
                    },
                    caller: Caller::Operator,
                },
                Origin::TopLevel,
            )
            .await
            .unwrap_err()
            .to_string();
        assert!(error.contains(expected_error), "{label}: {error}");
    }
    let store = gateway.jobs.store().await.unwrap();
    let bound = store
        .bind(
            start_id.clone(),
            admitted.job.revision,
            gateway.job_new_claude_conversation().unwrap(),
            10,
        )
        .await
        .unwrap();
    store
        .advance(
            start_id.clone(),
            bound.revision,
            ExecutionState::Terminal {
                terminal: Terminal {
                    at_ms: Some(11),
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
            11,
        )
        .await
        .unwrap();
    for (label, invalid_continue, expected_error) in [
        (
            "unsupported-effort",
            ExecutionSettings::Claude {
                model: "copilot/gemini-4-argon".into(),
                effort: Some("xhigh".into()),
                fast: false,
            },
            "unsupported effort for copilot/gemini-4-argon",
        ),
        (
            "fast-tier",
            ExecutionSettings::Claude {
                model: "copilot/gemini-4-argon".into(),
                effort: Some("high".into()),
                fast: true,
            },
            "External models have no service tiers",
        ),
        (
            "switch-to-native",
            ExecutionSettings::Claude {
                model: "opus".into(),
                effort: Some("high".into()),
                fast: false,
            },
            "Continue cannot change the conversation's model provider",
        ),
        (
            "switch-external-model",
            ExecutionSettings::Claude {
                model: "copilot/other-model".into(),
                effort: Some("high".into()),
                fast: false,
            },
            "Continue cannot change the conversation's model provider",
        ),
    ] {
        let error = gateway
            .jobs
            .continue_job(
                ContinueParams {
                    job_id: JobId::for_mutation(Provider::Claude, label).unwrap(),
                    agent_id: admitted.job.agent_id.clone(),
                    prompt: "Follow up".into(),
                    settings: Some(invalid_continue),
                    expected_previous_job_id: Some(start_id.clone()),
                    intent: ContinueIntent::Explicit,
                    recipient: ContinueRecipient::Current,
                    caller: Caller::Operator,
                },
                Origin::TopLevel,
            )
            .await
            .unwrap_err()
            .to_string();
        assert!(error.contains(expected_error), "{label}: {error}");
    }
    assert_eq!(
        store
            .agent(admitted.job.agent_id.clone())
            .await
            .unwrap()
            .latest_job_id,
        Some(start_id.clone())
    );
    let continued = gateway
        .jobs
        .continue_job(
            ContinueParams {
                job_id: JobId::for_mutation(Provider::Claude, "valid-continue").unwrap(),
                agent_id: admitted.job.agent_id,
                prompt: "Follow up".into(),
                settings: Some(ExecutionSettings::Claude {
                    model: "copilot/gemini-4-argon".into(),
                    effort: Some("medium".into()),
                    fast: false,
                }),
                expected_previous_job_id: Some(start_id),
                intent: ContinueIntent::Explicit,
                recipient: ContinueRecipient::Current,
                caller: Caller::Operator,
            },
            Origin::TopLevel,
        )
        .await
        .unwrap();
    assert!(matches!(continued.job.execution, ExecutionState::Admitted));
}
