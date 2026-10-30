use std::path::PathBuf;
use std::sync::{Arc, Weak};

use anyhow::{Context, Result, bail, ensure};
use tokio::sync::{Mutex, OnceCell, RwLock, watch};

use super::model::*;
use super::store::{JobStore, Selection, fingerprint};
use crate::gateway::Gateway;
use crate::wire::agent_jobs::*;

pub(crate) struct JobOwner {
    pub(crate) contexts: super::context::Contexts,
    pub(crate) native_routes: super::routes::NativeRoutes,
    pub(crate) operations: RwLock<()>,
    pub(crate) tasks: crate::tasks::owned_tasks::OwnedTasks,
    pub(super) scopes: super::routes::ScopedEndpoints,
    pub(super) endpoint: Mutex<Option<super::routes::ScopedEndpointLease>>,
    pub(super) root: Option<PathBuf>,
    store: OnceCell<JobStore>,
    message_claims: Mutex<std::collections::HashMap<String, Weak<Mutex<()>>>>,
    gateway: Weak<Gateway>,
    changed: watch::Sender<u64>,
}

impl JobOwner {
    pub(crate) fn new(root: Option<PathBuf>, gateway: Weak<Gateway>) -> Self {
        Self {
            contexts: Default::default(),
            native_routes: Default::default(),
            operations: Default::default(),
            tasks: Default::default(),
            scopes: Default::default(),
            endpoint: Default::default(),
            root,
            store: OnceCell::new(),
            message_claims: Default::default(),
            gateway,
            changed: watch::channel(0).0,
        }
    }

    pub(crate) async fn initialize(&self) -> Result<()> {
        if self.root.is_none() {
            return Ok(());
        }
        self.store().await?;
        self.ensure_endpoint().await
    }

    pub(crate) async fn store(&self) -> Result<&JobStore> {
        self.store
            .get_or_try_init(|| async {
                let store = JobStore::open(
                    self.root
                        .clone()
                        .context("delegated jobs require a persistent gateway state directory")?,
                )
                .await?;
                let host = self.gateway()?.host_identity().await?.host_id;
                store.initialize_parent_tags(host).await?;
                Ok::<_, anyhow::Error>(store)
            })
            .await
    }

    pub(crate) async fn claim_message(&self, id: &str) -> Result<tokio::sync::OwnedMutexGuard<()>> {
        let lock = {
            let mut claims = self.message_claims.lock().await;
            claims.retain(|_, claim| claim.strong_count() > 0);
            if let Some(lock) = claims.get(id).and_then(Weak::upgrade) {
                lock
            } else {
                ensure!(
                    claims.len() < MAX_UNSETTLED_JOBS,
                    "message delivery concurrency is at capacity; inspect existing receipts before retrying"
                );
                let lock = Arc::new(Mutex::new(()));
                claims.insert(id.to_owned(), Arc::downgrade(&lock));
                lock
            }
        };
        Ok(lock.lock_owned().await)
    }

    pub(crate) fn gateway(&self) -> Result<std::sync::Arc<Gateway>> {
        self.gateway.upgrade().context("gateway is shutting down")
    }

    pub(crate) fn dirty(&self) {
        self.changed
            .send_modify(|revision| *revision = revision.wrapping_add(1));
    }

    pub(crate) fn changes(&self) -> watch::Receiver<u64> {
        self.changed.subscribe()
    }

