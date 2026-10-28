mod normalize;
use super::{Origin, changes, query::SourceRef, store::Store};
use crate::providers::claude::records::{LineKind, MAX_SESSION_RECORD_BYTES, read_bounded_line};
use crate::storage::file_revision::FileRevision;
use anyhow::{Context, Result, ensure};
use regex::Regex;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{File, Metadata};
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use walkdir::WalkDir;

pub(crate) fn identity(metadata: &Metadata) -> String {
    format!("{:?}", FileRevision::from(metadata.clone()))
}

fn hash_prefix(path: &Path, length: u64) -> Result<String> {
    let mut hash = blake3::Hasher::new();
    let copied = std::io::copy(&mut File::open(path)?.take(length), &mut hash)?;
    ensure!(copied == length, "Source shortened during ingestion");
    Ok(hash.finalize().to_hex().to_string())
}

#[cfg(test)]
pub(crate) fn files(origin: &Origin) -> Result<Vec<PathBuf>> {
    if !origin.path().exists() {
        return Ok(Vec::new());
    }
    let mut files = Vec::new();
    for entry in WalkDir::new(origin.path()).follow_links(false) {
        let entry = entry?;
        if entry.file_type().is_file() && origin.is_transcript(entry.path()) {
            ensure!(
                files.len() < 100_000,
                "capacity: more than 100000 session sources"
            );
            files.push(entry.into_path());
        }
    }
    files.sort_by_cached_key(|path| std::fs::metadata(path).and_then(|m| m.modified()).ok());
    Ok(files)
}

fn companions(origin: &Origin, path: &Path) -> Result<Vec<PathBuf>> {
    let mut result = Vec::new();
    let directory = path.with_extension("");
    if directory.is_dir() {
        for entry in WalkDir::new(directory).follow_links(false) {
            let entry = entry?;
            if entry.file_type().is_file() && !origin.is_transcript(entry.path()) {
                ensure!(
                    result.len() < 100_000,
                    "capacity: too many session companions"
                );
                result.push(entry.into_path());
            }
        }
    }
    let metadata = path.with_extension("meta.json");
    if metadata.is_file() {
        result.push(metadata);
    }
    Ok(result)
}

pub(crate) fn scan(store: &Store, origins: &[Origin], stop: &AtomicBool) -> Result<Value> {
    scan_scope(store, origins, Scope::Full, stop)
}

pub(crate) enum Scope<'a> {
    Full,
    Changed(&'a [PathBuf]),
}

