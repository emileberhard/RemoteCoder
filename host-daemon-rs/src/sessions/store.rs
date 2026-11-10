use super::SCHEMA_VERSION;
use crate::storage::private_state;
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OpenFlags, limits::Limit};
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};

#[derive(Clone)]
pub(crate) struct Store {
    pub path: PathBuf,
    pub storage: std::sync::Arc<super::storage::Storage>,
    pub(super) worker: std::sync::Arc<std::sync::OnceLock<std::sync::Arc<super::worker::Mailbox>>>,
    anchor: std::sync::Arc<std::sync::Mutex<Connection>>,
}

impl Store {
    pub(crate) fn open(path: PathBuf, capacity: super::storage::Capacity) -> Result<Self> {
        let parent = path
            .parent()
            .context("Session database needs a parent directory")?;
        private_state::ensure_private_directory(parent)?;
        let storage = std::sync::Arc::new(super::storage::Storage::new(&path, capacity)?);
        discard_other_schema(&path, &storage)?;
        let store = Self {
            anchor: std::sync::Arc::new(std::sync::Mutex::new(Connection::open(&path)?)),
            path,
            storage,
            worker: Default::default(),
        };
        let db = store.writer()?;
        db.execute_batch("PRAGMA auto_vacuum=INCREMENTAL; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")?;
        db.execute_batch(include_str!("schema.sql"))?;
        super::index::open(&db)?;
        db.execute_batch(include_str!("views.sql"))?;
        db.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        for (table, identity) in [("source", "file_identity"), ("dependency", "identity")] {
            for (event, row, guard) in [
                ("INSERT", "new", String::new()),
                (
                    "UPDATE",
                    "new",
                    format!(
                        " WHEN old.{identity} IS NOT new.{identity} OR old.present IS NOT new.present"
                    ),
                ),
                ("DELETE", "old", String::new()),
            ] {
                db.execute_batch(&format!("CREATE TRIGGER IF NOT EXISTS feed_{table}_{event} AFTER {event} ON {table}{guard} BEGIN INSERT INTO change(origin_host,evidence_path) VALUES({row}.origin_host,{row}.path); END;"))?;
            }
        }
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&store.path, std::fs::Permissions::from_mode(0o600))?;
        store
            .anchor
            .lock()
            .expect("Session catalog anchor poisoned")
            .query_row("SELECT count(*) FROM sqlite_schema", [], |_| Ok(()))?;
        Ok(store)
    }

    pub fn writer(&self) -> Result<Writer> {
        let lease = self.storage.lease(0)?;
        let db = Connection::open(&self.path)?;
        db.busy_timeout(Duration::from_secs(5))?;
        db.execute_batch("PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA cache_size=-32768; PRAGMA mmap_size=0; PRAGMA temp_store=MEMORY; PRAGMA journal_size_limit=16777216;")?;
        let headroom = self.storage.usage()?.headroom_bytes;
        let page_size: i64 = db.pragma_query_value(None, "page_size", |r| r.get(0))?;
        let page_count: i64 = db.pragma_query_value(None, "page_count", |r| r.get(0))?;
        db.pragma_update(
            None,
            "max_page_count",
            (page_count + i64::try_from(headroom)? / page_size).max(1),
        )?;
        Ok(Writer { db, _lease: lease })
    }

    pub fn reader(&self) -> Result<Reader> {
        Ok(Reader {
            db: reader_connection(&self.path)?,
            storage: self.storage.clone(),
        })
    }
}

fn discard_other_schema(path: &Path, storage: &super::storage::Storage) -> Result<()> {
    if !path.try_exists()? {
        return Ok(());
    }
    let _lease = storage.lease(0)?;
    let version: u32 = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?
        .pragma_query_value(None, "user_version", |r| r.get(0))?;
    if version == SCHEMA_VERSION {
        return Ok(());
    }
    for suffix in ["", "-wal", "-shm"] {
        let mut file = path.as_os_str().to_owned();
        file.push(suffix);
        match std::fs::remove_file(&file) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    tracing::info!(
        version,
        "Session catalog rebuilds for schema {SCHEMA_VERSION}"
    );
    Ok(())
}

pub(crate) fn reader(path: &Path) -> Result<Reader> {
    Ok(Reader {
        db: reader_connection(path)?,
        storage: std::sync::Arc::new(super::storage::Storage::new(
            path,
            super::storage::Capacity::Host,
        )?),
    })
}

pub(crate) struct Reader {
    db: Connection,
    pub storage: std::sync::Arc<super::storage::Storage>,
}

impl Reader {
    pub(crate) fn interrupt_on(&mut self, control: Arc<ReadControl>) -> Result<()> {
        control.install(&self.db)
    }
}

pub(crate) struct ReadControl {
    deadline: Instant,
    cancelled: AtomicBool,
}

impl ReadControl {
    pub(crate) fn new(deadline: Instant) -> Arc<Self> {
        Arc::new(Self {
            deadline,
            cancelled: AtomicBool::new(false),
        })
    }

    pub(super) fn install(self: &Arc<Self>, db: &Connection) -> Result<()> {
        let control = self.clone();
        db.progress_handler(1000, Some(move || control.stopped()))?;
        Ok(())
    }

    pub(crate) fn stopped(&self) -> bool {
        self.cancelled.load(Ordering::Relaxed) || Instant::now() >= self.deadline
    }

    pub(crate) fn cancel_on_drop(self: &Arc<Self>) -> CancelRead {
        CancelRead(self.clone())
    }
}

pub(crate) struct CancelRead(Arc<ReadControl>);

impl Drop for CancelRead {
    fn drop(&mut self) {
        self.0.cancelled.store(true, Ordering::Relaxed);
    }
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
