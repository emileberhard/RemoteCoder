use super::{Accounts, usage};
use crate::accounts::types::{
    AccountId, AccountSnapshot, AccountState, DEFAULT_CLAUDE, DEFAULT_CODEX,
};
use crate::providers::Provider;
use crate::time::unix_seconds;
use anyhow::{Context, Result};
use serde::Serialize;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Directory {
    pub schema_version: u8,
    pub accounts: Vec<AccountSnapshot>,
    pub retired_claude_account_ids: Vec<AccountId>,
    pub retired_codex_account_ids: Vec<AccountId>,
    pub refreshing: bool,
}

impl Accounts {
    pub(crate) async fn start_refresh(self: &Arc<Self>) {
        self.refresh_directory();
    }

    pub(crate) fn refresh_reset_account(self: &Arc<Self>, key: String) {
        let mut start = false;
        self.reset_refreshing.send_modify(|pending| {
            let generation = pending.entry(key.clone()).or_insert_with(|| {
                start = true;
                0
            });
            *generation += 1;
        });
        if !start {
            return;
        }
        let mut pending = ResetRefreshOwner {
            owner: Arc::clone(self),
            key: key.clone(),
            active: true,
        };
        let owner = Arc::clone(self);
        self.tasks.spawn(async move {
            tokio::select! {
                _ = owner.cancellation.cancelled() => {},
                _ = async {
                    let mut refreshing = owner.refreshing.subscribe();
                    loop {
                        if owner.refreshing.send_if_modified(|owners| owners.insert(key.clone())) { break; }
                        if refreshing.wait_for(|owners| !owners.contains(&key)).await.is_err() { return; }
                    }
                    let _refresh = RefreshOwner { owner: Arc::clone(&owner), key: key.clone() };
                    loop {
                        let generation = owner.reset_refreshing.borrow()[&key];
                        if let Some(snapshot) = owner.snapshots.write().await.get_mut(&key) {
                            snapshot.resets = None;
                            snapshot.windows.clear();
                            snapshot.observed_at = None;
                            snapshot.stale = true;
                        }
                        let _ = owner.persist_snapshots().await;
                        let Ok(permit) = owner.capacity.acquire().await else { return; };
                        owner.refresh_one(&key).await;
                        drop(permit);
                        if pending.settle(generation) { break; }
                    }
                } => {},
            }
        });
    }

    pub(crate) async fn refresh_settled(&self, bound: Duration) {
        let mut refreshing = self.refreshing.subscribe();
        let mut resets = self.reset_refreshing.subscribe();
        let _ = tokio::time::timeout(bound, async {
            loop {
                if refreshing.borrow().is_empty() && resets.borrow().is_empty() {
                    return;
                }
                tokio::select! {
                    _ = refreshing.changed() => {},
                    _ = resets.changed() => {},
                }
            }
        })
        .await;
    }

    pub(crate) async fn directory(self: &Arc<Self>) -> Directory {
        let snapshots = self.snapshots.read().await;
        let mut accounts = Vec::new();
        for provider in [Provider::Codex, Provider::Claude] {
            let default = default_snapshot(provider);
            accounts.push(snapshots.get(&default.id).cloned().unwrap_or(default));
        }
        let refreshing = self.refreshing.borrow();
        let reset_refreshing = self.reset_refreshing.borrow();
        for sample in &mut accounts {
            if reset_refreshing.contains_key(&sample.id) {
                sample.resets = None;
                sample.windows.clear();
                sample.observed_at = None;
                sample.stale = true;
            }
        }
        drop(snapshots);
        let mut retired_claude_account_ids =
            self.retired_claude_ids.iter().cloned().collect::<Vec<_>>();
        retired_claude_account_ids.sort_by(|a, b| a.as_str().cmp(b.as_str()));
        let mut retired_codex_account_ids =
            self.retired_codex_ids.iter().cloned().collect::<Vec<_>>();
        retired_codex_account_ids.sort_by(|a, b| a.as_str().cmp(b.as_str()));
        Directory {
            retired_claude_account_ids,
            retired_codex_account_ids,
            schema_version: 2,
            accounts,
            refreshing: !refreshing.is_empty() || !reset_refreshing.is_empty(),
        }
    }

    pub(super) fn refresh_directory(self: &Arc<Self>) {
        if self.stopping.load(Ordering::Acquire) {
            return;
        }
        let keys = [DEFAULT_CODEX.to_owned(), DEFAULT_CLAUDE.to_owned()];
        for key in keys {
            let due = self
                .attempts
                .lock()
                .expect("account refresh attempts")
                .get(&key)
                .is_none_or(|(at, failures)| {
                    at.elapsed()
                        >= Duration::from_secs(if *failures == 0 {
                            120
                        } else {
                            (30u64 << (*failures - 1).min(3)).min(300)
                        })
                });
            if !due
                || !self
                    .refreshing
                    .send_if_modified(|owners| owners.insert(key.clone()))
            {
                continue;
            }
            let owner = Arc::clone(self);
            self.tasks.spawn(async move {
                let _refresh = RefreshOwner { owner: Arc::clone(&owner), key: key.clone() };
                tokio::select! {
                    _ = owner.cancellation.cancelled() => {},
                    _ = async {
                        let Ok(_permit) = owner.capacity.acquire().await else { return; };
                        let fresh = owner.refresh_one(&key).await;
                        let mut attempts = owner.attempts.lock().expect("account refresh attempts");
                        let failures = if fresh { 0 } else { attempts.get(&key).map_or(1, |(_, failures)| failures.saturating_add(1)) };
                        attempts.insert(key, (Instant::now(), failures));
                    } => {},
                }
            });
        }
    }

