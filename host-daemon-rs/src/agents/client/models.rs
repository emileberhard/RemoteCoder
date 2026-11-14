use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;

use crate::agents::jobs::model::{CyberAccessProgram, ExecutionSettings, Provider};
use crate::providers::claude::exec::is_native_model;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Model {
    id: String,
    model: String,
    model_provider: Option<String>,
    agent_provider: Option<String>,
    supported_reasoning_efforts: Vec<Effort>,
    default_reasoning_effort: String,
}

#[derive(Debug, Deserialize)]
struct Effort {
    #[serde(rename = "reasoningEffort")]
    effort: String,
}

pub(super) fn is_claude_alias(model: &str) -> bool {
    crate::providers::claude::exec::is_family_alias(model)
}

fn family(model: &str) -> Option<(Vec<u32>, &str)> {
    let (version, family) = model.strip_prefix("gpt-")?.rsplit_once('-')?;
    if !is_family_name(family) {
        return None;
    }
    let version = version
        .split('.')
        .map(str::parse)
        .collect::<Result<Vec<u32>, _>>()
        .ok()?;
    (!version.is_empty()).then_some((version, family))
}

fn is_family_name(family: &str) -> bool {
    !family.is_empty() && family.bytes().all(|byte| byte.is_ascii_lowercase())
}

fn resolve_effort(selected: &Model, effort: Option<&str>, default: &str) -> Result<String> {
    let effort = effort.unwrap_or(default);
    ensure!(
        selected
            .supported_reasoning_efforts
            .iter()
            .any(|candidate| candidate.effort == effort),
        "Model {} does not list reasoning effort {effort:?}",
        selected.model
    );
    Ok(effort.to_owned())
}

fn validate_external<'a>(
    selected: &'a Model,
    target: Provider,
    effort: Option<&'a str>,
    service_tier: Option<&'a str>,
) -> Result<(&'a str, String)> {
    match target {
        Provider::Codex => ensure!(
            selected.model_provider.as_deref() != Some("claude")
                && selected.agent_provider.as_deref() != Some("claude"),
            "Claude catalog entries require spawn_agent claude MODEL; they cannot run through the native Codex adapter"
        ),
        Provider::Claude => ensure!(
            selected.model_provider.is_some()
                && selected.agent_provider.as_deref() != Some("codex"),
            "Codex catalog entries require spawn_agent codex MODEL; they cannot run through the Claude adapter"
        ),
    }
    let model_provider = selected
        .model_provider
        .as_deref()
        .filter(|provider| !provider.is_empty() && !matches!(*provider, "openai" | "claude"))
        .with_context(|| {
            format!(
                "External model {} has no valid modelProvider in the gateway catalog",
                selected.id
            )
        })?;
    ensure!(
        !selected.model.is_empty()
            && selected.agent_provider.as_deref() == Some(target.as_str())
            && (target != Provider::Claude
                || (!is_native_model(&selected.id) && !is_native_model(&selected.model))),
        "External model {} has no verified {} harness capability in the gateway catalog",
        selected.id,
        target.as_str()
    );
    ensure!(
        service_tier.is_none_or(|tier| tier == "standard"),
        "External models have no service tiers"
    );
    let effort = resolve_effort(selected, effort, selected.default_reasoning_effort.as_str())?;
    Ok((model_provider, effort))
}

