use crate::config::ConfigSources;
use anyhow::{Context, Result, ensure};
use serde_json::Value;
use std::path::PathBuf;
use std::time::Duration;

pub(crate) const ROUTER_BUDGET: Duration = Duration::from_secs(8);

#[derive(Clone, Debug)]
pub(crate) struct RouterConfig {
    url: reqwest::Url,
    accounts_url: reqwest::Url,
    key_file: PathBuf,
    codex_account: String,
}

impl RouterConfig {
    pub(crate) fn load(sources: &ConfigSources) -> Result<Option<Self>> {
        if ![
            "RC_CODEX_GATEWAY_ROUTER_URL",
            "RC_CODEX_GATEWAY_ROUTER_ACCOUNTS_URL",
            "RC_CODEX_GATEWAY_ROUTER_KEY_FILE",
            "RC_CODEX_GATEWAY_ROUTER_CODEX_ACCOUNT",
            "RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS",
        ]
        .iter()
        .any(|name| sources.raw(name).is_some())
        {
            return Ok(None);
        }
        let key_file = sources
            .optional_string("RC_CODEX_GATEWAY_ROUTER_KEY_FILE")
            .map(PathBuf::from)
            .context("Set RC_CODEX_GATEWAY_ROUTER_KEY_FILE; install the key with host-daemon-rs/scripts/install-router-key.zsh")?;
        ensure!(
            key_file.is_absolute(),
            "RC_CODEX_GATEWAY_ROUTER_KEY_FILE must be an absolute path"
        );
        let codex_account = sources
            .optional_string("RC_CODEX_GATEWAY_ROUTER_CODEX_ACCOUNT")
            .context("Set RC_CODEX_GATEWAY_ROUTER_CODEX_ACCOUNT to the llm-router Codex account for the host default")?;
        ensure!(
            codex_account.len() <= 128
                && codex_account
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-'),
            "RC_CODEX_GATEWAY_ROUTER_CODEX_ACCOUNT must be an llm-router Codex account id"
        );
        Ok(Some(Self {
            url: listener(sources, "RC_CODEX_GATEWAY_ROUTER_URL")?,
            accounts_url: listener(sources, "RC_CODEX_GATEWAY_ROUTER_ACCOUNTS_URL")?,
            key_file,
            codex_account,
        }))
    }

    #[cfg(test)]
    pub(crate) fn local_for_test(address: std::net::SocketAddr, key_file: PathBuf) -> Self {
        let url = reqwest::Url::parse(&format!("http://{address}/")).unwrap();
        Self {
            accounts_url: url.clone(),
            url,
            key_file,
            codex_account: "workspace-a".into(),
        }
    }

    #[cfg(test)]
    pub(crate) fn unreachable_for_test(key_file: PathBuf) -> Self {
        Self::local_for_test(([127, 0, 0, 1], 1).into(), key_file)
    }

    #[cfg(test)]
    pub(crate) fn key_file(&self) -> &std::path::Path {
        &self.key_file
    }

    pub(crate) fn codex_account(&self) -> &str {
        &self.codex_account
    }

    pub(crate) fn inference_base(&self) -> &str {
        self.url.as_str().trim_end_matches('/')
    }

    pub(crate) fn key(&self) -> Result<String> {
        read_key(&self.key_file).map_err(|_| RouterError::KeyUnavailable.into())
    }
}

fn listener(sources: &ConfigSources, name: &str) -> Result<reqwest::Url> {
    let raw = sources
        .optional_string(name)
        .with_context(|| format!("Set {name} to the llm-router listener URL"))?;
    let url = reqwest::Url::parse(&raw).with_context(|| format!("{name} is not a URL"))?;
    validate_origin(&url, name)?;
    let loopback = url
        .host_str()
        .is_some_and(|host| matches!(host, "127.0.0.1" | "localhost" | "[::1]"));
    if !loopback {
        let allowed = sources
            .optional_string("RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS")
            .unwrap_or_default();
        ensure!(
            allowed.len() <= 8192,
            "RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS exceeds 8192 bytes"
        );
        let origins: Vec<_> = allowed
            .split(',')
            .filter(|origin| !origin.trim().is_empty())
            .collect();
        ensure!(
            origins.len() <= 32,
            "RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS exceeds 32 origins"
        );
        let mut matched = false;
        for raw in origins {
            let origin = reqwest::Url::parse(raw.trim())
                .context("RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS contains an invalid URL")?;
            validate_origin(&origin, "RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS")?;
            matched |= origin.origin() == url.origin();
        }
        ensure!(
            matched,
            "{name} must be loopback or explicitly listed in RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS"
        );
    }
    Ok(url)
}

