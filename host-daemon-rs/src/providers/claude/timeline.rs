//! Reads Claude session JSONL records: session lookup, typed-prompt and
//! injected-record classification for thread headers and history projections.
//!
//! Sessions live at `<claude home>/projects/<cwd slug>/<session uuid>.jsonl`.
//! The slug is lossy, so it is only ever produced forward from a known cwd; a
//! session's real cwd is read back out of the records themselves.

use std::collections::HashMap;
use std::ffi::OsString;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow};
use serde_json::Value;
use walkdir::WalkDir;

use crate::providers::claude::project_slug;

/// Locates a session file by uuid.
///
/// The slug cannot be inverted, so the projects tree is searched by file name.
/// The result must stay inside the configured Claude home.
pub(crate) fn resolve_session_path(session_uuid: &str, claude_home: &Path) -> Result<PathBuf> {
    find_session_path(session_uuid, claude_home)?
        .ok_or_else(|| anyhow!("session not found for {session_uuid}"))
}

#[derive(Default)]
pub(super) struct SessionFiles {
    identities: HashMap<OsString, (u64, u64)>,
}

impl SessionFiles {
    pub(super) fn register(&mut self, path: &Path) -> Result<bool> {
        let name = path
            .file_name()
            .context("Claude session path has no file name")?
            .to_owned();
        let metadata = match path.metadata() {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(error.into()),
        };
        let identity = (metadata.dev(), metadata.ino());
        if let Some(previous) = self.identities.get(&name) {
            anyhow::ensure!(
                *previous == identity,
                "duplicate Claude session UUID {}",
                path.file_stem().unwrap_or_default().to_string_lossy()
            );
            return Ok(false);
        }
        self.identities.insert(name, identity);
        Ok(true)
    }
}

pub(crate) fn find_session_path(session_uuid: &str, claude_home: &Path) -> Result<Option<PathBuf>> {
    let file_name = session_file_name(session_uuid)?;
    let mut unreadable = None;
    let mut found = None;
    let mut files = SessionFiles::default();
    for entry in WalkDir::new(claude_home.join("projects"))
        .min_depth(2)
        .max_depth(2)
    {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) if error.io_error().is_some_and(is_not_found) => continue,
            Err(error) => {
                unreadable.get_or_insert(error);
                continue;
            }
        };
        if entry.file_type().is_file()
            && entry.file_name().to_str() == Some(file_name.as_str())
            && files.register(entry.path())?
        {
            found = Some(contained_session_path(entry.path(), claude_home)?);
        }
    }
    match (found, unreadable) {
        (Some(path), _) => Ok(Some(path)),
        (None, Some(error)) => {
            Err(error).context("Could not search every Claude project directory")
        }
        (None, None) => Ok(None),
    }
}

fn is_not_found(error: &std::io::Error) -> bool {
    error.kind() == std::io::ErrorKind::NotFound
}

pub(crate) fn session_file_name(session_uuid: &str) -> Result<String> {
    if session_uuid.is_empty() || session_uuid.contains('/') || session_uuid.contains("..") {
        return Err(anyhow!("invalid session id {session_uuid}"));
    }
    Ok(format!("{session_uuid}.jsonl"))
}

pub(crate) fn contained_session_path(path: &Path, claude_home: &Path) -> Result<PathBuf> {
    let projects = claude_home.join("projects");
    let canonical = path
        .canonicalize()
        .with_context(|| format!("failed resolving {}", path.display()))?;
    let root = projects.canonicalize().unwrap_or_else(|_| projects.clone());
    if !canonical.starts_with(&root) {
        return Err(anyhow!(
            "session path must be inside the Claude projects directory"
        ));
    }
    Ok(canonical)
}

/// Session file path for a known cwd, used before the file exists.
pub(crate) fn session_path_for_cwd(claude_home: &Path, cwd: &str, session_uuid: &str) -> PathBuf {
    claude_home
        .join("projects")
        .join(project_slug(cwd))
        .join(format!("{session_uuid}.jsonl"))
}

pub(crate) fn existing_recorded_cwd(
    path: &Path,
    session_uuid: &str,
    missing_cwd: &str,
) -> Result<Option<String>> {
    use crate::providers::claude::records::{
        LineKind, MAX_SESSION_RECORD_BYTES, read_bounded_line,
    };
    let mut reader = std::io::BufReader::new(std::fs::File::open(path)?);
    let mut line = Vec::new();
    let mut recorded_missing = false;
    let mut existing = None;
    loop {
        line.clear();
        let (read, kind) = read_bounded_line(&mut reader, &mut line, MAX_SESSION_RECORD_BYTES)?;
        if read == 0 || kind == LineKind::Partial {
            break;
        }
        if kind == LineKind::Oversized {
            continue;
        }
        let Ok(record) = serde_json::from_slice::<Value>(&line) else {
            continue;
        };
        if record["sessionId"].as_str() != Some(session_uuid)
            || !matches!(record["type"].as_str(), Some("user" | "assistant"))
        {
            continue;
        }
        let Some(cwd) = record["cwd"].as_str() else {
            continue;
        };
        recorded_missing |= cwd == missing_cwd;
        if Path::new(cwd).is_absolute() && Path::new(cwd).is_dir() {
            existing = Some(cwd.to_owned());
        }
    }
    Ok(existing.filter(|_| recorded_missing))
}

