pub(super) mod control;
pub(super) mod environment;
pub(super) mod observe;
pub(super) mod reconcile;
pub(super) mod stop;

use super::wait_for_desktop_daemon;
use crate::config::{CodexSettings, DesktopAction, REQUIRED_CODEX_VERSION, parse_codex_version};
use crate::observability::desktop as desktop_journal;
use crate::observability::desktop::DesktopJournal;
use crate::providers::codex::daemon::CodexAppServer;
use crate::runtime::desktop::control::MacOsDesktop;
use crate::runtime::desktop::observe::record_decision;
use crate::runtime::desktop::reconcile::{check_chatgpt, launch_chatgpt};
use crate::runtime::desktop::stop::{DesktopStopAuthority, stop_chatgpt};
use anyhow::{Context, Result, bail, ensure};
use serde_json::json;

/// Runs one desktop action. Separated from `run` so the invocation's opening
/// and closing records bracket every path, including the error ones.
pub(super) async fn run_desktop_action(
    action: DesktopAction,
    app_server: &CodexAppServer,
    journal: &DesktopJournal,
) -> Result<()> {
    match action {
        DesktopAction::Launch => {
            wait_for_desktop_daemon(app_server).await?;
            launch_chatgpt(app_server, journal).await
        }
        DesktopAction::Check => check_chatgpt(app_server, journal).await,
        DesktopAction::Stop => stop_requested(app_server, journal).await,
        DesktopAction::Mode => unreachable!("desktop mode returns before its journal opens"),
    }
}

/// One desktop reconciliation started inside the gateway rather than by the
/// launchd job, journalled end to end under `origin` so a relaunch during an
/// install or a recovery is attributable to that transaction.
pub(super) async fn reconcile_desktop(
    app_server: &CodexAppServer,
    origin: &'static str,
) -> Result<()> {
    let journal = DesktopJournal::open("launch", origin);
    journal.event("desktop/started", json!({ "host": host_name() }));
    let result = launch_chatgpt(app_server, &journal).await;
    record_desktop_finished(&journal, &result);
    result
}

pub(super) async fn stop_desktop(app_server: &CodexAppServer, origin: &'static str) -> Result<()> {
    let journal = DesktopJournal::open("stop", origin);
    journal.event("desktop/started", json!({ "host": host_name() }));
    let result = stop_requested(app_server, &journal).await;
    record_desktop_finished(&journal, &result);
    result
}

async fn stop_requested(app_server: &CodexAppServer, journal: &DesktopJournal) -> Result<()> {
    match MacOsDesktop::for_app_server(app_server, journal)? {
        Some(desktop) => stop_chatgpt(&desktop, journal, DesktopStopAuthority::Requested).await,
        None => Ok(()),
    }
}

pub(super) async fn check_desktop(app_server: &CodexAppServer, origin: &'static str) -> Result<()> {
    let journal = DesktopJournal::open("check", origin);
    journal.event("desktop/started", json!({ "host": host_name() }));
    let result = check_chatgpt(app_server, &journal).await;
    record_desktop_finished(&journal, &result);
    result
}

/// Opens an invocation with the provenance needed to tell which installed
/// gateway made the decisions that follow.
pub(super) fn record_desktop_started(journal: &DesktopJournal, settings: &CodexSettings) {
    let executable = std::env::current_exe().ok();
    let bytes = executable
        .as_ref()
        .and_then(|path| std::fs::metadata(path).ok())
        .map(|metadata| metadata.len());
    journal.event(
        "desktop/started",
        json!({
            "host": host_name(),
            "pid": std::process::id(),
            "gatewayPath": executable.map(|path| path.display().to_string()),
            "gatewayBytes": bytes,
            "requiredCodexVersion": REQUIRED_CODEX_VERSION,
            "runtimeCodexVersion": settings.codex_version,
            "runtimeCodexPath": settings.codex_path.display().to_string(),
        }),
    );
}

pub(super) fn record_desktop_finished(journal: &DesktopJournal, result: &Result<()>) {
    journal.event(
        "desktop/finished",
        json!({
            "ok": result.is_ok(),
            "durationMs": journal.elapsed_ms(),
            "detail": result
                .as_ref()
                .err()
                .map(|error| desktop_journal::sanitize_detail(&format!("{error:#}"))),
        }),
    );
}

fn host_name() -> String {
    nix::unistd::gethostname()
        .ok()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "unknown".to_string())
}

pub(super) const CHATGPT_EXECUTABLE: &str = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT";
pub(super) const CHATGPT_APPLICATION: &str = "/Applications/ChatGPT.app";

/// One running ChatGPT app instance: a process whose command is exactly the
/// bundle executable. The start time tells it apart from a later process that
/// reuses its pid, so no stop adopts a process it never observed.
///
/// Nothing else is a Desktop process. A bundled `codex app-server` may belong
/// to ChatGPT, the managed runtime, Computer Use or another agent; its
/// executable name proves none of those, so its presence authorizes nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct DesktopApp {
    pub(super) pid: i32,
    pub(super) started_micros: u64,
}

