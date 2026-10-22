//! Native conversation changes must remain fenced after the requesting socket leaves.
use super::agent_gateway::parse_native_error;
use super::{Gateway, NativeMutationTransport, PendingControlReply, SEND_TIMEOUT_SECONDS};
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult, log_diagnostic_ws_frame};
use crate::turns::is_durable_codex_thread;
use anyhow::{Context, Result, anyhow, ensure};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tokio::sync::{Mutex, oneshot};

const UNVERIFIED_NATIVE_CHANGE: &str = "A native conversation change is still unverified. Ordinary messages remain available; further native changes wait for verification or a confirmed runtime replacement.";

const MAX_PENDING_NATIVE_MUTATIONS: usize = 1024;

#[derive(Default)]
pub(super) struct PendingNativeMutations {
    markers: Mutex<HashMap<String, i32>>,
}

impl PendingNativeMutations {
    pub(super) fn validate(markers: &HashMap<String, i32>) -> Result<()> {
        ensure!(
            markers.len() <= MAX_PENDING_NATIVE_MUTATIONS
                && markers.iter().all(|(thread, pid)| !thread.is_empty()
                    && is_durable_codex_thread(thread)
                    && *pid > 0),
            "invalid pending native conversation changes"
        );
        Ok(())
    }

    pub(super) async fn restore(&self, markers: HashMap<String, i32>) {
        *self.markers.lock().await = markers;
    }

    pub(super) async fn durable(&self) -> HashMap<String, i32> {
        self.markers
            .lock()
            .await
            .iter()
            .filter(|(thread, _)| is_durable_codex_thread(thread))
            .map(|(thread, pid)| (thread.clone(), *pid))
            .collect()
    }

    pub(super) async fn contains(&self, thread: &str) -> bool {
        self.markers.lock().await.contains_key(thread)
    }

    async fn recorded(&self, only_thread: Option<&str>) -> Vec<(String, i32)> {
        self.markers
            .lock()
            .await
            .iter()
            .filter(|(thread, _)| only_thread.is_none_or(|wanted| wanted == thread.as_str()))
            .map(|(thread, pid)| (thread.clone(), *pid))
            .collect()
    }

    async fn remove_owned(&self, owners: Vec<(String, i32)>) -> bool {
        let mut markers = self.markers.lock().await;
        let mut removed = false;
        for (thread, pid) in owners {
            if markers.get(&thread) == Some(&pid) {
                markers.remove(&thread);
                removed = true;
            }
        }
        removed
    }

    pub(super) async fn mark(&self, thread: &str, pid: i32) -> Result<()> {
        let mut markers = self.markers.lock().await;
        ensure!(
            !markers.contains_key(thread),
            "A native change is already pending for this conversation"
        );
        ensure!(
            markers.len() < MAX_PENDING_NATIVE_MUTATIONS,
            "Too many native conversation changes are pending"
        );
        markers.insert(thread.to_owned(), pid);
        Ok(())
    }
}

pub(super) enum NativeMutationError {
    Native(RpcError),
    NotEnqueued(anyhow::Error),
    OutcomeUnknown(anyhow::Error),
    Storage(anyhow::Error),
}

impl std::fmt::Display for NativeMutationError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Native(error) => formatter.write_str(&error.message),
            Self::NotEnqueued(error) | Self::OutcomeUnknown(error) | Self::Storage(error) => {
                write!(formatter, "{error}")
            }
        }
    }
}

impl From<NativeMutationError> for RpcError {
    fn from(error: NativeMutationError) -> Self {
        match error {
            NativeMutationError::Native(error) => error,
            NativeMutationError::NotEnqueued(error)
            | NativeMutationError::OutcomeUnknown(error)
            | NativeMutationError::Storage(error) => Self::from(error),
        }
    }
}

impl Gateway {
    /// One verified current PID and at most 1024 recorded threads, with one durable
    /// write for all proven-dead owners. A live or unreadable old PID stays pending.
    pub(crate) async fn reconcile_pending_native_mutations(
        &self,
        only_thread: Option<&str>,
        current_pid: Option<i32>,
    ) -> Result<()> {
        let pending = self.native_mutations.recorded(only_thread).await;
        if pending.is_empty() {
            return Ok(());
        }
        let current_pid = match current_pid {
            Some(pid) => pid,
            None => self.codex.info().await?.pid,
        };
        let dead = pending
            .into_iter()
            .filter(|(_, pid)| *pid != current_pid && process_is_proven_gone(*pid))
            .collect::<Vec<_>>();
        if dead.is_empty() {
            return Ok(());
        }
        let removed = self.native_mutations.remove_owned(dead).await;
        if removed {
            self.commit_turn_state()
                .await
                .context("Persisting proven-dead native conversation changes")?;
        }
        Ok(())
    }

