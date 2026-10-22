use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::Value;
use std::{
    path::{Path, PathBuf},
    process::Stdio,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Run {
    pub run_id: String,
    pub thread_id: String,
    pub provider: String,
    pub relationship_known: bool,
    pub provider_home: Option<PathBuf>,
    pub parent_thread_id: Option<String>,
    pub parent_home: Option<PathBuf>,
    pub title: String,
    pub model: Option<String>,
    pub state: super::State,
    #[serde(default)]
    pub can_open_conversation: bool,
    pub can_message: bool,
    pub can_stop: bool,
    pub can_continue: bool,
    pub resumed_from_run: Option<String>,
    #[serde(default, rename = "lastActiveAt")]
    pub last_active_at_ms: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Page {
    pub schema_version: u32,
    pub data: Vec<Run>,
    pub next_cursor: Option<String>,
    pub warnings: Vec<String>,
}

/// Only the launcher-owned v2 coverage contract proves non-delegation. These
/// codes are deliberately fixed; warning copy and unrelated rows are not proof.
const COVERAGE_REASONS: &[&str] = &[
    "indexUnavailable",
    "indexBuilding",
    "indexStale",
    "indexUnreadable",
    "indexCorrupt",
    "unsupportedIndexVersion",
    "invalidSubject",
    "metadataUnreadable",
    "identityPending",
    "identityUnknown",
    "historyOwnershipUnknown",
    "lineageUnknown",
    "resumeOriginUnknown",
    "lineageConflict",
    "unscopedLaunchAttempt",
    "legacyEventsIncomplete",
    "descendantIdentityUnknown",
    "descendantLimitReached",
    "coverageBudgetExceeded",
    "retentionLimitReached",
];

#[derive(Debug)]
pub(crate) struct CoverageUnavailable(pub Vec<&'static str>);

impl std::fmt::Display for CoverageUnavailable {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("Launcher ancestry coverage is unavailable")
    }
}
impl std::error::Error for CoverageUnavailable {}

pub(crate) fn unavailable(reason: &'static str) -> anyhow::Error {
    CoverageUnavailable(vec![reason]).into()
}

pub(crate) fn call_failure(error: anyhow::Error) -> anyhow::Error {
    if error.is::<CoverageUnavailable>() {
        error
    } else {
        unavailable("launcherUnavailable")
    }
}

fn reason_codes(coverage: &Value) -> Result<Vec<&'static str>> {
    let codes = coverage["reasonCodes"]
        .as_array()
        .ok_or_else(|| unavailable("invalidCoverage"))?;
    ensure!(
        codes.len() <= COVERAGE_REASONS.len(),
        CoverageUnavailable(vec!["invalidCoverage"])
    );
    codes
        .iter()
        .map(|code| {
            COVERAGE_REASONS
                .iter()
                .copied()
                .find(|known| Some(*known) == code.as_str())
                .ok_or_else(|| unavailable("unsupportedCoverageReason"))
        })
        .collect()
}

pub(crate) fn subject_relation(response: &Value, home: &Path, thread: &str) -> Result<bool> {
    ensure!(
        response.get("error").is_none(),
        CoverageUnavailable(vec!["launcherOperationRejected"])
    );
    let home = home
        .to_str()
        .ok_or_else(|| unavailable("providerHomeUnavailable"))?;
    ensure!(
        response["schemaVersion"] == 2,
        CoverageUnavailable(vec!["unsupportedLauncherProtocol"])
    );
    let subjects = response["coverage"]["subjects"]
        .as_array()
        .ok_or_else(|| unavailable("missingCoverageSubject"))?;
    let mut matches = subjects.iter().filter(|subject| {
        subject["providerHome"].as_str() == Some(home)
            && subject["threadId"].as_str() == Some(thread)
    });
    let subject = matches
        .next()
        .ok_or_else(|| unavailable("missingCoverageSubject"))?;
    ensure!(
        matches.next().is_none(),
        CoverageUnavailable(vec!["ambiguousCoverageSubject"])
    );
    let codes = reason_codes(subject)?;
    match subject["status"].as_str() {
        Some("complete") if codes.is_empty() => match subject["relation"]["kind"].as_str() {
            // Positive delegation needs no routable parent identity to suppress.
            Some("child") => Ok(true),
            Some("root")
                if ["parentHome", "parentThreadId"]
                    .iter()
                    .all(|key| subject["relation"].get(*key).is_none_or(Value::is_null)) =>
            {
                Ok(false)
            }
            _ => Err(unavailable("invalidCoverageRelation")),
        },
        Some("incomplete" | "unavailable") if !codes.is_empty() => {
            Err(CoverageUnavailable(codes).into())
        }
        _ => Err(unavailable("invalidCoverage")),
    }
}

pub(crate) fn readiness(response: &Value) -> Result<()> {
    ensure!(
        response.get("error").is_none(),
        CoverageUnavailable(vec!["launcherOperationRejected"])
    );
    ensure!(
        response["schemaVersion"] == 2
            && response["supportedVersions"]
                .as_array()
                .is_some_and(|values| values.contains(&serde_json::json!(2)))
            && ["status", "classify"]
                .iter()
                .all(|operation| response["supportedOperations"]
                    .as_array()
                    .is_some_and(|values| values.contains(&serde_json::json!(operation)))),
        CoverageUnavailable(vec!["unsupportedLauncherProtocol"])
    );
    let coverage = &response["coverage"];
    let codes = reason_codes(coverage)?;
    match coverage["status"].as_str() {
        Some("complete") if codes.is_empty() => Ok(()),
        Some("unavailable") if !codes.is_empty() => Err(CoverageUnavailable(codes).into()),
        _ => Err(unavailable("invalidCoverage")),
    }
}

pub(crate) fn default_program() -> Result<PathBuf> {
    if cfg!(test) {
        return Ok(PathBuf::from("/__remotecoder_test_missing_launcher__"));
    }
    Ok(match std::env::var_os("RC_AGENT_WORK_CLI") {
        Some(path) => PathBuf::from(path),
        None => crate::config::HostPaths::from_env()?
            .home()
            .join("configs/bin/agent-work"),
    })
}

pub(crate) async fn call_program(request: Value, program: &Path) -> Result<Value> {
    let mut command = tokio::process::Command::new(program);
    #[cfg(target_os = "macos")]
    crate::platform::macos::scheduling::prepare_agent_command(&mut command);
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .context("Launcher integration is unavailable; install the matching agent-work CLI")?;
    let mut stdin = child.stdin.take().context("Launcher input unavailable")?;
    let stdout = child.stdout.take().context("Launcher output unavailable")?;
    stdin.write_all(&serde_json::to_vec(&request)?).await?;
    stdin.shutdown().await?;
    drop(stdin);
    let mut bytes = Vec::new();
    stdout
        .take(2 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .await?;
    ensure!(
        bytes.len() <= 2 * 1024 * 1024,
        "Launcher response exceeds limit"
    );
    let status = child.wait().await?;
    let result: Value = serde_json::from_slice(&bytes).context("Invalid launcher response")?;
    if request["schemaVersion"] == 2 && result.get("error").is_some() {
        return Err(unavailable(match result["error"]["code"].as_str() {
            Some("unsupportedSchemaVersion" | "unsupportedOperation") => {
                "unsupportedLauncherProtocol"
            }
            _ => "launcherOperationRejected",
        }));
    }
    ensure!(
        status.success(),
        "{}",
        result["error"]
            .as_str()
            .unwrap_or("Launcher operation failed")
    );
    Ok(result)
}

pub(crate) fn project(
    runs: &[Run],
    root: &str,
    homes: &[PathBuf],
    native: &[super::Agent],
) -> Vec<super::Agent> {
    use std::collections::{HashMap, HashSet};
    let mut included: HashMap<(PathBuf, String), Option<String>> = homes
        .iter()
        .map(|home| ((home.clone(), root.to_owned()), None))
        .collect();
    for node in native {
        if let Some(thread) = &node.thread_id {
            for home in homes {
                included.insert((home.clone(), thread.clone()), Some(node.id.clone()));
            }
        }
    }
    let mut seen = HashSet::new();
    let mut nodes = Vec::new();
    for _ in 0..32 {
        let before = nodes.len();
        for origin in runs
            .iter()
            .rev()
            .filter(|run| run.relationship_known && run.resumed_from_run.is_none())
        {
            let Some(home) = &origin.provider_home else {
                continue;
            };
            let identity = (home.clone(), origin.thread_id.clone());
            if seen.contains(&identity) {
                continue;
            }
            let relation = if origin.thread_id == root && homes.contains(home) {
                Some(None)
            } else {
                std::iter::once(origin)
                    .chain(runs.iter().filter(|run| {
                        run.provider_home == origin.provider_home
                            && run.thread_id == origin.thread_id
                    }))
                    .find_map(|run| {
                        let parent = (run.parent_home.clone()?, run.parent_thread_id.clone()?);
                        included.get(&parent).cloned()
                    })
            };
            let Some(parent_id) = relation else { continue };
            let executions = || {
                runs.iter().filter(|run| {
                    run.provider_home == origin.provider_home && run.thread_id == origin.thread_id
                })
            };
            let latest = executions().next().unwrap_or(origin);
            let last_active_at = executions()
                .filter_map(|run| run.last_active_at_ms)
                .filter(|ms| *ms > 0)
                .max()
                .map(|ms| ms / 1000);
            let id = format!("launcher:{}", origin.run_id);
            included.insert(identity.clone(), Some(id.clone()));
            seen.insert(identity);
            nodes.push(super::Agent {
                id,
                parent_id,
                owner_thread_id: root.into(),
                thread_id: Some(origin.thread_id.clone()),
                provider: origin.provider.clone(),
                source: "launcher".into(),
                title: latest.title.clone(),
                model: latest.model.clone(),
                state: latest.state.clone(),
                capabilities: super::Capabilities {
                    inspect: true,
                    open_conversation: latest.can_open_conversation,
                    message: latest.can_message,
                    continue_work: latest.can_continue,
                    stop: latest.can_stop,
                    ..Default::default()
                },
                execution_id: Some(latest.run_id.clone()),
                last_active_at,
            });
            if nodes.len() >= 512 {
                return nodes;
            }
        }
        if before == nodes.len() {
            break;
        }
    }
    nodes
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn coverage_fixture() -> Value {
        json!({"schemaVersion":2,"coverage":{"status":"incomplete","reasonCodes":["lineageUnknown"],"subjects":[
            {"providerHome":"/account","threadId":"root","status":"complete","reasonCodes":[],"relation":{"kind":"root"}},
            {"providerHome":"/unrelated","threadId":"root","status":"complete","reasonCodes":[],"relation":{"kind":"child"}},
            {"providerHome":"/account","threadId":"another","status":"future","reasonCodes":["futureCode"]}
        ]}})
    }

    #[tokio::test]
    async fn rejected_v2_subprocess_preserves_fixed_protocol_error() {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        let program = directory.path().join("launcher");
        for code in ["unsupportedSchemaVersion", "unsupportedOperation", "other"] {
            std::fs::write(&program, format!("#!/bin/sh\ncat >/dev/null\nprintf '%s' '{{\"error\":{{\"code\":\"{code}\"}}}}'\nexit 1\n")).unwrap();
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
            let error = call_failure(
                call_program(json!({"operation":"status","schemaVersion":2}), &program)
                    .await
                    .unwrap_err(),
            );
            assert_eq!(
                error.downcast_ref::<CoverageUnavailable>().unwrap().0,
                [if code == "other" {
                    "launcherOperationRejected"
                } else {
                    "unsupportedLauncherProtocol"
                }]
            );
        }
    }

    #[test]
    fn coverage_is_exact_and_never_inferred_from_summary_warnings_or_parent_routes() {
        let mut response = coverage_fixture();
        assert!(!subject_relation(&response, Path::new("/account"), "root").unwrap());
        assert!(subject_relation(&response, Path::new("/unrelated"), "root").unwrap());
        assert!(subject_relation(&response, Path::new("/wrong-home"), "root").is_err());
        assert!(subject_relation(&response, Path::new("/account"), "missing").is_err());
        response["coverage"]["subjects"][0]["relation"] =
            json!({"kind":"child","parentHome":null,"parentThreadId":null});
        assert!(subject_relation(&response, Path::new("/account"), "root").unwrap());
        let duplicate = response["coverage"]["subjects"][0].clone();
        response["coverage"]["subjects"]
            .as_array_mut()
            .unwrap()
            .push(duplicate);
        assert!(subject_relation(&response, Path::new("/account"), "root").is_err());
    }

    #[test]
    fn missing_malformed_future_or_incomplete_coverage_never_proves_root() {
        for (field, value) in [
            ("status", json!("future")),
            ("reasonCodes", json!(["futureReason"])),
            ("reasonCodes", Value::Null),
            ("relation", json!({"kind":"unknown"})),
            (
                "relation",
                json!({"kind":"root","parentThreadId":"contradictory-parent"}),
            ),
        ] {
            let mut response = coverage_fixture();
            response["coverage"]["subjects"][0][field] = value;
            assert!(subject_relation(&response, Path::new("/account"), "root").is_err());
        }
        let mut response = coverage_fixture();
        response["schemaVersion"] = json!(1);
        assert!(subject_relation(&response, Path::new("/account"), "root").is_err());
        response["schemaVersion"] = json!(2);
        response["error"] = json!({"code":"unsupportedSchemaVersion"});
        assert!(subject_relation(&response, Path::new("/account"), "root").is_err());
        response.as_object_mut().unwrap().remove("error");
        response["coverage"]["subjects"][0]["status"] = json!("incomplete");
        for reason in [
            "unscopedLaunchAttempt",
            "legacyEventsIncomplete",
            "resumeOriginUnknown",
            "coverageBudgetExceeded",
        ] {
            response["coverage"]["subjects"][0]["reasonCodes"] = json!([reason]);
            let error = subject_relation(&response, Path::new("/account"), "root").unwrap_err();
            assert_eq!(
                error.downcast_ref::<CoverageUnavailable>().unwrap().0,
                [reason]
            );
        }
    }

    #[test]
    fn status_is_only_versioned_index_readiness_and_cannot_prove_a_subject() {
        let response = json!({"schemaVersion":2,"supportedVersions":[1,2],"supportedOperations":["status","classify","reindex"],
            "coverage":{"status":"complete","reasonCodes":[]}});
        readiness(&response).unwrap();
        assert!(subject_relation(&response, Path::new("/account"), "root").is_err());
        assert!(readiness(&json!({"schemaVersion":1})).is_err());
        assert!(
            readiness(&json!({"schemaVersion":2,"error":{"code":"unsupportedSchemaVersion"}}))
                .is_err()
        );
    }

    fn run(
        id: &str,
        thread: &str,
        home: &str,
        parent: &str,
        parent_home: &str,
        resumed: Option<&str>,
    ) -> Run {
        serde_json::from_value(json!({"runId":id,"threadId":thread,"provider":"codex","relationshipKnown":true,"providerHome":home,"parentThreadId":parent,"parentHome":parent_home,"title":"Review","state":"completed","canMessage":false,"canStop":false,"canContinue":true,"resumedFromRun":resumed})).unwrap()
    }

    #[test]
    fn owning_account_can_manage_its_external_session_directly() {
        let entries = [run("origin", "child", "/account", "root", "/other", None)];
        let nodes = project(&entries, "child", &[PathBuf::from("/account")], &[]);
        assert_eq!(nodes.len(), 1);
        assert_eq!(nodes[0].id, "launcher:origin");
        assert!(nodes[0].capabilities.continue_work);
    }

    #[test]
    fn resumed_session_keeps_identity_and_original_ancestry() {
        let runs = vec![
            run(
                "new",
                "child",
                "/account/b",
                "other",
                "/account/a",
                Some("old"),
            ),
            run("old", "child", "/account/b", "root", "/account/a", None),
        ];
        let roots = vec![PathBuf::from("/account/a")];
        let child = project(&runs, "root", &roots, &[]).pop().unwrap();
        assert_eq!(child.id, "launcher:old");
        assert_eq!(child.execution_id.as_deref(), Some("new"));
        let reference = project(&runs, "other", &roots, &[]).pop().unwrap();
        assert_eq!(reference.id, child.id);
    }

    #[test]
    fn activity_is_the_newest_execution_and_absence_stays_unknown() {
        let execution = |id: &str, resumed: Option<&str>, active: Value| -> Run {
            serde_json::from_value(json!({"runId":id,"threadId":"child","provider":"codex","relationshipKnown":true,"providerHome":"/account/b","parentThreadId":"root","parentHome":"/account/a","title":"Review","state":"completed","canMessage":false,"canStop":false,"canContinue":true,"resumedFromRun":resumed,"lastActiveAt":active})).unwrap()
        };
        let roots = [PathBuf::from("/account/a")];
        let runs = vec![
            execution("new", Some("old"), json!(1_790_000_000_999_i64)),
            execution("old", None, json!(1_790_000_500_000_i64)),
        ];
        assert_eq!(
            project(&runs, "root", &roots, &[])[0].last_active_at,
            Some(1_790_000_500)
        );
        for unknown in [Value::Null, json!(0)] {
            let runs = vec![execution("only", None, unknown)];
            assert_eq!(project(&runs, "root", &roots, &[])[0].last_active_at, None);
        }
    }

    #[test]
    fn nested_accounts_use_both_home_and_thread_identity() {
        let runs = vec![
            run(
                "nested",
                "grandchild",
                "/account/c",
                "child",
                "/account/b",
                None,
            ),
            run(
                "wrong",
                "foreign",
                "/account/c",
                "child",
                "/other-account",
                None,
            ),
            run("parent", "child", "/account/b", "root", "/account/a", None),
        ];
        let nodes = project(&runs, "root", &[PathBuf::from("/account/a")], &[]);
        assert_eq!(nodes.len(), 2);
        assert_eq!(nodes[1].parent_id.as_deref(), Some("launcher:parent"));
    }
}
