use std::borrow::Cow;
use std::collections::HashSet;

use serde_json::Value;

pub(crate) fn prompt_summary(text: &str) -> Cow<'_, str> {
    const START: &str = "<remotecoder_pasted_text_v1>\n";
    const END: &str = "\n</remotecoder_pasted_text_v1>";
    const FILES: &str = "Attached files (uploaded to this host; use these absolute paths):\n";
    let text = text.trim();
    let body = match text.rsplit_once(FILES) {
        Some((body, paths))
            if (body.is_empty() || body.ends_with("\n\n"))
                && !paths.is_empty()
                && paths
                    .lines()
                    .all(|path| path.starts_with("- /") && path.len() > 3) =>
        {
            body.trim_end()
        }
        _ => text,
    };
    if let Some(summary) = inline_summary(body) {
        return Cow::Owned(summary);
    }
    if let Some((caption, payload)) = body
        .strip_suffix(END)
        .and_then(|body| body.rsplit_once(START))
        && (caption.is_empty() || caption.ends_with("\n\n"))
        && valid_pasted_entries(payload)
    {
        return Cow::Borrowed(if caption.trim().is_empty() {
            "Pasted text"
        } else {
            caption.trim()
        });
    }
    Cow::Borrowed(if body.is_empty() && body.len() != text.len() {
        "File attachment"
    } else {
        body
    })
}

fn valid_pasted_entries(payload: &str) -> bool {
    let Ok(Value::Array(entries)) = serde_json::from_str(payload) else {
        return false;
    };
    let mut ids = HashSet::with_capacity(entries.len());
    !entries.is_empty()
        && entries.iter().all(|entry| {
            let id = entry["id"].as_str().and_then(crate::ids::parse_uuid);
            let text = entry["text"].as_str();
            match (id, text) {
                (Some(id), Some(text)) => !text.trim().is_empty() && ids.insert(id),
                _ => false,
            }
        })
}

fn inline_summary(text: &str) -> Option<String> {
    const START: &str = "<remotecoder_pasted_text_v2 id=\"";
    const LITERAL: &str = "<remotecoder_literal_text_v2 bytes=\"";
    const LITERAL_END: &str = "\n</remotecoder_literal_text_v2>";
    let mut literal = 0;
    let mut search = 0;
    let mut summary = String::new();
    let mut ids = HashSet::new();
    let mut recognized = false;
    while let Some(offset) = text[search..].find("<remotecoder_") {
        let start = search + offset;
        search = start + "<remotecoder_".len();
        let marked = &text[start..];
        let (replacement, next) = if let Some(marked) = marked.strip_prefix(START) {
            let Some((id, end)) = inline_paste_end(marked) else {
                continue;
            };
            if !ids.insert(id) {
                return None;
            }
            ("[Pasted text]", start + START.len() + end)
        } else if let Some(marked) = marked.strip_prefix(LITERAL) {
            let Some((literal, end)) = inline_payload(marked, LITERAL_END) else {
                continue;
            };
            (literal, start + LITERAL.len() + end)
        } else {
            continue;
        };
        summary.push_str(&text[literal..start]);
        summary.push_str(replacement);
        search = next;
        literal = search;
        recognized = true;
    }
    if !recognized {
        return None;
    }
    summary.push_str(&text[literal..]);
    Some(summary.trim().to_owned())
}

fn inline_paste_end(marked: &str) -> Option<(crate::ids::UuidBytes, usize)> {
    const END: &str = "\n</remotecoder_pasted_text_v2>";
    let id = crate::ids::parse_uuid(marked.get(..36)?)?;
    let attributes = marked.get(36..)?.strip_prefix("\" bytes=\"")?;
    let (payload, end) = inline_payload(attributes, END)?;
    if payload.trim().is_empty() {
        return None;
    }
    Some((id, marked.len() - attributes.len() + end))
}

fn inline_payload<'a>(marked: &'a str, end: &str) -> Option<(&'a str, usize)> {
    let header_end = marked.as_bytes()[..marked.len().min(13)]
        .windows(3)
        .position(|bytes| bytes == b"\">\n")?;
    let length = &marked[..header_end];
    let payload = &marked[header_end + 3..];
    let bytes = length.parse::<usize>().ok()?;
    if bytes == 0 || bytes.to_string() != length {
        return None;
    }
    payload.get(bytes..)?.strip_prefix(end)?;
    Some((
        payload.get(..bytes)?,
        marked.len() - payload.len() + bytes + end.len(),
    ))
}
