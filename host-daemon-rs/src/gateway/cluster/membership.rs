use super::*;

impl Gateway {
    pub(super) async fn cluster_load(&self) -> Result<HostLoad> {
        let store = self.jobs.store().await?;
        let mut active = 0;
        for agent in store.agent_rows().await? {
            if let Some(id) = agent.latest_job_id
                && !matches!(
                    store.read(id).await?.execution,
                    ExecutionState::Terminal { .. } | ExecutionState::Unknown { .. }
                )
            {
                active += 1;
            }
        }
        let (cpu_percent, memory_pressure) = tokio::task::spawn_blocking(|| {
            let cores = std::thread::available_parallelism()
                .ok()
                .map(|value| value.get() as f64);
            let cpu = std::process::Command::new("/bin/ps")
                .args(["-A", "-o", "%cpu="])
                .output()
                .ok()
                .filter(|output| output.status.success())
                .and_then(|output| String::from_utf8(output.stdout).ok())
                .and_then(|output| {
                    output
                        .split_whitespace()
                        .map(str::parse::<f64>)
                        .collect::<std::result::Result<Vec<_>, _>>()
                        .ok()
                })
                .and_then(|values| cores.map(|cores| values.iter().sum::<f64>() / cores));
            let pressure = std::process::Command::new("/usr/sbin/sysctl")
                .args(["-n", "kern.memorystatus_vm_pressure_level"])
                .output()
                .ok()
                .filter(|output| output.status.success())
                .and_then(|output| String::from_utf8(output.stdout).ok())
                .and_then(|value| match value.trim() {
                    "1" => Some(MemoryPressure::Normal),
                    "2" => Some(MemoryPressure::Warn),
                    "4" => Some(MemoryPressure::Critical),
                    _ => None,
                });
            (cpu, pressure)
        })
        .await?;
        Ok(HostLoad {
            cpu_percent,
            memory_pressure,
            active_agents: u32::try_from(active)?,
        })
    }
}

impl Gateway {
    pub(in crate::gateway) async fn validate_member_grant(
        &self,
        grant: &Grant,
    ) -> std::result::Result<(), RpcError> {
        if let Grant::Peer {
            host,
            membership,
            digest,
        } = grant
        {
            if !self
                .cluster_link()
                .await?
                .store
                .valid(host, membership, digest)
                .await?
            {
                return Err(cluster_error(ErrorClass::Refused, "membership was removed"));
            }
        }
        Ok(())
    }
}

impl Gateway {
    pub(crate) async fn remote_receiver_active(&self, host: &str) -> Result<bool> {
        Ok(self
            .cluster_link()
            .await?
            .store
            .all()
            .await?
            .iter()
            .any(|member| member.host == host && member.state == MemberState::Active))
    }

    pub(crate) async fn surface_job_result(&self, id: &JobId, reason: &str) -> Result<()> {
        use crate::agents::jobs::model::Attention;
        let store = self.jobs.store().await?;
        let job = store
            .attention(
                id.clone(),
                Attention::Pending {
                    reason: reason.to_owned(),
                },
            )
            .await?;
        let Some(Attention::Pending { reason }) = &job.attention else {
            return Ok(());
        };
        let identity = self.host_identity().await?;
        let thread = job
            .execution
            .conversation()
            .map(|conversation| conversation.thread_id.as_str());
        let payload = json!({"ownerHostId":identity.host_id,"jobId":id,"reason":reason,"eventID":format!("{}:{id}:result-attention",identity.host_id),"source":"agentResult","sessionID":thread,"createdAtUnixSeconds":crate::time::unix_seconds()});
        self.broadcast_json_or_drop(
            &json!({"method":"agent/jobs/attention","params":payload}),
            crate::observability::journal::Source::Gateway,
        )?;
        self.journal
            .runtime("agent_result_attention", payload.clone());
        if self.apns.check_alert_registration("alert").await.is_ok() {
            self.apns
                .send_task_completion(
                    &format!("job:{id}"),
                    "Agent result needs attention",
                    "",
                    reason,
                    &payload,
                )
                .await;
        }
        store
            .attention(
                id.clone(),
                Attention::Surfaced {
                    reason: reason.clone(),
                },
            )
            .await?;
        Ok(())
    }
}

impl Gateway {
    pub(super) async fn membership_request(
        &self,
        grant: &Grant,
        method: &str,
        params: Value,
    ) -> Result<Value> {
        let identity = self.host_identity().await?;
        let link = self.cluster_link().await?;
        ensure!(
            matches!(grant, Grant::Operator),
            "membership changes require the local operator"
        );
        match method {
            "cluster/issue" => {
                let request: IssueParams = decode(params)?;
                ensure!(
                    request.r#for != identity.host_id,
                    "cannot join this host to itself"
                );
                let membership = request.membership.clone();
                let credential = link.store.issue(request).await?;
                let (routes, pin) = link.endpoint().await?;
                Ok(json!(IssueReceipt {
                    protocol: PROTOCOL,
                    host: identity.host_id,
                    incarnation: identity.incarnation,
                    membership,
                    pin,
                    routes,
                    credential
                }))
            }
            "cluster/accept" => Ok(public_member(&link.store.accept(decode(params)?).await?)),
            "cluster/remove" => {
                let request: RemoveParams = decode(params)?;
                let record = link.store.remove(request.clone(), true).await?;
                link.forget(&request.membership).await;
                self.remove_member_work(&request.membership, &request.host)
                    .await?;
                let remote=link.call(&request.host,"cluster/removed",json!({"protocol":PROTOCOL,"host":identity.host_id,"membership":request.membership})).await;
                if remote.is_ok() {
                    link.store.remove(request, false).await?;
                }
                Ok(
                    json!({"removed":true,"pending":remote.is_err(),"hostId":record.host,"membership":record.membership}),
                )
            }
            _ => {
                for member in link
                    .store
                    .all()
                    .await?
                    .into_iter()
                    .filter(|member| member.state != MemberState::Removed)
                {
                    let remove = RemoveParams {
                        protocol: PROTOCOL,
                        host: member.host.clone(),
                        membership: member.membership.clone(),
                    };
                    link.store.remove(remove.clone(), true).await?;
                    self.remove_member_work(&member.membership, &member.host)
                        .await?;
                    link.call(&member.host,"cluster/removed",json!({"protocol":PROTOCOL,"host":identity.host_id,"membership":member.membership})).await?;
                    link.store.remove(remove, false).await?;
                }
                let _operations = self.jobs.operations.write().await;
                ensure!(
                    self.jobs.store().await?.pending_ids().await?.is_empty(),
                    "stop and settle active jobs before resetting host identity"
                );
                let state = self
                    .turn_state_path
                    .as_deref()
                    .and_then(std::path::Path::parent)
                    .context("identity has no state directory")?
                    .to_owned();
                let reset =
                    tokio::task::spawn_blocking(move || crate::identity::reset(&state)).await??;
                let cached = self
                    .identity
                    .get()
                    .context("host identity is not initialized")?;
                *cached.write().await = reset.clone();
                link.update_identity(reset.clone()).await;
                Ok(json!({"reset":true,"hostId":reset.host_id,"incarnation":reset.incarnation}))
            }
        }
    }
}