pub(crate) fn queued_user_prompt(record: &Value) -> Option<(String, &str)> {
    let attachment = record.get("attachment")?;
    if attachment.get("type").and_then(Value::as_str) != Some("queued_command")
        || attachment.get("commandMode").and_then(Value::as_str) != Some("prompt")
        || attachment.get("isMeta").and_then(Value::as_bool) == Some(true)
    {
        return None;
    }
    let source_id = attachment.get("source_uuid").and_then(Value::as_str)?;
    let prompt = user_prompt_text(attachment.get("prompt"))?;
    (!is_injected_user_text(&prompt)).then_some((prompt, source_id))
}

/// Extracts a real user prompt, or `None` when the record is tool output.
/// Voice delegation envelopes render as the spoken input they carry.
pub(crate) fn user_prompt_text(content: Option<&Value>) -> Option<String> {
    let text = match content? {
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return None;
            }
            trimmed.to_string()
        }
        Value::Array(parts) => {
            if parts
                .iter()
                .any(|part| part.get("type").and_then(Value::as_str) == Some("tool_result"))
            {
                return None;
            }
            let text = parts
                .iter()
                .filter(|part| part.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n");
            let trimmed = text.trim();
            if trimmed.is_empty() {
                // An attachment with no caption is still a user message; dropping it
                // left the turn looking like it began with no prompt at all.
                let has_image = parts
                    .iter()
                    .any(|part| part.get("type").and_then(Value::as_str) == Some("image"));
                if has_image {
                    return Some("Image attachment".to_string());
                }
                return None;
            }
            trimmed.to_string()
        }
        _ => return None,
    };
    if is_abort_marker(&text) {
        return None;
    }
    Some(crate::voice::handoff::delegation_display_text(&text).unwrap_or(text))
}

/// Claude Code writes `[Request interrupted by user...]` into the session file
/// whenever a turn is aborted mid-flight — including when the gateway or the OS
/// killed the process, which is not the user at all. Replaying it as a prompt
/// both fabricates a message the user never sent and splits the turn it cut off.
pub(crate) fn is_turn_end_stop_reason(reason: &str) -> bool {
    matches!(
        reason,
        "end_turn" | "stop_sequence" | "max_tokens" | "refusal"
    )
}

pub(crate) fn is_abort_marker(text: &str) -> bool {
    text.starts_with("[Request interrupted by user")
}

/// Text envelopes Claude Code writes as `user` records the user never typed:
/// background-task completions, injected reminders, and the slash-command
/// plumbing around local command execution. None of them carry a record-level
/// flag, so they are recognized by the envelope itself.
const INJECTED_TEXT_ENVELOPES: [&str; 7] = [
    "<task-notification>",
    "<system-reminder>",
    "<local-command-caveat>",
    "<local-command-stdout>",
    "<local-command-stderr>",
    "<command-name>",
    "<command-message>",
];

