use std::collections::HashMap;
use std::fmt;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use anyhow::{Context, Result, ensure};
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

#[derive(Debug)]
pub(crate) struct LinkError {
    pub class: ErrorClass,
    pub transmitted: bool,
    pub message: String,
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

    pub(crate) async fn endpoint(&self) -> Result<(Vec<String>, String)> {
        let endpoint = self
            .endpoint
            .read()
            .await
            .clone()
            .context("cluster Join requires the pinned LAN TLS listener")?;
        Ok((
            vec![format!("wss://{}:{}/ws", endpoint.host, endpoint.port)],
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
                            state: ReachabilityState::Unreachable,
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
                view.routes = record.routes;
                view
            })
            .collect())
    }

    pub(crate) async fn refresh_members(&self) -> Result<()> {
        use futures_util::stream;
        let identity = self.identity.read().await.clone();
        stream::iter(
            self.store
                .all()
                .await?
                .into_iter()
                .filter(|member| member.state == MemberState::Active),
        )
        .for_each_concurrent(64, |member| {
            let identity = &identity;
            async move {
                if tokio::time::timeout(
                    Duration::from_secs(2),
                    self.call(
                        &member.host,
                        "cluster/hello",
                        json!({"protocol":PROTOCOL,"host":identity.host_id,"incarnation":identity.incarnation}),
                    ),
                )
                .await
                .is_err()
                {
                    self.observe_failure(
                        &member,
                        &LinkError {
                            class: ErrorClass::Uncertain,
                            transmitted: true,
                            message: "member hello deadline exceeded".into(),
                        },
                    )
                    .await;
                }
            }
        })
        .await;
        Ok(())
    }

    pub(crate) async fn call(
        &self,
        host: &str,
        method: &str,
        params: Value,
    ) -> std::result::Result<Value, LinkError> {
        let record = self.store.resolve(host).await.map_err(|error| LinkError {
            class: ErrorClass::Refused,
            transmitted: false,
            message: error.to_string(),
        })?;
        if record.state != MemberState::Active && method != "cluster/removed" {
            return Err(LinkError {
                class: ErrorClass::Refused,
                transmitted: false,
                message: "membership was removed".into(),
            });
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
        let mut cached = tokio::time::timeout(Duration::from_secs(10), slot.lock())
            .await
            .map_err(|_| LinkError {
                class: ErrorClass::Unavailable,
                transmitted: false,
                message: "member connection is busy".into(),
            })?;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
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
                let mut connection = match previous {
                    Some(connection) => connection,
                    None => self.connect(&record, &slot).await?,
                };
                ensure!(
                    connection.hello.host == record.host,
                    "member returned another host identity"
                );
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
                    return Err(anyhow::anyhow!(LinkError {
                        class: ErrorClass::Unsupported,
                        transmitted: false,
                        message: format!("member lacks {capability}")
                    }));
                }
                let id = self.next_id.fetch_add(1, Ordering::Relaxed);
                let request = crate::wire::json::encode(
                    &json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}),
                )?;
                let crate::wire::json::EncodedJson::Text(request) = request else {
                    return Err(LinkError {
                        class: ErrorClass::Usage,
                        transmitted: false,
                        message: "member request exceeds frame capacity".into(),
                    }
                    .into());
                };
                let result = connection.request(id, request, transmitted.clone()).await?;
                if method == "cluster/hello" {
                    let hello: HelloReceipt = serde_json::from_value(result.clone())?;
                    ensure!(
                        hello.host == record.host && hello.protocol == PROTOCOL,
                        "member hello identity changed"
                    );
                    self.observe(&record, &hello).await;
                    connection.hello = hello;
                }
                if connection.is_alive() {
                    *cached = Some(connection);
                }
                Ok(result)
            })
            .await;
            any_transmitted |= transmitted.load(Ordering::Acquire);
            let error = match result {
                Ok(Ok(value)) => return Ok(value),
                Ok(Err(error)) => error,
                Err(_) => anyhow::anyhow!("member request deadline exceeded"),
            };
            if let Some(evidence) = error.downcast_ref::<super::members::MembershipRemoved>() {
                self.confirm_removed(&record, evidence)
                    .await
                    .map_err(|error| LinkError {
                        class: ErrorClass::Unavailable,
                        transmitted: any_transmitted,
                        message: error.to_string(),
                    })?;
                return Err(LinkError {
                    class: ErrorClass::Refused,
                    transmitted: any_transmitted,
                    message: error.to_string(),
                });
            }
            let transport_failure = error.downcast_ref::<LinkError>().is_none();
            let mut error = error
                .downcast::<LinkError>()
                .unwrap_or_else(|error| LinkError {
                    class: if any_transmitted {
                        ErrorClass::Uncertain
                    } else {
                        ErrorClass::Unavailable
                    },
                    transmitted: any_transmitted,
                    message: error.to_string(),
                });
            error.transmitted |= any_transmitted;
            if attempt == 0
                && transport_failure
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
    ) -> Result<Connection> {
        let identity = self.identity.read().await.clone();
        let token = record
            .credential
            .as_ref()
            .context("member Join has not been accepted")?;
        let provider = Arc::new(ring::default_provider());
        let config = ClientConfig::builder_with_provider(provider.clone())
            .with_protocol_versions(&[&TLS13])?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(super::dialer::SpkiPin {
                pin: record.pin.clone(),
                provider,
            }))
            .with_no_client_auth();
        let mut failure = None;
        for route in &record.routes {
            let mut request = route.as_str().into_client_request()?;
            request
                .headers_mut()
                .insert("Authorization", format!("Bearer {token}").parse()?);
            let connected = tokio::time::timeout(
                Duration::from_secs(3),
                tokio_tungstenite::connect_async_tls_with_config(
                    request,
                    Some(crate::providers::codex::daemon::websocket_config()),
                    false,
                    Some(Connector::Rustls(Arc::new(config.clone()))),
                ),
            )
            .await;
            match connected {
                Ok(Ok((mut socket, _))) => {
                    loop {
                        match socket
                            .next()
                            .await
                            .context("member closed before ready")??
                        {
                            Message::Text(text)
                                if serde_json::from_str::<Value>(&text)?["method"]
                                    == "daemon/ready" =>
                            {
                                break;
                            }
                            Message::Ping(value) => socket.send(Message::Pong(value)).await?,
                            _ => {}
                        }
                    }
                    socket.send(Message::Text(json!({"jsonrpc":"2.0","id":0,"method":"cluster/hello","params":{"protocol":PROTOCOL,"host":identity.host_id,"incarnation":identity.incarnation}}).to_string())).await?;
                    let hello: HelloReceipt =
                        serde_json::from_value(response(&mut socket, 0).await?)?;
                    ensure!(hello.host == record.host, "member identity changed");
                    if hello.protocol != PROTOCOL {
                        return Err(LinkError {
                            class: ErrorClass::Unsupported,
                            transmitted: false,
                            message: "member cluster protocol is unsupported".into(),
                        }
                        .into());
                    }
                    self.observe(record, &hello).await;
                    return Ok(Connection::new(socket, hello, Arc::downgrade(slot)));
                }
                Ok(Err(tokio_tungstenite::tungstenite::Error::Http(response))) => {
                    let headers = response.headers();
                    if response.status()
                        == tokio_tungstenite::tungstenite::http::StatusCode::FORBIDDEN
                        && headers
                            .get("x-remotecoder-refusal")
                            .and_then(|value| value.to_str().ok())
                            == Some("membership_removed")
                        && let (Some(host), Some(membership)) = (
                            headers
                                .get("x-remotecoder-peer-host")
                                .and_then(|value| value.to_str().ok()),
                            headers
                                .get("x-remotecoder-membership")
                                .and_then(|value| value.to_str().ok()),
                        )
                    {
                        let evidence = super::members::MembershipRemoved {
                            host: host.into(),
                            membership: membership.into(),
                        };
                        self.confirm_removed(record, &evidence).await?;
                        return Err(evidence.into());
                    }
                    failure = Some(format!("member refused upgrade with {}", response.status()));
                }
                Ok(Err(error)) => failure = Some(error.to_string()),
                Err(_) => failure = Some("member connect deadline exceeded".into()),
            }
        }
        anyhow::bail!(
            "{}",
            failure.unwrap_or_else(|| "member has no routes".into())
        )
    }

    async fn observe(&self, record: &MemberRecord, hello: &HelloReceipt) {
        let mut observations = self.observations.write().await;
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
        self.wake_member(&record.host).await;
    }

    async fn observe_failure(&self, record: &MemberRecord, error: &LinkError) {
        if !matches!(
            error.class,
            ErrorClass::Unavailable | ErrorClass::Uncertain | ErrorClass::Unsupported
        ) {
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
            }
            view.reachability.state = state;
        }
    }

    pub(crate) async fn forget(&self, membership: &str) {
        self.connections.lock().await.remove(membership);
    }
}

