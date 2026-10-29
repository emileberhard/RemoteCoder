use super::*;
use crate::agents::jobs::store_tests::job;
use crate::wire::cluster::*;

fn conversation(sequence: u8) -> ConversationIdentity {
    ConversationIdentity {
        provider: Provider::Codex,
        provider_home: ProviderHome::Known {
            path: "/tmp/cluster-store-fixture/.codex".into(),
        },
        thread_id: format!("00000000-0000-4000-8000-{sequence:012x}"),
    }
}

fn address(sequence: u8) -> AgentAddress {
    AgentAddress {
        host_id: "fixture-host".into(),
        thread_id: conversation(sequence).thread_id,
    }
}

async fn child(store: &JobStore, sequence: u8, parent: u8) -> JobRecord {
    let mut record = job(sequence);
    record.created_at_ms = Some(100 + i64::from(sequence));
    record.updated_at_ms = 100 + i64::from(sequence);
    record.initial_parent = Some(address(parent));
    record.admission_origin = Some(Origin::Parent {
        conversation: conversation(parent),
    });
    record.recipient = Recipient::Conversation {
        conversation: conversation(parent),
    };
    store.admit(record.clone()).await.unwrap();
    store
        .bind(record.job_id, 0, conversation(sequence), 200)
        .await
        .unwrap()
}

#[tokio::test]
async fn cluster_parent_pages_seek_selected_indexes_and_follow_moves_promotion_and_reload() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().to_owned();
    let store = JobStore::open(root.clone()).await.unwrap();
    let a = child(&store, 1, 10).await;
    let b = child(&store, 2, 10).await;
    let nested = child(&store, 3, 1).await;
    let unrelated = job(250).job_id;
    store
        .access(move |inner| {
            inner.indexes.order.insert((Some(999), unrelated));
            Ok(())
        })
        .await
        .unwrap();
    assert!(store.list(Selection::Recent, 1, None).await.is_err());
    let first = store
        .list(Selection::Children(address(10)), 1, None)
        .await
        .unwrap();
    assert_eq!(
        first.jobs.iter().map(|row| &row.job_id).collect::<Vec<_>>(),
        vec![&b.job_id]
    );
    assert_eq!(first.next_cursor.as_deref(), Some(b.job_id.as_str()));
    let second = store
        .list(Selection::Children(address(10)), 1, first.next_cursor)
        .await
        .unwrap();
    assert_eq!(
        second
            .jobs
            .iter()
            .map(|row| &row.job_id)
            .collect::<Vec<_>>(),
        vec![&a.job_id]
    );
    assert!(second.next_cursor.is_none());
    let descendants = store
        .list(Selection::Descendants(address(10)), 10, None)
        .await
        .unwrap();
    assert_eq!(
        descendants
            .jobs
            .iter()
            .map(|row| &row.job_id)
            .collect::<Vec<_>>(),
        vec![&nested.job_id, &b.job_id, &a.job_id]
    );
    for selection in [
        Selection::Children(address(99)),
        Selection::Descendants(address(99)),
    ] {
        let page = store.list(selection, 1, None).await.unwrap();
        assert!(page.jobs.is_empty());
        assert!(page.next_cursor.is_none());
    }
    store
        .set_parent_for_test(
            a.agent_id.clone(),
            Some(address(11)),
            Recipient::Conversation {
                conversation: conversation(11),
            },
        )
        .await
        .unwrap();
    let moved = store
        .list(Selection::Descendants(address(11)), 10, None)
        .await
        .unwrap();
    assert_eq!(
        moved.jobs.iter().map(|row| &row.job_id).collect::<Vec<_>>(),
        vec![&nested.job_id, &a.job_id]
    );
    store
        .set_parent_for_test(a.agent_id, None, Recipient::None)
        .await
        .unwrap();
    drop(store);
    let store = JobStore::open(root).await.unwrap();
    let original = store
        .list(Selection::Descendants(address(10)), 10, None)
        .await
        .unwrap();
    assert_eq!(
        original
            .jobs
            .iter()
            .map(|row| &row.job_id)
            .collect::<Vec<_>>(),
        vec![&b.job_id]
    );
    assert!(
        store
            .list(Selection::Descendants(address(11)), 10, None)
            .await
            .unwrap()
            .jobs
            .is_empty()
    );
    let retained = store
        .list(Selection::Children(address(1)), 10, None)
        .await
        .unwrap();
    assert_eq!(
        retained
            .jobs
            .iter()
            .map(|row| &row.job_id)
            .collect::<Vec<_>>(),
        vec![&nested.job_id]
    );
}

