use std::net::{Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use axum::Router;
use hyper_util::rt::{TokioIo, TokioTimer};
use hyper_util::service::TowerToHyperService;
use serde::Serialize;
use tokio::net::{TcpListener, TcpSocket, TcpStream};
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
    pub(crate) async fn bind(settings: &crate::config::LanSettings) -> Result<Self> {
        let host = match &settings.binding {
            crate::config::LanBinding::DualStack => lan_tls::mdns_host_name()?,
            crate::config::LanBinding::Address { host, .. } => host.clone(),
        };
        let identity = tokio::task::spawn_blocking(move || {
            LanIdentity::load(&lan_tls::default_key_path()?, host)
        })
        .await
        .context("LAN TLS identity task failed")??;
        let listener = match &settings.binding {
            crate::config::LanBinding::DualStack => {
                bind_dual_stack(settings.port).with_context(|| {
                    format!(
                        "could not bind dual-stack TLS listener on port {}",
                        settings.port
                    )
                })?
            }
            crate::config::LanBinding::Address { address, .. } => {
                let socket = SocketAddr::new(*address, settings.port);
                #[cfg(target_os = "linux")]
                {
                    bind_address(socket)?
                }
                #[cfg(not(target_os = "linux"))]
                TcpListener::bind(socket)
                    .await
                    .with_context(|| format!("could not bind TLS listener at {socket}"))?
            }
        };
        Ok(Self {
            listener,
            acceptor: identity.acceptor,
            endpoint: LanEndpoint {
                host: identity.host,
                port: settings.port,
                spki_sha256: identity.spki_sha256,
            },
        })
    }

    pub(crate) fn endpoint(&self) -> &LanEndpoint {
        &self.endpoint
    }
}

#[cfg(target_os = "linux")]
fn bind_address(address: SocketAddr) -> std::io::Result<TcpListener> {
    let socket = if address.is_ipv4() {
        TcpSocket::new_v4()?
    } else {
        TcpSocket::new_v6()?
    };
    let options = socket2::SockRef::from(&socket);
    if address.is_ipv4() {
        options.set_freebind_v4(true)?;
    } else {
        options.set_freebind_v6(true)?;
    }
    socket.set_reuseaddr(true)?;
    socket.bind(address)?;
    socket.listen(128)
}

fn bind_dual_stack(port: u16) -> std::io::Result<TcpListener> {
    let socket = TcpSocket::new_v6()?;
    nix::sys::socket::setsockopt(&socket, nix::sys::socket::sockopt::Ipv6V6Only, &false)?;
    socket.set_reuseaddr(true)?;
    socket.bind(SocketAddr::from((Ipv6Addr::UNSPECIFIED, port)))?;
    socket.listen(128)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn the_explicit_listener_can_bind_before_its_interface_has_an_address() {
        for address in ["198.51.100.99:0", "[2001:db8::99]:0"] {
            let address: SocketAddr = address.parse().unwrap();
            let listener = bind_address(address).unwrap();
            assert_eq!(listener.local_addr().unwrap().ip(), address.ip());
        }
    }

    #[tokio::test]
    async fn the_lan_listener_accepts_ipv6_and_ipv4_peers() {
        let listener = bind_dual_stack(0).unwrap();
        let port = listener.local_addr().unwrap().port();
        for address in [
            SocketAddr::from((Ipv6Addr::LOCALHOST, port)),
            SocketAddr::from(([127, 0, 0, 1], port)),
        ] {
            tokio::try_join!(TcpStream::connect(address), listener.accept()).unwrap();
        }
    }
}
