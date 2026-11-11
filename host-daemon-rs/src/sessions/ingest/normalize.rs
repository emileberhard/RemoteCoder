use super::{Origin, SourceRef};
use anyhow::{Context, Result};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug)]
pub(super) struct IdentityConflict {
    pub key: String,
}

impl std::fmt::Display for IdentityConflict {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("Conflicting provider session identity in different source files")
    }
}

impl std::error::Error for IdentityConflict {}

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
    #[serde(default)]
    native_user_messages: bool,
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
            .transpose()
            .map_err(|error| {
                if self.origin.provider == "codex" && value["type"] == "session_meta" {
                    error.context(super::InvalidHeader("Invalid Codex session metadata"))
                } else {
                    error
                }
            })?;
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
                Some("user_message") => {
                    let text = p["message"].as_str().unwrap_or_default();
                    if !state.native_user_messages
                        && let Some(thread) = &state.thread
                    {
                        self.db.execute("UPDATE item SET kind='system' WHERE session_key=?1 AND turn_id IS ?2 AND kind='user' AND text=?3 AND json_extract(source_ref,'$.pointer')='/payload/content'", params![super::super::session_key(self.origin,thread),state.turn,text])?;
                    }
                    state.native_user_messages = true;
                    self.item(
                        state,
                        at,
                        0,
                        if crate::providers::codex::user_text::is_typed(text) {
                            "user"
                        } else {
                            "system"
                        },
                        text.to_owned(),
                        "/payload/message",
                        p,
                        None,
                        None,
                    )?;
                }
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
                        let legacy = (p["role"] == "user" && !state.native_user_messages)
                            .then(|| {
                                crate::providers::codex::user_text::legacy_message(&p["content"])
                            })
                            .flatten();
                        let role = match p["role"].as_str() {
                            Some("user") if legacy.is_some() => "user",
                            Some("user") => "system",
                            Some("assistant") => "assistant",
                            _ => "system",
                        };
                        self.item(
                            state,
                            at,
                            0,
                            role,
                            legacy.unwrap_or_else(|| text(&p["content"])),
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
            let root = self.origin.path();
            let relative = self.path.strip_prefix(&root)?;
            let mut parts = relative.iter();
            parts
                .next()
                .context("Claude transcript has no project directory")?;
            let session = parts
                .next()
                .context("Claude transcript has no session filename")?;
            if parts
                .next()
                .is_some_and(|directory| directory == "subagents")
            {
                let parent = session
                    .to_str()
                    .context("Native child has no owning session")?;
                let child = stem
                    .strip_prefix("agent-")
                    .context("Native child has no agent filename")?;
                state.thread = Some(crate::providers::claude::subagent_thread_id(parent, child));
                state.parent = Some(crate::providers::claude::claude_thread_id(parent));
            } else {
                state.thread = Some(crate::providers::claude::claude_thread_id(stem));
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
        if let Some((prompt, _)) = crate::providers::claude::timeline::queued_user_prompt(v)
            && !crate::agents::envelope::is_message(&prompt)
        {
            self.item(
                state,
                at,
                0,
                "user",
                prompt,
                "/attachment/prompt",
                &v["attachment"]["prompt"],
                None,
                None,
            )?;
        }
        if !matches!(v["type"].as_str(), Some("user" | "assistant")) {
            return Ok(());
        }
        state.model = string(&message["model"]).or(state.model.take());
        let typed_user = v["type"] == "user"
            && !crate::providers::claude::timeline::is_injected_user_record(
                v,
                message.get("content"),
            )
            && !has_tool_result(&message["content"])
            && !crate::agents::envelope::is_message(&text(&message["content"]));
        if typed_user {
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
                                if typed_user { "user" } else { "system" }
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
                    if typed_user { "user" } else { "system" }
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
        let thread = state.thread.as_ref().ok_or(super::InvalidHeader(
            "Missing exact provider session identity",
        ))?;
        let key = super::super::session_key(self.origin, thread);
        let existing: Option<i64> = self
            .db
            .query_row(
                "SELECT source_id FROM session WHERE session_key=?1",
                [&key],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(existing) = existing.filter(|id| *id != self.source) {
            let owner: String = self.db.query_row(
                "SELECT local_path FROM source WHERE source_id=?1",
                [existing],
                |row| row.get(0),
            )?;
            let gone = matches!(std::fs::symlink_metadata(owner), Err(error) if error.kind() == std::io::ErrorKind::NotFound);
            if !gone || !self.origin.path().is_dir() {
                return Err(IdentityConflict { key }.into());
            }
            self.db
                .execute("DELETE FROM session WHERE source_id=?1", [existing])?;
            self.db
                .execute("DELETE FROM source WHERE source_id=?1", [existing])?;
        }
        self.db.execute("INSERT OR IGNORE INTO session(session_key,origin_host,provider,provider_home,thread_id,source_id,thread_id_reversed) VALUES(?1,?2,?3,?4,?5,?6,?7)",params![key,self.origin.host,self.origin.provider,self.origin.provider_home.to_string_lossy(),thread,self.source,thread.bytes().rev().collect::<Vec<_>>()])?;
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
        let item = super::super::item_key(&key, self.offset, part);
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
            let Ok(local) = self.origin.local(std::path::Path::new(path)) else {
                continue;
            };
            let identity = super::file_identity(&local)?;
            self.db.execute("INSERT INTO dependency(source_id,path,local_path,kind,identity,present,origin_host) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(source_id,path) DO UPDATE SET identity=excluded.identity,present=excluded.present",params![self.source,path,local.to_string_lossy(),if sidecars.contains(path) {"sidecar"} else {"image"},identity,identity.is_some(),self.origin.host])?;
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

pub(super) fn save_session(
    db: &Connection,
    origin: &Origin,
    source: i64,
    state: &State,
) -> Result<()> {
    if let Some(thread) = &state.thread {
        db.execute("INSERT INTO session(session_key,origin_host,provider,provider_home,thread_id,cwd,title,started_at,last_at,parent_session_key,source_id,thread_id_reversed) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12) ON CONFLICT(session_key) DO UPDATE SET cwd=excluded.cwd,title=CASE WHEN session.provider='codex' THEN coalesce(excluded.title,session.title) ELSE excluded.title END,started_at=excluded.started_at,last_at=excluded.last_at,parent_session_key=excluded.parent_session_key WHERE session.source_id=excluded.source_id",params![super::super::session_key(origin,thread),origin.host,origin.provider,origin.provider_home.to_string_lossy(),thread,state.cwd,state.title,state.first,state.last,state.parent.as_ref().map(|p|super::super::session_key(origin,p)),source,thread.bytes().rev().collect::<Vec<_>>()])?;
    }
    Ok(())
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
