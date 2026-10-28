use anyhow::{Context, Result};

use super::model::*;
use super::owner::{JobOwner, now_ms};

impl JobOwner {
    pub(super) async fn deliver_notices(&self, id: &JobId) -> Result<bool> {
        let store = self.store().await?;
        let original = store.read(id.clone()).await?;
        if original.source != JobSource::Runtime {
            return Ok(false);
        }
        let Recipient::Conversation { conversation } = &original.recipient else {
            return Ok(false);
        };
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
                .deliver_job_input(conversation, &delivery_id, &text, None)
                .await
            {
                Ok(value) => {
                    serde_json::from_value::<DeliveryState>(value["deliveryState"].clone())?
                }
                Err(error) => DeliveryState::Uncertain {
                    reason: error.message,
                },
            };
            retry |= matches!(
                next,
                DeliveryState::Pending
                    | DeliveryState::Sending { .. }
                    | DeliveryState::Submitted { .. }
                    | DeliveryState::Uncertain { .. }
                    | DeliveryState::Blocked { .. }
            );
            store
                .notice_delivery(id.clone(), sending.revision, delivery_id, next, now_ms())
                .await?;
        }
        Ok(retry)
    }

    pub(super) async fn deliver_completion(
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
        let Recipient::Conversation { conversation } = &job.recipient else {
            return Ok(false);
        };
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
            .deliver_job_input(conversation, delivery_id, text, None)
            .await
        {
            Ok(value) => serde_json::from_value::<DeliveryState>(value["deliveryState"].clone())?,
            Err(error) => DeliveryState::Uncertain {
                reason: error.message,
            },
        };
        let retry = matches!(
            next,
            DeliveryState::Pending
                | DeliveryState::Sending { .. }
                | DeliveryState::Submitted { .. }
                | DeliveryState::Uncertain { .. }
                | DeliveryState::Blocked { .. }
        );
        self.store()
            .await?
            .delivery(job.job_id.clone(), sending.revision, next, now_ms())
            .await?;
        Ok(retry)
    }
}
