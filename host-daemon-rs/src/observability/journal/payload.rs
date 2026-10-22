use sha2::{Digest, Sha256};

use super::{MAX_RECORD_BYTES, MAX_STRING_BYTES};
use serde_json::{Value, json};

pub(super) fn insert_kind(fields: &mut Value, kind: &'static str) {
    if let Value::Object(map) = fields {
        map.insert("kind".to_string(), json!(kind));
    }
}

/// A payload parsed once, elided once, and consumed at most once.
pub(super) struct Payload(pub(super) Value);

impl Payload {
    pub(super) fn value(&self) -> &Value {
        &self.0
    }

    pub(super) fn take(&mut self) -> Value {
        std::mem::replace(&mut self.0, Value::Null)
    }
}

pub(super) fn parse_and_elide(raw: &str) -> Payload {
    match serde_json::from_str::<Value>(raw) {
        Ok(mut value) => {
            redact_call_details(&mut value);
            elide_long_strings(&mut value);
            if raw.len() > MAX_RECORD_BYTES {
                elide_bulk_members(&mut value);
            }
            Payload(value)
        }
        Err(_) => Payload(json!({ "_unparsed": true, "bytes": raw.len() })),
    }
}

// Call briefs and delivery capabilities belong to their private call store,
// not the general RPC diagnostic journal (including response-only envelopes).
pub(super) fn redact_call_details(value: &mut Value) {
    match value {
        Value::Object(map) => {
            if map.get("type").and_then(Value::as_str) == Some("image")
                && let Some(data) = map.get_mut("data")
                && let Some(encoded) = data.as_str()
            {
                *data = json!({"imageCount": 1, "imageBytes": encoded.len()});
            }
            for (key, member) in map {
                if matches!(
                    key.as_str(),
                    "voipToken"
                        | "apnsToken"
                        | "deviceToken"
                        | "pushToken"
                        | "activityPushToken"
                        | "liveActivityPushToken"
                        | "locationPushToken"
                        | "location_push_token"
                        | "tokenHex"
                        | "brief"
                        | "accessToken"
                        | "refreshToken"
                        | "idToken"
                        | "apiKey"
                        | "authUrl"
                        | "verificationUrl"
                        | "userCode"
                        | "authorizationCode"
                        | "bearer"
                        | "_remoteCoderRootPermit"
                ) {
                    *member = Value::String("[redacted]".into());
                } else if key == "tokens" {
                    redact_device_tokens(member);
                } else if key == "to" && member.as_str().is_some_and(|to| to.starts_with('+')) {
                    *member = Value::String("[telephone recipient]".into());
                } else {
                    redact_call_details(member);
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(redact_call_details),
        Value::String(text)
            if text.trim_start().starts_with('{')
                && text.contains("\"content\"")
                && text.contains("\"image\"") =>
        {
            if let Ok(mut nested) = serde_json::from_str::<Value>(text) {
                redact_call_details(&mut nested);
                *value = Value::String(nested.to_string());
            }
        }
        Value::String(text) if text.starts_with("data:image/") => {
            *value = json!({"imageCount": 1, "imageBytes": text.split_once(',').map_or(0, |(_, data)| data.len())});
        }
        _ => (),
    }
}

fn redact_device_tokens(value: &mut Value) {
    match value {
        Value::String(_) => *value = Value::String("[redacted]".into()),
        Value::Object(map) => {
            for (key, member) in map {
                if key == "navigation" {
                    redact_call_details(member);
                } else {
                    redact_device_tokens(member);
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(redact_device_tokens),
        _ => (),
    }
}

/// Second trimming rule, applied only to records over [`MAX_RECORD_BYTES`]:
/// the bulk `result`/`params` member becomes a digest stub while the JSON-RPC
/// envelope (id, method, ok) survives, so response correlation still works.
fn elide_bulk_members(value: &mut Value) {
    let Value::Object(map) = value else { return };
    for key in ["result", "params"] {
        if let Some(member) = map.get_mut(key) {
            let serialized = member.to_string();
            if serialized.len() > MAX_STRING_BYTES {
                *member = json!({
                    "_elided": true,
                    "bytes": serialized.len(),
                    "sha256Prefix": sha256_prefix(&serialized),
                });
            }
        }
    }
}

pub(super) fn elide_oversized_event(fields: &mut Value) {
    elide_long_strings(fields);
    let Value::Object(map) = fields else { return };
    let mut sizes: Vec<(String, usize)> = map
        .iter()
        .map(|(key, member)| (key.clone(), key.len() + member.to_string().len()))
        .collect();
    let mut total: usize = sizes.iter().map(|(_, size)| size).sum();
    if total <= MAX_RECORD_BYTES {
        return;
    }
    sizes.retain(|(key, _)| !matches!(key.as_str(), "kind" | "event"));
    sizes.sort_by_key(|(_, size)| std::cmp::Reverse(*size));
    for (key, size) in sizes {
        if total <= MAX_RECORD_BYTES {
            break;
        }
        let Some(member) = map.get_mut(&key) else {
            continue;
        };
        let serialized = member.to_string();
        *member = json!({
            "_elided": true,
            "bytes": serialized.len(),
            "sha256Prefix": sha256_prefix(&serialized),
        });
        total = total - size + key.len() + member.to_string().len();
    }
}

/// Replaces any string over [`MAX_STRING_BYTES`] with a digest stub — the
/// journal's first trimming rule.
fn elide_long_strings(value: &mut Value) {
    match value {
        Value::String(text) if text.len() > MAX_STRING_BYTES => {
            *value = json!({
                "_elided": true,
                "bytes": text.len(),
                "sha256Prefix": sha256_prefix(text),
            });
        }
        Value::Array(items) => items.iter_mut().for_each(elide_long_strings),
        Value::Object(map) => map.values_mut().for_each(elide_long_strings),
        _ => {}
    }
}

fn sha256_prefix(text: &str) -> String {
    let digest = Sha256::digest(text.as_bytes());
    digest
        .iter()
        .take(8)
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub(super) fn string_field(payload: &Payload, key: &str) -> Option<String> {
    payload
        .value()
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
}

/// `method`, `threadId` and `turnId` for a notification frame.
pub(super) fn notification_identity(
    payload: &Payload,
) -> (Option<String>, Option<String>, Option<String>) {
    let method = string_field(payload, "method");
    let Some(params) = payload.value().get("params") else {
        return (method, None, None);
    };
    let thread_id = params
        .get("threadId")
        .and_then(Value::as_str)
        .or_else(|| {
            params
                .get("thread")
                .and_then(|thread| thread.get("id"))
                .and_then(Value::as_str)
        })
        .map(str::to_string);
    let turn_id = params
        .get("turnId")
        .and_then(Value::as_str)
        .or_else(|| {
            params
                .get("turn")
                .and_then(|turn| turn.get("id"))
                .and_then(Value::as_str)
        })
        .map(str::to_string);
    (method, thread_id, turn_id)
}

/// Thread id carried by a request's params, so `--thread` also finds the RPCs
/// that acted on a thread.
pub(super) fn rpc_thread_id(message: &Value) -> Option<String> {
    message
        .get("params")?
        .get("threadId")
        .and_then(Value::as_str)
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn even_small_inline_images_never_reach_the_journal() {
        for raw in [
            json!({"method":"device/tool/result","params":{"content":[{"type":"image","mimeType":"image/jpeg","data":"private-photo"}]}}),
            json!({"result":{"contentItems":[{"type":"inputImage","imageUrl":"data:image/jpeg;base64,private-photo"}]}}),
            json!({"result":{"content":[{"type":"text","text":json!({"content":[{"type":"image","data":"private-photo","mimeType":"image/jpeg"}]}).to_string()}]}}),
        ] {
            let parsed = parse_and_elide(&raw.to_string());
            let text = parsed.value().to_string();
            assert!(!text.contains("private-photo"));
            assert!(text.contains("imageBytes"));
            assert!(text.contains("13"));
        }
    }

    #[test]
    fn call_capabilities_and_briefs_are_redacted_in_requests_and_responses() {
        let payload = parse_and_elide(&json!({"id": 1, "params": {
            "voipToken": "private-token", "_remoteCoderRootPermit":"private-permit", "request": {"to": "+46000001709", "brief": {"context": "private context"}}
        }, "result": {"to": "+46000001709", "callId": "call-id"}}).to_string());
        let encoded = payload.value().to_string();
        for private in [
            "private-token",
            "private-permit",
            "+46000001709",
            "private context",
        ] {
            assert!(!encoded.contains(private));
        }
        assert_eq!(payload.value()["result"]["callId"], "call-id");
    }

    #[test]
    fn device_registration_tokens_are_redacted() {
        let params: Value = serde_json::from_str(include_str!(
            "../../../../protocol-fixtures/devices/register.json"
        ))
        .expect("fixture");
        let payload = parse_and_elide(
            &json!({"id": 1, "method": "devices/register", "params": params}).to_string(),
        );
        let encoded = payload.value().to_string();
        for kind in ["a1", "a2", "a3", "a4"] {
            assert!(!encoded.contains(&kind.repeat(32)));
        }
        assert_eq!(
            payload.value()["params"]["tokens"]["location"]["navigation"]["eventBaseUrl"],
            "https://gateway.example"
        );
    }

    #[test]
    fn strings_over_the_limit_are_replaced_by_a_digest_stub() {
        let long = "a".repeat(MAX_STRING_BYTES + 1);
        let short = "b".repeat(MAX_STRING_BYTES);
        let mut value = json!({
            "params": { "image": long, "text": short, "items": [{ "nested": "c".repeat(MAX_STRING_BYTES + 5) }] }
        });
        elide_long_strings(&mut value);

        let elided = &value["params"]["image"];
        assert_eq!(elided["_elided"], json!(true));
        assert_eq!(elided["bytes"], json!(MAX_STRING_BYTES + 1));
        assert_eq!(elided["sha256Prefix"].as_str().expect("prefix").len(), 16);
        assert_eq!(value["params"]["text"], json!(short));
        assert_eq!(
            value["params"]["items"][0]["nested"]["_elided"],
            json!(true)
        );
    }
}
