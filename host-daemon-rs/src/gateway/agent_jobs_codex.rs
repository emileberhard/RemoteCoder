use std::sync::Arc;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::Gateway;
use super::agent_gateway::CodexStop;
use crate::agents::jobs::model::{
    ConversationIdentity, DeliveryState, MAX_PROMPT_BYTES, Provider, ProviderHome,
};
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};
use crate::time::unix_seconds;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum NativeInputFact {
    Recorded,
    Rejected,
    Stopped,
    Finished,
    Terminal,
    Suspended,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
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
    pub(crate) async fn job_deliver_codex(
        self: &Arc<Self>,
        conversation: &ConversationIdentity,
        delivery_id: &str,
        text: &str,
    ) -> RpcResult {
        let ProviderHome::Known { path } = &conversation.provider_home else {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "the Codex provider home is unknown",
            ));
        };
        if conversation.provider != Provider::Codex
            || path != &self.job_codex_home().map_err(RpcError::from)?
            || delivery_id.is_empty()
            || delivery_id.len() > 512
            || text.len() > MAX_PROMPT_BYTES
        {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "invalid exact Codex delivery",
            ));
        }
        let state = match self
            .deliver_codex_input(conversation, delivery_id, text)
            .await
        {
            Ok(state) => state,
            Err(error) => DeliveryState::Uncertain {
                reason: format!("native delivery custody could not be reconciled: {error:#}"),
            },
        };
        Ok(json!({"deliveryId":delivery_id,"deliveryState":state}))
    }

    async fn deliver_codex_input(
        self: &Arc<Self>,
        target: &ConversationIdentity,
        id: &str,
        text: &str,
    ) -> Result<DeliveryState> {
        if let Some(accepted) = self
            .job_read_codex_acceptance(&target.thread_id, id)
            .await?
        {
            return Ok(accepted_delivery(&target.thread_id, id, &accepted));
        }
        let input = json!([{"type":"text","text":text}]);
        let mut cursor: Option<String> = None;
        let mut seen = std::collections::HashSet::new();
        for _ in 0..4 {
            let page = self.call_control("thread/items/list", json!({
                "threadId":target.thread_id,"limit":100,"sortDirection":"desc","cursor":cursor,
            })).await?;
            let entries = page["data"]
                .as_array()
                .context("canonical delivery page has no items")?;
            ensure!(
                entries.len() <= 100,
                "canonical delivery page exceeds its bound"
            );
            for entry in entries {
                if entry["item"]["type"] == "userMessage"
                    && entry["item"]["clientId"].as_str() == Some(id)
                {
                    return Ok(
                        if super::queue::same_codex_input(&entry["item"]["content"], &input) {
                            DeliveryState::Recorded {
                                receipt: format!(
                                    "codex:{} input={} item={}",
                                    target.thread_id, id, entry["item"]["id"]
                                ),
                            }
                        } else {
                            DeliveryState::Blocked {
                                reason: "the delivery identity already records a different payload"
                                    .into(),
                            }
                        },
                    );
                }
            }
            cursor = page["nextCursor"].as_str().map(str::to_owned);
            match &cursor {
                None => break,
                Some(cursor) => ensure!(
                    seen.insert(cursor.clone()),
                    "canonical delivery cursor repeated"
                ),
            }
        }
        let response = self
            .queue_rpc(
                0,
                "thread/queue/add",
                json!({
                    "threadId":target.thread_id,
                    "clientUserMessageId":id,
                    "input":input,
                }),
            )
            .await;
        Ok(match response {
            Ok(response) => DeliveryState::Accepted {
                receipt: format!(
                    "codex:{} input={} queuedSubmission={}",
                    target.thread_id,
                    id,
                    response
                        .pointer("/queuedSubmission/id")
                        .and_then(Value::as_str)
                        .context("native queued delivery has no receipt identity")?
                ),
            },
            Err(error) if error.kind() == Some("queueChangeUncertain") => {
                DeliveryState::Uncertain {
                    reason: error.message,
                }
            }
            Err(error)
                if error
                    .response(&Value::Null)
                    .pointer("/error/data/kind")
                    .and_then(Value::as_str)
                    == Some("inputAlreadyAccepted") =>
            {
                match self
                    .job_read_codex_acceptance(&target.thread_id, id)
                    .await?
                {
                    Some(accepted) => accepted_delivery(&target.thread_id, id, &accepted),
                    None => DeliveryState::Uncertain {
                        reason:
                            "native acceptance receipt disappeared during delivery reconciliation"
                                .into(),
                    },
                }
            }
            Err(error) => DeliveryState::Blocked {
                reason: error.message,
            },
        })
    }

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
                    && accepted
                        .fingerprint
                        .bytes()
                        .all(|byte| byte.is_ascii_hexdigit()),
                "native acceptance evidence is invalid"
            );
        }
        Ok(accepted)
    }

    pub(crate) async fn job_start_codex_input(self: &Arc<Self>, params: Value) -> Result<Value> {
        ensure!(!self.is_draining(), "the gateway is draining");
        let thread = params["threadId"]
            .as_str()
            .context("threadId is required")?;
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
            .map_err(|error| anyhow::anyhow!("{}", error.message))?;
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
            let bound =
                self.core
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
    ) -> RpcResult {
        let changed = self.core.lock().await.turns.hold_queue(thread);
        if changed {
            self.commit_turn_state().await.map_err(RpcError::from)?;
        }
        let response = self.call_control("thread/input/stop", json!({
            "threadId":thread,"clientUserMessageId":input,
        })).await.map_err(RpcError::from)?;
        let accepted: Option<NativeInputAcceptance> = serde_json::from_value(
            response.get("acceptance").cloned().ok_or_else(|| {
                RpcError::new(RpcCode::Internal, "native input Stop has no fence acknowledgement")
            })?
        ).map_err(|error| RpcError::new(RpcCode::Internal, error.to_string()))?;
        if let Some(accepted) = accepted {
            if !accepted.has(NativeInputFact::Terminal) {
                return Err(RpcError::new(
                    RpcCode::Internal, "native input Stop did not acknowledge a terminal fence",
                ));
            }
            return if accepted.has(NativeInputFact::Stopped) {
                CodexStop::new(self)
                    .cleanup_accepted(thread, &accepted.turn_id)
                    .await
            } else {
                Ok(json!({}))
            };
        }
        Ok(json!({}))
    }
}

fn accepted_delivery(thread: &str, input: &str, accepted: &NativeInputAcceptance) -> DeliveryState {
    let receipt = format!(
        "codex:{thread}/{} input={input} fingerprint={}",
        accepted.turn_id, accepted.fingerprint
    );
    if accepted.has(NativeInputFact::Recorded) {
        DeliveryState::Recorded { receipt }
    } else if accepted.has(NativeInputFact::Rejected)
        || accepted.has(NativeInputFact::Stopped)
        || accepted.has(NativeInputFact::Terminal)
    {
        DeliveryState::Blocked {
            reason: "the native owner retired this exact delivery before recording it".into(),
        }
    } else {
        DeliveryState::Accepted { receipt }
    }
}
