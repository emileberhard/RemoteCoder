use super::{Origin, changes, ingest, store::Store};
use anyhow::{Context, Result, ensure};
use base64::Engine;
use futures_util::future::BoxFuture;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

const CHUNK: usize = 1 << 20;

pub(crate) fn role(database: &Path) -> Result<bool> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Role {
        enabled: bool,
    }
    let path = database
        .parent()
        .and_then(Path::parent)
        .context("Session mirror role has no owner")?
        .join("mirror-role.json");
    let bytes = crate::storage::private_state::read_bounded(&path, 1024).map_err(|error| {
        anyhow::anyhow!("unavailable: cannot read session mirror role: {error:?}")
    })?;
    bytes
        .map(|bytes| {
            serde_json::from_slice::<Role>(&bytes)
                .map(|role| role.enabled)
                .context("Invalid session mirror role")
        })
        .transpose()
        .map(|role| role.unwrap_or(false))
}

pub(crate) fn mark_initial_rebuild(store: &Store) -> Result<()> {
    if role(&store.path)? {
        store.writer()?.execute(
            "INSERT OR IGNORE INTO meta SELECT 'mirror_rebuilding','1' WHERE NOT EXISTS(SELECT 1 FROM mirror_state)",
            [],
        )?;
    } else {
        finish_initial_rebuild(store)?;
    }
    Ok(())
}

pub(crate) fn finish_initial_rebuild(store: &Store) -> Result<()> {
    let rebuilding: bool = store.reader()?.query_row(
        "SELECT EXISTS(SELECT 1 FROM meta WHERE key='mirror_rebuilding')",
        [],
        |r| r.get(0),
    )?;
    if rebuilding {
        store
            .writer()?
            .execute("DELETE FROM meta WHERE key='mirror_rebuilding'", [])?;
    }
    Ok(())
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Entry {
    pub origin_host: String,
    pub provider: String,
    pub provider_home: PathBuf,
    pub path: PathBuf,
    pub identity: String,
    pub revision: String,
    pub size: u64,
    pub present: bool,
    pub dependency: bool,
}

pub(super) const LIST_SQL: &str = r#"WITH RECURSIVE paths(path) AS (
 SELECT ?2
 UNION ALL
 SELECT (SELECT min(candidate) FROM (
  SELECT (SELECT min(path) FROM source WHERE origin_host=?1 AND path>paths.path) AS candidate
  UNION ALL
  SELECT (SELECT min(path) FROM dependency WHERE origin_host=?1 AND path>paths.path)
 )) FROM paths WHERE path IS NOT NULL LIMIT 502
)
SELECT s.provider,s.provider_home,p.path,
 CASE WHEN s.path=p.path THEN s.local_path ELSE d.local_path END,
 CASE WHEN s.path=p.path THEN s.present ELSE d.present END,
 s.path<>p.path
FROM paths p JOIN source s ON s.source_id=coalesce(
 (SELECT source_id FROM source WHERE origin_host=?1 AND path=p.path),
 (SELECT source_id FROM dependency WHERE origin_host=?1 AND path=p.path ORDER BY source_id LIMIT 1))
LEFT JOIN dependency d ON d.origin_host=?1 AND d.path=p.path AND d.source_id=s.source_id
WHERE p.path>?2 ORDER BY p.path LIMIT 501"#;

