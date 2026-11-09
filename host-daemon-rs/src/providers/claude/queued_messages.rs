use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tracing::warn;

use super::capacity::CapacityExceeded;
use super::records::read_record;
use crate::storage::private_state;

const VERSION: u32 = 1;
const EXTENSION: &str = "queue";
pub(crate) const MAX_ENTRY_BYTES: usize = 1 << 20;
pub(crate) const MAX_THREAD_ENTRIES: usize = 100;
pub(crate) const MAX_THREAD_BYTES: usize = 8 << 20;
pub(crate) const MAX_TOTAL_BYTES: u64 = 32 << 20;
pub(crate) const MAX_THREADS: usize = 256;
const MAX_HOLD_MESSAGE_BYTES: usize = 1_024;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct QueuedMessage {
    pub id: String,
    pub input: Value,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub starting: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct QueueHold {
    pub message: String,
}

impl QueueHold {
    pub(crate) fn new(message: &str) -> Self {
        let end = message.floor_char_boundary(MAX_HOLD_MESSAGE_BYTES);
        Self {
            message: message[..end].to_owned(),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Queue {
    pub entries: Vec<QueuedMessage>,
    pub hold: Option<QueueHold>,
}

impl Queue {
    pub(crate) fn entry(&self, id: &str) -> Option<&QueuedMessage> {
        self.entries.iter().find(|entry| entry.id == id)
    }

    fn is_empty(&self) -> bool {
        self.entries.is_empty() && self.hold.is_none()
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Document {
    version: u32,
    thread_id: String,
    entries: Vec<QueuedMessage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    hold: Option<QueueHold>,
}

struct Occupant {
    thread: Option<String>,
    bytes: u64,
}

pub(crate) struct QueuedMessages {
    home: PathBuf,
    occupants: Mutex<HashMap<PathBuf, Occupant>>,
}

pub(crate) fn path(home: &Path, thread_id: &str) -> PathBuf {
    super::conversation_index::side_path(home, thread_id, EXTENSION)
}

impl QueuedMessages {
    pub(crate) fn open(home: PathBuf) -> Self {
        let mut occupants = HashMap::new();
        let directory = super::conversation_index::history_directory(&home);
        match std::fs::read_dir(&directory) {
            Ok(entries) => {
                for entry in entries.flatten() {
                    let file = entry.path();
                    if file.extension().and_then(|extension| extension.to_str()) != Some(EXTENSION)
                    {
                        continue;
                    }
                    let bytes = entry.metadata().map(|metadata| metadata.len()).unwrap_or(0);
                    let thread = match read_document(&file) {
                        Ok(Some(document)) => Some(document.thread_id),
                        Ok(None) => continue,
                        Err(error) => {
                            warn!(file = %file.display(), error = %format!("{error:#}"), "Claude queued messages are unreadable");
                            None
                        }
                    };
                    occupants.insert(file, Occupant { thread, bytes });
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                warn!(directory = %directory.display(), %error, "Claude queued messages could not be listed");
            }
        }
        Self {
            home,
            occupants: Mutex::new(occupants),
        }
    }

    pub(crate) fn threads(&self) -> Vec<String> {
        self.occupants
            .lock()
            .expect("queued message occupancy poisoned")
            .values()
            .filter_map(|occupant| occupant.thread.clone())
            .collect()
    }

    pub(crate) fn has(&self, thread_id: &str) -> bool {
        self.occupants
            .lock()
            .expect("queued message occupancy poisoned")
            .contains_key(&path(&self.home, thread_id))
    }

    pub(crate) fn load(&self, thread_id: &str) -> Result<Queue> {
        let file = path(&self.home, thread_id);
        Ok(read_queue(&file, thread_id)?.unwrap_or_default())
    }

    pub(crate) fn update<T>(
        &self,
        thread_id: &str,
        operation: impl FnOnce(&mut Queue) -> Result<T>,
    ) -> Result<T> {
        let file = path(&self.home, thread_id);
        let mut occupants = self
            .occupants
            .lock()
            .expect("queued message occupancy poisoned");
        private_state::transaction(
            &file,
            "Claude queued messages have no parent directory",
            |file| Ok(read_queue(file, thread_id)?.unwrap_or_default()),
            |queue| {
                let previous = queue.clone();
                let result = operation(queue)?;
                Ok((result, *queue != previous))
            },
            |file, queue| {
                if queue.is_empty() {
                    match std::fs::remove_file(file) {
                        Ok(()) => {}
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                        Err(error) => return Err(error.into()),
                    }
                    occupants.remove(file);
                    return Ok(());
                }
                let encoded = encode(thread_id, queue)?;
                let others = occupants
                    .iter()
                    .filter(|(path, _)| path.as_path() != file)
                    .collect::<Vec<_>>();
                if !occupants.contains_key(file) && others.len() >= MAX_THREADS {
                    return Err(CapacityExceeded {
                        resource: "conversations with queued messages",
                        limit: MAX_THREADS,
                    }
                    .into());
                }
                let total = others
                    .iter()
                    .map(|(_, occupant)| occupant.bytes)
                    .sum::<u64>()
                    + encoded.len() as u64;
                if total > MAX_TOTAL_BYTES {
                    return Err(CapacityExceeded {
                        resource: "queued message bytes",
                        limit: MAX_TOTAL_BYTES as usize,
                    }
                    .into());
                }
                private_state::replace(file, &encoded)?;
                occupants.insert(
                    file.to_owned(),
                    Occupant {
                        thread: Some(thread_id.to_owned()),
                        bytes: encoded.len() as u64,
                    },
                );
                Ok(())
            },
        )
    }
}

pub(crate) fn check_entry(input: &Value) -> Result<(), CapacityExceeded> {
    if !matches!(
        crate::wire::json::encoded_len_at_most(input, MAX_ENTRY_BYTES),
        Ok(Some(_))
    ) {
        return Err(CapacityExceeded {
            resource: "queued message bytes per message",
            limit: MAX_ENTRY_BYTES,
        });
    }
    Ok(())
}

fn encode(thread_id: &str, queue: &Queue) -> Result<Vec<u8>> {
    if queue.entries.len() > MAX_THREAD_ENTRIES {
        return Err(CapacityExceeded {
            resource: "queued messages per conversation",
            limit: MAX_THREAD_ENTRIES,
        }
        .into());
    }
    let encoded = serde_json::to_vec(&Document {
        version: VERSION,
        thread_id: thread_id.to_owned(),
        entries: queue.entries.clone(),
        hold: queue.hold.clone(),
    })?;
    if encoded.len() > MAX_THREAD_BYTES {
        return Err(CapacityExceeded {
            resource: "queued message bytes per conversation",
            limit: MAX_THREAD_BYTES,
        }
        .into());
    }
    Ok(encoded)
}

fn read_document(file: &Path) -> Result<Option<Document>> {
    let Some(data) = read_record(file, MAX_THREAD_BYTES as u64)? else {
        return Ok(None);
    };
    let document: Document = serde_json::from_slice(&data)
        .with_context(|| format!("invalid Claude queued messages {}", file.display()))?;
    ensure!(
        document.version == VERSION,
        "Claude queued messages {} have unsupported version {}",
        file.display(),
        document.version
    );
    Ok(Some(document))
}

fn read_queue(file: &Path, thread_id: &str) -> Result<Option<Queue>> {
    let Some(document) = read_document(file)? else {
        return Ok(None);
    };
    ensure!(
        document.thread_id == thread_id,
        "Claude queued messages {} belong to another thread",
        file.display()
    );
    Ok(Some(Queue {
        entries: document.entries,
        hold: document.hold,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn message(id: &str, text: &str) -> QueuedMessage {
        QueuedMessage {
            id: id.to_owned(),
            input: json!([{"type":"text","text":text}]),
            starting: false,
        }
    }

    fn store() -> (tempfile::TempDir, QueuedMessages) {
        let home = tempfile::TempDir::new().unwrap();
        let store = QueuedMessages::open(home.path().to_owned());
        (home, store)
    }

    #[test]
    fn transactions_persist_only_committed_changes_and_remove_emptied_queues() {
        let (home, store) = store();
        store
            .update("claude_a", |queue| {
                queue.entries.push(message("first", "one"));
                Ok(())
            })
            .unwrap();
        let failed: Result<()> = store.update("claude_a", |queue| {
            queue.entries.push(message("second", "two"));
            anyhow::bail!("refused")
        });
        assert!(failed.is_err());
        let reopened = QueuedMessages::open(home.path().to_owned());
        assert_eq!(reopened.threads(), vec!["claude_a".to_owned()]);
        assert_eq!(
            reopened.load("claude_a").unwrap().entries,
            vec![message("first", "one")]
        );

        reopened
            .update("claude_a", |queue| {
                queue.entries.clear();
                Ok(())
            })
            .unwrap();
        assert!(!reopened.has("claude_a"));
        assert!(!path(home.path(), "claude_a").exists());
        assert!(
            QueuedMessages::open(home.path().to_owned())
                .threads()
                .is_empty()
        );
    }

    #[test]
    fn a_hold_alone_keeps_the_queue_file() {
        let (_home, store) = store();
        store
            .update("claude_a", |queue| {
                queue.hold = Some(QueueHold::new(&"x".repeat(4_096)));
                Ok(())
            })
            .unwrap();
        let hold = store.load("claude_a").unwrap().hold.unwrap();
        assert_eq!(hold.message.len(), MAX_HOLD_MESSAGE_BYTES);
        assert!(store.has("claude_a"));
    }

    #[test]
    fn caps_refuse_growth_with_typed_capacity_and_keep_the_previous_queue() {
        let (_home, store) = store();
        let refused = |error: anyhow::Error| error.downcast::<CapacityExceeded>().unwrap().resource;

        store
            .update("claude_a", |queue| {
                queue.entries = (0..MAX_THREAD_ENTRIES)
                    .map(|index| message(&format!("m{index}"), "x"))
                    .collect();
                Ok(())
            })
            .unwrap();
        let error = store
            .update("claude_a", |queue| {
                queue.entries.push(message("overflow", "x"));
                Ok(())
            })
            .unwrap_err();
        assert_eq!(refused(error), "queued messages per conversation");
        assert_eq!(
            store.load("claude_a").unwrap().entries.len(),
            MAX_THREAD_ENTRIES
        );

        let large = "y".repeat(MAX_ENTRY_BYTES - 64);
        let error = store
            .update("claude_b", |queue| {
                queue.entries = (0..9)
                    .map(|index| message(&format!("b{index}"), &large))
                    .collect();
                Ok(())
            })
            .unwrap_err();
        assert_eq!(refused(error), "queued message bytes per conversation");
        assert!(!store.has("claude_b"));

        for thread in 0..5 {
            store
                .update(&format!("claude_t{thread}"), |queue| {
                    queue.entries = (0..6)
                        .map(|index| message(&format!("t{index}"), &large))
                        .collect();
                    Ok(())
                })
                .unwrap();
        }
        let error = store
            .update("claude_c", |queue| {
                queue.entries = (0..3)
                    .map(|index| message(&format!("c{index}"), &large))
                    .collect();
                Ok(())
            })
            .unwrap_err();
        assert_eq!(refused(error), "queued message bytes");
        assert!(!store.has("claude_c"));
    }

    #[test]
    fn the_thread_cap_counts_conversations_holding_a_queue() {
        let (_home, store) = store();
        for thread in 0..MAX_THREADS {
            store
                .update(&format!("claude_{thread}"), |queue| {
                    queue.entries.push(message("m", "x"));
                    Ok(())
                })
                .unwrap();
        }
        let error = store
            .update("claude_extra", |queue| {
                queue.entries.push(message("m", "x"));
                Ok(())
            })
            .unwrap_err();
        assert_eq!(
            error.downcast::<CapacityExceeded>().unwrap().resource,
            "conversations with queued messages"
        );
        store
            .update("claude_0", |queue| {
                queue.entries.push(message("n", "x"));
                Ok(())
            })
            .unwrap();
    }

    #[test]
    fn an_oversized_message_is_refused_before_it_reaches_the_store() {
        assert!(check_entry(&json!([{"type":"text","text":"small"}])).is_ok());
        let error =
            check_entry(&json!([{"type":"text","text":"z".repeat(MAX_ENTRY_BYTES)}])).unwrap_err();
        assert_eq!(error.limit, MAX_ENTRY_BYTES);
    }

    #[test]
    fn unknown_fields_and_versions_fail_visibly_and_are_never_overwritten() {
        let (home, store) = store();
        let file = path(home.path(), "claude_a");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        let foreign = json!({"version":2,"threadId":"claude_a","entries":[]}).to_string();
        std::fs::write(&file, &foreign).unwrap();
        assert!(store.load("claude_a").is_err());
        assert!(
            store
                .update("claude_a", |queue| {
                    queue.entries.push(message("m", "x"));
                    Ok(())
                })
                .is_err()
        );
        assert_eq!(std::fs::read_to_string(&file).unwrap(), foreign);

        std::fs::write(
            &file,
            json!({"version":1,"threadId":"claude_a","entries":[],"extra":true}).to_string(),
        )
        .unwrap();
        assert!(store.load("claude_a").is_err());
        let reopened = QueuedMessages::open(home.path().to_owned());
        assert!(reopened.threads().is_empty());
        assert!(reopened.has("claude_a"));
    }
}
