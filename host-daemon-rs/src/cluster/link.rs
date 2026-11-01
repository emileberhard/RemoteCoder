use std::collections::HashMap;
use std::fmt;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::{Mutex, RwLock};
use tokio_rustls::rustls::{ClientConfig, crypto::ring, version::TLS13};
use tokio_tungstenite::{
    Connector, MaybeTlsStream, WebSocketStream,
    tungstenite::{Message, client::IntoClientRequest},
};

use super::members::Members;
use crate::identity::HostIdentity;
use crate::wire::cluster::*;

type Socket = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

#[derive(Clone, Debug)]
pub(crate) enum Failure {
    Transport,
    Peer(Value),
    Local,
    Protocol,
}

#[derive(Clone, Debug)]
pub(crate) struct LinkError {
    pub cause: Failure,
    pub class: ErrorClass,
    pub transmitted: bool,
    pub message: String,
}

impl LinkError {
    pub(crate) fn local(class: ErrorClass, message: impl ToString) -> Self {
        Self {
            cause: Failure::Local,
            class,
            transmitted: false,
            message: message.to_string(),
        }
    }

    fn transport(message: impl ToString, transmitted: bool) -> Self {
        Self {
            cause: Failure::Transport,
            class: if transmitted {
                ErrorClass::Uncertain
            } else {
                ErrorClass::Unavailable
            },
            transmitted,
            message: message.to_string(),
        }
    }

    fn peer(error: Value) -> Self {
        Self {
            class: ErrorClass::from_rpc(&error),
            transmitted: true,
            message: error["message"]
                .as_str()
                .unwrap_or("member refused request")
                .to_owned(),
            cause: Failure::Peer(error),
        }
    }

    pub(crate) fn coverage_state(&self) -> &'static str {
        match (&self.cause, &self.class) {
            (Failure::Transport, _) => "unreachable",
            (_, ErrorClass::Unsupported) => "unsupported",
            (_, ErrorClass::Refused) => "refused",
            _ => "unavailable",
        }
    }
}

impl fmt::Display for LinkError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}
impl std::error::Error for LinkError {}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Reachability {
    pub state: ReachabilityState,
    pub since: String,
    pub last_seen_at: Option<String>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ReachabilityState {
    Unknown,
    Reachable,
    Unreachable,
    Unsupported,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MemberView {
    #[serde(rename = "hostId")]
    pub host: String,
    pub name: String,
    pub membership: String,
    pub state: MemberState,
    pub incarnation: Option<String>,
    pub capabilities: Vec<String>,
    pub reachability: Reachability,
    pub version: Option<String>,
    pub protocol: Option<u32>,
    pub load: Option<HostLoad>,
    pub routes: Vec<String>,
}

mod connection;
use connection::Connection;

pub(crate) struct Link {
    pub(crate) store: Arc<Members>,
    identity: RwLock<HostIdentity>,
    connections: Mutex<HashMap<String, Arc<Mutex<Option<Connection>>>>>,
    observations: RwLock<HashMap<String, MemberView>>,
    endpoint: RwLock<Option<crate::http::lan::LanEndpoint>>,
    wakes: Mutex<HashMap<String, tokio::sync::watch::Sender<u64>>>,
    routes: std::sync::OnceLock<HashMap<String, String>>,
    next_id: AtomicU64,
}

pub(crate) fn timestamp() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .expect("UTC timestamp formats as RFC 3339")
}

impl Link {
    pub(crate) fn new(state: &Path, identity: HostIdentity) -> Self {
        Self {
            store: Arc::new(Members::new(state)),
            identity: RwLock::new(identity),
            connections: Mutex::new(HashMap::new()),
            observations: RwLock::new(HashMap::new()),
            endpoint: RwLock::new(None),
            wakes: Mutex::default(),
            routes: std::sync::OnceLock::new(),
            next_id: AtomicU64::new(1),
        }
    }

    pub(crate) async fn member_wakes(&self, host: &str) -> tokio::sync::watch::Receiver<u64> {
        self.wakes
            .lock()
            .await
            .entry(host.to_owned())
            .or_insert_with(|| tokio::sync::watch::channel(0).0)
            .subscribe()
    }

