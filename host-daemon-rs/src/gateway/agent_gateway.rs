use super::Gateway;
use crate::agents::{Agent, State, claude};
use crate::rpc::RpcError;
use crate::rpc::error::RpcCode;
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

pub(super) use service::AgentOwners;
pub(super) use service::ThreadRelation;
pub(super) use stop::CodexStop;

#[derive(Default)]
pub(super) struct Runtime {
    pub(super) parents: Mutex<HashMap<String, ParentSnapshot>>,
    claude_history: Mutex<VecDeque<ClaudeHistorySnapshot>>,
    native_executions: Mutex<VecDeque<NativeExecutionSnapshot>>,
    views: Mutex<VecDeque<AgentViewSnapshot>>,
}

pub(super) const NOTIFICATION_ANCESTRY_BUDGET: Duration = Duration::from_secs(2);
const TRUNCATED_NATIVE_AGENTS: &str = "More than 256 native agents; showing the first page set";
pub(super) const TURN_CHECK_WAIT: Duration = Duration::from_secs(3);
pub(super) const DESCENDANT_STOP_WAIT: Duration = Duration::from_secs(10);
pub(super) const CHILD_STOP_WAIT: Duration = Duration::from_secs(5);
pub(super) const CHILD_STOP_CONCURRENCY: usize = 4;
pub(super) const NO_ACTIVE_TURN: &str = "no active turn to interrupt";
pub(super) const THREAD_NOT_LOADED: &str = "thread not found";

pub(super) fn parse_native_error(text: &str) -> Option<RpcError> {
    serde_json::from_str::<Value>(text)
        .ok()
        .filter(|native| native["code"].is_i64())
        .map(|native| RpcError::from_wire(&native))
}

