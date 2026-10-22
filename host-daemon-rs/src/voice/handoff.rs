//! Voice delegation routing between the realtime voice model and the external
//! (Claude) executor.
//!
//! Mirrors the upstream Codex desktop semantics: at most one active delegation,
//! newest-wins supersession when the user speaks again mid-task, and exactly
//! one authoritative completion per executor turn. Intermediate executor
//! messages are commentary appends, never completions — the Claude contract is
//! that the next CLI `result` is authoritative for the whole turn, so the
//! handoff that is newest when the turn ends receives the final text.

/// Seconds of commentary silence during a running turn before the gateway
/// synthesizes a progress append from the latest tool activity.
const WATCHDOG_QUIET_SECONDS: f64 = 45.0;

const APPEND_FLUSH_INTERVAL_SECONDS: f64 = 0.2;
const MAX_PENDING_TEXT_BYTES: usize = 8 * 1024;
const MAX_RESULT_TEXT_BYTES: usize = 32 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TranscriptEntry {
    pub role: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum VoiceOutputTarget {
    Handoff(String),
    Conversation,
}

impl VoiceOutputTarget {
    pub(crate) fn handoff_id(&self) -> Option<&str> {
        match self {
            Self::Handoff(id) => Some(id),
            Self::Conversation => None,
        }
    }
}

#[derive(Debug, Clone)]
enum VoiceTurnBinding {
    Dispatching,
    Queued,
    Consumed(String),
}

impl VoiceTurnBinding {
    fn turn_id(&self) -> Option<&str> {
        match self {
            Self::Consumed(id) => Some(id),
            Self::Dispatching | Self::Queued => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BoundTurn {
    target: VoiceOutputTarget,
    turn_id: String,
}

impl BoundTurn {
    pub(crate) fn turn_id(&self) -> &str {
        &self.turn_id
    }
}

#[derive(Debug, Clone)]
struct ActiveVoiceTurn {
    target: VoiceOutputTarget,
    input_id: Option<String>,
    binding: VoiceTurnBinding,
    pending_text: String,
    accumulated_text: String,
    candidate_final_text: Option<String>,
    result_too_long: bool,
    message_received: bool,
    last_flush_at: f64,
    requested_at: f64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct VoiceAppend {
    pub target: VoiceOutputTarget,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct VoiceCompletion {
    pub target: VoiceOutputTarget,
    pub text: String,
    pub latency_seconds_x1000: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BeginOutcome {
    /// Delegation silently retired because a newer one replaced it. The
    /// realtime service tolerates delegations that never receive output; the
    /// desktop client relies on the same behavior.
    pub superseded_handoff_id: Option<String>,
    pub inherited_turn_id: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct VoiceDelegations {
    active: Option<ActiveVoiceTurn>,
    transcript_cursor: usize,
    last_append_at: f64,
    last_tool_label: Option<String>,
    quiet_reported: bool,
    pub requested_count: u64,
    pub superseded_count: u64,
    pub completed_count: u64,
    pub failed_count: u64,
    pub synthesized_append_count: u64,
}

impl VoiceDelegations {
    pub fn new() -> Self {
        Self::default()
    }

    pub(crate) fn bound_turn(&self) -> Option<BoundTurn> {
        let active = self.active.as_ref()?;
        Some(BoundTurn {
            target: active.target.clone(),
            turn_id: active.binding.turn_id()?.to_string(),
        })
    }

    /// Fails a delegation whose bound turn no longer exists on the executor —
    /// its `turn/completed` can never match (for example the turn ended before
    /// binding), so without this the delegation would sit forever while the
    /// watchdog narrates "Still working" into the void. Does nothing unless
    /// the active delegation is still exactly the one the caller observed
    /// missing.
    pub(crate) fn fail_missing_turn(
        &mut self,
        expected: &BoundTurn,
        now: f64,
    ) -> Option<VoiceCompletion> {
        if self.bound_turn().as_ref() != Some(expected) {
            return None;
        }
        self.complete_turn(&expected.turn_id, "unknown", None, now)
    }

    /// Registers a new delegation, replacing (not completing) any pending one.
    pub(crate) fn begin(&mut self, handoff_id: &str, input_id: &str, now: f64) -> BeginOutcome {
        self.requested_count += 1;
        self.quiet_reported = false;
        let previous = self.active.take();
        let superseded_handoff_id = previous
            .as_ref()
            .and_then(|old| old.target.handoff_id().map(str::to_string));
        if superseded_handoff_id.is_some() {
            self.superseded_count += 1;
        }
        let inherited_turn_id = previous.and_then(|old| old.binding.turn_id().map(str::to_string));
        self.active = Some(ActiveVoiceTurn {
            target: VoiceOutputTarget::Handoff(handoff_id.to_string()),
            input_id: Some(input_id.to_string()),
            binding: VoiceTurnBinding::Dispatching,
            pending_text: String::new(),
            accumulated_text: String::new(),
            candidate_final_text: None,
            result_too_long: false,
            message_received: false,
            last_flush_at: 0.0,
            requested_at: now,
        });
        BeginOutcome {
            superseded_handoff_id,
            inherited_turn_id,
        }
    }

    pub(crate) fn observe_turn(&mut self, turn_id: &str, now: f64) {
        if let Some(active) = self.active.as_mut() {
            if matches!(active.target, VoiceOutputTarget::Handoff(_)) {
                // Only the provider's replay of this exact input identifies
                // the turn that consumed it. A preceding turn can end while
                // the utterance is still queued in Claude's stdin.
                return;
            }
            if active.binding.turn_id() == Some(turn_id) {
                return;
            }
        }
        self.active = Some(ActiveVoiceTurn {
            target: VoiceOutputTarget::Conversation,
            input_id: None,
            binding: VoiceTurnBinding::Consumed(turn_id.to_string()),
            pending_text: String::new(),
            accumulated_text: String::new(),
            candidate_final_text: None,
            result_too_long: false,
            message_received: false,
            last_flush_at: 0.0,
            requested_at: now,
        });
        self.quiet_reported = false;
        self.last_tool_label = None;
        self.last_append_at = now;
    }

    pub(crate) fn bind_input(&mut self, input_id: &str, turn_id: &str) -> bool {
        if let Some(active) = self
            .active
            .as_mut()
            .filter(|active| active.input_id.as_deref() == Some(input_id))
        {
            active.binding = VoiceTurnBinding::Consumed(turn_id.to_string());
            return true;
        }
        false
    }

    pub(crate) fn note_dispatched(&mut self, handoff_id: &str) {
        if let Some(active) = self
            .active
            .as_mut()
            .filter(|active| active.target.handoff_id() == Some(handoff_id))
            && matches!(active.binding, VoiceTurnBinding::Dispatching)
        {
            active.binding = VoiceTurnBinding::Queued;
        }
    }

    pub(crate) fn unconsumed_handoff_id(&self) -> Option<&str> {
        let active = self.active.as_ref()?;
        matches!(active.binding, VoiceTurnBinding::Queued)
            .then(|| active.target.handoff_id())
            .flatten()
    }

    /// Drops a delegation that failed to start. Returns whether it was active.
    pub(crate) fn remove(&mut self, handoff_id: &str) -> bool {
        if self
            .active
            .as_ref()
            .is_some_and(|active| active.target.handoff_id() == Some(handoff_id))
        {
            self.active = None;
            self.failed_count += 1;
            return true;
        }
        false
    }

    /// Like `remove`, but only while the provider has not yet consumed the
    /// input, so a delegation that bound a turn since it was observed stays.
    pub(crate) fn remove_unconsumed(&mut self, handoff_id: &str) -> bool {
        self.active
            .as_ref()
            .is_some_and(|active| active.binding.turn_id().is_none())
            && self.remove(handoff_id)
    }

    /// Marks the successful dispatch as the commentary baseline.
    pub(crate) fn mark_started(&mut self, handoff_id: &str, now: f64) {
        if self
            .active
            .as_ref()
            .is_some_and(|active| active.target.handoff_id() == Some(handoff_id))
        {
            self.last_append_at = now;
            self.quiet_reported = false;
        }
    }

    pub(crate) fn append_delta(
        &mut self,
        turn_id: &str,
        delta: &str,
        now: f64,
    ) -> Option<VoiceAppend> {
        let active = self.active.as_mut()?;
        if active.binding.turn_id() != Some(turn_id) {
            return None;
        }
        if !push_bounded(&mut active.accumulated_text, delta, MAX_RESULT_TEXT_BYTES) {
            active.result_too_long = true;
        }
        if active.target == VoiceOutputTarget::Conversation {
            return None;
        }
        active.pending_text.push_str(delta);
        if active.pending_text.len() < MAX_PENDING_TEXT_BYTES
            && active.last_flush_at != 0.0
            && now - active.last_flush_at < APPEND_FLUSH_INTERVAL_SECONDS
        {
            return None;
        }
        active.last_flush_at = now;
        self.last_append_at = now;
        self.quiet_reported = false;
        Some(VoiceAppend {
            target: active.target.clone(),
            text: std::mem::take(&mut active.pending_text),
        })
    }

    /// Records a completed executor message as the completion candidate and
    /// flushes any unflushed tail as commentary. Never completes the handoff:
    /// mid-turn status messages must not retire the delegation.
    pub(crate) fn note_agent_message(
        &mut self,
        turn_id: &str,
        text: &str,
        now: f64,
    ) -> Option<VoiceAppend> {
        let active = self.active.as_mut()?;
        if active.binding.turn_id() != Some(turn_id) {
            return None;
        }
        if !text.trim().is_empty() {
            let text = text.trim();
            active.message_received = true;
            active.result_too_long = text.len() > MAX_RESULT_TEXT_BYTES;
            active.candidate_final_text = (!active.result_too_long).then(|| text.to_string());
        }
        if active.target == VoiceOutputTarget::Conversation {
            active.pending_text.clear();
            self.last_append_at = now;
            self.quiet_reported = false;
            return (!text.trim().is_empty()).then(|| VoiceAppend {
                target: VoiceOutputTarget::Conversation,
                text: text.to_string(),
            });
        }
        if active.pending_text.is_empty() {
            return None;
        }
        active.last_flush_at = now;
        self.last_append_at = now;
        self.quiet_reported = false;
        Some(VoiceAppend {
            target: active.target.clone(),
            text: std::mem::take(&mut active.pending_text),
        })
    }

    /// Records tool activity for synthesized progress commentary.
    pub(crate) fn note_tool_activity(&mut self, turn_id: &str, label: String) {
        let Some(active) = self.active.as_mut() else {
            return;
        };
        if active.binding.turn_id() != Some(turn_id) {
            return;
        }
        self.last_tool_label = Some(label);
    }

    /// The single authoritative completion for a finished executor turn.
    pub(crate) fn complete_turn(
        &mut self,
        turn_id: &str,
        status: &str,
        error_message: Option<&str>,
        now: f64,
    ) -> Option<VoiceCompletion> {
        let matches = self
            .active
            .as_ref()
            .is_some_and(|active| active.binding.turn_id() == Some(turn_id));
        if !matches {
            return None;
        }
        let active = self.active.take()?;
        self.last_tool_label = None;
        if matches!(active.target, VoiceOutputTarget::Handoff(_)) {
            if matches!(status, "failed" | "unknown") {
                self.failed_count += 1;
            } else {
                self.completed_count += 1;
            }
        } else if status == "completed" && active.message_received {
            // A passive listener already received each complete assistant message.
            return None;
        }

        let text = match status {
            "failed" => {
                let detail = error_message
                    .map(|message| truncate_chars(message, 200))
                    .filter(|message| !message.is_empty())
                    .map(|message| format!(" ({message})"))
                    .unwrap_or_default();
                format!("The task hit an error before finishing{detail} — details are in the chat.")
            }
            "interrupted" => "The task was interrupted before finishing.".to_string(),
            "unknown" => "The task ended without reporting its outcome — see the chat.".to_string(),
            _ => active
                .candidate_final_text
                .clone()
                .or_else(|| {
                    let accumulated = active.accumulated_text.trim();
                    (!active.result_too_long && !accumulated.is_empty())
                        .then(|| accumulated.to_string())
                })
                .unwrap_or_else(|| {
                    if active.result_too_long {
                        "The task's result is too long to read aloud — see the chat.".to_string()
                    } else {
                        "The task finished without a spoken result — see the chat.".to_string()
                    }
                }),
        };
        Some(VoiceCompletion {
            target: active.target,
            text,
            latency_seconds_x1000: ((now - active.requested_at) * 1000.0) as i64,
        })
    }

    /// Synthesized progress commentary when the executor has been silent too
    /// long during a running turn. Called from the gateway's periodic tick.
    pub(crate) fn watchdog_append(&mut self, now: f64) -> Option<VoiceAppend> {
        let active = self.active.as_ref()?;
        if self.quiet_reported
            || active.binding.turn_id().is_none()
            || now - self.last_append_at.max(active.requested_at) < WATCHDOG_QUIET_SECONDS
        {
            return None;
        }
        let text = match self.last_tool_label.as_deref() {
            Some(label) => format!("The task is still active. Last reported activity: {label}."),
            None => {
                "The task is still active, but there is no new progress report yet.".to_string()
            }
        };
        self.last_append_at = now;
        self.synthesized_append_count += 1;
        self.quiet_reported = true;
        Some(VoiceAppend {
            target: active.target.clone(),
            text,
        })
    }

    /// Slices the entries this session has not yet delivered to the executor.
    /// `activeTranscript` grows monotonically within a realtime session; a
    /// shrinking array means an upstream reset, so deliver everything again.
    pub(crate) fn take_transcript_delta(
        &mut self,
        entries: &[TranscriptEntry],
    ) -> Vec<TranscriptEntry> {
        // An empty snapshot means the client omitted the transcript, not that
        // the call restarted; keep the cursor so nothing is re-delivered later.
        if entries.is_empty() {
            return Vec::new();
        }
        if entries.len() < self.transcript_cursor {
            self.transcript_cursor = 0;
        }
        let delta = entries[self.transcript_cursor..].to_vec();
        self.transcript_cursor = entries.len();
        delta
    }
}

/// Compact label for synthesized progress commentary from a translated tool
/// item (`item/started` / `item/completed` payloads).
pub(crate) fn tool_activity_label(item: &serde_json::Value) -> Option<String> {
    let get = |key: &str| item.get(key).and_then(serde_json::Value::as_str);
    match get("type")? {
        "commandExecution" => {
            let command = get("command").unwrap_or_default();
            (!command.is_empty()).then(|| format!("command {}", truncate_chars(command, 60)))
        }
        "fileChange" => {
            let path = item
                .get("changes")
                .and_then(serde_json::Value::as_array)
                .and_then(|changes| changes.first())
                .and_then(|change| change.get("path"))
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default();
            let name = path.rsplit('/').next().unwrap_or(path);
            (!name.is_empty()).then(|| format!("editing {name}"))
        }
        "webSearch" => {
            let query = get("query").unwrap_or_default();
            (!query.is_empty())
                .then(|| format!("searching the web for \"{}\"", truncate_chars(query, 60)))
        }
        "mcpToolCall" => {
            let server = get("server").unwrap_or_default();
            let tool = get("tool").unwrap_or_default();
            (!tool.is_empty()).then(|| format!("using {server} {tool}"))
        }
        "dynamicToolCall" => {
            let tool = get("tool").unwrap_or_default();
            (!tool.is_empty()).then(|| format!("using {tool}"))
        }
        _ => None,
    }
}

/// Wraps a spoken delegation for the executor, mirroring the desktop client's
/// `<realtime_delegation>` envelope. `transcript_delta` is what the voice
/// model and user said since the previous delegation.
pub(crate) fn delegation_envelope(input: &str, transcript_delta: &[TranscriptEntry]) -> String {
    let mut envelope = format!(
        "<realtime_delegation>\n  <input>{}</input>\n",
        escape_xml(input)
    );
    if !transcript_delta.is_empty() {
        envelope.push_str("  <transcript_delta>");
        for entry in transcript_delta {
            envelope.push_str(&format!(
                "{}: {}\n",
                escape_xml(&entry.role),
                escape_xml(&entry.text)
            ));
        }
        envelope.push_str("</transcript_delta>\n");
    }
    envelope.push_str("</realtime_delegation>");
    envelope
}

pub(crate) fn envelope_with_call_context(envelope: &str, context: &str) -> Option<String> {
    envelope.strip_prefix("<realtime_delegation>")?;
    let body = envelope.strip_suffix("</realtime_delegation>")?;
    Some(format!(
        "{body}  <call_context>{}</call_context>\n</realtime_delegation>",
        escape_xml(context)
    ))
}

fn escape_xml(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

pub(crate) fn transcript_tail_envelope(text: &str) -> Option<&str> {
    let text = text.trim();
    if !text.starts_with("<realtime_delegation>") || !text.ends_with("</realtime_delegation>") {
        return None;
    }
    let body = text
        .strip_prefix("<realtime_delegation>")?
        .strip_suffix("</realtime_delegation>")?;
    if !body
        .trim_start()
        .starts_with("<source>transcript_tail_flush</source>")
        || body.contains("<realtime_delegation>")
        || body.contains("</realtime_delegation>")
    {
        return None;
    }
    Some(text)
}

/// Extracts the spoken input from a delegation envelope for display, so chat
/// transcripts show what the user said. Synthetic tail flushes are classified
/// by dispatch metadata; authored or ambiguous nested envelopes stay intact.
pub(crate) fn delegation_display_text(text: &str) -> Option<String> {
    let trimmed = text.trim();
    if !trimmed.starts_with("<realtime_delegation>") || !trimmed.ends_with("</realtime_delegation>")
    {
        return None;
    }
    if transcript_tail_envelope(trimmed).is_some()
        || trimmed["<realtime_delegation>".len()..].contains("<realtime_delegation>")
    {
        return None;
    }
    // rfind: the transcript delta may itself quote the literal tag text.
    let start = trimmed.rfind("<input>")? + "<input>".len();
    let end = trimmed.rfind("</input>")?;
    if end < start {
        return None;
    }
    let inner = trimmed[start..end].trim();
    if inner.is_empty() {
        return None;
    }
    // Earlier gateway recordings used unescaped text and no canonical indentation.
    Some(if trimmed.starts_with("<realtime_delegation>\n  <input>") {
        inner
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&amp;", "&")
    } else {
        inner.to_string()
    })
}

fn push_bounded(buffer: &mut String, text: &str, max_bytes: usize) -> bool {
    let room = max_bytes.saturating_sub(buffer.len());
    if text.len() <= room {
        buffer.push_str(text);
        return true;
    }
    let mut end = room;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    buffer.push_str(&text[..end]);
    false
}

fn truncate_chars(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    let truncated: String = text.chars().take(max_chars).collect();
    format!("{truncated}…")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entries(pairs: &[(&str, &str)]) -> Vec<TranscriptEntry> {
        pairs
            .iter()
            .map(|(role, text)| TranscriptEntry {
                role: role.to_string(),
                text: text.to_string(),
            })
            .collect()
    }

    #[test]
    fn joining_an_active_turn_routes_complete_messages_without_a_new_request() {
        let mut state = VoiceDelegations::new();
        state.observe_turn("running-turn", 10.0);
        assert!(
            state
                .append_delta("running-turn", "The clips are transcribed.", 11.0)
                .is_none()
        );
        let update = state
            .note_agent_message("running-turn", "The clips are transcribed.", 12.0)
            .expect("passive update");
        assert_eq!(update.target, VoiceOutputTarget::Conversation);
        assert_eq!(update.text, "The clips are transcribed.");
        state.note_agent_message("running-turn", "Finished the website changes.", 13.0);
        assert!(
            state
                .complete_turn("running-turn", "completed", None, 14.0)
                .is_none(),
            "do not speak the final answer twice"
        );
        assert!(state.bound_turn().is_none());
        assert!(state.watchdog_append(100.0).is_none());
        assert_eq!(state.requested_count, 0);
    }

    #[test]
    fn speaking_after_joining_binds_the_existing_turn_and_keeps_one_completion() {
        let mut state = VoiceDelegations::new();
        state.observe_turn("running-turn", 1.0);
        let started = state.begin("spoken-request", "spoken-request", 2.0);
        assert_eq!(started.inherited_turn_id.as_deref(), Some("running-turn"));
        assert!(started.superseded_handoff_id.is_none());
        state.observe_turn("running-turn", 3.0);
        state.bind_input("spoken-request", "running-turn");
        let update = state
            .append_delta("running-turn", "The transcripts are ready.", 4.0)
            .expect("handoff update");
        assert_eq!(update.target.handoff_id(), Some("spoken-request"));
        let completion = state
            .complete_turn("running-turn", "completed", None, 5.0)
            .expect("handoff completion");
        assert_eq!(completion.target.handoff_id(), Some("spoken-request"));
        assert_eq!(state.completed_count, 1);
        assert!(
            state
                .complete_turn("running-turn", "completed", None, 6.0)
                .is_none()
        );
    }

    /// Four delegations steer one turn, followed by a status message and the
    /// real answer. The newest delegation must receive the answer and nothing
    /// may fabricate a failure.
    #[test]
    fn turn_17_regression_answer_lands_on_the_newest_delegation() {
        let mut state = VoiceDelegations::new();

        // The first request starts the turn.
        let first = state.begin("request-1", "request-1", 0.0);
        assert_eq!(first.superseded_handoff_id, None);
        state.bind_input("request-1", "turn-17");
        // Follow-up requests steer the same turn.
        let second = state.begin("request-2", "request-2", 85.0);
        assert_eq!(second.superseded_handoff_id.as_deref(), Some("request-1"));
        assert_eq!(second.inherited_turn_id.as_deref(), Some("turn-17"));
        state.bind_input("request-2", "turn-17");
        // A status message arrives mid-turn.
        let status_append = state.append_delta("turn-17", "Working on the example.", 94.0);
        assert_eq!(
            status_append.and_then(|append| append.target.handoff_id().map(str::to_string)),
            Some("request-2".to_string())
        );
        assert!(
            state
                .note_agent_message("turn-17", "Working on the example.", 94.1)
                .is_none()
        );
        state.begin("request-3", "request-3", 109.0);
        state.bind_input("request-3", "turn-17");
        state.begin("request-4", "request-4", 198.0);
        state.bind_input("request-4", "turn-17");

        // The answer streams and the turn completes.
        let answer_append =
            state.append_delta("turn-17", "The example account is signed out.", 211.0);
        assert_eq!(
            answer_append.and_then(|append| append.target.handoff_id().map(str::to_string)),
            Some("request-4".to_string())
        );
        assert!(
            state
                .note_agent_message("turn-17", "The example account is signed out.", 211.5)
                .is_none()
        );
        let completion = state
            .complete_turn("turn-17", "completed", None, 217.0)
            .expect("single completion at turn end");
        assert_eq!(completion.target.handoff_id(), Some("request-4"));
        assert_eq!(completion.text, "The example account is signed out.");
        assert!(!completion.text.contains("task ended"));

        // Nothing left to drain, nothing to fabricate.
        assert!(
            state
                .complete_turn("turn-17", "completed", None, 218.0)
                .is_none()
        );
        assert_eq!(state.completed_count, 1);
        assert_eq!(state.superseded_count, 3);
    }

    #[test]
    fn output_cannot_bind_a_handoff_before_the_exact_input_is_consumed() {
        let mut state = VoiceDelegations::new();
        state.begin("handoff-1", "handoff-1", 1.0);

        state.observe_turn("preceding-turn", 1.1);
        assert!(
            state
                .append_delta("preceding-turn", "old progress", 1.2)
                .is_none()
        );
        assert!(
            state
                .complete_turn("preceding-turn", "completed", None, 1.3)
                .is_none()
        );
        state.observe_turn("turn-arrived-first", 1.4);
        assert!(!state.bind_input("unrelated-input", "turn-arrived-first"));
        assert!(state.bind_input("handoff-1", "turn-arrived-first"));
        let append = state
            .append_delta("turn-arrived-first", "hello", 2.0)
            .expect("consumed input binds the turn");
        assert_eq!(append.target.handoff_id(), Some("handoff-1"));
        let completion = state
            .complete_turn("turn-arrived-first", "completed", None, 3.0)
            .expect("bound turn completes");
        assert_eq!(completion.text, "hello");
    }

    #[test]
    fn stale_turn_notifications_are_ignored() {
        let mut state = VoiceDelegations::new();
        state.begin("handoff-1", "handoff-1", 1.0);
        state.bind_input("handoff-1", "turn-current");

        assert!(state.append_delta("turn-stale", "wrong", 2.0).is_none());
        assert!(
            state
                .note_agent_message("turn-stale", "wrong", 2.0)
                .is_none()
        );
        assert!(
            state
                .complete_turn("turn-stale", "completed", None, 3.0)
                .is_none()
        );
        assert_eq!(
            state
                .append_delta("turn-current", "current", 4.0)
                .unwrap()
                .target
                .handoff_id(),
            Some("handoff-1")
        );
    }

    #[test]
    fn failed_turn_without_text_completes_with_error_framing() {
        let mut state = VoiceDelegations::new();
        state.begin("handoff-1", "handoff-1", 1.0);
        state.bind_input("handoff-1", "turn-1");

        let completion = state
            .complete_turn("turn-1", "failed", Some("billing guard: api key"), 5.0)
            .expect("failed completion");
        assert!(completion.text.contains("hit an error"));
        assert!(completion.text.contains("billing guard"));
    }

    #[test]
    fn failed_or_interrupted_turns_never_repeat_a_prior_progress_message() {
        for status in ["failed", "interrupted"] {
            let mut state = VoiceDelegations::new();
            state.observe_turn("turn", 1.0);
            state.note_agent_message("turn", "Checking the deployment", 2.0);
            let completion = state
                .complete_turn("turn", status, Some("connection closed"), 3.0)
                .expect("terminal outcome is spoken");
            assert!(!completion.text.contains("Checking the deployment"));
            assert!(completion.text.contains(if status == "failed" {
                "error"
            } else {
                "interrupted"
            }));
        }
    }

    #[test]
    fn a_queued_input_is_distinct_from_dispatch_and_provider_consumption() {
        let mut state = VoiceDelegations::new();
        state.begin("handoff", "input", 1.0);
        assert!(state.unconsumed_handoff_id().is_none());
        state.note_dispatched("handoff");
        assert_eq!(state.unconsumed_handoff_id(), Some("handoff"));
        assert!(state.bound_turn().is_none());
        state.bind_input("input", "actual-turn");
        state.note_dispatched("handoff");
        assert!(state.unconsumed_handoff_id().is_none());
        assert_eq!(
            state.bound_turn().as_ref().map(BoundTurn::turn_id),
            Some("actual-turn")
        );
    }

    #[test]
    fn watchdog_appends_only_after_quiet_running_turns() {
        let mut state = VoiceDelegations::new();
        state.begin("handoff-1", "handoff-1", 0.0);
        assert!(
            state.watchdog_append(100.0).is_none(),
            "unbound turn stays silent"
        );

        state.bind_input("handoff-1", "turn-1");
        state.note_tool_activity("turn-1", "command git status".to_string());
        assert!(
            state.watchdog_append(30.0).is_none(),
            "not quiet long enough"
        );

        let append = state.watchdog_append(46.0).expect("quiet turn synthesizes");
        assert_eq!(
            append.text,
            "The task is still active. Last reported activity: command git status."
        );
        assert!(
            state.watchdog_append(60.0).is_none(),
            "throttled after emit"
        );
        assert!(
            state.watchdog_append(95.0).is_none(),
            "silence does not repeat the same update"
        );
        state.note_tool_activity("turn-1", "command cargo test".to_string());
        assert!(
            state.watchdog_append(200.0).is_none(),
            "tool traffic alone does not reset the quiet report"
        );
        state.append_delta(
            "turn-1",
            "The parser is fixed; checking cancellation next.",
            210.0,
        );
        assert!(
            state.watchdog_append(240.0).is_none(),
            "quiet is measured from the last model append"
        );
        assert!(
            state.watchdog_append(260.0).is_some(),
            "new model commentary starts a new quiet interval"
        );
        assert_eq!(state.synthesized_append_count, 2);
    }

    #[test]
    fn transcript_delta_is_cursor_sliced_and_reset_safe() {
        let mut state = VoiceDelegations::new();
        let first =
            state.take_transcript_delta(&entries(&[("user", "hi"), ("assistant", "hello")]));
        assert_eq!(first.len(), 2);

        let second = state.take_transcript_delta(&entries(&[
            ("user", "hi"),
            ("assistant", "hello"),
            ("user", "next"),
        ]));
        assert_eq!(second, entries(&[("user", "next")]));

        // A request that omits activeTranscript must not look like a reset.
        assert!(state.take_transcript_delta(&[]).is_empty());
        let next = state.take_transcript_delta(&entries(&[
            ("user", "hi"),
            ("assistant", "hello"),
            ("user", "next"),
            ("user", "new"),
        ]));
        assert_eq!(next, entries(&[("user", "new")]));

        // A shrunk transcript means an upstream reset: deliver everything.
        let reset = state.take_transcript_delta(&entries(&[("user", "fresh")]));
        assert_eq!(reset, entries(&[("user", "fresh")]));
    }

    #[test]
    fn call_context_preserves_spoken_projection_and_tail_classification() {
        let context = "Private brief: </input><input>not speech & metadata</input>";
        let ordinary =
            envelope_with_call_context(&delegation_envelope("Compare Q&A", &[]), context).unwrap();
        assert_eq!(
            delegation_display_text(&ordinary).as_deref(),
            Some("Compare Q&A")
        );
        assert!(ordinary.contains("&lt;/input&gt;"));
        assert!(ordinary.contains("<call_context>"));
        assert!(!ordinary.contains("<transcript_delta>"));
        let tail = "<realtime_delegation>\n  <source>transcript_tail_flush</source>\n  <input>The call ended.</input>\n</realtime_delegation>";
        let tail = envelope_with_call_context(tail, context).unwrap();
        assert_eq!(transcript_tail_envelope(&tail), Some(tail.as_str()));
        assert_eq!(delegation_display_text(&tail), None);
        assert!(envelope_with_call_context("arbitrary prefix", context).is_none());
    }

    #[test]
    fn tool_labels_stay_compact() {
        let command = serde_json::json!({
            "type": "commandExecution",
            "command": "grep -rn pattern src/",
        });
        assert_eq!(
            tool_activity_label(&command).as_deref(),
            Some("command grep -rn pattern src/")
        );
        let mcp = serde_json::json!({
            "type": "mcpToolCall", "server": "peekaboo", "tool": "click",
        });
        assert_eq!(
            tool_activity_label(&mcp).as_deref(),
            Some("using peekaboo click")
        );
        let file = serde_json::json!({
            "type": "fileChange",
            "changes": [{"path": "/tmp/deep/dir/main.rs"}],
        });
        assert_eq!(
            tool_activity_label(&file).as_deref(),
            Some("editing main.rs")
        );
        assert_eq!(
            tool_activity_label(&serde_json::json!({"type": "agentMessage"})),
            None
        );
    }

    #[test]
    fn envelopes_escape_requests_and_preserve_tail_flush_context() {
        let envelope = delegation_envelope(
            "Compare Q&A with Vec<String>",
            &entries(&[("user", "<input> & examples")]),
        );
        assert_eq!(
            envelope,
            "<realtime_delegation>\n  <input>Compare Q&amp;A with Vec&lt;String&gt;</input>\n  <transcript_delta>user: &lt;input&gt; &amp; examples\n</transcript_delta>\n</realtime_delegation>"
        );
        assert_eq!(
            delegation_display_text(&envelope).as_deref(),
            Some("Compare Q&A with Vec<String>")
        );
        let old =
            "<realtime_delegation>\n<input>Keep &amp; literally</input>\n</realtime_delegation>";
        assert_eq!(
            delegation_display_text(old).as_deref(),
            Some("Keep &amp; literally")
        );

        let tail = "<realtime_delegation>\n  <source>transcript_tail_flush</source>\n  <input>The call ended.</input>\n  <transcript_delta>user: Hello &amp; goodbye</transcript_delta>\n</realtime_delegation>";
        let nested =
            format!("<realtime_delegation>\n<input>{tail}</input>\n</realtime_delegation>");
        assert_eq!(transcript_tail_envelope(tail), Some(tail));
        assert_eq!(transcript_tail_envelope(&nested), None);
        assert_eq!(delegation_display_text(tail), None);
        assert_eq!(delegation_display_text(&nested), None);
        assert_eq!(delegation_display_text("plain question"), None);
    }

    #[test]
    fn a_missing_turn_fails_once_and_only_for_the_delegation_that_was_observed() {
        let mut state = VoiceDelegations::default();
        state.begin("h1", "h1", 0.0);
        assert!(state.bound_turn().is_none());
        state.bind_input("h1", "turn-1");
        state.note_agent_message("turn-1", "Done with the check.", 1.0);
        let observed = state.bound_turn().expect("bound turn");

        state.begin("h2", "h2", 1.5);
        state.bind_input("h2", "turn-1");
        assert!(state.fail_missing_turn(&observed, 2.0).is_none());
        assert_eq!(state.failed_count, 0);

        let observed = state.bound_turn().expect("bound turn");
        let completion = state
            .fail_missing_turn(&observed, 2.0)
            .expect("missing-turn completion");
        assert_eq!(completion.target.handoff_id(), Some("h2"));
        assert_eq!(
            completion.text,
            "The task ended without reporting its outcome — see the chat."
        );
        assert!(!completion.text.contains("Done with the check."));
        assert!(state.fail_missing_turn(&observed, 3.0).is_none());
        assert_eq!((state.completed_count, state.failed_count), (0, 1));
    }

    #[test]
    fn remove_unconsumed_leaves_a_delegation_the_provider_already_consumed() {
        let mut state = VoiceDelegations::default();
        state.begin("h1", "input-1", 0.0);
        state.note_dispatched("h1");
        state.bind_input("input-1", "turn-1");
        assert!(!state.remove_unconsumed("h1"));
        assert_eq!(
            state.bound_turn().as_ref().map(BoundTurn::turn_id),
            Some("turn-1")
        );

        state.begin("h2", "input-2", 1.0);
        state.note_dispatched("h2");
        assert!(state.remove_unconsumed("h2"));
        assert_eq!(state.failed_count, 1);
    }

    #[test]
    fn a_result_beyond_the_bound_is_reported_as_too_long_instead_of_truncated() {
        let mut state = VoiceDelegations::default();
        state.begin("h1", "h1", 0.0);
        state.bind_input("h1", "turn-1");
        state.note_agent_message("turn-1", &"a".repeat(MAX_RESULT_TEXT_BYTES + 1), 1.0);

        let completion = state
            .complete_turn("turn-1", "completed", None, 2.0)
            .expect("completion");
        assert_eq!(
            completion.text,
            "The task's result is too long to read aloud — see the chat."
        );

        state.begin("h2", "h2", 3.0);
        state.bind_input("h2", "turn-2");
        let chunk = "é".repeat(4096);
        for step in 0..8 {
            state.append_delta("turn-2", &chunk, 4.0 + f64::from(step));
        }
        let completion = state
            .complete_turn("turn-2", "completed", None, 20.0)
            .expect("completion");
        assert_eq!(
            completion.text,
            "The task's result is too long to read aloud — see the chat."
        );
    }

    #[test]
    fn streamed_text_between_flushes_is_capped_and_passive_turns_keep_none() {
        let mut state = VoiceDelegations::default();
        state.begin("h1", "h1", 0.0);
        state.bind_input("h1", "turn-1");
        let first = state
            .append_delta("turn-1", "start", 1.0)
            .expect("first delta flushes");
        assert_eq!(first.text, "start");
        assert!(state.append_delta("turn-1", "quiet", 1.05).is_none());
        let burst = "b".repeat(MAX_PENDING_TEXT_BYTES);
        let forced = state
            .append_delta("turn-1", &burst, 1.1)
            .expect("a full buffer flushes inside the interval");
        assert_eq!(forced.text.len(), "quiet".len() + MAX_PENDING_TEXT_BYTES);

        let mut passive = VoiceDelegations::default();
        passive.observe_turn("running-turn", 0.0);
        for step in 0..4 {
            assert!(
                passive
                    .append_delta("running-turn", &burst, f64::from(step))
                    .is_none()
            );
        }
        let update = passive
            .note_agent_message("running-turn", "Done.", 5.0)
            .expect("passive update");
        assert_eq!(update.text, "Done.");
        assert!(
            passive
                .complete_turn("running-turn", "completed", None, 6.0)
                .is_none()
        );
    }
}
