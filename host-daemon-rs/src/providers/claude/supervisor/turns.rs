use super::input_writer::InputSlot;
use super::{
    ClaudeRuntime, ClaudeSupervisor, InputWriter, ProcessAdmission, RuntimeTurn, TurnControlError,
    TurnErrorData, TurnOrigin, TurnPhase, TurnStartError, annotate_agent_initiated, lifecycle,
};
use crate::ids::new_session_uuid;
use crate::providers::claude::translate::TurnTranslator;
use crate::providers::claude::{ClaudeTurnRequest, ClaudeUserInput, claude_thread_id};
use crate::rpc::error::RpcCode;
use nix::unistd::Pid;
use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use tracing::{debug, info, warn};

impl ClaudeSupervisor {
    /// Starts a turn and returns its id once the prompt reaches Claude's stdin.
    ///
    /// A second turn on a busy thread is rejected rather than queued: a silently
    /// queued turn looks identical to a hung one from the phone. `steer` is the
    /// explicit path for adding guidance to the active turn.
    pub(crate) async fn start_turn(
        self: &Arc<Self>,
        request: ClaudeTurnRequest,
    ) -> Result<String, TurnStartError> {
        let _start_guard = self.lifecycles.lock(&request.thread_id).await;
        self.start_turn_locked(request, TurnOrigin::Dispatched)
            .await
    }

    /// A local CLI command must never fold into an agent-initiated response.
    pub(crate) async fn start_compaction(
        self: &Arc<Self>,
        mut request: ClaudeTurnRequest,
    ) -> Result<String, TurnStartError> {
        let _guard = self.lifecycles.lock(&request.thread_id).await;
        self.wait_for_finishing_turn(&request.thread_id).await;
        let reservation = self.reserve_start(&request).await?;
        // Preserve the effective warm selection, including an acknowledged setting
        // change that has not yet appeared in an assistant transcript record.
        if let Some(runtime) = self.runtimes.lock().await.get(&request.thread_id) {
            let settings = runtime.settings.as_ref().ok_or_else(|| TurnStartError {
                data: None,
                code: RpcCode::Unavailable,
                message: "Claude settings are unavailable; retry after reconnecting".into(),
            })?;
            request.selection = settings.effective().clone();
        } else if let Some(selection) = self.parent_selection(&request.thread_id).await {
            request.selection = selection;
        }
        drop(reservation);
        self.start_turn_locked(request, TurnOrigin::Dispatched)
            .await
    }

    pub(crate) async fn start_voice_turn(
        self: &Arc<Self>,
        mut request: ClaudeTurnRequest,
    ) -> Result<String, TurnStartError> {
        let _start_guard = self.lifecycles.lock(&request.thread_id).await;
        if let Some(runtime) = self.runtimes.lock().await.get(&request.thread_id) {
            let settings = runtime.settings.as_ref().ok_or_else(|| TurnStartError {
                data: None,
                code: RpcCode::Internal,
                message: "Claude settings could not be confirmed; retry the settings change"
                    .to_string(),
            })?;
            request.selection = settings.effective().clone();
        }
        self.start_turn_locked(request, TurnOrigin::Dispatched)
            .await
    }

