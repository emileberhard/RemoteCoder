use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{Answer, Choice, Definition};

const OPEN: &str = "<send_user_message_question_reply>";
const CLOSE: &str = "</send_user_message_question_reply>";
const MAXIMUM_TEXT_BYTES: usize = 256 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Entry {
    pub turn_id: String,
    pub item: Value,
    pub started_at_ordinal: Option<i64>,
    pub started_at_ms: Option<i64>,
    pub completed_at_ms: Option<i64>,
    pub is_complete: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Fact {
    Asked(Definition),
    Answered(Vec<(String, usize, Answer)>),
    Plain { ordinal: i64 },
}

pub(crate) fn relevant(item: &Value) -> bool {
    item["type"] == "userMessage"
        || (item["type"] == "agentMessage"
            && item["delivery"] == "async"
            && item["questions"].is_array())
}

/// Canonical positions, not delivery sequence or wall clocks, establish causality.
/// A malformed reply-shaped message is never a plain-input supersession.
pub(crate) fn normalize(entry: &Entry) -> Result<Option<Fact>> {
    if !relevant(&entry.item) || entry.is_complete != Some(true) {
        return Ok(None);
    }
    let ordinal = entry
        .started_at_ordinal
        .context("question input has no canonical source position")?;
    let item_id = entry.item["id"]
        .as_str()
        .context("question input has no item identity")?;
    super::validate_id(item_id)?;
    if entry.item["type"] == "agentMessage" {
        let source = entry.item["questions"]
            .as_array()
            .context("invalid async question array")?;
        ensure!(
            !source.is_empty() && source.len() <= 128,
            "async question capacity exceeded"
        );
        let mut questions = Vec::new();
        let mut bytes = 0;
        for value in source {
            let title = value["title"]
                .as_str()
                .context("question title is missing")?
                .to_owned();
            let options = match &value["options"] {
                Value::Null => Vec::new(),
                Value::Array(values) => values
                    .iter()
                    .map(|option| {
                        option
                            .as_str()
                            .map(str::to_owned)
                            .context("question option must be text")
                    })
                    .collect::<Result<Vec<_>>>()?,
                _ => anyhow::bail!("invalid question options"),
            };
            bytes += title.len() + options.iter().map(String::len).sum::<usize>();
            ensure!(
                !title.trim().is_empty() && options.len() <= 128 && bytes <= MAXIMUM_TEXT_BYTES,
                "invalid or oversized question"
            );
            questions.push(Choice { title, options });
        }
        return Ok(Some(Fact::Asked(Definition {
            item_id: item_id.into(),
            turn_id: entry.turn_id.clone(),
            ordinal,
            asked_at_ms: entry.started_at_ms.or(entry.completed_at_ms),
            questions,
        })));
    }
    let text = entry.item["content"]
        .as_array()
        .map(|content| {
            content
                .iter()
                .filter_map(|part| {
                    (part["type"] == "text")
                        .then(|| part["text"].as_str())
                        .flatten()
                })
                .collect::<Vec<_>>()
                .join("\n\n")
        })
        .unwrap_or_default();
    let text = text.trim();
    if text.contains(OPEN) || text.contains(CLOSE) {
        // Invalid user-authored envelopes are non-destructive, not fatal to the stream.
        let Some(body) = text.strip_prefix(OPEN).and_then(|s| s.strip_suffix(CLOSE)) else {
            return Ok(None);
        };
        if body.len() > MAXIMUM_TEXT_BYTES {
            return Ok(None);
        }
        let Ok(value) = serde_json::from_str::<Value>(body) else {
            return Ok(None);
        };
        let values = match value {
            Value::Array(values) => values,
            Value::Object(_) => vec![value],
            _ => return Ok(None),
        };
        if values.len() > 128 {
            return Ok(None);
        }
        let mut answers = Vec::new();
        for value in values {
            let Some(key) = value["questionItemId"]
                .as_str()
                .and_then(|key| serde_json::from_str::<Value>(key).ok())
            else {
                continue;
            };
            let Some(parts) = key
                .as_array()
                .filter(|parts| parts.len() == 3 && parts[0] == "request_user_input_async")
            else {
                continue;
            };
            let (Some(target), Some(index), Some(answer)) = (
                parts[1].as_str(),
                parts[2].as_u64(),
                value["answer"].as_str(),
            ) else {
                continue;
            };
            if super::validate_id(target).is_err() || index >= 128 || answer.trim().is_empty() {
                continue;
            }
            answers.push((
                target.to_owned(),
                index as usize,
                Answer {
                    text: answer.to_owned(),
                    item_id: item_id.into(),
                    client_id: entry.item["clientId"].as_str().map(str::to_owned),
                    ordinal,
                    at_ms: entry.completed_at_ms.or(entry.started_at_ms),
                },
            ));
        }
        return Ok((!answers.is_empty()).then_some(Fact::Answered(answers)));
    }
    // These are established harness envelopes, not content keyword guesses.
    if text.is_empty()
        || text.starts_with("<system-reminder>")
        || text.starts_with("<task-notification>")
        || text.starts_with("<realtime_delegation>")
            && text.contains("<source>transcript_tail_flush</source>")
        || entry.item["isMeta"] == true
        || entry.item["isSynthetic"] == true
    {
        return Ok(None);
    }
    Ok(Some(Fact::Plain { ordinal }))
}
