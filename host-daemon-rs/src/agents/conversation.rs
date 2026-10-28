use std::path::Path;

use anyhow::{Context, Result, ensure};
use serde_json::Value;

use super::jobs::model::{ConversationIdentity, Provider, ProviderHome};

pub(crate) fn conversation_from_header(header: &Value) -> Result<ConversationIdentity> {
    let thread_id = header["id"]
        .as_str()
        .context("Conversation has no exact ID")?;
    let provider = if thread_id.starts_with("claude_") {
        Provider::Claude
    } else {
        Provider::Codex
    };
    let path = Path::new(
        header["path"]
            .as_str()
            .context("Conversation has no authoritative history path")?,
    );
    ensure!(
        path.is_absolute(),
        "Conversation history path is not absolute"
    );
    let directory = match provider {
        Provider::Claude => "projects",
        Provider::Codex => "sessions",
    };
    let home = path
        .ancestors()
        .find(|path| {
            path.file_name().is_some_and(|name| {
                name == directory || (provider == Provider::Codex && name == "archived_sessions")
            })
        })
        .and_then(Path::parent)
        .context("Conversation history path does not identify a provider home")?;
    Ok(ConversationIdentity {
        provider,
        provider_home: ProviderHome::Known {
            path: home.to_owned(),
        },
        thread_id: thread_id.to_owned(),
    })
}
