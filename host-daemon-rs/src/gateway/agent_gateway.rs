use super::Gateway;
use crate::agents::{Agent, State, claude, launcher};
use crate::rpc::RpcError;
use crate::rpc::error::RpcCode;
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

pub(super) use service::AgentOwners;
pub(super) use stop::CodexStop;

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub(super) enum LauncherPurpose {
    Inventory,
    Classification,
    Mutation,
}

#[derive(Default)]
pub(super) struct Runtime {
    launcher: Arc<service::inventory::LauncherReads>,
    classifications: service::classification::Classifications,
    pub(super) parents: Mutex<HashMap<String, ParentSnapshot>>,
    claude_history: Mutex<VecDeque<ClaudeHistorySnapshot>>,
    native_executions: Mutex<VecDeque<NativeExecutionSnapshot>>,
    views: Mutex<VecDeque<AgentViewSnapshot>>,
    notification_health: Mutex<NotificationHealth>,
    notification_preflight_task: Mutex<Option<JoinHandle<()>>>,
    launcher_program: std::sync::OnceLock<PathBuf>,
}

#[derive(Default)]
struct NotificationHealth {
    index: Option<Value>,
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
    parse_native_error(&error.to_string())
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
    error
        .downcast_ref::<launcher::CoverageUnavailable>()
        .map(|error| error.0.clone())
        .unwrap_or_else(|| vec!["ancestryUnavailable"])
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

const LAUNCHER_PAGING_WARNING: &str = "Launcher history is incomplete";
const LAUNCHER_LIMIT_WARNING: &str = "Launcher history exceeds the inventory limit";
const LAUNCHER_INCOMPLETE_WARNING: &str = "Launcher list coverage incomplete:";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum InventoryCoverage {
    Complete,
    Incomplete,
}

impl InventoryCoverage {
    fn read(paged_out: bool, warnings: &[String]) -> Self {
        if paged_out
            || warnings.iter().any(|warning| {
                warning == LAUNCHER_LIMIT_WARNING
                    || warning.starts_with(LAUNCHER_INCOMPLETE_WARNING)
            })
        {
            Self::Incomplete
        } else {
            Self::Complete
        }
    }
}

pub(super) struct LauncherInventory {
    pub(super) runs: Vec<launcher::Run>,
    pub(super) coverage: InventoryCoverage,
    pub(super) warnings: Vec<String>,
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
    #[cfg(test)]
    pub(crate) fn use_agent_launcher(&self, program: PathBuf) {
        self.agents.launcher_program.set(program).unwrap();
    }

    fn agent_launcher_program(&self) -> Result<PathBuf> {
        match self.agents.launcher_program.get() {
            Some(program) => Ok(program.clone()),
            None => launcher::default_program(),
        }
    }

    pub(super) async fn call_agent_launcher(
        &self,
        purpose: LauncherPurpose,
        request: Value,
    ) -> Result<Value> {
        let program = self.agent_launcher_program()?;
        self.agents.launcher.call(purpose, request, &program).await
    }

    pub(super) async fn stop_agent_inventory(&self) {
        self.agents.launcher.stop().await;
    }

    pub(super) async fn start_notification_ancestry_preflight(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        let task = tokio::spawn(async move {
            loop {
                let Some(gateway) = weak.upgrade() else { break };
                let started = Instant::now();
                let result = tokio::time::timeout(
                    NOTIFICATION_ANCESTRY_BUDGET,
                    gateway.call_agent_launcher(
                        LauncherPurpose::Classification,
                        json!({"operation":"status","schemaVersion":2}),
                    ),
                )
                .await
                .map_err(anyhow::Error::from)
                .and_then(|result| result.map_err(launcher::call_failure))
                .and_then(|response| launcher::readiness(&response));
                let snapshot = json!({"status":if result.is_ok() { "available" } else { "unavailable" },
                    "reasonCodes":result.as_ref().err().map(coverage_failure_codes).unwrap_or_default(),
                    "checkedAtUnixSeconds":crate::time::unix_seconds(),"elapsedMs":started.elapsed().as_millis()});
                gateway
                    .record_notification_ancestry_preflight(snapshot)
                    .await;
                drop(gateway);
                tokio::time::sleep(Duration::from_secs(60)).await;
            }
        });
        let previous = self
            .agents
            .notification_preflight_task
            .lock()
            .await
            .replace(task);
        if let Some(previous) = previous {
            previous.abort();
            let _ = previous.await;
        }
    }

    async fn record_notification_ancestry_preflight(&self, snapshot: Value) {
        let mut health = self.agents.notification_health.lock().await;
        if health.index.as_ref().is_none_or(|previous| {
            previous["status"] != snapshot["status"]
                || previous["reasonCodes"] != snapshot["reasonCodes"]
        }) {
            self.journal.push("ancestryPreflight", snapshot.clone());
        }
        health.index = Some(snapshot);
    }

    pub(super) async fn stop_notification_ancestry_preflight(&self) {
        let task = self.agents.notification_preflight_task.lock().await.take();
        if let Some(task) = task {
            task.abort();
            let _ = task.await;
        }
    }

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
                .ok_or_else(|| launcher::unavailable("providerHomeUnavailable"))?
                .to_path_buf()
        };
        let home = home.canonicalize().unwrap_or(home);
        ensure!(
            home.is_absolute() && home.to_str().is_some(),
            launcher::CoverageUnavailable(vec!["providerHomeUnavailable"])
        );
        Ok(home)
    }

    pub(super) fn admit_launcher_action_target(
        &self,
        action: &str,
        thread: Option<&str>,
    ) -> Result<Option<crate::gateway::admission::Admission>> {
        if action == "stop" {
            return Ok(None);
        }
        let target = thread.context("Agent thread is unavailable")?;
        self.admission.admit(target).map(Some)
    }

    pub(super) fn agent_homes(&self) -> Result<Vec<PathBuf>> {
        let codex = self.codex_home().context("Codex home is unavailable")?;
        let homes = vec![
            codex.to_path_buf(),
            self.claude_settings.claude_home.clone(),
        ];
        Ok(homes
            .into_iter()
            .map(|home| home.canonicalize().unwrap_or(home))
            .collect())
    }
}

mod service;
mod stop;
#[cfg(test)]
mod tests;
