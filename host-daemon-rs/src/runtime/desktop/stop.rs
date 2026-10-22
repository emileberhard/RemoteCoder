use super::control::{DESKTOP_KILL_TIMEOUT, DESKTOP_QUIT_TIMEOUT, DesktopControl};
use super::environment::EnvironmentObservation;
use super::observe::list_processes;
use super::{DesktopApp, DesktopReason, app_pids};
use crate::observability::desktop as desktop_journal;
use crate::observability::desktop::DesktopJournal;
use anyhow::{Result, bail};
use serde_json::json;
use std::time::Duration;

/// What entitles a stop to end the app instances it targets. It is recorded
/// with every target, so a termination can be attributed from its own records.
#[derive(Clone, Copy)]
pub(in crate::runtime) enum DesktopStopAuthority<'a> {
    /// An installer, runtime transition, recovery cleanup or operator asked
    /// for ChatGPT to be stopped. Every instance listed at stop time is a target.
    Requested,
    /// Reconciliation observed these instances and decided `reason`. Only an
    /// instance whose own readable environment differs is a target; a
    /// matching or unreadable sibling is retained, and an instance it never
    /// observed is neither.
    Reconciled {
        reason: DesktopReason,
        observations: &'a [(DesktopApp, EnvironmentObservation)],
    },
}

/// One instance a stop will end, with the evidence that selected it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct StopTarget {
    app: DesktopApp,
    evidence: &'static str,
}

impl DesktopStopAuthority<'_> {
    fn name(self) -> &'static str {
        match self {
            DesktopStopAuthority::Requested => "requested",
            DesktopStopAuthority::Reconciled { reason, .. } => reason.as_str(),
        }
    }

    fn targets(self, listed: &[DesktopApp]) -> Vec<StopTarget> {
        match self {
            DesktopStopAuthority::Requested => listed
                .iter()
                .map(|&app| StopTarget {
                    app,
                    evidence: "requested",
                })
                .collect(),
            DesktopStopAuthority::Reconciled { observations, .. } => observations
                .iter()
                .filter(|(app, observation)| {
                    matches!(observation, EnvironmentObservation::Differs(_))
                        && listed.contains(app)
                })
                .map(|(app, observation)| StopTarget {
                    app: *app,
                    evidence: observation.as_str(),
                })
                .collect(),
        }
    }

    /// Whether `app` may still be running once the stop is complete.
    fn retains(self, app: &DesktopApp) -> bool {
        match self {
            DesktopStopAuthority::Requested => false,
            DesktopStopAuthority::Reconciled { observations, .. } => {
                observations.iter().any(|(observed, _)| observed == app)
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::runtime) enum StopMethod {
    /// The standard quit Apple Event, so the app runs its own shutdown and
    /// ends the helpers it owns.
    Quit,
    /// Escalation for an instance that is still the same process after the
    /// quit window. SIGTERM is not an intermediate step: a Cocoa app handles
    /// it no more gracefully than SIGKILL.
    Kill,
}

impl StopMethod {
    fn as_str(self) -> &'static str {
        match self {
            StopMethod::Quit => "quit",
            StopMethod::Kill => "SIGKILL",
        }
    }
}

/// What happened to one stop request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::runtime) enum Delivery {
    Sent,
    /// The pid no longer holds the selected instance, so nothing was sent.
    TargetGone,
}

