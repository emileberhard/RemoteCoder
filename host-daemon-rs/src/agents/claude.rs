use super::{Agent, Capabilities, State};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::BTreeMap, path::PathBuf};

pub(crate) mod store;
pub mod transcript;

const MAX_CHILDREN: usize = 256;

fn lifecycle_changed(previous: &Child, current: &Child) -> bool {
    let mut prior = previous.clone();
    prior.last_text = current.last_text.clone();
    prior.last_event_time = current.last_event_time;
    prior != *current
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Child {
    pub id: String,
    pub task_id: Option<String>,
    #[serde(default)]
    pub execution_revision: u64,
    #[serde(default)]
    pub last_start_event: Option<String>,
    #[serde(default)]
    pub last_event_time: Option<i64>,
    pub agent_id: Option<String>,
    pub tool_id: Option<String>,
    pub parent_tool_id: Option<String>,
    pub parent_agent_id: Option<String>,
    pub title: String,
    pub model: Option<String>,
    pub state: State,
    pub output_file: Option<PathBuf>,
    pub last_text: Option<String>,
}

impl Child {
    pub(crate) fn public_id(&self, root: &str) -> String {
        format!(
            "claude:{root}:{}",
            self.agent_id.as_ref().unwrap_or(&self.id)
        )
    }
}

#[derive(Clone, Default, Deserialize, Serialize)]
pub(crate) struct Projection {
    pub children: BTreeMap<String, Child>,
    pub limited: bool,
    #[serde(default)]
    pub next_execution_revision: u64,
    #[serde(skip)]
    pub transcript_times: BTreeMap<String, i64>,
}

impl Projection {
    fn child(&mut self, id: &str) -> Option<&mut Child> {
        if !self.children.contains_key(id) && self.children.len() >= MAX_CHILDREN {
            self.limited = true;
            return None;
        }
        Some(self.children.entry(id.to_owned()).or_insert_with(|| Child {
            id: id.to_owned(),
            task_id: None,
            execution_revision: 0,
            last_start_event: None,
            last_event_time: None,
            agent_id: None,
            tool_id: None,
            parent_tool_id: None,
            parent_agent_id: None,
            title: "Agent".into(),
            model: None,
            state: State::Unknown,
            output_file: None,
            last_text: None,
        }))
    }

    pub(crate) fn ingest(&mut self, value: &Value) -> bool {
        if let Some(notification) = persisted_task_notification(value) {
            return self.ingest(&notification);
        }
        if !matches!(
            value["type"].as_str(),
            Some("assistant" | "user" | "system")
        ) {
            return false;
        }
        let mut changed = false;
        let event_time = value["timestamp"]
            .as_str()
            .and_then(crate::time::parse_rfc3339_seconds);
        let subtype = value["subtype"].as_str();
        if subtype == Some("background_tasks_changed") {
            if let Some(tasks) = value["tasks"].as_array() {
                for task in tasks {
                    if task["task_type"] != "local_agent" || task["ambient"] == true {
                        continue;
                    }
                    let Some(id) = task["task_id"].as_str() else {
                        continue;
                    };
                    if let Some(child) = self.child(id) {
                        let previous = child.clone();
                        child.task_id = Some(id.into());
                        child.state = State::Working;
                        if let Some(title) = task["description"].as_str() {
                            child.title = bounded(title, 200);
                        }
                        child.last_event_time = event_time.or(child.last_event_time);
                        changed |= lifecycle_changed(&previous, child);
                    }
                }
            }
        } else if matches!(
            subtype,
            Some("task_started" | "task_updated" | "task_notification")
        ) && let Some(id) = value["task_id"].as_str()
        {
            let tool = value["tool_use_id"].as_str();
            let is_agent = value["task_type"] == "local_agent"
                || self.children.contains_key(id)
                || tool.is_some_and(|tool| self.children.contains_key(tool));
            if is_agent && value["ambient"] != true {
                if let Some(tool) = tool
                    && tool != id
                    && let Some(previous) = self.children.remove(tool)
                {
                    let current = self.children.entry(id.into()).or_insert_with(|| Child {
                        id: id.into(),
                        ..previous.clone()
                    });
                    current.tool_id = previous.tool_id;
                    current.parent_tool_id = previous.parent_tool_id;
                    current.parent_agent_id = previous.parent_agent_id;
                    current.agent_id = current.agent_id.clone().or(previous.agent_id);
                    current.model = current.model.clone().or(previous.model);
                }
                let start = if subtype == Some("task_started") {
                    let event = value["uuid"].as_str().or(tool).unwrap_or(id);
                    if self
                        .children
                        .get(id)
                        .and_then(|child| child.last_start_event.as_deref())
                        != Some(event)
                    {
                        self.next_execution_revision =
                            self.next_execution_revision.saturating_add(1);
                        Some((event.to_owned(), self.next_execution_revision))
                    } else {
                        None
                    }
                } else {
                    None
                };
                if let Some(child) = self.child(id) {
                    let previous = child.clone();
                    child.task_id = Some(id.into());
                    if let Some((event, revision)) = start {
                        child.execution_revision = revision;
                        child.last_start_event = Some(event);
                    }
                    child.last_event_time = event_time.or(child.last_event_time);
                    if let Some(tool) = tool {
                        child.tool_id = Some(tool.into());
                    }
                    if let Some(title) = value["description"]
                        .as_str()
                        .or(value["patch"]["description"].as_str())
                    {
                        child.title = bounded(title, 200);
                    }
                    if let Some(output) = value["output_file"].as_str() {
                        child.output_file = Some(output.into());
                    }
                    if let Some(summary) = value["summary"].as_str() {
                        child.last_text = Some(bounded(summary, 8000));
                    }
                    child.state = match value["patch"]["status"]
                        .as_str()
                        .or(value["status"].as_str())
                    {
                        Some("running" | "pending") => State::Working,
                        Some("completed") => State::Completed,
                        Some("failed") => State::Failed,
                        Some("killed" | "stopped") => State::Interrupted,
                        _ if subtype == Some("task_started") => State::Working,
                        _ => child.state.clone(),
                    };
                    changed |= lifecycle_changed(&previous, child);
                }
            }
        }
        let mut bindings = Vec::new();
        if let Some(blocks) = value["message"]["content"].as_array() {
            for block in blocks {
                if block["type"] == "tool_use"
                    && matches!(block["name"].as_str(), Some("Agent" | "Task"))
                {
                    let Some(tool) = block["id"].as_str() else {
                        continue;
                    };
                    let id = self
                        .children
                        .values()
                        .find(|c| c.tool_id.as_deref() == Some(tool))
                        .map(|c| c.id.clone())
                        .unwrap_or_else(|| tool.into());
                    if let Some(child) = self.child(&id) {
                        let previous = child.clone();
                        child.tool_id = Some(tool.into());
                        child.parent_tool_id =
                            value["parent_tool_use_id"].as_str().map(str::to_owned);
                        child.parent_agent_id =
                            value["parent_agent_id"].as_str().map(str::to_owned);
                        child.title = block["input"]["description"]
                            .as_str()
                            .map(|s| bounded(s, 200))
                            .unwrap_or_else(|| "Agent".into());
                        child.model = block["input"]["model"].as_str().map(str::to_owned);
                        child.state = State::Working;
                        child.last_event_time = event_time.or(child.last_event_time);
                        changed |= lifecycle_changed(&previous, child);
                    }
                } else if block["type"] == "tool_use"
                    && block["name"] == "SendMessage"
                    && let Some(agent) = block["input"]["to"].as_str()
                    && let Some(child) = self
                        .children
                        .values_mut()
                        .find(|c| c.agent_id.as_deref() == Some(agent))
                {
                    let previous = child.clone();
                    child.state = State::Working;
                    child.last_event_time = event_time.or(child.last_event_time);
                    changed |= lifecycle_changed(&previous, child);
                } else if block["type"] == "tool_result" {
                    if let Some(child) = self.children.values_mut().find(|c| {
                        block["tool_use_id"]
                            .as_str()
                            .is_some_and(|tool| c.tool_id.as_deref() == Some(tool))
                    }) {
                        let previous = child.clone();
                        let result = value
                            .get("tool_use_result")
                            .or_else(|| value.get("toolUseResult"))
                            .unwrap_or(&Value::Null);
                        child.model = result["resolvedModel"]
                            .as_str()
                            .map(str::to_owned)
                            .or(child.model.take());
                        child.agent_id = result["agentId"]
                            .as_str()
                            .map(str::to_owned)
                            .or(child.agent_id.take());
                        if let Some(agent) = &child.agent_id {
                            bindings.push((child.id.clone(), agent.clone()));
                        }
                        child.output_file = result["outputFile"]
                            .as_str()
                            .map(PathBuf::from)
                            .or(child.output_file.take());
                        if let Some(text) = block["content"].as_str() {
                            child.last_text = Some(bounded(text, 8000));
                        }
                        if result["isAsync"] != true
                            && result["status"] != "async_launched"
                            && child.task_id.is_none()
                        {
                            child.state = if block["is_error"] == true {
                                State::Failed
                            } else {
                                State::Completed
                            };
                        }
                        child.last_event_time = event_time.or(child.last_event_time);
                        changed |= lifecycle_changed(&previous, child);
                    }
                } else if block["type"] == "text"
                    && let Some(parent_tool) = value["parent_tool_use_id"].as_str()
                    && let Some(child) = self
                        .children
                        .values_mut()
                        .find(|c| c.tool_id.as_deref() == Some(parent_tool))
                    && let Some(text) = block["text"].as_str()
                {
                    child.last_text = Some(bounded(text, 8000));
                }
            }
        }
        for (id, agent) in bindings {
            let replaced_tools: Vec<String> = self
                .children
                .iter()
                .filter(|(key, child)| *key != &id && child.agent_id.as_ref() == Some(&agent))
                .filter_map(|(_, child)| child.tool_id.clone())
                .collect();
            self.children
                .retain(|key, child| key == &id || child.agent_id.as_ref() != Some(&agent));
            for child in self.children.values_mut() {
                if child
                    .parent_tool_id
                    .as_ref()
                    .is_some_and(|tool| replaced_tools.contains(tool))
                {
                    child.parent_agent_id = Some(agent.clone());
                }
            }
        }
        changed
    }

    pub(crate) fn overlay(&mut self, other: Self) {
        self.next_execution_revision = self
            .next_execution_revision
            .max(other.next_execution_revision);
        for (id, child) in other.children {
            self.next_execution_revision =
                self.next_execution_revision.max(child.execution_revision);
            self.children.retain(|key, existing| {
                key == &id
                    || !(child
                        .agent_id
                        .as_ref()
                        .is_some_and(|agent| existing.agent_id.as_ref() == Some(agent))
                        || child
                            .tool_id
                            .as_ref()
                            .is_some_and(|tool| existing.tool_id.as_ref() == Some(tool)))
            });
            if self.children.len() < MAX_CHILDREN || self.children.contains_key(&id) {
                self.children.insert(id, child);
            } else {
                self.limited = true;
            }
        }
        self.limited |= other.limited;
    }

    fn overlay_cold(&mut self, saved: Self, saved_written_at: Option<i64>) {
        self.next_execution_revision = self
            .next_execution_revision
            .max(saved.next_execution_revision);
        self.limited |= saved.limited;
        for (id, old) in saved.children {
            self.next_execution_revision = self.next_execution_revision.max(old.execution_revision);
            let matching = self
                .children
                .iter()
                .find(|(key, current)| {
                    *key == &id
                        || old
                            .agent_id
                            .as_ref()
                            .is_some_and(|agent| current.agent_id.as_ref() == Some(agent))
                        || old
                            .tool_id
                            .as_ref()
                            .is_some_and(|tool| current.tool_id.as_ref() == Some(tool))
                })
                .map(|(key, current)| (key.clone(), current.clone()));
            if let Some((current_id, current)) = matching {
                let current_newer = matches!((current.last_event_time, old.last_event_time),
                    (Some(current_time), Some(old_time)) if current_time > old_time)
                    || current
                        .last_event_time
                        .zip(saved_written_at)
                        .is_some_and(|(current_time, written_at)| current_time > written_at);
                let old_newer = matches!((current.last_event_time, old.last_event_time),
                    (Some(current_time), Some(old_time)) if old_time > current_time);
                let same_execution = current.task_id == old.task_id
                    && current.tool_id == old.tool_id
                    && current.last_start_event == old.last_start_event;
                if current_newer {
                    continue;
                }
                if old_newer || same_execution {
                    self.children.remove(&current_id);
                    self.children.insert(id, old);
                } else if let Some(current) = self.children.get_mut(&current_id) {
                    current.state = State::Unknown;
                    current.task_id = None;
                    current.output_file = None;
                    self.limited = true;
                }
            } else if self.children.len() < MAX_CHILDREN {
                self.children.insert(id, old);
            } else {
                self.limited = true;
            }
        }
    }

    pub(crate) fn stopped(&mut self) {
        for child in self.children.values_mut() {
            if child.state.is_running() {
                child.state = State::Interrupted;
            }
        }
    }

    pub(crate) fn agents(&self, root: &str, live: bool) -> Vec<Agent> {
        self.children
            .values()
            .map(|child| {
                let parent = self.children.values().find(|other| {
                    child
                        .parent_agent_id
                        .as_ref()
                        .is_some_and(|id| other.agent_id.as_ref() == Some(id))
                        || child
                            .parent_tool_id
                            .as_ref()
                            .is_some_and(|id| other.tool_id.as_ref() == Some(id))
                });
                let state = if !live && child.state.is_running() {
                    State::Unknown
                } else {
                    child.state.clone()
                };
                Agent {
                    id: child.public_id(root),
                    parent_id: parent.map(|c| c.public_id(root)),
                    owner_thread_id: root.into(),
                    thread_id: None,
                    provider: "claude".into(),
                    source: "native".into(),
                    title: child.title.clone(),
                    model: child.model.clone(),
                    state,
                    capabilities: Capabilities {
                        inspect: true,
                        ask_parent: true,
                        ..Default::default()
                    },
                    execution_id: child.task_id.clone(),
                    last_active_at: child.last_event_time.max(
                        child
                            .agent_id
                            .as_ref()
                            .and_then(|id| self.transcript_times.get(id).copied()),
                    ),
                }
            })
            .collect()
    }
}

fn persisted_task_notification(value: &Value) -> Option<Value> {
    let text = match value["type"].as_str()? {
        "queue-operation" if value["operation"] == "enqueue" => value["content"].as_str()?,
        "attachment" if value["attachment"]["type"] == "queued_command" => {
            value["attachment"]["prompt"].as_str()?
        }
        _ => return None,
    };
    let body = text.trim_start().strip_prefix("<task-notification>")?;
    let header = body
        .split_once("<result>")
        .map_or(body, |(header, _)| header);
    let field = |tag: &str| {
        let open = format!("<{tag}>");
        let start = header.find(&open)? + open.len();
        let end = start + header[start..].find(&format!("</{tag}>"))?;
        Some(header[start..end].trim().to_owned())
    };
    Some(json!({
        "type": "system",
        "subtype": "task_notification",
        "timestamp": value["timestamp"],
        "task_id": field("task-id")?,
        "tool_use_id": field("tool-use-id"),
        "status": field("status"),
        "summary": field("summary"),
    }))
}

fn bounded(text: &str, limit: usize) -> String {
    let mut end = text.len().min(limit);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    pub(super) fn tool(id: &str, parent: Option<&str>) -> Value {
        json!({"type":"assistant","parent_tool_use_id":parent,"message":{"content":[{"type":"tool_use","name":"Agent","id":id,"input":{"description":"Review changes","model":"opus"}}]}})
    }

    #[test]
    fn resumed_agent_replaces_older_task_independent_of_lexical_order() {
        let mut live = Projection::default();
        let result = |tool: &str| json!({"type":"user","tool_use_result":{"agentId":"stable-agent","isAsync":true},"message":{"content":[{"type":"tool_result","tool_use_id":tool,"content":"Started"}]}});
        live.ingest(&tool("old-tool", None));
        live.ingest(&json!({"type":"system","subtype":"task_started","task_type":"local_agent","task_id":"z-old","tool_use_id":"old-tool"}));
        live.ingest(&result("old-tool"));
        live.ingest(&json!({"type":"system","subtype":"task_notification","task_id":"z-old","status":"completed"}));
        let mut restored = live.clone();
        live.ingest(&tool("new-tool", None));
        live.ingest(&json!({"type":"system","subtype":"task_started","task_type":"local_agent","task_id":"a-new","tool_use_id":"new-tool"}));
        live.ingest(&result("new-tool"));
        assert_eq!(live.children.len(), 1);
        restored.overlay(live);
        let agents = restored.agents("claude_root", true);
        assert_eq!(agents.len(), 1);
        assert_eq!(agents[0].id, "claude:claude_root:stable-agent");
        assert_eq!(agents[0].execution_id.as_deref(), Some("a-new"));
        assert_eq!(agents[0].state, State::Working);
    }

    #[test]
    fn reused_task_id_never_reuses_a_stale_stop_token() {
        let mut projection = Projection::default();
        let result = |tool: &str| json!({"type":"user","tool_use_result":{"agentId":"stable-agent","isAsync":true},"message":{"content":[{"type":"tool_result","tool_use_id":tool,"content":"Started"}]}});
        for (tool_id, task_id, event) in [
            ("first-tool", "task-one", "first"),
            ("second-tool", "task-two", "second"),
            ("third-tool", "task-one", "third"),
        ] {
            projection.ingest(&tool(tool_id, None));
            projection.ingest(&json!({"type":"system","subtype":"task_started","task_type":"local_agent","task_id":task_id,"tool_use_id":tool_id,"uuid":event}));
            projection.ingest(&result(tool_id));
        }
        assert_eq!(projection.children.len(), 1);
        assert_eq!(projection.children["task-one"].execution_revision, 3);
        assert_eq!(projection.next_execution_revision, 3);
    }

    #[test]
    fn cold_history_keeps_a_proven_newer_external_resume() {
        fn invocation(tool_id: &str, task_id: &str, time: &str) -> Projection {
            let mut projection = Projection::default();
            let mut use_event = tool(tool_id, None);
            use_event["timestamp"] = json!(time);
            projection.ingest(&use_event);
            projection.ingest(&json!({"type":"system","subtype":"task_started","task_type":"local_agent","task_id":task_id,"tool_use_id":tool_id,"uuid":task_id,"timestamp":time}));
            projection.ingest(&json!({"type":"user","timestamp":time,"tool_use_result":{"agentId":"stable-agent","isAsync":true},"message":{"content":[{"type":"tool_result","tool_use_id":tool_id,"content":"Started"}]}}));
            projection
        }
        let mut saved = invocation("old-tool", "old-task", "2026-09-26T10:00:00Z");
        saved.children.get_mut("old-task").unwrap().state = State::Completed;
        let mut tail = invocation("new-tool", "new-task", "2026-09-26T10:01:00Z");
        tail.overlay_cold(
            saved,
            crate::time::parse_rfc3339_seconds("2026-09-26T10:00:30Z"),
        );
        assert_eq!(tail.children.len(), 1);
        assert_eq!(
            tail.children["new-task"].agent_id.as_deref(),
            Some("stable-agent")
        );
        assert_eq!(tail.children["new-task"].state, State::Working);
    }

    #[test]
    fn cold_history_without_order_evidence_drops_execution_authority() {
        let mut saved = Projection::default();
        saved.ingest(&tool("old-tool", None));
        saved.children.get_mut("old-tool").unwrap().agent_id = Some("stable-agent".into());
        let mut tail = Projection::default();
        tail.ingest(&tool("new-tool", None));
        tail.children.get_mut("new-tool").unwrap().agent_id = Some("stable-agent".into());
        tail.overlay_cold(saved, None);
        assert_eq!(tail.children.len(), 1);
        assert_eq!(tail.children["new-tool"].state, State::Unknown);
        assert_eq!(tail.children["new-tool"].task_id, None);
        assert!(tail.limited);
    }

    #[test]
    fn child_text_updates_do_not_request_a_durable_save() {
        let mut projection = Projection::default();
        assert!(projection.ingest(&tool("child-tool", None)));
        assert!(projection.ingest(&json!({"type":"system","subtype":"task_started","task_type":"local_agent","task_id":"child-tool"})));
        assert!(!projection.ingest(&json!({"type":"system","subtype":"task_updated","task_type":"local_agent","task_id":"child-tool","summary":"Still working"})));
        assert!(projection.ingest(&json!({"type":"system","subtype":"task_notification","task_id":"child-tool","status":"completed","summary":"Finished"})));
    }

    #[test]
    fn durable_overlay_replaces_provisional_task_identity() {
        let mut saved = Projection::default();
        saved.ingest(&tool("invocation", None));
        let mut live = saved.clone();
        live.ingest(&json!({"type":"system","subtype":"task_started","task_type":"local_agent","task_id":"task","tool_use_id":"invocation"}));
        saved.overlay(live);
        assert_eq!(saved.children.len(), 1);
        assert_eq!(saved.children["task"].task_id.as_deref(), Some("task"));
    }

    #[test]
    fn lifecycle_keeps_nested_agent_identity_and_terminal_outcome() {
        let mut projection = Projection::default();
        projection.ingest(&tool("tool-parent", None));
        projection.ingest(&tool("tool-child", Some("tool-parent")));
        projection.ingest(&json!({"type":"system","subtype":"task_started","task_type":"local_agent","task_id":"task-parent","tool_use_id":"tool-parent"}));
        projection.ingest(&json!({"type":"system","subtype":"task_notification","task_id":"task-parent","status":"completed","summary":"Reviewed"}));
        let agents = projection.agents("claude_root", true);
        assert_eq!(agents.len(), 2);
        assert_eq!(projection.children["task-parent"].state, State::Completed);
        assert_eq!(
            agents
                .iter()
                .find(|a| a.id == "claude:claude_root:tool-child")
                .unwrap()
                .parent_id
                .as_deref(),
            Some("claude:claude_root:task-parent")
        );
        assert_eq!(
            projection
                .agents("claude_root", false)
                .iter()
                .find(|a| a.id == "claude:claude_root:tool-child")
                .unwrap()
                .state,
            State::Unknown
        );
    }

    #[test]
    fn snapshot_before_start_retains_parent_and_fences_resumed_execution() {
        let mut projection = Projection::default();
        projection.ingest(&tool("parent", None));
        projection.ingest(&tool("child", Some("parent")));
        projection.ingest(&json!({"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"task","task_type":"local_agent","description":"Review"}]}));
        let started = json!({"type":"system","subtype":"task_started","task_id":"task","task_type":"local_agent","tool_use_id":"child","uuid":"first"});
        projection.ingest(&started);
        projection.ingest(&started);
        assert_eq!(projection.children["task"].execution_revision, 1);
        assert_eq!(
            projection.children["task"].parent_tool_id.as_deref(),
            Some("parent")
        );
        projection.ingest(&json!({"type":"user","tool_use_result":{"status":"async_launched","agentId":"native-id","resolvedModel":"claude-sonnet"},"message":{"content":[{"type":"tool_result","tool_use_id":"child","content":"launched"}]}}));
        projection.ingest(&json!({"type":"system","subtype":"task_updated","task_id":"task","patch":{"status":"killed"}}));
        assert_eq!(projection.children["task"].state, State::Interrupted);
        let mut resumed = started;
        resumed["uuid"] = json!("second");
        projection.ingest(&resumed);
        assert_eq!(projection.children["task"].execution_revision, 2);
        assert_eq!(projection.children["task"].state, State::Working);
        assert_eq!(
            projection.children["task"].public_id("root"),
            "claude:root:native-id"
        );
    }

    #[test]
    fn shell_tasks_and_stream_deltas_never_become_agents() {
        let mut projection = Projection::default();
        assert!(!projection.ingest(&json!({"type":"system","subtype":"task_started","task_type":"local_bash","task_id":"shell"})));
        assert!(!projection.ingest(&json!({"type":"stream_event","parent_tool_use_id":"tool","event":{"delta":{"text":"hello"}}})));
        assert!(projection.children.is_empty());
    }

    #[test]
    fn persisted_task_notifications_settle_background_agents_until_resumed() {
        let notification = |task: &str, tool: &str, status: &str| {
            format!(
                "<task-notification>\n<task-id>{task}</task-id>\n<tool-use-id>{tool}</tool-use-id>\n<status>{status}</status>\n<summary>Agent \"Map\" finished</summary>\n<result>Quoted <status>running</status></result>\n</task-notification>"
            )
        };
        let mut projection = Projection::default();
        projection.ingest(&tool("toolu_map", None));
        projection.ingest(&json!({"type":"user","toolUseResult":{"agentId":"a6e8","isAsync":true,"status":"async_launched"},"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_map","content":"Async agent launched successfully."}]}}));
        projection.ingest(&json!({"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-27T12:17:45.980Z","content":notification("b1","toolu_bash","completed")}));
        assert_eq!(projection.children.len(), 1);
        assert_eq!(projection.children["toolu_map"].state, State::Working);

        projection.ingest(&json!({"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-27T12:17:45.980Z","content":notification("a6e8","toolu_map","completed")}));
        assert_eq!(projection.children.len(), 1);
        assert_eq!(projection.children["a6e8"].state, State::Completed);
        assert_eq!(
            projection.children["a6e8"].agent_id.as_deref(),
            Some("a6e8")
        );

        projection.ingest(&json!({"type":"assistant","timestamp":"2026-09-27T12:19:00.000Z","message":{"content":[{"type":"tool_use","name":"SendMessage","id":"toolu_resume","input":{"to":"a6e8","message":"Also check timers"}}]}}));
        assert_eq!(projection.children["a6e8"].state, State::Working);

        projection.ingest(&json!({"type":"attachment","timestamp":"2026-09-27T12:20:00.000Z","attachment":{"type":"queued_command","prompt":notification("a6e8","toolu_map","failed")}}));
        assert_eq!(projection.children["a6e8"].state, State::Failed);
    }

    #[test]
    fn terminal_sync_result_and_runtime_stop_have_different_outcomes() {
        let mut projection = Projection::default();
        projection.ingest(&tool("done", None));
        projection.ingest(&tool("running", None));
        projection.ingest(&json!({"type":"user","toolUseResult":{"agentId":"agent-a"},"message":{"content":[{"type":"tool_result","tool_use_id":"done","content":"finished"}]}}));
        projection.stopped();
        assert_eq!(projection.children["done"].state, State::Completed);
        assert_eq!(projection.children["running"].state, State::Interrupted);
    }
}
