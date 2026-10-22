use super::{
    CHILD_STOP_CONCURRENCY, CHILD_STOP_WAIT, DESCENDANT_STOP_WAIT, NO_ACTIVE_TURN, NativeInventory,
    THREAD_NOT_LOADED, TURN_CHECK_WAIT, native_error,
};
use crate::gateway::Gateway;
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};
use futures_util::{FutureExt, StreamExt};
use serde_json::{Value, json};

pub(in crate::gateway) struct CodexStop<'a> {
    gateway: &'a Gateway,
}

impl<'a> CodexStop<'a> {
    pub(in crate::gateway) fn new(gateway: &'a Gateway) -> Self {
        Self { gateway }
    }

    pub(in crate::gateway) async fn run(
        &self,
        thread: &str,
        turn: &str,
        interrupt: Value,
    ) -> RpcResult {
        self.confirm_running(thread, turn).await?;
        let ((parent, commands), descendants) = tokio::join!(
            async {
                let parent = self.gateway.call_control("turn/interrupt", interrupt).await;
                (parent, self.end_commands(thread).await)
            },
            tokio::time::timeout(DESCENDANT_STOP_WAIT, self.descendants(thread)),
        );
        let mut missed = commands
            .err()
            .map(|error| format!("its commands: {error}"))
            .into_iter()
            .collect::<Vec<_>>();
        missed.extend(
            descendants.unwrap_or_else(|_| {
                vec!["its agents did not all answer the Stop in time".to_owned()]
            }),
        );
        match (parent, missed.is_empty()) {
            (Ok(result), true) => Ok(result),
            (Err(error), true) => Err(native_error(&error)),
            (parent, false) => {
                let turn = match parent {
                    Ok(_) => "The turn stopped".to_owned(),
                    Err(error) => format!(
                        "The turn did not confirm the Stop ({})",
                        native_error(&error).message
                    ),
                };
                Err(RpcError::new(
                    RpcCode::Internal,
                    format!(
                        "{turn}, but some of its work may still be running: {}",
                        missed.join("; ")
                    ),
                ))
            }
        }
    }

    async fn confirm_running(&self, thread: &str, turn: &str) -> std::result::Result<(), RpcError> {
        let unreadable = |reason: &str| {
            RpcError::new(
                RpcCode::Internal,
                format!("The turn's state could not be read, so nothing was stopped: {reason}"),
            )
        };
        let latest = self
            .gateway
            .latest_codex_turn(thread, Some(TURN_CHECK_WAIT))
            .await
            .map_err(|error| unreadable(&native_error(&error).message))?;
        match latest
            .as_ref()
            .filter(|latest| latest["status"] == "inProgress")
            .map(|latest| latest["id"].as_str())
        {
            None => Err(RpcError::turn_not_running(
                NO_ACTIVE_TURN,
                thread,
                Some(turn),
            )),
            Some(Some(running)) if running == turn => Ok(()),
            Some(Some(running)) => Err(RpcError::new(
                RpcCode::InvalidRequest,
                format!("expected active turn id {turn} but found {running}"),
            )),
            Some(None) => Err(unreadable("the running turn has no id")),
        }
    }

    async fn descendants(&self, root: &str) -> Vec<String> {
        let NativeInventory { agents, coverage } = match self
            .gateway
            .agent_service()
            .native_codex_agents_with_freshness(root, true)
            .await
        {
            Ok(listed) => listed,
            Err(error) => return vec![format!("its agents could not be listed: {error:#}")],
        };
        let mut missed = coverage
            .is_truncated()
            .then(|| "more than 256 agents exist, so some were not checked".to_owned())
            .into_iter()
            .collect::<Vec<_>>();
        missed.extend(
            coverage
                .unreadable
                .iter()
                .filter(|thread| {
                    !agents.iter().any(|agent| {
                        agent.thread_id.as_ref() == Some(*thread) && agent.state.is_running()
                    })
                })
                .map(|thread| {
                    let title = agents
                        .iter()
                        .find(|agent| agent.thread_id.as_ref() == Some(thread))
                        .map_or(thread.as_str(), |agent| agent.title.as_str());
                    format!("{title}'s activity could not be read")
                }),
        );
        let running = agents.into_iter().filter(|agent| agent.state.is_running());
        let unstopped = futures_util::stream::iter(running)
            .map(|agent| {
                async move {
                    let Some(thread) = agent.thread_id.as_deref() else {
                        return vec![format!("{} has no known running turn", agent.title)];
                    };
                    let mut missed = Vec::new();
                    match agent.execution_id.as_deref() {
                        None => missed.push(format!("{} has no known running turn", agent.title)),
                        Some(turn) => {
                            let stopped = self
                                .gateway
                                .call_control_with_timeout(
                                    "turn/interrupt",
                                    json!({"threadId": thread, "turnId": turn}),
                                    CHILD_STOP_WAIT,
                                )
                                .await;
                            if let Err(error) = stopped
                                && native_error(&error).message != NO_ACTIVE_TURN
                            {
                                missed.push(format!("{}: {error:#}", agent.title));
                            }
                        }
                    }
                    if let Err(error) = self.end_commands(thread).await {
                        missed.push(format!("{}'s commands: {error}", agent.title));
                    }
                    missed
                }
                .boxed()
            })
            .buffer_unordered(CHILD_STOP_CONCURRENCY)
            .collect::<Vec<_>>()
            .await;
        missed.extend(unstopped.into_iter().flatten());
        missed.sort();
        missed
    }

    async fn end_commands(&self, thread: &str) -> std::result::Result<(), String> {
        let ended = self
            .gateway
            .call_control_with_timeout(
                "thread/backgroundTerminals/clean",
                json!({"threadId": thread}),
                CHILD_STOP_WAIT,
            )
            .await;
        let Err(error) = ended else {
            return Ok(());
        };
        let error = native_error(&error);
        if error.code == RpcCode::InvalidRequest && error.message.starts_with(THREAD_NOT_LOADED) {
            return Ok(());
        }
        Err(error.message)
    }
}
