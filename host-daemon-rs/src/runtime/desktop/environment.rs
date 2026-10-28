use super::CHATGPT_EXECUTABLE;
use crate::observability::desktop as desktop_journal;
use crate::providers::codex::daemon::CodexAppServer;
use crate::runtime::launchd::launchctl;
use anyhow::{Context, Result, bail};
use serde::Serialize;
use std::path::Path;

#[derive(Debug)]
pub(in crate::runtime) struct ChatGptEnvironment {
    pub(in crate::runtime) app_server_ws_url: String,
}

impl ChatGptEnvironment {
    pub(super) fn for_app_server(app_server: &CodexAppServer) -> Result<Self> {
        Ok(Self {
            app_server_ws_url: app_server_websocket_url(app_server.socket_path())?,
        })
    }

    pub(super) fn launch_variables(&self) -> [(&'static str, &str); 3] {
        [
            ("CODEX_APP_SERVER_WS_URL", &self.app_server_ws_url),
            // Managed lifecycle operations cannot wait for Desktop's quit dialog.
            ("CODEX_ELECTRON_DISABLE_QUIT_CONFIRMATION", "1"),
            ("CODEX_SPARKLE_ENABLED", "false"),
        ]
    }

    /// Reduces a `ps eww` command line to the allowlisted fields
    /// reconciliation is allowed to compare and record. The raw line carries
    /// the process's whole environment; only what this returns may reach a
    /// journal record.
    pub(in crate::runtime) fn observe(&self, command: &str) -> ObservedEnvironment {
        let expected_ws_url = format!("CODEX_APP_SERVER_WS_URL={}", self.app_server_ws_url);
        let mut observed = ObservedEnvironment::default();
        for token in command.split_whitespace() {
            if let Some(value) = token.strip_prefix("CODEX_APP_SERVER_WS_URL=") {
                observed.app_server_ws_url = Some(desktop_journal::sanitize_detail(value));
                observed.app_server_ws_url_matches |= token == expected_ws_url;
            } else if token == "CODEX_SPARKLE_ENABLED=false" {
                observed.updater_disabled = true;
            } else if token.starts_with("CODEX_APP_SERVER_FORCE_CLI=") {
                observed.force_cli_present = true;
            } else if token.starts_with("CODEX_APP_SERVER_USE_LOCAL_DAEMON=") {
                observed.use_local_daemon_present = true;
            }
        }
        observed
    }
}

/// The allowlisted, non-secret fields reconciliation compares. `ps eww`
/// returns the whole process environment, so this is deliberately the only
/// shape that crosses into a journal record: the public managed attachment
/// address, whether the in-app updater is off, plus presence flags for the
/// obsolete private-daemon controls.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(in crate::runtime) struct ObservedEnvironment {
    app_server_ws_url: Option<String>,
    app_server_ws_url_matches: bool,
    updater_disabled: bool,
    pub(in crate::runtime) force_cli_present: bool,
    pub(in crate::runtime) use_local_daemon_present: bool,
}

impl ObservedEnvironment {
    /// `CODEX_APP_SERVER_USE_LOCAL_DAEMON` is recorded but not decisive. An
    /// app that can update itself is a mismatch even when attached, because
    /// an update replaces the bundled Codex the shared runtime is paired with.
    pub(in crate::runtime) fn matches(&self) -> bool {
        self.app_server_ws_url_matches && self.updater_disabled && !self.force_cli_present
    }
}

/// What one environment probe established about one ChatGPT process.
///
/// `Unreadable` exists because the previous probe collapsed "this process is
/// attached to the wrong daemon" and "this process could not be read" into a
/// single `false`, and a `false` stops and relaunches the app. An
/// unobservable process is unknown, and unknown is never grounds to restart.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::runtime) enum EnvironmentObservation {
    /// Provably attached to the managed app-server.
    Matches,
    /// Provably attached to something else.
    Differs(ObservedEnvironment),
    /// The process exited between listing and probing. Benign; the next list
    /// simply will not contain it.
    Vanished,
    /// The probe failed or returned nothing usable for a process that is
    /// still alive.
    Unreadable { detail: String },
}

