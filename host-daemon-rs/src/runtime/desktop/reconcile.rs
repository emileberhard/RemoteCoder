use super::control::{DesktopControl, MacOsDesktop};
use super::environment::{ChatGptEnvironment, configure_chatgpt_environment};
use super::observe::{
    decide_desktop_action, list_processes, observe_desktop, record_decision, record_observation,
};
use super::stop::{DesktopStopAuthority, elapsed_ms, stop_chatgpt};
use super::{CHATGPT_APPLICATION, DesktopReason, app_pids, verify_chatgpt_bundled_codex};
use crate::config::host_profile::DesktopMode;
use crate::observability::desktop as desktop_journal;
use crate::observability::desktop::DesktopJournal;
use crate::providers::codex::daemon::CodexAppServer;
use crate::runtime::verify_recent_thread_compatibility;
use anyhow::{Result, bail};
use serde_json::json;
use std::path::Path;
use std::time::Duration;

pub(super) async fn launch_chatgpt(
    app_server: &CodexAppServer,
    journal: &DesktopJournal,
) -> Result<()> {
    let environment = ChatGptEnvironment::for_app_server(app_server)?;
    configure_chatgpt_environment(&environment).await?;
    if DesktopMode::for_this_host()? == DesktopMode::Disabled {
        record_decision(journal, DesktopReason::Disabled, "none", json!({}));
        return Ok(());
    }
    if !Path::new(CHATGPT_APPLICATION).exists() {
        record_decision(journal, DesktopReason::NotInstalled, "none", json!({}));
        return Ok(());
    }
    verify_chatgpt_bundled_codex(journal, app_server.expected_version())?;
    reconcile_desktop_state(&MacOsDesktop, journal, &environment).await
}

/// Observes the host, records the decision, and only then acts. Every branch
/// that mutates ChatGPT is reached from a recorded `DesktopReason`, so no
/// relaunch can happen without a durable record of what justified it.
pub(in crate::runtime) async fn reconcile_desktop_state(
    control: &impl DesktopControl,
    journal: &DesktopJournal,
    environment: &ChatGptEnvironment,
) -> Result<()> {
    let observations = observe_desktop(control, journal, environment, "process-list").await?;
    let reason = decide_desktop_action(&observations);
    record_observation(journal, &observations, environment);
    record_decision(journal, reason, reason.action(), json!({}));

    match reason {
        DesktopReason::Healthy | DesktopReason::NotInstalled => return Ok(()),
        DesktopReason::ObservationFailed => bail!(
            "ChatGPT's shared-daemon attachment could not be observed; the running app was left untouched"
        ),
        DesktopReason::IncompatibleVersion | DesktopReason::Disabled => {
            unreachable!("the bundled version and host mode are decided before observation")
        }
        DesktopReason::EnvironmentMismatch => {
            let authority = DesktopStopAuthority::Reconciled {
                reason,
                observations: &observations,
            };
            stop_chatgpt(control, journal, authority).await?;
            if decide_after_stop(control, journal, environment).await? == DesktopReason::Healthy {
                return Ok(());
            }
        }
        DesktopReason::AppAbsent => {}
    }

    launch_and_stabilize(control, journal, environment).await
}

/// Decides again once the mismatched instances are gone: `AppAbsent` means
/// relaunch, `Healthy` means a retained sibling already matches. Any other
/// state fails with the sibling left running, because opening the app would
/// merely activate it.
async fn decide_after_stop(
    control: &impl DesktopControl,
    journal: &DesktopJournal,
    environment: &ChatGptEnvironment,
) -> Result<DesktopReason> {
    let observations = observe_desktop(control, journal, environment, "post-stop").await?;
    let reason = decide_desktop_action(&observations);
    record_observation(journal, &observations, environment);
    let action = match reason {
        DesktopReason::AppAbsent => "launch",
        DesktopReason::Healthy => "none",
        _ => "abort",
    };
    record_decision(journal, reason, action, json!({ "stage": "post-stop" }));
    match reason {
        DesktopReason::AppAbsent | DesktopReason::Healthy => Ok(reason),
        _ => bail!(
            "ChatGPT {:?} is {} after its mismatched instances stopped and was left running",
            app_pids(observations.iter().map(|(app, _)| app)),
            reason.as_str()
        ),
    }
}

