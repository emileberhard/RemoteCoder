use std::sync::{Mutex, MutexGuard};

/// Replenish only after the new WebRTC call has had time to establish so the
/// background thread start cannot contend with the latency-critical path.
pub(crate) const VOICE_SHADOW_REPLENISH_DELAY_SECONDS: u64 = 3;
const MAX_STALE_SHADOWS: usize = 8;

#[derive(Debug)]
struct ReadyShadow {
    cwd: String,
    thread_id: String,
}

#[derive(Debug)]
pub(crate) struct ShadowReservation {
    generation: u64,
    cwd: String,
}

#[derive(Debug, Default)]
struct PoolState {
    closed: bool,
    generation: u64,
    reserved: bool,
    ready: Option<ReadyShadow>,
    stale: Vec<String>,
}

#[derive(Debug, Default)]
pub(crate) struct ShadowPool {
    state: Mutex<PoolState>,
}

impl ShadowPool {
    fn state(&self) -> MutexGuard<'_, PoolState> {
        self.state.lock().expect("voice shadow pool poisoned")
    }

    pub(crate) fn take(&self, cwd: &str) -> Option<String> {
        let mut state = self.state();
        if state.ready.as_ref().is_some_and(|ready| ready.cwd == cwd) {
            state.ready.take().map(|ready| ready.thread_id)
        } else {
            None
        }
    }

    pub(crate) fn reserve(&self, cwd: &str) -> Option<ShadowReservation> {
        let mut state = self.state();
        if state.closed
            || state.reserved
            || state.ready.as_ref().is_some_and(|ready| ready.cwd == cwd)
        {
            return None;
        }
        state.reserved = true;
        Some(ShadowReservation {
            generation: state.generation,
            cwd: cwd.to_string(),
        })
    }

    pub(crate) fn release(&self, reservation: ShadowReservation) {
        let mut state = self.state();
        if state.generation == reservation.generation {
            state.reserved = false;
        }
    }

    /// Returns the thread ids the caller must delete: the offered thread when
    /// it no longer belongs to this pool, or the shadow it evicted.
    pub(crate) fn offer(&self, reservation: ShadowReservation, thread_id: String) -> Vec<String> {
        let mut state = self.state();
        if state.closed || state.generation != reservation.generation {
            return vec![thread_id];
        }
        state.reserved = false;
        state
            .ready
            .replace(ReadyShadow {
                cwd: reservation.cwd,
                thread_id,
            })
            .map(|evicted| evicted.thread_id)
            .into_iter()
            .collect()
    }

    pub(crate) fn invalidate(&self) {
        let mut state = self.state();
        state.generation = state.generation.wrapping_add(1);
        state.reserved = false;
        if let Some(ready) = state.ready.take() {
            if state.stale.len() == MAX_STALE_SHADOWS {
                state.stale.remove(0);
            }
            state.stale.push(ready.thread_id);
        }
    }

    pub(crate) fn take_stale(&self) -> Vec<String> {
        std::mem::take(&mut self.state().stale)
    }

    pub(crate) fn close(&self) -> Vec<String> {
        let mut state = self.state();
        state.closed = true;
        let mut unused = std::mem::take(&mut state.stale);
        unused.extend(state.ready.take().map(|ready| ready.thread_id));
        unused
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_replenish_is_reserved_at_a_time_and_take_matches_the_cwd() {
        let pool = ShadowPool::default();
        let reservation = pool.reserve("/a").expect("first reservation");
        assert!(pool.reserve("/b").is_none());
        assert!(pool.offer(reservation, "shadow-a".to_string()).is_empty());

        assert!(pool.reserve("/a").is_none());
        assert!(pool.take("/b").is_none());
        assert_eq!(pool.take("/a").as_deref(), Some("shadow-a"));
        assert!(pool.reserve("/a").is_some());
    }

    #[test]
    fn a_shadow_for_another_cwd_evicts_the_ready_one() {
        let pool = ShadowPool::default();
        let first = pool.reserve("/a").expect("reservation");
        pool.offer(first, "shadow-a".to_string());

        let second = pool.reserve("/b").expect("reservation for another cwd");
        assert_eq!(pool.offer(second, "shadow-b".to_string()), ["shadow-a"]);
        assert_eq!(pool.take("/b").as_deref(), Some("shadow-b"));
    }

    #[test]
    fn invalidation_retires_the_ready_shadow_and_refuses_an_in_flight_offer() {
        let pool = ShadowPool::default();
        let ready = pool.reserve("/a").expect("reservation");
        pool.offer(ready, "shadow-a".to_string());
        let in_flight = pool.reserve("/b").expect("reservation");

        pool.invalidate();

        assert!(pool.take("/a").is_none());
        assert_eq!(pool.offer(in_flight, "shadow-b".to_string()), ["shadow-b"]);
        assert!(pool.reserve("/a").is_some());
        assert_eq!(pool.take_stale(), ["shadow-a"]);
        assert!(pool.take_stale().is_empty());
    }

    #[test]
    fn stale_shadows_are_bounded_and_close_returns_every_unused_one() {
        let pool = ShadowPool::default();
        for index in 0..MAX_STALE_SHADOWS + 2 {
            let reservation = pool.reserve("/a").expect("reservation");
            pool.offer(reservation, format!("shadow-{index}"));
            pool.invalidate();
        }
        let reservation = pool.reserve("/a").expect("reservation");
        pool.offer(reservation, "ready".to_string());

        let unused = pool.close();

        assert_eq!(unused.len(), MAX_STALE_SHADOWS + 1);
        assert_eq!(unused.first().map(String::as_str), Some("shadow-2"));
        assert_eq!(unused.last().map(String::as_str), Some("ready"));
        assert!(pool.reserve("/a").is_none());
    }
}