    pub(crate) async fn wake_member(&self, host: &str) {
        if let Some(wake) = self.wakes.lock().await.get(host) {
            wake.send_modify(|revision| *revision = revision.wrapping_add(1));
        }
    }

    pub(crate) async fn set_endpoint(&self, endpoint: Option<crate::http::lan::LanEndpoint>) {
        *self.endpoint.write().await = endpoint;
    }

    pub(crate) fn configure_routes(&self, routes: HashMap<String, String>) -> Result<()> {
        self.routes
            .set(routes)
            .map_err(|_| anyhow::anyhow!("cluster routes are already configured"))
    }

    fn routes_for(&self, host: &str, retained: &[String]) -> Vec<String> {
        let mut routes = self
            .routes
            .get()
            .and_then(|routes| routes.get(host))
            .cloned()
            .into_iter()
            .collect::<Vec<_>>();
        for route in retained {
            if !routes.contains(route) {
                routes.push(route.clone());
            }
        }
        routes
    }

    pub(crate) async fn endpoint(&self) -> Result<(Vec<String>, String)> {
        let endpoint = self
            .endpoint
            .read()
            .await
            .clone()
            .context("cluster Join requires the pinned LAN TLS listener")?;
        Ok((
            self.routes_for(
                &self.identity.read().await.host_id,
                &[format!("wss://{}:{}/ws", endpoint.host, endpoint.port)],
            ),
            endpoint.spki_sha256,
        ))
    }

    pub(crate) async fn members(&self) -> Result<Vec<MemberView>> {
        let records = self.store.all().await?;
        let mut observations = self.observations.write().await;
        Ok(records
            .into_iter()
            .filter(|record| record.state != MemberState::Removed)
            .map(|record| {
                if observations
                    .get(&record.host)
                    .is_some_and(|view| view.membership != record.membership)
                {
                    observations.remove(&record.host);
                }
                let mut view = observations
                    .entry(record.host.clone())
                    .or_insert_with(|| MemberView {
                        host: record.host.clone(),
                        name: record.name.clone(),
                        membership: record.membership.clone(),
                        state: record.state,
                        incarnation: None,
                        capabilities: Vec::new(),
                        reachability: Reachability {
                            state: ReachabilityState::Unknown,
                            since: timestamp(),
                            last_seen_at: None,
                        },
                        version: None,
                        protocol: None,
                        load: None,
                        routes: record.routes.clone(),
                    })
                    .clone();
                view.state = record.state;
                view.name = record.name;
                view.routes = self.routes_for(&record.host, &record.routes);
                view
            })
            .collect())
    }

    pub(crate) async fn is_connected(&self, host: &str) -> bool {
        let Ok(record) = self.store.resolve(host).await else {
            return false;
        };
        let slot = self
            .connections
            .lock()
            .await
            .get(&record.membership)
            .cloned();
        match slot {
            Some(slot) => slot.lock().await.as_ref().is_some_and(Connection::is_alive),
            None => false,
        }
    }

    pub(crate) async fn refresh_members(&self) -> Result<()> {
        use futures_util::stream;
        let identity = self.identity.read().await.clone();
        stream::iter(self.store.all().await?.into_iter().filter(|member| member.state == MemberState::Active))
            .for_each_concurrent(64, |member| {
                let identity = &identity;
                async move {
                    let _ = self.call(&member.host, "cluster/hello", json!({"protocol":PROTOCOL,"host":identity.host_id,"incarnation":identity.incarnation})).await;
                }
            }).await;
        Ok(())
    }

