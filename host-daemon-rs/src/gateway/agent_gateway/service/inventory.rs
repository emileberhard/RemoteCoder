use super::super::{InventoryCoverage, LAUNCHER_PAGING_WARNING};
use super::{AgentService, LauncherInventory};
use crate::agents::launcher;
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{Semaphore, watch};
use tokio::time::Instant;

use super::super::LauncherPurpose;

pub(super) const INVENTORY_BUDGET: Duration = Duration::from_secs(1);
const FAILURE_RETRY: Duration = Duration::from_secs(2);
const PENDING_SELECTION_LIMIT: usize = 32;
const CALLER_LIMIT: usize = 32;
const WAITER_LIMIT: usize = 64;
const CACHE_LIMIT: usize = 16;

type Outcome = std::result::Result<Arc<LauncherInventory>, Arc<str>>;
type Pending = Arc<watch::Sender<Option<Outcome>>>;

#[derive(Clone, PartialEq, Eq, Hash)]
struct Selection {
    homes: Vec<PathBuf>,
    ancestors: bool,
    ids: Vec<String>,
}

struct Snapshot {
    selection: Selection,
    at: Instant,
    outcome: Outcome,
}

#[derive(Default)]
struct State {
    cache: VecDeque<Snapshot>,
    pending: HashMap<(u64, Selection), Pending>,
    generation: u64,
}

pub(in crate::gateway::agent_gateway) struct LauncherReads {
    state: Mutex<State>,
    tasks: crate::tasks::owned_tasks::OwnedTasks,
    inventory: LauncherPool,
    classification: LauncherPool,
    mutations: LauncherPool,
}

struct LauncherPool {
    processes: Semaphore,
    callers: Semaphore,
}

impl LauncherPool {
    fn new(processes: usize) -> Self {
        Self {
            processes: Semaphore::new(processes),
            callers: Semaphore::new(CALLER_LIMIT),
        }
    }
}

impl Default for LauncherReads {
    fn default() -> Self {
        Self {
            state: Mutex::new(State::default()),
            tasks: crate::tasks::owned_tasks::OwnedTasks::default(),
            inventory: LauncherPool::new(2),
            classification: LauncherPool::new(1),
            mutations: LauncherPool::new(2),
        }
    }
}

struct InFlight {
    owner: Arc<LauncherReads>,
    selection: Selection,
    pending: Pending,
    generation: u64,
    completed: bool,
}

enum Claim {
    Cached(Outcome),
    Waiting(watch::Receiver<Option<Outcome>>),
    Owned(InFlight),
}

impl LauncherReads {
    async fn read_launcher_inventory(
        &self,
        selection: &Value,
        homes: &[PathBuf],
        program: &Path,
    ) -> Result<LauncherInventory> {
        let operation = if selection.get("threadIds").is_some() {
            "classify"
        } else {
            "list"
        };
        let mut rows = Vec::new();
        let mut warnings = Vec::new();
        let mut cursor: Option<String> = None;
        let mut bytes = 0;
        for _ in 0..50 {
            let response = self.call(LauncherPurpose::Inventory,
                json!({"operation":operation, "homes":homes, "limit":200, "cursor":cursor,"threadIds":selection.get("threadIds"),"ancestorThreadIds":selection.get("ancestorThreadIds")}),
                program,
            ).await?;
            bytes += crate::wire::json::encoded_len(&response)?;
            ensure!(
                bytes <= 2 * 1024 * 1024,
                "Launcher inventory exceeds byte limit"
            );
            let page: launcher::Page = serde_json::from_value(response)?;
            ensure!(page.schema_version == 1, "Unsupported launcher protocol");
            rows.extend(page.data);
            warnings.extend(page.warnings);
            if page.next_cursor.is_none() {
                cursor = None;
                break;
            }
            ensure!(
                page.next_cursor != cursor,
                "Launcher pagination did not advance"
            );
            cursor = page.next_cursor;
        }
        let paged_out = cursor.is_some();
        if paged_out {
            warnings.push(LAUNCHER_PAGING_WARNING.into());
        }
        warnings.sort();
        warnings.dedup();
        Ok(LauncherInventory {
            coverage: InventoryCoverage::read(paged_out, &warnings),
            runs: rows,
            warnings,
        })
    }

    pub(in crate::gateway::agent_gateway) fn invalidate(&self) {
        let mut state = self.state.lock().expect("Launcher inventory poisoned");
        state.cache.clear();
        state.generation = state.generation.wrapping_add(1);
    }

