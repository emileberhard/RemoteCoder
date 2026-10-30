mod automations;
mod cluster;
mod models;
pub(crate) mod native_parent;
pub(crate) mod sessions;
mod transport;

use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail, ensure};
use clap::{Args, Subcommand};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::conversation::conversation_from_header;
use super::envelope::{self, Sender};
use super::jobs::model::{
    ConversationBinding, ExecutionSettings, ExecutionState, JobId, JobRecord, JobSpec, Provider,
    ProviderHome, SpecEvidence, ToolScope,
};
use crate::config::{ConfigSources, GatewayEndpoint, HostPaths};
use crate::wire::agent_jobs::*;

const SCOPED_SOCKET_ENV: &str = "RC_AGENT_JOB_SOCKET";
const MAX_INVENTORY_PAGES: usize = 50;

#[derive(Clone, Debug, Subcommand)]
pub(crate) enum AgentCommand {
    Cluster {
        #[command(subcommand)]
        command: cluster::ClusterCommand,
    },
    SetParent {
        agent: String,
        parent: String,
        #[command(flatten)]
        caller: CallerArgs,
    },
    Spawn(SpawnArgs),
    List(ListArgs),
    Read {
        target: String,
        #[command(flatten)]
        caller: CallerArgs,
        #[arg(long)]
        json: bool,
    },
    Message(MessageArgs),
    Stop {
        target: String,
        #[arg(long)]
        host: Option<String>,
        #[arg(long)]
        mutation_id: Option<String>,
    },
    Dismiss {
        target: String,
        reason: String,
        #[arg(long)]
        mutation_id: Option<String>,
    },
    SetTitle {
        title: String,
        #[arg(long)]
        mutation_id: Option<String>,
        #[command(flatten)]
        caller: CallerArgs,
    },
    Capture,
    Receipt {
        delivery_id: String,
        #[arg(long)]
        json: bool,
    },
    NativeParent,
    Items {
        target: String,
        #[arg(long)]
        host: Option<String>,
        #[arg(long)]
        json: bool,
    },
}

#[derive(Clone, Debug, Args)]
pub(crate) struct CallerArgs {
    #[arg(long)]
    host: Option<String>,
    #[arg(long, conflicts_with = "caller_context")]
    operator: bool,
    #[arg(long, conflicts_with = "operator")]
    caller_context: Option<String>,
}

#[derive(Clone, Debug, Args)]
pub(crate) struct SpawnArgs {
    provider_or_prompt: String,
    model: Option<String>,
    prompt: Option<String>,
    #[arg(long)]
    resume: Option<String>,
    #[arg(long = "model")]
    model_override: Option<String>,
    #[arg(long)]
    effort: Option<String>,
    #[arg(long, value_parser = ["standard", "fast", "flex"])]
    service_tier: Option<String>,
    #[arg(long, conflicts_with = "service_tier")]
    fast: bool,
    #[arg(long, value_parser = ["full-access", "read-only"])]
    preset: Option<String>,
    #[arg(long)]
    sandbox_root: Option<PathBuf>,
    #[arg(long)]
    cwd: Option<PathBuf>,
    #[arg(long)]
    title: Option<String>,
    #[arg(long)]
    job_id: Option<String>,
    #[command(flatten)]
    caller: CallerArgs,
    #[arg(long)]
    json: bool,
}

#[derive(Clone, Debug, Args)]
pub(crate) struct ListArgs {
    #[arg(long)]
    host: Option<String>,
    #[arg(long)]
    local: bool,
    #[arg(long)]
    cursor: Option<String>,
    target: Option<String>,
    #[arg(long)]
    active: bool,
    #[arg(long, value_parser = ["codex", "claude"])]
    provider: Option<String>,
    #[arg(long)]
    automations: bool,
    #[arg(long, default_value_t = 20, value_parser = clap::value_parser!(u32).range(1..=10000))]
    last: u32,
    #[arg(long)]
    json: bool,
}

#[derive(Clone, Debug, Args)]
pub(crate) struct MessageArgs {
    target: String,
    text: String,
    #[arg(long)]
    delivery_id: Option<String>,
    #[arg(long)]
    format_only: bool,
    #[arg(long, requires_all = ["reply_tool", "reply_target", "format_only"])]
    sender_id: Option<String>,
    #[arg(long, requires_all = ["sender_id", "reply_target", "format_only"])]
    reply_tool: Option<String>,
    #[arg(long, requires_all = ["sender_id", "reply_tool", "format_only"])]
    reply_target: Option<String>,
    #[command(flatten)]
    caller: CallerArgs,
    #[arg(long)]
    json: bool,
}

struct Endpoint {
    local: GatewayEndpoint,
    host: Option<String>,
}

#[derive(Debug)]
struct RpcFailure(Value);

impl std::fmt::Display for RpcFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0["message"].as_str().unwrap_or("Agent request failed"))
    }
}

impl std::error::Error for RpcFailure {}

#[derive(Debug)]
struct RequestIdentity(String);

impl std::fmt::Display for RequestIdentity {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "request {}", self.0)
    }
}

