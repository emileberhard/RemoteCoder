use super::{Origin, ingest, store::Store};
use anyhow::{Context, Result};
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

const RECONCILE: Duration = Duration::from_secs(600);
const PENDING_PATHS: usize = 512;

#[derive(Default)]
struct Pending(Vec<BTreeSet<PathBuf>>);

impl Pending {
    fn include(&mut self, index: usize, root: &Path, path: PathBuf) {
        if self.0.len() <= index {
            self.0.resize_with(index + 1, BTreeSet::new);
        }
        let paths = &mut self.0[index];
        if paths.iter().any(|parent| path.starts_with(parent)) {
            return;
        }
        paths.retain(|child| !child.starts_with(&path));
        paths.insert(path);
        if paths.len() > PENDING_PATHS {
            let mut common = paths.first().expect("Pending path was inserted").clone();
            for path in paths.iter() {
                while !path.starts_with(&common) && common != root {
                    common.pop();
                }
            }
            assert!(common.starts_with(root));
            paths.clear();
            paths.insert(common);
        }
    }

    fn event(&mut self, origins: &[Origin], event: notify::Result<Event>) {
        let event = match event {
            Ok(event) => event,
            Err(error) => {
                tracing::warn!(%error,"Session filesystem events require reconciliation");
                let mut recovery =
                    Event::new(EventKind::Other).set_flag(notify::event::Flag::Rescan);
                recovery.paths = error.paths;
                recovery
            }
        };
        if matches!(event.kind, EventKind::Access(_)) && !event.need_rescan() {
            return;
        }
        if event.paths.is_empty() && event.need_rescan() {
            for (i, origin) in origins.iter().enumerate() {
                self.include(i, &origin.path(), origin.path());
            }
        }
        for path in &event.paths {
            for (i, origin) in origins.iter().enumerate() {
                let root = origin.path();
                if path.starts_with(&root) {
                    self.include(i, &root, path.clone());
                } else if root.starts_with(path)
                    && (event.need_rescan()
                        || matches!(
                            event.kind,
                            EventKind::Remove(_)
                                | EventKind::Modify(notify::event::ModifyKind::Name(_))
                        ))
                {
                    self.include(i, &root, root.clone());
                }
            }
        }
    }

    fn is_empty(&self) -> bool {
        self.0.iter().all(BTreeSet::is_empty)
    }
    fn take(&mut self) -> Vec<PathBuf> {
        self.0.iter_mut().flat_map(std::mem::take).collect()
    }
}

