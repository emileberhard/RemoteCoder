pub(crate) mod cluster;
mod execution;
pub(crate) mod messages;

use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result, bail, ensure};
use serde::de::DeserializeOwned;
use sha2::{Digest, Sha256};

use super::model::*;
use crate::storage::private_state::{self, ReadError};
use crate::wire::agent_jobs::{JobSummary, ListPage};

const MAX_AGENT_BYTES: u64 = 16 * 1024;
const MAX_EVIDENCE_BYTES: u64 = 1024 * 1024;
const RUNTIME_RESERVATION: u64 = 2 * (MAX_JOB_BYTES + MAX_EVIDENCE_BYTES + MAX_AGENT_BYTES);
const MUTATION_RESERVE: u64 = 2 * MAX_JOB_BYTES;
const RETENTION_MS: i64 = 30 * 24 * 60 * 60 * 1000;

#[derive(Clone)]
pub(crate) struct JobStore {
    inner: Arc<Mutex<Inner>>,
    executions: Arc<execution::ExecutionGates>,
}

struct Inner {
    root: PathBuf,
    _lease: File,
    jobs: BTreeMap<JobId, JobRecord>,
    agents: BTreeMap<String, AgentRecord>,
    parents:
        std::collections::HashMap<ConversationIdentity, Option<crate::wire::cluster::AgentAddress>>,
    uncertainties: Vec<ImportedUncertainty>,
    messages: BTreeMap<String, messages::MessageRecord>,
    intents: BTreeMap<JobId, crate::wire::cluster::RemoteIntent>,
    fences: BTreeMap<String, crate::wire::cluster::CancelFence>,
}

pub(crate) enum Selection {
    Recent,
    Agent(String),
    Children(crate::wire::cluster::AgentAddress),
    Descendants(crate::wire::cluster::AgentAddress),
}

impl JobStore {
    pub(crate) async fn open(root: PathBuf) -> Result<Self> {
        tokio::task::spawn_blocking(move || {
            private_state::ensure_private_directory(&root)?;
            let lease = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(root.join("owner.lock"))?;
            lease.try_lock().context("another process owns the delegated-job store")?;
            let mut inner = Inner { root, _lease: lease, jobs: BTreeMap::new(), agents: BTreeMap::new(), parents:Default::default(), uncertainties: Vec::new(), messages: BTreeMap::new(), intents: BTreeMap::new(), fences: BTreeMap::new() };
            for name in ["jobs", "agents", "evidence", "uncertainties", "messages", "remote-intents", "cancel-fences"] {
                private_state::ensure_private_directory(&inner.root.join(name))?;
            }
            File::open(&inner.root)?.sync_all()?;
            for entry in std::fs::read_dir(inner.root.join("jobs"))? {
                let entry = entry?;
                if entry.path().extension().is_none_or(|extension| extension != "json") {
                    continue;
                }
                let job: JobRecord = read(&entry.path(), MAX_JOB_BYTES)?;
                validate_job(&job)?;
                ensure!(entry.path() == inner.job_path(&job.job_id), "job filename does not match its identity");
                ensure!(inner.jobs.insert(job.job_id.clone(), job).is_none(), "duplicate persisted job identity");
            }
            for entry in std::fs::read_dir(inner.root.join("agents"))? {
                let entry = entry?;
                if entry.path().extension().is_none_or(|extension| extension != "json") {
                    continue;
                }
                let agent: AgentRecord = read(&entry.path(), MAX_AGENT_BYTES)?;
                ensure!(entry.path() == inner.agent_path(&agent.agent_id), "agent filename does not match its identity");
                inner.index_parent(&agent);
                ensure!(inner.agents.insert(agent.agent_id.clone(), agent).is_none(), "duplicate persisted agent identity");
            }
            inner.recover_agents()?;
            for entry in std::fs::read_dir(inner.root.join("uncertainties"))? {
                let entry = entry?;
                if entry.path().extension().is_none_or(|extension| extension != "json") { continue; }
                let evidence: ImportedUncertainty = read(&entry.path(), MAX_AGENT_BYTES)?;
                ensure!(!evidence.evidence_id.is_empty() && evidence.evidence_id.len() <= 512, "invalid historical uncertainty identity");
                ensure!(entry.path().file_stem().and_then(|name| name.to_str()) == Some(fingerprint(evidence.evidence_id.as_bytes()).as_str()), "historical uncertainty filename differs from its identity");
                inner.uncertainties.push(evidence);
            }
            inner.load_messages()?;
            inner.load_cluster()?;
            inner.validate_slots()?;
            let accounted = inner.accounted_bytes()?;
            if accounted + MUTATION_RESERVE > MAX_STORE_BYTES {
                tracing::warn!(accounted, "delegated-job store is over its budget; admission stays closed until settled payloads are reclaimed");
            }
            Ok(Self { inner: Arc::new(Mutex::new(inner)), executions: Arc::default() })
        }).await.context("opening delegated-job store")?
    }

