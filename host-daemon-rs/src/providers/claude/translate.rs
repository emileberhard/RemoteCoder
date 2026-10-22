//! Translates the `claude --output-format stream-json` event stream into the
//! app-server v2 notifications the iOS app already consumes.
//!
//! The app is the fixed point here: every emitted frame must decode against the
//! existing `CodexAppServerV2` models, so item payloads are built to their exact
//! wire shape (see `CodexAppServerV2+Items.swift`). Unknown Claude events are
//! dropped rather than guessed at, and a malformed line never aborts a turn.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use indexmap::IndexMap;
use serde_json::{Map, Value, json};

use self::live::{LivePrefix, LivePrefixBudget};
use super::capacity::{CapacityExceeded, MAX_PROVIDER_ID_BYTES};

const MAX_TURN_IDENTITIES: usize = 65_536;
const MAX_TURN_IDENTITY_BYTES: usize = 8 << 20;
const MAX_MESSAGE_BLOCKS: usize = 4_096;
const MAX_PENDING_TOOLS: usize = 256;
const MAX_PENDING_TOOL_BYTES: usize = 16 << 20;

use self::context_usage::token_usage_notification;
use self::tools::{PendingTool, ToolOutcome, tool_item, tool_result_images, tool_result_text};

pub(crate) mod context_usage;
pub(crate) mod live;
pub(crate) mod narration;
mod reasoning;
pub(crate) mod tools;

/// Rejected because the run would not bill the user's claude.ai subscription.
#[derive(Debug, Clone)]
pub(crate) struct BillingViolation(pub String);

/// What the caller should do after feeding a line to the translator.
#[derive(Debug, Default)]
pub(crate) struct Translated {
    /// JSON-RPC notification frames to broadcast verbatim.
    pub notifications: Vec<Value>,
    /// Set once the CLI reports the turn is over.
    pub result: Option<TurnResult>,
    pub capacity_error: Option<CapacityExceeded>,
    pub live_prefix_failures: Vec<(String, CapacityExceeded)>,
}

#[derive(Debug, Clone)]
pub(crate) struct TurnResult {
    pub status: String,
    pub error_message: Option<String>,
    pub error_info: Option<CodexErrorInfo>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CodexErrorInfo {
    CyberPolicy,
}

impl CodexErrorInfo {
    fn from_refusal_category(category: &str) -> Option<Self> {
        match category {
            "cyber" => Some(Self::CyberPolicy),
            _ => None,
        }
    }

    fn wire_name(self) -> &'static str {
        match self {
            Self::CyberPolicy => "cyberPolicy",
        }
    }
}

#[derive(Debug)]
enum BlockKind {
    Thinking {
        reasoning_item_id: String,
        prefix: LivePrefix,
    },
    Text {
        item_id: String,
        prefix: LivePrefix,
    },
    ToolUse,
}

/// Per-turn translation state.
pub(crate) struct TurnTranslator {
    thread_id: String,
    turn_id: String,
    live_epoch: String,
    live_sequence: u64,
    live_finished: bool,
    live_prefix_budget: Arc<LivePrefixBudget>,
    cwd: String,
    blocks: HashMap<u64, BlockKind>,
    pending_tools: IndexMap<String, PendingTool>,
    pending_tool_bytes: usize,
    current_message_id: Option<String>,
    assistant_block_offsets: HashMap<String, u64>,
    assistant_records: HashSet<String>,
    identity_bytes: usize,
    reasoning_item_id: Option<String>,
    thinking_tokens: i64,
    session_id: Option<String>,
    model_id: Option<String>,
    latest_context_usage: Option<Value>,
    auto_compact_window: Option<i64>,
    started_at_ms: i64,
    manual_compaction: bool,
    compaction_item: Option<String>,
    compaction_completed: bool,
    compaction_sequence: u32,
    refusal: Option<CodexErrorInfo>,
}

impl TurnTranslator {
    pub fn new(
        thread_id: String,
        turn_id: String,
        cwd: String,
        auto_compact_window: Option<i64>,
        started_at_ms: i64,
        live_prefix_budget: Arc<LivePrefixBudget>,
    ) -> Self {
        Self {
            thread_id,
            turn_id,
            live_epoch: crate::ids::new_session_uuid(),
            live_sequence: 0,
            live_finished: false,
            live_prefix_budget,
            cwd,
            blocks: HashMap::new(),
            pending_tools: IndexMap::new(),
            pending_tool_bytes: 0,
            current_message_id: None,
            assistant_block_offsets: HashMap::new(),
            assistant_records: HashSet::new(),
            identity_bytes: 0,
            reasoning_item_id: None,
            thinking_tokens: 0,
            session_id: None,
            model_id: None,
            latest_context_usage: None,
            auto_compact_window,
            started_at_ms,
            manual_compaction: false,
            compaction_item: None,
            compaction_completed: false,
            compaction_sequence: 0,
            refusal: None,
        }
    }

    pub(crate) fn turn_id(&self) -> &str {
        &self.turn_id
    }

    pub(crate) fn session_id(&self) -> Option<&str> {
        self.session_id.as_deref()
    }

    pub(crate) fn expect_manual_compaction(&mut self) {
        self.manual_compaction = true;
    }

    pub(crate) fn is_manual_compaction(&self) -> bool {
        self.manual_compaction
    }

    fn start_compaction(&mut self, out: &mut Translated) {
        if self.compaction_item.is_none() {
            self.compaction_sequence = self.compaction_sequence.saturating_add(1);
            let id = format!("{}#compact-{}", self.turn_id, self.compaction_sequence);
            out.notifications
                .push(self.item_started(json!({"type":"contextCompaction", "id":id})));
            self.compaction_item = Some(id);
        }
    }

    /// Feeds one parsed stream line.
    pub(crate) fn handle(&mut self, value: &Value) -> Translated {
        let mut out = Translated::default();

        // Sub-agent traffic rolls up under its parent Task item; forwarding it would
        // interleave two conversations in one timeline.
        if value
            .get("parent_tool_use_id")
            .is_some_and(|v| !v.is_null())
        {
            return out;
        }

        let Some(event_type) = value.get("type").and_then(Value::as_str) else {
            return out;
        };
        let Some(sequence) = self.live_sequence.checked_add(1) else {
            out.capacity_error = Some(CapacityExceeded {
                resource: "live observation sequence",
                limit: usize::MAX,
            });
            return out;
        };
        self.live_sequence = sequence;

        match event_type {
            "system" => self.handle_system(value, &mut out),
            "stream_event" => self.handle_stream_event(value, &mut out),
            "assistant" => self.handle_assistant(value, &mut out),
            "user" => self.handle_user(value, &mut out),
            "result" => self.handle_result(value, &mut out),
            // rate_limit_event is cached by the caller; everything else is not ours.
            _ => {}
        }

        for notification in &mut out.notifications {
            notification["rcClaudeLive"] =
                json!({"epoch":self.live_epoch, "sequence":self.live_sequence});
        }
        out
    }

