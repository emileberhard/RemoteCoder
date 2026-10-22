use super::store::{load, state_path};
use super::{Child, MAX_CHILDREN, Projection, bounded};
use crate::agents::{Message, Output, State};
use anyhow::{Result, ensure};
use serde_json::Value;
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
};

const TAIL_BYTES: u64 = 2 * 1024 * 1024;
const LAST_EVENT_BYTES: u64 = 64 * 1024;

fn subagent_files(session: &Path) -> std::io::Result<Vec<PathBuf>> {
    let folder = session.with_extension("").join("subagents");
    if !folder.exists() {
        return Ok(Vec::new());
    }
    let mut paths = Vec::new();
    for entry in std::fs::read_dir(folder)? {
        let path = entry?.path();
        if path
            .extension()
            .is_some_and(|extension| extension == "jsonl")
            && path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .is_some_and(|stem| stem.starts_with("agent-"))
        {
            paths.push(path);
            if paths.len() > MAX_CHILDREN {
                break;
            }
        }
    }
    paths.sort();
    Ok(paths)
}

pub(crate) fn history_revision(
    session: &Path,
    state: &Path,
) -> std::io::Result<Vec<(PathBuf, Option<crate::storage::file_revision::FileRevision>)>> {
    let mut paths = vec![
        session.to_owned(),
        state.to_owned(),
        session.with_extension("").join("subagents"),
    ];
    for transcript in subagent_files(session)? {
        paths.push(transcript.with_extension("meta.json"));
        paths.push(transcript);
    }
    paths
        .into_iter()
        .map(|path| {
            let revision = match std::fs::metadata(&path) {
                Ok(metadata) => Some(crate::storage::file_revision::FileRevision::from(metadata)),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
                Err(error) => return Err(error),
            };
            Ok((path, revision))
        })
        .collect()
}

pub(crate) fn history(home: &Path, root: &str, session: &Path) -> Result<Projection> {
    let saved = load(home, root)?;
    let saved_written_at = state_path(home, root)
        .ok()
        .and_then(|path| modified_seconds(&path));
    let mut projection = Projection::default();
    let (events, partial) = tail(session)?;
    projection.limited |= partial;
    for value in events {
        projection.ingest(&value);
    }
    projection.overlay_cold(saved, saved_written_at);
    let folder = session.with_extension("").join("subagents");
    if folder.exists() {
        let files = subagent_files(session)?;
        projection.limited |= files.len() > MAX_CHILDREN;
        for path in files.into_iter().take(MAX_CHILDREN) {
            let Some(name) = path
                .file_stem()
                .and_then(|s| s.to_str())
                .and_then(|s| s.strip_prefix("agent-"))
            else {
                continue;
            };
            if path.extension().is_none_or(|s| s != "jsonl") {
                continue;
            }
            if let Some(time) = modified_seconds(&path) {
                projection.transcript_times.insert(name.to_owned(), time);
            }
            let meta = subagent_meta(&path)?;
            let stopped_by_user = meta["stoppedByUser"] == true;
            if let Some(known) = projection
                .children
                .values_mut()
                .find(|c| c.agent_id.as_deref() == Some(name))
            {
                if stopped_by_user && known.state.may_be_running() {
                    known.state = State::Interrupted;
                }
                continue;
            }
            let (events, partial) = head(&path)?;
            let parent = meta["parentAgentId"]
                .as_str()
                .or_else(|| {
                    events.iter().find_map(|v| {
                        v["parentAgentId"]
                            .as_str()
                            .or(v["parent_agent_id"].as_str())
                    })
                })
                .map(str::to_owned);
            let title = meta["description"]
                .as_str()
                .or_else(|| events.iter().find_map(|v| v["agentName"].as_str()))
                .map(|title| bounded(title, 200))
                .unwrap_or_else(|| "Agent".into());
            let last = last_event(&path)?;
            let state = if stopped_by_user {
                State::Interrupted
            } else if last["type"] == "assistant" && last["message"]["stop_reason"] == "end_turn" {
                State::Completed
            } else {
                State::Unknown
            };
            if let Some(child) = projection.child(name) {
                child.agent_id = Some(name.into());
                child.parent_agent_id = parent;
                child.output_file = Some(path.clone());
                child.title = title;
                child.model = meta["model"].as_str().map(str::to_owned);
                child.state = state;
            }
            projection.limited |= partial;
        }
    }
    Ok(projection)
}

