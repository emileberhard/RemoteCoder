use super::*;
use std::collections::{BTreeSet, HashMap};

#[derive(Default)]
pub(super) struct Indexes {
    conversations: HashMap<ConversationIdentity, BTreeSet<String>>,
    pub order: BTreeSet<(Option<i64>, JobId)>,
    pub by_agent: HashMap<String, BTreeSet<(Option<i64>, JobId)>>,
    pub active: HashMap<String, BTreeSet<JobId>>,
    pending_by_agent: HashMap<String, BTreeSet<JobId>>,
    pub successors: HashMap<JobId, BTreeSet<JobId>>,
    heads: HashMap<String, ChainHead>,
    lineage: HashMap<JobId, u64>,
    members: HashMap<String, MemberWork>,
}

struct ChainHead {
    anchor: Option<JobId>,
    generation: u64,
    value: std::result::Result<Option<JobId>, String>,
}

struct MemberWork {
    jobs: BTreeSet<JobId>,
    intents: BTreeSet<JobId>,
    changed: tokio::sync::watch::Sender<u64>,
}

impl Default for MemberWork {
    fn default() -> Self {
        Self {
            jobs: BTreeSet::new(),
            intents: BTreeSet::new(),
            changed: tokio::sync::watch::channel(0).0,
        }
    }
}

impl Indexes {
    pub fn agent(&self, conversation: &ConversationIdentity) -> Result<Option<&String>> {
        let Some(ids) = self.conversations.get(conversation) else {
            return Ok(None);
        };
        ensure!(
            ids.len() == 1,
            "multiple agents claim the same provider conversation"
        );
        Ok(ids.first())
    }

    pub fn remove_agent(&mut self, agent: &AgentRecord) {
        if let ConversationBinding::Known { conversation } = &agent.conversation
            && let Some(ids) = self.conversations.get_mut(conversation)
        {
            ids.remove(&agent.agent_id);
            if ids.is_empty() {
                self.conversations.remove(conversation);
            }
        }
    }

    pub fn insert_agent(&mut self, agent: &AgentRecord) {
        if let ConversationBinding::Known { conversation } = &agent.conversation {
            self.conversations
                .entry(conversation.clone())
                .or_default()
                .insert(agent.agent_id.clone());
        }
    }

    pub fn remove_job(&mut self, job: &JobRecord) {
        self.order.remove(&(job.created_at_ms, job.job_id.clone()));
        if let Some(ids) = self.by_agent.get_mut(&job.agent_id) {
            ids.remove(&(job.created_at_ms, job.job_id.clone()));
            if ids.is_empty() {
                self.by_agent.remove(&job.agent_id);
            }
        }
        if let Some(ids) = self.active.get_mut(&job.agent_id) {
            ids.remove(&job.job_id);
            if ids.is_empty() {
                self.active.remove(&job.agent_id);
            }
        }
        if let Some(previous) = &job.previous_job_id
            && let Some(ids) = self.successors.get_mut(previous)
        {
            ids.remove(&job.job_id);
            if ids.is_empty() {
                self.successors.remove(previous);
            }
        }
        if let Some(ids) = self.pending_by_agent.get_mut(&job.agent_id) {
            ids.remove(&job.job_id);
            if ids.is_empty() {
                self.pending_by_agent.remove(&job.agent_id);
            }
        }
        if let Recipient::Remote { host, .. } = &job.recipient
            && let Some(work) = self.members.get_mut(host)
        {
            work.jobs.remove(&job.job_id);
        }
    }

    pub fn insert_job(&mut self, job: &JobRecord) {
        self.order.insert((job.created_at_ms, job.job_id.clone()));
        self.by_agent
            .entry(job.agent_id.clone())
            .or_default()
            .insert((job.created_at_ms, job.job_id.clone()));
        if job.source == JobSource::Runtime
            && matches!(
                job.execution,
                ExecutionState::Admitted
                    | ExecutionState::WaitingForProvider { .. }
                    | ExecutionState::Bound { .. }
                    | ExecutionState::Dispatching { .. }
                    | ExecutionState::Running { .. }
                    | ExecutionState::Recovering { .. }
            )
        {
            self.active
                .entry(job.agent_id.clone())
                .or_default()
                .insert(job.job_id.clone());
        }
        if let Some(previous) = &job.previous_job_id {
            self.successors
                .entry(previous.clone())
                .or_default()
                .insert(job.job_id.clone());
        }
        if live_reservation(job) {
            self.pending_by_agent
                .entry(job.agent_id.clone())
                .or_default()
                .insert(job.job_id.clone());
        }
        if live_reservation(job)
            && let Recipient::Remote { host, .. } = &job.recipient
        {
            let work = self.members.entry(host.clone()).or_default();
            work.jobs.insert(job.job_id.clone());
        }
    }