    async fn access<T: Send + 'static>(
        &self,
        operation: impl FnOnce(&mut Inner) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let inner = Arc::clone(&self.inner);
        tokio::task::spawn_blocking(move || {
            let mut guard = inner
                .lock()
                .map_err(|_| anyhow::anyhow!("delegated-job store owner panicked"))?;
            operation(&mut guard)
        })
        .await
        .context("delegated-job store operation")?
    }

    pub(crate) async fn read(&self, id: JobId) -> Result<JobRecord> {
        self.access(move |inner| inner.job(&id).cloned()).await
    }

    pub(crate) async fn existing_request(
        &self,
        id: JobId,
        fingerprint: String,
    ) -> Result<Option<JobRecord>> {
        self.access(move |inner| inner.existing_request(&id, &fingerprint))
            .await
    }

    pub(crate) async fn ensure_new_message_id(&self, delivery_id: String) -> Result<()> {
        self.access(move |inner| {
            let matches = |payload: &CompletionPayload| match payload {
                CompletionPayload::Prepared { delivery_id: retained, .. }
                | CompletionPayload::Expired { delivery_id: retained, .. } => retained == &delivery_id,
                CompletionPayload::HistoricalUnreplayable { delivery_id: retained, .. } => retained.as_ref() == Some(&delivery_id),
            };
            for job in inner.jobs.values() {
                ensure!(!job.notices.iter().any(|notice| matches(&notice.payload)), "delivery ID belongs to a retained job notice; inspect its receipt instead of resending it");
                if let ExecutionState::Terminal { terminal } = &job.execution
                    && let Completion::Required { payload, .. } = &terminal.completion {
                    ensure!(!matches(payload), "delivery ID belongs to a retained completion; inspect its receipt instead of resending it");
                }
            }
            Ok(())
        }).await
    }

    pub(crate) async fn agent(&self, agent_id: String) -> Result<AgentRecord> {
        self.access(move |inner| inner.agent_view(&agent_id)).await
    }

    pub(crate) async fn find_agent(&self, agent_id: String) -> Result<Option<AgentRecord>> {
        self.access(move |inner| {
            if inner.agents.contains_key(&agent_id) {
                inner.agent_view(&agent_id).map(Some)
            } else {
                Ok(None)
            }
        })
        .await
    }

    pub(crate) async fn pending_ids(&self) -> Result<Vec<JobId>> {
        self.access(|inner| {
            Ok(inner
                .jobs
                .values()
                .filter(|job| {
                    job.source == JobSource::Runtime && !settled(job)
                        || !is_terminal(job) && matches!(job.stop, StopState::Requested { .. })
                })
                .map(|job| job.job_id.clone())
                .collect())
        })
        .await
    }

    pub(crate) async fn classify(
        &self,
        conversation: ConversationIdentity,
        created_at_ms: Option<i64>,
    ) -> Result<Option<Origin>> {
        self.access(move |inner| {
            let mut found = inner.agents.values().filter(|agent| matches!(&agent.conversation, ConversationBinding::Known { conversation: known } if known == &conversation));
            let origin = found.next().map(|agent| agent.origin.clone());
            ensure!(found.next().is_none(), "multiple agents claim the same provider conversation");
            if origin.is_some() { return Ok(origin); }
            if inner.agents.values().any(|agent| matches!(&agent.conversation, ConversationBinding::Known { conversation: known } if known.provider == conversation.provider && known.thread_id == conversation.thread_id && matches!(known.provider_home, ProviderHome::Unknown { .. }))) {
                return Ok(Some(Origin::Unknown { reason: "recorded conversation ancestry has an unresolved provider home".into() }));
            }
            if let Some(evidence) = inner.uncertainties.iter().find(|evidence| {
                evidence.provider.is_none_or(|provider| provider == conversation.provider)
                    && evidence.provider_home.as_ref().is_none_or(|home| matches!(&conversation.provider_home, ProviderHome::Known { path } if path == home))
                    && evidence.thread_id.as_ref().is_none_or(|thread| thread == &conversation.thread_id)
                    && (evidence.thread_id.is_some() || created_at_ms.zip(evidence.latest_possible_creation_ms).is_none_or(|(created, latest)| created <= latest))
            }) {
                return Ok(Some(Origin::Unknown { reason: format!("historical ancestry is unresolved: {}", evidence.reason) }));
            }
            let unresolved = inner.jobs.values().any(|job| job.execution.conversation().is_some_and(|known| {
                known.provider == conversation.provider && known.thread_id == conversation.thread_id && (known.provider_home == conversation.provider_home || matches!(known.provider_home, ProviderHome::Unknown { .. }))
            }));
            Ok(unresolved.then(|| Origin::Unknown { reason: "recorded job ancestry or provider scope is unresolved".into() }))
        }).await
    }

    pub(crate) async fn verify_legacy_socket(
        &self,
        conversation: ConversationIdentity,
        socket: PathBuf,
    ) -> Result<()> {
        ensure!(
            super::routes::is_legacy_socket(&socket),
            "unrecognized legacy scoped socket"
        );
        self.access(move |inner| {
            let matches = inner.jobs.values().any(|job| {
                super::routes::legacy_socket(&job.job_id) == socket
                    && inner.agents.get(&job.agent_id).is_some_and(|agent|
                        matches!(&agent.conversation, ConversationBinding::Known { conversation: known } if known == &conversation))
            });
            ensure!(matches, "legacy scoped socket does not belong to this gateway's exact calling conversation");
            Ok(())
        }).await
    }

    pub(crate) async fn agent_for_conversation(
        &self,
        conversation: ConversationIdentity,
    ) -> Result<Option<AgentRecord>> {
        self.access(move |inner| {
            let mut found = inner.agents.values().filter(|agent| matches!(&agent.conversation, ConversationBinding::Known { conversation: known } if known == &conversation));
            let id = found.next().map(|agent| agent.agent_id.clone());
            ensure!(found.next().is_none(), "multiple agents claim the same provider conversation");
            id.map(|id| inner.agent_view(&id)).transpose()
        }).await
    }

    pub(crate) async fn list(
        &self,
        selection: Selection,
        limit: u32,
        cursor: Option<String>,
    ) -> Result<ListPage> {
        self.access(move |inner| {
            ensure!(
                (1..=256).contains(&limit),
                "job page limit must be between 1 and 256"
            );
            let before = cursor
                .map(|id| {
                    let id = JobId::try_from(id).map_err(anyhow::Error::msg)?;
                    let job = inner.job(&id)?;
                    Ok::<_, anyhow::Error>((job.created_at_ms, id))
                })
                .transpose()?;
            let included = match &selection {
                Selection::Children(parent) | Selection::Descendants(parent) => {
                    let mut parents = std::collections::HashSet::from([parent.clone()]);
                    let mut included = std::collections::HashSet::new();
                    loop {
                        let mut changed = false;
                        for agent in inner.agents.values() {
                            if agent
                                .parent
                                .as_ref()
                                .is_some_and(|parent| parents.contains(parent))
                                && included.insert(agent.agent_id.clone())
                            {
                                changed = true;
                                if matches!(selection, Selection::Descendants(_))
                                    && let ConversationBinding::Known { conversation } =
                                        &agent.conversation
                                {
                                    parents.insert(crate::wire::cluster::AgentAddress {
                                        host_id: parent.host_id.clone(),
                                        thread_id: conversation.thread_id.clone(),
                                    });
                                }
                            }
                        }
                        if !changed || matches!(selection, Selection::Children(_)) {
                            break;
                        }
                    }
                    Some(included)
                }
                _ => None,
            };
            let mut records: Vec<_> = inner
                .jobs
                .values()
                .filter(|job| {
                    let matches = match &selection {
                        Selection::Recent => true,
                        Selection::Agent(id) => &job.agent_id == id,
                        _ => included
                            .as_ref()
                            .is_some_and(|ids| ids.contains(&job.agent_id)),
                    };
                    matches
                        && before.as_ref().is_none_or(|before| {
                            (job.created_at_ms, &job.job_id) < (before.0, &before.1)
                        })
                })
                .collect();
            records.sort_by(|left, right| {
                (right.created_at_ms, &right.job_id).cmp(&(left.created_at_ms, &left.job_id))
            });
            let more = records.len() > limit as usize;
            records.truncate(limit as usize);
            let next_cursor = more.then(|| {
                records
                    .last()
                    .expect("nonempty bounded page")
                    .job_id
                    .as_str()
                    .to_owned()
            });
            let jobs = records
                .into_iter()
                .map(|job| inner.summary(job))
                .collect::<Result<Vec<_>>>()?;
            Ok(ListPage { jobs, next_cursor })
        })
        .await
    }

    pub(crate) async fn evidence_root(&self, id: JobId) -> Result<PathBuf> {
        self.access(move |inner| {
            inner.job(&id)?;
            let path = inner.root.join("evidence").join(id.as_str());
            private_state::ensure_private_directory(&path)?;
            File::open(path.parent().context("evidence parent missing")?)?.sync_all()?;
            Ok(path)
        })
        .await
    }

    pub(crate) async fn admit(&self, job: JobRecord) -> Result<(JobRecord, bool)> {
        self.admit_with_stop_fence(job, false).await
    }

    pub(crate) async fn admit_message_continuation(
        &self,
        job: JobRecord,
    ) -> Result<(JobRecord, bool)> {
        self.admit_with_stop_fence(job, true).await
    }

    async fn admit_with_stop_fence(
        &self,
        mut job: JobRecord,
        require_unstopped: bool,
    ) -> Result<(JobRecord, bool)> {
        let _previous = match &job.previous_job_id {
            Some(previous) => Some(self.executions.mutation(previous).await?),
            None => None,
        };
        self.access(move |inner| {
            let _previous = _previous;
            if job.admitted_membership.is_some() && let Some(fence)=inner.fences.values().find(|fence|fence.job_id==job.job_id && job.admitted_membership.as_deref()==Some(fence.membership.as_str())) {
                job.stop=StopState::Requested {mutation_id:format!("cluster:{}",fence.membership),at_ms:fence.at};
            }
            validate_job(&job)?;
            ensure!(job.source == JobSource::Runtime && job.revision == 0, "new admission requires an initial runtime job");
            if let Some(previous) = inner.existing_request(&job.job_id, job.request_fingerprint.as_deref().context("new admission requires its request fingerprint")?)? {
                return Ok((previous, true));
            }
            ensure!(matches!(job.execution, ExecutionState::Admitted), "new admission must start admitted");
            ensure!(serde_json::to_vec(&job)?.len() as u64 <= MAX_JOB_BYTES - MAX_RESULT_BYTES as u64 - 64 * 1024, "encoded job input leaves insufficient room for its terminal result; shorten the prompt or reference a file");
            ensure!(inner.jobs.values().filter(|existing| live_reservation(existing)).count() < MAX_UNSETTLED_JOBS, "delegated-job admission capacity reached; settle or dismiss existing work");
            ensure!(!inner.jobs.values().any(|existing| existing.agent_id == job.agent_id && existing.source == JobSource::Runtime && !is_terminal(existing)), "conversation already has an unresolved runtime job");
            if let Some(previous_id) = &job.previous_job_id {
                let previous = inner.job(previous_id)?;
                ensure!(!require_unstopped || (matches!(previous.stop, StopState::NotRequested) && !matches!(&previous.execution, ExecutionState::Terminal { terminal } if matches!(terminal.outcome, JobOutcome::Stopped { .. }))), "automatic message continuation cannot clear Stop; use explicit Continue to restart deliberately");
                ensure!(previous.agent_id == job.agent_id && ((previous.source == JobSource::Imported && !matches!(&previous.execution, ExecutionState::Terminal { terminal } if terminal.cleanup == CleanupState::Pending)) || matches!(&previous.execution, ExecutionState::Terminal { terminal } if terminal.cleanup == CleanupState::Complete)), "Continue waits until the previous terminal result is acknowledged by its provider");
                ensure!(inner.agent_view(&job.agent_id)?.latest_job_id.as_ref() == Some(previous_id), "Continue was based on a superseded job");
                ensure!(job.admission_origin.is_none(), "Continue cannot replace original ancestry");
            } else {
                ensure!(job.admission_origin.is_some(), "initial admission requires immutable ancestry");
                ensure!(!inner.agents.contains_key(&job.agent_id), "agent identity already exists");
            }
            inner.reclaim(job.created_at_ms.context("runtime admission requires creation time")?, RUNTIME_RESERVATION)?;
            ensure!(inner.accounted_bytes()? + RUNTIME_RESERVATION + MUTATION_RESERVE <= MAX_STORE_BYTES, "delegated-job storage is pinned at its cap; settle pending work before admitting more");
            inner.write_job(&job)?;
            inner.jobs.insert(job.job_id.clone(), job.clone());
            inner.ensure_agent(&job)?;
            Ok((job, false))
        }).await
    }

    pub(crate) async fn bind(
        &self,
        id: JobId,
        revision: u64,
        conversation: ConversationIdentity,
        at_ms: i64,
    ) -> Result<JobRecord> {
        self.access(move |inner| {
            let mut job = inner.current(&id, revision)?;
            ensure!(matches!(job.execution, ExecutionState::Admitted), "only an admitted job can acquire a provider conversation");
            ensure!(matches!(conversation.provider_home, ProviderHome::Known { .. }), "new execution needs an exact provider home");
            ensure!(!conversation.thread_id.is_empty(), "provider thread identity is empty");
            ensure!(!inner.agents.values().any(|other| other.agent_id != job.agent_id && matches!(&other.conversation, ConversationBinding::Known { conversation: existing } if existing == &conversation)), "provider conversation already belongs to another delegated agent");
            let mut agent = inner.agent_view(&job.agent_id)?;
            match &agent.conversation {
                ConversationBinding::Known { conversation: existing } => ensure!(*existing == conversation, "Continue cannot switch provider conversation"),
                ConversationBinding::Unknown { .. } => agent.conversation = ConversationBinding::Known { conversation: conversation.clone() },
            }
            inner.write_agent(&agent)?;
            inner.agents.insert(agent.agent_id.clone(), agent);
            job.execution = ExecutionState::Bound { conversation };
            inner.commit(job, at_ms)
        }).await
    }

    pub(crate) async fn advance(
        &self,
        id: JobId,
        revision: u64,
        execution: ExecutionState,
        at_ms: i64,
    ) -> Result<JobRecord> {
        let _execution = self.executions.mutation(&id).await?;
        self.access(move |inner| {
            let _execution = _execution;
            let mut job = inner.current(&id, revision)?;
            validate_transition(&job, &execution)?;
            if let ExecutionState::RetryWaiting { retry_at_ms, .. } = &job.execution
                && matches!(execution, ExecutionState::Dispatching { .. })
            {
                ensure!(at_ms >= *retry_at_ms, "provider retry is not due");
            }
            job.execution = execution;
            inner.commit(job, at_ms)
        })
        .await
    }

    pub(crate) async fn schedule_provider_retry(
        &self,
        id: JobId,
        revision: u64,
        binding: ExecutionBinding,
        reason: String,
        retry_at_ms: i64,
        at_ms: i64,
    ) -> Result<JobRecord> {
        let _execution = self.executions.mutation(&id).await?;
        self.access(move |inner| {
            let _execution = _execution;
            let mut job = inner.current(&id, revision)?;
            ensure!(
                job.provider_retries.len() < super::retry::MAX_PROVIDER_RETRIES,
                "provider retry budget exhausted"
            );
            ensure!(
                job.execution.conversation() == Some(&binding.conversation),
                "retry changed the exact failed conversation"
            );
            let next = ExecutionState::RetryWaiting {
                binding: binding.clone(),
                retry_at_ms,
            };
            validate_transition(&job, &next)?;
            job.provider_retries.push(ProviderRetry {
                binding,
                outcome: JobOutcome::Failed { reason },
            });
            job.execution = next;
            inner.commit(job, at_ms)
        })
        .await
    }

    pub(crate) async fn request_stop(
        &self,
        id: JobId,
        mutation_id: String,
        at_ms: i64,
    ) -> Result<JobRecord> {
        self.access(move |inner| {
            ensure!(
                !mutation_id.is_empty() && mutation_id.len() <= 200,
                "invalid Stop mutation identity"
            );
            let mut job = inner.job(&id)?.clone();
            if is_terminal(&job) || matches!(job.stop, StopState::Requested { .. }) {
                return Ok(job);
            }
            job.stop = StopState::Requested { mutation_id, at_ms };
            inner.commit(job, at_ms)
        })
        .await
    }

    pub(crate) async fn record_uncertainty(
        &self,
        id: JobId,
        revision: u64,
        reason: String,
        notice: Option<String>,
        at_ms: i64,
    ) -> Result<JobRecord> {
        let _execution = self.executions.mutation(&id).await?;
        self.access(move |inner| {
            let _execution = _execution;
            let mut job = inner.current(&id, revision)?;
            let next = ExecutionState::Unknown { conversation: job.execution.conversation().cloned(), binding: job.execution.binding().cloned(), reason };
            validate_transition(&job, &next)?;
            job.execution = next;
            let delivery_id = format!("{}:notice:observation", id.as_str());
            if let Some(text) = notice
                && !job.notices.iter().any(|notice| matches!(&notice.payload, CompletionPayload::Prepared { delivery_id: existing, .. } if existing == &delivery_id)) {
                    job.notices.push(JobNotice { at_ms: Some(at_ms), payload: CompletionPayload::Prepared { delivery_id, fingerprint: fingerprint(text.as_bytes()), text }, delivery: DeliveryState::Pending });
            }
            inner.commit(job, at_ms)
        }).await
    }

    pub(crate) async fn complete_cleanup(
        &self,
        id: JobId,
        revision: u64,
        at_ms: i64,
    ) -> Result<JobRecord> {
        self.access(move |inner| {
            let mut job = inner.current(&id, revision)?;
            let ExecutionState::Terminal { terminal } = &mut job.execution else {
                bail!("provider cleanup requires a durable terminal outcome");
            };
            terminal.cleanup = CleanupState::Complete;
            inner.commit(job, at_ms)
        })
        .await
    }

    pub(crate) async fn notice_delivery(
        &self,
        id: JobId,
        revision: u64,
        delivery_id: String,
        next: DeliveryState,
        at_ms: i64,
    ) -> Result<JobRecord> {
        self.access(move |inner| {
            let mut job = inner.current(&id, revision)?;
            let notice = job.notices.iter_mut().find(|notice| matches!(&notice.payload, CompletionPayload::Prepared { delivery_id: existing, .. } if existing == &delivery_id)).context("job notice is missing")?;
            ensure!(!delivery_settled(&notice.delivery) || notice.delivery == next || matches!((&notice.delivery, &next), (DeliveryState::Accepted { .. }, DeliveryState::Recorded { .. })), "settled notice cannot be resent or changed");
            notice.delivery = next;
            inner.commit(job, at_ms)
        }).await
    }

    pub(crate) async fn dismiss_obligations(
        &self,
        id: JobId,
        reason: String,
        at_ms: i64,
    ) -> Result<JobRecord> {
        self.access(move |inner| {
            let mut job = inner.job(&id)?.clone();
            if let ExecutionState::Terminal { terminal } = &mut job.execution
                && let Completion::Required { delivery, .. } = &mut terminal.completion
                && !delivery_settled(delivery)
            {
                *delivery = DeliveryState::Dismissed {
                    reason: reason.clone(),
                };
            }
            for notice in &mut job.notices {
                if !delivery_settled(&notice.delivery) {
                    notice.delivery = DeliveryState::Dismissed {
                        reason: reason.clone(),
                    };
                }
            }
            inner.commit(job, at_ms)
        })
        .await
    }

    pub(crate) async fn delivery(
        &self,
        id: JobId,
        revision: u64,
        next: DeliveryState,
        at_ms: i64,
    ) -> Result<JobRecord> {
        self.access(move |inner| {
            let mut job = inner.current(&id, revision)?;
            let ExecutionState::Terminal { terminal } = &mut job.execution else {
                bail!("completion delivery requires a terminal job")
            };
            let Completion::Required { delivery, .. } = &mut terminal.completion else {
                bail!("job has no completion recipient")
            };
            ensure!(
                !delivery_settled(delivery)
                    || *delivery == next
                    || matches!(
                        (&*delivery, &next),
                        (
                            DeliveryState::Accepted { .. },
                            DeliveryState::Recorded { .. }
                        )
                    ),
                "settled completion cannot be changed or resent"
            );
            *delivery = next;
            inner.commit(job, at_ms)
        })
        .await
    }
}

