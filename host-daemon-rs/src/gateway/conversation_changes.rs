use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use anyhow::{Context, Result};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::Gateway;
use super::rpc_methods::decode_params;
use crate::changes::{Admission, Anchor, Boundary, Source};
use crate::changes::checkouts::{
    self, ChangeSummary, CheckoutSummary, Discovery, Evidence, Observations, SummaryOutcome,
};
use crate::changes::turn::{self, Change, Edit, TurnFile};
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};

const CONVERSATION_PAGES: usize = 10;
const AGENT_PAGES: usize = 5;
const PAGE_ITEMS: usize = 100;
const RECENT_TURNS: usize = 20;
const RANGE_TURNS_PER_PAGE: usize = 100;
const RANGE_TURN_PAGES: usize = 5;
const RANGE_PAGES: usize = 40;
const MAXIMUM_AGENTS: usize = 16;
const CONCURRENT_AGENT_READS: usize = 4;
const MAXIMUM_RECORDED_EDIT_BYTES: usize = 32 * 1024 * 1024;
const SUMMARY_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SummaryRequest {
    thread_id: String,
    directory: String,
    #[serde(default)]
    source: Option<Source>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CheckoutsRequest {
    thread_id: Option<String>,
    directory: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TurnRequest {
    thread_id: String,
    #[serde(default)]
    since: Option<Anchor>,
}

#[derive(Serialize)]
#[serde(
    tag = "status",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum TurnChanges {
    Ready {
        turn: TurnSummary,
        files: Vec<TurnFile>,
        unlisted_files: u64,
        commands: usize,
        omitted_agents: usize,
        complete: bool,
        captured_at_ms: i64,
    },
    NoRecentEdits {
        complete: bool,
    },
}

#[derive(Serialize)]
#[serde(
    tag = "status",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum RangeChanges {
    Ready {
        since: RangeStart,
        turns: usize,
        files: Vec<TurnFile>,
        unlisted_files: u64,
        commands: usize,
        omitted_agents: usize,
        complete: bool,
        captured_at_ms: i64,
    },
    AnchorMissing {
        complete: bool,
    },
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RangeStart {
    turn_id: String,
    boundary: Boundary,
    #[serde(skip_serializing_if = "Option::is_none")]
    at_ms: Option<i64>,
}

struct ListedTurn {
    id: String,
    started_at_ms: Option<i64>,
    completed_at_ms: Option<i64>,
    running: bool,
}

impl ListedTurn {
    fn parse(turn: &Value) -> Result<Self> {
        Ok(Self {
            id: turn["id"].as_str().context("A turn has no id")?.to_owned(),
            started_at_ms: turn["startedAt"].as_i64().map(|seconds| seconds * 1000),
            completed_at_ms: turn["completedAt"].as_i64().map(|seconds| seconds * 1000),
            running: turn["status"] == "inProgress",
        })
    }
}

struct TurnsThrough {
    turns: Vec<ListedTurn>,
    found: bool,
    exhausted: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TurnSummary {
    id: String,
    started_at_ms: i64,
    running: bool,
    latest: bool,
}

struct RecentTurn {
    id: String,
    started_at_ms: i64,
    running: bool,
}

struct Activity {
    at_ms: Option<i64>,
    kind: ActivityKind,
}

enum ActivityKind {
    Edits(Vec<Edit>),
    Command { cwd: Option<String> },
}

trait Collect: Default + Send {
    fn collect(&mut self, at_ms: Option<i64>, item: &Value, budget: &AtomicUsize) -> bool;
}

impl Collect for Vec<Activity> {
    fn collect(&mut self, at_ms: Option<i64>, item: &Value, budget: &AtomicUsize) -> bool {
        let Some(kind) = activity_kind(item) else {
            return true;
        };
        let bytes = match &kind {
            ActivityKind::Edits(edits) => edits.iter().map(Edit::recorded_bytes).sum(),
            ActivityKind::Command { .. } => 0,
        };
        if budget
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |left| {
                left.checked_sub(bytes)
            })
            .is_err()
        {
            return false;
        }
        self.push(Activity { at_ms, kind });
        true
    }
}

impl Collect for Observations {
    fn collect(&mut self, at_ms: Option<i64>, item: &Value, _: &AtomicUsize) -> bool {
        match activity_kind(item) {
            Some(ActivityKind::Edits(edits)) => {
                for edit in edits {
                    let moved = match edit.change {
                        Some(Change::Update {
                            moved_to: Some(target),
                            ..
                        }) => Some(target),
                        _ => None,
                    };
                    for path in std::iter::once(edit.path).chain(moved) {
                        if let Some(folder) = Path::new(&path).parent() {
                            self.record(folder.to_path_buf(), Evidence::Edited, at_ms);
                        }
                    }
                }
            }
            Some(ActivityKind::Command { cwd: Some(cwd) }) => {
                self.record(PathBuf::from(cwd), Evidence::Command, at_ms);
            }
            Some(ActivityKind::Command { cwd: None }) | None => {}
        }
        true
    }
}

struct HistoryReader<C> {
    thread: String,
    turn: Option<String>,
    pages: usize,
    cursor: Option<String>,
    collected: C,
    reached_ms: Option<i64>,
    exhausted: bool,
}

impl<C: Collect> HistoryReader<C> {
    fn new(thread: &str, turn: Option<&str>, pages: usize) -> Self {
        Self {
            thread: thread.to_owned(),
            turn: turn.map(str::to_owned),
            pages,
            cursor: None,
            collected: C::default(),
            reached_ms: None,
            exhausted: false,
        }
    }

    fn covers(&self, since_ms: Option<i64>) -> bool {
        self.exhausted
            || since_ms
                .zip(self.reached_ms)
                .is_some_and(|(since, reached)| reached < since)
    }

    fn wants(&self, since_ms: Option<i64>) -> bool {
        self.pages > 0 && !self.covers(since_ms)
    }
}

struct Child<C> {
    last_active_at: Option<i64>,
    history: Option<HistoryReader<C>>,
}

struct TurnWindow {
    edits: Vec<Edit>,
    commands: usize,
    omitted_agents: usize,
    complete: bool,
}

impl Gateway {
    pub(super) async fn changes_rpc(&self, method: &str, params: Value) -> RpcResult {
        let response = match method {
            "changes/read" => {
                let request: crate::changes::ReadRequest = decode_params(params)?;
                absolute(&request.directory)?;
                serde_json::to_value(self.changes.read(request).await?)
            }
            "changes/checkouts" => {
                let request: CheckoutsRequest = decode_params(params)?;
                absolute(&request.directory)?;
                serde_json::to_value(
                    self.changes
                        .admit(|admission| self.checkouts(request, admission))
                        .await?,
                )
            }
            "changes/summary" => {
                let request: SummaryRequest = decode_params(params)?;
                absolute(&request.directory)?;
                if request.source == Some(Source::Branch) {
                    return Err(RpcError::new(
                        RpcCode::InvalidParams,
                        "Omit source to summarize branch changes",
                    ));
                }
                serde_json::to_value(
                    self.changes
                        .admit(|admission| self.change_summary(request, admission))
                        .await?,
                )
            }
            "changes/turn" => {
                let TurnRequest { thread_id, since } = decode_params(params)?;
                match since {
                    None => serde_json::to_value(
                        self.changes
                            .admit(|admission| self.turn_changes(&thread_id, admission))
                            .await?,
                    ),
                    Some(anchor) => {
                        anchor.validate().map_err(|error| {
                            RpcError::new(RpcCode::InvalidParams, error.to_string())
                        })?;
                        serde_json::to_value(
                            self.changes
                                .admit(|admission| {
                                    self.range_changes(&thread_id, anchor, admission)
                                })
                                .await?,
                        )
                    }
                }
            }
            _ => {
                return Err(RpcError::new(
                    RpcCode::MethodNotFound,
                    "Unknown changes method",
                ));
            }
        };
        Ok(response.context("Could not encode the changes")?)
    }

    async fn change_summary(
        &self,
        request: SummaryRequest,
        admission: Admission,
    ) -> Result<ChangeSummary> {
        let deadline = tokio::time::Instant::now() + SUMMARY_TIMEOUT;
        let source = request.source;
        let discovery = tokio::time::timeout_at(
            deadline,
            self.checkouts(
                CheckoutsRequest {
                    thread_id: Some(request.thread_id),
                    directory: request.directory,
                },
                admission,
            ),
        )
        .await
        .context("Checkout discovery exceeded the summary deadline")??;
        Ok(summarize_checkouts(discovery, source, deadline).await)
    }

    async fn checkouts(
        &self,
        request: CheckoutsRequest,
        admission: Admission,
    ) -> Result<Discovery> {
        let mut observations = Observations::default();
        let mut complete = true;
        if let Some(thread) = &request.thread_id {
            let unlimited = AtomicUsize::new(usize::MAX);
            let mut own = HistoryReader::new(thread, None, CONVERSATION_PAGES);
            let (read, (children, listed)) =
                tokio::join!(self.read_back(&mut own, None, &unlimited), async {
                    let (mut children, listed) =
                        self.conversation_agents::<Observations>(thread).await;
                    self.read_children(&mut children, None, &unlimited).await;
                    (children, listed)
                });
            read?;
            complete = listed
                && own.exhausted
                && children.iter().all(|child| {
                    child
                        .history
                        .as_ref()
                        .is_some_and(|history| history.exhausted)
                });
            observations = own.collected;
            for history in children.into_iter().filter_map(|child| child.history) {
                observations.absorb(history.collected);
            }
        }
        let folder = PathBuf::from(request.directory);
        admission
            .blocking(move || checkouts::discover(observations, &folder, complete))
            .await
    }

    async fn turn_changes(&self, thread: &str, admission: Admission) -> Result<TurnChanges> {
        let (page, (mut children, mut complete)) = tokio::join!(
            self.cluster_history_page(
                "thread/turns/list",
                json!({"threadId":thread,"limit":RECENT_TURNS,"sortDirection":"desc","itemsView":"notLoaded"}),
            ),
            self.conversation_agents::<Vec<Activity>>(thread)
        );
        let page = page?;
        let listed = page["data"].as_array().context("Missing turn list")?;
        let mut turns = Vec::with_capacity(listed.len());
        for turn in listed {
            let Some(started_at) = turn["startedAt"].as_i64() else {
                break;
            };
            turns.push(RecentTurn {
                id: turn["id"].as_str().context("A turn has no id")?.to_owned(),
                started_at_ms: started_at * 1000,
                running: turn["status"] == "inProgress",
            });
        }
        let dated = turns.len() == listed.len();
        let budget = AtomicUsize::new(MAXIMUM_RECORDED_EDIT_BYTES);
        let mut pages = CONVERSATION_PAGES;
        let mut omitted_agents = 0;
        for (index, turn) in turns.iter().enumerate() {
            let since = Some(turn.started_at_ms);
            let mut own = HistoryReader::<Vec<Activity>>::new(thread, Some(&turn.id), pages);
            let (read, ()) = tokio::join!(
                self.read_back(&mut own, None, &budget),
                self.read_children(&mut children, since, &budget)
            );
            read?;
            pages = own.pages;
            complete &= own.exhausted;
            let end_ms = index.checked_sub(1).map(|newer| turns[newer].started_at_ms);
            let window = turn_window(turn.started_at_ms, end_ms, &own.collected, &children);
            complete &= window.complete;
            omitted_agents = window.omitted_agents;
            if window.edits.is_empty() {
                if own.exhausted {
                    continue;
                }
                break;
            }
            let files = turn::turn_files(window.edits, &admission).await?;
            return Ok(TurnChanges::Ready {
                turn: TurnSummary {
                    id: turn.id.clone(),
                    started_at_ms: turn.started_at_ms,
                    running: turn.running,
                    latest: index == 0,
                },
                files: files.files,
                unlisted_files: files.unlisted_files,
                commands: window.commands,
                omitted_agents,
                complete,
                captured_at_ms: crate::time::unix_millis(),
            });
        }
        Ok(TurnChanges::NoRecentEdits {
            complete: dated && (turns.is_empty() || (complete && omitted_agents == 0)),
        })
    }

    async fn range_changes(
        &self,
        thread: &str,
        anchor: Anchor,
        admission: Admission,
    ) -> Result<RangeChanges> {
        let (search, (mut children, listed)) = tokio::join!(
            self.turns_through(thread, &anchor.turn_id),
            self.conversation_agents::<Vec<Activity>>(thread)
        );
        let TurnsThrough {
            turns,
            found,
            exhausted,
        } = search?;
        let Some(range) = found.then(|| range_of(&turns, anchor.boundary)).flatten() else {
            return Ok(RangeChanges::AnchorMissing {
                complete: exhausted,
            });
        };
        let Range {
            start,
            counted,
            start_ms,
            at_ms,
            after_running,
        } = range;
        let budget = AtomicUsize::new(MAXIMUM_RECORDED_EDIT_BYTES);
        let (own, ()) = tokio::join!(self.read_turns(thread, counted, &budget), async {
            if let Some(start_ms) = start_ms {
                self.read_children(&mut children, Some(start_ms), &budget)
                    .await;
            }
        });
        let (own, own_complete) = own?;
        let window = match start_ms {
            Some(start_ms) => turn_window(start_ms, None, &own, &children),
            None => TurnWindow {
                complete: after_running,
                ..turn_window(i64::MAX, None, &own, &[])
            },
        };
        let files = turn::turn_files(window.edits, &admission).await?;
        Ok(RangeChanges::Ready {
            since: RangeStart {
                turn_id: start.id.clone(),
                boundary: anchor.boundary,
                at_ms,
            },
            turns: counted.len(),
            files: files.files,
            unlisted_files: files.unlisted_files,
            commands: window.commands,
            omitted_agents: window.omitted_agents,
            complete: listed && own_complete && window.complete,
            captured_at_ms: crate::time::unix_millis(),
        })
    }

    async fn turns_through(&self, thread: &str, anchor: &str) -> Result<TurnsThrough> {
        let mut turns = Vec::new();
        let mut cursor = None;
        for _ in 0..RANGE_TURN_PAGES {
            let mut params = json!({"threadId":thread,"limit":RANGE_TURNS_PER_PAGE,"sortDirection":"desc","itemsView":"notLoaded"});
            if let Some(cursor) = cursor.take() {
                params["cursor"] = Value::String(cursor);
            }
            let page = self
                .cluster_history_page("thread/turns/list", params)
                .await?;
            for turn in page["data"].as_array().context("Missing turn list")? {
                let turn = ListedTurn::parse(turn)?;
                let found = turn.id == anchor;
                turns.push(turn);
                if found {
                    return Ok(TurnsThrough {
                        turns,
                        found: true,
                        exhausted: true,
                    });
                }
            }
            match page["nextCursor"].as_str() {
                Some(next) => cursor = Some(next.to_owned()),
                None => {
                    return Ok(TurnsThrough {
                        turns,
                        found: false,
                        exhausted: true,
                    });
                }
            }
        }
        Ok(TurnsThrough {
            turns,
            found: false,
            exhausted: false,
        })
    }

    async fn read_turns(
        &self,
        thread: &str,
        turns: &[ListedTurn],
        budget: &AtomicUsize,
    ) -> Result<(Vec<Activity>, bool)> {
        let mut activity = Vec::new();
        let mut pages = RANGE_PAGES;
        for turn in turns {
            let mut reader = HistoryReader::<Vec<Activity>>::new(thread, Some(&turn.id), pages);
            self.read_back(&mut reader, None, budget).await?;
            pages = reader.pages;
            activity.extend(reader.collected);
            if !reader.exhausted {
                return Ok((activity, false));
            }
        }
        Ok((activity, true))
    }

    async fn read_back<C: Collect>(
        &self,
        reader: &mut HistoryReader<C>,
        since_ms: Option<i64>,
        budget: &AtomicUsize,
    ) -> Result<()> {
        while reader.wants(since_ms) {
            reader.pages -= 1;
            let mut params =
                json!({"threadId":reader.thread,"limit":PAGE_ITEMS,"sortDirection":"desc"});
            if let Some(turn) = &reader.turn {
                params["turnId"] = json!(turn);
            }
            if let Some(cursor) = reader.cursor.take() {
                params["cursor"] = Value::String(cursor);
            }
            let page = self
                .cluster_history_page("thread/items/list", params)
                .await?;
            for entry in page["data"].as_array().context("Missing item list")? {
                let at_ms = entry["startedAtMs"].as_i64();
                if !reader.collected.collect(at_ms, &entry["item"], budget) {
                    reader.pages = 0;
                    return Ok(());
                }
                if let Some(at) = at_ms {
                    reader.reached_ms =
                        Some(reader.reached_ms.map_or(at, |reached| reached.min(at)));
                }
            }
            match page["nextCursor"].as_str() {
                Some(next) => reader.cursor = Some(next.to_owned()),
                None => reader.exhausted = true,
            }
        }
        Ok(())
    }

    async fn read_children<C: Collect>(
        &self,
        children: &mut [Child<C>],
        since_ms: Option<i64>,
        budget: &AtomicUsize,
    ) {
        futures_util::stream::iter(children.iter_mut().filter(|child| {
            since_ms.is_none_or(|since| active_since(child.last_active_at, since))
                && child
                    .history
                    .as_ref()
                    .is_some_and(|history| history.wants(since_ms))
        }))
        .for_each_concurrent(CONCURRENT_AGENT_READS, |child| {
            self.read_child(child, since_ms, budget)
        })
        .await;
    }

    async fn read_child<C: Collect>(
        &self,
        child: &mut Child<C>,
        since_ms: Option<i64>,
        budget: &AtomicUsize,
    ) {
        let Some(history) = &mut child.history else {
            return;
        };
        if let Err(error) = self.read_back(history, since_ms, budget).await {
            tracing::warn!(thread_id = %history.thread, %error, "child agent history unavailable for change review");
            child.history = None;
        }
    }

    async fn conversation_agents<C: Collect>(&self, root: &str) -> (Vec<Child<C>>, bool) {
        let (Ok(identity), Ok(listed)) = (
            self.host_identity().await,
            self.agent_service().list_agents(root).await,
        ) else {
            return (Vec::new(), false);
        };
        let Ok(mut agents) =
            serde_json::from_value::<Vec<crate::agents::Agent>>(listed["agents"].clone())
        else {
            return (Vec::new(), false);
        };
        agents.sort_by_key(|agent| std::cmp::Reverse(agent.last_active_at));
        let mut threads = HashSet::from([root.to_owned()]);
        let mut readable = 0;
        let mut children = Vec::new();
        for agent in agents {
            if let Some(thread) = &agent.thread_id
                && !threads.insert(thread.clone())
            {
                continue;
            }
            let history = agent
                .thread_id
                .filter(|_| agent.owner_host_id == identity.host_id && readable < MAXIMUM_AGENTS)
                .map(|thread| {
                    readable += 1;
                    HistoryReader::new(&thread, None, AGENT_PAGES)
                });
            children.push(Child {
                last_active_at: agent.last_active_at,
                history,
            });
        }
        (
            children,
            listed["warnings"].as_array().is_none_or(Vec::is_empty),
        )
    }
}

fn absolute(directory: &str) -> Result<(), RpcError> {
    if !directory.starts_with('/') {
        return Err(RpcError::new(
            RpcCode::InvalidParams,
            "directory must be an absolute path",
        ));
    }
    Ok(())
}

fn turn_window(
    start_ms: i64,
    end_ms: Option<i64>,
    own: &[Activity],
    children: &[Child<Vec<Activity>>],
) -> TurnWindow {
    let inside =
        |at: Option<i64>| at.is_some_and(|at| at >= start_ms && end_ms.is_none_or(|end| at < end));
    let mut window = TurnWindow {
        edits: Vec::new(),
        commands: 0,
        omitted_agents: 0,
        complete: true,
    };
    let mut activity: Vec<&Activity> = own.iter().rev().collect();
    for child in children
        .iter()
        .filter(|child| active_since(child.last_active_at, start_ms))
    {
        match &child.history {
            Some(history) => {
                let unplaced = history.collected.iter().any(|activity| {
                    activity.at_ms.is_none()
                        && matches!(&activity.kind, ActivityKind::Edits(edits) if !edits.is_empty())
                });
                window.complete &= history.covers(Some(start_ms)) && !unplaced;
                activity.extend(
                    history
                        .collected
                        .iter()
                        .rev()
                        .filter(|activity| inside(activity.at_ms)),
                );
            }
            None => window.omitted_agents += 1,
        }
    }
    let mut edits = Vec::new();
    for activity in activity {
        match &activity.kind {
            ActivityKind::Edits(recorded) => edits.extend(
                recorded
                    .iter()
                    .map(|edit| (activity.at_ms.unwrap_or(start_ms), edit.clone())),
            ),
            ActivityKind::Command { .. } => window.commands += 1,
        }
    }
    edits.sort_by_key(|(at, _)| *at);
    window.edits = edits.into_iter().map(|(_, edit)| edit).collect();
    window
}

struct Range<'a> {
    start: &'a ListedTurn,
    counted: &'a [ListedTurn],
    start_ms: Option<i64>,
    at_ms: Option<i64>,
    after_running: bool,
}

fn range_of(newest_through_anchor: &[ListedTurn], boundary: Boundary) -> Option<Range<'_>> {
    let (start, newer) = newest_through_anchor.split_last()?;
    Some(match boundary {
        Boundary::Start => Range {
            start,
            counted: newest_through_anchor,
            start_ms: start.started_at_ms,
            at_ms: start.started_at_ms,
            after_running: false,
        },
        Boundary::End => Range {
            start,
            counted: newer,
            start_ms: start
                .completed_at_ms
                .map(|completed| completed + 1000)
                .or_else(|| newer.last().and_then(|next| next.started_at_ms)),
            at_ms: start.completed_at_ms,
            after_running: start.running,
        },
    })
}

fn active_since(last_active_seconds: Option<i64>, since_ms: i64) -> bool {
    last_active_seconds.is_none_or(|seconds| (seconds + 1) * 1000 > since_ms)
}

fn activity_kind(item: &Value) -> Option<ActivityKind> {
    static HOME: OnceLock<PathBuf> = OnceLock::new();
    match item["type"].as_str()? {
        "fileChange" => Some(ActivityKind::Edits(turn::recorded_edits(item))),
        "commandExecution" => Some(ActivityKind::Command {
            cwd: item["command"]
                .as_str()
                .and_then(|command| {
                    checkouts::command_directory(
                        command,
                        HOME.get_or_init(|| {
                            PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                        }),
                    )
                    .filter(|path| path.is_absolute())
                    .map(|path| path.to_string_lossy().into_owned())
                })
                .or_else(|| {
                    item["cwd"]
                        .as_str()
                        .filter(|cwd| cwd.starts_with('/'))
                        .map(str::to_owned)
                }),
        }),
        _ => None,
    }
}

async fn summarize_checkouts(
    discovery: Discovery,
    source: Option<Source>,
    deadline: tokio::time::Instant,
) -> ChangeSummary {
    let mut worked_in = Vec::with_capacity(discovery.worked_in.len());
    for checkout in discovery.worked_in {
        let outcome = if tokio::time::Instant::now() >= deadline {
            SummaryOutcome::Failed
        } else {
            match tokio::time::timeout_at(
                deadline,
                crate::changes::summary(Path::new(&checkout.root), source),
            )
            .await
            {
                Ok(Ok(crate::changes::ChangeRead::Ready { snapshot })) => {
                    SummaryOutcome::Ready { snapshot }
                }
                Ok(Ok(crate::changes::ChangeRead::Unavailable { reason })) => {
                    SummaryOutcome::Unavailable { reason }
                }
                Ok(Err(error)) => {
                    tracing::warn!(root = %checkout.root, %error, "checkout changes summary failed");
                    SummaryOutcome::Failed
                }
                Err(_) => {
                    tracing::warn!(root = %checkout.root, "checkout changes summary deadline exceeded");
                    SummaryOutcome::Failed
                }
            }
        };
        worked_in.push(CheckoutSummary {
            root: checkout.root,
            evidence: checkout.evidence,
            outcome,
        });
    }
    ChangeSummary {
        worked_in,
        in_folder: discovery.in_folder,
        complete: discovery.complete,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn summary_keeps_other_checkouts_when_one_fails_and_bounds_unfinished_reads() {
        let temporary = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(temporary.path()).unwrap();
        let ready = root.join("ready");
        let broken = root.join("broken");
        for path in [&ready, &broken] {
            std::fs::create_dir(path).unwrap();
            assert!(
                std::process::Command::new("git")
                    .args(["init", "-q"])
                    .arg(path)
                    .status()
                    .unwrap()
                    .success()
            );
        }
        std::fs::write(ready.join("new.txt"), "new\n").unwrap();
        std::fs::write(broken.join(".git/config"), "[invalid\n").unwrap();
        let discovery = || Discovery {
            worked_in: [&ready, &broken, &root.join("missing")]
                .map(|path| checkouts::Checkout {
                    root: path.to_string_lossy().into_owned(),
                    evidence: std::collections::BTreeSet::from([Evidence::Command]),
                })
                .into(),
            in_folder: Vec::new(),
            complete: true,
        };
        let summary = summarize_checkouts(
            discovery(),
            None,
            tokio::time::Instant::now() + SUMMARY_TIMEOUT,
        )
        .await;
        assert!(
            matches!(&summary.worked_in[0].outcome, SummaryOutcome::Ready { snapshot } if snapshot.files.len() == 1)
        );
        assert!(matches!(
            summary.worked_in[1].outcome,
            SummaryOutcome::Failed
        ));
        assert!(matches!(
            summary.worked_in[2].outcome,
            SummaryOutcome::Unavailable {
                reason: crate::changes::Unavailability::MissingDirectory
            }
        ));
        let expired = summarize_checkouts(
            discovery(),
            None,
            tokio::time::Instant::now() - Duration::from_secs(1),
        )
        .await;
        assert!(
            expired
                .worked_in
                .iter()
                .all(|checkout| matches!(checkout.outcome, SummaryOutcome::Failed))
        );
    }

    #[test]
    fn summary_requires_a_thread_directory_and_no_extra_fields() {
        for params in [
            json!({"directory":"/repo"}),
            json!({"threadId":"t"}),
            json!({"threadId":"t","directory":"/repo","since":"now"}),
            json!({"threadId":"t","directory":"/repo","source":"everything"}),
        ] {
            assert!(decode_params::<SummaryRequest>(params).is_err());
        }
        let staged: SummaryRequest =
            decode_params(json!({"threadId":"t","directory":"/repo","source":"staged"})).unwrap();
        assert_eq!(staged.source, Some(Source::Staged));
        assert!(absolute("relative").is_err());
    }

    #[test]
    fn a_turn_request_takes_an_optional_turn_boundary() {
        let request: TurnRequest = decode_params(json!({"threadId":"t"})).unwrap();
        assert!(request.since.is_none());
        let request: TurnRequest =
            decode_params(json!({"threadId":"t","since":{"turnId":"turn-1","boundary":"end"}}))
                .unwrap();
        assert_eq!(
            request.since,
            Some(Anchor {
                turn_id: "turn-1".into(),
                boundary: Boundary::End
            })
        );
        for params in [
            json!({"threadId":"t","since":{"turnId":"turn-1","boundary":"middle"}}),
            json!({"threadId":"t","since":{"turnId":"turn-1"}}),
            json!({"threadId":"t","since":{"turnId":"turn-1","boundary":"start","at":1}}),
        ] {
            assert!(decode_params::<TurnRequest>(params).is_err());
        }
        for turn_id in ["", " turn", &"t".repeat(513)] {
            let anchor = Anchor {
                turn_id: turn_id.into(),
                boundary: Boundary::Start,
            };
            assert!(anchor.validate().is_err());
        }
    }

    #[test]
    fn a_range_counts_the_anchor_turn_only_from_its_start() {
        let turn = |id: &str, started, completed, running| ListedTurn {
            id: id.into(),
            started_at_ms: Some(started),
            completed_at_ms: completed,
            running,
        };
        let turns = [
            turn("newest", 30_000, Some(35_000), false),
            turn("middle", 20_000, Some(25_000), false),
            turn("anchor", 10_000, Some(15_000), false),
        ];
        let ids = |range: &Range<'_>| range.counted.iter().map(|turn| turn.id.clone()).collect::<Vec<_>>();

        let start = range_of(&turns, Boundary::Start).unwrap();
        assert_eq!(ids(&start), ["newest", "middle", "anchor"]);
        assert_eq!((start.start_ms, start.at_ms), (Some(10_000), Some(10_000)));

        let end = range_of(&turns, Boundary::End).unwrap();
        assert_eq!(end.start.id, "anchor");
        assert_eq!(ids(&end), ["newest", "middle"]);
        assert_eq!((end.start_ms, end.at_ms), (Some(16_000), Some(15_000)));
        assert!(!end.after_running);

        let running = [turn("anchor", 10_000, None, true)];
        let end = range_of(&running, Boundary::End).unwrap();
        assert!(end.counted.is_empty() && end.after_running);
        assert_eq!((end.start_ms, end.at_ms), (None, None));

        let unfinished = [
            turn("newest", 30_000, None, true),
            turn("anchor", 10_000, None, false),
        ];
        let end = range_of(&unfinished, Boundary::End).unwrap();
        assert_eq!(end.start_ms, Some(30_000));
        assert!(range_of(&[], Boundary::Start).is_none());
    }

    #[tokio::test]
    async fn range_changes_serialize_like_the_shared_fixture() {
        let edits = vec![
            Edit {
                path: "/nonexistent-fixture/care/src/app.rs".into(),
                change: Some(Change::Update {
                    hunks: "@@ -1,2 +1,2 @@\n let a = 1;\n-let b = 2;\n+let b = 3;\n".into(),
                    moved_to: None,
                }),
            },
            Edit {
                path: "/nonexistent-fixture/notes.md".into(),
                change: Some(Change::Add("# Notes\n".into())),
            },
        ];
        let files = crate::changes::ChangeReader::default()
            .admit(|admission| async move { turn::turn_files(edits, &admission).await })
            .await
            .unwrap();
        let ready = RangeChanges::Ready {
            since: RangeStart {
                turn_id: "turn-3".into(),
                boundary: Boundary::End,
                at_ms: Some(1_793_636_561_000),
            },
            turns: 2,
            files: files.files,
            unlisted_files: files.unlisted_files,
            commands: 3,
            omitted_agents: 1,
            complete: false,
            captured_at_ms: 1_793_636_914_000,
        };
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../protocol-fixtures/changes/range-ready.json"
        ))
        .unwrap();
        assert_eq!(serde_json::to_value(ready).unwrap(), fixture);
        assert_eq!(
            serde_json::to_value(RangeChanges::AnchorMissing { complete: true }).unwrap(),
            json!({"status":"anchorMissing","complete":true})
        );
    }

    #[test]
    fn edits_and_commands_become_observed_folders() {
        let edit = json!({"type":"fileChange","status":"completed","changes":[
            {"path":"/repo/src/a.rs","kind":{"type":"update","move_path":"/repo/lib/a.rs"},"diff":""}
        ]});
        let command =
            json!({"type":"commandExecution","status":"completed","cwd":"/repo","command":"ls"});
        let mut observations = Observations::default();
        let empty = AtomicUsize::new(0);
        let cd = json!({"type":"commandExecution","status":"completed","cwd":"/repo","command":"cd /other/./src && x"});
        for (item, at) in [(edit, 10), (command, 20), (cd, 30)] {
            assert!(observations.collect(Some(at), &item, &empty));
        }
        let mut expected = Observations::default();
        expected.record(PathBuf::from("/repo/src"), Evidence::Edited, Some(10));
        expected.record(PathBuf::from("/repo/lib"), Evidence::Edited, Some(10));
        expected.record(PathBuf::from("/repo"), Evidence::Command, Some(20));
        expected.record(PathBuf::from("/other/src"), Evidence::Command, Some(30));
        assert_eq!(observations, expected);
        assert!(activity_kind(&json!({"type":"agentMessage"})).is_none());
    }

    #[tokio::test]
    async fn turn_changes_serialize_like_the_shared_fixture() {
        let edits = vec![
            Edit {
                path: "/nonexistent-fixture/care/src/app.rs".into(),
                change: Some(Change::Update {
                    hunks: "@@ -1,2 +1,2 @@\n let a = 1;\n-let b = 2;\n+let b = 3;\n".into(),
                    moved_to: None,
                }),
            },
            Edit {
                path: "/nonexistent-fixture/notes.md".into(),
                change: Some(Change::Add("# Notes\n".into())),
            },
        ];
        let files = crate::changes::ChangeReader::default()
            .admit(|admission| async move { turn::turn_files(edits, &admission).await })
            .await
            .unwrap();
        let ready = TurnChanges::Ready {
            turn: TurnSummary {
                id: "turn-1".into(),
                started_at_ms: 1_793_636_561_000,
                running: false,
                latest: true,
            },
            files: files.files,
            unlisted_files: files.unlisted_files,
            commands: 3,
            omitted_agents: 1,
            complete: false,
            captured_at_ms: 1_793_636_914_000,
        };
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../protocol-fixtures/changes/turn-ready.json"
        ))
        .unwrap();
        assert_eq!(serde_json::to_value(ready).unwrap(), fixture);
    }

    #[test]
    fn a_turn_window_holds_its_own_items_and_child_edits_inside_it() {
        let edit = |path: &str| {
            ActivityKind::Edits(vec![Edit {
                path: path.into(),
                change: Some(Change::Add(String::new())),
            }])
        };
        let at = |at_ms, kind| Activity {
            at_ms: Some(at_ms),
            kind,
        };
        let child = |last_active_at, collected, reached_ms, exhausted| Child {
            last_active_at,
            history: Some(HistoryReader {
                collected,
                reached_ms: Some(reached_ms),
                exhausted,
                ..HistoryReader::<Vec<Activity>>::new("child", None, 0)
            }),
        };
        let own = vec![at(10_500, ActivityKind::Command { cwd: None })];
        let children = vec![
            child(
                Some(30),
                vec![
                    at(25_000, edit("/newer")),
                    at(12_000, edit("/b")),
                    at(11_000, edit("/a")),
                    at(9_000, edit("/older")),
                ],
                9_000,
                false,
            ),
            Child {
                last_active_at: None,
                history: None,
            },
            child(Some(5), vec![at(4_000, edit("/inactive"))], 4_000, true),
            child(Some(30), Vec::new(), 15_000, false),
        ];

        let window = turn_window(10_000, Some(20_000), &own, &children);

        let paths: Vec<_> = window.edits.iter().map(|edit| edit.path.as_str()).collect();
        assert_eq!(paths, ["/a", "/b"]);
        assert_eq!(
            (window.commands, window.omitted_agents, window.complete),
            (1, 1, false)
        );
        assert!(turn_window(10_000, Some(20_000), &own, &children[..3]).complete);

        let untimed = [child(
            Some(30),
            vec![Activity {
                at_ms: None,
                kind: edit("/untimed"),
            }],
            9_000,
            true,
        )];
        let window = turn_window(10_000, Some(20_000), &own, &untimed);
        assert!(window.edits.is_empty());
        assert!(
            !window.complete,
            "an edit without a time may belong to the turn"
        );
    }

    #[test]
    fn edits_beyond_the_budget_are_not_kept() {
        let edit = |path: &str| {
            json!({"type":"fileChange","status":"completed","changes":[
                {"path":path,"kind":{"type":"add"},"diff":"0123456789"}
            ]})
        };
        let budget = AtomicUsize::new(25);
        let mut activity = Vec::<Activity>::new();

        assert!(activity.collect(Some(1), &edit("/a"), &budget));
        assert!(activity.collect(Some(2), &edit("/b"), &budget));
        assert!(!activity.collect(Some(3), &edit("/c"), &budget));

        assert_eq!(activity.len(), 2);
        assert_eq!(budget.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn agents_count_as_active_until_their_last_second_ends() {
        assert!(active_since(None, 5_000));
        assert!(active_since(Some(5), 5_999));
        assert!(!active_since(Some(5), 6_000));
    }
}
