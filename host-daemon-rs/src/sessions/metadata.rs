use super::Origin;
use crate::agents::jobs::model::{ConversationIdentity, ProviderHome};
use crate::wire::cluster::AgentAddress;
use anyhow::{Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Seek};

pub(crate) type Parents = HashMap<ConversationIdentity, Option<AgentAddress>>;

pub(crate) fn parents(db: &Connection, origins: &[Origin], parents: &Parents) -> Result<Parents> {
    let tx = db.unchecked_transaction()?;
    let mut unresolved = Parents::new();
    {
        let mut existing = tx.prepare("SELECT EXISTS(SELECT 1 FROM session JOIN source USING(source_id) WHERE session_key=?1 AND source.present=1)")?;
        let mut find_parent = tx.prepare("SELECT session_key FROM session JOIN source USING(source_id) WHERE session.origin_host=?1 AND thread_id=?2 AND source.present=1 LIMIT 2")?;
        let mut update = tx.prepare("UPDATE session SET delegated_parent_known=1,delegated_parent_session_key=?2 WHERE session_key=?1 AND (delegated_parent_known=0 OR delegated_parent_session_key IS NOT ?2)")?;
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
            if !existing.query_row([&key], |r| r.get::<_, bool>(0))? {
                unresolved.insert(identity.clone(), parent.clone());
                continue;
            }
            let parent_key = match parent {
                None => None,
                Some(address) => {
                    let keys = find_parent
                        .query_map(params![address.host_id, address.thread_id], |r| {
                            r.get::<_, String>(0)
                        })?
                        .collect::<rusqlite::Result<Vec<_>>>()?;
                    if keys.len() != 1 {
                        unresolved.insert(identity.clone(), parent.clone());
                        continue;
                    }
                    keys.into_iter().next()
                }
            };
            update.execute(params![key, parent_key])?;
        }
    }
    tx.commit()?;
    Ok(unresolved)
}

#[derive(Serialize, Deserialize)]
struct TitleCheckpoint {
    identity: String,
    bytes: u64,
    hash: String,
}

pub(crate) fn titles(db: &Connection, origins: &[Origin]) -> Result<()> {
    for origin in origins.iter().filter(|o| o.provider == "codex") {
        let path = origin.local_home.join("session_index.jsonl");
        let mut file = match std::fs::File::open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        };
        let revision = file.metadata()?;
        ensure!(
            revision.is_file() && revision.len() <= 16 << 20,
            "capacity: native title index exceeds 16 MiB"
        );
        let identity = super::ingest::identity(&revision);
        let cache_key = titles_key(origin);
        let prior = db
            .query_row("SELECT value FROM meta WHERE key=?1", [&cache_key], |r| {
                r.get::<_, String>(0)
            })
            .optional()?
            .and_then(|value| serde_json::from_str::<TitleCheckpoint>(&value).ok());
        if prior
            .as_ref()
            .is_some_and(|prior| prior.identity == identity)
        {
            continue;
        }

        let mut hash = blake3::Hasher::new();
        let mut offset = 0;
        if let Some(prior) = prior.filter(|prior| prior.bytes > 0 && prior.bytes < revision.len()) {
            let length = std::io::copy(&mut (&mut file).take(prior.bytes), &mut hash)?;
            if length == prior.bytes && hash.finalize().to_hex().as_str() == prior.hash {
                offset = prior.bytes;
            } else {
                file.rewind()?;
                hash.reset();
            }
        }

        let mut reader = BufReader::new(file.take(revision.len() - offset));
        let mut line = Vec::new();
        let mut updates = HashMap::new();
        loop {
            line.clear();
            let count = reader.read_until(b'\n', &mut line)?;
            if count == 0 || !line.ends_with(b"\n") {
                break;
            }
            offset += count as u64;
            hash.update(&line);
            let value: serde_json::Value = match serde_json::from_slice(&line) {
                Ok(value) => value,
                Err(_) => continue,
            };
            if let (Some(id), Some(title)) = (
                value["id"].as_str(),
                value["thread_name"].as_str().filter(|t| !t.is_empty()),
            ) {
                updates.insert(id.to_owned(), title.to_owned());
            }
        }
        let checkpoint = TitleCheckpoint {
            identity,
            bytes: offset,
            hash: hash.finalize().to_hex().to_string(),
        };
        let tx = db.unchecked_transaction()?;
        {
            let mut update =
                tx.prepare("UPDATE session SET title=?2 WHERE session_key=?1 AND title IS NOT ?2")?;
            for (thread, title) in updates {
                update.execute(params![super::session_key(origin, &thread), title])?;
            }
        }
        tx.execute(
            "INSERT OR REPLACE INTO meta VALUES(?1,?2)",
            params![cache_key, serde_json::to_string(&checkpoint)?],
        )?;
        tx.commit()?;
    }
    Ok(())
}

