use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use crate::ids::{format_uuid, is_session_uuid, parse_uuid};
use crate::push::PushEnvironment;

pub(super) const MAX_DEVICES: usize = 32;
const STORE_VERSION: u8 = 1;
const MIN_TOKEN_CHARS: usize = 32;
const MAX_TOKEN_CHARS: usize = 256;
const MAX_AUTHORIZATION_BYTES: usize = 512;
const MAX_EVENT_BASE_URL_BYTES: usize = 2048;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TokenKind {
    Alert,
    LiveActivity,
    Location,
    Voip,
}

const TOKEN_KINDS: [TokenKind; 4] = [
    TokenKind::Alert,
    TokenKind::LiveActivity,
    TokenKind::Location,
    TokenKind::Voip,
];

impl TokenKind {
    fn name(self) -> &'static str {
        match self {
            Self::Alert => "alert",
            Self::LiveActivity => "liveActivity",
            Self::Location => "location",
            Self::Voip => "voip",
        }
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub(crate) struct Token(String);

impl Token {
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }

    pub(crate) fn fingerprint(&self) -> String {
        Sha256::digest(self.0.as_bytes())[..8]
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }
}

impl TryFrom<String> for Token {
    type Error = anyhow::Error;

    fn try_from(value: String) -> Result<Self> {
        let value = value.trim().to_ascii_lowercase();
        ensure!(
            (MIN_TOKEN_CHARS..=MAX_TOKEN_CHARS).contains(&value.len())
                && value.bytes().all(|byte| byte.is_ascii_hexdigit()),
            "a device token must be {MIN_TOKEN_CHARS} to {MAX_TOKEN_CHARS} hexadecimal characters"
        );
        Ok(Self(value))
    }
}

impl From<Token> for String {
    fn from(token: Token) -> Self {
        token.0
    }
}

impl std::fmt::Debug for Token {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "Token({})", self.fingerprint())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct NavigationStartInputs {
    pub(crate) event_base_url: String,
    pub(crate) setup_ready: bool,
    pub(crate) authorization: String,
    pub(crate) full_accuracy: bool,
    pub(crate) google_terms_accepted: bool,
}

impl NavigationStartInputs {
    pub(crate) fn validate(&self) -> Result<()> {
        self.normalized_event_base_url()?;
        ensure!(
            !self.authorization.trim().is_empty(),
            "authorization diagnostic must not be empty"
        );
        ensure!(
            self.authorization.len() <= MAX_AUTHORIZATION_BYTES,
            "authorization diagnostic must be at most {MAX_AUTHORIZATION_BYTES} bytes"
        );
        Ok(())
    }

    pub(crate) fn normalized_event_base_url(&self) -> Result<String> {
        let base = self.event_base_url.trim();
        ensure!(
            base.len() <= MAX_EVENT_BASE_URL_BYTES,
            "eventBaseURL must be at most {MAX_EVENT_BASE_URL_BYTES} bytes"
        );
        let url = reqwest::Url::parse(base).context("eventBaseURL must be a valid URL")?;
        if !matches!(url.scheme(), "http" | "https")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            bail!(
                "eventBaseURL must be an http or https URL with a host and no credentials, query or fragment"
            );
        }
        Ok(url.as_str().trim_end_matches('/').to_string())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct LocationRegistration {
    pub(crate) token: Token,
    pub(crate) navigation: NavigationStartInputs,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DeviceTokens {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) alert: Option<Token>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) live_activity: Option<Token>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) voip: Option<Token>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) location: Option<LocationRegistration>,
}

impl DeviceTokens {
    pub(super) fn get(&self, kind: TokenKind) -> Option<&Token> {
        match kind {
            TokenKind::Alert => self.alert.as_ref(),
            TokenKind::LiveActivity => self.live_activity.as_ref(),
            TokenKind::Voip => self.voip.as_ref(),
            TokenKind::Location => self.location.as_ref().map(|location| &location.token),
        }
    }

    pub(super) fn clear(&mut self, kind: TokenKind) {
        match kind {
            TokenKind::Alert => self.alert = None,
            TokenKind::LiveActivity => self.live_activity = None,
            TokenKind::Voip => self.voip = None,
            TokenKind::Location => self.location = None,
        }
    }

    pub(super) fn is_empty(&self) -> bool {
        TOKEN_KINDS.iter().all(|kind| self.get(*kind).is_none())
    }

    fn release(&mut self, token: &Token) {
        for kind in TOKEN_KINDS {
            if self.get(kind) == Some(token) {
                self.clear(kind);
            }
        }
    }

