use anyhow::{Context, Result, ensure};
use std::fs::{File, OpenOptions};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

pub(crate) const CAP_BYTES: u64 = 64 << 30;
pub(crate) const RESERVE_BYTES: u64 = 20 << 30;

pub(crate) struct Storage {
    root: PathBuf,
    database: PathBuf,
}

#[derive(serde::Serialize)]
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
        Ok(Self {
            database: database.to_owned(),
            root: database
                .parent()
                .context("Session state needs a directory")?
                .to_owned(),
        })
    }

    pub fn usage(&self) -> Result<Usage> {
        let mut used = 0u64;
        for entry in walkdir::WalkDir::new(&self.root).follow_links(false) {
            let entry = entry?;
            if entry.file_type().is_file() {
                used = used
                    .checked_add(entry.metadata()?.len())
                    .context("Session state size overflow")?;
            }
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
        let database = self
            .database
            .metadata()
            .map_or(0, |metadata| metadata.len());
        let wal = PathBuf::from(
            self.database
                .as_os_str()
                .to_owned()
                .into_string()
                .context("Session path is not UTF-8")?
                + "-wal",
        )
        .metadata()
        .map_or(0, |metadata| metadata.len());
        let checkpoint = database
            .saturating_sub(wal)
            .saturating_add(database / 128)
            .saturating_add(65536);
        Ok(Usage {
            used_bytes: used,
            free_bytes: free,
            cap_bytes: CAP_BYTES,
            reserve_bytes: RESERVE_BYTES,
            stale_reason: if admit(used, checkpoint, free).is_ok() {
                None
            } else {
                Some("budget")
            },
        })
    }

    pub fn lease(&self, incoming: u64) -> Result<File> {
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.root.join(".storage.lock"))?;
        lock.try_lock()
            .context("unavailable: another session writer owns the storage budget")?;
        let usage = self.usage()?;
        if incoming > 0 {
            admit(usage.used_bytes, incoming, usage.free_bytes)?;
        }
        Ok(lock)
    }
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
