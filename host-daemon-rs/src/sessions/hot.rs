use super::Origin;
use crate::storage::file_revision::FileRevision;
use anyhow::Result;
use rusqlite::{Connection, params};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::time::{Duration, Instant};

const CAPACITY: usize = 64;
const LIFETIME: Duration = Duration::from_secs(600);

struct Entry {
    revision: String,
    expires: Instant,
}

#[derive(Default)]
pub(super) struct Hot {
    entries: BTreeMap<PathBuf, Entry>,
    expiry: BTreeSet<(Instant, PathBuf)>,
}

impl Hot {
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    fn remember(&mut self, path: PathBuf, revision: String, expires: Instant) {
        if let Some(old) = self.entries.get(&path) {
            if old.revision == revision {
                return;
            }
            self.expiry.remove(&(old.expires, path.clone()));
        }
        self.expiry.insert((expires, path.clone()));
        self.entries.insert(path, Entry { revision, expires });
        while self.entries.len() > CAPACITY {
            let (_, path) = self.expiry.pop_first().expect("Hot entries have an expiry");
            self.entries.remove(&path);
        }
    }

    fn forget(&mut self, path: &PathBuf) {
        if let Some(entry) = self.entries.remove(path) {
            self.expiry.remove(&(entry.expires, path.clone()));
        }
    }

    fn prune(&mut self, now: Instant) {
        while self
            .expiry
            .first()
            .is_some_and(|(expires, _)| *expires <= now)
        {
            let (_, path) = self.expiry.pop_first().expect("Hot expiry was present");
            self.entries.remove(&path);
        }
    }

    pub fn observe(&mut self, db: &Connection, origins: &[Origin]) -> Result<()> {
        let now = ::time::OffsetDateTime::now_utc();
        let floor = i64::try_from((now - LIFETIME).unix_timestamp_nanos())?;
        for origin in origins {
            let mut statement=db.prepare("SELECT path,file_identity,mtime_ns FROM source WHERE origin_host=?1 AND provider=?2 AND provider_home=?3 AND present=1 AND mtime_ns>=?4 ORDER BY mtime_ns DESC LIMIT 64")?;
            let rows = statement.query_map(
                params![
                    origin.host,
                    origin.provider,
                    origin.provider_home.to_string_lossy(),
                    floor
                ],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )?;
            for row in rows {
                let (path, revision, modified) = row?;
                let age = (now.unix_timestamp_nanos() - i128::from(modified)).max(0);
                let remaining = LIFETIME.saturating_sub(Duration::from_nanos(u64::try_from(age)?));
                self.remember(
                    origin.local(std::path::Path::new(&path))?,
                    revision,
                    Instant::now() + remaining,
                );
            }
        }
        self.prune(Instant::now());
        Ok(())
    }

    pub fn changed(&mut self) -> Result<Vec<PathBuf>> {
        self.prune(Instant::now());
        let paths: Vec<_> = self.entries.keys().cloned().collect();
        let mut changed = Vec::new();
        for path in paths {
            let metadata = match std::fs::symlink_metadata(&path) {
                Ok(metadata) if metadata.is_file() => metadata,
                Ok(_) => {
                    self.forget(&path);
                    changed.push(path);
                    continue;
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    self.forget(&path);
                    changed.push(path);
                    continue;
                }
                Err(error) => return Err(error.into()),
            };
            let revision = format!("{:?}", FileRevision::from(metadata));
            if self
                .entries
                .get(&path)
                .is_some_and(|entry| entry.revision != revision)
            {
                self.remember(path.clone(), revision, Instant::now() + LIFETIME);
                changed.push(path);
            }
        }
        Ok(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sessions_hot_sources_evict_least_recent_and_expire() {
        let mut hot = Hot::default();
        let now = Instant::now();
        for index in 0..=CAPACITY {
            hot.remember(
                PathBuf::from(index.to_string()),
                index.to_string(),
                now + Duration::from_secs(index as u64),
            );
        }
        assert_eq!(hot.entries.len(), CAPACITY);
        assert!(!hot.entries.contains_key(&PathBuf::from("0")));
        hot.remember(
            PathBuf::from("1"),
            "new".into(),
            now + Duration::from_secs(100),
        );
        hot.remember(
            PathBuf::from("65"),
            "65".into(),
            now + Duration::from_secs(65),
        );
        assert!(!hot.entries.contains_key(&PathBuf::from("2")));
        assert!(hot.entries.contains_key(&PathBuf::from("1")));
        hot.prune(now + Duration::from_secs(101));
        assert!(hot.is_empty());
        assert!(hot.expiry.is_empty());
    }
}
