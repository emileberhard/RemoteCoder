use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result, bail};

use super::model::*;
use super::owner::{JobOwner, now_ms};
use super::result::{bounded_result, git_snapshot};
use super::store::fingerprint;
use crate::gateway::Gateway;
use crate::providers::claude::ClaudeJobInspection;

impl JobOwner {
    pub(crate) fn coordination_socket(&self) -> Result<PathBuf> {
        Ok(super::routes::scoped_socket(self.root.as_deref().context(
            "delegated jobs require persistent gateway state",
        )?))
    }

    pub(super) async fn reconcile_job(&self, id: JobId) -> Result<bool> {
        let gateway = self.gateway()?;
        let store = self.store().await?;
        let current = store.retarget_delivery(id.clone()).await?;
        let notices_pending = if matches!(&current.recipient, Recipient::Remote {host,..} if gateway.remote_receiver_active(host).await?)
        {
            false
        } else {
            self.deliver_notices(&id).await?
        };
        for _ in 0..8 {
            let job = store.read(id.clone()).await?;
            if let ExecutionState::Terminal { terminal } = &job.execution {
                if terminal.cleanup == CleanupState::Pending {
                    let agent = store.agent(job.agent_id.clone()).await?;
                    let ConversationBinding::Known { conversation } = agent.conversation else {
                        bail!("terminal provider cleanup has no exact conversation");
                    };
                    gateway
                        .job_claude()?
                        .acknowledge_job_terminal(
                            &id,
                            &conversation,
                            &self.evidence_file(&id).await?,
                        )
                        .await?;
                    store
                        .complete_cleanup(id.clone(), job.revision, now_ms())
                        .await?;
                    continue;
                }
                let current = store.retarget_delivery(job.job_id.clone()).await?;
                if let Recipient::Remote { host, .. } = &current.recipient
                    && gateway.remote_receiver_active(host).await?
                {
                    return Ok(false);
                }
                let ExecutionState::Terminal { terminal } = &current.execution else {
                    unreachable!()
                };
                return Ok(self.deliver_completion(&current, terminal).await? || notices_pending);
            }
            if matches!(job.stop, StopState::Requested { .. }) {
                self.stop_execution(&gateway, &job).await?;
                let effects = if matches!(
                    job.execution,
                    ExecutionState::Admitted | ExecutionState::Bound { .. }
                ) {
                    EffectEvidence::NotStarted
                } else {
                    EffectEvidence::MayHaveRun
                };
                self.finalize(
                    &job,
                    JobOutcome::Stopped { effects },
                    ResultEvidence::Unavailable {
                        reason: "work was explicitly stopped; partial effects may remain".into(),
                    },
                )
                .await?;
                continue;
            }
            if job.source == JobSource::Imported || gateway.is_draining() {
                return Ok(false);
            }
            let SpecEvidence::Known { spec } = &job.spec else {
                bail!("unfinished runtime job has no execution specification");
            };
            let retry_spec = (!job.provider_retries.is_empty()).then(|| continuation_spec(spec));
            let spec = retry_spec.as_ref().unwrap_or(spec);
            match &job.execution {
                ExecutionState::Admitted => {
                    let agent = store.agent(job.agent_id.clone()).await?;
                    let conversation = match agent.conversation {
                        ConversationBinding::Known { conversation } => conversation,
                        ConversationBinding::Unknown { .. } => match spec.settings.provider() {
                            Provider::Codex => super::codex::create(&gateway, spec).await?,
                            Provider::Claude => gateway.job_new_claude_conversation(),
                        },
                    };
                    store
                        .bind(id.clone(), job.revision, conversation, now_ms())
                        .await?;
                }
                ExecutionState::RetryWaiting {
                    binding,
                    retry_at_ms,
                } => {
                    if now_ms() < *retry_at_ms {
                        return Ok(true);
                    }
                    store
                        .advance(
                            id.clone(),
                            job.revision,
                            ExecutionState::Dispatching {
                                conversation: binding.conversation.clone(),
                                input_id: job.current_input_id(),
                            },
                            now_ms(),
                        )
                        .await?;
                }
                ExecutionState::Bound { conversation } => {
                    if conversation.provider == Provider::Claude && job.previous_job_id.is_none() {
                        gateway
                            .job_claude()?
                            .record_job_session(&conversation.thread_id, &job.job_id)
                            .await?;
                    }
                    self.ensure_endpoint().await?;
                    store
                        .advance(
                            id.clone(),
                            job.revision,
                            ExecutionState::Dispatching {
                                conversation: conversation.clone(),
                                input_id: job.current_input_id(),
                            },
                            now_ms(),
                        )
                        .await?;
                    let current = store.read(id.clone()).await?;
                    if matches!(current.stop, StopState::Requested { .. }) {
                        continue;
                    }
                    let binding = match conversation.provider {
                        Provider::Codex => super::codex::start(&gateway, &current).await,
                        Provider::Claude => {
                            gateway
                                .job_claude()?
                                .start_job(
                                    &id,
                                    conversation,
                                    spec,
                                    &input_id(&current)?,
                                    &self.coordination_socket()?,
                                    &self.evidence_file(&id).await?,
                                )
                                .await
                        }
                    };
                    match binding {
                        Ok(binding) => {
                            store
                                .advance(
                                    id.clone(),
                                    current.revision,
                                    ExecutionState::Running { binding },
                                    now_ms(),
                                )
                                .await?;
                        }
                        Err(error) => {
                            self.record_unknown(
                                &current,
                                format!("dispatch acknowledgement is unresolved: {error:#}"),
                            )
                            .await?;
                            return Ok(true);
                        }
                    }
                }
                _ => {
                    self.ensure_endpoint().await?;
                    let evidence = self.inspect(&gateway, &job).await?;
                    match evidence {
                        Inspection::PreparedRecovery { recovery_input_id } => {
                            let identity = job
                                .execution
                                .conversation()
                                .context("prepared recovery has no conversation")?;
                            anyhow::ensure!(
                                identity.provider == Provider::Claude,
                                "prepared recovery belongs to another provider"
                            );
                            gateway
                                .job_claude()?
                                .recover_job(
                                    &id,
                                    identity,
                                    spec,
                                    &recovery_input_id,
                                    &self.coordination_socket()?,
                                    &self.evidence_file(&id).await?,
                                )
                                .await?;
                        }
                        Inspection::RetryableInput {
                            conversation: target,
                            input_id: retained,
                        } => {
                            anyhow::ensure!(
                                job.execution.conversation() == Some(&target)
                                    && retained == input_id(&job)?
                                    && target.provider == Provider::Codex,
                                "retryable input proof does not match the retained job"
                            );
                            let binding = super::codex::start(&gateway, &job).await?;
                            store
                                .advance(
                                    id.clone(),
                                    job.revision,
                                    ExecutionState::Running { binding },
                                    now_ms(),
                                )
                                .await?;
                        }
                        Inspection::Prepared => {
                            let Some(conversation) = job.execution.conversation() else {
                                return Ok(false);
                            };
                            let binding = match conversation.provider {
                                Provider::Codex => super::codex::start(&gateway, &job).await?,
                                Provider::Claude => {
                                    gateway
                                        .job_claude()?
                                        .start_job(
                                            &id,
                                            conversation,
                                            spec,
                                            &input_id(&job)?,
                                            &self.coordination_socket()?,
                                            &self.evidence_file(&id).await?,
                                        )
                                        .await?
                                }
                            };
                            store
                                .advance(
                                    id.clone(),
                                    job.revision,
                                    ExecutionState::Running { binding },
                                    now_ms(),
                                )
                                .await?;
                        }
                        Inspection::Running { binding } => {
                            if matches!(&job.execution, ExecutionState::Running { binding: current } if current == &binding)
                            {
                                return Ok(notices_pending);
                            }
                            store
                                .advance(
                                    id.clone(),
                                    job.revision,
                                    ExecutionState::Running { binding },
                                    now_ms(),
                                )
                                .await?;
                            return Ok(notices_pending);
                        }
                        Inspection::Recoverable { binding } => {
                            if !gateway
                                .job_provider_recovery_complete(binding.conversation.provider)
                                .await?
                            {
                                return Ok(true);
                            }
                            let recovery_input_id = (binding.conversation.provider
                                == Provider::Claude)
                                .then(crate::ids::new_session_uuid);
                            let recovering = store
                                .advance(
                                    id.clone(),
                                    job.revision,
                                    ExecutionState::Recovering {
                                        binding: binding.clone(),
                                        recovery_input_id: recovery_input_id.clone(),
                                    },
                                    now_ms(),
                                )
                                .await?;
                            match binding.conversation.provider {
                                Provider::Codex => {
                                    super::codex::recover(&gateway, &recovering).await?;
                                }
                                Provider::Claude => {
                                    gateway
                                        .job_claude()?
                                        .recover_job(
                                            &id,
                                            &binding.conversation,
                                            spec,
                                            recovery_input_id.as_deref().context(
                                                "Claude recovery input identity is missing",
                                            )?,
                                            &self.coordination_socket()?,
                                            &self.evidence_file(&id).await?,
                                        )
                                        .await?;
                                }
                            }
                        }
                        Inspection::Pending { reason } => {
                            self.record_pending(&job, reason).await?;
                            return Ok(true);
                        }
                        Inspection::Unknown { reason } => {
                            self.record_unknown(&job, reason).await?;
                            return Ok(false);
                        }
                        Inspection::TransientFailure { binding, reason } => {
                            use rand_core::RngCore;
                            let at = now_ms();
                            let retry_at = super::retry::retry_at_ms(
                                at,
                                job.provider_retries.len(),
                                rand_core::OsRng.next_u64(),
                            );
                            store
                                .schedule_provider_retry(
                                    id.clone(),
                                    job.revision,
                                    binding,
                                    reason,
                                    retry_at,
                                    at,
                                )
                                .await?;
                            return Ok(true);
                        }
                        Inspection::Finished { outcome, result } => {
                            self.finalize(&job, outcome, result).await?;
                        }
                    }
                }
            }
        }
        Ok(true)
    }

