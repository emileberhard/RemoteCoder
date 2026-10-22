use std::collections::HashMap;
use std::io::{Error, Result};
use std::ops::{Deref, DerefMut};
use std::path::{Path, PathBuf};

use crate::providers::claude::settings::ClaudeSettings;
use tokio::process::Command;

pub(crate) struct ClaudeCommand(Command);

impl std::fmt::Debug for ClaudeCommand {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ClaudeCommand")
            .field("program", &self.0.as_std().get_program())
            .finish_non_exhaustive()
    }
}

impl Deref for ClaudeCommand {
    type Target = Command;
    fn deref(&self) -> &Command {
        &self.0
    }
}

impl DerefMut for ClaudeCommand {
    fn deref_mut(&mut self) -> &mut Command {
        &mut self.0
    }
}

impl ClaudeCommand {
    pub(crate) fn into_inner(self) -> Command {
        self.0
    }
}

/// Environment variables the Claude child is allowed to inherit.
///
/// `PATH` is handled separately, and `TERM` is
/// forced to `dumb` so the CLI never emits interactive control sequences.
const INHERITED_ENV_KEYS: [&str; 4] = ["HOME", "USER", "SHELL", "LANG"];

/// Credential-shaped variables that must never reach the child.
///
/// Matches the interactive guard (`env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN
/// -u CLAUDE_CODE_OAUTH_TOKEN`) and generalizes it: `env_clear` already removes
/// everything, and this list is what the debug assertion re-checks.
fn is_credential_env_key(key: &str) -> bool {
    key.starts_with("ANTHROPIC_") || key == "CLAUDE_CODE_OAUTH_TOKEN" || key.ends_with("_API_KEY")
}

/// Builds the child environment for a Claude invocation.
///
/// Returned as an owned map so tests can assert on it without spawning.
pub(crate) fn child_env() -> HashMap<String, String> {
    child_env_from(|key| std::env::var(key).ok())
}

fn child_env_from(value_for: impl Fn(&str) -> Option<String>) -> HashMap<String, String> {
    let mut env: HashMap<String, String> = HashMap::new();

    for key in INHERITED_ENV_KEYS {
        if let Some(value) = value_for(key)
            && !value.trim().is_empty()
        {
            env.insert(key.to_string(), value);
        }
    }

    // The inherited PATH keeps the agent tools available after env_clear.
    let path = value_for("PATH")
        .filter(|path| !path.trim().is_empty())
        .unwrap_or_else(|| "/usr/bin:/bin:/usr/sbin:/sbin".into());
    env.insert("PATH".to_string(), path);

    // Non-interactive output only.
    env.insert("TERM".to_string(), "dumb".to_string());

    // The gateway's own MCP server speaks exactly one protocol revision and has
    // no legacy handshake path, so revision selection is pinned rather than left
    // to whatever a future CLI release defaults to.
    env.insert("MCP_PROTOCOL_NEGOTIATION".to_string(), "auto".to_string());

    debug_assert!(
        !env.keys().any(|key| is_credential_env_key(key)),
        "claude child environment must not carry credential variables"
    );

    env
}

/// Builds a `claude` command with a cleared, allow-listed environment.
///
/// `args` is the complete argument vector; callers own argv construction so there
/// is exactly one place per call site to audit.
pub(crate) fn command(settings: &ClaudeSettings, args: &[String]) -> Result<ClaudeCommand> {
    debug_assert!(
        !args.iter().any(|arg| arg == "--bare"),
        "claude must never be invoked with --bare"
    );

    let mut cmd = Command::new(&settings.claude_path);
    #[cfg(target_os = "macos")]
    crate::platform::macos::scheduling::prepare_agent_command(&mut cmd);
    cmd.args(args);
    cmd.env_clear();
    for (key, value) in child_env() {
        cmd.env(key, value);
    }
    if let Some(directory) = &settings.config_dir {
        cmd.env("CLAUDE_CONFIG_DIR", directory);
    }
    if let Some(router) = &settings.router {
        let key = router
            .key()
            .map_err(|error| Error::other(error.to_string()))?;
        cmd.env("ANTHROPIC_BASE_URL", router.inference_base());
        cmd.env("ANTHROPIC_AUTH_TOKEN", key);
        cmd.env("CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK", "1");
    }
    Ok(ClaudeCommand(cmd))
}

