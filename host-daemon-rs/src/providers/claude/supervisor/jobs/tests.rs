use super::*;
use crate::agents::mcp::McpTokens;
use crate::observability::journal::Journal;
use crate::providers::claude::restart::ItemStatus;
use crate::providers::claude::restart::test_support::{SESSION, StubClaude, THREAD};
use serde_json::json;
use std::fs;
use std::time::Duration;
use tokio::sync::mpsc;

struct Fixture {
    stub: StubClaude,
    agent: Arc<ClaudeSupervisor>,
    job_id: JobId,
    conversation: ConversationIdentity,
    spec: JobSpec,
    evidence: PathBuf,
    socket: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let stub = StubClaude::new();
        let (sender, mut events) = mpsc::channel(256);
        tokio::spawn(async move { while events.recv().await.is_some() {} });
        let agent = ClaudeSupervisor::new(
            stub.settings.clone(),
            sender,
            Journal::disabled(),
            McpTokens::default(),
        );
        Self {
            job_id: JobId::try_from("agent-claude-2026102720000000000-abcdef12".to_owned())
                .unwrap(),
            conversation: ConversationIdentity {
                provider: Provider::Claude,
                provider_home: ProviderHome::Known {
                    path: stub.claude_home.clone(),
                },
                thread_id: THREAD.to_owned(),
            },
            spec: JobSpec {
                prompt: "finish delegated work".into(),
                cwd: stub.cwd.clone().into(),
                settings: ExecutionSettings::Claude {
                    model: "opus".into(),
                    effort: Some("max".into()),
                    fast: false,
                },
                tool_scope: ToolScope::ReadOnly {
                    root: stub.cwd.clone().into(),
                },
                title: None,
            },
            evidence: stub.state.join("jobs/evidence/job.json"),
            socket: stub.state.join("job.sock"),
            stub,
            agent,
        }
    }

    async fn start(&self) -> ExecutionBinding {
        self.agent
            .record_job_session(THREAD, &self.job_id)
            .await
            .unwrap();
        self.agent
            .start_job(
                &self.job_id,
                &self.conversation,
                &self.spec,
                "11111111-2222-4333-8444-666666666666",
                &self.socket,
                &self.evidence,
            )
            .await
            .unwrap()
    }

    async fn inspect(&self) -> ClaudeJobInspection {
        self.agent
            .inspect_job(&self.job_id, &self.conversation, &self.evidence)
            .await
            .unwrap()
    }

    fn finish_stub(&self) {
        let state = serde_json::to_string(&self.stub.state.to_string_lossy()).unwrap();
        let script = format!(
            r#"#!/usr/bin/python3
import json, os, sys, time
from pathlib import Path
state = Path({state})
def emit(value):
    print(json.dumps(value), flush=True)
def save(name, value):
    with (state / name).open('a') as output:
        output.write(json.dumps(value) + '\n')
save('launches.jsonl', {{'argv': sys.argv[1:], 'socket': os.environ.get('RC_AGENT_JOB_SOCKET'), 'jobId': os.environ.get('RC_AGENT_JOB_ID')}})
args = sys.argv[1:]
session_flag = '--session-id' if '--session-id' in args else '--resume'
session = args[args.index(session_flag) + 1]
emit({{'type':'system','subtype':'init','session_id':session,'apiKeySource':'none','fast_mode_state':'off','permissionMode':'bypassPermissions'}})
frame = json.loads(sys.stdin.readline())
emit(frame)
emit({{'type':'system','subtype':'background_tasks_changed','tasks':[{{'task_id':'child-1','task_type':'local_agent','description':'child task','ambient':False}}]}})
emit({{'type':'result','session_id':session,'subtype':'success','is_error':False,'num_turns':1,'result':'initial candidate'}})
save('ordinary.jsonl', {{'ready':True}})
while not (state / 'release').exists():
    time.sleep(0.005)
emit({{'type':'system','subtype':'background_tasks_changed','tasks':[]}})
emit({{'type':'assistant','session_id':session,'message':{{'content':[{{'type':'text','text':'child answer'}}]}}}})
save('child-answer.jsonl', {{'ready':True}})
while not (state / 'child-result').exists():
    time.sleep(0.005)
emit({{'type':'result','session_id':session,'subtype':'success','is_error':False,'num_turns':0,'origin':{{'kind':'task-notification'}},'result':'child answer'}})
for line in sys.stdin:
    save('unexpected-input.jsonl', json.loads(line))
emit({{'type':'result','session_id':session,'subtype':'success','is_error':False,'num_turns':0,'origin':{{'kind':'task-notification'}},'result':'latest child finish'}})
save('eof.jsonl', {{'closed':True}})
"#
        );
        fs::write(&self.stub.settings.claude_path, script).unwrap();
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        for group in &self.agent.process_registry.lock().unwrap().groups {
            super::super::signal_group(
                nix::unistd::Pid::from_raw(*group),
                nix::sys::signal::Signal::SIGKILL,
            );
        }
    }
}

