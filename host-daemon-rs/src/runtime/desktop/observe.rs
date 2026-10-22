use super::control::DesktopControl;
use super::environment::{ChatGptEnvironment, EnvironmentObservation};
use super::{DesktopApp, DesktopReason, app_pids};
use crate::observability::desktop as desktop_journal;
use crate::observability::desktop::DesktopJournal;
use anyhow::Result;
use serde_json::{Value, json};

/// Observes every ChatGPT app instance against the expected attachment.
pub(super) async fn observe_desktop(
    control: &impl DesktopControl,
    journal: &DesktopJournal,
    environment: &ChatGptEnvironment,
    stage: &'static str,
) -> Result<Vec<(DesktopApp, EnvironmentObservation)>> {
    Ok(list_processes(control, journal, stage)
        .await?
        .into_iter()
        .map(|app| (app, control.observe_environment(app, environment)))
        .collect())
}

/// Chooses what a reconciliation is entitled to do from one observation
/// snapshot. Only the app instances themselves are evidence. Pure, so the
/// policy is testable without a host.
pub(in crate::runtime) fn decide_desktop_action(
    observations: &[(DesktopApp, EnvironmentObservation)],
) -> DesktopReason {
    let live: Vec<&EnvironmentObservation> = observations
        .iter()
        .map(|(_, observation)| observation)
        .filter(|observation| !matches!(observation, EnvironmentObservation::Vanished))
        .collect();
    if live.is_empty() {
        return DesktopReason::AppAbsent;
    }
    // A proven mismatch outranks an unreadable sibling: one process provably
    // on the wrong daemon is real evidence, and this preserves every restart
    // the launcher would previously have made on proven evidence.
    if live
        .iter()
        .any(|observation| matches!(observation, EnvironmentObservation::Differs(_)))
    {
        return DesktopReason::EnvironmentMismatch;
    }
    if live
        .iter()
        .any(|observation| matches!(observation, EnvironmentObservation::Unreadable { .. }))
    {
        return DesktopReason::ObservationFailed;
    }
    DesktopReason::Healthy
}

/// Records one decision. `action` is what this invocation actually did, not
/// what the reason would authorize: `check` reports and never mutates, so it
/// must not claim it stopped anything.
pub(super) fn record_decision(
    journal: &DesktopJournal,
    reason: DesktopReason,
    action: &'static str,
    extra: Value,
) {
    let mut fields = match extra {
        Value::Object(map) => map,
        _ => serde_json::Map::new(),
    };
    fields.insert("reason".to_string(), json!(reason.as_str()));
    fields.insert("action".to_string(), json!(action));
    journal.event("desktop/decision", Value::Object(fields));
}

/// Lists processes, recording an explicit inconclusive decision when the host
/// cannot be listed at all — otherwise the invocation would abort with no
/// record of why.
pub(super) async fn list_processes(
    control: &impl DesktopControl,
    journal: &DesktopJournal,
    stage: &'static str,
) -> Result<Vec<DesktopApp>> {
    control.processes().await.inspect_err(|error| {
        record_decision(
            journal,
            DesktopReason::ObservationFailed,
            "abort",
            json!({
                "stage": stage,
                "detail": desktop_journal::sanitize_detail(&format!("{error:#}")),
            }),
        );
    })
}

/// Records exactly what was seen, before any mutation, so a later relaunch can
/// be attributed to observed state rather than inferred from its timing.
pub(in crate::runtime) fn record_observation(
    journal: &DesktopJournal,
    observations: &[(DesktopApp, EnvironmentObservation)],
    environment: &ChatGptEnvironment,
) {
    let observed: Vec<Value> = observations
        .iter()
        .map(|(app, observation)| {
            let mut entry = json!({
                "pid": app.pid,
                "startedMicros": app.started_micros,
                "observation": observation.as_str(),
            });
            match observation {
                EnvironmentObservation::Differs(fields) => {
                    entry["observed"] = serde_json::to_value(fields).unwrap_or(Value::Null);
                }
                EnvironmentObservation::Unreadable { detail } => {
                    entry["detail"] = json!(detail);
                }
                EnvironmentObservation::Matches | EnvironmentObservation::Vanished => {}
            }
            entry
        })
        .collect();
    journal.event(
        "desktop/observed",
        json!({
            "appPids": app_pids(observations.iter().map(|(app, _)| app)),
            "expected": {
                "appServerWsUrl": environment.app_server_ws_url,
            },
            "processes": observed,
        }),
    );
}
