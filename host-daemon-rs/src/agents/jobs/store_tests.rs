use super::model::*;
use super::store::{JobStore, Selection};

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
        provider_retries: Vec::new(),
        source: JobSource::Runtime,
        admitted_membership: None,
        remote_fingerprint: None,
        parent_revision: 0,
        initial_parent: None,
        admission_origin: Some(Origin::TopLevel),
        unconfirmed_result: None,
        attention: None,
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
async fn cluster_fault_commits_survive_restart_and_fence_parent_handover() {
    use crate::wire::cluster::*;
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().to_owned();
    let store = JobStore::open(root.clone()).await.unwrap();
    let mut original = job(90);
    let receiver = Recipient::Remote {
        host: "host-a".into(),
        incarnation: "inc-a".into(),
        conversation: conversation(),
    };
    original.recipient = receiver.clone();
    original.initial_parent = Some(AgentAddress {
        host_id: "host-a".into(),
        thread_id: conversation().thread_id,
    });
    let SpecEvidence::Known { spec } = &original.spec else {
        unreachable!()
    };
    let intent = RemoteIntent {
        protocol: PROTOCOL,
        host: "host-b".into(),
        membership: "member".into(),
        incarnation: "inc-b".into(),
        request: AdmitParams {
            protocol: PROTOCOL,
            job_id: original.job_id.clone(),
            fingerprint: "immutable".into(),
            incarnation: "inc-b".into(),
            origin: Origin::TopLevel,
            recipient: receiver.clone(),
            operation: AdmissionOperation::Start(spec.clone()),
            caller_authority: CallerAuthority::Operator,
        },
        parent: original.initial_parent.clone(),
        created_at: crate::cluster::link::timestamp(),
        state: IntentState::Pending,
        stop_confirmed: false,
    };
    store.put_intent(intent.clone()).await.unwrap();
    drop(store);
    let store = JobStore::open(root.clone()).await.unwrap();
    assert_eq!(
        store.intents().await.unwrap()[0].request.fingerprint,
        "immutable"
    );
    store.admit(original.clone()).await.unwrap();
    drop(store);
    let store = JobStore::open(root.clone()).await.unwrap();
    assert!(store.admit(original.clone()).await.unwrap().1);
    assert_eq!(store.agent_rows().await.unwrap().len(), 1);
    let done = store
        .advance(
            original.job_id.clone(),
            0,
            ExecutionState::Terminal {
                terminal: Terminal {
                    at_ms: Some(101),
                    execution: None,
                    git: GitSnapshot::Unknown {
                        reason: "fixture".into(),
                    },
                    outcome: JobOutcome::Completed,
                    result: ResultEvidence::Available {
                        result: JobResult {
                            text: "retained result".into(),
                            truncated: false,
                        },
                    },
                    completion: Completion::Required {
                        payload: CompletionPayload::HistoricalUnreplayable {
                            delivery_id: Some("immutable-delivery".into()),
                            fingerprint: None,
                            reason: "fixture".into(),
                        },
                        delivery: DeliveryState::Uncertain {
                            reason: "reply lost".into(),
                        },
                    },
                    cleanup: CleanupState::Complete,
                },
            },
            101,
        )
        .await
        .unwrap();
    store
        .set_parent(original.agent_id.clone(), None, Recipient::None)
        .await
        .unwrap();
    let frozen = store.retarget_delivery(done.job_id.clone()).await.unwrap();
    assert_eq!(frozen.recipient, receiver);
    drop(store);
    let store = JobStore::open(root).await.unwrap();
    let recovered = store.read(original.job_id.clone()).await.unwrap();
    assert!(matches!(
        recovered.execution,
        ExecutionState::Terminal { .. }
    ));
    assert_eq!(recovered.recipient, receiver);
    let rejected = store
        .delivery(
            original.job_id.clone(),
            recovered.revision,
            DeliveryState::Unreachable {
                reason: "receiver proved no acceptance".into(),
            },
            102,
        )
        .await
        .unwrap();
    let moved = store.retarget_delivery(rejected.job_id).await.unwrap();
    assert_eq!(moved.recipient, Recipient::None);
    store
        .intent_state(original.job_id.clone(), IntentState::Unknown)
        .await
        .unwrap();
    assert!(
        store
            .intent_state(original.job_id, IntentState::Pending)
            .await
            .is_err()
    );
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
            .contains("unresolved runtime job")
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
    let retained = store.read(original.job_id.clone()).await.unwrap();
    assert!(
        matches!(&retained.notices[0].payload, CompletionPayload::Expired { delivery_id, .. } if delivery_id == &notice_id)
    );
    assert!(store.ensure_new_message_id(notice_id).await.is_err());
    let mut another = job(13);
    another.created_at_ms = Some(32 * 24 * 60 * 60 * 1000);
    store.admit(another).await.unwrap();
    assert_eq!(
        store.read(original.job_id).await.unwrap().revision,
        retained.revision,
        "an already expired settled job is not rewritten by later admissions"
    );
}

