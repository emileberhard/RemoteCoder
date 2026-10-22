use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

pub(crate) const REFRESH_METHOD: &str = "account/chatgptAuthTokens/refresh";
use super::super::router::Router as Transport;
use std::sync::Arc;

pub(crate) struct Router {
    transport: Arc<Transport>,
}

impl Router {
    pub(crate) fn new(transport: Arc<Transport>) -> Self {
        Self { transport }
    }

    #[cfg(test)]
    pub(crate) fn for_test(config: super::super::router::RouterConfig) -> Arc<Self> {
        Arc::new(Self::new(Arc::new(Transport::new(Some(config)).unwrap())))
    }
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Token {
    pub access_token: String,
    pub account_id: String,
    pub plan_type: String,
    pub expires_at: String,
    pub generation: String,
}

impl Token {
    pub(crate) fn expiry(&self) -> Result<i64> {
        Ok(OffsetDateTime::parse(&self.expires_at, &Rfc3339)
            .context("Codex router token expiry is invalid")?
            .unix_timestamp())
    }

    fn validate(&self, expected: &str) -> Result<()> {
        ensure!(
            self.account_id == expected,
            "Codex router returned a different account"
        );
        ensure!(
            self.generation == format!("{:x}", Sha256::digest(self.access_token.as_bytes())),
            "Codex router token generation is invalid"
        );
        let payload = self
            .access_token
            .split('.')
            .nth(1)
            .context("Codex router bearer is invalid")?;
        let bytes = URL_SAFE_NO_PAD
            .decode(payload)
            .context("Codex router bearer is invalid")?;
        let claims: Value =
            serde_json::from_slice(&bytes).context("Codex router bearer claims are invalid")?;
        ensure!(
            claims["https://api.openai.com/auth"]["chatgpt_account_id"] == expected,
            "Codex router bearer belongs to a different account"
        );
        let expiry = self.expiry()?;
        ensure!(
            expiry - OffsetDateTime::now_utc().unix_timestamp() >= 20 * 60
                && claims["exp"].as_i64().is_some_and(|value| value >= expiry),
            "Codex router token has insufficient lifetime"
        );
        ensure!(
            !self.plan_type.is_empty(),
            "Codex router omitted the account plan"
        );
        Ok(())
    }

    pub(crate) fn login_params(&self) -> Value {
        json!({"type":"chatgptAuthTokens", "accessToken":self.access_token,
            "chatgptAccountId":self.account_id, "chatgptPlanType":self.plan_type})
    }

    pub(crate) fn refresh_result(&self) -> Value {
        json!({"accessToken":self.access_token, "chatgptAccountId":self.account_id,
            "chatgptPlanType":self.plan_type})
    }
}

pub(crate) struct Quota {
    pub rate_limits: Value,
    pub resets: Option<crate::accounts::resets::ResetSnapshot>,
}

impl Router {
    pub(crate) async fn issue(&self, account: &str) -> Result<Token> {
        self.token("codex/token", json!({"account_id":account}), account)
            .await
    }

    pub(crate) async fn renew(&self, account: &str, rejected: &str) -> Result<Token> {
        let token = self
            .token(
                "codex/renew",
                json!({"account_id":account,"generation":rejected}),
                account,
            )
            .await?;
        ensure!(
            token.generation != rejected,
            "Codex router returned the rejected token generation"
        );
        Ok(token)
    }

    async fn token(&self, path: &str, body: Value, account: &str) -> Result<Token> {
        let token: Token = serde_json::from_value(self.transport.post(path, body).await?)
            .context("Codex router token response is invalid")?;
        token.validate(account)?;
        Ok(token)
    }

    pub(crate) async fn quota(&self, account: &str) -> Result<Quota> {
        let result = self
            .transport
            .post("codex/quota", json!({"account_id":account}))
            .await?;
        ensure!(
            result["account_id"] == account,
            "Codex router quota belongs to a different account"
        );
        let limits = result
            .get("rate_limits")
            .context("Codex router quota is unavailable")?;
        ensure!(
            limits["accountId"] == account,
            "Codex router quota identity is unavailable or changed"
        );
        Ok(Quota {
            rate_limits: limits.clone(),
            resets: crate::accounts::resets::from_router(result.get("resets").cloned()),
        })
    }
}
