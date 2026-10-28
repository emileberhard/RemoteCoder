use std::collections::{HashMap, HashSet};

use anyhow::{Context, Result, bail, ensure};
use futures_util::{StreamExt, stream};
use serde_json::{Value, json};

use super::{ActionParams, AgentService};
use crate::agents::jobs::model::{
    ConversationBinding, ConversationIdentity, ExecutionState, JobId, JobOutcome, Origin, Provider,
    ResultEvidence, SpecEvidence,
};
use crate::agents::{Agent, Capabilities, Output, State};
use crate::wire::agent_jobs::{
    Caller, ContinueParams, ContinueRecipient, JobView, MessageParams, MessageTarget, StopParams,
};

pub(in crate::gateway) enum ThreadRelation {
    Root,
    Child(Option<ConversationIdentity>),
}

impl AgentService<'_> {
    pub(super) async fn classify_runtime(&self, ids: Vec<String>) -> Result<Value> {
        let mut unique = ids;
        unique.sort();
        unique.dedup();
        for id in &unique {
            crate::questions::validate_id(id)?;
        }
        let rows = stream::iter(unique).map(|id| async move {
            let result = async {
                let parent = self.parent_for_thread(&id).await?;
                let Some(parent) = parent else { return Ok(None); };
                let identity = self.gateway.agent_conversation(&id)?;
                let agent_id = match self.gateway.jobs.agent_for_conversation(&identity).await? {
                    Some(agent) => format!("job:{}", agent.agent_id),
                    None if identity.provider == Provider::Codex => format!("codex:{id}"),
                    None => bail!("Child has no authoritative agent identity"),
                };
                Ok(Some(json!({"parentThreadId":parent.thread_id,"parentAccountId":null,"agentId":agent_id})))
            }.await;
            (id, result)
        }).buffer_unordered(32).collect::<Vec<(String, Result<Option<Value>>)>>().await;
        let mut relations = serde_json::Map::new();
        let mut roots = Vec::new();
        let mut warnings = Vec::new();
        for (id, result) in rows {
            match result {
                Ok(Some(relation)) => {
                    relations.insert(id, relation);
                }
                Ok(None) => roots.push(id),
                Err(error) => warnings.push(format!("{id}: {error:#}")),
            }
        }
        roots.sort();
        warnings.sort();
        Ok(json!({"relations":relations,"knownRoots":roots,"warnings":warnings}))
    }

    pub(in crate::gateway) async fn parent_for_thread(
        &self,
        thread: &str,
    ) -> Result<Option<ConversationIdentity>> {
        match self.thread_relation(thread).await? {
            ThreadRelation::Root => Ok(None),
            ThreadRelation::Child(Some(parent)) => {
                ensure!(
                    self.gateway.agent_conversation(&parent.thread_id)? == parent,
                    "Recorded parent belongs to another provider home"
                );
                Ok(Some(parent))
            }
            ThreadRelation::Child(None) => bail!("Native child has no exact parent identity"),
        }
    }

    pub(in crate::gateway) async fn thread_relation(&self, thread: &str) -> Result<ThreadRelation> {
        let identity = self.gateway.agent_conversation(thread)?;
        let exact = self.gateway.jobs.agent_for_conversation(&identity).await?;
        match exact.map(|agent| agent.origin) {
            Some(Origin::TopLevel) => return Ok(ThreadRelation::Root),
            Some(Origin::Parent { conversation }) => {
                return Ok(ThreadRelation::Child(Some(conversation)));
            }
            Some(Origin::Unknown { reason }) => bail!("Recorded agent origin is unknown: {reason}"),
            None => {}
        }
        if identity.provider == Provider::Claude {
            let uuid = crate::providers::claude::session_uuid_from_thread_id(thread)
                .context("Claude conversation identity is invalid")?;
            let header = self
                .gateway
                .claude_history
                .read_thread_header(uuid.to_owned())
                .await?;
            ensure!(
                header["id"] == thread,
                "Claude history returned another conversation"
            );
            if let Some(origin) = self
                .gateway
                .jobs
                .classify(&identity, created_at_ms(&header))
                .await?
            {
                return origin_relation(origin);
            }
            use crate::providers::claude::conversation_index::SessionOrigin;
            if let Some(runtime) = self.gateway.claude_agent() {
                match runtime.creation_origin(thread)? {
                    Some(SessionOrigin::TopLevel) => return Ok(ThreadRelation::Root),
                    Some(SessionOrigin::Job { .. } | SessionOrigin::Unknown) => {
                        bail!("Claude session has no resolved runtime origin");
                    }
                    None => {}
                }
            }
            return Ok(ThreadRelation::Root);
        }
        let header = self
            .gateway
            .call_control(
                "thread/read",
                json!({"threadId":thread,"includeTurns":false}),
            )
            .await?;
        if let Some(origin) = self
            .gateway
            .jobs
            .classify(&identity, created_at_ms(&header["thread"]))
            .await?
        {
            return origin_relation(origin);
        }
        if super::super::native_agent_relation(&header, thread)? {
            let parent = super::native_parent(&header["thread"])
                .map(|parent| self.gateway.agent_conversation(parent))
                .transpose()?;
            return Ok(ThreadRelation::Child(parent));
        }
        Ok(ThreadRelation::Root)
    }

    pub(super) async fn runtime_agents(
        &self,
        root: &str,
        native: &[Agent],
    ) -> Result<(Vec<Agent>, Vec<String>)> {
        let mut ancestors = vec![root.to_owned()];
        ancestors.extend(native.iter().filter_map(|agent| agent.thread_id.clone()));
        let mut seen_ancestors = HashSet::new();
        ancestors.retain(|ancestor| seen_ancestors.insert(ancestor.clone()));
        let mut warnings = Vec::new();
        if ancestors.len() > 32 {
            ancestors.truncate(32);
            warnings.push("Additional agent subtrees are outside this view's limit".into());
        }
        let mut selected = HashMap::new();
        for ancestor in ancestors {
            let identity = self.gateway.agent_conversation(&ancestor)?;
            let page = self.gateway.jobs.descendants(&identity, 256, None).await?;
            if page.next_cursor.is_some() {
                warnings.push("Runtime agent descendants exceed this view's limit".into());
            }
            for row in page.jobs {
                selected.entry(row.agent_id).or_insert(row.job_id);
            }
        }
        ensure!(
            selected.len() <= 512,
            "Runtime agent descendants exceed the view budget"
        );
        let results = stream::iter(selected)
            .map(|(agent_id, job_id)| async move {
                let result = async {
                    let view = self.gateway.jobs.read(&job_id).await?;
                    let selected = view.agent.as_ref().and_then(|agent| {
                        agent
                            .latest_job_id
                            .as_ref()
                            .or(agent.origin_job_id.as_ref())
                    });
                    if let Some(selected) = selected
                        && selected != &view.job.job_id
                    {
                        return self.gateway.jobs.read(selected).await;
                    }
                    Ok(view)
                }
                .await;
                (agent_id, result)
            })
            .buffer_unordered(32)
            .collect::<Vec<(String, Result<JobView>)>>()
            .await;
        let mut views = Vec::new();
        for (agent_id, result) in results {
            match result {
                Ok(view) => views.push(view),
                Err(error) => warnings.push(format!(
                    "Runtime agent {agent_id} is unavailable: {error:#}"
                )),
            }
        }
        views.sort_by(|left, right| left.job.agent_id.cmp(&right.job.agent_id));
        let mut parents = HashMap::new();
        parents.insert(self.gateway.agent_conversation(root)?, None);
        for agent in native {
            if let Some(thread) = &agent.thread_id {
                parents.insert(
                    self.gateway.agent_conversation(thread)?,
                    Some(agent.id.clone()),
                );
            }
        }
        for view in &views {
            if let Some(agent) = &view.agent
                && let ConversationBinding::Known { conversation } = &agent.conversation
                && self.gateway.agent_conversation(&conversation.thread_id)? == *conversation
            {
                parents.insert(
                    conversation.clone(),
                    Some(format!("job:{}", agent.agent_id)),
                );
            }
        }
        let mut projected = Vec::new();
        let mut seen = HashSet::new();
        for view in views {
            if !seen.insert(view.job.agent_id.clone()) {
                continue;
            }
            let origin = view
                .agent
                .as_ref()
                .map(|agent| &agent.origin)
                .or(view.job.admission_origin.as_ref());
            let Some(Origin::Parent { conversation }) = origin else {
                warnings.push("Runtime agent origin is unresolved".into());
                continue;
            };
            let Some(parent_id) = parents.get(conversation).cloned() else {
                warnings.push("Runtime agent parent is outside this view's verified scope".into());
                continue;
            };
            let thread = match view.agent.as_ref().map(|agent| &agent.conversation) {
                Some(ConversationBinding::Known { conversation })
                    if self.gateway.agent_conversation(&conversation.thread_id)?
                        == *conversation =>
                {
                    Some(conversation.thread_id.clone())
                }
                _ => None,
            };
            let (title, model, settings_known) = match &view.job.spec {
                SpecEvidence::Known { spec } => (
                    spec.title.clone(),
                    Some(settings_model(&spec.settings).to_owned()),
                    true,
                ),
                SpecEvidence::Expired {
                    title, settings, ..
                } => (
                    title.clone(),
                    Some(settings_model(settings).to_owned()),
                    true,
                ),
                SpecEvidence::Unknown { .. } => (None, None, false),
            };
            let execution_known = view
                .agent
                .as_ref()
                .is_none_or(|agent| agent.latest_job_id.is_some());
            let state = if execution_known {
                state(&view.job.execution)
            } else {
                warnings.push(format!("Runtime agent {} has conflicting continuation jobs; current execution is unknown", view.job.agent_id));
                State::Unknown
            };
            let continuation_known = view.agent.as_ref().is_some_and(|agent| {
                agent.latest_job_id.as_ref() == Some(&view.job.job_id) && agent.tool_scope.is_some()
            });
            projected.push(Agent {
                id: format!("job:{}", view.job.agent_id),
                parent_id,
                owner_thread_id: root.to_owned(),
                thread_id: thread.clone(),
                provider: if view.job.job_id.as_str().starts_with("agent-codex-") {
                    "codex"
                } else {
                    "claude"
                }
                .into(),
                source: "runtime".into(),
                title: title.unwrap_or_else(|| "Agent".into()),
                model,
                capabilities: Capabilities {
                    inspect: execution_known,
                    open_conversation: thread.is_some(),
                    message: execution_known && thread.is_some() && state.is_running(),
                    continue_work: thread.is_some()
                        && settings_known
                        && continuation_known
                        && !state.may_be_running(),
                    stop: execution_known && state.may_be_running(),
                    ..Capabilities::default()
                },
                state,
                execution_id: execution_known.then(|| view.job.job_id.as_str().to_owned()),
                last_active_at: execution_known.then_some(view.job.updated_at_ms / 1000),
            });
        }
        Ok((projected, warnings))
    }

    pub(super) async fn read_runtime_agent(&self, node: &Agent) -> Result<Value> {
        let id = JobId::try_from(
            node.execution_id
                .clone()
                .context("Runtime agent has no execution ID")?,
        )
        .map_err(anyhow::Error::msg)?;
        let view = self.gateway.jobs.read(&id).await?;
        let mut output = Output::default();
        if let SpecEvidence::Known { spec } = &view.job.spec {
            output.push("user", &spec.prompt);
        }
        let ExecutionState::Terminal { terminal } = &view.job.execution else {
            bail!("Agent has not completed; open its provider conversation for live output");
        };
        match &terminal.result {
            ResultEvidence::Available { result } => {
                output.push("assistant", &result.text);
                output.truncated |= result.truncated;
            }
            ResultEvidence::Unavailable { reason } => {
                bail!("Agent result is unavailable: {reason}")
            }
            ResultEvidence::Expired => bail!("Agent result has expired under the retention policy"),
        }
        Ok(serde_json::to_value(output)?)
    }

    pub(super) async fn act_on_runtime_agent(
        &self,
        node: &Agent,
        params: ActionParams,
    ) -> Result<Value> {
        let job_id = JobId::try_from(
            node.execution_id
                .clone()
                .context("Runtime agent has no execution ID")?,
        )
        .map_err(anyhow::Error::msg)?;
        let view = self.gateway.jobs.read(&job_id).await?;
        ensure!(
            view.agent
                .as_ref()
                .is_none_or(|agent| agent.latest_job_id.as_ref() == Some(&job_id)),
            "Agent execution changed; refresh before acting"
        );
        let mutation_id = params
            .mutation_id
            .context("Runtime actions require a stable mutation ID")?;
        let (method, request) = match params.action.as_str() {
            "stop" => (
                "agent/jobs/stop",
                serde_json::to_value(StopParams {
                    job_id,
                    mutation_id,
                })?,
            ),
            "message" => (
                "agent/jobs/message",
                serde_json::to_value(MessageParams {
                    target: MessageTarget::Job { job_id },
                    caller: Caller::Operator,
                    delivery_id: mutation_id,
                    text: params.text.context("Message text is required")?,
                })?,
            ),
            "continue" => {
                let agent = view.agent.context("Agent conversation is unresolved")?;
                let ConversationBinding::Known { conversation } = agent.conversation else {
                    bail!("Agent conversation is unresolved");
                };
                (
                    "agent/jobs/continue",
                    serde_json::to_value(ContinueParams {
                        job_id: JobId::for_mutation(conversation.provider, &mutation_id)
                            .map_err(anyhow::Error::msg)?,
                        agent_id: agent.agent_id,
                        prompt: params.text.context("Continuation text is required")?,
                        settings: None,
                        recipient: ContinueRecipient::Previous,
                        caller: Caller::Operator,
                    })?,
                )
            }
            _ => bail!("Unsupported runtime agent action"),
        };
        self.gateway
            .agent_jobs_rpc(method, request)
            .await
            .map_err(|error| anyhow::anyhow!(error.message))
    }
}

fn settings_model(settings: &crate::agents::jobs::model::ExecutionSettings) -> &str {
    match settings {
        crate::agents::jobs::model::ExecutionSettings::Codex { model, .. }
        | crate::agents::jobs::model::ExecutionSettings::Claude { model, .. } => model,
    }
}

fn state(execution: &ExecutionState) -> State {
    match execution {
        ExecutionState::Unknown { .. } => State::Unknown,
        ExecutionState::Terminal { terminal } => match terminal.outcome {
            JobOutcome::Completed => State::Completed,
            JobOutcome::Failed { .. } => State::Failed,
            JobOutcome::Stopped { .. } => State::Interrupted,
        },
        _ => State::Working,
    }
}

fn created_at_ms(header: &Value) -> Option<i64> {
    header
        .get("createdAt")
        .and_then(Value::as_i64)
        .and_then(|seconds| seconds.checked_mul(1000))
}

fn origin_relation(origin: Origin) -> Result<ThreadRelation> {
    match origin {
        Origin::TopLevel => Ok(ThreadRelation::Root),
        Origin::Parent { conversation } => Ok(ThreadRelation::Child(Some(conversation))),
        Origin::Unknown { reason } => bail!("Recorded agent origin is unknown: {reason}"),
    }
}