async fn admission<P: Serialize>(
    endpoint: &Endpoint,
    method: &str,
    job_id: JobId,
    params: P,
) -> Result<Value> {
    let admitted: AdmissionReceipt = rpc(endpoint, method, params)
        .await
        .context(RequestIdentity(job_id.as_str().to_owned()))?;
    Ok(receipt(admitted))
}

fn response_value(response: Value) -> Result<Value> {
    if let Some(error) = response.get("error") {
        return Err(RpcFailure(error.clone()).into());
    }
    response
        .get("result")
        .cloned()
        .context("Agent route returned no result")
}

async fn rpc<P: Serialize, R: DeserializeOwned>(
    endpoint: &Endpoint,
    method: &str,
    params: P,
) -> Result<R> {
    let params = serde_json::to_value(params)?;
    let response = if let Some(host) = &endpoint.host
        && !method.starts_with("agent/context/")
    {
        let caller = params
            .get("caller")
            .cloned()
            .unwrap_or(json!({"kind":"operator"}));
        transport::call(
            &endpoint.local,
            "agent/cluster/dispatch",
            json!({"host":host,"method":method,"request":params,"caller":caller}),
        )
        .await?
    } else {
        transport::call(&endpoint.local, method, params).await?
    };
    Ok(serde_json::from_value(response_value(response)?)?)
}

async fn scoped(request: ScopedRequest) -> Result<Value> {
    let path = std::env::var_os(SCOPED_SOCKET_ENV).context("No scoped agent route is available")?;
    let root = HostPaths::from_env()?.state("agent-jobs/v1");
    let legacy_target = crate::agents::jobs::routes::scoped_socket(&root);
    response_value(transport::scoped(Path::new(&path), &legacy_target, &request).await?)
}

async fn mutation<P: Serialize>(
    endpoint: &Endpoint,
    method: &str,
    request_id: String,
    params: P,
) -> Result<Value> {
    rpc(endpoint, method, params)
        .await
        .context(RequestIdentity(request_id))
}

async fn scoped_mutation(request_id: String, request: ScopedRequest) -> Result<Value> {
    scoped(request).await.context(RequestIdentity(request_id))
}

fn use_scoped(caller: &CallerArgs) -> bool {
    !caller.operator
        && caller.caller_context.is_none()
        && std::env::var_os(SCOPED_SOCKET_ENV).is_some()
}

fn endpoint(env_file: Option<&Path>) -> Result<Endpoint> {
    let default_file = HostPaths::from_env()?.state("codex-gateway.env");
    let env_file = env_file.or_else(|| default_file.exists().then_some(default_file.as_path()));
    Ok(Endpoint {
        local: GatewayEndpoint::load(&ConfigSources::load(env_file)?)?,
        host: None,
    })
}

async fn capture(endpoint: &Endpoint) -> Result<CapturedContext> {
    let pid = std::process::id();
    let identity = crate::platform::process::identify(i32::try_from(pid)?)?
        .context("The caller process no longer has a verifiable identity")?;
    rpc(endpoint, "agent/context/capture", CaptureParams {
        pid,
        started_at_unix_micros: identity.started_micros,
    }).await.context("Cannot prove the calling agent; capture context before detaching, pass --caller-context explicitly, or select --operator for deliberate standalone work")
}

async fn caller(endpoint: &Endpoint, arguments: &CallerArgs) -> Result<Caller> {
    if arguments.operator {
        return Ok(Caller::Operator);
    }
    let context_id = match &arguments.caller_context {
        Some(context_id) => {
            ensure!(
                !context_id.trim().is_empty(),
                "Caller context must not be empty"
            );
            context_id.clone()
        }
        None => capture(endpoint).await?.context_id,
    };
    Ok(Caller::Captured { context_id })
}

fn text(argument: &str) -> Result<String> {
    let text = if argument == "-" {
        let mut text = String::new();
        std::io::stdin()
            .take(super::jobs::model::MAX_PROMPT_BYTES as u64 + 1)
            .read_to_string(&mut text)?;
        text
    } else {
        argument.to_owned()
    };
    ensure!(!text.trim().is_empty(), "Text must not be empty");
    ensure!(
        text.len() <= super::jobs::model::MAX_PROMPT_BYTES,
        "Inline text exceeds 512 KiB; provide a file path for the agent to read"
    );
    Ok(text)
}

fn new_job_id(provider: Provider, supplied: Option<String>) -> Result<JobId> {
    let value = if let Some(supplied) = supplied {
        supplied
    } else {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .context("System clock precedes the Unix epoch")?
            .as_nanos();
        let suffix = crate::ids::new_session_uuid().replace('-', "");
        format!("agent-{}-{nanos}-{}", provider.as_str(), &suffix[..8])
    };
    JobId::try_from(value).map_err(anyhow::Error::msg)
}

async fn model_catalog(endpoint: &Endpoint) -> Result<Vec<models::Model>> {
    let mut cursor = Value::Null;
    let mut models = Vec::new();
    for _ in 0..MAX_INVENTORY_PAGES {
        let page: Value = rpc(
            endpoint,
            "model/list",
            json!({"cursor":cursor,"limit":100,"includeHidden":true}),
        )
        .await?;
        models.extend(serde_json::from_value::<Vec<models::Model>>(
            page["data"].clone(),
        )?);
        cursor = page["nextCursor"].clone();
        if cursor.is_null() {
            return Ok(models);
        }
    }
    bail!("Model inventory exceeded its page limit")
}

