use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use super::PushEnvironment;
use crate::devices::TokenKind;

const MAX_COLLAPSE_ID_BYTES: usize = 64;

fn route(kind: TokenKind) -> &'static str {
    match kind {
        TokenKind::Alert => "/v1/internal/alert",
        TokenKind::LiveActivity => "/v1/internal/live-activity",
        TokenKind::Location => "/v1/internal/location",
        TokenKind::Voip => "/v1/internal/voip",
    }
}

#[derive(Debug, Clone)]
pub(super) struct PushBroker {
    url: String,
    token: String,
    client: reqwest::Client,
}

impl PushBroker {
    pub(super) fn new(url: String, token: String) -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("failed building reqwest client");
        Self { url, token, client }
    }

    pub(super) fn url(&self) -> &str {
        &self.url
    }

    pub(super) async fn supports_live_activity_relevance(&self) -> bool {
        let response = self
            .client
            .get(format!("{}/healthz", self.url.trim_end_matches('/')))
            .timeout(Duration::from_secs(2))
            .send()
            .await;
        let Ok(response) = response else { return false };
        if !response.status().is_success() {
            return false;
        }
        response.json::<Value>().await.is_ok_and(|health| {
            health["capabilities"]["live_activity_relevance_score"].as_bool() == Some(true)
        })
    }

    pub(super) async fn send<TRequest>(
        &self,
        kind: TokenKind,
        request: &TRequest,
    ) -> Result<BrokerSendResponse, BrokerRequestError>
    where
        TRequest: Serialize + ?Sized,
    {
        post_broker_json(&self.client, &self.url, &self.token, route(kind), request).await
    }
}

#[derive(Debug, Serialize)]
pub(super) struct BrokerAlertRequest<'a> {
    pub(super) topic: &'a str,
    pub(super) push_environment: PushEnvironment,
    pub(super) device_token: &'a str,
    pub(super) title: &'a str,
    pub(super) body: &'a str,
    pub(super) subtitle: Option<&'a str>,
    pub(super) sound: Option<&'a str>,
    pub(super) collapse_id: Option<&'a str>,
    pub(super) mutable_content: bool,
    pub(super) custom_data: Option<Map<String, Value>>,
}

#[derive(Debug, Serialize)]
pub(super) struct BrokerLiveActivityRequest {
    pub(super) bundle_id: String,
    pub(super) push_environment: PushEnvironment,
    pub(super) device_token: String,
    pub(super) event: LiveActivityEvent,
    pub(super) timestamp: i64,
    pub(super) content_state: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) relevance_score: Option<u8>,
    pub(super) stale_date: Option<i64>,
    pub(super) dismissal_date: Option<i64>,
    pub(super) alert: Option<Value>,
}

#[derive(Debug, Serialize)]
pub(super) struct BrokerLocationRequest<'a> {
    pub(super) bundle_id: &'a str,
    pub(super) push_environment: PushEnvironment,
    pub(super) device_token: &'a str,
    pub(super) expiration: i64,
    pub(super) custom_data: &'a Map<String, Value>,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum LiveActivityEvent {
    Update,
    End,
}

