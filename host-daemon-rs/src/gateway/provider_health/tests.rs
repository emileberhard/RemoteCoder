use super::*;

#[test]
fn health_matches_the_shared_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../protocol-fixtures/providers/provider-health.json"
    ))
    .unwrap();
    let health = ProviderHealth {
        codex: CodexHealth::Fallback {
            reason: CODEX_SIGN_IN_FAILED.into(),
            fallback: "copilot".into(),
        },
        claude: Some(ClaudeHealth::Unavailable {
            reason: "Claude Code is not signed in on mac-mini".into(),
        }),
    };

    assert_eq!(fixture["method"], PROVIDER_HEALTH_METHOD);
    assert_eq!(fixture["params"], json!({"providers": health}));
}

use crate::notifications::history::NotificationOrigin;
use crate::test_support::{FakeControl, TestGateway};

async fn reply(gateway: &Arc<Gateway>, control: &mut FakeControl, result: Value) {
    let raw = tokio::time::timeout(Duration::from_secs(2), control.requests.recv())
        .await
        .unwrap()
        .unwrap();
    let request: Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(request["method"], "account/read");
    gateway
        .handle_control_text(
            json!({"id":request["id"], "result": result}).to_string(),
            NotificationOrigin::Control { opened_after: 0 },
        )
        .await;
}

#[tokio::test]
async fn native_account_evidence_drives_both_admission_and_health() {
    let gateway = TestGateway::new();
    let mut control = FakeControl::attach(&gateway, 8).await;
    *gateway.control_init_result.lock().await = Some(json!({}));
    for (account, available, health) in [
        (
            json!({"requiresOpenaiAuth":true, "account":null}),
            false,
            CodexHealth::Unavailable {
                reason: "Codex is not signed in".into(),
            },
        ),
        (
            json!({"requiresOpenaiAuth":true, "account":{"type":"apiKey"}}),
            true,
            CodexHealth::Ready,
        ),
        (
            json!({"requiresOpenaiAuth":false, "account":null}),
            true,
            CodexHealth::Ready,
        ),
    ] {
        let (result, ()) = tokio::join!(
            gateway.codex_first_party_available(),
            reply(&gateway, &mut control, account)
        );
        assert_eq!(result.unwrap(), available);
        assert_eq!(gateway.published_codex_health(), health);
    }
}

#[tokio::test]
async fn malformed_account_evidence_is_unknown_and_never_admits_fallback() {
    let gateway = TestGateway::new();
    let mut control = FakeControl::attach(&gateway, 8).await;
    *gateway.control_init_result.lock().await = Some(json!({}));
    for account in [
        json!({}),
        json!({"requiresOpenaiAuth":true}),
        json!({"requiresOpenaiAuth":true, "account":false}),
    ] {
        let (result, ()) = tokio::join!(
            gateway.codex_first_party_available(),
            reply(&gateway, &mut control, account)
        );
        let error = result.unwrap_err();
        assert_eq!(error.data, RpcData::RetryAfterMs(RETRY_AFTER_MS));
        assert_eq!(
            gateway.published_codex_health(),
            CodexHealth::Unavailable {
                reason: "Codex authentication availability is unknown".into(),
            }
        );
    }
}

#[tokio::test]
async fn transient_control_states_keep_their_reasons_without_fallback() {
    let gateway = TestGateway::new();
    let error = gateway.codex_first_party_available().await.unwrap_err();
    assert_eq!(error.message, CODEX_NOT_RUNNING);
    assert_eq!(error.data, RpcData::RetryAfterMs(RETRY_AFTER_MS));
    let mut control = FakeControl::attach(&gateway, 8).await;
    let generation = gateway.control.current().unwrap();
    for (holds_recovery, reason) in [(false, CODEX_STARTING), (true, CODEX_AWAITING_SIGN_IN)] {
        generation.auth.lock().unwrap().holds_recovery = holds_recovery;
        let error = gateway.codex_first_party_available().await.unwrap_err();
        assert_eq!(error.message, reason);
        assert_eq!(error.data, RpcData::RetryAfterMs(RETRY_AFTER_MS));
        assert_eq!(
            gateway.published_codex_health(),
            CodexHealth::Unavailable {
                reason: reason.into()
            }
        );
        assert!(control.requests.try_recv().is_err());
    }
}

