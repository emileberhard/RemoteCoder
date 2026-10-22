use super::Gateway;
use anyhow::{Result, ensure};
use std::future::Future;
use tokio_util::sync::CancellationToken;

impl Gateway {
    pub(crate) fn spawn_account_reset<F, Fut>(&self, operation: F) -> Result<()>
    where
        F: FnOnce(CancellationToken) -> Fut + Send + 'static,
        Fut: Future<Output = Result<()>> + Send + 'static,
    {
        ensure!(!self.is_draining(), crate::accounts::GatewayStopping);
        let permit = self
            .reset_capacity
            .clone()
            .try_acquire_owned()
            .map_err(|_| crate::accounts::AccountsBusy)?;
        ensure!(
            self.reset_tasks
                .spawn_graceful("account reset", move |shutdown| async move {
                    let _permit = permit;
                    operation(shutdown).await
                }),
            crate::accounts::GatewayStopping
        );
        Ok(())
    }
}
