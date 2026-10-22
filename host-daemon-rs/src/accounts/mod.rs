pub(crate) mod claude_migration;
pub(crate) mod codex_migration;
pub(crate) mod registry;
pub(crate) mod resets;
mod snapshots;
#[cfg(test)]
mod tests;
pub mod types;
mod usage;
pub(crate) use usage::codex_identity_in_workspace;

use crate::accounts::types::{AccountId, AccountSnapshot, AccountState};
use crate::config::HostPaths;
use crate::gateway::Gateway;
use crate::providers::Provider;
use crate::providers::claude::settings::ClaudeSettings;
use anyhow::{Result, ensure};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Instant;
use tokio::sync::{Mutex, RwLock, Semaphore, watch};
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

#[derive(Debug)]
pub(crate) struct AccountsBusy;
impl std::fmt::Display for AccountsBusy {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("Too many account operations are running; retry shortly")
    }
}
impl std::error::Error for AccountsBusy {}
#[derive(Debug)]
pub(crate) struct GatewayStopping;
impl std::fmt::Display for GatewayStopping {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("Gateway is restarting")
    }
}
impl std::error::Error for GatewayStopping {}

pub(crate) struct Accounts {
    paths: HostPaths,
    host: Arc<Gateway>,
    claude: ClaudeSettings,
    retired_claude_ids: HashSet<AccountId>,
    retired_codex_ids: HashSet<AccountId>,
    snapshots: RwLock<HashMap<String, AccountSnapshot>>,
    attempts: StdMutex<HashMap<String, (Instant, u32)>>,
    snapshot_write: Mutex<()>,
    refreshing: watch::Sender<HashSet<String>>,
    reset_refreshing: watch::Sender<HashMap<String, u64>>,
    capacity: Arc<Semaphore>,
    tasks: TaskTracker,
    stopping: AtomicBool,
    cancellation: CancellationToken,
}

impl Accounts {
    pub(crate) async fn open(
        paths: &HostPaths,
        host: Arc<Gateway>,
        claude: ClaudeSettings,
    ) -> Result<Arc<Self>> {
        Self::open_in(paths.home().to_path_buf(), host, claude).await
    }
    pub(super) async fn open_in(
        home: PathBuf,
        host: Arc<Gateway>,
        claude: ClaudeSettings,
    ) -> Result<Arc<Self>> {
        let paths = HostPaths::from_home(home.clone())?;
        let (retired_claude_ids, retired_codex_ids) = tokio::task::spawn_blocking(move || {
            Ok::<_, anyhow::Error>((
                claude_migration::retired_ids(&home)?,
                codex_migration::retired_ids(&home)?,
            ))
        })
        .await??;
        let retired_claude_ids = retired_claude_ids
            .into_iter()
            .map(AccountId::try_from)
            .collect::<Result<HashSet<_>>>()?;
        let retired_codex_ids = retired_codex_ids
            .into_iter()
            .map(AccountId::try_from)
            .collect::<Result<HashSet<_>>>()?;
        host.reconcile_live_activity_scopes(&std::collections::BTreeSet::from([
            "default".to_owned()
        ]))
        .await;
        let cached = tokio::fs::read(paths.state("account-usage.json"))
            .await
            .ok()
            .and_then(|bytes| {
                serde_json::from_slice::<HashMap<String, AccountSnapshot>>(&bytes).ok()
            })
            .unwrap_or_default();
        let snapshots = cached
            .into_iter()
            .filter(|(id, _)| matches!(id.as_str(), types::DEFAULT_CODEX | types::DEFAULT_CLAUDE))
            .map(|(id, mut sample)| {
                sample.stale = true;
                sample.resets = None;
                if sample.provider == Provider::Claude {
                    sample.identity = None;
                    sample.plan = None;
                }
                if sample.provider == Provider::Claude
                    || !usage::is_last_known(sample.observed_at, crate::time::unix_seconds())
                {
                    sample.windows.clear();
                    sample.observed_at = None;
                }
                sample.state = if sample.enabled {
                    AccountState::Unavailable
                } else {
                    AccountState::Disabled
                };
                (id, sample)
            })
            .collect();
        Ok(Arc::new(Self {
            paths,
            host,
            claude,
            retired_claude_ids,
            retired_codex_ids,
            snapshots: RwLock::new(snapshots),
            attempts: StdMutex::new(HashMap::new()),
            snapshot_write: Mutex::new(()),
            refreshing: watch::channel(HashSet::new()).0,
            reset_refreshing: watch::channel(HashMap::new()).0,
            capacity: Arc::new(Semaphore::new(2)),
            tasks: TaskTracker::new(),
            stopping: AtomicBool::new(false),
            cancellation: CancellationToken::new(),
        }))
    }

    pub(crate) fn redirects_to_default(&self, id: &AccountId) -> bool {
        self.retired_claude_ids.contains(id) || self.retired_codex_ids.contains(id)
    }

    pub(crate) async fn gateway_for_account(
        &self,
        id: &AccountId,
        _generation: Option<u64>,
    ) -> Result<Arc<Gateway>> {
        ensure!(!self.stopping.load(Ordering::Acquire), GatewayStopping);
        ensure!(
            self.redirects_to_default(id),
            "Account enrollment not found"
        );
        Ok(self.host.clone())
    }

    pub(crate) async fn drain(&self) {
        self.stopping.store(true, Ordering::Release);
        self.cancellation.cancel();
    }
    pub(crate) async fn stop(&self) {
        self.drain().await;
        self.tasks.close();
        self.tasks.wait().await;
    }
}