async fn settings(
    endpoint: &Endpoint,
    provider: Provider,
    model: &str,
    effort: Option<&str>,
    tier: Option<&str>,
) -> Result<ExecutionSettings> {
    match provider {
        Provider::Codex => models::codex(model, effort, tier, &model_catalog(endpoint).await?),
        Provider::Claude => {
            let model = model.to_ascii_lowercase();
            ensure!(
                matches!(
                    model.as_str(),
                    "default"
                        | "best"
                        | "fable"
                        | "fable[1m]"
                        | "haiku"
                        | "opus"
                        | "opus[1m]"
                        | "opusplan"
                        | "sonnet"
                        | "sonnet[1m]"
                ),
                "Claude requires a moving model family alias"
            );
            ensure!(
                tier.is_none_or(|tier| matches!(tier, "standard" | "fast")),
                "Claude supports standard or fast mode"
            );
            Ok(ExecutionSettings::Claude {
                model,
                effort: effort.map(str::to_owned),
                fast: tier == Some("fast"),
            })
        }
    }
}

async fn resolve(endpoint: &Endpoint, target: &str) -> Result<JobId> {
    if let Ok(id) = JobId::try_from(target.to_owned()) {
        return Ok(id);
    }
    let resolved: Value = rpc(
        endpoint,
        "agent/cluster/resolve",
        json!({"target":target,"local":true}),
    )
    .await?;
    JobId::try_from(
        resolved["jobId"]
            .as_str()
            .context("target has no job identity")?
            .to_owned(),
    )
    .map_err(anyhow::Error::msg)
}

async fn read(endpoint: &Endpoint, target: &str) -> Result<JobView> {
    rpc(
        endpoint,
        "agent/jobs/read",
        ReadParams {
            job_id: resolve(endpoint, target).await?,
        },
    )
    .await
}

fn execution_status(job: &JobRecord) -> &'static str {
    match &job.execution {
        ExecutionState::Admitted => "admitted",
        ExecutionState::WaitingForProvider { .. } => "waitingForProvider",
        ExecutionState::Bound { .. } => "bound",
        ExecutionState::Dispatching { .. } => "dispatchUncertain",
        ExecutionState::Running { .. } => "running",
        ExecutionState::Recovering { .. } => "recovering",
        ExecutionState::RetryWaiting { .. } => "retryWaiting",
        ExecutionState::Unknown { .. } => "unknown",
        ExecutionState::Terminal { terminal } => match terminal.outcome {
            super::jobs::model::JobOutcome::Completed => "completed",
            super::jobs::model::JobOutcome::Failed { .. } => "failed",
            super::jobs::model::JobOutcome::Stopped { .. } => "stopped",
        },
    }
}

fn receipt(receipt: AdmissionReceipt) -> Value {
    let provider_session_id = receipt
        .job
        .execution
        .conversation()
        .map(|conversation| conversation.thread_id.as_str());
    json!({"ownerHostId":receipt.owner_host_id,"address":format!("{}:{}",receipt.owner_host_id,receipt.job.job_id.as_str()),"run_id":receipt.job.job_id,"agent_id":receipt.job.agent_id,"previous_run_id":receipt.job.previous_job_id,
        "provider_session_id":provider_session_id,"status":execution_status(&receipt.job),"duplicate":receipt.duplicate,"job":receipt.job})
}

