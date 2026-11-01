use super::super::model::*;
use super::super::owner::now_ms;
use super::super::store::fingerprint;
use super::super::store_tests::job;
use crate::test_support::TestGateway;

const HOUR_MS: i64 = 60 * 60 * 1000;

fn receiver() -> Recipient {
    Recipient::Conversation {
        conversation: ConversationIdentity {
            provider: Provider::Codex,
            provider_home: ProviderHome::Known {
                path: "/tmp/job-fixture/codex".into(),
            },
            thread_id: "thread-fixture".into(),
        },
    }
}

fn completion(record: &JobRecord, delivery: DeliveryState) -> Completion {
    Completion::Required {
        payload: CompletionPayload::Prepared {
            delivery_id: format!("{}:completion", record.job_id.as_str()),
            fingerprint: fingerprint(b"Child finished."),
            text: "Child finished.".into(),
        },
        delivery,
    }
}

fn notice(record: &JobRecord, name: &str, delivery: DeliveryState) -> JobNotice {
    JobNotice {
        at_ms: Some(now_ms()),
        payload: CompletionPayload::Prepared {
            delivery_id: format!("{}:notice:{name}", record.job_id.as_str()),
            fingerprint: fingerprint(b"Still working."),
            text: "Still working.".into(),
        },
        delivery,
    }
}

async fn terminal(
    gateway: &TestGateway,
    mut record: JobRecord,
    completion: Completion,
    at_ms: i64,
) -> JobRecord {
    record.recipient = receiver();
    let store = gateway.jobs.store().await.unwrap();
    let (admitted, _) = store.admit(record).await.unwrap();
    store
        .advance(
            admitted.job_id,
            admitted.revision,
            ExecutionState::Terminal {
                terminal: Terminal {
                    at_ms: Some(at_ms),
                    execution: None,
                    git: GitSnapshot::Unknown {
                        reason: "fixture".into(),
                    },
                    outcome: JobOutcome::Completed,
                    result: ResultEvidence::Unavailable {
                        reason: "fixture".into(),
                    },
                    completion,
                    cleanup: CleanupState::Complete,
                },
            },
            at_ms,
        )
        .await
        .unwrap()
}

fn completion_state(record: &JobRecord) -> &DeliveryState {
    let ExecutionState::Terminal { terminal } = &record.execution else {
        panic!("fixture job is terminal");
    };
    let Completion::Required { delivery, .. } = &terminal.completion else {
        panic!("fixture job requires completion");
    };
    delivery
}

#[tokio::test]
async fn wakes_inside_the_retry_interval_never_rewrite_a_delivery() {
    let directory = tempfile::tempdir().unwrap();
    let gateway = TestGateway::with_native_runtime(directory.path());
    let record = job(1);
    let completion = completion(&record, DeliveryState::Pending);
    let job = terminal(&gateway, record, completion, now_ms() - HOUR_MS).await;
    let store = gateway.jobs.store().await.unwrap();

    gateway
        .jobs
        .reconcile_job(job.job_id.clone())
        .await
        .unwrap();
    let attempted = store.read(job.job_id.clone()).await.unwrap();
    assert!(matches!(
        completion_state(&attempted),
        DeliveryState::Uncertain { .. }
    ));
    for _ in 0..100 {
        gateway.jobs.dirty();
        gateway
            .jobs
            .reconcile_job(job.job_id.clone())
            .await
            .unwrap();
    }

    assert_eq!(
        store.read(job.job_id).await.unwrap().revision,
        attempted.revision
    );
}

#[tokio::test]
async fn a_never_accepted_completion_past_its_window_is_handed_off_without_sending() {
    let directory = tempfile::tempdir().unwrap();
    let gateway = TestGateway::with_native_runtime(directory.path());
    let record = job(2);
    let unreachable = DeliveryState::Unreachable {
        reason: "parent has no route".into(),
    };
    let completion = completion(&record, unreachable.clone());
    let job = terminal(&gateway, record, completion, now_ms() - 25 * HOUR_MS).await;
    let store = gateway.jobs.store().await.unwrap();
    let before = now_ms();

    gateway
        .jobs
        .reconcile_job(job.job_id.clone())
        .await
        .unwrap();

    let handed_off = store.read(job.job_id.clone()).await.unwrap();
    assert_eq!(completion_state(&handed_off), &unreachable);
    assert_eq!(
        handed_off.attention,
        Some(Attention::Surfaced {
            reason: "receiver could not be reconciled within 24 hours".into()
        })
    );
    assert!(handed_off.updated_at_ms >= before);
    assert!(!store.pending_ids().await.unwrap().contains(&job.job_id));
}

#[tokio::test]
async fn a_stored_failure_past_its_window_is_reconciled_once_before_hand_off() {
    let directory = tempfile::tempdir().unwrap();
    let gateway = TestGateway::with_native_runtime(directory.path());
    let record = job(3);
    let failed = DeliveryState::Failed {
        reason: "history appeared to hold different content".into(),
    };
    let completion = completion(&record, failed);
    let job = terminal(&gateway, record, completion, now_ms() - 25 * HOUR_MS).await;
    let store = gateway.jobs.store().await.unwrap();

    gateway
        .jobs
        .reconcile_job(job.job_id.clone())
        .await
        .unwrap();

    let handed_off = store.read(job.job_id.clone()).await.unwrap();
    assert!(matches!(
        completion_state(&handed_off),
        DeliveryState::Uncertain { .. }
    ));
    assert_eq!(handed_off.revision, job.revision + 4);
    assert_eq!(
        handed_off.attention,
        Some(Attention::Surfaced {
            reason: "receiver could not be reconciled within 24 hours".into()
        })
    );
    assert!(!store.pending_ids().await.unwrap().contains(&job.job_id));
}

#[tokio::test]
async fn a_terminal_jobs_notices_are_superseded_without_contacting_the_receiver() {
    let directory = tempfile::tempdir().unwrap();
    let gateway = TestGateway::with_native_runtime(directory.path());
    let mut record = job(4);
    record.notices = vec![
        notice(&record, "pending", DeliveryState::Pending),
        notice(
            &record,
            "uncertain",
            DeliveryState::Uncertain {
                reason: "reply lost".into(),
            },
        ),
    ];
    let job = terminal(&gateway, record, Completion::NotRequired, now_ms()).await;
    let store = gateway.jobs.store().await.unwrap();

    gateway
        .jobs
        .reconcile_job(job.job_id.clone())
        .await
        .unwrap();

    let settled = store.read(job.job_id.clone()).await.unwrap();
    assert_eq!(settled.revision, job.revision + 1);
    assert!(settled.notices.iter().all(|notice| notice.delivery
        == DeliveryState::Dismissed {
            reason: "superseded by the final result".into()
        }));
    assert!(!store.pending_ids().await.unwrap().contains(&job.job_id));
}
