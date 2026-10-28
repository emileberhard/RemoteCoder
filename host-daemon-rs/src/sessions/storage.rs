use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub(crate) const CAP_BYTES: u64 = 64 << 30;
pub(crate) const RESERVE_BYTES: u64 = 20 << 30;

pub(crate) struct Storage {
    root: PathBuf,
    database: PathBuf,
    cache: Mutex<Cache>,
}

#[derive(Clone, Deserialize, Serialize)]
struct Cache {
    other_bytes: u64,
    reconciled_ms: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Usage {
    pub used_bytes: u64,
    pub free_bytes: u64,
    pub cap_bytes: u64,
    pub reserve_bytes: u64,
    pub stale_reason: Option<&'static str>,
}

impl Storage {
    pub fn new(database: &Path) -> Result<Self> {
        let storage = Self {
            root: database
                .parent()
                .context("Session state needs a directory")?
                .to_owned(),
            database: database.to_owned(),
            cache: Mutex::new(Cache {
                other_bytes: 0,
                reconciled_ms: 0,
            }),
        };
        let cache = storage.load_cache()?;
        if let Some(cache) = cache {
            *storage.cache.lock().expect("Session accounting poisoned") = cache;
        } else {
            storage.reconcile()?;
        }
        Ok(storage)
    }

    fn path(&self, name: &str) -> PathBuf {
        self.root.join(name)
    }

    fn load_cache(&self) -> Result<Option<Cache>> {
        if self.path(".accounting.dirty").exists() {
            return Ok(None);
        }
        let bytes =
            crate::storage::private_state::read_bounded(&self.path(".accounting.json"), 1024)
                .map_err(|error| {
                    anyhow::anyhow!("unavailable: cannot read session accounting: {error:?}")
                })?;
        bytes
            .map(|bytes| serde_json::from_slice(&bytes).context("Invalid session accounting"))
            .transpose()
    }

    fn database_path(&self, suffix: &str) -> PathBuf {
        let mut path = self.database.as_os_str().to_os_string();
        path.push(suffix);
        path.into()
    }

    pub fn wal_bytes(&self) -> Result<u64> {
        file_bytes(&self.database_path("-wal"))
    }

    fn reconcile(&self) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut other_bytes = 0u64;
        for (count, entry) in walkdir::WalkDir::new(&self.root)
            .follow_links(false)
            .into_iter()
            .enumerate()
        {
            ensure!(
                count < 100_000 && Instant::now() < deadline,
                "unavailable: session accounting reconciliation exceeded its bounded walk"
            );
            let entry = entry?;
            if entry.file_type().is_file()
                && ![
                    self.database.clone(),
                    self.database_path("-wal"),
                    self.database_path("-shm"),
                    self.database_path("-journal"),
                    self.path(".accounting.json"),
                    self.path(".accounting.dirty"),
                    self.path(".storage.lock"),
                ]
                .contains(&entry.path().to_owned())
            {
                other_bytes = other_bytes
                    .checked_add(file_bytes(entry.path())?)
                    .context("Session state size overflow")?;
            }
        }
        *self.cache.lock().expect("Session accounting poisoned") = Cache {
            other_bytes,
            reconciled_ms: milliseconds()?,
        };
        Ok(())
    }

    fn save_cache(&self) -> Result<()> {
        let cache = self
            .cache
            .lock()
            .expect("Session accounting poisoned")
            .clone();
        crate::storage::private_state::replace(
            &self.path(".accounting.json"),
            &serde_json::to_vec(&cache)?,
        )?;
        if self.path(".accounting.dirty").exists() {
            std::fs::remove_file(self.path(".accounting.dirty"))?;
        }
        Ok(())
    }