pub(crate) fn list(store: &Store, host: &str, after: Option<String>) -> Result<Value> {
    let db = store.reader()?;
    let change_cursor = changes::cursor(&db)?;
    let (through, complete, roots): (Option<String>, bool, String) = db.query_row("SELECT indexed_through,stale_reason IS NULL AND complete_through IS NOT NULL,provider_roots FROM coverage WHERE origin_host=?1",[host],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?;
    let roots: Vec<PathBuf> = serde_json::from_str(&roots)?;
    ensure!(
        !roots.is_empty() && roots.iter().all(|root| root.is_dir()),
        "unavailable: provider roots are unavailable; mirror presence is unknown"
    );
    let mut statement = db.prepare(LIST_SQL)?;
    let rows = statement
        .query_map(params![host, after.as_deref().unwrap_or("")], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, bool>(4)?,
                r.get::<_, bool>(5)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let more = rows.len() > 500;
    let mut page = Vec::new();
    for (provider, home, path, local, present, dependency) in rows.into_iter().take(500) {
        page.push(describe(
            host, provider, home, path, local, present, dependency,
        )?);
    }
    let next = if more {
        page.last()
            .map(|entry| entry.path.to_string_lossy().into_owned())
    } else {
        None
    };
    ensure!(
        roots.iter().all(|root| root.is_dir()),
        "unavailable: provider roots are unavailable; mirror presence is unknown"
    );
    Ok(
        json!({"schemaVersion":1,"sessionMetadata":super::metadata::page(&db,host,&page)?,"files":page,"cursor":next,"through":through,"complete":complete,"changeCursor":change_cursor,"coverage":super::query::coverage(&db)?}),
    )
}

fn describe(
    host: &str,
    provider: String,
    home: String,
    path: String,
    local: String,
    present: bool,
    dependency: bool,
) -> Result<Entry> {
    let root = Path::new(&home).join(if provider == "codex" {
        "sessions"
    } else {
        "projects"
    });
    ensure!(
        root.is_dir(),
        "unavailable: provider root is unavailable; mirror presence is unknown"
    );
    let metadata = match std::fs::metadata(&local) {
        Ok(m) => Some(m),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            ensure!(
                root.is_dir(),
                "unavailable: provider root is unavailable; mirror presence is unknown"
            );
            None
        }
        Err(e) => return Err(e.into()),
    };
    Ok(Entry {
        origin_host: host.into(),
        provider,
        provider_home: home.into(),
        path: path.into(),
        identity: metadata.as_ref().map(ingest::identity).unwrap_or_default(),
        revision: metadata.as_ref().map(ingest::identity).unwrap_or_default(),
        size: metadata.as_ref().map_or(0, |m| m.len()),
        present: present && metadata.is_some(),
        dependency,
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DeltaRequest {
    pub cursor: String,
}

pub(super) const DELTA_SQL: &str = "SELECT seq,evidence_path FROM change INDEXED BY change_evidence WHERE origin_host=?1 AND evidence_path IS NOT NULL AND seq>?2 ORDER BY seq LIMIT 501";

pub(crate) fn delta(
    store: &Store,
    host: &str,
    origins: &[Origin],
    request: DeltaRequest,
) -> Result<Value> {
    let db = store.reader()?;
    let tx = db.unchecked_transaction()?;
    let (head, after, _) = changes::window(&tx, Some(&request.cursor))?;
    let events: Vec<(i64, String)> = tx
        .prepare(DELTA_SQL)?
        .query_map(params![host, after], |row| Ok((row.get(0)?, row.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    let more = events.len() > 500;
    let mut last = after;
    let mut paths = std::collections::BTreeSet::new();
    for (seq, path) in events.into_iter().take(500) {
        last = seq;
        paths.insert(path);
    }
    if !paths.is_empty() {
        ensure!(
            origins.iter().all(|origin| origin.path().is_dir()),
            "unavailable: provider roots are unavailable; mirror presence is unknown"
        );
    }
    let mut files = Vec::new();
    for path in paths {
        let known: Option<(String,String,String,bool,bool)> = tx.query_row("SELECT provider,provider_home,local_path,present,0 FROM source WHERE origin_host=?1 AND path=?2 UNION ALL SELECT s.provider,s.provider_home,d.local_path,d.present,1 FROM dependency d JOIN source s USING(source_id) WHERE d.origin_host=?1 AND d.path=?2 LIMIT 1",params![host,path],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional()?;
        let (provider, home, local, present, dependency) = match known {
            Some(known) => known,
            None => {
                let origin = origins.iter().find(|origin| {
                    origin.host == host && Path::new(&path).starts_with(&origin.provider_home)
                });
                let Some(origin) = origin else {
                    continue;
                };
                let local = origin.local(Path::new(&path))?;
                (
                    origin.provider.clone(),
                    origin.provider_home.to_string_lossy().into_owned(),
                    local.to_string_lossy().into_owned(),
                    true,
                    !origin.is_transcript(&local),
                )
            }
        };
        files.push(describe(
            host, provider, home, path, local, present, dependency,
        )?);
    }
    if !files.is_empty() {
        ensure!(
            origins.iter().all(|origin| origin.path().is_dir()),
            "unavailable: provider roots are unavailable; mirror presence is unknown"
        );
    }
    let cursor = if more {
        format!(
            "{}:{last}",
            head.rsplit_once(':')
                .context("Generated change cursor missing sequence")?
                .0
        )
    } else {
        head
    };
    let (through,complete):(Option<String>,bool)=tx.query_row("SELECT indexed_through,stale_reason IS NULL AND complete_through IS NOT NULL FROM coverage WHERE origin_host=?1",[host],|r|Ok((r.get(0)?,r.get(1)?)))?;
    Ok(
        json!({"sessionMetadata":super::metadata::page(&tx,host,&files)?,"files":files,"cursor":cursor,"hasMore":more,"through":through,"complete":complete}),
    )
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Fetch {
    pub path: String,
    pub identity: String,
    pub revision: String,
    pub offset: u64,
    pub length: usize,
    pub prefix_hash: Option<String>,
}

pub(crate) fn fetch(store: &Store, host: &str, request: Fetch) -> Result<Value> {
    ensure!(
        (1..=CHUNK).contains(&request.length),
        "mirror fetch length exceeds 1 MiB"
    );
    let db = store.reader()?;
    let local:String=db.query_row("SELECT local_path FROM source WHERE origin_host=?1 AND path=?2 UNION SELECT d.local_path FROM dependency d JOIN source s USING(source_id) WHERE s.origin_host=?1 AND d.path=?2 LIMIT 1",params![host,request.path],|r|r.get(0)).context("not_found: path is not session evidence owned by this host")?;
    let mut file = File::open(local)?;
    let before = file.metadata()?;
    let identity = ingest::identity(&before);
    ensure!(
        identity == request.identity && identity == request.revision,
        "conflict: source revision changed; relist and restart this file"
    );
    ensure!(
        request.offset <= before.len(),
        "mirror offset exceeds source size"
    );
    if let Some(expected) = request.prefix_hash {
        let mut hash = blake3::Hasher::new();
        std::io::copy(&mut (&file).take(request.offset), &mut hash)?;
        ensure!(
            hash.finalize().to_hex().as_str() == expected,
            "conflict: source prefix was rewritten"
        );
    }
    file.seek(SeekFrom::Start(request.offset))?;
    let mut bytes = Vec::new();
    (&mut file)
        .take(request.length as u64)
        .read_to_end(&mut bytes)?;
    ensure!(
        ingest::identity(&file.metadata()?) == request.revision,
        "conflict: source changed during fetch"
    );
    Ok(
        json!({"base64":base64::engine::general_purpose::STANDARD.encode(&bytes),"nextOffset":request.offset+bytes.len() as u64,"revision":request.revision}),
    )
}

pub(crate) type Call =
    std::sync::Arc<dyn Fn(&'static str, Value) -> BoxFuture<'static, Result<Value>> + Send + Sync>;

fn mirror_origin(root: &Path, host: &str, provider: String, provider_home: PathBuf) -> Origin {
    let scope = blake3::hash(provider_home.as_os_str().as_encoded_bytes())
        .to_hex()
        .to_string();
    Origin {
        host: host.into(),
        provider: provider.clone(),
        provider_home,
        local_home: root
            .join(blake3::hash(host.as_bytes()).to_hex().as_str())
            .join(provider)
            .join(&scope[..16]),
    }
}

#[derive(Default)]
pub(crate) struct Failures(std::sync::Mutex<BTreeMap<(String, PathBuf), String>>);

impl Failures {
    fn observe(&self, host: &str, path: &Path, error: Option<&anyhow::Error>) {
        let mut failures = self.0.lock().expect("Mirror failure observations poisoned");
        let key = (host.to_owned(), path.to_owned());
        match error {
            Some(error) => {
                let message = format!("{error:#}");
                if failures.get(&key) != Some(&message) {
                    tracing::warn!(host,path=%path.display(),error=%message,"Session mirror entry skipped");
                    if failures.len() < 100_000 || failures.contains_key(&key) {
                        failures.insert(key, message);
                    }
                }
            }
            None => {
                if failures.remove(&key).is_some() {
                    tracing::info!(host,path=%path.display(),"Session mirror entry recovered");
                }
            }
        }
    }
}

pub(super) struct Projection {
    host: String,
    origins: Vec<Origin>,
    changes: Option<Vec<PathBuf>>,
    metadata: Vec<super::metadata::SessionMetadata>,
}

impl Projection {
    pub(super) fn apply(
        self,
        store: &Store,
        stop: &std::sync::atomic::AtomicBool,
        inventory_waiting: &dyn Fn() -> bool,
        between: &mut impl FnMut(&mut rusqlite::Connection) -> Result<()>,
    ) -> Result<bool> {
        let scope = self
            .changes
            .as_deref()
            .map_or(ingest::Scope::Full, ingest::Scope::Changed);
        let outcome = ingest::scan_serving(
            store,
            &self.origins,
            scope,
            stop,
            inventory_waiting,
            between,
        )?;
        ensure!(
            !stop.load(std::sync::atomic::Ordering::Acquire),
            "Session mirror projection stopped"
        );
        let mut db = store.writer()?;
        let partial:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM coverage WHERE origin_host=?1 AND stale_reason IS NOT NULL)",[&self.host],|r|r.get(0))?;
        let tx = db.transaction()?;
        super::metadata::apply(&tx, &self.host, &self.metadata)?;
        tx.commit()?;
        between(&mut db)?;
        super::index::drain(&mut db, stop, between)?;
        Ok(outcome["parseFailures"] == 0 && !partial)
    }
}

pub(crate) async fn sync(
    store: &Store,
    host: &str,
    call: Call,
    stop: tokio_util::sync::CancellationToken,
    failures: std::sync::Arc<Failures>,
) -> Result<Value> {
    let store = store.clone();
    let host = host.to_owned();
    tokio::task::spawn_blocking(move || {
        let runtime = tokio::runtime::Handle::current();
        runtime.block_on(sync_owned(&store, &host, call, stop, failures))
    })
    .await?
}

async fn sync_owned(
    store: &Store,
    host: &str,
    call: Call,
    stop: tokio_util::sync::CancellationToken,
    failures: std::sync::Arc<Failures>,
) -> Result<Value> {
    let root = store.path.parent().context("Mirror root")?.join("mirror");
    if !root.is_dir() {
        crate::storage::private_state::ensure_private_directory(&root)?;
    }
    use std::os::unix::fs::OpenOptionsExt;
    let lock = crate::storage::lock_file::open(&root.join(".lock"))?;
    let _mirror_lease = super::storage::Lease::acquire(lock)
        .context("Mirror is already owned by another worker")?;
    let saved: Option<(String, i64, bool)> = store
        .reader()?
        .query_row(
            "SELECT cursor,reconciled_at,projected_complete FROM mirror_state WHERE origin_host=?1",
            [host],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    let now = ::time::OffsetDateTime::now_utc().unix_timestamp();
    let mut full = saved
        .as_ref()
        .is_none_or(|(_, at, _)| now.saturating_sub(*at) >= 600);
    let mut cursor = if full {
        None
    } else {
        saved.as_ref().map(|(cursor, _, _)| cursor.clone())
    };
    let mut snapshot_cursor = None;
    let mut metadata = BTreeMap::new();
    let mut changed = std::collections::BTreeSet::new();
    let storage = &store.storage;
    let mut origins = BTreeMap::new();
    let mut retained = std::collections::BTreeSet::new();
    let mut complete = true;
    let mut total_files = 0;
    let mut through: Option<String> = None;
    loop {
        if full && snapshot_cursor.is_none() {
            let known: Vec<(String, String)> = store
        .reader()?
        .prepare("SELECT DISTINCT provider,provider_home FROM source WHERE origin_host=?1 LIMIT 1025")?
        .query_map([host], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
            ensure!(
                known.len() <= 1024,
                "capacity: mirror origin inventory exceeds 1024 provider homes"
            );
            for (provider, home) in known {
                let origin = mirror_origin(&root, host, provider, PathBuf::from(home));
                origins.insert(
                    (origin.provider.clone(), origin.provider_home.clone()),
                    origin,
                );
            }
        }
        let page = if full {
            call("sessions/mirror/list", json!({"cursor":cursor})).await?
        } else {
            match call("sessions/mirror/changes", json!({"cursor":cursor})).await {
                Ok(page) => page,
                Err(error) if format!("{error:#}").contains("cursor_expired:") => {
                    full = true;
                    cursor = None;
                    continue;
                }
                Err(error) => return Err(error),
            }
        };
        if full && snapshot_cursor.is_none() {
            snapshot_cursor = Some(
                page["changeCursor"]
                    .as_str()
                    .context("unsupported: mirror listing has no change cursor")?
                    .to_owned(),
            );
        }
        complete &= page["complete"] == true;
        if let Some(boundary) = page["through"].as_str() {
            if through
                .as_deref()
                .is_none_or(|previous| boundary < previous)
            {
                through = Some(boundary.to_owned());
            }
        } else {
            complete = false;
        }
        if let Some(values) = page.get("sessionMetadata") {
            let values: Vec<super::metadata::SessionMetadata> =
                serde_json::from_value(values.clone())?;
            ensure!(
                metadata.len() + values.len() <= 100_000,
                "capacity: mirror metadata exceeds 100000 sessions"
            );
            for value in values {
                metadata.insert(value.session_key.clone(), value);
            }
        }
        let entries: Vec<Entry> = serde_json::from_value(page["files"].clone())?;
        for entry in entries {
            ensure!(!stop.is_cancelled(), "Mirror stopped");
            ensure!(
                entry.origin_host == host,
                "Mirror origin does not match the authenticated member"
            );
            let result:Result<()> = async {
            let origin = mirror_origin(
                &root,
                host,
                entry.provider.clone(),
                entry.provider_home.clone(),
            );
            let target = origin.local(&entry.path)?;
            ensure!(
                origins.len() < 1024
                    || origins
                        .contains_key(&(origin.provider.clone(), origin.provider_home.clone())),
                "capacity: mirror exceeds 1024 provider homes"
            );
            origins.insert(
                (origin.provider.clone(), origin.provider_home.clone()),
                origin,
            );
            if full && entry.present {
                ensure!(
                    retained.len() < 100_000,
                    "capacity: mirror manifest exceeds 100000 files"
                );
                retained.insert(target.clone());
            }
            if !entry.present {
                ensure!(
                    changed.len() < 100_000 || changed.contains(&target),
                    "capacity: mirror batch exceeds 100000 changed paths"
                );
                changed.insert(target.clone());
                if target.is_file() {
                    storage.mutate(&[&target], 0, || Ok(std::fs::remove_file(&target)?))?;
                }
                store.writer()?.execute(
                    "DELETE FROM mirror_file WHERE origin_host=?1 AND path=?2",
                    params![host, entry.path.to_string_lossy()],
                )?;
                return Ok(());
            }
            let temporary = target.with_extension(format!(
                "{}.partial",
                target
                    .extension()
                    .and_then(|v| v.to_str())
                    .unwrap_or("file")
            ));
            crate::storage::private_state::ensure_private_directory(
                target.parent().context("Mirror target parent")?,
            )?;
            let cached: Option<String> = store
                .reader()?
                .query_row(
                    "SELECT identity FROM mirror_file WHERE origin_host=?1 AND path=?2",
                    params![host, entry.path.to_string_lossy()],
                    |r| r.get(0),
                )
                .optional()?;
            if cached.as_deref() == Some(&entry.revision) && target.exists() {
                total_files += 1;
                return Ok(());
            }
            if temporary.exists() {
                storage.mutate(&[&temporary], 0, || Ok(std::fs::remove_file(&temporary)?))?;
            }
            let existing = if target.exists() {
                target.metadata()?.len()
            } else {
                0
            };
            let mut offset = if existing <= entry.size { existing } else { 0 };
            let mut prefix = None;
            if offset > 0 {
                let mut hash = blake3::Hasher::new();
                std::io::copy(&mut File::open(&target)?, &mut hash)?;
                prefix = Some(hash.finalize().to_hex().to_string());
            }
            let first = Fetch {
                path: entry.path.to_string_lossy().into_owned(),
                identity: entry.identity.clone(),
                revision: entry.revision.clone(),
                offset,
                length: CHUNK,
                prefix_hash: prefix,
            };
            let mut response = call("sessions/mirror/fetch", serde_json::to_value(&first)?).await;
            if offset > 0 && response.as_ref().err().is_some_and(|error| super::error_data(error)["class"]=="conflict") {
                offset = 0;
                response = call(
                    "sessions/mirror/fetch",
                    serde_json::to_value(Fetch {
                        offset: 0,
                        prefix_hash: None,
                        ..first
                    })?,
                )
                .await;
            }
            drop(storage.lease(entry.size.saturating_sub(offset))?);
            let staging = if offset > 0 { target.clone() } else { temporary.clone() };
            if offset == 0 {
                storage.mutate(&[&staging], 0, || {
                    OpenOptions::new().write(true).create_new(true).mode(0o600).open(&staging)?;
                    Ok(())
                })?;
            }
            let mut output = OpenOptions::new().append(true).open(&staging)?;
            loop {
                ensure!(!stop.is_cancelled(), "Mirror stopped");
                let value = response?;
                let bytes = base64::engine::general_purpose::STANDARD.decode(
                    value["base64"]
                        .as_str()
                        .context("Mirror returned no bytes")?,
                )?;
                ensure!(
                    bytes.len() <= CHUNK && offset + bytes.len() as u64 <= entry.size,
                    "Mirror response exceeds admitted file size"
                );
                storage.mutate(&[&staging], bytes.len() as u64, || {
                    Ok(output.write_all(&bytes)?)
                })?;
                offset += bytes.len() as u64;
                if offset == entry.size {
                    break;
                }
                ensure!(
                    !bytes.is_empty(),
                    "Mirror response ended before the advertised size"
                );
                response = call(
                    "sessions/mirror/fetch",
                    serde_json::to_value(Fetch {
                        path: entry.path.to_string_lossy().into_owned(),
                        identity: entry.identity.clone(),
                        revision: entry.revision.clone(),
                        offset,
                        length: CHUNK,
                        prefix_hash: None,
                    })?,
                )
                .await;
            }
            output.sync_all()?;
            drop(output);
            if staging != target {
                storage.mutate(&[&staging, &target], 0, || Ok(std::fs::rename(&staging, &target)?))?;
            }
            store.writer()?.execute("INSERT INTO mirror_file VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(origin_host,path) DO UPDATE SET identity=excluded.identity,size=excluded.size,received=excluded.received,local_path=excluded.local_path",params![host,entry.path.to_string_lossy(),entry.revision,i64::try_from(entry.size)?,i64::try_from(offset)?,target.to_string_lossy()])?;
            ensure!(
                changed.len() < 100_000 || changed.contains(&target),
                "capacity: mirror batch exceeds 100000 changed paths"
            );
            changed.insert(target);
            total_files += 1;
            Ok(())
            }.await;
            failures.observe(host, &entry.path, result.as_ref().err());
            if result.is_err() {
                complete = false;
            }
        }
        cursor = page["cursor"].as_str().map(str::to_owned);
        if full && cursor.is_none() || !full && page["hasMore"] != true {
            break;
        }
    }
    if full && complete {
        let host_root = root.join(blake3::hash(host.as_bytes()).to_hex().as_str());
        if host_root.exists() {
            for entry in walkdir::WalkDir::new(&host_root).follow_links(false) {
                let entry = entry?;
                if entry.file_type().is_file() && !retained.contains(entry.path()) {
                    storage.mutate(&[entry.path()], 0, || {
                        Ok(std::fs::remove_file(entry.path())?)
                    })?;
                }
            }
        }
    }
    let projected = if full || !changed.is_empty() || !metadata.is_empty() {
        let projection = Projection {
            host: host.to_owned(),
            origins: origins.into_values().collect(),
            changes: (!full).then(|| changed.into_iter().collect()),
            metadata: metadata.into_values().collect(),
        };
        store
            .worker
            .get()
            .context("unavailable: session projection worker is not running")?
            .project_mirror(projection)
            .await?
    } else {
        saved.as_ref().is_some_and(|(_, _, projected)| *projected)
    };
    let projected =
        projected && complete && (full || saved.as_ref().is_some_and(|(_, _, prior)| *prior));
    let cursor =
        if full { snapshot_cursor } else { cursor }.context("Mirror returned no change cursor")?;
    let complete = complete && projected;
    let reason = (!complete).then_some("origin_incomplete");
    let previous: Option<(Option<String>, Option<String>)> = store
        .reader()?
        .query_row(
            "SELECT complete_through,stale_reason FROM coverage WHERE origin_host=?1",
            [host],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let complete_through = if complete {
        through
    } else {
        previous.as_ref().and_then(|(through, _)| through.clone())
    };
    let reconciled = if full {
        ::time::OffsetDateTime::now_utc().unix_timestamp()
    } else {
        saved.as_ref().context("Delta mirror has no prior state")?.1
    };
    let state_changed = saved
        .as_ref()
        .is_none_or(|(old, at, prior)| old != &cursor || *at != reconciled || *prior != projected);
    let coverage_changed = previous
        .as_ref()
        .is_none_or(|(prior, stale)| prior != &complete_through || stale.as_deref() != reason);
    if state_changed || coverage_changed {
        let mut db = store.writer()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        tx.execute("INSERT INTO mirror_state(origin_host,cursor,reconciled_at,projected_complete) VALUES(?1,?2,?3,?4) ON CONFLICT(origin_host) DO UPDATE SET cursor=excluded.cursor,reconciled_at=excluded.reconciled_at,projected_complete=excluded.projected_complete",params![host,cursor,reconciled,projected])?;
        if coverage_changed {
            tx.execute("INSERT INTO coverage(origin_host,mode,indexed_through,complete_through,stale_reason) VALUES(?1,'mirror',?2,?3,?4) ON CONFLICT(origin_host) DO UPDATE SET mode='mirror',indexed_through=excluded.indexed_through,complete_through=excluded.complete_through,stale_reason=excluded.stale_reason",params![host,super::now(),complete_through,reason])?;
        }
        tx.commit()?;
    }
    Ok(json!({"files":total_files,"complete":complete,"full":full}))
}

use rusqlite::OptionalExtension;
