//! Host-side store for files the app clients attach to a message.
//!
//! Neither provider accepts an arbitrary file as message content, so a file
//! becomes useful to the agent only once it exists on the host as a real file
//! the model can read, convert, run or move. The app streams it here, the
//! gateway lands it under `~/.remote-coder/uploads/<upload id>/<name>`, and the
//! message carries that absolute path in plain text. Keeping uploads out of the
//! working directory keeps worktrees clean and commits accidental-free.
//!
//! An upload is named by the client's id. Its bytes arrive in one or more
//! appends at the upload's current offset, so a transfer interrupted by a lost
//! network, a route change, a suspended app or a gateway restart continues from
//! the bytes already on disk instead of starting over. The partial file is the
//! source of truth: each chunk is written, hashed and counted in one
//! synchronous step, so wherever an append stops, the offset and the running
//! digest describe exactly the bytes in the file, and any doubt sends both back
//! to the file. Blocking work holds the upload's writer lock until it ends, so
//! a newer append or a discard never overlaps it.
//!
//! The store owns the one thing that arrives from the network and must not be
//! trusted: the file name. It becomes a single safe path component that a model
//! can paste into a shell command unquoted. Bodies are opaque and verified
//! against the declared length and SHA-256 before they get a name.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use axum::body::Bytes;
use futures_util::{FutureExt, Stream, StreamExt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::{OwnedMutexGuard, Semaphore};
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

/// One file may not exceed this. Phone videos run to several gigabytes.
const MAX_UPLOAD_BYTES: u64 = 32 * 1024 * 1024 * 1024;
/// Everything the store holds at once: finished files, partial files and the
/// bytes unfinished uploads still need. Reaching it evicts idle unfinished
/// uploads, then the oldest finished ones before their retention ends.
const MAX_STORE_BYTES: u64 = 64 * 1024 * 1024 * 1024;
/// Free space the host must keep once every admitted upload has landed. The
/// Mini's data volume has run at 99% before; an upload must never be what
/// pushes it over.
const MIN_FREE_BYTES_AFTER_WRITE: u64 = 2 * 1024 * 1024 * 1024;
/// Uploads outlive the message that carried them so later turns and other
/// clients can keep using the file, but not forever.
const RETENTION: Duration = Duration::from_secs(30 * 24 * 60 * 60);
/// An unfinished upload nobody continued for this long is abandoned.
const INCOMPLETE_RETENTION: Duration = Duration::from_secs(7 * 24 * 60 * 60);
/// Unfinished uploads kept at once. Each holds disk space until it finishes,
/// so a client that starts many and finishes none must not pile them up.
const MAX_INCOMPLETE: usize = 32;
/// Appends streaming at once. Each holds an open file and a hasher.
const MAX_WRITERS: usize = 8;
/// An unfinished upload unclaimed this long is the first to go when a new
/// upload needs its room.
const SESSION_IDLE_EVICTION: Duration = Duration::from_secs(60 * 60);
/// Body bytes gathered before one blocking write, so disk and hashing work
/// stays off the async runtime.
const WRITE_BATCH_BYTES: usize = 1024 * 1024;
/// How long the body may go without a byte before the append ends. A client
/// lost with its tunnel never closes the connection, and there is deliberately
/// no cap on the transfer's total duration.
const BODY_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
/// Longest file name kept; the extension is preserved inside this budget.
const MAX_NAME_LENGTH: usize = 128;
/// Filesystems bound a name in bytes, and letters outside ASCII take several.
const MAX_NAME_BYTES: usize = 255;
/// Anything longer after the last dot is not an extension worth preserving.
const MAX_EXTENSION_LENGTH: usize = 16;
const PARTIAL_NAME: &str = ".partial";
const SESSION_NAME: &str = ".session";

/// A rejected or interrupted append, and the reason to hand back to the client.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum UploadError {
    InvalidId,
    /// The name was missing, empty, or reduces to nothing usable.
    InvalidName,
    /// The declared length is zero or over `MAX_UPLOAD_BYTES`.
    InvalidLength,
    /// The declared SHA-256 is missing or not 64 hex digits.
    InvalidHash,
    /// The length or digest differs from the ones the upload started with.
    DeclarationMismatch,
    /// The append starts somewhere other than the upload's current offset.
    OffsetMismatch {
        offset: u64,
    },
    /// The store's budget or the host's free-space floor leaves no room.
    InsufficientStorage,
    TooManyIncomplete,
    /// The body's length differs from the bytes the upload still needs.
    LengthMismatch {
        declared: u64,
        received: u64,
    },
    /// The complete file's digest differs from the declared one; the upload
    /// was discarded.
    HashMismatch,
    Discarded,
    AlreadyStored,
    /// The directory or file could not be read or written.
    Io(String),
    /// Every writer slot is taken.
    Busy,
    /// The host is restarting and takes no more bytes.
    Draining,
    /// The body sent nothing for `BODY_IDLE_TIMEOUT`.
    Stalled,
    Superseded,
    Interrupted(String),
}

impl UploadError {
    pub(crate) fn message(&self) -> String {
        match self {
            UploadError::InvalidId => "upload id must be a UUID".to_string(),
            UploadError::InvalidName => "file name is missing or unusable".to_string(),
            UploadError::InvalidLength => {
                format!("declared length must be between 1 and {MAX_UPLOAD_BYTES} bytes")
            }
            UploadError::InvalidHash => "a 64-hex-digit sha256 must be declared".to_string(),
            UploadError::DeclarationMismatch => {
                "the length or sha256 differs from the upload's".to_string()
            }
            UploadError::OffsetMismatch { offset } => {
                format!("the upload continues at byte {offset}")
            }
            UploadError::InsufficientStorage => {
                "the host does not have enough free space for this file".to_string()
            }
            UploadError::TooManyIncomplete => {
                "too many unfinished uploads on this host; finish or remove some".to_string()
            }
            UploadError::LengthMismatch { declared, received } => {
                format!("the body must carry the remaining {declared} bytes, not {received}")
            }
            UploadError::HashMismatch => {
                "the file's sha256 does not match the declared digest".to_string()
            }
            UploadError::Discarded => "the upload was discarded".to_string(),
            UploadError::AlreadyStored => "the upload already finished".to_string(),
            UploadError::Io(error) => format!("failed storing upload: {error}"),
            UploadError::Busy => "too many uploads are in progress; retry shortly".to_string(),
            UploadError::Draining => "the host is restarting; retry after it is back".to_string(),
            UploadError::Stalled => "the upload stopped sending data".to_string(),
            UploadError::Superseded => "a newer request took over this upload".to_string(),
            UploadError::Interrupted(error) => format!("the upload was interrupted: {error}"),
        }
    }
}

/// A client-chosen upload id: a UUID in canonical lowercase form, which is
/// also the upload's directory name.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct UploadId(String);

impl UploadId {
    pub(crate) fn parse(raw: &str) -> Option<UploadId> {
        let canonical = raw.to_ascii_lowercase();
        let shaped = canonical.len() == 36
            && canonical
                .char_indices()
                .all(|(index, character)| match index {
                    8 | 13 | 18 | 23 => character == '-',
                    _ => character.is_ascii_hexdigit(),
                });
        shaped.then_some(UploadId(canonical))
    }

    pub(crate) fn random() -> UploadId {
        UploadId(crate::ids::new_session_uuid())
    }

    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone)]
pub(crate) struct Declaration<'a> {
    pub name: &'a str,
    pub length: u64,
    pub sha256: &'a str,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct Append {
    pub offset: u64,
    pub content_length: u64,
}

/// A file that landed, with the exact path to hand the model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct StoredUpload {
    pub path: PathBuf,
    pub bytes: u64,
    pub sha256: String,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum UploadStatus {
    Absent,
    Incomplete { offset: u64 },
    Stored(StoredUpload),
}

/// The declaration an upload started with, kept beside its bytes so it
/// survives a gateway restart.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct SessionRecord {
    name: String,
    length: u64,
    sha256: String,
}

struct Session {
    dir: PathBuf,
    record: SessionRecord,
    offset: AtomicU64,
    touched: AtomicU64,
    /// The current append's generation and cancellation, so a newer append
    /// can take over from one whose client is gone but whose connection has
    /// not timed out.
    writer: Mutex<Option<(u64, CancellationToken)>>,
    /// Held by an append, including blocking work it hands off.
    state: Arc<tokio::sync::Mutex<WriterState>>,
}

struct WriterState {
    /// The digest of exactly the first `offset` bytes, or `None` until it is
    /// rebuilt from the partial file.
    hasher: Option<Sha256>,
}

struct Inventory {
    used: u64,
    victims: Vec<Victim>,
}

enum Victim {
    Idle {
        id: UploadId,
        bytes: u64,
        remaining: u64,
    },
    Finished {
        path: PathBuf,
        bytes: u64,
    },
}

/// What admitting one more upload takes from the store.
struct Room {
    incomplete: usize,
    free: u64,
    committed: u64,
    used: u64,
    needed: u64,
    budget: u64,
}

impl Room {
    fn has_slot(&self) -> bool {
        self.incomplete < MAX_INCOMPLETE
    }

    fn has_space(&self) -> bool {
        self.free
            .saturating_sub(self.committed)
            .saturating_sub(self.needed)
            >= MIN_FREE_BYTES_AFTER_WRITE
    }

