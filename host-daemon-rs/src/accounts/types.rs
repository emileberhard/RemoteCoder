use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

use crate::providers::Provider;

pub(crate) const DEFAULT_CODEX: &str = "default-codex";
pub(crate) const DEFAULT_CLAUDE: &str = "default-claude";

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub(crate) struct AccountId(String);

impl TryFrom<String> for AccountId {
    type Error = anyhow::Error;
    fn try_from(value: String) -> Result<Self> {
        ensure!(
            value.len() == 36
                && value.bytes().enumerate().all(|(i, b)| {
                    if matches!(i, 8 | 13 | 18 | 23) {
                        b == b'-'
                    } else {
                        b.is_ascii_hexdigit()
                    }
                }),
            "Account ID must be a UUID"
        );
        Ok(Self(value.to_ascii_lowercase()))
    }
}
impl From<AccountId> for String {
    fn from(value: AccountId) -> Self {
        value.0
    }
}
impl AccountId {
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
    pub(crate) fn directory_name(&self) -> String {
        self.0.replace('-', "")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Identity {
    pub key: String,
    pub email: Option<String>,
    pub workspace: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Enrollment {
    pub id: AccountId,
    pub provider: Provider,
    pub label: String,
    pub enabled: bool,
    pub generation: u64,
    pub identity: Option<Identity>,
    #[serde(skip)]
    pub router_account_id: Option<String>,
    #[serde(default, skip_serializing)]
    pub voice_account_id: Option<AccountId>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct UsageWindow {
    pub id: String,
    pub label: String,
    pub duration_minutes: Option<i64>,
    pub used_percent: f64,
    pub resets_at: Option<f64>,
    pub model: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AccountSnapshot {
    pub id: String,
    pub provider: Provider,
    pub label: String,
    pub enabled: bool,
    pub generation: u64,
    pub is_default: bool,
    pub identity: Option<Identity>,
    pub plan: Option<String>,
    pub state: AccountState,
    pub windows: Vec<UsageWindow>,
    #[serde(default)]
    pub resets: Option<super::resets::ResetSnapshot>,
    pub observed_at: Option<f64>,
    pub stale: bool,
    pub error: Option<String>,
    pub active_turns: usize,
    #[serde(default)]
    pub incoming_call_routing_id: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum AccountState {
    Ready,
    AuthenticationRequired,
    IdentityMismatch,
    Unavailable,
    Disabled,
}

#[cfg(test)]
impl Enrollment {
    pub(crate) fn unbound(id: AccountId, label: &str) -> Self {
        Self {
            id,
            provider: Provider::Codex,
            label: label.into(),
            enabled: true,
            generation: 1,
            identity: None,
            router_account_id: None,
            voice_account_id: None,
        }
    }
}

#[cfg(test)]
impl AccountSnapshot {
    pub(crate) fn pending(entry: &Enrollment) -> Self {
        Self {
            id: entry.id.as_str().to_owned(),
            provider: entry.provider,
            label: entry.label.clone(),
            enabled: entry.enabled,
            generation: entry.generation,
            is_default: false,
            identity: entry.identity.clone(),
            plan: None,
            state: if entry.enabled {
                AccountState::Unavailable
            } else {
                AccountState::Disabled
            },
            windows: Vec::new(),
            resets: None,
            observed_at: None,
            stale: true,
            error: None,
            active_turns: 0,
            incoming_call_routing_id: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn account_ids_reject_paths_and_normalize() {
        for value in [
            "../default",
            "default",
            "/tmp/account",
            "8dc8844a-15b0-4117-9c52-f61246c8012/",
            "8dc8844a-15b0-4117-9c52-f61246c8012g",
        ] {
            assert!(AccountId::try_from(value.to_owned()).is_err());
        }
        let id = AccountId::try_from("8DC8844A-15B0-4117-9C52-F61246C8012A".to_owned()).unwrap();
        assert_eq!(id.as_str(), "8dc8844a-15b0-4117-9c52-f61246c8012a");
        assert_eq!(id.directory_name().len(), 32);
    }
}
