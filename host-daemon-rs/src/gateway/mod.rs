mod account_resets;
mod agent_actions;
mod agent_gateway;
mod question_gateway;

use crate::agents::mcp::McpTokens;
use crate::navigation::NavigationManager;
use crate::notifications::history::NotificationHistory;
use crate::observability::journal::Journal;
use crate::providers::claude::ClaudeSupervisor;
use crate::providers::claude::auth::ClaudeAuth;
use crate::providers::claude::restart_driver::ClaudeRestartDriver;
use crate::providers::claude::settings::ClaudeSettings;
use crate::providers::codex::daemon::CodexAppServer;
use crate::providers::codex::external::ExternalProviders;
use crate::push::PushService;
use crate::rpc::dispatch::ClientRequest;
use crate::runtime::recovery::{RecoveryJournal, RecoveryStore};
use crate::turns::{ActiveTurn, PendingTurnStart, ThreadQueue, TurnContext, TurnKey, TurnLedger};
use crate::voice::handoff::{VoiceAppend, VoiceOutputTarget};
use crate::voice::session::VoiceCoordinator;
use anyhow::{Context, Result, anyhow};
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap, HashSet};
#[cfg(test)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::{Mutex, mpsc, oneshot, watch};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message as UpstreamMessage;
use tracing::{info, warn};

pub(crate) mod calls;
mod claude_live;
mod control;
mod conversation_review;
pub(crate) mod device_tools;
mod execution;
mod live_activity;
mod native_mutations;
mod notifications;
mod push;
mod queue;
mod renames;
mod rpc_methods;
mod side_question;
mod subscriptions;
mod transport;
mod turn_state;
mod turns;
mod voice;
mod voice_handoffs;

// 5s is too aggressive for large JSON-RPC payloads (e.g. thread/read that includes
// base64-encoded image inputs). A slow cellular link can legitimately take >5s to
// drain a 1-3 MiB websocket message, and timing out here makes some threads
// effectively unopenable from iOS.
const SEND_TIMEOUT_SECONDS: f64 = 60.0;

const SHUTDOWN_INTERRUPT_GRACE_SECONDS: u64 = 2;

const CODEX_LIVENESS_PROBE_TIMEOUT_SECONDS: f64 = 5.0;
const CODEX_UPSTREAM_INIT_TIMEOUT_SECONDS: f64 = 10.0;
const UPSTREAM_SEND_TIMEOUT_SECONDS: f64 = 30.0;
const UPSTREAM_OUTBOUND_QUEUE_SIZE: usize = 16;
const CLIENT_UPSTREAM_QUEUE_SIZE: usize = 32;

const ENDED_TURN_LOOKUP_PAGE_SIZE: u32 = 20;

const CLIENT_OUTBOUND_QUEUE_SIZE: usize = 32;
const TRANSPORT_ERROR_CLOSE_TIMEOUT: Duration = Duration::from_secs(2);
const RESTARTING_CLOSE_CODE: u16 = 4012;
const RESTARTING_CLOSE_REASON: &str = "gateway restarting";

pub(crate) fn restarting_close() -> axum::extract::ws::CloseFrame<'static> {
    axum::extract::ws::CloseFrame {
        code: RESTARTING_CLOSE_CODE,
        reason: std::borrow::Cow::Borrowed(RESTARTING_CLOSE_REASON),
    }
}
#[derive(Debug)]
enum ClientCommand {
    Text(String),
    FrameCapacity(transport::RejectedFrame),
    Pong(Vec<u8>),
    TransportError {
        payload: String,
        flushed: oneshot::Sender<()>,
    },
    Close {
        code: u16,
        reason: String,
    },
}

/// A connected client's outbound queue paired with the id that names it, so
/// every send site can attribute what it sent to the journal without threading
/// the id through separately.
#[derive(Debug, Clone)]
struct ClientTx {
    content_subscriptions: Arc<subscriptions::ContentSubscriptions>,
    id: u64,
    installation_id: Option<String>,
    tx: mpsc::Sender<ClientCommand>,
    closed: tokio_util::sync::CancellationToken,
    query_response: Option<Arc<transport::queries::ResponseClaim>>,
}

