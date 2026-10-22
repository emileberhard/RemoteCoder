use super::Gateway;
use super::subscriptions::MAX_CLAUDE_THREAD_ID_BYTES;
use crate::providers::claude::{CapacityExceeded, session_uuid_from_thread_id};
use crate::rpc::error::RpcCode;
use crate::rpc::{HISTORY_PAGE_RESPONSE_BUDGET, RpcError, RpcResult};
use serde::Deserialize;
use serde_json::{Value, json};
use std::io::{self, Write};

impl Gateway {
    pub(super) async fn claude_live_checkpoint_rpc(&self, params: Value) -> RpcResult {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Request {
            thread_id: String,
        }
        let request: Request = serde_json::from_value(params)
            .map_err(|_| RpcError::new(RpcCode::InvalidParams, "Expected one Claude threadId"))?;
        if request.thread_id.len() > MAX_CLAUDE_THREAD_ID_BYTES
            || session_uuid_from_thread_id(&request.thread_id).is_none()
        {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "threadId must be a Claude thread ID of at most 512 bytes",
            ));
        }
        let agent = self.claude_agent();
        let snapshot = match agent {
            Some(agent) => agent.live_checkpoint(&request.thread_id).await,
            None => None,
        };
        let Some(snapshot) = snapshot else {
            return Ok(
                json!({"status":"unknown", "threadId":request.thread_id, "reason":"noLiveState"}),
            );
        };
        bounded_checkpoint(snapshot, &request.thread_id)
    }
}

fn bounded_checkpoint(snapshot: Value, thread_id: &str) -> RpcResult {
    let mut length = CheckpointLength {
        bytes: 0,
        exceeded: false,
    };
    let result = serde_json::to_writer(&mut length, &snapshot);
    if length.exceeded {
        let capacity = CapacityExceeded {
            resource: "live checkpoint bytes",
            limit: HISTORY_PAGE_RESPONSE_BUDGET,
        };
        return Ok(json!({"status":"unknown", "threadId":thread_id, "reason":capacity.to_value()}));
    }
    result.map_err(|error| {
        RpcError::new(
            RpcCode::Internal,
            format!("Could not encode live checkpoint: {error}"),
        )
    })?;
    Ok(snapshot)
}

struct CheckpointLength {
    bytes: usize,
    exceeded: bool,
}

impl Write for CheckpointLength {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > HISTORY_PAGE_RESPONSE_BUDGET.saturating_sub(self.bytes) {
            self.exceeded = true;
            return Err(io::Error::other("live checkpoint exceeds response budget"));
        }
        self.bytes += bytes.len();
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gateway::tests::test_client;
    use crate::rpc::dispatch::{DispatchPlan, RequestLifetime};
    use crate::test_support::TestGateway;
    use tokio::sync::mpsc;

    #[tokio::test]
    async fn live_checkpoint_rpc_is_read_only_and_reports_absence_without_starting_work() {
        let gateway = TestGateway::new();
        let (tx, mut rx) = mpsc::channel(2);
        let client = test_client(1, tx);
        let DispatchPlan::Request(request) = DispatchPlan::parse(
            &json!({"id":1,
            "method":"claude/thread/liveCheckpoint", "params":{"threadId":"claude_missing"}})
            .to_string(),
        ) else {
            panic!("expected read request")
        };
        assert!(!request.starts_new_work);
        let owned = request.owned.expect("checkpoint must be gateway-owned");
        assert_eq!(owned.lifetime, RequestLifetime::Query);
        gateway
            .handle_owned_rpc(1, &client, &request.method, owned.target, &request.object)
            .await
            .unwrap();
        let super::super::ClientCommand::Text(response) = rx.recv().await.unwrap() else {
            panic!("expected response")
        };
        let response: Value = serde_json::from_str(&response).unwrap();
        assert_eq!(
            response["result"],
            json!({"status":"unknown","threadId":"claude_missing","reason":"noLiveState"})
        );
        assert!(gateway.claude_agent().is_none());
        for params in [
            json!({}),
            json!({"threadId":"native"}),
            json!({"threadId":"claude_"}),
            json!({"threadId":format!("claude_{}", "x".repeat(512))}),
        ] {
            assert_eq!(
                gateway
                    .claude_live_checkpoint_rpc(params)
                    .await
                    .unwrap_err()
                    .code,
                RpcCode::InvalidParams
            );
        }
    }

    #[test]
    fn live_checkpoint_encoded_capacity_counts_escaping_without_returning_a_partial_prefix() {
        let snapshot =
            json!({"liveItems":[{"text":"\0".repeat(HISTORY_PAGE_RESPONSE_BUDGET / 6)}]});
        let unknown = bounded_checkpoint(snapshot, "claude_a").unwrap();
        assert_eq!(unknown["status"], "unknown");
        assert_eq!(unknown["reason"]["kind"], "capacity");
        assert_eq!(unknown["reason"]["limit"], HISTORY_PAGE_RESPONSE_BUDGET);
        assert!(unknown.get("liveItems").is_none());
    }
}
