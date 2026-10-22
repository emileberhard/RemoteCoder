use serde_json::{Value, json};

use super::registry::{
    NAMESPACE, PUBLISH_VISUAL, TAKE_PHOTO, ToolDefinition, definitions, is_registry_tool,
};

const CODE_MODE_IMAGE_RESULT: &str = "In exec code, this call resolves to one string: text lines plus one data:image/jpeg;base64 line per image. Pass each data: line to image() and print the other lines with text().";

/// The `dynamicTools` array injected into Codex thread starts: one namespace
/// spec holding every registry tool.
pub(crate) fn codex_dynamic_tools() -> Value {
    json!([{
        "type": "namespace",
        "name": NAMESPACE,
        "description": "RemoteCoder's own tools for the app this conversation runs in.",
        "tools": definitions()
            .iter()
            .map(|tool| json!({
                "type": "function",
                "name": tool.name,
                "description": codex_description(tool),
                "inputSchema": (tool.input_schema)(),
                "deferLoading": tool.name == TAKE_PHOTO,
            }))
            .collect::<Vec<_>>(),
    }])
}

fn codex_description(tool: &ToolDefinition) -> String {
    if [TAKE_PHOTO, PUBLISH_VISUAL].contains(&tool.name) {
        format!("{} {CODE_MODE_IMAGE_RESULT}", tool.description)
    } else {
        tool.description.to_owned()
    }
}

pub(crate) fn declare_on_codex_request(obj: &mut serde_json::Map<String, Value>) -> bool {
    let Some(method) = obj.get("method").and_then(Value::as_str) else {
        return false;
    };
    if method != "thread/start" {
        return false;
    }

    let params = obj
        .entry("params")
        .or_insert_with(|| json!({}))
        .as_object_mut();
    let Some(params) = params else {
        return false;
    };
    let declared = params
        .entry("dynamicTools")
        .or_insert_with(|| json!([]))
        .as_array_mut();
    let Some(declared) = declared else {
        return false;
    };

    // Appended, not assigned: no client sends its own today, but replacing a
    // client's declarations would fail silently if one ever started.
    declared.extend(
        codex_dynamic_tools()
            .as_array()
            .cloned()
            .unwrap_or_default(),
    );
    true
}

/// An `item/tool/call` request from Codex, reduced to what dispatch needs.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct CodexToolCall {
    pub id: Value,
    pub tool: String,
    pub arguments: Value,
    pub thread_id: Option<String>,
    pub call_id: Option<String>,
    pub turn_id: Option<String>,
}

