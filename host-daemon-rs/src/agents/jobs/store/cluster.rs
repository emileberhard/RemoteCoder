use super::*;
use crate::wire::cluster::{AgentAddress, CancelFence, IntentState, RemoteIntent};

impl Inner {
    pub(super) fn load_cluster(&mut self) -> Result<()> {
        for entry in std::fs::read_dir(self.root.join("remote-intents"))? {
            let entry = entry?;
            if entry
                .path()
                .extension()
                .is_none_or(|extension| extension != "json")
            {
                continue;
            }
            let intent: RemoteIntent = read(&entry.path(), MAX_JOB_BYTES)?;
            ensure!(
                entry.file_name().to_str()
                    == Some(format!("{}.json", intent.request.job_id.as_str()).as_str()),
                "intent filename differs from its job identity"
            );
            ensure!(
                self.insert_intent(intent).is_none(),
                "duplicate remote intent"
            );
        }
        for entry in std::fs::read_dir(self.root.join("cancel-fences"))? {
            let entry = entry?;
            if entry
                .path()
                .extension()
                .is_none_or(|extension| extension != "json")
            {
                continue;
            }
            let fence: CancelFence = read(&entry.path(), MAX_AGENT_BYTES)?;
            let key = fence_key(&fence.membership, &fence.job_id);
            ensure!(
                entry.path().file_stem().and_then(|name| name.to_str()) == Some(key.as_str()),
                "cancel-fence filename differs from its identity"
            );
            self.fences.insert(key, fence);
        }
        Ok(())
    }
}

impl JobStore {
    pub(crate) async fn parent_tags(
        &self,
        threads: Vec<ConversationIdentity>,
    ) -> Result<std::collections::HashMap<ConversationIdentity, Option<AgentAddress>>> {
        self.access(move |inner| {
            Ok(threads
                .into_iter()
                .filter_map(|thread| {
                    inner
                        .parents
                        .get(&thread)
                        .map(|parent| (thread.clone(), parent.clone()))
                })
                .collect())
        })
        .await
    }

    pub(crate) async fn find_job(&self, id: JobId) -> Result<Option<JobRecord>> {
        self.access(move |inner| Ok(inner.jobs.get(&id).cloned()))
            .await
    }

    pub(crate) async fn adopt_conversation(&self, agent: AgentRecord) -> Result<AgentRecord> {
        self.access(move |inner| {
            if let ConversationBinding::Known { conversation } = &agent.conversation {
                if let Some(id) = inner.indexes.agent(conversation)? {
                    return inner.agent_view(id);
                }
                ensure!(
                    !conversation.thread_id.is_empty(),
                    "conversation has no identity"
                );
            } else {
                bail!("adoption requires an exact conversation");
            }
            ensure!(
                inner.accounted_bytes()? + 2 * MAX_AGENT_BYTES + MUTATION_RESERVE
                    <= MAX_STORE_BYTES,
                "agent store capacity reached"
            );
            inner.write_agent(&agent)?;
            inner.insert_agent(agent.clone());
            Ok(agent)
        })
        .await
    }

    pub(crate) async fn initialize_parent_tags(&self, host: String) -> Result<()> {
        self.access(move |inner| {
            let agents = inner
                .agents
                .values()
                .filter(|agent| agent.parent_recipient.is_none())
                .cloned()
                .collect::<Vec<_>>();
            for mut agent in agents {
                let parent = match &agent.origin {
                    Origin::TopLevel => continue,
                    Origin::Parent { conversation } => Some(AgentAddress {
                        host_id: host.clone(),
                        thread_id: conversation.thread_id.clone(),
                    }),
                    Origin::RemoteParent { host, conversation } => Some(AgentAddress {
                        host_id: host.clone(),
                        thread_id: conversation.thread_id.clone(),
                    }),
                    Origin::Unknown { .. } => continue,
                };
                let recipient = agent
                    .latest_job_id
                    .as_ref()
                    .or(agent.origin_job_id.as_ref())
                    .and_then(|id| inner.jobs.get(id))
                    .map(|job| job.recipient.clone())
                    .unwrap_or_else(|| Recipient::Unknown {
                        reason: "agent has no delivery evidence".into(),
                    });
                if agent.parent == parent && agent.parent_recipient.as_ref() == Some(&recipient) {
                    continue;
                }
                agent.parent = parent;
                agent.parent_recipient = Some(recipient);
                inner.write_agent(&agent)?;
                inner.insert_agent(agent);
            }
            Ok(())
        })
        .await
    }

