use super::live_activity::{FinishedTurn, FinishedTurns};
use super::{
    ActiveTasksLiveActivitySnapshot, ApnsSend, DurableTurnState, Gateway, GatewayCoreState,
    native_mutations,
};
use crate::time::unix_seconds;
use crate::turns::{
    ActiveTurn, Completion, DurableTurns, PendingTurnStart, PromptContext, TurnKey, TurnLedger,
    agent_label,
};
use anyhow::{Context, Result};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use tracing::{debug, info, warn};

pub(super) fn captures_turn_start(method: Option<&str>) -> bool {
    matches!(method, Some("turn/start" | "thread/compact/start"))
}

impl DurableTurnState {
    pub(crate) fn validate(&self) -> Result<()> {
        native_mutations::PendingNativeMutations::validate(&self.pending_native_mutations)?;
        anyhow::ensure!(
            TurnLedger::queues_are_bounded(&self.queued_submissions),
            "queued submissions exceed their limits"
        );
        Ok(())
    }
}

impl Gateway {
    pub(super) async fn load_turn_state(&self) -> Result<()> {
        let Some(path) = self.turn_state_path.as_ref() else {
            return Ok(());
        };
        self.core.lock().await.finished_turns =
            FinishedTurns::load(&FinishedTurns::path(path)).await;
        let cleanup_path = path.clone();
        let removed = tokio::task::spawn_blocking(move || {
            crate::storage::private_state::remove_dead_writer_temporaries(&cleanup_path)
        })
        .await
        .context("turn-state temporary cleanup worker failed")??;
        if removed > 0 {
            info!(removed, path = %path.display(), "removed abandoned turn-state temporaries");
        }
        let Some(durable) = read_turn_state(path).await? else {
            return Ok(());
        };
        let turns = TurnLedger::restore(DurableTurns {
            pending_turn_starts: durable.pending_turn_starts,
            active_turns_by_key: durable.active_turns_by_key,
            turn_ctx_by_key: durable.turn_ctx_by_key,
            queued_submissions: durable.queued_submissions,
        });
        self.next_client_id
            .fetch_max(turns.next_owner_client_id(), Ordering::AcqRel);
        self.native_mutations
            .restore(durable.pending_native_mutations)
            .await;
        let mut core = self.core.lock().await;
        core.turns = turns;
        Ok(())
    }

    pub(super) async fn commit_turn_state(&self) -> Result<()> {
        self.activity.mark_changed();
        let Some(path) = self.turn_state_path.as_ref() else {
            return Ok(());
        };
        let guard = Arc::clone(&self.turn_state_write_lock).lock_owned().await;
        let pending_native_mutations = self.native_mutations.durable().await;
        let (durable, finished_turns) = {
            let core = self.core.lock().await;
            let turns = core.turns.durable();
            let durable = DurableTurnState {
                pending_turn_starts: turns.pending_turn_starts,
                active_turns_by_key: turns.active_turns_by_key,
                turn_ctx_by_key: turns.turn_ctx_by_key,
                pending_native_mutations,
                queued_submissions: turns.queued_submissions,
            };
            (durable, core.finished_turns.clone())
        };
        let path = path.clone();
        // The blocking writer owns the guard until persistence actually finishes,
        // even when an asynchronous caller is cancelled.
        tokio::task::spawn_blocking(move || {
            let _guard = guard;
            let parent = path.parent().context("turn state path has no parent")?;
            crate::storage::private_state::ensure_private_directory(parent)?;
            crate::storage::private_state::write_json(&path, &durable)?;
            if finished_turns.is_available() {
                crate::storage::private_state::write_json(
                    &FinishedTurns::path(&path),
                    &finished_turns,
                )?;
            }
            Ok(())
        })
        .await
        .context("turn-state persistence worker failed")?
    }

