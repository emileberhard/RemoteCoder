use anyhow::Result;
use rusqlite::{Connection, OptionalExtension, params};
use std::collections::{BTreeSet, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const VERSION: &str = "3";
const OTHER_BYTES: i64 = 512 << 10;
const OTHER_ROWS: usize = 4096;
const MEMBER_LIMIT: usize = 128;
const IMMEDIATE_REFRESH_MS: i64 = 10;
const COOLDOWN_MULTIPLIER: i64 = 9;

pub(super) fn ready(db: &Connection) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM meta WHERE key='search_version' AND value=?1)",
        [VERSION],
        |r| r.get(0),
    )?)
}

pub(super) fn open(db: &Connection) -> Result<()> {
    if ready(db)? {
        return Ok(());
    }
    let tx = db.unchecked_transaction()?;
    for trigger in [
        "search_item_insert",
        "search_item_delete",
        "search_item_update",
        "search_item_update_before",
        "search_item_update_after",
        "search_session_insert",
        "search_session_update",
        "search_session_delete",
        "search_source_update",
    ] {
        tx.execute_batch(&format!("DROP TRIGGER IF EXISTS {trigger}"))?;
    }
    tx.execute_batch("DROP VIEW IF EXISTS search_item_content; DROP VIEW IF EXISTS searchable_item; DROP VIEW IF EXISTS search_ancestry; DROP TABLE IF EXISTS item_word_fts; DROP TABLE IF EXISTS conversation_fts; DROP TABLE IF EXISTS search_item; DROP TABLE IF EXISTS search_dirty; DROP TABLE IF EXISTS search_member; DROP TABLE IF EXISTS search_document;")?;
    tx.execute_batch(include_str!("search_schema.sql"))?;
    tx.execute(
        "INSERT OR REPLACE INTO meta VALUES('search_version',?1)",
        [VERSION],
    )?;
    tx.commit()?;
    Ok(())
}

pub(crate) fn root(db: &Connection, key: &str) -> Result<String> {
    let mut current = key.to_owned();
    let mut nearest_present = current.clone();
    let mut visited = HashSet::new();
    for _ in 0..16 {
        if !visited.insert(current.clone()) {
            return Ok(key.to_owned());
        }
        let parent: Option<Option<String>> = db.query_row("SELECT CASE WHEN delegated_parent_known THEN delegated_parent_session_key ELSE parent_session_key END FROM session s JOIN source src USING(source_id) WHERE session_key=?1 AND src.present=1", [&current], |r| r.get(0)).optional()?;
        match parent {
            None => return Ok(nearest_present),
            Some(None) => return Ok(current),
            Some(Some(parent)) => nearest_present = std::mem::replace(&mut current, parent),
        }
    }
    Ok(key.to_owned())
}

const DIRTY: &str = " FROM search_dirty pending LEFT JOIN session s USING(session_key)
 LEFT JOIN search_member m USING(session_key) LEFT JOIN search_document d ON d.session_key=m.root_key";

pub(super) fn drain(
    db: &mut Connection,
    stop: &AtomicBool,
    between: &mut impl FnMut(&mut Connection) -> Result<()>,
) -> Result<Option<Instant>> {
    while !stop.load(Ordering::Acquire) && rebuild_ready(db)? {
        between(db)?;
    }
    let ready_ms: Option<i64> = db.query_row(
        &format!("SELECT min(coalesce(d.refreshed_ms+d.cooldown_ms,0)){DIRTY}"),
        [],
        |r| r.get(0),
    )?;
    Ok(ready_ms.map(|ready_ms| {
        Instant::now() + Duration::from_millis(ready_ms.saturating_sub(clock_ms()).max(0) as u64)
    }))
}

pub(super) fn rebuild_ready(db: &mut Connection) -> Result<bool> {
    rebuild(db, Some(clock_ms()))
}

#[cfg(test)]
pub(crate) fn rebuild_one(db: &mut Connection) -> Result<bool> {
    rebuild(db, None)
}

fn clock_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

