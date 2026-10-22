use crate::providers::codex::daemon::MAX_WEBSOCKET_BYTES;
use crate::rpc::dispatch::{MAX_REQUEST_ID_BYTES, validate_request_id};
use crate::storage::tool_media::ToolMediaStore;
use crate::wire::json::{EncodedJson, encode};
use crate::wire::tool_media::{CompactionError, compact_tool_media};
use anyhow::{Context, Result, ensure};
use serde_json::Value;

#[derive(Debug, Clone)]
pub(in crate::gateway) struct RejectedFrame {
    pub id: Option<Value>,
    pub method: Option<String>,
    pub thread: Option<String>,
    pub bytes: usize,
    pub resource: &'static str,
}

#[derive(Debug, Clone)]
pub(in crate::gateway) enum ClientFrame {
    Text(String),
    Rejected(RejectedFrame),
}

#[derive(serde::Deserialize)]
struct OutboundMetadata<'a> {
    #[serde(borrow)]
    id: Option<&'a serde_json::value::RawValue>,
    #[serde(borrow)]
    method: Option<&'a serde_json::value::RawValue>,
    #[serde(borrow)]
    params: Option<OutboundParams<'a>>,
}

#[derive(serde::Deserialize)]
struct OutboundParams<'a> {
    #[serde(borrow, rename = "threadId")]
    thread_id: Option<&'a serde_json::value::RawValue>,
    #[serde(borrow)]
    thread: Option<OutboundThread<'a>>,
}

#[derive(serde::Deserialize)]
struct OutboundThread<'a> {
    #[serde(borrow)]
    id: Option<&'a serde_json::value::RawValue>,
}

fn bounded_metadata_string(
    raw: Option<&serde_json::value::RawValue>,
    limit: usize,
) -> Option<String> {
    raw.filter(|raw| raw.get().len() <= limit * 6 + 2)
        .and_then(|raw| serde_json::from_str::<String>(raw.get()).ok())
        .filter(|value| value.len() <= limit)
}

fn bounded_value_string(value: Option<&Value>, limit: usize) -> Option<String> {
    value
        .and_then(Value::as_str)
        .filter(|value| value.len() <= limit)
        .map(str::to_owned)
}

impl RejectedFrame {
    fn from_value(message: &Value, bytes: usize) -> Self {
        Self {
            id: message
                .get("id")
                .filter(|id| {
                    message.get("method").is_none()
                        && !id.is_null()
                        && validate_request_id(id).is_ok()
                })
                .cloned(),
            method: bounded_value_string(message.get("method"), 256),
            thread: bounded_value_string(
                message
                    .pointer("/params/threadId")
                    .or_else(|| message.pointer("/params/thread/id")),
                512,
            ),
            bytes,
            resource: "outbound message bytes",
        }
    }

    fn from_raw(raw: &str) -> Self {
        let metadata = serde_json::from_str::<OutboundMetadata<'_>>(raw).ok();
        Self {
            id: metadata
                .as_ref()
                .filter(|meta| meta.method.is_none())
                .and_then(|meta| meta.id)
                .filter(|raw| raw.get().len() <= MAX_REQUEST_ID_BYTES * 6 + 2)
                .and_then(|raw| serde_json::from_str::<Value>(raw.get()).ok())
                .filter(|id| !id.is_null() && validate_request_id(id).is_ok()),
            method: metadata
                .as_ref()
                .and_then(|meta| bounded_metadata_string(meta.method, 256)),
            thread: metadata
                .as_ref()
                .and_then(|meta| meta.params.as_ref())
                .and_then(|params| {
                    bounded_metadata_string(
                        params
                            .thread_id
                            .or_else(|| params.thread.as_ref().and_then(|thread| thread.id)),
                        512,
                    )
                }),
            bytes: raw.len(),
            resource: "outbound message bytes",
        }
    }
}

impl ClientFrame {
    pub(in crate::gateway) fn encode(message: &Value) -> Result<Self> {
        match encode(message)? {
            EncodedJson::Text(text) => Ok(Self::Text(text)),
            EncodedJson::Capacity { bytes } => {
                Ok(Self::Rejected(RejectedFrame::from_value(message, bytes)))
            }
        }
    }

