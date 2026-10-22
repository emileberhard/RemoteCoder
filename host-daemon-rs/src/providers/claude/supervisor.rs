//! Supervises persistent `claude` stream-json processes.
//!
//! A thread keeps one warm Claude Code process and sends each new turn through
//! stdin. This is both the lowest-latency handoff seam for realtime voice and
//! the protocol Claude documents for interactive sessions. Every process still
//! runs inside its own process group with the same subscription billing guard
//! and bounded TERM/KILL shutdown ladder.

use crate::agents::mcp::McpTokens;
use crate::observability::journal::Journal;
use crate::providers::claude::settings::ClaudeSettings;
use crate::providers::claude::supervisor::input_writer::InputWriter;
use crate::providers::claude::translate::TurnTranslator;
use crate::providers::claude::wake_hold::WakeHold;
use crate::providers::claude::{ClaudeSelection, ClaudeTurnRequest};
use crate::rpc::error::RpcCode;
use nix::errno::Errno;
use nix::sys::signal::Signal;
use nix::unistd::Pid;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tokio::process::{ChildStderr, ChildStdout};
use tokio::sync::{Mutex, mpsc, oneshot};
use tracing::{debug, error, info, warn};

mod controls;
mod finishing;
mod idle;
mod input_writer;
mod lifecycle;
mod messages;
mod process;
mod restart_capture;
mod settings;
mod side_question;
mod stream;
mod suspend;
mod turns;

pub(crate) use messages::ParentMessage;
pub(crate) use restart_capture::ResumeDelivery;

const STOP_GRACE_PERIOD: Duration = Duration::from_secs(5);
const STOP_KILL_PERIOD: Duration = Duration::from_secs(5);
/// CLI init waits for configured MCP servers, and `npx`-backed servers stall
/// for a minute-plus under npm cache contention when several sessions spawn
/// at once (a 47 s init was observed and killed at the previous 45 s limit).
/// The deadline only needs to catch truly wedged spawns.
const RUNTIME_START_TIMEOUT: Duration = Duration::from_secs(120);
const RUNTIME_IDLE_TIMEOUT: Duration = Duration::from_secs(10 * 60);
const IDLE_WARM_RUNTIME_CAP: usize = 2;
const WAKE_EVIDENCE_RETRY: Duration = Duration::from_secs(60);
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);
const INTERRUPT_GRACE: Duration = Duration::from_secs(3);
const STDERR_RING_CAPACITY: usize = 256;
const CAPTURE_CONCURRENCY: usize = 8;

#[derive(Debug, Clone, Copy)]
enum TurnErrorData {
    Capacity(super::capacity::CapacityExceeded),
    Unresponsive,
    DeliveryUncertain,
}

#[derive(Debug)]
pub(crate) struct TurnStartError {
    data: Option<TurnErrorData>,
    pub code: RpcCode,
    pub message: String,
}

impl TurnStartError {
    fn internal(message: impl Into<String>) -> Self {
        Self {
            code: RpcCode::Internal,
            message: message.into(),
            data: None,
        }
    }

    fn is_queued_stall(&self) -> bool {
        matches!(self.data, Some(TurnErrorData::DeliveryUncertain))
    }

    fn is_unanswered(&self) -> bool {
        matches!(self.data, Some(TurnErrorData::Unresponsive))
    }

    fn unresponsive(message: impl Into<String>) -> Self {
        Self {
            code: RpcCode::Unavailable,
            message: message.into(),
            data: Some(TurnErrorData::Unresponsive),
        }
    }

    fn delivery_uncertain(message: impl Into<String>) -> Self {
        Self {
            code: RpcCode::Unavailable,
            message: message.into(),
            data: Some(TurnErrorData::DeliveryUncertain),
        }
    }
}

impl std::fmt::Display for TurnStartError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.message.fmt(formatter)
    }
}