    fn within_budget(&self) -> bool {
        self.used
            .saturating_add(self.committed)
            .saturating_add(self.needed)
            <= self.budget
    }

    fn fits(&self) -> bool {
        self.has_slot() && self.has_space() && self.within_budget()
    }

    /// Counts what evicting `victim` gives back, or returns false when it
    /// cannot help: a finished upload frees budget, not a slot or space.
    fn evict(&mut self, victim: &Victim) -> bool {
        match *victim {
            Victim::Idle {
                bytes, remaining, ..
            } => {
                self.incomplete -= 1;
                self.committed = self.committed.saturating_sub(remaining);
                self.free = self.free.saturating_add(bytes);
                self.used = self.used.saturating_sub(bytes);
            }
            Victim::Finished { bytes, .. } => {
                if !self.has_slot() || !self.has_space() {
                    return false;
                }
                self.used = self.used.saturating_sub(bytes);
            }
        }
        true
    }
}

impl Session {
    fn new(
        dir: PathBuf,
        record: SessionRecord,
        offset: u64,
        touched: SystemTime,
        hasher: Option<Sha256>,
    ) -> Session {
        Session {
            dir,
            record,
            offset: AtomicU64::new(offset),
            touched: AtomicU64::new(epoch_seconds(touched)),
            writer: Mutex::new(None),
            state: Arc::new(tokio::sync::Mutex::new(WriterState { hasher })),
        }
    }

    fn partial(&self) -> PathBuf {
        self.dir.join(PARTIAL_NAME)
    }

    fn remaining(&self) -> u64 {
        self.record
            .length
            .saturating_sub(self.offset.load(Ordering::Acquire))
    }

    fn touch(&self) {
        self.touched
            .store(epoch_seconds(SystemTime::now()), Ordering::Release);
    }

    fn idle_since(&self, now: SystemTime) -> Duration {
        Duration::from_secs(epoch_seconds(now).saturating_sub(self.touched.load(Ordering::Acquire)))
    }

    fn matches(&self, record: &SessionRecord) -> bool {
        self.record.length == record.length && self.record.sha256 == record.sha256
    }

    fn is_idle(&self, now: SystemTime) -> bool {
        self.idle_since(now) >= SESSION_IDLE_EVICTION
            && self
                .writer
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .is_none()
    }
}

#[derive(Clone)]
pub(crate) struct UploadStore {
    /// Canonical, so every returned path is one the model can use verbatim.
    dir: PathBuf,
    sessions: Arc<Mutex<HashMap<UploadId, Arc<Session>>>>,
    writers: Arc<Semaphore>,
    generations: Arc<AtomicU64>,
    shutdown: CancellationToken,
    idle_timeout: Duration,
    budget: u64,
}

impl UploadStore {
    /// Creates the directory user-private, resolves it to its canonical path,
    /// loads the unfinished uploads clients may still continue, and removes
    /// abandoned and expired ones.
    pub(crate) fn open_in(dir: PathBuf) -> anyhow::Result<UploadStore> {
        use std::os::unix::fs::DirBuilderExt;

        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .map_err(|error| anyhow::anyhow!("cannot create {}: {error}", dir.display()))?;
        let dir = dir
            .canonicalize()
            .map_err(|error| anyhow::anyhow!("cannot canonicalize {}: {error}", dir.display()))?;
        let now = SystemTime::now();
        let store = UploadStore {
            sessions: Arc::new(Mutex::new(load_sessions(&dir, now))),
            dir,
            writers: Arc::new(Semaphore::new(MAX_WRITERS)),
            generations: Arc::new(AtomicU64::new(0)),
            shutdown: CancellationToken::new(),
            idle_timeout: BODY_IDLE_TIMEOUT,
            budget: MAX_STORE_BYTES,
        };
        let swept = store.inventory(&store.sessions(), now);
        if let Err(error) = swept {
            warn!(reason = %error.message(), "upload store could not be swept");
        }
        Ok(store)
    }

    /// Refuses new appends and ends the ones still streaming. Their bytes
    /// stay on disk, so the clients continue after the restart.
    pub(crate) fn drain(&self) {
        self.shutdown.cancel();
    }

    pub(crate) fn status(&self, id: &UploadId) -> Result<UploadStatus, UploadError> {
        if let Some(session) = self.session(id) {
            return Ok(UploadStatus::Incomplete {
                offset: session.offset.load(Ordering::Acquire),
            });
        }
        Ok(self
            .stored(id)?
            .map_or(UploadStatus::Absent, UploadStatus::Stored))
    }

    /// Removes an unfinished upload and its bytes once a streaming append has
    /// stopped. A finished upload stays until retention, since a sent message
    /// may already name its path; an unknown id is already gone. The removal
    /// runs in its own task, so a dropped request cannot leave the bytes
    /// without a session.
    pub(crate) async fn discard(&self, id: &UploadId) -> Result<(), UploadError> {
        let store = self.clone();
        let id = id.clone();
        tokio::spawn(async move { store.remove_session(&id).await })
            .await
            .map_err(|error| UploadError::Io(error.to_string()))?
    }

    async fn remove_session(&self, id: &UploadId) -> Result<(), UploadError> {
        let removed = self.sessions().remove(id);
        let Some(session) = removed else {
            return match self.stored(id)? {
                Some(_) => Err(UploadError::AlreadyStored),
                None => Ok(()),
            };
        };
        let writer = session
            .writer
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        if let Some((_, writer)) = writer {
            writer.cancel();
        }
        let _stopped = Arc::clone(&session.state).lock_owned().await;
        if self.stored(id)?.is_some() {
            return Err(UploadError::AlreadyStored);
        }
        let dir = session.dir.clone();
        let removed = tokio::task::spawn_blocking(move || remove_upload(&dir, "discarded"))
            .await
            .map_err(|error| UploadError::Io(error.to_string()))?;
        if removed {
            Ok(())
        } else {
            Err(UploadError::Io("the upload could not be removed".into()))
        }
    }

    /// Writes one append's body at the upload's offset, creating the upload
    /// on its first append. Every byte received before the body ends, stalls,
    /// is superseded or the host drains stays on disk, and the error tells the
    /// client why to continue later. The upload is stored, and named, once its
    /// length is reached and its digest matches; repeating the final append
    /// returns the same file.
    pub(crate) async fn append<S, E>(
        &self,
        id: &UploadId,
        declaration: Declaration<'_>,
        append: Append,
        mut body: S,
    ) -> Result<StoredUpload, UploadError>
    where
        S: Stream<Item = Result<Bytes, E>> + Unpin,
        E: std::fmt::Display,
    {
        if self.shutdown.is_cancelled() {
            return Err(UploadError::Draining);
        }
        let record = validate(&declaration)?;
        let session = match self.session(id) {
            Some(session) if session.matches(&record) => session,
            Some(_) => return Err(UploadError::DeclarationMismatch),
            None => match self.stored(id)? {
                Some(stored) if stored.bytes == record.length && stored.sha256 == record.sha256 => {
                    return Ok(stored);
                }
                Some(_) => return Err(UploadError::DeclarationMismatch),
                None if append.offset != 0 => {
                    return Err(UploadError::OffsetMismatch { offset: 0 });
                }
                None => {
                    let store = self.clone();
                    let id = id.clone();
                    tokio::task::spawn_blocking(move || store.create(&id, record, free_bytes))
                        .await
                        .map_err(|error| UploadError::Io(error.to_string()))??
                }
            },
        };
        let claim = self.claim(&session);
        self.write(id, &session, &claim.token, append, &mut body)
            .await
    }

    fn sessions(&self) -> std::sync::MutexGuard<'_, HashMap<UploadId, Arc<Session>>> {
        self.sessions
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn session(&self, id: &UploadId) -> Option<Arc<Session>> {
        self.sessions().get(id).cloned()
    }

    fn is_current(&self, id: &UploadId, session: &Arc<Session>) -> bool {
        self.sessions()
            .get(id)
            .is_some_and(|current| Arc::ptr_eq(current, session))
    }

