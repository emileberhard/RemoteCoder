use std::sync::Arc;

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::Gateway;
use crate::agents::jobs::model::{
    ConversationBinding, ConversationIdentity, DeliveryState, ExecutionState, JobId, Origin,
    Recipient, ToolScope,
};
use crate::agents::{Agent, AgentKind, Capabilities, State};
use crate::auth::installation_credentials::Grant;
use crate::rpc::error::{RpcCode, RpcData};
use crate::rpc::{RpcError, RpcResult};
use crate::wire::agent_jobs::{self, Caller};
use crate::wire::cluster::*;

fn decode<T: serde::de::DeserializeOwned>(value: Value) -> Result<T> {
    Ok(serde_json::from_value(value)?)
}
fn cluster_error(class: ErrorClass, message: impl Into<String>) -> RpcError {
    RpcError::new(RpcCode::InvalidRequest, message)
        .with_data(RpcData::Raw(json!({"class":class,"retryable":false})))
}
fn version() -> &'static str {
    crate::build_identity::IDENTITY.version
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Dispatch {
    host: String,
    method: String,
    request: Value,
    caller: Caller,
}

impl Gateway {
    pub(super) async fn cluster_rpc(
        &self,
        grant: &Grant,
        method: &str,
        params: Value,
    ) -> RpcResult {
        let result = self.cluster_request(grant, method, params).await;
        result.map_err(|error| {
            if let Some(error) = error.downcast_ref::<crate::cluster::link::LinkError>() {
                return cluster_error(error.class.clone(), error.message.clone());
            }
            if let Some(error) = error.downcast_ref::<RpcError>() {
                return error.clone();
            }
            cluster_error(ErrorClass::Refused, format!("{error:#}"))
        })
    }

