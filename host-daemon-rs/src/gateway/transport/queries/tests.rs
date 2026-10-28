use super::*;
use crate::gateway::{ClientCommand, ClientRequests};
use crate::rpc::dispatch::DispatchPlan;
use crate::test_support::TestGateway;
use futures_util::FutureExt;
use tokio::sync::mpsc;

struct Connection {
    gateway: TestGateway,
    requests: ClientRequests,
    queries: ConnectionQueries,
    responses: mpsc::Receiver<ClientCommand>,
    upstream: mpsc::Receiver<crate::gateway::UpstreamFrame>,
    _voice: mpsc::Receiver<crate::gateway::VoiceRequest>,
    admitted: Vec<Value>,
}

impl Connection {
    fn new() -> Self {
        let gateway = TestGateway::new();
        let (tx, responses) = mpsc::channel(128);
        let out_tx = crate::gateway::tests::test_client(1, tx);
        let (lane_tx, upstream) = mpsc::channel(8);
        let (voice_tx, voice) = mpsc::channel(8);
        let queries = ConnectionQueries::new(Arc::clone(&gateway), out_tx.clone(), Arc::default());
        Self {
            gateway,
            requests: ClientRequests {
                out_tx,
                lane_tx,
                voice_tx,
                queries: Arc::clone(&queries.tasks),
            },
            queries,
            responses,
            upstream,
            _voice: voice,
            admitted: Vec::new(),
        }
    }

    async fn send(&mut self, message: Value) {
        let raw = message.to_string();
        let DispatchPlan::Request(request) = DispatchPlan::parse(&raw) else {
            panic!("valid request");
        };
        self.gateway
            .route_request(
                1,
                request,
                raw,
                &self.requests,
                &mut self.queries,
                Instant::now(),
            )
            .await
            .unwrap();
    }

    async fn query(&mut self, id: impl Into<Value>) {
        self.send(json!({"id": id.into(), "method": "daemon/replayNotifications", "params": {}}))
            .await;
    }

    async fn cancel(&mut self, id: impl Into<Value>) {
        self.send(json!({"jsonrpc":"2.0", "method":"$/cancelRequest", "params":{"id":id.into()}}))
            .await;
    }

    async fn event(&mut self, event: QueryEvent) {
        match event {
            QueryEvent::Admitted => self
                .admitted
                .push(self.queries.running.last().unwrap().info.id.clone()),
            QueryEvent::Finished(result) => result.unwrap(),
            QueryEvent::Expired(info) => self
                .gateway
                .send_error_to(
                    &self.requests.out_tx,
                    Some(&info.id),
                    &RpcError::request_timed_out(QUERY_DEADLINE),
                )
                .await
                .unwrap(),
        }
    }

    async fn drive_ready(&mut self) {
        while let Some(event) = self.queries.next().now_or_never() {
            self.event(event).await;
        }
    }

    async fn drain(&mut self) {
        while !self.queries.queued.is_empty() || !self.queries.running.is_empty() {
            let event = self.queries.next().await;
            self.event(event).await;
        }
    }

    async fn response(&mut self) -> Value {
        let ClientCommand::Text(text) = self.responses.recv().await.expect("response") else {
            panic!("text response");
        };
        serde_json::from_str(&text).unwrap()
    }
}

#[tokio::test]
async fn burst_beyond_eight_waits_and_finishes_in_fifo_order() {
    let mut connection = Connection::new();
    let gateway = Arc::clone(&connection.gateway);
    let core = gateway.core.lock().await;
    for id in 1..=20 {
        connection.query(id).await;
    }
    connection.drive_ready().await;
    assert_eq!(connection.queries.running.len(), 8);
    assert_eq!(connection.queries.queue_depth(), 12);
    assert!(connection.responses.try_recv().is_err());
    drop(core);
    connection.drain().await;
    assert_eq!(
        connection.admitted,
        (1..=20).map(Value::from).collect::<Vec<_>>()
    );
    let mut ids = Vec::new();
    for _ in 1..=20 {
        let response = connection.response().await;
        ids.push(response["id"].as_i64().unwrap());
        assert!(response.get("result").is_some(), "{response}");
    }
    ids.sort();
    assert_eq!(ids, (1..=20).collect::<Vec<_>>());
    assert!(connection.responses.try_recv().is_err());
}

