//! Best-effort turn review for both providers. No work queues; the thread
//! itself writes the new title through a side question on its warm prompt cache.
use super::Gateway;
use crate::providers::claude::{
    is_claude_thread_id,
    projection::{ItemsListParams, TurnsListParams},
};
use crate::providers::router::RouterConfig;
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};
use crate::tasks::owned_tasks::OwnedTasks;
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::sync::{Arc, Weak, atomic::Ordering};

mod done;
mod early_title;
mod judge;
mod titles;
mod trace;
use judge::{JudgeApi, Questions};
use tokio::sync::Semaphore;
use trace::Trace;

use titles::{MAX_TITLE_CHARACTERS, THRESHOLD};
// About 24k tokens for ordinary prose, leaving room for the questions.
const MAX_CONTEXT_BYTES: usize = 96 * 1024;
const MAX_BUFFER_BYTES: usize = 512 * 1024;
const MAX_USER_GOAL_BYTES: usize = 8 * 1024;
const MAX_HISTORY_PAGES: usize = 400;

pub(super) struct Runtime {
    gateway: Weak<Gateway>,
    router: Option<RouterConfig>,
    budget: Arc<Semaphore>,
    early_titles: Arc<Semaphore>,
    tasks: OwnedTasks,
}

impl Runtime {
    pub(super) fn new(gateway: Weak<Gateway>, router: Option<RouterConfig>) -> Self {
        Self {
            gateway,
            router,
            budget: Arc::new(Semaphore::new(1)),
            early_titles: Arc::new(Semaphore::new(early_title::MAX_PENDING)),
            tasks: OwnedTasks::default(),
        }
    }

    pub(super) fn ingest(&self, message: &Value, is_new: bool) {
        if !is_new {
            return;
        }
        let method = message["method"].as_str().unwrap_or_default();
        if method == "turn/started" {
            self.schedule_early_title(message);
        }
        if method != "turn/completed" {
            return;
        }
        let Some(thread) = message.pointer("/params/threadId").and_then(Value::as_str) else {
            return;
        };
        let Some(turn) = message.pointer("/params/turn/id").and_then(Value::as_str) else {
            return;
        };
        let Some(gateway) = self.gateway.upgrade() else {
            return;
        };
        let mut trace = gateway.review_trace(thread, turn);
        trace.event(
            "completion",
            json!({"turnStatus":message.pointer("/params/turn/status")}),
        );
        if message
            .pointer("/params/turn/status")
            .and_then(Value::as_str)
            != Some("completed")
        {
            trace.finish("skipped", "turnNotCompleted");
            return;
        }
        let Some(router) = self.router.clone() else {
            trace.finish("skipped", "routerNotConfigured");
            return;
        };
        let Ok(permit) = Arc::clone(&self.budget).try_acquire_owned() else {
            trace.finish("skipped", "hostBusy");
            return;
        };
        let thread = thread.to_owned();
        let turn = turn.to_owned();
        self.tasks.spawn("conversation review", async move {
            let result = async {
                let api = JudgeApi::new(&router)?;
                trace.protect_secret(&api.key);
                if let Some(reason) = gateway.review_exclusion(&thread).await? {
                    return Ok(Outcome::skipped(reason));
                }
                if gateway.is_agent_thread(&thread).await? {
                    return Ok(Outcome::skipped("delegatedAgent"));
                }
                gateway
                    .review_turn(&api, &thread, &turn, &trace, permit)
                    .await
            }
            .await;
            match result {
                Ok(outcome) => trace.finish(outcome.status, outcome.reason),
                Err(error) => {
                    trace.failed(&error);
                    gateway.journal.push(
                        "conversationReviewSkipped",
                        json!({"threadId":thread,"turnId":turn,"reason":"checkFailed"}),
                    );
                }
            }
            Ok(())
        });
    }

