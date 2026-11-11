use super::{Origin, discovery::Discovery, hot::Hot, ingest, store::Store};
use anyhow::{Context, Result};
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::BTreeSet;
use std::ops::Bound::{Excluded, Included, Unbounded};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

const RECONCILE: Duration = Duration::from_secs(600);
const PENDING_PATHS: usize = 512;

#[derive(Default)]
struct Pending {
    paths: Vec<BTreeSet<PathBuf>>,
    inventory: Vec<InventoryRequest>,
    parents: Option<Arc<super::metadata::Parents>>,
    mirror: Option<MirrorRequest>,
}

struct InventoryRequest {
    deadline: Instant,
    reply: std::sync::mpsc::SyncSender<std::result::Result<(), String>>,
}

struct MirrorRequest {
    projection: super::mirror::Projection,
    reply: tokio::sync::oneshot::Sender<Result<bool>>,
}

pub(super) struct Mailbox {
    stop: Arc<AtomicBool>,
    wake: Arc<(Mutex<Pending>, Condvar)>,
    discovery: Mutex<(Vec<Origin>, Discovery)>,
}

impl Mailbox {
    pub(super) async fn project_mirror(
        &self,
        projection: super::mirror::Projection,
    ) -> Result<bool> {
        let (reply, result) = tokio::sync::oneshot::channel();
        {
            let mut pending = self.wake.0.lock().expect("Session worker wake poisoned");
            anyhow::ensure!(
                !self.stop.load(Ordering::Acquire),
                "unavailable: session worker stopped"
            );
            anyhow::ensure!(
                pending.mirror.is_none(),
                "capacity: a mirror projection is already pending"
            );
            pending.mirror = Some(MirrorRequest { projection, reply });
            self.wake.1.notify_one();
        }
        result
            .await
            .context("unavailable: session projection worker stopped")?
    }

    pub fn inventory(&self, store: &Store) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(5);
        anyhow::ensure!(
            !self.stop.load(Ordering::Acquire),
            "unavailable: session worker stopped"
        );
        if let Ok(mut current) = self.discovery.try_lock() {
            let (origins, discovery) = &mut *current;
            discovery.refresh(origins, Some(deadline))?;
            if !discovery.has_pending()
                || discovery.headers_present(&*store.reader()?, origins, deadline)?
            {
                return Ok(());
            }
        }
        let (reply, result) = std::sync::mpsc::sync_channel(1);
        let pending = self.wake.0.lock().expect("Session worker wake poisoned");
        let (mut pending, _) = self
            .wake
            .1
            .wait_timeout_while(
                pending,
                deadline.saturating_duration_since(Instant::now()),
                |pending| pending.inventory.len() >= 64 && !self.stop.load(Ordering::Acquire),
            )
            .expect("Session worker wake poisoned");
        anyhow::ensure!(
            !self.stop.load(Ordering::Acquire),
            "unavailable: session worker stopped"
        );
        anyhow::ensure!(
            pending.inventory.len() < 64 && Instant::now() < deadline,
            "unavailable: inventory catch-up exceeded five seconds"
        );
        pending.inventory.push(InventoryRequest { deadline, reply });
        self.wake.1.notify_all();
        drop(pending);
        result
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .context("unavailable: inventory catch-up exceeded five seconds")?
            .map_err(anyhow::Error::msg)
    }

    fn inventory_waiting(&self) -> bool {
        !self
            .wake
            .0
            .lock()
            .expect("Session worker wake poisoned")
            .inventory
            .is_empty()
    }

    fn requested(&self) -> bool {
        let pending = self.wake.0.lock().expect("Session worker wake poisoned");
        !pending.inventory.is_empty()
    }

    fn reconcile(&self, db: &mut rusqlite::Connection, origins: &[Origin]) -> Result<()> {
        let mut current = self.discovery.lock().expect("Session discovery poisoned");
        let (stored_origins, discovery) = &mut *current;
        stored_origins.clear();
        stored_origins.extend_from_slice(origins);
        discovery.reconcile();
        discovery.refresh(origins, None)?;
        if let Err(error) = discovery.headers(db, origins, &self.stop, None) {
            tracing::warn!(%error,"Session inventory has incomplete identities");
        }
        Ok(())
    }

    fn serve(&self, db: &mut rusqlite::Connection, origins: &[Origin]) {
        let requests = {
            let mut pending = self.wake.0.lock().expect("Session worker wake poisoned");
            let requests = std::mem::take(&mut pending.inventory);
            self.wake.1.notify_all();
            requests
        };
        let requests: Vec<_> = requests
            .into_iter()
            .filter(|request| request.deadline > Instant::now())
            .collect();
        let Some(deadline) = requests.iter().map(|request| request.deadline).max() else {
            return;
        };
        let result = (|| -> Result<()> {
            let mut current = self.discovery.lock().expect("Session discovery poisoned");
            let (_, discovery) = &mut *current;
            discovery.refresh(origins, Some(deadline))?;
            discovery.headers(db, origins, &self.stop, Some(deadline))
        })()
        .map_err(|error| format!("{error:#}"));
        for request in requests {
            let _ = request.reply.try_send(result.clone());
        }
    }
}

