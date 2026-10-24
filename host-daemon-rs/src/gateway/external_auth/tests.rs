use super::*;
use crate::notifications::history::NotificationOrigin;
use crate::providers::claude::settings::ClaudeSettings;
use crate::providers::codex::daemon::CodexAppServer;
use crate::providers::router::RouterConfig;
use crate::test_support::{FakeControl, TestGateway};
use axum::{Json, Router as HttpRouter, extract::State, routing::post};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use tokio::sync::Notify;

struct Backend {
    requests: AtomicUsize,
    hold: AtomicBool,
    wrong: AtomicBool,
    same: AtomicBool,
    initial: Value,
    entered: Notify,
    release: Notify,
    quota: std::sync::Mutex<Option<Value>>,
    quota_entered: tokio::sync::Semaphore,
    quota_release: tokio::sync::Semaphore,
}

async fn issue(State(backend): State<Arc<Backend>>) -> Json<Value> {
    Json(backend.initial.clone())
}

async fn renew(State(backend): State<Arc<Backend>>, Json(body): Json<Value>) -> Json<Value> {
    assert_eq!(body["account_id"], "workspace-a");
    assert_eq!(body["generation"].as_str().unwrap().len(), 64);
    backend.requests.fetch_add(1, Ordering::SeqCst);
    backend.entered.notify_one();
    if backend.hold.load(Ordering::SeqCst) {
        backend.release.notified().await;
    }
    if backend.same.load(Ordering::SeqCst) {
        return Json(backend.initial.clone());
    }
    Json(token(
        if backend.wrong.load(Ordering::SeqCst) {
            "workspace-b"
        } else {
            "workspace-a"
        },
        "renewed",
    ))
}

fn token(account: &str, label: &str) -> Value {
    let expiry = time::OffsetDateTime::now_utc() + time::Duration::hours(2);
    let claims = json!({"exp":expiry.unix_timestamp(),"label":label,
        "https://api.openai.com/auth":{"chatgpt_account_id":account}});
    let access = format!("e30.{}.fixture", URL_SAFE_NO_PAD.encode(claims.to_string()));
    json!({"access_token":access, "account_id":account, "plan_type":"pro",
        "expires_at":expiry.format(&time::format_description::well_known::Rfc3339).unwrap(),
        "generation":format!("{:x}", Sha256::digest(access.as_bytes()))})
}

struct Fixture {
    gateway: Arc<Gateway>,
    backend: Arc<Backend>,
    server: tokio::task::JoinHandle<()>,
    _directory: tempfile::TempDir,
    _host: TestGateway,
    claude: crate::providers::claude::settings::ClaudeTestSettings,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.server.abort();
    }
}

impl Fixture {
    async fn serve_router(
        directory: &std::path::Path,
    ) -> (Arc<Backend>, tokio::task::JoinHandle<()>, RouterConfig) {
        use std::os::unix::fs::PermissionsExt;
        let key = directory.join("key");
        std::fs::write(&key, "fixture-key").unwrap();
        std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let backend = Arc::new(Backend {
            requests: AtomicUsize::new(0),
            hold: AtomicBool::new(false),
            wrong: AtomicBool::new(false),
            same: AtomicBool::new(false),
            initial: token("workspace-a", "initial"),
            entered: Notify::new(),
            release: Notify::new(),
            quota: std::sync::Mutex::new(None),
            quota_entered: tokio::sync::Semaphore::new(0),
            quota_release: tokio::sync::Semaphore::new(0),
        });
        let app = HttpRouter::new()
            .route("/codex/token", post(issue))
            .route("/codex/renew", post(renew))
            .route(
                "/codex/quota",
                post(|State(backend): State<Arc<Backend>>| async move {
                    let value = backend.quota.lock().unwrap().clone();
                    match value {
                        Some(value) => {
                            backend.quota_entered.add_permits(1);
                            backend.quota_release.acquire().await.unwrap().forget();
                            (axum::http::StatusCode::OK, Json(value))
                        }
                        None => (
                            axum::http::StatusCode::NOT_FOUND,
                            Json(json!({"error":{"code":"account_not_found"}})),
                        ),
                    }
                }),
            )
            .with_state(Arc::clone(&backend));
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (backend, server, RouterConfig::local_for_test(address, key))
    }

