use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use axum::Router;
use hyper_util::rt::{TokioIo, TokioTimer};
use hyper_util::service::TowerToHyperService;
use serde::Serialize;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;
use tokio_rustls::TlsAcceptor;
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;
use tracing::{debug, error, warn};

use super::lan_identity as lan_tls;
use super::lan_identity::LanIdentity;

const LAN_TLS_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
pub(super) const LAN_HEADER_READ_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LanEndpoint {
    pub(crate) host: String,
    pub(crate) port: u16,
    pub(crate) spki_sha256: String,
}

pub(crate) struct LanListener {
    pub(super) listener: TcpListener,
    pub(super) acceptor: TlsAcceptor,
    pub(super) endpoint: LanEndpoint,
}

impl LanListener {
    pub(crate) async fn bind(port: u16) -> Result<Self> {
        let identity = tokio::task::spawn_blocking(|| {
            LanIdentity::load(&lan_tls::default_key_path()?, lan_tls::mdns_host_name()?)
        })
        .await
        .context("LAN TLS identity task failed")??;
        let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, port))
            .await
            .with_context(|| format!("failed to bind 0.0.0.0:{port}"))?;
        Ok(Self {
            listener,
            acceptor: identity.acceptor,
            endpoint: LanEndpoint {
                host: identity.host,
                port,
                spki_sha256: identity.spki_sha256,
            },
        })
    }

    pub(crate) fn endpoint(&self) -> &LanEndpoint {
        &self.endpoint
    }
}

pub(super) async fn serve_lan(
    listener: TcpListener,
    acceptor: TlsAcceptor,
    app: Router,
    shutdown: CancellationToken,
    max_connections: usize,
) {
    let connections = TaskTracker::new();
    let slots = Arc::new(Semaphore::new(max_connections));
    loop {
        let (stream, peer) = tokio::select! {
            accepted = accept(&listener) => match accepted {
                Some(connection) => connection,
                None => continue,
            },
            () = shutdown.cancelled() => break,
        };
        let Ok(slot) = Arc::clone(&slots).try_acquire_owned() else {
            warn!(%peer, max_connections, "LAN connection refused: at capacity");
            continue;
        };
        let connection = serve_lan_connection(
            stream,
            peer,
            acceptor.clone(),
            app.clone(),
            shutdown.clone(),
        );
        connections.spawn(async move {
            connection.await;
            drop(slot);
        });
    }
    drop(listener);
    connections.close();
    connections.wait().await;
}

async fn accept(listener: &TcpListener) -> Option<(TcpStream, SocketAddr)> {
    match listener.accept().await {
        Ok(connection) => Some(connection),
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::ConnectionRefused
                    | std::io::ErrorKind::ConnectionAborted
                    | std::io::ErrorKind::ConnectionReset
            ) =>
        {
            None
        }
        Err(error) => {
            error!(%error, "LAN listener failed to accept a connection");
            tokio::time::sleep(Duration::from_secs(1)).await;
            None
        }
    }
}

async fn serve_lan_connection(
    stream: TcpStream,
    peer: SocketAddr,
    acceptor: TlsAcceptor,
    app: Router,
    shutdown: CancellationToken,
) {
    let handshake = tokio::time::timeout(LAN_TLS_HANDSHAKE_TIMEOUT, acceptor.accept(stream));
    let stream = tokio::select! {
        handshake = handshake => match handshake {
            Ok(Ok(stream)) => stream,
            Ok(Err(error)) => {
                warn!(%peer, %error, "LAN TLS handshake failed");
                return;
            }
            Err(_) => {
                warn!(%peer, "LAN TLS handshake timed out");
                return;
            }
        },
        () = shutdown.cancelled() => return,
    };
    let connection = hyper::server::conn::http1::Builder::new()
        .timer(TokioTimer::new())
        .header_read_timeout(LAN_HEADER_READ_TIMEOUT)
        .serve_connection(TokioIo::new(stream), TowerToHyperService::new(app))
        .with_upgrades();
    tokio::pin!(connection);
    let served = tokio::select! {
        served = connection.as_mut() => served,
        () = shutdown.cancelled() => {
            connection.as_mut().graceful_shutdown();
            connection.await
        }
    };
    if let Err(error) = served {
        debug!(%peer, %error, "LAN connection ended with an error");
    }
}
