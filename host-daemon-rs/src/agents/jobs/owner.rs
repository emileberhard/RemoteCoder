use std::path::PathBuf;
use std::sync::Weak;

use anyhow::{Context, Result, bail, ensure};
use tokio::sync::{OnceCell, watch};

use super::model::*;
use super::store::{JobStore, Selection, fingerprint};
use crate::gateway::Gateway;
use crate::wire::agent_jobs::*;

pub(crate) struct JobOwner {
    pub(crate) contexts: super::context::Contexts,
    root: Option<PathBuf>,
    store: OnceCell<JobStore>,
    gateway: Weak<Gateway>,
    changed: watch::Sender<u64>,
}

impl JobOwner {
    pub(crate) fn new(root: Option<PathBuf>, gateway: Weak<Gateway>) -> Self {
        Self {
            contexts: Default::default(),
            root,
            store: OnceCell::new(),
            gateway,
            changed: watch::channel(0).0,
        }
    }

    pub(crate) async fn initialize(&self) -> Result<()> {
        if self.root.is_none() {
            return Ok(());
        }
        self.store().await.map(|_| ())
    }

    pub(super) async fn store(&self) -> Result<&JobStore> {
        self.store
            .get_or_try_init(|| async {
                JobStore::open(
                    self.root
                        .clone()
                        .context("delegated jobs require a persistent gateway state directory")?,
                )
                .await
            })
            .await
    }

    pub(super) fn gateway(&self) -> Result<std::sync::Arc<Gateway>> {
        self.gateway.upgrade().context("gateway is shutting down")
    }

    pub(super) fn dirty(&self) {
        self.changed
            .send_modify(|revision| *revision = revision.wrapping_add(1));
    }

    pub(super) fn changes(&self) -> watch::Receiver<u64> {
        self.changed.subscribe()
    }

    pub(crate) async fn read(&self, id: &JobId) -> Result<JobView> {
        let store = self.store().await?;
        let job = store.read(id.clone()).await?;
        let agent = store.find_agent(job.agent_id.clone()).await?;
        ensure!(
            agent.is_some() || job.source == JobSource::Imported,
            "runtime job is missing its authoritative agent record"
        );
        Ok(JobView { job, agent })
    }

    pub(crate) async fn agent(&self, id: &str) -> Result<AgentRecord> {
        self.store().await?.agent(id.into()).await
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
        created_at_ms: Option<i64>,
    ) -> Result<Option<Origin>> {
        self.store().await?.classify(conversation.clone(), created_at_ms).await
    }

    pub(crate) async fn list(&self, request: ListParams) -> Result<ListPage> {
        let selection = match request.selector {
            ListSelector::Recent => Selection::Recent,
            ListSelector::Agent { agent_id } => Selection::Agent(agent_id),
            ListSelector::Caller { .. } => {
                bail!("caller-scoped listing must resolve its identity at the gateway boundary")
            }
        };
        self.store()
            .await?
            .list(selection, request.limit, request.cursor)
            .await
    }

    pub(crate) async fn children(
        &self,
        parent: &ConversationIdentity,
        limit: u32,
        cursor: Option<String>,
    ) -> Result<ListPage> {
        self.store()
            .await?
            .list(Selection::Children(parent.clone()), limit, cursor)
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
            .list(Selection::Descendants(parent.clone()), limit, cursor)
            .await
    }

    pub(crate) async fn start(
        &self,
        request: StartParams,
        origin: Origin,
    ) -> Result<AdmissionReceipt> {
        ensure!(
            !matches!(origin, Origin::Unknown { .. }),
            "new work requires a proven parent or explicit operator intent"
        );
        let recipient = recipient(&origin);
        let request_fingerprint =
            fingerprint(&serde_json::to_vec(&(&request.spec, &origin, &recipient))?);
        let at_ms = now_ms();
        let job = JobRecord {
            agent_id: request.job_id.as_str().into(),
            job_id: request.job_id,
            request_fingerprint: Some(request_fingerprint),
            created_at_ms: Some(at_ms),
            updated_at_ms: at_ms,
            revision: 0,
            previous_job_id: None,
            source: JobSource::Runtime,
            admission_origin: Some(origin),
            unconfirmed_result: None,
            spec: SpecEvidence::Known { spec: request.spec },
            recipient,
            execution: ExecutionState::Admitted,
            stop: StopState::NotRequested,
        };
        let (job, duplicate) = self.store().await?.admit(job).await?;
        self.dirty();
        Ok(AdmissionReceipt { job, duplicate })
    }

    pub(crate) async fn continue_job(
        &self,
        request: ContinueParams,
        caller: Origin,
    ) -> Result<AdmissionReceipt> {
        let store = self.store().await?;
        let current_recipient = match &request.recipient {
            ContinueRecipient::Previous => None,
            ContinueRecipient::Current => Some(recipient(&caller)),
        };
        let request_fingerprint = fingerprint(&serde_json::to_vec(&(
            &request.agent_id,
            &request.prompt,
            &request.settings,
            &request.recipient,
            &current_recipient,
        ))?);
        if let Some(job) = store
            .existing_request(request.job_id.clone(), request_fingerprint.clone())
            .await?
        {
            return Ok(AdmissionReceipt {
                job,
                duplicate: true,
            });
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
            SpecEvidence::Unknown { .. } => bail!(
                "historical execution settings are unresolved; this conversation cannot continue until they are proven"
            ),
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
            ContinueRecipient::Current => recipient(&caller),
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
            source: JobSource::Runtime,
            admission_origin: None,
            unconfirmed_result: None,
            spec: SpecEvidence::Known { spec },
            recipient,
            execution: ExecutionState::Admitted,
            stop: StopState::NotRequested,
        };
        let (job, duplicate) = store.admit(job).await?;
        self.dirty();
        Ok(AdmissionReceipt { job, duplicate })
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
        let job = store.read(request.job_id.clone()).await?;
        let job = store
            .delivery(
                request.job_id,
                job.revision,
                DeliveryState::Dismissed {
                    reason: request.reason,
                },
                now_ms(),
            )
            .await?;
        self.dirty();
        Ok(job)
    }
}

fn recipient(origin: &Origin) -> Recipient {
    match origin {
        Origin::TopLevel => Recipient::None,
        Origin::Parent { conversation } => Recipient::Conversation {
            conversation: conversation.clone(),
        },
        Origin::Unknown { reason } => Recipient::Unknown {
            reason: reason.clone(),
        },
    }
}

pub(super) fn now_ms() -> i64 {
    (crate::time::unix_seconds() * 1000.0) as i64
}