fn rebuild(db: &mut Connection, now_ms: Option<i64>) -> Result<bool> {
    let dirty: Option<(String, bool, Option<String>)> = db
        .query_row(
            &format!(
                "SELECT pending.session_key,pending.relink,m.root_key{DIRTY}
        WHERE pending.relink OR ?1 IS NULL OR d.refreshed_ms IS NULL
           OR d.refreshed_ms>?1 OR d.refreshed_ms+d.cooldown_ms<=?1
        ORDER BY s.last_at DESC,pending.session_key LIMIT 1"
            ),
            [now_ms],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    let Some((key, relink, prior)) = dirty else {
        return Ok(false);
    };
    let tx = db.transaction()?;
    if let Some(root) = prior.filter(|_| !relink) {
        rebuild_document(&tx, &root)?;
        tx.execute("DELETE FROM search_dirty WHERE relink=0 AND session_key IN (SELECT session_key FROM search_member WHERE root_key=?1)", [&root])?;
    } else {
        refold(&tx, &key)?;
    }
    tx.commit()?;
    Ok(true)
}

fn refold(db: &Connection, key: &str) -> Result<()> {
    let root = root(db, key)?;
    let descendants: Vec<String> = db
        .prepare(
            "WITH RECURSIVE children(key) AS (VALUES(?1)
        UNION SELECT a.session_key FROM children c JOIN search_ancestry a ON a.parent=c.key)
        SELECT key FROM children",
        )?
        .query_map([&root], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    let mut previous_roots = BTreeSet::new();
    let mut previous = db.prepare("SELECT root_key FROM search_member WHERE session_key=?1")?;
    let mut backfill = db.prepare("SELECT backfill FROM search_dirty WHERE session_key=?1")?;
    for member in &descendants {
        if member != &root && self::root(db, member)? != root {
            continue;
        }
        if let Some(prior) = previous
            .query_row([member], |r| r.get::<_, String>(0))
            .optional()?
            .filter(|prior| prior != &root)
        {
            previous_roots.insert(prior);
        }
        if backfill
            .query_row([member], |r| r.get::<_, bool>(0))
            .optional()?
            == Some(true)
        {
            backfill_member(db, member)?;
        }
        db.execute("INSERT INTO search_member VALUES(?1,?2) ON CONFLICT(session_key) DO UPDATE SET root_key=excluded.root_key", params![member,root])?;
        db.execute("DELETE FROM search_dirty WHERE session_key=?1", [member])?;
    }
    for prior in previous_roots {
        rebuild_document(db, &prior)?;
    }
    rebuild_document(db, &root)?;
    db.execute("DELETE FROM search_member WHERE session_key=?1 AND NOT EXISTS(SELECT 1 FROM session s WHERE s.session_key=search_member.session_key)", [key])?;
    Ok(())
}

fn backfill_member(db: &Connection, member: &str) -> Result<()> {
    let unindexed = " FROM searchable_item i WHERE i.session_key=?1 AND NOT EXISTS(SELECT 1 FROM search_item m WHERE m.id=i.rowid)";
    db.execute(
        &format!(
            "INSERT INTO item_word_fts(rowid,text,scope) SELECT i.rowid,i.text,i.scope{unindexed}"
        ),
        [member],
    )?;
    db.execute(&format!("INSERT INTO search_item SELECT i.rowid,i.scope,i.document_column,i.text_bytes{unindexed}"), [member])?;
    Ok(())
}

fn rebuild_document(db: &Connection, root: &str) -> Result<()> {
    let started = Instant::now();
    let header: Option<(Option<String>, Option<String>)> = db
        .query_row(
            "SELECT s.title,s.cwd FROM session s JOIN source USING(source_id)
         JOIN search_member m ON m.session_key=s.session_key AND m.root_key=s.session_key
         WHERE s.session_key=?1 AND source.present=1",
            [root],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if let Some(id) = db
        .query_row(
            "SELECT id FROM search_document WHERE session_key=?1",
            [root],
            |r| r.get::<_, i64>(0),
        )
        .optional()?
    {
        db.execute("DELETE FROM conversation_fts WHERE rowid=?1", [id])?;
        db.execute("DELETE FROM search_document WHERE id=?1", [id])?;
    }
    let Some((title, cwd)) = header else {
        return Ok(());
    };
    let typed = typed_text(db, root)?;
    let (other, capped) = other_text(db, root)?;
    db.execute("INSERT INTO search_document(session_key,refreshed_ms,cooldown_ms,capped) VALUES(?1,0,0,?2)", params![root,capped])?;
    let id = db.last_insert_rowid();
    db.execute(
        "INSERT INTO conversation_fts(rowid,title,typed,other,cwd) VALUES(?1,?2,?3,?4,?5)",
        params![id, title, typed, other, cwd],
    )?;
    let duration_ms = started.elapsed().as_millis() as i64;
    let cooldown_ms = if duration_ms > IMMEDIATE_REFRESH_MS {
        duration_ms * COOLDOWN_MULTIPLIER
    } else {
        0
    };
    db.execute(
        "UPDATE search_document SET refreshed_ms=?2,cooldown_ms=?3 WHERE id=?1",
        params![id, clock_ms(), cooldown_ms],
    )?;
    Ok(())
}

fn typed_text(db: &Connection, root: &str) -> Result<String> {
    let mut text = String::new();
    let mut statement = db.prepare(
        "SELECT i.text FROM search_member m
        JOIN session s USING(session_key) JOIN source src USING(source_id)
        JOIN search_item w ON w.scope='s'||s.source_id AND w.document_column='typed'
        JOIN item i ON i.rowid=w.id WHERE m.root_key=?1 AND src.present=1 ORDER BY w.id",
    )?;
    let mut rows = statement.query([root])?;
    while let Some(row) = rows.next()? {
        let value: String = row.get(0)?;
        text.push_str(&crate::prompt_summary::prompt_summary(&value));
        text.push('\n');
    }
    Ok(text)
}

pub(super) fn member_scopes(db: &Connection, root: &str) -> Result<(Vec<String>, bool)> {
    let mut members: Vec<String> = db
        .prepare(
            "SELECT 's'||s.source_id FROM search_member m
        JOIN session s USING(session_key) JOIN source src USING(source_id)
        WHERE m.root_key=?1 AND src.present=1
        ORDER BY s.last_at DESC,s.session_key LIMIT ?2",
        )?
        .query_map(params![root, MEMBER_LIMIT as i64 + 1], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    let capped = members.len() > MEMBER_LIMIT;
    members.truncate(MEMBER_LIMIT);
    Ok((members, capped))
}

fn other_text(db: &Connection, root: &str) -> Result<(String, bool)> {
    let (members, mut capped) = member_scopes(db, root)?;
    if members.is_empty() {
        return Ok((String::new(), capped));
    }
    let seeks = vec![
        "SELECT id,text_bytes FROM search_item WHERE scope=? AND document_column='other'";
        members.len()
    ];
    let sql = format!(
        "{} ORDER BY id DESC LIMIT {}",
        seeks.join(" UNION ALL "),
        OTHER_ROWS + 1
    );
    let mut metadata = db.prepare(&sql)?;
    let mut rows = metadata.query(rusqlite::params_from_iter(members))?;
    let mut get_text = db.prepare("SELECT text FROM item WHERE rowid=?1")?;
    let mut text = String::new();
    let mut remaining = OTHER_BYTES;
    for count in 0..=OTHER_ROWS {
        let Some(row) = rows.next()? else {
            break;
        };
        let size: i64 = row.get(1)?;
        if count == OTHER_ROWS {
            capped = true;
            break;
        }
        if size >= OTHER_BYTES {
            capped = true;
            continue;
        }
        if size >= remaining {
            capped = true;
            break;
        }
        let id: i64 = row.get(0)?;
        let value: String = get_text.query_row([id], |r| r.get(0))?;
        text.push_str(&value);
        text.push('\n');
        remaining -= size + 1;
    }
    Ok((text, capped))
}

pub(super) fn capped_roots(db: &Connection) -> Result<Option<i64>> {
    if !ready(db)? {
        return Ok(None);
    }
    Ok(Some(db.query_row(
        "SELECT count(*) FROM search_document WHERE capped=1",
        [],
        |r| r.get(0),
    )?))
}
