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
        let mut pages=pages.into_iter().filter_map(|(host,result)| match result {
            Err(error)=> {coverage.push(json!({"hostId":host,"state":match error.class {ErrorClass::Unsupported=>"unsupported",ErrorClass::Refused=>"refused",_=>"unreachable"}}));None}
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
        Ok(json!({"agents":rows,"coverage":coverage,"nextCursor":next_cursor,"warnings":[]}))
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
        let identity = self.host_identity().await?;
        let mut agents = Vec::new();
        if !cursor.jobs_done {
            let page = self
                .jobs
                .list(agent_jobs::ListParams {
                    selector: agent_jobs::ListSelector::Recent,
                    limit: 256.min(limit as u32),
                    cursor: cursor.jobs.clone(),
                })
                .await?;
            for row in page.jobs {
                cursor.jobs = Some(row.job_id.as_str().to_owned());
                if params["active"] == true && !row.active {
                    continue;
                }
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
            for session in page.sessions {
                cursor.sessions = Some(session.session_key.clone());
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
                let agent = self.jobs.agent_for_conversation(&conversation).await?;
                if agent
                    .as_ref()
                    .is_some_and(|agent| agent.latest_job_id.is_some())
                {
                    continue;
                }
                if params["active"] == true {
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
        let mut cursor = None;
        let mut found = std::collections::BTreeMap::<String, Value>::new();
        loop {
            let page = self
                .jobs
                .list(agent_jobs::ListParams {
                    selector: agent_jobs::ListSelector::Recent,
                    limit: 256,
                    cursor,
                })
                .await?;
            for row in page.jobs {
                let session = match &row.conversation {
                    ConversationBinding::Known { conversation } => {
                        Some(conversation.thread_id.as_str())
                    }
                    _ => None,
                };
                if row.job_id.as_str().ends_with(target)
                    || session.is_some_and(|thread| {
                        thread == target || thread.strip_prefix("claude_") == Some(target)
                    })
                {
                    let view = self.jobs.read(&row.job_id).await?;
                    let selected = if row.job_id.as_str().ends_with(target) {
                        row.job_id
                    } else {
                        view.agent
                            .as_ref()
                            .and_then(|agent| agent.latest_job_id.clone())
                            .context("conversation latest job is unresolved")?
                    };
                    found.insert(row.agent_id.clone(),json!({"ownerHostId":identity.host_id,"jobId":selected,"agentId":row.agent_id,"conversation":row.conversation}));
                    if found.len() > 1 {
                        return Err(cluster_error(
                            ErrorClass::Usage,
                            "agent selector is ambiguous; use an exact address",
                        )
                        .into());
                    }
                }
            }
            cursor = page.next_cursor;
            if cursor.is_none() {
                break;
            }
        }
        if let Some(row) = found.into_values().next() {
            return Ok(Some(row));
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
