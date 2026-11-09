use super::Gateway;
use crate::providers::claude::is_claude_thread_id;
use crate::rpc::error::{RpcCode, RpcData};
use crate::rpc::{RpcError, RpcResult};
use crate::tasks::owned_tasks::OwnedTasks;
use anyhow::{Context, Result};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;
use tokio::sync::{Semaphore, oneshot};

const MAX_RENAME_THREADS: usize = 1_024;
const MAX_RENAME_NAME_BYTES: usize = 4_096;
const CALLER_WAIT: Duration = Duration::from_secs(30);

pub(super) struct Renames {
    threads: Mutex<HashMap<String, Weak<RenameState>>>,
    tasks: OwnedTasks,
    drain_running: AtomicBool,
    drain_requested: AtomicBool,
    update_capacity: Arc<Semaphore>,
}

impl Default for Renames {
    fn default() -> Self {
        Self {
            threads: Mutex::new(HashMap::new()),
            tasks: OwnedTasks::default(),
            drain_running: AtomicBool::new(false),
            drain_requested: AtomicBool::new(false),
            update_capacity: Arc::new(Semaphore::new(64)),
        }
    }
}

struct RenameState {
    generation: AtomicU64,
    serial: Arc<tokio::sync::Mutex<()>>,
    capacity: Arc<Semaphore>,
    pending_capacity: Arc<Semaphore>,
}

pub(super) struct Candidate {
    state: Arc<RenameState>,
    generation: u64,
}