    pub(crate) async fn confirm_remote_stop(&self, id: JobId) -> Result<()> {
        self.access(move |inner| {
            let mut intent = inner
                .intents
                .get(&id)
                .context("remote intent does not exist")?
                .clone();
            ensure!(
                intent.state == IntentState::StopRequested,
                "intent has no requested Stop"
            );
            intent.stop_confirmed = true;
            private_state::write_json(
                &inner
                    .root
                    .join("remote-intents")
                    .join(format!("{}.json", id.as_str())),
                &intent,
            )?;
            inner.insert_intent(intent);
            Ok(())
        })
        .await
    }

    pub(crate) async fn claim_intent(
        &self,
        id: &JobId,
    ) -> Result<tokio::sync::OwnedRwLockWriteGuard<()>> {
        self.executions.mutation(id).await
    }

    pub(crate) async fn begin_intent_attempt(&self, id: JobId) -> Result<(RemoteIntent, bool)> {
        self.access(move |inner| {
            let mut intent = inner
                .intents
                .get(&id)
                .context("remote intent does not exist")?
                .clone();
            ensure!(
                matches!(intent.state, IntentState::Pending | IntentState::Admitted),
                "remote intent is closed to admission"
            );
            let uncertain = intent.transmission_uncertain || intent.state == IntentState::Admitted;
            intent.transmission_uncertain = true;
            private_state::write_json(
                &inner
                    .root
                    .join("remote-intents")
                    .join(format!("{}.json", id.as_str())),
                &intent,
            )?;
            inner.insert_intent(intent.clone());
            Ok((intent, uncertain))
        })
        .await
    }

    pub(crate) async fn put_intent(&self, intent: RemoteIntent) -> Result<RemoteIntent> {
        self.access(move |inner| {
            if let Some(existing) = inner.intents.get(&intent.request.job_id) {
                if existing.request.fingerprint != intent.request.fingerprint
                    || existing.membership != intent.membership
                    || existing.host != intent.host
                    || existing.incarnation != intent.incarnation
                {
                    return Err(crate::rpc::RpcError::new(
                        crate::rpc::error::RpcCode::Conflict,
                        "remote job ID was reused with different inputs",
                    )
                    .with_data(crate::rpc::error::RpcData::Raw(
                        serde_json::json!({"class":"conflict"}),
                    ))
                    .into());
                }
                return Ok(existing.clone());
            }
            let bytes = serde_json::to_vec(&intent)?;
            ensure!(
                bytes.len() as u64 <= MAX_JOB_BYTES,
                "remote intent exceeds record capacity"
            );
            ensure!(
                inner.indexes.unsettled_intents < MAX_UNSETTLED_JOBS,
                "remote intent capacity reached"
            );
            ensure!(
                inner.accounted_bytes()? + 2 * bytes.len() as u64 + MUTATION_RESERVE
                    <= MAX_STORE_BYTES,
                "remote intent storage capacity reached"
            );
            private_state::replace(
                &inner
                    .root
                    .join("remote-intents")
                    .join(format!("{}.json", intent.request.job_id.as_str())),
                &bytes,
            )?;
            inner.insert_intent(intent.clone());
            Ok(intent)
        })
        .await
    }

    #[cfg(test)]
    pub(crate) async fn intents(&self) -> Result<Vec<RemoteIntent>> {
        self.access(|inner| Ok(inner.intents.values().cloned().collect()))
            .await
    }

    pub(crate) async fn intent_state(&self, id: JobId, next: IntentState) -> Result<RemoteIntent> {
        self.access(move |inner| {
            let mut intent = inner
                .intents
                .get(&id)
                .context("remote intent does not exist")?
                .clone();
            ensure!(
                !matches!(
                    intent.state,
                    IntentState::Unknown | IntentState::Abandoned | IntentState::Removed
                ) || intent.state == next,
                "closed remote intent cannot be replayed"
            );
            ensure!(
                intent.state != IntentState::StopRequested
                    || matches!(
                        next,
                        IntentState::StopRequested | IntentState::Removed | IntentState::Unknown
                    ),
                "Stop cannot be undone by a late admission receipt"
            );
            intent.state = next;
            private_state::write_json(
                &inner
                    .root
                    .join("remote-intents")
                    .join(format!("{}.json", id.as_str())),
                &intent,
            )?;
            inner.insert_intent(intent.clone());
            Ok(intent)
        })
        .await
    }

    pub(crate) async fn cancel_remote(&self, fence: CancelFence) -> Result<Option<JobRecord>> {
        self.access(move |inner| {
            let key = fence_key(&fence.membership, &fence.job_id);
            if !inner.fences.contains_key(&key) {
                ensure!(
                    inner.accounted_bytes()? + MAX_AGENT_BYTES + MUTATION_RESERVE
                        <= MAX_STORE_BYTES,
                    "cancel fence capacity exceeded"
                );
                private_state::write_json(
                    &inner.root.join("cancel-fences").join(format!("{key}.json")),
                    &fence,
                )?;
                inner.fences.insert(key, fence.clone());
            }
            let Some(job) = inner.jobs.get(&fence.job_id) else {
                return Ok(None);
            };

            let mut job = job.clone();
            if matches!(job.stop, StopState::NotRequested) {
                job.stop = StopState::Requested {
                    mutation_id: format!("cluster:{}", fence.membership),
                    at_ms: fence.at,
                };
                return inner.commit(job, fence.at).map(Some);
            }
            Ok(Some(job))
        })
        .await
    }