#[tokio::test]
async fn explicit_continuation_preserves_imported_unknown_outcome_and_origin() {
    let directory = tempfile::tempdir().unwrap();
    let store = JobStore::open(directory.path().into()).await.unwrap();
    drop(store);
    let mut imported = job(81);
    imported.source = JobSource::Imported;
    imported.admission_origin = None;
    imported.spec = SpecEvidence::Unknown {
        reason: "historical prompt is unavailable".into(),
    };
    imported.execution = ExecutionState::Unknown {
        conversation: Some(conversation()),
        binding: None,
        reason: "historical outcome is unconfirmed".into(),
    };
    let agent = AgentRecord {
        parent: None,
        parent_revision: 0,
        parent_recipient: None,
        agent_id: imported.agent_id.clone(),
        conversation: ConversationBinding::Known {
            conversation: conversation(),
        },
        origin: Origin::Unknown {
            reason: "historical ancestry is unavailable".into(),
        },
        tool_scope: Some(ToolScope::ReadOnly {
            root: "/tmp/job-fixture".into(),
        }),
        origin_job_id: Some(imported.job_id.clone()),
        latest_job_id: Some(imported.job_id.clone()),
    };
    std::fs::write(
        directory
            .path()
            .join("jobs")
            .join(format!("{}.json", imported.job_id.as_str())),
        serde_json::to_vec(&imported).unwrap(),
    )
    .unwrap();
    std::fs::write(
        directory.path().join("agents").join(format!(
            "{}.json",
            super::store::fingerprint(agent.agent_id.as_bytes())
        )),
        serde_json::to_vec(&agent).unwrap(),
    )
    .unwrap();
    let store = JobStore::open(directory.path().into()).await.unwrap();
    let mut continuation = job(82);
    continuation.agent_id = imported.agent_id.clone();
    continuation.previous_job_id = Some(imported.job_id.clone());
    continuation.admission_origin = None;
    if let SpecEvidence::Known { spec } = &mut continuation.spec {
        spec.tool_scope = agent.tool_scope.clone().unwrap();
    }
    store.admit(continuation.clone()).await.unwrap();
    let bound = store
        .bind(continuation.job_id.clone(), 0, conversation(), 101)
        .await
        .unwrap();
    let dispatching = store
        .advance(
            continuation.job_id.clone(),
            bound.revision,
            ExecutionState::Dispatching {
                conversation: conversation(),
                input_id: continuation.initial_input_id(),
            },
            102,
        )
        .await
        .unwrap();
    store
        .record_uncertainty(
            continuation.job_id.clone(),
            dispatching.revision,
            "runtime observation unavailable".into(),
            None,
            103,
        )
        .await
        .unwrap();
    let page = store.list(Selection::Recent, 200, None).await.unwrap();
    let historical = page
        .jobs
        .iter()
        .find(|row| row.job_id == imported.job_id)
        .unwrap();
    let current = page
        .jobs
        .iter()
        .find(|row| row.job_id == continuation.job_id)
        .unwrap();
    assert_eq!(historical.state, crate::agents::State::Unknown);
    assert!(!historical.active);
    assert_eq!(current.state, crate::agents::State::Unknown);
    assert!(current.active);
    assert_eq!(store.read(imported.job_id.clone()).await.unwrap(), imported);
    let continued = store.agent(agent.agent_id).await.unwrap();
    assert_eq!(continued.origin, agent.origin);
    assert_eq!(continued.tool_scope, agent.tool_scope);
    assert_eq!(continued.latest_job_id, Some(continuation.job_id));
}

