use super::*;
use serde_json::json;

#[tokio::test]
async fn live_and_reloaded_positions_match_across_steering_and_late_completions() {
    let home = tempfile::TempDir::new().unwrap();
    let store = Store::new(home.path().to_path_buf());
    let thread = "claude-session";
    let actual_turn = "claude-turn-live";
    let mut frames = vec![
        json!({"method":"turn/started","params":{"threadId":thread,"turn":{"id":actual_turn,"startedAtMs":1000,"status":"inProgress"}}}),
        frame(
            thread,
            actual_turn,
            "item/completed",
            json!({"type":"userMessage","id":"user","clientId":"user","content":[]}),
        ),
        frame(
            thread,
            actual_turn,
            "item/started",
            json!({"type":"commandExecution","id":"first"}),
        ),
        frame(
            thread,
            actual_turn,
            "item/completed",
            json!({"type":"agentMessage","id":"msg#0","text":"Progress"}),
        ),
        frame(
            thread,
            actual_turn,
            "item/completed",
            json!({"type":"userMessage","id":"steer","clientId":"steer","content":[]}),
        ),
        frame(
            thread,
            actual_turn,
            "item/started",
            json!({"type":"commandExecution","id":"second"}),
        ),
        frame(
            thread,
            actual_turn,
            "item/completed",
            json!({"type":"commandExecution","id":"first"}),
        ),
        frame(
            thread,
            actual_turn,
            "item/completed",
            json!({"type":"commandExecution","id":"second"}),
        ),
    ];
    for frame in &mut frames {
        store.record(frame).await.unwrap();
    }
    assert_eq!(
        frames[2]["params"]["startedAtOrdinal"],
        frames[6]["params"]["startedAtOrdinal"]
    );
    let index = read(home.path(), thread).unwrap();
    let mut order = index.items.values().collect::<Vec<_>>();
    order.sort_by_key(|item| item.started_at_ordinal);
    assert_eq!(
        order
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        vec!["user", "first", "msg#0", "steer", "second"]
    );
}

#[tokio::test]
async fn interrupted_append_is_ignored_by_reads_and_repaired_before_the_next_write() {
    let home = tempfile::TempDir::new().unwrap();
    let store = Store::new(home.path().to_path_buf());
    let mut first = frame(
        "thread",
        "turn",
        "item/started",
        json!({"id":"first","type":"commandExecution"}),
    );
    store.record(&mut first).await.unwrap();
    let file = path(home.path(), "thread");
    OpenOptions::new()
        .append(true)
        .open(&file)
        .unwrap()
        .write_all(b"{incomplete")
        .unwrap();
    assert_eq!(read(home.path(), "thread").unwrap().items.len(), 1);
    let replacement = Store::new(home.path().to_path_buf());
    let mut second = frame(
        "thread",
        "turn",
        "item/started",
        json!({"id":"second","type":"commandExecution"}),
    );
    replacement.record(&mut second).await.unwrap();
    let restored = read(home.path(), "thread").unwrap();
    assert_eq!(restored.items.len(), 2);
    assert_eq!(
        restored.items["second"].started_at_ordinal,
        restored.items["first"].started_at_ordinal + 1
    );
}

#[tokio::test]
async fn failed_persistence_does_not_advertise_an_uncommitted_position() {
    let home = tempfile::TempDir::new().unwrap();
    fs::write(home.path().join("remotecoder-history"), b"occupied").unwrap();
    let store = Store::new(home.path().to_path_buf());
    let mut note = frame(
        "thread",
        "turn",
        "item/started",
        json!({"id":"first","type":"commandExecution"}),
    );
    assert!(store.record(&mut note).await.is_err());
    assert!(note["params"].get("startedAtOrdinal").is_none());
}

fn frame(thread: &str, turn: &str, method: &str, item: Value) -> Value {
    json!({"method":method,"params":{"threadId":thread,"turnId":turn,"item":item,"startedAtMs":1000,"completedAtMs":2000}})
}

