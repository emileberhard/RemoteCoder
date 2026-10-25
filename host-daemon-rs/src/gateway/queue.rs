use super::Gateway;
use super::native_mutations::NativeMutationError;
use super::turn_state::prompt_preview;
use crate::rpc::error::{RpcCode, RpcData};
use crate::rpc::{RpcError, RpcResult};
use crate::time::unix_seconds;
use crate::turns::{PromptContext, QueuedSubmission, TurnKey, is_durable_codex_thread};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::Arc;
use tracing::warn;

const QUEUE_LIST_PAGE_SIZE: u32 = 100;
const MAX_QUEUE_LIST_PAGES: usize = 2;

fn required_str<'a>(params: &'a Value, field: &str) -> Result<&'a str, RpcError> {
    params
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| RpcError::new(RpcCode::InvalidParams, format!("{field} is required")))
}

fn queue_change_error(thread: &str, error: NativeMutationError) -> RpcError {
    match error {
        NativeMutationError::OutcomeUnknown(error) | NativeMutationError::Storage(error) => {
            RpcError::queue_change_uncertain(thread, &error)
        }
        error => RpcError::from(error),
    }
}

fn codex_thread(params: &Value) -> Result<String, RpcError> {
    let thread = required_str(params, "threadId")?;
    if !is_durable_codex_thread(thread) {
        return Err(RpcError::new(
            RpcCode::InvalidParams,
            "A Codex threadId is required",
        ));
    }
    Ok(thread.to_owned())
}

impl Gateway {
    pub(super) async fn queue_rpc(
        self: &Arc<Self>,
        client_id: u64,
        method: &str,
        params: Value,
    ) -> RpcResult {
        let response = match method {
            "thread/queue/add" => self.queue_add(client_id, params).await,
            "thread/queue/start" => self.queue_start(client_id, params).await,
            "thread/queue/delete" => self.queue_delete(params).await,
            _ => Err(RpcError::new(
                RpcCode::MethodNotFound,
                format!("Unsupported queue method {method}"),
            )),
        };
        if response.is_ok() && !self.clients.contains_key(&client_id) {
            self.spawn_observers_for_client(client_id).await;
        }
        response
    }

    async fn queue_add(&self, client_id: u64, params: Value) -> RpcResult {
        let thread = codex_thread(&params)?;
        let client_user_message_id = required_str(&params, "clientUserMessageId")?.to_owned();
        {
            let mut core = self.core.lock().await;
            let submission = QueuedSubmission {
                client_user_message_id: client_user_message_id.clone(),
                queued_submission_id: None,
                context: PromptContext {
                    compaction: false,
                    preview: prompt_preview(&thread, params.get("input")),
                    cwd: core.turns.thread_cwd(&thread),
                    owner_client_id: client_id,
                },
                created_at_unix_seconds: unix_seconds(),
            };
            core.turns
                .begin_queue_add(&thread, submission)
                .map_err(|refusal| {
                    RpcError::new(RpcCode::Capacity, refusal.to_string())
                        .with_data(RpcData::Capacity)
                })?;
        }
        if let Err(error) = self.commit_turn_state().await {
            let mut core = self.core.lock().await;
            core.turns.queue_not_added(&thread, &client_user_message_id);
            core.turns.finish_queue_add(&thread);
            return Err(RpcError::from(
                error.context("Persisting the queued message failed"),
            ));
        }
        let outcome = self
            .run_native_mutation("thread/queue/add", params, &thread)
            .await;
        let changed = {
            let mut core = self.core.lock().await;
            core.turns.finish_queue_add(&thread);
            match &outcome {
                Ok(response) => response
                    .pointer("/queuedSubmission/id")
                    .and_then(Value::as_str)
                    .is_some_and(|id| {
                        core.turns
                            .queue_accepted(&thread, &client_user_message_id, id)
                    }),
                Err(NativeMutationError::NotEnqueued(_) | NativeMutationError::Native(_)) => {
                    core.turns.queue_not_added(&thread, &client_user_message_id)
                }
                Err(NativeMutationError::OutcomeUnknown(_) | NativeMutationError::Storage(_)) => {
                    false
                }
            }
        };
        if changed && let Err(error) = self.commit_turn_state().await {
            warn!(%error, "failed to persist queued message outcome");
        }
        if outcome.is_ok() {
            self.device_tools.record_driver(client_id, &thread);
        }
        outcome.map_err(|error| queue_change_error(&thread, error))
    }