#[derive(Default)]
struct ParentProjection {
    unresolved: Arc<super::metadata::Parents>,
    generation: Option<i64>,
}

fn refresh_metadata(
    db: &rusqlite::Connection,
    origins: &[Origin],
    mailbox: &Mailbox,
    parents: &mut ParentProjection,
) -> Result<()> {
    super::metadata::titles(db, origins)?;
    parents.refresh(db, origins, mailbox)
}

fn settle_projection(
    db: &mut rusqlite::Connection,
    origins: &[Origin],
    mailbox: &Mailbox,
    parents: &mut ParentProjection,
) -> Result<Option<Instant>> {
    refresh_metadata(db, origins, mailbox, parents)?;
    super::index::drain(db, &mailbox.stop, &mut |db| {
        mailbox.serve(db, origins);
        Ok(())
    })
}

impl ParentProjection {
    fn refresh(
        &mut self,
        db: &rusqlite::Connection,
        origins: &[Origin],
        mailbox: &Mailbox,
    ) -> Result<()> {
        let pending = mailbox
            .wake
            .0
            .lock()
            .expect("Session worker wake poisoned")
            .parents
            .take();
        if let Some(pending) = pending {
            self.unresolved = pending;
            self.generation = None;
        }
        if self.unresolved.is_empty() {
            return Ok(());
        }
        let generation = super::metadata::identity_generation(db)?;
        if self.generation != Some(generation) {
            self.unresolved = Arc::new(super::metadata::parents(db, origins, &self.unresolved)?);
            self.generation = Some(generation);
        }
        Ok(())
    }
}

impl Pending {
    fn include(&mut self, index: usize, root: &Path, path: PathBuf) {
        if self.paths.len() <= index {
            self.paths.resize_with(index + 1, BTreeSet::new);
        }
        let paths = &mut self.paths[index];
        if path.ancestors().any(|parent| paths.contains(parent)) {
            return;
        }
        let end = paths
            .range(path.clone()..)
            .find(|child| !child.starts_with(&path))
            .cloned();
        paths
            .extract_if(
                (Included(path.clone()), end.map_or(Unbounded, Excluded)),
                |_| true,
            )
            .for_each(drop);
        paths.insert(path);
        if paths.len() > PENDING_PATHS {
            let mut common = paths.first().expect("Pending path was inserted").clone();
            let last = paths.last().expect("Pending path was inserted");
            while !last.starts_with(&common) && common != root {
                common.pop();
            }
            debug_assert!(common.starts_with(root));
            paths.clear();
            paths.insert(common);
        }
    }

