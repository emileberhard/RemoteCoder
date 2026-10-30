use super::*;

impl Gateway {
    pub(in crate::gateway) async fn cluster_agents_rpc(
        &self,
        method: &str,
        params: Value,
    ) -> RpcResult {
        if method != "conversation/agents/list" {
            if let Some(id) = params["agentId"]
                .as_str()
                .and_then(|id| id.strip_prefix("thread:"))
            {
                if method == "conversation/agents/read" {
                    return self
                        .agent_service()
                        .read_thread_output(id)
                        .await
                        .map_err(RpcError::from);
                }
                let action = {
                    params["action"]
                        .as_str()
                        .ok_or_else(|| cluster_error(ErrorClass::Usage, "action is required"))?
                };
                return self.native_conversation_operation(json!({"threadId":id,"action":action,"input":{"text":params["text"],"deliveryId":params["mutationId"]}}),Caller::Operator).await.map_err(RpcError::from);
            }
            if let Some(id) = params["agentId"]
                .as_str()
                .and_then(|id| id.strip_prefix("job:"))
            {
                let agent = self.jobs.store().await?.agent(id.to_owned()).await?;
                let latest = agent.latest_job_id.ok_or_else(|| {
                    cluster_error(ErrorClass::Refused, "agent's latest job is unresolved")
                })?;
                let view = self.jobs.read(&latest).await?;
                let node = runtime_row(
                    &self.host_identity().await?.host_id,
                    params["threadId"].as_str().unwrap_or_default(),
                    &view,
                );
                if method == "conversation/agents/read" {
                    return self
                        .agent_service()
                        .read_runtime_agent(&node)
                        .await
                        .map_err(RpcError::from);
                }
                if method == "conversation/agents/action" {
                    if params["executionId"].as_str() != Some(latest.as_str()) {
                        return Err(cluster_error(
                            ErrorClass::Refused,
                            "agent execution changed; refresh before acting",
                        ));
                    }
                    let action = serde_json::from_value(params).map_err(anyhow::Error::from)?;
                    return self
                        .agent_service()
                        .act_on_runtime_agent(&node, action)
                        .await
                        .map_err(RpcError::from);
                }
            }
            return self.agent_service().agents_rpc(method, params).await;
        }
        let identity = self.host_identity().await.map_err(RpcError::from)?;
        let parent = if params.get("parent").is_some() {
            AgentAddress {
                host_id: params["parent"]["hostId"]
                    .as_str()
                    .unwrap_or(&identity.host_id)
                    .to_owned(),
                thread_id: params["parent"]["threadId"]
                    .as_str()
                    .ok_or_else(|| cluster_error(ErrorClass::Usage, "parent.threadId is required"))?
                    .to_owned(),
            }
        } else {
            AgentAddress {
                host_id: identity.host_id.clone(),
                thread_id: params["threadId"]
                    .as_str()
                    .ok_or_else(|| cluster_error(ErrorClass::Usage, "threadId is required"))?
                    .to_owned(),
            }
        };
        let mut result = if parent.host_id == identity.host_id {
            self.agent_service()
                .agents_rpc(method, json!({"threadId":parent.thread_id}))
                .await?
        } else {
            json!({"agents":[],"warnings":[]})
        };
        let mut rows: Vec<Agent> =
            serde_json::from_value(result["agents"].clone()).map_err(anyhow::Error::from)?;
        for row in &mut rows {
            row.owner_host_id = identity.host_id.clone();
            if row.parent.is_none() {
                row.parent = Some(parent.clone());
            }
        }
        let store = self.jobs.store().await?;
        let mut warnings = result["warnings"].as_array().cloned().unwrap_or_default();
        let identities = rows
            .iter()
            .filter_map(|row| row.thread_id.as_deref())
            .filter_map(|id| self.agent_conversation(id).ok())
            .collect();
        let tags = store.parent_tags(identities).await?;
        rows.retain(|row| {
            row.thread_id
                .as_deref()
                .and_then(|id| self.agent_conversation(id).ok())
                .and_then(|conversation| tags.get(&conversation))
                .is_none_or(|tag| tag.as_ref() == Some(&parent))
        });
        let mut by_thread: std::collections::HashMap<_, _> = rows
            .iter()
            .enumerate()
            .filter_map(|(index, row)| row.thread_id.clone().map(|id| (id, index)))
            .collect();
        for agent in store.agents_with_parent(parent.clone()).await? {
            let agent = match agent {
                Ok(agent) => agent,
                Err(error) => {
                    warnings.push(json!(format!("{error:#}")));
                    continue;
                }
            };
            let ConversationBinding::Known { conversation } = &agent.conversation else {
                continue;
            };
            let row = match self.project_agent_record(&agent, &parent.thread_id).await {
                Ok(row) => row,
                Err(error) => {
                    warnings.push(json!(format!(
                        "Agent {} is unavailable: {error:#}",
                        agent.agent_id
                    )));
                    continue;
                }
            };
            if let Some(index) = by_thread.get(&conversation.thread_id).copied() {
                rows[index] = row;
            } else {
                by_thread.insert(conversation.thread_id.clone(), rows.len());
                rows.push(row);
            }
        }
        if parent.host_id == identity.host_id {
            for intent in store.parent_intents(parent.clone()).await? {
                rows.push(intent_row(&intent)?);
            }
        }
        rows.sort_by(|left, right| {
            (&left.owner_host_id, &left.job_id, &left.id).cmp(&(
                &right.owner_host_id,
                &right.job_id,
                &right.id,
            ))
        });
        result["agents"] = json!(rows);
        result["warnings"] = json!(warnings);
        result["revision"] = json!(crate::ids::sha256_hex(
            serde_json::to_vec(&result["agents"]).map_err(anyhow::Error::from)?
        ));
        Ok(result)
    }
}