#[tokio::test]
async fn cluster_parent_move_rechecks_current_graph_before_committing_a_stale_snapshot() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().to_owned();
    let store = JobStore::open(root.clone()).await.unwrap();
    for (id, sequence) in [("a", 20), ("b", 21)] {
        store
            .adopt_conversation(AgentRecord {
                agent_id: id.into(),
                parent: None,
                parent_revision: 0,
                parent_recipient: Some(Recipient::None),
                conversation: ConversationBinding::Known {
                    conversation: conversation(sequence),
                },
                origin: Origin::TopLevel,
                tool_scope: Some(ToolScope::Full),
                origin_job_id: None,
                latest_job_id: None,
            })
            .await
            .unwrap();
    }
    let snapshots = HashMap::from([
        (address(20), (Some(conversation(20)), None)),
        (address(21), (Some(conversation(21)), None)),
    ]);
    store
        .set_parent(
            "a".into(),
            Some(address(21)),
            Recipient::Conversation {
                conversation: conversation(21),
            },
            address(20),
            snapshots.clone(),
        )
        .await
        .unwrap();
    assert!(
        store
            .set_parent(
                "b".into(),
                Some(address(20)),
                Recipient::Conversation {
                    conversation: conversation(20)
                },
                address(21),
                snapshots
            )
            .await
            .unwrap_err()
            .to_string()
            .contains("cycle")
    );
    assert_eq!(
        store.agent("a".into()).await.unwrap().parent,
        Some(address(21))
    );
    assert_eq!(store.agent("b".into()).await.unwrap().parent, None);
    drop(store);
    let store = JobStore::open(root).await.unwrap();
    assert_eq!(
        store.agent("a".into()).await.unwrap().parent,
        Some(address(21))
    );
    assert_eq!(store.agent("b".into()).await.unwrap().parent, None);
}

fn intent(sequence: u8) -> RemoteIntent {
    let record = job(sequence);
    let SpecEvidence::Known { spec } = record.spec else {
        panic!("fixture has no spec");
    };
    RemoteIntent {
        protocol: PROTOCOL,
        host: "remote-host".into(),
        membership: "fixture-membership".into(),
        incarnation: "fixture-incarnation".into(),
        request: AdmitParams {
            protocol: PROTOCOL,
            job_id: record.job_id,
            fingerprint: format!("intent-{sequence}"),
            incarnation: "fixture-incarnation".into(),
            origin: Origin::TopLevel,
            recipient: Recipient::None,
            operation: AdmissionOperation::Start(spec),
            caller_authority: CallerAuthority::Operator,
        },
        parent: None,
        created_at: "2026-01-01T00:00:00Z".into(),
        state: IntentState::Pending,
        stop_confirmed: false,
        transmission_uncertain: false,
    }
}

async fn unsettled(store: &JobStore) -> usize {
    store
        .access(|inner| Ok(inner.indexes.unsettled_intents))
        .await
        .unwrap()
}

