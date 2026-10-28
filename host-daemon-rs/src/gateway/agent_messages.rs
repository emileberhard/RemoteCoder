use anyhow::{Context, Result, bail, ensure};
use serde_json::json;

use super::Gateway;
use crate::agents::jobs::model::{
    ConversationBinding, DeliveryState, ExecutionState, JobId, JobSource, Origin, Recipient,
};
use crate::agents::jobs::store::fingerprint;
use crate::agents::jobs::store::messages::{MessageContinuation, MessageRecord, ResolvedMessage};
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};
use crate::wire::agent_jobs::*;

fn now_ms() -> i64 {
    (crate::time::unix_seconds() * 1000.0) as i64
}

fn bounded_reason(reason: &str) -> String {
    let mut characters = reason.chars();
    let mut result: String = characters.by_ref().take(4096).collect();
    if characters.next().is_some() {
        result.push_str(" [truncated]");
    }
    result
}

impl Gateway {
    pub(super) async fn job_message(&self, request: MessageParams) -> RpcResult {
        let gateway = self.jobs.gateway()?;
        tokio::spawn(async move { gateway.admit_job_message(request).await })
            .await
            .map_err(|error| {
                RpcError::from(anyhow::anyhow!("message admission task failed: {error}"))
            })?
    }

    async fn admit_job_message(&self, request: MessageParams) -> RpcResult {
        if request
            .delivery_id
            .split_once(':')
            .is_some_and(|(prefix, _)| JobId::try_from(prefix.to_owned()).is_ok())
        {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "job delivery IDs are reserved for the runtime; use a distinct message ID",
            ));
        }
        crate::agents::envelope::validate_message_text(&request.text)
            .map_err(|error| RpcError::new(RpcCode::InvalidParams, error.to_string()))?;
        let sender = self.resolve_job_caller(&request.caller).await?;
        let request_fingerprint = fingerprint(
            &serde_json::to_vec(&(&sender, &request.target, &request.text))
                .map_err(anyhow::Error::from)?,
        );
        let _claim = self.jobs.claim_message(&request.delivery_id).await?;
        let operation = self.jobs.operations.read().await;
        if self.is_draining() {
            return Err(RpcError::draining());
        }
        let store = self.jobs.store().await?;
        let mut record = if let Some(record) = store
            .existing_message(request.delivery_id.clone(), request_fingerprint.clone())
            .await
            .map_err(|error| RpcError::new(RpcCode::Conflict, error.to_string()))?
        {
            record
        } else {
            let text = match &sender {
                Origin::TopLevel => request.text,
                Origin::Parent { .. } => {
                    let view = self.job_context_view(request.caller.clone()).await?;
                    let host = self.job_host_name()?;
                    crate::agents::envelope::message(
                        &request.delivery_id,
                        &crate::agents::envelope::Sender {
                            agent_id: &view.sender_id,
                            provider: view.context.provider.as_str(),
                            host: &host,
                            reply_tool: "message_agent",
                            reply_target: view
                                .job_id
                                .as_ref()
                                .map_or(view.conversation.thread_id.as_str(), JobId::as_str),
                        },
                        &request.text,
                    )
                    .map_err(|error| RpcError::new(RpcCode::InvalidParams, error.to_string()))?
                }
                Origin::Unknown { .. } => {
                    return Err(RpcError::new(
                        RpcCode::InvalidRequest,
                        "message sender is unproven",
                    ));
                }
            };
            let at_ms = now_ms();
            store
                .admit_message(MessageRecord {
                    delivery_id: request.delivery_id.clone(),
                    request_fingerprint,
                    payload_fingerprint: fingerprint(text.as_bytes()),
                    sender,
                    requested_target: request.target,
                    text: Some(text),
                    resolved: None,
                    delivery_state: DeliveryState::Pending,
                    created_at_ms: at_ms,
                    updated_at_ms: at_ms,
                })
                .await?
        };
        if record.settled() {
            return Ok(json!(record));
        }
        if record.resolved.is_none() {
            if record.delivery_state != DeliveryState::Pending {
                return Ok(json!(record));
            }
            let resolved = match self.resolve_message_target(&record).await {
                Ok(resolved) => resolved,
                Err(error) => {
                    record = store
                        .update_message(
                            record.delivery_id,
                            DeliveryState::Failed {
                                reason: bounded_reason(&format!("{error:#}")),
                            },
                            now_ms(),
                        )
                        .await?;
                    return Ok(json!(record));
                }
            };
            record = store
                .resolve_message(record.delivery_id, resolved, now_ms())
                .await?;
        }
        let resolved = record
            .resolved
            .as_ref()
            .context("message resolution was not frozen")?;
        let text = record
            .text
            .as_deref()
            .context("unacknowledged message payload is unavailable")?;
        let attempt = match record.delivery_state {
            DeliveryState::Sending { attempt } => attempt.saturating_add(1),
            _ => 1,
        };
        store
            .update_message(
                record.delivery_id.clone(),
                DeliveryState::Sending { attempt },
                now_ms(),
            )
            .await?;
        let state = if let Some(continuation) = &resolved.continuation {
            drop(operation);
            match self.jobs.continue_job(ContinueParams {
                job_id: continuation.job_id.clone(), agent_id: continuation.agent_id.clone(), prompt: text.to_owned(), settings: None,
                expected_previous_job_id: Some(continuation.previous_job_id.clone()), intent: ContinueIntent::Message, recipient: ContinueRecipient::Previous, caller: request.caller,
            }, record.sender.clone()).await {
                Ok(receipt) => DeliveryState::Accepted { receipt: json!({"jobId":receipt.job.job_id,"duplicate":receipt.duplicate,"admitted":true,"consumed":false}).to_string() },
                Err(error) => DeliveryState::Blocked { reason: bounded_reason(&format!("{error:#}")) },
            }
        } else {
            let execution = match &resolved.target_job_id {
                Some(id) => match store.message_execution(id.clone()).await {
                    Ok(execution) => Some(execution),
                    Err(error) => {
                        record = store
                            .update_message(
                                record.delivery_id.clone(),
                                DeliveryState::Uncertain {
                                    reason: bounded_reason(&format!("{error:#}")),
                                },
                                now_ms(),
                            )
                            .await?;
                        return Ok(json!(record));
                    }
                },
                None => None,
            };
            let gateway = self.jobs.gateway()?;
            let response = gateway
                .deliver_job_input(&resolved.conversation, &record.delivery_id, text)
                .await;
            drop(execution);
            match response {
                Ok(response) => serde_json::from_value(response["deliveryState"].clone())
                    .unwrap_or_else(|error| DeliveryState::Uncertain {
                        reason: bounded_reason(&format!(
                            "provider returned unreadable delivery evidence: {error}"
                        )),
                    }),
                Err(error) => DeliveryState::Uncertain {
                    reason: bounded_reason(&error.message),
                },
            }
        };

        record = store
            .update_message(record.delivery_id, state, now_ms())
            .await?;
        Ok(json!(record))
    }

    async fn resolve_message_target(&self, record: &MessageRecord) -> Result<ResolvedMessage> {
        let resolved = match &record.requested_target {
            MessageTarget::Selector { selector } => {
                self.resolve_message_selector(selector, &record.delivery_id)
                    .await?
            }
            MessageTarget::Conversation { conversation } => {
                match self.jobs.agent_for_conversation(conversation).await? {
                    Some(agent) => {
                        self.resolve_message_job(
                            agent
                                .latest_job_id
                                .context("target conversation's current job is unresolved")?,
                            &record.delivery_id,
                        )
                        .await?
                    }
                    None => ResolvedMessage {
                        conversation: conversation.clone(),
                        target_job_id: None,
                        continuation: None,
                    },
                }
            }
            MessageTarget::Job { job_id } => {
                self.resolve_message_job(job_id.clone(), &record.delivery_id)
                    .await?
            }
            MessageTarget::Parent => {
                let Origin::Parent { conversation } = &record.sender else {
                    bail!("operator intent has no parent");
                };
                let agent = self
                    .jobs
                    .agent_for_conversation(conversation)
                    .await?
                    .context("caller has no delegated-agent recipient")?;
                let latest = agent
                    .latest_job_id
                    .context("caller's current job is unresolved")?;
                let Recipient::Conversation { conversation } =
                    self.jobs.read(&latest).await?.job.recipient
                else {
                    bail!("caller has no proven parent recipient");
                };
                ResolvedMessage {
                    conversation,
                    target_job_id: None,
                    continuation: None,
                }
            }
        };
        ensure!(
            self.agent_conversation(&resolved.conversation.thread_id)? == resolved.conversation,
            "message target belongs to another provider home"
        );
        Ok(resolved)
    }

    async fn resolve_message_selector(
        &self,
        selector: &str,
        delivery_id: &str,
    ) -> Result<ResolvedMessage> {
        if let Ok(job_id) = JobId::try_from(selector.to_owned()) {
            return self.resolve_message_job(job_id, delivery_id).await;
        }
        ensure!(
            selector.len() >= 4 && selector.len() <= 512,
            "use an exact run ID, provider session ID or suffix of 4–512 bytes"
        );
        let mut cursor = None;
        let mut matches = Vec::new();
        for page_index in 0..50 {
            let page = self
                .jobs
                .store()
                .await?
                .list(crate::agents::jobs::store::Selection::Recent, 200, cursor)
                .await?;
            matches.extend(page.jobs.into_iter().filter(|row| row.job_id.as_str().ends_with(selector) || matches!(&row.conversation, ConversationBinding::Known { conversation } if conversation.thread_id == selector || conversation.thread_id.strip_prefix("claude_") == Some(selector))));
            cursor = page.next_cursor;
            if cursor.is_none() {
                break;
            }
            ensure!(
                page_index < 49,
                "job discovery exceeded 10,000 records; use an exact run ID"
            );
        }
        let suffixes = matches
            .iter()
            .filter(|row| row.job_id.as_str().ends_with(selector))
            .collect::<Vec<_>>();
        if let [row] = suffixes.as_slice() {
            return self
                .resolve_message_job(row.job_id.clone(), delivery_id)
                .await;
        }
        ensure!(
            suffixes.is_empty(),
            "job selector is ambiguous; use an exact run ID"
        );
        if let Some(first) = matches.first() {
            ensure!(
                matches.iter().all(|row| row.agent_id == first.agent_id),
                "conversation selector is ambiguous; use an exact run ID"
            );
            let agent = self
                .jobs
                .store()
                .await?
                .agent(first.agent_id.clone())
                .await?;
            return self
                .resolve_message_job(
                    agent
                        .latest_job_id
                        .context("conversation's latest job is unresolved")?,
                    delivery_id,
                )
                .await;
        }
        let header = if selector.starts_with("claude_") {
            self.claude_thread_response(&json!({"threadId":selector}))
                .await
                .map_err(|error| anyhow::anyhow!(error.message))?["thread"]
                .clone()
        } else if let Some(id) = selector.strip_prefix("codex:") {
            self.call_control("thread/read", json!({"threadId":id,"includeTurns":false}))
                .await?["thread"]
                .clone()
        } else {
            bail!(
                "native conversation provider is unknown; use an explicit claude_UUID or codex:UUID selector"
            );
        };
        let conversation = crate::agents::conversation_from_header(&header)?;
        ensure!(
            conversation.thread_id == selector
                || conversation.thread_id.strip_prefix("claude_") == Some(selector)
                || selector.strip_prefix("codex:") == Some(conversation.thread_id.as_str()),
            "provider returned a different native conversation"
        );
        if let Some(agent) = self.jobs.agent_for_conversation(&conversation).await? {
            return self
                .resolve_message_job(
                    agent
                        .latest_job_id
                        .context("conversation's latest job is unresolved")?,
                    delivery_id,
                )
                .await;
        }
        Ok(ResolvedMessage {
            conversation,
            target_job_id: None,
            continuation: None,
        })
    }

    async fn resolve_message_job(
        &self,
        job_id: JobId,
        delivery_id: &str,
    ) -> Result<ResolvedMessage> {
        let view = self.jobs.read(&job_id).await?;
        let agent = view.agent.context("target conversation is unresolved")?;
        ensure!(
            agent.latest_job_id.as_ref() == Some(&job_id),
            "target job has been superseded; use its latest job"
        );
        let ConversationBinding::Known { conversation } = agent.conversation else {
            bail!("target provider identity is unresolved");
        };
        ensure!(
            matches!(
                view.job.stop,
                crate::agents::jobs::model::StopState::NotRequested
            ) && !matches!(&view.job.execution, ExecutionState::Terminal { terminal } if matches!(terminal.outcome, crate::agents::jobs::model::JobOutcome::Stopped { .. })),
            "automatic message continuation cannot clear Stop; use explicit Continue to restart deliberately"
        );
        let continuation = if matches!(view.job.execution, ExecutionState::Terminal { .. })
            || (view.job.source == JobSource::Imported
                && matches!(view.job.execution, ExecutionState::Unknown { .. }))
        {
            Some(MessageContinuation {
                agent_id: agent.agent_id,
                previous_job_id: job_id.clone(),
                job_id: JobId::for_mutation(conversation.provider, delivery_id)
                    .map_err(anyhow::Error::msg)?,
            })
        } else {
            ensure!(
                matches!(
                    view.job.execution,
                    ExecutionState::Running { .. } | ExecutionState::Recovering { .. }
                ),
                "target job is not ready for messages; inspect its current execution state"
            );
            None
        };
        Ok(ResolvedMessage {
            conversation,
            target_job_id: Some(job_id),
            continuation,
        })
    }
}

#[cfg(test)]
mod tests;