impl ClientTx {
    fn try_send(
        &self,
        command: ClientCommand,
    ) -> Result<(), mpsc::error::TrySendError<ClientCommand>> {
        let command = match command {
            ClientCommand::Text(text) => transport::ClientFrame::from_text(text).into_command(),
            other => other,
        };
        self.tx.try_send(command)
    }
}

async fn send_client_upstream(tx: &mpsc::Sender<UpstreamMessage>, payload: String) -> Result<()> {
    tokio::time::timeout(
        Duration::from_secs_f64(SEND_TIMEOUT_SECONDS),
        tx.send(UpstreamMessage::Text(payload)),
    )
    .await
    .context("Codex outbound queue timed out")?
    .context("Codex outbound queue closed")
}

#[derive(Debug, Clone, PartialEq)]
struct AppServerActiveTurn {
    thread_id: String,
    turn_id: String,
    started_at_unix_seconds: Option<f64>,
    last_seen_at_unix_seconds: f64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DurableTurnState {
    pending_turn_starts: HashMap<String, PendingTurnStart>,
    active_turns_by_key: HashMap<String, ActiveTurn>,
    turn_ctx_by_key: HashMap<String, TurnContext>,
    #[serde(default)]
    pending_native_mutations: HashMap<String, i32>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    queued_submissions: HashMap<String, ThreadQueue>,
}

type ControlReplies = std::sync::Mutex<HashMap<String, oneshot::Sender<Result<Value, String>>>>;

#[derive(Clone)]
struct NativeMutationTransport {
    pid: i32,
    sender: mpsc::Sender<String>,
}

struct PendingControlReply<'a> {
    id: String,
    replies: &'a ControlReplies,
}

impl Drop for PendingControlReply<'_> {
    fn drop(&mut self) {
        self.replies
            .lock()
            .expect("control replies poisoned")
            .remove(&self.id);
    }
}

#[derive(Debug, Default)]
struct GatewayCoreState {
    turns: TurnLedger,
    app_server_active_turns_by_thread: HashMap<String, AppServerActiveTurn>,
    app_server_inventory_generation_by_thread: HashMap<String, u64>,
    app_server_inventory_bootstrapped: bool,
    app_server_inventory_unresolved_threads: HashSet<String>,
    recovered_turn_keys: HashSet<TurnKey>,
    notification_history: NotificationHistory,
    finished_turns: live_activity::FinishedTurns,
}

#[derive(Debug, Clone)]
struct ApnsSend {
    collapse_id: String,
    title: String,
    subtitle: String,
    body: String,
    payload: Value,
}

#[derive(Debug, Clone, Default, PartialEq)]
struct ActiveTasksLiveActivitySnapshot {
    running: BTreeSet<String>,
    finished: live_activity::FinishedTurns,
}

fn voice_append_request(thread_id: &str, append: &VoiceAppend) -> (&'static str, Value) {
    match &append.target {
        VoiceOutputTarget::Handoff(handoff_id) => (
            "thread/realtime/handoff/append",
            serde_json::json!({
                "threadId": thread_id,
                "handoffId": handoff_id,
                "text": append.text,
                "phase": "commentary",
            }),
        ),
        VoiceOutputTarget::Conversation => (
            "thread/realtime/appendSpeech",
            serde_json::json!({ "threadId": thread_id, "text": append.text }),
        ),
    }
}

#[derive(Debug, Clone)]
pub(crate) struct DaemonReady {
    pub codex_pid: i32,
    pub started_at_unix_seconds: f64,
}

struct GatewayConstruction {
    codex: Arc<CodexAppServer>,
    user_name: Option<String>,
    claude_settings: ClaudeSettings,
    journal: Journal,
    turn_state_path: Option<PathBuf>,
    recovery_path: Option<PathBuf>,
    call_delivery: Option<calls::CallDeliveryConfig>,
    external_auth: Option<external_auth::ExternalAuth>,
    external_providers: Option<Arc<ExternalProviders>>,
}

mod account_context;
mod activity;
pub(crate) mod admission;
mod claude_fork;
mod external_auth;
mod external_providers;
mod provider_health;
pub(crate) use external_auth::ExternalAuth;
mod lifecycle;
mod takeover;