impl From<&str> for TurnStartError {
    fn from(message: &str) -> Self {
        Self::internal(message)
    }
}

impl From<String> for TurnStartError {
    fn from(message: String) -> Self {
        Self::internal(message)
    }
}

impl From<std::io::Error> for TurnStartError {
    fn from(error: std::io::Error) -> Self {
        if InputWriter::stall_was_queued(&error) {
            return Self::delivery_uncertain(error.to_string());
        }
        if InputWriter::is_stalled(&error) {
            return Self::unresponsive(error.to_string());
        }
        let capacity = error
            .get_ref()
            .and_then(|error| error.downcast_ref::<super::capacity::CapacityExceeded>())
            .copied();
        Self {
            code: if capacity.is_some() {
                RpcCode::Capacity
            } else {
                RpcCode::Internal
            },
            message: error.to_string(),
            data: capacity.map(TurnErrorData::Capacity),
        }
    }
}

impl From<TurnStartError> for crate::rpc::error::RpcError {
    fn from(error: TurnStartError) -> Self {
        let result = Self::new(error.code, error.message);
        match error.data {
            Some(TurnErrorData::Capacity(capacity)) => {
                result.with_data(crate::rpc::error::RpcData::Raw(capacity.to_value()))
            }
            Some(TurnErrorData::Unresponsive) => {
                result.with_data(crate::rpc::error::RpcData::Kind(
                    crate::rpc::error::ErrorKind::ProviderUnresponsive,
                ))
            }
            Some(TurnErrorData::DeliveryUncertain) => {
                result.with_data(crate::rpc::error::RpcData::Kind(
                    crate::rpc::error::ErrorKind::InputDeliveryUncertain,
                ))
            }
            None => result,
        }
    }
}

#[derive(Debug)]
pub(crate) enum TurnControlError {
    NotRunning { message: String },
    Failed(TurnStartError),
}