    async fn mark_pending_native_mutation(&self, thread: &str, pid: i32) -> Result<()> {
        self.reconcile_pending_native_mutations(Some(thread), Some(pid))
            .await?;
        ensure!(
            self.turn_state_path.is_some(),
            "Native conversation change storage is unavailable"
        );
        self.native_mutations.mark(thread, pid).await?;
        self.commit_turn_state()
            .await
            .context("Persisting pending native conversation change")
    }

    async fn clear_pending_native_mutation(&self, thread: &str, pid: i32) -> Result<()> {
        let removed = self
            .native_mutations
            .remove_owned(vec![(thread.to_owned(), pid)])
            .await;
        if removed {
            self.commit_turn_state()
                .await
                .context("Persisting completed native conversation change")?;
        }
        Ok(())
    }

    pub(super) async fn native_mutation_rpc(&self, method: &str, params: Value) -> RpcResult {
        let thread = params
            .get("threadId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .ok_or_else(|| RpcError::new(RpcCode::InvalidParams, "threadId is required"))?;
        if !is_durable_codex_thread(thread) {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "A Codex threadId is required",
            ));
        }
        let thread = thread.to_owned();
        Ok(self.run_native_mutation(method, params, &thread).await?)
    }

    pub(super) async fn run_native_mutation(
        &self,
        method: &str,
        params: Value,
        thread: &str,
    ) -> std::result::Result<Value, NativeMutationError> {
        self.run_native_mutation_with_send_timeout(
            method,
            params,
            thread,
            Duration::from_secs_f64(SEND_TIMEOUT_SECONDS),
        )
        .await
    }

    async fn run_native_mutation_with_send_timeout(
        &self,
        method: &str,
        params: Value,
        thread: &str,
        send_timeout: Duration,
    ) -> std::result::Result<Value, NativeMutationError> {
        let current_pid = self
            .codex
            .info()
            .await
            .map_err(NativeMutationError::NotEnqueued)?
            .pid;
        let transport = self
            .native_mutation_transport
            .lock()
            .await
            .clone()
            .context("Codex control connection is unavailable")
            .map_err(NativeMutationError::NotEnqueued)?;
        if transport.pid != current_pid {
            return Err(NativeMutationError::NotEnqueued(anyhow!(
                "Codex control connection changed; retry the native conversation change"
            )));
        }
        self.mark_pending_native_mutation(thread, transport.pid)
            .await
            .map_err(NativeMutationError::NotEnqueued)?;
        let reply = self
            .call_native_mutation_control(&transport, method, params, send_timeout)
            .await;
        match reply {
            Err(error @ NativeMutationError::OutcomeUnknown(_)) => Err(error),
            settled => {
                self.clear_pending_native_mutation(thread, transport.pid)
                    .await
                    .map_err(NativeMutationError::Storage)?;
                settled
            }
        }
    }

    /// The response has no wall-clock cap. A lost transport leaves the durable
    /// marker in place because the old native socket may still have unread work.
    async fn call_native_mutation_control(
        &self,
        transport: &NativeMutationTransport,
        method: &str,
        params: Value,
        send_timeout: Duration,
    ) -> std::result::Result<Value, NativeMutationError> {
        let seq = self.next_control_request_id.fetch_add(1, Ordering::Relaxed);
        let control_id = format!("gw:internal:{seq}");
        let (reply_tx, reply_rx) = oneshot::channel();
        self.control_requests
            .lock()
            .expect("control replies poisoned")
            .insert(control_id.clone(), reply_tx);
        let _pending = PendingControlReply {
            id: control_id.clone(),
            replies: &self.control_requests,
        };
        let request = json!({"jsonrpc":"2.0","id":control_id,"method":method,"params":params});
        let text = serde_json::to_string(&request)
            .map_err(|error| NativeMutationError::NotEnqueued(error.into()))?;
        log_diagnostic_ws_frame("gateway->codex", None, &text);
        let permit = tokio::time::timeout(send_timeout, transport.sender.reserve())
            .await
            .map_err(|_| NativeMutationError::NotEnqueued(anyhow!("Codex control send timed out")))?
            .map_err(|_| {
                NativeMutationError::NotEnqueued(anyhow!(
                    "Codex control channel closed before enqueue"
                ))
            })?;
        permit.send(text);
        reply_rx
            .await
            .map_err(|_| {
                NativeMutationError::OutcomeUnknown(
                    anyhow!("Native conversation change response channel closed")
                        .context(UNVERIFIED_NATIVE_CHANGE),
                )
            })?
            .map_err(|text| {
                NativeMutationError::Native(
                    parse_native_error(&text)
                        .unwrap_or_else(|| RpcError::new(RpcCode::Internal, text)),
                )
            })
    }
}