pub(crate) struct Gateway {
    user_name: Option<String>,
    pub(crate) admission: Arc<crate::gateway::admission::ConversationAdmission>,
    external_auth: Option<external_auth::ExternalAuth>,
    external_providers: Option<Arc<ExternalProviders>>,
    questions: question_gateway::Runtime,
    agents: agent_gateway::Runtime,
    codex: Arc<CodexAppServer>,
    apns: Arc<PushService>,
    clients: DashMap<u64, ClientTx>,
    journal: Journal,
    core: Mutex<GatewayCoreState>,
    draining: AtomicBool,
    listening: tokio::sync::watch::Sender<bool>,
    claude_restart: ClaudeRestartDriver,
    claude_recovery_task: Mutex<Option<JoinHandle<()>>>,
    claude_recovery_ready: AtomicBool,
    control: control::ControlConnection,
    native_mutation_transport: Mutex<Option<NativeMutationTransport>>,
    native_mutations: native_mutations::PendingNativeMutations,
    control_task: Mutex<Option<JoinHandle<()>>>,
    control_init_result: Mutex<Option<Value>>,
    provider_health: provider_health::ProviderHealthOwner,
    control_requests: ControlReplies,
    next_control_request_id: AtomicU64,
    observer_tasks: Mutex<HashMap<String, JoinHandle<()>>>,
    apns_completion_tx: Mutex<Option<mpsc::Sender<ApnsSend>>>,
    apns_completion_task: Mutex<Option<JoinHandle<()>>>,
    apns_live_activity_tx: Mutex<Option<watch::Sender<ActiveTasksLiveActivitySnapshot>>>,
    apns_live_activity_task: Mutex<Option<JoinHandle<()>>>,
    next_client_id: Arc<AtomicU64>,
    turn_state_path: Option<PathBuf>,
    turn_state_write_lock: Arc<Mutex<()>>,
    claude_settings: ClaudeSettings,
    claude_history: crate::providers::claude::history::ClaudeHistory,
    external_activity: crate::activity::external::ExternalActivity,
    activity: activity::ActivityPublisher,
    claude_auth: Arc<ClaudeAuth>,
    claude_auth_task: Mutex<Option<JoinHandle<()>>>,
    claude_notification_hook_health: Mutex<Option<Value>>,
    claude_agent: std::sync::Mutex<Option<Arc<ClaudeSupervisor>>>,
    claude_notification_task: Mutex<Option<JoinHandle<()>>>,
    voice: VoiceCoordinator,
    mcp_tokens: McpTokens,
    navigation: Arc<NavigationManager>,
    calls: calls::AgentCalls,
    recovery_store: Option<RecoveryStore>,
    metadata: crate::conversations::ConversationMetadataStore,
    marks: crate::conversation_marks::ConversationMarksStore,
    favorites: Option<crate::directory_favorites::DirectoryFavoritesStore>,
    tool_media: Option<crate::storage::tool_media::ToolMediaStore>,
    preferences: Option<crate::user_preferences::UserPreferencesStore>,
    projects: Arc<crate::conversation_projects::ProjectResolver>,
    request_budgets: Arc<transport::RequestBudgets>,
    review: conversation_review::Runtime,
    renames: renames::Renames,
    side_question_forks: side_question::Forks,
    device_tools: Arc<device_tools::DeviceTools>,
    tool_claims: crate::agents::tools::claims::ToolClaims,
    tool_tasks: crate::tasks::owned_tasks::OwnedTasks,
    command_tasks: crate::tasks::owned_tasks::OwnedTasks,
    voice_tasks: crate::tasks::owned_tasks::OwnedTasks,
    reset_tasks: crate::tasks::owned_tasks::OwnedTasks,
    reset_capacity: Arc<tokio::sync::Semaphore>,
}

impl Gateway {
    #[cfg(test)]
    pub(crate) fn with_turn_state(
        codex: Arc<CodexAppServer>,
        claude_settings: ClaudeSettings,
        journal: Journal,
        turn_state_path: Option<PathBuf>,
    ) -> Arc<Self> {
        Self::with_state_paths(codex, claude_settings, journal, turn_state_path, None, None)
    }

