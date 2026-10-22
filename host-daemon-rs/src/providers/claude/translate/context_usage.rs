use super::TurnTranslator;
use serde_json::{Value, json};

impl TurnTranslator {
    pub(super) fn model_context_window(&self, result: &Value) -> Option<i64> {
        let usage = result.get("modelUsage")?.as_object()?;
        let model_window = if let Some(model_id) = self.model_id.as_deref()
            && let Some(context_window) = usage
                .get(model_id)
                .and_then(|model| model.get("contextWindow"))
                .and_then(Value::as_i64)
        {
            Some(context_window)
        } else {
            usage.values().find_map(|model| {
                let canonical = model.get("canonicalModel").and_then(Value::as_str)?;
                (Some(canonical) == self.model_id.as_deref())
                    .then(|| model.get("contextWindow").and_then(Value::as_i64))
                    .flatten()
            })
        }?;

        Some(
            self.auto_compact_window
                .map_or(model_window, |window| window.min(model_window)),
        )
    }
}

pub(crate) fn token_usage_notification(
    thread_id: &str,
    turn_id: &str,
    usage: &Value,
    model_context_window: Option<i64>,
) -> Option<Value> {
    let Some(counters) = TokenCounters::parse(usage) else {
        tracing::warn!(thread_id, turn_id, "ignoring malformed Claude token usage");
        return None;
    };

    let breakdown = json!({
        "totalTokens": counters.total,
        "inputTokens": counters.input,
        "cachedInputTokens": counters.cached,
        "outputTokens": counters.output,
        "reasoningOutputTokens": counters.reasoning,
    });

    Some(json!({
        "method": "thread/tokenUsage/updated",
        "params": {
            "threadId": thread_id,
            "turnId": turn_id,
            "tokenUsage": {
                "total": breakdown,
                "last": breakdown,
                "modelContextWindow": model_context_window,
            }
        }
    }))
}

struct TokenCounters {
    input: i64,
    cached: i64,
    output: i64,
    reasoning: i64,
    total: i64,
}

impl TokenCounters {
    fn parse(usage: &Value) -> Option<Self> {
        let counter = |value: Option<&Value>| match value {
            None | Some(Value::Null) => Some(None),
            Some(value) => value.as_i64().filter(|count| *count >= 0).map(Some),
        };
        let input = counter(usage.get("input_tokens"))??;
        let output = counter(usage.get("output_tokens"))??;
        let cached = counter(usage.get("cache_read_input_tokens"))?.unwrap_or(0);
        let cache_creation = counter(usage.get("cache_creation_input_tokens"))?.unwrap_or(0);
        let reasoning = counter(
            usage
                .get("output_tokens_details")
                .and_then(|details| details.get("thinking_tokens")),
        )?
        .unwrap_or(0);
        let total = input
            .checked_add(cached)?
            .checked_add(cache_creation)?
            .checked_add(output)?;
        Some(Self {
            input,
            cached,
            output,
            reasoning,
            total,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::{methods, translator};
    use super::*;

    #[test]
    fn message_delta_usage_becomes_token_usage() {
        let mut t = translator();
        let out = t.handle(&json!({
            "type":"stream_event",
            "event":{"type":"message_delta","usage":{
                "input_tokens":2,"cache_read_input_tokens":100,"output_tokens":84,
                "output_tokens_details":{"thinking_tokens":8}
            }}
        }));

        assert_eq!(
            methods(&out.notifications),
            vec!["thread/tokenUsage/updated"]
        );
        let usage = &out.notifications[0]["params"]["tokenUsage"]["last"];
        assert_eq!(usage["inputTokens"], json!(2));
        assert_eq!(usage["cachedInputTokens"], json!(100));
        assert_eq!(usage["outputTokens"], json!(84));
        assert_eq!(usage["reasoningOutputTokens"], json!(8));
        assert_eq!(usage["totalTokens"], json!(186));
    }

    #[test]
    fn malformed_token_usage_is_dropped_instead_of_reported_as_zero() {
        let mut t = translator();
        for usage in [
            json!({"output_tokens":84}),
            json!({"input_tokens":2}),
            json!({"input_tokens":-2,"output_tokens":84}),
            json!({"input_tokens":"2","output_tokens":84}),
            json!({"input_tokens":2,"output_tokens":84,"cache_read_input_tokens":-1}),
            json!({"input_tokens":i64::MAX,"output_tokens":1,"cache_read_input_tokens":1}),
        ] {
            let out = t.handle(&json!({
                "type":"stream_event",
                "event":{"type":"message_delta","usage":usage}
            }));
            assert!(out.notifications.is_empty(), "{usage}");
        }

        let out = t.handle(&json!({
            "type":"stream_event",
            "event":{"type":"message_delta","usage":{"input_tokens":2,"output_tokens":5}}
        }));
        let usage = &out.notifications[0]["params"]["tokenUsage"]["last"];
        assert_eq!(usage["cachedInputTokens"], json!(0));
        assert_eq!(usage["totalTokens"], json!(7));
    }
}
