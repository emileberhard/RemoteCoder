use anyhow::Result;
use rusqlite::{Connection, OptionalExtension, params};
use std::collections::{BTreeSet, HashSet};

const VERSION: &str = "1";

pub(super) fn open(db: &Connection) -> Result<()> {
    let version: Option<String> = db
        .query_row(
            "SELECT value FROM meta WHERE key='search_version'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if version.as_deref() == Some(VERSION) {
        return Ok(());
    }
    let tx = db.unchecked_transaction()?;
    for trigger in [
        "search_item_insert",
        "search_item_delete",
        "search_item_update",
        "search_session_insert",
        "search_session_update",
        "search_session_delete",
        "search_source_update",
    ] {
        tx.execute_batch(&format!("DROP TRIGGER IF EXISTS {trigger}"))?;
    }
    tx.execute_batch("DROP VIEW IF EXISTS search_item_content; DROP TABLE IF EXISTS item_word_fts; DROP TABLE IF EXISTS conversation_fts; DROP TABLE IF EXISTS search_item; DROP TABLE IF EXISTS search_dirty; DROP TABLE IF EXISTS search_member; DROP TABLE IF EXISTS search_document;")?;
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

pub(crate) fn rebuild_one(db: &mut Connection) -> Result<bool> {
    let key: Option<String> = db.query_row("SELECT d.session_key FROM search_dirty d LEFT JOIN session s USING(session_key) ORDER BY s.last_at DESC,d.session_key LIMIT 1", [], |r| r.get(0)).optional()?;
    let Some(key) = key else {
        return Ok(false);
    };
    let tx = db.transaction()?;
    let root = root(&tx, &key)?;
    let descendants: Vec<String> = tx.prepare("WITH RECURSIVE children(key) AS (VALUES(?1) UNION SELECT s.session_key FROM session s JOIN children c ON (s.delegated_parent_known=0 AND s.parent_session_key=c.key) OR (s.delegated_parent_known=1 AND s.delegated_parent_session_key=c.key)) SELECT key FROM children")?.query_map([&root], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
    let mut previous_roots = BTreeSet::new();
    {
        let mut previous = tx.prepare("SELECT root_key FROM search_member WHERE session_key=?1")?;
        for member in &descendants {
            if self::root(&tx, member)? != root {
                continue;
            }
            if let Some(prior) = previous
                .query_row([member], |r| r.get::<_, String>(0))
                .optional()?
                .filter(|prior| prior != &root)
            {
                previous_roots.insert(prior);
            }
            tx.execute("INSERT INTO search_member VALUES(?1,?2) ON CONFLICT(session_key) DO UPDATE SET root_key=excluded.root_key", params![member,root])?;
            tx.execute("DELETE FROM search_dirty WHERE session_key=?1", [member])?;
        }
    }
    for prior in previous_roots {
        rebuild(&tx, &prior)?;
    }
    rebuild(&tx, &root)?;
    tx.execute("DELETE FROM search_member WHERE session_key=?1 AND NOT EXISTS(SELECT 1 FROM session s WHERE s.session_key=search_member.session_key)", [&key])?;
    tx.commit()?;
    Ok(true)
}

fn rebuild(db: &Connection, root: &str) -> Result<()> {
    let header: Option<(Option<String>, Option<String>)> = if self::root(db, root)? != root {
        None
    } else {
        db.query_row("SELECT title,cwd FROM session JOIN source USING(source_id) WHERE session_key=?1 AND present=1", [root], |r| Ok((r.get(0)?,r.get(1)?))).optional()?
    };
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
    let mut typed = String::new();
    let mut other = String::new();
    let mut statement = db.prepare("SELECT i.rowid,i.text,i.kind,'s'||s.source_id, m.id IS NOT NULL FROM search_member sm JOIN session s ON s.session_key=sm.session_key JOIN item i ON i.session_key=s.session_key LEFT JOIN search_item m ON m.id=i.rowid WHERE sm.root_key=?1 ORDER BY i.rowid")?;
    let mut rows = statement.query([root])?;
    while let Some(row) = rows.next()? {
        let id: i64 = row.get(0)?;
        let text: Option<String> = row.get(1)?;
        let kind: String = row.get(2)?;
        let scope: String = row.get(3)?;
        if !row.get::<_, bool>(4)? {
            db.execute("INSERT INTO search_item VALUES(?1,?2)", params![id, scope])?;
            db.execute(
                "INSERT INTO item_word_fts(rowid,text,scope) VALUES(?1,?2,?3)",
                params![id, text, scope],
            )?;
        }
        if let Some(text) = text {
            match kind.as_str() {
                "user" => {
                    typed.push_str(&crate::prompt_summary::prompt_summary(&text));
                    typed.push('\n');
                }
                "assistant" | "reasoning" => {
                    other.push_str(&text);
                    other.push('\n');
                }
                _ => {}
            }
        }
    }
    db.execute(
        "INSERT INTO search_document(session_key) VALUES(?1)",
        [root],
    )?;
    db.execute(
        "INSERT INTO conversation_fts(rowid,title,typed,other,cwd) VALUES(?1,?2,?3,?4,?5)",
        params![db.last_insert_rowid(), title, typed, other, cwd],
    )?;
    Ok(())
}