#[tokio::test]
async fn final_result_waits_for_background_work_eof_and_reap_and_survives_replacement() {
    let fixture = Fixture::new();
    fixture.finish_stub();
    let binding = fixture.start().await;
    fixture.stub.wait_for_log("ordinary.jsonl", 1).await;
    assert!(matches!(
        fixture.inspect().await,
        ClaudeJobInspection::Running { .. }
    ));
    let launches = fixture.stub.log("launches.jsonl");
    let args = launches[0]["argv"].as_array().unwrap();
    assert!(
        args.windows(2)
            .any(|pair| pair == [json!("--tools"), json!("Read,Grep,Glob,Bash,WebSearch")])
    );
    assert!(!args.contains(&json!("--mcp-config")));
    assert_eq!(
        launches[0]["socket"],
        fixture.socket.to_string_lossy().as_ref()
    );
    assert_eq!(launches[0]["jobId"], fixture.job_id.as_str());
    let mut changes = fixture.agent.subscribe_job_changes();
    fs::write(fixture.stub.state.join("release"), "ready").unwrap();
    fixture.stub.wait_for_log("child-answer.jsonl", 1).await;
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let opened = fixture
                .agent
                .runtimes
                .lock()
                .await
                .get(THREAD)
                .is_some_and(|runtime| {
                    runtime
                        .active_turn
                        .as_ref()
                        .is_some_and(|turn| turn.agent_initiated)
                        && runtime.background_tasks.is_empty()
                });
            if opened {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    let evidence: JobEvidence =
        serde_json::from_slice(&fs::read(&fixture.evidence).unwrap()).unwrap();
    assert!(matches!(evidence.phase, JobPhase::Executing));
    assert!(fixture.stub.log("eof.jsonl").is_empty());
    fs::write(fixture.stub.state.join("child-result"), "ready").unwrap();
    let candidate = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let ClaudeJobInspection::Finished { outcome, candidate } = fixture.inspect().await {
                assert_eq!(outcome, JobOutcome::Completed);
                break candidate.unwrap();
            }
            changes.changed().await.unwrap();
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "Claude did not finalize: {}. EOF log: {:?}",
            fs::read_to_string(&fixture.evidence).unwrap(),
            fixture.stub.log("eof.jsonl")
        )
    });
    assert_eq!(candidate.text.as_deref(), Some("latest child finish"));
    assert!(!fixture.agent.has_runtime(THREAD).await);
    assert!(fixture.stub.log("unexpected-input.jsonl").is_empty());
    fixture.stub.wait_for_log("eof.jsonl", 1).await;
    let (sender, _events) = mpsc::channel(256);
    let replacement = ClaudeSupervisor::new(
        fixture.stub.settings.clone(),
        sender,
        Journal::disabled(),
        McpTokens::default(),
    );
    assert!(matches!(
        replacement
            .inspect_job(&fixture.job_id, &fixture.conversation, &fixture.evidence)
            .await
            .unwrap(),
        ClaudeJobInspection::Finished { .. }
    ));
    assert!(matches!(
        replacement
            .resume_with_notice(&fixture.stub.item(SESSION, ItemStatus::Captured))
            .await
            .unwrap(),
        super::super::ResumeDelivery::Stopped
    ));
    assert_eq!(fixture.stub.log("launches.jsonl").len(), 1);
    assert!(!binding.turn_id.is_empty());
}

