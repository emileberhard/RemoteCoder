use serde::{Deserialize, Serialize};

use crate::agents::jobs::model::{
    AgentRecord, ConversationBinding, ConversationIdentity, ExecutionSettings, JobId, JobRecord,
    JobSpec, Provider,
};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum Caller {
    Operator,
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
    pub job: JobRecord,
    pub duplicate: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct JobView {
    pub job: JobRecord,
    pub agent: Option<AgentRecord>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct JobSummary {
    pub job_id: JobId,
    pub agent_id: String,
    pub conversation: ConversationBinding,
    pub provider: Provider,
    pub cwd: Option<std::path::PathBuf>,
    pub title: Option<String>,
    pub model: Option<String>,
    pub state: crate::agents::State,
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
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CaptureParams {
    pub pid: u32,
    pub started_at_unix_micros: u64,
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