    async fn evidence_file(&self, id: &JobId) -> Result<PathBuf> {
        Ok(self
            .store()
            .await?
            .evidence_root(id.clone())
            .await?
            .join("provider.json"))
    }

    async fn inspect(&self, gateway: &Arc<Gateway>, job: &JobRecord) -> Result<Inspection> {
        let identity = job
            .execution
            .conversation()
            .context("job has no exact provider conversation")?;
        match identity.provider {
            Provider::Codex => super::codex::inspect(gateway, job).await,
            Provider::Claude => {
                if matches!(job.execution, ExecutionState::Dispatching { .. })
                    && let Some(previous) = job.provider_retries.last()
                {
                    let SpecEvidence::Known { spec } = &job.spec else {
                        bail!("Claude provider retry has no specification");
                    };
                    gateway
                        .job_claude()?
                        .prepare_job_retry(
                            &job.job_id,
                            &previous.binding,
                            &continuation_spec(spec),
                            &job.current_input_id(),
                            &self.evidence_file(&job.job_id).await?,
                        )
                        .await?;
                }
                Ok(
                    match gateway
                        .job_claude()?
                        .inspect_job(
                            &job.job_id,
                            identity,
                            &self.evidence_file(&job.job_id).await?,
                        )
                        .await?
                    {
                        ClaudeJobInspection::Prepared => Inspection::Prepared,
                        ClaudeJobInspection::PreparedRecovery { recovery_input_id } => {
                            Inspection::PreparedRecovery { recovery_input_id }
                        }
                        ClaudeJobInspection::Running { binding } => Inspection::Running { binding },
                        ClaudeJobInspection::Recoverable { binding } => {
                            Inspection::Recoverable { binding }
                        }
                        ClaudeJobInspection::Unknown { reason } => Inspection::Unknown { reason },
                        ClaudeJobInspection::Finished {
                            binding,
                            outcome,
                            candidate,
                        } => {
                            let transient = matches!(outcome, JobOutcome::Failed { .. })
                                && candidate
                                    .as_ref()
                                    .is_some_and(|candidate| candidate.transient_failure());
                            if transient
                                && job.provider_retries.len() < super::retry::MAX_PROVIDER_RETRIES
                            {
                                Inspection::TransientFailure {
                                    binding: binding.context(
                                        "Claude terminal retry has no exact execution binding",
                                    )?,
                                    reason: candidate
                                        .as_ref()
                                        .and_then(|candidate| candidate.failure.clone())
                                        .context(
                                            "Claude transient failure has no terminal reason",
                                        )?,
                                }
                            } else {
                                Inspection::Finished {
                                    outcome: match outcome {
                                        JobOutcome::Failed { reason } if transient => {
                                            JobOutcome::Failed {
                                                reason: format!(
                                                    "provider retry budget exhausted after {} retries: {reason}",
                                                    job.provider_retries.len()
                                                ),
                                            }
                                        }
                                        other => other,
                                    },
                                    result: match candidate.and_then(|candidate| {
                                        candidate.text.map(|text| (text, candidate.truncated))
                                    }) {
                                        Some((text, truncated)) => ResultEvidence::Available {
                                            result: bounded_result(text, truncated)?,
                                        },
                                        None => ResultEvidence::Unavailable {
                                            reason: "provider ended without a final text result"
                                                .into(),
                                        },
                                    },
                                }
                            }
                        }
                    },
                )
            }
        }
    }

