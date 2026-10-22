use super::server::{HttpState, auth::Authorized};
use crate::accounts::{AccountsBusy, GatewayStopping, types::AccountId};
use crate::providers::router::{Router, RouterError};
use anyhow::Result;
use axum::{
    Json,
    extract::{Path, State},
    http::{StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::{Deserialize, Serialize};
use serde_json::json;

#[derive(Clone, Deserialize, Serialize)]
#[serde(try_from = "String", into = "String")]
struct RedemptionKey(String);

impl TryFrom<String> for RedemptionKey {
    type Error = anyhow::Error;
    fn try_from(value: String) -> Result<Self> {
        Ok(Self(AccountId::try_from(value)?.into()))
    }
}
impl From<RedemptionKey> for String {
    fn from(value: RedemptionKey) -> Self {
        value.0
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct CodexRedeem {
    reset_id: String,
    idempotency_key: RedemptionKey,
    generation: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ClaudeRedeem {
    account_id: String,
    reset_id: String,
    idempotency_key: RedemptionKey,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Redemption {
    outcome: Outcome,
    reason: Option<String>,
}

#[derive(Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all(serialize = "camelCase", deserialize = "snake_case"))]
enum Outcome {
    Reset,
    AlreadyRedeemed,
    NotNeeded,
    Refused,
}

async fn redeem(
    router: &Router,
    provider: &str,
    account_id: &str,
    reset_id: String,
    idempotency_key: RedemptionKey,
) -> Result<Redemption> {
    let value = router
        .redeem_reset(json!({
            "provider":provider,"account_id":account_id,"reset_id":reset_id,
            "idempotency_key":idempotency_key,
        }))
        .await
        .map_err(|error| {
            if matches!(
                error.downcast_ref::<RouterError>(),
                Some(RouterError::RequestFailed | RouterError::InvalidResponse)
            ) {
                anyhow::Error::new(RequestUnconfirmed)
            } else {
                error
            }
        })?;
    serde_json::from_value(value).map_err(|_| RequestUnconfirmed.into())
}

fn valid_reset_id(id: &str) -> bool {
    !id.trim().is_empty() && id.len() <= 4096 && !id.chars().any(char::is_control)
}

fn error(status: StatusCode, code: &str, message: &str) -> Response {
    (
        status,
        [(header::CACHE_CONTROL, "no-store")],
        Json(json!({"error":{"code":code,"message":message}})),
    )
        .into_response()
}

#[derive(Debug)]
struct RequestUnconfirmed;
impl std::fmt::Display for RequestUnconfirmed {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("llm-router did not confirm the reset outcome")
    }
}
impl std::error::Error for RequestUnconfirmed {}

fn unconfirmed(failure: &anyhow::Error) -> bool {
    failure.is::<RequestUnconfirmed>()
        || matches!(failure.downcast_ref::<RouterError>(),
        Some(RouterError::Refused { status, .. }) if !(400..500).contains(status) && *status != 503)
}

fn refresh_required(result: &Result<Redemption>) -> bool {
    result
        .as_ref()
        .is_ok_and(|result| result.outcome != Outcome::Refused)
        || result.as_ref().is_err_and(unconfirmed)
}

fn response(result: Result<Redemption>) -> Response {
    match result {
        Ok(result) => ([(header::CACHE_CONTROL, "no-store")], Json(result)).into_response(),
        Err(failure) if unconfirmed(&failure) => error(
            StatusCode::GATEWAY_TIMEOUT,
            "redeem_unconfirmed",
            "The reset outcome is unknown; retry this attempt with the same idempotency key",
        ),
        Err(failure) => {
            let (status, code) = match failure.downcast_ref::<RouterError>() {
                Some(RouterError::NotConfigured) => (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "account_management_unavailable",
                ),
                Some(RouterError::Refused { status: 409, code })
                    if code == "redeem_in_progress" || code == "redeem_unconfirmed_pending" =>
                {
                    (StatusCode::CONFLICT, code.as_str())
                }
                Some(RouterError::Refused { status: 404, code }) if code == "account_not_found" => {
                    (StatusCode::NOT_FOUND, "account_not_found")
                }
                Some(RouterError::Refused {
                    status: 401 | 403,
                    code,
                }) if code == "unauthorized" || code == "insufficient_scope" => {
                    (StatusCode::BAD_GATEWAY, "router_unauthorized")
                }
                Some(RouterError::Refused { status: 503, code })
                    if matches!(
                        code.as_str(),
                        "reset_credential_missing"
                            | "codex_credential_unavailable"
                            | "reset_credential_rejected"
                            | "reset_scope_insufficient"
                            | "reauthorization_required"
                            | "access_token_expired"
                            | "refresh_unconfirmed"
                            | "credential_storage_unavailable"
                            | "refresh_owner_unavailable"
                    ) =>
                {
                    (
                        StatusCode::SERVICE_UNAVAILABLE,
                        "reset_credential_unavailable",
                    )
                }
                Some(RouterError::Refused { status: 503, code })
                    if matches!(
                        code.as_str(),
                        "reset_state_unavailable"
                            | "account_store_unavailable"
                            | "upstream_unavailable"
                    ) =>
                {
                    (StatusCode::SERVICE_UNAVAILABLE, "router_retry_later")
                }
                Some(RouterError::Refused { status: 503, code }) if code == "router_stopping" => {
                    (StatusCode::SERVICE_UNAVAILABLE, "router_stopping")
                }
                Some(RouterError::TransportUnavailable) => {
                    (StatusCode::SERVICE_UNAVAILABLE, "router_unavailable")
                }
                Some(RouterError::KeyUnavailable) => {
                    (StatusCode::SERVICE_UNAVAILABLE, "router_key_unavailable")
                }
                Some(RouterError::Refused { status: 400, code }) if code == "invalid_request" => {
                    (StatusCode::BAD_REQUEST, "invalid_request")
                }
                _ if failure.is::<crate::accounts::resets::ResetAccountNotFound>() => {
                    (StatusCode::NOT_FOUND, "account_not_found")
                }
                _ if failure.is::<crate::accounts::resets::ResetAccountChanged>() => {
                    (StatusCode::CONFLICT, "reset_account_changed")
                }
                _ if failure.is::<AccountsBusy>() => {
                    (StatusCode::TOO_MANY_REQUESTS, "accounts_busy")
                }
                _ if failure.is::<GatewayStopping>() => {
                    (StatusCode::SERVICE_UNAVAILABLE, "gateway_stopping")
                }
                _ => (StatusCode::BAD_GATEWAY, "router_request_refused"),
            };
            error(status, code, &failure.to_string())
        }
    }
}

pub(super) async fn codex(
    State(state): State<HttpState>,
    _: Authorized,
    Path(account_id): Path<String>,
    Json(request): Json<CodexRedeem>,
) -> Response {
    if !valid_reset_id(&request.reset_id) {
        return error(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "Choose a valid reset id",
        );
    }
    let Some(accounts) = state.accounts else {
        return error(
            StatusCode::SERVICE_UNAVAILABLE,
            "account_management_unavailable",
            "Account management is unavailable on this gateway",
        );
    };
    let (sender, receiver) = tokio::sync::oneshot::channel();
    let admission = state.gateway.spawn_account_reset(move |_| async move {
        let result = async {
            let router_account = accounts
                .router_account_for_reset(&account_id, request.generation)
                .await?;
            let result = redeem(
                &state.router,
                "codex",
                &router_account.router_account_id,
                request.reset_id,
                request.idempotency_key,
            )
            .await;
            if refresh_required(&result) {
                accounts.refresh_reset_account(router_account.key.clone());
            }
            result
        }
        .await;
        let _ = sender.send(result);
        Ok(())
    });
    if let Err(error) = admission {
        return response(Err(error));
    }
    response(
        receiver
            .await
            .unwrap_or_else(|_| Err(RequestUnconfirmed.into())),
    )
}

pub(super) async fn claude(
    State(state): State<HttpState>,
    _: Authorized,
    Json(request): Json<ClaudeRedeem>,
) -> Response {
    if !super::claude_accounts::valid_id(&request.account_id) || !valid_reset_id(&request.reset_id)
    {
        return error(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "Choose a valid Claude account and reset id",
        );
    }
    let (sender, receiver) = tokio::sync::oneshot::channel();
    let admission = state
        .gateway
        .spawn_account_reset(move |shutdown| async move {
            let result = redeem(
                &state.router,
                "claude",
                &request.account_id,
                request.reset_id,
                request.idempotency_key,
            )
            .await;
            let refresh = refresh_required(&result);
            let _ = sender.send(result);
            if refresh {
                let result = shutdown
                    .run_until_cancelled(state.router.post("claude/accounts/refresh", json!({})))
                    .await;
                if matches!(result, Some(Err(_))) {
                    tracing::warn!("Claude account refresh after reset failed");
                }
            }
            Ok(())
        });
    if let Err(error) = admission {
        return response(Err(error));
    }
    response(
        receiver
            .await
            .unwrap_or_else(|_| Err(RequestUnconfirmed.into())),
    )
}

#[cfg(test)]
mod tests;
