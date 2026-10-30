use super::{ClaudeSupervisor, TurnOrigin, TurnStartError};
use crate::agents::jobs::routes::{NativeDeliveryState, NativeMessage, NativeRoutes};
use crate::providers::claude::conversation_index::{
    Delivery, DeliveryState, ParentDeliveryRoute, ParentSelection, delivery_uuid,
};
use crate::providers::claude::{
    ClaudeSelection, ClaudeTurnRequest, ClaudeUserInput, session_uuid_from_thread_id,
};
use crate::rpc::error::RpcCode;
use serde_json::{Value, json};
use std::sync::Arc;
use tracing::error;

enum ParentTransport<'a> {
    Gateway,
    Native(&'a NativeRoutes),
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ParentMessage {
    pub thread_id: String,
    pub delivery_id: String,
    pub text: String,
}

enum DispatchFailure {
    Rejected(TurnStartError),
    Uncertain(TurnStartError),
}

impl ClaudeSupervisor {
    pub(crate) async fn job_parent_gateway_owned(&self, thread: &str) -> anyhow::Result<bool> {
        Ok(self.has_runtime(thread).await
            || self.conversation_index.parent(thread).await?.delivery_route
                == ParentDeliveryRoute::Gateway)
    }

    pub(crate) async fn has_legacy_gateway_parent(&self, thread: &str) -> anyhow::Result<bool> {
        let parent = self.conversation_index.parent(thread).await?;
        Ok(parent.delivery_route == ParentDeliveryRoute::Unknown && parent.selection.is_some())
    }

    pub(crate) async fn restore_gateway_parent_route(&self, thread: &str) -> anyhow::Result<bool> {
        let _lifecycle = self.lifecycles.lock(thread).await;
        self.conversation_index
            .transact_parent(thread, |parent| {
                if parent.delivery_route == ParentDeliveryRoute::Unknown
                    && parent.selection.is_some()
                {
                    parent.delivery_route = ParentDeliveryRoute::Gateway;
                }
                Ok(parent.delivery_route == ParentDeliveryRoute::Gateway)
            })
            .await
    }

    pub(crate) async fn record_native_parent(&self, thread: &str) -> anyhow::Result<()> {
        let _lifecycle = self.lifecycles.lock(thread).await;
        anyhow::ensure!(
            !self.has_runtime(thread).await,
            "Claude parent has a live gateway execution owner"
        );
        anyhow::ensure!(
            !self
                .starting
                .lock()
                .expect("Claude start reservations poisoned")
                .contains(thread),
            "Claude parent is starting a gateway execution"
        );
        self.conversation_index
            .transact_parent(thread, |parent| {
                if parent.delivery_route != ParentDeliveryRoute::Native {
                    parent.stop_generation =
                        parent.stop_generation.checked_add(1).ok_or_else(|| {
                            anyhow::anyhow!("Claude parent Stop generation exhausted")
                        })?;
                    parent.stopped = false;
                    parent.delivery_route = ParentDeliveryRoute::Native;
                }
                Ok(())
            })
            .await
    }

    pub(super) async fn remember_parent(
        &self,
        request: &ClaudeTurnRequest,
        origin: TurnOrigin,
        stop_generation: u64,
    ) {
        let selection = ParentSelection {
            cwd: request.cwd.clone(),
            model: request.selection.model.clone(),
            effort: request.selection.effort.clone(),
            fast: request.selection.fast,
        };
        let user_turn = matches!(origin, TurnOrigin::Dispatched);
        self.update_parent(&request.thread_id, move |parent| {
            if parent.stop_generation != stop_generation {
                return;
            }
            parent.selection = Some(selection);
            parent.delivery_route = ParentDeliveryRoute::Gateway;
            if user_turn {
                parent.stopped = false;
            }
        })
        .await;
    }

    pub(super) async fn remember_parent_settings(
        &self,
        thread_id: &str,
        selection: &ClaudeSelection,
    ) {
        let ClaudeSelection {
            model,
            effort,
            fast,
        } = selection.clone();
        self.update_parent(thread_id, move |parent| {
            if let Some(selection) = parent.selection.as_mut() {
                selection.model = model;
                selection.effort = effort;
                selection.fast = fast;
            }
        })
        .await;
    }

    pub(crate) async fn stop_parent(&self, thread_id: &str) -> anyhow::Result<()> {
        let job = self
            .runtimes
            .lock()
            .await
            .get(thread_id)
            .and_then(|runtime| {
                runtime.input.stop_inputs();
                runtime.launch.job().cloned()
            });
        if let Some(handle) = job {
            self.conversation_index
                .update_job(thread_id, &handle, |saved| {
                    if !matches!(
                        saved.phase,
                        crate::providers::claude::conversation_index::job::JobPhase::Finished { .. }
                    ) {
                        saved.phase =
                            crate::providers::claude::conversation_index::job::JobPhase::Stopping;
                    }
                    Ok(())
                })
                .await?;
        }
        self.conversation_index
            .update_parent(thread_id, |parent| {
                parent.stopped = true;
                parent.stop_generation += 1;
            })
            .await
    }

    pub(crate) async fn stop_generation(&self, thread_id: &str) -> anyhow::Result<u64> {
        Ok(self
            .conversation_index
            .parent(thread_id)
            .await?
            .stop_generation)
    }

    pub(super) async fn parent_selection(&self, thread_id: &str) -> Option<ClaudeSelection> {
        self.conversation_index
            .parent(thread_id)
            .await
            .ok()?
            .selection
            .map(ParentSelection::selection)
    }

    pub(crate) async fn fast_mode(&self, thread_id: &str, model: &str) -> bool {
        self.parent_selection(thread_id)
            .await
            .is_some_and(|selection| {
                selection.fast && super::claude_model_matches(&selection.model, model)
            })
    }

    async fn update_parent(
        &self,
        thread_id: &str,
        update: impl FnOnce(&mut crate::providers::claude::conversation_index::Parent) + Send + 'static,
    ) {
        if let Err(error) = self
            .conversation_index
            .update_parent(thread_id, update)
            .await
        {
            error!(%thread_id, error = %format!("{error:#}"), "Claude parent record was not saved");
        }
    }

    pub(crate) async fn deliver_parent_message(
        self: &Arc<Self>,
        message: ParentMessage,
    ) -> Result<Value, TurnStartError> {
        self.deliver_message(message, ParentTransport::Gateway)
            .await
    }

    pub(crate) async fn deliver_native_parent_message(
        self: &Arc<Self>,
        message: ParentMessage,
        routes: &NativeRoutes,
    ) -> Result<Value, TurnStartError> {
        self.deliver_message(message, ParentTransport::Native(routes))
            .await
    }

    async fn deliver_message(
        self: &Arc<Self>,
        message: ParentMessage,
        transport: ParentTransport<'_>,
    ) -> Result<Value, TurnStartError> {
        if message.delivery_id.is_empty()
            || message.delivery_id.len() > 256
            || message.text.trim().is_empty()
            || message.text.len() > 1_048_576
        {
            return Err(rejected(
                "A delivery id (1–256 bytes) and nonempty message (at most 1 MiB) are required",
            ));
        }
        let session_uuid = session_uuid_from_thread_id(&message.thread_id)
            .ok_or_else(|| rejected("Claude parent thread id is invalid"))?
            .to_owned();
        let fingerprint = crate::ids::sha256_hex(message.text.as_bytes());
        let _lifecycle = self.lifecycles.lock(&message.thread_id).await;
        let parent = self
            .conversation_index
            .parent(&message.thread_id)
            .await
            .map_err(|error| {
                rejected(&format!(
                    "Claude parent record could not be read: {error:#}"
                ))
            })?;
        let input_id = delivery_uuid(&message.thread_id, &message.delivery_id);
        let known = parent.delivery_fingerprint(&message.delivery_id);
        if known.is_some_and(|known| known != fingerprint) {
            return Err(rejected(
                "Delivery id was already used for a different message or sender",
            ));
        }
        let prior = parent.delivery(&message.delivery_id);
        let home = self.settings.claude_home.clone();
        let session = session_uuid.clone();
        let id = input_id.clone();
        let recorded = tokio::task::spawn_blocking(move || {
            let Some(path) =
                crate::providers::claude::timeline::find_session_path(&session, &home)?
            else {
                return Ok(None);
            };
            crate::providers::claude::delivery_evidence::recorded_fingerprint(&path, &id)
        })
        .await
        .map_err(|error| uncertain(format!("Claude input evidence could not be read: {error}")))?
        .map_err(|error| {
            uncertain(format!(
                "Claude input evidence could not be read: {error:#}"
            ))
        })?;
        if let Some(recorded_fingerprint) = recorded {
            if recorded_fingerprint
                .as_deref()
                .is_some_and(|saved| saved != fingerprint)
            {
                return Err(rejected(
                    "Delivery id is recorded in Claude history with different message content",
                ));
            }
            if recorded_fingerprint.is_none() {
                return Err(uncertain(
                    "Claude history records this input UUID, but its original payload cannot be verified".to_owned(),
                ));
            }
            let mut receipt = receipt(
                &message,
                DeliveryState::Recorded,
                "gateway-recorded",
                prior.and_then(|delivery| delivery.receipt["turn_id"].as_str()),
            );
            receipt["duplicate"] = json!(true);
            self.save_delivery(
                &message.thread_id,
                Delivery {
                    id: message.delivery_id,
                    fingerprint,
                    state: DeliveryState::Recorded,
                    receipt: receipt.clone(),
                },
            )
            .await?;
            return Ok(receipt);
        }
        if known.is_some()
            && prior.is_none_or(|delivery| {
                matches!(
                    delivery.state,
                    DeliveryState::Submitted | DeliveryState::Recorded
                )
            })
        {
            let mut receipt = prior.map_or_else(
                || {
                    receipt(
                        &message,
                        DeliveryState::Submitted,
                        "gateway-submitted",
                        None,
                    )
                },
                |delivery| delivery.receipt.clone(),
            );
            receipt["duplicate"] = json!(true);
            return Ok(receipt);
        }
        if prior.is_some_and(|delivery| {
            matches!(
                delivery.state,
                DeliveryState::Sending | DeliveryState::Uncertain
            )
        }) {
            return Err(uncertain(
                "Claude parent message delivery is unresolved; canonical input evidence does not yet confirm it, so it will not be resent".to_owned(),
            ));
        }
        if parent.stopped {
            return Err(rejected(
                "Claude parent was interrupted by the user, so this message will not wake it",
            ));
        }
        let expected_route = match transport {
            ParentTransport::Gateway => ParentDeliveryRoute::Gateway,
            ParentTransport::Native(_) => ParentDeliveryRoute::Native,
        };
        if parent.delivery_route != expected_route {
            return Err(TurnStartError::parent_unreachable(
                "Claude parent has no proven owner for this delivery transport; history and prior selection do not authorize taking over a terminal session",
            ));
        }
        let stop_generation = parent.stop_generation;
        if let ParentTransport::Native(routes) = transport {
            return self
                .submit_native_message(message, fingerprint, stop_generation, routes)
                .await;
        }
        let selection = parent.selection.ok_or_else(|| {
            rejected("Claude parent has not run a turn through this gateway, so this message cannot wake it")
        })?;
        let request = ClaudeTurnRequest {
            thread_id: message.thread_id.clone(),
            session_uuid,
            first_turn: false,
            input: ClaudeUserInput {
                client_id: Some(input_id),
                is_synthetic: true,
                ..ClaudeUserInput::text(message.text.clone())
            },
            cwd: selection.cwd.clone(),
            selection: selection.selection(),
        };
        let prepared = Delivery {
            id: message.delivery_id.clone(),
            fingerprint: fingerprint.clone(),
            state: DeliveryState::Prepared,
            receipt: Value::Null,
        };
        self.prepare_delivery(&message.thread_id, prepared.clone(), stop_generation)
            .await?;
        let active = {
            let runtimes = self.runtimes.lock().await;
            runtimes.get(&message.thread_id).and_then(|runtime| {
                runtime.running_turn().map(|turn| {
                    (
                        turn.translator.turn_id().to_owned(),
                        runtime.input.clone(),
                        runtime.process_group_id,
                    )
                })
            })
        };
        let dispatched = if let Some((turn_id, input, group)) = active {
            let prepared = super::input_writer::InputWriter::prepare_input(&request.input)
                .map_err(TurnStartError::from)?;
            self.write_parent_message(&request.thread_id, group, input, prepared, stop_generation)
                .await
                .map(|()| (turn_id, "gateway-steered"))
        } else {
            self.start_turn_locked(request, TurnOrigin::Callback { stop_generation })
                .await
                .map(|turn_id| (turn_id, "gateway-started"))
                .map_err(DispatchFailure::Uncertain)
        };
        let (turn_id, delivery) = match dispatched {
            Ok(delivery) => delivery,
            Err(failure) => {
                let (mut state, error) = match failure {
                    DispatchFailure::Rejected(error) => (DeliveryState::Rejected, error),
                    DispatchFailure::Uncertain(error) => (DeliveryState::Uncertain, error),
                };
                if let Ok(current) = self.conversation_index.parent(&message.thread_id).await
                    && current
                        .delivery(&message.delivery_id)
                        .is_some_and(|delivery| {
                            matches!(
                                delivery.state,
                                DeliveryState::Prepared | DeliveryState::Rejected
                            )
                        })
                {
                    state = DeliveryState::Rejected;
                }
                self.save_delivery(
                    &message.thread_id,
                    Delivery {
                        id: message.delivery_id,
                        fingerprint,
                        state,
                        receipt: Value::Null,
                    },
                )
                .await?;
                return Err(if state == DeliveryState::Rejected {
                    error
                } else {
                    uncertain(format!(
                        "Claude parent message delivery is unconfirmed; do not resend it: {}",
                        error.message
                    ))
                });
            }
        };
        let receipt = receipt(&message, DeliveryState::Submitted, delivery, Some(&turn_id));
        self.save_delivery(
            &message.thread_id,
            Delivery {
                id: message.delivery_id,
                fingerprint,
                state: DeliveryState::Submitted,
                receipt: receipt.clone(),
            },
        )
        .await?;
        Ok(receipt)
    }

    async fn submit_native_message(
        &self,
        message: ParentMessage,
        fingerprint: String,
        stop_generation: u64,
        routes: &NativeRoutes,
    ) -> Result<Value, TurnStartError> {
        let conversation = crate::agents::jobs::model::ConversationIdentity {
            provider: crate::agents::jobs::model::Provider::Claude,
            provider_home: crate::agents::jobs::model::ProviderHome::Known {
                path: self.settings.claude_home.clone(),
            },
            thread_id: message.thread_id.clone(),
        };
        let native = NativeMessage::new(
            conversation.clone(),
            message.delivery_id.clone(),
            message.text.clone(),
        )
        .map_err(|error| {
            rejected(&format!(
                "Claude native input could not be prepared: {error:#}"
            ))
        })?;
        self.prepare_delivery(
            &message.thread_id,
            Delivery {
                id: message.delivery_id.clone(),
                fingerprint: fingerprint.clone(),
                state: DeliveryState::Prepared,
                receipt: Value::Null,
            },
            stop_generation,
        )
        .await?;
        let thread = message.thread_id.clone();
        let input = native.input_id().to_owned();
        self.conversation_index
            .transact_parent(&message.thread_id, move |parent| {
                anyhow::ensure!(
                    !parent.stopped && parent.stop_generation == stop_generation,
                    "Claude parent was interrupted before native submission"
                );
                parent.mark_delivery_sending(&thread, &input)
            })
            .await
            .map_err(|error| {
                rejected(&format!(
                    "Claude native input could not enter submission: {error:#}"
                ))
            })?;
        let result = routes.deliver(&conversation, native).await;
        let (state, reason) = match result {
            NativeDeliveryState::Submitted => (DeliveryState::Submitted, None),
            NativeDeliveryState::Uncertain { reason } => (DeliveryState::Uncertain, Some(reason)),
            NativeDeliveryState::Unreachable { reason } => (DeliveryState::Rejected, Some(reason)),
        };
        let receipt = receipt(&message, state, "native-submitted", None);
        self.save_delivery(
            &message.thread_id,
            Delivery {
                id: message.delivery_id,
                fingerprint,
                state,
                receipt: receipt.clone(),
            },
        )
        .await?;
        match state {
            DeliveryState::Submitted => Ok(receipt),
            DeliveryState::Rejected => Err(TurnStartError::parent_unreachable(
                reason
                    .as_deref()
                    .unwrap_or("Claude native parent is unreachable before input submission"),
            )),
            _ => Err(uncertain(reason.unwrap_or_else(|| {
                "Claude native delivery remains uncertain; do not resend it".into()
            }))),
        }
    }

    async fn prepare_delivery(
        &self,
        thread: &str,
        delivery: Delivery,
        generation: u64,
    ) -> Result<(), TurnStartError> {
        self.conversation_index
            .transact_parent(thread, move |parent| {
                anyhow::ensure!(
                    !parent.stopped && parent.stop_generation == generation,
                    "Claude parent was interrupted by the user, so this message will not wake it"
                );
                anyhow::ensure!(
                    parent
                        .delivery_fingerprint(&delivery.id)
                        .is_none_or(|known| known == delivery.fingerprint),
                    "Delivery id was already used for a different message or sender"
                );
                anyhow::ensure!(
                    parent.delivery(&delivery.id).is_none_or(|saved| matches!(
                        saved.state,
                        DeliveryState::Prepared | DeliveryState::Rejected
                    )),
                    "Claude parent message already has an unresolved or submitted delivery"
                );
                parent.record_delivery(delivery);
                Ok(())
            })
            .await
            .map_err(|error| {
                TurnStartError::internal(format!(
                    "Claude parent message intent could not be saved: {error:#}"
                ))
            })
    }

    async fn save_delivery(&self, thread: &str, delivery: Delivery) -> Result<(), TurnStartError> {
        self.conversation_index
            .update_parent(thread, move |parent| parent.record_delivery(delivery))
            .await
            .map_err(|error| {
                uncertain(format!(
                    "Claude parent message outcome could not be saved; do not resend it: {error:#}"
                ))
            })
    }

    async fn write_parent_message(
        &self,
        thread: &str,
        group: i32,
        input: super::InputWriter,
        prepared: Arc<super::input_writer::PreparedInput>,
        generation: u64,
    ) -> Result<(), DispatchFailure> {
        let slot = input
            .reserve()
            .await
            .map_err(|error| DispatchFailure::Rejected(error.into()))?;
        let parent = self
            .conversation_index
            .parent(thread)
            .await
            .map_err(|error| {
                DispatchFailure::Rejected(TurnStartError::internal(format!(
                    "Claude Stop state could not be checked: {error:#}"
                )))
            })?;
        if parent.stopped || parent.stop_generation != generation {
            return Err(DispatchFailure::Rejected(rejected(
                "Claude parent was interrupted by the user, so this message will not wake it",
            )));
        }
        let (admitted, policy) = {
            let runtimes = self.runtimes.lock().await;
            let admitted = self
                .admit_input(&runtimes)
                .map_err(DispatchFailure::Rejected)?;
            let Some(runtime) = runtimes.get(thread).filter(|runtime| {
                runtime.process_group_id == group && runtime.running_turn().is_some()
            }) else {
                return Err(DispatchFailure::Rejected(rejected(
                    "Claude parent execution changed before this message was submitted",
                )));
            };
            (admitted, runtime.launch.clone())
        };
        let pending = self
            .submit_callback_input(
                thread,
                &policy,
                TurnOrigin::Callback {
                    stop_generation: generation,
                },
                slot,
                prepared,
            )
            .await
            .map_err(DispatchFailure::Rejected)?;
        drop(admitted);
        if let Err(error) = pending.written().await {
            if super::InputWriter::is_stalled(&error) {
                return Err(DispatchFailure::Uncertain(self.input_stalled(
                    thread,
                    group,
                    "claude/message",
                    error,
                )));
            }
            let failure = format!("Failed writing Claude parent message: {error}");
            self.retire_after_write_failure(thread, group, &failure)
                .await;
            return Err(DispatchFailure::Uncertain(TurnStartError::internal(
                failure,
            )));
        }
        self.ensure_runtime_current(thread, group)
            .await
            .map_err(DispatchFailure::Uncertain)
    }

    pub(super) async fn submit_callback_input(
        &self,
        thread: &str,
        policy: &super::jobs::LaunchPolicy,
        origin: TurnOrigin,
        slot: super::input_writer::InputSlot,
        prepared: Arc<super::input_writer::PreparedInput>,
    ) -> Result<super::input_writer::PendingWrite, TurnStartError> {
        let TurnOrigin::Callback { stop_generation } = origin else {
            return self.submit_job_input(thread, policy, slot, prepared).await;
        };
        let input = prepared
            .input_id()
            .ok_or_else(|| rejected("Claude callback has no exact input identity"))?
            .to_owned();
        let saved_input = input.clone();
        let saved_thread = thread.to_owned();
        self.conversation_index
            .transact_parent(thread, move |parent| {
                anyhow::ensure!(
                    !parent.stopped && parent.stop_generation == stop_generation,
                    "Claude parent was interrupted before submission"
                );
                parent.mark_delivery_sending(&saved_thread, &saved_input)
            })
            .await
            .map_err(|error| {
                rejected(&format!(
                    "Claude callback could not enter submission: {error:#}"
                ))
            })?;
        match self.submit_job_input(thread, policy, slot, prepared).await {
            Ok(pending) => Ok(pending),
            Err(error) => {
                let saved_thread = thread.to_owned();
                self.conversation_index.transact_parent(thread, move |parent| {
                    if let Some(mut delivery) = parent.delivery_for_input(&saved_thread, &input).cloned() {
                        delivery.state = DeliveryState::Rejected;
                        parent.record_delivery(delivery);
                    }
                    Ok(())
                }).await.map_err(|saved| uncertain(format!("Claude input was not queued, but that outcome could not be saved: {saved:#}")))?;
                Err(error)
            }
        }
    }

    pub(super) async fn check_callback_generation(
        &self,
        thread: &str,
        origin: TurnOrigin,
    ) -> Result<(), TurnStartError> {
        let TurnOrigin::Callback { stop_generation } = origin else {
            return Ok(());
        };
        let parent = self
            .conversation_index
            .parent(thread)
            .await
            .map_err(|error| {
                TurnStartError::internal(format!(
                    "Claude Stop state could not be checked: {error:#}"
                ))
            })?;
        if parent.stopped || parent.stop_generation != stop_generation {
            return Err(rejected(
                "Claude parent was interrupted by the user, so this message will not wake it",
            ));
        }
        Ok(())
    }
}

fn receipt(
    message: &ParentMessage,
    state: DeliveryState,
    delivery: &str,
    turn_id: Option<&str>,
) -> Value {
    json!({
        "delivery": delivery,
        "delivery_state": state,
        "delivery_id": message.delivery_id,
        "delivery_confirmed": false,
        "parent": "claude",
        "thread_id": message.thread_id,
        "turn_id": turn_id,
    })
}

fn uncertain(message: String) -> TurnStartError {
    TurnStartError::delivery_uncertain(message)
}

fn rejected(message: &str) -> TurnStartError {
    TurnStartError {
        data: None,
        code: RpcCode::InvalidParams,
        message: message.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::super::suspend::suspend_test_support::nothing_suspended;
    use super::*;
    use crate::agents::mcp::McpTokens;
    use crate::ids::is_session_uuid;
    use crate::observability::journal::Journal;
    use crate::providers::claude::settings::ClaudeSettings;
    use crate::providers::claude::supervisor::{
        RUNTIME_IDLE_TIMEOUT, TurnControlError, signal_group,
    };
    use nix::sys::signal::Signal;
    use nix::unistd::Pid;
    use std::fs;
    use std::path::PathBuf;
    use std::time::Duration;
    use tokio::sync::mpsc;

    const SESSION: &str = "11111111-2222-4333-8444-555555555555";
    const THREAD: &str = "claude_11111111-2222-4333-8444-555555555555";

    struct Fixture {
        root: crate::providers::claude::settings::ClaudeTestSettings,
        agent: Arc<ClaudeSupervisor>,
        events: mpsc::Receiver<crate::providers::claude::ClaudeNotification>,
        history: PathBuf,
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            for group in &self.agent.process_registry.lock().unwrap().groups {
                signal_group(Pid::from_raw(*group), Signal::SIGKILL);
            }
        }
    }

    impl Fixture {
        fn new() -> Self {
            let root = ClaudeSettings::isolated_for_test();
            let executable = root.root_path().join("claude-stub");
            let history = crate::providers::claude::timeline::session_path_for_cwd(
                root.root_path(),
                &root.root_path().to_string_lossy(),
                SESSION,
            );
            crate::test_support::write_claude_cli_stub(
                &executable,
                crate::test_support::ClaudeCliMode::MessagesAcknowledgeInterrupt(history.clone()),
            );
            fs::create_dir_all(history.parent().unwrap()).unwrap();
            fs::write(
                &history,
                "{\"type\":\"user\",\"message\":\"existing history\"}\n",
            )
            .unwrap();
            let (agent, events) = Self::agent(&root);
            Self {
                root,
                agent,
                events,
                history,
            }
        }

        fn agent(
            test: &crate::providers::claude::settings::ClaudeTestSettings,
        ) -> (
            Arc<ClaudeSupervisor>,
            mpsc::Receiver<crate::providers::claude::ClaudeNotification>,
        ) {
            let root = test.root_path();
            let (sender, events) = mpsc::channel(128);
            let agent = ClaudeSupervisor::new(
                ClaudeSettings {
                    claude_path: root.join("claude-stub"),
                    claude_home: root.to_owned(),
                    config_dir: Some(root.to_owned()),
                    mcp_endpoint: "http://127.0.0.1:8787/mcp".to_owned(),
                    mcp_config_dir: root.join("mcp"),

                    default_model: "sonnet".to_owned(),
                    ..test.settings.clone()
                },
                sender,
                Journal::disabled(),
                McpTokens::default(),
            );
            (agent, events)
        }

        fn request(&self, text: &str, model: &str, effort: &str) -> ClaudeTurnRequest {
            ClaudeTurnRequest {
                thread_id: THREAD.to_owned(),
                session_uuid: SESSION.to_owned(),
                first_turn: false,
                input: ClaudeUserInput::text(text),
                selection: ClaudeSelection {
                    model: model.to_owned(),
                    effort: Some(effort.to_owned()),
                    fast: false,
                },
                cwd: self.root.root_path().to_string_lossy().into_owned(),
            }
        }

        async fn initial_turn(&mut self) {
            self.initial_turn_with("sonnet", "high").await;
        }

        async fn initial_turn_with(&mut self, model: &str, effort: &str) {
            self.agent
                .start_turn(self.request("initial", model, effort))
                .await
                .unwrap();
            tokio::time::timeout(Duration::from_secs(5), async {
                loop {
                    let event =
                        crate::test_support::claude_event(self.events.recv().await.unwrap());
                    if event["method"] == "turn/completed" {
                        assert_eq!(event["params"]["turn"]["status"], "completed", "{event}");
                        break;
                    }
                }
                loop {
                    if self.agent.runtimes.lock().await[THREAD].idle.is_some() {
                        break;
                    }
                    tokio::task::yield_now().await;
                }
            })
            .await
            .unwrap();
        }

        async fn expire(&self) {
            tokio::time::pause();
            tokio::time::advance(RUNTIME_IDLE_TIMEOUT + Duration::from_secs(1)).await;
            tokio::time::resume();
            tokio::time::timeout(Duration::from_secs(5), async {
                while self.agent.has_runtime(THREAD).await {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .unwrap();
        }

        async fn received(&self, count: usize) -> Vec<Value> {
            tokio::time::timeout(Duration::from_secs(5), async {
                loop {
                    let values: Vec<Value> =
                        fs::read_to_string(self.root.root_path().join("received.jsonl"))
                            .unwrap_or_default()
                            .lines()
                            .filter_map(|line| serde_json::from_str(line).ok())
                            .collect();
                    if values.len() >= count {
                        return values;
                    }
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            })
            .await
            .unwrap()
        }

        fn launches(&self) -> Vec<Value> {
            self.log("launches.jsonl")
        }

        fn controls(&self) -> Vec<Value> {
            self.log("controls.jsonl")
        }

        fn log(&self, name: &str) -> Vec<Value> {
            fs::read_to_string(self.root.root_path().join(name))
                .unwrap_or_default()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect()
        }
    }

    fn message(id: &str, text: &str) -> ParentMessage {
        ParentMessage {
            thread_id: THREAD.to_owned(),
            delivery_id: id.to_owned(),
            text: text.to_owned(),
        }
    }

    #[tokio::test]
    async fn legacy_gateway_parent_route_restores_delivery_without_clearing_stop() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        fixture.expire().await;
        fixture
            .agent
            .conversation_index
            .update_parent(THREAD, |parent| {
                parent.delivery_route = ParentDeliveryRoute::Unknown;
            })
            .await
            .unwrap();
        assert!(
            fixture
                .agent
                .has_legacy_gateway_parent(THREAD)
                .await
                .unwrap()
        );
        assert!(
            fixture
                .agent
                .restore_gateway_parent_route(THREAD)
                .await
                .unwrap()
        );
        let receipt = fixture
            .agent
            .deliver_parent_message(message("legacy-route", "restored delivery"))
            .await
            .unwrap();
        assert_eq!(receipt["delivery_state"], "submitted");
        let received = fixture.received(2).await;
        assert_eq!(received.len(), 2);
        fixture.agent.stop_all().await;
        fixture.agent.stop_parent(THREAD).await.unwrap();
        let generation = fixture.agent.stop_generation(THREAD).await.unwrap();
        fixture
            .agent
            .conversation_index
            .update_parent(THREAD, |parent| {
                parent.delivery_route = ParentDeliveryRoute::Unknown;
            })
            .await
            .unwrap();
        assert!(
            fixture
                .agent
                .restore_gateway_parent_route(THREAD)
                .await
                .unwrap()
        );
        assert_eq!(
            fixture.agent.stop_generation(THREAD).await.unwrap(),
            generation
        );
        let error = fixture
            .agent
            .deliver_parent_message(message("after-stop", "must stay stopped"))
            .await
            .unwrap_err();
        assert!(error.message.contains("interrupted by the user"));
        fixture.agent.record_native_parent(THREAD).await.unwrap();
        assert!(
            !fixture
                .agent
                .has_legacy_gateway_parent(THREAD)
                .await
                .unwrap()
        );
        assert!(
            !fixture
                .agent
                .restore_gateway_parent_route(THREAD)
                .await
                .unwrap()
        );
        assert!(
            !fixture
                .agent
                .has_legacy_gateway_parent("claude_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
                .await
                .unwrap()
        );
    }

    #[tokio::test]
    async fn current_delivery_ownership_never_defaults_from_history_minted_or_old_selection() {
        let mut fixture = Fixture::new();
        fixture
            .agent
            .conversation_index
            .record_minted(THREAD)
            .await
            .unwrap();
        let cwd = fixture.root.root_path().to_string_lossy().into_owned();
        fixture
            .agent
            .conversation_index
            .update_parent(THREAD, move |parent| {
                parent.selection = Some(ParentSelection {
                    cwd,
                    model: "sonnet".into(),
                    effort: None,
                    fast: false,
                });
            })
            .await
            .unwrap();
        assert!(
            !fixture
                .agent
                .job_parent_gateway_owned(THREAD)
                .await
                .unwrap()
        );
        assert!(
            fixture
                .agent
                .deliver_parent_message(message("unknown-owner", "completed work"))
                .await
                .is_err()
        );
        fixture.agent.record_native_parent(THREAD).await.unwrap();
        let (replacement, _) = Fixture::agent(&fixture.root);
        assert!(!replacement.job_parent_gateway_owned(THREAD).await.unwrap());
        fixture.initial_turn().await;
        assert!(
            fixture
                .agent
                .job_parent_gateway_owned(THREAD)
                .await
                .unwrap()
        );
        assert!(fixture.agent.record_native_parent(THREAD).await.is_err());
        fixture.agent.stop_all().await;
        let (replacement, _) = Fixture::agent(&fixture.root);
        assert!(replacement.job_parent_gateway_owned(THREAD).await.unwrap());
        replacement.record_native_parent(THREAD).await.unwrap();
        assert!(!replacement.job_parent_gateway_owned(THREAD).await.unwrap());
        assert!(
            replacement
                .deliver_parent_message(message("native-owner", "completed work"))
                .await
                .is_err()
        );
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn native_lost_receipt_cannot_replay_through_either_transport_and_reconciles_exact_history()
     {
        let fixture = Fixture::new();
        fixture.agent.record_native_parent(THREAD).await.unwrap();
        let conversation = crate::agents::jobs::model::ConversationIdentity {
            provider: crate::agents::jobs::model::Provider::Claude,
            provider_home: crate::agents::jobs::model::ProviderHome::Known {
                path: fixture.root.root_path().into(),
            },
            thread_id: THREAD.into(),
        };
        let pid = std::process::id() as i32;
        let started_micros = crate::platform::process::identify(pid)
            .unwrap()
            .unwrap()
            .started_micros;
        let routes = NativeRoutes::default();
        let (_lease, mut receiver) = routes
            .register(
                conversation.clone(),
                crate::platform::process::ProcessInstance {
                    pid,
                    started_micros,
                },
            )
            .unwrap();
        let (result, ()) = tokio::join!(
            fixture
                .agent
                .deliver_native_parent_message(message("native-lost", "completed work"), &routes),
            async {
                let request = receiver.recv().await.unwrap();
                assert_eq!(
                    request.message.input_id(),
                    delivery_uuid(THREAD, "native-lost")
                );
                let saved = fixture
                    .agent
                    .conversation_index
                    .parent(THREAD)
                    .await
                    .unwrap();
                assert_eq!(
                    saved.delivery("native-lost").unwrap().state,
                    DeliveryState::Sending
                );
                drop(request.reply);
            }
        );
        let uncertain = result.unwrap_err();
        assert!(!uncertain.parent_not_submitted());
        assert!(uncertain.message.contains("not confirm"));
        assert!(
            fixture
                .agent
                .deliver_native_parent_message(message("native-lost", "completed work"), &routes)
                .await
                .unwrap_err()
                .message
                .contains("will not be resent")
        );
        assert!(
            fixture
                .agent
                .deliver_parent_message(message("native-lost", "completed work"))
                .await
                .unwrap_err()
                .message
                .contains("will not be resent")
        );
        assert!(receiver.try_recv().is_err());
        let mut history = fs::read_to_string(&fixture.history).unwrap();
        history.push_str(&format!("{}\n",json!({"type":"user","uuid":delivery_uuid(THREAD,"native-lost"),"message":{"content":"completed work"}})));
        fs::write(&fixture.history, history).unwrap();
        let receipt = fixture
            .agent
            .deliver_native_parent_message(message("native-lost", "completed work"), &routes)
            .await
            .unwrap();
        assert_eq!(receipt["delivery_state"], "recorded");
        assert_eq!(receipt["duplicate"], true);
        assert!(
            fixture
                .agent
                .deliver_native_parent_message(message("native-lost", "changed work"), &routes)
                .await
                .is_err()
        );
        assert!(fixture.launches().is_empty());
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn native_definite_unreachable_can_retry_but_submitted_never_becomes_recorded_without_evidence()
     {
        let fixture = Fixture::new();
        fixture.agent.record_native_parent(THREAD).await.unwrap();
        let routes = NativeRoutes::default();
        let unreachable = fixture
            .agent
            .deliver_native_parent_message(message("native-retry", "completed work"), &routes)
            .await
            .unwrap_err();
        assert!(unreachable.parent_not_submitted());
        let wire: crate::rpc::error::RpcError = unreachable.into();
        assert_eq!(
            wire.response(&Value::Null)["error"]["data"],
            json!({"kind":"parentUnreachable","notSubmitted":true})
        );
        assert_eq!(
            fixture
                .agent
                .conversation_index
                .parent(THREAD)
                .await
                .unwrap()
                .delivery("native-retry")
                .unwrap()
                .state,
            DeliveryState::Rejected
        );
        let pid = std::process::id() as i32;
        let started_micros = crate::platform::process::identify(pid)
            .unwrap()
            .unwrap()
            .started_micros;
        let conversation = crate::agents::jobs::model::ConversationIdentity {
            provider: crate::agents::jobs::model::Provider::Claude,
            provider_home: crate::agents::jobs::model::ProviderHome::Known {
                path: fixture.root.root_path().into(),
            },
            thread_id: THREAD.into(),
        };
        let (_lease, mut receiver) = routes
            .register(
                conversation,
                crate::platform::process::ProcessInstance {
                    pid,
                    started_micros,
                },
            )
            .unwrap();
        let (result, ()) = tokio::join!(
            fixture
                .agent
                .deliver_native_parent_message(message("native-retry", "completed work"), &routes),
            async {
                receiver
                    .recv()
                    .await
                    .unwrap()
                    .reply
                    .send(NativeDeliveryState::Submitted)
                    .unwrap();
            }
        );
        assert_eq!(result.unwrap()["delivery_state"], "submitted");
        let duplicate = fixture
            .agent
            .deliver_parent_message(message("native-retry", "completed work"))
            .await
            .unwrap();
        assert_eq!(duplicate["delivery_state"], "submitted");
        assert_eq!(duplicate["duplicate"], true);
        assert!(receiver.try_recv().is_err());
        assert!(fixture.launches().is_empty());
    }

    #[tokio::test]
    async fn fast_mode_carries_over_only_to_the_same_model() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        fixture.expire().await;
        fixture
            .agent
            .update_settings(
                THREAD,
                &ClaudeSelection {
                    model: "opus".to_owned(),
                    effort: Some("low".to_owned()),
                    fast: true,
                },
            )
            .await
            .unwrap();
        let same_model = fixture.agent.fast_mode(THREAD, "claude-opus-5-5").await;
        let other_model = fixture.agent.fast_mode(THREAD, "sonnet").await;
        fixture.agent.stop_all().await;
        assert!(same_model);
        assert!(!other_model);
    }

    #[tokio::test]
    async fn expired_parent_resumes_exact_history_and_latest_settings() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        fixture.expire().await;
        fixture
            .agent
            .update_settings(
                THREAD,
                &ClaudeSelection {
                    model: "opus".to_owned(),
                    effort: Some("low".to_owned()),
                    fast: true,
                },
            )
            .await
            .unwrap();
        let receipt = fixture
            .agent
            .deliver_parent_message(message("completion-one", "completed work"))
            .await
            .unwrap();
        let received = fixture.received(2).await;
        let launches = fixture.launches();
        fixture.agent.stop_all().await;
        assert_eq!(receipt["delivery"], "gateway-started");
        assert_eq!(receipt["delivery_confirmed"], false);
        assert_eq!(launches.len(), 2);
        let args = launches[1]["argv"].as_array().unwrap();
        assert!(
            args.windows(2)
                .any(|pair| pair == [json!("--resume"), json!(SESSION)])
        );
        assert!(!args.contains(&json!("--session-id")));
        assert!(
            args.windows(2)
                .any(|pair| pair == [json!("--model"), json!("opus")])
        );
        assert!(
            args.windows(2)
                .any(|pair| pair == [json!("--effort"), json!("low")])
        );
        assert_eq!(launches[0]["fastMode"], false);
        assert_eq!(launches[1]["fastMode"], true);
        assert_eq!(launches[1]["cwd"], launches[0]["cwd"]);
        assert!(launches[1]["context"].get("account").is_none());
        assert_eq!(received[1]["message"]["content"], "completed work");
        assert_eq!(received[1]["isSynthetic"], true);
    }

    #[tokio::test]
    async fn side_question_answers_from_the_idle_runtime_without_opening_a_turn() {
        let mut fixture = Fixture::new();
        assert_eq!(
            fixture.agent.side_question(THREAD, "title?").await,
            Ok(None)
        );
        fixture.initial_turn().await;
        let answer = fixture.agent.side_question(THREAD, "title?").await;
        let controls = fixture.controls();
        fixture.agent.stop_all().await;
        assert_eq!(answer, Ok(Some("Answer to title?".to_owned())));
        assert_eq!(
            controls.last(),
            Some(&json!({"subtype":"side_question","question":"title?"}))
        );
        while let Ok(event) = fixture.events.try_recv() {
            let event = crate::test_support::claude_event(event);
            assert_ne!(event["method"], "turn/started", "{event}");
        }
    }

    #[tokio::test]
    async fn side_question_answers_during_a_running_turn_without_ending_it() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        fixture
            .agent
            .start_turn(fixture.request("keep working", "sonnet", "high"))
            .await
            .unwrap();
        let answer = fixture.agent.side_question(THREAD, "title?").await;
        let running = fixture.agent.runtimes.lock().await[THREAD]
            .active_turn
            .is_some();
        fixture.agent.stop_all().await;
        assert_eq!(answer, Ok(Some("Answer to title?".to_owned())));
        assert!(running, "the side question ended the running turn");
    }

    #[tokio::test]
    async fn a_cancelled_detached_side_question_kills_its_whole_process_group() {
        let fixture = Fixture::new();
        let cwd = fixture.root.root_path().to_string_lossy().into_owned();
        let agent = Arc::clone(&fixture.agent);
        let question =
            tokio::spawn(async move { agent.detached_side_question(THREAD, &cwd, "hang").await });
        let pid_file = fixture.root.root_path().join("detached-child.pid");
        let child = tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                if let Some(pid) = fs::read_to_string(&pid_file)
                    .ok()
                    .and_then(|pid| pid.trim().parse::<i32>().ok())
                {
                    return Pid::from_raw(pid);
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        question.abort();
        assert!(question.await.unwrap_err().is_cancelled());
        let reaped = tokio::time::timeout(Duration::from_secs(10), async {
            while nix::sys::signal::kill(child, None).is_ok()
                || !fixture
                    .agent
                    .process_registry
                    .lock()
                    .unwrap()
                    .groups
                    .is_empty()
            {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await;
        assert!(
            reaped.is_ok(),
            "the hook-like grandchild outlived its side question"
        );
    }

    #[tokio::test]
    async fn detached_side_question_output_is_bounded() {
        let fixture = Fixture::new();
        let cwd = fixture.root.root_path().to_string_lossy().into_owned();
        let answer = fixture
            .agent
            .detached_side_question(THREAD, &cwd, "flood")
            .await;
        assert_eq!(
            answer,
            Err("Claude side question output exceeded 1 MiB".to_owned())
        );
    }

    #[tokio::test]
    async fn an_unanswered_side_question_is_cancelled_at_the_control_deadline() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        tokio::time::pause();
        let answer = fixture.agent.side_question(THREAD, "unanswered").await;
        tokio::time::resume();
        assert!(answer.is_err());
        let cancelled = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let controls = fixture.controls();
                if let Some(cancel) = controls
                    .iter()
                    .find(|control| control["type"] == "control_cancel_request")
                {
                    return (controls[controls.len() - 2].clone(), cancel.clone());
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        fixture.agent.stop_all().await;
        assert_eq!(
            cancelled.0,
            json!({"subtype":"side_question","question":"unanswered"})
        );
        assert!(
            cancelled.1["request_id"]
                .as_str()
                .is_some_and(|id| !id.is_empty())
        );
    }

    #[tokio::test]
    async fn failed_parent_ledger_write_does_not_acknowledge_delivery() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        let history_dir = fixture.root.root_path().join("remotecoder-history");
        let lock = history_dir.join(format!(
            "{}.lock",
            crate::ids::sha256_hex(THREAD.as_bytes())
        ));
        if lock.exists() {
            fs::remove_file(&lock).unwrap();
        }
        fs::create_dir(&lock).expect("block the parent transaction lock");
        let outcome = fixture
            .agent
            .deliver_parent_message(message("write-failed", "the child finished"))
            .await;
        fs::remove_dir(&lock).expect("restore the parent transaction lock");
        let error = outcome.expect_err("delivery must not be acknowledged");
        assert_eq!(error.code, RpcCode::Internal);
        assert_eq!(fixture.received(1).await.len(), 1);
        let parent = fixture
            .agent
            .conversation_index
            .parent(THREAD)
            .await
            .expect("parent record");
        assert!(parent.delivery("write-failed").is_none());
    }

    #[tokio::test]
    async fn a_closing_supervisor_rejects_parent_messages_so_a_later_delivery_retries_them() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        fixture.agent.process_registry.lock().unwrap().closing = true;
        let idle = fixture
            .agent
            .deliver_parent_message(message("idle", "the child finished"))
            .await
            .expect_err("a closing supervisor starts no turn");
        {
            let mut runtimes = fixture.agent.runtimes.lock().await;
            let runtime = runtimes.get_mut(THREAD).unwrap();
            runtime.idle = None;
            runtime.active_turn = Some(super::super::RuntimeTurn::new(
                crate::providers::claude::translate::TurnTranslator::new(
                    THREAD.to_owned(),
                    "claude-turn-running".to_owned(),
                    fixture.root.root_path().to_string_lossy().into_owned(),
                    None,
                    0,
                    Arc::default(),
                ),
                false,
                None,
            ));
        }
        let steered = fixture
            .agent
            .deliver_parent_message(message("steered", "the second child finished"))
            .await
            .expect_err("a closing supervisor writes no input");
        let parent = fixture
            .agent
            .conversation_index
            .parent(THREAD)
            .await
            .unwrap();
        fixture.agent.process_registry.lock().unwrap().closing = false;
        let retried = fixture
            .agent
            .deliver_parent_message(message("steered", "the second child finished"))
            .await
            .expect("a rejected delivery is delivered again");
        let received = fixture.received(2).await;
        fixture.agent.stop_all().await;

        for refused in [&idle, &steered] {
            assert_eq!(refused.code, RpcCode::ServerBusy);
            assert_eq!(refused.message, "Claude runtime owner is stopping");
        }
        for id in ["idle", "steered"] {
            assert_eq!(
                parent.delivery(id).map(|delivery| delivery.state),
                Some(DeliveryState::Rejected)
            );
        }
        assert_eq!(retried["delivery"], "gateway-steered");
        assert_eq!(received.len(), 2);
        assert_eq!(
            received[1]["message"]["content"],
            "the second child finished"
        );
    }

    #[tokio::test]
    async fn a_lost_message_receipt_is_reconciled_without_resending_or_guessing_absence() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        fixture.expire().await;
        for id in ["recorded", "unresolved"] {
            let id = id.to_owned();
            fixture
                .agent
                .conversation_index
                .update_parent(THREAD, move |parent| {
                    parent.record_delivery(Delivery {
                        id,
                        fingerprint: crate::ids::sha256_hex(b"completed work"),
                        state: DeliveryState::Sending,
                        receipt: Value::Null,
                    });
                })
                .await
                .unwrap();
        }
        let mut history = fs::read_to_string(&fixture.history).unwrap();
        history.push_str(&format!(
            "{}\n",
            json!({
                "type":"user", "uuid":delivery_uuid(THREAD, "recorded"),
                "message":{"content":"completed work"}
            })
        ));
        fs::write(&fixture.history, history).unwrap();
        let (restarted, _) = Fixture::agent(&fixture.root);
        let receipt = restarted
            .deliver_parent_message(message("recorded", "completed work"))
            .await
            .unwrap();
        let unresolved = restarted
            .deliver_parent_message(message("unresolved", "completed work"))
            .await
            .unwrap_err();
        assert_eq!(receipt["delivery_state"], "recorded");
        assert!(unresolved.is_queued_stall());
        assert_eq!(fixture.launches().len(), 1);
        assert_eq!(fixture.received(1).await.len(), 1);
        restarted.stop_all().await;
    }

    #[tokio::test]
    async fn compacted_receipts_keep_message_identity_and_conflict_protection() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        fixture
            .agent
            .conversation_index
            .update_parent(THREAD, |parent| {
                for index in 0..300 {
                    parent.record_delivery(Delivery {
                        id: format!("saved-{index}"),
                        fingerprint: crate::ids::sha256_hex(b"completed work"),
                        state: DeliveryState::Submitted,
                        receipt: json!({"delivery":"gateway-steered"}),
                    });
                }
            })
            .await
            .unwrap();
        let receipt = fixture
            .agent
            .deliver_parent_message(message("saved-0", "completed work"))
            .await
            .unwrap();
        let conflict = fixture
            .agent
            .deliver_parent_message(message("saved-0", "changed content"))
            .await
            .unwrap_err();
        assert_eq!(receipt["duplicate"], true);
        assert_eq!(receipt["delivery_state"], "submitted");
        assert!(conflict.message.contains("different message or sender"));
        assert_eq!(fixture.received(1).await.len(), 1);
        fixture.agent.stop_all().await;
    }

    #[tokio::test]
    async fn simultaneous_messages_resume_once_then_steer_and_deduplicate() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        fixture.expire().await;
        let (one, two) = tokio::join!(
            fixture
                .agent
                .deliver_parent_message(message("one", "first child")),
            fixture
                .agent
                .deliver_parent_message(message("two", "second child")),
        );
        let (one, two) = (one.unwrap(), two.unwrap());
        let duplicate = fixture
            .agent
            .deliver_parent_message(message("one", "first child"))
            .await
            .unwrap();
        let conflict = fixture
            .agent
            .deliver_parent_message(message("one", "changed sender or message"))
            .await
            .unwrap_err();
        let received = fixture.received(3).await;
        let launches = fixture.launches();
        fixture.agent.stop_all().await;
        assert_eq!(launches.len(), 2);
        assert_eq!(one["turn_id"], two["turn_id"]);
        assert_eq!(one["delivery"], "gateway-started");
        assert_eq!(two["delivery"], "gateway-steered");
        assert_eq!(duplicate["duplicate"], true);
        assert!(conflict.message.contains("different message or sender"));
        assert_eq!(received.len(), 3);
        assert_eq!(received[1]["message"]["content"], "first child");
        assert_eq!(received[2]["message"]["content"], "second child");
    }

    #[tokio::test]
    async fn missing_history_and_interruption_reject_callbacks_without_spawning() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        fixture.expire().await;
        fs::remove_file(&fixture.history).unwrap();
        let missing = fixture
            .agent
            .deliver_parent_message(message("missing", "do not reconstruct"))
            .await
            .unwrap_err();
        fs::write(&fixture.history, "{}\n").unwrap();
        let running = fixture
            .agent
            .start_turn(fixture.request("keep working", "sonnet", "high"))
            .await
            .unwrap();
        fixture
            .agent
            .interrupt(THREAD, &running, nothing_suspended)
            .await
            .unwrap();
        let interrupted = fixture
            .agent
            .deliver_parent_message(message("stopped", "do not wake"))
            .await
            .unwrap_err();
        let launches = fixture.launches();
        fixture.agent.stop_all().await;
        assert!(
            missing.message.contains("is missing from"),
            "{}",
            missing.message
        );
        assert!(interrupted.message.contains("interrupted by the user"));
        assert_eq!(launches.len(), 2);
    }

    #[tokio::test]
    async fn a_restarted_gateway_wakes_the_parent_with_its_recorded_selection_once_per_delivery_id()
    {
        let mut fixture = Fixture::new();
        fixture.initial_turn_with("opus[1m]", "max").await;
        fixture.expire().await;
        let (restarted, _restarted_events) = Fixture::agent(&fixture.root);
        let receipt = restarted
            .deliver_parent_message(message("child-done", "review finished"))
            .await
            .unwrap();
        let received = fixture.received(2).await;
        restarted.stop_all().await;
        let (again, _again_events) = Fixture::agent(&fixture.root);
        let retried = again
            .deliver_parent_message(message("child-done", "review finished"))
            .await
            .unwrap();
        let launches = fixture.launches();
        again.stop_all().await;

        assert_eq!(receipt["delivery"], "gateway-started");
        assert_eq!(retried["duplicate"], true);
        assert_eq!(retried["delivery_state"], "recorded");
        assert_eq!(retried["turn_id"], receipt["turn_id"]);
        assert_eq!(launches.len(), 2);
        let args = launches[1]["argv"].as_array().unwrap();
        for pair in [
            ["--resume", SESSION],
            ["--model", "opus[1m]"],
            ["--effort", "max"],
        ] {
            assert!(
                args.windows(2)
                    .any(|window| window == [json!(pair[0]), json!(pair[1])]),
                "{pair:?} in {args:?}"
            );
        }
        assert_eq!(launches[1]["cwd"], launches[0]["cwd"]);
        assert_eq!(
            received[1]["uuid"],
            json!(delivery_uuid(THREAD, "child-done"))
        );
        assert!(is_session_uuid(received[1]["uuid"].as_str().unwrap()));
        assert_ne!(
            delivery_uuid(THREAD, "child-done"),
            delivery_uuid(THREAD, "child-done-2")
        );
    }

    #[tokio::test]
    async fn a_user_stop_interrupts_the_cli_and_refuses_wakes_across_restarts_until_a_user_turn() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        let running = fixture
            .agent
            .start_turn(fixture.request("keep working", "sonnet", "high"))
            .await
            .unwrap();
        fixture.received(2).await;
        fixture
            .agent
            .interrupt(THREAD, &running, nothing_suspended)
            .await
            .unwrap();
        let controls = fixture.controls();
        assert!(!fixture.agent.has_runtime(THREAD).await);

        let (restarted, mut restarted_events) = Fixture::agent(&fixture.root);
        let after_restart = restarted
            .deliver_parent_message(message("after-restart", "wake up"))
            .await
            .unwrap_err();
        restarted
            .start_turn(fixture.request("continue", "sonnet", "high"))
            .await
            .unwrap();
        let after_user_turn = restarted
            .deliver_parent_message(message("after-user-turn", "child done"))
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                let event = crate::test_support::claude_event(
                    restarted_events.recv().await.expect("restarted CLI event"),
                );
                if event["method"] == "item/completed"
                    && event["params"]["item"]["type"] == "userMessage"
                    && event["params"]["item"]["content"][0]["text"] == "continue"
                {
                    break;
                }
            }
        })
        .await
        .expect("the restarted CLI echoes the user turn after recording its launch");
        let launches = fixture.launches();
        restarted.stop_all().await;

        assert!(
            controls.contains(&json!({"subtype": "interrupt", "cancel_queued": true})),
            "{controls:?}"
        );
        assert!(
            after_restart.message.contains("interrupted by the user"),
            "{}",
            after_restart.message
        );
        assert_eq!(after_user_turn["delivery"], "gateway-steered");
        assert_eq!(launches.len(), 2);
    }

    #[tokio::test]
    async fn a_stop_names_the_running_turn_and_the_next_message_is_one_turn_with_its_reply() {
        let mut fixture = Fixture::new();
        fixture.initial_turn().await;
        let running = fixture
            .agent
            .start_turn(fixture.request("keep working", "sonnet", "high"))
            .await
            .unwrap();
        fixture.received(2).await;

        let mismatched = fixture
            .agent
            .interrupt(THREAD, "claude-turn-earlier", nothing_suspended)
            .await
            .unwrap_err();
        let still_running = fixture.agent.active_turn_id(THREAD).await;
        let parent_after_refusal = fixture
            .agent
            .conversation_index
            .parent(THREAD)
            .await
            .unwrap();
        let controls_after_refusal = fixture.controls();
        fixture
            .agent
            .interrupt(THREAD, &running, nothing_suspended)
            .await
            .unwrap();
        let ended = fixture
            .agent
            .interrupt(THREAD, &running, nothing_suspended)
            .await
            .unwrap_err();
        let mut stop_frames = Vec::new();
        while let Ok(frame) = fixture.events.try_recv() {
            let frame = crate::test_support::claude_event(frame);
            stop_frames.push(frame);
        }

        let mut request = fixture.request("reply: after the stop", "sonnet", "high");
        request.input.client_id = Some("after-stop-input".to_owned());
        let next = fixture.agent.start_turn(request).await.unwrap();
        let frames = tokio::time::timeout(Duration::from_secs(5), async {
            let mut frames = Vec::new();
            loop {
                let frame = crate::test_support::claude_event(fixture.events.recv().await.unwrap());
                let completed = frame["method"] == "turn/completed";
                frames.push(frame);
                if completed {
                    return frames;
                }
            }
        })
        .await
        .unwrap();
        fixture.agent.stop_all().await;

        let TurnControlError::Failed(mismatched) = mismatched else {
            panic!("a mismatched turn is a refusal, got {mismatched:?}");
        };
        assert_eq!(mismatched.code, RpcCode::InvalidRequest);
        assert_eq!(
            mismatched.message,
            format!("expected active turn id claude-turn-earlier but found {running}")
        );
        assert_eq!(still_running.as_deref(), Some(running.as_str()));
        assert!(!parent_after_refusal.stopped);
        assert!(
            controls_after_refusal.is_empty(),
            "{controls_after_refusal:?}"
        );
        assert!(
            matches!(&ended, TurnControlError::NotRunning { message } if message == "no active turn to interrupt"),
            "{ended:?}"
        );
        let stopped: Vec<_> = stop_frames
            .iter()
            .filter(|frame| frame["method"] == "turn/completed")
            .map(|frame| &frame["params"]["turn"])
            .collect();
        assert_eq!(stopped.len(), 1, "{stopped:?}");
        assert_eq!(stopped[0]["id"], running);
        assert_eq!(stopped[0]["status"], "interrupted");
        let started: Vec<_> = frames
            .iter()
            .filter(|frame| frame["method"] == "turn/started")
            .map(|frame| frame["params"]["turn"]["id"].clone())
            .collect();
        assert_eq!(started, [json!(next)]);
        let completed = frames.last().unwrap();
        assert_eq!(completed["params"]["turn"]["id"], next);
        assert_eq!(completed["params"]["turn"]["status"], "completed");
        let items: Vec<_> = frames
            .iter()
            .filter(|frame| frame["method"] == "item/completed")
            .map(|frame| {
                assert_eq!(frame["params"]["turnId"], next);
                &frame["params"]["item"]
            })
            .collect();
        assert!(
            items.iter().any(|item| item["type"] == "userMessage"
                && item["clientId"] == "after-stop-input"),
            "{items:?}"
        );
        assert!(
            items
                .iter()
                .any(|item| item["type"] == "agentMessage" && item["text"] == "after the stop"),
            "{items:?}"
        );
    }
}