    fn handle_system(&mut self, value: &Value, out: &mut Translated) {
        match value.get("subtype").and_then(Value::as_str) {
            Some("init") => {
                self.session_id = value
                    .get("session_id")
                    .and_then(Value::as_str)
                    .map(str::to_string);
                self.model_id = value
                    .get("model")
                    .and_then(Value::as_str)
                    .map(str::to_string);
            }
            Some("thinking_tokens") => {
                if let Some(tokens) = value.get("estimated_tokens").and_then(Value::as_i64) {
                    self.thinking_tokens = tokens;
                }
                if self.reasoning_item_id.is_none() {
                    let item_id = self.synthesized_reasoning_item_id();
                    self.open_reasoning_row(item_id, out);
                }
            }
            Some("status") if value["status"] == "compacting" => {
                if self.compaction_completed {
                    self.compaction_item = None;
                    self.compaction_completed = false;
                }
                self.start_compaction(out);
            }
            Some("compact_boundary") => {
                if self.manual_compaction && value["compact_metadata"]["trigger"] != "manual" {
                    return;
                }
                self.start_compaction(out);
                if !self.compaction_completed {
                    if let Some(id) = self.compaction_item.as_deref() {
                        out.notifications.push(
                            self.item_completed(json!({"type":"contextCompaction", "id":id})),
                        );
                    }
                    self.compaction_completed = true;
                }
            }
            // api_retry/plugin_install carry no timeline meaning.
            _ => {}
        }
    }

    fn handle_stream_event(&mut self, value: &Value, out: &mut Translated) {
        let Some(event) = value.get("event") else {
            return;
        };
        let Some(kind) = event.get("type").and_then(Value::as_str) else {
            return;
        };

        match kind {
            "message_start" => {
                if event
                    .pointer("/message/id")
                    .and_then(Value::as_str)
                    .is_some_and(|id| id.len() > MAX_PROVIDER_ID_BYTES)
                {
                    out.capacity_error = Some(CapacityExceeded {
                        resource: "provider identifier bytes",
                        limit: MAX_PROVIDER_ID_BYTES,
                    });
                    return;
                }
                self.current_message_id = event
                    .get("message")
                    .and_then(|message| message.get("id"))
                    .and_then(Value::as_str)
                    .map(str::to_string);
                // Block indexes are scoped to one provider message.
                self.blocks.clear();
                self.reasoning_item_id = None;
            }
            "content_block_start" => self.handle_content_block_start(event, out),
            "content_block_delta" => self.handle_content_block_delta(event, out),
            "content_block_stop" => self.handle_content_block_stop(event),
            "message_delta" => {
                if let Some(usage) = event.get("usage")
                    && let Some(notification) =
                        token_usage_notification(&self.thread_id, &self.turn_id, usage, None)
                {
                    self.latest_context_usage = Some(usage.clone());
                    out.notifications.push(notification);
                }
            }
            _ => {}
        }
    }

    fn handle_content_block_start(&mut self, event: &Value, out: &mut Translated) {
        let Some(index) = event.get("index").and_then(Value::as_u64) else {
            return;
        };
        let Some(block) = event.get("content_block") else {
            return;
        };

        if !self.blocks.contains_key(&index) && self.blocks.len() >= MAX_MESSAGE_BLOCKS {
            out.capacity_error = Some(CapacityExceeded {
                resource: "message blocks",
                limit: MAX_MESSAGE_BLOCKS,
            });
            return;
        }
        match block.get("type").and_then(Value::as_str) {
            Some("thinking") => {
                let reasoning_item_id = match self.reasoning_item_id.clone() {
                    Some(item_id) => item_id,
                    None => {
                        let item_id = format!("{}#thinking", self.block_item_id(index));
                        self.open_reasoning_row(item_id, out)
                    }
                };
                let mut prefix = LivePrefix::new(self.live_prefix_budget.clone());
                if let Some(failure) = prefix.append(block["thinking"].as_str().unwrap_or_default())
                {
                    out.live_prefix_failures
                        .push((reasoning_item_id.clone(), failure));
                }
                self.blocks.insert(
                    index,
                    BlockKind::Thinking {
                        reasoning_item_id,
                        prefix,
                    },
                );
            }
            Some("text") => {
                let item_id = self.block_item_id(index);
                let text = block["text"].as_str().unwrap_or_default();
                let mut prefix = LivePrefix::new(self.live_prefix_budget.clone());
                if let Some(failure) = prefix.append(text) {
                    out.live_prefix_failures.push((item_id.clone(), failure));
                }
                self.blocks.insert(
                    index,
                    BlockKind::Text {
                        item_id: item_id.clone(),
                        prefix,
                    },
                );
                out.notifications
                    .push(self.item_started(agent_message_item(&item_id, text)));
            }
            Some("tool_use") => {
                // Deliberately no item/started yet: the tool input streams in as
                // input_json_delta, and starting here would render an empty command
                // row. The assistant message carries the complete input and still
                // arrives before the tool runs, so the block is only recorded to
                // keep its deltas from being mistaken for assistant text.
                self.blocks.insert(index, BlockKind::ToolUse);
            }
            _ => {}
        }
    }

    fn handle_content_block_delta(&mut self, event: &Value, out: &mut Translated) {
        let Some(index) = event.get("index").and_then(Value::as_u64) else {
            return;
        };
        let Some(delta) = event.get("delta") else {
            return;
        };

        // signature_delta and input_json_delta carry nothing the timeline shows.
        let field = match delta.get("type").and_then(Value::as_str) {
            Some("text_delta") => "text",
            Some("thinking_delta") => "thinking",
            _ => return,
        };
        let Some(text) = delta.get(field).and_then(Value::as_str) else {
            return;
        };
        if text.is_empty() {
            return;
        }
        match (field, self.blocks.get_mut(&index)) {
            ("text", Some(BlockKind::Text { item_id, prefix })) => {
                if let Some(failure) = prefix.append(text) {
                    out.live_prefix_failures.push((item_id.clone(), failure));
                }
                let item_id = item_id.clone();
                out.notifications
                    .push(self.agent_message_delta(&item_id, text));
            }
            (
                "thinking",
                Some(BlockKind::Thinking {
                    reasoning_item_id,
                    prefix,
                }),
            ) => {
                if let Some(failure) = prefix.append(text) {
                    out.live_prefix_failures
                        .push((reasoning_item_id.clone(), failure));
                }
            }
            _ => {}
        }
    }

