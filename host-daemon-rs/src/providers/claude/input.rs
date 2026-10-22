use serde::ser::SerializeSeq;
use serde::{Deserialize, Serialize, Serializer};
use serde_json::Value;

/// One base64 image as Claude's streaming input accepts it.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ClaudeImage {
    pub media_type: String,
    pub base64_data: String,
}

/// A user turn: prompt text plus any attached images.
///
/// Claude's `--input-format stream-json` takes either a plain string or the
/// Messages content-block array. Text-only turns keep the string form that has
/// always worked; images require the array form.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ClaudeUserInput {
    pub client_id: Option<String>,
    pub text: String,
    pub images: Vec<ClaudeImage>,
    pub(super) is_synthetic: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) notice: Option<Box<crate::providers::claude::restart::Item>>,
}

impl ClaudeUserInput {
    pub(crate) fn text(text: impl Into<String>) -> Self {
        Self {
            client_id: None,
            text: text.into(),
            images: Vec::new(),
            is_synthetic: false,
            notice: None,
        }
    }

    pub(crate) fn recovery_notice(item: &crate::providers::claude::restart::Item) -> Self {
        Self {
            client_id: Some(item.recovery_id.clone()),
            is_synthetic: true,
            notice: Some(Box::new(crate::providers::claude::restart::Item {
                queued_inputs: Vec::new(),
                ..item.clone()
            })),
            ..Self::text(item.notice())
        }
    }

    pub(crate) fn transcript_tail(text: impl Into<String>) -> Self {
        Self {
            is_synthetic: true,
            ..Self::text(text)
        }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.text.trim().is_empty() && self.images.is_empty()
    }

    /// Parses the app-server `turn/start` / `turn/steer` `input` array.
    ///
    /// Unsupported image encodings are an error rather than a silent drop: an
    /// attachment that never reaches Claude looks to the user like the model
    /// ignored it.
    pub(crate) fn from_input_items(input: Option<&Value>) -> Result<Self, String> {
        let Some(items) = input.and_then(Value::as_array) else {
            return Ok(Self::default());
        };

        let mut texts: Vec<&str> = Vec::new();
        let mut images: Vec<ClaudeImage> = Vec::new();
        for item in items {
            match item.get("type").and_then(Value::as_str) {
                Some("text") | None => {
                    if let Some(text) = item.get("text").and_then(Value::as_str) {
                        texts.push(text);
                    }
                }
                Some("image") => {
                    let url = item
                        .get("url")
                        .and_then(Value::as_str)
                        .ok_or_else(|| "image input is missing url".to_string())?;
                    images.push(parse_data_url(url)?);
                }
                Some(other) => {
                    return Err(format!("unsupported input item type: {other}"));
                }
            }
        }

        Ok(Self {
            text: texts.join("\n"),
            images,
            ..Self::default()
        })
    }

    /// The `message.content` value for one streaming-input line.
    pub(super) fn content(&self) -> ClaudeContent<'_> {
        ClaudeContent(self)
    }
}

pub(super) struct ClaudeContent<'a>(&'a ClaudeUserInput);

impl Serialize for ClaudeContent<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let input = self.0;
        if input.images.is_empty() {
            return serializer.serialize_str(&input.text);
        }
        let text = !input.text.trim().is_empty();
        let mut blocks = serializer.serialize_seq(Some(input.images.len() + usize::from(text)))?;
        if text {
            blocks.serialize_element(&TextBlock {
                kind: "text",
                text: &input.text,
            })?;
        }
        for image in &input.images {
            blocks.serialize_element(&ImageBlock {
                kind: "image",
                source: ImageSource {
                    kind: "base64",
                    media_type: &image.media_type,
                    data: &image.base64_data,
                },
            })?;
        }
        blocks.end()
    }
}

#[derive(Serialize)]
struct TextBlock<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    text: &'a str,
}

#[derive(Serialize)]
struct ImageBlock<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    source: ImageSource<'a>,
}

#[derive(Serialize)]
struct ImageSource<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    media_type: &'a str,
    data: &'a str,
}

/// `data:image/png;base64,<payload>` is the only form the iOS client sends;
/// Claude has no way to fetch a remote URL for us.
fn parse_data_url(url: &str) -> Result<ClaudeImage, String> {
    let rest = url
        .strip_prefix("data:")
        .ok_or_else(|| "image input must be a data: URL".to_string())?;
    let (media_type, payload) = rest
        .split_once(";base64,")
        .ok_or_else(|| "image input must be base64-encoded".to_string())?;
    if media_type.is_empty() || payload.is_empty() {
        return Err("image input is empty".to_string());
    }
    Ok(ClaudeImage {
        media_type: media_type.to_string(),
        base64_data: payload.to_string(),
    })
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct ClaudeSelection {
    pub model: String,
    pub effort: Option<String>,
    pub fast: bool,
}

impl std::fmt::Display for ClaudeSelection {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let effort = self.effort.as_deref().unwrap_or("automatic");
        write!(formatter, "{} at {effort} effort", self.model)?;
        if self.fast {
            formatter.write_str(" with Fast")?;
        }
        Ok(())
    }
}

pub(crate) struct ClaudeTurnRequest {
    pub thread_id: String,
    pub session_uuid: String,
    pub first_turn: bool,
    pub input: ClaudeUserInput,
    pub selection: ClaudeSelection,
    pub cwd: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn image_item(url: &str) -> Value {
        json!({"type": "image", "url": url})
    }

    #[test]
    fn images_switch_the_wire_shape_to_content_blocks() {
        let input = json!([
            {"type": "text", "text": "look"},
            image_item("data:image/jpeg;base64,QUJD"),
        ]);
        let parsed = ClaudeUserInput::from_input_items(Some(&input)).expect("parses");

        assert_eq!(
            serde_json::to_value(parsed.content()).unwrap(),
            json!([
                {"type": "text", "text": "look"},
                {"type": "image", "source": {
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": "QUJD",
                }},
            ])
        );
    }

    #[test]
    fn an_image_without_a_caption_omits_the_empty_text_block() {
        let input = json!([image_item("data:image/png;base64,QUJD")]);
        let parsed = ClaudeUserInput::from_input_items(Some(&input)).expect("parses");

        assert!(!parsed.is_empty());
        let blocks = serde_json::to_value(parsed.content()).unwrap();
        let blocks = blocks.as_array().expect("array");
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0]["type"], json!("image"));
    }

    #[test]
    fn an_unfetchable_image_is_an_error_not_a_silent_drop() {
        let input = json!([image_item("https://example.com/cat.png")]);

        let err = ClaudeUserInput::from_input_items(Some(&input)).expect_err("rejects");

        assert!(err.contains("data:"), "unexpected message: {err}");
    }

    #[test]
    fn missing_input_is_empty_rather_than_an_error() {
        let parsed = ClaudeUserInput::from_input_items(None).expect("parses");

        assert!(parsed.is_empty());
    }
}
