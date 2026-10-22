use std::sync::Arc;

use anyhow::Result;
use axum::Json;
use axum::body::Bytes;
use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use serde_json::json;
use tracing::warn;

use crate::gateway::Gateway;

use super::HttpState;
use super::auth::{authorize, bearer_token};

fn optional_header<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers.get(name).and_then(|value| value.to_str().ok())
}

/// RemoteCoder's own MCP endpoint, which is how the Claude runtime reaches the
/// agent tools. See `mcp.rs` for the protocol; this owns auth and dispatch.
pub(super) async fn mcp_post(
    McpCaller { gateway, identity }: McpCaller,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let Ok(parsed) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({
                "jsonrpc": "2.0",
                "id": serde_json::Value::Null,
                "error": { "code": -32700, "message": "body must be JSON" }
            })),
        )
            .into_response();
    };

    let incoming = crate::agents::mcp::Incoming {
        protocol_version: optional_header(&headers, "mcp-protocol-version"),
        method_header: optional_header(&headers, "mcp-method"),
        name_header: optional_header(&headers, "mcp-name"),
        origin: optional_header(&headers, "origin"),
        body: &parsed,
    };

    match crate::agents::mcp::route(&incoming) {
        crate::agents::mcp::Action::Accepted => StatusCode::ACCEPTED.into_response(),
        crate::agents::mcp::Action::Respond { status, body } => (
            StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
            Json(body),
        )
            .into_response(),
        crate::agents::mcp::Action::CallTool {
            id,
            name,
            mut arguments,
        } => {
            if name == crate::agents::tools::NOTIFY_USER {
                let permission = bearer_token(&headers)
                    .ok_or("nativeClaudeRootProofMissing")
                    .and_then(|token| {
                        gateway
                            .mcp_tokens()
                            .consume_notification_permit(token, &arguments)
                    });
                if let Err(reason) = permission {
                    gateway.record_user_alert_suppression(
                        identity.as_ref().map(|value| value.thread_id.as_str()),
                        "userAlert",
                        None,
                        reason,
                    );
                    let outcome = crate::agents::tools::ToolOutcome::error(
                        "Notification caller was not verified by the runtime hook. Retry from the root conversation when notification authorization is available.",
                    );
                    return (
                        StatusCode::OK,
                        Json(crate::agents::mcp::tool_response(&id, &outcome)),
                    )
                        .into_response();
                }
                crate::agents::mcp::remove_notification_permit(&mut arguments);
            }
            let thread_id = identity.map(|identity| identity.thread_id);
            let turn_id = match thread_id.as_deref() {
                Some(thread) => gateway.claude_active_turn_id(thread).await,
                None => None,
            };
            let caller = crate::agents::tools::Caller {
                turn_id,
                provider: crate::providers::Provider::Claude,
                thread_id,
            };
            let outcome =
                crate::agents::tools::dispatch(&gateway, &name, &arguments, &caller).await;
            (
                StatusCode::OK,
                Json(crate::agents::mcp::tool_response(&id, &outcome)),
            )
                .into_response()
        }
    }
}

async fn mcp_runtime_owner(
    state: &HttpState,
    headers: &HeaderMap,
) -> Option<(Arc<Gateway>, crate::agents::mcp::McpIdentity)> {
    let token = bearer_token(headers)?;
    if let Some(identity) = state.gateway.mcp_tokens().identify(token) {
        return Some((state.gateway.clone(), identity));
    }
    None
}

/// Native hook root proof and suppressed-call journaling. Operator auth cannot
/// invent a runtime, and a missing/expired hook proof cannot authorize dispatch.
pub(super) async fn mcp_notification_hook(
    McpRuntime { gateway, identity }: McpRuntime,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let input = serde_json::from_slice(&body).unwrap_or(serde_json::Value::Null);
    if let Some(arguments) = bearer_token(&headers).and_then(|token| {
        gateway
            .mcp_tokens()
            .issue_notification_permit(token, &input)
    }) {
        return Json(
            json!({"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":arguments}}),
        )
        .into_response();
    }
    let reason =
        crate::providers::claude::notification_hook::decide(&input, &identity.session_uuid)
            .suppression_reason()
            .unwrap_or("nativeClaudeNotificationArgumentsInvalid");
    gateway.record_user_alert_suppression(Some(&identity.thread_id), "userAlert", None, reason);
    StatusCode::NO_CONTENT.into_response()
}

/// This protocol revision removed the GET stream endpoint.
pub(super) async fn mcp_get() -> Response {
    (
        StatusCode::METHOD_NOT_ALLOWED,
        Json(crate::agents::mcp::method_not_allowed()),
    )
        .into_response()
}

/// A per-runtime token identifies the thread that minted it. The gateway
/// bearer is also accepted so rc-gateway can exercise the endpoint, but it
/// carries no thread identity.
pub(super) struct McpCaller {
    gateway: Arc<Gateway>,
    identity: Option<crate::agents::mcp::McpIdentity>,
}

