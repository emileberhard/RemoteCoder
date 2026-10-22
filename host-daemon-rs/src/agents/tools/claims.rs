use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::watch;
use tokio::time::Instant;

use super::ToolOutcome;

const MAX_CLAIMS: usize = 64;
const RETENTION: Duration = Duration::from_secs(60);

type Key = (String, String);
pub(crate) type OutcomeReceiver = watch::Receiver<Option<Arc<ToolOutcome>>>;

struct Entry {
    outcome: watch::Sender<Option<Arc<ToolOutcome>>>,
    completed: Option<Instant>,
}

#[derive(Default)]
pub(crate) struct ToolClaims {
    entries: Mutex<HashMap<Key, Entry>>,
}

impl ToolClaims {
    pub(crate) fn claim(&self, key: &Key) -> Result<(OutcomeReceiver, bool), ToolOutcome> {
        let mut entries = self.entries.lock().expect("tool claims poisoned");
        let now = Instant::now();
        entries.retain(|_, entry| entry.completed.is_none_or(|time| now - time < RETENTION));
        if let Some(entry) = entries.get(key) {
            return Ok((entry.outcome.subscribe(), false));
        }
        if entries.len() >= MAX_CLAIMS {
            return Err(ToolOutcome::error(
                "RemoteCoder's tool call capacity is full. Try again shortly.",
            ));
        }
        let (outcome, receiver) = watch::channel(None);
        entries.insert(
            key.clone(),
            Entry {
                outcome,
                completed: None,
            },
        );
        Ok((receiver, true))
    }

    pub(crate) fn complete(&self, key: &Key, outcome: ToolOutcome) {
        let mut entries = self.entries.lock().expect("tool claims poisoned");
        let entry = entries.get_mut(key).expect("claimed tool call missing");
        entry.outcome.send_replace(Some(Arc::new(outcome)));
        entry.completed = Some(Instant::now());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn copies_join_the_first_result_and_completed_calls_remain_claimed_for_sixty_seconds() {
        let claims = ToolClaims::default();
        let key = ("thread".into(), "call".into());
        let (_, first) = claims.claim(&key).unwrap();
        let (mut copy, duplicate) = claims.claim(&key).unwrap();
        assert!(first);
        assert!(!duplicate);
        assert!(copy.borrow().is_none());
        claims.complete(&key, ToolOutcome::ok("dispatched once"));
        copy.changed().await.unwrap();
        assert_eq!(
            copy.borrow().as_deref(),
            Some(&ToolOutcome::ok("dispatched once"))
        );
        tokio::time::advance(Duration::from_secs(59)).await;
        let (tombstone, dispatch) = claims.claim(&key).unwrap();
        assert!(!dispatch);
        assert_eq!(tombstone.borrow().as_deref(), copy.borrow().as_deref());
        assert!(
            claims
                .claim(&("other-thread".into(), "call".into()))
                .unwrap()
                .1
        );
        tokio::time::advance(Duration::from_secs(1)).await;
        assert!(claims.claim(&key).unwrap().1);
    }

    #[test]
    fn capacity_never_evicts_live_calls_or_tombstones() {
        let claims = ToolClaims::default();
        for call in 0..MAX_CLAIMS {
            let key = ("thread".into(), call.to_string());
            assert!(claims.claim(&key).unwrap().1);
            if call % 2 == 0 {
                claims.complete(&key, ToolOutcome::ok("done"));
            }
        }
        assert!(claims.claim(&("thread".into(), "new".into())).is_err());
        assert!(!claims.claim(&("thread".into(), "0".into())).unwrap().1);
    }
}
