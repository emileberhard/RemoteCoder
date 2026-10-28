use super::{Origin, store::Store};
use anyhow::{Context, Result};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

pub(crate) struct Worker {
    stop: Arc<AtomicBool>,
    wake: Arc<(Mutex<()>, Condvar)>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl Worker {
    pub fn start(store: Store, origins: Vec<Origin>, skills: std::path::PathBuf) -> Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let wake = Arc::new((Mutex::new(()), Condvar::new()));
        let flag = stop.clone();
        let signal = wake.clone();
        let thread = std::thread::Builder::new()
            .name("sessions-ingest".into())
            .spawn(move || {
                if let Err(error) = store
                    .writer()
                    .and_then(|db| super::ingest::catalog(&db, &skills))
                {
                    tracing::warn!(%error,"Session skill catalog unavailable");
                }
                while !flag.load(Ordering::Acquire) {
                    if let Err(error) = super::ingest::scan(&store, &origins, &flag) {
                        tracing::warn!(%error,"Session ingestion unavailable");
                    }
                    let guard = signal.0.lock().expect("Session worker wake poisoned");
                    let _guard = signal
                        .1
                        .wait_timeout_while(guard, Duration::from_secs(2), |_| {
                            !flag.load(Ordering::Acquire)
                        })
                        .expect("Session worker wake poisoned");
                }
            })
            .context("Cannot start session ingest worker")?;
        Ok(Self {
            stop,
            wake,
            thread: Mutex::new(Some(thread)),
        })
    }

    pub fn stop(&self) -> Result<()> {
        self.stop.store(true, Ordering::Release);
        self.wake.1.notify_all();
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
        self.stop.store(true, Ordering::Release);
        self.wake.1.notify_all();
    }
}
