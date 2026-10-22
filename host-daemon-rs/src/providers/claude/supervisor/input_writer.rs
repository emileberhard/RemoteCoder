use super::ClaudeSupervisor;
use crate::ids::new_session_uuid;
use crate::providers::claude::ClaudeUserInput;
use crate::providers::claude::capacity::CapacityExceeded;
use crate::providers::claude::input::ClaudeContent;
use crate::providers::codex::daemon::MAX_WEBSOCKET_BYTES;
use nix::unistd::Pid;
use serde::Serialize;
use serde_json::Value;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tokio::io::{AsyncWrite, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot};
use tokio::time::Instant;
use tokio_util::sync::{CancellationToken, DropGuard};
use tracing::warn;

const INPUT_QUEUE_CAPACITY: usize = 16;

const INPUT_STALL_LIMIT: Duration = Duration::from_secs(10);

const MAX_UNCONSUMED_INPUTS: usize = 32;

#[derive(Clone, Default)]
pub(super) struct UnconsumedInputs(Arc<StdMutex<VecDeque<ClaudeUserInput>>>);

impl UnconsumedInputs {
    pub(super) fn queue(&self, input: Option<ClaudeUserInput>, send: impl FnOnce()) {
        let mut inputs = self.0.lock().expect("Claude input record poisoned");
        if let Some(input) = input {
            if inputs.len() == MAX_UNCONSUMED_INPUTS
                && let Some(dropped) = inputs.pop_front()
            {
                warn!(input = ?dropped.client_id, "Claude never echoed an input; it will not be carried across a restart");
            }
            inputs.push_back(input);
        }
        send();
    }

    pub(super) fn remove(&self, id: &str) {
        self.0
            .lock()
            .expect("Claude input record poisoned")
            .retain(|input| input.client_id.as_deref() != Some(id));
    }

    pub(super) fn take(&self, consumed: &[&str]) -> Vec<String> {
        if consumed.is_empty() {
            return Vec::new();
        }
        let mut inputs = self.0.lock().expect("Claude input record poisoned");
        let Some(last) = inputs.iter().rposition(|input| {
            input
                .client_id
                .as_deref()
                .is_some_and(|id| consumed.contains(&id))
        }) else {
            return Vec::new();
        };
        inputs
            .drain(..=last)
            .filter_map(|input| input.client_id)
            .collect()
    }

    pub(super) fn pending(&self) -> Vec<ClaudeUserInput> {
        self.0
            .lock()
            .expect("Claude input record poisoned")
            .iter()
            .cloned()
            .collect()
    }
}

enum Frame {
    Input(Arc<PreparedInput>),
    Control(PreparedControl),
}

struct Submission {
    frame: Frame,
    written: oneshot::Sender<std::io::Result<()>>,
}

#[derive(Clone)]
pub(super) struct InputWriter {
    submissions: mpsc::Sender<Submission>,
    unconsumed: UnconsumedInputs,
    stall_limit: Duration,
    _owner: Arc<DropGuard>,
}

impl InputWriter {
    pub(super) fn spawn<W>(writer: W) -> Self
    where
        W: AsyncWrite + Unpin + Send + 'static,
    {
        Self::spawn_with_stall_limit(writer, INPUT_STALL_LIMIT)
    }

