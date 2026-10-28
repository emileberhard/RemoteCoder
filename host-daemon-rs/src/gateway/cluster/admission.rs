use super::*;

impl Gateway {
    pub(crate) async fn cluster_authority(&self, caller: &Caller) -> Result<CallerAuthority> {
        if let Caller::Forwarded { authority, .. } = caller {
            validate_authority(authority)?;
            return Ok(authority.clone());
        }
        match self.resolve_job_caller(caller).await? {
            Origin::TopLevel => Ok(CallerAuthority::Operator),
            Origin::Parent { conversation } => {
                let scope = self
                    .jobs
                    .agent_for_conversation(&conversation)
                    .await?
                    .and_then(|agent| agent.tool_scope)
                    .unwrap_or(ToolScope::Full);
                let authority = CallerAuthority::Agent {
                    conversation,
                    scope,
                };
                validate_authority(&authority)?;
                Ok(authority)
            }
            _ => bail!("only locally proven callers may forward cluster work"),
        }
    }

    pub(in crate::gateway) fn inherit_job_scope(
        authority: &CallerAuthority,
        spec: &mut crate::agents::jobs::model::JobSpec,
    ) -> Result<()> {
        if let CallerAuthority::Agent {
            scope: ToolScope::ReadOnly { root },
            ..
        } = authority
        {
            ensure!(
                spec.cwd.starts_with(root),
                "child working directory is outside the caller's read-only root"
            );
            spec.tool_scope = ToolScope::ReadOnly { root: root.clone() };
        }
        Ok(())
    }

