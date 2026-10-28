use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;

use crate::agents::jobs::model::{CyberAccessProgram, ExecutionSettings};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Model {
    id: String,
    model: String,
    model_provider: Option<String>,
    supported_reasoning_efforts: Vec<Effort>,
    default_reasoning_effort: String,
}

#[derive(Debug, Deserialize)]
struct Effort {
    #[serde(rename = "reasoningEffort")]
    effort: String,
}

fn family(model: &str) -> Option<(Vec<u32>, &str)> {
    let (version, family) = model.strip_prefix("gpt-")?.rsplit_once('-')?;
    if !matches!(family, "luna" | "sol" | "astra") {
        return None;
    }
    let version = version
        .split('.')
        .map(str::parse)
        .collect::<Result<Vec<u32>, _>>()
        .ok()?;
    (!version.is_empty()).then_some((version, family))
}

pub(super) fn codex(
    input: &str,
    effort: Option<&str>,
    service_tier: Option<&str>,
    models: &[Model],
) -> Result<ExecutionSettings> {
    let normalized = input.to_ascii_lowercase();
    let requested_family = normalized
        .strip_prefix("codex-")
        .filter(|family| matches!(*family, "luna" | "sol" | "astra"))
        .or_else(|| family(&normalized).map(|(_, family)| family));
    let selected = if normalized == "codex-daybreak-blue" {
        models.iter().find(|model| model.model_provider.is_none() && model.model == "gpt-6-sol")
    } else if let Some(requested_family) = requested_family {
        models.iter().filter_map(|model| {
            if model.model_provider.is_some() {
                return None;
            }
            let (version, candidate_family) = family(&model.model)?;
            (candidate_family == requested_family).then_some((version, model))
        }).max_by(|(left, _), (right, _)| left.cmp(right)).map(|(_, model)| model)
    } else {
        models.iter().find(|model| model.model_provider.is_some() && model.id == input)
    }.with_context(|| format!("Model {input:?} is not available in the gateway catalog; use codex-luna, codex-sol, codex-astra or an exact external model ID"))?;
    ensure!(
        selected.model_provider.as_deref() != Some("claude"),
        "Claude catalog entries require spawn_agent claude MODEL; they cannot run through the native Codex adapter"
    );
    let external = selected.model_provider.is_some();
    ensure!(
        !external || service_tier.is_none_or(|tier| tier == "standard"),
        "External models have no service tiers"
    );
    let default = if external {
        selected.default_reasoning_effort.as_str()
    } else {
        match family(&selected.model).map(|(_, family)| family) {
            Some("luna") => "xhigh",
            Some("sol" | "astra") => "medium",
            _ => bail!("The selected native model has no supported family default"),
        }
    };
    let effort = effort.unwrap_or(default);
    ensure!(
        selected
            .supported_reasoning_efforts
            .iter()
            .any(|candidate| candidate.effort == effort),
        "Model {} does not list reasoning effort {effort:?}",
        selected.model
    );
    let service_tier = match service_tier {
        Some("fast" | "flex") if !external => service_tier.map(str::to_owned),
        Some("standard") | None => None,
        _ => bail!("Service tier must be standard, fast or flex"),
    };
    Ok(ExecutionSettings::Codex {
        model: selected.model.clone(),
        model_provider: selected
            .model_provider
            .clone()
            .unwrap_or_else(|| "openai".into()),
        effort: effort.to_owned(),
        service_tier,
        cyber_access_program: (normalized == "codex-daybreak-blue")
            .then_some(CyberAccessProgram::DaybreakBlue),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn catalog() -> Vec<Model> {
        serde_json::from_value(serde_json::json!([
            {"id":"gpt-6.2-sol","model":"gpt-6.2-sol","supportedReasoningEfforts":[{"reasoningEffort":"medium"}],"defaultReasoningEffort":"low"},
            {"id":"gpt-6.10-sol","model":"gpt-6.10-sol","supportedReasoningEfforts":[{"reasoningEffort":"medium"},{"reasoningEffort":"xhigh"}],"defaultReasoningEffort":"low"},
            {"id":"external/model","model":"external/model","modelProvider":"relay","supportedReasoningEfforts":[{"reasoningEffort":"none"}],"defaultReasoningEffort":"none"}
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
    }
}