    pub(super) async fn capture_client_request_locked(
        &self,
        client_id: u64,
        req: &serde_json::Map<String, Value>,
    ) -> Result<()> {
        let method = req.get("method").and_then(|v| v.as_str());
        if !captures_turn_start(method) {
            return Ok(());
        }
        let Some(request_key) = req
            .get("id")
            .and_then(|id| client_request_key(client_id, id))
        else {
            return Ok(());
        };
        let Some(Value::Object(params)) = req.get("params") else {
            return Ok(());
        };

        let thread_id = params
            .get("threadId")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .trim()
            .to_string();
        if thread_id.is_empty() {
            return Ok(());
        }

        // This prompt text is used for APNs previews; do not log it (user content).
        let preview = prompt_preview(&thread_id, params.get("input"));
        let cwd = params
            .get("cwd")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let client_user_message_id = client_user_message_id(params);

        {
            let mut core = self.core.lock().await;
            let previous_turn_id = core
                .turns
                .active_on_thread(&thread_id)
                .map(|turn| turn.turn_id.clone());
            core.turns.insert_pending(
                request_key,
                PendingTurnStart {
                    thread_id,
                    context: PromptContext {
                        compaction: method == Some("thread/compact/start"),
                        preview,
                        cwd,
                        owner_client_id: client_id,
                    },
                    previous_turn_id,
                    client_user_message_id,
                    created_at_unix_seconds: unix_seconds(),
                },
            );
        }
        self.commit_turn_state().await
    }

    pub(super) async fn capture_turn_start_response(
        &self,
        client_id: u64,
        message: &Value,
    ) -> Result<()> {
        if message.get("method").is_some() {
            return Ok(());
        }
        let Some(id) = message.get("id") else {
            return Ok(());
        };
        let turn_id = if message.get("error").is_none() {
            message
                .pointer("/result/turn")
                .and_then(Value::as_object)
                .filter(|turn| turn.get("status").and_then(Value::as_str) == Some("inProgress"))
                .and_then(|turn| turn.get("id"))
                .and_then(Value::as_str)
        } else {
            None
        };
        if (message.get("error").is_none()
            || message.pointer("/error/data/kind").and_then(Value::as_str)
                == Some("compactionDeliveryUncertain"))
            && turn_id.is_none()
            && let Some(key) = client_request_key(client_id, id)
            && self
                .core
                .lock()
                .await
                .turns
                .pending()
                .any(|(pending_key, pending)| pending_key == &key && pending.context.compaction)
        {
            // The native empty acknowledgment accepts work; its turn/started
            // notification (or disconnect observer) owns the actual turn id.
            return Ok(());
        }
        self.complete_pending_turn_start(client_id, id, turn_id)
            .await
    }

    async fn complete_pending_turn_start(
        &self,
        client_id: u64,
        id: &Value,
        turn_id: Option<&str>,
    ) -> Result<()> {
        let Some(request_key) = client_request_key(client_id, id) else {
            return Ok(());
        };
        let pending = self.core.lock().await.turns.take_pending(&request_key);
        let Some(pending) = pending else {
            return Ok(());
        };
        if let Some(turn_id) = turn_id {
            let now = unix_seconds();
            self.core
                .lock()
                .await
                .turns
                .start_from_pending(pending, turn_id, now, Some(now));
        }
        self.commit_turn_state().await
    }