    pub(super) async fn forward_cluster(
        &self,
        host: &str,
        method: &str,
        request: Value,
        authority: CallerAuthority,
    ) -> Result<Value> {
        validate_authority(&authority)?;
        let link = self.cluster_link().await?;
        let member = link
            .store
            .resolve(host)
            .await
            .map_err(|error| cluster_error(ErrorClass::Usage, error.to_string()))?;
        let identity = self.host_identity().await?;
        if matches!(method, "agent/jobs/start" | "agent/jobs/continue") {
            let (job_id, operation) = if method == "agent/jobs/start" {
                let mut request: agent_jobs::StartParams = decode(request)?;
                Self::inherit_job_scope(&authority, &mut request.spec)?;
                (request.job_id, AdmissionOperation::Start(request.spec))
            } else {
                let mut request: agent_jobs::ContinueParams = decode(request)?;
                request.caller = Caller::Operator;
                request.recipient = agent_jobs::ContinueRecipient::Current;
                (
                    request.job_id.clone(),
                    AdmissionOperation::Continue(request),
                )
            };
            let hello:HelloReceipt=decode(link.call(&member.host,"cluster/hello",json!({"protocol":PROTOCOL,"host":identity.host_id,"incarnation":identity.incarnation})).await.map_err(|error|crate::cluster::link::LinkError {class:if error.class==ErrorClass::Unsupported {ErrorClass::Unsupported}else{ErrorClass::Unavailable},transmitted:false,message:error.message})?)?;
            let origin = match &authority {
                CallerAuthority::Operator => Origin::TopLevel,
                CallerAuthority::Agent { conversation, .. } => Origin::RemoteParent {
                    host: identity.host_id.clone(),
                    conversation: conversation.clone(),
                },
            };
            let recipient = match &authority {
                CallerAuthority::Operator => Recipient::None,
                CallerAuthority::Agent { conversation, .. } => Recipient::Remote {
                    host: identity.host_id.clone(),
                    incarnation: identity.incarnation.clone(),
                    conversation: conversation.clone(),
                },
            };
            let mut parent = match &authority {
                CallerAuthority::Operator => None,
                CallerAuthority::Agent { conversation, .. } => Some(AgentAddress {
                    host_id: identity.host_id.clone(),
                    thread_id: conversation.thread_id.clone(),
                }),
            };
            if let AdmissionOperation::Continue(request) = &operation
                && let Some(previous) = &request.expected_previous_job_id
            {
                let view: agent_jobs::JobView = decode(
                    link.call(
                        &member.host,
                        "agent/jobs/read",
                        json!(ForwardParams {
                            protocol: PROTOCOL,
                            incarnation: identity.incarnation.clone(),
                            caller_authority: authority.clone(),
                            request: json!(agent_jobs::ReadParams {
                                job_id: previous.clone()
                            })
                        }),
                    )
                    .await?,
                )?;
                parent = view.parent;
            }
            let mut admit = AdmitParams {
                protocol: PROTOCOL,
                job_id,
                fingerprint: String::new(),
                incarnation: hello.incarnation.clone(),
                origin,
                recipient,
                operation,
                caller_authority: authority,
            };
            admit.fingerprint = admit_fingerprint(&admit)?;
            let intent = RemoteIntent {
                protocol: PROTOCOL,
                host: member.host.clone(),
                membership: member.membership,
                incarnation: hello.incarnation,
                request: admit,
                parent,
                created_at: crate::cluster::link::timestamp(),
                state: IntentState::Pending,
                stop_confirmed: false,
            };
            let intent = self.jobs.store().await?.put_intent(intent).await?;
            ensure!(
                !matches!(
                    intent.state,
                    IntentState::Abandoned | IntentState::Removed | IntentState::Unknown
                ),
                "remote intent is closed; inspect its retained receipt"
            );
            self.send_remote_intent(intent, true).await
        } else {
            if matches!(
                method,
                "model/list" | "thread/read" | "thread/items/list" | "thread/turns/list"
            ) {
                return Ok(link
                    .call(
                        &member.host,
                        "cluster/forward",
                        json!(ForwardParams {
                            protocol: PROTOCOL,
                            incarnation: identity.incarnation.clone(),
                            caller_authority: authority,
                            request: json!({"method":method,"params":request})
                        }),
                    )
                    .await?);
            }
            ensure!(
                matches!(
                    method,
                    "agent/jobs/message"
                        | "agent/jobs/read"
                        | "agent/jobs/list"
                        | "agent/jobs/stop"
                        | "agent/parent/set"
                        | "agent/cluster/resolve"
                        | "agent/conversation/operate"
                ),
                "unsupported forwarded method"
            );
            let payload = if method == "agent/cluster/resolve" {
                request
            } else if method == "agent/parent/set" {
                let mut request = request;
                request
                    .as_object_mut()
                    .context("invalid parent mutation")?
                    .remove("caller");
                request["protocol"] = json!(PROTOCOL);
                request["callerAuthority"] = json!(authority);
                request
            } else if method == "agent/jobs/stop" {
                let stop: agent_jobs::StopParams = decode(request)?;
                if self
                    .jobs
                    .store()
                    .await?
                    .intents()
                    .await?
                    .iter()
                    .any(|intent| intent.request.job_id == stop.job_id)
                {
                    self.jobs
                        .store()
                        .await?
                        .intent_state(stop.job_id.clone(), IntentState::StopRequested)
                        .await?;
                }
                json!(crate::wire::cluster::StopParams {
                    protocol: PROTOCOL,
                    job_id: stop.job_id
                })
            } else {
                json!(ForwardParams {
                    protocol: PROTOCOL,
                    incarnation: identity.incarnation.clone(),
                    caller_authority: authority,
                    request
                })
            };
            Ok(link.call(&member.host, method, payload).await?)
        }
    }

    pub(super) async fn send_remote_intent(
        &self,
        intent: RemoteIntent,
        initial: bool,
    ) -> Result<Value> {
        let result = self
            .cluster_link()
            .await?
            .call(&intent.host, "agent/jobs/admit", json!(intent.request))
            .await;
        match result {
            Ok(receipt) => {
                let current = self
                    .jobs
                    .store()
                    .await?
                    .intents()
                    .await?
                    .into_iter()
                    .find(|record| record.request.job_id == intent.request.job_id)
                    .context("intent disappeared")?;
                if current.state == IntentState::StopRequested {
                    self.jobs.dirty();
                } else {
                    self.jobs
                        .store()
                        .await?
                        .intent_state(intent.request.job_id, IntentState::Admitted)
                        .await?;
                }
                Ok(receipt)
            }
            Err(error) => {
                if initial && !error.transmitted
                    || matches!(
                        error.class,
                        ErrorClass::Refused
                            | ErrorClass::Usage
                            | ErrorClass::Unsupported
                            | ErrorClass::Conflict
                            | ErrorClass::NotFound
                    )
                {
                    self.jobs
                        .store()
                        .await?
                        .intent_state(intent.request.job_id, IntentState::Abandoned)
                        .await?;
                }
                self.jobs.dirty();
                Err(error.into())
            }
        }
    }

