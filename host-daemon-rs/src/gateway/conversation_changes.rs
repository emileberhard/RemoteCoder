use std::collections::HashSet;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use futures_util::future::join_all;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::Gateway;
use super::rpc_methods::decode_params;
use crate::changes::checkouts::{self, Discovery, Evidence, Observations};
use crate::changes::turn::{self, Change, Edit, TurnFile};
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};

const CONVERSATION_PAGES: usize = 10;
const AGENT_PAGES: usize = 5;
const PAGE_ITEMS: usize = 100;
const RECENT_TURNS: usize = 20;
const MAXIMUM_AGENTS: usize = 16;
const CONCURRENT_AGENT_READS: usize = 4;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CheckoutsRequest {
    thread_id: Option<String>,
    directory: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TurnRequest {
    thread_id: String,
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

struct HistoryReader {
    thread: String,
    turn: Option<String>,
    pages: usize,
    cursor: Option<String>,
    activity: Vec<Activity>,
    reached_ms: Option<i64>,
    exhausted: bool,
}

impl HistoryReader {
    fn new(thread: &str, turn: Option<&str>, pages: usize) -> Self {
        Self {
            thread: thread.to_owned(),
            turn: turn.map(str::to_owned),
            pages,
            cursor: None,
            activity: Vec::new(),
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

struct Child {
    last_active_at: Option<i64>,
    history: Option<HistoryReader>,
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
                absolute(Some(request.directory.as_str()))?;
                serde_json::to_value(self.changes.read(request).await?)
            }
            "changes/checkouts" => {
                let request: CheckoutsRequest = decode_params(params)?;
                absolute(request.directory.as_deref())?;
                serde_json::to_value(self.changes.admit(self.checkouts(request)).await?)
            }
            "changes/turn" => {
                let TurnRequest { thread_id } = decode_params(params)?;
                serde_json::to_value(self.changes.admit(self.turn_changes(&thread_id)).await?)
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

    async fn checkouts(&self, request: CheckoutsRequest) -> Result<Discovery> {
        let mut observations = Observations::default();
        let mut complete = true;
        if let Some(thread) = &request.thread_id {
            let (mut children, listed) = self.conversation_agents(thread).await;
            let mut own = HistoryReader::new(thread, None, CONVERSATION_PAGES);
            let (read, ()) = tokio::join!(
                self.read_back(&mut own, None),
                self.read_children(&mut children, None)
            );
            read?;
            complete = listed
                && own.exhausted
                && children.iter().all(|child| {
                    child
                        .history
                        .as_ref()
                        .is_some_and(|history| history.exhausted)
                });
            for activity in own.activity.iter().chain(
                children
                    .iter()
                    .filter_map(|child| child.history.as_ref())
                    .flat_map(|history| &history.activity),
            ) {
                observe(activity, &mut observations);
            }
        }
        let folder = request.directory.map(PathBuf::from);
        Ok(tokio::task::spawn_blocking(move || {
            checkouts::discover(observations, folder.as_deref(), complete)
        })
        .await?)
    }

    async fn turn_changes(&self, thread: &str) -> Result<TurnChanges> {
        let page = self
            .cluster_history_page(
                "thread/turns/list",
                json!({"threadId":thread,"limit":RECENT_TURNS,"sortDirection":"desc","itemsView":"notLoaded"}),
            )
            .await?;
        let turns = page["data"]
            .as_array()
            .context("Missing turn list")?
            .iter()
            .map(|turn| {
                Some(RecentTurn {
                    id: turn["id"].as_str()?.to_owned(),
                    started_at_ms: turn["startedAt"].as_i64()? * 1000,
                    running: turn["status"] == "inProgress",
                })
            })
            .collect::<Option<Vec<_>>>()
            .context("A turn has no id or start time")?;
        if turns.is_empty() {
            return Ok(TurnChanges::NoRecentEdits { complete: true });
        }
        let (mut children, mut complete) = self.conversation_agents(thread).await;
        let mut pages = CONVERSATION_PAGES;
        let mut omitted_agents = 0;
        for (index, turn) in turns.iter().enumerate() {
            let since = Some(turn.started_at_ms);
            let mut own = HistoryReader::new(thread, Some(&turn.id), pages);
            let (read, ()) = tokio::join!(
                self.read_back(&mut own, None),
                self.read_children(&mut children, since)
            );
            read?;
            pages = own.pages;
            complete &= own.exhausted;
            let end_ms = index.checked_sub(1).map(|newer| turns[newer].started_at_ms);
            let window = turn_window(turn.started_at_ms, end_ms, &own.activity, &children);
            complete &= window.complete;
            omitted_agents = window.omitted_agents;
            if window.edits.is_empty() {
                if own.exhausted {
                    continue;
                }
                break;
            }
            let files = turn::turn_files(window.edits).await?;
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
            complete: complete && omitted_agents == 0,
        })
    }

    async fn read_back(&self, reader: &mut HistoryReader, since_ms: Option<i64>) -> Result<()> {
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
                if let Some(at) = at_ms {
                    reader.reached_ms =
                        Some(reader.reached_ms.map_or(at, |reached| reached.min(at)));
                }
                if let Some(kind) = activity_kind(&entry["item"]) {
                    reader.activity.push(Activity { at_ms, kind });
                }
            }
            match page["nextCursor"].as_str() {
                Some(next) => reader.cursor = Some(next.to_owned()),
                None => reader.exhausted = true,
            }
        }
        Ok(())
    }

    async fn read_children(&self, children: &mut [Child], since_ms: Option<i64>) {
        let mut pending: Vec<&mut Child> = children
            .iter_mut()
            .filter(|child| {
                since_ms.is_none_or(|since| active_since(child.last_active_at, since))
                    && child
                        .history
                        .as_ref()
                        .is_some_and(|history| history.wants(since_ms))
            })
            .collect();
        for batch in pending.chunks_mut(CONCURRENT_AGENT_READS) {
            let mut reads = Vec::with_capacity(batch.len());
            for child in batch {
                reads.push(self.read_child(child, since_ms));
            }
            join_all(reads).await;
        }
    }

    async fn read_child(&self, child: &mut Child, since_ms: Option<i64>) {
        let Some(history) = &mut child.history else {
            return;
        };
        if let Err(error) = self.read_back(history, since_ms).await {
            tracing::warn!(thread_id = %history.thread, %error, "child agent history unavailable for change review");
            child.history = None;
        }
    }

    async fn conversation_agents(&self, root: &str) -> (Vec<Child>, bool) {
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

fn absolute(directory: Option<&str>) -> Result<(), RpcError> {
    if directory.is_some_and(|directory| !directory.starts_with('/')) {
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
    children: &[Child],
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
                window.complete &= history.covers(Some(start_ms));
                activity.extend(
                    history
                        .activity
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

fn active_since(last_active_seconds: Option<i64>, since_ms: i64) -> bool {
    last_active_seconds.is_none_or(|seconds| (seconds + 1) * 1000 > since_ms)
}

fn activity_kind(item: &Value) -> Option<ActivityKind> {
    match item["type"].as_str()? {
        "fileChange" => Some(ActivityKind::Edits(turn::recorded_edits(item))),
        "commandExecution" => Some(ActivityKind::Command {
            cwd: item["cwd"]
                .as_str()
                .filter(|cwd| cwd.starts_with('/'))
                .map(str::to_owned),
        }),
        _ => None,
    }
}

fn observe(activity: &Activity, observations: &mut Observations) {
    match &activity.kind {
        ActivityKind::Edits(edits) => {
            for edit in edits {
                let moved = match &edit.change {
                    Change::Update {
                        moved_to: Some(target),
                        ..
                    } => Some(target),
                    _ => None,
                };
                for path in std::iter::once(&edit.path).chain(moved) {
                    if let Some(folder) = Path::new(path).parent() {
                        observations.record(folder.to_path_buf(), Evidence::Edited, activity.at_ms);
                    }
                }
            }
        }
        ActivityKind::Command { cwd: Some(cwd) } => {
            observations.record(PathBuf::from(cwd), Evidence::Command, activity.at_ms);
        }
        ActivityKind::Command { cwd: None } => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edits_and_commands_become_observed_folders() {
        let edit = json!({"type":"fileChange","status":"completed","changes":[
            {"path":"/repo/src/a.rs","kind":{"type":"update","move_path":"/repo/lib/a.rs"},"diff":""}
        ]});
        let command =
            json!({"type":"commandExecution","status":"completed","cwd":"/repo","command":"ls"});
        let mut observations = Observations::default();
        for (item, at) in [(edit, 10), (command, 20)] {
            let kind = activity_kind(&item).unwrap();
            observe(
                &Activity {
                    at_ms: Some(at),
                    kind,
                },
                &mut observations,
            );
        }
        let mut expected = Observations::default();
        expected.record(PathBuf::from("/repo/src"), Evidence::Edited, Some(10));
        expected.record(PathBuf::from("/repo/lib"), Evidence::Edited, Some(10));
        expected.record(PathBuf::from("/repo"), Evidence::Command, Some(20));
        assert_eq!(observations, expected);
        assert!(activity_kind(&json!({"type":"agentMessage"})).is_none());
    }

    #[tokio::test]
    async fn turn_changes_serialize_like_the_shared_fixture() {
        let files = turn::turn_files(vec![
            Edit {
                path: "/nonexistent-fixture/care/src/app.rs".into(),
                change: Change::Update {
                    hunks: "@@ -1,2 +1,2 @@\n let a = 1;\n-let b = 2;\n+let b = 3;\n".into(),
                    moved_to: None,
                },
            },
            Edit {
                path: "/nonexistent-fixture/notes.md".into(),
                change: Change::Add("# Notes\n".into()),
            },
        ])
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
                change: Change::Add(String::new()),
            }])
        };
        let at = |at_ms, kind| Activity {
            at_ms: Some(at_ms),
            kind,
        };
        let child = |last_active_at, activity, reached_ms, exhausted| Child {
            last_active_at,
            history: Some(HistoryReader {
                activity,
                reached_ms: Some(reached_ms),
                exhausted,
                ..HistoryReader::new("child", None, 0)
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
    }

    #[test]
    fn agents_count_as_active_until_their_last_second_ends() {
        assert!(active_since(None, 5_000));
        assert!(active_since(Some(5), 5_999));
        assert!(!active_since(Some(5), 6_000));
    }
}
