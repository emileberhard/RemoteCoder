use super::Origin;
use crate::agents::jobs::model::{ConversationIdentity, ProviderHome};
use crate::wire::cluster::AgentAddress;
use anyhow::{Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{BufRead, BufReader};

pub(crate) type Parents = HashMap<ConversationIdentity, Option<AgentAddress>>;

pub(crate) fn parents(db: &Connection, origins: &[Origin], parents: &Parents) -> Result<()> {
    for (identity, parent) in parents {
        let ProviderHome::Known { path } = &identity.provider_home else {
            continue;
        };
        let Some(origin) = origins
            .iter()
            .find(|o| o.provider == identity.provider.as_str() && o.provider_home == *path)
        else {
            continue;
        };
        let key = super::session_key(origin, &identity.thread_id);
        let parent_key = match parent {
            None => None,
            Some(parent) => {
                let keys: Vec<String> = db.prepare("SELECT session_key FROM session WHERE origin_host=?1 AND thread_id=?2 LIMIT 2")?.query_map(params![parent.host_id,parent.thread_id], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
                if keys.len() != 1 {
                    continue;
                }
                keys.into_iter().next()
            }
        };
        db.execute("UPDATE session SET delegated_parent_known=1,delegated_parent_session_key=?2 WHERE session_key=?1 AND (delegated_parent_known=0 OR delegated_parent_session_key IS NOT ?2)", params![key,parent_key])?;
    }
    Ok(())
}

pub(crate) fn titles(db: &Connection, origins: &[Origin]) -> Result<()> {
    for origin in origins.iter().filter(|o| o.provider == "codex") {
        let path = origin.local_home.join("session_index.jsonl");
        let Some(identity) = super::ingest::file_identity(&path)? else {
            continue;
        };
        let cache_key = format!(
            "native_titles:{}:{}",
            origin.host,
            origin.provider_home.display()
        );
        if db
            .query_row("SELECT value FROM meta WHERE key=?1", [&cache_key], |r| {
                r.get::<_, String>(0)
            })
            .optional()?
            .as_deref()
            == Some(&identity)
        {
            continue;
        }
        let file = std::fs::File::open(&path)?;
        ensure!(
            file.metadata()?.len() <= 16 << 20,
            "capacity: native title index exceeds 16 MiB"
        );
        let mut titles = HashMap::new();
        for line in BufReader::new(file).lines() {
            let value: serde_json::Value = match serde_json::from_str(&line?) {
                Ok(value) => value,
                Err(_) => continue,
            };
            if let (Some(id), Some(title)) = (
                value["id"].as_str(),
                value["thread_name"].as_str().filter(|t| !t.is_empty()),
            ) {
                titles.insert(id.to_owned(), title.to_owned());
            }
        }
        for (thread, title) in titles {
            db.execute(
                "UPDATE session SET title=?2 WHERE session_key=?1 AND title IS NOT ?2",
                params![super::session_key(origin, &thread), title],
            )?;
        }
        db.execute(
            "INSERT OR REPLACE INTO meta VALUES(?1,?2)",
            params![cache_key, identity],
        )?;
    }
    Ok(())
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct SessionMetadata {
    pub(super) session_key: String,
    title: Option<String>,
    delegated_parent_known: bool,
    delegated_parent_session_key: Option<String>,
}

pub(super) fn page(
    db: &Connection,
    host: &str,
    entries: &[super::mirror::Entry],
) -> Result<Vec<SessionMetadata>> {
    let mut result = Vec::new();
    for entry in entries.iter().filter(|entry| !entry.dependency) {
        if let Some(metadata) = db.query_row("SELECT session_key,title,delegated_parent_known,delegated_parent_session_key FROM session JOIN source USING(source_id) WHERE source.origin_host=?1 AND source.path=?2", params![host,entry.path.to_string_lossy()], |r| Ok(SessionMetadata {session_key:r.get(0)?,title:r.get(1)?,delegated_parent_known:r.get(2)?,delegated_parent_session_key:r.get(3)?})).optional()? { result.push(metadata); }
    }
    Ok(result)
}

pub(super) fn apply(db: &Connection, host: &str, metadata: &[SessionMetadata]) -> Result<()> {
    for value in metadata {
        db.execute("UPDATE session SET title=?2,delegated_parent_known=?3,delegated_parent_session_key=?4 WHERE session_key=?1 AND origin_host=?5 AND (title IS NOT ?2 OR delegated_parent_known IS NOT ?3 OR delegated_parent_session_key IS NOT ?4)", params![value.session_key,value.title,value.delegated_parent_known,value.delegated_parent_session_key,host])?;
    }
    Ok(())
}
