use anyhow::{Context, Result, ensure};

use super::model::*;
use super::owner::{JobOwner, now_ms};

const OBSERVATION_ONLY: &str =
    "This job only observes; it will not submit, retry or recover native execution.";

impl JobOwner {
    pub(crate) async fn observe_native(
        &self,
        agent: AgentRecord,
        job_id: JobId,
        execution: ExecutionState,
        request_fingerprint: Option<String>,
    ) -> Result<JobRecord> {
        let at = now_ms();
        let job = JobRecord {
            job_id,
            agent_id: agent.agent_id,
            request_fingerprint,
            created_at_ms: Some(at),
            updated_at_ms: at,
            revision: 0,
            previous_job_id: agent.latest_job_id,
            provider_retries: Vec::new(),
            source: JobSource::Runtime,
            admitted_membership: None,
            remote_fingerprint: None,
            parent_revision: agent.parent_revision,
            initial_parent: agent.parent,
            admission_origin: None,
            unconfirmed_result: None,
            attention: None,
            notices: Vec::new(),
            spec: SpecEvidence::Unknown {
                reason: "native turn policy is owned by its native client".into(),
            },
            recipient: agent
                .parent_recipient
                .context("adopted agent has no recipient")?,
            execution,
            stop: StopState::NotRequested,
        };
        let job = self.store().await?.admit_native(job).await?;
        self.dirty();
        Ok(job)
    }