pub(crate) fn output(child: &Child, session: &Path) -> Result<Output> {
    let folder = session.with_extension("").join("subagents");
    let native = child
        .agent_id
        .as_ref()
        .map(|id| folder.join(format!("agent-{id}.jsonl")))
        .filter(|path| path.is_file());
    let path = native.or_else(|| {
        child
            .output_file
            .clone()
            .filter(|path| path.starts_with(&folder))
    });
    if let Some(path) = path
        && path.exists()
    {
        let path = path.canonicalize()?;
        ensure!(
            path.starts_with(folder.canonicalize()?),
            "Child output is outside its owning conversation"
        );
        let (events, truncated) = tail(&path)?;
        let mut output = Output {
            messages: Vec::new(),
            truncated,
        };
        for event in events {
            let role = event["message"]["role"].as_str().unwrap_or("");
            if !matches!(role, "user" | "assistant") {
                continue;
            }
            if let Some(blocks) = event["message"]["content"].as_array() {
                for block in blocks {
                    if block["type"] == "text"
                        && let Some(text) = block["text"].as_str()
                    {
                        output.push(role, text);
                    }
                }
            }
        }
        return Ok(output);
    }
    Ok(Output {
        messages: child
            .last_text
            .as_ref()
            .map(|text| {
                vec![Message {
                    role: "assistant".into(),
                    text: text.clone(),
                }]
            })
            .unwrap_or_default(),
        truncated: true,
    })
}

fn modified_seconds(path: &Path) -> Option<i64> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    let seconds = modified
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    i64::try_from(seconds).ok()
}

fn subagent_meta(transcript: &Path) -> Result<Value> {
    let mut bytes = Vec::new();
    match File::open(transcript.with_extension("meta.json")) {
        Ok(file) => file.take(16 * 1024).read_to_end(&mut bytes)?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Value::Null),
        Err(error) => return Err(error.into()),
    };
    Ok(serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}

fn last_event(path: &Path) -> Result<Value> {
    let mut file = File::open(path)?;
    let offset = file.metadata()?.len().saturating_sub(LAST_EVENT_BYTES);
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = Vec::new();
    file.take(LAST_EVENT_BYTES).read_to_end(&mut bytes)?;
    Ok(bytes
        .split(|byte| *byte == b'\n')
        .rfind(|line| !line.is_empty())
        .and_then(|line| serde_json::from_slice(line).ok())
        .unwrap_or(Value::Null))
}

fn head(path: &Path) -> Result<(Vec<Value>, bool)> {
    let mut bytes = Vec::new();
    File::open(path)?.take(16 * 1024).read_to_end(&mut bytes)?;
    let events: Vec<Value> = bytes
        .split(|byte| *byte == b'\n')
        .filter_map(|line| serde_json::from_slice(line).ok())
        .collect();
    let partial = bytes.len() == 16 * 1024 && events.is_empty();
    Ok((events, partial))
}

