use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use indexmap::IndexMap;
use serde::Deserialize;
use serde_json::json;
use tokio::sync::oneshot;

use super::{ClientCommand, ClientTx};
use crate::files::upload::UploadStore;
use crate::rpc::error::{RpcCode, RpcData};
use crate::rpc::{RpcError, RpcResult};

const MAX_HOSTS: usize = 256;
const MAX_OPERATIONS: usize = 4;
const MAX_DURATION_MS: u64 = 30 * 60 * 1000;
const MAX_AUDIO_BYTES: u64 = 44 + (MAX_DURATION_MS / 1000) * 16_000 * 2;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Declaration {
    serving: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Request {
    path: PathBuf,
    duration_ms: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct HostResult {
    operation_id: String,
    outcome: Outcome,
    text: Option<String>,
    model: Option<String>,
    detail: Option<String>,
    reason: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum Outcome {
    Succeeded,
    Failed,
    Cancelled,
}

struct Pending {
    host: ClientTx,
    deadline: tokio::time::Instant,
    result: Option<oneshot::Sender<HostResult>>,
}

#[derive(Default)]
struct State {
    hosts: IndexMap<u64, ClientTx>,
    pending: HashMap<String, Pending>,
}

#[derive(Default)]
pub(super) struct DictationHosts {
    state: Mutex<State>,
    uploads: OnceLock<UploadStore>,
}

impl DictationHosts {
    pub(super) fn configure_uploads(&self, uploads: UploadStore) -> anyhow::Result<()> {
        self.uploads
            .set(uploads)
            .map_err(|_| anyhow::anyhow!("Dictation uploads already configured"))
    }

    pub(super) fn declare(&self, client: &ClientTx, declaration: Declaration) -> RpcResult {
        let mut state = self.state.lock().expect("dictation hosts poisoned");
        state.hosts.shift_remove(&client.id);
        if declaration.serving {
            if state.hosts.len() >= MAX_HOSTS {
                return Err(reason("busy"));
            }
            state.hosts.insert(client.id, client.clone());
        }
        Ok(json!({}))
    }

    pub(super) fn disconnected(&self, id: u64) {
        self.state
            .lock()
            .expect("dictation hosts poisoned")
            .hosts
            .shift_remove(&id);
    }

    pub(super) fn result(&self, client_id: u64, result: HostResult) -> RpcResult {
        if result.operation_id.len() > 128
            || result
                .text
                .as_ref()
                .is_some_and(|s| s.len() > 2 * 1024 * 1024)
            || result.model.as_ref().is_some_and(|s| s.len() > 1024)
            || result.detail.as_ref().is_some_and(|s| s.len() > 4096)
            || result.reason.as_ref().is_some_and(|s| s != "busy")
        {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "Invalid dictation result",
            ));
        }
        if matches!(result.outcome, Outcome::Succeeded)
            && (result.text.as_ref().is_none_or(|s| s.trim().is_empty())
                || result.model.as_ref().is_none_or(|s| s.is_empty()))
        {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "A successful dictation needs text and model",
            ));
        }
        let mut state = self.state.lock().expect("dictation hosts poisoned");
        let Some(pending) = state.pending.get_mut(&result.operation_id) else {
            return Ok(json!({"accepted":false}));
        };
        if pending.host.id != client_id
            || pending.host.closed.is_cancelled()
            || tokio::time::Instant::now() >= pending.deadline
        {
            return Ok(json!({"accepted":false}));
        }
        let accepted = pending
            .result
            .take()
            .is_some_and(|sender| sender.send(result).is_ok());
        Ok(json!({"accepted":accepted}))
    }

    pub(super) async fn transcribe(
        self: &Arc<Self>,
        requester: &ClientTx,
        request: Request,
    ) -> RpcResult {
        if request.duration_ms == 0 || request.duration_ms > MAX_DURATION_MS {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "Invalid dictation duration",
            ));
        }
        let store = self
            .uploads
            .get()
            .ok_or_else(|| RpcError::new(RpcCode::Unavailable, "Upload store unavailable"))?;
        let upload = store
            .finished_path(&request.path)
            .map_err(|error| RpcError::new(RpcCode::Internal, error.message()))?;
        if upload.is_none_or(|upload| upload.bytes > MAX_AUDIO_BYTES) {
            return Err(RpcError::new(
                RpcCode::InvalidParams,
                "Dictation path is not a bounded finished upload",
            ));
        }
        let id = crate::ids::new_session_uuid();
        let deadline = Duration::from_millis(120_000 + request.duration_ms);
        let deadline_instant = tokio::time::Instant::now() + deadline;
        let deadline_unix_ms = crate::time::unix_millis() + deadline.as_millis() as i64;
        let message = json!({"method":"dictation/host/transcribe", "params": {"operationId": id, "path": request.path, "deadlineUnixMs": deadline_unix_ms}}).to_string();
        let (host, receiver) = {
            let mut state = self.state.lock().expect("dictation hosts poisoned");
            if state.pending.len() >= MAX_OPERATIONS {
                return Err(reason("busy"));
            }
            let host = state
                .hosts
                .values()
                .rev()
                .find(|host| !host.closed.is_cancelled())
                .cloned()
                .ok_or_else(|| reason("noHost"))?;
            let (sender, receiver) = oneshot::channel();
            state.pending.insert(
                id.clone(),
                Pending {
                    host: host.clone(),
                    deadline: deadline_instant,
                    result: Some(sender),
                },
            );
            if host.try_send(ClientCommand::Text(message)).is_err() {
                state.pending.remove(&id);
                host.closed.cancel();
                return Err(reason("hostLost"));
            }
            (host, receiver)
        };
        let mut operation = Operation {
            owner: self.clone(),
            id: id.clone(),
            complete: false,
        };
        let result = tokio::select! {
            biased;
            result = receiver => match result {
                Ok(result) => match result.outcome {
                    Outcome::Succeeded => Ok(json!({"text": result.text, "model": result.model})),
                    Outcome::Failed if result.reason.as_deref() == Some("busy") => Err(reason("busy")),
                    Outcome::Failed | Outcome::Cancelled => Err(reason("failed")),
                },
                Err(_) => Err(reason("hostLost")),
            },
            _ = host.closed.cancelled() => Err(reason("hostLost")),
            _ = requester.closed.cancelled() => Err(reason("unknown")),
            _ = tokio::time::sleep_until(deadline_instant) => Err(reason("unknown")),
        };
        if !matches!(&result, Err(error) if matches!(&error.data, RpcData::Raw(data) if data["reason"] == "unknown"))
        {
            operation.complete = true;
        }
        result
    }
}

