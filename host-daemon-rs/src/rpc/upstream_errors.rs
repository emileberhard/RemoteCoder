use super::PendingRequest;
use super::error::{ErrorKind, RpcCode};
use serde_json::Value;

const NO_ACTIVE_TURN_TO_STEER: &str = "no active turn to steer";
const INVALID_CURSOR: &str = "invalid cursor";

fn upstream_error_kind(message: &Value, request: &PendingRequest) -> Option<ErrorKind> {
    let error = message.get("error")?;
    if error.get("code")?.as_i64()? != RpcCode::InvalidRequest.value() {
        return None;
    }
    let text = error.get("message")?.as_str()?;
    match request.method {
        "turn/steer" if text == NO_ACTIVE_TURN_TO_STEER => Some(ErrorKind::TurnNotRunning {
            thread_id: request.thread_id.clone()?,
            turn_id: request.turn_id.clone(),
        }),
        "thread/turns/list" | "thread/items/list" if text.starts_with(INVALID_CURSOR) => {
            Some(ErrorKind::HistoryCursorInvalid)
        }
        _ => None,
    }
}

pub(crate) fn tag_upstream_error(message: &Value, request: &PendingRequest) -> Option<Value> {
    let kind = upstream_error_kind(message, request)?;
    let mut tagged = message.clone();
    tagged["error"]["data"] = kind.to_value();
    Some(tagged)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::process::Command;

    fn request(method: &'static str) -> PendingRequest {
        PendingRequest::new(
            method,
            Some(&json!({"threadId": "thread-1", "expectedTurnId": "turn-1"})),
        )
    }

    fn failure(code: i64, text: &str) -> Value {
        json!({"id": 3, "error": {"code": code, "message": text}})
    }

    #[test]
    fn a_steer_with_no_running_turn_becomes_turn_not_running() {
        let tagged = tag_upstream_error(
            &failure(-32600, NO_ACTIVE_TURN_TO_STEER),
            &request("turn/steer"),
        )
        .expect("tagged");

        assert_eq!(tagged["error"]["code"], -32600);
        assert_eq!(tagged["error"]["message"], NO_ACTIVE_TURN_TO_STEER);
        assert_eq!(
            tagged["error"]["data"],
            json!({
                "kind": "turnNotRunning", "retryable": false,
                "threadId": "thread-1", "turnId": "turn-1"
            })
        );
    }

    #[test]
    fn an_invalid_history_cursor_becomes_history_cursor_invalid() {
        for method in ["thread/turns/list", "thread/items/list"] {
            for text in [
                "invalid cursor: anchor turn is no longer present",
                "invalid cursor: {\"turnId\":\"gone\"}",
            ] {
                let tagged =
                    tag_upstream_error(&failure(-32600, text), &request(method)).expect("tagged");
                assert_eq!(
                    tagged["error"]["data"],
                    json!({"kind": "historyCursorInvalid", "retryable": false})
                );
            }
        }
    }

    #[test]
    fn other_upstream_failures_stay_untagged() {
        let steer = request("turn/steer");
        assert!(
            tag_upstream_error(
                &failure(-32600, "expected active turn id a but found b"),
                &steer
            )
            .is_none()
        );
        assert!(tag_upstream_error(&failure(-32603, NO_ACTIVE_TURN_TO_STEER), &steer).is_none());
        assert!(tag_upstream_error(&failure(-32600, "invalid cursor: x"), &steer).is_none());
        assert!(
            tag_upstream_error(
                &failure(-32600, NO_ACTIVE_TURN_TO_STEER),
                &request("thread/turns/list")
            )
            .is_none()
        );
        assert!(
            tag_upstream_error(&json!({"id": 3, "result": {}}), &request("turn/steer")).is_none()
        );
    }

    #[test]
    fn the_matched_texts_are_the_ones_the_pinned_fork_sends() {
        let commit = env!("RC_REQUIRED_CODEX_SOURCE_COMMIT");
        let fork = std::env::var_os("RC_CODEX_FORK_DIR")
            .map(std::path::PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME")
                    .map(|home| std::path::Path::new(&home).join("forks/oai-codex"))
            })
            .filter(|path| path.join(".git").exists());
        let Some(fork) = fork else {
            eprintln!("skipped: no Codex fork checkout (set RC_CODEX_FORK_DIR)");
            return;
        };
        let source = |file: &str| {
            let shown = Command::new("git")
                .arg("-C")
                .arg(&fork)
                .arg("show")
                .arg(format!(
                    "{commit}:codex-rs/app-server/src/request_processors/{file}"
                ))
                .output()
                .expect("git runs");
            assert!(
                shown.status.success(),
                "fork {commit} has no {file}: {}",
                String::from_utf8_lossy(&shown.stderr)
            );
            String::from_utf8(shown.stdout).expect("UTF-8 source")
        };

        assert!(source("turn_processor.rs").contains(&format!("\"{NO_ACTIVE_TURN_TO_STEER}\"")));
        assert!(source("thread_processor.rs").contains(&format!("\"{INVALID_CURSOR}: ")));
    }
}
