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

    fn validate(&self) -> Result<()> {
        ensure!(
            !self.turn_id.is_empty()
                && !self.root_turn_id.is_empty()
                && self.fingerprint.len() == 64
                && self
                    .fingerprint
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit()),
            "native acceptance evidence is invalid"
        );
        Ok(())
    }
}

impl Gateway {
    pub(crate) async fn job_deliver_codex(
        self: &Arc<Self>,
        conversation: &ConversationIdentity,
        delivery_id: &str,
        text: &str,
        expected_turn: Option<&str>,
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
            .deliver_codex_input(conversation, delivery_id, text, expected_turn)
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
        expected_turn: Option<&str>,
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
        let latest = self.latest_codex_turn(&target.thread_id, None).await?;
        let active = latest
            .as_ref()
            .filter(|turn| turn["status"] == "inProgress");
        if let Some(expected) = expected_turn
            && active.and_then(|turn| turn["id"].as_str()) != Some(expected)
        {
            return Ok(DeliveryState::Blocked {
                reason: "the target job's exact native turn is no longer active; input was not submitted".into(),
            });
        }
        if let Some(turn) = active {
            let turn_id = turn["id"]
                .as_str()
                .filter(|id| !id.is_empty())
                .context("the active native turn has no identity")?;
            let response = self
                .call_control(
                    "turn/steer",
                    json!({
                        "threadId":target.thread_id,
                        "expectedTurnId":turn_id,
                        "clientUserMessageId":id,
                        "input":input,
                    }),
                )
                .await;
            return match response {
                Ok(response) => {
                    ensure!(
                        response["turnId"].as_str() == Some(turn_id),
                        "native steer acknowledged a different turn"
                    );
                    Ok(DeliveryState::Accepted {
                        receipt: format!(
                            "codex:{}/{} input={} steered=true",
                            target.thread_id, turn_id, id
                        ),
                    })
                }
                Err(error) => Ok(
                    match super::agent_gateway::parse_native_error(&error.to_string()) {
                        Some(error) => DeliveryState::Blocked {
                            reason: error.message,
                        },
                        None => DeliveryState::Uncertain {
                            reason: format!(
                                "native steer custody could not be reconciled: {error:#}"
                            ),
                        },
                    },
                ),
            };
        }
        ensure!(
            latest.as_ref().is_none_or(|turn| matches!(
                turn["status"].as_str(),
                Some("completed" | "interrupted" | "failed")
            )),
            "native turn activity is unknown; input was not submitted"
        );
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
            accepted.validate()?;
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

    pub(crate) async fn job_stop_codex_input(&self, thread: &str, input: &str) -> RpcResult {
        let changed = self.core.lock().await.turns.hold_queue(thread);
        if changed {
            self.commit_turn_state().await.map_err(RpcError::from)?;
        }
        let response = self
            .call_control(
                "thread/input/stop",
                json!({
                    "threadId":thread,"clientUserMessageId":input,
                }),
            )
            .await
            .map_err(RpcError::from)?;
        let accepted: Option<NativeInputAcceptance> =
            serde_json::from_value(response.get("acceptance").cloned().ok_or_else(|| {
                RpcError::new(
                    RpcCode::Internal,
                    "native input Stop has no fence acknowledgement",
                )
            })?)
            .map_err(|error| RpcError::new(RpcCode::Internal, error.to_string()))?;
        if let Some(accepted) = accepted {
            accepted.validate().map_err(RpcError::from)?;
            if !accepted.has(NativeInputFact::Terminal) {
                return Err(RpcError::new(
                    RpcCode::Internal,
                    "native input Stop did not acknowledge a terminal fence",
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notifications::history::NotificationOrigin;
    use crate::test_support::{FakeControl, TestGateway};

    fn reply(gateway: &Gateway, request: &Value, result: Value) {
        gateway
            .control_requests
            .lock()
            .unwrap()
            .remove(request["id"].as_str().unwrap())
            .unwrap()
            .send(Ok(result))
            .unwrap();
    }

    #[tokio::test]
    async fn running_delivery_steers_with_stable_identity_and_never_retargets() {
        for (native_turn, steer_reply) in [
            ("expected", Some(Ok(json!({"turnId":"expected"})))),
            ("successor", None),
            (
                "expected",
                Some(Err(
                    json!({"code":-32600,"message":"no active turn to steer"}).to_string(),
                )),
            ),
        ] {
            let directory = tempfile::tempdir().unwrap();
            let root = directory.path().canonicalize().unwrap();
            let gateway = TestGateway::with_native_runtime(&root);
            let target = ConversationIdentity {
                provider: Provider::Codex,
                provider_home: ProviderHome::Known {
                    path: gateway.job_codex_home().unwrap(),
                },
                thread_id: "frozen-thread".into(),
            };
            let mut control = FakeControl::attach(&gateway, 4).await.requests;
            let owner = gateway.clone();
            let task = tokio::spawn(async move {
                owner
                    .job_deliver_codex(&target, "stable-message", "live input", Some("expected"))
                    .await
            });
            for (method, result) in [
                ("thread/input/acceptance/read", json!({"acceptance":null})),
                ("thread/items/list", json!({"data":[],"nextCursor":null})),
                (
                    "thread/turns/list",
                    json!({"data":[{"id":native_turn,"status":"inProgress"}]}),
                ),
            ] {
                let request: Value = serde_json::from_str(&control.recv().await.unwrap()).unwrap();
                assert_eq!(request["method"], method);
                reply(&gateway, &request, result);
            }
            let expected_state = if let Some(result) = steer_reply {
                let request: Value = serde_json::from_str(&control.recv().await.unwrap()).unwrap();
                assert_eq!(request["method"], "turn/steer");
                assert_eq!(
                    request["params"],
                    json!({"threadId":"frozen-thread","expectedTurnId":"expected","clientUserMessageId":"stable-message","input":[{"type":"text","text":"live input"}]})
                );
                let success = result.is_ok();
                gateway
                    .control_requests
                    .lock()
                    .unwrap()
                    .remove(request["id"].as_str().unwrap())
                    .unwrap()
                    .send(result)
                    .unwrap();
                if success { "accepted" } else { "blocked" }
            } else {
                "blocked"
            };
            assert_eq!(
                task.await.unwrap().unwrap()["deliveryState"]["kind"],
                expected_state
            );
            assert!(matches!(
                control.try_recv(),
                Err(tokio::sync::mpsc::error::TryRecvError::Empty)
            ));
        }
    }

    #[tokio::test]
    async fn accepted_historical_delivery_is_reconciled_without_new_steer() {
        let directory = tempfile::tempdir().unwrap();
        let gateway = TestGateway::with_native_runtime(directory.path());
        let target = ConversationIdentity {
            provider: Provider::Codex,
            provider_home: ProviderHome::Known {
                path: gateway.job_codex_home().unwrap(),
            },
            thread_id: "frozen-thread".into(),
        };
        let mut control = FakeControl::attach(&gateway, 1).await.requests;
        let owner = gateway.clone();
        let task = tokio::spawn(async move {
            owner
                .job_deliver_codex(&target, "stable-message", "live input", Some("new-turn"))
                .await
        });
        let request: Value = serde_json::from_str(&control.recv().await.unwrap()).unwrap();
        assert_eq!(request["method"], "thread/input/acceptance/read");
        reply(
            &gateway,
            &request,
            json!({"acceptance":{"turnId":"original-turn","rootTurnId":"original-turn","fingerprint":"a".repeat(64),"facts":[]}}),
        );
        let receipt = task.await.unwrap().unwrap();
        assert_eq!(receipt["deliveryState"]["kind"], "accepted");
        assert!(
            receipt["deliveryState"]["receipt"]
                .as_str()
                .unwrap()
                .contains("original-turn")
        );
        assert!(matches!(
            control.try_recv(),
            Err(tokio::sync::mpsc::error::TryRecvError::Empty)
        ));
    }

    #[tokio::test]
    async fn input_stop_requires_positive_native_fence_acknowledgement() {
        let thread = "e1741c43-3d9a-4448-9f4a-3c7e5906e852";
        for (reply, succeeds) in [
            (json!({}), false),
            (json!({"acceptance":null}), true),
            (
                json!({"acceptance":{
                    "turnId":"reserved-turn", "rootTurnId":"reserved-turn",
                    "fingerprint":"a".repeat(64), "facts":[],
                }}),
                false,
            ),
            (
                json!({"acceptance":{
                    "turnId":"reserved-turn", "rootTurnId":"reserved-turn",
                    "fingerprint":"a".repeat(64), "facts":["terminal","finished"],
                }}),
                true,
            ),
        ] {
            let directory = tempfile::tempdir().unwrap();
            let gateway = TestGateway::with_native_runtime(directory.path());
            let mut control = FakeControl::attach(&gateway, 1).await.requests;
            let owner = gateway.clone();
            let responder = tokio::spawn(async move {
                let request: Value = serde_json::from_str(&control.recv().await.unwrap()).unwrap();
                assert_eq!(request["method"], "thread/input/stop");
                assert_eq!(
                    request["params"],
                    json!({
                        "threadId":thread,"clientUserMessageId":"stable-input",
                    })
                );
                owner
                    .handle_control_text(
                        json!({"id":request["id"],"result":reply}).to_string(),
                        NotificationOrigin::Control { opened_after: 0 },
                    )
                    .await;
            });
            let result = gateway.job_stop_codex_input(thread, "stable-input").await;
            responder.await.unwrap();
            assert_eq!(result.is_ok(), succeeds, "{result:?}");
        }
    }
}
