use std::path::Path;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use crate::storage::private_document::{PrivateDocument, PrivateDocumentStore};

const SCHEMA_VERSION: u32 = 1;
const FILE_NAME: &str = "directory-favorites.json";
const MAXIMUM_STORE_BYTES: u64 = 256 * 1024;
const MAXIMUM_PATH_BYTES: usize = 1024;
const MAXIMUM_FAVORITES: usize = 100;
const MAXIMUM_CHANGES_PER_UPDATE: usize = 100;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Favorites {
    pub revision: u64,
    pub paths: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(tag = "op", rename_all = "camelCase")]
pub(crate) enum Change {
    Add { path: String },
    Remove { path: String },
}

impl Change {
    fn path(&self) -> &str {
        match self {
            Self::Add { path } | Self::Remove { path } => path,
        }
    }
}

pub(crate) struct Applied {
    pub favorites: Favorites,
    pub changed: bool,
}

pub(crate) fn validate(changes: &[Change]) -> Result<()> {
    ensure!(
        !changes.is_empty() && changes.len() <= MAXIMUM_CHANGES_PER_UPDATE,
        "an update carries 1 to {MAXIMUM_CHANGES_PER_UPDATE} changes"
    );
    for change in changes {
        validate_path(change.path())?;
    }
    Ok(())
}

fn validate_path(path: &str) -> Result<()> {
    ensure!(
        path.starts_with('/')
            && path.len() <= MAXIMUM_PATH_BYTES
            && !path.chars().any(char::is_control),
        "a favorite path must be absolute, at most {MAXIMUM_PATH_BYTES} bytes and free of control characters"
    );
    Ok(())
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Document {
    schema_version: u32,
    revision: u64,
    paths: Vec<String>,
}

impl PrivateDocument for Document {
    const NAME: &'static str = "directory favorites";
    const MAXIMUM_BYTES: u64 = MAXIMUM_STORE_BYTES;

    fn empty() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            revision: 0,
            paths: Vec::new(),
        }
    }

    fn validate(&self) -> Result<()> {
        ensure!(
            self.schema_version == SCHEMA_VERSION,
            "unsupported directory favorites version"
        );
        ensure!(
            self.paths.len() <= MAXIMUM_FAVORITES,
            "directory favorites exceed {MAXIMUM_FAVORITES} entries"
        );
        for (index, path) in self.paths.iter().enumerate() {
            validate_path(path)?;
            ensure!(
                !self.paths[..index].contains(path),
                "duplicate directory favorite"
            );
        }
        Ok(())
    }
}

impl Document {
    fn snapshot(&self) -> Favorites {
        Favorites {
            revision: self.revision,
            paths: self.paths.clone(),
        }
    }

    fn apply(&mut self, changes: Vec<Change>) -> Result<bool> {
        let mut paths = self.paths.clone();
        for change in changes {
            match change {
                Change::Add { path }
                    if !paths.contains(&path) && paths.len() < MAXIMUM_FAVORITES =>
                {
                    paths.insert(0, path)
                }
                Change::Add { .. } => {}
                Change::Remove { path } => paths.retain(|existing| *existing != path),
            }
        }
        if paths == self.paths {
            return Ok(false);
        }
        self.revision = self
            .revision
            .checked_add(1)
            .context("directory favorites revision exhausted")?;
        self.paths = paths;
        Ok(true)
    }
}

#[derive(Clone)]
pub(crate) struct DirectoryFavoritesStore {
    document: PrivateDocumentStore<Document>,
}

impl DirectoryFavoritesStore {
    pub(crate) fn new(directory: &Path) -> Self {
        Self {
            document: PrivateDocumentStore::new(directory.join(FILE_NAME)),
        }
    }

    pub(crate) async fn read(&self) -> Result<Favorites> {
        self.document
            .transaction(|document| Ok((document.snapshot(), false)))
            .await
    }

