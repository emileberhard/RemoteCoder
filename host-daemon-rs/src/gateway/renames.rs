use super::Gateway;
use crate::providers::claude::is_claude_thread_id;
use crate::rpc::error::{RpcCode, RpcData};
use crate::rpc::{RpcError, RpcResult};
use crate::tasks::owned_tasks::OwnedTasks;
use anyhow::Result;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;
use tokio::sync::{Semaphore, oneshot};

const MAX_RENAME_THREADS: usize = 1_024;
const MAX_RENAME_NAME_BYTES: usize = 4_096;
const CALLER_WAIT: Duration = Duration::from_secs(30);

#[derive(Default)]
pub(super) struct Renames {
    threads: Mutex<HashMap<String, Weak<RenameState>>>,
    tasks: OwnedTasks,
}

struct RenameState {
    generation: AtomicU64,
    serial: Arc<tokio::sync::Mutex<()>>,
    capacity: Arc<Semaphore>,
}

pub(super) struct Candidate {
    state: Arc<RenameState>,
    generation: u64,
}

enum Rename {
    Manual,
    Automatic { generation: u64, previous: String },
}

impl Renames {
    fn state(&self, thread: &str) -> std::result::Result<Arc<RenameState>, RpcError> {
        if thread.is_empty() || thread.len() > 512 {
            return Err(RpcError::new(RpcCode::InvalidParams, "Invalid threadId"));
        }
        let mut threads = self.threads.lock().expect("rename registry poisoned");
        threads.retain(|_, state| state.strong_count() > 0);
        if let Some(state) = threads.get(thread).and_then(Weak::upgrade) {
            return Ok(state);
        }
        if threads.len() >= MAX_RENAME_THREADS {
            return Err(RpcError::capacity());
        }
        let state = Arc::new(RenameState {
            generation: AtomicU64::new(0),
            serial: Arc::new(tokio::sync::Mutex::new(())),
            capacity: Arc::new(Semaphore::new(2)),
        });
        threads.insert(thread.to_owned(), Arc::downgrade(&state));
        Ok(state)
    }

    pub(super) fn candidate(&self, thread: &str) -> std::result::Result<Candidate, RpcError> {
        let state = self.state(thread)?;
        let generation = state.generation.load(Ordering::Acquire);
        Ok(Candidate { state, generation })
    }

    pub(super) async fn stop(&self) {
        self.tasks.stop().await;
    }
}

impl Gateway {
    pub(super) async fn rename_thread(self: &Arc<Self>, params: &Value) -> RpcResult {
        let thread = params["threadId"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= 512)
            .ok_or_else(|| RpcError::new(RpcCode::InvalidParams, "threadId is required"))?;
        let name = params["name"]
            .as_str()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .ok_or_else(|| {
                RpcError::new(RpcCode::InvalidParams, "thread name must not be empty")
            })?;
        let state = self.renames.state(thread)?;
        state.generation.fetch_add(1, Ordering::AcqRel);
        self.commit_rename(thread, name, state, Rename::Manual)
            .await?
            .ok_or_else(|| RpcError::new(RpcCode::Internal, "Manual rename was skipped"))
    }

    pub(super) async fn rename_automatically(
        self: &Arc<Self>,
        thread: &str,
        name: &str,
        previous: &str,
        candidate: Candidate,
    ) -> Result<Option<Value>> {
        if previous.len() > MAX_RENAME_NAME_BYTES {
            anyhow::bail!("previous title exceeds the rename comparison budget of 4096 bytes");
        }
        let rename = Rename::Automatic {
            generation: candidate.generation,
            previous: previous.to_owned(),
        };
        self.commit_rename(thread, name, candidate.state, rename)
            .await
            .map_err(|error| anyhow::anyhow!("title rename failed: {error:?}"))
    }

