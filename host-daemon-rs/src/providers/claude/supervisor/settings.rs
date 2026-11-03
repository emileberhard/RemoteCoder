use super::{
    ClaudeRuntimeSettings, ClaudeSupervisor, SessionRename, TurnStartError, append_custom_title,
    claude_model_matches,
};
use crate::ids::is_session_uuid;
use crate::providers::claude::ClaudeSelection;
use serde_json::{Value, json};

impl ClaudeSupervisor {
    pub(crate) async fn update_settings(
        &self,
        thread_id: &str,
        selection: &ClaudeSelection,
    ) -> Result<Value, TurnStartError> {
        let _guard = self.lifecycles.lock(thread_id).await;
        self.validate_route(thread_id, selection, false).await?;
        let result = if self.runtimes.lock().await.contains_key(thread_id) {
            self.apply_runtime_settings(thread_id, selection).await?
        } else {
            json!({ "status": "nextTurn" })
        };
        self.remember_parent_settings(thread_id, selection).await;
        Ok(result)
    }

    pub(crate) async fn validate_route(
        &self,
        thread_id: &str,
        selection: &ClaudeSelection,
        first_turn: bool,
    ) -> Result<crate::providers::claude::exec::Route, TurnStartError> {
        let parent = self
            .conversation_index
            .parent(thread_id)
            .await
            .map_err(|error| TurnStartError {
                data: None,
                code: crate::rpc::error::RpcCode::Unavailable,
                message: format!("Claude selection could not be read: {error:#}"),
            })?;
        let previous = parent.selection.map(|selection| selection.selection());
        let current = self
            .runtimes
            .lock()
            .await
            .get(thread_id)
            .and_then(|runtime| {
                runtime
                    .settings
                    .as_ref()
                    .map(|settings| settings.effective().clone())
            });
        let route = self
            .resolve_selection(selection, first_turn && previous.is_none())
            .await?;
        for old in previous.iter().chain(current.iter()) {
            let old_provider = self
                .settings
                .external_providers
                .as_ref()
                .and_then(|providers| providers.owner(&old.model))
                .map(|provider| provider.id())
                .or_else(|| {
                    crate::providers::claude::exec::is_native_model(&old.model).then_some("claude")
                })
                .ok_or_else(|| TurnStartError {
                    data: Some(super::TurnErrorData::ProviderUnavailable),
                    code: crate::rpc::error::RpcCode::Unavailable,
                    message: format!("Claude provider is unavailable for {}", old.model),
                })?;
            if old_provider != route.provider_id()
                || (route.provider_id() != "claude" && old.model != selection.model)
            {
                return Err(TurnStartError { data: None, code: crate::rpc::error::RpcCode::InvalidParams,
                    message: "This Claude conversation uses another provider; start a new conversation to change provider".into() });
            }
        }
        if !first_turn && previous.is_none() && current.is_none() && route.provider_id() != "claude"
        {
            return Err(TurnStartError { data: None, code: crate::rpc::error::RpcCode::InvalidParams,
                message: "This imported Claude conversation has no recorded provider; start a new conversation to use an external provider".into() });
        }
        Ok(route)
    }

    async fn resolve_selection(
        &self,
        selection: &ClaudeSelection,
        new: bool,
    ) -> Result<crate::providers::claude::exec::Route, TurnStartError> {
        crate::providers::claude::exec::resolve(&self.settings, selection, new)
            .await
            .map_err(|error| TurnStartError {
                data: Some(super::TurnErrorData::ProviderUnavailable),
                code: crate::rpc::error::RpcCode::Unavailable,
                message: format!("Claude provider is unavailable: {error:#}"),
            })
    }

    pub(crate) async fn record_initial_selection(
        &self,
        thread_id: &str,
        cwd: &str,
        selection: &ClaudeSelection,
    ) -> anyhow::Result<()> {
        let selection = crate::providers::claude::conversation_index::ParentSelection {
            cwd: cwd.to_owned(),
            model: selection.model.clone(),
            effort: selection.effort.clone(),
            fast: selection.fast,
        };
        self.conversation_index
            .update_parent(thread_id, move |parent| parent.selection = Some(selection))
            .await
    }

    pub(crate) async fn copy_parent_selection(
        &self,
        source: &str,
        target: &str,
    ) -> anyhow::Result<()> {
        let selection = self.conversation_index.parent(source).await?.selection;
        if let Some(selection) = selection {
            self.conversation_index
                .update_parent(target, move |parent| parent.selection = Some(selection))
                .await?;
        }
        Ok(())
    }