    async fn admission_receipt(&self, job: JobRecord, duplicate: bool) -> Result<AdmissionReceipt> {
        let identity = self.gateway()?.host_identity().await?;
        let address =
            job.execution
                .conversation()
                .map(|conversation| crate::wire::cluster::AgentAddress {
                    host_id: identity.host_id.clone(),
                    thread_id: conversation.thread_id.clone(),
                });
        let state = if matches!(job.stop, StopState::Requested { .. }) {
            crate::agents::State::Interrupted
        } else {
            match &job.execution {
                ExecutionState::Terminal { terminal } => match terminal.outcome {
                    JobOutcome::Completed => crate::agents::State::Completed,
                    JobOutcome::Failed { .. } => crate::agents::State::Failed,
                    JobOutcome::Stopped { .. } => crate::agents::State::Interrupted,
                },
                ExecutionState::Unknown { .. } => crate::agents::State::Unknown,
                ExecutionState::Running { .. }
                | ExecutionState::Recovering { .. }
                | ExecutionState::Dispatching { .. } => crate::agents::State::Working,
                _ => crate::agents::State::Waiting,
            }
        };
        Ok(AdmissionReceipt {
            protocol: crate::wire::cluster::PROTOCOL,
            owner_host_id: identity.host_id,
            job_id: job.job_id.clone(),
            address,
            state,
            incarnation: identity.incarnation,
            job,
            duplicate,
        })
    }

    pub(crate) async fn read(&self, id: &JobId) -> Result<JobView> {
        let store = self.store().await?;
        let job = store.read(id.clone()).await?;
        let agent = store.find_agent(job.agent_id.clone()).await?;
        ensure!(
            agent.is_some() || job.source == JobSource::Imported,
            "runtime job is missing its authoritative agent record"
        );
        let owner_host_id = Some(self.gateway()?.host_identity().await?.host_id.clone());
        let parent = agent.as_ref().and_then(|agent| agent.parent.clone());
        let recipient = Some(job.recipient.clone());
        Ok(JobView {
            owner_host_id,
            parent,
            recipient,
            job,
            agent,
        })
    }

    pub(crate) async fn agent_for_conversation(
        &self,
        conversation: &ConversationIdentity,
    ) -> Result<Option<AgentRecord>> {
        self.store()
            .await?
            .agent_for_conversation(conversation.clone())
            .await
    }

    pub(crate) async fn classify(
        &self,
        conversation: &ConversationIdentity,
        creation: Creation,
    ) -> Result<Option<Origin>> {
        self.store()
            .await?
            .classify(conversation.clone(), creation)
            .await
    }

    pub(crate) async fn list(&self, request: ListParams) -> Result<ListPage> {
        let selection = match request.selector {
            ListSelector::Recent => Selection::Recent,
            ListSelector::Agent { agent_id } => Selection::Agent(agent_id),
            ListSelector::Caller { .. } => {
                bail!("caller-scoped listing must resolve its identity at the gateway boundary")
            }
        };
        let mut page = self
            .store()
            .await?
            .list(selection, request.limit, request.cursor)
            .await?;
        let owner = self.gateway()?.host_identity().await?.host_id.clone();
        for row in &mut page.jobs {
            row.owner_host_id = Some(owner.clone());
        }
        Ok(page)
    }

    pub(crate) async fn children(
        &self,
        parent: &ConversationIdentity,
        limit: u32,
        cursor: Option<String>,
    ) -> Result<ListPage> {
        self.store()
            .await?
            .list(
                Selection::Children(crate::wire::cluster::AgentAddress {
                    host_id: self.gateway()?.host_identity().await?.host_id,
                    thread_id: parent.thread_id.clone(),
                }),
                limit,
                cursor,
            )
            .await
    }

    pub(crate) async fn descendants(
        &self,
        parent: &ConversationIdentity,
        limit: u32,
        cursor: Option<String>,
    ) -> Result<ListPage> {
        self.store()
            .await?
            .list(
                Selection::Descendants(crate::wire::cluster::AgentAddress {
                    host_id: self.gateway()?.host_identity().await?.host_id,
                    thread_id: parent.thread_id.clone(),
                }),
                limit,
                cursor,
            )
            .await
    }

