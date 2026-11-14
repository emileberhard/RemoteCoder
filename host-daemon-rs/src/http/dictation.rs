use std::path::PathBuf;

use anyhow::{Context, Result, ensure};
use axum::Json;
use axum::extract::State;
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde_json::json;

use crate::config::ConfigSources;
use crate::providers::router::{RouterConfig, read_key};

use super::server::HttpState;
use super::server::auth::{AuthorizationFailure, Authorized};

#[derive(Clone, Debug)]
pub(crate) struct DictationAccess {
    origin: reqwest::Url,
    key_file: PathBuf,
    gateway_key_file: Option<PathBuf>,
}

impl DictationAccess {
    pub(crate) fn load(
        sources: &ConfigSources,
        router: Option<&RouterConfig>,
    ) -> Result<Option<Self>> {
        let origin = sources.optional_string("RC_CODEX_GATEWAY_DICTATION_ORIGIN");
        let key_file = sources.optional_string("RC_CODEX_GATEWAY_DICTATION_KEY_FILE");
        if origin.is_none() && key_file.is_none() {
            return Ok(None);
        }
        let origin = reqwest::Url::parse(&origin.context("Set RC_CODEX_GATEWAY_DICTATION_ORIGIN")?)
            .context("RC_CODEX_GATEWAY_DICTATION_ORIGIN is not a URL")?;
        crate::providers::router::validate_origin(&origin, "RC_CODEX_GATEWAY_DICTATION_ORIGIN")?;
        let key_file = PathBuf::from(key_file.context("Set RC_CODEX_GATEWAY_DICTATION_KEY_FILE")?);
        ensure!(
            key_file.is_absolute(),
            "RC_CODEX_GATEWAY_DICTATION_KEY_FILE must be absolute"
        );
        let gateway_key_file = router.map(|router| router.key_file().to_owned());
        ensure!(
            gateway_key_file.as_ref() != Some(&key_file),
            "Dictation must use its own dictation-only key file"
        );
        Ok(Some(Self {
            origin,
            key_file,
            gateway_key_file,
        }))
    }

    fn credential(&self) -> Result<serde_json::Value> {
        let key = read_key(&self.key_file)?;
        if let file = &self.gateway_key_file {
            ensure!(
                key != read_key(file)?,
                "Dictation must not publish the gateway router key"
            );
        }
        Ok(json!({"origin": self.origin.as_str().trim_end_matches('/'), "key": key}))
    }
}

pub(in crate::http) async fn published(
    State(state): State<HttpState>,
    authorized: Result<Authorized, AuthorizationFailure>,
) -> Response {
    let mut response = match authorized {
        Err(error) => error.into_response(),
        Ok(_) => match state.dictation_access {
            None => (
                StatusCode::NOT_FOUND,
                Json(json!({"error": "dictation access is not configured"})),
            )
                .into_response(),
            Some(access) => match tokio::task::spawn_blocking(move || access.credential()).await {
                Ok(Ok(credential)) => Json(credential).into_response(),
                _ => (
                    StatusCode::SERVICE_UNAVAILABLE,
                    Json(json!({"error": "dictation credential unavailable"})),
                )
                    .into_response(),
            },
        },
    };
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        header::HeaderValue::from_static("no-store"),
    );
    response
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn dictation_configuration_requires_an_origin_and_a_separate_absolute_key_file() {
        for (origin, key, valid) in [
            (None, None, true),
            (
                Some("https://dictation.example"),
                Some("/private/dictation.key"),
                true,
            ),
            (
                Some("https://dictation.example/path"),
                Some("/private/dictation.key"),
                false,
            ),
            (
                Some("https://user:secret@dictation.example"),
                Some("/private/dictation.key"),
                false,
            ),
            (Some("https://dictation.example"), None, false),
            (None, Some("/private/dictation.key"), false),
            (
                Some("https://dictation.example"),
                Some("relative.key"),
                false,
            ),
            (
                Some("https://dictation.example"),
                Some("/private/gateway.key"),
                false,
            ),
        ] {
            let mut values = HashMap::new();
            if let origin = origin {
                values.insert("RC_CODEX_GATEWAY_DICTATION_ORIGIN".into(), origin.into());
            }
            if let key = key {
                values.insert("RC_CODEX_GATEWAY_DICTATION_KEY_FILE".into(), key.into());
            }
            let sources = ConfigSources::from_file_vars(values);
            let router = RouterConfig::unreachable_for_test("/private/gateway.key".into());
            assert_eq!(
                DictationAccess::load(&sources, Some(&router)).is_ok(),
                valid
            );
        }
    }
}