    async fn commit_rename(
        self: &Arc<Self>,
        thread: &str,
        name: &str,
        state: Arc<RenameState>,
        rename: Rename,
    ) -> std::result::Result<Option<Value>, RpcError> {
        if name.len() > MAX_RENAME_NAME_BYTES {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "thread name exceeds 4096 bytes",
            ));
        }
        let permit = Arc::clone(&state.capacity)
            .try_acquire_owned()
            .map_err(|_| RpcError::capacity())?;
        let deadline = tokio::time::Instant::now() + CALLER_WAIT;
        let serial = tokio::time::timeout_at(deadline, Arc::clone(&state.serial).lock_owned())
            .await
            .map_err(|_| RpcError::capacity())?;
        let gateway = Arc::clone(self);
        let thread = thread.to_owned();
        let name = name.to_owned();
        let (reply, receiver) = oneshot::channel();
        if !self.renames.tasks.spawn("conversation rename", async move {
            let _permit = permit;
            let _serial = serial;
            let result = gateway.apply_rename(&thread, &name, &state, rename).await;
            let outcome = match &result {
                Ok(Some(_)) => "acknowledged",
                Ok(None) => "skipped",
                Err(_) => "failed",
            };
            let caller_ended = reply.send(result).is_err();
            gateway.journal.push(
                "conversationRenameCompleted",
                json!({
                    "threadId":thread, "outcome":outcome, "callerEnded":caller_ended
                }),
            );
            Ok(())
        }) {
            return Err(RpcError::draining());
        }
        match tokio::time::timeout_at(deadline, receiver).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(RpcError::draining()),
            Err(_) => Err(RpcError::new(
                RpcCode::Unavailable,
                "The rename is still pending; refresh the name before retrying",
            )
            .with_data(RpcData::Raw(
                json!({"kind":"renameAcknowledgementUnknown", "retryable":false}),
            ))),
        }
    }

    async fn apply_rename(
        &self,
        thread: &str,
        name: &str,
        state: &RenameState,
        rename: Rename,
    ) -> std::result::Result<Option<Value>, RpcError> {
        if self.draining.load(Ordering::Acquire) {
            return Err(RpcError::draining());
        }
        if let Rename::Automatic {
            generation,
            previous,
        } = rename
        {
            let current = || {
                state.generation.load(Ordering::Acquire) == generation
                    && !self.draining.load(Ordering::Acquire)
            };
            if !current() {
                return Ok(None);
            }
            let header = self.review_header(thread).await.map_err(RpcError::from)?;
            if !current()
                || super::conversation_review::effective_title(&header["thread"])
                    != Some(previous.as_str())
            {
                return Ok(None);
            }
        }
        self.write_thread_name(&json!({"threadId":thread, "name":name}))
            .await
            .map(Some)
    }

    async fn write_thread_name(&self, params: &Value) -> RpcResult {
        if params["threadId"].as_str().is_some_and(is_claude_thread_id) {
            self.claude_thread_set_name(params).await
        } else {
            self.call_control_until_reply("thread/name/set", params.clone())
                .await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notifications::history::NotificationOrigin;
    use crate::test_support::{FakeControl, TestGateway};

    #[tokio::test]
    async fn a_manual_rename_at_the_automatic_guard_boundary_keeps_the_manual_name() {
        let gateway = TestGateway::new();
        let candidate = gateway.renames.candidate("thread").unwrap();
        let state = Arc::clone(&candidate.state);
        let boundary = state.serial.lock().await;
        let mut control = FakeControl::attach(&gateway, 8).await;
        let provider = gateway.clone();
        let (name_tx, name_rx) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(async move {
            let mut title = "Original".to_owned();
            let mut name_tx = Some(name_tx);
            while let Some(raw) = control.requests.recv().await {
                let request: Value = serde_json::from_str(&raw).unwrap();
                let result = match request["method"].as_str().unwrap() {
                    "thread/read" => json!({"thread":{"name":title}}),
                    "thread/name/set" => {
                        title = request["params"]["name"].as_str().unwrap().to_owned();
                        if let Some(tx) = name_tx.take() {
                            tx.send(title.clone()).unwrap();
                        }
                        json!({})
                    }
                    other => panic!("unexpected {other}"),
                };
                provider
                    .handle_control_text(
                        json!({"id":request["id"],"result":result}).to_string(),
                        NotificationOrigin::Control { opened_after: 0 },
                    )
                    .await;
            }
        });
        let manual_gateway = gateway.clone();
        let manual = tokio::spawn(async move {
            manual_gateway
                .rename_thread(&json!({"threadId":"thread","name":"My manual name"}))
                .await
        });
        while state.generation.load(Ordering::Acquire) == 0 {
            tokio::task::yield_now().await;
        }
        let auto_gateway = gateway.clone();
        let automatic = tokio::spawn(async move {
            auto_gateway
                .rename_automatically("thread", "Automatic", "Original", candidate)
                .await
        });
        drop(boundary);
        assert!(manual.await.unwrap().is_ok());
        assert!(automatic.await.unwrap().unwrap().is_none());
        assert_eq!(name_rx.await.unwrap(), "My manual name");
        assert_eq!(
            gateway.review_header("thread").await.unwrap()["thread"]["name"],
            "My manual name"
        );
        task.abort();
    }
    #[tokio::test(start_paused = true)]
    async fn a_submitted_automatic_rename_keeps_its_order_until_the_reply_after_the_rpc_deadline() {
        let gateway = TestGateway::new();
        let candidate = gateway.renames.candidate("thread").unwrap();
        let mut control = FakeControl::attach(&gateway, 8).await;
        let auto_gateway = gateway.clone();
        let automatic = tokio::spawn(async move {
            auto_gateway
                .rename_automatically("thread", "Automatic", "Original", candidate)
                .await
        });
        let header: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        assert_eq!(header["method"], "thread/read");
        gateway
            .handle_control_text(
                json!({"id":header["id"], "result":{"thread":{"name":"Original"}}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        let auto_write: Value =
            serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        assert_eq!(auto_write["params"]["name"], "Automatic");
        tokio::time::advance(std::time::Duration::from_secs(31)).await;
        tokio::task::yield_now().await;
        assert!(automatic.await.unwrap().is_err());
        let manual_gateway = gateway.clone();
        let manual = tokio::spawn(async move {
            manual_gateway
                .rename_thread(&json!({"threadId":"thread","name":"My manual name"}))
                .await
        });
        tokio::task::yield_now().await;
        assert!(!manual.is_finished());
        assert!(control.requests.try_recv().is_err());
        gateway
            .handle_control_text(
                json!({"id":auto_write["id"], "result":{}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        let manual_write: Value =
            serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        assert_eq!(manual_write["params"]["name"], "My manual name");
        gateway
            .handle_control_text(
                json!({"id":manual_write["id"], "result":{}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        assert!(manual.await.unwrap().is_ok());
    }
    #[tokio::test(start_paused = true)]
    async fn rename_review_a_stalled_thread_has_one_successor_and_other_threads_can_rename() {
        let gateway = TestGateway::new();
        let mut control = FakeControl::attach(&gateway, 8).await;
        let first = tokio::spawn({
            let gateway = gateway.clone();
            async move {
                gateway
                    .rename_thread(&json!({"threadId":"stalled","name":"First"}))
                    .await
            }
        });
        let request: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        assert_eq!(request["params"]["name"], "First");
        let second = tokio::spawn({
            let gateway = gateway.clone();
            async move {
                gateway
                    .rename_thread(&json!({"threadId":"stalled","name":"Second"}))
                    .await
            }
        });
        let state = gateway.renames.state("stalled").unwrap();
        while state.capacity.available_permits() != 0 {
            tokio::task::yield_now().await;
        }
        for _ in 0..16 {
            let error = gateway
                .rename_thread(&json!({"threadId":"stalled","name":"Rejected"}))
                .await
                .unwrap_err();
            assert_eq!(error.code, RpcCode::Capacity);
        }
        let other = tokio::spawn({
            let gateway = gateway.clone();
            async move {
                gateway
                    .rename_thread(&json!({"threadId":"other","name":"Independent"}))
                    .await
            }
        });
        let request: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        assert_eq!(request["params"]["threadId"], "other");
        gateway
            .handle_control_text(
                json!({"id":request["id"],"result":{}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        assert!(other.await.unwrap().is_ok());
        tokio::time::advance(Duration::from_secs(31)).await;
        assert_eq!(first.await.unwrap().unwrap_err().code, RpcCode::Unavailable);
        assert_eq!(second.await.unwrap().unwrap_err().code, RpcCode::Capacity);
        assert_eq!(state.capacity.available_permits(), 1);
        gateway.renames.stop().await;
        assert_eq!(state.capacity.available_permits(), 2);
    }
}
