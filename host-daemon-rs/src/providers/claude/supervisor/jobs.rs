use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result, ensure};
use serde_json::Value;

use super::{ClaudeSupervisor, TurnOrigin, TurnStartError, process::ReapState};
use crate::agents::jobs::model::{
    ConversationIdentity, EffectEvidence, ExecutionBinding, ExecutionSettings, JobId, JobOutcome,
    JobSpec, Provider, ProviderHome, ToolScope,
};
use crate::providers::claude::conversation_index::job::{
    Candidate, JobEvidence, JobHandle, JobInput, JobPhase, ProcessOwner, RecoveryInput,
};
use crate::providers::claude::{
    ClaudeSelection, ClaudeTurnRequest, ClaudeUserInput, session_uuid_from_thread_id,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum LaunchPolicy {
    Conversation {
        scope: ToolScope,
    },
    Job {
        handle: JobHandle,
        scope: ToolScope,
        coordination_socket: PathBuf,
    },
}

impl LaunchPolicy {
    pub(super) fn scope(&self) -> &ToolScope {
        match self {
            Self::Conversation { scope } | Self::Job { scope, .. } => scope,
        }
    }

    pub(super) fn job(&self) -> Option<&JobHandle> {
        match self {
            Self::Job { handle, .. } => Some(handle),
            Self::Conversation { .. } => None,
        }
    }

    pub(super) fn apply_args(&self, args: &mut Vec<String>) {
        if let ToolScope::ReadOnly { root } = self.scope() {
            args.extend([
                "--tools".to_owned(),
                "Read,Grep,Glob,Bash,WebSearch".to_owned(),
                "--allowedTools".to_owned(),
                [
                    "Bash(ls:*)",
                    "Bash(cat:*)",
                    "Bash(rg:*)",
                    "Bash(head:*)",
                    "Bash(tail:*)",
                    "Bash(find:*)",
                    "Bash(wc:*)",
                    "Bash(pwd:*)",
                    "Bash(message_agent:*)",
                    "Bash(set_agent_title:*)",
                    "Bash(ghp repo view:*)",
                    "Bash(ghp search repos:*)",
                    "Bash(ghp api repos/*)",
                    "Bash(ghp api search/repositories:*)",
                    "Bash(ghp api search/code:*)",
                    "Bash(ghw repo view:*)",
                    "Bash(ghw search repos:*)",
                    "Bash(ghw api repos/*)",
                    "Bash(ghw api search/repositories:*)",
                    "Bash(ghw api search/code:*)",
                ]
                .join(","),
                "--add-dir".to_owned(),
                root.to_string_lossy().into_owned(),
            ]);
        }
    }

    pub(super) fn apply_env(&self, command: &mut crate::providers::claude::exec::ClaudeCommand) {
        if let Self::Job {
            handle,
            coordination_socket,
            ..
        } = self
        {
            command.env("RC_AGENT_JOB_SOCKET", coordination_socket);
            command.env("RC_AGENT_JOB_ID", handle.job_id.as_str());
        }
    }
}

pub(crate) enum ClaudeJobInspection {
    Prepared,
    PreparedRecovery {
        recovery_input_id: String,
    },
    Running {
        binding: ExecutionBinding,
    },
    Recoverable {
        binding: ExecutionBinding,
    },
    Unknown {
        reason: String,
    },
    Finished {
        binding: Option<ExecutionBinding>,
        outcome: JobOutcome,
        candidate: Option<Candidate>,
    },
}

impl ClaudeSupervisor {
    pub(crate) fn subscribe_job_changes(&self) -> tokio::sync::watch::Receiver<()> {
        self.job_changes.subscribe()
    }

    fn validate_job_conversation(&self, conversation: &ConversationIdentity) -> Result<()> {
        ensure!(
            conversation.provider == Provider::Claude,
            "job is bound to another provider"
        );
        let ProviderHome::Known { path } = &conversation.provider_home else {
            anyhow::bail!("Claude provider home is unknown");
        };
        ensure!(
            std::fs::canonicalize(path)? == std::fs::canonicalize(&self.settings.claude_home)?,
            "Claude job is bound to a different provider home"
        );
        ensure!(
            session_uuid_from_thread_id(&conversation.thread_id).is_some(),
            "Claude thread identity is invalid"
        );
        Ok(())
    }

    pub(crate) async fn start_job(
        self: &Arc<Self>,
        job_id: &JobId,
        conversation: &ConversationIdentity,
        spec: &JobSpec,
        input_id: &str,
        coordination_socket: &Path,
        evidence_path: &Path,
    ) -> Result<ExecutionBinding> {
        self.validate_job_conversation(conversation)?;
        let ExecutionSettings::Claude {
            model,
            effort,
            fast,
        } = &spec.settings
        else {
            anyhow::bail!("Claude job has settings for another provider");
        };
        let session_uuid = session_uuid_from_thread_id(&conversation.thread_id)
            .context("Claude session is missing")?
            .to_owned();
        let _lifecycle = self.lifecycles.lock(&conversation.thread_id).await;
        let handle = JobHandle {
            job_id: job_id.clone(),
            evidence_path: evidence_path.to_owned(),
        };
        let generation = self.stop_generation(&conversation.thread_id).await?;
        let evidence = self
            .conversation_index
            .prepare_job(
                JobEvidence {
                    job_id: job_id.clone(),
                    conversation: conversation.clone(),
                    input: JobInput {
                        id: input_id.to_owned(),
                        fingerprint: crate::ids::sha256_hex(spec.prompt.as_bytes()),
                    },
                    recovery_input: None,
                    tool_scope: spec.tool_scope.clone(),
                    coordination_socket: coordination_socket.to_owned(),
                    stop_generation: generation,
                    turn_id: None,
                    owner: None,
                    input_consumed: false,
                    input_recorded: false,
                    ordinary_result_seen: false,
                    nonambient_tasks: Vec::new(),
                    candidate: None,
                    phase: JobPhase::Prepared,
                },
                &handle,
            )
            .await?;
        ensure!(
            !(matches!(evidence.phase, JobPhase::Prepared)
                && evidence.owner.is_none()
                && evidence.recovery_input.is_some()),
            "Claude job has prepared recovery input; retry its exact recovery UUID instead of replaying the original prompt"
        );
        if evidence.turn_id.is_some()
            || evidence.owner.is_some()
            || !matches!(evidence.phase, JobPhase::Prepared)
        {
            let bound = binding(&evidence).context("Claude job dispatch is unresolved")?;
            let live = self
                .runtimes
                .lock()
                .await
                .get(&conversation.thread_id)
                .is_some_and(|runtime| runtime.launch.job() == Some(&handle));
            ensure!(
                live && !matches!(evidence.phase, JobPhase::Finished { .. }),
                "Claude job already has an execution binding; inspect its exact evidence instead of dispatching again"
            );
            return Ok(bound);
        }
        let first_turn = self
            .session_history(&spec.cwd.to_string_lossy(), &session_uuid)
            .is_none();
        if first_turn {
            ensure!(
                self.creation_origin(&conversation.thread_id)?
                    == Some(
                        crate::providers::claude::conversation_index::SessionOrigin::Job {
                            job_id: job_id.clone()
                        }
                    ),
                "Claude continuation history is missing; only the exact job that created an unexecuted session may launch it fresh"
            );
        }
        let scope = spec.tool_scope.clone();
        let parent_handle = handle.clone();
        self.conversation_index
            .transact_parent(&conversation.thread_id, move |parent| {
                ensure!(
                    parent
                        .tool_scope
                        .as_ref()
                        .is_none_or(|saved| *saved == scope),
                    "Claude conversation permissions cannot change"
                );
                parent.tool_scope = Some(scope);
                parent.active_job = Some(parent_handle);
                Ok(())
            })
            .await?;
        let request = ClaudeTurnRequest {
            thread_id: conversation.thread_id.clone(),
            session_uuid,
            first_turn,
            input: ClaudeUserInput {
                client_id: Some(input_id.to_owned()),
                ..ClaudeUserInput::text(spec.prompt.clone())
            },
            selection: ClaudeSelection {
                model: model.clone(),
                effort: effort.clone(),
                fast: *fast,
            },
            cwd: spec.cwd.to_string_lossy().into_owned(),
        };
        self.start_turn_with_policy(
            request,
            TurnOrigin::Dispatched,
            LaunchPolicy::Job {
                handle: handle.clone(),
                scope: spec.tool_scope.clone(),
                coordination_socket: coordination_socket.to_owned(),
            },
        )
        .await
        .map_err(|error| anyhow::anyhow!(error.message))?;
        let evidence = self
            .conversation_index
            .job(&conversation.thread_id, &handle)
            .await?
            .context("Claude job evidence disappeared")?;
        binding(&evidence).context("Claude job has no exact turn binding after dispatch")
    }

    pub(crate) async fn inspect_job(
        &self,
        job_id: &JobId,
        conversation: &ConversationIdentity,
        evidence_path: &Path,
    ) -> Result<ClaudeJobInspection> {
        self.validate_job_conversation(conversation)?;
        let handle = JobHandle {
            job_id: job_id.clone(),
            evidence_path: evidence_path.to_owned(),
        };
        let Some(evidence) = self
            .conversation_index
            .job(&conversation.thread_id, &handle)
            .await?
        else {
            return Ok(ClaudeJobInspection::Unknown {
                reason: "Claude job execution evidence is unavailable".into(),
            });
        };
        ensure!(
            evidence.conversation == *conversation,
            "Claude job conversation identity conflicts"
        );
        let evidence = self
            .reconcile_job_input(&conversation.thread_id, &handle, evidence)
            .await?;
        if let JobPhase::Finished { ref outcome } = evidence.phase {
            return Ok(ClaudeJobInspection::Finished {
                binding: binding(&evidence),
                outcome: outcome.clone(),
                candidate: evidence.candidate,
            });
        }
        let live = self
            .runtimes
            .lock()
            .await
            .get(&conversation.thread_id)
            .is_some_and(|runtime| runtime.launch.job() == Some(&handle));
        if live {
            return Ok(match binding(&evidence) {
                Some(binding) => ClaudeJobInspection::Running { binding },
                None => ClaudeJobInspection::Unknown {
                    reason: "Claude job process is live without a committed turn binding".into(),
                },
            });
        }
        if let Some(owner) = &evidence.owner {
            let exact = owner.clone();
            if tokio::task::spawn_blocking(move || exact.alive()).await?? {
                return Ok(ClaudeJobInspection::Unknown { reason: "Claude's exact execution process is still alive without its stream owner; a second process is blocked".into() });
            }
            if super::group_exists(nix::unistd::Pid::from_raw(owner.pid)) {
                return Ok(ClaudeJobInspection::Unknown { reason: "Claude's leader is gone but its execution process group still exists; a second process is blocked".into() });
            }
        }
        if (evidence.input_consumed || evidence.input_recorded)
            && evidence.owner.is_some()
            && !matches!(evidence.phase, JobPhase::Stopping)
            && let Some(binding) = binding(&evidence)
        {
            return Ok(ClaudeJobInspection::Recoverable { binding });
        }
        Ok(match evidence.phase {
            JobPhase::Prepared if evidence.owner.is_none() && !evidence.input_recorded && !evidence.input_consumed => {
                match evidence.recovery_input {
                    Some(recovery) => ClaudeJobInspection::PreparedRecovery { recovery_input_id: recovery.input.id },
                    None if evidence.turn_id.is_none() => ClaudeJobInspection::Prepared,
                    None => ClaudeJobInspection::Unknown { reason:"Claude initial preparation unexpectedly retains a prior turn binding".into() },
                }
            }
            _ => ClaudeJobInspection::Unknown { reason: "Claude execution ended without final EOF and reap evidence; exact recovery must inspect history and state".into() },
        })
    }

    pub(crate) async fn prepare_job_retry(
        &self,
        job_id: &JobId,
        previous: &ExecutionBinding,
        spec: &JobSpec,
        input_id: &str,
        evidence_path: &Path,
    ) -> Result<()> {
        self.validate_job_conversation(&previous.conversation)?;
        let session = session_uuid_from_thread_id(&previous.conversation.thread_id)
            .context("Claude retry has no exact session")?;
        ensure!(
            self.session_history(&spec.cwd.to_string_lossy(), session)
                .is_some(),
            "Claude retry history is unavailable; refusing a new session"
        );
        let handle = JobHandle {
            job_id: job_id.clone(),
            evidence_path: evidence_path.to_owned(),
        };
        let next = JobInput {
            id: input_id.to_owned(),
            fingerprint: crate::ids::sha256_hex(spec.prompt.as_bytes()),
        };
        let previous = previous.clone();
        let thread = previous.conversation.thread_id.clone();
        let generation = self.stop_generation(&thread).await?;
        self.conversation_index
            .update_job(&thread, &handle, move |saved| {
                ensure!(
                    saved.stop_generation == generation,
                    "Claude Stop superseded provider retry"
                );
                if saved.input == next {
                    ensure!(
                        !matches!(saved.phase, JobPhase::Stopping),
                        "Claude retry is stopped"
                    );
                    return Ok(());
                }
                ensure!(
                    binding(saved).as_ref() == Some(&previous),
                    "Claude retry predecessor changed"
                );
                ensure!(
                    matches!(
                        saved.phase,
                        JobPhase::Finished {
                            outcome: JobOutcome::Failed { .. }
                        }
                    ),
                    "Claude retry requires a positively finished failed execution"
                );
                ensure!(
                    saved
                        .candidate
                        .as_ref()
                        .is_some_and(Candidate::transient_failure),
                    "Claude retry has no typed transient terminal failure"
                );
                saved.input = next;
                saved.recovery_input = None;
                saved.turn_id = None;
                saved.owner = None;
                saved.input_consumed = false;
                saved.input_recorded = false;
                saved.ordinary_result_seen = false;
                saved.nonambient_tasks.clear();
                saved.candidate = None;
                saved.phase = JobPhase::Prepared;
                Ok(())
            })
            .await
    }

    pub(crate) async fn recover_job(
        self: &Arc<Self>,
        job_id: &JobId,
        conversation: &ConversationIdentity,
        spec: &JobSpec,
        recovery_input_id: &str,
        coordination_socket: &Path,
        evidence_path: &Path,
    ) -> Result<super::ResumeDelivery> {
        self.validate_job_conversation(conversation)?;
        match self
            .inspect_job(job_id, conversation, evidence_path)
            .await?
        {
            ClaudeJobInspection::Recoverable { .. } => {}
            ClaudeJobInspection::PreparedRecovery {
                recovery_input_id: saved,
            } if saved == recovery_input_id => {}
            _ => anyhow::bail!("Claude job has no exact recoverable execution evidence"),
        }
        let ExecutionSettings::Claude {
            model,
            effort,
            fast,
        } = &spec.settings
        else {
            anyhow::bail!("Claude job has settings for another provider");
        };
        let handle = JobHandle {
            job_id: job_id.clone(),
            evidence_path: evidence_path.to_owned(),
        };
        let socket = coordination_socket.to_owned();
        let expected_recovery = recovery_input_id.to_owned();
        let evidence = self
            .conversation_index
            .update_job(&conversation.thread_id, &handle, move |saved| {
                ensure!(
                    !matches!(saved.phase, JobPhase::Stopping | JobPhase::Finished { .. }),
                    "Claude job cannot recover after Stop or finalization"
                );
                let prepared_recovery = matches!(saved.phase,JobPhase::Prepared) && saved.owner.is_none()
                    && saved.recovery_input.as_ref().is_some_and(|recovery| recovery.input.id == expected_recovery);
                ensure!(prepared_recovery || ((saved.input_consumed || saved.input_recorded) && saved.owner.is_some()), "Claude job has no positive input evidence; uncertain original input cannot be resumed");
                saved.coordination_socket = socket;
                Ok(saved.clone())
            })
            .await?;
        let item = crate::providers::claude::restart::Item {
            recovery_id: recovery_input_id.to_owned(),
            thread_id: conversation.thread_id.clone(),
            session_uuid: session_uuid_from_thread_id(&conversation.thread_id)
                .context("Claude session is missing")?
                .to_owned(),
            cwd: spec.cwd.to_string_lossy().into_owned(),
            model: model.clone(),
            effort: effort.clone(),
            fast: *fast,
            cause: crate::providers::claude::restart::Cause::Restart,
            interrupted_turn_id: evidence.turn_id,
            agent_initiated: false,
            background_tasks: Vec::new(),
            scheduled_wakes: Vec::new(),
            queued_inputs: Vec::new(),
            earlier_events: Vec::new(),
            stop_generation: Some(evidence.stop_generation),
            captured_at_unix_ms: evidence
                .recovery_input
                .as_ref()
                .filter(|recovery| recovery.input.id == recovery_input_id)
                .map_or_else(
                    || crate::time::unix_millis() as u64,
                    |recovery| recovery.captured_at_unix_ms,
                ),
            status: crate::providers::claude::restart::ItemStatus::Captured,
            attempts: 0,
            resumed_turn_id: None,
            error: None,
        };
        self.resume_with_notice(&item)
            .await
            .map_err(|error| anyhow::anyhow!(error.message))
    }

    pub(crate) async fn acknowledge_job_terminal(
        &self,
        job_id: &JobId,
        conversation: &ConversationIdentity,
        evidence_path: &Path,
    ) -> Result<()> {
        self.validate_job_conversation(conversation)?;
        let handle = JobHandle {
            job_id: job_id.clone(),
            evidence_path: evidence_path.to_owned(),
        };
        if self
            .conversation_index
            .job(&conversation.thread_id, &handle)
            .await?
            .is_none()
        {
            return Ok(());
        }
        self.conversation_index
            .update_job(&conversation.thread_id, &handle, |saved| {
                ensure!(
                    matches!(saved.phase, JobPhase::Finished { .. }),
                    "Claude job has no final result to acknowledge"
                );
                saved.candidate = None;
                saved.nonambient_tasks.clear();
                Ok(())
            })
            .await
    }

    pub(crate) async fn stop_job(
        &self,
        job_id: &JobId,
        conversation: &ConversationIdentity,
        evidence_path: &Path,
    ) -> Result<()> {
        self.validate_job_conversation(conversation)?;
        let handle = JobHandle {
            job_id: job_id.clone(),
            evidence_path: evidence_path.to_owned(),
        };
        let Some(evidence) = self
            .conversation_index
            .job(&conversation.thread_id, &handle)
            .await?
        else {
            return Ok(());
        };
        if matches!(evidence.phase, JobPhase::Finished { .. }) {
            return Ok(());
        }
        let stopping = self
            .conversation_index
            .update_job(&conversation.thread_id, &handle, |saved| {
                if matches!(saved.phase, JobPhase::Finished { .. }) {
                    return Ok(None);
                }
                saved.phase = JobPhase::Stopping;
                Ok(Some(saved.clone()))
            })
            .await?;
        let Some(evidence) = stopping else {
            return Ok(());
        };
        self.stop_parent(&conversation.thread_id).await?;
        if let Some(owner) = evidence.owner.clone() {
            let exact = owner.clone();
            if tokio::task::spawn_blocking(move || exact.alive()).await?? {
                self.fail_runtime(&conversation.thread_id, owner.pid, "interrupted", None)
                    .await;
                if owner.alive()? {
                    self.terminate_group(nix::unistd::Pid::from_raw(owner.pid))
                        .await;
                }
            }
            ensure!(
                !owner.alive()? && !super::group_exists(nix::unistd::Pid::from_raw(owner.pid)),
                "Claude's exact execution or its process group has not stopped; Stop stays pending"
            );
        }
        let effects = if evidence.owner.is_some() || evidence.recovery_input.is_some() {
            EffectEvidence::MayHaveRun
        } else {
            EffectEvidence::NotStarted
        };
        self.conversation_index
            .update_job(&conversation.thread_id, &handle, move |saved| {
                ensure!(
                    matches!(saved.phase, JobPhase::Stopping),
                    "Claude job Stop lost its execution fence"
                );
                saved.phase = JobPhase::Finished {
                    outcome: JobOutcome::Stopped { effects },
                };
                Ok(())
            })
            .await?;
        self.job_changes.send_replace(());
        Ok(())
    }

    pub(crate) async fn owned_process_session(
        &self,
        pid: i32,
        started_micros: u64,
    ) -> Option<(String, Option<String>)> {
        self.runtimes
            .lock()
            .await
            .iter()
            .find_map(|(thread, runtime)| {
                (runtime.process_group_id == pid
                    && runtime.process_started_micros == Some(started_micros))
                .then(|| {
                    (
                        thread.clone(),
                        runtime
                            .active_turn
                            .as_ref()
                            .map(|turn| turn.translator.turn_id().to_owned()),
                    )
                })
            })
    }

    pub(super) async fn conversation_launch_policy(
        &self,
        thread: &str,
    ) -> Result<LaunchPolicy, TurnStartError> {
        if let Some(runtime) = self.runtimes.lock().await.get(thread) {
            return Ok(runtime.launch.clone());
        }
        let parent = self
            .conversation_index
            .parent(thread)
            .await
            .map_err(|error| {
                TurnStartError::internal(format!("Claude permissions could not be read: {error:#}"))
            })?;
        if let Some(handle) = parent.active_job {
            let saved = self
                .conversation_index
                .job(thread, &handle)
                .await
                .map_err(|error| {
                    TurnStartError::internal(format!(
                        "Claude job ownership could not be read: {error:#}"
                    ))
                })?
                .ok_or_else(|| {
                    TurnStartError::internal("Claude's active job evidence is missing")
                })?;
            if !matches!(saved.phase, JobPhase::Finished { .. }) {
                return Ok(LaunchPolicy::Job {
                    handle,
                    scope: saved.tool_scope,
                    coordination_socket: saved.coordination_socket,
                });
            }
        }
        let scope = parent.tool_scope.unwrap_or(ToolScope::Full);
        Ok(LaunchPolicy::Conversation { scope })
    }

    pub(super) async fn prepare_job_resume(
        &self,
        request: &ClaudeTurnRequest,
        policy: &LaunchPolicy,
    ) -> Result<(), TurnStartError> {
        let Some(handle) = policy.job() else {
            return Ok(());
        };
        let saved = self
            .conversation_index
            .job(&request.thread_id, handle)
            .await
            .map_err(|error| {
                TurnStartError::internal(format!(
                    "Claude job ownership could not be read: {error:#}"
                ))
            })?
            .ok_or_else(|| TurnStartError::internal("Claude job evidence is missing"))?;
        let input =
            JobInput {
                id: request.input.client_id.clone().ok_or_else(|| {
                    TurnStartError::internal("Claude job input identity is missing")
                })?,
                fingerprint: crate::ids::sha256_hex(request.input.text.as_bytes()),
            };
        if matches!(saved.phase, JobPhase::Prepared) && saved.owner.is_none() {
            if saved.current_input() == &input
                && saved.recovery_input.is_some() == request.input.notice.is_some()
                && !saved.input_consumed
                && !saved.input_recorded
            {
                return Ok(());
            }
            return Err(TurnStartError::delivery_uncertain(
                "Claude prepared input identity conflicts; the original prompt or another recovery payload will not be replayed",
            ));
        }
        let live = self
            .runtimes
            .lock()
            .await
            .get(&request.thread_id)
            .is_some_and(|runtime| runtime.launch.job() == Some(handle));
        if live {
            return Ok(());
        }
        if matches!(saved.phase, JobPhase::Stopping | JobPhase::Finished { .. }) {
            return Err(TurnStartError::internal(
                "Claude job is stopped or finished and cannot resume",
            ));
        }
        let saved = self
            .reconcile_job_input(&request.thread_id, handle, saved)
            .await
            .map_err(|error| {
                TurnStartError::delivery_uncertain(format!(
                    "Claude input evidence could not be reconciled before recovery: {error:#}"
                ))
            })?;
        if !saved.input_consumed && !saved.input_recorded {
            return Err(TurnStartError::delivery_uncertain(
                "Claude original input has no positive canonical evidence; recovery cannot replay uncertain work",
            ));
        }
        if let Some(owner) = saved.owner.clone() {
            let group = owner.pid;
            let alive = tokio::task::spawn_blocking(move || owner.alive())
                .await
                .map_err(|error| TurnStartError::internal(error.to_string()))?
                .map_err(|error| {
                    TurnStartError::internal(format!(
                        "Claude process ownership is unknown: {error:#}"
                    ))
                })?;
            if alive {
                return Err(TurnStartError::unresponsive(
                    "Claude's exact job process still lives; refusing a second execution",
                ));
            }
            if super::group_exists(nix::unistd::Pid::from_raw(group)) {
                return Err(TurnStartError::unresponsive(
                    "Claude's execution process group still exists; refusing a second execution",
                ));
            }
        }
        let notice = request.input.notice.as_ref().ok_or_else(|| TurnStartError::delivery_uncertain("Claude job needs exact recovery with a history/state inspection notice; its original input will not be replayed"))?;
        let recovery = RecoveryInput {
            input,
            captured_at_unix_ms: notice.captured_at_unix_ms,
        };
        let previous = saved.current_input().clone();
        self.conversation_index
            .update_job(&request.thread_id, handle, move |saved| {
                ensure!(
                    !matches!(saved.phase, JobPhase::Stopping | JobPhase::Finished { .. }),
                    "Claude job was stopped before recovery"
                );
                ensure!(
                    saved.current_input() == &previous
                        && (saved.input_consumed || saved.input_recorded),
                    "Claude job input evidence changed before recovery preparation"
                );
                saved.owner = None;
                saved.phase = JobPhase::Prepared;
                saved.recovery_input = Some(recovery);
                saved.input_consumed = false;
                saved.input_recorded = false;
                saved.ordinary_result_seen = false;
                saved.nonambient_tasks.clear();
                Ok(())
            })
            .await
            .map_err(|error| {
                TurnStartError::internal(format!(
                    "Claude job recovery could not be prepared: {error:#}"
                ))
            })
    }

    pub(super) async fn record_job_turn(
        &self,
        thread: &str,
        launch: &LaunchPolicy,
        turn: &str,
    ) -> Result<(), TurnStartError> {
        let Some(handle) = launch.job() else {
            return Ok(());
        };
        let turn = turn.to_owned();
        self.conversation_index
            .update_job(thread, handle, move |saved| {
                ensure!(
                    !matches!(saved.phase, JobPhase::Stopping | JobPhase::Finished { .. }),
                    "Claude job is stopped or already has a final result"
                );
                saved.turn_id = Some(turn);
                Ok(())
            })
            .await
            .map_err(|error| {
                TurnStartError::internal(format!(
                    "Claude job turn binding could not be saved: {error:#}"
                ))
            })
    }

    async fn reconcile_job_input(
        &self,
        thread: &str,
        handle: &JobHandle,
        evidence: JobEvidence,
    ) -> Result<JobEvidence> {
        if evidence.input_consumed
            || evidence.input_recorded
            || matches!(evidence.phase, JobPhase::Finished { .. })
        {
            return Ok(evidence);
        }
        let session =
            session_uuid_from_thread_id(thread).context("Claude session identity is missing")?;
        let parent = self.conversation_index.parent(thread).await?;
        let Some(selection) = parent.selection else {
            return Ok(evidence);
        };
        let Some(path) = self.session_history(&selection.cwd, session) else {
            return Ok(evidence);
        };
        let expected = evidence.current_input().clone();
        let input = expected.id.clone();
        let synthetic = evidence.recovery_input.is_some();
        let actual = tokio::task::spawn_blocking(move || {
            if synthetic {
                crate::providers::claude::delivery_evidence::recorded_fingerprint(&path, &input)
            } else {
                crate::providers::claude::delivery_evidence::recorded_plain_fingerprint(
                    &path, &input,
                )
            }
        })
        .await??;
        let Some(Some(actual)) = actual else {
            return Ok(evidence);
        };
        ensure!(
            actual == expected.fingerprint,
            "Claude job input UUID is recorded with different payload content"
        );
        self.conversation_index
            .update_job(thread, handle, move |saved| {
                if saved.current_input() == &expected
                    && !matches!(saved.phase, JobPhase::Finished { .. })
                {
                    saved.input_recorded = true;
                }
                Ok(saved.clone())
            })
            .await
    }

    pub(super) async fn record_job_process(
        &self,
        runtime: &super::ClaudeRuntime,
    ) -> Result<(), TurnStartError> {
        let Some(handle) = runtime.launch.job() else {
            return Ok(());
        };
        let owner = ProcessOwner {
            pid: runtime.process_group_id,
            started_micros: runtime.process_started_micros.ok_or_else(|| {
                TurnStartError::internal("Claude job has no exact kernel process identity")
            })?,
            session_uuid: runtime.session_uuid.clone(),
        };
        self.conversation_index
            .update_job(
                &crate::providers::claude::claude_thread_id(&runtime.session_uuid),
                handle,
                move |saved| {
                    ensure!(
                        saved.owner.is_none()
                            && matches!(saved.phase, JobPhase::Prepared | JobPhase::Interrupted),
                        "Claude job already has an execution owner or has been stopped"
                    );
                    saved.owner = Some(owner);
                    saved.phase = JobPhase::Executing;
                    Ok(())
                },
            )
            .await
            .map_err(|error| {
                TurnStartError::internal(format!(
                    "Claude execution owner could not be saved: {error:#}"
                ))
            })
    }

    pub(super) async fn submit_job_input(
        &self,
        thread: &str,
        policy: &LaunchPolicy,
        slot: super::input_writer::InputSlot,
        prepared: Arc<super::input_writer::PreparedInput>,
    ) -> Result<super::input_writer::PendingWrite, TurnStartError> {
        match policy.job() {
            Some(handle) => self
                .conversation_index
                .admit_job_input(thread, handle, move || slot.send_input(prepared))
                .await
                .map_err(|error| {
                    TurnStartError::internal(format!(
                        "Claude job input was fenced before submission: {error:#}"
                    ))
                })?
                .map_err(TurnStartError::from),
            None => slot.send_input(prepared).map_err(TurnStartError::from),
        }
    }

    pub(super) async fn observe_job_frame(
        &self,
        thread: &str,
        group: i32,
        frame: &Value,
    ) -> Result<Vec<String>> {
        let consumed = super::consumed_input_ids(frame);
        let (evidence, handle, tasks) = {
            let mut runtimes = self.runtimes.lock().await;
            let Some(runtime) = runtimes
                .get_mut(thread)
                .filter(|runtime| runtime.process_group_id == group)
            else {
                return Ok(Vec::new());
            };
            let taken = runtime.input.unconsumed().take(&consumed);
            let evidence = consumed
                .into_iter()
                .map(str::to_owned)
                .chain(taken)
                .collect::<Vec<_>>();
            let tasks = runtime
                .background_tasks
                .iter()
                .filter_map(super::suspend::BackgroundTask::paused)
                .map(|task| task.id)
                .collect::<Vec<_>>();
            (evidence, runtime.launch.job().cloned(), tasks)
        };
        if let Some(handle) = handle
            && (!evidence.is_empty()
                || frame["type"] == "result"
                || super::is_background_tasks_change(frame))
        {
            let observed = frame.clone();
            let ids = evidence.clone();
            self.conversation_index
                .update_job(thread, &handle, move |saved| {
                    saved.observe(&observed, &ids, tasks)
                })
                .await?;
            self.job_changes.send_replace(());
        }
        Ok(evidence)
    }

    pub(super) async fn close_quiescent_job(
        self: &Arc<Self>,
        thread: &str,
        group: i32,
    ) -> Result<bool> {
        let handle = self
            .runtimes
            .lock()
            .await
            .get(thread)
            .filter(|runtime| runtime.process_group_id == group)
            .and_then(|runtime| runtime.launch.job().cloned());
        let Some(handle) = handle else {
            return Ok(false);
        };
        let evidence = self
            .conversation_index
            .job(thread, &handle)
            .await?
            .context("Claude job evidence is missing")?;
        if !matches!(evidence.phase, JobPhase::Executing) || !evidence.eligible() {
            return Ok(false);
        }
        let wakes = self.refresh_wakes(thread, group).await;
        let input = {
            let runtimes = self.runtimes.lock().await;
            let Some(runtime) = runtimes
                .get(thread)
                .filter(|runtime| runtime.process_group_id == group)
            else {
                return Ok(false);
            };
            if runtime.active_turn.is_some()
                || !runtime.input.unconsumed().pending().is_empty()
                || runtime
                    .background_tasks
                    .iter()
                    .any(|task| task.paused().is_some())
                || !matches!(wakes, super::WakeEvidence::Fresh)
                || runtime
                    .wakes
                    .held_until(tokio::time::Instant::now())
                    .is_some()
            {
                return Ok(false);
            }
            runtime.input.clone()
        };
        self.conversation_index
            .update_job(thread, &handle, |saved| {
                ensure!(
                    matches!(saved.phase, JobPhase::Executing),
                    "Claude job phase changed before closing its input"
                );
                saved.phase = JobPhase::Closing;
                Ok(())
            })
            .await?;
        input.close().await?;
        Ok(true)
    }

    pub(super) async fn finish_job_eof(&self, thread: &str, group: i32) -> Result<bool> {
        let captured = self
            .runtimes
            .lock()
            .await
            .get(thread)
            .filter(|runtime| runtime.process_group_id == group)
            .and_then(|runtime| {
                runtime
                    .launch
                    .job()
                    .cloned()
                    .map(|handle| (handle, runtime.reaped.clone()))
            });
        let Some((handle, mut reaped)) = captured else {
            return Ok(false);
        };
        loop {
            if !matches!(*reaped.borrow(), ReapState::Running) {
                break;
            }
            reaped
                .changed()
                .await
                .context("Claude process reap owner ended without a result")?;
        }
        let exit = reaped.borrow().clone();
        ensure!(
            !super::group_exists(nix::unistd::Pid::from_raw(group)),
            "Claude's process group still contains execution after its leader was reaped"
        );
        let evidence = self
            .conversation_index
            .job(thread, &handle)
            .await?
            .context("Claude job evidence is missing")?;
        if !matches!(evidence.phase, JobPhase::Closing) || !evidence.eligible() {
            return Ok(false);
        }
        if self
            .runtimes
            .lock()
            .await
            .get(thread)
            .is_none_or(|runtime| {
                runtime.process_group_id != group || runtime.active_turn.is_some()
            })
        {
            return Ok(false);
        }
        let current_generation = self.stop_generation(thread).await?;
        ensure!(
            current_generation == evidence.stop_generation,
            "Claude Stop superseded job finalization"
        );
        let outcome = match exit {
            ReapState::Exited(status) if status.success() => match evidence.candidate.as_ref() {
                Some(candidate) if candidate.failed => JobOutcome::Failed {
                    reason: candidate
                        .failure
                        .clone()
                        .unwrap_or_else(|| "Claude returned an error result".into()),
                },
                _ => JobOutcome::Completed,
            },
            ReapState::Exited(status) => JobOutcome::Failed {
                reason: format!("Claude process exited with {status}"),
            },
            ReapState::Failed(reason) => {
                anyhow::bail!("Claude process could not be reaped: {reason}")
            }
            ReapState::Running => anyhow::bail!("Claude process still runs after EOF"),
        };
        self.conversation_index
            .update_job(thread, &handle, move |saved| {
                ensure!(
                    matches!(saved.phase, JobPhase::Closing),
                    "Claude job phase changed before finalization"
                );
                saved.phase = JobPhase::Finished { outcome };
                Ok(())
            })
            .await?;
        self.runtimes.lock().await.remove(thread);
        self.job_changes.send_replace(());
        Ok(true)
    }
}

fn binding(evidence: &JobEvidence) -> Option<ExecutionBinding> {
    Some(ExecutionBinding {
        conversation: evidence.conversation.clone(),
        input_id: evidence.current_input().id.clone(),
        turn_id: evidence.turn_id.clone()?,
    })
}

#[cfg(all(test, target_os = "macos"))]
mod tests;