impl Inner {
    fn existing_request(&self, id: &JobId, fingerprint: &str) -> Result<Option<JobRecord>> {
        self.jobs
            .get(id)
            .map(|previous| {
                if previous.request_fingerprint.as_deref() != Some(fingerprint) {
                    return Err(crate::rpc::RpcError::new(
                        crate::rpc::error::RpcCode::Conflict,
                        "jobId was already used for a different or unverifiable request",
                    )
                    .with_data(crate::rpc::error::RpcData::Raw(
                        serde_json::json!({"class":"conflict"}),
                    ))
                    .into());
                }
                Ok(previous.clone())
            })
            .transpose()
    }
    fn summary(&self, job: &JobRecord) -> Result<JobSummary> {
        let (cwd, title, settings) = match &job.spec {
            SpecEvidence::Known { spec } => (
                Some(spec.cwd.clone()),
                spec.title.clone(),
                Some(&spec.settings),
            ),
            SpecEvidence::Expired {
                cwd,
                settings,
                title,
                ..
            } => (Some(cwd.clone()), title.clone(), Some(settings)),
            SpecEvidence::Unknown { .. } => (None, None, None),
        };
        let provider = if job.job_id.as_str().starts_with("agent-codex-") {
            Provider::Codex
        } else {
            Provider::Claude
        };
        let model = settings.map(|settings| match settings {
            ExecutionSettings::Codex { model, .. } | ExecutionSettings::Claude { model, .. } => {
                model.clone()
            }
        });
        let conversation = self
            .agents
            .get(&job.agent_id)
            .map(|agent| agent.conversation.clone())
            .unwrap_or_else(|| ConversationBinding::Unknown {
                reason: "historical provider conversation is unresolved".into(),
            });
        let state = match &job.execution {
            ExecutionState::Admitted
            | ExecutionState::Bound { .. }
            | ExecutionState::RetryWaiting { .. } => crate::agents::State::Waiting,
            ExecutionState::Running { .. } | ExecutionState::Recovering { .. } => {
                crate::agents::State::Working
            }
            ExecutionState::Dispatching { .. } | ExecutionState::Unknown { .. } => {
                crate::agents::State::Unknown
            }
            ExecutionState::Terminal { terminal } => match terminal.outcome {
                JobOutcome::Completed => crate::agents::State::Completed,
                JobOutcome::Failed { .. } => crate::agents::State::Failed,
                JobOutcome::Stopped { .. } => crate::agents::State::Interrupted,
            },
        };
        Ok(JobSummary {
            owner_host_id: None,
            parent: self
                .agents
                .get(&job.agent_id)
                .and_then(|agent| agent.parent.clone()),
            recipient: Some(job.recipient.clone()),
            job_id: job.job_id.clone(),
            agent_id: job.agent_id.clone(),
            conversation,
            provider,
            cwd,
            title,
            model,
            state,
            active: job.source == JobSource::Runtime && !is_terminal(job),
            created_at_ms: job.created_at_ms,
            updated_at_ms: job.updated_at_ms,
        })
    }