fn ensure_capacity(
    connections: &HashMap<String, Arc<Mutex<Option<Connection>>>>,
) -> std::result::Result<(), LinkError> {
    if connections.len() >= 4096 {
        return Err(LinkError {
            class: ErrorClass::Refused,
            transmitted: false,
            message: "member connection capacity reached".into(),
        });
    }
    Ok(())
}

async fn response(socket: &mut Socket, id: u64) -> Result<Value> {
    while let Some(message) = socket.next().await {
        match message? {
            Message::Text(text) => {
                let response: Value = serde_json::from_str(&text)?;
                if response["id"].as_u64() == Some(id) {
                    return receipt(response);
                }
            }
            Message::Ping(value) => socket.send(Message::Pong(value)).await?,
            Message::Close(_) => break,
            _ => {}
        }
    }
    anyhow::bail!("member closed before its receipt")
}

fn receipt(response: Value) -> Result<Value> {
    if let Some(error) = response.get("error") {
        if error["data"]["kind"] == "membership_removed"
            && let (Some(host), Some(membership)) = (
                error["data"]["host"].as_str(),
                error["data"]["membership"].as_str(),
            )
        {
            return Err(super::members::MembershipRemoved {
                host: host.into(),
                membership: membership.into(),
            }
            .into());
        }
        return Err(LinkError {
            class: ErrorClass::from_rpc(error),
            transmitted: true,
            message: error["message"]
                .as_str()
                .unwrap_or("member refused request")
                .to_owned(),
        }
        .into());
    }
    response
        .get("result")
        .cloned()
        .context("member returned no result")
}

#[cfg(test)]
mod reconnect_tests;

#[cfg(test)]
mod tests {
    use super::*;

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
        *slot.lock().await = Some(Connection::new(socket, hello, Arc::downgrade(&slot)));
        link.connections.lock().await.insert(membership, slot);
        let error = link
            .call(&host, "agent/jobs/admit", json!({}))
            .await
            .unwrap_err();
        assert_eq!(error.class, ErrorClass::Unsupported);
        assert!(!error.transmitted);
        assert_eq!(
            link.members().await.unwrap()[0].reachability.state,
            ReachabilityState::Unsupported
        );
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
            *slot.lock().await = Some(Connection::new(socket, hello, Arc::downgrade(&slot)));
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
