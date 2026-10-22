#[cfg(test)]
use super::ClientCommand;
use super::Gateway;
use super::transport::ClientFrame;
use crate::observability::journal::Source;
use crate::providers::claude::session_uuid_from_thread_id;
use crate::rpc::error::{RpcCode, RpcData};
use crate::rpc::{RpcError, RpcResult};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::Mutex;

const MAX_SUBSCRIPTIONS: usize = 64;
pub(super) const MAX_CLAUDE_THREAD_ID_BYTES: usize = 512;

#[derive(Debug, Default)]
pub(super) struct ContentSubscriptions {
    threads: Mutex<Option<HashSet<String>>>,
}

enum Audience<'a> {
    Global,
    Thread(&'a str),
    Invalid(&'static str),
}

impl ContentSubscriptions {
    pub(super) fn replace(&self, params: Value) -> RpcResult {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Set {
            thread_ids: Vec<String>,
        }
        let set: Set = serde_json::from_value(params)
            .map_err(|_| RpcError::new(RpcCode::InvalidParams, "threadIds is required"))?;
        if set.thread_ids.len() > MAX_SUBSCRIPTIONS {
            return Err(RpcError::new(
                RpcCode::Capacity,
                format!("At most {MAX_SUBSCRIPTIONS} Claude conversations may be subscribed"),
            )
            .with_data(RpcData::SubscriptionCapacity {
                limit: MAX_SUBSCRIPTIONS,
            }));
        }
        let mut threads = HashSet::with_capacity(set.thread_ids.len());
        for thread in set.thread_ids {
            if thread.len() > MAX_CLAUDE_THREAD_ID_BYTES
                || session_uuid_from_thread_id(&thread).is_none()
                || !threads.insert(thread)
            {
                return Err(RpcError::new(
                    RpcCode::InvalidParams,
                    "threadIds must contain distinct Claude thread IDs of at most 512 bytes",
                ));
            }
        }
        *self.threads.lock().expect("content subscriptions poisoned") = Some(threads);
        Ok(json!({}))
    }

    fn deliver(&self, audience: &Audience<'_>, send: impl FnOnce()) -> bool {
        let threads = self.threads.lock().expect("content subscriptions poisoned");
        let allowed = match (threads.as_ref(), audience) {
            (_, Audience::Invalid(_)) => false,
            (None, _) | (_, Audience::Global) => true,
            (Some(threads), Audience::Thread(thread)) => threads.contains(*thread),
        };
        if allowed {
            send();
        }
        allowed
    }
}

fn audience(message: &Value) -> Audience<'_> {
    let method = message["method"].as_str().unwrap_or_default();
    if matches!(
        method,
        "turn/started"
            | "turn/completed"
            | "thread/started"
            | "thread/closed"
            | "thread/deleted"
            | "thread/archived"
            | "thread/unarchived"
            | "thread/status/changed"
            | "thread/name/updated"
            | "thread/settings/updated"
            | "thread/history/invalidated"
            | "thread/compacted"
            | "conversation/questions/changed"
            | "conversation/marks/changed"
            | "directory/favorites/changed"
            | "preferences/changed"
            | "daemon/activeTurnsChanged"
            | "daemon/ready"
            | "account/updated"
            | "account/rateLimits/updated"
            | "host/state/changed"
    ) {
        return Audience::Global;
    }
    let thread = message.pointer("/params/threadId").and_then(Value::as_str);
    if method == "gateway/warning" && thread.is_none() {
        return Audience::Global;
    }
    if method.starts_with("item/")
        || matches!(
            method,
            "turn/plan/updated"
                | "turn/diff/updated"
                | "thread/tokenUsage/updated"
                | "error"
                | "daemon/claudeStderr"
                | "gateway/warning"
        )
    {
        return thread
            .filter(|thread| !thread.is_empty())
            .map_or(Audience::Invalid("missingThreadId"), Audience::Thread);
    }
    Audience::Invalid("unsupportedMethod")
}

