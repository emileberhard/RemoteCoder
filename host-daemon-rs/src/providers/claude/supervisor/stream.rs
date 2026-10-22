use super::{
    ClaudeRuntime, ClaudeRuntimeSettings, ClaudeSupervisor, RuntimeTurn, STDERR_RING_CAPACITY,
    TurnPhase, TurnStartError, annotate_agent_initiated, consumed_input_ids,
    is_background_tasks_change, opens_turn, wake_reason,
};
use crate::ids::new_session_uuid;
use crate::providers::claude::capacity::{CapacityExceeded, read_stream_line};
use crate::providers::claude::translate::TurnResult;
use crate::providers::claude::translate::narration::SEND_USER_MESSAGE;
use nix::unistd::Pid;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::BufReader;

const MAX_STDOUT_RECORD_BYTES: usize = 32 << 20;
const MAX_STDERR_RECORD_BYTES: usize = 16 << 10;
use tokio::process::{ChildStderr, ChildStdout};
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, warn};

impl ClaudeSupervisor {
    pub(super) fn prepare_runtime_control(
        request: &Value,
    ) -> Result<super::input_writer::PreparedControl, TurnStartError> {
        super::InputWriter::prepare_control(&new_session_uuid(), request)
            .map_err(TurnStartError::from)
    }

    pub(super) async fn runtime_control(
        &self,
        thread_id: &str,
        pid: i32,
        request: Value,
    ) -> Result<Value, TurnStartError> {
        let prepared = Self::prepare_runtime_control(&request)?;
        self.runtime_control_prepared(thread_id, pid, prepared)
            .await
    }

    pub(super) async fn runtime_control_prepared(
        &self,
        thread_id: &str,
        pid: i32,
        prepared: super::input_writer::PreparedControl,
    ) -> Result<Value, TurnStartError> {
        let request_id = prepared.request_id().to_owned();
        let (sender, receiver) = oneshot::channel();
        let input = self
            .begin_runtime_control(thread_id, pid, &request_id, sender)
            .await
            .map_err(TurnStartError::from)?;
        let result = tokio::time::timeout(
            Duration::from_secs(30),
            self.runtime_control_reply(thread_id, pid, input, prepared, receiver),
        )
        .await
        .unwrap_or_else(|_| {
            Err(TurnStartError::unresponsive(
                "Claude did not answer a control request within 30 s; the task is still running. A macOS permission prompt on the host can cause this",
            ))
        });
        self.remove_control_reply(thread_id, pid, &request_id).await;
        result
    }

    pub(super) async fn runtime_rename_control(
        &self,
        thread_id: &str,
        pid: i32,
        request: Value,
        lifecycle: tokio::sync::OwnedMutexGuard<()>,
    ) -> Result<Value, String> {
        let prepared = Self::prepare_runtime_control(&request).map_err(|error| error.message)?;
        let request_id = prepared.request_id().to_owned();
        let (sender, receiver) = oneshot::channel();
        let input = self
            .begin_runtime_control(thread_id, pid, &request_id, sender)
            .await?;
        drop(lifecycle);
        let result = self
            .runtime_control_reply(thread_id, pid, input, prepared, receiver)
            .await;
        self.remove_control_reply(thread_id, pid, &request_id).await;
        result.map_err(|error| error.message)
    }

    pub(super) async fn cancel_runtime_control(&self, thread_id: &str, pid: i32, request_id: &str) {
        let input = self
            .runtimes
            .lock()
            .await
            .get(thread_id)
            .filter(|runtime| runtime.process_group_id == pid)
            .map(|runtime| runtime.input.clone());
        let Some(input) = input else {
            return;
        };
        let cancelled = match super::InputWriter::prepare_control_cancel(request_id) {
            Ok(cancel) => input.send_prepared_control(cancel).await,
            Err(error) => Err(error),
        };
        if let Err(error) = cancelled {
            warn!(
                thread_id,
                request_id, "Claude control cancellation failed: {error}"
            );
        }
    }

    async fn remove_control_reply(&self, thread_id: &str, pid: i32, request_id: &str) {
        if let Some(runtime) = self
            .runtimes
            .lock()
            .await
            .get_mut(thread_id)
            .filter(|runtime| runtime.process_group_id == pid)
        {
            runtime.pending_controls.remove(request_id);
        }
    }

    async fn begin_runtime_control(
        &self,
        thread_id: &str,
        pid: i32,
        request_id: &str,
        sender: oneshot::Sender<Result<Value, String>>,
    ) -> Result<super::InputWriter, String> {
        let input = {
            let mut runtimes = self.runtimes.lock().await;
            let runtime = runtimes
                .get_mut(thread_id)
                .filter(|runtime| runtime.process_group_id == pid)
                .ok_or("Claude runtime is no longer available")?;
            runtime
                .pending_controls
                .retain(|_, pending| !pending.is_closed());
            runtime
                .pending_controls
                .insert(request_id.to_owned(), sender);
            runtime.input.clone()
        };
        Ok(input)
    }

