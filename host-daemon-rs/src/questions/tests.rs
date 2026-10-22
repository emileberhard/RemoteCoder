use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use super::*;

fn incident() -> Value {
    serde_json::from_str(include_str!(
        "../../../protocol-fixtures/questions/answered-outside-viewport.json"
    ))
    .unwrap()
}

fn reduce(entries: Vec<Entry>) -> Facts {
    let mut facts = Facts::default();
    for entry in entries {
        if let Some(fact) = normalize(&entry).unwrap() {
            facts.apply(fact).unwrap();
        }
    }
    facts
}

#[test]
fn cold_reconstruction_resolves_answer_before_definition_in_descending_pages() {
    let fixture = incident();
    let mut entries: Vec<Entry> =
        serde_json::from_value(fixture["canonicalItems"].clone()).unwrap();
    let viewport: Vec<Entry> = entries.iter().rev().take(50).cloned().collect();
    let forwards = reduce(entries.clone());
    entries.reverse();
    let backwards = reduce(entries.clone());
    assert_eq!(forwards, backwards);
    // A second observer delivers the same completions; no second meaning.
    entries.extend(entries.clone());
    assert_eq!(reduce(entries), backwards);
    let records = backwards.records(&BTreeMap::new(), &BTreeMap::new());
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].questions[0].resolution, Resolution::Answered);
    assert_eq!(
        records[0].questions[0].answer.as_ref().unwrap().text,
        "External"
    );
    assert!(!records[0].is_pending());
    assert_eq!(viewport.len(), 50);
    assert_eq!(viewport.first().unwrap().started_at_ordinal, Some(1034));
    assert_eq!(viewport.last().unwrap().started_at_ordinal, Some(985));
    assert!(reduce(viewport).definitions.is_empty());
}

fn question(id: &str, ordinal: i64, slots: usize) -> Fact {
    Fact::Asked(Definition {
        item_id: id.into(),
        turn_id: "turn".into(),
        ordinal,
        asked_at_ms: None,
        questions: (0..slots)
            .map(|index| Choice {
                title: format!("Question {index}"),
                options: vec!["A".into(), "B".into()],
            })
            .collect(),
    })
}

fn answer(id: &str, index: usize, ordinal: i64) -> Fact {
    Fact::Answered(vec![(
        id.into(),
        index,
        Answer {
            text: format!("answer-{ordinal}"),
            item_id: format!("input-{ordinal}"),
            ordinal,
            at_ms: None,
            client_id: None,
        },
    )])
}

#[test]
fn partial_answers_keep_original_indices_and_canonical_order_wins() {
    let mut facts = Facts::default();
    for fact in [
        question("a", 1, 3),
        question("b", 2, 2),
        answer("a", 2, 8),
        answer("a", 2, 6),
    ] {
        facts.apply(fact).unwrap();
    }
    let records = facts.records(&BTreeMap::new(), &BTreeMap::new());
    assert!(records.iter().all(Record::is_pending));
    assert_eq!(
        records[0]
            .questions
            .iter()
            .map(|slot| slot.resolution)
            .collect::<Vec<_>>(),
        [
            Resolution::Pending,
            Resolution::Pending,
            Resolution::Answered
        ]
    );
    assert_eq!(
        records[0].questions[2].answer.as_ref().unwrap().text,
        "answer-8"
    );
    facts.apply(Fact::Plain { ordinal: 10 }).unwrap();
    let records = facts.records(&BTreeMap::new(), &BTreeMap::new());
    assert!(!records.iter().any(Record::is_pending));
    assert_eq!(records[0].questions[2].resolution, Resolution::Answered);
    facts.apply(question("c", 11, 1)).unwrap();
    assert!(facts.records(&BTreeMap::new(), &BTreeMap::new())[2].is_pending());
}

#[test]
fn malformed_foreign_and_synthetic_inputs_never_become_blanket_supersession() {
    for text in [
        "<send_user_message_question_reply>broken</send_user_message_question_reply>",
        "quoted <send_user_message_question_reply>",
        "<send_user_message_question_reply>[{\"questionItemId\":\"[\\\"other_tool\\\",\\\"a\\\",0]\",\"answer\":\"B\"}]</send_user_message_question_reply>",
        "<realtime_delegation><source>transcript_tail_flush</source><input>Ended</input></realtime_delegation>",
        "<system-reminder>Context</system-reminder>",
        "<task-notification>Finished</task-notification>",
    ] {
        let entry = Entry {
            turn_id: "turn".into(),
            item: json!({"type":"userMessage","id":"input","content":[{"type":"text","text":text}]}),
            started_at_ordinal: Some(5),
            started_at_ms: None,
            completed_at_ms: None,
            is_complete: Some(true),
        };
        assert_eq!(normalize(&entry).unwrap(), None, "{text}");
    }
}

