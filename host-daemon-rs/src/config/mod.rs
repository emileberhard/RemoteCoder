pub(crate) mod host_profile;

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command as ProcessCommand;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use anyhow::{Context, Result, anyhow};
use clap::{Parser, Subcommand};

use crate::providers::claude::settings::ClaudeSettings;

const GATEWAY_LOG_FILTER_ENV_KEY: &str = "RC_CODEX_GATEWAY_LOG";
const LAN_PORT_ENV_KEY: &str = "RC_CODEX_GATEWAY_LAN_PORT";
pub(crate) const DEFAULT_LOG_RETENTION_DAYS: u64 = 30;
pub(crate) const REQUIRED_CODEX_VERSION: &str = env!("RC_REQUIRED_CODEX_VERSION");
pub(crate) const REQUIRED_CODEX_SOURCE_COMMIT: &str = env!("RC_REQUIRED_CODEX_SOURCE_COMMIT");
pub(crate) const REQUIRED_CODEX_SHA256: &str = env!("RC_REQUIRED_CODEX_SHA256");
pub(crate) const REQUIRED_CODE_MODE_HOST_SHA256: &str = env!("RC_REQUIRED_CODE_MODE_HOST_SHA256");
const CODE_MODE_HOST_NAME: &str = if cfg!(windows) {
    "codex-code-mode-host.exe"
} else {
    "codex-code-mode-host"
};

#[derive(Clone, Debug, Parser)]
#[command(name = "remote-coder-codex-gateway")]
pub(crate) struct Args {
    #[arg(long, action = clap::ArgAction::SetTrue)]
    pub version: bool,

    #[command(subcommand)]
    pub command: Option<Command>,

    /// Run only the persisted restart recovery control loop, without ingress.
    #[arg(long, hide = true)]
    pub recovery_only: bool,

    /// Optional env file (KEY=VALUE) to load settings from.
    #[arg(long)]
    pub env_file: Option<PathBuf>,
}

#[derive(Clone, Debug, Subcommand)]
pub(crate) enum Command {
    CheckConfig,
    #[command(hide = true)]
    ClaudeNotificationHook {
        #[arg(long)]
        mcp_config: PathBuf,
        #[arg(long)]
        session_id: String,
    },
    #[command(hide = true)]
    ClaudeSessionContext,
    /// Provision and revoke app-installation credentials without restarting agents.
    Credentials {
        #[command(subcommand)]
        command: crate::auth::installation_credentials::CredentialCommand,
    },
    /// Manage the shared Codex runtime as one recoverable transaction.
    Runtime {
        #[command(subcommand)]
        command: RuntimeCommand,
    },
}

#[derive(Clone, Debug, Subcommand)]
pub(crate) enum RuntimeCommand {
    /// Install a reviewed Codex package through the same recovery transaction.
    Install {
        package_dir: PathBuf,
        /// Validate the candidate and source without staging or changing service state.
        #[arg(long)]
        check_only: bool,
        /// Check an exact installed package before the gateway health-gated commit.
        #[arg(long, requires = "check_only")]
        check_installed: bool,
    },
    /// Restart the managed app-server and recover every active exact turn.
    Restart,
    /// Suspend active turns so a replacement gateway can recover them.
    PrepareHandoff,
    /// Fence, snapshot, suspend, and stop the daemon for a host shutdown.
    PrepareShutdown,
    /// Finish a pending handoff after a host or service restart.
    Reconcile,
    #[command(
        about = "Retry an exact failed recovery generation through the managed restart transaction."
    )]
    RetryFailed {
        #[arg(long)]
        generation_id: String,
    },
    /// Manage the ChatGPT Desktop client without giving it a private app-server.
    Desktop {
        #[command(subcommand)]
        action: DesktopAction,
    },
    InstallCallWorker {
        #[arg(long)]
        worker_host: Option<String>,
    },
    ConfigureCallDelivery,
    PrepareGatewayStage {
        #[arg(long)]
        stage_id: u32,
    },
    ClearGatewayStage {
        #[arg(long)]
        stage_id: u32,
    },
    /// Replace the installed gateway from the staged binary running this command.
    InstallGateway {
        /// Suffix that names this run's staged files beside the installed ones.
        #[arg(long)]
        stage_id: u32,
    },
    /// Remove the gateway and Desktop services once no turn is running.
    Uninstall,
    /// Remove rollback artifacts after gateway and desktop validation succeeds.
    Commit,
    /// Restore the previous reviewed runtime through a second recovery transaction.
    Rollback,
}

