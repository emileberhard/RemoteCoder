use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::agents::jobs::model::{
    ConversationIdentity, JobId, JobSpec, Origin, Recipient, ToolScope,
};

pub(crate) const PROTOCOL: u32 = 1;
pub(crate) const CAPABILITIES: &[&str] = &[
    "cluster.v1",
    "agent.jobs.v1",
    "agent.parent.v1",
    "sessions.v1",
];

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct AgentAddress {
    pub host_id: String,
    pub thread_id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ErrorClass {
    Usage,
    NotFound,
    Refused,
    Unavailable,
    Uncertain,
    Unsupported,
    Conflict,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct MemberRecord {
    pub protocol: u32,
    pub host: String,
    pub membership: String,
    pub state: MemberState,
    pub name: String,
    pub routes: Vec<String>,
    pub pin: String,
    pub issued_digest: String,
    pub credential: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum MemberState {
    Active,
    RemovePending,
    Removed,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct IssueParams {
    pub protocol: u32,
    pub r#for: String,
    pub name: String,
    pub membership: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct IssueReceipt {
    pub protocol: u32,
    pub host: String,
    pub incarnation: String,
    pub membership: String,
    pub pin: String,
    pub routes: Vec<String>,
    pub credential: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct AcceptParams {
    pub protocol: u32,
    pub host: String,
    pub name: String,
    pub membership: String,
    pub pin: String,
    pub routes: Vec<String>,
    pub credential: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RemoveParams {
    pub protocol: u32,
    pub host: String,
    pub membership: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct HelloParams {
    pub protocol: u32,
    pub host: String,
    pub incarnation: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct HelloReceipt {
    pub version: String,
    pub protocol: u32,
    pub host: String,
    pub incarnation: String,
    pub capabilities: Vec<String>,
    pub routes: Vec<String>,
    pub load: HostLoad,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct HostLoad {
    pub cpu_percent: Option<f64>,
    pub memory_pressure: Option<MemoryPressure>,
    pub active_agents: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum CallerAuthority {
    Operator,
    Agent {
        conversation: ConversationIdentity,
        scope: ToolScope,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(
    tag = "kind",
    content = "input",
    rename_all = "snake_case",
    deny_unknown_fields
)]
pub(crate) enum AdmissionOperation {
    Start(JobSpec),
    Continue(crate::wire::agent_jobs::ContinueParams),
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct AdmitParams {
    pub protocol: u32,
    pub job_id: JobId,
    pub fingerprint: String,
    pub incarnation: String,
    pub origin: Origin,
    pub recipient: Recipient,
    pub operation: AdmissionOperation,
    pub caller_authority: CallerAuthority,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DeliverParams {
    pub protocol: u32,
    pub conversation: ConversationIdentity,
    pub incarnation: String,
    pub delivery_id: String,
    pub text: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct StopParams {
    pub protocol: u32,
    pub job_id: JobId,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ForwardParams {
    pub incarnation: String,
    pub protocol: u32,
    pub caller_authority: CallerAuthority,
    pub request: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ParentParams {
    pub protocol: u32,
    pub agent: AgentAddress,
    pub parent: Option<AgentAddress>,
    pub caller_authority: CallerAuthority,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RemoteIntent {
    pub created_at: String,
    pub parent: Option<AgentAddress>,
    pub protocol: u32,
    pub host: String,
    pub membership: String,
    pub incarnation: String,
    pub request: AdmitParams,
    pub state: IntentState,
    #[serde(default)]
    pub stop_confirmed: bool,
    #[serde(default)]
    pub transmission_uncertain: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum IntentState {
    Pending,
    Admitted,
    Abandoned,
    StopRequested,
    Unknown,
    Removed,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CancelFence {
    pub protocol: u32,
    pub host: String,
    pub membership: String,
    pub job_id: JobId,
    pub at: i64,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(crate) enum MemoryPressure {
    Normal,
    Warn,
    Critical,
}
