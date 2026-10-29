use super::SCHEMA_VERSION;
use crate::storage::private_state;
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OpenFlags, limits::Limit};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

#[derive(Clone)]
pub(crate) struct Store {
    pub path: PathBuf,
    pub storage: std::sync::Arc<super::storage::Storage>,
    pub(super) worker: std::sync::Arc<std::sync::OnceLock<std::sync::Arc<super::worker::Mailbox>>>,
}

impl Store {
    pub fn open(path: PathBuf) -> Result<Self> {
        let parent = path
            .parent()
            .context("Session database needs a parent directory")?;
        private_state::ensure_private_directory(parent)?;
        let storage = std::sync::Arc::new(super::storage::Storage::new(&path)?);
        let store = Self {
            path,
            storage,
            worker: Default::default(),
        };
        let mut db = store.writer()?;
        let version: u32 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version != 0 && version != 4 && version != SCHEMA_VERSION {
            db.pragma_update(None, "foreign_keys", false)?;
            let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let objects:Vec<(String,String)>=tx.prepare("SELECT name,type FROM sqlite_schema WHERE type IN ('trigger','view','table') AND name NOT LIKE 'sqlite_%' ORDER BY CASE type WHEN 'trigger' THEN 0 WHEN 'view' THEN 1 ELSE CASE WHEN sql LIKE 'CREATE VIRTUAL TABLE%' THEN 2 ELSE 3 END END")?.query_map([],|r|Ok((r.get(0)?,r.get(1)?)))?.collect::<rusqlite::Result<_>>()?;
            for (name, kind) in objects {
                tx.execute_batch(&format!(
                    "DROP {kind} IF EXISTS \"{}\"",
                    name.replace('"', "\"\"")
                ))?;
            }
            tx.commit()?;
            db.pragma_update(None, "foreign_keys", true)?;
        }
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA auto_vacuum=INCREMENTAL;")?;
        migrate_change(&mut db)?;
        db.execute_batch(include_str!("schema.sql"))?;
        db.execute_batch(include_str!("views.sql"))?;
        db.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        for (table, key, revision) in [
            ("source", "CAST({r}.source_id AS TEXT)", "{r}.revision"),
            (
                "session",
                "{r}.session_key",
                "coalesce((SELECT seq+1 FROM sqlite_sequence WHERE name='change'),1)",
            ),
            (
                "turn",
                "json_array({r}.session_key,{r}.turn_id)",
                "coalesce((SELECT seq+1 FROM sqlite_sequence WHERE name='change'),1)",
            ),
            ("item", "{r}.item_key", "{r}.revision"),
            (
                "tool_call",
                "{r}.item_key",
                "coalesce((SELECT seq+1 FROM sqlite_sequence WHERE name='change'),1)",
            ),
            (
                "tool_result",
                "{r}.item_key",
                "coalesce((SELECT seq+1 FROM sqlite_sequence WHERE name='change'),1)",
            ),
            (
                "skill_observation",
                "json_array({r}.item_key,{r}.skill,{r}.via)",
                "coalesce((SELECT seq+1 FROM sqlite_sequence WHERE name='change'),1)",
            ),
            (
                "skill",
                "{r}.name",
                "coalesce((SELECT seq+1 FROM sqlite_sequence WHERE name='change'),1)",
            ),
            (
                "dependency",
                "json_array({r}.source_id,{r}.path)",
                "coalesce((SELECT seq+1 FROM sqlite_sequence WHERE name='change'),1)",
            ),
        ] {
            for (event, row, op) in [
                ("INSERT", "new", "upsert"),
                ("UPDATE", "new", "upsert"),
                ("DELETE", "old", "tombstone"),
            ] {
                let (host, path) = if matches!(table, "source" | "dependency") {
                    (format!("{row}.origin_host"), format!("{row}.path"))
                } else {
                    ("NULL".into(), "NULL".into())
                };
                db.execute_batch(&format!("CREATE TRIGGER IF NOT EXISTS feed_{table}_{event} AFTER {event} ON {table} BEGIN INSERT INTO change(entity,key,op,revision,origin_host,evidence_path) VALUES('{table}',{},'{op}',{},{host},{path}); END;", key.replace("{r}",row), revision.replace("{r}",row)))?;
            }
        }
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&store.path, std::fs::Permissions::from_mode(0o600))?;
        Ok(store)
    }

    pub fn writer(&self) -> Result<Writer> {
        let storage = &self.storage;
        let lease = storage.lease(0)?;
        let db = Connection::open(&self.path)?;
        db.busy_timeout(Duration::from_secs(5))?;
        db.execute_batch("PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA cache_size=-32768; PRAGMA mmap_size=0; PRAGMA temp_store=MEMORY; PRAGMA journal_size_limit=16777216;")?;
        let wal = storage.wal_bytes()?;
        let before = storage.usage()?;
        super::storage::admit(before.used_bytes, wal, before.free_bytes)?;
        let (busy, _, _): (i64, i64, i64) =
            db.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })?;
        ensure!(
            busy == 0,
            "unavailable: session snapshot prevents reclaiming its WAL"
        );
        let usage = storage.usage()?;
        let size = self.path.metadata()?.len();
        let page_size: u32 = db.pragma_query_value(None, "page_size", |r| r.get(0))?;
        let page_count: u32 = db.pragma_query_value(None, "page_count", |r| r.get(0))?;
        let limit = page_limit(
            size,
            usage.used_bytes.saturating_sub(size),
            usage.free_bytes,
            u64::from(page_size),
        );
        ensure!(
            u64::from(page_count) <= limit,
            "stale: budget; catalog cannot reserve its database and WAL within the shared cap"
        );
        db.pragma_update(None, "max_page_count", i64::try_from(limit)?)?;
        Ok(Writer { db, _lease: lease })
    }

    pub fn reader(&self) -> Result<Reader> {
        Ok(Reader {
            db: reader_connection(&self.path)?,
            storage: self.storage.clone(),
        })
    }
}