    #[cfg(test)]
    pub(crate) fn with_state_paths(
        codex: Arc<CodexAppServer>,
        claude_settings: ClaudeSettings,
        journal: Journal,
        turn_state_path: Option<PathBuf>,
        recovery_path: Option<PathBuf>,
        call_delivery: Option<calls::CallDeliveryConfig>,
    ) -> Arc<Self> {
        let apns = Arc::new(PushService::fixture_disabled(journal.clone()));
        Self::construct_with_apns(
            GatewayConstruction {
                codex,
                user_name: None,
                claude_settings,
                journal,
                turn_state_path,
                recovery_path,
                call_delivery,
                external_auth: None,
                external_providers: None,
            },
            apns,
        )
    }

    #[cfg(test)]
    pub(crate) async fn attach_fake_control(&self, tx: mpsc::Sender<String>) {
        self.control.retire().await;
        self.control.publish(tx);
    }

    #[expect(clippy::too_many_arguments)]
    pub(crate) fn with_notifier(
        codex: Arc<CodexAppServer>,
        apns: Arc<PushService>,
        claude_settings: ClaudeSettings,
        journal: Journal,
        state_directory: PathBuf,
        call_delivery: Option<calls::CallDeliveryConfig>,
        external_auth: Option<ExternalAuth>,
        external_providers: Option<Arc<ExternalProviders>>,
        user_name: Option<String>,
    ) -> Arc<Self> {
        Self::construct_with_apns(
            GatewayConstruction {
                codex,
                user_name,
                claude_settings,
                journal,
                turn_state_path: Some(state_directory.join("active-codex-turns.json")),
                recovery_path: Some(state_directory.join("codex-restart-recovery.json")),
                call_delivery,
                external_auth,
                external_providers,
            },
            apns,
        )
    }