#[derive(Clone, Copy, Debug, Subcommand)]
pub(crate) enum DesktopAction {
    Launch,
    Check,
    Stop,
    Mode,
}

impl DesktopAction {
    /// Stable name recorded as the `operation` of a desktop journal record.
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            DesktopAction::Launch => "launch",
            DesktopAction::Check => "check",
            DesktopAction::Stop => "stop",
            DesktopAction::Mode => "mode",
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct Settings {
    pub host_paths: HostPaths,
    pub bind_host: String,
    pub port: u16,
    pub lan_port: Option<u16>,
    pub codex_path: PathBuf,
    pub codex_code_mode_host_path: PathBuf,
    pub codex_version: String,
    pub auth_token: String,
    pub user_name: Option<String>,
    pub codex_child_env: HashMap<String, String>,
    pub push_broker_enabled: bool,
    pub claude: ClaudeSettings,
    pub router: Option<crate::providers::router::RouterConfig>,
    pub external_providers: Vec<crate::providers::codex::external::ExternalProvider>,
    pub speech_clients: crate::voice::speech::SpeechClients,
}

#[derive(Debug, Clone)]
pub(crate) struct HostPaths {
    home: PathBuf,
}

impl HostPaths {
    pub(crate) fn from_env() -> Result<Self> {
        let home = PathBuf::from(std::env::var_os("HOME").context("HOME is required")?);
        Self::from_home(home)
    }

    pub(crate) fn from_home(home: PathBuf) -> Result<Self> {
        anyhow::ensure!(
            home.is_absolute() && home.is_dir(),
            "HOME must be an existing absolute directory"
        );
        Ok(Self { home })
    }

    pub(crate) fn home(&self) -> &Path {
        &self.home
    }

    pub(crate) fn state_directory(&self) -> PathBuf {
        self.home.join(".remote-coder")
    }

    pub(crate) fn state(&self, name: &str) -> PathBuf {
        self.state_directory().join(name)
    }

    pub(crate) fn logs(&self, name: &str) -> PathBuf {
        self.logs_dir().join(name)
    }

    fn logs_dir(&self) -> PathBuf {
        self.home.join("Library/Logs/remote-coder")
    }
}

impl Settings {
    pub(crate) fn load(sources: &ConfigSources) -> Result<Self> {
        Self::load_with_codex(sources, CodexSettings::load(sources)?)
    }

    pub(crate) fn load_for_recovery(sources: &ConfigSources) -> Result<Self> {
        let codex = CodexSettings::load_for_runtime(sources)?;
        crate::runtime::identity::verify_recovery_package(&codex.codex_path)?;
        Self::load_with_codex(sources, codex)
    }

    fn load_with_codex(sources: &ConfigSources, codex: CodexSettings) -> Result<Self> {
        let host_paths = HostPaths::from_env()?;
        host_profile::validate()?;

        let GatewayEndpoint {
            bind_host,
            port,
            auth_token,
        } = GatewayEndpoint::load(sources)?;
        let lan_port = sources.lan_port(port)?;
        let push_broker_enabled = sources.optional_bool(
            "RC_CODEX_GATEWAY_PUSH_BROKER_ENABLED",
            sources.optional_string("RC_PUSH_BROKER_TOKEN").is_some(),
        )?;

        let speech_clients = crate::voice::speech::SpeechClients::parse(
            sources
                .raw(crate::voice::speech::SPEECH_CLIENTS_ENV_KEY)
                .as_deref(),
        )?;

        let CodexSettings {
            codex_path,
            codex_code_mode_host_path,
            codex_version,
            codex_child_env,
        } = codex;

        let router = crate::providers::router::RouterConfig::load(sources)?;
        let external_providers = crate::providers::codex::external::load(sources)?;
        let claude = ClaudeSettings::load(sources, &host_paths, port, router.clone())?;

        Ok(Self {
            host_paths,
            bind_host,
            port,
            lan_port,
            codex_path,
            codex_code_mode_host_path,
            codex_version,
            auth_token,
            user_name: user_name(sources)?,
            codex_child_env,
            push_broker_enabled,
            claude,
            speech_clients,
            router,
            external_providers,
        })
    }
}

fn user_name(sources: &ConfigSources) -> Result<Option<String>> {
    sources
        .raw("RC_CODEX_GATEWAY_USER_NAME")
        .map(|value| {
            let name = value.trim();
            anyhow::ensure!(
                !name.is_empty() && name.len() <= 128 && !value.chars().any(char::is_control),
                "RC_CODEX_GATEWAY_USER_NAME must contain 1–128 UTF-8 bytes without control characters"
            );
            Ok(name.to_owned())
        })
        .transpose()
}

/// Where the running gateway listens and the operator token that opens it,
/// for callers that talk to it over HTTP without the rest of `Settings`.
#[derive(Clone)]
pub(crate) struct GatewayEndpoint {
    bind_host: String,
    port: u16,
    auth_token: String,
}

impl GatewayEndpoint {
    pub(crate) fn load(sources: &ConfigSources) -> Result<Self> {
        Ok(Self {
            bind_host: sources.required_string("RC_CODEX_GATEWAY_BIND_HOST")?,
            port: sources.required_port("RC_CODEX_GATEWAY_PORT")?,
            auth_token: gateway_token(sources)?,
        })
    }

