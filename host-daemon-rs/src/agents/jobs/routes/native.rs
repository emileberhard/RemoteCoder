use std::collections::HashMap;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc, oneshot};

use crate::agents::jobs::model::{
    ConversationIdentity, MAX_JOB_BYTES, MAX_PROMPT_BYTES, Provider, ProviderHome,
};
use crate::platform::process::{ProcessInstance, identify};
use crate::providers::claude::conversation_index::delivery_uuid;

const MAX_ROUTES: usize = 256;
const ROUTE_QUEUE: usize = 16;
const QUEUED_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum NativeDeliveryState {
    Submitted,
    Uncertain { reason: String },
    Unreachable { reason: String },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(try_from = "MessageFields", into = "MessageFields")]
pub(crate) struct NativeMessage(MessageFields);

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MessageFields {
    conversation: ConversationIdentity,
    delivery_id: String,
    input_id: String,
    fingerprint: String,
    text: String,
}

impl NativeMessage {
    pub(crate) fn new(
        conversation: ConversationIdentity,
        delivery_id: String,
        text: String,
    ) -> Result<Self> {
        let fields = MessageFields {
            input_id: delivery_uuid(&conversation.thread_id, &delivery_id),
            fingerprint: crate::ids::sha256_hex(text.as_bytes()),
            conversation,
            delivery_id,
            text,
        };
        Self::try_from(fields).map_err(anyhow::Error::msg)
    }

    pub(crate) fn conversation(&self) -> &ConversationIdentity {
        &self.0.conversation
    }
    pub(crate) fn input_id(&self) -> &str {
        &self.0.input_id
    }
    pub(crate) fn frame(&self) -> Result<Vec<u8>> {
        let mut bytes = serde_json::to_vec(&serde_json::json!({
            "type":"user", "uuid":self.input_id(),
            "message":{"role":"user", "content":self.0.text}
        }))?;
        ensure!(
            bytes.len() < MAX_JOB_BYTES as usize,
            "Claude native message exceeds its transport capacity"
        );
        bytes.push(b'\n');
        Ok(bytes)
    }
}

impl TryFrom<MessageFields> for NativeMessage {
    type Error = String;

    fn try_from(fields: MessageFields) -> std::result::Result<Self, Self::Error> {
        let valid = valid_conversation(&fields.conversation)
            && crate::providers::claude::session_uuid_from_thread_id(
                &fields.conversation.thread_id,
            )
            .is_some()
            && !fields.delivery_id.trim().is_empty()
            && fields.delivery_id.len() <= 256
            && !fields.delivery_id.chars().any(char::is_control)
            && !fields.text.trim().is_empty()
            && fields.text.len() <= MAX_PROMPT_BYTES
            && fields.input_id
                == delivery_uuid(&fields.conversation.thread_id, &fields.delivery_id)
            && fields.fingerprint == crate::ids::sha256_hex(fields.text.as_bytes());
        if !valid {
            return Err("Claude native delivery identity or payload is invalid".into());
        }
        let message = Self(fields);
        message.frame().map_err(|error| error.to_string())?;
        Ok(message)
    }
}

impl From<NativeMessage> for MessageFields {
    fn from(message: NativeMessage) -> Self {
        message.0
    }
}

pub(crate) struct NativeDeliveryRequest {
    pub message: NativeMessage,
    pub reply: oneshot::Sender<NativeDeliveryState>,
    _bytes: OwnedSemaphorePermit,
}

#[derive(Clone)]
pub(crate) struct NativeRoutes {
    state: Arc<Mutex<State>>,
    bytes: Arc<Semaphore>,
}

#[derive(Default)]
struct State {
    next_epoch: u64,
    entries: HashMap<ConversationIdentity, Route>,
}

struct Route {
    epoch: u64,
    owner: ProcessInstance,
    sender: mpsc::Sender<NativeDeliveryRequest>,
}

pub(crate) struct NativeRouteLease {
    state: Weak<Mutex<State>>,
    conversation: ConversationIdentity,
    epoch: u64,
}

impl Default for NativeRoutes {
    fn default() -> Self {
        Self {
            state: Arc::default(),
            bytes: Arc::new(Semaphore::new(QUEUED_BYTES)),
        }
    }
}

