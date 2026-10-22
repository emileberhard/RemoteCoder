use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde_json::Value;

/// Per-runtime bearer tokens for `/mcp`.
///
/// A token is minted when a Claude runtime spawns and mapped to the thread it
/// belongs to, so a tool call carries trustworthy identity without trusting a
/// client-supplied header. Revoked when the runtime retires.
#[derive(Clone, Default)]
pub(crate) struct McpTokens {
    inner: Arc<Mutex<TokenState>>,
}

pub(crate) const NOTIFICATION_PERMIT_FIELD: &str = "_remoteCoderRootPermit";
const MAX_NOTIFICATION_PERMITS: usize = 256;
const MAX_RUNTIME_NOTIFICATION_PERMITS: usize = 16;
const NOTIFICATION_PERMIT_TTL: std::time::Duration = std::time::Duration::from_secs(30);

#[derive(Default)]
struct TokenState {
    tokens: HashMap<String, McpIdentity>,
    permits: std::collections::VecDeque<NotificationPermit>,
}

struct NotificationPermit {
    runtime_token: String,
    permit: String,
    // None marks an accepted dispatch until expiry, distinguishing replay from
    // an unknown proof without retaining the notification copy after delivery.
    arguments: Option<Value>,
    issued: std::time::Instant,
}

impl TokenState {
    fn prune_permits(&mut self) {
        self.permits.retain(|permit| {
            self.tokens.contains_key(&permit.runtime_token)
                && permit.issued.elapsed() < NOTIFICATION_PERMIT_TTL
        });
    }
}

