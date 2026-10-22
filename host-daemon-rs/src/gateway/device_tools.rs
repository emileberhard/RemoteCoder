use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use base64::Engine;
use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::oneshot;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use super::{ClientCommand, ClientTx, Gateway};
use crate::agents::tools::{Caller, ToolContent, ToolOutcome};
use crate::files::upload::UploadStore;
use crate::rpc::{RpcError, RpcResult, error::RpcCode};

const MAX_CONNECTIONS: usize = 256;
const MAX_DRIVERS: usize = 4096;
const MAX_OPERATIONS: usize = 8;
const DEADLINE: Duration = Duration::from_secs(60);
const UNKNOWN_DRIVER: &str = "The gateway cannot tell which device sent this thread's latest message. Ask the user to send any message from the RemoteCoder iPhone app to enable the camera.";
const NO_DRIVER: &str = "This turn did not come from the RemoteCoder iPhone app, so iPhone tools can't run. If a photo is needed, ask the user to send their next message from the iPhone.";
const OFFLINE: &str = "The user's iPhone is not connected to RemoteCoder right now.";
const UNSUPPORTED: &str =
    "The RemoteCoder app on The user's iPhone doesn't support take_photo; it needs an update.";
const BUSY: &str = "Another iPhone tool is running. Try again when it finishes.";
const UNKNOWN: &str = "The iPhone did not answer in time; whether a photo was taken is unknown.";
const CANCELLED: &str = "The iPhone tool was cancelled because its turn ended.";

#[cfg(test)]
mod tests;

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Camera {
    #[default]
    Back,
    Front,
    Both,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Lens {
    #[default]
    Wide,
    UltraWide,
    Telephoto,
}

impl Camera {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Back => "back",
            Self::Front => "front",
            Self::Both => "both",
        }
    }
}

impl Lens {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Wide => "wide",
            Self::UltraWide => "ultra_wide",
            Self::Telephoto => "telephoto",
        }
    }
}

#[derive(Debug, Default, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PhotoArguments {
    #[serde(default)]
    pub camera: Camera,
    #[serde(default)]
    pub lens: Lens,
}

