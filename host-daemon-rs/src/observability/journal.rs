//! Gateway observability journal.
//!
//! One append-only JSONL file per UTC day under
//! `~/Library/Logs/remote-coder/journal/`, recording every frame the gateway
//! sends to or receives from a client, every Claude runtime lifecycle event,
//! and every push-broker attempt — so a session can be reconstructed from the
//! host days later without a live listener attached.
//!
//! Callers hand raw payloads to a bounded channel and return immediately: all
//! parsing, elision and I/O happens on a single writer task. A full channel
//! drops the record and bumps a counter that the writer reports in-band; the
//! journal never blocks, slows, or fails gateway traffic.

use crate::observability::journal::writer::{Writer, run_writer};
use crate::observability::writer::WriterHandle;
use crate::time::{civil_from_days, days_from_civil, rfc3339_millis, unix_seconds};
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tracing::{info, warn};

#[cfg(test)]
mod harness;
mod payload;
mod writer;

/// Any JSON string longer than this is replaced by a digest stub. Sized to let
/// prompts, deltas, diffs and tool output through whole while catching
/// base64-encoded images in `turn/start` inputs.
const MAX_STRING_BYTES: usize = 16 * 1024;

/// Records buffered between the hot path and the writer task. Deep enough to
/// absorb a full delta burst; past this the record is dropped, not awaited.
const CHANNEL_CAPACITY: usize = 8192;

const MAX_QUEUED_BYTES: usize = 32 * 1024 * 1024;

const WRITE_BATCH_RECORDS: usize = 256;

/// In-flight client requests the writer remembers so a response line can name
/// its own method and latency. Bounded because a client can abandon requests.
const MAX_PENDING_REQUESTS: usize = 4096;

/// Whole-record ceiling. Per-string elision cannot catch a payload made of
/// thousands of small strings (a bounded history response, since retired,
/// averaged ~80 KB with no single string over 10 KB; one day of them was
/// 377 MB of a 402 MB file), so an oversized record keeps its envelope —
/// id, method, ok — and has its bulk `result`/`params` member stubbed.
const MAX_RECORD_BYTES: usize = 64 * 1024;

// Title requests contain a bounded, frozen model view that cannot be rebuilt
// exactly from a later transcript. Preserve it without ordinary payload elision.
const MAX_REVIEW_RECORD_BYTES: usize = 512 * 1024;

/// Where a frame heading for clients came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Source {
    /// Proxied from the upstream `codex app-server` connection.
    Codex,
    /// Translated from a Claude CLI runtime.
    Claude,
    /// Synthesized by the gateway itself.
    Gateway,
}

impl Source {
    fn as_str(self) -> &'static str {
        match self {
            Source::Codex => "codex",
            Source::Claude => "claude",
            Source::Gateway => "gateway",
        }
    }
}

#[derive(Debug)]
enum Record {
    /// A notification leaving the gateway toward one or more clients.
    Notify {
        source: Source,
        clients: usize,
        client_id: Option<u64>,
        payload: Arc<str>,
    },
    /// A client's bounded outbound queue rejected a frame.
    DeliverDrop {
        client_id: u64,
        reason: &'static str,
        payload: Arc<str>,
    },
    /// A client connected or disconnected.
    Client {
        client_id: u64,
        event: &'static str,
        remote_addr: Option<String>,
        clients: usize,
    },
    /// A client→gateway JSON-RPC request.
    RpcRequest {
        client_id: u64,
        payload: Arc<str>,
    },
    /// A gateway→client JSON-RPC response.
    RpcResponse {
        client_id: Option<u64>,
        payload: Arc<str>,
    },
    ConversationReview {
        fields: Value,
    },
    Event {
        kind: &'static str,
        fields: Value,
    },
}

/// A record with the time it was observed, so the writer's queueing delay never
/// shows up as gateway latency.
#[derive(Debug)]
struct Admitted {
    record: Record,
    at: f64,
    monotonic: Instant,
    bytes: usize,
}

impl Admitted {
    fn now(record: Record) -> Admitted {
        Admitted {
            bytes: record.retained_bytes(),
            record,
            at: unix_seconds(),
            monotonic: Instant::now(),
        }
    }
}

impl Record {
    fn retained_bytes(&self) -> usize {
        match self {
            Record::Notify { payload, .. }
            | Record::DeliverDrop { payload, .. }
            | Record::RpcRequest { payload, .. }
            | Record::RpcResponse { payload, .. } => payload.len(),
            Record::Client { remote_addr, .. } => remote_addr.as_ref().map_or(0, String::len),
            Record::Event { fields, .. } | Record::ConversationReview { fields } => {
                value_bytes(fields)
            }
        }
    }
}

