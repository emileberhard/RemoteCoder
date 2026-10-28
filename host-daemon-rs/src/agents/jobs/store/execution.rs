use std::collections::HashMap;
use std::sync::{Arc, Weak};

use anyhow::{Context, Result, ensure};
use tokio::sync::{Mutex, OwnedRwLockReadGuard, OwnedRwLockWriteGuard, RwLock};

use super::*;

#[derive(Default)]
pub(super) struct ExecutionGates(Mutex<HashMap<JobId, Weak<RwLock<()>>>>);

pub(crate) struct MessageExecution {
    _admission: OwnedRwLockReadGuard<()>,
}

impl ExecutionGates {
    async fn gate(&self, id: &JobId) -> Result<Arc<RwLock<()>>> {
        let mut gates = self.0.lock().await;
        gates.retain(|_, gate| gate.strong_count() > 0);
        if let Some(gate) = gates.get(id).and_then(Weak::upgrade) {
            return Ok(gate);
        }
        ensure!(
            gates.len() < MAX_UNSETTLED_JOBS,
            "job execution admission is at capacity"
        );
        let gate = Arc::new(RwLock::new(()));
        gates.insert(id.clone(), Arc::downgrade(&gate));
        Ok(gate)
    }

    pub(super) async fn mutation(&self, id: &JobId) -> Result<OwnedRwLockWriteGuard<()>> {
        Ok(self.gate(id).await?.write_owned().await)
    }
}

impl JobStore {
    pub(crate) async fn message_execution(&self, id: JobId) -> Result<MessageExecution> {
        let gate = self.executions.gate(&id).await?;
        let admission = gate.read_owned().await;
        self.access(move |inner| {
            let job = inner.job(&id)?;
            ensure!(
                inner.agent_view(&job.agent_id)?.latest_job_id.as_ref() == Some(&id),
                "the frozen target job was superseded"
            );
            ensure!(
                matches!(job.stop, StopState::NotRequested),
                "the frozen target job was explicitly stopped"
            );
            ensure!(
                !matches!(job.execution, ExecutionState::Terminal { .. }),
                "the frozen target job has already finished"
            );
            Ok(())
        })
        .await
        .context("message target execution could not be admitted")?;
        Ok(MessageExecution {
            _admission: admission,
        })
    }
}
