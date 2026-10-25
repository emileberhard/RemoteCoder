use crate::config::ConfigSources;
use crate::rpc::RpcError;
use crate::rpc::error::RpcCode;
use crate::storage::private_state;
use anyhow::{Context, Result, anyhow, ensure};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tracing::{debug, info, warn};

pub(crate) const EXTERNAL_PROVIDERS_ENV_KEY: &str = "RC_CODEX_GATEWAY_EXTERNAL_PROVIDERS_FILE";
pub(crate) const NATIVE_PROVIDER: &str = "openai";
const CATALOG_DIRECTORY: &str = "external-models";
const MAX_CONFIG_BYTES: u64 = 64 * 1024;
const MAX_CATALOG_BYTES: u64 = 1024 * 1024;
const MAX_LISTING_BYTES: usize = 4 * 1024 * 1024;
const MAX_PROVIDERS: usize = 8;
const MAX_MODELS: usize = 16;
const REFRESH_BUDGET: Duration = Duration::from_secs(5);

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ExternalProvider {
    id: String,
    name: String,
    #[serde(deserialize_with = "base_url")]
    base_url: reqwest::Url,
    key_file: PathBuf,
    models: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ExternalProvidersFile {
    providers: Vec<ExternalProvider>,
}

fn base_url<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<reqwest::Url, D::Error> {
    let raw = String::deserialize(deserializer)?;
    reqwest::Url::parse(&raw).map_err(serde::de::Error::custom)
}

pub(crate) fn load(sources: &ConfigSources) -> Result<Vec<ExternalProvider>> {
    let Some(path) = sources.optional_string(EXTERNAL_PROVIDERS_ENV_KEY) else {
        return Ok(Vec::new());
    };
    let path = PathBuf::from(path);
    ensure!(
        path.is_absolute(),
        "{EXTERNAL_PROVIDERS_ENV_KEY} must be an absolute path"
    );
    let bytes = private_state::read_bounded(&path, MAX_CONFIG_BYTES)
        .map_err(|_| {
            anyhow!("{EXTERNAL_PROVIDERS_ENV_KEY} must name a regular file of at most 64 KiB")
        })?
        .with_context(|| format!("{EXTERNAL_PROVIDERS_ENV_KEY} names a missing file"))?;
    let file: ExternalProvidersFile = serde_json::from_slice(&bytes)
        .with_context(|| format!("{EXTERNAL_PROVIDERS_ENV_KEY} is not a valid provider list"))?;
    validate(&file.providers)?;
    Ok(file.providers)
}

fn validate(providers: &[ExternalProvider]) -> Result<()> {
    ensure!(
        providers.len() <= MAX_PROVIDERS,
        "{EXTERNAL_PROVIDERS_ENV_KEY} lists more than {MAX_PROVIDERS} providers"
    );
    let mut ids = BTreeSet::new();
    let mut models = BTreeSet::new();
    for provider in providers {
        let id = provider.id.as_str();
        ensure!(
            !id.is_empty()
                && id.len() <= 64
                && id.bytes().all(|byte| byte.is_ascii_lowercase()
                    || byte.is_ascii_digit()
                    || b"-_".contains(&byte))
                && !matches!(id, NATIVE_PROVIDER | "claude"),
            "external provider ids must be 1–64 lowercase letters, digits, - or _, other than openai and claude"
        );
        ensure!(ids.insert(id), "external provider {id} is listed twice");
        ensure!(
            !provider.name.trim().is_empty()
                && provider.name.len() <= 64
                && !provider.name.chars().any(char::is_control),
            "external provider {id} needs a name of 1–64 bytes"
        );
        let url = &provider.base_url;
        ensure!(
            matches!(url.scheme(), "http" | "https")
                && url.host_str().is_some()
                && url.username().is_empty()
                && url.password().is_none()
                && url.query().is_none()
                && url.fragment().is_none(),
            "external provider {id} baseUrl must be an HTTP(S) URL without credentials, query or fragment"
        );
        ensure!(
            provider.key_file.is_absolute(),
            "external provider {id} keyFile must be an absolute path"
        );
        ensure!(
            !provider.models.is_empty() && provider.models.len() <= MAX_MODELS,
            "external provider {id} must enable 1–{MAX_MODELS} models"
        );
        for model in &provider.models {
            ensure!(
                !model.is_empty()
                    && model.len() <= 256
                    && !model.chars().any(|c| c.is_control() || c.is_whitespace()),
                "external provider {id} lists an invalid model id"
            );
            ensure!(
                models.insert(model.as_str()),
                "model {model} is enabled for more than one external provider"
            );
        }
    }
    Ok(())
}

pub(crate) struct ExternalProviders {
    providers: Vec<ExternalProvider>,
    directory: PathBuf,
    client: reqwest::Client,
    catalogs: Mutex<BTreeMap<String, Arc<Vec<Value>>>>,
    refresh: tokio::sync::Mutex<()>,
}

impl ExternalProviders {
    pub(crate) fn new(
        providers: Vec<ExternalProvider>,
        state_directory: &Path,
    ) -> Result<Option<Arc<Self>>> {
        let directory = state_directory.join(CATALOG_DIRECTORY);
        if providers.is_empty() {
            if std::fs::symlink_metadata(&directory).is_ok_and(|metadata| metadata.is_dir()) {
                std::fs::remove_dir_all(&directory)
                    .with_context(|| format!("removing {}", directory.display()))?;
            }
            return Ok(None);
        }
        private_state::ensure_private_directory(&directory)?;
        let mut catalogs = BTreeMap::new();
        for entry in std::fs::read_dir(&directory)? {
            let entry = entry?;
            let path = entry.path();
            let provider = providers
                .iter()
                .find(|provider| path == catalog_path(&directory, provider));
            match provider {
                Some(provider) => {
                    if let Some(models) = read_catalog(&path, provider) {
                        catalogs.insert(provider.id.clone(), Arc::new(models));
                    }
                }
                None if entry.file_type()?.is_file() => std::fs::remove_file(&path)
                    .with_context(|| format!("removing {}", path.display()))?,
                None => {}
            }
        }
        Ok(Some(Arc::new(Self {
            providers,
            directory,
            client: reqwest::Client::builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(REFRESH_BUDGET)
                .build()?,
            catalogs: Mutex::new(catalogs),
            refresh: tokio::sync::Mutex::new(()),
        })))
    }

    pub(crate) fn provider_ids(&self) -> impl Iterator<Item = &str> {
        self.providers.iter().map(|provider| provider.id.as_str())
    }

    pub(crate) fn fallback(&self) -> Option<&str> {
        self.provider_ids().next()
    }

    pub(crate) async fn start_on_fallback(
        &self,
        params: &mut Value,
    ) -> std::result::Result<(), RpcError> {
        let (Some(fields), Some(provider)) = (params.as_object_mut(), self.providers.first())
        else {
            return Ok(());
        };
        let native = fields
            .get("modelProvider")
            .and_then(Value::as_str)
            .is_none_or(|id| id == NATIVE_PROVIDER);
        if !native || selected_models(fields).any(|model| self.owner(model).is_some()) {
            return Ok(());
        }
        let models = self.fallback_catalog(provider).await?;
        self.map_onto_fallback(fields, &models);
        if let Some(default) = models.first() {
            if fields.get("model").is_none_or(Value::is_null) {
                fields.insert("model".into(), default["slug"].clone());
            }
            if let Some(model) = fields
                .get_mut("collaborationMode")
                .and_then(|mode| mode.pointer_mut("/settings/model"))
                && model
                    .as_str()
                    .is_some_and(|model| self.owner(model).is_none())
            {
                *model = default["slug"].clone();
            }
        }
        fields.insert("modelProvider".into(), json!(provider.id));
        info!(provider = %provider.id, model = %fields["model"], "starting a new Codex conversation on the fallback provider");
        Ok(())
    }

    async fn map_onto_fallback_thread(
        &self,
        fields: &mut Map<String, Value>,
        source: &str,
    ) -> std::result::Result<bool, RpcError> {
        match self.providers.first().filter(|first| first.id == source) {
            Some(fallback) => {
                let models = self.fallback_catalog(fallback).await?;
                Ok(self.map_onto_fallback(fields, &models))
            }
            None => Ok(false),
        }
    }

    fn map_onto_fallback(&self, fields: &mut Map<String, Value>, models: &[Value]) -> bool {
        let native = |model: &Value| {
            model
                .as_str()
                .filter(|model| self.owner(model).is_none())
                .map(str::to_owned)
        };
        let tiers = [
            fields.remove("serviceTier"),
            fields.remove("serviceTierForTurn"),
        ];
        let mut mapped = tiers.iter().any(Option::is_some);
        if mapped {
            debug!("dropped a service tier for the Codex fallback provider");
        }
        if let Some(requested) = fields.get("model").and_then(native) {
            let slug = matching_model(models, &requested);
            debug!(%requested, fallback = ?slug, "mapped a native model onto the Codex fallback provider");
            match slug {
                Some(slug) => fields.insert("model".into(), slug),
                None => fields.remove("model"),
            };
            mapped = true;
        }
        if let Some(model) = fields
            .get_mut("collaborationMode")
            .and_then(|mode| mode.pointer_mut("/settings/model"))
            && let Some(requested) = native(model)
            && let Some(slug) = matching_model(models, &requested)
        {
            debug!(%requested, fallback = %slug, "mapped a native collaboration model onto the Codex fallback provider");
            *model = slug;
            mapped = true;
        }
        mapped
    }

    async fn fallback_catalog(
        &self,
        provider: &ExternalProvider,
    ) -> std::result::Result<Arc<Vec<Value>>, RpcError> {
        self.catalog(provider).await.ok_or_else(|| {
            RpcError::new(
                RpcCode::Unavailable,
                format!("{} model metadata is unavailable", provider.name),
            )
        })
    }

    fn label<'a>(&'a self, provider_id: &'a str) -> &'a str {
        match self
            .providers
            .iter()
            .find(|provider| provider.id == provider_id)
        {
            Some(provider) => &provider.name,
            None if provider_id == NATIVE_PROVIDER => "ChatGPT",
            None => provider_id,
        }
    }

    pub(crate) async fn refresh(&self) {
        let _refresh = self.refresh.lock().await;
        let fetched = futures_util::future::join_all(
            self.providers.iter().map(|provider| self.fetch(provider)),
        )
        .await;
        for (provider, result) in self.providers.iter().zip(fetched) {
            if let Err(error) = result.and_then(|models| self.publish(provider, models)) {
                warn!(provider = %provider.id, "external model catalog refresh failed: {error:#}");
            }
        }
    }

    pub(crate) fn model_rows(&self) -> Vec<Value> {
        let catalogs = self.catalogs.lock().expect("external catalogs poisoned");
        self.providers
            .iter()
            .filter_map(|provider| catalogs.get(&provider.id).map(|models| (provider, models)))
            .flat_map(|(provider, models)| models.iter().map(|model| picker_row(provider, model)))
            .collect()
    }

    pub(crate) fn thread_to_inspect(method: &str, params: &Value) -> Option<String> {
        let thread = params["threadId"].as_str()?;
        if crate::providers::claude::is_claude_thread_id(thread) {
            return None;
        }
        let selects = |fields: &Map<String, Value>| {
            selected_models(fields).next().is_some() || selects_tier(fields)
        };
        match method {
            "thread/resume" | "thread/fork" | "thread/restart/recover" => Some(thread.to_owned()),
            "turn/start" | "thread/settings/update" | "turn/settings/update"
                if params.as_object().is_some_and(selects) =>
            {
                Some(thread.to_owned())
            }
            _ => None,
        }
    }

    pub(crate) async fn admit(
        &self,
        method: &str,
        params: &mut Value,
        source_provider: Option<&str>,
    ) -> std::result::Result<bool, RpcError> {
        let Some(fields) = params.as_object_mut() else {
            return Ok(false);
        };
        if method != "thread/list" {
            reject_config_selection(fields)?;
        }
        match method {
            "thread/list" => {
                if fields
                    .get("modelProviders")
                    .is_some_and(|value| !value.is_null())
                {
                    return Ok(false);
                }
                let providers = std::iter::once(NATIVE_PROVIDER)
                    .chain(self.provider_ids())
                    .collect::<Vec<_>>();
                fields.insert("modelProviders".into(), json!(providers));
                Ok(true)
            }
            "thread/start" => {
                let requested = fields.get("modelProvider").and_then(Value::as_str);
                let model = fields.get("model").and_then(Value::as_str);
                let provider = match (requested, model.and_then(|model| self.owner(model))) {
                    (Some(requested), _) => requested.to_owned(),
                    (None, Some(owner)) => owner.id.clone(),
                    (None, None) => NATIVE_PROVIDER.to_owned(),
                };
                if requested.is_none() && provider != NATIVE_PROVIDER {
                    fields.insert("modelProvider".into(), json!(provider));
                }
                self.admit_thread(fields, &provider, true, true).await
            }
            "thread/resume" | "thread/fork" | "thread/restart/recover" => {
                let source = source_provider.ok_or_else(|| {
                    RpcError::new(
                        RpcCode::Unavailable,
                        "The conversation's model provider is unknown",
                    )
                })?;
                if let Some(requested) = fields.get("modelProvider").and_then(Value::as_str)
                    && requested != source
                {
                    return Err(invalid(format!(
                        "This conversation runs on {}; start a new conversation to use another provider",
                        self.label(source)
                    )));
                }
                if method == "thread/resume"
                    && source != NATIVE_PROVIDER
                    && fields.get("modelProvider").is_none_or(Value::is_null)
                {
                    fields.insert("modelProvider".into(), json!(source));
                }
                let inherits = method == "thread/fork"
                    && fields.get("experimentalPredictionMode") == Some(&json!(true));
                let mapped = self.map_onto_fallback_thread(fields, source).await?;
                let configured = self.admit_thread(fields, source, false, !inherits).await?;
                Ok(mapped || configured)
            }
            "turn/start" | "thread/settings/update" | "turn/settings/update" => {
                let Some(source) = source_provider else {
                    return Ok(false);
                };
                let mapped = self.map_onto_fallback_thread(fields, source).await?;
                self.check_selection(fields, source).await.map(|_| mapped)
            }
            _ => Ok(false),
        }
    }

    async fn admit_thread(
        &self,
        fields: &mut Map<String, Value>,
        provider_id: &str,
        requires_model: bool,
        configure: bool,
    ) -> std::result::Result<bool, RpcError> {
        let Some(provider) = self.check_selection(fields, provider_id).await? else {
            return Ok(false);
        };
        if requires_model && fields.get("model").is_none_or(Value::is_null) {
            return Err(invalid(format!(
                "Choose a {} model to start a {} conversation",
                provider.name, provider.name
            )));
        }
        if !configure {
            return Ok(false);
        }
        let config = fields
            .entry("config")
            .and_modify(|config| {
                if config.is_null() {
                    *config = json!({});
                }
            })
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .ok_or_else(|| invalid("config must be an object".to_owned()))?;
        config.insert(
            format!("model_providers.{}", provider.id),
            native_provider(provider),
        );
        config.insert(
            "provider_model_catalog_json".into(),
            json!(catalog_path(&self.directory, provider)),
        );
        Ok(true)
    }

    async fn check_selection(
        &self,
        fields: &Map<String, Value>,
        provider_id: &str,
    ) -> std::result::Result<Option<&ExternalProvider>, RpcError> {
        let Some(provider) = self
            .providers
            .iter()
            .find(|provider| provider.id == provider_id)
        else {
            if let Some((model, owner)) = selected_models(fields)
                .find_map(|model| self.owner(model).map(|owner| (model, owner)))
            {
                return Err(invalid(format!(
                    "{model} runs on {}; start a new {} conversation to use it",
                    owner.name, owner.name
                )));
            }
            return Ok(None);
        };
        if selects_tier(fields) {
            return Err(invalid(format!("{} has no service tiers", provider.name)));
        }
        let models = self.catalog(provider).await.ok_or_else(|| {
            RpcError::new(
                RpcCode::Unavailable,
                format!("{} model metadata is unavailable", provider.name),
            )
        })?;
        if let Some(model) =
            selected_models(fields).find(|model| !models.iter().any(|row| row["slug"] == *model))
        {
            return Err(invalid(format!(
                "{model} is not available on {}; this conversation stays on {}",
                provider.name, provider.name
            )));
        }
        Ok(Some(provider))
    }

    fn owner(&self, model: &str) -> Option<&ExternalProvider> {
        self.providers
            .iter()
            .find(|provider| provider.models.iter().any(|id| id == model))
    }

    async fn catalog(&self, provider: &ExternalProvider) -> Option<Arc<Vec<Value>>> {
        let cached = || {
            self.catalogs
                .lock()
                .expect("external catalogs poisoned")
                .get(&provider.id)
                .cloned()
        };
        if let Some(models) = cached() {
            return Some(models);
        }
        self.refresh().await;
        cached()
    }

    async fn fetch(&self, provider: &ExternalProvider) -> Result<Vec<Value>> {
        let key_file = provider.key_file.clone();
        let key =
            tokio::task::spawn_blocking(move || crate::providers::router::read_key(&key_file))
                .await??;
        let url = reqwest::Url::parse(&format!(
            "{}/models",
            provider.base_url.as_str().trim_end_matches('/')
        ))?;
        let mut response = self.client.get(url).bearer_auth(key).send().await?;
        ensure!(
            response.status().is_success(),
            "{} model list answered HTTP {}",
            provider.name,
            response.status()
        );
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await? {
            ensure!(
                body.len() + chunk.len() <= MAX_LISTING_BYTES,
                "{} model list exceeds 4 MiB",
                provider.name
            );
            body.extend_from_slice(&chunk);
        }
        project(provider, &serde_json::from_slice(&body)?)
    }

    fn publish(&self, provider: &ExternalProvider, models: Vec<Value>) -> Result<()> {
        let unchanged = self
            .catalogs
            .lock()
            .expect("external catalogs poisoned")
            .get(&provider.id)
            .is_some_and(|current| **current == models);
        if unchanged {
            return Ok(());
        }
        private_state::write_json(
            &catalog_path(&self.directory, provider),
            &json!({"models": models}),
        )?;
        self.catalogs
            .lock()
            .expect("external catalogs poisoned")
            .insert(provider.id.clone(), Arc::new(models));
        Ok(())
    }
}

fn catalog_path(directory: &Path, provider: &ExternalProvider) -> PathBuf {
    directory.join(format!("{}.json", provider.id))
}

fn read_catalog(path: &Path, provider: &ExternalProvider) -> Option<Vec<Value>> {
    let bytes = private_state::read_bounded(path, MAX_CATALOG_BYTES).ok()??;
    let models = serde_json::from_slice::<Value>(&bytes).ok()?["models"]
        .as_array()?
        .iter()
        .filter(|row| {
            row["slug"]
                .as_str()
                .is_some_and(|slug| provider.models.iter().any(|model| model == slug))
        })
        .cloned()
        .collect::<Vec<_>>();
    (!models.is_empty()).then_some(models)
}

fn native_provider(provider: &ExternalProvider) -> Value {
    json!({
        "name": provider.name,
        "base_url": provider.base_url.as_str().trim_end_matches('/'),
        "wire_api": "responses",
        "auth": {"command": "/bin/cat", "args": [provider.key_file]},
        "capabilities": {"web_search": false},
        "supports_websockets": false,
    })
}

fn project(provider: &ExternalProvider, listing: &Value) -> Result<Vec<Value>> {
    let entries = listing["data"]
        .as_array()
        .context("model list has no data array")?;
    let mut models = Vec::new();
    for (priority, id) in provider.models.iter().enumerate() {
        let Some(entry) = entries.iter().find(|entry| entry["id"] == id.as_str()) else {
            warn!(provider = %provider.id, model = %id, "enabled external model is not listed");
            continue;
        };
        match native_model(id, entry, priority) {
            Ok(model) => models.push(model),
            Err(error) => {
                warn!(provider = %provider.id, model = %id, "external model metadata is unusable: {error:#}")
            }
        }
    }
    ensure!(
        !models.is_empty(),
        "{} lists none of its enabled models with usable metadata",
        provider.name
    );
    Ok(models)
}

fn native_model(id: &str, entry: &Value, priority: usize) -> Result<Value> {
    let capabilities = &entry["capabilities"];
    ensure!(
        capabilities["endpoints"]
            .as_array()
            .is_some_and(|endpoints| endpoints.iter().any(|endpoint| endpoint == "/v1/responses")),
        "it does not serve /v1/responses"
    );
    ensure!(
        capabilities["streaming"] == true && capabilities["tool_calls"] == true,
        "it does not report streaming tool calls"
    );
    let prompt_tokens = capabilities["prompt_tokens"]
        .as_i64()
        .filter(|tokens| *tokens > 0)
        .context("it has no prompt token limit")?;
    let efforts = strings(&capabilities["reasoning_efforts"])
        .filter(|effort| effort.len() <= 32 && effort.bytes().all(|byte| byte.is_ascii_lowercase()))
        .collect::<Vec<_>>();
    let default_effort = efforts
        .iter()
        .find(|effort| **effort == "medium")
        .or(efforts.first());
    let mut modalities = strings(&capabilities["input_modalities"])
        .filter(|modality| matches!(*modality, "text" | "image"))
        .collect::<Vec<_>>();
    if modalities.is_empty() {
        modalities.push("text");
    }
    ensure!(
        modalities.contains(&"text"),
        "it does not accept text input"
    );
    let display_name = entry["display_name"]
        .as_str()
        .filter(|name| !name.trim().is_empty() && name.len() <= 128)
        .unwrap_or(id);
    Ok(json!({
        "slug": id,
        "display_name": display_name,
        "description": null,
        "default_reasoning_level": default_effort,
        "supported_reasoning_levels": efforts
            .iter()
            .map(|effort| json!({"effort": effort, "description": effort}))
            .collect::<Vec<_>>(),
        "shell_type": "unified_exec",
        "visibility": "list",
        "supported_in_api": true,
        "priority": priority,
        "availability_nux": null,
        "upgrade": null,
        "support_verbosity": false,
        "default_verbosity": null,
        "apply_patch_tool_type": "freeform",
        "truncation_policy": {"mode": "tokens", "limit": 10000},
        "context_window": prompt_tokens,
        "max_context_window": prompt_tokens,
        "experimental_supported_tools": [],
        "input_modalities": modalities,
        "use_responses_lite": false,
    }))
}

fn strings(value: &Value) -> impl Iterator<Item = &str> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
}