    pub(crate) async fn reconcile_cluster_member(&self, host: &str) -> Result<bool> {
        let intents = self.jobs.store().await?.intents().await?;
        let mut retry = false;
        let link = self.cluster_link().await?;
        let identity = self.host_identity().await?;
        for member in link
            .members()
            .await?
            .into_iter()
            .filter(|member| member.host == host && member.state == MemberState::RemovePending)
        {
            if link.call(&member.host,"cluster/removed",json!({"protocol":PROTOCOL,"host":identity.host_id,"membership":member.membership})).await.is_ok() {
                link.store.remove(RemoveParams {protocol:PROTOCOL,host:member.host,membership:member.membership},false).await?;
            } else {retry=true;}
        }
        for intent in intents.into_iter().filter(|intent| intent.host == host) {
            if !matches!(
                intent.state,
                IntentState::Pending | IntentState::StopRequested
            ) || intent.stop_confirmed
            {
                continue;
            }
            let link = self.cluster_link().await?;
            let identity = self.host_identity().await?;
            let hello=link.call(&intent.host,"cluster/hello",json!({"protocol":PROTOCOL,"host":identity.host_id,"incarnation":identity.incarnation})).await;
            let hello: HelloReceipt = match hello {
                Ok(value) => decode(value)?,
                Err(_) => {
                    retry = true;
                    continue;
                }
            };
            if hello.incarnation != intent.incarnation {
                self.jobs
                    .store()
                    .await?
                    .intent_state(intent.request.job_id, IntentState::Unknown)
                    .await?;
                continue;
            }
            if intent.state == IntentState::StopRequested {
                if link
                    .call(
                        &intent.host,
                        "agent/jobs/stop",
                        json!(crate::wire::cluster::StopParams {
                            protocol: PROTOCOL,
                            job_id: intent.request.job_id.clone()
                        }),
                    )
                    .await
                    .is_err()
                {
                    retry = true;
                } else {
                    self.jobs
                        .store()
                        .await?
                        .confirm_remote_stop(intent.request.job_id)
                        .await?;
                }
            } else if self.send_remote_intent(intent, false).await.is_err() {
                retry = true;
            }
        }
        Ok(retry)
    }

    pub(super) async fn reconcile_member_incarnation(
        &self,
        host: &str,
        incarnation: &str,
    ) -> Result<()> {
        for intent in self.jobs.store().await?.intents().await? {
            if intent.host == host
                && intent.incarnation != incarnation
                && matches!(
                    intent.state,
                    IntentState::Pending | IntentState::Admitted | IntentState::StopRequested
                )
            {
                self.jobs
                    .store()
                    .await?
                    .intent_state(intent.request.job_id, IntentState::Unknown)
                    .await?;
            }
        }
        Ok(())
    }

    pub(super) async fn remove_member_work(&self, membership: &str, host: &str) -> Result<()> {
        let store = self.jobs.store().await?;
        for intent in store.intents().await? {
            if intent.membership == membership
                && intent.host == host
                && !matches!(
                    intent.state,
                    IntentState::Abandoned | IntentState::Unknown | IntentState::Removed
                )
            {
                store
                    .intent_state(intent.request.job_id, IntentState::Removed)
                    .await?;
            }
        }
        for agent in store.agent_rows().await? {
            let Some(id) = agent.latest_job_id else {
                continue;
            };
            let job = store.read(id.clone()).await?;
            if job.admitted_membership.as_deref() == Some(membership)
                && !matches!(job.execution, ExecutionState::Terminal { .. })
            {
                self.jobs
                    .stop(agent_jobs::StopParams {
                        job_id: id,
                        mutation_id: format!("member-removed:{membership}"),
                    })
                    .await?;
            }
        }
        self.jobs.dirty();
        Ok(())
    }