    fn job_path(&self, id: &JobId) -> PathBuf {
        self.root.join("jobs").join(format!("{}.json", id.as_str()))
    }
    fn agent_path(&self, id: &str) -> PathBuf {
        self.root
            .join("agents")
            .join(format!("{}.json", fingerprint(id.as_bytes())))
    }
    fn job(&self, id: &JobId) -> Result<&JobRecord> {
        self.jobs.get(id).context("delegated job does not exist")
    }

    fn current(&self, id: &JobId, revision: u64) -> Result<JobRecord> {
        let job = self.job(id)?;
        ensure!(
            job.revision == revision,
            "job changed while provider evidence was being read"
        );
        Ok(job.clone())
    }

    fn agent_view(&self, id: &str) -> Result<AgentRecord> {
        let mut agent = self
            .agents
            .get(id)
            .context("delegated agent does not exist")?
            .clone();
        let mut active = self.jobs.values().filter(|job| {
            job.agent_id == id
                && job.source == JobSource::Runtime
                && matches!(
                    job.execution,
                    ExecutionState::Admitted
                        | ExecutionState::Bound { .. }
                        | ExecutionState::Dispatching { .. }
                        | ExecutionState::Running { .. }
                        | ExecutionState::Recovering { .. }
                )
        });
        if let Some(job) = active.next() {
            ensure!(
                active.next().is_none(),
                "conversation has conflicting active runtime jobs"
            );
            agent.latest_job_id = Some(job.job_id.clone());
            return Ok(agent);
        }
        let Some(mut latest) = agent
            .latest_job_id
            .as_ref()
            .or(agent.origin_job_id.as_ref())
        else {
            return Ok(agent);
        };
        for _ in 0..=self.jobs.len() {
            ensure!(
                self.job(latest)?.agent_id == id,
                "continuation belongs to another agent"
            );
            let mut successors = self
                .jobs
                .values()
                .filter(|job| job.agent_id == id && job.previous_job_id.as_ref() == Some(latest));
            let Some(next) = successors.next() else {
                agent.latest_job_id = Some(latest.clone());
                return Ok(agent);
            };
            if successors.next().is_some() {
                agent.latest_job_id = None;
                return Ok(agent);
            }
            latest = &next.job_id;
        }
        bail!("conversation continuation chain contains a cycle")
    }