    pub(super) async fn refresh_one(self: &Arc<Self>, key: &str) -> bool {
        let mut snapshot;
        let result: Result<()> = async {
            let (gateway, provider) = match key {
                DEFAULT_CODEX => (self.host.clone(), Provider::Codex),
                DEFAULT_CLAUDE => (self.host.clone(), Provider::Claude),
                _ => return Err(anyhow::anyhow!("Unknown host account")),
            };
            let mut sample = default_snapshot(provider);
            match provider {
                Provider::Codex => {
                    let account = gateway
                        .native_account()
                        .await
                        .context("Could not read the native Codex login")?;
                    let limits = if account["account"]["type"] == "chatgpt" {
                        sample.identity = gateway.verified_codex_identity(&account).await?;
                        gateway
                            .account_quota()
                            .await
                            .inspect_err(|error| {
                                tracing::warn!(
                                    account = key,
                                    error = format!("{error:#}"),
                                    "Codex usage refresh failed"
                                )
                            })
                            .ok()
                    } else {
                        None
                    };
                    usage::apply_codex(
                        &mut sample,
                        &account,
                        limits.as_ref().map(|quota| &quota.rate_limits),
                    )?;
                    sample.resets = limits.as_ref().and_then(|quota| quota.resets.clone());
                    if sample.state == AccountState::Ready
                        && limits.is_none()
                        && let Some(previous) = self.snapshots.read().await.get(key)
                    {
                        usage::retain_codex_usage(&mut sample, previous, unix_seconds());
                    }
                    sample.error = gateway.external_auth_error();
                }
                Provider::Claude => {
                    let status = gateway.refreshed_claude_status().await;
                    usage::apply_claude(&mut sample, &status)?;
                }
            }
            sample.active_turns = gateway.reported_active_turn_status().await.0;
            sample.incoming_call_routing_id = Some(gateway.incoming_call_routing_id().await);
            self.snapshots.write().await.insert(key.to_owned(), sample);
            Ok(())
        }
        .await;
        if let Err(error) = result {
            let previous = self.snapshots.read().await.get(key).cloned();
            snapshot = if let Some(previous) = previous {
                previous
            } else {
                default_snapshot(if key == DEFAULT_CLAUDE {
                    Provider::Claude
                } else {
                    Provider::Codex
                })
            };
            snapshot.stale = true;
            snapshot.state = AccountState::Unavailable;
            snapshot.error = Some(error.to_string());
            if !usage::is_last_known(snapshot.observed_at, unix_seconds()) {
                snapshot.windows.clear();
                snapshot.resets = None;
                snapshot.observed_at = None;
            }
            self.snapshots
                .write()
                .await
                .insert(key.to_owned(), snapshot);
        }
        let _ = self.persist_snapshots().await;
        self.snapshots
            .read()
            .await
            .get(key)
            .is_some_and(|sample| sample.state == AccountState::Ready && !sample.stale)
    }

    pub(super) async fn persist_snapshots(&self) -> Result<()> {
        let _writer = self.snapshot_write.lock().await;
        let samples = self.snapshots.read().await.clone();
        let path = self.paths.state("account-usage.json");
        tokio::task::spawn_blocking(move || {
            crate::storage::private_state::write_json(&path, &samples)
        })
        .await??;
        Ok(())
    }
}

struct ResetRefreshOwner {
    owner: Arc<Accounts>,
    key: String,
    active: bool,
}
impl ResetRefreshOwner {
    fn settle(&mut self, generation: u64) -> bool {
        self.owner.reset_refreshing.send_if_modified(|pending| {
            if pending.get(&self.key) == Some(&generation) {
                pending.remove(&self.key);
                self.active = false;
                true
            } else {
                false
            }
        });
        !self.active
    }
}
impl Drop for ResetRefreshOwner {
    fn drop(&mut self) {
        if self.active {
            self.owner
                .reset_refreshing
                .send_if_modified(|pending| pending.remove(&self.key).is_some());
        }
    }
}

struct RefreshOwner {
    owner: Arc<Accounts>,
    key: String,
}
impl Drop for RefreshOwner {
    fn drop(&mut self) {
        self.owner
            .refreshing
            .send_if_modified(|owners| owners.remove(&self.key));
    }
}
fn default_snapshot(provider: Provider) -> AccountSnapshot {
    let (id, label) = match provider {
        Provider::Codex => (DEFAULT_CODEX, "Host default · ChatGPT"),
        Provider::Claude => (DEFAULT_CLAUDE, "Host default · Claude"),
    };
    AccountSnapshot {
        id: id.into(),
        provider,
        label: label.into(),
        enabled: true,
        generation: 1,
        is_default: true,
        identity: None,
        plan: None,
        state: AccountState::Unavailable,
        windows: Vec::new(),
        resets: None,
        observed_at: None,
        stale: true,
        error: None,
        active_turns: 0,
        incoming_call_routing_id: None,
    }
}