async fn spawn(endpoint: &Endpoint, arguments: SpawnArgs) -> Result<Value> {
    let caller = caller(endpoint, &arguments.caller).await?;
    let tier = if arguments.fast {
        Some("fast")
    } else {
        arguments.service_tier.as_deref()
    };
    if let Some(target) = &arguments.resume {
        ensure!(
            arguments.model.is_none() && arguments.prompt.is_none(),
            "Use spawn_agent --resume RUN PROMPT"
        );
        ensure!(
            arguments.cwd.is_none() && arguments.title.is_none(),
            "Continuation keeps the existing conversation's directory and title"
        );
        let mut source = read(endpoint, target).await?;
        if let Some(agent) = &source.agent
            && agent.agent_id == *target
        {
            let latest = agent
                .latest_job_id
                .clone()
                .context("Conversation latest job is unresolved; use an exact run ID")?;
            if latest != source.job.job_id {
                source = rpc(endpoint, "agent/jobs/read", ReadParams { job_id: latest }).await?;
            }
        }
        let historical;
        let (original_settings, original_scope) = match &source.job.spec {
            SpecEvidence::Known { spec } => (&spec.settings, &spec.tool_scope),
            SpecEvidence::Expired {
                settings,
                tool_scope,
                ..
            } => (settings, tool_scope),
            SpecEvidence::Unknown { .. } => {
                let agent = source
                    .agent
                    .as_ref()
                    .context("Historical agent identity is unresolved")?;
                let ConversationBinding::Known { conversation } = &agent.conversation else {
                    bail!("Historical provider conversation is unresolved");
                };
                ensure!(
                    conversation.provider == Provider::Claude,
                    "Historical Codex execution settings are unresolved"
                );
                let response: Value = rpc(
                    endpoint,
                    "thread/read",
                    json!({"threadId":conversation.thread_id,"includeTurns":false}),
                )
                .await?;
                ensure!(
                    conversation_from_header(&response["thread"])? == *conversation,
                    "Provider history resolved a different conversation or home"
                );
                historical = ExecutionSettings::Claude {
                    model: response["thread"]["model"]
                        .as_str()
                        .context("Historical model is unknown")?
                        .to_owned(),
                    effort: response["thread"]["reasoningEffort"]
                        .as_str()
                        .map(str::to_owned),
                    fast: false,
                };
                (
                    &historical,
                    agent
                        .tool_scope
                        .as_ref()
                        .context("Historical permission scope is unresolved")?,
                )
            }
        };
        if let Some(preset) = &arguments.preset {
            ensure!(
                matches!(
                    (preset.as_str(), original_scope),
                    ("full-access", ToolScope::Full) | ("read-only", ToolScope::ReadOnly { .. })
                ),
                "A continuation cannot change the conversation's permission scope"
            );
        }
        ensure!(
            arguments.sandbox_root.is_none(),
            "A continuation keeps its recorded sandbox root"
        );
        let settings =
            if arguments.model_override.is_some() || arguments.effort.is_some() || tier.is_some() {
                let selected = if let Some(model) = &arguments.model_override {
                    let (effort, tier) = match original_settings {
                        ExecutionSettings::Codex {
                            effort,
                            service_tier,
                            ..
                        } => (Some(effort.as_str()), service_tier.as_deref()),
                        ExecutionSettings::Claude { effort, fast, .. } => (
                            effort.as_deref(),
                            Some(if *fast { "fast" } else { "standard" }),
                        ),
                    };
                    settings(endpoint, original_settings.provider(), model, effort, tier).await?
                } else {
                    original_settings.clone()
                };
                Some(update_settings(
                    original_settings,
                    selected,
                    arguments.effort.as_deref(),
                    tier,
                )?)
            } else {
                None
            };
        let params = ContinueParams {
            job_id: new_job_id(original_settings.provider(), arguments.job_id)?,
            agent_id: source.job.agent_id,
            prompt: text(&arguments.provider_or_prompt)?,
            settings,
            expected_previous_job_id: Some(source.job.job_id),
            intent: ContinueIntent::Explicit,
            recipient: ContinueRecipient::Current,
            caller,
        };
        return admission(
            endpoint,
            "agent/jobs/continue",
            params.job_id.clone(),
            params,
        )
        .await;
    }
    ensure!(
        arguments.model_override.is_none(),
        "Use the positional model for a fresh agent"
    );
    let provider = match arguments.provider_or_prompt.as_str() {
        "codex" => Provider::Codex,
        "claude" => Provider::Claude,
        _ => bail!("Provider must be codex or claude"),
    };
    let model = arguments.model.context("A fresh agent requires a model")?;
    let prompt = text(
        &arguments
            .prompt
            .context("A fresh agent requires a prompt")?,
    )?;
    let requested_cwd = arguments.cwd.unwrap_or(std::env::current_dir()?);
    let cwd = if endpoint.host.is_some() {
        ensure!(
            requested_cwd.is_absolute(),
            "remote --cwd must be an absolute path on the target host"
        );
        requested_cwd
    } else {
        let cwd = requested_cwd.canonicalize()?;
        ensure!(cwd.is_dir(), "Working directory must be a directory");
        cwd
    };
    let tool_scope = match arguments.preset.as_deref().unwrap_or("full-access") {
        "full-access" => {
            ensure!(
                arguments.sandbox_root.is_none(),
                "--sandbox-root requires --preset read-only"
            );
            ToolScope::Full
        }
        "read-only" => {
            let requested_root = arguments
                .sandbox_root
                .context("Read-only agents require --sandbox-root")?;
            let root = if endpoint.host.is_some() {
                requested_root
            } else {
                requested_root.canonicalize()?
            };
            ensure!(
                root.is_absolute()
                    && cwd.starts_with(&root)
                    && (endpoint.host.is_some() || root.is_dir()),
                "Working directory must be inside the read-only sandbox root"
            );
            ToolScope::ReadOnly { root }
        }
        _ => bail!("Unsupported permission preset"),
    };
    let params = StartParams {
        job_id: new_job_id(provider, arguments.job_id)?,
        spec: JobSpec {
            prompt,
            cwd,
            settings: settings(
                endpoint,
                provider,
                &model,
                arguments.effort.as_deref(),
                tier,
            )
            .await?,
            tool_scope,
            title: arguments.title,
        },
        caller,
    };
    admission(endpoint, "agent/jobs/start", params.job_id.clone(), params).await
}