    fn handle_content_block_stop(&mut self, event: &Value) {
        let Some(index) = event.get("index").and_then(Value::as_u64) else {
            return;
        };
        let Some(block) = self.blocks.get(&index) else {
            return;
        };

        // The canonical assistant record can follow content_block_stop.
        if matches!(block, BlockKind::ToolUse) {
            self.blocks.remove(&index);
        }

        if let Some(BlockKind::Thinking {
            reasoning_item_id, ..
        }) = self.blocks.get(&index)
            && self.reasoning_item_id.as_ref() == Some(reasoning_item_id)
        {
            self.reasoning_item_id = None;
        }
    }

    fn handle_assistant(&mut self, value: &Value, out: &mut Translated) {
        let record_id = value.get("uuid").and_then(Value::as_str);
        if record_id.is_some_and(|id| self.assistant_records.contains(id)) {
            return;
        }
        match value
            .pointer("/message/stop_reason")
            .and_then(Value::as_str)
        {
            Some("refusal") => {
                self.refusal = value
                    .pointer("/message/stop_details/category")
                    .and_then(Value::as_str)
                    .and_then(CodexErrorInfo::from_refusal_category);
            }
            Some(_) => self.refusal = None,
            None => {}
        }
        let provider_id = value.pointer("/message/id").and_then(Value::as_str);
        if provider_id.is_some_and(|id| id.len() > MAX_PROVIDER_ID_BYTES) {
            out.capacity_error = Some(CapacityExceeded {
                resource: "provider identifier bytes",
                limit: MAX_PROVIDER_ID_BYTES,
            });
            return;
        }
        if value
            .pointer("/message/content")
            .and_then(Value::as_array)
            .is_some_and(|content| content.len() > MAX_MESSAGE_BLOCKS)
        {
            out.capacity_error = Some(CapacityExceeded {
                resource: "message blocks",
                limit: MAX_MESSAGE_BLOCKS,
            });
            return;
        }
        let new_provider_id =
            provider_id.filter(|id| !self.assistant_block_offsets.contains_key(*id));
        let added_bytes = record_id
            .map_or(0, str::len)
            .saturating_add(new_provider_id.map_or(0, str::len));
        let added_entries =
            usize::from(record_id.is_some()) + usize::from(new_provider_id.is_some());
        let entries = self.assistant_records.len() + self.assistant_block_offsets.len();
        if added_entries > MAX_TURN_IDENTITIES.saturating_sub(entries) {
            out.capacity_error = Some(CapacityExceeded {
                resource: "turn identities",
                limit: MAX_TURN_IDENTITIES,
            });
            return;
        }
        if added_bytes > MAX_TURN_IDENTITY_BYTES.saturating_sub(self.identity_bytes) {
            out.capacity_error = Some(CapacityExceeded {
                resource: "turn identity bytes",
                limit: MAX_TURN_IDENTITY_BYTES,
            });
            return;
        }
        self.identity_bytes += added_bytes;
        if let Some(id) = record_id {
            self.assistant_records.insert(id.to_string());
        }
        if let Some(id) = new_provider_id {
            self.assistant_block_offsets.insert(id.to_string(), 0);
        }
        let Some(content) = value
            .get("message")
            .and_then(|message| message.get("content"))
            .and_then(Value::as_array)
        else {
            return;
        };

        let first_index = provider_id
            .map(|id| {
                let offset = self
                    .assistant_block_offsets
                    .entry(id.to_string())
                    .or_default();
                let first = *offset;
                *offset += content.len() as u64;
                first
            })
            .unwrap_or(0);
        for (index, block) in content.iter().enumerate() {
            match block.get("type").and_then(Value::as_str) {
                Some("text") => {
                    let text = block
                        .get("text")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    let known = provider_id.map(|id| {
                        (
                            first_index + index as u64,
                            format!("{id}#{}", first_index + index as u64),
                        )
                    });
                    let Some((index, item_id)) = known.or_else(|| self.open_text_item()) else {
                        continue;
                    };
                    out.notifications
                        .push(self.item_completed(agent_message_item(&item_id, text)));
                    self.blocks.remove(&index);
                }
                Some("thinking") => {
                    let Some(id) = provider_id else {
                        continue;
                    };
                    let index = first_index + index as u64;
                    match narration::narration_text(block) {
                        Some(text) => self.complete_narration(id, index, text, out),
                        None => self.complete_thinking(index, block, out),
                    }
                }
                Some("tool_use") => {
                    if let Some(text) = narration::sent_message_text(block) {
                        if let Some(id) = block.get("id").and_then(Value::as_str) {
                            self.emit_agent_message(id, text, out);
                        }
                        continue;
                    }
                    self.start_tool_item(block, out);
                    if out.capacity_error.is_some() {
                        return;
                    }
                }
                _ => {}
            }
        }
    }

    /// The item id of the currently open text block, if any.
    fn open_text_item(&self) -> Option<(u64, String)> {
        self.blocks
            .iter()
            .filter_map(|(index, block)| match block {
                BlockKind::Text { item_id, .. } => Some((*index, item_id.clone())),
                _ => None,
            })
            .min_by_key(|(index, _)| *index)
    }