    pub(crate) async fn start(
        &self,
        request: StartParams,
        origin: Origin,
    ) -> Result<AdmissionReceipt> {
        let _operation = self.operations.read().await;
        ensure!(
            !self.gateway()?.is_draining(),
            "gateway is restarting; admission is closed"
        );
        ensure!(
            !matches!(origin, Origin::Unknown { .. }),
            "new work requires a proven parent or explicit operator intent"
        );
        let recipient = recipient(&origin, &request.caller);
        let initial_parent = match &origin {
            Origin::Parent { conversation } => Some(crate::wire::cluster::AgentAddress {
                host_id: self.gateway()?.host_identity().await?.host_id.clone(),
                thread_id: conversation.thread_id.clone(),
            }),
            Origin::RemoteParent { host, conversation } => {
                Some(crate::wire::cluster::AgentAddress {
                    host_id: host.clone(),
                    thread_id: conversation.thread_id.clone(),
                })
            }
            _ => None,
        };
        let admitted_membership = match &request.caller {
            Caller::Forwarded { membership, .. } => Some(membership.clone()),
            _ => None,
        };
        let request_fingerprint =
            fingerprint(&serde_json::to_vec(&(&request.spec, &origin, &recipient))?);
        if let Some(job) = self
            .store()
            .await?
            .existing_request(request.job_id.clone(), request_fingerprint.clone())
            .await?
        {
            return self.admission_receipt(job, true).await;
        }
        if !request.spec.cwd.is_dir() {
            return Err(crate::rpc::RpcError::new(crate::rpc::error::RpcCode::InvalidParams,"working directory is missing on the target host; pass --cwd with an existing target path").with_data(crate::rpc::error::RpcData::Raw(serde_json::json!({"class":"usage"}))).into());
        }
        if let ToolScope::ReadOnly { root } = &request.spec.tool_scope {
            ensure!(
                root.is_dir()
                    && request
                        .spec
                        .cwd
                        .canonicalize()?
                        .starts_with(root.canonicalize()?),
                "working directory must be inside the target host's read-only root"
            );
        }
        let at_ms = now_ms();
        let job = JobRecord {
            agent_id: request.job_id.as_str().into(),
            job_id: request.job_id,
            request_fingerprint: Some(request_fingerprint),
            created_at_ms: Some(at_ms),
            updated_at_ms: at_ms,
            revision: 0,
            previous_job_id: None,
            provider_retries: Vec::new(),
            source: JobSource::Runtime,
            admitted_membership,
            remote_fingerprint: match &request.caller {
                Caller::Forwarded {
                    admission_fingerprint,
                    ..
                } => admission_fingerprint.clone(),
                _ => None,
            },
            parent_revision: 0,
            initial_parent,
            admission_origin: Some(origin),
            unconfirmed_result: None,
            attention: None,
            notices: Vec::new(),
            spec: SpecEvidence::Known { spec: request.spec },
            recipient,
            execution: ExecutionState::Admitted,
            stop: StopState::NotRequested,
        };
        let (job, duplicate) = self.store().await?.admit(job).await?;
        self.dirty();
        self.admission_receipt(job, duplicate).await
    }