    pub fn usage(&self) -> Result<Usage> {
        let mut used = self
            .cache
            .lock()
            .expect("Session accounting poisoned")
            .other_bytes;
        for path in [
            self.database.clone(),
            self.database_path("-wal"),
            self.database_path("-shm"),
            self.database_path("-journal"),
            self.path(".accounting.json"),
            self.path(".accounting.dirty"),
        ] {
            used = used
                .checked_add(file_bytes(&path)?)
                .context("Session state size overflow")?;
        }
        let path = std::ffi::CString::new(self.root.as_os_str().as_encoded_bytes())?;
        let mut stats = std::mem::MaybeUninit::<libc::statvfs>::uninit();
        ensure!(
            unsafe { libc::statvfs(path.as_ptr(), stats.as_mut_ptr()) } == 0,
            "unavailable: cannot measure session free disk: {}",
            std::io::Error::last_os_error()
        );
        let stats = unsafe { stats.assume_init() };
        let free = stats.f_bavail as u64 * stats.f_frsize;
        let database = file_bytes(&self.database)?;
        let checkpoint = database
            .saturating_sub(self.wal_bytes()?)
            .saturating_add(database / 128)
            .saturating_add(65536);
        Ok(Usage {
            used_bytes: used,
            free_bytes: free,
            cap_bytes: CAP_BYTES,
            reserve_bytes: RESERVE_BYTES,
            stale_reason: if self.path(".accounting.dirty").exists() {
                Some("accounting_incomplete")
            } else if admit(used, checkpoint, free).is_ok() {
                None
            } else {
                Some("budget")
            },
        })
    }

    pub fn lease(&self, incoming: u64) -> Result<Lease> {
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.path(".storage.lock"))?;
        let lock = Lease::acquire(lock)
            .context("unavailable: another session writer owns the storage budget")?;
        let cache = self.load_cache()?;
        let stale = cache.as_ref().is_none_or(|cache| {
            milliseconds().map_or(true, |now| {
                now.saturating_sub(cache.reconciled_ms) >= 600_000
            })
        });
        if stale {
            self.reconcile()?;
            self.save_cache()?;
        } else if let Some(cache) = cache {
            *self.cache.lock().expect("Session accounting poisoned") = cache;
        }
        if incoming > 0 {
            let usage = self.usage()?;
            admit(usage.used_bytes, incoming, usage.free_bytes)?;
        }
        Ok(lock)
    }

    pub fn mutate<T>(
        &self,
        paths: &[&Path],
        incoming: u64,
        operation: impl FnOnce() -> Result<T>,
    ) -> Result<T> {
        let _lease = self.lease(incoming)?;
        let before = paths.iter().try_fold(0u64, |sum, path| {
            Ok::<_, anyhow::Error>(sum + file_bytes(path)?)
        })?;
        crate::storage::private_state::replace(&self.path(".accounting.dirty"), b"1")?;
        let result = operation();
        let after = paths.iter().try_fold(0u64, |sum, path| {
            Ok::<_, anyhow::Error>(sum + file_bytes(path)?)
        })?;
        {
            let mut cache = self.cache.lock().expect("Session accounting poisoned");
            cache.other_bytes = cache
                .other_bytes
                .checked_sub(before)
                .and_then(|bytes| bytes.checked_add(after))
                .context("Session accounting invariant failed")?;
        }
        self.save_cache()?;
        result
    }
}

fn milliseconds() -> Result<u64> {
    Ok(u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_millis(),
    )?)
}

pub(crate) fn admit(used: u64, incoming: u64, free: u64) -> Result<()> {
    ensure!(
        used.checked_add(incoming.saturating_add(65536))
            .is_some_and(|bytes| bytes <= CAP_BYTES)
            && free
                .checked_sub(incoming.saturating_add(65536))
                .is_some_and(|bytes| bytes >= RESERVE_BYTES),
        "stale: budget; session state needs space within 64 GiB and a 20 GiB free-disk reserve"
    );
    Ok(())
}

fn file_bytes(path: &Path) -> Result<u64> {
    match path.metadata() {
        Ok(metadata) => Ok(metadata.len()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(error) => Err(error.into()),
    }
}

pub(crate) struct Lease(File);

impl Lease {
    pub fn acquire(file: File) -> Result<Self> {
        file.try_lock()?;
        Ok(Self(file))
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        if let Err(error) = self.0.unlock() {
            tracing::error!(%error,"Session storage lease could not unlock");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_lease_unlocks_with_an_inherited_descriptor() {
        let root = tempfile::tempdir().unwrap();
        let storage = Storage::new(&root.path().join("catalog.sqlite3")).unwrap();
        let lease = storage.lease(0).unwrap();
        let inherited = lease.0.try_clone().unwrap();
        drop(lease);
        let next = storage.lease(0).unwrap();
        drop(inherited);
        drop(next);
    }
}
