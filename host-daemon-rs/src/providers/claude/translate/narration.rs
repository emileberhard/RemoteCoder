use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::Value;

const ENVELOPE_FIELD: u64 = 2;
const BLOCK_FIELD: u64 = 1;
const BLOCK_KIND_FIELD: u64 = 8;
const NARRATION_KIND: &[u8] = b"narration";

pub(crate) const SEND_USER_MESSAGE: &str = "SendUserMessage";
pub(crate) const SEND_USER_MESSAGE_ENV: &str = "CLAUDE_CODE_PEWTER_OWL_TOOL";

pub(crate) fn sent_message_text(block: &Value) -> Option<&str> {
    if block.get("type").and_then(Value::as_str) != Some("tool_use")
        || block.get("name").and_then(Value::as_str) != Some(SEND_USER_MESSAGE)
    {
        return None;
    }
    block
        .pointer("/input/message")
        .and_then(Value::as_str)
        .filter(|text| !text.trim().is_empty())
}

pub(crate) fn narration_text(block: &Value) -> Option<&str> {
    if block.get("type").and_then(Value::as_str) != Some("thinking") {
        return None;
    }
    let text = block.get("thinking").and_then(Value::as_str)?.trim();
    if text.is_empty() {
        return None;
    }
    let signature = STANDARD
        .decode(block.get("signature").and_then(Value::as_str)?)
        .ok()?;
    let envelope = last_bytes_field(&signature, ENVELOPE_FIELD)?;
    let metadata = last_bytes_field(envelope, BLOCK_FIELD)?;
    (last_bytes_field(metadata, BLOCK_KIND_FIELD)? == NARRATION_KIND).then_some(text)
}

fn last_bytes_field(message: &[u8], field: u64) -> Option<&[u8]> {
    let mut position = 0;
    let mut found = None;
    while position < message.len() {
        let key = varint(message, &mut position)?;
        match key & 7 {
            0 => {
                varint(message, &mut position)?;
            }
            1 => position = bounded_end(message, position, 8)?,
            2 => {
                let length = usize::try_from(varint(message, &mut position)?).ok()?;
                let end = bounded_end(message, position, length)?;
                if key >> 3 == field {
                    found = Some(&message[position..end]);
                }
                position = end;
            }
            5 => position = bounded_end(message, position, 4)?,
            _ => return None,
        }
    }
    found
}

fn bounded_end(message: &[u8], position: usize, length: usize) -> Option<usize> {
    position
        .checked_add(length)
        .filter(|end| *end <= message.len())
}

fn varint(message: &[u8], position: &mut usize) -> Option<u64> {
    let mut value = 0;
    for shift in (0..64).step_by(7) {
        let byte = *message.get(*position)?;
        *position += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some(value);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn envelope(kind: &[u8]) -> String {
        fn field(number: u8, bytes: &[u8]) -> Vec<u8> {
            let mut encoded = vec![(number << 3) | 2, bytes.len() as u8];
            encoded.extend_from_slice(bytes);
            encoded
        }
        let metadata = [field(3, b"other"), field(BLOCK_KIND_FIELD as u8, kind)].concat();
        let block = field(BLOCK_FIELD as u8, &metadata);
        STANDARD.encode([field(1, b"opaque"), field(ENVELOPE_FIELD as u8, &block)].concat())
    }

    fn thinking(text: &str, signature: &str) -> Value {
        json!({"type": "thinking", "thinking": text, "signature": signature})
    }

    #[test]
    fn only_a_signature_tagged_narration_with_text_is_narration() {
        assert_eq!(
            narration_text(&thinking(
                " Checking the logs.\n\n",
                &envelope(b"narration")
            )),
            Some("Checking the logs.")
        );
        assert_eq!(narration_text(&thinking("", &envelope(b"narration"))), None);
        assert_eq!(
            narration_text(&thinking("Weighing it.", &envelope(b"summary"))),
            None
        );
        assert_eq!(
            narration_text(
                &json!({"type": "text", "text": "Done.", "signature": envelope(b"narration")})
            ),
            None
        );
    }

    #[test]
    fn unreadable_or_legacy_signatures_are_ordinary_thinking() {
        for signature in ["", "not base64!", "EgQKAggB", "//////////8="] {
            assert_eq!(narration_text(&thinking("Weighing it.", signature)), None);
        }
        assert_eq!(
            narration_text(&json!({"type": "thinking", "thinking": "Weighing it."})),
            None
        );
    }
}