    fn construct_with_apns(
        configuration: GatewayConstruction,
        apns: Arc<PushService>,
    ) -> Arc<Self> {
        let GatewayConstruction {
            codex,
            user_name,
            claude_settings,
            journal,
            turn_state_path,
            recovery_path,
            call_delivery,
            external_auth,
            external_providers,
        } = configuration;
        let metadata_path = turn_state_path
            .as_ref()
            .map(|path| path.with_file_name("session-metadata-v2.json"));
        let navigation_device_path = turn_state_path
            .as_ref()
            .map(|path| path.with_file_name("navigation-device.json"));
        let calls_path = turn_state_path
            .as_ref()
            .map(|path| path.with_file_name("agent-calls.json"));
        let marks_location = turn_state_path
            .as_deref()
            .and_then(Path::parent)
            .map(|directory| crate::conversation_marks::Location {
                directory: directory.to_path_buf(),
                handoff_records: directory.join("conversation-handoffs.json"),
            });
        let favorites = turn_state_path
            .as_deref()
            .and_then(Path::parent)
            .map(crate::directory_favorites::DirectoryFavoritesStore::new);
        let tool_media = turn_state_path
            .as_deref()
            .and_then(Path::parent)
            .map(|directory| {
                crate::storage::tool_media::ToolMediaStore::new(directory.to_path_buf())
            });
        let preferences = turn_state_path
            .as_deref()
            .and_then(Path::parent)
            .map(crate::user_preferences::UserPreferencesStore::new);
        let projects = Default::default();
        let navigation = Arc::new(NavigationManager::new(
            Arc::clone(&apns),
            journal.clone(),
            navigation_device_path,
        ));
        let next_client_id = Arc::new(AtomicU64::new(1));
        let request_budgets = Default::default();
        let claude_projections =
            Arc::new(crate::providers::claude::projection::ProjectionCache::new(
                crate::providers::claude::projection::PROJECTION_CACHE_BUDGET_BYTES,
            ));
        let device_photos = Default::default();
        let device_tools = Arc::new(device_tools::DeviceTools::new(
            device_photos,
            journal.clone(),
        ));
        let admission = Arc::new(crate::gateway::admission::ConversationAdmission::default());
        let restart_store = turn_state_path
            .as_deref()
            .map(crate::providers::claude::restart::Store::beside);
        let restart_journal = journal.clone();
        Arc::new_cyclic(|gateway| Self {
            user_name,
            claude_recovery_ready: AtomicBool::new(!claude_settings.enabled),
            review: conversation_review::Runtime::new(
                gateway.clone(),
                claude_settings.router.clone(),
            ),
            renames: renames::Renames::default(),
            side_question_forks: side_question::Forks::default(),
            external_auth,
            external_providers,
            admission: Arc::clone(&admission),
            agents: agent_gateway::Runtime::default(),
            questions: question_gateway::Runtime::new(
                turn_state_path
                    .as_ref()
                    .and_then(|path| path.parent())
                    .map(|path| path.join("questions")),
                gateway.clone(),
            ),
            external_activity: crate::activity::external::ExternalActivity::default(),
            activity: activity::ActivityPublisher::default(),
            claude_auth: Arc::new(ClaudeAuth::new(claude_settings.clone())),
            claude_history: crate::providers::claude::history::ClaudeHistory::new(
                claude_settings.claude_home.clone(),
                claude_projections,
            ),
            claude_settings,
            claude_auth_task: Mutex::new(None),
            claude_notification_hook_health: Mutex::new(None),
            claude_agent: std::sync::Mutex::new(None),
            claude_notification_task: Mutex::new(None),
            voice: VoiceCoordinator::default(),
            mcp_tokens: McpTokens::new(),
            navigation,
            calls: calls::AgentCalls::new(calls_path, call_delivery),
            codex,
            apns,
            clients: DashMap::new(),
            journal,
            core: Mutex::new(GatewayCoreState::default()),
            draining: AtomicBool::new(false),
            listening: tokio::sync::watch::channel(false).0,
            claude_restart: ClaudeRestartDriver::new(
                restart_store,
                admission,
                restart_journal,
                lifecycle::restart_alert(gateway.clone()),
            ),
            claude_recovery_task: Mutex::new(None),
            control: control::ControlConnection::default(),
            native_mutation_transport: Mutex::new(None),
            native_mutations: native_mutations::PendingNativeMutations::default(),
            control_task: Mutex::new(None),
            control_init_result: Mutex::new(None),
            provider_health: provider_health::ProviderHealthOwner::default(),
            control_requests: std::sync::Mutex::new(HashMap::new()),
            next_control_request_id: AtomicU64::new(1),
            observer_tasks: Mutex::new(HashMap::new()),
            apns_completion_tx: Mutex::new(None),
            apns_completion_task: Mutex::new(None),
            apns_live_activity_tx: Mutex::new(None),
            apns_live_activity_task: Mutex::new(None),
            next_client_id,
            turn_state_path,
            turn_state_write_lock: Arc::new(Mutex::new(())),
            recovery_store: recovery_path.map(RecoveryStore::new),
            metadata: crate::conversations::ConversationMetadataStore::new(metadata_path),
            marks: crate::conversation_marks::ConversationMarksStore::new(marks_location),
            favorites,
            tool_media,
            preferences,
            projects,
            request_budgets,
            device_tools,
            tool_claims: crate::agents::tools::claims::ToolClaims::default(),
            tool_tasks: crate::tasks::owned_tasks::OwnedTasks::default(),
            command_tasks: crate::tasks::owned_tasks::OwnedTasks::default(),
            voice_tasks: crate::tasks::owned_tasks::OwnedTasks::default(),
            reset_tasks: crate::tasks::owned_tasks::OwnedTasks::default(),
            reset_capacity: Arc::new(tokio::sync::Semaphore::new(16)),
        })
    }