fn value_bytes(value: &Value) -> usize {
    match value {
        Value::String(text) => text.len(),
        Value::Array(items) => items.iter().map(value_bytes).sum(),
        Value::Object(map) => map
            .iter()
            .map(|(key, member)| key.len() + value_bytes(member))
            .sum(),
        _ => 0,
    }
}

/// Handle to the journal. Cloning is cheap; all clones share one writer task.
#[derive(Debug, Clone)]
pub(crate) struct Journal {
    tx: Option<mpsc::Sender<Admitted>>,
    dropped: Arc<AtomicU64>,
    queued_bytes: Arc<AtomicUsize>,
    writer: Arc<WriterHandle>,
}

impl Journal {
    pub(crate) fn open_in(dir: PathBuf, retention_days: u64) -> Journal {
        if let Err(error) = std::fs::create_dir_all(&dir) {
            warn!(dir = %dir.display(), %error, "gateway journal disabled: cannot create directory");
            return Journal::disabled();
        }
        info!(dir = %dir.display(), retention_days, "gateway journal opened");

        let (tx, rx) = mpsc::channel::<Admitted>(CHANNEL_CAPACITY);
        let dropped = Arc::new(AtomicU64::new(0));
        let queued_bytes = Arc::new(AtomicUsize::new(0));
        let writer = Arc::new(WriterHandle::default());
        writer.attach(tokio::spawn(run_writer(
            rx,
            Writer::new(dir, retention_days),
            Arc::clone(&dropped),
            Arc::clone(&queued_bytes),
            writer.stop_signal(),
        )));
        Journal {
            tx: Some(tx),
            dropped,
            queued_bytes,
            writer,
        }
    }

    pub(crate) async fn drain(&self, deadline: Duration) {
        self.writer.drain(deadline, "gateway journal").await;
    }

    /// A journal that records nothing. Used by unit tests and when the journal
    /// directory is unusable.
    pub(crate) fn disabled() -> Journal {
        Journal {
            tx: None,
            dropped: Arc::new(AtomicU64::new(0)),
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            writer: Arc::default(),
        }
    }

