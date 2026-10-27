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
