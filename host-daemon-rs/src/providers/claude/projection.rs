mod cache;
pub(crate) use cache::{CacheOutcome, ProjectionCache};

use crate::providers::claude::capacity::{CapacityExceeded, MAX_PROVIDER_ID_BYTES, validate_id};
use crate::providers::claude::conversation_index::Index;
use crate::providers::claude::records::{
    LineKind, MAX_SESSION_RECORD_BYTES, SYNTHETIC_MODEL, read_bounded_line,
};
use crate::providers::claude::settings::ClaudeSettings;
use crate::providers::claude::timeline::{
    is_injected_user_record, queued_user_prompt, user_prompt_text,
};
use crate::providers::claude::translate::context_usage::token_usage_notification;
use crate::providers::claude::translate::narration::{narration_text, sent_message_text};
use crate::providers::claude::translate::tools::{
    ToolOutcome, tool_item, tool_result_images, tool_result_text,
};
use crate::providers::claude::translate::{agent_message_item, user_message_item};
use crate::time::parse_rfc3339_millis;
use anyhow::{Context, Result, anyhow, bail};
use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{BufReader, Read};
use std::ops::Range;
use std::os::unix::fs::FileExt;
use std::path::Path;

const DEFAULT_PAGE_SIZE: usize = 25;
const MAX_PAGE_SIZE: usize = 100;
pub(crate) const PROJECTION_CACHE_BUDGET_BYTES: usize = 32 * 1024 * 1024;
const RECORD_CACHE_BUDGET_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug)]
pub(crate) enum HistoryError {
    InvalidRequest(String),
    InvalidCursor(String),
    Internal(anyhow::Error),
    Capacity(CapacityExceeded),
}

