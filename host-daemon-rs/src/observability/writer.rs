use std::sync::Mutex;
use std::time::Duration;

use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;
use tracing::warn;

#[derive(Debug, Default)]
pub(crate) struct WriterHandle {
    stop: CancellationToken,
    task: Mutex<Option<JoinHandle<()>>>,
}

impl WriterHandle {
    pub(crate) fn stop_signal(&self) -> CancellationToken {
        self.stop.clone()
    }

    pub(crate) fn attach(&self, task: JoinHandle<()>) {
        if let Ok(mut slot) = self.task.lock() {
            *slot = Some(task);
        }
    }

    pub(crate) async fn drain(&self, deadline: Duration, what: &'static str) {
        self.stop.cancel();
        let task = self.task.lock().ok().and_then(|mut slot| slot.take());
        let Some(task) = task else {
            return;
        };
        if tokio::time::timeout(deadline, task).await.is_err() {
            warn!(
                what,
                "log writer did not finish flushing before the shutdown deadline"
            );
        }
    }
}
