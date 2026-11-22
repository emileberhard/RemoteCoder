use serde_json::{Value, json};
use std::io::Write;
use std::path::Path;
use std::time::Duration;

const REMOTE_CODER_CONTEXT: &str = concat!(
    "\
You are working in RemoteCoder. The user can switch between text chat and live \
voice at any time while the same task continues. Your assistant text reaches \
both surfaces; a voice listener cannot see tool output or thinking.\n\
Before using tools on a typed request, say briefly what you will do. During longer work, write a \
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
",
    include_str!("../../../prompts/voice-call-agent.md")
);

pub(crate) fn conversation_hooks(executable: &Path, mcp_config: &Path) -> Value {
    json!([{"hooks":[
        {"type":"command", "command":executable, "timeout":10, "args":["claude-session-context"]},
        links_hook(executable, mcp_config),
    ]}])
}

pub(crate) fn job_hooks(executable: &Path, mcp_config: &Path) -> Value {
    json!([{"hooks":[links_hook(executable, mcp_config)]}])
}

fn links_hook(executable: &Path, mcp_config: &Path) -> Value {
    json!({
        "type":"command", "command":executable, "timeout":10,
        "args":["claude-conversation-links", "--mcp-config", mcp_config]
    })
}

pub(crate) fn run() -> i32 {
    match writeln!(std::io::stdout(), "{}", output()) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

pub(crate) async fn run_conversation_links(mcp_config: &Path) -> i32 {
    let response = super::runtime_callback::post(
        mcp_config,
        "/mcp/conversation-links",
        &json!({}),
        Duration::from_secs(2),
    )
    .await;
    let Some(links) = response
        .as_ref()
        .and_then(|response| response["conversationLinks"].as_str())
    else {
        return 0;
    };
    match writeln!(std::io::stdout(), "{}", hook_output(links)) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

fn hook_output(context: &str) -> Value {
    json!({"hookSpecificOutput":{
        "hookEventName":"SessionStart",
        "additionalContext":context,
    }})
}

fn output() -> Value {
    hook_output(REMOTE_CODER_CONTEXT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_session_start_receives_the_context_from_the_gateway_executable() {
        let executable = Path::new("/fixture path/gateway");
        let config = Path::new("/private path/mcp.json");
        let links = json!([
            "claude-conversation-links",
            "--mcp-config",
            "/private path/mcp.json"
        ]);
        let conversation = conversation_hooks(executable, config);
        assert!(conversation[0].get("matcher").is_none());
        let hooks = conversation[0]["hooks"].as_array().unwrap();
        assert_eq!(hooks.len(), 2);
        assert_eq!(hooks[0]["command"], "/fixture path/gateway");
        assert_eq!(hooks[0]["args"], json!(["claude-session-context"]));
        assert_eq!(hooks[1]["args"], links);
        let job = job_hooks(executable, config);
        assert_eq!(job[0]["hooks"].as_array().unwrap().len(), 1);
        assert_eq!(job[0]["hooks"][0]["args"], links);
        assert_eq!(
            output()["hookSpecificOutput"]["hookEventName"],
            "SessionStart"
        );
        assert_eq!(
            output()["hookSpecificOutput"]["additionalContext"],
            REMOTE_CODER_CONTEXT
        );
    }
}
