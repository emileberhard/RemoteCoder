use super::model::*;
use super::store::JobStore;

fn job(sequence: u8) -> JobRecord {
    let job_id =
        JobId::try_from(format!("agent-codex-1793127141860775000-{sequence:08x}")).unwrap();
    JobRecord {
        agent_id: job_id.as_str().into(),
        job_id,
        request_fingerprint: Some(format!("request-{sequence}")),
        created_at_ms: Some(100),
        updated_at_ms: 100,
        revision: 0,
        previous_job_id: None,
        source: JobSource::Runtime,
        admission_origin: Some(Origin::TopLevel),
        unconfirmed_result: None,
        notices: Vec::new(),
        spec: SpecEvidence::Known {
            spec: JobSpec {
                prompt: "Read the fixture and report its contents.".into(),
                cwd: "/tmp/job-fixture".into(),
                settings: ExecutionSettings::Codex {
                    model: "gpt-6.1-sol".into(),
                    model_provider: "openai".into(),
                    effort: "xhigh".into(),
                    service_tier: None,
                    cyber_access_program: None,
                },
                tool_scope: ToolScope::Full,
                title: None,
            },
        },
        recipient: Recipient::None,
        execution: ExecutionState::Admitted,
        stop: StopState::NotRequested,
    }
}

fn conversation() -> ConversationIdentity {
    ConversationIdentity {
        provider: Provider::Codex,
        provider_home: ProviderHome::Known {
            path: "/tmp/job-fixture/codex".into(),
        },
        thread_id: "thread-fixture".into(),
    }
}

#[tokio::test]
async fn admission_receipt_survives_reopen_and_rejects_conflicting_reuse() {
    let directory = tempfile::tempdir().unwrap();
    let store = JobStore::open(directory.path().into()).await.unwrap();
    let original = job(1);
    let (receipt, duplicate) = store.admit(original.clone()).await.unwrap();
    assert!(!duplicate);
    assert_eq!(receipt.revision, 0);
    drop(store);
    let store = JobStore::open(directory.path().into()).await.unwrap();
    let (_, duplicate) = store.admit(original.clone()).await.unwrap();
    assert!(duplicate);
    let mut conflict = original;
    conflict.request_fingerprint = Some("different-request".into());
    assert!(
        store
            .admit(conflict)
            .await
            .unwrap_err()
            .to_string()
            .contains("already used")
    );
}

#[tokio::test]
async fn lost_origin_projection_recovers_before_binding_or_visibility() {
    let directory = tempfile::tempdir().unwrap();
    let store = JobStore::open(directory.path().into()).await.unwrap();
    let original = job(2);
    store.admit(original.clone()).await.unwrap();
    drop(store);
    for entry in std::fs::read_dir(directory.path().join("agents")).unwrap() {
        std::fs::remove_file(entry.unwrap().path()).unwrap();
    }
    let store = JobStore::open(directory.path().into()).await.unwrap();
    assert_eq!(
        store.agent(original.agent_id.clone()).await.unwrap().origin,
        Origin::TopLevel
    );
    let bound = store
        .bind(original.job_id, 0, conversation(), 101)
        .await
        .unwrap();
    assert!(matches!(bound.execution, ExecutionState::Bound { .. }));
    assert_eq!(
        store.agent(original.agent_id).await.unwrap().conversation,
        ConversationBinding::Known {
            conversation: conversation()
        }
    );
}