impl From<TurnStartError> for TurnControlError {
    fn from(error: TurnStartError) -> Self {
        Self::Failed(error)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum SessionRename {
    Renamed,
    NoConversation,
}

#[derive(Clone, Copy)]
enum TurnOrigin {
    Dispatched,
    Callback,
}

struct RuntimeTurn {
    translator: TurnTranslator,
    /// Opened by the stream itself — a peer message, a background-subagent
    /// completion, a scheduled wake — rather than by gateway dispatch.
    agent_initiated: bool,
    awaiting_input: Option<String>,
    continues: Option<String>,
    phase: TurnPhase,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum TurnPhase {
    Running,
    Stopping,
    FinishingAfterStop,
    Finishing,
}

impl RuntimeTurn {
    fn new(
        translator: TurnTranslator,
        agent_initiated: bool,
        awaiting_input: Option<String>,
    ) -> Self {
        Self {
            translator,
            agent_initiated,
            awaiting_input,
            continues: None,
            phase: TurnPhase::Running,
        }
    }

    fn is_stopping(&self) -> bool {
        matches!(
            self.phase,
            TurnPhase::Stopping | TurnPhase::FinishingAfterStop
        )
    }

    fn admits(&mut self, frame: &Value, evidence: &[&str]) -> bool {
        let Some(input) = self.awaiting_input.as_deref() else {
            return true;
        };
        if evidence.contains(&input) {
            self.awaiting_input = None;
            return true;
        }
        !answers_other_work(frame, evidence)
    }

    fn is(&self, turn_id: &str) -> bool {
        self.translator.turn_id() == turn_id || self.continues.as_deref() == Some(turn_id)
    }
}

/// Owns one runtime's access to the gateway's MCP server.
///
/// Cleanup is tied to ownership rather than to the retire paths: a runtime can
/// be dropped from several places (idle timeout, config change, failure,
/// release, shutdown), and a token that outlived its process would be a
/// standing key to the tools.
struct McpRuntimeAccess {
    tokens: McpTokens,
    token: String,
    config_path: PathBuf,
}

impl Drop for McpRuntimeAccess {
    fn drop(&mut self) {
        self.tokens.revoke_token(&self.token);
        let _ = std::fs::remove_file(&self.config_path);
        let _ = std::fs::remove_file(runtime_settings_path(&self.config_path));
    }
}

#[derive(Clone, Debug, serde::Serialize)]
struct ClaudeRuntimeSettings {
    #[serde(flatten)]
    observed: ClaudeSelection,
    #[serde(skip)]
    selection: Option<ClaudeSelection>,
}

impl ClaudeRuntimeSettings {
    fn requested(request: &ClaudeTurnRequest) -> Self {
        Self {
            observed: request.selection.clone(),
            selection: Some(request.selection.clone()),
        }
    }

    fn read_back(response: &Value) -> Result<ClaudeSelection, String> {
        Ok(ClaudeSelection {
            model: response["applied"]["model"]
                .as_str()
                .ok_or("Claude returned no applied model")?
                .to_string(),
            effort: response["applied"]["effort"].as_str().map(str::to_string),
            fast: response["effective"]["fastMode"].as_bool() == Some(true),
        })
    }

    fn accepts(&self, request: &ClaudeTurnRequest) -> bool {
        self.selection.as_ref() == Some(&request.selection)
    }

    fn effective(&self) -> &ClaudeSelection {
        self.selection.as_ref().unwrap_or(&self.observed)
    }

    fn permits_fast(&self) -> bool {
        self.selection
            .as_ref()
            .is_some_and(|selection| selection.fast)
    }
}

struct ClaudeRuntime {
    input: InputWriter,
    pending_controls: HashMap<String, oneshot::Sender<Result<Value, String>>>,
    process_group_id: i32,
    session_uuid: String,
    settings: Option<ClaudeRuntimeSettings>,
    cwd: String,
    initialized: bool,
    active_turn: Option<RuntimeTurn>,
    background_tasks: Vec<suspend::BackgroundTask>,
    children: crate::agents::claude::Projection,
    children_generation: u128,
    lifecycle_generation: u64,
    stderr_ring: Arc<Mutex<Vec<String>>>,
    _mcp: Option<McpRuntimeAccess>,
    idle: Option<IdleArm>,
    wakes: WakeHold,
}

struct IdleArm {
    since: tokio::time::Instant,
    timer: tokio_util::sync::CancellationToken,
}

impl Drop for IdleArm {
    fn drop(&mut self) {
        self.timer.cancel();
    }
}

struct IdleRuntime {
    thread_id: String,
    process_group_id: i32,
    lifecycle_generation: u64,
    since: tokio::time::Instant,
}

enum IdleRetirement {
    Retired,
    Held(tokio::time::Instant),
    NotIdle,
}

#[derive(Clone, Copy)]
enum WakeEvidence {
    Fresh,
    Unreadable,
}

enum IdleEligibility {
    Busy,
    Eligible,
    HeldUntil(tokio::time::Instant),
    WakesUnreadable,
}

struct IdlePolicy;

impl IdlePolicy {
    fn eligibility(
        runtime: &ClaudeRuntime,
        evidence: WakeEvidence,
        now: tokio::time::Instant,
    ) -> IdleEligibility {
        if !runtime.is_idle() {
            return IdleEligibility::Busy;
        }
        if let Some(until) = runtime.wakes.held_until(now) {
            return IdleEligibility::HeldUntil(until);
        }
        match evidence {
            WakeEvidence::Fresh => IdleEligibility::Eligible,
            WakeEvidence::Unreadable => IdleEligibility::WakesUnreadable,
        }
    }
}

#[derive(Default)]
struct ProcessRegistry {
    closing: bool,
    groups: HashSet<i32>,
}

impl ClaudeRuntime {
    fn matches(&self, request: &ClaudeTurnRequest) -> bool {
        self.session_uuid == request.session_uuid
            && self
                .settings
                .as_ref()
                .is_some_and(|settings| settings.accepts(request))
            && self.cwd == request.cwd
    }

    fn background_task_ids(&self) -> Vec<String> {
        self.background_tasks
            .iter()
            .map(suspend::BackgroundTask::id)
            .map(str::to_owned)
            .collect()
    }

    fn is_idle(&self) -> bool {
        self.active_turn.is_none() && self.background_tasks.is_empty()
    }

    fn running_turn(&self) -> Option<&RuntimeTurn> {
        self.active_turn
            .as_ref()
            .filter(|turn| turn.phase == TurnPhase::Running)
    }

    fn running_turn_mut(&mut self) -> Option<&mut RuntimeTurn> {
        self.active_turn
            .as_mut()
            .filter(|turn| turn.phase == TurnPhase::Running)
    }
}

pub(crate) enum ClaudeNotification {
    Event(Value),
    IngressBarrier(tokio::sync::oneshot::Sender<()>),
}

pub(crate) struct ClaudeSupervisor {
    settings: ClaudeSettings,
    notifications: mpsc::Sender<ClaudeNotification>,
    journal: Journal,
    mcp_tokens: McpTokens,
    runtimes: Mutex<HashMap<String, ClaudeRuntime>>,
    lifecycles: lifecycle::ThreadLifecycles,
    starting: Arc<StdMutex<HashSet<String>>>,
    process_registry: Arc<StdMutex<ProcessRegistry>>,
    reapers: tokio_util::task::TaskTracker,
    io_tasks: crate::tasks::owned_tasks::OwnedTasks,
    timers: crate::tasks::owned_tasks::OwnedTasks,
    next_turn_sequence: AtomicU64,
    live_prefix_budget: Arc<crate::providers::claude::translate::live::LivePrefixBudget>,
    turn_settled: tokio::sync::Notify,
    conversation_index: crate::providers::claude::conversation_index::Store,
}

impl ClaudeSupervisor {
    pub fn new(
        settings: ClaudeSettings,
        notifications: mpsc::Sender<ClaudeNotification>,
        journal: Journal,
        mcp_tokens: McpTokens,
    ) -> Arc<Self> {
        // A disabled/no-MCP instance owns no runtime configurations. In
        // particular, hermetic tests must not sweep a live host's default path.
        if !settings.mcp_endpoint.is_empty() {
            sweep_stale_mcp_configs(&settings.mcp_config_dir);
        }
        Arc::new(Self {
            conversation_index: crate::providers::claude::conversation_index::Store::new(
                settings.claude_home.clone(),
            ),
            settings,
            notifications,
            journal,
            mcp_tokens,
            runtimes: Mutex::new(HashMap::new()),
            lifecycles: lifecycle::ThreadLifecycles::default(),
            starting: Arc::new(StdMutex::new(HashSet::new())),
            process_registry: Arc::default(),
            reapers: tokio_util::task::TaskTracker::new(),
            io_tasks: crate::tasks::owned_tasks::OwnedTasks::default(),
            timers: crate::tasks::owned_tasks::OwnedTasks::default(),
            next_turn_sequence: AtomicU64::new(1),
            live_prefix_budget: Arc::default(),
            turn_settled: tokio::sync::Notify::new(),
        })
    }

    pub(crate) fn process_group_ids(&self) -> HashSet<i32> {
        self.process_registry
            .lock()
            .expect("Claude process registry poisoned")
            .groups
            .clone()
    }

    pub(crate) async fn wait_for_notification_ingress(&self) -> anyhow::Result<()> {
        let (sender, receiver) = tokio::sync::oneshot::channel();
        self.notifications
            .send(ClaudeNotification::IngressBarrier(sender))
            .await
            .map_err(|_| anyhow::anyhow!("Claude notification sink closed"))?;
        receiver
            .await
            .map_err(|_| anyhow::anyhow!("Claude notification ingress stopped"))
    }

    pub(crate) async fn active_turn_count(&self) -> usize {
        self.runtimes
            .lock()
            .await
            .values()
            .filter(|runtime| runtime.active_turn.is_some())
            .count()
    }

    pub(crate) async fn live_checkpoint(&self, thread_id: &str) -> Option<Value> {
        self.runtimes
            .lock()
            .await
            .get(thread_id)
            .and_then(ClaudeRuntime::running_turn)
            .and_then(|turn| turn.translator.live_checkpoint())
    }

    pub(crate) async fn has_runtime(&self, thread_id: &str) -> bool {
        self.runtimes.lock().await.contains_key(thread_id)
    }

    /// Exact per-thread admission. A warm idle runtime is
    /// harmless, while a reserved start, active turn, or background task is not.
    #[cfg(test)]
    pub(crate) async fn has_pending_or_active_work(&self, thread_id: &str) -> bool {
        let starting = || {
            self.starting
                .lock()
                .expect("Claude start reservations poisoned")
                .contains(thread_id)
        };
        if starting() {
            return true;
        }
        if self
            .runtimes
            .lock()
            .await
            .get(thread_id)
            .is_some_and(|runtime| !runtime.is_idle())
        {
            return true;
        }
        starting()
    }

    pub(crate) async fn lock_lifecycle(&self, thread_id: &str) -> tokio::sync::OwnedMutexGuard<()> {
        self.lifecycles.lock(thread_id).await
    }

    pub(crate) async fn active_turn_id(&self, thread_id: &str) -> Option<String> {
        self.runtimes
            .lock()
            .await
            .get(thread_id)
            .and_then(|runtime| runtime.active_turn.as_ref())
            .map(|turn| turn.translator.turn_id().to_owned())
    }

    pub(crate) async fn execution_turn_id(&self, thread_id: &str, turn_id: &str) -> Option<String> {
        self.runtimes
            .lock()
            .await
            .get(thread_id)
            .and_then(|runtime| runtime.active_turn.as_ref())
            .filter(|turn| turn.is(turn_id))
            .map(|turn| turn.translator.turn_id().to_owned())
    }

    pub(crate) async fn turn_record(
        &self,
        thread_id: &str,
        turn_id: &str,
    ) -> anyhow::Result<Option<crate::providers::claude::conversation_index::TurnIdentity>> {
        self.conversation_index.turn(thread_id, turn_id).await
    }

    pub(crate) async fn record_turn_recovery(
        &self,
        thread_id: &str,
        turn_id: &str,
        recovery: crate::providers::claude::conversation_index::TurnRecovery,
    ) -> anyhow::Result<crate::providers::claude::conversation_index::TurnRecovery> {
        self.conversation_index
            .record_recovery(thread_id, turn_id, recovery)
            .await
    }

    pub(crate) async fn runtime_settings_snapshot(
        &self,
        thread_id: &str,
    ) -> Result<Option<ClaudeSelection>, String> {
        let runtimes = self.runtimes.lock().await;
        let Some(runtime) = runtimes.get(thread_id) else {
            return Ok(None);
        };
        runtime
            .settings
            .as_ref()
            .map(|settings| Some(settings.effective().clone()))
            .ok_or_else(|| "Claude runtime settings have not been observed".to_owned())
    }

    pub(crate) async fn runtime_settings_for_command(
        &self,
        thread_id: &str,
    ) -> Result<Option<ClaudeSelection>, String> {
        let _lifecycle = self.lifecycles.lock(thread_id).await;
        let pid = {
            let runtimes = self.runtimes.lock().await;
            let Some(runtime) = runtimes.get(thread_id) else {
                return Ok(None);
            };
            if let Some(settings) = &runtime.settings {
                return Ok(Some(settings.effective().clone()));
            }
            runtime.process_group_id
        };
        let response = self
            .runtime_control(thread_id, pid, json!({"subtype":"get_settings"}))
            .await
            .map_err(|error| error.message)?;
        let observed = ClaudeRuntimeSettings {
            observed: ClaudeRuntimeSettings::read_back(&response)?,
            selection: None,
        };
        let mut runtimes = self.runtimes.lock().await;
        let runtime = runtimes
            .get_mut(thread_id)
            .filter(|runtime| runtime.process_group_id == pid)
            .ok_or("Claude runtime ended while settings were being observed")?;
        self.journal.runtime(
            "settings_observed",
            json!({"threadId":thread_id,"pid":pid,"settings":observed}),
        );
        let selection = observed.effective().clone();
        runtime.settings = Some(observed);
        Ok(Some(selection))
    }

    async fn emit(&self, notification: Value) {
        let recorded = self.record(notification).await;
        self.publish(recorded).await;
    }

    async fn record(&self, mut notification: Value) -> RecordedNotification {
        let persistence_warning = match self.conversation_index.record(&mut notification).await {
            Ok(()) => None,
            Err(error) => {
                error!(%error, "Claude conversation identity persistence failed");
                Some(json!({ "method": "gateway/warning", "params": {
                    "kind": "historyIdentityPersistence",
                    "threadId": notification.pointer("/params/threadId"),
                    "message": "Claude history identity could not be saved. Reloaded chronology may be incomplete."
                }}))
            }
        };
        RecordedNotification {
            notification,
            persistence_warning,
        }
    }

    async fn publish(&self, recorded: RecordedNotification) {
        if let Some(warning) = recorded.persistence_warning {
            let _ = self
                .notifications
                .send(ClaudeNotification::Event(warning))
                .await;
        }
        if self
            .notifications
            .send(ClaudeNotification::Event(recorded.notification))
            .await
            .is_err()
        {
            debug!("claude notification sink closed");
        }
    }
}

struct RecordedNotification {
    notification: Value,
    persistence_warning: Option<Value>,
}

struct StoppedTurn {
    completed: RecordedNotification,
    message: Option<String>,
}

/// Until admission or retirement completes, the operation owns termination of
/// this exact registered process group. Cancellation cannot leave unowned work.
struct ProcessAdmission {
    group: i32,
    processes: Arc<StdMutex<ProcessRegistry>>,
    accepted: bool,
}

impl ProcessAdmission {
    fn new(group: i32, processes: Arc<StdMutex<ProcessRegistry>>) -> Self {
        Self {
            group,
            processes,
            accepted: false,
        }
    }
    fn accept(&mut self) {
        self.accepted = true;
    }
}

impl Drop for ProcessAdmission {
    fn drop(&mut self) {
        if !self.accepted
            && self
                .processes
                .lock()
                .expect("Claude process registry poisoned")
                .groups
                .contains(&self.group)
        {
            signal_group(Pid::from_raw(self.group), Signal::SIGKILL);
        }
    }
}

struct SpawnedRuntime {
    admission: ProcessAdmission,
    runtime: ClaudeRuntime,
    process_group_id: i32,
    stdout: ChildStdout,
    stderr: Option<ChildStderr>,
}

fn claude_model_matches(requested: &str, actual: &str) -> bool {
    if requested == actual {
        return true;
    }
    let family = requested.strip_suffix("[1m]").unwrap_or(requested);
    matches!(family, "sonnet" | "opus" | "fable" | "haiku")
        && actual.starts_with(&format!("claude-{family}-"))
}

fn other_turn(turn_id: &str, current: &str) -> TurnStartError {
    TurnStartError {
        data: None,
        code: RpcCode::InvalidRequest,
        message: format!("expected active turn id {turn_id} but found {current}"),
    }
}

fn consumed_input_ids(value: &Value) -> Vec<&str> {
    let echoed = value["uuid"].as_str().filter(|_| value["type"] == "user");
    let listed = match value["user_message_uuids"].as_array() {
        Some(ids) => ids.iter().filter_map(Value::as_str).collect(),
        None => value["user_message_uuid"]
            .as_str()
            .into_iter()
            .collect::<Vec<_>>(),
    };
    echoed.into_iter().chain(listed).collect()
}

fn answers_other_work(frame: &Value, evidence: &[&str]) -> bool {
    frame["type"] == "result"
        && (frame["origin"]["kind"]
            .as_str()
            .is_some_and(|kind| !matches!(kind, "unclassified" | "human"))
            || !evidence.is_empty())
}

fn runtime_settings_path(mcp_config: &Path) -> PathBuf {
    mcp_config.with_extension("settings.json")
}

fn claude_stream_args(request: &ClaudeTurnRequest, mcp_config: Option<&Path>) -> Vec<String> {
    let mut args = vec![
        "-p".to_string(),
        "--input-format".to_string(),
        "stream-json".to_string(),
        "--output-format".to_string(),
        "stream-json".to_string(),
        "--verbose".to_string(),
        "--include-partial-messages".to_string(),
        "--replay-user-messages".to_string(),
        "--forward-subagent-text".to_string(),
        "--thinking-display".to_string(),
        "summarized".to_string(),
        "--permission-mode".to_string(),
        "bypassPermissions".to_string(),
        "--model".to_string(),
        request.selection.model.clone(),
    ];
    if let Some(effort) = request.selection.effort.as_deref() {
        args.push("--effort".to_string());
        args.push(effort.to_string());
    }
    if let Some(path) = mcp_config {
        // Additive and per-invocation: the host's own MCP servers and skills
        // stay, and nothing is persisted. Deliberately not --strict-mcp-config.
        args.push("--mcp-config".to_string());
        args.push(path.display().to_string());
        args.push("--settings".to_string());
        args.push(runtime_settings_path(path).display().to_string());
    }
    args.push(if request.first_turn {
        "--session-id".to_string()
    } else {
        "--resume".to_string()
    });
    args.push(request.session_uuid.clone());
    args
}

/// Writes a file only its owner can read, creating the directory if needed.
/// The MCP config carries a bearer token, so the mode is part of the contract.
fn write_private_file(path: &Path, contents: &str) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(contents.as_bytes())
}

/// Removes MCP config files left behind by a previous process.
///
/// Every file in here belongs to a runtime, and at startup no runtime exists,
/// so anything present is stale by definition and holds a token that is already
/// gone from the in-memory map.
fn sweep_stale_mcp_configs(dir: &Path) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut removed = 0usize;
    for entry in entries.flatten() {
        if entry.path().extension().is_some_and(|ext| ext == "json")
            && fs::remove_file(entry.path()).is_ok()
        {
            removed += 1;
        }
    }
    if removed > 0 {
        info!(removed, dir = %dir.display(), "swept stale Claude MCP config files");
    }
}

async fn append_stderr_tail(
    error_message: Option<String>,
    stderr_ring: &Arc<Mutex<Vec<String>>>,
) -> Option<String> {
    let tail = {
        let ring = stderr_ring.lock().await;
        ring.iter()
            .rev()
            .take(20)
            .rev()
            .cloned()
            .collect::<Vec<_>>()
    };
    if tail.is_empty() {
        return error_message;
    }
    Some(format!(
        "{}: {}",
        error_message.unwrap_or_else(|| "Claude failed".to_string()),
        tail.join("\n")
    ))
}

fn signal_group(process_group_id: Pid, signal: Signal) {
    match nix::sys::signal::killpg(process_group_id, signal) {
        Ok(()) | Err(Errno::ESRCH) => {}
        Err(err) => {
            warn!(pgid = process_group_id.as_raw(), ?signal, %err, "failed to signal claude process group")
        }
    }
}

fn group_exists(process_group_id: Pid) -> bool {
    match nix::sys::signal::killpg(process_group_id, None) {
        Ok(()) | Err(Errno::EPERM) => true,
        Err(Errno::ESRCH) => false,
        Err(_) => true,
    }
}

async fn wait_for_group_exit(process_group_id: Pid, timeout: Duration) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if !group_exists(process_group_id) {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(PROCESS_POLL_INTERVAL).await;
    }
}

