use std::io::ErrorKind;
use std::path::Path;

use anyhow::{Context, Result, ensure};
use axum::Json;
use axum::extract::State;
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};
use serde_json::json;

use super::server::HttpState;
use super::server::auth::Authorized;

#[derive(Clone)]
pub(crate) enum RelayRoute {
    Absent,
    Unavailable,
    Published(RelayEndpoint),
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RelayEndpoint {
    proxy_host: String,
    proxy_port: u16,
    proxy_spki_sha256: String,
    target_host: String,
    target_port: u16,
    username: String,
    password: String,
}

impl RelayEndpoint {
    pub(crate) fn load(path: &Path) -> Result<Option<Self>> {
        let bytes = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error).with_context(|| format!("reading {}", path.display())),
        };
        let route: Self = serde_json::from_slice(&bytes)
            .with_context(|| format!("parsing {}", path.display()))?;
        ensure!(
            is_host(&route.proxy_host) && is_host(&route.target_host),
            "relay hosts must be DNS names or IPv4 addresses"
        );
        ensure!(
            route.proxy_port != 0 && route.target_port != 0,
            "relay ports must be between 1 and 65535"
        );
        ensure!(
            is_pin(&route.proxy_spki_sha256),
            "proxySpkiSha256 must be a base64 SHA-256 digest"
        );
        ensure!(
            !route.username.is_empty()
                && !route.username.contains(':')
                && !route.password.is_empty(),
            "the relay credential needs a username without ':' and a password"
        );
        Ok(Some(route))
    }

    pub(crate) fn target(&self) -> String {
        format!("{}:{}", self.target_host, self.target_port)
    }
}

pub(in crate::http) async fn published(State(state): State<HttpState>, _: Authorized) -> Response {
    let no_store = [(header::CACHE_CONTROL, "no-store")];
    match state.relay_route {
        RelayRoute::Published(endpoint) => (no_store, Json(endpoint)).into_response(),
        RelayRoute::Absent => (
            StatusCode::NOT_FOUND,
            no_store,
            Json(json!({"error": "no relay route"})),
        )
            .into_response(),
        RelayRoute::Unavailable => (
            StatusCode::SERVICE_UNAVAILABLE,
            no_store,
            Json(json!({"error": "relay route unavailable"})),
        )
            .into_response(),
    }
}

fn is_host(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'.')
}

fn is_pin(value: &str) -> bool {
    STANDARD
        .decode(value)
        .is_ok_and(|digest| digest.len() == 32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const PIN: &str = "8wwM/PRU7p/+58P1hcpANRXWQtrmLN9iR7Y36MPrda8=";

    fn write(contents: &serde_json::Value) -> tempfile::TempDir {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("relay.json"), contents.to_string()).unwrap();
        directory
    }

    fn file() -> serde_json::Value {
        json!({
            "proxyHost": "192.0.2.10",
            "proxyPort": 443,
            "proxySpkiSha256": PIN,
            "targetHost": "mini.relay.example.com",
            "targetPort": 20001,
            "username": "relay",
            "password": "secret",
        })
    }

    #[test]
    fn a_missing_file_publishes_no_relay() {
        let directory = tempfile::tempdir().unwrap();
        assert!(
            RelayEndpoint::load(&directory.path().join("relay.json"))
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn the_endpoint_publishes_the_file_it_validated() {
        let directory = write(&file());
        let endpoint = RelayEndpoint::load(&directory.path().join("relay.json"))
            .unwrap()
            .unwrap();
        assert_eq!(serde_json::to_value(&endpoint).unwrap(), file());
        assert_eq!(endpoint.target(), "mini.relay.example.com:20001");
    }

    #[test]
    fn invalid_files_are_rejected() {
        for (key, value) in [
            ("proxyHost", json!("relay host")),
            ("targetPort", json!(0)),
            ("proxySpkiSha256", json!("c2hvcnQ=")),
            ("username", json!("re:lay")),
            ("password", json!("")),
            ("gatewaySpkiSha256", json!(PIN)),
        ] {
            let mut contents = file();
            contents[key] = value;
            let directory = write(&contents);
            assert!(
                RelayEndpoint::load(&directory.path().join("relay.json")).is_err(),
                "{key} should be rejected"
            );
        }
    }
}