    pub(crate) async fn continue_job(
        &self,
        request: ContinueParams,
        caller: Origin,
    ) -> Result<AdmissionReceipt> {
        let _operation = self.operations.read().await;
        ensure!(
            !self.gateway()?.is_draining(),
            "gateway is restarting; admission is closed"
        );
        let store = self.store().await?;
        let current_recipient = match &request.recipient {
            ContinueRecipient::Previous => None,
            ContinueRecipient::Current => Some(recipient(&caller, &request.caller)),
        };
        let request_bytes = if request.intent == ContinueIntent::Message {
            serde_json::to_vec(&(
                &request.agent_id,
                &request.prompt,
                &request.settings,
                &request.recipient,
                &current_recipient,
                &request.expected_previous_job_id,
                &request.intent,
            ))?
        } else if request.expected_previous_job_id.is_some() {
            serde_json::to_vec(&(
                &request.agent_id,
                &request.prompt,
                &request.settings,
                &request.recipient,
                &current_recipient,
                &request.expected_previous_job_id,
            ))?
        } else {
            serde_json::to_vec(&(
                &request.agent_id,
                &request.prompt,
                &request.settings,
                &request.recipient,
                &current_recipient,
            ))?
        };
        let request_fingerprint = fingerprint(&request_bytes);
        if let Some(job) = store
            .existing_request(request.job_id.clone(), request_fingerprint.clone())
            .await?
        {
            return self.admission_receipt(job, true).await;
        }
        let agent = store.agent(request.agent_id.clone()).await?;
        let previous = store
            .read(
                agent
                    .latest_job_id
                    .clone()
                    .context("conversation's latest job is unresolved")?,
            )
            .await?;
        ensure!(
            request
                .expected_previous_job_id
                .as_ref()
                .is_none_or(|expected| expected == &previous.job_id),
            "Continue target was superseded; inspect its latest job before sending more work"
        );
        if previous.source == JobSource::Imported {
            let ConversationBinding::Known { conversation } = &agent.conversation else {
                bail!("historical provider conversation is unresolved");
            };
            ensure!(
                conversation.provider == Provider::Claude
                    || matches!(&previous.execution, ExecutionState::Terminal { .. }),
                "historical Codex continuation needs a confirmed terminal result"
            );
            let gateway = self.gateway()?;
            ensure!(
                gateway
                    .job_provider_recovery_complete(conversation.provider)
                    .await?,
                "provider recovery is unresolved; continuation cannot prove idle"
            );
            ensure!(
                gateway
                    .claude_active_turn_id(&conversation.thread_id)
                    .await
                    .is_none(),
                "historical conversation is still running"
            );
            let object = serde_json::json!({"params":{"threadId":conversation.thread_id}});
            if let Some(error) = gateway
                .other_client_refusal(
                    "thread/resume",
                    object
                        .as_object()
                        .context("continuation request is not an object")?,
                )
                .await
            {
                bail!(
                    "historical continuation cannot acquire this conversation: {}",
                    error.message
                );
            }
        }
        let (cwd, original_settings, tool_scope, title) = match &previous.spec {
            SpecEvidence::Known { spec } => (
                spec.cwd.clone(),
                spec.settings.clone(),
                spec.tool_scope.clone(),
                spec.title.clone(),
            ),
            SpecEvidence::Expired {
                cwd,
                settings,
                tool_scope,
                title,
            } => (
                cwd.clone(),
                settings.clone(),
                tool_scope.clone(),
                title.clone(),
            ),
            SpecEvidence::Unknown { .. } => {
                ensure!(
                    previous.source == JobSource::Imported,
                    "runtime job has no execution specification"
                );
                let ConversationBinding::Known { conversation } = &agent.conversation else {
                    bail!("historical provider conversation is unresolved");
                };
                ensure!(
                    conversation.provider == Provider::Claude,
                    "historical Codex execution settings are unresolved"
                );
                let response = self
                    .gateway()?
                    .claude_thread_response(&serde_json::json!({"threadId":conversation.thread_id}))
                    .await
                    .map_err(|error| anyhow::anyhow!(error.message))?;
                let header = &response["thread"];
                ensure!(
                    crate::agents::conversation::conversation_from_header(header)? == *conversation,
                    "provider history resolved a different conversation or home"
                );
                let cwd = PathBuf::from(
                    header["cwd"]
                        .as_str()
                        .context("historical working directory is unknown")?,
                );
                ensure!(
                    cwd.is_absolute(),
                    "historical working directory is unavailable"
                );
                let settings = ExecutionSettings::Claude {
                    model: header["model"]
                        .as_str()
                        .context("historical model is unknown")?
                        .to_owned(),
                    effort: header["reasoningEffort"].as_str().map(str::to_owned),
                    fast: false,
                };
                (
                    cwd,
                    settings,
                    agent
                        .tool_scope
                        .clone()
                        .context("historical permission scope is unresolved")?,
                    header["name"].as_str().map(str::to_owned),
                )
            }
        };
        ensure!(
            matches!(
                agent.conversation,
                ConversationBinding::Known {
                    conversation: ConversationIdentity {
                        provider_home: ProviderHome::Known { .. },
                        ..
                    }
                }
            ),
            "Continue requires an exact recorded provider conversation and home"
        );
        let settings = request
            .settings
            .unwrap_or_else(|| original_settings.clone());
        ensure!(
            agent.tool_scope.as_ref() == Some(&tool_scope),
            "conversation's permission scope is unresolved or conflicts with its latest job"
        );
        ensure!(
            settings.provider() == original_settings.provider(),
            "Continue cannot change provider"
        );
        if let (
            ExecutionSettings::Codex {
                model_provider: old,
                ..
            },
            ExecutionSettings::Codex {
                model_provider: new,
                ..
            },
        ) = (&original_settings, &settings)
        {
            ensure!(
                old == new,
                "Continue cannot change the conversation's model provider"
            );
        }
        let recipient = match request.recipient {
            ContinueRecipient::Previous => previous.recipient.clone(),
            ContinueRecipient::Current => recipient(&caller, &request.caller),
        };
        ensure!(
            !matches!(recipient, Recipient::Unknown { .. }),
            "Continue recipient is unresolved"
        );
        let spec = JobSpec {
            prompt: request.prompt,
            cwd,
            settings,
            tool_scope,
            title,
        };
        let at_ms = now_ms();
        let job = JobRecord {
            job_id: request.job_id,
            agent_id: request.agent_id,
            request_fingerprint: Some(request_fingerprint),
            created_at_ms: Some(at_ms),
            updated_at_ms: at_ms,
            revision: 0,
            previous_job_id: Some(previous.job_id),
            provider_retries: Vec::new(),
            source: JobSource::Runtime,
            admitted_membership: match &request.caller {
                Caller::Forwarded { membership, .. } => Some(membership.clone()),
                _ => None,
            },
            remote_fingerprint: match &request.caller {
                Caller::Forwarded {
                    admission_fingerprint,
                    ..
                } => admission_fingerprint.clone(),
                _ => None,
            },
            parent_revision: agent.parent_revision,
            initial_parent: agent.parent.clone(),
            admission_origin: None,
            unconfirmed_result: None,
            attention: None,
            notices: Vec::new(),
            spec: SpecEvidence::Known { spec },
            recipient,
            execution: ExecutionState::Admitted,
            stop: StopState::NotRequested,
        };
        let (job, duplicate) = match request.intent {
            ContinueIntent::Explicit => store.admit(job).await?,
            ContinueIntent::Message => store.admit_message_continuation(job).await?,
        };
        self.dirty();
        self.admission_receipt(job, duplicate).await
    }

