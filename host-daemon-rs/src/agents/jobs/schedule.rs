use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use tokio::time::Instant;

use super::model::JobId;

const MIN_INTERVAL: Duration = Duration::from_secs(1);
const MAX_INTERVAL: Duration = Duration::from_secs(600);

#[derive(Default)]
pub(crate) struct DeliverySchedule(Mutex<HashMap<(JobId, String), Instant>>);

impl DeliverySchedule {
    pub(super) fn claim(&self, job: &JobId, delivery_id: &str, age: Duration) -> bool {
        let now = Instant::now();
        let mut due = self.0.lock().expect("delivery schedule poisoned");
        let key = (job.clone(), delivery_id.to_owned());
        if due.get(&key).is_some_and(|next| *next > now) {
            return false;
        }
        due.insert(key, now + interval(age));
        true
    }

    pub(super) fn forget(&self, job: &JobId, delivery_id: &str) {
        self.0
            .lock()
            .expect("delivery schedule poisoned")
            .remove(&(job.clone(), delivery_id.to_owned()));
    }

    pub(super) fn expedite(&self, jobs: &[JobId]) {
        self.0
            .lock()
            .expect("delivery schedule poisoned")
            .retain(|(job, _), _| !jobs.contains(job));
    }

    pub(super) fn retain(&self, pending: &[JobId]) {
        self.0
            .lock()
            .expect("delivery schedule poisoned")
            .retain(|(job, _), _| pending.contains(job));
    }

    pub(super) fn next_due(&self) -> Option<Instant> {
        let now = Instant::now();
        self.0
            .lock()
            .expect("delivery schedule poisoned")
            .values()
            .filter(|due| **due > now)
            .min()
            .copied()
    }
}

fn interval(age: Duration) -> Duration {
    (age / 8).clamp(MIN_INTERVAL, MAX_INTERVAL)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retry_interval_grows_with_the_obligation_age_within_its_bounds() {
        assert_eq!(interval(Duration::ZERO), MIN_INTERVAL);
        assert_eq!(interval(Duration::from_secs(80)), Duration::from_secs(10));
        assert_eq!(interval(Duration::from_secs(24 * 60 * 60)), MAX_INTERVAL);
    }

    #[tokio::test(start_paused = true)]
    async fn a_claim_holds_its_obligation_until_due_unless_expedited() {
        let schedule = DeliverySchedule::default();
        let job = JobId::try_from("agent-codex-1793127141860775000-00000001".to_owned()).unwrap();
        let other = JobId::try_from("agent-codex-1793127141860775000-00000002".to_owned()).unwrap();
        let age = Duration::from_secs(80);

        assert!(schedule.claim(&job, "a:completion", age));
        assert!(!schedule.claim(&job, "a:completion", age));
        tokio::time::advance(Duration::from_secs(9)).await;
        assert!(!schedule.claim(&job, "a:completion", age));
        tokio::time::advance(Duration::from_secs(1)).await;
        assert!(schedule.claim(&job, "a:completion", age));
        assert!(schedule.claim(&other, "b:completion", age));

        schedule.expedite(std::slice::from_ref(&job));
        assert!(schedule.claim(&job, "a:completion", age));
        assert!(!schedule.claim(&other, "b:completion", age));

        schedule.retain(std::slice::from_ref(&other));
        assert_eq!(
            schedule.next_due(),
            Some(Instant::now() + Duration::from_secs(10))
        );
        tokio::time::advance(Duration::from_secs(10)).await;
        assert_eq!(schedule.next_due(), None);
    }
}