    fn stored(&self, id: &UploadId) -> Result<Option<StoredUpload>, UploadError> {
        let dir = self.dir.join(id.as_str());
        let Some(record) = read_record(&dir) else {
            return Ok(None);
        };
        let path = dir.join(&record.name);
        match std::fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.is_file() && metadata.len() == record.length => {
                Ok(Some(StoredUpload {
                    path,
                    bytes: record.length,
                    sha256: record.sha256,
                }))
            }
            Ok(_) => Ok(None),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(UploadError::Io(error.to_string())),
        }
    }

    /// Admits a new upload against the unfinished-upload limit, the volume's
    /// free space and the store's budget, counting what every unfinished
    /// upload still needs. Idle unfinished uploads, then the oldest finished
    /// ones, are evicted only when that admits it.
    fn create(
        &self,
        id: &UploadId,
        record: SessionRecord,
        free: impl FnOnce(&Path) -> Result<u64, UploadError>,
    ) -> Result<Arc<Session>, UploadError> {
        let mut sessions = self.sessions();
        if let Some(existing) = sessions.get(id) {
            return if existing.matches(&record) {
                Ok(Arc::clone(existing))
            } else {
                Err(UploadError::DeclarationMismatch)
            };
        }
        let now = SystemTime::now();
        sweep_idle(&mut sessions, now);
        let inventory = self.inventory(&sessions, now)?;
        let mut room = Room {
            incomplete: sessions.len(),
            free: free(&self.dir)?,
            committed: sessions.values().map(|session| session.remaining()).sum(),
            used: inventory.used,
            needed: record.length,
            budget: self.budget,
        };
        let mut victims = Vec::new();
        for victim in inventory.victims {
            if room.fits() || !room.evict(&victim) {
                break;
            }
            victims.push(victim);
        }
        if !room.has_slot() {
            return Err(UploadError::TooManyIncomplete);
        }
        if !room.fits() {
            return Err(UploadError::InsufficientStorage);
        }
        for victim in victims {
            let evicted = match victim {
                Victim::Idle { id, .. } => evict_session(&mut sessions, &id, "store full"),
                Victim::Finished { path, .. } => remove_upload(&path, "store full"),
            };
            if !evicted {
                return Err(UploadError::InsufficientStorage);
            }
        }
        let dir = self.dir.join(id.as_str());
        create_private_dir(&dir).map_err(|error| match error.kind() {
            std::io::ErrorKind::AlreadyExists => UploadError::DeclarationMismatch,
            _ => UploadError::Io(error.to_string()),
        })?;
        if let Err(error) =
            create_private_file(&dir.join(PARTIAL_NAME)).and_then(|()| write_record(&dir, &record))
        {
            remove_upload(&dir, "failed to start");
            return Err(UploadError::Io(error.to_string()));
        }
        let session = Arc::new(Session::new(dir, record, 0, now, Some(Sha256::new())));
        sessions.insert(id.clone(), Arc::clone(&session));
        Ok(session)
    }

    /// Removes finished uploads past retention, then returns the bytes on disk
    /// and what may go to make room: idle unfinished uploads, most idle first,
    /// then finished ones, oldest first.
    fn inventory(
        &self,
        sessions: &HashMap<UploadId, Arc<Session>>,
        now: SystemTime,
    ) -> Result<Inventory, UploadError> {
        let entries =
            std::fs::read_dir(&self.dir).map_err(|error| UploadError::Io(error.to_string()))?;
        let mut used: u64 = 0;
        let mut idle = Vec::new();
        let mut finished = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(metadata) = entry.metadata() else {
                continue;
            };
            if !metadata.is_dir() {
                continue;
            }
            let bytes = dir_bytes(&path);
            used += bytes;
            let id = entry.file_name().to_str().and_then(UploadId::parse);
            if let Some((id, session)) =
                id.and_then(|id| sessions.get(&id).map(|session| (id, session)))
            {
                if session.is_idle(now) {
                    let remaining = session.remaining();
                    idle.push((
                        session.idle_since(now),
                        Victim::Idle {
                            id,
                            bytes,
                            remaining,
                        },
                    ));
                }
                continue;
            }
            if path.join(PARTIAL_NAME).exists() {
                continue;
            }
            let modified = metadata.modified().unwrap_or(now);
            if now
                .duration_since(modified)
                .is_ok_and(|age| age > RETENTION)
            {
                if remove_upload(&path, "expired") {
                    used -= bytes;
                }
                continue;
            }
            finished.push((modified, Victim::Finished { path, bytes }));
        }
        idle.sort_by_key(|(idle_for, _)| std::cmp::Reverse(*idle_for));
        finished.sort_by_key(|(modified, _)| *modified);
        let victims = idle
            .into_iter()
            .map(|(_, victim)| victim)
            .chain(finished.into_iter().map(|(_, victim)| victim))
            .collect();
        Ok(Inventory { used, victims })
    }

    fn claim<'a>(&self, session: &'a Session) -> Claim<'a> {
        session.touch();
        let generation = self.generations.fetch_add(1, Ordering::Relaxed);
        let token = CancellationToken::new();
        let previous = session
            .writer
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .replace((generation, token.clone()));
        if let Some((_, previous)) = previous {
            previous.cancel();
        }
        Claim {
            session,
            generation,
            token,
        }
    }

    async fn write<S, E>(
        &self,
        id: &UploadId,
        session: &Arc<Session>,
        token: &CancellationToken,
        append: Append,
        body: &mut S,
    ) -> Result<StoredUpload, UploadError>
    where
        S: Stream<Item = Result<Bytes, E>> + Unpin,
        E: std::fmt::Display,
    {
        let mut state = tokio::select! {
            biased;
            () = token.cancelled() => return Err(UploadError::Superseded),
            () = self.shutdown.cancelled() => return Err(UploadError::Draining),
            state = Arc::clone(&session.state).lock_owned() => state,
        };
        if !self.is_current(id, session) {
            return self.stored(id)?.ok_or(UploadError::Discarded);
        }
        let _slot = Arc::clone(&self.writers)
            .try_acquire_owned()
            .map_err(|_| UploadError::Busy)?;
        if state.hasher.is_none() {
            state = rehash(
                Arc::clone(session),
                state,
                token.clone(),
                self.shutdown.clone(),
            )
            .await?;
        }
        let offset = session.offset.load(Ordering::Acquire);
        if append.offset != offset {
            return Err(UploadError::OffsetMismatch { offset });
        }
        let remaining = session.record.length.saturating_sub(offset);
        if append.content_length != remaining {
            return Err(UploadError::LengthMismatch {
                declared: remaining,
                received: append.content_length,
            });
        }
        let state = self
            .stream(session, state, token, append.content_length, body)
            .await?;
        if session.offset.load(Ordering::Acquire) < session.record.length {
            return Err(UploadError::Interrupted("the body ended early".to_string()));
        }
        self.finish(id, Arc::clone(session), state).await
    }

    /// Writes the body in blocking work that owns the writer lock, so a
    /// dropped request never overlaps the next append. Chunks that have
    /// already arrived are gathered into one write; bytes received before the
    /// body ends or fails are written before it returns.
    async fn stream<S, E>(
        &self,
        session: &Arc<Session>,
        mut state: OwnedMutexGuard<WriterState>,
        token: &CancellationToken,
        content_length: u64,
        body: &mut S,
    ) -> Result<OwnedMutexGuard<WriterState>, UploadError>
    where
        S: Stream<Item = Result<Bytes, E>> + Unpin,
        E: std::fmt::Display,
    {
        let mut file = None;
        let mut received: u64 = 0;
        loop {
            let mut next = tokio::select! {
                biased;
                () = token.cancelled() => return Err(UploadError::Superseded),
                () = self.shutdown.cancelled() => return Err(UploadError::Draining),
                next = tokio::time::timeout(self.idle_timeout, body.next()) => {
                    next.map_err(|_| UploadError::Stalled)?
                }
            };
            let mut batch = Vec::new();
            let mut batched = 0;
            let end = loop {
                match next {
                    Some(Ok(chunk)) => {
                        received += chunk.len() as u64;
                        if received > content_length {
                            return Err(UploadError::LengthMismatch {
                                declared: content_length,
                                received,
                            });
                        }
                        batched += chunk.len();
                        batch.push(chunk);
                    }
                    None => break Some(Ok(())),
                    Some(Err(error)) => {
                        break Some(Err(UploadError::Interrupted(error.to_string())));
                    }
                }
                if batched >= WRITE_BATCH_BYTES {
                    break None;
                }
                match body.next().now_or_never() {
                    Some(ready) => next = ready,
                    None => break None,
                }
            };
            if !batch.is_empty() {
                let written = write_batch(Arc::clone(session), state, file.take(), batch).await?;
                (state, file) = (written.0, Some(written.1));
            }
            match end {
                None => {}
                Some(Ok(())) => return Ok(state),
                Some(Err(error)) => return Err(error),
            }
        }
    }

    /// Checks the complete file's digest, then names it. A file that does not
    /// match was corrupted somewhere and continuing cannot repair it, so the
    /// upload is discarded and the client starts over.
    async fn finish(
        &self,
        id: &UploadId,
        session: Arc<Session>,
        state: OwnedMutexGuard<WriterState>,
    ) -> Result<StoredUpload, UploadError> {
        let sessions = Arc::clone(&self.sessions);
        let id = id.clone();
        tokio::task::spawn_blocking(move || {
            let Some(hasher) = state.hasher.clone() else {
                return Err(UploadError::Io("the upload's digest was lost".to_string()));
            };
            let sha256 = hex(&hasher.finalize());
            if sha256 != session.record.sha256 {
                forget(&sessions, &id, &session);
                remove_upload(&session.dir, "digest mismatch");
                return Err(UploadError::HashMismatch);
            }
            let path = session.dir.join(&session.record.name);
            publish(&session.partial(), &path)
                .map_err(|error| UploadError::Io(error.to_string()))?;
            forget(&sessions, &id, &session);
            if let Err(error) = std::fs::File::open(&session.dir).and_then(|dir| dir.sync_all()) {
                warn!(dir = %session.dir.display(), %error, "stored upload's directory was not synced");
            }
            info!(path = %path.display(), bytes = session.record.length, "stored upload");
            Ok(StoredUpload {
                path,
                bytes: session.record.length,
                sha256,
            })
        })
        .await
        .map_err(|error| UploadError::Io(error.to_string()))?
    }

    pub(crate) async fn move_verified(
        &self,
        upload: StoredUpload,
        directory: PathBuf,
        stem: String,
    ) -> anyhow::Result<PathBuf> {
        let store = self.clone();
        tokio::task::spawn_blocking(move || store.move_verified_file(upload, directory, stem))
            .await?
    }

    fn move_verified_file(
        &self,
        upload: StoredUpload,
        directory: PathBuf,
        stem: String,
    ) -> anyhow::Result<PathBuf> {
        use anyhow::{Context, ensure};
        use std::fs::{File, OpenOptions};
        use std::os::unix::fs::OpenOptionsExt;

        ensure!(
            upload.bytes > 0 && upload.bytes <= MAX_UPLOAD_BYTES,
            "invalid original size"
        );
        ensure!(
            upload.sha256.len() == 64 && upload.sha256.bytes().all(|byte| byte.is_ascii_hexdigit()),
            "invalid original SHA-256"
        );
        ensure!(
            sanitize_file_name(&stem).as_deref() == Some(stem.as_str()),
            "invalid photo filename"
        );
        let path = upload
            .path
            .canonicalize()
            .context("original upload is missing")?;
        ensure!(
            path == upload.path && path.starts_with(&self.dir),
            "original is outside the upload store or uses a noncanonical path"
        );
        let relative = path.strip_prefix(&self.dir)?;
        ensure!(
            relative.components().count() == 2
                && path
                    .file_name()
                    .is_some_and(|name| name != PARTIAL_NAME && name != SESSION_NAME),
            "original is not a completed upload"
        );
        ensure!(
            !path.with_file_name(PARTIAL_NAME).exists(),
            "original upload is still incomplete"
        );
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)?;
        let metadata = file.metadata()?;
        ensure!(
            metadata.is_file() && metadata.len() == upload.bytes,
            "original upload size does not match"
        );
        let (_, digest) = hash_reader(&mut file, || false)?
            .ok_or_else(|| anyhow::anyhow!("original upload hashing stopped"))?;
        ensure!(
            hex(&digest.finalize()).eq_ignore_ascii_case(&upload.sha256),
            "original upload SHA-256 does not match"
        );
        std::fs::create_dir_all(&directory)?;
        for suffix in 0..10000 {
            let name = if suffix == 0 {
                format!("{stem}.jpg")
            } else {
                format!("{stem}-{suffix}.jpg")
            };
            let destination = directory.join(name);
            match rename_exclusive(&path, &destination) {
                Ok(()) => {
                    File::open(&directory)?.sync_all()?;
                    return Ok(destination);
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error).context("moving original into the photo library"),
            }
        }
        anyhow::bail!("photo filename collision limit reached")
    }
}