#[tokio::test]
async fn runnerless_stop_survives_reopen_and_fences_late_execution_evidence() {
    let directory = tempfile::tempdir().unwrap();
    let store = JobStore::open(directory.path().into()).await.unwrap();
    let original = job(3);
    store.admit(original.clone()).await.unwrap();
    let bound = store
        .bind(original.job_id.clone(), 0, conversation(), 101)
        .await
        .unwrap();
    let stopped = store
        .request_stop(original.job_id.clone(), "stop-fixture".into(), 102)
        .await
        .unwrap();
    assert!(
        store
            .advance(
                original.job_id.clone(),
                bound.revision,
                ExecutionState::Dispatching {
                    conversation: conversation(),
                    input_id: original.initial_input_id()
                },
                103
            )
            .await
            .is_err()
    );
    drop(store);
    let store = JobStore::open(directory.path().into()).await.unwrap();
    assert_eq!(
        store.read(original.job_id.clone()).await.unwrap().stop,
        StopState::Requested {
            mutation_id: "stop-fixture".into(),
            at_ms: 102
        }
    );
    assert!(
        store
            .advance(
                original.job_id.clone(),
                stopped.revision,
                ExecutionState::Dispatching {
                    conversation: conversation(),
                    input_id: original.initial_input_id()
                },
                104
            )
            .await
            .is_err()
    );
    let terminal = Terminal {
        at_ms: Some(105),
        execution: None,
        git: GitSnapshot::Unknown {
            reason: "not a Git checkout".into(),
        },
        outcome: JobOutcome::Stopped {
            effects: EffectEvidence::NotStarted,
        },
        result: ResultEvidence::Unavailable {
            reason: "stopped before dispatch".into(),
        },
        completion: Completion::NotRequired,
        cleanup: crate::agents::jobs::model::CleanupState::Complete,
    };
    let final_job = store
        .advance(
            original.job_id.clone(),
            stopped.revision,
            ExecutionState::Terminal { terminal },
            105,
        )
        .await
        .unwrap();
    assert!(matches!(
        final_job.execution,
        ExecutionState::Terminal { .. }
    ));
    assert!(
        store
            .advance(
                original.job_id,
                final_job.revision,
                ExecutionState::Admitted,
                106
            )
            .await
            .is_err()
    );
}

#[tokio::test]
async fn only_one_process_owner_and_unresolved_job_can_claim_a_conversation() {
    let directory = tempfile::tempdir().unwrap();
    let store = JobStore::open(directory.path().into()).await.unwrap();
    assert!(JobStore::open(directory.path().into()).await.is_err());
    let original = job(4);
    store.admit(original.clone()).await.unwrap();
    let mut competing = job(5);
    competing.agent_id = original.agent_id;
    competing.previous_job_id = Some(original.job_id);
    competing.admission_origin = None;
    assert!(
        store
            .admit(competing)
            .await
            .unwrap_err()
            .to_string()
            .contains("unresolved job")
    );
}

#[tokio::test]
async fn continuation_order_uses_identity_chain_instead_of_wall_clock() {
    let directory = tempfile::tempdir().unwrap();
    let store = JobStore::open(directory.path().into()).await.unwrap();
    let original = job(6);
    store.admit(original.clone()).await.unwrap();
    store
        .advance(
            original.job_id.clone(),
            0,
            ExecutionState::Terminal {
                terminal: Terminal {
                    at_ms: Some(101),
                    execution: None,
                    git: GitSnapshot::Unknown {
                        reason: "not a Git checkout".into(),
                    },
                    outcome: JobOutcome::Completed,
                    result: ResultEvidence::Available {
                        result: JobResult {
                            text: "fixture".into(),
                            truncated: false,
                        },
                    },
                    completion: Completion::NotRequired,
                    cleanup: crate::agents::jobs::model::CleanupState::Complete,
                },
            },
            101,
        )
        .await
        .unwrap();
    let mut next = job(7);
    next.agent_id = original.agent_id.clone();
    next.previous_job_id = Some(original.job_id);
    next.admission_origin = None;
    next.created_at_ms = Some(90);
    let (admitted, _) = store.admit(next).await.unwrap();
    assert_eq!(
        store.agent(original.agent_id).await.unwrap().latest_job_id,
        Some(admitted.job_id)
    );
}

#[tokio::test]
async fn historical_delivery_ids_remain_reserved_without_replayable_payloads() {
    let directory = tempfile::tempdir().unwrap();
    let store = JobStore::open(directory.path().into()).await.unwrap();
    drop(store);
    let mut imported = job(8);
    imported.source = JobSource::Imported;
    imported.admission_origin = None;
    imported.execution = ExecutionState::Unknown {
        conversation: None,
        binding: None,
        reason: "historical runner interruption".into(),
    };
    imported.notices.push(JobNotice {
        at_ms: None,
        payload: CompletionPayload::HistoricalUnreplayable {
            delivery_id: Some("legacy-delivery".into()),
            fingerprint: None,
            reason: "old sender retained only its delivery receipt".into(),
        },
        delivery: DeliveryState::Accepted {
            receipt: "historical receipt".into(),
        },
    });
    std::fs::write(
        directory
            .path()
            .join("jobs")
            .join(format!("{}.json", imported.job_id.as_str())),
        serde_json::to_vec(&imported).unwrap(),
    )
    .unwrap();
    let store = JobStore::open(directory.path().into()).await.unwrap();
    assert!(
        store
            .ensure_new_message_id("legacy-delivery".into())
            .await
            .is_err()
    );
    store
        .ensure_new_message_id("new-delivery".into())
        .await
        .unwrap();
}

