use serde::{Deserialize, Serialize};

use crate::agents::jobs::model::{
    AgentRecord, ConversationBinding, ConversationIdentity, ExecutionSettings, JobId, JobRecord,
    JobSpec, Provider,
};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum Caller {
    Operator,
    #[serde(skip_deserializing)]
    Forwarded {
        host: String,
        membership: String,
        incarnation: String,
        authority: crate::wire::cluster::CallerAuthority,
        admission_fingerprint: Option<String>,
    },
    Captured {
        #[serde(rename = "contextId")]
        context_id: String,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct StartParams {
    pub job_id: JobId,
    pub spec: JobSpec,
    pub caller: Caller,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum ContinueRecipient {
    Previous,
    Current,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ContinueIntent {
    #[default]
    Explicit,
    Message,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ContinueParams {
    pub job_id: JobId,
    pub agent_id: String,
    pub prompt: String,
    pub settings: Option<ExecutionSettings>,
    #[serde(default)]
    pub expected_previous_job_id: Option<JobId>,
    #[serde(default)]
    pub intent: ContinueIntent,
    pub recipient: ContinueRecipient,
    pub caller: Caller,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ReadParams {
    pub job_id: JobId,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum ListSelector {
    Recent,
    Agent {
        #[serde(rename = "agentId")]
        agent_id: String,
    },
    Caller {
        caller: Caller,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ListParams {
    pub selector: ListSelector,
    pub limit: u32,
    pub cursor: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum MessageTarget {
    Selector {
        selector: String,
    },
    Conversation {
        conversation: ConversationIdentity,
    },
    Job {
        #[serde(rename = "jobId")]
        job_id: JobId,
    },
    Parent,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct MessageParams {
    pub target: MessageTarget,
    pub caller: Caller,
    pub delivery_id: String,
    pub text: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct MessageReadParams {
    pub delivery_id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct StopParams {
    pub job_id: JobId,
    pub mutation_id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DismissParams {
    pub job_id: JobId,
    pub mutation_id: String,
    pub reason: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct AdmissionReceipt {
    pub protocol: u32,
    pub owner_host_id: String,
    pub job_id: JobId,
    pub address: Option<crate::wire::cluster::AgentAddress>,
    pub state: crate::agents::State,
    pub incarnation: String,
    pub job: JobRecord,
    pub duplicate: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct JobView {
    #[serde(default)]
    pub owner_host_id: Option<String>,
    #[serde(default)]
    pub parent: Option<crate::wire::cluster::AgentAddress>,
    #[serde(default)]
    pub recipient: Option<crate::agents::jobs::model::Recipient>,
    pub job: JobRecord,
    pub agent: Option<AgentRecord>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct JobSummary {
    #[serde(default)]
    pub owner_host_id: Option<String>,
    #[serde(default)]
    pub parent: Option<crate::wire::cluster::AgentAddress>,
    #[serde(default)]
    pub recipient: Option<crate::agents::jobs::model::Recipient>,
    pub job_id: JobId,
    pub agent_id: String,
    pub conversation: ConversationBinding,
    pub provider: Provider,
    pub cwd: Option<std::path::PathBuf>,
    pub title: Option<String>,
    pub model: Option<String>,
    pub state: crate::agents::State,
    pub active: bool,
    pub created_at_ms: Option<i64>,
    pub updated_at_ms: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ListPage {
    pub jobs: Vec<JobSummary>,
    pub next_cursor: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", try_from = "CaptureWire")]
pub(crate) struct CaptureParams {
    pub pid: u32,
    pub birth: crate::platform::process::ProcessBirth,
}

#[derive(Deserialize)]
#[serde(untagged, deny_unknown_fields)]
enum CaptureWire {
    Current {
        pid: u32,
        birth: crate::platform::process::ProcessBirth,
    },
    Darwin {
        pid: u32,
        #[serde(rename = "startedAtUnixMicros")]
        started_micros: u64,
    },
}

impl TryFrom<CaptureWire> for CaptureParams {
    type Error = &'static str;

    fn try_from(wire: CaptureWire) -> Result<Self, Self::Error> {
        let (pid, birth) = match wire {
            CaptureWire::Current { pid, birth } => (pid, birth),
            CaptureWire::Darwin {
                pid,
                started_micros,
            } => (
                pid,
                crate::platform::process::ProcessBirth::Darwin { started_micros },
            ),
        };
        if pid == 0 || !birth.is_valid() {
            return Err("caller requires a compatible process birth proof");
        }
        Ok(Self { pid, birth })
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CapturedContext {
    pub context_id: String,
    pub provider: Provider,
    pub thread_id: String,
    pub turn_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ContextReadParams {
    pub caller: Caller,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ContextView {
    pub context: CapturedContext,
    pub conversation: ConversationIdentity,
    pub sender_id: String,
    pub job_id: Option<JobId>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SetTitleParams {
    pub caller: Caller,
    pub mutation_id: String,
    pub title: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(
    tag = "method",
    content = "params",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub(crate) enum ScopedRequest {
    Capture {},
    Legacy {
        socket: std::path::PathBuf,
        request: Box<ScopedRequest>,
    },
    ReadSelf {},
    ReadMessage {
        #[serde(rename = "deliveryId")]
        delivery_id: String,
    },
    MessageParent {
        #[serde(rename = "deliveryId")]
        delivery_id: String,
        text: String,
    },
    SetTitle {
        #[serde(rename = "mutationId")]
        mutation_id: String,
        title: String,
    },
}

#[cfg(test)]
mod capture_tests {
    use super::*;
    use crate::platform::process::{LinuxBirth, ProcessBirth};
    use serde_json::json;

    #[test]
    fn capture_birth_is_camel_case_and_has_exactly_one_form() {
        let legacy = json!({"pid":42,"startedAtUnixMicros":123});
        let current = json!({"pid":42,"birth":{"platform":"darwin","startedMicros":123}});
        let linux = json!({"pid":42,"birth":{"platform":"linux","birth":{"bootId":"01234567-89ab-cdef-0123-456789abcdef","startTicks":123}}});
        assert_eq!(
            serde_json::to_value(CaptureParams {
                pid: 42,
                birth: ProcessBirth::Darwin {
                    started_micros: 123
                }
            })
            .unwrap(),
            current
        );
        assert_eq!(
            serde_json::from_value::<CaptureParams>(legacy.clone()).is_ok(),
            cfg!(target_os = "macos")
        );
        assert_eq!(
            serde_json::from_value::<CaptureParams>(current.clone()).is_ok(),
            cfg!(target_os = "macos")
        );
        assert_eq!(
            serde_json::from_value::<CaptureParams>(linux).is_ok(),
            cfg!(target_os = "linux")
        );
        let mut contradictory = current;
        contradictory["startedAtUnixMicros"] = 123.into();
        assert!(serde_json::from_value::<CaptureParams>(contradictory).is_err());
        let bad = json!({"pid":42,"birth":{"platform":"darwin","started_micros":123}});
        assert!(serde_json::from_value::<CaptureParams>(bad).is_err());
        assert!(serde_json::from_value::<CaptureParams>(json!({"pid":0,"birth":ProcessBirth::Linux {birth:LinuxBirth{boot_id:*b"01234567-89ab-cdef-0123-456789abcdef",start_ticks:123}}})).is_err());
    }
}