#[tokio::test]
async fn an_exact_orphan_process_blocks_a_second_process_and_stop_keeps_final_evidence() {
    let fixture = Fixture::new();
    fixture.start().await;
    fixture.stub.wait_for_log("received.jsonl", 1).await;
    let (sender, _events) = mpsc::channel(256);
    let replacement = ClaudeSupervisor::new(
        fixture.stub.settings.clone(),
        sender,
        Journal::disabled(),
        McpTokens::default(),
    );
    assert!(matches!(
        replacement
            .inspect_job(&fixture.job_id, &fixture.conversation, &fixture.evidence)
            .await
            .unwrap(),
        ClaudeJobInspection::Unknown { .. }
    ));
    assert!(
        replacement
            .recover_job(
                &fixture.job_id,
                &fixture.conversation,
                &fixture.spec,
                "22222222-2222-4333-8444-666666666666",
                &fixture.socket,
                &fixture.evidence
            )
            .await
            .is_err()
    );
    assert_eq!(fixture.stub.log("launches.jsonl").len(), 1);
    fixture
        .agent
        .stop_job(&fixture.job_id, &fixture.conversation, &fixture.evidence)
        .await
        .unwrap();
    assert!(matches!(
        fixture.inspect().await,
        ClaudeJobInspection::Finished {
            outcome: JobOutcome::Stopped {
                effects: EffectEvidence::MayHaveRun
            },
            ..
        }
    ));
}

#[tokio::test]
async fn continuation_without_exact_history_cannot_start_fresh_under_the_old_session_uuid() {
    let fixture = Fixture::new();
    fixture.start().await;
    fixture.stub.wait_for_log("received.jsonl", 1).await;
    fixture
        .agent
        .stop_job(&fixture.job_id, &fixture.conversation, &fixture.evidence)
        .await
        .unwrap();
    fs::remove_file(fixture.stub.history(SESSION)).unwrap();
    let continued =
        JobId::try_from("agent-claude-2026102720000000001-abcdef12".to_owned()).unwrap();
    let error = fixture
        .agent
        .start_job(
            &continued,
            &fixture.conversation,
            &fixture.spec,
            "33333333-2222-4333-8444-666666666666",
            &fixture.socket,
            &fixture.evidence.with_file_name("continued.json"),
        )
        .await
        .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("continuation history is missing")
    );
    assert_eq!(fixture.stub.log("launches.jsonl").len(), 1);
}

#[tokio::test]
async fn canonical_input_identity_recovers_a_missing_receipt_without_claiming_consumption() {
    let fixture = Fixture::new();
    let binding = fixture.start().await;
    fixture.stub.wait_for_log("received.jsonl", 1).await;
    assert!(fixture.agent.suspend(THREAD).await);
    let handle = JobHandle {
        job_id: fixture.job_id.clone(),
        evidence_path: fixture.evidence.clone(),
    };
    fixture
        .agent
        .conversation_index
        .update_job(THREAD, &handle, |saved| {
            saved.input_consumed = false;
            saved.input_recorded = false;
            Ok(())
        })
        .await
        .unwrap();
    assert!(matches!(
        fixture.inspect().await,
        ClaudeJobInspection::Unknown { .. }
    ));
    fixture.stub.write_history(
        SESSION,
        &format!(
            "{}\n",
            json!({
                "type":"user", "uuid":binding.input_id,
                "message":{"role":"user","content":fixture.spec.prompt}
            })
        ),
    );
    assert!(
        matches!(fixture.inspect().await, ClaudeJobInspection::Recoverable { binding: saved } if saved == binding)
    );
    let evidence = fixture
        .agent
        .conversation_index
        .job(THREAD, &handle)
        .await
        .unwrap()
        .unwrap();
    assert!(evidence.input_recorded);
    assert!(!evidence.input_consumed);
    assert!(!evidence.eligible());
}

