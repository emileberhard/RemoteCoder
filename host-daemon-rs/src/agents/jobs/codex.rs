use std::collections::HashSet;
use std::sync::Arc;

use anyhow::{Context, Result, bail, ensure};
use serde_json::{Map, Value, json};

use super::model::*;
use super::result::bounded_result;
use crate::gateway::Gateway;
use crate::gateway::agent_jobs_codex::NativeInputFact;

const RESULT_PAGE_SIZE: usize = 100;
const RESULT_PAGES: usize = 16;
const READ_ONLY_DISABLED_FEATURES: [&str; 8] = [
    "apps",
    "codex_hooks",
    "enable_mcp_apps",
    "plugins",
    "recommended_plugins",
    "remote_plugin",
    "plugin_sharing",
    "tool_suggest",
];

pub(crate) async fn create(
    gateway: &Arc<Gateway>,
    id: &JobId,
    spec: &JobSpec,
) -> Result<ConversationIdentity> {
    let mut params = thread_params(gateway, id, spec).await?;
    if matches!(spec.tool_scope, ToolScope::Full) {
        params["dynamicTools"] = crate::agents::tools::codex_dynamic_tools();
    }
    let created = gateway.job_native_call("thread/start", params).await?;
    let thread_id = created
        .pointer("/thread/id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .context("Codex did not return the created thread identity")?
        .to_owned();
    let conversation = ConversationIdentity {
        provider: Provider::Codex,
        provider_home: ProviderHome::Known {
            path: gateway.job_codex_home()?,
        },
        thread_id,
    };
    if let Some(title) = &spec.title {
        gateway
            .job_native_call(
                "thread/name/set",
                json!({"threadId":conversation.thread_id,"name":title}),
            )
            .await?;
    }
    gateway
        .job_native_call("thread/persist", json!({"threadId":conversation.thread_id}))
        .await?;
    Ok(conversation)
}

pub(crate) async fn start(gateway: &Arc<Gateway>, job: &JobRecord) -> Result<ExecutionBinding> {
    ensure!(
        job.source == JobSource::Runtime,
        "imported input cannot be dispatched"
    );
    ensure!(
        matches!(job.stop, StopState::NotRequested),
        "the job has a durable Stop request"
    );
    let conversation = conversation(job)?;
    verify_home(gateway, conversation)?;
    let SpecEvidence::Known { spec } = &job.spec else {
        bail!("the original Codex input specification is unavailable");
    };
    let input_id = job.current_input_id();
    if let ExecutionState::Dispatching {
        input_id: retained, ..
    } = &job.execution
    {
        ensure!(retained == &input_id, "the retained input identity changed");
    }
    let mut resume = thread_params(gateway, &job.job_id, spec).await?;
    resume["threadId"] = json!(conversation.thread_id);
    resume["excludeTurns"] = json!(true);
    let resumed = gateway.job_native_call("thread/resume", resume).await?;
    ensure!(
        resumed.pointer("/thread/id").and_then(Value::as_str)
            == Some(conversation.thread_id.as_str()),
        "Codex resumed a different thread"
    );
    let ExecutionSettings::Codex {
        model,
        effort,
        service_tier,
        cyber_access_program,
        ..
    } = &spec.settings
    else {
        bail!("Codex job has settings for another provider");
    };
    let sandbox = match spec.tool_scope {
        ToolScope::Full => json!({"type":"dangerFullAccess"}),
        ToolScope::ReadOnly { .. } => json!({"type":"readOnly","networkAccess":true}),
    };
    let response = gateway
        .job_start_codex_input(json!({
            "threadId":conversation.thread_id,
            "clientUserMessageId":input_id,
            "input":[{"type":"text","text":if job.provider_retries.is_empty() { spec.prompt.as_str() } else { super::retry::CONTINUATION_PROMPT }}],
            "cwd":spec.cwd,
            "model":model,
            "effort":effort,
            "serviceTier":service_tier,
            "cyberAccessProgram":cyber_access_program,
            "approvalPolicy":"never",
            "sandboxPolicy":sandbox,
        }))
        .await?;
    let turn_id = response
        .pointer("/turn/id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .context("Codex did not return the accepted turn identity")?
        .to_owned();
    if let ExecutionState::Running { binding } | ExecutionState::Recovering { binding, .. } =
        &job.execution
    {
        ensure!(
            binding.input_id == input_id && binding.turn_id == turn_id,
            "Codex changed the original accepted execution binding"
        );
    }
    Ok(ExecutionBinding {
        conversation: conversation.clone(),
        input_id,
        turn_id,
    })
}

pub(crate) async fn inspect(gateway: &Arc<Gateway>, job: &JobRecord) -> Result<Inspection> {
    let conversation = conversation(job)?;
    verify_home(gateway, conversation)?;
    let input_id = job.current_input_id();
    let Some(accepted) = gateway
        .job_read_codex_acceptance(&conversation.thread_id, &input_id)
        .await?
    else {
        return Ok(
            if job.source == JobSource::Runtime
                && matches!(
                    job.execution,
                    ExecutionState::Dispatching { .. } | ExecutionState::Unknown { .. }
                )
                && matches!(job.spec, SpecEvidence::Known { .. })
            {
                Inspection::RetryableInput {
                    conversation: conversation.clone(),
                    input_id,
                }
            } else {
                Inspection::Unknown {
                    reason: "the native owner has no acceptance evidence for the exact input"
                        .into(),
                }
            },
        );
    };
    let binding = ExecutionBinding {
        conversation: conversation.clone(),
        input_id,
        turn_id: accepted.turn_id.clone(),
    };
    if let Some(retained) = job.execution.binding() {
        ensure!(
            retained == &binding,
            "native input acceptance changed its binding"
        );
    }
    if accepted.has(NativeInputFact::Rejected) {
        return Ok(Inspection::Finished {
            outcome: JobOutcome::Failed {
                reason: "the native input owner rejected the accepted input".into(),
            },
            result: ResultEvidence::Unavailable {
                reason: "the rejected input has no final result".into(),
            },
        });
    }
    if accepted.has(NativeInputFact::Stopped) {
        return Ok(Inspection::Finished {
            outcome: JobOutcome::Stopped {
                effects: EffectEvidence::MayHaveRun,
            },
            result: ResultEvidence::Unavailable {
                reason: "the input was explicitly stopped".into(),
            },
        });
    }
    if accepted.has(NativeInputFact::Suspended) {
        return Ok(Inspection::Unknown {
            reason: "the exact native input awaits its existing restart recovery owner".into(),
        });
    }
    if !accepted.has(NativeInputFact::Recorded) && !accepted.has(NativeInputFact::Terminal) {
        return Ok(Inspection::Recoverable { binding });
    }
    let inspected = gateway
        .job_inspect_turn(&conversation.thread_id, &accepted.turn_id)
        .await
        .map_err(|error| anyhow::anyhow!("{}", error.message))?;
    ensure!(
        inspected["executionTurnId"].as_str() == Some(accepted.turn_id.as_str()),
        "exact Codex inspection returned another execution"
    );
    if inspected["outcome"]["state"] == "known" {
        let outcome = match inspected["outcome"]["status"].as_str() {
            Some("completed") => JobOutcome::Completed,
            Some("failed")
                if accepted.has(NativeInputFact::Recorded)
                    && super::retry::is_transient(&inspected["outcome"]["error"])
                    && job.provider_retries.len() < super::retry::MAX_PROVIDER_RETRIES =>
            {
                return Ok(Inspection::TransientFailure {
                    binding,
                    reason: inspected["outcome"]["error"]["message"]
                        .as_str()
                        .unwrap_or("transient native provider failure")
                        .to_owned(),
                });
            }
            Some("failed") => JobOutcome::Failed {
                reason: {
                    let reason = inspected["outcome"]["error"]["message"]
                        .as_str()
                        .unwrap_or("the native turn failed without a recorded error message");
                    if job.provider_retries.len() == super::retry::MAX_PROVIDER_RETRIES
                        && super::retry::is_transient(&inspected["outcome"]["error"])
                    {
                        format!(
                            "provider retry budget exhausted after {} retries: {reason}",
                            job.provider_retries.len()
                        )
                    } else {
                        reason.to_owned()
                    }
                },
            },
            Some("interrupted") => JobOutcome::Stopped {
                effects: EffectEvidence::MayHaveRun,
            },
            _ => bail!("Codex inspection returned an unsupported terminal status"),
        };
        return Ok(Inspection::Finished {
            outcome,
            result: final_result(gateway, &binding).await?,
        });
    }
    Ok(match inspected["activity"].as_str() {
        Some("running") if !accepted.has(NativeInputFact::Terminal) => {
            Inspection::Running { binding }
        }
        Some("recovering" | "unknown") => Inspection::Pending {
            reason: format!(
                "exact Codex activity is not yet observable: {}",
                inspected["outcome"]["reason"]
                    .as_str()
                    .unwrap_or("unrecognized native inspection")
            ),
        },
        _ => Inspection::Unknown {
            reason: format!(
                "exact Codex terminal evidence is unavailable: {}",
                inspected["outcome"]["reason"]
                    .as_str()
                    .unwrap_or("unrecognized native inspection")
            ),
        },
    })
}

pub(crate) async fn recover(gateway: &Arc<Gateway>, job: &JobRecord) -> Result<ExecutionBinding> {
    let target = conversation(job)?;
    let accepted = gateway
        .job_read_codex_acceptance(&target.thread_id, &job.current_input_id())
        .await?
        .context("native input recovery has no exact acceptance evidence")?;
    ensure!(
        !accepted.has(NativeInputFact::Recorded)
            && !accepted.has(NativeInputFact::Terminal)
            && !accepted.has(NativeInputFact::Suspended),
        "recorded or suspended work belongs to the native restart recovery owner"
    );
    start(gateway, job).await
}

pub(crate) async fn stop(gateway: &Arc<Gateway>, job: &JobRecord) -> Result<()> {
    let target = conversation(job)?;
    verify_home(gateway, target)?;
    let input_id = job.current_input_id();
    gateway
        .job_stop_codex_input(&target.thread_id, &input_id)
        .await
        .map_err(|error| anyhow::anyhow!("{}", error.message))?;
    Ok(())
}

fn conversation(job: &JobRecord) -> Result<&ConversationIdentity> {
    match &job.execution {
        ExecutionState::Bound { conversation }
        | ExecutionState::Dispatching { conversation, .. } => Ok(conversation),
        ExecutionState::Running { binding } | ExecutionState::Recovering { binding, .. } => {
            Ok(&binding.conversation)
        }
        ExecutionState::Unknown {
            conversation: Some(conversation),
            ..
        } => Ok(conversation),
        _ => bail!("job has no exact Codex conversation"),
    }
}

fn verify_home(gateway: &Gateway, target: &ConversationIdentity) -> Result<()> {
    ensure!(
        target.provider == Provider::Codex,
        "the conversation is not Codex"
    );
    let ProviderHome::Known { path } = &target.provider_home else {
        bail!("the native provider home is unresolved");
    };
    ensure!(
        path == &gateway.job_codex_home()?,
        "the exact Codex provider home is not hosted by this gateway"
    );
    Ok(())
}

async fn thread_params(gateway: &Gateway, id: &JobId, spec: &JobSpec) -> Result<Value> {
    let ExecutionSettings::Codex {
        model,
        model_provider,
        service_tier,
        ..
    } = &spec.settings
    else {
        bail!("Codex thread settings use another provider");
    };
    let socket = gateway.job_coordination_socket(id);
    let mut config = json!({
        "shell_environment_policy":{"set":{"RC_AGENT_JOB_SOCKET":socket}}
    });
    if let ToolScope::ReadOnly { root } = &spec.tool_scope {
        ensure!(
            spec.cwd.starts_with(root),
            "working directory is outside the read-only root"
        );
        let effective = gateway
            .job_native_call("config/read", json!({"cwd":spec.cwd,"includeLayers":false}))
            .await?;
        let effective = effective["config"]
            .as_object()
            .context("Codex returned no effective read-only configuration")?;
        let servers = match effective.get("mcp_servers") {
            None => Map::new(),
            Some(value) => value
                .as_object()
                .context("Codex returned an invalid effective MCP configuration")?
                .clone(),
        };
        config["shell_environment_policy"]["inherit"] = json!("core");
        config["mcp_servers"] = Value::Object(
            servers
                .keys()
                .map(|name| (name.clone(), json!({"enabled":false})))
                .collect(),
        );
        config["features"] = Value::Object(
            READ_ONLY_DISABLED_FEATURES
                .into_iter()
                .map(|name| (name.to_owned(), json!(false)))
                .collect(),
        );
    }
    Ok(json!({
        "model":model,
        "modelProvider":model_provider,
        "serviceTier":service_tier,
        "cwd":spec.cwd,
        "approvalPolicy":"never",
        "config":config,
    }))
}

async fn final_result(gateway: &Gateway, binding: &ExecutionBinding) -> Result<ResultEvidence> {
    let mut cursor: Option<String> = None;
    let mut seen = HashSet::new();
    for _ in 0..RESULT_PAGES {
        let page = gateway
            .job_native_call(
                "thread/items/list",
                json!({
                    "threadId":binding.conversation.thread_id,
                    "turnId":binding.turn_id,
                    "limit":RESULT_PAGE_SIZE,
                    "sortDirection":"desc",
                    "cursor":cursor,
                }),
            )
            .await?;
        let items = page["data"]
            .as_array()
            .context("native result page has no items")?;
        ensure!(
            items.len() <= RESULT_PAGE_SIZE,
            "native result page exceeds its bound"
        );
        if let Some(text) = final_text(items, &binding.turn_id)? {
            return Ok(ResultEvidence::Available {
                result: bounded_result(text.to_owned(), false)?,
            });
        }
        cursor = page["nextCursor"].as_str().map(str::to_owned);
        match &cursor {
            None => {
                return Ok(ResultEvidence::Unavailable {
                    reason: "the exact terminal turn has no recorded final answer".into(),
                });
            }
            Some(cursor) => ensure!(seen.insert(cursor.clone()), "native result cursor repeated"),
        }
    }
    Ok(ResultEvidence::Unavailable {
        reason: "the final answer exceeds the bounded native history scan".into(),
    })
}

fn final_text<'a>(items: &'a [Value], turn: &str) -> Result<Option<&'a str>> {
    for entry in items {
        ensure!(
            entry["turnId"].as_str() == Some(turn),
            "native result page contains a different turn"
        );
        if entry["item"]["type"] == "agentMessage"
            && (entry["item"]["phase"].is_null() || entry["item"]["phase"] == "final_answer")
        {
            return Ok(Some(
                entry["item"]["text"]
                    .as_str()
                    .context("final answer has no text")?,
            ));
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_result_retains_unclassified_native_model_text() {
        let items = [
            json!({"turnId":"turn","item":{"type":"agentMessage","phase":"commentary","text":"still working"}}),
            json!({"turnId":"turn","item":{"type":"agentMessage","phase":null,"text":"The result"}}),
        ];
        assert_eq!(final_text(&items, "turn").unwrap(), Some("The result"));
        assert!(final_text(&items, "another-turn").is_err());
    }
}