    async fn stop_execution(&self, gateway: &Arc<Gateway>, job: &JobRecord) -> Result<()> {
        if job.source == JobSource::Imported {
            return Ok(());
        }
        if matches!(
            job.execution,
            ExecutionState::Admitted
                | ExecutionState::Bound { .. }
                | ExecutionState::RetryWaiting { .. }
        ) {
            return Ok(());
        }
        let Some(identity) = job.execution.conversation() else {
            if job.source == JobSource::Imported {
                return Ok(());
            }
            bail!("running job's exact provider identity is unresolved; Stop remains recorded");
        };
        match identity.provider {
            Provider::Codex => super::codex::stop(gateway, job).await,
            Provider::Claude => {
                gateway
                    .job_claude()?
                    .stop_job(
                        &job.job_id,
                        identity,
                        &self.evidence_file(&job.job_id).await?,
                    )
                    .await
            }
        }
    }

    pub(crate) async fn apply_pending_stops(&self, provider: Provider) -> Result<()> {
        if self.root.is_none() {
            return Ok(());
        }
        let _operations = self.operations.write().await;
        let store = self.store().await?;
        let gateway = self.gateway()?;
        for id in store.pending_ids().await? {
            let job = store.read(id).await?;
            if matches!(job.stop, StopState::Requested { .. })
                && job
                    .execution
                    .conversation()
                    .is_some_and(|identity| identity.provider == provider)
            {
                self.stop_execution(&gateway, &job).await?;
            }
        }
        Ok(())
    }

