use crate::config::HostPaths;
use anyhow::{Context, Result, bail, ensure};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command as TokioCommand;
use tracing::warn;

pub(super) const GATEWAY_LABEL: &str = "com.remote-coder.codex-gateway";
pub(super) const DESKTOP_LABEL: &str = "com.remote-coder.chatgpt-shared-codex";

const UNLOAD_TIMEOUT: Duration = Duration::from_secs(65);
const IDLE_TIMEOUT: Duration = Duration::from_secs(30);
const BOOTSTRAP_ATTEMPTS: usize = 20;
const POLL_INTERVAL: Duration = Duration::from_millis(100);
const CHATGPT_LAUNCHCTL_KEYS: [&str; 2] = [
    "CODEX_APP_SERVER_WS_URL",
    "CODEX_ELECTRON_DISABLE_QUIT_CONFIRMATION",
];

#[derive(Debug, Default, Eq, PartialEq)]
pub(super) struct LaunchdJob {
    pub(super) state: Option<String>,
    pub(super) pid: Option<u32>,
    pub(super) spawn_type: Option<String>,
}

impl LaunchdJob {
    pub(super) fn parse(listing: &str) -> Self {
        let mut job = Self::default();
        for line in listing.lines().map(str::trim_start) {
            if job.state.is_none()
                && let Some(state) = line.strip_prefix("state = ")
            {
                job.state = Some(state.trim().to_string());
            }
            if job.pid.is_none()
                && let Some(pid) = line.strip_prefix("pid = ")
            {
                job.pid = pid
                    .split_whitespace()
                    .next()
                    .and_then(|pid| pid.parse().ok());
            }
            if job.spawn_type.is_none()
                && let Some(kind) = line.strip_prefix("spawn type = ")
            {
                job.spawn_type = kind.split_whitespace().next().map(str::to_string);
            }
        }
        job
    }

    fn is_busy(&self) -> bool {
        matches!(self.state.as_deref(), Some("running" | "xpcproxy"))
    }
}

pub(super) struct LaunchdService {
    label: &'static str,
    plist: PathBuf,
}

impl LaunchdService {
    pub(super) fn new(label: &'static str, paths: &HostPaths) -> Self {
        Self {
            label,
            plist: paths
                .home()
                .join("Library/LaunchAgents")
                .join(format!("{label}.plist")),
        }
    }

    fn target(&self) -> String {
        format!("{}/{}", gui_domain(), self.label)
    }

    pub(super) fn plist(&self) -> &Path {
        &self.plist
    }

    pub(super) async fn job(&self) -> Result<Option<LaunchdJob>> {
        let output = launchctl()
            .args(["print", &self.target()])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .await
            .context("failed to run launchctl print")?;
        Ok(output
            .status
            .success()
            .then(|| LaunchdJob::parse(&String::from_utf8_lossy(&output.stdout))))
    }

    pub(super) async fn is_loaded(&self) -> Result<bool> {
        service_is_loaded(self.label).await
    }

    pub(super) async fn bootout(&self) -> Result<()> {
        if !self.is_loaded().await? {
            return Ok(());
        }
        let by_label = launchctl_succeeds(&["bootout", &self.target()]).await?;
        if !by_label {
            launchctl_succeeds(&["bootout", &gui_domain(), &self.plist.to_string_lossy()]).await?;
        }
        let deadline = tokio::time::Instant::now() + UNLOAD_TIMEOUT;
        while self.is_loaded().await? {
            ensure!(
                tokio::time::Instant::now() < deadline,
                "timed out waiting for {} to unload",
                self.label
            );
            tokio::time::sleep(POLL_INTERVAL).await;
        }
        Ok(())
    }

