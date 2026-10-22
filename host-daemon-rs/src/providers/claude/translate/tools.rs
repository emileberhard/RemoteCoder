use super::{
    MAX_PENDING_TOOL_BYTES, MAX_PENDING_TOOLS, MAX_PROVIDER_ID_BYTES, Translated, TurnTranslator,
};
use crate::providers::claude::capacity::CapacityExceeded;
use serde_json::{Map, Value, json};

#[derive(Debug, Clone)]
pub(super) struct PendingTool {
    pub(super) tool_name: String,
    pub(super) input: Value,
    pub(super) started_at_ms: i64,
    pub(super) bytes: usize,
}

impl TurnTranslator {
    pub(super) fn start_tool_item(&mut self, block: &Value, out: &mut Translated) {
        let Some(tool_use_id) = block.get("id").and_then(Value::as_str) else {
            return;
        };
        if tool_use_id.len() > MAX_PROVIDER_ID_BYTES {
            out.capacity_error = Some(CapacityExceeded {
                resource: "provider identifier bytes",
                limit: MAX_PROVIDER_ID_BYTES,
            });
            return;
        }
        let name = block
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let mut input = block.get("input").cloned().unwrap_or_else(|| json!({}));
        crate::agents::mcp::remove_notification_permit(&mut input);
        let started_at_ms = crate::time::unix_millis();

        // TodoWrite is a plan update, not a timeline item.
        if name == "TodoWrite" {
            if let Some(plan) = plan_notification(&input) {
                out.notifications.push(json!({
                    "method": "turn/plan/updated",
                    "params": {
                        "threadId": self.thread_id,
                        "turnId": self.turn_id,
                        "explanation": Value::Null,
                        "plan": plan,
                    }
                }));
            }
            return;
        }

        let previous_bytes = self
            .pending_tools
            .get(tool_use_id)
            .map_or(0, |tool| tool.bytes);
        if previous_bytes == 0 && self.pending_tools.len() >= MAX_PENDING_TOOLS {
            out.capacity_error = Some(CapacityExceeded {
                resource: "pending tools",
                limit: MAX_PENDING_TOOLS,
            });
            return;
        }
        let encoded = match crate::wire::json::encoded_len(&input) {
            Ok(bytes) => bytes,
            Err(_) => {
                out.capacity_error = Some(CapacityExceeded {
                    resource: "pending tool bytes",
                    limit: MAX_PENDING_TOOL_BYTES,
                });
                return;
            }
        };
        let bytes = encoded
            .saturating_mul(4)
            .saturating_add(name.len())
            .saturating_add(tool_use_id.len())
            .saturating_add(256);
        if bytes > MAX_PENDING_TOOL_BYTES.saturating_sub(self.pending_tool_bytes - previous_bytes) {
            out.capacity_error = Some(CapacityExceeded {
                resource: "pending tool bytes",
                limit: MAX_PENDING_TOOL_BYTES,
            });
            return;
        }
        self.pending_tool_bytes = self.pending_tool_bytes - previous_bytes + bytes;
        self.pending_tools.insert(
            tool_use_id.to_string(),
            PendingTool {
                tool_name: name.clone(),
                input: input.clone(),
                started_at_ms,
                bytes,
            },
        );

        let item = tool_item(
            tool_use_id,
            &name,
            &input,
            &self.cwd,
            ToolOutcome::InProgress,
        );
        out.notifications.push(self.item_started(item));
    }
}

pub(crate) enum ToolOutcome {
    InProgress,
    Finished {
        is_error: bool,
        result_text: Option<String>,
        tool_use_result: Option<Value>,
        images: Vec<Value>,
        duration_ms: Option<i64>,
    },
}