/// An append's claim on its upload; dropping it clears the claim unless a
/// newer append has already replaced it.
struct Claim<'a> {
    session: &'a Session,
    generation: u64,
    token: CancellationToken,
}

impl Drop for Claim<'_> {
    fn drop(&mut self) {
        let mut writer = self
            .session
            .writer
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if writer
            .as_ref()
            .is_some_and(|(generation, _)| *generation == self.generation)
        {
            *writer = None;
        }
    }
}

fn validate(declaration: &Declaration<'_>) -> Result<SessionRecord, UploadError> {
    let name = sanitize_file_name(declaration.name).ok_or(UploadError::InvalidName)?;
    if declaration.length == 0 || declaration.length > MAX_UPLOAD_BYTES {
        return Err(UploadError::InvalidLength);
    }
    let sha256 = declaration.sha256.trim().to_ascii_lowercase();
    if sha256.len() != 64 || !sha256.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(UploadError::InvalidHash);
    }
    Ok(SessionRecord {
        name,
        length: declaration.length,
        sha256,
    })
}

/// Appends one chunk and only then counts and hashes it. A failed write may
/// have appended part of the chunk, which is still the upload's next bytes,
/// so the next writer rebuilds the digest and offset from the file.
fn commit(
    session: &Session,
    state: &mut WriterState,
    file: &mut std::fs::File,
    bytes: &[u8],
) -> Result<(), UploadError> {
    if let Err(error) = file.write_all(bytes) {
        state.hasher = None;
        return Err(UploadError::Io(error.to_string()));
    }
    if let Some(hasher) = state.hasher.as_mut() {
        hasher.update(bytes);
    }
    session
        .offset
        .fetch_add(bytes.len() as u64, Ordering::AcqRel);
    session.touch();
    Ok(())
}

async fn write_batch(
    session: Arc<Session>,
    mut state: OwnedMutexGuard<WriterState>,
    file: Option<std::fs::File>,
    batch: Vec<Bytes>,
) -> Result<(OwnedMutexGuard<WriterState>, std::fs::File), UploadError> {
    tokio::task::spawn_blocking(move || {
        let mut file = match file {
            Some(file) => file,
            None => std::fs::OpenOptions::new()
                .append(true)
                .open(session.partial())
                .map_err(|error| UploadError::Io(error.to_string()))?,
        };
        for chunk in &batch {
            commit(&session, &mut state, &mut file, chunk)?;
        }
        Ok((state, file))
    })
    .await
    .map_err(|error| UploadError::Io(error.to_string()))?
}

async fn rehash(
    session: Arc<Session>,
    mut state: OwnedMutexGuard<WriterState>,
    token: CancellationToken,
    shutdown: CancellationToken,
) -> Result<OwnedMutexGuard<WriterState>, UploadError> {
    tokio::task::spawn_blocking(move || {
        let file = std::fs::File::open(session.partial())
            .map_err(|error| UploadError::Io(error.to_string()))?;
        let hashed = hash_reader(file, || token.is_cancelled() || shutdown.is_cancelled())
            .map_err(|error| UploadError::Io(error.to_string()))?;
        let Some((offset, hasher)) = hashed else {
            return Err(if shutdown.is_cancelled() {
                UploadError::Draining
            } else {
                UploadError::Superseded
            });
        };
        session.offset.store(offset, Ordering::Release);
        state.hasher = Some(hasher);
        Ok(state)
    })
    .await
    .map_err(|error| UploadError::Io(error.to_string()))?
}

fn hash_reader(
    mut reader: impl Read,
    stopped: impl Fn() -> bool,
) -> std::io::Result<Option<(u64, Sha256)>> {
    let mut hasher = Sha256::new();
    let mut buffer = vec![0; 1024 * 1024];
    let mut length: u64 = 0;
    loop {
        if stopped() {
            return Ok(None);
        }
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            return Ok(Some((length, hasher)));
        }
        hasher.update(&buffer[..read]);
        length += read as u64;
    }
}

fn publish(partial: &Path, path: &Path) -> std::io::Result<()> {
    std::fs::File::open(partial)?.sync_all()?;
    std::fs::rename(partial, path)
}

fn forget(
    sessions: &Mutex<HashMap<UploadId, Arc<Session>>>,
    id: &UploadId,
    session: &Arc<Session>,
) {
    let mut sessions = sessions
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if sessions
        .get(id)
        .is_some_and(|current| Arc::ptr_eq(current, session))
    {
        sessions.remove(id);
    }
}

/// Unfinished uploads a client may still continue: a partial file no longer
/// than its recorded length, continued within `INCOMPLETE_RETENTION`. Every
/// other partial file, including one a crash left before its record, goes.
/// A full-length partial is kept; the client's final empty append verifies
/// and names it without sending it again.
fn load_sessions(dir: &Path, now: SystemTime) -> HashMap<UploadId, Arc<Session>> {
    let mut sessions = HashMap::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return sessions;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(partial) = std::fs::symlink_metadata(path.join(PARTIAL_NAME)) else {
            continue;
        };
        let name = entry.file_name();
        let id = name
            .to_str()
            .and_then(|name| UploadId::parse(name).filter(|id| id.as_str() == name));
        let modified = partial.modified().unwrap_or(now);
        let fresh = now
            .duration_since(modified)
            .map_or(true, |idle| idle <= INCOMPLETE_RETENTION);
        match (id, read_record(&path)) {
            (Some(id), Some(record))
                if partial.is_file() && partial.len() <= record.length && fresh =>
            {
                let session = Session::new(path, record, partial.len(), modified, None);
                sessions.insert(id, Arc::new(session));
            }
            _ => {
                remove_upload(&path, "abandoned");
            }
        }
    }
    sessions
}

fn evict_session(
    sessions: &mut HashMap<UploadId, Arc<Session>>,
    id: &UploadId,
    reason: &str,
) -> bool {
    let Some(session) = sessions.get(id).cloned() else {
        return false;
    };
    let Ok(_quiet) = session.state.try_lock() else {
        return false;
    };
    if !remove_upload(&session.dir, reason) {
        return false;
    }
    sessions.remove(id);
    true
}

fn sweep_idle(sessions: &mut HashMap<UploadId, Arc<Session>>, now: SystemTime) {
    sessions.retain(|_, session| {
        let fresh = session.idle_since(now) <= INCOMPLETE_RETENTION;
        if !fresh {
            remove_upload(&session.dir, "abandoned");
        }
        fresh
    });
}

fn read_record(dir: &Path) -> Option<SessionRecord> {
    let bytes = std::fs::read(dir.join(SESSION_NAME)).ok()?;
    serde_json::from_slice::<SessionRecord>(&bytes)
        .ok()
        .filter(|record| sanitize_file_name(&record.name).as_deref() == Some(record.name.as_str()))
}

