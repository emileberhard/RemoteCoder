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

const MAX_AGENT_BYTES: u64 = 16 * 1024;
const MAX_EVIDENCE_BYTES: u64 = 1024 * 1024;
const RUNTIME_RESERVATION: u64 = 2 * (MAX_JOB_BYTES + MAX_EVIDENCE_BYTES + MAX_AGENT_BYTES);
const MUTATION_RESERVE: u64 = 2 * MAX_JOB_BYTES;
const RETENTION_MS: i64 = 30 * 24 * 60 * 60 * 1000;

#[derive(Clone)]
pub(crate) struct JobStore {
    inner: Arc<Mutex<Inner>>,
}

struct Inner {
    root: PathBuf,
    _lease: File,
    jobs: BTreeMap<JobId, JobRecord>,
    agents: BTreeMap<String, AgentRecord>,
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
            ensure!(tree_bytes(&root)? <= MAX_STORE_BYTES, "delegated-job store exceeds its 512 MiB budget; admission remains closed");
            let mut inner = Inner { root, _lease: lease, jobs: BTreeMap::new(), agents: BTreeMap::new() };
            for name in ["jobs", "agents", "evidence"] {
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
                ensure!(inner.agents.insert(agent.agent_id.clone(), agent).is_none(), "duplicate persisted agent identity");
            }
            inner.recover_agents()?;
            inner.validate_slots()?;
            ensure!(inner.accounted_bytes()? + MUTATION_RESERVE <= MAX_STORE_BYTES, "delegated-job state cannot preserve its mutation reservations; admission remains closed");
            Ok(Self { inner: Arc::new(Mutex::new(inner)) })
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

    pub(crate) async fn agent(&self, agent_id: String) -> Result<AgentRecord> {
        self.access(move |inner| inner.agent_view(&agent_id)).await
    }

    pub(crate) async fn snapshot(&self) -> Result<Vec<JobRecord>> {
        self.access(|inner| Ok(inner.jobs.values().cloned().collect()))
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
        self.access(move |inner| {
            validate_job(&job)?;
            ensure!(job.source == JobSource::Runtime && job.revision == 0, "new admission requires an initial runtime job");
            if let Some(previous) = inner.jobs.get(&job.job_id) {
                ensure!(previous.request_fingerprint.is_some() && previous.request_fingerprint == job.request_fingerprint, "jobId was already used for a different or unverifiable request");
                return Ok((previous.clone(), true));
            }
            ensure!(matches!(job.execution, ExecutionState::Admitted), "new admission must start admitted");
            ensure!(serde_json::to_vec(&job)?.len() as u64 <= MAX_JOB_BYTES - MAX_RESULT_BYTES as u64 - 64 * 1024, "encoded job input leaves insufficient room for its terminal result; shorten the prompt or reference a file");
            ensure!(inner.jobs.values().filter(|existing| live_reservation(existing)).count() < MAX_UNSETTLED_JOBS, "delegated-job admission capacity reached; settle or dismiss existing work");
            ensure!(!inner.jobs.values().any(|existing| existing.agent_id == job.agent_id && !is_terminal(existing)), "conversation already has an unresolved job");
            if let Some(previous_id) = &job.previous_job_id {
                let previous = inner.job(previous_id)?;
                ensure!(previous.agent_id == job.agent_id && is_terminal(previous), "Continue must name a terminal job in this conversation");
                ensure!(inner.agent_view(&job.agent_id)?.latest_job_id == *previous_id, "Continue was based on a superseded job");
                ensure!(job.admission_origin.is_none(), "Continue cannot replace original ancestry");
            } else {
                ensure!(job.admission_origin.is_some(), "initial admission requires immutable ancestry");
                ensure!(!inner.agents.contains_key(&job.agent_id), "agent identity already exists");
            }
            inner.reclaim(job.created_at_ms, RUNTIME_RESERVATION)?;
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
        self.access(move |inner| {
            let mut job = inner.current(&id, revision)?;
            validate_transition(&job, &execution)?;
            job.execution = execution;
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
                !delivery_settled(delivery) || *delivery == next,
                "settled completion cannot be changed or resent"
            );
            *delivery = next;
            inner.commit(job, at_ms)
        })
        .await
    }
}

impl Inner {
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
        let mut latest = &agent.origin_job_id;
        for _ in 0..=self.jobs.len() {
            let mut successors = self
                .jobs
                .values()
                .filter(|job| job.agent_id == id && job.previous_job_id.as_ref() == Some(latest));
            let Some(next) = successors.next() else {
                agent.latest_job_id = latest.clone();
                return Ok(agent);
            };
            ensure!(
                successors.next().is_none(),
                "conversation has conflicting continuation jobs"
            );
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
            agent_id: job.agent_id.clone(),
            conversation: ConversationBinding::Unknown {
                reason: "provider conversation is not yet bound".into(),
            },
            origin,
            tool_scope: spec.tool_scope.clone(),
            origin_job_id: job.job_id.clone(),
            latest_job_id: job.job_id.clone(),
        };
        self.write_agent(&agent)?;
        self.agents.insert(agent.agent_id.clone(), agent);
        Ok(())
    }

