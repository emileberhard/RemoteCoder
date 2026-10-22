use super::{CALL_SECONDS, CallState, RING_SECONDS, required_string};
use crate::agents::tools::Caller;
use crate::gateway::Gateway;
use crate::providers::Provider;
use crate::time::unix_seconds;
use anyhow::{Context, Result, anyhow, bail, ensure};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufRead, AsyncBufReadExt};
use tracing::warn;

const MAXIMUM_DIAGNOSTIC_BYTES: usize = 8_192;

pub(super) async fn read_diagnostic_line(
    reader: &mut (impl AsyncBufRead + Unpin),
    line: &mut Vec<u8>,
) -> Result<Option<Vec<u8>>> {
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return Ok((!line.is_empty()).then(|| std::mem::take(line)));
        }
        let end = available.iter().position(|byte| *byte == b'\n');
        let taken = end.unwrap_or(available.len());
        ensure!(
            line.len() + taken <= MAXIMUM_DIAGNOSTIC_BYTES,
            "telephone worker emitted an oversized diagnostic"
        );
        line.extend_from_slice(&available[..taken]);
        reader.consume(taken + usize::from(end.is_some()));
        if end.is_some() {
            return Ok(Some(std::mem::take(line)));
        }
    }
}

impl Gateway {
    pub(super) fn start_call_delivery(self: &Arc<Self>, call_id: &str) -> Result<()> {
        let delivery = {
            let gateway = Arc::clone(self);
            let call_id = call_id.to_string();
            async move {
                let result = match gateway.calls.get(&call_id).await {
                    Ok(record) if record.request.to == "self" => {
                        gateway.deliver_native_call(&call_id).await
                    }
                    Ok(_) => gateway.run_telephone_worker(&call_id).await,
                    Err(error) => Err(error),
                };
                if let Err(error) = result {
                    warn!(%call_id, %error, "agent call delivery failed");
                    if let Err(cleanup_error) = gateway
                        .record_delivery_failure_awaiting_capacity(&call_id, &error.to_string())
                        .await
                    {
                        warn!(%call_id, %cleanup_error, "failed to reconcile call delivery");
                    }
                }
                Ok(())
            }
        };
        let deadline = {
            let gateway = Arc::clone(self);
            let call_id = call_id.to_string();
            async move {
                loop {
                    let Ok(record) = gateway.calls.get(&call_id).await else {
                        return Ok(());
                    };
                    if record.state.terminal() {
                        return Ok(());
                    }
                    let deadline = record
                        .connected_at
                        .map_or(record.expires_at, |start| start + CALL_SECONDS);
                    let remaining = deadline - unix_seconds();
                    if remaining <= 0.0 {
                        let _ = gateway.end_agent_call(&call_id, "timeout").await;
                        return Ok(());
                    }
                    tokio::time::sleep(Duration::from_secs_f64(remaining.min(5.0))).await;
                }
            }
        };
        if self.voice_tasks.spawn("agent call delivery", delivery)
            && self.voice_tasks.spawn("agent call deadline", deadline)
        {
            return Ok(());
        }
        bail!("gateway is restarting")
    }

    pub(super) async fn record_delivery_failure_awaiting_capacity(
        self: &Arc<Self>,
        call_id: &str,
        reason: &str,
    ) -> Result<()> {
        if let Some(record) = self.record_delivery_failure(call_id, reason).await? {
            self.publish_call_state_awaiting_capacity(&record).await;
        }
        Ok(())
    }

    async fn record_delivery_failure(
        self: &Arc<Self>,
        call_id: &str,
        reason: &str,
    ) -> Result<Option<super::CallRecord>> {
        let reason = reason.to_string();
        let recorded = self
            .calls
            .change(call_id, move |record| {
                // The phone's authenticated receipt outranks a late APNs/broker
                // acknowledgment failure. Keep its deadline and media owner alive.
                let native_observed = record.request.to == "self"
                    && matches!(
                        record.state,
                        CallState::Ringing | CallState::Connecting | CallState::Connected
                    );
                if !record.state.terminal() && !native_observed {
                    record.state = CallState::Unresolved;
                    record.reason = Some(format!("delivery failed or uncertain: {reason}"));
                    record.ended_at = Some(unix_seconds());
                }
                Ok(())
            })
            .await;
        match recorded {
            Ok(record) if record.state != CallState::Unresolved => Ok(Some(record)),
            Ok(_) => self
                .end_agent_call(call_id, "delivery failed")
                .await
                .map(|_| None),
            Err(error) => {
                let _ = self
                    .end_agent_call(call_id, "call persistence failed")
                    .await;
                Err(error)
            }
        }
    }