    fn schedule_early_title(&self, message: &Value) {
        let params = &message["params"];
        let (Some(thread), Some(turn)) = (
            params["threadId"].as_str(),
            params.pointer("/turn/id").and_then(Value::as_str),
        ) else {
            return;
        };
        let Some(gateway) = self.gateway.upgrade() else {
            return;
        };
        let Ok(permit) = Arc::clone(&self.early_titles).try_acquire_owned() else {
            gateway.journal.push(
                "earlyTitleSkipped",
                json!({"threadId":thread,"turnId":turn,"reason":"capacity"}),
            );
            return;
        };
        let thread = thread.to_owned();
        let turn = turn.to_owned();
        self.tasks.spawn("early conversation title", async move {
            let _permit = permit;
            if let Err(error) = gateway.early_title(&thread, &turn).await {
                gateway.journal.push(
                    "earlyTitleSkipped",
                    json!({"threadId":thread,"turnId":turn,"reason":"checkFailed",
                        "error":format!("{error:#}")}),
                );
            }
            Ok(())
        });
    }

    pub(super) async fn stop(&self) {
        self.tasks.stop().await;
    }
}

#[derive(PartialEq)]
struct Snapshot {
    title: String,
    state: Value,
    latest_user_goal: Option<String>,
    has_user_turn: bool,
    completed_at: Option<i64>,
}

struct Conversation {
    messages: Vec<Value>,
    middle_truncated: bool,
    latest_user_goal: Option<String>,
}

struct Outcome {
    status: &'static str,
    reason: &'static str,
}
impl Outcome {
    fn skipped(reason: &'static str) -> Self {
        Self {
            status: "skipped",
            reason,
        }
    }
    fn failed(reason: &'static str) -> Self {
        Self {
            status: "failed",
            reason,
        }
    }
    fn kept(reason: &'static str) -> Self {
        Self {
            status: "kept",
            reason,
        }
    }
}

impl Gateway {
    fn trace_identity(&self, thread: &str, turn: Option<&str>, trigger: &str) -> Value {
        let claude = is_claude_thread_id(thread);
        json!({
            "threadId":thread,"turnId":turn,"trigger":trigger,"provider":if claude { "claude" } else { "codex" },
            "accountId":if claude { crate::accounts::types::DEFAULT_CLAUDE } else { crate::accounts::types::DEFAULT_CODEX },
            "accountGeneration":1,
            "host":nix::unistd::gethostname().ok().and_then(|name| name.into_string().ok()),
            "gateway":crate::build_identity::IDENTITY,"writer":"sideQuestion","titleCharacterLimit":MAX_TITLE_CHARACTERS
        })
    }

    fn review_trace(&self, thread: &str, turn: &str) -> Trace {
        let mut identity = self.trace_identity(thread, Some(turn), "turnCompleted");
        for (key, value) in [
            ("policyVersion", json!(4)),
            ("judgeModel", json!("typesafe/jev-1.13")),
            ("threshold", json!(THRESHOLD)),
            ("doneThreshold", json!(done::THRESHOLD)),
            ("contextByteLimit", json!(MAX_CONTEXT_BYTES)),
            ("latestUserGoalByteLimit", json!(MAX_USER_GOAL_BYTES)),
            ("writerRepairLimit", json!(1)),
        ] {
            identity[key] = value;
        }
        Trace::new(self.journal.clone(), identity)
    }

    fn early_title_trace(&self, thread: &str, turn: &str) -> Trace {
        let mut identity = self.trace_identity(thread, Some(turn), "earlyTitle");
        identity["delayMs"] = json!(early_title::DELAY.as_millis());
        Trace::new(self.journal.clone(), identity)
    }

    pub(super) async fn regenerate_title_rpc(self: &Arc<Self>, params: &Value) -> RpcResult {
        let thread = params["threadId"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= 512)
            .ok_or_else(|| RpcError::new(RpcCode::InvalidParams, "threadId is required"))?;
        let mut trace = Trace::new(
            self.journal.clone(),
            self.trace_identity(thread, None, "requested"),
        );
        match self.regenerate_title(thread, &trace).await {
            Ok(name) => {
                trace.finish("renamed", "renameAcknowledged");
                Ok(json!({ "name": name }))
            }
            Err(error) => {
                trace.failed(&error);
                Err(RpcError::new(
                    RpcCode::Internal,
                    format!("Could not regenerate the name: {error:#}"),
                ))
            }
        }
    }

