use super::Gateway;
use super::control::ControlGeneration;
use crate::providers::codex::router::{REFRESH_METHOD, Router, Token};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;

pub(crate) struct ExternalAuth {
    pub(super) router: Arc<Router>,
    pub(super) account_id: String,
}

impl ExternalAuth {
    pub(crate) fn new(router: Arc<Router>, account_id: String) -> Self {
        Self { router, account_id }
    }
}

#[derive(Default)]
pub(super) struct InstalledAuth {
    pub(super) token: Option<Token>,
    pub(super) error: Option<String>,
    pub(super) holds_recovery: bool,
}

const RECOVERY_SIGN_IN_WAIT: Duration = Duration::from_secs(120);
const RECOVERY_SIGN_IN_RETRY: Duration = Duration::from_secs(5);

impl Gateway {
    pub(super) fn require_auth_generation(
        &self,
        generation: &Arc<ControlGeneration>,
    ) -> Result<()> {
        ensure!(
            self.control
                .current()
                .is_some_and(|current| Arc::ptr_eq(&current, generation)),
            "Codex authentication connection was replaced"
        );
        Ok(())
    }

    pub(super) async fn authenticate_external(
        &self,
        generation: &Arc<ControlGeneration>,
    ) -> Result<()> {
        let Some(auth) = &self.external_auth else {
            return Ok(());
        };
        let result: Result<()> = async {
            let _change = generation.auth_change.lock().await;
            self.require_auth_generation(generation)?;
            let token = auth.router.issue(&auth.account_id).await?;
            self.install_external_token(generation, &token).await?;
            let mut installed = generation.auth.lock().expect("Codex auth state poisoned");
            installed.token = Some(token);
            installed.error = None;
            Ok(())
        }
        .await;
        if let Err(error) = &result
            && self.require_auth_generation(generation).is_ok()
        {
            generation
                .auth
                .lock()
                .expect("Codex auth state poisoned")
                .error = Some(error.to_string());
        }
        self.refresh_provider_health().await;
        result
    }

    pub(super) async fn sign_in_before_recovery(
        &self,
        generation: &Arc<ControlGeneration>,
    ) -> Result<()> {
        let Err(error) = self.authenticate_external(generation).await else {
            return Ok(());
        };
        self.require_auth_generation(generation)?;
        if !self.codex_recovery_pending().await {
            tracing::warn!(%error, "Codex subscription sign-in failed; Codex starts without it");
            return Ok(());
        }
        tracing::warn!(%error, "Codex subscription sign-in failed; interrupted Codex work waits for it");
        generation
            .auth
            .lock()
            .expect("Codex auth state poisoned")
            .holds_recovery = true;
        self.refresh_provider_health().await;
        let deadline = tokio::time::Instant::now() + RECOVERY_SIGN_IN_WAIT;
        loop {
            tokio::time::sleep(RECOVERY_SIGN_IN_RETRY).await;
            if self.authenticate_external(generation).await.is_ok() {
                break;
            }
            self.require_auth_generation(generation)?;
            if tokio::time::Instant::now() >= deadline {
                tracing::warn!(
                    "Codex subscription sign-in is still failing; resuming interrupted Codex work without it"
                );
                break;
            }
        }
        generation
            .auth
            .lock()
            .expect("Codex auth state poisoned")
            .holds_recovery = false;
        self.refresh_provider_health().await;
        Ok(())
    }

    async fn install_external_token(
        &self,
        generation: &Arc<ControlGeneration>,
        token: &Token,
    ) -> Result<()> {
        self.require_auth_generation(generation)?;
        self.call_control_with_timeout(
            "account/login/start",
            token.login_params(),
            Duration::from_secs(3),
        )
        .await
        .map_err(|_| anyhow::anyhow!("Codex external token login failed"))?;
        self.require_auth_generation(generation)?;
        Ok(())
    }

    pub(super) fn spawn_external_renewal(self: &Arc<Self>, generation: &Arc<ControlGeneration>) {
        if self.external_auth.is_none() {
            return;
        }
        let gateway = Arc::clone(self);
        let owner = Arc::clone(generation);
        generation.spawn("Codex proactive authentication", async move {
            loop {
                let wait = {
                    let installed = owner.auth.lock().expect("Codex auth state poisoned");
                    match (&installed.token, &installed.error) {
                        (Some(token), None) => Duration::from_secs(
                            (token.expiry()?
                                - time::OffsetDateTime::now_utc().unix_timestamp()
                                - 15 * 60)
                                .max(1) as u64,
                        ),
                        _ => Duration::from_secs(30),
                    }
                };
                tokio::select! {
                    _ = tokio::time::sleep(wait) => {},
                    _ = owner.auth_changed.notified() => continue,
                }
                if let Err(error) = gateway.authenticate_external(&owner).await {
                    gateway.require_auth_generation(&owner)?;
                    tracing::warn!(%error, "Codex proactive router renewal is unavailable");
                }
            }
        });
    }