    pub(in crate::gateway::agent_gateway) async fn call(
        &self,
        purpose: LauncherPurpose,
        request: Value,
        program: &Path,
    ) -> Result<Value> {
        let pool = match purpose {
            LauncherPurpose::Inventory => &self.inventory,
            LauncherPurpose::Classification => &self.classification,
            LauncherPurpose::Mutation => &self.mutations,
        };
        let _caller = pool
            .callers
            .try_acquire()
            .context("Launcher pending reads reached their limit")?;
        let wait = Duration::from_secs(if purpose == LauncherPurpose::Mutation {
            65
        } else {
            5
        });
        tokio::time::timeout(wait, async {
            let _permit = pool
                .processes
                .acquire()
                .await
                .context("Launcher process owner stopped")?;
            launcher::call_program(request, program).await
        })
        .await
        .context("Launcher queue and operation timed out")?
    }

    pub(in crate::gateway::agent_gateway) async fn stop(&self) {
        self.tasks.stop().await;
    }

    pub(super) async fn inventory(
        self: &Arc<Self>,
        service: &AgentService<'_>,
        selection: Value,
        homes: Vec<PathBuf>,
    ) -> Result<Arc<LauncherInventory>> {
        let ancestors = selection.get("ancestorThreadIds").is_some();
        let mut ids: Vec<String> = serde_json::from_value(
            selection[if ancestors {
                "ancestorThreadIds"
            } else {
                "threadIds"
            }]
            .clone(),
        )?;
        ensure!(ids.len() <= 512, "Launcher selection exceeds its limit");
        for id in &ids {
            crate::questions::validate_id(id)?;
        }
        ids.sort();
        ids.dedup();
        let selection = Selection {
            homes,
            ancestors,
            ids,
        };
        let program = service.gateway.agent_launcher_program()?;
        let mut pending = match self.claim(selection.clone())? {
            Claim::Cached(outcome) => {
                return outcome.map_err(|error| anyhow::anyhow!(error.to_string()));
            }
            Claim::Waiting(pending) => pending,
            Claim::Owned(mut owned) => {
                let receiver = owned.pending.subscribe();
                let owner = Arc::clone(self);
                let admitted = self.tasks.spawn("launcher_inventory", async move {
                    let selector = if selection.ancestors {
                        json!({"ancestorThreadIds": selection.ids})
                    } else {
                        json!({"threadIds": selection.ids})
                    };
                    let result = tokio::time::timeout(
                        INVENTORY_BUDGET,
                        owner.read_launcher_inventory(&selector, &selection.homes, &program),
                    )
                    .await
                    .context("Launcher inventory deadline exceeded")
                    .and_then(|result| result);
                    owned.complete(
                        result
                            .map(Arc::new)
                            .map_err(|error| Arc::<str>::from(format!("{error:#}"))),
                    );
                    Ok(())
                });
                ensure!(admitted, "Launcher inventory owner stopped");
                receiver
            }
        };
        tokio::time::timeout(INVENTORY_BUDGET, async {
            loop {
                let outcome = pending.borrow_and_update().clone();
                if let Some(outcome) = outcome {
                    break outcome.map_err(|error| anyhow::anyhow!(error.to_string()));
                }
                pending
                    .changed()
                    .await
                    .context("Launcher inventory ended without a result")?;
            }
        })
        .await
        .context("Launcher inventory wait deadline exceeded")?
    }

    fn claim(self: &Arc<Self>, selection: Selection) -> Result<Claim> {
        let mut state = self.state.lock().expect("Launcher inventory poisoned");
        if let Some(snapshot) = state
            .cache
            .iter()
            .find(|entry| entry.selection == selection)
        {
            let ttl = if snapshot.outcome.is_err() {
                FAILURE_RETRY
            } else if selection.ancestors {
                Duration::from_secs(9)
            } else {
                Duration::from_secs(5)
            };
            if snapshot.at.elapsed() < ttl {
                return Ok(Claim::Cached(snapshot.outcome.clone()));
            }
        }
        let key = (state.generation, selection.clone());
        if let Some(pending) = state.pending.get(&key) {
            ensure!(
                pending.receiver_count() < WAITER_LIMIT,
                "Launcher inventory has too many waiting readers"
            );
            return Ok(Claim::Waiting(pending.subscribe()));
        }
        ensure!(
            state.pending.len() < PENDING_SELECTION_LIMIT,
            "Launcher pending selections reached their limit"
        );
        let (sender, _) = watch::channel(None);
        let pending = Arc::new(sender);
        state.pending.insert(key, pending.clone());
        Ok(Claim::Owned(InFlight {
            owner: Arc::clone(self),
            selection,
            pending,
            generation: state.generation,
            completed: false,
        }))
    }
}