pub(crate) struct Worker {
    stop: Arc<AtomicBool>,
    wake: Arc<(Mutex<Pending>, Condvar)>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

fn watch(
    origins: &mut [Origin],
    wake: Arc<(Mutex<Pending>, Condvar)>,
) -> Result<RecommendedWatcher> {
    let mut roots = BTreeSet::new();
    for origin in origins.iter_mut() {
        let existing = origin
            .local_home
            .ancestors()
            .find(|p| p.is_dir())
            .context("Provider home has no accessible ancestor")?;
        let canonical = std::fs::canonicalize(existing)?;
        let relative = origin.local_home.strip_prefix(existing)?;
        let local = canonical.join(relative);
        roots.insert(canonical);
        origin.local_home = local;
    }
    let observed = origins.to_vec();
    let mut watcher = notify::recommended_watcher(move |event| {
        let mut pending = wake.0.lock().expect("Session worker wake poisoned");
        pending.event(&observed, event);
        if !pending.is_empty() {
            wake.1.notify_one();
        }
    })?;
    for root in roots {
        watcher.watch(&root, RecursiveMode::Recursive)?;
    }
    Ok(watcher)
}

impl Worker {
    pub fn start(store: Store, mut origins: Vec<Origin>) -> Result<Self> {
        let home = crate::config::HostPaths::from_env()?.home().to_owned();
        let mut skills = vec![home.join(".agents/skills")];
        skills.extend(
            origins
                .iter()
                .filter(|o| o.provider == "claude")
                .map(|o| o.local_home.join("skills")),
        );
        let stop = Arc::new(AtomicBool::new(false));
        let wake = Arc::new((Mutex::new(Pending::default()), Condvar::new()));
        let watcher = watch(&mut origins, wake.clone())?;
        let flag = stop.clone();
        let signal = wake.clone();
        let thread = std::thread::Builder::new()
            .name("sessions-ingest".into())
            .spawn(move || {
                let _watcher = watcher;
                #[cfg(target_os = "macos")]
                if unsafe {
                    libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_UTILITY, 0)
                } != 0
                {
                    tracing::warn!("Session worker cannot enter utility QoS; ingestion stopped");
                    return;
                }
                if let Err(error) = store.writer().and_then(|db| ingest::catalog(&db, &skills)) {
                    tracing::warn!(%error,"Session skill catalog unavailable");
                }
                let mut next_reconcile = Instant::now();
                while !flag.load(Ordering::Acquire) {
                    let mut pending = signal.0.lock().expect("Session worker wake poisoned");
                    pending = signal
                        .1
                        .wait_timeout_while(
                            pending,
                            next_reconcile.saturating_duration_since(Instant::now()),
                            |p| p.is_empty() && !flag.load(Ordering::Acquire),
                        )
                        .expect("Session worker wake poisoned")
                        .0;
                    if flag.load(Ordering::Acquire) {
                        break;
                    }
                    let full = Instant::now() >= next_reconcile;
                    let paths = pending.take();
                    drop(pending);
                    let scope = if full {
                        ingest::Scope::Full
                    } else {
                        ingest::Scope::Changed(&paths)
                    };
                    match ingest::scan_scope(&store, &origins, scope, &flag) {
                        Ok(_) => {
                            if full {
                                next_reconcile = Instant::now() + RECONCILE;
                            }
                        }
                        Err(error) => {
                            tracing::warn!(%error,"Session ingestion unavailable");
                            let mut pending =
                                signal.0.lock().expect("Session worker wake poisoned");
                            for (i, origin) in origins.iter().enumerate() {
                                for path in &paths {
                                    if path.starts_with(origin.path()) {
                                        pending.include(i, &origin.path(), path.clone());
                                    }
                                }
                            }
                            let _pending = signal
                                .1
                                .wait_timeout_while(pending, Duration::from_secs(2), |_| {
                                    !flag.load(Ordering::Acquire)
                                })
                                .expect("Session worker wake poisoned");
                        }
                    }
                }
            })
            .context("Cannot start session ingest worker")?;
        Ok(Self {
            stop,
            wake,
            thread: Mutex::new(Some(thread)),
        })
    }

    fn request_stop(&self) {
        let _pending = self.wake.0.lock().expect("Session worker wake poisoned");
        self.stop.store(true, Ordering::Release);
        self.wake.1.notify_all();
    }

