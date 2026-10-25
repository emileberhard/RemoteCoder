//! Bound retained request payloads as well as active operations. A permit belongs
//! to actual work, including time spent awaiting a subprocess or disk operation.
pub(crate) mod dispatch;
pub(crate) mod error;
pub(crate) mod upstream_errors;

pub(crate) use error::{ErrorKind, RpcError, RpcResult};

use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore};
use tracing::debug;

pub(crate) struct RequestBudget {
    slots: Arc<Semaphore>,
    bytes: Arc<Semaphore>,
}

pub(crate) struct RequestPermit {
    _slots: OwnedSemaphorePermit,
    _bytes: OwnedSemaphorePermit,
}

impl RequestBudget {
    pub fn new(count: usize, bytes: usize) -> Self {
        Self {
            slots: Arc::new(Semaphore::new(count)),
            bytes: Arc::new(Semaphore::new(bytes)),
        }
    }
    pub(crate) fn try_acquire(&self, bytes: usize) -> Option<RequestPermit> {
        let slots = Arc::clone(&self.slots).try_acquire_owned().ok()?;
        let bytes = Arc::clone(&self.bytes)
            .try_acquire_many_owned(u32::try_from(bytes.max(1)).ok()?)
            .ok()?;
        Some(RequestPermit {
            _slots: slots,
            _bytes: bytes,
        })
    }

