use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use axum::body::{Body, BodyDataStream, Bytes};
use axum::extract::{DefaultBodyLimit, State};
use axum::http::{Request, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, put};
use axum::{Json, Router};
use futures_util::{Stream, StreamExt, stream};
use serde_json::json;
use tokio::net::TcpListener;
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;
use tracing::info;

use crate::files::FileDownloads;
use crate::files::upload::UploadStore;
use crate::gateway::Gateway;
use crate::http::lan::{LanEndpoint, LanListener, serve_lan};
use crate::observability::app_logs::AppLogStore;
use crate::observability::journal::Journal;

use self::auth::enroll_credential;
use self::client::{app_logs, diagnostics, health, navigation_events, version, ws};
use self::files::{append_upload, discard_upload, download_file, legacy_upload, upload_status};
use self::mcp::{mcp_get, mcp_notification_hook, mcp_post};
use super::{accounts, claude_accounts, resets};

pub(crate) mod auth;
mod client;
#[cfg(test)]
mod cluster_tests;
mod files;
#[cfg(test)]
mod harness;
mod mcp;

/// Ceiling for one uploaded app-log segment. The app cuts segments far below
/// this; the limit exists so a broken or hostile client cannot post a file
/// large enough to matter.
const MAX_APP_LOG_SEGMENT_BYTES: usize = 16 * 1024 * 1024;
const MAX_MCP_REQUEST_BYTES: usize = 2 * crate::storage::visuals::MAX_HTML_BYTES + 64 * 1024;

/// Requests whose bodies the server buffers in memory, at once. Each body is
/// capped, but the caps alone do not bound the total.
const MAX_BUFFERED_REQUESTS: usize = 32;

/// How long a buffered body may go without a byte. There is no cap on its
/// total duration, only on silence.
const BUFFERED_BODY_IDLE_TIMEOUT: Duration = Duration::from_secs(30);

/// Open TLS connections on the LAN listener, handshakes included.
const MAX_LAN_CONNECTIONS: usize = 64;

#[derive(Clone)]
pub(crate) struct HttpState {
    pub auth_token: String,
    pub installation_credentials: crate::auth::installation_credentials::InstallationCredentials,
    pub gateway: Arc<Gateway>,
    pub router: Arc<crate::providers::router::Router>,
    pub accounts: Option<Arc<crate::accounts::Accounts>>,
    pub codex_version: String,
    pub codex_code_mode_host_path: PathBuf,
    pub app_logs: AppLogStore,
    pub uploads: UploadStore,
    pub files: FileDownloads,
    pub speech: crate::voice::speech::SpeechRelay,
    pub requests: RequestAdmission,
    pub journal: Journal,
    pub lan_endpoint: Option<LanEndpoint>,
    pub relay_route: crate::http::relay::RelayRoute,
    pub full_disk_access: crate::platform::macos::full_disk_access::FullDiskAccessReport,
}

impl HttpState {
    fn drain_transfers(&self) {
        self.requests.drain();
        self.files.drain();
        self.uploads.drain();
    }
}

/// Admission for routes that buffer their body: a bound on how many run at
/// once, an idle timeout on each body, and cancellation when the host drains.
#[derive(Clone)]
pub(crate) struct RequestAdmission {
    slots: Arc<Semaphore>,
    drain: CancellationToken,
    idle_timeout: Duration,
}

impl Default for RequestAdmission {
    fn default() -> Self {
        Self {
            slots: Arc::new(Semaphore::new(MAX_BUFFERED_REQUESTS)),
            drain: CancellationToken::new(),
            idle_timeout: BUFFERED_BODY_IDLE_TIMEOUT,
        }
    }
}

impl RequestAdmission {
    fn drain(&self) {
        self.drain.cancel();
    }