fn update_settings(
    current: &ExecutionSettings,
    mut selected: ExecutionSettings,
    effort: Option<&str>,
    tier: Option<&str>,
) -> Result<ExecutionSettings> {
    match (&current, &mut selected) {
        (
            ExecutionSettings::Codex {
                model_provider: current_provider,
                ..
            },
            ExecutionSettings::Codex {
                model_provider,
                effort: selected_effort,
                service_tier,
                ..
            },
        ) => {
            ensure!(
                current_provider == model_provider,
                "A continuation cannot change model provider"
            );
            if let Some(effort) = effort {
                *selected_effort = effort.to_owned();
            }
            if let Some(tier) = tier {
                ensure!(
                    model_provider == "openai" || tier == "standard",
                    "External models have no service tiers"
                );
                *service_tier = (tier != "standard").then(|| tier.to_owned());
            }
        }
        (
            ExecutionSettings::Claude { .. },
            ExecutionSettings::Claude {
                effort: selected_effort,
                fast,
                ..
            },
        ) => {
            if let Some(effort) = effort {
                *selected_effort = Some(effort.to_owned());
            }
            if let Some(tier) = tier {
                ensure!(
                    matches!(tier, "standard" | "fast"),
                    "Claude supports standard or fast mode"
                );
                *fast = tier == "fast";
            }
        }
        _ => bail!("A continuation cannot change provider"),
    }
    Ok(selected)
}

async fn formatting_context(
    arguments: &CallerArgs,
    env_file: Option<&Path>,
) -> Result<(ContextView, String)> {
    if use_scoped(arguments) {
        let view = serde_json::from_value(scoped(ScopedRequest::ReadSelf {}).await?)?;
        return Ok((view, host()?.to_ascii_lowercase()));
    }
    ensure!(
        !arguments.operator,
        "Inferred formatting requires a proven agent context; provide complete explicit sender metadata for native formatting"
    );
    let endpoint = endpoint(env_file)?;
    let host: crate::wire::gateway::HostInfoResponse =
        rpc(&endpoint, "host/info", json!({})).await?;
    ensure!(
        !host.hostname.trim().is_empty(),
        "The owning gateway's hostname is unavailable"
    );
    ensure!(
        arguments.caller_context.is_some() || host.hostname == self::host()?.to_ascii_lowercase(),
        "Cannot prove this local process through another host's gateway; capture caller context on the owning host and pass --caller-context, or provide complete explicit formatting metadata"
    );
    let view = rpc(
        &endpoint,
        "agent/context/read",
        ContextReadParams {
            caller: caller(&endpoint, arguments).await?,
        },
    )
    .await?;
    Ok((view, host.hostname))
}

fn host() -> Result<String> {
    Ok(nix::unistd::gethostname()?
        .to_string_lossy()
        .split('.')
        .next()
        .context("Host has no name")?
        .to_owned())
}

async fn message(endpoint: &Endpoint, arguments: MessageArgs, text: String) -> Result<Value> {
    let delivery_id = arguments
        .delivery_id
        .unwrap_or_else(crate::ids::new_session_uuid);
    let caller = caller(endpoint, &arguments.caller).await?;
    if arguments.target.starts_with("automation:") {
        let view: ContextView =
            rpc(endpoint, "agent/context/read", ContextReadParams { caller }).await?;
        let host = host()?;
        let sender = Sender {
            agent_id: &view.sender_id,
            provider: view.context.provider.as_str(),
            host: &host,
            reply_tool: "message_agent",
            reply_target: view
                .job_id
                .as_ref()
                .map_or(view.context.thread_id.as_str(), JobId::as_str),
        };
        let text = envelope::message(&delivery_id, &sender, &text)?;
        return automations::steer(&arguments.target, &text, &delivery_id)
            .await
            .context(RequestIdentity(delivery_id));
    }
    let target = if arguments.target == "parent" {
        MessageTarget::Parent
    } else {
        MessageTarget::Selector {
            selector: arguments.target,
        }
    };
    mutation(
        endpoint,
        "agent/jobs/message",
        delivery_id.clone(),
        MessageParams {
            target,
            caller,
            delivery_id,
            text,
        },
    )
    .await
}

async fn items(endpoint: &Endpoint, target: &str) -> Result<Value> {
    let view = read(endpoint, target).await?;
    let agent = view
        .agent
        .context("Job has no proven provider conversation")?;
    let ConversationBinding::Known { conversation } = agent.conversation else {
        bail!("Job's provider conversation is unknown");
    };
    let ProviderHome::Known { .. } = &conversation.provider_home else {
        bail!("Job's provider home is unknown");
    };
    let header: Value = rpc(
        endpoint,
        "thread/read",
        json!({"threadId":conversation.thread_id,"includeTurns":false}),
    )
    .await?;
    ensure!(
        header["thread"]["id"] == conversation.thread_id,
        "Gateway returned a different conversation"
    );
    ensure!(
        conversation_from_header(&header["thread"])? == conversation,
        "Conversation belongs to a different provider home"
    );
    let mut output = Vec::new();
    let mut bytes = 0;
    let mut cursor = Value::Null;
    for _ in 0..MAX_INVENTORY_PAGES {
        let page: Value = rpc(endpoint, "thread/items/list", json!({"threadId":conversation.thread_id,"limit":100,"sortDirection":"asc","cursor":cursor})).await?;
        for entry in page["data"]
            .as_array()
            .context("Provider returned no item page")?
        {
            bytes += crate::wire::json::encoded_len(entry)?;
            ensure!(
                bytes <= 24 * 1024 * 1024 && output.len() < 20_000,
                "Provider history exceeds the client item budget; inspect native pages directly"
            );
            output.push(entry.clone());
        }
        cursor = page["nextCursor"].clone();
        if cursor.is_null() {
            break;
        }
    }
    ensure!(
        cursor.is_null(),
        "Provider item history exceeds 5,000 items; inspect native pages directly"
    );
    Ok(json!({"jobId":view.job.job_id,"conversation":conversation,"items":output}))
}

