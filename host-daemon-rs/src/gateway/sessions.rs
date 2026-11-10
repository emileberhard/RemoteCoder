use super::Gateway;
use crate::rpc::error::{RpcCode, RpcData};
use crate::rpc::{RpcError, RpcResult};
use crate::sessions::{
    Origin, cluster, conversations, mirror, query,
    store::{ReadControl, Store},
    worker::Worker,
};
use anyhow::{Context, Result};
use futures_util::FutureExt;
use rusqlite::OptionalExtension;
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::sync::{Mutex, Semaphore};

tokio::task_local! {
    pub(super) static CONVERSATION_SEARCH_DEADLINE: std::time::Instant;
}

pub(super) struct Runtime {
    store: Store,
    origins: Vec<Origin>,
    worker: Arc<Worker>,
    readers: Arc<Semaphore>,
    search_readers: Arc<Semaphore>,
    mirror_lock: Mutex<()>,
    mirror_failures: Arc<mirror::Failures>,
    mirror_stop: tokio_util::sync::CancellationToken,
    mirror_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Gateway {
    pub(super) async fn sessions_runtime(&self) -> Result<&Arc<Runtime>> {
        self.session_runtime
            .get_or_try_init(|| async {
                let root = self
                    .turn_state_path
                    .as_ref()
                    .and_then(|p| p.parent())
                    .context("Session store has no configured state owner")?
                    .join("sessions/v1");
                let codex = self.codex.provider_home()?.to_owned();
                let claude = self.claude_settings.claude_home.clone();
                let host = self.host_identity().await?.host_id;
                let origins = vec![
                    Origin {
                        host: host.clone(),
                        provider: "codex".into(),
                        provider_home: codex.clone(),
                        local_home: codex,
                    },
                    Origin {
                        host,
                        provider: "claude".into(),
                        provider_home: claude.clone(),
                        local_home: claude,
                    },
                ];
                let cap_status = crate::config::HostPaths::from_env()?
                    .home()
                    .join(".local/state/disk-cap-status/remotecoder-sessions.json");
                tokio::task::spawn_blocking(move || -> Result<Arc<Runtime>> {
                    let store = Store::open(root.join("catalog.sqlite3"))?;
                    let worker =
                        Arc::new(Worker::start(store.clone(), origins.clone(), cap_status)?);
                    Ok(Arc::new(Runtime {
                        store,
                        origins,
                        worker,
                        readers: Arc::new(Semaphore::new(16)),
                        search_readers: Arc::new(Semaphore::new(2)),
                        mirror_lock: Mutex::new(()),
                        mirror_failures: Arc::default(),
                        mirror_stop: tokio_util::sync::CancellationToken::new(),
                        mirror_task: Mutex::new(None),
                    }))
                })
                .await?
            })
            .await
    }

    pub(super) async fn start_sessions(self: &Arc<Self>) -> Result<()> {
        let runtime = self.sessions_runtime().await?.clone();
        let mut task = runtime.mirror_task.lock().await;
        if task.is_some() {
            return Ok(());
        }
        let weak = Arc::downgrade(self);
        let stop = runtime.mirror_stop.clone();
        *task = Some(tokio::spawn(async move {
            let Some(gateway) = weak.upgrade() else {
                return;
            };
            let mut changes = gateway.jobs.changes();
            if let Ok(store) = gateway.jobs.store().await
                && let Ok(parents) = store.catalog_parents().await
                && let Some(runtime) = gateway.session_runtime.get()
            {
                runtime.worker.parents(parents);
            }
            drop(gateway);
            loop {
                tokio::select! {
                    _=stop.cancelled()=>break,
                    _=tokio::time::sleep(std::time::Duration::from_secs(5))=>{},
                    _=changes.changed()=>{}
                }
                let Some(gateway) = weak.upgrade() else {
                    break;
                };
                if let Ok(store) = gateway.jobs.store().await
                    && let Ok(parents) = store.catalog_parents().await
                    && let Some(runtime) = gateway.session_runtime.get()
                {
                    runtime.worker.parents(parents);
                }
                if let Err(error) = gateway.sync_session_mirror().await {
                    tracing::warn!(%error,"Session mirror is stale");
                }
            }
        }));
        Ok(())
    }

    pub(super) async fn stop_sessions(&self) {
        if let Some(runtime) = self.session_runtime.get() {
            runtime.mirror_stop.cancel();
            let task = runtime.mirror_task.lock().await.take();
            if let Some(task) = task {
                task.abort();
                let _ = task.await;
            }
            let worker = runtime.worker.clone();
            if let Err(error) = tokio::task::spawn_blocking(move || worker.stop()).await {
                tracing::warn!(%error,"Session ingest worker did not stop cleanly");
            }
        }
    }

    async fn sync_session_mirror(&self) -> Result<Value> {
        let runtime = self.sessions_runtime().await?;
        if !mirror::role(&runtime.store.path)? {
            return Ok(json!({"enabled":false}));
        }
        let Some(_guard) = runtime.mirror_lock.try_lock().ok() else {
            return Ok(json!({"running":true}));
        };
        let link = self.cluster_link().await?;
        let members = link
            .members()
            .await?
            .into_iter()
            .filter(|member| member.state == crate::wire::cluster::MemberState::Active);
        let mut outcomes = Vec::new();
        for member in members {
            let host = member.host;
            let member = host.clone();
            let link = link.clone();
            let callback: mirror::Call = Arc::new(move |method: &'static str, params: Value| {
                let link = link.clone();
                let member = member.clone();
                async move { link.call(&member, method, params).await.map_err(Into::into) }.boxed()
            });
            match mirror::sync(
                &runtime.store,
                &host,
                callback,
                runtime.mirror_stop.clone(),
                runtime.mirror_failures.clone(),
            )
            .await
            {
                Ok(value) => outcomes.push(json!({"host":host,"result":value})),
                Err(error) => {
                    let message = format!("{error:#}");
                    let prior: Option<String> = runtime
                        .store
                        .reader()?
                        .query_row(
                            "SELECT stale_reason FROM coverage WHERE origin_host=?1",
                            [&host],
                            |row| row.get(0),
                        )
                        .optional()?
                        .flatten();
                    if prior.as_ref() != Some(&message) {
                        tracing::warn!(host,%error,"Session mirror member is stale");
                        runtime.store.writer()?.execute("INSERT INTO coverage(origin_host,mode,stale_reason) VALUES(?1,'mirror',?2) ON CONFLICT(origin_host) DO UPDATE SET stale_reason=excluded.stale_reason WHERE coverage.stale_reason IS NOT excluded.stale_reason",rusqlite::params![host,message])?;
                    }
                    outcomes.push(json!({"host":host,"error":message}));
                }
            }
        }
        Ok(json!({"enabled":true,"members":outcomes}))
    }