impl ToolOutcome {
    fn status(&self) -> &'static str {
        match self {
            ToolOutcome::InProgress => "inProgress",
            ToolOutcome::Finished { is_error: true, .. } => "failed",
            ToolOutcome::Finished { .. } => "completed",
        }
    }

    fn duration_ms(&self) -> Option<i64> {
        match self {
            ToolOutcome::InProgress => None,
            ToolOutcome::Finished { duration_ms, .. } => *duration_ms,
        }
    }

    fn is_error(&self) -> bool {
        matches!(self, ToolOutcome::Finished { is_error: true, .. })
    }

    fn images(&self) -> &[Value] {
        match self {
            ToolOutcome::InProgress => &[],
            ToolOutcome::Finished { images, .. } => images,
        }
    }
}

/// Maps a Claude tool call onto the closest native app item type.
pub(crate) fn tool_item(
    tool_use_id: &str,
    tool_name: &str,
    input: &Value,
    cwd: &str,
    outcome: ToolOutcome,
) -> Value {
    if let Some(rest) = tool_name.strip_prefix("mcp__") {
        let mut parts = rest.splitn(2, "__");
        let server = parts.next().unwrap_or_default().to_string();
        let tool = parts.next().unwrap_or_default().to_string();
        return mcp_tool_call_item(tool_use_id, &server, &tool, input, &outcome);
    }

    match tool_name {
        "Bash" => command_execution_item(tool_use_id, input, cwd, &outcome),
        "Edit" | "Write" | "NotebookEdit" => {
            file_change_item(tool_use_id, tool_name, input, &outcome)
        }
        "WebSearch" => web_search_item(tool_use_id, input),
        "Read" => read_item(tool_use_id, input, &outcome),
        _ => dynamic_tool_call_item(tool_use_id, tool_name, input, &outcome, outcome.images()),
    }
}

fn read_item(tool_use_id: &str, input: &Value, outcome: &ToolOutcome) -> Value {
    let result = match outcome {
        ToolOutcome::Finished {
            is_error: false,
            tool_use_result: Some(result),
            ..
        } => Some(result),
        _ => None,
    };
    let path = result
        .and_then(|result| result.pointer("/file/filePath"))
        .or_else(|| input.get("file_path"))
        .and_then(Value::as_str)
        .filter(|path| std::path::Path::new(path).is_absolute());
    let kind = result
        .and_then(|result| result.get("type"))
        .and_then(Value::as_str);
    match (kind, path) {
        (Some("image"), Some(path)) => {
            let mut item = json!({ "type": "imageView", "id": tool_use_id, "path": path });
            if let Some(image) = outcome.images().first() {
                item["imageUrl"] = json!(data_url(image));
            }
            item
        }
        (Some("pdf" | "parts"), Some(path)) => {
            let name = std::path::Path::new(path)
                .file_name()
                .map(|name| name.to_string_lossy());
            let mut item = dynamic_tool_call_item(tool_use_id, "Read", input, outcome, &[]);
            item["rcMedia"] =
                json!([{ "path": path, "mimeType": "application/pdf", "name": name }]);
            item
        }
        _ => dynamic_tool_call_item(tool_use_id, "Read", input, outcome, outcome.images()),
    }
}

fn command_execution_item(
    tool_use_id: &str,
    input: &Value,
    cwd: &str,
    outcome: &ToolOutcome,
) -> Value {
    let command = input
        .get("command")
        .and_then(Value::as_str)
        .unwrap_or_default();

    let mut item = Map::new();
    item.insert("type".to_string(), json!("commandExecution"));
    item.insert("id".to_string(), json!(tool_use_id));
    item.insert("command".to_string(), json!(command));
    item.insert("cwd".to_string(), json!(cwd));
    item.insert("processId".to_string(), Value::Null);
    item.insert("status".to_string(), json!(outcome.status()));
    // Required by the app's decoder even when empty.
    item.insert("commandActions".to_string(), json!([]));

    if let ToolOutcome::Finished {
        tool_use_result,
        result_text,
        ..
    } = outcome
    {
        let aggregated = tool_use_result
            .as_ref()
            .and_then(aggregated_shell_output)
            .or_else(|| result_text.clone());
        item.insert(
            "aggregatedOutput".to_string(),
            aggregated.map_or(Value::Null, Value::String),
        );
        item.insert("exitCode".to_string(), Value::Null);
    }
    if let Some(duration_ms) = outcome.duration_ms() {
        item.insert("durationMs".to_string(), json!(duration_ms));
    }

    Value::Object(item)
}