    fn handle_user(&mut self, value: &Value, out: &mut Translated) {
        let content = value.pointer("/message/content");
        if !crate::providers::claude::timeline::is_injected_user_record(value, content)
            && let Some(text) = crate::providers::claude::timeline::user_prompt_text(content)
            && let Some(id) = value.get("uuid").and_then(Value::as_str)
        {
            out.notifications
                .push(self.item_completed(user_message_item(id, &text, content)));
        }
        let Some(content) = value
            .get("message")
            .and_then(|message| message.get("content"))
            .and_then(Value::as_array)
        else {
            return;
        };

        for block in content {
            if block.get("type").and_then(Value::as_str) != Some("tool_result") {
                continue;
            }
            let Some(tool_use_id) = block.get("tool_use_id").and_then(Value::as_str) else {
                continue;
            };
            let Some(pending) = self.pending_tools.shift_remove(tool_use_id) else {
                continue;
            };

            self.pending_tool_bytes -= pending.bytes;
            let is_error = block
                .get("is_error")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let outcome = ToolOutcome::Finished {
                is_error,
                result_text: tool_result_text(block),
                images: tool_result_images(block),
                tool_use_result: value.get("tool_use_result").cloned(),
                duration_ms: Some((crate::time::unix_millis() - pending.started_at_ms).max(0)),
            };

            let item = tool_item(
                tool_use_id,
                &pending.tool_name,
                &pending.input,
                &self.cwd,
                outcome,
            );
            out.notifications.push(self.item_completed(item));
        }
    }

    fn handle_result(&mut self, value: &Value, out: &mut Translated) {
        let is_error = value
            .get("is_error")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let subtype = value
            .get("subtype")
            .and_then(Value::as_str)
            .unwrap_or_default();
        // An interrupt arrives as an ordinary error result; only terminal_reason
        // separates it from a genuine failure, and the app renders the two
        // differently. Verified against a real SIGTERM'd turn.
        let aborted = value
            .get("terminal_reason")
            .and_then(Value::as_str)
            .is_some_and(|reason| reason.starts_with("aborted"));
        let missing_compaction = self.manual_compaction && !self.compaction_completed;
        let status = if aborted {
            "interrupted"
        } else if is_error || subtype.starts_with("error") || missing_compaction {
            "failed"
        } else {
            "completed"
        };

        let error_message = if status == "failed" && missing_compaction && !is_error {
            Some("Claude ended without confirming a compaction boundary".to_owned())
        } else if status == "failed" {
            Some(
                value
                    .get("result")
                    .and_then(Value::as_str)
                    .unwrap_or(subtype)
                    .to_string(),
            )
        } else {
            None
        };

        let context_window = self.model_context_window(value);
        if let Some(usage) = self
            .latest_context_usage
            .as_ref()
            .or_else(|| value.get("usage"))
            && let Some(notification) =
                token_usage_notification(&self.thread_id, &self.turn_id, usage, context_window)
        {
            out.notifications.push(notification);
        }

        let error_info = if status == "failed" {
            self.refusal
        } else {
            None
        };

        out.result = Some(TurnResult {
            status: status.to_string(),
            error_message,
            error_info,
        });
        self.end_live_state();
    }

    /// Builds the terminal `turn/completed` frame.
    ///
    /// `total_cost_usd` is deliberately never carried: it is a client-side API-rate
    /// estimate, not a bill, and these turns run on a subscription.
    pub(crate) fn turn_completed(
        &self,
        status: &str,
        error_message: Option<&str>,
        error_info: Option<CodexErrorInfo>,
    ) -> Value {
        self.turn_completed_with_clock(status, error_message, error_info, crate::time::unix_millis)
    }

    fn turn_completed_with_clock(
        &self,
        status: &str,
        error_message: Option<&str>,
        error_info: Option<CodexErrorInfo>,
        clock: impl FnOnce() -> i64,
    ) -> Value {
        let completed_at_ms = clock();
        let mut turn = Map::new();
        turn.insert("id".to_string(), json!(self.turn_id));
        turn.insert("items".to_string(), json!([]));
        turn.insert("itemsView".to_string(), json!("full"));
        turn.insert("startedAt".to_string(), json!(self.started_at_ms / 1000));
        turn.insert("startedAtMs".to_string(), json!(self.started_at_ms));
        turn.insert(
            "completedAt".to_string(),
            json!(completed_at_ms.div_euclid(1000)),
        );
        turn.insert("completedAtMs".to_string(), json!(completed_at_ms));
        turn.insert(
            "durationMs".to_string(),
            json!((completed_at_ms - self.started_at_ms).max(0)),
        );
        turn.insert("status".to_string(), json!(status));
        if let Some(message) = error_message {
            turn.insert(
                "error".to_string(),
                json!({ "message": message, "codexErrorInfo": error_info.map(CodexErrorInfo::wire_name), "additionalDetails": Value::Null }),
            );
        }

        json!({
            "method": "turn/completed",
            "params": { "threadId": self.thread_id, "turn": Value::Object(turn) }
        })
    }

    /// Builds the opening `turn/started` frame.
    pub(crate) fn turn_started(&self) -> Value {
        json!({
            "method": "turn/started",
            "params": {
                "threadId": self.thread_id,
                "turn": {
                    "id": self.turn_id,
                    "items": [],
                    "itemsView": "full",
                    "startedAt": self.started_at_ms / 1000,
                    "startedAtMs": self.started_at_ms,
                    "status": "inProgress",
                }
            }
        })
    }

    fn block_item_id(&self, index: u64) -> String {
        match self.current_message_id.as_deref() {
            Some(message_id) => format!("{message_id}#{index}"),
            None => format!("{}#{index}", self.turn_id),
        }
    }

    fn item_started(&self, item: Value) -> Value {
        json!({
            "method": "item/started",
            "params": {
                "item": item,
                "startedAtMs": crate::time::unix_millis(),
                "threadId": self.thread_id,
                "turnId": self.turn_id,
            }
        })
    }

    fn item_completed(&self, item: Value) -> Value {
        json!({
            "method": "item/completed",
            "params": {
                "item": item,
                "completedAtMs": crate::time::unix_millis(),
                "threadId": self.thread_id,
                "turnId": self.turn_id,
            }
        })
    }

    fn emit_agent_message(&self, item_id: &str, text: &str, out: &mut Translated) {
        out.notifications
            .push(self.item_started(agent_message_item(item_id, "")));
        out.notifications
            .push(self.agent_message_delta(item_id, text));
        out.notifications
            .push(self.item_completed(agent_message_item(item_id, text)));
    }

    fn agent_message_delta(&self, item_id: &str, delta: &str) -> Value {
        json!({
            "method": "item/agentMessage/delta",
            "params": {
                "threadId": self.thread_id,
                "turnId": self.turn_id,
                "itemId": item_id,
                "delta": delta,
            }
        })
    }
}