    pub(super) async fn capture_agent_message(
        &self,
        message: &Value,
    ) -> Option<(
        String,
        String,
        Option<ApnsSend>,
        Option<ActiveTasksLiveActivitySnapshot>,
    )> {
        let method = message.get("method")?.as_str()?;
        if !method.starts_with("turn/") && !method.starts_with("item/") {
            return None;
        }
        let method = method.to_string();
        let params = message.get("params")?.as_object()?;

        let now = unix_seconds();

        match method.as_str() {
            "turn/started" => {
                let (key, live_activity) = {
                    let mut core = self.core.lock().await;
                    let key = note_turn_started(&mut core, params, now)?;
                    let live_activity = active_tasks_live_activity_snapshot(&core);
                    (key, live_activity)
                };
                if let Err(error) = self.commit_turn_state().await {
                    warn!(%error, "failed to persist started turn state");
                }
                let key = key.to_string();
                debug!(method, key, "rpc codex->gateway received");
                Some((method, key, None, Some(live_activity)))
            }
            "item/started" | "item/completed"
                if params
                    .get("item")
                    .is_some_and(|item| item["type"] == "userMessage") =>
            {
                let key = turn_key_from_params(params)?;
                let client_user_message_id = params["item"]["clientId"].as_str()?;
                let live_activity = {
                    let mut core = self.core.lock().await;
                    if !core.turns.note_user_message(&key, client_user_message_id) {
                        return None;
                    }
                    active_tasks_live_activity_snapshot(&core)
                };
                if let Err(error) = self.commit_turn_state().await {
                    warn!(%error, "failed to persist attributed turn state");
                }
                Some((method, key.to_string(), None, Some(live_activity)))
            }
            "item/started"
                if params
                    .get("item")
                    .is_some_and(|item| item["type"] == "contextCompaction") =>
            {
                if let Some(key) = turn_key_from_params(params) {
                    self.core.lock().await.turns.note_compaction(&key);
                    if let Err(error) = self.commit_turn_state().await {
                        warn!(%error, "failed to persist compaction turn state");
                    }
                }
                None
            }
            "item/completed" => {
                note_item_completed(&mut *self.core.lock().await, params, now);
                None
            }
            "turn/completed" => {
                if let Some(key) = turn_key_from_params(params) {
                    self.device_tools.turn_ended(key.thread_id(), key.turn_id());
                }
                let hold_queue = !self.is_planned_interruption(&method, message);
                let (key, send, live_activity) = {
                    let mut core = self.core.lock().await;
                    let (key, send) = note_turn_completed(&mut core, params, now, hold_queue)?;
                    let live_activity = active_tasks_live_activity_snapshot(&core);
                    (key, send, live_activity)
                };
                if let Err(error) = self.commit_turn_state().await {
                    warn!(%error, "failed to persist completed turn state");
                }
                let key = key.to_string();
                debug!(method, key, "rpc codex->gateway received");
                Some((method, key, send, Some(live_activity)))
            }
            _ => None,
        }
    }
}

async fn read_turn_state(path: &Path) -> Result<Option<DurableTurnState>> {
    let bytes = match tokio::fs::read(path).await {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    let durable: DurableTurnState = serde_json::from_slice(&bytes)
        .with_context(|| format!("failed to parse {}", path.display()))?;
    durable
        .validate()
        .with_context(|| format!("failed to restore {}", path.display()))?;
    Ok(Some(durable))
}

fn turn_key_from_params(params: &serde_json::Map<String, Value>) -> Option<TurnKey> {
    let thread_id = params.get("threadId")?.as_str()?.trim();
    if thread_id.is_empty() {
        return None;
    }
    Some(TurnKey::new(thread_id, canonical_turn_id(params)?))
}

pub(super) fn note_turn_started(
    core: &mut GatewayCoreState,
    params: &serde_json::Map<String, Value>,
    now: f64,
) -> Option<TurnKey> {
    let key = turn_key_from_params(params)?;
    if !core.turns.note_started(&key, now) {
        return None;
    }
    core.finished_turns
        .note_started(key.thread_id(), key.turn_id());
    Some(key)
}

pub(super) fn note_item_completed(
    core: &mut GatewayCoreState,
    params: &serde_json::Map<String, Value>,
    now: f64,
) {
    let trimmed_id = |field: &str| {
        params
            .get(field)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
    };
    let (thread_id, turn_id) = (trimmed_id("threadId"), trimmed_id("turnId"));
    if thread_id.is_empty() || turn_id.is_empty() {
        return;
    }
    let Some(Value::Object(item)) = params.get("item") else {
        return;
    };
    if item.get("type").and_then(Value::as_str) != Some("agentMessage") {
        return;
    }
    let text = item
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if text.is_empty() {
        return;
    }
    core.turns.note_last_message(
        TurnKey::new(thread_id, turn_id),
        word_preview(text, 20),
        now,
    );
}

pub(super) fn prompt_preview(thread_id: &str, input: Option<&Value>) -> String {
    let prompt = input
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.get("text").and_then(Value::as_str))
        .map(crate::prompt_summary::prompt_summary)
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    if prompt.is_empty() {
        format!("{} task", agent_label(thread_id))
    } else {
        word_preview(&prompt, 20)
    }
}