fn aggregated_shell_output(tool_use_result: &Value) -> Option<String> {
    let stdout = tool_use_result
        .get("stdout")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let stderr = tool_use_result
        .get("stderr")
        .and_then(Value::as_str)
        .unwrap_or_default();

    let mut combined = String::new();
    if !stdout.is_empty() {
        combined.push_str(stdout);
    }
    if !stderr.is_empty() {
        if !combined.is_empty() {
            combined.push('\n');
        }
        combined.push_str(stderr);
    }
    if tool_use_result
        .get("interrupted")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        if !combined.is_empty() {
            combined.push('\n');
        }
        combined.push_str("[interrupted]");
    }

    if combined.is_empty() {
        None
    } else {
        Some(combined)
    }
}

fn file_change_item(
    tool_use_id: &str,
    tool_name: &str,
    input: &Value,
    outcome: &ToolOutcome,
) -> Value {
    let path = input
        .get("file_path")
        .or_else(|| input.get("notebook_path"))
        .and_then(Value::as_str)
        .unwrap_or_default();

    // Write creates unless the result shows it replaced existing content.
    let created = tool_name == "Write"
        && match outcome {
            ToolOutcome::Finished {
                tool_use_result, ..
            } => tool_use_result
                .as_ref()
                .and_then(|result| result.get("originalFile"))
                .is_none_or(Value::is_null),
            ToolOutcome::InProgress => true,
        };
    let kind = if created {
        json!({ "type": "add" })
    } else {
        json!({ "type": "update", "movePath": Value::Null })
    };

    json!({
        "type": "fileChange",
        "id": tool_use_id,
        "changes": [{ "path": path, "kind": kind, "diff": "" }],
        "status": outcome.status(),
    })
}

fn web_search_item(tool_use_id: &str, input: &Value) -> Value {
    let query = input
        .get("query")
        .and_then(Value::as_str)
        .unwrap_or_default();
    json!({
        "type": "webSearch",
        "id": tool_use_id,
        "query": query,
        "action": { "type": "search", "query": query, "queries": Value::Null },
    })
}

fn mcp_tool_call_item(
    tool_use_id: &str,
    server: &str,
    tool: &str,
    input: &Value,
    outcome: &ToolOutcome,
) -> Value {
    let mut item = Map::new();
    item.insert("type".to_string(), json!("mcpToolCall"));
    item.insert("id".to_string(), json!(tool_use_id));
    item.insert("server".to_string(), json!(server));
    item.insert("tool".to_string(), json!(tool));
    item.insert("status".to_string(), json!(outcome.status()));
    item.insert("arguments".to_string(), input.clone());

    if let ToolOutcome::Finished {
        is_error,
        result_text,
        images,
        ..
    } = outcome
    {
        let text = if *is_error {
            item.insert(
                "error".to_string(),
                json!({ "message": result_text.clone().unwrap_or_default() }),
            );
            None
        } else {
            result_text.as_ref()
        };
        if text.is_some() || !images.is_empty() {
            let content: Vec<Value> = text
                .into_iter()
                .map(|text| json!({ "type": "text", "text": text }))
                .chain(images.iter().cloned())
                .collect();
            item.insert(
                "result".to_string(),
                json!({ "content": content, "structuredContent": Value::Null }),
            );
        }
    }
    if let Some(duration_ms) = outcome.duration_ms() {
        item.insert("durationMs".to_string(), json!(duration_ms));
    }

    Value::Object(item)
}