    pub(crate) fn url(&self, path: &str) -> String {
        let host = match self.bind_host.as_str() {
            "0.0.0.0" | "::" => "127.0.0.1",
            other => other,
        };
        format!("http://{host}:{}/{path}", self.port)
    }

    pub(crate) fn port(&self) -> u16 {
        self.port
    }

    pub(crate) fn bearer(&self) -> &str {
        &self.auth_token
    }
}

fn gateway_token(sources: &ConfigSources) -> Result<String> {
    let token = sources.required_string("RC_CODEX_GATEWAY_AUTH_TOKEN")?;
    let distinct: std::collections::HashSet<_> = token.bytes().collect();
    anyhow::ensure!(
        token.len() >= 32
            && token.len() <= 4096
            && !token.chars().any(char::is_whitespace)
            && distinct.len() >= 8
            && ![
                "replace-me",
                "change-me",
                "changeme",
                "your-token",
                "example-token"
            ]
            .iter()
            .any(|placeholder| token.to_ascii_lowercase().contains(placeholder)),
        "RC_CODEX_GATEWAY_AUTH_TOKEN must be a random token of at least 32 characters; generate one with openssl rand -hex 32"
    );
    Ok(token)
}

/// What the runtime commands need: the managed Codex executable and its child
/// environment, without the listener, credentials or Claude provider.
#[derive(Debug, Clone)]
pub(crate) struct CodexSettings {
    pub codex_path: PathBuf,
    pub codex_code_mode_host_path: PathBuf,
    pub codex_version: String,
    pub codex_child_env: HashMap<String, String>,
}

impl CodexSettings {
    pub(crate) fn load(sources: &ConfigSources) -> Result<Self> {
        let codex_path =
            resolve_executable_path(sources.required_path("RC_CODEX_GATEWAY_CODEX_PATH")?);
        let runtime = validate_codex_runtime(&codex_path)?;
        Ok(Self {
            codex_path,
            codex_code_mode_host_path: runtime.code_mode_host_path,
            codex_version: runtime.version,
            codex_child_env: sources.codex_child_env(),
        })
    }