    async fn record_pending(&self, job: &JobRecord, reason: String) -> Result<()> {
        if matches!(&job.execution, ExecutionState::Unknown { reason: current, .. } if current == &reason)
        {
            return Ok(());
        }
        self.store()
            .await?
            .record_uncertainty(job.job_id.clone(), job.revision, reason, None, now_ms())
            .await?;
        self.dirty();
        Ok(())
    }

    async fn record_unknown(&self, job: &JobRecord, reason: String) -> Result<()> {
        if matches!(&job.execution, ExecutionState::Unknown { reason: current, .. } if current == &reason)
        {
            return Ok(());
        }
        let notice = if matches!(
            job.recipient,
            Recipient::Conversation { .. } | Recipient::Remote { .. }
        ) {
            let host = self.gateway()?.job_host_name()?;
            Some(crate::agents::envelope::message(
                &format!("{}:notice:observation", job.job_id.as_str()),
                &crate::agents::envelope::Sender {
                    agent_id: job.job_id.as_str(),
                    provider: provider(job)?.as_str(),
                    host: &host,
                    reply_tool: "message_agent",
                    reply_target: job.job_id.as_str(),
                },
                &format!(
                    "The outcome of delegated job {} is not yet known. This is an interim notice, not a final result. The runtime retains its identity and evidence and will report completion only when it is known. Inspect it with list_agents {} --json or explicitly stop it. Reason: {reason}",
                    job.job_id.as_str(),
                    job.job_id.as_str()
                ),
            )?)
        } else {
            None
        };
        self.store()
            .await?
            .record_uncertainty(job.job_id.clone(), job.revision, reason, notice, now_ms())
            .await?;
        self.dirty();
        Ok(())
    }

