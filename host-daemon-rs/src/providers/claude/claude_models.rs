use std::collections::HashSet;
use std::time::{Duration, Instant};

use anyhow::{Result, bail, ensure};
use indexmap::IndexMap;
use serde_json::{Map, Value, json};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
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
    models: Models,
    failed: bool,
}

#[derive(Clone, Default)]
pub(super) struct Models {
    pub(super) rows: Vec<Value>,
    pub(super) overrides: Map<String, Value>,
}

impl Catalog {
    pub(super) fn new(config: Option<RouterConfig>) -> Self {
        let router = config.and_then(|config| Router::new(Some(config)).ok());
        Self {
            router,
            state: Mutex::new(State::default()),
        }
    }

    pub(super) async fn models(&self) -> Models {
        let Some(router) = &self.router else {
            return Models::default();
        };
        let mut state = self.state.lock().await;
        if state
            .refreshed
            .is_some_and(|at| at.elapsed() < REFRESH_INTERVAL)
        {
            return state.models.clone();
        }
        let result = tokio::time::timeout(REFRESH_BUDGET, fetch(router)).await;
        state.refreshed = Some(Instant::now());
        let error = match result {
            Ok(Ok(models)) => {
                state.models = models;
                state.failed = false;
                return state.models.clone();
            }
            Ok(Err(error)) => error.to_string(),
            Err(_) => "timed out".to_owned(),
        };
        if !state.failed {
            tracing::warn!(%error, "Claude model catalog refresh failed; keeping the last list");
        }
        state.failed = true;
        state.models.clone()
    }
}

async fn fetch(router: &Router) -> Result<Models> {
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
            Some(false) => {
                let catalog = rows(&models);
                ensure!(!catalog.overrides.is_empty(), "no active Claude models");
                return Ok(catalog);
            }
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

fn rows(models: &[Value]) -> Models {
    let mut families = IndexMap::<&str, (&Value, &str, OffsetDateTime)>::new();
    for model in models.iter().filter(|model| model["lifecycle"] == "active") {
        let Some(family) = model["line"]
            .as_str()
            .filter(|value| super::exec::is_family_alias(value) && !value.contains('['))
        else {
            continue;
        };
        let Some(id) = model["id"].as_str().filter(|id| !id.is_empty()) else {
            continue;
        };
        let Some(created) = model["created_at"]
            .as_str()
            .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok())
        else {
            continue;
        };
        let latest = families.entry(family).or_insert((model, id, created));
        if created > latest.2 {
            *latest = (model, id, created);
        }
    }

    let mut catalog = Models::default();
    for (family, (model, id, _)) in families {
        catalog.overrides.insert(id.to_owned(), json!(family));
        let effort = &model["capabilities"]["effort"];
        let levels: Vec<_> = ["low", "medium", "high", "xhigh", "max"]
            .into_iter()
            .filter(|level| effort["supported"] == true && effort[*level]["supported"] == true)
            .collect();
        let default = if levels.contains(&"high") {
            "high"
        } else {
            levels.first().copied().unwrap_or("none")
        };
        let efforts: Vec<_> = levels
            .iter()
            .map(|level| json!({"reasoningEffort":level,"description":""}))
            .collect();
        let mut modalities = vec!["text"];
        if model["capabilities"]["image_input"]["supported"] == true {
            modalities.push("image");
        }
        let display = format!(
            "Claude {}{}",
            family[..1].to_ascii_uppercase(),
            &family[1..]
        );
        catalog.rows.push(json!({
            "id":family, "model":family, "displayName":display, "description":"", "hidden":false,
            "supportedReasoningEfforts":efforts, "defaultReasoningEffort":default,
            "inputModalities":modalities, "supportsPersonality":false,
            "additionalSpeedTiers": if family == "opus" { vec!["fast"] } else { vec![] },
            "serviceTiers":[], "isDefault":false, "agentProvider":"claude"
        }));
    }
    catalog
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_groups_lines_and_preserves_newest_capabilities() {
        let models = json!([
            {"id":"claude-mythos-5-3", "line":"mythos", "lifecycle":"deprecated", "created_at":"2026-11-12T00:00:00Z"},
            {"id":"claude-mythos-5-1", "line":"mythos", "lifecycle":"active", "created_at":"2026-11-09T00:00:00Z"},
            {"id":"claude-mythos-5-2", "line":"mythos", "lifecycle":"active", "created_at":"2026-11-11T00:00:00Z", "capabilities":{"effort":{"supported":true,"low":{"supported":true},"high":{"supported":true},"max":{"supported":true}},"image_input":{"supported":true}}},
            {"id":"claude-opus-5-1", "line":"opus", "lifecycle":"active", "created_at":"2026-11-10T00:00:00Z"},
            {"id":"claude-missing-1", "lifecycle":"active", "created_at":"2026-11-10T00:00:00Z"},
            {"id":"claude-retired-1", "line":"retired", "lifecycle":"retired", "created_at":"2026-11-10T00:00:00Z"}
        ]);
        let catalog = rows(models.as_array().unwrap());
        assert_eq!(
            json!(catalog.overrides),
            json!({"claude-mythos-5-2":"mythos","claude-opus-5-1":"opus"})
        );
        let rows = catalog.rows;
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
