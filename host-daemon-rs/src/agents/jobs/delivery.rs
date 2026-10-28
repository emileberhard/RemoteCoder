use anyhow::{Context, Result};

use super::model::*;
use super::owner::{JobOwner, now_ms};

impl JobOwner {
    pub(crate) async fn deliver_notices(&self, id: &JobId) -> Result<bool> {
        let store = self.store().await?;
        let original = store.read(id.clone()).await?;
        if original.source != JobSource::Runtime {
            return Ok(false);
        }
        if matches!(
            &original.recipient,
            Recipient::None | Recipient::Unknown { .. }
        ) {
            return Ok(false);
        }
        let gateway = self.gateway()?;
        if gateway.is_draining() {
            return Ok(false);
        }
        let mut retry = false;
        for notice in original.notices {
            let CompletionPayload::Prepared {
                delivery_id, text, ..
            } = notice.payload
            else {
                continue;
            };
            if matches!(
                notice.delivery,
                DeliveryState::Accepted { .. }
                    | DeliveryState::Recorded { .. }
                    | DeliveryState::Dismissed { .. }
            ) {
                continue;
            }
            if notice
                .at_ms
                .is_some_and(|at| now_ms().saturating_sub(at) >= 24 * 60 * 60 * 1000)
                && matches!(
                    notice.delivery,
                    DeliveryState::Unreachable { .. } | DeliveryState::Uncertain { .. }
                )
            {
                gateway.surface_job_result(id,"receiver could not be reconciled within 24 hours; notice requires user attention").await?;
                continue;
            }
            let current = store.read(id.clone()).await?;
            let sending = store
                .notice_delivery(
                    id.clone(),
                    current.revision,
                    delivery_id.clone(),
                    DeliveryState::Sending { attempt: 1 },
                    now_ms(),
                )
                .await?;
            let next = match gateway
                .deliver_job_recipient(&original.recipient, &delivery_id, &text)
                .await
            {
                Ok(state) => state,
                Err(error) => DeliveryState::Uncertain {
                    reason: error.to_string(),
                },
            };
            retry |= matches!(
                next,
                DeliveryState::Pending
                    | DeliveryState::Sending { .. }
                    | DeliveryState::Submitted { .. }
                    | DeliveryState::Uncertain { .. }
                    | DeliveryState::Blocked { .. }
                    | DeliveryState::Unreachable { .. }
            );
            store
                .notice_delivery(id.clone(), sending.revision, delivery_id, next, now_ms())
                .await?;
        }
        Ok(retry)
    }

    pub(crate) async fn deliver_completion(
        &self,
        job: &JobRecord,
        terminal: &Terminal,
    ) -> Result<bool> {
        let Completion::Required {
            payload:
                CompletionPayload::Prepared {
                    delivery_id, text, ..
                },
            delivery,
        } = &terminal.completion
        else {
            return Ok(false);
        };
        if matches!(
            delivery,
            DeliveryState::Accepted { .. }
                | DeliveryState::Recorded { .. }
                | DeliveryState::Dismissed { .. }
        ) {
            return Ok(false);
        }
        let job = self
            .store()
            .await?
            .retarget_delivery(job.job_id.clone())
            .await?;
        let gateway = self.gateway()?;
        if let Recipient::Remote { host, .. } = &job.recipient
            && !gateway.remote_receiver_active(host).await?
        {
            let reason = "receiver host was removed; prior acceptance cannot be reconciled";
            self.store()
                .await?
                .delivery(
                    job.job_id.clone(),
                    job.revision,
                    DeliveryState::Uncertain {
                        reason: reason.into(),
                    },
                    now_ms(),
                )
                .await?;
            gateway.surface_job_result(&job.job_id, reason).await?;
            return Ok(false);
        }
        if matches!(job.recipient, Recipient::None) {
            gateway
                .surface_job_result(
                    &job.job_id,
                    "agent was promoted; its result is available to the user",
                )
                .await?;
            let current = self.store().await?.read(job.job_id.clone()).await?;
            self.store()
                .await?
                .delivery(
                    job.job_id.clone(),
                    current.revision,
                    DeliveryState::Dismissed {
                        reason: "result surfaced to the user after promotion".into(),
                    },
                    now_ms(),
                )
                .await?;
            return Ok(false);
        }
        if let ExecutionState::Terminal { terminal } = &job.execution {
            if let Completion::Required { delivery, .. } = &terminal.completion {
                if terminal
                    .at_ms
                    .is_some_and(|at| now_ms().saturating_sub(at) >= 24 * 60 * 60 * 1000)
                    && matches!(
                        delivery,
                        DeliveryState::Unreachable { .. } | DeliveryState::Uncertain { .. }
                    )
                {
                    if matches!(delivery, DeliveryState::Unreachable { .. }) {
                        self.store().await?.delivery(job.job_id.clone(),job.revision,DeliveryState::Uncertain {reason:"receiver could not be reconciled within 24 hours; result requires user attention".into()},now_ms()).await?;
                    }
                    gateway.surface_job_result(&job.job_id,"receiver could not be reconciled within 24 hours; result requires user attention").await?;
                    return Ok(false);
                }
            }
        }
        let gateway = self.gateway()?;
        if gateway.is_draining() {
            return Ok(false);
        }
        let attempt = match delivery {
            DeliveryState::Sending { attempt } => attempt
                .checked_add(1)
                .context("delivery attempt counter exhausted")?,
            _ => 1,
        };
        let sending = self
            .store()
            .await?
            .delivery(
                job.job_id.clone(),
                job.revision,
                DeliveryState::Sending { attempt },
                now_ms(),
            )
            .await?;
        let next = match gateway
            .deliver_job_recipient(&job.recipient, delivery_id, text)
            .await
        {
            Ok(state) => state,
            Err(error) => DeliveryState::Uncertain {
                reason: error.to_string(),
            },
        };
        let retry = matches!(
            next,
            DeliveryState::Pending
                | DeliveryState::Sending { .. }
                | DeliveryState::Submitted { .. }
                | DeliveryState::Uncertain { .. }
                | DeliveryState::Blocked { .. }
                | DeliveryState::Unreachable { .. }
        );
        self.store()
            .await?
            .delivery(job.job_id.clone(), sending.revision, next, now_ms())
            .await?;
        Ok(retry)
    }
}
