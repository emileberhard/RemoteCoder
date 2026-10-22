use indexmap::IndexMap;
use std::collections::HashSet;
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::{Value, json, value::RawValue};
use walkdir::WalkDir;

use crate::providers::claude::claude_thread_id;
use crate::providers::claude::projection::{
    CacheOutcome, HistoryError, Projection, ProjectionCache,
};
use crate::providers::claude::records::{
    LineKind, MAX_SESSION_RECORD_BYTES, SYNTHETIC_MODEL, read_bounded_line,
};
use crate::providers::claude::timeline::{
    find_session_path, is_abort_marker, is_injected_user_text, is_turn_end_stop_reason,
    resolve_session_path, session_file_name,
};
use crate::storage::file_revision::FileRevision;
use crate::time::parse_rfc3339_seconds;

mod list;
mod reads;
pub(crate) use list::ThreadListQuery;

/// One provider-owned projection shared by list/read/resume. Filesystem dates
/// invalidate cached headers; only conversation records determine activity.
pub(crate) struct ClaudeHistory {
    home: PathBuf,
    index: Arc<reads::Headers>,
    projections: Arc<ProjectionCache>,
    pagination: Arc<tokio::sync::Semaphore>,
}

impl ClaudeHistory {
    pub fn new(home: PathBuf, projections: Arc<ProjectionCache>) -> Self {
        Self {
            home,
            index: Arc::new(reads::Headers::default()),
            projections,
            pagination: Arc::new(tokio::sync::Semaphore::new(4)),
        }
    }

    pub(crate) async fn read_projection<T: Send + 'static>(
        &self,
        thread_id: &str,
        active_turn: Option<String>,
        read: impl FnOnce(&Projection, &File, &Path) -> Result<T, HistoryError> + Send + 'static,
    ) -> Result<(T, CacheOutcome), HistoryError> {
        let session_uuid = crate::providers::claude::session_uuid_from_thread_id(thread_id)
            .filter(|uuid| session_file_name(uuid).is_ok())
            .ok_or_else(|| HistoryError::InvalidRequest(format!("invalid thread id: {thread_id}")))?
            .to_string();
        let home = self.home.clone();
        let thread_id = thread_id.to_string();
        let projections = Arc::clone(&self.projections);
        tokio::task::spawn_blocking(move || {
            let path = find_session_path(&session_uuid, &home)?.ok_or_else(|| {
                HistoryError::InvalidRequest(format!("no rollout found for thread id {thread_id}"))
            })?;
            projections.read(
                &home,
                &thread_id,
                &path,
                active_turn.as_deref(),
                |projection, file| read(projection, file, &path),
            )
        })
        .await
        .map_err(|error| {
            HistoryError::Internal(anyhow::anyhow!("Claude history worker failed: {error}"))
        })?
    }

    pub(crate) async fn list_threads(&self, query: ThreadListQuery) -> Result<Value, HistoryError> {
        let headers = self.index.list(self.home.clone()).await?;
        self.paginate(move || query.page(headers.iter())).await
    }

    async fn paginate(
        &self,
        read: impl FnOnce() -> Result<Value, HistoryError> + Send + 'static,
    ) -> Result<Value, HistoryError> {
        let permit = Arc::clone(&self.pagination)
            .acquire_owned()
            .await
            .map_err(|error| {
                HistoryError::Internal(anyhow::anyhow!("Claude pagination owner stopped: {error}"))
            })?;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            read()
        })
        .await
        .map_err(|error| {
            HistoryError::Internal(anyhow::anyhow!("Claude history worker failed: {error}"))
        })?
    }

    pub(crate) async fn read_thread_header(&self, session_uuid: String) -> Result<Value> {
        self.index.read(self.home.clone(), session_uuid).await
    }

    pub(crate) async fn session_path(&self, session_uuid: String) -> Result<PathBuf> {
        let home = self.home.clone();
        tokio::task::spawn_blocking(move || resolve_session_path(&session_uuid, &home))
            .await
            .context("Claude history worker failed")?
    }
}

const MAX_HEADER_CACHE_BYTES: usize = 16 << 20;
const MAX_HEADER_CACHE_ENTRIES: usize = 4_096;

struct CachedHeader {
    revision: FileRevision,
    header: Option<Value>,
    bytes: usize,
}

#[derive(Clone, Default)]
pub(crate) struct HistoryIndex {
    entries: IndexMap<PathBuf, Arc<CachedHeader>>,
    cache_bytes: usize,
    header_scans: u64,
}

#[derive(Clone, Copy)]
enum CacheAdmission {
    Read,
    Scan,
}