async fn execute(mut command: AgentCommand, env_file: Option<&Path>) -> Result<Value> {
    if matches!(&command, AgentCommand::NativeParent) {
        if std::env::var_os(SCOPED_SOCKET_ENV).is_some() {
            let view: ContextView =
                serde_json::from_value(scoped(ScopedRequest::ReadSelf {}).await?)?;
            ensure!(
                view.job_id.is_some(),
                "Scoped native holder route has no proven gateway job; no operator fallback is allowed"
            );
            return Ok(json!({"kind":"gatewayOwned"}));
        }
        let paths = HostPaths::from_env()?;
        let default_file = paths.state("codex-gateway.env");
        let sources = ConfigSources::load(
            env_file.or_else(|| default_file.exists().then_some(default_file.as_path())),
        )?;
        let endpoint = GatewayEndpoint::load(&sources)?;
        let claude = crate::providers::claude::settings::ClaudeSettings::load(
            &sources,
            &paths,
            endpoint.port(),
            None,
        )?;
        native_parent::run(endpoint, &claude.claude_home).await?;
        return Ok(json!({"kind":"closed"}));
    }
    if let AgentCommand::List(arguments) = &command {
        if arguments.automations {
            ensure!(
                arguments.target.is_none(),
                "Automation list filters cannot combine with a run selector"
            );
            return automations::listing(arguments).await;
        }
        if let Some(target) = &arguments.target
            && target.starts_with("automation:")
        {
            ensure!(
                !arguments.active && arguments.provider.is_none(),
                "Run inspection cannot combine list filters"
            );
            return automations::read(target).await;
        }
    }
    if let AgentCommand::Read { target, .. } = &command
        && target.starts_with("automation:")
    {
        return automations::read(target).await;
    }
    let prepared_message = if let AgentCommand::Message(arguments) = &command {
        let text = text(&arguments.text)?;
        envelope::validate_message_text(&text)?;
        Some(text)
    } else {
        None
    };
    if let AgentCommand::Receipt { delivery_id, .. } = &command
        && std::env::var_os(SCOPED_SOCKET_ENV).is_some()
    {
        return scoped(ScopedRequest::ReadMessage {
            delivery_id: delivery_id.clone(),
        })
        .await;
    }
    if let AgentCommand::Read { target, caller, .. } = &command
        && target == "self"
        && use_scoped(caller)
    {
        return scoped(ScopedRequest::ReadSelf {}).await;
    }
    if let AgentCommand::Message(arguments) = &command {
        if arguments.format_only {
            let context = if arguments.sender_id.is_none() {
                Some(formatting_context(&arguments.caller, env_file).await?)
            } else {
                None
            };
            let view = context.as_ref().map(|(view, _)| view);
            let host = match &context {
                Some((_, host)) => host.clone(),
                None => host()?,
            };
            let sender = Sender {
                agent_id: arguments
                    .sender_id
                    .as_deref()
                    .or_else(|| view.map(|view| view.sender_id.as_str()))
                    .context("Formatting has no proven sender")?,
                provider: view.map_or("native", |view| view.context.provider.as_str()),
                host: &host,
                reply_tool: arguments.reply_tool.as_deref().unwrap_or("message_agent"),
                reply_target: arguments
                    .reply_target
                    .as_deref()
                    .or_else(|| {
                        view.map(|view| {
                            view.job_id
                                .as_ref()
                                .map_or(view.conversation.thread_id.as_str(), JobId::as_str)
                        })
                    })
                    .context("Formatting has no proven reply target")?,
            };
            return Ok(Value::String(envelope::message(
                arguments
                    .delivery_id
                    .as_deref()
                    .unwrap_or(&crate::ids::new_session_uuid()),
                &sender,
                prepared_message
                    .as_deref()
                    .context("Message text was not prepared")?,
            )?));
        }
        if arguments.target == "parent" && use_scoped(&arguments.caller) {
            let delivery_id = arguments
                .delivery_id
                .clone()
                .unwrap_or_else(crate::ids::new_session_uuid);
            return scoped_mutation(
                delivery_id.clone(),
                ScopedRequest::MessageParent {
                    delivery_id,
                    text: prepared_message
                        .clone()
                        .context("Message text was not prepared")?,
                },
            )
            .await;
        }
    }
    if let AgentCommand::SetTitle {
        title,
        mutation_id,
        caller,
    } = &command
        && use_scoped(caller)
    {
        let mutation_id = mutation_id
            .clone()
            .unwrap_or_else(crate::ids::new_session_uuid);
        return scoped_mutation(
            mutation_id.clone(),
            ScopedRequest::SetTitle {
                mutation_id,
                title: title.clone(),
            },
        )
        .await;
    }
    let mut endpoint = endpoint(env_file)?;
    endpoint.host = cluster::command_host(&mut command)?;
    if let Some(thread) = cluster::resolve_command(&mut endpoint, &mut command).await?
        && !matches!(command, AgentCommand::SetParent { .. })
    {
        return cluster::native_operation(&endpoint, &thread, command, prepared_message).await;
    }
    match command {
        AgentCommand::Cluster { command } => cluster::execute(&endpoint, command).await,
        AgentCommand::SetParent {
            agent,
            parent,
            caller,
        } => cluster::set_parent(&endpoint, &agent, &parent, caller).await,
        AgentCommand::Spawn(arguments) => spawn(&endpoint, arguments).await,
        AgentCommand::Read {
            target,
            caller: arguments,
            ..
        } if target == "self" => {
            rpc(
                &endpoint,
                "agent/context/read",
                ContextReadParams {
                    caller: caller(&endpoint, &arguments).await?,
                },
            )
            .await
        }
        AgentCommand::Read { target, .. } => {
            Ok(serde_json::to_value(read(&endpoint, &target).await?)?)
        }
        AgentCommand::List(arguments) => {
            if let Some(target) = &arguments.target {
                ensure!(
                    !arguments.active && arguments.provider.is_none(),
                    "Job inspection cannot combine list filters"
                );
                return Ok(serde_json::to_value(read(&endpoint, target).await?)?);
            }
            let local = Endpoint {
                local: endpoint.local.clone(),
                host: None,
            };
            rpc(&local,"agent/cluster/list",json!({"host":endpoint.host,"local":arguments.local,"active":arguments.active,"provider":arguments.provider,"limit":arguments.last,"cursor":arguments.cursor})).await
        }
        AgentCommand::Message(arguments) => {
            message(
                &endpoint,
                arguments,
                prepared_message.context("Message text was not prepared")?,
            )
            .await
        }
        AgentCommand::Stop {
            target,
            mutation_id,
            ..
        } => {
            let mutation_id = mutation_id.unwrap_or_else(crate::ids::new_session_uuid);
            mutation(
                &endpoint,
                "agent/jobs/stop",
                mutation_id.clone(),
                StopParams {
                    job_id: resolve(&endpoint, &target).await?,
                    mutation_id,
                },
            )
            .await
        }
        AgentCommand::Dismiss {
            target,
            reason,
            mutation_id,
        } => {
            let mutation_id = mutation_id.unwrap_or_else(crate::ids::new_session_uuid);
            mutation(
                &endpoint,
                "agent/jobs/dismiss",
                mutation_id.clone(),
                DismissParams {
                    job_id: resolve(&endpoint, &target).await?,
                    mutation_id,
                    reason,
                },
            )
            .await
        }
        AgentCommand::SetTitle {
            title,
            mutation_id,
            caller: arguments,
        } => {
            let mutation_id = mutation_id.unwrap_or_else(crate::ids::new_session_uuid);
            mutation(
                &endpoint,
                "agent/context/setTitle",
                mutation_id.clone(),
                SetTitleParams {
                    caller: caller(&endpoint, &arguments).await?,
                    mutation_id,
                    title,
                },
            )
            .await
        }
        AgentCommand::Receipt { delivery_id, .. } => {
            rpc(
                &endpoint,
                "agent/messages/read",
                MessageReadParams { delivery_id },
            )
            .await
        }
        AgentCommand::Capture => Ok(serde_json::to_value(capture(&endpoint).await?)?),
        AgentCommand::Items { target, .. } => items(&endpoint, &target).await,
        AgentCommand::NativeParent => {
            unreachable!("native holder was handled before operator credential loading")
        }
    }
}

