use std::collections::HashSet;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

pub(crate) const FILE_NAME: &str = "claude-restart-recovery.json";
pub(crate) const MAX_DISPATCH_ATTEMPTS: u8 = 3;
const SCHEMA_VERSION: u8 = 3;
const MAX_ITEMS: usize = 1_000;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RecoveryAccount {
    pub id: String,
    pub generation: u64,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ItemStatus {
    Captured,
    Dispatching,
    Dispatched,
    Stopped,
    Failed,
}

impl ItemStatus {
    pub(crate) fn is_pending(self) -> bool {
        matches!(self, Self::Captured | Self::Dispatching)
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Cause {
    Restart,
    Migration,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum TaskKind {
    Agent,
    Command,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct PausedTask {
    pub id: String,
    pub kind: TaskKind,
    pub label: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind",
    deny_unknown_fields
)]
pub(crate) enum ScheduledWake {
    Loop { next_wake_unix_ms: Option<u64> },
    Cron { schedule: String },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Event {
    pub cause: Cause,
    pub captured_at_unix_ms: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Item {
    pub recovery_id: String,
    pub thread_id: String,
    pub session_uuid: String,
    pub cwd: String,
    pub model: String,
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub fast: bool,
    pub cause: Cause,
    pub interrupted_turn_id: Option<String>,
    pub agent_initiated: bool,
    pub background_tasks: Vec<PausedTask>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub scheduled_wakes: Vec<ScheduledWake>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub queued_inputs: Vec<crate::providers::claude::ClaudeUserInput>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub earlier_events: Vec<Event>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop_generation: Option<u64>,
    pub captured_at_unix_ms: u64,
    pub status: ItemStatus,
    pub attempts: u8,
    pub resumed_turn_id: Option<String>,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct SuspendedTurn {
    pub turn_id: String,
    pub stoppable: bool,
}

impl Item {
    pub(crate) fn selection(&self) -> crate::providers::claude::ClaudeSelection {
        crate::providers::claude::ClaudeSelection {
            model: self.model.clone(),
            effort: self.effort.clone(),
            fast: self.fast,
        }
    }

    pub(crate) fn suspended_turn(&self) -> Option<SuspendedTurn> {
        self.interrupted_turn_id
            .clone()
            .map(|turn_id| SuspendedTurn {
                turn_id,
                stoppable: self.stop_generation.is_some(),
            })
    }

    pub(crate) fn absorb(&mut self, earlier: Item) {
        self.earlier_events.extend(earlier.earlier_events);
        self.earlier_events.push(Event {
            cause: earlier.cause,
            captured_at_unix_ms: earlier.captured_at_unix_ms,
        });
        if self.interrupted_turn_id.is_none() {
            self.interrupted_turn_id = earlier.interrupted_turn_id;
        }
        let mut tasks = earlier.background_tasks;
        tasks.retain(|task| !self.background_tasks.iter().any(|kept| kept.id == task.id));
        tasks.append(&mut self.background_tasks);
        self.background_tasks = tasks;
        let loops_again = self
            .scheduled_wakes
            .iter()
            .any(|wake| matches!(wake, ScheduledWake::Loop { .. }));
        let mut wakes = earlier
            .scheduled_wakes
            .into_iter()
            .filter(|wake| match wake {
                ScheduledWake::Loop { .. } => !loops_again,
                ScheduledWake::Cron { .. } => !self.scheduled_wakes.contains(wake),
            })
            .collect::<Vec<_>>();
        wakes.append(&mut self.scheduled_wakes);
        self.scheduled_wakes = wakes;
    }

    pub(crate) fn notice(&self) -> String {
        let mut notice = vec![
            "Automated notice from RemoteCoder, the app the user runs this Claude Code session through; the user did not type it.".to_owned(),
        ];
        notice.extend(self.earlier_events.iter().map(Event::describe));
        notice.push(
            Event {
                cause: self.cause,
                captured_at_unix_ms: self.captured_at_unix_ms,
            }
            .describe(),
        );
        let event = match (self.earlier_events.is_empty(), self.cause) {
            (false, _) => "stop",
            (true, Cause::Restart) => "gateway restart",
            (true, Cause::Migration) => "profile migration",
        };
        if self.interrupted_turn_id.is_some() {
            notice.push("Your response in progress was cut off mid-step; recheck any command it was running before relying on its result.".to_owned());
        }
        let listed = |kind: TaskKind, entry: fn(&PausedTask) -> String| {
            self.background_tasks
                .iter()
                .filter(|task| task.kind == kind)
                .map(entry)
                .collect::<Vec<_>>()
        };
        let agents = listed(TaskKind::Agent, |task| {
            format!("{} ({})", task.id, task.label)
        });
        if !agents.is_empty() {
            notice.push(format!(
                "Your background agents were paused, not cancelled, and keep their progress. Resume each one that should continue with SendMessage to its agent id: {}. In each message, tell the agent that this planned {event} stopped it, and that if it was running a command, the {event} killed that command (it may show exit code 137 or 143; that was not a crash or an out-of-memory kill), so it should check what that command already did and rerun it only if it is still needed, then continue its task.",
                agents.join(", ")
            ));
        }
        let commands = listed(TaskKind::Command, |task| task.label.clone());
        if !commands.is_empty() {
            notice.push(format!(
                "These background commands and monitors ended with the process; rerun any you still need: {}.",
                commands.join("; ")
            ));
        }
        for wake in &self.scheduled_wakes {
            if let ScheduledWake::Loop { next_wake_unix_ms } = wake {
                notice.push(match next_wake_unix_ms {
                    Some(at) => format!(
                        "Your /loop wake-up due at {} ended with the process; call ScheduleWakeup again to keep the loop going.",
                        local_time(*at)
                    ),
                    None => "Your /loop ended with the process; call ScheduleWakeup again to keep the loop going.".to_owned(),
                });
            }
        }
        let crons = self
            .scheduled_wakes
            .iter()
            .filter_map(|wake| match wake {
                ScheduledWake::Cron { schedule } => Some(schedule.as_str()),
                ScheduledWake::Loop { .. } => None,
            })
            .collect::<Vec<_>>();
        if !crons.is_empty() {
            notice.push(format!(
                "Your scheduled cron jobs come back with this resumed session and keep their schedules: {}.",
                crons.join("; ")
            ));
        }
        notice.push("Agents you started with spawn_agent run separately, keep running and still report back here.".to_owned());
        notice.push(format!(
            "Inspect the session history and current workspace state first. Do not repeat side effects already completed; continue only the remaining work. Recovery id: {}",
            self.recovery_id
        ));
        notice.join(" ")
    }
}

impl Event {
    fn describe(&self) -> String {
        let time = local_time(self.captured_at_unix_ms);
        match self.cause {
            Cause::Restart => format!(
                "At {time} this Mac's RemoteCoder gateway restarted for a planned restart or deploy, which ended this session's Claude Code process, and RemoteCoder has now resumed the session."
            ),
            Cause::Migration => format!(
                "At {time} this session's Claude Code process ended before RemoteCoder consolidated its Claude profiles. RemoteCoder has now resumed the session in this Mac's host profile."
            ),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Journal {
    pub schema_version: u8,
    pub generation_id: String,
    pub account: Option<RecoveryAccount>,
    pub items: Vec<Item>,
}

impl Journal {
    pub(crate) fn capture(
        account: Option<RecoveryAccount>,
        captured: Vec<Item>,
        previous: Option<Journal>,
    ) -> Result<Self> {
        let captured_threads = captured
            .iter()
            .map(|item| item.thread_id.clone())
            .collect::<HashSet<_>>();
        let carried = previous
            .into_iter()
            .filter(|previous| previous.account == account)
            .flat_map(|previous| previous.items)
            .filter(|item| item.status.is_pending() && !captured_threads.contains(&item.thread_id))
            .collect::<Vec<_>>();
        let journal = Self {
            schema_version: SCHEMA_VERSION,
            generation_id: crate::ids::new_session_uuid(),
            account,
            items: captured.into_iter().chain(carried).collect(),
        };
        journal.validate()?;
        Ok(journal)
    }

    fn is_settled(&self) -> bool {
        !self.items.iter().any(|item| item.status.is_pending())
    }

    fn validate(&self) -> Result<()> {
        if self.schema_version != SCHEMA_VERSION {
            bail!(
                "unsupported Claude restart recovery schema {}",
                self.schema_version
            );
        }
        if self.generation_id.is_empty() || self.generation_id.len() > 128 {
            bail!("invalid Claude restart recovery generation id");
        }
        if self.items.len() > MAX_ITEMS {
            bail!("Claude restart recovery exceeds the {MAX_ITEMS}-item safety bound");
        }
        let mut recovery_ids = HashSet::with_capacity(self.items.len());
        let mut threads = HashSet::with_capacity(self.items.len());
        for item in &self.items {
            if item.recovery_id.is_empty()
                || item.thread_id.is_empty()
                || item.session_uuid.is_empty()
                || item.cwd.is_empty()
                || item.model.is_empty()
            {
                bail!("Claude restart recovery item is missing its identity");
            }
            if item.attempts > MAX_DISPATCH_ATTEMPTS {
                bail!("Claude restart recovery item exceeds its dispatch attempt bound");
            }
            if !recovery_ids.insert(item.recovery_id.as_str()) {
                bail!("duplicate Claude recovery id {}", item.recovery_id);
            }
            if !threads.insert(item.thread_id.as_str()) {
                bail!("duplicate Claude recovery thread {}", item.thread_id);
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub(crate) struct Store {
    path: PathBuf,
}

impl Store {
    pub(crate) fn beside(turn_state_path: &Path) -> Self {
        Self {
            path: turn_state_path.with_file_name(FILE_NAME),
        }
    }

    pub(crate) fn load(&self) -> Result<Option<Journal>> {
        let metadata = match std::fs::symlink_metadata(&self.path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("failed to inspect {}", self.path.display()));
            }
        };
        if !metadata.file_type().is_file()
            || metadata.uid() != unsafe { libc::getuid() }
            || metadata.permissions().mode() & 0o077 != 0
        {
            bail!(
                "Claude restart recovery journal must be a private regular file owned by the current user: {}",
                self.path.display()
            );
        }
        let bytes = std::fs::read(&self.path)
            .with_context(|| format!("failed to read {}", self.path.display()))?;
        let journal: Journal = serde_json::from_value(migrate(
            serde_json::from_slice(&bytes)
                .with_context(|| format!("failed to parse {}", self.path.display()))?,
        ))
        .with_context(|| format!("failed to parse {}", self.path.display()))?;
        journal.validate()?;
        Ok(Some(journal))
    }

    pub(crate) fn write(&self, journal: &Journal) -> Result<()> {
        journal.validate()?;
        let parent = self
            .path
            .parent()
            .context("Claude restart recovery journal has no parent")?;
        crate::storage::private_state::ensure_private_directory(parent)?;
        crate::storage::private_state::write_json(&self.path, journal)
    }

    pub(crate) fn update_item(
        &self,
        generation_id: &str,
        recovery_id: &str,
        update: impl FnOnce(&mut Item),
    ) -> Result<Journal> {
        let mut journal = self
            .load()?
            .context("Claude restart recovery journal disappeared")?;
        if journal.generation_id != generation_id {
            bail!(
                "Claude restart recovery generation changed from {generation_id} to {}",
                journal.generation_id
            );
        }
        let item = journal
            .items
            .iter_mut()
            .find(|item| item.recovery_id == recovery_id)
            .with_context(|| format!("Claude recovery item {recovery_id} disappeared"))?;
        update(item);
        self.write(&journal)?;
        Ok(journal)
    }

    pub(crate) fn remove_settled(&self, generation_id: &str) -> Result<bool> {
        let Some(journal) = self.load()? else {
            return Ok(false);
        };
        if journal.generation_id != generation_id || !journal.is_settled() {
            return Ok(false);
        }
        std::fs::remove_file(&self.path)
            .with_context(|| format!("failed to remove {}", self.path.display()))?;
        Ok(true)
    }
}

pub(crate) fn migrate(mut journal: serde_json::Value) -> serde_json::Value {
    let version = journal["schemaVersion"].as_u64();
    if !matches!(version, Some(1 | 2)) {
        return journal;
    }
    journal["schemaVersion"] = SCHEMA_VERSION.into();
    for item in journal["items"].as_array_mut().into_iter().flatten() {
        if let Some(item) = item.as_object_mut() {
            if version == Some(1) {
                item.remove("backgroundTaskIds");
                item.insert("backgroundTasks".to_owned(), serde_json::json!([]));
                item.insert("cause".to_owned(), serde_json::json!("restart"));
            }
            migrate_event(item);
            for event in item
                .get_mut("earlierEvents")
                .and_then(serde_json::Value::as_array_mut)
                .into_iter()
                .flatten()
            {
                if let Some(event) = event.as_object_mut() {
                    migrate_event(event);
                }
            }
        }
    }
    journal
}

fn migrate_event(event: &mut serde_json::Map<String, serde_json::Value>) {
    event.remove("accountSwitch");
    if matches!(
        event.get("cause").and_then(serde_json::Value::as_str),
        Some("move" | "moveFailed")
    ) {
        event.insert("cause".to_owned(), serde_json::json!("migration"));
    }
}

unsafe extern "C" {
    fn tzset();
}

fn local_time(unix_ms: u64) -> String {
    let seconds = (unix_ms / 1_000) as libc::time_t;
    let mut time: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { tzset() };
    if unsafe { libc::localtime_r(&seconds, &mut time) }.is_null() {
        return format!("Unix time {seconds}");
    }
    let mut buffer = [0u8; 64];
    let written = unsafe {
        libc::strftime(
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            c"%Y-%m-%d %H:%M %Z".as_ptr(),
            &time,
        )
    };
    if written == 0 {
        return format!("Unix time {seconds}");
    }
    String::from_utf8_lossy(&buffer[..written]).into_owned()
}

#[cfg(test)]
pub(crate) mod test_support {
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use serde_json::Value;

    use super::{Item, ItemStatus};
    use crate::providers::claude::settings::ClaudeSettings;

    pub(crate) const SESSION: &str = "11111111-2222-4333-8444-555555555555";
    pub(crate) const THREAD: &str = "claude_11111111-2222-4333-8444-555555555555";

    pub(crate) struct StubClaude {
        _root: crate::providers::claude::settings::ClaudeTestSettings,
        pub cwd: String,
        pub claude_home: PathBuf,
        pub state: PathBuf,
        pub settings: ClaudeSettings,
    }

    impl StubClaude {
        pub fn new() -> Self {
            let root = ClaudeSettings::isolated_for_test();
            let cwd = root.root_path().join("work");
            let claude_home = root.root_path().join("claude");
            let state = root.root_path().join("state");
            std::fs::create_dir_all(&cwd).unwrap();
            std::fs::create_dir_all(&state).unwrap();
            let cwd = cwd.to_string_lossy().into_owned();
            let executable = root.root_path().join("claude-stub");
            crate::test_support::write_claude_cli_stub(
                &executable,
                crate::test_support::ClaudeCliMode::RestartAbortedStreaming,
            );
            let wrapper = root.root_path().join("claude-wrapper");
            std::fs::write(
                &wrapper,
                format!(
                    "#!/bin/sh\nRC_TEST_STATE_DIR='{}' RC_TEST_CWD='{}' exec '{}' \"$@\"\n",
                    state.display(),
                    cwd,
                    executable.display()
                ),
            )
            .unwrap();
            std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o700)).unwrap();
            let settings = ClaudeSettings {
                claude_path: wrapper,
                claude_home: claude_home.clone(),
                config_dir: Some(claude_home.clone()),
                mcp_endpoint: "http://127.0.0.1:8787/mcp".to_owned(),
                mcp_config_dir: root.root_path().join("mcp"),
                ..root.settings.clone()
            };
            let stub = Self {
                _root: root,
                cwd,
                claude_home,
                state,
                settings,
            };
            stub.write_history(SESSION, "{\"type\":\"user\",\"message\":\"existing\"}\n");
            stub
        }

        pub(crate) fn history(&self, session_uuid: &str) -> PathBuf {
            crate::providers::claude::timeline::session_path_for_cwd(
                &self.claude_home,
                &self.cwd,
                session_uuid,
            )
        }

        pub(crate) fn write_history(&self, session_uuid: &str, contents: &str) {
            let path = self.history(session_uuid);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, contents).unwrap();
        }

        pub(crate) fn turn_state_path(&self) -> PathBuf {
            self.state.join("active-codex-turns.json")
        }

        pub(crate) fn log(&self, name: &str) -> Vec<Value> {
            read_log(&self.state.join(name))
        }

        pub(crate) async fn wait_for_log(&self, name: &str, count: usize) -> Vec<Value> {
            let path = self.state.join(name);
            tokio::time::timeout(Duration::from_secs(5), async {
                loop {
                    let values = read_log(&path);
                    if values.len() >= count {
                        return values;
                    }
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            })
            .await
            .unwrap_or_else(|_| panic!("{name} never reached {count} entries"))
        }

        pub(crate) fn item(&self, session_uuid: &str, status: ItemStatus) -> Item {
            Item {
                recovery_id: crate::ids::new_session_uuid(),
                thread_id: crate::providers::claude::claude_thread_id(session_uuid),
                session_uuid: session_uuid.to_owned(),
                cwd: self.cwd.clone(),
                model: "opus".to_owned(),
                effort: Some("max".to_owned()),
                fast: false,
                cause: super::Cause::Restart,
                interrupted_turn_id: Some("claude-turn-1".to_owned()),
                agent_initiated: false,
                background_tasks: Vec::new(),
                scheduled_wakes: Vec::new(),
                queued_inputs: Vec::new(),
                earlier_events: Vec::new(),
                stop_generation: None,
                captured_at_unix_ms: crate::time::unix_millis() as u64,
                status,
                attempts: 0,
                resumed_turn_id: None,
                error: None,
            }
        }
    }

    fn read_log(path: &Path) -> Vec<Value> {
        std::fs::read_to_string(path)
            .unwrap_or_default()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(thread: &str, status: ItemStatus) -> Item {
        Item {
            recovery_id: format!("recovery-{thread}"),
            thread_id: format!("claude_{thread}"),
            session_uuid: format!("{thread}-session"),
            cwd: "/work".to_owned(),
            model: "fable".to_owned(),
            effort: Some("high".to_owned()),
            fast: false,
            cause: Cause::Restart,
            interrupted_turn_id: Some(format!("claude-turn-{thread}")),
            agent_initiated: false,
            background_tasks: Vec::new(),
            scheduled_wakes: Vec::new(),
            queued_inputs: Vec::new(),
            earlier_events: Vec::new(),
            stop_generation: None,
            captured_at_unix_ms: 1_790_000_000_000,
            status,
            attempts: 0,
            resumed_turn_id: None,
            error: None,
        }
    }

    fn account() -> Option<RecoveryAccount> {
        Some(RecoveryAccount {
            id: "family".to_owned(),
            generation: 3,
        })
    }

    #[test]
    fn a_captured_journal_is_private_and_round_trips() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::beside(&root.path().join("state/active-codex-turns.json"));
        let journal =
            Journal::capture(account(), vec![item("a", ItemStatus::Captured)], None).unwrap();

        store.write(&journal).unwrap();

        let file_mode = std::fs::metadata(root.path().join("state").join(FILE_NAME))
            .unwrap()
            .permissions()
            .mode();
        let directory_mode = std::fs::metadata(root.path().join("state"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(file_mode & 0o777, 0o600);
        assert_eq!(directory_mode & 0o777, 0o700);
        assert_eq!(store.load().unwrap(), Some(journal));
    }

    #[test]
    fn a_readable_journal_is_rejected_rather_than_trusted() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::beside(&root.path().join("active-codex-turns.json"));
        let journal = Journal::capture(None, vec![item("a", ItemStatus::Captured)], None).unwrap();
        store.write(&journal).unwrap();
        std::fs::set_permissions(
            root.path().join(FILE_NAME),
            std::fs::Permissions::from_mode(0o644),
        )
        .unwrap();

        let error = store.load().unwrap_err();

        assert!(
            error.to_string().contains("private regular file"),
            "{error}"
        );
    }

    #[test]
    fn a_new_capture_carries_only_pending_work_it_did_not_recapture() {
        let previous = Journal::capture(
            account(),
            vec![
                item("dispatching", ItemStatus::Dispatching),
                item("waiting", ItemStatus::Captured),
                item("done", ItemStatus::Dispatched),
                item("failed", ItemStatus::Failed),
                item("recaptured", ItemStatus::Captured),
            ],
            None,
        )
        .unwrap();
        let mut recaptured = item("recaptured", ItemStatus::Captured);
        recaptured.recovery_id = "recovery-recaptured-again".to_owned();

        let journal =
            Journal::capture(account(), vec![recaptured], Some(previous.clone())).unwrap();

        let threads = journal
            .items
            .iter()
            .map(|item| (item.thread_id.as_str(), item.recovery_id.as_str()))
            .collect::<Vec<_>>();
        assert_eq!(
            threads,
            [
                ("claude_recaptured", "recovery-recaptured-again"),
                ("claude_dispatching", "recovery-dispatching"),
                ("claude_waiting", "recovery-waiting"),
            ]
        );
        assert_ne!(journal.generation_id, previous.generation_id);
        let other_account = Journal::capture(None, Vec::new(), Some(previous)).unwrap();
        assert!(other_account.items.is_empty());
    }

    #[test]
    fn updates_are_bound_to_their_generation_and_settled_journals_are_removed() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::beside(&root.path().join("active-codex-turns.json"));
        let journal = Journal::capture(None, vec![item("a", ItemStatus::Captured)], None).unwrap();
        store.write(&journal).unwrap();

        assert!(store.update_item("other", "recovery-a", |_| {}).is_err());
        assert!(!store.remove_settled(&journal.generation_id).unwrap());
        store
            .update_item(&journal.generation_id, "recovery-a", |item| {
                item.status = ItemStatus::Dispatched;
            })
            .unwrap();

        assert!(store.remove_settled(&journal.generation_id).unwrap());
        assert_eq!(store.load().unwrap(), None);
    }

    #[test]
    fn the_notice_names_the_cause_the_interruption_the_paused_work_and_the_recovery_id() {
        let mut captured = item("a", ItemStatus::Captured);
        captured.background_tasks = vec![
            PausedTask {
                id: "a1b2".to_owned(),
                kind: TaskKind::Agent,
                label: "Review the diff".to_owned(),
            },
            PausedTask {
                id: "shell-1".to_owned(),
                kind: TaskKind::Command,
                label: "npm run dev".to_owned(),
            },
        ];
        let notice = captured.notice();
        assert!(
            notice.starts_with("Automated notice from RemoteCoder, the app the user runs this Claude Code session through; the user did not type it. At 20"),
            "{notice}"
        );
        assert!(
            notice.contains("gateway restarted for a planned restart"),
            "{notice}"
        );
        assert!(notice.contains("cut off mid-step"), "{notice}");
        assert!(
            notice.contains("SendMessage to its agent id: a1b2 (Review the diff). In each message, tell the agent that this planned gateway restart stopped it, and that if it was running a command"),
            "{notice}"
        );
        assert!(notice.contains("exit code 137 or 143"), "{notice}");
        assert!(
            notice.contains(
                "check what that command already did and rerun it only if it is still needed"
            ),
            "{notice}"
        );
        assert!(
            notice.contains("rerun any you still need: npm run dev."),
            "{notice}"
        );
        assert!(!notice.contains("shell-1"), "{notice}");
        assert!(notice.ends_with("Recovery id: recovery-a"), "{notice}");
        assert!(!notice.contains('<'));

        captured.interrupted_turn_id = None;
        captured.background_tasks.clear();
        let notice = captured.notice();
        assert!(!notice.contains("mid-step"), "{notice}");
        assert!(!notice.contains("SendMessage"), "{notice}");
    }

    #[test]
    fn an_unread_earlier_notice_folds_into_one_notice_in_time_order() {
        let mut first = item("a", ItemStatus::Dispatched);
        first.captured_at_unix_ms = 1_000;
        first.background_tasks = vec![PausedTask {
            id: "a1b2".to_owned(),
            kind: TaskKind::Agent,
            label: "Review the diff".to_owned(),
        }];
        first.scheduled_wakes = vec![
            ScheduledWake::Loop {
                next_wake_unix_ms: None,
            },
            ScheduledWake::Cron {
                schedule: "0 9 * * *".to_owned(),
            },
        ];
        let mut latest = item("a", ItemStatus::Captured);
        latest.interrupted_turn_id = None;
        latest.captured_at_unix_ms = 2_000;
        latest.scheduled_wakes = vec![ScheduledWake::Cron {
            schedule: "0 9 * * *".to_owned(),
        }];

        latest.absorb(first);
        let notice = latest.notice();

        assert_eq!(notice.matches("gateway restarted").count(), 2, "{notice}");
        assert_eq!(notice.matches("Automated notice").count(), 1, "{notice}");
        assert!(notice.contains("cut off mid-step"), "{notice}");
        assert!(
            notice.contains("a1b2 (Review the diff). In each message, tell the agent that this planned stop stopped it"),
            "{notice}"
        );
        assert_eq!(notice.matches("/loop").count(), 1, "{notice}");
        assert_eq!(notice.matches("0 9 * * *").count(), 1, "{notice}");
        assert!(notice.ends_with("Recovery id: recovery-a"), "{notice}");
    }

    #[test]
    fn a_journal_written_before_background_work_was_classified_still_recovers() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::beside(&root.path().join("active-codex-turns.json"));
        let mut legacy = serde_json::to_value(
            Journal::capture(account(), vec![item("a", ItemStatus::Captured)], None).unwrap(),
        )
        .unwrap();
        legacy["schemaVersion"] = 1.into();
        let fields = legacy["items"][0].as_object_mut().unwrap();
        fields.remove("cause");
        fields.remove("backgroundTasks");
        fields.insert(
            "backgroundTaskIds".to_owned(),
            serde_json::json!(["shell-1"]),
        );
        crate::storage::private_state::write_json(&root.path().join(FILE_NAME), &legacy).unwrap();

        let journal = store.load().unwrap().unwrap();

        assert_eq!(journal.schema_version, SCHEMA_VERSION);
        assert_eq!(journal.items[0].cause, Cause::Restart);
        assert!(journal.items[0].background_tasks.is_empty());
        assert_eq!(journal.items[0].recovery_id, "recovery-a");
    }

    #[test]
    fn legacy_account_move_recovery_preserves_pending_work_without_account_switches() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::beside(&root.path().join("active-codex-turns.json"));
        let mut captured = item("a", ItemStatus::Captured);
        captured.background_tasks = vec![PausedTask {
            id: "agent-task".to_owned(),
            kind: TaskKind::Agent,
            label: "Review the diff".to_owned(),
        }];
        captured.queued_inputs = vec![crate::providers::claude::ClaudeUserInput::text(
            "continue reviewing",
        )];
        captured.earlier_events = vec![Event {
            cause: Cause::Restart,
            captured_at_unix_ms: 1_000,
        }];
        let mut legacy = serde_json::to_value(
            Journal::capture(account(), vec![captured.clone()], None).unwrap(),
        )
        .unwrap();
        legacy["schemaVersion"] = 2.into();
        legacy["items"][0]["cause"] = "move".into();
        legacy["items"][0]["accountSwitch"] = serde_json::json!({
            "fromEmail": "a@example.test", "toEmail": "b@example.test"
        });
        legacy["items"][0]["earlierEvents"][0]["cause"] = "moveFailed".into();
        legacy["items"][0]["earlierEvents"][0]["accountSwitch"] = serde_json::json!({
            "fromEmail": "c@example.test", "toEmail": "a@example.test"
        });
        crate::storage::private_state::write_json(&root.path().join(FILE_NAME), &legacy).unwrap();

        let journal = store.load().unwrap().unwrap();
        let migrated = &journal.items[0];
        assert_eq!(journal.schema_version, SCHEMA_VERSION);
        assert_eq!(migrated.cause, Cause::Migration);
        assert_eq!(migrated.earlier_events[0].cause, Cause::Migration);
        assert_eq!(migrated.earlier_events[0].captured_at_unix_ms, 1_000);
        assert_eq!(migrated.background_tasks, captured.background_tasks);
        assert_eq!(migrated.queued_inputs, captured.queued_inputs);
        assert_eq!(migrated.interrupted_turn_id, captured.interrupted_turn_id);
        assert_eq!(migrated.status, ItemStatus::Captured);
        assert!(!migrated.notice().contains("@example.test"));
        store.write(&journal).unwrap();
        assert_eq!(store.load().unwrap(), Some(journal));
    }
}