impl HistoryIndex {
    pub(crate) fn list_threads(&mut self, home: &Path, limit: usize) -> Result<Vec<Value>> {
        let projects = home.join("projects");
        if !projects.exists() {
            self.entries.clear();
            self.cache_bytes = 0;
            return Ok(Vec::new());
        }
        let projects = projects
            .canonicalize()
            .context("Could not resolve Claude projects directory")?;
        anyhow::ensure!(projects.is_dir(), "Claude projects path is not a directory");
        let mut seen = HashSet::new();
        let mut session_files = super::timeline::SessionFiles::default();
        let scans_before = self.header_scans;
        let mut threads = Vec::new();
        for entry in WalkDir::new(&projects).min_depth(2).max_depth(2) {
            let entry = entry.context("Could not enumerate Claude sessions")?;
            let path = entry.path();
            if !entry.file_type().is_file()
                || path.extension().and_then(|ext| ext.to_str()) != Some("jsonl")
            {
                continue;
            }
            if !session_files.register(path)? {
                continue;
            }
            seen.insert(path.to_path_buf());
            if let Some(header) = self.header_with_admission(path, CacheAdmission::Scan)? {
                threads.push(header);
            }
        }
        self.entries.retain(|path, _| seen.contains(path));
        self.cache_bytes = self.entries.values().map(|entry| entry.bytes).sum();
        threads.sort_by(|a, b| {
            b["updatedAt"]
                .as_i64()
                .cmp(&a["updatedAt"].as_i64())
                .then_with(|| a["id"].as_str().cmp(&b["id"].as_str()))
        });
        // Imported or rewritten files can have arbitrarily new mtimes. Every
        // candidate needs its real activity date before the limit is applied.
        tracing::debug!(
            headers_scanned = self.header_scans.wrapping_sub(scans_before),
            sessions = threads.len(),
            cached_headers = self.entries.len(),
            "Claude header scan"
        );
        threads.truncate(limit);
        Ok(threads)
    }

    fn remove_cached_header(&mut self, path: &Path) {
        if let Some(entry) = self.entries.shift_remove(path) {
            self.cache_bytes -= entry.bytes;
        }
    }

    fn store(
        &mut self,
        path: PathBuf,
        entry: Option<Arc<CachedHeader>>,
        admission: CacheAdmission,
    ) {
        self.remove_cached_header(&path);
        let Some(entry) = entry else { return };
        let fits = self.entries.len() < MAX_HEADER_CACHE_ENTRIES
            && self.cache_bytes <= MAX_HEADER_CACHE_BYTES.saturating_sub(entry.bytes);
        if entry.bytes > MAX_HEADER_CACHE_BYTES
            || matches!(admission, CacheAdmission::Scan) && !fits
        {
            return;
        }
        while self.entries.len() >= MAX_HEADER_CACHE_ENTRIES
            || self.cache_bytes > MAX_HEADER_CACHE_BYTES - entry.bytes
        {
            if let Some((_, evicted)) = self.entries.shift_remove_index(0) {
                self.cache_bytes -= evicted.bytes;
            } else {
                break;
            }
        }
        self.cache_bytes += entry.bytes;
        self.entries.insert(path, entry);
    }

    fn header(&mut self, path: &Path) -> Result<Option<Value>> {
        self.header_with_admission(path, CacheAdmission::Read)
    }

    fn header_with_admission(
        &mut self,
        path: &Path,
        admission: CacheAdmission,
    ) -> Result<Option<Value>> {
        let file = match File::open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                self.remove_cached_header(path);
                return Ok(None);
            }
            Err(error) => {
                return Err(error).with_context(|| format!("Could not open {}", path.display()));
            }
        };
        let revision = FileRevision::from(file.metadata()?);
        if let Some(entry) = self.entries.shift_remove(path) {
            if entry.revision == revision {
                let header = entry.header.clone();
                self.entries.insert(path.to_path_buf(), entry);
                return Ok(header);
            }
            self.cache_bytes -= entry.bytes;
        }

        // Rebuild changed files, including in-place rewrites and truncations.
        // An append-only cursor cannot safely represent Claude's mutable logs.
        self.header_scans = self.header_scans.wrapping_add(1);
        let header = read_header(&file, revision.length)
            .with_context(|| format!("Could not index {}", path.display()))?
            .thread(path);
        if FileRevision::from(file.metadata()?) == revision {
            let bytes = header
                .as_ref()
                .map_or(0, |header| header.to_string().len())
                .saturating_mul(4)
                .saturating_add(path.as_os_str().len())
                .saturating_add(1_024);
            self.store(
                path.to_path_buf(),
                Some(Arc::new(CachedHeader {
                    revision,
                    header: header.clone(),
                    bytes,
                })),
                admission,
            );
        } else {
            // A writer advanced during this bounded read. The next request must
            // scan it again rather than reuse this complete-record prefix.
            self.remove_cached_header(path);
        }
        Ok(header)
    }
}

#[derive(Default)]
struct Header {
    cwd: Option<String>,
    version: Option<String>,
    custom_title: Option<String>,
    ai_title: Option<String>,
    first_prompt: Option<String>,
    created_at: Option<i64>,
    updated_at: Option<i64>,
    recency_at: Option<i64>,
    last_turn_completed_at: Option<i64>,
    model: Option<String>,
    effort: Option<String>,
    settings_updated_at: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record<'a> {
    #[serde(rename = "type")]
    kind: String,
    timestamp: Option<String>,
    subtype: Option<String>,
    cwd: Option<String>,
    version: Option<String>,
    custom_title: Option<String>,
    ai_title: Option<String>,
    effort: Option<String>,
    #[serde(default)]
    is_sidechain: bool,
    #[serde(default)]
    is_meta: bool,
    #[serde(default)]
    is_compact_summary: bool,
    #[serde(default)]
    is_synthetic: bool,
    #[serde(rename = "parentToolUseID", alias = "parent_tool_use_id", borrow)]
    parent_tool: Option<&'a RawValue>,
    #[serde(borrow)]
    message: Option<&'a RawValue>,
}

