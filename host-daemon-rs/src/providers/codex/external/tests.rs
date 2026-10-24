use super::*;

const MODEL: &str = "vendor/model-a";

fn provider() -> ExternalProvider {
    ExternalProvider {
        id: "relay".into(),
        name: "Relay".into(),
        base_url: reqwest::Url::parse("http://127.0.0.1:9/v1").unwrap(),
        key_file: PathBuf::from("/private/relay.key"),
        models: vec![MODEL.into(), "vendor/missing".into()],
    }
}

fn listing() -> Value {
    json!({"object": "list", "data": [
        {"id": MODEL, "display_name": "Model A", "capabilities": {
            "endpoints": ["/v1/chat/completions", "/v1/responses"],
            "prompt_tokens": 200000, "output_tokens": 65536, "context_tokens": 265536,
            "reasoning_efforts": ["low", "medium", "high"],
            "input_modalities": ["text", "image"],
            "streaming": true, "tool_calls": true
        }},
        {"id": "vendor/other", "capabilities": {"endpoints": ["/v1/responses"], "prompt_tokens": 1}}
    ]})
}

fn providers(state: &Path) -> Arc<ExternalProviders> {
    let directory = state.join(CATALOG_DIRECTORY);
    private_state::ensure_private_directory(&directory).unwrap();
    let models = project(&provider(), &listing()).unwrap();
    private_state::write_json(&directory.join("relay.json"), &json!({"models": models})).unwrap();
    ExternalProviders::new(vec![provider()], state)
        .unwrap()
        .unwrap()
}

