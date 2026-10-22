//! Short registry operations and independent per-conversation command ordering.
//! No global guard is retained across a provider control exchange.
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex as StdMutex, Weak};
use tokio::sync::{Mutex, OwnedMutexGuard};

#[derive(Default)]
pub(crate) struct ThreadLifecycles {
    locks: StdMutex<HashMap<String, Weak<Mutex<()>>>>,
}

impl ThreadLifecycles {
    pub(crate) async fn lock(&self, thread_id: &str) -> OwnedMutexGuard<()> {
        let lock = {
            let mut locks = self
                .locks
                .lock()
                .expect("thread lifecycle registry poisoned");
            locks.retain(|_, lock| lock.strong_count() > 0);
            match locks.get(thread_id).and_then(Weak::upgrade) {
                Some(lock) => lock,
                None => {
                    let lock = Arc::new(Mutex::new(()));
                    locks.insert(thread_id.to_owned(), Arc::downgrade(&lock));
                    lock
                }
            }
        };
        lock.lock_owned().await
    }
}

/// A start owns capacity even before its runtime is registered. The set is
/// synchronously released on success, failure, or cancellation of its future.
#[derive(Debug)]
pub(crate) struct StartReservation {
    pub thread_id: String,
    pub starts: Arc<StdMutex<HashSet<String>>>,
}

impl Drop for StartReservation {
    fn drop(&mut self) {
        self.starts
            .lock()
            .expect("Claude start reservations poisoned")
            .remove(&self.thread_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn unrelated_threads_progress_while_the_same_thread_remains_ordered() {
        let owners = Arc::new(ThreadLifecycles::default());
        let first = owners.lock("a").await;
        let waiting = tokio::spawn({
            let owners = Arc::clone(&owners);
            async move { owners.lock("a").await }
        });
        let other = tokio::time::timeout(std::time::Duration::from_millis(100), owners.lock("b"))
            .await
            .unwrap();
        assert!(!waiting.is_finished());
        drop(other);
        drop(first);
        drop(waiting.await.unwrap());
        drop(owners.lock("c").await);
        assert!(owners.locks.lock().unwrap().len() <= 1);
    }
}
