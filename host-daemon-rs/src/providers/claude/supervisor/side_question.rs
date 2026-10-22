use super::ClaudeSupervisor;
use crate::providers::claude::translate::billing_violation;
use crate::providers::claude::{exec as claude_exec, session_uuid_from_thread_id};
use serde_json::{Value, json};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};

const DETACHED_ANSWER_TIMEOUT: Duration = Duration::from_secs(60);
const MAX_DETACHED_OUTPUT_BYTES: u64 = 1024 * 1024;

impl ClaudeSupervisor {
    pub(crate) async fn side_question(
        &self,
        thread_id: &str,
        question: &str,
    ) -> Result<Option<String>, String> {
        let pid = self
            .runtimes
            .lock()
            .await
            .get(thread_id)
            .map(|runtime| runtime.process_group_id);
        let Some(pid) = pid else {
            return Ok(None);
        };
        let prepared = Self::prepare_runtime_control(
            &json!({ "subtype": "side_question", "question": question }),
        )
        .map_err(|error| error.message)?;
        let request_id = prepared.request_id().to_owned();
        match self
            .runtime_control_prepared(thread_id, pid, prepared)
            .await
        {
            Ok(response) => side_question_answer(&response).map(Some),
            Err(error) => {
                if error.is_unanswered() {
                    self.cancel_runtime_control(thread_id, pid, &request_id)
                        .await;
                }
                Err(error.message)
            }
        }
    }

    pub(crate) async fn detached_side_question(
        &self,
        thread_id: &str,
        cwd: &str,
        question: &str,
    ) -> Result<String, String> {
        let session = session_uuid_from_thread_id(thread_id).ok_or("invalid Claude thread id")?;
        if self.session_history(cwd, session).is_none() {
            return Err(format!(
                "Claude history for session {session} is missing for cwd {cwd}"
            ));
        }
        let model = match self.conversation_index.parent(thread_id).await {
            Ok(parent) => parent
                .selection
                .map(|selection| selection.selection().model),
            Err(error) => return Err(format!("Claude parent record is unreadable: {error:#}")),
        }
        .unwrap_or_else(|| self.settings.default_model.clone());
        let args = [
            "-p",
            "--resume",
            session,
            "--fork-session",
            "--no-session-persistence",
            "--tools",
            "",
            "--strict-mcp-config",
            "--settings",
            r#"{"fastMode":false}"#,
            "--permission-mode",
            "bypassPermissions",
            "--output-format",
            "stream-json",
            "--verbose",
            "--model",
            &model,
            question,
        ]
        .map(str::to_owned);
        let mut command = claude_exec::command(&self.settings, &args)
            .map_err(|error| format!("failed to prepare claude: {error}"))?;
        command
            .current_dir(cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let group = {
            let mut registry = self
                .process_registry
                .lock()
                .expect("Claude process registry poisoned");
            self.spawn_group(&mut registry, command)
                .map_err(|error| format!("failed to run claude: {error}"))?
        };
        let stdout = group.stdout.ok_or("Claude stdout was not piped")?;
        let mut lines = BufReader::new(stdout.take(MAX_DETACHED_OUTPUT_BYTES)).lines();
        let answer = tokio::time::timeout(DETACHED_ANSWER_TIMEOUT, async {
            let mut initialized = false;
            while let Some(line) = lines
                .next_line()
                .await
                .map_err(|error| format!("failed to read claude output: {error}"))?
            {
                let Ok(record) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                match (record["type"].as_str(), record["subtype"].as_str()) {
                    (Some("system"), Some("init")) => {
                        if let Some(violation) = billing_violation(&record, false) {
                            return Err(format!(
                                "Claude side question was refused: {}",
                                violation.0
                            ));
                        }
                        initialized = true;
                    }
                    (Some("result"), _) if initialized => return detached_answer(&record),
                    (Some("result"), _) => {
                        return Err("Claude answered before reporting its billing state".into());
                    }
                    _ => {}
                }
            }
            Err(if lines.get_ref().get_ref().limit() == 0 {
                "Claude side question output exceeded 1 MiB".into()
            } else {
                "Claude side question returned no result".into()
            })
        })
        .await
        .map_err(|_| "Claude did not answer the side question within 60 s".to_owned())?;
        drop(group.admission);
        answer
    }
}

fn detached_answer(result: &Value) -> Result<String, String> {
    if result["is_error"] != false || result["subtype"] != "success" {
        return Err(format!(
            "Claude side question failed: {}",
            result["subtype"].as_str().unwrap_or("unknown")
        ));
    }
    result["result"]
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| "Claude returned no side-question answer".into())
}

fn side_question_answer(response: &Value) -> Result<String, String> {
    if response["synthetic"] == true {
        return Err("Claude answered the side question with a synthetic message".into());
    }
    response["response"]
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| "Claude returned no side-question answer".into())
}

#[cfg(test)]
mod tests {
    use super::side_question_answer;
    use serde_json::json;

    #[test]
    fn only_a_real_model_answer_is_returned() {
        assert_eq!(
            side_question_answer(&json!({"response":"Cache-aware titles","synthetic":false})),
            Ok("Cache-aware titles".into())
        );
        assert!(
            side_question_answer(&json!({"response":"API Error: 529","synthetic":true})).is_err()
        );
        assert!(side_question_answer(&json!({"response":null,"synthetic":false})).is_err());
    }
}
