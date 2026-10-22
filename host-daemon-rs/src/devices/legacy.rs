use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value;
use tracing::{info, warn};

use super::model::{NavigationStartInputs, Token};
use super::{AlertTarget, Destination, LocationTarget, Origin};
use crate::config::HostPaths;
use crate::ids::is_session_uuid;
use crate::push::PushEnvironment;
use crate::storage::private_state;

const MAX_CALL_STORE_BYTES: u64 = 16 * 1024 * 1024;
const MAX_NAVIGATION_DEVICE_BYTES: u64 = 64 * 1024;

#[derive(Debug)]
pub(super) struct Sources {
    calls_store: PathBuf,
    navigation_device: PathBuf,
    alert_token: PathBuf,
    live_activity_token: PathBuf,
    environment: PathBuf,
    identity: PathBuf,
    default_environment: Option<PushEnvironment>,
}

impl Sources {
    pub(super) fn from_environment(paths: &HostPaths, bundle_id: &str) -> Self {
        let alert_token = token_file("RC_APNS_TOKEN_FILE", paths, "apns_device_token");
        Self {
            calls_store: paths.state("agent-calls.json"),
            navigation_device: paths.state("navigation-device.json"),
            live_activity_token: token_file(
                "RC_LIVE_ACTIVITY_TOKEN_FILE",
                paths,
                "active_tasks_live_activity_token",
            ),
            environment: alert_token.with_file_name("apns_environment"),
            identity: alert_token.with_file_name("apns_notification_identity.json"),
            alert_token,
            default_environment: default_environment(bundle_id),
        }
    }

    pub(super) fn alert_targets(&self) -> Vec<AlertTarget> {
        let (Some(token), Some(environment)) = (read_token(&self.alert_token), self.environment())
        else {
            return Vec::new();
        };
        let binding = registered_notification_host(&self.identity, &token);
        vec![AlertTarget {
            host_binding: binding.status(),
            host_id: binding.into_host_id(),
            destination: Destination {
                token,
                environment,
                origin: Origin::Legacy {
                    call_device_id: None,
                    token_file: Some(self.alert_token.clone()),
                },
            },
        }]
    }

    pub(super) fn live_activity_destinations(&self) -> Vec<Destination> {
        let (Some(token), Some(environment)) =
            (read_token(&self.live_activity_token), self.environment())
        else {
            return Vec::new();
        };
        vec![Destination {
            token,
            environment,
            origin: Origin::Legacy {
                call_device_id: None,
                token_file: Some(self.live_activity_token.clone()),
            },
        }]
    }

    pub(super) fn voip_destination(&self) -> Option<Destination> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct CallStore {
            device: Option<CallDevice>,
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct CallDevice {
            device_id: String,
            voip_token: Token,
            environment: PushEnvironment,
        }
        let store: CallStore = read_json(&self.calls_store, MAX_CALL_STORE_BYTES)?;
        let device = store.device?;
        Some(Destination {
            token: device.voip_token,
            environment: device.environment,
            origin: Origin::Legacy {
                call_device_id: Some(device.device_id),
                token_file: None,
            },
        })
    }

    pub(super) fn location_target(&self) -> Option<LocationTarget> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct NavigationDevice {
            location_push_token: Token,
            push_environment: PushEnvironment,
            event_base_url: String,
            setup_ready: bool,
            authorization: String,
            full_accuracy: bool,
            google_terms_accepted: bool,
        }
        let device: NavigationDevice =
            read_json(&self.navigation_device, MAX_NAVIGATION_DEVICE_BYTES)?;
        Some(LocationTarget {
            navigation: NavigationStartInputs {
                event_base_url: device.event_base_url,
                setup_ready: device.setup_ready,
                authorization: device.authorization,
                full_accuracy: device.full_accuracy,
                google_terms_accepted: device.google_terms_accepted,
            },
            destination: Destination {
                token: device.location_push_token,
                environment: device.push_environment,
                origin: Origin::Legacy {
                    call_device_id: None,
                    token_file: None,
                },
            },
        })
    }

    fn environment(&self) -> Option<PushEnvironment> {
        std::fs::read_to_string(&self.environment)
            .ok()
            .and_then(|value| parse_push_environment(&value))
            .or(self.default_environment)
    }
}

