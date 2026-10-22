use super::{HistoryError, Projection};
use crate::storage::file_revision::FileRevision;
use anyhow::{Context, Result};
use std::collections::HashMap;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError, Weak};

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
    projection: Arc<Projection>,
    bytes: usize,
    used: u64,
}

#[derive(Default)]
struct CacheState {
    entries: HashMap<PathBuf, CacheEntry>,
    gates: HashMap<PathBuf, Weak<Mutex<()>>>,
    bytes: usize,
    clock: u64,
}

pub(crate) struct ProjectionCache {
    budget: usize,
    state: Mutex<CacheState>,
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
        read: impl FnOnce(&Projection, &File) -> Result<T, HistoryError>,
    ) -> Result<(T, CacheOutcome), HistoryError> {
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
            let _building = gate.lock().unwrap_or_else(PoisonError::into_inner);
            match self.cached(path, &key) {
                Some(projection) => (projection, CacheOutcome::Hit),
                None => {
                    let index =
                        crate::providers::claude::conversation_index::read(home, thread_id)?;
                    let projection = Arc::new(Projection::build(
                        &file,
                        key.session.length,
                        &index,
                        active_turn,
                    )?);
                    let outcome = self.insert(path, key, Arc::clone(&projection));
                    (projection, outcome)
                }
            }
        };
        Ok((read(&projection, &file)?, outcome))
    }

    fn state(&self) -> std::sync::MutexGuard<'_, CacheState> {
        self.state.lock().expect("projection cache poisoned")
    }

    fn gate(&self, path: &Path) -> Arc<Mutex<()>> {
        let mut state = self.state();
        if let Some(gate) = state.gates.get(path).and_then(Weak::upgrade) {
            return gate;
        }
        state.gates.retain(|_, gate| gate.strong_count() > 0);
        let gate = Arc::new(Mutex::new(()));
        state
            .gates
            .insert(path.to_path_buf(), Arc::downgrade(&gate));
        gate
    }

    fn cached(&self, path: &Path, key: &CacheKey) -> Option<Arc<Projection>> {
        let mut state = self.state();
        state.clock += 1;
        let clock = state.clock;
        let entry = state
            .entries
            .get_mut(path)
            .filter(|entry| entry.key == *key)?;
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
                projection,
                bytes,
                used,
            },
        );
        CacheOutcome::Built
    }
}