    fn send(&self, record: Record) {
        let Some(tx) = self.tx.as_ref() else {
            return;
        };
        let admitted = Admitted::now(record);
        let bytes = admitted.bytes;
        let queued = self.queued_bytes.fetch_add(bytes, Ordering::Relaxed);
        if queued.saturating_add(bytes) > MAX_QUEUED_BYTES || tx.try_send(admitted).is_err() {
            self.queued_bytes.fetch_sub(bytes, Ordering::Relaxed);
            self.dropped.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// A notification broadcast to every connected client.
    pub(crate) fn notify(&self, source: Source, clients: usize, payload: &Arc<str>) {
        self.send(Record::Notify {
            source,
            clients,
            client_id: None,
            payload: Arc::clone(payload),
        });
    }

    /// A notification addressed to a single client (voice routing, local
    /// gateway frames such as `daemon/ready`).
    pub(crate) fn notify_client(&self, source: Source, client_id: u64, payload: &Arc<str>) {
        self.send(Record::Notify {
            source,
            clients: 1,
            client_id: Some(client_id),
            payload: Arc::clone(payload),
        });
    }

    pub(crate) fn deliver_drop(&self, client_id: u64, reason: &'static str, payload: &Arc<str>) {
        self.send(Record::DeliverDrop {
            client_id,
            reason,
            payload: Arc::clone(payload),
        });
    }

    pub(crate) fn client_event(
        &self,
        client_id: u64,
        event: &'static str,
        remote_addr: Option<String>,
        clients: usize,
    ) {
        self.send(Record::Client {
            client_id,
            event,
            remote_addr,
            clients,
        });
    }

    pub(crate) fn rpc_request(&self, client_id: u64, payload: &Arc<str>) {
        self.send(Record::RpcRequest {
            client_id,
            payload: Arc::clone(payload),
        });
    }

    pub(crate) fn rpc_response(&self, client_id: Option<u64>, payload: &Arc<str>) {
        self.send(Record::RpcResponse {
            client_id,
            payload: Arc::clone(payload),
        });
    }

    /// Claude runtime lifecycle. `fields` must be a JSON object.
    pub(crate) fn runtime(&self, event: &str, fields: Value) {
        self.send_event("runtime", event, fields);
    }

    /// Full, bounded turn-review evidence. No authentication headers or keys.
    pub(crate) fn review(&self, event: &str, fields: Value) {
        self.send(Record::ConversationReview {
            fields: with_event(event, fields),
        });
    }

    /// A push-broker attempt. `fields` must be a JSON object.
    pub(crate) fn push(&self, event: &str, fields: Value) {
        self.send_event("push", event, fields);
    }

    /// An agent tool dispatch. `fields` must be a JSON object, and must never
    /// carry the per-runtime MCP token or any other auth material.
    pub(crate) fn tool(&self, event: &str, fields: Value) {
        self.send_event("tool", event, fields);
    }

    /// A model question lifecycle step. `fields` must be a JSON object.
    pub(crate) fn question(&self, event: &str, fields: Value) {
        self.send_event("question", event, fields);
    }

    /// A file upload outcome. `fields` must be a JSON object.
    pub(crate) fn upload(&self, event: &str, fields: Value) {
        self.send_event("upload", event, fields);
    }

    pub(crate) fn transport(&self, event: &str, fields: Value) {
        self.send_event("transport", event, fields);
    }

    pub(crate) fn speech(&self, event: &str, fields: Value) {
        self.send_event("speech", event, fields);
    }

    fn send_event(&self, kind: &'static str, event: &str, fields: Value) {
        self.send(Record::Event {
            kind,
            fields: with_event(event, fields),
        });
    }
}

fn with_event(event: &str, fields: Value) -> Value {
    let mut object = match fields {
        Value::Object(map) => map,
        other => {
            let mut map = Map::new();
            map.insert("value".to_string(), other);
            map
        }
    };
    object.insert("event".to_string(), json!(event));
    Value::Object(object)
}

fn journal_file_name(day: u32) -> String {
    format!("gateway-{day:08}.jsonl")
}

/// Deletes journal files whose day is older than the retention window.
fn sweep_retention(dir: &Path, today: u32, retention_days: u64) {
    sweep_expired_day_files(dir, today, retention_days, |name| {
        name.strip_prefix("gateway-")
            .and_then(|rest| rest.strip_suffix(".jsonl"))
            .and_then(|day| day.parse::<u32>().ok())
    });
}

/// Deletes files in `dir` older than the retention window, where `day_of`
/// reads a `YYYYMMDD` out of a file name and returns `None` for anything the
/// caller does not own. Shared by the journal and the uploaded app-log store
/// so both age out on identical, testable date math.
pub(crate) fn sweep_expired_day_files(
    dir: &Path,
    today: u32,
    retention_days: u64,
    day_of: impl Fn(&str) -> Option<u32>,
) {
    let Some(cutoff) = cutoff_day(today, retention_days) else {
        return;
    };
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let Some(day) = day_of(name) else {
            continue;
        };
        if day < cutoff && std::fs::remove_file(&path).is_ok() {
            info!(file = name, "pruned expired log file");
        }
    }
}

/// The oldest `YYYYMMDD` still inside the retention window.
fn cutoff_day(today: u32, retention_days: u64) -> Option<u32> {
    let today_days = days_from_civil(today)?;
    Some(civil_from_days(
        today_days - i64::try_from(retention_days).ok()?,
    ))
}

fn civil_day(unix_seconds: f64) -> u32 {
    civil_from_days((unix_seconds / 86_400.0).floor() as i64)
}

/// Today as `YYYYMMDD`, UTC — the day boundary every log surface rotates on.
pub(crate) fn today_utc() -> u32 {
    civil_day(unix_seconds())
}

/// Now as `2026-08-21T14:03:07.482Z`, so every host log surface stamps time
/// identically and records from different files can be merged on sight.
pub(crate) fn now_rfc3339_millis() -> String {
    rfc3339_millis(unix_seconds())
}

#[cfg(test)]
mod tests {
    use super::harness::{read_lines, temp_dir};
    use super::*;
    use tokio_util::sync::CancellationToken;

    #[test]
    fn civil_dates_round_trip_through_the_epoch() {
        assert_eq!(civil_from_days(0), 19_700_101);
        assert_eq!(days_from_civil(19_700_101), Some(0));
        // 2026-08-21 and the leap day that trips naive implementations.
        assert_eq!(civil_from_days(20_686), 20_260_821);
        assert_eq!(days_from_civil(20_260_821), Some(20_686));
        assert_eq!(days_from_civil(20_240_229), Some(19_782));
        assert_eq!(civil_from_days(19_782), 20_240_229);
    }