    pub(crate) async fn update(&self, changes: Vec<Change>) -> Result<Applied> {
        self.document
            .transaction(move |document| {
                let changed = document.apply(changes)?;
                let favorites = document.snapshot();
                Ok((Applied { favorites, changed }, changed))
            })
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn add(path: &str) -> Change {
        Change::Add { path: path.into() }
    }

    fn remove(path: &str) -> Change {
        Change::Remove { path: path.into() }
    }

    #[test]
    fn changes_decode_from_their_wire_names() {
        let changes: Vec<Change> = serde_json::from_value(serde_json::json!([
            {"op": "add", "path": "/a"},
            {"op": "remove", "path": "/b"},
        ]))
        .unwrap();
        assert_eq!(changes, vec![add("/a"), remove("/b")]);
    }

    #[test]
    fn only_absolute_bounded_printable_paths_are_accepted() {
        assert!(
            validate(&[
                add("/Users/developer/RemoteCoder"),
                add("/Users/developer/ends with space ")
            ])
            .is_ok()
        );
        assert!(validate(&[add("~/RemoteCoder")]).is_err());
        assert!(validate(&[add("/a\nb")]).is_err());
        assert!(validate(&[add(&format!("/{}", "a".repeat(MAXIMUM_PATH_BYTES)))]).is_err());
        assert!(validate(&[]).is_err());
    }

    #[tokio::test]
    async fn an_absent_document_reads_empty_without_being_created() {
        let directory = tempfile::tempdir().unwrap();
        let store = DirectoryFavoritesStore::new(directory.path());
        let favorites = store.read().await.unwrap();
        assert_eq!((favorites.revision, favorites.paths.len()), (0, 0));
        assert!(!directory.path().join(FILE_NAME).exists());
    }

    #[tokio::test]
    async fn adds_go_first_and_only_real_changes_advance_the_revision() {
        let directory = tempfile::tempdir().unwrap();
        let store = DirectoryFavoritesStore::new(directory.path());
        let added = store.update(vec![add("/a"), add("/b")]).await.unwrap();
        assert!(added.changed);
        assert_eq!(
            added.favorites,
            Favorites {
                revision: 1,
                paths: vec!["/b".into(), "/a".into()]
            }
        );
        let unchanged = store.update(vec![add("/a"), remove("/c")]).await.unwrap();
        assert!(!unchanged.changed);
        assert_eq!(unchanged.favorites, added.favorites);
        let removed = store.update(vec![remove("/b")]).await.unwrap();
        assert_eq!(
            removed.favorites,
            Favorites {
                revision: 2,
                paths: vec!["/a".into()]
            }
        );
        let reopened = DirectoryFavoritesStore::new(directory.path());
        assert_eq!(reopened.read().await.unwrap(), removed.favorites);
    }

    #[tokio::test]
    async fn adds_past_the_limit_are_skipped_while_the_rest_applies() {
        let directory = tempfile::tempdir().unwrap();
        let store = DirectoryFavoritesStore::new(directory.path());
        let full: Vec<Change> = (0..MAXIMUM_FAVORITES)
            .map(|index| add(&format!("/{index}")))
            .collect();
        store.update(full).await.unwrap();
        let applied = store
            .update(vec![remove("/0"), add("/kept"), add("/skipped")])
            .await
            .unwrap();
        assert!(applied.changed);
        assert_eq!(applied.favorites.paths.len(), MAXIMUM_FAVORITES);
        assert_eq!(applied.favorites.paths[0], "/kept");
        assert!(!applied.favorites.paths.contains(&"/skipped".to_string()));
    }

    #[tokio::test]
    async fn an_unreadable_document_is_reported_and_preserved() {
        const INVALID: &[u8] = b"{\"schemaVersion\":1,\"revision\":1,\"paths\":[\"relative\"]}";
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join(FILE_NAME);
        std::fs::write(&path, INVALID).unwrap();
        let store = DirectoryFavoritesStore::new(directory.path());
        assert!(store.read().await.is_err());
        assert!(store.update(vec![add("/a")]).await.is_err());
        assert_eq!(std::fs::read(&path).unwrap(), INVALID);
    }
}
