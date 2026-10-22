use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::LazyLock;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use regex::bytes::Regex;
use serde_json::Value;
use tokio::time::Instant;

use crate::providers::claude::records::{LineKind, read_bounded_line};

const WAKE_GRACE: Duration = Duration::from_secs(5 * 60);
const LOOP_REARM_HORIZON: Duration = Duration::from_secs(60 * 60);
const CRON_LIFETIME: Duration = Duration::from_secs(7 * 24 * 60 * 60 + 15 * 60);
const WAKE_CALL_TIMEOUT: Duration = Duration::from_secs(10 * 60);
const MAX_TRACKED_CRONS: usize = 64;
const READ_BUFFER_BYTES: usize = 1 << 20;
const MAX_LINE_BYTES: u64 = 1 << 20;

static WAKE_RECORD: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"ScheduleWakeup|CronCreate|CronDelete|"turnOrigin":"scheduled""#)
        .expect("valid wake record pattern")
});
static TOOL_RESULT_RECORD: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#""toolUseResult""#).expect("valid tool result pattern"));
static RECORD_TIMESTAMP: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#""timestamp":"([^"]+)""#).expect("valid record timestamp pattern")
});

#[derive(Clone)]
enum WakeCall {
    ScheduleWakeup,
    CronCreate { prompt: String, cron: String },
    CronDelete,
}

#[derive(Clone)]
struct Cron {
    prompt: String,
    recurring: bool,
    durable: bool,
    until: Instant,
    schedule: String,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ScheduledWork {
    Loop { next_wake: Option<SystemTime> },
    Cron { schedule: String },
}

#[derive(Clone, Default)]
pub(crate) struct WakeHold {
    offset: u64,
    restored_until: u64,
    calls: HashMap<String, (WakeCall, SystemTime)>,
    loop_until: Option<Instant>,
    loop_next_wake: Option<SystemTime>,
    crons: HashMap<String, Cron>,
}

impl WakeHold {
    pub(crate) fn resuming(transcript_len: u64) -> Self {
        Self {
            restored_until: transcript_len,
            ..Self::default()
        }
    }

    pub(crate) fn offset(&self) -> u64 {
        self.offset
    }

    pub(crate) fn held_until(&self, now: Instant) -> Option<Instant> {
        self.loop_until
            .into_iter()
            .chain(self.crons.values().map(|cron| cron.until))
            .filter(|until| *until > now)
            .max()
    }

    pub(crate) fn scheduled(&self, now: Instant, wall_now: SystemTime) -> Vec<ScheduledWork> {
        let held_loop = self
            .loop_until
            .filter(|until| *until > now)
            .map(|_| ScheduledWork::Loop {
                next_wake: self.loop_next_wake.filter(|wake| *wake > wall_now),
            });
        let mut crons = self
            .crons
            .iter()
            .filter(|(_, cron)| cron.until > now)
            .collect::<Vec<_>>();
        crons.sort_by_key(|(id, _)| *id);
        held_loop
            .into_iter()
            .chain(crons.into_iter().map(|(_, cron)| ScheduledWork::Cron {
                schedule: cron.schedule.clone(),
            }))
            .collect()
    }