pub(super) fn codex(
    input: &str,
    effort: Option<&str>,
    service_tier: Option<&str>,
    models: &[Model],
) -> Result<ExecutionSettings> {
    let normalized = input.to_ascii_lowercase();
    let newest = |requested: &str| {
        models
            .iter()
            .filter_map(|model| {
                if model.model_provider.is_some() {
                    return None;
                }
                let (version, candidate) = family(&model.model)?;
                (candidate == requested).then_some((version, model))
            })
            .max_by(|(left, _), (right, _)| left.cmp(right))
            .map(|(_, model)| model)
    };
    let external = models
        .iter()
        .find(|model| model.model_provider.is_some() && model.id == input);
    let selected = if normalized == "codex-daybreak-blue" {
        models
            .iter()
            .find(|model| model.model_provider.is_none() && model.model == "gpt-6-sol")
    } else if let Some(requested) = normalized
        .strip_prefix("codex-")
        .filter(|family| is_family_name(family))
    {
        newest(requested)
    } else if let Some((_, requested)) = family(&normalized) {
        let native = newest(requested);
        ensure!(
            native.is_none() || external.is_none(),
            "Model {input:?} names both an external model and the native {requested} family; use codex-{requested} for the native model"
        );
        native.or(external)
    } else {
        external
    }
    .with_context(|| {
        let mut families: Vec<_> = models
            .iter()
            .filter(|model| model.model_provider.is_none())
            .filter_map(|model| family(&model.model).map(|(_, family)| format!("codex-{family}")))
            .collect();
        families.sort();
        families.dedup();
        format!(
            "Model {input:?} is not available in the gateway catalog; use {} or an exact external model ID",
            families.join(", ")
        )
    })?;
    if selected.model_provider.is_some() {
        let (model_provider, effort) =
            validate_external(selected, Provider::Codex, effort, service_tier)?;
        return Ok(ExecutionSettings::Codex {
            model: selected.model.clone(),
            model_provider: model_provider.to_owned(),
            effort,
            service_tier: None,
            cyber_access_program: None,
        });
    }
    ensure!(
        selected
            .agent_provider
            .as_deref()
            .is_none_or(|provider| provider == "codex"),
        "Model {} has no verified Codex harness capability in the gateway catalog",
        selected.id
    );
    let default = match family(&selected.model).map(|(_, family)| family) {
        Some("luna") => "xhigh",
        Some("sol" | "astra") => "medium",
        _ => selected.default_reasoning_effort.as_str(),
    };
    let effort = resolve_effort(selected, effort, default)?;
    let service_tier = match service_tier {
        Some("fast" | "flex") => service_tier.map(str::to_owned),
        Some("standard") | None => None,
        _ => bail!("Service tier must be standard, fast or flex"),
    };
    Ok(ExecutionSettings::Codex {
        model: selected.model.clone(),
        model_provider: "openai".into(),
        effort,
        service_tier,
        cyber_access_program: (normalized == "codex-daybreak-blue")
            .then_some(CyberAccessProgram::DaybreakBlue),
    })
}