    pub(in crate::gateway) async fn compact(
        message: &mut Value,
        media: Option<&ToolMediaStore>,
    ) -> Result<Option<Self>> {
        match compact_tool_media(message, media).await {
            Ok(false) => Ok(None),
            Ok(true) => Self::encode(message).map(Some),
            Err(CompactionError::Capacity { bytes }) => {
                let mut rejected = RejectedFrame::from_value(message, bytes);
                rejected.resource = "nested tool JSON bytes";
                Ok(Some(Self::Rejected(rejected)))
            }
            Err(CompactionError::Encoding(error)) => Err(error),
        }
    }

    pub(in crate::gateway) async fn prepare(
        message: &mut Value,
        media: Option<&ToolMediaStore>,
    ) -> Result<Self> {
        match Self::compact(message, media).await? {
            Some(frame) => Ok(frame),
            None => Self::encode(message),
        }
    }

    pub(in crate::gateway) fn capacity_resource(&self) -> Option<&'static str> {
        match self {
            Self::Rejected(rejected) => Some(rejected.resource),
            Self::Text(_) => None,
        }
    }

    pub(in crate::gateway) fn from_text(text: String) -> Self {
        if text.len() > MAX_WEBSOCKET_BYTES {
            Self::Rejected(RejectedFrame::from_raw(&text))
        } else {
            Self::Text(text)
        }
    }

    pub(in crate::gateway) fn from_raw(raw: &str) -> Self {
        if raw.len() > MAX_WEBSOCKET_BYTES {
            Self::Rejected(RejectedFrame::from_raw(raw))
        } else {
            Self::Text(raw.to_owned())
        }
    }

    pub(in crate::gateway) fn text(&self) -> Option<&str> {
        match self {
            Self::Text(text) => Some(text),
            Self::Rejected(_) => None,
        }
    }

    pub(in crate::gateway) fn bytes(&self) -> usize {
        match self {
            Self::Text(text) => text.len(),
            Self::Rejected(rejection) => rejection.bytes,
        }
    }

    pub(in crate::gateway) fn stamp(self, message: &Value, sequence: Option<u64>) -> Result<Self> {
        let Some(sequence) = sequence else {
            return Ok(self);
        };
        let object = message
            .as_object()
            .filter(|object| !object.is_empty())
            .context("stored notification must be a non-empty JSON object")?;
        ensure!(
            !object.contains_key("rcSequence"),
            "stored notification already carries rcSequence"
        );
        let suffix = format!(",\"rcSequence\":{sequence}}}");
        match self {
            Self::Text(mut text) => {
                let body_len = text
                    .trim_end()
                    .strip_suffix('}')
                    .context("stored notification must end its JSON object")?
                    .len();
                let bytes = body_len + suffix.len();
                if bytes > MAX_WEBSOCKET_BYTES {
                    return Ok(Self::Rejected(RejectedFrame::from_value(message, bytes)));
                }
                text.truncate(body_len);
                text.try_reserve_exact(suffix.len())?;
                text.push_str(&suffix);
                Ok(Self::Text(text))
            }
            Self::Rejected(mut rejected) => {
                if rejected.resource == "outbound message bytes" {
                    rejected.bytes = rejected.bytes.saturating_add(suffix.len() - 1);
                }
                Ok(Self::Rejected(rejected))
            }
        }
    }

    pub(in crate::gateway) fn into_command(self) -> super::super::ClientCommand {
        match self {
            Self::Text(text) => super::super::ClientCommand::Text(text),
            Self::Rejected(rejected) => super::super::ClientCommand::FrameCapacity(rejected),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rpc_capacity_sequence_stamp_cannot_expand_a_bounded_frame_past_the_cap() {
        let message = serde_json::json!({"method":"item/completed"});
        let prefix = r#"{"method":"item/completed""#;
        let raw = format!(
            "{prefix}{}}}",
            " ".repeat(MAX_WEBSOCKET_BYTES - prefix.len() - 1)
        );
        let frame = ClientFrame::from_text(raw)
            .stamp(&message, Some(1))
            .unwrap();
        let ClientFrame::Rejected(rejection) = frame else {
            panic!("stamp must be rejected");
        };
        assert_eq!(
            rejection.bytes,
            MAX_WEBSOCKET_BYTES + r#","rcSequence":1"#.len()
        );
        assert_eq!(rejection.method.as_deref(), Some("item/completed"));
        assert_eq!(rejection.id, None);
        let message = serde_json::json!({"id":4,"result":{"text":"Åsa 🚀\n"}});
        let frame = ClientFrame::encode(&message).unwrap();
        assert_eq!(
            frame.text().unwrap(),
            serde_json::to_string(&message).unwrap()
        );
    }
}