#[tokio::test]
async fn imported_forks_use_retained_checkpoint_or_single_active_runtime() {
    for (checkpoint, active, expected) in [
        (Some(2), false, Some(2)),
        (None, false, None),
        (None, true, Some(4)),
    ] {
        let directory = tempfile::tempdir().unwrap();
        drop(JobStore::open(directory.path().into()).await.unwrap());
        let mut original = job(1);
        original.source = JobSource::Imported;
        original.execution = ExecutionState::Unknown {
            conversation: Some(conversation()),
            binding: None,
            reason: "Historical outcome is unconfirmed".into(),
        };
        for sequence in 1..=if active { 4 } else { 3 } {
            let mut record = original.clone();
            record.job_id = job(sequence).job_id;
            record.created_at_ms = Some(1000 - i64::from(sequence));
            if sequence != 1 {
                record.previous_job_id = Some(original.job_id.clone());
                record.admission_origin = None;
            }
            if sequence == 4 {
                record.source = JobSource::Runtime;
                record.execution = ExecutionState::Running {
                    binding: ExecutionBinding {
                        conversation: conversation(),
                        input_id: "active-input".into(),
                        turn_id: "active-turn".into(),
                    },
                };
            }
            std::fs::write(
                directory
                    .path()
                    .join("jobs")
                    .join(format!("{}.json", record.job_id.as_str())),
                serde_json::to_vec(&record).unwrap(),
            )
            .unwrap();
        }
        let agent = AgentRecord {
            parent: None,
            parent_revision: 0,
            parent_recipient: None,
            agent_id: original.agent_id.clone(),
            conversation: ConversationBinding::Known {
                conversation: conversation(),
            },
            origin: Origin::TopLevel,
            tool_scope: Some(ToolScope::Full),
            origin_job_id: Some(original.job_id),
            latest_job_id: checkpoint.map(|sequence| job(sequence).job_id),
        };
        std::fs::write(
            directory.path().join("agents").join(format!(
                "{}.json",
                super::store::fingerprint(agent.agent_id.as_bytes())
            )),
            serde_json::to_vec(&agent).unwrap(),
        )
        .unwrap();
        let store = JobStore::open(directory.path().into()).await.unwrap();
        assert_eq!(
            store.agent(agent.agent_id).await.unwrap().latest_job_id,
            expected.map(|sequence| job(sequence).job_id),
        );
    }
}

async fn running_retry_fixture(store: &JobStore, sequence: u8) -> JobRecord {
    let original = job(sequence);
    store.admit(original.clone()).await.unwrap();
    let bound = store
        .bind(original.job_id.clone(), 0, conversation(), 101)
        .await
        .unwrap();
    let dispatched = store
        .advance(
            bound.job_id.clone(),
            bound.revision,
            ExecutionState::Dispatching {
                conversation: conversation(),
                input_id: bound.current_input_id(),
            },
            102,
        )
        .await
        .unwrap();
    store
        .advance(
            dispatched.job_id.clone(),
            dispatched.revision,
            ExecutionState::Running {
                binding: ExecutionBinding {
                    conversation: conversation(),
                    input_id: dispatched.current_input_id(),
                    turn_id: "failed-0".into(),
                },
            },
            103,
        )
        .await
        .unwrap()
}

