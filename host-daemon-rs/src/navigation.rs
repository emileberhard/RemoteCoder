use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chacha20poly1305::aead::Aead;
use chacha20poly1305::{ChaCha20Poly1305, KeyInit, Nonce};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use tokio::sync::{Mutex, Notify};
use x25519_dalek::{PublicKey, StaticSecret};

use crate::devices::{NavigationStartInputs, Token};
use crate::ids::random_identifier;
use crate::observability::journal::Journal;
use crate::push::{PushEnvironment, PushService};
use crate::time::unix_seconds;

const SCHEMA_VERSION: u8 = 1;
const SESSION_LIFETIME_SECONDS: i64 = 6 * 60 * 60;
const MAX_EVENTS_PER_SESSION: usize = 512;
const MAX_EVENT_BYTES_PER_SESSION: usize = 512 * 1024;
const MAX_SESSIONS: usize = 16;
const MAX_IDENTIFIER_BYTES: usize = 128;
const MAX_TEXT_BYTES: usize = 512;
const MAX_PUBLIC_KEY_BYTES: usize = 64;
const MAX_SEALED_PAYLOAD_BYTES: usize = 96 * 1024;
const KEY_DERIVATION_INFO: &[u8] = b"RemoteCoderLiveNavigation/v1";

#[derive(Debug)]
pub(crate) struct InvalidNavigationUploadToken;

impl std::fmt::Display for InvalidNavigationUploadToken {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("invalid navigation upload token")
    }
}

impl std::error::Error for InvalidNavigationUploadToken {}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NavigationDestination {
    pub latitude: f64,
    pub longitude: f64,
    pub title: String,
    pub place_id: Option<String>,
}

