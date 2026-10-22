//! ChatGPT desktop reconciliation journal.
//!
//! One append-only JSONL file per UTC day under
//! `~/Library/Logs/remote-coder/desktop/`, recording why each shared-Codex
//! reconciliation did or did not touch the running ChatGPT app.
//!
//! Reconciliation normally runs as a short-lived launchd-invoked CLI process
//! that can bail at any step, so records are written *synchronously, before*
//! the step they describe: an invocation that dies while stopping ChatGPT
//! still leaves its intent, its targets and its reason on disk. That is the
//! whole point of the file — the previous design proved a reconciliation had
//! run but never which branch it took, so an unexpected relaunch could not be
//! explained afterwards without reproducing it.
//!
//! Every record is correlated by one `invocation` id, and writes are
//! best-effort: a journal failure degrades to a no-op and never fails
//! reconciliation.
//!
//! Nothing here may carry process environments, tokens or credentials, and
//! this module cannot enforce that: safety comes from the caller passing only
//! allowlisted non-secret fields (see `runtime::ObservedEnvironment`). Raw
//! `ps eww` output holds the target's entire environment — on this host that
//! includes live API tokens — so it must never reach a record.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::{Map, Value, json};
use tracing::{info, warn};

use crate::config::DEFAULT_LOG_RETENTION_DAYS;
use crate::observability::journal::{now_rfc3339_millis, sweep_expired_day_files, today_utc};

/// Longest sanitized error detail a record keeps. Long enough for an anyhow
/// chain naming the failing step, short enough that a repeatedly failing
/// five-minute check cannot grow the day file without bound.
const MAX_DETAIL_CHARS: usize = 500;

/// Environment variable the launchd job sets so a periodic check is
/// distinguishable from a hand-run one. Absent means an operator ran it.
const TRIGGER_ENV_KEY: &str = "RC_DESKTOP_TRIGGER";

/// Records one desktop reconciliation invocation. Cheap to open; a failure to
/// open degrades to a journal that records nothing.
pub(crate) struct DesktopJournal {
    file: Option<Mutex<std::fs::File>>,
    path: Option<PathBuf>,
    invocation: String,
    operation: &'static str,
    trigger: String,
    started: std::time::Instant,
}

impl DesktopJournal {
    /// Opens today's desktop journal for one invocation of `operation`
    /// (`launch`, `check` or `stop`) attributed to `origin` — the in-process
    /// caller's name, or `cli` when a launchd job or operator invoked the
    /// runtime command.
    pub(crate) fn open(operation: &'static str, origin: &str) -> DesktopJournal {
        let dir = crate::config::HostPaths::from_env()
            .ok()
            .map(|paths| paths.logs("desktop"));
        let trigger = if origin == "cli" {
            std::env::var(TRIGGER_ENV_KEY)
                .ok()
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| "manual".to_string())
        } else {
            origin.to_string()
        };
        let path = dir.map(|dir| day_file_path(&dir));
        let file = path
            .as_ref()
            .and_then(|path| open_day_file(path, DEFAULT_LOG_RETENTION_DAYS));
        DesktopJournal {
            file,
            path,
            invocation: invocation_id(),
            operation,
            trigger,
            started: std::time::Instant::now(),
        }
    }

    /// A journal writing into `dir`, for tests that assert on emitted records.
    #[cfg(test)]
    pub(crate) fn in_dir(dir: &Path, operation: &'static str, trigger: &str) -> DesktopJournal {
        let path = day_file_path(dir);
        DesktopJournal {
            file: open_day_file(&path, DEFAULT_LOG_RETENTION_DAYS),
            path: Some(path),
            invocation: invocation_id(),
            operation,
            trigger: trigger.to_string(),
            started: std::time::Instant::now(),
        }
    }

    /// Every record this journal has written, for tests.
    #[cfg(test)]
    pub(crate) fn records(&self) -> Vec<Value> {
        let Some(path) = self.path.as_ref() else {
            return Vec::new();
        };
        std::fs::read_to_string(path)
            .unwrap_or_default()
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| serde_json::from_str(line).expect("each record is one JSON object"))
            .collect()
    }

    /// Milliseconds since this invocation opened, for duration fields.
    pub(crate) fn elapsed_ms(&self) -> u64 {
        u64::try_from(self.started.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    /// Records one event. `fields` must be a JSON object; the envelope
    /// (`ts`, `event`, `invocation`, `operation`, `trigger`) is stamped here
    /// so no call site can emit an uncorrelated record.
    pub(crate) fn event(&self, event: &str, fields: Value) {
        let mut object = match fields {
            Value::Object(map) => map,
            other => {
                let mut map = Map::new();
                map.insert("value".to_string(), other);
                map
            }
        };
        object.insert("ts".to_string(), json!(now_rfc3339_millis()));
        object.insert("event".to_string(), json!(event));
        object.insert("invocation".to_string(), json!(self.invocation));
        object.insert("operation".to_string(), json!(self.operation));
        object.insert("trigger".to_string(), json!(self.trigger));
        self.write(&Value::Object(object));
    }

    fn write(&self, record: &Value) {
        let Some(file) = self.file.as_ref() else {
            return;
        };
        let Ok(mut line) = serde_json::to_vec(record) else {
            return;
        };
        line.push(b'\n');
        // One `write_all` of one whole line to an O_APPEND handle, so the
        // gateway's own reconciliations and the launchd job can share the day
        // file without interleaving.
        if let Ok(mut file) = file.lock()
            && let Err(error) = file.write_all(&line)
        {
            warn!(path = ?self.path, %error, "desktop journal write failed");
        }
    }
}

/// Flattens `detail` to one bounded line. This is a size and shape guard, not
/// a redaction boundary: what may be recorded at all is decided by the field
/// allowlist at the call site (`runtime::ObservedEnvironment`), and passing
/// untrusted process output through here would still leak it, only shorter.
pub(crate) fn sanitize_detail(detail: &str) -> String {
    let flattened: String = detail
        .chars()
        .map(|ch| if ch.is_control() { ' ' } else { ch })
        .collect();
    let trimmed = flattened.trim();
    if trimmed.chars().count() <= MAX_DETAIL_CHARS {
        return trimmed.to_string();
    }
    let kept: String = trimmed.chars().take(MAX_DETAIL_CHARS).collect();
    format!("{kept}…")
}

fn day_file_path(dir: &Path) -> PathBuf {
    dir.join(format!("desktop-{:08}.jsonl", today_utc()))
}

fn open_day_file(path: &Path, retention_days: u64) -> Option<Mutex<std::fs::File>> {
    let dir = path.parent()?;
    if let Err(error) = std::fs::create_dir_all(dir) {
        warn!(dir = %dir.display(), %error, "desktop journal disabled: cannot create directory");
        return None;
    }
    sweep_expired_day_files(dir, today_utc(), retention_days, |name| {
        name.strip_prefix("desktop-")
            .and_then(|rest| rest.strip_suffix(".jsonl"))
            .and_then(|day| day.parse::<u32>().ok())
    });
    match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)
    {
        Ok(file) => {
            info!(path = %path.display(), "desktop journal opened");
            Some(Mutex::new(file))
        }
        Err(error) => {
            warn!(path = %path.display(), %error, "desktop journal disabled: cannot open day file");
            None
        }
    }
}

