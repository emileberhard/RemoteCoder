use anyhow::Result;
use axum::Json;
use axum::extract::{FromRequestParts, State};
use axum::http::request::Parts;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde_json::json;
use tracing::warn;

use super::HttpState;

pub(crate) fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
}

pub(super) fn header_value<'a>(headers: &'a HeaderMap, name: &str) -> &'a str {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("")
}

fn is_authorized(headers: &HeaderMap, expected_token: &str) -> bool {
    bearer_token(headers).is_some_and(|token| {
        crate::auth::installation_credentials::operator_matches(token, expected_token)
    })
}

/// Extractors that decide who is calling from the request head. Handlers list
/// one before any body extractor, so an unauthenticated caller is refused
/// before its body is read.
pub(in crate::http) struct Authorized(pub(super) crate::auth::installation_credentials::Grant);

#[axum::async_trait]
impl FromRequestParts<HttpState> for Authorized {
    type Rejection = AuthorizationFailure;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &HttpState,
    ) -> Result<Self, Self::Rejection> {
        authorize(state, &parts.headers).await.map(Self)
    }
}

pub(in crate::http) struct Operator;

#[axum::async_trait]
impl FromRequestParts<HttpState> for Operator {
    type Rejection = Response;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &HttpState,
    ) -> Result<Self, Self::Rejection> {
        if is_authorized(&parts.headers, &state.auth_token) {
            return Ok(Self);
        }
        Err((
            StatusCode::FORBIDDEN,
            Json(json!({"error":"operator credential required for enrollment"})),
        )
            .into_response())
    }
}

pub(in crate::http) enum AuthorizationFailure {
    Unauthorized,
    Unavailable,
}

impl IntoResponse for AuthorizationFailure {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            Self::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            Self::Unavailable => (
                StatusCode::SERVICE_UNAVAILABLE,
                "credential storage unavailable",
            ),
        };
        (status, Json(json!({"error": message}))).into_response()
    }
}

pub(super) async fn authorize(
    state: &HttpState,
    headers: &HeaderMap,
) -> Result<crate::auth::installation_credentials::Grant, AuthorizationFailure> {
    let token = bearer_token(headers).ok_or(AuthorizationFailure::Unauthorized)?;
    match state
        .installation_credentials
        .authenticate(token, &state.auth_token)
        .await
    {
        Ok(Some(grant)) => Ok(grant),
        Ok(None) => Err(AuthorizationFailure::Unauthorized),
        Err(error) => {
            warn!(%error, "installation credential storage unavailable");
            Err(AuthorizationFailure::Unavailable)
        }
    }
}

pub(super) async fn enroll_credential(
    State(state): State<HttpState>,
    _: Operator,
    Json(request): Json<crate::auth::installation_credentials::Enrollment>,
) -> Response {
    match state
        .installation_credentials
        .enroll(request, &state.auth_token)
        .await
    {
        Ok(token) => (
            [(header::CACHE_CONTROL, "no-store")],
            Json(json!({"token": token})),
        )
            .into_response(),
        Err(error) => {
            warn!(%error, "installation enrollment failed");
            (
                StatusCode::CONFLICT,
                Json(json!({"error": error.to_string()})),
            )
                .into_response()
        }
    }
}
