use super::*;

fn message(id: &str, at_ms: i64) -> MessageRecord {
    MessageRecord {
        delivery_id: id.into(),
        request_fingerprint: fingerprint(format!("request-{id}").as_bytes()),
        payload_fingerprint: fingerprint(b"frozen original envelope"),
        sender: Origin::TopLevel,
        requested_target: MessageTarget::Selector {
            selector: "missing-target".into(),
        },
        text: Some("frozen original envelope".into()),
        resolved: None,
        delivery_state: DeliveryState::Pending,
        created_at_ms: at_ms,
        updated_at_ms: at_ms,
    }
}

#[tokio::test]
async fn sender_receipts_survive_reopen_and_freeze_payload_before_resolution() {
    let root = tempfile::tempdir().unwrap();
    let store = JobStore::open(root.path().into()).await.unwrap();
    let original = message("durable-id", 100);
    store.admit_message(original.clone()).await.unwrap();
    let failed = store
        .update_message(
            original.delivery_id.clone(),
            DeliveryState::Failed {
                reason: "target does not exist".into(),
            },
            101,
        )
        .await
        .unwrap();
    drop(store);
    let store = JobStore::open(root.path().into()).await.unwrap();
    assert_eq!(
        store
            .message(original.delivery_id.clone())
            .await
            .unwrap()
            .delivery_state,
        failed.delivery_state
    );
    let mut duplicate = original.clone();
    duplicate.text = Some("changed computed envelope after sender moved".into());
    let retained = store.admit_message(duplicate).await.unwrap();
    assert_eq!(retained.text, original.text);
    assert_eq!(retained.delivery_state, failed.delivery_state);
    assert!(
        store
            .existing_message(original.delivery_id, fingerprint(b"different raw request"))
            .await
            .unwrap_err()
            .to_string()
            .contains("different sender, target or message")
    );
}

#[tokio::test]
async fn successful_payload_expiry_preserves_receipts_and_pins_unresolved_text() {
    let root = tempfile::tempdir().unwrap();
    let store = JobStore::open(root.path().into()).await.unwrap();
    store
        .admit_message(message("accepted-id", 100))
        .await
        .unwrap();
    store
        .update_message(
            "accepted-id".into(),
            DeliveryState::Accepted {
                receipt: "native accepted input receipt".into(),
            },
            101,
        )
        .await
        .unwrap();
    store
        .admit_message(message("unresolved-id", 100))
        .await
        .unwrap();
    store
        .admit_message(message("later-id", 102 + RETENTION_MS))
        .await
        .unwrap();
    let accepted = store.message("accepted-id".into()).await.unwrap();
    assert!(accepted.text.is_none());
    assert_eq!(
        accepted.request_fingerprint,
        message("accepted-id", 100).request_fingerprint
    );
    assert_eq!(
        accepted.delivery_state,
        DeliveryState::Accepted {
            receipt: "native accepted input receipt".into()
        }
    );
    assert_eq!(
        store
            .message("unresolved-id".into())
            .await
            .unwrap()
            .text
            .as_deref(),
        Some("frozen original envelope")
    );
    assert!(
        store
            .update_message(
                "accepted-id".into(),
                DeliveryState::Pending,
                103 + RETENTION_MS
            )
            .await
            .is_err()
    );
}

#[tokio::test]
async fn terminal_transport_and_lookup_receipts_do_not_exhaust_unresolved_capacity() {
    let root = tempfile::tempdir().unwrap();
    let store = JobStore::open(root.path().into()).await.unwrap();
    for index in 0..=MAX_UNSETTLED_JOBS {
        let id = format!("settled-{index}");
        store.admit_message(message(&id, 100)).await.unwrap();
        let state = if index % 2 == 0 {
            DeliveryState::Submitted {
                route: "claudeNative".into(),
            }
        } else {
            DeliveryState::Failed {
                reason: "target does not exist".into(),
            }
        };
        store.update_message(id, state, 101).await.unwrap();
    }
    store
        .admit_message(message("still-available", 102))
        .await
        .unwrap();
    store
        .admit_message(message("trigger-expiry", 102 + RETENTION_MS))
        .await
        .unwrap();
    for id in ["settled-0", "settled-1"] {
        let record = store.message(id.into()).await.unwrap();
        assert!(record.text.is_none());
        assert_eq!(
            record.payload_fingerprint,
            fingerprint(b"frozen original envelope")
        );
        assert!(
            store
                .update_message(id.into(), DeliveryState::Pending, 103 + RETENTION_MS)
                .await
                .is_err()
        );
    }
    assert_eq!(
        store
            .message("settled-0".into())
            .await
            .unwrap()
            .delivery_state,
        DeliveryState::Submitted {
            route: "claudeNative".into()
        }
    );
    assert_eq!(
        store
            .message("settled-1".into())
            .await
            .unwrap()
            .delivery_state,
        DeliveryState::Failed {
            reason: "target does not exist".into()
        }
    );
}

#[tokio::test]
async fn uncertain_and_retryable_delivery_payloads_remain_pinned_after_retention() {
    let root = tempfile::tempdir().unwrap();
    let store = JobStore::open(root.path().into()).await.unwrap();
    for (id, state) in [
        (
            "uncertain",
            DeliveryState::Uncertain {
                reason: "native acknowledgement lost".into(),
            },
        ),
        (
            "blocked",
            DeliveryState::Blocked {
                reason: "provider unavailable".into(),
            },
        ),
        (
            "unreachable",
            DeliveryState::Unreachable {
                reason: "native holder unavailable".into(),
            },
        ),
    ] {
        store.admit_message(message(id, 100)).await.unwrap();
        store.update_message(id.into(), state, 101).await.unwrap();
    }
    store
        .admit_message(message("after-retention", 102 + RETENTION_MS))
        .await
        .unwrap();
    for id in ["uncertain", "blocked", "unreachable"] {
        let record = store.message(id.into()).await.unwrap();
        assert_eq!(record.text.as_deref(), Some("frozen original envelope"));
        assert!(!record.settled());
    }
}