    pub(crate) async fn stop(&self, request: StopParams) -> Result<JobRecord> {
        let job = self
            .store()
            .await?
            .request_stop(request.job_id, request.mutation_id, now_ms())
            .await?;
        self.dirty();
        Ok(job)
    }

    pub(crate) async fn dismiss(&self, request: DismissParams) -> Result<JobRecord> {
        ensure!(
            !request.mutation_id.is_empty() && request.mutation_id.len() <= 200,
            "dismissal requires a stable mutation identity"
        );
        ensure!(
            !request.reason.trim().is_empty() && request.reason.len() <= 4096,
            "dismissal requires a nonempty reason of at most 4096 bytes"
        );
        let store = self.store().await?;
        let job = store
            .dismiss_obligations(request.job_id, request.reason, now_ms())
            .await?;
        self.dirty();
        Ok(job)
    }
}

fn recipient(origin: &Origin, caller: &Caller) -> Recipient {
    match origin {
        Origin::TopLevel => Recipient::None,
        Origin::Parent { conversation } => Recipient::Conversation {
            conversation: conversation.clone(),
        },
        Origin::RemoteParent { host, conversation } => match caller {
            Caller::Forwarded { incarnation, .. } => Recipient::Remote {
                host: host.clone(),
                incarnation: incarnation.clone(),
                conversation: conversation.clone(),
            },
            _ => Recipient::Unknown {
                reason: "remote caller has no proven incarnation".into(),
            },
        },
        Origin::Unknown { reason } => Recipient::Unknown {
            reason: reason.clone(),
        },
    }
}

pub(super) fn now_ms() -> i64 {
    (crate::time::unix_seconds() * 1000.0) as i64
}
