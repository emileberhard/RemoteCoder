use super::*;

#[test]
fn health_matches_the_shared_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../protocol-fixtures/providers/provider-health.json"
    ))
    .unwrap();
    let health = ProviderHealth {
        codex: codex_health(CodexControl::Ready, true, Some("copilot")),
        claude: Some(ClaudeHealth::Unavailable {
            reason: "Claude Code is not signed in on mac-mini".into(),
        }),
    };

    assert_eq!(fixture["method"], PROVIDER_HEALTH_METHOD);
    assert_eq!(fixture["params"], json!({"providers": health}));
}

#[test]
fn ready_has_no_reason_and_unknown_claude_is_absent() {
    let health = ProviderHealth {
        codex: codex_health(CodexControl::Ready, false, Some("copilot")),
        claude: claude_health(true, None),
    };

    assert_eq!(json!(health), json!({"codex": {"state": "ready"}}));
}

#[test]
fn a_failing_subscription_without_a_fallback_leaves_codex_unavailable() {
    assert_eq!(
        codex_health(CodexControl::Ready, true, None),
        CodexHealth::Unavailable {
            reason: CODEX_SIGN_IN_FAILED.into()
        }
    );
}
