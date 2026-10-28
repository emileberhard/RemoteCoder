use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use nix::errno::Errno;
use serde::Deserialize;
use serde_json::value::RawValue;
use tokio::sync::Mutex;

use super::transcript::{Boundary, TranscriptCache};
use super::{
    ActivityState, SessionActivity, SessionOwner, ensure_inventory_within_limit, output, valid_id,
};
use crate::providers::claude::settings::ClaudeSettings;
use crate::providers::claude::timeline::{
    is_abort_marker, is_injected_user_text, is_turn_end_stop_reason,
};
use crate::storage::file_revision::FileRevision;
use crate::time::parse_rfc3339_seconds;

const MAX_LISTING_AGE: Duration = Duration::from_secs(30);
#[cfg(target_os = "macos")]
const KEYCHAIN_STATUS_LIMIT: Duration = Duration::from_secs(2);

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeSession {
    session_id: Option<String>,
    cwd: PathBuf,
    started_at: u64,
    pid: Option<u32>,
    status: Option<String>,
    state: Option<String>,
}

#[derive(Default)]
pub(super) struct ClaudeInventory {
    listing: Option<Listing>,
    #[cfg(target_os = "macos")]
    keychain_check: Option<tokio::task::JoinHandle<Result<bool>>>,
}

struct Listing {
    sessions: Vec<ClaudeSession>,
    registry: Vec<(OsString, FileRevision)>,
    listed_at: Instant,
}

impl ClaudeInventory {
    fn current(&self, registry: Option<&[(OsString, FileRevision)]>) -> Option<&[ClaudeSession]> {
        let listing = self.listing.as_ref()?;
        let current = listing.listed_at.elapsed() < MAX_LISTING_AGE
            && registry == Some(listing.registry.as_slice())
            && listing
                .sessions
                .iter()
                .filter_map(|session| session.pid)
                .all(process_exists);
        current.then_some(listing.sessions.as_slice())
    }

    #[cfg(target_os = "macos")]
    async fn ensure_keychain_unlocked(&mut self) -> Result<()> {
        let mut check = self.keychain_check.take().unwrap_or_else(|| {
            tokio::task::spawn_blocking(crate::platform::macos::keychain::lookup_would_prompt)
        });
        let Ok(joined) = tokio::time::timeout(KEYCHAIN_STATUS_LIMIT, &mut check).await else {
            self.keychain_check = Some(check);
            anyhow::bail!("the login keychain status did not respond");
        };
        anyhow::ensure!(
            !joined.context("keychain status check failed")??,
            "the login keychain is locked; listing Claude sessions would raise a keychain prompt"
        );
        Ok(())
    }
}

fn registry_revisions(dir: &Path) -> Option<Vec<(OsString, FileRevision)>> {
    let mut revisions = std::fs::read_dir(dir)
        .ok()?
        .map(|entry| {
            let entry = entry.ok()?;
            Some((
                entry.file_name(),
                FileRevision::from(entry.metadata().ok()?),
            ))
        })
        .collect::<Option<Vec<_>>>()?;
    revisions.sort_by(|left, right| left.0.cmp(&right.0));
    Some(revisions)
}

fn process_exists(pid: u32) -> bool {
    let Ok(pid) = i32::try_from(pid) else {
        return false;
    };
    nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None) != Err(Errno::ESRCH)
}

pub(super) async fn claude_sessions(
    settings: &ClaudeSettings,
    cache: Arc<Mutex<TranscriptCache>>,
    inventory: Arc<Mutex<ClaudeInventory>>,
) -> Result<Vec<SessionActivity>> {
    if !settings.enabled {
        return Ok(Vec::new());
    }
    let mut inventory = inventory.lock_owned().await;
    let registry_dir = settings.claude_home.join("sessions");
    let registry = tokio::task::spawn_blocking(move || registry_revisions(&registry_dir))
        .await
        .context("Claude session registry reader failed")?;
    let sessions = if let Some(sessions) = inventory
        .current(registry.as_deref())
        .map(<[ClaudeSession]>::to_vec)
    {
        sessions
    } else {
        #[cfg(target_os = "macos")]
        inventory.ensure_keychain_unlocked().await?;
        let command =
            crate::providers::claude::exec::command(settings, &["agents".into(), "--json".into()])?;
        let sessions: Vec<ClaudeSession> =
            serde_json::from_slice(&output(command.into_inner()).await?)
                .context("invalid claude agents JSON")?;
        ensure_inventory_within_limit(sessions.len())?;
        inventory.listing = registry.map(|registry| Listing {
            sessions: sessions.clone(),
            registry,
            listed_at: Instant::now(),
        });
        sessions
    };
    drop(inventory);
    let home = settings.claude_home.clone();
    let mut cache = cache.lock_owned().await;
    tokio::task::spawn_blocking(move || {
        cache.seen.clear();
        let result = sessions
            .into_iter()
            .filter_map(|session| {
                let id = session.session_id?;
                if !valid_id(&id) {
                    return None;
                }
                let slug = crate::providers::claude::project_slug(&session.cwd.to_string_lossy());
                let path = home.join("projects").join(slug).join(format!("{id}.jsonl"));
                let (state, tail) = if session.pid.is_none() {
                    // Background jobs can remain listed after their process exits.
                    if session.state.as_deref() == Some("blocked") {
                        (
                            ActivityState::Waiting,
                            cache.boundary(&path, boundary).ok().flatten(),
                        )
                    } else {
                        (ActivityState::Unknown, None)
                    }
                } else {
                    let tail = cache.boundary(&path, boundary);
                    let owner_started = (session.started_at / 1000) as i64;
                    let state = match tail
                        .as_ref()
                        .map(|tail| tail.and_then(|b| b.state_since(owner_started)))
                    {
                        Ok(Some(ActivityState::Working))
                            if session.status.as_deref() == Some("waiting") =>
                        {
                            ActivityState::Waiting
                        }
                        Ok(Some(state)) => state,
                        Ok(None) => match session.status.as_deref() {
                            Some("idle") => ActivityState::Idle,
                            _ => ActivityState::Unknown,
                        },
                        Err(_) => ActivityState::Unknown,
                    };
                    (state, tail.ok().flatten())
                };
                let waiting_since = tail
                    .filter(|_| state == ActivityState::Waiting)
                    .and_then(|boundary| boundary.timestamp);
                let owner = session
                    .pid
                    .and_then(|pid| i32::try_from(pid).ok())
                    .map(|pid| SessionOwner::Client { pid });
                Some(SessionActivity {
                    thread_id: format!("claude_{id}"),
                    state,
                    owner,
                    waiting_since,
                })
            })
            .collect();
        cache.finish();
        result
    })
    .await
    .context("Claude activity reader failed")
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record<'a> {
    #[serde(rename = "type")]
    kind: String,
    timestamp: Option<String>,
    subtype: Option<String>,
    #[serde(default)]
    is_sidechain: bool,
    #[serde(default)]
    is_meta: bool,
    #[serde(default)]
    is_compact_summary: bool,
    #[serde(rename = "parentToolUseID", alias = "parent_tool_use_id", borrow)]
    parent_tool: Option<&'a RawValue>,
    #[serde(borrow)]
    message: Option<Message<'a>>,
}

