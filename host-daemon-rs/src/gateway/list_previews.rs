use crate::prompt_summary::{ATTACHED_FILES_HEADER, MARKER_PREFIX};
use serde_json::Value;
use unicode_segmentation::UnicodeSegmentation;

pub(super) fn bound(result: &mut Value) -> bool {
    let Some(threads) = result.get_mut("data").and_then(Value::as_array_mut) else {
        return false;
    };
    let mut changed = false;
    for thread in threads {
        if let Some(Value::String(preview)) = thread.get_mut("preview")
            && !preview.contains(MARKER_PREFIX)
            && !preview.contains(ATTACHED_FILES_HEADER)
            && let Some((boundary, _)) = preview.grapheme_indices(true).nth(2_048)
        {
            preview.truncate(boundary);
            changed = true;
        }
    }
    changed
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn bounded_preview_preserves_short_and_exact_bound_headers() {
        let prefix = "👨‍👩‍👧‍👦".repeat(2_048);
        let canonical = json!({"data":[{"id":"native","preview":format!("{prefix}e\u{301}")},
                {"id":"exact","preview":prefix},{"id":"empty","preview":""}],"nextCursor":"cursor"});
        let mut payload = canonical.clone();
        assert!(bound(&mut payload));
        assert_eq!(payload["data"][0]["preview"], prefix);
        assert_eq!(canonical["data"][0]["preview"], format!("{prefix}e\u{301}"));
        assert_eq!(payload["data"][1], canonical["data"][1]);
        assert_eq!(payload["data"][2], canonical["data"][2]);
        assert_eq!(payload["nextCursor"], canonical["nextCursor"]);
        assert!(!bound(&mut payload));
    }

    #[test]
    fn bounded_preview_preserves_long_remote_coder_prompt_formats() {
        let fixtures: Value = serde_json::from_str(include_str!(
            "../../../protocol-fixtures/attachments/pasted-text-v2-cases.json"
        ))
        .unwrap();
        let fixture = fixtures
            .as_array()
            .unwrap()
            .iter()
            .find(|fixture| fixture["name"] == "attachment only")
            .unwrap();
        let original = fixture["entries"][0]["text"].as_str().unwrap();
        let text = "👩🏽‍💻 log line\n".repeat(512);
        let prompt = fixture["prompt"]
            .as_str()
            .unwrap()
            .replace(
                &format!("bytes=\"{}\"", original.len()),
                &format!("bytes=\"{}\"", text.len()),
            )
            .replace(original, &text);
        assert!(prompt.graphemes(true).count() > 2_048);
        assert_eq!(
            crate::prompt_summary::prompt_summary(&prompt),
            fixture["summary"].as_str().unwrap()
        );
        for preview in [
            prompt,
            format!(
                "{}<remotecoder_pasted_text_v1>\npayload\n</remotecoder_pasted_text_v1>",
                "a".repeat(3_000)
            ),
            format!("{}</remotecoder_pasted_text_v1>", "a".repeat(3_000)),
            format!(
                "{}<remotecoder_literal_text_v2 bytes=\"4\">\ntext\n</remotecoder_literal_text_v2>",
                "a".repeat(3_000)
            ),
            format!(
                "{}\n\nAttached files (uploaded to this host; use these absolute paths):\n- /tmp/file",
                "a".repeat(3_000)
            ),
        ] {
            let canonical = json!({"data":[{"id":"native","preview":preview}]});
            let mut payload = canonical.clone();
            assert!(!bound(&mut payload));
            assert_eq!(payload, canonical);
        }
    }
}