fn picker_row(provider: &ExternalProvider, model: &Value) -> Value {
    let efforts = model["supported_reasoning_levels"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|level| json!({"reasoningEffort": level["effort"], "description": level["description"]}))
        .collect::<Vec<_>>();
    json!({
        "id": model["slug"],
        "model": model["slug"],
        "upgrade": null,
        "upgradeInfo": null,
        "availabilityNux": null,
        "displayName": model["display_name"],
        "description": "",
        "hidden": false,
        "supportedReasoningEfforts": efforts,
        "defaultReasoningEffort": model["default_reasoning_level"].as_str().unwrap_or("none"),
        "inputModalities": model["input_modalities"],
        "supportsPersonality": false,
        "additionalSpeedTiers": [],
        "serviceTiers": [],
        "isDefault": false,
        "modelProvider": provider.id,
        "modelProviderName": provider.name,
    })
}

fn matching_model(models: &[Value], requested: &str) -> Option<Value> {
    models
        .iter()
        .map(|row| &row["slug"])
        .find(|slug| {
            slug.as_str()
                .is_some_and(|slug| slug.rsplit('/').next() == Some(requested))
        })
        .cloned()
}

fn selected_models(fields: &Map<String, Value>) -> impl Iterator<Item = &str> {
    [
        fields.get("model"),
        fields
            .get("collaborationMode")
            .and_then(|mode| mode.pointer("/settings/model")),
    ]
    .into_iter()
    .flatten()
    .filter_map(Value::as_str)
}

fn selects_tier(fields: &Map<String, Value>) -> bool {
    ["serviceTier", "serviceTierForTurn"].iter().any(|key| {
        fields
            .get(*key)
            .is_some_and(|tier| !tier.is_null() && tier != "default")
    })
}

const SELECTION_CONFIG: [&str; 8] = [
    "model",
    "model_provider",
    "model_providers",
    "service_tier",
    "profile",
    "profiles",
    "model_catalog_json",
    "provider_model_catalog_json",
];

fn reject_config_selection(fields: &Map<String, Value>) -> std::result::Result<(), RpcError> {
    let Some(config) = fields.get("config").and_then(Value::as_object) else {
        return Ok(());
    };
    match config
        .keys()
        .find(|key| SELECTION_CONFIG.contains(&key.split('.').next().unwrap_or(key)))
    {
        Some(key) => Err(invalid(format!(
            "config.{key} cannot choose the model, its provider or service tier; use the request's own fields"
        ))),
        None => Ok(()),
    }
}

fn invalid(message: String) -> RpcError {
    RpcError::new(RpcCode::InvalidParams, message)
}

#[cfg(test)]
mod tests;
