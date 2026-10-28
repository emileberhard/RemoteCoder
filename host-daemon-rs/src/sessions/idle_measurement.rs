use super::{Origin, ingest, store::Store, worker::Worker};
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
    ensure!(
        mode == "after",
        "The baseline uses its preserved executable"
    );
    let stop = AtomicBool::new(false);
    let cpu = cpu_seconds();
    let started = Instant::now();
    let initial = ingest::scan(store, origins, &stop)?;
    let initial_seconds = started.elapsed().as_secs_f64();
    let initial_cpu = cpu_seconds() - cpu;
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
    let report = json!({"phase":mode,"initialSeconds":initial_seconds,"initialCpuSeconds":initial_cpu,"initial":initial,"reconcileSeconds":reconcile_seconds,"reconcileCpuSeconds":reconcile_cpu,"outcome":reconcile,"cpuSeconds":idle_cpu,"elapsedSeconds":elapsed,"cpuSecondsPerMinute":idle_cpu*60.0/elapsed,"amortizedReconcileCpuSecondsPerMinute":reconcile_cpu/10.0,"databaseWrittenDuringQuiet":false,"coldAppendSeconds":append_seconds,"newFileSeconds":new_seconds});
    std::fs::write(
        std::env::var("RC_SESSIONS_MEASURE_REPORT")?,
        serde_json::to_vec_pretty(&report)?,
    )?;
    println!("{report}");
    Ok(())
}