/// Transport authorization never belongs in app tool cards, history or logs.
pub(crate) fn remove_notification_permit(arguments: &mut Value) {
    if let Some(object) = arguments.as_object_mut() {
        object.remove(NOTIFICATION_PERMIT_FIELD);
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct McpIdentity {
    pub thread_id: String,
    pub session_uuid: String,
}

impl McpTokens {
    pub fn new() -> McpTokens {
        McpTokens::default()
    }

    /// Mints a token for one runtime. Any token previously held by the same
    /// session is dropped, so a respawn never leaves a usable stale token.
    pub(crate) fn mint(&self, thread_id: &str, session_uuid: &str) -> String {
        let token = random_token();
        let mut tokens = self.lock();
        tokens
            .tokens
            .retain(|_, identity| identity.session_uuid != session_uuid);
        tokens.prune_permits();
        tokens.tokens.insert(
            token.clone(),
            McpIdentity {
                thread_id: thread_id.to_string(),
                session_uuid: session_uuid.to_string(),
            },
        );
        token
    }

    pub(crate) fn identify(&self, token: &str) -> Option<McpIdentity> {
        self.lock().tokens.get(token).cloned()
    }

    /// Revokes exactly one token. Retiring a runtime uses this rather than
    /// revoking by session, because a replacement runtime for the same session
    /// may already hold a freshly minted token by the time the old one drops.
    pub(crate) fn revoke_token(&self, token: &str) {
        let mut state = self.lock();
        state.tokens.remove(token);
        state.prune_permits();
    }

    /// The provider hook, not model arguments, proves native root execution.
    /// Its opaque permit is bound to this runtime and the complete JSON input.
    pub(crate) fn issue_notification_permit(&self, token: &str, hook: &Value) -> Option<Value> {
        let mut state = self.lock();
        let identity = state.tokens.get(token)?;
        if crate::providers::claude::notification_hook::decide(hook, &identity.session_uuid)
            != crate::providers::claude::notification_hook::Decision::Root
        {
            return None;
        }
        let mut arguments = hook["tool_input"].as_object()?.clone();
        // This proof establishes caller identity, not business validation.
        // The normal notify_user owner reports empty/missing title or body.
        arguments.remove(NOTIFICATION_PERMIT_FIELD);
        state.prune_permits();
        // A busy runtime evicts its own oldest permit before it can displace
        // other runtimes. The global limit additionally bounds host memory.
        while state
            .permits
            .iter()
            .filter(|entry| entry.runtime_token == token)
            .count()
            >= MAX_RUNTIME_NOTIFICATION_PERMITS
        {
            let index = state
                .permits
                .iter()
                .position(|entry| entry.runtime_token == token)?;
            state.permits.remove(index);
        }
        while state.permits.len() >= MAX_NOTIFICATION_PERMITS {
            state.permits.pop_front();
        }
        let permit = random_token();
        state.permits.push_back(NotificationPermit {
            runtime_token: token.into(),
            permit: permit.clone(),
            arguments: Some(Value::Object(arguments.clone())),
            issued: std::time::Instant::now(),
        });
        arguments.insert(NOTIFICATION_PERMIT_FIELD.into(), Value::String(permit));
        Some(Value::Object(arguments))
    }

    /// A timeout, absent hook, replay or changed payload cannot reach notify_user.
    /// A wrong runtime or payload cannot consume a legitimate concurrent call.
    /// Fixed reasons contain neither the proof nor user content.
    pub(crate) fn consume_notification_permit(
        &self,
        token: &str,
        arguments: &Value,
    ) -> Result<(), &'static str> {
        let Some(permit) = arguments[NOTIFICATION_PERMIT_FIELD].as_str() else {
            return Err("nativeClaudeRootProofMissing");
        };
        let mut state = self.lock();
        let Some(index) = state
            .permits
            .iter()
            .position(|entry| entry.permit == permit)
        else {
            return Err("nativeClaudeRootProofUnknown");
        };
        let entry = &mut state.permits[index];
        if entry.runtime_token != token {
            return Err("nativeClaudeRootProofRuntimeMismatch");
        }
        if entry.issued.elapsed() >= NOTIFICATION_PERMIT_TTL {
            state.permits.remove(index);
            return Err("nativeClaudeRootProofExpired");
        }
        let expected = entry
            .arguments
            .as_ref()
            .ok_or("nativeClaudeRootProofReplayed")?;
        let matches =
            arguments
                .as_object()
                .zip(expected.as_object())
                .is_some_and(|(actual, expected)| {
                    actual.len() == expected.len() + 1
                        && expected
                            .iter()
                            .all(|(key, value)| actual.get(key) == Some(value))
                });
        if !matches {
            return Err("nativeClaudeRootProofArgumentsMismatch");
        }
        entry.arguments = None;
        Ok(())
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, TokenState> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// A short opaque id for naming one runtime's config file.
///
/// Deliberately not derived from the session or the token: two runtimes for one
/// session must not collide on a path, and a retiring runtime deletes its own
/// file — while a filename is far more visible than the token it points at.
pub(crate) fn config_file_id() -> String {
    random_token()[..16].to_string()
}

/// 32 bytes of OS randomness, hex encoded.
///
/// This is a bearer token, so it needs real entropy rather than something
/// derived from the clock and a pid, which a caller who knows roughly when a
/// runtime spawned could search.
fn random_token() -> String {
    use std::io::Read;

    let mut bytes = [0u8; 32];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut urandom| urandom.read_exact(&mut bytes))
        .expect("/dev/urandom must be readable to mint an MCP token");
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn root_hook(session: &str) -> Value {
        json!({"hook_event_name":"PreToolUse","tool_name":crate::providers::claude::notification_hook::TOOL,
            "session_id":session,"tool_input":{"title":"Fixture","body":"Root notification"}})
    }

    #[test]
    fn notification_permits_require_native_root_evidence_and_are_single_use() {
        let tokens = McpTokens::new();
        let runtime = tokens.mint("claude_root", "session");
        let root = root_hook("session");
        let mut child = root.clone();
        child["agent_id"] = json!("child");
        assert!(tokens.issue_notification_permit(&runtime, &child).is_none());
        assert!(
            tokens
                .issue_notification_permit(&runtime, &root_hook("wrong-session"))
                .is_none()
        );
        assert!(
            tokens
                .issue_notification_permit("unknown-runtime", &root)
                .is_none()
        );
        assert_eq!(
            tokens.consume_notification_permit(&runtime, &root["tool_input"]),
            Err("nativeClaudeRootProofMissing")
        );
        let arguments = tokens.issue_notification_permit(&runtime, &root).unwrap();
        assert_eq!(
            tokens.consume_notification_permit(&runtime, &arguments),
            Ok(())
        );
        assert_eq!(
            tokens.consume_notification_permit(&runtime, &arguments),
            Err("nativeClaudeRootProofReplayed")
        );
    }

    #[test]
    fn notification_permits_bind_complete_arguments_runtime_and_retirement() {
        let tokens = McpTokens::new();
        let runtime = tokens.mint("claude_root", "session");
        let another = tokens.mint("claude_other", "other-session");
        let root = root_hook("session");
        let arguments = tokens.issue_notification_permit(&runtime, &root).unwrap();
        assert_eq!(
            tokens.consume_notification_permit(&another, &arguments),
            Err("nativeClaudeRootProofRuntimeMismatch")
        );
        for field in ["title", "body", "unexpected"] {
            let mut changed = arguments.clone();
            changed[field] = json!("Changed input");
            assert_eq!(
                tokens.consume_notification_permit(&runtime, &changed),
                Err("nativeClaudeRootProofArgumentsMismatch")
            );
        }
        assert_eq!(
            tokens.consume_notification_permit(&runtime, &arguments),
            Ok(())
        );
        let revoked = tokens.issue_notification_permit(&runtime, &root).unwrap();
        tokens.revoke_token(&runtime);
        assert_eq!(
            tokens.consume_notification_permit(&runtime, &revoked),
            Err("nativeClaudeRootProofUnknown")
        );
    }

    #[test]
    fn notification_permits_expire_and_one_runtime_cannot_evict_its_peer() {
        let tokens = McpTokens::new();
        let runtime = tokens.mint("claude_root", "session");
        let peer = tokens.mint("claude_peer", "peer-session");
        let root = root_hook("session");
        let expired = tokens.issue_notification_permit(&runtime, &root).unwrap();
        tokens.lock().permits.front_mut().unwrap().issued -= std::time::Duration::from_secs(31);
        assert_eq!(
            tokens.consume_notification_permit(&runtime, &expired),
            Err("nativeClaudeRootProofExpired")
        );
        let peer_arguments = tokens
            .issue_notification_permit(&peer, &root_hook("peer-session"))
            .unwrap();
        let oldest = tokens.issue_notification_permit(&runtime, &root).unwrap();
        let mut newest = Value::Null;
        for _ in 0..MAX_RUNTIME_NOTIFICATION_PERMITS {
            newest = tokens.issue_notification_permit(&runtime, &root).unwrap();
        }
        assert_eq!(
            tokens.lock().permits.len(),
            MAX_RUNTIME_NOTIFICATION_PERMITS + 1
        );
        assert_eq!(
            tokens.consume_notification_permit(&runtime, &oldest),
            Err("nativeClaudeRootProofUnknown")
        );
        assert_eq!(
            tokens.consume_notification_permit(&runtime, &newest),
            Ok(())
        );
        assert_eq!(
            tokens.consume_notification_permit(&peer, &peer_arguments),
            Ok(())
        );
    }

    #[test]
    fn parallel_root_calls_have_independent_permits_and_accept_json_key_reordering() {
        let tokens = McpTokens::new();
        let runtime = tokens.mint("claude_root", "session");
        let first = tokens
            .issue_notification_permit(&runtime, &root_hook("session"))
            .unwrap();
        let second = tokens
            .issue_notification_permit(&runtime, &root_hook("session"))
            .unwrap();
        let reordered = json!({NOTIFICATION_PERMIT_FIELD:first[NOTIFICATION_PERMIT_FIELD],"body":"Root notification","title":"Fixture"});
        assert_eq!(
            tokens.consume_notification_permit(&runtime, &second),
            Ok(())
        );
        assert_eq!(
            tokens.consume_notification_permit(&runtime, &reordered),
            Ok(())
        );
    }

    #[test]
    fn a_token_identifies_its_thread_until_it_is_revoked() {
        let tokens = McpTokens::new();
        let token = tokens.mint("claude_abc", "session-1");

        assert_eq!(
            tokens.identify(&token),
            Some(McpIdentity {
                thread_id: "claude_abc".to_string(),
                session_uuid: "session-1".to_string(),
            })
        );
        assert_eq!(tokens.identify("not-a-token"), None);

        tokens.revoke_token(&token);
        assert_eq!(
            tokens.identify(&token),
            None,
            "a retired runtime's token must die with it"
        );
    }

    #[test]
    fn reminting_for_one_session_invalidates_the_previous_token() {
        let tokens = McpTokens::new();
        let first = tokens.mint("claude_abc", "session-1");
        let second = tokens.mint("claude_abc", "session-1");

        assert_ne!(first, second);
        assert_eq!(tokens.identify(&first), None);
        assert!(tokens.identify(&second).is_some());
    }

    #[test]
    fn tokens_are_unique_and_opaque() {
        let tokens = McpTokens::new();
        let mut seen = std::collections::HashSet::new();
        for index in 0..100 {
            let token = tokens.mint("claude_abc", &format!("session-{index}"));
            assert_eq!(token.len(), 64);
            assert!(seen.insert(token));
        }
    }
}
