use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::TlsConnector;
use tokio_rustls::client::TlsStream;
use tokio_rustls::rustls::ClientConfig;
use tokio_rustls::rustls::crypto::ring;
use tokio_rustls::rustls::pki_types::ServerName;
use tokio_rustls::rustls::version::TLS13;
use tokio_util::sync::CancellationToken;

use crate::auth::installation_credentials::InstallationCredentials;
use crate::files::FileDownloads;
use crate::files::upload::UploadStore;
use crate::gateway::Gateway;
use crate::http::lan::{LanEndpoint, serve_lan};
use crate::http::lan_identity::LanIdentity;
use crate::observability::app_logs::{APP_LOG_BYTE_CAP, AppLogStore};
use crate::observability::journal::Journal;
use crate::providers::codex::daemon::CodexAppServer;
use crate::voice::speech::{SpeechClients, SpeechRelay};

use super::{HttpState, MAX_LAN_CONNECTIONS, RequestAdmission, router};

pub(super) const OPERATOR: &str = "operator-token";
pub(super) const HOST: &str = "gateway-test.local";

use crate::cluster::dialer::SpkiPin;

pub(super) struct LanHarness {
    pub(super) directory: tempfile::TempDir,
    pub(super) address: SocketAddr,
    pub(super) pin: String,
    pub(super) shutdown: CancellationToken,
    pub(super) server: tokio::task::JoinHandle<()>,
    pub(super) gateway: Arc<Gateway>,
    pub(super) state: HttpState,
    _claude: crate::providers::claude::settings::ClaudeTestSettings,
}

impl LanHarness {
    pub(super) async fn start() -> Self {
        Self::start_configured(false, RequestAdmission::default(), MAX_LAN_CONNECTIONS).await
    }

    pub(super) async fn start_scoped(account: bool) -> Self {
        Self::start_configured(account, RequestAdmission::default(), MAX_LAN_CONNECTIONS).await
    }

    pub(super) async fn start_configured(
        account: bool,
        requests: RequestAdmission,
        max_connections: usize,
    ) -> Self {
        let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
        let directory = tempfile::tempdir().unwrap();
        let journal = Journal::open_in(directory.path().join("journal"), 1);
        let identity =
            LanIdentity::load(&directory.path().join("lan-tls-key.der"), HOST.to_string()).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let gateway = Gateway::with_state_paths(
            Arc::new(CodexAppServer::new_for_test_socket(
                directory.path().join("codex"),
            )),
            claude_test.settings.clone(),
            journal.clone(),
            Some(directory.path().join("turns.json")),
            None,
            None,
        );
        let installations = InstallationCredentials::new(
            directory.path().join("installation-credentials.json"),
            gateway.cluster_link().await.unwrap().store.clone(),
        );
        let mut state = HttpState {
            full_disk_access: crate::platform::macos::full_disk_access::probe(
                &directory.path().join("TCC.db"),
                false,
            )
            .await,
            router: Arc::new(
                crate::providers::router::Router::new(claude_test.settings.router.clone()).unwrap(),
            ),
            auth_token: OPERATOR.to_string(),
            installation_credentials: installations.clone(),
            gateway,
            accounts: None,
            codex_version: "test".to_string(),
            codex_code_mode_host_path: directory.path().join("codex-code-mode-host"),
            app_logs: AppLogStore::new_in(directory.path().join("app-logs"), 1, APP_LOG_BYTE_CAP),
            uploads: UploadStore::open_in(directory.path().join("uploads")).unwrap(),
            files: FileDownloads::default(),
            speech: SpeechRelay::new(
                OPERATOR.to_string(),
                installations,
                Some(
                    crate::providers::router::RouterConfig::unreachable_for_test(
                        directory.path().join("router-key"),
                    ),
                ),
                SpeechClients::parse(None).unwrap(),
                Journal::disabled(),
            )
            .unwrap(),
            requests,
            journal,
            lan_endpoint: Some(LanEndpoint {
                host: identity.host.clone(),
                port: address.port(),
                spki_sha256: identity.spki_sha256.clone(),
            }),
            relay_route: crate::http::relay::RelayRoute::Absent,
        };
        let shutdown = CancellationToken::new();
        let gateway = if account {
            let home = directory.path().join("accounts");
            std::fs::create_dir_all(&home).unwrap();
            let accounts = crate::accounts::Accounts::open_in(
                home,
                state.gateway.clone(),
                claude_test.settings.clone(),
            )
            .await
            .unwrap();
            state.accounts = Some(accounts);
            state.gateway.clone()
        } else {
            state.gateway.clone()
        };
        gateway
            .cluster_link()
            .await
            .unwrap()
            .set_endpoint(Some(LanEndpoint {
                host: "127.0.0.1".into(),
                port: address.port(),
                spki_sha256: identity.spki_sha256.clone(),
            }))
            .await;
        let server = tokio::spawn(serve_lan(
            listener,
            identity.acceptor,
            router(state.clone()),
            shutdown.clone(),
            max_connections,
        ));
        Self {
            directory,
            address,
            pin: identity.spki_sha256,
            shutdown,
            server,
            gateway,
            state,
            _claude: claude_test,
        }
    }

