use super::server::{HttpState, auth::Authorized};
use crate::accounts::types::UsageWindow;
use crate::gateway::ConversationProviderChange;
use crate::providers::claude::valid_id;
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
    models: Option<Vec<RouterModelChoice>>,
    preference: Option<String>,
    route: Option<RouterRoute>,
    active_route: Option<RouterRoute>,
    route_options: Option<Vec<String>>,
}
#[derive(Deserialize)]
struct RouterModelChoice {
    model: String,
    automatic: Option<String>,
    available_at: Option<String>,
}
#[derive(Default, Deserialize)]
struct RouterCodex {
    route: Option<RouterRoute>,
    active_route: Option<RouterRoute>,
    route_options: Option<Vec<String>>,
}
#[derive(Deserialize)]
struct RouterRoute {
    kind: String,
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
    tier: Option<String>,
    shared: bool,
    credential: Credential,
    availability: Availability,
    available_at: Option<String>,
    usage: Option<RouterUsage>,
    resets: Option<Value>,
    #[serde(default)]
    models: Option<Vec<String>>,
    #[serde(default)]
    cyber_verified: bool,
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
    model_limits: Option<Value>,
}
#[derive(Deserialize)]
struct RouterWindow {
    utilization: f64,
    resets_at: String,
}
#[derive(Deserialize)]
struct RouterModelWindow {
    model: String,
    group: String,
    observed_at: String,
    #[serde(flatten)]
    window: RouterWindow,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Directory {
    automatic: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    models: Option<Vec<ModelChoice>>,
    preference: Option<String>,
    route: Option<String>,
    codex_route: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    claude_route_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    codex_route_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    claude_route_options: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    codex_route_options: Option<Vec<String>>,
    copilot: Option<Copilot>,
    accounts: Vec<Account>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ModelChoice {
    model: String,
    automatic: Option<String>,
    available_at: Option<f64>,
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
    tier: Option<String>,
    shared: bool,
    credential: Credential,
    availability: Availability,
    available_at: Option<f64>,
    windows: Vec<UsageWindow>,
    observed_at: Option<f64>,
    resets: Option<crate::accounts::resets::ResetSnapshot>,
    models: Option<Vec<String>>,
    cyber_verified: bool,
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
                    windows.push(usage_window(
                        id.to_owned(),
                        label.to_owned(),
                        Some(duration),
                        None,
                        &window,
                    )?);
                }
            }
            match model_windows(usage.model_limits) {
                Ok(model_windows) => windows.extend(model_windows),
                Err(_) => tracing::warn!(
                    account = %account.id,
                    "Claude model limits are unmappable; leaving them unknown"
                ),
            }
        }
        accounts.push(Account {
            id: account.id,
            label: account.label,
            plan: account.plan,
            tier: account.tier,
            shared: account.shared,
            credential: account.credential,
            availability: account.availability,
            available_at: account.available_at.as_deref().map(timestamp).transpose()?,
            windows,
            observed_at,
            resets: crate::accounts::resets::from_router(account.resets),
            models: account.models,
            cyber_verified: account.cyber_verified,
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
    let models = inventory
        .claude
        .models
        .map(|models| {
            let mut families = std::collections::HashSet::new();
            models
                .into_iter()
                .map(|choice| {
                    ensure!(
                        valid_id(&choice.model) && families.insert(choice.model.clone()),
                        "Invalid Claude model choice"
                    );
                    ensure!(
                        choice.automatic.as_ref().is_none_or(|id| ids.contains(id)),
                        "Unknown Claude model account choice"
                    );
                    ensure!(
                        choice.automatic.is_none() || choice.available_at.is_none(),
                        "Available Claude model has a return time"
                    );
                    Ok(ModelChoice {
                        model: choice.model,
                        automatic: choice.automatic,
                        available_at: choice.available_at.as_deref().map(timestamp).transpose()?,
                    })
                })
                .collect::<Result<Vec<_>>>()
        })
        .transpose()?;
    let RouterCodex {
        route,
        active_route,
        route_options,
    } = inventory.codex.unwrap_or_default();
    ensure!(
        inventory.claude.route.as_ref().is_none_or(|route| matches!(
            route.kind.as_str(),
            "subscription" | "copilot" | "openrouter"
        )),
        "Unknown legacy Claude route"
    );
    ensure!(
        route
            .as_ref()
            .is_none_or(|route| matches!(route.kind.as_str(), "subscription" | "copilot")),
        "Unknown legacy Codex route"
    );
    Ok(Directory {
        automatic: inventory.claude.automatic,
        models,
        preference: inventory.claude.preference,
        route: inventory.claude.route.map(|route| route.kind),
        codex_route: route.map(|route| route.kind),
        claude_route_id: inventory.claude.active_route.map(|route| route.kind),
        codex_route_id: active_route.map(|route| route.kind),
        claude_route_options: inventory.claude.route_options,
        codex_route_options: route_options,
        copilot,
        accounts,
    })
}
fn usage_window(
    id: String,
    label: String,
    duration_minutes: Option<i64>,
    model: Option<String>,
    window: &RouterWindow,
) -> Result<UsageWindow> {
    ensure!(
        window.utilization.is_finite() && window.utilization >= 0.0,
        "Invalid Claude utilization"
    );
    Ok(UsageWindow {
        id,
        label,
        duration_minutes,
        used_percent: (window.utilization * 100.0).min(100.0),
        resets_at: Some(timestamp(&window.resets_at)?),
        model,
        observed_at: None,
    })
}
fn model_windows(limits: Option<Value>) -> Result<Vec<UsageWindow>> {
    let Some(limits) = limits else {
        return Ok(Vec::new());
    };
    serde_json::from_value::<Vec<RouterModelWindow>>(limits)?
        .into_iter()
        .map(|limit| {
            ensure!(valid_id(&limit.model), "Invalid Claude model limit");
            let mut label = limit.model.clone();
            label[..1].make_ascii_uppercase();
            let duration = match limit.group.as_str() {
                "session" => Some(300),
                "weekly" => Some(10080),
                _ => None,
            };
            let mut window = usage_window(
                format!("{}-{}", limit.model, limit.group),
                format!("{label} {}", limit.group),
                duration,
                Some(limit.model),
                &limit.window,
            )?;
            window.observed_at = Some(timestamp(&limit.observed_at)?);
            Ok(window)
        })
        .collect()
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
                    (403, "route_not_available") => error(
                        StatusCode::FORBIDDEN,
                        "route_not_available",
                        "This route is unavailable for the configured llm-router key",
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

async fn thread_routes_path(state: &HttpState) -> String {
    if let Some(home) = state.gateway.codex_home()
        && let Ok(value) = tokio::fs::read_to_string(home.join("installation_id")).await
        && let Some(id) = crate::ids::parse_uuid(value.trim())
    {
        return format!(
            "accounts/thread-routes?installation={}",
            crate::ids::format_uuid(id)
        );
    }
    "accounts/thread-routes".into()
}

fn thread_routes_response(result: Result<Value>) -> Response {
    match result {
        Ok(value) => ([(header::CACHE_CONTROL, "no-store")], Json(value)).into_response(),
        Err(failure) => match failure.downcast_ref::<RouterError>() {
            Some(RouterError::Refused { status: 403, .. }) => error(
                StatusCode::FORBIDDEN,
                "route_not_available",
                "This provider is unavailable for this conversation",
            ),
            Some(RouterError::Refused { status: 404, .. }) => error(
                StatusCode::NOT_FOUND,
                "route_not_supported",
                "The inference router does not support conversation overrides",
            ),
            Some(RouterError::Refused { status: 409, .. }) => error(
                StatusCode::CONFLICT,
                "route_capacity_exhausted",
                "The inference router has reached its override limit. Clear an existing override to add another.",
            ),
            _ => error(
                StatusCode::SERVICE_UNAVAILABLE,
                "router_unavailable",
                "Conversation provider settings are unavailable",
            ),
        },
    }
}

pub(super) async fn thread_routes(State(state): State<HttpState>, _: Authorized) -> Response {
    thread_routes_response(state.router.get(&thread_routes_path(&state).await).await)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ThreadRoutePreference {
    thread_id: String,
    route: Value,
}

pub(super) async fn set_thread_route(
    State(state): State<HttpState>,
    _: Authorized,
    Json(request): Json<ThreadRoutePreference>,
) -> Response {
    let claude_id = crate::providers::claude::session_uuid_from_thread_id(&request.thread_id);
    let id = claude_id.unwrap_or(&request.thread_id);
    if !crate::ids::parse_uuid(id).is_some_and(|parsed| crate::ids::format_uuid(parsed) == id)
        || !(request.route.is_null() || request.route.as_str().is_some_and(valid_id))
    {
        return error(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "Choose a valid conversation and provider",
        );
    }
    let _lifecycle = if claude_id.is_some() {
        let Some(agent) = state.gateway.claude_agent() else {
            return error(
                StatusCode::SERVICE_UNAVAILABLE,
                "provider_unavailable",
                "Claude is unavailable on this gateway",
            );
        };
        Some(agent.lock_lifecycle(&request.thread_id).await)
    } else {
        None
    };
    match state
        .gateway
        .conversation_provider_change(&request.thread_id)
        .await
    {
        Ok(ConversationProviderChange::Allowed) => {}
        Ok(ConversationProviderChange::ExternalProvider) if request.route.is_null() => {}
        Ok(ConversationProviderChange::ExternalProvider) => {
            return error(
                StatusCode::FORBIDDEN,
                "route_not_supported",
                "This conversation uses a provider configured on its host",
            );
        }
        Ok(ConversationProviderChange::Busy) => {
            return error(
                StatusCode::CONFLICT,
                "conversation_busy",
                "Change the provider after the current turn finishes",
            );
        }
        Err(_) => {
            return error(
                StatusCode::SERVICE_UNAVAILABLE,
                "conversation_unavailable",
                "This gateway could not verify the conversation",
            );
        }
    }
    let path = thread_routes_path(&state).await;
    thread_routes_response(
        state
            .router
            .put(
                &path,
                json!({"thread_id":request.thread_id,"route":request.route}),
            )
            .await,
    )
}
#[derive(Deserialize)]
#[serde(untagged)]
pub(super) enum Preference {
    Account(AccountPreference),
    Route(RoutePreference),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct AccountPreference {
    account: Value,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct RoutePreference {
    route: String,
}
pub(super) async fn prefer(
    State(state): State<HttpState>,
    _: Authorized,
    Json(request): Json<Preference>,
) -> Response {
    let body = match request {
        Preference::Account(AccountPreference {
            account: Value::Null,
        }) => {
            json!({"provider":"claude","account":null})
        }
        Preference::Account(AccountPreference {
            account: Value::String(account),
        }) if valid_id(&account) => {
            json!({"provider":"claude","account":account})
        }
        Preference::Route(RoutePreference { route }) if valid_id(&route) => {
            json!({"provider":"claude","route":route})
        }
        _ => {
            return error(
                StatusCode::BAD_REQUEST,
                "invalid_request",
                "Choose a valid Claude account id, route, or null for automatic",
            );
        }
    };
    response(state.router.put("accounts/preference", body).await)
}

pub(super) async fn route_codex(
    State(state): State<HttpState>,
    _: Authorized,
    Json(request): Json<RoutePreference>,
) -> Response {
    let body = match request.route.as_str() {
        "subscription" => json!({"provider":"codex","account":null}),
        "copilot" => json!({"provider":"codex","account":"copilot"}),
        route if valid_id(route) => json!({"provider":"codex","route":route}),
        _ => {
            return error(
                StatusCode::BAD_REQUEST,
                "invalid_request",
                "Choose a valid Codex route",
            );
        }
    };
    response(state.router.put("accounts/preference", body).await)
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
