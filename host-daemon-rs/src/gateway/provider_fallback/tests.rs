use super::*;
use crate::notifications::history::NotificationOrigin;
use crate::providers::claude::{ClaudeSupervisor, settings::ClaudeSettings};
use crate::providers::codex::daemon::CodexAppServer;
use crate::test_support::{FakeControl, TestGateway};
use std::sync::Arc;
use std::time::Duration;

async fn host(claude_enabled: bool, executable_exists: bool) -> TestGateway {
    let mut home = ClaudeSettings::isolated_for_test();
    home.settings.enabled = claude_enabled;
    home.settings.claude_path = if executable_exists {
        "/usr/bin/true".into()
    } else {
        home.root_path().join("missing-claude")
    };
    let gateway = TestGateway::with_settings(
        Arc::new(CodexAppServer::new(
            "/usr/bin/true".into(),
            Default::default(),
        )),
        home.settings.clone(),
        Arc::new(home),
    );
    if claude_enabled {
        let (notifications, _rx) = tokio::sync::mpsc::channel(1);
        gateway.set_claude_agent(ClaudeSupervisor::new(
            gateway.claude_settings.clone(),
            notifications,
            gateway.journal.clone(),
            gateway.mcp_tokens.clone(),
        ));
    }
    gateway.claude_auth.refresh().await;
    gateway
}

async fn respond(gateway: &Arc<Gateway>, control: &mut FakeControl, method: &str, result: Value) {
    let request = tokio::time::timeout(Duration::from_secs(3), control.requests.recv())
        .await
        .unwrap()
        .unwrap();
    let request: Value = serde_json::from_str(&request).unwrap();
    assert_eq!(request["method"], method);
    gateway
        .handle_control_text(
            json!({"id": request["id"], "result": result}).to_string(),
            NotificationOrigin::Control { opened_after: 0 },
        )
        .await;
}

fn unrestricted_start() -> Value {
    json!({"model":"gpt-6.1-sol", "cwd":"/fixture/project",
        "sandbox":"danger-full-access", "approvalPolicy":"never",
        "serviceTier":"fast", "cyberAccessProgram":"daybreakBlue",
        "acceptProviderFallback":true, "config":{"model_reasoning_effort":"xhigh"}})
}

#[tokio::test]
async fn logged_out_codex_uses_claude_opus_and_preserves_effort() {
    let gateway = host(true, true).await;
    let mut control = FakeControl::attach(&gateway, 4).await;
    *gateway.control_init_result.lock().await = Some(json!({}));
    let mut params = unrestricted_start();
    let (result, ()) = tokio::join!(
        gateway.admit_new_conversation(&mut params),
        respond(
            &gateway,
            &mut control,
            "account/read",
            json!({"requiresOpenaiAuth":true, "account":null})
        )
    );
    assert!(result.unwrap());
    assert_eq!(params["provider"], "claude");
    assert_eq!(params["model"], "opus");
    assert_eq!(params["config"], json!({"model_reasoning_effort":"xhigh"}));
    assert_eq!(params["cwd"], "/fixture/project");
    assert!(params.get("serviceTier").is_none());
    assert!(params.get("cyberAccessProgram").is_none());
}

#[tokio::test]
async fn authenticated_codex_keeps_its_selection_even_with_claude_ready() {
    let gateway = host(true, true).await;
    let mut control = FakeControl::attach(&gateway, 4).await;
    *gateway.control_init_result.lock().await = Some(json!({}));
    let original = unrestricted_start();
    let mut params = original.clone();
    let (result, ()) = tokio::join!(
        gateway.admit_new_conversation(&mut params),
        respond(
            &gateway,
            &mut control,
            "account/read",
            json!({"requiresOpenaiAuth":true, "account":{"type":"chatgpt", "email":"fixture@example.invalid", "planType":"pro"}})
        )
    );
    assert!(!result.unwrap());
    assert_eq!(params, original);
}

#[tokio::test]
async fn unavailable_claude_uses_latest_native_sol_after_account_read() {
    for (enabled, executable_exists) in [(false, true), (true, false)] {
        let gateway = host(enabled, executable_exists).await;
        let mut control = FakeControl::attach(&gateway, 4).await;
        *gateway.control_init_result.lock().await = Some(json!({}));
        let mut params = json!({"provider":"claude", "model":"opus", "cwd":"/fixture/project", "acceptProviderFallback":true, "config":{"model_reasoning_effort":"ultra"}});
        let replies = async {
            respond(
                &gateway,
                &mut control,
                "account/read",
                json!({"requiresOpenaiAuth":true, "account":{"type":"apiKey"}}),
            )
            .await;
            respond(
                &gateway,
                &mut control,
                "model/list",
                json!({"data":[
                    {"model":"gpt-6-sol"},
                    {"model":"gpt-6.2-sol", "modelProvider":"openai", "supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"}]},
                    {"model":"gpt-6.1-sol"},
                    {"model":"gpt-99-sol", "modelProvider":"copilot"},
                    {"model":"gpt-7-astra"}, {"model":"gpt-99-sol","hidden":true}
                ]}),
            )
            .await;
        };
        let (result, ()) = tokio::join!(gateway.admit_new_conversation(&mut params), replies);
        assert!(result.unwrap());
        assert!(params.get("provider").is_none());
        assert_eq!(params["model"], "gpt-6.2-sol");
        assert_eq!(params["config"]["model_reasoning_effort"], "high");
    }
}

