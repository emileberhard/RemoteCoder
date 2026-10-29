use super::{PAGE_BYTES, PAGE_ROWS, changes};
use anyhow::{Context, Result, ensure};
use base64::Engine;
use rusqlite::{Connection, Params, params, types::ValueRef};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

pub(crate) fn coverage(db: &super::store::Reader) -> Result<Value> {
    let mut result = rows(
        db,
        "SELECT origin_host,mode,indexed_through,complete_through,stale_reason,parse_failures FROM coverage ORDER BY origin_host",
        [],
    )?;
    result["storage"] = serde_json::to_value(db.storage.usage()?)?;
    Ok(result)
}

pub(crate) fn rows(db: &Connection, sql: &str, params: impl Params) -> Result<Value> {
    let mut stmt = db.prepare(sql)?;
    ensure!(stmt.readonly(), "sql accepts one read-only statement");
    let columns: Vec<String> = stmt.column_names().map(str::to_owned).collect();
    let mut cursor = stmt.query(params)?;
    let mut result = Vec::new();
    let mut bytes = serde_json::to_vec(&columns)?.len() + 64 * 1024;
    let mut truncated = false;
    while let Some(row) = cursor.next()? {
        let values: Vec<Value> = (0..columns.len())
            .map(|i| -> Result<Value> {
                Ok(match row.get_ref(i)? {
                    ValueRef::Null => Value::Null,
                    ValueRef::Integer(v) => json!(v),
                    ValueRef::Real(v) => json!(v),
                    ValueRef::Text(v) => json!(std::str::from_utf8(v)?),
                    ValueRef::Blob(v) => {
                        json!({"base64":base64::engine::general_purpose::STANDARD.encode(v)})
                    }
                })
            })
            .collect::<Result<_>>()?;
        let length = serde_json::to_vec(&values)?.len() + 1;
        if result.len() == PAGE_ROWS || bytes + length > PAGE_BYTES {
            truncated = true;
            break;
        }
        bytes += length;
        result.push(values);
    }
    Ok(json!({"columns":columns,"rows":result,"truncated":truncated}))
}

