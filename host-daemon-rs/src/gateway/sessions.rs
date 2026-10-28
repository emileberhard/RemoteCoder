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
    origins: Vec<Origin>,
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
                let host = local_cluster().0;
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
                    let worker = Arc::new(Worker::start(store.clone(), origins.clone())?);
                    Ok(Arc::new(Runtime {
                        store,
                        worker,
                        origins,
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
        if !runtime.store.path.with_file_name("mirror.enabled").exists() {
            return Ok(json!({"enabled":false}));
        }
        let Some(_guard) = runtime.mirror_lock.try_lock().ok() else {
            return Ok(json!({"running":true}));
        };
        let (_, members, call) = local_cluster();
        let mut outcomes = Vec::new();
        for host in members {
            let member = host.clone();
            let caller = call.clone();
            let callback: mirror::Call = Arc::new(move |method: &'static str, params: Value| {
                caller(member.clone(), method.into(), params)
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
        let origins = runtime.origins.clone();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            if after.is_none() {
                crate::sessions::ingest::refresh_inventory(&store, &origins)?;
            }
            query::inventory(&store.reader()?, after.as_deref(), limit)
        })
        .await?
    }

    pub(crate) async fn sessions_rpc(self: &Arc<Self>, method: &str, params: Value) -> RpcResult {
        self.session_request(method, params)
            .await
            .map_err(session_error)
    }

    async fn session_request(&self, method: &str, params: Value) -> Result<Value> {
        let runtime = self.sessions_runtime().await?.clone();
        let (host, members, call) = local_cluster();
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
        if method == "sessions/mirror/set" {
            #[derive(serde::Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Enabled {
                enabled: bool,
            }
            let enabled: Enabled = serde_json::from_value(params)?;
            let path = runtime.store.path.with_file_name("mirror.enabled");
            if enabled.enabled {
                crate::storage::private_state::replace(&path, b"1")?;
            } else if path.exists() {
                std::fs::remove_file(path)?;
            }
            return Ok(json!({"enabled":enabled.enabled}));
        }
        if method == "sessions/mirror/status" {
            return Ok(
                json!({"enabled":runtime.store.path.with_file_name("mirror.enabled").exists(),"coverage":query::coverage(&runtime.store.reader()?)?}),
            );
        }
        let permit = runtime.readers.clone().acquire_owned().await?;
        let store = runtime.store.clone();
        let method = method.to_owned();
        let request = if method == "sessions/search" {
            Some(serde_json::from_value::<query::Search>(params.clone())?)
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
                        let cursors:std::collections::BTreeMap<String,Option<String>>=request.cursor.as_deref().map(serde_json::from_str).transpose()?.unwrap_or_default();
                        if cursors.contains_key("local") && cursors["local"].is_none() {return Ok(json!({"hits":[],"cursor":null,"coverage":query::coverage(&store.reader()?)?}));}
                        request.cursor=cursors.get("local").cloned().flatten();
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
            return cluster::search(output, members, request, call).await;
        }
        Ok(output)
    }
}

fn local_cluster() -> (String, Vec<String>, cluster::MemberCall) {
    (
        "local".into(),
        Vec::new(),
        Arc::new(|_, _, _| {
            async { anyhow::bail!("Cluster link is not wired in this stage") }.boxed()
        }),
    )
}

fn session_error(error: anyhow::Error) -> RpcError {
    let message = format!("{error:#}");
    let kind = if message.starts_with("cursor_expired:") {
        "cursor_expired"
    } else if message.starts_with("source_changed:") {
        "source_changed"
    } else {
        "sessions_error"
    };
    RpcError::new(RpcCode::InvalidParams, message)
        .with_data(RpcData::Raw(json!({"kind":kind,"retryable":false})))
}
