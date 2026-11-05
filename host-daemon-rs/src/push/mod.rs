mod broker;
mod live_activity;
#[cfg(test)]
mod tests;

use std::path::PathBuf;
use std::sync::Arc;

use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use tokio::sync::{Mutex, watch};
use tracing::{info, warn};

use crate::devices::{AlertTarget, Destination, DeviceRegistry, TokenKind};
use crate::observability::journal::Journal;
use crate::time::unix_seconds;
use broker::{
    BrokerAlertRequest, BrokerLiveActivityRequest, BrokerLocationRequest, BrokerRequestError,
    LiveActivityEvent, PushBroker, apns_collapse_id,
};
pub(crate) use broker::{Delivered, DeliveryFailure, DeliveryOutcome};
pub(crate) use live_activity::{
    AttentionReason, AttentionRow, FleetSnapshot, Freshness, LiveActivityContent,
    LiveActivitySnapshot, MAX_ATTENTION_ROWS, MAX_FLEET_HOSTS, PeerOutcome, PeerReport,
    SourceProjection, attention_title,
};

const PAYLOAD_KEY: &str = "remoteCoder.taskCompletionPayload";
const ALERT_SOUND: &str = "remote-coder-notification.wav";
const MAX_CONCURRENT_SENDS: usize = 4;
const NO_ALERT_DEVICE: &str = "no alert device registered";
const NO_LIVE_ACTIVITY_DEVICE: &str = "no live activity device registered";
const REGISTRY_UNREADABLE: &str = "device registry unreadable";

#[derive(Clone)]
pub(crate) enum PushConfiguration {
    Disabled,
    MissingToken,
    Configured { url: String, token: String },
}

impl std::fmt::Debug for PushConfiguration {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Disabled => formatter.write_str("Disabled"),
            Self::MissingToken => formatter.write_str("MissingToken"),
            Self::Configured { url, .. } => formatter
                .debug_struct("Configured")
                .field("url", url)
                .field("token", &"[REDACTED]")
                .finish(),
        }
    }
}

impl PushConfiguration {
    pub(crate) fn load(sources: &crate::config::ConfigSources) -> anyhow::Result<Self> {
        let token = sources.optional_string("RC_PUSH_BROKER_TOKEN");
        if !sources.optional_bool("RC_CODEX_GATEWAY_PUSH_BROKER_ENABLED", token.is_some())? {
            return Ok(Self::Disabled);
        }
        let Some(token) = token else {
            return Ok(Self::MissingToken);
        };
        Ok(Self::Configured {
            url: sources
                .optional_string("RC_PUSH_BROKER_URL")
                .unwrap_or_else(|| "http://127.0.0.1:5012".to_owned()),
            token,
        })
    }
}

struct Delivery<'a> {
    kind: TokenKind,
    journal: Option<&'static str>,
    destination: &'a Destination,
    fields: Value,
}

struct AlertContent<'a> {
    stream: &'static str,
    title: &'a str,
    subtitle: Option<&'a str>,
    body: &'a str,
    collapse_id: &'a str,
    completion: Option<&'a Value>,
    fields: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum PushEnvironment {
    Development,
    Production,
}

impl PushEnvironment {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Development => "development",
            Self::Production => "production",
        }
    }
}

#[derive(Debug)]
pub(crate) struct PushService {
    broker: Option<PushBroker>,
    /// Why there is no broker, for the journal line that records the skip.
    unavailable_reason: Option<&'static str>,
    devices: Arc<DeviceRegistry>,
    journal: Journal,
    live_activity_sources: std::sync::Mutex<live_activity::Sources>,
    live_activity_publication: Mutex<live_activity::Publication>,
    live_activity_epoch: String,
    live_activity_updates: watch::Sender<Option<LiveActivitySnapshot>>,
    peer_reports: watch::Sender<Option<PeerReport>>,
    referenced_threads:
        watch::Sender<std::collections::BTreeSet<crate::wire::cluster::AgentAddress>>,
    fleet_changes: watch::Sender<u64>,
}

