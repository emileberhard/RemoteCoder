//! One correlated, host-private audit trail per turn-review opportunity.
use crate::observability::journal::Journal;
use serde_json::{Value, json};
use std::sync::{
    Mutex,
    atomic::{AtomicU64, Ordering},
};
use std::time::Instant;

pub(super) struct Trace {
    journal: Journal,
    id: String,
    identity: Value,
    sequence: AtomicU64,
    requests: AtomicU64,
    secrets: Mutex<Option<String>>,
    last_event: Mutex<&'static str>,
    consumers: Mutex<serde_json::Map<String, Value>>,
    started: Instant,
    finished: bool,
}

impl Trace {
    pub(super) fn new(journal: Journal, mut identity: Value) -> Self {
        let id = crate::ids::new_session_uuid();
        identity["traceId"] = json!(id);
        identity["schemaVersion"] = json!(1);
        let trace = Self {
            journal,
            id,
            identity,
            sequence: AtomicU64::new(0),
            requests: AtomicU64::new(0),
            secrets: Mutex::new(None),
            last_event: Mutex::new("started"),
            consumers: Mutex::new(serde_json::Map::new()),
            started: Instant::now(),
            finished: false,
        };
        trace.event("started", json!({}));
        trace
    }

    #[cfg(test)]
    pub(super) fn silent() -> Self {
        Self::new(Journal::disabled(), json!({}))
    }

    pub(super) fn request_id(&self) -> String {
        format!(
            "{}:{}",
            self.id,
            self.requests.fetch_add(1, Ordering::Relaxed) + 1
        )
    }

    pub(super) fn protect_secret(&self, secret: &str) {
        if secret.is_empty() {
            return;
        }
        let mut secrets = self.secrets.lock().expect("review trace secrets poisoned");
        if secrets.as_deref() != Some(secret) {
            *secrets = Some(secret.to_owned());
        }
    }

    pub(super) fn event(&self, event: &'static str, mut fields: Value) {
        let Some(object) = fields.as_object_mut() else {
            return;
        };
        if let Some(identity) = self.identity.as_object() {
            object.extend(identity.clone());
        }
        object.entry("payloadComplete").or_insert(json!(true));
        object.insert(
            "sequence".into(),
            json!(self.sequence.fetch_add(1, Ordering::Relaxed)),
        );
        let secrets = self.secrets.lock().expect("review trace secrets poisoned");
        if redact_values(&mut fields, secrets.as_deref()) {
            fields["redacted"] = json!(true);
        }
        self.journal.review(event, fields);
        *self.last_event.lock().expect("review trace phase poisoned") = event;
    }

    pub(super) fn consumer_outcome(
        &self,
        consumer: &'static str,
        outcome: &'static str,
        reason: &'static str,
    ) {
        self.consumers
            .lock()
            .expect("review consumers poisoned")
            .insert(
                consumer.to_owned(),
                json!({"outcome":outcome,"reason":reason}),
            );
    }

    pub(super) fn consumer_failed(
        &self,
        consumer: &'static str,
        reason: &'static str,
        error: &anyhow::Error,
    ) {
        self.event(
            "consumerFailed",
            json!({"consumer":consumer,"reason":reason,"error":format!("{error:#}")}),
        );
        self.consumer_outcome(consumer, "failed", reason);
    }

    pub(super) fn finish(&mut self, outcome: &'static str, reason: &'static str) {
        if self.finished {
            return;
        }
        let last = *self.last_event.lock().expect("review trace phase poisoned");
        let mut consumers = self
            .consumers
            .lock()
            .expect("review consumers poisoned")
            .clone();
        for pending in consumers
            .values_mut()
            .filter(|consumer| consumer["outcome"] == "pending")
        {
            *pending = json!({"outcome":outcome,"reason":reason});
        }
        self.event(
            "finished",
            json!({"outcome":outcome,"reason":reason,"lastEvent":last,"consumers":consumers,
            "elapsedMs":self.started.elapsed().as_secs_f64()*1000.0}),
        );
        self.finished = true;
    }

    pub(super) fn failed(&mut self, error: &anyhow::Error) {
        let at = *self.last_event.lock().expect("review trace phase poisoned");
        self.event("failed", json!({"error":format!("{error:#}"),"atEvent":at}));
        self.finish("failed", "checkFailed");
    }
}

impl Drop for Trace {
    fn drop(&mut self) {
        // A dropped future must never look like a successful keep decision.
        self.finish("abandoned", "taskEndedWithoutOutcome");
    }
}

fn redact_values(value: &mut Value, secret: Option<&str>) -> bool {
    match value {
        Value::String(text) => {
            let mut redacted = false;
            if let Some(secret) = secret
                && text.contains(secret)
            {
                *text = text.replace(secret, "[redacted]");
                redacted = true;
            }
            redacted
        }
        Value::Array(values) => {
            let mut changed = false;
            for value in values {
                changed |= redact_values(value, secret);
            }
            changed
        }
        Value::Object(values) => {
            let mut changed = false;
            for value in values.values_mut() {
                changed |= redact_values(value, secret);
            }
            changed
        }
        _ => false,
    }
}
