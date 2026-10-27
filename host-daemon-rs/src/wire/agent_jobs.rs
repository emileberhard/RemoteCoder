use serde::{Deserialize, Serialize};

use crate::agents::jobs::model::{ExecutionSettings, JobId, JobRecord, JobSpec};

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
    Current { caller: Caller },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ContinueParams {
    pub job_id: JobId,
    pub agent_id: String,
    pub prompt: String,
    pub settings: Option<ExecutionSettings>,
    pub recipient: ContinueRecipient,
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