enum Rename {
    Manual,
    Automatic {
        generation: u64,
        previous: String,
        requested: bool,
    },
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
            pending_capacity: Arc::new(Semaphore::new(1)),
        });
        threads.insert(thread.to_owned(), Arc::downgrade(&state));
        Ok(state)
    }

    pub(super) fn candidate(&self, thread: &str) -> std::result::Result<Candidate, RpcError> {
        let state = self.state(thread)?;
        let generation = state.generation.load(Ordering::Acquire);
        Ok(Candidate { state, generation })
    }

    fn invalidate_existing(&self, thread: &str) {
        let threads = self.threads.lock().expect("rename registry poisoned");
        if let Some(state) = threads.get(thread).and_then(Weak::upgrade) {
            state.generation.fetch_add(1, Ordering::AcqRel);
        }
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
        if name.len() > MAX_RENAME_NAME_BYTES {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "thread name exceeds 4096 bytes",
            ));
        }
        let pending = self
            .marks
            .pending_renames(crate::time::unix_seconds() as i64)
            .await
            .map_err(RpcError::from)?
            .get(thread)
            .cloned();
        let state = self.renames.state(thread)?;
        let admission = Arc::clone(&state.capacity)
            .try_acquire_owned()
            .map_err(|_| RpcError::capacity())?;
        state.generation.fetch_add(1, Ordering::AcqRel);
        let gateway = Arc::clone(self);
        let thread = thread.to_owned();
        let name = name.to_owned();
        let (reply, receiver) = oneshot::channel();
        if !self
            .renames
            .tasks
            .spawn("manual rename admission", async move {
                let result = async {
                    gateway
                        .marks
                        .cancel_pending_rename(
                            thread.clone(),
                            pending,
                            crate::time::unix_seconds() as i64,
                        )
                        .await
                        .map_err(RpcError::from)?;
                    drop(admission);
                    gateway
                        .commit_rename(&thread, &name, state, Rename::Manual)
                        .await?
                        .ok_or_else(|| {
                            RpcError::new(RpcCode::Internal, "Manual rename was skipped")
                        })
                }
                .await;
                let _ = reply.send(result);
                Ok(())
            })
        {
            return Err(RpcError::draining());
        }
        receiver.await.map_err(|_| RpcError::draining())?
    }

    pub(super) async fn prepare_regenerate(self: &Arc<Self>, thread: &str) -> Result<Candidate> {
        let pending = self
            .marks
            .pending_renames(crate::time::unix_seconds() as i64)
            .await?
            .get(thread)
            .cloned();
        let state = self
            .renames
            .state(thread)
            .map_err(|error| anyhow::anyhow!("rename admission failed: {error:?}"))?;
        let permit = Arc::clone(&state.capacity)
            .try_acquire_owned()
            .map_err(|_| anyhow::anyhow!("rename admission capacity reached"))?;
        let generation = state.generation.fetch_add(1, Ordering::AcqRel) + 1;
        let gateway = Arc::clone(self);
        let thread = thread.to_owned();
        let (reply, receiver) = oneshot::channel();
        if !self
            .renames
            .tasks
            .spawn("regenerate name admission", async move {
                let result = async {
                    gateway
                        .marks
                        .cancel_pending_rename(
                            thread.clone(),
                            pending,
                            crate::time::unix_seconds() as i64,
                        )
                        .await?;
                    let _guard =
                        tokio::time::timeout(CALLER_WAIT, Arc::clone(&state.serial).lock_owned())
                            .await?;
                    anyhow::ensure!(
                        state.generation.load(Ordering::Acquire) == generation,
                        "a newer rename superseded regeneration"
                    );
                    if let Some(delta) = gateway
                        .marks
                        .clear_manual_name(thread, crate::time::unix_seconds() as i64)
                        .await?
                    {
                        gateway.publish_marks(&delta).await;
                    }
                    Ok(Candidate { state, generation })
                }
                .await;
                drop(permit);
                let _ = reply.send(result);
                Ok(())
            })
        {
            anyhow::bail!("rename owner is shutting down");
        }
        receiver.await.context("regenerate name admission ended")?
    }

    pub(super) async fn rename_automatically(
        self: &Arc<Self>,
        thread: &str,
        name: &str,
        previous: &str,
        candidate: Candidate,
        requested: bool,
    ) -> Result<Option<Value>> {
        if previous.len() > MAX_RENAME_NAME_BYTES {
            anyhow::bail!("previous title exceeds the rename comparison budget of 4096 bytes");
        }
        let rename = Rename::Automatic {
            generation: candidate.generation,
            previous: previous.to_owned(),
            requested,
        };
        self.commit_rename(thread, name, candidate.state, rename)
            .await
            .map_err(|error| anyhow::anyhow!("title rename failed: {error:?}"))
    }

    pub(super) async fn update_named_pins(
        self: &Arc<Self>,
        changes: Vec<crate::conversation_marks::Change>,
        now: i64,
    ) -> RpcResult {
        let permit = Arc::clone(&self.renames.update_capacity)
            .try_acquire_owned()
            .map_err(|_| RpcError::capacity())?;
        let gateway = Arc::clone(self);
        let (reply, receiver) = oneshot::channel();
        if !self.renames.tasks.spawn("named pin update", async move {
            let _permit = permit;
            for change in &changes {
                if let crate::conversation_marks::Change::Pin {
                    thread_id,
                    name: Some(_),
                } = change
                {
                    gateway.renames.invalidate_existing(thread_id);
                }
            }
            let result = gateway.marks.update(changes, now).await;
            if let Ok(delta) = &result {
                gateway.wake_pending_renames();
                if let Some(delta) = delta {
                    gateway.publish_marks(delta).await;
                }
            }
            let _ = reply.send(result);
            Ok(())
        }) {
            return Err(RpcError::draining());
        }
        let delta = receiver.await.map_err(|_| RpcError::draining())??;
        Ok(json!({ "delta": delta }))
    }

    pub(super) fn wake_pending_renames(self: &Arc<Self>) {
        self.renames.drain_requested.store(true, Ordering::Release);
        if self.renames.drain_running.swap(true, Ordering::AcqRel) {
            return;
        }
        let gateway = Arc::clone(self);
        if !self
            .renames
            .tasks
            .spawn("pending conversation renames", async move {
                loop {
                    gateway
                        .renames
                        .drain_requested
                        .store(false, Ordering::Release);
                    gateway.drain_pending_renames().await;
                    gateway
                        .renames
                        .drain_running
                        .store(false, Ordering::Release);
                    if !gateway.renames.drain_requested.load(Ordering::Acquire)
                        || gateway.renames.drain_running.swap(true, Ordering::AcqRel)
                    {
                        break;
                    }
                }
                Ok(())
            })
        {
            self.renames.drain_running.store(false, Ordering::Release);
        }
    }

    async fn drain_pending_renames(self: &Arc<Self>) {
        let pending = match self
            .marks
            .pending_renames(crate::time::unix_seconds() as i64)
            .await
        {
            Ok(pending) => pending,
            Err(error) => {
                tracing::warn!(%error, "pending renames unavailable");
                return;
            }
        };
        for (thread, pending) in pending {
            let Ok(state) = self.renames.state(&thread) else {
                continue;
            };
            let Ok(permit) = Arc::clone(&state.pending_capacity).try_acquire_owned() else {
                continue;
            };
            let gateway = Arc::clone(self);
            let task_thread = thread.clone();
            let task_pending = pending.clone();
            let (reply, receiver) = oneshot::channel();
            if !self
                .renames
                .tasks
                .spawn("pending conversation rename", async move {
                    let _state = state;
                    let result = gateway
                        .drain_pending_rename(&task_thread, &task_pending)
                        .await;
                    drop(permit);
                    if let Ok(current) = gateway
                        .marks
                        .pending_renames(crate::time::unix_seconds() as i64)
                        .await
                        && current
                            .get(&task_thread)
                            .is_some_and(|newer| newer != &task_pending)
                    {
                        gateway.wake_pending_renames();
                    }
                    let _ = reply.send(result);
                    Ok(())
                })
            {
                return;
            }
            match tokio::time::timeout(CALLER_WAIT, receiver).await {
                Ok(Ok(Ok(()))) => {}
                Ok(Ok(Err(error))) => {
                    tracing::warn!(thread_id = thread, %error, "pending rename retained")
                }
                Ok(Err(_)) => tracing::warn!(thread_id = thread, "pending rename owner stopped"),
                Err(_) => tracing::warn!(
                    thread_id = thread,
                    "pending rename is still awaiting its provider"
                ),
            }
        }
    }

    async fn drain_pending_rename(
        &self,
        thread: &str,
        pending: &crate::conversation_marks::PendingRename,
    ) -> Result<()> {
        let name = pending.name.as_str();
        let state = self
            .renames
            .state(thread)
            .map_err(|error| anyhow::anyhow!("rename admission failed: {error:?}"))?;
        let generation = state.generation.load(Ordering::Acquire);
        let _serial =
            tokio::time::timeout(CALLER_WAIT, Arc::clone(&state.serial).lock_owned()).await?;
        let is_current = || {
            state.generation.load(Ordering::Acquire) == generation
                && !self.draining.load(Ordering::Acquire)
        };
        if !is_current()
            || self
                .marks
                .pending_renames(crate::time::unix_seconds() as i64)
                .await?
                .get(thread)
                != Some(pending)
        {
            return Ok(());
        }
        let header = match self.review_header(thread).await {
            Ok(header) => header,
            Err(error) if !is_claude_thread_id(thread) && missing_codex_thread(&error, thread) => {
                self.marks
                    .complete_pending_rename(
                        thread.to_owned(),
                        pending.clone(),
                        crate::time::unix_seconds() as i64,
                    )
                    .await?;
                return Ok(());
            }
            Err(error) => return Err(error),
        };
        let header = &header["thread"];
        if matches_displayed_title(header, name) {
            self.marks
                .complete_pending_rename(
                    thread.to_owned(),
                    pending.clone(),
                    crate::time::unix_seconds() as i64,
                )
                .await?;
            return Ok(());
        }
        if !is_current()
            || self
                .marks
                .pending_renames(crate::time::unix_seconds() as i64)
                .await?
                .get(thread)
                != Some(pending)
        {
            return Ok(());
        }
        let (current, delta) = self
            .marks
            .begin_pending_rename(
                thread.to_owned(),
                pending.clone(),
                crate::time::unix_seconds() as i64,
            )
            .await?;
        if let Some(delta) = delta {
            self.publish_marks(&delta).await;
        }
        if !current || !is_current() {
            return Ok(());
        }
        self.write_thread_name(&json!({"threadId":thread,"name":name}))
            .await
            .map_err(|error| anyhow::anyhow!("provider rename failed: {error:?}"))?;
        self.marks
            .complete_pending_rename(
                thread.to_owned(),
                pending.clone(),
                crate::time::unix_seconds() as i64,
            )
            .await?;
        Ok(())
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
            requested,
        } = &rename
        {
            let current = || {
                state.generation.load(Ordering::Acquire) == *generation
                    && !self.draining.load(Ordering::Acquire)
            };
            if !current() {
                return Ok(None);
            }
            if !requested
                && self
                    .marks
                    .read(crate::time::unix_seconds() as i64)
                    .await
                    .map_err(RpcError::from)?
                    .threads
                    .get(thread)
                    .is_some_and(|mark| mark.manual_name)
            {
                return Ok(None);
            }
            if self
                .marks
                .pending_renames(crate::time::unix_seconds() as i64)
                .await
                .map_err(RpcError::from)?
                .contains_key(thread)
            {
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
        let manual = matches!(rename, Rename::Manual);
        let previously_manual = manual
            && self
                .marks
                .read(crate::time::unix_seconds() as i64)
                .await
                .map_err(RpcError::from)?
                .threads
                .get(thread)
                .is_some_and(|marks| marks.manual_name);
        if manual
            && let Some(delta) = self
                .marks
                .record_manual_name(thread.to_owned(), crate::time::unix_seconds() as i64)
                .await
                .map_err(RpcError::from)?
        {
            self.publish_marks(&delta).await;
        }
        let response = match self
            .write_thread_name(&json!({"threadId":thread, "name":name}))
            .await
        {
            Ok(response) => response,
            Err(error) => {
                if manual
                    && !previously_manual
                    && (error.code == RpcCode::InvalidParams
                        || (is_claude_thread_id(thread)
                            && matches!(&error.data, RpcData::Raw(data) if data["kind"] == "renameNotStarted")))
                    && let Some(delta) = self
                        .marks
                        .clear_manual_name(thread.to_owned(), crate::time::unix_seconds() as i64)
                        .await
                        .map_err(RpcError::from)?
                {
                    self.publish_marks(&delta).await;
                }
                return Err(error);
            }
        };
        Ok(Some(response))
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

fn matches_displayed_title(header: &Value, name: &str) -> bool {
    if let Some(current) = header["name"]
        .as_str()
        .filter(|value| !value.trim().is_empty())
    {
        return name == current;
    }
    let preview = header["preview"].as_str().unwrap_or_default();
    let needle = name
        .trim()
        .trim_end_matches('…')
        .trim_end_matches('.')
        .trim_end();
    if needle.is_empty() {
        return false;
    }
    preview.contains(needle) || crate::prompt_summary::prompt_summary(preview).contains(needle)
}

fn missing_codex_thread(error: &anyhow::Error, thread: &str) -> bool {
    serde_json::from_str::<Value>(&error.to_string()).is_ok_and(|reply| {
        reply["code"] == -32600
            && reply["message"].as_str() == Some(format!("thread not loaded: {thread}").as_str())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notifications::history::NotificationOrigin;
    use crate::test_support::{FakeControl, TestGateway};

    #[tokio::test]
    async fn oversized_manual_name_does_not_cancel_the_pending_name() {
        use crate::conversation_marks::Change;
        let gateway = TestGateway::new();
        gateway
            .marks
            .update(
                vec![Change::Pin {
                    thread_id: "thread".into(),
                    name: Some("Keep".into()),
                }],
                1,
            )
            .await
            .unwrap();
        let error = gateway
            .rename_thread(&json!({"threadId":"thread","name":"x".repeat(4097)}))
            .await
            .unwrap_err();
        assert_eq!(error.code, RpcCode::InvalidParams);
        assert_eq!(
            gateway.marks.pending_renames(2).await.unwrap()["thread"].name,
            "Keep"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_stalled_carry_over_does_not_block_the_next_and_its_late_reply_precedes_manual_rename()
     {
        use crate::conversation_marks::Change;
        let gateway = TestGateway::new();
        gateway
            .marks
            .update(
                vec![
                    Change::Pin {
                        thread_id: "a".into(),
                        name: Some("Old A".into()),
                    },
                    Change::Pin {
                        thread_id: "b".into(),
                        name: Some("Old B".into()),
                    },
                ],
                1,
            )
            .await
            .unwrap();
        let mut control = FakeControl::attach(&gateway, 8).await;
        let drain = tokio::spawn({
            let gateway = gateway.clone();
            async move { gateway.drain_pending_renames().await }
        });
        let read_a: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        assert_eq!(read_a["params"]["threadId"], "a");
        gateway
            .handle_control_text(
                json!({"id":read_a["id"],"result":{"thread":{"name":"Current A"}}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        let write_a: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        assert_eq!(write_a["params"]["name"], "Old A");
        tokio::time::advance(Duration::from_secs(31)).await;
        let read_b: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        assert_eq!(read_b["params"]["threadId"], "b");
        gateway
            .handle_control_text(
                json!({"id":read_b["id"],"result":{"thread":{"name":"Current B"}}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        let write_b: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        assert_eq!(write_b["params"]["name"], "Old B");
        gateway
            .handle_control_text(
                json!({"id":write_b["id"],"result":{}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        drain.await.unwrap();
        assert!(
            gateway
                .marks
                .pending_renames(2)
                .await
                .unwrap()
                .contains_key("a")
        );
        let manual = tokio::spawn({
            let gateway = gateway.clone();
            async move {
                gateway
                    .rename_thread(&json!({"threadId":"a","name":"Manual A"}))
                    .await
            }
        });
        while gateway
            .marks
            .pending_renames(2)
            .await
            .unwrap()
            .contains_key("a")
        {
            tokio::task::yield_now().await;
        }
        assert!(control.requests.try_recv().is_err());
        gateway
            .handle_control_text(
                json!({"id":write_a["id"],"result":{}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        let manual_write: Value =
            serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        assert_eq!(manual_write["params"]["name"], "Manual A");
        gateway
            .handle_control_text(
                json!({"id":manual_write["id"],"result":{}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        manual.await.unwrap().unwrap();
        assert!(gateway.marks.read(3).await.unwrap().threads["a"].manual_name);
    }

    #[tokio::test]
    async fn a_named_pin_arriving_during_automatic_read_invalidates_the_rename() {
        use crate::conversation_marks::Change;
        let gateway = TestGateway::new();
        let candidate = gateway.renames.candidate("thread").unwrap();
        let mut control = FakeControl::attach(&gateway, 8).await;
        let automatic = tokio::spawn({
            let gateway = gateway.clone();
            async move {
                gateway
                    .rename_automatically("thread", "Automatic", "Original", candidate, false)
                    .await
            }
        });
        let read: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        gateway
            .update_named_pins(
                vec![Change::Pin {
                    thread_id: "thread".into(),
                    name: Some("Mine".into()),
                }],
                1,
            )
            .await
            .unwrap();
        gateway
            .handle_control_text(
                json!({"id":read["id"],"result":{"thread":{"name":"Original"}}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        assert!(automatic.await.unwrap().unwrap().is_none());
        gateway.renames.stop().await;
    }

    #[test]
    fn displayed_title_comparison_covers_wrapped_and_ellipsized_previews() {
        let header = json!({"name":null,"preview":"Read <remotecoder_pasted_text_v2 id=\"11111111-2222-4333-8444-555555555555\" bytes=\"4\">\ndata\n</remotecoder_pasted_text_v2>"});
        assert!(matches_displayed_title(&header, "Read [Pasted text]"));
        assert!(matches_displayed_title(
            &json!({"name":null,"preview":"First line and more"}),
            "First line…"
        ));
        assert!(!matches_displayed_title(
            &json!({"name":"Original","preview":"First line"}),
            "First line"
        ));
    }

    #[tokio::test]
    async fn rejected_manual_rename_preserves_the_previous_protection_state() {
        let gateway = TestGateway::new();
        let mut control = FakeControl::attach(&gateway, 8).await;
        let manual = tokio::spawn({
            let gateway = gateway.clone();
            async move {
                gateway
                    .rename_thread(&json!({"threadId":"thread","name":"Name"}))
                    .await
            }
        });
        let write: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        gateway
            .handle_control_text(
                json!({"id":write["id"],"error":{"code":-32602,"message":"not started"}})
                    .to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        assert_eq!(
            manual.await.unwrap().unwrap_err().code,
            RpcCode::InvalidParams
        );
        assert!(
            gateway
                .marks
                .read(2)
                .await
                .unwrap()
                .threads
                .get("thread")
                .is_none_or(|mark| !mark.manual_name)
        );
    }

    #[tokio::test]
    async fn unavailable_claude_agent_does_not_protect_an_unchanged_name() {
        let gateway = TestGateway::new();
        let thread = "claude_11111111-2222-4333-8444-555555555555";
        let error = gateway
            .rename_thread(&json!({"threadId":thread,"name":"Name"}))
            .await
            .unwrap_err();
        assert_eq!(error.code, RpcCode::Internal);
        assert!(
            gateway
                .marks
                .read(2)
                .await
                .unwrap()
                .threads
                .get(thread)
                .is_none_or(|mark| !mark.manual_name)
        );
    }

    #[tokio::test]
    async fn regeneration_cancels_only_older_pending_names() {
        use crate::conversation_marks::Change;
        let gateway = TestGateway::new();
        let pin = |name: &str| Change::Pin {
            thread_id: "thread".into(),
            name: Some(name.into()),
        };
        gateway.marks.update(vec![pin("Old")], 1).await.unwrap();
        gateway
            .marks
            .record_manual_name("thread".into(), 1)
            .await
            .unwrap();
        let _candidate = gateway.prepare_regenerate("thread").await.unwrap();
        assert!(!gateway.marks.read(2).await.unwrap().threads["thread"].manual_name);
        assert!(gateway.marks.pending_renames(2).await.unwrap().is_empty());
        gateway.marks.update(vec![pin("New")], 3).await.unwrap();
        assert_eq!(
            gateway.marks.pending_renames(4).await.unwrap()["thread"].name,
            "New"
        );
    }

    #[tokio::test]
    async fn a_named_pin_after_manual_admission_is_not_canceled_by_the_queued_rename() {
        use crate::conversation_marks::Change;
        let gateway = TestGateway::new();
        let pin = |name: &str| Change::Pin {
            thread_id: "thread".into(),
            name: Some(name.into()),
        };
        gateway.marks.update(vec![pin("Old")], 1).await.unwrap();
        let state = gateway.renames.state("thread").unwrap();
        let guard = state.serial.lock().await;
        let mut control = FakeControl::attach(&gateway, 8).await;
        let manual = tokio::spawn({
            let gateway = gateway.clone();
            async move {
                gateway
                    .rename_thread(&json!({"threadId":"thread","name":"Manual"}))
                    .await
            }
        });
        while !gateway.marks.pending_renames(2).await.unwrap().is_empty() {
            tokio::task::yield_now().await;
        }
        gateway.marks.update(vec![pin("New")], 3).await.unwrap();
        drop(guard);
        let write: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        assert_eq!(write["params"]["name"], "Manual");
        gateway
            .handle_control_text(
                json!({"id":write["id"],"result":{}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        manual.await.unwrap().unwrap();
        assert_eq!(
            gateway.marks.pending_renames(4).await.unwrap()["thread"].name,
            "New"
        );
    }

    #[tokio::test]
    async fn a_repeated_name_queued_during_provider_write_survives_the_old_receipt() {
        use crate::conversation_marks::Change;
        let gateway = TestGateway::new();
        let named_pin = || Change::Pin {
            thread_id: "thread".into(),
            name: Some("Keep".into()),
        };
        gateway.marks.update(vec![named_pin()], 1).await.unwrap();
        let old = gateway.marks.pending_renames(1).await.unwrap()["thread"].clone();
        let mut control = FakeControl::attach(&gateway, 8).await;
        let draining = tokio::spawn({
            let gateway = gateway.clone();
            let old = old.clone();
            async move { gateway.drain_pending_rename("thread", &old).await }
        });
        let read: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        gateway
            .handle_control_text(
                json!({"id":read["id"],"result":{"thread":{"name":"Current"}}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        let write: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        assert_eq!(write["params"]["name"], "Keep");
        gateway.marks.update(vec![named_pin()], 2).await.unwrap();
        gateway
            .handle_control_text(
                json!({"id":write["id"],"result":{}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        draining.await.unwrap().unwrap();
        let newer = gateway.marks.pending_renames(3).await.unwrap()["thread"].clone();
        assert_eq!(newer.name, "Keep");
        assert!(newer.revision > old.revision);
        assert!(gateway.marks.read(3).await.unwrap().threads["thread"].manual_name);
    }

    #[tokio::test(start_paused = true)]
    async fn manual_name_is_protected_when_a_late_provider_reply_outlives_the_caller() {
        let gateway = TestGateway::new();
        let mut control = FakeControl::attach(&gateway, 8).await;
        let state = gateway.renames.state("thread").unwrap();
        let caller = tokio::spawn({
            let gateway = gateway.clone();
            async move {
                gateway
                    .rename_thread(&json!({"threadId":"thread","name":"Manual"}))
                    .await
            }
        });
        let write: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        tokio::time::advance(Duration::from_secs(31)).await;
        assert!(caller.await.unwrap().is_err());
        gateway
            .handle_control_text(
                json!({"id":write["id"],"result":{}}).to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        let _guard = state.serial.lock().await;
        assert!(gateway.marks.read(100).await.unwrap().threads["thread"].manual_name);
    }

    #[tokio::test]
    async fn confirmed_missing_codex_thread_drops_only_its_matching_pending_name() {
        use crate::conversation_marks::Change;
        let gateway = TestGateway::new();
        gateway
            .marks
            .update(
                vec![Change::Pin {
                    thread_id: "missing".into(),
                    name: Some("Old".into()),
                }],
                1,
            )
            .await
            .unwrap();
        let mut control = FakeControl::attach(&gateway, 8).await;
        let draining = tokio::spawn({
            let gateway = gateway.clone();
            async move {
                {
                    let pending =
                        gateway.marks.pending_renames(1).await.unwrap()["missing"].clone();
                    gateway.drain_pending_rename("missing", &pending).await
                }
            }
        });
        let read: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        gateway.handle_control_text(json!({"id":read["id"],"error":{"code":-32600,"message":"thread not loaded: missing"}}).to_string(), NotificationOrigin::Control { opened_after: 0 }).await;
        draining.await.unwrap().unwrap();
        assert!(gateway.marks.pending_renames(2).await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_newer_named_pin_fences_an_in_flight_carry_over() {
        use crate::conversation_marks::Change;
        let gateway = TestGateway::new();
        gateway
            .marks
            .update(
                vec![Change::Pin {
                    thread_id: "thread".into(),
                    name: Some("Old".into()),
                }],
                1,
            )
            .await
            .unwrap();
        let mut control = FakeControl::attach(&gateway, 8).await;
        let draining = tokio::spawn({
            let gateway = gateway.clone();
            async move {
                {
                    let pending = gateway.marks.pending_renames(1).await.unwrap()["thread"].clone();
                    gateway.drain_pending_rename("thread", &pending).await
                }
            }
        });
        let read: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        assert_eq!(read["method"], "thread/read");
        gateway
            .marks
            .update(
                vec![Change::Pin {
                    thread_id: "thread".into(),
                    name: Some("New".into()),
                }],
                2,
            )
            .await
            .unwrap();
        gateway
            .handle_control_text(
                json!({"id":read["id"],"result":{"thread":{"name":"Current","preview":"Preview"}}})
                    .to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        draining.await.unwrap().unwrap();
        assert!(control.requests.try_recv().is_err());
        assert_eq!(
            gateway.marks.pending_renames(3).await.unwrap()["thread"].name,
            "New"
        );
    }

    #[tokio::test]
    async fn carry_over_skips_the_shown_preview_without_creating_a_manual_name() {
        use crate::conversation_marks::Change;
        let gateway = TestGateway::new();
        let shown = "a".repeat(250);
        let preview = format!("{shown}👨‍👩‍👧‍👦after");
        gateway
            .marks
            .update(
                vec![Change::Pin {
                    thread_id: "thread".into(),
                    name: Some(shown.clone()),
                }],
                1,
            )
            .await
            .unwrap();
        let mut control = FakeControl::attach(&gateway, 8).await;
        let draining = tokio::spawn({
            let gateway = gateway.clone();
            async move {
                {
                    let pending = gateway.marks.pending_renames(1).await.unwrap()["thread"].clone();
                    gateway.drain_pending_rename("thread", &pending).await
                }
            }
        });
        let read: Value = serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
        gateway
            .handle_control_text(
                json!({"id":read["id"],"result":{"thread":{"name":null,"preview":preview}}})
                    .to_string(),
                NotificationOrigin::Control { opened_after: 0 },
            )
            .await;
        draining.await.unwrap().unwrap();
        assert!(control.requests.try_recv().is_err());
        assert!(gateway.marks.pending_renames(2).await.unwrap().is_empty());
        assert!(!gateway.marks.read(2).await.unwrap().threads["thread"].manual_name);
    }

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
                .rename_automatically("thread", "Automatic", "Original", candidate, false)
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
                .rename_automatically("thread", "Automatic", "Original", candidate, false)
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
