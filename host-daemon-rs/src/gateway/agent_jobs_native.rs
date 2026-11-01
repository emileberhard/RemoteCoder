use anyhow::{Context, Result, ensure};
use serde_json::json;

use super::Gateway;
use crate::agents::jobs::model::{
    ConversationIdentity, ExecutionBinding, ExecutionState, Provider,
};

enum NativeInput<'a> {
    Turn(&'a str),
    Input(&'a str),
}

impl Gateway {
    pub(super) async fn native_active_execution(
        &self,
        conversation: &ConversationIdentity,
    ) -> Result<Option<ExecutionState>> {
        let turn = match conversation.provider {
            Provider::Codex => self
                .latest_codex_turn(&conversation.thread_id, None)
                .await?
                .filter(|turn| turn["status"] == "inProgress")
                .map(|turn| {
                    turn["id"]
                        .as_str()
                        .context("active native turn has no ID")
                        .map(str::to_owned)
                })
                .transpose()?,
            Provider::Claude => self.claude_active_turn_id(&conversation.thread_id).await,
        };
        let Some(turn) = turn else { return Ok(None) };
        let binding = self
            .native_binding(conversation, NativeInput::Turn(&turn))
            .await?;
        Ok(Some(match binding {
            Some(binding) => ExecutionState::Running { binding },
            None => ExecutionState::Unknown {
                conversation: Some(conversation.clone()),
                binding: None,
                reason: format!(
                    "native turn {turn} has no exact input evidence; observation cannot infer its binding"
                ),
            },
        }))
    }

    pub(crate) async fn native_input_binding(
        &self,
        conversation: &ConversationIdentity,
        input: &str,
    ) -> Result<Option<ExecutionBinding>> {
        if conversation.provider == Provider::Codex
            && let Some(accepted) = self
                .job_read_codex_acceptance(&conversation.thread_id, input)
                .await?
        {
            return Ok(Some(ExecutionBinding {
                conversation: conversation.clone(),
                input_id: input.into(),
                turn_id: accepted.turn_id,
            }));
        }
        let native_input = match conversation.provider {
            Provider::Claude => crate::providers::claude::conversation_index::delivery_uuid(
                &conversation.thread_id,
                input,
            ),
            Provider::Codex => input.to_owned(),
        };
        self.native_binding(conversation, NativeInput::Input(&native_input))
            .await
    }

    async fn native_binding(
        &self,
        conversation: &ConversationIdentity,
        query: NativeInput<'_>,
    ) -> Result<Option<ExecutionBinding>> {
        let mut cursor: Option<String> = None;
        let mut seen = std::collections::HashSet::new();
        for _ in 0..4 {
            let mut params = json!({"threadId":conversation.thread_id,"limit":100,"sortDirection":"desc","cursor":cursor});
            if let NativeInput::Turn(turn) = &query {
                params["turnId"] = json!(turn);
            }
            let page = self
                .cluster_history_page("thread/items/list", params)
                .await?;
            let entries = page["data"]
                .as_array()
                .context("native input page has no items")?;
            ensure!(entries.len() <= 100, "native input page exceeds its bound");
            for entry in entries {
                if entry["item"]["type"] != "userMessage" {
                    continue;
                }
                let Some(input) = entry["item"]["clientId"]
                    .as_str()
                    .filter(|id| !id.is_empty())
                else {
                    continue;
                };
                let Some(turn) = entry["turnId"].as_str().filter(|id| !id.is_empty()) else {
                    continue;
                };
                let matches = match &query {
                    NativeInput::Turn(expected) => turn == *expected,
                    NativeInput::Input(expected) => input == *expected,
                };
                if matches {
                    return Ok(Some(ExecutionBinding {
                        conversation: conversation.clone(),
                        input_id: input.into(),
                        turn_id: turn.into(),
                    }));
                }
            }
            cursor = page["nextCursor"].as_str().map(str::to_owned);
            match &cursor {
                None => break,
                Some(cursor) => {
                    ensure!(seen.insert(cursor.clone()), "native input cursor repeated")
                }
            }
        }
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{FakeControl, TestGateway};

    #[tokio::test]
    async fn active_native_binding_needs_input_evidence_from_that_exact_turn() {
        for input_turn in ["exact-turn", "other-turn"] {
            let gateway = TestGateway::new();
            let conversation = gateway
                .agent_conversation("0e1a0399-0e3d-5aa4-ace7-0ed28835d55f")
                .unwrap();
            let mut control = FakeControl::attach(&gateway, 2).await.requests;
            let owner = gateway.clone();
            let target = conversation.clone();
            let task = tokio::spawn(async move {
                owner
                    .native_active_execution(&target)
                    .await
                    .unwrap()
                    .unwrap()
            });
            for method in ["thread/turns/list", "thread/items/list"] {
                let request: serde_json::Value =
                    serde_json::from_str(&control.recv().await.unwrap()).unwrap();
                assert_eq!(request["method"], method);
                let data = if method == "thread/turns/list" {
                    json!({"data":[{"id":"exact-turn","status":"inProgress"}],"nextCursor":null})
                } else {
                    assert_eq!(request["params"]["turnId"], "exact-turn");
                    json!({"data":[{"turnId":input_turn,"item":{"type":"userMessage","clientId":"native-input"}}],"nextCursor":null})
                };
                gateway
                    .control_requests
                    .lock()
                    .unwrap()
                    .remove(request["id"].as_str().unwrap())
                    .unwrap()
                    .send(Ok(data))
                    .unwrap();
            }
            let execution = task.await.unwrap();
            if input_turn == "exact-turn" {
                assert_eq!(
                    execution.binding(),
                    Some(&ExecutionBinding {
                        conversation,
                        turn_id: "exact-turn".into(),
                        input_id: "native-input".into()
                    })
                );
            } else {
                assert!(matches!(
                    execution,
                    ExecutionState::Unknown { binding: None, .. }
                ));
            }
            assert!(matches!(
                control.try_recv(),
                Err(tokio::sync::mpsc::error::TryRecvError::Empty)
            ));
        }
    }
}