fn validate_origin(url: &reqwest::Url, name: &str) -> Result<()> {
    ensure!(
        matches!(url.scheme(), "http" | "https")
            && url.host_str().is_some()
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none()
            && url.path() == "/",
        "{name} must be an HTTP(S) origin without a path, credentials, query or fragment"
    );
    Ok(())
}

pub(crate) struct Router {
    config: Option<RouterConfig>,
    client: reqwest::Client,
}

#[derive(Debug)]
pub(crate) enum RouterError {
    NotConfigured,
    KeyUnavailable,
    TransportUnavailable,
    RequestFailed,
    InvalidResponse,
    Refused { status: u16, code: String },
}

impl std::fmt::Display for RouterError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotConfigured => formatter.write_str("llm-router is not configured; this feature is unavailable"),
            Self::KeyUnavailable => formatter.write_str(
                "RC_CODEX_GATEWAY_ROUTER_KEY_FILE must be one llm-router key in a regular file owned by the gateway user with mode 0600",
            ),
            Self::TransportUnavailable => formatter
                .write_str("The private llm-router listener is unavailable; check its connection"),
            Self::RequestFailed => formatter.write_str(
                "The llm-router request failed; check its connection",
            ),
            Self::InvalidResponse => formatter.write_str(
                "llm-router returned an invalid response; check gateway/router compatibility",
            ),
            Self::Refused { code, .. } if code == "unauthorized" => formatter.write_str(
                "llm-router rejected this host's key; install a current key with install-router-key.zsh",
            ),
            Self::Refused { code, .. } if code == "insufficient_scope" => formatter.write_str(
                "This host's llm-router key lacks a required scope; provision it with inference, accounts:read, accounts:prefer, accounts:redeem and codex:token",
            ),
            Self::Refused { code, .. } if code == "key_store_unavailable" => {
                formatter.write_str("llm-router cannot read its key store; check the router")
            }
            Self::Refused { status, code } => write!(
                formatter,
                "llm-router refused the request (HTTP {status}, {code})"
            ),
        }
    }
}
impl std::error::Error for RouterError {}

impl Router {
    pub(crate) fn new(config: Option<RouterConfig>) -> Result<Self> {
        Ok(Self {
            config,
            client: reqwest::Client::builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(ROUTER_BUDGET)
                .build()?,
        })
    }
    pub(crate) fn configured(&self) -> bool {
        self.config.is_some()
    }
    fn config(&self) -> Result<&RouterConfig> {
        self.config
            .as_ref()
            .ok_or_else(|| RouterError::NotConfigured.into())
    }
    pub(crate) async fn post(&self, path: &str, body: Value) -> Result<Value> {
        self.response(
            self.client
                .post(self.config()?.accounts_url.join(path)?)
                .json(&body),
        )
        .await
    }
    pub(crate) async fn redeem_reset(&self, body: Value) -> Result<Value> {
        self.response(
            self.client
                .post(self.config()?.accounts_url.join("accounts/resets/redeem")?)
                .timeout(Duration::from_secs(35))
                .json(&body),
        )
        .await
    }
    pub(crate) async fn put(&self, path: &str, body: Value) -> Result<Value> {
        self.response(
            self.client
                .put(self.config()?.accounts_url.join(path)?)
                .json(&body),
        )
        .await
    }
    pub(crate) async fn get(&self, path: &str) -> Result<Value> {
        self.response(self.client.get(self.config()?.accounts_url.join(path)?))
            .await
    }
    async fn response(&self, request: reqwest::RequestBuilder) -> Result<Value> {
        let config = self.config()?.clone();
        let key = tokio::task::spawn_blocking(move || config.key())
            .await
            .map_err(|_| RouterError::KeyUnavailable)??;
        let mut response = request.bearer_auth(key).send().await.map_err(|error| {
            if error.is_connect() || error.is_builder() {
                RouterError::TransportUnavailable
            } else {
                RouterError::RequestFailed
            }
        })?;
        let status = response.status();
        let body = async {
            if response
                .content_length()
                .is_some_and(|size| size > 64 * 1024)
            {
                return Err(RouterError::InvalidResponse);
            }
            let mut bytes = Vec::new();
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|_| RouterError::RequestFailed)?
            {
                if bytes.len() + chunk.len() > 64 * 1024 {
                    return Err(RouterError::InvalidResponse);
                }
                bytes.extend_from_slice(&chunk);
            }
            serde_json::from_slice::<Value>(&bytes).map_err(|_| RouterError::InvalidResponse)
        }
        .await;
        if !status.is_success() {
            let code = body
                .as_ref()
                .ok()
                .and_then(|value| value["error"]["code"].as_str())
                .filter(|code| {
                    !code.is_empty()
                        && code.len() <= 128
                        && code.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
                })
                .unwrap_or("router_request_refused")
                .to_owned();
            return Err(RouterError::Refused {
                status: status.as_u16(),
                code,
            }
            .into());
        }
        let value = body?;
        Ok(value)
    }
}