fn write_record(dir: &Path, record: &SessionRecord) -> std::io::Result<()> {
    std::fs::write(dir.join(SESSION_NAME), serde_json::to_vec(record)?)
}

fn remove_upload(dir: &Path, reason: &str) -> bool {
    match std::fs::remove_dir_all(dir) {
        Ok(()) => {
            info!(dir = %dir.display(), reason, "removed upload");
            true
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
        Err(error) => {
            warn!(dir = %dir.display(), reason, %error, "could not remove upload");
            false
        }
    }
}

fn dir_bytes(dir: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    entries
        .flatten()
        .filter_map(|entry| entry.metadata().ok())
        .filter(|metadata| metadata.is_file())
        .map(|metadata| metadata.len())
        .sum()
}

#[cfg(target_os = "macos")]
fn rename_exclusive(source: &Path, destination: &Path) -> std::io::Result<()> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let source = CString::new(source.as_os_str().as_bytes())?;
    let destination = CString::new(destination.as_os_str().as_bytes())?;
    let result =
        unsafe { libc::renamex_np(source.as_ptr(), destination.as_ptr(), libc::RENAME_EXCL) };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(not(target_os = "macos"))]
fn rename_exclusive(source: &Path, destination: &Path) -> std::io::Result<()> {
    std::fs::hard_link(source, destination)?;
    std::fs::remove_file(source)
}

/// Reduces a client-supplied file name to one safe path component that still
/// reads as the original file and keeps its extension.
///
/// Letters and digits in any script stay; everything else becomes `-`, runs
/// collapse, and leading dots or dashes go, so a separator, a `..`, a hidden
/// file or a flag-shaped name can never survive. Truncation cuts the stem, not
/// the extension, because the extension is what tells a model what the file is.
fn sanitize_file_name(raw: &str) -> Option<String> {
    let cleaned = clean_component(raw);
    if cleaned.is_empty() {
        return None;
    }
    if cleaned.chars().count() <= MAX_NAME_LENGTH && cleaned.len() <= MAX_NAME_BYTES {
        return Some(cleaned);
    }
    let (stem, extension) = match cleaned.rsplit_once('.') {
        Some((stem, extension))
            if !stem.is_empty()
                && !extension.is_empty()
                && extension.chars().count() <= MAX_EXTENSION_LENGTH =>
        {
            (stem, Some(extension))
        }
        _ => (cleaned.as_str(), None),
    };
    let (suffix_chars, suffix_bytes) = extension.map_or((0, 0), |extension| {
        (extension.chars().count() + 1, extension.len() + 1)
    });
    let keep_chars = MAX_NAME_LENGTH.saturating_sub(suffix_chars).max(1);
    let keep_bytes = MAX_NAME_BYTES.saturating_sub(suffix_bytes);
    let mut kept_bytes = 0;
    let stem: String = stem
        .chars()
        .take(keep_chars)
        .take_while(|character| {
            kept_bytes += character.len_utf8();
            kept_bytes <= keep_bytes
        })
        .collect();
    let stem = stem.trim_end_matches(['-', '.']);
    if stem.is_empty() {
        return None;
    }
    Some(match extension {
        Some(extension) => format!("{stem}.{extension}"),
        None => stem.to_string(),
    })
}

fn clean_component(raw: &str) -> String {
    let mut cleaned = String::with_capacity(raw.len());
    let mut last_was_dash = false;
    for character in raw.chars() {
        let safe = if character.is_alphanumeric() || matches!(character, '.' | '_' | '-') {
            character
        } else {
            '-'
        };
        if safe == '-' {
            if last_was_dash {
                continue;
            }
            last_was_dash = true;
        } else {
            if safe == '.' && last_was_dash {
                // "report (final).pdf" keeps its extension attached.
                cleaned.pop();
            }
            last_was_dash = false;
        }
        cleaned.push(safe);
    }
    cleaned
        .trim_matches(|character| character == '-' || character == '.')
        .to_string()
}

fn free_bytes(dir: &Path) -> Result<u64, UploadError> {
    let stat = nix::sys::statvfs::statvfs(dir)
        .map_err(|error| UploadError::Io(format!("could not read free space: {error}")))?;
    u64::try_from(u128::from(stat.blocks_available()) * u128::from(stat.fragment_size()))
        .map_err(|error| UploadError::Io(format!("free space exceeds u64: {error}")))
}

fn create_private_dir(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new().mode(0o700).create(path)
}

fn create_private_file(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map(drop)
}