    pub(crate) fn load_for_runtime(sources: &ConfigSources) -> Result<Self> {
        let codex_path =
            resolve_executable_path(sources.required_path("RC_CODEX_GATEWAY_CODEX_PATH")?);
        let identity = crate::runtime::identity::PackageIdentity::read(&codex_path)?;
        let runtime = validate_codex_runtime_for_version(&codex_path, &identity.version)?;
        let current = crate::config::HostPaths::from_env()?
            .home()
            .join(".codex/packages/standalone/current/codex");
        identity.verify(&current)?;
        Ok(Self {
            codex_path,
            codex_code_mode_host_path: runtime.code_mode_host_path,
            codex_version: runtime.version,
            codex_child_env: sources.codex_child_env(),
        })
    }
}

#[derive(Debug, Eq, PartialEq)]
struct CodexRuntime {
    code_mode_host_path: PathBuf,
    version: String,
}

fn validate_codex_runtime(codex_path: &Path) -> Result<CodexRuntime> {
    validate_codex_runtime_for_version(codex_path, REQUIRED_CODEX_VERSION)
}

fn validate_codex_runtime_for_version(
    codex_path: &Path,
    expected_version: &str,
) -> Result<CodexRuntime> {
    validate_executable(codex_path, "Codex executable")?;
    let resolved_codex_path = fs::canonicalize(codex_path).with_context(|| {
        format!(
            "failed to resolve Codex executable {}",
            codex_path.display()
        )
    })?;

    let code_mode_host_path = resolved_codex_path
        .parent()
        .ok_or_else(|| {
            anyhow!(
                "Codex executable has no parent directory: {}",
                codex_path.display()
            )
        })?
        .join(CODE_MODE_HOST_NAME);
    validate_executable(&code_mode_host_path, "Codex code-mode host").with_context(|| {
        format!(
            "incomplete Codex runtime beside {}; install the matched Codex package, not the codex executable alone",
            codex_path.display()
        )
    })?;

    let output = ProcessCommand::new(&resolved_codex_path)
        .arg("--version")
        .output()
        .with_context(|| {
            format!(
                "failed to query Codex version from {}",
                codex_path.display()
            )
        })?;
    if !output.status.success() {
        return Err(anyhow!(
            "Codex version probe failed for {} with status {}",
            codex_path.display(),
            output.status
        ));
    }
    let stdout = String::from_utf8(output.stdout).context("Codex version output was not UTF-8")?;
    let version = parse_codex_version(&stdout)?;
    if version != expected_version {
        return Err(anyhow!(
            "unsupported Codex version {version}; RemoteCoder requires {expected_version}"
        ));
    }

    Ok(CodexRuntime {
        code_mode_host_path,
        version,
    })
}

fn validate_executable(path: &Path, label: &str) -> Result<()> {
    let metadata = fs::metadata(path)
        .with_context(|| format!("{label} does not exist: {}", path.display()))?;
    if !metadata.is_file() {
        return Err(anyhow!("{label} must be a file: {}", path.display()));
    }
    #[cfg(unix)]
    if metadata.permissions().mode() & 0o111 == 0 {
        return Err(anyhow!("{label} is not executable: {}", path.display()));
    }
    Ok(())
}

pub(crate) fn parse_codex_version(output: &str) -> Result<String> {
    let mut fields = output.split_whitespace();
    let product = fields.next().unwrap_or_default();
    let version = fields.next().unwrap_or_default();
    if product != "codex-cli" || version.is_empty() || fields.next().is_some() {
        return Err(anyhow!(
            "unexpected Codex version output: {:?}",
            output.trim()
        ));
    }
    Ok(version.to_string())
}

/// Resolve the tracing filter from the gateway env-file without changing the process environment.
///
/// If `RUST_LOG` is already set, it wins.
///
/// Supported env-file key:
/// - `RC_CODEX_GATEWAY_LOG` (value is used as the tracing filter)
pub(crate) fn tracing_filter(sources: &ConfigSources) -> Option<String> {
    tracing_filter_from(
        std::env::var("RUST_LOG").ok().as_deref(),
        std::env::var(GATEWAY_LOG_FILTER_ENV_KEY).ok().as_deref(),
        sources
            .file_vars
            .get(GATEWAY_LOG_FILTER_ENV_KEY)
            .map(String::as_str),
    )
}

fn tracing_filter_from(
    rust_log: Option<&str>,
    gateway_log: Option<&str>,
    file_gateway_log: Option<&str>,
) -> Option<String> {
    rust_log
        .map(str::to_owned)
        .or_else(|| non_empty_trimmed(gateway_log))
        .or_else(|| non_empty_trimmed(file_gateway_log))
}

fn non_empty_trimmed(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

/// The daily rolling tracing appender (`codex-gateway.YYYY-MM-DD.log`) and the
/// directory it writes to. Rotation is UTC, matching the journal's day files.
pub(crate) fn rolling_log_appender()
-> Result<(tracing_appender::rolling::RollingFileAppender, String)> {
    let dir = log_dir()?;
    fs::create_dir_all(&dir)
        .with_context(|| format!("failed creating log directory {}", dir.display()))?;
    let appender = tracing_appender::rolling::Builder::new()
        .rotation(tracing_appender::rolling::Rotation::DAILY)
        .filename_prefix("codex-gateway")
        .filename_suffix("log")
        .max_log_files(usize::try_from(DEFAULT_LOG_RETENTION_DAYS).unwrap_or(30))
        .build(&dir)
        .with_context(|| format!("failed opening rolling logs in {}", dir.display()))?;
    Ok((appender, dir.display().to_string()))
}

fn log_dir() -> Result<PathBuf> {
    Ok(HostPaths::from_env()?.logs_dir())
}

/// The gateway env file and the process environment, with one precedence:
/// an env-file entry wins over the process environment, even when empty.
pub(crate) struct ConfigSources {
    file_vars: HashMap<String, String>,
}

impl ConfigSources {
    #[cfg(test)]
    pub(crate) fn from_file_vars(file_vars: HashMap<String, String>) -> Self {
        Self { file_vars }
    }

    pub(crate) fn load(env_file: Option<&Path>) -> Result<Self> {
        let file_vars = match env_file {
            Some(path) => load_env_file(path)
                .with_context(|| format!("failed reading env file {}", path.display()))?,
            None => HashMap::new(),
        };
        Ok(Self { file_vars })
    }

    pub(crate) fn raw(&self, key: &str) -> Option<String> {
        self.file_vars
            .get(key)
            .cloned()
            .or_else(|| std::env::var(key).ok())
    }

    pub(crate) fn optional_string(&self, key: &str) -> Option<String> {
        self.raw(key)
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    }

    fn required_string(&self, key: &str) -> Result<String> {
        let value = self.raw(key).ok_or_else(|| anyhow!("missing {key}"))?;
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return Err(anyhow!("{key} must be non-empty"));
        }
        Ok(trimmed.to_string())
    }

    fn required_port(&self, key: &str) -> Result<u16> {
        let value = self.raw(key).ok_or_else(|| anyhow!("missing {key}"))?;
        parse_port(key, &value)
    }

    fn required_path(&self, key: &str) -> Result<PathBuf> {
        let value = self.raw(key).ok_or_else(|| anyhow!("missing {key}"))?;
        Ok(PathBuf::from(value.trim()))
    }

    fn optional_bool(&self, key: &str, default: bool) -> Result<bool> {
        let Some(value) = self.raw(key) else {
            return Ok(default);
        };
        match value.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => Ok(true),
            "0" | "false" | "no" | "off" => Ok(false),
            _ => Err(anyhow!(
                "{key} must be a boolean (true/false, yes/no, on/off, or 1/0)"
            )),
        }
    }

