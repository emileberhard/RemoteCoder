use super::turn_state::{active_tasks_live_activity_snapshot, text_preview};
use super::{ActiveTasksLiveActivitySnapshot, Gateway};
use crate::conversation_marks::{Marks, ThreadMarks};
use crate::providers::claude::{is_claude_thread_id, session_uuid_from_thread_id};
use crate::push::{AttentionReason, AttentionRow, LiveActivityContent, MAX_ATTENTION_ROWS};
use crate::storage::private_state;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::watch;
use tracing::warn;

const COALESCE_WINDOW: Duration = Duration::from_millis(250);
const TITLE_READ_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_TITLE_CHARS: usize = 80;
const MAX_FINISHED_TURNS: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct FinishedTurn {
    pub turn_id: String,
    pub started_at: i64,
    pub completed_at: i64,
}

impl FinishedTurn {
    fn is_unread(&self, marks: Option<&ThreadMarks>, read_baseline: i64) -> bool {
        let seen = marks
            .and_then(|marks| marks.seen_through)
            .unwrap_or(i64::MIN);
        marks.is_some_and(|marks| marks.marked_unread)
            || marks.is_none_or(|marks| marks.purpose.is_none())
                && read_baseline.max(seen) < self.completed_at
                && seen <= self.started_at
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub(super) struct FinishedTurns(Option<BTreeMap<String, FinishedTurn>>);

impl Default for FinishedTurns {
    fn default() -> Self {
        Self(Some(BTreeMap::new()))
    }
}

impl FinishedTurns {
    pub(super) fn path(turn_state: &Path) -> PathBuf {
        turn_state.with_file_name("live-activity-finished-turns.json")
    }

    pub(super) async fn load(path: &Path) -> Self {
        let owned = path.to_owned();
        let parsed = tokio::task::spawn_blocking(move || -> Result<Self> {
            match private_state::read_bounded(&owned, 256 * 1024)
                .map_err(|error| anyhow::anyhow!("{error:?}"))?
            {
                Some(bytes) => {
                    let turns: Self =
                        serde_json::from_slice(&bytes).context("parsing finished turns")?;
                    turns.known()?;
                    Ok(turns)
                }
                None => Ok(Self::default()),
            }
        })
        .await
        .context("finished-turn reader failed")
        .and_then(|result| result);
        parsed.unwrap_or_else(|error| {
            warn!(error = %format!("{error:#}"), path = %path.display(), "finished turns unavailable; preserving state");
            Self(None)
        })
    }

    pub(super) fn is_available(&self) -> bool {
        self.0.is_some()
    }

    fn known(&self) -> Result<&BTreeMap<String, FinishedTurn>> {
        self.0
            .as_ref()
            .context("Live Activity completion state unavailable")
    }

    pub(super) fn record(&mut self, thread: &str, turn: FinishedTurn) {
        let Some(turns) = self.0.as_mut() else { return };
        turns.insert(thread.to_owned(), turn);
        if turns.len() > MAX_FINISHED_TURNS
            && let Some(oldest) = turns
                .iter()
                .min_by_key(|(_, turn)| turn.completed_at)
                .map(|(thread, _)| thread.clone())
        {
            turns.remove(&oldest);
        }
    }

    pub(super) fn note_started(&mut self, thread: &str, turn_id: &str) {
        if let Some(turns) = self.0.as_mut()
            && turns
                .get(thread)
                .is_some_and(|finished| finished.turn_id != turn_id)
        {
            turns.remove(thread);
        }
    }

    pub(super) fn remove(&mut self, thread: &str) -> bool {
        self.0
            .as_mut()
            .is_some_and(|turns| turns.remove(thread).is_some())
    }
}

fn asked_since_read(asked_at_ms: i64, marks: Option<&ThreadMarks>, read_baseline: i64) -> bool {
    let seen = marks
        .and_then(|marks| marks.seen_through)
        .unwrap_or(i64::MIN);
    asked_at_ms.div_euclid(1000) > read_baseline.max(seen)
}

fn header_title(header: &Value) -> Option<String> {
    ["name", "preview"]
        .into_iter()
        .filter_map(|field| header[field].as_str())
        .map(str::trim)
        .find(|title| !title.is_empty())
        .map(|title| text_preview(title, MAX_TITLE_CHARS))
}

fn attention_content(
    snapshot: &ActiveTasksLiveActivitySnapshot,
    marks: &Marks,
    latest_questions: &BTreeMap<String, i64>,
    owners: &HashMap<String, String>,
    account_id: Option<&str>,
) -> Result<LiveActivityContent> {
    let running: BTreeSet<&String> = snapshot
        .running
        .iter()
        .filter_map(|thread| owners.get(thread))
        .collect();
    let mut attention: Vec<_> = snapshot
        .finished
        .known()?
        .iter()
        .filter(|(thread, turn)| {
            owners.get(*thread) == Some(*thread)
                && !running.contains(thread)
                && turn.is_unread(marks.threads.get(*thread), marks.read_baseline)
        })
        .map(|(thread, turn)| {
            let completed_at = turn.completed_at;
            let asked = latest_questions.get(thread).is_some_and(|&asked_at_ms| {
                asked_since_read(asked_at_ms, marks.threads.get(thread), marks.read_baseline)
            });
            AttentionRow {
                thread_id: thread.clone(),
                account_id: account_id.map(str::to_owned),
                title: None,
                reason: if asked {
                    AttentionReason::Question {
                        completed_at: Some(completed_at),
                    }
                } else {
                    AttentionReason::FinishedUnread { completed_at }
                },
            }
        })
        .collect();
    attention.sort_by(AttentionRow::attention_order);
    let attention_count = attention.len();
    attention.truncate(MAX_ATTENTION_ROWS);
    Ok(LiveActivityContent {
        active_task_count: running.len(),
        attention,
        attention_count,
    })
}

impl Gateway {
    pub(super) async fn start_live_activity(self: &Arc<Self>) {
        let restored = active_tasks_live_activity_snapshot(&*self.core.lock().await);
        let (live_activity_tx, live_activity_rx) = watch::channel(restored);
        *self.apns_live_activity_tx.lock().await = Some(live_activity_tx);
        let live_activity_task = {
            let gw = Arc::clone(self);
            let task_gw = Arc::clone(&gw);
            tokio::spawn(
                task_gw.run_task_logged("apns_live_activity_loop", async move {
                    gw.apns_live_activity_loop(live_activity_rx).await
                }),
            )
        };
        *self.apns_live_activity_task.lock().await = Some(live_activity_task);
    }

    pub(super) async fn refresh_live_activity(&self) {
        let snapshot = active_tasks_live_activity_snapshot(&*self.core.lock().await);
        self.publish_live_activity(snapshot).await;
    }

    pub(super) async fn publish_live_activity(&self, snapshot: ActiveTasksLiveActivitySnapshot) {
        if let Some(tx) = self.apns_live_activity_tx.lock().await.as_ref() {
            tx.send_replace(snapshot);
        }
    }

    pub(super) async fn forget_finished_turn(&self, thread: &str) {
        if !self.core.lock().await.finished_turns.remove(thread) {
            return;
        }
        if let Err(error) = self.commit_turn_state().await {
            warn!(%error, "failed to persist finished turns");
        }
        self.refresh_live_activity().await;
    }

    pub(crate) async fn reconcile_live_activity_scopes(&self, retained: &BTreeSet<String>) {
        self.apns.reconcile_live_activity_scopes(retained).await;
    }

    pub(super) async fn apns_live_activity_loop(
        &self,
        rx: watch::Receiver<ActiveTasksLiveActivitySnapshot>,
    ) {
        tokio::join!(
            self.project_live_activity_loop(rx),
            self.broadcast_live_activity_loop()
        );
    }

    async fn broadcast_live_activity_loop(&self) {
        let mut updates = self.apns.live_activity_updates();
        updates.mark_changed();
        while updates.changed().await.is_ok() {
            let snapshot = updates.borrow_and_update().clone();
            if let Err(error) = self.broadcast_json_or_drop(
                &json!({"method":"daemon/liveActivity/changed","params":snapshot}),
                crate::observability::journal::Source::Gateway,
            ) {
                warn!(%error, "Live Activity snapshot broadcast failed");
            }
        }
    }

    async fn project_live_activity_loop(
        &self,
        mut rx: watch::Receiver<ActiveTasksLiveActivitySnapshot>,
    ) {
        let scope = "default";
        let mut titles = HashMap::new();
        rx.mark_changed();
        let mut retrying = false;
        loop {
            if retrying {
                tokio::select! {
                    changed = rx.changed() => { if changed.is_err() { break } }
                    _ = tokio::time::sleep(Duration::from_secs(3)) => {}
                }
            } else if rx.changed().await.is_err() {
                break;
            }
            tokio::time::sleep(COALESCE_WINDOW).await;
            let snapshot = rx.borrow_and_update().clone();
            let projection = tokio::select! {
                biased;
                changed = rx.changed() => {
                    if changed.is_err() { break; }
                    rx.mark_changed();
                    continue;
                }
                projection = self.live_activity_content(&snapshot, &mut titles) => projection,
            };
            let is_current = || matches!(rx.has_changed(), Ok(false));
            if !is_current() {
                continue;
            }
            match projection {
                Ok(content) => {
                    retrying = false;
                    self.apns
                        .report_live_activity_if_current(scope, content, is_current)
                        .await;
                }
                Err(error) => {
                    if !retrying {
                        warn!(error = %format!("{error:#}"), "Live Activity content unavailable");
                    }
                    retrying = true;
                    self.apns
                        .mark_live_activity_unavailable_if_current(scope, is_current)
                        .await;
                }
            }
        }
    }

    async fn live_activity_content(
        &self,
        snapshot: &ActiveTasksLiveActivitySnapshot,
        titles: &mut HashMap<String, (Option<i64>, Option<String>)>,
    ) -> Result<LiveActivityContent> {
        snapshot.finished.known()?;
        anyhow::ensure!(
            self.claude_recovery_complete().await?,
            "Live Activity Claude recovery unavailable"
        );
        let marks = self.marks.read(crate::time::unix_seconds() as i64).await?;
        let latest_questions = self.questions.latest_pending_questions().await;
        let threads: Vec<String> = snapshot
            .running
            .iter()
            .chain(snapshot.finished.known()?.keys())
            .cloned()
            .collect();
        let owners = self.agent_service().thread_roots(&threads).await;
        anyhow::ensure!(
            threads.iter().all(|thread| owners.contains_key(thread)),
            "Live Activity ancestry unavailable"
        );
        let account_id = None;
        let mut content =
            attention_content(snapshot, &marks, &latest_questions, &owners, account_id)?;

        titles.retain(|thread, _| content.attention.iter().any(|row| row.thread_id == *thread));
        for row in &mut content.attention {
            let completed_at = row.reason.completed_at();
            let header = match titles.get(&row.thread_id) {
                Some((cached_at, title)) if *cached_at == completed_at => title.clone(),
                _ => match self.live_activity_title(&row.thread_id).await {
                    Ok(title) => {
                        titles.insert(row.thread_id.clone(), (completed_at, title.clone()));
                        title
                    }
                    Err(error) => {
                        warn!(%error, thread_id = %row.thread_id, "Live Activity title unavailable");
                        None
                    }
                },
            };
            row.title = marks
                .threads
                .get(&row.thread_id)
                .and_then(|marks| marks.pin_name.as_deref())
                .map(|pinned| text_preview(pinned, MAX_TITLE_CHARS))
                .or(header);
        }
        Ok(content)
    }

    async fn live_activity_title(&self, thread: &str) -> Result<Option<String>> {
        let header = if is_claude_thread_id(thread) {
            let session =
                session_uuid_from_thread_id(thread).context("Claude thread id has no session")?;
            self.claude_history
                .read_thread_header(session.to_owned())
                .await?
        } else {
            self.call_control_with_timeout(
                "thread/read",
                json!({"threadId": thread, "includeTurns": false}),
                TITLE_READ_TIMEOUT,
            )
            .await?["thread"]
                .take()
        };
        Ok(header_title(&header))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conversation_marks::Purpose;

    const BASELINE: i64 = 1_000;

    fn turn(started_at: i64, completed_at: i64) -> FinishedTurn {
        FinishedTurn {
            turn_id: "turn".into(),
            started_at,
            completed_at,
        }
    }

    fn seen(through: i64) -> ThreadMarks {
        ThreadMarks {
            seen_through: Some(through),
            ..ThreadMarks::default()
        }
    }

    fn marks(threads: impl IntoIterator<Item = (&'static str, ThreadMarks)>) -> Marks {
        Marks {
            schema_version: 2,
            revision: 1,
            read_baseline: BASELINE,
            threads: threads
                .into_iter()
                .map(|(thread, marks)| (thread.to_owned(), marks))
                .collect(),
        }
    }

    fn snapshot(
        running: &[&str],
        finished: &[(&str, FinishedTurn)],
    ) -> ActiveTasksLiveActivitySnapshot {
        let mut turns = FinishedTurns::default();
        for (thread, turn) in finished {
            turns.record(thread, turn.clone());
        }
        ActiveTasksLiveActivitySnapshot {
            running: running.iter().map(|thread| (*thread).to_owned()).collect(),
            finished: turns,
        }
    }

    fn rows(content: &LiveActivityContent) -> Vec<(&str, AttentionReason)> {
        content
            .attention
            .iter()
            .map(|row| (row.thread_id.as_str(), row.reason))
            .collect()
    }

    #[test]
    fn a_finished_turn_is_read_once_a_mark_covers_its_completion_or_passes_its_start() {
        let finished = turn(1_100, 1_200);
        assert!(finished.is_unread(None, BASELINE));
        assert!(finished.is_unread(Some(&seen(1_050)), BASELINE));
        assert!(!finished.is_unread(Some(&seen(1_200)), BASELINE));
        assert!(!finished.is_unread(None, 1_200));
        assert!(
            !finished.is_unread(Some(&seen(1_150)), BASELINE),
            "a Claude transcript completion before the gateway's still marks this turn read"
        );
        assert!(
            finished.is_unread(Some(&seen(1_100)), BASELINE),
            "a predecessor that completed in the second this turn started is not this turn"
        );
    }

    #[test]
    fn marked_unread_wins_and_purposed_threads_are_never_unread_on_their_own() {
        let finished = turn(1_100, 1_200);
        let purposed = ThreadMarks {
            purpose: Some(Purpose::Automation),
            ..ThreadMarks::default()
        };
        assert!(!finished.is_unread(Some(&purposed), BASELINE));
        let marked = ThreadMarks {
            marked_unread: true,
            ..seen(1_300)
        };
        assert!(finished.is_unread(Some(&marked), 1_300));
    }

    #[test]
    fn rows_are_unread_finished_roots_that_are_not_running() {
        let snapshot = snapshot(
            &["running", "child"],
            &[
                ("read", turn(1_100, 1_250)),
                ("older", turn(1_100, 1_200)),
                ("newer", turn(1_100, 1_300)),
                ("parent", turn(1_100, 1_400)),
                ("delegated", turn(1_100, 1_500)),
            ],
        );
        let owners = [
            ("child".to_owned(), "parent".to_owned()),
            ("delegated".to_owned(), "older".to_owned()),
        ]
        .into_iter()
        .chain(
            ["running", "read", "older", "newer", "parent", "asking"]
                .map(|thread| (thread.to_owned(), thread.to_owned())),
        )
        .collect::<HashMap<_, _>>();
        let questions = BTreeMap::from([
            ("read".to_owned(), 1_240_000),
            ("asking".to_owned(), 1_260_000),
        ]);
        let content = attention_content(
            &snapshot,
            &marks([("read", seen(1_250))]),
            &questions,
            &owners,
            Some("account"),
        )
        .unwrap();

        assert_eq!(content.active_task_count, 2);
        assert_eq!(content.attention_count, 2);
        assert_eq!(
            rows(&content),
            vec![
                (
                    "newer",
                    AttentionReason::FinishedUnread {
                        completed_at: 1_300
                    }
                ),
                (
                    "older",
                    AttentionReason::FinishedUnread {
                        completed_at: 1_200
                    }
                ),
            ]
        );
        assert!(
            content
                .attention
                .iter()
                .all(|row| row.account_id.as_deref() == Some("account"))
        );
    }

    #[test]
    fn a_question_marks_an_unread_row_only_when_asked_after_the_read_point() {
        let snapshot = snapshot(
            &[],
            &[
                ("fresh", turn(1_100, 1_300)),
                ("same-second", turn(1_100, 1_250)),
                ("stale", turn(1_100, 1_200)),
            ],
        );
        let owners = ["fresh", "same-second", "stale"]
            .map(|thread| (thread.to_owned(), thread.to_owned()))
            .into_iter()
            .collect::<HashMap<_, _>>();
        let questions = BTreeMap::from([
            ("fresh".to_owned(), 1_200_000),
            ("same-second".to_owned(), 1_050_900),
            ("stale".to_owned(), 1_000_000),
        ]);
        let content = attention_content(
            &snapshot,
            &marks([("same-second", seen(1_050)), ("stale", seen(1_050))]),
            &questions,
            &owners,
            None,
        )
        .unwrap();
        assert_eq!(
            rows(&content),
            vec![
                (
                    "fresh",
                    AttentionReason::Question {
                        completed_at: Some(1_300)
                    }
                ),
                (
                    "same-second",
                    AttentionReason::FinishedUnread {
                        completed_at: 1_250
                    }
                ),
                (
                    "stale",
                    AttentionReason::FinishedUnread {
                        completed_at: 1_200
                    }
                ),
            ]
        );
    }

    #[test]
    fn a_question_without_an_unread_finished_turn_is_not_attention() {
        let owners = HashMap::from([("asking".into(), "asking".into())]);
        let content = attention_content(
            &snapshot(&[], &[("asking", turn(1_100, 1_200))]),
            &marks([("asking", seen(1_200))]),
            &BTreeMap::from([("asking".to_owned(), 1_500_000)]),
            &owners,
            None,
        )
        .unwrap();
        assert!(content.is_empty());
    }

    #[test]
    fn unavailable_ancestry_holds_running_and_finished_attention() {
        let content = attention_content(
            &snapshot(
                &["unknown-running"],
                &[("unknown-finished", turn(1_100, 1_300))],
            ),
            &marks([]),
            &BTreeMap::new(),
            &HashMap::new(),
            None,
        )
        .unwrap();
        assert!(content.is_empty());
    }

    #[test]
    fn losing_question_coverage_only_drops_the_question_marker() {
        let snapshot = snapshot(&["working"], &[("both", turn(1_100, 1_300))]);
        let owners = HashMap::from([
            ("both".into(), "both".into()),
            ("working".into(), "working".into()),
        ]);
        let before = attention_content(
            &snapshot,
            &marks([]),
            &BTreeMap::from([("both".to_owned(), 1_200_000)]),
            &owners,
            None,
        )
        .unwrap();
        let after =
            attention_content(&snapshot, &marks([]), &BTreeMap::new(), &owners, None).unwrap();
        assert!(matches!(
            before.attention[0].reason,
            AttentionReason::Question { .. }
        ));
        assert_eq!(after.active_task_count, 1);
        assert_eq!(after.attention_count, before.attention_count);
        assert_eq!(
            rows(&after),
            vec![(
                "both",
                AttentionReason::FinishedUnread {
                    completed_at: 1_300
                }
            )]
        );
    }

    #[tokio::test]
    async fn review_regression_unreadable_finished_state_stays_unavailable_and_untouched() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("finished.json");
        let bytes = b"{unfinished";
        std::fs::write(&path, bytes).unwrap();
        let finished = FinishedTurns::load(&path).await;
        let gateway = crate::test_support::TestGateway::new();
        let snapshot = ActiveTasksLiveActivitySnapshot {
            running: BTreeSet::new(),
            finished,
        };
        assert!(
            gateway
                .live_activity_content(&snapshot, &mut HashMap::new())
                .await
                .is_err()
        );
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
    }

    #[test]
    fn the_oldest_finished_turn_is_evicted_beyond_the_bound() {
        let mut turns = FinishedTurns::default();
        for index in 0..=MAX_FINISHED_TURNS as i64 {
            turns.record(&format!("thread-{index}"), turn(index, 100 - index));
        }
        assert_eq!(turns.known().unwrap().len(), MAX_FINISHED_TURNS);
        assert!(
            !turns
                .known()
                .unwrap()
                .contains_key(&format!("thread-{MAX_FINISHED_TURNS}"))
        );
    }

    #[test]
    fn a_title_prefers_the_name_then_the_first_prompt() {
        assert_eq!(
            header_title(&json!({"name":" Live Activity ","preview":"first"})),
            Some("Live Activity".into())
        );
        assert_eq!(
            header_title(&json!({"name":null,"preview":"first prompt"})),
            Some("first prompt".into())
        );
        assert_eq!(header_title(&json!({"name":"","preview":" "})), None);
    }
}

#[cfg(test)]
mod startup_tests {
    use super::*;

    fn probe_gateway(
        probe: &crate::test_support::LiveActivityProbe,
        settings: crate::providers::claude::settings::ClaudeSettings,
        path: PathBuf,
    ) -> Arc<Gateway> {
        Gateway::construct_with_apns(
            super::super::GatewayConstruction {
                user_name: None,
                codex: Arc::new(crate::providers::codex::daemon::CodexAppServer::new(
                    "/bin/true".into(),
                    HashMap::new(),
                )),
                claude_settings: settings,
                journal: crate::observability::journal::Journal::disabled(),
                turn_state_path: Some(path),
                recovery_path: None,
                call_delivery: None,
                external_auth: None,
                external_providers: None,
            },
            probe.service.clone(),
        )
    }

    #[tokio::test]
    async fn review_followup_settled_claude_recovery_waits_for_ledger_ingress() {
        use crate::providers::claude::{
            ClaudeSupervisor,
            restart::{
                self,
                test_support::{SESSION, StubClaude, THREAD},
            },
        };
        let stub = StubClaude::new();
        let path = stub.turn_state_path();
        restart::Store::beside(&path)
            .write(
                &restart::Journal::capture(
                    None,
                    vec![stub.item(SESSION, restart::ItemStatus::Captured)],
                    None,
                )
                .unwrap(),
            )
            .unwrap();
        let probe = crate::test_support::LiveActivityProbe::new(None).await;
        let gateway = probe_gateway(
            &probe,
            crate::providers::claude::settings::ClaudeSettings {
                enabled: true,
                ..stub.settings.clone()
            },
            path,
        );
        let (sender, notifications) = tokio::sync::mpsc::channel(256);
        let agent = ClaudeSupervisor::new(
            gateway.claude_settings.clone(),
            sender,
            crate::observability::journal::Journal::disabled(),
            crate::agents::mcp::McpTokens::default(),
        );
        gateway.set_claude_agent(agent.clone());
        gateway.mark_listening();
        gateway
            .claude_restart
            .recover(Some(agent.clone()), gateway.listening.subscribe())
            .await;
        assert!(!gateway.claude_restart.has_pending().await.unwrap());
        agent.stop_all().await;
        assert_eq!(agent.active_turn_count().await, 0);
        gateway
            .marks
            .update(
                vec![crate::conversation_marks::Change::MarkUnread {
                    thread_id: THREAD.into(),
                }],
                crate::time::unix_seconds() as i64,
            )
            .await
            .unwrap();
        gateway.spawn_claude_restart_recovery().await;
        let initial = active_tasks_live_activity_snapshot(&*gateway.core.lock().await);
        let unavailable = gateway
            .live_activity_content(&initial, &mut HashMap::new())
            .await
            .is_err();
        let (sender, mut observed) = watch::channel(initial);
        *gateway.apns_live_activity_tx.lock().await = Some(sender);
        gateway.agents.parents.lock().await.insert(
            THREAD.into(),
            super::super::agent_gateway::ParentSnapshot {
                at: std::time::Instant::now(),
                parent: None,
                available: true,
            },
        );
        let owner = gateway.clone();
        let ingress =
            tokio::spawn(async move { owner.claude_notification_loop(notifications).await });
        let resumed = tokio::time::timeout(
            Duration::from_secs(30),
            observed.wait_for(|snapshot| {
                gateway
                    .claude_recovery_ready
                    .load(std::sync::atomic::Ordering::Acquire)
                    && snapshot
                        .finished
                        .known()
                        .is_ok_and(|finished| finished.contains_key(THREAD))
            }),
        )
        .await
        .unwrap()
        .unwrap()
        .clone();
        let content = gateway
            .live_activity_content(&resumed, &mut HashMap::new())
            .await
            .unwrap();
        ingress.abort();
        agent.stop_all().await;
        assert!(unavailable);
        assert_eq!(content.active_task_count, 0);
        assert_eq!(content.attention_count, 1);
    }

    #[tokio::test]
    async fn review_followup_claude_recovery_cannot_end_a_restored_running_activity() {
        use crate::providers::claude::restart::{
            self,
            test_support::{SESSION, StubClaude},
        };
        for unreadable in [false, true] {
            let stub = StubClaude::new();
            let path = stub.turn_state_path();
            let store = restart::Store::beside(&path);
            let journal = restart::Journal::capture(
                None,
                vec![stub.item(SESSION, restart::ItemStatus::Captured)],
                None,
            )
            .unwrap();
            store.write(&journal).unwrap();
            if unreadable {
                std::fs::write(path.with_file_name("claude-restart-recovery.json"), b"{").unwrap();
            }
            let aggregate_path = stub.state.join("live-activity.json");
            {
                let original =
                    crate::test_support::LiveActivityProbe::new(Some(aggregate_path.clone())).await;
                original
                    .service
                    .report_live_activity(
                        "default",
                        LiveActivityContent {
                            active_task_count: 1,
                            ..LiveActivityContent::default()
                        },
                    )
                    .await;
            }
            let probe = crate::test_support::LiveActivityProbe::new(Some(aggregate_path)).await;
            let gateway = probe_gateway(&probe, stub.settings.clone(), path);
            let (sender, receiver) = watch::channel(active_tasks_live_activity_snapshot(
                &*gateway.core.lock().await,
            ));
            let owner = gateway.clone();
            let task =
                tokio::spawn(async move { owner.project_live_activity_loop(receiver).await });
            tokio::time::sleep(Duration::from_millis(650)).await;
            let snapshot = probe.service.live_activity_updates().borrow().clone();
            let requests = probe.requests.lock().unwrap().clone();
            task.abort();
            drop(sender);
            assert!(
                snapshot.is_none(),
                "recovery unreadable={unreadable}: {requests:?}"
            );
            assert!(requests.is_empty(), "pending recovery sent {requests:?}");
        }
    }

    #[tokio::test]
    async fn review_followup_a_new_turn_supersedes_an_empty_projection_waiting_for_ancestry() {
        let settings = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
        let directory = tempfile::tempdir().unwrap();
        let probe = crate::test_support::LiveActivityProbe::new(None).await;
        let gateway = probe_gateway(
            &probe,
            settings.settings.clone(),
            directory.path().join("turn-state.json"),
        );
        probe
            .service
            .report_live_activity(
                "default",
                LiveActivityContent {
                    active_task_count: 1,
                    ..LiveActivityContent::default()
                },
            )
            .await;
        gateway.core.lock().await.finished_turns.record(
            "child",
            FinishedTurn {
                turn_id: "old".into(),
                started_at: 10,
                completed_at: 20,
            },
        );
        gateway.agents.parents.lock().await.insert(
            "root".into(),
            super::super::agent_gateway::ParentSnapshot {
                at: std::time::Instant::now(),
                parent: None,
                available: true,
            },
        );
        let mut control = crate::test_support::FakeControl::attach(&gateway, 32).await;
        let (sender, receiver) = watch::channel(active_tasks_live_activity_snapshot(
            &*gateway.core.lock().await,
        ));
        *gateway.apns_live_activity_tx.lock().await = Some(sender);
        let owner = gateway.clone();
        let task = tokio::spawn(async move { owner.project_live_activity_loop(receiver).await });
        let request: Value = serde_json::from_str(
            &tokio::time::timeout(Duration::from_secs(30), control.requests.recv())
                .await
                .unwrap()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(request["method"], "thread/read");
        gateway.handle_control_text(json!({"method":"turn/started","params":{"threadId":"child","turn":{"id":"new","status":"inProgress"}}}).to_string(), crate::gateway::tests::CONTROL).await;
        gateway.handle_control_text(json!({"id":request["id"],"result":{"thread":{"id":"child","parentThreadId":"root","source":"cli"}}}).to_string(), crate::gateway::tests::CONTROL).await;
        tokio::time::sleep(Duration::from_millis(650)).await;
        let requests = probe.requests.lock().unwrap().clone();
        let snapshot = probe.service.live_activity_updates().borrow().clone();
        task.abort();
        gateway.questions.stop().await;
        assert!(
            requests.iter().all(|request| request["event"] != "end"),
            "{requests:?}"
        );
        assert_eq!(snapshot.unwrap().content.active_task_count, 1);
    }

    #[tokio::test]
    async fn a_previously_valid_host_projection_becomes_unavailable_when_its_source_fails() {
        let gateway = crate::test_support::TestGateway::new();
        gateway
            .apns
            .report_live_activity("default", LiveActivityContent::default())
            .await;
        gateway.core.lock().await.finished_turns = FinishedTurns(None);
        let mut updates = gateway.apns.live_activity_updates();
        gateway.start_live_activity().await;
        let changed = tokio::time::timeout(Duration::from_secs(30), updates.changed()).await;
        let observed = updates.borrow().clone();
        let task = gateway.apns_live_activity_task.lock().await.take();
        if let Some(task) = task {
            task.abort();
        }
        assert!(changed.is_ok());
        assert!(observed.is_none());
    }

    #[tokio::test]
    async fn review_regression_startup_publishes_restored_finished_turns_without_an_event() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("turn-state.json");
        let gateway = crate::test_support::TestGateway::with_codex(
            Arc::new(crate::providers::codex::daemon::CodexAppServer::new(
                "/bin/true".into(),
                HashMap::new(),
            )),
            Some(path.clone()),
        );
        let mut finished = FinishedTurns::default();
        finished.record(
            "root",
            FinishedTurn {
                turn_id: "done".into(),
                started_at: 10,
                completed_at: 20,
            },
        );
        private_state::write_json(&FinishedTurns::path(&path), &finished).unwrap();
        gateway.load_turn_state().await.unwrap();
        gateway
            .marks
            .update(
                vec![crate::conversation_marks::Change::MarkUnread {
                    thread_id: "root".into(),
                }],
                20,
            )
            .await
            .unwrap();
        gateway.agents.parents.lock().await.insert(
            "root".into(),
            super::super::agent_gateway::ParentSnapshot {
                at: std::time::Instant::now(),
                parent: None,
                available: true,
            },
        );
        let mut updates = gateway.apns.live_activity_updates();
        gateway.start_live_activity().await;
        let result = tokio::time::timeout(Duration::from_secs(30), updates.changed()).await;
        let observed = updates.borrow().clone();
        let task = gateway.apns_live_activity_task.lock().await.take();
        if let Some(task) = task {
            task.abort();
        }
        assert!(result.is_ok());
        let observed = observed.unwrap();
        assert_eq!(observed.content.attention_count, 1);
        assert_eq!(observed.content.attention[0].thread_id, "root");
    }
}