    fn fingerprints(&self) -> Map<String, Value> {
        TOKEN_KINDS
            .iter()
            .filter_map(|kind| {
                let token = self.get(*kind)?;
                Some((kind.name().to_owned(), Value::from(token.fingerprint())))
            })
            .collect()
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DeviceRegistration {
    pub(super) device_id: String,
    pub(super) bundle_id: String,
    pub(super) apns_environment: PushEnvironment,
    pub(super) app_host_id: String,
    pub(super) tokens: DeviceTokens,
}

impl DeviceRegistration {
    pub(super) fn validated(mut self, bundle_id: &str) -> Result<Self> {
        ensure!(self.bundle_id == bundle_id, "unsupported bundleId");
        self.device_id = parse_uuid(&self.device_id)
            .map(format_uuid)
            .context("deviceId must be a UUID")?;
        ensure!(
            is_session_uuid(&self.app_host_id),
            "appHostId must be a UUID"
        );
        ensure!(
            !self.tokens.is_empty(),
            "at least one token is required; unregister the device instead"
        );
        if let Some(location) = &self.tokens.location {
            location.navigation.validate()?;
        }
        Ok(self)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct DeviceEntry {
    pub(super) device_id: String,
    pub(super) app_host_id: String,
    pub(super) apns_environment: PushEnvironment,
    pub(super) tokens: DeviceTokens,
    pub(super) updated_at_unix_millis: i64,
}

impl DeviceEntry {
    pub(super) fn redacted(&self) -> Value {
        serde_json::json!({
            "deviceId": self.device_id,
            "appHostId": self.app_host_id,
            "apnsEnvironment": self.apns_environment.as_str(),
            "tokens": self.tokens.fingerprints(),
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct DeviceStore {
    version: u8,
    pub(super) devices: Vec<DeviceEntry>,
}

impl Default for DeviceStore {
    fn default() -> Self {
        Self {
            version: STORE_VERSION,
            devices: Vec::new(),
        }
    }
}

impl DeviceStore {
    pub(super) fn validate(&self) -> Result<()> {
        ensure!(
            self.version == STORE_VERSION,
            "unsupported device registry version"
        );
        ensure!(
            self.devices.len() <= MAX_DEVICES,
            "device registry capacity exceeded"
        );
        for (index, entry) in self.devices.iter().enumerate() {
            ensure!(
                !self.devices[..index]
                    .iter()
                    .any(|earlier| earlier.device_id == entry.device_id),
                "device registry has a duplicate deviceId"
            );
        }
        Ok(())
    }

    pub(super) fn upsert(
        &mut self,
        registration: DeviceRegistration,
        now_millis: i64,
    ) -> Result<()> {
        let DeviceRegistration {
            device_id,
            apns_environment,
            app_host_id,
            tokens,
            ..
        } = registration;
        for kind in TOKEN_KINDS {
            if let Some(token) = tokens.get(kind) {
                for entry in self
                    .devices
                    .iter_mut()
                    .filter(|entry| entry.device_id != device_id)
                {
                    entry.tokens.release(token);
                }
            }
        }
        self.devices.retain(|entry| !entry.tokens.is_empty());
        let known = self
            .devices
            .iter()
            .any(|entry| entry.device_id == device_id);
        ensure!(known || self.devices.len() < MAX_DEVICES, CapacityExceeded);
        let updated_at_unix_millis = self
            .devices
            .iter()
            .map(|entry| entry.updated_at_unix_millis.saturating_add(1))
            .fold(now_millis, i64::max);
        let entry = DeviceEntry {
            device_id,
            app_host_id,
            apns_environment,
            tokens,
            updated_at_unix_millis,
        };
        match self
            .devices
            .iter_mut()
            .find(|existing| existing.device_id == entry.device_id)
        {
            Some(existing) => *existing = entry,
            None => self.devices.push(entry),
        }
        Ok(())
    }

    pub(super) fn remove(&mut self, device_id: &str) -> bool {
        let before = self.devices.len();
        self.devices.retain(|entry| entry.device_id != device_id);
        self.devices.len() != before
    }

    pub(super) fn invalidate(&mut self, device_id: &str, kind: TokenKind, token: &Token) -> bool {
        let Some(entry) = self
            .devices
            .iter_mut()
            .find(|entry| entry.device_id == device_id && entry.tokens.get(kind) == Some(token))
        else {
            return false;
        };
        entry.tokens.clear(kind);
        self.devices.retain(|entry| !entry.tokens.is_empty());
        true
    }

    pub(super) fn holders(&self, kind: TokenKind) -> impl Iterator<Item = &DeviceEntry> {
        self.devices
            .iter()
            .filter(move |entry| entry.tokens.get(kind).is_some())
    }

    pub(super) fn most_recent(&self, kind: TokenKind) -> Option<&DeviceEntry> {
        self.holders(kind)
            .max_by_key(|entry| entry.updated_at_unix_millis)
    }
}

#[derive(Debug)]
pub(crate) struct CapacityExceeded;

impl std::fmt::Display for CapacityExceeded {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "the device registry holds its {MAX_DEVICES} devices; unregister one first"
        )
    }
}

impl std::error::Error for CapacityExceeded {}