    async fn review_turn(
        self: &Arc<Self>,
        api: &JudgeApi,
        thread: &str,
        turn: &str,
        trace: &Trace,
        evaluation: tokio::sync::OwnedSemaphorePermit,
    ) -> Result<Outcome> {
        let rename_candidate = self.renames.candidate(thread);
        trace.event("snapshotStarted", json!({"phase":"initial"}));
        let Some(snapshot) = self.review_snapshot(thread, turn, trace).await? else {
            return Ok(Outcome::skipped("snapshotRejected"));
        };
        let title_eligible = titles::eligible(&snapshot);
        let questions = Questions {
            title: title_eligible,
            done: snapshot.completed_at.is_some(),
        };
        trace.consumer_outcome(
            "title",
            if questions.title {
                "pending"
            } else {
                "skipped"
            },
            if questions.title {
                "judgePending"
            } else {
                "notApplicable"
            },
        );
        trace.consumer_outcome(
            "done",
            if questions.done { "pending" } else { "skipped" },
            if questions.done {
                "judgePending"
            } else {
                "notApplicable"
            },
        );
        trace.event("snapshot", json!({"oldTitle":snapshot.title,"titleTooLong":snapshot.state["titleTooLong"],
            "contextBytes":snapshot.state.to_string().len(),"messages":snapshot.state["messages"].as_array().map(Vec::len),
            "middleTruncated":snapshot.state["middleTruncated"],"titleEligible":questions.title,"doneEligible":questions.done,
            "completedAt":snapshot.completed_at}));
        if !questions.title && !questions.done {
            return Ok(Outcome::skipped("noApplicableQuestions"));
        }
        let decisions = api.judge(&snapshot.state, questions, trace).await?;
        let mut done_failed = false;
        if let Some(answer) = decisions.done {
            match answer {
                Ok(probability) => {
                    let result = match snapshot.completed_at {
                        Some(completed_at) => {
                            self.record_done(thread, completed_at, probability, trace)
                                .await
                        }
                        None => Err(anyhow::anyhow!("done timestamp unavailable")),
                    };
                    match result {
                        Ok(changed) => trace.consumer_outcome(
                            "done",
                            if changed { "written" } else { "unchanged" },
                            "doneJudged",
                        ),
                        Err(error) => {
                            trace.consumer_failed("done", "marksWriteFailed", &error);
                            done_failed = true;
                        }
                    }
                }
                Err(error) => {
                    trace.consumer_failed("done", "invalidDecision", &error);
                    done_failed = true;
                }
            }
        }
        let Some(title) = decisions.title else {
            return Ok(if done_failed {
                Outcome::failed("doneFailed")
            } else {
                Outcome {
                    status: "reviewed",
                    reason: "doneJudged",
                }
            });
        };
        let outcome = match title {
            Err(error) => {
                trace.consumer_failed("title", "invalidDecision", &error);
                return Ok(Outcome::failed("titleFailed"));
            }
            Ok(false) => Outcome::kept("judgeKeptTitle"),
            Ok(true) => {
                let candidate = match rename_candidate {
                    Ok(candidate) => candidate,
                    Err(error) => {
                        trace.consumer_failed(
                            "title",
                            "renameAdmissionFailed",
                            &anyhow::anyhow!("{error:?}"),
                        );
                        return Ok(Outcome::failed("titleFailed"));
                    }
                };
                match self
                    .maintain_title(
                        thread,
                        turn,
                        snapshot,
                        trace,
                        titles::TitleEvaluation {
                            candidate,
                            permit: evaluation,
                        },
                    )
                    .await
                {
                    Ok(outcome) => outcome,
                    Err(error) => {
                        trace.consumer_failed("title", "maintenanceFailed", &error);
                        return Ok(Outcome::failed("titleFailed"));
                    }
                }
            }
        };
        trace.consumer_outcome("title", outcome.status, outcome.reason);
        Ok(outcome)
    }

