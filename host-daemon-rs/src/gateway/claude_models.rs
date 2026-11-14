use std::collections::HashSet;
use std::time::{Duration, Instant};

use anyhow::{Result, bail, ensure};
use serde_json::{Value, json};
use tokio::sync::Mutex;

use crate::providers::router::{Router, RouterConfig};

const REFRESH_INTERVAL: Duration = Duration::from_secs(60);
const REFRESH_BUDGET: Duration = Duration::from_secs(8);

pub(super) struct Catalog {
    router: Option<Router>,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    refreshed: Option<Instant>,
    rows: Vec<Value>,
    failed: bool,
}

impl Catalog {
    pub(super) fn new(config: Option<RouterConfig>) -> Self {
        let router = config.and_then(|config| Router::new(Some(config)).ok());
        Self {
            router,
            state: Mutex::new(State::default()),
        }
    }

    pub(super) async fn rows(&self) -> Vec<Value> {
        let Some(router) = &self.router else {
            return Vec::new();
        };
        let mut state = self.state.lock().await;
        if state
            .refreshed
            .is_some_and(|at| at.elapsed() < REFRESH_INTERVAL)
        {
            return state.rows.clone();
        }
        let result = tokio::time::timeout(REFRESH_BUDGET, fetch(router)).await;
        state.refreshed = Some(Instant::now());
        let error = match result {
            Ok(Ok(rows)) => {
                state.rows = rows;
                state.failed = false;
                return state.rows.clone();
            }
            Ok(Err(error)) => error.to_string(),
            Err(_) => "timed out".to_owned(),
        };
        if !state.failed {
            tracing::warn!(%error, "Claude model catalog refresh failed; keeping the last list");
        }
        state.failed = true;
        state.rows.clone()
    }
}

async fn fetch(router: &Router) -> Result<Vec<Value>> {
    let mut models = Vec::new();
    let mut after = None;
    let mut cursors = HashSet::new();
    for _ in 0..64 {
        let page = router.anthropic_models(after.as_deref()).await?;
        models.extend(
            page["data"]
                .as_array()
                .ok_or_else(|| anyhow::anyhow!("missing model data"))?
                .iter()
                .cloned(),
        );
        match page["has_more"].as_bool() {
            Some(false) => return Ok(rows(&models)),
            Some(true) => {
                let next = page["last_id"]
                    .as_str()
                    .filter(|id| !id.is_empty())
                    .ok_or_else(|| anyhow::anyhow!("missing cursor"))?;
                ensure!(cursors.insert(next.to_owned()), "repeated cursor");
                after = Some(next.to_owned());
            }
            None => bail!("missing pagination state"),
        }
    }
    bail!("too many model pages")
}

fn rows(models: &[Value]) -> Vec<Value> {
    let mut families: Vec<(&str, &Value, bool)> = Vec::new();
    for model in models {
        let family = model["line"].as_str().or_else(|| {
            model["id"]
                .as_str()?
                .strip_prefix("claude-")?
                .split('-')
                .next()
        });
        let Some(family) = family.filter(|value| {
            crate::providers::claude::exec::is_family_alias(value) && !value.contains('[')
        }) else {
            continue;
        };
        let active = model["lifecycle"] == "active";
        if let Some(existing) = families.iter_mut().find(|(name, _, _)| *name == family) {
            existing.2 |= active;
        } else {
            families.push((family, model, active));
        }
    }
    families.into_iter().filter(|(_, _, active)| *active).map(|(family, model, _)| {
        let effort = &model["capabilities"]["effort"];
        let levels: Vec<_> = ["low", "medium", "high", "xhigh", "max"].into_iter()
            .filter(|level| effort["supported"] == true && effort[*level]["supported"] == true)
            .collect();
        let default = if levels.contains(&"high") { "high" } else { levels.first().copied().unwrap_or("none") };
        let efforts: Vec<_> = levels.iter().map(|level| json!({"reasoningEffort":level,"description":""})).collect();
        let mut modalities = vec!["text"];
        if model["capabilities"]["image_input"]["supported"] == true { modalities.push("image"); }
        let display = format!("Claude {}{}", family[..1].to_ascii_uppercase(), &family[1..]);
        json!({
            "id":family, "model":family, "displayName":display, "description":"", "hidden":false,
            "supportedReasoningEfforts":efforts, "defaultReasoningEffort":default,
            "inputModalities":modalities, "supportsPersonality":false,
            "additionalSpeedTiers": if family == "opus" { vec!["fast"] } else { vec![] },
            "serviceTiers":[], "isDefault":false, "agentProvider":"claude"
        })
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_groups_lines_and_preserves_newest_capabilities() {
        let models = json!([
            {"id":"claude-mythos-5-2", "line":"mythos", "lifecycle":"active", "capabilities":{"effort":{"supported":true,"low":{"supported":true},"high":{"supported":true},"max":{"supported":true}},"image_input":{"supported":true}}},
            {"id":"claude-opus-5-1", "lifecycle":"active", "capabilities":{}},
            {"id":"claude-mythos-5-1", "line":"mythos", "lifecycle":"deprecated", "capabilities":{}},
            {"id":"claude-retired-1", "line":"retired", "lifecycle":"retired"}
        ]);
        let rows = rows(models.as_array().unwrap());
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["model"], "mythos");
        assert_eq!(rows[0]["agentProvider"], "claude");
        assert!(rows[0].get("modelProvider").is_none());
        assert_eq!(rows[0]["defaultReasoningEffort"], "high");
        assert_eq!(
            rows[0]["supportedReasoningEfforts"]
                .as_array()
                .unwrap()
                .len(),
            3
        );
        assert_eq!(rows[0]["inputModalities"], json!(["text", "image"]));
        assert_eq!(rows[1]["additionalSpeedTiers"], json!(["fast"]));
    }
}