#[tokio::test]
async fn an_unproven_owner_with_a_live_group_cannot_be_declared_stopped() {
    let fixture = Fixture::new();
    fixture.start().await;
    fixture.stub.wait_for_log("received.jsonl", 1).await;
    let handle = JobHandle {
        job_id: fixture.job_id.clone(),
        evidence_path: fixture.evidence.clone(),
    };
    fixture
        .agent
        .conversation_index
        .update_job(THREAD, &handle, |saved| {
            saved.owner.as_mut().unwrap().started_micros += 1;
            Ok(())
        })
        .await
        .unwrap();
    let (sender, _events) = mpsc::channel(256);
    let replacement = ClaudeSupervisor::new(
        fixture.stub.settings.clone(),
        sender,
        Journal::disabled(),
        McpTokens::default(),
    );
    let error = replacement
        .stop_job(&fixture.job_id, &fixture.conversation, &fixture.evidence)
        .await
        .unwrap_err();
    assert!(error.to_string().contains("Stop stays pending"));
    let evidence = fixture
        .agent
        .conversation_index
        .job(THREAD, &handle)
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(evidence.phase, JobPhase::Stopping));
    assert!(fixture.agent.has_runtime(THREAD).await);
    assert!(fixture.agent.suspend(THREAD).await);
}

#[tokio::test]
async fn prepared_recovery_retries_only_its_frozen_input_and_never_the_original_prompt() {
    let fixture = Fixture::new();
    let original = fixture.start().await;
    fixture.stub.wait_for_log("received.jsonl", 1).await;
    assert!(fixture.agent.suspend(THREAD).await);
    let mut item = fixture.stub.item(SESSION, ItemStatus::Captured);
    item.recovery_id = "22222222-2222-4333-8444-666666666666".into();
    item.interrupted_turn_id = Some(original.turn_id.clone());
    item.captured_at_unix_ms = 1_700_000_000_000;
    let handle = JobHandle {
        job_id: fixture.job_id.clone(),
        evidence_path: fixture.evidence.clone(),
    };
    let policy = LaunchPolicy::Job {
        handle: handle.clone(),
        scope: fixture.spec.tool_scope.clone(),
        coordination_socket: fixture.socket.clone(),
    };
    let request = ClaudeTurnRequest {
        thread_id: THREAD.into(),
        session_uuid: SESSION.into(),
        first_turn: false,
        input: ClaudeUserInput::recovery_notice(&item),
        selection: ClaudeSelection {
            model: "opus".into(),
            effort: Some("max".into()),
            fast: false,
        },
        cwd: fixture.stub.cwd.clone(),
    };
    fixture
        .agent
        .prepare_job_resume(&request, &policy)
        .await
        .unwrap();
    assert!(
        matches!(fixture.inspect().await,ClaudeJobInspection::PreparedRecovery { recovery_input_id } if recovery_input_id == item.recovery_id)
    );
    let original_retry = fixture
        .agent
        .start_job(
            &fixture.job_id,
            &fixture.conversation,
            &fixture.spec,
            &original.input_id,
            &fixture.socket,
            &fixture.evidence,
        )
        .await
        .unwrap_err();
    assert!(original_retry.to_string().contains("prepared recovery"));
    let (sender, _events) = mpsc::channel(256);
    let replacement = ClaudeSupervisor::new(
        fixture.stub.settings.clone(),
        sender,
        Journal::disabled(),
        McpTokens::default(),
    );
    assert!(
        replacement
            .recover_job(
                &fixture.job_id,
                &fixture.conversation,
                &fixture.spec,
                "33333333-2222-4333-8444-666666666666",
                &fixture.socket,
                &fixture.evidence
            )
            .await
            .is_err()
    );
    replacement
        .recover_job(
            &fixture.job_id,
            &fixture.conversation,
            &fixture.spec,
            &item.recovery_id,
            &fixture.socket,
            &fixture.evidence,
        )
        .await
        .unwrap();
    let received = fixture.stub.wait_for_log("received.jsonl", 2).await;
    assert_eq!(received.len(), 2);
    assert_eq!(received[1]["uuid"], item.recovery_id);
    assert_eq!(received[1]["message"]["content"], request.input.text);
    assert_ne!(received[1]["message"]["content"], fixture.spec.prompt);
    let evidence = replacement
        .conversation_index
        .job(THREAD, &handle)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        evidence.recovery_input.unwrap().captured_at_unix_ms,
        item.captured_at_unix_ms
    );
    replacement
        .stop_job(&fixture.job_id, &fixture.conversation, &fixture.evidence)
        .await
        .unwrap();
}
