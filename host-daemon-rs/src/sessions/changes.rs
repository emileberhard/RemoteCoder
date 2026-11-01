use anyhow::{Result, ensure};
use rusqlite::Connection;

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
                anyhow::anyhow!("cursor_expired: the change feed no longer covers this cursor; take a full listing")
            })?;
            ensure!(
                epoch == prefix,
                "cursor_expired: database epoch changed; take a full listing"
            );
            seq.parse::<i64>()?
        }
    };
    let high: i64 = head.rsplit_once(':').expect("generated cursor").1.parse()?;
    ensure!(
        after >= floor && after <= high,
        "cursor_expired: the change feed no longer covers this cursor; take a full listing"
    );
    Ok((head, after, high))
}

pub(crate) fn prune(db: &Connection, keep: i64) -> Result<()> {
    let tx = db.unchecked_transaction()?;
    let removed: i64 = tx.query_row(
        "SELECT coalesce((SELECT seq FROM sqlite_sequence WHERE name='change'),0)-?1",
        [keep],
        |r| r.get(0),
    )?;
    if removed > 0 {
        tx.execute("DELETE FROM change WHERE seq<=?1", [removed])?;
        tx.execute(
            "UPDATE meta SET value=CAST(max(CAST(value AS INTEGER),?1) AS TEXT) WHERE key='floor'",
            [removed],
        )?;
    }
    tx.commit()?;
    Ok(())
}
