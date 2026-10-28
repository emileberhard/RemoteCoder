mod automations;
mod models;
pub(crate) mod native_parent;
mod transport;

use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail, ensure};
use clap::{Args, Subcommand};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::envelope::{self, Sender};
use super::jobs::model::{
    ConversationBinding, ConversationIdentity, ExecutionSettings, ExecutionState, JobId, JobRecord,
    JobSpec, Provider, ProviderHome, SpecEvidence, ToolScope,
};
use crate::config::{ConfigSources, GatewayEndpoint, HostPaths};
use crate::wire::agent_jobs::*;

const SCOPED_SOCKET_ENV: &str = "RC_AGENT_JOB_SOCKET";
const MAX_INVENTORY_PAGES: usize = 50;

#[derive(Clone, Debug, Subcommand)]
pub(crate) enum AgentCommand {
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
    NativeParent,
    Items {
        target: String,
        #[arg(long)]
        json: bool,
    },
}

#[derive(Clone, Debug, Args)]
pub(crate) struct CallerArgs {
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
    #[arg(long, value_parser = ["original", "current"], requires = "resume")]
    parent: Option<String>,
    #[command(flatten)]
    caller: CallerArgs,
    #[arg(long)]
    json: bool,
}

#[derive(Clone, Debug, Args)]
pub(crate) struct ListArgs {
    target: Option<String>,
    #[arg(long)]
    active: bool,
    #[arg(long, value_parser = ["codex", "claude"])]
    provider: Option<String>,
    #[arg(long)]
    automations: bool,
    #[arg(long, default_value_t = 20, value_parser = clap::value_parser!(u32).range(1..=200))]
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

#[derive(Debug)]
struct RpcFailure(Value);

#[derive(Debug)]
struct NoMatchingJob;

impl std::fmt::Display for NoMatchingJob {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("No job matches this selector")
    }
}

impl std::error::Error for NoMatchingJob {}

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
    endpoint: &GatewayEndpoint,
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
    endpoint: &GatewayEndpoint,
    method: &str,
    params: P,
) -> Result<R> {
    let response = transport::call(endpoint, method, serde_json::to_value(params)?).await?;
    Ok(serde_json::from_value(response_value(response)?)?)
}

async fn scoped(request: ScopedRequest) -> Result<Value> {
    let path = std::env::var_os(SCOPED_SOCKET_ENV).context("No scoped agent route is available")?;
    response_value(transport::scoped(Path::new(&path), &request).await?)
}