    fn guarded(&self, body: BodyDataStream) -> impl Stream<Item = std::io::Result<Bytes>> + use<> {
        let drain = self.drain.clone();
        let idle_timeout = self.idle_timeout;
        stream::unfold(Some(body), move |body| {
            let drain = drain.clone();
            async move {
                let mut body = body?;
                let failure = |kind, message| Some((Err(std::io::Error::new(kind, message)), None));
                tokio::select! {
                    () = drain.cancelled() => {
                        failure(std::io::ErrorKind::Interrupted, "the host is restarting")
                    }
                    next = tokio::time::timeout(idle_timeout, body.next()) => match next {
                        Err(_) => failure(std::io::ErrorKind::TimedOut, "the request body stopped"),
                        Ok(None) => None,
                        Ok(Some(Err(error))) => failure(std::io::ErrorKind::Other, &error.to_string()),
                        Ok(Some(Ok(chunk))) => Some((Ok(chunk), Some(body))),
                    }
                }
            }
        })
    }
}

async fn admit_buffered(
    State(requests): State<RequestAdmission>,
    request: Request<Body>,
    next: Next,
) -> Response {
    if requests.drain.is_cancelled() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"error":"the host is restarting; retry after it is back"})),
        )
            .into_response();
    }
    let Ok(_permit) = Arc::clone(&requests.slots).try_acquire_owned() else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            [(header::RETRY_AFTER, "1")],
            Json(json!({"error":"too many requests are in progress; retry shortly"})),
        )
            .into_response();
    };
    let (parts, body) = request.into_parts();
    let body = Body::from_stream(requests.guarded(body.into_data_stream()));
    next.run(Request::from_parts(parts, body)).await
}

pub(crate) async fn run_http_server(
    bind_host: String,
    port: u16,
    state: HttpState,
    lan: Option<LanListener>,
) -> Result<()> {
    state
        .gateway
        .cluster_link()
        .await?
        .set_endpoint(state.lan_endpoint.clone())
        .await;
    let shutdown_gateway = Arc::clone(&state.gateway);
    let shutdown_state = state.clone();
    let app = router(state);

    let listener = TcpListener::bind((bind_host.as_str(), port))
        .await
        .with_context(|| format!("failed to bind {bind_host}:{port}"))?;
    shutdown_gateway.mark_listening();

    let lan_shutdown = CancellationToken::new();
    let lan_server = lan.map(|lan| {
        info!(
            port = lan.endpoint.port,
            host = %lan.endpoint.host,
            spki_sha256 = %lan.endpoint.spki_sha256,
            "LAN TLS listener started"
        );
        serve_lan(
            lan.listener,
            lan.acceptor,
            app.clone(),
            lan_shutdown.clone(),
            MAX_LAN_CONNECTIONS,
        )
    });
    let signal = {
        let lan_shutdown = lan_shutdown.clone();
        async move {
            shutdown_signal(shutdown_state).await;
            lan_shutdown.cancel();
        }
    };
    let plaintext = async {
        let served = axum::serve(listener, app)
            .with_graceful_shutdown(signal)
            .await;
        lan_shutdown.cancel();
        served
    };
    let lan = async {
        if let Some(lan_server) = lan_server {
            lan_server.await;
        }
    };
    let (served, ()) = tokio::join!(plaintext, lan);
    served.context("http server exited")?;

    Ok(())
}