    pub(super) async fn start_turn_locked(
        self: &Arc<Self>,
        mut request: ClaudeTurnRequest,
        origin: TurnOrigin,
    ) -> Result<String, TurnStartError> {
        request.input.client_id.get_or_insert_with(new_session_uuid);
        let prepared = super::input_writer::InputWriter::prepare_input(&request.input)
            .map_err(TurnStartError::from)?;
        let stop_generation = self
            .stop_generation(&request.thread_id)
            .await
            .map_err(|error| TurnStartError {
                data: None,
                code: RpcCode::Internal,
                message: format!("the Stop state could not be read: {error:#}"),
            })?;
        self.check_callback_generation(&request.thread_id, origin)
            .await?;
        self.wait_for_finishing_turn(&request.thread_id).await;
        if self
            .runtimes
            .lock()
            .await
            .get(&request.thread_id)
            .is_some_and(|runtime| {
                runtime
                    .running_turn()
                    .is_some_and(|turn| !turn.agent_initiated)
            })
        {
            self.reserve_start(&request).await?;
        }
        let update_warm_runtime = self
            .runtimes
            .lock()
            .await
            .get(&request.thread_id)
            .is_some_and(|runtime| {
                runtime.session_uuid == request.session_uuid
                    && runtime.cwd == request.cwd
                    && !runtime
                        .settings
                        .as_ref()
                        .is_some_and(|settings| settings.accepts(&request))
            });
        if update_warm_runtime
            && let Err(message) = self
                .apply_runtime_settings(&request.thread_id, &request.selection)
                .await
        {
            if matches!(message.data, Some(TurnErrorData::Capacity(_))) {
                return Err(message);
            }
            let idle = self
                .runtimes
                .lock()
                .await
                .get(&request.thread_id)
                .is_some_and(ClaudeRuntime::is_idle);
            if !idle {
                return Err(match message.data {
                    Some(TurnErrorData::DeliveryUncertain) => {
                        TurnStartError::unresponsive(message.message)
                    }
                    _ => message,
                });
            }
            warn!(%message, thread_id = %request.thread_id, "retiring idle Claude runtime after an unconfirmed settings change");
            if let Some(runtime) = self.runtimes.lock().await.get_mut(&request.thread_id) {
                runtime.settings = None;
            }
        }
        if request.input.text != "/compact" {
            let folded = self
                .fold_into_agent_initiated_turn(&request, &prepared, origin)
                .await;
            if matches!(&folded, Ok(Some(_)))
                || matches!(&folded, Err(error) if error.is_queued_stall())
            {
                self.remember_parent(&request, origin, stop_generation)
                    .await;
            }
            if let Some(turn_id) = folded? {
                return Ok(turn_id);
            }
        }
        let _admission = self.reserve_start(&request).await?;

        let (turn_id, mut translator) = self.new_turn(&request.thread_id, &request.cwd);
        if request.input.text == "/compact" {
            translator.expect_manual_compaction();
        }
        let agent_initiated = matches!(origin, TurnOrigin::Callback { .. });
        let mut started_notification = translator.turn_started();
        if agent_initiated {
            annotate_agent_initiated(&mut started_notification, None);
        }

        let stale_group = {
            let mut runtimes = self.runtimes.lock().await;
            match runtimes.get(&request.thread_id) {
                Some(runtime) if runtime.matches(&request) => None,
                Some(runtime) => {
                    let group = runtime.process_group_id;
                    runtimes.remove(&request.thread_id);
                    Some(group)
                }
                None => None,
            }
        };
        if let Some(group) = stale_group {
            self.journal.runtime(
                "retire",
                serde_json::json!({
                    "reason": "configuration changed",
                    "threadId": request.thread_id,
                    "pid": group,
                    "model": request.selection.model,
                    "effort": request.selection.effort,
                    "fast": request.selection.fast,
                    "cwd": request.cwd,
                }),
            );
            self.terminate_group(Pid::from_raw(group)).await;
        }

        let warm = self
            .reserve_warm_input(&request.thread_id, "turn/start")
            .await?;
        self.check_callback_generation(&request.thread_id, origin)
            .await?;
        let (slot, process_group_id, mut process_admission) = {
            let mut runtimes = self.runtimes.lock().await;
            if let Some(runtime) = runtimes.get_mut(&request.thread_id) {
                let Some((group, slot)) =
                    warm.filter(|(group, _)| *group == runtime.process_group_id)
                else {
                    return Err(TurnStartError::internal(
                        "the Claude runtime changed while this turn was starting; send it again",
                    ));
                };
                runtime.idle = None;
                runtime.lifecycle_generation = runtime.lifecycle_generation.wrapping_add(1);
                runtime.active_turn = Some(RuntimeTurn::new(
                    translator,
                    agent_initiated,
                    request.input.client_id.clone(),
                ));
                (
                    slot,
                    group,
                    ProcessAdmission::new(group, Arc::clone(&self.process_registry)),
                )
            } else {
                drop(runtimes);
                let spawned = self.spawn_runtime(&request)?;
                let slot = spawned.runtime.input.reserve().await?;
                let process_admission = spawned.admission;
                let process_group_id = spawned.process_group_id;
                let stdout = spawned.stdout;
                let stderr = spawned.stderr;

                let mut runtime = spawned.runtime;
                runtime.active_turn = Some(RuntimeTurn::new(
                    translator,
                    agent_initiated,
                    request.input.client_id.clone(),
                ));
                self.runtimes
                    .lock()
                    .await
                    .insert(request.thread_id.clone(), runtime);
                self.journal.runtime(
                    "spawn",
                    serde_json::json!({
                        "threadId": request.thread_id,
                        "pid": process_group_id,
                        "model": request.selection.model,
                        "effort": request.selection.effort,
                        "fast": request.selection.fast,
                        "cwd": request.cwd,
                        "sessionUuid": request.session_uuid,
                    }),
                );
                self.start_runtime_tasks(
                    request.thread_id.clone(),
                    process_group_id,
                    stdout,
                    stderr,
                );
                (slot, process_group_id, process_admission)
            }
        };

        self.emit(started_notification).await;

        self.check_callback_generation(&request.thread_id, origin)
            .await?;
        let pending = {
            let runtimes = self.runtimes.lock().await;
            if !runtimes.get(&request.thread_id).is_some_and(|runtime| {
                runtime.process_group_id == process_group_id && runtime.running_turn().is_some()
            }) {
                return Err(TurnStartError::internal(
                    "Claude runtime stopped before its input was submitted",
                ));
            }
            slot.send_input(Arc::clone(&prepared))
        };
        if let Err(err) = pending.written().await {
            if InputWriter::is_stalled(&err) {
                process_admission.accept();
                self.remember_parent(&request, origin, stop_generation)
                    .await;
                return Err(self.input_stalled(
                    &request.thread_id,
                    process_group_id,
                    "turn/start",
                    err,
                ));
            }
            self.fail_runtime(
                &request.thread_id,
                process_group_id,
                "failed",
                Some(format!("failed writing Claude prompt: {err}")),
            )
            .await;
            return Err(TurnStartError {
                data: None,
                code: RpcCode::Internal,
                message: format!("failed writing Claude prompt: {err}"),
            });
        }

        self.ensure_runtime_current(&request.thread_id, process_group_id)
            .await?;
        process_admission.accept();
        self.remember_parent(&request, origin, stop_generation)
            .await;

        // A turn ends when Claude ends it, when the process dies (the stream reader
        // fails the runtime), or when the user interrupts. Deliberately no wall-clock
        // cap: a single turn legitimately runs for hours, and a long silent tool call
        // is indistinguishable from a wedged process, so a timer can only kill healthy
        // work. Codex turns have never had one either.
        info!(
            thread_id = %request.thread_id,
            turn_id = %turn_id,
            pid = process_group_id,
            model = %request.selection.model,
            fast = request.selection.fast,
            first_turn = request.first_turn,
            "claude turn started"
        );
        Ok(turn_id)
    }

