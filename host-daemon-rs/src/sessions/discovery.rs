use super::{Origin, ingest};
use crate::storage::file_revision::FileRevision;
use anyhow::{Result, ensure};
use rusqlite::{Connection, params};
use std::collections::{BTreeMap, BTreeSet};
use std::ops::Bound::{Excluded, Included, Unbounded};
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::time::Instant;

const CAPACITY: usize = 100_000;

#[derive(Default)]
pub(super) struct Discovery {
    directories: BTreeMap<PathBuf, Option<FileRevision>>,
    pending: BTreeSet<PathBuf>,
    rejected: BTreeMap<PathBuf, FileRevision>,
}

impl Discovery {
    pub fn reconcile(&mut self) {
        self.directories.clear();
        self.pending.clear();
    }

    pub fn refresh(&mut self, origins: &[Origin], deadline: Option<Instant>) -> Result<()> {
        for origin in origins {
            let root = origin.path();
            ensure!(
                self.directories.len() < CAPACITY || self.directories.contains_key(&root),
                "capacity: too many session directories"
            );
            self.directories.entry(root).or_default();
        }
        let mut todo: Vec<_> = self
            .directories
            .iter()
            .map(|(path, revision)| (path.clone(), revision.clone()))
            .collect();
        while let Some((path, previous)) = todo.pop() {
            ensure!(
                deadline.is_none_or(|deadline| Instant::now() < deadline),
                "unavailable: inventory discovery exceeded five seconds"
            );
            let metadata = match std::fs::symlink_metadata(&path) {
                Ok(metadata) if metadata.is_dir() => metadata,
                Ok(_) => {
                    self.forget(&path);
                    continue;
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    self.forget(&path);
                    continue;
                }
                Err(error) => return Err(error.into()),
            };
            let revision = FileRevision::from(metadata);
            if previous.as_ref() == Some(&revision) {
                continue;
            }
            for entry in std::fs::read_dir(&path)? {
                ensure!(
                    deadline.is_none_or(|deadline| Instant::now() < deadline),
                    "unavailable: inventory discovery exceeded five seconds"
                );
                let entry = entry?;
                let kind = entry.file_type()?;
                let child = entry.path();
                if kind.is_dir() && !self.directories.contains_key(&child) {
                    ensure!(
                        self.directories.len() < CAPACITY,
                        "capacity: too many session directories"
                    );
                    self.directories.insert(child.clone(), None);
                    todo.push((child, None));
                } else if kind.is_file()
                    && origins.iter().any(|origin| origin.is_transcript(&child))
                {
                    ensure!(
                        self.pending.len() < CAPACITY,
                        "capacity: too many undiscovered session headers"
                    );
                    self.pending.insert(child);
                }
            }
            self.directories.insert(path, Some(revision));
        }
        Ok(())
    }

    #[cfg(test)]
    pub fn directory_count(&self, origin: &Origin) -> usize {
        self.directories
            .range(origin.path()..)
            .take_while(|(path, _)| path.starts_with(origin.path()))
            .count()
    }

    fn forget(&mut self, path: &PathBuf) {
        let end = self
            .directories
            .range(path.clone()..)
            .find(|(p, _)| !p.starts_with(path))
            .map(|(p, _)| p.clone());
        self.directories
            .extract_if(
                (Included(path.clone()), end.map_or(Unbounded, Excluded)),
                |_, _| true,
            )
            .for_each(drop);
        let end = self
            .pending
            .range(path.clone()..)
            .find(|p| !p.starts_with(path))
            .cloned();
        self.rejected.retain(|p, _| !p.starts_with(path));
        self.pending
            .extract_if(
                (Included(path.clone()), end.map_or(Unbounded, Excluded)),
                |_| true,
            )
            .for_each(drop);
    }

