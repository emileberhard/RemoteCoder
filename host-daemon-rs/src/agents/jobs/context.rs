use std::collections::VecDeque;

use anyhow::{Context, Result, ensure};
use tokio::sync::Mutex;

use super::model::ConversationIdentity;
use crate::platform::process::ProcessInstance;
use crate::wire::agent_jobs::CapturedContext;

const MAX_CAPTURED_CONTEXTS: usize = 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ProvenCaller {
    pub conversation: ConversationIdentity,
    pub process: ProcessInstance,
    pub turn_id: Option<String>,
    pub tool_call_id: Option<String>,
}

impl ProvenCaller {
    pub(crate) fn same_owner(&self, other: &Self) -> bool {
        self.conversation == other.conversation
            && self.process == other.process
            && self.tool_call_id == other.tool_call_id
    }
}

#[derive(Clone)]
struct Captured {
    id: String,
    caller: ProvenCaller,
}

#[derive(Default)]
pub(crate) struct Contexts(Mutex<VecDeque<Captured>>);

impl Contexts {
    pub(crate) async fn capture(&self, caller: ProvenCaller) -> CapturedContext {
        let mut contexts = self.0.lock().await;
        let previous = contexts
            .iter()
            .position(|saved| saved.caller.same_owner(&caller));
        let id = previous
            .and_then(|position| contexts.remove(position))
            .map(|saved| saved.id)
            .unwrap_or_else(crate::ids::new_session_uuid);
        if contexts.len() == MAX_CAPTURED_CONTEXTS {
            contexts.pop_front();
        }
        let result = CapturedContext {
            context_id: id.clone(),
            provider: caller.conversation.provider,
            thread_id: caller.conversation.thread_id.clone(),
            turn_id: caller.turn_id.clone(),
        };
        contexts.push_back(Captured { id, caller });
        result
    }

    pub(crate) async fn get(&self, id: &str) -> Result<ProvenCaller> {
        ensure!(
            !id.is_empty() && id.len() <= 200,
            "invalid captured caller identity"
        );
        self.0.lock().await.iter().find(|saved| saved.id == id).map(|saved| saved.caller.clone())
            .context("caller context is no longer retained; capture it again from the originating agent before detaching")
    }
}