impl InFlight {
    fn complete(&mut self, outcome: Outcome) {
        let mut state = self
            .owner
            .state
            .lock()
            .expect("Launcher inventory poisoned");
        let key = (self.generation, self.selection.clone());
        let current = state
            .pending
            .get(&key)
            .is_some_and(|pending| Arc::ptr_eq(pending, &self.pending));
        if current {
            state.pending.remove(&key);
        }
        if current && state.generation == self.generation {
            state
                .cache
                .retain(|entry| entry.selection != self.selection);
            if state.cache.len() >= CACHE_LIMIT {
                state.cache.pop_front();
            }
            state.cache.push_back(Snapshot {
                selection: self.selection.clone(),
                at: Instant::now(),
                outcome: outcome.clone(),
            });
        }
        self.completed = true;
        drop(state);
        self.pending.send_replace(Some(outcome));
    }
}

impl Drop for InFlight {
    fn drop(&mut self) {
        if !self.completed {
            self.complete(Err(Arc::from("Launcher inventory cancelled")));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TestGateway;
    use std::os::unix::fs::PermissionsExt;

    struct Fixture {
        directory: tempfile::TempDir,
        gateway: TestGateway,
    }

    impl Fixture {
        fn new(mode: &str) -> Self {
            let directory = tempfile::tempdir().unwrap();
            let gateway = TestGateway::new();
            let program = directory.path().join("launcher");
            std::fs::write(directory.path().join("mode"), mode).unwrap();
            std::fs::write(
                &program,
                r#"#!/usr/bin/python3
import fcntl,json,pathlib,sys,time,os
root=pathlib.Path(__file__).parent
request=json.load(sys.stdin)
with (root/'calls').open('a') as log:
    fcntl.flock(log,fcntl.LOCK_EX)
    log.write(json.dumps(request)+'\n')
mode=(root/'mode').read_text()
if mode=='hold':
    (root/('started-'+str(os.getpid()))).touch()
    while not (root/'release').exists(): time.sleep(0.005)
if mode=='fail': sys.exit(1)
print(json.dumps({'schemaVersion':1,'data':[],'nextCursor':None,'warnings':[]}))
"#,
            )
            .unwrap();
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
            gateway.use_agent_launcher(program);
            Self { directory, gateway }
        }

        fn calls(&self) -> usize {
            std::fs::read_to_string(self.directory.path().join("calls"))
                .unwrap_or_default()
                .lines()
                .count()
        }

        async fn started(&self, count: usize) {
            let path = self.directory.path().join("calls");
            crate::test_support::wait_until("launcher process to start", move || {
                std::fs::read_to_string(&path)
                    .unwrap_or_default()
                    .lines()
                    .count()
                    >= count
            })
            .await;
        }

        fn release(&self) {
            std::fs::write(self.directory.path().join("release"), "").unwrap();
        }
    }

    #[tokio::test]
    async fn discovery_round_two_ui_classification_cannot_exhaust_alert_capacity() {
        crate::test_support::with_manual_time(async {
            let fixture = Fixture::new("hold");
            let mut readers = Vec::new();
            for id in ["a", "b"] {
                let gateway = Arc::clone(&fixture.gateway);
                readers.push(tokio::spawn(async move {
                    gateway
                        .agent_service()
                        .agents_rpc("conversation/agents/classify", json!({"threadIds":[id]}))
                        .await
                }));
            }
            fixture.started(2).await;
            let gateway = Arc::clone(&fixture.gateway);
            let alert = tokio::spawn(async move {
                gateway
                    .is_agent_thread("claude_11111111-2222-4333-8444-555555555555")
                    .await
            });
            fixture.started(3).await;
            fixture.release();
            for reader in readers {
                reader.await.unwrap().unwrap();
            }
            let _ = alert.await.unwrap();
        })
        .await;
    }

    #[tokio::test]
    async fn discovery_round_two_shutdown_cancels_owned_inventory() {
        crate::test_support::with_manual_time(async {
            let fixture = Fixture::new("hold");
            let gateway = Arc::clone(&fixture.gateway);
            let reader = tokio::spawn(async move {
                gateway
                    .agent_service()
                    .launcher_agents(json!({"threadIds":["a"]}))
                    .await
            });
            fixture.started(1).await;
            fixture.gateway.stop().await.unwrap();
            let pending = fixture
                .gateway
                .agents
                .launcher
                .state
                .lock()
                .unwrap()
                .pending
                .len();
            let permits = fixture
                .gateway
                .agents
                .launcher
                .inventory
                .processes
                .available_permits();
            fixture.release();
            let _ = reader.await.unwrap();
            assert_eq!(pending, 0, "shutdown left inventory running");
            assert_eq!(permits, 2, "shutdown did not release inventory processes");
        })
        .await;
    }

    #[tokio::test]
    async fn discovery_round_two_incomplete_agent_discovery_is_retryable() {
        crate::test_support::with_manual_time(async {
            let fixture = Fixture::new("hold");
            let mut control = crate::test_support::FakeControl::attach(&fixture.gateway, 4).await;
            let gateway = Arc::clone(&fixture.gateway);
            let responder = tokio::spawn(async move {
                let request: Value =
                    serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
                assert_eq!(request["method"], "thread/list");
                gateway
                    .control_requests
                    .lock()
                    .unwrap()
                    .remove(request["id"].as_str().unwrap())
                    .unwrap()
                    .send(Ok(json!({"data":[],"nextCursor":null})))
                    .unwrap();
            });
            let service = fixture.gateway.agent_service();
            let read = service.agents_rpc(
                "conversation/agents/read",
                json!({"threadId":"root","agentId":"launcher:missing"}),
            );
            let expire = async {
                fixture.started(1).await;
                responder.await.unwrap();
                tokio::time::advance(INVENTORY_BUDGET + Duration::from_millis(1)).await;
            };
            let (error, ()) = tokio::join!(read, expire);
            let error = error.unwrap_err();
            let wire = error.response(&json!(1));
            assert_eq!(wire["error"]["data"]["retryable"], true);
            assert_eq!(wire["error"]["data"]["kind"], "agentDiscoveryIncomplete");
            assert!(error.message.contains("discovery incomplete"));
        })
        .await;
    }

    #[tokio::test]
    async fn discovery_opus_cancelled_inventory_reader_cannot_cancel_shared_work() {
        crate::test_support::with_manual_time(async {
            let fixture = Fixture::new("hold");
            let gateway = Arc::clone(&fixture.gateway);
            let first = tokio::spawn(async move {
                gateway
                    .agent_service()
                    .launcher_agents(json!({"threadIds":["a"]}))
                    .await
            });
            fixture.started(1).await;
            let service = fixture.gateway.agent_service();
            let second = service.launcher_agents(json!({"threadIds":["a"]}));
            tokio::pin!(second);
            tokio::select! {
                biased;
                _ = &mut second => panic!("shared read finished before fixture release"),
                () = tokio::task::yield_now() => {}
            }
            first.abort();
            let _ = first.await;
            fixture.release();
            let result = second.await;
            let cached = service.launcher_agents(json!({"threadIds":["a"]})).await;
            assert!(
                result.is_ok(),
                "caller cancellation poisoned a shared reader"
            );
            assert!(cached.is_ok(), "caller cancellation poisoned the cache");
            assert_eq!(fixture.calls(), 1);
        })
        .await;
    }

    #[tokio::test]
    async fn discovery_opus_mutations_cannot_starve_alert_classification() {
        crate::test_support::with_manual_time(async {
            let fixture = Fixture::new("hold");
            let gateway = Arc::clone(&fixture.gateway);
            let first = tokio::spawn(async move {
                gateway
                    .call_agent_launcher(LauncherPurpose::Mutation, json!({"operation":"stop"}))
                    .await
            });
            let gateway = Arc::clone(&fixture.gateway);
            let second = tokio::spawn(async move {
                gateway
                    .call_agent_launcher(LauncherPurpose::Mutation, json!({"operation":"send"}))
                    .await
            });
            fixture.started(2).await;
            let gateway = Arc::clone(&fixture.gateway);
            let alert = tokio::spawn(async move {
                gateway
                    .call_agent_launcher(
                        LauncherPurpose::Classification,
                        json!({"operation":"status","schemaVersion":2}),
                    )
                    .await
            });
            fixture.started(3).await;
            fixture.release();
            first.await.unwrap().unwrap();
            second.await.unwrap().unwrap();
            alert.await.unwrap().unwrap();
        })
        .await;
    }

    #[tokio::test]
    async fn identical_inventory_selections_share_one_process_and_preserve_home_identity() {
        crate::test_support::with_manual_time(async {
            let fixture = Fixture::new("hold");
            let service = fixture.gateway.agent_service();
            let read = service.launcher_agents(json!({"threadIds":["b","a","b"]}));
            let duplicate = service.launcher_agents(json!({"threadIds":["a","b"]}));
            let release = async {
                fixture.started(1).await;
                fixture.release();
            };
            let (first, second, _) = tokio::join!(read, duplicate, release);
            assert!(Arc::ptr_eq(&first.unwrap(), &second.unwrap()));
            assert_eq!(fixture.calls(), 1);
            fixture
                .gateway
                .agents
                .launcher
                .inventory(
                    &service,
                    json!({"threadIds":["a","b"]}),
                    vec![fixture.directory.path().join("other-home")],
                )
                .await
                .unwrap();
            assert_eq!(fixture.calls(), 2);
        })
        .await;
    }

    #[tokio::test]
    async fn failing_and_timed_out_inventory_are_remembered_until_negative_expiry() {
        crate::test_support::with_manual_time(async {
            for mode in ["fail", "hold"] {
                let fixture = Fixture::new(mode);
                let service = fixture.gateway.agent_service();
                let selection = json!({"threadIds":["a"]});
                let read = service.launcher_agents(selection.clone());
                let expire = async {
                    fixture.started(1).await;
                    if mode == "hold" {
                        tokio::time::advance(INVENTORY_BUDGET + Duration::from_millis(1)).await;
                    }
                };
                let (result, ()) = tokio::join!(read, expire);
                assert!(result.is_err());
                let gateway = Arc::clone(&fixture.gateway);
                crate::test_support::wait_until("shared inventory to settle", move || {
                    gateway
                        .agents
                        .launcher
                        .state
                        .lock()
                        .unwrap()
                        .pending
                        .is_empty()
                })
                .await;
                assert!(service.launcher_agents(selection.clone()).await.is_err());
                assert_eq!(fixture.calls(), 1);
                fixture.release();
                std::fs::write(fixture.directory.path().join("mode"), "ok").unwrap();
                tokio::time::advance(FAILURE_RETRY).await;
                service.launcher_agents(selection).await.unwrap();
                assert_eq!(fixture.calls(), 2);
            }
        })
        .await;
    }

    #[tokio::test]
    async fn agents_list_preserves_native_agents_when_external_discovery_times_out() {
        crate::test_support::with_manual_time(async {
            let fixture = Fixture::new("hold");
            let mut control = crate::test_support::FakeControl::attach(&fixture.gateway, 4).await;
            let gateway = Arc::clone(&fixture.gateway);
            let responder = tokio::spawn(async move {
                for _ in 0..4 {
                    let request: Value =
                        serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
                    let result = if request["method"] == "thread/list" {
                        json!({"data":[{"id":"child","parentThreadId":"root","name":"Native child","updatedAt":1,"status":{"type":"idle"}}],"nextCursor":null})
                    } else {
                        assert_eq!(request["method"], "thread/turns/list");
                        json!({"data":[{"id":"turn-child","status":"completed"}]})
                    };
                    gateway
                        .control_requests
                        .lock()
                        .unwrap()
                        .remove(request["id"].as_str().unwrap())
                        .unwrap()
                        .send(Ok(result))
                        .unwrap();
                }
            });
            let service = fixture.gateway.agent_service();
            let first = service.agents_rpc("conversation/agents/list", json!({"threadId":"root"}));
            let second = service.agents_rpc("conversation/agents/list", json!({"threadId":"root"}));
            let expire = async {
                fixture.started(1).await;
                responder.await.unwrap();
                tokio::time::advance(INVENTORY_BUDGET + Duration::from_millis(1)).await;
            };
            let (first, second, ()) = tokio::join!(first, second, expire);
            for list in [first.unwrap(), second.unwrap()] {
                assert_eq!(list["agents"][0]["threadId"], "child");
                assert!(list["warnings"].as_array().unwrap().iter().any(|warning| {
                    warning
                        .as_str()
                        .unwrap()
                        .contains("External agents unavailable")
                }));
            }
            assert_eq!(fixture.calls(), 1);
        }).await;
    }

    #[test]
    fn discovery_review_invalidated_work_cannot_be_joined_or_remove_its_replacement() {
        let owner = Arc::new(LauncherReads::default());
        let selection = Selection {
            homes: Vec::new(),
            ancestors: false,
            ids: vec!["root".into()],
        };
        let Claim::Owned(mut previous) = owner.claim(selection.clone()).unwrap() else {
            panic!("first reader must own inventory");
        };
        owner.invalidate();
        let current = owner.claim(selection.clone()).unwrap();
        let Claim::Owned(mut current) = current else {
            panic!("post-mutation reader joined invalidated inventory");
        };
        previous.complete(Err(Arc::from("old result")));
        let Claim::Waiting(waiting) = owner.claim(selection.clone()).unwrap() else {
            panic!("old completion removed current inventory");
        };
        current.complete(Err(Arc::from("new result")));
        assert_eq!(
            waiting
                .borrow()
                .as_ref()
                .unwrap()
                .as_ref()
                .err()
                .unwrap()
                .as_ref(),
            "new result"
        );
        let Claim::Cached(outcome) = owner.claim(selection).unwrap() else {
            panic!("current result was not cached");
        };
        assert_eq!(outcome.err().unwrap().as_ref(), "new result");
    }

    #[tokio::test]
    async fn discovery_review_list_keeps_headers_when_execution_enrichment_expires() {
        crate::test_support::with_manual_time(async {
            let fixture = Fixture::new("ok");
            let mut control = crate::test_support::FakeControl::attach(&fixture.gateway, 4).await;
            let gateway = Arc::clone(&fixture.gateway);
            let responder = tokio::spawn(async move {
                for _ in 0..3 {
                    let request: Value =
                        serde_json::from_str(&control.requests.recv().await.unwrap()).unwrap();
                    let result = match request["method"].as_str().unwrap() {
                        "thread/list" => json!({"data":[
                            {"id":"ready","parentThreadId":"root","name":"Ready child","updatedAt":1,"status":{"type":"idle"}},
                            {"id":"blocked","parentThreadId":"root","name":"Blocked child","updatedAt":1,"status":{"type":"idle"}}
                        ],"nextCursor":null}),
                        "thread/turns/list" if request["params"]["threadId"] == "ready" => {
                            json!({"data":[{"id":"ready-turn","status":"completed"}]})
                        }
                        "thread/turns/list" => continue,
                        _ => panic!("unexpected request"),
                    };
                    gateway
                        .control_requests
                        .lock()
                        .unwrap()
                        .remove(request["id"].as_str().unwrap())
                        .unwrap()
                        .send(Ok(result))
                        .unwrap();
                }
            });
            let service = fixture.gateway.agent_service();
            let read = service.agents_rpc("conversation/agents/list", json!({"threadId":"root"}));
            let expire = async {
                responder.await.unwrap();
                tokio::time::advance(Duration::from_millis(2001)).await;
            };
            let (list, ()) = tokio::join!(read, expire);
            let list = list.unwrap();
            let agents = list["agents"].as_array().unwrap();
            assert_eq!(
                agents.len(),
                2,
                "known native headers disappeared at the deadline"
            );
            let ready = agents
                .iter()
                .find(|agent| agent["threadId"] == "ready")
                .unwrap();
            assert_eq!(ready["state"], "completed");
            let blocked = agents
                .iter()
                .find(|agent| agent["threadId"] == "blocked")
                .unwrap();
            assert_eq!(blocked["state"], "unknown");
            assert!(blocked["executionId"].is_null());
            assert!(list["warnings"].as_array().unwrap().iter().any(|warning| {
                warning
                    .as_str()
                    .unwrap()
                    .contains("Latest execution unavailable for blocked")
            }));
        }).await;
    }

    #[test]
    fn pending_inventory_and_waiters_are_bounded_and_cancellation_releases_them() {
        let owner = Arc::new(LauncherReads::default());
        let selection = |id: usize| Selection {
            homes: Vec::new(),
            ancestors: false,
            ids: vec![id.to_string()],
        };
        let owned: Vec<_> = (0..PENDING_SELECTION_LIMIT)
            .map(|id| owner.claim(selection(id)).unwrap())
            .collect();
        assert!(owner.claim(selection(PENDING_SELECTION_LIMIT)).is_err());
        let waiting: Vec<_> = (0..WAITER_LIMIT)
            .map(|_| owner.claim(selection(0)).unwrap())
            .collect();
        assert!(owner.claim(selection(0)).is_err());
        drop(owned);
        assert!(owner.state.lock().unwrap().pending.is_empty());
        match &waiting[0] {
            Claim::Waiting(receiver) => assert!(receiver.borrow().as_ref().unwrap().is_err()),
            _ => panic!("expected waiter"),
        }
    }
}