    async fn runtime_control_reply(
        &self,
        thread_id: &str,
        pid: i32,
        input: super::InputWriter,
        prepared: super::input_writer::PreparedControl,
        receiver: oneshot::Receiver<Result<Value, String>>,
    ) -> Result<Value, TurnStartError> {
        if let Err(error) = input.send_prepared_control(prepared).await {
            if super::InputWriter::is_stalled(&error) {
                return Err(self.input_stalled(thread_id, pid, "control", error));
            }
            let message = format!("failed writing a Claude control request: {error}");
            self.retire_after_write_failure(thread_id, pid, &message)
                .await;
            return Err(TurnStartError::internal(message));
        }
        receiver
            .await
            .map_err(|_| TurnStartError::internal("Claude runtime ended during a control request"))?
            .map_err(TurnStartError::from)
    }

    pub(super) async fn read_stderr(
        &self,
        thread_id: String,
        process_group_id: i32,
        stderr: ChildStderr,
        shutdown: CancellationToken,
    ) {
        let mut reader = BufReader::new(stderr);
        let mut bytes = Vec::new();
        loop {
            let Some(read) = shutdown
                .run_until_cancelled(read_stream_line(
                    &mut reader,
                    &mut bytes,
                    MAX_STDERR_RECORD_BYTES,
                    "stderr record bytes",
                ))
                .await
            else {
                return;
            };
            match read {
                Ok(true) => {}
                Ok(false) => return,
                Err(error) => {
                    if let Some(capacity) = error
                        .get_ref()
                        .and_then(|error| error.downcast_ref::<CapacityExceeded>())
                    {
                        self.emit_capacity_failure(&thread_id, capacity).await;
                    }
                    self.fail_runtime(
                        &thread_id,
                        process_group_id,
                        "failed",
                        Some(format!("Claude stderr read failed: {error}")),
                    )
                    .await;
                    return;
                }
            }
            let line = String::from_utf8_lossy(&bytes)
                .trim_end_matches(['\r', '\n'])
                .to_string();
            if line.trim().is_empty() {
                continue;
            }
            let ring = {
                let runtimes = self.runtimes.lock().await;
                runtimes.get(&thread_id).and_then(|runtime| {
                    (runtime.process_group_id == process_group_id)
                        .then(|| Arc::clone(&runtime.stderr_ring))
                })
            };
            let Some(ring) = ring else { return };
            {
                let mut ring = ring.lock().await;
                if ring.len() >= STDERR_RING_CAPACITY {
                    ring.remove(0);
                }
                ring.push(line.clone());
            }
            self.emit(json!({
                "method": "daemon/claudeStderr",
                "params": { "threadId": thread_id, "line": line }
            }))
            .await;
        }
    }

