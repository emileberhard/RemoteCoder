use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::{Mutex, oneshot};
use tokio_util::sync::CancellationToken;

use super::{ClientTx, Gateway};
use crate::agents::jobs::model::Provider;
use crate::agents::jobs::routes::NativeDeliveryState;
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};
use crate::wire::agent_jobs::Caller;

#[derive(Default)]
pub(super) struct ParentHolders {
    connections: Mutex<HashMap<u64, Holder>>,
    tasks: crate::tasks::owned_tasks::OwnedTasks,
}

struct Holder {
    route_id: String,
    closed: CancellationToken,
    pending: Option<(String, oneshot::Sender<NativeDeliveryState>)>,
}

impl ParentHolders {
    pub(super) async fn stop(&self) {
        self.tasks.stop().await;
        self.connections.lock().await.clear();
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Registration {
    caller: Caller,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Acknowledgement {
    route_id: String,
    attempt_id: String,
    state: NativeDeliveryState,
}

impl Gateway {
    pub(super) async fn agent_routes_rpc(
        self: &Arc<Self>,
        client_id: u64,
        out: &ClientTx,
        method: &str,
        params: Value,
    ) -> RpcResult {
        match method {
            "agent/routes/register" => {
                if self.is_draining() {
                    return Err(RpcError::draining());
                }
                let request: Registration = serde_json::from_value(params)
                    .map_err(|error| RpcError::new(RpcCode::InvalidParams, error.to_string()))?;
                self.resolve_job_caller(&request.caller).await?;
                let Caller::Captured { context_id } = request.caller else {
                    return Err(RpcError::new(
                        RpcCode::InvalidParams,
                        "native parent routes require a captured process identity",
                    ));
                };
                let proven = self.jobs.contexts.get(&context_id).await?;
                if proven.conversation.provider != Provider::Claude {
                    return Err(RpcError::new(
                        RpcCode::InvalidParams,
                        "native parent routes are Claude-only",
                    ));
                }
                let provider = self.job_claude()?;
                if provider
                    .owned_process_session(proven.process.pid, proven.process.started_micros)
                    .await
                    .is_some()
                {
                    return Ok(json!({"kind":"gatewayOwned"}));
                }
                let owner = crate::providers::claude::native_parent::prove_owner(
                    &self.claude_settings.claude_home,
                    proven.process.pid,
                    proven.process.started_micros,
                )
                .await?
                .context("native parent process no longer owns its inbox")?;
                if crate::providers::claude::claude_thread_id(&owner.session_uuid)
                    != proven.conversation.thread_id
                {
                    return Err(RpcError::new(
                        RpcCode::Conflict,
                        "native parent identity changed during registration",
                    ));
                }
                provider
                    .record_native_parent(&proven.conversation.thread_id)
                    .await?;
                let (lease, mut requests) = self
                    .jobs
                    .native_routes
                    .register(proven.conversation, proven.process)?;
                let route_id = crate::ids::new_session_uuid();
                let closed = out.closed.child_token();
                let previous = self.job_routes.connections.lock().await.insert(
                    client_id,
                    Holder {
                        route_id: route_id.clone(),
                        closed: closed.clone(),
                        pending: None,
                    },
                );
                if let Some(previous) = previous {
                    previous.closed.cancel();
                }
                let gateway = Arc::clone(self);
                let out = out.clone();
                let owned_id = route_id.clone();
                let admitted = self.job_routes.tasks.spawn_graceful("native_parent_route", move |shutdown| async move {
                    let _lease = lease;
                    loop {
                        let request = tokio::select! {
                            _ = shutdown.cancelled() => break,
                            _ = closed.cancelled() => break,
                            request = requests.recv() => match request { Some(request) => request, None => break },
                        };
                        let attempt_id = crate::ids::new_session_uuid();
                        let (ack, result) = oneshot::channel();
                        {
                            let mut holders = gateway.job_routes.connections.lock().await;
                            let Some(holder) = holders.get_mut(&client_id).filter(|holder| holder.route_id == owned_id) else { break; };
                            holder.pending = Some((attempt_id.clone(), ack));
                        }
                        let outcome = tokio::time::timeout(Duration::from_secs(8), async {
                            gateway.send_json_awaiting_capacity(&out, &json!({"method":"agent/routes/deliver","params":{"routeId":owned_id,"attemptId":attempt_id,"message":request.message}})).await?;
                            tokio::select! {
                                _ = shutdown.cancelled() => anyhow::bail!("gateway stopped before native acknowledgement"),
                                _ = closed.cancelled() => anyhow::bail!("holder connection closed before acknowledgement"),
                                result = result => Ok::<_, anyhow::Error>(result?),
                            }
                        }).await;
                        let state = match outcome {
                            Ok(Ok(state)) => state,
                            _ => NativeDeliveryState::Uncertain { reason: "native holder did not acknowledge this exact attempt; reconcile canonical input evidence before retry".into() },
                        };
                        let _ = request.reply.send(state);
                        let mut holders = gateway.job_routes.connections.lock().await;
                        if let Some(holder) = holders.get_mut(&client_id).filter(|holder| holder.route_id == owned_id) { holder.pending = None; }
                    }
                    let mut holders = gateway.job_routes.connections.lock().await;
                    if holders.get(&client_id).is_some_and(|holder| holder.route_id == owned_id) { holders.remove(&client_id); }
                    Ok(())
                });
                if !admitted {
                    self.job_routes.connections.lock().await.remove(&client_id);
                    return Err(RpcError::draining());
                }
                self.jobs.dirty();
                Ok(json!({"kind":"native","routeId":route_id}))
            }
            "agent/routes/ack" => {
                let request: Acknowledgement = serde_json::from_value(params)
                    .map_err(|error| RpcError::new(RpcCode::InvalidParams, error.to_string()))?;
                let mut holders = self.job_routes.connections.lock().await;
                let Some(holder) = holders
                    .get_mut(&client_id)
                    .filter(|holder| holder.route_id == request.route_id)
                else {
                    return Err(RpcError::new(
                        RpcCode::Conflict,
                        "native route is no longer owned by this connection",
                    ));
                };
                if !holder
                    .pending
                    .as_ref()
                    .is_some_and(|(attempt, _)| attempt == &request.attempt_id)
                {
                    return Err(RpcError::new(
                        RpcCode::Conflict,
                        "native delivery attempt is no longer pending",
                    ));
                }
                let (_, reply) = holder
                    .pending
                    .take()
                    .context("native attempt disappeared")?;
                let _ = reply.send(request.state);
                Ok(json!({"acknowledged":true}))
            }
            _ => Err(RpcError::new(
                RpcCode::MethodNotFound,
                "unknown native parent route method",
            )),
        }
    }
}
