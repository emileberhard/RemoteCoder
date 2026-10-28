use serde::{Deserialize, Serialize};

use super::*;
use crate::wire::agent_jobs::MessageTarget;

const MESSAGE_RESERVATION: u64 = 2 * MAX_JOB_BYTES;
const MESSAGE_HEADROOM: u64 = 64 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct MessageRecord {
    pub delivery_id: String,
    pub request_fingerprint: String,
    pub payload_fingerprint: String,
    pub sender: Origin,
    pub requested_target: MessageTarget,
    pub text: Option<String>,
    pub resolved: Option<ResolvedMessage>,
    pub delivery_state: DeliveryState,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ResolvedMessage {
    #[serde(default)]
    pub remote_recipient: Option<Recipient>,
    pub conversation: ConversationIdentity,
    pub target_job_id: Option<JobId>,
    pub continuation: Option<MessageContinuation>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct MessageContinuation {
    pub agent_id: String,
    pub previous_job_id: JobId,
    pub job_id: JobId,
}

fn bound_state(mut state: DeliveryState) -> DeliveryState {
    let text = match &mut state {
        DeliveryState::Submitted { route } => Some(route),
        DeliveryState::Accepted { receipt } | DeliveryState::Recorded { receipt } => Some(receipt),
        DeliveryState::Uncertain { reason }
        | DeliveryState::Blocked { reason }
        | DeliveryState::Unreachable { reason }
        | DeliveryState::Dismissed { reason }
        | DeliveryState::Failed { reason } => Some(reason),
        DeliveryState::Pending | DeliveryState::Sending { .. } => None,
    };
    if let Some(text) = text
        && let Some((boundary, _)) = text.char_indices().nth(4096)
    {
        text.truncate(boundary);
        text.push_str(" [truncated]");
    }

    state
}

impl MessageRecord {
    pub(crate) fn acknowledged(&self) -> bool {
        matches!(
            self.delivery_state,
            DeliveryState::Submitted { .. }
                | DeliveryState::Accepted { .. }
                | DeliveryState::Recorded { .. }
        )
    }

    pub(crate) fn settled(&self) -> bool {
        self.acknowledged()
            || matches!(self.delivery_state, DeliveryState::Dismissed { .. })
            || (self.resolved.is_none()
                && matches!(self.delivery_state, DeliveryState::Failed { .. }))
    }

    fn reserved(&self) -> bool {
        !self.settled()
    }
}

impl JobStore {
    pub(crate) async fn message(&self, delivery_id: String) -> Result<MessageRecord> {
        self.access(move |inner| {
            inner
                .messages
                .get(&delivery_id)
                .cloned()
                .context("message receipt does not exist")
        })
        .await
    }

    pub(crate) async fn existing_message(
        &self,
        id: String,
        request_fingerprint: String,
    ) -> Result<Option<MessageRecord>> {
        self.access(move |inner| {
            inner
                .messages
                .get(&id)
                .map(|record| {
                    ensure!(
                        record.request_fingerprint == request_fingerprint,
                        "delivery ID was already used for a different sender, target or message"
                    );
                    Ok(record.clone())
                })
                .transpose()
        })
        .await
    }

    pub(crate) async fn admit_message(&self, record: MessageRecord) -> Result<MessageRecord> {
        self.ensure_new_message_id(record.delivery_id.clone())
            .await?;
        self.access(move |inner| {
            ensure!(!record.delivery_id.is_empty() && record.delivery_id.len() <= 512, "message delivery ID must contain 1–512 bytes");
            if let Some(existing) = inner.messages.get(&record.delivery_id) {
                ensure!(existing.request_fingerprint == record.request_fingerprint, "delivery ID was already used for a different sender, target or message");
                return Ok(existing.clone());
            }
            ensure!(record.payload_fingerprint == fingerprint(record.text.as_deref().context("message admission has no payload")?.as_bytes()), "message envelope fingerprint differs from its frozen payload");
            ensure!(record.request_fingerprint.len() == 64 && record.text.is_some() && record.resolved.is_none() && record.delivery_state == DeliveryState::Pending, "message admission requires attributed immutable input");
            ensure!(serde_json::to_vec(&record)?.len() as u64 + MESSAGE_HEADROOM <= MAX_JOB_BYTES, "encoded message leaves insufficient receipt space; shorten the text or reference a file");
            ensure!(inner.messages.values().filter(|record| record.reserved()).count() < MAX_UNSETTLED_JOBS, "unresolved message receipt capacity reached; inspect existing receipts before sending more");
            inner.reclaim(record.created_at_ms, MESSAGE_RESERVATION)?;
            ensure!(inner.accounted_bytes()? + MESSAGE_RESERVATION + MUTATION_RESERVE <= MAX_STORE_BYTES, "delegated-job storage is pinned at its cap; resolve retained work and message receipts before sending more");
            inner.write_message(&record)?;
            inner.messages.insert(record.delivery_id.clone(), record.clone());
            Ok(record)
        }).await
    }

    pub(crate) async fn resolve_message(
        &self,
        id: String,
        resolved: ResolvedMessage,
        at_ms: i64,
    ) -> Result<MessageRecord> {
        self.access(move |inner| {
            let mut record = inner
                .messages
                .get(&id)
                .cloned()
                .context("message receipt does not exist")?;
            ensure!(
                record.resolved.is_none() && record.delivery_state == DeliveryState::Pending,
                "message resolution is already frozen"
            );
            record.resolved = Some(resolved);
            record.updated_at_ms = at_ms;
            inner.write_message(&record)?;
            inner.messages.insert(id, record.clone());
            Ok(record)
        })
        .await
    }

    pub(crate) async fn update_message(
        &self,
        id: String,
        state: DeliveryState,
        at_ms: i64,
    ) -> Result<MessageRecord> {
        self.access(move |inner| {
            let mut record = inner
                .messages
                .get(&id)
                .cloned()
                .context("message receipt does not exist")?;
            ensure!(!record.settled(), "settled message receipt is immutable");
            record.delivery_state = bound_state(state);
            record.updated_at_ms = at_ms;
            inner.write_message(&record)?;
            inner.messages.insert(id, record.clone());
            Ok(record)
        })
        .await
    }
}

impl Inner {
    pub(super) fn load_messages(&mut self) -> Result<()> {
        private_state::ensure_private_directory(&self.root.join("messages"))?;
        for entry in std::fs::read_dir(self.root.join("messages"))? {
            let entry = entry?;
            if entry
                .path()
                .extension()
                .is_none_or(|extension| extension != "json")
            {
                continue;
            }
            let record: MessageRecord = read(&entry.path(), MAX_JOB_BYTES)?;
            ensure!(
                !record.delivery_id.is_empty()
                    && record.delivery_id.len() <= 512
                    && record.request_fingerprint.len() == 64,
                "invalid persisted message receipt"
            );
            ensure!(
                record.payload_fingerprint.len() == 64
                    && record.text.as_ref().is_none_or(
                        |text| fingerprint(text.as_bytes()) == record.payload_fingerprint
                    ),
                "persisted message envelope differs from its fingerprint"
            );
            ensure!(
                entry.path() == self.message_path(&record.delivery_id),
                "message filename differs from its identity"
            );
            ensure!(
                self.messages
                    .insert(record.delivery_id.clone(), record)
                    .is_none(),
                "duplicate persisted message identity"
            );
        }
        Ok(())
    }

    fn message_path(&self, id: &str) -> PathBuf {
        self.root
            .join("messages")
            .join(format!("{}.json", fingerprint(id.as_bytes())))
    }

    fn write_message(&self, record: &MessageRecord) -> Result<()> {
        let bytes = serde_json::to_vec(record)?;
        ensure!(
            bytes.len() as u64 <= MAX_JOB_BYTES,
            "message receipt exceeds its record budget"
        );
        ensure!(
            tree_bytes(&self.root)? + bytes.len() as u64 <= MAX_STORE_BYTES,
            "message receipt cannot commit within the delegated-job store cap"
        );
        private_state::replace(&self.message_path(&record.delivery_id), &bytes)
    }

    pub(super) fn message_reservations(&self) -> Result<u64> {
        self.messages
            .values()
            .filter(|record| record.reserved())
            .try_fold(0, |total, record| {
                Ok(total
                    + MESSAGE_RESERVATION.saturating_sub(
                        std::fs::metadata(self.message_path(&record.delivery_id))?.len(),
                    ))
            })
    }

    pub(super) fn reclaim_messages(&mut self, now: i64) -> Result<()> {
        let expired = self
            .messages
            .values()
            .filter(|record| {
                !record.reserved()
                    && record.text.is_some()
                    && now.saturating_sub(record.updated_at_ms) >= RETENTION_MS
            })
            .map(|record| record.delivery_id.clone())
            .collect::<Vec<_>>();
        for id in expired {
            let mut record = self.messages[&id].clone();
            record.text = None;
            self.write_message(&record)?;
            self.messages.insert(id, record);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests;
