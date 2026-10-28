use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, ensure};
use futures_util::future::BoxFuture;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::task::{JoinHandle, JoinSet};

use crate::agents::jobs::model::MAX_JOB_BYTES;
use crate::platform::process::{ProcessInstance, unix_peer_identity};
use crate::rpc::error::{RpcCode, RpcError, RpcResult};
use crate::wire::agent_jobs::ScopedRequest;

pub(crate) type ScopedHandler =
    Arc<dyn Fn(ProcessInstance, ScopedRequest) -> BoxFuture<'static, RpcResult> + Send + Sync>;

#[derive(Clone)]
pub(crate) struct ScopedEndpoints {
    endpoints: Arc<Semaphore>,
    peers: Arc<Semaphore>,
}

impl Default for ScopedEndpoints {
    fn default() -> Self {
        Self {
            endpoints: Arc::new(Semaphore::new(1)),
            peers: Arc::new(Semaphore::new(64)),
        }
    }
}

pub(crate) struct ScopedEndpointLease {
    task: Option<JoinHandle<()>>,
}

struct SocketOwner {
    path: PathBuf,
    device: u64,
    inode: u64,
    _permit: OwnedSemaphorePermit,
}

impl ScopedEndpoints {
    pub(crate) async fn bind(
        &self,
        path: &Path,
        handler: ScopedHandler,
    ) -> Result<ScopedEndpointLease> {
        let permit = Arc::clone(&self.endpoints)
            .try_acquire_owned()
            .context("scoped coordination endpoint capacity reached")?;
        ensure!(
            path.is_absolute(),
            "scoped coordination socket must have an absolute path"
        );
        crate::storage::private_state::ensure_private_directory(
            path.parent()
                .context("scoped coordination socket has no parent")?,
        )?;
        match std::fs::symlink_metadata(path) {
            Ok(_) => reclaim_stale_socket(path).await?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error)
                    .context("scoped endpoint path could not be inspected before binding");
            }
        }
        let listener =
            UnixListener::bind(path).context("scoped coordination socket could not be bound")?;
        let metadata = std::fs::symlink_metadata(path)?;
        let owner = SocketOwner {
            path: path.into(),
            device: metadata.dev(),
            inode: metadata.ino(),
            _permit: permit,
        };
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        let peers = Arc::clone(&self.peers);
        let task = tokio::spawn(async move {
            let _owner = owner;
            let mut tasks = JoinSet::new();
            loop {
                tokio::select! {
                    accepted = listener.accept() => {
                        let Ok((stream, _)) = accepted else { break; };
                        let Ok(permit) = Arc::clone(&peers).try_acquire_owned() else { continue; };
                        let handler = Arc::clone(&handler);
                        tasks.spawn(async move {
                            let _permit = permit;
                            let _ = tokio::time::timeout(Duration::from_secs(30), serve(stream, handler)).await;
                        });
                    }
                    _ = tasks.join_next(), if !tasks.is_empty() => {}
                }
            }
        });
        Ok(ScopedEndpointLease { task: Some(task) })
    }
}

async fn reclaim_stale_socket(path: &Path) -> Result<()> {
    let before = std::fs::symlink_metadata(path)
        .context("existing scoped socket metadata is unavailable")?;
    ensure!(
        before.file_type().is_socket() && before.uid() == nix::unistd::Uid::current().as_raw(),
        "existing scoped endpoint is not a socket owned by this user; refusing replacement"
    );
    let probe = tokio::time::timeout(Duration::from_millis(250), UnixStream::connect(path)).await;
    ensure!(
        matches!(probe,Ok(Err(ref error)) if error.kind() == std::io::ErrorKind::ConnectionRefused),
        "existing scoped coordination socket is live or its owner is uncertain; refusing replacement"
    );
    let current = std::fs::symlink_metadata(path)
        .context("scoped socket changed during stale-owner probe")?;
    ensure!(
        current.file_type().is_socket()
            && current.uid() == before.uid()
            && current.dev() == before.dev()
            && current.ino() == before.ino(),
        "scoped socket identity changed during stale-owner probe; refusing replacement"
    );
    std::fs::remove_file(path).context("stale scoped socket could not be reclaimed")
}

async fn serve(mut stream: UnixStream, handler: ScopedHandler) -> Result<()> {
    let peer = unix_peer_identity(&stream).map(|(pid, identity)| ProcessInstance {
        pid,
        started_micros: identity.started_micros,
    });
    let result = match peer {
        Ok(peer) => read_request(&mut stream)
            .await
            .map(|request| (peer, request)),
        Err(error) => Err(RpcError::new(
            RpcCode::Unavailable,
            format!("Scoped coordination needs verified kernel peer identity: {error:#}"),
        )),
    };
    let result = match result {
        Ok((peer, request)) => handler(peer, request).await,
        Err(error) => Err(error),
    };
    let response = match result {
        Ok(value) => json!({"result":value}),
        Err(error) => error.response(&Value::Null),
    };
    let mut bytes = serde_json::to_vec(&response)?;
    if bytes.len() >= MAX_JOB_BYTES as usize {
        bytes = serde_json::to_vec(&RpcError::capacity().response(&Value::Null))?;
    }
    bytes.push(b'\n');
    stream.write_all(&bytes).await?;
    stream.shutdown().await?;
    Ok(())
}

async fn read_request(stream: &mut UnixStream) -> std::result::Result<ScopedRequest, RpcError> {
    let mut bytes = Vec::new();
    BufReader::new(stream.take(MAX_JOB_BYTES + 1))
        .read_until(b'\n', &mut bytes)
        .await
        .map_err(|error| {
            RpcError::new(
                RpcCode::Unavailable,
                format!("Scoped coordination frame could not be read: {error}"),
            )
        })?;
    if bytes.len() > MAX_JOB_BYTES as usize {
        return Err(RpcError::capacity());
    }
    if bytes.last() != Some(&b'\n') {
        return Err(RpcError::new(
            RpcCode::InvalidRequest,
            "Scoped coordination needs one complete newline-delimited request",
        ));
    }
    serde_json::from_slice(&bytes).map_err(|error| {
        RpcError::new(
            RpcCode::InvalidParams,
            format!("Invalid scoped coordination request: {error}"),
        )
    })
}

impl ScopedEndpointLease {
    pub(crate) async fn close(mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
            let _ = task.await;
        }
    }
}

impl Drop for ScopedEndpointLease {
    fn drop(&mut self) {
        if let Some(task) = &self.task {
            task.abort();
        }
    }
}

impl Drop for SocketOwner {
    fn drop(&mut self) {
        if std::fs::symlink_metadata(&self.path)
            .is_ok_and(|metadata| metadata.dev() == self.device && metadata.ino() == self.inode)
        {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

pub(crate) fn scoped_socket(root: &Path) -> PathBuf {
    socket_directory().join(format!(
        "caller-{}.sock",
        super::super::store::fingerprint(root.as_os_str().as_encoded_bytes())
    ))
}

pub(crate) fn legacy_socket(id: &crate::agents::jobs::model::JobId) -> PathBuf {
    socket_directory().join(format!(
        "{}.sock",
        super::super::store::fingerprint(id.as_str().as_bytes())
    ))
}

pub(crate) fn is_legacy_socket(path: &Path) -> bool {
    path.parent() == Some(socket_directory().as_path())
        && path
            .extension()
            .is_some_and(|extension| extension == "sock")
        && path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .is_some_and(|stem| {
                stem.len() == 64
                    && stem
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            })
}

fn socket_directory() -> PathBuf {
    PathBuf::from(format!("/tmp/rc-aj-{}", nix::unistd::getuid()))
}