pub(crate) fn sql(db: &super::store::Reader, sql: &str) -> Result<Value> {
    let tx = db.unchecked_transaction()?;
    let mut result = rows(&tx, sql, [])?;
    result["changeCursor"] = json!(changes::cursor(&tx)?);
    result["schemaVersion"] = json!(1);
    result["coverage"] = coverage(db)?;
    Ok(result)
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SessionHeader {
    pub session_key: String,
    pub host_id: String,
    pub provider: String,
    pub thread_id: String,
    pub cwd: Option<String>,
    pub title: Option<String>,
    pub started_at: Option<String>,
    pub last_at: Option<String>,
    pub parent_session_key: Option<String>,
    pub source_present: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SessionPage {
    pub sessions: Vec<SessionHeader>,
    pub cursor: Option<String>,
}

pub(crate) fn inventory(
    db: &super::store::Reader,
    after: Option<&str>,
    limit: usize,
) -> Result<SessionPage> {
    ensure!(
        (1..=1000).contains(&limit),
        "Inventory limit must be 1..=1000"
    );
    let mut statement=db.prepare("SELECT s.session_key,s.origin_host,s.provider,s.thread_id,s.cwd,s.title,s.started_at,s.last_at,s.parent_session_key,src.present FROM session s JOIN source src USING(source_id) WHERE s.session_key>?1 ORDER BY s.session_key LIMIT ?2")?;
    let rows = statement.query_map(params![after.unwrap_or(""), limit as i64 + 1], |r| {
        session_header(r)
    })?;
    let mut sessions = Vec::new();
    let mut bytes = 65536;
    let mut more = false;
    for header in rows {
        let header = header?;
        let length = serde_json::to_vec(&header)?.len() + 1;
        if sessions.len() == limit || bytes + length > PAGE_BYTES {
            more = true;
            break;
        }
        bytes += length;
        sessions.push(header);
    }
    ensure!(
        !more || !sessions.is_empty(),
        "capacity: session header exceeds 8 MiB"
    );
    let cursor = if more {
        sessions.last().map(|s| s.session_key.clone())
    } else {
        None
    };
    Ok(SessionPage { sessions, cursor })
}

fn session_header(r: &rusqlite::Row<'_>) -> rusqlite::Result<SessionHeader> {
    Ok(SessionHeader {
        session_key: r.get(0)?,
        host_id: r.get(1)?,
        provider: r.get(2)?,
        thread_id: r.get(3)?,
        cwd: r.get(4)?,
        title: r.get(5)?,
        started_at: r.get(6)?,
        last_at: r.get(7)?,
        parent_session_key: r.get(8)?,
        source_present: r.get(9)?,
    })
}

pub(super) const THREAD_SUFFIX_SQL: &str = "SELECT s.session_key,s.origin_host,s.provider,s.thread_id,s.cwd,s.title,s.started_at,s.last_at,s.parent_session_key,src.present FROM session s JOIN source src USING(source_id) WHERE s.origin_host=?1 AND s.thread_id_reversed>=?2 AND s.thread_id_reversed<?3 AND src.present=1 LIMIT 2";

pub(crate) fn match_thread_suffix(
    db: &super::store::Reader,
    host: &str,
    suffix: &str,
) -> Result<Vec<SessionHeader>> {
    ensure!(
        !suffix.is_empty() && suffix.len() <= 512,
        "Thread suffix must be 1..=512 UTF-8 bytes"
    );
    let lower: Vec<_> = suffix.bytes().rev().collect();
    let mut upper = lower.clone();
    let last = upper.last_mut().context("Empty thread suffix")?;
    *last = last
        .checked_add(1)
        .context("Thread suffix has no upper bound")?;
    Ok(db
        .prepare(THREAD_SUFFIX_SQL)?
        .query_map(params![host, lower, upper], session_header)?
        .collect::<rusqlite::Result<_>>()?)
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Search {
    pub query: String,
    pub since: Option<String>,
    pub limit: Option<usize>,
    pub cursor: Option<String>,
    #[serde(default)]
    pub local: bool,
}

pub(crate) fn search(db: &super::store::Reader, request: &Search) -> Result<Value> {
    ensure!(
        request.query.chars().count() >= 3 && request.query.len() <= 4096,
        "search needs 3..=4096 UTF-8 bytes"
    );
    let limit = request.limit.unwrap_or(50);
    ensure!((1..=1000).contains(&limit), "search limit must be 1..=1000");
    let fingerprint =
        blake3::hash(serde_json::to_string(&(&request.query, &request.since))?.as_bytes())
            .to_hex()
            .to_string();
    let after = match &request.cursor {
        None => 0,
        Some(cursor) => {
            let (query, id) = cursor.rsplit_once(':').context("Invalid search cursor")?;
            ensure!(
                query == fingerprint,
                "Search cursor belongs to a different query"
            );
            id.parse::<i64>()?
        }
    };
    let literal = format!("\"{}\"", request.query.replace('"', "\"\""));
    let mut stmt = db.prepare("SELECT i.rowid,i.item_key,i.session_key,s.origin_host,s.thread_id,i.at,i.kind,substr(i.text,max(1,instr(lower(i.text),lower(?4))-100),400),i.text_bytes,src.present FROM item_fts JOIN item i ON i.rowid=item_fts.rowid JOIN session s USING(session_key) JOIN source src USING(source_id) WHERE item_fts MATCH ?1 AND (?2 IS NULL OR julianday(i.at)>=julianday(?2)) AND i.rowid>?3 ORDER BY i.rowid LIMIT ?5")?;
    let mut rows = stmt.query(params![
        literal,
        request.since,
        after,
        request.query,
        limit as i64 + 1
    ])?;
    let mut hits = Vec::new();
    let mut last = after;
    let mut more = false;
    while let Some(row) = rows.next()? {
        if hits.len() == limit {
            more = true;
            break;
        }
        last = row.get(0)?;
        hits.push(json!({"itemKey":row.get::<_,String>(1)?,"sessionKey":row.get::<_,String>(2)?,"hostId":row.get::<_,String>(3)?,"threadId":row.get::<_,String>(4)?,"at":row.get::<_,Option<String>>(5)?,"kind":row.get::<_,String>(6)?,"excerpt":row.get::<_,Option<String>>(7)?,"textBytes":row.get::<_,i64>(8)?,"sourceDeleted":row.get::<_,i64>(9)?==0}));
    }
    Ok(
        json!({"schemaVersion":1,"hits":hits,"cursor":if more {Some(format!("{fingerprint}:{last}"))} else {None},"coverage":coverage(db)?}),
    )
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ReadRequest {
    pub target: String,
    #[serde(default)]
    pub offset: u64,
    pub length: Option<usize>,
    pub dependency: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SourceRef {
    pub path: String,
    pub offset: u64,
    pub length: u64,
    pub hash: String,
    pub pointer: String,
    pub images: Vec<String>,
    pub sidecars: Vec<String>,
}

pub(super) const SESSION_TARGET_SQL: &str = "WITH candidates AS (SELECT session_key FROM session WHERE session_key=?1 UNION SELECT session_key FROM (SELECT session_key FROM session WHERE thread_id=?1 LIMIT 2) UNION SELECT session_key FROM (SELECT session_key FROM session WHERE origin_host=?2 AND thread_id=?3 LIMIT 2) LIMIT 2) SELECT src.local_path,src.present FROM candidates JOIN session s USING(session_key) JOIN source src USING(source_id)";

pub(crate) fn read(db: &super::store::Reader, request: ReadRequest) -> Result<Value> {
    let length = request.length.unwrap_or(64 * 1024);
    ensure!(
        (1..=4 * 1024 * 1024).contains(&length),
        "read length must be 1..=4194304 bytes"
    );
    let item: Option<(String,String,i64)> = db.query_row("SELECT i.source_ref,src.local_path,src.source_id FROM item i JOIN session s USING(session_key) JOIN source src USING(source_id) WHERE item_key=?1",[&request.target],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
    let (bytes, total, reference) = if let Some((reference, path, source)) = item {
        let reference: SourceRef = serde_json::from_str(&reference)?;
        if let Some(dependency) = request.dependency.as_deref() {
            ensure!(
                reference
                    .sidecars
                    .iter()
                    .chain(&reference.images)
                    .any(|p| p == dependency),
                "Dependency is not referenced by this item"
            );
            let (path,identity):(String,Option<String>)=db.query_row("SELECT local_path,identity FROM dependency WHERE source_id=?1 AND path=?2 AND present=1",params![source,dependency],|r|Ok((r.get(0)?,r.get(1)?))).context("source deleted: dependency is unavailable")?;
            let expected = identity
                .as_deref()
                .context("source_changed: dependency revision is unknown")?;
            let (bytes, total) =
                dependency_bytes(File::open(&path)?, expected, request.offset, length)?;
            (bytes, total, Some(reference))
        } else {
            let bytes = item_bytes(
                File::open(&path).context("source deleted: raw transcript is unavailable")?,
                &reference,
                request.offset,
                length,
            )?;
            (bytes, reference.length, Some(reference))
        }
    } else {
        ensure!(
            request.dependency.is_none(),
            "Dependencies require an item key"
        );
        let address = request.target.split_once(':');
        let mut stmt = db.prepare(SESSION_TARGET_SQL)?;
        let matches = stmt
            .query_map(
                params![
                    request.target,
                    address.map(|(host, _)| host),
                    address.map(|(_, thread)| thread)
                ],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)),
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        ensure!(
            !matches.is_empty(),
            "not_found: no session matches the address"
        );
        ensure!(
            matches.len() == 1,
            "usage: ambiguous session address; use its canonical session key"
        );
        ensure!(matches[0].1 == 1, "source deleted");
        let path = matches[0].0.clone();
        let mut file = File::open(&path).context("source deleted")?;
        let total = file.metadata()?.len();
        let bytes = range_bytes(&mut file, total, request.offset, length)?;
        (bytes, total, None)
    };
    let next = request.offset + bytes.len() as u64;
    let mut response = json!({"schemaVersion":1,"target":request.target,"offset":request.offset,"totalBytes":total,"nextOffset":if next<total {Some(next)} else {None},"base64":base64::engine::general_purpose::STANDARD.encode(&bytes),"utf8":std::str::from_utf8(&bytes).ok(),"sourceRef":reference});
    if serde_json::to_vec(&response)?.len() > PAGE_BYTES {
        response
            .as_object_mut()
            .context("Read response")?
            .remove("utf8");
    }
    ensure!(
        serde_json::to_vec(&response)?.len() <= PAGE_BYTES,
        "capacity: read response exceeds 8 MiB"
    );
    Ok(response)
}

fn range_bytes(file: &mut File, total: u64, offset: u64, length: usize) -> Result<Vec<u8>> {
    ensure!(offset <= total, "Read offset exceeds source length");
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = Vec::new();
    file.take((length as u64).min(total - offset))
        .read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn item_bytes(
    mut file: File,
    reference: &SourceRef,
    offset: u64,
    length: usize,
) -> Result<Vec<u8>> {
    ensure!(
        reference.length <= crate::providers::claude::records::MAX_SESSION_RECORD_BYTES as u64,
        "capacity: record exceeds bounded read"
    );
    ensure!(
        offset <= reference.length,
        "Read offset exceeds source length"
    );
    file.seek(SeekFrom::Start(reference.offset))?;
    let mut record = Vec::new();
    file.take(reference.length).read_to_end(&mut record)?;
    ensure!(
        record.len() as u64 == reference.length
            && blake3::hash(&record).to_hex().as_str() == reference.hash,
        "source_changed: exact record no longer matches the projection"
    );
    let start = usize::try_from(offset)?;
    Ok(record[start..record.len().min(start + length)].to_vec())
}

fn dependency_bytes(
    mut file: File,
    expected: &str,
    offset: u64,
    length: usize,
) -> Result<(Vec<u8>, u64)> {
    let before = file.metadata()?;
    ensure!(
        super::ingest::identity(&before) == expected,
        "source_changed: re-ingest before reading dependency"
    );
    let bytes = range_bytes(&mut file, before.len(), offset, length)?;
    ensure!(
        super::ingest::identity(&file.metadata()?) == expected,
        "source_changed: dependency changed during read"
    );
    Ok((bytes, before.len()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sessions_reads_capture_validated_handles_across_path_rotation() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("evidence");
        std::fs::write(&path, b"old record\n").unwrap();
        let item_file = File::open(&path).unwrap();
        let dependency_file = File::open(&path).unwrap();
        std::fs::rename(&path, directory.path().join("retired")).unwrap();
        std::fs::write(&path, b"replacement\n").unwrap();
        let identity = super::super::ingest::identity(&dependency_file.metadata().unwrap());
        let reference = SourceRef {
            path: path.to_string_lossy().into_owned(),
            offset: 0,
            length: 11,
            hash: blake3::hash(b"old record\n").to_hex().to_string(),
            pointer: "".into(),
            images: vec![],
            sidecars: vec![],
        };
        assert_eq!(item_bytes(item_file, &reference, 4, 6).unwrap(), b"record");
        assert_eq!(
            dependency_bytes(dependency_file, &identity, 4, 6)
                .unwrap()
                .0,
            b"record"
        );
    }
}

use rusqlite::OptionalExtension;
