use super::control::ControlGeneration;
use super::{ClientCommand, ClientTx, Gateway, RESTARTING_CLOSE_CODE};
use crate::observability::journal::Source;
use crate::providers::codex::external::ExternalProviders;
use crate::rpc::RpcError;
use crate::rpc::error::{CodexUnavailable, RETRY_AFTER_MS, RpcCode, RpcData};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::{Arc, Weak};
use std::time::Duration;
use tracing::{info, warn};

pub(super) const PROVIDER_HEALTH_METHOD: &str = "gateway/providerHealth";
const CODEX_NOT_RUNNING: &str = "Codex app-server is not running";
const CODEX_STARTING: &str = "Codex is starting";
const CODEX_AWAITING_SIGN_IN: &str =
    "Codex is waiting for its subscription sign-in to resume interrupted work";
const CODEX_SIGN_IN_FAILED: &str = "Codex subscription sign-in failed";
const CODEX_CONNECTION_FAILED: &str = "This connection could not reach Codex; reconnect";
const CODEX_READY_CLOSE_REASON: &str = "Codex is available; reconnect";
const CODEX_RECONNECT_FIRST_PROBE: Duration = Duration::from_secs(5);
const CODEX_RECONNECT_PROBE_LIMIT: Duration = Duration::from_secs(30);

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub(crate) enum CodexHealth {
    Ready,
    Fallback { reason: String, fallback: String },
    Unavailable { reason: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub(crate) enum ClaudeHealth {
    Ready,
    Fallback { reason: String, fallback: String },
    Unavailable { reason: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct ProviderHealth {
    codex: CodexHealth,
    #[serde(skip_serializing_if = "Option::is_none")]
    claude: Option<ClaudeHealth>,
}

#[derive(Clone, Copy, Debug)]
pub(super) enum CodexControl {
    Disconnected,
    Starting,
    AwaitingSignIn,
    Ready,
}

#[derive(Clone)]
enum Readiness {
    Ready,
    Unavailable(String),
    Unknown(String),
}

impl Readiness {
    fn available(self) -> Result<bool, RpcError> {
        match self {
            Self::Ready => Ok(true),
            Self::Unavailable(_) => Ok(false),
            Self::Unknown(reason) => Err(RpcError::new(RpcCode::Unavailable, reason)
                .with_data(RpcData::RetryAfterMs(RETRY_AFTER_MS))),
        }
    }
}

struct NativeReadiness {
    generation: Weak<ControlGeneration>,
    evidence: Readiness,
}

pub(super) struct ProviderHealthOwner {
    native: std::sync::Mutex<Option<NativeReadiness>>,
    native_refresh: tokio::sync::Mutex<()>,
    published: std::sync::Mutex<ProviderHealth>,
    refresh: tokio::sync::Mutex<()>,
    degraded_clients: std::sync::Mutex<HashSet<u64>>,
}

impl Default for ProviderHealthOwner {
    fn default() -> Self {
        Self {
            native: std::sync::Mutex::default(),
            native_refresh: tokio::sync::Mutex::default(),
            published: std::sync::Mutex::new(ProviderHealth {
                codex: CodexHealth::Unavailable {
                    reason: CODEX_NOT_RUNNING.into(),
                },
                claude: None,
            }),
            refresh: tokio::sync::Mutex::default(),
            degraded_clients: std::sync::Mutex::default(),
        }
    }
}

impl Gateway {
    pub(super) async fn codex_ready(&self) -> bool {
        self.control_init_result.lock().await.is_some()
    }

    pub(super) async fn codex_subscription_failing(&self) -> bool {
        self.external_auth.is_some() && self.require_external_auth().await.is_err()
    }

    async fn codex_control(&self) -> CodexControl {
        let Some(generation) = self.control.current() else {
            return CodexControl::Disconnected;
        };
        if self.codex_ready().await {
            CodexControl::Ready
        } else if generation
            .auth
            .lock()
            .expect("Codex auth state poisoned")
            .holds_recovery
        {
            CodexControl::AwaitingSignIn
        } else {
            CodexControl::Starting
        }
    }

    async fn codex_readiness(&self) -> Readiness {
        match self.codex_control().await {
            CodexControl::Disconnected => return Readiness::Unknown(CODEX_NOT_RUNNING.into()),
            CodexControl::Starting => return Readiness::Unknown(CODEX_STARTING.into()),
            CodexControl::AwaitingSignIn => {
                return Readiness::Unknown(CODEX_AWAITING_SIGN_IN.into());
            }
            CodexControl::Ready => (),
        }
        if self.external_auth.is_some() {
            return if self.codex_subscription_failing().await {
                Readiness::Unavailable(CODEX_SIGN_IN_FAILED.into())
            } else {
                Readiness::Ready
            };
        }
        let current = self.control.current();
        self.provider_health
            .native
            .lock()
            .expect("native readiness poisoned")
            .as_ref()
            .filter(|snapshot| {
                snapshot
                    .generation
                    .upgrade()
                    .zip(current)
                    .is_some_and(|(previous, current)| Arc::ptr_eq(&previous, &current))
            })
            .map(|snapshot| snapshot.evidence.clone())
            .unwrap_or_else(|| {
                Readiness::Unknown("Codex authentication availability is unknown".into())
            })
    }

    async fn claude_readiness(&self) -> Readiness {
        if !self.claude_settings.enabled {
            return Readiness::Unavailable("Claude is turned off on this gateway".into());
        }
        if let Err(error) =
            crate::providers::claude::auth::validate_claude_path(&self.claude_settings.claude_path)
        {
            return Readiness::Unavailable(error.to_string());
        }
        if self.claude_agent().is_none() {
            return Readiness::Unknown("Claude supervisor is starting".into());
        }
        match self.claude_auth.cached_snapshot().await {
            Some(snapshot) => match snapshot.error {
                Some(reason) => Readiness::Unavailable(reason),
                None => Readiness::Ready,
            },
            None => Readiness::Unknown("Claude authentication availability is unknown".into()),
        }
    }

    pub(super) async fn claude_first_party_available(&self) -> Result<bool, RpcError> {
        self.claude_readiness().await.available()
    }

    pub(super) async fn codex_first_party_available(&self) -> Result<bool, RpcError> {
        self.refresh_native_readiness().await;
        self.refresh_provider_health().await;
        self.codex_readiness().await.available()
    }

    async fn refresh_native_readiness(&self) {
        if self.external_auth.is_some()
            || !matches!(self.codex_control().await, CodexControl::Ready)
        {
            return;
        }
        let _refresh = self.provider_health.native_refresh.lock().await;
        if !matches!(self.codex_control().await, CodexControl::Ready) {
            return;
        }
        let Some(generation) = self.control.current() else {
            return;
        };
        let evidence = match self
            .call_control_unadmitted("account/read", json!({"refreshToken": false}))
            .await
        {
            Ok(account) => match account.get("requiresOpenaiAuth").and_then(Value::as_bool) {
                Some(false) => Readiness::Ready,
                Some(true) => match account.get("account") {
                    Some(Value::Null) => Readiness::Unavailable("Codex is not signed in".into()),
                    Some(account) if account.is_object() => Readiness::Ready,
                    _ => Readiness::Unknown("Codex authentication availability is unknown".into()),
                },
                None => Readiness::Unknown("Codex authentication availability is unknown".into()),
            },
            Err(error) => Readiness::Unknown(format!(
                "Codex authentication availability could not be checked: {error:#}"
            )),
        };
        if self.require_auth_generation(&generation).is_ok() {
            *self
                .provider_health
                .native
                .lock()
                .expect("native readiness poisoned") = Some(NativeReadiness {
                generation: Arc::downgrade(&generation),
                evidence,
            });
        }
    }

    pub(super) fn spawn_native_readiness_refresh(
        self: &Arc<Self>,
        generation: &Arc<ControlGeneration>,
    ) {
        if self.external_auth.is_some() {
            return;
        }
        let gateway = Arc::clone(self);
        generation.spawn("native provider readiness", async move {
            loop {
                gateway.refresh_native_readiness().await;
                gateway.refresh_provider_health().await;
                tokio::time::sleep(Duration::from_secs(30)).await;
            }
        });
    }

    pub(super) async fn refresh_provider_health(&self) {
        let _refresh = self.provider_health.refresh.lock().await;
        let codex_readiness = self.codex_readiness().await;
        let claude_readiness = self.claude_readiness().await;
        let control_ready = matches!(self.codex_control().await, CodexControl::Ready);
        let external = self
            .external_providers
            .as_deref()
            .and_then(ExternalProviders::fallback);
        let codex = match &codex_readiness {
            Readiness::Ready => CodexHealth::Ready,
            Readiness::Unknown(reason) => CodexHealth::Unavailable {
                reason: reason.clone(),
            },
            Readiness::Unavailable(reason) => {
                let fallback = match &claude_readiness {
                    Readiness::Ready => Some("claude"),
                    Readiness::Unavailable(_) if control_ready => external,
                    _ => None,
                };
                match fallback {
                    Some(fallback) => CodexHealth::Fallback {
                        reason: reason.clone(),
                        fallback: fallback.into(),
                    },
                    None => CodexHealth::Unavailable {
                        reason: reason.clone(),
                    },
                }
            }
        };
        let claude = Some(match claude_readiness {
            Readiness::Ready => ClaudeHealth::Ready,
            Readiness::Unknown(reason) => ClaudeHealth::Unavailable { reason },
            Readiness::Unavailable(reason) => {
                let fallback = match &codex_readiness {
                    Readiness::Ready => Some("codex"),
                    Readiness::Unavailable(_) if control_ready => external,
                    _ => None,
                };
                match fallback {
                    Some(fallback) => ClaudeHealth::Fallback {
                        reason,
                        fallback: fallback.into(),
                    },
                    None => ClaudeHealth::Unavailable { reason },
                }
            }
        });
        let health = ProviderHealth { codex, claude };
        let mut published = self
            .provider_health
            .published
            .lock()
            .expect("provider health poisoned");
        if *published == health {
            return;
        }
        info!(?health, "provider health changed");
        *published = health;
        let notification =
            json!({"method": PROVIDER_HEALTH_METHOD, "params": {"providers": &*published}});
        if let Err(error) = self.broadcast_json_or_drop(&notification, Source::Gateway) {
            warn!(%error, "failed to announce provider health");
        }
    }

    #[cfg(test)]
    pub(super) fn is_degraded(&self, client_id: u64) -> bool {
        self.provider_health
            .degraded_clients
            .lock()
            .expect("degraded clients poisoned")
            .contains(&client_id)
    }

    #[cfg(test)]
    pub(super) fn published_codex_health(&self) -> CodexHealth {
        self.provider_health
            .published
            .lock()
            .expect("provider health poisoned")
            .codex
            .clone()
    }

    pub(super) async fn codex_unavailable(&self) -> CodexUnavailable {
        let (reason, retryable) = match self.codex_control().await {
            CodexControl::Disconnected => (CODEX_NOT_RUNNING, true),
            CodexControl::Starting => (CODEX_STARTING, true),
            CodexControl::AwaitingSignIn => (CODEX_AWAITING_SIGN_IN, false),
            CodexControl::Ready => (CODEX_CONNECTION_FAILED, true),
        };
        CodexUnavailable {
            reason: reason.into(),
            retryable,
        }
    }

    pub(super) fn admit_client(&self, client: &ClientTx, degraded: bool, mut ready: Value) {
        let published = self
            .provider_health
            .published
            .lock()
            .expect("provider health poisoned");
        ready["providers"] = json!(&*published);
        let _ = self.send_json_or_drop(client, &json!({"method": "daemon/ready", "params": ready}));
        self.clients.insert(client.id, client.clone());
        if degraded {
            self.provider_health
                .degraded_clients
                .lock()
                .expect("degraded clients poisoned")
                .insert(client.id);
        }
    }

    pub(super) fn forget_degraded_client(&self, client_id: u64) {
        self.provider_health
            .degraded_clients
            .lock()
            .expect("degraded clients poisoned")
            .remove(&client_id);
    }

    pub(super) fn close_degraded_clients(&self) {
        let degraded = std::mem::take(
            &mut *self
                .provider_health
                .degraded_clients
                .lock()
                .expect("degraded clients poisoned"),
        );
        for client_id in degraded {
            self.close_for_codex(client_id);
        }
    }

    pub(super) async fn reconnect_once_codex_is_reachable(&self, client_id: u64) {
        let mut retry = CODEX_RECONNECT_FIRST_PROBE;
        loop {
            tokio::time::sleep(retry).await;
            retry = (retry * 2).min(CODEX_RECONNECT_PROBE_LIMIT);
            if self.codex.connect_ws().await.is_ok() {
                break;
            }
        }
        self.forget_degraded_client(client_id);
        self.close_for_codex(client_id);
        std::future::pending::<()>().await;
    }

    fn close_for_codex(&self, client_id: u64) {
        if let Some((_, client)) = self.clients.remove(&client_id) {
            let _ = self.deliver_or_drop(
                &client,
                ClientCommand::Close {
                    code: RESTARTING_CLOSE_CODE,
                    reason: CODEX_READY_CLOSE_REASON.into(),
                },
            );
        }
    }
}

#[cfg(test)]
mod tests;
