use super::{HistoryError, Projection};
use crate::storage::file_revision::FileRevision;
use anyhow::{Context, Result};
use std::collections::HashMap;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, Weak};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CacheOutcome {
    Hit,
    Built,
    Uncached,
}

impl CacheOutcome {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            CacheOutcome::Hit => "hit",
            CacheOutcome::Built => "built",
            CacheOutcome::Uncached => "uncached",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct CacheKey {
    session: FileRevision,
    index: Option<FileRevision>,
    active_turn: Option<String>,
}

struct CacheEntry {
    key: CacheKey,
    sampled: tokio::time::Instant,
    projection: Arc<Projection>,
    bytes: usize,
    used: u64,
}

#[derive(Default)]
struct CacheState {
    entries: HashMap<PathBuf, CacheEntry>,
    gates: HashMap<PathBuf, Weak<BuildGate>>,
    bytes: usize,
    clock: u64,
}

pub(crate) struct ProjectionCache {
    budget: usize,
    state: Mutex<CacheState>,
}

#[derive(Default)]
struct BuildGate {
    building: Mutex<bool>,
    changed: Condvar,
}

impl BuildGate {
    fn enter(&self, check: &dyn Fn() -> Result<()>) -> Result<BuildGuard<'_>> {
        let mut building = self.building.lock().expect("projection gate poisoned");
        while *building {
            check()?;
            building = self
                .changed
                .wait_timeout(building, std::time::Duration::from_millis(25))
                .expect("projection gate poisoned")
                .0;
        }
        check()?;
        *building = true;
        Ok(BuildGuard(self))
    }
}

struct BuildGuard<'a>(&'a BuildGate);

impl Drop for BuildGuard<'_> {
    fn drop(&mut self) {
        *self.0.building.lock().expect("projection gate poisoned") = false;
        self.0.changed.notify_all();
    }
}

impl ProjectionCache {
    pub fn new(budget: usize) -> Self {
        Self {
            budget,
            state: Mutex::new(CacheState::default()),
        }
    }

    pub(crate) fn read<T>(
        &self,
        home: &Path,
        thread_id: &str,
        path: &Path,
        active_turn: Option<&str>,
        check: &dyn Fn() -> Result<()>,
        read: impl FnOnce(&Projection, &File) -> Result<T, HistoryError>,
    ) -> Result<(T, CacheOutcome), HistoryError> {
        check()?;
        let file =
            File::open(path).with_context(|| format!("failed opening {}", path.display()))?;
        let session = FileRevision::from(
            file.metadata()
                .with_context(|| format!("failed reading {}", path.display()))?,
        );
        let key = CacheKey {
            index: crate::providers::claude::conversation_index::revision(home, thread_id)?,
            session,
            active_turn: active_turn.map(str::to_string),
        };
        let gate = self.gate(path);
        let (projection, outcome) = {
            let _building = gate.enter(check)?;
            match self.cached(path, &key) {
                Some(projection) => (projection, CacheOutcome::Hit),
                None => {
                    let index =
                        crate::providers::claude::conversation_index::read(home, thread_id)?;
                    let projection = Arc::new(Projection::build_checked(
                        &file,
                        key.session.length,
                        &index,
                        active_turn,
                        Some(check),
                    )?);
                    let outcome = self.insert(path, key, Arc::clone(&projection));
                    (projection, outcome)
                }
            }
        };
        check()?;
        Ok((read(&projection, &file)?, outcome))
    }

    fn state(&self) -> std::sync::MutexGuard<'_, CacheState> {
        self.state.lock().expect("projection cache poisoned")
    }

    fn gate(&self, path: &Path) -> Arc<BuildGate> {
        let mut state = self.state();
        if let Some(gate) = state.gates.get(path).and_then(Weak::upgrade) {
            return gate;
        }
        state.gates.retain(|_, gate| gate.strong_count() > 0);
        let gate = Arc::new(BuildGate::default());
        state
            .gates
            .insert(path.to_path_buf(), Arc::downgrade(&gate));
        gate
    }

    fn cached(&self, path: &Path, key: &CacheKey) -> Option<Arc<Projection>> {
        let mut state = self.state();
        state.clock += 1;
        let clock = state.clock;
        let entry = state.entries.get_mut(path).filter(|entry| {
            entry.key == *key && entry.key.session.can_reuse(&key.session, entry.sampled)
        })?;
        entry.used = clock;
        Some(Arc::clone(&entry.projection))
    }

    fn insert(&self, path: &Path, key: CacheKey, projection: Arc<Projection>) -> CacheOutcome {
        let bytes = projection.estimated_bytes();
        let mut state = self.state();
        if let Some(previous) = state.entries.remove(path) {
            state.bytes -= previous.bytes;
        }
        if bytes > self.budget {
            return CacheOutcome::Uncached;
        }
        while state.bytes + bytes > self.budget {
            let Some(oldest) = state
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.used)
                .map(|(path, _)| path.clone())
            else {
                break;
            };
            if let Some(evicted) = state.entries.remove(&oldest) {
                state.bytes -= evicted.bytes;
            }
        }
        state.clock += 1;
        let used = state.clock;
        state.bytes += bytes;
        state.entries.insert(
            path.to_path_buf(),
            CacheEntry {
                key,
                sampled: tokio::time::Instant::now(),
                projection,
                bytes,
                used,
            },
        );
        CacheOutcome::Built
    }
}