#[test]
fn projection_uses_router_facts_and_generic_harness_defaults() {
    let models = project(&provider(), &listing()).unwrap();

    assert_eq!(models.len(), 1, "unlisted models are not offered");
    let model = &models[0];
    assert_eq!(model["slug"], MODEL);
    assert_eq!(model["display_name"], "Model A");
    assert_eq!(model["context_window"], 200000);
    assert_eq!(model["max_context_window"], 200000);
    assert_eq!(model["default_reasoning_level"], "medium");
    assert_eq!(
        model["supported_reasoning_levels"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
    assert_eq!(model["input_modalities"], json!(["text", "image"]));
    assert_eq!(model["shell_type"], "unified_exec");
    assert_eq!(model["apply_patch_tool_type"], "freeform");
    assert_eq!(model["use_responses_lite"], false);
    for absent in [
        "comp_hash",
        "service_tiers",
        "additional_speed_tiers",
        "base_instructions",
        "model_messages",
    ] {
        assert!(model.get(absent).is_none(), "{absent}");
    }
}

#[test]
fn a_model_without_responses_or_a_prompt_cap_is_never_projected() {
    let mut listing = listing();
    listing["data"][0]["capabilities"]["endpoints"] = json!(["/v1/chat/completions"]);
    assert!(project(&provider(), &listing).is_err());

    let mut listing = self::listing();
    listing["data"][0]["capabilities"]
        .as_object_mut()
        .unwrap()
        .remove("prompt_tokens");
    assert!(project(&provider(), &listing).is_err());

    for capability in ["streaming", "tool_calls"] {
        let mut listing = self::listing();
        listing["data"][0]["capabilities"]
            .as_object_mut()
            .unwrap()
            .remove(capability);
        assert!(project(&provider(), &listing).is_err(), "{capability}");
    }
}

#[tokio::test]
async fn nested_and_per_turn_selections_get_the_same_checks() {
    let state = tempfile::tempdir().unwrap();
    let external = providers(state.path());
    let foreign = json!({"mode": "default", "settings": {"model": "gpt-x"}});
    let ours = json!({"mode": "default", "settings": {"model": MODEL}});

    for method in ["turn/start", "thread/settings/update"] {
        let mut params = json!({"threadId": "t", "collaborationMode": foreign});
        assert!(ExternalProviders::thread_to_inspect(method, &params).is_some());
        let error = external
            .admit(method, &mut params, Some("relay"))
            .await
            .unwrap_err();
        assert!(error.message.contains("stays on Relay"), "{method}");

        let mut params = json!({"threadId": "t", "collaborationMode": ours});
        let error = external
            .admit(method, &mut params, Some("openai"))
            .await
            .unwrap_err();
        assert!(error.message.contains("runs on Relay"), "{method}");

        let mut params = json!({"threadId": "t", "model": MODEL, "collaborationMode": ours});
        assert!(
            !external
                .admit(method, &mut params, Some("relay"))
                .await
                .unwrap()
        );
    }

    let mut params = json!({"threadId": "t", "serviceTierForTurn": "priority"});
    assert!(ExternalProviders::thread_to_inspect("turn/start", &params).is_some());
    let error = external
        .admit("turn/start", &mut params, Some("relay"))
        .await
        .unwrap_err();
    assert!(error.message.contains("no service tiers"));

    for key in ["serviceTier", "serviceTierForTurn"] {
        let mut standard = json!({"threadId": "t", "model": MODEL, key: "default"});
        assert!(
            !external
                .admit("turn/start", &mut standard, Some("relay"))
                .await
                .unwrap(),
            "{key}"
        );
    }
}

#[tokio::test]
async fn a_new_conversation_on_the_provider_gets_its_definition_and_catalog() {
    let state = tempfile::tempdir().unwrap();
    let external = providers(state.path());
    let mut params = json!({"model": MODEL, "modelProvider": "relay", "config": {"model_reasoning_effort": "high"}});

    assert!(
        external
            .admit("thread/start", &mut params, None)
            .await
            .unwrap()
    );

    let config = &params["config"];
    assert_eq!(config["model_reasoning_effort"], "high");
    assert_eq!(
        config["provider_model_catalog_json"],
        json!(state.path().join("external-models/relay.json"))
    );
    let definition = &config["model_providers.relay"];
    assert_eq!(definition["base_url"], "http://127.0.0.1:9/v1");
    assert_eq!(definition["wire_api"], "responses");
    assert_eq!(
        definition["auth"],
        json!({"command": "/bin/cat", "args": ["/private/relay.key"]})
    );
    assert_eq!(definition["capabilities"], json!({"web_search": false}));

    let mut by_model = json!({"model": MODEL});
    assert!(
        external
            .admit("thread/start", &mut by_model, None)
            .await
            .unwrap()
    );
    assert_eq!(
        by_model["modelProvider"], "relay",
        "the operator config names the model's provider"
    );
    let mut native = json!({"model": "gpt-x"});
    assert!(
        !external
            .admit("thread/start", &mut native, None)
            .await
            .unwrap()
    );
    assert!(native.get("modelProvider").is_none());
}

#[tokio::test]
async fn unsupported_selections_fail_instead_of_changing_provider() {
    let state = tempfile::tempdir().unwrap();
    let external = providers(state.path());
    let admit = |method: &'static str, mut params: Value, source: Option<&'static str>| {
        let external = Arc::clone(&external);
        async move {
            external
                .admit(method, &mut params, source)
                .await
                .unwrap_err()
                .message
        }
    };

    assert!(
        admit("thread/start", json!({"modelProvider": "relay"}), None)
            .await
            .contains("Choose a Relay model")
    );
    assert!(
        admit(
            "thread/start",
            json!({"modelProvider": "relay", "model": "gpt-x"}),
            None
        )
        .await
        .contains("not available on Relay")
    );
    assert!(
        admit(
            "thread/start",
            json!({"modelProvider": "relay", "model": MODEL, "serviceTier": "priority"}),
            None
        )
        .await
        .contains("no service tiers")
    );
    assert!(
        admit(
            "thread/resume",
            json!({"threadId": "t", "modelProvider": "relay"}),
            Some("openai")
        )
        .await
        .contains("runs on ChatGPT")
    );
    assert!(
        admit(
            "thread/fork",
            json!({"threadId": "t", "modelProvider": "openai"}),
            Some("relay")
        )
        .await
        .contains("runs on Relay")
    );
    assert!(
        admit(
            "thread/fork",
            json!({"threadId": "t", "model": MODEL}),
            Some("openai")
        )
        .await
        .contains("runs on Relay")
    );
    assert!(
        admit(
            "turn/start",
            json!({"threadId": "t", "model": "gpt-x"}),
            Some("relay")
        )
        .await
        .contains("stays on Relay")
    );
    assert!(
        admit(
            "thread/settings/update",
            json!({"threadId": "t", "serviceTier": "priority"}),
            Some("relay")
        )
        .await
        .contains("no service tiers")
    );
}

#[tokio::test]
async fn config_overrides_cannot_choose_the_provider_model_or_tier() {
    let state = tempfile::tempdir().unwrap();
    let external = providers(state.path());
    for (method, source) in [
        ("thread/fork", Some("relay")),
        ("thread/resume", Some("relay")),
        ("thread/fork", Some("openai")),
        ("thread/start", None),
        ("turn/start", Some("relay")),
    ] {
        for config in [
            json!({"model_provider": "openai"}),
            json!({"model": "gpt-x"}),
            json!({"service_tier": "priority"}),
            json!({"profile": "other"}),
            json!({"model_providers.relay.base_url": "http://127.0.0.1:1/v1"}),
            json!({"model_providers": {"relay": {}}}),
            json!({"provider_model_catalog_json": "/tmp/catalog.json"}),
        ] {
            let mut params = json!({"threadId": "t", "model": MODEL, "config": config});
            let error = external
                .admit(method, &mut params, source)
                .await
                .unwrap_err();
            assert!(
                error.message.contains("use the request's own fields"),
                "{method} {config}"
            );
        }
    }

    let mut effort = json!({"threadId": "t", "config": {"model_reasoning_effort": "low"}});
    assert!(
        external
            .admit("thread/fork", &mut effort, Some("relay"))
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn resumes_and_forks_keep_the_source_provider() {
    let state = tempfile::tempdir().unwrap();
    let external = providers(state.path());

    let mut resume = json!({"threadId": "t", "model": MODEL});
    assert!(
        external
            .admit("thread/resume", &mut resume, Some("relay"))
            .await
            .unwrap()
    );
    assert!(resume["config"]["model_providers.relay"].is_object());

    let mut recover = json!({"threadId": "t", "turnId": "u", "capability": "c"});
    assert!(
        external
            .admit("thread/restart/recover", &mut recover, Some("relay"))
            .await
            .unwrap()
    );
    assert!(recover["config"]["model_providers.relay"].is_object());
    assert!(recover["config"]["provider_model_catalog_json"].is_string());

    let mut inheriting =
        json!({"threadId": "t", "ephemeral": true, "experimentalPredictionMode": true});
    assert!(
        !external
            .admit("thread/fork", &mut inheriting, Some("relay"))
            .await
            .unwrap()
    );
    assert!(inheriting.get("config").is_none());

    let mut native = json!({"threadId": "t", "model": "gpt-x"});
    assert!(
        !external
            .admit("thread/fork", &mut native, Some("openai"))
            .await
            .unwrap()
    );
    assert!(native.get("config").is_none());

    let mut native_recover = json!({"threadId": "t", "turnId": "u", "capability": "c"});
    assert!(
        !external
            .admit(
                "thread/restart/recover",
                &mut native_recover,
                Some("openai")
            )
            .await
            .unwrap()
    );
    assert!(native_recover.get("config").is_none());
}

#[test]
fn only_selection_changes_need_the_threads_provider() {
    let inspect = |method, params: Value| ExternalProviders::thread_to_inspect(method, &params);

    assert_eq!(
        inspect("thread/resume", json!({"threadId": "t"})).as_deref(),
        Some("t")
    );
    assert_eq!(
        inspect("turn/start", json!({"threadId": "t", "input": []})),
        None
    );
    assert_eq!(
        inspect("turn/start", json!({"threadId": "t", "model": "m"})).as_deref(),
        Some("t")
    );
    assert_eq!(
        inspect(
            "thread/fork",
            json!({"threadId": "claude_aaaaaaaa-1111-4222-8333-444444444444"})
        ),
        None
    );
}

#[tokio::test]
async fn history_lists_include_the_configured_providers_unless_a_filter_is_given() {
    let state = tempfile::tempdir().unwrap();
    let external = providers(state.path());

    let mut list = json!({"limit": 5});
    assert!(
        external
            .admit("thread/list", &mut list, None)
            .await
            .unwrap()
    );
    assert_eq!(list["modelProviders"], json!(["openai", "relay"]));

    let mut filtered = json!({"modelProviders": ["openai"]});
    assert!(
        !external
            .admit("thread/list", &mut filtered, None)
            .await
            .unwrap()
    );
    assert_eq!(filtered["modelProviders"], json!(["openai"]));
}

#[test]
fn picker_rows_carry_the_provider_and_obsolete_catalogs_are_removed() {
    let state = tempfile::tempdir().unwrap();
    let directory = state.path().join(CATALOG_DIRECTORY);
    private_state::ensure_private_directory(&directory).unwrap();
    std::fs::write(directory.join("retired.json"), "{}").unwrap();
    let external = providers(state.path());

    assert!(!directory.join("retired.json").exists());
    let rows = external.model_rows();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["model"], MODEL);
    assert_eq!(rows[0]["modelProvider"], "relay");
    assert_eq!(rows[0]["modelProviderName"], "Relay");
    assert_eq!(rows[0]["defaultReasoningEffort"], "medium");
    assert_eq!(rows[0]["serviceTiers"], json!([]));

    drop(external);
    assert!(
        ExternalProviders::new(Vec::new(), state.path())
            .unwrap()
            .is_none()
    );
    assert!(
        !directory.exists(),
        "the catalog directory leaves with its configuration"
    );
}

#[test]
fn configuration_rejects_ambiguous_providers() {
    let mut duplicate = provider();
    duplicate.id = "other".into();
    assert!(
        validate(&[provider(), duplicate])
            .unwrap_err()
            .to_string()
            .contains("more than one")
    );

    let mut native = provider();
    native.id = "openai".into();
    assert!(validate(&[native]).is_err());
}