#[derive(Deserialize)]
struct Message {
    content: Option<Content>,
}

#[derive(Deserialize)]
struct AssistantSettings {
    model: Option<String>,
    stop_reason: Option<String>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Content {
    Text(String),
    Blocks(Vec<Block>),
}

#[derive(Deserialize)]
struct Block {
    #[serde(rename = "type")]
    kind: String,
    text: Option<String>,
}

fn read_header(file: &File, length: u64) -> Result<Header> {
    let mut header = Header::default();
    let mut reader = BufReader::new(file.take(length));
    let mut line = Vec::new();
    let mut offset = 0;
    loop {
        line.clear();
        let (read, kind) = read_bounded_line(&mut reader, &mut line, MAX_SESSION_RECORD_BYTES)?;
        let line_offset = offset;
        offset += read;
        match kind {
            LineKind::Complete => {}
            LineKind::Partial => break,
            LineKind::Oversized => continue,
        }
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let record: Record<'_> = serde_json::from_slice(&line)
            .with_context(|| format!("Invalid Claude session record at byte {line_offset}"))?;
        if record.is_sidechain || record.parent_tool.is_some() {
            continue;
        }
        if header.cwd.is_none() {
            header.cwd = record.cwd;
        }
        if header.version.is_none() {
            header.version = record.version;
        }
        let active = match record.kind.as_str() {
            "system" if record.subtype.as_deref() == Some("turn_duration") => {
                // Older CLI logs may only retain the terminal duration record.
                // Do not advance an already recorded end for that same turn.
                if header.updated_at > header.last_turn_completed_at {
                    header.note_completion(record.timestamp.as_deref());
                }
                false
            }
            "custom-title" => {
                header.custom_title = record.custom_title.filter(|s| !s.trim().is_empty());
                false
            }
            "ai-title" => {
                header.ai_title = record.ai_title.filter(|s| !s.trim().is_empty());
                false
            }
            "assistant" => {
                if let Some(raw) = record.message {
                    let message: AssistantSettings = serde_json::from_str(raw.get())?;
                    if message.model.as_deref() == Some(SYNTHETIC_MODEL) {
                        continue;
                    }
                    if message
                        .stop_reason
                        .as_deref()
                        .is_some_and(is_turn_end_stop_reason)
                    {
                        header.note_completion(record.timestamp.as_deref());
                    }
                    if let Some(model) = message.model.filter(|model| !model.starts_with('<'))
                        && let Some(timestamp) =
                            record.timestamp.as_deref().and_then(parse_rfc3339_seconds)
                        && header
                            .settings_updated_at
                            .is_none_or(|previous| timestamp >= previous)
                    {
                        header.model = Some(model);
                        header.effort = record.effort;
                        header.settings_updated_at = Some(timestamp);
                    }
                    true
                } else {
                    false
                }
            }
            "user" if !record.is_meta && !record.is_compact_summary && !record.is_synthetic => {
                let Some(raw) = record.message else { continue };
                let message: Message = serde_json::from_str(raw.get())?;
                let Some(content) = message.content else {
                    continue;
                };
                if content.is_abort() {
                    header.note_completion(record.timestamp.as_deref());
                    false
                } else if let Content::Blocks(blocks) = &content
                    && blocks.iter().any(|block| block.kind == "tool_result")
                {
                    true
                } else if let Some(prompt) = content.prompt() {
                    header.first_prompt.get_or_insert(prompt);
                    if let Some(timestamp) =
                        record.timestamp.as_deref().and_then(parse_rfc3339_seconds)
                    {
                        header.recency_at = Some(
                            header
                                .recency_at
                                .map_or(timestamp, |old| old.max(timestamp)),
                        );
                    }
                    true
                } else {
                    false
                }
            }
            _ => false,
        };
        if active
            && let Some(timestamp) = record.timestamp.as_deref().and_then(parse_rfc3339_seconds)
        {
            header.created_at = Some(
                header
                    .created_at
                    .map_or(timestamp, |old| old.min(timestamp)),
            );
            header.updated_at = Some(
                header
                    .updated_at
                    .map_or(timestamp, |old| old.max(timestamp)),
            );
        }
    }
    Ok(header)
}

impl Content {
    fn is_abort(&self) -> bool {
        match self {
            Self::Text(text) => is_abort_marker(text),
            Self::Blocks(blocks) => blocks.iter().any(|block| {
                block.kind == "text" && block.text.as_deref().is_some_and(is_abort_marker)
            }),
        }
    }