impl From<anyhow::Error> for HistoryError {
    fn from(error: anyhow::Error) -> Self {
        match error.downcast_ref::<CapacityExceeded>() {
            Some(capacity) => Self::Capacity(*capacity),
            None => Self::Internal(error),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SortDirection {
    Asc,
    Desc,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ItemsView {
    NotLoaded,
    Summary,
    Full,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ItemsListParams {
    pub thread_id: String,
    pub turn_id: Option<String>,
    pub cursor: Option<String>,
    pub limit: Option<u32>,
    pub sort_direction: Option<SortDirection>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TurnsListParams {
    pub thread_id: String,
    pub cursor: Option<String>,
    pub limit: Option<u32>,
    pub sort_direction: Option<SortDirection>,
    pub items_view: Option<ItemsView>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ItemsCursor {
    thread_id: String,
    item_id: String,
    include_anchor: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TurnsCursor {
    turn_id: String,
    include_anchor: bool,
}

#[derive(Clone, Copy, Debug)]
struct Span {
    offset: u64,
    len: usize,
}

#[derive(Debug)]
struct ToolResult {
    record: Span,
    part: usize,
    completed_at_ms: Option<i64>,
}

#[derive(Debug)]
enum Source {
    Prompt(Span),
    Queued(Span),
    Text {
        record: Span,
        block: usize,
    },
    Tool {
        record: Span,
        block: usize,
        result: Option<ToolResult>,
    },
    Synthetic(Value),
}

impl Source {
    fn is_user_message(&self) -> bool {
        matches!(self, Source::Prompt(_) | Source::Queued(_))
    }

    fn spans(&self) -> impl Iterator<Item = Span> {
        let (record, result) = match self {
            Source::Prompt(span) | Source::Queued(span) => (Some(*span), None),
            Source::Text { record, .. } => (Some(*record), None),
            Source::Tool { record, result, .. } => {
                (Some(*record), result.as_ref().map(|result| result.record))
            }
            Source::Synthetic(_) => (None, None),
        };
        record.into_iter().chain(result)
    }
}

#[derive(Debug)]
struct Identity {
    ordinal: i64,
    started_at_ms: i64,
    completed_at_ms: Option<i64>,
    is_complete: bool,
    client_id: Option<String>,
}

#[derive(Debug)]
struct Item {
    id: String,
    turn: usize,
    source: Source,
    started_at_ms: Option<i64>,
    completed_at_ms: Option<i64>,
    identity: Option<Identity>,
}

#[derive(Debug)]
struct Turn {
    id: String,
    items: Range<usize>,
    status: String,
    started_at_ms: Option<i64>,
    completed_at_ms: Option<i64>,
}

#[derive(Debug)]
struct LatestUsage {
    usage: Value,
    turn_id: String,
}

#[derive(Debug)]
pub(crate) struct Projection {
    items: Vec<Item>,
    turns: Vec<Turn>,
    item_positions: HashMap<String, usize>,
    turn_positions: HashMap<String, usize>,
    cwd: Option<String>,
    latest_usage: Option<LatestUsage>,
    length: u64,
}

#[derive(Debug)]
pub(crate) struct ForkPoint {
    pub length: u64,
    pub turns: HashSet<String>,
}

struct Row {
    id: String,
    source: Source,
    started_at_ms: Option<i64>,
    completed_at_ms: Option<i64>,
    sequence: usize,
}

struct Draft {
    started_at_ms: Option<i64>,
    last_seen_ms: Option<i64>,
    rows: Vec<Row>,
}

impl Draft {
    fn new(started_at_ms: Option<i64>) -> Self {
        Self {
            started_at_ms,
            last_seen_ms: started_at_ms,
            rows: Vec::new(),
        }
    }

    fn saw(&mut self, timestamp_ms: Option<i64>) {
        if timestamp_ms.is_some() {
            self.last_seen_ms = timestamp_ms;
        }
    }
}

struct Group {
    rows: Vec<Row>,
    started_at_ms: Option<i64>,
    last_seen_ms: Option<i64>,
}

#[derive(Default)]
struct Scan {
    drafts: Vec<Draft>,
    tool_results: HashMap<String, ToolResult>,
    cwd: Option<String>,
    latest_usage: Option<(Value, usize)>,
    rows: usize,
    length: u64,
}

impl Scan {
    fn current(&mut self, timestamp_ms: Option<i64>) -> &mut Draft {
        if self.drafts.is_empty() {
            self.drafts.push(Draft::new(timestamp_ms));
        }
        let last = self.drafts.len() - 1;
        &mut self.drafts[last]
    }

    fn push_row(&mut self, id: String, source: Source, timestamp_ms: Option<i64>) {
        let sequence = self.rows;
        self.rows += 1;
        let completed_at_ms = match source {
            Source::Tool { .. } => None,
            _ => timestamp_ms,
        };
        self.current(timestamp_ms).rows.push(Row {
            id,
            source,
            started_at_ms: timestamp_ms,
            completed_at_ms,
            sequence,
        });
    }

    fn apply(&mut self, record: &Value, span: Span, block_offsets: &mut HashMap<String, usize>) {
        let timestamp_ms = record
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(parse_rfc3339_millis);
        if self.cwd.is_none()
            && let Some(cwd) = record.get("cwd").and_then(Value::as_str)
        {
            self.cwd = Some(cwd.to_string());
        }
        match record.get("type").and_then(Value::as_str) {
            Some("user") => self.apply_user(record, span, timestamp_ms),
            Some("attachment") => {
                let Some((_, source_id)) = queued_user_prompt(record) else {
                    return;
                };
                let source_id = source_id.to_string();
                self.current(timestamp_ms).saw(timestamp_ms);
                self.push_row(source_id, Source::Queued(span), timestamp_ms);
            }
            Some("assistant")
                if record.pointer("/message/model").and_then(Value::as_str)
                    == Some(SYNTHETIC_MODEL) => {}
            Some("assistant") => self.apply_assistant(record, span, timestamp_ms, block_offsets),
            _ => {}
        }
    }

    fn apply_user(&mut self, record: &Value, span: Span, timestamp_ms: Option<i64>) {
        let content = record.pointer("/message/content");
        if is_injected_user_record(record, content) {
            self.current(timestamp_ms);
            return;
        }
        if user_prompt_text(content).is_some() {
            self.drafts.push(Draft::new(timestamp_ms));
            if let Some(id) = record.get("uuid").and_then(Value::as_str) {
                self.push_row(id.to_string(), Source::Prompt(span), timestamp_ms);
            }
            return;
        }
        let Some(draft) = self.drafts.last_mut() else {
            return;
        };
        draft.saw(timestamp_ms);
        for (part_index, part) in content
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .enumerate()
        {
            if part.get("type").and_then(Value::as_str) != Some("tool_result") {
                continue;
            }
            if let Some(tool_use_id) = part.get("tool_use_id").and_then(Value::as_str) {
                self.tool_results.insert(
                    tool_use_id.to_string(),
                    ToolResult {
                        record: span,
                        part: part_index,
                        completed_at_ms: timestamp_ms,
                    },
                );
            }
        }
    }

    fn apply_assistant(
        &mut self,
        record: &Value,
        span: Span,
        timestamp_ms: Option<i64>,
        block_offsets: &mut HashMap<String, usize>,
    ) {
        let usage = record.pointer("/message/usage").cloned();
        if !self.drafts.is_empty() {
            self.current(timestamp_ms).saw(timestamp_ms);
            let blocks = record
                .pointer("/message/content")
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or_default();
            let provider_id = record.pointer("/message/id").and_then(Value::as_str);
            let first_block = provider_id.map_or(0, |id| {
                let offset = block_offsets.entry(id.to_string()).or_default();
                let first = *offset;
                *offset += blocks.len();
                first
            });
            for (block, value) in blocks.iter().enumerate() {
                match value.get("type").and_then(Value::as_str) {
                    Some(kind @ ("text" | "thinking"))
                        if kind == "text" || narration_text(value).is_some() =>
                    {
                        if let Some(id) = provider_id {
                            self.push_row(
                                format!("{id}#{}", first_block + block),
                                Source::Text {
                                    record: span,
                                    block,
                                },
                                timestamp_ms,
                            );
                        }
                    }
                    Some("tool_use") => {
                        let Some(id) = value.get("id").and_then(Value::as_str) else {
                            continue;
                        };
                        if sent_message_text(value).is_some() {
                            self.push_row(
                                id.to_string(),
                                Source::Text {
                                    record: span,
                                    block,
                                },
                                timestamp_ms,
                            );
                            continue;
                        }
                        if value.get("name").and_then(Value::as_str) == Some("TodoWrite") {
                            continue;
                        }
                        self.push_row(
                            id.to_string(),
                            Source::Tool {
                                record: span,
                                block,
                                result: None,
                            },
                            timestamp_ms,
                        );
                    }
                    _ => {}
                }
            }
        }
        if let Some(usage) = usage {
            self.latest_usage = Some((usage, self.rows));
        }
    }
}

impl Projection {
    pub(crate) fn build(
        file: &File,
        length: u64,
        index: &Index,
        active_turn: Option<&str>,
    ) -> Result<Self> {
        let scan = scan(file, length)?;
        Ok(project(scan, index, active_turn))
    }

    pub(crate) fn estimated_bytes(&self) -> usize {
        let items: usize = self
            .items
            .iter()
            .map(|item| {
                (std::mem::size_of::<Item>()
                    + 2 * item.id.len()
                    + std::mem::size_of::<(String, usize)>()
                    + item
                        .identity
                        .as_ref()
                        .and_then(|identity| identity.client_id.as_ref())
                        .map_or(0, String::len))
                .saturating_add(match &item.source {
                    Source::Synthetic(value) => crate::wire::json::encoded_len(value)
                        .map_or(usize::MAX, |bytes| bytes.saturating_mul(2)),
                    _ => 0,
                })
            })
            .fold(0usize, usize::saturating_add);
        let turns: usize = self
            .turns
            .iter()
            .map(|turn| {
                std::mem::size_of::<Turn>()
                    + 2 * turn.id.len()
                    + turn.status.len()
                    + std::mem::size_of::<(String, usize)>()
            })
            .sum();
        let usage = self.latest_usage.as_ref().map_or(0, |latest| {
            crate::wire::json::encoded_len(&latest.usage).map_or(usize::MAX, |bytes| {
                bytes.saturating_mul(2).saturating_add(latest.turn_id.len())
            })
        });
        std::mem::size_of::<Self>()
            .saturating_add(items)
            .saturating_add(turns)
            .saturating_add(usage)
    }

    pub(crate) fn fork_point(&self, through_turn: Option<&str>) -> Result<ForkPoint, HistoryError> {
        let running = self
            .turns
            .iter()
            .position(|turn| turn.status == "inProgress");
        let unfinished = |position: usize| {
            HistoryError::InvalidRequest(format!(
                "Claude turn {} is still running; fork from a finished turn before it",
                self.turns[position].id
            ))
        };
        let last = match through_turn {
            Some(turn_id) => {
                let position = *self.turn_positions.get(turn_id).ok_or_else(|| {
                    HistoryError::InvalidRequest(format!(
                        "turn {turn_id} is not in this Claude conversation"
                    ))
                })?;
                if let Some(running) = running.filter(|running| *running <= position) {
                    return Err(unfinished(running));
                }
                position
            }
            None => running
                .unwrap_or(self.turns.len())
                .checked_sub(1)
                .ok_or_else(|| {
                    HistoryError::InvalidRequest(
                        "This Claude conversation has no finished turn to fork".to_string(),
                    )
                })?,
        };
        let (kept, later) = self.items.split_at(self.turns[last].items.end);
        let length = if last + 1 == self.turns.len() {
            self.length
        } else {
            let kept_end = kept
                .iter()
                .flat_map(|item| item.source.spans())
                .map(|span| span.offset + span.len as u64)
                .max()
                .unwrap_or(0);
            let later_start = later
                .iter()
                .flat_map(|item| item.source.spans())
                .map(|span| span.offset)
                .min();
            if later_start.is_some_and(|later_start| kept_end > later_start) {
                return Err(HistoryError::InvalidRequest(format!(
                    "Claude turn {} ends after a later turn begins; fork from another turn",
                    self.turns[last].id
                )));
            }
            kept_end
        };
        if length == 0 {
            return Err(HistoryError::InvalidRequest(format!(
                "Claude turn {} has no conversation records to fork",
                self.turns[last].id
            )));
        }
        Ok(ForkPoint {
            length,
            turns: self.turns[..=last]
                .iter()
                .map(|turn| turn.id.clone())
                .collect(),
        })
    }

    pub(crate) fn token_usage_replay(
        &self,
        thread_id: &str,
        settings: &ClaudeSettings,
    ) -> Option<Value> {
        let latest = self.latest_usage.as_ref()?;
        let window = self
            .cwd
            .as_deref()
            .and_then(|cwd| settings.auto_compact_window(Path::new(cwd)));
        token_usage_notification(thread_id, &latest.turn_id, &latest.usage, window)
    }

    pub(crate) fn items_page(
        &self,
        file: &File,
        params: &ItemsListParams,
    ) -> Result<Value, HistoryError> {
        let cursor = params
            .cursor
            .as_deref()
            .map(|cursor| {
                serde_json::from_str::<ItemsCursor>(cursor)
                    .ok()
                    .filter(|parsed| parsed.thread_id == params.thread_id)
                    .ok_or_else(|| invalid_cursor(cursor))
            })
            .transpose()?;
        let positions = match params.turn_id.as_deref() {
            None => 0..self.items.len(),
            Some(turn_id) => self
                .turn_positions
                .get(turn_id)
                .map_or(0..0, |turn| self.turns[*turn].items.clone()),
        };
        let anchor = cursor
            .as_ref()
            .map(|cursor| {
                self.item_positions
                    .get(&cursor.item_id)
                    .filter(|position| positions.contains(position))
                    .map(|anchor| (*anchor, cursor.include_anchor))
                    .ok_or_else(|| {
                        HistoryError::InvalidCursor(
                            "invalid cursor: anchor item is no longer present".to_string(),
                        )
                    })
            })
            .transpose()?;
        let page = paginate(
            positions,
            anchor,
            params.limit,
            params.sort_direction.unwrap_or(SortDirection::Asc),
        );
        let cursor_for = |position: usize, include_anchor: bool| {
            serde_json::to_string(&ItemsCursor {
                thread_id: params.thread_id.clone(),
                item_id: self.items[position].id.clone(),
                include_anchor,
            })
            .context("failed to serialize cursor")
        };
        let backwards_cursor = page
            .selected
            .first()
            .map(|position| cursor_for(*position, true))
            .transpose()?;
        let next_cursor = page
            .has_more
            .then(|| {
                page.selected
                    .last()
                    .map(|position| cursor_for(*position, false))
            })
            .flatten()
            .transpose()?;
        let mut records = RecordReader::new(file);
        let data = page
            .selected
            .iter()
            .map(|position| self.entry(*position, &mut records))
            .collect::<Result<Vec<_>>>()?;
        Ok(json!({
            "data": data,
            "nextCursor": next_cursor,
            "backwardsCursor": backwards_cursor,
        }))
    }

    pub(crate) fn turns_page(
        &self,
        file: &File,
        params: &TurnsListParams,
    ) -> Result<Value, HistoryError> {
        if self.turns.is_empty() {
            return Ok(json!({ "data": [], "nextCursor": null, "backwardsCursor": null }));
        }
        let anchor = params
            .cursor
            .as_deref()
            .map(|cursor| {
                let parsed = serde_json::from_str::<TurnsCursor>(cursor)
                    .map_err(|_| invalid_cursor(cursor))?;
                self.turn_positions
                    .get(&parsed.turn_id)
                    .map(|anchor| (*anchor, parsed.include_anchor))
                    .ok_or_else(|| {
                        HistoryError::InvalidCursor(
                            "invalid cursor: anchor turn is no longer present".to_string(),
                        )
                    })
            })
            .transpose()?;
        let page = paginate(
            0..self.turns.len(),
            anchor,
            params.limit,
            params.sort_direction.unwrap_or(SortDirection::Desc),
        );
        let cursor_for = |position: usize, include_anchor: bool| {
            serde_json::to_string(&TurnsCursor {
                turn_id: self.turns[position].id.clone(),
                include_anchor,
            })
            .context("failed to serialize cursor")
        };
        let backwards_cursor = page
            .selected
            .first()
            .map(|position| cursor_for(*position, true))
            .transpose()?;
        let next_cursor = page
            .has_more
            .then(|| {
                page.selected
                    .last()
                    .map(|position| cursor_for(*position, false))
            })
            .flatten()
            .transpose()?;
        let view = params.items_view.unwrap_or(ItemsView::Summary);
        let mut records = RecordReader::new(file);
        let data = page
            .selected
            .iter()
            .map(|position| self.turn(*position, view, &mut records))
            .collect::<Result<Vec<_>>>()?;
        Ok(json!({
            "data": data,
            "nextCursor": next_cursor,
            "backwardsCursor": backwards_cursor,
        }))
    }

    pub(crate) fn thread_turns(
        &self,
        file: &File,
        budget_bytes: usize,
    ) -> Result<Vec<Value>, HistoryError> {
        let exceeded = || {
            HistoryError::Capacity(CapacityExceeded {
                resource: "thread/read turn bytes",
                limit: budget_bytes,
            })
        };
        let mut records = RecordReader::new(file);
        let mut remaining = budget_bytes;
        let mut turns = Vec::with_capacity(self.turns.len());
        for (position, turn) in self.turns.iter().enumerate() {
            let mut items = Vec::with_capacity(turn.items.len());
            let mut item_bytes = 0;
            for item_position in turn.items.clone() {
                let item = self.item_value(item_position, &mut records)?;
                item_bytes +=
                    crate::wire::json::encoded_len_at_most(&item, remaining - item_bytes)?
                        .ok_or_else(exceeded)?;
                items.push(item);
            }
            let turn = self.turn_value(position, ItemsView::Full, items);
            remaining -=
                crate::wire::json::encoded_len_at_most(&turn, remaining)?.ok_or_else(exceeded)?;
            turns.push(turn);
        }
        Ok(turns)
    }

    fn turn(&self, position: usize, view: ItemsView, records: &mut RecordReader) -> Result<Value> {
        let turn = &self.turns[position];
        let positions: Vec<usize> = match view {
            ItemsView::NotLoaded => Vec::new(),
            ItemsView::Full => turn.items.clone().collect(),
            ItemsView::Summary => {
                let first_user = turn
                    .items
                    .clone()
                    .find(|item| self.items[*item].source.is_user_message());
                let last_agent = turn
                    .items
                    .clone()
                    .rev()
                    .find(|item| matches!(self.items[*item].source, Source::Text { .. }));
                first_user.into_iter().chain(last_agent).collect()
            }
        };
        let items = positions
            .into_iter()
            .map(|item| self.item_value(item, records))
            .collect::<Result<Vec<_>>>()?;
        Ok(self.turn_value(position, view, items))
    }

    fn turn_value(&self, position: usize, view: ItemsView, items: Vec<Value>) -> Value {
        let turn = &self.turns[position];
        let items_view = match view {
            ItemsView::NotLoaded => "notLoaded",
            ItemsView::Summary => "summary",
            ItemsView::Full => "full",
        };
        let duration_ms = turn
            .started_at_ms
            .zip(turn.completed_at_ms)
            .map(|(started, completed)| (completed - started).max(0));
        json!({
            "id": turn.id,
            "items": items,
            "itemsView": items_view,
            "status": turn.status,
            "error": null,
            "startedAt": turn.started_at_ms.map(|ms| ms.div_euclid(1000)),
            "completedAt": turn.completed_at_ms.map(|ms| ms.div_euclid(1000)),
            "durationMs": duration_ms,
        })
    }

    fn entry(&self, position: usize, records: &mut RecordReader) -> Result<Value> {
        let item = &self.items[position];
        let mut entry = Map::new();
        match &item.identity {
            Some(identity) => {
                entry.insert("startedAtOrdinal".into(), json!(identity.ordinal));
                entry.insert("startedAtMs".into(), json!(identity.started_at_ms));
            }
            None => {
                if let Some(started_at_ms) = item.started_at_ms {
                    entry.insert("startedAtMs".into(), json!(started_at_ms));
                }
            }
        }
        let completed_at_ms = item
            .identity
            .as_ref()
            .and_then(|identity| identity.completed_at_ms)
            .or(item.completed_at_ms);
        if let Some(completed_at_ms) = completed_at_ms {
            entry.insert("completedAtMs".into(), json!(completed_at_ms));
        }
        let is_complete = match &item.source {
            Source::Synthetic(_) => item
                .identity
                .as_ref()
                .is_some_and(|identity| identity.is_complete),
            Source::Tool { result, .. } => result.is_some(),
            _ => true,
        };
        entry.insert("isComplete".into(), json!(is_complete));
        entry.insert("turnId".into(), json!(self.turns[item.turn].id));
        entry.insert("item".into(), self.item_value(position, records)?);
        Ok(Value::Object(entry))
    }

    fn item_value(&self, position: usize, records: &mut RecordReader) -> Result<Value> {
        let item = &self.items[position];
        let mut value = match &item.source {
            Source::Prompt(span) => {
                let record = records.read(*span)?;
                let text = user_prompt_text(record.pointer("/message/content"))
                    .ok_or_else(|| changed(&item.id))?;
                user_message_item(&item.id, &text, record.pointer("/message/content"))
            }
            Source::Queued(span) => {
                let record = records.read(*span)?;
                let (text, source_id) =
                    queued_user_prompt(record).ok_or_else(|| changed(&item.id))?;
                if source_id != item.id {
                    return Err(changed(&item.id));
                }
                user_message_item(&item.id, &text, record.pointer("/attachment/prompt"))
            }
            Source::Text { record, block } => {
                let block = records
                    .read(*record)?
                    .pointer(&format!("/message/content/{block}"))
                    .ok_or_else(|| changed(&item.id))?;
                let text = match block.get("type").and_then(Value::as_str) {
                    Some("text") => block
                        .get("text")
                        .and_then(Value::as_str)
                        .unwrap_or_default(),
                    _ => narration_text(block)
                        .or_else(|| sent_message_text(block))
                        .ok_or_else(|| changed(&item.id))?,
                };
                agent_message_item(&item.id, text)
            }
            Source::Tool {
                record,
                block,
                result,
            } => self.tool_value(item, *record, *block, result.as_ref(), records)?,
            Source::Synthetic(value) => value.clone(),
        };
        if let Some(client_id) = item
            .identity
            .as_ref()
            .and_then(|identity| identity.client_id.as_ref())
            && item.source.is_user_message()
        {
            value["clientId"] = json!(client_id);
        }
        Ok(value)
    }

    fn tool_value(
        &self,
        item: &Item,
        record: Span,
        block: usize,
        result: Option<&ToolResult>,
        records: &mut RecordReader,
    ) -> Result<Value> {
        let tool_use = records
            .read(record)?
            .pointer(&format!("/message/content/{block}"))
            .filter(|block| block.get("id").and_then(Value::as_str) == Some(item.id.as_str()))
            .ok_or_else(|| changed(&item.id))?;
        let name = tool_use
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let mut input = tool_use.get("input").cloned().unwrap_or_else(|| json!({}));
        crate::agents::mcp::remove_notification_permit(&mut input);
        let outcome = match result {
            None => ToolOutcome::InProgress,
            Some(result) => {
                let record = records.read(result.record)?;
                let part = record
                    .pointer(&format!("/message/content/{}", result.part))
                    .filter(|part| {
                        part.get("tool_use_id").and_then(Value::as_str) == Some(item.id.as_str())
                    })
                    .ok_or_else(|| changed(&item.id))?;
                ToolOutcome::Finished {
                    is_error: part
                        .get("is_error")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    result_text: tool_result_text(part),
                    images: tool_result_images(part),
                    tool_use_result: record.get("toolUseResult").cloned(),
                    duration_ms: item
                        .started_at_ms
                        .zip(result.completed_at_ms)
                        .map(|(started, completed)| (completed - started).max(0)),
                }
            }
        };
        Ok(tool_item(
            &item.id,
            &name,
            &input,
            self.cwd.as_deref().unwrap_or_default(),
            outcome,
        ))
    }
}

fn validate_record_ids(record: &Value) -> Result<()> {
    for pointer in ["/uuid", "/message/id", "/attachment/source_uuid"] {
        if let Some(id) = record.pointer(pointer).and_then(Value::as_str) {
            validate_id(id, "historical provider ID bytes", MAX_PROVIDER_ID_BYTES)?;
        }
    }
    for block in record
        .pointer("/message/content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let key = match block.get("type").and_then(Value::as_str) {
            Some("tool_use") => "id",
            Some("tool_result") => "tool_use_id",
            _ => continue,
        };
        if let Some(id) = block.get(key).and_then(Value::as_str) {
            validate_id(id, "historical provider ID bytes", MAX_PROVIDER_ID_BYTES)?;
        }
    }
    Ok(())
}

fn scan(file: &File, length: u64) -> Result<Scan> {
    let mut reader = BufReader::new(file.take(length));
    let mut scan = Scan::default();
    let mut block_offsets = HashMap::new();
    let mut seen_records = HashSet::new();
    let mut line = Vec::new();
    let mut offset = 0u64;
    loop {
        line.clear();
        let (read, kind) = read_bounded_line(&mut reader, &mut line, MAX_SESSION_RECORD_BYTES)
            .context("failed reading Claude session")?;
        let span = Span {
            offset,
            len: line.len(),
        };
        match kind {
            LineKind::Complete => {}
            LineKind::Partial => break,
            LineKind::Oversized => bail!(
                "a Claude session record at byte {offset} is larger than {MAX_SESSION_RECORD_BYTES} bytes"
            ),
        }
        offset += read;
        scan.length = offset;
        let Ok(record) = serde_json::from_slice::<Value>(&line) else {
            continue;
        };
        validate_record_ids(&record)?;
        if let Some(id) = record.get("uuid").and_then(Value::as_str)
            && !seen_records.insert(id.to_string())
        {
            continue;
        }
        if record.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        scan.apply(&record, span, &mut block_offsets);
    }
    Ok(scan)
}

fn project(mut scan: Scan, index: &Index, active_turn: Option<&str>) -> Projection {
    for draft in &mut scan.drafts {
        for row in &mut draft.rows {
            if let Source::Tool { result, .. } = &mut row.source {
                *result = scan.tool_results.remove(&row.id);
                row.completed_at_ms = result.as_ref().and_then(|result| result.completed_at_ms);
            }
        }
    }
    let usage_rows = scan.latest_usage.as_ref().map(|(_, rows)| *rows);
    let mut usage_turn: Option<String> = None;
    let mut groups = IndexMap::<String, Group>::new();
    let mut seen = HashSet::new();
    let trailing = scan.drafts.len().saturating_sub(1);
    for (position, draft) in scan.drafts.into_iter().enumerate() {
        let legacy_id = format!("claude-turn-{}", position + 1);
        let running = active_turn.filter(|_| position == trailing);
        let last_indexed = draft
            .rows
            .iter()
            .rposition(|row| index.items.contains_key(&row.id));
        let mut preceding: Option<String> = None;
        for (row_position, row) in draft.rows.into_iter().enumerate() {
            if !seen.insert(row.id.clone()) {
                continue;
            }
            let turn_id = match index.items.get(&row.id) {
                Some(identity) => {
                    preceding = Some(identity.turn_id.clone());
                    identity.turn_id.clone()
                }
                None => match running {
                    Some(running) if last_indexed.is_none_or(|last| row_position > last) => {
                        running.to_string()
                    }
                    _ => preceding.clone().unwrap_or_else(|| legacy_id.clone()),
                },
            };
            if usage_rows.is_some_and(|rows| row.sequence < rows) || usage_turn.is_none() {
                usage_turn = Some(turn_id.clone());
            }
            let group = groups.entry(turn_id).or_insert_with(|| Group {
                rows: Vec::new(),
                started_at_ms: draft.started_at_ms,
                last_seen_ms: None,
            });
            group.last_seen_ms = group.last_seen_ms.max(draft.last_seen_ms);
            group.rows.push(row);
        }
    }
    let mut synthetic = index
        .items
        .values()
        .filter(|item| item.synthetic_item.is_some() && !seen.contains(&item.id))
        .collect::<Vec<_>>();
    synthetic.sort_by_key(|item| item.started_at_ordinal);
    for item in synthetic {
        let Some(value) = item.synthetic_item.clone() else {
            continue;
        };
        let row = Row {
            id: item.id.clone(),
            source: Source::Synthetic(value),
            started_at_ms: None,
            completed_at_ms: None,
            sequence: usize::MAX,
        };
        if let Some(group) = groups.get_mut(&item.turn_id) {
            group.rows.push(row);
            continue;
        }
        let later = groups
            .values()
            .position(|group| {
                first_ordinal(group, index).is_some_and(|first| first > item.started_at_ordinal)
            })
            .unwrap_or(groups.len());
        groups.shift_insert(
            later,
            item.turn_id.clone(),
            Group {
                rows: vec![row],
                started_at_ms: None,
                last_seen_ms: None,
            },
        );
    }
    if let Some(active_turn) = active_turn
        && !groups.contains_key(active_turn)
    {
        groups.insert(
            active_turn.to_string(),
            Group {
                rows: Vec::new(),
                started_at_ms: None,
                last_seen_ms: None,
            },
        );
    }

    let mut items = Vec::new();
    let mut turns = Vec::with_capacity(groups.len());
    for (turn_position, (id, group)) in groups.into_iter().enumerate() {
        let start = items.len();
        for row in ordered_by_index(group.rows, index) {
            let identity = index.items.get(&row.id).map(|identity| Identity {
                ordinal: identity.started_at_ordinal,
                started_at_ms: identity.started_at_ms,
                completed_at_ms: identity.completed_at_ms,
                is_complete: identity.is_complete,
                client_id: identity.client_id.clone(),
            });
            items.push(Item {
                id: row.id,
                turn: turn_position,
                source: row.source,
                started_at_ms: row.started_at_ms,
                completed_at_ms: row.completed_at_ms,
                identity,
            });
        }
        let metadata = index.turns.get(&id);
        let running = active_turn == Some(id.as_str());
        let status = if running {
            "inProgress".to_string()
        } else {
            match metadata {
                Some(turn) if turn.status == "inProgress" => "interrupted".to_string(),
                Some(turn) => turn.status.clone(),
                None => "completed".to_string(),
            }
        };
        let started_at_ms = metadata
            .map(|turn| turn.started_at_ms)
            .filter(|started| *started > 0)
            .or(group.started_at_ms);
        let completed_at_ms = match (running, metadata) {
            (true, _) => None,
            (false, Some(turn)) => turn.completed_at_ms,
            (false, None) => group.last_seen_ms,
        };
        turns.push(Turn {
            id,
            items: start..items.len(),
            status,
            started_at_ms,
            completed_at_ms,
        });
    }
    let latest_usage = scan.latest_usage.and_then(|(usage, _)| {
        let turn_id = usage_turn.or_else(|| {
            turns
                .iter()
                .rev()
                .find(|turn| matches!(turn.status.as_str(), "completed" | "failed"))
                .or(turns.last())
                .map(|turn| turn.id.clone())
        })?;
        Some(LatestUsage { usage, turn_id })
    });
    let item_positions = items
        .iter()
        .enumerate()
        .map(|(position, item)| (item.id.clone(), position))
        .collect();
    let turn_positions = turns
        .iter()
        .enumerate()
        .map(|(position, turn)| (turn.id.clone(), position))
        .collect();
    Projection {
        items,
        turns,
        item_positions,
        turn_positions,
        cwd: scan.cwd,
        latest_usage,
        length: scan.length,
    }
}

fn first_ordinal(group: &Group, index: &Index) -> Option<i64> {
    group
        .rows
        .iter()
        .filter_map(|row| index.items.get(&row.id))
        .map(|identity| identity.started_at_ordinal)
        .min()
}

fn ordered_by_index(rows: Vec<Row>, index: &Index) -> Vec<Row> {
    let slots = rows
        .iter()
        .enumerate()
        .filter(|(_, row)| index.items.contains_key(&row.id))
        .map(|(slot, _)| slot)
        .collect::<Vec<_>>();
    let mut sorted = slots.clone();
    sorted.sort_by_key(|slot| {
        index
            .items
            .get(&rows[*slot].id)
            .map(|identity| identity.started_at_ordinal)
    });
    let mut order = (0..rows.len()).collect::<Vec<_>>();
    for (slot, source) in slots.into_iter().zip(sorted) {
        order[slot] = source;
    }
    let mut rows = rows.into_iter().map(Some).collect::<Vec<_>>();
    order
        .into_iter()
        .filter_map(|position| rows[position].take())
        .collect()
}

struct Page {
    selected: Vec<usize>,
    has_more: bool,
}

fn paginate(
    positions: Range<usize>,
    anchor: Option<(usize, bool)>,
    limit: Option<u32>,
    direction: SortDirection,
) -> Page {
    let page_size = limit
        .map(|limit| limit as usize)
        .unwrap_or(DEFAULT_PAGE_SIZE)
        .clamp(1, MAX_PAGE_SIZE);
    let remaining = match (direction, anchor) {
        (_, None) => positions,
        (SortDirection::Asc, Some((anchor, true))) => anchor..positions.end,
        (SortDirection::Asc, Some((anchor, false))) => anchor + 1..positions.end,
        (SortDirection::Desc, Some((anchor, true))) => positions.start..anchor + 1,
        (SortDirection::Desc, Some((anchor, false))) => positions.start..anchor,
    };
    let has_more = remaining.len() > page_size;
    let selected = match direction {
        SortDirection::Asc => remaining.take(page_size).collect(),
        SortDirection::Desc => remaining.rev().take(page_size).collect(),
    };
    Page { selected, has_more }
}

fn invalid_cursor(cursor: &str) -> HistoryError {
    HistoryError::InvalidCursor(format!("invalid cursor: {cursor}"))
}

fn changed(item_id: &str) -> anyhow::Error {
    anyhow!("Claude session changed while item {item_id} was read; retry the page")
}

struct RecordReader<'a> {
    file: &'a File,
    records: HashMap<u64, Value>,
    cached_bytes: usize,
}

impl<'a> RecordReader<'a> {
    fn new(file: &'a File) -> Self {
        Self {
            file,
            records: HashMap::new(),
            cached_bytes: 0,
        }
    }

    fn read(&mut self, span: Span) -> Result<&Value> {
        if !self.records.contains_key(&span.offset) {
            if span.len > RECORD_CACHE_BUDGET_BYTES.saturating_sub(self.cached_bytes) {
                self.records.clear();
                self.cached_bytes = 0;
            }
            let mut bytes = vec![0; span.len];
            self.file
                .read_exact_at(&mut bytes, span.offset)
                .context("failed reading Claude session record")?;
            let record = serde_json::from_slice(&bytes)
                .map_err(|_| anyhow!("Claude session changed while it was read; retry the page"))?;
            self.records.insert(span.offset, record);
            self.cached_bytes += span.len;
        }
        self.records
            .get(&span.offset)
            .context("Claude session record cache lost a record")
    }
}

#[cfg(test)]
mod tests;