#[tokio::test]
async fn settled_notice_payload_expires_but_its_identity_survives() {
    let directory = tempfile::tempdir().unwrap();
    let store = JobStore::open(directory.path().into()).await.unwrap();
    let original = job(9);
    store.admit(original.clone()).await.unwrap();
    let bound = store
        .bind(original.job_id.clone(), 0, conversation(), 100)
        .await
        .unwrap();
    let dispatched = store
        .advance(
            original.job_id.clone(),
            bound.revision,
            ExecutionState::Dispatching {
                conversation: conversation(),
                input_id: original.initial_input_id(),
            },
            100,
        )
        .await
        .unwrap();
    let binding = ExecutionBinding {
        conversation: conversation(),
        input_id: original.initial_input_id(),
        turn_id: "original-turn".into(),
    };
    let running = store
        .advance(
            original.job_id.clone(),
            dispatched.revision,
            ExecutionState::Running {
                binding: binding.clone(),
            },
            100,
        )
        .await
        .unwrap();
    let uncertain = store
        .record_uncertainty(
            original.job_id.clone(),
            running.revision,
            "unknown".into(),
            Some("interim text".into()),
            101,
        )
        .await
        .unwrap();
    assert_eq!(uncertain.execution.binding(), Some(&binding));
    let notice_id = format!("{}:notice:observation", original.job_id.as_str());
    let accepted = store
        .notice_delivery(
            original.job_id.clone(),
            uncertain.revision,
            notice_id.clone(),
            DeliveryState::Accepted {
                receipt: "fixture receipt".into(),
            },
            102,
        )
        .await
        .unwrap();
    store
        .advance(
            original.job_id.clone(),
            accepted.revision,
            ExecutionState::Terminal {
                terminal: Terminal {
                    at_ms: Some(103),
                    execution: None,
                    git: GitSnapshot::Unknown {
                        reason: "fixture".into(),
                    },
                    outcome: JobOutcome::Completed,
                    result: ResultEvidence::Available {
                        result: JobResult {
                            text: "result".into(),
                            truncated: false,
                        },
                    },
                    completion: Completion::NotRequired,
                    cleanup: CleanupState::Complete,
                },
            },
            103,
        )
        .await
        .unwrap();
    let mut later = job(10);
    later.created_at_ms = Some(31 * 24 * 60 * 60 * 1000);
    store.admit(later).await.unwrap();
    drop(store);
    let store = JobStore::open(directory.path().into()).await.unwrap();
    let retained = store.read(original.job_id).await.unwrap();
    assert!(
        matches!(&retained.notices[0].payload, CompletionPayload::Expired { delivery_id, .. } if delivery_id == &notice_id)
    );
    assert!(store.ensure_new_message_id(notice_id).await.is_err());
}

#[tokio::test]
async fn cutover_hold_survives_owner_restart_and_preserves_reads_and_stop() {
    let directory = tempfile::tempdir().unwrap();
    let store = JobStore::open(directory.path().into()).await.unwrap();
    let original = job(11);
    store.admit(original.clone()).await.unwrap();
    crate::storage::private_state::replace(
        &directory.path().join("cutover.hold"),
        b"fixture cutover",
    )
    .unwrap();
    drop(store);
    let store = JobStore::open(directory.path().into()).await.unwrap();
    assert!(store.execution_held().await.unwrap());
    assert!(store.admit(job(12)).await.is_err());
    assert_eq!(
        store.read(original.job_id.clone()).await.unwrap().job_id,
        original.job_id
    );
    let stopped = store
        .request_stop(original.job_id, "stop-during-cutover".into(), 105)
        .await
        .unwrap();
    assert!(matches!(stopped.stop, StopState::Requested { .. }));
    std::fs::remove_file(directory.path().join("cutover.hold")).unwrap();
    store.admit(job(12)).await.unwrap();
}
