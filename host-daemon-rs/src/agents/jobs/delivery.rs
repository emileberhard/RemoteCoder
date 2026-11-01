use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use serde_json::json;

use super::model::*;
use super::owner::{JobOwner, now_ms};
use super::store::delivery_settled;
use crate::gateway::Gateway;

const DELIVERY_WINDOW_MS: i64 = 24 * 60 * 60 * 1000;
const WINDOW_EXPIRED: &str = "receiver could not be reconciled within 24 hours";

#[derive(Clone, Copy)]
enum Duty {
    Notice,
    Completion,
}

struct Obligation {
    duty: Duty,
    delivery_id: String,
    text: String,
    state: DeliveryState,
    at_ms: Option<i64>,
}

impl JobOwner {
    pub(crate) async fn deliver_obligations(&self, job: JobRecord) -> Result<()> {
        let gateway = self.gateway()?;
        if job.source != JobSource::Runtime || gateway.is_draining() {
            return Ok(());
        }
        let job = self.supersede_notices(&gateway, job).await?;
        for obligation in obligations(&job) {
            self.deliver(&gateway, &job, obligation).await?;
        }
        Ok(())
    }

    async fn supersede_notices(&self, gateway: &Gateway, job: JobRecord) -> Result<JobRecord> {
        let superseded: Vec<_> = job
            .notices
            .iter()
            .filter(|notice| !delivery_settled(&notice.delivery))
            .map(|notice| {
                (
                    notice.payload.delivery_id().map(str::to_owned),
                    notice.delivery.clone(),
                )
            })
            .collect();
        if !matches!(job.execution, ExecutionState::Terminal { .. }) || superseded.is_empty() {
            return Ok(job);
        }
        let to = DeliveryState::Dismissed {
            reason: "superseded by the final result".into(),
        };
        let job = self
            .store()
            .await?
            .dismiss_notices(job.job_id.clone(), job.revision, to.clone(), now_ms())
            .await?;
        for (delivery_id, from) in superseded {
            if let Some(delivery_id) = &delivery_id {
                self.deliveries.forget(&job.job_id, delivery_id);
            }
            journal(gateway, &job.job_id, delivery_id.as_deref(), &from, &to);
        }
        Ok(job)
    }

    async fn deliver(
        &self,
        gateway: &Arc<Gateway>,
        job: &JobRecord,
        obligation: Obligation,
    ) -> Result<()> {
        let age = obligation.at_ms.map(|at| now_ms().saturating_sub(at));
        let expired = age.is_none_or(|age| age >= DELIVERY_WINDOW_MS);
        let custody = matches!(
            obligation.state,
            DeliveryState::Sending { .. }
                | DeliveryState::Submitted { .. }
                | DeliveryState::Uncertain { .. }
        );
        let never_accepted = matches!(
            obligation.state,
            DeliveryState::Pending
                | DeliveryState::Unreachable { .. }
                | DeliveryState::Blocked { .. }
        );
        let removed = match &job.recipient {
            Recipient::Remote { host, .. } => !gateway.remote_receiver_active(host).await?,
            _ => false,
        };
        let hand_off = match &job.recipient {
            Recipient::Unknown { reason } => Some(reason.clone()),
            Recipient::None => {
                Some("agent was promoted; its result is available to the user".into())
            }
            _ if removed => Some("receiver host was removed; delivery cannot be reconciled".into()),
            _ if expired && never_accepted => Some(WINDOW_EXPIRED.into()),
            _ => None,
        };
        if let Some(reason) = hand_off {
            return self.hand_off(gateway, job, &obligation, reason).await;
        }
        let age = Duration::from_millis(age.unwrap_or(DELIVERY_WINDOW_MS).try_into().unwrap_or(0));
        if !self
            .deliveries
            .claim(&job.job_id, &obligation.delivery_id, age)
        {
            return Ok(());
        }
        if !custody {
            self.record(
                gateway,
                &job.job_id,
                &obligation,
                DeliveryState::Sending { attempt: 1 },
            )
            .await?;
        }
        let next = gateway
            .deliver_job_recipient(
                &job.recipient,
                &obligation.delivery_id,
                &obligation.text,
                &obligation.state,
            )
            .await
            .unwrap_or_else(|error| DeliveryState::Uncertain {
                reason: error.to_string(),
            });
        self.record(gateway, &job.job_id, &obligation, next.clone())
            .await?;
        match next {
            next if delivery_settled(&next) => {
                self.deliveries.forget(&job.job_id, &obligation.delivery_id);
                Ok(())
            }
            DeliveryState::Failed { reason } => {
                self.hand_off(gateway, job, &obligation, reason).await
            }
            _ if expired => {
                self.hand_off(gateway, job, &obligation, WINDOW_EXPIRED.into())
                    .await
            }
            _ => Ok(()),
        }
    }

