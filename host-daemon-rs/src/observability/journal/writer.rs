use std::collections::{BTreeMap, HashMap};

use tokio::io::AsyncWriteExt;
use tokio_util::sync::CancellationToken;

use super::payload::{
    Payload, elide_oversized_event, insert_kind, notification_identity, parse_and_elide,
    redact_call_details, rpc_thread_id, string_field,
};
use super::{
    Admitted, MAX_PENDING_REQUESTS, MAX_REVIEW_RECORD_BYTES, Record, WRITE_BATCH_RECORDS,
    civil_day, journal_file_name, sweep_retention,
};
use crate::time::{rfc3339_millis, unix_seconds};
use serde_json::{Map, Value, json};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::time::Instant;
use tokio::sync::mpsc;
use tracing::warn;

pub(super) async fn run_writer(
    mut rx: mpsc::Receiver<Admitted>,
    mut writer: Writer,
    dropped: Arc<AtomicU64>,
    queued_bytes: Arc<AtomicUsize>,
    stop: CancellationToken,
) {
    let mut reported_drops: u64 = 0;
    let mut records = Vec::with_capacity(WRITE_BATCH_RECORDS);
    let mut lines = Vec::new();
    let mut closing = false;
    loop {
        let received = tokio::select! {
            received = rx.recv_many(&mut records, WRITE_BATCH_RECORDS) => received,
            () = stop.cancelled(), if !closing => {
                rx.close();
                closing = true;
                continue;
            }
        };
        if received == 0 {
            break;
        }
        let observed = dropped.load(Ordering::Relaxed);
        if observed > reported_drops {
            let line = writer.stamp(
                json!({
                    "kind": "journal_drop",
                    "dropped": observed,
                    "since": reported_drops,
                }),
                unix_seconds(),
            );
            append_line(&mut lines, &line);
            reported_drops = observed;
        }
        for admitted in records.drain(..) {
            let bytes = admitted.bytes;
            let line = writer.render(admitted);
            queued_bytes.fetch_sub(bytes, Ordering::Relaxed);
            append_line(&mut lines, &line);
        }
        if let Some(line) = writer.correlation_loss() {
            append_line(&mut lines, &line);
        }
        writer.write(&lines).await;
        lines.clear();
    }
}