pub(super) fn claude(
    input: &str,
    effort: Option<&str>,
    service_tier: Option<&str>,
    models: &[Model],
) -> Result<ExecutionSettings> {
    if is_claude_alias(input) {
        ensure!(
            service_tier.is_none_or(|tier| matches!(tier, "standard" | "fast")),
            "Claude supports standard or fast mode"
        );
        return Ok(ExecutionSettings::Claude {
            model: input.to_ascii_lowercase(),
            effort: effort.map(str::to_owned),
            fast: service_tier == Some("fast"),
        });
    }
    let selected = models
        .iter()
        .find(|model| model.model_provider.is_some() && model.id == input)
        .or_else(|| models.iter().find(|model| model.id == input))
        .with_context(|| {
            format!(
                "Model {input:?} is not available in the gateway catalog; use a Claude moving alias or an exact external model ID"
            )
        })?;
    let (_, effort) = validate_external(selected, Provider::Claude, effort, service_tier)?;
    Ok(ExecutionSettings::Claude {
        model: selected.model.clone(),
        effort: Some(effort),
        fast: false,
    })
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;

    pub(in crate::agents::client) fn catalog() -> Vec<Model> {
        serde_json::from_value(serde_json::json!([
            {"id":"gpt-6.2-sol","model":"gpt-6.2-sol","supportedReasoningEfforts":[{"reasoningEffort":"medium"}],"defaultReasoningEffort":"low"},
            {"id":"gpt-6.10-sol","model":"gpt-6.10-sol","supportedReasoningEfforts":[{"reasoningEffort":"medium"},{"reasoningEffort":"xhigh"}],"defaultReasoningEffort":"low"},
            {"id":"external/model","model":"external/model","modelProvider":"relay","agentProvider":"codex","supportedReasoningEfforts":[{"reasoningEffort":"none"}],"defaultReasoningEffort":"none"},
            {"id":"copilot/gemini-4-argon","model":"copilot/gemini-4-argon","modelProvider":"copilot","agentProvider":"claude","supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"medium"},{"reasoningEffort":"high"}],"defaultReasoningEffort":"medium"}
        ])).unwrap()
    }

    #[test]
    fn family_alias_uses_the_newest_numeric_version_and_family_effort() {
        assert_eq!(
            codex("gpt-5-sol", None, None, &catalog()).unwrap(),
            ExecutionSettings::Codex {
                model: "gpt-6.10-sol".into(),
                model_provider: "openai".into(),
                effort: "medium".into(),
                service_tier: None,
                cyber_access_program: None,
            }
        );
        assert!(codex("codex-sol", Some("high"), None, &catalog()).is_err());
    }

    #[test]
    fn a_catalog_family_without_local_policy_uses_its_newest_model_and_catalog_effort() {
        let mut models = catalog();
        models.extend(serde_json::from_value::<Vec<Model>>(serde_json::json!([
            {"id":"gpt-5.6-terra","model":"gpt-5.6-terra","supportedReasoningEfforts":[{"reasoningEffort":"medium"}],"defaultReasoningEffort":"medium"},
            {"id":"gpt-6.1-terra","model":"gpt-6.1-terra","supportedReasoningEfforts":[{"reasoningEffort":"low"}],"defaultReasoningEffort":"low"}
        ])).unwrap());
        for alias in ["codex-terra", "gpt-6.1-terra"] {
            assert_eq!(
                codex(alias, None, None, &models).unwrap(),
                ExecutionSettings::Codex {
                    model: "gpt-6.1-terra".into(),
                    model_provider: "openai".into(),
                    effort: "low".into(),
                    service_tier: None,
                    cyber_access_program: None,
                }
            );
        }
        let error = codex("codex-nova", None, None, &models)
            .unwrap_err()
            .to_string();
        assert!(error.contains("codex-sol, codex-terra"));
    }

    #[test]
    fn an_exact_external_id_keeps_its_provider_unless_a_native_family_shares_it() {
        let mut models = catalog();
        models.extend(serde_json::from_value::<Vec<Model>>(serde_json::json!([
            {"id":"gpt-6.1-nova","model":"gpt-6.1-nova","modelProvider":"relay","agentProvider":"codex","supportedReasoningEfforts":[{"reasoningEffort":"none"}],"defaultReasoningEffort":"none"},
            {"id":"gpt-6.2-sol","model":"gpt-6.2-sol","modelProvider":"relay","agentProvider":"codex","supportedReasoningEfforts":[{"reasoningEffort":"none"}],"defaultReasoningEffort":"none"}
        ])).unwrap());
        assert_eq!(
            codex("gpt-6.1-nova", None, None, &models).unwrap(),
            ExecutionSettings::Codex {
                model: "gpt-6.1-nova".into(),
                model_provider: "relay".into(),
                effort: "none".into(),
                service_tier: None,
                cyber_access_program: None,
            }
        );
        assert!(codex("gpt-6.2-sol", None, None, &models).is_err());
        assert!(codex("codex-sol", None, None, &models).is_ok());
    }

    #[test]
    fn external_selection_preserves_exact_provider_and_rejects_fast_mode() {
        assert_eq!(
            codex("external/model", None, None, &catalog()).unwrap(),
            ExecutionSettings::Codex {
                model: "external/model".into(),
                model_provider: "relay".into(),
                effort: "none".into(),
                service_tier: None,
                cyber_access_program: None,
            }
        );
        assert!(codex("external/model", None, Some("fast"), &catalog()).is_err());
        assert!(codex("EXTERNAL/MODEL", None, None, &catalog()).is_err());
    }

    #[test]
    fn approved_program_alias_retains_its_program_and_exact_model() {
        let mut models = catalog();
        models.push(serde_json::from_value(serde_json::json!({"id":"gpt-6-sol","model":"gpt-6-sol","supportedReasoningEfforts":[{"reasoningEffort":"medium"},{"reasoningEffort":"max"}],"defaultReasoningEffort":"medium"})).unwrap());
        assert_eq!(
            codex("codex-daybreak-blue", Some("max"), None, &models).unwrap(),
            ExecutionSettings::Codex {
                model: "gpt-6-sol".into(),
                model_provider: "openai".into(),
                effort: "max".into(),
                service_tier: None,
                cyber_access_program: Some(CyberAccessProgram::DaybreakBlue),
            }
        );
    }

    #[test]
    fn claude_catalog_entry_never_becomes_native_codex_execution() {
        let models: Vec<Model> = serde_json::from_value(serde_json::json!([
            {"id":"claude/opus","model":"opus","modelProvider":"claude","supportedReasoningEfforts":[{"reasoningEffort":"high"}],"defaultReasoningEffort":"high"}
        ])).unwrap();
        assert!(codex("claude/opus", None, None, &models).is_err());
        assert!(codex("copilot/gemini-4-argon", Some("high"), None, &catalog()).is_err());
    }

    #[test]
    fn claude_admits_moving_aliases_and_matching_external_catalog_rows() {
        assert_eq!(
            claude("OPUS[1M]", Some("xhigh"), Some("fast"), &[]).unwrap(),
            ExecutionSettings::Claude {
                model: "opus[1m]".into(),
                effort: Some("xhigh".into()),
                fast: true,
            }
        );
        assert!(claude("opus", None, Some("flex"), &[]).is_err());
        assert!(claude("claude-opus-4-7", None, None, &catalog()).is_err());
        assert_eq!(
            claude("copilot/gemini-4-argon", Some("high"), None, &catalog()).unwrap(),
            ExecutionSettings::Claude {
                model: "copilot/gemini-4-argon".into(),
                effort: Some("high".into()),
                fast: false,
            }
        );
        assert_eq!(
            claude("copilot/gemini-4-argon", None, Some("standard"), &catalog()).unwrap(),
            ExecutionSettings::Claude {
                model: "copilot/gemini-4-argon".into(),
                effort: Some("medium".into()),
                fast: false,
            }
        );
        assert!(claude("COPILOT/GEMINI-4-ARGON", Some("high"), None, &catalog()).is_err());
        assert!(claude("copilot/gemini-4-argon", Some("xhigh"), None, &catalog()).is_err());
        assert!(
            claude(
                "copilot/gemini-4-argon",
                Some("high"),
                Some("fast"),
                &catalog()
            )
            .is_err()
        );
        assert!(
            claude(
                "copilot/gemini-4-argon",
                Some("high"),
                Some("flex"),
                &catalog()
            )
            .is_err()
        );
    }

    #[test]
    fn external_rows_with_missing_or_mismatched_harness_capability_fail_visibly() {
        let models: Vec<Model> = serde_json::from_value(serde_json::json!([
            {"id":"copilot/missing-harness","model":"copilot/missing-harness","modelProvider":"copilot","supportedReasoningEfforts":[{"reasoningEffort":"high"}],"defaultReasoningEffort":"high"},
            {"id":"copilot/unknown-harness","model":"copilot/unknown-harness","modelProvider":"copilot","agentProvider":"other","supportedReasoningEfforts":[{"reasoningEffort":"high"}],"defaultReasoningEffort":"high"},
            {"id":"copilot/native-conflict","model":"opus","modelProvider":"copilot","agentProvider":"claude","supportedReasoningEfforts":[{"reasoningEffort":"high"}],"defaultReasoningEffort":"high"},
            {"id":"claude/invalid-provider","model":"claude/invalid-provider","modelProvider":"claude","agentProvider":"claude","supportedReasoningEfforts":[{"reasoningEffort":"high"}],"defaultReasoningEffort":"high"}
        ])).unwrap();
        for id in [
            "copilot/missing-harness",
            "copilot/unknown-harness",
            "copilot/native-conflict",
            "claude/invalid-provider",
        ] {
            assert!(codex(id, Some("high"), None, &models).is_err(), "{id}");
            assert!(claude(id, Some("high"), None, &models).is_err(), "{id}");
        }
        assert!(claude("external/model", None, None, &catalog()).is_err());
        assert!(claude("gpt-6.2-sol", None, None, &catalog()).is_err());
    }
}