fn dynamic_tool_call_item(
    tool_use_id: &str,
    tool_name: &str,
    input: &Value,
    outcome: &ToolOutcome,
    images: &[Value],
) -> Value {
    let mut item = Map::new();
    item.insert("type".to_string(), json!("dynamicToolCall"));
    item.insert("id".to_string(), json!(tool_use_id));
    item.insert("namespace".to_string(), Value::Null);
    item.insert("tool".to_string(), json!(tool_name));
    item.insert("status".to_string(), json!(outcome.status()));
    item.insert("arguments".to_string(), input.clone());

    if let ToolOutcome::Finished { result_text, .. } = outcome {
        item.insert("success".to_string(), json!(!outcome.is_error()));
        let content: Vec<Value> = result_text
            .iter()
            .map(|text| json!({ "type": "inputText", "text": text }))
            .chain(
                images
                    .iter()
                    .map(|image| json!({ "type": "inputImage", "imageUrl": data_url(image) })),
            )
            .collect();
        if !content.is_empty() {
            item.insert("contentItems".to_string(), Value::Array(content));
        }
    }
    if let Some(duration_ms) = outcome.duration_ms() {
        item.insert("durationMs".to_string(), json!(duration_ms));
    }

    Value::Object(item)
}

/// Maps a TodoWrite payload onto the app's plan steps.
fn plan_notification(input: &Value) -> Option<Vec<Value>> {
    let todos = input.get("todos").and_then(Value::as_array)?;
    let plan = todos
        .iter()
        .filter_map(|todo| {
            let step = todo
                .get("content")
                .or_else(|| todo.get("activeForm"))
                .and_then(Value::as_str)?;
            let status = match todo.get("status").and_then(Value::as_str) {
                Some("completed") => "completed",
                Some("in_progress") => "inProgress",
                _ => "pending",
            };
            Some(json!({ "step": step, "status": status }))
        })
        .collect();
    Some(plan)
}

fn data_url(image: &Value) -> String {
    format!(
        "data:{};base64,{}",
        image["mimeType"].as_str().unwrap_or_default(),
        image["data"].as_str().unwrap_or_default()
    )
}

pub(crate) fn tool_result_images(block: &Value) -> Vec<Value> {
    let Some(Value::Array(parts)) = block.get("content") else {
        return Vec::new();
    };
    parts
        .iter()
        .filter(|part| part["type"] == "image" && part["source"]["type"] == "base64")
        .filter_map(|part| {
            let source = &part["source"];
            Some(json!({
                "type": "image",
                "mimeType": source["media_type"].as_str()?,
                "data": source["data"].as_str()?,
            }))
        })
        .collect()
}

