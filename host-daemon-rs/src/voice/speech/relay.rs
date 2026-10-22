use std::borrow::Cow;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::State;
use axum::extract::ws::{CloseFrame, Message, WebSocketUpgrade};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode, Uri, header};
use axum::response::{IntoResponse, Response};
use axum::routing::any;
use axum::{Json, Router};
use reqwest::Url;
use serde_json::json;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio_util::sync::{CancellationToken, DropGuard};
use tokio_util::task::TaskTracker;
use tokio_util::task::task_tracker::TaskTrackerToken;
use tracing::warn;

use super::SpeechClients;
use super::routes::{self, Origin, Provider, Transport};
use crate::auth::installation_credentials::{Grant, InstallationCredentials};
use crate::observability::journal::Journal;
use crate::providers::codex::daemon::MAX_WEBSOCKET_BYTES;
use crate::providers::router::RouterConfig;

use self::websocket::{connect_socket, relay_socket};

#[cfg(test)]
mod harness;
mod http;
mod websocket;

const MAX_CONCURRENT_RELAYS: usize = 4;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

const LEASE_CHECK_INTERVAL: Duration = if cfg!(test) {
    Duration::from_millis(100)
} else {
    Duration::from_secs(5)
};

const DRAIN_GRACE: Duration = Duration::from_secs(3);

const REJECTION_HEADER: HeaderName = HeaderName::from_static("x-speech-relay-rejection");
const REJECTION_CLOSE_REASON_PREFIX: &str = "speech-relay-rejection:";

#[derive(Clone)]
pub(crate) struct SpeechRelay {
    inner: Arc<Inner>,
}

struct Inner {
    operator_token: String,
    installations: InstallationCredentials,
    router: Option<RouterConfig>,
    clients: SpeechClients,
    http: reqwest::Client,
    capacity: Arc<Semaphore>,
    drain: CancellationToken,
    tracker: TaskTracker,
    journal: Journal,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Rejection {
    Unauthorized,
    AuthenticationUnavailable,
    NotPermitted,
    OperationNotAllowed,
    Draining,
    Capacity,
    CredentialsUnavailable,
    Unavailable,
    RequestTooLarge,
    ClientStalled,
    UpstreamUnreachable,
    UpstreamRejected,
    UpstreamFailed,
}

impl Rejection {
    fn kind(self) -> &'static str {
        match self {
            Rejection::Unauthorized => "unauthorized",
            Rejection::AuthenticationUnavailable => "authenticationUnavailable",
            Rejection::NotPermitted => "notPermitted",
            Rejection::OperationNotAllowed => "operationNotAllowed",
            Rejection::Draining => "draining",
            Rejection::Capacity => "capacity",
            Rejection::CredentialsUnavailable => "credentialsUnavailable",
            Rejection::Unavailable => "unavailable",
            Rejection::RequestTooLarge => "requestTooLarge",
            Rejection::ClientStalled => "clientStalled",
            Rejection::UpstreamUnreachable => "upstreamUnreachable",
            Rejection::UpstreamRejected => "upstreamRejected",
            Rejection::UpstreamFailed => "upstreamFailed",
        }
    }

    fn status(self) -> StatusCode {
        match self {
            Rejection::Unauthorized => StatusCode::UNAUTHORIZED,
            Rejection::NotPermitted => StatusCode::FORBIDDEN,
            Rejection::OperationNotAllowed => StatusCode::NOT_FOUND,
            Rejection::Capacity => StatusCode::TOO_MANY_REQUESTS,
            Rejection::RequestTooLarge => StatusCode::PAYLOAD_TOO_LARGE,
            Rejection::ClientStalled => StatusCode::REQUEST_TIMEOUT,
            Rejection::CredentialsUnavailable => StatusCode::INTERNAL_SERVER_ERROR,
            Rejection::Unavailable => StatusCode::SERVICE_UNAVAILABLE,
            Rejection::AuthenticationUnavailable | Rejection::Draining => {
                StatusCode::SERVICE_UNAVAILABLE
            }
            Rejection::UpstreamUnreachable
            | Rejection::UpstreamRejected
            | Rejection::UpstreamFailed => StatusCode::BAD_GATEWAY,
        }
    }