fn append_custom_title(path: &Path, session_uuid: &str, title: &str) -> Result<bool, String> {
    use std::io::{Read, Seek, SeekFrom, Write};
    let failed =
        |error: std::io::Error| format!("Could not record the Claude session title: {error}");
    let mut file = fs::OpenOptions::new()
        .read(true)
        .append(true)
        .open(path)
        .map_err(failed)?;
    let length = file.metadata().map_err(failed)?.len();
    if length == 0 {
        return Ok(false);
    }
    let mut last = [0_u8; 1];
    file.seek(SeekFrom::Start(length - 1)).map_err(failed)?;
    file.read_exact(&mut last).map_err(failed)?;
    if last[0] != b'\n' {
        return Err(
            "The Claude session file ends mid-record; retry once Claude finishes writing it"
                .to_owned(),
        );
    }
    let mut line = json!({
        "type": "custom-title",
        "customTitle": title,
        "sessionId": session_uuid,
    })
    .to_string();
    line.push('\n');
    file.write_all(line.as_bytes()).map_err(failed)?;
    Ok(true)
}

/// Whether a stream line is turn content, and so may open an agent-initiated
/// turn.
///
/// The gate is event-type based because the two wake shapes differ: pinned
/// against a live CLI (2.1.238), a peer message opens with a replayed synthetic
/// `user` record while a subagent completion opens straight into
/// `stream_event`. Ambient lines legitimately arrive outside a turn and must not
/// open one — `system` (except `thinking_tokens`, which is turn progress),
/// `rate_limit_event`, and the `command_lifecycle` brackets around peer wakes.
fn opens_turn(value: &Value) -> bool {
    match value.get("type").and_then(Value::as_str) {
        Some("user") => {
            value.pointer("/origin/kind").and_then(Value::as_str) == Some("peer")
                || !crate::providers::claude::timeline::is_injected_user_record(
                    value,
                    value.pointer("/message/content"),
                )
        }
        Some("stream_event" | "assistant" | "result") => true,
        Some("system") => value.get("subtype").and_then(Value::as_str) == Some("thinking_tokens"),
        _ => false,
    }
}

