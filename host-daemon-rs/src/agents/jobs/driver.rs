use std::sync::Arc;
use std::time::Duration;

use anyhow::{Result, ensure};
use futures_util::{FutureExt, StreamExt, stream};

use super::model::JobId;
use super::owner::JobOwner;

impl JobOwner {
    pub(crate) fn start_driver(&self) -> Result<()> {
        if self.root.is_none() {
            return Ok(());
        }
        let gateway = self.gateway()?;
        let mut changes = self.changes();
        let mut provider_changes = gateway
            .job_claude()
            .ok()
            .map(|provider| provider.subscribe_job_changes());
        let admitted = self.tasks.spawn_graceful("delegated_jobs", move |shutdown| async move {
            let mut delay = Duration::from_millis(250);
            loop {
                if gateway.is_draining() { break; }
                let ids = gateway.jobs.store().await?.pending_ids().await?;
                let outcomes = stream::iter(ids).map(|id| {
                    let gateway = Arc::clone(&gateway);
                    async move {
                        let _operation = gateway.jobs.operations.read().await;
                        if gateway.is_draining() { return false; }
                        match gateway.jobs.reconcile_job(id.clone()).await {
                            Ok(retry) => retry,
                            Err(error) => {
                                tracing::warn!(job_id = id.as_str(), error = %format!("{error:#}"), "delegated job reconciliation is pending");
                                true
                            }
                        }
                    }
                }).buffer_unordered(16).collect::<Vec<_>>().await;
                let retry = outcomes.into_iter().any(|retry| retry);
                tokio::select! {
                    _ = shutdown.cancelled() => break,
                    result = changes.changed() => { if result.is_err() { break; } delay = Duration::from_millis(250); }
                    result = async { match &mut provider_changes { Some(changes) => changes.changed().await, None => std::future::pending().await } } => {
                        if result.is_err() { provider_changes = None; }
                        delay = Duration::from_millis(250);
                    }
                    _ = tokio::time::sleep(delay), if retry => { delay = (delay * 2).min(Duration::from_secs(60)); }
                }
            }
            Ok(())
        });
        ensure!(admitted, "delegated-job driver is already closed");
        Ok(())
    }

    pub(crate) async fn quiesce(&self) {
        {
            let _operations = self.operations.write().await;
        }
        self.tasks.stop().await;
    }

    pub(crate) async fn close_endpoints(&self) {
        let endpoints = std::mem::take(&mut *self.endpoints.lock().await);
        for (_, endpoint) in endpoints {
            endpoint.close().await;
        }
    }

    pub(super) async fn ensure_endpoint(&self, job: &super::model::JobRecord) -> Result<()> {
        let mut endpoints = self.endpoints.lock().await;
        if endpoints.contains_key(&job.job_id) {
            return Ok(());
        }
        let gateway = Arc::downgrade(&self.gateway()?);
        let handler: super::routes::ScopedHandler = Arc::new(move |id, peer, request| {
            let gateway = gateway.clone();
            async move {
                let Some(gateway) = gateway.upgrade() else {
                    return Err(crate::rpc::RpcError::draining());
                };
                gateway.scoped_job_rpc(id, peer, request).await
            }
            .boxed()
        });
        let endpoint = self
            .scopes
            .bind(
                &self.coordination_socket(&job.job_id),
                job.job_id.clone(),
                handler,
            )
            .await?;
        endpoints.insert(job.job_id.clone(), endpoint);
        Ok(())
    }

    pub(super) async fn close_endpoint(&self, id: &JobId) {
        let endpoint = self.endpoints.lock().await.remove(id);
        if let Some(endpoint) = endpoint {
            endpoint.close().await;
        }
    }

    pub(crate) async fn verify_peer(
        &self,
        id: &JobId,
        peer: crate::platform::process::ProcessInstance,
    ) -> Result<super::context::ProvenCaller> {
        let view = self.read(id).await?;
        let proven = self.gateway()?.job_process_context(peer).await?;
        ensure!(
            view.job.execution.conversation() == Some(&proven.conversation),
            "scoped socket does not belong to the actual calling provider process; capture context before detaching"
        );
        ensure!(
            view.agent
                .as_ref()
                .and_then(|agent| agent.latest_job_id.as_ref())
                == Some(id),
            "scoped socket belongs to a superseded job"
        );
        Ok(proven)
    }

    pub(crate) fn notify_provider_event(&self, message: &serde_json::Value) {
        let method = message["method"].as_str().unwrap_or_default();
        let relevant = matches!(
            method,
            "turn/started" | "turn/completed" | "thread/status/changed" | "thread/queue/changed"
        ) || method == "item/completed"
            && message
                .pointer("/params/item/type")
                .and_then(serde_json::Value::as_str)
                == Some("userMessage");
        if relevant {
            self.dirty();
        }
    }
}
