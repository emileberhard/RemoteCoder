mod legacy;
mod model;
#[cfg(test)]
mod tests;

use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result, ensure};
use tracing::{info, warn};

use crate::config::HostPaths;
use crate::push::PushEnvironment;
use crate::storage::private_state::{self, ReadError};
use crate::time::unix_millis;
pub(crate) use model::{
    CapacityExceeded, DeviceRegistration, NavigationStartInputs, Token, TokenKind,
};
use model::{DeviceEntry, DeviceStore};

const DEFAULT_BUNDLE_ID: &str = "emileberhard.RemoteCoder";
const MAX_STORE_BYTES: u64 = 1024 * 1024;

#[derive(Debug, Clone)]
enum Origin {
    Registered {
        device_id: String,
    },
    Legacy {
        call_device_id: Option<String>,
        token_file: Option<PathBuf>,
    },
}

#[derive(Debug, Clone)]
pub(crate) struct Destination {
    pub(crate) token: Token,
    pub(crate) environment: PushEnvironment,
    origin: Origin,
}

impl Destination {
    pub(crate) fn device_id(&self) -> Option<&str> {
        match &self.origin {
            Origin::Registered { device_id } => Some(device_id),
            Origin::Legacy { call_device_id, .. } => call_device_id.as_deref(),
        }
    }

    fn registered(entry: &DeviceEntry, kind: TokenKind) -> Option<Self> {
        Some(Self {
            token: entry.tokens.get(kind)?.clone(),
            environment: entry.apns_environment,
            origin: Origin::Registered {
                device_id: entry.device_id.clone(),
            },
        })
    }
}

#[derive(Debug, Clone)]
pub(crate) struct AlertTarget {
    pub(crate) destination: Destination,
    pub(crate) host_id: Option<String>,
    pub(crate) host_binding: &'static str,
}

#[derive(Debug, Clone)]
pub(crate) struct LocationTarget {
    pub(crate) destination: Destination,
    pub(crate) navigation: NavigationStartInputs,
}

#[derive(Debug)]
pub(crate) enum RegisterError {
    Invalid(anyhow::Error),
    Full(CapacityExceeded),
    Unavailable(anyhow::Error),
}

#[derive(Debug, Clone)]
pub(crate) struct DeviceRegistry {
    bundle_id: String,
    path: PathBuf,
    legacy: Option<Arc<legacy::Sources>>,
    #[cfg(test)]
    _directory: Option<Arc<tempfile::TempDir>>,
}

impl DeviceRegistry {
    pub(crate) fn open(paths: &HostPaths) -> Result<Self> {
        let bundle_id = std::env::var("RC_APNS_BUNDLE_ID")
            .unwrap_or_else(|_| DEFAULT_BUNDLE_ID.to_owned())
            .trim()
            .to_owned();
        ensure!(!bundle_id.is_empty(), "RC_APNS_BUNDLE_ID must not be empty");
        Ok(Self {
            legacy: Some(Arc::new(legacy::Sources::from_environment(
                paths, &bundle_id,
            ))),
            path: paths.state("devices.json"),
            bundle_id,
            #[cfg(test)]
            _directory: None,
        })
    }

    pub(crate) fn bundle_id(&self) -> &str {
        &self.bundle_id
    }

    pub(crate) async fn register(
        &self,
        registration: DeviceRegistration,
    ) -> Result<serde_json::Value, RegisterError> {
        let registration = registration
            .validated(&self.bundle_id)
            .map_err(RegisterError::Invalid)?;
        let path = self.path.clone();
        let recorded = tokio::task::spawn_blocking(move || {
            transaction(&path, |store| {
                store.upsert(registration.clone(), unix_millis())?;
                let entry = store
                    .devices
                    .iter()
                    .find(|entry| entry.device_id == registration.device_id)
                    .context("registered device is missing after upsert")?;
                Ok((entry.redacted(), true))
            })
        })
        .await
        .context("device registry worker failed")
        .map_err(RegisterError::Unavailable)?;
        recorded.map_err(|error| match error.downcast::<CapacityExceeded>() {
            Ok(full) => RegisterError::Full(full),
            Err(error) => RegisterError::Unavailable(error),
        })
    }

    pub(crate) async fn unregister(&self, device_id: &str) -> Result<bool> {
        let device_id = crate::ids::parse_uuid(device_id)
            .map(crate::ids::format_uuid)
            .context("deviceId must be a UUID")?;
        let path = self.path.clone();
        tokio::task::spawn_blocking(move || {
            transaction(&path, |store| {
                let removed = store.remove(&device_id);
                Ok((removed, removed))
            })
        })
        .await
        .context("device registry worker failed")?
    }

    pub(crate) async fn alert_targets(&self) -> Result<Vec<AlertTarget>> {
        self.resolve(
            |store| {
                store
                    .holders(TokenKind::Alert)
                    .filter_map(|entry| {
                        Some(AlertTarget {
                            destination: Destination::registered(entry, TokenKind::Alert)?,
                            host_id: Some(entry.app_host_id.clone()),
                            host_binding: "bound",
                        })
                    })
                    .collect()
            },
            legacy::Sources::alert_targets,
        )
        .await
    }

    pub(crate) async fn live_activity_destinations(&self) -> Result<Vec<Destination>> {
        self.resolve(
            |store| {
                store
                    .holders(TokenKind::LiveActivity)
                    .filter_map(|entry| Destination::registered(entry, TokenKind::LiveActivity))
                    .collect()
            },
            legacy::Sources::live_activity_destinations,
        )
        .await
    }

