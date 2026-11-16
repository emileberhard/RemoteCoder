use serde_json::{Value, json};
use std::io::Write;
use std::path::Path;
use std::time::Duration;

const REMOTE_CODER_CONTEXT: &str = "\
You are working in RemoteCoder. The user can switch between text chat and live \
voice at any time while the same task continues. Your assistant text reaches \
both surfaces; a voice listener cannot see tool output or thinking.\n\
Before using tools, say briefly what you will do. During longer work, write a \
short assistant text update between tool phases, roughly every 30 seconds, \
with a concrete finding, decision, completed step, or next action. When the \
user asks for status, answer at the next opportunity before continuing the \
work. Keep the original task moving after that answer.\n\
Text you write between tool calls reaches the user only as a short summary. \
When they need something exactly as written before your final answer, such as \
code, a command or an exact value, send it with SendUserMessage. Keep routine \
updates as plain text.\n\
Spoken input arrives in <realtime_delegation>: <input> is the user's request; \
<transcript_delta> is recent call context. Treat spoken and typed guidance as \
part of the same conversation.\n\
Lead your final answer with a self-contained, conversational account of the \
result and any remaining work. Put code, raw URLs, tables, and long identifiers \
after that lead when needed for the written chat.\n\
When the user says goodbye, asks to hang up or asks whether the call ended, \
call end_voice_call at once without writing anything; the voice has already \
said goodbye.";

pub(crate) fn hooks(executable: &Path, mcp_config: &Path) -> Value {
    json!([{"hooks":[{
        "type":"command", "command":executable, "timeout":10,
        "args":["claude-session-context", "--mcp-config", mcp_config]
    }]}])
}

pub(crate) async fn run(mcp_config: &Path) -> i32 {
    let links = super::runtime_callback::post(
        mcp_config,
        "/mcp/session-context",
        &json!({}),
        Duration::from_secs(2),
    )
    .await;
    let links = links
        .as_ref()
        .and_then(|response| response["conversationLinks"].as_str());
    match writeln!(std::io::stdout(), "{}", output(links)) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

fn output(conversation_links: Option<&str>) -> Value {
    let context = match conversation_links {
        Some(links) => format!("{REMOTE_CODER_CONTEXT}\n{links}"),
        None => REMOTE_CODER_CONTEXT.to_owned(),
    };
    json!({"hookSpecificOutput":{
        "hookEventName":"SessionStart",
        "additionalContext":context,
    }})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_session_start_receives_the_context_from_the_gateway_executable() {
        let hooks = hooks(
            Path::new("/fixture path/gateway"),
            Path::new("/private path/mcp.json"),
        );
        assert!(hooks[0].get("matcher").is_none());
        assert_eq!(hooks[0]["hooks"][0]["command"], "/fixture path/gateway");
        assert_eq!(
            hooks[0]["hooks"][0]["args"],
            json!([
                "claude-session-context",
                "--mcp-config",
                "/private path/mcp.json"
            ])
        );
        assert_eq!(
            output(None)["hookSpecificOutput"]["hookEventName"],
            "SessionStart"
        );
        assert_eq!(
            output(None)["hookSpecificOutput"]["additionalContext"],
            REMOTE_CODER_CONTEXT
        );
        assert_eq!(
            output(Some("links"))["hookSpecificOutput"]["additionalContext"],
            format!("{REMOTE_CODER_CONTEXT}\nlinks")
        );
    }
}