    pub(crate) async fn call(
        &self,
        host: &str,
        method: &str,
        params: Value,
    ) -> std::result::Result<Value, LinkError> {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
        let record = self
            .store
            .resolve(host)
            .await
            .map_err(|error| LinkError::local(ErrorClass::Refused, error))?;
        if record.state != MemberState::Active && method != "cluster/removed" {
            return Err(LinkError::local(
                ErrorClass::Refused,
                "membership was removed",
            ));
        }
        let slot = {
            let mut connections = self.connections.lock().await;
            if !connections.contains_key(&record.membership) {
                ensure_capacity(&connections)?;
            }
            connections
                .entry(record.membership.clone())
                .or_default()
                .clone()
        };
        let mut cached = tokio::time::timeout_at(deadline, slot.lock())
            .await
            .map_err(|_| LinkError::local(ErrorClass::Unavailable, "member connection is busy"))?;
        let spec = crate::rpc::dispatch::method_spec(method);
        let read_only = matches!(
            spec.lifetime.or(spec.claude.map(|claude| claude.lifetime)),
            Some(
                crate::rpc::dispatch::RequestLifetime::Query
                    | crate::rpc::dispatch::RequestLifetime::Status
            )
        );
        let mut any_transmitted = false;
        for attempt in 0..2 {
            let previous = cached.take().filter(Connection::is_alive);
            let transmitted = Arc::new(AtomicBool::new(false));
            let result = tokio::time::timeout_at(deadline, async {
                let fresh = previous.is_none();
                let mut connection = match previous {
                    Some(connection) => connection,
                    None => self.connect(&record, &slot, deadline).await?,
                };
                let capability = if method.starts_with("sessions/") {
                    "sessions.v1"
                } else if method.starts_with("agent/parent/") {
                    "agent.parent.v1"
                } else if method.starts_with("agent/") {
                    "agent.jobs.v1"
                } else {
                    "cluster.v1"
                };
                if !connection
                    .hello
                    .capabilities
                    .iter()
                    .any(|value| value == capability)
                {
                    *cached = Some(connection);
                    return Err(LinkError::local(
                        ErrorClass::Unsupported,
                        format!("member lacks {capability}"),
                    ));
                }
                let result = if fresh && method == "cluster/hello" {
                    Ok(json!(connection.hello))
                } else {
                    let id = self.next_id.fetch_add(1, Ordering::Relaxed);
                    let request = crate::wire::json::encode(
                        &json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}),
                    )
                    .map_err(|error| LinkError::local(ErrorClass::Usage, error))?;
                    let crate::wire::json::EncodedJson::Text(request) = request else {
                        *cached = Some(connection);
                        return Err(LinkError::local(
                            ErrorClass::Usage,
                            "member request exceeds frame capacity",
                        ));
                    };
                    connection.request(id, request, transmitted.clone()).await
                };
                if let Ok(value) = &result {
                    if method == "cluster/hello" {
                        let hello: HelloReceipt = serde_json::from_value(value.clone())
                            .map_err(|error| LinkError::local(ErrorClass::Refused, error))?;
                        if hello.host != record.host || hello.protocol != PROTOCOL {
                            return Err(LinkError {
                                cause: Failure::Protocol,
                                class: ErrorClass::Unsupported,
                                transmitted: transmitted.load(Ordering::Acquire),
                                message: "member hello identity or protocol changed".into(),
                            });
                        }
                        connection.hello = hello;
                    }
                    self.observe(&record, &connection.hello).await;
                }
                if connection.is_alive() {
                    *cached = Some(connection);
                }
                result
            })
            .await
            .unwrap_or_else(|_| {
                Err(LinkError::transport(
                    "member request deadline exceeded",
                    transmitted.load(Ordering::Acquire),
                ))
            });
            any_transmitted |= transmitted.load(Ordering::Acquire);
            let mut error = match result {
                Ok(value) => return Ok(value),
                Err(error) => error,
            };
            error.transmitted |= any_transmitted;
            if let Failure::Peer(reply) = &error.cause
                && reply["data"]["kind"] == "membership_removed"
                && let (Some(host), Some(membership)) = (
                    reply["data"]["host"].as_str(),
                    reply["data"]["membership"].as_str(),
                )
            {
                self.confirm_removed(
                    &record,
                    &super::members::MembershipRemoved {
                        host: host.into(),
                        membership: membership.into(),
                    },
                )
                .await
                .map_err(|failure| LinkError::local(ErrorClass::Unavailable, failure))?;
            }
            if attempt == 0
                && matches!(error.cause, Failure::Transport)
                && (!error.transmitted || read_only)
                && tokio::time::Instant::now() < deadline
            {
                continue;
            }
            self.observe_failure(&record, &error).await;
            return Err(error);
        }
        unreachable!("member call has at most two attempts")
    }

    pub(crate) async fn update_identity(&self, identity: HostIdentity) {
        *self.identity.write().await = identity;
        self.connections.lock().await.clear();
        self.observations.write().await.clear();
    }

    async fn confirm_removed(
        &self,
        record: &MemberRecord,
        evidence: &super::members::MembershipRemoved,
    ) -> Result<()> {
        let identity = self.identity.read().await;
        let matches = evidence.host == identity.host_id && evidence.membership == record.membership;
        drop(identity);
        if matches && record.state == MemberState::RemovePending {
            self.store
                .remove(
                    RemoveParams {
                        protocol: PROTOCOL,
                        host: record.host.clone(),
                        membership: record.membership.clone(),
                    },
                    false,
                )
                .await?;
        }
        Ok(())
    }

    async fn connect(
        &self,
        record: &MemberRecord,
        slot: &Arc<Mutex<Option<Connection>>>,
        deadline: tokio::time::Instant,
    ) -> std::result::Result<Connection, LinkError> {
        let identity = self.identity.read().await.clone();
        let token = record.credential.as_ref().ok_or_else(|| {
            LinkError::local(ErrorClass::Refused, "member Join has not been accepted")
        })?;
        let provider = Arc::new(ring::default_provider());
        let config = ClientConfig::builder_with_provider(provider.clone())
            .with_protocol_versions(&[&TLS13])
            .map_err(|error| LinkError::local(ErrorClass::Refused, error))?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(super::dialer::SpkiPin {
                pin: record.pin.clone(),
                provider,
            }))
            .with_no_client_auth();
        let mut failure = LinkError::local(ErrorClass::Unavailable, "member has no routes");
        let routes = self.routes_for(&record.host, &record.routes);
        for (index, route) in routes.iter().enumerate() {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            let routes_left = u32::try_from(routes.len() - index).unwrap_or(u32::MAX);
            let attempt_deadline = tokio::time::Instant::now() + remaining / routes_left;
            let mut request = route
                .as_str()
                .into_client_request()
                .map_err(|error| LinkError::local(ErrorClass::Usage, error))?;
            request.headers_mut().insert(
                "Authorization",
                format!("Bearer {token}")
                    .parse()
                    .map_err(|error| LinkError::local(ErrorClass::Refused, error))?,
            );
            let connected = tokio::time::timeout_at(attempt_deadline, async {
                let stream = dial(request.uri()).await.map_err(|error| LinkError::transport(error, false))?;
                let (mut socket, _) = tokio_tungstenite::client_async_tls_with_config(request, stream, Some(crate::providers::codex::daemon::websocket_config()), Some(Connector::Rustls(Arc::new(config.clone())))).await.map_err(|error| {
                    if let tokio_tungstenite::tungstenite::Error::Http(response) = &error {
                        if response.status() == tokio_tungstenite::tungstenite::http::StatusCode::FORBIDDEN && response.headers().get("x-remotecoder-refusal").and_then(|v|v.to_str().ok()) == Some("membership_removed") {
                            let headers=response.headers();
                            return LinkError::peer(json!({"message":"membership was removed","data":{"class":"refused","kind":"membership_removed","host":headers.get("x-remotecoder-peer-host").and_then(|v|v.to_str().ok()),"membership":headers.get("x-remotecoder-membership").and_then(|v|v.to_str().ok())}}));
                        }
                        return LinkError::local(ErrorClass::Refused, format!("member refused upgrade with {}", response.status()));
                    }
                    if matches!(error, tokio_tungstenite::tungstenite::Error::Tls(_)) {
                        return LinkError::local(ErrorClass::Refused,error);
                    }
                    LinkError::transport(error, false)
                })?;
                loop {
                    match socket.next().await.ok_or_else(||LinkError::transport("member closed before ready",false))?.map_err(|error|LinkError::transport(error,false))? {
                        Message::Text(text) if serde_json::from_str::<Value>(&text).map_err(|error|LinkError::local(ErrorClass::Refused,error))?["method"] == "daemon/ready" => break,
                        Message::Ping(value) => socket.send(Message::Pong(value)).await.map_err(|error|LinkError::transport(error,false))?,
                        Message::Close(_) => return Err(LinkError::transport("member closed before ready",false)),
                        _ => {}
                    }
                }
                socket.send(Message::Text(json!({"jsonrpc":"2.0","id":0,"method":"cluster/hello","params":{"protocol":PROTOCOL,"host":identity.host_id,"incarnation":identity.incarnation}}).to_string())).await.map_err(|error|LinkError::transport(error,false))?;
                let hello: HelloReceipt = serde_json::from_value(response(&mut socket,0).await?).map_err(|error|LinkError::local(ErrorClass::Refused,error))?;
                if hello.host != record.host { return Err(LinkError::local(ErrorClass::Refused,"member identity changed")); }
                if hello.protocol != PROTOCOL {return Err(LinkError {cause:Failure::Protocol,class:ErrorClass::Unsupported,transmitted:false,message:"member cluster protocol is unsupported".into()});}
                self.observe(record,&hello).await;
                let wake = self.wakes.lock().await.entry(record.host.clone()).or_insert_with(||tokio::sync::watch::channel(0).0).clone();
                Ok(Connection::new(socket,hello,Arc::downgrade(slot),Some(wake)))
            }).await;
            match connected {
                Ok(Ok(connection)) => return Ok(connection),
                Ok(Err(mut error)) if !matches!(error.cause, Failure::Transport) => {
                    error.transmitted = false;
                    return Err(error);
                }
                Ok(Err(error)) => failure = error,
                Err(_) => failure = LinkError::transport("member connect deadline exceeded", false),
            }
        }
        Err(failure)
    }

    async fn observe(&self, record: &MemberRecord, hello: &HelloReceipt) {
        let mut observations = self.observations.write().await;
        let changed = observations.get(&record.host).is_none_or(|view| {
            view.membership != record.membership
                || view.incarnation.as_ref() != Some(&hello.incarnation)
                || view.reachability.state != ReachabilityState::Reachable
        });
        let since = observations
            .get(&record.host)
            .filter(|view| {
                view.membership == record.membership
                    && view.reachability.state == ReachabilityState::Reachable
            })
            .map(|view| view.reachability.since.clone())
            .unwrap_or_else(timestamp);
        observations.insert(
            record.host.clone(),
            MemberView {
                host: record.host.clone(),
                name: record.name.clone(),
                membership: record.membership.clone(),
                state: record.state,
                incarnation: Some(hello.incarnation.clone()),
                capabilities: hello.capabilities.clone(),
                reachability: Reachability {
                    state: ReachabilityState::Reachable,
                    since,
                    last_seen_at: Some(timestamp()),
                },
                version: Some(hello.version.clone()),
                protocol: Some(hello.protocol),
                load: Some(hello.load.clone()),
                routes: record.routes.clone(),
            },
        );
        drop(observations);
        if changed {
            tracing::info!(host=%record.host, "cluster member is reachable");
            self.wake_member(&record.host).await;
        }
    }

    async fn observe_failure(&self, record: &MemberRecord, error: &LinkError) {
        if !matches!(error.cause, Failure::Transport | Failure::Protocol) {
            return;
        }
        let _ = self.members().await;
        let mut observations = self.observations.write().await;
        if let Some(view) = observations.get_mut(&record.host) {
            let state = if error.class == ErrorClass::Unsupported {
                ReachabilityState::Unsupported
            } else {
                ReachabilityState::Unreachable
            };
            if view.reachability.state != state {
                view.reachability.since = timestamp();
                tracing::warn!(host = %record.host, name = %record.name, state = ?state, error = %error.message, "cluster member is not reachable");
            }
            view.reachability.state = state;
        }
    }

    pub(crate) async fn forget(&self, membership: &str) {
        self.connections.lock().await.remove(membership);
    }
}

