mod claude;
mod codex;
mod stop;
#[cfg(test)]
mod tests;
mod transcript {
    use std::collections::{HashMap, HashSet};
    use std::fs::File;
    use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
    use std::path::{Path, PathBuf};

    use anyhow::Result;

    use super::ActivityState;
    use crate::storage::file_revision::FileRevision;

    #[derive(Clone, Copy)]
    pub(super) struct Boundary {
        pub state: ActivityState,
        pub timestamp: Option<i64>,
    }

    impl Boundary {
        pub(crate) fn state_since(self, owner_started: i64) -> Option<ActivityState> {
            match self.timestamp {
                None => Some(ActivityState::Unknown),
                Some(at) if at < owner_started && self.state != ActivityState::Idle => None,
                Some(_) => Some(self.state),
            }
        }
    }

    #[derive(Default)]
    pub(super) struct TranscriptCache {
        entries: HashMap<PathBuf, CachedTranscript>,
        pub seen: HashSet<PathBuf>,
    }

    struct CachedTranscript {
        revision: FileRevision,
        boundary: Option<Boundary>,
    }

    impl TranscriptCache {
        pub(crate) fn boundary(
            &mut self,
            path: &Path,
            project: impl Fn(&[u8]) -> Result<Option<Boundary>>,
        ) -> Result<Option<Boundary>> {
            self.seen.insert(path.to_path_buf());
            let revision = FileRevision::from(std::fs::metadata(path)?);
            if let Some(cached) = self.entries.get(path)
                && cached.revision == revision
            {
                return Ok(cached.boundary);
            }
            self.entries.remove(path);
            let boundary = tail_boundary(path, project)?;
            anyhow::ensure!(
                FileRevision::from(std::fs::metadata(path)?) == revision,
                "session changed during activity read"
            );
            self.entries
                .insert(path.to_path_buf(), CachedTranscript { revision, boundary });
            Ok(boundary)
        }

        pub(crate) fn clear(&mut self) {
            self.entries.clear();
            self.seen.clear();
        }

        pub(crate) fn finish(&mut self) {
            self.entries.retain(|path, _| self.seen.contains(path));
        }
    }

    // A bounded complete-record tail: large attachments and torn final writes must
    // not turn a partial parse into an authoritative idle/working answer.
    pub(super) fn tail_boundary(
        path: &Path,
        project: impl Fn(&[u8]) -> Result<Option<Boundary>>,
    ) -> Result<Option<Boundary>> {
        const LIMIT: u64 = 8 * 1024 * 1024;
        let mut file = File::open(path)?;
        let length = file.metadata()?.len();
        let offset = length.saturating_sub(LIMIT);
        file.seek(SeekFrom::Start(offset))?;
        let mut reader = BufReader::new(file.take(length - offset));
        let mut line = Vec::new();
        if offset > 0 {
            reader.read_until(b'\n', &mut line)?;
        }
        let mut latest = None;
        loop {
            line.clear();
            if reader.read_until(b'\n', &mut line)? == 0 {
                break;
            }
            anyhow::ensure!(line.last() == Some(&b'\n'), "session tail is being written");
            if !line.iter().all(u8::is_ascii_whitespace)
                && let Some(boundary) = project(&line)?
            {
                latest = Some(boundary);
            }
        }
        Ok(latest)
    }
}

use std::collections::HashSet;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use serde::Serialize;
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::Command;
use tokio::sync::Mutex;

use crate::providers::claude::settings::ClaudeSettings;
use claude::{ClaudeInventory, claude_sessions};
use codex::codex_sessions;
pub(crate) use stop::stop_client;
use transcript::TranscriptCache;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ActivityState {
    Working,
    Waiting,
    Idle,
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SessionOwner {
    Gateway,
    Client { pid: i32 },
}

impl Serialize for SessionOwner {
    fn serialize<S: serde::Serializer>(
        &self,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        serializer.serialize_str(match self {
            Self::Gateway => "gateway",
            Self::Client { .. } => "client",
        })
    }
}

#[derive(Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SessionActivity {
    pub thread_id: String,
    pub state: ActivityState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner: Option<SessionOwner>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub waiting_since: Option<i64>,
}

#[derive(Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Snapshot {
    pub sessions: Vec<SessionActivity>,
    pub claude_available: bool,
    pub codex_available: bool,
}

impl Snapshot {
    pub(crate) fn attribute_to_gateway(&mut self, gateway_processes: &HashSet<i32>) {
        for session in &mut self.sessions {
            if let Some(SessionOwner::Client { pid }) = session.owner
                && gateway_processes.contains(&pid)
            {
                session.owner = Some(SessionOwner::Gateway);
            }
        }
    }