#[tokio::test]
async fn replacement_control_does_not_inherit_prior_native_authentication() {
    let gateway = TestGateway::new();
    let mut control = FakeControl::attach(&gateway, 8).await;
    *gateway.control_init_result.lock().await = Some(json!({}));
    let (result, ()) = tokio::join!(
        gateway.codex_first_party_available(),
        reply(
            &gateway,
            &mut control,
            json!({"requiresOpenaiAuth":true,"account":null})
        )
    );
    assert!(!result.unwrap());
    let _replacement = FakeControl::attach(&gateway, 8).await;
    gateway.refresh_provider_health().await;
    assert_eq!(
        gateway.published_codex_health(),
        CodexHealth::Unavailable {
            reason: "Codex authentication availability is unknown".into(),
        }
    );
    assert!(matches!(
        gateway.codex_readiness().await,
        Readiness::Unknown(_)
    ));
}

#[tokio::test]
async fn health_publication_does_not_wait_for_the_native_account_response() {
    let gateway = TestGateway::new();
    let mut control = FakeControl::attach(&gateway, 8).await;
    *gateway.control_init_result.lock().await = Some(json!({}));
    let generation = gateway.control.current().unwrap();
    gateway.spawn_native_readiness_refresh(&generation);
    let request = tokio::time::timeout(Duration::from_secs(2), control.requests.recv())
        .await
        .unwrap()
        .unwrap();
    let request: Value = serde_json::from_str(&request).unwrap();
    assert_eq!(request["method"], "account/read");
    tokio::time::timeout(
        Duration::from_millis(100),
        gateway.refresh_provider_health(),
    )
    .await
    .unwrap();
    assert!(matches!(
        gateway.codex_readiness().await,
        Readiness::Unknown(_)
    ));
    gateway.control.retire().await;
}

#[tokio::test]
async fn claude_uses_cached_auth_and_requires_its_supervisor_without_codex() {
    use crate::providers::claude::{ClaudeSupervisor, settings::ClaudeSettings};
    use crate::providers::codex::daemon::CodexAppServer;
    let mut home = ClaudeSettings::isolated_for_test();
    home.settings.enabled = true;
    home.settings.claude_path = "/usr/bin/true".into();
    let gateway = TestGateway::with_settings(
        Arc::new(CodexAppServer::new(
            "/usr/bin/true".into(),
            Default::default(),
        )),
        home.settings.clone(),
        Arc::new(home),
    );
    assert!(gateway.claude_first_party_available().await.is_err());
    gateway.claude_auth.refresh().await;
    assert!(gateway.claude_first_party_available().await.is_err());
    let (notifications, _rx) = tokio::sync::mpsc::channel(1);
    gateway.set_claude_agent(ClaudeSupervisor::new(
        gateway.claude_settings.clone(),
        notifications,
        gateway.journal.clone(),
        gateway.mcp_tokens.clone(),
    ));
    assert!(gateway.claude_first_party_available().await.unwrap());
    gateway.refresh_provider_health().await;
    assert_eq!(
        gateway.provider_health.published.lock().unwrap().claude,
        Some(ClaudeHealth::Ready)
    );
    let mut control = FakeControl::attach(&gateway, 8).await;
    *gateway.control_init_result.lock().await = Some(json!({}));
    let (available, ()) = tokio::join!(
        gateway.codex_first_party_available(),
        reply(
            &gateway,
            &mut control,
            json!({"requiresOpenaiAuth":true,"account":null})
        )
    );
    assert!(!available.unwrap());
    assert_eq!(
        gateway.published_codex_health(),
        CodexHealth::Fallback {
            reason: "Codex is not signed in".into(),
            fallback: "claude".into(),
        }
    );
}

#[tokio::test]
async fn account_response_from_a_replaced_connection_cannot_publish_ready() {
    let gateway = TestGateway::new();
    let mut control = FakeControl::attach(&gateway, 8).await;
    *gateway.control_init_result.lock().await = Some(json!({}));
    let replace_before_response = async {
        let raw = tokio::time::timeout(Duration::from_secs(2), control.requests.recv())
            .await
            .unwrap()
            .unwrap();
        let request: Value = serde_json::from_str(&raw).unwrap();
        let _replacement = FakeControl::attach(&gateway, 8).await;
        gateway
            .handle_control_text(
                json!({"id":request["id"], "result":{"requiresOpenaiAuth":false,"account":null}})
                    .to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
    };
    let (result, ()) = tokio::join!(
        gateway.codex_first_party_available(),
        replace_before_response
    );
    assert_eq!(
        result.unwrap_err().data,
        RpcData::RetryAfterMs(RETRY_AFTER_MS)
    );
    assert_eq!(
        gateway.published_codex_health(),
        CodexHealth::Unavailable {
            reason: "Codex authentication availability is unknown".into(),
        }
    );
}
