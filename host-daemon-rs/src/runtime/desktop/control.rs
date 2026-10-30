use super::environment::{ChatGptEnvironment, EnvironmentObservation, observe_chatgpt_process};
use super::observe::record_decision;
use super::stop::{Delivery, StopMethod};
use super::{CHATGPT_APPLICATION, CHATGPT_EXECUTABLE, DesktopApp, DesktopReason};
use crate::config::host_profile::DesktopMode;
use crate::observability::desktop as desktop_journal;
use crate::observability::desktop::DesktopJournal;
use crate::platform::macos::application::request_quit;
use crate::platform::process as mac_app;
use crate::providers::codex::daemon::CodexAppServer;
use crate::runtime::launchd::launchctl;
use anyhow::{Context, Result, bail};
use serde_json::json;
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command as TokioCommand;

pub(super) const DESKTOP_QUIT_TIMEOUT: Duration = Duration::from_secs(10);
pub(super) const DESKTOP_KILL_TIMEOUT: Duration = Duration::from_secs(2);

/// The host operations desktop reconciliation performs. Production uses
/// `MacOsDesktop`; tests substitute a fake, so the signal, escalation, launch
/// and stabilization paths are exercised without signalling a real GUI
/// process or asking Launch Services to open anything.
#[allow(async_fn_in_trait)]
pub(in crate::runtime) trait DesktopControl {
    async fn processes(&self) -> Result<Vec<DesktopApp>>;
    fn observe_environment(
        &self,
        app: DesktopApp,
        environment: &ChatGptEnvironment,
    ) -> EnvironmentObservation;
    /// Sends `method` to `app` only if its pid still holds that exact
    /// instance. An identity that cannot be read is an error, never a
    /// licence to act.
    fn deliver(&self, app: DesktopApp, method: StopMethod) -> Result<Delivery>;
    async fn open_application(&self, environment: &ChatGptEnvironment) -> Result<()>;
}

pub(in crate::runtime) struct MacOsDesktop {
    mode: DesktopMode,
}

impl MacOsDesktop {
    pub(in crate::runtime) fn for_app_server(
        app_server: &CodexAppServer,
        journal: &DesktopJournal,
    ) -> Result<Option<Self>> {
        match DesktopMode::for_codex_home(app_server.provider_home()?)? {
            Some(mode) => Ok(Some(Self { mode })),
            None => {
                record_decision(journal, DesktopReason::Isolated, "none", json!({}));
                Ok(None)
            }
        }
    }

    pub(super) fn mode(&self) -> DesktopMode {
        self.mode
    }

    pub(super) async fn configure_environment(
        &self,
        environment: &ChatGptEnvironment,
    ) -> Result<()> {
        for (key, value) in environment.launch_variables() {
            let status = launchctl().args(["setenv", key, value]).status().await?;
            if !status.success() {
                bail!("failed to set ChatGPT {key} environment");
            }
        }
        Ok(())
    }
}

impl DesktopControl for MacOsDesktop {
    async fn processes(&self) -> Result<Vec<DesktopApp>> {
        listed_apps(&chatgpt_app_pids(&process_lines()?), &mac_app::identify)
    }

    fn observe_environment(
        &self,
        app: DesktopApp,
        environment: &ChatGptEnvironment,
    ) -> EnvironmentObservation {
        let observation = observe_chatgpt_process(app.pid, environment);
        // The probe read whatever process holds the pid now; it describes the
        // listed instance only if that instance is still the one there.
        match current_app(app.pid, &mac_app::identify) {
            Ok(Some(current)) if current == app => observation,
            Ok(_) => EnvironmentObservation::Vanished,
            Err(error) => EnvironmentObservation::Unreadable {
                detail: desktop_journal::sanitize_detail(&format!("{error:#}")),
            },
        }
    }

    fn deliver(&self, app: DesktopApp, method: StopMethod) -> Result<Delivery> {
        // Checked immediately before the request. macOS cannot address a
        // process by identity, so only the instant between this check and the
        // request remains open to a replacement.
        if current_app(app.pid, &mac_app::identify)? != Some(app) {
            return Ok(Delivery::TargetGone);
        }
        match method {
            StopMethod::Quit => request_quit(app.pid)?,
            StopMethod::Kill => match nix::sys::signal::kill(
                nix::unistd::Pid::from_raw(app.pid),
                nix::sys::signal::Signal::SIGKILL,
            ) {
                Ok(()) => {}
                Err(nix::errno::Errno::ESRCH) => return Ok(Delivery::TargetGone),
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("failed to send SIGKILL to pid {}", app.pid));
                }
            },
        }
        Ok(Delivery::Sent)
    }

    async fn open_application(&self, environment: &ChatGptEnvironment) -> Result<()> {
        let status = TokioCommand::new("/usr/bin/open")
            .arg("-g")
            .arg(CHATGPT_APPLICATION)
            .envs(environment.launch_variables())
            .env_remove("CODEX_APP_SERVER_USE_LOCAL_DAEMON")
            .env_remove("CODEX_APP_SERVER_FORCE_CLI")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .context("failed to ask Launch Services to open ChatGPT")?;
        if !status.success() {
            bail!("Launch Services failed to open ChatGPT with {status}");
        }
        Ok(())
    }
}

pub(in crate::runtime) type IdentifyProcess =
    dyn Fn(i32) -> Result<Option<mac_app::ProcessIdentity>>;

/// The app instance running as `pid` now: a live process whose executable is
/// the app's. `None` means no such instance; an unreadable identity is an
/// error, so it can never pass for an absent or exited app.
pub(in crate::runtime) fn current_app(
    pid: i32,
    identify: &IdentifyProcess,
) -> Result<Option<DesktopApp>> {
    Ok(identify(pid)?
        .filter(|identity| identity.executable == Path::new(CHATGPT_EXECUTABLE))
        .map(|identity| DesktopApp {
            pid,
            started_micros: identity.started_micros,
        }))
}

/// Resolves listed pids to app instances. The command came from an earlier
/// `ps` snapshot, so each pid's executable is revalidated together with its
/// start time; a pid that is no longer the app is skipped.
pub(in crate::runtime) fn listed_apps(
    pids: &[i32],
    identify: &IdentifyProcess,
) -> Result<Vec<DesktopApp>> {
    let mut apps = Vec::new();
    for &pid in pids {
        if let Some(app) = current_app(pid, identify)? {
            apps.push(app);
        }
    }
    Ok(apps)
}

/// The pids of ChatGPT app instances in a `ps` pid/command listing. Every
/// other process, whatever its executable or owner, is ignored.
pub(in crate::runtime) fn chatgpt_app_pids(processes: &[(i32, String)]) -> Vec<i32> {
    processes
        .iter()
        .filter(|(_, command)| command == CHATGPT_EXECUTABLE)
        .map(|(pid, _)| *pid)
        .collect()
}

pub(in crate::runtime) fn process_lines() -> Result<Vec<(i32, String)>> {
    let output = std::process::Command::new("ps")
        .args(["-Ao", "pid=,command="])
        .output()?;
    if !output.status.success() {
        bail!("ps failed with {}", output.status);
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout
        .lines()
        .map(|line| {
            let line = line.trim();
            let (pid, command) = line
                .split_once(char::is_whitespace)
                .context("ps returned a malformed row")?;
            Ok((pid.parse()?, command.trim().to_string()))
        })
        .collect()
}
