use anyhow::Result;
use futures_util::{StreamExt, future::BoxFuture, stream};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;

pub(crate) type MemberCall =
    Arc<dyn Fn(String, String, Value) -> BoxFuture<'static, Result<Value>> + Send + Sync>;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Position {
    Next(Option<String>),
    Exhausted,
}

pub(crate) fn positions(cursor: Option<&str>) -> Result<BTreeMap<String, Position>> {
    anyhow::ensure!(
        cursor.is_none_or(|cursor| cursor.len() <= 1024 * 1024),
        "capacity: search cursor exceeds 1 MiB"
    );
    let positions: BTreeMap<String, Position> = cursor
        .map(serde_json::from_str)
        .transpose()?
        .unwrap_or_default();
    anyhow::ensure!(
        positions.len() <= 1024,
        "capacity: search cursor exceeds 1024 members"
    );
    Ok(positions)
}

pub(crate) async fn search(
    local_host: &str,
    local: Value,
    members: Vec<String>,
    request: super::query::Search,
    call: MemberCall,
) -> Result<Value> {
    let cursors = positions(request.cursor.as_deref())?;
    let members: std::collections::BTreeSet<_> = members
        .into_iter()
        .chain(
            cursors
                .keys()
                .filter(|host| host.as_str() != local_host)
                .cloned(),
        )
        .collect();
    let mut request = request;
    request.local = true;
    let pages = stream::iter(members.into_iter().map(|host| {
        let call = call.clone();
        let mut request = request.clone();
        let position = cursors.get(&host).cloned().unwrap_or(Position::Next(None));
        let exhausted = matches!(position, Position::Exhausted);
        request.cursor = match position {
            Position::Next(cursor) => cursor,
            Position::Exhausted => None,
        };
        async move {
            if exhausted {
                return (host, Ok(json!({"hits":[],"cursor":null,"exhausted":true})));
            }
            let result = call(
                host.clone(),
                "sessions/search".into(),
                serde_json::to_value(request).expect("serializable search"),
            )
            .await;
            (host, result)
        }
    }))
    .buffer_unordered(64)
    .collect::<Vec<_>>()
    .await;
    let mut hits = local["hits"].as_array().cloned().unwrap_or_default();
    let mut coverage = vec![json!({"hostId":local_host,"state":"ok","coverage":local["coverage"]})];
    let mut next = BTreeMap::from([(
        local_host.to_owned(),
        local["cursor"]
            .as_str()
            .map(|cursor| Position::Next(Some(cursor.into())))
            .unwrap_or(Position::Exhausted),
    )]);
    for (host, result) in pages {
        match result {
            Ok(page) => {
                if let Some(page_hits) = page["hits"].as_array() {
                    hits.extend(page_hits.iter().cloned());
                }
                next.insert(
                    host.clone(),
                    page["cursor"]
                        .as_str()
                        .map(|cursor| Position::Next(Some(cursor.into())))
                        .unwrap_or(Position::Exhausted),
                );
                coverage.push(json!({"hostId":host,"state":"ok","coverage":page["coverage"]}));
            }
            Err(error) => {
                next.insert(
                    host.clone(),
                    cursors.get(&host).cloned().unwrap_or(Position::Next(None)),
                );
                let state = match error
                    .downcast_ref::<crate::cluster::link::LinkError>()
                    .map(|error| &error.class)
                {
                    Some(crate::wire::cluster::ErrorClass::Unsupported) => "unsupported",
                    Some(crate::wire::cluster::ErrorClass::Refused) => "refused",
                    _ => "unreachable",
                };
                coverage.push(json!({"hostId":host,"state":state,"error":format!("{error:#}")}));
            }
        }
    }
    let mut identities = std::collections::BTreeSet::new();
    hits.retain(|hit| {
        hit["itemKey"]
            .as_str()
            .is_some_and(|key| identities.insert(key.to_owned()))
    });
    anyhow::ensure!(
        serde_json::to_vec(&hits)?.len() < super::PAGE_BYTES - 65536,
        "capacity: cluster search page exceeds 8 MiB; lower --limit"
    );
    let has_more = next
        .values()
        .any(|position| matches!(position, Position::Next(_)));
    Ok(
        json!({"schemaVersion":1,"hits":hits,"cursor":if has_more {Some(serde_json::to_string(&next)?)} else {None},"coverage":coverage}),
    )
}