pub(super) fn client_user_message_id(params: &serde_json::Map<String, Value>) -> Option<String> {
    params
        .get("clientUserMessageId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
}

fn word_preview(text: &str, words: usize) -> String {
    let trimmed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if trimmed.is_empty() {
        return String::new();
    }

    let parts: Vec<&str> = trimmed.split(' ').collect();
    if parts.len() <= words {
        return trimmed;
    }
    format!("{}...", parts[..words].join(" "))
}

fn note_turn_completed(
    core: &mut GatewayCoreState,
    params: &serde_json::Map<String, Value>,
    now: f64,
    hold_queue: bool,
) -> Option<(TurnKey, Option<ApnsSend>)> {
    let key = turn_key_from_params(params)?;

    let status = params
        .get("turn")
        .and_then(|v| v.get("status"))
        .and_then(|v| v.as_str())
        .unwrap_or("unknown")
        .trim()
        .to_string();
    let context = match core.turns.complete(&key, now) {
        Completion::AlreadyRecorded => return Some((key, None)),
        Completion::Recorded(context) => context,
    };
    if hold_queue && status == "interrupted" {
        core.turns.hold_queue(key.thread_id());
    }
    if context.compaction && context.last_message_preview.is_none() {
        return Some((key, None));
    }
    if hold_queue || status != "interrupted" {
        let turn = params.get("turn");
        let completed_at = turn
            .and_then(|turn| turn["completedAt"].as_i64())
            .unwrap_or(now as i64);
        let started_at = turn
            .and_then(|turn| turn["startedAt"].as_i64())
            .unwrap_or(completed_at);
        core.finished_turns.record(
            key.thread_id(),
            FinishedTurn {
                turn_id: key.turn_id().to_owned(),
                started_at,
                completed_at,
            },
        );
    }
    let (thread_id, turn_id) = (key.thread_id().to_owned(), key.turn_id().to_owned());

    let outcome = if status == "completed" {
        "success"
    } else {
        "failure"
    };
    let label = agent_label(&thread_id);
    let title = if status == "completed" {
        format!("{label} finished")
    } else {
        format!("{label} ended")
    };
    let subtitle = context.prompt_preview.clone();
    let body = context.last_message_preview.clone().unwrap_or_else(|| {
        if status == "completed" {
            "Task finished.".to_string()
        } else {
            format!("Turn ended: {status}")
        }
    });

    let payload = serde_json::json!({
        "eventID": format!("{thread_id}:{turn_id}"),
        "source": agent_source(&thread_id),
        "outcome": outcome,
        "conversationID": Value::Null,
        "sessionID": thread_id,
        "promptPreview": subtitle,
        "messagePreview": body,
        "workingDirectory": context.cwd,
        "createdAtUnixSeconds": unix_seconds(),
    });

    Some((
        key,
        Some(ApnsSend {
            collapse_id: thread_id.clone(),
            title,
            subtitle,
            body,
            payload,
        }),
    ))
}

pub(super) fn complete_tracked_turn(
    core: &mut GatewayCoreState,
    turn: &ActiveTurn,
    status: &str,
    hold_queue: bool,
) -> (Option<ApnsSend>, ActiveTasksLiveActivitySnapshot) {
    let mut params = serde_json::Map::new();
    params.insert("threadId".to_string(), json!(turn.thread_id));
    params.insert(
        "turn".to_string(),
        json!({
            "id": turn.turn_id,
            "status": status,
            "startedAt": turn.started_at_unix_seconds as i64,
        }),
    );
    let send =
        note_turn_completed(core, &params, unix_seconds(), hold_queue).and_then(|(_, send)| send);
    (send, active_tasks_live_activity_snapshot(core))
}

pub(super) fn ended_turn_status<'a>(newest_first: &'a [Value], turn_id: &str) -> Option<&'a str> {
    let Some(listed) = newest_first
        .iter()
        .find(|listed| listed.get("id").and_then(Value::as_str) == Some(turn_id))
    else {
        return Some("unknown");
    };
    listed
        .get("status")
        .and_then(Value::as_str)
        .filter(|status| matches!(*status, "completed" | "interrupted" | "failed"))
}

