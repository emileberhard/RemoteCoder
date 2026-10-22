use super::RPC_TIMEOUT;
use crate::providers::codex::daemon::{CodexAppServer, CodexWebSocket};
use crate::runtime::recovery::{RecoveryJournal, RecoveryTask, RecoveryTaskStatus};
use anyhow::{Context, Result, bail, ensure};
use futures_util::{SinkExt, StreamExt};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use tokio_tungstenite::tungstenite::Message;

pub(super) async fn verify_failed_recovery_targets(
    rpc: &mut RpcClient,
    journal: &RecoveryJournal,
) -> Result<()> {
    for task in journal
        .tasks
        .iter()
        .filter(|task| task.status == RecoveryTaskStatus::Failed)
    {
        let page: TurnsPage = rpc
            .request(
                "thread/turns/list",
                serde_json::json!({
                    "threadId": task.thread_id,
                    "limit": 1,
                    "sortDirection": "desc",
                    "itemsView": "summary",
                }),
            )
            .await?;
        ensure!(
            page.data.first().is_some_and(|turn| {
                turn.id == task.turn_id
                    && matches!(turn.status.as_str(), "inProgress" | "interrupted")
                    && turn.completed_at.is_none()
            }),
            "failed recovery target {}:{} is no longer the exact unfinished native turn",
            task.thread_id,
            task.turn_id
        );
    }
    Ok(())
}

pub(super) async fn snapshot_active_tasks(rpc: &mut RpcClient) -> Result<Vec<RecoveryTask>> {
    let mut cursor: Option<String> = None;
    let mut seen_cursors = std::collections::HashSet::new();
    let mut threads = HashMap::new();
    loop {
        let mut params = serde_json::json!({"limit": 100});
        if let Some(cursor) = cursor.as_deref() {
            params["cursor"] = Value::String(cursor.to_string());
        }
        let response: LoadedThreadsPage = rpc.request("thread/loaded/list", params).await?;
        for id in response.data {
            let response: ThreadReadResponse = rpc
                .request(
                    "thread/read",
                    serde_json::json!({"threadId": id, "includeTurns": false}),
                )
                .await?;
            let thread = response.thread;
            if thread.id != id {
                bail!("thread/read returned {} for {id}", thread.id);
            }
            threads.insert(thread.id.clone(), thread);
        }
        let Some(next_cursor) = response.next_cursor else {
            break;
        };
        if !seen_cursors.insert(next_cursor.clone()) {
            bail!("thread/loaded/list repeated a pagination cursor");
        }
        cursor = Some(next_cursor);
        if threads.len() > 10_000 {
            bail!("loaded thread inventory exceeded safety bound");
        }
    }

    let mut tasks = Vec::new();
    for thread in threads
        .values()
        .filter(|thread| thread.status.kind == "active")
    {
        let response: Result<TurnsPage> = rpc
            .request(
                "thread/turns/list",
                serde_json::json!({
                    "threadId": thread.id,
                    "limit": 1,
                    "sortDirection": "desc",
                    "itemsView": "summary",
                }),
            )
            .await;
        let response = match response {
            Ok(response) => response,
            Err(error) if error.is::<EphemeralTurnsUnavailable>() => {
                let current: ThreadReadResponse = rpc
                    .request(
                        "thread/read",
                        serde_json::json!({"threadId": thread.id, "includeTurns": false}),
                    )
                    .await
                    .with_context(|| format!("failed to re-read ephemeral thread {}", thread.id))?;
                ensure!(
                    current.thread.id == thread.id
                        && current.thread.ephemeral == Some(true)
                        && current.thread.status.kind == "idle",
                    "ephemeral thread {} is active or unresolved and cannot be captured safely; retry after it finishes",
                    thread.id
                );
                continue;
            }
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("failed to read turns of active thread {}", thread.id)
                });
            }
        };
        let Some(active) = response
            .data
            .into_iter()
            .find(|turn| turn.status == "inProgress")
        else {
            let current: Result<ThreadReadResponse> = rpc
                .request(
                    "thread/read",
                    serde_json::json!({"threadId": thread.id, "includeTurns": false}),
                )
                .await;
            match current {
                Ok(current)
                    if current.thread.id == thread.id && current.thread.status.kind != "active" =>
                {
                    continue;
                }
                Err(error) if error.is::<ThreadNotFound>() => continue,
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("failed to re-read active thread {}", thread.id));
                }
                Ok(current) if current.thread.id != thread.id => {
                    bail!(
                        "thread/read returned {} for {}",
                        current.thread.id,
                        thread.id
                    );
                }
                Ok(_) => {
                    bail!("active thread {} has no in-progress turn", thread.id);
                }
            }
        };
        tasks.push(RecoveryTask {
            thread_id: thread.id.clone(),
            turn_id: active.id,
            parent_thread_id: thread.parent_thread_id.clone(),
            depth: thread_depth(&thread.id, &threads)?,
            recovery_attempts: 0,
            status: RecoveryTaskStatus::Captured,
            error: None,
        });
    }
    Ok(tasks)
}