fn router(state: HttpState) -> Router {
    let speech = state.speech.router();
    let buffered = Router::new()
        .route(
            "/credentials/enroll",
            post(enroll_credential).layer(DefaultBodyLimit::max(4096)),
        )
        .route(
            "/app-logs",
            post(app_logs).layer(DefaultBodyLimit::max(MAX_APP_LOG_SEGMENT_BYTES)),
        )
        .route(
            "/mcp",
            post(mcp_post)
                .layer(DefaultBodyLimit::max(MAX_MCP_REQUEST_BYTES))
                .get(mcp_get),
        )
        .route(
            "/mcp/notification-hook",
            post(mcp_notification_hook).layer(DefaultBodyLimit::max(64 * 1024)),
        )
        .route("/navigation/events", post(navigation_events))
        .route_layer(middleware::from_fn_with_state(
            state.requests.clone(),
            admit_buffered,
        ));
    Router::new()
        .route("/health", get(health))
        .route("/version", get(version))
        .route("/relay", get(crate::http::relay::published))
        .route("/diagnostics", get(diagnostics))
        .route("/ws", get(ws))
        .route("/claude/accounts", get(claude_accounts::directory))
        .route(
            "/claude/accounts/preference",
            put(claude_accounts::prefer).layer(DefaultBodyLimit::max(4096)),
        )
        .route(
            "/claude/accounts/refresh",
            post(claude_accounts::refresh).layer(DefaultBodyLimit::max(4096)),
        )
        .route(
            "/claude/accounts/resets/redeem",
            post(resets::claude).layer(DefaultBodyLimit::max(8192)),
        )
        .route(
            "/accounts/:account_id/resets/redeem",
            post(resets::codex).layer(DefaultBodyLimit::max(8192)),
        )
        .route("/accounts", get(accounts::directory))
        .route("/uploads", post(legacy_upload))
        .route(
            "/uploads/:id",
            put(append_upload).get(upload_status).delete(discard_upload),
        )
        .route("/files/download", post(download_file))
        .merge(buffered)
        .with_state(state)
        .merge(speech)
}

