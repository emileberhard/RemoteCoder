use std::collections::VecDeque;

use serde_json::{Value, json};

// Reconnect replay: keep a bounded in-memory history of app-server notifications so clients can
// recover ordered turn activity after backgrounding, force-quit, or brief network loss.
const NOTIFICATION_HISTORY_MAX_SIZE: usize = 20_000;
const NOTIFICATION_HISTORY_MAX_BYTES: usize = 16 * 1024 * 1024;
pub(crate) const NOTIFICATION_HISTORY_TTL_SECONDS: f64 = 2.0 * 60.0 * 60.0;
const NOTIFICATION_REPLAY_MAX_BYTES: usize = 8 * 1024 * 1024;
const NOTIFICATION_PAIRING_WINDOW_SECONDS: f64 = 5.0;
const NOTIFICATION_PAIRING_LOOKBACK: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NotificationOrigin {
    Client { id: u64, opened_after: u64 },
    Control { opened_after: u64 },
    Observer { opened_after: u64 },
    Provider,
    Gateway,
}

impl NotificationOrigin {
    fn opened_after(self) -> u64 {
        match self {
            Self::Client { opened_after, .. }
            | Self::Control { opened_after }
            | Self::Observer { opened_after } => opened_after,
            Self::Provider | Self::Gateway => 0,
        }
    }
}

#[derive(Debug, Clone)]
struct HistoryEntry {
    sequence: u64,
    timestamp_unix_seconds: f64,
    thread_id: Option<String>,
    turn_started: Option<String>,
    raw_json: String,
    origins: Vec<NotificationOrigin>,
}

fn started_turn_id(raw: &str) -> Option<String> {
    if !raw.contains("\"turn/started\"") {
        return None;
    }
    let message = serde_json::from_str::<Value>(raw).ok()?;
    if message.get("method")? != "turn/started" {
        return None;
    }
    message["params"]["turn"]["id"].as_str().map(str::to_owned)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Recorded {
    pub sequence: u64,
    pub is_new: bool,
}

#[derive(Debug)]
pub(crate) struct NotificationHistory {
    entries: VecDeque<HistoryEntry>,
    bytes: usize,
    latest_sequence: u64,
    epoch: String,
}

impl Default for NotificationHistory {
    fn default() -> Self {
        Self {
            entries: VecDeque::new(),
            bytes: 0,
            latest_sequence: 0,
            epoch: crate::ids::new_session_uuid(),
        }
    }
}

impl NotificationHistory {
    pub(crate) fn epoch(&self) -> &str {
        &self.epoch
    }

    pub(crate) fn latest_sequence(&self) -> u64 {
        self.latest_sequence
    }

    pub(crate) fn turn_started_sequence(&self, thread_id: &str, turn_id: &str) -> Option<u64> {
        self.entries
            .iter()
            .rev()
            .find(|entry| {
                entry.turn_started.as_deref() == Some(turn_id)
                    && entry.thread_id.as_deref() == Some(thread_id)
            })
            .map(|entry| entry.sequence)
    }

    pub(crate) fn record(
        &mut self,
        raw: &str,
        thread_id: Option<String>,
        origin: NotificationOrigin,
        now: f64,
    ) -> Recorded {
        if raw.len() > NOTIFICATION_HISTORY_MAX_BYTES {
            return self.record_unretained();
        }
        let recent = self
            .entries
            .len()
            .saturating_sub(NOTIFICATION_PAIRING_LOOKBACK);
        let after_own_copy = self
            .entries
            .range(recent..)
            .rposition(|entry| entry.thread_id == thread_id && entry.origins.contains(&origin))
            .map_or(recent, |index| recent + index + 1);
        if let Some(entry) = self.entries.range_mut(after_own_copy..).find(|entry| {
            entry.sequence > origin.opened_after()
                && entry.timestamp_unix_seconds >= now - NOTIFICATION_PAIRING_WINDOW_SECONDS
                && entry.thread_id == thread_id
                && entry.raw_json == raw
        }) {
            entry.origins.push(origin);
            return Recorded {
                sequence: entry.sequence,
                is_new: false,
            };
        }
        self.latest_sequence = self.latest_sequence.saturating_add(1);
        let sequence = self.latest_sequence;
        self.entries.push_back(HistoryEntry {
            sequence,
            timestamp_unix_seconds: now,
            thread_id,
            turn_started: started_turn_id(raw),
            raw_json: raw.to_string(),
            origins: vec![origin],
        });
        self.bytes = self.bytes.saturating_add(raw.len());
        while self.entries.len() > NOTIFICATION_HISTORY_MAX_SIZE
            || self.bytes > NOTIFICATION_HISTORY_MAX_BYTES
        {
            self.drop_oldest();
        }
        self.prune_expired(now);
        Recorded {
            sequence,
            is_new: true,
        }
    }

    pub(crate) fn record_unretained(&mut self) -> Recorded {
        self.latest_sequence = self.latest_sequence.saturating_add(1);
        self.entries.clear();
        self.bytes = 0;
        Recorded {
            sequence: self.latest_sequence,
            is_new: true,
        }
    }

    pub(crate) fn replay(&mut self, request: &ReplayRequest, now: f64) -> ReplayPage {
        self.prune_expired(now);
        let oldest = self
            .entries
            .front()
            .map(|entry| (entry.sequence, entry.timestamp_unix_seconds));
        let epoch_changed = request
            .epoch
            .as_deref()
            .is_some_and(|requested| requested != self.epoch);
        let after_sequence = if epoch_changed {
            0
        } else {
            request.after_sequence
        };
        let evicted_before = epoch_changed
            || match oldest {
                Some((sequence, timestamp)) => {
                    after_sequence.saturating_add(1) < sequence
                        && timestamp > request.since_unix_seconds
                }
                None => after_sequence < self.latest_sequence,
            };
        let mut through_sequence = after_sequence;
        let mut entries = Vec::new();
        let mut skipped = Vec::new();
        let mut has_more = false;
        let mut selected_bytes = 0usize;
        for entry in &self.entries {
            if entry.sequence <= after_sequence {
                continue;
            }
            if entry.timestamp_unix_seconds < request.since_unix_seconds
                || request
                    .thread_id
                    .as_deref()
                    .is_some_and(|thread_id| entry.thread_id.as_deref() != Some(thread_id))
            {
                through_sequence = entry.sequence;
                continue;
            }
            if entry.raw_json.len() > NOTIFICATION_REPLAY_MAX_BYTES {
                skipped.push(SkippedNotification {
                    sequence: entry.sequence,
                    thread_id: entry.thread_id.clone(),
                });
                through_sequence = entry.sequence;
                continue;
            }
            if entries.len() >= request.limit
                || selected_bytes.saturating_add(entry.raw_json.len())
                    > NOTIFICATION_REPLAY_MAX_BYTES
            {
                has_more = true;
                break;
            }
            selected_bytes = selected_bytes.saturating_add(entry.raw_json.len());
            entries.push(entry.clone());
            through_sequence = entry.sequence;
        }
        if !has_more {
            through_sequence = self.latest_sequence.max(through_sequence);
        }
        ReplayPage {
            epoch: self.epoch.clone(),
            through_sequence,
            has_more,
            evicted_before,
            skipped,
            oldest_sequence: oldest.map(|(sequence, _)| sequence),
            latest_sequence: self.latest_sequence,
            entries,
        }
    }

    fn prune_expired(&mut self, now: f64) {
        let cutoff = now - NOTIFICATION_HISTORY_TTL_SECONDS;
        while self
            .entries
            .front()
            .is_some_and(|entry| entry.timestamp_unix_seconds < cutoff)
        {
            self.drop_oldest();
        }
    }

    fn drop_oldest(&mut self) {
        if let Some(entry) = self.entries.pop_front() {
            self.bytes = self.bytes.saturating_sub(entry.raw_json.len());
        }
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.entries.len()
    }

    #[cfg(test)]
    pub(crate) fn age_for_test(&mut self, index: usize, seconds: f64) {
        self.entries[index].timestamp_unix_seconds -= seconds;
    }

    #[cfg(test)]
    pub(crate) fn timestamp_for_test(&self, index: usize) -> f64 {
        self.entries[index].timestamp_unix_seconds
    }

    #[cfg(test)]
    pub(crate) fn origins_for_test(&self, index: usize) -> &[NotificationOrigin] {
        &self.entries[index].origins
    }
}

#[derive(Debug)]
pub(crate) struct ReplayRequest {
    since_unix_seconds: f64,
    after_sequence: u64,
    epoch: Option<String>,
    thread_id: Option<String>,
    limit: usize,
}

impl ReplayRequest {
    pub(crate) fn from_params(params: Option<&Value>) -> Self {
        let param = |name: &str| params.and_then(|params| params.get(name));
        Self {
            since_unix_seconds: param("sinceUnixSeconds")
                .and_then(Value::as_f64)
                .unwrap_or(0.0),
            after_sequence: param("afterSequence").and_then(Value::as_u64).unwrap_or(0),
            epoch: param("epoch").and_then(Value::as_str).map(str::to_owned),
            thread_id: param("threadId")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|thread_id| !thread_id.is_empty())
                .map(str::to_owned),
            limit: param("limit")
                .and_then(Value::as_u64)
                .and_then(|value| usize::try_from(value).ok())
                .filter(|value| *value > 0)
                .unwrap_or(NOTIFICATION_HISTORY_MAX_SIZE)
                .min(NOTIFICATION_HISTORY_MAX_SIZE),
        }
    }
}