    pub(crate) fn read_transcript(
        &mut self,
        path: &Path,
        now: Instant,
        wall_now: SystemTime,
    ) -> std::io::Result<()> {
        let mut file = File::open(path)?;
        if file.metadata()?.len() < self.offset {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "the transcript is shorter than the wake read offset",
            ));
        }
        file.seek(SeekFrom::Start(self.offset))?;
        self.read_lines(
            BufReader::with_capacity(READ_BUFFER_BYTES, file),
            now,
            wall_now,
        )
    }

    pub(crate) fn restored_crons(
        transcript: impl Read,
        now: Instant,
        wall_now: SystemTime,
    ) -> std::io::Result<Vec<String>> {
        let mut hold = Self::resuming(u64::MAX);
        hold.read_lines(
            BufReader::with_capacity(READ_BUFFER_BYTES, transcript),
            now,
            wall_now,
        )?;
        let mut crons = hold
            .crons
            .iter()
            .filter(|(_, cron)| !cron.durable && cron.until > now)
            .collect::<Vec<_>>();
        crons.sort_by_key(|(id, _)| *id);
        Ok(crons
            .into_iter()
            .map(|(_, cron)| cron.schedule.clone())
            .collect())
    }

    fn read_lines(
        &mut self,
        mut reader: impl BufRead,
        now: Instant,
        wall_now: SystemTime,
    ) -> std::io::Result<()> {
        let mut line = Vec::new();
        loop {
            line.clear();
            let (read, kind) = read_bounded_line(&mut reader, &mut line, MAX_LINE_BYTES)?;
            if kind == LineKind::Partial {
                return Ok(());
            }
            self.offset += read;
            if kind == LineKind::Complete {
                let restored = self.offset <= self.restored_until;
                self.observe_line(&line, restored, now, wall_now);
            }
        }
    }

    fn observe_line(&mut self, line: &[u8], restored: bool, now: Instant, wall_now: SystemTime) {
        let wanted = WAKE_RECORD.is_match(line)
            || (!self.calls.is_empty() && TOOL_RESULT_RECORD.is_match(line));
        if wanted && let Ok(record) = serde_json::from_slice::<Value>(line) {
            self.observe_record(&record, restored, now, wall_now);
        }
        if !restored
            && self.loop_until.is_some()
            && let Some(at) = RECORD_TIMESTAMP
                .captures(line)
                .and_then(|captures| captures.get(1))
                .and_then(|timestamp| std::str::from_utf8(timestamp.as_bytes()).ok())
                .and_then(record_time)
        {
            self.extend_loop(at + LOOP_REARM_HORIZON + WAKE_GRACE, now, wall_now);
        }
    }

    fn observe_record(
        &mut self,
        record: &Value,
        restored: bool,
        now: Instant,
        wall_now: SystemTime,
    ) {
        if record.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            return;
        }
        let Some(at) = record
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(record_time)
        else {
            return;
        };
        match record.get("type").and_then(Value::as_str) {
            Some("assistant") => self.record_calls(record, restored, at),
            Some("user")
                if record.get("turnOrigin").and_then(Value::as_str) == Some("scheduled") =>
            {
                self.release_fired_cron(record)
            }
            Some("user") => self.apply_result(record, at, now, wall_now),
            _ => {}
        }
    }

    fn record_calls(&mut self, record: &Value, restored: bool, at: SystemTime) {
        for block in content_blocks(record) {
            if block.get("type").and_then(Value::as_str) != Some("tool_use") {
                continue;
            }
            let Some(id) = block.get("id").and_then(Value::as_str) else {
                continue;
            };
            let call = match block.get("name").and_then(Value::as_str) {
                Some("ScheduleWakeup") if !restored => WakeCall::ScheduleWakeup,
                Some("CronCreate") => WakeCall::CronCreate {
                    prompt: block["input"]["prompt"]
                        .as_str()
                        .unwrap_or_default()
                        .to_owned(),
                    cron: block["input"]["cron"]
                        .as_str()
                        .unwrap_or_default()
                        .to_owned(),
                },
                Some("CronDelete") => WakeCall::CronDelete,
                _ => continue,
            };
            self.calls.insert(id.to_owned(), (call, at));
        }
    }

    fn apply_result(&mut self, record: &Value, at: SystemTime, now: Instant, wall_now: SystemTime) {
        self.calls.retain(|_, (_, called)| {
            !matches!(at.duration_since(*called), Ok(age) if age >= WAKE_CALL_TIMEOUT)
        });
        let Some(call) = content_blocks(record).find_map(|block| {
            if block.get("type").and_then(Value::as_str) != Some("tool_result") {
                return None;
            }
            self.calls
                .remove(block.get("tool_use_id").and_then(Value::as_str)?)
                .map(|(call, _)| call)
        }) else {
            return;
        };
        let Some(result) = record.get("toolUseResult") else {
            return;
        };
        match call {
            WakeCall::ScheduleWakeup => self.apply_scheduled_wakeup(result, at, now, wall_now),
            WakeCall::CronCreate { prompt, cron } => {
                if let Some(id) = result.get("id").and_then(Value::as_str) {
                    let recurring = result.get("recurring").and_then(Value::as_bool) != Some(false);
                    let lifetime_end = at + CRON_LIFETIME;
                    let until = match pinned_fire_time(&cron, at) {
                        Some(fire) if !recurring => (fire + WAKE_GRACE).min(lifetime_end),
                        _ => lifetime_end,
                    };
                    let schedule = result
                        .get("humanSchedule")
                        .and_then(Value::as_str)
                        .map_or(cron, str::to_owned);
                    let cron = Cron {
                        prompt,
                        recurring,
                        durable: result.get("durable").and_then(Value::as_bool) == Some(true),
                        until: instant_at(until, now, wall_now),
                        schedule,
                    };
                    self.track_cron(id, cron);
                }
            }
            WakeCall::CronDelete => {
                if let Some(id) = result.get("id").and_then(Value::as_str) {
                    self.crons.remove(id);
                }
            }
        }
    }

    fn apply_scheduled_wakeup(
        &mut self,
        result: &Value,
        at: SystemTime,
        now: Instant,
        wall_now: SystemTime,
    ) {
        if result.get("stopped").and_then(Value::as_bool) == Some(true) {
            self.loop_until = None;
            self.loop_next_wake = None;
        } else if let Some(millis) = result
            .get("scheduledFor")
            .and_then(Value::as_u64)
            .filter(|millis| *millis > 0)
        {
            self.extend_loop(at + LOOP_REARM_HORIZON + WAKE_GRACE, now, wall_now);
            self.loop_next_wake = Some(UNIX_EPOCH + Duration::from_millis(millis));
        }
    }

    fn extend_loop(&mut self, until: SystemTime, now: Instant, wall_now: SystemTime) {
        let until = instant_at(until, now, wall_now);
        self.loop_until = Some(self.loop_until.map_or(until, |current| current.max(until)));
    }

    fn release_fired_cron(&mut self, record: &Value) {
        let Some(prompt) = prompt_text(record) else {
            return;
        };
        let fired = self
            .crons
            .iter()
            .filter(|(_, cron)| !cron.recurring && cron.prompt == prompt)
            .min_by_key(|(_, cron)| cron.until)
            .map(|(id, _)| id.clone());
        if let Some(id) = fired {
            self.crons.remove(&id);
        }
    }

    fn track_cron(&mut self, id: &str, cron: Cron) {
        if self.crons.len() >= MAX_TRACKED_CRONS
            && let Some(oldest) = self
                .crons
                .iter()
                .min_by_key(|(_, cron)| cron.until)
                .map(|(id, _)| id.clone())
        {
            self.crons.remove(&oldest);
        }
        self.crons.insert(id.to_owned(), cron);
    }
}