/// Opens ChatGPT through Launch Services and waits for it to settle on the
/// managed app-server, recording the request, the resulting pids and the
/// stabilization outcome.
async fn launch_and_stabilize(
    control: &impl DesktopControl,
    journal: &DesktopJournal,
    environment: &ChatGptEnvironment,
) -> Result<()> {
    journal.event(
        "desktop/launchRequest",
        json!({ "application": CHATGPT_APPLICATION }),
    );
    let started = tokio::time::Instant::now();
    if let Err(error) = control.open_application(environment).await {
        journal.event(
            "desktop/launchResult",
            json!({
                "ok": false,
                "waitedMs": elapsed_ms(started),
                "detail": desktop_journal::sanitize_detail(&format!("{error:#}")),
            }),
        );
        return Err(error);
    }

    let deadline = started + Duration::from_secs(10);
    loop {
        let apps = list_processes(control, journal, "launch-wait").await?;
        if !apps.is_empty() {
            journal.event(
                "desktop/launchResult",
                json!({
                    "ok": true,
                    "waitedMs": elapsed_ms(started),
                    "appPids": app_pids(&apps),
                }),
            );
            break;
        }
        if tokio::time::Instant::now() >= deadline {
            journal.event(
                "desktop/launchResult",
                json!({
                    "ok": false,
                    "waitedMs": elapsed_ms(started),
                    "detail": "ChatGPT did not appear through Launch Services",
                }),
            );
            bail!("ChatGPT did not start through Launch Services");
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    let stabilizing = tokio::time::Instant::now();
    let deadline = stabilizing + Duration::from_secs(60);
    let mut consecutive_successes = 0;
    loop {
        let observations = observe_desktop(control, journal, environment, "stabilize").await?;
        let reason = decide_desktop_action(&observations);
        let pids = app_pids(observations.iter().map(|(app, _)| app));
        if reason == DesktopReason::Healthy {
            consecutive_successes += 1;
            if consecutive_successes >= 3 {
                journal.event(
                    "desktop/stabilized",
                    json!({
                        "ok": true,
                        "consecutiveSuccesses": consecutive_successes,
                        "waitedMs": elapsed_ms(stabilizing),
                        "appPids": pids,
                    }),
                );
                return Ok(());
            }
        } else {
            consecutive_successes = 0;
        }
        if tokio::time::Instant::now() >= deadline {
            record_observation(journal, &observations, environment);
            journal.event(
                "desktop/stabilized",
                json!({
                    "ok": false,
                    "reason": reason.as_str(),
                    "consecutiveSuccesses": consecutive_successes,
                    "waitedMs": elapsed_ms(stabilizing),
                    "appPids": pids,
                }),
            );
            bail!(
                "ChatGPT did not stabilize on the shared Codex app-server; its last observation was {}",
                reason.as_str()
            );
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

pub(super) async fn check_chatgpt(
    app_server: &CodexAppServer,
    journal: &DesktopJournal,
) -> Result<()> {
    if DesktopMode::for_this_host()? == DesktopMode::Disabled {
        record_decision(journal, DesktopReason::Disabled, "report-only", json!({}));
        bail!("ChatGPT Desktop is disabled on this host by config/host-profiles.json");
    }
    app_server.verify_ready().await?;
    verify_chatgpt_bundled_codex(journal, app_server.expected_version())?;
    let environment = ChatGptEnvironment::for_app_server(app_server)?;
    match report_desktop_state(&MacOsDesktop, journal, &environment).await? {
        DesktopReason::Healthy => verify_recent_thread_compatibility(app_server).await,
        DesktopReason::AppAbsent => bail!("ChatGPT is not running"),
        DesktopReason::EnvironmentMismatch => {
            bail!("ChatGPT lacks the managed launch environment")
        }
        DesktopReason::ObservationFailed => {
            bail!("ChatGPT's shared-daemon attachment could not be observed")
        }
        DesktopReason::IncompatibleVersion
        | DesktopReason::NotInstalled
        | DesktopReason::Disabled => {
            unreachable!("decided before observation")
        }
    }
}

/// The observing half of `check`. It never quits, kills or opens anything,
/// whatever the reason would authorize during reconciliation.
pub(in crate::runtime) async fn report_desktop_state(
    control: &impl DesktopControl,
    journal: &DesktopJournal,
    environment: &ChatGptEnvironment,
) -> Result<DesktopReason> {
    let observations = observe_desktop(control, journal, environment, "process-list").await?;
    let reason = decide_desktop_action(&observations);
    record_observation(journal, &observations, environment);
    record_decision(journal, reason, "report-only", json!({}));
    Ok(reason)
}