fn selected(store: &Store, origin: &Origin, paths: &[PathBuf]) -> Result<BTreeSet<PathBuf>> {
    let mut selected = BTreeSet::new();
    let db = store.reader()?;
    for path in paths {
        match std::fs::symlink_metadata(path) {
            Ok(metadata) if metadata.is_file() && origin.is_transcript(path) => {
                selected.insert(path.clone());
            }
            Ok(metadata) if metadata.is_dir() => {
                for entry in WalkDir::new(path).follow_links(false) {
                    let entry = entry?;
                    if entry.file_type().is_file() && origin.is_transcript(entry.path()) {
                        selected.insert(entry.into_path());
                        ensure!(
                            selected.len() <= 100_000,
                            "capacity: more than 100000 session sources"
                        );
                    }
                }
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let original = origin.original(path)?.to_string_lossy().into_owned();
        let low = format!("{original}/");
        let high = format!("{original}0");
        let known: Vec<String> = db.prepare("SELECT path FROM source WHERE origin_host=?1 AND (path=?2 OR (path>=?3 AND path<?4)) UNION SELECT s.path FROM dependency d JOIN source s USING(source_id) WHERE s.origin_host=?1 AND s.present=1 AND (d.path=?2 OR (d.path>=?3 AND d.path<?4))")?.query_map(params![origin.host,original,low,high],|r|r.get(0))?.collect::<rusqlite::Result<_>>()?;
        for path in known {
            selected.insert(origin.local(Path::new(&path))?);
            ensure!(
                selected.len() <= 100_000,
                "capacity: more than 100000 session sources"
            );
        }
    }
    Ok(selected)
}

pub(crate) fn scan_scope(
    store: &Store,
    origins: &[Origin],
    scope: Scope<'_>,
    stop: &AtomicBool,
) -> Result<Value> {
    scan_serving(store, origins, scope, stop, &mut |_| Ok(()))
}

pub(super) fn scan_serving(
    store: &Store,
    origins: &[Origin],
    scope: Scope<'_>,
    stop: &AtomicBool,
    between: &mut impl FnMut(&mut Connection) -> Result<()>,
) -> Result<Value> {
    let mut ingested = 0;
    let mut failures = 0;
    let mut longest_source = 0.0_f64;
    let mut slow_sources = 0;
    let mut changed_hosts = BTreeSet::new();
    let at = super::now();
    for origin in origins {
        let root = origin.path();
        let scopes = match &scope {
            Scope::Full => vec![root.clone()],
            Scope::Changed(paths) => paths
                .iter()
                .filter_map(|path| {
                    if path.starts_with(&root) {
                        Some(path.clone())
                    } else if root.starts_with(path) {
                        Some(root.clone())
                    } else {
                        None
                    }
                })
                .collect(),
        };
        if scopes.is_empty() {
            continue;
        }
        changed_hosts.insert(origin.host.clone());
        if !root.is_dir() {
            continue;
        }
        let paths: Vec<_> = selected(store, origin, &scopes)?.into_iter().collect();
        for batch in paths.chunks(32) {
            let mut db = store.writer()?;
            for path in batch {
                if stop.load(Ordering::Acquire) {
                    return Ok(serde_json::json!({"cancelled":true}));
                }
                let original = origin.original(path)?.to_string_lossy().into_owned();
                let gone = match std::fs::symlink_metadata(path) {
                    Ok(metadata) => !metadata.is_file(),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
                    Err(error) => return Err(error.into()),
                };
                if gone {
                    if !root.is_dir() {
                        break;
                    }
                    let tx =
                        db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
                    tx.execute("DELETE FROM session WHERE source_id IN (SELECT source_id FROM source WHERE origin_host=?1 AND path=?2)",params![origin.host,original])?;
                    tx.execute(
                        "DELETE FROM source WHERE origin_host=?1 AND path=?2",
                        params![origin.host, original],
                    )?;
                    tx.commit()?;
                    between(&mut db)?;
                    continue;
                }
                let started = std::time::Instant::now();
                match ingest(&mut db, origin, path, stop) {
                    Ok(changed) => ingested += usize::from(changed),
                    Err(error) => {
                        failures += 1;
                        db.execute("INSERT INTO source(origin_host,provider,provider_home,path,local_path,file_identity,size,mtime_ns,ingested_offset,revision,present,prefix_hash,parser_state,failure) VALUES(?1,?2,?3,?4,?5,'',0,0,0,0,1,'','{}',?6) ON CONFLICT(origin_host,path) DO UPDATE SET failure=excluded.failure",params![origin.host,origin.provider,origin.provider_home.to_string_lossy(),original,path.to_string_lossy(),format!("{error:#}")])?;
                    }
                }
                let elapsed = started.elapsed().as_secs_f64();
                longest_source = longest_source.max(elapsed);
                slow_sources += usize::from(elapsed > 5.0);
                between(&mut db)?;
            }
        }
    }
    if changed_hosts.is_empty() {
        return Ok(serde_json::json!({"ingested":0,"parseFailures":0}));
    }
    let db = store.writer()?;
    for host in changed_hosts {
        let local = origins
            .iter()
            .any(|o| o.host == host && o.local_home == o.provider_home);
        let absent = origins
            .iter()
            .filter(|o| o.host == host)
            .any(|o| !o.path().is_dir());
        let errors:i64=db.query_row("SELECT count(*) FROM source WHERE origin_host=?1 AND failure IS NOT NULL AND failure<>'partial_record'",[&host],|r|r.get(0))?;
        let unavailable:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM source WHERE origin_host=?1 AND failure IS NOT NULL) OR EXISTS(SELECT 1 FROM dependency d JOIN source s USING(source_id) WHERE s.origin_host=?1 AND d.present=0)",[&host],|r|r.get(0))?;
        let reason = if absent {
            Some("provider_unavailable")
        } else if errors > 0 {
            Some("parse_failure")
        } else if unavailable {
            Some("incomplete_evidence")
        } else {
            None
        };
        db.execute("INSERT INTO coverage(origin_host,mode,indexed_through,complete_through,stale_reason,parse_failures) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(origin_host) DO UPDATE SET indexed_through=excluded.indexed_through,complete_through=CASE WHEN excluded.stale_reason IS NULL AND excluded.mode='local' THEN excluded.complete_through ELSE coverage.complete_through END,stale_reason=excluded.stale_reason,parse_failures=excluded.parse_failures",params![host,if local {"local"}else{"mirror"},at,if local&&reason.is_none(){Some(&at)}else{None},reason,errors])?;
    }
    changes::prune(&db)?;
    db.execute_batch("PRAGMA wal_checkpoint(PASSIVE);")?;
    Ok(
        serde_json::json!({"ingested":ingested,"parseFailures":failures,"longestSourceSeconds":longest_source,"sourcesOverFiveSeconds":slow_sources}),
    )
}

pub(crate) fn refresh_inventory(store: &Store) -> Result<()> {
    store
        .worker
        .get()
        .context("unavailable: session worker is not running")?
        .inventory()
}

pub(super) fn header(
    db: &mut Connection,
    origin: &Origin,
    path: &Path,
    stop: &AtomicBool,
) -> Result<()> {
    if let Err(error) = ingest_source(db, origin, path, stop, ReadMode::Inventory) {
        if let Some(conflict) = error.downcast_ref::<normalize::IdentityConflict>() {
            let known: bool = db.query_row(
                "SELECT EXISTS(SELECT 1 FROM session WHERE session_key=?1)",
                [&conflict.key],
                |row| row.get(0),
            )?;
            if known {
                return Ok(());
            }
        }
        return Err(error);
    }
    let original = origin.original(path)?.to_string_lossy().into_owned();
    let present: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM source JOIN session USING(source_id) WHERE source.origin_host=?1 AND source.path=?2)",params![origin.host,original],|r|r.get(0))?;
    ensure!(
        present,
        "unavailable: transcript exists without a complete identity record"
    );
    Ok(())
}

