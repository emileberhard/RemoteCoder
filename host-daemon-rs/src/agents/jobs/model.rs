use std::path::PathBuf;

use serde::{Deserialize, Serialize};

pub(crate) const MAX_PROMPT_BYTES: usize = 512 * 1024;
pub(crate) const MAX_RESULT_BYTES: usize = 256 * 1024;
pub(crate) const MAX_JOB_BYTES: u64 = 1024 * 1024;
pub(crate) const MAX_STORE_BYTES: u64 = 512 * 1024 * 1024;
pub(crate) const MAX_UNSETTLED_JOBS: usize = 256;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Provider {
    Codex,
    Claude,
}

impl Provider {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(try_from = "String", into = "String")]
pub(crate) struct JobId(String);

impl JobId {
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }

    pub(crate) fn for_mutation(provider: Provider, mutation_id: &str) -> Result<Self, String> {
        use sha2::{Digest, Sha256};
        if mutation_id.is_empty() || mutation_id.len() > 200 {
            return Err("mutation identity must contain 1–200 bytes".into());
        }
        let digest = Sha256::new()
            .chain_update(b"remotecoder-agent-job\0")
            .chain_update(provider.as_str().as_bytes())
            .chain_update(b"\0")
            .chain_update(mutation_id.as_bytes())
            .finalize();
        let mut time = [0u8; 8];
        time.copy_from_slice(&digest[..8]);
        let mut suffix = [0u8; 4];
        suffix.copy_from_slice(&digest[8..12]);
        Self::try_from(format!(
            "agent-{}-{:019}-{:08x}",
            provider.as_str(),
            u64::from_be_bytes(time) % 10_000_000_000_000_000_000,
            u32::from_be_bytes(suffix)
        ))
    }
}