    pub fn intent_changed(&mut self, intent: &crate::wire::cluster::RemoteIntent) {
        let work = self.members.entry(intent.host.clone()).or_default();
        if matches!(
            intent.state,
            crate::wire::cluster::IntentState::Pending
                | crate::wire::cluster::IntentState::StopRequested
        ) && !intent.stop_confirmed
        {
            work.intents.insert(intent.request.job_id.clone());
        } else {
            work.intents.remove(&intent.request.job_id);
        }
    }

    fn wake(&mut self, host: &str) {
        self.members
            .entry(host.to_owned())
            .or_default()
            .changed
            .send_modify(|revision| *revision = revision.wrapping_add(1));
    }
}

#[derive(PartialEq, Eq)]
enum DeliveryProgress {
    Pending,
    Terminal,
    Ready,
}

fn delivery_signal(job: &JobRecord) -> Option<(String, usize, DeliveryProgress)> {
    if !live_reservation(job) {
        return None;
    }
    let Recipient::Remote { host, .. } = &job.recipient else {
        return None;
    };
    let phase = match &job.execution {
        ExecutionState::Terminal { terminal } if terminal.cleanup == CleanupState::Complete => {
            DeliveryProgress::Ready
        }
        ExecutionState::Terminal { .. } => DeliveryProgress::Terminal,
        _ => DeliveryProgress::Pending,
    };
    Some((host.clone(), job.notices.len(), phase))
}

impl Inner {
    fn refresh_head(&mut self, agent: &AgentRecord) {
        let anchor = agent
            .latest_job_id
            .as_ref()
            .or(agent.origin_job_id.as_ref())
            .cloned();
        if self
            .indexes
            .heads
            .get(&agent.agent_id)
            .is_some_and(|head| head.anchor == anchor)
        {
            return;
        }
        let generation = self
            .indexes
            .heads
            .get(&agent.agent_id)
            .map_or(0, |head| head.generation)
            .wrapping_add(1);
        let mut latest = anchor.clone();
        let value = (|| -> Result<Option<JobId>> {
            for _ in 0..=self.jobs.len() {
                let Some(id) = &latest else { return Ok(None) };
                ensure!(
                    self.job(id)?.agent_id == agent.agent_id,
                    "continuation belongs to another agent"
                );
                self.indexes.lineage.insert(id.clone(), generation);
                let Some(next) = self.indexes.successors.get(id) else {
                    return Ok(latest);
                };
                if next.len() != 1 {
                    return Ok(None);
                }
                latest = next.first().cloned();
            }
            bail!("conversation continuation chain contains a cycle")
        })()
        .map_err(|error| format!("{error:#}"));
        self.indexes.heads.insert(
            agent.agent_id.clone(),
            ChainHead {
                anchor,
                generation,
                value,
            },
        );
    }

    pub(super) fn insert_agent(&mut self, agent: AgentRecord) -> Option<AgentRecord> {
        let parent_changed = self
            .agents
            .get(&agent.agent_id)
            .is_some_and(|previous| previous.parent_revision != agent.parent_revision);
        if parent_changed {
            let hosts = self
                .indexes
                .pending_by_agent
                .get(&agent.agent_id)
                .into_iter()
                .flatten()
                .filter_map(|id| self.jobs.get(id))
                .filter_map(|job| match &job.recipient {
                    Recipient::Remote { host, .. } => Some(host.clone()),
                    _ => None,
                })
                .collect::<BTreeSet<_>>();
            for host in hosts {
                self.indexes.wake(&host);
            }
        }
        if let Some(previous) = self.agents.get(&agent.agent_id) {
            self.indexes.remove_agent(previous);
            if let ConversationBinding::Known { conversation } = &previous.conversation {
                self.parents.remove(conversation);
            }
        }
        self.indexes.insert_agent(&agent);
        self.index_parent(&agent);
        self.refresh_head(&agent);
        self.agents.insert(agent.agent_id.clone(), agent)
    }