    fn recover_agents(&mut self) -> Result<()> {
        let initial: Vec<_> = self
            .jobs
            .values()
            .filter(|job| job.previous_job_id.is_none())
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

    fn write_agent(&self, agent: &AgentRecord) -> Result<()> {
        let bytes = serde_json::to_vec(agent)?;
        ensure!(
            bytes.len() as u64 <= MAX_AGENT_BYTES,
            "agent origin exceeds its record budget"
        );
        private_state::replace(&self.agent_path(&agent.agent_id), &bytes)
    }

    fn commit(&mut self, mut job: JobRecord, at_ms: i64) -> Result<JobRecord> {
        job.revision = job
            .revision
            .checked_add(1)
            .context("job revision exhausted")?;
        job.updated_at_ms = at_ms;
        if job.source == JobSource::Imported {
            ensure!(
                tree_bytes(&self.root)? + serde_json::to_vec(&job)?.len() as u64 <= MAX_STORE_BYTES,
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
        Ok(accounted)
    }

    fn reclaim(&mut self, now: i64, incoming: u64) -> Result<()> {
        let mut candidates: Vec<_> = self
            .jobs
            .values()
            .filter(|job| settled(job))
            .map(|job| (job.updated_at_ms, job.job_id.clone()))
            .collect();
        candidates.sort();
        for (at, id) in candidates {
            if now.saturating_sub(at) < RETENTION_MS
                && self.accounted_bytes()? + incoming + MUTATION_RESERVE <= MAX_STORE_BYTES
            {
                break;
            }
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
                terminal.result = ResultEvidence::Expired;
                if let Completion::Required { payload, .. } = &mut terminal.completion {
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
            }
            self.commit(job, at)?;
        }
        Ok(())
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
    matches!(&job.execution, ExecutionState::Terminal { terminal } if match &terminal.completion {
        Completion::NotRequired => true,
        Completion::Required { delivery, .. } => delivery_settled(delivery),
    })
}
fn live_reservation(job: &JobRecord) -> bool {
    job.source == JobSource::Runtime && !settled(job)
}

fn validate_job(job: &JobRecord) -> Result<()> {
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
        ensure!(
            job.job_id
                .as_str()
                .starts_with(&format!("agent-{}-", spec.settings.provider().as_str())),
            "job identity provider differs from its settings"
        );
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
    if let (Some(before), Some(after)) = (
        execution_conversation(&job.execution),
        execution_conversation(next),
    ) {
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
        ) | (_, ExecutionState::Terminal { .. })
    );
    ensure!(valid, "invalid delegated-job execution transition");
    Ok(())
}

fn execution_conversation(execution: &ExecutionState) -> Option<&ConversationIdentity> {
    match execution {
        ExecutionState::Admitted | ExecutionState::Terminal { .. } => None,
        ExecutionState::Bound { conversation }
        | ExecutionState::Dispatching { conversation, .. } => Some(conversation),
        ExecutionState::Running { binding } | ExecutionState::Recovering { binding, .. } => {
            Some(&binding.conversation)
        }
        ExecutionState::Unknown { conversation, .. } => conversation.as_ref(),
    }
}