    /// Allocates a fresh turn id and its translator for a thread.
    pub(super) fn new_turn(&self, thread_id: &str, cwd: &str) -> (String, TurnTranslator) {
        let turn_id = format!(
            "claude-turn-{}-{}",
            crate::time::unix_millis(),
            self.next_turn_sequence.fetch_add(1, Ordering::Relaxed)
        );
        let translator = TurnTranslator::new(
            thread_id.to_string(),
            turn_id.clone(),
            cwd.to_string(),
            self.settings.auto_compact_window(std::path::Path::new(cwd)),
            crate::time::unix_millis(),
            self.live_prefix_budget.clone(),
        );
        (turn_id, translator)
    }

    /// Folds a dispatched turn into a running agent-initiated one.
    ///
    /// Claude's streaming input joins new input into the active query and the
    /// next `result` closes the combined work, so the agent-initiated turn is
    /// completed at the fold point and the dispatched turn takes over the
    /// stream: the caller gets its own turn id and the CLI's single result
    /// still closes exactly one open turn. Returns `Ok(None)` when no
    /// agent-initiated turn is running and normal dispatch applies.
    async fn fold_into_agent_initiated_turn(
        self: &Arc<Self>,
        request: &ClaudeTurnRequest,
        prepared: &Arc<super::input_writer::PreparedInput>,
        origin: TurnOrigin,
    ) -> Result<Option<String>, TurnStartError> {
        // Cheap first: building a translator reads Claude's settings files, so
        // ordinary dispatch must not pay for it twice.
        let folds = {
            let runtimes = self.runtimes.lock().await;
            runtimes
                .get(&request.thread_id)
                .and_then(ClaudeRuntime::running_turn)
                .is_some_and(|active| active.agent_initiated)
        };
        if !folds {
            return Ok(None);
        }
        let Some((reserved_group, slot)) = self
            .reserve_warm_input(&request.thread_id, "turn/start")
            .await?
        else {
            return Ok(None);
        };

        let (turn_id, translator) = self.new_turn(&request.thread_id, &request.cwd);
        let started = translator.turn_started();
        let dispatched = RuntimeTurn::new(translator, false, request.input.client_id.clone());

        let closing_wake = {
            let mut runtimes = self.runtimes.lock().await;
            runtimes
                .get_mut(&request.thread_id)
                .filter(|runtime| runtime.process_group_id == reserved_group)
                .and_then(|runtime| {
                    let group = runtime.process_group_id;
                    let wake = runtime
                        .running_turn_mut()
                        .filter(|active| active.agent_initiated)?;
                    wake.phase = TurnPhase::Finishing;
                    wake.translator.end_live_state();
                    let mut completed = wake.translator.turn_completed("completed", None, None);
                    annotate_agent_initiated(&mut completed, None);
                    Some((group, wake.translator.turn_id().to_owned(), completed))
                })
        };
        // The agent-initiated turn ended while the translator was being built;
        // the normal dispatch path applies.
        let Some((process_group_id, wake_turn_id, completed)) = closing_wake else {
            return Ok(None);
        };
        let completed = self.record(completed).await;
        let folded = {
            let mut runtimes = self.runtimes.lock().await;
            match runtimes
                .get_mut(&request.thread_id)
                .filter(|runtime| runtime.process_group_id == process_group_id)
            {
                Some(runtime)
                    if runtime.active_turn.as_ref().is_some_and(|active| {
                        active.phase == TurnPhase::Finishing
                            && active.translator.turn_id() == wake_turn_id
                    }) =>
                {
                    if !runtime.matches(request) {
                        debug!(
                            thread_id = %request.thread_id,
                            requested = %request.selection,
                            running_settings = ?runtime.settings,
                            "folded dispatch keeps the running Claude configuration"
                        );
                    }
                    runtime.active_turn = Some(dispatched);
                    true
                }
                _ => false,
            }
        };
        self.turn_settled.notify_waiters();
        if !folded {
            self.publish(completed).await;
            return Ok(None);
        }

        let mut process_admission =
            ProcessAdmission::new(process_group_id, Arc::clone(&self.process_registry));
        self.publish(completed).await;
        self.emit(started).await;

        self.check_callback_generation(&request.thread_id, origin)
            .await?;
        let pending = {
            let runtimes = self.runtimes.lock().await;
            if !runtimes.get(&request.thread_id).is_some_and(|runtime| {
                runtime.process_group_id == process_group_id && runtime.running_turn().is_some()
            }) {
                return Err(TurnStartError::internal(
                    "Claude runtime stopped before its input was submitted",
                ));
            }
            slot.send_input(Arc::clone(prepared))
        };
        if let Err(err) = pending.written().await {
            if InputWriter::is_stalled(&err) {
                process_admission.accept();
                return Err(self.input_stalled(
                    &request.thread_id,
                    process_group_id,
                    "turn/start",
                    err,
                ));
            }
            self.fail_runtime(
                &request.thread_id,
                process_group_id,
                "failed",
                Some(format!("failed writing Claude prompt: {err}")),
            )
            .await;
            return Err(TurnStartError {
                data: None,
                code: RpcCode::Internal,
                message: format!("failed writing Claude prompt: {err}"),
            });
        }
        self.ensure_runtime_current(&request.thread_id, process_group_id)
            .await?;
        process_admission.accept();
        info!(
            thread_id = %request.thread_id,
            turn_id = %turn_id,
            pid = process_group_id,
            folded_into_agent_initiated = true,
            "claude turn started"
        );
        Ok(Some(turn_id))
    }

