use super::*;

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ListCursor {
    positions: std::collections::BTreeMap<String, Option<String>>,
    complete: std::collections::BTreeSet<String>,
}

impl Gateway {
    pub(super) async fn list_cluster_agents(&self, params: Value) -> Result<Value> {
        use base64::Engine;
        use futures_util::{StreamExt, stream};
        let limit = params["limit"].as_u64().unwrap_or(100);
        ensure!(
            (1..=10000).contains(&limit),
            "list limit must be between 1 and 10000"
        );
        let mut cursor: ListCursor = match params["cursor"].as_str() {
            Some(value) => {
                ensure!(value.len() <= 1024 * 1024, "list cursor exceeds capacity");
                serde_json::from_slice(
                    &base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(value)?,
                )?
            }
            None => ListCursor::default(),
        };
        let identity = self.host_identity().await?;
        let link = self.cluster_link().await?;
        let mut hosts = vec![identity.host_id.clone()];
        if params["local"] != true {
            hosts.extend(
                link.members()
                    .await?
                    .into_iter()
                    .filter(|member| member.state == MemberState::Active)
                    .map(|member| member.host),
            );
        }
        let pages=stream::iter(hosts.iter().cloned()).map(|host| {
            let position=cursor.positions.get(&host).cloned().flatten();
            let complete=cursor.complete.contains(&host);
            let identity=&identity;
            let link=&link;
            let params=&params;
            async move {
                if complete {return (host,Ok(json!({"agents":[],"nextCursor":null})));}
                let request=json!({"limit":limit.min(256),"cursor":position,"active":params["active"],"provider":params["provider"]});
                let page=if host==identity.host_id {self.local_agent_inventory(request).await.map_err(|error|crate::cluster::link::LinkError {class:ErrorClass::Unavailable,transmitted:false,message:error.to_string()})}else {link.call(&host,"agent/cluster/inventory",request).await};
                (host,page)
            }
        }).buffer_unordered(64).collect::<Vec<_>>().await;
        let mut coverage = Vec::new();
        let mut warnings = Vec::new();
        let mut pages=pages.into_iter().filter_map(|(host,result)| match result {
            Err(error)=> {warnings.push(format!("{host}: {error}"));coverage.push(json!({"hostId":host,"state":match error.class {ErrorClass::Unsupported=>"unsupported",ErrorClass::Refused=>"refused",_=>"unreachable"}}));None}
            Ok(page)=> {coverage.push(json!({"hostId":host,"state":"ok"}));Some((host,page["agents"].as_array().cloned().unwrap_or_default().into_iter().collect::<std::collections::VecDeque<_>>(),page["nextCursor"].as_str().map(str::to_owned)))}
        }).collect::<Vec<_>>();
        pages.sort_by(|left, right| left.0.cmp(&right.0));
        let mut rows = Vec::new();
        loop {
            let mut consumed = false;
            for (host, page, _) in &mut pages {
                if rows.len() >= limit as usize {
                    break;
                }
                if let Some(entry) = page.pop_front() {
                    consumed = true;
                    cursor.positions.insert(
                        host.clone(),
                        entry["cursorAfter"].as_str().map(str::to_owned),
                    );
                    rows.push(entry["row"].clone());
                }
            }
            if !consumed || rows.len() >= limit as usize {
                break;
            }
        }
        for (host, page, next) in pages {
            if page.is_empty() {
                cursor.positions.insert(host.clone(), next.clone());
                if next.is_none() {
                    cursor.complete.insert(host);
                }
            }
        }
        coverage.sort_by_key(|row| row["hostId"].as_str().unwrap_or_default().to_owned());
        let next_cursor = if hosts.iter().any(|host| !cursor.complete.contains(host)) {
            Some(
                base64::engine::general_purpose::URL_SAFE_NO_PAD
                    .encode(serde_json::to_vec(&cursor)?),
            )
        } else {
            None
        };
        Ok(json!({"agents":rows,"coverage":coverage,"nextCursor":next_cursor,"warnings":warnings}))
    }
}

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct InventoryCursor {
    jobs: Option<String>,
    sessions: Option<String>,
    jobs_done: bool,
    sessions_done: bool,
}

fn inventory_cursor(cursor: &InventoryCursor) -> Result<String> {
    use base64::Engine;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(serde_json::to_vec(cursor)?))
}

