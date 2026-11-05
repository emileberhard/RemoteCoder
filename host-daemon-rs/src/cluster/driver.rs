use crate::gateway::Gateway;
use crate::wire::cluster::*;
use anyhow::{Result, ensure};
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;

const REPORT_RETRY_FLOOR: Duration = Duration::from_millis(500);
const REPORT_RETRY_CEILING: Duration = Duration::from_secs(30);

pub(crate) fn start(gateway: &Arc<Gateway>) -> Result<()> {
    let weak = Arc::downgrade(gateway);
    let started = gateway
        .jobs
        .tasks
        .spawn_graceful("cluster_driver", move |shutdown| async move {
            let Some(gateway) = weak.upgrade() else {
                return Ok(());
            };
            let mut changes = gateway.cluster_link().await?.store.changes().await;
            let mut workers = tokio::task::JoinSet::new();
            let mut running = std::collections::HashSet::new();
            let capacity = Arc::new(tokio::sync::Semaphore::new(64));
            loop {
                let link = gateway.cluster_link().await?;
                let members: Vec<_> = link
                    .store
                    .all()
                    .await?
                    .into_iter()
                    .filter(|member| member.state != MemberState::Removed)
                    .collect();
                gateway.retain_live_activity_peers(
                    &members.iter().map(|member| member.host.clone()).collect(),
                );
                for member in members {
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
                let (_, outcome) = result?;
                outcome?;
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
    let stop = shutdown.child_token();
    let host = member.host.clone();
    let (deliveries, reports) = tokio::join!(
        async {
            let result = member_deliveries(gateway.clone(), member, capacity, stop.clone()).await;
            stop.cancel();
            result
        },
        live_activity_reports(gateway.clone(), host, stop.clone()),
    );
    deliveries.and(reports)
}

async fn live_activity_reports(
    gateway: std::sync::Weak<Gateway>,
    host: String,
    stop: tokio_util::sync::CancellationToken,
) -> Result<()> {
    let Some(owner) = gateway.upgrade() else {
        return Ok(());
    };
    let link = owner.cluster_link().await?;
    let mut wakes = link.member_wakes(&host).await;
    let mut reports = owner.peer_live_activity_reports();
    drop(owner);
    let mut settled = false;
    let mut delay = REPORT_RETRY_FLOOR;
    loop {
        let report = reports.borrow_and_update().clone();
        if !settled && let Some(report) = &report {
            let params = json!(LiveActivityReportParams {
                protocol: PROTOCOL,
                projection: report.projection.clone(),
            });
            settled = match link
                .call(&host, "cluster/liveActivity/report", params)
                .await
            {
                Ok(reply) => reply["outcome"] == "accepted",
                Err(error) => error.class == ErrorClass::Unsupported,
            };
            delay = if settled {
                REPORT_RETRY_FLOOR
            } else {
                (delay * 2).min(REPORT_RETRY_CEILING)
            };
        }
        tokio::select! {
            _ = stop.cancelled() => break,
            changed = wakes.changed() => {
                if changed.is_err() { break; }
                settled = false;
            }
            changed = reports.changed() => {
                if changed.is_err() { break; }
                settled = false;
            }
            _ = tokio::time::sleep(jittered(delay)), if !settled && report.is_some() => {}
        }
    }
    Ok(())
}

fn jittered(delay: Duration) -> Duration {
    let fraction =
        f64::from(getrandom::u32().expect("operating system entropy")) / f64::from(u32::MAX);
    delay.mul_f64(0.5 + fraction / 2.0)
}

async fn member_deliveries(
    gateway: std::sync::Weak<Gateway>,
    member: MemberRecord,
    capacity: Arc<tokio::sync::Semaphore>,
    shutdown: tokio_util::sync::CancellationToken,
) -> Result<()> {
    use futures_util::{StreamExt, stream};
    let Some(owner) = gateway.upgrade() else {
        return Ok(());
    };
    let store = owner.jobs.store().await?.clone();
    let mut changes = store.member_changes(member.host.clone()).await?;
    let link = owner.cluster_link().await?;
    let mut membership_changes = link.store.changes().await;
    let mut wakes = link.member_wakes(&member.host).await;
    drop(owner);
    let mut delay = Duration::from_millis(250);
    loop {
        let Some(owner) = gateway.upgrade() else {
            break;
        };
        if owner.is_draining() {
            break;
        }
        let record = match link.store.resolve(&member.host).await {
            Ok(record)
                if record.membership == member.membership
                    && record.state != MemberState::Removed =>
            {
                record
            }
            _ => break,
        };
        let ids = store.member_pending_ids(member.host.clone()).await?;
        let permit =
            tokio::select! {_=shutdown.cancelled()=>break,permit=capacity.acquire()=>permit?};
        let mut retry = false;
        if record.state == MemberState::Active && !link.is_connected(&member.host).await {
            let identity = owner.host_identity().await?;
            retry = link
                    .call(
                        &member.host,
                        "cluster/hello",
                        json!({"protocol":PROTOCOL,"host":identity.host_id,"incarnation":identity.incarnation}),
                    )
                    .await
                    .is_err();
        }
        retry |= owner.reconcile_cluster_member(&member.host).await?;
        let outcomes=stream::iter(ids).map(|id| {
                let owner=&owner;
                let host=&member.host;
                async move {
                    let _operation=owner.jobs.operations.read().await;
                    let store=owner.jobs.store().await?;
                    let job=store.retarget_delivery(id).await?;
                    if !matches!(&job.recipient,crate::agents::jobs::model::Recipient::Remote {host:receiver,..} if receiver==host) {owner.jobs.dirty();return Ok::<_,anyhow::Error>(());}
                    owner.jobs.deliver_obligations(job).await
                }
            }).buffer_unordered(64).collect::<Vec<_>>().await;
        for outcome in outcomes {
            match outcome {
                Ok(()) => {}
                Err(error) => {
                    tracing::warn!(host=member.host,%error,"remote delivery remains pending");
                    retry = true;
                }
            }
        }
        drop(permit);
        let due = tokio::time::Instant::now() + delay;
        let delivery_due = owner.jobs.next_delivery_due();
        delay = (delay * 2).min(Duration::from_secs(60));
        drop(owner);
        tokio::select! {
            _=shutdown.cancelled()=>break,
            result = wakes.changed() => {
                if result.is_err() { break; }
                let Some(owner) = gateway.upgrade() else { break; };
                owner.jobs.expedite(&store.member_pending_ids(member.host.clone()).await?);
                delay = Duration::from_millis(250);
            },
            result=changes.changed()=> {if result.is_err(){break;}},
            result=membership_changes.changed()=> {if result.is_err(){break;}},
            _=tokio::time::sleep_until(due),if retry=>{},
            _=tokio::time::sleep_until(delivery_due.unwrap_or(due)),if delivery_due.is_some()=>{},
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
