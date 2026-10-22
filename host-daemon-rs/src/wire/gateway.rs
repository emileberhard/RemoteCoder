use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TerminalError {
    pub message: Option<String>,
    pub codex_error_info: Option<String>,
}

impl TerminalError {
    pub(crate) fn from_wire(value: Option<&Value>) -> Option<Self> {
        let error = value.filter(|error| !error.is_null())?;
        Some(Self {
            message: error
                .get("message")
                .and_then(Value::as_str)
                .map(|message| message.chars().take(2048).collect()),
            codex_error_info: error
                .get("codexErrorInfo")
                .and_then(Value::as_str)
                .map(|code| code.chars().take(128).collect()),
        })
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(crate) enum RealtimeVoiceRole {
    Developer,
    User,
    Assistant,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RealtimeVoiceInitialItem {
    pub role: RealtimeVoiceRole,
    pub text: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RealtimeVoiceStartRequest {
    pub conversation_thread_id: String,
    pub realtime_session_id: String,
    pub replace_existing_session: bool,
    pub cwd: String,
    pub model: String,
    pub effort: Option<String>,
    pub sdp: String,
    pub voice: Option<String>,
    #[serde(default)]
    pub initial_items: Vec<RealtimeVoiceInitialItem>,
}

impl RealtimeVoiceStartRequest {
    pub(crate) fn validate(mut self) -> Result<Self> {
        const MAXIMUM_INITIAL_ITEMS: usize = 128;
        const MAXIMUM_ESTIMATED_TOKENS: usize = 8_192;
        const BYTES_PER_ESTIMATED_TOKEN: usize = 4;

        self.conversation_thread_id =
            required_trimmed(self.conversation_thread_id, "conversationThreadId")?;
        self.realtime_session_id = required_trimmed(self.realtime_session_id, "realtimeSessionId")?;
        self.cwd = required_trimmed(self.cwd, "cwd")?;
        self.model = required_trimmed(self.model, "model")?;
        validate_model_name(&self.model)?;
        self.effort = optional_trimmed(self.effort);
        self.voice = optional_trimmed(self.voice);
        if self.sdp.trim().is_empty() {
            return Err(anyhow!("sdp is required"));
        }
        if self.initial_items.len() > MAXIMUM_INITIAL_ITEMS {
            return Err(anyhow!(
                "initialItems must contain no more than {MAXIMUM_INITIAL_ITEMS} entries"
            ));
        }
        let mut estimated_tokens = 0usize;
        for item in &mut self.initial_items {
            item.text = required_trimmed(std::mem::take(&mut item.text), "initialItems.text")?;
            estimated_tokens = estimated_tokens
                .saturating_add(item.text.len().div_ceil(BYTES_PER_ESTIMATED_TOKEN));
        }
        if estimated_tokens > MAXIMUM_ESTIMATED_TOKENS {
            return Err(anyhow!(
                "initialItems must contain no more than {MAXIMUM_ESTIMATED_TOKENS} estimated tokens"
            ));
        }
        Ok(self)
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ConversationSettingsUpdate {
    pub thread_id: String,
    pub model: String,
    pub effort: Option<String>,
    #[serde(default, deserialize_with = "present_or_null")]
    pub service_tier: Option<Option<String>>,
    pub summary: Option<String>,
}

fn present_or_null<'de, D>(deserializer: D) -> std::result::Result<Option<Option<String>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer).map(Some)
}

impl ConversationSettingsUpdate {
    pub(crate) fn from_params(params: Value) -> Result<Self> {
        let settings: Self = serde_json::from_value(params)?;
        if settings.thread_id.is_empty() || settings.model.is_empty() {
            return Err(anyhow!("threadId and model are required"));
        }
        validate_model_name(&settings.model)?;
        Ok(settings)
    }
}

pub(crate) fn validate_model_name(model: &str) -> Result<()> {
    const MAX_MODEL_NAME_BYTES: usize = 512;
    if model.len() > MAX_MODEL_NAME_BYTES {
        return Err(anyhow!(
            "model must be at most {MAX_MODEL_NAME_BYTES} bytes"
        ));
    }
    Ok(())
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RealtimeVoiceConnectedRequest {
    pub realtime_session_id: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RealtimeVoiceStartResponse {
    pub realtime_thread_id: String,
    pub model: String,
    pub effort: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RealtimeVoiceListResponse {
    pub voices: Vec<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RealtimeVoiceStatusResponse {
    pub active: bool,
    pub owned_by_current_client: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct EmptyResponse {}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct HostInfoResponse {
    pub home_directory: String,
    pub hostname: String,
    pub automations_authority: Option<String>,
    pub speech_available: bool,
}

#[derive(Debug, Deserialize)]
struct UpstreamRealtimeVoiceListResponse {
    voices: VersionedRealtimeVoiceCatalog,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VersionedRealtimeVoiceCatalog {
    default_v1: Option<String>,
    v1: Vec<String>,
}

pub(crate) fn normalize_realtime_voices(response: Value) -> Result<RealtimeVoiceListResponse> {
    let response: UpstreamRealtimeVoiceListResponse = serde_json::from_value(response)
        .map_err(|error| anyhow!("Codex returned an invalid realtime voice catalog: {error}"))?;
    let default = response.voices.default_v1;
    let available = response.voices.v1;

    let mut voices = Vec::with_capacity(available.len());
    if let Some(default) = default.as_deref() {
        voices.push(default.to_string());
    }
    for voice in available {
        if Some(voice.as_str()) != default.as_deref() {
            voices.push(voice);
        }
    }
    if voices.is_empty() {
        return Err(anyhow!("Codex returned no V1 realtime voices"));
    }
    Ok(RealtimeVoiceListResponse { voices })
}

fn required_trimmed(value: String, field: &str) -> Result<String> {
    let value = value.trim().to_string();
    if value.is_empty() {
        return Err(anyhow!("{field} is required"));
    }
    Ok(value)
}

fn optional_trimmed(value: Option<String>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn model_name_capacity_is_checked_at_the_settings_rpc_boundary() {
        let parse = |model| {
            ConversationSettingsUpdate::from_params(
                serde_json::json!({"threadId":"t", "model":model}),
            )
        };
        assert_eq!(parse("m".repeat(512)).unwrap().model.len(), 512);
        assert!(
            parse("Å".repeat(257))
                .unwrap_err()
                .to_string()
                .contains("512 bytes")
        );
    }

    #[test]
    fn start_request_rejects_unknown_fields_and_preserves_sdp() {
        let raw = json!({
            "conversationThreadId": " claude_thread ",
            "realtimeSessionId": " session-1 ",
            "replaceExistingSession": true,
            "cwd": " /tmp/project ",
            "model": " sonnet ",
            "effort": " high ",
            "sdp": "v=0\r\no=remote-coder\r\n",
            "voice": " cove ",
            "initialItems": [{"role": "user", "text": " Earlier question "}]
        });
        let request: RealtimeVoiceStartRequest = serde_json::from_value(raw).expect("request DTO");
        let request = request.validate().expect("valid request");
        assert_eq!(request.conversation_thread_id, "claude_thread");
        assert_eq!(request.realtime_session_id, "session-1");
        assert!(request.replace_existing_session);
        assert_eq!(request.sdp, "v=0\r\no=remote-coder\r\n");
        assert_eq!(request.initial_items[0].text, "Earlier question");

        let unknown = json!({
            "conversationThreadId": "thread",
            "realtimeSessionId": "session-1",
            "replaceExistingSession": true,
            "cwd": "/tmp/project",
            "model": "sonnet",
            "sdp": "v=0",
            "unexpected": true
        });
        assert!(serde_json::from_value::<RealtimeVoiceStartRequest>(unknown).is_err());
    }

    #[test]
    fn settings_updates_keep_a_null_service_tier_distinct_from_an_absent_one() {
        let parse = |params| ConversationSettingsUpdate::from_params(params);
        let base = json!({"threadId": "t", "model": "m"});
        assert_eq!(parse(base.clone()).expect("absent").service_tier, None);
        let cleared = parse(json!({"threadId": "t", "model": "m", "serviceTier": null}));
        assert_eq!(cleared.expect("null").service_tier, Some(None));
        let set = parse(json!({"threadId": "t", "model": "m", "serviceTier": "fast"}));
        assert_eq!(
            set.expect("set").service_tier,
            Some(Some("fast".to_owned()))
        );
        assert!(parse(json!({"threadId": "", "model": "m"})).is_err());
        assert!(parse(json!({"threadId": "t", "model": "m", "extra": 1})).is_err());
    }

    #[test]
    fn versioned_voice_catalog_uses_the_v1_default_first() {
        let response = normalize_realtime_voices(json!({
            "voices": {
                "defaultV1": "cove",
                "defaultV2": "marin",
                "v1": ["juniper", "cove", "sol"],
                "v2": ["alloy", "marin"]
            }
        }))
        .expect("voice catalog");
        assert_eq!(response.voices, ["cove", "juniper", "sol"]);
    }

    #[test]
    fn start_request_rejects_unbounded_initial_context() {
        let raw = json!({
            "conversationThreadId": "thread",
            "realtimeSessionId": "session-1",
            "replaceExistingSession": true,
            "cwd": "/tmp/project",
            "model": "sonnet",
            "sdp": "v=0",
            "initialItems": [{"role": "user", "text": "x".repeat(32_769)}]
        });
        let request: RealtimeVoiceStartRequest = serde_json::from_value(raw).expect("request DTO");

        assert!(request.validate().is_err());
    }
}
