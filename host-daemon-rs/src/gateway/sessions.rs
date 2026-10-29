use super::Gateway;
use crate::rpc::error::{RpcCode, RpcData};
use crate::rpc::{RpcError, RpcResult};
use crate::sessions::{Origin, changes, cluster, mirror, query, store::Store, worker::Worker};
use anyhow::{Context, Result};
use futures_util::FutureExt;
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::sync::{Mutex, Semaphore};

pub(super) struct Runtime {
    store: Store,
    worker: Arc<Worker>,
    readers: Arc<Semaphore>,
    mirror_lock: Mutex<()>,
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
                tokio::task::spawn_blocking(move || -> Result<Arc<Runtime>> {
                    let store = Store::open(root.join("catalog.sqlite3"))?;
                    let worker = Arc::new(Worker::start(store.clone(), origins)?);
                    Ok(Arc::new(Runtime {
                        store,
                        worker,
                        readers: Arc::new(Semaphore::new(16)),
                        mirror_lock: Mutex::new(()),
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
            loop {
                tokio::select! {
                    _=stop.cancelled()=>break,
                    _=tokio::time::sleep(std::time::Duration::from_secs(5))=>{}
                }
                let Some(gateway) = weak.upgrade() else {
                    break;
                };
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
            match mirror::sync(&runtime.store, &host, callback, runtime.mirror_stop.clone()).await {
                Ok(value) => outcomes.push(json!({"host":host,"result":value})),
                Err(error) => {
                    let message = format!("{error:#}");
                    runtime.store.writer()?.execute("INSERT INTO coverage(origin_host,mode,stale_reason) VALUES(?1,'mirror',?2) ON CONFLICT(origin_host) DO UPDATE SET stale_reason=excluded.stale_reason",rusqlite::params![host,message])?;
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
        self.session_request(grant, method, params)
            .await
            .map_err(session_error)
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
                "sessions/changes"=>changes::read(&store.reader()?,serde_json::from_value(params)?),
                "sessions/mirror/list"=>{
                    #[derive(serde::Deserialize)]
                    #[serde(deny_unknown_fields)]
                    struct List {cursor:Option<String>}
                    let request:List=serde_json::from_value(params)?;
                    mirror::list(&store,&host,request.cursor)
                }
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
