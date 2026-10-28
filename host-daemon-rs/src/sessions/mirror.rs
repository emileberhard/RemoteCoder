use super::{Origin, ingest, store::Store};
use anyhow::{Context, Result, ensure};
use base64::Engine;
use futures_util::future::BoxFuture;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};

pub(crate) const BUDGET_BYTES: u64 = 50 << 30;
const RESERVE_BYTES: u64 = 20 << 30;
const CHUNK: usize = 1 << 20;

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

fn physical(metadata: &std::fs::Metadata) -> String {
    format!("{}:{}", metadata.dev(), metadata.ino())
}

pub(crate) fn list(store: &Store, host: &str, after: Option<String>) -> Result<Value> {
    let db = store.reader()?;
    let mut statement=db.prepare("SELECT provider,provider_home,path,local_path,present,0 FROM source WHERE origin_host=?1 UNION ALL SELECT s.provider,s.provider_home,d.path,d.local_path,d.present,1 FROM dependency d JOIN source s USING(source_id) WHERE s.origin_host=?1 ORDER BY 3")?;
    let mut entries = BTreeMap::new();
    for row in statement.query_map([host], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, bool>(4)?,
            r.get::<_, bool>(5)?,
        ))
    })? {
        let (provider, home, path, local, present, dependency) = row?;
        let metadata = match std::fs::metadata(&local) {
            Ok(m) => Some(m),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => return Err(e.into()),
        };
        let entry = Entry {
            origin_host: host.into(),
            provider,
            provider_home: home.into(),
            path: PathBuf::from(&path),
            identity: metadata.as_ref().map(physical).unwrap_or_default(),
            revision: metadata.as_ref().map(ingest::identity).unwrap_or_default(),
            size: metadata.as_ref().map_or(0, |m| m.len()),
            present: present && metadata.is_some(),
            dependency,
        };
        entries.insert(path, entry);
    }
    let mut page = Vec::new();
    let mut next = None;
    for (path, entry) in entries
        .into_iter()
        .filter(|(p, _)| after.as_ref().is_none_or(|after| p > after))
    {
        if page.len() == 500 {
            break;
        }
        next = Some(path);
        page.push(entry);
    }
    let (through, complete): (Option<String>, bool) = db.query_row("SELECT indexed_through,stale_reason IS NULL AND complete_through IS NOT NULL FROM coverage WHERE origin_host=?1",[host],|r|Ok((r.get(0)?,r.get(1)?)))?;
    Ok(
        json!({"schemaVersion":1,"files":page,"cursor":if page.len()==500 {next} else {None},"through":through,"complete":complete,"coverage":super::query::coverage(&db)?}),
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
    ensure!(
        physical(&before) == request.identity && ingest::identity(&before) == request.revision,
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

pub(crate) fn usage(root: &Path) -> Result<u64> {
    if !root.exists() {
        return Ok(0);
    }
    let mut bytes = 0u64;
    for entry in walkdir::WalkDir::new(root).follow_links(false) {
        let entry = entry?;
        if entry.file_type().is_file() {
            bytes = bytes
                .checked_add(entry.metadata()?.len())
                .context("Mirror byte count overflow")?;
        }
    }
    Ok(bytes)
}

pub(crate) fn admit(used: u64, incoming: u64, free: u64, total: u64) -> Result<()> {
    ensure!(
        used.checked_add(incoming)
            .is_some_and(|bytes| bytes <= BUDGET_BYTES)
            && free.saturating_sub(incoming) >= RESERVE_BYTES.max(total / 10),
        "stale: budget; mirror needs space within 50 GiB and its free-disk reserve"
    );
    Ok(())
}

fn available(root: &Path) -> Result<(u64, u64)> {
    use std::ffi::CString;
    let path = CString::new(root.as_os_str().as_encoded_bytes())?;
    let mut stats = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    let result = unsafe { libc::statvfs(path.as_ptr(), stats.as_mut_ptr()) };
    ensure!(
        result == 0,
        "Cannot measure mirror free disk: {}",
        std::io::Error::last_os_error()
    );
    let stats = unsafe { stats.assume_init() };
    Ok((
        stats.f_bavail as u64 * stats.f_frsize,
        stats.f_blocks as u64 * stats.f_frsize,
    ))
}

pub(crate) type Call =
    std::sync::Arc<dyn Fn(&'static str, Value) -> BoxFuture<'static, Result<Value>> + Send + Sync>;

pub(crate) async fn sync(
    store: &Store,
    host: &str,
    call: Call,
    stop: tokio_util::sync::CancellationToken,
) -> Result<Value> {
    let store = store.clone();
    let host = host.to_owned();
    tokio::task::spawn_blocking(move || {
        let runtime = tokio::runtime::Handle::current();
        runtime.block_on(sync_owned(&store, &host, call, stop))
    })
    .await?
}

async fn sync_owned(
    store: &Store,
    host: &str,
    call: Call,
    stop: tokio_util::sync::CancellationToken,
) -> Result<Value> {
    let root = store.path.parent().context("Mirror root")?.join("mirror");
    crate::storage::private_state::ensure_private_directory(&root)?;
    use std::os::unix::fs::OpenOptionsExt;
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(root.join(".lock"))?;
    lock.try_lock()
        .context("Mirror is already owned by another worker")?;
    let mut cursor = None;
    let mut used = usage(&root)?;
    let mut origins = BTreeMap::new();
    let mut complete = true;
    let mut total_files = 0;
    let mut through: Option<String> = None;
    loop {
        let page = call("sessions/mirror/list", json!({"cursor":cursor})).await?;
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
        let entries: Vec<Entry> = serde_json::from_value(page["files"].clone())?;
        for entry in entries {
            ensure!(!stop.is_cancelled(), "Mirror stopped");
            ensure!(
                entry.origin_host == host,
                "Mirror origin does not match the authenticated member"
            );
            if !entry.present {
                complete = false;
                continue;
            }
            let relative = entry
                .path
                .strip_prefix(&entry.provider_home)
                .context("Mirror source is outside provider home")?;
            ensure!(
                relative
                    .components()
                    .all(|c| matches!(c, Component::Normal(_))),
                "Invalid mirror evidence path"
            );
            let scope = blake3::hash(entry.provider_home.as_os_str().as_encoded_bytes())
                .to_hex()
                .to_string();
            let home = root
                .join(blake3::hash(host.as_bytes()).to_hex().as_str())
                .join(&entry.provider)
                .join(&scope[..16]);
            let target = home.join(relative);
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
                origins.insert(
                    format!("{}:{scope}", entry.provider),
                    Origin {
                        host: host.into(),
                        provider: entry.provider,
                        provider_home: entry.provider_home,
                        local_home: home,
                    },
                );
                total_files += 1;
                continue;
            }
            if temporary.exists() {
                std::fs::remove_file(&temporary)?;
                used = usage(&root)?;
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
            let (free, total) = available(&root)?;
            admit(used, entry.size, free, total)?;
            let first = Fetch {
                path: entry.path.to_string_lossy().into_owned(),
                identity: entry.identity.clone(),
                revision: entry.revision.clone(),
                offset,
                length: CHUNK,
                prefix_hash: prefix,
            };
            let mut response = call("sessions/mirror/fetch", serde_json::to_value(&first)?).await;
            if response.is_err() && offset > 0 {
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
            if offset > 0 {
                std::fs::copy(&target, &temporary)?;
            } else {
                File::create(&temporary)?;
            }
            let mut output = OpenOptions::new().append(true).open(&temporary)?;
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
                output.write_all(&bytes)?;
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
            std::fs::rename(&temporary, &target)?;
            used = used.saturating_sub(existing) + entry.size;
            store.writer()?.execute("INSERT INTO mirror_file VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(origin_host,path) DO UPDATE SET identity=excluded.identity,size=excluded.size,received=excluded.received,local_path=excluded.local_path",params![host,entry.path.to_string_lossy(),entry.revision,i64::try_from(entry.size)?,i64::try_from(offset)?,target.to_string_lossy()])?;
            origins.insert(
                format!("{}:{scope}", entry.provider),
                Origin {
                    host: host.into(),
                    provider: entry.provider,
                    provider_home: entry.provider_home,
                    local_home: home,
                },
            );
            total_files += 1;
        }
        cursor = page["cursor"].as_str().map(str::to_owned);
        if cursor.is_none() {
            break;
        }
    }
    let origins: Vec<_> = origins.into_values().collect();
    {
        let outcome = ingest::scan(store, &origins, &std::sync::atomic::AtomicBool::new(false))?;
        let partial: bool = store.reader()?.query_row(
            "SELECT stale_reason IS NOT NULL FROM coverage WHERE origin_host=?1",
            [host],
            |r| r.get(0),
        )?;
        let complete = complete && outcome["parseFailures"] == 0 && !partial;
        let at = super::now();
        store.writer()?.execute("INSERT INTO coverage(origin_host,mode,indexed_through,complete_through,stale_reason) VALUES(?1,'mirror',?2,?3,?4) ON CONFLICT(origin_host) DO UPDATE SET mode='mirror',indexed_through=excluded.indexed_through,complete_through=CASE WHEN excluded.stale_reason IS NULL THEN excluded.complete_through ELSE coverage.complete_through END,stale_reason=excluded.stale_reason",params![host,at,if complete {through.as_deref()} else {None},if complete {None} else {Some("missing_dependency")}])?;
        Ok(json!({"files":total_files,"complete":complete}))
    }
}

use rusqlite::OptionalExtension;
