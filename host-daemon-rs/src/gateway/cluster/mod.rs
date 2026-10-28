mod admission;
mod agents;
mod conversations;
mod inventory;
mod membership;
mod parents;

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::Gateway;
use crate::agents::jobs::model::{
    ConversationBinding, ConversationIdentity, ExecutionState, JobId, Origin, Recipient, ToolScope,
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
        let result = Box::pin(self.cluster_request(grant, method, params)).await;
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
            link.refresh_members().await?;
            return Ok(
                json!({"self":{"hostId":identity.host_id,"name":self.job_host_name()?,"incarnation":identity.incarnation,"version":version(),"protocol":PROTOCOL},"members":link.members().await?}),
            );
        }
        if matches!(
            method,
            "cluster/issue" | "cluster/accept" | "cluster/remove" | "cluster/reset-identity"
        ) {
            return self.membership_request(grant, method, params).await;
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
            let result = if method == "agent/cluster/inventory" {
                self.local_agent_inventory(params).await
            } else {
                self.resolve_cluster_agent(params, matches!(grant, Grant::Peer { .. }))
                    .await
            };
            return result.map_err(|error| {
                if error.is::<RpcError>() || error.is::<crate::cluster::link::LinkError>() {
                    error
                } else {
                    cluster_error(ErrorClass::Unavailable, format!("{error:#}")).into()
                }
            });
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
            "agent/jobs/admit" => self.admit_remote(host, membership, params).await,
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