const ATTEMPT_DELAY: Duration = Duration::from_millis(250);

async fn dial(
    uri: &tokio_tungstenite::tungstenite::http::Uri,
) -> std::io::Result<tokio::net::TcpStream> {
    let host = uri.host().unwrap_or_default();
    let host = host.trim_start_matches('[').trim_end_matches(']');
    let addresses = tokio::net::lookup_host((host, uri.port_u16().unwrap_or(443)))
        .await?
        .collect();
    race(addresses, tokio::net::TcpStream::connect).await
}

async fn race<T, F, Attempt>(addresses: Vec<std::net::SocketAddr>, connect: F) -> std::io::Result<T>
where
    F: Fn(std::net::SocketAddr) -> Attempt,
    Attempt: std::future::Future<Output = std::io::Result<T>>,
{
    let mut attempts = futures_util::stream::FuturesUnordered::new();
    for (index, address) in addresses.into_iter().enumerate() {
        let attempt = connect(address);
        let delay = ATTEMPT_DELAY * u32::try_from(index).unwrap_or(u32::MAX);
        attempts.push(async move {
            tokio::time::sleep(delay).await;
            attempt.await
        });
    }
    let mut failure = None;
    while let Some(result) = attempts.next().await {
        match result {
            Ok(stream) => return Ok(stream),
            Err(error) => failure = Some(error),
        }
    }
    Err(failure.unwrap_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::NotFound, "member route has no address")
    }))
}