    pub(super) async fn connect(&self, pin: &str) -> std::io::Result<TlsStream<TcpStream>> {
        let provider = Arc::new(ring::default_provider());
        let mut config = ClientConfig::builder_with_provider(Arc::clone(&provider))
            .with_protocol_versions(&[&TLS13])
            .unwrap()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(SpkiPin {
                pin: pin.to_string(),
                provider,
            }))
            .with_no_client_auth();
        config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
        let stream = TcpStream::connect(self.address).await?;
        TlsConnector::from(Arc::new(config))
            .connect(ServerName::try_from(HOST).unwrap(), stream)
            .await
    }

    pub(super) async fn stop(self) {
        self.shutdown.cancel();
        tokio::time::timeout(Duration::from_secs(5), self.server)
            .await
            .expect("LAN server stops after cancellation")
            .expect("LAN server task");
    }
}

pub(super) async fn exchange(
    stream: &mut TlsStream<TcpStream>,
    head: &str,
    body: &[u8],
) -> (u16, Vec<u8>) {
    stream.write_all(head.as_bytes()).await.unwrap();
    stream.write_all(body).await.unwrap();
    stream.flush().await.unwrap();
    let mut received = Vec::new();
    let head_end = loop {
        if let Some(end) = received.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
            break end + 4;
        }
        let mut chunk = [0; 4096];
        let read = stream.read(&mut chunk).await.unwrap();
        assert!(read > 0, "connection closed before the response head");
        received.extend_from_slice(&chunk[..read]);
    };
    let head = std::str::from_utf8(&received[..head_end]).unwrap();
    let status = head[9..12].parse().unwrap();
    let length: usize = head
        .lines()
        .find_map(|line| {
            let (name, value) = line.split_once(':')?;
            name.eq_ignore_ascii_case("content-length")
                .then(|| value.trim().parse().unwrap())
        })
        .unwrap_or_else(|| {
            assert_eq!(
                status, 204,
                "response declares Content-Length unless it has no content"
            );
            0
        });
    let mut response_body = received[head_end..].to_vec();
    while response_body.len() < length {
        let mut chunk = [0; 4096];
        let read = stream.read(&mut chunk).await.unwrap();
        assert!(read > 0, "connection closed before the response body");
        response_body.extend_from_slice(&chunk[..read]);
    }
    (status, response_body)
}

