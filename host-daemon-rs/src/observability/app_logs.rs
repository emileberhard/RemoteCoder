//! Host-side store for log segments uploaded by the iOS client.
//!
//! The phone's OSLog rotates away within hours, so anything it recorded is
//! gone before a question about it gets asked. The app drains its own log
//! store into gzipped JSONL segments and posts them here; the gateway writes
//! them verbatim under `~/Library/Logs/remote-coder/app-logs/<device>/` and
//! ages them out on the same retention window as the journal.
//!
//! Segment bodies are opaque: they are stored, never parsed. What this module
//! owns is the path — a device name arrives from the network, so it is
//! sanitized to a single safe path component before it can name a directory.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use tracing::{info, warn};

use crate::observability::journal::{sweep_expired_day_files, today_utc};
use crate::storage::private_state;

/// A rejected upload, and the reason to hand back to the client.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum AppLogError {
    /// The device or segment header was missing, empty, or entirely unsafe.
    InvalidName(&'static str),
    /// The body is not gzip. Segments are stored as-is, so this is the only
    /// chance to notice a client sending something else.
    NotGzip,
    /// The directory or file could not be written.
    Io(String),
}

impl AppLogError {
    pub(crate) fn message(&self) -> String {
        match self {
            AppLogError::InvalidName(field) => format!("{field} is missing or unusable"),
            AppLogError::NotGzip => "body must be gzip-compressed JSONL".to_string(),
            AppLogError::Io(error) => format!("failed storing segment: {error}"),
        }
    }
}

/// Longest device or segment name kept. Names are cosmetic path components;
/// anything longer is a client bug or an attack, not a real device name.
const MAX_NAME_LENGTH: usize = 64;

#[derive(Debug, Clone)]
pub(crate) struct AppLogStore {
    dir: PathBuf,
    retention_days: u64,
    publishing: Arc<Mutex<()>>,
}

impl AppLogStore {
    pub(crate) fn new_in(dir: PathBuf, retention_days: u64) -> AppLogStore {
        AppLogStore {
            dir,
            retention_days,
            publishing: Arc::new(Mutex::new(())),
        }
    }

    /// Stores one segment and returns where it landed. Re-uploading a segment
    /// replaces it whole and in place, so a client that lost a 2xx can retry
    /// safely, even after midnight, and a failed retry leaves the earlier
    /// acknowledged copy intact.
    pub(crate) fn store(
        &self,
        device: &str,
        segment: &str,
        body: &[u8],
    ) -> Result<PathBuf, AppLogError> {
        self.store_on(today_utc(), device, segment, body)
    }

    fn store_on(
        &self,
        today: u32,
        device: &str,
        segment: &str,
        body: &[u8],
    ) -> Result<PathBuf, AppLogError> {
        let device = sanitize_component(device).ok_or(AppLogError::InvalidName("device"))?;
        let segment = sanitize_component(segment).ok_or(AppLogError::InvalidName("segment"))?;
        if body.len() < 2 || body[0] != 0x1f || body[1] != 0x8b {
            return Err(AppLogError::NotGzip);
        }

        let _publishing = self
            .publishing
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        sweep_all_devices(&self.dir, today, self.retention_days);

        let device_dir = self.dir.join(&device);
        std::fs::create_dir_all(&device_dir).map_err(|error| AppLogError::Io(error.to_string()))?;
        let path = existing_segment_path(&device_dir, &segment)
            .unwrap_or_else(|| device_dir.join(format!("{today:08}-{segment}.jsonl.gz")));
        private_state::replace(&path, body)
            .map_err(|error| AppLogError::Io(format!("{error:#}")))?;
        info!(
            device = %device,
            segment = %segment,
            bytes = body.len(),
            "stored app log segment"
        );
        Ok(path)
    }
}

/// Reduces an arbitrary client-supplied string to one safe path component.
///
/// Everything outside `[A-Za-z0-9._-]` becomes `-`, so a separator or a `..`
/// can never survive into a path. A name that carries no usable character, or
/// that reduces to dots alone, is rejected rather than silently renamed.
fn sanitize_component(raw: &str) -> Option<String> {
    let mut cleaned = String::with_capacity(raw.len().min(MAX_NAME_LENGTH));
    let mut last_was_dash = false;
    for character in raw.chars().take(MAX_NAME_LENGTH * 4) {
        let safe = if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-') {
            character
        } else {
            '-'
        };
        if safe == '-' {
            if last_was_dash {
                continue;
            }
            last_was_dash = true;
        } else {
            last_was_dash = false;
        }
        cleaned.push(safe);
        if cleaned.len() >= MAX_NAME_LENGTH {
            break;
        }
    }

    let trimmed = cleaned.trim_matches(|character| character == '-' || character == '.');
    if trimmed.is_empty() || trimmed.chars().all(|character| character == '.') {
        return None;
    }
    Some(trimmed.to_string())
}

