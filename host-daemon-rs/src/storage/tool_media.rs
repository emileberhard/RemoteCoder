use std::path::PathBuf;
use std::sync::Arc;
use std::time::SystemTime;

use anyhow::Result;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use tokio::sync::Semaphore;

use super::content_store::{Limits, inventory, retain};
use super::no_follow::Root;

const LIMITS: Limits = Limits {
    bytes: 512 * 1024 * 1024,
    entries: 4096,
};
const MAX_MEDIA_BYTES: usize = 32 * 1024 * 1024;
const TYPES: [(&str, &str); 5] = [
    ("image/png", "png"),
    ("image/jpeg", "jpg"),
    ("image/gif", "gif"),
    ("image/webp", "webp"),
    ("application/pdf", "pdf"),
];

pub(crate) fn media_type_for_path(path: &str) -> Option<&'static str> {
    let (_, extension) = path.rsplit_once('.')?;
    TYPES
        .iter()
        .find(|(_, known)| *known == extension)
        .map(|(mime_type, _)| *mime_type)
}

#[derive(Clone, Debug)]
pub(crate) struct ToolMediaStore {
    state_directory: PathBuf,
    admission: Arc<Semaphore>,
}

#[derive(Default)]
pub(crate) struct MediaBatch {
    staged: Vec<Staged>,
}

struct Staged {
    path: PathBuf,
    bytes: Vec<u8>,
}

impl ToolMediaStore {
    pub(crate) fn new(state_directory: PathBuf) -> Self {
        Self {
            state_directory,
            admission: Arc::new(Semaphore::new(1)),
        }
    }

    fn directory(&self) -> PathBuf {
        self.state_directory.join("tool-media")
    }

    pub(crate) fn stage(
        &self,
        batch: &mut MediaBatch,
        mime_type: &str,
        base64: &str,
    ) -> Option<PathBuf> {
        let (_, extension) = TYPES.iter().find(|(known, _)| *known == mime_type)?;
        if base64.len() > MAX_MEDIA_BYTES.div_ceil(3) * 4 {
            return None;
        }
        let bytes = STANDARD.decode(base64).ok()?;
        let path = self
            .directory()
            .join(format!("{}.{extension}", crate::ids::sha256_hex(&bytes)));
        if !batch.staged.iter().any(|staged| staged.path == path) {
            batch.staged.push(Staged {
                path: path.clone(),
                bytes,
            });
        }
        Some(path)
    }

    pub(crate) async fn admit(&self, batch: MediaBatch) -> Result<()> {
        if batch.staged.is_empty() {
            return Ok(());
        }
        let permit = Arc::clone(&self.admission).acquire_owned().await?;
        let store = self.clone();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            store.write(batch)
        })
        .await?
    }

    fn write(&self, batch: MediaBatch) -> Result<()> {
        let root = Root::open(&self.state_directory)?;
        let directory = self.directory();
        root.ensure_directory(&directory)?;
        let _lock = root.lock_file(&directory.join("store.lock"))?;
        let mut missing = Vec::new();
        for staged in &batch.staged {
            match root.open_file(&staged.path)? {
                Some(file) if file.metadata()?.len() == staged.bytes.len() as u64 => {
                    file.set_modified(SystemTime::now())?;
                }
                _ => missing.push(staged),
            }
        }
        if missing.is_empty() {
            return Ok(());
        }
        let extensions = TYPES.map(|(_, extension)| extension);
        let entries = inventory(&root, &directory, &LIMITS, &extensions)?;
        let protected: Vec<_> = batch
            .staged
            .iter()
            .map(|staged| staged.path.clone())
            .collect();
        let incoming = missing.iter().map(|staged| staged.bytes.len() as u64).sum();
        retain(&root, entries, &protected, incoming, missing.len(), &LIMITS)?;
        for staged in missing {
            root.write_read_only(&staged.path, &staged.bytes)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::time::Duration;

    #[test]
    fn admitted_media_is_content_addressed_read_only_and_reused() {
        let home = tempfile::tempdir().unwrap();
        let store = ToolMediaStore::new(home.path().to_path_buf());
        let mut batch = MediaBatch::default();
        let path = store.stage(&mut batch, "image/png", "YWJj").unwrap();
        assert_eq!(
            store.stage(&mut batch, "image/png", "YWJj"),
            Some(path.clone())
        );
        assert_eq!(batch.staged.len(), 1);
        assert!(!path.exists(), "staging must not write before admission");
        store.write(batch).unwrap();
        assert_eq!(
            path,
            home.path().join(
                "tool-media/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.png"
            )
        );
        assert_eq!(std::fs::read(&path).unwrap(), b"abc");
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o400
        );

        let old = SystemTime::UNIX_EPOCH + Duration::from_secs(1);
        std::fs::File::open(&path)
            .unwrap()
            .set_modified(old)
            .unwrap();
        let mut again = MediaBatch::default();
        store.stage(&mut again, "image/png", "YWJj").unwrap();
        store.write(again).unwrap();
        assert!(std::fs::metadata(&path).unwrap().modified().unwrap() > old);
    }

    #[test]
    fn unsupported_undecodable_and_oversized_media_is_not_staged() {
        let store = ToolMediaStore::new(PathBuf::from("/nonexistent"));
        let mut batch = MediaBatch::default();
        assert_eq!(store.stage(&mut batch, "image/svg+xml", "YWJj"), None);
        assert_eq!(store.stage(&mut batch, "audio/wav", "YWJj"), None);
        assert_eq!(store.stage(&mut batch, "image/png", "not base64!"), None);
        let oversized = "A".repeat(MAX_MEDIA_BYTES.div_ceil(3) * 4 + 4);
        assert_eq!(store.stage(&mut batch, "application/pdf", &oversized), None);
        assert!(batch.staged.is_empty());
    }

    #[test]
    fn retention_evicts_the_oldest_media_but_never_the_batch() {
        let home = tempfile::tempdir().unwrap();
        let store = ToolMediaStore::new(home.path().to_path_buf());
        let mut first = MediaBatch::default();
        let old = store.stage(&mut first, "image/png", "YWJj").unwrap();
        let kept = store.stage(&mut first, "image/jpeg", "ZGVm").unwrap();
        store.write(first).unwrap();
        let filler = store.directory().join(format!("{}.pdf", "f".repeat(64)));
        std::fs::File::create(&filler)
            .unwrap()
            .set_len(LIMITS.bytes - 6)
            .unwrap();
        for (path, seconds) in [(&kept, 1), (&old, 2), (&filler, 3)] {
            std::fs::File::open(path)
                .unwrap()
                .set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(seconds))
                .unwrap();
        }

        let mut next = MediaBatch::default();
        store.stage(&mut next, "image/jpeg", "ZGVm").unwrap();
        let new = store.stage(&mut next, "image/gif", "Z2hp").unwrap();
        store.write(next).unwrap();
        assert!(!old.exists());
        assert!(kept.exists() && filler.exists() && new.exists());
    }
}