fn human_listing(result: &Value) -> Result<String> {
    fn value<'a>(row: &'a Value, field: &str) -> &'a str {
        row[field].as_str().unwrap_or("unknown")
    }
    if let Some(rows) = result["agents"].as_array() {
        let mut lines = rows
            .iter()
            .map(|row| {
                format!(
                    "{}:{}  {}  {}  {}\n  {}",
                    value(row, "ownerHostId"),
                    row["run_id"]
                        .as_str()
                        .or_else(|| row["provider_session_id"].as_str())
                        .unwrap_or("unknown"),
                    value(row, "status"),
                    value(row, "provider"),
                    value(row, "model"),
                    value(row, "title")
                )
            })
            .collect::<Vec<_>>();
        if rows.is_empty() {
            lines.push("No matching agents".into());
        }
        if let Some(warnings) = result["warnings"].as_array() {
            lines.extend(warnings.iter().filter_map(Value::as_str).map(str::to_owned));
        }
        return Ok(lines.join("\n"));
    }
    let view: JobView = serde_json::from_value(result.clone())?;
    let (model, cwd) = match &view.job.spec {
        SpecEvidence::Known { spec } => (Some(&spec.settings), Some(&spec.cwd)),
        SpecEvidence::Expired { settings, cwd, .. } => (Some(settings), Some(cwd)),
        SpecEvidence::Unknown { .. } => (None, None),
    };
    let model = model
        .map(|settings| match settings {
            ExecutionSettings::Codex { model, .. } | ExecutionSettings::Claude { model, .. } => {
                model.as_str()
            }
        })
        .unwrap_or("unknown");
    let mut lines = vec![
        format!(
            "{}  {}",
            view.job.job_id.as_str(),
            execution_status(&view.job)
        ),
        format!("Model: {model}"),
        format!(
            "Directory: {}",
            cwd.map(|cwd| cwd.display().to_string())
                .unwrap_or_else(|| "unknown".into())
        ),
    ];
    if let Some(agent) = view.agent {
        match agent.conversation {
            ConversationBinding::Known { conversation } => lines.push(format!(
                "Conversation: {} ({})",
                conversation.thread_id,
                conversation.provider.as_str()
            )),
            ConversationBinding::Unknown { reason } => {
                lines.push(format!("Conversation: unknown ({reason})"))
            }
        }
    }
    match &view.job.execution {
        ExecutionState::Unknown { reason, .. } => lines.push(format!("Status evidence: {reason}")),
        ExecutionState::Terminal { terminal } => {
            if let super::jobs::model::ResultEvidence::Available { result } = &terminal.result {
                lines.push(result.text.clone());
            }
        }
        _ => {}
    }
    Ok(lines.join("\n"))
}