    pub(super) async fn reconcile_native(&self, job: &JobRecord) -> Result<()> {
        let gateway = self.gateway()?;
        let binding = match job.execution.binding() {
            Some(binding) => binding.clone(),
            None => {
                let observed = match &job.execution {
                    ExecutionState::Dispatching {
                        conversation,
                        input_id,
                    } => gateway.native_input_binding(conversation, input_id).await,
                    ExecutionState::Unknown {
                        conversation: Some(conversation),
                        ..
                    } if job.request_fingerprint.is_some() => {
                        gateway
                            .native_input_binding(conversation, &job.current_input_id())
                            .await
                    }
                    ExecutionState::Unknown { reason, .. } => {
                        return self.record_unknown(job, reason.clone()).await;
                    }
                    _ => Ok(None),
                };
                let binding = match observed {
                    Ok(binding) => binding,
                    Err(error) => return self.record_unknown(job, format!("Native input/turn evidence is unavailable: {error:#}. {OBSERVATION_ONLY}")).await,
                };
                let Some(binding) = binding else {
                    return self.record_unknown(job, format!("The native route has no exact input/turn evidence. {OBSERVATION_ONLY}")).await;
                };
                self.store()
                    .await?
                    .advance(
                        job.job_id.clone(),
                        job.revision,
                        ExecutionState::Running { binding },
                        now_ms(),
                    )
                    .await?;
                self.dirty();
                return Ok(());
            }
        };
        let inspection = gateway
            .job_inspect_turn(&binding.conversation.thread_id, &binding.turn_id)
            .await?;
        ensure!(
            inspection["threadId"] == binding.conversation.thread_id
                && inspection["turnId"] == binding.turn_id,
            "native inspection returned another execution"
        );
        if matches!(
            inspection["activity"].as_str(),
            Some("running" | "recovering")
        ) {
            return Ok(());
        }
        let Some(outcome) = super::codex::terminal_outcome(&inspection)? else {
            let reason = inspection["outcome"]["reason"]
                .as_str()
                .unwrap_or("evidence unavailable");
            return self.record_unknown(job, format!("The exact native turn has no terminal evidence ({reason}). {OBSERVATION_ONLY}")).await;
        };
        let terminal_binding = ExecutionBinding {
            turn_id: inspection["executionTurnId"]
                .as_str()
                .context("native inspection lost its exact terminal turn")?
                .to_owned(),
            ..binding
        };
        let result = super::codex::final_result(&gateway, &terminal_binding)
            .await
            .unwrap_or_else(|error| ResultEvidence::Unavailable {
                reason: format!("exact native terminal result is unavailable: {error:#}"),
            });
        self.finalize(job, outcome, result).await?;
        self.dirty();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{FakeControl, TestGateway};
    use crate::wire::cluster::AgentAddress;

    #[tokio::test]
    async fn native_observation_reloads_without_policy_or_execution_authority() {
        let gateway = TestGateway::new();
        let mut control = FakeControl::attach(&gateway, 8).await.requests;
        let conversation = gateway.job_new_claude_conversation().unwrap();
        let parent = gateway.job_new_claude_conversation().unwrap();
        let agent = gateway
            .jobs
            .store()
            .await
            .unwrap()
            .adopt_conversation(AgentRecord {
                agent_id: "native-observation".into(),
                conversation: ConversationBinding::Known {
                    conversation: conversation.clone(),
                },
                origin: Origin::TopLevel,
                tool_scope: None,
                origin_job_id: None,
                latest_job_id: None,
                parent: Some(AgentAddress {
                    host_id: "local".into(),
                    thread_id: parent.thread_id.clone(),
                }),
                parent_revision: 1,
                parent_recipient: Some(Recipient::Conversation {
                    conversation: parent.clone(),
                }),
            })
            .await
            .unwrap();
        let id = JobId::for_mutation(Provider::Claude, "native-observation").unwrap();
        let job = gateway
            .jobs
            .observe_native(
                agent.clone(),
                id.clone(),
                ExecutionState::Unknown {
                    conversation: Some(conversation),
                    binding: None,
                    reason: "input evidence unavailable".into(),
                },
                None,
            )
            .await
            .unwrap();
        gateway.jobs.reconcile_native(&job).await.unwrap();
        let current = gateway.jobs.read(&id).await.unwrap();
        assert_eq!(current.job.execution, job.execution);
        assert!(matches!(
            current.job.execution,
            ExecutionState::Unknown { .. }
        ));
        assert!(matches!(current.job.spec, SpecEvidence::Unknown { .. }));
        assert!(current.job.provider_retries.is_empty());
        assert_eq!(
            current.job.recipient,
            Recipient::Conversation {
                conversation: parent
            }
        );
        assert_eq!(current.agent.unwrap().latest_job_id, Some(id.clone()));
        assert_eq!(current.job.notices.len(), 1);
        let CompletionPayload::Prepared { delivery_id, .. } = &current.job.notices[0].payload
        else {
            panic!("observation notice missing")
        };
        let acknowledged = gateway
            .jobs
            .store()
            .await
            .unwrap()
            .notice_delivery(
                id.clone(),
                current.job.revision,
                delivery_id.clone(),
                DeliveryState::Accepted {
                    receipt: "parent-custody".into(),
                },
                now_ms(),
            )
            .await
            .unwrap();
        assert!(!gateway.jobs.reconcile_job(id.clone()).await.unwrap());
        assert_eq!(
            gateway.jobs.read(&id).await.unwrap().job.revision,
            acknowledged.revision
        );
        assert!(matches!(
            control.try_recv(),
            Err(tokio::sync::mpsc::error::TryRecvError::Empty)
        ));
        let root = gateway.jobs.root.clone().unwrap();
        let snapshot = tempfile::tempdir().unwrap();
        for directory in ["agents", "jobs"] {
            std::fs::create_dir(snapshot.path().join(directory)).unwrap();
            for entry in std::fs::read_dir(root.join(directory)).unwrap() {
                let entry = entry.unwrap();
                std::fs::copy(
                    entry.path(),
                    snapshot.path().join(directory).join(entry.file_name()),
                )
                .unwrap();
            }
        }
        let reopened = super::super::store::JobStore::open(snapshot.path().to_owned())
            .await
            .unwrap();
        assert_eq!(
            reopened.agent(agent.agent_id).await.unwrap().latest_job_id,
            Some(id.clone())
        );
        assert_eq!(reopened.read(id).await.unwrap(), acknowledged);
    }

    #[tokio::test]
    async fn imported_unknown_execution_remains_inert() {
        let gateway = TestGateway::new();
        let mut control = FakeControl::attach(&gateway, 1).await.requests;
        let mut job = super::super::store_tests::job(201);
        job.source = JobSource::Imported;
        job.spec = SpecEvidence::Unknown {
            reason: "historical policy absent".into(),
        };
        job.execution = ExecutionState::Unknown {
            conversation: None,
            binding: None,
            reason: "historical execution absent".into(),
        };
        let root = gateway.jobs.root.clone().unwrap().join("jobs");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(
            root.join(format!("{}.json", job.job_id.as_str())),
            serde_json::to_vec(&job).unwrap(),
        )
        .unwrap();
        let store = gateway.jobs.store().await.unwrap();
        assert!(!store.pending_ids().await.unwrap().contains(&job.job_id));
        assert_eq!(store.read(job.job_id.clone()).await.unwrap(), job);
        assert!(matches!(
            control.try_recv(),
            Err(tokio::sync::mpsc::error::TryRecvError::Empty)
        ));
    }

    #[tokio::test]
    async fn native_finalization_uses_job_completion_without_provider_cleanup() {
        let gateway = TestGateway::new();
        for provider in [Provider::Codex, Provider::Claude] {
            let conversation = match provider {
                Provider::Codex => ConversationIdentity {
                    provider,
                    provider_home: ProviderHome::Known {
                        path: gateway.job_codex_home().unwrap(),
                    },
                    thread_id: "0e1a0399-0e3d-5aa4-ace7-0ed28835d55f".into(),
                },
                Provider::Claude => gateway.job_new_claude_conversation().unwrap(),
            };
            let parent = gateway.job_new_claude_conversation().unwrap();
            let agent = gateway
                .jobs
                .store()
                .await
                .unwrap()
                .adopt_conversation(AgentRecord {
                    agent_id: format!("native-{}", provider.as_str()),
                    conversation: ConversationBinding::Known {
                        conversation: conversation.clone(),
                    },
                    origin: Origin::TopLevel,
                    tool_scope: None,
                    origin_job_id: None,
                    latest_job_id: None,
                    parent: Some(AgentAddress {
                        host_id: "local".into(),
                        thread_id: parent.thread_id.clone(),
                    }),
                    parent_revision: 1,
                    parent_recipient: Some(Recipient::Conversation {
                        conversation: parent,
                    }),
                })
                .await
                .unwrap();
            let id = JobId::for_mutation(provider, "native-finalization").unwrap();
            let binding = ExecutionBinding {
                conversation,
                input_id: "native-input".into(),
                turn_id: "exact-native-turn".into(),
            };
            let job = gateway
                .jobs
                .observe_native(
                    agent,
                    id.clone(),
                    ExecutionState::Running {
                        binding: binding.clone(),
                    },
                    None,
                )
                .await
                .unwrap();
            gateway
                .jobs
                .finalize(
                    &job,
                    JobOutcome::Completed,
                    ResultEvidence::Available {
                        result: JobResult {
                            text: "Native final answer".into(),
                            truncated: false,
                        },
                    },
                )
                .await
                .unwrap();
            let terminal = gateway.jobs.read(&id).await.unwrap().job.execution;
            let ExecutionState::Terminal { terminal } = terminal else {
                panic!("native job was not finalized")
            };
            assert_eq!(terminal.execution, Some(binding));
            assert_eq!(terminal.cleanup, CleanupState::Complete);
            let Completion::Required {
                payload:
                    CompletionPayload::Prepared {
                        delivery_id, text, ..
                    },
                delivery,
            } = terminal.completion
            else {
                panic!("native completion missing")
            };
            assert_eq!(delivery_id, format!("{}:completion", id.as_str()));
            assert_eq!(delivery, DeliveryState::Pending);
            assert!(text.contains("Native final answer"));
            assert!(text.contains("<followup tool=\"message_agent\""));
        }
    }
}
