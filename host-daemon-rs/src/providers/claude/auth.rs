use std::path::Path;
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use serde_json::Value;
use tokio::io::AsyncReadExt;
use tokio::sync::{Mutex, RwLock};

use crate::providers::claude::exec as claude_exec;
use crate::providers::claude::settings::ClaudeSettings;
use crate::time::unix_seconds;

#[derive(Debug, Clone)]
pub(crate) struct ClaudeAuthSnapshot {
    pub error: Option<String>,
    pub version: Option<String>,
    pub checked_at_unix_seconds: f64,
    refresh_after: Instant,
}

impl ClaudeAuthSnapshot {
    pub(crate) fn ok(&self) -> bool {
        self.error.is_none()
    }
}

pub(crate) struct ClaudeAuth {
    settings: ClaudeSettings,
    refresh_lock: Mutex<()>,
    snapshot: RwLock<Option<ClaudeAuthSnapshot>>,
}

impl ClaudeAuth {
    pub fn new(settings: ClaudeSettings) -> Self {
        Self {
            settings,
            refresh_lock: Mutex::new(()),
            snapshot: RwLock::new(None),
        }
    }

    pub(crate) async fn cached_snapshot(&self) -> Option<ClaudeAuthSnapshot> {
        self.snapshot.read().await.clone()
    }

    pub(crate) async fn snapshot_refreshing(self: &Arc<Self>) -> ClaudeAuthSnapshot {
        self.refresh().await
    }

    pub(crate) async fn refresh(&self) -> ClaudeAuthSnapshot {
        let _guard = self.refresh_lock.lock().await;
        if let Some(snapshot) = self.cached_snapshot().await
            && Instant::now() < snapshot.refresh_after
        {
            return snapshot;
        }
        let settings = self.settings.clone();
        let ready = tokio::task::spawn_blocking(move || {
            settings
                .router
                .as_ref()
                .map(|router| router.key().map(|_| ()))
                .transpose()
        })
        .await;
        let mut error = match ready {
            Ok(Ok(_)) => None,
            Ok(Err(error)) => Some(error.to_string()),
            Err(_) => Some("Claude router readiness check failed".into()),
        };
        if error.is_none() && self.settings.router.is_none() {
            error = self
                .native_auth()
                .await
                .err()
                .map(|error| error.to_string());
        }
        let version = if error.is_none() {
            self.run_version().await
        } else {
            None
        };
        let snapshot = ClaudeAuthSnapshot {
            error,
            version,
            checked_at_unix_seconds: unix_seconds(),
            refresh_after: Instant::now()
                + Duration::from_secs(self.settings.auth_preflight_interval_secs),
        };
        *self.snapshot.write().await = Some(snapshot.clone());
        snapshot
    }

    async fn native_auth(&self) -> Result<()> {
        let mut command = claude_exec::command(
            &self.settings,
            &["auth".into(), "status".into(), "--json".into()],
        )?;
        let checked = tokio::time::timeout(Duration::from_secs(10), async {
            let mut child = command
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .kill_on_drop(true)
                .spawn()?;
            let stdout = child
                .stdout
                .take()
                .ok_or_else(|| anyhow!("Claude authentication status is unavailable"))?;
            let mut bytes = Vec::new();
            stdout.take(16_385).read_to_end(&mut bytes).await?;
            anyhow::ensure!(
                bytes.len() <= 16_384,
                "Claude authentication status exceeds its limit"
            );
            let status = child.wait().await?;
            let response: Value = serde_json::from_slice(&bytes)
                .map_err(|_| anyhow!("Claude authentication status is unreadable"))?;
            anyhow::ensure!(
                status.success() && response["loggedIn"] == true,
                "Claude Code is not signed in; run claude auth login on this host"
            );
            Ok(())
        })
        .await;
        checked.map_err(|_| anyhow!("Claude authentication status timed out"))?
    }

    async fn run_version(&self) -> Option<String> {
        let mut command = claude_exec::command(&self.settings, &["--version".into()]).ok()?;
        tokio::time::timeout(Duration::from_secs(10), async {
            let mut child = command
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .kill_on_drop(true)
                .spawn()
                .ok()?;
            let stdout = child.stdout.take()?;
            let mut bytes = Vec::new();
            stdout.take(4097).read_to_end(&mut bytes).await.ok()?;
            if bytes.len() > 4096 || !child.wait().await.ok()?.success() {
                return None;
            }
            String::from_utf8(bytes)
                .ok()
                .map(|version| version.trim().to_owned())
        })
        .await
        .ok()?
    }
}

pub(crate) fn health_json(
    settings: &ClaudeSettings,
    snapshot: Option<&ClaudeAuthSnapshot>,
    active_turns: usize,
) -> Value {
    serde_json::json!({
        "enabled": settings.enabled,
        "authentication": if settings.router.is_some() { "router" } else { "native" },
        "ok": snapshot.is_some_and(ClaudeAuthSnapshot::ok),
        "version": snapshot.and_then(|snapshot| snapshot.version.clone()),
        "error": snapshot.and_then(|snapshot| snapshot.error.clone()),
        "activeTurns": active_turns,
        "checkedAtUnixSeconds": snapshot.map(|snapshot| snapshot.checked_at_unix_seconds),
    })
}

/// Absolute path guard used at startup when the provider is enabled.
pub(crate) fn validate_claude_path(path: &Path) -> Result<()> {
    if !path.is_absolute() {
        return Err(anyhow!(
            "RC_CLAUDE_PATH must be absolute: {}",
            path.display()
        ));
    }
    if !path.is_file() {
        return Err(anyhow!("RC_CLAUDE_PATH is not a file: {}", path.display()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn native_readiness_checks_the_cli_login_without_a_router() {
        use std::os::unix::fs::PermissionsExt;
        let fixture = ClaudeSettings::isolated_for_test();
        let executable = fixture.root_path().join("claude-status");
        let mut settings = fixture.settings.clone();
        settings.router = None;
        settings.claude_path = executable.clone();
        settings.enabled = true;
        for logged_in in [true, false] {
            std::fs::write(
                &executable,
                format!("#!/bin/sh\nprintf '%s' '{{\"loggedIn\":{logged_in}}}'\n"),
            )
            .unwrap();
            std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
            let snapshot = ClaudeAuth::new(settings.clone()).refresh().await;
            assert_eq!(snapshot.ok(), logged_in);
            assert_eq!(
                health_json(&settings, Some(&snapshot), 0)["authentication"],
                "native"
            );
            if !logged_in {
                assert!(snapshot.error.unwrap().contains("claude auth login"));
            }
        }
    }

    #[tokio::test]
    async fn readiness_uses_router_key_without_a_local_subscription_or_cli() {
        let fixture = ClaudeSettings::isolated_for_test();
        let settings = ClaudeSettings {
            enabled: true,
            claude_path: "/nonexistent/claude".into(),
            ..fixture.settings.clone()
        };
        let snapshot = ClaudeAuth::new(settings.clone()).refresh().await;
        assert!(snapshot.ok());
        assert!(snapshot.version.is_none());
        let health = health_json(&settings, Some(&snapshot), 0);
        assert_eq!(health["ok"], true);
        assert!(health.get("accountKey").is_none());
        std::fs::remove_file(settings.router.as_ref().unwrap().key_file()).unwrap();
        let snapshot = ClaudeAuth::new(settings).refresh().await;
        assert!(!snapshot.ok());
        assert!(
            snapshot
                .error
                .unwrap()
                .contains("RC_CODEX_GATEWAY_ROUTER_KEY_FILE")
        );
    }
}