/// Per-run billing assertion.
///
/// A run that reports an API key source would not bill the subscription, and
/// one that reports fast mode the conversation did not select would bill
/// unasked-for extra usage, so the caller kills it rather than letting it
/// continue.
pub(crate) fn billing_violation(init: &Value, fast_selected: bool) -> Option<BillingViolation> {
    let api_key_source = init
        .get("apiKeySource")
        .and_then(Value::as_str)
        .unwrap_or("missing");
    if api_key_source != "none" {
        return Some(BillingViolation(format!(
            "apiKeySource is {api_key_source}, expected none"
        )));
    }

    let fast_mode = init
        .get("fast_mode_state")
        .and_then(Value::as_str)
        .unwrap_or("missing");
    if !fast_selected && fast_mode != "off" {
        return Some(BillingViolation(format!(
            "fast_mode_state is {fast_mode}, expected off"
        )));
    }

    let permission_mode = init
        .get("permissionMode")
        .and_then(Value::as_str)
        .unwrap_or("missing");
    if permission_mode != "bypassPermissions" {
        return Some(BillingViolation(format!(
            "permissionMode is {permission_mode}, expected bypassPermissions"
        )));
    }

    None
}

pub(crate) fn user_message_item(id: &str, text: &str, source: Option<&Value>) -> Value {
    let blocks = source.and_then(Value::as_array);
    let images: Vec<Value> = blocks
        .into_iter()
        .flatten()
        .filter(|block| block["type"] == "image")
        .filter_map(|block| {
            let source = block.get("source")?;
            let url = match source["type"].as_str()? {
                "base64" => format!(
                    "data:{};base64,{}",
                    source["media_type"].as_str()?,
                    source["data"].as_str()?
                ),
                "url" => source["url"].as_str()?.to_string(),
                _ => return None,
            };
            Some(json!({"type": "image", "url": url}))
        })
        .collect();
    let has_text = blocks.is_none_or(|blocks| {
        blocks.iter().any(|block| {
            block["type"] == "text"
                && block["text"]
                    .as_str()
                    .is_some_and(|text| !text.trim().is_empty())
        })
    });
    let mut content = Vec::new();
    if has_text || images.is_empty() {
        content.push(json!({"type": "text", "text": text, "textElements": []}));
    }
    content.extend(images);
    json!({"type": "userMessage", "id": id, "clientId": id, "content": content})
}

