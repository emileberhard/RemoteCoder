use super::{Origin, SourceRef};
use anyhow::{Context, Result};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Default, Debug, Serialize, Deserialize)]
pub(super) struct State {
    pub thread: Option<String>,
    pub cwd: Option<String>,
    pub title: Option<String>,
    pub first: Option<String>,
    pub last: Option<String>,
    pub parent: Option<String>,
    pub turn: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub turn_seq: i64,
}

pub(super) struct Record<'a> {
    pub db: &'a Connection,
    pub origin: &'a Origin,
    pub source: i64,
    pub revision: i64,
    pub path: &'a std::path::Path,
    pub offset: u64,
    pub bytes: &'a [u8],
}

impl Record<'_> {
    pub fn apply(&self, state: &mut State, value: Value) -> Result<()> {
        let timestamp = value["timestamp"]
            .as_str()
            .map(super::super::timestamp)
            .transpose()?;
        if let Some(at) = &timestamp {
            if state.first.as_ref().is_none_or(|first| at < first) {
                state.first = Some(at.clone());
            }
            if state.last.as_ref().is_none_or(|last| at > last) {
                state.last = Some(at.clone());
            }
        }
        if self.origin.provider == "codex" {
            self.codex(state, &value, timestamp.as_deref())?;
        } else {
            self.claude(state, &value, timestamp.as_deref())?;
        }
        if let Some(thread) = &state.thread {
            self.db.execute("INSERT INTO session(session_key,origin_host,provider,provider_home,thread_id,cwd,title,started_at,last_at,parent_session_key,source_id) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11) ON CONFLICT(session_key) DO UPDATE SET cwd=excluded.cwd,title=excluded.title,started_at=excluded.started_at,last_at=excluded.last_at,parent_session_key=excluded.parent_session_key WHERE session.source_id=excluded.source_id",params![super::super::session_key(self.origin,thread),self.origin.host,self.origin.provider,self.origin.provider_home.to_string_lossy(),thread,state.cwd,state.title,state.first,state.last,state.parent.as_ref().map(|p|super::super::session_key(self.origin,p)),self.source])?;
        }
        Ok(())
    }

    fn codex(&self, state: &mut State, v: &Value, at: Option<&str>) -> Result<()> {
        let p = &v["payload"];
        match v["type"].as_str() {
            Some("session_meta") => {
                if let Some(id) = p["id"].as_str().or_else(|| p["session_id"].as_str()) {
                    let stem = self
                        .path
                        .file_stem()
                        .and_then(|s| s.to_str())
                        .unwrap_or_default();
                    let exact = stem
                        .get(stem.len().saturating_sub(36)..)
                        .is_some_and(|suffix| {
                            suffix.len() == 36
                                && suffix.chars().enumerate().all(|(i, c)| {
                                    if matches!(i, 8 | 13 | 18 | 23) {
                                        c == '-'
                                    } else {
                                        c.is_ascii_hexdigit()
                                    }
                                })
                        });
                    if exact && !stem.ends_with(id) {
                        return Ok(());
                    }
                }
                if state.thread.is_none() {
                    state.thread = string(&p["id"]).or_else(|| string(&p["session_id"]));
                }
                state.cwd = string(&p["cwd"]);
                state.parent = p
                    .pointer("/source/subagent/thread_spawn/parent_thread_id")
                    .or_else(|| p.pointer("/source/subAgent/thread_spawn/parent_thread_id"))
                    .and_then(string);
                self.session(state)?;
            }
            Some("turn_context") => {
                if let Some(turn) = p["turn_id"].as_str() {
                    state.turn = Some(turn.into());
                }
                state.cwd = string(&p["cwd"]).or(state.cwd.take());
                state.model = string(&p["model"]);
                state.effort = string(&p["effort"]).or_else(|| string(&p["reasoning_effort"]));
                self.turn(state, at, None)?;
            }
            Some("event_msg") => match p["type"].as_str() {
                Some("task_started") => {
                    state.turn = string(&p["turn_id"]);
                    state.turn_seq += 1;
                    self.turn(state, at, Some("in_progress"))?;
                }
                Some("task_complete" | "task_completed" | "turn_aborted") => {
                    state.turn = string(&p["turn_id"]).or(state.turn.take());
                    self.turn(
                        state,
                        at,
                        Some(if p["type"] == "turn_aborted" {
                            "interrupted"
                        } else {
                            "completed"
                        }),
                    )?;
                }
                Some("token_count") => {
                    if let (Some(thread), Some(turn)) = (&state.thread, &state.turn) {
                        let usage = &p["info"]["total_token_usage"];
                        self.db.execute("UPDATE turn SET tokens_in=?1,tokens_out=?2 WHERE session_key=?3 AND turn_id=?4",params![usage["input_tokens"].as_i64(),usage["output_tokens"].as_i64(),super::super::session_key(self.origin,thread),turn])?;
                    }
                }
                _ => {}
            },
            Some("response_item") => {
                let kind = p["type"].as_str().unwrap_or("");
                match kind {
                    "message" => {
                        let role = match p["role"].as_str() {
                            Some("user") => "user",
                            Some("assistant") => "assistant",
                            _ => "system",
                        };
                        self.item(
                            state,
                            at,
                            0,
                            role,
                            text(&p["content"]),
                            "/payload/content",
                            &p["content"],
                            None,
                            None,
                        )?;
                    }
                    "reasoning" => {
                        self.item(
                            state,
                            at,
                            0,
                            "reasoning",
                            text(&p["summary"]),
                            "/payload/summary",
                            p,
                            None,
                            None,
                        )?;
                    }
                    "function_call" | "custom_tool_call" => {
                        let input = p
                            .get("arguments")
                            .or(p.get("input"))
                            .cloned()
                            .unwrap_or(Value::Null);
                        let input = match input {
                            Value::String(s) => {
                                serde_json::from_str(&s).unwrap_or(Value::String(s))
                            }
                            v => v,
                        };
                        self.item(
                            state,
                            at,
                            0,
                            "tool_call",
                            serde_json::to_string(&input)?,
                            "/payload",
                            p,
                            Some((p["name"].as_str().unwrap_or("unknown"), input)),
                            None,
                        )?;
                    }
                    "function_call_output" | "custom_tool_call_output" => {
                        self.item(
                            state,
                            at,
                            0,
                            "tool_result",
                            text(&p["output"]),
                            "/payload/output",
                            &p["output"],
                            None,
                            Some(p),
                        )?;
                    }
                    _ => {}
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn claude(&self, state: &mut State, v: &Value, at: Option<&str>) -> Result<()> {
        if state.thread.is_none() {
            let stem = self
                .path
                .file_stem()
                .and_then(|p| p.to_str())
                .context("Session path needs a UTF-8 name")?;
            if self
                .path
                .parent()
                .and_then(|p| p.file_name())
                .is_some_and(|p| p == "subagents")
            {
                let parent = self
                    .path
                    .parent()
                    .and_then(|p| p.parent())
                    .and_then(|p| p.file_name())
                    .and_then(|p| p.to_str())
                    .context("Native child has no owning session")?;
                let child = stem.strip_prefix("agent-").unwrap_or(stem);
                state.thread = Some(format!("claude:{parent}:{child}"));
                state.parent = Some(format!("claude_{parent}"));
            } else {
                let id = v["sessionId"].as_str().unwrap_or(stem);
                state.thread = Some(format!("claude_{id}"));
            }
        }
        state.cwd = string(&v["cwd"]).or(state.cwd.take());
        if v["type"] == "custom-title" {
            state.title = string(&v["customTitle"]);
        }
        if v["type"] == "ai-title" && state.title.is_none() {
            state.title = string(&v["aiTitle"]);
        }
        self.session(state)?;
        let message = &v["message"];
        if !matches!(v["type"].as_str(), Some("user" | "assistant")) {
            return Ok(());
        }
        state.model = string(&message["model"]).or(state.model.take());
        if v["type"] == "user" && v["isMeta"] != true && !has_tool_result(&message["content"]) {
            state.turn = v["turnId"]
                .as_str()
                .map(str::to_owned)
                .or_else(|| v["uuid"].as_str().map(|id| format!("record:{id}")));
            state.turn_seq += 1;
            self.turn(state, at, None)?;
        }
        if let Some(parts) = message["content"].as_array() {
            for (n, part) in parts.iter().enumerate() {
                match part["type"].as_str() {
                    Some("tool_use") => {
                        let input = part["input"].clone();
                        self.item(
                            state,
                            at,
                            n,
                            "tool_call",
                            serde_json::to_string(&input)?,
                            &format!("/message/content/{n}"),
                            part,
                            Some((part["name"].as_str().unwrap_or("unknown"), input)),
                            None,
                        )?;
                    }
                    Some("tool_result") => {
                        let mut result = part.clone();
                        if result.get("is_error").is_none() {
                            result["is_error"] = Value::Bool(false);
                        }
                        result["metadata"] = v
                            .get("toolUseResult")
                            .or(v.get("tool_use_result"))
                            .cloned()
                            .unwrap_or(Value::Null);
                        self.item(
                            state,
                            at,
                            n,
                            "tool_result",
                            text(&part["content"]),
                            &format!("/message/content/{n}"),
                            &result,
                            None,
                            Some(&result),
                        )?;
                    }
                    Some("thinking") => {
                        self.item(
                            state,
                            at,
                            n,
                            "reasoning",
                            part["thinking"].as_str().unwrap_or("").into(),
                            &format!("/message/content/{n}"),
                            part,
                            None,
                            None,
                        )?;
                    }
                    _ => {
                        self.item(
                            state,
                            at,
                            n,
                            if v["type"] == "user" {
                                if v["isMeta"] == true {
                                    "system"
                                } else {
                                    "user"
                                }
                            } else {
                                "assistant"
                            },
                            text(part),
                            &format!("/message/content/{n}"),
                            part,
                            None,
                            None,
                        )?;
                    }
                }
            }
        } else if message["content"].is_string() {
            self.item(
                state,
                at,
                0,
                if v["type"] == "user" {
                    "user"
                } else {
                    "assistant"
                },
                text(&message["content"]),
                "/message/content",
                message,
                None,
                None,
            )?;
        }
        if let (Some(thread), Some(turn)) = (&state.thread, &state.turn) {
            let u = &message["usage"];
            if !u.is_null() {
                self.db.execute("UPDATE turn SET tokens_in=?1,tokens_out=?2,model=coalesce(?3,model) WHERE session_key=?4 AND turn_id=?5",params![u["input_tokens"].as_i64(),u["output_tokens"].as_i64(),state.model,super::super::session_key(self.origin,thread),turn])?;
            }
        }
        Ok(())
    }

    fn session(&self, state: &State) -> Result<()> {
        let thread = state
            .thread
            .as_ref()
            .context("Missing exact provider session identity")?;
        let key = super::super::session_key(self.origin, thread);
        let existing: Option<i64> = self
            .db
            .query_row(
                "SELECT source_id FROM session WHERE session_key=?1",
                [&key],
                |r| r.get(0),
            )
            .optional()?;
        anyhow::ensure!(
            existing.is_none_or(|id| id == self.source),
            "Conflicting provider session identity in different source files"
        );
        self.db.execute("INSERT OR IGNORE INTO session(session_key,origin_host,provider,provider_home,thread_id,source_id) VALUES(?1,?2,?3,?4,?5,?6)",params![key,self.origin.host,self.origin.provider,self.origin.provider_home.to_string_lossy(),thread,self.source])?;
        Ok(())
    }

    fn turn(&self, state: &State, at: Option<&str>, status: Option<&str>) -> Result<()> {
        let (Some(thread), Some(turn)) = (&state.thread, &state.turn) else {
            return Ok(());
        };
        self.db.execute("INSERT INTO turn(session_key,turn_id,seq,started_at,ended_at,status,model,effort) VALUES(?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT(session_key,turn_id) DO UPDATE SET ended_at=coalesce(excluded.ended_at,turn.ended_at),status=coalesce(excluded.status,turn.status),model=coalesce(excluded.model,turn.model),effort=coalesce(excluded.effort,turn.effort)",params![super::super::session_key(self.origin,thread),turn,state.turn_seq,at,if matches!(status,Some("completed"|"interrupted")) {at} else {None},status,state.model,state.effort])?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn item(
        &self,
        state: &State,
        at: Option<&str>,
        part: usize,
        kind: &str,
        mut text: String,
        pointer: &str,
        value: &Value,
        call: Option<(&str, Value)>,
        result: Option<&Value>,
    ) -> Result<()> {
        self.session(state)?;
        let key =
            super::super::session_key(self.origin, state.thread.as_deref().context("No session")?);
        let item = format!("{key}@item:{}:{part}", self.offset);
        let (images, sidecars) = super::dependencies(value, &text, self.origin, self.path)?;
        for sidecar in &sidecars {
            let local = self.origin.local(std::path::Path::new(sidecar))?;
            if let Some(bytes) = crate::providers::claude::records::read_record(
                &local,
                crate::providers::claude::records::MAX_SESSION_RECORD_BYTES,
            )? && let Ok(content) = String::from_utf8(bytes)
            {
                text = content;
            }
        }
        for path in images
            .iter()
            .filter(|p| !p.starts_with("inline:"))
            .chain(sidecars.iter())
        {
            let local = match self.origin.local(std::path::Path::new(path)) {
                Ok(local) => local,
                Err(_) => {
                    self.db.execute(
                        "INSERT OR IGNORE INTO dependency VALUES(?1,?2,'','external_image',NULL,0)",
                        params![self.source, path],
                    )?;
                    continue;
                }
            };
            let identity = match std::fs::metadata(&local) {
                Ok(m) => Some(super::identity(&m)),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
                Err(e) => return Err(e.into()),
            };
            self.db.execute("INSERT INTO dependency(source_id,path,local_path,kind,identity,present) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(source_id,path) DO UPDATE SET identity=excluded.identity,present=excluded.present",params![self.source,path,local.to_string_lossy(),if sidecars.contains(path) {"sidecar"} else {"image"},identity,identity.is_some()])?;
        }
        let reference = SourceRef {
            path: self
                .origin
                .original(self.path)?
                .to_string_lossy()
                .into_owned(),
            offset: self.offset,
            length: self.bytes.len() as u64,
            hash: blake3::hash(self.bytes).to_hex().to_string(),
            pointer: pointer.into(),
            images,
            sidecars: sidecars.clone(),
        };
        self.db.execute("INSERT INTO item(item_key,session_key,turn_id,seq,at,kind,text,text_bytes,source_ref,revision) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",params![item,key,state.turn,(self.offset as i64)*4096+part as i64,at,kind,text,text.len() as i64,serde_json::to_string(&reference)?,self.revision])?;
        if let Some((tool, input)) = call {
            let call_id = value["call_id"].as_str().or_else(|| value["id"].as_str());
            self.db.execute(
                "INSERT INTO tool_call VALUES(?1,?2,?3,?4)",
                params![item, call_id, tool, serde_json::to_string(&input)?],
            )?;
            for (skill, via) in super::skills(tool, &input) {
                self.db.execute(
                    "INSERT OR IGNORE INTO skill_observation VALUES(?1,?2,?3,?4,'unknown',?5)",
                    params![item, key, skill, via, at],
                )?;
            }
        }
        if let Some(result) = result {
            let call_id = result["tool_use_id"]
                .as_str()
                .or_else(|| result["call_id"].as_str());
            let (error, exit, duration) = super::outcome(result, &text);
            self.db.execute(
                "INSERT INTO tool_result VALUES(?1,?2,?3,?4,?5,?6)",
                params![item, call_id, error, exit, duration, sidecars.first()],
            )?;
            let outcome = if error == Some(true) || exit.is_some_and(|v| v != 0) {
                "failed"
            } else if error == Some(false) || exit == Some(0) {
                "ok"
            } else {
                "unknown"
            };
            self.db.execute("UPDATE skill_observation SET outcome=?1 WHERE item_key IN (SELECT c.item_key FROM tool_call c JOIN item i USING(item_key) WHERE c.call_id=?2 AND i.session_key=?3)",params![outcome,call_id,key])?;
        }
        Ok(())
    }
}

fn string(value: &Value) -> Option<String> {
    value.as_str().map(str::to_owned)
}
fn has_tool_result(value: &Value) -> bool {
    value
        .as_array()
        .is_some_and(|a| a.iter().any(|v| v["type"] == "tool_result"))
}
fn text(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Array(a) => a
            .iter()
            .map(text)
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("\n"),
        Value::Object(o) => {
            for field in ["text", "output", "message", "content"] {
                if let Some(v) = o.get(field) {
                    return text(v);
                }
            }
            String::new()
        }
        _ => String::new(),
    }
}
use rusqlite::OptionalExtension;