#[tokio::test]
async fn claude_accounts_routes_require_authorization_without_codex_availability() {
    let harness = LanHarness::start().await;
    for (method, path, body) in [
        ("GET", "/claude/accounts", ""),
        ("PUT", "/claude/accounts/preference", "{\"account\":null}"),
        ("POST", "/claude/accounts/refresh", "{}"),
    ] {
        let head = format!(
            "{method} {path} HTTP/1.1\r\nHost: {HOST}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
            body.len()
        );
        let mut stream = harness.connect(&harness.pin).await.unwrap();
        let (status, _) = exchange(&mut stream, &head, body.as_bytes()).await;
        assert_eq!(status, 401);
        let head = format!(
            "{method} {path} HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {OPERATOR}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
            body.len()
        );
        let mut stream = harness.connect(&harness.pin).await.unwrap();
        let (status, response) = exchange(&mut stream, &head, body.as_bytes()).await;
        assert_eq!(status, 503);
        let value: serde_json::Value = serde_json::from_slice(&response).unwrap();
        assert_eq!(value["error"]["code"], "router_unavailable");
    }
    use axum::{
        Json,
        http::{HeaderMap, header},
        routing::{get, post, put},
    };
    use std::os::unix::fs::PermissionsExt;
    fn inventory(preference: serde_json::Value) -> serde_json::Value {
        serde_json::json!({"accounts":[
            {"id":"second","provider":"claude","label":"Second","plan":"max","shared":true,"credential":"ready",
             "availability":"available","available_at":null,"usage":null},
            {"id":"ca4d1cbc-865c-4136-a13c-bd004f229c93","provider":"codex","label":"codex@example.test","plan":"pro",
             "shared":false,"credential":"expired","availability":"unavailable","available_at":null,"usage":null}
        ],"claude":{"automatic":"second","preference":preference},"codex":{"inventory":"ok"}})
    }
    async fn listed(headers: HeaderMap) -> Json<serde_json::Value> {
        assert_eq!(headers[header::AUTHORIZATION], "Bearer fixture-key");
        Json(inventory(serde_json::Value::Null))
    }
    async fn preferred(
        headers: HeaderMap,
        Json(body): Json<serde_json::Value>,
    ) -> axum::response::Response {
        use axum::response::IntoResponse;
        assert_eq!(headers[header::AUTHORIZATION], "Bearer fixture-key");
        assert_eq!(body["provider"], "claude");
        let refusal = match body["account"].as_str() {
            Some("missing") => Some((404, "account_not_found")),
            Some("unavailable") => Some((503, "preference_unavailable")),
            Some("unauthorized") => Some((401, "unauthorized")),
            Some("forbidden") => Some((403, "insufficient_scope")),
            Some("invalid") => Some((400, "invalid_request")),
            Some("unexpected") => Some((404, "other_missing")),
            Some("busy") => Some((503, "key_store_unavailable")),
            Some("failed") => Some((500, "internal_error")),
            Some("second") | None => None,
            Some(value) => panic!("Unexpected preferred account {value}"),
        };
        if let Some((status, code)) = refusal {
            return (
                axum::http::StatusCode::from_u16(status).unwrap(),
                Json(serde_json::json!({"error":{"code":code}})),
            )
                .into_response();
        }
        Json(inventory(body["account"].clone())).into_response()
    }
    async fn refreshed(Json(body): Json<serde_json::Value>) -> Json<serde_json::Value> {
        assert_eq!(body, serde_json::json!({}));
        Json(inventory(serde_json::json!("second")))
    }
    let key = harness.directory.path().join("router-key");
    std::fs::write(&key, "fixture-key").unwrap();
    std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).unwrap();
    let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let upstream_address = upstream.local_addr().unwrap();
    let upstream_app = axum::Router::new()
        .route("/accounts", get(listed))
        .route("/accounts/preference", put(preferred))
        .route("/accounts/refresh", post(refreshed));
    let upstream_server = tokio::spawn(async move {
        axum::serve(upstream, upstream_app).await.unwrap();
    });
    let mut state = harness.state.clone();
    state.router = Arc::new(
        crate::providers::router::Router::new(Some(
            crate::providers::router::RouterConfig::local_for_test(upstream_address, key),
        ))
        .unwrap(),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let app = router(state);
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let url = |path: &str| format!("http://{address}/claude/accounts{path}");
    for (request, preference) in [
        (client.get(url("")), serde_json::Value::Null),
        (
            client
                .put(url("/preference"))
                .json(&serde_json::json!({"account":"second"})),
            serde_json::json!("second"),
        ),
        (
            client
                .put(url("/preference"))
                .json(&serde_json::json!({"account":null})),
            serde_json::Value::Null,
        ),
        (
            client.post(url("/refresh")).json(&serde_json::json!({})),
            serde_json::json!("second"),
        ),
    ] {
        let response = request.bearer_auth(OPERATOR).send().await.unwrap();
        assert_eq!(response.status(), reqwest::StatusCode::OK);
        assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
        let value: serde_json::Value = response.json().await.unwrap();
        assert_eq!(value["automatic"], "second");
        assert_eq!(value["preference"], preference);
        assert_eq!(value["accounts"].as_array().unwrap().len(), 1);
        assert_eq!(value["accounts"][0]["plan"], "max");
        assert_eq!(value["accounts"][0]["shared"], true);
        assert_eq!(value["accounts"][0]["availability"], "available");
        assert_eq!(value["accounts"][0]["observedAt"], serde_json::Value::Null);
    }
    for (account, status, code) in [
        (serde_json::json!("missing"), 404, "account_not_found"),
        (
            serde_json::json!("unavailable"),
            503,
            "preference_unavailable",
        ),
        (
            serde_json::json!("unauthorized"),
            502,
            "router_unauthorized",
        ),
        (serde_json::json!("forbidden"), 502, "router_unauthorized"),
        (serde_json::json!("invalid"), 502, "router_invalid_request"),
        (
            serde_json::json!("unexpected"),
            502,
            "router_request_refused",
        ),
        (serde_json::json!("busy"), 503, "router_unavailable"),
        (serde_json::json!("failed"), 502, "router_request_refused"),
        (serde_json::json!("Not An Id"), 400, "invalid_request"),
        (serde_json::json!(5), 400, "invalid_request"),
    ] {
        let response = client
            .put(url("/preference"))
            .bearer_auth(OPERATOR)
            .json(&serde_json::json!({"account":account}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status);
        assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
        let value: serde_json::Value = response.json().await.unwrap();
        assert_eq!(value["error"]["code"], code);
    }
    let response = client
        .post(url("/select"))
        .bearer_auth(OPERATOR)
        .json(&serde_json::json!({"account":"second"}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), reqwest::StatusCode::NOT_FOUND);
    server.abort();
    upstream_server.abort();
    harness.stop().await;
}

#[tokio::test]
async fn reset_routes_authenticate_and_refuse_unbound_codex_before_router_submission() {
    use axum::{Json, http::StatusCode, routing::post};
    use serde_json::{Value, json};
    use std::os::unix::fs::PermissionsExt;

    let harness = LanHarness::start_scoped(true).await;
    let key = harness.directory.path().join("reset-router-key");
    std::fs::write(&key, "fixture-key").unwrap();
    std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).unwrap();
    let requests = Arc::new(std::sync::Mutex::new(Vec::new()));
    let recorded = requests.clone();
    let fake = axum::Router::new().route(
        "/accounts/resets/redeem",
        post(move |Json(body): Json<Value>| {
            let recorded = recorded.clone();
            async move {
                if body["idempotency_key"] != "e1741c43-3d9a-4448-9f4a-3c7e5906e852" {
                    return (
                        StatusCode::BAD_REQUEST,
                        Json(json!({"error":{"code":"invalid_request"}})),
                    );
                }
                recorded.lock().unwrap().push(body);
                (
                    StatusCode::OK,
                    Json(json!({"outcome":"refused","reason":"noCredit"})),
                )
            }
        }),
    );
    let (upstream, upstream_server) = crate::test_support::serve(fake).await;
    let mut state = harness.state.clone();
    state.router = Arc::new(
        crate::providers::router::Router::new(Some(
            crate::providers::router::RouterConfig::local_for_test(upstream, key),
        ))
        .unwrap(),
    );
    let (gateway, server) = crate::test_support::serve(super::router(state)).await;
    let client = reqwest::Client::new();
    let attempt = json!({"resetId":"offer","idempotencyKey":"E1741C43-3D9A-4448-9F4A-3C7E5906E852","generation":1});
    let url =
        format!("http://{gateway}/accounts/e1741c43-3d9a-4448-9f4a-3c7e5906e852/resets/redeem");
    assert_eq!(
        client
            .post(&url)
            .json(&attempt)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
    for path in [&format!(
        "http://{gateway}/accounts/default-codex/resets/redeem"
    )] {
        let mut changed = attempt.clone();
        changed["generation"] = json!(2);
        let refused = client
            .post(path)
            .bearer_auth(OPERATOR)
            .json(&changed)
            .send()
            .await
            .unwrap();
        assert_eq!(refused.status(), StatusCode::CONFLICT);
        assert_eq!(
            refused.json::<Value>().await.unwrap()["error"]["code"],
            "reset_account_changed"
        );
    }
    let refused = client
        .post(&url)
        .bearer_auth(OPERATOR)
        .json(&attempt)
        .send()
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::NOT_FOUND);
    assert_eq!(
        refused.json::<Value>().await.unwrap()["error"]["code"],
        "account_not_found"
    );
    assert!(requests.lock().unwrap().is_empty());
    for (path, body, provider, account) in [
        (
            "/accounts/default-codex/resets/redeem",
            attempt.clone(),
            "codex",
            "workspace-a",
        ),
        (
            "/claude/accounts/resets/redeem",
            json!({"accountId":"first","resetId":"offer","idempotencyKey":"E1741C43-3D9A-4448-9F4A-3C7E5906E852"}),
            "claude",
            "first",
        ),
    ] {
        let response = client
            .post(format!("http://{gateway}{path}"))
            .bearer_auth(OPERATOR)
            .json(&body)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.json::<Value>().await.unwrap(),
            json!({"outcome":"refused","reason":"noCredit"})
        );
        assert_eq!(
            requests.lock().unwrap().last().unwrap(),
            &json!({"provider":provider,"account_id":account,"reset_id":"offer","idempotency_key":"e1741c43-3d9a-4448-9f4a-3c7e5906e852"})
        );
    }
    assert_eq!(requests.lock().unwrap().len(), 2);
    server.abort();
    upstream_server.abort();
    harness.shutdown.cancel();
    harness.server.await.unwrap();
}

