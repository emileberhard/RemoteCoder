use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::{Value, json};

use super::Gateway;
use crate::agents::jobs::context::ProvenCaller;
use crate::agents::jobs::model::{
    ConversationBinding, ConversationIdentity, ExecutionState, JobId, Origin, Provider,
    ProviderHome, Recipient,
};
use crate::platform::process::{ProcessInstance, ancestry};
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};
use crate::wire::agent_jobs::*;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NativeToolContext {
    thread_id: String,
    turn_id: String,
    tool_call_id: String,
    root_process_identity: NativeProcessIdentity,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NativeProcessIdentity {
    pid: i32,
    started_at_unix_micros: u64,
}

impl Gateway {
    pub(crate) fn job_coordination_socket(&self, id: &JobId) -> std::path::PathBuf {
        self.jobs.coordination_socket(id)
    }

    pub(crate) fn job_host_name(&self) -> Result<String> {
        let host = nix::unistd::gethostname()?;
        Ok(host
            .to_str()
            .context("host name is not UTF-8")?
            .split('.')
            .next()
            .context("host name is empty")?
            .to_owned())
    }

    pub(crate) fn job_claude(
        &self,
    ) -> Result<std::sync::Arc<crate::providers::claude::ClaudeSupervisor>> {
        self.claude_agent()
            .context("Claude provider is unavailable")
    }

    pub(crate) fn job_new_claude_conversation(&self) -> ConversationIdentity {
        ConversationIdentity {
            provider: Provider::Claude,
            provider_home: ProviderHome::Known {
                path: self.claude_settings.claude_home.clone(),
            },
            thread_id: crate::providers::claude::claude_thread_id(&crate::ids::new_session_uuid()),
        }
    }

    pub(crate) async fn job_provider_recovery_complete(&self, provider: Provider) -> Result<bool> {
        match provider {
            Provider::Codex => Ok(!self.codex_recovery_pending().await),
            Provider::Claude => self.claude_recovery_complete().await,
        }
    }

    pub(crate) async fn agent_jobs_rpc(&self, method: &str, params: Value) -> RpcResult {
        fn decode<T: serde::de::DeserializeOwned>(params: Value) -> Result<T, RpcError> {
            serde_json::from_value(params)
                .map_err(|error| RpcError::new(RpcCode::InvalidParams, error.to_string()))
        }
        match method {
            "agent/context/capture" => Ok(json!(self.capture_job_context(decode(params)?).await?)),
            "agent/context/read" => {
                let request: ContextReadParams = decode(params)?;
                Ok(json!(self.job_context_view(request.caller).await?))
            }
            "agent/context/setTitle" => {
                let request: SetTitleParams = decode(params)?;
                let view = self.job_context_view(request.caller).await?;
                self.jobs
                    .gateway()?
                    .rename_thread(
                        &json!({"threadId":view.conversation.thread_id,"name":request.title}),
                    )
                    .await
            }
            "agent/jobs/start" => {
                if self.is_draining() {
                    return Err(RpcError::draining());
                }
                let request: StartParams = decode(params)?;
                let origin = self.resolve_job_caller(&request.caller).await?;
                Ok(json!(self.jobs.start(request, origin).await?))
            }
            "agent/jobs/continue" => {
                if self.is_draining() {
                    return Err(RpcError::draining());
                }
                let request: ContinueParams = decode(params)?;
                let origin = self.resolve_job_caller(&request.caller).await?;
                Ok(json!(self.jobs.continue_job(request, origin).await?))
            }
            "agent/jobs/read" => {
                let request: ReadParams = decode(params)?;
                Ok(json!(self.jobs.read(&request.job_id).await?))
            }
            "agent/jobs/list" => {
                let request: ListParams = decode(params)?;
                match &request.selector {
                    ListSelector::Caller { caller } => match self.resolve_job_caller(caller).await?
                    {
                        Origin::Parent { conversation } => Ok(json!(
                            self.jobs
                                .children(&conversation, request.limit, request.cursor)
                                .await?
                        )),
                        _ => Err(RpcError::new(
                            RpcCode::InvalidParams,
                            "caller-scoped listing requires an agent identity",
                        )),
                    },
                    _ => Ok(json!(self.jobs.list(request).await?)),
                }
            }
            "agent/jobs/stop" => Ok(json!(self.jobs.stop(decode(params)?).await?)),
            "agent/jobs/dismiss" => Ok(json!(self.jobs.dismiss(decode(params)?).await?)),
            "agent/jobs/message" => self.job_message(decode(params)?).await,
            _ => Err(RpcError::new(
                RpcCode::MethodNotFound,
                "Unknown delegated-agent method",
            )),
        }
    }

    pub(crate) async fn job_native_call(&self, method: &str, params: Value) -> Result<Value> {
        self.call_control(method, params).await
    }

    pub(crate) fn job_codex_home(&self) -> Result<std::path::PathBuf> {
        Ok(self.codex.provider_home()?.to_owned())
    }

    pub(crate) async fn job_inspect_turn(&self, thread: &str, turn: &str) -> crate::rpc::RpcResult {
        self.inspect_execution(json!({"threadId":thread,"turnId":turn}))
            .await
    }

    pub(crate) async fn job_process_context(
        &self,
        process: ProcessInstance,
    ) -> Result<ProvenCaller> {
        let chain = tokio::task::spawn_blocking(move || ancestry(process)).await??;
        ensure!(
            !chain.is_empty(),
            "caller has no verifiable process ancestry"
        );
        let native = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            self.call_control(
                "daemon/toolContext",
                json!({"pid":process.pid,"startedAtUnixMicros":process.started_micros}),
            ),
        )
        .await
        .unwrap_or_else(|_| Err(anyhow::anyhow!("native caller identity lookup timed out")));
        let (native, native_failure) = match native {
            Ok(value) => (
                serde_json::from_value::<Option<NativeToolContext>>(
                    value
                        .get("context")
                        .cloned()
                        .context("native caller context reply has no context field")?,
                )?,
                None,
            ),
            Err(error) => (None, Some(error)),
        };
        let native_position = native
            .as_ref()
            .map(|context| {
                chain
                    .iter()
                    .position(|candidate| {
                        candidate.pid == context.root_process_identity.pid
                            && candidate.started_micros
                                == context.root_process_identity.started_at_unix_micros
                    })
                    .context("native tool owner is outside the verified caller ancestry")
            })
            .transpose()?;
        let claude_home = self.claude_settings.claude_home.clone();
        for (position, candidate) in chain.iter().enumerate() {
            if native_position == Some(position) {
                let context = native.as_ref().context("native caller owner disappeared")?;
                ensure!(
                    !context.thread_id.is_empty()
                        && !context.turn_id.is_empty()
                        && !context.tool_call_id.is_empty(),
                    "native tool context is incomplete"
                );
                return Ok(ProvenCaller {
                    conversation: ConversationIdentity {
                        provider: Provider::Codex,
                        provider_home: ProviderHome::Known {
                            path: self.job_codex_home()?,
                        },
                        thread_id: context.thread_id.clone(),
                    },
                    process: *candidate,
                    turn_id: Some(context.turn_id.clone()),
                    tool_call_id: Some(context.tool_call_id.clone()),
                });
            }
            if let Some(supervisor) = self.claude_agent()
                && let Some((thread_id, turn_id)) = supervisor
                    .owned_process_session(candidate.pid, candidate.started_micros)
                    .await
            {
                return Ok(ProvenCaller {
                    conversation: ConversationIdentity {
                        provider: Provider::Claude,
                        provider_home: ProviderHome::Known { path: claude_home },
                        thread_id,
                    },
                    process: *candidate,
                    turn_id,
                    tool_call_id: None,
                });
            }
            if let Some(owner) = crate::providers::claude::native_parent::prove_owner(
                &claude_home,
                candidate.pid,
                candidate.started_micros,
            )
            .await?
            {
                return Ok(ProvenCaller {
                    conversation: ConversationIdentity {
                        provider: Provider::Claude,
                        provider_home: ProviderHome::Known { path: claude_home },
                        thread_id: crate::providers::claude::claude_thread_id(&owner.session_uuid),
                    },
                    process: *candidate,
                    turn_id: None,
                    tool_call_id: None,
                });
            }
        }
        if let Some(error) = native_failure {
            return Err(error).context("caller could not be proved; native process mapping was unavailable and no Claude owner matched");
        }
        anyhow::bail!(
            "caller is outside a live agent tool process; capture context before detaching and pass --caller-context explicitly, or select deliberate --operator work"
        )
    }

    async fn capture_job_context(&self, request: CaptureParams) -> Result<CapturedContext> {
        let process = ProcessInstance {
            pid: i32::try_from(request.pid)?,
            started_micros: request.started_at_unix_micros,
        };
        let proven = self.job_process_context(process).await?;
        Ok(self.jobs.contexts.capture(proven).await)
    }

    pub(super) async fn resolve_job_caller(&self, caller: &Caller) -> Result<Origin> {
        match caller {
            Caller::Operator => Ok(Origin::TopLevel),
            Caller::Captured { context_id } => {
                let saved = self.jobs.contexts.get(context_id).await?;
                let current = self.job_process_context(saved.process).await?;
                ensure!(
                    saved.same_owner(&current),
                    "captured caller owner changed; recapture from the originating agent"
                );
                Ok(Origin::Parent {
                    conversation: saved.conversation,
                })
            }
        }
    }

    async fn job_context_view(&self, caller: Caller) -> Result<ContextView> {
        let Caller::Captured { context_id } = &caller else {
            anyhow::bail!("operator intent has no agent sender identity")
        };
        self.resolve_job_caller(&caller).await?;
        let saved = self.jobs.contexts.get(context_id).await?;
        let agent = self
            .jobs
            .agent_for_conversation(&saved.conversation)
            .await?;
        let job_id = agent.as_ref().and_then(|agent| agent.latest_job_id.clone());
        let sender_id = job_id
            .as_ref()
            .map(|id| id.as_str().to_owned())
            .unwrap_or_else(|| saved.conversation.thread_id.clone());
        Ok(ContextView {
            context: CapturedContext {
                context_id: context_id.clone(),
                provider: saved.conversation.provider,
                thread_id: saved.conversation.thread_id.clone(),
                turn_id: saved.turn_id,
            },
            conversation: saved.conversation,
            sender_id,
            job_id,
        })
    }

    pub(crate) async fn scoped_job_rpc(
        &self,
        id: JobId,
        peer: ProcessInstance,
        request: ScopedRequest,
    ) -> RpcResult {
        let proven = self.jobs.verify_peer(&id, peer).await?;
        let conversation = proven.conversation.clone();
        let context = self.jobs.contexts.capture(proven).await;
        let caller = Caller::Captured {
            context_id: context.context_id.clone(),
        };
        match request {
            ScopedRequest::ReadSelf {} => Ok(json!(ContextView {
                context,
                conversation,
                sender_id: id.as_str().into(),
                job_id: Some(id)
            })),
            ScopedRequest::MessageParent { delivery_id, text } => {
                self.job_message(MessageParams {
                    target: MessageTarget::Parent,
                    caller,
                    delivery_id,
                    text,
                })
                .await
            }
            ScopedRequest::SetTitle { mutation_id, title } => {
                self.agent_jobs_rpc(
                    "agent/context/setTitle",
                    json!(SetTitleParams {
                        caller,
                        mutation_id,
                        title
                    }),
                )
                .await
            }
        }
    }

    async fn job_message(&self, request: MessageParams) -> RpcResult {
        let _operation = self.jobs.operations.read().await;
        if self.is_draining() {
            return Err(RpcError::draining());
        }
        if request
            .delivery_id
            .split_once(':')
            .is_some_and(|(prefix, _)| JobId::try_from(prefix.to_owned()).is_ok())
        {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "job delivery IDs are reserved for the runtime; use a distinct message ID",
            ));
        }
        crate::agents::envelope::validate_message_text(&request.text)
            .map_err(|error| RpcError::new(RpcCode::InvalidParams, error.to_string()))?;
        let caller = self.resolve_job_caller(&request.caller).await?;
        let target = match &request.target {
            MessageTarget::Conversation { conversation } => conversation.clone(),
            MessageTarget::Job { job_id } => {
                let view = self.jobs.read(job_id).await?;
                let agent = view.agent.context("target conversation is unresolved")?;
                if agent.latest_job_id.as_ref() != Some(job_id) {
                    return Err(RpcError::new(
                        RpcCode::Conflict,
                        "target job has been superseded; use its latest job",
                    ));
                }
                if !matches!(
                    view.job.execution,
                    ExecutionState::Running { .. } | ExecutionState::Recovering { .. }
                ) {
                    return Err(RpcError::new(
                        RpcCode::InvalidRequest,
                        "target job is not running; resolve unknown work or use explicit Continue",
                    ));
                }
                match agent.conversation {
                    ConversationBinding::Known { conversation } => conversation,
                    _ => {
                        return Err(RpcError::new(
                            RpcCode::InvalidRequest,
                            "target provider identity is unresolved",
                        ));
                    }
                }
            }
            MessageTarget::Parent => {
                let Origin::Parent { conversation } = &caller else {
                    return Err(RpcError::new(
                        RpcCode::InvalidRequest,
                        "operator intent has no parent",
                    ));
                };
                let agent = self
                    .jobs
                    .agent_for_conversation(conversation)
                    .await?
                    .context("caller has no delegated-agent recipient")?;
                let latest = agent
                    .latest_job_id
                    .context("caller's current job is unresolved")?;
                match self.jobs.read(&latest).await?.job.recipient {
                    Recipient::Conversation { conversation } => conversation,
                    _ => {
                        return Err(RpcError::new(
                            RpcCode::InvalidRequest,
                            "caller has no proven parent recipient",
                        ));
                    }
                }
            }
        };
        if self.agent_conversation(&target.thread_id)? != target {
            return Err(RpcError::new(
                RpcCode::InvalidRequest,
                "message target belongs to another provider home",
            ));
        }
        let text = match caller {
            Origin::TopLevel => request.text,
            Origin::Parent { .. } => {
                let view = self.job_context_view(request.caller).await?;
                let host = self.job_host_name()?;
                crate::agents::envelope::message(
                    &request.delivery_id,
                    &crate::agents::envelope::Sender {
                        agent_id: &view.sender_id,
                        provider: view.context.provider.as_str(),
                        host: &host,
                        reply_tool: "message_agent",
                        reply_target: view
                            .job_id
                            .as_ref()
                            .map_or(view.conversation.thread_id.as_str(), JobId::as_str),
                    },
                    &request.text,
                )
                .map_err(|error| RpcError::new(RpcCode::InvalidParams, error.to_string()))?
            }
            Origin::Unknown { .. } => {
                return Err(RpcError::new(
                    RpcCode::InvalidRequest,
                    "message sender is unproven",
                ));
            }
        };
        self.jobs
            .gateway()?
            .deliver_job_input(&target, &request.delivery_id, &text)
            .await
    }
}