fn job_title(job: &crate::agents::jobs::model::JobRecord) -> Option<&str> {
    match &job.spec {
        crate::agents::jobs::model::SpecEvidence::Known { spec } => spec.title.as_deref(),
        crate::agents::jobs::model::SpecEvidence::Expired { title, .. } => title.as_deref(),
        _ => None,
    }
}
fn job_model(job: &crate::agents::jobs::model::JobRecord) -> Option<&str> {
    let settings = match &job.spec {
        crate::agents::jobs::model::SpecEvidence::Known { spec } => &spec.settings,
        crate::agents::jobs::model::SpecEvidence::Expired { settings, .. } => settings,
        _ => return None,
    };
    Some(match settings {
        crate::agents::jobs::model::ExecutionSettings::Codex { model, .. }
        | crate::agents::jobs::model::ExecutionSettings::Claude { model, .. } => model,
    })
}
fn job_state(job: &crate::agents::jobs::model::JobRecord) -> crate::agents::State {
    match &job.execution {
        ExecutionState::Terminal { terminal } => match terminal.outcome {
            crate::agents::jobs::model::JobOutcome::Completed => crate::agents::State::Completed,
            crate::agents::jobs::model::JobOutcome::Failed { .. } => crate::agents::State::Failed,
            crate::agents::jobs::model::JobOutcome::Stopped { .. } => {
                crate::agents::State::Interrupted
            }
        },
        ExecutionState::Running { .. } | ExecutionState::Recovering { .. } => {
            crate::agents::State::Working
        }
        ExecutionState::Admitted
        | ExecutionState::WaitingForProvider { .. }
        | ExecutionState::Bound { .. }
        | ExecutionState::RetryWaiting { .. } => crate::agents::State::Waiting,
        _ => crate::agents::State::Unknown,
    }
}

