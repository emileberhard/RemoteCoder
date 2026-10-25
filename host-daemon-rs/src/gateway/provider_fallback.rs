use super::Gateway;
use super::agent_gateway::native_error;
use crate::rpc::{RpcError, error::RpcCode};
use serde_json::{Value, json};

impl Gateway {
    pub(super) async fn admit_new_conversation(
        &self,
        params: &mut Value,
    ) -> Result<bool, RpcError> {
        let Some(fields) = params.as_object() else {
            return Ok(false);
        };
        if fields.get("serviceName").and_then(Value::as_str) == Some("RemoteCoder Voice") {
            return Ok(false);
        }
        let claude = fields.get("provider").and_then(Value::as_str) == Some("claude");
        let explicit_external = fields
            .get("modelProvider")
            .and_then(Value::as_str)
            .is_some_and(|provider| provider != "openai")
            || fields
                .get("model")
                .and_then(Value::as_str)
                .is_some_and(|model| {
                    self.external_providers
                        .as_ref()
                        .is_some_and(|external| external.owner(model).is_some())
                });
        if explicit_external {
            return Ok(false);
        }
        let accepts_fallback = fields
            .get("acceptProviderFallback")
            .and_then(Value::as_bool)
            == Some(true);
        if claude && !accepts_fallback {
            return Ok(false);
        }
        if claude && self.claude_first_party_available().await? {
            return Ok(false);
        }
        let codex_available = self.codex_first_party_available().await?;
        if !claude && codex_available {
            return Ok(false);
        }
        if accepts_fallback
            && !claude
            && permits_claude(params)
            && self.claude_first_party_available().await?
        {
            change_harness(params, "claude", "opus");
            return Ok(true);
        }
        if accepts_fallback && claude && codex_available {
            let mut rows = Vec::new();
            let mut cursor = Value::Null;
            for page in 0..64 {
                let catalog = self
                    .call_control_unadmitted(
                        "model/list",
                        json!({
                            "includeHidden":false, "limit":1000, "cursor":cursor
                        }),
                    )
                    .await
                    .map_err(|error| native_error(&error))?;
                if let Some(data) = catalog["data"].as_array() {
                    rows.extend(data.iter().cloned());
                }
                cursor = catalog["nextCursor"].clone();
                if cursor.is_null() {
                    break;
                }
                if page == 63 {
                    return Err(RpcError::new(
                        RpcCode::Unavailable,
                        "Codex model catalog exceeds admission limit",
                    ));
                }
            }
            let catalog = json!({"data":rows});
            let model = latest_sol(&catalog).ok_or_else(|| {
                RpcError::new(RpcCode::Unavailable, "Codex reports no visible Sol model")
            })?;
            change_harness(params, "codex", model["model"].as_str().expect("Sol model"));
            if let Some(requested) = params
                .pointer("/config/model_reasoning_effort")
                .and_then(Value::as_str)
            {
                let levels = model["supportedReasoningEfforts"]
                    .as_array()
                    .map(Vec::as_slice)
                    .unwrap_or(&[]);
                let effort = crate::rpc::supported_reasoning_effort(
                    requested,
                    levels
                        .iter()
                        .filter_map(|level| level["reasoningEffort"].as_str()),
                )
                .map(str::to_owned);
                let config = params["config"].as_object_mut().expect("effort config");
                if let Some(effort) = effort {
                    config.insert("model_reasoning_effort".into(), json!(effort));
                } else {
                    config.remove("model_reasoning_effort");
                }
            }
            return Ok(true);
        }
        self.external_providers.as_ref().filter(|external| external.fallback().is_some())
            .ok_or_else(|| RpcError::new(RpcCode::Unavailable, "Both first-party providers are unavailable and no external fallback is configured"))?;
        if !self.codex_ready().await {
            return Err(self.codex_unavailable().await.into());
        }
        if claude {
            change_harness(params, "codex", "");
            params
                .as_object_mut()
                .expect("start parameters")
                .remove("model");
        }
        self.start_on_fallback(params).await?;
        Ok(true)
    }
}

fn permits_claude(params: &Value) -> bool {
    let sandbox = params.get("sandbox").and_then(Value::as_str);
    let policy = params
        .pointer("/sandboxPolicy/type")
        .and_then(Value::as_str);
    let full_access = sandbox == Some("danger-full-access") || policy == Some("dangerFullAccess");
    full_access
        && sandbox.is_none_or(|sandbox| sandbox == "danger-full-access")
        && policy.is_none_or(|policy| policy == "dangerFullAccess")
        && params.get("approvalPolicy").and_then(Value::as_str) == Some("never")
        && params.get("config").is_none_or(|config| {
            config.as_object().is_some_and(|fields| {
                fields.keys().all(|key| {
                    matches!(
                        key.as_str(),
                        "model_reasoning_effort" | "model_reasoning_summary"
                    )
                })
            })
        })
        && params.pointer("/sandboxPolicy/networkAccess") != Some(&Value::Bool(false))
        && params.get("permissions").is_none_or(Value::is_null)
}

fn change_harness(params: &mut Value, provider: &str, model: &str) {
    let effort = params
        .pointer("/config/model_reasoning_effort")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let Some(fields) = params.as_object_mut() else {
        return;
    };
    for field in [
        "config",
        "modelProvider",
        "serviceTier",
        "serviceTierForTurn",
        "collaborationMode",
        "cyberAccessProgram",
    ] {
        fields.remove(field);
    }
    if provider == "claude" {
        fields.insert("provider".into(), json!(provider));
    } else {
        fields.remove("provider");
    }
    fields.insert("model".into(), json!(model));
    if let Some(effort) = effort {
        fields.insert("config".into(), json!({"model_reasoning_effort": effort}));
    }
}

fn latest_sol(catalog: &Value) -> Option<&Value> {
    catalog["data"]
        .as_array()?
        .iter()
        .filter(|row| {
            row.get("modelProvider")
                .is_none_or(|provider| provider.is_null() || provider == "openai")
        })
        .filter(|row| row["hidden"] != true)
        .filter_map(|row| {
            let model = row["model"].as_str()?;
            let version = model
                .strip_prefix("gpt-")?
                .strip_suffix("-sol")?
                .split('.')
                .map(str::parse::<u32>)
                .collect::<Result<Vec<_>, _>>()
                .ok()?;
            Some((version, row))
        })
        .max_by(|left, right| left.0.cmp(&right.0))
        .map(|(_, row)| row)
}

#[cfg(test)]
mod tests;
