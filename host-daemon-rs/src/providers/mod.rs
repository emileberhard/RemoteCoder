use serde::{Deserialize, Serialize};

pub mod claude;
pub mod codex;
pub(crate) mod router;

/// Which agent surface a call arrived on. Recorded on every journal line so a
/// dispatch can be traced back to the thread that made it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Provider {
    Codex,
    Claude,
}

impl Provider {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Provider::Claude => "claude",
            Provider::Codex => "codex",
        }
    }
}