    pub(super) async fn read_runtime_stream(
        self: Arc<Self>,
        thread_id: String,
        process_group_id: i32,
        stdout: ChildStdout,
        shutdown: CancellationToken,
    ) {
        let mut reader = BufReader::new(stdout);
        let mut bytes = Vec::new();
        let stream_failure = loop {
            let Some(read) = shutdown
                .run_until_cancelled(read_stream_line(
                    &mut reader,
                    &mut bytes,
                    MAX_STDOUT_RECORD_BYTES,
                    "stdout record bytes",
                ))
                .await
            else {
                return;
            };
            match read {
                Ok(true) => {}
                Ok(false) => break "Claude stream ended unexpectedly".to_string(),
                Err(error) => {
                    if let Some(capacity) = error
                        .get_ref()
                        .and_then(|error| error.downcast_ref::<CapacityExceeded>())
                    {
                        self.emit_capacity_failure(&thread_id, capacity).await;
                    }
                    break format!("Claude stream read failed: {error}");
                }
            }
            let trimmed = match std::str::from_utf8(&bytes) {
                Ok(line) => line.trim(),
                Err(error) => break format!("Claude stream is not UTF-8: {error}"),
            };
            if trimmed.is_empty() {
                continue;
            }
            let value: Value = match serde_json::from_str(trimmed) {
                Ok(value) => value,
                Err(err) => {
                    debug!(%err, "skipping malformed claude stream line");
                    continue;
                }
            };
            let is_initialization = value.get("type").and_then(Value::as_str) == Some("system")
                && value.get("subtype").and_then(Value::as_str) == Some("init");

            if value.get("subtype").and_then(Value::as_str) == Some("init") {
                let field = |key: &str| {
                    value
                        .get(key)
                        .and_then(Value::as_str)
                        .unwrap_or("?")
                        .to_string()
                };
                info!(
                    api_key_source = %field("apiKeySource"),
                    fast_mode_state = %field("fast_mode_state"),
                    claude_code_version = %field("claude_code_version"),
                    "claude runtime initialised"
                );
                if !value["tools"]
                    .as_array()
                    .is_some_and(|tools| tools.iter().any(|tool| tool == SEND_USER_MESSAGE))
                {
                    warn!(
                        claude_code_version = %field("claude_code_version"),
                        "claude runtime does not offer SendUserMessage; verbatim mid-turn text cannot reach the app"
                    );
                }
            }

            // The subscription guard lives here rather than in the translator
            // because `system/init` fires per turn, and the init of a turn the
            // stream opens on its own arrives while no turn is active.
            if is_initialization
                && let Some(violation) = crate::providers::claude::translate::billing_violation(
                    &value,
                    self.fast_selected(&thread_id, process_group_id).await,
                )
            {
                self.kill_for_billing_violation(&thread_id, process_group_id, &violation.0)
                    .await;
                return;
            }

            self.observe_child_agents(&thread_id, process_group_id, &value)
                .await;

            if is_background_tasks_change(&value) {
                self.track_background_tasks(&thread_id, process_group_id, &value)
                    .await;
            }

            self.wait_for_finishing_turn(&thread_id).await;
            let mut opened: Option<Value> = None;
            let translated = {
                let mut runtimes = self.runtimes.lock().await;
                let Some(runtime) = runtimes.get_mut(&thread_id) else {
                    return;
                };
                if runtime.process_group_id != process_group_id {
                    return;
                }
                let consumed = consumed_input_ids(&value);
                let taken = runtime.input.unconsumed().take(&consumed);
                let evidence = consumed
                    .iter()
                    .copied()
                    .chain(taken.iter().map(String::as_str))
                    .collect::<Vec<_>>();
                if value.get("type").and_then(Value::as_str) == Some("control_response") {
                    let response = &value["response"];
                    if let Some(sender) = response["request_id"]
                        .as_str()
                        .and_then(|id| runtime.pending_controls.remove(id))
                    {
                        let result = if response["subtype"] == "success" {
                            Ok(response["response"].clone())
                        } else {
                            Err(response["error"]
                                .as_str()
                                .unwrap_or("Claude control request failed")
                                .to_string())
                        };
                        let _ = sender.send(result);
                    }
                    continue;
                }
                if runtime
                    .active_turn
                    .as_ref()
                    .is_some_and(super::RuntimeTurn::is_stopping)
                {
                    continue;
                }
                if is_initialization {
                    runtime.initialized = true;
                }
                if runtime.active_turn.is_none() {
                    opened = self.open_agent_initiated_turn(runtime, &thread_id, &value);
                }
                // Still none: the line was ambient or subagent-inner and
                // deliberately did not open a turn.
                let Some(active) = runtime.active_turn.as_mut() else {
                    continue;
                };
                if !active.admits(&value, &evidence) {
                    info!(
                        %thread_id,
                        turn_id = active.translator.turn_id(),
                        origin = %value["origin"]["kind"],
                        "Claude result answers earlier input; the dispatched turn stays open"
                    );
                    continue;
                }
                active.translator.handle(&value)
            };

            for (item_id, capacity) in translated.live_prefix_failures {
                self.journal.runtime(
                    "livePrefixCapacity",
                    json!({
                        "threadId":thread_id, "pid":process_group_id, "itemId":item_id, "reason":capacity.to_value()
                    }),
                );
            }

            if let Some(started) = opened {
                self.emit(started).await;
            }

            for notification in translated.notifications {
                self.emit(notification).await;
            }

            if let Some(capacity) = translated.capacity_error {
                self.emit_capacity_failure(&thread_id, &capacity).await;
                break capacity.to_string();
            }

            if let Some(result) = translated.result {
                self.finish_turn(&thread_id, process_group_id, result).await;
            }
        };

        self.fail_runtime(&thread_id, process_group_id, "failed", Some(stream_failure))
            .await;
    }

    async fn emit_capacity_failure(&self, thread_id: &str, capacity: &CapacityExceeded) {
        self.emit(json!({"method":"error", "params":{
            "threadId":thread_id, "willRetry":false,
            "error":{"message":capacity.to_string(), "codexErrorInfo":null,
                "additionalDetails":null},
            "data":capacity.to_value()
        }}))
        .await;
    }