    async fn finalize(
        &self,
        job: &JobRecord,
        outcome: JobOutcome,
        result: ResultEvidence,
    ) -> Result<()> {
        let result = match result {
            ResultEvidence::Available { result } => ResultEvidence::Available {
                result: bounded_result(result.text, result.truncated)?,
            },
            other => other,
        };
        let git = match &job.spec {
            SpecEvidence::Known { spec } => git_snapshot(&spec.cwd).await,
            _ => GitSnapshot::Unknown {
                reason: "job working directory is unresolved".into(),
            },
        };
        let completion = match &job.recipient {
            Recipient::None => Completion::NotRequired,
            _ => {
                let gateway = self.gateway()?;
                let text = crate::agents::envelope::completion(
                    &job.job_id,
                    provider(job)?,
                    &gateway.host_identity().await?.host_id,
                    &outcome,
                    &result,
                    &git,
                )?;
                Completion::Required {
                    payload: CompletionPayload::Prepared {
                        delivery_id: format!("{}:completion", job.job_id.as_str()),
                        fingerprint: fingerprint(text.as_bytes()),
                        text,
                    },
                    delivery: DeliveryState::Pending,
                }
            }
        };
        let execution = job.execution.binding().cloned();
        let cleanup = if job.source == JobSource::Runtime
            && job
                .execution
                .conversation()
                .is_some_and(|identity| identity.provider == Provider::Claude)
            && !matches!(
                job.execution,
                ExecutionState::Admitted | ExecutionState::Bound { .. }
            ) {
            CleanupState::Pending
        } else {
            CleanupState::Complete
        };
        let terminal = Terminal {
            at_ms: Some(now_ms()),
            execution,
            git,
            outcome,
            result,
            completion,
            cleanup,
        };
        self.store()
            .await?
            .advance(
                job.job_id.clone(),
                job.revision,
                ExecutionState::Terminal { terminal },
                now_ms(),
            )
            .await?;
        Ok(())
    }
}

fn input_id(job: &JobRecord) -> Result<String> {
    match &job.execution {
        ExecutionState::Dispatching { input_id, .. } => Ok(input_id.clone()),
        ExecutionState::Running { binding } | ExecutionState::Recovering { binding, .. } => {
            Ok(binding.input_id.clone())
        }
        ExecutionState::Unknown { .. } => Ok(job.current_input_id()),
        _ => bail!("job has no dispatched input identity"),
    }
}

fn provider(job: &JobRecord) -> Result<Provider> {
    match &job.spec {
        SpecEvidence::Known { spec } => Ok(spec.settings.provider()),
        SpecEvidence::Expired { settings, .. } => Ok(settings.provider()),
        SpecEvidence::Unknown { .. } => job
            .execution
            .conversation()
            .map(|identity| identity.provider)
            .context("job provider is unresolved"),
    }
}

fn continuation_spec(spec: &JobSpec) -> JobSpec {
    JobSpec {
        prompt: super::retry::CONTINUATION_PROMPT.to_owned(),
        cwd: spec.cwd.clone(),
        settings: spec.settings.clone(),
        tool_scope: spec.tool_scope.clone(),
        title: spec.title.clone(),
    }
}
