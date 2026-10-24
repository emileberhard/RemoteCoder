use std::time::Duration;

use anyhow::Result;
use axum::Json;
use axum::body::Bytes;
use axum::extract::ws::{Message, WebSocketUpgrade};
use axum::extract::{FromRequestParts, Query, State};
use axum::http::request::Parts;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use serde::Deserialize;
use serde_json::json;
use tracing::{info, warn};

use crate::accounts::GatewayStopping;
use crate::navigation::EncryptedNavigationEventRequest;
use crate::observability::app_logs::{AppLogError, warn_rejected};
use crate::providers::codex::daemon::MAX_WEBSOCKET_BYTES;

use super::HttpState;
use super::auth::{Authorized, bearer_token, header_value};

pub(super) const DEVICE_HEADER: &str = "x-remotecoder-device";

pub(super) const SEGMENT_HEADER: &str = "x-remotecoder-segment";

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct RuntimeQuery {
    account_id: Option<crate::accounts::types::AccountId>,
    account_generation: Option<u64>,
}

pub(super) async fn version(_: Authorized) -> Json<&'static crate::build_identity::BuildIdentity> {
    Json(&crate::build_identity::IDENTITY)
}

pub(super) async fn health(State(state): State<HttpState>, _: Authorized) -> Response {
    match state.gateway.daemon_ready().await {
        Ok(ready) => {
            let (active_turn_count, active_turn_inventory_available) =
                state.gateway.reported_active_turn_status().await;
            (
                StatusCode::OK,
                Json(json!({
                "status": "ok",
                "codexPid": ready.codex_pid,
                "codexVersion": state.codex_version,
                "codexCodeModeHostPath": state.codex_code_mode_host_path,
                "startedAt": ready.started_at_unix_seconds,
                "draining": state.gateway.is_draining(),
                "activeTurnCount": active_turn_count,
                "activeTurnInventoryAvailable": active_turn_inventory_available,
                // Reported only. Claude health never changes "status" or removes
                // "codexPid": install-launchagent.zsh gates installs on that contract.
                "claude": state.gateway.claude_health().await,
                "lanEndpoint": state.lan_endpoint,
                "fullDiskAccess": state.full_disk_access,
                "features": {
                    "automations": crate::config::host_profile::AutomationAuthority::capability(),
                    "speech": {"available":state.router.configured(), "reason":if state.router.configured() { None } else { Some("routerNotConfigured") }},
                    "conversationReview": {"available":state.router.configured(), "reason":if state.router.configured() { None } else { Some("routerNotConfigured") }},
                    "routerAccounts": {"available":state.router.configured(), "reason":if state.router.configured() { None } else { Some("routerNotConfigured") }},
                },
                })),
            )
                .into_response()
        }
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status":"error","message":"codex unavailable"})),
        )
            .into_response(),
    }
}

pub(super) async fn diagnostics(State(state): State<HttpState>, _: Authorized) -> Response {
    match state.gateway.daemon_ready().await {
        Ok(ready) => match state.gateway.daemon_diagnostics().await {
            Ok(codex_diagnostics) => (
                StatusCode::OK,
                Json(json!({
                    "codexPid": ready.codex_pid,
                    "codexDiagnostics": codex_diagnostics,
                })),
            )
                .into_response(),
            Err(error) => {
                warn!(%error, "failed to read app-server resource diagnostics");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status":"error","message":"codex diagnostics unavailable"})),
                )
                    .into_response()
            }
        },
        Err(error) => {
            warn!(%error, "app-server is unavailable for resource diagnostics");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"status":"error","message":"codex unavailable"})),
            )
                .into_response()
        }
    }
}

