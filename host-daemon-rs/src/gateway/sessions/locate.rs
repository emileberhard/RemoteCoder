use super::{Gateway, SESSION_REQUEST_DEADLINE, session_error};
use crate::auth::installation_credentials::Grant;
use crate::providers::claude::projection::LocateTarget;
use crate::rpc::{RpcError, RpcResult};
use crate::sessions::{cluster, locate, store::ReadControl};
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Arc;

impl Gateway {
    pub(super) async fn locate_session(
        self: &Arc<Self>,
        grant: &Grant,
        params: Value,
    ) -> RpcResult {
        let request: locate::Request =
            serde_json::from_value(params).map_err(|e| session_error(e.into()))?;
        let deadline = SESSION_REQUEST_DEADLINE
            .try_with(|d| *d)
            .unwrap_or_else(|_| std::time::Instant::now() + locate::DEADLINE);
        let control = ReadControl::new(deadline);
        let _cancel = control.cancel_on_drop();
        let work = async {
            let host = self.host_identity().await.map_err(session_error)?.host_id;
            if !matches!(grant, Grant::Peer { .. })
                && let Some(origin) = cluster::target_origin(&host, &request.item_key)
            {
                return self
                    .cluster_link()
                    .await
                    .map_err(session_error)?
                    .call(
                        &origin,
                        "sessions/locate",
                        serde_json::to_value(&request).map_err(|e| session_error(e.into()))?,
                    )
                    .await
                    .map_err(|e| session_error(e.into()));
            }
            let runtime = self
                .sessions_runtime()
                .await
                .map_err(session_error)?
                .clone();
            let permit = runtime
                .search_readers
                .clone()
                .acquire_owned()
                .await
                .map_err(|e| session_error(e.into()))?;
            let store = runtime.store.clone();
            let gateway = self.clone();
            let reading = control.clone();
            let handle = tokio::runtime::Handle::current();
            let item = tokio::task::spawn_blocking(move || -> Result<locate::Item> {
                let _permit = permit;
                let mut db = store.reader()?;
                db.interrupt_on(reading.clone())?;
                let mut item = locate::item(&db, &request, &reading)?;
                if item.provider == "claude" {
                    let child = item
                        .response
                        .thread_id
                        .strip_prefix("claude:")
                        .and_then(|id| id.split_once(':'))
                        .map(|(parent, agent)| (format!("claude_{parent}"), agent.to_owned()));
                    let target = if let Some((parent, agent_id)) = child {
                        item.response.thread_id = parent;
                        LocateTarget::Agent { agent_id }
                    } else {
                        LocateTarget::Item {
                            offset: item.reference.offset,
                            part: item.part,
                        }
                    };
                    let active = handle.block_on(tokio::time::timeout_at(
                        tokio::time::Instant::from_std(deadline),
                        gateway.claude_active_turn_id(&item.response.thread_id),
                    ))?;
                    let location = gateway
                        .claude_history
                        .locate_blocking(
                            &item.response.thread_id,
                            active.as_deref(),
                            &target,
                            &|| {
                                ensure!(!reading.stopped(), "locate interrupted");
                                Ok(())
                            },
                            |file| {
                                if matches!(target, LocateTarget::Item { .. }) {
                                    crate::sessions::query::verified_item_bytes(
                                        file.try_clone()?,
                                        &item.reference,
                                        0,
                                        0,
                                        || {
                                            ensure!(!reading.stopped(), "locate interrupted");
                                            Ok(())
                                        },
                                    )?;
                                }
                                Ok(())
                            },
                        )
                        .map_err(|error| anyhow::anyhow!("Claude locate failed: {error:?}"))?;
                    if let Some(location) = location {
                        item.response.turn_id = Some(location.turn_id);
                        item.response.item_id = Some(location.item_id);
                        item.response.turns_cursor = Some(location.turns_cursor);
                        item.response.items_cursor = Some(location.items_cursor);
                    }
                }
                Ok(item)
            })
            .await
            .map_err(|e| session_error(e.into()))?
            .map_err(session_error)?;
            if item.provider != "codex"
                || (item.response.turn_id.is_none()
                    && !matches!(item.kind.as_str(), "user" | "assistant"))
            {
                return serde_json::to_value(item.response).map_err(|e| session_error(e.into()));
            }
            let Ok(permit) = runtime.native_locates.clone().try_acquire_owned() else {
                return serde_json::to_value(item.response).map_err(|e| session_error(e.into()));
            };
            let fallback = item.response.clone();
            let gateway = self.clone();
            let native_control = control.clone();
            let (reply, result) = tokio::sync::oneshot::channel();
            if !runtime
                .locate_tasks
                .spawn("sessions_locate_native", async move {
                    let _permit = permit;
                    let response = gateway.locate_native_item(item, native_control).await;
                    let _ = reply.send(response);
                    Ok(())
                })
            {
                return serde_json::to_value(fallback).map_err(|e| session_error(e.into()));
            }
            serde_json::to_value(result.await.map_err(|e| session_error(e.into()))?)
                .map_err(|e| session_error(e.into()))
        };
        match tokio::time::timeout_at(tokio::time::Instant::from_std(deadline), work).await {
            Ok(result) if !control.stopped() => result,
            _ => Err(RpcError::request_timed_out(locate::DEADLINE)),
        }
    }

