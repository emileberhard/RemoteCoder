use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, ensure};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::{Error as WebSocketError, Message};

use super::transport::{self, Socket};
use crate::agents::jobs::model::{ConversationIdentity, Provider, ProviderHome};
use crate::agents::jobs::routes::NativeMessage;
use crate::config::GatewayEndpoint;
use crate::platform::process::{ProcessInstance, ancestry, identify};
use crate::providers::claude::native_parent::{
    NativeParentForwarder, NativeSessionOwner, prove_owner,
};
use crate::wire::agent_jobs::{Caller, CaptureParams, CapturedContext};

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
enum Registration {
    Native {
        #[serde(rename = "routeId")]
        route_id: String,
    },
    GatewayOwned,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Delivery {
    route_id: String,
    attempt_id: String,
    message: NativeMessage,
}

pub(crate) async fn run(endpoint: GatewayEndpoint, claude_home: &Path) -> Result<()> {
    let process = current_process()?;
    let owner = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if let Some(owner) = native_ancestor(claude_home, process).await? {
                return Ok::<_,anyhow::Error>(owner);
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }).await.context("Native parent holder needs its live Claude session's recorded inbox; start it directly from SessionStart without detaching")??;
    let socket = std::env::var_os("CLAUDE_CODE_MESSAGING_SOCKET")
        .context("Claude SessionStart did not provide its native messaging socket")?;
    ensure!(
        Path::new(&socket) == owner.socket_path,
        "Inherited Claude inbox does not belong to this session; start the holder from its SessionStart hook"
    );
    let token = std::env::var("CLAUDE_CODE_MESSAGING_TOKEN")
        .context("Claude SessionStart did not provide its process-only messaging token")?;
    let conversation = ConversationIdentity {
        provider: Provider::Claude,
        provider_home: ProviderHome::Known {
            path: claude_home.into(),
        },
        thread_id: crate::providers::claude::claude_thread_id(&owner.session_uuid),
    };
    let forwarder = NativeParentForwarder::new(conversation.clone(), owner.clone(), token)?;
    let mut failures = 0u32;
    loop {
        if !same_session(claude_home, &owner).await? {
            return Ok(());
        }
        let mut socket = match transport::connect(&endpoint).await {
            Ok(socket) => socket,
            Err(error) if authentication_failure(&error) => return Err(error),
            Err(_) => {
                reconnect_delay(&mut failures).await;
                continue;
            }
        };
        match serve(
            &mut socket,
            process,
            &conversation,
            claude_home,
            &owner,
            &forwarder,
        )
        .await?
        {
            SessionEnd::Finished => return Ok(()),
            SessionEnd::Disconnected => reconnect_delay(&mut failures).await,
        }
    }
}

enum SessionEnd {
    Finished,
    Disconnected,
}

async fn serve(
    socket: &mut Socket,
    process: ProcessInstance,
    conversation: &ConversationIdentity,
    home: &Path,
    owner: &NativeSessionOwner,
    forwarder: &NativeParentForwarder,
) -> Result<SessionEnd> {
    let capture = send_rpc(
        socket,
        1,
        "agent/context/capture",
        serde_json::to_value(CaptureParams {
            pid: process.pid.try_into()?,
            started_at_unix_micros: process.started_micros,
        })?,
    )
    .await;
    let capture = match capture {
        Ok(value) => value,
        Err(ExchangeError::Transport) => return Ok(SessionEnd::Disconnected),
        Err(ExchangeError::Rejected(error)) => return Err(error),
    };
    let capture: CapturedContext = serde_json::from_value(capture)
        .context("Gateway returned invalid captured native context")?;
    ensure!(
        capture.provider == Provider::Claude && capture.thread_id == conversation.thread_id,
        "Gateway captured a different native parent; refusing to register an inherited session"
    );
    let registration = send_rpc(
        socket,
        2,
        "agent/routes/register",
        json!({"caller":Caller::Captured { context_id: capture.context_id }}),
    )
    .await;
    let registration = match registration {
        Ok(value) => value,
        Err(ExchangeError::Transport) => return Ok(SessionEnd::Disconnected),
        Err(ExchangeError::Rejected(error)) => return Err(error),
    };
    let Registration::Native { route_id } = serde_json::from_value(registration)
        .context("Gateway returned invalid native route registration")?
    else {
        return Ok(SessionEnd::Finished);
    };
    ensure!(
        !route_id.is_empty() && route_id.len() <= 256,
        "Gateway returned invalid native route identity"
    );
    let mut health = tokio::time::interval(Duration::from_secs(5));
    health.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut next_rpc = 3u64;
    loop {
        let frame = tokio::select! {
            frame = socket.next() => frame,
            _ = health.tick() => {
                if !same_session(home, owner).await? { return Ok(SessionEnd::Finished); }
                continue;
            }
        };
        match frame {
            Some(Ok(Message::Text(text))) => {
                let notification: Value = serde_json::from_str(&text)
                    .context("Gateway sent invalid native route JSON")?;
                if notification
                    .get("id")
                    .and_then(Value::as_u64)
                    .is_some_and(|id| id >= 3)
                    && notification.get("error").is_some()
                {
                    anyhow::bail!(
                        "Gateway rejected native delivery acknowledgement; no input will be retried"
                    );
                }
                if notification["method"] != "agent/routes/deliver" {
                    continue;
                }
                let delivery: Delivery = serde_json::from_value(notification["params"].clone())
                    .context("Gateway sent invalid native delivery")?;
                ensure!(
                    delivery.route_id == route_id
                        && crate::ids::is_session_uuid(&delivery.attempt_id),
                    "Gateway sent a native delivery for a different route or invalid attempt"
                );
                let state = forwarder.forward(&delivery.message).await;
                let ack = json!({"routeId":route_id,"attemptId":delivery.attempt_id,"state":state});
                if socket
                    .send(Message::Text(
                        json!({"id":next_rpc,"method":"agent/routes/ack","params":ack}).to_string(),
                    ))
                    .await
                    .is_err()
                {
                    return Ok(SessionEnd::Disconnected);
                }
                next_rpc = next_rpc
                    .checked_add(1)
                    .context("Native route RPC identity exhausted")?;
            }
            Some(Ok(Message::Ping(bytes))) => {
                if socket.send(Message::Pong(bytes)).await.is_err() {
                    return Ok(SessionEnd::Disconnected);
                }
            }
            Some(Ok(Message::Close(_))) | Some(Err(_)) | None => {
                return Ok(SessionEnd::Disconnected);
            }
            _ => {}
        }
    }
}