    fn ensure_agent(&mut self, job: &JobRecord) -> Result<()> {
        if self.agents.contains_key(&job.agent_id) {
            return Ok(());
        }
        let Some(origin) = job.admission_origin.clone() else {
            ensure!(
                job.source == JobSource::Imported,
                "job has no canonical ancestry record"
            );
            return Ok(());
        };
        let SpecEvidence::Known { spec } = &job.spec else {
            ensure!(
                job.source == JobSource::Imported,
                "new agent has no execution policy"
            );
            return Ok(());
        };
        let agent = AgentRecord {
            parent: job.initial_parent.clone(),
            parent_revision: job.parent_revision,
            parent_recipient: Some(job.recipient.clone()),
            agent_id: job.agent_id.clone(),
            conversation: ConversationBinding::Unknown {
                reason: "provider conversation is not yet bound".into(),
            },
            origin,
            tool_scope: Some(spec.tool_scope.clone()),
            origin_job_id: Some(job.job_id.clone()),
            latest_job_id: Some(job.job_id.clone()),
        };
        self.write_agent(&agent)?;
        self.agents.insert(agent.agent_id.clone(), agent);
        Ok(())
    }

    fn recover_agents(&mut self) -> Result<()> {
        let initial: Vec<_> = self
            .jobs
            .values()
            .filter(|job| job.source == JobSource::Runtime && job.previous_job_id.is_none())
            .cloned()
            .collect();
        for job in initial {
            self.ensure_agent(&job)?;
        }
        Ok(())
    }

