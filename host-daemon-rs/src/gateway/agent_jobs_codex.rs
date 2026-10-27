use std::sync::Arc;

use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::{Value, json};

use super::Gateway;
use super::agent_gateway::CodexStop;
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};
use crate::time::unix_seconds;

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum NativeInputFact {
    Recorded,
    Rejected,
    Stopped,
    Finished,
    Terminal,
    Suspended,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NativeInputAcceptance {
    pub(crate) turn_id: String,
    pub(crate) root_turn_id: String,
    pub(crate) fingerprint: String,
    pub(crate) facts: Vec<NativeInputFact>,
}

impl NativeInputAcceptance {
    pub(crate) fn has(&self, fact: NativeInputFact) -> bool {
        self.facts.contains(&fact)
    }
}

impl Gateway {
    pub(crate) async fn job_read_codex_acceptance(
        &self,
        thread: &str,
        input: &str,
    ) -> Result<Option<NativeInputAcceptance>> {
        let response = self
            .call_control(
                "thread/input/acceptance/read",
                json!({"threadId":thread,"clientUserMessageId":input}),
            )
            .await?;
        let accepted: Option<NativeInputAcceptance> = serde_json::from_value(
            response
                .get("acceptance")
                .cloned()
                .context("native acceptance reply has no acceptance field")?,
        )?;
        if let Some(accepted) = &accepted {
            ensure!(
                !accepted.turn_id.is_empty()
                    && !accepted.root_turn_id.is_empty()
                    && accepted.fingerprint.len() == 64
                    && accepted.fingerprint.bytes().all(|byte| byte.is_ascii_hexdigit()),
                "native acceptance evidence is invalid"
            );
        }
        Ok(accepted)
    }

    pub(crate) async fn job_start_codex_input(
        self: &Arc<Self>,
        params: Value,
    ) -> Result<Value> {
        ensure!(!self.is_draining(), "the gateway is draining");
        let thread = params["threadId"].as_str().context("threadId is required")?;
        let input = params["clientUserMessageId"]
            .as_str()
            .filter(|id| !id.is_empty())
            .context("a stable clientUserMessageId is required")?;
        let id = json!(format!("agent-input:{thread}:{input}"));
        let request = json!({"id":id,"method":"turn/start","params":params});
        let object = request.as_object().context("invalid turn request")?;
        let _admission = self.admit_request(Some("turn/start"), object)?;
        self.validate_dispatch("turn/start", object)
            .await
            .map_err(anyhow::Error::from)?;
        let key = format!("0:{id}");
        let exists = self
            .core
            .lock()
            .await
            .turns
            .pending()
            .any(|(candidate, _)| candidate == &key);
        if !exists {
            self.capture_client_request_locked(0, object).await?;
        }
        let response = self.call_control("turn/start", params).await;
        if let Ok(response) = &response {
            let turn_id = response
                .pointer("/turn/id")
                .and_then(Value::as_str)
                .context("native turn acceptance has no exact turn identity")?;
            let bound = self
                .core
                .lock()
                .await
                .turns
                .bind_pending_acceptance(&key, turn_id, unix_seconds());
            if bound {
                self.commit_turn_state().await?;
            }
        }
        self.spawn_observers_for_client(0).await;
        response
    }

    pub(crate) async fn job_stop_codex_input(
        &self,
        thread: &str,
        input: &str,
        accepted: &NativeInputAcceptance,
    ) -> RpcResult {
        let current = self
            .job_read_codex_acceptance(thread, input)
            .await
            .map_err(RpcError::from)?
            .ok_or_else(|| {
                RpcError::new(RpcCode::Conflict, "native acceptance is unresolved; Stop remains pending")
            })?;
        if current.turn_id != accepted.turn_id || current.fingerprint != accepted.fingerprint {
            return Err(RpcError::new(RpcCode::Conflict, "native input acceptance changed"));
        }
        let changed = self.core.lock().await.turns.hold_queue(thread);
        if changed {
            self.commit_turn_state().await.map_err(RpcError::from)?;
        }
        if current.has(NativeInputFact::Terminal) {
            return if current.has(NativeInputFact::Stopped) {
                CodexStop::new(self).cleanup_accepted(thread, &accepted.turn_id).await
            } else {
                Ok(json!({}))
            };
        }
        CodexStop::new(self)
            .run_accepted(
                thread,
                json!({"threadId":thread,"turnId":accepted.turn_id}),
            )
            .await
    }
}
