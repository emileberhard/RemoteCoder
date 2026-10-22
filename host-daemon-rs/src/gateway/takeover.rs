use super::Gateway;
use crate::activity::external::stop_client;
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};
use serde_json::{Map, Value, json};

const OPEN_IN_OTHER_CLIENT: &str =
    "This conversation is open in another client. Take it over here before sending.";

fn continues_existing_thread(method: &str) -> bool {
    matches!(
        method,
        "turn/start"
            | "thread/resume"
            | "claude/message"
            | "thread/compact/start"
            | "thread/queue/add"
            | "thread/queue/start"
    )
}

impl Gateway {
    pub(super) async fn other_client_refusal(
        &self,
        method: &str,
        object: &Map<String, Value>,
    ) -> Option<RpcError> {
        if !continues_existing_thread(method) {
            return None;
        }
        let thread_id = object.get("params")?.get("threadId")?.as_str()?;
        match self
            .external_snapshot()
            .await
            .and_then(|snapshot| snapshot.client_owners(thread_id))
        {
            Ok(owners) if owners.is_empty() => None,
            Ok(_) => Some(RpcError::new(RpcCode::Conflict, OPEN_IN_OTHER_CLIENT)),
            Err(error) => Some(RpcError::new(RpcCode::Unavailable, format!("{error:#}"))),
        }
    }

    pub(super) async fn take_over_conversation(&self, params: Value) -> RpcResult {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct TakeOver {
            thread_id: String,
        }
        let TakeOver { thread_id } = super::rpc_methods::decode_params(params)?;
        self.external_activity.invalidate().await;
        let owners = self
            .external_snapshot()
            .await
            .and_then(|snapshot| snapshot.client_owners(&thread_id))
            .map_err(|error| RpcError::new(RpcCode::Unavailable, format!("{error:#}")))?;
        for &pid in &owners {
            let stopped = stop_client(pid).await;
            self.journal.runtime(
                "take_over",
                json!({
                    "threadId": thread_id,
                    "pid": pid,
                    "outcome": if stopped.is_ok() { "stopped" } else { "failed" },
                }),
            );
            stopped.map_err(|error| {
                RpcError::new(
                    RpcCode::Internal,
                    format!("Could not stop the other client: {error:#}"),
                )
            })?;
        }
        self.external_activity.invalidate().await;
        self.activity.mark_changed();
        Ok(json!({ "stoppedProcesses": owners.len() }))
    }
}