fn client_request_key(client_id: u64, request_id: &Value) -> Option<String> {
    if !request_id.is_string() && !request_id.is_number() {
        return None;
    }
    serde_json::to_string(request_id)
        .ok()
        .map(|request_id| format!("{client_id}:{request_id}"))
}

fn canonical_turn_id(params: &serde_json::Map<String, Value>) -> Option<String> {
    let from_turn = params
        .get("turn")
        .and_then(|v| v.get("id"))
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let from_field = params
        .get("turnId")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty());

    from_turn.or(from_field).map(str::to_owned)
}

pub(super) fn is_terminal_turn_for_pending(turn: &Value, pending: &PendingTurnStart) -> bool {
    let Some(turn_id) = turn.get("id").and_then(Value::as_str) else {
        return false;
    };
    if pending.previous_turn_id.as_deref() == Some(turn_id) {
        return false;
    }
    if !matches!(
        turn.get("status").and_then(Value::as_str),
        Some("completed" | "interrupted" | "failed")
    ) {
        return false;
    }
    if let Some(client_user_message_id) = &pending.client_user_message_id {
        return turn_carries_user_message(turn, client_user_message_id);
    }
    pending.previous_turn_id.is_some()
        || turn
            .get("startedAt")
            .and_then(Value::as_f64)
            .is_some_and(|started_at| started_at + 1.0 >= pending.created_at_unix_seconds)
}

pub(super) fn user_message_client_ids(turn: &Value) -> impl Iterator<Item = &str> {
    turn.get("items")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|item| item["type"] == "userMessage")
        .filter_map(|item| item["clientId"].as_str())
}

pub(super) fn turn_carries_user_message(turn: &Value, client_user_message_id: &str) -> bool {
    user_message_client_ids(turn).any(|id| id == client_user_message_id)
}

pub(super) fn resumed_turn_terminal_status<'a>(
    message: &'a Value,
    turn_id: &str,
) -> Option<&'a str> {
    message
        .pointer("/result/thread/turns")
        .and_then(Value::as_array)?
        .iter()
        .rev()
        .find(|turn| turn.get("id").and_then(Value::as_str) == Some(turn_id))?
        .get("status")
        .and_then(Value::as_str)
        .filter(|status| matches!(*status, "completed" | "interrupted" | "failed"))
}

pub(super) fn is_other_turn_terminal_on_thread(message: &Value, expected: &ActiveTurn) -> bool {
    if message.get("method").and_then(Value::as_str) != Some("turn/completed") {
        return false;
    }
    let Some(params) = message.get("params").and_then(Value::as_object) else {
        return false;
    };
    params.get("threadId").and_then(Value::as_str) == Some(expected.thread_id.as_str())
        && canonical_turn_id(params).as_deref() != Some(expected.turn_id.as_str())
}

pub(super) fn text_preview(text: &str, max_chars: usize) -> String {
    let flattened = text.replace('\n', " ");
    if flattened.chars().count() <= max_chars {
        return flattened;
    }
    let truncated: String = flattened.chars().take(max_chars).collect();
    format!("{truncated}…")
}

pub(super) fn active_tasks_live_activity_snapshot(
    core: &GatewayCoreState,
) -> ActiveTasksLiveActivitySnapshot {
    ActiveTasksLiveActivitySnapshot {
        running: core
            .turns
            .active()
            .map(|turn| turn.thread_id.clone())
            .collect(),
        finished: core.finished_turns.clone(),
    }
}