fn runtime_row(owner: &str, root: &str, view: &agent_jobs::JobView) -> Agent {
    let thread = view
        .agent
        .as_ref()
        .and_then(|agent| match &agent.conversation {
            ConversationBinding::Known { conversation } => Some(conversation.thread_id.clone()),
            _ => None,
        });
    let known = view
        .agent
        .as_ref()
        .is_some_and(|agent| agent.latest_job_id.as_ref() == Some(&view.job.job_id));
    let state = if known {
        job_state(&view.job)
    } else {
        State::Unknown
    };
    let provider = if view.job.job_id.as_str().starts_with("agent-codex-") {
        "codex"
    } else {
        "claude"
    };
    Agent {
        id: format!("job:{}", view.job.agent_id),
        owner_host_id: owner.into(),
        job_id: Some(view.job.job_id.as_str().into()),
        parent: view.parent.clone(),
        recipient: Some(view.job.recipient.clone()),
        kind: None,
        intent_state: None,
        parent_id: None,
        owner_thread_id: root.into(),
        thread_id: thread.clone(),
        provider: provider.into(),
        source: "runtime".into(),
        title: job_title(&view.job).unwrap_or("Agent").into(),
        model: job_model(&view.job).map(str::to_owned),
        capabilities: Capabilities {
            inspect: known,
            open_conversation: thread.is_some(),
            message: known && thread.is_some(),
            continue_work: known
                && thread.is_some()
                && !state.may_be_running()
                && view
                    .agent
                    .as_ref()
                    .is_some_and(|agent| agent.tool_scope.is_some()),
            stop: known && state.may_be_running(),
            ask_parent: view.parent.is_some(),
        },
        state,
        execution_id: known.then(|| view.job.job_id.as_str().to_owned()),
        last_active_at: Some(view.job.updated_at_ms / 1000),
    }
}

fn intent_row(intent: &RemoteIntent) -> Result<Agent> {
    Ok(Agent {
        id: intent.request.job_id.as_str().into(),
        owner_host_id: intent.host.clone(),
        job_id: Some(intent.request.job_id.as_str().into()),
        parent: intent.parent.clone(),
        recipient: Some(intent.request.recipient.clone()),
        kind: Some(AgentKind::RemoteIntent),
        intent_state: Some(intent.state),
        parent_id: None,
        owner_thread_id: intent
            .parent
            .as_ref()
            .map(|parent| parent.thread_id.clone())
            .unwrap_or_default(),
        thread_id: None,
        provider: match &intent.request.operation {
            AdmissionOperation::Start(spec) => spec.settings.provider().as_str(),
            AdmissionOperation::Continue(request) => {
                if request.job_id.as_str().starts_with("agent-codex-") {
                    "codex"
                } else {
                    "claude"
                }
            }
        }
        .into(),
        source: "remote_intent".into(),
        title: match &intent.request.operation {
            AdmissionOperation::Start(spec) => spec.title.clone().unwrap_or_else(|| "Agent".into()),
            AdmissionOperation::Continue(_) => "Agent".into(),
        },
        model: None,
        state: State::Unknown,
        capabilities: Capabilities::default(),
        execution_id: None,
        last_active_at: Some(
            time::OffsetDateTime::parse(
                &intent.created_at,
                &time::format_description::well_known::Rfc3339,
            )?
            .unix_timestamp(),
        ),
    })
}

impl Gateway {
    pub(super) async fn project_agent_record(
        &self,
        agent: &crate::agents::jobs::model::AgentRecord,
        root: &str,
    ) -> Result<Agent> {
        let identity = self.host_identity().await?;
        if let Some(id) = agent
            .latest_job_id
            .as_ref()
            .or(agent.origin_job_id.as_ref())
        {
            return Ok(runtime_row(
                &identity.host_id,
                root,
                &self.jobs.read(id).await?,
            ));
        }
        let ConversationBinding::Known { conversation } = &agent.conversation else {
            bail!("agent has no exact provider conversation")
        };
        let header = if conversation.provider == crate::agents::jobs::model::Provider::Claude {
            self.claude_thread_response(&json!({"threadId":conversation.thread_id}))
                .await?
        } else {
            self.job_native_call(
                "thread/read",
                json!({"threadId":conversation.thread_id,"includeTurns":false}),
            )
            .await?
        };
        Ok(native_row(
            &identity.host_id,
            root,
            agent,
            &header["thread"],
        ))
    }
}