    pub(crate) async fn session_inventory(
        &self,
        after: Option<String>,
        limit: usize,
    ) -> Result<query::SessionPage> {
        let runtime = self.sessions_runtime().await?;
        let permit = runtime.readers.clone().acquire_owned().await?;
        let store = runtime.store.clone();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            if after.is_none() {
                crate::sessions::ingest::refresh_inventory(&store)?;
            }
            query::inventory(&store.reader()?, after.as_deref(), limit)
        })
        .await?
    }

    pub(crate) async fn session_thread_suffix(
        &self,
        suffix: &str,
    ) -> Result<Vec<query::SessionHeader>> {
        let runtime = self.sessions_runtime().await?;
        let permit = runtime.readers.clone().acquire_owned().await?;
        let store = runtime.store.clone();
        let host = self.host_identity().await?.host_id;
        let suffix = suffix.to_owned();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let matches = query::match_thread_suffix(&store.reader()?, &host, &suffix)?;
            if !matches.is_empty() {
                return Ok(matches);
            }
            crate::sessions::ingest::refresh_inventory(&store)?;
            query::match_thread_suffix(&store.reader()?, &host, &suffix)
        })
        .await?
    }

    pub(crate) async fn sessions_rpc(
        self: &Arc<Self>,
        grant: &crate::auth::installation_credentials::Grant,
        method: &str,
        params: Value,
    ) -> RpcResult {
        if method == "sessions/conversations/search" {
            return self.conversation_search(params).await;
        }
        self.session_request(grant, method, params)
            .await
            .map_err(session_error)
    }

    async fn conversation_search(&self, params: Value) -> RpcResult {
        let request: conversations::Request =
            serde_json::from_value(params).map_err(|error| session_error(error.into()))?;
        request.terms().map_err(session_error)?;
        let deadline = CONVERSATION_SEARCH_DEADLINE
            .try_with(|deadline| *deadline)
            .unwrap_or_else(|_| std::time::Instant::now() + conversations::DEADLINE);
        let control = ReadControl::new(deadline);
        let _cancel = control.cancel_on_drop();
        let completed: conversations::Completed = Arc::default();
        let work = async {
            let runtime = self.sessions_runtime().await.map_err(session_error)?;
            let permit = runtime
                .search_readers
                .clone()
                .acquire_owned()
                .await
                .map_err(|error| session_error(error.into()))?;
            let store = runtime.store.clone();
            let completed = completed.clone();
            tokio::task::spawn_blocking(move || {
                let _permit = permit;
                let mut db = store.reader()?;
                db.interrupt_on(control.clone())?;
                conversations::search(&db, &request, &control, &completed)
            })
            .await
            .map_err(|error| session_error(error.into()))?
            .map_err(session_error)
        };
        let response =
            match tokio::time::timeout_at(tokio::time::Instant::from_std(deadline), work).await {
                Ok(Err(_)) if std::time::Instant::now() >= deadline => {
                    conversations::partial(&completed)
                        .ok_or_else(|| RpcError::request_timed_out(conversations::DEADLINE))?
                }
                Ok(result) => result?,
                Err(_) => conversations::partial(&completed)
                    .ok_or_else(|| RpcError::request_timed_out(conversations::DEADLINE))?,
            };
        serde_json::to_value(response).map_err(|error| session_error(error.into()))
    }

    async fn session_request(
        &self,
        grant: &crate::auth::installation_credentials::Grant,
        method: &str,
        params: Value,
    ) -> Result<Value> {
        let host = self.host_identity().await?.host_id;
        let params = if method == "sessions/read" {
            let mut request: query::ReadRequest = serde_json::from_value(params)?;
            request.local |= matches!(
                grant,
                crate::auth::installation_credentials::Grant::Peer { .. }
            );
            if let Some((origin, forwarded)) = cluster::forward_read(&host, request.clone())? {
                return self
                    .cluster_link()
                    .await?
                    .call(&origin, method, forwarded)
                    .await
                    .map_err(Into::into);
            }
            serde_json::to_value(request)?
        } else {
            params
        };
        let runtime = self.sessions_runtime().await?.clone();
        let local_host = host.clone();
        if method == "sessions/list" {
            #[derive(serde::Deserialize)]
            #[serde(deny_unknown_fields)]
            struct List {
                cursor: Option<String>,
                limit: usize,
            }
            let request: List = serde_json::from_value(params)?;
            return Ok(serde_json::to_value(
                self.session_inventory(request.cursor, request.limit)
                    .await?,
            )?);
        }
        if method == "sessions/mirror/status" {
            return Ok(json!({"role":mirror::role(&runtime.store.path)?}));
        }
        let permit = runtime.readers.clone().acquire_owned().await?;
        let store = runtime.store.clone();
        let origins = runtime.origins.clone();
        let method = method.to_owned();
        let request = if method == "sessions/search" {
            let mut request = serde_json::from_value::<query::Search>(params.clone())?;
            request.local |= matches!(
                grant,
                crate::auth::installation_credentials::Grant::Peer { .. }
            );
            Some(request)
        } else {
            None
        };
        let request_copy = request.clone();
        let output=tokio::task::spawn_blocking(move||->Result<Value> {
            let _permit=permit;
            match method.as_str() {
                "sessions/search"=>{
                    let mut request=request_copy.context("Search request missing")?;
                    if !request.local {
                        let positions=cluster::positions(request.cursor.as_deref())?;
                        match positions.get(&host).cloned().unwrap_or(cluster::Position::Next(None)) {
                            cluster::Position::Exhausted=>return Ok(json!({"hits":[],"cursor":null,"coverage":query::coverage(&store.reader()?)?})),
                            cluster::Position::Next(cursor)=>request.cursor=cursor,
                        }
                    }
                    query::search(&store.reader()?,&request)
                }
                "sessions/sql"=>{
                    #[derive(serde::Deserialize)]
                    #[serde(deny_unknown_fields)]
                    struct Sql {sql:String}
                    let request:Sql=serde_json::from_value(params)?;
                    query::sql(&store.reader()?,&request.sql)
                }
                "sessions/read"=>query::read(&store.reader()?,serde_json::from_value(params)?),
                "sessions/mirror/list"=>{
                    #[derive(serde::Deserialize)]
                    #[serde(deny_unknown_fields)]
                    struct List {cursor:Option<String>}
                    let request:List=serde_json::from_value(params)?;
                    mirror::list(&store,&host,request.cursor)
                }
                "sessions/mirror/changes"=>mirror::delta(&store,&host,&origins,serde_json::from_value(params)?),
                "sessions/mirror/fetch"=>mirror::fetch(&store,&host,serde_json::from_value(params)?),
                _=>anyhow::bail!("unsupported: unknown sessions method"),
            }
        }).await??;
        if let Some(request) = request
            && !request.local
        {
            let link = self.cluster_link().await?;
            let members = link
                .members()
                .await?
                .into_iter()
                .filter(|member| member.state == crate::wire::cluster::MemberState::Active)
                .map(|member| member.host)
                .collect();
            let call: cluster::MemberCall = Arc::new(move |host, method, params| {
                let link = link.clone();
                async move { link.call(&host, &method, params).await.map_err(Into::into) }.boxed()
            });
            return cluster::search(&local_host, output, members, request, call).await;
        }
        Ok(output)
    }
}

