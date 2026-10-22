use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::path::Path;

use anyhow::{Result, ensure};
use serde::Deserialize;
use tracing::info;

use super::{
    Document, Location, Purpose, SCHEMA_VERSION, Settlement, SettlementState, ThreadMarks,
};

const LEGACY_FILE_NAME: &str = "conversation-marks.json";
const LEGACY_SCHEMA_VERSION: u32 = 1;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LegacyDocument {
    schema_version: u32,
    revision: u64,
    read_baseline: i64,
    threads: BTreeMap<String, LegacyThreadMarks>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LegacyThreadMarks {
    revision: u64,
    #[serde(default)]
    seen_through: Option<i64>,
    #[serde(default)]
    marked_unread: bool,
    #[serde(default)]
    pin_name: Option<String>,
    #[serde(default)]
    archived_at: Option<i64>,
    #[serde(default)]
    purpose: Option<Purpose>,
}

#[derive(Deserialize)]
struct HandoffRecord {
    #[serde(default)]
    snapshot: Option<RecordedThread>,
    #[serde(default)]
    destination: Option<RecordedThread>,
    #[serde(default)]
    complete: bool,
    #[serde(default)]
    aborted: bool,
}

#[derive(Deserialize)]
struct RecordedThread {
    id: Option<String>,
}

pub(super) fn import(location: &Location) -> Result<Option<Document>> {
    if let Some(mut document) = super::read_json::<Document>(
        &location.directory.join("conversation-marks.v2.json"),
        "version 2 conversation marks",
    )? {
        ensure!(
            document.schema_version == 2,
            "unsupported conversation marks version"
        );
        ensure!(
            document
                .threads
                .values()
                .all(|marks| marks.done_through.is_none()),
            "invalid version 2 conversation marks"
        );
        document.validate()?;
        document.schema_version = SCHEMA_VERSION;
        return Ok(Some(document));
    }
    let Some(legacy) = super::read_json::<LegacyDocument>(
        &location.directory.join(LEGACY_FILE_NAME),
        "conversation marks",
    )?
    else {
        return Ok(None);
    };
    ensure!(
        legacy.schema_version == LEGACY_SCHEMA_VERSION,
        "unsupported conversation marks version"
    );
    let handoff_owned = handoff_owned_threads(&location.handoff_records)?;
    let archived = legacy
        .threads
        .values()
        .filter(|marks| marks.archived_at.is_some())
        .count();
    let document = migrate(legacy, &handoff_owned);
    document.validate()?;
    let settled = document
        .threads
        .values()
        .filter(|marks| marks.settlement.is_some())
        .count();
    info!(
        directory = %location.directory.display(),
        settled,
        dropped = archived - settled,
        pending_native_unarchive = document.pending_native_unarchive.len(),
        "conversation marks migrated to schema version 3"
    );
    Ok(Some(document))
}

fn handoff_owned_threads(path: &Path) -> Result<HashSet<String>> {
    let records = super::read_json::<Vec<HandoffRecord>>(path, "conversation handoff records")?
        .unwrap_or_default();
    Ok(records
        .into_iter()
        .flat_map(|record| {
            let abandoned = record.aborted || !record.complete;
            [record.snapshot, record.destination.filter(|_| abandoned)]
        })
        .flatten()
        .filter_map(|thread| thread.id)
        .collect())
}

fn migrate(legacy: LegacyDocument, handoff_owned: &HashSet<String>) -> Document {
    let mut pending_native_unarchive = BTreeSet::new();
    let threads = legacy
        .threads
        .into_iter()
        .filter_map(|(id, marks)| {
            let codex = !crate::providers::claude::is_claude_thread_id(&id);
            let settled_through = marks
                .archived_at
                .filter(|_| marks.purpose.is_none() && !(codex && handoff_owned.contains(&id)));
            if settled_through.is_some() && codex {
                pending_native_unarchive.insert(id.clone());
            }
            let migrated = ThreadMarks {
                revision: marks.revision,
                seen_through: marks.seen_through,
                marked_unread: marks.marked_unread,
                pin_name: marks.pin_name,
                purpose: marks.purpose,
                settlement: settled_through.map(|through| Settlement {
                    state: SettlementState::Settled,
                    through,
                }),
                done_through: None,
            };
            (!migrated.is_empty()).then_some((id, migrated))
        })
        .collect();
    Document {
        schema_version: SCHEMA_VERSION,
        revision: legacy.revision,
        read_baseline: legacy.read_baseline,
        threads,
        pending_native_unarchive,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conversation_marks::{ConversationMarksStore, FILE_NAME};
    use std::fs;

    #[tokio::test]
    async fn version_two_import_preserves_all_marks_and_pending_work_without_writing_older_files() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("conversation-marks.v2.json");
        let old = serde_json::json!({"schemaVersion":2,"revision":7,"readBaseline":10,"threads":{
            "a":{"revision":7,"seenThrough":30,"markedUnread":true,"pinName":"Keep","purpose":"automation","settlement":{"state":"active","through":40}}
        },"pendingNativeUnarchive":["native"]}).to_string();
        fs::write(&path, &old).unwrap();
        let legacy = directory.path().join(LEGACY_FILE_NAME);
        fs::write(&legacy, b"older rollback state").unwrap();
        let store = ConversationMarksStore::new(Some(Location {
            directory: directory.path().into(),
            handoff_records: directory.path().join("handoffs"),
        }));
        let imported = store.read(100).await.unwrap();
        assert_eq!(imported.schema_version, 3);
        assert_eq!(imported.revision, 7);
        assert_eq!(imported.read_baseline, 10);
        assert_eq!(imported.threads["a"].pin_name.as_deref(), Some("Keep"));
        assert_eq!(imported.threads["a"].seen_through, Some(30));
        assert!(imported.threads["a"].marked_unread);
        assert_eq!(imported.threads["a"].purpose, Some(Purpose::Automation));
        assert_eq!(
            imported.threads["a"].settlement,
            Some(Settlement {
                state: SettlementState::Active,
                through: 40
            })
        );
        assert_eq!(imported.threads["a"].done_through, None);
        assert_eq!(
            store.pending_native_unarchives(100).await.unwrap(),
            ["native"]
        );
        store
            .complete_native_unarchives(vec!["native".into()], 200)
            .await
            .unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), old);
        assert_eq!(fs::read(&legacy).unwrap(), b"older rollback state");
        assert!(directory.path().join(FILE_NAME).exists());
    }

    #[tokio::test]
    async fn the_first_load_imports_version_one_marks_and_leaves_them_untouched() {
        let directory = tempfile::tempdir().unwrap();
        let legacy_path = directory.path().join(LEGACY_FILE_NAME);
        let handoffs_path = directory.path().join("conversation-handoffs.json");
        let legacy = serde_json::to_vec(&serde_json::json!({
            "schemaVersion": 1,
            "revision": 9,
            "readBaseline": 10,
            "threads": {
                "codex-archived": {"revision": 3, "seenThrough": 40, "archivedAt": 50},
                "claude_archived": {"revision": 4, "pinName": "Keep", "archivedAt": 60},
                "codex-probe": {"revision": 5, "purpose": "probe", "archivedAt": 70},
                "codex-snapshot": {"revision": 6, "archivedAt": 80},
                "codex-abandoned": {"revision": 7, "markedUnread": true, "archivedAt": 85},
                "codex-continued": {"revision": 8, "archivedAt": 90},
                "codex-unread": {"revision": 9, "markedUnread": true}
            }
        }))
        .unwrap();
        fs::write(&legacy_path, &legacy).unwrap();
        fs::write(
            &handoffs_path,
            serde_json::to_vec(&serde_json::json!([
                {
                    "request": {"threadId": "codex-source"},
                    "snapshot": {"id": "codex-snapshot", "path": "/archived"},
                    "destination": {"id": "codex-continued"},
                    "complete": true,
                    "aborted": false
                },
                {
                    "request": {"threadId": "codex-source"},
                    "snapshot": null,
                    "destination": {"id": "codex-abandoned"},
                    "complete": false,
                    "aborted": true
                }
            ]))
            .unwrap(),
        )
        .unwrap();
        let store = ConversationMarksStore::new(Some(Location {
            directory: directory.path().to_path_buf(),
            handoff_records: handoffs_path,
        }));
        let settled = |through| {
            Some(Settlement {
                state: SettlementState::Settled,
                through,
            })
        };

        let marks = store.read(1_000).await.unwrap();
        assert_eq!(
            (marks.schema_version, marks.revision, marks.read_baseline),
            (3, 9, 10)
        );
        assert_eq!(marks.threads["codex-archived"].settlement, settled(50));
        assert_eq!(marks.threads["codex-archived"].seen_through, Some(40));
        assert_eq!(marks.threads["claude_archived"].settlement, settled(60));
        assert_eq!(
            marks.threads["claude_archived"].pin_name.as_deref(),
            Some("Keep")
        );
        assert_eq!(marks.threads["codex-continued"].settlement, settled(90));
        assert_eq!(marks.threads["codex-probe"].settlement, None);
        assert_eq!(marks.threads["codex-probe"].purpose, Some(Purpose::Probe));
        assert_eq!(marks.threads["codex-abandoned"].settlement, None);
        assert!(marks.threads["codex-abandoned"].marked_unread);
        assert!(!marks.threads.contains_key("codex-snapshot"));
        assert_eq!(
            marks.threads["codex-unread"],
            ThreadMarks {
                revision: 9,
                marked_unread: true,
                ..ThreadMarks::default()
            }
        );
        assert_eq!(
            store.pending_native_unarchives(1_000).await.unwrap(),
            ["codex-archived", "codex-continued"]
        );
        assert_eq!(fs::read(&legacy_path).unwrap(), legacy);

        fs::write(&legacy_path, b"not json").unwrap();
        assert_eq!(store.read(2_000).await.unwrap(), marks);
        assert_eq!(
            store
                .complete_native_unarchives(vec!["codex-archived".into()], 2_000)
                .await
                .unwrap(),
            1
        );
        assert_eq!(
            store
                .complete_native_unarchives(vec!["codex-continued".into()], 2_000)
                .await
                .unwrap(),
            0
        );
        let stored: serde_json::Value =
            serde_json::from_slice(&fs::read(directory.path().join(FILE_NAME)).unwrap()).unwrap();
        assert_eq!(stored["schemaVersion"], 3);
        assert!(stored.get("pendingNativeUnarchive").is_none());
    }
}