impl PhotoArguments {
    pub(crate) fn validate(&self) -> Result<(), &'static str> {
        if self.camera == Camera::Front && self.lens != Lens::Wide {
            return Err(
                "take_photo's front camera supports only lens=wide. Use camera=back or both for ultra_wide or telephoto.",
            );
        }
        Ok(())
    }

    fn captures(&self) -> Vec<(Camera, Lens)> {
        match self.camera {
            Camera::Back => vec![(Camera::Back, self.lens)],
            Camera::Front => vec![(Camera::Front, Lens::Wide)],
            Camera::Both => vec![(Camera::Back, self.lens), (Camera::Front, Lens::Wide)],
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Declaration {
    tools: Vec<DeclaredTool>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DeclaredTool {
    name: String,
    version: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Outcome {
    Succeeded,
    Refused,
    Failed,
    Cancelled,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Refusal {
    ForegroundRequired,
    PermissionDenied,
    CameraUnavailable,
    LensUnavailable,
    Busy,
    InvalidArguments,
    DeadlinePassed,
}

impl Refusal {
    fn text(&self) -> &'static str {
        match self {
            Self::ForegroundRequired => {
                "RemoteCoder must be open on the iPhone screen to use the camera. Ask the user to unlock the phone and open the app."
            }
            Self::PermissionDenied => "Camera access for RemoteCoder is off in iOS Settings.",
            Self::CameraUnavailable => "The requested iPhone camera is unavailable.",
            Self::LensUnavailable => "The requested iPhone camera lens is unavailable.",
            Self::Busy => BUSY,
            Self::InvalidArguments => "The iPhone rejected take_photo's arguments.",
            Self::DeadlinePassed => {
                "The iPhone refused take_photo because its deadline had passed; no photo was taken by this operation."
            }
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DeviceResult {
    operation_id: String,
    outcome: Outcome,
    reason: Option<Refusal>,
    detail: Option<String>,
    #[serde(default)]
    content: Vec<ToolContent>,
    #[serde(default)]
    originals: Vec<PhotoOriginal>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct PhotoOriginal {
    path: PathBuf,
    sha256: String,
    bytes: u64,
    camera: Camera,
    lens: Lens,
    width: u32,
    height: u32,
}

impl DeviceResult {
    fn validate(&self, arguments: &PhotoArguments) -> Result<Vec<(u32, u32)>, &'static str> {
        if self.operation_id.len() > 128
            || self.detail.as_ref().is_some_and(|value| value.len() > 4096)
            || self.originals.len() > 2
        {
            return Err("Device result exceeds its limits");
        }
        if matches!(self.outcome, Outcome::Refused) != self.reason.is_some() {
            return Err("A refusal requires a reason, and other outcomes must omit it");
        }
        if !matches!(self.outcome, Outcome::Succeeded) {
            if !self.content.is_empty() || !self.originals.is_empty() {
                return Err("Only a successful device result may contain photos");
            }
            return Ok(Vec::new());
        }
        let captures = arguments.captures();
        if self.content.len() != captures.len() {
            return Err(
                "A successful take_photo result must contain exactly one JPEG image per capture, back then front for both, and no text",
            );
        }
        let mut dimensions = Vec::new();
        let mut encoded_bytes = 0;
        for content in &self.content {
            match content {
                ToolContent::Image { mime_type, base64 } if mime_type == "image/jpeg" => {
                    encoded_bytes += base64.len();
                    if encoded_bytes > 3 * 1024 * 1024 {
                        return Err("Device images exceed 3 MiB of encoded data");
                    }
                    let bytes = base64::engine::general_purpose::STANDARD
                        .decode(base64)
                        .map_err(|_| "Invalid image base64")?;
                    let (width, height) = jpeg_dimensions(&bytes).ok_or("Invalid JPEG image")?;
                    if width.max(height) > 1568 {
                        return Err("Model photos must have a long edge of at most 1568 pixels");
                    }
                    dimensions.push((width, height));
                }
                _ => {
                    return Err(
                        "take_photo content must contain only image/jpeg images; put upload failures in detail",
                    );
                }
            }
        }
        let mut named = Vec::new();
        for original in &self.originals {
            let identity = (original.camera, original.lens);
            if !captures.contains(&identity)
                || named.contains(&identity)
                || original.width == 0
                || original.height == 0
                || original.path.as_os_str().len() > 4096
            {
                return Err("Original metadata does not match the requested cameras");
            }
            named.push(identity);
        }
        Ok(dimensions)
    }
}

fn jpeg_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    if !bytes.starts_with(&[0xff, 0xd8]) || !bytes.ends_with(&[0xff, 0xd9]) {
        return None;
    }
    let mut position = 2;
    while position + 4 <= bytes.len() {
        if bytes[position] != 0xff {
            return None;
        }
        while bytes.get(position) == Some(&0xff) {
            position += 1;
        }
        let marker = *bytes.get(position)?;
        position += 1;
        if matches!(marker, 0xd8 | 0xd9 | 0x01 | 0xd0..=0xd7) {
            continue;
        }
        if marker == 0xda {
            return None;
        }
        let length =
            u16::from_be_bytes([*bytes.get(position)?, *bytes.get(position + 1)?]) as usize;
        if length < 2 || position.checked_add(length)? > bytes.len() {
            return None;
        }
        if matches!(marker, 0xc0..=0xc3 | 0xc5..=0xc7 | 0xc9..=0xcb | 0xcd..=0xcf) {
            if length < 8 {
                return None;
            }
            let height = u16::from_be_bytes([bytes[position + 3], bytes[position + 4]]) as u32;
            let width = u16::from_be_bytes([bytes[position + 5], bytes[position + 6]]) as u32;
            return (width > 0 && height > 0).then_some((width, height));
        }
        position += length;
    }
    None
}

struct ValidatedResult {
    result: DeviceResult,
    dimensions: Vec<(u32, u32)>,
}

struct Connection {
    client: ClientTx,
    tools: Option<HashMap<String, u32>>,
}

struct Pending {
    thread: String,
    turn: String,
    installation: String,
    client: ClientTx,
    arguments: PhotoArguments,
    deadline: Instant,
    cancelled: CancellationToken,
    result: Option<oneshot::Sender<Result<ValidatedResult, String>>>,
}

enum Driver {
    Installation(String),
    Cleared,
}

#[derive(Default)]
struct State {
    connections: HashMap<u64, Connection>,
    drivers: IndexMap<String, Driver>,
    pending: HashMap<String, Pending>,
    ended_turns: IndexMap<(String, String), Instant>,
}

pub(crate) struct PhotoStorage {
    uploads: UploadStore,
    library: PathBuf,
}

pub(crate) struct DeviceTools {
    state: Mutex<State>,
    pub(super) photos: Arc<OnceLock<PhotoStorage>>,
    journal: crate::observability::journal::Journal,
}

impl DeviceTools {
    pub(super) fn new(
        photos: Arc<OnceLock<PhotoStorage>>,
        journal: crate::observability::journal::Journal,
    ) -> Self {
        Self {
            photos,
            journal,
            state: Mutex::default(),
        }
    }

    pub(super) fn connected(&self, client: ClientTx) -> Result<(), RpcError> {
        let mut state = self.state.lock().expect("device tools poisoned");
        if state.connections.len() >= MAX_CONNECTIONS {
            return Err(RpcError::new(
                RpcCode::ServerBusy,
                "Too many device tool connections",
            ));
        }
        state.connections.insert(
            client.id,
            Connection {
                client,
                tools: None,
            },
        );
        Ok(())
    }

    pub(super) fn disconnected(&self, client_id: u64) {
        let mut state = self.state.lock().expect("device tools poisoned");
        if let Some(connection) = state.connections.remove(&client_id) {
            connection.client.closed.cancel();
        }
    }

    pub(super) fn declare(&self, client_id: u64, declaration: Declaration) -> RpcResult {
        if declaration.tools.len() > 16
            || declaration
                .tools
                .iter()
                .any(|tool| tool.name.is_empty() || tool.name.len() > 128 || tool.version == 0)
        {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "Invalid device tool declarations",
            ));
        }
        let mut tools = HashMap::new();
        for tool in declaration.tools {
            if tools.insert(tool.name, tool.version).is_some() {
                return Err(RpcError::new(
                    RpcCode::InvalidParams,
                    "Duplicate device tool declaration",
                ));
            }
        }
        let mut state = self.state.lock().expect("device tools poisoned");
        let connection = state
            .connections
            .get_mut(&client_id)
            .ok_or_else(|| RpcError::new(RpcCode::Unavailable, "Device connection closed"))?;
        if connection.client.installation_id.is_none() && !tools.is_empty() {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "Device tools require an installation credential",
            ));
        }
        connection.tools = Some(tools);
        Ok(json!({}))
    }

    pub(super) fn record_input(&self, client_id: u64, method: &str, params: &Value) {
        if !matches!(
            method,
            "turn/start" | "turn/steer" | "claude/message" | "thread/queue/add"
        ) {
            return;
        }
        let Some(thread) = params
            .get("threadId")
            .and_then(Value::as_str)
            .filter(|thread| !thread.is_empty() && thread.len() <= 512)
        else {
            return;
        };
        self.record_driver(client_id, thread);
    }

    pub(super) fn record_driver(&self, client_id: u64, thread: &str) {
        let mut state = self.state.lock().expect("device tools poisoned");
        state.drivers.shift_remove(thread);
        let Some(connection) = state.connections.get(&client_id) else {
            return;
        };
        let installation = connection
            .tools
            .as_ref()
            .is_none_or(|tools| !tools.is_empty())
            .then(|| connection.client.installation_id.clone())
            .flatten();
        if state.drivers.len() >= MAX_DRIVERS {
            state.drivers.shift_remove_index(0);
        }
        let driver = match installation {
            Some(installation) => Driver::Installation(installation),
            None => Driver::Cleared,
        };
        state.drivers.insert(thread.to_string(), driver);
    }

    pub(super) fn turn_ended(&self, thread: &str, turn: &str) {
        let mut state = self.state.lock().expect("device tools poisoned");
        state
            .ended_turns
            .retain(|_, ended| ended.elapsed() < DEADLINE);
        if state.ended_turns.len() >= MAX_DRIVERS {
            state.ended_turns.shift_remove_index(0);
        }
        state
            .ended_turns
            .insert((thread.into(), turn.into()), Instant::now());
        let operations: Vec<_> = state
            .pending
            .iter()
            .filter(|(_, pending)| pending.thread == thread && pending.turn == turn)
            .map(|(id, _)| id.clone())
            .collect();
        for id in operations {
            if let Some(pending) = state.pending.get(&id)
                && pending.result.is_some()
                && !pending.cancelled.is_cancelled()
            {
                pending.cancelled.cancel();
                send_cancel(&self.journal, &pending.client, &id);
            }
        }
    }

    pub(super) fn result(&self, client_id: u64, params: Value) -> RpcResult {
        let operation_id = params
            .get("operationId")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::new(RpcCode::InvalidParams, "operationId is required"))?;
        let mut state = self.state.lock().expect("device tools poisoned");
        let Some(pending) = state.pending.get_mut(operation_id) else {
            return Ok(json!({"accepted": false}));
        };
        if pending.client.id != client_id
            || pending.result.is_none()
            || pending.cancelled.is_cancelled()
            || Instant::now() >= pending.deadline
            || pending.client.closed.is_cancelled()
        {
            return Ok(json!({"accepted": false}));
        }
        let validated = serde_json::from_value::<DeviceResult>(params)
            .map_err(|error| error.to_string())
            .and_then(|result| {
                let dimensions = result
                    .validate(&pending.arguments)
                    .map_err(str::to_string)?;
                Ok(ValidatedResult { result, dimensions })
            });
        let rejection = validated.as_ref().err().cloned();
        let sent = pending
            .result
            .take()
            .expect("pending result sender")
            .send(validated)
            .is_ok();
        match rejection {
            Some(message) => Err(RpcError::new(RpcCode::InvalidParams, message)),
            None => Ok(json!({"accepted": sent})),
        }
    }

    pub(super) async fn invoke(
        self: &Arc<Self>,
        gateway: &Arc<Gateway>,
        caller: &Caller,
        arguments: PhotoArguments,
    ) -> ToolOutcome {
        let (Some(thread), Some(turn)) = (&caller.thread_id, &caller.turn_id) else {
            return ToolOutcome::error(UNKNOWN_DRIVER);
        };
        let operation_id = crate::ids::new_session_uuid();
        let (client, mut receiver, cancelled, deadline) = {
            let mut state = self.state.lock().expect("device tools poisoned");
            if state
                .ended_turns
                .contains_key(&(thread.clone(), turn.clone()))
            {
                return ToolOutcome::error(CANCELLED);
            }
            let installation = match state.drivers.get(thread) {
                Some(Driver::Installation(installation)) => installation.clone(),
                Some(Driver::Cleared) => return ToolOutcome::error(NO_DRIVER),
                None => return ToolOutcome::error(UNKNOWN_DRIVER),
            };
            let live: Vec<_> = state
                .connections
                .values()
                .filter(|connection| {
                    connection.client.installation_id.as_ref() == Some(&installation)
                        && !connection.client.closed.is_cancelled()
                })
                .collect();
            if live.is_empty() {
                return ToolOutcome::error(OFFLINE);
            }
            let Some(connection) = live
                .into_iter()
                .filter(|connection| {
                    connection
                        .tools
                        .as_ref()
                        .and_then(|tools| tools.get("take_photo"))
                        == Some(&1)
                })
                .max_by_key(|connection| connection.client.id)
            else {
                return ToolOutcome::error(UNSUPPORTED);
            };
            let client = connection.client.clone();
            if state.pending.len() >= MAX_OPERATIONS
                || state
                    .pending
                    .values()
                    .any(|pending| pending.installation == installation)
            {
                return ToolOutcome::error(BUSY);
            }
            let deadline = Instant::now() + DEADLINE;
            let cancelled = CancellationToken::new();
            let (sender, receiver) = oneshot::channel();
            state.pending.insert(
                operation_id.clone(),
                Pending {
                    thread: thread.clone(),
                    turn: turn.clone(),
                    installation,
                    client: client.clone(),
                    arguments: arguments.clone(),
                    deadline,
                    cancelled: cancelled.clone(),
                    result: Some(sender),
                },
            );
            (client, receiver, cancelled, deadline)
        };
        let mut operation = Operation {
            owner: Arc::clone(self),
            id: operation_id.clone(),
            finished: false,
        };
        let invoke = json!({"method":"device/tool/invoke", "params":{
            "operationId":operation_id, "tool":"take_photo", "version":1, "arguments":arguments,
            "deadlineUnixMs": (crate::time::unix_seconds() * 1000.0) as u64 + DEADLINE.as_millis() as u64,
        }});
        if gateway
            .send_json_awaiting_capacity(&client, &invoke)
            .await
            .is_err()
        {
            return ToolOutcome::error(OFFLINE);
        }
        gateway.journal().tool("device_sent", json!({"operationId":operation_id,"threadId":thread,"turnId":turn,"clientId":client.id,"tool":"take_photo"}));
        let result = tokio::select! {
            biased;
            _ = cancelled.cancelled() => ToolOutcome::error(CANCELLED),
            result = &mut receiver => match result {
                Ok(Ok(result)) => self.render_result(result, &arguments).await,
                Ok(Err(message)) => ToolOutcome::error(format!("The iPhone returned an invalid take_photo result: {message}. Update the RemoteCoder app before trying again.")),
                Err(_) => ToolOutcome::error(UNKNOWN),
            },
            _ = client.closed.cancelled() => ToolOutcome::error(UNKNOWN),
            _ = tokio::time::sleep_until(deadline) => {
                send_cancel(&self.journal, &client, &operation_id);
                ToolOutcome::error(UNKNOWN)
            },
        };
        operation.finish();
        result
    }

    async fn render_result(
        &self,
        validated: ValidatedResult,
        arguments: &PhotoArguments,
    ) -> ToolOutcome {
        let ValidatedResult { result, dimensions } = validated;
        let detail = result.detail.as_deref().filter(|detail| !detail.is_empty());
        let failure = match result.outcome {
            Outcome::Refused => Some(result.reason.as_ref().expect("validated refusal").text()),
            Outcome::Failed => Some("The iPhone could not take the photo."),
            Outcome::Cancelled => Some("The iPhone cancelled take_photo."),
            Outcome::Succeeded => None,
        };
        if let Some(text) = failure {
            return ToolOutcome::error(match detail {
                Some(detail) => format!("{text} {detail}"),
                None => text.into(),
            });
        }
        let mut content = result.content;
        for ((camera, lens), (width, height)) in arguments.captures().into_iter().zip(dimensions) {
            let original = result
                .originals
                .iter()
                .find(|original| original.camera == camera && original.lens == lens);
            let saved = match (self.photos.get(), original) {
                (Some(storage), Some(original)) => {
                    let moved =
                        match photo_destination(&storage.library, original.camera, original.lens) {
                            Ok((directory, stem)) => {
                                storage
                                    .uploads
                                    .move_verified(
                                        crate::files::upload::StoredUpload {
                                            path: original.path.clone(),
                                            sha256: original.sha256.clone(),
                                            bytes: original.bytes,
                                        },
                                        directory,
                                        stem,
                                    )
                                    .await
                            }
                            Err(error) => Err(error),
                        };
                    moved
                        .map(|path| format!("Full-size original saved at {}.", path.display()))
                        .unwrap_or_else(|error| {
                            format!("Full-size original was not saved: {error:#}.")
                        })
                }
                (None, _) => {
                    "Full-size original was not saved: photo storage is unavailable.".into()
                }
                (_, None) => {
                    "Full-size original was not saved: the iPhone did not upload it.".into()
                }
            };
            let camera_label = match camera {
                Camera::Back => "Back",
                Camera::Front => "Front",
                Camera::Both => unreachable!(),
            };
            content.push(ToolContent::Text {
                text: format!(
                    "{camera_label} {} camera, {width}×{height}. {saved}",
                    lens.name().replace('_', " ")
                ),
            });
        }
        if let Some(detail) = detail {
            content.push(ToolContent::Text {
                text: detail.into(),
            });
        }
        ToolOutcome {
            content,
            is_error: false,
            detail: None,
        }
    }
}

struct Operation {
    owner: Arc<DeviceTools>,
    id: String,
    finished: bool,
}

impl Operation {
    fn finish(&mut self) {
        self.owner
            .state
            .lock()
            .expect("device tools poisoned")
            .pending
            .remove(&self.id);
        self.finished = true;
    }
}

impl Drop for Operation {
    fn drop(&mut self) {
        if !self.finished
            && let Some(pending) = self
                .owner
                .state
                .lock()
                .expect("device tools poisoned")
                .pending
                .remove(&self.id)
            && pending.result.is_some()
        {
            send_cancel(&self.owner.journal, &pending.client, &self.id);
        }
    }
}

fn send_cancel(journal: &crate::observability::journal::Journal, client: &ClientTx, id: &str) {
    let notification = json!({"method":"device/tool/cancel","params":{"operationId":id}});
    let payload = notification.to_string();
    journal.notify_client(
        crate::observability::journal::Source::Gateway,
        client.id,
        &Arc::from(payload.as_str()),
    );
    if client.try_send(ClientCommand::Text(payload)).is_err() {
        client.closed.cancel();
    }
}

impl Gateway {
    pub(crate) async fn invoke_device_photo(
        self: &Arc<Self>,
        caller: &Caller,
        arguments: PhotoArguments,
    ) -> ToolOutcome {
        self.device_tools.invoke(self, caller, arguments).await
    }

    pub(crate) fn configure_device_photos(
        &self,
        uploads: UploadStore,
        library: PathBuf,
    ) -> anyhow::Result<()> {
        self.device_tools
            .photos
            .set(PhotoStorage { uploads, library })
            .map_err(|_| anyhow::anyhow!("Photo storage is already configured"))
    }
}

fn photo_destination(
    library: &std::path::Path,
    camera: Camera,
    lens: Lens,
) -> anyhow::Result<(PathBuf, String)> {
    let seconds = crate::time::unix_millis() / 1000;
    let mut local = std::mem::MaybeUninit::<libc::tm>::uninit();
    anyhow::ensure!(
        !unsafe { libc::localtime_r(&seconds, local.as_mut_ptr()) }.is_null(),
        "local photo date is unavailable"
    );
    let local = unsafe { local.assume_init() };
    let directory = library.join(format!(
        "{:04}-{:02}-{:02}",
        local.tm_year + 1900,
        local.tm_mon + 1,
        local.tm_mday
    ));
    let stem = format!(
        "{:02}{:02}{:02}-{}-{}",
        local.tm_hour,
        local.tm_min,
        local.tm_sec,
        camera.name(),
        lens.name()
    );
    Ok((directory, stem))
}