    fn validate_slots(&self) -> Result<()> {
        let mut active = BTreeMap::new();
        for job in self
            .jobs
            .values()
            .filter(|job| job.source == JobSource::Runtime && !is_terminal(job))
        {
            ensure!(
                active.insert(&job.agent_id, &job.job_id).is_none(),
                "multiple unresolved jobs own one conversation"
            );
        }
        Ok(())
    }

    fn write_job(&self, job: &JobRecord) -> Result<()> {
        validate_job(job)?;
        let bytes = serde_json::to_vec(job)?;
        ensure!(
            bytes.len() as u64 <= MAX_JOB_BYTES,
            "job exceeds its reserved 1 MiB record budget"
        );
        private_state::replace(&self.job_path(&job.job_id), &bytes)
    }

    fn index_parent(&mut self, agent: &AgentRecord) {
        if let ConversationBinding::Known { conversation } = &agent.conversation {
            if agent.parent_recipient.is_some() {
                self.parents
                    .insert(conversation.clone(), agent.parent.clone());
            } else {
                self.parents.remove(conversation);
            }
        }
    }

    fn write_agent(&mut self, agent: &AgentRecord) -> Result<()> {
        let bytes = serde_json::to_vec(agent)?;
        ensure!(
            bytes.len() as u64 <= MAX_AGENT_BYTES,
            "agent origin exceeds its record budget"
        );
        private_state::replace(&self.agent_path(&agent.agent_id), &bytes)?;
        self.index_parent(agent);
        Ok(())
    }

    fn commit(&mut self, mut job: JobRecord, at_ms: i64) -> Result<JobRecord> {
        job.revision = job
            .revision
            .checked_add(1)
            .context("job revision exhausted")?;
        job.updated_at_ms = at_ms;
        if job.source == JobSource::Imported {
            let current = std::fs::metadata(self.job_path(&job.job_id))?.len();
            let growth = (serde_json::to_vec(&job)?.len() as u64).saturating_sub(current);
            ensure!(
                growth == 0 || tree_bytes(&self.root)? + growth <= MAX_STORE_BYTES,
                "imported job mutation exceeds the store budget; reclaim settled payloads first"
            );
        }
        self.write_job(&job)?;
        self.jobs.insert(job.job_id.clone(), job.clone());
        Ok(job)
    }

    fn accounted_bytes(&self) -> Result<u64> {
        let mut accounted = tree_bytes(&self.root)?;
        for job in self.jobs.values().filter(|job| live_reservation(job)) {
            let job_bytes = std::fs::metadata(self.job_path(&job.job_id))?.len();
            let evidence = self.root.join("evidence").join(job.job_id.as_str());
            let evidence_bytes = if evidence.is_dir() {
                tree_bytes(&evidence)?
            } else {
                0
            };
            let owned = job_bytes + evidence_bytes;
            accounted += RUNTIME_RESERVATION.saturating_sub(owned);
        }
        accounted += self.message_reservations()?;
        Ok(accounted)
    }