    pub fn headers(
        &mut self,
        db: &mut Connection,
        origins: &[Origin],
        stop: &AtomicBool,
        deadline: Option<Instant>,
    ) -> Result<()> {
        let paths: Vec<_> = self.pending.iter().cloned().collect();
        for path in paths {
            ensure!(
                !stop.load(std::sync::atomic::Ordering::Acquire),
                "Session ingestion stopped"
            );
            ensure!(
                deadline.is_none_or(|deadline| Instant::now() < deadline),
                "unavailable: inventory catch-up exceeded five seconds"
            );
            let revision = match std::fs::symlink_metadata(&path) {
                Ok(metadata) if metadata.is_file() => FileRevision::from(metadata),
                Ok(_) => {
                    self.pending.remove(&path);
                    continue;
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    self.pending.remove(&path);
                    continue;
                }
                Err(error) => return Err(error.into()),
            };
            if self.rejected.get(&path) == Some(&revision) {
                self.pending.remove(&path);
                continue;
            }
            let Some(origin) = origins
                .iter()
                .find(|origin| path.starts_with(origin.path()))
            else {
                continue;
            };
            let original = origin.original(&path)?.to_string_lossy().into_owned();
            let present: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM source JOIN session USING(source_id) WHERE source.origin_host=?1 AND source.path=?2)",params![origin.host,original],|r|r.get(0))?;
            let outcome = if present {
                Ok(())
            } else {
                ingest::header(db, origin, &path, stop)
            };
            match outcome {
                Ok(()) => {
                    self.pending.remove(&path);
                    self.rejected.remove(&path);
                }
                Err(error) => {
                    if !error.is::<ingest::InvalidHeader>() {
                        return Err(error);
                    }
                    ensure!(
                        self.rejected.len() < CAPACITY || self.rejected.contains_key(&path),
                        "capacity: too many rejected session headers"
                    );
                    ingest::record_failure(db, origin, &path, &error)?;
                    tracing::warn!(path=%path.display(), %error, "Session header skipped");
                    self.rejected.insert(path.clone(), revision);
                    self.pending.remove(&path);
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sessions_discovery_classifies_invalid_header_evidence() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let origin = Origin {
            host: "fixture".into(),
            provider: "codex".into(),
            provider_home: directory.path().into(),
            local_home: directory.path().into(),
        };
        let path = origin.path().join("invalid.jsonl");
        std::fs::create_dir_all(path.parent().unwrap())?;
        let mut db = Connection::open_in_memory()?;
        db.execute_batch(include_str!("schema.sql"))?;
        for body in [
            String::new(),
            "{\"type\":\"session_meta\",\"payload\":{\"id\":null}}\n".into(),
            "{\"type\":\"session_meta\",\"timestamp\":\"invalid\",\"payload\":{\"id\":\"valid\"}}\n".into(),
            "{\"type\":\"event_msg\"}\n".repeat(128),
        ] {
            std::fs::write(&path, body)?;
            let error = ingest::header(&mut db, &origin, &path, &AtomicBool::new(false)).unwrap_err();
            assert!(error.is::<ingest::InvalidHeader>(), "{error:#}");
        }
        Ok(())
    }

    #[test]
    fn sessions_discovery_retries_unreadable_headers_without_a_file_change() -> Result<()> {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir()?;
        let origin = Origin {
            host: "fixture".into(),
            provider: "codex".into(),
            provider_home: directory.path().into(),
            local_home: directory.path().into(),
        };
        let path = origin.path().join("valid.jsonl");
        std::fs::create_dir_all(path.parent().unwrap())?;
        std::fs::write(
            &path,
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"valid\"}}\n",
        )?;
        let mut db = Connection::open_in_memory()?;
        db.execute_batch(include_str!("schema.sql"))?;
        let mut discovery = Discovery::default();
        discovery.refresh(std::slice::from_ref(&origin), None)?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o000))?;
        let stop = AtomicBool::new(false);
        let error = discovery
            .headers(&mut db, std::slice::from_ref(&origin), &stop, None)
            .unwrap_err();
        assert_eq!(
            error.downcast_ref::<std::io::Error>().unwrap().kind(),
            std::io::ErrorKind::PermissionDenied
        );
        assert!(discovery.rejected.is_empty());
        assert!(discovery.pending.contains(&path));
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        discovery.headers(&mut db, &[origin], &stop, None)?;
        assert!(discovery.pending.is_empty());
        assert_eq!(
            db.query_row("SELECT thread_id FROM session", [], |row| row
                .get::<_, String>(0))?,
            "valid"
        );
        Ok(())
    }

    #[test]
    fn sessions_discovery_recurses_new_dates_and_forgets_removed_directories() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let origin = Origin {
            host: "fixture".into(),
            provider: "codex".into(),
            provider_home: directory.path().into(),
            local_home: directory.path().into(),
        };
        std::fs::create_dir_all(origin.path())?;
        let mut discovery = Discovery::default();
        discovery.refresh(std::slice::from_ref(&origin), None)?;
        let nested = origin.path().join("2026/10/28");
        std::fs::create_dir_all(&nested)?;
        let first = nested.join("first.jsonl");
        std::fs::write(&first, "{}\n")?;
        discovery.refresh(std::slice::from_ref(&origin), None)?;
        assert!(discovery.pending.contains(&first));
        std::fs::remove_dir_all(origin.path().join("2026"))?;
        discovery.refresh(std::slice::from_ref(&origin), None)?;
        assert_eq!(discovery.directories.len(), 1);
        assert!(discovery.pending.is_empty());
        std::fs::create_dir_all(&nested)?;
        let second = nested.join("second.jsonl");
        std::fs::write(&second, "{}\n")?;
        discovery.refresh(std::slice::from_ref(&origin), None)?;
        assert_eq!(discovery.pending, BTreeSet::from([second]));
        Ok(())
    }
}