async fn shutdown_signal(state: HttpState) {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };

    #[cfg(unix)]
    let term = async {
        use tokio::signal::unix::{SignalKind, signal};
        let mut sigterm = signal(SignalKind::terminate()).expect("install SIGTERM handler");
        sigterm.recv().await;
    };

    #[cfg(not(unix))]
    let term = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = term => {},
    }

    state.drain_transfers();

    tokio::join!(
        state.gateway.shutdown_for_restart(),
        async {
            if let Some(accounts) = &state.accounts {
                accounts.drain().await;
            }
        },
        state.speech.drain()
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio_tungstenite::tungstenite::Message;
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;

    use crate::http::lan::LAN_HEADER_READ_TIMEOUT;
    use crate::http::server::client::{DEVICE_HEADER, SEGMENT_HEADER};

    use crate::http::server::harness::{HOST, LanHarness, OPERATOR, exchange};

    #[tokio::test]
    async fn version_requires_auth_and_reports_identity_when_codex_is_unavailable() {
        let lan = LanHarness::start().await;
        let mut stream = lan.connect(&lan.pin).await.expect("pinned handshake");
        for authorization in ["", "Authorization: Bearer wrong-token\r\n"] {
            let (status, _) = exchange(
                &mut stream,
                &format!("GET /version HTTP/1.1\r\nHost: {HOST}\r\n{authorization}\r\n"),
                b"",
            )
            .await;
            assert_eq!(status, 401);
        }
        let authorization = format!("Authorization: Bearer {OPERATOR}\r\n");
        let (status, _) = exchange(
            &mut stream,
            &format!("GET /health HTTP/1.1\r\nHost: {HOST}\r\n{authorization}\r\n"),
            b"",
        )
        .await;
        assert_eq!(status, 500);
        let (status, body) = exchange(
            &mut stream,
            &format!("GET /version HTTP/1.1\r\nHost: {HOST}\r\n{authorization}\r\n"),
            b"",
        )
        .await;
        assert_eq!(status, 200);
        assert_eq!(
            serde_json::from_slice::<Value>(&body).unwrap(),
            json!({
                "version": option_env!("RC_RELEASE_VERSION").unwrap_or("dev"),
                "commit": option_env!("RC_SOURCE_COMMIT"),
                "modified": option_env!("RC_SOURCE_MODIFIED").map(|value| value == "true"),
                "workerHash": env!("RC_CALL_WORKER_HASH"),
            })
        );
        lan.stop().await;
    }

    #[tokio::test]
    async fn relay_requires_auth_is_never_cached_and_separates_absent_from_unavailable() {
        let lan = LanHarness::start().await;
        let file = lan.directory.path().join("relay.json");
        let route = json!({
            "proxyHost": "192.0.2.10", "proxyPort": 443,
            "proxySpkiSha256": "8wwM/PRU7p/+58P1hcpANRXWQtrmLN9iR7Y36MPrda8=",
            "targetHost": "mini.relay.example.com", "targetPort": 20001,
            "username": "relay", "password": "secret",
        });
        std::fs::write(&file, route.to_string()).unwrap();
        let mut configured = lan.state.clone();
        configured.relay_route = crate::http::relay::RelayRoute::Published(
            crate::http::relay::RelayEndpoint::load(&file)
                .unwrap()
                .unwrap(),
        );
        let mut unavailable = lan.state.clone();
        unavailable.relay_route = crate::http::relay::RelayRoute::Unavailable;
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        let cases = [
            (lan.state.clone(), 404, json!({"error": "no relay route"})),
            (
                unavailable,
                503,
                json!({"error": "relay route unavailable"}),
            ),
            (configured, 200, route),
        ];
        for (state, status, body) in cases {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let url = format!("http://{}/relay", listener.local_addr().unwrap());
            let server = tokio::spawn(async move {
                axum::serve(listener, router(state)).await.unwrap();
            });
            let refused = client.get(&url).bearer_auth("wrong").send().await.unwrap();
            assert_eq!(refused.status().as_u16(), 401);
            let response = client.get(&url).bearer_auth(OPERATOR).send().await.unwrap();
            assert_eq!(response.status().as_u16(), status);
            assert_eq!(
                response.headers()[axum::http::header::CACHE_CONTROL],
                "no-store"
            );
            assert_eq!(response.json::<Value>().await.unwrap(), body);
            server.abort();
        }
        lan.stop().await;
    }

    #[test]
    fn lan_endpoint_serializes_as_the_health_contract() {
        let endpoint = LanEndpoint {
            host: "mini.local".to_string(),
            port: 8789,
            spki_sha256: "c3BraQ==".to_string(),
        };

        assert_eq!(
            json!({ "lanEndpoint": Some(endpoint) }),
            json!({ "lanEndpoint": { "host": "mini.local", "port": 8789, "spkiSha256": "c3BraQ==" } })
        );
        assert_eq!(
            json!({ "lanEndpoint": None::<LanEndpoint> }),
            json!({ "lanEndpoint": null })
        );
    }

    #[tokio::test]
    async fn lan_listener_serves_the_gateway_routes_to_a_pinned_client() {
        let lan = LanHarness::start().await;
        let mut stream = lan.connect(&lan.pin).await.expect("pinned handshake");
        assert_eq!(stream.get_ref().1.alpn_protocol(), Some(&b"http/1.1"[..]));

        let (status, _) = exchange(
            &mut stream,
            &format!(
                "GET /health HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer not-the-operator\r\n\r\n"
            ),
            b"",
        )
        .await;
        assert_eq!(status, 401);

        let (status, body) = exchange(
            &mut stream,
            &format!(
                "GET /health HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {OPERATOR}\r\n\r\n"
            ),
            b"",
        )
        .await;
        assert_eq!(status, 500);
        assert_eq!(
            serde_json::from_slice::<Value>(&body).unwrap(),
            json!({"status": "error", "message": "codex unavailable"})
        );

        let segment = [0x1f, 0x8b, 0x08, 0x00];
        let (status, body) = exchange(
            &mut stream,
            &format!(
                "POST /app-logs HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {OPERATOR}\r\n{DEVICE_HEADER}: phone\r\n{SEGMENT_HEADER}: lan-1\r\nContent-Length: {}\r\n\r\n",
                segment.len()
            ),
            &segment,
        )
        .await;
        assert_eq!(status, 200);
        let stored = serde_json::from_slice::<Value>(&body).unwrap()["stored"]
            .as_str()
            .unwrap()
            .to_string();
        assert_eq!(
            std::fs::read(lan.directory.path().join("app-logs/phone").join(stored)).unwrap(),
            segment
        );

        for (device, body, expected) in [("phone", &b"plain"[..], 422), ("..", &segment[..], 400)] {
            let (status, _) = exchange(
                &mut stream,
                &format!(
                    "POST /app-logs HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {OPERATOR}\r\n{DEVICE_HEADER}: {device}\r\n{SEGMENT_HEADER}: lan-2\r\nContent-Length: {}\r\n\r\n",
                    body.len()
                ),
                body,
            )
            .await;
            assert_eq!(status, expected, "{device}");
        }

        lan.stop().await;
    }

    #[tokio::test]
    async fn lan_listener_upgrades_websockets() {
        let lan = LanHarness::start().await;
        let stream = lan.connect(&lan.pin).await.expect("pinned handshake");
        let mut request = format!("wss://{HOST}/ws").into_client_request().unwrap();
        request.headers_mut().insert(
            header::AUTHORIZATION,
            format!("Bearer {OPERATOR}").parse().unwrap(),
        );

        let (mut socket, response) = tokio_tungstenite::client_async(request, stream)
            .await
            .expect("WebSocket upgrade over the LAN listener");

        assert_eq!(response.status(), StatusCode::SWITCHING_PROTOCOLS);
        match socket.next().await {
            Some(Ok(Message::Text(text))) => assert!(text.contains("daemon/ready"), "{text}"),
            other => panic!("expected the ready frame, got {other:?}"),
        }
        lan.stop().await;
    }

    #[tokio::test]
    async fn cancelling_shutdown_closes_idle_lan_connections() {
        let lan = LanHarness::start().await;
        let mut idle = lan.connect(&lan.pin).await.expect("pinned handshake");
        let (status, _) = exchange(
            &mut idle,
            &format!("GET /health HTTP/1.1\r\nHost: {HOST}\r\n\r\n"),
            b"",
        )
        .await;
        assert_eq!(status, 401);

        lan.stop().await;

        let mut remainder = Vec::new();
        let closed =
            tokio::time::timeout(Duration::from_secs(5), idle.read_to_end(&mut remainder)).await;
        assert!(closed.is_ok(), "the server must close the idle connection");
        assert!(remainder.is_empty());
    }

    #[tokio::test]
    async fn a_connection_that_never_sends_a_request_cannot_hold_shutdown_open() {
        let lan = LanHarness::start().await;
        let mut silent = lan.connect(&lan.pin).await.expect("pinned handshake");
        tokio::time::sleep(Duration::from_millis(200)).await;
        tokio::time::pause();

        lan.shutdown.cancel();
        tokio::time::timeout(2 * LAN_HEADER_READ_TIMEOUT, lan.server)
            .await
            .expect("the header read timeout releases the silent connection")
            .expect("LAN server task");
        tokio::time::resume();

        let mut remainder = Vec::new();
        let ended =
            tokio::time::timeout(Duration::from_secs(5), silent.read_to_end(&mut remainder)).await;
        assert!(ended.is_ok(), "the client must see the connection end");
        assert!(remainder.is_empty());
    }

    fn post_head(path: &str, authorization: Option<&str>, length: usize) -> String {
        let authorization = authorization
            .map(|token| format!("Authorization: Bearer {token}\r\n"))
            .unwrap_or_default();
        format!(
            "POST {path} HTTP/1.1\r\nHost: {HOST}\r\n{authorization}Content-Type: application/octet-stream\r\nContent-Length: {length}\r\n\r\n"
        )
    }

    const UPLOAD_PATH: &str = "/uploads/00000000-0000-4000-8000-000000000001?name=stalled.bin";
    const UPLOAD_SHA256: &str = "0000000000000000000000000000000000000000000000000000000000000000";

    fn upload_head(authorization: Option<&str>, length: usize) -> String {
        let headers = format!(
            "X-RemoteCoder-SHA256: {UPLOAD_SHA256}\r\nX-RemoteCoder-Upload-Offset: 0\r\nX-RemoteCoder-Upload-Length: {length}\r\n"
        );
        post_head(UPLOAD_PATH, authorization, length)
            .replacen("POST ", "PUT ", 1)
            .replacen("\r\n\r\n", &format!("\r\n{headers}\r\n"), 1)
    }

    #[tokio::test]
    async fn unauthenticated_requests_are_refused_before_their_bodies_are_read() {
        let lan = LanHarness::start().await;
        for (head, expected) in [
            (post_head("/app-logs", None, 1_000_000), 401),
            (post_head("/mcp", None, 1_000_000), 401),
            (post_head("/mcp/notification-hook", None, 1_000_000), 401),
            (post_head("/credentials/enroll", None, 1_000_000), 403),
            (post_head("/navigation/events", None, 1_000_000), 401),
            (upload_head(None, 1_000_000), 401),
            (post_head("/files/download", None, 1_000_000), 401),
        ] {
            let mut stream = lan.connect(&lan.pin).await.unwrap();
            let (status, _) =
                tokio::time::timeout(Duration::from_secs(5), exchange(&mut stream, &head, b""))
                    .await
                    .unwrap_or_else(|_| panic!("{head} waited for a body it should never read"));
            assert_eq!(status, expected, "{head}");
        }
        lan.stop().await;
    }

    #[tokio::test]
    async fn draining_ends_stalled_authenticated_bodies_so_shutdown_can_finish() {
        for (head, expected) in [
            (post_head("/app-logs", Some(OPERATOR), 100), 400),
            (upload_head(Some(OPERATOR), 100), 503),
        ] {
            let lan = LanHarness::start().await;
            let mut stream = lan.connect(&lan.pin).await.unwrap();
            let state = lan.state.clone();
            let drained = async {
                tokio::time::sleep(Duration::from_millis(200)).await;
                state.drain_transfers();
            };
            let ((status, _), ()) = tokio::time::timeout(Duration::from_secs(5), async {
                tokio::join!(exchange(&mut stream, &head, b"part"), drained)
            })
            .await
            .expect("a stalled body must not outlive the drain");
            assert_eq!(status, expected, "{head}");
            lan.stop().await;
        }
    }

    #[tokio::test]
    async fn buffered_requests_beyond_the_admission_limit_are_refused() {
        let requests = RequestAdmission {
            slots: Arc::new(Semaphore::new(1)),
            ..RequestAdmission::default()
        };
        let lan = LanHarness::start_configured(false, requests, MAX_LAN_CONNECTIONS).await;
        let mut holder = lan.connect(&lan.pin).await.unwrap();
        holder
            .write_all(post_head("/app-logs", Some(OPERATOR), 100).as_bytes())
            .await
            .unwrap();
        holder.write_all(b"part").await.unwrap();

        let refused = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let mut stream = lan.connect(&lan.pin).await.unwrap();
                let head = post_head("/app-logs", Some(OPERATOR), 4);
                let (status, _) = exchange(&mut stream, &head, b"data").await;
                if status == 503 {
                    return;
                }
                tokio::task::yield_now().await;
            }
        })
        .await;
        assert!(
            refused.is_ok(),
            "the second request is refused while the first holds the slot"
        );

        lan.state.drain_transfers();
        lan.stop().await;
    }

    #[tokio::test]
    async fn the_lan_listener_refuses_connections_beyond_its_limit() {
        let lan = LanHarness::start_configured(false, RequestAdmission::default(), 1).await;
        let mut first = lan.connect(&lan.pin).await.unwrap();
        let (status, _) = exchange(
            &mut first,
            &format!("GET /health HTTP/1.1\r\nHost: {HOST}\r\n\r\n"),
            b"",
        )
        .await;
        assert_eq!(status, 401);

        let second = tokio::time::timeout(Duration::from_secs(5), lan.connect(&lan.pin))
            .await
            .expect("a refused connection ends promptly");
        assert!(
            second.is_err(),
            "the connection over the limit must not complete a handshake"
        );

        drop(first);
        tokio::time::timeout(Duration::from_secs(5), async {
            while lan.connect(&lan.pin).await.is_err() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("the slot frees when the first connection closes");
        lan.stop().await;
    }

    #[tokio::test(start_paused = true)]
    async fn a_silent_buffered_body_times_out_and_then_ends() {
        let admission = RequestAdmission::default();
        let silent = Body::from_stream(stream::pending::<std::io::Result<Bytes>>());
        let mut guarded = Box::pin(admission.guarded(silent.into_data_stream()));

        let error = guarded.next().await.unwrap().unwrap_err();

        assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
        assert!(guarded.next().await.is_none());
    }
}