pub(super) fn app_pids<'a>(apps: impl IntoIterator<Item = &'a DesktopApp>) -> Vec<i32> {
    apps.into_iter().map(|app| app.pid).collect()
}

/// Why a reconciliation acted, or did not. These names are the stable
/// vocabulary the desktop journal records and operators grep for, so an
/// unexpected ChatGPT relaunch can be attributed without reproducing it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum DesktopReason {
    /// ChatGPT is attached to the managed app-server. Nothing is touched.
    Healthy,
    /// No ChatGPT process at all; Launch Services must open one.
    AppAbsent,
    /// A readable process provably lacks the managed launch environment: it
    /// is attached to something other than the managed socket, or can update
    /// itself.
    EnvironmentMismatch,
    /// The bundle does not carry the approved Codex version.
    IncompatibleVersion,
    /// The host could not be observed. Deliberately *not* a mismatch: an
    /// unreadable process is unknown, and unknown never justifies a restart.
    ObservationFailed,
    /// No ChatGPT bundle on this host. Reconciliation has nothing to own.
    NotInstalled,
    Disabled,
    Isolated,
}

impl DesktopReason {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            DesktopReason::Healthy => "healthy",
            DesktopReason::AppAbsent => "app-absent",
            DesktopReason::EnvironmentMismatch => "environment-mismatch",
            DesktopReason::IncompatibleVersion => "incompatible-version",
            DesktopReason::ObservationFailed => "observation-failed",
            DesktopReason::NotInstalled => "not-installed",
            DesktopReason::Disabled => "disabled",
            DesktopReason::Isolated => "isolated",
        }
    }

    /// What the reason authorizes. Only a proven bad attachment stops a
    /// running app.
    fn action(self) -> &'static str {
        match self {
            DesktopReason::Healthy => "none",
            DesktopReason::AppAbsent => "launch",
            DesktopReason::EnvironmentMismatch => "stop-mismatched",
            DesktopReason::IncompatibleVersion | DesktopReason::ObservationFailed => "abort",
            DesktopReason::NotInstalled | DesktopReason::Disabled | DesktopReason::Isolated => {
                "none"
            }
        }
    }
}

pub(super) fn verify_chatgpt_bundled_codex(
    journal: &DesktopJournal,
    required_version: &str,
) -> Result<()> {
    record_bundled_codex_version(
        journal,
        required_version,
        read_bundled_codex_version(std::path::Path::new(CHATGPT_APPLICATION)),
    )
}

pub(in crate::runtime) fn record_bundled_codex_version(
    journal: &DesktopJournal,
    required_version: &str,
    version: Result<String>,
) -> Result<()> {
    match &version {
        Ok(version) if version == required_version => {
            journal.event(
                "desktop/version",
                json!({
                    "ok": true,
                    "bundledCodexVersion": version,
                    "requiredCodexVersion": required_version,
                }),
            );
            Ok(())
        }
        Ok(version) => {
            record_decision(
                journal,
                DesktopReason::IncompatibleVersion,
                "abort",
                json!({
                    "bundledCodexVersion": version,
                    "requiredCodexVersion": required_version,
                }),
            );
            bail!(
                "ChatGPT bundles Codex {version}, but the selected shared runtime is {required_version}; validate and deploy the matching pair before shared launch"
            )
        }
        Err(error) => {
            // An unreadable bundle is an inconclusive observation, not proof
            // of a wrong version, so it aborts without touching the app.
            record_decision(
                journal,
                DesktopReason::ObservationFailed,
                "abort",
                json!({
                    "stage": "bundled-codex-version",
                    "requiredCodexVersion": required_version,
                    "detail": desktop_journal::sanitize_detail(&format!("{error:#}")),
                }),
            );
            Err(anyhow::anyhow!("{error:#}"))
        }
    }
}

/// Splits the bundled-Codex probe into "read a version" and "could not read
/// one" so the caller can record an inconclusive observation separately from
/// a confirmed version mismatch.
pub(super) fn read_bundled_codex_version(application: &std::path::Path) -> Result<String> {
    let mut selected = None;
    for relative in [
        "Contents/Resources/codex",
        "Contents/Resources/codex-cli/bin/codex",
    ] {
        let executable = application.join(relative);
        match std::fs::symlink_metadata(&executable) {
            Ok(_) => {
                ensure!(
                    selected.is_none(),
                    "ChatGPT bundled Codex layout is ambiguous: both official executable paths are present"
                );
                selected = Some(executable);
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error).with_context(|| {
                    format!(
                        "failed to inspect ChatGPT bundled Codex path {}",
                        executable.display()
                    )
                });
            }
        }
    }
    let executable = selected.context("ChatGPT bundled Codex layout is missing")?;
    let output = std::process::Command::new(executable)
        .arg("--version")
        .output()
        .context("failed to query ChatGPT's bundled Codex version")?;
    if !output.status.success() {
        bail!(
            "ChatGPT's bundled Codex version probe failed with {}",
            output.status
        );
    }
    let stdout = String::from_utf8(output.stdout)
        .context("ChatGPT's bundled Codex version output was not UTF-8")?;
    parse_codex_version(&stdout)
}