fn is_background_tasks_change(value: &Value) -> bool {
    value.get("type").and_then(Value::as_str) == Some("system")
        && value.get("subtype").and_then(Value::as_str) == Some("background_tasks_changed")
}

/// Provenance for an agent-initiated turn, read from the CLI's typed `origin`
/// on the wake trigger. Best-effort: only peer wakes carry one.
fn wake_reason(value: &Value) -> Option<Value> {
    let origin = value.get("origin")?;
    let kind = origin.get("kind").and_then(Value::as_str)?;
    let mut reason = serde_json::Map::new();
    reason.insert("kind".to_string(), json!(kind));
    if let Some(name) = origin.get("name").and_then(Value::as_str) {
        reason.insert("name".to_string(), json!(name));
    }
    Some(Value::Object(reason))
}

/// Marks a turn frame as agent-initiated so a client can tell "the answer to
/// your question" from "something happened while you were away". Additive:
/// clients that do not know the params ignore them.
fn annotate_agent_initiated(notification: &mut Value, reason: Option<&Value>) {
    let Some(params) = notification
        .get_mut("params")
        .and_then(Value::as_object_mut)
    else {
        return;
    };
    params.insert("agentInitiated".to_string(), json!(true));
    if let Some(reason) = reason {
        params.insert("wakeReason".to_string(), reason.clone());
    }
}

#[cfg(test)]
pub(super) mod tests;
