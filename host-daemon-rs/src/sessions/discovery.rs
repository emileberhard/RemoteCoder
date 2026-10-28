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
        let mut first_error = None;
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
            match std::fs::symlink_metadata(&path) {
                Ok(metadata) if metadata.is_file() => {}
                Ok(_) => {
                    self.pending.remove(&path);
                    continue;
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    self.pending.remove(&path);
                    continue;
                }
                Err(error) => return Err(error.into()),
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
                }
                Err(error) => {
                    if first_error.is_none() {
                        first_error = Some(error);
                    }
                }
            }
        }
        if let Some(error) = first_error {
            return Err(error);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