    #[test]
    fn timestamps_render_as_rfc3339_with_millis() {
        assert_eq!(rfc3339_millis(0.0), "1970-01-01T00:00:00.000Z");
        assert_eq!(rfc3339_millis(-0.001), "1969-12-31T23:59:59.999Z");
        assert_eq!(rfc3339_millis(86_399.999), "1970-01-01T23:59:59.999Z");
        assert_eq!(rfc3339_millis(86_400.0), "1970-01-02T00:00:00.000Z");
        assert_eq!(
            rfc3339_millis(1_787_323_387.482),
            "2026-08-21T14:43:07.482Z"
        );
    }

    #[test]
    fn the_retention_sweep_keeps_exactly_the_window() {
        let dir = temp_dir("sweep");
        std::fs::create_dir_all(&dir).expect("dir");
        // 2026-08-21 minus 30 days is 2026-07-22: the boundary file stays.
        for name in [
            "gateway-20260721.jsonl",
            "gateway-20260722.jsonl",
            "gateway-20260821.jsonl",
            "codex-gateway.2026-07-01.log",
        ] {
            std::fs::write(dir.join(name), "{}\n").expect("write");
        }

        sweep_retention(&dir, 20_260_821, 30);

        let mut remaining: Vec<String> = std::fs::read_dir(&dir)
            .expect("read dir")
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .collect();
        remaining.sort();
        assert_eq!(
            remaining,
            vec![
                "codex-gateway.2026-07-01.log",
                "gateway-20260722.jsonl",
                "gateway-20260821.jsonl",
            ]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn review_payloads_are_complete_private_and_explicit_about_capacity_loss() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().expect("isolated journal");
        let path = dir
            .path()
            .join(journal_file_name(civil_day(unix_seconds())));
        std::fs::write(&path, "").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        let journal = Journal::open_in(dir.path().to_owned(), 30);
        let body = json!({"state":{"messages":[{"text":"a".repeat(90 * 1024)}]}});
        journal.review(
            "request",
            json!({"traceId":"trace","body":body,"payloadComplete":true}),
        );
        journal.review(
            "request",
            json!({"traceId":"oversized","body":"b".repeat(MAX_REVIEW_RECORD_BYTES + 1)}),
        );
        journal.drain(Duration::from_secs(5)).await;
        let lines: Vec<Value> = std::fs::read_to_string(&path)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(lines[0]["kind"], "review");
        assert_eq!(
            lines[0]["body"], body,
            "review inputs must survive both ordinary journal trimming rules"
        );
        assert_eq!(lines[0]["payloadComplete"], true);
        assert_eq!(lines[1]["traceId"], "oversized");
        assert_eq!(lines[1]["payloadComplete"], false);
        assert_eq!(lines[1]["body"]["_elided"], true);
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o077,
            0
        );
    }