async fn mutation<P: Serialize>(
    endpoint: &GatewayEndpoint,
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

fn endpoint(env_file: Option<&Path>) -> Result<GatewayEndpoint> {
    let default_file = HostPaths::from_env()?.state("codex-gateway.env");
    let env_file = env_file.or_else(|| default_file.exists().then_some(default_file.as_path()));
    GatewayEndpoint::load(&ConfigSources::load(env_file)?)
}

async fn capture(endpoint: &GatewayEndpoint) -> Result<CapturedContext> {
    let pid = std::process::id();
    let identity = crate::platform::process::identify(i32::try_from(pid)?)?
        .context("The caller process no longer has a verifiable identity")?;
    rpc(endpoint, "agent/context/capture", CaptureParams {
        pid,
        started_at_unix_micros: identity.started_micros,
    }).await.context("Cannot prove the calling agent; capture context before detaching, pass --caller-context explicitly, or select --operator for deliberate standalone work")
}

async fn caller(endpoint: &GatewayEndpoint, arguments: &CallerArgs) -> Result<Caller> {
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

async fn model_catalog(endpoint: &GatewayEndpoint) -> Result<Vec<models::Model>> {
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
    endpoint: &GatewayEndpoint,
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

async fn list_page(
    endpoint: &GatewayEndpoint,
    cursor: Option<String>,
    limit: u32,
) -> Result<ListPage> {
    rpc(
        endpoint,
        "agent/jobs/list",
        ListParams {
            selector: ListSelector::Recent,
            limit,
            cursor,
        },
    )
    .await
}

fn summary_matches(summary: &JobSummary, target: &str) -> bool {
    summary.job_id.as_str().ends_with(target)
        || match &summary.conversation {
            ConversationBinding::Known { conversation } => {
                conversation.thread_id == target
                    || conversation.thread_id.strip_prefix("claude_") == Some(target)
            }
            ConversationBinding::Unknown { .. } => false,
        }
}

async fn resolve(endpoint: &GatewayEndpoint, target: &str) -> Result<JobId> {
    if let Ok(job_id) = JobId::try_from(target.to_owned()) {
        return Ok(job_id);
    }
    ensure!(
        target.len() >= 4,
        "Use an exact run ID, provider session ID or suffix of at least four characters"
    );
    let mut cursor = None;
    let mut matches = Vec::new();
    for _ in 0..MAX_INVENTORY_PAGES {
        let page = list_page(endpoint, cursor, 200).await?;
        matches.extend(
            page.jobs
                .into_iter()
                .filter(|summary| summary_matches(summary, target)),
        );
        cursor = page.next_cursor;
        if cursor.is_none() {
            let run_matches = matches
                .iter()
                .filter(|row| row.job_id.as_str().ends_with(target))
                .collect::<Vec<_>>();
            if let [row] = run_matches.as_slice() {
                return Ok(row.job_id.clone());
            }
            if run_matches.is_empty()
                && matches
                    .first()
                    .is_some_and(|first| matches.iter().all(|row| row.agent_id == first.agent_id))
            {
                let view: JobView = rpc(
                    endpoint,
                    "agent/jobs/read",
                    ReadParams {
                        job_id: matches[0].job_id.clone(),
                    },
                )
                .await?;
                return view
                    .agent
                    .context(
                        "Conversation history has no resolved agent identity; use an exact run ID",
                    )?
                    .latest_job_id
                    .context("Conversation latest job is unresolved; use an exact run ID");
            }
            return match matches.as_slice() {
                [] => Err(NoMatchingJob.into()),
                _ => bail!("Job selector {target:?} is ambiguous; use an exact run ID"),
            };
        }
    }
    bail!("Job discovery is incomplete after 10,000 entries; use an exact run ID")
}

async fn read(endpoint: &GatewayEndpoint, target: &str) -> Result<JobView> {
    rpc(
        endpoint,
        "agent/jobs/read",
        ReadParams {
            job_id: resolve(endpoint, target).await?,
        },
    )
    .await
}

fn conversation_from_header(header: &Value) -> Result<ConversationIdentity> {
    let thread_id = header["id"]
        .as_str()
        .context("Conversation has no exact ID")?;
    let provider = if thread_id.starts_with("claude_") {
        Provider::Claude
    } else {
        Provider::Codex
    };
    let path = Path::new(
        header["path"]
            .as_str()
            .context("Conversation has no authoritative history path")?,
    );
    ensure!(
        path.is_absolute(),
        "Conversation history path is not absolute"
    );
    let directory = match provider {
        Provider::Claude => "projects",
        Provider::Codex => "sessions",
    };
    let home = path
        .ancestors()
        .find(|path| {
            path.file_name().is_some_and(|name| {
                name == directory || (provider == Provider::Codex && name == "archived_sessions")
            })
        })
        .and_then(Path::parent)
        .context("Conversation history path does not identify a provider home")?;
    Ok(ConversationIdentity {
        provider,
        provider_home: ProviderHome::Known {
            path: home.to_owned(),
        },
        thread_id: thread_id.to_owned(),
    })
}

async fn native_recipient(
    endpoint: &GatewayEndpoint,
    target: &str,
) -> Result<ConversationIdentity> {
    if target.starts_with("claude_") || target.starts_with("codex:") {
        let id = target.strip_prefix("codex:").unwrap_or(target);
        let response: Value = rpc(
            endpoint,
            "thread/read",
            json!({"threadId":id,"includeTurns":false}),
        )
        .await?;
        ensure!(
            response["thread"]["id"] == id,
            "Gateway returned a different conversation"
        );
        return conversation_from_header(&response["thread"]);
    }
    let mut cursor = Value::Null;
    let mut matches = Vec::new();
    for _ in 0..MAX_INVENTORY_PAGES {
        let page: Value = rpc(
            endpoint,
            "thread/list",
            json!({"limit":200,"cursor":cursor}),
        )
        .await?;
        for header in page["data"]
            .as_array()
            .context("Gateway returned no conversation page")?
        {
            let id = header["id"]
                .as_str()
                .context("Conversation has no exact ID")?;
            if id == target || id.strip_prefix("claude_") == Some(target) {
                matches.push(conversation_from_header(header)?);
            }
        }
        cursor = page["nextCursor"].clone();
        if cursor.is_null() {
            return match matches.as_slice() {
                [conversation] => Ok(conversation.clone()),
                [] => bail!("No job or native conversation matches {target:?}"),
                _ => bail!("Native conversation is ambiguous; use claude_UUID or codex:UUID"),
            };
        }
    }
    bail!("Native conversation discovery exceeded its page budget; use claude_UUID or codex:UUID")
}

fn execution_status(job: &JobRecord) -> &'static str {
    match &job.execution {
        ExecutionState::Admitted => "admitted",
        ExecutionState::Bound { .. } => "bound",
        ExecutionState::Dispatching { .. } => "dispatchUncertain",
        ExecutionState::Running { .. } => "running",
        ExecutionState::Recovering { .. } => "recovering",
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
    json!({"run_id":receipt.job.job_id,"agent_id":receipt.job.agent_id,
        "provider_session_id":provider_session_id,"status":execution_status(&receipt.job),"duplicate":receipt.duplicate,"job":receipt.job})
}

async fn spawn(endpoint: &GatewayEndpoint, arguments: SpawnArgs) -> Result<Value> {
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
        let source = read(endpoint, target).await?;
        let (original_settings, original_scope) = match &source.job.spec {
            SpecEvidence::Known { spec } => (&spec.settings, &spec.tool_scope),
            SpecEvidence::Expired {
                settings,
                tool_scope,
                ..
            } => (settings, tool_scope),
            SpecEvidence::Unknown { .. } => bail!(
                "Historical execution settings are unknown; continuation needs resolved provider evidence"
            ),
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
            recipient: if arguments.parent.as_deref() == Some("current") {
                ContinueRecipient::Current
            } else {
                ContinueRecipient::Previous
            },
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
    let cwd = arguments
        .cwd
        .unwrap_or(std::env::current_dir()?)
        .canonicalize()?;
    ensure!(cwd.is_dir(), "Working directory must be a directory");
    let tool_scope = match arguments.preset.as_deref().unwrap_or("full-access") {
        "full-access" => {
            ensure!(
                arguments.sandbox_root.is_none(),
                "--sandbox-root requires --preset read-only"
            );
            ToolScope::Full
        }
        "read-only" => {
            let root = arguments
                .sandbox_root
                .context("Read-only agents require --sandbox-root")?
                .canonicalize()?;
            ensure!(
                root.is_dir() && cwd.starts_with(&root),
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

fn formatting_identity(
    explicit: Option<&str>,
    codex: Option<&str>,
    claude: Option<&str>,
) -> Result<(String, &'static str)> {
    if let Some(explicit) = explicit {
        return Ok((explicit.to_owned(), "native"));
    }
    match (
        codex.filter(|id| !id.trim().is_empty()),
        claude.filter(|id| !id.trim().is_empty()),
    ) {
        (Some(id), None) => Ok((id.to_owned(), "codex")),
        (None, Some(id)) => Ok((
            format!("claude_{}", id.strip_prefix("claude_").unwrap_or(id)),
            "claude",
        )),
        (Some(_), Some(_)) => bail!(
            "Formatting identity is ambiguous; pass --sender-id, --reply-tool and --reply-target"
        ),
        (None, None) => bail!(
            "Formatting needs CODEX_THREAD_ID or CLAUDE_CODE_SESSION_ID, or explicit --sender-id, --reply-tool and --reply-target"
        ),
    }
}

fn host() -> Result<String> {
    Ok(nix::unistd::gethostname()?
        .to_string_lossy()
        .split('.')
        .next()
        .context("Host has no name")?
        .to_owned())
}

async fn message(
    endpoint: &GatewayEndpoint,
    arguments: MessageArgs,
    text: String,
) -> Result<Value> {
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
        match resolve(endpoint, &arguments.target).await {
            Ok(job_id) => MessageTarget::Job { job_id },
            Err(error) if error.is::<NoMatchingJob>() => MessageTarget::Conversation {
                conversation: native_recipient(endpoint, &arguments.target).await?,
            },
            Err(error) => return Err(error),
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

async fn items(endpoint: &GatewayEndpoint, target: &str) -> Result<Value> {
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

async fn execute(command: AgentCommand, env_file: Option<&Path>) -> Result<Value> {
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
    if let AgentCommand::Read { target, caller, .. } = &command
        && target == "self"
        && use_scoped(caller)
    {
        return scoped(ScopedRequest::ReadSelf {}).await;
    }
    if let AgentCommand::Message(arguments) = &command {
        if arguments.format_only {
            let host = host()?;
            let inferred = formatting_identity(
                arguments.sender_id.as_deref(),
                std::env::var("CODEX_THREAD_ID").ok().as_deref(),
                std::env::var("CLAUDE_CODE_SESSION_ID").ok().as_deref(),
            )?;
            let reply_tool = format!("codex-threads send --host {host}");
            let sender = Sender {
                agent_id: &inferred.0,
                provider: inferred.1,
                host: &host,
                reply_tool: arguments.reply_tool.as_deref().unwrap_or(&reply_tool),
                reply_target: arguments.reply_target.as_deref().unwrap_or(&inferred.0),
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
    let endpoint = endpoint(env_file)?;
    match command {
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
            let mut cursor = None;
            let mut rows = Vec::new();
            for _ in 0..MAX_INVENTORY_PAGES {
                let page = list_page(&endpoint, cursor, 200).await?;
                rows.extend(page.jobs.into_iter().filter(|row| {
                    (!arguments.active || row.state.may_be_running())
                        && arguments
                            .provider
                            .as_deref()
                            .is_none_or(|provider| row.provider.as_str() == provider)
                }));
                cursor = page.next_cursor;
                if cursor.is_none() || rows.len() > arguments.last as usize {
                    break;
                }
            }
            ensure!(
                cursor.is_none() || rows.len() > arguments.last as usize,
                "Job discovery is incomplete; use an exact selector"
            );
            let truncated = cursor.is_some() || rows.len() > arguments.last as usize;
            rows.truncate(arguments.last as usize);
            let rows = rows.into_iter().map(|row| {
                let provider_session_id = match &row.conversation { ConversationBinding::Known { conversation } => Some(conversation.thread_id.strip_prefix("claude_").unwrap_or(&conversation.thread_id)), ConversationBinding::Unknown { .. } => None };
                json!({"run_id":row.job_id,"agent_id":row.agent_id,"provider":row.provider,"provider_session_id":provider_session_id,"cwd":row.cwd,"model":row.model,"title":row.title,"state":row.state,"created_at_epoch_ms":row.created_at_ms,"last_active_at_epoch_ms":row.updated_at_ms,"conversation":row.conversation})
            }).collect::<Vec<_>>();
            Ok(
                json!({"agents":rows,"warnings":if truncated { vec!["Agent list is limited; more matching history may exist"] } else { Vec::<&str>::new() }}),
            )
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
        AgentCommand::Capture => Ok(serde_json::to_value(capture(&endpoint).await?)?),
        AgentCommand::Items { target, .. } => items(&endpoint, &target).await,
        AgentCommand::NativeParent => {
            unreachable!("native holder was handled before operator credential loading")
        }
    }
}

pub(crate) async fn run(command: AgentCommand, env_file: Option<&Path>) -> Result<i32> {
    let format_only = matches!(&command, AgentCommand::Message(arguments) if arguments.format_only);
    let compact = match &command {
        AgentCommand::Spawn(arguments) => arguments.json,
        AgentCommand::Message(arguments) => arguments.json,
        AgentCommand::List(arguments) => arguments.json,
        AgentCommand::Read { json, .. } | AgentCommand::Items { json, .. } => *json,
        _ => true,
    };
    match execute(command, env_file).await {
        Ok(Value::String(text)) if format_only => {
            println!("{text}");
            Ok(0)
        }
        Ok(result) => {
            println!(
                "{}",
                if compact {
                    serde_json::to_string(&result)?
                } else {
                    serde_json::to_string_pretty(&result)?
                }
            );
            Ok(0)
        }
        Err(error) => {
            let (exit, payload) = if let Some(error) = error.downcast_ref::<RpcFailure>() {
                let exit = if error.0["retryable"] == true || error.0["data"]["retryable"] == true {
                    75
                } else {
                    69
                };
                (exit, error.0.clone())
            } else if let Some(error) = error.downcast_ref::<transport::TransportError>() {
                (
                    if error.submission == transport::Submission::Uncertain {
                        75
                    } else {
                        69
                    },
                    json!({"kind":if error.submission == transport::Submission::Uncertain {"submissionUncertain"} else {"unavailable"},"message":error.to_string(),"retryable":false}),
                )
            } else {
                (
                    64,
                    json!({"kind":"invalidRequest","message":format!("{error:#}"),"retryable":false}),
                )
            };
            let request_id = error
                .downcast_ref::<RequestIdentity>()
                .map(|identity| identity.0.as_str());
            println!(
                "{}",
                serde_json::to_string(
                    &json!({"ok":false,"request_id":request_id,"error":payload})
                )?
            );
            Ok(exit)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formatting_infers_exact_provider_identity_without_authenticated_capture() {
        assert_eq!(
            formatting_identity(None, Some("codex-thread"), None).unwrap(),
            ("codex-thread".into(), "codex")
        );
        assert_eq!(
            formatting_identity(None, None, Some("claude-session")).unwrap(),
            ("claude_claude-session".into(), "claude")
        );
        assert!(formatting_identity(None, Some("a"), Some("b")).is_err());
        assert!(formatting_identity(None, None, None).is_err());
        assert_eq!(
            formatting_identity(Some("/root/worker"), Some("a"), Some("b")).unwrap(),
            ("/root/worker".into(), "native")
        );
    }
}