#[derive(Clone)]
struct ActivityPayload {
    fleet: bool,
    ends: bool,
    state: Value,
    relevance_score: u8,
    identity: Value,
}

impl ActivityPayload {
    fn local(content: &LiveActivityContent, superseded: bool) -> Self {
        Self::new(
            false,
            !superseded && content.is_empty(),
            content,
            serde_json::json!({}),
        )
    }

    fn fleet(content: &live_activity::FleetContent) -> Self {
        Self::new(
            true,
            content.is_certified_empty(),
            &content.content,
            serde_json::json!({"unavailableHostIDs": content.unavailable_host_ids}),
        )
    }

    fn new(fleet: bool, ends: bool, content: &LiveActivityContent, mut extra: Value) -> Self {
        extra["activeTaskCount"] = Value::from(content.active_task_count);
        extra["attention"] = serde_json::json!(content.attention);
        extra["attentionCount"] = Value::from(content.attention_count);
        Self {
            fleet,
            ends,
            relevance_score: content.relevance_score(),
            identity: serde_json::json!({"ends": ends, "state": extra}),
            state: extra,
        }
    }
}

impl PushService {
    pub fn new(
        configuration: PushConfiguration,
        journal: Journal,
        devices: Arc<DeviceRegistry>,
        live_activity_path: Option<PathBuf>,
    ) -> Self {
        let disabled = matches!(&configuration, PushConfiguration::Disabled);
        let (broker, unavailable_reason) = match configuration {
            PushConfiguration::Disabled => (None, Some("broker disabled")),
            PushConfiguration::MissingToken => (None, Some("broker not configured")),
            PushConfiguration::Configured { url, token } => {
                (Some(PushBroker::new(url, token)), None)
            }
        };

        if disabled {
            info!("push broker explicitly disabled for this gateway");
        } else if let Some(broker) = broker.as_ref() {
            info!(
                "push broker configured topic={} broker_url={}",
                devices.bundle_id(),
                broker.url()
            );
        } else {
            info!("push broker not configured (missing token/config)");
        }

        let (sources, publication) = live_activity::load(live_activity_path);
        Self {
            broker,
            unavailable_reason,
            devices,
            journal,
            referenced_threads: watch::channel(sources.referenced()).0,
            live_activity_sources: std::sync::Mutex::new(sources),
            live_activity_publication: Mutex::new(publication),
            live_activity_epoch: crate::ids::new_session_uuid(),
            live_activity_updates: watch::channel(None).0,
            peer_reports: watch::channel(None).0,
            fleet_changes: watch::channel(0).0,
        }
    }

    #[cfg(test)]
    pub(crate) fn fixture_disabled(journal: Journal) -> Self {
        Self::new(
            PushConfiguration::Disabled,
            journal,
            Arc::new(DeviceRegistry::temporary()),
            None,
        )
    }

    pub(crate) fn devices(&self) -> &Arc<DeviceRegistry> {
        &self.devices
    }

    pub(crate) fn live_activity_updates(&self) -> watch::Receiver<Option<LiveActivitySnapshot>> {
        self.live_activity_updates.subscribe()
    }

    #[cfg(test)]
    pub(crate) async fn fixture_broker(
        url: String,
        journal: Journal,
        path: Option<PathBuf>,
    ) -> Self {
        let mut notifier = Self::new(
            PushConfiguration::Disabled,
            journal,
            Arc::new(DeviceRegistry::temporary()),
            path,
        );
        notifier.broker = Some(PushBroker::new(url, "fixture-broker".into()));
        notifier.unavailable_reason = None;
        notifier
            .devices
            .register(crate::devices::fixture_registration(1))
            .await
            .expect("fixture device registration");
        notifier
    }