#[tokio::test]
async fn creation_record_survives_a_new_store_and_proves_only_its_own_thread() {
    use std::os::unix::fs::PermissionsExt;
    let home = tempfile::TempDir::new().unwrap();
    let thread = "claude_00000000-0000-4000-8000-000000000001";
    Store::new(home.path().to_path_buf())
        .record_minted(thread)
        .await
        .unwrap();

    let restarted = Store::new(home.path().to_path_buf());
    assert!(restarted.is_minted(thread).unwrap());
    assert!(
        !restarted
            .is_minted("claude_00000000-0000-4000-8000-000000000002")
            .unwrap()
    );
    assert!(restarted.record_minted(thread).await.is_err());
    let record = minted_path(home.path(), thread);
    assert_eq!(
        fs::metadata(&record).unwrap().permissions().mode() & 0o777,
        0o600
    );

    let copied = "claude_00000000-0000-4000-8000-000000000003";
    fs::copy(&record, minted_path(home.path(), copied)).unwrap();
    assert!(restarted.is_minted(copied).is_err());
    let truncated = "claude_00000000-0000-4000-8000-000000000004";
    fs::write(minted_path(home.path(), truncated), b"{\"threadId\":").unwrap();
    assert!(restarted.is_minted(truncated).is_err());
    let linked = "claude_00000000-0000-4000-8000-000000000005";
    let elsewhere = tempfile::TempDir::new().unwrap();
    Store::new(elsewhere.path().to_path_buf())
        .record_minted(linked)
        .await
        .unwrap();
    std::os::unix::fs::symlink(
        minted_path(elsewhere.path(), linked),
        minted_path(home.path(), linked),
    )
    .unwrap();
    assert!(restarted.is_minted(linked).is_err());
}

#[tokio::test]
async fn a_cancelled_caller_keeps_the_thread_locked_until_its_blocking_write_ends() {
    let home = tempfile::TempDir::new().unwrap();
    let store = Store::new(home.path().to_path_buf());
    let (started_sender, started) = std::sync::mpsc::channel();
    let (release, released) = std::sync::mpsc::channel::<()>();
    let held = store.thread("thread").await.lock_owned().await;
    let write = tokio::spawn(under_guards(held, move |_| {
        started_sender.send(()).unwrap();
        released.recv().unwrap();
    }));
    tokio::task::spawn_blocking(move || started.recv())
        .await
        .unwrap()
        .unwrap();

    write.abort();
    let _ = write.await;
    let waiting = tokio::time::timeout(
        std::time::Duration::from_millis(50),
        store.thread("thread").await.lock_owned(),
    )
    .await;
    assert!(waiting.is_err());

    release.send(()).unwrap();
    tokio::time::timeout(
        std::time::Duration::from_secs(2),
        store.thread("thread").await.lock_owned(),
    )
    .await
    .expect("the lock is released once the blocking write ends");
}

#[tokio::test]
async fn an_oversized_parent_or_creation_record_is_refused_before_it_is_parsed() {
    let home = tempfile::TempDir::new().unwrap();
    let store = Store::new(home.path().to_path_buf());
    let thread = "claude_00000000-0000-4000-8000-000000000021";
    fs::create_dir_all(home.path().join("remotecoder-history")).unwrap();
    fs::write(
        parent_path(home.path(), thread),
        vec![b' '; MAX_PARENT_RECORD_BYTES as usize + 1],
    )
    .unwrap();
    fs::write(
        minted_path(home.path(), thread),
        vec![b' '; MAX_MINTED_RECORD_BYTES as usize + 1],
    )
    .unwrap();

    let refused = store.parent(thread).await.unwrap_err();
    assert!(refused.to_string().contains("too large"));
    let refused = store.is_minted(thread).unwrap_err();
    assert!(refused.to_string().contains("too large"));
}

#[test]
fn historical_id_capacity_identity_records_refuse_keys_before_map_insertion() {
    let item = ItemIdentity {
        id: format!("{}#{}", "m".repeat(4096), usize::MAX),
        turn_id: "turn".into(),
        started_at_ordinal: 0,
        started_at_ms: 1,
        completed_at_ms: None,
        is_complete: false,
        client_id: Some("client".into()),
        synthetic_item: None,
    };
    let encode = |record: &Record| {
        let mut data = serde_json::to_vec(record).unwrap();
        data.push(b'\n');
        data
    };
    assert_eq!(
        parse(&encode(&Record::Item(item.clone())))
            .unwrap()
            .items
            .len(),
        1
    );
    let cases = [
        (
            Record::Item(ItemIdentity {
                id: "x".repeat(4129),
                ..item.clone()
            }),
            4128,
        ),
        (
            Record::Item(ItemIdentity {
                turn_id: "x".repeat(4097),
                ..item.clone()
            }),
            4096,
        ),
        (
            Record::Item(ItemIdentity {
                client_id: Some("x".repeat(4097)),
                ..item
            }),
            4096,
        ),
        (
            Record::Turn(TurnIdentity {
                id: "x".repeat(4097),
                started_at_ms: 1,
                completed_at_ms: None,
                status: "inProgress".into(),
                error: None,
                recovery: None,
            }),
            4096,
        ),
    ];
    for (record, limit) in cases {
        let error = parse(&encode(&record))
            .err()
            .expect("oversized identity must be refused");
        let capacity = error
            .downcast_ref::<crate::providers::claude::capacity::CapacityExceeded>()
            .unwrap();
        assert_eq!(capacity.resource, "historical identity ID bytes");
        assert_eq!(capacity.limit, limit);
    }
}