pub(super) fn native_error(error: &anyhow::Error) -> RpcError {
    crate::rpc::error::CodexUnavailable::find(error)
        .or_else(|| parse_native_error(&error.to_string()))
        .unwrap_or_else(|| RpcError::new(RpcCode::Internal, format!("{error:#}")))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClassifyParams {
    thread_ids: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ListParams {
    thread_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct AgentRef {
    pub(super) agent_id: String,
    pub(super) thread_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ActionParams {
    #[serde(flatten)]
    pub(super) agent: AgentRef,
    pub(super) action: String,
    #[serde(default)]
    pub(super) execution_id: Option<String>,
    #[serde(default)]
    pub(super) text: Option<String>,
    #[serde(default)]
    pub(super) mutation_id: Option<String>,
}

fn decode<T: serde::de::DeserializeOwned>(params: Value) -> std::result::Result<T, RpcError> {
    serde_json::from_value(params)
        .map_err(|error| RpcError::new(RpcCode::InvalidParams, error.to_string()))
}

pub(super) fn coverage_failure_codes(error: &anyhow::Error) -> Vec<&'static str> {
    if error.is::<tokio::time::error::Elapsed>() {
        return vec!["ancestryTimeout"];
    }
    vec!["ancestryUnavailable"]
}

struct NativeExecutionSnapshot {
    root: String,
    entries: HashMap<String, NativeExecution>,
}

#[derive(Clone)]
struct NativeExecution {
    read_at: Instant,
    updated_at: Value,
    status: Value,
    state: State,
    execution_id: Option<String>,
}

struct ClaudeHistorySnapshot {
    root: String,
    revision: Vec<(PathBuf, Option<crate::storage::file_revision::FileRevision>)>,
    projection: claude::Projection,
}

struct AgentViewSnapshot {
    root: String,
    at: Instant,
    agents: Vec<Agent>,
}

#[derive(Clone)]
pub(super) struct ParentSnapshot {
    pub(super) at: Instant,
    pub(super) parent: Option<String>,
    pub(super) available: bool,
}

#[derive(Default)]
pub(super) struct NativeCoverage {
    truncated: bool,
    pub(super) unreadable: Vec<String>,
    history_limited: bool,
}

impl NativeCoverage {
    pub(super) fn is_truncated(&self) -> bool {
        self.truncated
    }

    pub(super) fn warnings(&self) -> Vec<String> {
        let mut warnings = self
            .unreadable
            .iter()
            .map(|id| format!("Latest execution unavailable for {id}"))
            .collect::<Vec<_>>();
        if self.truncated {
            warnings.push(TRUNCATED_NATIVE_AGENTS.into());
        }
        if self.history_limited {
            warnings.push("Some Claude agent history is outside the read window".into());
        }
        warnings
    }
}

pub(super) struct NativeInventory {
    pub(super) agents: Vec<Agent>,
    pub(super) coverage: NativeCoverage,
}

pub(super) fn native_parent(thread: &Value) -> Option<&str> {
    thread["parentThreadId"].as_str().or_else(|| {
        thread
            .pointer("/source/subAgent/thread_spawn/parent_thread_id")
            .and_then(Value::as_str)
    })
}

pub(super) fn native_agent_relation(header: &Value, requested: &str) -> Result<bool> {
    let thread = &header["thread"];
    ensure!(
        thread["id"].as_str() == Some(requested),
        "Native ancestry returned an unverified thread identity"
    );
    if thread["parentThreadId"]
        .as_str()
        .is_some_and(|id| !id.is_empty())
        || thread["source"]
            .get("subAgent")
            .is_some_and(|source| !source.is_null())
    {
        return Ok(true);
    }
    ensure!(
        thread.get("parentThreadId").is_none_or(Value::is_null),
        "Native ancestry parent identity is malformed"
    );
    // SessionSource is required by the pinned ThreadReadResponse. Its `unknown`
    // enum case is a valid origin; an absent/future/malformed field is not a
    // successfully decoded native non-child response.
    let source = &thread["source"];
    let valid_source = matches!(
        source.as_str(),
        Some("cli" | "vscode" | "exec" | "appServer" | "unknown")
    ) || source.as_object().is_some_and(|object| {
        object.len() == 1 && object.get("custom").is_some_and(Value::is_string)
    });
    ensure!(valid_source, "Native ancestry source is unavailable");
    Ok(false)
}

impl Gateway {
    pub(super) async fn latest_codex_turn(
        &self,
        thread: &str,
        wait: Option<Duration>,
    ) -> Result<Option<Value>> {
        let params =
            json!({"threadId":thread,"limit":1,"sortDirection":"desc","itemsView":"notLoaded"});
        let page = match wait {
            Some(wait) => {
                self.call_control_with_timeout("thread/turns/list", params, wait)
                    .await?
            }
            None => self.call_control("thread/turns/list", params).await?,
        };
        Ok(page["data"]
            .as_array()
            .context("the turn list is missing")?
            .first()
            .cloned())
    }

    pub(super) fn agent_home_for_thread(&self, thread: &str) -> Result<PathBuf> {
        let provider = if crate::providers::claude::is_claude_thread_id(thread) {
            crate::providers::Provider::Claude
        } else {
            crate::providers::Provider::Codex
        };
        let home = if provider == crate::providers::Provider::Claude {
            self.claude_settings.claude_home.clone()
        } else {
            self.codex_home()
                .context("Codex provider home is unavailable")?
                .to_path_buf()
        };
        let home = home.canonicalize().unwrap_or(home);
        ensure!(
            home.is_absolute() && home.to_str().is_some(),
            "Provider home is unavailable"
        );
        Ok(home)
    }

    pub(super) fn agent_conversation(
        &self,
        thread: &str,
    ) -> Result<crate::agents::jobs::model::ConversationIdentity> {
        use crate::agents::jobs::model::{ConversationIdentity, Provider, ProviderHome};
        crate::questions::validate_id(thread)?;
        let unsupported = |message| {
            crate::rpc::RpcError::new(crate::rpc::error::RpcCode::InvalidRequest, message)
                .with_data(crate::rpc::error::RpcData::Raw(
                    json!({"class":"unsupported","retryable":false}),
                ))
        };
        let provider = if let Some(sidecar) = thread.strip_prefix("claude:") {
            let (parent, child) = sidecar
                .split_once(':')
                .context("Invalid Claude sidecar identity")?;
            ensure!(
                crate::ids::is_session_uuid(parent) && !child.is_empty() && !child.contains(':'),
                "Invalid Claude sidecar identity"
            );
            return Err(unsupported("Claude child sidecars have no resumable provider thread; read them through sessions").into());
        } else if let Some(uuid) = thread.strip_prefix("claude_") {
            ensure!(
                crate::ids::is_session_uuid(uuid),
                "Invalid Claude conversation identity"
            );
            Provider::Claude
        } else if crate::ids::is_session_uuid(thread) {
            Provider::Codex
        } else {
            return Err(unsupported("Unrecognized provider conversation identity").into());
        };
        Ok(ConversationIdentity {
            provider,
            provider_home: ProviderHome::Known {
                path: self.agent_home_for_thread(thread)?,
            },
            thread_id: thread.to_owned(),
        })
    }
}

mod service;
mod stop;
#[cfg(test)]
mod tests;