    /// Adds user guidance to the active turn through Claude's documented
    /// stream-json input channel. Intermediate result frames stay inside the
    /// same RemoteCoder turn until every queued input has been processed.
    pub(crate) async fn steer(
        &self,
        thread_id: &str,
        expected_turn_id: &str,
        input: &ClaudeUserInput,
    ) -> Result<(), TurnControlError> {
        let lifecycle = self.lifecycles.lock(thread_id).await;
        let (writer, process_group_id) = {
            let mut runtimes = self.runtimes.lock().await;
            let Some(runtime) = runtimes.get_mut(thread_id) else {
                return Err(TurnControlError::NotRunning {
                    message: format!("thread {thread_id} has no running Claude process"),
                });
            };
            let Some(_active) = runtime
                .running_turn_mut()
                .filter(|active| active.translator.turn_id() == expected_turn_id)
            else {
                return Err(TurnControlError::NotRunning {
                    message: format!("thread {thread_id} has no active turn to steer"),
                });
            };
            (runtime.input.clone(), runtime.process_group_id)
        };

        let prepared = InputWriter::prepare_input(input).map_err(TurnStartError::from)?;
        let delivered = match writer.reserve().await {
            Ok(slot) => {
                let pending = slot.send_input(prepared);
                drop(lifecycle);
                pending.written().await
            }
            Err(error) => Err(error),
        };
        if let Err(err) = delivered {
            if InputWriter::is_stalled(&err) {
                return Err(self
                    .input_stalled(thread_id, process_group_id, "turn/steer", err)
                    .into());
            }
            let message = format!("failed steering Claude: {err}");
            self.retire_after_write_failure(thread_id, process_group_id, &message)
                .await;
            return Err(TurnStartError {
                data: None,
                code: RpcCode::Internal,
                message,
            }
            .into());
        }
        self.ensure_runtime_current(thread_id, process_group_id)
            .await?;
        Ok(())
    }

