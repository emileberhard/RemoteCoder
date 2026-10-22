use std::sync::Arc;
use std::time::Instant;

use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::registry::{
    CALL_STATUS, END_CALL, END_VOICE_CALL, NOTIFY_USER, PUBLISH_VISUAL, REQUEST_CALL, STEER_CALL,
    TAKE_PHOTO, definitions,
};
use crate::gateway::Gateway;
use crate::gateway::calls::RequestCall;
use crate::providers::Provider;

/// Who is calling. The thread id comes from the gateway's own records — the
/// per-runtime MCP token for Claude, the request params for Codex — never from
/// anything the model can set.
#[derive(Debug, Clone)]
pub(crate) struct Caller {
    pub provider: Provider,
    pub thread_id: Option<String>,
    pub turn_id: Option<String>,
}

/// The result of a dispatch, in the shape both projections render.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ToolOutcome {
    pub content: Vec<ToolContent>,
    pub is_error: bool,
    pub detail: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub(crate) enum ToolContent {
    Text {
        text: String,
    },
    Image {
        #[serde(rename = "mimeType")]
        mime_type: String,
        #[serde(rename = "data")]
        base64: String,
    },
}

impl ToolOutcome {
    pub(crate) fn ok(text: impl Into<String>) -> ToolOutcome {
        ToolOutcome {
            content: vec![ToolContent::Text { text: text.into() }],
            is_error: false,
            detail: None,
        }
    }

    pub(crate) fn error(text: impl Into<String>) -> ToolOutcome {
        ToolOutcome {
            content: vec![ToolContent::Text { text: text.into() }],
            is_error: true,
            detail: None,
        }
    }

    fn with_detail(self, detail: Value) -> ToolOutcome {
        ToolOutcome {
            detail: Some(detail),
            ..self
        }
    }

    pub(crate) fn audit(&self) -> Value {
        let mut images = 0;
        let mut image_bytes = 0;
        let mut texts = Vec::new();
        for content in &self.content {
            match content {
                ToolContent::Text { text } => texts.push(text.as_str()),
                ToolContent::Image { base64, .. } => {
                    images += 1;
                    image_bytes += base64.len();
                }
            }
        }
        json!({"text": texts.join("\n"), "imageCount": images, "imageBytes": image_bytes})
    }
}