impl TryFrom<String> for JobId {
    type Error = String;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        let mut parts = value.split('-');
        let valid = parts.next() == Some("agent")
            && matches!(parts.next(), Some("codex" | "claude"))
            && parts
                .next()
                .is_some_and(|part| part.len() == 19 && part.bytes().all(|b| b.is_ascii_digit()))
            && parts.next().is_some_and(|part| {
                part.len() == 8
                    && part
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
            && parts.next().is_none();
        if valid {
            Ok(Self(value))
        } else {
            Err("jobId must be an exact agent run identifier".into())
        }
    }
}

impl From<JobId> for String {
    fn from(value: JobId) -> Self {
        value.0
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ConversationIdentity {
    pub provider: Provider,
    pub provider_home: ProviderHome,
    pub thread_id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum ProviderHome {
    Known { path: PathBuf },
    Unknown { reason: String },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum Origin {
    TopLevel,
    Parent { conversation: ConversationIdentity },
    Unknown { reason: String },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum Recipient {
    None,
    Conversation { conversation: ConversationIdentity },
    Unknown { reason: String },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum ToolScope {
    Full,
    ReadOnly { root: PathBuf },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "provider", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum ExecutionSettings {
    Codex {
        model: String,
        #[serde(rename = "modelProvider")]
        model_provider: String,
        effort: String,
        #[serde(rename = "serviceTier")]
        service_tier: Option<String>,
        #[serde(rename = "cyberAccessProgram")]
        cyber_access_program: Option<CyberAccessProgram>,
    },
    Claude {
        model: String,
        effort: Option<String>,
        fast: bool,
    },
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum CyberAccessProgram {
    DaybreakBlue,
}

impl ExecutionSettings {
    pub(crate) fn provider(&self) -> Provider {
        match self {
            Self::Codex { .. } => Provider::Codex,
            Self::Claude { .. } => Provider::Claude,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct JobSpec {
    pub prompt: String,
    pub cwd: PathBuf,
    pub settings: ExecutionSettings,
    pub tool_scope: ToolScope,
    pub title: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum SpecEvidence {
    Known {
        spec: JobSpec,
    },
    Expired {
        cwd: PathBuf,
        settings: ExecutionSettings,
        #[serde(rename = "toolScope")]
        tool_scope: ToolScope,
        title: Option<String>,
    },
    Unknown {
        reason: String,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ExecutionBinding {
    pub conversation: ConversationIdentity,
    pub input_id: String,
    pub turn_id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum GitSnapshot {
    Known {
        head: String,
        branch: Option<String>,
        dirty: bool,
    },
    Unknown {
        reason: String,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct JobResult {
    pub text: String,
    pub truncated: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum ResultEvidence {
    Available { result: JobResult },
    Unavailable { reason: String },
    Expired,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum JobOutcome {
    Completed,
    Failed { reason: String },
    Stopped { effects: EffectEvidence },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum EffectEvidence {
    NotStarted,
    MayHaveRun,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum CompletionPayload {
    Prepared {
        #[serde(rename = "deliveryId")]
        delivery_id: String,
        fingerprint: String,
        text: String,
    },
    HistoricalUnreplayable {
        #[serde(rename = "deliveryId")]
        delivery_id: Option<String>,
        fingerprint: Option<String>,
        reason: String,
    },
    Expired {
        #[serde(rename = "deliveryId")]
        delivery_id: String,
        fingerprint: String,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum DeliveryState {
    Pending,
    Sending { attempt: u32 },
    Submitted { route: String },
    Accepted { receipt: String },
    Recorded { receipt: String },
    Uncertain { reason: String },
    Blocked { reason: String },
    Unreachable { reason: String },
    Dismissed { reason: String },
    Failed { reason: String },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum Completion {
    NotRequired,
    Required {
        payload: CompletionPayload,
        delivery: DeliveryState,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Terminal {
    pub at_ms: Option<i64>,
    pub execution: Option<ExecutionBinding>,
    pub git: GitSnapshot,
    pub outcome: JobOutcome,
    pub result: ResultEvidence,
    pub completion: Completion,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum ExecutionState {
    Admitted,
    Bound {
        conversation: ConversationIdentity,
    },
    Dispatching {
        conversation: ConversationIdentity,
        #[serde(rename = "inputId")]
        input_id: String,
    },
    Running {
        binding: ExecutionBinding,
    },
    Recovering {
        binding: ExecutionBinding,
        #[serde(rename = "recoveryInputId")]
        recovery_input_id: Option<String>,
    },
    Unknown {
        conversation: Option<ConversationIdentity>,
        reason: String,
    },
    Terminal {
        terminal: Terminal,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum StopState {
    NotRequested,
    Requested {
        #[serde(rename = "mutationId")]
        mutation_id: String,
        #[serde(rename = "atMs")]
        at_ms: i64,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct JobRecord {
    pub job_id: JobId,
    pub agent_id: String,
    pub request_fingerprint: Option<String>,
    pub created_at_ms: Option<i64>,
    pub updated_at_ms: i64,
    pub revision: u64,
    pub previous_job_id: Option<JobId>,
    pub source: JobSource,
    pub admission_origin: Option<Origin>,
    pub unconfirmed_result: Option<JobResult>,
    pub spec: SpecEvidence,
    pub recipient: Recipient,
    pub execution: ExecutionState,
    pub stop: StopState,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum JobSource {
    Runtime,
    Imported,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum ConversationBinding {
    Known { conversation: ConversationIdentity },
    Unknown { reason: String },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct AgentRecord {
    pub agent_id: String,
    pub conversation: ConversationBinding,
    pub origin: Origin,
    pub tool_scope: Option<ToolScope>,
    pub origin_job_id: Option<JobId>,
    pub latest_job_id: Option<JobId>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ImportedUncertainty {
    pub evidence_id: String,
    pub source_run_id: String,
    pub provider: Option<Provider>,
    pub provider_home: Option<PathBuf>,
    pub thread_id: Option<String>,
    pub parent_home: Option<PathBuf>,
    pub parent_thread_id: Option<String>,
    pub latest_possible_creation_ms: Option<i64>,
    pub reason: String,
}

pub(crate) enum Inspection {
    Prepared,
    Running { binding: ExecutionBinding },
    Recoverable { binding: ExecutionBinding },
    Unknown { reason: String },
    Finished { outcome: JobOutcome, result: ResultEvidence },
}