    fn lan_port(&self, port: u16) -> Result<Option<u16>> {
        let Some(value) = self.optional_string(LAN_PORT_ENV_KEY) else {
            return Ok(None);
        };
        let lan_port = parse_port(LAN_PORT_ENV_KEY, &value)?;
        if lan_port == port {
            return Err(anyhow!(
                "{LAN_PORT_ENV_KEY} must differ from RC_CODEX_GATEWAY_PORT ({port})"
            ));
        }
        Ok(Some(lan_port))
    }

    /// Env-file entries forwarded into the `codex app-server` child.
    ///
    /// Gateway control keys stay daemon-only. `RC_CLAUDE_*` is excluded for the
    /// same reason: it configures the Claude provider, not Codex.
    ///
    /// Note this map is deliberately never reused for the Claude child. It can
    /// legitimately carry `ANTHROPIC_API_KEY` for Codex-side MCP tooling, and
    /// Claude receives only its explicitly configured llm-router credentials.
    fn codex_child_env(&self) -> HashMap<String, String> {
        self.file_vars
            .iter()
            .filter(|(key, _)| {
                !key.starts_with("RC_CODEX_GATEWAY_") && !key.starts_with("RC_CLAUDE_")
            })
            .filter(|(key, value)| !key.trim().is_empty() && !value.trim().is_empty())
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect()
    }
}

fn parse_port(key: &str, value: &str) -> Result<u16> {
    let parsed: u16 = value
        .trim()
        .parse()
        .with_context(|| format!("{key} must be a number"))?;
    if parsed == 0 {
        return Err(anyhow!("{key} must be between 1 and 65535"));
    }
    Ok(parsed)
}