    pub(crate) fn client_owners(&self, thread_id: &str) -> Result<Vec<i32>> {
        let available = if crate::providers::claude::is_claude_thread_id(thread_id) {
            self.claude_available
        } else {
            self.codex_available
        };
        anyhow::ensure!(
            available,
            "Could not verify whether this conversation is open in another client"
        );
        Ok(self
            .sessions
            .iter()
            .filter(|session| session.thread_id == thread_id)
            .filter_map(|session| match session.owner {
                Some(SessionOwner::Client { pid }) => Some(pid),
                _ => None,
            })
            .collect())
    }
}

#[derive(Default)]
pub(crate) struct ExternalActivity {
    cache: Mutex<Option<(Instant, Snapshot)>>,
    claude_inventory: Arc<Mutex<ClaudeInventory>>,
    claude_transcripts: Arc<Mutex<TranscriptCache>>,
    codex_transcripts: Arc<Mutex<TranscriptCache>>,
}

impl ExternalActivity {
    pub(crate) async fn snapshot(
        &self,
        settings: &ClaudeSettings,
        codex_home: PathBuf,
        managed_pid: Option<i32>,
    ) -> Snapshot {
        self.read(settings, codex_home, managed_pid).await
    }

    pub(crate) async fn invalidate(&self) {
        *self.cache.lock().await = None;
    }

    async fn read(
        &self,
        settings: &ClaudeSettings,
        codex_home: PathBuf,
        managed_pid: Option<i32>,
    ) -> Snapshot {
        let mut cache = self.cache.lock().await;
        if let Some((at, snapshot)) = cache.as_ref()
            && at.elapsed() < Duration::from_secs(1)
        {
            return snapshot.clone();
        }
        let (claude, codex) = tokio::join!(
            claude_sessions(
                settings,
                Arc::clone(&self.claude_transcripts),
                Arc::clone(&self.claude_inventory),
            ),
            codex_sessions(codex_home, managed_pid, Arc::clone(&self.codex_transcripts))
        );
        let mut snapshot = Snapshot {
            claude_available: claude.is_ok(),
            codex_available: codex.is_ok(),
            ..Snapshot::default()
        };
        for (provider, result) in [("claude", claude), ("codex", codex)] {
            match result {
                Ok(sessions) => snapshot.sessions.extend(sessions),
                Err(error) => {
                    tracing::warn!(provider, %error, "external activity inventory unavailable")
                }
            }
        }
        snapshot
            .sessions
            .sort_by(|left, right| left.thread_id.cmp(&right.thread_id));
        *cache = Some((Instant::now(), snapshot.clone()));
        snapshot
    }
}

const MAXIMUM_STDOUT_BYTES: usize = 16 * 1024 * 1024;
const MAXIMUM_STDERR_BYTES: usize = 4 * 1024;
const MAXIMUM_INVENTORY_SESSIONS: usize = 512;

async fn output(command: Command) -> Result<Vec<u8>> {
    let output = bounded_output(command).await?;
    anyhow::ensure!(
        output.status.success(),
        "activity command failed: {}",
        output.status
    );
    Ok(output.stdout)
}

async fn bounded_output(mut command: Command) -> Result<std::process::Output> {
    command
        .kill_on_drop(true)
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command
        .spawn()
        .context("activity command failed to start")?;
    let group = child
        .id()
        .and_then(|pid| i32::try_from(pid).ok())
        .map(nix::unistd::Pid::from_raw)
        .context("activity command has no process id")?;
    let stdout = child
        .stdout
        .take()
        .context("activity command has no stdout")?;
    let stderr = child
        .stderr
        .take()
        .context("activity command has no stderr")?;
    let collected = tokio::time::timeout(Duration::from_secs(3), async {
        tokio::try_join!(
            read_bounded(stdout, MAXIMUM_STDOUT_BYTES, "inventory"),
            read_bounded(stderr, MAXIMUM_STDERR_BYTES, "diagnostics"),
            async { child.wait().await.map_err(anyhow::Error::from) },
        )
    })
    .await
    .context("activity command timed out")
    .and_then(|collected| collected);
    let (stdout, stderr, status) = collected.inspect_err(|_| {
        let _ = nix::sys::signal::killpg(group, nix::sys::signal::Signal::SIGKILL);
    })?;
    anyhow::ensure!(
        stderr.is_empty(),
        "activity command reported incomplete coverage"
    );
    Ok(std::process::Output {
        status,
        stdout,
        stderr,
    })
}

async fn read_bounded(stream: impl AsyncRead + Unpin, limit: usize, what: &str) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    stream
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .await?;
    anyhow::ensure!(bytes.len() <= limit, "activity {what} exceeds size limit");
    Ok(bytes)
}

fn ensure_inventory_within_limit(sessions: usize) -> Result<()> {
    anyhow::ensure!(
        sessions <= MAXIMUM_INVENTORY_SESSIONS,
        "activity inventory lists {sessions} sessions, above the {MAXIMUM_INVENTORY_SESSIONS} limit"
    );
    Ok(())
}

fn valid_id(id: &str) -> bool {
    id.len() == 36 && id.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
}