    pub fn stop(&self) -> Result<()> {
        self.request_stop();
        let thread = self.thread.lock().expect("Session worker poisoned").take();
        if let Some(thread) = thread {
            thread
                .join()
                .map_err(|_| anyhow::anyhow!("Session ingest worker panicked"))?;
        }
        Ok(())
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        self.request_stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::ensure;
    use rusqlite::hooks::Action;
    use serde_json::json;
    use std::io::Write;

    fn fixture() -> (tempfile::TempDir, Store, Origin, PathBuf) {
        let directory = tempfile::tempdir().unwrap();
        let home = directory.path().join(".codex");
        std::fs::create_dir_all(home.join("sessions")).unwrap();
        let home = std::fs::canonicalize(home).unwrap();
        let origin = Origin {
            host: "fixture".into(),
            provider: "codex".into(),
            provider_home: home.clone(),
            local_home: home,
        };
        let path = origin.path().join("cold.jsonl");
        std::fs::write(
            &path,
            format!(
                "{}\n",
                json!({"type":"session_meta","payload":{"id":"cold"}})
            ),
        )
        .unwrap();
        std::fs::File::open(&path)
            .unwrap()
            .set_modified(std::time::UNIX_EPOCH + Duration::from_secs(1_600_000_000))
            .unwrap();
        let store = Store::open(directory.path().join("state/catalog.sqlite3")).unwrap();
        (directory, store, origin, path)
    }

    fn append(path: &Path, needle: &str) {
        writeln!(std::fs::OpenOptions::new().append(true).open(path).unwrap(),"{}",json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":needle}]}})).unwrap();
    }

    fn wait_text(store: &Store, needle: &str) -> Duration {
        let started = Instant::now();
        loop {
            let found: bool = store
                .reader()
                .unwrap()
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM item WHERE instr(text,?1)>0)",
                    [needle],
                    |r| r.get(0),
                )
                .unwrap();
            if found {
                return started.elapsed();
            }
            assert!(
                started.elapsed() < Duration::from_secs(10),
                "Session update exceeded ten seconds"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn sessions_events_bound_each_origin_and_keep_rescan_subtrees() {
        let (_directory, _store, origin, _path) = fixture();
        let mut other = origin.clone();
        other.local_home = other.local_home.with_file_name(".claude");
        other.provider = "claude".into();
        let origins = [origin.clone(), other.clone()];
        let mut pending = Pending::default();
        pending.event(
            &origins,
            Ok(Event::new(EventKind::Other)
                .add_path(other.path())
                .set_flag(notify::event::Flag::Rescan)),
        );
        for i in 0..=PENDING_PATHS {
            pending.event(
                &origins,
                Ok(Event::new(EventKind::Any)
                    .add_path(origin.path().join(format!("subtree/{i}.jsonl")))),
            );
        }
        assert_eq!(
            pending.0[0],
            BTreeSet::from([origin.path().join("subtree")])
        );
        assert_eq!(pending.0[1], BTreeSet::from([other.path()]));
        pending.event(
            &origins,
            Ok(Event::new(EventKind::Other)
                .add_path(origin.local_home.clone())
                .set_flag(notify::event::Flag::Rescan)),
        );
        assert_eq!(pending.0[0], BTreeSet::from([origin.path()]));
        let paths = pending.take();
        assert_eq!(paths.len(), 2);
        assert!(pending.is_empty());
    }

    #[test]
    fn sessions_watcher_retains_an_append_during_the_initial_scan() -> Result<()> {
        let (_directory, store, mut origin, path) = fixture();
        let wake = Arc::new((Mutex::new(Pending::default()), Condvar::new()));
        let _watcher = watch(std::slice::from_mut(&mut origin), wake.clone())?;
        let mut db = store.writer()?;
        let injected = Arc::new(AtomicBool::new(false));
        let once = injected.clone();
        let target = path.clone();
        db.update_hook(Some(
            move |action: Action, _database: &str, table: &str, _row: i64| {
                if action == Action::SQLITE_INSERT
                    && table == "session"
                    && !once.swap(true, Ordering::SeqCst)
                {
                    append(&target, "duringinitialscan");
                }
            },
        ));
        ingest::ingest(&mut db, &origin, &path, &AtomicBool::new(false))?;
        assert!(injected.load(Ordering::SeqCst));
        drop(db);
        let pending = wake.0.lock().unwrap();
        let (mut pending, _) = wake
            .1
            .wait_timeout_while(pending, Duration::from_secs(10), |p| p.is_empty())
            .unwrap();
        ensure!(
            !pending.is_empty(),
            "Append during ingestion was not queued"
        );
        let paths = pending.take();
        drop(pending);
        ingest::scan_scope(
            &store,
            &[origin],
            ingest::Scope::Changed(&paths),
            &AtomicBool::new(false),
        )?;
        let found: bool = store.reader()?.query_row(
            "SELECT EXISTS(SELECT 1 FROM item WHERE text='duringinitialscan')",
            [],
            |r| r.get(0),
        )?;
        assert!(found);
        Ok(())
    }

    #[test]
    fn sessions_worker_follows_cold_appends_and_new_directories() -> Result<()> {
        let (_directory, store, origin, path) = fixture();
        let worker = Worker::start(store.clone(), vec![origin.clone()])?;
        let deadline = Instant::now() + Duration::from_secs(10);
        while store
            .reader()?
            .query_row("SELECT count(*) FROM session", [], |r| r.get::<_, i64>(0))?
            == 0
        {
            ensure!(Instant::now() < deadline, "Initial session did not appear");
            std::thread::sleep(Duration::from_millis(10));
        }
        append(&path, "resumedcoldsession");
        assert!(wait_text(&store, "resumedcoldsession") < Duration::from_secs(10));
        let new = origin.path().join("new/nested/new.jsonl");
        std::fs::create_dir_all(new.parent().unwrap())?;
        std::fs::write(
            &new,
            format!(
                "{}\n",
                json!({"type":"session_meta","payload":{"id":"new"}})
            ),
        )?;
        append(&new, "newsessionevent");
        assert!(wait_text(&store, "newsessionevent") < Duration::from_secs(10));
        worker.stop()?;
        Ok(())
    }
}