fn resolve_executable_path(path: PathBuf) -> PathBuf {
    if path.components().count() != 1 {
        return path;
    }

    let Some(paths) = std::env::var_os("PATH") else {
        return path;
    };

    for directory in std::env::split_paths(&paths) {
        let candidate = directory.join(&path);
        if candidate.is_file() {
            return candidate;
        }
    }

    path
}

fn load_env_file(path: &Path) -> Result<HashMap<String, String>> {
    let content = fs::read_to_string(path)?;
    Ok(parse_env_file(&content))
}

fn parse_env_file(content: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();

    for raw_line in content.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        let line = line.strip_prefix("export ").unwrap_or(line);
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };

        let key = k.trim();
        if key.is_empty() {
            continue;
        }

        out.insert(key.to_string(), normalize_env_value(v));
    }

    out
}

fn normalize_env_value(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.len() >= 2 {
        let quoted = (trimmed.starts_with('"') && trimmed.ends_with('"'))
            || (trimmed.starts_with('\'') && trimmed.ends_with('\''));
        if quoted {
            return trimmed[1..trimmed.len() - 1].to_string();
        }
    }
    trimmed.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn operator_user_name_is_optional_bounded_and_rejects_invalid_configuration() {
        assert_eq!(
            user_name(&ConfigSources::from_file_vars(HashMap::new())).unwrap(),
            None
        );
        for (value, expected) in [(" Maya Chen ", "Maya Chen"), ("Åsa", "Åsa")] {
            let sources = ConfigSources::from_file_vars(HashMap::from([(
                "RC_CODEX_GATEWAY_USER_NAME".into(),
                value.into(),
            )]));
            assert_eq!(user_name(&sources).unwrap().as_deref(), Some(expected));
        }
        for value in [
            String::new(),
            "   ".into(),
            "a".repeat(129),
            "é".repeat(65),
            "Maya\nChen".into(),
            "Maya\tChen".into(),
        ] {
            let sources = ConfigSources::from_file_vars(HashMap::from([(
                "RC_CODEX_GATEWAY_USER_NAME".into(),
                value,
            )]));
            assert!(
                user_name(&sources)
                    .unwrap_err()
                    .to_string()
                    .contains("RC_CODEX_GATEWAY_USER_NAME")
            );
        }
    }

    #[test]
    fn operator_tokens_refuse_placeholders_short_or_repetitive_credentials() {
        for token in [
            "replace-me".to_owned(),
            "short-secret".to_owned(),
            "a".repeat(64),
            "replace-me-0123456789abcdef0123456789abcdef".to_owned(),
        ] {
            let sources = ConfigSources::from_file_vars(HashMap::from([(
                "RC_CODEX_GATEWAY_AUTH_TOKEN".into(),
                token.clone(),
            )]));
            let error = gateway_token(&sources).unwrap_err().to_string();
            assert!(error.contains("RC_CODEX_GATEWAY_AUTH_TOKEN"));
            assert!(!error.contains(&token));
        }
        let token: String = (b'a'..=b'z').map(char::from).cycle().take(32).collect();
        let sources = ConfigSources::from_file_vars(HashMap::from([(
            "RC_CODEX_GATEWAY_AUTH_TOKEN".into(),
            token.clone(),
        )]));
        assert_eq!(gateway_token(&sources).unwrap(), token);
    }

    #[test]
    fn a_wildcard_bind_is_probed_over_loopback() {
        let endpoint = |host: &str| {
            GatewayEndpoint::load(&ConfigSources {
                file_vars: HashMap::from([
                    ("RC_CODEX_GATEWAY_BIND_HOST".to_string(), host.to_string()),
                    ("RC_CODEX_GATEWAY_PORT".to_string(), "18787".to_string()),
                    (
                        "RC_CODEX_GATEWAY_AUTH_TOKEN".to_string(),
                        "0123456789abcdef".repeat(2),
                    ),
                ]),
            })
            .expect("gateway endpoint")
        };

        assert_eq!(
            endpoint("0.0.0.0").url("health"),
            "http://127.0.0.1:18787/health"
        );
        assert_eq!(
            endpoint("::").url("diagnostics"),
            "http://127.0.0.1:18787/diagnostics"
        );
        assert_eq!(
            endpoint("100.64.0.9").url("health"),
            "http://100.64.0.9:18787/health"
        );
    }

    #[test]
    fn host_paths_require_a_real_home_and_keep_persisted_locations() {
        let directory = TempDir::new().expect("host home");
        let paths = HostPaths::from_home(directory.path().to_path_buf()).expect("host paths");
        assert_eq!(
            paths.state("codex-restart-recovery.json"),
            directory
                .path()
                .join(".remote-coder/codex-restart-recovery.json")
        );
        assert_eq!(
            paths.logs("journal"),
            directory.path().join("Library/Logs/remote-coder/journal")
        );
        assert!(
            HostPaths::from_home(PathBuf::from("relative-home"))
                .expect_err("relative HOME")
                .to_string()
                .contains("HOME")
        );
    }

    #[test]
    fn tracing_filter_uses_process_value_then_gateway_value_then_file() {
        assert_eq!(
            tracing_filter_from(Some("debug"), Some("error"), Some("warn")),
            Some("debug".to_owned())
        );
        assert_eq!(
            tracing_filter_from(None, Some("error"), Some("warn")),
            Some("error".to_owned())
        );
        assert_eq!(
            tracing_filter_from(None, None, Some(" warn ")),
            Some("warn".to_owned())
        );
        assert_eq!(tracing_filter_from(None, Some(" "), None), None);
    }

    #[test]
    fn install_accepts_check_only_mode() {
        let install_args = Args::try_parse_from([
            "gateway",
            "--env-file",
            "/tmp/gateway.env",
            "runtime",
            "install",
            "/tmp/package",
        ])
        .expect("runtime install arguments");

        assert!(!install_args.recovery_only);
        assert!(matches!(
            install_args.command,
            Some(Command::Runtime {
                command: RuntimeCommand::Install {
                    package_dir,
                    check_only: false,
                    check_installed: false,
                },
            }) if package_dir == Path::new("/tmp/package")
        ));

        let check_args = Args::try_parse_from([
            "gateway",
            "--env-file",
            "/tmp/gateway.env",
            "runtime",
            "install",
            "/tmp/package",
            "--check-only",
        ])
        .expect("read-only candidate check arguments");
        assert!(matches!(
            check_args.command,
            Some(Command::Runtime {
                command: RuntimeCommand::Install {
                    check_only: true,
                    ..
                },
            })
        ));
        let installed_check = Args::try_parse_from([
            "gateway",
            "runtime",
            "install",
            "/tmp/package",
            "--check-only",
            "--check-installed",
        ])
        .expect("installed package check arguments");
        assert!(matches!(
            installed_check.command,
            Some(Command::Runtime {
                command: RuntimeCommand::Install {
                    check_only: true,
                    check_installed: true,
                    ..
                },
            })
        ));
        assert!(
            Args::try_parse_from([
                "gateway",
                "runtime",
                "install",
                "/tmp/package",
                "--check-installed",
            ])
            .is_err()
        );

        let recovery_args = Args::try_parse_from([
            "gateway",
            "--recovery-only",
            "--env-file",
            "/tmp/gateway.env",
        ])
        .expect("recovery-only gateway arguments");
        assert!(recovery_args.recovery_only);
        assert!(recovery_args.command.is_none());
    }

    #[test]
    fn codex_child_env_excludes_gateway_and_claude_control_keys() {
        let vars = HashMap::from([
            ("RC_CODEX_GATEWAY_PORT".to_string(), "8787".to_string()),
            ("RC_CLAUDE_PATH".to_string(), "/usr/bin/claude".to_string()),
            ("ANTHROPIC_API_KEY".to_string(), "sk-ant-x".to_string()),
        ]);

        let forwarded = ConfigSources { file_vars: vars }.codex_child_env();

        assert!(!forwarded.contains_key("RC_CODEX_GATEWAY_PORT"));
        assert!(!forwarded.contains_key("RC_CLAUDE_PATH"));
        // Codex-side tooling may legitimately need this; only Claude must never see it.
        assert_eq!(
            forwarded.get("ANTHROPIC_API_KEY").map(String::as_str),
            Some("sk-ant-x")
        );
    }

    #[test]
    fn codex_child_env_normalizes_exported_quoted_ca_path() {
        let file_vars = parse_env_file(" export SSL_CERT_FILE = '/configured/ca.pem' \n");

        assert_eq!(
            ConfigSources { file_vars }
                .codex_child_env()
                .get("SSL_CERT_FILE")
                .map(String::as_str),
            Some("/configured/ca.pem")
        );
    }

    #[test]
    fn lan_port_is_optional_distinct_and_valid() {
        let none = ConfigSources {
            file_vars: HashMap::new(),
        };
        assert_eq!(none.lan_port(8787).unwrap(), None);
        for (value, expected) in [
            ("  ", Ok(None)),
            (" 8789 ", Ok(Some(8789))),
            ("lan", Err("must be a number")),
            ("65536", Err("must be a number")),
            ("0", Err("must be between 1 and 65535")),
            ("8787", Err("must differ from RC_CODEX_GATEWAY_PORT (8787)")),
        ] {
            let sources = ConfigSources {
                file_vars: HashMap::from([(LAN_PORT_ENV_KEY.to_string(), value.to_string())]),
            };
            match (sources.lan_port(8787), expected) {
                (Ok(port), Ok(expected)) => assert_eq!(port, expected, "{value:?}"),
                (Err(error), Err(message)) => {
                    assert!(error.to_string().contains(message), "{value:?}: {error:#}");
                }
                (actual, expected) => panic!("{value:?}: {actual:?} instead of {expected:?}"),
            }
        }
    }

    #[test]
    fn optional_bool_reads_the_file_value_or_rejects_it() {
        let read = |value: &str| {
            ConfigSources {
                file_vars: HashMap::from([(
                    "RC_CODEX_GATEWAY_PUSH_BROKER_ENABLED".to_string(),
                    value.to_string(),
                )]),
            }
            .optional_bool("RC_CODEX_GATEWAY_PUSH_BROKER_ENABLED", true)
        };

        assert!(!read("off").expect("valid bool"));
        let error = read("sometimes").expect_err("invalid bool must fail");
        assert!(error.to_string().contains("must be a boolean"));
    }

    #[test]
    fn rejects_unexpected_codex_version_output() {
        let error = parse_codex_version("codex 0.148.0 alpha.9\n").expect_err("invalid output");
        assert!(
            error
                .to_string()
                .contains("unexpected Codex version output")
        );
    }

    #[cfg(unix)]
    #[test]
    fn runtime_install_rejects_an_older_complete_package() {
        let temp = TempDir::new().expect("temp dir");
        let codex = temp.path().join("codex");
        let code_mode_host = temp.path().join(CODE_MODE_HOST_NAME);
        fs::write(&codex, "#!/bin/sh\necho 'codex-cli 0.149.1'\n").expect("codex stub");
        fs::write(&code_mode_host, "#!/bin/sh\nexit 0\n").expect("host stub");
        for path in [&codex, &code_mode_host] {
            fs::set_permissions(path, fs::Permissions::from_mode(0o755)).expect("chmod stub");
        }

        assert!(validate_codex_runtime(&codex).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn codex_settings_need_no_listener_credentials_or_claude_configuration() {
        let temp = TempDir::new().expect("temp dir");
        let codex = temp.path().join("codex");
        let code_mode_host = temp.path().join(CODE_MODE_HOST_NAME);
        fs::write(
            &codex,
            format!("#!/bin/sh\necho 'codex-cli {REQUIRED_CODEX_VERSION}'\n"),
        )
        .expect("codex stub");
        fs::write(&code_mode_host, "#!/bin/sh\nexit 0\n").expect("host stub");
        for path in [&codex, &code_mode_host] {
            fs::set_permissions(path, fs::Permissions::from_mode(0o755)).expect("chmod stub");
        }
        let env_file = temp.path().join("gateway.env");
        fs::write(
            &env_file,
            format!("RC_CODEX_GATEWAY_CODEX_PATH={}\n", codex.display()),
        )
        .expect("env file");

        let settings =
            CodexSettings::load(&ConfigSources::load(Some(&env_file)).expect("env sources"))
                .expect("codex settings");

        assert_eq!(settings.codex_version, REQUIRED_CODEX_VERSION);
        assert_eq!(settings.codex_path, codex);
    }
}
