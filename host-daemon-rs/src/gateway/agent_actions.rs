use super::Gateway;
use super::agent_gateway::{CodexStop, NOTIFICATION_ANCESTRY_BUDGET, coverage_failure_codes};
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};
use anyhow::Result;
use serde::Deserialize;
use serde_json::{Value, json};
use std::time::Instant;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InterruptTurn {
    thread_id: String,
    turn_id: String,
}

impl Gateway {
    pub(crate) async fn interrupt_codex_turn(&self, params: Value) -> RpcResult {
        let InterruptTurn { thread_id, turn_id } =
            serde_json::from_value(params.clone()).map_err(|_| {
                RpcError::new(RpcCode::InvalidParams, "threadId and turnId are required")
            })?;
        CodexStop::new(self).run(&thread_id, &turn_id, params).await
    }

    // Shared authoritative ancestry for notification eligibility.
    pub(super) async fn is_agent_thread(&self, thread: &str) -> Result<bool> {
        let started = Instant::now();
        let result = tokio::time::timeout(
            NOTIFICATION_ANCESTRY_BUDGET,
            self.lookup_agent_thread(thread),
        )
        .await
        .map_err(anyhow::Error::from)
        .and_then(|result| result);
        let snapshot = json!({
            "outcome":match &result { Ok(true) => "child", Ok(false) => "root", Err(_) => "unknown" },
            "reasonCodes":result.as_ref().err().map(coverage_failure_codes).unwrap_or_default(),
            "threadId":thread,"accountID":Option::<&str>::None,
            "accountGeneration":Option::<u64>::None,
            "checkedAtUnixSeconds":crate::time::unix_seconds(),"elapsedMs":started.elapsed().as_millis(),
        });
        self.journal.push("ancestryLookup", snapshot);
        result
    }

    async fn lookup_agent_thread(&self, thread: &str) -> Result<bool> {
        self.agent_service()
            .thread_relation(thread)
            .await
            .map(|relation| matches!(relation, super::agent_gateway::ThreadRelation::Child(_)))
    }
}