    fn event(&mut self, origins: &[Origin], event: notify::Result<Event>) {
        let event = match event {
            Ok(event) => event,
            Err(error) => {
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
                if origin.provider == "codex"
                    && path == &origin.local_home.join("session_index.jsonl")
                {
                    if self.paths.len() <= i {
                        self.paths.resize_with(i + 1, BTreeSet::new);
                    }
                    self.paths[i].insert(path.clone());
                } else if path.starts_with(&root) {
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
        self.paths.iter().all(BTreeSet::is_empty)
            && self.inventory.is_empty()
            && self.parents.is_none()
            && self.mirror.is_none()
    }
    fn take(&mut self) -> Vec<BTreeSet<PathBuf>> {
        std::mem::take(&mut self.paths)
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
        origin.local_home = local;
        if origin.path().is_dir() {
            roots.insert(origin.path());
        }
    }
    let observed = origins.to_vec();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<Event>| {
        if let Err(error) = &event {
            tracing::warn!(%error,"Session filesystem events require reconciliation");
        }
        let mut pending = wake.0.lock().expect("Session worker wake poisoned");
        pending.event(&observed, event);
        if !pending.is_empty() {
            wake.1.notify_one();
        }
    })?;
    for root in roots {
        watcher.watch(&root, RecursiveMode::Recursive)?;
    }
    for origin in origins
        .iter()
        .filter(|o| o.provider == "codex" && o.local_home.is_dir())
    {
        watcher.watch(&origin.local_home, RecursiveMode::NonRecursive)?;
    }
    Ok(watcher)
}

impl Worker {
    pub(crate) fn parents(&self, parents: Arc<super::metadata::Parents>) {
        self.wake
            .0
            .lock()
            .expect("Session worker wake poisoned")
            .parents = Some(parents);
        self.wake.1.notify_one();
    }

    pub fn start(
        store: Store,
        mut origins: Vec<Origin>,
        skills: Vec<PathBuf>,
        cap_status: PathBuf,
    ) -> Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let wake = Arc::new((Mutex::new(Pending::default()), Condvar::new()));
        let mailbox = Arc::new(Mailbox {
            stop: stop.clone(),
            wake: wake.clone(),
            discovery: Mutex::new((origins.clone(), Discovery::default())),
        });
        let endpoint = mailbox.clone();
        let registration = store.worker.clone();
        registration
            .set(mailbox)
            .map_err(|_| anyhow::anyhow!("Session worker is already registered"))?;
        let flag = stop.clone();
        let signal = wake.clone();
        let thread = std::thread::Builder::new()
            .name("sessions-ingest".into())
            .spawn(move || {
                let mut _watcher = None;
                let mut hot = Hot::default();
                let mut parent_projection = ParentProjection::default();
                let mut next_hot = Instant::now();
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
                let mut next_document: Option<Instant> = None;
                let mut search_installed = false;
                let mut retry_delay = Duration::from_secs(2);
                while !flag.load(Ordering::Acquire) {
                    let mut pending = signal.0.lock().expect("Session worker wake poisoned");
                    let deadline = next_reconcile
                        .min(next_document.unwrap_or(next_reconcile))
                        .min(if hot.is_empty() {
                            next_reconcile
                        } else {
                            next_hot
                        });
                    pending = signal
                        .1
                        .wait_timeout_while(
                            pending,
                            deadline.saturating_duration_since(Instant::now()),
                            |p| p.is_empty() && !flag.load(Ordering::Acquire),
                        )
                        .expect("Session worker wake poisoned")
                        .0;
                    if flag.load(Ordering::Acquire) {
                        break;
                    }
                    let full = Instant::now() >= next_reconcile;
                    let parent_update = pending.parents.is_some();
                    let mirror = pending.mirror.take();
                    let batches = pending.take();
                    drop(pending);
                    let mut paths: Vec<_> = batches.into_iter().flatten().collect();
                    let result: Result<serde_json::Value> = (|| {
                        if !search_installed {
                            super::index::open(&*store.writer()?)?;
                            search_installed = true;
                        }
                        if !hot.is_empty() && Instant::now() >= next_hot {
                            paths.extend(hot.changed()?);
                            next_hot = Instant::now() + Duration::from_secs(1);
                        }
                        if !full && paths.is_empty() && !endpoint.requested() {
                            if parent_update || next_document.is_some_and(|at| Instant::now() >= at)
                            {
                                let mut db = store.writer()?;
                                next_document = settle_projection(
                                    &mut db,
                                    &origins,
                                    &endpoint,
                                    &mut parent_projection,
                                )?;
                            }
                            return Ok(serde_json::json!({"ingested":0,"parseFailures":0}));
                        }
                        let scope = if full {
                            ingest::Scope::Full
                        } else {
                            ingest::Scope::Changed(&paths)
                        };
                        if full {
                            _watcher = Some(watch(&mut origins, signal.clone())?);
                            let mut db = store.writer()?;
                            endpoint.reconcile(&mut db, &origins)?;
                            refresh_metadata(&db, &origins, &endpoint, &mut parent_projection)?;
                            endpoint.serve(&mut db, &origins);
                            hot.observe(&db, &origins)?;
                        } else if endpoint.requested() {
                            let mut db = store.writer()?;
                            endpoint.serve(&mut db, &origins);
                            hot.observe(&db, &origins)?;
                        }
                        let outcome = ingest::scan_serving(
                            &store,
                            &origins,
                            scope,
                            &flag,
                            &|| endpoint.inventory_waiting(),
                            &mut |db| {
                                if endpoint.requested() {
                                    endpoint.serve(db, &origins);
                                    hot.observe(db, &origins)?;
                                }
                                Ok(())
                            },
                        )?;
                        {
                            let mut db = store.writer()?;
                            next_document = settle_projection(
                                &mut db,
                                &origins,
                                &endpoint,
                                &mut parent_projection,
                            )?;
                        }
                        hot.observe(&*store.reader()?, &origins)?;
                        if full && outcome["cancelled"] != true {
                            ingest::mark_ready(&*store.writer()?)?;
                        }
                        Ok(outcome)
                    })();
                    if let Some(MirrorRequest { projection, reply }) = mirror {
                        let result = (|| {
                            anyhow::ensure!(
                                search_installed,
                                "unavailable: session search indexes are initializing"
                            );
                            let projected = projection.apply(
                                &store,
                                &flag,
                                &|| endpoint.inventory_waiting(),
                                &mut |db| {
                                    if endpoint.requested() {
                                        endpoint.serve(db, &origins);
                                    }
                                    Ok(())
                                },
                            )?;
                            let mut db = store.writer()?;
                            next_document = settle_projection(
                                &mut db,
                                &origins,
                                &endpoint,
                                &mut parent_projection,
                            )?;
                            Ok(projected)
                        })();
                        let _ = reply.send(result);
                    }
                    if full && let Err(error) = store.storage.publish_cap(&cap_status) {
                        tracing::warn!(%error,"Session disk cap status unavailable");
                    }
                    match result {
                        Ok(_) => {
                            retry_delay = Duration::from_secs(2);
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
                            if full {
                                next_reconcile = Instant::now() + retry_delay;
                            }
                            let failure = format!("{error:#}");
                            for request in std::mem::take(&mut pending.inventory) {
                                let _ = request.reply.try_send(Err(failure.clone()));
                            }
                            let _pending = signal
                                .1
                                .wait_timeout_while(pending, retry_delay, |pending| {
                                    pending.inventory.is_empty() && !flag.load(Ordering::Acquire)
                                })
                                .expect("Session worker wake poisoned");
                            retry_delay = (retry_delay * 2).min(RECONCILE);
                        }
                    }
                }
            })
            .map_err(|error| {
                stop.store(true, Ordering::Release);
                anyhow::anyhow!(error).context("Cannot start session ingest worker")
            })?;
        Ok(Self {
            stop,
            wake,
            thread: Mutex::new(Some(thread)),
        })
    }

    fn request_stop(&self) {
        let mut pending = self.wake.0.lock().expect("Session worker wake poisoned");
        self.stop.store(true, Ordering::Release);
        let requests = std::mem::take(&mut pending.inventory);
        pending.mirror.take();
        self.wake.1.notify_all();
        drop(pending);
        for request in requests {
            let _ = request
                .reply
                .try_send(Err("unavailable: session worker stopped".into()));
        }
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
        let store = Store::open(
            directory.path().join("state/catalog.sqlite3"),
            super::super::storage::Capacity::Fixed {
                free_bytes: 1 << 40,
            },
        )
        .unwrap();
        super::super::index::open(&*store.writer().unwrap()).unwrap();
        (directory, store, origin, path)
    }

    #[test]
    fn sessions_hot_sources_match_their_catalog_identity() -> Result<()> {
        let (_directory, store, origin, path) = fixture();
        std::fs::File::open(&path)?.set_modified(std::time::SystemTime::now())?;
        let origins = [origin];
        ingest::scan(&store, &origins, &AtomicBool::new(false))?;
        let mut hot = Hot::default();
        hot.observe(&*store.reader()?, &origins)?;
        ensure!(!hot.is_empty());
        ensure!(hot.changed()?.is_empty());
        Ok(())
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
            pending.paths[0],
            BTreeSet::from([origin.path().join("subtree")])
        );
        assert_eq!(pending.paths[1], BTreeSet::from([other.path()]));
        pending.event(
            &origins,
            Ok(Event::new(EventKind::Other)
                .add_path(origin.local_home.clone())
                .set_flag(notify::event::Flag::Rescan)),
        );
        assert_eq!(pending.paths[0], BTreeSet::from([origin.path()]));
        let paths: Vec<_> = pending.take().into_iter().flatten().collect();
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
        ))?;
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
        let paths: Vec<_> = pending.take().into_iter().flatten().collect();
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
        let (directory, store, origin, path) = fixture();
        let worker = Worker::start(
            store.clone(),
            vec![origin.clone()],
            Vec::new(),
            directory.path().join("disk-cap-status.json"),
        )?;
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
    #[test]
    fn sessions_hot_worker_observes_appends_while_the_writer_fd_stays_open() -> Result<()> {
        let (directory, store, origin, path) = fixture();
        std::fs::File::open(&path)?.set_modified(std::time::SystemTime::now())?;
        let status = directory.path().join("disk-cap-status.json");
        let worker = Worker::start(store.clone(), vec![origin], Vec::new(), status.clone())?;
        let deadline = Instant::now() + Duration::from_secs(60);
        while !status.exists() {
            ensure!(Instant::now() < deadline, "Initial source did not finish");
            std::thread::sleep(Duration::from_millis(10));
        }
        std::fs::remove_file(&status)?;
        let mut file = std::fs::OpenOptions::new().append(true).open(path)?;
        writeln!(
            file,
            "{}",
            json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"stillopenappend"}]}})
        )?;
        file.flush()?;
        wait_text(&store, "stillopenappend");
        ensure!(!status.exists(), "Hot append waited for a full reconcile");
        worker.stop()?;
        drop(file);
        Ok(())
    }

    #[test]
    fn sessions_concurrent_inventory_coalesces_during_content_ingest() -> Result<()> {
        const CALLERS: usize = 8;
        let (_directory, store, origin, path) = fixture();
        let other = origin.path().join("other.jsonl");
        std::fs::write(
            &other,
            format!(
                "{}\n",
                json!({"type":"session_meta","payload":{"id":"other"}})
            ),
        )?;
        append(&path, "activeingest");
        let stop = Arc::new(AtomicBool::new(false));
        let wake = Arc::new((Mutex::new(Pending::default()), Condvar::new()));
        let mailbox = Arc::new(Mailbox {
            stop,
            wake: wake.clone(),
            discovery: Mutex::new((vec![origin.clone()], Discovery::default())),
        });
        store
            .worker
            .set(mailbox.clone())
            .map_err(|_| anyhow::anyhow!("Fixture already registered"))?;
        mailbox.reconcile(&mut *store.writer()?, std::slice::from_ref(&origin))?;
        let (entered_tx, entered_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let (read_tx, read_rx) = std::sync::mpsc::channel();
        std::thread::scope(|scope| -> Result<()> {
            let writer_store = &store;
            let writer_origin = &origin;
            let writer_mailbox = &mailbox;
            let writer = scope.spawn(move || -> Result<()> {
                let mut first = true;
                ingest::scan_serving(
                    writer_store,
                    std::slice::from_ref(writer_origin),
                    ingest::Scope::Full,
                    &writer_mailbox.stop,
                    &|| false,
                    &mut |db| {
                        if first {
                            first = false;
                            entered_tx.send(())?;
                            release_rx.recv_timeout(Duration::from_secs(5))?;
                            writer_mailbox.serve(db, std::slice::from_ref(writer_origin));
                            for _ in 0..CALLERS {
                                read_rx.recv_timeout(Duration::from_secs(5))?;
                            }
                        }
                        Ok(())
                    },
                )?;
                Ok(())
            });
            entered_rx.recv_timeout(Duration::from_secs(5))?;
            ingest::refresh_inventory(&store)?;
            let new = origin.path().join("2026/10/28/just-created.jsonl");
            std::fs::create_dir_all(new.parent().unwrap())?;
            std::fs::write(
                &new,
                format!(
                    "{}\n",
                    json!({"type":"session_meta","payload":{"id":"just-created"}})
                ),
            )?;
            let mut readers = Vec::new();
            for _ in 0..CALLERS {
                let store = &store;
                let read_tx = read_tx.clone();
                readers.push(scope.spawn(move || -> Result<()> {
                    ingest::refresh_inventory(store)?;
                    let page = super::super::query::inventory(&store.reader()?, None, 1000)?;
                    assert!(
                        page.sessions
                            .iter()
                            .any(|header| header.thread_id == "just-created")
                    );
                    read_tx.send(())?;
                    Ok(())
                }));
            }
            let pending = wake.0.lock().unwrap();
            let (pending, _) = wake
                .1
                .wait_timeout_while(pending, Duration::from_secs(5), |pending| {
                    pending.inventory.len() != CALLERS
                })
                .unwrap();
            assert_eq!(pending.inventory.len(), CALLERS);
            drop(pending);
            release_tx.send(())?;
            for reader in readers {
                reader.join().unwrap()?;
            }
            writer.join().unwrap()?;
            Ok(())
        })?;
        assert!(!mailbox.requested());
        Ok(())
    }
}