/// Machine-facing provider tag carried in the APNs payload.
fn agent_source(thread_id: &str) -> &'static str {
    if crate::providers::claude::is_claude_thread_id(thread_id) {
        "claude"
    } else {
        "codex"
    }
}

#[cfg(test)]
mod private_state_startup_tests {
    use super::*;
    use crate::test_support::TestGateway;

    #[tokio::test]
    async fn private_state_startup_sweeps_only_dead_writer_ledger_temporaries() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("active-codex-turns.json");
        let mut child = std::process::Command::new("/usr/bin/true").spawn().unwrap();
        let dead_pid = i32::try_from(child.id()).unwrap();
        assert!(child.wait().unwrap().success());
        assert_eq!(
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(dead_pid), None),
            Err(nix::errno::Errno::ESRCH)
        );
        let legacy = directory
            .path()
            .join(format!("active-codex-turns.json.new.{dead_pid}"));
        let current = directory
            .path()
            .join(format!(".active-codex-turns.json.{dead_pid}.1.new"));
        for temporary in [&legacy, &current] {
            std::fs::write(temporary, b"abandoned partial write").unwrap();
        }
        let retained = [
            format!("active-codex-turns.json.new.{}", std::process::id()),
            format!(".active-codex-turns.json.{}.1.new", std::process::id()),
            "active-codex-turns.json.new.unknown".into(),
            "active-codex-turns.json.new.0".into(),
            "active-codex-turns.json.new.-1".into(),
            format!("active-codex-turns.json.new.+{dead_pid}"),
            format!("active-codex-turns.json.new.0{dead_pid}"),
            format!(".active-codex-turns.json.{dead_pid}.unknown.new"),
            format!(".active-codex-turns.json.{dead_pid}.0.new"),
            format!("other-state.json.new.{dead_pid}"),
        ];
        for name in &retained {
            std::fs::write(directory.path().join(name), b"retained").unwrap();
        }
        let link = directory
            .path()
            .join(format!(".active-codex-turns.json.{dead_pid}.2.new"));
        let folder = directory
            .path()
            .join(format!(".active-codex-turns.json.{dead_pid}.3.new"));
        std::fs::create_dir(&folder).unwrap();
        let turn = ActiveTurn {
            thread_id: "thread".into(),
            turn_id: "turn".into(),
            owner_client_id: 7,
            started_at_unix_seconds: 1.0,
            last_seen_at_unix_seconds: 1.0,
        };
        let durable = DurableTurnState {
            active_turns_by_key: std::collections::HashMap::from([(
                "thread|turn".into(),
                turn.clone(),
            )]),
            ..DurableTurnState::default()
        };
        let original = serde_json::to_vec(&durable).unwrap();
        std::fs::write(&path, &original).unwrap();
        std::os::unix::fs::symlink(&path, &link).unwrap();
        let gateway = TestGateway::with_codex(
            Arc::new(crate::providers::codex::daemon::CodexAppServer::new(
                "/bin/true".into(),
                std::collections::HashMap::new(),
            )),
            Some(path.clone()),
        );
        gateway.load_turn_state().await.unwrap();
        assert!(!legacy.exists());
        assert!(!current.exists());
        assert_eq!(std::fs::read(&path).unwrap(), original);
        assert_eq!(
            gateway
                .core
                .lock()
                .await
                .turns
                .active_turn(&TurnKey::new("thread", "turn")),
            Some(&turn)
        );
        for name in &retained {
            assert_eq!(
                std::fs::read(directory.path().join(name)).unwrap(),
                b"retained"
            );
        }
        assert!(
            std::fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert!(folder.is_dir());
        std::fs::remove_file(&path).unwrap();
        std::fs::write(&legacy, b"abandoned").unwrap();
        gateway.load_turn_state().await.unwrap();
        assert!(!legacy.exists());
        assert!(!path.exists());
    }
}
