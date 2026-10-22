//! Public params use camelCase; the service's definition and event objects stay opaque.
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct AutomationParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Map<String, Value>>,
    #[serde(
        default,
        rename(deserialize = "replaceDefinition"),
        skip_serializing_if = "Option::is_none"
    )]
    pub replace_definition: Option<bool>,
    #[serde(
        default,
        rename(deserialize = "requestId"),
        skip_serializing_if = "Option::is_none"
    )]
    pub request_id: Option<String>,
    #[serde(
        default,
        rename(deserialize = "expectedRevision"),
        skip_serializing_if = "Option::is_none"
    )]
    pub expected_revision: Option<u64>,
    #[serde(
        default,
        rename(deserialize = "targetRevision"),
        skip_serializing_if = "Option::is_none"
    )]
    pub target_revision: Option<u64>,
    #[serde(
        default,
        rename(deserialize = "includeRemoved"),
        skip_serializing_if = "Option::is_none"
    )]
    pub include_removed: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub search: Option<String>,
    #[serde(
        default,
        rename(deserialize = "dryRun"),
        skip_serializing_if = "Option::is_none"
    )]
    pub dry_run: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub offset: Option<u64>,
    #[serde(
        default,
        rename(deserialize = "runId"),
        skip_serializing_if = "Option::is_none"
    )]
    pub run_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cancel: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub invocation: Option<Map<String, Value>>,
    #[serde(
        default,
        rename(deserialize = "parentRunId"),
        skip_serializing_if = "Option::is_none"
    )]
    pub parent_run_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acknowledge: Option<bool>,
    #[serde(
        default,
        rename(deserialize = "outputOffset"),
        skip_serializing_if = "Option::is_none"
    )]
    pub output_offset: Option<u64>,
    #[serde(
        default,
        rename(deserialize = "outputLimit"),
        skip_serializing_if = "Option::is_none"
    )]
    pub output_limit: Option<u32>,
}
