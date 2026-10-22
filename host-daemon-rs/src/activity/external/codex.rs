use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::Value;
use tokio::process::Command;
use tokio::sync::Mutex;

use super::transcript::{Boundary, TranscriptCache};
use super::{
    ActivityState, SessionActivity, SessionOwner, bounded_output, ensure_inventory_within_limit,
    valid_id,
};
use crate::time::parse_rfc3339_seconds;

pub(super) async fn codex_sessions(
    home: PathBuf,
    managed_pid: Option<i32>,
    cache: Arc<Mutex<TranscriptCache>>,
) -> Result<Vec<SessionActivity>> {
    let managed_pid = managed_pid.context("managed Codex identity unavailable")?;
    let mut command = Command::new("/usr/sbin/lsof");
    command.args([
        "-nP",
        "-a",
        "-u",
        &nix::unistd::getuid().as_raw().to_string(),
        "-c",
        "codex",
        "-Fpcfatn",
    ]);
    let files = codex_writers(
        std::str::from_utf8(&inventory_output(command).await?)?,
        &home,
        managed_pid,
    );
    ensure_inventory_within_limit(files.values().map(Vec::len).sum())?;
    let mut cache = cache.lock_owned().await;
    if files.is_empty() {
        cache.clear();
        return Ok(Vec::new());
    }
    tokio::task::spawn_blocking(move || {
        let mut starts = HashMap::new();
        for pid in files.keys() {
            if let Some(identity) = crate::platform::process::identify(*pid)? {
                starts.insert(*pid, i64::try_from(identity.started_micros / 1_000_000)?);
            }
        }
        cache.seen.clear();
        let mut sessions = Vec::new();
        for (pid, paths) in files {
            let Some(start) = starts.get(&pid) else {
                continue;
            };
            for path in paths {
                let mut first = String::new();
                BufReader::new(File::open(&path)?.take(128 * 1024)).read_line(&mut first)?;
                let header: Value = serde_json::from_str(&first)?;
                let Some(id) = header["payload"]["id"].as_str().filter(|id| valid_id(id)) else {
                    continue;
                };
                let state = cache
                    .boundary(&path, boundary)
                    .ok()
                    .flatten()
                    .and_then(|boundary| boundary.state_since(*start))
                    .unwrap_or(ActivityState::Unknown);
                sessions.push(SessionActivity {
                    thread_id: id.to_string(),
                    state,
                    owner: Some(SessionOwner::Client { pid }),
                    waiting_since: None,
                });
            }
        }
        cache.finish();
        Ok(sessions)
    })
    .await
    .context("Codex activity reader failed")?
}

async fn inventory_output(command: Command) -> Result<Vec<u8>> {
    let output = bounded_output(command).await?;
    anyhow::ensure!(
        output.status.success() || (output.status.code() == Some(1) && output.stdout.is_empty()),
        "Codex activity command failed: {}",
        output.status
    );
    Ok(output.stdout)
}

pub(super) fn codex_writers(
    text: &str,
    home: &Path,
    managed_pid: i32,
) -> HashMap<i32, Vec<PathBuf>> {
    let mut files: HashMap<i32, Vec<PathBuf>> = HashMap::new();
    let (mut pid, mut codex, mut writable, mut regular) = (0, false, false, false);
    for line in text.lines().filter(|line| !line.is_empty()) {
        let value = &line[1..];
        match &line[..1] {
            "p" => {
                pid = value.parse().unwrap_or(0);
                codex = false;
            }
            "c" => codex = value == "codex",
            "f" => {
                writable = false;
                regular = false;
            }
            "a" => writable = value == "w" || value == "u",
            "t" => regular = value == "REG",
            "n" if pid > 0 && pid != managed_pid && codex && writable && regular => {
                let path = PathBuf::from(value);
                if path.starts_with(home.join("sessions"))
                    && path.extension().is_some_and(|v| v == "jsonl")
                {
                    files.entry(pid).or_default().push(path);
                }
            }
            _ => {}
        }
    }
    files
}

#[derive(Deserialize)]
struct Record {
    #[serde(rename = "type")]
    kind: String,
    timestamp: Option<String>,
    payload: Payload,
}

#[derive(Deserialize)]
struct Payload {
    #[serde(rename = "type")]
    kind: Option<String>,
}

pub(super) fn boundary(line: &[u8]) -> Result<Option<Boundary>> {
    let record: Record = serde_json::from_slice(line)?;
    if record.kind != "event_msg" {
        return Ok(None);
    }
    let state = match record.payload.kind.as_deref() {
        Some("task_complete" | "turn_aborted") => ActivityState::Idle,
        Some("task_started") => ActivityState::Working,
        _ => return Ok(None),
    };
    Ok(Some(Boundary {
        state,
        timestamp: record.timestamp.as_deref().and_then(parse_rfc3339_seconds),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shell(script: &str) -> Command {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", script]);
        command
    }

    #[tokio::test]
    async fn codex_inventory_accepts_no_matches_but_rejects_incomplete_results() {
        assert!(inventory_output(shell("exit 1")).await.unwrap().is_empty());
        assert!(super::super::output(shell("exit 1")).await.is_err());
        for script in [
            "printf partial; exit 1",
            "echo skipped >&2; exit 1",
            "exit 2",
        ] {
            assert!(inventory_output(shell(script)).await.is_err(), "{script}");
        }
    }
}