/// Stops the ChatGPT app instances `authority` selects, and nothing else.
/// Each is asked to quit normally; only an instance that is still the same
/// process after the quit window is killed. An instance that appears
/// meanwhile was never selected, so it is reported and left running; one the
/// authority retains may keep running. Intent is recorded before each
/// request, so an invocation that dies mid-stop still leaves on disk what it
/// was about to end and why.
pub(in crate::runtime) async fn stop_chatgpt(
    control: &impl DesktopControl,
    journal: &DesktopJournal,
    authority: DesktopStopAuthority<'_>,
) -> Result<()> {
    let listed = list_processes(control, journal, "stop-list").await?;
    let targets = authority.targets(&listed);
    if targets.is_empty() {
        // Listed instances here were never selected by this authority; the
        // caller's next observation decides about them.
        journal.event(
            "desktop/stop",
            json!({
                "authority": authority.name(),
                "targets": [],
                "skipped": "no-targets",
                "appPids": app_pids(&listed),
            }),
        );
        return Ok(());
    }
    request_stop(control, journal, authority, &targets, StopMethod::Quit);
    let remaining = wait_for_targets_exit(
        control,
        journal,
        &targets,
        StopMethod::Quit,
        DESKTOP_QUIT_TIMEOUT,
    )
    .await?;
    if !remaining.is_empty() {
        // `remaining` comes from a listing taken just now, so each target's
        // pid and start time were revalidated immediately before escalation.
        request_stop(control, journal, authority, &remaining, StopMethod::Kill);
        let survivors = wait_for_targets_exit(
            control,
            journal,
            &remaining,
            StopMethod::Kill,
            DESKTOP_KILL_TIMEOUT,
        )
        .await?;
        if !survivors.is_empty() {
            let pids = app_pids(survivors.iter().map(|target| &target.app));
            journal.event(
                "desktop/stopFailed",
                json!({ "reason": "targets-survived", "appPids": pids }),
            );
            bail!("ChatGPT {pids:?} did not stop");
        }
    }
    let unselected: Vec<DesktopApp> = list_processes(control, journal, "stop-verify")
        .await?
        .into_iter()
        .filter(|app| !authority.retains(app))
        .collect();
    if !unselected.is_empty() {
        journal.event(
            "desktop/stopFailed",
            json!({ "reason": "unselected-instance", "appPids": app_pids(&unselected) }),
        );
        bail!(
            "ChatGPT {:?} started while stopping and was left running",
            app_pids(&unselected)
        );
    }
    Ok(())
}

/// Sends `method` to every target, recording the intent with each target's
/// identity and evidence first, then each delivery outcome. Delivery failures
/// are recorded, not raised: the caller's authority is the exit check, not one
/// request's error. An unreadable target is never signalled, and the exit
/// check that follows fails on the same unreadable listing.
pub(super) fn request_stop(
    control: &impl DesktopControl,
    journal: &DesktopJournal,
    authority: DesktopStopAuthority<'_>,
    targets: &[StopTarget],
    method: StopMethod,
) {
    journal.event(
        "desktop/stop",
        json!({
            "method": method.as_str(),
            "authority": authority.name(),
            "targets": targets
                .iter()
                .map(|target| json!({
                    "pid": target.app.pid,
                    "startedMicros": target.app.started_micros,
                    "evidence": target.evidence,
                }))
                .collect::<Vec<_>>(),
        }),
    );
    for target in targets {
        let (outcome, detail) = match control.deliver(target.app, method) {
            Ok(Delivery::Sent) => ("sent", None),
            Ok(Delivery::TargetGone) => ("target-gone", None),
            Err(error) => (
                "failed",
                Some(desktop_journal::sanitize_detail(&format!("{error:#}"))),
            ),
        };
        journal.event(
            "desktop/signal",
            json!({
                "pid": target.app.pid,
                "startedMicros": target.app.started_micros,
                "method": method.as_str(),
                "outcome": outcome,
                "detail": detail,
            }),
        );
    }
}

/// Waits up to `timeout` for every target to exit and returns the targets
/// that are still the same process. A timeout is not an error here — the
/// caller escalates — but it is recorded, so an escalated stop is visible.
async fn wait_for_targets_exit(
    control: &impl DesktopControl,
    journal: &DesktopJournal,
    targets: &[StopTarget],
    method: StopMethod,
    timeout: Duration,
) -> Result<Vec<StopTarget>> {
    let started = tokio::time::Instant::now();
    let deadline = started + timeout;
    loop {
        let listed = list_processes(control, journal, "stop-wait").await?;
        let remaining: Vec<StopTarget> = targets
            .iter()
            .filter(|target| listed.contains(&target.app))
            .copied()
            .collect();
        if remaining.is_empty() || tokio::time::Instant::now() >= deadline {
            journal.event(
                "desktop/stopWait",
                json!({
                    "method": method.as_str(),
                    "exited": remaining.is_empty(),
                    "waitedMs": elapsed_ms(started),
                    "remainingAppPids": app_pids(remaining.iter().map(|target| &target.app)),
                }),
            );
            return Ok(remaining);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

pub(super) fn elapsed_ms(since: tokio::time::Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}
