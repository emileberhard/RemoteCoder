use super::{PAGE_ROWS, query};
use anyhow::{Result, ensure};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Request {
    pub cursor: Option<String>,
    pub limit: Option<usize>,
}

pub(crate) fn cursor(db: &Connection) -> Result<String> {
    let (epoch, seq): (String, i64) = db.query_row("SELECT (SELECT value FROM meta WHERE key='epoch'),coalesce((SELECT max(seq) FROM sqlite_sequence WHERE name='change'),0)", [], |r| Ok((r.get(0)?,r.get(1)?)))?;
    Ok(format!("1:{epoch}:{seq}"))
}

pub(super) fn window(db: &Connection, requested: Option<&str>) -> Result<(String, i64, i64)> {
    let head = cursor(db)?;
    let prefix = head.rsplit_once(':').expect("generated change cursor").0;
    let floor: i64 = db
        .query_row("SELECT value FROM meta WHERE key='floor'", [], |r| {
            r.get::<_, String>(0)
        })?
        .parse()?;
    let after = match requested {
        None => 0,
        Some(value) => {
            let (epoch, seq) = value.rsplit_once(':').ok_or_else(|| {
                anyhow::anyhow!("cursor_expired: take a SQL snapshot and use its changeCursor")
            })?;
            ensure!(
                epoch == prefix,
                "cursor_expired: database epoch changed; take a snapshot"
            );
            seq.parse::<i64>()?
        }
    };
    let high: i64 = head.rsplit_once(':').expect("generated cursor").1.parse()?;
    ensure!(
        after >= floor && after <= high,
        "cursor_expired: take a SQL snapshot and use its changeCursor"
    );
    Ok((head, after, high))
}

pub(crate) fn read(db: &super::store::Reader, request: Request) -> Result<Value> {
    let tx = db.unchecked_transaction()?;
    let (head, after, high) = window(&tx, request.cursor.as_deref())?;
    let prefix = head.rsplit_once(':').expect("generated change cursor").0;
    let limit = request.limit.unwrap_or(1000);
    ensure!(
        (1..=PAGE_ROWS).contains(&limit),
        "limit must be 1..={PAGE_ROWS}"
    );
    let mut response = query::rows(
        &tx,
        "SELECT seq,entity,key,op,revision,committed_at FROM change WHERE seq>?1 ORDER BY seq LIMIT ?2",
        params![after, limit as i64],
    )?;
    let rows = response["rows"].as_array().expect("query rows");
    let last = rows.last().and_then(|r| r[0].as_i64()).unwrap_or(after);
    response["cursor"] = json!(format!("{prefix}:{last}"));
    response["hasMore"] = json!(last < high);
    response["schemaVersion"] = json!(1);
    response["coverage"] = query::coverage(db)?;
    Ok(response)
}

pub(super) const PRUNE_SQL: &str = "SELECT coalesce(max(seq),0) FROM change INDEXED BY change_age WHERE committed_at < strftime('%Y-%m-%dT%H:%M:%fZ','now',?1)";

pub(crate) fn prune(db: &Connection) -> Result<()> {
    let tx = db.unchecked_transaction()?;
    let removed: i64 = tx.query_row(PRUNE_SQL, [format!("-{} days", super::CHANGE_DAYS)], |r| {
        r.get(0)
    })?;
    tx.execute("DELETE FROM change WHERE seq<=?1", [removed])?;
    tx.execute(
        "UPDATE meta SET value=CAST(max(CAST(value AS INTEGER),?1) AS TEXT) WHERE key='floor'",
        [removed],
    )?;
    tx.commit()?;
    Ok(())
}