    async fn review_exclusion(&self, thread: &str) -> Result<Option<&'static str>> {
        let marks = self.marks.read(crate::time::unix_seconds() as i64).await?;
        let Some(mark) = marks.threads.get(thread) else {
            return Ok(None);
        };
        Ok(if mark.pin_name.is_some() {
            Some("pinned")
        } else if mark.purpose.is_some() {
            Some("excludedPurpose")
        } else {
            None
        })
    }

    async fn review_turns(&self, thread: &str, direction: &str, limit: u32) -> Result<Value> {
        let params = json!({"threadId":thread,"sortDirection":direction,"limit":limit,"itemsView":"summary"});
        if !is_claude_thread_id(thread) {
            return self.call_control("thread/turns/list", params).await;
        }
        let params: TurnsListParams = serde_json::from_value(params)?;
        let active_turn = self.claude_active_turn_id(thread).await;
        self.claude_history
            .read_projection(thread, active_turn, move |projection, file, _| {
                projection.turns_page(file, &params)
            })
            .await
            .map(|(page, _)| page)
            .map_err(|error| anyhow::anyhow!("review history unavailable: {error:?}"))
    }

    async fn review_conversation(&self, thread: &str) -> Result<Option<Conversation>> {
        let mut cursor: Option<String> = None;
        let mut messages = Vec::new();
        let mut bytes = 0;
        let mut truncated = false;
        let mut latest_user_goal = None;
        for _ in 0..MAX_HISTORY_PAGES {
            let params =
                json!({"threadId":thread,"sortDirection":"asc","limit":50,"cursor":cursor});
            let page = if is_claude_thread_id(thread) {
                let params: ItemsListParams = serde_json::from_value(params)?;
                self.claude_history
                    .read_projection(thread, None, move |projection, file, _| {
                        projection.items_page(file, &params)
                    })
                    .await
                    .map(|(page, _)| page)
                    .map_err(|error| anyhow::anyhow!("review history unavailable: {error:?}"))?
            } else {
                self.call_control("thread/items/list", params).await?
            };
            if self.draining.load(Ordering::Acquire) {
                return Ok(None);
            }
            let entries = page["data"]
                .as_array()
                .context("review items unavailable")?;
            for entry in entries {
                if entry["item"]["type"] == "userMessage" {
                    latest_user_goal = None;
                }
                if let Some(message) = conversation_message(&entry["item"]) {
                    if message["role"] == "user" {
                        latest_user_goal = trimmed_message_text(&message, MAX_USER_GOAL_BYTES)?
                            .or_else(|| message["text"].as_str().map(str::to_owned));
                    }
                    bytes = match message_bytes_at_most(
                        &message,
                        (MAX_BUFFER_BYTES - bytes).saturating_add(1),
                    )? {
                        Some(size) => bytes + size - 1,
                        None => MAX_BUFFER_BYTES + 1,
                    };
                    messages.push(message);
                    if bytes > MAX_BUFFER_BYTES {
                        truncated |= trim_middle(&mut messages, MAX_CONTEXT_BYTES)?;
                        bytes =
                            crate::wire::json::encoded_len_at_most(&messages, MAX_CONTEXT_BYTES)?
                                .context("trimmed review context exceeds byte budget")?;
                    }
                }
            }
            let next = page["nextCursor"].as_str().map(str::to_owned);
            if next.is_none() {
                truncated |= trim_middle(&mut messages, MAX_CONTEXT_BYTES)?;
                return Ok(Some(Conversation {
                    messages,
                    middle_truncated: truncated,
                    latest_user_goal,
                }));
            }
            ensure!(next != cursor, "review history cursor did not advance");
            cursor = next;
        }
        anyhow::bail!("conversation exceeds review history safety limit")
    }

    pub(super) async fn review_header(&self, thread: &str) -> Result<Value> {
        let params = json!({"threadId":thread,"includeTurns":false});
        if is_claude_thread_id(thread) {
            self.claude_thread_response(&params)
                .await
                .map_err(|error| anyhow::anyhow!("review header unavailable: {error:?}"))
        } else {
            self.call_control("thread/read", params).await
        }
    }

    async fn review_snapshot(
        &self,
        thread: &str,
        turn: &str,
        trace: &Trace,
    ) -> Result<Option<Snapshot>> {
        let header = self.review_header(thread).await?;
        let rejected = |reason: &'static str| {
            trace.event("snapshotRejected", json!({"reason":reason}));
            None
        };
        let header = &header["thread"];
        trace.event("header", json!({"observedThreadId":header["id"],"status":header["status"],
            "ephemeral":header["ephemeral"],"nativeTitle":header["name"],"preview":header["preview"]}));
        if header["id"].as_str() != Some(thread)
            || header["ephemeral"].as_bool() != Some(false)
            || !matches!(
                header.pointer("/status/type").and_then(Value::as_str),
                Some("idle" | "notLoaded")
            )
        {
            return Ok(rejected("threadUnavailableOrActive"));
        }
        let title = effective_title(header).unwrap_or_default();
        let latest = self.review_turns(thread, "desc", 1).await?;
        let Some(latest) = latest["data"].as_array().and_then(|data| data.first()) else {
            return Ok(rejected("turnUnavailable"));
        };
        trace.event(
            "turnRead",
            json!({"observedTurnId":latest["id"],"status":latest["status"]}),
        );
        if latest["id"].as_str() != Some(turn) || latest["status"].as_str() != Some("completed") {
            return Ok(rejected("turnChangedOrIncomplete"));
        }
        let has_user_turn = latest["items"]
            .as_array()
            .is_some_and(|items| items.iter().any(|item| item["type"] == "userMessage"));
        let completed_at = if is_claude_thread_id(thread) {
            header["lastTurnCompletedAt"].as_i64().filter(|completed| {
                latest["startedAt"]
                    .as_i64()
                    .is_some_and(|started| *completed >= started)
            })
        } else {
            latest["completedAt"].as_i64()
        };
        let Some(conversation) = self.review_conversation(thread).await? else {
            return Ok(rejected("gatewayDrainingDuringHistoryRead"));
        };
        if conversation.messages.is_empty() {
            return Ok(rejected("emptyDialogue"));
        }

        Ok(Some(Snapshot {
            title: title.to_owned(),
            state: json!({"title":bounded(title, 256),"titleTooLong":title.chars().count() > MAX_TITLE_CHARACTERS,
                "messages":conversation.messages,"middleTruncated":conversation.middle_truncated}),
            latest_user_goal: conversation.latest_user_goal,
            has_user_turn,
            completed_at,
        }))
    }
}

