use serde_json::Value;

pub(super) const MAX_PROVIDER_RETRIES: usize = 5;
pub(super) const CONTINUATION_PROMPT: &str = "The previous attempt ended with a transient provider error. Continue the same delegated job from this conversation's history and current state. Inspect existing results and effects before acting; do not repeat completed actions or blindly replay any action whose outcome is uncertain.";

pub(super) fn is_transient(error: &Value) -> bool {
    match error["codexErrorInfo"].as_str() {
        Some("serverOverloaded" | "flexUnavailable" | "rateLimitExceeded" | "internalServerError") => true,
        Some(
            "httpConnectionFailed"
            | "responseStreamConnectionFailed"
            | "responseStreamDisconnected"
            | "responseTooManyFailedAttempts",
        ) => match error.get("httpStatusCode") {
            None | Some(Value::Null) => true,
            Some(status) => matches!(status.as_u64(), Some(408 | 429 | 500..=599)),
        },
        _ => false,
    }
}

pub(super) fn retry_at_ms(now_ms: i64, completed_retries: usize, jitter: u64) -> i64 {
    let base = 2_000u64 << completed_retries.min(MAX_PROVIDER_RETRIES);
    let delay = base + jitter % (base + 1);
    now_ms.saturating_add(delay as i64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_proven_transient_provider_failures_retry() {
        for code in [
            "serverOverloaded",
            "flexUnavailable",
            "rateLimitExceeded",
            "internalServerError",
        ] {
            let raw = json!({"message":"provider capacity","codexErrorInfo":code});
            let normalized = crate::wire::gateway::TerminalError::from_wire(Some(&raw)).unwrap();
            assert!(is_transient(&serde_json::to_value(normalized).unwrap()));
        }
        for code in [
            "httpConnectionFailed",
            "responseStreamConnectionFailed",
            "responseStreamDisconnected",
            "responseTooManyFailedAttempts",
        ] {
            for status in [408, 429, 500, 503, 599] {
                assert!(is_transient(
                    &json!({"codexErrorInfo":code,"httpStatusCode":status})
                ));
            }
            for status in [400, 401, 403, 404] {
                assert!(!is_transient(
                    &json!({"codexErrorInfo":code,"httpStatusCode":status})
                ));
            }
            assert!(is_transient(&json!({"codexErrorInfo":code})));
            assert!(is_transient(
                &json!({"codexErrorInfo":code,"httpStatusCode":null})
            ));
            assert!(!is_transient(
                &json!({"codexErrorInfo":code,"httpStatusCode":"503"})
            ));
        }
        for code in [
            "unauthorized",
            "usageLimitExceeded",
            "sessionBudgetExceeded",
            "contextWindowExceeded",
            "cyberPolicy",
            "badRequest",
            "other",
        ] {
            assert!(!is_transient(
                &json!({"codexErrorInfo":code,"message":"Selected model is at capacity"})
            ));
        }
        assert!(!is_transient(&Value::Null));
    }

    #[test]
    fn deterministic_clock_and_jitter_bound_exponential_retry_delays() {
        for attempt in 0..MAX_PROVIDER_RETRIES {
            let base = 2_000i64 << attempt;
            assert_eq!(retry_at_ms(100, attempt, 0), 100 + base);
            assert_eq!(retry_at_ms(100, attempt, base as u64), 100 + 2 * base);
        }
        assert_eq!(retry_at_ms(i64::MAX, 0, 0), i64::MAX);
    }
}
