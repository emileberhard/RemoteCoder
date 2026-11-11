mod normalize;
mod source;

use super::{Origin, changes, query::SourceRef, store::Store};
use anyhow::{Context, Result, ensure};
use regex::Regex;
use rusqlite::{Connection, params};
use serde_json::Value;
#[cfg(test)]
pub(crate) use source::ingest;
use source::{ReadMode, ReadOutcome, ingest_source};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::Metadata;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use walkdir::WalkDir;

pub(crate) fn identity(metadata: &Metadata) -> String {
    format!(
        "{}:{}:{}.{:09}:{}.{:09}",
        metadata.ino(),
        metadata.len(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        metadata.ctime(),
        metadata.ctime_nsec()
    )
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

#[cfg(test)]
pub(crate) fn scan(store: &Store, origins: &[Origin], stop: &AtomicBool) -> Result<Value> {
    let outcome = scan_scope(store, origins, Scope::Full, stop)?;
    if outcome["cancelled"] != true {
        mark_ready(&*store.writer()?)?;
    }
    Ok(outcome)
}

pub(super) fn mark_ready(db: &Connection) -> Result<()> {
    db.execute(
        "UPDATE meta SET value='1' WHERE key='catalog_ready' AND value='0'",
        [],
    )?;
    Ok(())
}

pub(crate) enum Scope<'a> {
    Full,
    Changed(&'a [PathBuf]),
}

pub(super) const SOURCE_SELECTION_SQL: &str = "SELECT path FROM source WHERE origin_host=?1 AND path=?2 UNION SELECT path FROM source WHERE origin_host=?1 AND path>=?3 AND path<?4 UNION SELECT s.path FROM dependency d CROSS JOIN source s USING(source_id) WHERE d.path=?2 AND s.origin_host=?1 AND s.present=1 UNION SELECT s.path FROM dependency d CROSS JOIN source s USING(source_id) WHERE d.path>=?3 AND d.path<?4 AND s.origin_host=?1 AND s.present=1";

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
        let known: Vec<String> = db
            .prepare(SOURCE_SELECTION_SQL)?
            .query_map(params![origin.host, original, low, high], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
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

#[cfg(test)]
pub(crate) fn scan_scope(
    store: &Store,
    origins: &[Origin],
    scope: Scope<'_>,
    stop: &AtomicBool,
) -> Result<Value> {
    super::index::open(&*store.writer()?)?;
    let outcome = scan_serving(store, origins, scope, stop, &|| false, &mut |_| Ok(()))?;
    let mut db = store.writer()?;
    while !stop.load(Ordering::Acquire) && super::index::rebuild_one(&mut db)? {}
    Ok(outcome)
}

pub(super) fn scan_serving(
    store: &Store,
    origins: &[Origin],
    scope: Scope<'_>,
    stop: &AtomicBool,
    inventory_waiting: &dyn Fn() -> bool,
    between: &mut impl FnMut(&mut Connection) -> Result<()>,
) -> Result<Value> {
    let mut ingested = 0;
    let mut failures = 0;
    let mut longest_source = 0.0_f64;
    let mut slow_sources = 0;
    let mut changed_hosts = BTreeSet::new();
    let at = super::now();
    let mut sources = Vec::new();
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
        for path in selected(store, origin, &scopes)? {
            ensure!(
                sources.len() < 100_000,
                "capacity: more than 100000 session sources"
            );
            sources.push((origin, path));
        }
    }
    if matches!(scope, Scope::Full) {
        sources.sort_by_cached_key(|(_, path)| {
            std::fs::metadata(path)
                .and_then(|metadata| metadata.modified())
                .ok()
        });
    }
    for batch in sources.chunks(32) {
        let mut db = store.writer()?;
        for (origin, path) in batch {
            let root = origin.path();
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
                let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
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
            let mode = match scope {
                Scope::Full => ReadMode::Full,
                Scope::Changed(_) => ReadMode::Incremental,
            };
            loop {
                if stop.load(Ordering::Acquire) {
                    return Ok(serde_json::json!({"cancelled":true}));
                }
                if inventory_waiting() {
                    between(&mut db)?;
                }
                match ingest_source(&mut db, origin, path, stop, mode, inventory_waiting) {
                    Ok(ReadOutcome::Checkpoint | ReadOutcome::Yield) => between(&mut db)?,
                    Ok(ReadOutcome::Saved) => {
                        ingested += 1;
                        break;
                    }
                    Ok(ReadOutcome::Unchanged) => break,
                    Err(error) => {
                        record_failure(&db, origin, path, &error)?;
                        break;
                    }
                }
            }
            let elapsed = started.elapsed().as_secs_f64();
            longest_source = longest_source.max(elapsed);
            slow_sources += usize::from(elapsed > 5.0);
            super::index::rebuild_ready(&mut db)?;
            between(&mut db)?;
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
        failures += usize::try_from(errors)?;
        let unavailable:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM source WHERE origin_host=?1 AND failure IS NOT NULL) OR EXISTS(SELECT 1 FROM dependency d CROSS JOIN source s USING(source_id) WHERE d.present=0 AND s.origin_host=?1)",[&host],|r|r.get(0))?;
        let reason = if absent {
            Some("provider_unavailable")
        } else if errors > 0 {
            Some("parse_failure")
        } else if unavailable {
            Some("incomplete_evidence")
        } else {
            None
        };
        let roots: Vec<_> = origins
            .iter()
            .filter(|origin| origin.host == host)
            .map(Origin::path)
            .collect();
        db.execute("INSERT INTO coverage(origin_host,mode,indexed_through,complete_through,stale_reason,parse_failures,provider_roots) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(origin_host) DO UPDATE SET indexed_through=excluded.indexed_through,complete_through=CASE WHEN excluded.stale_reason IS NULL AND excluded.mode='local' THEN excluded.complete_through ELSE coverage.complete_through END,stale_reason=excluded.stale_reason,parse_failures=excluded.parse_failures,provider_roots=excluded.provider_roots",params![host,if local {"local"}else{"mirror"},at,if local&&reason.is_none(){Some(&at)}else{None},reason,errors,serde_json::to_string(&roots)?])?;
    }
    changes::prune(&db, super::CHANGE_ROWS)?;
    db.execute_batch("PRAGMA incremental_vacuum; PRAGMA wal_checkpoint(PASSIVE);")?;
    Ok(
        serde_json::json!({"ingested":ingested,"parseFailures":failures,"longestSourceSeconds":longest_source,"sourcesOverFiveSeconds":slow_sources}),
    )
}

pub(crate) fn refresh_inventory(store: &Store) -> Result<()> {
    store
        .worker
        .get()
        .context("unavailable: session worker is not running")?
        .inventory(store)
}

pub(super) fn record_failure(
    db: &Connection,
    origin: &Origin,
    path: &Path,
    error: &anyhow::Error,
) -> Result<()> {
    let original = origin.original(path)?.to_string_lossy().into_owned();
    let message = format!("{error:#}");
    db.execute("INSERT INTO source(origin_host,provider,provider_home,path,local_path,file_identity,size,mtime_ns,ingested_offset,revision,present,prefix_hash,parser_state,failure) VALUES(?1,?2,?3,?4,?5,'',0,0,0,0,1,'','{}',?6) ON CONFLICT(origin_host,path) DO UPDATE SET failure=excluded.failure WHERE source.failure IS NOT excluded.failure",params![origin.host,origin.provider,origin.provider_home.to_string_lossy(),original,path.to_string_lossy(),message])?;
    Ok(())
}

#[derive(Debug)]
pub(super) struct InvalidHeader(pub &'static str);

impl std::fmt::Display for InvalidHeader {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for InvalidHeader {}

pub(super) fn header(
    db: &mut Connection,
    origin: &Origin,
    path: &Path,
    stop: &AtomicBool,
) -> Result<()> {
    if let Err(error) = ingest_source(db, origin, path, stop, ReadMode::Inventory, &|| false) {
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
    if !present {
        return Err(InvalidHeader("Transcript exists without a complete identity record").into());
    }
    Ok(())
}

pub(super) fn file_identity(path: &Path) -> Result<Option<String>> {
    match std::fs::metadata(path) {
        Ok(metadata) => Ok(Some(identity(&metadata))),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
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