    async fn cluster_request(&self, grant: &Grant, method: &str, params: Value) -> Result<Value> {
        let identity = self.host_identity().await?.clone();
        let link = self.cluster_link().await?;
        if method == "cluster/list" {
            return Ok(
                json!({"self":{"hostId":identity.host_id,"name":self.job_host_name()?,"incarnation":identity.incarnation,"version":version(),"protocol":PROTOCOL},"members":link.members().await?}),
            );
        }
        if method == "cluster/issue"
            || method == "cluster/accept"
            || method == "cluster/remove"
            || method == "cluster/reset-identity"
        {
            ensure!(
                matches!(grant, Grant::Operator),
                "membership changes require the local operator"
            );
            return match method {
                "cluster/issue" => {
                    let request: IssueParams = decode(params)?;
                    ensure!(
                        request.r#for != identity.host_id,
                        "cannot join this host to itself"
                    );
                    let membership = request.membership.clone();
                    let credential = link.store.issue(request).await?;
                    let (routes, pin) = link.endpoint().await?;
                    Ok(json!(IssueReceipt {
                        protocol: PROTOCOL,
                        host: identity.host_id,
                        incarnation: identity.incarnation,
                        membership,
                        pin,
                        routes,
                        credential
                    }))
                }
                "cluster/accept" => Ok(public_member(&link.store.accept(decode(params)?).await?)),
                "cluster/remove" => {
                    let request: RemoveParams = decode(params)?;
                    let record = link.store.remove(request.clone(), true).await?;
                    link.forget(&request.membership).await;
                    self.remove_member_work(&request.membership, &request.host)
                        .await?;
                    let remote=link.call(&request.host,"cluster/removed",json!({"protocol":PROTOCOL,"host":identity.host_id,"membership":request.membership})).await;
                    if remote.is_ok() {
                        link.store.remove(request, false).await?;
                    }
                    Ok(
                        json!({"removed":true,"pending":remote.is_err(),"hostId":record.host,"membership":record.membership}),
                    )
                }
                _ => {
                    for member in link
                        .store
                        .all()
                        .await?
                        .into_iter()
                        .filter(|member| member.state != MemberState::Removed)
                    {
                        let remove = RemoveParams {
                            protocol: PROTOCOL,
                            host: member.host.clone(),
                            membership: member.membership.clone(),
                        };
                        link.store.remove(remove.clone(), true).await?;
                        self.remove_member_work(&member.membership, &member.host)
                            .await?;
                        link.call(&member.host,"cluster/removed",json!({"protocol":PROTOCOL,"host":identity.host_id,"membership":member.membership})).await?;
                        link.store.remove(remove, false).await?;
                    }
                    let _operations = self.jobs.operations.write().await;
                    ensure!(
                        self.jobs.store().await?.pending_ids().await?.is_empty(),
                        "stop and settle active jobs before resetting host identity"
                    );
                    let state = self
                        .turn_state_path
                        .as_deref()
                        .and_then(std::path::Path::parent)
                        .context("identity has no state directory")?
                        .to_owned();
                    let reset = tokio::task::spawn_blocking(move || crate::identity::reset(&state))
                        .await??;
                    let cached = self
                        .identity
                        .get()
                        .context("host identity is not initialized")?;
                    *cached.write().await = reset.clone();
                    link.update_identity(reset.clone()).await;
                    Ok(json!({"reset":true,"hostId":reset.host_id,"incarnation":reset.incarnation}))
                }
            };
        }
        if method == "agent/conversation/operate" && !matches!(grant, Grant::Peer { .. }) {
            let mut request = params;
            let caller: Caller = decode(
                request
                    .as_object_mut()
                    .context("invalid native operation")?
                    .remove("caller")
                    .context("caller is required")?,
            )?;
            request["callerAuthority"] = json!(self.cluster_authority(&caller).await?);
            return self.native_conversation_operation(request, caller).await;
        }
        if matches!(method, "agent/cluster/inventory" | "agent/cluster/resolve") {
            if let Grant::Peer {
                host,
                membership,
                digest,
            } = grant
            {
                ensure!(
                    link.store.valid(host, membership, digest).await?,
                    "membership was removed"
                );
            }
            return if method == "agent/cluster/inventory" {
                self.local_agent_inventory(params).await
            } else {
                self.resolve_cluster_agent(params, matches!(grant, Grant::Peer { .. }))
                    .await
            };
        }
        if method == "agent/cluster/list" {
            ensure!(
                !matches!(grant, Grant::Peer { .. }),
                "cluster fan-out cannot be forwarded recursively"
            );
            return self.list_cluster_agents(params).await;
        }
        if method == "agent/cluster/dispatch" {
            ensure!(
                !matches!(grant, Grant::Peer { .. }),
                "a member cannot forward through a third host"
            );
            let request: Dispatch = decode(params)?;
            let authority = self.cluster_authority(&request.caller).await?;
            return self
                .forward_cluster(&request.host, &request.method, request.request, authority)
                .await;
        }
        if method == "agent/parent/set" && !matches!(grant, Grant::Peer { .. }) {
            let mut value = params;
            let caller: Caller = decode(
                value
                    .as_object_mut()
                    .context("invalid parent request")?
                    .remove("caller")
                    .unwrap_or(json!({"kind":"operator"})),
            )?;
            let authority = self.cluster_authority(&caller).await?;
            value["callerAuthority"] = json!(authority);
            value["protocol"] = json!(PROTOCOL);
            let request: ParentParams = decode(value)?;
            ensure!(
                request.agent.host_id == identity.host_id,
                "parent update must be sent to the owning host"
            );
            return self.set_cluster_parent(request).await;
        }
        let Grant::Peer {
            host,
            membership,
            digest,
        } = grant
        else {
            bail!("this cluster method requires an authenticated member");
        };
        ensure!(
            link.store.valid(host, membership, digest).await?,
            "membership was removed"
        );
        ensure!(
            params["protocol"].as_u64() == Some(PROTOCOL as u64),
            "unsupported cluster protocol"
        );
        match method {
            "cluster/hello" => {
                let request: HelloParams = decode(params)?;
                ensure!(
                    request.host == *host,
                    "hello host differs from its credential"
                );
                crate::cluster::members::validate_uuid(&request.incarnation)?;
                self.reconcile_member_incarnation(host, &request.incarnation)
                    .await?;
                link.wake_member(host).await;
                self.jobs.dirty();
                Ok(json!(HelloReceipt {
                    protocol: PROTOCOL,
                    host: identity.host_id,
                    incarnation: identity.incarnation,
                    capabilities: CAPABILITIES.iter().map(|value| (*value).into()).collect(),
                    routes: link
                        .endpoint()
                        .await
                        .map(|value| value.0)
                        .unwrap_or_default(),
                    load: self.cluster_load().await?,
                    version: version().into()
                }))
            }
            "cluster/removed" => {
                let request: RemoveParams = decode(params)?;
                ensure!(
                    request.host == *host && request.membership == *membership,
                    "removal differs from its credential"
                );
                link.store.remove(request, false).await?;
                link.forget(membership).await;
                self.remove_member_work(membership, host).await?;
                Ok(json!({"removed":true}))
            }
            "cluster/forward" => {
                let request: ForwardParams = decode(params)?;
                validate_authority(&request.caller_authority)?;
                let method = request.request["method"]
                    .as_str()
                    .context("forwarded method is required")?;
                let params = request.request["params"].clone();
                match method {
                    "model/list" => self.model_list(params).await.map_err(Into::into),
                    "thread/read"
                        if crate::providers::claude::is_claude_thread_id(
                            params["threadId"].as_str().unwrap_or_default(),
                        ) =>
                    {
                        self.claude_thread_response(&params)
                            .await
                            .map_err(Into::into)
                    }
                    "thread/items/list" | "thread/turns/list" => {
                        self.cluster_history_page(method, params).await
                    }
                    "thread/read" => {
                        let mut result = self.job_native_call(method, params).await?;
                        self.apply_parent_tags(&mut result).await?;
                        Ok(result)
                    }
                    _ => bail!("forwarded method is not a supported read"),
                }
            }
            "agent/jobs/admit" => {
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
                    host: host.clone(),
                    membership: membership.clone(),
                    incarnation: remote_incarnation(&request.recipient, host)?,
                    authority: request.caller_authority.clone(),
                };
                let origin = self.resolve_job_caller(&caller).await?;
                ensure!(
                    origin == request.origin,
                    "remote origin differs from the caller proven by its member"
                );
                ensure!(match (&request.caller_authority,&request.recipient) {
                    (CallerAuthority::Operator,Recipient::None)=>true,
                    (CallerAuthority::Agent {conversation,..},Recipient::Remote {host:receiver,conversation:target,..})=>receiver==host && target==conversation,
                    _=>false,
                },"remote recipient differs from its proven caller");
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
            "agent/jobs/deliver" => {
                let request: DeliverParams = decode(params)?;
                if request.incarnation != identity.incarnation {
                    return Err(cluster_error(
                        ErrorClass::Uncertain,
                        "recipient incarnation changed; prior delivery cannot be reconciled",
                    )
                    .into());
                }
                self.jobs
                    .gateway()?
                    .deliver_job_input(
                        &request.conversation,
                        &request.delivery_id,
                        &request.text,
                        None,
                    )
                    .await
                    .map_err(Into::into)
            }
            "agent/jobs/stop" => {
                let request: crate::wire::cluster::StopParams = decode(params)?;
                let fence = CancelFence {
                    protocol: PROTOCOL,
                    host: host.clone(),
                    membership: membership.clone(),
                    job_id: request.job_id.clone(),
                    at: (crate::time::unix_seconds() * 1000.0) as i64,
                };
                let job = self.jobs.store().await?.cancel_remote(fence).await?;
                self.jobs.dirty();
                Ok(
                    json!({"jobId":request.job_id,"state":if job.is_some(){"stop_requested"}else{"cancelled"}}),
                )
            }
            "agent/parent/resolve" => {
                let address: AgentAddress = decode(params["agent"].clone())?;
                ensure!(
                    address.host_id == identity.host_id,
                    "parent resolve names another host"
                );
                Ok(json!({"conversation":self.agent_conversation(&address.thread_id)?}))
            }
            "agent/parent/read" => {
                let address: AgentAddress = decode(params["agent"].clone())?;
                ensure!(
                    address.host_id == identity.host_id,
                    "parent read names another host"
                );
                Ok(
                    json!({"parent":self.agent_service().parent_for_thread(&address.thread_id).await?}),
                )
            }
            "agent/parent/set" => self.set_cluster_parent(decode(params)?).await,
            "agent/conversation/operate" => {
                let request: ForwardParams = decode(params)?;
                let mut operation = request.request;
                operation
                    .as_object_mut()
                    .context("invalid native operation")?
                    .remove("caller");
                let caller = Caller::Forwarded {
                    admission_fingerprint: None,
                    host: host.clone(),
                    membership: membership.clone(),
                    incarnation: request.incarnation,
                    authority: request.caller_authority,
                };
                self.native_conversation_operation(operation, caller).await
            }
            "agent/jobs/read" | "agent/jobs/list" | "agent/jobs/message" => {
                let request: ForwardParams = decode(params)?;
                validate_authority(&request.caller_authority)?;
                let caller = Caller::Forwarded {
                    admission_fingerprint: None,
                    host: host.clone(),
                    membership: membership.clone(),
                    incarnation: request.incarnation,
                    authority: request.caller_authority,
                };
                match method {
                    "agent/jobs/message" => {
                        let mut request: agent_jobs::MessageParams = decode(request.request)?;
                        request.caller = caller;
                        self.job_message(request).await.map_err(Into::into)
                    }
                    _ => self
                        .agent_jobs_rpc(method, request.request)
                        .await
                        .map_err(Into::into),
                }
            }
            _ => bail!("unsupported cluster member method"),
        }
    }

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