pub(super) async fn ws(
    ws: WebSocketUpgrade,
    State(state): State<HttpState>,
    Authorized(grant): Authorized,
    Query(query): Query<RuntimeQuery>,
) -> Response {
    let gateway = match query.account_id {
        None => state.gateway.clone(),
        Some(id) => {
            let Some(accounts) = &state.accounts else {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Account management is unavailable",
                )
                    .into_response();
            };
            match accounts
                .gateway_for_account(&id, query.account_generation)
                .await
            {
                Ok(gateway) => {
                    info!(account_id = id.as_str(), account_generation = ?query.account_generation, "Retired account redirect");
                    gateway
                }
                Err(error) if error.is::<GatewayStopping>() => {
                    return ws
                        .on_upgrade(|mut socket| async move {
                            let close = crate::gateway::restarting_close();
                            let _ = socket.send(Message::Close(Some(close))).await;
                        })
                        .into_response();
                }
                Err(error) => {
                    return (
                        StatusCode::CONFLICT,
                        Json(json!({"error":error.to_string()})),
                    )
                        .into_response();
                }
            }
        }
    };
    ws.max_message_size(MAX_WEBSOCKET_BYTES)
        .max_frame_size(MAX_WEBSOCKET_BYTES)
        .on_upgrade(move |socket| async move {
            let cancelled = tokio_util::sync::CancellationToken::new();
            let connection = gateway.handle_ws(socket, cancelled.clone(), grant.clone());
            tokio::pin!(connection);
            if matches!(
                grant,
                crate::auth::installation_credentials::Grant::Operator
            ) {
                connection.await;
                return;
            }
            loop {
                tokio::select! {
                    _ = &mut connection => return,
                    _ = tokio::time::sleep(Duration::from_secs(5)) => {},
                }
                match state.installation_credentials.is_valid(&grant).await {
                    Ok(true) => {}
                    result => {
                        if let Err(error) = result {
                            warn!(%error, "credential lease unavailable");
                        }
                        cancelled.cancel();
                        connection.await;
                        return;
                    }
                }
            }
        })
        .into_response()
}

/// Receives one gzipped JSONL log segment from an app client and stores it
/// verbatim. Bearer-authed exactly like `/health` and `/ws`.
pub(super) async fn app_logs(
    State(state): State<HttpState>,
    _: Authorized,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let device = header_value(&headers, DEVICE_HEADER);
    let segment = header_value(&headers, SEGMENT_HEADER);
    // The store does synchronous filesystem work (directory sweep + a write
    // of up to 16 MB); keep it off the async workers shared with /ws.
    let stored = {
        let app_logs = state.app_logs.clone();
        let device = device.to_string();
        let segment = segment.to_string();
        tokio::task::spawn_blocking(move || app_logs.store(&device, &segment, &body)).await
    };
    let Ok(result) = stored else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": "storage task failed" })),
        )
            .into_response();
    };
    match result {
        Ok(stored) => {
            if let Some(eviction) = &stored.cap_eviction {
                state.journal.app_logs("cap_evicted", eviction.fields());
            }
            (
                StatusCode::OK,
                Json(json!({ "stored": stored.path.file_name().and_then(|name| name.to_str()) })),
            )
                .into_response()
        }
        Err(error) => {
            warn_rejected(device, &error);
            let status = match error {
                AppLogError::Io(_) => StatusCode::INTERNAL_SERVER_ERROR,
                _ => StatusCode::BAD_REQUEST,
            };
            (status, Json(json!({ "error": error.message() }))).into_response()
        }
    }
}

pub(super) async fn navigation_events(
    State(state): State<HttpState>,
    NavigationToken(token): NavigationToken,
    Json(request): Json<EncryptedNavigationEventRequest>,
) -> Response {
    match state.gateway.navigation().ingest(&token, request).await {
        Ok(response) => (StatusCode::OK, Json(json!(response))).into_response(),
        Err(error) => {
            let message = error.to_string();
            let status = if error.is::<crate::navigation::InvalidNavigationUploadToken>() {
                StatusCode::UNAUTHORIZED
            } else {
                StatusCode::BAD_REQUEST
            };
            warn!(%error, "navigation event rejected");
            (status, Json(json!({ "error": message }))).into_response()
        }
    }
}

/// Only the token's presence is checked here; the navigation owner decides
/// whether it is valid once it has the request it belongs to.
pub(super) struct NavigationToken(String);

#[axum::async_trait]
impl FromRequestParts<HttpState> for NavigationToken {
    type Rejection = Response;

    async fn from_request_parts(parts: &mut Parts, _: &HttpState) -> Result<Self, Self::Rejection> {
        bearer_token(&parts.headers)
            .map(|token| Self(token.to_owned()))
            .ok_or_else(|| {
                (
                    StatusCode::UNAUTHORIZED,
                    Json(json!({ "error": "missing navigation upload token" })),
                )
                    .into_response()
            })
    }
}