fn ensure_capacity(
    connections: &HashMap<String, Arc<Mutex<Option<Connection>>>>,
) -> std::result::Result<(), LinkError> {
    if connections.len() >= 4096 {
        return Err(LinkError::local(
            ErrorClass::Refused,
            "member connection capacity reached",
        ));
    }
    Ok(())
}

async fn response(socket: &mut Socket, id: u64) -> std::result::Result<Value, LinkError> {
    while let Some(message) = socket.next().await {
        match message.map_err(|error| LinkError::transport(error, false))? {
            Message::Text(text) => {
                let response: Value = serde_json::from_str(&text)
                    .map_err(|error| LinkError::local(ErrorClass::Refused, error))?;
                if response["id"].as_u64() == Some(id) {
                    return receipt(response);
                }
            }
            Message::Ping(value) => socket
                .send(Message::Pong(value))
                .await
                .map_err(|error| LinkError::transport(error, false))?,
            Message::Close(_) => break,
            _ => {}
        }
    }
    Err(LinkError::transport(
        "member closed before its receipt",
        false,
    ))
}

fn receipt(response: Value) -> std::result::Result<Value, LinkError> {
    if let Some(error) = response.get("error") {
        return Err(LinkError::peer(error.clone()));
    }
    response
        .get("result")
        .cloned()
        .ok_or_else(|| LinkError::local(ErrorClass::Refused, "member returned no result"))
}