    fn close_code(self) -> u16 {
        4000 + self.status().as_u16()
    }

    fn message(self) -> &'static str {
        match self {
            Rejection::Unauthorized => "The gateway rejected this client's credential.",
            Rejection::AuthenticationUnavailable => {
                "The gateway cannot read its installation credentials."
            }
            Rejection::NotPermitted => "This installation is not allowed to use gateway speech.",
            Rejection::OperationNotAllowed => "The gateway does not relay this speech operation.",
            Rejection::Draining => "The gateway is restarting.",
            Rejection::Capacity => "The gateway is relaying its maximum number of speech sessions.",
            Rejection::CredentialsUnavailable => "The gateway cannot read its llm-router key.",
            Rejection::Unavailable => "Speech is unavailable because llm-router is not configured.",
            Rejection::RequestTooLarge => "The speech request exceeds the gateway's size limit.",
            Rejection::ClientStalled => "The client stopped sending its speech request.",
            Rejection::UpstreamUnreachable => "The gateway could not reach the speech provider.",
            Rejection::UpstreamRejected => "The speech provider rejected the gateway's connection.",
            Rejection::UpstreamFailed => "The speech provider connection failed.",
        }
    }

    fn close_message(self) -> Message {
        Message::Close(Some(CloseFrame {
            code: self.close_code(),
            reason: Cow::Owned(format!("{REJECTION_CLOSE_REASON_PREFIX}{}", self.kind())),
        }))
    }
}

impl IntoResponse for Rejection {
    fn into_response(self) -> Response {
        (
            self.status(),
            [
                (header::CACHE_CONTROL, "no-store"),
                (REJECTION_HEADER, self.kind()),
            ],
            Json(json!({
                "remoteCoderSpeechError": {
                    "kind": self.kind(),
                    "message": self.message(),
                }
            })),
        )
            .into_response()
    }
}

#[derive(Default)]
struct Stop(OnceLock<Rejection>);

impl Stop {
    fn set(&self, rejection: Rejection) {
        let _ = self.0.set(rejection);
    }

    fn reason(&self) -> Rejection {
        self.0.get().copied().unwrap_or(Rejection::Draining)
    }
}

struct Admitted {
    upstream: Url,
    credential: (HeaderName, HeaderValue),
    ledger: Ledger,
    relay: CancellationToken,
    stop: Arc<Stop>,
}

struct Ledger {
    journal: Journal,
    provider: Provider,
    operation: &'static str,
    transport: Transport,
    principal: String,
    started: Instant,
    bytes_up: Arc<AtomicU64>,
    bytes_down: u64,
    status: Option<u16>,
    close_code: Option<u16>,
    outcome: &'static str,
    _permit: OwnedSemaphorePermit,
    _tracked: TaskTrackerToken,
    _relay: DropGuard,
}

impl Ledger {
    fn reject_http(&mut self, rejection: Rejection) {
        self.outcome = rejection.kind();
        self.status = Some(rejection.status().as_u16());
    }

    fn reject_upgrade(&mut self, rejection: Rejection, upstream_status: Option<u16>) {
        self.outcome = rejection.kind();
        self.status = upstream_status;
    }

    fn close(&mut self, outcome: &'static str, close_code: Option<u16>) {
        self.outcome = outcome;
        self.close_code = close_code;
    }
}