pub(super) fn identity_generation(db: &Connection) -> Result<i64> {
    Ok(db
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM meta WHERE key='session_identity_generation'",
            [],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or(0))
}

fn titles_key(origin: &Origin) -> String {
    format!(
        "native_titles:{}:{}",
        origin.host,
        origin.provider_home.display()
    )
}

pub(super) fn source_metadata(db: &Connection, source: i64) -> Result<Option<SessionMetadata>> {
    Ok(db.query_row("SELECT session_key,title,delegated_parent_known,delegated_parent_session_key FROM session WHERE source_id=?1", [source], SessionMetadata::from_row).optional()?)
}

pub(super) fn source_replaced(
    db: &Connection,
    origin: &Origin,
    prior: Option<&SessionMetadata>,
    thread: Option<&str>,
) -> Result<()> {
    if let Some(thread) = thread {
        let key = super::session_key(origin, thread);
        if prior.is_none_or(|prior| prior.session_key != key) {
            db.execute("INSERT INTO meta VALUES('session_identity_generation','1') ON CONFLICT(key) DO UPDATE SET value=CAST(value AS INTEGER)+1", [])?;
        }
    }
    let codex = origin.provider == "codex";
    if codex {
        db.execute("DELETE FROM meta WHERE key=?1", [titles_key(origin)])?;
    }
    if let Some(prior) = prior {
        db.execute("UPDATE session SET title=CASE WHEN ?2 THEN ?3 ELSE title END,delegated_parent_known=?4,delegated_parent_session_key=?5 WHERE session_key=?1 AND ((?2 AND title IS NOT ?3) OR delegated_parent_known IS NOT ?4 OR delegated_parent_session_key IS NOT ?5)", params![prior.session_key,codex,prior.title,prior.delegated_parent_known,prior.delegated_parent_session_key])?;
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

impl SessionMetadata {
    fn from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            session_key: r.get(0)?,
            title: r.get(1)?,
            delegated_parent_known: r.get(2)?,
            delegated_parent_session_key: r.get(3)?,
        })
    }
}

pub(super) fn page(
    db: &Connection,
    host: &str,
    entries: &[super::mirror::Entry],
) -> Result<Vec<SessionMetadata>> {
    let mut result = Vec::new();
    for entry in entries.iter().filter(|entry| !entry.dependency) {
        if let Some(metadata) = db.query_row("SELECT session_key,title,delegated_parent_known,delegated_parent_session_key FROM session JOIN source USING(source_id) WHERE source.origin_host=?1 AND source.path=?2", params![host,entry.path.to_string_lossy()], SessionMetadata::from_row).optional()? { result.push(metadata); }
    }
    Ok(result)
}

pub(super) fn apply(db: &Connection, host: &str, metadata: &[SessionMetadata]) -> Result<()> {
    for value in metadata {
        db.execute("UPDATE session SET title=?2,delegated_parent_known=?3,delegated_parent_session_key=?4 WHERE session_key=?1 AND origin_host=?5 AND (title IS NOT ?2 OR delegated_parent_known IS NOT ?3 OR delegated_parent_session_key IS NOT ?4)", params![value.session_key,value.title,value.delegated_parent_known,value.delegated_parent_session_key,host])?;
    }
    Ok(())
}