    fn reclaim(&mut self, now: i64, incoming: u64) -> Result<()> {
        self.reclaim_messages(now)?;
        let mut candidates: Vec<_> = self
            .jobs
            .values()
            .filter(|job| settled(job) && has_reclaimable_payload(job))
            .map(|job| (job.updated_at_ms, job.job_id.clone()))
            .collect();
        candidates.sort();
        let mut accounted = self.accounted_bytes()?;
        for (at, id) in candidates {
            if now.saturating_sub(at) < RETENTION_MS
                && accounted + incoming + MUTATION_RESERVE <= MAX_STORE_BYTES
            {
                break;
            }
            let before = std::fs::metadata(self.job_path(&id))?.len();
            let mut job = self.job(&id)?.clone();
            if let SpecEvidence::Known { spec } = job.spec {
                job.spec = SpecEvidence::Expired {
                    cwd: spec.cwd,
                    settings: spec.settings,
                    tool_scope: spec.tool_scope,
                    title: spec.title,
                };
            }
            if let ExecutionState::Terminal { terminal } = &mut job.execution {
                if matches!(terminal.result, ResultEvidence::Available { .. }) {
                    terminal.result = ResultEvidence::Expired;
                }
                if let Completion::Required { payload, .. } = &mut terminal.completion {
                    expire_payload(payload);
                }
            }
            job.unconfirmed_result = None;
            for notice in &mut job.notices {
                expire_payload(&mut notice.payload);
            }
            self.commit(job, at)?;
            let after = std::fs::metadata(self.job_path(&id))?.len();
            accounted = (accounted + after).saturating_sub(before);
        }
        Ok(())
    }
}

fn has_reclaimable_payload(job: &JobRecord) -> bool {
    let prepared =
        |payload: &CompletionPayload| matches!(payload, CompletionPayload::Prepared { .. });
    matches!(job.spec, SpecEvidence::Known { .. })
        || job.unconfirmed_result.is_some()
        || job.notices.iter().any(|notice| prepared(&notice.payload))
        || matches!(&job.execution, ExecutionState::Terminal { terminal }
            if matches!(terminal.result, ResultEvidence::Available { .. })
                || matches!(&terminal.completion, Completion::Required { payload, .. } if prepared(payload)))
}

fn expire_payload(payload: &mut CompletionPayload) {
    if let CompletionPayload::Prepared {
        delivery_id,
        fingerprint,
        ..
    } = payload
    {
        *payload = CompletionPayload::Expired {
            delivery_id: delivery_id.clone(),
            fingerprint: fingerprint.clone(),
        };
    }
}