    pub(super) async fn apply_runtime_settings(
        &self,
        thread_id: &str,
        selection: &ClaudeSelection,
    ) -> Result<Value, TurnStartError> {
        let pid = self
            .runtimes
            .lock()
            .await
            .get(thread_id)
            .ok_or("Claude runtime ended before settings could be updated")?
            .process_group_id;
        let prepared = Self::prepare_runtime_control(&json!({
            "subtype":"apply_flag_settings",
            "settings":{
                "model":selection.model,
                "effortLevel":selection.effort,
                "fastMode":selection.fast,
            }
        }))?;
        // Mutating controls may apply only part of a request. Until readback
        // succeeds, no previously cached tuple is safe to reuse.
        if let Some(runtime) = self.runtimes.lock().await.get_mut(thread_id) {
            runtime.settings = None;
        }
        let apply_result = self
            .runtime_control_prepared(thread_id, pid, prepared)
            .await;
        let response = self
            .runtime_control(thread_id, pid, json!({ "subtype": "get_settings" }))
            .await?;
        let actual = ClaudeRuntimeSettings::read_back(&response)?;
        let matches = claude_model_matches(&selection.model, &actual.model)
            && selection
                .effort
                .as_ref()
                .is_none_or(|effort| actual.effort.as_ref() == Some(effort))
            && actual.fast == selection.fast;
        let observed = ClaudeRuntimeSettings {
            observed: actual.clone(),
            selection: (apply_result.is_ok() && matches).then(|| selection.clone()),
        };
        let mut runtimes = self.runtimes.lock().await;
        let runtime = runtimes
            .get_mut(thread_id)
            .filter(|runtime| {
                runtime.process_group_id == pid
                    && !runtime
                        .active_turn
                        .as_ref()
                        .is_some_and(super::RuntimeTurn::is_stopping)
            })
            .ok_or("Claude runtime ended while settings were being updated")?;
        self.journal.runtime(
            "settings_observed",
            json!({ "threadId": thread_id, "pid": pid, "settings": observed }),
        );
        runtime.settings = Some(observed);
        apply_result?;
        if !matches {
            return Err(format!("Claude reported {actual} after requesting {selection}").into());
        }
        let current_turn = runtime
            .running_turn()
            .map(|turn| turn.translator.turn_id().to_owned());
        Ok(json!({
            "status": if current_turn.is_some() { "nextTurn" } else { "applied" },
            "currentTurnId": current_turn,
            "applied": { "model": actual.model, "effort": actual.effort },
        }))
    }

    pub(crate) async fn rename_session(
        &self,
        thread_id: &str,
        session_uuid: &str,
        name: &str,
    ) -> Result<SessionRename, String> {
        if !is_session_uuid(session_uuid) {
            return Err(format!("Claude session id {session_uuid} is not a UUID"));
        }
        let lifecycle = self.lifecycles.lock(thread_id).await;
        let pid = self
            .runtimes
            .lock()
            .await
            .get(thread_id)
            .map(|runtime| runtime.process_group_id);
        if let Some(pid) = pid {
            self.runtime_rename_control(
                thread_id,
                pid,
                json!({
                    "subtype": "rename_session",
                    "title": name,
                    "source": "host",
                    "session_id": session_uuid,
                }),
                lifecycle,
            )
            .await?;
        } else {
            let home = self.settings.claude_home.clone();
            let session = session_uuid.to_owned();
            let title = name.to_owned();
            let recorded = tokio::task::spawn_blocking(move || {
                let path = crate::providers::claude::timeline::find_session_path(&session, &home)
                    .map_err(|error| {
                    format!("Could not find the Claude session file: {error:#}")
                })?;
                match path {
                    Some(path) => append_custom_title(&path, &session, &title),
                    None => Ok(false),
                }
            })
            .await
            .map_err(|error| format!("Claude session rename worker failed: {error}"))??;
            if !recorded {
                return Ok(SessionRename::NoConversation);
            }
        }
        self.journal.runtime(
            "session_renamed",
            json!({ "threadId": thread_id, "liveRuntime": pid.is_some() }),
        );
        self.emit(json!({
            "method": "thread/name/updated",
            "params": { "threadId": thread_id, "threadName": name },
        }))
        .await;
        Ok(SessionRename::Renamed)
    }
}