enum ExchangeError {
    Transport,
    Rejected(anyhow::Error),
}

async fn send_rpc(
    socket: &mut Socket,
    id: u64,
    method: &str,
    params: Value,
) -> std::result::Result<Value, ExchangeError> {
    let exchange = async {
        socket
            .send(Message::Text(
                json!({"id":id,"method":method,"params":params}).to_string(),
            ))
            .await
            .map_err(|_| ExchangeError::Transport)?;
        while let Some(frame) = socket.next().await {
            match frame {
                Ok(Message::Text(text)) => {
                    let response: Value = serde_json::from_str(&text)
                        .map_err(|error| ExchangeError::Rejected(error.into()))?;
                    if response["id"] != id {
                        continue;
                    }
                    if let Some(error) = response.get("error") {
                        let code = error["code"].as_i64();
                        if matches!(code, Some(-32002 | -32003)) {
                            return Err(ExchangeError::Transport);
                        }
                        return Err(ExchangeError::Rejected(anyhow::anyhow!(
                            "Gateway refused {method}: {}",
                            error["message"].as_str().unwrap_or("unspecified RPC error")
                        )));
                    }
                    return response.get("result").cloned().ok_or_else(|| {
                        ExchangeError::Rejected(anyhow::anyhow!(
                            "Gateway returned no {method} result"
                        ))
                    });
                }
                Ok(Message::Ping(bytes)) => socket
                    .send(Message::Pong(bytes))
                    .await
                    .map_err(|_| ExchangeError::Transport)?,
                Ok(Message::Close(_)) | Err(_) => break,
                _ => {}
            }
        }
        Err(ExchangeError::Transport)
    };
    tokio::time::timeout(Duration::from_secs(30), exchange)
        .await
        .unwrap_or(Err(ExchangeError::Transport))
}

fn current_process() -> Result<ProcessInstance> {
    let pid = i32::try_from(std::process::id())?;
    let identity = identify(pid)?.context("Native holder process identity is unavailable")?;
    Ok(ProcessInstance {
        pid,
        started_micros: identity.started_micros,
    })
}

async fn native_ancestor(
    home: &Path,
    process: ProcessInstance,
) -> Result<Option<NativeSessionOwner>> {
    for process in ancestry(process) {
        let process = process?;
        if let Some(owner) = prove_owner(home, process.pid, process.started_micros).await? {
            return Ok(Some(owner));
        }
    }
    Ok(None)
}

async fn same_session(home: &Path, owner: &NativeSessionOwner) -> Result<bool> {
    Ok(prove_owner(home, owner.pid, owner.started_micros)
        .await?
        .is_some_and(|current| {
            current.session_uuid == owner.session_uuid && current.socket_path == owner.socket_path
        }))
}

async fn reconnect_delay(failures: &mut u32) {
    *failures = failures.saturating_add(1);
    let base = 250u64.saturating_mul(1u64 << (*failures).min(5)).min(5000);
    let jitter = u64::from(getrandom::u32().expect("operating system entropy") % 256);
    tokio::time::sleep(Duration::from_millis(base + jitter)).await;
}

fn authentication_failure(error: &anyhow::Error) -> bool {
    matches!(error.downcast_ref::<WebSocketError>(), Some(WebSocketError::Http(response)) if matches!(response.status().as_u16(), 401 | 403))
}

#[cfg(all(test, target_os = "macos"))]
mod tests;
