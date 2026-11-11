use std::borrow::Cow;
use std::collections::HashSet;

use serde_json::Value;

pub(crate) const MARKER_PREFIX: &str = "remotecoder_";
pub(crate) const REMOTE_CODER_NOTE_START: &str = "<remotecoder_note>";
pub(crate) const REMOTE_CODER_NOTE_END: &str = "</remotecoder_note>";

pub(crate) const ATTACHED_FILES_HEADER: &str =
    "Attached files (uploaded to this host; use these absolute paths):\n";

pub(crate) fn without_remote_coder_note(text: &str) -> &str {
    let trimmed = text.trim_end();
    let Some(body) = trimmed.strip_suffix(REMOTE_CODER_NOTE_END) else {
        return text;
    };
    let Some((user, _)) = body.rsplit_once(REMOTE_CODER_NOTE_START) else {
        return text;
    };
    if user.is_empty() || user.ends_with('\n') {
        user.trim_end()
    } else {
        text
    }
}

fn without_attached_files(text: &str) -> &str {
    match text.rsplit_once(ATTACHED_FILES_HEADER) {
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
    }
}

pub(crate) fn prompt_summary(text: &str) -> Cow<'_, str> {
    let text = without_remote_coder_note(text).trim();
    let body = without_attached_files(text);
    if let Some(summary) = inline_text(body, |_| "[Pasted text]") {
        return Cow::Owned(summary);
    }
    if let Some((caption, _)) = pasted_entries(body) {
        return Cow::Borrowed(if caption.is_empty() {
            "Pasted text"
        } else {
            caption
        });
    }
    Cow::Borrowed(if body.is_empty() && body.len() != text.len() {
        "File attachment"
    } else {
        body
    })
}

pub(crate) fn searchable_prompt(text: &str) -> Cow<'_, str> {
    let body = without_attached_files(without_remote_coder_note(text).trim());
    if let Some(text) = inline_text(body, |payload| payload) {
        return Cow::Owned(text);
    }
    if let Some((caption, entries)) = pasted_entries(body) {
        let mut text = caption.to_owned();
        for entry in entries {
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(entry["text"].as_str().expect("validated pasted text"));
        }
        return Cow::Owned(text);
    }
    Cow::Borrowed(body)
}

fn pasted_entries(body: &str) -> Option<(&str, Vec<Value>)> {
    const START: &str = "<remotecoder_pasted_text_v1>\n";
    const END: &str = "\n</remotecoder_pasted_text_v1>";
    let (caption, payload) = body.strip_suffix(END)?.rsplit_once(START)?;
    if !caption.is_empty() && !caption.ends_with("\n\n") {
        return None;
    }
    let entries: Vec<Value> = serde_json::from_str(payload).ok()?;
    let mut ids = HashSet::with_capacity(entries.len());
    let valid = !entries.is_empty()
        && entries.iter().all(|entry| {
            let id = entry["id"].as_str().and_then(crate::ids::parse_uuid);
            let text = entry["text"].as_str();
            match (id, text) {
                (Some(id), Some(text)) => !text.trim().is_empty() && ids.insert(id),
                _ => false,
            }
        });
    valid.then_some((caption.trim(), entries))
}

fn inline_text(text: &str, pasted_text: impl for<'a> Fn(&'a str) -> &'a str) -> Option<String> {
    const START: &str = "<remotecoder_pasted_text_v2 id=\"";
    const LITERAL: &str = "<remotecoder_literal_text_v2 bytes=\"";
    const LITERAL_END: &str = "\n</remotecoder_literal_text_v2>";
    const VISUAL_REPLY: &str = "<remotecoder_visual_reply_v1 turn=\"";
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
            let Some((id, payload, end)) = inline_paste(marked) else {
                continue;
            };
            if !ids.insert(id) {
                return None;
            }
            (pasted_text(payload), start + START.len() + end)
        } else if let Some(marked) = marked.strip_prefix(LITERAL) {
            let Some((literal, end)) = inline_payload(marked, LITERAL_END) else {
                continue;
            };
            (literal, start + LITERAL.len() + end)
        } else if let Some(marked) = marked.strip_prefix(VISUAL_REPLY) {
            let Some((reply, end)) = visual_reply(marked) else {
                continue;
            };
            (reply, start + VISUAL_REPLY.len() + end)
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

fn visual_reply(marked: &str) -> Option<(&str, usize)> {
    const END: &str = "\n</remotecoder_visual_reply_v1>";
    const MAXIMUM_TURN_BYTES: usize = 128;
    const MAXIMUM_REPLY_BYTES: usize = 16 * 1024;
    let quote = marked
        .as_bytes()
        .iter()
        .take(MAXIMUM_TURN_BYTES + 1)
        .position(|byte| *byte == b'"')?;
    let turn = &marked.as_bytes()[..quote];
    if turn.is_empty()
        || !turn
            .iter()
            .all(|byte| (0x21..0x7f).contains(byte) && *byte != b'<' && *byte != b'>')
    {
        return None;
    }
    let rest = marked[quote..].strip_prefix("\" visual=\"")?;
    let digest = rest.get(..64)?;
    if !digest
        .bytes()
        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return None;
    }
    let attributes = rest[64..].strip_prefix("\" bytes=\"")?;
    let (payload, end) = inline_payload(attributes, END)?;
    if payload.trim().is_empty() || payload.len() > MAXIMUM_REPLY_BYTES {
        return None;
    }
    Some((payload, marked.len() - attributes.len() + end))
}

fn inline_paste(marked: &str) -> Option<(crate::ids::UuidBytes, &str, usize)> {
    const END: &str = "\n</remotecoder_pasted_text_v2>";
    let id = crate::ids::parse_uuid(marked.get(..36)?)?;
    let attributes = marked.get(36..)?.strip_prefix("\" bytes=\"")?;
    let (payload, end) = inline_payload(attributes, END)?;
    if payload.trim().is_empty() {
        return None;
    }
    Some((id, payload, marked.len() - attributes.len() + end))
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