#[derive(PartialEq, Eq)]
enum ReadMode {
    Full,
    Inventory,
}

pub(crate) fn ingest(
    db: &mut Connection,
    origin: &Origin,
    path: &Path,
    stop: &AtomicBool,
) -> Result<bool> {
    ingest_source(db, origin, path, stop, ReadMode::Full)
}

fn ingest_source(
    db: &mut Connection,
    origin: &Origin,
    path: &Path,
    stop: &AtomicBool,
    mode: ReadMode,
) -> Result<bool> {
    let mut file = File::open(path)?;
    let before = file.metadata()?;
    ensure!(before.is_file(), "Session source is not a regular file");
    let stamp = identity(&before);
    let original = origin.original(path)?.to_string_lossy().into_owned();
    let prior:Option<(i64,String,i64,String,String,i64,bool)>=db.query_row("SELECT source_id,file_identity,ingested_offset,prefix_hash,parser_state,revision,present FROM source WHERE origin_host=?1 AND path=?2",params![origin.host,original],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?))).optional()?;
    let prior = prior
        .map(
            |(id, stamp, offset, prefix, state, revision, present)| -> Result<_> {
                Ok((
                    id,
                    stamp,
                    u64::try_from(offset)?,
                    prefix,
                    state,
                    revision,
                    present,
                ))
            },
        )
        .transpose()?;
    let companions = if mode == ReadMode::Full {
        companions(origin, path)?
    } else {
        Vec::new()
    };
    let mut dependencies_changed = false;
    if let Some((id, ..)) = &prior {
        let dependencies: Vec<(String, Option<String>)> = db
            .prepare("SELECT local_path,identity FROM dependency WHERE source_id=?1")?
            .query_map([id], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        for (path, old) in dependencies {
            let current = match std::fs::metadata(path) {
                Ok(m) => Some(identity(&m)),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
                Err(e) => return Err(e.into()),
            };
            dependencies_changed |= current != old;
        }
    }
    if let Some((id, ..)) = &prior {
        let known: BTreeSet<String> = db
            .prepare("SELECT path FROM dependency WHERE source_id=?1")?
            .query_map([id], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        for companion in &companions {
            dependencies_changed |=
                !known.contains(&origin.original(companion)?.to_string_lossy().into_owned());
        }
    }
    if prior
        .as_ref()
        .is_some_and(|(_, previous, _, _, _, _, present)| previous == &stamp && *present)
        && !dependencies_changed
    {
        return Ok(false);
    }
    let append = if let Some((_, _, offset, hash, _, _, present)) = &prior {
        *present
            && !dependencies_changed
            && *offset > 0
            && before.len() >= *offset
            && hash_prefix(path, *offset)? == *hash
    } else {
        false
    };
    let mut state = if append {
        serde_json::from_str(&prior.as_ref().context("Append needs previous state")?.4)?
    } else {
        normalize::State::default()
    };
    let mut offset = if append {
        prior.as_ref().context("Append needs previous state")?.2
    } else {
        0
    };
    let revision = prior.as_ref().map_or(1, |p| p.5 + 1);
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    tx.execute("INSERT OR IGNORE INTO source(origin_host,provider,provider_home,path,local_path,file_identity,size,mtime_ns,ingested_offset,revision,present,prefix_hash,parser_state) VALUES(?1,?2,?3,?4,?5,'',0,0,0,0,1,'','{}')",params![origin.host,origin.provider,origin.provider_home.to_string_lossy(),original,path.to_string_lossy()])?;
    let source: i64 = tx.query_row(
        "SELECT source_id FROM source WHERE origin_host=?1 AND path=?2",
        params![origin.host, original],
        |r| r.get(0),
    )?;
    if !append {
        tx.execute("DELETE FROM session WHERE source_id=?1", [source])?;
        tx.execute("DELETE FROM dependency WHERE source_id=?1", [source])?;
    }
    let mut hash = blake3::Hasher::new();
    std::io::copy(&mut File::open(path)?.take(offset), &mut hash)?;
    file.seek(SeekFrom::Start(offset))?;
    let mut reader = BufReader::new(file.take(before.len() - offset));
    let mut line = Vec::new();
    let mut records = 0;
    loop {
        ensure!(!stop.load(Ordering::Acquire), "Session ingestion cancelled");
        line.clear();
        let bound = if mode == ReadMode::Inventory {
            8 << 20
        } else {
            MAX_SESSION_RECORD_BYTES
        };
        let (read, kind) = read_bounded_line(&mut reader, &mut line, bound)?;
        if read == 0 {
            break;
        }
        if kind == LineKind::Partial {
            break;
        }
        ensure!(
            kind != LineKind::Oversized,
            "capacity: source record exceeds {MAX_SESSION_RECORD_BYTES} bytes; raw evidence retained"
        );
        if !line.iter().all(u8::is_ascii_whitespace) {
            let value: Value =
                serde_json::from_slice(&line).context("Malformed complete session record")?;
            let record = normalize::Record {
                db: &tx,
                origin,
                source,
                revision,
                path,
                offset,
                bytes: &line,
            };
            record.apply(&mut state, value)?;
        }
        hash.update(&line);
        offset += read;
        records += 1;
        if mode == ReadMode::Inventory {
            if state.thread.is_some() {
                break;
            }
            ensure!(
                records < 128 && offset < 8 << 20,
                "unavailable: identity exceeds inventory read budget"
            );
        }
    }
    for companion in companions {
        let metadata = std::fs::metadata(&companion)?;
        tx.execute(
            "INSERT OR IGNORE INTO dependency VALUES(?1,?2,?3,'companion',?4,1)",
            params![
                source,
                origin.original(&companion)?.to_string_lossy(),
                companion.to_string_lossy(),
                identity(&metadata)
            ],
        )?;
    }
    let prefix = hash.finalize().to_hex().to_string();
    let after = std::fs::metadata(path)?;
    ensure!(
        before.dev() == after.dev() && before.ino() == after.ino() && before.len() <= after.len(),
        "Source replaced during ingestion"
    );
    if FileRevision::from(before.clone()) != FileRevision::from(after.clone()) {
        ensure!(
            prefix == hash_prefix(path, offset)?,
            "Source changed during ingestion"
        );
    }
    ensure!(
        state.thread.is_some() || offset == 0,
        "Transcript has no exact provider identity"
    );
    tx.execute("UPDATE source SET local_path=?1,file_identity=?2,size=?3,mtime_ns=?4,ingested_offset=?5,revision=?6,present=1,prefix_hash=?7,parser_state=?8,failure=?9 WHERE source_id=?10",params![path.to_string_lossy(),if mode==ReadMode::Full {&stamp} else {""},i64::try_from(before.len())?,before.mtime()*1_000_000_000+before.mtime_nsec(),i64::try_from(offset)?,revision,prefix,serde_json::to_string(&state)?,if offset<before.len() {Some("partial_record")} else {None},source])?;
    tx.commit()?;
    Ok(true)
}

pub(super) fn skills(tool: &str, input: &Value) -> Vec<(String, &'static str)> {
    let mut result = BTreeSet::new();
    if tool == "Skill"
        && let Some(name) = input["skill"].as_str()
    {
        result.insert((name.to_owned(), "skill_tool"));
    }
    static PATH: std::sync::LazyLock<Regex> = std::sync::LazyLock::new(|| {
        Regex::new(r#"(?:[/~][^\s\"'<>`]+)?/skills/(?:\.system/)?([^/\s\"'<>`]+)/SKILL\.md"#)
            .expect("skill path expression")
    });
    let encoded = input.to_string();
    for captures in PATH.captures_iter(&encoded) {
        result.insert((captures[1].to_owned(), "skill_md_read"));
    }
    result.into_iter().collect()
}

pub(super) fn outcome(value: &Value, text: &str) -> (Option<bool>, Option<i64>, Option<i64>) {
    let payload = if text.starts_with("Script completed\n") {
        text.split_once("Output:\n").map_or(text, |(_, body)| body)
    } else {
        text
    };
    let parsed = serde_json::from_str::<Value>(payload).ok();
    let root = parsed.as_ref().unwrap_or(value);
    let exit = [
        root.pointer("/exit_code"),
        root.pointer("/metadata/exit_code"),
        value.pointer("/metadata/exitCode"),
        value.pointer("/metadata/exit_code"),
    ]
    .into_iter()
    .flatten()
    .find_map(Value::as_i64);
    let duration = root["duration_ms"]
        .as_i64()
        .or_else(|| value["metadata"]["durationMs"].as_i64());
    let error = value["is_error"]
        .as_bool()
        .or_else(|| root["isError"].as_bool());
    static EXIT: std::sync::LazyLock<Regex> = std::sync::LazyLock::new(|| {
        Regex::new(r"(?m)^Process exited with code (-?[0-9]+)\s*$")
            .expect("exit evidence expression")
    });
    (
        error,
        exit.or_else(|| EXIT.captures(text).and_then(|c| c[1].parse().ok())),
        duration,
    )
}

pub(super) fn dependencies(
    value: &Value,
    text: &str,
    origin: &Origin,
    path: &Path,
) -> Result<(Vec<String>, Vec<String>)> {
    let mut images = BTreeSet::new();
    fn visit(value: &Value, images: &mut BTreeSet<String>, pointer: String) {
        match value {
            Value::Array(a) => {
                for (i, v) in a.iter().enumerate() {
                    visit(v, images, format!("{pointer}/{i}"));
                }
            }
            Value::Object(o) => {
                if matches!(
                    o.get("type").and_then(Value::as_str),
                    Some("image" | "input_image" | "image_url")
                ) {
                    images.insert(format!("inline:{pointer}"));
                }
                for (k, v) in o {
                    if matches!(k.as_str(), "savedPath" | "image_path" | "file_path")
                        && let Some(p) = v.as_str()
                        && crate::storage::tool_media::media_type_for_path(p).is_some()
                    {
                        images.insert(p.into());
                    }
                    if k != "data" {
                        visit(v, images, format!("{pointer}/{k}"));
                    }
                }
            }
            _ => {}
        }
    }
    visit(value, &mut images, String::new());
    static SIDECAR: std::sync::LazyLock<Regex> = std::sync::LazyLock::new(|| {
        Regex::new(r#"(?:/[^\s<>\"']+)?/tool-results/[^\s<>\"']+"#)
            .expect("sidecar path expression")
    });
    let mut sidecars = BTreeSet::new();
    for capture in SIDECAR.find_iter(text) {
        let raw = PathBuf::from(capture.as_str().trim_end_matches(['.', ',', ')']));
        let original = if raw.is_absolute() {
            raw
        } else {
            origin
                .original(path)?
                .parent()
                .context("Sidecar parent")?
                .join(raw)
        };
        if original.starts_with(&origin.provider_home) {
            sidecars.insert(original.to_string_lossy().into_owned());
        }
    }
    Ok((images.into_iter().collect(), sidecars.into_iter().collect()))
}

pub(crate) fn catalog(db: &Connection, roots: &[PathBuf]) -> Result<()> {
    let mut paths = BTreeSet::new();
    let mut skills = BTreeMap::new();
    let roots: BTreeSet<PathBuf> = roots
        .iter()
        .filter(|r| r.exists())
        .map(std::fs::canonicalize)
        .collect::<std::io::Result<_>>()?;
    for root in roots {
        for entry in WalkDir::new(root).follow_links(true) {
            let entry = entry?;
            if entry.file_type().is_file() && entry.file_name() == "SKILL.md" {
                let path = std::fs::canonicalize(entry.path())?;
                if !paths.insert(path.clone()) {
                    continue;
                }
                ensure!(
                    paths.len() <= 10000,
                    "capacity: more than 10000 installed skills"
                );
                let name = path
                    .parent()
                    .and_then(|p| p.file_name())
                    .context("Skill directory")?
                    .to_string_lossy()
                    .into_owned();
                skills.entry(name).or_insert(path);
            }
        }
    }
    let tx = db.unchecked_transaction()?;
    let known: Vec<String> = tx
        .prepare("SELECT name FROM skill WHERE present=1")?
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    for name in known {
        if !skills.contains_key(&name) {
            tx.execute("UPDATE skill SET present=0 WHERE name=?1", [name])?;
        }
    }
    for (name, path) in skills {
        tx.execute("INSERT INTO skill(name,path,first_seen,present) VALUES(?1,?2,?3,1) ON CONFLICT(name) DO UPDATE SET path=excluded.path,present=1 WHERE skill.path<>excluded.path OR skill.present=0",params![name,path.to_string_lossy(),super::now()])?;
    }
    tx.commit()?;
    Ok(())
}
