//! Claude's native subagents share their enclosing runtime's MCP token. Only
//! the provider's PreToolUse hook supplies their separate agent_id. Denial is
//! local; a failed journal callback can never authorize a child notification.

use serde_json::{Value, json};
use std::{io::Read, path::Path, time::Duration};

pub(crate) const TOOL: &str = "mcp__remotecoder__notify_user";
const MAX_INPUT_BYTES: u64 = 64 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Decision {
    Root,
    Child,
    Unverified,
}

impl Decision {
    pub(crate) fn suppression_reason(&self) -> Option<&'static str> {
        match self {
            Self::Root => None,
            Self::Child => Some("nativeClaudeChild"),
            Self::Unverified => Some("nativeClaudeCallerUnverified"),
        }
    }
}

pub(crate) fn decide(input: &Value, session_id: &str) -> Decision {
    if input["hook_event_name"] != "PreToolUse"
        || input["tool_name"] != TOOL
        || input["session_id"].as_str() != Some(session_id)
    {
        return Decision::Unverified;
    }
    match input.get("agent_id") {
        None => Decision::Root,
        Some(Value::String(id)) if !id.trim().is_empty() => Decision::Child,
        _ => Decision::Unverified,
    }
}

pub(crate) fn validated_executable(path: &Path) -> std::io::Result<std::path::PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    if !path.is_absolute() {
        return Err(std::io::Error::other(
            "notification helper must be absolute",
        ));
    }
    let executable = path.canonicalize()?;
    let metadata = executable.metadata()?;
    if !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0 {
        return Err(std::io::Error::other(
            "notification helper is not executable",
        ));
    }
    Ok(executable)
}

pub(crate) fn hooks(executable: &Path, mcp_config: &Path, session_id: &str) -> Value {
    json!([{
        "matcher":format!("^{TOOL}$"), "hooks":[{
            // Missing/crashed/timed-out helpers leave no proof. MCP dispatch
            // then journals the rejection; only known child/unverified calls
            // exit 2 locally. Exec form keeps paths out of shell interpolation.
            "type":"command", "command":executable, "timeout":30,
            "args":["claude-notification-hook","--mcp-config",mcp_config,"--session-id",session_id]
        }]
    }])
}

/// Executes the installed helper contract without a token, broker or real
/// notification. Health is telemetry only; timeout cannot restart the host.
pub(crate) async fn preflight() -> Value {
    let started = std::time::Instant::now();
    let result = tokio::time::timeout(Duration::from_secs(2), async {
        use tokio::io::AsyncWriteExt;
        let executable = validated_executable(&std::env::current_exe()?)?;
        for child in [false, true] {
            let mut input = json!({"hook_event_name":"PreToolUse","tool_name":TOOL,"session_id":"notification-preflight"});
            if child { input["agent_id"] = json!("notification-preflight-child"); }
            let mut process = tokio::process::Command::new(&executable)
                .args(["claude-notification-hook", "--mcp-config", "/dev/null", "--session-id", "notification-preflight"])
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .kill_on_drop(true).spawn()?;
            let mut stdin = process.stdin.take().ok_or_else(|| std::io::Error::other("helper input unavailable"))?;
            stdin.write_all(input.to_string().as_bytes()).await?;
            stdin.shutdown().await?;
            drop(stdin);
            let status = process.wait().await?;
            if status.code() != Some(if child { 2 } else { 0 }) {
                return Err(std::io::Error::other("helper contract mismatch"));
            }
        }
        Ok::<_, std::io::Error>(())
    }).await;
    let reason = match result {
        Ok(Ok(())) => None,
        Ok(Err(_)) => Some("nativeClaudeHookUnavailable"),
        Err(_) => Some("nativeClaudeHookPreflightTimeout"),
    };
    json!({"status":if reason.is_none() { "available" } else { "unavailable" },
        "reason":reason,"checkedAtUnixSeconds":crate::time::unix_seconds(),"elapsedMs":started.elapsed().as_millis()})
}

