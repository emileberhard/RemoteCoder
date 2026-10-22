//! Finite owners for asynchronous operations. Closing admission and joining are
//! distinct: every shutdown caller waits for the actual tracked destructors.
use std::future::Future;
use std::panic::AssertUnwindSafe;
use std::sync::Mutex;

use futures_util::FutureExt;
use tokio_util::{sync::CancellationToken, task::TaskTracker};

#[derive(Default)]
pub(crate) struct OwnedTasks {
    closed: Mutex<bool>,
    tracker: TaskTracker,
    shutdown: CancellationToken,
}

impl OwnedTasks {
    pub(crate) fn spawn(
        &self,
        label: &'static str,
        work: impl Future<Output = anyhow::Result<()>> + Send + 'static,
    ) -> bool {
        self.spawn_graceful(label, move |shutdown| async move {
            match shutdown.run_until_cancelled(work).await {
                Some(result) => result,
                None => Ok(()),
            }
        })
    }

    /// The operation chooses safe cancellation boundaries, e.g. finish creating
    /// a voice session before its owning connection can stop that session.
    pub(crate) fn spawn_graceful<F, Fut>(&self, label: &'static str, work: F) -> bool
    where
        F: FnOnce(CancellationToken) -> Fut,
        Fut: Future<Output = anyhow::Result<()>> + Send + 'static,
    {
        let closed = self.closed.lock().expect("task admission poisoned");
        if *closed {
            return false;
        }
        let future = work(self.shutdown.child_token());
        self.tracker.spawn(async move {
            match AssertUnwindSafe(future).catch_unwind().await {
                Ok(Ok(())) => {}
                Ok(Err(error)) => tracing::warn!(label, %error, "owned operation failed"),
                Err(_) => tracing::error!(label, "owned operation panicked"),
            }
        });
        true
    }

    pub(crate) async fn stop(&self) {
        {
            let mut closed = self.closed.lock().expect("task admission poisoned");
            *closed = true;
            self.tracker.close();
            self.shutdown.cancel();
        }
        self.tracker.wait().await;
    }
}

impl Drop for OwnedTasks {
    fn drop(&mut self) {
        self.shutdown.cancel();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use tokio::sync::oneshot;

    #[tokio::test]
    async fn every_stop_waits_for_graceful_cleanup_and_new_work_is_rejected() {
        let owner = Arc::new(OwnedTasks::default());
        let (ready, ready_rx) = oneshot::channel();
        let (release, release_rx) = oneshot::channel();
        assert!(owner.spawn_graceful("test", |shutdown| async move {
            shutdown.cancelled().await;
            ready.send(()).unwrap();
            release_rx.await.unwrap();
            Ok(())
        }));
        let first = tokio::spawn({
            let owner = Arc::clone(&owner);
            async move { owner.stop().await }
        });
        ready_rx.await.unwrap();
        assert!(!owner.spawn("too late", async { Ok(()) }));
        let second = tokio::spawn({
            let owner = Arc::clone(&owner);
            async move { owner.stop().await }
        });
        tokio::task::yield_now().await;
        assert!(!first.is_finished() && !second.is_finished());
        release.send(()).unwrap();
        first.await.unwrap();
        second.await.unwrap();
    }
}
