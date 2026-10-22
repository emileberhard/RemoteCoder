use super::{CacheAdmission, HistoryIndex, MAX_HEADER_CACHE_ENTRIES};
use anyhow::{Context, Result, ensure};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::sync::{Semaphore, watch};

type Outcome = std::result::Result<Arc<Vec<Value>>, Arc<str>>;
type Pending = Arc<watch::Sender<Option<Outcome>>>;
const SCAN_WAITER_LIMIT: usize = 64;

#[derive(Default)]
struct State {
    index: HistoryIndex,
    generation: u64,
    pending: Option<Pending>,
    changed: HashSet<PathBuf>,
    discard_scan: bool,
    reads: HashMap<PathBuf, Arc<()>>,
}

pub(super) struct Headers {
    state: Mutex<State>,
    readers: Arc<Semaphore>,
}

impl Default for Headers {
    fn default() -> Self {
        Self {
            state: Mutex::new(State::default()),
            readers: Arc::new(Semaphore::new(32)),
        }
    }
}

struct Scan {
    owner: Arc<Headers>,
    pending: Pending,
    generation: u64,
    completed: bool,
}

impl Headers {
    pub(super) async fn read(self: &Arc<Self>, home: PathBuf, uuid: String) -> Result<Value> {
        self.read_with(home, uuid, |index, path| index.header(path))
            .await
    }

    async fn read_with(
        self: &Arc<Self>,
        home: PathBuf,
        uuid: String,
        read: impl FnOnce(&mut HistoryIndex, &std::path::Path) -> Result<Option<Value>> + Send + 'static,
    ) -> Result<Value> {
        let permit = Arc::clone(&self.readers)
            .acquire_owned()
            .await
            .context("Claude header read owner stopped")?;
        let owner = Arc::clone(self);
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let path = super::resolve_session_path(&uuid, &home)?;
            let stamp = Arc::new(());
            let previous = {
                let mut state = owner.state.lock().expect("Claude headers poisoned");
                state.reads.insert(path.clone(), Arc::clone(&stamp));
                state.index.entries.get(&path).cloned()
            };
            let mut index = HistoryIndex::default();
            if let Some(entry) = &previous {
                index.entries.insert(path.clone(), entry.clone());
                index.cache_bytes = entry.bytes;
            }
            let result = read(&mut index, &path);
            let mut state = owner.state.lock().expect("Claude headers poisoned");
            let current = state.index.entries.get(&path).cloned();
            let current_read = state
                .reads
                .get(&path)
                .is_some_and(|current| Arc::ptr_eq(current, &stamp));
            if current_read {
                state.reads.remove(&path);
            }
            if current_read
                && match (&previous, current.as_ref()) {
                    (Some(previous), Some(current)) => Arc::ptr_eq(previous, current),
                    (None, None) => true,
                    _ => false,
                }
            {
                if state.pending.is_some() {
                    if state.changed.len() < MAX_HEADER_CACHE_ENTRIES {
                        state.changed.insert(path.clone());
                    } else {
                        state.discard_scan = true;
                    }
                }
                state.generation = state.generation.wrapping_add(1);
                state.index.header_scans =
                    state.index.header_scans.wrapping_add(index.header_scans);
                if result.is_ok() {
                    state.index.store(
                        path,
                        index.entries.pop().map(|(_, entry)| entry),
                        CacheAdmission::Read,
                    );
                }
            }
            result?.context("Claude session has no timestamped conversation activity")
        })
        .await
        .context("Claude history worker failed")?
    }

    pub(super) async fn list(self: &Arc<Self>, home: PathBuf) -> Result<Arc<Vec<Value>>> {
        self.scan(move |index| index.list_threads(&home, usize::MAX))
            .await
    }

    async fn scan(
        self: &Arc<Self>,
        read: impl FnOnce(&mut HistoryIndex) -> Result<Vec<Value>> + Send + 'static,
    ) -> Result<Arc<Vec<Value>>> {
        let mut receiver = {
            let mut state = self.state.lock().expect("Claude headers poisoned");
            if let Some(pending) = &state.pending {
                ensure!(
                    pending.receiver_count() < SCAN_WAITER_LIMIT,
                    "Claude history scan has too many waiting readers"
                );
                pending.subscribe()
            } else {
                let (sender, receiver) = watch::channel(None);
                let pending = Arc::new(sender);
                state.pending = Some(pending.clone());
                state.changed.clear();
                state.discard_scan = false;
                let mut index = state.index.clone();
                let scans_before = index.header_scans;
                let mut scan = Scan {
                    owner: Arc::clone(self),
                    pending,
                    generation: state.generation,
                    completed: false,
                };
                tokio::task::spawn_blocking(move || {
                    let result = read(&mut index);
                    scan.complete(result, index, scans_before);
                });
                receiver
            }
        };
        loop {
            let outcome = receiver.borrow_and_update().clone();
            if let Some(outcome) = outcome {
                return outcome.map_err(|error| anyhow::anyhow!(error.to_string()));
            }
            receiver
                .changed()
                .await
                .context("Claude history scan ended without a result")?;
        }
    }
}

