use super::{ApnsSend, Gateway};
use serde_json::json;
use tokio::sync::mpsc;

impl Gateway {
    pub(super) async fn apns_completion_loop(&self, mut rx: mpsc::Receiver<ApnsSend>) {
        while let Some(apns) = rx.recv().await {
            if self.apns.check_alert_registration("alert").await.is_err() {
                continue;
            }

            if self
                .check_user_alert_ownership(
                    apns.payload["sessionID"].as_str(),
                    "alert",
                    apns.payload["eventID"].as_str(),
                )
                .await
                .is_err()
            {
                continue;
            }
            self.apns
                .send_task_completion(
                    &apns.collapse_id,
                    &apns.title,
                    &apns.subtitle,
                    &apns.body,
                    &apns.payload,
                )
                .await;
        }
    }

    /// Sends the `notify_user` alert through the same broker path as task
    /// completions. The error string is written for the model to read.
    pub(crate) async fn send_user_alert(
        &self,
        title: &str,
        body: &str,
        thread_id: Option<&str>,
    ) -> std::result::Result<(), String> {
        self.apns
            .check_alert_registration("userAlert")
            .await
            .map_err(|reason| format!("push notifications are unavailable ({reason})"))?;
        self.check_user_alert_ownership(thread_id, "userAlert", None)
            .await
            .map_err(|reason| match reason {
                "delegatedChild" => "Child notifications are suppressed; report through the parent conversation.".to_string(),
                _ => format!("Notification ownership could not be verified ({reason}); retry after the host notification service is available."),
            })?;
        self.apns
            .send_user_alert(title, body, thread_id)
            .await
            .map(|_| ())
            .map_err(|failure| failure.to_string())
    }

    /// One gate for every conversation-owned user alert, including questions,
    /// explicit notify_user calls and recovery failures. The authoritative
    /// Agents lookup is account-scoped and bounded to two seconds. Only its
    /// proven root result permits delivery; unavailable ancestry stays unknown.
    pub(super) async fn check_user_alert_ownership(
        &self,
        thread_id: Option<&str>,
        event: &str,
        event_id: Option<&str>,
    ) -> std::result::Result<(), &'static str> {
        let reason = match thread_id.filter(|id| !id.trim().is_empty()) {
            None => "missingThreadIdentity",
            Some(thread) => match self.is_agent_thread(thread).await {
                Ok(false) => return Ok(()),
                Ok(true) => "delegatedChild",
                Err(error) if error.is::<tokio::time::error::Elapsed>() => "ancestryTimeout",
                Err(_) => "ancestryUnavailable",
            },
        };
        self.record_user_alert_suppression(thread_id, event, event_id, reason);
        Err(reason)
    }

    pub(crate) fn record_user_alert_suppression(
        &self,
        thread_id: Option<&str>,
        event: &str,
        event_id: Option<&str>,
        reason: &str,
    ) {
        self.journal.push(
            event,
            json!({
                "outcome": "suppressed", "reason": reason,
                "sessionId": thread_id, "eventId": event_id,
                "accountID": Option::<&str>::None,
                "accountGeneration": Option::<u64>::None,
            }),
        );
    }
}