    pub(crate) async fn start(self: &Arc<Self>) -> Result<()> {
        self.codex.verify_ready().await?;
        self.load_turn_state().await?;
        self.calls.load().await?;
        self.start_notification_ancestry_preflight().await;

        // APNs is best-effort, but should be serialized/coalesced to avoid bursts and JWT churn.
        let (completion_tx, completion_rx) = mpsc::channel::<ApnsSend>(256);
        *self.apns_completion_tx.lock().await = Some(completion_tx);
        let completion_task = {
            let gw = Arc::clone(self);
            let task_gw = Arc::clone(&gw);
            tokio::spawn(task_gw.run_task_logged("apns_completion_loop", async move {
                gw.apns_completion_loop(completion_rx).await
            }))
        };
        *self.apns_completion_task.lock().await = Some(completion_task);

        self.start_live_activity().await;

        // Gateway-owned voice and observer work gets one control connection.
        // Each remote client opens its own independent app-server connection.
        let control_task = {
            let gw = Arc::clone(self);
            let task_gw = Arc::clone(&gw);
            tokio::spawn(task_gw.run_task_logged("codex_control_loop", async move {
                gw.codex_control_loop().await
            }))
        };
        *self.control_task.lock().await = Some(control_task);

        self.start_activity_publisher().await;

        if self.claude_settings.enabled {
            let claude_auth_task = {
                let gw = Arc::clone(self);
                let task_gw = Arc::clone(&gw);
                tokio::spawn(
                    task_gw.run_task_logged("claude_auth_preflight_loop", async move {
                        gw.claude_auth_preflight_loop().await
                    }),
                )
            };
            *self.claude_auth_task.lock().await = Some(claude_auth_task);

            // Claude turns feed the same notification funnel as Codex control
            // frames, so replay, push, and Live Activity behave identically.
            let (notifications_tx, notifications_rx) =
                mpsc::channel::<crate::providers::claude::ClaudeNotification>(1024);
            self.set_claude_agent(ClaudeSupervisor::new(
                self.claude_settings.clone(),
                notifications_tx,
                self.journal.clone(),
                self.mcp_tokens.clone(),
            ));
            let claude_notification_task = {
                let gw = Arc::clone(self);
                let task_gw = Arc::clone(&gw);
                tokio::spawn(
                    task_gw.run_task_logged("claude_notification_loop", async move {
                        gw.claude_notification_loop(notifications_rx).await
                    }),
                )
            };
            *self.claude_notification_task.lock().await = Some(claude_notification_task);
            self.spawn_claude_restart_recovery().await;
        }

        Ok(())
    }

    /// Drains agent notifications into the shared client funnel.
    async fn claude_notification_loop(
        self: Arc<Self>,
        mut rx: mpsc::Receiver<crate::providers::claude::ClaudeNotification>,
    ) {
        while let Some(message) = rx.recv().await {
            match message {
                crate::providers::claude::ClaudeNotification::Event(value) => {
                    self.ingest_agent_notification(value).await
                }
                crate::providers::claude::ClaudeNotification::IngressBarrier(acknowledged) => {
                    let _ = acknowledged.send(());
                }
            }
        }
    }

    /// Refreshes the Claude auth snapshot on a fixed interval.
    ///
    /// Failures are reported through `/health`, never escalated: a broken Claude
    /// router configuration must not take the Codex gateway down.
    async fn claude_auth_preflight_loop(self: Arc<Self>) {
        let interval = Duration::from_secs(self.claude_settings.auth_preflight_interval_secs);
        loop {
            let hook = crate::providers::claude::notification_hook::preflight().await;
            self.journal
                .runtime("notificationHookPreflight", hook.clone());
            *self.claude_notification_hook_health.lock().await = Some(hook);
            let snapshot = self.claude_auth.refresh().await;
            self.refresh_provider_health().await;
            if !snapshot.ok() {
                warn!(
                    error = snapshot.error.as_deref().unwrap_or("router is unavailable"),
                    "claude provider is not usable"
                );
            }
            tokio::time::sleep(interval).await;
        }
    }

    pub(crate) fn claude_agent(&self) -> Option<Arc<ClaudeSupervisor>> {
        self.claude_agent
            .lock()
            .expect("Claude supervisor slot poisoned")
            .clone()
    }

    pub(crate) fn set_claude_agent(&self, agent: Arc<ClaudeSupervisor>) {
        *self
            .claude_agent
            .lock()
            .expect("Claude supervisor slot poisoned") = Some(agent);
    }

    fn take_claude_agent(&self) -> Option<Arc<ClaudeSupervisor>> {
        self.claude_agent
            .lock()
            .expect("Claude supervisor slot poisoned")
            .take()
    }

    /// Claude provider view for `/health`.
    ///
    /// Reported, never enforced: `install-launchagent.zsh` gates installs on the
    /// top-level status and `codexPid`, so a failing Claude preflight must not
    /// change either.
    pub(crate) async fn claude_health(&self) -> Value {
        let snapshot = self.claude_auth.cached_snapshot().await;
        let agent = self.claude_agent();
        let active_turns = match agent.as_ref() {
            Some(agent) => agent.active_turn_count().await,
            None => 0,
        };
        let mut health = crate::providers::claude::auth::health_json(
            &self.claude_settings,
            snapshot.as_ref(),
            active_turns,
        );
        health["notificationHook"] = self
            .claude_notification_hook_health
            .lock()
            .await
            .clone()
            .unwrap_or_else(|| json!({"status":"unknown","reason":"notChecked"}));
        health
    }