impl Scan {
    fn complete(&mut self, result: Result<Vec<Value>>, index: HistoryIndex, scans_before: u64) {
        let mut state = self.owner.state.lock().expect("Claude headers poisoned");
        if state
            .pending
            .as_ref()
            .is_some_and(|pending| Arc::ptr_eq(pending, &self.pending))
        {
            state.pending = None;
            if result.is_ok() {
                if state.generation == self.generation {
                    state.index = index;
                } else if !state.discard_scan {
                    let changed = std::mem::take(&mut state.changed);
                    let removed: Vec<_> = state
                        .index
                        .entries
                        .keys()
                        .filter(|path| {
                            !index.entries.contains_key(*path) && !changed.contains(*path)
                        })
                        .cloned()
                        .collect();
                    for path in removed {
                        state.index.remove_cached_header(&path);
                    }
                    state.index.header_scans = state
                        .index
                        .header_scans
                        .wrapping_add(index.header_scans.wrapping_sub(scans_before));
                    for (path, entry) in index.entries {
                        if !changed.contains(&path) {
                            state.index.store(path, Some(entry), CacheAdmission::Scan);
                        }
                    }
                }
            }
            state.generation = state.generation.wrapping_add(1);
            state.changed.clear();
        }
        self.completed = true;
        drop(state);
        self.pending.send_replace(Some(
            result
                .map(Arc::new)
                .map_err(|error| Arc::from(format!("{error:#}"))),
        ));
    }
}

