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
    AttentionReason, AttentionRow, LiveActivityContent, LiveActivitySnapshot, MAX_ATTENTION_ROWS,
};

const PAYLOAD_KEY: &str = "remoteCoder.taskCompletionPayload";
const ALERT_SOUND: &str = "remote-coder-notification.wav";
const MAX_CONCURRENT_SENDS: usize = 4;
const NO_ALERT_DEVICE: &str = "no alert device registered";
const NO_LIVE_ACTIVITY_DEVICE: &str = "no live activity device registered";
const REGISTRY_UNREADABLE: &str = "device registry unreadable";

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
    live_activity: Mutex<live_activity::Aggregate>,
    live_activity_epoch: String,
    live_activity_updates: watch::Sender<Option<LiveActivitySnapshot>>,
}

impl PushService {
    pub fn new(
        enabled: bool,
        journal: Journal,
        devices: Arc<DeviceRegistry>,
        live_activity_path: Option<PathBuf>,
    ) -> Self {
        let broker = if enabled { load_broker() } else { None };
        let unavailable_reason = match (enabled, broker.is_some()) {
            (_, true) => None,
            (false, _) => Some("broker disabled"),
            (true, false) => Some("broker not configured"),
        };

        if !enabled {
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

        Self {
            broker,
            unavailable_reason,
            devices,
            journal,
            live_activity: Mutex::new(live_activity::Aggregate::load(live_activity_path)),
            live_activity_epoch: crate::ids::new_session_uuid(),
            live_activity_updates: watch::channel(None).0,
        }
    }

    #[cfg(test)]
    pub(crate) fn fixture_disabled(journal: Journal) -> Self {
        let mut service = Self::new(false, journal, Arc::new(DeviceRegistry::temporary()), None);
        service.live_activity.get_mut().required_scopes =
            Some(std::collections::BTreeSet::from(["default".into()]));
        service
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
        let mut notifier = Self::new(false, journal, Arc::new(DeviceRegistry::temporary()), path);
        notifier.broker = Some(PushBroker::new(url, "fixture-broker".into()));
        notifier.unavailable_reason = None;
        notifier
            .devices
            .register(crate::devices::fixture_registration(1))
            .await
            .expect("fixture device registration");
        notifier
            .reconcile_live_activity_scopes(&std::collections::BTreeSet::from(["default".into()]))
            .await;
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
    pub(crate) async fn report_live_activity(&self, account: &str, content: LiveActivityContent) {
        // Hold the owner through delivery so a slower older update cannot end a
        // newer activity belonging to another account.
        self.report_live_activity_if_current(account, content, || true)
            .await;
    }

    pub(crate) async fn report_live_activity_if_current(
        &self,
        account: &str,
        content: LiveActivityContent,
        is_current: impl Fn() -> bool + Sync,
    ) {
        let mut aggregate = self.live_activity.lock().await;
        if !is_current() {
            return;
        }
        let changed = match aggregate.report(account, content).await {
            Ok(changed) => changed,
            Err(error) => {
                warn!(%error, "Live Activity state unavailable");
                return;
            }
        };
        self.publish_live_activity(&mut aggregate, changed, &is_current)
            .await;
        if !is_current() {
            aggregate.mark_unavailable(account);
            self.live_activity_updates
                .send_if_modified(|current| current.take().is_some());
        }
    }

    pub(crate) async fn mark_live_activity_unavailable_if_current(
        &self,
        scope: &str,
        is_current: impl Fn() -> bool,
    ) {
        let mut aggregate = self.live_activity.lock().await;
        if !is_current() {
            return;
        }
        aggregate.mark_unavailable(scope);
        self.live_activity_updates
            .send_if_modified(|current| current.take().is_some());
    }

    pub(crate) async fn reconcile_live_activity_scopes(
        &self,
        retained: &std::collections::BTreeSet<String>,
    ) {
        let mut aggregate = self.live_activity.lock().await;
        let changed = match aggregate.retain_scopes(retained).await {
            Ok(changed) => changed,
            Err(error) => {
                warn!(%error, "Live Activity scopes unavailable");
                return;
            }
        };
        self.publish_live_activity(&mut aggregate, changed, &|| true)
            .await;
    }

    async fn publish_live_activity(
        &self,
        aggregate: &mut live_activity::Aggregate,
        changed: bool,
        is_current: &(impl Fn() -> bool + Sync),
    ) {
        if changed {
            aggregate.delivered_tokens.clear();
        }
        if !is_current() {
            return;
        }
        if !aggregate.is_ready() {
            self.live_activity_updates
                .send_if_modified(|current| current.take().is_some());
            return;
        }
        let merged = match aggregate.merged() {
            Ok(merged) => merged,
            Err(error) => {
                warn!(%error, "Live Activity state unavailable");
                return;
            }
        };
        self.live_activity_updates.send_if_modified(|current| {
            if current
                .as_ref()
                .is_some_and(|current| current.content == merged)
            {
                return false;
            }
            *current = Some(LiveActivitySnapshot {
                epoch: self.live_activity_epoch.clone(),
                revision: aggregate.next_revision(),
                content: merged.clone(),
                relevance_score: merged.relevance_score(),
                updated_at_unix_seconds: unix_seconds(),
            });
            true
        });
        let destinations = match self.devices.live_activity_destinations().await {
            Ok(destinations) => destinations,
            Err(error) => {
                warn!(%error, "device registry unreadable for live activity");
                self.record_skip("liveActivity", REGISTRY_UNREADABLE);
                return;
            }
        };
        if destinations.is_empty() {
            if changed {
                self.record_skip("liveActivity", NO_LIVE_ACTIVITY_DEVICE);
            }
            return;
        }
        let pending: Vec<_> = destinations
            .into_iter()
            .filter(|destination| {
                !aggregate
                    .delivered_tokens
                    .contains(destination.token.as_str())
            })
            .collect();
        if pending.is_empty() {
            return;
        }
        let Ok(broker) = self.broker_recorded("liveActivity") else {
            return;
        };
        let timestamp = aggregate.next_timestamp(unix_seconds().floor() as i64);
        let delivered = self
            .send_live_activity(broker, &merged, timestamp, pending, is_current)
            .await;
        aggregate.delivered_tokens.extend(delivered);
    }

    async fn send_live_activity(
        &self,
        broker: &PushBroker,
        content: &LiveActivityContent,
        timestamp: i64,
        destinations: Vec<Destination>,
        is_current: &(impl Fn() -> bool + Sync),
    ) -> Vec<String> {
        let (event, stale_date, dismissal_date) = if content.is_empty() {
            (LiveActivityEvent::End, None, Some(timestamp))
        } else {
            (LiveActivityEvent::Update, Some(timestamp + 5 * 60), None)
        };
        let content_state = serde_json::json!({
            "activeTaskCount": content.active_task_count,
            "attention": content.attention,
            "attentionCount": content.attention_count,
            "updatedAtUnixSeconds": unix_seconds(),
        });
        let relevance_score = if broker.supports_live_activity_relevance().await {
            Some(content.relevance_score())
        } else {
            None
        };

        futures_util::stream::iter(destinations)
            .map(|destination| {
                let request = BrokerLiveActivityRequest {
                    bundle_id: self.devices.bundle_id().to_owned(),
                    push_environment: destination.environment,
                    device_token: destination.token.as_str().to_owned(),
                    event,
                    timestamp,
                    content_state: content_state.clone(),
                    relevance_score,
                    stale_date,
                    dismissal_date,
                    alert: None,
                };
                async move {
                    if !is_current() {
                        return None;
                    }
                    let token = destination.token.as_str().to_owned();
                    self.deliver(
                        broker,
                        Delivery {
                            kind: TokenKind::LiveActivity,
                            journal: Some("liveActivity"),
                            destination: &destination,
                            fields: serde_json::json!({
                                "activityEvent": event,
                                "activeTaskCount": content.active_task_count,
                                "attentionCount": content.attention_count,
                            }),
                        },
                        &request,
                    )
                    .await
                    .ok()
                    .map(|_| token)
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

fn load_broker() -> Option<PushBroker> {
    let token = std::env::var("RC_PUSH_BROKER_TOKEN")
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())?;
    let url = std::env::var("RC_PUSH_BROKER_URL")
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "http://127.0.0.1:5012".to_owned());
    Some(PushBroker::new(url, token))
}

fn is_permanently_invalid(error: &BrokerRequestError) -> bool {
    matches!(
        error.apns_reason.as_deref(),
        Some("BadDeviceToken" | "DeviceTokenNotForTopic" | "ExpiredToken" | "Unregistered")
    )
}