fn epoch_seconds(time: SystemTime) -> u64 {
    time.duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::stream;
    use std::convert::Infallible;

    const MIB: usize = 1024 * 1024;

    fn temp_store() -> (UploadStore, tempfile::TempDir) {
        let root = tempfile::tempdir().expect("temp dir");
        let store = UploadStore::open_in(root.path().join("uploads")).expect("open store");
        (store, root)
    }

    fn reopen(store: &UploadStore) -> UploadStore {
        UploadStore::open_in(store.dir.clone()).expect("reopen store")
    }

    fn id(number: u32) -> UploadId {
        UploadId::parse(&format!("00000000-0000-4000-8000-{number:012x}")).expect("id")
    }

    fn body(chunks: &[&[u8]]) -> impl Stream<Item = Result<Bytes, Infallible>> + Unpin + use<> {
        let owned: Vec<Result<Bytes, Infallible>> = chunks
            .iter()
            .map(|chunk| Ok(Bytes::copy_from_slice(chunk)))
            .collect();
        stream::iter(owned)
    }

    fn stalled_after(
        first: &[u8],
    ) -> impl Stream<Item = Result<Bytes, Infallible>> + Unpin + use<> {
        stream::iter([Ok(Bytes::copy_from_slice(first))]).chain(stream::pending())
    }

    fn digest(bytes: &[u8]) -> String {
        hex(&Sha256::digest(bytes))
    }

    fn file(length: usize) -> Vec<u8> {
        (0..length).map(|index| (index % 251) as u8).collect()
    }

    fn declare<'a>(name: &'a str, bytes: &[u8], sha256: &'a str) -> Declaration<'a> {
        Declaration {
            name,
            length: bytes.len() as u64,
            sha256,
        }
    }

    fn from(offset: usize, bytes: &[u8]) -> Append {
        Append {
            offset: offset as u64,
            content_length: (bytes.len() - offset) as u64,
        }
    }

    async fn store_whole(
        store: &UploadStore,
        upload: &UploadId,
        name: &str,
        bytes: &[u8],
    ) -> StoredUpload {
        let sha = digest(bytes);
        match store
            .append(
                upload,
                declare(name, bytes, &sha),
                from(0, bytes),
                body(&[bytes]),
            )
            .await
        {
            Ok(stored) => stored,
            other => panic!("not stored: {other:?}"),
        }
    }

    async fn wait_for_offset(store: &UploadStore, upload: &UploadId, offset: u64) {
        tokio::time::timeout(Duration::from_secs(5), async {
            while store.status(upload) != Ok(UploadStatus::Incomplete { offset }) {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .expect("offset reached");
    }

    async fn wait_for_writers(store: &UploadStore, available: usize) {
        tokio::time::timeout(Duration::from_secs(5), async {
            while store.writers.available_permits() != available {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("writers settle");
    }

    #[test]
    fn upload_ids_are_canonical_uuids() {
        let upload = UploadId::parse("6F9619FF-8B86-D011-B42D-00CF4FC964FF").expect("uuid");
        assert_eq!(upload.as_str(), "6f9619ff-8b86-d011-b42d-00cf4fc964ff");
        for raw in [
            "",
            "6f9619ff8b86d011b42d00cf4fc964ff",
            "6f9619ff-8b86-d011-b42d-00cf4fc964f",
            "../8b86-d011-b42d-00cf4fc964ff-xxxxx",
            "6f9619ff-8b86-d011-b42d-00cf4fc964fg",
        ] {
            assert_eq!(UploadId::parse(raw), None, "{raw:?}");
        }
    }

    #[tokio::test]
    async fn stores_a_verified_body_once_at_its_canonical_path() {
        let (store, _root) = temp_store();
        let bytes = b"hello upload";
        let upload = id(1);

        let stored = store_whole(&store, &upload, "Q3 report.txt", bytes).await;

        assert_eq!(
            stored.path,
            store.dir.join(upload.as_str()).join("Q3-report.txt")
        );
        assert_eq!(stored.bytes, bytes.len() as u64);
        assert_eq!(std::fs::read(&stored.path).expect("file"), bytes);
        assert!(!stored.path.with_file_name(PARTIAL_NAME).exists());
        assert_eq!(
            store.status(&upload),
            Ok(UploadStatus::Stored(stored.clone()))
        );
        assert_eq!(
            store_whole(&store, &upload, "renamed.txt", bytes).await,
            stored
        );
        assert_eq!(
            reopen(&store).status(&upload),
            Ok(UploadStatus::Stored(stored))
        );
        assert_eq!(store.status(&id(2)), Ok(UploadStatus::Absent));
    }

    #[tokio::test]
    async fn rejects_bad_declarations_and_appends_before_writing() {
        let (store, _root) = temp_store();
        let bytes = b"payload";
        let sha = digest(bytes);
        let whole = from(0, bytes);
        for (declaration, expected) in [
            (declare("...", bytes, &sha), UploadError::InvalidName),
            (declare("a.txt", bytes, "xyz"), UploadError::InvalidHash),
            (
                Declaration {
                    name: "a.txt",
                    length: 0,
                    sha256: &sha,
                },
                UploadError::InvalidLength,
            ),
            (
                Declaration {
                    name: "a.txt",
                    length: MAX_UPLOAD_BYTES + 1,
                    sha256: &sha,
                },
                UploadError::InvalidLength,
            ),
        ] {
            assert_eq!(
                store
                    .append(&id(1), declaration, whole, body(&[bytes]))
                    .await,
                Err(expected)
            );
        }
        assert_eq!(
            store
                .append(
                    &id(1),
                    declare("a.txt", bytes, &sha),
                    from(3, bytes),
                    body(&[&bytes[3..]])
                )
                .await,
            Err(UploadError::OffsetMismatch { offset: 0 })
        );
        assert_eq!(std::fs::read_dir(&store.dir).expect("dir").count(), 0);

        let first = store
            .append(
                &id(1),
                declare("a.txt", bytes, &sha),
                from(0, bytes),
                body(&[&bytes[..3]]),
            )
            .await;
        assert_eq!(
            first,
            Err(UploadError::Interrupted("the body ended early".to_string()))
        );
        let other = digest(b"other");
        assert_eq!(
            store
                .append(
                    &id(1),
                    declare("a.txt", bytes, &other),
                    from(3, bytes),
                    body(&[&bytes[3..]])
                )
                .await,
            Err(UploadError::DeclarationMismatch)
        );
        assert_eq!(
            store
                .append(
                    &id(1),
                    declare("a.txt", bytes, &sha),
                    Append {
                        offset: 3,
                        content_length: 5
                    },
                    body(&[b"yload!"])
                )
                .await,
            Err(UploadError::LengthMismatch {
                declared: 4,
                received: 5
            })
        );
        assert_eq!(
            store
                .append(
                    &id(1),
                    declare("a.txt", bytes, &sha),
                    Append {
                        offset: 3,
                        content_length: 2
                    },
                    body(&[b"yl"])
                )
                .await,
            Err(UploadError::LengthMismatch {
                declared: 4,
                received: 2
            })
        );
        assert_eq!(
            store.status(&id(1)),
            Ok(UploadStatus::Incomplete { offset: 3 })
        );
    }

    #[tokio::test]
    async fn an_interrupted_append_keeps_its_bytes_and_continues_at_its_offset() {
        let (store, _root) = temp_store();
        let bytes = file(3 * MIB);
        let sha = digest(&bytes);
        let upload = id(1);
        let interrupted = stream::iter([
            Ok(Bytes::copy_from_slice(&bytes[..MIB])),
            Err("connection reset"),
        ]);

        let outcome = store
            .append(
                &upload,
                declare("clip.mov", &bytes, &sha),
                from(0, &bytes),
                interrupted,
            )
            .await;

        assert_eq!(
            outcome,
            Err(UploadError::Interrupted("connection reset".into()))
        );
        assert_eq!(
            store.status(&upload),
            Ok(UploadStatus::Incomplete { offset: MIB as u64 })
        );
        assert_eq!(
            store
                .append(
                    &upload,
                    declare("clip.mov", &bytes, &sha),
                    from(0, &bytes),
                    body(&[&bytes])
                )
                .await,
            Err(UploadError::OffsetMismatch { offset: MIB as u64 })
        );
        let rest = store
            .append(
                &upload,
                declare("clip.mov", &bytes, &sha),
                from(MIB, &bytes),
                body(&[&bytes[MIB..]]),
            )
            .await;
        let Ok(stored) = rest else {
            panic!("not stored: {rest:?}");
        };
        assert_eq!(std::fs::read(stored.path).expect("file"), bytes);
    }

    #[tokio::test]
    async fn a_restart_continues_from_the_partial_file() {
        let (store, _root) = temp_store();
        let bytes = file(2 * MIB + 17);
        let sha = digest(&bytes);
        let upload = id(1);
        assert_eq!(
            store
                .append(
                    &upload,
                    declare("clip.mov", &bytes, &sha),
                    from(0, &bytes),
                    body(&[&bytes[..MIB]])
                )
                .await,
            Err(UploadError::Interrupted("the body ended early".to_string()))
        );

        let restarted = reopen(&store);

        assert_eq!(
            restarted.status(&upload),
            Ok(UploadStatus::Incomplete { offset: MIB as u64 })
        );
        let rest = restarted
            .append(
                &upload,
                declare("clip.mov", &bytes, &sha),
                from(MIB, &bytes),
                body(&[&bytes[MIB..]]),
            )
            .await;
        let Ok(stored) = rest else {
            panic!("not stored: {rest:?}");
        };
        assert_eq!(std::fs::read(stored.path).expect("file"), bytes);
    }

    #[tokio::test]
    async fn a_full_length_partial_left_by_a_crash_is_named_without_resending() {
        let (store, _root) = temp_store();
        let bytes = b"every byte arrived before the crash";
        let sha = digest(bytes);
        let upload = id(1);
        let dir = store.dir.join(upload.as_str());
        create_private_dir(&dir).expect("dir");
        std::fs::write(dir.join(PARTIAL_NAME), bytes).expect("partial");
        write_record(
            &dir,
            &SessionRecord {
                name: "notes.txt".into(),
                length: bytes.len() as u64,
                sha256: sha.clone(),
            },
        )
        .expect("record");

        let restarted = reopen(&store);

        assert_eq!(
            restarted.status(&upload),
            Ok(UploadStatus::Incomplete {
                offset: bytes.len() as u64
            })
        );
        let finished = restarted
            .append(
                &upload,
                declare("notes.txt", bytes, &sha),
                from(bytes.len(), bytes),
                body(&[]),
            )
            .await;
        let Ok(stored) = finished else {
            panic!("not stored: {finished:?}");
        };
        assert_eq!(stored.path, dir.join("notes.txt"));
        assert_eq!(std::fs::read(stored.path).expect("file"), bytes);
    }

    #[tokio::test]
    async fn a_digest_mismatch_discards_the_upload() {
        let (store, _root) = temp_store();
        let bytes = b"payload";
        let wrong = digest(b"something else");
        let upload = id(1);

        let outcome = store
            .append(
                &upload,
                declare("a.txt", bytes, &wrong),
                from(0, bytes),
                body(&[bytes]),
            )
            .await;

        assert_eq!(outcome, Err(UploadError::HashMismatch));
        assert_eq!(store.status(&upload), Ok(UploadStatus::Absent));
        assert!(!store.dir.join(upload.as_str()).exists());
    }

    #[tokio::test]
    async fn a_newer_append_takes_over_from_a_writer_whose_client_is_gone() {
        let (store, _root) = temp_store();
        let bytes = file(2 * MIB);
        let sha = digest(&bytes);
        let upload = id(1);
        let abandoned = {
            let (store, upload, bytes, sha) =
                (store.clone(), upload.clone(), bytes.clone(), sha.clone());
            tokio::spawn(async move {
                store
                    .append(
                        &upload,
                        declare("clip.mov", &bytes, &sha),
                        from(0, &bytes),
                        stalled_after(&bytes[..MIB]),
                    )
                    .await
            })
        };
        wait_for_offset(&store, &upload, MIB as u64).await;

        let rest = store
            .append(
                &upload,
                declare("clip.mov", &bytes, &sha),
                from(MIB, &bytes),
                body(&[&bytes[MIB..]]),
            )
            .await;

        assert!(rest.is_ok(), "{rest:?}");
        assert_eq!(abandoned.await.expect("task"), Err(UploadError::Superseded));
        assert_eq!(store.writers.available_permits(), MAX_WRITERS);
    }

    #[tokio::test]
    async fn a_dropped_append_leaves_the_offset_matching_the_file() {
        let (store, _root) = temp_store();
        let bytes = file(2 * MIB);
        let sha = digest(&bytes);
        let upload = id(1);
        let dropped = {
            let (store, upload, bytes, sha) =
                (store.clone(), upload.clone(), bytes.clone(), sha.clone());
            tokio::spawn(async move {
                store
                    .append(
                        &upload,
                        declare("clip.mov", &bytes, &sha),
                        from(0, &bytes),
                        stalled_after(&bytes[..MIB]),
                    )
                    .await
            })
        };
        wait_for_offset(&store, &upload, MIB as u64).await;

        dropped.abort();
        assert!(dropped.await.expect_err("aborted").is_cancelled());

        let partial = store.dir.join(upload.as_str()).join(PARTIAL_NAME);
        assert_eq!(
            std::fs::metadata(partial).expect("partial").len(),
            MIB as u64
        );
        let rest = store
            .append(
                &upload,
                declare("clip.mov", &bytes, &sha),
                from(MIB, &bytes),
                body(&[&bytes[MIB..]]),
            )
            .await;
        assert!(rest.is_ok(), "{rest:?}");
        assert_eq!(store.writers.available_permits(), MAX_WRITERS);
    }

    #[tokio::test]
    async fn a_body_that_goes_quiet_ends_the_append_and_keeps_its_bytes() {
        let (mut store, _root) = temp_store();
        store.idle_timeout = Duration::from_millis(50);
        let bytes = b"payload that never finishes";
        let sha = digest(bytes);

        let outcome = store
            .append(
                &id(1),
                declare("a.bin", bytes, &sha),
                from(0, bytes),
                stalled_after(b"payl"),
            )
            .await;

        assert_eq!(outcome, Err(UploadError::Stalled));
        assert_eq!(
            store.status(&id(1)),
            Ok(UploadStatus::Incomplete { offset: 4 })
        );
        assert_eq!(store.writers.available_permits(), MAX_WRITERS);
    }

    #[tokio::test]
    async fn a_slow_but_steady_body_is_not_cut_off_by_the_idle_timeout() {
        let (mut store, _root) = temp_store();
        store.idle_timeout = Duration::from_millis(200);
        let bytes = b"abcdef";
        let sha = digest(bytes);
        let paced = Box::pin(stream::unfold(0usize, move |sent| async move {
            if sent == bytes.len() {
                return None;
            }
            tokio::time::sleep(Duration::from_millis(80)).await;
            Some((
                Ok::<_, Infallible>(Bytes::copy_from_slice(&bytes[sent..=sent])),
                sent + 1,
            ))
        }));

        let outcome = store
            .append(&id(1), declare("a.txt", bytes, &sha), from(0, bytes), paced)
            .await;

        assert!(outcome.is_ok(), "{outcome:?}");
    }

    #[tokio::test]
    async fn draining_ends_streaming_appends_and_keeps_their_bytes() {
        let (store, _root) = temp_store();
        let bytes = b"payload that never finishes";
        let sha = digest(bytes);
        let streaming = {
            let (store, sha) = (store.clone(), sha.clone());
            tokio::spawn(async move {
                store
                    .append(
                        &id(1),
                        declare("a.bin", bytes, &sha),
                        from(0, bytes),
                        stalled_after(b"payl"),
                    )
                    .await
            })
        };
        wait_for_offset(&store, &id(1), 4).await;

        store.drain();

        assert_eq!(streaming.await.expect("task"), Err(UploadError::Draining));
        assert_eq!(
            store
                .append(
                    &id(1),
                    declare("a.bin", bytes, &sha),
                    from(4, bytes),
                    body(&[&bytes[4..]])
                )
                .await,
            Err(UploadError::Draining)
        );
        assert_eq!(
            reopen(&store).status(&id(1)),
            Ok(UploadStatus::Incomplete { offset: 4 })
        );
    }

    #[tokio::test]
    async fn appends_beyond_the_writer_limit_are_refused() {
        let (store, _root) = temp_store();
        let bytes = b"payload that never finishes";
        let sha = digest(bytes);
        let streaming: Vec<_> = (0..MAX_WRITERS as u32)
            .map(|number| {
                let (store, sha) = (store.clone(), sha.clone());
                tokio::spawn(async move {
                    store
                        .append(
                            &id(number),
                            declare("a.bin", bytes, &sha),
                            from(0, bytes),
                            stalled_after(b"payl"),
                        )
                        .await
                })
            })
            .collect();
        wait_for_writers(&store, 0).await;

        assert_eq!(
            store
                .append(
                    &id(99),
                    declare("late.bin", bytes, &sha),
                    from(0, bytes),
                    body(&[bytes])
                )
                .await,
            Err(UploadError::Busy)
        );

        store.drain();
        for append in streaming {
            assert_eq!(append.await.expect("task"), Err(UploadError::Draining));
        }
        assert_eq!(store.writers.available_permits(), MAX_WRITERS);
    }

    #[tokio::test]
    async fn discarding_removes_only_unfinished_uploads() {
        let (store, _root) = temp_store();
        let bytes = b"payload that never finishes";
        let sha = digest(bytes);
        let streaming = {
            let (store, sha) = (store.clone(), sha.clone());
            tokio::spawn(async move {
                store
                    .append(
                        &id(1),
                        declare("a.bin", bytes, &sha),
                        from(0, bytes),
                        stalled_after(b"payl"),
                    )
                    .await
            })
        };
        wait_for_offset(&store, &id(1), 4).await;

        assert_eq!(store.discard(&id(1)).await, Ok(()));

        assert_eq!(streaming.await.expect("task"), Err(UploadError::Superseded));
        assert_eq!(store.status(&id(1)), Ok(UploadStatus::Absent));
        assert!(!store.dir.join(id(1).as_str()).exists());
        let stored = store_whole(&store, &id(2), "kept.txt", b"kept").await;
        assert_eq!(store.discard(&id(2)).await, Err(UploadError::AlreadyStored));
        assert!(stored.path.exists());
        assert_eq!(store.discard(&id(3)).await, Ok(()));
    }

    #[tokio::test]
    async fn a_dropped_discard_still_removes_the_upload() {
        let (store, _root) = temp_store();
        let bytes = b"payload that never finishes";
        let sha = digest(bytes);
        let appended = store
            .append(
                &id(1),
                declare("a.bin", bytes, &sha),
                from(0, bytes),
                body(&[b"payl"]),
            )
            .await;
        assert_eq!(
            appended,
            Err(UploadError::Interrupted("the body ended early".to_string()))
        );
        let busy = Arc::clone(&store.session(&id(1)).expect("session").state)
            .lock_owned()
            .await;

        let dropped = tokio::time::timeout(Duration::from_millis(20), store.discard(&id(1))).await;
        assert!(dropped.is_err());
        drop(busy);

        for _ in 0..200 {
            if !store.dir.join(id(1).as_str()).exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(!store.dir.join(id(1).as_str()).exists());
        assert_eq!(store.status(&id(1)), Ok(UploadStatus::Absent));
        let again = store
            .append(
                &id(1),
                declare("a.bin", bytes, &sha),
                from(0, bytes),
                body(&[bytes]),
            )
            .await;
        assert!(again.is_ok(), "{again:?}");
    }

    #[tokio::test]
    async fn admission_reserves_what_unfinished_uploads_still_need() {
        let (store, _root) = temp_store();
        let record = |length: u64| SessionRecord {
            name: "a.bin".into(),
            length,
            sha256: "0".repeat(64),
        };
        let free = |_: &Path| Ok(MIN_FREE_BYTES_AFTER_WRITE + 1024);

        store.create(&id(1), record(600), free).expect("first fits");

        assert_eq!(
            store.create(&id(2), record(600), free).err(),
            Some(UploadError::InsufficientStorage)
        );
        assert!(store.create(&id(3), record(424), free).is_ok());
        let missing = store.dir.join("missing");
        assert!(matches!(
            store.create(&id(4), record(1), |_: &Path| free_bytes(&missing)),
            Err(UploadError::Io(_))
        ));
        let plenty = |_: &Path| Ok(u64::MAX);
        for number in 5..(MAX_INCOMPLETE as u32 + 3) {
            store
                .create(&id(number), record(1), plenty)
                .expect("within the limit");
        }
        assert_eq!(
            store.create(&id(99), record(1), plenty).err(),
            Some(UploadError::TooManyIncomplete)
        );
    }

    fn backdate(store: &UploadStore, upload: &UploadId, idle: Duration) {
        store
            .session(upload)
            .expect("unfinished upload")
            .touched
            .store(epoch_seconds(SystemTime::now() - idle), Ordering::Release);
    }

    #[tokio::test]
    async fn a_new_upload_evicts_idle_unfinished_ones_only_when_it_needs_their_room() {
        let (store, _root) = temp_store();
        let record = |length: u64| SessionRecord {
            name: "a.bin".into(),
            length,
            sha256: "0".repeat(64),
        };
        let free = |_: &Path| Ok(MIN_FREE_BYTES_AFTER_WRITE + 1000);
        store.create(&id(1), record(600), free).expect("first fits");
        backdate(&store, &id(1), SESSION_IDLE_EVICTION * 2);

        store
            .create(&id(2), record(300), free)
            .expect("fits beside the idle upload");
        assert!(
            store.session(&id(1)).is_some(),
            "an idle upload keeps its reservation while nothing needs it"
        );

        store
            .create(&id(3), record(500), free)
            .expect("fits once the idle upload goes");
        assert!(store.session(&id(1)).is_none());
        assert!(!store.dir.join(id(1).as_str()).exists());
        assert_eq!(
            store.create(&id(4), record(500), free).err(),
            Some(UploadError::InsufficientStorage)
        );
        assert!(store.session(&id(2)).is_some() && store.session(&id(3)).is_some());
    }

    #[tokio::test]
    async fn a_full_store_evicts_the_most_idle_upload_only_when_that_admits_the_new_one() {
        let (store, _root) = temp_store();
        let record = |length: u64| SessionRecord {
            name: "a.bin".into(),
            length,
            sha256: "0".repeat(64),
        };
        let plenty = |_: &Path| Ok(u64::MAX);
        for number in 1..=MAX_INCOMPLETE as u32 {
            store
                .create(&id(number), record(1), plenty)
                .expect("within the limit");
        }
        backdate(&store, &id(2), SESSION_IDLE_EVICTION * 2);
        backdate(&store, &id(3), SESSION_IDLE_EVICTION * 3);

        let tight = |_: &Path| Ok(MIN_FREE_BYTES_AFTER_WRITE);
        assert_eq!(
            store.create(&id(99), record(1000), tight).err(),
            Some(UploadError::InsufficientStorage)
        );
        assert!(store.session(&id(2)).is_some() && store.session(&id(3)).is_some());

        store
            .create(&id(99), record(1), plenty)
            .expect("fits once the most idle upload goes");
        assert!(store.session(&id(3)).is_none());
        assert!(store.session(&id(2)).is_some());
    }

    #[tokio::test]
    async fn the_store_evicts_its_oldest_finished_uploads_to_stay_within_budget() {
        let (mut store, _root) = temp_store();
        store.budget = 10_000;
        let oldest = store_whole(&store, &id(1), "oldest.bin", &[1; 4000]).await;
        let newer = store_whole(&store, &id(2), "newer.bin", &[2; 4000]).await;
        let an_hour_ago = SystemTime::now() - Duration::from_secs(3600);
        std::fs::File::open(oldest.path.parent().expect("dir"))
            .expect("open")
            .set_modified(an_hour_ago)
            .expect("set mtime");
        let record = |length: u64| SessionRecord {
            name: "c.bin".into(),
            length,
            sha256: "0".repeat(64),
        };
        let plenty = |_: &Path| Ok(u64::MAX);

        store
            .create(&id(3), record(4000), plenty)
            .expect("fits after eviction");

        assert!(
            !oldest.path.exists(),
            "the oldest finished upload makes room"
        );
        assert!(newer.path.exists());
        assert_eq!(
            store.create(&id(4), record(6000), plenty).err(),
            Some(UploadError::InsufficientStorage)
        );
        assert!(
            newer.path.exists(),
            "nothing is evicted when eviction cannot make room"
        );
    }

    #[tokio::test]
    async fn startup_removes_expired_and_abandoned_uploads_only() {
        let (store, _root) = temp_store();
        let fresh = store_whole(&store, &id(1), "fresh.txt", b"x").await;
        let expired = store_whole(&store, &id(2), "expired.txt", b"x").await;
        let bytes = b"unfinished";
        let sha = digest(bytes);
        for number in [3, 4] {
            store
                .append(
                    &id(number),
                    declare("u.bin", bytes, &sha),
                    from(0, bytes),
                    body(&[&bytes[..4]]),
                )
                .await
                .expect_err("unfinished");
        }
        let orphan = store.dir.join(id(5).as_str());
        create_private_dir(&orphan).expect("dir");
        std::fs::write(orphan.join(PARTIAL_NAME), b"no record").expect("partial");
        let set_modified = |path: &Path, age: Duration| {
            std::fs::File::open(path)
                .expect("open")
                .set_modified(SystemTime::now() - age)
                .expect("set mtime");
        };
        set_modified(
            expired.path.parent().expect("dir"),
            RETENTION + Duration::from_secs(60),
        );
        let idle = store.dir.join(id(4).as_str()).join(PARTIAL_NAME);
        set_modified(&idle, INCOMPLETE_RETENTION + Duration::from_secs(60));

        let restarted = reopen(&store);

        assert!(fresh.path.exists());
        assert!(!expired.path.parent().expect("dir").exists());
        assert_eq!(
            restarted.status(&id(3)),
            Ok(UploadStatus::Incomplete { offset: 4 })
        );
        assert_eq!(restarted.status(&id(4)), Ok(UploadStatus::Absent));
        assert!(!orphan.exists());
    }

    #[tokio::test]
    async fn photo_moves_verify_completed_uploads_and_never_replace_an_existing_original() {
        let (store, root) = temp_store();
        let destination = root.path().join("Pictures/RemoteCoder/2026-10-04");
        let bytes = b"fixture original";
        let first = store_whole(&store, &id(1), "original.jpg", bytes).await;
        let mut invalid = first.clone();
        invalid.sha256 = "0".repeat(64);
        assert!(
            store
                .move_verified(invalid, destination.clone(), "120000-back-wide".into())
                .await
                .unwrap_err()
                .to_string()
                .contains("SHA-256")
        );
        let mut invalid = first.clone();
        invalid.bytes += 1;
        assert!(
            store
                .move_verified(invalid, destination.clone(), "120000-back-wide".into())
                .await
                .unwrap_err()
                .to_string()
                .contains("size")
        );
        let outside = root.path().join("outside.jpg");
        std::fs::write(&outside, bytes).unwrap();
        let mut invalid = first.clone();
        invalid.path = outside;
        assert!(
            store
                .move_verified(invalid, destination.clone(), "120000-back-wide".into())
                .await
                .unwrap_err()
                .to_string()
                .contains("outside")
        );
        let mut record = first.clone();
        record.path = first.path.with_file_name(SESSION_NAME);
        assert!(
            store
                .move_verified(record, destination.clone(), "120000-back-wide".into())
                .await
                .is_err()
        );
        let mut missing = first.clone();
        missing.path = store.dir.join("missing/absent.jpg");
        assert!(
            store
                .move_verified(missing, destination.clone(), "120000-back-wide".into())
                .await
                .is_err()
        );
        std::fs::write(first.path.with_file_name(PARTIAL_NAME), bytes).unwrap();
        assert!(
            store
                .move_verified(
                    first.clone(),
                    destination.clone(),
                    "120000-back-wide".into()
                )
                .await
                .unwrap_err()
                .to_string()
                .contains("incomplete")
        );
        std::fs::remove_file(first.path.with_file_name(PARTIAL_NAME)).unwrap();
        let saved = store
            .move_verified(
                first.clone(),
                destination.clone(),
                "120000-back-wide".into(),
            )
            .await
            .unwrap();
        assert_eq!(saved, destination.join("120000-back-wide.jpg"));
        assert_eq!(std::fs::read(&saved).unwrap(), bytes);
        assert!(!first.path.exists());
        let second = store_whole(&store, &id(2), "other.jpg", b"another").await;
        let saved_second = store
            .move_verified(second, destination.clone(), "120000-back-wide".into())
            .await
            .unwrap();
        assert_eq!(saved_second, destination.join("120000-back-wide-1.jpg"));
        assert_eq!(std::fs::read(saved_second).unwrap(), b"another");
        assert_eq!(std::fs::read(saved).unwrap(), bytes);
    }

    #[tokio::test]
    async fn concurrent_photo_moves_use_exclusive_names_without_waiting_on_a_store_lock() {
        let (store, root) = temp_store();
        let lock = std::fs::File::create(store.dir.join(".photo-moves.lock")).unwrap();
        lock.lock().unwrap();
        let first = store_whole(&store, &id(1), "first.jpg", b"first").await;
        let second = store_whole(&store, &id(2), "second.jpg", b"second").await;
        let destination = root.path().join("photos");
        let (first, second) = tokio::time::timeout(Duration::from_secs(2), async {
            tokio::join!(
                store.move_verified(first, destination.clone(), "120000-back-wide".into()),
                store.move_verified(second, destination.clone(), "120000-back-wide".into())
            )
        })
        .await
        .unwrap();
        let first = first.unwrap();
        let second = second.unwrap();
        assert_ne!(first, second);
        assert_eq!(std::fs::read(first).unwrap(), b"first");
        assert_eq!(std::fs::read(second).unwrap(), b"second");
    }

    #[test]
    fn sanitize_keeps_readable_names_without_unsafe_components() {
        for (raw, expected) in [
            ("report.pdf", Some("report.pdf")),
            ("Q3 report (final).PDF", Some("Q3-report-final.PDF")),
            ("årsredovisning 2025.xlsx", Some("årsredovisning-2025.xlsx")),
            ("archive.tar.gz", Some("archive.tar.gz")),
            ("Makefile", Some("Makefile")),
            ("../../etc/passwd", Some("etc-passwd")),
            ("/tmp/x.txt", Some("tmp-x.txt")),
            (".env", Some("env")),
            (".partial", Some("partial")),
            ("--rm", Some("rm")),
            ("a b;c$d`e'f\"g.sh", Some("a-b-c-d-e-f-g.sh")),
            ("...", None),
            ("   ", None),
            ("!!!", None),
        ] {
            assert_eq!(sanitize_file_name(raw).as_deref(), expected, "{raw:?}");
        }
    }

    #[test]
    fn sanitize_truncates_the_stem_and_keeps_the_extension() {
        let long = format!("{}.pdf", "a".repeat(300));
        let cleaned = sanitize_file_name(&long).expect("name");
        assert_eq!(cleaned.chars().count(), MAX_NAME_LENGTH);
        assert!(cleaned.ends_with(".pdf"));

        // A "extension" longer than any real one gets no budget of its own.
        let long_extension = format!("a.{}", "b".repeat(300));
        let cleaned = sanitize_file_name(&long_extension).expect("name");
        assert_eq!(cleaned.chars().count(), MAX_NAME_LENGTH);
    }

    #[test]
    fn sanitize_bounds_names_in_bytes_as_well_as_letters() {
        for letter in ['ä', '文', '𝒜'] {
            let long = format!("{}.pdf", letter.to_string().repeat(128));
            let cleaned = sanitize_file_name(&long).expect("name");
            assert!(
                cleaned.len() <= MAX_NAME_BYTES,
                "{letter}: {}",
                cleaned.len()
            );
            assert!(cleaned.ends_with(".pdf"), "{letter}");
            assert!(cleaned.starts_with(letter), "{letter}");
        }
    }
}