    pub(super) fn inherit_job_scope(
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

    async fn forward_cluster(
        &self,
        host: &str,
        method: &str,
        request: Value,
        authority: CallerAuthority,
    ) -> Result<Value> {
        validate_authority(&authority)?;
        let link = self.cluster_link().await?;
        let member = link.store.resolve(host).await.map_err(|error|cluster_error(ErrorClass::Usage,error.to_string()))?;
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

    async fn send_remote_intent(&self, intent: RemoteIntent, initial: bool) -> Result<Value> {
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

    async fn reconcile_member_incarnation(&self, host: &str, incarnation: &str) -> Result<()> {
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

    async fn remove_member_work(&self, membership: &str, host: &str) -> Result<()> {
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

    pub(super) async fn authorize_existing(&self, id: &str, caller: &Caller) -> Result<()> {
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

    pub(super) async fn authorize_conversation(
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

    async fn cluster_load(&self) -> Result<HostLoad> {
        let store = self.jobs.store().await?;
        let mut active = 0;
        for agent in store.agent_rows().await? {
            if let Some(id) = agent.latest_job_id
                && !matches!(
                    store.read(id).await?.execution,
                    ExecutionState::Terminal { .. } | ExecutionState::Unknown { .. }
                )
            {
                active += 1;
            }
        }
        let (cpu_percent, memory_pressure) = tokio::task::spawn_blocking(|| {
            let cores = std::thread::available_parallelism()
                .ok()
                .map(|value| value.get() as f64);
            let cpu = std::process::Command::new("/bin/ps")
                .args(["-A", "-o", "%cpu="])
                .output()
                .ok()
                .filter(|output| output.status.success())
                .and_then(|output| String::from_utf8(output.stdout).ok())
                .and_then(|output| {
                    output
                        .split_whitespace()
                        .map(str::parse::<f64>)
                        .collect::<std::result::Result<Vec<_>, _>>()
                        .ok()
                })
                .and_then(|values| cores.map(|cores| values.iter().sum::<f64>() / cores));
            let pressure = std::process::Command::new("/usr/sbin/sysctl")
                .args(["-n", "kern.memorystatus_vm_pressure_level"])
                .output()
                .ok()
                .filter(|output| output.status.success())
                .and_then(|output| String::from_utf8(output.stdout).ok())
                .and_then(|value| match value.trim() {
                    "1" => Some(MemoryPressure::Normal),
                    "2" => Some(MemoryPressure::Warn),
                    "4" => Some(MemoryPressure::Critical),
                    _ => None,
                });
            (cpu, pressure)
        })
        .await?;
        Ok(HostLoad {
            cpu_percent,
            memory_pressure,
            active_agents: u32::try_from(active)?,
        })
    }
}

fn public_member(record: &MemberRecord) -> Value {
    json!({"hostId":record.host,"name":record.name,"membership":record.membership,"state":record.state,"routes":record.routes})
}
fn check_steering_scope(authority: &CallerAuthority, target: Option<&ToolScope>) -> Result<()> {
    if let CallerAuthority::Agent {
        scope: ToolScope::ReadOnly { root },
        ..
    } = authority
    {
        ensure!(
            matches!(target,Some(ToolScope::ReadOnly {root:target}) if target.starts_with(root)),
            "read-only caller cannot steer a conversation outside its scope"
        );
    }
    Ok(())
}
fn validate_authority(authority: &CallerAuthority) -> Result<()> {
    if let CallerAuthority::Agent { conversation, .. } = authority {
        ensure!(
            !conversation.thread_id.is_empty(),
            "caller conversation is empty"
        );
    }
    Ok(())
}
fn remote_incarnation(recipient: &Recipient, host: &str) -> Result<String> {
    match recipient {
        Recipient::Remote {
            host: owner,
            incarnation,
            ..
        } if owner == host => Ok(incarnation.clone()),
        Recipient::None => Ok(String::new()),
        _ => bail!("remote recipient differs from its authenticated member"),
    }
}
fn admit_fingerprint(request: &AdmitParams) -> Result<String> {
    Ok(crate::agents::jobs::store::fingerprint(
        &serde_json::to_vec(&(
            request.protocol,
            &request.job_id,
            &request.incarnation,
            &request.origin,
            &request.recipient,
            &request.operation,
            &request.caller_authority,
        ))?,
    ))
}

impl Gateway {
    async fn set_cluster_parent(&self, request: ParentParams) -> Result<Value> {
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
                let native_parent = super::agent_gateway::native_parent(&header["thread"]);
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
            next = if parent.host_id == identity.host_id {
                self.agent_service()
                    .parent_for_thread(&parent.thread_id)
                    .await?
            } else {
                let response = link
                    .call(
                        &parent.host_id,
                        "agent/parent/read",
                        json!({"protocol":PROTOCOL,"agent":parent}),
                    )
                    .await
                    .map_err(|error| cluster_error(ErrorClass::Unavailable, error.message))?;
                decode(response["parent"].clone())?
            };
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
                        json!({"protocol":PROTOCOL,"agent":parent}),
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
            .set_parent(agent.agent_id, request.parent, recipient)
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

    pub(super) async fn cluster_agents_rpc(&self, method: &str, params: Value) -> RpcResult {
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
        for agent in store.agent_rows().await? {
            let ConversationBinding::Known { conversation } = &agent.conversation else {
                continue;
            };
            let row_index = rows
                .iter()
                .position(|row| row.thread_id.as_deref() == Some(&conversation.thread_id));
            if agent.parent.as_ref() != Some(&parent) {
                if let Some(index) = row_index {
                    rows.remove(index);
                }
                continue;
            }
            let row = self.project_agent_record(&agent, &parent.thread_id).await?;
            if let Some(index) = row_index {
                rows[index] = row;
            } else {
                rows.push(row);
            }
        }
        if parent.host_id == identity.host_id {
            for intent in store.intents().await? {
                if intent.parent.as_ref() == Some(&parent) {
                    rows.push(intent_row(&intent)?);
                }
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
        use sha2::{Digest, Sha256};
        result["revision"] = json!(format!(
            "{:x}",
            Sha256::digest(serde_json::to_vec(&result["agents"]).map_err(RpcError::from)?)
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
        | ExecutionState::Bound { .. }
        | ExecutionState::RetryWaiting { .. } => crate::agents::State::Waiting,
        _ => crate::agents::State::Unknown,
    }
}

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ListCursor {
    positions: std::collections::BTreeMap<String, Option<String>>,
    complete: std::collections::BTreeSet<String>,
}

impl Gateway {
    async fn list_cluster_agents(&self, params: Value) -> Result<Value> {
        use base64::Engine;
        use futures_util::{StreamExt, stream};
        let limit = params["limit"].as_u64().unwrap_or(100);
        ensure!(
            (1..=10000).contains(&limit),
            "list limit must be between 1 and 10000"
        );
        let mut cursor: ListCursor = match params["cursor"].as_str() {
            Some(value) => {
                ensure!(value.len() <= 1024 * 1024, "list cursor exceeds capacity");
                serde_json::from_slice(
                    &base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(value)?,
                )?
            }
            None => ListCursor::default(),
        };
        let identity = self.host_identity().await?;
        let link = self.cluster_link().await?;
        let mut hosts = vec![identity.host_id.clone()];
        if params["local"] != true {
            hosts.extend(
                link.members()
                    .await?
                    .into_iter()
                    .filter(|member| member.state == MemberState::Active)
                    .map(|member| member.host),
            );
        }
        let pages=stream::iter(hosts.iter().cloned()).map(|host| {
            let position=cursor.positions.get(&host).cloned().flatten();
            let complete=cursor.complete.contains(&host);
            let identity=&identity;
            let link=&link;
            let params=&params;
            async move {
                if complete {return (host,Ok(json!({"agents":[],"nextCursor":null})));}
                let request=json!({"limit":limit.min(256),"cursor":position,"active":params["active"],"provider":params["provider"]});
                let page=if host==identity.host_id {self.local_agent_inventory(request).await.map_err(|error|crate::cluster::link::LinkError {class:ErrorClass::Unavailable,transmitted:false,message:error.to_string()})}else {link.call(&host,"agent/cluster/inventory",request).await};
                (host,page)
            }
        }).buffer_unordered(64).collect::<Vec<_>>().await;
        let mut coverage = Vec::new();
        let mut pages=pages.into_iter().filter_map(|(host,result)| match result {
            Err(error)=> {coverage.push(json!({"hostId":host,"state":match error.class {ErrorClass::Unsupported=>"unsupported",ErrorClass::Refused=>"refused",_=>"unreachable"}}));None}
            Ok(page)=> {coverage.push(json!({"hostId":host,"state":"ok"}));Some((host,page["agents"].as_array().cloned().unwrap_or_default().into_iter().collect::<std::collections::VecDeque<_>>(),page["nextCursor"].as_str().map(str::to_owned)))}
        }).collect::<Vec<_>>();
        pages.sort_by(|left, right| left.0.cmp(&right.0));
        let mut rows = Vec::new();
        loop {
            let mut consumed = false;
            for (host, page, _) in &mut pages {
                if rows.len() >= limit as usize {
                    break;
                }
                if let Some(entry) = page.pop_front() {
                    consumed = true;
                    cursor.positions.insert(
                        host.clone(),
                        entry["cursorAfter"].as_str().map(str::to_owned),
                    );
                    rows.push(entry["row"].clone());
                }
            }
            if !consumed || rows.len() >= limit as usize {
                break;
            }
        }
        for (host, page, next) in pages {
            if page.is_empty() {
                cursor.positions.insert(host.clone(), next.clone());
                if next.is_none() {
                    cursor.complete.insert(host);
                }
            }
        }
        coverage.sort_by_key(|row| row["hostId"].as_str().unwrap_or_default().to_owned());
        let next_cursor = if hosts.iter().any(|host| !cursor.complete.contains(host)) {
            Some(
                base64::engine::general_purpose::URL_SAFE_NO_PAD
                    .encode(serde_json::to_vec(&cursor)?),
            )
        } else {
            None
        };
        Ok(json!({"agents":rows,"coverage":coverage,"nextCursor":next_cursor,"warnings":[]}))
    }
}

impl Gateway {
    pub(super) async fn apply_parent_tags(&self, response: &mut Value) -> Result<bool> {
        if self.turn_state_path.is_none() {
            return Ok(false);
        }
        let host = self.host_identity().await?.host_id;
        let agents = self.jobs.store().await?.agent_rows().await?;
        let tags = agents
            .iter()
            .filter_map(|agent| match &agent.conversation {
                ConversationBinding::Known { conversation } if agent.parent_recipient.is_some() => {
                    Some((conversation.thread_id.as_str(), agent.parent.as_ref()))
                }
                _ => None,
            })
            .collect::<std::collections::HashMap<_, _>>();
        let mut changed = false;
        let mut apply = |thread: &mut Value| {
            let Some(id) = thread["id"].as_str() else {
                return;
            };
            let native_parent =
                super::agent_gateway::native_parent(thread).map(|thread| AgentAddress {
                    host_id: host.clone(),
                    thread_id: thread.to_owned(),
                });
            let parent = tags.get(id).copied().unwrap_or(native_parent.as_ref());
            thread["parent"] = json!(parent);
            thread["parentThreadId"] = json!(
                parent
                    .filter(|parent| parent.host_id == host)
                    .map(|parent| &parent.thread_id)
            );
            thread
                .as_object_mut()
                .expect("thread header is an object")
                .remove("parentHostID");
            changed = true;
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

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct InventoryCursor {
    jobs: Option<String>,
    sessions: Option<String>,
    jobs_done: bool,
    sessions_done: bool,
}

fn inventory_cursor(cursor: &InventoryCursor) -> Result<String> {
    use base64::Engine;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(serde_json::to_vec(cursor)?))
}

impl Gateway {
    async fn local_agent_inventory(&self, params: Value) -> Result<Value> {
        use base64::Engine;
        let limit = params["limit"].as_u64().unwrap_or(100);
        ensure!(
            (1..=1000).contains(&limit),
            "inventory limit must be between 1 and 1000"
        );
        let mut cursor: InventoryCursor = match params["cursor"].as_str() {
            Some(value) => {
                ensure!(value.len() <= 4096, "inventory cursor exceeds capacity");
                serde_json::from_slice(
                    &base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(value)?,
                )?
            }
            None => Default::default(),
        };
        let identity = self.host_identity().await?;
        let mut agents = Vec::new();
        if !cursor.jobs_done {
            let page = self
                .jobs
                .list(agent_jobs::ListParams {
                    selector: agent_jobs::ListSelector::Recent,
                    limit: 256.min(limit as u32),
                    cursor: cursor.jobs.clone(),
                })
                .await?;
            for row in page.jobs {
                cursor.jobs = Some(row.job_id.as_str().to_owned());
                if params["active"] == true && !row.active {
                    continue;
                }
                if let Some(provider) = params["provider"].as_str()
                    && provider != row.provider.as_str()
                {
                    continue;
                }
                let session = match &row.conversation {
                    ConversationBinding::Known { conversation } => {
                        Some(conversation.thread_id.clone())
                    }
                    _ => None,
                };
                agents.push(json!({"row":{"run_id":row.job_id,"agent_id":row.agent_id,"ownerHostId":identity.host_id,"parent":row.parent,"recipient":row.recipient,"provider":row.provider,"provider_session_id":session,"cwd":row.cwd,"model":row.model,"title":row.title,"state":row.state,"status":row.state,"created_at_epoch_ms":row.created_at_ms,"last_active_at_epoch_ms":row.updated_at_ms,"conversation":row.conversation},"cursorAfter":inventory_cursor(&cursor)?}));
            }
            cursor.jobs = page.next_cursor;
            cursor.jobs_done = cursor.jobs.is_none();
        }
        if cursor.jobs_done && agents.len() < limit as usize && !cursor.sessions_done {
            let page = self
                .session_inventory(
                    cursor.sessions.clone(),
                    (limit as usize - agents.len()).min(1000),
                )
                .await?;
            for session in page.sessions {
                cursor.sessions = Some(session.session_key.clone());
                if session.host_id != identity.host_id || !session.source_present {
                    continue;
                }
                let conversation = self.agent_conversation(&session.thread_id)?;
                let agent = self.jobs.agent_for_conversation(&conversation).await?;
                if agent
                    .as_ref()
                    .is_some_and(|agent| agent.latest_job_id.is_some())
                {
                    continue;
                }
                if params["active"] == true {
                    continue;
                }
                if let Some(provider) = params["provider"].as_str()
                    && provider != session.provider
                {
                    continue;
                }
                let parent = agent.as_ref().and_then(|agent| agent.parent.clone());
                let recipient = agent
                    .as_ref()
                    .and_then(|agent| agent.parent_recipient.clone());
                agents.push(json!({"row":{"run_id":null,"agent_id":agent.as_ref().map(|agent|&agent.agent_id),"ownerHostId":identity.host_id,"parent":parent,"recipient":recipient,"provider":session.provider,"provider_session_id":session.thread_id,"cwd":session.cwd,"model":null,"title":session.title.unwrap_or_else(||"Agent".into()),"state":"unknown","status":"unknown","created_at":session.started_at,"last_active_at":session.last_at,"conversation":ConversationBinding::Known {conversation}},"cursorAfter":inventory_cursor(&cursor)?}));
            }
            cursor.sessions = page.cursor;
            cursor.sessions_done = cursor.sessions.is_none();
        }
        let next = if cursor.jobs_done && cursor.sessions_done {
            None
        } else {
            Some(inventory_cursor(&cursor)?)
        };
        Ok(json!({"agents":agents,"nextCursor":next}))
    }
}

impl Gateway {
    async fn resolve_local_agent(&self, target: &str) -> Result<Option<Value>> {
        ensure!(
            target.len() >= 4 && target.len() <= 512,
            "use an exact identity or a suffix of at least four characters"
        );
        let identity = self.host_identity().await?;
        if let Ok(id) = JobId::try_from(target.to_owned())
            && let Ok(view) = self.jobs.read(&id).await
        {
            return Ok(Some(
                json!({"ownerHostId":identity.host_id,"jobId":view.job.job_id,"agentId":view.job.agent_id,"conversation":view.agent.map(|agent|agent.conversation)}),
            ));
        }
        let mut cursor = None;
        let mut found = std::collections::BTreeMap::<String, Value>::new();
        loop {
            let page = self
                .jobs
                .list(agent_jobs::ListParams {
                    selector: agent_jobs::ListSelector::Recent,
                    limit: 256,
                    cursor,
                })
                .await?;
            for row in page.jobs {
                let session = match &row.conversation {
                    ConversationBinding::Known { conversation } => {
                        Some(conversation.thread_id.as_str())
                    }
                    _ => None,
                };
                if row.job_id.as_str().ends_with(target)
                    || session.is_some_and(|thread| {
                        thread == target || thread.strip_prefix("claude_") == Some(target)
                    })
                {
                    let view = self.jobs.read(&row.job_id).await?;
                    let selected = if row.job_id.as_str().ends_with(target) {
                        row.job_id
                    } else {
                        view.agent
                            .as_ref()
                            .and_then(|agent| agent.latest_job_id.clone())
                            .context("conversation latest job is unresolved")?
                    };
                    found.insert(row.agent_id.clone(),json!({"ownerHostId":identity.host_id,"jobId":selected,"agentId":row.agent_id,"conversation":row.conversation}));
                    if found.len() > 1 {
                        return Err(cluster_error(
                            ErrorClass::Usage,
                            "agent selector is ambiguous; use an exact address",
                        )
                        .into());
                    }
                }
            }
            cursor = page.next_cursor;
            if cursor.is_none() {
                break;
            }
        }
        if let Some(row) = found.into_values().next() {
            return Ok(Some(row));
        }
        let mut cursor = None;
        let mut found = None;
        loop {
            let page = self.session_inventory(cursor, 1000).await?;
            for session in page.sessions {
                if session.host_id == identity.host_id
                    && session.source_present
                    && (session.thread_id == target || session.thread_id.ends_with(target))
                {
                    if found.is_some() {
                        return Err(cluster_error(
                            ErrorClass::Usage,
                            "conversation selector is ambiguous; use an exact address",
                        )
                        .into());
                    }
                    found = Some(
                        json!({"ownerHostId":identity.host_id,"threadId":session.thread_id,"jobId":null,"kind":"native"}),
                    );
                }
            }
            cursor = page.cursor;
            if cursor.is_none() {
                break;
            }
        }
        Ok(found)
    }

    async fn resolve_cluster_agent(&self, params: Value, peer: bool) -> Result<Value> {
        use futures_util::{StreamExt, stream};
        let target = params["target"].as_str().context("target is required")?;
        if let Some(found) = self.resolve_local_agent(target).await? {
            return Ok(found);
        }
        if peer || params["local"] == true {
            return Err(
                cluster_error(ErrorClass::NotFound, "agent was not found on this host").into(),
            );
        }
        let link = self.cluster_link().await?;
        let replies = stream::iter(
            link.members()
                .await?
                .into_iter()
                .filter(|member| member.state == MemberState::Active),
        )
        .map(|member| {
            let link = &link;
            async move {
                (
                    member.host.clone(),
                    link.call(
                        &member.host,
                        "agent/cluster/resolve",
                        json!({"target":target,"local":true}),
                    )
                    .await,
                )
            }
        })
        .buffer_unordered(64)
        .collect::<Vec<_>>()
        .await;
        let mut matches = Vec::new();
        let mut coverage = Vec::new();
        let mut incomplete = false;
        for (host, result) in replies {
            match result {
                Ok(row) => {
                    coverage.push(json!({"hostId":host,"state":"ok"}));
                    matches.push(row);
                }
                Err(error) if error.class == ErrorClass::NotFound => {
                    coverage.push(json!({"hostId":host,"state":"ok"}))
                }
                Err(error) => {
                    incomplete = true;
                    coverage.push(json!({"hostId":host,"state":match error.class {ErrorClass::Unsupported=>"unsupported",ErrorClass::Refused=>"refused",_=>"unreachable"}}));
                }
            }
        }
        if matches.len() > 1 {
            return Err(cluster_error(
                ErrorClass::Usage,
                "agent selector matches multiple hosts; use host:id",
            )
            .with_data(RpcData::Raw(
                json!({"class":ErrorClass::Usage,"candidates":matches,"coverage":coverage}),
            ))
            .into());
        }
        if incomplete {
            return Err(cluster_error(
                ErrorClass::Unavailable,
                "agent resolution has incomplete cluster coverage; use host:id",
            )
            .with_data(RpcData::Raw(
                json!({"class":ErrorClass::Unavailable,"coverage":coverage}),
            ))
            .into());
        }
        matches.pop().ok_or_else(|| {
            cluster_error(ErrorClass::NotFound, "agent was not found in the cluster").into()
        })
    }
}

impl Gateway {
    async fn native_conversation_operation(&self, request: Value, caller: Caller) -> Result<Value> {
        let thread = request["threadId"]
            .as_str()
            .context("threadId is required")?;
        let conversation = self.agent_conversation(thread)?;
        let origin = self.resolve_job_caller(&caller).await?;
        ensure!(
            !matches!(origin, Origin::Unknown { .. }),
            "caller is unproven"
        );
        let action = request["action"].as_str().context("action is required")?;
        if matches!(action, "message" | "stop" | "continue") {
            self.authorize_conversation(&caller, &conversation).await?;
        }
        match action {
            "read"=> {
                let mut result=if conversation.provider==crate::agents::jobs::model::Provider::Claude {self.claude_thread_response(&json!({"threadId":thread})).await?}else{self.job_native_call("thread/read",json!({"threadId":thread,"includeTurns":false})).await?};
                self.apply_parent_tags(&mut result).await?;
                Ok(result)
            }
            "items"=>self.cluster_history_page("thread/items/list",json!({"threadId":thread,"limit":100,"sortDirection":"asc"})).await,
            "message"=> {
                let delivery_id=request["input"]["deliveryId"].as_str().context("deliveryId is required")?.to_owned();
                let text=request["input"]["text"].as_str().context("text is required")?.to_owned();
                self.job_message(agent_jobs::MessageParams {target:agent_jobs::MessageTarget::Conversation {conversation},caller,delivery_id,text}).await.map_err(Into::into)
            }
            "stop"=> {
                if conversation.provider==crate::agents::jobs::model::Provider::Claude {
                    let turn=self.claude_active_turn_id(thread).await.context("conversation has no known active turn")?;
                    self.stop_claude_turn(thread,&turn).await?;
                    Ok(json!({"stopped":true,"threadId":thread,"turnId":turn}))
                } else {
                    let turn=self.latest_codex_turn(thread,Some(std::time::Duration::from_secs(3))).await?.context("conversation has no known active turn")?;
                    let turn=turn["id"].as_str().context("active turn has no identity")?;
                    self.interrupt_codex_turn(json!({"threadId":thread,"turnId":turn})).await.map_err(Into::into)
                }
            }
            "continue"=>Err(cluster_error(ErrorClass::Unsupported,"native conversation permission evidence is unavailable; continue through its owning native client").into()),
            _=>Err(cluster_error(ErrorClass::Usage,"unsupported native conversation action").into()),
        }
    }

    pub(in crate::gateway) async fn cluster_history_page(
        &self,
        method: &str,
        params: Value,
    ) -> Result<Value> {
        let thread = params["threadId"]
            .as_str()
            .context("threadId is required")?
            .to_owned();
        if !crate::providers::claude::is_claude_thread_id(&thread) {
            return self.job_native_call(method, params).await;
        }
        let request = if method == "thread/items/list" {
            crate::rpc::HistoryPageRequest::Items(decode(params)?)
        } else {
            crate::rpc::HistoryPageRequest::Turns(decode(params)?)
        };
        let active = self.claude_active_turn_id(&thread).await;
        let (page, _) = self
            .claude_history
            .read_projection(&thread, active, move |projection, file, _| match &request {
                crate::rpc::HistoryPageRequest::Items(params) => {
                    projection.items_page(file, params)
                }
                crate::rpc::HistoryPageRequest::Turns(params) => {
                    projection.turns_page(file, params)
                }
            })
            .await?;
        Ok(page)
    }
}

impl Gateway {
    pub(super) async fn validate_member_grant(
        &self,
        grant: &Grant,
    ) -> std::result::Result<(), RpcError> {
        if let Grant::Peer {
            host,
            membership,
            digest,
        } = grant
        {
            if !self
                .cluster_link()
                .await?
                .store
                .valid(host, membership, digest)
                .await?
            {
                return Err(cluster_error(ErrorClass::Refused, "membership was removed"));
            }
        }
        Ok(())
    }
}

impl Gateway {
    pub(crate) async fn remote_receiver_active(&self, host: &str) -> Result<bool> {
        Ok(self
            .cluster_link()
            .await?
            .store
            .all()
            .await?
            .iter()
            .any(|member| member.host == host && member.state == MemberState::Active))
    }

    pub(crate) async fn surface_job_result(&self, id: &JobId, reason: &str) -> Result<()> {
        use crate::agents::jobs::model::Attention;
        let store = self.jobs.store().await?;
        let job = store
            .attention(
                id.clone(),
                Attention::Pending {
                    reason: reason.to_owned(),
                },
            )
            .await?;
        let Some(Attention::Pending { reason }) = &job.attention else {
            return Ok(());
        };
        let identity = self.host_identity().await?;
        let thread = job
            .execution
            .conversation()
            .map(|conversation| conversation.thread_id.as_str());
        let payload = json!({"ownerHostId":identity.host_id,"jobId":id,"reason":reason,"eventID":format!("{}:{id}:result-attention",identity.host_id),"source":"agentResult","sessionID":thread,"createdAtUnixSeconds":crate::time::unix_seconds()});
        self.broadcast_json_or_drop(
            &json!({"method":"agent/jobs/attention","params":payload}),
            crate::observability::journal::Source::Gateway,
        )?;
        self.journal
            .runtime("agent_result_attention", payload.clone());
        if self.apns.check_alert_registration("alert").await.is_ok() {
            self.apns
                .send_task_completion(
                    &format!("job:{id}"),
                    "Agent result needs attention",
                    "",
                    reason,
                    &payload,
                )
                .await;
        }
        store
            .attention(
                id.clone(),
                Attention::Surfaced {
                    reason: reason.clone(),
                },
            )
            .await?;
        Ok(())
    }
}

fn runtime_row(owner: &str, root: &str, view: &agent_jobs::JobView) -> Agent {
    let state = job_state(&view.job);
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
    async fn project_agent_record(
        &self,
        agent: &crate::agents::jobs::model::AgentRecord,
        root: &str,
    ) -> Result<Agent> {
        let identity = self.host_identity().await?;
        if let Some(id) = &agent.latest_job_id {
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
            thread_id: "parent".into(),
        };
        let agent = AgentRecord {
            agent_id: "native-agent".into(),
            parent: Some(address.clone()),
            parent_revision: 0,
            parent_recipient: Some(Recipient::None),
            conversation: ConversationBinding::Known {
                conversation: gateway.agent_conversation("native-thread").unwrap(),
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