impl Drop for Scan {
    fn drop(&mut self) {
        if !self.completed {
            self.complete(
                Err(anyhow::anyhow!("Claude history scan cancelled")),
                HistoryIndex::default(),
                0,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::{
        MAX_HEADER_CACHE_BYTES,
        tests::{message, session},
    };
    use super::*;
    use serde_json::json;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    #[tokio::test]
    async fn header_cache_evicts_by_bytes_and_serves_oversized_headers_without_retaining_them() {
        let home = tempfile::tempdir().unwrap();
        let index = Arc::new(Headers::default());
        for id in ["first", "second", "third"] {
            session(
                home.path(),
                id,
                &[
                    message("user", "2026-09-20T10:00:00Z"),
                    json!({"type":"custom-title", "customTitle":id.repeat(400_000)}),
                ],
            );
            let header = index
                .read(home.path().to_path_buf(), id.into())
                .await
                .unwrap();
            assert_eq!(header["name"], id.repeat(400_000));
            assert!(index.state.lock().unwrap().index.cache_bytes <= MAX_HEADER_CACHE_BYTES);
        }
        assert!(
            !index
                .state
                .lock()
                .unwrap()
                .index
                .entries
                .keys()
                .any(|path| path.file_stem().unwrap() == "first")
        );
        let reread = index
            .read(home.path().to_path_buf(), "first".into())
            .await
            .unwrap();
        assert_eq!(reread["name"], "first".repeat(400_000));
        session(
            home.path(),
            "oversized",
            &[
                message("user", "2026-09-20T10:00:00Z"),
                json!({"type":"custom-title", "customTitle":"x".repeat(MAX_HEADER_CACHE_BYTES)}),
            ],
        );
        assert_eq!(
            index
                .read(home.path().to_path_buf(), "oversized".into())
                .await
                .unwrap()["name"]
                .as_str()
                .unwrap()
                .len(),
            MAX_HEADER_CACHE_BYTES
        );
        assert!(
            !index
                .state
                .lock()
                .unwrap()
                .index
                .entries
                .keys()
                .any(|path| path.file_stem().unwrap() == "oversized")
        );
        assert_eq!(
            index
                .list(home.path().to_path_buf())
                .await
                .unwrap()
                .as_slice()
                .len(),
            4
        );
    }

    #[tokio::test]
    async fn discovery_opus_concurrent_header_misses_cache_independent_paths() {
        let home = tempfile::tempdir().unwrap();
        let ids = [
            "11111111-2222-4333-8444-555555555555",
            "22222222-2222-4333-8444-555555555555",
        ];
        for id in ids {
            super::super::tests::session(
                home.path(),
                id,
                &[super::super::tests::message("user", "2026-09-20T10:00:00Z")],
            );
        }
        let owner = Arc::new(Headers::default());
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let mut tasks = Vec::new();
        for id in ids {
            let owner = Arc::clone(&owner);
            let home = home.path().to_path_buf();
            let barrier = Arc::clone(&barrier);
            tasks.push(tokio::spawn(async move {
                owner
                    .read_with(home, id.into(), move |index, path| {
                        barrier.wait();
                        index.header(path)
                    })
                    .await
            }));
        }
        for task in tasks {
            task.await.unwrap().unwrap();
        }
        let state = owner.state.lock().unwrap();
        assert_eq!(
            state.index.entries.len(),
            2,
            "an unrelated miss invalidated a header result"
        );
        assert!(state.reads.is_empty());
    }

    #[tokio::test]
    async fn a_slow_full_scan_is_coalesced_and_cannot_block_or_overwrite_a_header_read() {
        let home = tempfile::tempdir().unwrap();
        let id = "11111111-2222-4333-8444-555555555555";
        let path = super::super::tests::session(
            home.path(),
            id,
            &[super::super::tests::message("user", "2026-09-20T10:00:00Z")],
        );
        let owner = Arc::new(Headers::default());
        let count = Arc::new(AtomicUsize::new(0));
        let (started_tx, started) = tokio::sync::oneshot::channel();
        let (release, resumed) = std::sync::mpsc::channel();
        let scan_owner = Arc::clone(&owner);
        let scan_home = home.path().to_path_buf();
        let observed = Arc::clone(&count);
        let first = tokio::spawn(async move {
            scan_owner
                .scan(move |index| {
                    observed.fetch_add(1, Ordering::SeqCst);
                    let rows = index.list_threads(&scan_home, usize::MAX)?;
                    started_tx.send(()).unwrap();
                    resumed.recv().unwrap();
                    Ok(rows)
                })
                .await
        });
        started.await.unwrap();
        let observed = Arc::clone(&count);
        let second = owner.scan(move |_| {
            observed.fetch_add(1, Ordering::SeqCst);
            Ok(Vec::new())
        });
        tokio::pin!(second);
        assert!(futures_util::poll!(&mut second).is_pending());
        let mut updated = super::super::tests::message("user", "2026-09-20T11:00:00Z");
        updated["message"]["content"] = json!("Newer prompt");
        super::super::tests::session(home.path(), id, &[updated]);
        let read = tokio::time::timeout(
            Duration::from_millis(500),
            owner.read(home.path().into(), id.into()),
        )
        .await;
        release.send(()).unwrap();
        let header = read.expect("header waited for the full scan").unwrap();
        assert_eq!(header["preview"], "Newer prompt");
        let first = first.await.unwrap().unwrap();
        let second = second.await.unwrap();
        assert!(Arc::ptr_eq(&first, &second));
        assert_eq!(count.load(Ordering::SeqCst), 1);
        let path = path.canonicalize().unwrap();
        let state = owner.state.lock().unwrap();
        let cached = state.index.entries.get(&path).unwrap();
        assert_eq!(cached.header.as_ref().unwrap()["preview"], "Newer prompt");
    }
}