fn message_exit(result: &Value) -> i32 {
    match result["deliveryState"]["kind"].as_str() {
        Some("submitted" | "accepted" | "recorded") => 0,
        Some("uncertain" | "sending" | "pending") => 6,
        Some("unreachable") => 5,
        _ => 4,
    }
}

pub(crate) async fn run(command: AgentCommand, env_file: Option<&Path>) -> Result<i32> {
    let format_only = matches!(&command, AgentCommand::Message(arguments) if arguments.format_only);
    let is_message = matches!(&command, AgentCommand::Message(arguments) if !arguments.target.starts_with("automation:"));
    let human_list = matches!(&command, AgentCommand::List(arguments) if !arguments.json && !arguments.automations && !arguments.target.as_deref().is_some_and(|target| target.starts_with("automation:")));
    let compact = match &command {
        AgentCommand::Spawn(arguments) => arguments.json,
        AgentCommand::Message(arguments) => arguments.json,
        AgentCommand::List(arguments) => arguments.json,
        AgentCommand::Read { json, .. }
        | AgentCommand::Items { json, .. }
        | AgentCommand::Receipt { json, .. } => *json,
        _ => true,
    };
    match execute(command, env_file).await {
        Ok(Value::String(text)) if format_only => {
            println!("{text}");
            Ok(0)
        }
        Ok(result) if human_list => {
            println!("{}", human_listing(&result)?);
            Ok(0)
        }
        Ok(result) => {
            let exit = if is_message { message_exit(&result) } else { 0 };
            let encoded = if compact {
                serde_json::to_string(&result)?
            } else {
                serde_json::to_string_pretty(&result)?
            };
            if exit == 0 {
                println!("{encoded}");
            } else {
                eprintln!("{encoded}");
            }
            Ok(exit)
        }
        Err(error) => {
            let (exit, payload) = if let Some(error) = error.downcast_ref::<RpcFailure>() {
                let exit = cluster::error_exit(&error.0);
                (exit, error.0.clone())
            } else if let Some(error) = error.downcast_ref::<transport::TransportError>() {
                (
                    if error.submission == transport::Submission::Uncertain {
                        6
                    } else {
                        5
                    },
                    json!({"kind":if error.submission == transport::Submission::Uncertain {"submissionUncertain"} else {"unavailable"},"message":error.to_string(),"retryable":false}),
                )
            } else {
                (
                    2,
                    json!({"kind":"usage","message":format!("{error:#}"),"retryable":false}),
                )
            };
            let request_id = error
                .downcast_ref::<RequestIdentity>()
                .map(|identity| identity.0.as_str());
            let diagnostic = serde_json::to_string(
                &json!({"ok":false,"request_id":request_id,"error":payload}),
            )?;
            eprintln!("{diagnostic}");
            Ok(exit)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_delivery_failures_return_nonzero_without_changing_receipt() {
        for (kind, exit) in [
            ("unreachable", 5),
            ("uncertain", 6),
            ("blocked", 4),
            ("failed", 4),
            ("sending", 6),
            ("pending", 6),
        ] {
            assert_eq!(
                message_exit(
                    &json!({"deliveryId":"same-id","deliveryState":{"kind":kind,"reason":"not accepted"}})
                ),
                exit
            );
        }
        for kind in ["submitted", "accepted", "recorded"] {
            assert_eq!(
                message_exit(&json!({"deliveryId":"same-id","deliveryState":{"kind":kind}})),
                0
            );
        }
        assert_eq!(message_exit(&json!({"deliveryId":"same-id"})), 4);
    }

    #[test]
    fn human_list_preserves_unknown_status_and_missing_model() {
        let output = human_listing(&json!({"agents":[{"run_id":"agent-claude-old","status":"unknown","provider":"claude","model":null,"title":null}],"warnings":[]})).unwrap();
        assert!(output.contains("agent-claude-old  unknown  claude  unknown"));
        assert!(!output.contains("null"));
        assert_eq!(
            human_listing(&json!({"agents":[],"warnings":[]})).unwrap(),
            "No matching agents"
        );
    }
}