fn read_key(path: &std::path::Path) -> Result<String> {
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .context("llm-router key is unavailable")?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file()
            && metadata.uid() == nix::unistd::geteuid().as_raw()
            && metadata.mode() & 0o777 == 0o600
            && metadata.len() <= 4096,
        "llm-router key must be a private regular file owned by the gateway user with mode 0600"
    );
    let mut key = String::new();
    file.take(4097)
        .read_to_string(&mut key)
        .context("llm-router key is unreadable")?;
    ensure!(key.len() <= 4096, "llm-router key exceeds its limit");
    let key = key.trim();
    ensure!(
        !key.is_empty() && !key.chars().any(char::is_whitespace),
        "llm-router key is invalid"
    );
    Ok(key.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn load(url: &str, accounts: &str, key: &str, account: &str) -> Result<Option<RouterConfig>> {
        RouterConfig::load(&ConfigSources::from_file_vars(HashMap::from([
            ("RC_CODEX_GATEWAY_ROUTER_URL".into(), url.into()),
            (
                "RC_CODEX_GATEWAY_ROUTER_ACCOUNTS_URL".into(),
                accounts.into(),
            ),
            ("RC_CODEX_GATEWAY_ROUTER_KEY_FILE".into(), key.into()),
            (
                "RC_CODEX_GATEWAY_ROUTER_CODEX_ACCOUNT".into(),
                account.into(),
            ),
        ])))
    }

    #[test]
    fn configured_router_is_complete_and_validated_without_disclosing_values() {
        let loopback = "http://127.0.0.1:42069";
        let private = "http://127.0.0.1:42070";
        for (url, accounts, key, account, expected) in [
            (
                "",
                private,
                "/tmp/key",
                "workspace-a",
                "RC_CODEX_GATEWAY_ROUTER_URL",
            ),
            (
                loopback,
                "",
                "/tmp/key",
                "workspace-a",
                "RC_CODEX_GATEWAY_ROUTER_ACCOUNTS_URL",
            ),
            (
                loopback,
                private,
                "",
                "workspace-a",
                "RC_CODEX_GATEWAY_ROUTER_KEY_FILE",
            ),
            (loopback, private, "~/key", "workspace-a", "absolute path"),
            (
                "ftp://127.0.0.1",
                private,
                "/tmp/key",
                "workspace-a",
                "HTTP(S) origin",
            ),
            (
                "http://unlisted.example.com:42069",
                private,
                "/tmp/key",
                "workspace-a",
                "RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS",
            ),
            (
                "http://user:never-disclose-sentinel@127.0.0.1",
                private,
                "/tmp/key",
                "workspace-a",
                "HTTP(S) origin",
            ),
            (
                loopback,
                "http://127.0.0.1:42070/v1",
                "/tmp/key",
                "workspace-a",
                "without a path",
            ),
            (
                loopback,
                private,
                "/tmp/key",
                "",
                "RC_CODEX_GATEWAY_ROUTER_CODEX_ACCOUNT",
            ),
            (
                loopback,
                private,
                "/tmp/key",
                "never-disclose-sentinel/../x",
                "llm-router Codex account id",
            ),
        ] {
            let error = load(url, accounts, key, account).unwrap_err();
            assert!(error.to_string().contains(expected), "{error}");
            assert!(!error.to_string().contains("never-disclose-sentinel"));
        }
        let sources = ConfigSources::from_file_vars(HashMap::from([
            (
                "RC_CODEX_GATEWAY_ROUTER_URL".into(),
                "https://router.example.com:42069".into(),
            ),
            (
                "RC_CODEX_GATEWAY_ROUTER_ACCOUNTS_URL".into(),
                "https://router.example.com:42070".into(),
            ),
            (
                "RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS".into(),
                "https://router.example.com:42069,https://router.example.com:42070".into(),
            ),
            ("RC_CODEX_GATEWAY_ROUTER_KEY_FILE".into(), "/tmp/key".into()),
            (
                "RC_CODEX_GATEWAY_ROUTER_CODEX_ACCOUNT".into(),
                "workspace-a".into(),
            ),
        ]));
        let config = RouterConfig::load(&sources).unwrap().unwrap();
        assert_eq!(config.inference_base(), "https://router.example.com:42069");
        assert_eq!(config.codex_account(), "workspace-a");
        assert!(
            RouterConfig::load(&ConfigSources::from_file_vars(HashMap::new()))
                .unwrap()
                .is_none()
        );
    }
}