fn append_line(lines: &mut Vec<u8>, line: &Value) {
    let start = lines.len();
    match serde_json::to_writer(&mut *lines, line) {
        Ok(()) => lines.push(b'\n'),
        Err(_) => lines.truncate(start),
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum RequestId {
    Text(String),
    Number(String),
}

impl RequestId {
    fn from_json(id: &Value) -> Option<RequestId> {
        match id {
            Value::String(text) => Some(RequestId::Text(text.clone())),
            Value::Number(number) => Some(RequestId::Number(number.to_string())),
            _ => None,
        }
    }
}

struct PendingRequest {
    method: String,
    admitted: Instant,
    sequence: u64,
}

#[derive(Default)]
struct PendingRequests {
    entries: HashMap<(u64, RequestId), PendingRequest>,
    by_age: BTreeMap<u64, (u64, RequestId)>,
    next_sequence: u64,
    evicted: u64,
}

impl PendingRequests {
    fn remember(&mut self, client_id: u64, id: RequestId, method: String, admitted: Instant) {
        let key = (client_id, id);
        self.forget(&key);
        if self.entries.len() >= MAX_PENDING_REQUESTS
            && let Some((_, oldest)) = self.by_age.pop_first()
        {
            self.entries.remove(&oldest);
            self.evicted += 1;
        }
        let sequence = self.next_sequence;
        self.next_sequence += 1;
        self.by_age.insert(sequence, key.clone());
        self.entries.insert(
            key,
            PendingRequest {
                method,
                admitted,
                sequence,
            },
        );
    }

    fn take(&mut self, client_id: u64, id: &RequestId) -> Option<PendingRequest> {
        self.forget(&(client_id, id.clone()))
    }

    fn forget(&mut self, key: &(u64, RequestId)) -> Option<PendingRequest> {
        let request = self.entries.remove(key)?;
        self.by_age.remove(&request.sequence);
        Some(request)
    }

    fn evicted(&self) -> u64 {
        self.evicted
    }
}

pub(super) struct Writer {
    dir: PathBuf,
    retention_days: u64,
    open: Option<(u32, tokio::fs::File)>,
    io_error_logged: bool,
    pending: PendingRequests,
    reported_correlation_losses: u64,
}

impl Writer {
    pub(super) fn new(dir: PathBuf, retention_days: u64) -> Writer {
        Writer {
            dir,
            retention_days,
            open: None,
            io_error_logged: false,
            pending: PendingRequests::default(),
            reported_correlation_losses: 0,
        }
    }

    fn stamp(&self, fields: Value, at: f64) -> Value {
        let mut object = match fields {
            Value::Object(map) => map,
            other => {
                let mut map = Map::new();
                map.insert("value".to_string(), other);
                map
            }
        };
        object.insert("ts".to_string(), json!(rfc3339_millis(at)));
        let mut value = Value::Object(object);
        redact_call_details(&mut value);
        value
    }

    fn correlation_loss(&mut self) -> Option<Value> {
        let evicted = self.pending.evicted();
        if evicted <= self.reported_correlation_losses {
            return None;
        }
        let line = self.stamp(
            json!({
                "kind": "journal_correlation_loss",
                "evicted": evicted,
                "since": self.reported_correlation_losses,
            }),
            unix_seconds(),
        );
        self.reported_correlation_losses = evicted;
        Some(line)
    }

    fn render(&mut self, admitted: Admitted) -> Value {
        let Admitted {
            record,
            at,
            monotonic,
            bytes: _,
        } = admitted;
        match record {
            Record::Notify {
                source,
                clients,
                client_id,
                payload,
            } => {
                let mut parsed = parse_and_elide(&payload);
                let (method, thread_id, turn_id) = notification_identity(&parsed);
                self.stamp(
                    json!({
                        "kind": "notify",
                        "method": method,
                        "threadId": thread_id,
                        "turnId": turn_id,
                        "source": source.as_str(),
                        "clients": clients,
                        "clientId": client_id,
                        "payload": parsed.take(),
                    }),
                    at,
                )
            }
            Record::DeliverDrop {
                client_id,
                reason,
                payload,
            } => {
                let parsed = parse_and_elide(&payload);
                let (method, thread_id, turn_id) = notification_identity(&parsed);
                self.stamp(
                    json!({
                        "kind": "deliver_drop",
                        "clientId": client_id,
                        "method": method,
                        "threadId": thread_id,
                        "turnId": turn_id,
                        "reason": reason,
                    }),
                    at,
                )
            }
            Record::Client {
                client_id,
                event,
                remote_addr,
                clients,
            } => {
                // Deliberately no pending-map cleanup here: the slow Claude
                // RPCs routinely outlive their socket, and dropping their
                // entries on disconnect blanked method + elapsedMs on exactly
                // the responses worth measuring. Stale entries are evicted
                // oldest-first in `PendingRequests::remember` instead.
                self.stamp(
                    json!({
                        "kind": "client",
                        "clientId": client_id,
                        "event": event,
                        "remoteAddr": remote_addr,
                        "clients": clients,
                    }),
                    at,
                )
            }
            Record::RpcRequest { client_id, payload } => {
                let mut parsed = parse_and_elide(&payload);
                let method = string_field(&parsed, "method");
                let id = parsed.value().get("id").cloned();
                if let (Some(method), Some(id)) = (method.as_ref(), id.as_ref())
                    && let Some(id) = RequestId::from_json(id)
                {
                    self.pending
                        .remember(client_id, id, method.clone(), monotonic);
                }
                if method.as_deref() == Some("command/exec") {
                    let argument_count = parsed
                        .value()
                        .get("params")
                        .and_then(|params| params.get("command"))
                        .and_then(Value::as_array)
                        .map(Vec::len);
                    parsed = Payload(json!({
                        "id": id,
                        "method": "command/exec",
                        "argumentCount": argument_count,
                        "bytes": payload.len(),
                    }));
                }
                self.stamp(
                    json!({
                        "kind": "rpc",
                        "direction": "request",
                        "method": method,
                        "id": id,
                        "clientId": client_id,
                        "threadId": rpc_thread_id(parsed.value()),
                        "payload": parsed.take(),
                    }),
                    at,
                )
            }
            Record::RpcResponse { client_id, payload } => {
                let mut parsed = parse_and_elide(&payload);
                let id = parsed.value().get("id").cloned();
                let error = parsed.value().get("error").cloned();
                let matched = client_id
                    .zip(id.as_ref().and_then(RequestId::from_json))
                    .and_then(|(client_id, id)| self.pending.take(client_id, &id));
                let method = matched.as_ref().map(|request| request.method.clone());
                let elapsed_ms = matched.as_ref().map(|request| {
                    (monotonic
                        .saturating_duration_since(request.admitted)
                        .as_secs_f64()
                        * 1000.0)
                        .round()
                });
                if method.as_deref() == Some("command/exec") {
                    parsed = Payload(json!({ "id": id, "bytes": payload.len() }));
                }
                self.stamp(
                    json!({
                        "kind": "rpc",
                        "direction": "response",
                        "method": method,
                        "id": id,
                        "clientId": client_id,
                        "ok": error.is_none(),
                        "elapsedMs": elapsed_ms,
                        "payload": parsed.take(),
                    }),
                    at,
                )
            }
            Record::ConversationReview { mut fields } => {
                insert_kind(&mut fields, "review");
                let bytes = fields.to_string().len();
                if bytes > MAX_REVIEW_RECORD_BYTES {
                    // Never present a capacity-limited record as complete evidence.
                    elide_oversized_event(&mut fields);
                    fields["payloadComplete"] = json!(false);
                    fields["recordBytes"] = json!(bytes);
                    fields["recordLimitBytes"] = json!(MAX_REVIEW_RECORD_BYTES);
                }
                self.stamp(fields, at)
            }
            Record::Event { kind, fields } => {
                let mut fields = fields;
                insert_kind(&mut fields, kind);
                elide_oversized_event(&mut fields);
                self.stamp(fields, at)
            }
        }
    }

    async fn write(&mut self, lines: &[u8]) {
        if lines.is_empty() {
            return;
        }
        let Some(file) = self.ensure_file().await else {
            return;
        };
        let written = match file.write_all(lines).await {
            Ok(()) => file.flush().await,
            Err(error) => Err(error),
        };
        if let Err(error) = written {
            self.open = None;
            self.log_io_error(&error);
        }
    }

    /// Returns today's file, rotating and sweeping retention on a day change.
    async fn ensure_file(&mut self) -> Option<&mut tokio::fs::File> {
        let today = civil_day(unix_seconds());
        if self.open.as_ref().is_some_and(|(day, _)| *day == today) {
            return self.open.as_mut().map(|(_, file)| file);
        }

        if let Some((_, mut previous)) = self.open.take() {
            let _ = previous.flush().await;
        }
        sweep_retention(&self.dir, today, self.retention_days);

        let path = self.dir.join(journal_file_name(today));
        match tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&path)
            .await
        {
            Ok(file) => {
                use std::os::unix::fs::PermissionsExt;
                if let Err(error) = file
                    .set_permissions(std::fs::Permissions::from_mode(0o600))
                    .await
                {
                    self.log_io_error(&error);
                    return None;
                }
                self.io_error_logged = false;
                self.open = Some((today, file));
                self.open.as_mut().map(|(_, file)| file)
            }
            Err(error) => {
                self.log_io_error(&error);
                None
            }
        }
    }

    /// One warning per failure streak; a healthy write resets the latch.
    fn log_io_error(&mut self, error: &std::io::Error) {
        if self.io_error_logged {
            return;
        }
        self.io_error_logged = true;
        warn!(dir = %self.dir.display(), %error, "gateway journal write failed; dropping records");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::observability::journal::harness::{read_lines, temp_dir};
    use crate::observability::journal::{Journal, MAX_RECORD_BYTES, Source, with_event};
    use tokio_util::sync::CancellationToken;

    #[test]
    fn command_exec_journal_records_shape_without_command_or_push_tokens() {
        let mut writer = Writer::new(PathBuf::new(), 1);
        let secret = "a1b2c3d4e5f60718";
        let command = format!("cat <<'EOF'\nTOKEN={secret}\nEOF");
        let request = json!({
            "id": 7,
            "method": "command/exec",
            "params": {"command": ["zsh", "-lc", command], "env": {"SECRET": secret}}
        });
        let request_line = writer.render(Admitted::now(Record::RpcRequest {
            client_id: 3,
            payload: Arc::from(request.to_string()),
        }));
        assert_eq!(request_line["method"], "command/exec");
        assert_eq!(request_line["payload"]["argumentCount"], 3);
        assert_eq!(request_line["payload"]["bytes"], request.to_string().len());
        assert!(!request_line.to_string().contains(secret));
        assert!(!request_line.to_string().contains("cat <<"));

        let response = json!({"id": 7, "result": {"stdout": secret, "exitCode": 0}});
        let response_line = writer.render(Admitted::now(Record::RpcResponse {
            client_id: Some(3),
            payload: Arc::from(response.to_string()),
        }));
        assert_eq!(response_line["ok"], true);
        assert!(!response_line.to_string().contains(secret));

        let push_line = writer.render(Admitted::now(Record::Event {
            kind: "push",
            fields: json!({"deviceToken": secret, "nested": {"locationPushToken": secret}}),
        }));
        assert!(!push_line.to_string().contains(secret));
    }

    #[test]
    fn a_tool_dispatch_renders_under_its_own_kind() {
        let mut writer = Writer::new(temp_dir("tool"), 30);

        let line = writer.render(Admitted::now(Record::Event {
            kind: "tool",
            fields: with_event(
                "dispatch",
                json!({"tool": "end_voice_call", "source": "codex", "outcome": "ok"}),
            ),
        }));

        assert_eq!(line["kind"], "tool");
        assert_eq!(line["event"], "dispatch");
        assert_eq!(line["tool"], "end_voice_call");
        assert_eq!(line["source"], "codex");
        assert!(line["ts"].is_string(), "every line is timestamped");
    }

    #[tokio::test]
    async fn a_day_change_rotates_into_a_new_file() {
        let dir = temp_dir("rotate");
        std::fs::create_dir_all(&dir).expect("dir");
        let mut writer = Writer::new(dir.clone(), 30);

        writer.write(b"{\"kind\":\"first\"}\n").await;
        let first_day = writer.open.as_ref().expect("open file").0;

        // Force the boundary the way a midnight tick would.
        writer.open.as_mut().expect("open file").0 = first_day - 1;
        writer.write(b"{\"kind\":\"second\"}\n").await;

        assert_eq!(writer.open.as_ref().expect("open file").0, first_day);
        let today = std::fs::read_to_string(dir.join(journal_file_name(first_day))).expect("today");
        assert!(today.contains("\"first\""), "first line stays in its file");
        assert!(
            today.contains("\"second\""),
            "second line lands after rotation"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_full_channel_drops_records_without_blocking_and_reports_the_count() {
        let dir = temp_dir("drops");
        std::fs::create_dir_all(&dir).expect("dir");
        let (tx, rx) = mpsc::channel::<Admitted>(1);
        let dropped = Arc::new(AtomicU64::new(0));
        let journal = Journal {
            tx: Some(tx),
            dropped: Arc::clone(&dropped),
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            writer: Arc::default(),
        };

        // Nothing is draining the channel yet, so everything past the first
        // record must be dropped rather than awaited.
        for _ in 0..64 {
            journal.notify(Source::Gateway, 1, &Arc::from(r#"{"method":"noop"}"#));
        }
        assert_eq!(dropped.load(Ordering::Relaxed), 63);

        tokio::spawn(run_writer(
            rx,
            Writer::new(dir.clone(), 30),
            Arc::clone(&dropped),
            Arc::clone(&journal.queued_bytes),
            CancellationToken::new(),
        ));

        let path = dir.join(journal_file_name(civil_day(unix_seconds())));
        let lines = read_lines(&path, 2).await;
        assert_eq!(
            lines[0]["kind"], "journal_drop",
            "the drop count is reported in-band before the next record"
        );
        assert_eq!(lines[0]["dropped"], json!(63));
        assert_eq!(lines[1]["kind"], "notify");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn latency_and_timestamps_come_from_admission_not_from_dequeue() {
        let mut writer = Writer::new(PathBuf::new(), 1);
        let admitted = Instant::now();
        let request_record = request_at(1, json!(5), "turn/start");
        let request = writer.render(Admitted {
            bytes: request_record.retained_bytes(),
            record: request_record,
            at: 1_787_323_387.0,
            monotonic: admitted,
        });
        let response_record = response_to(1, json!(5));
        let response = writer.render(Admitted {
            bytes: response_record.retained_bytes(),
            record: response_record,
            at: 1_787_323_387.25,
            monotonic: admitted + std::time::Duration::from_millis(250),
        });

        assert_eq!(request["ts"], "2026-08-21T14:43:07.000Z");
        assert_eq!(response["ts"], "2026-08-21T14:43:07.250Z");
        assert_eq!(response["elapsedMs"], json!(250.0));
    }

    #[test]
    fn string_and_numeric_request_ids_are_distinct_requests() {
        let mut writer = Writer::new(PathBuf::new(), 1);
        writer.render(Admitted::now(request_at(1, json!("1"), "text/method")));
        writer.render(Admitted::now(request_at(1, json!(1), "number/method")));

        let numeric = writer.render(Admitted::now(response_to(1, json!(1))));
        let text = writer.render(Admitted::now(response_to(1, json!("1"))));

        assert_eq!(numeric["method"], "number/method");
        assert_eq!(text["method"], "text/method");
    }

    #[test]
    fn a_full_pending_map_evicts_only_the_oldest_and_records_the_loss() {
        let mut writer = Writer::new(PathBuf::new(), 1);
        let admitted = Instant::now();
        for id in 0..=MAX_PENDING_REQUESTS {
            writer.pending.remember(
                1,
                RequestId::Number(id.to_string()),
                format!("method-{id}"),
                admitted,
            );
        }

        assert_eq!(writer.pending.entries.len(), MAX_PENDING_REQUESTS);
        assert!(
            writer
                .pending
                .take(1, &RequestId::Number("0".to_string()))
                .is_none()
        );
        assert_eq!(
            writer
                .pending
                .take(1, &RequestId::Number("1".to_string()))
                .map(|request| request.method),
            Some("method-1".to_string())
        );
        let loss = writer.correlation_loss().expect("loss is reported");
        assert_eq!(loss["kind"], "journal_correlation_loss");
        assert_eq!(loss["evicted"], json!(1));
        assert!(writer.correlation_loss().is_none(), "reported once");
    }

    #[test]
    fn an_oversized_runtime_record_keeps_its_event_and_stubs_its_bulk() {
        let mut writer = Writer::new(PathBuf::new(), 1);
        let members: Map<String, Value> = (0..10)
            .map(|index| (format!("member{index}"), json!("x".repeat(15_000))))
            .chain([("thread".to_string(), json!("claude-session-1"))])
            .collect();

        let line = writer.render(Admitted::now(Record::Event {
            kind: "runtime",
            fields: with_event("spawn", Value::Object(members)),
        }));

        assert!(line.to_string().len() < MAX_RECORD_BYTES + 256);
        assert_eq!(line["kind"], "runtime");
        assert_eq!(line["event"], "spawn");
        assert_eq!(line["thread"], "claude-session-1");
        assert!(
            line.as_object()
                .expect("object")
                .values()
                .any(|member| member["_elided"] == json!(true))
        );
    }

    fn request_at(client_id: u64, id: Value, method: &str) -> Record {
        Record::RpcRequest {
            client_id,
            payload: Arc::from(json!({"id": id, "method": method}).to_string()),
        }
    }

    fn response_to(client_id: u64, id: Value) -> Record {
        Record::RpcResponse {
            client_id: Some(client_id),
            payload: Arc::from(json!({"id": id, "result": {}}).to_string()),
        }
    }
}
