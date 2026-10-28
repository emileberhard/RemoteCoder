use std::path::PathBuf;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{Store, under_guards};
use crate::agents::jobs::model::{
    ConversationIdentity, JobId, JobOutcome, MAX_JOB_BYTES, MAX_RESULT_BYTES, ToolScope,
};
use crate::providers::claude::records::read_record;
use crate::storage::private_state;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct JobHandle {
    pub job_id: JobId,
    pub evidence_path: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ProcessOwner {
    pub pid: i32,
    pub started_micros: u64,
    pub session_uuid: String,
}

impl ProcessOwner {
    pub(crate) fn alive(&self) -> Result<bool> {
        Ok(crate::platform::process::identify(self.pid)?
            .is_some_and(|identity| identity.started_micros == self.started_micros))
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Candidate {
    pub text: Option<String>,
    pub truncated: bool,
    pub failed: bool,
    pub failure: Option<String>,
    #[serde(default)]
    pub api_error_status: Option<u16>,
    #[serde(default)]
    pub terminal_reason: Option<String>,
}

impl Candidate {
    pub(crate) fn transient_failure(&self) -> bool {
        self.failed
            && matches!(
                self.failure.as_deref(),
                Some("success" | "error_during_execution")
            )
            && self
                .terminal_reason
                .as_deref()
                .is_none_or(|reason| reason == "api_error")
            && matches!(self.api_error_status, Some(408 | 429 | 500..=599))
    }

    fn from_result(frame: &Value) -> Self {
        let original = frame.get("result").and_then(Value::as_str);
        let text = original.map(|text| {
            let mut remaining = MAX_RESULT_BYTES.saturating_sub(2);
            let mut begin = text.len();
            for (index, character) in text.char_indices().rev() {
                let encoded = match character {
                    '"' | '\\' | '\n' | '\r' | '\t' | '\u{08}' | '\u{0c}' => 2,
                    '\u{00}'..='\u{1f}' => 6,
                    other => other.len_utf8(),
                };
                if encoded > remaining {
                    break;
                }
                remaining -= encoded;
                begin = index;
            }
            text[begin..].to_owned()
        });
        let failed = frame.get("is_error").and_then(Value::as_bool) == Some(true);
        Self {
            truncated: original
                .zip(text.as_ref())
                .is_some_and(|(original, saved)| original.len() != saved.len()),
            text,
            failed,
            api_error_status: frame
                .get("api_error_status")
                .and_then(Value::as_u64)
                .and_then(|status| u16::try_from(status).ok()),
            terminal_reason: frame
                .get("terminal_reason")
                .and_then(Value::as_str)
                .map(|reason| reason.chars().take(128).collect()),
            failure: failed.then(|| {
                frame
                    .get("subtype")
                    .and_then(Value::as_str)
                    .unwrap_or("Claude returned an error result")
                    .chars()
                    .take(512)
                    .collect()
            }),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum JobPhase {
    Prepared,
    Executing,
    Closing,
    Stopping,
    Interrupted,
    Finished { outcome: JobOutcome },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct JobInput {
    pub id: String,
    pub fingerprint: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RecoveryInput {
    pub input: JobInput,
    pub captured_at_unix_ms: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct JobEvidence {
    pub job_id: JobId,
    pub conversation: ConversationIdentity,
    pub input: JobInput,
    pub recovery_input: Option<RecoveryInput>,
    pub tool_scope: ToolScope,
    pub coordination_socket: PathBuf,
    pub stop_generation: u64,
    pub turn_id: Option<String>,
    pub owner: Option<ProcessOwner>,
    pub input_consumed: bool,
    pub input_recorded: bool,
    pub ordinary_result_seen: bool,
    pub nonambient_tasks: Vec<String>,
    pub candidate: Option<Candidate>,
    pub phase: JobPhase,
}

impl JobEvidence {
    pub(crate) fn current_input(&self) -> &JobInput {
        self.recovery_input
            .as_ref()
            .map_or(&self.input, |saved| &saved.input)
    }
    pub(crate) fn eligible(&self) -> bool {
        self.input_consumed && self.ordinary_result_seen && self.nonambient_tasks.is_empty()
    }

    pub(crate) fn observe(
        &mut self,
        frame: &Value,
        consumed: &[String],
        nonambient_tasks: Vec<String>,
    ) -> Result<()> {
        let mut next = self.clone();
        next.input_consumed |= consumed.contains(&self.current_input().id);
        next.nonambient_tasks = nonambient_tasks;
        if frame.get("type").and_then(Value::as_str) == Some("result")
            && frame.get("parent_tool_use_id").is_none_or(Value::is_null)
        {
            next.candidate = Some(Candidate::from_result(frame));
            if next.input_consumed
                && frame.pointer("/origin/kind").and_then(Value::as_str)
                    != Some("task-notification")
            {
                next.ordinary_result_seen = true;
            }
        }
        ensure!(
            !matches!(self.phase, JobPhase::Finished { .. }) || next == *self,
            "Claude produced new execution evidence after the job's final result committed"
        );
        *self = next;
        Ok(())
    }
}

fn load(handle: &JobHandle) -> Result<Option<JobEvidence>> {
    let Some(bytes) = read_record(&handle.evidence_path, MAX_JOB_BYTES)? else {
        return Ok(None);
    };
    let evidence: JobEvidence =
        serde_json::from_slice(&bytes).context("invalid Claude job evidence")?;
    ensure!(
        evidence.job_id == handle.job_id,
        "Claude job evidence belongs to a different job"
    );
    Ok(Some(evidence))
}

impl Store {
    pub(crate) async fn job(
        &self,
        thread: &str,
        handle: &JobHandle,
    ) -> Result<Option<JobEvidence>> {
        let guard = self.thread(thread).await.lock_owned().await;
        let handle = handle.clone();
        under_guards(guard, move |_| load(&handle)).await?
    }

    pub(crate) async fn prepare_job(
        &self,
        evidence: JobEvidence,
        handle: &JobHandle,
    ) -> Result<JobEvidence> {
        let expected = evidence.clone();
        self.transact_job(&evidence.conversation.thread_id, handle, move |saved| {
            if let Some(saved) = saved {
                ensure!(
                    saved.conversation == expected.conversation
                        && saved.input == expected.input
                        && saved.tool_scope == expected.tool_scope,
                    "Claude job identity conflicts with its prepared execution"
                );
                return Ok(saved.clone());
            }
            *saved = Some(expected.clone());
            Ok(expected)
        })
        .await
    }

    pub(crate) async fn update_job<T: Send + 'static>(
        &self,
        thread: &str,
        handle: &JobHandle,
        operation: impl FnOnce(&mut JobEvidence) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        self.transact_job(thread, handle, move |saved| {
            operation(saved.as_mut().context("Claude job evidence is missing")?)
        })
        .await
    }

    pub(crate) async fn admit_job_input<T: Send + 'static>(
        &self,
        thread: &str,
        handle: &JobHandle,
        submit: impl FnOnce() -> T + Send + 'static,
    ) -> Result<T> {
        self.transact_job(thread, handle, move |saved| {
            let saved = saved.as_ref().context("Claude job evidence is missing")?;
            ensure!(
                matches!(saved.phase, JobPhase::Executing),
                "Claude job no longer admits input"
            );
            Ok(submit())
        })
        .await
    }

    async fn transact_job<T: Send + 'static>(
        &self,
        thread: &str,
        handle: &JobHandle,
        operation: impl FnOnce(&mut Option<JobEvidence>) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let guard = self.thread(thread).await.lock_owned().await;
        let handle = handle.clone();
        under_guards(guard, move |_| {
            private_state::transaction(
                &handle.evidence_path,
                "Claude job evidence has no parent directory",
                |_| {
                    private_state::remove_dead_writer_temporaries(&handle.evidence_path)?;
                    load(&handle)
                },
                |saved| {
                    let previous = saved.clone();
                    let result = operation(saved)?;
                    Ok((result, *saved != previous))
                },
                |path, saved| {
                    let evidence = saved
                        .as_ref()
                        .context("Claude job evidence cannot be removed by an update")?;
                    let bytes = serde_json::to_vec(evidence)?;
                    ensure!(
                        bytes.len() as u64 <= MAX_JOB_BYTES,
                        "Claude job evidence exceeds its reserved capacity"
                    );
                    private_state::replace(path, &bytes)
                },
            )
        })
        .await?
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn terminal_api_status_is_required_and_quota_or_non_api_limits_do_not_retry() {
        for status in [408, 429, 500, 503, 529] {
            for subtype in ["success", "error_during_execution"] {
                let candidate = Candidate::from_result(&json!({"type":"result", "is_error":true,
                "subtype":subtype, "api_error_status":status, "terminal_reason":"api_error"}));
                assert!(candidate.transient_failure());
            }
        }
        for (status, reason, subtype) in [
            (401, "api_error", "error_during_execution"),
            (403, "api_error", "error_during_execution"),
            (429, "blocking_limit", "error_during_execution"),
            (503, "budget_exhausted", "error_during_execution"),
            (503, "api_error", "error_max_turns"),
        ] {
            let candidate = Candidate::from_result(&json!({"type":"result", "is_error":true,
                "subtype":subtype,"api_error_status":status,"terminal_reason":reason}));
            assert!(!candidate.transient_failure());
        }
        let untyped = Candidate::from_result(&json!({"type":"result","is_error":true,
            "subtype":"error_during_execution","result":"overloaded, retry later"}));
        assert!(!untyped.transient_failure());
    }

    #[test]
    fn result_tail_bounds_encoded_bytes_and_preserves_utf8() {
        let original = format!("{}finished 🦀", "\0\"🦀".repeat(MAX_RESULT_BYTES));
        let candidate = Candidate::from_result(&json!({"type":"result", "result":original}));
        let saved = candidate.text.unwrap();
        assert!(candidate.truncated);
        assert!(saved.ends_with("finished 🦀"));
        assert!(original.ends_with(&saved));
        assert!(serde_json::to_vec(&saved).unwrap().len() <= MAX_RESULT_BYTES);
    }
}
