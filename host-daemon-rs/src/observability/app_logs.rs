//! Host-side store for log segments uploaded by the iOS client.
//!
//! The phone's OSLog rotates away within hours, so anything it recorded is
//! gone before a question about it gets asked. The app drains its own log
//! store into gzipped JSONL segments and posts them here; the gateway writes
//! them verbatim under `~/Library/Logs/remote-coder/app-logs/<device>/` and
//! ages them out after [`APP_LOG_RETENTION_DAYS`] or, oldest first across all
//! devices, beyond [`APP_LOG_BYTE_CAP`].
//!
//! Segment bodies are opaque: they are stored, never parsed. What this module
//! owns is the path — a device name arrives from the network, so it is
//! sanitized to a single safe path component before it can name a directory.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
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

pub(crate) const APP_LOG_RETENTION_DAYS: u64 = 14;
pub(crate) const APP_LOG_BYTE_CAP: u64 = 1024 * 1024 * 1024;
const RETENTION_MARKER: &str = "retention.json";

#[derive(Debug, Clone)]
pub(crate) struct AppLogStore {
    dir: PathBuf,
    retention_days: u64,
    byte_cap: u64,
    publishing: Arc<Mutex<()>>,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct StoredSegment {
    pub(crate) path: PathBuf,
    pub(crate) cap: Option<CapOutcome>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CapOutcome {
    pub(crate) files: usize,
    pub(crate) bytes: u64,
    pub(crate) retained_bytes: Option<u64>,
    pub(crate) cap_bytes: u64,
    pub(crate) unreadable_entries: usize,
    pub(crate) evicted_through: Option<SystemTime>,
    pub(crate) at: SystemTime,
}

impl CapOutcome {
    pub(crate) fn is_met(&self) -> bool {
        self.retained_bytes
            .is_some_and(|retained| retained <= self.cap_bytes)
    }

    pub(crate) fn event(&self) -> &'static str {
        match (self.is_met(), self.files) {
            (false, _) => "cap_unmet",
            (true, 0) => "cap_met",
            (true, _) => "cap_evicted",
        }
    }

    pub(crate) fn fields(&self) -> Value {
        json!({
            "met": self.is_met(),
            "files": self.files,
            "bytes": self.bytes,
            "retainedBytes": self.retained_bytes,
            "capBytes": self.cap_bytes,
            "unreadableEntries": self.unreadable_entries,
            "evictedThroughMs": self.evicted_through.map(unix_millis),
            "atMs": unix_millis(self.at),
        })
    }
}

impl AppLogStore {
    pub(crate) fn new_in(dir: PathBuf, retention_days: u64, byte_cap: u64) -> AppLogStore {
        AppLogStore {
            dir,
            retention_days,
            byte_cap,
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
    ) -> Result<StoredSegment, AppLogError> {
        self.store_on(today_utc(), device, segment, body)
    }

    fn store_on(
        &self,
        today: u32,
        device: &str,
        segment: &str,
        body: &[u8],
    ) -> Result<StoredSegment, AppLogError> {
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
        let cap = self.record_cap(enforce_byte_cap(&self.dir, self.byte_cap));
        Ok(StoredSegment { path, cap })
    }

    fn record_cap(&self, outcome: CapOutcome) -> Option<CapOutcome> {
        let marker_path = self.dir.join(RETENTION_MARKER);
        let previous = std::fs::read(&marker_path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
        let previously_unmet = previous
            .as_ref()
            .is_some_and(|marker| marker["met"] == false);
        if outcome.is_met() && outcome.files == 0 && !previously_unmet {
            return None;
        }
        warn!(
            event = outcome.event(),
            files = outcome.files,
            bytes = outcome.bytes,
            retained_bytes = outcome.retained_bytes,
            cap_bytes = outcome.cap_bytes,
            unreadable = outcome.unreadable_entries,
            "app log store byte cap"
        );
        let mut marker = outcome.fields();
        if outcome.evicted_through.is_none() {
            marker["evictedThroughMs"] =
                previous.map_or(Value::Null, |previous| previous["evictedThroughMs"].clone());
        }
        marker["retentionDays"] = json!(self.retention_days);
        if let Err(error) = private_state::replace(&marker_path, marker.to_string().as_bytes()) {
            warn!(error = %format!("{error:#}"), "failed recording the app log cap outcome");
        }
        Some(outcome)
    }
}

fn enforce_byte_cap(dir: &Path, byte_cap: u64) -> CapOutcome {
    let mut unreadable_entries = 0;
    let mut segments: Vec<(SystemTime, u64, PathBuf)> = Vec::new();
    for device_dir in device_directories(dir) {
        let Ok(entries) = std::fs::read_dir(&device_dir) else {
            unreadable_entries += 1;
            continue;
        };
        for entry in entries {
            let Ok(entry) = entry else {
                unreadable_entries += 1;
                continue;
            };
            if entry.file_name().to_str().and_then(segment_day).is_none() {
                continue;
            }
            match entry.metadata() {
                Ok(metadata) => segments.push((
                    metadata.modified().unwrap_or(UNIX_EPOCH),
                    metadata.len(),
                    entry.path(),
                )),
                Err(_) => unreadable_entries += 1,
            }
        }
    }
    let mut retained: u64 = segments.iter().map(|(_, size, _)| size).sum();
    let mut files = 0;
    let mut bytes = 0;
    let mut evicted_through = None;
    if retained > byte_cap {
        segments.sort();
        for (modified, size, path) in segments {
            if retained <= byte_cap {
                break;
            }
            if std::fs::remove_file(&path).is_ok() {
                retained -= size;
                files += 1;
                bytes += size;
                evicted_through = Some(modified);
            }
        }
    }
    CapOutcome {
        files,
        bytes,
        retained_bytes: (unreadable_entries == 0).then_some(retained),
        cap_bytes: byte_cap,
        unreadable_entries,
        evicted_through,
        at: SystemTime::now(),
    }
}

fn unix_millis(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH).map_or(0, |elapsed| {
        u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX)
    })
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

fn device_directories(dir: &Path) -> impl Iterator<Item = PathBuf> {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
}

fn sweep_all_devices(dir: &Path, today: u32, retention_days: u64) {
    for device_dir in device_directories(dir) {
        sweep_expired_day_files(&device_dir, today, retention_days, segment_day);
        let _ = std::fs::remove_dir(&device_dir);
    }
}

fn segment_day(name: &str) -> Option<u32> {
    let (day, rest) = name.split_at_checked(8)?;
    if !rest.starts_with('-') || !rest.ends_with(".jsonl.gz") {
        return None;
    }
    day.parse::<u32>().ok()
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
        let store = AppLogStore::new_in(dir.clone(), 30, APP_LOG_BYTE_CAP);

        let path = store
            .store("Taylors iPhone", "a1b2c3", &gzip_body())
            .expect("segment stored")
            .path;

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
        let store = AppLogStore::new_in(dir.clone(), 30, APP_LOG_BYTE_CAP);

        for hostile in ["../../etc", "..", "/", "....//", "."] {
            match store.store(hostile, "seg", &gzip_body()) {
                Err(AppLogError::InvalidName("device")) => {}
                Ok(StoredSegment { path, .. }) => {
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
        let store = AppLogStore::new_in(dir.clone(), 30, APP_LOG_BYTE_CAP);
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
        sweep_expired_day_files(&dir, 20_260_821, 30, segment_day);

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
        let store = AppLogStore::new_in(dir.clone(), 30, APP_LOG_BYTE_CAP);

        let first = store
            .store_on(20_260_821, "phone", "seg-1", &gzip_body())
            .expect("first upload")
            .path;
        let mut retried_body = gzip_body();
        retried_body.push(b'!');
        let retry = store
            .store_on(20_260_822, "phone", "seg-1", &retried_body)
            .expect("retry")
            .path;

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
        let store = AppLogStore::new_in(dir.clone(), 30, APP_LOG_BYTE_CAP);
        let path = store
            .store_on(20_260_821, "phone", "seg-1", &gzip_body())
            .expect("first upload")
            .path;

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
        let store = AppLogStore::new_in(dir.clone(), 30, APP_LOG_BYTE_CAP);

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
        let store = AppLogStore::new_in(dir.clone(), 30, APP_LOG_BYTE_CAP);

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

    #[test]
    fn the_byte_cap_evicts_the_oldest_segments_across_devices_and_records_the_cut() {
        let dir = temp_dir("cap");
        let body_size = u64::try_from(gzip_body().len()).expect("size");
        let store = AppLogStore::new_in(dir.clone(), 30, body_size * 2);
        let base = UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
        let mut stored = Vec::new();
        for (offset, device, segment) in [(0, "phone", "a"), (60, "ipad", "b")] {
            let segment = store
                .store_on(20_260_821, device, segment, &gzip_body())
                .expect("upload");
            assert_eq!(segment.cap, None);
            std::fs::File::options()
                .write(true)
                .open(&segment.path)
                .and_then(|file| file.set_modified(base + std::time::Duration::from_secs(offset)))
                .expect("set mtime");
            stored.push(segment.path);
        }

        let newest = store
            .store_on(20_260_821, "phone", "c", &gzip_body())
            .expect("upload");

        let outcome = newest.cap.expect("over the cap");
        assert_eq!((outcome.files, outcome.bytes), (1, body_size));
        assert_eq!(outcome.retained_bytes, Some(body_size * 2));
        assert_eq!(outcome.evicted_through, Some(base));
        assert_eq!(outcome.event(), "cap_evicted");
        assert!(
            !stored[0].exists(),
            "the oldest segment goes first, whatever its device"
        );
        assert!(stored[1].exists());
        assert!(newest.path.exists());
        let marker: Value = serde_json::from_slice(
            &std::fs::read(dir.join(RETENTION_MARKER)).expect("marker written"),
        )
        .expect("marker is JSON");
        assert_eq!(marker["evictedThroughMs"], json!(1_700_000_000_000_u64));
        assert_eq!(marker["met"], json!(true));
        assert_eq!(marker["retentionDays"], json!(30));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_cap_the_store_cannot_meet_is_reported_as_unmet() {
        let dir = temp_dir("cap-unmet");
        let body_size = u64::try_from(gzip_body().len()).expect("size");
        let store = AppLogStore::new_in(dir.clone(), 30, body_size * 3);
        for segment in ["a", "b"] {
            store
                .store_on(20_260_821, "phone", segment, &gzip_body())
                .expect("upload");
        }
        let locked = dir.join("phone");
        let mut permissions = std::fs::metadata(&locked).expect("metadata").permissions();
        std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o500);
        std::fs::set_permissions(&locked, permissions.clone()).expect("read-only directory");
        let store = AppLogStore::new_in(dir.clone(), 30, body_size);

        let outcome = store
            .store_on(20_260_821, "ipad", "c", &gzip_body())
            .map(|stored| stored.cap);
        std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o700);
        std::fs::set_permissions(&locked, permissions).expect("restore directory");

        let outcome = outcome.expect("upload").expect("over the cap");
        assert!(!outcome.is_met());
        assert_eq!(outcome.event(), "cap_unmet");
        assert_eq!(outcome.retained_bytes, Some(body_size * 2));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_unreadable_device_leaves_the_total_unknown_until_it_reads_again() {
        let dir = temp_dir("cap-unknown");
        let store = AppLogStore::new_in(dir.clone(), 30, APP_LOG_BYTE_CAP);
        store
            .store_on(20_260_821, "phone", "a", &gzip_body())
            .expect("upload");
        let marker_path = dir.join(RETENTION_MARKER);
        std::fs::write(&marker_path, r#"{"met":true,"evictedThroughMs":123}"#).expect("marker");
        let marker = || -> Value {
            serde_json::from_slice(&std::fs::read(&marker_path).expect("marker")).expect("JSON")
        };
        let hidden = dir.join("phone");
        let mut permissions = std::fs::metadata(&hidden).expect("metadata").permissions();
        std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o000);
        std::fs::set_permissions(&hidden, permissions.clone()).expect("unreadable directory");

        let unknown = store
            .store_on(20_260_821, "ipad", "b", &gzip_body())
            .map(|stored| stored.cap);
        std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o700);
        std::fs::set_permissions(&hidden, permissions).expect("restore directory");

        let unknown = unknown.expect("upload").expect("reported");
        assert_eq!(
            (
                unknown.retained_bytes,
                unknown.unreadable_entries,
                unknown.event()
            ),
            (None, 1, "cap_unmet")
        );
        assert_eq!(
            (
                marker()["met"].clone(),
                marker()["evictedThroughMs"].clone()
            ),
            (json!(false), json!(123))
        );

        let recovered = store
            .store_on(20_260_821, "ipad", "c", &gzip_body())
            .expect("upload")
            .cap
            .expect("recovery reported");
        assert_eq!(recovered.event(), "cap_met");
        assert_eq!(
            (
                marker()["met"].clone(),
                marker()["evictedThroughMs"].clone()
            ),
            (json!(true), json!(123))
        );
        let quiet = store
            .store_on(20_260_821, "ipad", "d", &gzip_body())
            .expect("upload");
        assert_eq!(quiet.cap, None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