pub(crate) fn fingerprint(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn read<T: DeserializeOwned>(path: &Path, maximum: u64) -> Result<T> {
    let bytes = private_state::read_bounded(path, maximum)
        .map_err(|error| match error {
            ReadError::Io(error) => anyhow::Error::from(error),
            other => anyhow::anyhow!("invalid delegated-job file: {other:?}"),
        })?
        .context("delegated-job file disappeared while its owner held the lease")?;
    serde_json::from_slice(&bytes)
        .with_context(|| format!("invalid delegated-job record {}; preserved", path.display()))
}

fn tree_bytes(path: &Path) -> Result<u64> {
    let mut total = 0u64;
    for entry in std::fs::read_dir(path)? {
        let entry = entry?;
        let metadata = entry.metadata()?;
        ensure!(
            !entry.file_type()?.is_symlink(),
            "delegated-job store must not contain symlinks"
        );
        if metadata.is_dir() {
            total = total
                .checked_add(tree_bytes(&entry.path())?)
                .context("store byte count overflow")?;
        } else if metadata.is_file() {
            total = total
                .checked_add(metadata.len())
                .context("store byte count overflow")?;
        }
    }
    Ok(total)
}

fn is_terminal(job: &JobRecord) -> bool {
    matches!(job.execution, ExecutionState::Terminal { .. })
}
fn delivery_settled(delivery: &DeliveryState) -> bool {
    matches!(
        delivery,
        DeliveryState::Accepted { .. }
            | DeliveryState::Recorded { .. }
            | DeliveryState::Dismissed { .. }
    )
}
fn settled(job: &JobRecord) -> bool {
    job.notices
        .iter()
        .all(|notice| delivery_settled(&notice.delivery))
        && matches!(&job.execution, ExecutionState::Terminal { terminal } if terminal.cleanup == CleanupState::Complete && match &terminal.completion {
            Completion::NotRequired => true,
            Completion::Required { delivery, .. } => delivery_settled(delivery),
        })
}
fn live_reservation(job: &JobRecord) -> bool {
    job.source == JobSource::Runtime && !settled(job)
}

fn validate_job(job: &JobRecord) -> Result<()> {
    ensure!(
        job.provider_retries.len() <= super::retry::MAX_PROVIDER_RETRIES,
        "provider retry budget exceeded"
    );
    for retry in &job.provider_retries {
        ensure!(
            matches!(retry.outcome, JobOutcome::Failed { .. }),
            "provider retry predecessor must have failed"
        );
        ensure!(
            job.execution
                .conversation()
                .is_none_or(|conversation| conversation == &retry.binding.conversation),
            "provider retry changed its conversation"
        );
    }
    if let ExecutionState::RetryWaiting { binding, .. } = &job.execution {
        ensure!(
            job.provider_retries
                .last()
                .is_some_and(|retry| &retry.binding == binding),
            "provider retry waiting lost its predecessor"
        );
    }
    if let ExecutionState::Unknown {
        conversation,
        binding: Some(binding),
        ..
    } = &job.execution
    {
        ensure!(
            conversation.as_ref() == Some(&binding.conversation),
            "unknown execution changed its proven conversation binding"
        );
    }
    ensure!(
        job.source == JobSource::Imported || job.created_at_ms.is_some(),
        "runtime job requires its creation time"
    );
    if let Some(result) = &job.unconfirmed_result {
        ensure!(
            serde_json::to_vec(result)?.len() <= MAX_RESULT_BYTES,
            "encoded unconfirmed result exceeds 256 KiB"
        );
    }
    let mut notice_ids = std::collections::HashSet::new();
    for notice in &job.notices {
        if let CompletionPayload::Prepared {
            delivery_id,
            fingerprint: expected,
            text,
        } = &notice.payload
        {
            ensure!(
                delivery_id.starts_with(&format!("{}:notice:", job.job_id.as_str()))
                    && notice_ids.insert(delivery_id),
                "runtime notice identity is invalid or duplicated"
            );
            ensure!(
                *expected == fingerprint(text.as_bytes()),
                "notice fingerprint differs from its immutable payload"
            );
        }
    }
    ensure!(
        !job.agent_id.is_empty() && job.agent_id.len() <= 200,
        "invalid agent identity"
    );
    if let SpecEvidence::Known { spec } = &job.spec {
        ensure!(
            !spec.prompt.trim().is_empty() && spec.prompt.len() <= MAX_PROMPT_BYTES,
            "job prompt must contain text and fit within 512 KiB"
        );
        ensure!(spec.cwd.is_absolute(), "job cwd must be absolute");
        if let ToolScope::ReadOnly { root } = &spec.tool_scope {
            ensure!(
                root.is_absolute(),
                "read-only scope requires an absolute root"
            );
        }
        match &spec.settings {
            ExecutionSettings::Codex {
                model,
                model_provider,
                effort,
                ..
            } => {
                ensure!(
                    !model.is_empty() && !model_provider.is_empty() && !effort.is_empty(),
                    "Codex model, provider and effort are required"
                );
                ensure!(
                    model_provider != "claude",
                    "Claude execution must use the Claude provider contract"
                );
            }
            ExecutionSettings::Claude { model, .. } => {
                ensure!(!model.is_empty(), "Claude model is required")
            }
        }
        ensure!(
            job.job_id
                .as_str()
                .starts_with(&format!("agent-{}-", spec.settings.provider().as_str())),
            "job identity provider differs from its settings"
        );
    }
    if job.source == JobSource::Runtime {
        if let ExecutionState::Dispatching { input_id, .. } = &job.execution {
            ensure!(
                *input_id == job.current_input_id(),
                "dispatch input differs from the job's immutable current input identity"
            );
        }
        if let ExecutionState::Terminal { terminal } = &job.execution {
            ensure!(
                terminal.at_ms.is_some(),
                "runtime terminal outcome requires its observation time"
            );
        }
    }
    if let ExecutionState::Terminal { terminal } = &job.execution {
        if let ResultEvidence::Available { result } = &terminal.result {
            ensure!(
                serde_json::to_vec(result)?.len() <= MAX_RESULT_BYTES,
                "encoded job result exceeds 256 KiB"
            );
        }
        if let Completion::Required {
            payload:
                CompletionPayload::Prepared {
                    delivery_id,
                    fingerprint: expected,
                    text,
                },
            ..
        } = &terminal.completion
        {
            ensure!(
                delivery_id == &format!("{}:completion", job.job_id.as_str()),
                "final completion identity must be stable"
            );
            ensure!(
                *expected == fingerprint(text.as_bytes()),
                "completion fingerprint differs from immutable payload"
            );
        }
    }
    Ok(())
}

fn validate_transition(job: &JobRecord, next: &ExecutionState) -> Result<()> {
    ensure!(
        !is_terminal(job),
        "terminal outcome and result are immutable"
    );
    if let (Some(before), Some(after)) = (job.execution.conversation(), next.conversation()) {
        ensure!(
            before == after,
            "job execution cannot switch its exact provider conversation"
        );
    }
    if matches!(job.stop, StopState::Requested { .. }) {
        ensure!(
            matches!(next, ExecutionState::Terminal { terminal } if matches!(terminal.outcome, JobOutcome::Stopped { .. })),
            "Stop must settle before any further dispatch or recovery"
        );
        return Ok(());
    }
    let valid = matches!(
        (&job.execution, next),
        (
            ExecutionState::Bound { .. },
            ExecutionState::Dispatching { .. }
        ) | (
            ExecutionState::Dispatching { .. },
            ExecutionState::Running { .. }
        ) | (
            ExecutionState::Dispatching { .. },
            ExecutionState::Unknown { .. }
        ) | (
            ExecutionState::Running { .. },
            ExecutionState::Recovering { .. }
        ) | (
            ExecutionState::Running { .. },
            ExecutionState::Unknown { .. }
        ) | (
            ExecutionState::Recovering { .. },
            ExecutionState::Running { .. }
        ) | (
            ExecutionState::Recovering { .. },
            ExecutionState::Unknown { .. }
        ) | (
            ExecutionState::Unknown { .. },
            ExecutionState::Running { .. }
        ) | (
            ExecutionState::Unknown { .. },
            ExecutionState::Recovering { .. }
        ) | (
            ExecutionState::Unknown { .. },
            ExecutionState::Unknown { .. }
        ) | (
            ExecutionState::Running { .. },
            ExecutionState::Running { .. }
        ) | (
            ExecutionState::Recovering { .. },
            ExecutionState::Recovering { .. }
        ) | (
            ExecutionState::Running { .. }
                | ExecutionState::Recovering { .. }
                | ExecutionState::Unknown { .. },
            ExecutionState::RetryWaiting { .. }
        ) | (
            ExecutionState::RetryWaiting { .. },
            ExecutionState::Dispatching { .. }
        ) | (_, ExecutionState::Terminal { .. })
    );
    ensure!(valid, "invalid delegated-job execution transition");
    Ok(())
}