    pub(super) fn spawn_with_stall_limit<W>(writer: W, stall_limit: Duration) -> Self
    where
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let (submissions, queue) = mpsc::channel(INPUT_QUEUE_CAPACITY);
        let unconsumed = UnconsumedInputs::default();
        let cancel = CancellationToken::new();
        tokio::spawn(write_until_failure(
            FramedInput {
                writer,
                unconsumed: unconsumed.clone(),
            },
            queue,
            cancel.clone(),
        ));
        Self {
            submissions,
            unconsumed,
            stall_limit,
            _owner: Arc::new(cancel.drop_guard()),
        }
    }

    pub(super) fn unconsumed(&self) -> &UnconsumedInputs {
        &self.unconsumed
    }

    pub(super) fn prepare_input(input: &ClaudeUserInput) -> std::io::Result<Arc<PreparedInput>> {
        let id = input.client_id.clone().unwrap_or_else(new_session_uuid);
        let frame = InputFrame {
            kind: "user",
            uuid: &id,
            parent_tool_use_id: (),
            message: InputMessage {
                role: "user",
                content: input.content(),
            },
            is_synthetic: input.is_synthetic.then_some(true),
            should_query: input.is_synthetic.then_some(true),
        };
        let raw = frame_bytes(&frame)?;
        Ok(Arc::new(PreparedInput {
            input: ClaudeUserInput {
                client_id: Some(id),
                ..input.clone()
            },
            raw,
        }))
    }

    #[cfg(test)]
    pub(super) async fn send_input(&self, input: &ClaudeUserInput) -> std::io::Result<()> {
        self.send_prepared(Self::prepare_input(input)?).await
    }

    pub(super) async fn send_prepared(&self, input: Arc<PreparedInput>) -> std::io::Result<()> {
        self.submit(Frame::Input(input)).await
    }

    pub(super) fn prepare_control(
        request_id: &str,
        request: &Value,
    ) -> std::io::Result<PreparedControl> {
        let raw = frame_bytes(&ControlFrame {
            kind: "control_request",
            request_id,
            request,
        })?;
        Ok(PreparedControl {
            request_id: request_id.to_owned(),
            raw,
        })
    }

    pub(super) fn prepare_control_cancel(request_id: &str) -> std::io::Result<PreparedControl> {
        let raw = frame_bytes(&ControlCancelFrame {
            kind: "control_cancel_request",
            request_id,
        })?;
        Ok(PreparedControl {
            request_id: request_id.to_owned(),
            raw,
        })
    }

    pub(super) async fn send_prepared_control(
        &self,
        prepared: PreparedControl,
    ) -> std::io::Result<()> {
        self.submit(Frame::Control(prepared)).await
    }

    pub(super) fn is_stalled(error: &std::io::Error) -> bool {
        Self::stall(error).is_some()
    }

    pub(super) fn stall_was_queued(error: &std::io::Error) -> bool {
        Self::stall(error).is_some_and(|stall| stall.queued)
    }

    fn stall(error: &std::io::Error) -> Option<&InputStalled> {
        error.get_ref()?.downcast_ref::<InputStalled>()
    }

    async fn submit(&self, frame: Frame) -> std::io::Result<()> {
        self.reserve().await?.send(frame).written().await
    }

    pub(super) async fn reserve(&self) -> std::io::Result<InputSlot> {
        let deadline = Instant::now() + self.stall_limit;
        let permit = tokio::time::timeout_at(deadline, self.submissions.clone().reserve_owned())
            .await
            .map_err(|_| {
                InputStalled {
                    queued: false,
                    limit: self.stall_limit,
                }
                .into_error()
            })?
            .map_err(|_| writer_stopped())?;
        Ok(InputSlot {
            permit,
            unconsumed: self.unconsumed.clone(),
            deadline,
            limit: self.stall_limit,
        })
    }
}

pub(super) struct InputSlot {
    permit: mpsc::OwnedPermit<Submission>,
    unconsumed: UnconsumedInputs,
    deadline: Instant,
    limit: Duration,
}

impl InputSlot {
    pub(super) fn send_input(self, input: Arc<PreparedInput>) -> PendingWrite {
        self.send(Frame::Input(input))
    }

    fn send(self, frame: Frame) -> PendingWrite {
        let (written, outcome) = oneshot::channel();
        let input = match &frame {
            Frame::Input(prepared) => Some(prepared.input.clone()),
            Frame::Control(_) => None,
        };
        let permit = self.permit;
        self.unconsumed.queue(input, || {
            permit.send(Submission { frame, written });
        });
        PendingWrite {
            outcome,
            deadline: self.deadline,
            limit: self.limit,
        }
    }
}

pub(super) struct PendingWrite {
    outcome: oneshot::Receiver<std::io::Result<()>>,
    deadline: Instant,
    limit: Duration,
}

impl PendingWrite {
    pub(super) async fn written(self) -> std::io::Result<()> {
        tokio::time::timeout_at(self.deadline, self.outcome)
            .await
            .map_err(|_| {
                InputStalled {
                    queued: true,
                    limit: self.limit,
                }
                .into_error()
            })?
            .map_err(|_| writer_stopped())?
    }
}

#[derive(Debug)]
struct InputStalled {
    queued: bool,
    limit: Duration,
}

impl InputStalled {
    fn into_error(self) -> std::io::Error {
        std::io::Error::new(std::io::ErrorKind::TimedOut, self)
    }
}

impl std::fmt::Display for InputStalled {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let limit = self.limit.as_secs_f64();
        if self.queued {
            write!(
                formatter,
                "Claude has not read its input for {limit} s, so delivery is unconfirmed; the input stays queued and reaches Claude if it resumes. A macOS permission prompt on the host can cause this"
            )
        } else {
            write!(
                formatter,
                "Claude has not read its input for {limit} s and its input queue is full, so this input was not delivered. A macOS permission prompt on the host can cause this"
            )
        }
    }
}

impl std::error::Error for InputStalled {}

pub(super) struct PreparedControl {
    request_id: String,
    raw: Vec<u8>,
}

impl PreparedControl {
    pub(super) fn request_id(&self) -> &str {
        &self.request_id
    }
}

#[derive(Serialize)]
struct ControlFrame<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    request_id: &'a str,
    request: &'a Value,
}

#[derive(Serialize)]
struct ControlCancelFrame<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    request_id: &'a str,
}

pub(super) struct PreparedInput {
    input: ClaudeUserInput,
    raw: Vec<u8>,
}

#[derive(Serialize)]
struct InputFrame<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    uuid: &'a str,
    parent_tool_use_id: (),
    message: InputMessage<'a>,
    #[serde(rename = "isSynthetic", skip_serializing_if = "Option::is_none")]
    is_synthetic: Option<bool>,
    #[serde(rename = "shouldQuery", skip_serializing_if = "Option::is_none")]
    should_query: Option<bool>,
}