    pub(crate) async fn voip_destination(&self) -> Result<Option<Destination>> {
        self.resolve(
            |store| {
                store
                    .most_recent(TokenKind::Voip)
                    .and_then(|entry| Destination::registered(entry, TokenKind::Voip))
            },
            legacy::Sources::voip_destination,
        )
        .await
    }

    pub(crate) async fn location_target(&self) -> Result<Option<LocationTarget>> {
        self.resolve(
            |store| {
                let entry = store.most_recent(TokenKind::Location)?;
                Some(LocationTarget {
                    destination: Destination::registered(entry, TokenKind::Location)?,
                    navigation: entry.tokens.location.as_ref()?.navigation.clone(),
                })
            },
            legacy::Sources::location_target,
        )
        .await
    }

    pub(crate) async fn invalidate(&self, destination: &Destination, kind: TokenKind) {
        match &destination.origin {
            Origin::Registered { device_id } => {
                let path = self.path.clone();
                let (device_id, token) = (device_id.clone(), destination.token.clone());
                let outcome = tokio::task::spawn_blocking(move || {
                    transaction(&path, |store| {
                        let removed = store.invalidate(&device_id, kind, &token);
                        Ok((removed, removed))
                    })
                })
                .await;
                match outcome {
                    Ok(Ok(true)) => {
                        info!(kind = ?kind, "removed permanently invalid push token")
                    }
                    Ok(Ok(false)) => {}
                    Ok(Err(error)) => {
                        warn!(kind = ?kind, %error, "failed to remove permanently invalid push token")
                    }
                    Err(error) => {
                        warn!(kind = ?kind, %error, "device registry worker failed")
                    }
                }
            }
            Origin::Legacy {
                token_file: Some(path),
                ..
            } => {
                let (path, token) = (path.clone(), destination.token.clone());
                if let Err(error) =
                    tokio::task::spawn_blocking(move || legacy::remove_if_equal(&path, &token))
                        .await
                {
                    warn!(kind = ?kind, %error, "device registry worker failed");
                }
            }
            Origin::Legacy {
                token_file: None, ..
            } => {}
        }
    }

    async fn resolve<T: Send + 'static>(
        &self,
        registered: impl FnOnce(&DeviceStore) -> T + Send + 'static,
        legacy: impl FnOnce(&legacy::Sources) -> T + Send + 'static,
    ) -> Result<T> {
        let path = self.path.clone();
        let sources = self.legacy.clone();
        tokio::task::spawn_blocking(move || {
            Ok(match (load(&path)?, sources.as_deref()) {
                (Some(store), _) => registered(&store),
                (None, Some(sources)) => legacy(sources),
                (None, None) => registered(&DeviceStore::default()),
            })
        })
        .await
        .context("device registry worker failed")?
    }
}

#[cfg(test)]
impl DeviceRegistry {
    pub(crate) fn temporary() -> Self {
        let directory = tempfile::tempdir().expect("temporary device registry directory");
        Self {
            bundle_id: DEFAULT_BUNDLE_ID.to_owned(),
            path: directory.path().join("devices.json"),
            legacy: None,
            _directory: Some(Arc::new(directory)),
        }
    }
}

#[cfg(test)]
pub(crate) fn fixture_registration_json(seed: u8) -> serde_json::Value {
    let token = |kind: u8| format!("{kind:02x}{seed:02x}").repeat(16);
    serde_json::json!({
        "deviceId": format!("00000000-0000-4000-8000-{seed:012}"),
        "bundleId": DEFAULT_BUNDLE_ID,
        "apnsEnvironment": "development",
        "appHostId": "AAAAAAAA-0000-0000-0000-000000000001",
        "tokens": {
            "alert": token(0xa1),
            "liveActivity": token(0xa2),
            "voip": token(0xa3),
            "location": {
                "token": token(0xa4),
                "navigation": {
                    "eventBaseUrl": "https://gateway.example",
                    "setupReady": true,
                    "authorization": "authorizedAlways",
                    "fullAccuracy": true,
                    "googleTermsAccepted": true,
                },
            },
        },
    })
}

#[cfg(test)]
pub(crate) fn fixture_registration(seed: u8) -> DeviceRegistration {
    serde_json::from_value(fixture_registration_json(seed)).expect("fixture device registration")
}

fn transaction<T>(
    path: &Path,
    operation: impl FnOnce(&mut DeviceStore) -> Result<(T, bool)>,
) -> Result<T> {
    private_state::transaction(
        path,
        "device registry has no parent",
        |path| Ok(load(path)?.unwrap_or_default()),
        operation,
        private_state::write_json,
    )
}

fn load(path: &Path) -> Result<Option<DeviceStore>> {
    let Some(bytes) =
        private_state::read_bounded(path, MAX_STORE_BYTES).map_err(|error| match error {
            ReadError::Io(error) => anyhow::Error::from(error).context("reading device registry"),
            ReadError::NotRegular => anyhow::anyhow!("device registry is not a regular file"),
            ReadError::TooLargeBeforeRead | ReadError::TooLargeAfterRead => {
                anyhow::anyhow!("device registry capacity exceeded")
            }
        })?
    else {
        return Ok(None);
    };
    let store: DeviceStore =
        serde_json::from_slice(&bytes).context("invalid device registry; original preserved")?;
    store
        .validate()
        .context("invalid device registry; original preserved")?;
    Ok(Some(store))
}
