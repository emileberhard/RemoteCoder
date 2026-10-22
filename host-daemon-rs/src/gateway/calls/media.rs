use super::{CallRecord, CallState, call_principal};
use crate::gateway::Gateway;
use crate::observability::journal::Source;
use crate::time::unix_seconds;
use crate::voice::session::VoiceSessionOrigin;
use crate::wire::gateway::{
    RealtimeVoiceInitialItem, RealtimeVoiceRole, RealtimeVoiceStartRequest,
};
use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;
use tracing::warn;

impl Gateway {
    pub(super) async fn start_call_media(
        self: &Arc<Self>,
        client_id: u64,
        record: CallRecord,
        sdp: String,
        voice: Option<String>,
    ) -> Result<Value> {
        let _admission = self.admission.admit(&record.conversation_thread_id)?;
        let brief = record.request.brief.voice_instructions(
            &record.call_id,
            record.request.to != "self",
            self.user_name.as_deref(),
        )?;
        if record.provider == "codex" {
            let context = record.backend_context(self.user_name.as_deref())?;
            self.call_control("thread/inject_items", json!({"threadId": record.conversation_thread_id,
                "items": [{"type": "message", "role": "developer", "content": [{"type": "input_text", "text": context}]}]})).await?;
        }
        let request = RealtimeVoiceStartRequest {
            conversation_thread_id: record.conversation_thread_id.clone(),
            realtime_session_id: record.call_id.clone(),
            replace_existing_session: false,
            cwd: record.cwd,
            model: record.model,
            effort: record.effort,
            sdp,
            voice,
            initial_items: vec![RealtimeVoiceInitialItem {
                role: RealtimeVoiceRole::Developer,
                text: brief,
            }],
        }
        .validate()?;
        match self
            .start_voice_session(client_id, request, VoiceSessionOrigin::AgentCall)
            .await
        {
            Ok(response) => {
                let log_path = self.voice.log_path(&record.call_id);
                self.calls
                    .change(&record.call_id, |record| {
                        record.voice_log_path = log_path;
                        Ok(())
                    })
                    .await?;
                serde_json::to_value(response).map_err(Into::into)
            }
            Err(error) => {
                let _ = self
                    .end_agent_call(&record.call_id, "voice startup failed")
                    .await;
                Err(error)
            }
        }
    }

    pub(super) async fn greet_connected_call(&self, record: &CallRecord) -> Result<()> {
        let thread_id = self
            .voice
            .live_realtime_thread(&record.call_id)
            .context("call voice session is no longer active")?;
        let principal = call_principal(self.user_name.as_deref(), record.request.to != "self")?;
        self.call_control("thread/realtime/appendSpeech", json!({"threadId": thread_id,
            "text": format!("The recipient's audio is ready. Begin the call now: identify yourself as {principal}'s assistant, greet briefly, and follow the call brief.")})).await?;
        Ok(())
    }

    pub(super) async fn record_media_event(
        self: &Arc<Self>,
        client_id: u64,
        params: Value,
    ) -> Result<Value> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct MediaEvent {
            call_id: String,
            event: String,
            provider_call_id: Option<String>,
            reason: Option<String>,
            provider_state: Option<String>,
        }
        let event: MediaEvent = serde_json::from_value(params)?;
        ensure!(
            event
                .reason
                .as_ref()
                .is_none_or(|reason| reason.len() <= 1_000),
            "media reason too long"
        );
        let call_id = event.call_id.clone();
        let (record, newly_connected) = self
            .calls
            .change_with(&call_id, move |record| {
                let mut newly_connected = false;
                ensure!(
                    record.request.to != "self" && record.media_client_id == Some(client_id),
                    "not this call's media owner"
                );
                if let Some(provider_id) = &event.provider_call_id {
                    ensure!(
                        provider_id.starts_with('c')
                            && provider_id.len() <= 64
                            && provider_id.bytes().all(|byte| byte.is_ascii_alphanumeric()),
                        "invalid provider call ID"
                    );
                    ensure!(
                        record
                            .delivery_receipt
                            .as_ref()
                            .is_none_or(|id| id == provider_id),
                        "provider call ID changed"
                    );
                    record.delivery_receipt = Some(provider_id.clone());
                }
                match event.event.as_str() {
                    "submitted" => {
                        ensure!(
                            !record.state.terminal() && record.delivery_receipt.is_some(),
                            "submission has no provider receipt"
                        );
                    }
                    "answered" => {
                        ensure!(
                            matches!(record.state, CallState::Connecting | CallState::Connected)
                                && record.delivery_receipt.is_some(),
                            "call is no longer awaiting answer"
                        );
                        newly_connected = record.state == CallState::Connecting;
                        record.state = CallState::Connected;
                        record.connected_at.get_or_insert(unix_seconds());
                    }
                    "completed" => {
                        ensure!(
                            record.delivery_receipt.is_some()
                                && matches!(
                                    event.provider_state.as_deref(),
                                    Some("success" | "busy" | "failed")
                                ),
                            "terminal carrier state is required"
                        );
                        record.state = CallState::Ended;
                        if record.reason.is_none() {
                            record.reason = event
                                .reason
                                .clone()
                                .or_else(|| event.provider_state.clone());
                        }
                        record.ended_at = Some(unix_seconds());
                    }
                    "uncertain" => {
                        if record.state != CallState::Ended {
                            record.state = CallState::Unresolved;
                            record.reason = event.reason.clone();
                            record.ended_at = Some(unix_seconds());
                        }
                    }
                    _ => bail!("unsupported carrier event"),
                }
                Ok(newly_connected)
            })
            .await?;
        self.publish_call_state_awaiting_capacity(&record).await;
        if newly_connected {
            let _transition = self.voice.transition().await;
            if self.calls.get(&record.call_id).await?.state == CallState::Connected {
                self.greet_connected_call(&record).await?;
            }
        }
        if record.state.terminal() {
            self.stop_voice_session(client_id).await?;
        }
        Ok(record.status())
    }

    pub(in crate::gateway) async fn publish_call_state_awaiting_capacity(
        &self,
        record: &CallRecord,
    ) {
        self.broadcast_json_awaiting_capacity(&call_state_notification(record), Source::Gateway)
            .await;
    }

    pub(in crate::gateway) fn publish_call_state_or_drop(&self, record: &CallRecord) {
        if let Err(error) =
            self.broadcast_json_or_drop(&call_state_notification(record), Source::Gateway)
        {
            warn!(%error, "failed to encode call state notification");
        }
    }
}

fn call_state_notification(record: &CallRecord) -> Value {
    json!({"method": "calls/changed", "params": {
        "callId": record.call_id, "state": record.state, "expiresAt": record.expires_at,
        "reason": record.reason, "deliveryReceipt": record.delivery_receipt,
        "connectedAt": record.connected_at, "endedAt": record.ended_at,
    }})
}