pub(super) fn page_limit(size: u64, other: u64, free: u64, page_size: u64) -> u64 {
    super::storage::CAP_BYTES
        .saturating_sub(other)
        .min(
            free.saturating_sub(super::storage::RESERVE_BYTES)
                .saturating_add(size),
        )
        .saturating_sub(65536)
        .saturating_sub(super::storage::WAL_BYTES)
        / page_size
}

fn migrate_change(db: &mut Connection) -> Result<()> {
    let columns: std::collections::BTreeSet<String> = db
        .prepare("PRAGMA table_info(change)")?
        .query_map([], |row| row.get(1))?
        .collect::<rusqlite::Result<_>>()?;
    if columns.is_empty() || columns.contains("origin_host") && columns.contains("evidence_path") {
        return Ok(());
    }
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    for column in ["origin_host", "evidence_path"] {
        if !columns.contains(column) {
            tx.execute_batch(&format!("ALTER TABLE change ADD COLUMN {column} TEXT"))?;
        }
    }
    for table in ["source", "dependency"] {
        for event in ["INSERT", "UPDATE", "DELETE"] {
            tx.execute_batch(&format!("DROP TRIGGER IF EXISTS feed_{table}_{event}"))?;
        }
    }
    tx.commit()?;
    Ok(())
}

pub(crate) fn reader(path: &Path) -> Result<Reader> {
    Ok(Reader {
        db: reader_connection(path)?,
        storage: std::sync::Arc::new(super::storage::Storage::new(path)?),
    })
}

pub(crate) struct Reader {
    db: Connection,
    pub storage: std::sync::Arc<super::storage::Storage>,
}

impl std::ops::Deref for Reader {
    type Target = Connection;
    fn deref(&self) -> &Connection {
        &self.db
    }
}

fn reader_connection(path: &Path) -> Result<Connection> {
    let mut db = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    db.busy_timeout(Duration::from_millis(250))?;
    let version: u32 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
    ensure!(
        version == SCHEMA_VERSION,
        "Unsupported sessions schema {version}"
    );
    db.execute_batch("PRAGMA query_only=ON; PRAGMA cache_size=-8192; PRAGMA mmap_size=0; PRAGMA trusted_schema=OFF; PRAGMA temp_store=MEMORY;")?;
    db.set_limit(Limit::SQLITE_LIMIT_ATTACHED, 0)?;
    db.set_limit(Limit::SQLITE_LIMIT_LENGTH, 64 << 20)?;
    db.set_limit(Limit::SQLITE_LIMIT_SQL_LENGTH, 64 * 1024)?;
    db.set_limit(Limit::SQLITE_LIMIT_WORKER_THREADS, 0)?;
    let started = Instant::now();
    db.progress_handler(
        1000,
        Some(move || started.elapsed() >= Duration::from_secs(5)),
    )?;
    db.authorizer(Some(|context: rusqlite::hooks::AuthContext<'_>| {
        use rusqlite::hooks::{AuthAction, Authorization};
        match context.action {
            AuthAction::Attach { .. } | AuthAction::Detach { .. } => Authorization::Deny,
            AuthAction::Pragma {
                pragma_name,
                pragma_value: Some(_),
            } if ![
                "table_info",
                "table_xinfo",
                "index_info",
                "index_xinfo",
                "index_list",
                "foreign_key_list",
            ]
            .contains(&pragma_name) =>
            {
                Authorization::Deny
            }
            _ => Authorization::Allow,
        }
    }))?;
    Ok(db)
}

pub(crate) struct Writer {
    db: Connection,
    _lease: super::storage::Lease,
}

impl std::ops::Deref for Writer {
    type Target = Connection;
    fn deref(&self) -> &Connection {
        &self.db
    }
}

impl std::ops::DerefMut for Writer {
    fn deref_mut(&mut self) -> &mut Connection {
        &mut self.db
    }
}
