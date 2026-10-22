use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::storage::private_document::{PrivateDocument, PrivateDocumentStore};

const SCHEMA_VERSION: u32 = 1;
const FILE_NAME: &str = "user-preferences.json";
const MAXIMUM_STORE_BYTES: u64 = 1024 * 1024;
const MAXIMUM_ENTRIES: usize = 64;
const MAXIMUM_KEY_BYTES: usize = 128;
const MAXIMUM_DEVICE_BYTES: usize = 64;
const MAXIMUM_VALUE_BYTES: usize = 8 * 1024;
const MAXIMUM_UPDATED_AT: u64 = (1 << 53) - 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Entry {
    pub value: Value,
    pub updated_at: u64,
    pub device: String,
}

impl Entry {
    fn supersedes(&self, other: &Entry) -> bool {
        (self.updated_at, &self.device) > (other.updated_at, &other.device)
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub(crate) struct Preferences {
    pub entries: BTreeMap<String, Entry>,
}

pub(crate) struct Applied {
    pub preferences: Preferences,
    pub changed: bool,
}

pub(crate) fn validate(entries: &BTreeMap<String, Entry>) -> Result<()> {
    ensure!(
        !entries.is_empty() && entries.len() <= MAXIMUM_ENTRIES,
        "an update carries 1 to {MAXIMUM_ENTRIES} entries"
    );
    entries
        .iter()
        .try_for_each(|(key, entry)| validate_entry(key, entry))
}

fn validate_entry(key: &str, entry: &Entry) -> Result<()> {
    ensure!(
        is_bounded_label(key, MAXIMUM_KEY_BYTES),
        "a preference key is 1 to {MAXIMUM_KEY_BYTES} bytes without control characters"
    );
    ensure!(
        is_bounded_label(&entry.device, MAXIMUM_DEVICE_BYTES),
        "a preference device is 1 to {MAXIMUM_DEVICE_BYTES} bytes without control characters"
    );
    ensure!(
        (1..=MAXIMUM_UPDATED_AT).contains(&entry.updated_at),
        "a preference version is 1 to {MAXIMUM_UPDATED_AT}"
    );
    ensure!(
        serde_json::to_vec(&entry.value)?.len() <= MAXIMUM_VALUE_BYTES,
        "a preference value is at most {MAXIMUM_VALUE_BYTES} bytes of JSON"
    );
    Ok(())
}

fn is_bounded_label(label: &str, maximum_bytes: usize) -> bool {
    !label.is_empty() && label.len() <= maximum_bytes && !label.chars().any(char::is_control)
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Document {
    schema_version: u32,
    entries: BTreeMap<String, Entry>,
}

impl PrivateDocument for Document {
    const NAME: &'static str = "user preferences";
    const MAXIMUM_BYTES: u64 = MAXIMUM_STORE_BYTES;

    fn empty() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            entries: BTreeMap::new(),
        }
    }

    fn validate(&self) -> Result<()> {
        ensure!(
            self.schema_version == SCHEMA_VERSION,
            "unsupported user preferences version"
        );
        ensure!(
            self.entries.len() <= MAXIMUM_ENTRIES,
            "user preferences exceed {MAXIMUM_ENTRIES} entries"
        );
        self.entries
            .iter()
            .try_for_each(|(key, entry)| validate_entry(key, entry))
    }
}

impl Document {
    fn snapshot(&self) -> Preferences {
        Preferences {
            entries: self.entries.clone(),
        }
    }

    fn merge(&mut self, entries: BTreeMap<String, Entry>) -> bool {
        let mut changed = false;
        for (key, entry) in entries {
            match self.entries.get(&key) {
                Some(existing) if !entry.supersedes(existing) => {}
                None if self.entries.len() >= MAXIMUM_ENTRIES => {
                    tracing::warn!(%key, "user preferences are full; skipped a new key");
                }
                _ => {
                    self.entries.insert(key, entry);
                    changed = true;
                }
            }
        }
        changed
    }
}

#[derive(Clone)]
pub(crate) struct UserPreferencesStore {
    document: PrivateDocumentStore<Document>,
}

impl UserPreferencesStore {
    pub(crate) fn new(directory: &Path) -> Self {
        Self {
            document: PrivateDocumentStore::new(directory.join(FILE_NAME)),
        }
    }

    pub(crate) async fn read(&self) -> Result<Preferences> {
        self.document
            .transaction(|document| Ok((document.snapshot(), false)))
            .await
    }

