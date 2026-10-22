use crate::time::parse_rfc3339_unix_seconds;
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ResetSnapshot {
    pub state: ResetState,
    pub observed_at: Option<f64>,
    pub available: Option<u64>,
    pub offers: Option<Vec<ResetOffer>>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum ResetState {
    Known,
    Unavailable,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ResetOffer {
    pub id: String,
    pub title: Option<String>,
    pub remaining: u64,
    pub expires_at: Option<f64>,
    pub usable_now: Option<bool>,
    pub requires_limit: Option<bool>,
    pub clears: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct RouterResets {
    state: ResetState,
    observed_at: Option<String>,
    available: Option<u64>,
    offers: Option<Vec<RouterOffer>>,
    error: Option<RouterResetError>,
}

#[derive(Deserialize)]
struct RouterResetError {
    code: String,
}

#[derive(Deserialize)]
struct RouterOffer {
    id: String,
    title: Option<String>,
    remaining: u64,
    expires_at: Option<String>,
    usable_now: Option<bool>,
    requires_limit: Option<bool>,
    clears: Option<Vec<String>>,
}

impl TryFrom<RouterResets> for ResetSnapshot {
    type Error = anyhow::Error;

    fn try_from(value: RouterResets) -> Result<Self> {
        match value.state {
            ResetState::Known => ensure!(value.error.is_none(), "Known resets carry an error"),
            ResetState::Unavailable => ensure!(
                value
                    .error
                    .as_ref()
                    .is_some_and(|error| !error.code.is_empty())
                    && value.available.is_none()
                    && value.offers.is_none(),
                "Unavailable resets carry allowance or lack an error"
            ),
        }
        Ok(Self {
            state: value.state,
            observed_at: value
                .observed_at
                .as_deref()
                .map(parse_rfc3339_unix_seconds)
                .transpose()?,
            available: value.available,
            offers: value
                .offers
                .map(|offers| {
                    let mut ids = std::collections::HashSet::new();
                    offers
                        .into_iter()
                        .map(|offer| {
                            ensure!(
                                !offer.id.trim().is_empty() && ids.insert(offer.id.clone()),
                                "Reset offer identity is invalid"
                            );
                            Ok(ResetOffer {
                                id: offer.id,
                                title: offer.title,
                                remaining: offer.remaining,
                                expires_at: offer
                                    .expires_at
                                    .as_deref()
                                    .map(parse_rfc3339_unix_seconds)
                                    .transpose()?,
                                usable_now: offer.usable_now,
                                requires_limit: offer.requires_limit,
                                clears: offer.clears,
                            })
                        })
                        .collect::<Result<Vec<_>>>()
                })
                .transpose()?,
            error: value.error.map(|error| error.code),
        })
    }
}

pub(crate) fn from_router(value: Option<Value>) -> Option<ResetSnapshot> {
    let value = value.filter(|value| !value.is_null())?;
    Some(
        serde_json::from_value::<RouterResets>(value)
            .map_err(anyhow::Error::from)
            .and_then(TryInto::try_into)
            .unwrap_or(ResetSnapshot {
                state: ResetState::Unavailable,
                observed_at: None,
                available: None,
                offers: None,
                error: Some("upstream_unavailable".into()),
            }),
    )
}

#[derive(Debug)]
pub(crate) struct ResetAccountNotFound;
impl std::fmt::Display for ResetAccountNotFound {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("This Codex account no longer exists; reload the account list")
    }
}
impl std::error::Error for ResetAccountNotFound {}

#[derive(Debug)]
pub(crate) struct ResetAccountChanged;
impl std::fmt::Display for ResetAccountChanged {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("This account changed; reload the account list before redeeming")
    }
}
impl std::error::Error for ResetAccountChanged {}

pub(crate) struct ResetAccount {
    pub key: String,
    pub router_account_id: String,
}

impl super::Accounts {
    pub(crate) async fn router_account_for_reset(
        &self,
        key: &str,
        generation: u64,
    ) -> Result<ResetAccount> {
        ensure!(key == super::types::DEFAULT_CODEX, ResetAccountNotFound);
        ensure!(generation == 1, ResetAccountChanged);
        Ok(ResetAccount {
            key: key.to_owned(),
            router_account_id: self
                .claude
                .router
                .as_ref()
                .ok_or(crate::providers::router::RouterError::NotConfigured)?
                .codex_account()
                .to_owned(),
        })
    }
}
