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
    MembershipRemoved(crate::cluster::members::MembershipRemoved),
}

impl IntoResponse for AuthorizationFailure {
    fn into_response(self) -> Response {
        match self {
            Self::MembershipRemoved(removed) => (
                StatusCode::FORBIDDEN,
                [
                    ("x-remotecoder-refusal", "membership_removed"),
                    ("x-remotecoder-peer-host", removed.host.as_str()),
                    ("x-remotecoder-membership", removed.membership.as_str()),
                ],
                Json(removed.data()),
            )
                .into_response(),
            Self::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                Json(json!({"error":"unauthorized"})),
            )
                .into_response(),
            Self::Unavailable => (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({"error":"credential storage unavailable"})),
            )
                .into_response(),
        }
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
        Err(error) => match error.downcast::<crate::cluster::members::MembershipRemoved>() {
            Ok(removed) => Err(AuthorizationFailure::MembershipRemoved(removed)),
            Err(error) => {
                warn!(%error, "installation credential storage unavailable");
                Err(AuthorizationFailure::Unavailable)
            }
        },
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::server::harness::{HOST, LanHarness, exchange};
    use crate::wire::cluster::{IssueParams, PROTOCOL, RemoveParams};
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;

    #[tokio::test]
    async fn revoked_peer_credentials_receive_only_exact_typed_http_refusal() {
        let lan = LanHarness::start().await;
        let link = lan.gateway.cluster_link().await.unwrap();
        let host = "00000000-0000-4000-8000-000000000031";
        let membership = "00000000-0000-4000-8000-000000000032";
        let token = link
            .store
            .issue(IssueParams {
                protocol: PROTOCOL,
                r#for: host.into(),
                name: "revoked-peer".into(),
                membership: membership.into(),
            })
            .await
            .unwrap();
        link.store
            .remove(
                RemoveParams {
                    protocol: PROTOCOL,
                    host: host.into(),
                    membership: membership.into(),
                },
                false,
            )
            .await
            .unwrap();
        let mut stream = lan.connect(&lan.pin).await.unwrap();
        let (status, body) = exchange(
            &mut stream,
            &format!(
                "GET /health HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {token}\r\n\r\n"
            ),
            b"",
        )
        .await;
        assert_eq!(status, 403);
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&body).unwrap(),
            json!({"class":"refused","kind":"membership_removed","host":host,"membership":membership,"retryable":false})
        );
        let (status, body) = exchange(
            &mut stream,
            &format!(
                "GET /health HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {token}x\r\n\r\n"
            ),
            b"",
        )
        .await;
        assert_eq!(status, 401);
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&body).unwrap(),
            json!({"error":"unauthorized"})
        );
        let stream = lan.connect(&lan.pin).await.unwrap();
        let mut request = format!("wss://{HOST}/ws").into_client_request().unwrap();
        request.headers_mut().insert(
            header::AUTHORIZATION,
            format!("Bearer {token}").parse().unwrap(),
        );
        let error = tokio_tungstenite::client_async(request, stream)
            .await
            .unwrap_err();
        let tokio_tungstenite::tungstenite::Error::Http(response) = error else {
            panic!("expected an HTTP refusal");
        };
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        assert_eq!(
            response.headers()["x-remotecoder-refusal"],
            "membership_removed"
        );
        assert_eq!(response.headers()["x-remotecoder-peer-host"], host);
        assert_eq!(response.headers()["x-remotecoder-membership"], membership);
        lan.stop().await;
    }
}
