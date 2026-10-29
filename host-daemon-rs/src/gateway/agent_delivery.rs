use std::sync::Arc;

use serde_json::json;

use super::Gateway;
use crate::agents::jobs::model::{ConversationIdentity, DeliveryState, Provider};
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};

impl Gateway {
    pub(crate) async fn deliver_job_input(
        self: &Arc<Self>,
        conversation: &ConversationIdentity,
        delivery_id: &str,
        text: &str,
        expected_turn: Option<&str>,
    ) -> RpcResult {
        if self.agent_conversation(&conversation.thread_id)? != *conversation {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "delivery provider home differs from the canonical owner",
            ));
        }
        if conversation.provider == Provider::Codex {
            return self
                .job_deliver_codex(conversation, delivery_id, text, expected_turn)
                .await;
        }
        let provider = self.job_claude()?;
        let message = crate::providers::claude::ParentMessage {
            thread_id: conversation.thread_id.clone(),
            delivery_id: delivery_id.to_owned(),
            text: text.to_owned(),
        };
        let mut gateway_owned = provider
            .job_parent_gateway_owned(&conversation.thread_id)
            .await?;
        if !gateway_owned
            && provider
                .has_legacy_gateway_parent(&conversation.thread_id)
                .await?
        {
            self.external_activity.invalidate().await;
            let request = json!({"params":{"threadId":conversation.thread_id}});
            if let Some(error) = self
                .other_client_refusal(
                    "claude/message",
                    request.as_object().expect("constructed request object"),
                )
                .await
            {
                return Ok(
                    json!({"deliveryId":delivery_id,"deliveryState":DeliveryState::Blocked { reason: error.message }}),
                );
            }
            gateway_owned = provider
                .restore_gateway_parent_route(&conversation.thread_id)
                .await?;
            if gateway_owned {
                self.journal.runtime(
                    "parent_route_restored",
                    json!({"threadId":conversation.thread_id,"evidence":"retainedGatewaySelectionAndAvailableClientInventory"}),
                );
            }
        }
        let result = if gateway_owned {
            provider.deliver_parent_message(message).await
        } else {
            provider
                .deliver_native_parent_message(message, &self.jobs.native_routes)
                .await
        };
        let state = match result {
            Ok(receipt) => match receipt["delivery_state"].as_str() {
                Some("recorded") => DeliveryState::Recorded {
                    receipt: receipt.to_string(),
                },
                Some("submitted") => DeliveryState::Submitted {
                    route: if gateway_owned {
                        "claudeGateway"
                    } else {
                        "claudeNative"
                    }
                    .into(),
                },
                _ => {
                    return Err(RpcError::new(
                        RpcCode::Internal,
                        "Claude delivery returned an unsupported evidence state",
                    ));
                }
            },
            Err(error) => {
                let parent_not_submitted = error.parent_not_submitted();
                let error = RpcError::from(error);
                match error.kind() {
                    _ if parent_not_submitted => DeliveryState::Unreachable {
                        reason: error.message,
                    },
                    Some("inputDeliveryUncertain") => DeliveryState::Uncertain {
                        reason: error.message,
                    },
                    Some("parentUnreachable") => DeliveryState::Unreachable {
                        reason: error.message,
                    },
                    _ if error.code == RpcCode::ServerBusy
                        || error.code == RpcCode::Unavailable =>
                    {
                        DeliveryState::Blocked {
                            reason: error.message,
                        }
                    }
                    _ => DeliveryState::Failed {
                        reason: error.message,
                    },
                }
            }
        };
        Ok(json!({"deliveryId":delivery_id,"deliveryState":state}))
    }
}