fn existing_segment_path(device_dir: &Path, segment: &str) -> Option<PathBuf> {
    let suffix = format!("-{segment}.jsonl.gz");
    std::fs::read_dir(device_dir)
        .ok()?
        .flatten()
        .map(|entry| entry.path())
        .find(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| name.strip_suffix(&suffix))
                .is_some_and(|day| day.len() == 8 && day.bytes().all(|byte| byte.is_ascii_digit()))
        })
}

fn sweep_all_devices(dir: &Path, today: u32, retention_days: u64) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for device_dir in entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
    {
        sweep_device_directory(&device_dir, today, retention_days);
        let _ = std::fs::remove_dir(&device_dir);
    }
}

fn sweep_device_directory(dir: &Path, today: u32, retention_days: u64) {
    sweep_expired_day_files(dir, today, retention_days, |name| {
        let (day, rest) = name.split_at_checked(8)?;
        if !rest.starts_with('-') || !rest.ends_with(".jsonl.gz") {
            return None;
        }
        day.parse::<u32>().ok()
    });
}

/// Logs an upload the gateway refused, so a phone that silently stops
/// reporting is visible from the host side.
pub(crate) fn warn_rejected(device: &str, error: &AppLogError) {
    warn!(device, reason = %error.message(), "rejected app log upload");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gzip_body() -> Vec<u8> {
        let mut body = vec![0x1f, 0x8b, 0x08, 0x00];
        body.extend_from_slice(b"not really compressed, stored verbatim");
        body
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("rc-app-logs-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn a_segment_lands_under_its_device_directory() {
        let dir = temp_dir("store");
        let store = AppLogStore::new_in(dir.clone(), 30);

        let path = store
            .store("Taylors iPhone", "a1b2c3", &gzip_body())
            .expect("segment stored");

        assert_eq!(
            path.parent().and_then(|parent| parent.file_name()),
            Some(std::ffi::OsStr::new("Taylors-iPhone"))
        );
        let name = path
            .file_name()
            .expect("name")
            .to_string_lossy()
            .to_string();
        assert!(name.ends_with("-a1b2c3.jsonl.gz"), "unexpected name {name}");
        assert_eq!(std::fs::read(&path).expect("read back"), gzip_body());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_device_name_can_never_escape_the_store() {
        let dir = temp_dir("traversal");
        let store = AppLogStore::new_in(dir.clone(), 30);

        for hostile in ["../../etc", "..", "/", "....//", "."] {
            match store.store(hostile, "seg", &gzip_body()) {
                Err(AppLogError::InvalidName("device")) => {}
                Ok(path) => {
                    let canonical = path.canonicalize().expect("canonical path");
                    let root = dir.canonicalize().expect("canonical root");
                    assert!(
                        canonical.starts_with(&root),
                        "{hostile:?} escaped the store as {canonical:?}"
                    );
                    assert_eq!(
                        canonical
                            .strip_prefix(&root)
                            .expect("relative")
                            .components()
                            .count(),
                        2,
                        "{hostile:?} produced more than <device>/<file>"
                    );
                }
                other => panic!("{hostile:?} produced {other:?}"),
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_segment_name_is_reduced_to_one_component() {
        assert_eq!(sanitize_component("a/b/c"), Some("a-b-c".to_string()));
        assert_eq!(
            sanitize_component("Taylor's iPhone"),
            Some("Taylor-s-iPhone".to_string())
        );
        assert_eq!(sanitize_component("  "), None);
        assert_eq!(sanitize_component(".."), None);
        assert_eq!(sanitize_component("../"), None);
        assert_eq!(
            sanitize_component(&"x".repeat(200)).map(|name| name.len()),
            Some(MAX_NAME_LENGTH)
        );
    }

    #[test]
    fn a_body_that_is_not_gzip_is_refused() {
        let dir = temp_dir("gzip");
        let store = AppLogStore::new_in(dir.clone(), 30);
        assert_eq!(
            store.store("phone", "seg", b"{\"plain\":\"jsonl\"}"),
            Err(AppLogError::NotGzip)
        );
        assert_eq!(store.store("phone", "seg", b""), Err(AppLogError::NotGzip));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn expired_segments_are_swept_and_foreign_files_are_left_alone() {
        let dir = temp_dir("sweep");
        std::fs::create_dir_all(&dir).expect("dir");
        for name in [
            "20260721-old.jsonl.gz",
            "20260722-boundary.jsonl.gz",
            "20260821-today.jsonl.gz",
            "notes.txt",
        ] {
            std::fs::write(dir.join(name), b"x").expect("write");
        }

        // 2026-08-21 minus 30 days is 2026-07-22: the boundary file stays.
        sweep_device_directory(&dir, 20_260_821, 30);

        let mut remaining: Vec<String> = std::fs::read_dir(&dir)
            .expect("read dir")
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .collect();
        remaining.sort();
        assert_eq!(
            remaining,
            vec![
                "20260722-boundary.jsonl.gz",
                "20260821-today.jsonl.gz",
                "notes.txt",
            ]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_retry_after_midnight_replaces_the_original_segment() {
        let dir = temp_dir("midnight");
        let store = AppLogStore::new_in(dir.clone(), 30);

        let first = store
            .store_on(20_260_821, "phone", "seg-1", &gzip_body())
            .expect("first upload");
        let mut retried_body = gzip_body();
        retried_body.push(b'!');
        let retry = store
            .store_on(20_260_822, "phone", "seg-1", &retried_body)
            .expect("retry");

        assert_eq!(retry, first);
        assert_eq!(std::fs::read(&first).expect("read back"), retried_body);
        assert_eq!(
            std::fs::read_dir(dir.join("phone"))
                .expect("read dir")
                .count(),
            1
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_failed_replacement_keeps_the_acknowledged_segment() {
        let dir = temp_dir("failed-replace");
        let store = AppLogStore::new_in(dir.clone(), 30);
        let path = store
            .store_on(20_260_821, "phone", "seg-1", &gzip_body())
            .expect("first upload");

        let device_dir = dir.join("phone");
        let mut permissions = std::fs::metadata(&device_dir)
            .expect("metadata")
            .permissions();
        std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o500);
        std::fs::set_permissions(&device_dir, permissions.clone()).expect("read-only directory");
        let outcome = store.store_on(20_260_821, "phone", "seg-1", b"\x1f\x8bnew");
        std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o700);
        std::fs::set_permissions(&device_dir, permissions).expect("restore directory");

        assert!(matches!(outcome, Err(AppLogError::Io(_))));
        assert_eq!(std::fs::read(&path).expect("read back"), gzip_body());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn concurrent_uploads_of_one_segment_leave_one_whole_file() {
        let dir = temp_dir("concurrent");
        let store = AppLogStore::new_in(dir.clone(), 30);

        std::thread::scope(|scope| {
            for (today, marker) in [(20_260_821, b'a'), (20_260_822, b'b')] {
                let store = store.clone();
                scope.spawn(move || {
                    let mut body = gzip_body();
                    body.push(marker);
                    store
                        .store_on(today, "phone", "seg-1", &body)
                        .expect("upload");
                });
            }
        });

        let files: Vec<_> = std::fs::read_dir(dir.join("phone"))
            .expect("read dir")
            .flatten()
            .collect();
        assert_eq!(files.len(), 1);
        let body = std::fs::read(files[0].path()).expect("read back");
        assert!(
            body == [gzip_body(), vec![b'a']].concat()
                || body == [gzip_body(), vec![b'b']].concat()
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn inactive_device_directories_are_swept_on_the_next_upload() {
        let dir = temp_dir("inactive");
        let inactive = dir.join("old-phone");
        std::fs::create_dir_all(&inactive).expect("dir");
        std::fs::write(inactive.join("20260101-old.jsonl.gz"), b"x").expect("write");
        let store = AppLogStore::new_in(dir.clone(), 30);

        store
            .store_on(20_260_821, "phone", "seg-1", &gzip_body())
            .expect("upload");

        assert!(
            !inactive.exists(),
            "an emptied inactive device directory is removed"
        );
        assert!(dir.join("phone").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