fn record_time(timestamp: &str) -> Option<SystemTime> {
    let seconds = crate::time::parse_rfc3339_seconds(timestamp)?;
    Some(UNIX_EPOCH + Duration::from_secs(u64::try_from(seconds).ok()?))
}

fn pinned_fire_time(cron: &str, created: SystemTime) -> Option<SystemTime> {
    let fields: Vec<&str> = cron.split_whitespace().collect();
    let [minute, hour, day, month, "*"] = fields.as_slice() else {
        return None;
    };
    let (minute, hour, day, month): (i32, i32, i32, i32) = (
        minute.parse().ok()?,
        hour.parse().ok()?,
        day.parse().ok()?,
        month.parse().ok()?,
    );
    let created =
        libc::time_t::try_from(created.duration_since(UNIX_EPOCH).ok()?.as_secs()).ok()?;
    let mut local: libc::tm = unsafe { std::mem::zeroed() };
    if unsafe { libc::localtime_r(&created, &mut local) }.is_null() {
        return None;
    }
    [local.tm_year, local.tm_year + 1]
        .into_iter()
        .find_map(|year| {
            let mut wanted = libc::tm {
                tm_sec: 0,
                tm_min: minute,
                tm_hour: hour,
                tm_mday: day,
                tm_mon: month - 1,
                tm_year: year,
                tm_isdst: -1,
                ..unsafe { std::mem::zeroed() }
            };
            let fire = unsafe { libc::mktime(&mut wanted) };
            let exact = (wanted.tm_min, wanted.tm_hour, wanted.tm_mday, wanted.tm_mon)
                == (minute, hour, day, month - 1);
            (exact && fire >= created)
                .then(|| u64::try_from(fire).ok())
                .flatten()
                .map(|fire| UNIX_EPOCH + Duration::from_secs(fire))
        })
}

