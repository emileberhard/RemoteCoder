use super::*;

impl Gateway {
    pub(super) async fn set_cluster_parent(&self, request: ParentParams) -> Result<Value> {
        ensure!(request.protocol == PROTOCOL, "unsupported parent protocol");
        validate_authority(&request.caller_authority)?;
        let identity = self.host_identity().await?;
        ensure!(
            request.agent.host_id == identity.host_id,
            "parent update must name this owner"
        );
        let conversation = self.agent_conversation(&request.agent.thread_id)?;
        let agent = match self.jobs.agent_for_conversation(&conversation).await? {
            Some(agent) => agent,
            None => {
                let header =
                    if conversation.provider == crate::agents::jobs::model::Provider::Claude {
                        self.claude_thread_response(&json!({"threadId":conversation.thread_id}))
                            .await?
                    } else {
                        self.job_native_call(
                            "thread/read",
                            json!({"threadId":conversation.thread_id,"includeTurns":false}),
                        )
                        .await?
                    };
                ensure!(
                    header["thread"]["id"] == conversation.thread_id,
                    "native read returned another conversation"
                );
                let native_parent = crate::gateway::agent_gateway::native_parent(&header["thread"]);
                let parent = native_parent.map(|thread| AgentAddress {
                    host_id: identity.host_id.clone(),
                    thread_id: thread.to_owned(),
                });
                let origin = match native_parent {
                    Some(thread) => Origin::Parent {
                        conversation: self.agent_conversation(thread)?,
                    },
                    None => Origin::TopLevel,
                };
                let recipient = match &origin {
                    Origin::Parent { conversation } => Recipient::Conversation {
                        conversation: conversation.clone(),
                    },
                    _ => Recipient::None,
                };
                self.jobs
                    .store()
                    .await?
                    .adopt_conversation(crate::agents::jobs::model::AgentRecord {
                        agent_id: format!(
                            "native-{}",
                            crate::agents::jobs::store::fingerprint(&serde_json::to_vec(
                                &conversation
                            )?)
                        ),
                        conversation: ConversationBinding::Known { conversation },
                        origin,
                        tool_scope: None,
                        origin_job_id: None,
                        latest_job_id: None,
                        parent,
                        parent_revision: 0,
                        parent_recipient: Some(recipient),
                    })
                    .await?
            }
        };
        let mut next = request.parent.clone();
        let link = self.cluster_link().await?;
        let mut seen = std::collections::HashSet::new();
        let mut observed = std::collections::HashMap::new();
        for hop in 0..=16 {
            let Some(parent) = next else { break };
            ensure!(hop < 16, "parent chain exceeds 16 hops");
            if parent == request.agent
                || !seen.insert((parent.host_id.clone(), parent.thread_id.clone()))
            {
                return Err(
                    cluster_error(ErrorClass::Usage, "parent tag would form a cycle").into(),
                );
            }
            let conversation = (parent.host_id == identity.host_id)
                .then(|| self.agent_conversation(&parent.thread_id))
                .transpose()?;
            next = if parent.host_id == identity.host_id {
                self.agent_service()
                    .parent_for_thread(&parent.thread_id)
                    .await?
            } else {
                let response = link
                    .call(
                        &parent.host_id,
                        "agent/parent/read",
                        json!({"protocol":PROTOCOL,"agent":parent.clone()}),
                    )
                    .await
                    .map_err(|error| cluster_error(ErrorClass::Unavailable, error.message))?;
                decode(response["parent"].clone())?
            };
            observed.insert(parent, (conversation, next.clone()));
        }
        let recipient = match &request.parent {
            None => Recipient::None,
            Some(parent) if parent.host_id == identity.host_id => Recipient::Conversation {
                conversation: self.agent_conversation(&parent.thread_id)?,
            },
            Some(parent) => {
                let hello:HelloReceipt=decode(link.call(&parent.host_id,"cluster/hello",json!({"protocol":PROTOCOL,"host":identity.host_id,"incarnation":identity.incarnation})).await?)?;
                let provider = if crate::providers::claude::is_claude_thread_id(&parent.thread_id) {
                    crate::agents::jobs::model::Provider::Claude
                } else {
                    crate::agents::jobs::model::Provider::Codex
                };
                let resolved = link
                    .call(
                        &parent.host_id,
                        "agent/parent/resolve",
                        json!({"protocol":PROTOCOL,"agent":parent.clone()}),
                    )
                    .await?;
                let conversation: ConversationIdentity = decode(resolved["conversation"].clone())?;
                ensure!(
                    conversation.provider == provider && conversation.thread_id == parent.thread_id,
                    "parent resolved another conversation"
                );
                Recipient::Remote {
                    host: parent.host_id.clone(),
                    incarnation: hello.incarnation,
                    conversation,
                }
            }
        };
        let mut row = self
            .project_agent_record(&agent, &request.agent.thread_id)
            .await?;
        let _operation = self.jobs.operations.write().await;
        let moved = self
            .jobs
            .store()
            .await?
            .set_parent(
                agent.agent_id,
                request.parent,
                recipient,
                request.agent.clone(),
                observed,
            )
            .await?;
        self.agent_service().invalidate_parent_views().await;
        self.jobs.dirty();
        row.parent = moved.parent.clone();
        row.recipient = moved.parent_recipient;
        row.capabilities.ask_parent = row.parent.is_some();
        row.owner_thread_id = row
            .parent
            .as_ref()
            .map_or(request.agent.thread_id, |parent| parent.thread_id.clone());
        Ok(serde_json::to_value(row)?)
    }
}
impl Gateway {
    pub(in crate::gateway) async fn apply_parent_tags(&self, response: &mut Value) -> Result<bool> {
        if self.turn_state_path.is_none() {
            return Ok(false);
        }
        let host = self.host_identity().await?.host_id;
        let threads = response
            .get("thread")
            .into_iter()
            .chain(
                response
                    .get("data")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten(),
            )
            .filter_map(|thread| thread.get("id").and_then(Value::as_str))
            .filter_map(|thread| self.agent_conversation(thread).ok())
            .collect();
        let tags = self.jobs.store().await?.parent_tags(threads).await?;
        let mut changed = false;
        let mut apply = |thread: &mut Value| {
            if !thread.is_object() {
                return;
            }
            let Some(id) = thread["id"].as_str() else {
                return;
            };
            let Ok(conversation) = self.agent_conversation(id) else {
                return;
            };
            let native_parent =
                crate::gateway::agent_gateway::native_parent(thread).map(|thread| AgentAddress {
                    host_id: host.clone(),
                    thread_id: thread.to_owned(),
                });
            let parent = match tags.get(&conversation) {
                Some(parent) => parent.as_ref(),
                None if native_parent.is_none() => return,
                None => native_parent.as_ref(),
            };
            for (field, value) in [
                ("parent", json!(parent)),
                (
                    "parentThreadId",
                    json!(
                        parent
                            .filter(|parent| parent.host_id == host)
                            .map(|parent| &parent.thread_id)
                    ),
                ),
            ] {
                if thread.get(field) != Some(&value) {
                    thread[field] = value;
                    changed = true;
                }
            }
            if let Some(fields) = thread.as_object_mut() {
                changed |= fields.remove("parentHostID").is_some();
            }
        };
        if let Some(thread) = response.get_mut("thread") {
            apply(thread);
        }
        if let Some(rows) = response.get_mut("data").and_then(Value::as_array_mut) {
            for row in rows {
                apply(row);
            }
        }
        Ok(changed)
    }
}
