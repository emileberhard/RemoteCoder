use super::{Origin, discovery::Discovery, ingest, store::Store, worker::Worker};
use anyhow::{Result, ensure};
use serde_json::json;
use std::io::Write;
use std::path::Path;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant, UNIX_EPOCH};

fn cpu_seconds() -> f64 {
    let mut used = std::mem::MaybeUninit::<libc::rusage>::uninit();
    assert_eq!(
        unsafe { libc::getrusage(libc::RUSAGE_SELF, used.as_mut_ptr()) },
        0
    );
    let used = unsafe { used.assume_init() };
    used.ru_utime.tv_sec as f64
        + used.ru_utime.tv_usec as f64 / 1e6
        + used.ru_stime.tv_sec as f64
        + used.ru_stime.tv_usec as f64 / 1e6
}

fn append(path: &Path, text: &str) -> Result<()> {
    writeln!(
        std::fs::OpenOptions::new().append(true).open(path)?,
        "{}",
        json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":text}]}})
    )?;
    Ok(())
}

fn wait_text(store: &Store, thread: &str, text: &str, since: Instant) -> Result<f64> {
    loop {
        let found: bool = store.reader()?.query_row(
            "SELECT EXISTS(SELECT 1 FROM item WHERE session_key IN (SELECT session_key FROM session WHERE thread_id=?1) AND instr(text,?2)>0)",
            [thread, text],
            |r| r.get(0),
        )?;
        if found {
            return Ok(since.elapsed().as_secs_f64());
        }
        ensure!(
            since.elapsed() < Duration::from_secs(10),
            "Session update exceeded ten seconds"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

pub(super) fn run(store: &Store, origins: &[Origin], mode: &str) -> Result<()> {
    if mode == "active" {
        return active(store, origins);
    }
    ensure!(
        mode == "after",
        "The baseline uses its preserved executable"
    );
    let read_resolver_plan: Vec<String> = store
        .reader()?
        .prepare(&format!(
            "EXPLAIN QUERY PLAN {}",
            super::query::SESSION_TARGET_SQL
        ))?
        .query_map(["absent-session", "mini", "absent-session"], |row| {
            row.get(3)
        })?
        .collect::<rusqlite::Result<_>>()?;
    println!(
        "{}",
        json!({"phase":"readResolverPlan","steps":read_resolver_plan})
    );
    let suffix_plan: Vec<String> = store
        .reader()?
        .prepare(&format!(
            "EXPLAIN QUERY PLAN {}",
            super::query::THREAD_SUFFIX_SQL
        ))?
        .query_map(rusqlite::params!["mini", b"toor", b"toos"], |row| {
            row.get(3)
        })?
        .collect::<rusqlite::Result<_>>()?;
    let old_read_plan: Vec<String> = store.reader()?.prepare("EXPLAIN QUERY PLAN SELECT src.local_path,src.present FROM session s JOIN source src USING(source_id) WHERE s.session_key=?1 OR s.thread_id=?1 OR s.origin_host||':'||s.thread_id=?1 LIMIT 2")?.query_map(["absent-session"], |row| row.get(3))?.collect::<rusqlite::Result<_>>()?;
    println!(
        "{}",
        json!({"phase":"suffixPlan","steps":suffix_plan,"oldReadResolverPlan":old_read_plan})
    );
    let source_selection_plan: Vec<String> = store
        .reader()?
        .prepare(&format!(
            "EXPLAIN QUERY PLAN {}",
            ingest::SOURCE_SELECTION_SQL
        ))?
        .query_map(["mini", "/one", "/one/", "/one0"], |row| row.get(3))?
        .collect::<rusqlite::Result<_>>()?;
    println!(
        "{}",
        json!({"phase":"sourceSelectionPlan","steps":source_selection_plan})
    );
    let stop = AtomicBool::new(false);
    let cpu = cpu_seconds();
    let started = Instant::now();
    let mut discovery = Discovery::default();
    discovery.refresh(origins, None)?;
    let header_result = discovery.headers(&mut *store.writer()?, origins, &stop, None);
    let header_seconds = started.elapsed().as_secs_f64();
    let header_complete = header_result.is_ok();
    let directory_counts: serde_json::Map<String, serde_json::Value> = origins
        .iter()
        .map(|origin| {
            (
                origin.provider.clone(),
                json!(discovery.directory_count(origin)),
            )
        })
        .collect();
    println!(
        "{}",
        json!({"phase":"headers","elapsedSeconds":header_seconds,"complete":header_complete,"directories":directory_counts})
    );
    let header_cpu = cpu_seconds() - cpu;
    let mut discovery_times = Vec::new();
    for _ in 0..10 {
        let started = Instant::now();
        discovery.refresh(origins, Some(started + Duration::from_secs(5)))?;
        discovery_times.push(started.elapsed().as_secs_f64());
    }
    discovery_times.sort_by(f64::total_cmp);
    println!(
        "{}",
        json!({"phase":"directoryDiscovery","p95Seconds":discovery_times[9],"directories":directory_counts})
    );
    let cpu = cpu_seconds();
    let started = Instant::now();
    let initial = ingest::scan(store, origins, &stop)?;
    let initial_seconds = header_seconds + started.elapsed().as_secs_f64();
    let initial_cpu = header_cpu + cpu_seconds() - cpu;
    println!(
        "{}",
        json!({"phase":"initial","elapsedSeconds":initial_seconds,"cpuSeconds":initial_cpu,"outcome":initial})
    );
    let cpu = cpu_seconds();
    let started = Instant::now();
    let reconcile = ingest::scan(store, origins, &stop)?;
    let reconcile_seconds = started.elapsed().as_secs_f64();
    let reconcile_cpu = cpu_seconds() - cpu;
    let origin = origins.iter().find(|o| o.provider == "codex").unwrap();
    let cold = origin.path().join("fleet-idle-cold.jsonl");
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&cold)?;
    writeln!(
        file,
        "{}",
        json!({"type":"session_meta","payload":{"id":"fleet-idle-cold"}})
    )?;
    file.set_modified(UNIX_EPOCH + Duration::from_secs(1_600_000_000))?;
    drop(file);
    let prior: Option<String> =
        store
            .reader()?
            .query_row("SELECT max(indexed_through) FROM coverage", [], |r| {
                r.get(0)
            })?;
    let worker = Worker::start(store.clone(), origins.to_vec())?;
    let started = Instant::now();
    loop {
        let current: Option<String> =
            store
                .reader()?
                .query_row("SELECT max(indexed_through) FROM coverage", [], |r| {
                    r.get(0)
                })?;
        if current != prior {
            break;
        }
        ensure!(
            started.elapsed() < Duration::from_secs(120),
            "Initial reconciliation did not finish"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    std::thread::sleep(Duration::from_secs(2));
    let mut inventory_times = Vec::new();
    for _ in 0..10 {
        let started = Instant::now();
        ingest::refresh_inventory(store)?;
        inventory_times.push(started.elapsed().as_secs_f64());
    }
    inventory_times.sort_by(f64::total_cmp);
    let catalog_files = [
        store.path.clone(),
        store.path.with_extension("sqlite3-wal"),
        store.path.with_extension("sqlite3-shm"),
    ];
    let revisions = || -> Result<Vec<_>> {
        catalog_files
            .iter()
            .map(|path| match std::fs::metadata(path) {
                Ok(meta) => Ok(Some((meta.len(), meta.modified()?))),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(error) => Err(error.into()),
            })
            .collect()
    };
    let before = revisions()?;
    let started = Instant::now();
    let cpu = cpu_seconds();
    std::thread::sleep(Duration::from_secs(60));
    let elapsed = started.elapsed().as_secs_f64();
    let idle_cpu = cpu_seconds() - cpu;
    let after = revisions()?;
    ensure!(before == after, "Quiet catalog was written");
    let started = Instant::now();
    append(&cold, "fleetidleappendprobe")?;
    let append_seconds = wait_text(store, "fleet-idle-cold", "fleetidleappendprobe", started)?;
    let new = origin
        .path()
        .join("fleet-idle-new/nested/fleet-idle-new.jsonl");
    let started = Instant::now();
    std::fs::create_dir_all(new.parent().unwrap())?;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&new)?;
    writeln!(
        file,
        "{}",
        json!({"type":"session_meta","payload":{"id":"fleet-idle-new"}})
    )?;
    drop(file);
    append(&new, "fleetidlenewprobe")?;
    let new_seconds = wait_text(store, "fleet-idle-new", "fleetidlenewprobe", started)?;
    worker.stop()?;
    let report = json!({"phase":mode,"readResolverPlan":read_resolver_plan,"sourceSelectionPlan":source_selection_plan,"oldReadResolverPlan":old_read_plan,"suffixPlan":suffix_plan,"headerSeconds":header_seconds,"headerComplete":header_complete,"directories":directory_counts,"directoryDiscoveryP95Seconds":discovery_times[9],"inventoryCatchupP95Seconds":inventory_times[9],"initialSeconds":initial_seconds,"initialCpuSeconds":initial_cpu,"initial":initial,"reconcileSeconds":reconcile_seconds,"reconcileCpuSeconds":reconcile_cpu,"outcome":reconcile,"cpuSeconds":idle_cpu,"elapsedSeconds":elapsed,"cpuSecondsPerMinute":idle_cpu*60.0/elapsed,"amortizedReconcileCpuSecondsPerMinute":reconcile_cpu/10.0,"databaseWrittenDuringQuiet":false,"coldAppendSeconds":append_seconds,"newFileSeconds":new_seconds});
    std::fs::write(
        std::env::var("RC_SESSIONS_MEASURE_REPORT")?,
        serde_json::to_vec_pretty(&report)?,
    )?;
    println!("{report}");
    Ok(())
}

fn active(store: &Store, origins: &[Origin]) -> Result<()> {
    ensure!(
        origins.len() == 1 && origins[0].provider == "codex",
        "Active probe needs one isolated Codex origin"
    );
    let control = std::path::PathBuf::from(std::env::var("RC_SESSIONS_ACTIVE_CONTROL")?);
    std::fs::create_dir_all(&control)?;
    let path = origins[0].path().join("fleet-active.jsonl");
    std::fs::create_dir_all(path.parent().unwrap())?;
    let mut file = std::io::BufWriter::new(
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)?,
    );
    writeln!(
        file,
        "{}",
        json!({"type":"session_meta","payload":{"id":"fleet-active"}})
    )?;
    let padding = json!({"type":"measurement_padding","padding":"x".repeat(1 << 20)}).to_string();
    for _ in 0..200 {
        writeln!(file, "{padding}")?;
    }
    file.flush()?;
    drop(file);
    ingest::scan(store, origins, &AtomicBool::new(false))?;
    let prior: Option<String> =
        store
            .reader()?
            .query_row("SELECT max(indexed_through) FROM coverage", [], |row| {
                row.get(0)
            })?;
    let worker = Worker::start(store.clone(), origins.to_vec())?;
    let waiting = Instant::now();
    loop {
        let current: Option<String> =
            store
                .reader()?
                .query_row("SELECT max(indexed_through) FROM coverage", [], |row| {
                    row.get(0)
                })?;
        if current != prior {
            break;
        }
        ensure!(
            waiting.elapsed() < Duration::from_secs(30),
            "Active worker did not become ready"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let initial_bytes = path.metadata()?.len();
    let started = Instant::now();
    let cpu = cpu_seconds();
    std::fs::write(control.join("ready"), b"ready")?;
    while !control.join("done").exists() {
        ensure!(
            started.elapsed() < Duration::from_secs(90),
            "Active driver did not finish"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let elapsed = started.elapsed().as_secs_f64();
    let used = cpu_seconds() - cpu;
    worker.stop()?;
    let report = json!({"phase":"active","initialBytes":initial_bytes,"elapsedSeconds":elapsed,"cpuSeconds":used,"cpuSecondsPerMinute":used * 60.0 / elapsed});
    std::fs::write(
        std::env::var("RC_SESSIONS_MEASURE_REPORT")?,
        serde_json::to_vec_pretty(&report)?,
    )?;
    println!("{report}");
    Ok(())
}
