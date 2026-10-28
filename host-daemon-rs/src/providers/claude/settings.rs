use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow};
use serde_json::Value;
use tracing::{debug, warn};

use crate::config::{ConfigSources, HostPaths};

/// Claude provider configuration.
#[derive(Debug, Clone)]
pub(crate) struct ClaudeSettings {
    pub enabled: bool,
    pub claude_path: PathBuf,
    pub claude_home: PathBuf,
    pub config_dir: Option<PathBuf>,
    pub router: Option<crate::providers::router::RouterConfig>,
    pub default_model: String,
    pub auth_preflight_interval_secs: u64,
    /// Where a spawned Claude runtime reaches the gateway's own MCP server for
    /// the RemoteCoder agent tools. Always loopback: the child runs on this host.
    pub mcp_endpoint: String,
    /// Per-runtime `--mcp-config` files live here, one per Claude session.
    pub mcp_config_dir: PathBuf,
}

#[cfg(test)]
pub(crate) struct ClaudeTestSettings {
    _root: tempfile::TempDir,
    pub settings: ClaudeSettings,
}

#[cfg(test)]
impl ClaudeTestSettings {
    pub(crate) fn root_path(&self) -> &Path {
        self._root.path()
    }
}

impl ClaudeSettings {
    #[cfg(test)]
    pub(crate) fn isolated_for_test() -> ClaudeTestSettings {
        let root = tempfile::tempdir().expect("test Claude home");
        let claude_home = root
            .path()
            .canonicalize()
            .expect("canonical test home")
            .join("claude");
        fs::create_dir(&claude_home).expect("test Claude directory");
        let router_key_file = root.path().join("router-key");
        fs::write(&router_key_file, "test-router-key").expect("test router key");
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&router_key_file, fs::Permissions::from_mode(0o600))
            .expect("private test key");
        let settings = Self {
            enabled: false,
            claude_path: PathBuf::from("claude"),
            claude_home: claude_home.clone(),
            config_dir: Some(claude_home.clone()),
            router: Some(
                crate::providers::router::RouterConfig::unreachable_for_test(router_key_file),
            ),
            default_model: "claude-fable-5".to_string(),
            auth_preflight_interval_secs: 300,
            mcp_endpoint: String::new(),
            mcp_config_dir: root.path().join("mcp"),
        };
        ClaudeTestSettings {
            _root: root,
            settings,
        }
    }

    pub(crate) fn load(
        sources: &ConfigSources,
        paths: &HostPaths,
        gateway_port: u16,
        router: Option<crate::providers::router::RouterConfig>,
    ) -> Result<Self> {
        let home = paths.home();

        let configured_path = sources.optional_string("RC_CLAUDE_PATH");
        if let Some(configured) = &configured_path {
            anyhow::ensure!(
                Path::new(configured).is_absolute(),
                "RC_CLAUDE_PATH must be absolute: {configured}"
            );
        }
        let claude_path =
            crate::providers::claude::exec::resolve_claude_path(configured_path.as_deref(), home)
                .unwrap_or_else(|| PathBuf::from("claude"));

        if let Err(error) = crate::providers::claude::auth::validate_claude_path(&claude_path) {
            warn!(%error, "Claude executable unavailable; Claude turns fail and /health.claude reports it until it is installed");
        }

        let config_dir = sources.optional_string("RC_CLAUDE_HOME").map(PathBuf::from);
        let claude_home = config_dir.clone().unwrap_or_else(|| home.join(".claude"));
        let default_model = "claude-fable-5".to_string();
        let auth_preflight_interval_secs = 300;

        Ok(Self {
            enabled: true,
            claude_path,
            config_dir,
            claude_home,
            router,
            default_model,
            auth_preflight_interval_secs,
            mcp_endpoint: format!("http://127.0.0.1:{gateway_port}/mcp"),
            mcp_config_dir: paths.state("claude-mcp"),
        })
    }

    /// Resolves the same effective auto-compact ceiling Claude Code applies.
    ///
    /// RemoteCoder launches the native CLI with the user's normal `HOME`, so
    /// Claude reads user, project, local, and managed settings. Resolve the
    /// window from those same files for the context meter instead of exposing
    /// only the model's theoretical maximum from `result.modelUsage`.
    pub(crate) fn auto_compact_window(&self, cwd: &Path) -> Option<i64> {
        let mut setting_window = None;
        let mut environment_window = None;

        for path in claude_settings_paths(&self.claude_home, cwd) {
            let Some(settings) = read_claude_settings(&path) else {
                continue;
            };

            if let Some(value) = settings.get("autoCompactWindow") {
                match parse_compact_window(value, false) {
                    Ok(window) => setting_window = Some((window, path.clone())),
                    Err(error) => {
                        warn!(path = %path.display(), %error, "ignoring invalid Claude autoCompactWindow")
                    }
                }
            }

            if let Some(value) = settings
                .get("env")
                .and_then(Value::as_object)
                .and_then(|env| env.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW"))
            {
                match parse_compact_window(value, true) {
                    Ok(window) => environment_window = Some((window, path.clone())),
                    Err(error) => {
                        warn!(path = %path.display(), %error, "ignoring invalid Claude auto-compact environment override")
                    }
                }
            }
        }

        let resolved = environment_window.or(setting_window);
        if let Some((window, source)) = resolved.as_ref() {
            debug!(window, source = %source.display(), "resolved Claude auto-compact window");
        }
        resolved.map(|(window, _)| window)
    }
}

