pub mod claude;
pub(crate) mod client;
pub(crate) mod envelope;
pub(crate) mod jobs;
pub mod mcp;
pub mod tools;

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum State {
    Working,
    Waiting,
    Completed,
    Interrupted,
    Failed,
    Unknown,
}

impl State {
    pub(crate) fn is_running(&self) -> bool {
        matches!(self, Self::Working | Self::Waiting)
    }

    pub(crate) fn may_be_running(&self) -> bool {
        self.is_running() || *self == Self::Unknown
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Capabilities {
    pub inspect: bool,
    pub open_conversation: bool,
    pub message: bool,
    pub continue_work: bool,
    pub stop: bool,
    pub ask_parent: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Agent {
    pub id: String,
    pub parent_id: Option<String>,
    pub owner_thread_id: String,
    pub thread_id: Option<String>,
    pub provider: String,
    pub source: String,
    pub title: String,
    pub model: Option<String>,
    pub state: State,
    pub capabilities: Capabilities,
    pub execution_id: Option<String>,
    pub last_active_at: Option<i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Message {
    pub role: String,
    pub text: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Output {
    pub messages: Vec<Message>,
    pub truncated: bool,
}

impl Output {
    pub(crate) fn push(&mut self, role: &str, text: &str) {
        let bounded: String = text.chars().take(16000).collect();
        self.truncated |= bounded.len() < text.len();
        self.messages.push(Message {
            role: role.into(),
            text: bounded,
        });
        while self.messages.len() > 100
            || self
                .messages
                .iter()
                .map(|message| message.text.len())
                .sum::<usize>()
                > 256 * 1024
        {
            self.messages.remove(0);
            self.truncated = true;
        }
    }
}
