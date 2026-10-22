use super::server::HttpState;
use super::server::auth::Authorized;
use crate::accounts::{Accounts, AccountsBusy, GatewayStopping};
use axum::{
    Json,
    extract::{Query, State},
    http::{StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;

const REFRESH_WAIT_BOUND: Duration = Duration::from_secs(30);

#[derive(Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum DirectoryWait {
    Refresh,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct DirectoryQuery {
    #[serde(default)]
    refresh: bool,
    wait: Option<DirectoryWait>,
}

fn service(state: &HttpState) -> Result<Arc<Accounts>, Box<Response>> {
    state.accounts.clone().ok_or_else(|| {
        Box::new(
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({"error":"Account management is unavailable on this gateway"})),
            )
                .into_response(),
        )
    })
}
fn result<T: serde::Serialize>(value: anyhow::Result<T>) -> Response {
    match value {
        Ok(value) => ([(header::CACHE_CONTROL, "no-store")], Json(value)).into_response(),
        Err(error) if error.is::<AccountsBusy>() => (
            StatusCode::TOO_MANY_REQUESTS,
            [
                (header::CACHE_CONTROL, "no-store"),
                (header::RETRY_AFTER, "1"),
            ],
            Json(json!({"error":error.to_string()})),
        )
            .into_response(),
        Err(error) if error.is::<GatewayStopping>() => (
            StatusCode::SERVICE_UNAVAILABLE,
            [(header::CACHE_CONTROL, "no-store")],
            Json(json!({"error":error.to_string()})),
        )
            .into_response(),
        Err(error) => (
            StatusCode::CONFLICT,
            [(header::CACHE_CONTROL, "no-store")],
            Json(json!({"error":error.to_string()})),
        )
            .into_response(),
    }
}

pub(super) async fn directory(
    State(state): State<HttpState>,
    _: Authorized,
    Query(query): Query<DirectoryQuery>,
) -> Response {
    match service(&state) {
        Ok(accounts) => {
            if query.refresh {
                accounts.start_refresh().await;
            }
            if query.wait == Some(DirectoryWait::Refresh) {
                accounts.refresh_settled(REFRESH_WAIT_BOUND).await;
            }
            result(Ok(accounts.directory().await))
        }
        Err(error) => *error,
    }
}