#[tokio::test]
async fn provider_retries_retain_exact_bindings_due_time_and_budget_across_restart() {
    let directory = tempfile::tempdir().unwrap();
    let mut store = JobStore::open(directory.path().into()).await.unwrap();
    let mut current = running_retry_fixture(&store, 41).await;
    let original_input = current.current_input_id();
    for attempt in 0..super::retry::MAX_PROVIDER_RETRIES {
        let failed = current.execution.binding().unwrap().clone();
        current = store
            .schedule_provider_retry(
                current.job_id.clone(),
                current.revision,
                failed.clone(),
                "Selected model is at capacity".into(),
                2_000,
                1_000,
            )
            .await
            .unwrap();
        assert_eq!(current.provider_retries[attempt].binding, failed);
        assert_ne!(current.current_input_id(), original_input);
        let next_input = current.current_input_id();
        drop(store);
        store = JobStore::open(directory.path().into()).await.unwrap();
        current = store.read(current.job_id.clone()).await.unwrap();
        assert_eq!(current.current_input_id(), next_input);
        assert!(matches!(
            current.execution,
            ExecutionState::RetryWaiting {
                retry_at_ms: 2_000,
                ..
            }
        ));
        let dispatch = ExecutionState::Dispatching {
            conversation: conversation(),
            input_id: next_input.clone(),
        };
        assert!(
            store
                .advance(
                    current.job_id.clone(),
                    current.revision,
                    dispatch.clone(),
                    1_999
                )
                .await
                .is_err()
        );
        current = store
            .advance(current.job_id.clone(), current.revision, dispatch, 2_000)
            .await
            .unwrap();
        current = store
            .advance(
                current.job_id.clone(),
                current.revision,
                ExecutionState::Running {
                    binding: ExecutionBinding {
                        conversation: conversation(),
                        input_id: next_input,
                        turn_id: format!("failed-{}", attempt + 1),
                    },
                },
                2_001,
            )
            .await
            .unwrap();
    }
    assert!(
        store
            .schedule_provider_retry(
                current.job_id.clone(),
                current.revision,
                current.execution.binding().unwrap().clone(),
                "still unavailable".into(),
                3_000,
                2_002
            )
            .await
            .is_err()
    );
    assert_eq!(
        store
            .read(current.job_id.clone())
            .await
            .unwrap()
            .provider_retries
            .len(),
        5
    );
    let final_binding = current.execution.binding().cloned();
    let completed = store
        .advance(
            current.job_id.clone(),
            current.revision,
            ExecutionState::Terminal {
                terminal: Terminal {
                    at_ms: Some(2_003),
                    execution: final_binding,
                    git: GitSnapshot::Unknown {
                        reason: "fixture".into(),
                    },
                    outcome: JobOutcome::Completed,
                    result: ResultEvidence::Available {
                        result: JobResult {
                            text: "completed once".into(),
                            truncated: false,
                        },
                    },
                    completion: Completion::NotRequired,
                    cleanup: CleanupState::Complete,
                },
            },
            2_003,
        )
        .await
        .unwrap();
    assert!(
        matches!(completed.execution, ExecutionState::Terminal { terminal } if terminal.outcome == JobOutcome::Completed)
    );
}

#[tokio::test]
async fn stop_during_provider_backoff_survives_restart_and_blocks_successor_dispatch() {
    let directory = tempfile::tempdir().unwrap();
    let store = JobStore::open(directory.path().into()).await.unwrap();
    let current = running_retry_fixture(&store, 42).await;
    let waiting = store
        .schedule_provider_retry(
            current.job_id.clone(),
            current.revision,
            current.execution.binding().unwrap().clone(),
            "overloaded".into(),
            2_000,
            1_000,
        )
        .await
        .unwrap();
    store
        .request_stop(waiting.job_id.clone(), "stop-during-backoff".into(), 1_001)
        .await
        .unwrap();
    drop(store);
    let store = JobStore::open(directory.path().into()).await.unwrap();
    let stopped = store.read(waiting.job_id).await.unwrap();
    assert!(
        store
            .advance(
                stopped.job_id.clone(),
                stopped.revision,
                ExecutionState::Dispatching {
                    conversation: conversation(),
                    input_id: stopped.current_input_id(),
                },
                2_001
            )
            .await
            .is_err()
    );
    assert!(matches!(stopped.stop, StopState::Requested { .. }));
    assert_eq!(stopped.provider_retries.len(), 1);
}
