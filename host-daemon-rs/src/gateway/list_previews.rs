use serde_json::Value;
use unicode_segmentation::UnicodeSegmentation;

pub(super) fn bound(result: &mut Value) -> bool {
    let Some(threads) = result.get_mut("data").and_then(Value::as_array_mut) else {
        return false;
    };
    let mut changed = false;
    for thread in threads {
        if let Some(Value::String(preview)) = thread.get_mut("preview")
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
    fn bounded_preview_preserves_short_and_exact_bound_headers_for_both_providers() {
        for id in ["native", "claude_session"] {
            let prefix = "👨‍👩‍👧‍👦".repeat(2_048);
            let canonical = json!({"data":[{"id":id,"preview":format!("{prefix}e\u{301}")},
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
    }
}