impl Gateway {
    pub(super) async fn local_agent_inventory(&self, params: Value) -> Result<Value> {
        use base64::Engine;
        let limit = params["limit"].as_u64().unwrap_or(100);
        ensure!(
            (1..=1000).contains(&limit),
            "inventory limit must be between 1 and 1000"
        );
        let mut cursor: InventoryCursor = match params["cursor"].as_str() {
            Some(value) => {
                ensure!(value.len() <= 4096, "inventory cursor exceeds capacity");
                serde_json::from_slice(
                    &base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(value)?,
                )?
            }
            None => Default::default(),
        };
        let active = params["active"] == true;
        if active {
            cursor.sessions_done = true;
        }
        let identity = self.host_identity().await?;
        let mut agents = Vec::new();
        if !cursor.jobs_done {
            let page = self
                .jobs
                .store()
                .await?
                .list(
                    if active {
                        crate::agents::jobs::store::Selection::Active
                    } else {
                        crate::agents::jobs::store::Selection::Recent
                    },
                    256.min(limit as u32),
                    cursor.jobs.clone(),
                )
                .await?;
            for row in page.jobs {
                cursor.jobs = Some(row.job_id.as_str().to_owned());
                if let Some(provider) = params["provider"].as_str()
                    && provider != row.provider.as_str()
                {
                    continue;
                }
                let session = match &row.conversation {
                    ConversationBinding::Known { conversation } => {
                        Some(conversation.thread_id.clone())
                    }
                    _ => None,
                };
                agents.push(json!({"row":{"run_id":row.job_id,"agent_id":row.agent_id,"ownerHostId":identity.host_id,"parent":row.parent,"recipient":row.recipient,"provider":row.provider,"provider_session_id":session,"cwd":row.cwd,"model":row.model,"title":row.title,"state":row.state,"status":row.state,"created_at_epoch_ms":row.created_at_ms,"last_active_at_epoch_ms":row.updated_at_ms,"conversation":row.conversation},"cursorAfter":inventory_cursor(&cursor)?}));
            }
            cursor.jobs = page.next_cursor;
            cursor.jobs_done = cursor.jobs.is_none();
        }
        if cursor.jobs_done && agents.len() < limit as usize && !cursor.sessions_done {
            let page = self
                .session_inventory(
                    cursor.sessions.clone(),
                    (limit as usize - agents.len()).min(1000),
                )
                .await?;
            let mut identities = std::collections::HashMap::new();
            for session in &page.sessions {
                if session.host_id != identity.host_id || !session.source_present {
                    continue;
                }
                let conversation =
                    if session.provider == "claude" && session.thread_id.starts_with("claude:") {
                        ConversationIdentity {
                            provider: crate::agents::jobs::model::Provider::Claude,
                            provider_home: crate::agents::jobs::model::ProviderHome::Known {
                                path: self.claude_settings.claude_home.clone(),
                            },
                            thread_id: session.thread_id.clone(),
                        }
                    } else {
                        self.agent_conversation(&session.thread_id)?
                    };
                identities.insert(session.thread_id.clone(), conversation);
            }
            let mut indexed = self
                .jobs
                .store()
                .await?
                .agents_for_conversations(identities.values().cloned().collect())
                .await?;
            for session in page.sessions {
                cursor.sessions = Some(session.session_key.clone());
                let Some(conversation) = identities.remove(&session.thread_id) else {
                    continue;
                };
                let agent = indexed.remove(&conversation);
                if agent
                    .as_ref()
                    .is_some_and(|agent| agent.latest_job_id.is_some())
                {
                    continue;
                }
                if let Some(provider) = params["provider"].as_str()
                    && provider != session.provider
                {
                    continue;
                }
                let parent = agent.as_ref().and_then(|agent| agent.parent.clone());
                let recipient = agent
                    .as_ref()
                    .and_then(|agent| agent.parent_recipient.clone());
                agents.push(json!({"row":{"run_id":null,"agent_id":agent.as_ref().map(|agent|&agent.agent_id),"ownerHostId":identity.host_id,"parent":parent,"recipient":recipient,"provider":session.provider,"provider_session_id":session.thread_id,"cwd":session.cwd,"model":null,"title":session.title.unwrap_or_else(||"Agent".into()),"state":"unknown","status":"unknown","created_at":session.started_at,"last_active_at":session.last_at,"conversation":ConversationBinding::Known {conversation}},"cursorAfter":inventory_cursor(&cursor)?}));
            }
            cursor.sessions = page.cursor;
            cursor.sessions_done = cursor.sessions.is_none();
        }
        let next = if cursor.jobs_done && cursor.sessions_done {
            None
        } else {
            Some(inventory_cursor(&cursor)?)
        };
        Ok(json!({"agents":agents,"nextCursor":next}))
    }
}