fn session_error(error: anyhow::Error) -> RpcError {
    let data = crate::sessions::error_data(&error);
    RpcError::new(
        RpcCode::InvalidParams,
        data["message"].as_str().unwrap_or("Session request failed"),
    )
    .with_data(RpcData::Raw(data))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::jobs::model::{
        AgentRecord, ConversationBinding, ConversationIdentity, Origin as JobOrigin, Provider,
        ProviderHome, Recipient,
    };
    use crate::wire::cluster::AgentAddress;

    #[tokio::test]
    async fn sessions_conversations_rpc_uses_persisted_ownership_and_current_promotions() {
        let directory = tempfile::tempdir().unwrap();
        let gateway = crate::test_support::TestGateway::new();
        let host = gateway.host_identity().await.unwrap().host_id;
        let home = directory.path().join("codex");
        let origin = Origin {
            host: host.clone(),
            provider: "codex".into(),
            provider_home: home.clone(),
            local_home: home.clone(),
        };
        let root = "8c43d12f-8038-5d28-be95-ef14cc47faf3";
        let child = "0e1a0399-0e3d-5aa4-ace7-0ed28835d55f";
        std::fs::create_dir_all(origin.path()).unwrap();
        for (id, parent, message) in [
            (root, None, "parent conversation"),
            (child, Some(root), "ownershipneedle"),
        ] {
            let records = [
                json!({"type":"session_meta","timestamp":"2026-11-01T10:00:00Z","payload":{"id":id,"cwd":"/fixture","source":{"subagent":{"thread_spawn":{"parent_thread_id":parent}}}}}),
                json!({"type":"event_msg","payload":{"type":"user_message","message":message}}),
            ];
            std::fs::write(
                origin.path().join(format!("{id}.jsonl")),
                records
                    .iter()
                    .map(|record| format!("{record}\n"))
                    .collect::<String>(),
            )
            .unwrap();
        }
        let store = Store::open(directory.path().join("sessions/catalog.sqlite3")).unwrap();
        crate::sessions::ingest::scan(
            &store,
            std::slice::from_ref(&origin),
            &std::sync::atomic::AtomicBool::new(false),
        )
        .unwrap();
        let worker = Arc::new(
            Worker::start(
                store.clone(),
                vec![origin.clone()],
                directory.path().join("cap-status.json"),
            )
            .unwrap(),
        );
        let stopping = worker.clone();
        tokio::task::spawn_blocking(move || stopping.stop())
            .await
            .unwrap()
            .unwrap();
        gateway
            .session_runtime
            .set(Arc::new(Runtime {
                store,
                origins: vec![origin.clone()],
                worker,
                readers: Arc::new(Semaphore::new(16)),
                search_readers: Arc::new(Semaphore::new(2)),
                mirror_lock: Mutex::new(()),
                mirror_failures: Arc::default(),
                mirror_stop: tokio_util::sync::CancellationToken::new(),
                mirror_task: Mutex::new(None),
            }))
            .unwrap_or_else(|_| panic!("fresh sessions runtime"));
        let identity = |thread: &str| ConversationIdentity {
            provider: Provider::Codex,
            provider_home: ProviderHome::Known { path: home.clone() },
            thread_id: thread.into(),
        };
        let jobs = gateway.jobs.store().await.unwrap();
        jobs.adopt_conversation(AgentRecord {
            agent_id: "search-child".into(),
            conversation: ConversationBinding::Known {
                conversation: identity(child),
            },
            origin: JobOrigin::Parent {
                conversation: identity(root),
            },
            tool_scope: None,
            origin_job_id: None,
            latest_job_id: None,
            parent: Some(AgentAddress {
                host_id: host,
                thread_id: root.into(),
            }),
            parent_revision: 0,
            parent_recipient: Some(Recipient::Conversation {
                conversation: identity(root),
            }),
        })
        .await
        .unwrap();
        {
            let runtime = gateway.session_runtime.get().unwrap();
            let mut db = runtime.store.writer().unwrap();
            crate::sessions::metadata::parents(
                &db,
                &runtime.origins,
                &jobs.catalog_parents().await.unwrap(),
            )
            .unwrap();
            while crate::sessions::index::rebuild_one(&mut db).unwrap() {}
        }
        let grant = crate::auth::installation_credentials::Grant::Operator;
        let response = gateway
            .sessions_rpc(
                &grant,
                "sessions/conversations/search",
                json!({"query":"ownershipneedle","limit":30}),
            )
            .await
            .unwrap();
        assert_eq!(
            response["conversations"][0]["sessionKey"],
            crate::sessions::session_key(&origin, root)
        );
        assert_eq!(
            response["conversations"][0]["hits"][0]["agentThreadId"],
            child
        );
        jobs.set_parent_for_test("search-child".into(), None, Recipient::None)
            .await
            .unwrap();
        {
            let runtime = gateway.session_runtime.get().unwrap();
            let mut db = runtime.store.writer().unwrap();
            crate::sessions::metadata::parents(
                &db,
                &runtime.origins,
                &jobs.catalog_parents().await.unwrap(),
            )
            .unwrap();
            while crate::sessions::index::rebuild_one(&mut db).unwrap() {}
        }
        let response = gateway
            .sessions_rpc(
                &grant,
                "sessions/conversations/search",
                json!({"query":"ownershipneedle","limit":30}),
            )
            .await
            .unwrap();
        assert_eq!(
            response["conversations"][0]["sessionKey"],
            crate::sessions::session_key(&origin, child)
        );
        assert!(response["conversations"][0]["hits"][0]["agentThreadId"].is_null());
        for params in [
            json!({"query":"needle"}),
            json!({"query":"needle","limit":0}),
            json!({"query":"needle","limit":1,"local":true}),
        ] {
            assert_eq!(
                gateway
                    .sessions_rpc(&grant, "sessions/conversations/search", params)
                    .await
                    .unwrap_err()
                    .code,
                RpcCode::InvalidParams
            );
        }
    }
}
