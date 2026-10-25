use super::Gateway;
#[cfg(test)]
use crate::providers::codex::daemon::CodexAppServer;
use crate::rpc::RpcError;
use crate::rpc::dispatch::method_spec;
use crate::rpc::error::{ErrorKind, RETRY_AFTER_MS, RpcCode, RpcData};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
#[cfg(test)]
use std::path::PathBuf;
#[cfg(test)]
use std::sync::Arc;

pub(super) fn admission_error(error: &anyhow::Error) -> RpcError {
    let refusal = RpcError::new(RpcCode::Unavailable, error.to_string());
    if error.is::<crate::gateway::admission::ConversationBusy>() {
        refusal.with_data(RpcData::Kind(ErrorKind::ConversationBusy {
            retry_after_ms: RETRY_AFTER_MS,
        }))
    } else {
        refusal
    }
}

pub(super) fn admission_refusal(id: Option<&Value>, error: &anyhow::Error) -> Value {
    admission_error(error).response(id.unwrap_or(&Value::Null))
}

pub(super) fn requires_admission(method: &str, params: &Value) -> bool {
    if method == "conversation/agents/action" && params["action"] == "stop" {
        return false;
    }
    if method == "thread/name/set" {
        return params["threadId"]
            .as_str()
            .is_some_and(crate::providers::claude::is_claude_thread_id);
    }
    let spec = method_spec(method);
    // Automation service admissions use the saved execution target, independently
    // of the account through which this physical host was reached.
    if matches!(spec.route, crate::rpc::dispatch::OwnedRoute::Automations) {
        return false;
    }
    spec.admission || spec.new_work
}

impl Gateway {
    pub(crate) fn codex_home(&self) -> Option<&std::path::Path> {
        self.codex
            .socket_path()
            .parent()
            .and_then(std::path::Path::parent)
    }

    pub(super) async fn check_voice_account(&self) -> Result<()> {
        self.check_account_identity().await
    }

    pub(crate) async fn native_account(&self) -> Result<Value> {
        self.call_control("account/read", json!({"refreshToken": false}))
            .await
    }
    pub(crate) async fn account_quota(&self) -> Result<crate::providers::codex::router::Quota> {
        let Some(auth) = self.external_auth.as_ref() else {
            return Ok(crate::providers::codex::router::Quota {
                rate_limits: self
                    .call_control("account/rateLimits/read", json!({}))
                    .await?,
                resets: None,
            });
        };
        auth.router.quota(&auth.account_id).await
    }
    pub(crate) async fn refreshed_claude_status(&self) -> Value {
        let snapshot = self.claude_auth.snapshot_refreshing().await;
        crate::providers::claude::auth::health_json(
            &self.claude_settings,
            Some(&snapshot),
            self.active_turn_count().await,
        )
    }

    pub(crate) async fn check_account_identity(&self) -> Result<()> {
        self.require_external_auth().await
    }

    pub(crate) async fn verified_codex_identity(
        &self,
        account: &Value,
    ) -> Result<Option<crate::accounts::types::Identity>> {
        let Some(auth) = self.external_auth.as_ref() else {
            return Ok(None);
        };
        self.require_external_auth().await?;
        {
            let generation = self
                .control
                .current()
                .context("Codex authentication is unavailable")?;
            let installed = generation.auth.lock().expect("Codex auth state poisoned");
            let token = installed
                .token
                .as_ref()
                .context("Codex authentication is not ready")?;
            ensure!(
                token.account_id == auth.account_id,
                "Codex external token identity changed"
            );

            self.require_auth_generation(&generation)?;
            crate::accounts::codex_identity_in_workspace(account, &token.account_id).map(Some)
        }
        .context("Account identity is unavailable")
    }
    pub(super) async fn account_request_error(
        &self,
        method: &str,
        object: &serde_json::Map<String, Value>,
    ) -> Option<String> {
        let parameters = object.get("params").unwrap_or(&Value::Null);
        if self.external_auth.is_some()
            && super::external_auth::blocked_consumer_auth(method, parameters)
        {
            return Some(
                "Codex authentication is managed by llm-router; update the account there".into(),
            );
        }
        if method_spec(method).identity
            && !(method == "conversation/agents/action" && parameters["action"] == "stop")
            && !crate::rpc::dispatch::claude_route(method, object)
            && self.external_providers.is_none()
            && let Err(error) = self.check_account_identity().await
        {
            return Some(error.to_string());
        }
        None
    }
}

impl Gateway {
    pub(crate) fn admit_request(
        &self,
        method: Option<&str>,
        object: &serde_json::Map<String, Value>,
    ) -> Result<Option<crate::gateway::admission::Admission>> {
        let Some(method) = method else {
            return Ok(None);
        };
        if !requires_admission(method, object.get("params").unwrap_or(&Value::Null)) {
            return Ok(None);
        }
        let key = if matches!(method, "voice/session/start" | "calls/request") {
            "conversationThreadId"
        } else {
            "threadId"
        };
        object
            .get("params")
            .and_then(|params| params.get(key))
            .and_then(Value::as_str)
            .map(|thread| {
                if method == "thread/compact/start" {
                    self.admission.admit_compaction(thread)
                } else {
                    self.admission.admit(thread)
                }
            })
            .transpose()
    }
}

#[cfg(test)]
mod admission_tests {
    use super::*;
    use crate::wire::gateway::RealtimeVoiceStartRequest;

    fn request(params: Value) -> serde_json::Map<String, Value> {
        json!({ "params": params }).as_object().unwrap().clone()
    }

    #[test]
    fn compaction_refuses_new_work_on_its_conversation_only() {
        let gateway = crate::test_support::TestGateway::with_codex(
            Arc::new(CodexAppServer::new_for_test_socket(PathBuf::from(
                "/tmp/admission-tests",
            ))),
            None,
        );
        let _compaction = gateway.admission.admit_compaction("busy").unwrap();
        for method in ["turn/start", "turn/steer", "thread/goal/set"] {
            let refused = gateway
                .admit_request(Some(method), &request(json!({"threadId":"busy"})))
                .err()
                .expect(method);
            assert!(
                admission_error(&refused)
                    .response(&Value::Null)
                    .to_string()
                    .contains("conversationBusy")
            );
            assert!(
                gateway
                    .admit_request(Some(method), &request(json!({"threadId":"other"})))
                    .unwrap()
                    .is_some()
            );
        }
        let voice = json!({"conversationThreadId":"busy", "realtimeSessionId":"voice-test",
            "replaceExistingSession":false, "cwd":"/tmp", "model":"gpt-6-luna", "sdp":"offer"});
        serde_json::from_value::<RealtimeVoiceStartRequest>(voice.clone())
            .unwrap()
            .validate()
            .unwrap();
        assert!(
            gateway
                .admit_request(Some("voice/session/start"), &request(voice))
                .is_err()
        );
        for (method, params) in [
            ("thread/read", json!({"threadId":"busy"})),
            (
                "conversation/agents/action",
                json!({"threadId":"busy","action":"stop"}),
            ),
        ] {
            assert!(
                gateway
                    .admit_request(Some(method), &request(params))
                    .unwrap()
                    .is_none()
            );
        }
    }
}