#[derive(Debug, Deserialize)]
pub(super) struct BrokerSendResponse {
    pub(super) apns_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct BrokerErrorResponse {
    detail: Option<String>,
    apns_reason: Option<String>,
    apns_id: Option<String>,
}

#[derive(Debug)]
pub(crate) struct BrokerRequestError {
    pub(super) status: Option<u16>,
    pub(super) detail: Option<String>,
    pub(super) apns_reason: Option<String>,
    pub(super) apns_id: Option<String>,
}

impl BrokerRequestError {
    pub(super) fn into_failure(self) -> DeliveryFailure {
        match self.status {
            None => DeliveryFailure::Uncertain(self),
            Some(status) if status == StatusCode::OK.as_u16() => DeliveryFailure::Uncertain(self),
            Some(_) => DeliveryFailure::Rejected(self),
        }
    }
}

#[derive(Debug)]
pub(crate) struct Delivered {
    pub(crate) apns_id: Option<String>,
}

#[derive(Debug)]
pub(crate) enum DeliveryFailure {
    BrokerUnavailable(&'static str),
    NoDestination,
    Rejected(BrokerRequestError),
    Uncertain(BrokerRequestError),
}

pub(crate) type DeliveryOutcome = Result<Delivered, DeliveryFailure>;

impl std::fmt::Display for DeliveryFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BrokerUnavailable(reason) => {
                write!(formatter, "push notifications are unavailable ({reason})")
            }
            Self::NoDestination => formatter.write_str(
                "no device is registered for notifications yet; enable them in RemoteCoder's settings",
            ),
            Self::Rejected(error) => formatter.write_str(
                error
                    .apns_reason
                    .as_deref()
                    .or(error.detail.as_deref())
                    .unwrap_or("the push broker rejected it"),
            ),
            Self::Uncertain(error) => write!(
                formatter,
                "delivery uncertain ({})",
                error.detail.as_deref().unwrap_or("no answer from the push broker")
            ),
        }
    }
}

impl std::error::Error for DeliveryFailure {}

pub(super) fn apns_collapse_id(key: &str) -> String {
    if key.len() <= MAX_COLLAPSE_ID_BYTES {
        return key.to_owned();
    }
    format!(
        "sha256:{}",
        URL_SAFE_NO_PAD.encode(Sha256::digest(key.as_bytes()))
    )
}

async fn post_broker_json<TRequest, TResponse>(
    client: &reqwest::Client,
    base_url: &str,
    token: &str,
    path: &str,
    request: &TRequest,
) -> Result<TResponse, BrokerRequestError>
where
    TRequest: Serialize + ?Sized,
    TResponse: for<'de> Deserialize<'de>,
{
    let url = format!("{}{}", base_url.trim_end_matches('/'), path);
    let response = client
        .post(url)
        .bearer_auth(token)
        .json(request)
        .send()
        .await
        .map_err(|error| BrokerRequestError {
            status: None,
            detail: Some(error.to_string()),
            apns_reason: None,
            apns_id: None,
        })?;

    let status = response.status();
    if status.is_success() {
        return response
            .json::<TResponse>()
            .await
            .map_err(|error| BrokerRequestError {
                status: Some(StatusCode::OK.as_u16()),
                detail: Some(error.to_string()),
                apns_reason: None,
                apns_id: None,
            });
    }

    let error_body =
        response
            .json::<BrokerErrorResponse>()
            .await
            .ok()
            .unwrap_or(BrokerErrorResponse {
                detail: None,
                apns_reason: None,
                apns_id: None,
            });

    Err(BrokerRequestError {
        status: Some(status.as_u16()),
        detail: error_body.detail,
        apns_reason: error_body.apns_reason,
        apns_id: error_body.apns_id,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collapse_ids_fit_apns_and_stay_distinct() {
        let short = "question:thread-1:item-1";
        assert_eq!(apns_collapse_id(short), short);

        let scoped =
            "7b32688f-fff8-488d-a9d5-d7d1e6a105dc:claude_2f0c8e4e-8d5c-4a57-9b0e-5c1f3b6a9d21";
        let question =
            "question:claude_2f0c8e4e-8d5c-4a57-9b0e-5c1f3b6a9d21:toolu_01XyZabcdEFGhijkLMNopqrs";
        for key in [scoped, question] {
            assert!(key.len() > MAX_COLLAPSE_ID_BYTES);
            let id = apns_collapse_id(key);
            assert!(id.len() <= MAX_COLLAPSE_ID_BYTES, "{id}");
            assert_eq!(apns_collapse_id(key), id);
        }
        assert_ne!(apns_collapse_id(scoped), apns_collapse_id(question));
    }
}