    #[tokio::test]
    async fn notifications_and_rpc_pairs_are_recorded_with_identity() {
        let dir = temp_dir("records");
        let journal = Journal::open_in(dir.clone(), 30);

        journal.rpc_request(
            7,
            &Arc::from(
                r#"{"id":11,"method":"turn/start","params":{"threadId":"claude-session-1"}}"#,
            ),
        );
        journal.rpc_response(
            Some(7),
            &Arc::from(r#"{"id":11,"result":{"turnId":"turn-3"}}"#),
        );
        journal.notify(
            Source::Claude,
            2,
            &Arc::from(
                r#"{"method":"turn/started","params":{"threadId":"claude-session-1","turnId":"turn-3"}}"#,
            ),
        );
        journal.deliver_drop(
            9,
            "outbound queue full",
            &Arc::from(r#"{"method":"item/updated","params":{"threadId":"t","turnId":"turn-3"}}"#),
        );
        journal.client_event(9, "disconnect", None, 1);

        let path = dir.join(journal_file_name(civil_day(unix_seconds())));
        let lines = read_lines(&path, 5).await;

        assert_eq!(lines[0]["kind"], "rpc");
        assert_eq!(lines[0]["direction"], "request");
        assert_eq!(lines[0]["method"], "turn/start");
        assert_eq!(lines[0]["clientId"], 7);
        assert_eq!(lines[0]["threadId"], "claude-session-1");
        assert_eq!(
            lines[0]["payload"]["params"]["threadId"],
            "claude-session-1"
        );

        assert_eq!(lines[1]["direction"], "response");
        assert_eq!(lines[1]["ok"], json!(true));
        assert_eq!(
            lines[1]["method"], "turn/start",
            "responses inherit their request's method"
        );
        assert!(lines[1]["elapsedMs"].as_f64().is_some());

        assert_eq!(lines[2]["kind"], "notify");
        assert_eq!(lines[2]["source"], "claude");
        assert_eq!(lines[2]["clients"], 2);
        assert_eq!(lines[2]["turnId"], "turn-3");

        assert_eq!(lines[3]["kind"], "deliver_drop");
        assert_eq!(lines[3]["clientId"], 9);
        assert_eq!(lines[3]["method"], "item/updated");
        assert!(lines[3].get("payload").is_none(), "drops carry no payload");

        assert_eq!(lines[4]["kind"], "client");
        assert_eq!(lines[4]["event"], "disconnect");
        assert!(lines[4]["ts"].as_str().expect("ts").ends_with('Z'));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_response_arriving_after_disconnect_still_names_its_method() {
        let dir = temp_dir("late-response");
        let journal = Journal::open_in(dir.clone(), 30);

        journal.rpc_request(
            21,
            &Arc::from(r#"{"id":62,"method":"claude/status","params":{}}"#),
        );
        journal.client_event(21, "disconnect", None, 0);
        journal.rpc_response(Some(21), &Arc::from(r#"{"id":62,"result":{"ok":false}}"#));

        let path = dir.join(journal_file_name(civil_day(unix_seconds())));
        let lines = read_lines(&path, 3).await;
        assert_eq!(lines[2]["direction"], "response");
        assert_eq!(
            lines[2]["method"], "claude/status",
            "slow RPCs routinely outlive their socket; the pending entry must survive disconnect"
        );
        assert!(lines[2]["elapsedMs"].as_f64().is_some());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn an_oversized_record_keeps_its_envelope_and_stubs_the_bulk() {
        let dir = temp_dir("oversized");
        let journal = Journal::open_in(dir.clone(), 30);

        // Thousands of small strings: no single string crosses the per-string
        // limit, but the record as a whole is far over the ceiling.
        let messages: Vec<Value> = (0..12_000).map(|i| json!({"t": format!("m{i}")})).collect();
        let response = json!({"id": 30, "result": {"messages": messages}}).to_string();
        assert!(response.len() > MAX_RECORD_BYTES);
        journal.rpc_response(Some(13), &Arc::from(response.as_str()));

        let path = dir.join(journal_file_name(civil_day(unix_seconds())));
        let lines = read_lines(&path, 1).await;
        assert_eq!(lines[0]["payload"]["id"], 30, "the envelope survives");
        assert_eq!(lines[0]["payload"]["result"]["_elided"], json!(true));
        assert!(
            lines[0]["payload"]["result"]["bytes"]
                .as_u64()
                .expect("bytes")
                > 64 * 1024
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn drain_writes_the_queued_records_before_it_returns() {
        let dir = temp_dir("drain");
        let journal = Journal::open_in(dir.clone(), 30);
        journal.notify(Source::Gateway, 1, &Arc::from(r#"{"method":"noop"}"#));

        journal.drain(Duration::from_secs(5)).await;

        let path = dir.join(journal_file_name(civil_day(unix_seconds())));
        let content = std::fs::read_to_string(&path).expect("journal file");
        assert!(content.contains(r#""kind":"notify""#), "{content}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_stalled_writer_holds_at_most_the_byte_budget() {
        let dir = temp_dir("byte-budget");
        std::fs::create_dir_all(&dir).expect("dir");
        let (tx, rx) = mpsc::channel::<Admitted>(CHANNEL_CAPACITY);
        let journal = Journal {
            tx: Some(tx),
            dropped: Arc::new(AtomicU64::new(0)),
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            writer: Arc::default(),
        };
        let megabyte: Arc<str> = Arc::from("x".repeat(1024 * 1024));

        for _ in 0..40 {
            journal.notify(Source::Gateway, 1, &megabyte);
        }

        let accepted = MAX_QUEUED_BYTES / megabyte.len();
        assert_eq!(
            journal.dropped.load(Ordering::Relaxed),
            (40 - accepted) as u64
        );
        assert_eq!(
            journal.queued_bytes.load(Ordering::Relaxed),
            MAX_QUEUED_BYTES
        );

        tokio::spawn(run_writer(
            rx,
            Writer::new(dir.clone(), 30),
            Arc::clone(&journal.dropped),
            Arc::clone(&journal.queued_bytes),
            CancellationToken::new(),
        ));
        let path = dir.join(journal_file_name(civil_day(unix_seconds())));
        read_lines(&path, accepted + 1).await;
        assert_eq!(journal.queued_bytes.load(Ordering::Relaxed), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