    /// Opens a turn for output that arrived with no dispatched turn — a peer
    /// message, a background-subagent completion, a scheduled wake — and
    /// registers it like any other active turn, so the whole downstream path
    /// (notifications, APNs, Live Activities, voice) needs no special case.
    /// Returns the `turn/started` frame to emit, or `None` for a line that must
    /// not open a turn.
    pub(super) fn open_agent_initiated_turn(
        &self,
        runtime: &mut ClaudeRuntime,
        thread_id: &str,
        value: &Value,
    ) -> Option<Value> {
        // Background-subagent traffic streams between turns with
        // `parent_tool_use_id` set; it belongs to its parent Task item.
        if value
            .get("parent_tool_use_id")
            .is_some_and(|parent| !parent.is_null())
        {
            return None;
        }
        if !opens_turn(value) {
            debug!(%thread_id, "ignoring ambient Claude stream line outside a turn");
            return None;
        }

        let (turn_id, translator) = self.new_turn(thread_id, &runtime.cwd);
        let mut started = translator.turn_started();
        annotate_agent_initiated(&mut started, wake_reason(value).as_ref());
        // The idle timer armed when the previous turn finished must not retire a
        // runtime that has just woken up.
        runtime.idle = None;
        runtime.lifecycle_generation = runtime.lifecycle_generation.wrapping_add(1);
        runtime.active_turn = Some(RuntimeTurn::new(translator, true, None));
        info!(%thread_id, %turn_id, "agent-initiated Claude turn started");
        Some(started)
    }

    async fn fast_selected(&self, thread_id: &str, process_group_id: i32) -> bool {
        self.runtimes
            .lock()
            .await
            .get(thread_id)
            .filter(|runtime| runtime.process_group_id == process_group_id)
            .and_then(|runtime| runtime.settings.as_ref())
            .is_some_and(ClaudeRuntimeSettings::permits_fast)
    }

    /// Kills a runtime that reported it would not bill the claude.ai
    /// subscription.
    async fn kill_for_billing_violation(
        &self,
        thread_id: &str,
        process_group_id: i32,
        reason: &str,
    ) {
        error!(reason, "killing Claude runtime: billing guard failed");
        self.journal.runtime(
            "billing_kill",
            serde_json::json!({
                "threadId": thread_id,
                "pid": process_group_id,
                "reason": reason,
            }),
        );
        self.fail_runtime(
            thread_id,
            process_group_id,
            "failed",
            Some(format!("billing guard: {reason}")),
        )
        .await;
    }

    pub(super) async fn finish_turn(
        self: &Arc<Self>,
        thread_id: &str,
        process_group_id: i32,
        result: TurnResult,
    ) {
        let (turn_id, completed) = {
            let mut runtimes = self.runtimes.lock().await;
            let Some(active) = runtimes
                .get_mut(thread_id)
                .filter(|runtime| runtime.process_group_id == process_group_id)
                .and_then(ClaudeRuntime::running_turn_mut)
            else {
                return;
            };
            active.phase = TurnPhase::Finishing;
            active.translator.end_live_state();
            let mut completed = active.translator.turn_completed(
                &result.status,
                result.error_message.as_deref(),
                result.error_info,
            );
            if active.agent_initiated {
                annotate_agent_initiated(&mut completed, None);
            }
            (active.translator.turn_id().to_owned(), completed)
        };
        let completed = self.record(completed).await;
        let settled = {
            let mut runtimes = self.runtimes.lock().await;
            let finished = runtimes
                .get_mut(thread_id)
                .filter(|runtime| runtime.process_group_id == process_group_id)
                .and_then(|runtime| {
                    let active = runtime.active_turn.take_if(|turn| {
                        turn.phase == TurnPhase::Finishing && turn.translator.turn_id() == turn_id
                    })?;
                    let mismatch = active
                        .translator
                        .session_id()
                        .filter(|reported| *reported != runtime.session_uuid)
                        .map(str::to_owned);
                    Some((
                        mismatch,
                        runtime.session_uuid.clone(),
                        runtime.lifecycle_generation,
                    ))
                });
            if let Some((Some(_), ..)) = &finished {
                runtimes.remove(thread_id);
            }
            finished
        };
        self.turn_settled.notify_waiters();
        if let Some((Some(reported), expected, _)) = &settled {
            warn!(
                thread_id,
                requested = %expected,
                reported = %reported,
                "Claude reported a different session id; retiring the runtime"
            );
            self.terminate_group(Pid::from_raw(process_group_id)).await;
        }

        self.publish(completed).await;
        if let Some((None, _, lifecycle_generation)) = settled {
            self.schedule_runtime_idle_timeout(
                thread_id.to_string(),
                process_group_id,
                lifecycle_generation,
            )
            .await;
        }
        info!(thread_id, status = %result.status, "claude turn finished");
    }
}