    pub(crate) fn is_draining(&self) -> bool {
        self.draining.load(Ordering::Acquire)
    }

    pub(crate) async fn active_turn_count(&self) -> usize {
        self.core.lock().await.turns.active_count()
    }

    pub(crate) async fn reported_active_turn_status(&self) -> (usize, bool) {
        let core = self.core.lock().await;
        let mut turn_keys = core.turns.active_keys().cloned().collect::<HashSet<_>>();
        turn_keys.extend(
            core.app_server_active_turns_by_thread
                .values()
                .map(|turn| TurnKey::new(&turn.thread_id, &turn.turn_id)),
        );
        (
            turn_keys.len(),
            core.app_server_inventory_bootstrapped
                && core.app_server_inventory_unresolved_threads.is_empty(),
        )
    }

    pub(crate) async fn prepared_handoff_is_durable(&self) -> bool {
        self.recovery_journal()
            .await
            .is_some_and(|journal| journal.is_prepared_handoff())
    }

    async fn restart_in_progress(&self) -> bool {
        self.is_draining()
            || self
                .recovery_journal()
                .await
                .is_some_and(|journal| journal.is_planned_transition())
    }

    async fn recovery_journal(&self) -> Option<RecoveryJournal> {
        let store = self.recovery_store.clone()?;
        match tokio::task::spawn_blocking(move || store.load()).await {
            Ok(Ok(journal)) => journal,
            Ok(Err(error)) => {
                warn!(%error, "failed to inspect recovery journal");
                None
            }
            Err(error) => {
                warn!(%error, "recovery journal inspection task failed");
                None
            }
        }
    }

    async fn stop_voice_for_shutdown(&self) {
        let unused_shadows = self.voice.shadows.close();
        if let Some(session) = self.voice.take_for_shutdown() {
            session.close_log("shutdown");

            let params = serde_json::json!({ "threadId": session.realtime_thread_id });
            match tokio::time::timeout(
                Duration::from_secs(SHUTDOWN_INTERRUPT_GRACE_SECONDS),
                self.call_control("thread/realtime/stop", params),
            )
            .await
            {
                Ok(Ok(_)) => info!("realtime voice session stopped for shutdown"),
                Ok(Err(error)) => {
                    warn!(%error, "failed to stop realtime voice session for shutdown")
                }
                Err(_) => warn!("timed out stopping realtime voice session for shutdown"),
            }
            if let Some(log) = session.log.as_ref() {
                log.drain(Duration::from_secs(SHUTDOWN_INTERRUPT_GRACE_SECONDS))
                    .await;
            }
        }
        if tokio::time::timeout(
            Duration::from_secs(SHUTDOWN_INTERRUPT_GRACE_SECONDS),
            self.delete_unused_voice_shadow_threads(unused_shadows),
        )
        .await
        .is_err()
        {
            warn!("timed out deleting unused voice shadow threads for shutdown");
        }
    }