    pub(super) async fn handle_external_refresh(self: &Arc<Self>, message: &Value) -> bool {
        if self.external_auth.is_none() || message["method"] != REFRESH_METHOD {
            return false;
        }
        let Some(id) = message
            .get("id")
            .filter(|id| id.is_string() || id.is_number())
            .cloned()
        else {
            return true;
        };
        let Some(generation) = self.control.current() else {
            return true;
        };
        let permit = Arc::clone(&generation.auth_refresh_slots).try_acquire_owned();
        let previous = message["params"]["previousAccountId"]
            .as_str()
            .map(str::to_owned);
        let rejected = generation
            .auth
            .lock()
            .expect("Codex auth state poisoned")
            .token
            .as_ref()
            .map(|token| token.generation.clone());
        let gateway = Arc::clone(self);
        let owner = Arc::clone(&generation);
        generation.spawn("Codex reactive authentication", async move {
            let result = tokio::time::timeout(Duration::from_millis(6500), async {
                let _permit = permit.context("Codex refresh callback capacity reached")?;
                gateway
                    .refresh_external(&owner, previous.as_deref(), rejected.as_deref())
                    .await
            })
            .await;
            gateway.require_auth_generation(&owner)?;
            let reply = match result {
                Ok(Ok(token)) => json!({"jsonrpc":"2.0","id":id,"result":token.refresh_result()}),
                failure => {
                    let error = match failure {
                        Ok(Err(error)) => error.to_string(),
                        _ => "Codex router refresh timed out".to_owned(),
                    };
                    owner.auth.lock().expect("Codex auth state poisoned").error =
                        Some(error.clone());
                    tracing::warn!(%error, "Codex reactive router renewal failed");
                    json!({"jsonrpc":"2.0","id":id,"error":{"code":-32603,"message":error}})
                }
            };
            let sent = tokio::time::timeout(
                Duration::from_millis(500),
                owner.out_tx.send(reply.to_string()),
            )
            .await
            .context("Codex refresh reply queue timed out")
            .and_then(|sent| sent.context("Codex refresh reply connection closed"));
            if sent.is_err() {
                owner.auth.lock().expect("Codex auth state poisoned").error =
                    Some("Codex refresh reply failed; login must be restored".into());
            }
            owner.auth_changed.notify_one();
            sent
        });
        true
    }

    pub(super) fn handle_external_account_update(self: &Arc<Self>, message: &Value) {
        if self.external_auth.is_none()
            || message["method"] != "account/updated"
            || message["params"]["authMode"] == "chatgptAuthTokens"
        {
            return;
        }
        let Some(generation) = self.control.current() else {
            return;
        };
        generation
            .auth
            .lock()
            .expect("Codex auth state poisoned")
            .error = Some(
            "Codex authentication changed outside RemoteCoder; reinstalling llm-router tokens"
                .into(),
        );
        let gateway = Arc::clone(self);
        let owner = Arc::clone(&generation);
        generation.spawn("Codex external re-authentication", async move {
            if let Err(error) = gateway.authenticate_external(&owner).await {
                gateway.require_auth_generation(&owner)?;
                tracing::warn!(%error, "Codex external re-authentication is unavailable");
            }
            owner.auth_changed.notify_one();
            Ok(())
        });
    }

    async fn refresh_external(
        &self,
        generation: &Arc<ControlGeneration>,
        previous: Option<&str>,
        rejected: Option<&str>,
    ) -> Result<Token> {
        let auth = self
            .external_auth
            .as_ref()
            .context("Codex external auth has no router owner")?;
        ensure!(
            previous == Some(auth.account_id.as_str()),
            "Codex refresh requested a different account"
        );
        let _change = generation.auth_change.lock().await;
        self.require_auth_generation(generation)?;
        let current = generation
            .auth
            .lock()
            .expect("Codex auth state poisoned")
            .token
            .clone()
            .context("Codex external auth was not installed")?;
        let rejected = rejected.context("Codex refresh has no installed token generation")?;
        if current.generation != rejected {
            return Ok(current.clone());
        }
        let token = auth.router.renew(&auth.account_id, rejected).await?;
        self.require_auth_generation(generation)?;
        self.install_external_token(generation, &token).await?;
        let mut installed = generation.auth.lock().expect("Codex auth state poisoned");
        installed.token = Some(token.clone());
        installed.error = None;
        Ok(token)
    }

    pub(super) async fn require_external_auth(&self) -> Result<()> {
        if self.external_auth.is_none() {
            return Ok(());
        }
        let generation = self
            .control
            .current()
            .context("Codex authentication is unavailable")?;
        let installed = generation.auth.lock().expect("Codex auth state poisoned");
        let token = installed
            .token
            .as_ref()
            .context("Codex authentication is not ready")?;
        ensure!(
            token.expiry()? > time::OffsetDateTime::now_utc().unix_timestamp(),
            "Codex router token expired; renewal is unavailable"
        );
        self.require_auth_generation(&generation)
    }

    pub(crate) fn external_auth_error(&self) -> Option<String> {
        self.external_auth.as_ref()?;
        self.control.current().and_then(|owner| {
            owner
                .auth
                .lock()
                .expect("Codex auth state poisoned")
                .error
                .clone()
        })
    }
}

#[cfg(test)]
mod tests;

pub(super) fn blocked_consumer_auth(method: &str, params: &Value) -> bool {
    method.starts_with("account/login/")
        || matches!(
            method,
            "account/logout"
                | "loginChatGpt"
                | "loginApiKey"
                | "logoutChatGpt"
                | "cancelLoginChatGpt"
        )
        || (method == "getAuthStatus" && params["includeToken"] == true)
}