    async fn host_default() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let (backend, server, config) = Self::serve_router(directory.path()).await;
        let claude = ClaudeSettings::isolated_for_test();
        let journal = crate::observability::journal::Journal::disabled();
        let gateway = Gateway::with_notifier(
            Arc::new(CodexAppServer::new_for_test_socket(
                directory.path().join("c"),
            )),
            Arc::new(crate::push::PushService::new(
                false,
                journal.clone(),
                Arc::new(crate::devices::DeviceRegistry::temporary()),
                None,
            )),
            claude.settings.clone(),
            journal,
            directory.path().join("state"),
            None,
            Some(super::ExternalAuth::new(
                crate::providers::codex::router::Router::for_test(config),
                "workspace-a".into(),
            )),
            None,
            None,
        );
        Self {
            gateway,
            backend,
            server,
            _directory: directory,
            _host: TestGateway::new(),
            claude,
        }
    }

    async fn new() -> Self {
        Self::host_default().await
    }

    async fn authenticate(&self, control: &mut FakeControl) {
        let gateway = Arc::clone(&self.gateway);
        let generation = gateway.control.current().unwrap();
        let task = tokio::spawn(async move { gateway.authenticate_external(&generation).await });
        let request: Value = serde_json::from_str(
            &tokio::time::timeout(Duration::from_secs(2), control.requests.recv())
                .await
                .unwrap()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(request["method"], "account/login/start");
        assert_eq!(request["params"]["type"], "chatgptAuthTokens");
        assert_eq!(request["params"]["chatgptAccountId"], "workspace-a");
        assert!(self.gateway.require_external_auth().await.is_err());
        self.gateway
            .handle_control_text(
                json!({"id":request["id"],"result":{"type":"chatgptAuthTokens"}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        task.await.unwrap().unwrap();
        self.gateway.require_external_auth().await.unwrap();
    }

    async fn callback(&self, id: i64) {
        self.gateway
            .handle_control_text(
                json!({"id":id,"method":REFRESH_METHOD,
            "params":{"reason":"unauthorized","previousAccountId":"workspace-a"}})
                .to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
    }
}

#[tokio::test]
async fn login_must_complete_before_admission_and_a_new_connection_must_log_in_again() {
    let fixture = Fixture::new().await;
    let mut control = FakeControl::attach(&fixture.gateway, 8).await;
    fixture.authenticate(&mut control).await;
    fixture.gateway.control.retire().await;
    assert!(fixture.gateway.require_external_auth().await.is_err());
    let mut replacement = FakeControl::attach(&fixture.gateway, 8).await;
    assert!(fixture.gateway.require_external_auth().await.is_err());
    fixture.authenticate(&mut replacement).await;
    fixture.gateway.control.retire().await;
}

#[tokio::test]
async fn concurrent_callbacks_share_one_rotation_and_the_broker_keeps_receiving() {
    let fixture = Fixture::new().await;
    let mut control = FakeControl::attach(&fixture.gateway, 8).await;
    fixture.authenticate(&mut control).await;
    fixture.backend.hold.store(true, Ordering::SeqCst);
    fixture.callback(41).await;
    fixture.backend.entered.notified().await;
    tokio::time::timeout(Duration::from_millis(200), fixture.callback(42))
        .await
        .unwrap();
    fixture.backend.release.notify_one();
    let login: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
    assert_eq!(login["method"], "account/login/start");
    fixture
        .gateway
        .handle_control_text(
            json!({"id":login["id"],"result":{"type":"chatgptAuthTokens"}}).to_string(),
            NotificationOrigin::Control { opened_after: 0 },
        )
        .await;
    let first: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
    let second: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
    assert_eq!(first["result"], second["result"]);
    assert_eq!(first["result"]["chatgptAccountId"], "workspace-a");
    assert_eq!(fixture.backend.requests.load(Ordering::SeqCst), 1);
    assert!(first.get("error").is_none());
    fixture.gateway.control.retire().await;
}

#[tokio::test]
async fn retiring_the_owner_cancels_renewal_without_publishing_to_the_replacement() {
    let fixture = Fixture::new().await;
    let mut control = FakeControl::attach(&fixture.gateway, 8).await;
    fixture.authenticate(&mut control).await;
    fixture.backend.hold.store(true, Ordering::SeqCst);
    fixture.callback(41).await;
    fixture.backend.entered.notified().await;
    fixture.gateway.control.retire().await;
    let mut replacement = FakeControl::attach(&fixture.gateway, 8).await;
    fixture.backend.release.notify_one();
    assert!(
        tokio::time::timeout(Duration::from_millis(100), replacement.requests.recv())
            .await
            .is_err()
    );
    assert!(fixture.gateway.require_external_auth().await.is_err());
    fixture.gateway.control.retire().await;
}

#[tokio::test]
async fn a_slow_router_gets_a_failure_within_the_native_refresh_deadline() {
    let fixture = Fixture::new().await;
    let mut control = FakeControl::attach(&fixture.gateway, 8).await;
    fixture.authenticate(&mut control).await;
    fixture.backend.hold.store(true, Ordering::SeqCst);
    fixture.callback(41).await;
    fixture.backend.entered.notified().await;
    let response = tokio::time::timeout(Duration::from_millis(7500), control.requests.recv())
        .await
        .unwrap()
        .unwrap();
    let response: Value = serde_json::from_str(&response).unwrap();
    assert_eq!(response["id"], 41);
    assert_eq!(response["error"]["code"], -32603);
    assert!(response.get("result").is_none());
    fixture.backend.release.notify_one();
    assert!(
        tokio::time::timeout(Duration::from_millis(100), control.requests.recv())
            .await
            .is_err()
    );
    assert!(fixture.gateway.external_auth_error().is_some());
    fixture.gateway.control.retire().await;
}

#[tokio::test]
async fn wrong_account_renewal_fails_without_installing_or_returning_its_bearer() {
    let fixture = Fixture::new().await;
    let mut control = FakeControl::attach(&fixture.gateway, 8).await;
    fixture.authenticate(&mut control).await;
    fixture.backend.wrong.store(true, Ordering::SeqCst);
    fixture.callback(41).await;
    let response: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
    assert_eq!(response["error"]["code"], -32603);
    assert!(response.get("result").is_none());
    let owner = fixture.gateway.control.current().unwrap();
    assert_eq!(
        owner
            .auth
            .lock()
            .unwrap()
            .token
            .as_ref()
            .unwrap()
            .account_id,
        "workspace-a"
    );
    assert!(owner.auth.lock().unwrap().error.is_some());
    fixture.gateway.control.retire().await;
}

#[tokio::test]
async fn an_expired_in_memory_token_refuses_turns_and_voice_before_native_dispatch() {
    let fixture = Fixture::new().await;
    let mut control = FakeControl::attach(&fixture.gateway, 8).await;
    fixture.authenticate(&mut control).await;
    let owner = fixture.gateway.control.current().unwrap();
    owner
        .auth
        .lock()
        .unwrap()
        .token
        .as_mut()
        .unwrap()
        .expires_at = (time::OffsetDateTime::now_utc() - time::Duration::seconds(1))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    for method in ["turn/start", "voice/session/start"] {
        let object = json!({"id":1,"method":method,"params":{}})
            .as_object()
            .unwrap()
            .clone();
        let error = fixture
            .gateway
            .account_request_error(method, &object)
            .await
            .unwrap();
        assert!(error.contains("expired"));
    }
    assert!(control.requests.try_recv().is_err());
    fixture.gateway.control.retire().await;
}

#[tokio::test]
async fn consumer_auth_mutations_and_bearer_export_are_refused_before_native_dispatch() {
    let fixture = Fixture::new().await;
    for (method, params) in [
        ("account/login/start", json!({"type":"chatgptAuthTokens"})),
        ("account/logout", json!({})),
        ("getAuthStatus", json!({"includeToken":true})),
    ] {
        let object = json!({"id":1,"method":method,"params":params})
            .as_object()
            .unwrap()
            .clone();
        let error = fixture
            .gateway
            .account_request_error(method, &object)
            .await
            .unwrap();
        assert!(error.contains("llm-router"));
    }
    let object = json!({"id":1,"params":{"includeToken":false}})
        .as_object()
        .unwrap()
        .clone();
    assert!(
        fixture
            .gateway
            .account_request_error("getAuthStatus", &object)
            .await
            .is_none()
    );
}

#[tokio::test]
async fn unchanged_rejected_generation_fails_without_reinstalling_the_token() {
    let fixture = Fixture::new().await;
    let mut control = FakeControl::attach(&fixture.gateway, 8).await;
    fixture.authenticate(&mut control).await;
    fixture.backend.same.store(true, Ordering::SeqCst);
    fixture.callback(41).await;
    let response: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
    assert_eq!(response["id"], 41);
    assert!(
        response["error"]["message"]
            .as_str()
            .unwrap()
            .contains("rejected token generation")
    );
    assert!(response.get("result").is_none());
    assert!(fixture.gateway.external_auth_error().is_some());
    assert!(control.requests.try_recv().is_err());
    fixture.gateway.control.retire().await;
}

#[tokio::test]
async fn native_partitions_ignore_refresh_without_answering() {
    let host = TestGateway::new();
    let mut control = FakeControl::attach(&host, 8).await;
    let message =
        json!({"id":41,"method":REFRESH_METHOD,"params":{"previousAccountId":"workspace-a"}});
    assert!(!host.handle_external_refresh(&message).await);
    host.handle_control_text(
        message.to_string(),
        NotificationOrigin::Control { opened_after: 0 },
    )
    .await;
    assert!(
        tokio::time::timeout(Duration::from_millis(100), control.requests.recv())
            .await
            .is_err()
    );
    host.control.retire().await;
}

#[tokio::test]
async fn router_outage_does_not_block_resume_or_turn_admission_with_valid_installed_auth() {
    let fixture = Fixture::new().await;
    let mut control = FakeControl::attach(&fixture.gateway, 8).await;
    fixture.authenticate(&mut control).await;
    fixture.server.abort();
    fixture
        .gateway
        .control
        .current()
        .unwrap()
        .auth
        .lock()
        .unwrap()
        .error = Some("router unavailable".into());
    for method in ["thread/resume", "turn/start"] {
        let object = json!({"id":1,"params":{}}).as_object().unwrap().clone();
        assert!(
            tokio::time::timeout(
                Duration::from_secs(2),
                fixture.gateway.account_request_error(method, &object),
            )
            .await
            .unwrap()
            .is_none()
        );
        assert!(control.requests.try_recv().is_err());
    }
    fixture.gateway.control.retire().await;
}

#[tokio::test]
async fn the_host_default_runs_on_router_tokens_and_refuses_native_sign_in() {
    let fixture = Fixture::host_default().await;
    let turn = json!({"id":1,"method":"turn/start","params":{}})
        .as_object()
        .unwrap()
        .clone();
    assert!(
        fixture
            .gateway
            .account_request_error("turn/start", &turn)
            .await
            .is_some()
    );
    let mut control = FakeControl::attach(&fixture.gateway, 8).await;
    fixture.authenticate(&mut control).await;
    assert!(
        fixture
            .gateway
            .account_request_error("turn/start", &turn)
            .await
            .is_none()
    );
    fixture.gateway.control.retire().await;
    let claude = json!({"id":1,"method":"turn/start","params":{"threadId":"claude_0f5c2b8e-6d0e-4c43-9d54-2b1f0d6a7e11"}})
        .as_object()
        .unwrap()
        .clone();
    assert!(
        fixture
            .gateway
            .account_request_error("turn/start", &claude)
            .await
            .is_none()
    );
    assert!(
        fixture
            .gateway
            .account_request_error("turn/start", &turn)
            .await
            .is_some()
    );
    for method in ["account/login/start", "account/logout"] {
        let object = json!({"id":1,"method":method,"params":{"type":"chatgpt"}})
            .as_object()
            .unwrap()
            .clone();
        let error = fixture
            .gateway
            .account_request_error(method, &object)
            .await
            .unwrap();
        assert!(error.contains("llm-router"));
    }
    assert!(control.requests.try_recv().is_err());
}

#[tokio::test]
async fn a_failed_host_quota_read_keeps_only_the_verified_accounts_recent_usage() {
    use crate::accounts::types::{AccountSnapshot, AccountState, DEFAULT_CODEX, UsageWindow};
    let fixture = Fixture::host_default().await;
    let mut control = FakeControl::attach(&fixture.gateway, 8).await;
    fixture.authenticate(&mut control).await;
    let account =
        json!({"account":{"type":"chatgpt","email":"fixture@example.test","planType":"pro"}});
    let verified = crate::accounts::codex_identity_in_workspace(&account, "workspace-a");
    for (seeded_workspace, age, retained) in [
        ("workspace-a", 60.0, true),
        ("workspace-b", 60.0, false),
        ("workspace-a", 1801.0, false),
    ] {
        let observed = crate::time::unix_seconds() - age;
        let home = tempfile::tempdir().unwrap();
        let paths = crate::config::HostPaths::from_home(home.path().to_path_buf()).unwrap();
        let seeded = AccountSnapshot {
            id: DEFAULT_CODEX.into(),
            provider: crate::providers::Provider::Codex,
            label: "Host default · ChatGPT".into(),
            enabled: true,
            generation: 1,
            is_default: true,
            identity: crate::accounts::codex_identity_in_workspace(&account, seeded_workspace),
            plan: Some("pro".into()),
            state: AccountState::Ready,
            windows: vec![UsageWindow {
                id: "codex:primary".into(),
                label: "Weekly".into(),
                duration_minutes: Some(10080),
                used_percent: 66.0,
                resets_at: None,
                model: None,
            }],
            resets: crate::accounts::resets::from_router(Some(
                json!({"state":"known","available":5,"offers":null,"error":null}),
            )),
            observed_at: Some(observed),
            stale: false,
            error: None,
            active_turns: 0,
            incoming_call_routing_id: None,
        };
        let usage = paths.state("account-usage.json");
        std::fs::create_dir_all(usage.parent().unwrap()).unwrap();
        std::fs::write(
            &usage,
            serde_json::to_vec(&json!({ DEFAULT_CODEX: seeded })).unwrap(),
        )
        .unwrap();
        let accounts = crate::accounts::Accounts::open(
            &paths,
            Arc::clone(&fixture.gateway),
            fixture.claude.settings.clone(),
        )
        .await
        .unwrap();
        assert!(accounts.directory().await.accounts[0].resets.is_none());
        accounts.start_refresh().await;
        let request: Value = serde_json::from_str(
            &tokio::time::timeout(Duration::from_secs(2), control.requests.recv())
                .await
                .unwrap()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(request["method"], "account/read");
        fixture
            .gateway
            .handle_control_text(
                json!({"id":request["id"],"result":account}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        accounts.refresh_settled(Duration::from_secs(10)).await;
        let directory = accounts.directory().await;
        let row = directory
            .accounts
            .iter()
            .find(|row| row.id == DEFAULT_CODEX)
            .unwrap();
        assert_eq!(row.state, AccountState::Ready);
        assert!(row.stale);
        assert_eq!(row.identity, verified);
        if retained {
            assert_eq!(row.observed_at, Some(observed));
            assert_eq!(row.windows.len(), 1);
            assert_eq!(row.windows[0].used_percent, 66.0);
        } else {
            assert!(row.windows.is_empty());
            assert!(row.observed_at.is_none());
        }
    }
    fixture.gateway.control.retire().await;
}

#[tokio::test]
async fn an_auth_change_outside_the_gateway_reinstalls_router_tokens() {
    let fixture = Fixture::host_default().await;
    let mut control = FakeControl::attach(&fixture.gateway, 8).await;
    fixture.authenticate(&mut control).await;
    let notify = |mode: Value| {
        json!({"method":"account/updated","params":{"authMode":mode,"planType":"pro"}}).to_string()
    };
    fixture
        .gateway
        .handle_control_text(
            notify(json!("chatgptAuthTokens")),
            NotificationOrigin::Control { opened_after: 0 },
        )
        .await;
    assert!(
        tokio::time::timeout(Duration::from_millis(100), control.requests.recv())
            .await
            .is_err()
    );
    for mode in [Value::Null, json!("chatgpt")] {
        fixture
            .gateway
            .handle_control_text(
                notify(mode),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        assert!(fixture.gateway.external_auth_error().is_some());
        let login: Value = serde_json::from_str(
            &tokio::time::timeout(Duration::from_secs(2), control.requests.recv())
                .await
                .unwrap()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(login["method"], "account/login/start");
        assert_eq!(login["params"]["type"], "chatgptAuthTokens");
        assert_eq!(login["params"]["chatgptAccountId"], "workspace-a");
        fixture
            .gateway
            .handle_control_text(
                json!({"id":login["id"],"result":{"type":"chatgptAuthTokens"}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        tokio::time::timeout(Duration::from_secs(2), async {
            while fixture.gateway.external_auth_error().is_some() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }
    fixture.gateway.control.retire().await;
}

#[tokio::test]
async fn reset_refresh_repeats_after_another_redemption_and_uses_normalized_router_resets() {
    use crate::accounts::types::{AccountState, DEFAULT_CODEX};
    let fixture = Fixture::host_default().await;
    let mut control = FakeControl::attach(&fixture.gateway, 8).await;
    fixture.authenticate(&mut control).await;
    let home = tempfile::tempdir().unwrap();
    let paths = crate::config::HostPaths::from_home(home.path().to_path_buf()).unwrap();
    let accounts = crate::accounts::Accounts::open(
        &paths,
        fixture.gateway.clone(),
        fixture.claude.settings.clone(),
    )
    .await
    .unwrap();
    let quota = |resets: Value| {
        json!({
            "account_id":"workspace-a",
            "rate_limits":{"accountId":"workspace-a","rateLimitResetCredits":{"availableCount":99,"credits":null},
                "rateLimits":{"primary":{"usedPercent":44,"windowDurationMins":10080}}},
            "resets":resets,
        })
    };
    *fixture.backend.quota.lock().unwrap() = Some(quota(
        json!({"state":"known","observed_at":"2026-10-17T07:00:00Z","available":2,"offers":null,"error":null}),
    ));
    accounts.refresh_reset_account(DEFAULT_CODEX.into());
    answer_reset_account(&fixture.gateway, &mut control).await;
    fixture
        .backend
        .quota_entered
        .acquire()
        .await
        .unwrap()
        .forget();
    accounts.refresh_reset_account(DEFAULT_CODEX.into());
    *fixture.backend.quota.lock().unwrap() = Some(quota(
        json!({"state":"known","observed_at":"2026-10-17T08:00:00Z","available":0,"offers":[],"error":null}),
    ));
    fixture.backend.quota_release.add_permits(1);
    answer_reset_account(&fixture.gateway, &mut control).await;
    fixture
        .backend
        .quota_entered
        .acquire()
        .await
        .unwrap()
        .forget();
    let pending = accounts.directory().await;
    assert!(pending.refreshing);
    assert!(pending.accounts[0].resets.is_none());
    assert!(pending.accounts[0].windows.is_empty());
    assert!(pending.accounts[0].stale);
    fixture.backend.quota_release.add_permits(1);
    accounts.refresh_settled(Duration::from_secs(2)).await;
    let settled = accounts.directory().await;
    assert!(!settled.refreshing);
    assert!(!settled.accounts[0].stale);
    assert_eq!(settled.accounts[0].state, AccountState::Ready);
    assert_eq!(settled.accounts[0].windows[0].used_percent, 44.0);
    let resets = serde_json::to_value(&settled.accounts[0].resets).unwrap();
    assert_eq!(
        resets,
        json!({"state":"known","observedAt":1792224000.0,"available":0,"offers":[],"error":null})
    );

    for value in [
        json!({"state":"known","available":-1}),
        Value::Null,
        json!({"state":"known","available":3,"observed_at":"2026-10-17T08:00:00Z","offers":[{"id":"nonexpiring","title":null,"remaining":1,"expires_at":null,"usable_now":null,"requires_limit":null,"clears":null}]}),
    ] {
        *fixture.backend.quota.lock().unwrap() = Some(quota(value.clone()));
        accounts.refresh_reset_account(DEFAULT_CODEX.into());
        answer_reset_account(&fixture.gateway, &mut control).await;
        fixture
            .backend
            .quota_entered
            .acquire()
            .await
            .unwrap()
            .forget();
        fixture.backend.quota_release.add_permits(1);
        accounts.refresh_settled(Duration::from_secs(2)).await;
        let row = accounts.directory().await.accounts.remove(0);
        assert_eq!(row.state, AccountState::Ready);
        assert_eq!(row.windows[0].used_percent, 44.0);
        let resets = serde_json::to_value(row.resets).unwrap();
        if value.is_null() {
            assert!(resets.is_null());
        } else if value["available"] == -1 {
            assert_eq!(
                resets,
                json!({"state":"unavailable","observedAt":null,"available":null,"offers":null,"error":"upstream_unavailable"})
            );
        } else {
            assert_eq!(resets["available"], 3);
            assert_eq!(resets["offers"][0]["expiresAt"], Value::Null);
            assert_eq!(resets["offers"][0]["usableNow"], Value::Null);
        }
    }
    accounts.stop().await;
    fixture.gateway.control.retire().await;
}

async fn answer_reset_account(gateway: &Arc<Gateway>, control: &mut FakeControl) {
    let request: Value = serde_json::from_str(
        &tokio::time::timeout(Duration::from_secs(2), control.requests.recv())
            .await
            .unwrap()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(request["method"], "account/read");
    gateway.handle_control_text(json!({"id":request["id"],"result":{"account":{"type":"chatgpt","email":"fixture@example.test","planType":"pro"}}}).to_string(), NotificationOrigin::Control { opened_after: 0 }).await;
}
