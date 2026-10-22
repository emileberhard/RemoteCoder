use super::transport::ClientFrame;
use super::{ClientTx, Gateway};
use crate::notifications::history::{NotificationOrigin, Recorded, ReplayRequest};
use crate::notifications::{notification_thread_id, should_store_notification_method};
use crate::storage::tool_media::ToolMediaStore;
use crate::time::unix_seconds;
use crate::wire::tool_media::may_carry_tool_media;
use anyhow::Result;
use serde_json::Value;
use tracing::warn;

impl Gateway {
    /// Records an agent notification for replay and push side effects.
    ///
    /// Shared by the Codex control reader and the Claude translator so both
    /// providers get identical replay history, APNs, and Live Activity behavior.
    pub(super) async fn record_agent_notification(
        &self,
        raw: &str,
        origin: NotificationOrigin,
    ) -> Option<u64> {
        let parsed = serde_json::from_str::<Value>(raw).ok()?;
        self.record_agent_notification_value(raw, &parsed, origin)
            .await
    }

    pub(super) async fn record_agent_notification_value(
        &self,
        raw: &str,
        message: &Value,
        origin: NotificationOrigin,
    ) -> Option<u64> {
        let compacted = match compact_notification(raw, message, self.tool_media.as_ref()).await {
            Ok(compacted) => compacted,
            Err(error) => {
                warn!(%error, "failed to encode notification for replay");
                return None;
            }
        };
        let history_raw = compacted
            .as_ref()
            .map_or(Some(raw), |(frame, _)| frame.text());
        self.record_agent_notification_for_clients(history_raw, message, origin)
            .await
    }

    async fn record_agent_notification_for_clients(
        &self,
        raw: Option<&str>,
        message: &Value,
        origin: NotificationOrigin,
    ) -> Option<u64> {
        // Server requests are not notifications. Keeping them out of history
        // also preserves their byte-identical forwarding contract.
        if message.get("id").is_some() {
            return None;
        }
        let method = message.get("method").and_then(Value::as_str)?;
        if !should_store_notification_method(method) {
            return None;
        }
        self.questions.ingest(message).await;
        let thread_id = notification_thread_id(message);
        let recorded = match raw {
            Some(raw) => {
                self.record_notification_history(raw, thread_id.clone(), origin)
                    .await
            }
            None => self
                .core
                .lock()
                .await
                .notification_history
                .record_unretained(),
        };
        self.review.ingest(message, recorded.is_new);
        if recorded.is_new
            && let Some(thread_id) = thread_id
        {
            self.record_thread_lifecycle(method, &thread_id).await;
        }

        if let Some((_method, _key, apns, live_activity)) =
            self.capture_agent_message(message).await
        {
            if let Some(apns) = apns
                && !self.is_planned_interruption(method, message)
                && let Some(tx) = self.apns_completion_tx.lock().await.clone()
            {
                let _ = tx.try_send(apns);
            }
            if let Some(live_activity) = live_activity {
                self.publish_live_activity(live_activity).await;
            }
        }
        Some(recorded.sequence)
    }

    pub(super) async fn prepare_forwarded_notification(
        &self,
        raw: &str,
        message: &Value,
        origin: NotificationOrigin,
    ) -> Result<ClientFrame> {
        let compacted = compact_notification(raw, message, self.tool_media.as_ref()).await?;
        let (frame, client_message) = match compacted {
            Some((frame, compacted)) => (frame, Some(compacted)),
            None => (ClientFrame::from_raw(raw), None),
        };
        let sequence = self
            .record_agent_notification_for_clients(frame.text(), message, origin)
            .await;
        frame.stamp(client_message.as_ref().unwrap_or(message), sequence)
    }

    /// Feeds a provider-generated notification into the same funnel as Codex
    /// Codex traffic: replay history, push side effects, then client fanout.
    pub(crate) async fn ingest_agent_notification(&self, mut message: Value) {
        self.forward_voice_agent_notification(&message).await;
        let frame = match ClientFrame::prepare(&mut message, self.tool_media.as_ref()).await {
            Ok(frame) => frame,
            Err(error) => {
                warn!(%error, "failed to encode provider notification");
                return;
            }
        };
        let sequence = self
            .record_agent_notification_for_clients(
                frame.text(),
                &message,
                NotificationOrigin::Provider,
            )
            .await;
        match frame.stamp(&message, sequence) {
            Ok(frame) => self.broadcast_claude_content(&frame, &message),
            Err(error) => warn!(%error, "failed to annotate provider notification"),
        }
    }

    pub(super) async fn notification_floor(&self) -> u64 {
        self.core
            .lock()
            .await
            .notification_history
            .latest_sequence()
    }

    pub(super) async fn notification_position(&self) -> (String, u64) {
        let core = self.core.lock().await;
        (
            core.notification_history.epoch().to_owned(),
            core.notification_history.latest_sequence(),
        )
    }

    #[cfg(test)]
    pub(super) async fn push_notification_history(
        &self,
        raw: &str,
        thread_id: Option<String>,
        origin: NotificationOrigin,
    ) -> u64 {
        self.record_notification_history(raw, thread_id, origin)
            .await
            .sequence
    }

    async fn record_notification_history(
        &self,
        raw: &str,
        thread_id: Option<String>,
        origin: NotificationOrigin,
    ) -> Recorded {
        self.core
            .lock()
            .await
            .notification_history
            .record(raw, thread_id, origin, unix_seconds())
    }

    pub(super) async fn handle_daemon_replay_notifications(
        &self,
        out_tx: &ClientTx,
        req_id: Option<Value>,
        params: Option<Value>,
    ) -> Result<()> {
        let request = ReplayRequest::from_params(params.as_ref());
        let page = self
            .core
            .lock()
            .await
            .notification_history
            .replay(&request, unix_seconds());
        let msg = serde_json::json!({
            "id": req_id.unwrap_or(Value::Null),
            "result": page.into_wire(unix_seconds()),
        });
        self.send_json_awaiting_capacity(out_tx, &msg).await
    }
}

pub(super) async fn compact_notification(
    raw: &str,
    message: &Value,
    media: Option<&ToolMediaStore>,
) -> Result<Option<(ClientFrame, Value)>> {
    if !may_carry_tool_media(raw) {
        return Ok(None);
    }
    let mut compacted = message.clone();
    Ok(ClientFrame::compact(&mut compacted, media)
        .await?
        .map(|frame| (frame, compacted)))
}
