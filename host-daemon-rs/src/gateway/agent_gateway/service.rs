use super::{
    ActionParams, AgentRef, AgentViewSnapshot, ClassifyParams, ListParams, NativeCoverage,
    NativeExecution, NativeExecutionSnapshot, NativeInventory, ParentSnapshot, decode,
    native_parent,
};
use crate::agents::{Agent, Capabilities, Output, State};
use crate::gateway::Gateway;
use crate::gateway::agent_gateway::stop::CodexStop;
use crate::rpc::error::RpcCode;
use crate::rpc::{RpcError, RpcResult};
use anyhow::{Context, Result, anyhow, bail, ensure};
use futures_util::{FutureExt, StreamExt};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

pub(in crate::gateway) struct AgentService<'a> {
    gateway: &'a Gateway,
}

mod runtime;
pub(in crate::gateway) use runtime::ThreadRelation;

pub(in crate::gateway) struct AgentOwners {
    pub(in crate::gateway) owners: HashMap<String, String>,
    pub(in crate::gateway) complete: bool,
}

#[derive(Debug)]
struct DiscoveryIncomplete;

impl std::fmt::Display for DiscoveryIncomplete {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("Agent discovery incomplete; try again")
    }
}

impl std::error::Error for DiscoveryIncomplete {}

impl Gateway {
    pub(in crate::gateway) fn agent_service(&self) -> AgentService<'_> {
        AgentService { gateway: self }
    }
}