pub(crate) async fn run(mcp_config: &Path, session_id: &str) -> i32 {
    let mut bytes = Vec::new();
    let input = if std::io::stdin()
        .take(MAX_INPUT_BYTES + 1)
        .read_to_end(&mut bytes)
        .is_ok()
        && bytes.len() as u64 <= MAX_INPUT_BYTES
    {
        serde_json::from_slice(&bytes).unwrap_or(Value::Null)
    } else {
        Value::Null
    };
    let decision = decide(&input, session_id);
    if decision == Decision::Root {
        if let Ok(Some(response)) = tokio::time::timeout(
            Duration::from_secs(2),
            hook_response(mcp_config, &input, true),
        )
        .await
            && response
                .pointer("/hookSpecificOutput/updatedInput")
                .and_then(|args| args[crate::agents::mcp::NOTIFICATION_PERMIT_FIELD].as_str())
                .is_some()
        {
            // Construct our own output: a response can supply the proof only,
            // never alter the input or the user's normal permission rules.
            let mut arguments = input["tool_input"].clone();
            arguments[crate::agents::mcp::NOTIFICATION_PERMIT_FIELD] =
                response["hookSpecificOutput"]["updatedInput"]
                    [crate::agents::mcp::NOTIFICATION_PERMIT_FIELD]
                    .clone();
            println!(
                "{}",
                json!({"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":arguments}})
            );
            return 0;
        }
        eprintln!(
            "RemoteCoder notification authorization is unavailable. Retry from the root conversation after the host notification service is available."
        );
        // Dispatch requires the proof even when hooks time out or are disabled.
        // Continuing without one lets that owner journal this unavailable path.
        return 0;
    }
    // Only fixed copy reaches the model. No title, body or provider error is
    // printed, even for malformed input or a failed callback.
    match decision {
        Decision::Child => eprintln!(
            "RemoteCoder child notifications are suppressed. Report the result to the parent conversation; the parent owns user notifications."
        ),
        Decision::Unverified => eprintln!(
            "RemoteCoder could not verify this notification caller. Notification delivery is unavailable for this call."
        ),
        Decision::Root => unreachable!(),
    }
    let _ = tokio::time::timeout(
        Duration::from_millis(300),
        hook_response(mcp_config, &input, false),
    )
    .await;
    2
}

async fn hook_response(
    mcp_config: &Path,
    input: &Value,
    include_tool_input: bool,
) -> Option<Value> {
    let data = tokio::fs::read(mcp_config).await.ok()?;
    let config: Value = serde_json::from_slice(&data).ok()?;
    let server = &config["mcpServers"][crate::agents::tools::NAMESPACE];
    let mut url = reqwest::Url::parse(server["url"].as_str()?).ok()?;
    if url.host_str() != Some("127.0.0.1") {
        return None;
    }
    url.set_path("/mcp/notification-hook");
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(if include_tool_input {
            Duration::from_millis(1_800)
        } else {
            Duration::from_millis(250)
        })
        .build()
        .ok()?;
    let mut body = json!({"hook_event_name":input["hook_event_name"],"tool_name":input["tool_name"],"session_id":input["session_id"]});
    if let Some(agent) = input.get("agent_id") {
        body["agent_id"] = agent.clone();
    }
    if include_tool_input {
        body["tool_input"] = input["tool_input"].clone();
    }
    client
        .post(url)
        .header(
            "Authorization",
            server["headers"]["Authorization"].as_str()?,
        )
        .json(&body)
        .send()
        .await
        .ok()?
        .error_for_status()
        .ok()?
        .json()
        .await
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_exact_native_root_hook_leaves_permissions_unchanged() {
        let root = json!({"hook_event_name":"PreToolUse","tool_name":TOOL,"session_id":"session"});
        assert_eq!(decide(&root, "session"), Decision::Root);
        let mut child = root.clone();
        child["agent_id"] = json!("native-child");
        assert_eq!(decide(&child, "session"), Decision::Child);
        assert_eq!(decide(&root, "another-session"), Decision::Unverified);
        for value in [Value::Null, json!(""), json!(7)] {
            child["agent_id"] = value;
            assert_eq!(decide(&child, "session"), Decision::Unverified);
        }
        let mut other_tool = root;
        other_tool["tool_name"] = json!("mcp__other__notify_user");
        assert_eq!(decide(&other_tool, "session"), Decision::Unverified);
        assert_eq!(decide(&Value::Null, "session"), Decision::Unverified);
    }

    #[test]
    fn hook_configuration_is_narrow_additive_and_does_not_change_permissions() {
        let value = hooks(
            Path::new("/fixture path/gateway"),
            Path::new("/private path/mcp.json"),
            "session",
        );
        assert_eq!(value.as_array().unwrap().len(), 1);
        let hook = &value[0];
        assert_eq!(hook["matcher"], "^mcp__remotecoder__notify_user$");
        assert_eq!(hook["hooks"][0]["command"], "/fixture path/gateway");
        assert_eq!(hook["hooks"][0]["args"][2], "/private path/mcp.json");
    }
}