fn thread_depth(thread_id: &str, threads: &HashMap<String, ThreadSummary>) -> Result<usize> {
    let mut depth = 0;
    let mut current = thread_id;
    let mut seen = std::collections::HashSet::new();
    while let Some(parent) = threads
        .get(current)
        .and_then(|thread| thread.parent_thread_id.as_deref())
    {
        if !seen.insert(current) {
            bail!("thread parent cycle includes {thread_id}");
        }
        depth += 1;
        current = parent;
    }
    Ok(depth)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ThreadSummary {
    pub(super) id: String,
    parent_thread_id: Option<String>,
    ephemeral: Option<bool>,
    status: ThreadStatus,
}

#[derive(Debug, Deserialize)]
struct ThreadStatus {
    #[serde(rename = "type")]
    kind: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TurnSummary {
    id: String,
    status: String,
    completed_at: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LoadedThreadsPage {
    data: Vec<String>,
    next_cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct ThreadReadResponse {
    pub(super) thread: ThreadSummary,
}

#[derive(Debug, Deserialize)]
struct TurnsPage {
    data: Vec<TurnSummary>,
}

#[derive(Debug, Deserialize)]
pub(super) struct SuspendResponse {
    pub(super) outcome: SuspendOutcome,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "status", rename_all = "camelCase")]
pub(super) enum SuspendOutcome {
    Suspended {
        #[serde(rename = "turnId")]
        turn_id: String,
    },
    NotActive,
    TurnChanged {
        #[serde(rename = "actualTurnId")]
        actual_turn_id: String,
    },
    HasLiveDescendants,
    UnsupportedTask,
}

pub(super) struct RpcClient {
    pub(super) websocket: CodexWebSocket,
    pub(super) next_id: u64,
}

#[derive(Debug)]
struct ThreadNotFound(String);

#[derive(Debug)]
struct EphemeralTurnsUnavailable;

impl std::fmt::Display for EphemeralTurnsUnavailable {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("ephemeral threads do not support thread/turns/list")
    }
}

impl std::error::Error for EphemeralTurnsUnavailable {}

impl std::fmt::Display for ThreadNotFound {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for ThreadNotFound {}

impl RpcClient {
    pub(super) async fn connect(app_server: &CodexAppServer) -> Result<Self> {
        Self::initialize(app_server.connect_ws().await?).await
    }

    pub(super) async fn initialize(websocket: CodexWebSocket) -> Result<Self> {
        let mut client = Self {
            websocket,
            next_id: 0,
        };
        client
            .request::<_, Value>(
                "initialize",
                serde_json::json!({
                    "clientInfo": {
                        "name": "remotecoder-runtime",
                        "title": "RemoteCoder runtime transaction",
                        "version": crate::build_identity::IDENTITY.version,
                    },
                    "capabilities": {"experimentalApi": true},
                }),
            )
            .await?;
        client
            .websocket
            .send(Message::Text(
                serde_json::json!({"method": "initialized", "params": {}}).to_string(),
            ))
            .await?;
        Ok(client)
    }

    pub(super) async fn request<P, R>(&mut self, method: &str, params: P) -> Result<R>
    where
        P: Serialize,
        R: DeserializeOwned,
    {
        let deadline = tokio::time::Instant::now() + RPC_TIMEOUT;
        self.next_id += 1;
        let id = format!("runtime:{}", self.next_id);
        tokio::time::timeout_at(
            deadline,
            self.websocket.send(Message::Text(
                serde_json::json!({
                    "jsonrpc": "2.0",
                    "id": &id,
                    "method": method,
                    "params": params,
                })
                .to_string(),
            )),
        )
        .await
        .with_context(|| format!("{method} timed out"))?
        .with_context(|| format!("failed to send {method}"))?;
        loop {
            let frame = tokio::time::timeout_at(deadline, self.websocket.next())
                .await
                .with_context(|| format!("{method} timed out"))?
                .context("Codex app-server closed the runtime connection")??;
            let Message::Text(raw) = frame else {
                continue;
            };
            let message: Value = serde_json::from_str(&raw)
                .with_context(|| format!("{method} returned invalid JSON"))?;
            if message.get("id").and_then(Value::as_str) != Some(id.as_str()) {
                continue;
            }
            if let Some(error) = message.get("error") {
                if method == "thread/turns/list"
                    && error["code"] == -32600
                    && error["message"] == "ephemeral threads do not support thread/turns/list"
                {
                    return Err(EphemeralTurnsUnavailable)
                        .with_context(|| format!("{method} failed: {error}"));
                }
                if method == "thread/read"
                    && error["message"]
                        .as_str()
                        .is_some_and(|message| message.contains("thread not found:"))
                {
                    return Err(ThreadNotFound(format!("{method} failed: {error}")).into());
                }
                bail!("{method} failed: {error}");
            }
            let result = message
                .get("result")
                .cloned()
                .context("app-server response omitted result")?;
            return serde_json::from_value(result)
                .with_context(|| format!("{method} returned an invalid result"));
        }
    }
}