impl Gateway {
    pub(super) fn broadcast_claude_content(&self, frame: &ClientFrame, message: &Value) {
        let audience = audience(message);
        if let Audience::Invalid(reason) = &audience {
            self.journal.push(
                "providerNotificationRoutingRejected",
                json!({
                    "method":message["method"], "reason":reason
                }),
            );
        }
        let mut recipients = Vec::new();
        for client in self.snapshot_clients() {
            if client.content_subscriptions.deliver(&audience, || {
                let _ = self.deliver_or_drop(&client, frame.clone().into_command());
            }) {
                recipients.push(client);
            }
        }
        if let Some(payload) = frame.text() {
            self.journal_broadcast(payload, Source::Claude, &recipients);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gateway::ClientTx;
    use crate::gateway::tests::test_client;
    use crate::test_support::TestGateway;
    use std::time::Duration;
    use tokio::sync::mpsc;

    fn client(
        gateway: &Gateway,
        id: u64,
        threads: Option<&[&str]>,
    ) -> (ClientTx, mpsc::Receiver<ClientCommand>) {
        let (tx, rx) = mpsc::channel(32);
        let client = test_client(id, tx);
        if let Some(threads) = threads {
            client
                .content_subscriptions
                .replace(json!({"threadIds":threads}))
                .unwrap();
        }
        gateway.clients.insert(id, client.clone());
        (client, rx)
    }

    fn receive(rx: &mut mpsc::Receiver<ClientCommand>) -> Value {
        let ClientCommand::Text(text) = rx.try_recv().unwrap() else {
            panic!("expected notification")
        };
        serde_json::from_str(&text).unwrap()
    }

    #[tokio::test]
    async fn content_routing_subscription_replace_validates_atomically_and_empty_opts_in() {
        let gateway = TestGateway::new();
        let (client, mut rx) = client(&gateway, 1, None);
        async fn submit(gateway: &std::sync::Arc<Gateway>, client: &ClientTx, params: Value) {
            gateway
                .handle_owned_rpc(
                    client.id,
                    client,
                    "conversation/subscriptions/set",
                    crate::rpc::dispatch::OwnedTarget::Gateway(
                        crate::rpc::dispatch::OwnedRoute::Subscriptions,
                    ),
                    json!({"id":1,"params":params}).as_object().unwrap(),
                )
                .await
                .unwrap();
        }
        submit(&gateway, &client, json!({"threadIds":["claude_a"]})).await;
        assert_eq!(receive(&mut rx)["result"], json!({}));
        for (index, params) in [
            json!({"threadIds":vec!["claude_b";65]}),
            json!({"threadIds":["claude_b","claude_b"]}),
            json!({"threadIds":["native"]}),
            json!({"threadIds":[format!("claude_{}","x".repeat(512))]}),
        ]
        .into_iter()
        .enumerate()
        {
            submit(&gateway, &client, params).await;
            let response = receive(&mut rx);
            assert!(response.get("error").is_some());
            if index == 0 {
                assert_eq!(response["error"]["code"], -32001);
                assert_eq!(response["error"]["data"]["limit"], 64);
                assert_eq!(response["error"]["data"]["retryable"], false);
            }
            let subscribed = client.content_subscriptions.threads.lock().unwrap();
            assert_eq!(
                subscribed.as_ref().unwrap(),
                &HashSet::from(["claude_a".to_owned()])
            );
        }
        submit(&gateway, &client, json!({"threadIds":[]})).await;
        assert_eq!(receive(&mut rx)["result"], json!({}));
        gateway.ingest_agent_notification(json!({"method":"item/agentMessage/delta","params":{"threadId":"claude_a","delta":"private"}})).await;
        assert!(rx.try_recv().is_err());
        assert!(gateway.clients.contains_key(&client.id));
    }

    #[tokio::test]
    async fn content_routing_filters_transcript_and_keeps_legacy_and_lifecycle_delivery() {
        let gateway = TestGateway::new();
        let (_, mut a) = client(&gateway, 1, Some(&["claude_a"]));
        let (_, mut b) = client(&gateway, 2, Some(&["claude_b"]));
        let (_, mut empty) = client(&gateway, 3, Some(&[]));
        let (_, mut legacy) = client(&gateway, 4, None);
        for method in [
            "item/agentMessage/delta",
            "turn/plan/updated",
            "thread/tokenUsage/updated",
            "error",
            "daemon/claudeStderr",
        ] {
            let floor = gateway.notification_floor().await;
            gateway.ingest_agent_notification(json!({"method":method,"params":{"threadId":"claude_a","turnId":"turn-a","delta":"private"}})).await;
            if method == "turn/plan/updated" {
                assert_eq!(gateway.notification_floor().await, floor + 1);
            }
            assert_eq!(receive(&mut a)["method"], method);
            assert_eq!(receive(&mut legacy)["method"], method);
            assert!(b.try_recv().is_err() && empty.try_recv().is_err());
        }
        gateway.ingest_agent_notification(json!({"method":"item/agentMessage/delta","params":{"threadId":"claude_b","delta":"other"}})).await;
        assert_eq!(receive(&mut b)["params"]["delta"], "other");
        assert_eq!(receive(&mut legacy)["params"]["delta"], "other");
        assert!(a.try_recv().is_err() && empty.try_recv().is_err());
        for method in ["turn/started", "turn/completed", "thread/name/updated"] {
            gateway.ingest_agent_notification(json!({"method":method,"params":{"threadId":"claude_a","turn":{"id":"turn-a","status":"interrupted"}}})).await;
            for rx in [&mut a, &mut b, &mut empty, &mut legacy] {
                assert_eq!(receive(rx)["method"], method);
            }
        }
        for message in [
            json!({"method":"provider/futureContent","params":{"threadId":"claude_a"}}),
            json!({"method":"item/agentMessage/delta","params":{"delta":"unscoped"}}),
        ] {
            gateway.ingest_agent_notification(message.clone()).await;
            assert!(
                a.try_recv().is_err()
                    && b.try_recv().is_err()
                    && empty.try_recv().is_err()
                    && legacy.try_recv().is_err()
            );
        }
    }

    #[tokio::test]
    async fn content_routing_real_stderr_producer_reaches_only_its_subscriber_and_legacy() {
        let gateway = TestGateway::new();
        let (_, mut subscribed) = client(&gateway, 1, Some(&["claude_a"]));
        let (_, mut unrelated) = client(&gateway, 2, Some(&["claude_b"]));
        let (_, mut legacy) = client(&gateway, 3, None);
        let frame = crate::providers::claude::runtime_stderr_frame("claude_a").await;
        assert_eq!(frame["method"], "daemon/claudeStderr");
        assert_eq!(frame["params"]["line"], "provider diagnostic");
        gateway.ingest_agent_notification(frame).await;
        assert_eq!(receive(&mut subscribed)["params"]["threadId"], "claude_a");
        assert_eq!(receive(&mut legacy)["params"]["threadId"], "claude_a");
        assert!(unrelated.try_recv().is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn content_routing_full_writers_never_delay_healthy_clients_or_drop_their_delta() {
        let gateway = TestGateway::new();
        let (tx, _full) = mpsc::channel(1);
        let blocked = test_client(1, tx);
        blocked
            .content_subscriptions
            .replace(json!({"threadIds":["claude_a"]}))
            .unwrap();
        blocked
            .try_send(ClientCommand::Text("occupied".into()))
            .unwrap();
        gateway.clients.insert(1, blocked.clone());
        let (healthy, mut rx) = client(&gateway, 2, Some(&["claude_a"]));
        let before = tokio::time::Instant::now();
        gateway.ingest_agent_notification(json!({"method":"item/agentMessage/delta","params":{"threadId":"claude_a","delta":"accepted"}})).await;
        assert_eq!(before.elapsed(), Duration::ZERO);
        assert_eq!(receive(&mut rx)["params"]["delta"], "accepted");
        assert!(blocked.closed.is_cancelled());
        assert!(!gateway.clients.contains_key(&1));
        assert!(!healthy.closed.is_cancelled() && gateway.clients.contains_key(&2));
    }
}
