use serde_json::{Value, json};
use std::io::Write;
use std::path::Path;

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

pub(crate) fn hooks(executable: &Path) -> Value {
    json!([{"hooks":[{
        "type":"command", "command":executable, "timeout":10,
        "args":["claude-session-context"]
    }]}])
}

pub(crate) fn run() -> i32 {
    match writeln!(std::io::stdout(), "{}", output()) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

fn output() -> Value {
    json!({"hookSpecificOutput":{
        "hookEventName":"SessionStart",
        "additionalContext":REMOTE_CODER_CONTEXT,
    }})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_session_start_receives_the_context_from_the_gateway_executable() {
        let hooks = hooks(Path::new("/fixture path/gateway"));
        assert!(hooks[0].get("matcher").is_none());
        assert_eq!(hooks[0]["hooks"][0]["command"], "/fixture path/gateway");
        assert_eq!(
            hooks[0]["hooks"][0]["args"],
            json!(["claude-session-context"])
        );
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