pub(crate) fn tool_result_text(block: &Value) -> Option<String> {
    match block.get("content") {
        Some(Value::String(text)) if !text.is_empty() => Some(text.clone()),
        Some(Value::Array(parts)) => {
            let text = parts
                .iter()
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n");
            if text.is_empty() { None } else { Some(text) }
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::{methods, translator};
    use super::*;

    #[test]
    fn failed_tool_result_marks_the_item_failed() {
        let mut t = translator();
        t.handle(&json!({
            "type":"assistant",
            "message":{"content":[{"type":"tool_use","id":"toolu_x","name":"Bash","input":{"command":"false"}}]}
        }));

        let completed = t.handle(&json!({
            "type":"user",
            "message":{"content":[{
                "tool_use_id":"toolu_x","type":"tool_result","content":"boom","is_error":true
            }]},
            "tool_use_result":{"stdout":"","stderr":"boom","interrupted":false}
        }));

        let item = &completed.notifications[0]["params"]["item"];
        assert_eq!(item["status"], json!("failed"));
        assert!(item["exitCode"].is_null());
    }

    #[test]
    fn read_and_write_tools_map_to_native_items() {
        let mut t = translator();
        let read = t.handle(&json!({
            "type":"assistant",
            "message":{"content":[{"type":"tool_use","id":"toolu_r","name":"Read","input":{"file_path":"/a.txt"}}]}
        }));
        assert_eq!(
            read.notifications[0]["params"]["item"]["type"],
            json!("dynamicToolCall")
        );
        assert_eq!(
            read.notifications[0]["params"]["item"]["tool"],
            json!("Read")
        );

        let write = t.handle(&json!({
            "type":"assistant",
            "message":{"content":[{"type":"tool_use","id":"toolu_w","name":"Write","input":{"file_path":"/b.txt","content":"x"}}]}
        }));
        let item = &write.notifications[0]["params"]["item"];
        assert_eq!(item["type"], json!("fileChange"));
        assert_eq!(item["changes"][0]["path"], json!("/b.txt"));
        assert_eq!(item["changes"][0]["kind"]["type"], json!("add"));
    }

    #[test]
    fn a_successful_image_read_completes_as_an_image_view() {
        let mut t = translator();
        let started = t.handle(&json!({
            "type":"assistant",
            "message":{"content":[{"type":"tool_use","id":"toolu_i","name":"Read","input":{"file_path":"/tmp/chart.png"}}]}
        }));
        assert_eq!(
            started.notifications[0]["params"]["item"]["type"],
            json!("dynamicToolCall")
        );

        let completed = t.handle(&json!({
            "type":"user",
            "message":{"content":[{
                "tool_use_id":"toolu_i","type":"tool_result",
                "content":[{"type":"image","source":{"type":"base64","data":"iVBOR","media_type":"image/png"}}]
            }]},
            "tool_use_result":{"type":"image","file":{"base64":"iVBOR","type":"image/png"}}
        }));
        assert_eq!(methods(&completed.notifications), vec!["item/completed"]);
        assert_eq!(
            completed.notifications[0]["params"]["item"],
            json!({"type":"imageView","id":"toolu_i","path":"/tmp/chart.png",
                   "imageUrl":"data:image/png;base64,iVBOR"})
        );
    }

    #[test]
    fn a_failed_or_text_read_stays_a_tool_call() {
        for (result, is_error) in [
            (json!({"type":"image","file":{"base64":"iVBOR"}}), true),
            (
                json!({"type":"text","file":{"filePath":"/tmp/a.txt","content":"x"}}),
                false,
            ),
        ] {
            let item = tool_item(
                "toolu_r",
                "Read",
                &json!({"file_path":"/tmp/a.png"}),
                "/tmp",
                ToolOutcome::Finished {
                    is_error,
                    result_text: None,
                    tool_use_result: Some(result),
                    images: Vec::new(),
                    duration_ms: None,
                },
            );
            assert_eq!(item["type"], json!("dynamicToolCall"));
        }
    }

    #[test]
    fn tool_result_images_reach_items_and_read_pdfs_show_the_document() {
        let page = json!({"type":"image","source":{"type":"base64","data":"/9j/","media_type":"image/jpeg"}});
        let finished = |is_error: bool, result: Value| {
            let block =
                json!({"content":[{"type":"text","text":"Took a screenshot"}, page.clone()]});
            ToolOutcome::Finished {
                is_error,
                result_text: tool_result_text(&block),
                tool_use_result: Some(result),
                images: tool_result_images(&block),
                duration_ms: None,
            }
        };
        let image = json!({"type":"image","mimeType":"image/jpeg","data":"/9j/"});
        let inline = json!({"type":"inputImage","imageUrl":"data:image/jpeg;base64,/9j/"});

        let mcp = tool_item(
            "toolu_m",
            "mcp__chrome__take_screenshot",
            &json!({}),
            "/tmp",
            finished(false, json!([])),
        );
        assert_eq!(
            mcp["result"]["content"],
            json!([{"type":"text","text":"Took a screenshot"}, image])
        );

        let failed = tool_item(
            "toolu_f",
            "mcp__chrome__click",
            &json!({}),
            "/tmp",
            finished(true, json!([])),
        );
        assert_eq!(failed["error"]["message"], json!("Took a screenshot"));
        assert_eq!(failed["result"]["content"], json!([image]));

        let dynamic = tool_item(
            "toolu_d",
            "Screenshot",
            &json!({}),
            "/tmp",
            finished(false, json!([])),
        );
        assert_eq!(
            dynamic["contentItems"],
            json!([{"type":"inputText","text":"Took a screenshot"}, inline])
        );

        for kind in ["pdf", "parts"] {
            let read = tool_item(
                "toolu_r",
                "Read",
                &json!({"file_path":"report.pdf","pages":"1"}),
                "/tmp",
                finished(
                    false,
                    json!({"type":kind,"file":{"filePath":"/tmp/report.pdf"}}),
                ),
            );
            assert_eq!(read["type"], json!("dynamicToolCall"));
            assert_eq!(
                read["rcMedia"],
                json!([{"path":"/tmp/report.pdf","mimeType":"application/pdf","name":"report.pdf"}])
            );
            assert_eq!(
                read["contentItems"],
                json!([{"type":"inputText","text":"Took a screenshot"}])
            );
        }

        let unplaced = tool_item(
            "toolu_i",
            "Read",
            &json!({"file_path":"photo.jpg"}),
            "/tmp",
            finished(false, json!({"type":"image","file":{}})),
        );
        assert_eq!(unplaced["type"], json!("dynamicToolCall"));
        assert_eq!(unplaced["contentItems"][1], inline);
    }

    #[test]
    fn mcp_tool_names_split_into_server_and_tool() {
        let mut t = translator();
        let out = t.handle(&json!({
            "type":"assistant",
            "message":{"content":[{
                "type":"tool_use","id":"toolu_m","name":"mcp__peekaboo__click","input":{"x":1}
            }]}
        }));

        let item = &out.notifications[0]["params"]["item"];
        assert_eq!(item["type"], json!("mcpToolCall"));
        assert_eq!(item["server"], json!("peekaboo"));
        assert_eq!(item["tool"], json!("click"));
    }

    #[test]
    fn notification_transport_proof_never_enters_app_tool_items_or_pending_state() {
        let mut t = translator();
        let out = t.handle(&json!({
            "type":"assistant", "message":{"content":[{
                "type":"tool_use","id":"notification","name":crate::providers::claude::notification_hook::TOOL,
                "input":{"title":"Fixture","body":"Root",crate::agents::mcp::NOTIFICATION_PERMIT_FIELD:"fixture-proof"}
            }]}
        }));
        let item = &out.notifications[0]["params"]["item"];
        assert_eq!(item["arguments"], json!({"title":"Fixture","body":"Root"}));
        assert_eq!(t.pending_tools["notification"].input, item["arguments"]);
        let completed = t.handle(&json!({"type":"user","message":{"content":[{
            "type":"tool_result","tool_use_id":"notification","content":"Delivered","is_error":false
        }]}}));
        assert!(
            !serde_json::to_string(&completed.notifications)
                .unwrap()
                .contains("fixture-proof")
        );
    }

    #[test]
    fn todo_write_becomes_a_plan_update() {
        let mut t = translator();
        let out = t.handle(&json!({
            "type":"assistant",
            "message":{"content":[{
                "type":"tool_use","id":"toolu_t","name":"TodoWrite",
                "input":{"todos":[
                    {"content":"first","status":"completed"},
                    {"content":"second","status":"in_progress"},
                    {"content":"third","status":"pending"}
                ]}
            }]}
        }));

        assert_eq!(methods(&out.notifications), vec!["turn/plan/updated"]);
        let plan = &out.notifications[0]["params"]["plan"];
        assert_eq!(plan[0]["status"], json!("completed"));
        assert_eq!(plan[1]["status"], json!("inProgress"));
        assert_eq!(plan[2]["status"], json!("pending"));
    }
}