#[axum::async_trait]
impl FromRequestParts<HttpState> for McpCaller {
    type Rejection = Response;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &HttpState,
    ) -> Result<Self, Self::Rejection> {
        if let Some((gateway, identity)) = mcp_runtime_owner(state, &parts.headers).await {
            return Ok(Self {
                gateway,
                identity: Some(identity),
            });
        }
        if authorize(state, &parts.headers).await.is_ok() {
            return Ok(Self {
                gateway: state.gateway.clone(),
                identity: None,
            });
        }
        warn!("unauthorized request to /mcp");
        Err((
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"unauthorized"})),
        )
            .into_response())
    }
}

pub(super) struct McpRuntime {
    gateway: Arc<Gateway>,
    identity: crate::agents::mcp::McpIdentity,
}

#[axum::async_trait]
impl FromRequestParts<HttpState> for McpRuntime {
    type Rejection = StatusCode;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &HttpState,
    ) -> Result<Self, Self::Rejection> {
        mcp_runtime_owner(state, &parts.headers)
            .await
            .map(|(gateway, identity)| Self { gateway, identity })
            .ok_or(StatusCode::UNAUTHORIZED)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    use crate::http::server::harness::{HOST, LanHarness, OPERATOR, exchange};

    #[tokio::test]
    async fn notify_dispatch_requires_the_exact_one_use_native_root_hook_proof() {
        for account in [false, true] {
            let harness = LanHarness::start_scoped(account).await;
            let token = harness.gateway.mcp_tokens().mint("claude_root", "session");
            let call = |arguments: Value| {
                json!({"jsonrpc":"2.0","id":1,"method":"tools/call",
            "params":{"name":"notify_user","arguments":arguments,"_meta":{"io.modelcontextprotocol/protocolVersion":crate::agents::mcp::PROTOCOL_VERSION}}})
            };
            let arguments = json!({"title":"Fixture","body":"Root"});
            let (_, response) =
                notification_request(&harness, "/mcp", &token, call(arguments.clone())).await;
            assert!(
                response["result"]["content"][0]["text"]
                    .as_str()
                    .unwrap()
                    .contains("runtime hook")
            );
            let (status, issued) = notification_request(&harness,"/mcp/notification-hook",&token,
            json!({"session_id":"session","hook_event_name":"PreToolUse","tool_name":crate::providers::claude::notification_hook::TOOL,"tool_input":arguments})).await;
            assert_eq!(status, 200);
            assert!(
                issued["hookSpecificOutput"]
                    .get("permissionDecision")
                    .is_none()
            );
            let updated = issued["hookSpecificOutput"]["updatedInput"].clone();
            assert!(updated[crate::agents::mcp::NOTIFICATION_PERMIT_FIELD].is_string());
            let proof = updated[crate::agents::mcp::NOTIFICATION_PERMIT_FIELD]
                .as_str()
                .unwrap()
                .to_owned();
            let other = harness
                .gateway
                .mcp_tokens()
                .mint("claude_other", "other-session");
            let (_, wrong_runtime) =
                notification_request(&harness, "/mcp", &other, call(updated.clone())).await;
            assert_eq!(wrong_runtime["result"]["isError"], true);
            let mut changed = updated.clone();
            changed["body"] = json!("Different notification");
            let (_, changed_copy) =
                notification_request(&harness, "/mcp", &token, call(changed)).await;
            assert_eq!(changed_copy["result"]["isError"], true);
            let (_, delivered) =
                notification_request(&harness, "/mcp", &token, call(updated.clone())).await;
            // This fixture disables APNs. Its registration error proves dispatch
            // passed the hook boundary without ever contacting a real broker.
            assert!(
                delivered["result"]["content"][0]["text"]
                    .as_str()
                    .unwrap()
                    .contains("push notifications are unavailable")
            );
            let (_, replay) = notification_request(&harness, "/mcp", &token, call(updated)).await;
            assert!(
                replay["result"]["content"][0]["text"]
                    .as_str()
                    .unwrap()
                    .contains("runtime hook")
            );
            let (status, empty_copy) = notification_request(&harness, "/mcp/notification-hook", &token, json!({
                "session_id":"session","hook_event_name":"PreToolUse","tool_name":crate::providers::claude::notification_hook::TOOL,
                "tool_input":{"title":" ","body":"Root"}
            })).await;
            assert_eq!(status, 200);
            let (_, invalid_copy) = notification_request(
                &harness,
                "/mcp",
                &token,
                call(empty_copy["hookSpecificOutput"]["updatedInput"].clone()),
            )
            .await;
            assert_eq!(invalid_copy["result"]["isError"], true);
            assert!(
                invalid_copy["result"]["content"][0]["text"]
                    .as_str()
                    .unwrap()
                    .contains("non-empty \"title\"")
            );
            let (status, _) = notification_request(&harness, "/mcp/notification-hook", &token, json!({
                "session_id":"session","hook_event_name":"PreToolUse","tool_name":crate::providers::claude::notification_hook::TOOL,
                "tool_input":null
            })).await;
            assert_eq!(status, 204);
            let records = tokio::time::timeout(std::time::Duration::from_secs(2), async {
                loop {
                    let mut records = Vec::new();
                    for entry in
                        std::fs::read_dir(harness.directory.path().join("journal")).unwrap()
                    {
                        let path = entry.unwrap().path();
                        if path.extension().is_some_and(|ext| ext == "jsonl") {
                            for line in std::fs::read_to_string(path).unwrap().lines() {
                                if let Ok(record) = serde_json::from_str::<Value>(line) {
                                    records.push(record);
                                }
                            }
                        }
                    }
                    if records.iter().any(|record| {
                        record["reason"] == "nativeClaudeNotificationArgumentsInvalid"
                    }) {
                        break records;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                }
            })
            .await
            .unwrap();
            let record = records
                .iter()
                .find(|record| record["event"] == "dispatch")
                .unwrap();
            assert_eq!(
                record["arguments"],
                json!({"titleBytes": 7, "bodyBytes": 4})
            );
            let serialized = serde_json::to_string(&records).unwrap();
            assert!(!serialized.contains(&proof));
            assert!(!serialized.contains(crate::agents::mcp::NOTIFICATION_PERMIT_FIELD));
            for reason in [
                "nativeClaudeRootProofRuntimeMismatch",
                "nativeClaudeRootProofArgumentsMismatch",
                "nativeClaudeRootProofReplayed",
            ] {
                assert!(records.iter().any(|record| record["reason"] == reason));
            }
            harness.stop().await;
        }
    }

    async fn notification_request(
        harness: &LanHarness,
        path: &str,
        token: &str,
        body: Value,
    ) -> (u16, Value) {
        let mut stream = harness.connect(&harness.pin).await.unwrap();
        let body = body.to_string();
        let (status, response) = exchange(&mut stream, &format!(
            "POST {path} HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nMCP-Protocol-Version: {}\r\nMCP-Method: tools/call\r\nMCP-Name: notify_user\r\n\r\n",body.len(),crate::agents::mcp::PROTOCOL_VERSION),body.as_bytes()).await;
        (
            status,
            serde_json::from_slice(&response).unwrap_or(Value::Null),
        )
    }

    #[tokio::test]
    async fn a_full_size_inline_visual_fits_the_request_after_json_escaping() {
        let harness = LanHarness::start().await;
        let token = harness.gateway.mcp_tokens().mint("claude_root", "session");
        let html = "\"".repeat(crate::storage::visuals::MAX_HTML_BYTES);
        let body = json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"publish_visual",
            "arguments":{"html":html,"path":"/both.html","title":"Both"},
            "_meta":{"io.modelcontextprotocol/protocolVersion":crate::agents::mcp::PROTOCOL_VERSION}}})
        .to_string();
        assert!(body.len() > 2 * crate::storage::visuals::MAX_HTML_BYTES);
        let mut stream = harness.connect(&harness.pin).await.unwrap();
        let (status, response) = exchange(&mut stream, &format!(
            "POST /mcp HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nMCP-Protocol-Version: {}\r\nMCP-Method: tools/call\r\nMCP-Name: publish_visual\r\n\r\n",
            body.len(), crate::agents::mcp::PROTOCOL_VERSION), body.as_bytes()).await;
        assert_eq!(status, 200, "{}", String::from_utf8_lossy(&response));
        let response: Value = serde_json::from_slice(&response).unwrap_or(Value::Null);
        assert!(
            response["result"]["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("exactly one")
        );
        harness.stop().await;
    }

    #[tokio::test]
    async fn native_notification_hook_requires_a_live_runtime_identity() {
        let harness = LanHarness::start().await;
        let token = harness.gateway.mcp_tokens().mint("claude_root", "session");
        let body = json!({"hook_event_name":"PreToolUse","tool_name":crate::providers::claude::notification_hook::TOOL,
            "session_id":"session","agent_id":"child"}).to_string();
        for (credential, expected) in [
            (OPERATOR, 401),
            ("unknown-token", 401),
            (token.as_str(), 204),
        ] {
            let mut stream = harness.connect(&harness.pin).await.unwrap();
            let (status, _) = exchange(&mut stream, &format!(
                "POST /mcp/notification-hook HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {credential}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",body.len()), body.as_bytes()).await;
            assert_eq!(status, expected);
        }
        harness.gateway.mcp_tokens().revoke_token(&token);
        let mut stream = harness.connect(&harness.pin).await.unwrap();
        let (status, _) = exchange(&mut stream, &format!(
            "POST /mcp/notification-hook HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {token}\r\nContent-Length: {}\r\n\r\n",body.len()), body.as_bytes()).await;
        assert_eq!(status, 401);
        drop(stream);
        harness.stop().await;
    }
}
