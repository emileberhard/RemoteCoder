use super::Gateway;
use super::agent_gateway::native_error;
use crate::providers::codex::external::ExternalProviders;
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

pub(super) fn admission_failure(error: &RpcError) -> anyhow::Error {
    anyhow!(error.response(&Value::Null)["error"].to_string())
}

impl Gateway {
    pub(super) async fn admit_native(
        &self,
        method: &str,
        params: &mut Value,
    ) -> std::result::Result<bool, RpcError> {
        let Some(external) = self.external_providers.as_deref() else {
            return Ok(false);
        };
        let source = match ExternalProviders::thread_to_inspect(method, params) {
            Some(thread) => Some(self.thread_model_provider(&thread).await?),
            None => None,
        };
        external.admit(method, params, source.as_deref()).await
    }

    async fn thread_model_provider(&self, thread: &str) -> std::result::Result<String, RpcError> {
        let response = self
            .call_control_unadmitted(
                "thread/read",
                json!({"threadId": thread, "includeTurns": false}),
            )
            .await
            .map_err(|error| native_error(&error))?;
        response
            .pointer("/thread/modelProvider")
            .and_then(Value::as_str)
            .filter(|provider| !provider.is_empty())
            .map(str::to_owned)
            .ok_or_else(|| {
                RpcError::new(
                    RpcCode::Unavailable,
                    "Codex reported no model provider for this conversation",
                )
            })
    }

    pub(super) async fn model_list(&self, params: Value) -> RpcResult {
        let Some(external) = self.external_providers.as_deref() else {
            return self
                .call_control("model/list", params)
                .await
                .map_err(|error| native_error(&error));
        };
        let (listing, ()) =
            tokio::join!(self.call_control("model/list", params), external.refresh());
        let mut listing = listing.map_err(|error| native_error(&error))?;
        if listing["nextCursor"].is_null()
            && let Some(models) = listing["data"].as_array_mut()
        {
            models.extend(external.model_rows());
        }
        Ok(listing)
    }

    pub(super) async fn load_external_thread(&self, thread: &str) -> Result<()> {
        let Some(external) = self.external_providers.as_deref() else {
            return Ok(());
        };
        let provider = self
            .thread_model_provider(thread)
            .await
            .map_err(|error| admission_failure(&error))?;
        if external.provider_ids().any(|id| id == provider) {
            self.call_control(
                "thread/resume",
                json!({"threadId": thread, "excludeTurns": true}),
            )
            .await?;
        }
        Ok(())
    }
}
