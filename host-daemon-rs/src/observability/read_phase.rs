use serde_json::json;
use std::time::Duration;
use tokio::time::Instant;

pub(crate) struct ReadPhase<'a> {
    journal: &'a crate::observability::journal::Journal,
    method: &'static str,
    phase: &'static str,
    started: Instant,
}

impl<'a> ReadPhase<'a> {
    pub(crate) fn new(
        journal: &'a crate::observability::journal::Journal,
        method: &'static str,
        phase: &'static str,
    ) -> Self {
        Self {
            journal,
            method,
            phase,
            started: Instant::now(),
        }
    }

    pub(crate) fn advance(&mut self, phase: &'static str) {
        self.record(true);
        self.phase = phase;
        self.started = Instant::now();
    }

    fn record(&self, completed: bool) {
        if self.started.elapsed() >= Duration::from_millis(250) {
            self.journal.transport("readPhase", json!({"method":self.method,"phase":self.phase,"elapsedMs":self.started.elapsed().as_millis(),"completed":completed}));
        }
    }

    pub(crate) fn complete(mut self) {
        self.advance("complete");
    }
}

impl Drop for ReadPhase<'_> {
    fn drop(&mut self) {
        self.record(false);
    }
}