/// One tool call with its arguments decoded and validated once; dispatch and
/// the journal read the same value, so neither re-parses the raw JSON.
#[derive(Debug, PartialEq)]
enum ToolCall {
    PublishVisual(crate::storage::visuals::PublishVisual),
    TakePhoto(crate::gateway::device_tools::PhotoArguments),
    RequestCall(RequestCall),
    CallStatus { call_id: String },
    EndCall { call_id: String },
    EndVoiceCall,
    SteerCall { call_id: String, message: String },
    NotifyUser { title: String, body: String },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CallIdArguments {
    call_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SteerArguments {
    call_id: String,
    message: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NotifyArguments {
    title: String,
    body: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NoArguments {}

fn decode_arguments<T: DeserializeOwned>(
    tool: &str,
    arguments: &Value,
    needs: &str,
) -> Result<T, String> {
    serde_json::from_value(arguments.clone())
        .map_err(|_| format!("{tool} needs {needs} and no other arguments."))
}

fn non_blank(tool: &str, value: String, needs: &str) -> Result<String, String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(format!("{tool} needs {needs} and no other arguments."));
    }
    Ok(trimmed.to_owned())
}

impl ToolCall {
    fn decode(tool: &str, arguments: &Value) -> Result<ToolCall, String> {
        const CALL_ID: &str = "a non-empty \"callId\" string";
        const STEER: &str = "non-empty \"callId\" and \"message\" strings";
        const NOTIFY: &str = "non-empty \"title\" and \"body\" strings";
        match tool {
            PUBLISH_VISUAL => {
                let visual: crate::storage::visuals::PublishVisual = decode_arguments(
                    tool,
                    arguments,
                    "a non-empty \"title\" string and exactly one of an \"html\" string or an absolute \"path\"",
                )?;
                visual.validate().map_err(|error| error.to_string())?;
                Ok(ToolCall::PublishVisual(visual))
            }
            TAKE_PHOTO => {
                let photo: crate::gateway::device_tools::PhotoArguments = decode_arguments(
                    tool,
                    arguments,
                    "camera=back, front or both and lens=wide, ultra_wide or telephoto",
                )?;
                photo.validate().map_err(str::to_string)?;
                Ok(ToolCall::TakePhoto(photo))
            }
            REQUEST_CALL => serde_json::from_value(arguments.clone())
                .map(ToolCall::RequestCall)
                .map_err(|error| error.to_string()),
            CALL_STATUS | END_CALL => {
                let CallIdArguments { call_id } = decode_arguments(tool, arguments, CALL_ID)?;
                let call_id = non_blank(tool, call_id, CALL_ID)?;
                Ok(if tool == CALL_STATUS {
                    ToolCall::CallStatus { call_id }
                } else {
                    ToolCall::EndCall { call_id }
                })
            }
            END_VOICE_CALL => {
                decode_arguments::<NoArguments>(tool, arguments, "no arguments")?;
                Ok(ToolCall::EndVoiceCall)
            }
            STEER_CALL => {
                let SteerArguments { call_id, message } = decode_arguments(tool, arguments, STEER)?;
                Ok(ToolCall::SteerCall {
                    call_id: non_blank(tool, call_id, STEER)?,
                    message: non_blank(tool, message, STEER)?,
                })
            }
            NOTIFY_USER => {
                let NotifyArguments { title, body } = decode_arguments(tool, arguments, NOTIFY)?;
                Ok(ToolCall::NotifyUser {
                    title: non_blank(tool, title, NOTIFY)?,
                    body: non_blank(tool, body, NOTIFY)?,
                })
            }
            other => Err(format!(
                "Unknown tool \"{other}\". Available: {}.",
                definitions()
                    .iter()
                    .map(|tool| tool.name)
                    .collect::<Vec<_>>()
                    .join(", ")
            )),
        }
    }

    /// What the journal may keep: identities and sizes, never call briefs,
    /// steering text or notification copy.
    fn audit(&self) -> Value {
        match self {
            ToolCall::PublishVisual(visual) => visual.audit(),
            ToolCall::TakePhoto(photo) => json!(photo),
            ToolCall::RequestCall(request) => {
                json!({"requestId": request.request_id, "brief": "[private call record]"})
            }
            ToolCall::CallStatus { call_id } | ToolCall::EndCall { call_id } => {
                json!({"callId": call_id})
            }
            ToolCall::EndVoiceCall => json!({}),
            ToolCall::SteerCall { call_id, message } => {
                json!({"callId": call_id, "messageBytes": message.len()})
            }
            ToolCall::NotifyUser { title, body } => {
                json!({"titleBytes": title.len(), "bodyBytes": body.len()})
            }
        }
    }

    async fn previewed(published: crate::storage::visuals::Published) -> ToolOutcome {
        let mut audit = published.audit;
        let mut content = vec![
            ToolContent::Text {
                text: "Shown inline automatically; your answer needs no embed. Check the preview, then give the key point. Republishing with the same title replaces it in this turn. To show this version again in a later answer, put the embed below on its own line.".into(),
            },
            ToolContent::Text {
                text: published.embed,
            },
        ];
        match crate::storage::visual_preview::render(&published.hash, &published.bytes).await {
            Ok(preview) => {
                audit["preview"] = preview.audit;
                content.push(ToolContent::Text {
                    text: preview.summary,
                });
                content.push(ToolContent::Image {
                    mime_type: "image/jpeg".into(),
                    base64: preview.jpeg_base64,
                });
            }
            Err(error) => {
                audit["preview"] = error.audit();
                content.push(ToolContent::Text {
                    text: format!("Preview unavailable: {error}."),
                });
            }
        }
        ToolOutcome {
            content,
            is_error: false,
            detail: Some(audit),
        }
    }

    async fn run(self, gateway: &Arc<Gateway>, caller: &Caller) -> ToolOutcome {
        match self {
            ToolCall::PublishVisual(visual) => match visual.publish().await {
                Ok(published) => Self::previewed(published).await,
                Err(error) => ToolOutcome::error(format!("Could not publish visual: {error}"))
                    .with_detail(error.audit()),
            },
            ToolCall::TakePhoto(photo) => gateway.invoke_device_photo(caller, photo).await,
            ToolCall::RequestCall(request) => {
                Self::status(gateway.request_agent_call(caller, request).await)
            }
            ToolCall::CallStatus { call_id } => {
                Self::status(gateway.agent_call_status(caller, &call_id).await)
            }
            ToolCall::EndCall { call_id } => {
                Self::status(gateway.end_call_for_agent(caller, &call_id).await)
            }
            ToolCall::EndVoiceCall => {
                if gateway.end_voice_call_for_agent(caller).await {
                    ToolOutcome::ok("Voice call ended.")
                } else {
                    ToolOutcome::error("No active voice call to end.")
                }
            }
            ToolCall::SteerCall { call_id, message } => {
                match gateway
                    .steer_call_for_agent(caller, &call_id, &message)
                    .await
                {
                    Ok(()) => ToolOutcome::ok("Guidance accepted by the live voice session."),
                    Err(error) => ToolOutcome::error(error.to_string()),
                }
            }
            ToolCall::NotifyUser { title, body } => {
                match gateway
                    .send_user_alert(&title, &body, caller.thread_id.as_deref())
                    .await
                {
                    Ok(()) => ToolOutcome::ok("Notification sent."),
                    Err(reason) => {
                        ToolOutcome::error(format!("Could not send the notification: {reason}"))
                    }
                }
            }
        }
    }

    fn status(result: anyhow::Result<Value>) -> ToolOutcome {
        match result {
            Ok(status) => ToolOutcome::ok(status.to_string()),
            Err(error) => ToolOutcome::error(error.to_string()),
        }
    }
}

/// Runs one tool and journals the attempt with its outcome.
pub(crate) async fn dispatch(
    gateway: &Arc<Gateway>,
    tool: &str,
    arguments: &Value,
    caller: &Caller,
) -> ToolOutcome {
    let started = Instant::now();
    let decoded = ToolCall::decode(tool, arguments);
    let audit = decoded
        .as_ref()
        .map_or_else(|_| json!("[arguments rejected]"), ToolCall::audit);
    let outcome = match decoded {
        Ok(call) => call.run(gateway, caller).await,
        Err(text) => ToolOutcome::error(text),
    };
    let mut outcome_audit = outcome.audit();
    if tool == PUBLISH_VISUAL {
        outcome_audit["text"] = json!("[visual publication result]");
    }
    gateway.journal().tool(
        "dispatch",
        json!({
            "tool": tool,
            "source": caller.provider.as_str(),
            "threadId": caller.thread_id,
            "turnId": caller.turn_id,
            "arguments": audit,
            "outcome": if outcome.is_error { "error" } else { "ok" },
            "text": outcome_audit["text"],
            "imageCount": outcome_audit["imageCount"],
            "imageBytes": outcome_audit["imageBytes"],
            "detail": outcome.detail,
            "elapsedMs": started.elapsed().as_secs_f64() * 1000.0,
        }),
    );
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_decode_once_and_reject_anything_the_schema_forbids() {
        let decode = |tool: &str, arguments: Value| ToolCall::decode(tool, &arguments);

        assert_eq!(
            decode(NOTIFY_USER, json!({"title": " hi ", "body": "there"})),
            Ok(ToolCall::NotifyUser {
                title: "hi".into(),
                body: "there".into()
            })
        );
        assert_eq!(
            decode(CALL_STATUS, json!({"callId": "c1"})),
            Ok(ToolCall::CallStatus {
                call_id: "c1".into()
            })
        );
        assert_eq!(
            decode(END_VOICE_CALL, json!({})),
            Ok(ToolCall::EndVoiceCall)
        );

        for (tool, arguments) in [
            (NOTIFY_USER, json!({"title": "  ", "body": "b"})),
            (NOTIFY_USER, json!({"title": "t"})),
            (NOTIFY_USER, json!({"title": 7, "body": "b"})),
            (NOTIFY_USER, json!({"title": "t", "body": "b", "extra": 1})),
            (CALL_STATUS, json!({"callId": ""})),
            (END_CALL, json!({"callId": "c1", "other": true})),
            (STEER_CALL, json!({"callId": "c1", "message": " "})),
            (END_VOICE_CALL, json!({"callId": "c1"})),
            (END_VOICE_CALL, Value::Null),
        ] {
            let error = decode(tool, arguments.clone()).unwrap_err();
            assert!(error.starts_with(tool), "{tool} {arguments}: {error}");
        }
        assert!(decode(REQUEST_CALL, json!({"requestId": "r"})).is_err());
        assert_eq!(
            decode(TAKE_PHOTO, json!({})),
            Ok(ToolCall::TakePhoto(
                crate::gateway::device_tools::PhotoArguments::default()
            ))
        );
        assert!(
            decode(TAKE_PHOTO, json!({"camera":"front","lens":"telephoto"}))
                .unwrap_err()
                .contains("front camera supports only lens=wide")
        );
        assert!(decode(TAKE_PHOTO, json!({"camera":"both","lens":"ultra_wide"})).is_ok());
        assert!(decode(TAKE_PHOTO, json!({"camera":"rear"})).is_err());
        assert!(decode(TAKE_PHOTO, json!({"extra":true})).is_err());
        assert!(
            decode("rm_rf", json!({}))
                .unwrap_err()
                .contains("Unknown tool")
        );
    }

    #[test]
    fn the_journal_projection_keeps_identities_and_sizes_but_no_copy() {
        let notify = ToolCall::NotifyUser {
            title: "Secret title".into(),
            body: "Secret body".into(),
        };
        let steer = ToolCall::SteerCall {
            call_id: "c1".into(),
            message: "Private guidance".into(),
        };
        assert_eq!(notify.audit(), json!({"titleBytes": 12, "bodyBytes": 11}));
        assert_eq!(steer.audit(), json!({"callId": "c1", "messageBytes": 16}));
        for audited in [notify.audit(), steer.audit()] {
            let text = audited.to_string();
            assert!(
                !text.contains("Secret") && !text.contains("Private"),
                "{text}"
            );
        }
    }
}