#[tokio::test]
async fn cluster_unsettled_intent_count_tracks_admission_stop_confirmation_and_reload() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().to_owned();
    let store = JobStore::open(root.clone()).await.unwrap();
    let first = intent(30);
    let second = intent(31);
    store.put_intent(first.clone()).await.unwrap();
    store.put_intent(second.clone()).await.unwrap();
    assert_eq!(unsettled(&store).await, 2);
    store
        .intent_state(first.request.job_id.clone(), IntentState::Admitted)
        .await
        .unwrap();
    assert_eq!(unsettled(&store).await, 1);
    store
        .intent_state(second.request.job_id.clone(), IntentState::StopRequested)
        .await
        .unwrap();
    assert_eq!(unsettled(&store).await, 1);
    store
        .confirm_remote_stop(second.request.job_id)
        .await
        .unwrap();
    assert_eq!(unsettled(&store).await, 0);
    drop(store);
    let store = JobStore::open(root.clone()).await.unwrap();
    assert_eq!(unsettled(&store).await, 0);
    store
        .intent_state(first.request.job_id.clone(), IntentState::StopRequested)
        .await
        .unwrap();
    assert_eq!(unsettled(&store).await, 1);
    drop(store);
    let store = JobStore::open(root).await.unwrap();
    assert_eq!(unsettled(&store).await, 1);
    store
        .confirm_remote_stop(first.request.job_id)
        .await
        .unwrap();
    assert_eq!(unsettled(&store).await, 0);
}

#[tokio::test]
async fn cluster_cancel_fences_match_both_membership_and_exact_job_on_admission() {
    let directory = tempfile::tempdir().unwrap();
    let store = JobStore::open(directory.path().to_owned()).await.unwrap();
    let mut unmatched_member = job(40);
    unmatched_member.admitted_membership = Some("member-a".into());
    let mut unmatched_job = job(41);
    unmatched_job.admitted_membership = Some("member-a".into());
    let mut matched = job(42);
    matched.admitted_membership = Some("member-a".into());
    for (membership, id) in [
        ("member-b", unmatched_member.job_id.clone()),
        ("member-a", job(43).job_id),
        ("member-a", matched.job_id.clone()),
    ] {
        assert!(
            store
                .cancel_remote(CancelFence {
                    protocol: PROTOCOL,
                    host: "remote-host".into(),
                    membership: membership.into(),
                    job_id: id,
                    at: 77
                })
                .await
                .unwrap()
                .is_none()
        );
    }
    for record in [unmatched_member, unmatched_job] {
        assert!(matches!(
            store.admit(record).await.unwrap().0.stop,
            StopState::NotRequested
        ));
    }
    let record = store.admit(matched).await.unwrap().0;
    assert_eq!(
        record.stop,
        StopState::Requested {
            mutation_id: "cluster:member-a".into(),
            at_ms: 77
        }
    );
}

#[tokio::test]
async fn cluster_intent_claim_rechecks_closed_state_after_a_queued_attempt() {
    let directory = tempfile::tempdir().unwrap();
    let store = JobStore::open(directory.path().to_owned()).await.unwrap();
    let intent = intent(50);
    let id = intent.request.job_id.clone();
    store.put_intent(intent).await.unwrap();
    let first = store.claim_intent(&id).await.unwrap();
    let second = store.claim_intent(&id);
    tokio::pin!(second);
    assert!(futures_util::poll!(&mut second).is_pending());
    store
        .intent_state(id.clone(), IntentState::Abandoned)
        .await
        .unwrap();
    drop(first);
    let _second = second.await.unwrap();
    assert!(
        store
            .begin_intent_attempt(id.clone())
            .await
            .unwrap_err()
            .to_string()
            .contains("closed to admission")
    );
}

#[tokio::test]
async fn cluster_intent_attempt_uncertainty_is_persisted_before_admission_and_survives_reload() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().to_owned();
    let store = JobStore::open(root.clone()).await.unwrap();
    let intent = intent(51);
    let id = intent.request.job_id.clone();
    store.put_intent(intent).await.unwrap();
    let claim = store.claim_intent(&id).await.unwrap();
    let (retained, previous) = store.begin_intent_attempt(id.clone()).await.unwrap();
    assert!(!previous);
    assert!(retained.transmission_uncertain);
    drop(claim);
    drop(store);
    let store = JobStore::open(root).await.unwrap();
    let _claim = store.claim_intent(&id).await.unwrap();
    let (retained, previous) = store.begin_intent_attempt(id).await.unwrap();
    assert!(previous);
    assert!(retained.transmission_uncertain);
}