impl EnvironmentObservation {
    pub(super) fn as_str(&self) -> &'static str {
        match self {
            EnvironmentObservation::Matches => "matches",
            EnvironmentObservation::Differs(_) => "differs",
            EnvironmentObservation::Vanished => "vanished",
            EnvironmentObservation::Unreadable { .. } => "unreadable",
        }
    }
}

pub(in crate::runtime) fn app_server_websocket_url(socket_path: &Path) -> Result<String> {
    let socket_path = socket_path
        .to_str()
        .context("Codex app-server socket path is not valid UTF-8")?;
    if !socket_path.starts_with('/') || socket_path.contains(':') {
        bail!("Codex app-server socket path cannot form a ws+unix URL");
    }
    // ChatGPT routes hostless URLs through its remote-host SOCKS proxy. The
    // ws+unix transport reads the socket from the pathname, so localhost keeps
    // the connection local without changing the absolute socket path.
    Ok(format!("ws+unix://localhost{socket_path}:/rpc"))
}

async fn set_launchctl_environment(key: &str, value: &str) -> Result<()> {
    let status = launchctl().args(["setenv", key, value]).status().await?;
    if !status.success() {
        bail!("failed to set ChatGPT {key} environment");
    }
    Ok(())
}

pub(super) async fn configure_chatgpt_environment(environment: &ChatGptEnvironment) -> Result<()> {
    for (key, value) in environment.launch_variables() {
        set_launchctl_environment(key, value).await?;
    }
    Ok(())
}

/// Reads one process's environment and classifies it. `ps` exits non-zero for
/// a pid that has gone away and can also fail transiently under load, so a
/// failed read is separated from a confirmed mismatch here rather than being
/// flattened into "does not match".
pub(super) fn observe_chatgpt_process(
    pid: i32,
    environment: &ChatGptEnvironment,
) -> EnvironmentObservation {
    let probe = std::process::Command::new("ps")
        .args(["eww", "-p", &pid.to_string(), "-o", "command="])
        .output();
    let classified = match &probe {
        Ok(output) if output.status.success() => classify_probe_output(&output.stdout, environment),
        Ok(output) => Err(format!("ps exited with {}", output.status)),
        Err(error) => Err(format!("ps could not run: {error}")),
    };
    match classified {
        Ok(observation) => observation,
        Err(detail) => {
            // Distinguish the benign race — the process exited between the
            // listing and the probe — from a live process we failed to read.
            if process_exists(pid) {
                EnvironmentObservation::Unreadable {
                    detail: desktop_journal::sanitize_detail(&detail),
                }
            } else {
                EnvironmentObservation::Vanished
            }
        }
    }
}

/// Classifies one probe's raw output, split from the `ps` call so the parsing
/// boundary is testable.
///
/// `Err` means the output could not be used, which the caller resolves to
/// `Vanished` or `Unreadable`. Blank, truncated or foreign output must land
/// here: a command line we cannot recognize is not evidence that ChatGPT is
/// attached to the wrong daemon, and only such evidence may stop the app. A
/// recognizable line carrying *none* of the expected variables is a real
/// mismatch and stays one.
pub(in crate::runtime) fn classify_probe_output(
    stdout: &[u8],
    environment: &ChatGptEnvironment,
) -> Result<EnvironmentObservation, String> {
    let command = String::from_utf8_lossy(stdout);
    let command = command.trim_start();
    if command.is_empty() {
        return Err("ps returned no output".to_string());
    }
    // `-o command=` prints the command line of the pid asked about, and every
    // pid reaching here was classified as the app because its command is
    // exactly this path.
    if !command.starts_with(CHATGPT_EXECUTABLE) {
        return Err("ps returned no recognizable ChatGPT command line".to_string());
    }
    let observed = environment.observe(command);
    Ok(if observed.matches() {
        EnvironmentObservation::Matches
    } else {
        EnvironmentObservation::Differs(observed)
    })
}

/// Whether `pid` still exists, via signal 0. `EPERM` means it exists but is
/// not ours to signal, which still counts as existing.
pub(super) fn process_exists(pid: i32) -> bool {
    !matches!(
        nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None),
        Err(nix::errno::Errno::ESRCH)
    )
}