#[derive(Debug)]
struct SkippedNotification {
    sequence: u64,
    thread_id: Option<String>,
}

impl SkippedNotification {
    fn to_wire(&self) -> Value {
        json!({"sequence": self.sequence, "threadId": self.thread_id})
    }
}

#[derive(Debug)]
pub(crate) struct ReplayPage {
    epoch: String,
    through_sequence: u64,
    has_more: bool,
    evicted_before: bool,
    skipped: Vec<SkippedNotification>,
    oldest_sequence: Option<u64>,
    latest_sequence: u64,
    entries: Vec<HistoryEntry>,
}

impl ReplayPage {
    pub(crate) fn into_wire(self, generated_at_unix_seconds: f64) -> Value {
        let mut skipped = self.skipped;
        let mut notifications = Vec::with_capacity(self.entries.len());
        for entry in self.entries {
            match serde_json::from_str::<Value>(&entry.raw_json) {
                Ok(message) => notifications.push(json!({
                    "sequence": entry.sequence,
                    "timestampUnixSeconds": entry.timestamp_unix_seconds,
                    "message": message,
                })),
                Err(_) => skipped.push(SkippedNotification {
                    sequence: entry.sequence,
                    thread_id: entry.thread_id,
                }),
            }
        }
        skipped.sort_by_key(|entry| entry.sequence);
        json!({
            "generatedAtUnixSeconds": generated_at_unix_seconds,
            "epoch": self.epoch,
            "throughSequence": self.through_sequence,
            "hasMore": self.has_more,
            "evictedBefore": self.evicted_before,
            "skipped": skipped.iter().map(SkippedNotification::to_wire).collect::<Vec<_>>(),
            "oldestSequence": self.oldest_sequence,
            "latestSequence": self.latest_sequence,
            "gapBefore": self.evicted_before,
            "notifications": notifications,
        })
    }
}