#[derive(Serialize)]
struct InputMessage<'a> {
    role: &'static str,
    content: ClaudeContent<'a>,
}

fn frame_bytes<T: Serialize + ?Sized>(frame: &T) -> std::io::Result<Vec<u8>> {
    if crate::wire::json::encoded_len_at_most(frame, MAX_WEBSOCKET_BYTES - 1)
        .map_err(std::io::Error::other)?
        .is_none()
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            CapacityExceeded {
                resource: "input frame bytes",
                limit: MAX_WEBSOCKET_BYTES,
            },
        ));
    }
    let mut raw = serde_json::to_vec(frame)?;
    raw.push(b'\n');
    Ok(raw)
}

fn writer_stopped() -> std::io::Error {
    std::io::Error::new(
        std::io::ErrorKind::BrokenPipe,
        "the Claude input writer has stopped",
    )
}

struct FramedInput<W> {
    writer: W,
    unconsumed: UnconsumedInputs,
}

async fn write_until_failure<W: AsyncWrite + Unpin>(
    mut stream: FramedInput<W>,
    mut queue: mpsc::Receiver<Submission>,
    cancel: CancellationToken,
) {
    while let Some(submission) = cancel.run_until_cancelled(queue.recv()).await.flatten() {
        let Some(result) = cancel
            .run_until_cancelled(stream.write(&submission.frame))
            .await
        else {
            return;
        };
        let failed = result.is_err();
        let _ = submission.written.send(result);
        if failed {
            return;
        }
    }
}

impl<W: AsyncWrite + Unpin> FramedInput<W> {
    async fn write(&mut self, frame: &Frame) -> std::io::Result<()> {
        match frame {
            Frame::Input(prepared) => {
                let written = self.write_raw(&prepared.raw).await;
                if written.is_err()
                    && let Some(id) = &prepared.input.client_id
                {
                    self.unconsumed.remove(id);
                }
                written
            }
            Frame::Control(prepared) => self.write_raw(&prepared.raw).await,
        }
    }

    async fn write_raw(&mut self, raw: &[u8]) -> std::io::Result<()> {
        self.writer.write_all(raw).await?;
        self.writer.flush().await
    }
}

impl ClaudeSupervisor {
    pub(super) fn input_stalled(
        &self,
        thread_id: &str,
        process_group_id: i32,
        operation: &str,
        error: std::io::Error,
    ) -> super::TurnStartError {
        warn!(thread_id, pid = process_group_id, operation, %error, "Claude is not reading its input");
        self.journal.runtime(
            "input_stalled",
            serde_json::json!({"threadId":thread_id,"pid":process_group_id,"operation":operation}),
        );
        error.into()
    }

    pub(super) async fn retire_after_write_failure(
        &self,
        thread_id: &str,
        process_group_id: i32,
        message: &str,
    ) {
        self.terminate_group(Pid::from_raw(process_group_id)).await;
        self.fail_runtime(
            thread_id,
            process_group_id,
            "failed",
            Some(message.to_owned()),
        )
        .await;
    }
}

#[cfg(test)]
mod capacity_tests {
    use super::*;
    use crate::providers::claude::input::ClaudeImage;
    use serde_json::json;

    #[tokio::test]
    async fn input_frame_capacity_rejects_image_expansion_before_the_queue_and_keeps_writer_usable()
    {
        let data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO3A3ioAAAAASUVORK5CYII=";
        let count = 200_000;
        let item = json!({"type":"image","url":format!("data:image/png;base64,{data}")});
        let inbound_bytes = (serde_json::to_vec(&item).unwrap().len() + 1) * count + 1024;
        assert!(inbound_bytes < MAX_WEBSOCKET_BYTES);
        let input = ClaudeUserInput {
            images: vec![
                ClaudeImage {
                    media_type: "image/png".into(),
                    base64_data: data.into()
                };
                count
            ],
            ..ClaudeUserInput::text("")
        };
        let writer = InputWriter::spawn(tokio::io::sink());
        let error = writer
            .send_input(&input)
            .await
            .expect_err("expanded frame must be refused before admission");
        let capacity = error
            .get_ref()
            .unwrap()
            .downcast_ref::<crate::providers::claude::capacity::CapacityExceeded>()
            .unwrap();
        assert_eq!(capacity.resource, "input frame bytes");
        assert_eq!(capacity.limit, MAX_WEBSOCKET_BYTES);
        let rpc = crate::rpc::error::RpcError::from(super::super::TurnStartError::from(error));
        assert_eq!(rpc.code, crate::rpc::error::RpcCode::Capacity);
        assert_eq!(
            rpc.response(&json!(7))["error"]["data"],
            json!({"kind":"capacity", "retryable":false, "resource":"input frame bytes", "limit":MAX_WEBSOCKET_BYTES})
        );
        assert!(writer.unconsumed().take(&["absent"]).is_empty());
        let small = ClaudeUserInput {
            client_id: Some("healthy".into()),
            ..ClaudeUserInput::text("hello")
        };
        writer.send_input(&small).await.unwrap();
        assert_eq!(writer.unconsumed().take(&["healthy"]), vec!["healthy"]);
    }
}
