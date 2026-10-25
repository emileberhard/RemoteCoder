use super::{ClientCommand, ClientTx, Gateway, RESTARTING_CLOSE_CODE};
use crate::observability::journal::Source;
use crate::providers::claude::auth::ClaudeAuthSnapshot;
use crate::providers::codex::external::ExternalProviders;
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::HashSet;
use tracing::{info, warn};

pub(super) const PROVIDER_HEALTH_METHOD: &str = "gateway/providerHealth";
const CODEX_NOT_RUNNING: &str = "Codex app-server is not running";
const CODEX_STARTING: &str = "Codex is starting";
const CODEX_SIGN_IN_FAILED: &str = "Codex subscription sign-in failed";
const CODEX_CONNECTION_FAILED: &str = "This connection could not reach Codex; reconnect";
const CODEX_READY_CLOSE_REASON: &str = "Codex is available; reconnect";

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
    Ready,
}

fn codex_health(
    control: CodexControl,
    subscription_failing: bool,
    fallback: Option<&str>,
) -> CodexHealth {
    let unavailable = |reason: &str| CodexHealth::Unavailable {
        reason: reason.to_owned(),
    };
    match (control, subscription_failing, fallback) {
        (CodexControl::Disconnected, ..) => unavailable(CODEX_NOT_RUNNING),
        (CodexControl::Starting, ..) => unavailable(CODEX_STARTING),
        (CodexControl::Ready, false, _) => CodexHealth::Ready,
        (CodexControl::Ready, true, Some(fallback)) => CodexHealth::Fallback {
            reason: CODEX_SIGN_IN_FAILED.to_owned(),
            fallback: fallback.to_owned(),
        },
        (CodexControl::Ready, true, None) => unavailable(CODEX_SIGN_IN_FAILED),
    }
}

fn claude_health(enabled: bool, snapshot: Option<&ClaudeAuthSnapshot>) -> Option<ClaudeHealth> {
    if !enabled {
        return Some(ClaudeHealth::Unavailable {
            reason: "Claude is turned off on this gateway".into(),
        });
    }
    Some(match &snapshot?.error {
        None => ClaudeHealth::Ready,
        Some(reason) => ClaudeHealth::Unavailable {
            reason: reason.clone(),
        },
    })
}

pub(super) struct ProviderHealthOwner {
    published: std::sync::Mutex<ProviderHealth>,
    refresh: tokio::sync::Mutex<()>,
    degraded_clients: std::sync::Mutex<HashSet<u64>>,
}

impl Default for ProviderHealthOwner {
    fn default() -> Self {
        Self {
            published: std::sync::Mutex::new(ProviderHealth {
                codex: codex_health(CodexControl::Disconnected, false, None),
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

    pub(super) async fn refresh_provider_health(&self) {
        let _refresh = self.provider_health.refresh.lock().await;
        let control = if self.codex_ready().await {
            CodexControl::Ready
        } else if self.control.current().is_some() {
            CodexControl::Starting
        } else {
            CodexControl::Disconnected
        };
        let failing = self.codex_subscription_failing().await;
        let snapshot = self.claude_auth.cached_snapshot().await;
        let health = ProviderHealth {
            codex: codex_health(
                control,
                failing,
                self.external_providers
                    .as_deref()
                    .and_then(ExternalProviders::fallback),
            ),
            claude: claude_health(self.claude_settings.enabled, snapshot.as_ref()),
        };
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

    pub(super) fn published_codex_health(&self) -> CodexHealth {
        self.provider_health
            .published
            .lock()
            .expect("provider health poisoned")
            .codex
            .clone()
    }

    pub(super) fn codex_unavailable_reason(&self) -> String {
        match self.published_codex_health() {
            CodexHealth::Unavailable { reason } => reason,
            CodexHealth::Ready | CodexHealth::Fallback { .. } => CODEX_CONNECTION_FAILED.into(),
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
}

#[cfg(test)]
mod tests;
