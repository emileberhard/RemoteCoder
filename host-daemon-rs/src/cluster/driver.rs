use crate::gateway::Gateway;
use crate::wire::cluster::*;
use anyhow::{Context, Result, ensure};
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;

impl Gateway {
    pub(crate) fn start_cluster_liveness(self: &Arc<Self>) -> Result<()> {
        use futures_util::{StreamExt, stream};
        let gateway = Arc::downgrade(self);
        let started = self.jobs.tasks.spawn_graceful("cluster_liveness", move |shutdown| async move {
            let mut previous = std::time::SystemTime::now();
            let mut first = true;
            let mut tick = tokio::time::interval(Duration::from_secs(2));
            let mut route = tokio::process::Command::new("/sbin/route")
                .args(["-n", "monitor"])
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .kill_on_drop(true)
                .spawn()?;
            use tokio::io::AsyncBufReadExt;
            let mut changes = tokio::io::BufReader::new(route.stdout.take().context("network monitor has no output")?).lines();
            let mut route_open = true;
            loop {
                let changed = tokio::select! {
                    _ = shutdown.cancelled() => break,
                    result = changes.next_line(), if route_open => {
                        route_open = result?.is_some();
                        route_open
                    }
                    _ = tick.tick() => {
                        let now = std::time::SystemTime::now();
                        let woke = now.duration_since(previous).is_ok_and(|elapsed| elapsed > Duration::from_secs(5));
                        previous = now;
                        woke
                    }
                };
                if !changed && !first {
                    continue;
                }
                first = false;
                let Some(gateway) = gateway.upgrade() else { break };
                let link = gateway.cluster_link().await?;
                let identity = gateway.host_identity().await?;
                let members = link.members().await?;
                stream::iter(members.into_iter().filter(|member| member.state == MemberState::Active))
                    .for_each_concurrent(64, |member| {
                        let link = link.clone();
                        let identity = identity.clone();
                        async move {
                            let _ = link.call(&member.host, "cluster/hello", json!({"protocol":PROTOCOL,"host":identity.host_id,"incarnation":identity.incarnation})).await;
                        }
                    }).await;
                gateway.jobs.dirty();
                previous = std::time::SystemTime::now();
            }
            route.start_kill()?;
            route.wait().await?;
            Ok(())
        });
        ensure!(started, "cluster liveness owner is closed");
        Ok(())
    }
}

pub(crate) fn start(gateway: &Arc<Gateway>) -> Result<()> {
    let weak = Arc::downgrade(gateway);
    let started = gateway
        .jobs
        .tasks
        .spawn_graceful("cluster_driver", move |shutdown| async move {
            let Some(gateway) = weak.upgrade() else {
                return Ok(());
            };
            let mut changes = gateway.jobs.changes();
            let mut workers = tokio::task::JoinSet::new();
            let mut running = std::collections::HashSet::new();
            let capacity = Arc::new(tokio::sync::Semaphore::new(64));
            loop {
                let link = gateway.cluster_link().await?;
                for member in link
                    .store
                    .all()
                    .await?
                    .into_iter()
                    .filter(|member| member.state != MemberState::Removed)
                {
                    if running.insert(member.membership.clone()) {
                        let weak = Arc::downgrade(&gateway);
                        let stop = shutdown.child_token();
                        let capacity = capacity.clone();
                        workers.spawn(async move {
                            let id = member.membership.clone();
                            let result = member_worker(weak, member, capacity, stop).await;
                            (id, result)
                        });
                    }
                }
                tokio::select! {
                    _ = shutdown.cancelled() => break,
                    result = changes.changed() => { if result.is_err() { break; } },
                    Some(result) = workers.join_next(), if !workers.is_empty() => {
                        let (id, result) = result?;
                        running.remove(&id);
                        if let Err(error) = result {
                            tracing::warn!(membership=id,%error,"cluster member driver stopped");
                            tokio::time::sleep(Duration::from_secs(1)).await;
                        }
                    }
                }
            }
            shutdown.cancel();
            while let Some(result) = workers.join_next().await {
                result?;
            }
            Ok(())
        });
    ensure!(started, "cluster driver owner is closed");
    Ok(())
}