#[tokio::test]
async fn claude_reset_replies_before_its_tracked_claude_only_refresh_without_enrollments() {
    use axum::{Json, routing::post};
    use serde_json::{Value, json};
    use std::os::unix::fs::PermissionsExt;
    let harness = LanHarness::start().await;
    let key = harness.directory.path().join("reset-router-key");
    std::fs::write(&key, "fixture-key").unwrap();
    std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).unwrap();
    let entered = Arc::new(tokio::sync::Semaphore::new(0));
    let release = Arc::new(tokio::sync::Semaphore::new(0));
    let finished = Arc::new(tokio::sync::Semaphore::new(0));
    let backend = axum::Router::new()
        .route(
            "/accounts/resets/redeem",
            post(|| async { Json(json!({"outcome":"reset","reason":null})) }),
        )
        .route(
            "/claude/accounts/refresh",
            post({
                let entered = entered.clone();
                let release = release.clone();
                let finished = finished.clone();
                move || {
                    let (entered, release, finished) =
                        (entered.clone(), release.clone(), finished.clone());
                    async move {
                        entered.add_permits(1);
                        release.acquire().await.unwrap().forget();
                        finished.add_permits(1);
                        Json(json!({}))
                    }
                }
            }),
        );
    let (upstream, backend_server) = crate::test_support::serve(backend).await;
    let mut state = harness.state.clone();
    assert!(state.accounts.is_none());
    state.router = Arc::new(
        crate::providers::router::Router::new(Some(
            crate::providers::router::RouterConfig::local_for_test(upstream, key),
        ))
        .unwrap(),
    );
    let (address, server) = crate::test_support::serve(super::router(state)).await;
    let unavailable = reqwest::Client::new()
        .post(format!("http://{address}/accounts/default-codex/resets/redeem"))
        .bearer_auth(OPERATOR)
        .json(&json!({"resetId":"offer","idempotencyKey":"e1741c43-3d9a-4448-9f4a-3c7e5906e852","generation":1}))
        .send().await.unwrap();
    assert_eq!(
        unavailable.status(),
        reqwest::StatusCode::SERVICE_UNAVAILABLE
    );
    assert_eq!(
        unavailable.json::<Value>().await.unwrap()["error"]["code"],
        "account_management_unavailable"
    );
    let result = tokio::time::timeout(Duration::from_secs(2), reqwest::Client::new()
        .post(format!("http://{address}/claude/accounts/resets/redeem"))
        .bearer_auth(OPERATOR)
        .json(&json!({"accountId":"first","resetId":"offer","idempotencyKey":"e1741c43-3d9a-4448-9f4a-3c7e5906e852"}))
        .send()).await.unwrap().unwrap();
    assert_eq!(result.status(), reqwest::StatusCode::OK);
    assert_eq!(
        result.json::<Value>().await.unwrap(),
        json!({"outcome":"reset","reason":null})
    );
    tokio::time::timeout(Duration::from_secs(2), entered.acquire())
        .await
        .unwrap()
        .unwrap()
        .forget();
    release.add_permits(1);
    tokio::time::timeout(Duration::from_secs(2), finished.acquire())
        .await
        .unwrap()
        .unwrap()
        .forget();
    harness.gateway.stop().await.unwrap();
    server.abort();
    backend_server.abort();
    harness.shutdown.cancel();
    harness.server.await.unwrap();
}

