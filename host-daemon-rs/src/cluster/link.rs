use std::collections::HashMap;
use std::fmt;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use anyhow::{Context, Result, ensure};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::{Mutex, RwLock};
use tokio_rustls::rustls::{ClientConfig, crypto::ring, version::TLS13};
use tokio_tungstenite::{Connector, MaybeTlsStream, WebSocketStream, tungstenite::{Message, client::IntoClientRequest}};

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
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result { formatter.write_str(&self.message) }
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
pub(crate) enum ReachabilityState { Reachable, Unreachable, Unsupported }

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

struct Connection { socket: Socket, hello: HelloReceipt }

pub(crate) struct Link {
    pub(crate) store: Members,
    identity: HostIdentity,
    connections: Mutex<HashMap<String, Arc<Mutex<Option<Connection>>>>>,
    observations: RwLock<HashMap<String, MemberView>>,
    endpoint: RwLock<Option<crate::http::lan::LanEndpoint>>,
    next_id: AtomicU64,
}

pub(crate) fn timestamp() -> String {
    time::OffsetDateTime::now_utc().format(&time::format_description::well_known::Rfc3339).expect("UTC timestamp formats as RFC 3339")
}

impl Link {
    pub(crate) fn new(state: &Path, identity: HostIdentity) -> Self {
        Self { store: Members::new(state), identity, connections: Mutex::new(HashMap::new()), observations: RwLock::new(HashMap::new()), endpoint: RwLock::new(None), next_id: AtomicU64::new(1) }
    }

    pub(crate) async fn set_endpoint(&self, endpoint: Option<crate::http::lan::LanEndpoint>) { *self.endpoint.write().await = endpoint; }

    pub(crate) async fn endpoint(&self) -> Result<(Vec<String>, String)> {
        let endpoint = self.endpoint.read().await.clone().context("cluster Join requires the pinned LAN TLS listener")?;
        Ok((vec![format!("wss://{}:{}/ws",endpoint.host,endpoint.port)],endpoint.spki_sha256))
    }

    pub(crate) async fn members(&self) -> Result<Vec<MemberView>> {
        let records = self.store.all().await?;
        let observations = self.observations.read().await;
        Ok(records.into_iter().filter(|record|record.state != MemberState::Removed).map(|record| {
            let mut view = observations.get(&record.host).filter(|view|view.membership == record.membership).cloned().unwrap_or_else(||MemberView {
                host: record.host.clone(), name: record.name.clone(), membership: record.membership.clone(), state: record.state, incarnation: None, capabilities: Vec::new(), reachability: Reachability {state: ReachabilityState::Unreachable, since: timestamp(), last_seen_at:None}, version:None, protocol:None, load:None, routes:record.routes.clone(),
            });
            view.state = record.state;
            view
        }).collect())
    }