    async fn hand_off(
        &self,
        gateway: &Arc<Gateway>,
        job: &JobRecord,
        obligation: &Obligation,
        reason: String,
    ) -> Result<()> {
        self.deliveries.forget(&job.job_id, &obligation.delivery_id);
        match obligation.duty {
            Duty::Completion => gateway.surface_job_result(&job.job_id, &reason).await,
            Duty::Notice => {
                self.record(
                    gateway,
                    &job.job_id,
                    obligation,
                    DeliveryState::Dismissed { reason },
                )
                .await
            }
        }
    }

    async fn record(
        &self,
        gateway: &Gateway,
        id: &JobId,
        obligation: &Obligation,
        next: DeliveryState,
    ) -> Result<()> {
        let store = self.store().await?;
        let job = store.read(id.clone()).await?;
        let delivery_id = &obligation.delivery_id;
        let previous = match obligation.duty {
            Duty::Notice => job
                .notices
                .iter()
                .find(|notice| notice.payload.delivery_id() == Some(delivery_id.as_str()))
                .map(|notice| &notice.delivery),
            Duty::Completion => match &job.execution {
                ExecutionState::Terminal { terminal } => match &terminal.completion {
                    Completion::Required { delivery, .. } => Some(delivery),
                    Completion::NotRequired => None,
                },
                _ => None,
            },
        }
        .context("delivery obligation disappeared")?
        .clone();
        if previous == next {
            return Ok(());
        }
        match obligation.duty {
            Duty::Notice => {
                store
                    .notice_delivery(
                        id.clone(),
                        job.revision,
                        delivery_id.clone(),
                        next.clone(),
                        now_ms(),
                    )
                    .await?
            }
            Duty::Completion => {
                store
                    .delivery(id.clone(), job.revision, next.clone(), now_ms())
                    .await?
            }
        };
        journal(gateway, id, Some(delivery_id), &previous, &next);
        Ok(())
    }
}

fn obligations(job: &JobRecord) -> Vec<Obligation> {
    let mut obligations: Vec<_> = job
        .notices
        .iter()
        .filter_map(|notice| {
            obligation(
                Duty::Notice,
                &notice.payload,
                &notice.delivery,
                notice.at_ms,
            )
        })
        .collect();
    if let ExecutionState::Terminal { terminal } = &job.execution
        && terminal.cleanup == CleanupState::Complete
        && let Completion::Required { payload, delivery } = &terminal.completion
    {
        obligations.extend(obligation(
            Duty::Completion,
            payload,
            delivery,
            terminal.at_ms,
        ));
    }
    obligations
}

fn obligation(
    duty: Duty,
    payload: &CompletionPayload,
    state: &DeliveryState,
    at_ms: Option<i64>,
) -> Option<Obligation> {
    let CompletionPayload::Prepared {
        delivery_id, text, ..
    } = payload
    else {
        return None;
    };
    (!delivery_settled(state)).then(|| Obligation {
        duty,
        delivery_id: delivery_id.clone(),
        text: text.clone(),
        state: state.clone(),
        at_ms,
    })
}

fn journal(
    gateway: &Gateway,
    id: &JobId,
    delivery_id: Option<&str>,
    from: &DeliveryState,
    to: &DeliveryState,
) {
    gateway.journal().runtime(
        "agent_delivery",
        json!({"jobId": id, "deliveryId": delivery_id, "from": from, "to": to}),
    );
}

#[cfg(test)]
mod tests;