#[tokio::test]
async fn codex_reset_outlives_its_client_and_gateway_stop_waits_for_its_refresh_admission() {
    use axum::{Json, routing::post};
    use serde_json::json;
    use std::os::unix::fs::PermissionsExt;
    let harness = LanHarness::start_scoped(true).await;
    let key = harness.directory.path().join("reset-router-key");
    std::fs::write(&key, "fixture-key").unwrap();
    std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).unwrap();
    let (entered, entered_rx) = tokio::sync::oneshot::channel();
    let entered = Arc::new(std::sync::Mutex::new(Some(entered)));
    let release = Arc::new(tokio::sync::Semaphore::new(0));
    let backend = axum::Router::new().route(
        "/accounts/resets/redeem",
        post({
            let release = release.clone();
            move || {
                let (entered, release) = (entered.clone(), release.clone());
                async move {
                    entered.lock().unwrap().take().unwrap().send(()).unwrap();
                    release.acquire().await.unwrap().forget();
                    Json(json!({"outcome":"reset","reason":null}))
                }
            }
        }),
    );
    let (upstream, backend_server) = crate::test_support::serve(backend).await;
    let mut state = harness.state.clone();
    let gateway = state.gateway.clone();
    let accounts = state.accounts.clone().unwrap();
    state.router = Arc::new(
        crate::providers::router::Router::new(Some(
            crate::providers::router::RouterConfig::local_for_test(upstream, key),
        ))
        .unwrap(),
    );
    let observations = harness
        .directory
        .path()
        .join("accounts/.remote-coder/account-usage.json");
    assert!(!observations.exists());
    let (address, server) = crate::test_support::serve(super::router(state)).await;
    let request = tokio::spawn(async move {
        reqwest::Client::new()
            .post(format!("http://{address}/accounts/default-codex/resets/redeem"))
            .bearer_auth(OPERATOR)
            .json(&json!({"resetId":"offer","idempotencyKey":"e1741c43-3d9a-4448-9f4a-3c7e5906e852","generation":1}))
            .send().await
    });
    tokio::time::timeout(Duration::from_secs(2), entered_rx)
        .await
        .unwrap()
        .unwrap();
    request.abort();
    assert!(request.await.unwrap_err().is_cancelled());
    let mut stopping = tokio::spawn(async move { gateway.stop().await });
    assert!(
        tokio::time::timeout(Duration::from_millis(100), &mut stopping)
            .await
            .is_err()
    );
    release.add_permits(1);
    tokio::time::timeout(Duration::from_secs(2), stopping)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    accounts.refresh_settled(Duration::from_secs(2)).await;
    let observations: serde_json::Value =
        serde_json::from_slice(&std::fs::read(observations).unwrap()).unwrap();
    assert_eq!(observations["default-codex"]["windows"], json!([]));
    assert_eq!(observations["default-codex"]["resets"], json!(null));
    assert_eq!(observations["default-codex"]["stale"], json!(true));
    accounts.stop().await;
    harness.gateway.stop().await.unwrap();
    server.abort();
    backend_server.abort();
    harness.shutdown.cancel();
    harness.server.await.unwrap();
}
