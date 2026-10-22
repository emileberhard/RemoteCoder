use super::Gateway;
use super::agent_gateway::{
    CodexStop, LauncherPurpose, NOTIFICATION_ANCESTRY_BUDGET, coverage_failure_codes,
    native_agent_relation,
};
use crate::agents::launcher;
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
        let claude = crate::providers::claude::is_claude_thread_id(thread);
        if claude && self.claude_thread_is_minted(thread).await? {
            return Ok(false);
        }
        let native = if !claude {
            self.call_control(
                "thread/read",
                json!({"threadId":thread,"includeTurns":false}),
            )
            .await
            .and_then(|header| native_agent_relation(&header, thread))
            .map_err(|_| launcher::unavailable("nativeAncestryUnavailable"))
        } else {
            Ok(false)
        };
        if native.as_ref().is_ok_and(|child| *child) {
            return Ok(true);
        }
        let home = self.agent_home_for_thread(thread)?;
        // Fresh indexed coverage is cheap and must not borrow the UI's cached
        // inventory. A newly admitted unresolved launch can invalidate a prior
        // negative root proof. Read only this exact provider home and thread.
        let response = self
            .call_agent_launcher(
                LauncherPurpose::Classification,
                json!({"operation":"classify","schemaVersion":2,
            "homes":[home],"threadIds":[thread]}),
            )
            .await
            .map_err(launcher::call_failure)?;
        if launcher::subject_relation(&response, &home, thread)? {
            return Ok(true);
        }
        native
    }

    async fn claude_thread_is_minted(&self, thread: &str) -> Result<bool> {
        let Some(agent) = self.claude_agent() else {
            return Ok(false);
        };
        agent
            .is_minted(thread)
            .map_err(|_| launcher::unavailable("creationRecordUnreadable"))
    }
}
