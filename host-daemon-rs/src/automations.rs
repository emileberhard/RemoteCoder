//! Host-owned management of the Mini's existing private automation service.
//! Scheduling, validation, history and idempotent receipts belong to that service.
use crate::config::{HostPaths, host_profile::AutomationAuthority};
use crate::rpc::error::{ErrorKind, RpcCode, RpcData};
use crate::rpc::{RpcError, RpcResult};
use crate::wire::automations::AutomationParams;
use serde_json::{Value, json};
use std::path::Path;
use std::time::Duration;

const REQUEST_LIMIT: usize = 1_048_576;
const RESPONSE_LIMIT: usize = 8 * 1_048_576;
const READ_TIMEOUT: Duration = Duration::from_secs(20);
// Preparation can resolve sessions and baseline multiple iMessage chats. This
// generous ordinary-operation budget is bounded; it is not a worst-case promise.
const PREPARATION_TIMEOUT: Duration = Duration::from_secs(300);
const ACTOR: &str = r#"{"surface":"remotecoder","authenticated":true}"#;

pub(crate) async fn rpc(method: &str, params: Value) -> RpcResult {
    let request = prepare(method, params)?;
    if !AutomationAuthority::for_this_host()
        .map_err(|_| unavailable("Automation authority policy is unavailable"))?
    {
        return Err(unavailable(
            "Automation management is unavailable on this host",
        ));
    }
    let paths =
        HostPaths::from_env().map_err(|_| unavailable("Automation service home is unavailable"))?;
    let socket = std::env::var_os("AUTOMATIONS_STATE_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| paths.home().join(".local/state/automations"))
        .join("control.sock");
    call(&socket, request).await
}

fn invalid(message: impl Into<String>) -> RpcError {
    RpcError::new(RpcCode::InvalidParams, message)
}

fn unavailable(message: &str) -> RpcError {
    RpcError::new(RpcCode::Unavailable, message).with_data(RpcData::Kind(
        ErrorKind::AutomationUnavailable {
            authority: AutomationAuthority::authority().ok().flatten(),
        },
    ))
}

fn transport_failure(request: &Value, message: &str) -> RpcError {
    if matches!(
        request["op"].as_str(),
        Some("set" | "remove" | "restore" | "run")
    ) {
        RpcError::new(RpcCode::Unavailable, message).with_data(RpcData::Kind(
            ErrorKind::AutomationAcknowledgementUnknown {
                authority: AutomationAuthority::authority().ok().flatten(),
                request_id: request["request_id"].as_str().map(str::to_owned),
            },
        ))
    } else {
        unavailable(message)
    }
}

fn operation_timeout(request: &Value) -> Duration {
    if matches!(request["op"].as_str(), Some("set" | "restore" | "run")) {
        PREPARATION_TIMEOUT
    } else {
        READ_TIMEOUT
    }
}

fn prepare(method: &str, params: Value) -> Result<Value, RpcError> {
    let op = match method {
        "automations/status" => "status",
        "automations/list" => "list",
        "automations/show" => "show",
        "automations/history" => "history",
        "automations/set" => "set",
        "automations/remove" => "remove",
        "automations/restore" => "restore",
        "automations/run" => "run",
        _ => {
            return Err(RpcError::new(
                RpcCode::MethodNotFound,
                "Unknown automation method",
            ));
        }
    };
    let params: AutomationParams =
        serde_json::from_value(if params.is_null() { json!({}) } else { params })
            .map_err(|error| invalid(format!("Invalid automation params: {error}")))?;
    for (name, value) in [
        ("id", &params.id),
        ("requestId", &params.request_id),
        ("runId", &params.run_id),
    ] {
        if value
            .as_ref()
            .is_some_and(|value| value.trim().is_empty() || value.len() > 256)
        {
            return Err(invalid(format!(
                "{name} must be nonempty and at most 256 bytes"
            )));
        }
    }
    if params
        .search
        .as_ref()
        .is_some_and(|search| search.chars().count() > 200)
    {
        return Err(invalid("search must be at most 200 characters"));
    }
    if params
        .state
        .as_deref()
        .is_some_and(|state| !matches!(state, "active" | "paused" | "removed"))
    {
        return Err(invalid(
            "state must be active, paused or removed; omit it for all",
        ));
    }
    if params
        .limit
        .is_some_and(|limit| !(1..=200).contains(&limit))
        || params
            .output_limit
            .is_some_and(|limit| !(1..=262_144).contains(&limit))
        || params.target_revision == Some(0)
        || params
            .reason
            .as_ref()
            .is_some_and(|reason| reason.chars().count() > 2000)
    {
        return Err(invalid(
            "Automation pagination, revision or reason exceeds its bounds",
        ));
    }
    if matches!(op, "set" | "remove" | "restore") && params.expected_revision.is_none() {
        return Err(invalid("Definition changes require expectedRevision"));
    }
    if matches!(op, "set" | "remove" | "restore" | "run") && params.request_id.is_none() {
        return Err(invalid("Automation mutations require a stable requestId"));
    }
    let mut request = serde_json::to_value(params).map_err(|error| invalid(error.to_string()))?;
    let allowed: &[&str] = match op {
        "status" => &[],
        "list" => &[
            "id",
            "include_removed",
            "state",
            "search",
            "limit",
            "offset",
        ],
        "show" => &[
            "id",
            "target_revision",
            "run_id",
            "limit",
            "offset",
            "output_offset",
            "output_limit",
        ],
        "history" => &["id", "limit", "offset"],
        "set" => &[
            "id",
            "data",
            "replace_definition",
            "request_id",
            "expected_revision",
            "reason",
            "dry_run",
        ],
        "remove" => &["id", "request_id", "expected_revision", "reason", "dry_run"],
        "restore" => &[
            "id",
            "target_revision",
            "data",
            "replace_definition",
            "request_id",
            "expected_revision",
            "reason",
            "dry_run",
        ],
        "run" => &[
            "id",
            "data",
            "request_id",
            "dry_run",
            "run_id",
            "cancel",
            "message",
            "resolution",
            "invocation",
            "parent_run_id",
            "acknowledge",
        ],
        _ => unreachable!(),
    };
    if let Some(key) = request
        .as_object()
        .and_then(|object| object.keys().find(|key| !allowed.contains(&key.as_str())))
    {
        return Err(invalid(format!("{key} does not apply to {op}")));
    }
    request["op"] = json!(op);
    Ok(request)
}

async fn call(socket: &Path, request: Value) -> RpcResult {
    let body = serde_json::to_vec(&request).map_err(|error| invalid(error.to_string()))?;
    if body.len() > REQUEST_LIMIT {
        return Err(invalid(
            "Automation request exceeds the 1 MiB service limit",
        ));
    }
    let timeout = operation_timeout(&request);
    let client = reqwest::Client::builder()
        .unix_socket(socket)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(2))
        .timeout(timeout)
        .build()
        .map_err(|_| unavailable("Automation transport could not be initialized"))?;
    let operation = async {
        let mut response = client
            .post("http://localhost/rpc")
            .header("Content-Type", "application/json")
            .header("X-Automations-Actor", ACTOR)
            .body(body)
            .send()
            .await
            .map_err(|error| {
                if error.is_connect() {
                    unavailable("Automation service socket is unavailable")
                } else {
                    transport_failure(
                        &request,
                        "Automation service acknowledgement was not received",
                    )
                }
            })?;
        if !response.status().is_success() {
            return Err(transport_failure(
                &request,
                "Automation service returned an unexpected HTTP status",
            ));
        }
        if response
            .content_length()
            .is_some_and(|length| length > RESPONSE_LIMIT as u64)
        {
            return Err(transport_failure(
                &request,
                "Automation service response exceeds its size limit",
            ));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| {
            transport_failure(&request, "Automation service response was interrupted")
        })? {
            if chunk.len() > RESPONSE_LIMIT - bytes.len() {
                return Err(transport_failure(
                    &request,
                    "Automation service response exceeds its size limit",
                ));
            }
            bytes.extend_from_slice(&chunk);
        }
        // Parse on a blocking worker: large prompt snapshots never monopolize a gateway reactor.
        let envelope = tokio::task::spawn_blocking(move || serde_json::from_slice::<Value>(&bytes))
            .await
            .map_err(|_| transport_failure(&request, "Automation response decoding failed"))?
            .map_err(|_| transport_failure(&request, "Automation service returned invalid JSON"))?;
        if !envelope["ok"].is_boolean()
            || !envelope["health"].is_object()
            || (envelope["ok"] == true && envelope.get("data").is_none())
            || (envelope["ok"] == false && !envelope["error"].is_object())
        {
            return Err(transport_failure(
                &request,
                "Automation service returned an invalid envelope",
            ));
        }
        Ok(envelope)
    };
    tokio::time::timeout(timeout, operation)
        .await
        .unwrap_or_else(|_| {
            Err(transport_failure(
                &request,
                "Automation service request timed out",
            ))
        })
}

#[cfg(test)]
mod tests;