    async fn run_telephone_worker(&self, call_id: &str) -> Result<()> {
        use tokio::io::{AsyncWriteExt, BufReader};
        let config = self
            .calls
            .delivery
            .as_ref()
            .context("telephone delivery unavailable")?;
        let connection = config.worker_connection()?;
        let record = self
            .calls
            .change(call_id, |record| {
                ensure!(
                    record.state == CallState::Requested && unix_seconds() < record.expires_at,
                    "call no longer deliverable"
                );
                record.state = CallState::Delivering;
                Ok(())
            })
            .await?;
        self.publish_call_state_awaiting_capacity(&record).await;
        let shell_quote = |value: &str| format!("'{}'", value.replace('\'', "'\\''"));
        let mut child = tokio::process::Command::new("/usr/bin/ssh")
            .args([
                "-T",
                "-oBatchMode=yes",
                "-oConnectTimeout=10",
                &config.worker_host,
            ])
            .arg(format!("{} --worker", shell_quote(&config.worker_path)))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .context("starting Mini-owned telephone media worker")?;
        let mut input = child.stdin.take().context("worker stdin unavailable")?;
        let payload = json!({"callId": call_id, "originGatewayHostId": self.calls.state.lock().await.host_id,
            "gateway": connection,
            "configPath": config.worker_config_path});
        input.write_all(format!("{payload}\n").as_bytes()).await?;
        input.flush().await?;
        // Keeping this pipe open is the worker lease. EOF also cancels after a
        // gateway/SSH crash, without another daemon or a polling supervisor.
        let mut output = BufReader::new(child.stdout.take().context("worker stdout unavailable")?);
        let mut diagnostic = Vec::new();
        let mut stopping = false;
        let mut output_open = true;
        let deadline =
            tokio::time::sleep(Duration::from_secs_f64(CALL_SECONDS + RING_SECONDS + 90.0));
        tokio::pin!(deadline);
        loop {
            let changed = self.calls.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            if !stopping {
                let record = self.calls.get(call_id).await?;
                if record.state.terminal() || record.state == CallState::Ending {
                    stopping = true;
                    let _ = input.write_all(b"{\"command\":\"stop\"}\n").await;
                    let _ = input.shutdown().await;
                }
            }
            tokio::select! {
                status = child.wait() => {
                    let status = status?;
                    let record = self.calls.get(call_id).await?;
                    ensure!(status.success() && record.state.terminal(), "telephone worker exited without a reconciled outcome");
                    return Ok(());
                }
                line = read_diagnostic_line(&mut output, &mut diagnostic), if output_open => {
                    if let Some(line) = line? {
                        let event: Value = serde_json::from_slice(&line).context("invalid worker diagnostic")?;
                        self.journal.push("callMedia", json!({"callId": call_id, "mediaEvent": event["event"], "status": event["status"]}));
                    } else {
                        output_open = false;
                    }
                }
                _ = &mut changed, if !stopping => {}
                _ = &mut deadline => bail!("telephone worker exceeded its bounded lifetime"),
            }
        }
    }

    pub(super) async fn verify_call_origin(
        &self,
        caller: &Caller,
    ) -> Result<(String, String, Option<String>)> {
        let thread_id = caller
            .thread_id
            .as_deref()
            .context("missing managed conversation")?;
        if caller.provider == Provider::Claude {
            let agent = self.claude_agent().context("Claude provider unavailable")?;
            ensure!(
                agent.has_runtime(thread_id).await,
                "Claude conversation is not owned by this gateway runtime"
            );
            let selection = agent
                .runtime_settings_for_command(thread_id)
                .await
                .map_err(|error| anyhow!(error))?
                .context("Claude runtime settings unavailable")?;
            let session_id = crate::providers::claude::session_uuid_from_thread_id(thread_id)
                .context("invalid Claude threadId")?;
            let header = self
                .claude_history
                .read_thread_header(session_id.to_string())
                .await?;
            let cwd = header["cwd"]
                .as_str()
                .context("Claude conversation has no working directory")?
                .to_string();
            Ok((cwd, selection.model, selection.effort))
        } else {
            let response = self
                .call_control(
                    "thread/read",
                    json!({"threadId": thread_id, "includeTurns": false}),
                )
                .await?;
            let thread = &response["thread"];
            ensure!(
                matches!(thread["status"]["type"].as_str(), Some("idle" | "active")),
                "Codex conversation is not loaded and available in this gateway runtime"
            );
            ensure!(
                thread["modelProvider"] == "openai",
                "voice requires the native OpenAI subscription provider"
            );
            Ok((
                required_string(thread, "cwd")?.to_string(),
                required_string(thread, "model")?.to_string(),
                thread["reasoningEffort"].as_str().map(str::to_string),
            ))
        }
    }

    pub(super) async fn verify_subscription_voice(&self, cwd: &str) -> Result<()> {
        let account = self
            .call_control("account/read", json!({"refreshToken": false}))
            .await?;
        ensure!(
            matches!(
                account["account"]["type"].as_str(),
                Some("chatgpt" | "chatgptAuthTokens")
            ),
            "a ChatGPT subscription login is required; API-key voice is not a fallback"
        );
        let config = self
            .call_control("config/read", json!({"includeLayers": false, "cwd": cwd}))
            .await?;
        for key in [
            "experimental_realtime_ws_base_url",
            "experimental_realtime_webrtc_call_base_url",
            "experimental_realtime_ws_backend_prompt",
        ] {
            ensure!(
                config["config"][key].is_null(),
                "agent calls do not support configured {key} overrides"
            );
        }
        Ok(())
    }

    pub(super) async fn deliver_native_call(&self, call_id: &str) -> Result<()> {
        let destination = self
            .apns
            .devices()
            .voip_destination()
            .await?
            .context("VoIP device no longer registered")?;
        let host_id = self.incoming_call_routing_id().await;
        let device_id = destination.device_id().map(str::to_owned);
        let record = self
            .calls
            .change(call_id, move |record| {
                ensure!(
                    record.device_id.is_some() && record.device_id == device_id,
                    "incoming-call enrollment changed before delivery"
                );
                ensure!(
                    record.state == CallState::Requested && unix_seconds() < record.expires_at,
                    "call no longer deliverable"
                );
                record.state = CallState::Delivering;
                Ok(())
            })
            .await?;
        self.publish_call_state_awaiting_capacity(&record).await;
        let receipt = self
            .apns
            .send_voip_push(&destination, call_id, &host_id, record.expires_at)
            .await
            .map_err(|error| anyhow!(error))?
            .apns_id;
        let record = self
            .calls
            .change(call_id, move |record| {
                record.delivery_receipt = receipt;
                // APNs acceptance is delivery submission, not proof the phone rang.
                Ok(())
            })
            .await?;
        self.publish_call_state_awaiting_capacity(&record).await;
        Ok(())
    }
}