impl Gateway {
    pub(crate) async fn deliver_job_recipient(
        self: &Arc<Self>,
        recipient: &crate::agents::jobs::model::Recipient,
        id: &str,
        text: &str,
        previous: &DeliveryState,
    ) -> anyhow::Result<DeliveryState> {
        use crate::agents::jobs::model::Recipient;
        match recipient {
            Recipient::Conversation { conversation } => {
                let result = self
                    .deliver_job_input(conversation, id, text, None)
                    .await
                    .map_err(|error| anyhow::anyhow!(error.message))?;
                Ok(serde_json::from_value(result["deliveryState"].clone())?)
            }
            Recipient::Remote {
                host,
                incarnation,
                conversation,
            } => {
                let request = crate::wire::cluster::DeliverParams {
                    protocol: crate::wire::cluster::PROTOCOL,
                    conversation: conversation.clone(),
                    incarnation: incarnation.clone(),
                    delivery_id: id.to_owned(),
                    text: text.to_owned(),
                };
                match self
                    .cluster_link()
                    .await?
                    .call(host, "agent/jobs/deliver", json!(request))
                    .await
                {
                    Ok(response) => Ok(serde_json::from_value(response["deliveryState"].clone())?),
                    Err(error)
                        if matches!(
                            previous,
                            DeliveryState::Uncertain { .. }
                                | DeliveryState::Sending { .. }
                                | DeliveryState::Submitted { .. }
                        ) =>
                    {
                        Ok(DeliveryState::Uncertain {
                            reason: error.message,
                        })
                    }
                    Err(error) => Ok(match error.class {
                        crate::wire::cluster::ErrorClass::Unavailable if !error.transmitted => {
                            DeliveryState::Unreachable {
                                reason: error.message,
                            }
                        }
                        crate::wire::cluster::ErrorClass::Refused
                        | crate::wire::cluster::ErrorClass::Unsupported
                        | crate::wire::cluster::ErrorClass::Conflict => DeliveryState::Failed {
                            reason: error.message,
                        },
                        _ => DeliveryState::Uncertain {
                            reason: error.message,
                        },
                    }),
                }
            }
            Recipient::None => Ok(DeliveryState::Dismissed {
                reason: "agent was promoted; result remains available to the user".into(),
            }),
            Recipient::Unknown { reason } => Ok(DeliveryState::Uncertain {
                reason: reason.clone(),
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::jobs::model::Recipient;
    use crate::wire::cluster::*;

    #[tokio::test]
    async fn cluster_delivery_retry_transport_failure_keeps_uncertain_custody() {
        use base64::Engine;
        let directory = tempfile::tempdir().unwrap();
        let gateway = crate::test_support::TestGateway::with_native_runtime(directory.path());
        let link = gateway.cluster_link().await.unwrap();
        let host = crate::ids::new_session_uuid();
        let membership = crate::ids::new_session_uuid();
        let credential = link
            .store
            .issue(IssueParams {
                protocol: PROTOCOL,
                r#for: host.clone(),
                name: "receiver".into(),
                membership: membership.clone(),
            })
            .await
            .unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            for _ in 0..2 {
                let (stream, _) = listener.accept().await.unwrap();
                drop(stream);
            }
        });
        link.store
            .accept(AcceptParams {
                protocol: PROTOCOL,
                host: host.clone(),
                name: "receiver".into(),
                membership,
                pin: base64::engine::general_purpose::STANDARD.encode([0u8; 32]),
                routes: vec![format!("wss://{address}/ws")],
                credential,
            })
            .await
            .unwrap();
        let recipient = Recipient::Remote {
            host,
            incarnation: crate::ids::new_session_uuid(),
            conversation: ConversationIdentity {
                provider: Provider::Codex,
                provider_home: crate::agents::jobs::model::ProviderHome::Known {
                    path: directory.path().join("codex"),
                },
                thread_id: crate::ids::new_session_uuid(),
            },
        };
        let initial = gateway
            .deliver_job_recipient(&recipient, "delivery", "result", &DeliveryState::Pending)
            .await
            .unwrap();
        assert!(matches!(initial, DeliveryState::Unreachable { .. }));
        let retried = gateway
            .deliver_job_recipient(
                &recipient,
                "delivery",
                "result",
                &DeliveryState::Uncertain {
                    reason: "old receiver may have accepted".into(),
                },
            )
            .await
            .unwrap();
        assert!(matches!(retried, DeliveryState::Uncertain { .. }));
        server.await.unwrap();
    }
}
