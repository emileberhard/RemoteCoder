use super::{ClientTx, Gateway, QUERY_DEADLINE};
use crate::gateway::admission::Admission;
use crate::rpc::dispatch::ClientRequest;
use crate::rpc::error::{ErrorKind, RpcCode, RpcData};
use crate::rpc::{RequestPermit, RpcError};
use crate::tasks::owned_tasks::OwnedTasks;
use anyhow::{Context as _, Result};
use futures_util::future::{BoxFuture, poll_fn};
use serde_json::{Map, Value, json};
use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::{Context, Poll};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::time::{Instant, Sleep};
use tokio_util::sync::{CancellationToken, DropGuard};

const RUNNING_LIMIT: usize = 8;
const QUEUE_LIMIT: usize = 64;
const QUERY_BYTES: usize = 2 * 1024 * 1024;

#[derive(Debug, Default)]
pub(in crate::gateway) struct ResponseClaim(AtomicBool);

impl ResponseClaim {
    pub(in crate::gateway) fn is_claimed(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }

    pub(in crate::gateway) fn claim(&self) -> bool {
        !self.0.swap(true, Ordering::AcqRel)
    }
}

pub(super) struct QueryInfo {
    pub id: Value,
    pub method: String,
    pub thread: Option<String>,
}

struct QueuedQuery {
    request: ClientRequest,
    bytes: usize,
    admission: Option<Admission>,
    deadline: Pin<Box<Sleep>>,
}

impl QueuedQuery {
    fn info(&self) -> QueryInfo {
        QueryInfo {
            id: self.request.object["id"].clone(),
            method: self.request.method.clone(),
            thread: request_thread(&self.request.object),
        }
    }
}

struct RunningQuery {
    info: QueryInfo,
    response: Arc<ResponseClaim>,
    work: BoxFuture<'static, Result<()>>,
    _cancellation: DropGuard,
}

type AdmissionFuture = BoxFuture<'static, (OwnedSemaphorePermit, RequestPermit)>;

pub(super) enum QueryEvent {
    Admitted,
    Finished(Result<()>),
    Expired(QueryInfo),
}

pub(super) struct ConnectionQueries {
    gateway: Arc<Gateway>,
    out: ClientTx,
    local: Arc<Semaphore>,
    queued: VecDeque<QueuedQuery>,
    queued_bytes: usize,
    admitting: Option<AdmissionFuture>,
    running: Vec<RunningQuery>,
    tasks: Arc<OwnedTasks>,
}

impl ConnectionQueries {
    pub fn new(gateway: Arc<Gateway>, out: ClientTx, tasks: Arc<OwnedTasks>) -> Self {
        Self {
            gateway,
            out,
            local: Arc::new(Semaphore::new(QUERY_BYTES)),
            queued: VecDeque::new(),
            queued_bytes: 0,
            admitting: None,
            running: Vec::new(),
            tasks,
        }
    }

    pub fn queue_depth(&self) -> usize {
        self.queued.len()
    }

    pub fn enqueue(
        &mut self,
        request: ClientRequest,
        bytes: usize,
        admission: Option<Admission>,
        received: Instant,
    ) -> Result<(), RpcError> {
        let id = &request.object["id"];
        if self
            .queued
            .iter()
            .any(|query| query.request.object["id"] == *id)
            || self.running.iter().any(|query| query.info.id == *id)
        {
            return Err(RpcError::new(
                RpcCode::InvalidRequest,
                "Request id is already pending",
            ));
        }
        if bytes > QUERY_BYTES {
            return Err(RpcError::new(
                RpcCode::Capacity,
                "Query exceeds the connection input byte limit",
            )
            .with_data(RpcData::ByteCapacity {
                resource: "connection query bytes",
                actual_bytes: bytes,
                limit: QUERY_BYTES,
            }));
        }
        let resource = if self.queued.len() >= QUEUE_LIMIT {
            Some("connection query queue")
        } else if bytes > QUERY_BYTES.saturating_sub(self.queued_bytes) {
            Some("connection query queue bytes")
        } else {
            None
        };
        if let Some(resource) = resource {
            return Err(capacity_error(resource));
        }
        self.queued_bytes += bytes;
        self.queued.push_back(QueuedQuery {
            request,
            bytes,
            admission,
            deadline: Box::pin(tokio::time::sleep_until(received + QUERY_DEADLINE)),
        });
        Ok(())
    }

    fn remove_queued(&mut self, index: usize) -> QueuedQuery {
        if index == 0 {
            self.admitting = None;
        }
        let query = self.queued.remove(index).expect("queued query index");
        self.queued_bytes -= query.bytes;
        query
    }

    pub fn cancel(&mut self, id: &Value) -> Option<QueryInfo> {
        if id.is_null() {
            return None;
        }
        if let Some(index) = self
            .queued
            .iter()
            .position(|query| query.request.object["id"] == *id)
        {
            return Some(self.remove_queued(index).info());
        }
        let index = self.running.iter().position(|query| query.info.id == *id)?;
        if !self.running[index].response.claim() {
            return None;
        }
        Some(self.running.remove(index).info)
    }