    pub(crate) async fn stop(&self) -> Result<()> {
        self.draining.store(true, Ordering::Release);
        self.stop_voice_for_shutdown().await;
        self.stop_notification_ancestry_preflight().await;
        // Accepted command work is gateway-owned, not tied to a socket. Finish
        // its cancellation before taking away provider/control resources.
        self.review.stop().await;
        self.renames.stop().await;
        self.questions.stop().await;
        self.tool_tasks.stop().await;
        self.command_tasks.stop().await;
        self.voice_tasks.stop().await;
        self.reset_tasks.stop().await;
        let task = self.claude_recovery_task.lock().await.take();
        if let Some(task) = task {
            task.abort();
            let _ = task.await;
        }
        // Claude children are killed before the tasks that supervise them, so a
        // shutdown cannot leave an orphaned turn process group behind.
        if let Some(agent) = self.take_claude_agent() {
            agent.stop_all().await;
        }
        let task = self.claude_notification_task.lock().await.take();
        if let Some(task) = task {
            task.abort();
            let _ = task.await;
        }
        let task = self.claude_auth_task.lock().await.take();
        if let Some(task) = task {
            task.abort();
            let _ = task.await;
        }
        let task = self.control_task.lock().await.take();
        if let Some(task) = task {
            task.abort();
            let _ = task.await;
        }
        let observer_tasks = {
            let mut tasks = self.observer_tasks.lock().await;
            tasks.drain().map(|(_, task)| task).collect::<Vec<_>>()
        };
        for task in observer_tasks {
            task.abort();
            let _ = task.await;
        }
        self.stop_activity_publisher().await;
        self.stop_agent_inventory().await;
        let task = self.apns_completion_task.lock().await.take();
        if let Some(task) = task {
            task.abort();
            let _ = task.await;
        }
        let task = self.apns_live_activity_task.lock().await.take();
        if let Some(task) = task {
            task.abort();
            let _ = task.await;
        }
        self.control.retire().await;
        *self.native_mutation_transport.lock().await = None;
        *self.control_init_result.lock().await = None;
        self.control_requests
            .lock()
            .expect("control replies poisoned")
            .clear();
        *self.apns_completion_tx.lock().await = None;
        *self.apns_live_activity_tx.lock().await = None;
        Ok(())
    }

    pub(crate) async fn daemon_ready(&self) -> Result<DaemonReady> {
        let info = tokio::time::timeout(
            Duration::from_secs_f64(CODEX_LIVENESS_PROBE_TIMEOUT_SECONDS),
            self.codex.probe_ready_info(),
        )
        .await
        .context("codex readiness probe timed out")??;
        if self.control_init_result.lock().await.is_none() {
            return Err(anyhow!("Codex control connection is not initialized"));
        }
        Ok(DaemonReady {
            codex_pid: info.pid,
            started_at_unix_seconds: info.started_at_unix_seconds,
        })
    }

    /// Reads the app-server's process-local diagnostics for deployment acceptance.
    /// Ordinary lifecycle readiness does not depend on this response.
    pub(crate) async fn daemon_diagnostics(&self) -> Result<Value> {
        self.call_control("server/diagnostics", serde_json::json!({}))
            .await
    }

    /// Journal handle, for the agent-tool dispatcher.
    pub(crate) fn journal(&self) -> &Journal {
        &self.journal
    }

    /// Per-runtime MCP bearer tokens, minted at Claude runtime spawn and
    /// checked by the `/mcp` endpoint.
    pub(crate) fn mcp_tokens(&self) -> &McpTokens {
        &self.mcp_tokens
    }
}

struct ClientRequests {
    out_tx: ClientTx,
    lane_tx: mpsc::Sender<UpstreamFrame>,
    voice_tx: mpsc::Sender<VoiceRequest>,
    queries: Arc<crate::tasks::owned_tasks::OwnedTasks>,
}

enum UpstreamFrame {
    Response(String),
    Request(NativeRequest),
}

struct NativeRequest {
    raw: String,
    request: ClientRequest,
    _admission: Option<crate::gateway::admission::Admission>,
}

struct VoiceRequest {
    method: String,
    object: serde_json::Map<String, Value>,
    _permit: crate::rpc::RequestPermit,
    _admission: Option<crate::gateway::admission::Admission>,
}

/// Clamps an app reasoning effort to what `claude --effort` accepts.
///
/// The CLI rejects an unknown level outright, which would fail the whole turn.
fn claude_effort_wire_value(effort: &str) -> String {
    match effort {
        "low" | "medium" | "high" | "xhigh" | "max" => effort.to_string(),
        _ => "max".to_string(),
    }
}

async fn claude_fast_mode(
    agent: &ClaudeSupervisor,
    thread_id: &str,
    model: &str,
    service_tier: Option<Option<&str>>,
) -> Result<bool, crate::rpc::RpcError> {
    match service_tier {
        None => Ok(agent.fast_mode(thread_id, model).await),
        Some(None) => Ok(false),
        Some(Some("fast")) => Ok(true),
        Some(Some(tier)) => Err(crate::rpc::RpcError::new(
            crate::rpc::error::RpcCode::InvalidParams,
            format!("Claude has no {tier} service tier"),
        )),
    }
}

fn thread_cwd(thread: &Value) -> String {
    thread
        .get("cwd")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

#[cfg(test)]
mod tests;