#[cfg(test)]
pub(crate) fn pinned_cron(fire: SystemTime) -> String {
    let seconds =
        libc::time_t::try_from(fire.duration_since(UNIX_EPOCH).unwrap().as_secs()).unwrap();
    let mut local: libc::tm = unsafe { std::mem::zeroed() };
    assert!(!unsafe { libc::localtime_r(&seconds, &mut local) }.is_null());
    format!(
        "{} {} {} {} *",
        local.tm_min,
        local.tm_hour,
        local.tm_mday,
        local.tm_mon + 1
    )
}

fn instant_at(wall: SystemTime, now: Instant, wall_now: SystemTime) -> Instant {
    match wall.duration_since(wall_now) {
        Ok(ahead) => now + ahead,
        Err(behind) => now.checked_sub(behind.duration()).unwrap_or(now),
    }
}

fn prompt_text(record: &Value) -> Option<String> {
    match &record["message"]["content"] {
        Value::String(text) => Some(text.clone()),
        Value::Array(blocks) => blocks
            .iter()
            .find_map(|block| block.get("text").and_then(Value::as_str))
            .map(str::to_owned),
        _ => None,
    }
}

fn content_blocks(record: &Value) -> impl Iterator<Item = &Value> {
    record
        .get("message")
        .and_then(|message| message.get("content"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use serde_json::json;

    use super::*;

    const WALL: u64 = 1_790_000_040;

    fn at(seconds: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(WALL + seconds)
    }

    fn stamp(seconds: u64) -> String {
        crate::time::rfc3339_millis((WALL + seconds) as f64)
    }

    fn tool_use(seconds: u64, id: &str, name: &str, input: Value) -> Value {
        json!({
            "type": "assistant",
            "isSidechain": false,
            "timestamp": stamp(seconds),
            "message": {"content": [{"type": "tool_use", "id": id, "name": name, "input": input}]},
        })
    }

    fn tool_result(seconds: u64, id: &str, result: Value) -> Value {
        json!({
            "type": "user",
            "isSidechain": false,
            "timestamp": stamp(seconds),
            "message": {"content": [{"type": "tool_result", "tool_use_id": id, "content": "ok"}]},
            "toolUseResult": result,
        })
    }

    fn scheduled_fire(seconds: u64, prompt: &str) -> Value {
        json!({
            "type": "user",
            "isSidechain": false,
            "isMeta": true,
            "turnOrigin": "scheduled",
            "promptSource": "system",
            "timestamp": stamp(seconds),
            "message": {"role": "user", "content": prompt},
        })
    }

    fn activity(seconds: u64) -> Value {
        json!({
            "type": "assistant",
            "isSidechain": false,
            "timestamp": stamp(seconds),
            "message": {"content": [{"type": "text", "text": "working"}]},
        })
    }

    fn cron_created(
        seconds: u64,
        call: &str,
        job: &str,
        cron: &str,
        prompt: &str,
        recurring: bool,
    ) -> [Value; 2] {
        [
            tool_use(
                seconds,
                call,
                "CronCreate",
                json!({"cron": cron, "prompt": prompt, "recurring": recurring}),
            ),
            tool_result(
                seconds,
                call,
                json!({"id": job, "humanSchedule": cron, "recurring": recurring, "durable": false}),
            ),
        ]
    }

    fn wakeup_scheduled(seconds: u64, call: &str, delay: u64) -> [Value; 2] {
        [
            tool_use(
                seconds,
                call,
                "ScheduleWakeup",
                json!({"delaySeconds": delay}),
            ),
            tool_result(
                seconds,
                call,
                json!({"scheduledFor": (WALL + seconds + delay) * 1000, "clampedDelaySeconds": delay, "wasClamped": false}),
            ),
        ]
    }

    struct Transcript {
        dir: tempfile::TempDir,
    }

    impl Transcript {
        fn new() -> Self {
            Self {
                dir: tempfile::tempdir().unwrap(),
            }
        }

        fn path(&self) -> std::path::PathBuf {
            self.dir.path().join("session.jsonl")
        }

        fn append(&self, records: &[Value]) -> u64 {
            let mut file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(self.path())
                .unwrap();
            for record in records {
                writeln!(file, "{record}").unwrap();
            }
            file.metadata().unwrap().len()
        }

        fn append_bytes(&self, bytes: &[u8]) {
            let mut file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(self.path())
                .unwrap();
            file.write_all(bytes).unwrap();
        }
    }

    fn read(hold: &mut WakeHold, transcript: &Transcript, now: Instant, seconds: u64) {
        hold.read_transcript(&transcript.path(), now, at(seconds))
            .unwrap();
    }

    #[test]
    fn an_active_loop_holds_past_its_keepalive_after_the_latest_activity_until_stopped() {
        let transcript = Transcript::new();
        let now = Instant::now();
        let mut hold = WakeHold::default();
        transcript.append(&wakeup_scheduled(0, "toolu_1", 60));
        transcript.append(&[activity(90)]);

        read(&mut hold, &transcript, now, 90);
        let horizon = now + LOOP_REARM_HORIZON + WAKE_GRACE;
        assert_eq!(hold.held_until(now), Some(horizon));
        assert_eq!(
            hold.held_until(horizon),
            None,
            "a silent loop stops holding"
        );

        transcript.append(&[
            tool_use(100, "toolu_2", "ScheduleWakeup", json!({"stop": true})),
            tool_result(
                100,
                "toolu_2",
                json!({"scheduledFor": 0, "stopped": true, "cancelledWakeups": 1}),
            ),
        ]);
        read(&mut hold, &transcript, now, 100);
        assert_eq!(hold.held_until(now), None);
    }

    #[test]
    fn crons_hold_until_deleted_fired_or_past_the_cli_lifetime() {
        let transcript = Transcript::new();
        let now = Instant::now();
        let mut hold = WakeHold::default();
        transcript.append(&cron_created(
            0,
            "toolu_1",
            "c24f0199",
            &pinned_cron(at(600)),
            "Check the build",
            false,
        ));
        transcript.append(&cron_created(
            0,
            "toolu_2",
            "a70b5579",
            "0 9 * * *",
            "Summarise the day",
            true,
        ));
        transcript.append(&cron_created(
            0,
            "toolu_3",
            "5d1e0c2a",
            "*/30 * * * *",
            "Rotate the logs",
            true,
        ));
        read(&mut hold, &transcript, now, 0);
        assert_eq!(hold.held_until(now), Some(now + CRON_LIFETIME));

        transcript.append(&[
            scheduled_fire(600, "Check the build"),
            scheduled_fire(600, "Summarise the day"),
            tool_use(700, "toolu_4", "CronDelete", json!({"id": "5d1e0c2a"})),
            tool_result(700, "toolu_4", json!({"id": "5d1e0c2a"})),
        ]);
        read(&mut hold, &transcript, now, 700);
        assert!(
            !hold.crons.contains_key("c24f0199"),
            "a fired one-shot is done"
        );
        assert!(
            hold.crons.contains_key("a70b5579"),
            "a recurring cron fires again"
        );
        assert!(
            !hold.crons.contains_key("5d1e0c2a"),
            "a deleted cron is done"
        );
        assert_eq!(hold.held_until(now + CRON_LIFETIME), None);
    }

    #[test]
    fn a_resumed_session_keeps_its_crons_but_not_its_loop() {
        let transcript = Transcript::new();
        let now = Instant::now();
        transcript.append(&wakeup_scheduled(0, "toolu_1", 600));
        let resumed_at = transcript.append(&cron_created(
            0,
            "toolu_2",
            "b067e269",
            "*/30 * * * *",
            "Rotate the logs",
            true,
        ));

        let mut hold = WakeHold::resuming(resumed_at);
        transcript.append(&[activity(30)]);
        read(&mut hold, &transcript, now, 30);
        assert_eq!(
            hold.loop_until, None,
            "the CLI does not restore a self-paced loop"
        );
        assert_eq!(
            hold.held_until(now),
            Some(now + CRON_LIFETIME - Duration::from_secs(30))
        );
    }

    #[test]
    fn a_transcript_restores_only_its_undeleted_session_crons_within_their_lifetime() {
        let records = [
            wakeup_scheduled(0, "toolu_1", 600).to_vec(),
            cron_created(0, "toolu_2", "a70b5579", "0 9 * * *", "Summarise", true).to_vec(),
            cron_created(0, "toolu_3", "5d1e0c2a", "*/30 * * * *", "Rotate", true).to_vec(),
            vec![
                tool_use(10, "toolu_4", "CronDelete", json!({"id": "5d1e0c2a"})),
                tool_result(10, "toolu_4", json!({"id": "5d1e0c2a"})),
                tool_use(
                    10,
                    "toolu_5",
                    "CronCreate",
                    json!({"cron": "0 7 * * *", "prompt": "Wake", "durable": true}),
                ),
                tool_result(
                    10,
                    "toolu_5",
                    json!({"id": "9f00d1ab", "humanSchedule": "0 7 * * *", "recurring": true, "durable": true}),
                ),
            ],
        ]
        .concat();
        let transcript: String = records.iter().map(|record| format!("{record}\n")).collect();
        let now = Instant::now();

        let restored =
            |seconds| WakeHold::restored_crons(transcript.as_bytes(), now, at(seconds)).unwrap();

        assert_eq!(restored(20), ["0 9 * * *"]);
        assert!(restored(CRON_LIFETIME.as_secs()).is_empty());
    }

    #[test]
    fn scheduled_work_lists_the_live_loop_and_crons_but_a_resume_restores_only_crons() {
        let transcript = Transcript::new();
        let now = Instant::now();
        transcript.append(&wakeup_scheduled(0, "toolu_1", 1200));
        transcript.append(&[
            tool_use(
                0,
                "toolu_2",
                "CronCreate",
                json!({"cron": "*/10 * * * *", "prompt": "Check CI", "recurring": true}),
            ),
            tool_result(
                0,
                "toolu_2",
                json!({"id": "a-named", "humanSchedule": "Every 10 minutes", "recurring": true}),
            ),
        ]);
        let resumed_at = transcript.append(&[
            tool_use(
                0,
                "toolu_3",
                "CronCreate",
                json!({"cron": "0 9 * * 1", "prompt": "Plan the week", "recurring": true}),
            ),
            tool_result(0, "toolu_3", json!({"id": "b-unnamed", "recurring": true})),
        ]);
        let crons = [
            ScheduledWork::Cron {
                schedule: "Every 10 minutes".into(),
            },
            ScheduledWork::Cron {
                schedule: "0 9 * * 1".into(),
            },
        ];

        let mut hold = WakeHold::default();
        read(&mut hold, &transcript, now, 30);
        assert_eq!(
            hold.scheduled(now, at(30))[0],
            ScheduledWork::Loop {
                next_wake: Some(at(1200))
            }
        );
        assert_eq!(hold.scheduled(now, at(30))[1..], crons);
        assert_eq!(
            hold.scheduled(now, at(1300))[0],
            ScheduledWork::Loop { next_wake: None }
        );

        let mut resumed = WakeHold::resuming(resumed_at);
        read(&mut resumed, &transcript, now, 30);
        assert_eq!(resumed.scheduled(now, at(30)), crons);
    }

    #[test]
    fn a_pinned_one_shot_holds_until_its_fire_time_and_not_once_that_has_passed() {
        let transcript = Transcript::new();
        let resumed_at = transcript.append(&cron_created(
            0,
            "toolu_1",
            "b067e269",
            &pinned_cron(at(2 * 60 * 60)),
            "Check the build",
            false,
        ));
        let now = Instant::now();

        let mut on_time = WakeHold::resuming(resumed_at);
        read(&mut on_time, &transcript, now, 60);
        assert_eq!(
            on_time.held_until(now),
            Some(now + Duration::from_secs(2 * 60 * 60 - 60) + WAKE_GRACE)
        );

        let mut past_due = WakeHold::resuming(resumed_at);
        read(&mut past_due, &transcript, now, 3 * 60 * 60);
        assert_eq!(
            past_due.held_until(now),
            None,
            "a one-shot whose time passed while the runtime was down holds nothing"
        );
    }

    #[test]
    fn a_pinned_date_early_in_the_new_year_fires_in_the_next_year() {
        let new_year_noon_utc = UNIX_EPOCH + Duration::from_secs(1_798_804_800);
        let two_days_before = new_year_noon_utc - Duration::from_secs(2 * 24 * 60 * 60);
        assert_eq!(
            pinned_fire_time(&pinned_cron(new_year_noon_utc), two_days_before),
            Some(new_year_noon_utc)
        );
    }

    #[test]
    fn a_one_shot_without_a_pinned_date_holds_for_the_cli_lifetime() {
        let transcript = Transcript::new();
        let now = Instant::now();
        let mut hold = WakeHold::default();
        transcript.append(&cron_created(
            0,
            "toolu_1",
            "c24f0199",
            "0 9 * * 1",
            "Check the build",
            false,
        ));

        read(&mut hold, &transcript, now, 0);
        assert_eq!(hold.held_until(now), Some(now + CRON_LIFETIME));
    }

    #[test]
    fn a_partial_last_line_is_read_once_it_is_complete() {
        let transcript = Transcript::new();
        let now = Instant::now();
        let mut hold = WakeHold::default();
        let [call, result] = cron_created(
            0,
            "toolu_1",
            "c24f0199",
            "0 9 * * *",
            "Check the build",
            true,
        );
        transcript.append(&[call]);
        let result = result.to_string();
        let (head, tail) = result.split_at(result.len() / 2);

        transcript.append_bytes(head.as_bytes());
        read(&mut hold, &transcript, now, 0);
        assert_eq!(hold.held_until(now), None);

        transcript.append_bytes(format!("{tail}\n").as_bytes());
        read(&mut hold, &transcript, now, 0);
        assert!(hold.held_until(now).is_some());
        assert_eq!(
            hold.offset(),
            std::fs::metadata(transcript.path()).unwrap().len()
        );
    }

    #[test]
    fn a_line_over_the_bound_is_skipped_without_losing_the_records_around_it() {
        let transcript = Transcript::new();
        let now = Instant::now();
        let mut hold = WakeHold::default();
        let [call, result] = cron_created(0, "toolu_1", "c24f0199", "0 9 * * *", "Check", true);
        transcript.append(&[call]);
        let oversized = vec![b'x'; MAX_LINE_BYTES as usize + 10];
        transcript.append_bytes(&oversized);

        read(&mut hold, &transcript, now, 0);
        assert_eq!(
            hold.offset(),
            std::fs::metadata(transcript.path()).unwrap().len() - oversized.len() as u64
        );

        transcript.append_bytes(b"\n");
        transcript.append(&[result]);
        read(&mut hold, &transcript, now, 0);
        assert!(hold.held_until(now).is_some());
        assert_eq!(
            hold.offset(),
            std::fs::metadata(transcript.path()).unwrap().len()
        );
    }

    #[test]
    fn other_tools_and_subagent_records_do_not_hold() {
        let transcript = Transcript::new();
        let now = Instant::now();
        let mut hold = WakeHold::default();
        let wake = json!({"scheduledFor": (WALL + 600) * 1000});
        let mut nested = wakeup_scheduled(0, "toolu_2", 600);
        for record in &mut nested {
            record["isSidechain"] = json!(true);
        }
        transcript.append(&[
            tool_use(0, "toolu_1", "Bash", json!({"command": "true"})),
            tool_result(0, "toolu_1", wake),
        ]);
        read(&mut hold, &transcript, now, 0);
        assert_eq!(hold.held_until(now), None);
        transcript.append(&nested);

        read(&mut hold, &transcript, now, 0);
        assert_eq!(hold.held_until(now), None);
    }
}