    pub(crate) async fn call(&self, host: &str, method: &str, params: Value) -> std::result::Result<Value, LinkError> {
        let record = self.store.resolve(host).await.map_err(|error|LinkError {class:ErrorClass::Refused,transmitted:false,message:error.to_string()})?;
        let slot = {
            let mut connections = self.connections.lock().await;
            ensure_capacity(&connections)?;
            connections.entry(record.membership.clone()).or_default().clone()
        };
        let mut slot = tokio::time::timeout(Duration::from_secs(10),slot.lock()).await.map_err(|_|LinkError {class:ErrorClass::Unavailable,transmitted:false,message:"member connection is busy".into()})?;
        let previous = slot.take();
        let mut transmitted = false;
        let result = tokio::time::timeout(Duration::from_secs(10), async {
            let mut connection = match previous { Some(connection)=>connection, None=>self.connect(&record).await? };
            ensure!(connection.hello.host == record.host, "member returned another host identity");
            let capability = if method.starts_with("sessions/") { "sessions.v1" } else if method.starts_with("agent/parent/") { "agent.parent.v1" } else if method.starts_with("agent/") { "agent.jobs.v1" } else { "cluster.v1" };
            if !connection.hello.capabilities.iter().any(|value|value == capability) {
                return Err(anyhow::anyhow!(LinkError {class:ErrorClass::Unsupported,transmitted:false,message:format!("member lacks {capability}")}));
            }
            let id = self.next_id.fetch_add(1,Ordering::Relaxed);
            let request = crate::wire::json::encode(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))?;
            let crate::wire::json::EncodedJson::Text(request) = request else { anyhow::bail!("member request exceeds frame capacity"); };
            transmitted = true;
            connection.socket.send(Message::Text(request)).await?;
            let result = response(&mut connection.socket,id).await?;
            *slot = Some(connection);
            Ok(result)
        }).await;
        let result = match result {
            Ok(Ok(value))=>Ok(value),
            Ok(Err(error))=>Err(error.downcast::<LinkError>().unwrap_or_else(|error|LinkError {class:if transmitted {ErrorClass::Uncertain}else{ErrorClass::Unavailable},transmitted,message:error.to_string()})),
            Err(_)=>Err(LinkError {class:if transmitted {ErrorClass::Uncertain}else{ErrorClass::Unavailable},transmitted,message:"member request deadline exceeded".into()}),
        };
        if let Err(error) = &result { self.observe_failure(&record,error).await; }
        result
    }

    async fn connect(&self, record: &MemberRecord) -> Result<Connection> {
        let token = record.credential.as_ref().context("member Join has not been accepted")?;
        let provider = Arc::new(ring::default_provider());
        let config = ClientConfig::builder_with_provider(provider.clone()).with_protocol_versions(&[&TLS13])?.dangerous().with_custom_certificate_verifier(Arc::new(super::dialer::SpkiPin {pin:record.pin.clone(),provider})).with_no_client_auth();
        let mut failure = None;
        for route in &record.routes {
            let mut request = route.as_str().into_client_request()?;
            request.headers_mut().insert("Authorization", format!("Bearer {token}").parse()?);
            let connected = tokio::time::timeout(Duration::from_secs(3),tokio_tungstenite::connect_async_tls_with_config(request,Some(crate::providers::codex::daemon::websocket_config()),false,Some(Connector::Rustls(Arc::new(config.clone()))))).await;
            match connected {
                Ok(Ok((mut socket,_))) => {
                    loop { match socket.next().await.context("member closed before ready")?? {Message::Text(text) if serde_json::from_str::<Value>(&text)?["method"] == "daemon/ready" =>break, Message::Ping(value)=>socket.send(Message::Pong(value)).await?, _=>{} } }
                    socket.send(Message::Text(json!({"jsonrpc":"2.0","id":0,"method":"cluster/hello","params":{"protocol":PROTOCOL,"host":self.identity.host_id,"incarnation":self.identity.incarnation}}).to_string())).await?;
                    let hello: HelloReceipt = serde_json::from_value(response(&mut socket,0).await?)?;
                    ensure!(hello.protocol == PROTOCOL && hello.host == record.host, "member identity or protocol changed");
                    self.observe(record,&hello).await;
                    return Ok(Connection {socket,hello});
                }
                Ok(Err(error))=>failure=Some(error.to_string()),
                Err(_)=>failure=Some("member connect deadline exceeded".into()),
            }
        }
        anyhow::bail!("{}",failure.unwrap_or_else(||"member has no routes".into()))
    }

    async fn observe(&self, record: &MemberRecord, hello: &HelloReceipt) {
        self.observations.write().await.insert(record.host.clone(), MemberView {host:record.host.clone(),name:record.name.clone(),membership:record.membership.clone(),state:record.state,incarnation:Some(hello.incarnation.clone()),capabilities:hello.capabilities.clone(),reachability:Reachability {state:ReachabilityState::Reachable,since:timestamp(),last_seen_at:Some(timestamp())},version:None,protocol:Some(hello.protocol),load:Some(hello.load.clone()),routes:record.routes.clone()});
    }

    async fn observe_failure(&self, record: &MemberRecord, error: &LinkError) {
        let mut observations = self.observations.write().await;
        if let Some(view) = observations.get_mut(&record.host) {
            let state = if error.class == ErrorClass::Unsupported {ReachabilityState::Unsupported}else{ReachabilityState::Unreachable};
            if view.reachability.state != state {view.reachability.since=timestamp();}
            view.reachability.state=state;
        }
    }

    pub(crate) async fn forget(&self, membership: &str) { self.connections.lock().await.remove(membership); }
}

fn ensure_capacity(connections: &HashMap<String,Arc<Mutex<Option<Connection>>>>) -> std::result::Result<(),LinkError> {
    if connections.len() >= 4096 { return Err(LinkError {class:ErrorClass::Refused,transmitted:false,message:"member connection capacity reached".into()}); }
    Ok(())
}

async fn response(socket: &mut Socket, id: u64) -> Result<Value> {
    while let Some(message) = socket.next().await {
        match message? {
            Message::Text(text)=> {
                let response: Value = serde_json::from_str(&text)?;
                if response["id"].as_u64() == Some(id) {
                    if let Some(error) = response.get("error") {
                        let class = error["data"]["class"].as_str().and_then(|class|serde_json::from_value(json!(class)).ok()).unwrap_or(ErrorClass::Refused);
                        return Err(LinkError {class,transmitted:true,message:error["message"].as_str().unwrap_or("member refused request").to_owned()}.into());
                    }
                    return response.get("result").cloned().context("member returned no result");
                }
            }
            Message::Ping(value)=>socket.send(Message::Pong(value)).await?,
            Message::Close(_)=>break,
            _=>{},
        }
    }
    anyhow::bail!("member closed before its receipt")
}