pub(super) fn effective_title(thread: &Value) -> Option<&str> {
    thread["name"]
        .as_str()
        .filter(|name| !name.trim().is_empty())
        .or_else(|| thread["preview"].as_str())
}

fn bounded(text: &str, limit: usize) -> String {
    text.chars().take(limit).collect()
}

fn conversation_message(item: &Value) -> Option<Value> {
    match item["type"].as_str()? {
        "userMessage" => {
            let text = item["content"]
                .as_array()?
                .iter()
                .filter_map(|part| part["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n");
            (!text.trim().is_empty()).then(|| json!({"role":"user","text":text}))
        }
        "agentMessage" => {
            let text = item["text"].as_str()?;
            (!text.trim().is_empty()).then(|| json!({"role":"assistant","text":text}))
        }
        "commandExecution" | "mcpToolCall" | "dynamicToolCall" | "fileChange" | "webSearch" => {
            // Keep the tool event, with a short name where available. Arguments,
            // command output and patches do not crowd out the actual dialogue.
            Some(
                json!({"role":"tool","type":item["type"],"name":item["tool"].as_str().or_else(|| item["name"].as_str()).map(|name| bounded(name,80))}),
            )
        }
        _ => None,
    }
}

fn message_bytes_at_most(message: &Value, budget: usize) -> Result<Option<usize>> {
    if message["text"]
        .as_str()
        .is_some_and(|text| text.len() > budget)
    {
        return Ok(None);
    }
    Ok(
        crate::wire::json::encoded_len_at_most(message, budget.saturating_sub(1))?
            .map(|bytes| bytes + 1),
    )
}

/// Keep complete messages at the beginning and end; never cap every message.
/// A single oversized bookend is itself trimmed in the middle as a last resort.
fn trim_middle(messages: &mut Vec<Value>, budget: usize) -> Result<bool> {
    let budget = budget.saturating_sub(1);
    let mut sizes = messages
        .iter()
        .map(|message| {
            Ok(message_bytes_at_most(message, budget)?.unwrap_or(budget.saturating_add(1)))
        })
        .collect::<Result<Vec<_>>>()?;
    if sizes.iter().copied().fold(0usize, usize::saturating_add) <= budget {
        return Ok(false);
    }
    if messages.len() == 1 {
        trim_message_middle(&mut messages[0], budget)?;
        return Ok(true);
    }
    let last = messages.len() - 1;
    if sizes[0].saturating_add(sizes[last]) > budget {
        trim_message_middle(&mut messages[0], budget / 2)?;
        trim_message_middle(&mut messages[last], budget / 2)?;
        sizes[0] =
            message_bytes_at_most(&messages[0], budget)?.context("review head exceeds budget")?;
        sizes[last] = message_bytes_at_most(&messages[last], budget)?
            .context("review tail exceeds budget")?;
    }
    let head_budget = (budget / 2).max(sizes[0]).min(budget - sizes[last]);
    let mut left = 0;
    let mut used = 0usize;
    while left < messages.len() && used.saturating_add(sizes[left]) <= head_budget {
        used += sizes[left];
        left += 1;
    }
    let tail_budget = budget - used;
    let mut right = messages.len();
    used = 0;
    while right > left && used.saturating_add(sizes[right - 1]) <= tail_budget {
        used += sizes[right - 1];
        right -= 1;
    }
    messages.drain(left..right);
    Ok(true)
}

fn trim_message_middle(message: &mut Value, budget: usize) -> Result<()> {
    if let Some(text) = trimmed_message_text(message, budget)? {
        message["text"] = Value::String(text);
    }
    Ok(())
}

fn trimmed_message_text(message: &Value, budget: usize) -> Result<Option<String>> {
    if message_bytes_at_most(message, budget)?.is_some() {
        return Ok(None);
    }
    let text = message["text"]
        .as_str()
        .context("review message metadata exceeds byte budget")?;
    let marker = "\n[... message middle omitted ...]\n";
    let mut candidate = Value::Object(
        message
            .as_object()
            .context("review message must be an object")?
            .iter()
            .filter(|(key, _)| key.as_str() != "text")
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect(),
    );
    let mut low = 0usize;
    let mut high = text.len().min(budget.saturating_sub(marker.len()));
    let mut best = None;
    while low <= high {
        let keep = low + (high - low) / 2;
        let mut head = keep / 2;
        let mut tail = text.len() - (keep - head);
        while !text.is_char_boundary(head) {
            head -= 1;
        }
        while !text.is_char_boundary(tail) {
            tail += 1;
        }
        candidate["text"] = json!(format!("{}{marker}{}", &text[..head], &text[tail..]));
        if message_bytes_at_most(&candidate, budget)?.is_some() {
            best = Some(candidate["text"].take());
            low = keep + 1;
        } else if keep == 0 {
            break;
        } else {
            high = keep - 1;
        }
    }
    match best.context("review message metadata exceeds byte budget")? {
        Value::String(text) => Ok(Some(text)),
        _ => anyhow::bail!("review text preparation did not produce text"),
    }
}

#[cfg(test)]
mod tests;