#[cfg(test)]
mod reconnect_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn a_stalled_first_address_does_not_starve_a_later_one() {
        let started = tokio::time::Instant::now();
        let addresses = vec![
            "[::1]:8789".parse().unwrap(),
            "127.0.0.1:8789".parse().unwrap(),
        ];
        let connected = race(addresses, |address: std::net::SocketAddr| async move {
            if address.is_ipv6() {
                std::future::pending::<std::io::Result<std::net::SocketAddr>>().await
            } else {
                Ok(address)
            }
        })
        .await
        .unwrap();
        assert!(connected.is_ipv4());
        assert_eq!(started.elapsed(), ATTEMPT_DELAY);
    }

    #[tokio::test]
    async fn cluster_fault_old_member_is_unsupported_before_admission_is_sent() {
        let directory = tempfile::tempdir().unwrap();
        let host = crate::ids::new_session_uuid();
        let membership = crate::ids::new_session_uuid();
        let link = Link::new(
            directory.path(),
            HostIdentity {
                host_id: crate::ids::new_session_uuid(),
                incarnation: crate::ids::new_session_uuid(),
            },
        );
        let credential = link
            .store
            .issue(IssueParams {
                protocol: PROTOCOL,
                r#for: host.clone(),
                name: "old".into(),
                membership: membership.clone(),
            })
            .await
            .unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            assert!(matches!(
                socket.next().await,
                None | Some(Err(_)) | Some(Ok(Message::Close(_)))
            ));
        });
        use base64::Engine;
        link.store
            .accept(AcceptParams {
                protocol: PROTOCOL,
                host: host.clone(),
                name: "old".into(),
                membership: membership.clone(),
                pin: base64::engine::general_purpose::STANDARD.encode([0u8; 32]),
                routes: vec![format!("wss://{address}/ws")],
                credential,
            })
            .await
            .unwrap();
        let stream = tokio::net::TcpStream::connect(address).await.unwrap();
        let (socket, _) = tokio_tungstenite::client_async(
            format!("ws://{address}/ws"),
            MaybeTlsStream::Plain(stream),
        )
        .await
        .unwrap();
        let hello = HelloReceipt {
            protocol: PROTOCOL,
            version: "old".into(),
            host: host.clone(),
            incarnation: crate::ids::new_session_uuid(),
            capabilities: vec!["cluster.v1".into()],
            routes: vec![],
            load: HostLoad {
                cpu_percent: None,
                memory_pressure: None,
                active_agents: 0,
            },
        };
        let slot = Arc::new(Mutex::new(None));
        *slot.lock().await = Some(Connection::new(socket, hello, Arc::downgrade(&slot), None));
        link.connections.lock().await.insert(membership, slot);
        let error = link
            .call(&host, "agent/jobs/admit", json!({}))
            .await
            .unwrap_err();
        assert_eq!(error.class, ErrorClass::Unsupported);
        assert!(!error.transmitted);
        assert_eq!(
            link.members().await.unwrap()[0].reachability.state,
            ReachabilityState::Unknown
        );
        link.forget(&link.store.resolve(&host).await.unwrap().membership)
            .await;
        server.await.unwrap();
    }
    #[tokio::test]
    async fn cluster_lost_removal_ack_reconciles_only_exact_tombstone_evidence() {
        use base64::Engine;
        for exact in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let local = crate::ids::new_session_uuid();
            let host = crate::ids::new_session_uuid();
            let membership = crate::ids::new_session_uuid();
            let link = Link::new(
                directory.path(),
                HostIdentity {
                    host_id: local.clone(),
                    incarnation: crate::ids::new_session_uuid(),
                },
            );
            let credential = link
                .store
                .issue(IssueParams {
                    protocol: PROTOCOL,
                    r#for: host.clone(),
                    name: "peer".into(),
                    membership: membership.clone(),
                })
                .await
                .unwrap();
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            link.store
                .accept(AcceptParams {
                    protocol: PROTOCOL,
                    host: host.clone(),
                    name: "peer".into(),
                    membership: membership.clone(),
                    pin: base64::engine::general_purpose::STANDARD.encode([0u8; 32]),
                    routes: vec![format!("wss://{address}/ws")],
                    credential,
                })
                .await
                .unwrap();
            link.store
                .remove(
                    RemoveParams {
                        protocol: PROTOCOL,
                        host: host.clone(),
                        membership: membership.clone(),
                    },
                    true,
                )
                .await
                .unwrap();
            let data = json!({"class":"refused","kind":"membership_removed","host":if exact {local} else {crate::ids::new_session_uuid()},"membership":membership});
            let server = tokio::spawn(async move {
                let (stream, _) = listener.accept().await.unwrap();
                let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
                let Message::Text(request) = socket.next().await.unwrap().unwrap() else {
                    panic!("expected removal RPC")
                };
                let request: Value = serde_json::from_str(&request).unwrap();
                assert_eq!(request["method"], "cluster/removed");
                socket.send(Message::Text(json!({"jsonrpc":"2.0","id":request["id"],"error":{"code":-32000,"message":"membership removed","data":data}}).to_string())).await.unwrap();
            });
            let stream = tokio::net::TcpStream::connect(address).await.unwrap();
            let (socket, _) = tokio_tungstenite::client_async(
                format!("ws://{address}/ws"),
                MaybeTlsStream::Plain(stream),
            )
            .await
            .unwrap();
            let hello = HelloReceipt {
                protocol: PROTOCOL,
                version: "test".into(),
                host: host.clone(),
                incarnation: crate::ids::new_session_uuid(),
                capabilities: vec!["cluster.v1".into()],
                routes: vec![],
                load: HostLoad {
                    cpu_percent: None,
                    memory_pressure: None,
                    active_agents: 0,
                },
            };
            let slot = Arc::new(Mutex::new(None));
            *slot.lock().await = Some(Connection::new(socket, hello, Arc::downgrade(&slot), None));
            link.connections
                .lock()
                .await
                .insert(membership.clone(), slot);
            let error = link
                .call(&host, "cluster/removed", json!({}))
                .await
                .unwrap_err();
            assert_eq!(error.class, ErrorClass::Refused);
            assert_eq!(
                link.store.is_removed(&host, &membership).await.unwrap(),
                exact
            );
            server.await.unwrap();
        }
    }
}