impl AgentService<'_> {
    pub(in crate::gateway) async fn invalidate_parent_views(&self) {
        self.gateway.agents.parents.lock().await.clear();
        self.gateway.agents.views.lock().await.clear();
    }

    pub(in crate::gateway) async fn agents_rpc(&self, method: &str, params: Value) -> RpcResult {
        let result = match method {
            "conversation/agents/classify" => self.classify_agents(decode(params)?).await,
            "conversation/agents/list" => {
                let ListParams { thread_id } = decode(params)?;
                self.list_agents(&thread_id).await
            }
            "conversation/agents/read" => self.read_agent(&decode(params)?).await,
            "conversation/agents/action" => self.act_on_agent(decode(params)?).await,
            _ => {
                return Err(RpcError::new(
                    RpcCode::MethodNotFound,
                    "Unsupported agent operation",
                ));
            }
        };
        result.map_err(|error| {
            if error.is::<DiscoveryIncomplete>() {
                RpcError::new(RpcCode::Unavailable, error.to_string()).with_data(
                    crate::rpc::error::RpcData::Raw(
                        json!({"kind":"agentDiscoveryIncomplete","retryable":true}),
                    ),
                )
            } else {
                RpcError::new(RpcCode::Internal, format!("{error:#}"))
            }
        })
    }

    async fn classify_agents(
        &self,
        ClassifyParams { thread_ids: ids }: ClassifyParams,
    ) -> Result<Value> {
        ensure!(
            ids.len() <= 200,
            "At most 200 conversations per classification"
        );
        self.classify_runtime(ids).await
    }

    pub(in crate::gateway) async fn native_codex_agents_with_freshness(
        &self,
        root: &str,
        fresh: bool,
    ) -> Result<NativeInventory> {
        self.native_codex_agents_until(
            root,
            fresh,
            tokio::time::Instant::now() + Duration::from_secs(3),
        )
        .await
    }

    async fn native_codex_agents_until(
        &self,
        root: &str,
        fresh: bool,
        deadline: tokio::time::Instant,
    ) -> Result<NativeInventory> {
        let mut nodes = Vec::new();
        let mut coverage = NativeCoverage::default();
        let mut cursor: Option<String> = None;
        let previous = if fresh {
            HashMap::new()
        } else {
            self.gateway
                .agents
                .native_executions
                .lock()
                .await
                .iter()
                .find(|entry| entry.root == root)
                .map(|entry| entry.entries.clone())
                .unwrap_or_default()
        };
        let mut current = HashMap::new();
        for _ in 0..4 {
            if tokio::time::Instant::now() >= deadline {
                coverage.truncated = true;
                break;
            }
            let page = match tokio::time::timeout_at(deadline, self.gateway.call_control("thread/list", json!({"ancestorThreadId":root,"limit":64,"cursor":cursor,"sortKey":"created_at"}))).await {
                Ok(Ok(page)) => page,
                Ok(Err(error)) if nodes.is_empty() => return Err(error),
                Ok(Err(_)) | Err(_) => {
                    coverage.truncated = true;
                    break;
                }
            };
            let threads = page["data"]
                .as_array()
                .context("Missing child thread page")?;
            let ids = threads
                .iter()
                .filter(|thread| {
                    let id = thread["id"].as_str();
                    let cached = id.and_then(|id| previous.get(id));
                    thread["status"]["type"] == "active"
                        || thread["updatedAt"].is_null()
                        || cached.is_none_or(|entry| {
                            entry.read_at.elapsed() >= Duration::from_secs(30)
                                || entry.updated_at != thread["updatedAt"]
                                || entry.status != thread["status"]
                        })
                })
                .map(|thread| {
                    thread["id"]
                        .as_str()
                        .map(str::to_owned)
                        .context("Child has no identity")
                })
                .collect::<Result<Vec<_>>>()?;
            let gateway = self.gateway;
            let mut latest: HashMap<String, Result<Option<Value>>> =
                futures_util::stream::iter(ids)
                    .map(|id| {
                        async move {
                            if tokio::time::Instant::now() >= deadline {
                                return (id, Err(anyhow!("Latest child execution timed out")));
                            }
                            let result = tokio::time::timeout_at(
                                deadline,
                                gateway.latest_codex_turn(&id, None),
                            )
                            .await
                            .context("Latest child execution timed out")
                            .and_then(|result| result);
                            (id, result)
                        }
                        .boxed()
                    })
                    .buffer_unordered(4)
                    .collect()
                    .await;
            for thread in threads {
                let id = thread["id"].as_str().context("Child has no identity")?;
                let parent = native_parent(thread);
                let flags = thread
                    .pointer("/status/activeFlags")
                    .and_then(Value::as_array);
                let mut state = match thread.pointer("/status/type").and_then(Value::as_str) {
                    Some("active")
                        if flags.is_some_and(|f| {
                            f.iter().any(|flag| {
                                matches!(
                                    flag.as_str(),
                                    Some("waitingOnApproval" | "waitingOnUserInput")
                                )
                            })
                        }) =>
                    {
                        State::Waiting
                    }
                    Some("active") => State::Working,
                    Some("systemError") => State::Failed,
                    _ => State::Unknown,
                };
                let mut execution_id = None;
                let mut read_failed = false;
                let cached = previous.get(id).filter(|entry| {
                    !thread["updatedAt"].is_null()
                        && thread["status"]["type"] != "active"
                        && entry.read_at.elapsed() < Duration::from_secs(30)
                        && entry.updated_at == thread["updatedAt"]
                        && entry.status == thread["status"]
                });
                if let Some(entry) = cached {
                    state = entry.state.clone();
                    execution_id = entry.execution_id.clone();
                } else {
                    match latest
                        .remove(id)
                        .context("Missing child execution result")?
                    {
                        Ok(turn) => {
                            if let Some(turn) = turn {
                                execution_id = turn["id"].as_str().map(str::to_owned);
                                if !state.is_running() {
                                    state = match turn["status"].as_str() {
                                        Some("inProgress") => State::Working,
                                        Some("completed") => State::Completed,
                                        Some("interrupted") => State::Interrupted,
                                        Some("failed") => State::Failed,
                                        _ => State::Unknown,
                                    };
                                }
                            }
                        }
                        Err(_) => {
                            read_failed = true;
                            coverage.unreadable.push(id.to_owned());
                        }
                    }
                }
                let active = state.is_running();
                if !read_failed {
                    current.insert(
                        id.to_owned(),
                        cached.cloned().unwrap_or_else(|| NativeExecution {
                            read_at: Instant::now(),
                            updated_at: thread["updatedAt"].clone(),
                            status: thread["status"].clone(),
                            state: state.clone(),
                            execution_id: execution_id.clone(),
                        }),
                    );
                }
                nodes.push(Agent {
                    owner_host_id: self.gateway.host_identity().await?.host_id.clone(),
                    job_id: None,
                    parent: Some(crate::wire::cluster::AgentAddress {
                        host_id: self.gateway.host_identity().await?.host_id,
                        thread_id: parent.unwrap_or(root).into(),
                    }),
                    recipient: None,
                    kind: None,
                    intent_state: None,
                    id: format!("codex:{id}"),
                    parent_id: parent.filter(|p| *p != root).map(|p| format!("codex:{p}")),
                    owner_thread_id: root.into(),
                    thread_id: Some(id.into()),
                    provider: "codex".into(),
                    source: "native".into(),
                    title: thread["name"]
                        .as_str()
                        .filter(|s| !s.trim().is_empty())
                        .or(thread["agentNickname"].as_str())
                        .or(thread["agentRole"].as_str())
                        .unwrap_or("Agent")
                        .into(),
                    model: thread["model"].as_str().map(str::to_owned),
                    state,
                    capabilities: Capabilities {
                        inspect: true,
                        open_conversation: true,
                        ask_parent: true,
                        stop: active && execution_id.is_some(),
                        ..Default::default()
                    },
                    execution_id,
                    last_active_at: thread["updatedAt"].as_i64(),
                });
            }
            let next = page["nextCursor"].as_str().map(str::to_owned);
            if next.is_none() {
                cursor = None;
                break;
            }
            ensure!(next != cursor, "Native child pagination did not advance");
            cursor = next;
        }
        coverage.truncated |= cursor.is_some();
        let mut cache = self.gateway.agents.native_executions.lock().await;
        cache.retain(|entry| entry.root != root);
        cache.push_back(NativeExecutionSnapshot {
            root: root.into(),
            entries: current,
        });
        while cache.len() > 16 {
            cache.pop_front();
        }
        Ok(NativeInventory {
            agents: nodes,
            coverage,
        })
    }

    async fn native_agents(
        &self,
        root: &str,
        deadline: tokio::time::Instant,
    ) -> Result<NativeInventory> {
        if root.starts_with("claude_") {
            return Ok(NativeInventory {
                agents: Vec::new(),
                coverage: NativeCoverage::default(),
            });
        }
        self.native_codex_agents_until(root, false, deadline).await
    }

    pub(in crate::gateway) async fn list_agents(&self, root: &str) -> Result<Value> {
        crate::questions::validate_id(root)?;

        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        let mut phase = crate::observability::read_phase::ReadPhase::new(
            &self.gateway.journal,
            "conversation/agents/list",
            "nativeInventory",
        );
        let (mut native, mut warnings) = match self.native_agents(root, deadline).await {
            Ok(inventory) => (inventory.agents, inventory.coverage.warnings()),
            Err(error) => (
                Vec::new(),
                vec![format!("Native agents unavailable: {error}")],
            ),
        };
        phase.advance("externalExpansion");
        let mut inspected = HashSet::from([root.to_owned()]);
        let mut external = Vec::new();
        let mut titles = HashMap::<String, String>::new();
        for _ in 0..8 {
            if tokio::time::Instant::now() >= deadline {
                warnings.push("Agent discovery incomplete: inventory deadline exceeded".into());
                break;
            }
            let (projected, runtime_warnings) = match self.runtime_agents(root, &native).await {
                Ok(result) => result,
                Err(error) => {
                    warnings.push(format!("Runtime agents unavailable: {error:#}"));
                    break;
                }
            };
            external = projected;
            warnings.extend(runtime_warnings);
            let mut expanded = false;
            let external_count = external.len();
            for agent in &mut external {
                if tokio::time::Instant::now() >= deadline {
                    warnings.push("Agent discovery incomplete: inventory deadline exceeded".into());
                    break;
                }
                let Some(thread) = &agent.thread_id else {
                    continue;
                };
                if inspected.len() >= 16 {
                    warnings.push("Additional agent subtrees are outside this view's limit".into());
                    break;
                }
                if !inspected.insert(thread.clone()) {
                    continue;
                }
                let header = tokio::time::timeout_at(deadline, async {
                    if let Some(uuid) =
                        crate::providers::claude::session_uuid_from_thread_id(thread)
                    {
                        self.gateway
                            .claude_history
                            .read_thread_header(uuid.to_owned())
                            .await
                    } else {
                        self.gateway
                            .call_control(
                                "thread/read",
                                json!({"threadId":thread,"includeTurns":false}),
                            )
                            .await
                            .map(|value| value["thread"].clone())
                    }
                })
                .await;
                if let Ok(Ok(header)) = header
                    && let Some(name) = header["name"]
                        .as_str()
                        .filter(|name| !name.trim().is_empty())
                {
                    titles.insert(agent.id.clone(), name.into());
                }
                match self.native_agents(thread, deadline).await {
                    Ok(NativeInventory {
                        agents: mut children,
                        coverage,
                    }) => {
                        warnings.extend(coverage.warnings());
                        expanded |= !children.is_empty();
                        for child in &mut children {
                            if child.parent_id.is_none() {
                                child.parent_id = Some(agent.id.clone());
                            }
                        }
                        native.extend(children);
                    }
                    Err(error) => warnings.push(format!("Agent subtree unavailable: {error}")),
                }
                if native.len() + external_count >= 512 {
                    break;
                }
            }
            if !expanded || native.len() + external.len() >= 512 {
                break;
            }
        }
        phase.complete();
        for agent in &mut external {
            if let Some(title) = titles.remove(&agent.id) {
                agent.title = title;
            }
        }
        native.extend(external);
        native.sort_by(|a, b| a.id.cmp(&b.id));
        native.dedup_by(|a, b| a.id == b.id);
        if native.len() > 512 {
            native.truncate(512);
            warnings.push("Agent list reached its limit".into());
        }
        warnings.sort();
        warnings.dedup();
        let revision = crate::ids::sha256_hex(serde_json::to_vec(&native)?);
        let mut views = self.gateway.agents.views.lock().await;
        views.retain(|entry| entry.root != root);
        views.push_back(AgentViewSnapshot {
            root: root.into(),
            at: Instant::now(),
            agents: native.clone(),
        });
        while views.len() > 16 {
            views.pop_front();
        }
        Ok(json!({"agents":native,"revision":revision,"warnings":warnings}))
    }

    async fn resolve_agent(
        &self,
        AgentRef {
            agent_id: id,
            thread_id: root,
        }: &AgentRef,
    ) -> Result<Agent> {
        let cached = self
            .gateway
            .agents
            .views
            .lock()
            .await
            .iter()
            .find(|entry| entry.root == *root && entry.at.elapsed() < Duration::from_secs(30))
            .and_then(|entry| entry.agents.iter().find(|agent| agent.id == *id))
            .cloned();
        if let Some(agent) = cached {
            return Ok(agent);
        }
        let list = self.list_agents(root).await?;
        let nodes: Vec<Agent> = serde_json::from_value(list["agents"].clone())?;
        if let Some(agent) = nodes.into_iter().find(|n| n.id == *id) {
            return Ok(agent);
        }
        if list["warnings"]
            .as_array()
            .is_some_and(|warnings| !warnings.is_empty())
        {
            return Err(DiscoveryIncomplete.into());
        }
        bail!("Agent is no longer available; refresh the list")
    }

    async fn read_agent(&self, target: &AgentRef) -> Result<Value> {
        let node = self.resolve_agent(target).await?;
        if node.source == "runtime" {
            return self.read_runtime_agent(&node).await;
        }
        let thread = node.thread_id.context("Missing native thread")?;
        self.read_thread_output(&thread).await
    }

    pub(in crate::gateway) async fn read_thread_output(&self, thread: &str) -> Result<Value> {
        let turns = self
            .gateway
            .cluster_history_page(
                "thread/turns/list",
                json!({"threadId":thread,"limit":5,"sortDirection":"desc","itemsView":"notLoaded"}),
            )
            .await?;
        let mut output = Output::default();
        for turn in turns["data"]
            .as_array()
            .context("Missing turn list")?
            .iter()
            .rev()
        {
            let items=self.gateway.cluster_history_page("thread/items/list",json!({"threadId":thread,"turnId":turn["id"],"limit":100,"sortDirection":"desc"})).await?;
            output.truncated |= !items["nextCursor"].is_null();
            for entry in items["data"]
                .as_array()
                .context("Missing item list")?
                .iter()
                .rev()
            {
                let item = &entry["item"];
                if item["type"] == "userMessage"
                    && let Some(blocks) = item["content"].as_array()
                {
                    for block in blocks {
                        if block["type"] == "text"
                            && let Some(text) = block["text"].as_str()
                        {
                            output.push("user", text);
                        }
                    }
                }
                if item["type"] == "agentMessage"
                    && let Some(text) = item["text"].as_str()
                {
                    output.push("assistant", text);
                }
            }
        }
        output.truncated |= !turns["nextCursor"].is_null();
        Ok(serde_json::to_value(output)?)
    }

    pub(in crate::gateway) async fn act_on_agent(&self, params: ActionParams) -> Result<Value> {
        let node = self.resolve_agent(&params.agent).await?;
        let action = params.action.as_str();
        ensure!(
            matches!(action, "message" | "continue" | "stop"),
            "Unsupported agent action"
        );
        ensure!(
            !self.gateway.is_draining() || action == "stop",
            "Gateway is restarting; retry after reconnecting"
        );
        ensure!(
            params.execution_id == node.execution_id,
            "Agent execution changed; refresh before acting"
        );
        if node.source == "runtime" {
            return self.act_on_runtime_agent(&node, params).await;
        }
        if action == "stop" && node.provider == "codex" && node.capabilities.stop {
            let thread = node.thread_id.as_deref().context("Missing native thread")?;
            let turn = node
                .execution_id
                .as_deref()
                .context("Missing child execution")?;
            CodexStop::new(self.gateway)
                .run(thread, turn, json!({"threadId":thread,"turnId":turn}))
                .await
                .map_err(|error| anyhow!(error.message))?;
            return Ok(json!({"delivery":"stopRequested"}));
        }
        bail!("This action must be requested through the parent conversation")
    }

    pub(in crate::gateway) async fn agent_owners(&self, threads: &[String]) -> AgentOwners {
        let roots = self.thread_roots(threads).await;
        AgentOwners {
            complete: threads.iter().all(|thread| roots.contains_key(thread)),
            owners: roots
                .into_iter()
                .filter(|(thread, root)| thread != root)
                .collect(),
        }
    }

    pub(in crate::gateway) async fn remote_parents(
        &self,
        roots: impl IntoIterator<Item = &String>,
    ) -> Option<HashMap<String, crate::wire::cluster::AgentAddress>> {
        let parents = self.gateway.agents.parents.lock().await;
        let mut remote = HashMap::new();
        for root in roots {
            let snapshot = parents.get(root).filter(|snapshot| snapshot.available)?;
            if let Some(parent) = &snapshot.remote_parent {
                remote.insert(root.clone(), parent.clone());
            }
        }
        Some(remote)
    }

    pub(in crate::gateway) async fn thread_roots(
        &self,
        threads: &[String],
    ) -> HashMap<String, String> {
        let mut parents = self.gateway.agents.parents.lock().await.clone();
        let mut pending: Vec<String> = threads.iter().take(128).cloned().collect();
        for _ in 0..8 {
            pending.sort();
            pending.dedup();
            let missing: Vec<String> = pending
                .iter()
                .filter(|id| {
                    parents.get(*id).is_none_or(|snapshot| {
                        snapshot.at.elapsed()
                            > Duration::from_secs(if !snapshot.available {
                                3
                            } else if snapshot.parent.is_some() || snapshot.remote_parent.is_some()
                            {
                                300
                            } else {
                                10
                            })
                    })
                })
                .cloned()
                .collect();
            if !missing.is_empty() {
                let reads = futures_util::stream::iter(missing)
                    .map(|thread| {
                        async move {
                            let parent = async {
                                let host = self.gateway.host_identity().await?.host_id;
                                self.parent_for_thread(&thread).await.map(|parent| {
                                    parent.map(|parent| {
                                        if parent.host_id == host {
                                            ParentLink::Local(parent.thread_id)
                                        } else {
                                            ParentLink::Remote(parent)
                                        }
                                    })
                                })
                            }
                            .await;
                            (thread, parent)
                        }
                        .boxed()
                    })
                    .buffer_unordered(32)
                    .collect::<Vec<_>>()
                    .await;
                for (thread, parent) in reads {
                    let available = parent.is_ok();
                    let (parent, remote_parent) = match parent {
                        Ok(Some(ParentLink::Local(parent))) => (Some(parent), None),
                        Ok(Some(ParentLink::Remote(parent))) => (None, Some(parent)),
                        Ok(None) => (None, None),
                        Err(_) => parents
                            .get(&thread)
                            .map(|snapshot| {
                                (snapshot.parent.clone(), snapshot.remote_parent.clone())
                            })
                            .unwrap_or_default(),
                    };
                    if parents.len() >= 1024
                        && !parents.contains_key(&thread)
                        && let Some(oldest) = parents
                            .iter()
                            .min_by_key(|(_, snapshot)| snapshot.at)
                            .map(|(id, _)| id.clone())
                    {
                        parents.remove(&oldest);
                    }
                    parents.insert(
                        thread,
                        ParentSnapshot {
                            at: Instant::now(),
                            parent,
                            remote_parent,
                            available,
                        },
                    );
                }
            }
            let next: Vec<String> = pending
                .iter()
                .filter_map(|id| parents.get(id).and_then(|snapshot| snapshot.parent.clone()))
                .collect();
            if next.is_empty() || next == pending {
                break;
            }
            pending = next;
        }
        let mut cache = self.gateway.agents.parents.lock().await;
        for (thread, snapshot) in parents {
            if cache
                .get(&thread)
                .is_none_or(|current| current.at <= snapshot.at)
            {
                cache.insert(thread, snapshot);
            }
        }
        while cache.len() > 1024 {
            let Some(oldest) = cache
                .iter()
                .min_by_key(|(_, snapshot)| snapshot.at)
                .map(|(id, _)| id.clone())
            else {
                break;
            };
            cache.remove(&oldest);
        }
        let parents = &*cache;
        threads
            .iter()
            .filter_map(|thread| {
                let mut owner = thread.clone();
                let mut visited = HashSet::from([owner.clone()]);
                for _ in 0..32 {
                    let snapshot = parents.get(&owner)?;
                    if !snapshot.available {
                        return None;
                    }
                    let Some(parent) = snapshot.parent.clone() else {
                        return snapshot.available.then(|| (thread.clone(), owner));
                    };
                    if !visited.insert(parent.clone()) {
                        return Some((thread.clone(), thread.clone()));
                    }
                    owner = parent;
                }
                None
            })
            .collect()
    }
}

enum ParentLink {
    Local(String),
    Remote(crate::wire::cluster::AgentAddress),
}