/// True for a `user` record the harness wrote rather than the user: skill and
/// context injections (`isMeta`), compaction preambles (`isCompactSummary`),
/// and the text envelopes above. A turn boundary means the user said something;
/// these are neither boundaries nor bubbles.
///
/// Codex needs no equivalent: its rollout `event_msg`/`user_message` channel
/// carries only genuinely typed input (verified across every 2026 rollout on
/// this host), and injected instructions arrive as `response_item` records the
/// Codex reader already ignores.
pub(crate) fn is_injected_user_record(record: &Value, content: Option<&Value>) -> bool {
    let flag = |name: &str| record.get(name).and_then(Value::as_bool) == Some(true);
    // The CLI projects transcript metadata to `isSynthetic` in stream-json.
    if flag("isMeta") || flag("isCompactSummary") || flag("isSynthetic") {
        return true;
    }

    let leading_text = match content {
        Some(Value::String(text)) => text.trim_start(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter(|part| part.get("type").and_then(Value::as_str) == Some("text"))
            .find_map(|part| part.get("text").and_then(Value::as_str))
            .map(str::trim_start)
            .unwrap_or_default(),
        _ => return false,
    };
    is_injected_user_text(leading_text)
}

pub(crate) fn is_injected_user_text(text: &str) -> bool {
    INJECTED_TEXT_ENVELOPES
        .iter()
        .any(|envelope| text.trim_start().starts_with(envelope))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::{parse_rfc3339_millis, parse_rfc3339_seconds};
    use serde_json::json;
    use std::fs;
    use std::io::Write;

    fn write_session(dir: &Path, cwd: &str, uuid: &str, lines: &[Value]) -> PathBuf {
        let project = dir.join("projects").join(project_slug(cwd));
        fs::create_dir_all(&project).expect("create project dir");
        let path = project.join(format!("{uuid}.jsonl"));
        let mut file = fs::File::create(&path).expect("create session file");
        for line in lines {
            writeln!(file, "{}", serde_json::to_string(line).expect("json")).expect("write");
        }
        path
    }

    #[test]
    fn a_session_lookup_reports_unreadable_coverage_instead_of_absence() {
        use std::os::unix::fs::PermissionsExt;

        let home = tempfile::tempdir().unwrap();
        let found = write_session(home.path(), "/repo/a", "found", &[json!({"type":"user"})]);
        let blocked = home.path().join("projects/blocked");
        fs::create_dir_all(&blocked).unwrap();
        fs::set_permissions(&blocked, fs::Permissions::from_mode(0o000)).unwrap();

        let missing = find_session_path("missing", home.path());
        let existing = find_session_path("found", home.path());
        fs::set_permissions(&blocked, fs::Permissions::from_mode(0o755)).unwrap();

        assert!(missing.is_err());
        assert_eq!(existing.unwrap(), Some(found.canonicalize().unwrap()));
        assert_eq!(
            find_session_path("missing", &home.path().join("none")).unwrap(),
            None
        );
    }

    #[test]
    fn a_session_deleted_after_enumeration_is_skipped_by_identity_registration() {
        let home = tempfile::tempdir().unwrap();
        write_session(home.path(), "/repo", "vanished", &[json!({"type":"user"})]);
        let candidate = WalkDir::new(home.path().join("projects"))
            .min_depth(2)
            .max_depth(2)
            .into_iter()
            .map(Result::unwrap)
            .find(|entry| entry.file_type().is_file())
            .unwrap();
        fs::remove_file(candidate.path()).unwrap();
        assert!(!SessionFiles::default().register(candidate.path()).unwrap());
        assert_eq!(find_session_path("vanished", home.path()).unwrap(), None);
    }

    #[test]
    fn session_path_lands_under_the_project_slug() {
        let path = session_path_for_cwd(
            Path::new("/Users/developer/.claude"),
            "/Users/developer/RemoteCoder",
            "sess-1",
        );

        assert_eq!(
            path,
            PathBuf::from(
                "/Users/developer/.claude/projects/-Users-developer-RemoteCoder/sess-1.jsonl"
            )
        );
    }

    #[test]
    fn the_history_preview_skips_injected_records() {
        let home = tempfile::tempdir().expect("tempdir");
        let cwd = "/repo/app";
        let lines = vec![
            json!({
                "type":"user","cwd":cwd,"version":"2.1.234","isSidechain":false,"isMeta":true,
                "timestamp":"2026-08-16T13:35:17.605Z",
                "message":{"role":"user","content":"<local-command-caveat>Caveat: the messages below…</local-command-caveat>"}
            }),
            json!({
                "type":"user","cwd":cwd,"isSidechain":false,
                "timestamp":"2026-08-16T13:35:18.000Z",
                "message":{"role":"user","content":"real question"}
            }),
        ];
        write_session(home.path(), cwd, "sess-preview", &lines);

        let threads = crate::providers::claude::history::HistoryIndex::default()
            .list_threads(home.path(), 30)
            .expect("threads");
        assert_eq!(threads.len(), 1);
        assert_eq!(threads[0]["preview"], json!("real question"));
    }

    #[test]
    fn session_lookup_rejects_traversal() {
        let home = tempfile::tempdir().expect("tempdir");

        assert!(resolve_session_path("../../etc/passwd", home.path()).is_err());
        assert!(resolve_session_path("", home.path()).is_err());
    }

    #[test]
    fn timestamps_parse_to_unix_seconds() {
        assert_eq!(
            parse_rfc3339_seconds("2026-08-16T13:35:17.605Z"),
            Some(1_786_887_317)
        );
        assert_eq!(parse_rfc3339_seconds("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_rfc3339_seconds("1970-01-01T01:00:00+01:00"), Some(0));
        assert_eq!(
            parse_rfc3339_seconds("2000-03-01T00:00:00Z"),
            Some(951_868_800)
        );
        assert_eq!(parse_rfc3339_seconds("not-a-timestamp"), None);
        assert_eq!(
            parse_rfc3339_millis("2026-08-16T13:35:17.605Z"),
            Some(1_786_887_317_605)
        );
        assert_eq!(
            parse_rfc3339_millis("1970-01-01T00:00:01.5+00:00"),
            Some(1_500)
        );
        assert!(parse_rfc3339_millis("2024-02-29T00:00:00Z").is_some());
        for timestamp in [
            "2026-02-29T00:00:00Z",
            "2026-04-31T00:00:00Z",
            "2026-08-16T13:35Z",
            "2026-08-16T13:35:17:42Z",
            "2026-08-16T-1:35:17Z",
            "2026-08-16T13:35:17.Z",
            "2026-08-16T13:35:17.6junkZ",
            "2026-08-16T13:35:17+-01:00",
            "2026-08-16T13:35:17+01:-01",
            "999999999999999999-08-16T13:35:17Z",
        ] {
            assert_eq!(parse_rfc3339_millis(timestamp), None, "{timestamp}");
        }
    }
}