/// Resolves the `claude` executable to an absolute path.
///
/// Resolution order is explicit configuration, then the canonical native
/// install, then `PATH`. `PATH` is deliberately last: on managed hosts a wrapper
/// shim shadows `claude` on `PATH` and injects unrelated launch settings. The
/// gateway inherits host settings and adds only its runtime-owned tool hook.
pub(crate) fn resolve_claude_path(configured: Option<&str>, home: &Path) -> Option<PathBuf> {
    if let Some(configured) = configured {
        let trimmed = configured.trim();
        if !trimmed.is_empty() {
            return Some(PathBuf::from(trimmed));
        }
    }

    let canonical = home.join(".local/bin/claude");
    if canonical.is_file() {
        return Some(canonical);
    }

    let paths = std::env::var_os("PATH")?;
    std::env::split_paths(&paths)
        .map(|dir| dir.join("claude"))
        .find(|candidate| candidate.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn router_credentials_are_private_rotatable_and_never_diagnosed() {
        use std::os::unix::fs::PermissionsExt;
        let fixture = ClaudeSettings::isolated_for_test();
        let settings = &fixture.settings;
        let command = super::command(settings, &["--version".into()]).unwrap();
        let env: HashMap<_, _> = command
            .as_std()
            .get_envs()
            .filter_map(|(key, value)| {
                value.map(|value| {
                    (
                        key.to_string_lossy().into_owned(),
                        value.to_string_lossy().into_owned(),
                    )
                })
            })
            .collect();
        assert_eq!(env["ANTHROPIC_BASE_URL"], "http://127.0.0.1:1");
        assert_eq!(env["ANTHROPIC_AUTH_TOKEN"], "test-router-key");
        assert_eq!(env["CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK"], "1");
        assert!(!format!("{command:?}").contains("test-router-key"));
        assert_eq!(
            env.keys()
                .filter(|key| key.starts_with("ANTHROPIC_"))
                .count(),
            2
        );
        assert!(!env.contains_key("CLAUDE_CODE_OAUTH_TOKEN"));
        assert!(!env.contains_key("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"));
        assert!(!format!("{settings:?}").contains("test-router-key"));
        std::fs::write(
            settings.router.as_ref().unwrap().key_file(),
            "rotated-private-token",
        )
        .unwrap();
        assert_eq!(
            settings.router.as_ref().unwrap().key().unwrap(),
            "rotated-private-token"
        );
        std::fs::set_permissions(
            settings.router.as_ref().unwrap().key_file(),
            std::fs::Permissions::from_mode(0o644),
        )
        .unwrap();
        let error = super::command(settings, &[]).err().unwrap();
        assert!(!format!("{error:?}").contains("rotated-private-token"));
        assert!(error.to_string().contains("mode 0600"));
        std::fs::remove_file(settings.router.as_ref().unwrap().key_file()).unwrap();
        let error = super::command(settings, &[]).err().unwrap();
        assert!(
            error
                .to_string()
                .contains("RC_CODEX_GATEWAY_ROUTER_KEY_FILE")
        );
    }

    #[test]
    fn native_login_commands_do_not_inject_router_authentication_or_fast_bypass() {
        let fixture = ClaudeSettings::isolated_for_test();
        let mut settings = fixture.settings.clone();
        settings.router = None;
        let command = super::command(&settings, &["auth".into(), "status".into()]).unwrap();
        let keys: Vec<_> = command
            .as_std()
            .get_envs()
            .map(|(key, _)| key.to_string_lossy())
            .collect();
        assert!(
            !keys.iter().any(
                |key| key.starts_with("ANTHROPIC_") || key.starts_with("CLAUDE_CODE_SKIP_FAST")
            )
        );
        assert!(keys.iter().any(|key| key == "CLAUDE_CONFIG_DIR"));
    }

    #[test]
    fn child_env_preserves_path_and_pins_the_cli_contract() {
        let env = child_env_from(|key| (key == "PATH").then(|| "/usr/bin:/local/tools".into()));
        let path = env.get("PATH").expect("PATH is always set");

        assert_eq!(path, "/usr/bin:/local/tools");
        assert_eq!(env.get("TERM").map(String::as_str), Some("dumb"));
        // The gateway's MCP server speaks one revision and has no legacy path,
        // so a CLI default change must not silently move the negotiation.
        assert_eq!(
            env.get("MCP_PROTOCOL_NEGOTIATION").map(String::as_str),
            Some("auto")
        );
    }

    #[test]
    fn child_env_never_carries_credentials() {
        let env = child_env_from(|key| {
            Some(
                match key {
                    "ANTHROPIC_API_KEY" => "sk-ant-should-not-leak",
                    "CLAUDE_CODE_OAUTH_TOKEN" => "oauth-should-not-leak",
                    "OPENAI_API_KEY" => "sk-should-not-leak",
                    "PATH" => "/usr/bin",
                    _ => "allowed",
                }
                .to_string(),
            )
        });

        assert!(!env.contains_key("ANTHROPIC_API_KEY"));
        assert!(!env.contains_key("CLAUDE_CODE_OAUTH_TOKEN"));
        assert!(!env.contains_key("OPENAI_API_KEY"));
        assert!(!env.keys().any(|key| is_credential_env_key(key)));
    }

    #[test]
    fn resolve_claude_path_prefers_explicit_configuration() {
        let resolved = resolve_claude_path(Some("/opt/claude"), Path::new("/Users/nobody"));

        assert_eq!(resolved, Some(PathBuf::from("/opt/claude")));
    }
}
