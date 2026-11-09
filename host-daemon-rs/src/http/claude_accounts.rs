use super::server::{HttpState, auth::Authorized};
use crate::accounts::types::UsageWindow;
use crate::providers::router::RouterError;
use crate::time::parse_rfc3339_unix_seconds as timestamp;
use anyhow::{Result, ensure};
use axum::{
    Json,
    extract::State,
    http::{StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Deserialize)]
struct RouterInventory {
    accounts: Vec<RouterAccount>,
    claude: RouterChoice,
    codex: Option<RouterCodex>,
}
#[derive(Deserialize)]
struct RouterChoice {
    automatic: String,
    preference: Option<String>,
    route: Option<RouterRoute<ClaudeRoute>>,
}
#[derive(Deserialize)]
struct RouterCodex {
    route: Option<RouterRoute<CodexRoute>>,
}
#[derive(Deserialize)]
struct RouterRoute<Kind> {
    kind: Kind,
}
#[derive(Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
enum ClaudeRoute {
    Subscription,
    Openrouter,
    Copilot,
}
#[derive(Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
enum CodexRoute {
    Subscription,
    Copilot,
}
#[derive(Deserialize)]
#[serde(tag = "provider", rename_all = "lowercase")]
enum RouterAccount {
    Claude(Box<ClaudeAccount>),
    Copilot(Box<CopilotAccount>),
    #[serde(other)]
    Other,
}
#[derive(Deserialize)]
struct CopilotAccount {
    label: String,
    plan: String,
    availability: Availability,
    available_at: Option<String>,
    error: Option<String>,
    budget: Option<RouterBudget>,
}
#[derive(Deserialize)]
struct RouterBudget {
    limit_usd: f64,
    spent_usd: Option<f64>,
    remaining_usd: Option<f64>,
    resets_at: Option<String>,
}
#[derive(Deserialize)]
struct ClaudeAccount {
    id: String,
    label: String,
    plan: String,
    shared: bool,
    credential: Credential,
    availability: Availability,
    available_at: Option<String>,
    usage: Option<RouterUsage>,
    resets: Option<Value>,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum Credential {
    Ready,
    Rejected,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum Availability {
    Available,
    Cooling,
    Exhausted,
    Rejected,
    Unavailable,
}
#[derive(Deserialize)]
struct RouterUsage {
    observed_at: String,
    five_hour: Option<RouterWindow>,
    weekly: Option<RouterWindow>,
}
#[derive(Deserialize)]
struct RouterWindow {
    utilization: f64,
    resets_at: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Directory {
    automatic: String,
    preference: Option<String>,
    route: Option<ClaudeRoute>,
    codex_route: Option<CodexRoute>,
    copilot: Option<Copilot>,
    accounts: Vec<Account>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Copilot {
    label: String,
    plan: String,
    availability: Availability,
    available_at: Option<f64>,
    error: Option<String>,
    budget: Option<Budget>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Budget {
    limit_usd: f64,
    spent_usd: Option<f64>,
    remaining_usd: Option<f64>,
    resets_at: Option<f64>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Account {
    id: String,
    label: String,
    plan: String,
    shared: bool,
    credential: Credential,
    availability: Availability,
    available_at: Option<f64>,
    windows: Vec<UsageWindow>,
    observed_at: Option<f64>,
    resets: Option<crate::accounts::resets::ResetSnapshot>,
}
fn map_directory(value: Value) -> Result<Directory> {
    let inventory: RouterInventory = serde_json::from_value(value)?;
    let mut ids = std::collections::HashSet::new();
    let mut accounts = Vec::new();
    let mut copilot = None;
    for account in inventory.accounts {
        let account = match account {
            RouterAccount::Claude(account) => account,
            RouterAccount::Copilot(account) => {
                ensure!(copilot.is_none(), "Duplicate Copilot account");
                copilot = Some(map_copilot(*account)?);
                continue;
            }
            RouterAccount::Other => continue,
        };
        ensure!(
            valid_id(&account.id) && ids.insert(account.id.clone()),
            "Invalid Claude account identity"
        );
        let mut windows = Vec::new();
        let mut observed_at = None;
        if let Some(usage) = account.usage {
            observed_at = Some(timestamp(&usage.observed_at)?);
            for (id, label, duration, window) in [
                ("five-hour", "Five hours", 300, usage.five_hour),
                ("weekly", "Weekly", 10080, usage.weekly),
            ] {
                if let Some(window) = window {
                    ensure!(
                        window.utilization.is_finite() && window.utilization >= 0.0,
                        "Invalid Claude utilization"
                    );
                    windows.push(UsageWindow {
                        id: id.to_owned(),
                        label: label.to_owned(),
                        duration_minutes: Some(duration),
                        used_percent: (window.utilization * 100.0).min(100.0),
                        resets_at: Some(timestamp(&window.resets_at)?),
                        model: None,
                    });
                }
            }
        }
        accounts.push(Account {
            id: account.id,
            label: account.label,
            plan: account.plan,
            shared: account.shared,
            credential: account.credential,
            availability: account.availability,
            available_at: account.available_at.as_deref().map(timestamp).transpose()?,
            windows,
            observed_at,
            resets: crate::accounts::resets::from_router(account.resets),
        });
    }
    ensure!(
        !accounts.is_empty() && accounts.len() <= 128,
        "Invalid Claude account count"
    );
    ensure!(
        ids.contains(&inventory.claude.automatic)
            && inventory
                .claude
                .preference
                .as_ref()
                .is_none_or(|preference| ids.contains(preference)),
        "Unknown Claude account choice"
    );
    Ok(Directory {
        automatic: inventory.claude.automatic,
        preference: inventory.claude.preference,
        route: inventory.claude.route.map(|route| route.kind),
        codex_route: inventory
            .codex
            .and_then(|codex| codex.route)
            .map(|route| route.kind),
        copilot,
        accounts,
    })
}
fn map_copilot(account: CopilotAccount) -> Result<Copilot> {
    let budget = account
        .budget
        .map(|budget| {
            let amounts = [
                Some(budget.limit_usd),
                budget.spent_usd,
                budget.remaining_usd,
            ];
            ensure!(
                amounts
                    .into_iter()
                    .flatten()
                    .all(|amount| amount.is_finite() && amount >= 0.0),
                "Invalid Copilot budget"
            );
            Ok(Budget {
                limit_usd: budget.limit_usd,
                spent_usd: budget.spent_usd,
                remaining_usd: budget.remaining_usd,
                resets_at: budget.resets_at.as_deref().map(timestamp).transpose()?,
            })
        })
        .transpose()?;
    Ok(Copilot {
        label: account.label,
        plan: account.plan,
        availability: account.availability,
        available_at: account.available_at.as_deref().map(timestamp).transpose()?,
        error: account.error,
        budget,
    })
}
pub(super) fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id.as_bytes()[0].is_ascii_lowercase()
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}
fn error(status: StatusCode, code: &str, message: &str) -> Response {
    (
        status,
        [(header::CACHE_CONTROL, "no-store")],
        Json(json!({"error":{"code":code,"message":message}})),
    )
        .into_response()
}
fn response(result: Result<Value>) -> Response {
    match result {
        Ok(value) => match map_directory(value) {
            Ok(value) => ([(header::CACHE_CONTROL, "no-store")], Json(value)).into_response(),
            Err(_) => {
                tracing::warn!("Claude account router returned unmappable accounts");
                error(
                    StatusCode::BAD_GATEWAY,
                    "router_invalid_response",
                    "llm-router returned invalid Claude accounts; check gateway/router compatibility",
                )
            }
        },
        Err(failure) => {
            tracing::warn!(router_error = ?failure.downcast_ref::<RouterError>(), "Claude account router request failed");
            match failure.downcast_ref::<RouterError>() {
                Some(RouterError::Refused { status, code }) => match (*status, code.as_str()) {
                    (404, "account_not_found") => error(
                        StatusCode::NOT_FOUND,
                        "account_not_found",
                        "This Claude account no longer exists; reload the account list",
                    ),
                    (503, "preference_unavailable") => error(
                        StatusCode::SERVICE_UNAVAILABLE,
                        "preference_unavailable",
                        "llm-router could not save the preference; the previous preference remains in force; check its state storage",
                    ),
                    (503, _) => error(
                        StatusCode::SERVICE_UNAVAILABLE,
                        "router_unavailable",
                        &failure.to_string(),
                    ),
                    (403, "copilot_not_permitted") => error(
                        StatusCode::FORBIDDEN,
                        "copilot_not_permitted",
                        "This gateway's llm-router key may not use Copilot; its router policy needs copilot allowed",
                    ),
                    (401 | 403, _) => error(
                        StatusCode::BAD_GATEWAY,
                        "router_unauthorized",
                        &failure.to_string(),
                    ),
                    (400, _) => error(
                        StatusCode::BAD_GATEWAY,
                        "router_invalid_request",
                        "llm-router rejected the gateway request; check gateway/router compatibility",
                    ),
                    _ => error(
                        StatusCode::BAD_GATEWAY,
                        "router_request_refused",
                        &failure.to_string(),
                    ),
                },
                Some(RouterError::NotConfigured) => error(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "account_management_unavailable",
                    &failure.to_string(),
                ),
                Some(RouterError::KeyUnavailable) => error(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "router_key_unavailable",
                    &failure.to_string(),
                ),
                Some(RouterError::InvalidResponse) => error(
                    StatusCode::BAD_GATEWAY,
                    "router_invalid_response",
                    &failure.to_string(),
                ),
                _ => error(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "router_unavailable",
                    "The private llm-router listener is unavailable; check its connection",
                ),
            }
        }
    }
}
pub(super) async fn directory(State(state): State<HttpState>, _: Authorized) -> Response {
    response(state.router.get("accounts").await)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Preference {
    account: Value,
}
pub(super) async fn prefer(
    State(state): State<HttpState>,
    _: Authorized,
    Json(request): Json<Preference>,
) -> Response {
    let account = match request.account {
        Value::Null => Value::Null,
        Value::String(account) if valid_id(&account) => Value::String(account),
        _ => {
            return error(
                StatusCode::BAD_REQUEST,
                "invalid_request",
                "Choose a valid Claude account id or null for automatic",
            );
        }
    };
    response(
        state
            .router
            .put(
                "accounts/preference",
                json!({"provider":"claude","account":account}),
            )
            .await,
    )
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct CodexRouteChoice {
    route: Value,
}
pub(super) async fn route_codex(
    State(state): State<HttpState>,
    _: Authorized,
    Json(request): Json<CodexRouteChoice>,
) -> Response {
    let account = match request.route.as_str() {
        Some("subscription") => Value::Null,
        Some("copilot") => json!("copilot"),
        _ => {
            return error(
                StatusCode::BAD_REQUEST,
                "invalid_request",
                "Choose subscription or copilot for the Codex route",
            );
        }
    };
    response(
        state
            .router
            .put(
                "accounts/preference",
                json!({"provider":"codex","account":account}),
            )
            .await,
    )
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Refresh {}
pub(super) async fn refresh(
    State(state): State<HttpState>,
    _: Authorized,
    Json(_): Json<Refresh>,
) -> Response {
    response(state.router.post("accounts/refresh", json!({})).await)
}

#[cfg(test)]
mod tests;