fn process_is_proven_gone(pid: i32) -> bool {
    if pid <= 0 {
        return false;
    }
    // A process that is merely inaccessible is still treated as live.
    let result = unsafe { libc::kill(pid, 0) };
    result == -1 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gateway::ClientTx;
    use crate::notifications::history::NotificationOrigin;
    use crate::rpc::dispatch::{OwnedRoute, OwnedTarget};
    use std::sync::Arc;
    use tokio::sync::mpsc;

    fn exited_process_pid() -> i32 {
        let mut child = std::process::Command::new("/bin/sh")
            .args(["-c", "exit 0"])
            .spawn()
            .unwrap();
        let pid = i32::try_from(child.id()).unwrap();
        child.wait().unwrap();
        assert!(process_is_proven_gone(pid));
        pid
    }

    fn make_gateway(directory: &std::path::Path) -> crate::test_support::TestGateway {
        crate::test_support::TestGateway::with_native_runtime(directory)
    }

    #[tokio::test]
    async fn owned_native_change_survives_client_disconnect_until_exact_reply() {
        let directory = tempfile::tempdir().unwrap();
        let gateway = make_gateway(directory.path());
        let (control_tx, mut control_rx) = mpsc::channel(2);
        *gateway.native_mutation_transport.lock().await = Some(NativeMutationTransport {
            pid: i32::try_from(std::process::id()).unwrap(),
            sender: control_tx,
        });
        let (client_tx, client_rx) = mpsc::channel(2);
        let client = ClientTx {
            content_subscriptions: Arc::default(),
            query_response: None,
            installation_id: None,
            id: 12,
            tx: client_tx,
            closed: tokio_util::sync::CancellationToken::new(),
        };
        let thread = "e1741c43-3d9a-4448-9f4a-3c7e5906e852";
        let request = json!({"id":7,"method":"thread/goal/set","params":{
            "threadId":thread,"objective":"Continue the task","status":"active"
        }});
        let object = request.as_object().unwrap().clone();
        let admission = gateway.admission.admit(thread).unwrap();
        let (done_tx, done_rx) = oneshot::channel();
        let owner = Arc::clone(&gateway);
        assert!(
            gateway
                .command_tasks
                .spawn("native change test", async move {
                    let _admission = admission;
                    let result = owner
                        .handle_owned_rpc(
                            12,
                            &client,
                            "thread/goal/set",
                            OwnedTarget::Gateway(OwnedRoute::NativeMutation),
                            &object,
                        )
                        .await;
                    let _ = done_tx.send(());
                    result
                })
        );

        let raw = control_rx.recv().await.expect("native request was sent");
        let native: Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(native["method"], "thread/goal/set");
        assert!(gateway.admission.admit_compaction(thread).is_err());
        assert!(gateway.native_mutations.contains(thread).await);
        drop(client_rx);
        tokio::task::yield_now().await;
        assert!(gateway.admission.admit_compaction(thread).is_err());

        gateway
            .handle_control_text(
                json!({"id":native["id"],"result":{}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        done_rx.await.unwrap();
        gateway.command_tasks.stop().await;
        assert!(!gateway.native_mutations.contains(thread).await);
        assert!(gateway.admission.admit_compaction(thread).is_ok());
    }

    #[tokio::test]
    async fn restored_unknown_mutation_stays_pending_while_native_pid_is_live() {
        let directory = tempfile::tempdir().unwrap();
        let thread = "e1741c43-3d9a-4448-9f4a-3c7e5906e852";
        let pid = i32::try_from(std::process::id()).unwrap();
        let first = make_gateway(directory.path());
        first
            .mark_pending_native_mutation(thread, pid)
            .await
            .unwrap();
        drop(first);

        let restored = make_gateway(directory.path());
        restored.load_turn_state().await.unwrap();
        assert_eq!(
            restored.native_mutations.durable().await.get(thread),
            Some(&pid)
        );
        restored
            .reconcile_pending_native_mutations(Some(thread), Some(pid + 1))
            .await
            .unwrap();
        assert_eq!(
            restored.native_mutations.durable().await.get(thread),
            Some(&pid)
        );
    }

    #[tokio::test]
    async fn replaced_control_sender_cannot_reroute_a_marked_native_change() {
        let directory = tempfile::tempdir().unwrap();
        let gateway = make_gateway(directory.path());
        let pid = i32::try_from(std::process::id()).unwrap();
        let thread = "e1741c43-3d9a-4448-9f4a-3c7e5906e852";
        let (original_tx, mut original_rx) = mpsc::channel(2);
        *gateway.native_mutation_transport.lock().await = Some(NativeMutationTransport {
            pid,
            sender: original_tx,
        });
        let write_guard = gateway.turn_state_write_lock.lock().await;
        let owner = Arc::clone(&gateway);
        let operation = tokio::spawn(async move {
            owner
                .run_native_mutation(
                    "thread/goal/set",
                    json!({"threadId":thread,"objective":"Continue","status":"active"}),
                    thread,
                )
                .await
        });
        tokio::time::timeout(Duration::from_secs(1), async {
            while !gateway.native_mutations.contains(thread).await {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let (replacement_tx, mut replacement_rx) = mpsc::channel(2);
        *gateway.native_mutation_transport.lock().await = Some(NativeMutationTransport {
            pid,
            sender: replacement_tx,
        });
        drop(write_guard);

        let original: Value = serde_json::from_str(&original_rx.recv().await.unwrap()).unwrap();
        assert_eq!(original["method"], "thread/goal/set");
        assert!(matches!(
            replacement_rx.try_recv(),
            Err(mpsc::error::TryRecvError::Empty)
        ));
        gateway
            .handle_control_text(
                json!({"id":original["id"],"result":{}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        assert!(operation.await.unwrap().is_ok());
        assert!(!gateway.native_mutations.contains(thread).await);
    }

    #[tokio::test]
    async fn failed_reservation_clears_a_request_that_was_never_enqueued() {
        for (receiver_open, send_timeout, expected) in [
            (true, Duration::from_millis(1), "send timed out"),
            (false, Duration::from_secs(1), "closed before enqueue"),
        ] {
            let directory = tempfile::tempdir().unwrap();
            let gateway = make_gateway(directory.path());
            let thread = "e1741c43-3d9a-4448-9f4a-3c7e5906e852";
            let (sender, receiver) = mpsc::channel(1);
            if receiver_open {
                sender.try_send("occupied".to_owned()).unwrap();
            } else {
                drop(receiver);
            }
            *gateway.native_mutation_transport.lock().await = Some(NativeMutationTransport {
                pid: i32::try_from(std::process::id()).unwrap(),
                sender,
            });
            let error = gateway
                .run_native_mutation_with_send_timeout(
                    "thread/goal/set",
                    json!({"threadId":thread}),
                    thread,
                    send_timeout,
                )
                .await
                .unwrap_err();
            assert!(matches!(error, NativeMutationError::NotEnqueued(_)));
            assert!(error.to_string().contains(expected), "{error}");
            assert!(!gateway.native_mutations.contains(thread).await);
            let restored = make_gateway(directory.path());
            restored.load_turn_state().await.unwrap();
            assert!(!restored.native_mutations.contains(thread).await);
        }
    }

    #[tokio::test]
    async fn native_error_reply_keeps_its_code_and_clears_the_marker() {
        let directory = tempfile::tempdir().unwrap();
        let gateway = make_gateway(directory.path());
        let thread = "e1741c43-3d9a-4448-9f4a-3c7e5906e852";
        let (sender, mut receiver) = mpsc::channel(1);
        *gateway.native_mutation_transport.lock().await = Some(NativeMutationTransport {
            pid: i32::try_from(std::process::id()).unwrap(),
            sender,
        });
        let owner = Arc::clone(&gateway);
        let operation = tokio::spawn(async move {
            owner
                .run_native_mutation("thread/goal/set", json!({"threadId":thread}), thread)
                .await
        });
        let request: Value = serde_json::from_str(&receiver.recv().await.unwrap()).unwrap();
        gateway
            .handle_control_text(
                json!({"id":request["id"],"error":{"code":-32602,"message":"bad goal"}})
                    .to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        let NativeMutationError::Native(error) = operation.await.unwrap().unwrap_err() else {
            panic!("a native error reply must stay typed");
        };
        assert_eq!(error.code, RpcCode::InvalidParams);
        assert_eq!(error.message, "bad goal");
        assert!(!gateway.native_mutations.contains(thread).await);
    }

    #[tokio::test]
    async fn queued_request_with_lost_reply_keeps_durable_marker() {
        let directory = tempfile::tempdir().unwrap();
        let gateway = make_gateway(directory.path());
        let thread = "e1741c43-3d9a-4448-9f4a-3c7e5906e852";
        let (sender, mut receiver) = mpsc::channel(1);
        *gateway.native_mutation_transport.lock().await = Some(NativeMutationTransport {
            pid: i32::try_from(std::process::id()).unwrap(),
            sender,
        });
        let owner = Arc::clone(&gateway);
        let operation = tokio::spawn(async move {
            owner
                .run_native_mutation("thread/goal/set", json!({"threadId":thread}), thread)
                .await
        });
        let _: Value = serde_json::from_str(&receiver.recv().await.unwrap()).unwrap();
        gateway.control_requests.lock().unwrap().clear();
        let error = operation.await.unwrap().unwrap_err();
        assert!(matches!(error, NativeMutationError::OutcomeUnknown(_)));
        assert!(error.to_string().contains("unverified"));
        let restored = make_gateway(directory.path());
        restored.load_turn_state().await.unwrap();
        assert!(restored.native_mutations.contains(thread).await);
    }

    #[tokio::test]
    async fn restored_dead_runtime_allows_next_goal_and_inject_requests() {
        let directory = tempfile::tempdir().unwrap();
        let old_pid = exited_process_pid();
        let goal_thread = "e1741c43-3d9a-4448-9f4a-3c7e5906e852";
        let inject_thread = "43dd6ac0-a78e-4e3b-a889-b3ca18b91603";
        let first = make_gateway(directory.path());
        first
            .native_mutations
            .mark(goal_thread, old_pid)
            .await
            .unwrap();
        first
            .native_mutations
            .mark(inject_thread, old_pid)
            .await
            .unwrap();
        first.commit_turn_state().await.unwrap();
        drop(first);

        let restored = make_gateway(directory.path());
        restored.load_turn_state().await.unwrap();
        let (sender, mut receiver) = mpsc::channel(2);
        *restored.native_mutation_transport.lock().await = Some(NativeMutationTransport {
            pid: i32::try_from(std::process::id()).unwrap(),
            sender,
        });
        for (method, thread) in [
            ("thread/goal/set", goal_thread),
            ("thread/inject_items", inject_thread),
        ] {
            let owner = Arc::clone(&restored);
            let operation = tokio::spawn(async move {
                owner
                    .run_native_mutation(method, json!({"threadId":thread}), thread)
                    .await
            });
            let request: Value = serde_json::from_str(&receiver.recv().await.unwrap()).unwrap();
            assert_eq!(request["method"], method);
            restored
                .handle_control_text(
                    json!({"id":request["id"],"result":{}}).to_string(),
                    NotificationOrigin::Control { opened_after: 0 },
                )
                .await;
            assert!(operation.await.unwrap().is_ok());
            assert!(!restored.native_mutations.contains(thread).await);
        }
    }

    #[tokio::test]
    async fn account_work_guard_clears_all_markers_after_proven_runtime_replacement() {
        let directory = tempfile::tempdir().unwrap();
        let gateway = make_gateway(directory.path());
        let old_pid = exited_process_pid();
        for thread in [
            "e1741c43-3d9a-4448-9f4a-3c7e5906e852",
            "43dd6ac0-a78e-4e3b-a889-b3ca18b91603",
        ] {
            gateway
                .native_mutations
                .mark(thread, old_pid)
                .await
                .unwrap();
        }
        gateway.commit_turn_state().await.unwrap();
        drop(gateway);
        let gateway = make_gateway(directory.path());
        gateway.load_turn_state().await.unwrap();
        assert_eq!(gateway.native_mutations.durable().await.len(), 2);
        gateway.core.lock().await.app_server_inventory_bootstrapped = true;
        gateway
            .reconcile_pending_native_mutations(None, None)
            .await
            .unwrap();
        assert!(gateway.native_mutations.durable().await.is_empty());
        let restored = make_gateway(directory.path());
        restored.load_turn_state().await.unwrap();
        assert!(restored.native_mutations.durable().await.is_empty());
    }
}
