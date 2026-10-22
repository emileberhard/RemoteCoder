//! Per-session voice observability log.
//!
//! One JSONL file per realtime voice session under
//! `~/Library/Logs/remote-coder/voice-sessions/`, capturing both transcripts,
//! every delegation's lifecycle, and a closing summary — so a voice call can
//! be evaluated afterwards from a single host-side artifact. Writes are
//! best-effort through a bounded channel; a full queue drops the event and the
//! writer reports the count in-band, so logging never blocks or fails voice
//! traffic.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc;
use tracing::info;

use crate::observability::writer::WriterHandle;
use crate::time::unix_seconds;

const MAX_SESSION_FILES: usize = 100;

const QUEUE_CAPACITY: usize = 1024;

#[derive(Debug, Clone)]
pub(crate) struct VoiceLog {
    tx: mpsc::Sender<Value>,
    dropped: Arc<AtomicU64>,
    writer: Arc<WriterHandle>,
    pub path: PathBuf,
}

impl VoiceLog {
    pub(crate) fn open(realtime_thread_id: &str) -> Option<VoiceLog> {
        let dir = crate::config::HostPaths::from_env()
            .ok()?
            .logs("voice-sessions");
        Self::open_in(dir, realtime_thread_id)
    }

    fn open_in(dir: PathBuf, realtime_thread_id: &str) -> Option<VoiceLog> {
        std::fs::create_dir_all(&dir).ok()?;
        prune_oldest(&dir, MAX_SESSION_FILES.saturating_sub(1));

        let file_id: String = realtime_thread_id
            .chars()
            .filter(|ch| ch.is_ascii_alphanumeric() || *ch == '-')
            .collect();
        let path = dir.join(format!("{:010}-{file_id}.jsonl", unix_seconds() as u64));
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .ok()?;
        info!(path = %path.display(), "voice session log opened");

        let (tx, mut rx) = mpsc::channel::<Value>(QUEUE_CAPACITY);
        let dropped = Arc::new(AtomicU64::new(0));
        let observed_drops = Arc::clone(&dropped);
        let mut file = tokio::fs::File::from_std(file);
        let writer = Arc::new(WriterHandle::default());
        let stop = writer.stop_signal();
        writer.attach(tokio::spawn(async move {
            let mut reported_drops: u64 = 0;
            let mut closing = false;
            loop {
                let event = tokio::select! {
                    event = rx.recv() => event,
                    () = stop.cancelled(), if !closing => {
                        rx.close();
                        closing = true;
                        continue;
                    }
                };
                let Some(event) = event else {
                    break;
                };
                let Ok(event_line) = serde_json::to_vec(&event) else {
                    continue;
                };
                let mut lines = Vec::new();
                let observed = observed_drops.load(Ordering::Relaxed);
                if observed > reported_drops {
                    let notice = stamped(
                        "log_drop",
                        json!({ "dropped": observed, "since": reported_drops }),
                    );
                    if let Ok(line) = serde_json::to_vec(&notice) {
                        lines.extend_from_slice(&line);
                        lines.push(b'\n');
                    }
                    reported_drops = observed;
                }
                lines.extend_from_slice(&event_line);
                lines.push(b'\n');
                if file.write_all(&lines).await.is_err() {
                    break;
                }
            }
            let _ = file.flush().await;
        }));
        Some(VoiceLog {
            tx,
            dropped,
            writer,
            path,
        })
    }

    pub(crate) async fn drain(&self, deadline: Duration) {
        self.writer.drain(deadline, "voice session log").await;
    }

    /// Records one event. `fields` must be a JSON object; `ts` and `event`
    /// are stamped here.
    pub(crate) fn event(&self, event: &str, fields: Value) {
        if self.tx.try_send(stamped(event, fields)).is_err() {
            self.dropped.fetch_add(1, Ordering::Relaxed);
        }
    }
}

fn stamped(event: &str, fields: Value) -> Value {
    let mut object = match fields {
        Value::Object(map) => map,
        other => {
            let mut map = serde_json::Map::new();
            map.insert("value".to_string(), other);
            map
        }
    };
    object.insert("ts".to_string(), json!(unix_seconds()));
    object.insert("event".to_string(), json!(event));
    Value::Object(object)
}

/// Keeps the newest `keep` files; the unix-seconds filename prefix sorts
/// chronologically.
fn prune_oldest(dir: &std::path::Path, keep: usize) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut files: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "jsonl"))
        .collect();
    if files.len() <= keep {
        return;
    }
    files.sort();
    let excess = files.len() - keep;
    for path in files.into_iter().take(excess) {
        let _ = std::fs::remove_file(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn events_land_in_the_session_file() {
        let dir = tempfile::tempdir().expect("isolated voice log");
        let log = VoiceLog::open_in(dir.path().to_owned(), "thread-abc").expect("log opens");
        let path = log.path.clone();

        log.event("session/start", json!({"model": "claude-fable-5"}));
        log.event("transcript", json!({"role": "user", "text": "hej"}));
        log.drain(Duration::from_secs(60)).await;

        let content = std::fs::read_to_string(&path).expect("flushed session file");
        let lines: Vec<Value> = content
            .lines()
            .map(|line| serde_json::from_str(line).expect("valid json"))
            .collect();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0]["event"], "session/start");
        assert_eq!(lines[0]["model"], "claude-fable-5");
        assert!(lines[0]["ts"].as_f64().expect("ts") > 0.0);
        assert_eq!(lines[1]["event"], "transcript");
    }

    #[test]
    fn prune_keeps_the_newest_files() {
        let dir = tempfile::tempdir().expect("isolated voice logs");
        for index in 0..5 {
            std::fs::write(dir.path().join(format!("000000000{index}-x.jsonl")), "{}\n")
                .expect("write");
        }
        prune_oldest(dir.path(), 2);
        let mut remaining: Vec<String> = std::fs::read_dir(dir.path())
            .expect("read dir")
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .collect();
        remaining.sort();
        assert_eq!(remaining, vec!["0000000003-x.jsonl", "0000000004-x.jsonl"]);
    }

    #[tokio::test]
    async fn a_full_queue_drops_events_and_reports_the_count_in_the_file() {
        let dir = tempfile::tempdir().expect("isolated voice log");
        let log = VoiceLog::open_in(dir.path().to_owned(), "thread-drops").expect("log opens");
        let path = log.path.clone();

        for index in 0..QUEUE_CAPACITY + 5 {
            log.event("transcript", json!({ "index": index }));
        }
        assert_eq!(log.dropped.load(Ordering::Relaxed), 5);
        log.drain(Duration::from_secs(60)).await;

        let content = std::fs::read_to_string(&path).expect("flushed session file");
        let lines: Vec<Value> = content
            .lines()
            .map(|line| serde_json::from_str(line).expect("valid json"))
            .collect();
        assert_eq!(lines.len(), QUEUE_CAPACITY + 1);
        assert_eq!(lines[0]["event"], "log_drop");
        assert_eq!(lines[0]["dropped"], json!(5));
        assert_eq!(lines[1]["index"], json!(0));
    }
}