    fn prompt(self) -> Option<String> {
        let text = match self {
            Self::Text(text) => text,
            Self::Blocks(blocks) => {
                let text = blocks
                    .iter()
                    .filter(|block| block.kind == "text")
                    .filter_map(|block| block.text.as_deref())
                    .collect::<Vec<_>>()
                    .join("\n");
                if text.trim().is_empty() && blocks.iter().any(|block| block.kind == "image") {
                    return Some("Image attachment".to_string());
                }
                text
            }
        };
        let text = text.trim();
        if text.is_empty() || is_injected_user_text(text) || is_abort_marker(text) {
            return None;
        }
        Some(
            crate::voice::handoff::delegation_display_text(text)
                .unwrap_or_else(|| text.to_string()),
        )
    }
}

impl Header {
    fn note_completion(&mut self, timestamp: Option<&str>) {
        if let Some(timestamp) = timestamp.and_then(parse_rfc3339_seconds) {
            self.last_turn_completed_at = Some(
                self.last_turn_completed_at
                    .map_or(timestamp, |old| old.max(timestamp)),
            );
        }
    }

    fn thread(self, path: &Path) -> Option<Value> {
        let session_uuid = path.file_stem()?.to_str()?;
        let preview = self
            .ai_title
            .or_else(|| {
                self.first_prompt
                    .map(|prompt| crate::prompt_summary::prompt_summary(&prompt).to_string())
            })
            .unwrap_or_else(|| "(untitled)".to_string());
        Some(json!({
            "id": claude_thread_id(session_uuid), "preview": preview.chars().take(200).collect::<String>(),
            "name": self.custom_title,
            "modelProvider": "claude", "createdAt": self.created_at?, "updatedAt": self.updated_at?,
            "recencyAt": self.recency_at,
            "lastTurnCompletedAt": self.last_turn_completed_at,
            "model": self.model, "reasoningEffort": self.effort,
            "path": path.to_string_lossy(), "cwd": self.cwd?, "cliVersion": self.version.unwrap_or_default(),
            "source": "appServer", "status": { "type": "notLoaded" }, "ephemeral": false, "turns": [],
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;

    pub(super) fn session(home: &Path, id: &str, records: &[Value]) -> PathBuf {
        let project = home.join("projects/repo");
        fs::create_dir_all(&project).unwrap();
        let path = project.join(format!("{id}.jsonl"));
        let mut file = File::create(&path).unwrap();
        for record in records {
            writeln!(file, "{record}").unwrap();
        }
        path
    }

    pub(super) fn message(role: &str, timestamp: &str) -> Value {
        json!({"type":role,"timestamp":timestamp,"cwd":"/repo", "version":"test",
            "message":{"role":role,"content":"hello"}})
    }

    #[tokio::test]
    async fn discovery_review_cancelled_pagination_retains_its_work_budget() {
        let home = tempfile::tempdir().unwrap();
        let history = Arc::new(ClaudeHistory::new(
            home.path().into(),
            Arc::new(ProjectionCache::new(32 << 20)),
        ));
        let mut releases = Vec::new();
        for _ in 0..4 {
            let (started, observed) = tokio::sync::oneshot::channel();
            let (release, blocked) = std::sync::mpsc::channel::<()>();
            releases.push(release);
            let owner = Arc::clone(&history);
            let task = tokio::spawn(async move {
                owner
                    .paginate(move || {
                        started.send(()).unwrap();
                        let _ = blocked.recv();
                        Ok(Value::Null)
                    })
                    .await
            });
            observed.await.unwrap();
            task.abort();
            let _ = task.await;
        }
        let (started, mut observed) = tokio::sync::oneshot::channel();
        let owner = Arc::clone(&history);
        let task = tokio::spawn(async move {
            owner
                .paginate(move || {
                    started.send(()).unwrap();
                    Ok(Value::Null)
                })
                .await
        });
        let premature =
            tokio::time::timeout(std::time::Duration::from_secs(1), &mut observed).await;
        drop(releases);
        task.await.unwrap().unwrap();
        assert!(
            premature.is_err(),
            "cancelled pagination admitted extra blocking work"
        );
    }

    #[tokio::test]
    async fn duplicate_session_uuids_are_rejected_by_list_headers_paths_and_projection_reads() {
        let home = tempfile::tempdir().unwrap();
        let id = "11111111-2222-4333-8444-555555555555";
        let original = session(home.path(), id, &[message("user", "2026-09-20T10:00:00Z")]);
        let history =
            ClaudeHistory::new(home.path().into(), Arc::new(ProjectionCache::new(32 << 20)));
        history.read_thread_header(id.into()).await.unwrap();
        let other = home.path().join("projects/other");
        fs::create_dir_all(&other).unwrap();
        fs::write(
            other.join(format!("{id}.jsonl")),
            format!("{}\n", message("user", "2026-09-20T11:00:00Z")),
        )
        .unwrap();
        let errors = [
            format!(
                "{:?}",
                history
                    .list_threads(ThreadListQuery::new(10, None, None).unwrap())
                    .await
                    .unwrap_err()
            ),
            history
                .read_thread_header(id.into())
                .await
                .unwrap_err()
                .to_string(),
            history
                .session_path(id.into())
                .await
                .unwrap_err()
                .to_string(),
            format!(
                "{:?}",
                history
                    .read_projection(&format!("claude_{id}"), None, |_, _, _| Ok(()))
                    .await
                    .unwrap_err()
            ),
        ];
        for error in errors {
            assert!(error.contains("duplicate Claude session UUID"), "{error}");
        }
        fs::remove_file(other.join(format!("{id}.jsonl"))).unwrap();
        assert_eq!(
            history.session_path(id.into()).await.unwrap(),
            original.canonicalize().unwrap()
        );
        assert_eq!(
            history
                .list_threads(ThreadListQuery::new(10, None, None).unwrap())
                .await
                .unwrap()["data"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }

    #[tokio::test]
    async fn bounds_review_hard_link_session_aliases_remain_one_readable_conversation_after_cache_priming()
     {
        let home = tempfile::tempdir().unwrap();
        let id = "11111111-2222-4333-8444-555555555555";
        let original = session(home.path(), id, &[message("user", "2026-09-20T10:00:00Z")]);
        let history =
            ClaudeHistory::new(home.path().into(), Arc::new(ProjectionCache::new(32 << 20)));
        let mut expected = history.read_thread_header(id.into()).await.unwrap();
        let other = home.path().join("projects/alias");
        fs::create_dir_all(&other).unwrap();
        fs::hard_link(&original, other.join(format!("{id}.jsonl"))).unwrap();
        let mut aliased = history.read_thread_header(id.into()).await.unwrap();
        aliased.as_object_mut().unwrap().remove("path");
        expected.as_object_mut().unwrap().remove("path");
        assert_eq!(aliased, expected);
        let page = history
            .list_threads(ThreadListQuery::new(10, None, None).unwrap())
            .await
            .unwrap();
        assert_eq!(page["data"].as_array().unwrap().len(), 1);
        assert_eq!(page["data"][0]["id"], format!("claude_{id}"));
        assert_eq!(page["data"][0]["preview"], "hello");
        let selected = history.session_path(id.into()).await.unwrap();
        let original_metadata = original.metadata().unwrap();
        let selected_metadata = selected.metadata().unwrap();
        use std::os::unix::fs::MetadataExt;
        assert_eq!(
            (selected_metadata.dev(), selected_metadata.ino()),
            (original_metadata.dev(), original_metadata.ino())
        );
        history
            .read_projection(&format!("claude_{id}"), None, |_, _, _| Ok(()))
            .await
            .unwrap();
    }

    #[test]
    fn bounds_review_repeated_full_scans_rebuild_only_uncached_headers_above_entry_and_byte_budgets()
     {
        let home = tempfile::tempdir().unwrap();
        for index in 0..MAX_HEADER_CACHE_ENTRIES + 1 {
            session(
                home.path(),
                &format!("session-{index}"),
                &[message("user", "2026-09-20T10:00:00Z")],
            );
        }
        let mut index = HistoryIndex::default();
        assert_eq!(
            index.list_threads(home.path(), usize::MAX).unwrap().len(),
            MAX_HEADER_CACHE_ENTRIES + 1
        );
        for _ in 0..2 {
            let before = index.header_scans;
            assert_eq!(
                index.list_threads(home.path(), usize::MAX).unwrap().len(),
                MAX_HEADER_CACHE_ENTRIES + 1
            );
            assert_eq!(index.header_scans - before, 1);
        }
        let home = tempfile::tempdir().unwrap();
        for id in ["first", "second", "third"] {
            session(
                home.path(),
                id,
                &[
                    message("user", "2026-09-20T10:00:00Z"),
                    json!({"type":"custom-title", "customTitle":"x".repeat(MAX_HEADER_CACHE_BYTES / 8)}),
                ],
            );
        }
        let mut index = HistoryIndex::default();
        assert_eq!(index.list_threads(home.path(), 10).unwrap().len(), 3);
        for _ in 0..2 {
            let before = index.header_scans;
            assert_eq!(index.list_threads(home.path(), 10).unwrap().len(), 3);
            assert_eq!(index.header_scans - before, 2);
            assert!(index.cache_bytes <= MAX_HEADER_CACHE_BYTES);
        }
    }

    #[tokio::test]
    async fn pasted_prompt_headers_are_summarized_before_truncation() {
        let cases: Vec<Value> = serde_json::from_str(include_str!(
            "../../../../protocol-fixtures/attachments/pasted-text-v1-cases.json"
        ))
        .unwrap();
        let inline: Vec<Value> = serde_json::from_str(include_str!(
            "../../../../protocol-fixtures/attachments/pasted-text-v2-cases.json"
        ))
        .unwrap();
        for case in cases.into_iter().chain(inline) {
            assert_eq!(
                crate::prompt_summary::prompt_summary(case["prompt"].as_str().unwrap()),
                case["summary"].as_str().unwrap(),
                "{}",
                case["name"]
            );
            let home = tempfile::tempdir().unwrap();
            let mut record = message("user", "2026-09-20T10:00:00Z");
            record["message"]["content"] = case["prompt"].clone();
            let expected: String = case["summary"]
                .as_str()
                .unwrap()
                .chars()
                .take(200)
                .collect();
            session(home.path(), "pasted-summary", &[record]);
            let index = Arc::new(reads::Headers::default());
            if expected.is_empty() {
                assert!(
                    index
                        .read(home.path().to_path_buf(), "pasted-summary".into())
                        .await
                        .is_err()
                );
                assert!(
                    index
                        .list(home.path().to_path_buf())
                        .await
                        .unwrap()
                        .as_slice()
                        .is_empty()
                );
                continue;
            }
            let header = index
                .read(home.path().to_path_buf(), "pasted-summary".into())
                .await
                .unwrap();
            assert_eq!(header["preview"], expected, "{}", case["name"]);
            assert_eq!(
                index
                    .list(home.path().to_path_buf())
                    .await
                    .unwrap()
                    .as_slice()[0]["preview"],
                expected,
                "{}",
                case["name"]
            );
        }
    }

    #[tokio::test]
    async fn completion_time_changes_only_at_a_root_turn_end() {
        let home = tempfile::tempdir().unwrap();
        let index = Arc::new(reads::Headers::default());
        let mut records = vec![message("user", "2026-09-20T10:00:00Z")];
        let path = session(home.path(), "recency", &records);
        assert!(
            index
                .read(home.path().to_path_buf(), "recency".into())
                .await
                .unwrap()["lastTurnCompletedAt"]
                .is_null()
        );

        let mut complete = message("assistant", "2026-09-20T10:01:00Z");
        complete["message"]["stop_reason"] = json!("end_turn");
        records.push(complete.clone());
        records.push(
            json!({"type":"system","subtype":"turn_duration","timestamp":"2026-09-20T10:01:01Z"}),
        );
        records.push(message("user", "2026-09-20T10:02:00Z"));
        let mut tool = message("assistant", "2026-09-20T10:03:00Z");
        tool["message"]["stop_reason"] = json!("tool_use");
        records.push(tool);
        records.push(json!({"type":"user","timestamp":"2026-09-20T10:04:00Z",
            "message":{"content":[{"type":"tool_result","tool_use_id":"tool","content":"done"}]}}));
        for flag in ["isSidechain", "parentToolUseID", "parent_tool_use_id"] {
            let mut child = complete.clone();
            child["timestamp"] = json!("2026-09-20T10:05:00Z");
            child[flag] = if flag == "isSidechain" {
                json!(true)
            } else {
                json!("child")
            };
            records.push(child);
        }
        records.push(json!({"type":"custom-title","customTitle":"Renamed","timestamp":"2026-09-20T10:06:00Z"}));
        session(home.path(), "recency", &records);
        let during = index
            .read(home.path().to_path_buf(), "recency".into())
            .await
            .unwrap();
        assert_eq!(
            during["lastTurnCompletedAt"],
            parse_rfc3339_seconds("2026-09-20T10:01:00Z").unwrap()
        );
        assert_eq!(
            during["updatedAt"],
            parse_rfc3339_seconds("2026-09-20T10:04:00Z").unwrap()
        );

        complete["timestamp"] = json!("2026-09-20T10:07:00Z");
        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        writeln!(file, "{complete}").unwrap();
        let after = index
            .read(home.path().to_path_buf(), "recency".into())
            .await
            .unwrap();
        assert_eq!(
            after["lastTurnCompletedAt"],
            parse_rfc3339_seconds("2026-09-20T10:07:00Z").unwrap()
        );
        assert_eq!(
            Arc::new(reads::Headers::default())
                .read(home.path().to_path_buf(), "recency".into())
                .await
                .unwrap(),
            after
        );

        // A rewrite must remove a completion that is no longer in the source.
        session(
            home.path(),
            "recency",
            &[message("user", "2026-09-20T10:00:00Z")],
        );
        assert!(
            index
                .read(home.path().to_path_buf(), "recency".into())
                .await
                .unwrap()["lastTurnCompletedAt"]
                .is_null()
        );
    }

    #[tokio::test]
    async fn recency_follows_the_last_real_prompt_only() {
        let home = tempfile::tempdir().unwrap();
        let index = Arc::new(reads::Headers::default());
        let mut reply = message("assistant", "2026-09-20T10:05:00Z");
        reply["message"]["stop_reason"] = json!("end_turn");
        session(
            home.path(),
            "prompts",
            &[
                message("user", "2026-09-20T10:00:00Z"),
                message("user", "2026-09-20T10:03:00Z"),
                json!({"type":"user","timestamp":"2026-09-20T10:04:00Z",
                    "message":{"content":[{"type":"tool_result","tool_use_id":"tool","content":"done"}]}}),
                json!({"type":"user","isMeta":true,"timestamp":"2026-09-20T10:04:30Z",
                    "message":{"content":"meta"}}),
                reply,
            ],
        );
        let header = index
            .read(home.path().to_path_buf(), "prompts".into())
            .await
            .unwrap();
        assert_eq!(
            header["recencyAt"],
            parse_rfc3339_seconds("2026-09-20T10:03:00Z").unwrap()
        );
    }

    #[tokio::test]
    async fn interrupted_and_legacy_turns_have_explicit_end_evidence() {
        let home = tempfile::tempdir().unwrap();
        for (id, terminal) in [
            (
                "abort",
                json!({"type":"user","timestamp":"2026-09-20T10:01:00Z",
                "message":{"content":"[Request interrupted by user]"}}),
            ),
            (
                "duration",
                json!({"type":"system","subtype":"turn_duration","timestamp":"2026-09-20T10:01:00Z"}),
            ),
        ] {
            session(
                home.path(),
                id,
                &[message("user", "2026-09-20T10:00:00Z"), terminal],
            );
            let header = Arc::new(reads::Headers::default())
                .read(home.path().to_path_buf(), id.into())
                .await
                .unwrap();
            assert_eq!(
                header["lastTurnCompletedAt"],
                parse_rfc3339_seconds("2026-09-20T10:01:00Z").unwrap()
            );
        }
        for reason in ["end_turn", "stop_sequence", "max_tokens", "refusal"] {
            let mut terminal = message("assistant", "2026-09-20T10:01:00Z");
            terminal["message"]["stop_reason"] = json!(reason);
            session(
                home.path(),
                reason,
                &[message("user", "2026-09-20T10:00:00Z"), terminal],
            );
            assert_eq!(
                Arc::new(reads::Headers::default())
                    .read(home.path().to_path_buf(), reason.into())
                    .await
                    .unwrap()["lastTurnCompletedAt"],
                parse_rfc3339_seconds("2026-09-20T10:01:00Z").unwrap()
            );
        }
    }

    #[tokio::test]
    async fn synthetic_records_are_not_conversation_activity() {
        let home = tempfile::tempdir().unwrap();
        let mut synthetic_reply = message("assistant", "2026-09-13T12:00:00Z");
        synthetic_reply["message"]["model"] = json!("<synthetic>");
        synthetic_reply["message"]["stop_reason"] = json!("end_turn");
        let mut synthetic_input = message("user", "2026-09-13T13:00:00Z");
        synthetic_input["isSynthetic"] = json!(true);
        session(
            home.path(),
            "synthetic",
            &[
                message("user", "2026-09-13T10:00:00Z"),
                synthetic_reply,
                synthetic_input,
            ],
        );

        let header = Arc::new(reads::Headers::default())
            .read(home.path().to_path_buf(), "synthetic".into())
            .await
            .unwrap();

        assert_eq!(
            header["updatedAt"],
            parse_rfc3339_seconds("2026-09-13T10:00:00Z").unwrap()
        );
        assert!(header["lastTurnCompletedAt"].is_null());
    }

    #[tokio::test]
    async fn header_reports_latest_real_model_and_effort_without_using_a_default() {
        let home = tempfile::tempdir().unwrap();
        let mut first = message("assistant", "2026-09-13T10:00:00Z");
        first["message"]["model"] = json!("claude-sonnet-5");
        first["effort"] = json!("low");
        let mut latest = message("assistant", "2026-09-13T11:00:00Z");
        latest["message"]["model"] = json!("claude-opus-5");
        latest["effort"] = json!("xhigh");
        let mut child = latest.clone();
        child["isSidechain"] = json!(true);
        child["message"]["model"] = json!("claude-fable-5");
        let mut synthetic = message("assistant", "2026-09-13T12:00:00Z");
        synthetic["message"]["model"] = json!("<synthetic>");
        session(
            home.path(),
            "models",
            &[first.clone(), latest, child, synthetic, first],
        );
        let header = Arc::new(reads::Headers::default())
            .read(home.path().to_path_buf(), "models".into())
            .await
            .unwrap();
        assert_eq!(header["model"], "claude-opus-5");
        assert_eq!(header["reasoningEffort"], "xhigh");

        session(
            home.path(),
            "unknown",
            &[message("user", "2026-09-13T10:00:00Z")],
        );
        let header = Arc::new(reads::Headers::default())
            .read(home.path().to_path_buf(), "unknown".into())
            .await
            .unwrap();
        assert!(header["model"].is_null());
        assert!(header["reasoningEffort"].is_null());
    }

    #[test]
    fn activity_order_is_computed_before_limiting_and_ties_are_stable() {
        let home = tempfile::tempdir().unwrap();
        let mut index = HistoryIndex::default();
        let newer = session(home.path(), "a", &[message("user", "2026-09-05T10:00:00Z")]);
        File::open(newer)
            .unwrap()
            .set_modified(std::time::UNIX_EPOCH)
            .unwrap();
        session(
            home.path(),
            "z",
            &[message("assistant", "2026-09-05T10:00:00Z")],
        );
        session(
            home.path(),
            "old",
            &[message("user", "2026-09-04T10:00:00Z")],
        );
        session(
            home.path(),
            "metadata-only",
            &[json!({"type":"ai-title","cwd":"/repo","aiTitle":"noise"})],
        );
        let threads = index.list_threads(home.path(), 2).unwrap();
        assert_eq!(
            threads
                .iter()
                .map(|t| t["id"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["claude_a", "claude_z"]
        );
        assert_eq!(
            index.list_threads(home.path(), 1).unwrap()[0]["id"],
            "claude_a"
        );
    }

    #[tokio::test]
    async fn all_records_are_considered_but_metadata_and_injections_are_not_activity() {
        let home = tempfile::tempdir().unwrap();
        let mut records = vec![message("user", "2026-09-04T10:00:00Z")];
        records.extend(
            (0..100).map(|_| json!({"type":"attachment", "timestamp":"2026-09-06T10:00:00Z"})),
        );
        records.push(message("assistant", "2026-09-05T10:00:00Z"));
        records.push(message("user", "2026-09-04T11:00:00Z")); // Replayed older record.
        for flag in ["isSidechain", "isMeta", "isCompactSummary"] {
            let mut record = message("user", "2026-09-06T10:00:00Z");
            record[flag] = json!(true);
            records.push(record);
        }
        for text in [
            "<task-notification>finished",
            "[Request interrupted by user]",
        ] {
            let mut record = message("user", "2026-09-06T10:00:00Z");
            record["message"]["content"] = json!(text);
            records.push(record);
        }
        records.push(json!({"type":"custom-title", "customTitle":"Renamed"}));
        records.push(json!({"type":"ai-title", "aiTitle":"Generated later"}));
        session(home.path(), "activity", &records);
        let index = Arc::new(reads::Headers::default());
        let header = index
            .read(home.path().to_path_buf(), "activity".into())
            .await
            .unwrap();
        assert_eq!(
            header["updatedAt"],
            parse_rfc3339_seconds("2026-09-05T10:00:00Z").unwrap()
        );
        assert_eq!(
            header["createdAt"],
            parse_rfc3339_seconds("2026-09-04T10:00:00Z").unwrap()
        );
        assert_eq!(header["name"], "Renamed");
        assert_eq!(header["preview"], "Generated later");
        assert_eq!(header["id"], "claude_activity");
        assert_eq!(header["cwd"], "/repo");
        assert_eq!(header["cliVersion"], "test");
        assert_eq!(header["modelProvider"], "claude");
        assert_eq!(header["source"], "appServer");
        assert_eq!(
            index
                .list(home.path().to_path_buf())
                .await
                .unwrap()
                .as_slice(),
            [header]
        );
    }

    #[tokio::test]
    async fn cache_tracks_complete_appends_and_ignores_shutdown_metadata() {
        let home = tempfile::tempdir().unwrap();
        let path = session(
            home.path(),
            "append",
            &[message("user", "2026-09-04T10:00:00Z")],
        );
        let index = Arc::new(reads::Headers::default());
        let original = index
            .read(home.path().to_path_buf(), "append".into())
            .await
            .unwrap();
        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        writeln!(
            file,
            "{}",
            json!({"type":"last-prompt", "lastPrompt":"hello"})
        )
        .unwrap();
        assert_eq!(
            index
                .read(home.path().to_path_buf(), "append".into())
                .await
                .unwrap(),
            original
        );
        let next = message("assistant", "2026-09-05T10:00:00Z").to_string();
        let split = next.len() / 2;
        write!(file, "{}", &next[..split]).unwrap();
        assert_eq!(
            index
                .read(home.path().to_path_buf(), "append".into())
                .await
                .unwrap(),
            original
        );
        writeln!(file, "{}", &next[split..]).unwrap();
        let updated = index
            .read(home.path().to_path_buf(), "append".into())
            .await
            .unwrap();
        assert!(updated["updatedAt"].as_i64() > original["updatedAt"].as_i64());
        assert_eq!(
            index
                .read(home.path().to_path_buf(), "append".into())
                .await
                .unwrap(),
            updated
        );
    }

    #[tokio::test]
    async fn cache_rebuilds_after_rewrite_replacement_truncation_and_deletion() {
        let home = tempfile::tempdir().unwrap();
        let path = session(
            home.path(),
            "mutable",
            &[message("user", "2026-09-05T10:00:00Z")],
        );
        let index = Arc::new(reads::Headers::default());
        let original = index
            .read(home.path().to_path_buf(), "mutable".into())
            .await
            .unwrap();
        let modified = path.metadata().unwrap().modified().unwrap();
        session(
            home.path(),
            "mutable",
            &[message("user", "2026-09-04T10:00:00Z")],
        );
        File::open(&path).unwrap().set_modified(modified).unwrap();
        let corrected = index
            .read(home.path().to_path_buf(), "mutable".into())
            .await
            .unwrap();
        assert!(corrected["updatedAt"].as_i64() < original["updatedAt"].as_i64());
        let replacement = session(
            home.path(),
            "replacement",
            &[message("user", "2026-09-03T10:00:00Z")],
        );
        fs::rename(replacement, &path).unwrap();
        assert!(
            index
                .read(home.path().to_path_buf(), "mutable".into())
                .await
                .unwrap()["updatedAt"]
                .as_i64()
                < corrected["updatedAt"].as_i64()
        );
        fs::write(&path, "").unwrap();
        assert!(
            index
                .list(home.path().to_path_buf())
                .await
                .unwrap()
                .as_slice()
                .is_empty()
        );
        fs::remove_file(path).unwrap();
        assert!(
            index
                .list(home.path().to_path_buf())
                .await
                .unwrap()
                .as_slice()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn missing_activity_dates_never_fall_back_to_file_dates() {
        let home = tempfile::tempdir().unwrap();
        let mut record = message("user", "invalid");
        session(home.path(), "invalid", &[record.clone()]);
        record.as_object_mut().unwrap().remove("timestamp");
        session(home.path(), "missing", &[record]);
        let index = Arc::new(reads::Headers::default());
        assert!(
            index
                .list(home.path().to_path_buf())
                .await
                .unwrap()
                .as_slice()
                .is_empty()
        );
        assert!(
            index
                .read(home.path().to_path_buf(), "missing".into())
                .await
                .is_err()
        );
    }
}