#[tokio::test]
async fn ready_claude_keeps_its_selection_without_codex_control() {
    let gateway = host(true, true).await;
    let original = json!({"provider":"claude", "model":"sonnet", "cwd":"/fixture/project"});
    let mut params = original.clone();
    assert!(!gateway.admit_new_conversation(&mut params).await.unwrap());
    assert_eq!(params, original);
}

#[tokio::test]
async fn explicit_external_provider_is_preserved_when_first_party_is_unavailable() {
    let gateway = host(false, false).await;
    let original = json!({"modelProvider":"copilot", "model":"copilot/gemini-4-argon"});
    let mut params = original.clone();
    assert!(!gateway.admit_new_conversation(&mut params).await.unwrap());
    assert_eq!(params, original);
}

#[tokio::test]
async fn restricted_codex_requests_never_change_to_full_access_claude() {
    let gateway = host(true, true).await;
    let mut control = FakeControl::attach(&gateway, 4).await;
    *gateway.control_init_result.lock().await = Some(json!({}));
    for restriction in [
        json!({"sandbox":"workspace-write"}),
        json!({"sandbox":"workspace-write", "sandboxPolicy":{"type":"dangerFullAccess"}}),
        json!({"approvalPolicy":"on-request"}),
        json!({"permissions":{"network":false}}),
        json!({"sandboxPolicy":{"type":"dangerFullAccess", "networkAccess":false}}),
        json!({"config":{"sandbox_mode":"read-only"}}),
        json!({"config":{"approval_policy":"on-request"}}),
        json!({"config":{"profile":"restricted"}}),
    ] {
        let mut params = unrestricted_start();
        params
            .as_object_mut()
            .unwrap()
            .extend(restriction.as_object().unwrap().clone());
        let original = params.clone();
        let (result, ()) = tokio::join!(
            gateway.admit_new_conversation(&mut params),
            respond(
                &gateway,
                &mut control,
                "account/read",
                json!({"requiresOpenaiAuth":true, "account":null})
            )
        );
        assert!(
            result.is_err(),
            "restriction must remain enforced: {restriction}"
        );
        assert_eq!(params, original);
    }
}

#[tokio::test]
async fn both_first_party_unavailable_use_configured_copilot_with_native_codex_auth() {
    use crate::providers::codex::external::{ExternalProvider, ExternalProviders};
    use crate::storage::private_state;
    let home = ClaudeSettings::isolated_for_test();
    let directory = tempfile::tempdir().unwrap();
    let state = directory.path().join("state");
    let catalogs = state.join("external-models");
    private_state::ensure_private_directory(&catalogs).unwrap();
    private_state::write_json(
        &catalogs.join("copilot.json"),
        &json!({"models":[{"slug":"copilot/gemini-4-argon"}]}),
    )
    .unwrap();
    let provider: ExternalProvider = serde_json::from_value(json!({
        "id":"copilot", "name":"Copilot", "baseUrl":"http://127.0.0.1:9/v1",
        "keyFile":directory.path().join("copilot.key"), "models":["copilot/gemini-4-argon"]
    }))
    .unwrap();
    let external = ExternalProviders::new(vec![provider], &state)
        .unwrap()
        .unwrap();
    let journal = crate::observability::journal::Journal::disabled();
    let gateway = Gateway::with_notifier(
        Arc::new(CodexAppServer::new_for_test_socket(
            directory.path().join("codex"),
        )),
        Arc::new(crate::push::PushService::new(
            false,
            journal.clone(),
            Arc::new(crate::devices::DeviceRegistry::temporary()),
            None,
        )),
        home.settings.clone(),
        journal,
        state,
        None,
        None,
        Some(external),
        None,
    );
    let mut control = FakeControl::attach(&gateway, 4).await;
    *gateway.control_init_result.lock().await = Some(json!({}));
    let mut params = unrestricted_start();
    let (result, ()) = tokio::join!(
        gateway.admit_new_conversation(&mut params),
        respond(
            &gateway,
            &mut control,
            "account/read",
            json!({"requiresOpenaiAuth":true, "account":null})
        )
    );
    assert!(result.unwrap());
    assert_eq!(params["modelProvider"], "copilot");
    assert_eq!(params["model"], "copilot/gemini-4-argon");
}

#[tokio::test]
async fn old_clients_do_not_change_harness_when_codex_is_logged_out() {
    let gateway = host(true, true).await;
    let mut control = FakeControl::attach(&gateway, 4).await;
    *gateway.control_init_result.lock().await = Some(json!({}));
    let mut params = unrestricted_start();
    params
        .as_object_mut()
        .unwrap()
        .remove("acceptProviderFallback");
    let original = params.clone();
    let (result, ()) = tokio::join!(
        gateway.admit_new_conversation(&mut params),
        respond(
            &gateway,
            &mut control,
            "account/read",
            json!({"requiresOpenaiAuth":true,"account":null})
        )
    );
    assert!(result.is_err());
    assert_eq!(params, original);
}

#[tokio::test]
async fn old_claude_clients_retain_their_original_harness() {
    let gateway = host(false, false).await;
    let original = json!({"provider":"claude","model":"opus","cwd":"/tmp"});
    let mut params = original.clone();
    assert!(!gateway.admit_new_conversation(&mut params).await.unwrap());
    assert_eq!(params, original);
}