/// Recognizes an upstream dynamic-tool call the gateway itself must answer.
///
/// Anything else — including a dynamic tool some other client declared — returns
/// `None` so it keeps being broadcast to the client that owes the answer.
pub(crate) fn codex_tool_call(message: &Value) -> Option<CodexToolCall> {
    if message.get("method")?.as_str()? != "item/tool/call" {
        return None;
    }
    let id = message.get("id").filter(|id| !id.is_null())?.clone();
    let params = message.get("params")?;
    let tool = params.get("tool")?.as_str()?;
    let namespace = params.get("namespace").and_then(Value::as_str);
    if !is_registry_tool(namespace, tool) {
        return None;
    }

    Some(CodexToolCall {
        id,
        call_id: params
            .get("callId")
            .and_then(Value::as_str)
            .map(str::to_string),
        turn_id: params
            .get("turnId")
            .and_then(Value::as_str)
            .map(str::to_string),
        tool: tool.to_string(),
        arguments: params
            .get("arguments")
            .cloned()
            .unwrap_or_else(|| json!({})),
        thread_id: params
            .get("threadId")
            .and_then(Value::as_str)
            .map(str::to_string),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::tools::NOTIFY_USER;

    #[test]
    fn codex_projection_is_one_namespace_of_tagged_functions() {
        let spec = codex_dynamic_tools();
        let namespace = &spec[0];
        assert_eq!(namespace["type"], "namespace");
        assert_eq!(namespace["name"], NAMESPACE);
        let names: Vec<&str> = namespace["tools"]
            .as_array()
            .expect("array")
            .iter()
            .map(|tool| {
                assert_eq!(tool["type"], "function", "codex requires a tagged spec");
                tool["name"].as_str().expect("name")
            })
            .collect();
        assert_eq!(
            names,
            definitions()
                .iter()
                .map(|tool| tool.name)
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn code_mode_image_callers_learn_the_string_result_shape() {
        let spec = codex_dynamic_tools();
        let tools = spec[0]["tools"].as_array().expect("array");
        let description = |name: &str| {
            tools
                .iter()
                .find(|tool| tool["name"] == name)
                .and_then(|tool| tool["description"].as_str())
                .expect("description")
                .to_owned()
        };
        for name in [TAKE_PHOTO, PUBLISH_VISUAL] {
            let tool = description(name);
            assert!(tool.contains("data:image/jpeg;base64") && tool.contains("image()"));
        }
        assert!(!description(NOTIFY_USER).contains("image()"));
    }

    fn declared_namespaces(obj: &serde_json::Map<String, Value>) -> Vec<String> {
        obj["params"]["dynamicTools"]
            .as_array()
            .expect("array")
            .iter()
            .map(|spec| spec["name"].as_str().expect("name").to_string())
            .collect()
    }

    fn request(method: &str, params: Value) -> serde_json::Map<String, Value> {
        json!({"method": method, "params": params})
            .as_object()
            .expect("object")
            .clone()
    }

    #[test]
    fn only_thread_entry_points_declare_tools_without_replacing_other_params() {
        for (method, declares_tools) in [
            ("thread/start", true),
            ("thread/resume", false),
            ("turn/start", false),
            ("thread/list", false),
            ("command/exec", false),
        ] {
            let mut obj = request(method, json!({"cwd": "/tmp"}));
            assert_eq!(
                declare_on_codex_request(&mut obj),
                declares_tools,
                "{method}"
            );
            assert_eq!(obj["params"]["cwd"], "/tmp", "other params survive");
            if declares_tools {
                assert_eq!(declared_namespaces(&obj), vec![NAMESPACE], "{method}");
            } else {
                assert!(obj["params"].get("dynamicTools").is_none(), "{method}");
            }
        }
    }

    #[test]
    fn a_clients_own_declarations_are_kept() {
        let mut obj = request(
            "thread/start",
            json!({"dynamicTools": [{"type": "namespace", "name": "theirs", "tools": []}]}),
        );

        assert!(declare_on_codex_request(&mut obj));
        assert_eq!(declared_namespaces(&obj), vec!["theirs", NAMESPACE]);
    }

    #[test]
    fn only_registry_tool_calls_are_claimed() {
        let call = |params: Value| {
            codex_tool_call(&json!({"id": 9, "method": "item/tool/call", "params": params}))
        };

        let ours = call(json!({
            "threadId": "t1",
            "turnId": "u1",
            "callId": "c1",
            "namespace": NAMESPACE,
            "tool": NOTIFY_USER,
            "arguments": {"title": "hi", "body": "there"}
        }))
        .expect("a registry call is claimed");
        assert_eq!(ours.tool, NOTIFY_USER);
        assert_eq!(ours.thread_id.as_deref(), Some("t1"));
        assert_eq!(ours.arguments["title"], "hi");
        assert_eq!(ours.id, json!(9));

        // Someone else's dynamic tool must keep being broadcast to the client
        // that declared it, or that client's call never gets an answer.
        assert!(call(json!({"namespace": "theirs", "tool": NOTIFY_USER})).is_none());
        assert!(
            call(json!({"tool": NOTIFY_USER})).is_none(),
            "a namespace-less call is foreign; claiming it would swallow a client's own tool"
        );
        assert!(call(json!({"namespace": NAMESPACE, "tool": "rm_rf"})).is_none());
        assert!(codex_tool_call(&json!({"method": "item/completed"})).is_none());
        assert!(
            codex_tool_call(&json!({
                "method": "item/tool/call",
                "params": {"tool": NOTIFY_USER}
            }))
            .is_none(),
            "a call with no id has nowhere to send its result"
        );
    }
}