    async fn queue_start(&self, client_id: u64, params: Value) -> RpcResult {
        let thread = codex_thread(&params)?;
        let response = self
            .run_native_mutation("thread/queue/start", params, &thread)
            .await
            .map_err(|error| queue_change_error(&thread, error))?;
        if let Some(turn_id) = response.pointer("/turn/id").and_then(Value::as_str) {
            self.core.lock().await.turns.note_queue_started(
                &TurnKey::new(&thread, turn_id),
                client_id,
                unix_seconds(),
            );
            if let Err(error) = self.commit_turn_state().await {
                warn!(%error, "failed to persist started queued message");
            }
        }
        Ok(response)
    }

    async fn queue_delete(&self, params: Value) -> RpcResult {
        let thread = codex_thread(&params)?;
        let queued_submission_id = required_str(&params, "queuedSubmissionId")?.to_owned();
        let response = self
            .run_native_mutation("thread/queue/delete", params, &thread)
            .await
            .map_err(|error| queue_change_error(&thread, error))?;
        if response["deleted"] == true
            && self
                .core
                .lock()
                .await
                .turns
                .queue_deleted(&thread, &queued_submission_id)
            && let Err(error) = self.commit_turn_state().await
        {
            warn!(%error, "failed to persist deleted queued message");
        }
        Ok(response)
    }

    async fn native_queue_client_ids(&self, thread: &str) -> Result<HashSet<String>> {
        let mut client_ids = HashSet::new();
        let mut cursor: Option<String> = None;
        for _ in 0..MAX_QUEUE_LIST_PAGES {
            let mut params = json!({"threadId": thread, "limit": QUEUE_LIST_PAGE_SIZE});
            if let Some(cursor) = &cursor {
                params["cursor"] = json!(cursor);
            }
            let page = self.call_control("thread/queue/list", params).await?;
            for submission in page["data"]
                .as_array()
                .context("thread/queue/list returned no submissions")?
            {
                client_ids.insert(
                    submission["clientUserMessageId"]
                        .as_str()
                        .context("a queued submission has no clientUserMessageId")?
                        .to_owned(),
                );
            }
            match page["nextCursor"].as_str() {
                Some(next) => cursor = Some(next.to_owned()),
                None => return Ok(client_ids),
            }
        }
        bail!("thread/queue/list exceeded {MAX_QUEUE_LIST_PAGES} pages")
    }

    async fn settle_queue(&self, thread: &str, hold: bool) -> Result<()> {
        anyhow::ensure!(
            !self.native_mutations.contains(thread).await,
            "a queued message change is still unverified"
        );
        let listed_at = unix_seconds();
        let listed = self.native_queue_client_ids(thread).await?;
        let changed = self
            .core
            .lock()
            .await
            .turns
            .settle_queue(thread, &listed, listed_at, hold);
        if changed {
            self.commit_turn_state().await?;
        }
        Ok(())
    }