#[tokio::test]
async fn dismissal_is_durable_idempotent_and_cannot_erase_canonical_answers() {
    let root = tempfile::tempdir().unwrap();
    let store = QuestionStore::new(Some(root.path().into()));
    let initial = store
        .transaction("thread", |document| {
            let mut facts = Facts::default();
            facts.apply(question("a", 1, 3))?;
            facts.apply(answer("a", 2, 3))?;
            document.replace_facts(facts, None, BTreeMap::new())?;
            Ok(document.records()[0].clone())
        })
        .await
        .unwrap();
    let request = DismissRequest {
        expected_epoch: store.read("thread").await.unwrap().epoch,
        thread_id: "thread".into(),
        item_id: "a".into(),
        expected_record_revision: initial.revision,
        mutation_id: "dismiss-1".into(),
    };
    let first = store
        .transaction("thread", {
            let request = request.clone();
            move |document| document.dismiss(&request)
        })
        .await
        .unwrap();
    let restarted = QuestionStore::new(Some(root.path().into()));
    let again = restarted
        .transaction("thread", {
            let request = request.clone();
            move |document| document.dismiss(&request)
        })
        .await
        .unwrap();
    assert_eq!(first, again);
    assert!(!first.0);
    assert_eq!(
        first
            .1
            .questions
            .iter()
            .map(|slot| slot.resolution)
            .collect::<Vec<_>>(),
        [
            Resolution::Dismissed,
            Resolution::Dismissed,
            Resolution::Answered
        ]
    );
    let final_record = restarted
        .transaction("thread", |document| {
            let mut facts = document.facts.clone();
            facts.apply(answer("a", 0, 20))?;
            document.replace_facts(facts, None, BTreeMap::new())?;
            Ok(document.records()[0].clone())
        })
        .await
        .unwrap();
    assert_eq!(final_record.questions[0].resolution, Resolution::Answered);
    let mut invalid = request;
    invalid.expected_record_revision += 1;
    assert!(
        restarted
            .transaction("thread", move |document| document.dismiss(&invalid))
            .await
            .is_err()
    );
}

#[tokio::test]
async fn stale_dismissal_conflicts_and_competing_store_instances_preserve_writes() {
    let root = tempfile::tempdir().unwrap();
    let first = QuestionStore::new(Some(root.path().into()));
    let second = QuestionStore::new(Some(root.path().into()));
    first
        .transaction("thread", |document| {
            let mut facts = Facts::default();
            facts.apply(question("a", 1, 2))?;
            document.replace_facts(facts, None, BTreeMap::new())
        })
        .await
        .unwrap();
    let (a, b) = tokio::join!(
        first.transaction("thread", |document| {
            document.alert_attempted.insert("a".into());
            Ok(())
        }),
        second.transaction("thread", |document| {
            document.alert_attempted.insert("b".into());
            Ok(())
        })
    );
    a.unwrap();
    b.unwrap();
    assert_eq!(
        first.read("thread").await.unwrap().alert_attempted,
        BTreeSet::from(["a".into(), "b".into()])
    );
    let stale = DismissRequest {
        expected_epoch: first.read("thread").await.unwrap().epoch,
        thread_id: "thread".into(),
        item_id: "a".into(),
        expected_record_revision: 0,
        mutation_id: "stale".into(),
    };
    assert!(
        first
            .transaction("thread", move |document| document.dismiss(&stale))
            .await
            .unwrap()
            .0
    );
}

#[tokio::test]
async fn failed_transactions_preserve_original_and_thread_paths_cannot_escape() {
    let root = tempfile::tempdir().unwrap();
    let store = QuestionStore::new(Some(root.path().into()));
    store.read("../../outside").await.unwrap();
    let files: Vec<_> = std::fs::read_dir(root.path())
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    let path = files
        .iter()
        .find(|path| path.extension().unwrap() == "json")
        .unwrap();
    let before = std::fs::read(path).unwrap();
    assert!(
        store
            .transaction("../../outside", |document| -> anyhow::Result<()> {
                document.alert_attempted.insert("not-committed".into());
                anyhow::bail!("injected failure")
            })
            .await
            .is_err()
    );
    assert_eq!(std::fs::read(path).unwrap(), before);
    for bytes in [b"broken".as_slice(), br#"{"schemaVersion":99}"#] {
        std::fs::write(path, bytes).unwrap();
        assert!(store.read("../../outside").await.is_err());
        assert_eq!(std::fs::read(path).unwrap(), bytes);
    }
}

#[tokio::test]
async fn a_stale_epoch_cannot_dismiss_a_replacement_history_with_reused_ids() {
    let root = tempfile::tempdir().unwrap();
    let store = QuestionStore::new(Some(root.path().into()));
    let original = store
        .transaction("thread", |document| {
            let mut facts = Facts::default();
            facts.apply(question("q", 1, 1))?;
            document.replace_facts(facts, None, BTreeMap::new())?;
            Ok(document.clone())
        })
        .await
        .unwrap();
    let request = DismissRequest {
        thread_id: "thread".into(),
        item_id: "q".into(),
        expected_epoch: original.epoch.clone(),
        expected_record_revision: original.records()[0].revision,
        mutation_id: "old-dismissal".into(),
    };
    store
        .transaction("thread", {
            let request = request.clone();
            move |document| {
                document.dismiss(&request)?;
                Ok(())
            }
        })
        .await
        .unwrap();
    store
        .transaction("thread", |document| {
            document.reset_lineage()?;
            let mut facts = Facts::default();
            facts.apply(question("q", 1, 1))?;
            document.replace_facts(facts, None, BTreeMap::new())
        })
        .await
        .unwrap();
    let result = store
        .transaction("thread", move |document| document.dismiss(&request))
        .await
        .unwrap();
    assert!(result.0);
    assert!(result.1.is_pending());
}