impl Drop for Ledger {
    fn drop(&mut self) {
        self.journal.speech(
            "relayed",
            json!({
                "provider": self.provider.name(),
                "operation": self.operation,
                "transport": self.transport.name(),
                "principal": self.principal,
                "outcome": self.outcome,
                "status": self.status,
                "closeCode": self.close_code,
                "bytesUp": self.bytes_up.load(Ordering::Relaxed),
                "bytesDown": self.bytes_down,
                "durationMs": u64::try_from(self.started.elapsed().as_millis()).unwrap_or(u64::MAX),
            }),
        );
    }
}

impl SpeechRelay {
    pub fn new(
        operator_token: String,
        installations: InstallationCredentials,
        router: Option<RouterConfig>,
        clients: SpeechClients,
        journal: Journal,
    ) -> anyhow::Result<Self> {
        let http = reqwest::Client::builder()
            .no_proxy()
            .connect_timeout(CONNECT_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        Ok(Self {
            inner: Arc::new(Inner {
                operator_token,
                installations,
                router,
                clients,
                http,
                capacity: Arc::new(Semaphore::new(MAX_CONCURRENT_RELAYS)),
                drain: CancellationToken::new(),
                tracker: TaskTracker::new(),
                journal,
            }),
        })
    }

    pub(crate) fn router(&self) -> Router {
        Router::new()
            .route("/speech/*path", any(handle))
            .with_state(self.clone())
    }

    pub(crate) async fn drain(&self) {
        self.inner.drain.cancel();
        self.inner.tracker.close();
        if tokio::time::timeout(DRAIN_GRACE, self.inner.tracker.wait())
            .await
            .is_err()
        {
            warn!("speech relays did not stop within the drain grace period");
        }
    }

    async fn authenticate(&self, headers: &HeaderMap) -> Result<Grant, Rejection> {
        let token =
            crate::http::server::auth::bearer_token(headers).ok_or(Rejection::Unauthorized)?;
        match self
            .inner
            .installations
            .authenticate(token, &self.inner.operator_token)
            .await
        {
            Ok(Some(grant)) => Ok(grant),
            Ok(None) => Err(Rejection::Unauthorized),
            Err(error) => {
                warn!(%error, "installation credential storage unavailable");
                Err(Rejection::AuthenticationUnavailable)
            }
        }
    }

    async fn admit(
        &self,
        grant: &Grant,
        method: &Method,
        uri: &Uri,
        transport: Transport,
    ) -> Result<Admitted, Rejection> {
        let principal = match grant {
            Grant::Operator => "operator".to_owned(),
            Grant::Installation { id, .. } => id.clone(),
        };
        let target = uri
            .path()
            .strip_prefix("/speech/")
            .and_then(|rest| rest.split_once('/'))
            .and_then(|(name, path)| Some((Provider::from_name(name)?, format!("/{path}"))));
        let Some((provider, path)) = target else {
            return Err(self.refuse(&principal, None, None, Rejection::OperationNotAllowed));
        };
        if !self.inner.clients.permits(grant) {
            return Err(self.refuse(&principal, Some(provider), None, Rejection::NotPermitted));
        }
        let Some(operation) = routes::operation(provider, method, &path, transport) else {
            return Err(self.refuse(
                &principal,
                Some(provider),
                None,
                Rejection::OperationNotAllowed,
            ));
        };
        let refuse =
            |rejection| self.refuse(&principal, Some(provider), Some(operation.name), rejection);
        if self.inner.drain.is_cancelled() {
            return Err(refuse(Rejection::Draining));
        }
        let Ok(permit) = Arc::clone(&self.inner.capacity).try_acquire_owned() else {
            return Err(refuse(Rejection::Capacity));
        };
        let router = self
            .inner
            .router
            .as_ref()
            .ok_or_else(|| refuse(Rejection::Unavailable))?;
        let key = match router.key() {
            Ok(key) => key,
            Err(error) => {
                warn!(%error, "llm-router key unavailable");
                return Err(refuse(Rejection::CredentialsUnavailable));
            }
        };
        let upstream = upstream_url(
            router.inference_base(),
            operation.origin,
            &path,
            uri.query(),
            transport,
        )
        .map_err(&refuse)?;
        let (name, value) = provider.credential_header(&key);
        let Ok(mut value) = HeaderValue::from_str(&value) else {
            return Err(refuse(Rejection::CredentialsUnavailable));
        };
        value.set_sensitive(true);

        let relay = self.inner.drain.child_token();
        let stop = Arc::new(Stop::default());
        self.watch_lease(grant, relay.clone(), Arc::clone(&stop));
        Ok(Admitted {
            upstream,
            credential: (name, value),
            ledger: Ledger {
                journal: self.inner.journal.clone(),
                provider,
                operation: operation.name,
                transport,
                principal,
                started: Instant::now(),
                bytes_up: Arc::new(AtomicU64::new(0)),
                bytes_down: 0,
                status: None,
                close_code: None,
                outcome: "clientClosed",
                _permit: permit,
                _tracked: self.inner.tracker.token(),
                _relay: relay.clone().drop_guard(),
            },
            relay,
            stop,
        })
    }

    fn refuse(
        &self,
        principal: &str,
        provider: Option<Provider>,
        operation: Option<&'static str>,
        rejection: Rejection,
    ) -> Rejection {
        self.inner.journal.speech(
            "rejected",
            json!({
                "provider": provider.map(Provider::name),
                "operation": operation,
                "principal": principal,
                "rejection": rejection.kind(),
            }),
        );
        rejection
    }

    fn watch_lease(&self, grant: &Grant, relay: CancellationToken, stop: Arc<Stop>) {
        let Grant::Installation { .. } = grant else {
            return;
        };
        let grant = grant.clone();
        let installations = self.inner.installations.clone();
        self.inner.tracker.spawn(async move {
            loop {
                tokio::select! {
                    _ = relay.cancelled() => return,
                    _ = tokio::time::sleep(LEASE_CHECK_INTERVAL) => {}
                }
                match installations.is_valid(&grant).await {
                    Ok(true) => {}
                    Ok(false) => {
                        stop.set(Rejection::Unauthorized);
                        relay.cancel();
                        return;
                    }
                    Err(error) => {
                        warn!(%error, "speech relay credential lease unavailable");
                        stop.set(Rejection::AuthenticationUnavailable);
                        relay.cancel();
                        return;
                    }
                }
            }
        });
    }
}

async fn handle(
    State(relay): State<SpeechRelay>,
    upgrade: Option<WebSocketUpgrade>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let grant = match relay.authenticate(&headers).await {
        Ok(grant) => grant,
        Err(rejection) => return rejection.into_response(),
    };
    match upgrade {
        Some(upgrade) => {
            let admitted = match relay
                .admit(&grant, &method, &uri, Transport::WebSocket)
                .await
            {
                Ok(admitted) => admitted,
                Err(rejection) => return rejection.into_response(),
            };
            let connected = match connect_socket(admitted).await {
                Ok(connected) => connected,
                Err(rejection) => return rejection.into_response(),
            };
            upgrade
                .max_message_size(MAX_WEBSOCKET_BYTES)
                .max_frame_size(MAX_WEBSOCKET_BYTES)
                .on_upgrade(move |client| relay_socket(client, connected))
        }
        None => match relay.admit(&grant, &method, &uri, Transport::Http).await {
            Ok(admitted) => relay.relay_http(admitted, method, &headers, body).await,
            Err(rejection) => rejection.into_response(),
        },
    }
}

fn upstream_url(
    router: &str,
    origin: Origin,
    path: &str,
    query: Option<&str>,
    transport: Transport,
) -> Result<Url, Rejection> {
    let mut url = Url::parse(&format!(
        "{router}/vendors/{}{path}",
        origin.router_vendor()
    ))
    .map_err(|_| Rejection::CredentialsUnavailable)?;
    if transport == Transport::WebSocket {
        let scheme = match url.scheme() {
            "https" => "wss",
            "http" => "ws",
            _ => return Err(Rejection::CredentialsUnavailable),
        };
        url.set_scheme(scheme)
            .map_err(|()| Rejection::CredentialsUnavailable)?;
    }
    let query = query
        .map(|query| {
            query
                .split('&')
                .filter(|pair| {
                    let name = pair.split('=').next().unwrap_or_default();
                    !name.is_empty() && name != "key" && name != "access_token"
                })
                .collect::<Vec<_>>()
                .join("&")
        })
        .filter(|query| !query.is_empty());
    url.set_query(query.as_deref());
    Ok(url)
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::SinkExt;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio_tungstenite::tungstenite;

    use crate::voice::speech::relay::harness::{
        Harness, OPERATOR, next_close, next_message, rejection_kind,
    };
    use crate::voice::speech::relay::http::MAX_REQUEST_BODY_BYTES;

    #[tokio::test]
    async fn admission_rejects_with_typed_errors_and_policy_limits_only_installations() {
        let harness = Harness::start(SpeechClients::parse(Some("phone")).unwrap()).await;
        let phone = harness.enroll("phone").await;
        let tablet = harness.enroll("tablet").await;
        let transcription = "/speech/openai/v1/audio/transcriptions";

        let unauthenticated = harness
            .http
            .post(format!("http://{}{transcription}", harness.address))
            .send()
            .await
            .unwrap();
        assert_eq!(
            rejection_kind(unauthenticated).await,
            (401, "unauthorized".to_owned())
        );
        assert_eq!(
            rejection_kind(harness.post(transcription, &tablet).send().await.unwrap()).await,
            (403, "notPermitted".to_owned())
        );
        for token in [phone.as_str(), OPERATOR] {
            let response = harness
                .post(transcription, token)
                .body("a")
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
        }
        for path in [
            "/speech/openai/v1/chat/completions",
            "/speech/openai/v1/audio/%2e%2e/transcriptions",
            "/speech/unknown/v1/audio/transcriptions",
        ] {
            assert_eq!(
                rejection_kind(harness.post(path, &phone).send().await.unwrap()).await,
                (404, "operationNotAllowed".to_owned())
            );
        }

        let mut stream = tokio::net::TcpStream::connect(harness.address)
            .await
            .unwrap();
        stream
            .write_all(
                format!(
                    "POST {transcription} HTTP/1.1\r\nhost: relay\r\nauthorization: Bearer {OPERATOR}\r\ncontent-length: {}\r\n\r\n",
                    MAX_REQUEST_BODY_BYTES + 1
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        let mut head = [0u8; 12];
        tokio::time::timeout(Duration::from_secs(5), stream.read_exact(&mut head))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&head, b"HTTP/1.1 413");
    }

    #[tokio::test]
    async fn capacity_refuses_a_fifth_relay_and_every_ending_releases_its_slot() {
        let harness = Harness::start(SpeechClients::All).await;
        let realtime = "/speech/openai/v1/realtime";
        let mut sockets = Vec::new();
        for _ in 0..MAX_CONCURRENT_RELAYS {
            let mut socket = harness.socket(realtime, OPERATOR).await.unwrap();
            next_message(&mut socket).await;
            sockets.push(socket);
        }
        assert_eq!(
            harness.socket(realtime, OPERATOR).await.err(),
            Some((StatusCode::TOO_MANY_REQUESTS, "capacity".to_owned()))
        );
        assert_eq!(
            rejection_kind(
                harness
                    .post("/speech/openai/v1/audio/transcriptions", OPERATOR)
                    .body("audio")
                    .send()
                    .await
                    .unwrap()
            )
            .await,
            (429, "capacity".to_owned())
        );

        let mut completed = sockets.pop().unwrap();
        completed
            .send(tungstenite::Message::Text("bye".into()))
            .await
            .unwrap();
        assert_eq!(
            next_close(&mut completed).await,
            (4321, "upstream-bye".to_owned())
        );
        harness.wait_for_free_slots(1).await;

        sockets.pop().unwrap().close(None).await.unwrap();
        harness.wait_for_free_slots(2).await;

        drop(sockets.pop().unwrap());
        harness.wait_for_free_slots(3).await;

        let mut failed = harness
            .socket("/speech/openai/v1/realtime?behavior=drop", OPERATOR)
            .await
            .unwrap();
        assert_eq!(
            next_close(&mut failed).await,
            (4502, "speech-relay-rejection:upstreamFailed".to_owned())
        );
        harness.wait_for_free_slots(3).await;

        drop(sockets);
        harness.wait_for_free_slots(MAX_CONCURRENT_RELAYS).await;
    }

    #[tokio::test]
    async fn revoking_an_installation_ends_its_active_relay() {
        let harness = Harness::start(SpeechClients::All).await;
        let phone = harness.enroll("phone").await;
        let mut socket = harness
            .socket("/speech/openai/v1/realtime", &phone)
            .await
            .unwrap();
        next_message(&mut socket).await;

        assert!(
            harness
                .installations
                .revoke("phone".to_owned())
                .await
                .unwrap()
        );
        assert_eq!(
            next_close(&mut socket).await,
            (4401, "speech-relay-rejection:unauthorized".to_owned())
        );
    }

    #[tokio::test]
    async fn drain_closes_active_relays_and_refuses_new_ones() {
        let harness = Harness::start(SpeechClients::All).await;
        let mut socket = harness
            .socket("/speech/openai/v1/realtime", OPERATOR)
            .await
            .unwrap();
        next_message(&mut socket).await;

        tokio::time::timeout(DRAIN_GRACE, harness.relay.drain())
            .await
            .expect("drain finished within its grace period");
        assert_eq!(
            next_close(&mut socket).await,
            (4503, "speech-relay-rejection:draining".to_owned())
        );
        assert_eq!(
            rejection_kind(
                harness
                    .post("/speech/openai/v1/audio/transcriptions", OPERATOR)
                    .send()
                    .await
                    .unwrap()
            )
            .await,
            (503, "draining".to_owned())
        );
    }

    #[tokio::test]
    async fn unconfigured_speech_is_explicitly_unavailable() {
        let directory = tempfile::tempdir().unwrap();
        let relay = SpeechRelay::new(
            "test-operator".into(),
            InstallationCredentials::new(directory.path().join("installations")),
            None,
            SpeechClients::All,
            Journal::disabled(),
        )
        .unwrap();
        let rejection = relay
            .admit(
                &Grant::Operator,
                &Method::POST,
                &"/speech/openai/v1/audio/transcriptions".parse().unwrap(),
                Transport::Http,
            )
            .await
            .err()
            .expect("speech needs a configured router");
        let response = rejection.into_response();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(
            response.headers()["X-Speech-Relay-Rejection"],
            "unavailable"
        );
    }

    #[test]
    fn upstream_urls_name_the_router_vendor_and_drop_client_credentials() {
        let router = "http://127.0.0.1:42069";
        assert_eq!(
            upstream_url(
                router,
                Origin::AzureResource,
                "/speechtotext/transcriptions:transcribe",
                Some("api-version=2025-10-15&key=client"),
                Transport::Http,
            )
            .unwrap()
            .as_str(),
            "http://127.0.0.1:42069/vendors/azure-speech/speechtotext/transcriptions:transcribe?api-version=2025-10-15"
        );
        assert_eq!(
            upstream_url(
                router,
                Origin::AssemblyAiStreaming,
                "/v3/ws",
                Some("sample_rate=16000&access_token=client"),
                Transport::WebSocket,
            )
            .unwrap()
            .as_str(),
            "ws://127.0.0.1:42069/vendors/assemblyai-streaming/v3/ws?sample_rate=16000"
        );
    }
}