    pub async fn next(&mut self) -> QueryEvent {
        poll_fn(|context| self.poll(context)).await
    }

    fn poll(&mut self, context: &mut Context<'_>) -> Poll<QueryEvent> {
        if let Some(query) = self.queued.front_mut()
            && query.deadline.as_mut().poll(context).is_ready()
        {
            return Poll::Ready(QueryEvent::Expired(self.remove_queued(0).info()));
        }
        for index in 0..self.running.len() {
            if let Poll::Ready(result) = self.running[index].work.as_mut().poll(context) {
                self.running.remove(index);
                return Poll::Ready(QueryEvent::Finished(result));
            }
        }
        let Some(query) = self.queued.front() else {
            return Poll::Pending;
        };
        if self.running.len() >= RUNNING_LIMIT {
            return Poll::Pending;
        }
        let admission = self.admitting.get_or_insert_with(|| {
            let local = Arc::clone(&self.local);
            let host = Arc::clone(&self.gateway.request_budgets);
            let bytes = query.bytes;
            Box::pin(async move {
                let local = local
                    .acquire_many_owned(u32::try_from(bytes.max(1)).expect("bounded query bytes"))
                    .await
                    .expect("query budget remains open");
                let host = host.query.acquire(bytes).await;
                (local, host)
            })
        });
        let Poll::Ready(permits) = admission.as_mut().poll(context) else {
            return Poll::Pending;
        };
        let query = self.remove_queued(0);
        let info = query.info();
        let response = Arc::new(ResponseClaim::default());
        let mut out = self.out.clone();
        out.query_response = Some(Arc::clone(&response));
        let cancellation = CancellationToken::new();
        let shutdown = cancellation.clone();
        let (complete, completed) = tokio::sync::oneshot::channel();
        let work = run_query(Arc::clone(&self.gateway), out.clone(), query, permits);
        self.tasks.spawn("gateway query", async move {
            let result = tokio::select! {
                biased;
                _ = shutdown.cancelled() => Ok(()),
                result = work => result,
            };
            let _ = complete.send(result);
            Ok(())
        });
        let gateway = Arc::clone(&self.gateway);
        let id = info.id.clone();
        self.running.push(RunningQuery {
            info,
            response,
            work: Box::pin(async move {
                let result = completed
                    .await
                    .context("gateway query task ended before completion")
                    .and_then(|result| result);
                if result.is_err() {
                    gateway
                        .send_error_to(
                            &out,
                            Some(&id),
                            &RpcError::new(RpcCode::Internal, "Gateway query failed"),
                        )
                        .await?;
                }
                result
            }),
            _cancellation: cancellation.drop_guard(),
        });
        Poll::Ready(QueryEvent::Admitted)
    }
}

async fn run_query(
    gateway: Arc<Gateway>,
    out: ClientTx,
    query: QueuedQuery,
    permits: (OwnedSemaphorePermit, RequestPermit),
) -> Result<()> {
    let QueuedQuery {
        request,
        admission,
        mut deadline,
        ..
    } = query;
    let id = request.object["id"].clone();
    let method = request.method.clone();
    let thread = request_thread(&request.object);
    let work = async {
        let _permits = permits;
        let _admission = admission;
        match gateway
            .validate_dispatch(&request.method, &request.object)
            .await
        {
            Ok(()) => (),
            Err(error) => return gateway.send_error_to(&out, Some(&id), &error).await,
        };
        gateway
            .handle_owned_rpc(
                out.id,
                &out,
                &request.method,
                request.owned.expect("owned query route").target,
                &request.object,
            )
            .await
    };
    let outcome = if Instant::now() >= deadline.deadline() {
        drop(work);
        None
    } else {
        tokio::select! {
            biased;
            _ = deadline.as_mut() => None,
            result = work => Some(result),
        }
    };
    match outcome {
        Some(result) => result,
        None => {
            gateway.journal.transport(
                "query_timed_out",
                json!({
                    "clientId": out.id, "method": method, "threadId": thread,
                    "limitMs": QUERY_DEADLINE.as_millis(),
                }),
            );
            gateway
                .send_error_to(
                    &out,
                    Some(&id),
                    &RpcError::request_timed_out(QUERY_DEADLINE),
                )
                .await
        }
    }
}

pub(super) fn capacity_error(resource: &'static str) -> RpcError {
    RpcError::capacity().with_data(RpcData::ResourceCapacity { resource })
}

pub(super) fn request_thread(object: &Map<String, Value>) -> Option<String> {
    object
        .get("params")
        .and_then(|params| params.get("threadId"))
        .and_then(Value::as_str)
        .filter(|thread| thread.len() <= 512)
        .map(str::to_owned)
}

pub(super) fn cancelled_error() -> RpcError {
    RpcError::new(-32800, "Request cancelled").with_data(RpcData::Kind(ErrorKind::RequestCancelled))
}

#[cfg(test)]
mod tests;