impl Gateway {
    pub(super) async fn resolve_local_agent(&self, target: &str) -> Result<Option<Value>> {
        ensure!(
            target.len() >= 4 && target.len() <= 512,
            "use an exact identity or a suffix of at least four characters"
        );
        let identity = self.host_identity().await?;
        if let Ok(id) = JobId::try_from(target.to_owned())
            && let Ok(view) = self.jobs.read(&id).await
        {
            return Ok(Some(
                json!({"ownerHostId":identity.host_id,"jobId":view.job.job_id,"agentId":view.job.agent_id,"conversation":view.agent.map(|agent|agent.conversation)}),
            ));
        }
        let store = self.jobs.store().await?;
        let matches = store.job_suffix_matches(target.to_owned()).await?;
        ensure!(
            matches.len() < 2,
            cluster_error(
                ErrorClass::Usage,
                "agent selector is ambiguous; use an exact address"
            )
        );
        if let Some(id) = matches.into_iter().next() {
            let view = self.jobs.read(&id).await?;
            return Ok(Some(
                json!({"ownerHostId":identity.host_id,"jobId":id,"agentId":view.job.agent_id,"conversation":view.agent.map(|agent|agent.conversation)}),
            ));
        }
        let mut conversations = Vec::new();
        if let Ok(conversation) = self.agent_conversation(target) {
            conversations.push(conversation);
        }
        if crate::ids::is_session_uuid(target) {
            conversations.push(self.agent_conversation(&format!("claude_{target}"))?);
        }
        let mut found = None;
        for agent in store
            .agents_for_conversations(conversations)
            .await?
            .into_values()
        {
            let Some(id) = agent.latest_job_id else {
                ensure!(
                    agent.origin_job_id.is_none(),
                    "conversation latest job is unresolved"
                );
                continue;
            };
            ensure!(
                found.is_none(),
                cluster_error(
                    ErrorClass::Usage,
                    "agent selector is ambiguous; use an exact address"
                )
            );
            found = Some(
                json!({"ownerHostId":identity.host_id,"jobId":id,"agentId":agent.agent_id,"conversation":agent.conversation}),
            );
        }
        if found.is_some() {
            return Ok(found);
        }
        let mut cursor = None;
        let mut found = None;
        loop {
            let page = self.session_inventory(cursor, 1000).await?;
            for session in page.sessions {
                if session.host_id == identity.host_id
                    && session.source_present
                    && (session.thread_id == target || session.thread_id.ends_with(target))
                {
                    if found.is_some() {
                        return Err(cluster_error(
                            ErrorClass::Usage,
                            "conversation selector is ambiguous; use an exact address",
                        )
                        .into());
                    }
                    found = Some(
                        json!({"ownerHostId":identity.host_id,"threadId":session.thread_id,"jobId":null,"kind":"native"}),
                    );
                }
            }
            cursor = page.cursor;
            if cursor.is_none() {
                break;
            }
        }
        Ok(found)
    }