pub(super) fn remove_if_equal(path: &Path, attempted: &Token) {
    if read_token(path).as_ref() != Some(attempted) {
        return;
    }
    match std::fs::remove_file(path) {
        Ok(()) => info!(token_file = %path.display(), "removed permanently invalid push token"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => warn!(
            token_file = %path.display(),
            "failed to remove permanently invalid push token: {error}"
        ),
    }
}

fn token_file(variable: &str, paths: &HostPaths, default: &str) -> PathBuf {
    match std::env::var(variable)
        .ok()
        .map(|value| value.trim().to_owned())
    {
        Some(value) if !value.is_empty() => expand_tilde(PathBuf::from(value), paths.home()),
        _ => paths.state(default),
    }
}

fn default_environment(bundle_id: &str) -> Option<PushEnvironment> {
    let explicit = std::env::var("RC_PUSH_BROKER_ENV")
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());
    match explicit.as_deref() {
        Some(value) => parse_push_environment(value),
        None if bundle_id.ends_with(".dev") || bundle_id.ends_with(".exp") => {
            Some(PushEnvironment::Development)
        }
        None => Some(PushEnvironment::Production),
    }
}

fn parse_push_environment(value: &str) -> Option<PushEnvironment> {
    match value.trim().to_ascii_lowercase().as_str() {
        "development" => Some(PushEnvironment::Development),
        "production" => Some(PushEnvironment::Production),
        _ => None,
    }
}

fn read_token(path: &Path) -> Option<Token> {
    Token::try_from(std::fs::read_to_string(path).ok()?).ok()
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path, max_bytes: u64) -> Option<T> {
    let bytes = private_state::read_bounded(path, max_bytes).ok()??;
    serde_json::from_slice(&bytes).ok()
}

fn expand_tilde(path: PathBuf, home: &Path) -> PathBuf {
    if let Some(s) = path.to_str()
        && let Some(rest) = s.strip_prefix("~/")
    {
        return home.join(rest);
    }
    path
}

#[derive(Debug, PartialEq, Eq)]
enum HostBinding {
    Bound(String),
    Absent,
    Mismatch,
    Invalid,
}

impl HostBinding {
    fn status(&self) -> &'static str {
        match self {
            Self::Bound(_) => "bound",
            Self::Absent => "absent",
            Self::Mismatch => "mismatch",
            Self::Invalid => "invalid",
        }
    }

    fn into_host_id(self) -> Option<String> {
        match self {
            Self::Bound(host) => Some(host),
            Self::Absent | Self::Mismatch | Self::Invalid => None,
        }
    }
}

fn registered_notification_host(identity: &Path, token: &Token) -> HostBinding {
    let text = match std::fs::read_to_string(identity) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return HostBinding::Absent,
        Err(_) => return HostBinding::Invalid,
    };
    let Ok(registration) = serde_json::from_str::<Value>(&text) else {
        return HostBinding::Invalid;
    };
    let Some(fingerprint) = registration["tokenFingerprint"].as_str() else {
        return HostBinding::Invalid;
    };
    if fingerprint != token.fingerprint() {
        return HostBinding::Mismatch;
    }
    match registration["hostID"].as_str() {
        Some(host) if is_session_uuid(host) => HostBinding::Bound(host.into()),
        _ => HostBinding::Invalid,
    }
}

#[cfg(test)]
impl Sources {
    pub(super) fn under(directory: &Path) -> anyhow::Result<Self> {
        let paths = HostPaths::from_home(directory.to_path_buf())?;
        std::fs::create_dir_all(paths.state(""))?;
        Ok(Self {
            calls_store: paths.state("agent-calls.json"),
            navigation_device: paths.state("navigation-device.json"),
            alert_token: paths.state("apns_device_token"),
            live_activity_token: paths.state("active_tasks_live_activity_token"),
            environment: paths.state("apns_environment"),
            identity: paths.state("apns_notification_identity.json"),
            default_environment: Some(PushEnvironment::Production),
        })
    }
}