fn reason(value: &str) -> RpcError {
    RpcError::new(RpcCode::Unavailable, format!("Dictation host: {value}"))
        .with_data(RpcData::Raw(json!({"reason":value})))
}

struct Operation {
    owner: Arc<DictationHosts>,
    id: String,
    complete: bool,
}

impl Drop for Operation {
    fn drop(&mut self) {
        let pending = self
            .owner
            .state
            .lock()
            .expect("dictation hosts poisoned")
            .pending
            .remove(&self.id);
        if !self.complete
            && let Some(pending) = pending
            && pending.result.is_some()
        {
            let message =
                json!({"method":"dictation/host/cancel", "params":{"operationId":self.id}});
            if pending
                .host
                .try_send(ClientCommand::Text(message.to_string()))
                .is_err()
            {
                pending.host.closed.cancel();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::upload::{Append, Declaration as UploadDeclaration, UploadId};
    use serde_json::Value;
    use tokio::sync::mpsc;
    use tokio_util::sync::CancellationToken;

    fn client(id: u64) -> (ClientTx, mpsc::Receiver<ClientCommand>) {
        let (tx, rx) = mpsc::channel(16);
        (
            ClientTx {
                grant: crate::auth::installation_credentials::Grant::Operator,
                content_subscriptions: Arc::default(),
                query_response: None,
                id,
                installation_id: None,
                tx,
                closed: CancellationToken::new(),
            },
            rx,
        )
    }

    async fn fixture() -> (Arc<DictationHosts>, tempfile::TempDir, PathBuf) {
        let directory = tempfile::tempdir().unwrap();
        let store = UploadStore::open_in(directory.path().join("uploads")).unwrap();
        let id = UploadId::random();
        let body = futures_util::stream::iter([Ok::<_, std::convert::Infallible>(
            axum::body::Bytes::from_static(b"test"),
        )]);
        let stored = store
            .append(
                &id,
                UploadDeclaration {
                    name: "recording.wav",
                    length: 4,
                    sha256: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
                },
                Append {
                    offset: 0,
                    content_length: 4,
                },
                body,
            )
            .await
            .unwrap();
        let relay = Arc::new(DictationHosts::default());
        relay.configure_uploads(store).unwrap();
        (relay, directory, stored.path)
    }

    fn start(
        relay: &Arc<DictationHosts>,
        requester: &ClientTx,
        path: &std::path::Path,
    ) -> tokio::task::JoinHandle<RpcResult> {
        let relay = relay.clone();
        let requester = requester.clone();
        let path = path.to_owned();
        tokio::spawn(async move {
            relay
                .transcribe(
                    &requester,
                    Request {
                        path,
                        duration_ms: 1000,
                    },
                )
                .await
        })
    }

    async fn receive(rx: &mut mpsc::Receiver<ClientCommand>) -> Value {
        let ClientCommand::Text(text) = rx.recv().await.unwrap() else {
            panic!("expected notification")
        };
        serde_json::from_str(&text).unwrap()
    }

    fn error_reason(error: RpcError) -> Value {
        let RpcData::Raw(data) = error.data else {
            panic!("missing reason")
        };
        data["reason"].clone()
    }

    #[tokio::test]
    async fn no_host_invalid_upload_and_disabled_declaration() {
        let (relay, _dir, path) = fixture().await;
        let (requester, _) = client(1);
        assert_eq!(
            error_reason(
                relay
                    .transcribe(
                        &requester,
                        Request {
                            path: path.clone(),
                            duration_ms: 1
                        }
                    )
                    .await
                    .unwrap_err()
            ),
            "noHost"
        );
        let (host, _) = client(2);
        relay.declare(&host, Declaration { serving: true }).unwrap();
        let bad = relay
            .transcribe(
                &requester,
                Request {
                    path: path.with_file_name("other"),
                    duration_ms: 1,
                },
            )
            .await
            .unwrap_err();
        assert_eq!(bad.code, RpcCode::InvalidParams);
        relay
            .declare(&host, Declaration { serving: false })
            .unwrap();
        assert_eq!(
            error_reason(
                relay
                    .transcribe(
                        &requester,
                        Request {
                            path,
                            duration_ms: 1
                        }
                    )
                    .await
                    .unwrap_err()
            ),
            "noHost"
        );
    }

    #[tokio::test]
    async fn latest_host_only_gets_new_operations_and_host_loss_is_reported() {
        let (relay, _dir, path) = fixture().await;
        let (requester, _) = client(1);
        let (first, mut first_rx) = client(2);
        let (second, mut second_rx) = client(3);
        relay
            .declare(&first, Declaration { serving: true })
            .unwrap();
        let old = start(&relay, &requester, &path);
        let old_request = receive(&mut first_rx).await;
        relay
            .declare(&second, Declaration { serving: true })
            .unwrap();
        let new = start(&relay, &requester, &path);
        let new_request = receive(&mut second_rx).await;
        relay.result(first.id, serde_json::from_value(json!({"operationId":old_request["params"]["operationId"],"outcome":"succeeded","text":"first","model":"batch"})).unwrap()).unwrap();
        assert_eq!(old.await.unwrap().unwrap()["text"], "first");
        assert_ne!(
            old_request["params"]["operationId"],
            new_request["params"]["operationId"]
        );
        second.closed.cancel();
        assert_eq!(error_reason(new.await.unwrap().unwrap_err()), "hostLost");
    }

    #[tokio::test]
    async fn disabling_a_host_preserves_its_admitted_operation() {
        let (relay, _dir, path) = fixture().await;
        let (requester, _) = client(1);
        let (host, mut rx) = client(2);
        relay.declare(&host, Declaration { serving: true }).unwrap();
        let operation = start(&relay, &requester, &path);
        let request = receive(&mut rx).await;
        relay
            .declare(&host, Declaration { serving: false })
            .unwrap();
        assert_eq!(
            error_reason(start(&relay, &requester, &path).await.unwrap().unwrap_err()),
            "noHost"
        );
        relay
            .result(
                host.id,
                serde_json::from_value(json!({
                    "operationId": request["params"]["operationId"],
                    "outcome": "succeeded", "text": "finished", "model": "batch"
                }))
                .unwrap(),
            )
            .unwrap();
        assert_eq!(operation.await.unwrap().unwrap()["text"], "finished");
    }

    #[tokio::test(start_paused = true)]
    async fn deadline_and_requester_loss_cancel_the_host() {
        for disconnect in [false, true] {
            let (relay, _dir, path) = fixture().await;
            let (requester, _) = client(1);
            let (host, mut rx) = client(2);
            relay.declare(&host, Declaration { serving: true }).unwrap();
            let operation = start(&relay, &requester, &path);
            let request = receive(&mut rx).await;
            if disconnect {
                requester.closed.cancel();
            } else {
                tokio::time::advance(Duration::from_secs(121)).await;
                let late = relay
                    .result(
                        host.id,
                        serde_json::from_value(json!({
                            "operationId": request["params"]["operationId"], "outcome": "succeeded",
                            "text": "late", "model": "batch"
                        }))
                        .unwrap(),
                    )
                    .unwrap();
                assert_eq!(late["accepted"], false);
            }
            assert_eq!(
                error_reason(operation.await.unwrap().unwrap_err()),
                "unknown"
            );
            let cancel = receive(&mut rx).await;
            assert_eq!(cancel["method"], "dictation/host/cancel");
            assert_eq!(
                cancel["params"]["operationId"],
                request["params"]["operationId"]
            );
        }
    }

    #[tokio::test]
    async fn four_operations_are_bounded_and_busy_is_typed() {
        let (relay, _dir, path) = fixture().await;
        let (requester, _) = client(1);
        let (host, mut rx) = client(2);
        relay.declare(&host, Declaration { serving: true }).unwrap();
        let mut tasks = Vec::new();
        for _ in 0..4 {
            tasks.push(start(&relay, &requester, &path));
            receive(&mut rx).await;
        }
        assert_eq!(
            error_reason(start(&relay, &requester, &path).await.unwrap().unwrap_err()),
            "busy"
        );
        requester.closed.cancel();
        for task in tasks {
            let _ = task.await;
        }
    }

    #[tokio::test]
    async fn a_busy_host_refusal_is_returned_to_the_requester() {
        let (relay, _dir, path) = fixture().await;
        let (requester, _) = client(1);
        let (host, mut rx) = client(2);
        relay.declare(&host, Declaration { serving: true }).unwrap();
        let operation = start(&relay, &requester, &path);
        let request = receive(&mut rx).await;
        relay
            .result(
                host.id,
                serde_json::from_value(json!({
                    "operationId": request["params"]["operationId"],
                    "outcome": "failed", "reason": "busy"
                }))
                .unwrap(),
            )
            .unwrap();
        assert_eq!(error_reason(operation.await.unwrap().unwrap_err()), "busy");
    }
}