    pub(super) async fn bootstrap(&self) -> Result<()> {
        let plist = self.plist.to_string_lossy();
        let mut last_error = String::new();
        for _ in 0..BOOTSTRAP_ATTEMPTS {
            let output = launchctl()
                .args(["bootstrap", &gui_domain(), &plist])
                .stdin(Stdio::null())
                .output()
                .await
                .context("failed to run launchctl bootstrap")?;
            if output.status.success() || self.is_loaded().await? {
                return Ok(());
            }
            last_error = String::from_utf8_lossy(&output.stderr).trim().to_string();
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        bail!("failed to bootstrap {}: {last_error}", self.label)
    }

    pub(super) async fn kickstart(&self) -> Result<()> {
        ensure!(
            launchctl_succeeds(&["kickstart", "-k", &self.target()]).await?,
            "failed to kickstart {}",
            self.label
        );
        Ok(())
    }

    pub(super) async fn wait_until_idle(&self) -> Result<()> {
        let deadline = tokio::time::Instant::now() + IDLE_TIMEOUT;
        loop {
            let busy = self.job().await?.is_some_and(|job| job.is_busy());
            if !busy {
                return Ok(());
            }
            ensure!(
                tokio::time::Instant::now() < deadline,
                "timed out waiting for {} to become idle",
                self.label
            );
            tokio::time::sleep(POLL_INTERVAL).await;
        }
    }
}

async fn launchctl_succeeds(arguments: &[&str]) -> Result<bool> {
    Ok(launchctl()
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .context("failed to run launchctl")?
        .success())
}

async fn service_is_loaded(label: &str) -> Result<bool> {
    launchctl_succeeds(&["print", &format!("{}/{label}", gui_domain())]).await
}

pub(super) async fn clear_chatgpt_launchctl_environment() {
    for key in CHATGPT_LAUNCHCTL_KEYS {
        match launchctl_succeeds(&["unsetenv", key]).await {
            Ok(true) => {}
            Ok(false) => warn!(key, "launchctl could not unset the ChatGPT environment key"),
            Err(error) => warn!(key, %error, "launchctl unsetenv did not run"),
        }
    }
}

pub(super) fn gui_domain() -> String {
    format!("gui/{}", unsafe { libc::getuid() })
}

pub(super) fn launchctl() -> TokioCommand {
    TokioCommand::new("launchctl")
}

pub(super) async fn unload_gateway_launchagent() -> Result<bool> {
    let loaded = gateway_launchagent_is_loaded().await?;
    if !loaded {
        return Ok(false);
    }
    let domain = format!("{}/{GATEWAY_LABEL}", gui_domain());
    let status = launchctl()
        .args(["bootout", &domain])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await?;
    if !status.success() {
        bail!("failed to unload {GATEWAY_LABEL} for runtime upgrade");
    }
    Ok(true)
}

pub(super) async fn gateway_launchagent_is_loaded() -> Result<bool> {
    service_is_loaded(GATEWAY_LABEL).await
}

pub(super) async fn restore_gateway_launchagent(was_loaded: bool) -> Result<()> {
    if !was_loaded || gateway_launchagent_is_loaded().await? {
        return Ok(());
    }
    let paths = HostPaths::from_env()?;
    let plist = paths
        .home()
        .join("Library/LaunchAgents")
        .join(format!("{GATEWAY_LABEL}.plist"));
    if !plist.is_file() {
        bail!("gateway LaunchAgent plist is missing: {}", plist.display());
    }
    let domain = gui_domain();
    let status = launchctl()
        .arg("bootstrap")
        .arg(domain)
        .arg(&plist)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await?;
    if !status.success() {
        bail!("failed to restore {GATEWAY_LABEL}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_launchd_listing_yields_its_first_state_pid_and_spawn_type() {
        let job = LaunchdJob::parse(
            "gui/501/com.remote-coder.codex-gateway = {\n\tstate = running\n\tpid = 4242\n\tspawn type = interactive (3)\n\tendpoints = {\n\t\tstate = other\n\t}\n}\n",
        );

        assert_eq!(job.state.as_deref(), Some("running"));
        assert_eq!(job.pid, Some(4242));
        assert_eq!(job.spawn_type.as_deref(), Some("interactive"));
        assert!(job.is_busy());
    }

    #[test]
    fn an_idle_listing_without_a_pid_is_not_busy() {
        let job = LaunchdJob::parse("\tstate = not running\n\tlast exit code = 0\n");

        assert_eq!(job.pid, None);
        assert_eq!(job.spawn_type, None);
        assert!(!job.is_busy());
    }
}