#[tokio::test]
async fn full_queue_refuses_only_excess_requests_and_names_the_resource() {
    let mut connection = Connection::new();
    for id in 1..=65 {
        connection.query(id).await;
    }
    let response = connection.response().await;
    assert_eq!(response["id"], 65);
    assert_eq!(response["error"]["code"], -32001);
    assert_eq!(
        response["error"]["data"],
        json!({
            "kind":"capacity", "retryable":true, "resource":"connection query queue",
        })
    );
    assert_eq!(connection.queries.queue_depth(), 64);
    connection.cancel(32).await;
    assert_eq!(connection.response().await["error"]["code"], -32800);
    connection.query(66).await;
    connection.drain().await;
    let mut ids = Vec::new();
    for _ in 0..64 {
        let response = connection.response().await;
        ids.push(response["id"].as_i64().unwrap());
        assert!(response.get("result").is_some());
    }
    ids.sort();
    assert_eq!(
        ids,
        (1..=64)
            .filter(|id| *id != 32)
            .chain([66])
            .collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn queue_bytes_are_bounded_and_cancellation_reclaims_them() {
    let mut connection = Connection::new();
    connection
        .send(
            json!({"id":1,"method":"daemon/replayNotifications", "params":{
                "padding":"x".repeat(QUERY_BYTES / 2),
            }}),
        )
        .await;
    connection
        .send(
            json!({"id":2,"method":"daemon/replayNotifications", "params":{
                "padding":"x".repeat(QUERY_BYTES / 2),
            }}),
        )
        .await;
    assert_eq!(
        connection.response().await["error"]["data"]["resource"],
        "connection query queue bytes"
    );
    connection.cancel(1).await;
    assert_eq!(connection.response().await["error"]["code"], -32800);
    assert_eq!(connection.queries.queued_bytes, 0);
    connection.query(3).await;
    connection.drain().await;
    assert_eq!(connection.response().await["id"], 3);
}

#[tokio::test]
async fn oversized_query_is_nonretryable_without_occupying_the_queue() {
    let mut connection = Connection::new();
    let message = json!({"id":1,"method":"daemon/replayNotifications","params":{
        "padding":"x".repeat(QUERY_BYTES),
    }});
    let bytes = message.to_string().len();
    connection.send(message).await;
    let response = connection.response().await;
    assert_eq!(response["id"], 1);
    assert_eq!(response["error"]["code"], -32001);
    assert_eq!(
        response["error"]["data"],
        json!({
            "kind":"capacity", "retryable":false, "resource":"connection query bytes",
            "actualBytes":bytes, "limit":QUERY_BYTES,
        })
    );
    assert_eq!(connection.queries.queue_depth(), 0);
    connection.query(2).await;
    connection.drain().await;
    assert!(connection.response().await.get("result").is_some());
}

#[tokio::test]
async fn connection_controls_bypass_full_read_admission_and_preserve_replacement_order() {
    let mut connection = Connection::new();
    let gateway = Arc::clone(&connection.gateway);
    let core = gateway.core.lock().await;
    for id in 1..=8 {
        connection.query(id).await;
    }
    connection.drive_ready().await;
    for id in 9..=72 {
        connection.query(id).await;
    }
    for (id, thread) in [(100, "claude_a"), (101, "claude_b")] {
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            connection.send(json!({"id":id,"method":"conversation/subscriptions/set",
            "params":{"threadIds":[thread]}})),
        )
        .await
        .expect("subscription replacement must not await stalled reads");
        assert_eq!(connection.response().await, json!({"id":id,"result":{}}));
    }
    gateway
        .clients
        .insert(1, connection.requests.out_tx.clone());
    for thread in ["claude_a", "claude_b"] {
        let message = json!({"method":"item/agentMessage/delta","params":{
            "threadId":thread,"delta":"text",
        }});
        gateway.broadcast_claude_content(
            &super::super::ClientFrame::encode(&message).unwrap(),
            &message,
        );
    }
    assert_eq!(
        connection.response().await["params"]["threadId"],
        "claude_b"
    );
    assert!(connection.responses.try_recv().is_err());
    for (id, method) in [(102, "host/info"), (103, "daemon/liveActivity")] {
        connection.send(json!({"id":id,"method":method})).await;
        let response =
            tokio::time::timeout(std::time::Duration::from_secs(5), connection.response())
                .await
                .expect("status response must not await stalled reads");
        assert_eq!(response["id"], id);
        assert!(response.get("result").is_some(), "{response}");
    }
    connection
        .send(json!({"id":104,"method":"daemon/activeTurns"}))
        .await;
    let permits: Vec<_> = (0..15)
        .map(|_| gateway.request_budgets.status.try_acquire(1).unwrap())
        .collect();
    assert!(gateway.request_budgets.status.try_acquire(1).is_none());
    assert_eq!(connection.queries.queue_depth(), 64);
    gateway.command_tasks.stop().await;
    connection.requests.queries.stop().await;
    drop((permits, core));
}

#[tokio::test]
async fn status_burst_preserves_stop_admission() {
    let mut connection = Connection::new();
    for id in 1..=16 {
        let method = if id % 2 == 0 {
            "host/info"
        } else {
            "daemon/liveActivity"
        };
        connection.send(json!({"id":id,"method":method})).await;
    }
    connection
        .send(json!({"id":100,"method":"turn/interrupt","params":{}}))
        .await;
    let mut responses = Vec::new();
    for _ in 0..17 {
        responses.push(connection.response().await);
    }
    let stop = responses
        .iter()
        .find(|response| response["id"] == 100)
        .unwrap();
    assert_eq!(stop["error"]["code"], -32602, "{stop}");
    assert_eq!(
        responses
            .iter()
            .filter(|response| response["id"] == 100)
            .count(),
        1
    );
    for response in responses.iter().filter(|response| response["id"] != 100) {
        assert!(response.get("result").is_some(), "{response}");
    }
}

#[tokio::test]
async fn failed_query_tasks_answer_internal_once_and_release_permits() {
    for response_committed in [false, true] {
        let mut connection = Connection::new();
        connection.query(1).await;
        connection.queries.queued.front_mut().unwrap().request.owned = None;
        assert!(matches!(
            connection.queries.next().await,
            QueryEvent::Admitted
        ));
        if response_committed {
            let out = ClientTx {
                grant: crate::auth::installation_credentials::Grant::Operator,
                query_response: Some(Arc::clone(&connection.queries.running[0].response)),
                ..connection.requests.out_tx.clone()
            };
            connection
                .gateway
                .send_json_awaiting_capacity(&out, &json!({"id":1,"result":{}}))
                .await
                .unwrap();
        }
        assert!(matches!(
            connection.queries.next().await,
            QueryEvent::Finished(Err(_))
        ));
        assert!(!connection.responses.is_empty());
        let response = connection.response().await;
        assert_eq!(response["id"], 1);
        if response_committed {
            assert_eq!(response, json!({"id":1,"result":{}}));
        } else {
            assert_eq!(response["error"]["code"], -32603);
        }
        connection.cancel(1).await;
        assert!(connection.responses.try_recv().is_err());
        let permits: Vec<_> = (0..32)
            .map(|_| {
                connection
                    .gateway
                    .request_budgets
                    .query
                    .try_acquire(1)
                    .unwrap()
            })
            .collect();
        assert_eq!(permits.len(), 32);
    }
}

#[tokio::test]
async fn cancellation_with_request_id_is_invalid_and_leaves_target_pending() {
    let mut connection = Connection::new();
    connection.query(1).await;
    for id in [json!(2), Value::Null] {
        connection
            .send(json!({"jsonrpc":"2.0","id":id,"method":"$/cancelRequest",
            "params":{"id":1}}))
            .await;
        assert!(!connection.responses.is_empty());
        let response = connection.response().await;
        assert_eq!(response["id"], id);
        assert_eq!(response["error"]["code"], -32600);
        assert_eq!(connection.queries.queue_depth(), 1);
    }
    connection.drain().await;
    let response = connection.response().await;
    assert_eq!(response["id"], 1);
    assert!(response.get("result").is_some());
    assert!(connection.upstream.try_recv().is_err());
}

#[tokio::test]
async fn queued_and_running_cancellations_release_permits_and_answer_once() {
    let mut connection = Connection::new();
    let gateway = Arc::clone(&connection.gateway);
    let core = gateway.core.lock().await;
    for id in 1..=20 {
        connection.query(id).await;
    }
    connection.drive_ready().await;
    let mut remaining = Vec::new();
    for _ in 0..24 {
        remaining.push(gateway.request_budgets.query.try_acquire(1).unwrap());
    }
    assert!(gateway.request_budgets.query.try_acquire(1).is_none());
    for id in [1, 12, 3] {
        connection.cancel(id).await;
        assert_eq!(
            connection.response().await,
            json!({
                "id":id, "error":{
                    "code":-32800, "message":"Request cancelled",
                    "data":{"kind":"requestCancelled", "retryable":false},
                },
            })
        );
        connection.cancel(id).await;
    }
    let first = gateway.request_budgets.query.acquire(1).await;
    let second = gateway.request_budgets.query.acquire(1).await;
    assert!(gateway.request_budgets.query.try_acquire(1).is_none());
    drop((first, second, remaining, core));
    connection.drain().await;
    let mut ids = Vec::new();
    for _ in 0..17 {
        let response = connection.response().await;
        ids.push(response["id"].as_i64().unwrap());
        assert!(response.get("result").is_some());
    }
    ids.sort();
    assert_eq!(
        ids,
        (1..=20)
            .filter(|id| ![1, 12, 3].contains(id))
            .collect::<Vec<_>>()
    );
    assert!(connection.responses.try_recv().is_err());
    assert!(connection.upstream.try_recv().is_err());
}

#[tokio::test]
async fn cancellation_is_exact_and_never_forwards_unknown_or_nonquery_ids() {
    let mut connection = Connection::new();
    connection.query(7).await;
    connection.query("7").await;
    connection.cancel(7).await;
    assert_eq!(connection.response().await["id"], 7);
    connection.cancel(json!({"invalid":true})).await;
    connection.cancel(99).await;
    connection.cancel(Value::Null).await;
    connection
        .send(json!({"id": 10,"method":"config/read","params":{}}))
        .await;
    assert!(connection.upstream.try_recv().is_ok());
    connection.cancel(10).await;
    connection.drain().await;
    let response = connection.response().await;
    assert_eq!(response["id"], "7");
    assert!(response.get("result").is_some());
    connection.cancel("7").await;
    assert!(connection.responses.try_recv().is_err());
    assert!(connection.upstream.try_recv().is_err());
}

#[tokio::test]
async fn response_already_enqueued_wins_over_cancellation_and_deadline() {
    let mut connection = Connection::new();
    connection.query(1).await;
    assert!(matches!(
        connection.queries.next().await,
        QueryEvent::Admitted
    ));
    let running = &connection.queries.running[0];
    let out = ClientTx {
        grant: crate::auth::installation_credentials::Grant::Operator,
        query_response: Some(Arc::clone(&running.response)),
        ..connection.requests.out_tx.clone()
    };
    connection
        .gateway
        .send_json_awaiting_capacity(&out, &json!({"id":1,"result":{}}))
        .await
        .unwrap();
    connection.cancel(1).await;
    connection.drain().await;
    assert_eq!(connection.response().await, json!({"id":1,"result":{}}));
    assert!(connection.responses.try_recv().is_err());
}

#[tokio::test(start_paused = true)]
async fn deadline_counts_host_queue_wait_and_remaining_handler_time() {
    let mut connection = Connection::new();
    let gateway = Arc::clone(&connection.gateway);
    let core = gateway.core.lock().await;
    let permits: Vec<_> = (0..32)
        .map(|_| gateway.request_budgets.query.try_acquire(1).unwrap())
        .collect();
    connection.query(1).await;
    connection.drive_ready().await;
    tokio::time::advance(std::time::Duration::from_secs(40)).await;
    drop(permits);
    connection.drive_ready().await;
    assert_eq!(connection.queries.running.len(), 1);
    connection.query(2).await;
    connection.drive_ready().await;
    tokio::time::advance(std::time::Duration::from_secs(20)).await;
    connection.drive_ready().await;
    let response = connection.response().await;
    assert_eq!(response["id"], 1);
    assert_eq!(response["error"]["data"]["kind"], "requestTimedOut");
    assert_eq!(response["error"]["data"]["limitMs"], 60000);
    assert!(connection.responses.try_recv().is_err());
    drop(core);
    connection.drain().await;
    assert_eq!(connection.response().await["id"], 2);
}

#[tokio::test(start_paused = true)]
async fn queued_deadline_expires_without_starting_the_handler() {
    let mut connection = Connection::new();
    let gateway = Arc::clone(&connection.gateway);
    let permits: Vec<_> = (0..32)
        .map(|_| gateway.request_budgets.query.try_acquire(1).unwrap())
        .collect();
    connection.query(1).await;
    connection.drive_ready().await;
    tokio::time::advance(QUERY_DEADLINE).await;
    connection.drive_ready().await;
    let response = connection.response().await;
    assert_eq!(response["id"], 1);
    assert_eq!(response["error"]["data"]["kind"], "requestTimedOut");
    drop(permits);
    connection.query(2).await;
    connection.drain().await;
    assert_eq!(connection.response().await["id"], 2);
    assert!(connection.responses.try_recv().is_err());
}

#[tokio::test(start_paused = true)]
async fn an_elapsed_deadline_wins_even_if_the_handler_is_immediately_ready() {
    let mut connection = Connection::new();
    connection.query(1).await;
    assert!(matches!(
        connection.queries.next().await,
        QueryEvent::Admitted
    ));
    tokio::time::advance(QUERY_DEADLINE).await;
    connection.drain().await;
    let response = connection.response().await;
    assert_eq!(response["id"], 1);
    assert_eq!(response["error"]["data"]["kind"], "requestTimedOut");
    assert!(connection.responses.try_recv().is_err());
}

#[tokio::test]
async fn cancelling_the_head_releases_pending_admission_and_preserves_fifo() {
    let mut connection = Connection::new();
    let gateway = Arc::clone(&connection.gateway);
    let mut permits: Vec<_> = (0..32)
        .map(|_| gateway.request_budgets.query.try_acquire(1).unwrap())
        .collect();
    for id in 1..=3 {
        connection.query(id).await;
    }
    connection.drive_ready().await;
    connection.cancel(1).await;
    assert_eq!(connection.response().await["error"]["code"], -32800);
    drop(permits.pop());
    connection.drain().await;
    for id in 2..=3 {
        let response = connection.response().await;
        assert_eq!(response["id"], id);
        assert!(response.get("result").is_some());
    }
}

#[tokio::test]
async fn disconnect_drops_running_queries_and_pending_admission() {
    let mut connection = Connection::new();
    let gateway = Arc::clone(&connection.gateway);
    let core = gateway.core.lock().await;
    for id in 1..=20 {
        connection.query(id).await;
    }
    connection.drive_ready().await;
    let tasks = Arc::clone(&connection.queries.tasks);
    drop(connection);
    tasks.stop().await;
    let permits: Vec<_> = (0..32)
        .map(|_| gateway.request_budgets.query.try_acquire(1).unwrap())
        .collect();
    assert!(gateway.request_budgets.query.try_acquire(1).is_none());
    drop(core);
    let mut connection = ConnectionQueries::new(
        Arc::clone(&gateway),
        crate::gateway::tests::test_client(2, mpsc::channel(1).0),
        Arc::default(),
    );
    let DispatchPlan::Request(request) =
        DispatchPlan::parse(r#"{"id":1,"method":"daemon/replayNotifications"}"#)
    else {
        panic!("request");
    };
    connection
        .enqueue(request, 50, None, Instant::now())
        .unwrap();
    assert!(connection.next().now_or_never().is_none());
    let local = Arc::clone(&connection.local);
    drop(connection);
    assert!(local.try_acquire_many(QUERY_BYTES as u32).is_ok());
    drop(permits);
    for _ in 0..32 {
        assert!(gateway.request_budgets.query.try_acquire(1).is_some());
    }
}