    async fn locate_native_item(
        &self,
        item: locate::Item,
        control: Arc<ReadControl>,
    ) -> locate::Response {
        let mut response = if matches!(item.kind.as_str(), "user" | "assistant") {
            self.locate_native_occurrence(item, &control).await
        } else {
            item.response
        };
        if !control.stopped()
            && let Some(turn)=&response.turn_id
            && let Ok(page)=self.call_control_read_until_reply("thread/items/list",json!({"threadId":response.thread_id,"turnId":turn,"limit":1,"sortDirection":"asc"})).await
            && let Some(rows)=page["data"].as_array()
            && let Some(first)=rows.first().filter(|_|rows.len()==1)
            && first["turnId"]==*turn
        {
            response.items_cursor=page["backwardsCursor"].as_str().map(str::to_owned);
        }
        response
    }

    async fn locate_native_occurrence(
        &self,
        item: locate::Item,
        control: &ReadControl,
    ) -> locate::Response {
        let mut response = item.response;
        let Some(text) = item.text.filter(|s| !s.trim().is_empty()) else {
            return response;
        };
        let term = crate::prompt_summary::prompt_summary(&text)
            .chars()
            .take(160)
            .collect::<String>();
        if term.trim().is_empty() {
            return response;
        }
        let mut cursor = None;
        let mut matches = HashMap::new();
        let mut complete = false;
        for _ in 0..2 {
            if control.stopped() {
                return response;
            }
            let page=match self.call_control_read_until_reply("thread/searchOccurrences",json!({"threadId":response.thread_id,"searchTerm":term,"cursor":cursor,"limit":100})).await { Ok(page)=>page,Err(_)=>return response };
            let Some(rows) = page["data"].as_array() else {
                return response;
            };
            for row in rows {
                if response
                    .turn_id
                    .as_deref()
                    .is_some_and(|t| row["turnId"].as_str() != Some(t))
                {
                    continue;
                }
                if let (Some(id), Some(turn), Some(position)) = (
                    row["itemId"].as_str(),
                    row["turnId"].as_str(),
                    row["turnCursor"].as_str(),
                ) {
                    if response.turn_id.as_deref() == Some(turn) {
                        response.turns_cursor = Some(position.to_owned());
                    }
                    matches.insert(id.to_owned(), (turn.to_owned(), position.to_owned()));
                }
            }
            cursor = page["nextCursor"].as_str().map(str::to_owned);
            if cursor.is_none() {
                complete = true;
                break;
            }
        }
        if control.stopped() {
            return response;
        }
        if let Some(id) = item.provider_item_id {
            matches.retain(|key, _| key == &id);
        } else if !complete || !item.unique_text {
            return response;
        }
        if matches.len() != 1 {
            return response;
        }
        let (id, (turn, position)) = matches.into_iter().next().expect("one candidate");
        let page = match self
            .call_control_read_until_reply(
                "thread/items/read",
                json!({"threadId":response.thread_id,"turnId":turn,"itemIds":[id]}),
            )
            .await
        {
            Ok(page) => page,
            Err(_) => return response,
        };
        let Some(rows) = page["data"].as_array() else {
            return response;
        };
        let Some(entry) = rows.first().filter(|_| rows.len() == 1) else {
            return response;
        };
        if entry["turnId"] == turn
            && entry["item"]["id"] == id
            && locate::item_text(&entry["item"]).as_deref() == Some(text.as_str())
        {
            response.turn_id = Some(turn);
            response.turns_cursor = Some(position);
            response.item_id = Some(id);
        }
        response
    }
}