    pub(crate) async fn set_parent(
        &self,
        id: String,
        parent: Option<AgentAddress>,
        recipient: Recipient,
        target: AgentAddress,
        observed: HashMap<AgentAddress, (Option<ConversationIdentity>, Option<AgentAddress>)>,
    ) -> Result<AgentRecord> {
        self.access(move |inner| {
            let mut next = parent.clone();
            let mut seen = std::collections::HashSet::new();
            for hop in 0..=16 {
                let Some(address) = next else {
                    return inner.update_parent(id, parent, recipient);
                };
                ensure!(
                    hop < 16 && address != target && seen.insert(address.clone()),
                    "parent tag would form a cycle or exceed 16 hops"
                );
                let (conversation, snapshot) = observed
                    .get(&address)
                    .context("parent chain changed during validation; retry the move")?;
                next = conversation
                    .as_ref()
                    .and_then(|conversation| inner.parents.get(conversation))
                    .unwrap_or(snapshot)
                    .clone();
            }
            unreachable!()
        })
        .await
    }

    #[cfg(test)]
    pub(crate) async fn set_parent_for_test(
        &self,
        id: String,
        parent: Option<AgentAddress>,
        recipient: Recipient,
    ) -> Result<AgentRecord> {
        self.access(move |inner| inner.update_parent(id, parent, recipient))
            .await
    }

    pub(crate) async fn retarget_delivery(&self, id: JobId) -> Result<JobRecord> {
        self.access(move |inner| {
            let mut job=inner.job(&id)?.clone();
            let agent=inner.agent_view(&job.agent_id)?;
            if agent.parent_revision <= job.parent_revision {return Ok(job);}
            let frozen=matches!(&job.execution,ExecutionState::Terminal {terminal} if matches!(&terminal.completion,Completion::Required {delivery:DeliveryState::Uncertain{..}|DeliveryState::Sending{..}|DeliveryState::Submitted{..}|DeliveryState::Accepted{..}|DeliveryState::Recorded{..},..}));
            let uncertain_notice = job.notices.iter().any(|notice| matches!(notice.delivery,
                DeliveryState::Uncertain { .. } | DeliveryState::Sending { .. } | DeliveryState::Submitted { .. }));
            if frozen || uncertain_notice {return Ok(job);}
            job.recipient=agent.parent_recipient.context("moved agent has no receiver identity")?;
            job.parent_revision=agent.parent_revision;
            let at_ms=job.updated_at_ms;
            inner.commit(job,at_ms)
        }).await
    }

    #[cfg(test)]
    pub(crate) async fn agent_ids(&self) -> Result<Vec<String>> {
        self.access(|inner| {
            let mut ids: Vec<_> = inner.agents.keys().cloned().collect();
            ids.sort();
            Ok(ids)
        })
        .await
    }
}

impl JobStore {
    pub(crate) async fn attention(&self, id: JobId, next: Attention) -> Result<JobRecord> {
        self.access(move |inner| {
            let mut job = inner.job(&id)?.clone();
            if matches!(job.attention, Some(Attention::Surfaced { .. }))
                || job.attention == Some(next.clone())
            {
                return Ok(job);
            }
            ensure!(
                job.attention.is_none() || matches!(&next, Attention::Surfaced { .. }),
                "attention is already pending"
            );
            job.attention = Some(next);
            let at_ms = job.updated_at_ms;
            inner.commit(job, at_ms)
        })
        .await
    }
}

pub(super) fn fence_key(membership: &str, id: &JobId) -> String {
    fingerprint(format!("{}:{}", membership, id.as_str()).as_bytes())
}

impl Inner {
    fn update_parent(
        &mut self,
        id: String,
        parent: Option<AgentAddress>,
        recipient: Recipient,
    ) -> Result<AgentRecord> {
        let mut agent = self.agent_view(&id)?;
        if agent.parent == parent && agent.parent_recipient.as_ref() == Some(&recipient) {
            return Ok(agent);
        }
        agent.parent = parent;
        agent.parent_revision = agent
            .parent_revision
            .checked_add(1)
            .context("parent revision exhausted")?;
        agent.parent_recipient = Some(recipient);
        self.write_agent(&agent)?;
        self.insert_agent(agent.clone());
        Ok(agent)
    }
}