    pub(crate) async fn check_alert_registration(&self, event: &str) -> Result<(), &'static str> {
        let reason = match (&self.broker, self.devices.alert_targets().await) {
            (None, _) => self.unavailable_reason.unwrap_or("no broker config"),
            (Some(_), Ok(targets)) if targets.is_empty() => NO_ALERT_DEVICE,
            (Some(_), Ok(_)) => return Ok(()),
            (Some(_), Err(error)) => {
                warn!(%error, "device registry unreadable for alert registration check");
                REGISTRY_UNREADABLE
            }
        };
        self.record_skip(event, reason);
        Err(reason)
    }

    pub(crate) async fn send_voip_push(
        &self,
        destination: &Destination,
        call_id: &str,
        host_id: &str,
        expires_at: f64,
    ) -> DeliveryOutcome {
        let broker = self.broker()?;
        let request = serde_json::json!({
            "bundle_id": self.devices.bundle_id(),
            "push_environment": destination.environment,
            "device_token": destination.token.as_str(),
            "call_id": call_id,
            "host_id": host_id,
            "expires_at": expires_at.floor() as i64,
        });
        self.deliver(
            broker,
            Delivery {
                kind: TokenKind::Voip,
                journal: None,
                destination,
                fields: Value::Null,
            },
            &request,
        )
        .await
    }

    pub(crate) async fn send_task_completion(
        &self,
        collapse_id: &str,
        title: &str,
        subtitle: &str,
        body: &str,
        payload: &Value,
    ) {
        let Ok((broker, targets)) = self.alert_route("alert").await else {
            return;
        };
        let _ = self
            .deliver_alerts(
                broker,
                targets,
                &AlertContent {
                    stream: "alert",
                    title,
                    subtitle: Some(subtitle),
                    body,
                    collapse_id,
                    completion: Some(payload),
                    fields: serde_json::json!({ "collapseId": collapse_id }),
                },
            )
            .await;
    }

    pub(crate) async fn send_location_push(
        &self,
        destination: &Destination,
        expiration: i64,
        custom_data: &Map<String, Value>,
    ) -> DeliveryOutcome {
        let broker = self.broker()?;
        let request = BrokerLocationRequest {
            bundle_id: self.devices.bundle_id(),
            push_environment: destination.environment,
            device_token: destination.token.as_str(),
            expiration,
            custom_data,
        };
        let delivered = self
            .deliver(
                broker,
                Delivery {
                    kind: TokenKind::Location,
                    journal: None,
                    destination,
                    fields: Value::Null,
                },
                &request,
            )
            .await?;
        self.journal.push(
            "navigation",
            serde_json::json!({
                "event": "locationPushSent",
                "env": destination.environment.as_str(),
                "tokenFingerprint": destination.token.fingerprint(),
                "apnsId": delivered.apns_id,
            }),
        );
        Ok(delivered)
    }

    /// Sends the alert produced by the `notify_user` agent tool.
    ///
    /// Unlike a task completion this is something the agent chose to say, so it
    /// carries its own collapse id and no completion payload — a notification
    /// tap opens the app rather than routing to a finished turn. The outcome is
    /// returned rather than only logged, because the model is waiting on it. It
    /// succeeds when any registered device accepted the alert.
    pub(crate) async fn send_user_alert(
        &self,
        title: &str,
        body: &str,
        thread_id: Option<&str>,
    ) -> DeliveryOutcome {
        let (broker, targets) = self.alert_route("userAlert").await?;
        // Its own collapse id, so an agent notification never replaces the
        // completion alert for the same thread on the lock screen.
        let collapse_id = match thread_id {
            Some(thread_id) => format!("agent-notify:{thread_id}"),
            None => "agent-notify".to_string(),
        };
        self.deliver_alerts(
            broker,
            targets,
            &AlertContent {
                stream: "userAlert",
                title,
                subtitle: None,
                body,
                collapse_id: &collapse_id,
                completion: None,
                fields: serde_json::json!({
                    "collapseId": collapse_id,
                    "threadId": thread_id,
                }),
            },
        )
        .await
    }

    #[cfg(test)]
    pub(crate) async fn report_live_activity(
        &self,
        local_host: Option<&str>,
        projection: SourceProjection,
    ) {
        self.report_live_activity_if_current(local_host, projection, Freshness::new(|| true))
            .await;
    }

    pub(crate) async fn report_live_activity_if_current(
        &self,
        local_host: Option<&str>,
        projection: SourceProjection,
        freshness: Freshness,
    ) {
        if !freshness.is_fresh() {
            return;
        }
        let changed = self.change_local(|sources| sources.report_local(projection, freshness));
        self.publish_live_activity(changed, local_host).await;
    }

    pub(crate) async fn mark_live_activity_unavailable_if_current(
        &self,
        local_host: Option<&str>,
        is_current: impl Fn() -> bool + Sync,
    ) {
        if !is_current() {
            return;
        }
        let changed = self.change_local(live_activity::Sources::mark_local_unavailable);
        self.publish_live_activity(changed, local_host).await;
    }

    fn sources(&self) -> std::sync::MutexGuard<'_, live_activity::Sources> {
        self.live_activity_sources
            .lock()
            .expect("Live Activity sources poisoned")
    }

    fn change_local(&self, change: impl FnOnce(&mut live_activity::Sources) -> bool) -> bool {
        let mut sources = self.sources();
        let changed = change(&mut sources);
        let report = sources.report();
        self.peer_reports.send_if_modified(|current| match current {
            Some(current) if *current == report => false,
            _ => {
                *current = Some(report);
                true
            }
        });
        if changed {
            self.fleet_changes.send_modify(|revision| *revision += 1);
        }
        changed
    }

    fn change_peers(&self, change: impl FnOnce(&mut live_activity::Sources) -> bool) {
        let mut sources = self.sources();
        if change(&mut sources) {
            let referenced = sources.referenced();
            self.referenced_threads.send_if_modified(|current| {
                let changed = *current != referenced;
                *current = referenced;
                changed
            });
            self.fleet_changes.send_modify(|revision| *revision += 1);
        }
    }

    pub(crate) fn live_activity_epoch(&self) -> &str {
        &self.live_activity_epoch
    }

    pub(crate) fn peer_live_activity_reports(&self) -> watch::Receiver<Option<PeerReport>> {
        self.peer_reports.subscribe()
    }

    pub(crate) fn fleet_live_activity_changes(&self) -> watch::Receiver<u64> {
        self.fleet_changes.subscribe()
    }

    pub(crate) fn referenced_thread_changes(
        &self,
    ) -> watch::Receiver<std::collections::BTreeSet<crate::wire::cluster::AgentAddress>> {
        self.referenced_threads.subscribe()
    }

    pub(crate) fn referenced_threads(
        &self,
    ) -> std::collections::BTreeSet<crate::wire::cluster::AgentAddress> {
        self.referenced_threads.borrow().clone()
    }

    pub(crate) fn receive_peer_live_activity(
        &self,
        host: &str,
        client: u64,
        report: Result<Option<SourceProjection>, String>,
    ) -> PeerOutcome {
        let mut outcome = PeerOutcome::Stale;
        self.change_peers(|sources| {
            let (received, changed) = sources.receive_peer(host, client, report);
            outcome = received;
            changed
        });
        outcome
    }

    pub(crate) fn peer_live_activity_closed(&self, host: &str, client: u64) {
        self.change_peers(|sources| sources.peer_connection_closed(host, client));
    }

    pub(crate) fn retain_live_activity_peers(&self, members: &std::collections::BTreeSet<String>) {
        self.change_peers(|sources| sources.retain_peers(members));
    }

    pub(crate) async fn publish_fleet_live_activity(&self, local_host: Option<&str>) {
        self.publish_live_activity(false, local_host).await;
    }

    pub(crate) fn fleet_live_activity_snapshot(
        &self,
        hosts: &[String],
        local_host: &str,
    ) -> FleetSnapshot {
        let content = self.sources().fleet_content(hosts, local_host);
        FleetSnapshot {
            epoch: self.live_activity_epoch.clone(),
            revision: *self.fleet_changes.borrow(),
            relevance_score: content.content.relevance_score(),
            content,
            updated_at_unix_seconds: unix_seconds(),
        }
    }

    async fn publish_live_activity(&self, changed: bool, local_host: Option<&str>) {
        let mut publication = self.live_activity_publication.lock().await;
        let (local, superseded, restoring, revision) = {
            let sources = self.sources();
            (
                sources.local_content().cloned(),
                sources.local_superseded(),
                sources.is_restoring(),
                *self.fleet_changes.borrow(),
            )
        };
        let is_current = || *self.fleet_changes.borrow() == revision;
        match &local {
            None => {
                self.live_activity_updates
                    .send_if_modified(|current| current.take().is_some());
            }
            Some(local) => {
                self.live_activity_updates.send_if_modified(|current| {
                    if current
                        .as_ref()
                        .is_some_and(|current| current.content == *local)
                    {
                        return false;
                    }
                    *current = Some(LiveActivitySnapshot {
                        epoch: self.live_activity_epoch.clone(),
                        revision: publication.next_revision(),
                        relevance_score: local.relevance_score(),
                        content: local.clone(),
                        updated_at_unix_seconds: unix_seconds(),
                    });
                    true
                });
            }
        }
        if !restoring {
            self.deliver_live_activity(
                &mut publication,
                changed,
                local.map(|local| ActivityPayload::local(&local, superseded)),
                local_host,
                &is_current,
            )
            .await;
        }
        let cache = self.sources().cache();
        publication.persist(cache).await;
    }

    async fn deliver_live_activity(
        &self,
        publication: &mut live_activity::Publication,
        changed: bool,
        local: Option<ActivityPayload>,
        local_host: Option<&str>,
        is_current: &(impl Fn() -> bool + Sync),
    ) {
        let (legacy, fleet) = match tokio::try_join!(
            self.devices.live_activity_destinations(),
            self.devices.fleet_activity_targets()
        ) {
            Ok(destinations) => destinations,
            Err(error) => {
                warn!(%error, "device registry unreadable for live activity");
                self.record_skip("liveActivity", REGISTRY_UNREADABLE);
                return;
            }
        };
        if legacy.is_empty() && fleet.is_empty() {
            if changed {
                self.record_skip("liveActivity", NO_LIVE_ACTIVITY_DEVICE);
            }
            publication.delivered.clear();
            return;
        }
        let mut payloads: Vec<(Destination, ActivityPayload)> = legacy
            .into_iter()
            .filter_map(|destination| Some((destination, local.clone()?)))
            .collect();
        if let Some(local_host) = local_host {
            let sources = self.sources();
            payloads.extend(fleet.into_iter().map(|target| {
                let content = sources.fleet_content(&target.hosts, local_host);
                (target.destination, ActivityPayload::fleet(&content))
            }));
        }
        publication.delivered.retain(|token, _| {
            payloads
                .iter()
                .any(|(destination, _)| destination.token.as_str() == token)
        });
        let pending: Vec<_> = payloads
            .into_iter()
            .filter(|(destination, payload)| {
                publication.delivered.get(destination.token.as_str()) != Some(&payload.identity)
            })
            .collect();
        if pending.is_empty() {
            return;
        }
        let Ok(broker) = self.broker_recorded("liveActivity") else {
            return;
        };
        let timestamp = publication.next_timestamp(unix_seconds().floor() as i64);
        let delivered = self
            .send_live_activity(broker, timestamp, pending, is_current)
            .await;
        publication.delivered.extend(delivered);
    }

    async fn send_live_activity(
        &self,
        broker: &PushBroker,
        timestamp: i64,
        pending: Vec<(Destination, ActivityPayload)>,
        is_current: &(impl Fn() -> bool + Sync),
    ) -> Vec<(String, Value)> {
        let supports_relevance = broker.supports_live_activity_relevance().await;
        futures_util::stream::iter(pending)
            .map(|(destination, payload)| {
                let (event, stale_date, dismissal_date) = if payload.ends {
                    (LiveActivityEvent::End, None, Some(timestamp))
                } else {
                    (LiveActivityEvent::Update, Some(timestamp + 5 * 60), None)
                };
                let mut content_state = payload.state.clone();
                content_state["updatedAtUnixSeconds"] = Value::from(unix_seconds());
                let request = BrokerLiveActivityRequest {
                    bundle_id: self.devices.bundle_id().to_owned(),
                    push_environment: destination.environment,
                    device_token: destination.token.as_str().to_owned(),
                    event,
                    timestamp,
                    content_state,
                    relevance_score: supports_relevance.then_some(payload.relevance_score),
                    stale_date,
                    dismissal_date,
                    alert: None,
                };
                async move {
                    if !is_current() || (payload.ends && self.sources().local_superseded()) {
                        return None;
                    }
                    let token = destination.token.as_str().to_owned();
                    self.deliver(
                        broker,
                        Delivery {
                            kind: if payload.fleet {
                                TokenKind::FleetActivity
                            } else {
                                TokenKind::LiveActivity
                            },
                            journal: Some("liveActivity"),
                            destination: &destination,
                            fields: serde_json::json!({
                                "activityEvent": event,
                                "fleet": payload.fleet,
                                "activeTaskCount": payload.state["activeTaskCount"],
                                "attentionCount": payload.state["attentionCount"],
                            }),
                        },
                        &request,
                    )
                    .await
                    .ok()
                    .map(|_| (token, payload.identity))
                }
            })
            .buffer_unordered(MAX_CONCURRENT_SENDS)
            .filter_map(std::future::ready)
            .collect()
            .await
    }

    fn broker(&self) -> Result<&PushBroker, DeliveryFailure> {
        self.broker
            .as_ref()
            .ok_or(DeliveryFailure::BrokerUnavailable(
                self.unavailable_reason.unwrap_or("no broker config"),
            ))
    }

    fn broker_recorded(&self, stream: &'static str) -> Result<&PushBroker, DeliveryFailure> {
        self.broker().inspect_err(|failure| {
            if let DeliveryFailure::BrokerUnavailable(reason) = failure {
                self.record_skip(stream, reason);
            }
        })
    }

    async fn alert_route(
        &self,
        stream: &'static str,
    ) -> Result<(&PushBroker, Vec<AlertTarget>), DeliveryFailure> {
        let broker = self.broker_recorded(stream)?;
        match self.devices.alert_targets().await {
            Ok(targets) if !targets.is_empty() => Ok((broker, targets)),
            Ok(_) => {
                self.record_skip(stream, NO_ALERT_DEVICE);
                Err(DeliveryFailure::NoDestination)
            }
            Err(error) => {
                warn!(%error, "device registry unreadable for {stream}");
                self.record_skip(stream, REGISTRY_UNREADABLE);
                Err(DeliveryFailure::BrokerUnavailable(REGISTRY_UNREADABLE))
            }
        }
    }

    async fn deliver_alerts(
        &self,
        broker: &PushBroker,
        targets: Vec<AlertTarget>,
        content: &AlertContent<'_>,
    ) -> DeliveryOutcome {
        let outcomes: Vec<DeliveryOutcome> = futures_util::stream::iter(targets)
            .map(|target| self.send_alert(broker, target, content))
            .buffer_unordered(MAX_CONCURRENT_SENDS)
            .collect()
            .await;
        let mut first_failure = None;
        for outcome in outcomes {
            match outcome {
                Ok(delivered) => return Ok(delivered),
                Err(failure) => {
                    first_failure.get_or_insert(failure);
                }
            }
        }
        Err(first_failure.unwrap_or(DeliveryFailure::NoDestination))
    }

    async fn send_alert(
        &self,
        broker: &PushBroker,
        target: AlertTarget,
        content: &AlertContent<'_>,
    ) -> DeliveryOutcome {
        let mut fields = content.fields.clone();
        let custom_data = content.completion.map(|completion| {
            // The host UUID belongs to the app installation that registered
            // this exact token, never to the daemon or provider account, so
            // a payload never carries a host another device registered.
            let mut payload = completion.clone();
            if let Some(object) = payload.as_object_mut() {
                object.remove("hostID");
            }
            if let Some(host_id) = &target.host_id {
                payload["hostID"] = Value::String(host_id.clone());
            }
            let text = |key: &str| {
                payload
                    .get(key)
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
                    .to_owned()
            };
            fields["hostBinding"] = Value::from(target.host_binding);
            fields["eventId"] = Value::from(text("eventID"));
            fields["sessionId"] = Value::from(text("sessionID"));
            fields["turnOutcome"] = Value::from(text("outcome"));
            let mut custom_data = Map::new();
            custom_data.insert(PAYLOAD_KEY.to_string(), Value::String(payload.to_string()));
            custom_data
        });
        let collapse_id = apns_collapse_id(content.collapse_id);
        let request = BrokerAlertRequest {
            topic: self.devices.bundle_id(),
            push_environment: target.destination.environment,
            device_token: target.destination.token.as_str(),
            title: content.title,
            body: content.body,
            subtitle: content.subtitle,
            sound: Some(ALERT_SOUND),
            collapse_id: Some(&collapse_id),
            mutable_content: false,
            custom_data,
        };
        self.deliver(
            broker,
            Delivery {
                kind: TokenKind::Alert,
                journal: Some(content.stream),
                destination: &target.destination,
                fields,
            },
            &request,
        )
        .await
    }

    async fn deliver<TRequest>(
        &self,
        broker: &PushBroker,
        delivery: Delivery<'_>,
        request: &TRequest,
    ) -> DeliveryOutcome
    where
        TRequest: Serialize + ?Sized,
    {
        let Delivery {
            kind,
            journal,
            destination,
            fields,
        } = delivery;
        let topic = self.devices.bundle_id();
        let token_fp = destination.token.fingerprint();
        let result = broker.send(kind, request).await;
        let mut record = serde_json::json!({
            "topic": topic,
            "env": destination.environment.as_str(),
            "tokenFingerprint": token_fp,
        });
        if let (Some(object), Some(fields)) = (record.as_object_mut(), fields.as_object()) {
            object.extend(
                fields
                    .iter()
                    .map(|(key, value)| (key.clone(), value.clone())),
            );
        }
        let outcome = match result {
            Ok(response) => {
                info!(
                    kind = ?kind,
                    topic,
                    token_fp,
                    apns_id = ?response.apns_id,
                    "push sent"
                );
                record["outcome"] = Value::from("sent");
                record["apnsId"] = Value::from(response.apns_id.clone());
                Ok(Delivered {
                    apns_id: response.apns_id,
                })
            }
            Err(error) => {
                warn!(
                    kind = ?kind,
                    topic,
                    token_fp,
                    status = ?error.status,
                    reason = ?error.apns_reason,
                    detail = ?error.detail,
                    apns_id = ?error.apns_id,
                    "push failed"
                );
                record["outcome"] = Value::from("failed");
                record["status"] = Value::from(error.status);
                record["apnsReason"] = Value::from(error.apns_reason.clone());
                record["detail"] = Value::from(error.detail.clone());
                record["apnsId"] = Value::from(error.apns_id.clone());
                if is_permanently_invalid(&error) {
                    self.devices.invalidate(destination, kind).await;
                }
                Err(error.into_failure())
            }
        };
        if let Some(stream) = journal {
            self.journal.push(stream, record);
        }
        outcome
    }

    /// Records a push attempt that never reached the broker.
    fn record_skip(&self, event: &str, reason: &'static str) {
        self.journal.push(
            event,
            serde_json::json!({ "outcome": "skipped", "reason": reason }),
        );
    }
}

fn is_permanently_invalid(error: &BrokerRequestError) -> bool {
    matches!(
        error.apns_reason.as_deref(),
        Some("BadDeviceToken" | "DeviceTokenNotForTopic" | "ExpiredToken" | "Unregistered")
    )
}