    pub(crate) async fn acquire(&self, bytes: usize) -> RequestPermit {
        let slots = Arc::clone(&self.slots)
            .acquire_owned()
            .await
            .expect("request budget remains open");
        let bytes = Arc::clone(&self.bytes)
            .acquire_many_owned(u32::try_from(bytes.max(1)).expect("bounded request bytes"))
            .await
            .expect("request budget remains open");
        RequestPermit {
            _slots: slots,
            _bytes: bytes,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TransportCapacityError {
    kind: &'static str,
    pub(crate) direction: &'static str,
    pub(crate) actual_bytes: usize,
    pub(crate) limit_bytes: usize,
    retryable: bool,
    message: &'static str,
}

impl TransportCapacityError {
    pub(crate) fn from_upstream(error: &tokio_tungstenite::tungstenite::Error) -> Option<Self> {
        use tokio_tungstenite::tungstenite::{Error, error::CapacityError};
        let Error::Capacity(CapacityError::MessageTooLong { size, max_size }) = error else {
            return None;
        };
        Some(Self {
            kind: "messageTooLarge",
            direction: "upstream",
            actual_bytes: *size,
            limit_bytes: *max_size,
            retryable: false,
            message: "History exceeds the connection limit. Load a smaller page; an individual oversized item cannot be loaded.",
        })
    }
}

pub(crate) const HISTORY_PAGE_RESPONSE_BUDGET: usize = 24 * 1024 * 1024;

pub(crate) struct PendingRequest {
    pub(crate) method: &'static str,
    pub(crate) thread_id: Option<String>,
    pub(crate) turn_id: Option<String>,
    pub(crate) issued_at: Instant,
}

impl PendingRequest {
    pub(crate) fn new(method: &'static str, params: Option<&Value>) -> Self {
        let text = |name: &str| {
            params
                .and_then(|params| params.get(name))
                .and_then(Value::as_str)
                .map(str::to_owned)
        };
        Self {
            method,
            thread_id: text("threadId"),
            turn_id: text("expectedTurnId"),
            issued_at: Instant::now(),
        }
    }
}

pub(crate) type PendingRequests = Arc<Mutex<HashMap<String, PendingRequest>>>;
pub(crate) const PENDING_REQUEST_TTL: Duration = Duration::from_secs(120);

pub(crate) fn prune_pending_requests(pending: &mut HashMap<String, PendingRequest>, now: Instant) {
    pending.retain(|_, request| {
        now.saturating_duration_since(request.issued_at) < PENDING_REQUEST_TTL
    });
}
pub(crate) const MAX_PENDING_REQUESTS: usize = 256;

pub(crate) enum HistoryPageRequest {
    Items(crate::providers::claude::projection::ItemsListParams),
    Turns(crate::providers::claude::projection::TurnsListParams),
}

impl HistoryPageRequest {
    pub(crate) fn thread_id(&self) -> &str {
        match self {
            HistoryPageRequest::Items(params) => &params.thread_id,
            HistoryPageRequest::Turns(params) => &params.thread_id,
        }
    }
}

pub(crate) fn history_page_method(method: Option<&str>) -> Option<&'static str> {
    match method? {
        "thread/turns/list" => Some("thread/turns/list"),
        "thread/items/list" => Some("thread/items/list"),
        "claude/thread/list" => Some("claude/thread/list"),
        _ => None,
    }
}

pub(crate) fn correlated_method(method: Option<&str>) -> Option<&'static str> {
    match method? {
        "turn/start" => Some("turn/start"),
        "turn/steer" => Some("turn/steer"),
        method => history_page_method(Some(method)),
    }
}

pub(crate) fn oversized_history_page_error(
    message: &Value,
    bytes: usize,
    method: Option<&str>,
) -> Option<Value> {
    if bytes <= HISTORY_PAGE_RESPONSE_BUDGET
        || history_page_method(method).is_none()
        || message.get("method").is_some()
        || message.get("result").is_none()
    {
        return None;
    }
    let id = message.get("id")?;
    Some(serde_json::json!({
        "jsonrpc": "2.0", "id": id,
        "error": {
            "code": -32003,
            "message": "History page exceeds the response budget. Request fewer items.",
            "data": ErrorKind::HistoryPageTooLarge {
                actual_bytes: bytes,
                limit_bytes: HISTORY_PAGE_RESPONSE_BUDGET,
            }.to_value()
        }
    }))
}

pub(crate) fn log_diagnostic_ws_frame(direction: &str, client_id: Option<u64>, raw: &str) {
    // This runs once per frame per client. Without the guard it parses every
    // payload even when debug logging is off; the journal is the durable
    // record, so this stays purely a live-debugging aid.
    if !tracing::enabled!(tracing::Level::DEBUG) {
        return;
    }
    let parsed = serde_json::from_str::<Value>(raw).ok();
    let method = parsed
        .as_ref()
        .and_then(|value| value.get("method"))
        .and_then(Value::as_str);
    let has_id = parsed
        .as_ref()
        .is_some_and(|value| value.get("id").is_some());
    debug!(
        direction,
        client_id,
        bytes = raw.len(),
        method,
        has_id,
        "ws frame"
    );
}

pub(crate) fn supported_reasoning_effort<'a>(
    requested: &'a str,
    supported: impl Iterator<Item = &'a str>,
) -> Option<&'a str> {
    let supported = supported.collect::<Vec<_>>();
    if supported.contains(&requested) {
        return Some(requested);
    }
    [
        "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
    ]
    .into_iter()
    .rev()
    .find(|effort| supported.contains(effort))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_oversized_history_page_matches_its_fixture() {
        let expected: Value = serde_json::from_str(include_str!(
            "../../../protocol-fixtures/errors/history-page-too-large.json"
        ))
        .expect("fixture json");
        let response = serde_json::json!({"id": 23, "result": {"data": []}});

        for method in ["thread/items/list", "claude/thread/list"] {
            let error = oversized_history_page_error(&response, 33_000_000, Some(method))
                .expect("over budget");
            assert_eq!(error["id"], expected["id"]);
            assert_eq!(error["error"], expected["error"]);
        }
    }

    #[test]
    fn both_limits_are_enforced_and_failed_admission_does_not_leak_a_slot() {
        let budget = RequestBudget::new(2, 10);
        let first = budget.try_acquire(6).unwrap();
        assert!(budget.try_acquire(5).is_none());
        let second = budget.try_acquire(4).unwrap();
        assert!(budget.try_acquire(0).is_none());
        drop(first);
        drop(second);
        assert!(budget.try_acquire(10).is_some());
    }
}