impl NativeRoutes {
    pub(crate) fn register(
        &self,
        conversation: ConversationIdentity,
        owner: ProcessInstance,
    ) -> Result<(NativeRouteLease, mpsc::Receiver<NativeDeliveryRequest>)> {
        ensure!(
            valid_conversation(&conversation) && owner.pid > 0 && owner.started_micros > 0,
            "Claude native route requires an exact process instance"
        );
        let mut state = self.state.lock().expect("native route registry poisoned");
        state.entries.retain(|_, route| !route.sender.is_closed());
        ensure!(
            state.entries.contains_key(&conversation) || state.entries.len() < MAX_ROUTES,
            "Claude native parent route capacity reached"
        );
        ensure!(
            state
                .entries
                .get(&conversation)
                .is_none_or(|route| route.owner == owner),
            "Claude native conversation already has a different process owner"
        );
        let epoch = state
            .next_epoch
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("Claude native route generation exhausted"))?;
        state.next_epoch = epoch;
        let (sender, receiver) = mpsc::channel(ROUTE_QUEUE);
        state.entries.insert(
            conversation.clone(),
            Route {
                epoch,
                owner,
                sender,
            },
        );
        Ok((
            NativeRouteLease {
                state: Arc::downgrade(&self.state),
                conversation,
                epoch,
            },
            receiver,
        ))
    }

    pub(crate) async fn deliver(
        &self,
        conversation: &ConversationIdentity,
        message: NativeMessage,
    ) -> NativeDeliveryState {
        if message.conversation() != conversation {
            return unreachable("Claude native delivery targets a different conversation");
        }
        let route = self
            .state
            .lock()
            .expect("native route registry poisoned")
            .entries
            .get(conversation)
            .map(|route| (route.epoch, route.owner, route.sender.clone()));
        let Some((epoch, owner, sender)) = route else {
            return unreachable("Claude native parent has no live registered holder");
        };
        let alive = tokio::task::spawn_blocking(move || identify(owner.pid)).await;
        if !matches!(alive, Ok(Ok(Some(identity))) if identity.started_micros == owner.started_micros)
        {
            return unreachable("Claude native parent process identity is no longer live");
        }
        if !self.current(conversation, epoch) {
            return unreachable("Claude native parent registration changed before submission");
        }
        let size = match serde_json::to_vec(&message) {
            Ok(bytes) => bytes.len(),
            Err(_) => return unreachable("Claude native message could not be encoded"),
        };
        let Ok(bytes) = Arc::clone(&self.bytes).try_acquire_many_owned(size as u32) else {
            return unreachable("Claude native transport capacity reached before submission");
        };
        let (reply, result) = oneshot::channel();
        if sender
            .try_send(NativeDeliveryRequest {
                message,
                reply,
                _bytes: bytes,
            })
            .is_err()
        {
            return unreachable(
                "Claude native parent transport is full or disconnected before submission",
            );
        }
        match tokio::time::timeout(Duration::from_secs(10), result).await {
            Ok(Ok(result)) if self.current(conversation, epoch) => result,
            _ => NativeDeliveryState::Uncertain { reason: "Claude native holder did not confirm this exact submission; reconcile its input UUID before any retry".into() },
        }
    }

    fn current(&self, conversation: &ConversationIdentity, epoch: u64) -> bool {
        self.state
            .lock()
            .expect("native route registry poisoned")
            .entries
            .get(conversation)
            .is_some_and(|route| route.epoch == epoch)
    }
}

impl Drop for NativeRouteLease {
    fn drop(&mut self) {
        if let Some(state) = self.state.upgrade() {
            let mut state = state.lock().expect("native route registry poisoned");
            if state
                .entries
                .get(&self.conversation)
                .is_some_and(|route| route.epoch == self.epoch)
            {
                state.entries.remove(&self.conversation);
            }
        }
    }
}

fn unreachable(reason: &str) -> NativeDeliveryState {
    NativeDeliveryState::Unreachable {
        reason: reason.into(),
    }
}

fn valid_conversation(conversation: &ConversationIdentity) -> bool {
    conversation.provider == Provider::Claude
        && matches!(&conversation.provider_home, ProviderHome::Known { path } if path.is_absolute() && path.as_os_str().len() <= 4096)
        && crate::providers::claude::session_uuid_from_thread_id(&conversation.thread_id).is_some()
}