    pub(super) async fn settle_unstarted_queue(&self, thread: &str) {
        if let Err(error) = self.settle_queue(thread, true).await {
            warn!(thread_id = thread, error = %format!("{error:#}"), "queued messages could not be read; holding them");
            if self.core.lock().await.turns.hold_queue(thread)
                && let Err(error) = self.commit_turn_state().await
            {
                warn!(%error, "failed to persist held queued messages");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gateway::NativeMutationTransport;
    use crate::notifications::history::NotificationOrigin;
    use crate::test_support::{FakeControl, TestGateway};
    use crate::turns::PendingTurnStart;
    use tokio::sync::mpsc;

    const THREAD: &str = "e1741c43-3d9a-4448-9f4a-3c7e5906e852";

    async fn attach_native_transport(gateway: &Gateway) -> mpsc::Receiver<String> {
        let (sender, receiver) = mpsc::channel(4);
        *gateway.native_mutation_transport.lock().await = Some(NativeMutationTransport {
            pid: i32::try_from(std::process::id()).unwrap(),
            sender,
        });
        receiver
    }

    async fn answer(gateway: &Arc<Gateway>, request: &Value, mut reply: Value) {
        reply["id"] = request["id"].clone();
        gateway
            .handle_control_text(
                reply.to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
    }

    fn add(client_user_message_id: &str) -> Value {
        json!({
            "threadId": THREAD,
            "clientUserMessageId": client_user_message_id,
            "input": [{"type": "text", "text": "Run the tests"}],
        })
    }

    async fn queued(gateway: &Gateway) -> Vec<(String, Option<String>)> {
        gateway
            .core
            .lock()
            .await
            .turns
            .durable()
            .queued_submissions
            .get(THREAD)
            .map(|queue| {
                queue
                    .submissions
                    .iter()
                    .map(|submission| {
                        (
                            submission.client_user_message_id.clone(),
                            submission.queued_submission_id.clone(),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    fn submission(client_user_message_id: &str, owner_client_id: u64) -> QueuedSubmission {
        QueuedSubmission {
            client_user_message_id: client_user_message_id.to_owned(),
            queued_submission_id: Some(format!("native-{client_user_message_id}")),
            context: PromptContext {
                compaction: false,
                preview: "Queued work".to_owned(),
                cwd: Some("/repo".to_owned()),
                owner_client_id,
            },
            created_at_unix_seconds: 1.0,
        }
    }

    #[tokio::test]
    async fn queued_attribution_survives_restore_before_the_user_item() {
        let directory = tempfile::tempdir().unwrap();
        let gateway = TestGateway::with_native_runtime(directory.path());
        let key = TurnKey::new(THREAD, "queued");
        {
            let mut core = gateway.core.lock().await;
            core.turns.enqueue(THREAD, submission("q1", 12)).unwrap();
            core.turns.note_started(&key, 2.0);
        }
        gateway.commit_turn_state().await.unwrap();
        let restored = TestGateway::with_native_runtime(directory.path());
        restored.load_turn_state().await.unwrap();
        restored
            .capture_agent_message(&json!({
                "method": "item/started",
                "params": {"threadId": THREAD, "turnId": "queued", "item": {
                    "type": "userMessage", "id": "user-1", "clientId": "q1", "content": []
                }}
            }))
            .await;
        let core = restored.core.lock().await;
        assert_eq!(core.turns.active_turn(&key).unwrap().owner_client_id, 12);
        let context = core.turns.context(&key).unwrap();
        assert_eq!(context.prompt_preview, "Queued work");
        assert_eq!(context.cwd.as_deref(), Some("/repo"));
        assert!(!context.awaiting_attribution);
        assert!(core.turns.durable().queued_submissions.is_empty());
    }

    #[tokio::test]
    async fn send_now_attributes_the_leased_owner_and_keeps_an_unleased_starter() {
        for leased in [true, false] {
            let directory = tempfile::tempdir().unwrap();
            let gateway = TestGateway::with_native_runtime(directory.path());
            let mut native = attach_native_transport(&gateway).await;
            if leased {
                gateway
                    .core
                    .lock()
                    .await
                    .turns
                    .enqueue(THREAD, submission("q1", 12))
                    .unwrap();
            }
            let owner = gateway.clone();
            let start = tokio::spawn(async move {
                owner
                    .queue_start(
                        24,
                        json!({"threadId": THREAD, "queuedSubmissionId": "native-q1"}),
                    )
                    .await
            });
            let request: Value = serde_json::from_str(&native.recv().await.unwrap()).unwrap();
            answer(
                &gateway,
                &request,
                json!({"result":{"turn":{"id":"queued","status":"inProgress"}}}),
            )
            .await;
            start.await.unwrap().unwrap();
            gateway.capture_agent_message(&json!({
                "method": "turn/started", "params": {"threadId": THREAD, "turn": {"id": "queued", "status": "inProgress"}}
            })).await;
            gateway.capture_agent_message(&json!({
                "method": "item/started", "params": {"threadId": THREAD, "turnId": "queued", "item": {
                    "type": "userMessage", "id": "user-1", "clientId": "q1", "content": []
                }}
            })).await;
            let core = gateway.core.lock().await;
            assert_eq!(
                core.turns
                    .active_turn(&TurnKey::new(THREAD, "queued"))
                    .unwrap()
                    .owner_client_id,
                if leased { 12 } else { 24 }
            );
        }
    }

    #[tokio::test]
    async fn a_duplicate_interrupt_does_not_hold_a_started_successor() {
        let gateway = TestGateway::new();
        gateway
            .core
            .lock()
            .await
            .turns
            .enqueue(THREAD, submission("q1", 12))
            .unwrap();
        let interrupted = json!({"method": "turn/completed", "params": {
            "threadId": THREAD, "turn": {"id": "first", "status": "interrupted"}
        }});
        gateway.capture_agent_message(&interrupted).await;
        assert!(
            !gateway
                .core
                .lock()
                .await
                .turns
                .awaits_queued_successor(THREAD)
        );
        gateway
            .capture_agent_message(&json!({"method": "turn/started", "params": {
                "threadId": THREAD, "turn": {"id": "successor", "status": "inProgress"}
            }}))
            .await;
        gateway.capture_agent_message(&interrupted).await;
        assert!(
            gateway
                .core
                .lock()
                .await
                .turns
                .awaits_queued_successor(THREAD)
        );
        assert!(
            gateway
                .core
                .lock()
                .await
                .turns
                .is_active(&TurnKey::new(THREAD, "successor"))
        );
    }

    #[tokio::test]
    async fn settlement_keeps_an_add_before_its_native_marker_and_releases_after_refusal() {
        let directory = tempfile::tempdir().unwrap();
        let gateway = TestGateway::with_native_runtime(directory.path());
        let mut native = attach_native_transport(&gateway).await;
        let transport_guard = gateway.native_mutation_transport.lock().await;
        let owner = gateway.clone();
        let adding =
            tokio::spawn(async move { owner.queue_rpc(12, "thread/queue/add", add("q1")).await });
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while queued(&gateway).await.is_empty() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        gateway.commit_turn_state().await.unwrap();
        assert!(!gateway.native_mutations.contains(THREAD).await);
        let mut control = FakeControl::attach(&gateway, 2).await.requests;
        let owner = gateway.clone();
        let responder = tokio::spawn(async move {
            let request: Value = serde_json::from_str(&control.recv().await.unwrap()).unwrap();
            assert_eq!(request["method"], "thread/queue/list");
            answer(
                &owner,
                &request,
                json!({"result":{"data":[],"nextCursor":null}}),
            )
            .await;
        });
        gateway.settle_queue(THREAD, false).await.unwrap();
        responder.await.unwrap();
        assert_eq!(queued(&gateway).await.len(), 1);
        drop(transport_guard);
        let request: Value = serde_json::from_str(&native.recv().await.unwrap()).unwrap();
        answer(
            &gateway,
            &request,
            json!({"error":{"code":-32600,"message":"queue is full"}}),
        )
        .await;
        assert_eq!(adding.await.unwrap().unwrap_err().message, "queue is full");
        assert!(queued(&gateway).await.is_empty());
    }

    #[tokio::test]
    async fn an_add_is_durable_before_codex_sees_it_and_settles_by_its_outcome() {
        let directory = tempfile::tempdir().unwrap();
        let gateway = TestGateway::with_native_runtime(directory.path());
        let mut native = attach_native_transport(&gateway).await;
        let (client_tx, _client_rx) = mpsc::channel(1);
        gateway.clients.insert(
            12,
            crate::gateway::ClientTx {
                content_subscriptions: Arc::default(),
                query_response: None,
                installation_id: None,
                id: 12,
                tx: client_tx,
                closed: tokio_util::sync::CancellationToken::new(),
            },
        );

        let owner = Arc::clone(&gateway);
        let accepted =
            tokio::spawn(async move { owner.queue_rpc(12, "thread/queue/add", add("q1")).await });
        let request: Value = serde_json::from_str(&native.recv().await.unwrap()).unwrap();
        assert_eq!(request["method"], "thread/queue/add");
        assert_eq!(request["params"]["clientUserMessageId"], "q1");
        let restored = TestGateway::with_native_runtime(directory.path());
        restored.load_turn_state().await.unwrap();
        assert_eq!(queued(&restored).await, [("q1".to_owned(), None)]);
        answer(
            &gateway,
            &request,
            json!({"result":{"queuedSubmission":{"id":"native-1","input":[],"clientUserMessageId":"q1"}}}),
        )
        .await;
        accepted.await.unwrap().unwrap();
        assert_eq!(
            queued(&gateway).await,
            [("q1".to_owned(), Some("native-1".to_owned()))]
        );

        let owner = Arc::clone(&gateway);
        let refused =
            tokio::spawn(async move { owner.queue_rpc(12, "thread/queue/add", add("q2")).await });
        let request: Value = serde_json::from_str(&native.recv().await.unwrap()).unwrap();
        answer(
            &gateway,
            &request,
            json!({"error":{"code":-32600,"message":"queue is full"}}),
        )
        .await;
        let error = refused.await.unwrap().unwrap_err();
        assert_eq!(
            (error.code, error.message.as_str()),
            (RpcCode::InvalidRequest, "queue is full")
        );
        assert_eq!(
            queued(&gateway).await,
            [("q1".to_owned(), Some("native-1".to_owned()))]
        );

        let owner = Arc::clone(&gateway);
        let uncertain =
            tokio::spawn(async move { owner.queue_rpc(12, "thread/queue/add", add("q3")).await });
        let _: Value = serde_json::from_str(&native.recv().await.unwrap()).unwrap();
        gateway.control_requests.lock().unwrap().clear();
        let error = uncertain.await.unwrap().unwrap_err();
        assert_eq!(
            (error.code, error.kind()),
            (RpcCode::Unavailable, Some("queueChangeUncertain"))
        );
        assert_eq!(
            queued(&gateway).await,
            [
                ("q1".to_owned(), Some("native-1".to_owned())),
                ("q3".to_owned(), None)
            ]
        );
        assert!(matches!(
            native.try_recv(),
            Err(mpsc::error::TryRecvError::Empty)
        ));
    }

    #[tokio::test]
    async fn a_queue_started_turn_never_takes_another_clients_pending_start() {
        let gateway = TestGateway::new();
        let turn_start = |thread: &str, id: u64, client_user_message_id: &str| {
            json!({"id": id, "method": "turn/start", "params": {
                "threadId": thread,
                "clientUserMessageId": client_user_message_id,
                "input": [{"type": "text", "text": "Steer this"}],
            }})
            .as_object()
            .unwrap()
            .clone()
        };
        gateway
            .capture_client_request_locked(3, &turn_start(THREAD, 5, "p1"))
            .await
            .unwrap();
        gateway
            .core
            .lock()
            .await
            .turns
            .enqueue(THREAD, submission("q1", 2))
            .unwrap();
        let notify = |method: &str, params: Value| json!({"method": method, "params": params});
        gateway
            .capture_agent_message(&notify(
                "turn/started",
                json!({"threadId": THREAD, "turn": {"id": "queued", "status": "inProgress"}}),
            ))
            .await;
        gateway
            .capture_agent_message(&notify(
                "item/started",
                json!({"threadId": THREAD, "turnId": "queued", "item": {
                    "type": "userMessage", "id": "item-1", "clientId": "q1", "content": []
                }}),
            ))
            .await;
        {
            let core = gateway.core.lock().await;
            let key = TurnKey::new(THREAD, "queued");
            assert_eq!(
                core.turns.context(&key).unwrap().prompt_preview,
                "Queued work"
            );
            assert_eq!(core.turns.active_turn(&key).unwrap().owner_client_id, 2);
            assert!(core.turns.durable().queued_submissions.is_empty());
            assert_eq!(
                core.turns
                    .pending_start("3:5")
                    .and_then(|pending: &PendingTurnStart| pending
                        .client_user_message_id
                        .as_deref()),
                Some("p1")
            );
        }

        let other = "43dd6ac0-a78e-4e3b-a889-b3ca18b91603";
        gateway
            .capture_client_request_locked(3, &turn_start(other, 6, "p2"))
            .await
            .unwrap();
        gateway
            .capture_agent_message(&notify(
                "turn/started",
                json!({"threadId": other, "turn": {"id": "external", "status": "inProgress"}}),
            ))
            .await;
        let external = TurnKey::new(other, "external");
        assert_eq!(
            gateway
                .core
                .lock()
                .await
                .turns
                .context(&external)
                .unwrap()
                .prompt_preview,
            "Codex task"
        );
        gateway
            .capture_agent_message(&notify(
                "item/completed",
                json!({"threadId": other, "turnId": "external", "item": {
                    "type": "userMessage", "id": "item-2", "clientId": "p2", "content": []
                }}),
            ))
            .await;
        let core = gateway.core.lock().await;
        assert_eq!(
            core.turns.context(&external).unwrap().prompt_preview,
            "Steer this"
        );
        assert_eq!(
            core.turns.active_turn(&external).unwrap().owner_client_id,
            3
        );
        assert!(core.turns.pending_start("3:6").is_none());
        assert!(core.turns.pending_start("3:5").is_some());
    }

    #[tokio::test]
    async fn queued_messages_are_retained_until_codex_lists_none() {
        for (reply, kept) in [
            (
                json!({"result":{"data":[{"id":"native-q1","input":[],"clientUserMessageId":"q1"}],"nextCursor":null}}),
                true,
            ),
            (
                json!({"error":{"code":-32603,"message":"queue store unavailable"}}),
                true,
            ),
            (json!({"result":{"data":[],"nextCursor":null}}), false),
        ] {
            let gateway = TestGateway::new();
            gateway.core.lock().await.app_server_inventory_bootstrapped = true;
            gateway
                .core
                .lock()
                .await
                .turns
                .enqueue(THREAD, submission("q1", 2))
                .unwrap();
            let mut control = FakeControl::attach(&gateway, 2).await.requests;
            let owner = gateway.clone();
            let failed = reply.get("error").is_some();
            let responder = tokio::spawn(async move {
                let request: Value = serde_json::from_str(&control.recv().await.unwrap()).unwrap();
                assert_eq!(request["method"], "thread/queue/list");
                assert_eq!(request["params"]["threadId"], THREAD);
                answer(&owner, &request, reply).await;
            });
            assert_eq!(gateway.settle_queue(THREAD, false).await.is_err(), failed);
            responder.await.unwrap();
            assert_eq!(!queued(&gateway).await.is_empty(), kept);
        }
    }

    #[tokio::test]
    async fn queue_sends_wait_for_a_starting_compaction_and_removal_does_not() {
        let gateway = TestGateway::new();
        *gateway.control_init_result.lock().await = Some(json!({}));
        gateway
            .capture_client_request_locked(
                4,
                json!({"id": 9, "method": "thread/compact/start", "params": {"threadId": THREAD}})
                    .as_object()
                    .unwrap(),
            )
            .await
            .unwrap();
        let request = |method: &str| {
            json!({"params": {"threadId": THREAD, "queuedSubmissionId": "native-q1"}, "method": method})
                .as_object()
                .unwrap()
                .clone()
        };
        for method in ["thread/queue/add", "thread/queue/start"] {
            let error = gateway
                .validate_dispatch(method, &request(method))
                .await
                .err()
                .unwrap();
            assert_eq!(error.code, RpcCode::Conflict, "{method}");
        }
        assert!(
            gateway
                .validate_dispatch("thread/queue/delete", &request("thread/queue/delete"))
                .await
                .is_ok()
        );
    }

    #[test]
    fn interrupted_queues_hold_and_settling_keeps_newer_submissions() {
        let mut ledger = crate::turns::TurnLedger::default();
        ledger.enqueue(THREAD, submission("listed", 1)).unwrap();
        ledger.enqueue(THREAD, submission("gone", 1)).unwrap();
        let mut newer = submission("newer", 1);
        newer.created_at_unix_seconds = 10.0;
        ledger.enqueue(THREAD, newer).unwrap();

        assert!(ledger.settle_queue(THREAD, &HashSet::from(["listed".to_owned()]), 5.0, true));
        assert!(!ledger.awaits_queued_successor(THREAD));
        let kept = ledger.durable().queued_submissions[THREAD]
            .submissions
            .iter()
            .map(|submission| submission.client_user_message_id.clone())
            .collect::<Vec<_>>();
        assert_eq!(kept, ["listed", "newer"]);

        ledger.note_started(&TurnKey::new(THREAD, "next"), 11.0);
        assert!(ledger.awaits_queued_successor(THREAD));

        let mut full = crate::turns::TurnLedger::default();
        for index in 0..crate::turns::MAX_QUEUED_SUBMISSIONS_PER_THREAD {
            full.enqueue(THREAD, submission(&format!("q{index}"), 1))
                .unwrap();
        }
        assert_eq!(
            full.enqueue(THREAD, submission("overflow", 1)),
            Err(crate::turns::QueueRefusal::ThreadFull)
        );
        let durable = full.durable().queued_submissions;
        assert!(crate::turns::TurnLedger::queues_are_bounded(&durable));
        let restored = crate::turns::TurnLedger::restore(crate::turns::DurableTurns {
            queued_submissions: durable,
            ..Default::default()
        });
        assert_eq!(
            restored.durable().queued_submissions[THREAD]
                .submissions
                .len(),
            crate::turns::MAX_QUEUED_SUBMISSIONS_PER_THREAD
        );
    }
}