impl NavigationDestination {
    fn validate(&self) -> Result<()> {
        if !self.latitude.is_finite() || !(-90.0..=90.0).contains(&self.latitude) {
            bail!("destination latitude must be between -90 and 90");
        }
        if !self.longitude.is_finite() || !(-180.0..=180.0).contains(&self.longitude) {
            bail!("destination longitude must be between -180 and 180");
        }
        if self.title.trim().is_empty() {
            bail!("destination title must not be empty");
        }
        if self.title.len() > MAX_TEXT_BYTES
            || self
                .place_id
                .as_ref()
                .is_some_and(|place_id| place_id.len() > MAX_TEXT_BYTES)
        {
            bail!("destination title and placeId must be at most {MAX_TEXT_BYTES} bytes");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum NavigationTravelMode {
    Driving,
    Cycling,
    Walking,
    Taxi,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NavigationProfile {
    pub mode: NavigationTravelMode,
    #[serde(default)]
    pub avoid_highways: bool,
    #[serde(default)]
    pub avoid_tolls: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RegisterNavigationDeviceParams {
    pub location_push_token: String,
    pub push_environment: PushEnvironment,
    pub event_base_url: String,
    pub setup_ready: bool,
    pub authorization: String,
    pub full_accuracy: bool,
    pub google_terms_accepted: bool,
}

impl RegisterNavigationDeviceParams {
    fn validate(&self) -> Result<()> {
        Token::try_from(self.location_push_token.clone())?;
        self.start_inputs().validate()
    }

    fn start_inputs(&self) -> NavigationStartInputs {
        NavigationStartInputs {
            event_base_url: self.event_base_url.clone(),
            setup_ready: self.setup_ready,
            authorization: self.authorization.clone(),
            full_accuracy: self.full_accuracy,
            google_terms_accepted: self.google_terms_accepted,
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct NavigationDeviceRegistration {
    location_push_token: String,
    push_environment: PushEnvironment,
    event_base_url: String,
    setup_ready: bool,
    authorization: String,
    full_accuracy: bool,
    google_terms_accepted: bool,
    registered_at_unix_seconds: f64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct StartNavigationParams {
    pub destination: Option<NavigationDestination>,
    pub profile: NavigationProfile,
    #[serde(default)]
    pub single_fix: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum NavigationSessionState {
    Starting,
    Active,
    StopRequested,
    Expired,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StartNavigationResponse {
    pub session_id: String,
    pub state: NavigationSessionState,
    pub expires_at_unix_seconds: i64,
    pub apns_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct NavigationSessionParams {
    pub session_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct NextNavigationEventParams {
    pub session_id: String,
    #[serde(default)]
    pub after_sequence: u64,
    #[serde(default = "default_next_timeout_seconds")]
    pub timeout_seconds: u64,
}

fn default_next_timeout_seconds() -> u64 {
    20
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct EncryptedNavigationEventRequest {
    pub session_id: String,
    pub sequence: u64,
    pub ephemeral_public_key: String,
    pub sealed_payload: String,
}

impl EncryptedNavigationEventRequest {
    fn validate_sizes(&self) -> Result<()> {
        if self.session_id.len() > MAX_IDENTIFIER_BYTES
            || self.ephemeral_public_key.len() > MAX_PUBLIC_KEY_BYTES
            || self.sealed_payload.len() > MAX_SEALED_PAYLOAD_BYTES
        {
            bail!("navigation event exceeds its size limits");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NavigationIngestResponse {
    pub accepted_sequence: u64,
    pub command: Option<NavigationCommand>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub(crate) enum NavigationCommand {
    Stop,
}

struct NavigationSession {
    id: String,
    destination: Option<NavigationDestination>,
    profile: NavigationProfile,
    created_at_unix_seconds: f64,
    expires_at_unix_seconds: i64,
    upload_token_hash: [u8; 32],
    decryption_key: StaticSecret,
    events: VecDeque<StoredEvent>,
    event_bytes: usize,
    dropped_through_sequence: u64,
    latest_sequence: u64,
    single_fix: bool,
    stop_requested: bool,
}

struct StoredEvent {
    sequence: u64,
    bytes: usize,
    value: Value,
}

impl NavigationSession {
    fn is_expired(&self, now: i64) -> bool {
        now > self.expires_at_unix_seconds
    }

    fn state(&self, now: i64) -> NavigationSessionState {
        if self.is_expired(now) {
            NavigationSessionState::Expired
        } else if self.stop_requested {
            NavigationSessionState::StopRequested
        } else if self.latest_sequence == 0 {
            NavigationSessionState::Starting
        } else {
            NavigationSessionState::Active
        }
    }
}

#[derive(Default)]
struct NavigationSessions {
    by_id: HashMap<String, NavigationSession>,
}

impl NavigationSessions {
    fn latest_id(&self) -> Option<&str> {
        self.by_id
            .values()
            .max_by(|left, right| {
                left.created_at_unix_seconds
                    .total_cmp(&right.created_at_unix_seconds)
            })
            .map(|session| session.id.as_str())
    }

    fn admit(&mut self, session: NavigationSession, now: i64) -> Result<()> {
        self.by_id.retain(|_, retained| !retained.is_expired(now));
        if self.by_id.len() >= MAX_SESSIONS {
            let evictable = self
                .by_id
                .values()
                .filter(|retained| retained.stop_requested)
                .min_by(|left, right| {
                    left.created_at_unix_seconds
                        .total_cmp(&right.created_at_unix_seconds)
                })
                .map(|retained| retained.id.clone());
            match evictable {
                Some(id) => {
                    self.by_id.remove(&id);
                }
                None => bail!("navigation is at its {MAX_SESSIONS} live session limit"),
            }
        }
        self.by_id.insert(session.id.clone(), session);
        Ok(())
    }
}

pub(crate) struct NavigationManager {
    apns: Arc<PushService>,
    journal: Journal,
    device_path: Option<PathBuf>,
    sessions: Mutex<NavigationSessions>,
    changed: Notify,
}

impl NavigationManager {
    pub fn new(apns: Arc<PushService>, journal: Journal, device_path: Option<PathBuf>) -> Self {
        Self {
            apns,
            journal,
            device_path,
            sessions: Mutex::new(NavigationSessions::default()),
            changed: Notify::new(),
        }
    }

    pub(crate) async fn register_device(
        &self,
        params: RegisterNavigationDeviceParams,
    ) -> Result<Value> {
        params.validate()?;
        let registration = NavigationDeviceRegistration {
            location_push_token: params.location_push_token.trim().to_ascii_lowercase(),
            push_environment: params.push_environment,
            event_base_url: params.start_inputs().normalized_event_base_url()?,
            setup_ready: params.setup_ready,
            authorization: params.authorization,
            full_accuracy: params.full_accuracy,
            google_terms_accepted: params.google_terms_accepted,
            registered_at_unix_seconds: unix_seconds(),
        };
        self.persist_device(&registration).await?;
        self.journal.push(
            "navigation",
            json!({
                "event": "deviceRegistered",
                "environment": registration.push_environment.as_str(),
                "setupReady": registration.setup_ready,
                "authorization": registration.authorization,
                "fullAccuracy": registration.full_accuracy,
                "googleTermsAccepted": registration.google_terms_accepted,
            }),
        );
        Ok(json!({
            "registered": true,
            "setupReady": registration.setup_ready,
            "registeredAtUnixSeconds": registration.registered_at_unix_seconds,
        }))
    }

    async fn persist_device(&self, registration: &NavigationDeviceRegistration) -> Result<()> {
        let Some(path) = self.device_path.as_ref() else {
            return Ok(());
        };
        let parent = path
            .parent()
            .context("navigation device path has no parent")?;
        tokio::fs::create_dir_all(parent).await?;
        let bytes = serde_json::to_vec_pretty(registration)?;
        let temporary = path.with_extension("json.tmp");
        tokio::fs::write(&temporary, bytes).await?;
        tokio::fs::rename(&temporary, path).await?;
        Ok(())
    }

    pub(crate) async fn start(
        &self,
        params: StartNavigationParams,
    ) -> Result<StartNavigationResponse> {
        if let Some(destination) = params.destination.as_ref() {
            if params.single_fix {
                bail!("a single fix takes no destination");
            }
            destination.validate()?;
        }
        let target = self
            .apns
            .devices()
            .location_target()
            .await
            .context("reading the device registry")?
            .context(
                "no iPhone has registered for live location: open RemoteCoder on the iPhone, \
                 and if this persists run Settings → Location → Prepare live location there",
            )?;
        let inputs = &target.navigation;
        if !inputs.setup_ready || !inputs.full_accuracy || !inputs.google_terms_accepted {
            bail!(
                "iPhone live-location setup is incomplete (location access={}, precise={}, \
                 Google terms accepted={}): run Settings → Location → Prepare live location in \
                 RemoteCoder on the iPhone and allow Always and Precise",
                inputs.authorization,
                inputs.full_accuracy,
                inputs.google_terms_accepted
            );
        }

        let session_id = random_identifier(16);
        let upload_token = random_identifier(32);
        let upload_token_hash = Sha256::digest(upload_token.as_bytes()).into();
        let decryption_key = StaticSecret::random();
        let server_public_key = PublicKey::from(&decryption_key);
        let now = unix_seconds();
        let expires_at_unix_seconds = now as i64 + SESSION_LIFETIME_SECONDS;
        let event_upload_url = format!("{}/navigation/events", inputs.normalized_event_base_url()?);
        let command = json!({
            "schemaVersion": SCHEMA_VERSION,
            "sessionId": session_id,
            "destination": params.destination,
            "profile": params.profile,
            "eventUploadURL": event_upload_url,
            "uploadToken": upload_token,
            "serverPublicKey": URL_SAFE_NO_PAD.encode(server_public_key.as_bytes()),
            "expiresAtUnixSeconds": expires_at_unix_seconds,
            "singleFix": params.single_fix,
        });
        let custom_data = command
            .as_object()
            .cloned()
            .context("navigation command must be an object")?;

        self.sessions.lock().await.admit(
            NavigationSession {
                id: session_id.clone(),
                destination: params.destination,
                profile: params.profile,
                created_at_unix_seconds: now,
                expires_at_unix_seconds,
                upload_token_hash,
                decryption_key,
                events: VecDeque::new(),
                event_bytes: 0,
                dropped_through_sequence: 0,
                latest_sequence: 0,
                single_fix: params.single_fix,
                stop_requested: false,
            },
            now as i64,
        )?;

        let apns = self
            .apns
            .send_location_push(&target.destination, expires_at_unix_seconds, &custom_data)
            .await;
        let (apns_id, state) = match apns {
            Ok(delivered) => (delivered.apns_id, NavigationSessionState::Starting),
            Err(error) => {
                let mut sessions = self.sessions.lock().await;
                let observed = sessions
                    .by_id
                    .get(&session_id)
                    .is_some_and(|session| session.latest_sequence > 0);
                if !observed {
                    sessions.by_id.remove(&session_id);
                    return Err(anyhow!(error));
                }
                drop(sessions);
                self.journal.push(
                    "navigation",
                    json!({
                        "event": "sendFailedAfterObservation",
                        "sessionId": session_id,
                        "error": error.to_string(),
                    }),
                );
                (None, NavigationSessionState::Active)
            }
        };
        self.journal.push(
            "navigation",
            json!({
                "event": "sessionStarted",
                "sessionId": session_id,
                "expiresAtUnixSeconds": expires_at_unix_seconds,
                "apnsId": apns_id,
            }),
        );
        Ok(StartNavigationResponse {
            session_id,
            state,
            expires_at_unix_seconds,
            apns_id,
        })
    }

    pub(crate) async fn status(&self, requested_id: Option<String>) -> Result<Value> {
        let sessions = self.sessions.lock().await;
        let id = requested_id
            .as_deref()
            .or_else(|| sessions.latest_id())
            .context("no navigation session exists")?;
        let session = sessions
            .by_id
            .get(id)
            .with_context(|| format!("unknown navigation session {id}"))?;
        Ok(session_status(session, unix_seconds() as i64))
    }

    pub(crate) async fn stop(&self, session_id: String) -> Result<Value> {
        let mut sessions = self.sessions.lock().await;
        let session = sessions
            .by_id
            .get_mut(&session_id)
            .with_context(|| format!("unknown navigation session {session_id}"))?;
        session.stop_requested = true;
        self.changed.notify_waiters();
        self.journal.push(
            "navigation",
            json!({ "event": "stopRequested", "sessionId": session_id }),
        );
        Ok(json!({ "sessionId": session_id, "state": "stopRequested" }))
    }

    pub(crate) async fn next_event(&self, params: NextNavigationEventParams) -> Result<Value> {
        let timeout = Duration::from_secs(params.timeout_seconds.clamp(1, 60));
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let notified = self.changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            {
                let sessions = self.sessions.lock().await;
                let session = sessions
                    .by_id
                    .get(&params.session_id)
                    .with_context(|| format!("unknown navigation session {}", params.session_id))?;
                if let Some(event) = session
                    .events
                    .iter()
                    .find(|event| event.sequence > params.after_sequence)
                {
                    return Ok(json!({
                        "event": event.value,
                        "droppedThroughSequence": (session.dropped_through_sequence
                            > params.after_sequence)
                            .then_some(session.dropped_through_sequence),
                    }));
                }
                match session.state(unix_seconds() as i64) {
                    NavigationSessionState::StopRequested => {
                        return Ok(json!({ "event": Value::Null, "state": "stopRequested" }));
                    }
                    NavigationSessionState::Expired => {
                        return Ok(json!({ "event": Value::Null, "state": "expired" }));
                    }
                    NavigationSessionState::Starting | NavigationSessionState::Active => {}
                }
            }
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                return Ok(json!({ "event": Value::Null, "state": "waiting" }));
            }
        }
    }

    pub(crate) async fn ingest(
        &self,
        bearer_token: &str,
        request: EncryptedNavigationEventRequest,
    ) -> Result<NavigationIngestResponse> {
        request.validate_sizes()?;
        let (decryption_key, expected_token_hash, expires_at, latest_sequence, stop_requested) = {
            let sessions = self.sessions.lock().await;
            let session = sessions
                .by_id
                .get(&request.session_id)
                .with_context(|| format!("unknown navigation session {}", request.session_id))?;
            (
                session.decryption_key.clone(),
                session.upload_token_hash,
                session.expires_at_unix_seconds,
                session.latest_sequence,
                session.stop_requested,
            )
        };
        if unix_seconds() as i64 > expires_at {
            bail!("navigation session expired");
        }
        let provided_hash: [u8; 32] = Sha256::digest(bearer_token.as_bytes()).into();
        if expected_token_hash.ct_eq(&provided_hash).unwrap_u8() != 1 {
            return Err(InvalidNavigationUploadToken.into());
        }
        if request.sequence == 0 {
            bail!("navigation event sequence must be positive");
        }
        if request.sequence < latest_sequence {
            bail!("navigation event sequence must increase");
        }
        if request.sequence == latest_sequence {
            return Ok(NavigationIngestResponse {
                accepted_sequence: request.sequence,
                command: stop_requested.then_some(NavigationCommand::Stop),
            });
        }
        let plaintext = decrypt_event(
            &request.session_id,
            &decryption_key,
            &request.ephemeral_public_key,
            &request.sealed_payload,
        )?;
        let event: Value =
            serde_json::from_slice(&plaintext).context("invalid navigation event JSON")?;
        validate_event(&event, &request.session_id, request.sequence)?;

        let (command, inserted) = {
            let mut sessions = self.sessions.lock().await;
            let session = sessions
                .by_id
                .get_mut(&request.session_id)
                .context("navigation session disappeared during ingest")?;
            let inserted = store_event(session, request.sequence, event.clone(), plaintext.len())?;
            (
                session.stop_requested.then_some(NavigationCommand::Stop),
                inserted,
            )
        };
        if inserted {
            self.changed.notify_waiters();
            self.journal.push(
                "navigation",
                json!({
                    "event": "deviceEvent",
                    "sessionId": request.session_id,
                    "sequence": request.sequence,
                    "kind": event.get("kind").and_then(Value::as_str),
                }),
            );
        }
        Ok(NavigationIngestResponse {
            accepted_sequence: request.sequence,
            command,
        })
    }
}

fn store_event(
    session: &mut NavigationSession,
    sequence: u64,
    event: Value,
    bytes: usize,
) -> Result<bool> {
    if sequence < session.latest_sequence {
        bail!("navigation event sequence must increase");
    }
    if sequence == session.latest_sequence {
        return Ok(false);
    }
    session.latest_sequence = sequence;
    session.stop_requested |= session.single_fix;
    session.events.push_back(StoredEvent {
        sequence,
        bytes,
        value: event,
    });
    session.event_bytes += bytes;
    while session.events.len() > MAX_EVENTS_PER_SESSION
        || (session.event_bytes > MAX_EVENT_BYTES_PER_SESSION && session.events.len() > 1)
    {
        if let Some(dropped) = session.events.pop_front() {
            session.event_bytes -= dropped.bytes;
            session.dropped_through_sequence = dropped.sequence;
        }
    }
    Ok(true)
}

fn decrypt_event(
    session_id: &str,
    secret: &StaticSecret,
    encoded_public_key: &str,
    encoded_payload: &str,
) -> Result<Vec<u8>> {
    let public_key_bytes = URL_SAFE_NO_PAD
        .decode(encoded_public_key)
        .context("invalid event public key encoding")?;
    let public_key_bytes: [u8; 32] = public_key_bytes
        .try_into()
        .map_err(|_| anyhow!("event public key must contain 32 bytes"))?;
    let shared = secret.diffie_hellman(&PublicKey::from(public_key_bytes));
    let hkdf = Hkdf::<Sha256>::new(Some(session_id.as_bytes()), shared.as_bytes());
    let mut key = [0_u8; 32];
    hkdf.expand(KEY_DERIVATION_INFO, &mut key)
        .map_err(|_| anyhow!("failed deriving navigation event key"))?;
    let combined = URL_SAFE_NO_PAD
        .decode(encoded_payload)
        .context("invalid sealed event encoding")?;
    let Some((nonce, sealed)) = combined
        .split_first_chunk::<12>()
        .filter(|(_, sealed)| sealed.len() >= 16)
    else {
        bail!("sealed event is too short");
    };
    let cipher = ChaCha20Poly1305::new((&key).into());
    cipher
        .decrypt(&Nonce::from(*nonce), sealed)
        .map_err(|_| anyhow!("navigation event authentication failed"))
}

fn validate_event(event: &Value, session_id: &str, sequence: u64) -> Result<()> {
    let object = event
        .as_object()
        .context("navigation event must be an object")?;
    if object.get("schemaVersion").and_then(Value::as_u64) != Some(SCHEMA_VERSION.into()) {
        bail!("unsupported navigation event schema version");
    }
    if object.get("sessionId").and_then(Value::as_str) != Some(session_id) {
        bail!("navigation event sessionId does not match request");
    }
    if object.get("sequence").and_then(Value::as_u64) != Some(sequence) {
        bail!("navigation event sequence does not match request");
    }
    if object.get("kind").and_then(Value::as_str).is_none() {
        bail!("navigation event kind is required");
    }
    if let Some(location) = object.get("rawLocation") {
        validate_location(location)?;
    }
    if let Some(location) = object.get("roadSnappedLocation") {
        validate_location(location)?;
    }
    Ok(())
}

fn validate_location(value: &Value) -> Result<()> {
    let latitude = value
        .get("latitude")
        .and_then(Value::as_f64)
        .context("location latitude is required")?;
    let longitude = value
        .get("longitude")
        .and_then(Value::as_f64)
        .context("location longitude is required")?;
    if !(-90.0..=90.0).contains(&latitude) || !(-180.0..=180.0).contains(&longitude) {
        bail!("location coordinates are out of range");
    }
    Ok(())
}

fn session_status(session: &NavigationSession, now: i64) -> Value {
    json!({
        "sessionId": session.id,
        "state": session.state(now),
        "destination": session.destination,
        "profile": session.profile,
        "createdAtUnixSeconds": session.created_at_unix_seconds,
        "expiresAtUnixSeconds": session.expires_at_unix_seconds,
        "singleFix": session.single_fix,
        "latestSequence": session.latest_sequence,
        "latestEvent": session.events.back().map(|event| &event.value),
        "droppedThroughSequence": session.dropped_through_sequence,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn destination_validation_requires_valid_coordinates_and_a_title() {
        let destination = |latitude, title: &str| NavigationDestination {
            latitude,
            longitude: 13.0,
            title: title.to_string(),
            place_id: None,
        };
        assert!(destination(55.7, "Lund").validate().is_ok());
        assert!(destination(91.0, "Invalid").validate().is_err());
        assert!(destination(55.7, " ").validate().is_err());
    }

    #[test]
    fn event_validation_requires_matching_identity() {
        let event = json!({
            "schemaVersion": 1,
            "sessionId": "expected",
            "sequence": 1,
            "kind": "location",
        });
        assert!(validate_event(&event, "expected", 1).is_ok());
        assert!(validate_event(&event, "other", 1).is_err());
        assert!(validate_event(&event, "expected", 2).is_err());
    }

    #[test]
    fn decrypts_x25519_chacha20poly1305_combined_payload() {
        let session_id = "session-1";
        let server_secret = StaticSecret::from([0x11; 32]);
        let server_public = PublicKey::from(&server_secret);
        let device_secret = StaticSecret::from([0x22; 32]);
        let device_public = PublicKey::from(&device_secret);
        let shared = device_secret.diffie_hellman(&server_public);
        let hkdf = Hkdf::<Sha256>::new(Some(session_id.as_bytes()), shared.as_bytes());
        let mut key = [0_u8; 32];
        hkdf.expand(KEY_DERIVATION_INFO, &mut key).unwrap();

        let nonce = [7_u8; 12];
        let plaintext =
            br#"{"schemaVersion":1,"sessionId":"session-1","sequence":1,"kind":"bootstrap"}"#;
        let cipher = ChaCha20Poly1305::new((&key).into());
        let ciphertext = cipher
            .encrypt(&Nonce::from(nonce), plaintext.as_slice())
            .unwrap();
        let mut combined = nonce.to_vec();
        combined.extend(ciphertext);
        let encoded_public_key = URL_SAFE_NO_PAD.encode(device_public.as_bytes());
        let sealed = URL_SAFE_NO_PAD.encode(combined);

        let decrypted =
            decrypt_event(session_id, &server_secret, &encoded_public_key, &sealed).unwrap();

        assert_eq!(
            encoded_public_key,
            "D6poTtKIZ7l_Smot7l34zpdOdrcBjj8iocTPJnhXDyA"
        );
        assert_eq!(
            sealed,
            "BwcHBwcHBwcHBwcHG5qTTouaBhngv7iiGHu77K2zNimXufBtLajq3zWPX2n1XPwl2pTydQNAmY5ZIOwMLGmroUTNWcBwGn05nB9jGeDBmFsV-H-4bJ7HaDoBsveAJJ9IMYPhMeUbnw"
        );
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn event_storage_acknowledges_last_sequence_without_duplicating_it() {
        let mut session = test_session();
        let event = json!({ "sequence": 1, "kind": "location" });

        assert!(store_event(&mut session, 1, event.clone(), 10).unwrap());
        assert!(!store_event(&mut session, 1, event, 10).unwrap());

        assert_eq!(session.latest_sequence, 1);
        assert_eq!(session.events.len(), 1);
    }

    #[test]
    fn a_single_fix_session_asks_the_iphone_to_stop_with_its_first_event() {
        let mut session = test_session();
        session.single_fix = true;

        assert!(
            store_event(
                &mut session,
                1,
                json!({ "sequence": 1, "kind": "bootstrap" }),
                10
            )
            .unwrap()
        );

        assert!(session.stop_requested);
        assert_eq!(session.state(0), NavigationSessionState::StopRequested);
        assert_eq!(session.events.len(), 1);
    }

    #[test]
    fn admission_drops_expired_sessions_and_derives_the_latest() {
        let mut sessions = NavigationSessions::default();
        sessions.admit(session_at("expired", 1.0, 10), 5).unwrap();
        sessions.admit(session_at("live", 2.0, 30), 5).unwrap();
        sessions.admit(session_at("newer", 3.0, 30), 20).unwrap();

        assert!(!sessions.by_id.contains_key("expired"));
        assert_eq!(sessions.latest_id(), Some("newer"));
    }

    #[test]
    fn admission_refuses_at_capacity_and_evicts_only_stopped_sessions() {
        let mut sessions = NavigationSessions::default();
        for index in 0..MAX_SESSIONS {
            let id = format!("session-{index}");
            sessions
                .admit(session_at(&id, index as f64, i64::MAX), 0)
                .unwrap();
        }
        assert!(
            sessions
                .admit(session_at("overflow", 99.0, i64::MAX), 0)
                .is_err()
        );
        assert_eq!(sessions.by_id.len(), MAX_SESSIONS);

        sessions.by_id.get_mut("session-3").unwrap().stop_requested = true;
        sessions
            .admit(session_at("replacement", 100.0, i64::MAX), 0)
            .unwrap();
        assert!(!sessions.by_id.contains_key("session-3"));
        assert!(sessions.by_id.contains_key("replacement"));
    }

    #[test]
    fn event_bytes_are_bounded_and_the_dropped_sequence_is_reported() {
        let mut session = test_session();
        let chunk = MAX_EVENT_BYTES_PER_SESSION / 2;
        for sequence in 1..=3 {
            let event = json!({ "sequence": sequence, "kind": "location" });
            assert!(store_event(&mut session, sequence, event, chunk).unwrap());
        }

        assert_eq!(session.events.len(), 2);
        assert_eq!(session.events.front().unwrap().sequence, 2);
        assert_eq!(session.dropped_through_sequence, 1);
        assert!(session.event_bytes <= MAX_EVENT_BYTES_PER_SESSION);
    }

    #[test]
    fn session_state_is_derived_from_the_clock_and_observations() {
        let mut session = session_at("session", 0.0, 100);
        assert_eq!(session.state(50), NavigationSessionState::Starting);
        session.latest_sequence = 1;
        assert_eq!(session.state(50), NavigationSessionState::Active);
        session.stop_requested = true;
        assert_eq!(session.state(50), NavigationSessionState::StopRequested);
        assert_eq!(session.state(101), NavigationSessionState::Expired);
    }

    fn session_at(id: &str, created_at: f64, expires_at: i64) -> NavigationSession {
        let mut session = test_session();
        session.id = id.to_string();
        session.created_at_unix_seconds = created_at;
        session.expires_at_unix_seconds = expires_at;
        session
    }

    fn test_session() -> NavigationSession {
        NavigationSession {
            id: "session".to_string(),
            destination: None,
            profile: NavigationProfile {
                mode: NavigationTravelMode::Walking,
                avoid_highways: false,
                avoid_tolls: false,
            },
            created_at_unix_seconds: 0.0,
            expires_at_unix_seconds: i64::MAX,
            upload_token_hash: [0; 32],
            decryption_key: StaticSecret::random(),
            events: VecDeque::new(),
            event_bytes: 0,
            dropped_through_sequence: 0,
            latest_sequence: 0,
            single_fix: false,
            stop_requested: false,
        }
    }
}
