use anyhow::Result;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

const MAX_INFLIGHT_THREADS: usize = 1024;

#[derive(Default)]
pub(crate) struct ConversationAdmission {
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    inflight: HashMap<String, usize>,
    exclusive: HashSet<String>,
}

#[derive(Debug)]
pub(crate) struct ConversationBusy(&'static str);

impl std::fmt::Display for ConversationBusy {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for ConversationBusy {}

pub(crate) struct Admission {
    owner: Arc<ConversationAdmission>,
    thread: String,
    exclusive: bool,
}

impl ConversationAdmission {
    pub(crate) fn admit(self: &Arc<Self>, thread: &str) -> Result<Admission> {
        self.admit_request(thread, false)
    }

    pub(crate) fn admit_compaction(self: &Arc<Self>, thread: &str) -> Result<Admission> {
        self.admit_request(thread, true)
    }

    fn admit_request(self: &Arc<Self>, thread: &str, exclusive: bool) -> Result<Admission> {
        let mut state = self.state.lock().expect("conversation admission poisoned");
        if state.exclusive.contains(thread) || (exclusive && state.inflight.contains_key(thread)) {
            return Err(ConversationBusy(
                "This conversation has a pending command; retry after it finishes",
            )
            .into());
        }
        if !state.inflight.contains_key(thread) && state.inflight.len() >= MAX_INFLIGHT_THREADS {
            return Err(ConversationBusy("Too many conversations have pending requests").into());
        }
        *state.inflight.entry(thread.to_owned()).or_default() += 1;
        if exclusive {
            state.exclusive.insert(thread.to_owned());
        }
        Ok(Admission {
            owner: self.clone(),
            thread: thread.to_owned(),
            exclusive,
        })
    }

    pub(crate) fn compacting_threads(&self) -> Vec<String> {
        self.state
            .lock()
            .expect("conversation admission poisoned")
            .exclusive
            .iter()
            .cloned()
            .collect()
    }
}

impl Drop for Admission {
    fn drop(&mut self) {
        let mut state = self
            .owner
            .state
            .lock()
            .expect("conversation admission poisoned");
        if self.exclusive {
            state.exclusive.remove(&self.thread);
        }
        if let Some(count) = state.inflight.get_mut(&self.thread) {
            *count -= 1;
            if *count == 0 {
                state.inflight.remove(&self.thread);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compaction_excludes_pending_requests_and_releases_on_drop() {
        let owner = Arc::new(ConversationAdmission::default());
        let send = owner.admit("source").unwrap();
        assert!(owner.admit_compaction("source").is_err());
        drop(send);
        let compact = owner.admit_compaction("source").unwrap();
        assert!(owner.admit("source").is_err());
        assert!(owner.admit_compaction("source").is_err());
        let unrelated = owner.admit("other").unwrap();
        drop(compact);
        assert!(owner.admit("source").is_ok());
        drop(unrelated);
    }
}