async fn member_worker(
    gateway: std::sync::Weak<Gateway>,
    member: MemberRecord,
    capacity: Arc<tokio::sync::Semaphore>,
    shutdown: tokio_util::sync::CancellationToken,
) -> Result<()> {
    use futures_util::{StreamExt, stream};
    let Some(owner) = gateway.upgrade() else {
        return Ok(());
    };
    let mut changes = owner.jobs.changes();
    let link = owner.cluster_link().await?;
    let mut wakes = link.member_wakes(&member.host).await;
    drop(owner);
    let mut delay = Duration::from_millis(250);
    let mut due = tokio::time::Instant::now();
    let mut previous = String::new();
    let mut retry = false;
    loop {
        let Some(owner) = gateway.upgrade() else {
            break;
        };
        if owner.is_draining() {
            break;
        }
        let Some(record) = link.store.all().await?.into_iter().find(|record| {
            record.membership == member.membership && record.state != MemberState::Removed
        }) else {
            break;
        };
        let store = owner.jobs.store().await?;
        let mut ids = Vec::new();
        let mut key = Vec::new();
        for id in store.pending_ids().await? {
            let job = store.read(id.clone()).await?;
            if matches!(&job.recipient,crate::agents::jobs::model::Recipient::Remote {host,..} if host==&member.host)
            {
                key.push((id.as_str().to_owned(), job.revision));
                ids.push(id);
            }
        }
        let intents = store
            .intents()
            .await?
            .into_iter()
            .filter(|intent| intent.host == member.host)
            .map(|intent| (intent.request.job_id, intent.state, intent.stop_confirmed))
            .collect::<Vec<_>>();
        let current = crate::agents::jobs::store::fingerprint(&serde_json::to_vec(&(
            key,
            intents,
            record.state,
        ))?);
        if current != previous || retry && tokio::time::Instant::now() >= due {
            let permit =
                tokio::select! {_=shutdown.cancelled()=>break,permit=capacity.acquire()=>permit?};
            let attempted_ids = ids.clone();
            let attempted_intents = store
                .intents()
                .await?
                .into_iter()
                .filter(|intent| intent.host == member.host)
                .map(|intent| intent.request.job_id)
                .collect::<std::collections::HashSet<_>>();
            retry = owner.reconcile_cluster_member(&member.host).await?;
            let outcomes=stream::iter(ids).map(|id| {
                let owner=&owner;
                let host=&member.host;
                async move {
                    let _operation=owner.jobs.operations.read().await;
                    let store=owner.jobs.store().await?;
                    let job=store.retarget_delivery(id.clone()).await?;
                    if !matches!(&job.recipient,crate::agents::jobs::model::Recipient::Remote {host:receiver,..} if receiver==host) {owner.jobs.dirty();return Ok::<_,anyhow::Error>(false);}
                    let notices=owner.jobs.deliver_notices(&id).await?;
                    let job=store.read(id).await?;
                    match &job.execution {
                        crate::agents::jobs::model::ExecutionState::Terminal {terminal} if terminal.cleanup==crate::agents::jobs::model::CleanupState::Complete=>Ok(owner.jobs.deliver_completion(&job,terminal).await? || notices),
                        _=>Ok(notices),
                    }
                }
            }).buffer_unordered(64).collect::<Vec<_>>().await;
            for outcome in outcomes {
                match outcome {
                    Ok(pending) => retry |= pending,
                    Err(error) => {
                        tracing::warn!(host=member.host,%error,"remote delivery remains pending");
                        retry = true;
                    }
                }
            }
            drop(permit);
            let mut key = Vec::new();
            for id in attempted_ids {
                let job = store.read(id.clone()).await?;
                if matches!(&job.recipient,crate::agents::jobs::model::Recipient::Remote {host,..} if host==&member.host)
                {
                    key.push((id.as_str().to_owned(), job.revision));
                }
            }
            let intents = store
                .intents()
                .await?
                .into_iter()
                .filter(|intent| {
                    intent.host == member.host && attempted_intents.contains(&intent.request.job_id)
                })
                .map(|intent| (intent.request.job_id, intent.state, intent.stop_confirmed))
                .collect::<Vec<_>>();
            previous = crate::agents::jobs::store::fingerprint(&serde_json::to_vec(&(
                key,
                intents,
                record.state,
            ))?);
            due = tokio::time::Instant::now() + delay;
            delay = (delay * 2).min(Duration::from_secs(60));
        }
        drop(owner);
        tokio::select! {
            _=shutdown.cancelled()=>break,
            result=wakes.changed()=> {if result.is_err(){break;}delay=Duration::from_millis(250);due=tokio::time::Instant::now();retry=true;},
            result=changes.changed()=> {if result.is_err(){break;}},
            _=tokio::time::sleep_until(due),if retry=>{},
        }
    }
    Ok(())
}