fn native_row(
    owner: &str,
    root: &str,
    agent: &crate::agents::jobs::model::AgentRecord,
    header: &Value,
) -> Agent {
    let thread = match &agent.conversation {
        ConversationBinding::Known { conversation } => Some(conversation.thread_id.clone()),
        _ => None,
    };
    let working = header["status"]["type"] == "active";
    let provider = match &agent.conversation {
        ConversationBinding::Known { conversation } => conversation.provider.as_str(),
        _ => "unknown",
    };
    Agent {
        id: format!("thread:{}", thread.as_deref().unwrap_or_default()),
        owner_host_id: owner.into(),
        job_id: None,
        parent: agent.parent.clone(),
        recipient: agent.parent_recipient.clone(),
        kind: None,
        intent_state: None,
        parent_id: None,
        owner_thread_id: root.into(),
        thread_id: thread,
        provider: provider.into(),
        source: "native".into(),
        title: header["name"].as_str().unwrap_or("Agent").into(),
        model: header["model"].as_str().map(str::to_owned),
        state: if working {
            State::Working
        } else {
            State::Unknown
        },
        capabilities: Capabilities {
            inspect: true,
            open_conversation: true,
            message: true,
            continue_work: false,
            stop: working,
            ask_parent: agent.parent.is_some(),
        },
        execution_id: None,
        last_active_at: header["updatedAt"].as_i64(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::jobs::model::*;

    #[tokio::test]
    async fn every_agent_row_kind_round_trips_the_required_wire_shape() {
        let gateway = crate::test_support::TestGateway::new();
        let directory = tempfile::tempdir().unwrap();
        let spec = JobSpec {
            prompt: "Fixture".into(),
            cwd: directory.path().into(),
            settings: ExecutionSettings::Codex {
                model: "gpt-6.1-sol".into(),
                model_provider: "openai".into(),
                effort: "medium".into(),
                service_tier: None,
                cyber_access_program: None,
            },
            tool_scope: ToolScope::Full,
            title: None,
        };
        let id = JobId::for_mutation(Provider::Codex, "typed-agent-rows").unwrap();
        gateway
            .jobs
            .start(
                agent_jobs::StartParams {
                    job_id: id.clone(),
                    spec: spec.clone(),
                    caller: Caller::Operator,
                },
                Origin::TopLevel,
            )
            .await
            .unwrap();
        let view = gateway.jobs.read(&id).await.unwrap();
        let identity = gateway.host_identity().await.unwrap();
        let address = AgentAddress {
            host_id: identity.host_id.clone(),
            thread_id: "8c43d12f-8038-5d28-be95-ef14cc47faf3".into(),
        };
        let agent = AgentRecord {
            agent_id: "native-agent".into(),
            parent: Some(address.clone()),
            parent_revision: 0,
            parent_recipient: Some(Recipient::None),
            conversation: ConversationBinding::Known {
                conversation: gateway
                    .agent_conversation("9304e502-2328-5bd3-bd7b-2fbe7d467b95")
                    .unwrap(),
            },
            origin: Origin::TopLevel,
            tool_scope: None,
            origin_job_id: None,
            latest_job_id: None,
        };
        let intent = RemoteIntent {
            created_at: crate::cluster::link::timestamp(),
            parent: Some(address),
            protocol: PROTOCOL,
            host: identity.host_id.clone(),
            membership: crate::ids::new_session_uuid(),
            incarnation: identity.incarnation.clone(),
            request: AdmitParams {
                protocol: PROTOCOL,
                job_id: id,
                fingerprint: "fixture".into(),
                incarnation: identity.incarnation,
                origin: Origin::TopLevel,
                recipient: Recipient::None,
                operation: AdmissionOperation::Start(spec),
                caller_authority: CallerAuthority::Operator,
            },
            state: IntentState::Pending,
            stop_confirmed: false,
            transmission_uncertain: false,
        };
        let rows = [
            native_row(
                &identity.host_id,
                "parent",
                &agent,
                &json!({"name":"Native","status":{"type":"idle"}}),
            ),
            runtime_row(&identity.host_id, "parent", &view),
            intent_row(&intent).unwrap(),
        ];
        for row in rows {
            let encoded = serde_json::to_value(row).unwrap();
            let decoded: Agent = serde_json::from_value(encoded.clone()).unwrap();
            assert!(!decoded.owner_host_id.is_empty());
            assert!(encoded["title"].is_string());
            assert!(encoded["capabilities"]["askParent"].is_boolean());
            let mut missing = encoded;
            missing["capabilities"]
                .as_object_mut()
                .unwrap()
                .remove("askParent");
            assert!(serde_json::from_value::<Agent>(missing).is_err());
        }
    }
}