    pub(super) async fn resolve_cluster_agent(&self, params: Value, peer: bool) -> Result<Value> {
        use futures_util::{StreamExt, stream};
        let target = params["target"].as_str().context("target is required")?;
        if let Some(found) = self.resolve_local_agent(target).await? {
            return Ok(found);
        }
        if peer || params["local"] == true {
            return Err(
                cluster_error(ErrorClass::NotFound, "agent was not found on this host").into(),
            );
        }
        let link = self.cluster_link().await?;
        let replies = stream::iter(
            link.members()
                .await?
                .into_iter()
                .filter(|member| member.state == MemberState::Active),
        )
        .map(|member| {
            let link = &link;
            async move {
                (
                    member.host.clone(),
                    link.call(
                        &member.host,
                        "agent/cluster/resolve",
                        json!({"target":target,"local":true}),
                    )
                    .await,
                )
            }
        })
        .buffer_unordered(64)
        .collect::<Vec<_>>()
        .await;
        let mut matches = Vec::new();
        let mut coverage = Vec::new();
        let mut incomplete = false;
        for (host, result) in replies {
            match result {
                Ok(row) => {
                    coverage.push(json!({"hostId":host,"state":"ok"}));
                    matches.push(row);
                }
                Err(error) if error.class == ErrorClass::NotFound => {
                    coverage.push(json!({"hostId":host,"state":"ok"}))
                }
                Err(error) => {
                    incomplete = true;
                    coverage.push(json!({"hostId":host,"state":match error.class {ErrorClass::Unsupported=>"unsupported",ErrorClass::Refused=>"refused",_=>"unreachable"}}));
                }
            }
        }
        if matches.len() > 1 {
            return Err(cluster_error(
                ErrorClass::Usage,
                "agent selector matches multiple hosts; use host:id",
            )
            .with_data(RpcData::Raw(
                json!({"class":ErrorClass::Usage,"candidates":matches,"coverage":coverage}),
            ))
            .into());
        }
        if incomplete {
            return Err(cluster_error(
                ErrorClass::Unavailable,
                "agent resolution has incomplete cluster coverage; use host:id",
            )
            .with_data(RpcData::Raw(
                json!({"class":ErrorClass::Unavailable,"coverage":coverage}),
            ))
            .into());
        }
        matches.pop().ok_or_else(|| {
            cluster_error(ErrorClass::NotFound, "agent was not found in the cluster").into()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn cluster_active_listing_skips_history_pages_and_paginates_only_active_jobs() {
        use crate::agents::jobs::model::*;
        use crate::agents::jobs::store_tests::job;
        use crate::storage::private_state;

        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        let jobs = root.join("agent-jobs/v1/jobs");
        private_state::ensure_private_directory(&jobs).unwrap();
        let finished = ExecutionState::Terminal {
            terminal: Terminal {
                at_ms: Some(3_000),
                execution: None,
                git: GitSnapshot::Unknown {
                    reason: "fixture".into(),
                },
                outcome: JobOutcome::Completed,
                result: ResultEvidence::Expired,
                completion: Completion::NotRequired,
                cleanup: CleanupState::Complete,
            },
        };
        for sequence in 1..=128 {
            let mut settled = job(sequence);
            settled.created_at_ms = Some(1_000 + i64::from(sequence));
            settled.updated_at_ms = 3_000;
            settled.execution = finished.clone();
            private_state::write_json(
                &jobs.join(format!("{}.json", settled.job_id.as_str())),
                &settled,
            )
            .unwrap();
        }
        let mut active = vec![job(201), job(202), job(203)];
        active[1].execution = ExecutionState::WaitingForProvider {
            provider: Provider::Codex,
        };
        active[2].execution = ExecutionState::Unknown {
            conversation: None,
            binding: None,
            reason: "provider observation unavailable".into(),
        };
        for record in &active {
            private_state::write_json(
                &jobs.join(format!("{}.json", record.job_id.as_str())),
                record,
            )
            .unwrap();
        }
        let mut imported = job(204);
        imported.source = JobSource::Imported;
        imported.admission_origin = None;
        imported.execution = active[2].execution.clone();
        imported.created_at_ms = Some(2_000);
        private_state::write_json(
            &jobs.join(format!("{}.json", imported.job_id.as_str())),
            &imported,
        )
        .unwrap();

        let sessions = root.join("codex/sessions/2026/10/28");
        std::fs::create_dir_all(&sessions).unwrap();
        for sequence in 0..128 {
            let id = format!("00000000-0000-4000-8000-{sequence:012x}");
            let metadata = json!({"type":"session_meta","timestamp":"2026-10-28T10:00:00Z","payload":{"id":id,"cwd":root,"source":"cli"}});
            std::fs::write(
                sessions.join(format!("{id}.jsonl")),
                format!("{metadata}\n"),
            )
            .unwrap();
        }
        let gateway = crate::test_support::TestGateway::with_native_runtime(root);
        gateway.sessions_runtime().await.unwrap();
        gateway.stop_sessions().await;
        assert_eq!(
            gateway
                .session_inventory(None, 1000)
                .await
                .unwrap()
                .sessions
                .len(),
            128
        );
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(root.join("sessions/v1/.storage.lock"))
            .unwrap();
        let _lease = crate::sessions::storage::Lease::acquire(file).unwrap();
        assert!(gateway.session_inventory(None, 1).await.is_err());

        let mut cursor = Value::Null;
        let mut seen = Vec::new();
        for expected in [2, 1] {
            let page = gateway
                .cluster_rpc(
                    &Grant::Operator,
                    "agent/cluster/list",
                    json!({"local":true,"active":true,"limit":2,"cursor":cursor}),
                )
                .await
                .unwrap();
            assert_eq!(page["coverage"][0]["state"], "ok", "{page}");
            assert_eq!(page["warnings"], json!([]));
            let rows = page["agents"].as_array().unwrap();
            assert_eq!(rows.len(), expected, "{page}");
            for row in rows {
                seen.push(row["run_id"].as_str().unwrap().to_owned());
            }
            cursor = page["nextCursor"].clone();
            assert_eq!(cursor.is_null(), expected == 1);
        }
        assert_eq!(
            seen,
            active
                .iter()
                .rev()
                .map(|record| record.job_id.as_str().to_owned())
                .collect::<Vec<_>>()
        );
        let page = gateway
            .cluster_rpc(
                &Grant::Operator,
                "agent/cluster/list",
                json!({"local":true,"active":true,"limit":3}),
            )
            .await
            .unwrap();
        assert_eq!(page["agents"].as_array().unwrap().len(), 3);
        assert!(page["nextCursor"].is_null());
        assert_eq!(page["warnings"], json!([]));
        for record in active {
            gateway
                .jobs
                .store()
                .await
                .unwrap()
                .advance(record.job_id, 0, finished.clone(), 3_000)
                .await
                .unwrap();
        }
        let page = gateway
            .cluster_rpc(
                &Grant::Operator,
                "agent/cluster/list",
                json!({"local":true,"active":true,"limit":1}),
            )
            .await
            .unwrap();
        assert_eq!(page["agents"], json!([]));
        assert!(page["nextCursor"].is_null());
        assert_eq!(page["coverage"][0]["state"], "ok");
        assert_eq!(page["warnings"], json!([]));
    }

    #[tokio::test]
    async fn cluster_inventory_writer_contention_preserves_unavailable_and_coverage() {
        let directory = tempfile::tempdir().unwrap();
        let gateway = crate::test_support::TestGateway::with_native_runtime(directory.path());
        gateway.sessions_runtime().await.unwrap();
        gateway.stop_sessions().await;
        let root = gateway
            .turn_state_path
            .as_ref()
            .unwrap()
            .parent()
            .unwrap()
            .join("sessions/v1");
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(root.join(".storage.lock"))
            .unwrap();
        let lease = crate::sessions::storage::Lease::acquire(file).unwrap();
        for (method, params) in [
            ("agent/cluster/inventory", json!({"limit":100})),
            (
                "agent/cluster/resolve",
                json!({"target":"unmatched-conversation","local":true}),
            ),
        ] {
            let error = gateway
                .cluster_rpc(&Grant::Operator, method, params)
                .await
                .unwrap_err();
            let response = error.response(&Value::Null);
            let encoded = &response["error"];
            assert_eq!(encoded["data"]["class"], "unavailable");
            assert!(
                encoded["message"]
                    .as_str()
                    .unwrap()
                    .contains("another session writer owns the storage budget")
            );
        }
        let page = gateway
            .cluster_rpc(
                &Grant::Operator,
                "agent/cluster/list",
                json!({"local":true}),
            )
            .await
            .unwrap();
        assert_eq!(page["coverage"][0]["state"], "unreachable");
        assert!(
            page["warnings"][0]
                .as_str()
                .unwrap()
                .contains("another session writer owns the storage budget")
        );
        drop(lease);
        let page = gateway
            .cluster_rpc(
                &Grant::Operator,
                "agent/cluster/list",
                json!({"local":true}),
            )
            .await
            .unwrap();
        assert_eq!(page["coverage"][0]["state"], "ok", "{page}");
    }
}