fn tail(path: &Path) -> Result<(Vec<Value>, bool)> {
    let mut file = File::open(path)?;
    let length = file.metadata()?.len();
    let offset = length.saturating_sub(TAIL_BYTES);
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = Vec::new();
    file.take(TAIL_BYTES).read_to_end(&mut bytes)?;
    let mut lines = bytes.split(|byte| *byte == b'\n');
    if offset != 0 {
        lines.next();
    }
    let events = lines
        .filter_map(|line| serde_json::from_slice(line).ok())
        .collect();
    Ok((events, offset != 0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::claude::tests::tool;
    use serde_json::json;

    #[test]
    fn child_transcript_append_invalidates_history_revision() {
        let directory = tempfile::tempdir().unwrap();
        let session = directory.path().join("root.jsonl");
        let state = directory.path().join("state.json");
        std::fs::write(&session, "").unwrap();
        let folder = session.with_extension("").join("subagents");
        std::fs::create_dir_all(&folder).unwrap();
        let child = folder.join("agent-child.jsonl");
        std::fs::write(&child, "one\n").unwrap();
        let before = history_revision(&session, &state).unwrap();
        std::fs::write(&child, "one\ntwo\n").unwrap();
        let after = history_revision(&session, &state).unwrap();
        assert_ne!(before, after);
    }

    #[test]
    fn activity_is_the_newest_of_event_and_transcript_times() {
        let directory = tempfile::tempdir().unwrap();
        let root = "claude_11111111-1111-4111-8111-111111111111";
        let session = directory
            .path()
            .join("11111111-1111-4111-8111-111111111111.jsonl");
        let folder = session.with_extension("").join("subagents");
        std::fs::create_dir_all(&folder).unwrap();
        let spawn = |tool: &str| json!({"type":"assistant","timestamp":"2026-09-26T10:00:00Z","message":{"content":[{"type":"tool_use","name":"Agent","id":tool,"input":{"description":"Review"}}]}});
        let bound = json!({"type":"user","timestamp":"2026-09-26T10:00:01Z","tool_use_result":{"agentId":"transcribed","isAsync":true},"message":{"content":[{"type":"tool_result","tool_use_id":"transcribed-tool","content":"Started"}]}});
        std::fs::write(
            &session,
            format!(
                "{}\n{bound}\n{}\n",
                spawn("transcribed-tool"),
                spawn("silent-tool")
            ),
        )
        .unwrap();
        for (name, seconds) in [("transcribed", 1_790_424_000), ("file-only", 1_780_000_000)] {
            std::fs::File::create(folder.join(format!("agent-{name}.jsonl")))
                .unwrap()
                .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(seconds))
                .unwrap();
        }
        let agents = history(directory.path(), root, &session)
            .unwrap()
            .agents(root, false);
        let activity = |id: &str| {
            agents
                .iter()
                .find(|agent| agent.id == format!("claude:{root}:{id}"))
                .unwrap()
                .last_active_at
        };
        assert_eq!(activity("transcribed"), Some(1_790_424_000));
        assert_eq!(activity("file-only"), Some(1_780_000_000));
        assert_eq!(activity("silent-tool"), Some(1_790_416_800));
    }

    #[test]
    fn transcript_only_agents_take_title_and_outcome_from_their_own_files() {
        let directory = tempfile::tempdir().unwrap();
        let root = "claude_11111111-1111-4111-8111-111111111111";
        let session = directory
            .path()
            .join("11111111-1111-4111-8111-111111111111.jsonl");
        let folder = session.with_extension("").join("subagents");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(&session, "").unwrap();
        let prompt = json!({"type":"user","message":{"role":"user","content":"Build it"}});
        let reply = |stop: &str| json!({"type":"assistant","message":{"role":"assistant","stop_reason":stop,"content":[{"type":"text","text":"Done"}]}});
        let interrupted = json!({"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}});
        for (name, last, meta) in [
            (
                "finished",
                reply("end_turn"),
                json!({"description":"Build English site","model":"opus"}),
            ),
            (
                "nested",
                reply("end_turn"),
                json!({"description":"Check links","parentAgentId":"finished"}),
            ),
            (
                "stopped",
                interrupted,
                json!({"description":"Stop work","stoppedByUser":true}),
            ),
            ("running", reply("tool_use"), Value::Null),
        ] {
            let transcript = folder.join(format!("agent-{name}.jsonl"));
            std::fs::write(&transcript, format!("{prompt}\n{last}\n")).unwrap();
            if !meta.is_null() {
                std::fs::write(transcript.with_extension("meta.json"), meta.to_string()).unwrap();
            }
        }
        let agents = history(directory.path(), root, &session)
            .unwrap()
            .agents(root, false);
        let agent = |name: &str| {
            agents
                .iter()
                .find(|agent| agent.id == format!("claude:{root}:{name}"))
                .unwrap()
        };
        assert_eq!(agent("finished").title, "Build English site");
        assert_eq!(agent("finished").state, State::Completed);
        assert_eq!(agent("finished").model.as_deref(), Some("opus"));
        let parent = format!("claude:{root}:finished");
        assert_eq!(agent("nested").parent_id.as_deref(), Some(parent.as_str()));
        assert_eq!(agent("stopped").title, "Stop work");
        assert_eq!(agent("stopped").state, State::Interrupted);
        assert_eq!(agent("running").title, "Agent");
        assert_eq!(agent("running").state, State::Unknown);
        let state = state_path(directory.path(), root).unwrap();
        let before = history_revision(&session, &state).unwrap();
        std::fs::write(folder.join("agent-running.meta.json"), "{}").unwrap();
        assert_ne!(history_revision(&session, &state).unwrap(), before);
    }

    #[test]
    fn a_parent_known_agent_the_user_stopped_reads_stopped_and_an_unexplained_one_stays_unknown() {
        let directory = tempfile::tempdir().unwrap();
        let root = "claude_11111111-1111-4111-8111-111111111111";
        let session = directory
            .path()
            .join("11111111-1111-4111-8111-111111111111.jsonl");
        let folder = session.with_extension("").join("subagents");
        std::fs::create_dir_all(&folder).unwrap();
        let mut records = String::new();
        for name in ["stopped", "silent"] {
            let tool_id = format!("tool-{name}");
            let launched = json!({"type":"user","toolUseResult":{"agentId":name,"isAsync":true},"message":{"content":[{"type":"tool_result","tool_use_id":tool_id,"content":"Started"}]}});
            records.push_str(&format!("{}\n{launched}\n", tool(&tool_id, None)));
            let transcript = folder.join(format!("agent-{name}.jsonl"));
            std::fs::write(
                &transcript,
                "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Work\"}}\n",
            )
            .unwrap();
        }
        std::fs::write(&session, records).unwrap();
        std::fs::write(
            folder.join("agent-stopped.meta.json"),
            json!({"description":"Review changes","stoppedByUser":true}).to_string(),
        )
        .unwrap();

        let agents = history(directory.path(), root, &session)
            .unwrap()
            .agents(root, false);
        let state = |name: &str| {
            agents
                .iter()
                .find(|agent| agent.id == format!("claude:{root}:{name}"))
                .map(|agent| agent.state.clone())
        };

        assert_eq!(agents.len(), 2, "{agents:?}");
        assert_eq!(state("stopped"), Some(State::Interrupted));
        assert_eq!(state("silent"), Some(State::Unknown));
    }

    #[test]
    fn output_rejects_escape_and_bounds_oversized_json_lines() {
        let directory = tempfile::tempdir().unwrap();
        let session = directory.path().join("root.jsonl");
        let folder = session.with_extension("").join("subagents");
        std::fs::create_dir_all(&folder).unwrap();
        let file = folder.join("agent-a.jsonl");
        std::fs::write(
            &file,
            format!(
                "{}\n{}\n",
                "x".repeat(TAIL_BYTES as usize + 1),
                json!({"message":{"role":"assistant","content":[{"type":"text","text":"recent"}]}})
            ),
        )
        .unwrap();
        let mut projection = Projection::default();
        let child = projection.child("a").unwrap();
        child.output_file = Some(file);
        let result = output(child, &session).unwrap();
        assert!(result.truncated);
        assert_eq!(result.messages[0].text, "recent");
        let other = directory.path().join("foreign.jsonl");
        std::fs::write(&other, "").unwrap();
        child.output_file = Some(other);
        assert!(output(child, &session).unwrap().messages.is_empty());
    }
}