    pub(super) fn insert_job(&mut self, job: JobRecord) -> Option<JobRecord> {
        let new = !self.jobs.contains_key(&job.job_id);
        let previous = self.jobs.get(&job.job_id).and_then(delivery_signal);
        let next = delivery_signal(&job);
        if let Some(previous) = self.jobs.get(&job.job_id) {
            self.indexes.remove_job(previous);
        }
        self.indexes.insert_job(&job);
        if previous != next {
            if let Some((host, ..)) = previous {
                self.indexes.wake(&host);
            }
            if let Some((host, ..)) = next {
                self.indexes.wake(&host);
            }
        }
        let id = job.job_id.clone();
        let agent_id = job.agent_id.clone();
        let previous_id = job.previous_job_id.clone();
        let retained = self.jobs.insert(id.clone(), job);
        if new {
            if let Some(agent) = self.agents.get(&agent_id).cloned() {
                let anchor = agent
                    .latest_job_id
                    .as_ref()
                    .or(agent.origin_job_id.as_ref());
                if anchor == Some(&id) {
                    self.indexes.heads.remove(&agent_id);
                    self.refresh_head(&agent);
                } else if let Some(previous) = previous_id
                    && self
                        .jobs
                        .get(&previous)
                        .is_some_and(|job| job.agent_id == agent_id)
                    && let Some(head) = self.indexes.heads.get_mut(&agent_id)
                    && self.indexes.lineage.get(&previous) == Some(&head.generation)
                {
                    self.indexes.lineage.insert(id.clone(), head.generation);
                    head.value = if head
                        .value
                        .as_ref()
                        .is_ok_and(|value| value.as_ref() == Some(&previous))
                        && self
                            .indexes
                            .successors
                            .get(&previous)
                            .is_some_and(|ids| ids.len() == 1)
                    {
                        Ok(Some(id))
                    } else {
                        Ok(None)
                    };
                }
            }
        }
        retained
    }

    pub(super) fn insert_intent(
        &mut self,
        intent: crate::wire::cluster::RemoteIntent,
    ) -> Option<crate::wire::cluster::RemoteIntent> {
        let changed = self
            .intents
            .get(&intent.request.job_id)
            .is_none_or(|previous| {
                previous.state != intent.state || previous.stop_confirmed != intent.stop_confirmed
            });
        self.indexes.intent_changed(&intent);
        if changed {
            self.indexes.wake(&intent.host);
        }
        self.intents.insert(intent.request.job_id.clone(), intent)
    }
}

impl Indexes {
    pub fn head(&self, agent: &str) -> Result<Option<JobId>> {
        self.heads
            .get(agent)
            .context("agent has no continuation index")?
            .value
            .clone()
            .map_err(anyhow::Error::msg)
    }
}

impl JobStore {
    pub(crate) async fn member_changes(
        &self,
        host: String,
    ) -> Result<tokio::sync::watch::Receiver<u64>> {
        self.access(move |inner| {
            Ok(inner
                .indexes
                .members
                .entry(host)
                .or_default()
                .changed
                .subscribe())
        })
        .await
    }

    pub(crate) async fn member_pending_ids(&self, host: String) -> Result<Vec<JobId>> {
        self.access(move |inner| {
            Ok(inner
                .indexes
                .members
                .get(&host)
                .map(|work| work.jobs.iter().cloned().collect())
                .unwrap_or_default())
        })
        .await
    }

    pub(crate) async fn member_pending_intents(
        &self,
        host: String,
    ) -> Result<Vec<crate::wire::cluster::RemoteIntent>> {
        self.access(move |inner| {
            inner
                .indexes
                .members
                .get(&host)
                .into_iter()
                .flat_map(|work| work.intents.iter())
                .map(|id| {
                    inner
                        .intents
                        .get(id)
                        .cloned()
                        .context("pending intent index has no record")
                })
                .collect()
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversation_index_removes_old_bindings_and_keeps_conflicts_explicit() {
        let conversation = ConversationIdentity {
            provider: Provider::Codex,
            provider_home: ProviderHome::Known {
                path: "/tmp/index-fixture".into(),
            },
            thread_id: "first".into(),
        };
        let mut agent = AgentRecord {
            agent_id: "agent".into(),
            conversation: ConversationBinding::Known {
                conversation: conversation.clone(),
            },
            origin: Origin::TopLevel,
            tool_scope: None,
            origin_job_id: None,
            latest_job_id: None,
            parent: None,
            parent_revision: 0,
            parent_recipient: None,
        };
        let mut index = Indexes::default();
        index.insert_agent(&agent);
        assert_eq!(
            index.agent(&conversation).unwrap().map(String::as_str),
            Some("agent")
        );
        let mut conflicting = agent.clone();
        conflicting.agent_id = "conflicting".into();
        index.insert_agent(&conflicting);
        assert!(index.agent(&conversation).is_err());
        index.remove_agent(&conflicting);
        index.remove_agent(&agent);
        let mut next = conversation.clone();
        next.thread_id = "next".into();
        agent.conversation = ConversationBinding::Known {
            conversation: next.clone(),
        };
        index.insert_agent(&agent);
        assert!(index.agent(&conversation).unwrap().is_none());
        assert_eq!(
            index.agent(&next).unwrap().map(String::as_str),
            Some("agent")
        );
        index.remove_agent(&agent);
        assert!(index.agent(&next).unwrap().is_none());
    }
}