    pub(crate) async fn update(&self, entries: BTreeMap<String, Entry>) -> Result<Applied> {
        self.document
            .transaction(move |document| {
                let changed = document.merge(entries);
                let preferences = document.snapshot();
                Ok((
                    Applied {
                        preferences,
                        changed,
                    },
                    changed,
                ))
            })
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn entry(value: Value, updated_at: u64, device: &str) -> Entry {
        Entry {
            value,
            updated_at,
            device: device.into(),
        }
    }

    fn entries(pairs: &[(&str, Entry)]) -> BTreeMap<String, Entry> {
        pairs
            .iter()
            .map(|(key, entry)| ((*key).to_string(), entry.clone()))
            .collect()
    }

    #[test]
    fn entries_use_their_wire_names_and_reject_unknown_fields() {
        let decoded: Entry =
            serde_json::from_value(json!({"value": {"a": "b"}, "updatedAt": 7, "device": "phone"}))
                .unwrap();
        assert_eq!(decoded, entry(json!({"a": "b"}), 7, "phone"));
        assert!(
            serde_json::from_value::<Entry>(
                json!({"value": 1, "updatedAt": 7, "device": "phone", "extra": true})
            )
            .is_err()
        );
    }

    #[test]
    fn only_bounded_printable_keys_devices_and_values_are_accepted() {
        let valid = entry(json!("gpt"), 1, "phone");
        assert!(validate(&entries(&[("codex.defaultModelID", valid.clone())])).is_ok());
        assert!(validate(&entries(&[("", valid.clone())])).is_err());
        assert!(validate(&entries(&[("a\nb", valid.clone())])).is_err());
        let long_key = "k".repeat(MAXIMUM_KEY_BYTES + 1);
        assert!(validate(&entries(&[(long_key.as_str(), valid.clone())])).is_err());
        assert!(validate(&entries(&[("key", entry(json!(1), 1, ""))])).is_err());
        assert!(validate(&entries(&[("key", entry(json!(1), 0, "phone"))])).is_err());
        let too_new = entry(json!(1), MAXIMUM_UPDATED_AT + 1, "phone");
        assert!(validate(&entries(&[("key", too_new)])).is_err());
        let large = json!("v".repeat(MAXIMUM_VALUE_BYTES));
        assert!(validate(&entries(&[("key", entry(large, 1, "phone"))])).is_err());
        assert!(validate(&BTreeMap::new()).is_err());
    }

    #[tokio::test]
    async fn an_absent_document_reads_empty_without_being_created() {
        let directory = tempfile::tempdir().unwrap();
        let store = UserPreferencesStore::new(directory.path());
        assert!(store.read().await.unwrap().entries.is_empty());
        assert!(!directory.path().join(FILE_NAME).exists());
    }

    #[tokio::test]
    async fn the_latest_change_to_each_key_wins_regardless_of_arrival_order() {
        let directory = tempfile::tempdir().unwrap();
        let store = UserPreferencesStore::new(directory.path());
        let newer = entry(json!("+opus"), 20, "mac");
        let applied = store
            .update(entries(&[
                ("claude.modelVisibility", newer.clone()),
                ("ttsAutoSpeakEnabled", entry(json!(true), 5, "phone")),
            ]))
            .await
            .unwrap();
        assert!(applied.changed);

        let stale = store
            .update(entries(&[(
                "claude.modelVisibility",
                entry(json!("-opus"), 10, "phone"),
            )]))
            .await
            .unwrap();
        assert!(!stale.changed);
        assert_eq!(stale.preferences.entries["claude.modelVisibility"], newer);

        let reset = entry(Value::Null, 20, "phone");
        let tie = store
            .update(entries(&[("claude.modelVisibility", reset.clone())]))
            .await
            .unwrap();
        assert!(tie.changed);
        assert_eq!(tie.preferences.entries["claude.modelVisibility"], reset);

        let reopened = UserPreferencesStore::new(directory.path());
        assert_eq!(reopened.read().await.unwrap(), tie.preferences);
    }

    #[tokio::test]
    async fn new_keys_past_the_limit_are_skipped_while_known_keys_still_update() {
        let directory = tempfile::tempdir().unwrap();
        let store = UserPreferencesStore::new(directory.path());
        let full: BTreeMap<String, Entry> = (0..MAXIMUM_ENTRIES)
            .map(|index| (format!("key{index}"), entry(json!(index), 1, "phone")))
            .collect();
        store.update(full).await.unwrap();
        let applied = store
            .update(entries(&[
                ("key0", entry(json!("updated"), 2, "phone")),
                ("skipped", entry(json!(true), 2, "phone")),
            ]))
            .await
            .unwrap();
        assert!(applied.changed);
        assert_eq!(applied.preferences.entries.len(), MAXIMUM_ENTRIES);
        assert_eq!(applied.preferences.entries["key0"].value, json!("updated"));
        assert!(!applied.preferences.entries.contains_key("skipped"));
    }
}