fn claude_settings_paths(claude_home: &Path, cwd: &Path) -> Vec<PathBuf> {
    let project_root = cwd
        .ancestors()
        .find(|ancestor| ancestor.join(".git").exists())
        .unwrap_or(cwd);
    let mut paths = vec![claude_home.join("settings.json")];

    for path in [
        project_root.join(".claude/settings.json"),
        cwd.join(".claude/settings.local.json"),
        project_root.join(".claude/settings.local.json"),
        PathBuf::from("/Library/Application Support/ClaudeCode/managed-settings.json"),
    ] {
        if !paths.contains(&path) {
            paths.push(path);
        }
    }

    paths
}

fn read_claude_settings(path: &Path) -> Option<Value> {
    let content = match fs::read_to_string(path) {
        Ok(content) => content,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return None,
        Err(error) => {
            warn!(path = %path.display(), %error, "failed reading Claude settings");
            return None;
        }
    };

    match serde_json::from_str(&content) {
        Ok(value) => Some(value),
        Err(error) => {
            warn!(path = %path.display(), %error, "failed parsing Claude settings");
            None
        }
    }
}

fn parse_compact_window(value: &Value, environment_value: bool) -> Result<i64> {
    let window = if environment_value {
        value
            .as_str()
            .ok_or_else(|| anyhow!("CLAUDE_CODE_AUTO_COMPACT_WINDOW must be a string"))?
            .parse::<i64>()
            .context("CLAUDE_CODE_AUTO_COMPACT_WINDOW must be a plain token count")?
    } else {
        value
            .as_i64()
            .ok_or_else(|| anyhow!("autoCompactWindow must be an integer"))?
    };

    if !(100_000..=1_000_000).contains(&window) {
        return Err(anyhow!(
            "auto-compact window must be between 100000 and 1000000 tokens"
        ));
    }
    Ok(window)
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use tempfile::TempDir;

    use super::*;

    #[test]
    fn a_missing_claude_executable_does_not_stop_settings_loading() {
        let home = TempDir::new().expect("host home");
        let paths = HostPaths::from_home(home.path().to_path_buf()).expect("host paths");
        let load = |claude_path: &str| {
            ClaudeSettings::load(
                &ConfigSources::from_file_vars(HashMap::from([(
                    "RC_CLAUDE_PATH".to_string(),
                    claude_path.to_string(),
                )])),
                &paths,
                8787,
                None,
            )
        };

        let settings = load("/nonexistent/claude").expect("missing executable is not fatal");
        assert_eq!(settings.claude_path, PathBuf::from("/nonexistent/claude"));
        assert_eq!(settings.mcp_endpoint, "http://127.0.0.1:8787/mcp");
        assert!(settings.config_dir.is_none());
        assert_eq!(settings.claude_home, home.path().join(".claude"));
        let error = load("claude").expect_err("relative path is a configuration error");
        assert!(error.to_string().contains("must be absolute"));
    }

    #[test]
    fn claude_auto_compact_environment_override_wins_across_scopes() {
        let claude_test = ClaudeSettings::isolated_for_test();
        let temp = TempDir::new().expect("temp dir");
        let claude_home = temp.path().join("home/.claude");
        let project = temp.path().join("project");
        fs::create_dir_all(&claude_home).expect("claude home");
        fs::create_dir_all(project.join(".git")).expect("git root");
        fs::create_dir_all(project.join(".claude")).expect("project settings");
        fs::write(
            claude_home.join("settings.json"),
            r#"{"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"400000"}}"#,
        )
        .expect("user settings");
        fs::write(
            project.join(".claude/settings.json"),
            r#"{"autoCompactWindow":500000}"#,
        )
        .expect("project settings");
        let settings = ClaudeSettings {
            claude_home,
            ..claude_test.settings.clone()
        };

        assert_eq!(settings.auto_compact_window(&project), Some(400_000));
    }
}