    async fn reserve_warm_input(
        &self,
        thread_id: &str,
        operation: &str,
    ) -> Result<Option<(i32, InputSlot)>, TurnStartError> {
        let warm = self
            .runtimes
            .lock()
            .await
            .get(thread_id)
            .map(|runtime| (runtime.process_group_id, runtime.input.clone()));
        let Some((group, input)) = warm else {
            return Ok(None);
        };
        match input.reserve().await {
            Ok(slot) => Ok(Some((group, slot))),
            Err(error) if InputWriter::is_stalled(&error) => {
                Err(self.input_stalled(thread_id, group, operation, error))
            }
            Err(error) => {
                let message = format!("failed writing Claude prompt: {error}");
                self.retire_after_write_failure(thread_id, group, &message)
                    .await;
                Err(TurnStartError::internal(message))
            }
        }
    }

    pub(super) async fn ensure_runtime_current(
        &self,
        thread: &str,
        group: i32,
    ) -> Result<(), TurnStartError> {
        if self
            .runtimes
            .lock()
            .await
            .get(thread)
            .is_some_and(|runtime| {
                runtime.process_group_id == group
                    && !runtime
                        .active_turn
                        .as_ref()
                        .is_some_and(super::RuntimeTurn::is_stopping)
            })
        {
            Ok(())
        } else {
            Err(TurnStartError {
                data: None,
                code: RpcCode::Unavailable,
                message: "Claude runtime stopped before the operation was confirmed".into(),
            })
        }
    }

    pub(super) async fn reserve_start(
        &self,
        request: &ClaudeTurnRequest,
    ) -> Result<lifecycle::StartReservation, TurnStartError> {
        let runtimes = self.runtimes.lock().await;
        if self
            .process_registry
            .lock()
            .expect("Claude process registry poisoned")
            .closing
        {
            return Err(TurnStartError {
                data: None,
                code: RpcCode::ServerBusy,
                message: "Claude runtime owner is stopping".into(),
            });
        }
        if let Some(active) = runtimes
            .get(&request.thread_id)
            .and_then(|runtime| runtime.active_turn.as_ref())
        {
            return Err(TurnStartError {
                data: None,
                code: RpcCode::ServerBusy,
                message: format!(
                    "thread {} already has turn {} running",
                    request.thread_id,
                    active.translator.turn_id()
                ),
            });
        }
        let mut starts = self
            .starting
            .lock()
            .expect("Claude start reservations poisoned");
        if !starts.insert(request.thread_id.clone()) {
            return Err(TurnStartError {
                data: None,
                code: RpcCode::ServerBusy,
                message: format!("thread {} already has a turn starting", request.thread_id),
            });
        }
        Ok(lifecycle::StartReservation {
            thread_id: request.thread_id.clone(),
            starts: Arc::clone(&self.starting),
        })
    }

    pub(crate) async fn mint_session(&self) -> anyhow::Result<String> {
        let session_uuid = new_session_uuid();
        self.conversation_index
            .record_minted(&claude_thread_id(&session_uuid))
            .await?;
        Ok(session_uuid)
    }

    pub(crate) fn is_minted(&self, thread_id: &str) -> anyhow::Result<bool> {
        self.conversation_index.is_minted(thread_id)
    }

    pub(crate) async fn fork_thread_records(
        &self,
        source_id: &str,
        target_id: &str,
        turns: HashSet<String>,
    ) -> anyhow::Result<()> {
        self.conversation_index
            .fork_thread(source_id, target_id, turns)
            .await
    }

    pub(crate) fn session_history(&self, cwd: &str, session_uuid: &str) -> Option<PathBuf> {
        let canonical = fs::canonicalize(cwd)
            .ok()
            .map(|path| path.to_string_lossy().into_owned());
        std::iter::once(cwd.to_owned())
            .chain(canonical)
            .map(|cwd| {
                crate::providers::claude::timeline::session_path_for_cwd(
                    &self.settings.claude_home,
                    &cwd,
                    session_uuid,
                )
            })
            .find(|path| path.is_file())
    }
}