    pub(in crate::gateway) async fn authorize_existing(
        &self,
        id: &str,
        caller: &Caller,
    ) -> Result<()> {
        let agent = self.jobs.store().await?.agent(id.to_owned()).await?;
        check_steering_scope(
            &self.cluster_authority(caller).await?,
            agent.tool_scope.as_ref(),
        )?;
        ensure!(
            agent.tool_scope.is_some()
                || matches!(
                    caller,
                    Caller::Operator
                        | Caller::Forwarded {
                            authority: CallerAuthority::Operator,
                            ..
                        }
                ),
            "target conversation permission scope is unresolved"
        );
        Ok(())
    }

    pub(in crate::gateway) async fn authorize_conversation(
        &self,
        caller: &Caller,
        conversation: &ConversationIdentity,
    ) -> Result<()> {
        let authority = self.cluster_authority(caller).await?;
        if matches!(
            authority,
            CallerAuthority::Agent {
                scope: ToolScope::ReadOnly { .. },
                ..
            }
        ) {
            let target = self.jobs.agent_for_conversation(conversation).await?;
            check_steering_scope(
                &authority,
                target.as_ref().and_then(|agent| agent.tool_scope.as_ref()),
            )?;
        }
        Ok(())
    }
}

impl Gateway {
    pub(super) async fn admit_remote(
        &self,
        host: &str,
        membership: &str,
        params: Value,
    ) -> Result<Value> {
        let identity = self.host_identity().await?;
        let request: AdmitParams = decode(params)?;
        if request.incarnation != identity.incarnation {
            return Err(cluster_error(
                ErrorClass::Uncertain,
                "target incarnation changed; remote admission is unknown",
            )
            .into());
        }
        validate_authority(&request.caller_authority)?;
        let caller = Caller::Forwarded {
            admission_fingerprint: Some(request.fingerprint.clone()),
            host: host.to_owned(),
            membership: membership.to_owned(),
            incarnation: remote_incarnation(&request.recipient, host)?,
            authority: request.caller_authority.clone(),
        };
        let origin = self.resolve_job_caller(&caller).await?;
        ensure!(
            origin == request.origin,
            "remote origin differs from the caller proven by its member"
        );
        ensure!(
            match (&request.caller_authority, &request.recipient) {
                (CallerAuthority::Operator, Recipient::None) => true,
                (
                    CallerAuthority::Agent { conversation, .. },
                    Recipient::Remote {
                        host: receiver,
                        conversation: target,
                        ..
                    },
                ) => receiver == host && target == conversation,
                _ => false,
            },
            "remote recipient differs from its proven caller"
        );
        ensure!(
            request.fingerprint == admit_fingerprint(&request)?,
            "remote admission fingerprint differs from its payload"
        );
        if let Some(existing) = self
            .jobs
            .store()
            .await?
            .find_job(request.job_id.clone())
            .await?
        {
            if existing.remote_fingerprint.as_deref() != Some(&request.fingerprint) {
                return Err(cluster_error(
                    ErrorClass::Conflict,
                    "job ID was reused with different inputs",
                )
                .into());
            }
        }
        let receipt = match request.operation {
            AdmissionOperation::Start(mut spec) => {
                Self::inherit_job_scope(&request.caller_authority, &mut spec)?;
                self.jobs
                    .start(
                        agent_jobs::StartParams {
                            job_id: request.job_id,
                            spec,
                            caller,
                        },
                        origin,
                    )
                    .await?
            }
            AdmissionOperation::Continue(mut continuation) => {
                ensure!(
                    continuation.job_id == request.job_id,
                    "Continue identity differs from admission identity"
                );
                self.authorize_existing(&continuation.agent_id, &caller)
                    .await?;
                continuation.caller = caller;
                continuation.recipient = agent_jobs::ContinueRecipient::Current;
                self.jobs.continue_job(continuation, origin).await?
            }
        };
        Ok(json!(receipt))
    }
}