#[derive(Deserialize)]
struct Message<'a> {
    stop_reason: Option<String>,
    #[serde(borrow)]
    content: Option<&'a RawValue>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Content {
    Text(String),
    Blocks(Vec<TextBlock>),
}

#[derive(Deserialize)]
struct TextBlock {
    text: Option<String>,
}

impl Content {
    fn any_text(&self, predicate: impl Fn(&str) -> bool) -> bool {
        match self {
            Self::Text(text) => predicate(text),
            Self::Blocks(blocks) => blocks
                .iter()
                .any(|block| block.text.as_deref().is_some_and(&predicate)),
        }
    }
}

pub(super) fn boundary(line: &[u8]) -> Result<Option<Boundary>> {
    let record: Record<'_> = serde_json::from_slice(line)?;
    if record.is_sidechain || record.parent_tool.is_some() {
        return Ok(None);
    }
    let state = match record.kind.as_str() {
        "system" if record.subtype.as_deref() == Some("turn_duration") => ActivityState::Idle,
        "assistant" => match record
            .message
            .as_ref()
            .and_then(|m| m.stop_reason.as_deref())
        {
            Some(reason) if is_turn_end_stop_reason(reason) => ActivityState::Idle,
            Some("tool_use") | None => ActivityState::Working,
            _ => ActivityState::Unknown,
        },
        "user" => {
            let content: Option<Content> = record
                .message
                .and_then(|m| m.content)
                .map(|content| serde_json::from_str(content.get()))
                .transpose()?;
            if content
                .as_ref()
                .is_some_and(|c| c.any_text(is_abort_marker))
            {
                ActivityState::Idle
            } else if record.is_meta
                || record.is_compact_summary
                || content
                    .as_ref()
                    .is_some_and(|c| c.any_text(is_injected_user_text))
            {
                return Ok(None);
            } else {
                ActivityState::Working
            }
        }
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

    fn inventory(
        registry: Vec<(OsString, FileRevision)>,
        pid: u32,
        age: Duration,
    ) -> ClaudeInventory {
        let session: ClaudeSession = serde_json::from_value(serde_json::json!({
            "sessionId": "00000000-0000-0000-0000-000000000000",
            "cwd": "/tmp",
            "startedAt": 0,
            "pid": pid,
        }))
        .expect("session");
        ClaudeInventory {
            listing: Some(Listing {
                sessions: vec![session],
                registry,
                listed_at: Instant::now() - age,
            }),
            ..ClaudeInventory::default()
        }
    }

    #[test]
    fn the_listing_is_reused_only_while_registry_age_and_processes_all_hold() {
        let dir = tempfile::TempDir::new().expect("dir");
        std::fs::write(dir.path().join("1.json"), "{}").expect("registry entry");
        let registry = registry_revisions(dir.path()).expect("registry");
        let alive = std::process::id();

        let fresh = inventory(registry.clone(), alive, Duration::ZERO);
        assert!(fresh.current(Some(&registry)).is_some());
        assert!(
            fresh.current(None).is_none(),
            "an unreadable registry proves nothing"
        );

        std::fs::write(dir.path().join("2.json"), "{}").expect("new session");
        let changed = registry_revisions(dir.path()).expect("registry");
        assert!(fresh.current(Some(&changed)).is_none());

        let aged = inventory(registry.clone(), alive, MAX_LISTING_AGE);
        assert!(aged.current(Some(&registry)).is_none());

        let mut child = std::process::Command::new("/usr/bin/true")
            .spawn()
            .expect("child");
        let exited = child.id();
        child.wait().expect("child exit");
        let orphaned = inventory(registry.clone(), exited, Duration::ZERO);
        assert!(orphaned.current(Some(&registry)).is_none());
    }
}