pub(crate) fn agent_message_item(id: &str, text: &str) -> Value {
    json!({
        "type": "agentMessage",
        "id": id,
        "text": text,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(super) fn translator() -> TurnTranslator {
        TurnTranslator::new(
            "claude_11111111-2222-3333-4444-555555555555".to_string(),
            "turn-1".to_string(),
            "/repo".to_string(),
            None,
            1_700_000_000_000,
            Arc::default(),
        )
    }

    pub(super) fn methods(values: &[Value]) -> Vec<String> {
        values
            .iter()
            .filter_map(|value| value.get("method").and_then(Value::as_str))
            .map(str::to_string)
            .collect()
    }

    #[tokio::test]
    async fn completion_timestamps_match_history_across_a_second_boundary() {
        use crate::providers::claude::conversation_index::{self, Store};
        use crate::providers::claude::projection::{ItemsView, ProjectionCache, TurnsListParams};
        use std::cell::Cell;

        let home = tempfile::tempdir().expect("isolated history home");
        let store = Store::new(home.path().to_path_buf());
        let mut t = translator();
        let prompt = json!({"type":"user","uuid":"prompt","cwd":"/repo","timestamp":"2023-11-14T22:13:20.000Z","message":{"role":"user","content":"Finish the turn"}});
        let path = home.path().join("session.jsonl");
        std::fs::write(&path, format!("{prompt}\n")).expect("write provider transcript");
        let mut started = t.turn_started();
        store.record(&mut started).await.expect("record turn start");
        for mut frame in t.handle(&prompt).notifications {
            store.record(&mut frame).await.expect("record prompt");
        }

        let clock = Cell::new(1_700_000_000_999_i64);
        let mut completed = t.turn_completed_with_clock("completed", None, None, || {
            let instant = clock.get();
            clock.set(instant + 1);
            instant
        });
        store
            .record(&mut completed)
            .await
            .expect("record completion");
        let index =
            conversation_index::read(home.path(), &t.thread_id).expect("read persisted index");
        let indexed_turn = index.turns.get(&t.turn_id).expect("indexed turn");
        let cache = ProjectionCache::new(1024 * 1024);
        let (page, _) = cache
            .read(
                home.path(),
                &t.thread_id,
                &path,
                None,
                |projection, file| {
                    projection.turns_page(
                        file,
                        &TurnsListParams {
                            thread_id: t.thread_id.clone(),
                            cursor: None,
                            limit: Some(1),
                            sort_direction: None,
                            items_view: Some(ItemsView::Full),
                        },
                    )
                },
            )
            .expect("read history page");
        let live = &completed["params"]["turn"];
        let history = &page["data"][0];
        assert_eq!(history["id"], t.turn_id);
        assert_eq!(live["completedAt"], history["completedAt"]);
        assert_eq!(live["durationMs"], history["durationMs"]);
        assert_eq!(indexed_turn.completed_at_ms, Some(1_700_000_000_999));
        assert_eq!(live["completedAtMs"], 1_700_000_000_999_i64);
        assert_eq!(live["completedAt"], 1_700_000_000_i64);
        assert_eq!(live["durationMs"], 999);
    }

    #[test]
    fn turn_identity_capacity_preserves_existing_offsets_and_refuses_new_records() {
        let mut t = translator();
        for index in 0..MAX_TURN_IDENTITIES - 1 {
            let output = t.handle(&json!({"type":"assistant", "uuid":index.to_string(),
                "message":{"id":"message", "content":[{"type":"text", "text":"part"}]}}));
            assert!(output.capacity_error.is_none());
            assert_eq!(
                output.notifications[0]["params"]["item"]["id"],
                format!("message#{index}")
            );
        }
        let duplicate = t.handle(
            &json!({"type":"assistant", "uuid":"0", "message":{"id":"message", "content":[]}}),
        );
        assert!(duplicate.capacity_error.is_none());
        assert!(duplicate.notifications.is_empty());
        let rejected = t.handle(&json!({"type":"assistant", "uuid":"overflow", "message":{"id":"message", "content":[{"type":"text", "text":"lost"}]}}));
        assert_eq!(rejected.capacity_error.unwrap().resource, "turn identities");
        assert!(rejected.notifications.is_empty());

        let mut t = translator();
        let rejected = t.handle(&json!({"type":"assistant", "uuid":"x".repeat(MAX_TURN_IDENTITY_BYTES + 1), "message":{"content":[]}}));
        assert_eq!(
            rejected.capacity_error.unwrap().resource,
            "turn identity bytes"
        );
        let accepted = t.handle(&json!({"type":"assistant", "uuid":"valid", "message":{"id":"message", "content":[{"type":"text", "text":"kept"}]}}));
        assert_eq!(
            accepted.notifications[0]["params"]["item"]["id"],
            "message#0"
        );
    }

    #[test]
    fn translation_capacity_bounds_open_blocks_and_pending_tool_inputs() {
        let mut t = translator();
        t.handle(&json!({"type":"stream_event", "event":{"type":"message_start", "message":{"id":"message"}}}));
        for index in 0..MAX_MESSAGE_BLOCKS {
            assert!(t.handle(&json!({"type":"stream_event", "event":{"type":"content_block_start", "index":index, "content_block":{"type":"text"}}})).capacity_error.is_none());
        }
        let rejected = t.handle(&json!({"type":"stream_event", "event":{"type":"content_block_start", "index":MAX_MESSAGE_BLOCKS, "content_block":{"type":"text"}}}));
        assert_eq!(rejected.capacity_error.unwrap().resource, "message blocks");
        assert!(rejected.notifications.is_empty());
        let mut t = translator();
        for index in 0..MAX_PENDING_TOOLS {
            assert!(t.handle(&json!({"type":"assistant", "message":{"content":[{"type":"tool_use", "id":index.to_string(), "name":"Bash", "input":{}}]}})).capacity_error.is_none());
        }
        let rejected = t.handle(&json!({"type":"assistant", "message":{"content":[{"type":"tool_use", "id":"overflow", "name":"Bash", "input":{}}]}}));
        assert_eq!(rejected.capacity_error.unwrap().resource, "pending tools");
        t.handle(&json!({"type":"user", "message":{"content":[{"type":"tool_result", "tool_use_id":"0", "content":"done"}]}}));
        let accepted = t.handle(&json!({"type":"assistant", "message":{"content":[{"type":"tool_use", "id":"next", "name":"Bash", "input":{}}]}}));
        assert!(accepted.capacity_error.is_none());
        assert_eq!(accepted.notifications[0]["params"]["item"]["id"], "next");
        let mut t = translator();
        let rejected = t.handle(&json!({"type":"assistant", "message":{"content":[{"type":"tool_use", "id":"big", "name":"Bash", "input":{"command":"x".repeat(MAX_PENDING_TOOL_BYTES)}}]}}));
        assert_eq!(
            rejected.capacity_error.unwrap().resource,
            "pending tool bytes"
        );
        assert!(rejected.notifications.is_empty());
    }

    #[test]
    fn bounds_review_canonical_assistant_records_cannot_amplify_oversized_ids_or_block_lists() {
        for (id, content, resource) in [
            (
                "x".repeat(MAX_PROVIDER_ID_BYTES + 1),
                vec![json!({"type":"text","text":"kept"}); 4],
                "provider identifier bytes",
            ),
            (
                "message".into(),
                vec![json!({"type":"text","text":"kept"}); MAX_MESSAGE_BLOCKS + 1],
                "message blocks",
            ),
        ] {
            let mut t = translator();
            let output = t.handle(&json!({"type":"assistant", "uuid":"record", "message":{"id":id, "content":content}}));
            assert_eq!(output.capacity_error.unwrap().resource, resource);
            assert!(output.notifications.is_empty());
            let accepted = t.handle(&json!({"type":"assistant", "uuid":"record", "message":{"id":"message", "content":[{"type":"text","text":"kept"}]}}));
            assert_eq!(
                accepted.notifications[0]["params"]["item"]["id"],
                "message#0"
            );
        }
    }

    #[test]
    fn manual_compaction_completes_only_on_native_boundary() {
        let mut t = translator();
        t.expect_manual_compaction();
        let started = t.handle(&json!({"type":"system","subtype":"status","status":"compacting"}));
        assert_eq!(methods(&started.notifications), ["item/started"]);
        assert_eq!(
            started.notifications[0]["params"]["item"]["type"],
            "contextCompaction"
        );
        let status = t.handle(
            &json!({"type":"system","subtype":"status","status":null,"compact_result":"success"}),
        );
        assert!(status.notifications.is_empty());
        assert!(status.result.is_none());
        let completed = t.handle(&json!({"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual","pre_tokens":40000,"post_tokens":2700}}));
        assert_eq!(methods(&completed.notifications), ["item/completed"]);
        assert_eq!(
            started.notifications[0]["params"]["item"]["id"],
            completed.notifications[0]["params"]["item"]["id"]
        );
        assert!(completed.result.is_none());
        let done = t.handle(&json!({"type":"result","subtype":"success","is_error":false}));
        assert_eq!(done.result.unwrap().status, "completed");
    }

    #[test]
    fn manual_compaction_without_native_boundary_fails_instead_of_reporting_success() {
        let mut t = translator();
        t.expect_manual_compaction();
        let automatic = t.handle(&json!({"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto"}}));
        assert!(automatic.notifications.is_empty());
        let done = t.handle(&json!({"type":"result","subtype":"success","is_error":false}));
        assert!(
            done.notifications
                .iter()
                .all(|item| item["method"] != "item/completed")
        );
        let result = done.result.unwrap();
        assert_eq!(result.status, "failed");
        assert!(
            result
                .error_message
                .unwrap()
                .contains("compaction boundary")
        );
    }

    #[test]
    fn init_without_violations_emits_nothing() {
        let mut t = translator();
        let init = json!({
            "type": "system", "subtype": "init", "session_id": "abc",
            "apiKeySource": "none", "fast_mode_state": "off",
            "permissionMode": "bypassPermissions"
        });

        let out = t.handle(&init);

        assert!(out.notifications.is_empty());
        assert!(billing_violation(&init, false).is_none());
        assert_eq!(t.session_id(), Some("abc"));
    }

    #[test]
    fn each_non_subscription_init_field_is_a_billing_violation() {
        for (field, value) in [
            ("apiKeySource", "ANTHROPIC_API_KEY"),
            ("fast_mode_state", "on"),
            ("permissionMode", "default"),
        ] {
            let mut init = json!({
                "type": "system", "subtype": "init",
                "apiKeySource": "none", "fast_mode_state": "off",
                "permissionMode": "bypassPermissions"
            });
            init[field] = json!(value);

            let violation = billing_violation(&init, false).expect("billing violation");
            assert!(violation.0.starts_with(field), "{field}: {}", violation.0);
        }
    }

    #[test]
    fn fast_mode_is_a_billing_violation_only_when_not_selected() {
        let init = json!({
            "type": "system", "subtype": "init",
            "apiKeySource": "none", "fast_mode_state": "on",
            "permissionMode": "bypassPermissions"
        });

        assert!(billing_violation(&init, true).is_none());
        assert!(billing_violation(&init, false).is_some());
    }

    #[test]
    fn canonical_text_survives_block_stop_and_uses_the_same_provider_block_id_as_history() {
        let mut t = translator();
        t.handle(
            &json!({"type":"stream_event","event":{"type":"message_start","message":{"id":"msg"}}}),
        );
        t.handle(&json!({"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}}));
        t.handle(&json!({"type":"stream_event","event":{"type":"content_block_stop","index":0}}));
        t.handle(&json!({"type":"assistant","uuid":"thinking-record","message":{"id":"msg","content":[{"type":"thinking","thinking":"private"}]}}));
        let started = t.handle(&json!({"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text"}}}));
        t.handle(&json!({"type":"stream_event","event":{"type":"content_block_stop","index":1}}));
        let record = json!({"type":"assistant","uuid":"text-record","message":{"id":"msg","content":[{"type":"text","text":"Visible"}]}});
        let completed = t.handle(&record);
        assert_eq!(started.notifications[0]["params"]["item"]["id"], "msg#1");
        assert_eq!(completed.notifications[0]["params"]["item"]["id"], "msg#1");
        assert_eq!(
            completed.notifications[0]["params"]["item"]["text"],
            "Visible"
        );
        assert!(t.handle(&record).notifications.is_empty());
    }

    #[test]
    fn replayed_user_echo_retains_client_identity_but_injected_context_does_not_become_a_user() {
        let mut t = translator();
        let echo = t.handle(&json!({"type":"user","uuid":"client-id","message":{"role":"user","content":"Actual input"}}));
        assert_eq!(echo.notifications[0]["params"]["item"]["id"], "client-id");
        assert_eq!(
            echo.notifications[0]["params"]["item"]["clientId"],
            "client-id"
        );
        let injected = t.handle(&json!({"type":"user","uuid":"injected-id","isMeta":true,"message":{"role":"user","content":"Hidden context"}}));
        assert!(injected.notifications.is_empty());
        let synthetic = t.handle(&json!({"type":"user","uuid":"skill-id","isSynthetic":true,"message":{"role":"user","content":"Base directory for this skill: /skills/audio"}}));
        assert!(
            synthetic.notifications.is_empty(),
            "stream-json context must not become a user bubble or voice input"
        );
    }

    #[test]
    fn tail_dispatch_metadata_preserves_authored_xml_identity() {
        let mut t = translator();
        let tail = "<realtime_delegation><source>transcript_tail_flush</source><input>The call ended.</input><transcript_delta>user: Goodbye</transcript_delta></realtime_delegation>";
        let nested =
            format!("<realtime_delegation>\n<input>{tail}</input>\n</realtime_delegation>");
        let synthetic = t.handle(&json!({"type":"user","uuid":"tail-id","isSynthetic":true,"message":{"role":"user","content":tail}}));
        assert!(synthetic.notifications.is_empty());
        let echo = t.handle(
            &json!({"type":"user","uuid":"authored-id","message":{"role":"user","content":tail}}),
        );
        let item = &echo.notifications[0]["params"]["item"];
        assert_eq!(item["id"], "authored-id");
        assert_eq!(item["clientId"], "authored-id");
        assert_eq!(item["content"][0]["text"], tail);
        assert_eq!(
            crate::providers::claude::timeline::user_prompt_text(Some(&json!(nested))).as_deref(),
            Some(nested.as_str())
        );
    }

    #[test]
    fn call_handoff_live_and_replay_show_speech_without_private_context() {
        let speech = "Please check Q&A";
        let text = crate::voice::handoff::envelope_with_call_context(
            &crate::voice::handoff::delegation_envelope(speech, &[]),
            "Private call brief and <input>implementation instructions</input>",
        )
        .unwrap();
        let mut t = translator();
        let echo = t.handle(
            &json!({"type":"user", "uuid":"call-input", "message":{"role":"user", "content":text}}),
        );
        assert_eq!(echo.notifications.len(), 1);
        assert_eq!(
            echo.notifications[0]["params"]["item"]["content"][0]["text"],
            speech
        );
        assert_eq!(
            crate::providers::claude::timeline::user_prompt_text(Some(&json!(text))).as_deref(),
            Some(speech)
        );
        assert!(
            !serde_json::to_string(&echo.notifications)
                .unwrap()
                .contains("Private call brief")
        );
    }

    #[test]
    fn subagent_traffic_is_dropped() {
        let mut t = translator();
        let out = t.handle(&json!({
            "type":"assistant",
            "parent_tool_use_id":"toolu_parent",
            "message":{"content":[{"type":"text","text":"inner"}]}
        }));

        assert!(out.notifications.is_empty());
    }

    #[test]
    fn an_interrupted_result_reports_interrupted_not_failed() {
        let mut t = translator();
        let out = t.handle(&json!({
            "type":"result","subtype":"error_during_execution","is_error":true,
            "terminal_reason":"aborted_streaming"
        }));

        let result = out.result.expect("result");
        assert_eq!(result.status, "interrupted");
        assert_eq!(result.error_message, None);
    }

    #[test]
    fn result_reports_completion_and_never_carries_cost() {
        let mut t = translator();
        let out = t.handle(&json!({
            "type":"result","subtype":"success","is_error":false,
            "total_cost_usd":0.89,"usage":{"input_tokens":4,"output_tokens":87}
        }));

        let result = out.result.expect("result");
        assert_eq!(result.status, "completed");

        let completed = t.turn_completed(
            &result.status,
            result.error_message.as_deref(),
            result.error_info,
        );
        let serialized = serde_json::to_string(&completed).expect("json");
        assert!(!serialized.contains("cost"));
        assert_eq!(completed["params"]["turn"]["status"], json!("completed"));
    }

    #[test]
    fn error_result_fails_the_turn_with_a_message() {
        let mut t = translator();
        let out = t.handle(&json!({
            "type":"result","subtype":"error_during_execution","is_error":true,
            "result":"exploded"
        }));

        let result = out.result.expect("result");
        assert_eq!(result.status, "failed");

        let completed = t.turn_completed(
            &result.status,
            result.error_message.as_deref(),
            result.error_info,
        );
        assert_eq!(
            completed["params"]["turn"]["error"]["message"],
            json!("exploded")
        );
        assert_eq!(
            completed["params"]["turn"]["error"]["codexErrorInfo"],
            Value::Null
        );
    }

    fn refusal(uuid: &str, category: &str) -> Value {
        json!({
            "type":"assistant","uuid":uuid,
            "message":{
                "id":format!("msg_{uuid}"),"model":"<synthetic>","role":"assistant",
                "stop_reason":"refusal","stop_sequence":"",
                "stop_details":{"type":"refusal","category":category,"explanation":"blocked"},
                "content":[{"type":"text","text":"API Error: safeguards flagged this session"}]
            }
        })
    }

    #[test]
    fn a_turn_that_fails_on_a_cyber_refusal_reports_cyber_policy() {
        let mut t = translator();
        t.handle(&refusal("r1", "cyber"));
        let out = t.handle(&json!({
            "type":"result","subtype":"success","is_error":true,
            "stop_reason":"refusal","result":"API Error: safeguards flagged this session"
        }));

        let result = out.result.expect("result");
        assert_eq!(result.status, "failed");
        let completed = t.turn_completed(
            &result.status,
            result.error_message.as_deref(),
            result.error_info,
        );
        assert_eq!(
            completed["params"]["turn"]["error"]["codexErrorInfo"],
            json!("cyberPolicy")
        );
        assert_eq!(
            completed["params"]["turn"]["error"]["message"],
            json!("API Error: safeguards flagged this session")
        );
    }

    #[test]
    fn a_refusal_the_retry_moved_past_is_not_the_turn_error() {
        let mut t = translator();
        t.handle(&refusal("r1", "cyber"));
        t.handle(&json!({
            "type":"assistant","uuid":"a2",
            "message":{"id":"msg_a2","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}
        }));
        let out = t.handle(&json!({
            "type":"result","subtype":"error_during_execution","is_error":true,"result":"exploded"
        }));

        assert_eq!(out.result.expect("result").error_info, None);
    }

    #[test]
    fn a_refusal_outside_the_cyber_category_has_no_protocol_code() {
        let mut t = translator();
        t.handle(&refusal("r1", "other"));
        let out = t.handle(&json!({
            "type":"result","subtype":"success","is_error":true,"result":"refused"
        }));

        assert_eq!(out.result.expect("result").error_info, None);
    }

    /// Replays a real captured `claude` stream (Bash tool + text reply) and pins
    /// the exact notification sequence the app receives.
    #[test]
    fn replaying_a_real_stream_emits_the_expected_notification_sequence() {
        let fixture = include_str!("../../../tests/fixtures/claude-stream-basic.jsonl");

        let mut t = TurnTranslator::new(
            "claude_11111111-2222-3333-4444-555555555555".to_string(),
            "turn-1".to_string(),
            "/repo".to_string(),
            Some(400_000),
            1_700_000_000_000,
            Arc::default(),
        );
        let mut emitted: Vec<Value> = Vec::new();
        let mut result: Option<TurnResult> = None;

        for line in fixture.lines().filter(|line| !line.trim().is_empty()) {
            let value: Value = serde_json::from_str(line).expect("fixture line is JSON");
            if value.get("subtype").and_then(Value::as_str) == Some("init") {
                assert!(
                    billing_violation(&value, false).is_none(),
                    "captured stream must be subscription-backed"
                );
            }
            let mut out = t.handle(&value);
            emitted.append(&mut out.notifications);
            if out.result.is_some() {
                result = out.result;
            }
        }

        assert_eq!(
            methods(&emitted),
            vec![
                // Reasoning row: opens empty, then its signed record completes it.
                "item/started",
                "item/completed",
                // Bash call, its usage tick, then its result.
                "item/started",
                "thread/tokenUsage/updated",
                "item/completed",
                // Final assistant message.
                "item/started",
                "item/agentMessage/delta",
                "item/completed",
                "thread/tokenUsage/updated",
                "thread/tokenUsage/updated",
            ]
        );

        let item_types: Vec<&str> = emitted
            .iter()
            .filter_map(|value| value["params"]["item"]["type"].as_str())
            .collect();
        assert_eq!(
            item_types,
            vec![
                "reasoning",
                "reasoning",
                "commandExecution",
                "commandExecution",
                "agentMessage",
                "agentMessage",
            ]
        );

        assert_eq!(
            emitted[1]["params"]["item"]["summary"],
            json!(["Thought for ~64 tokens"])
        );
        assert_eq!(emitted[0]["params"]["item"]["summary"], json!([]));

        // The tool item keeps the toolu_ id verbatim so live and history anchors agree.
        let command_item = &emitted[2]["params"]["item"];
        assert_eq!(command_item["id"], json!("toolu_018pBuxkXmNVSj9dSAABAkMz"));
        assert_eq!(command_item["command"], json!("echo hello"));
        assert_eq!(command_item["cwd"], "/repo");
        assert_eq!(command_item["status"], "inProgress");
        assert!(command_item["commandActions"].is_array());
        assert_eq!(
            emitted[4]["params"]["item"]["aggregatedOutput"],
            json!("hello")
        );
        assert_eq!(emitted[4]["params"]["item"]["status"], "completed");
        assert!(emitted[4]["params"]["item"]["exitCode"].is_null());
        assert_eq!(
            emitted[5]["params"]["item"]["id"],
            "msg_011Ce6WrAknxgVLTxw9b1fD9#0"
        );
        assert_eq!(emitted[6]["params"]["delta"], "done");
        assert_eq!(emitted[7]["params"]["item"]["text"], json!("done"));

        let terminal_usage = &emitted[9]["params"]["tokenUsage"];
        assert_eq!(terminal_usage["modelContextWindow"], json!(400_000));
        // The context meter reflects the final request's active context, not
        // the double-counted aggregate across every API request in the turn.
        assert_eq!(terminal_usage["last"]["totalTokens"], json!(42_261));

        assert_eq!(
            result.map(|result| result.status),
            Some("completed".to_string())
        );
    }
}