/// 8 bytes of OS randomness, hex encoded. Falls back to a pid/time value
/// rather than failing reconciliation, because the id only has to correlate
/// records inside one day file.
fn invocation_id() -> String {
    use std::io::Read;

    let mut bytes = [0u8; 8];
    if std::fs::File::open("/dev/urandom")
        .and_then(|mut urandom| urandom.read_exact(&mut bytes))
        .is_ok()
    {
        return bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    }
    fallback_invocation_id(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default(),
    )
}

fn fallback_invocation_id(elapsed: std::time::Duration) -> String {
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_FALLBACK: AtomicU64 = AtomicU64::new(0);
    let sequence = NEXT_FALLBACK.fetch_add(1, Ordering::Relaxed);
    let nanos = elapsed.as_nanos();
    format!(
        "{:08x}{:08x}{:032x}{sequence:016x}",
        (nanos as u32).wrapping_add(sequence as u32),
        std::process::id(),
        nanos
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detail_is_bounded_and_single_line() {
        assert_eq!(sanitize_detail("  boom\nnext  "), "boom next");
        let long = "x".repeat(MAX_DETAIL_CHARS + 50);
        let sanitized = sanitize_detail(&long);
        assert_eq!(sanitized.chars().count(), MAX_DETAIL_CHARS + 1);
        assert!(sanitized.ends_with('…'));
    }

    #[test]
    fn invocation_ids_are_distinct() {
        assert_ne!(invocation_id(), invocation_id());
    }

    #[test]
    fn fallback_invocation_ids_are_distinct_within_one_clock_tick() {
        let elapsed = std::time::Duration::from_secs(42);
        assert_ne!(
            fallback_invocation_id(elapsed),
            fallback_invocation_id(elapsed)
        );
    }

    #[test]
    fn records_carry_the_correlation_envelope() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = day_file_path(dir.path());
        let journal = DesktopJournal {
            file: open_day_file(&path, 30),
            path: Some(path),
            invocation: "abcd1234".to_string(),
            operation: "launch",
            trigger: "periodic".to_string(),
            started: std::time::Instant::now(),
        };
        journal.event("desktop/decision", json!({ "reason": "healthy" }));

        let records = journal.records();
        assert_eq!(records.len(), 1);
        let record = &records[0];
        assert_eq!(record["invocation"], "abcd1234");
        assert_eq!(record["operation"], "launch");
        assert_eq!(record["trigger"], "periodic");
        assert_eq!(record["event"], "desktop/decision");
        assert_eq!(record["reason"], "healthy");
        assert!(
            record["ts"].as_str().is_some_and(|ts| ts.ends_with('Z')),
            "records must carry a UTC timestamp: {record}"
        );
    }

    #[test]
    fn expired_day_files_are_swept_on_open() {
        let dir = tempfile::tempdir().expect("temp dir");
        let stale = dir.path().join("desktop-20200101.jsonl");
        std::fs::write(&stale, "{}\n").expect("stale file");
        let _file = open_day_file(&day_file_path(dir.path()), 30).expect("day file");
        assert!(!stale.exists(), "a day file past retention must be pruned");
    }
}
