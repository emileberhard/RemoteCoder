use super::Gateway;
use anyhow::{Context, Result};
use serde_json::{Value, json};

pub(super) fn fork_note(source: &Value) -> Result<String> {
    let title = source["name"]
        .as_str()
        .filter(|name| !name.is_empty())
        .or_else(|| source["preview"].as_str())
        .unwrap_or("(untitled)");
    let cwd = source["cwd"].as_str().context("fork source has no cwd")?;
    Ok(format!(
        "RemoteCoder note: this conversation is a fork of \"{title}\". Its earlier history was copied from that conversation, which continues separately and may still be working in {cwd}."
    ))
}

impl Gateway {
    pub(super) async fn note_client_fork(&self, source_id: &str, result: &Value) {
        let target = result.pointer("/thread/id").and_then(Value::as_str);
        let injected = async {
            let thread = target.context("fork response has no thread id")?;
            let source = self.call_control("thread/read", json!({"threadId": source_id, "includeTurns": false})).await?;
            let note = fork_note(&source["thread"])?;
            self.call_control("thread/inject_items", json!({"threadId": thread, "items": [{
                "type": "message", "role": "developer", "content": [{"type": "input_text", "text": note}]
            }]})).await?;
            Ok::<_, anyhow::Error>(())
        }.await;
        if let Err(error) = injected {
            self.journal.runtime("fork_note_failed", json!({"sourceThreadId": source_id, "threadId": target, "error": format!("{error:#}")}));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unnamed_source_uses_its_preview() {
        let source = json!({"name":null,"preview":"Find the lost draft","cwd":"/work"});
        assert_eq!(
            fork_note(&source).unwrap(),
            "RemoteCoder note: this conversation is a fork of \"Find the lost draft\". Its earlier history was copied from that conversation, which continues separately and may still be working in /work."
        );
    }
}
