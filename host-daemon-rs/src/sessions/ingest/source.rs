use super::{InvalidHeader, companions, file_identity, identity, normalize};
use crate::providers::claude::records::{LineKind, MAX_SESSION_RECORD_BYTES, read_bounded_line};
use crate::sessions::{Origin, metadata};
use crate::storage::file_revision::FileRevision;
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;
use std::collections::BTreeSet;
use std::fs::{File, Metadata};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

const FINGERPRINT_WINDOW: u64 = 64 << 10;

struct RecordReader<R: Read> {
    input: BufReader<R>,
    hash: blake3::Hasher,
}

impl<R: Read> RecordReader<R> {
    fn new(input: R) -> Self {
        Self {
            input: BufReader::new(input),
            hash: blake3::Hasher::new(),
        }
    }
}

impl<R: Read> Read for RecordReader<R> {
    fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
        let count = self.input.read(bytes)?;
        self.hash.update(&bytes[..count]);
        Ok(count)
    }
}

impl<R: Read> BufRead for RecordReader<R> {
    fn fill_buf(&mut self) -> std::io::Result<&[u8]> {
        self.input.fill_buf()
    }
    fn consume(&mut self, length: usize) {
        self.hash.update(&self.input.buffer()[..length]);
        self.input.consume(length);
    }
}

fn chain_record(previous: blake3::Hash, record: blake3::Hash) -> blake3::Hash {
    let mut chain = blake3::Hasher::new();
    chain.update(previous.as_bytes());
    chain.update(record.as_bytes());
    chain.finalize()
}

fn verify_prefix(path: &Path, length: u64, expected: &str, stop: &AtomicBool) -> Result<bool> {
    let mut reader = RecordReader::new(File::open(path)?.take(length));
    let mut line = Vec::new();
    let mut read = 0;
    let mut chain = blake3::hash(&[]);
    loop {
        ensure!(!stop.load(Ordering::Acquire), "Session ingestion cancelled");
        line.clear();
        reader.hash.reset();
        let (count, kind) = read_bounded_line(&mut reader, &mut line, MAX_SESSION_RECORD_BYTES)?;
        if count == 0 {
            break;
        }
        if kind == LineKind::Partial {
            return Ok(false);
        }
        chain = chain_record(chain, reader.hash.finalize());
        read += count;
    }
    Ok(read == length && chain.to_hex().as_str() == expected)
}

fn fingerprint(file: &mut File, length: u64) -> Result<(String, String)> {
    let window = length.min(FINGERPRINT_WINDOW);
    file.seek(SeekFrom::Start(0))?;
    let mut head = blake3::Hasher::new();
    ensure!(
        std::io::copy(&mut (&mut *file).take(window), &mut head)? == window,
        "Source shortened during fingerprint"
    );
    let head = head.finalize().to_hex().to_string();
    if length <= FINGERPRINT_WINDOW {
        return Ok((head.clone(), head));
    }
    file.seek(SeekFrom::Start(length - window))?;
    let mut tail = blake3::Hasher::new();
    ensure!(
        std::io::copy(&mut file.take(window), &mut tail)? == window,
        "Source shortened during fingerprint"
    );
    Ok((head, tail.finalize().to_hex().to_string()))
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum ReadMode {
    Full,
    Incremental,
    Inventory,
}

#[cfg(test)]
pub(crate) fn ingest(
    db: &mut Connection,
    origin: &Origin,
    path: &Path,
    stop: &AtomicBool,
) -> Result<bool> {
    Ok(matches!(
        ingest_source(db, origin, path, stop, ReadMode::Full, &|| false)?,
        ReadOutcome::Saved
    ))
}

#[derive(Clone, Default, serde::Deserialize, serde::Serialize)]
#[serde(default)]
struct AppendState {
    head: String,
    tail: String,
    verified_revision: i64,
    gap_records: u64,
    first_gap: Option<(u64, u64)>,
    checkpointed: bool,
}

struct Previous {
    id: i64,
    stamp: String,
    offset: u64,
    chain: String,
    parser: String,
    revision: i64,
    present: bool,
    append: AppendState,
    size: u64,
}

pub(super) enum ReadOutcome {
    Unchanged,
    Saved,
    Checkpoint,
    Yield,
}

pub(super) fn ingest_source(
    db: &mut Connection,
    origin: &Origin,
    path: &Path,
    stop: &AtomicBool,
    mode: ReadMode,
    inventory_waiting: &dyn Fn() -> bool,
) -> Result<ReadOutcome> {
    let mut file = File::open(path)?;
    let before = file.metadata()?;
    ensure!(before.is_file(), "Session source is not a regular file");
    let stamp = identity(&before);
    let original = origin.original(path)?.to_string_lossy().into_owned();
    let prior = previous_source(db, origin, &original)?;
    let companions = if mode != ReadMode::Inventory {
        companions(origin, path)?
    } else {
        Vec::new()
    };
    let read = SourceRead {
        origin,
        path,
        stop,
        mode,
        before: &before,
        stamp: &stamp,
        prior: prior.as_ref(),
        companions,
    };
    let changes = dependency_changes(db, origin, read.prior, &read.companions)?;
    let previous = match read.plan(db, &mut file, changes)? {
        ReadPlan::Finished(outcome) => return Ok(outcome),
        ReadPlan::Parse(previous) => previous,
    };
    let can_checkpoint = previous.is_some()
        || read
            .prior
            .is_none_or(|previous| previous.offset == 0 || previous.stamp.is_empty());
    let mut progress = RecordProgress::from_previous(previous)?;
    let revision = prior.as_ref().map_or(1, |previous| previous.revision + 1);
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    tx.execute("INSERT OR IGNORE INTO source(origin_host,provider,provider_home,path,local_path,file_identity,size,mtime_ns,ingested_offset,revision,present,prefix_hash,parser_state) VALUES(?1,?2,?3,?4,?5,'',0,0,0,0,1,'','{}')",params![origin.host,origin.provider,origin.provider_home.to_string_lossy(),original,path.to_string_lossy()])?;
    let source: i64 = tx.query_row(
        "SELECT source_id FROM source WHERE origin_host=?1 AND path=?2",
        params![origin.host, original],
        |row| row.get(0),
    )?;
    let metadata = if previous.is_some() {
        None
    } else {
        let metadata = metadata::source_metadata(&tx, source)?;
        tx.execute("DELETE FROM session WHERE source_id=?1", [source])?;
        tx.execute("DELETE FROM dependency WHERE source_id=?1", [source])?;
        metadata
    };
    let target = RecordTarget {
        db: &tx,
        source,
        revision,
    };
    let checkpointed = match read.records(
        &mut file,
        &target,
        &mut progress,
        can_checkpoint,
        inventory_waiting,
    )? {
        RecordBoundary::Yield => return Ok(ReadOutcome::Yield),
        RecordBoundary::Checkpoint => true,
        RecordBoundary::End => false,
    };
    normalize::save_session(&tx, origin, source, &progress.state)?;
    if previous.is_none() {
        metadata::source_replaced(
            &tx,
            origin,
            metadata.as_ref(),
            progress.state.thread.as_deref(),
        )?;
    }
    if mode != ReadMode::Inventory && !checkpointed {
        refresh_dependencies(&tx, origin, source, &read.companions)?;
    }
    read.save(&mut file, &target, progress, previous, checkpointed)?;
    tx.commit()?;
    Ok(if checkpointed {
        ReadOutcome::Checkpoint
    } else {
        ReadOutcome::Saved
    })
}

fn previous_source(db: &Connection, origin: &Origin, original: &str) -> Result<Option<Previous>> {
    let prior = db.query_row("SELECT source_id,file_identity,ingested_offset,prefix_hash,parser_state,revision,present,append_state,size FROM source WHERE origin_host=?1 AND path=?2", params![origin.host,original], |row| {
        let unsigned = |index: usize| -> rusqlite::Result<u64> {
            u64::try_from(row.get::<_,i64>(index)?).map_err(|error|rusqlite::Error::FromSqlConversionFailure(index,rusqlite::types::Type::Integer,Box::new(error)))
        };
        let saved: String = row.get(7)?;
        let append = serde_json::from_str(&saved).map_err(|error| rusqlite::Error::FromSqlConversionFailure(7,rusqlite::types::Type::Text,Box::new(error)))?;
        Ok(Previous {id:row.get(0)?,stamp:row.get(1)?,offset:unsigned(2)?,chain:row.get(3)?,parser:row.get(4)?,revision:row.get(5)?,present:row.get(6)?,append,size:unsigned(8)?})
    }).optional()?;
    Ok(prior)
}

struct DependencyChanges {
    sidecar: bool,
    evidence: bool,
}

fn dependency_changes(
    db: &Connection,
    origin: &Origin,
    prior: Option<&Previous>,
    companions: &[PathBuf],
) -> Result<DependencyChanges> {
    let mut sidecar_changed = false;
    let mut evidence_changed = false;
    if let Some(previous) = prior {
        let dependencies: Vec<(String, String, String, Option<String>)> = db
            .prepare("SELECT path,local_path,kind,identity FROM dependency WHERE source_id=?1")?
            .query_map([previous.id], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })?
            .collect::<rusqlite::Result<_>>()?;
        let mut known = BTreeSet::new();
        for (path, local, kind, old) in dependencies {
            if file_identity(Path::new(&local))? != old {
                if kind == "sidecar" {
                    sidecar_changed = true;
                } else {
                    evidence_changed = true;
                }
            }
            known.insert(path);
        }
        for companion in companions {
            evidence_changed |=
                !known.contains(&origin.original(companion)?.to_string_lossy().into_owned());
        }
    }
    Ok(DependencyChanges {
        sidecar: sidecar_changed,
        evidence: evidence_changed,
    })
}

struct SourceRead<'a> {
    origin: &'a Origin,
    path: &'a Path,
    stop: &'a AtomicBool,
    mode: ReadMode,
    before: &'a Metadata,
    stamp: &'a str,
    prior: Option<&'a Previous>,
    companions: Vec<PathBuf>,
}

enum ReadPlan<'a> {
    Finished(ReadOutcome),
    Parse(Option<&'a Previous>),
}

struct RecordTarget<'a> {
    db: &'a Connection,
    source: i64,
    revision: i64,
}

struct RecordProgress {
    state: normalize::State,
    offset: u64,
    chain: blake3::Hash,
    gap_records: u64,
    first_gap: Option<(u64, u64)>,
}

impl RecordProgress {
    fn from_previous(previous: Option<&Previous>) -> Result<Self> {
        Ok(match previous {
            Some(previous) => Self {
                state: serde_json::from_str(&previous.parser)?,
                offset: previous.offset,
                chain: previous.chain.parse()?,
                gap_records: previous.append.gap_records,
                first_gap: previous.append.first_gap,
            },
            None => Self {
                state: normalize::State::default(),
                offset: 0,
                chain: blake3::hash(&[]),
                gap_records: 0,
                first_gap: None,
            },
        })
    }
}

enum RecordBoundary {
    End,
    Checkpoint,
    Yield,
}

impl SourceRead<'_> {
    fn plan(
        &self,
        db: &mut Connection,
        file: &mut File,
        changes: DependencyChanges,
    ) -> Result<ReadPlan<'_>> {
        let DependencyChanges {
            sidecar: sidecar_changed,
            evidence: evidence_changed,
        } = changes;
        let same_stamp = self
            .prior
            .is_some_and(|previous| previous.stamp == self.stamp && previous.present);
        let resuming = self
            .prior
            .is_some_and(|previous| previous.append.checkpointed);
        let mut verified = true;
        if let Some(previous) = self.prior
            && self.mode != ReadMode::Inventory
            && previous.offset > 0
            && !sidecar_changed
        {
            let mut append = previous.append.clone();
            let check = (self.mode == ReadMode::Full
                && (!same_stamp
                    || (!resuming && previous.append.verified_revision != previous.revision)))
                || (!same_stamp && self.before.len() == previous.size);
            if check {
                verified = self.before.len() >= previous.offset
                    && verify_prefix(self.path, previous.offset, &previous.chain, self.stop)?;
                append.verified_revision = previous.revision;
            }
            if !resuming
                && verified
                && self.before.len() == previous.size
                && !previous.stamp.is_empty()
            {
                if !check && !evidence_changed {
                    return Ok(ReadPlan::Finished(ReadOutcome::Unchanged));
                }
                let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
                if check {
                    tx.execute(
                    "UPDATE source SET file_identity=?1,mtime_ns=?2,present=1,append_state=?3 WHERE source_id=?4",
                    params![self.stamp, self.before.mtime() * 1_000_000_000 + self.before.mtime_nsec(), serde_json::to_string(&append)?, previous.id],
                )?;
                }
                if evidence_changed {
                    refresh_dependencies(&tx, self.origin, previous.id, &self.companions)?;
                }
                tx.commit()?;
                return Ok(ReadPlan::Finished(if evidence_changed {
                    ReadOutcome::Saved
                } else {
                    ReadOutcome::Unchanged
                }));
            }
        } else if same_stamp && !sidecar_changed && !evidence_changed {
            return Ok(ReadPlan::Finished(ReadOutcome::Unchanged));
        }
        let Some(previous) = self.prior else {
            return Ok(ReadPlan::Parse(None));
        };
        let append = previous.present
            && verified
            && !sidecar_changed
            && previous.offset > 0
            && (self.before.len() > previous.size
                || (resuming && self.before.len() >= previous.offset))
            && fingerprint(file, previous.offset)?
                == (previous.append.head.clone(), previous.append.tail.clone());
        Ok(ReadPlan::Parse(append.then_some(previous)))
    }

    fn records(
        &self,
        file: &mut File,
        target: &RecordTarget<'_>,
        progress: &mut RecordProgress,
        can_checkpoint: bool,
        inventory_waiting: &dyn Fn() -> bool,
    ) -> Result<RecordBoundary> {
        let RecordTarget {
            db,
            source,
            revision,
        } = *target;
        file.seek(SeekFrom::Start(progress.offset))?;
        let mut reader = RecordReader::new(file.take(self.before.len() - progress.offset));
        let mut line = Vec::new();
        let mut records = 0;
        if self.origin.provider == "claude" && progress.state.thread.is_none() {
            normalize::Record {
                db,
                origin: self.origin,
                source,
                revision,
                path: self.path,
                offset: progress.offset,
                bytes: &[],
            }
            .apply(&mut progress.state, Value::Null)?;
        }
        if self.mode != ReadMode::Inventory || self.origin.provider != "claude" {
            loop {
                ensure!(
                    !self.stop.load(Ordering::Acquire),
                    "Session ingestion cancelled"
                );
                line.clear();
                reader.hash.reset();
                let bound = if self.mode == ReadMode::Inventory {
                    8 << 20
                } else {
                    MAX_SESSION_RECORD_BYTES
                };
                let (read, kind) = read_bounded_line(&mut reader, &mut line, bound)?;
                if read == 0 || kind == LineKind::Partial {
                    break;
                }
                let bad = if kind == LineKind::Oversized {
                    true
                } else if line.iter().all(u8::is_ascii_whitespace) {
                    false
                } else if let Ok(value) = serde_json::from_slice::<Value>(&line) {
                    normalize::Record {
                        db,
                        origin: self.origin,
                        source,
                        revision,
                        path: self.path,
                        offset: progress.offset,
                        bytes: &line,
                    }
                    .apply(&mut progress.state, value)?;
                    false
                } else {
                    true
                };
                if bad {
                    progress.gap_records = progress
                        .gap_records
                        .checked_add(1)
                        .context("Too many record gaps")?;
                    progress.first_gap.get_or_insert((progress.offset, read));
                }
                progress.chain = chain_record(progress.chain, reader.hash.finalize());
                progress.offset += read;
                records += 1;
                if progress.offset < self.before.len() && inventory_waiting() {
                    if !can_checkpoint {
                        return Ok(RecordBoundary::Yield);
                    }
                    if progress.state.thread.is_some() {
                        return Ok(RecordBoundary::Checkpoint);
                    }
                }
                if self.mode == ReadMode::Inventory {
                    if progress.state.thread.is_some() {
                        break;
                    }
                    if records >= 128 || progress.offset >= 8 << 20 {
                        return Err(InvalidHeader(
                            "Transcript has no identity within the inventory header budget",
                        )
                        .into());
                    }
                }
            }
        }
        Ok(RecordBoundary::End)
    }

    fn save(
        &self,
        file: &mut File,
        target: &RecordTarget<'_>,
        progress: RecordProgress,
        previous: Option<&Previous>,
        checkpointed: bool,
    ) -> Result<()> {
        let RecordTarget {
            db,
            source,
            revision,
        } = *target;
        let RecordProgress {
            state,
            offset,
            chain,
            gap_records,
            first_gap,
        } = progress;
        let Self {
            before,
            path,
            mode,
            stop,
            stamp,
            prior,
            ..
        } = *self;
        let prefix = chain.to_hex().to_string();
        let (head, tail) = fingerprint(file, offset)?;
        let after = std::fs::metadata(path)?;
        ensure!(
            before.dev() == after.dev()
                && before.ino() == after.ino()
                && before.len() <= after.len(),
            "Source replaced during ingestion"
        );
        let stable = FileRevision::from(before.clone()) == FileRevision::from(after.clone());
        if !stable && mode == ReadMode::Full {
            ensure!(
                verify_prefix(path, offset, &prefix, stop)?,
                "Source changed during ingestion"
            );
        } else if !stable && let Some(previous) = previous {
            ensure!(
                fingerprint(file, previous.offset)?
                    == (previous.append.head.clone(), previous.append.tail.clone()),
                "Source changed during ingestion"
            );
        }
        if state.thread.is_none() && offset > 0 {
            return Err(InvalidHeader("Transcript has no exact provider identity").into());
        }
        let verified_revision = if mode == ReadMode::Full
            || (previous.is_none() && stable && mode != ReadMode::Inventory)
        {
            revision
        } else {
            prior.map_or(0, |previous| previous.append.verified_revision)
        };
        let append_state = AppendState {
            head,
            tail,
            verified_revision,
            gap_records,
            first_gap,
            checkpointed,
        };
        db.execute("UPDATE source SET local_path=?1,file_identity=?2,size=?3,mtime_ns=?4,ingested_offset=?5,revision=?6,present=1,prefix_hash=?7,parser_state=?8,failure=?9,append_state=?10 WHERE source_id=?11",params![path.to_string_lossy(),if mode != ReadMode::Inventory {stamp} else {""},i64::try_from(before.len())?,before.mtime()*1_000_000_000+before.mtime_nsec(),i64::try_from(offset)?,revision,prefix,serde_json::to_string(&state)?,if gap_records>0 {Some("record_gap")} else if offset<before.len(){Some("partial_record")}else{None},serde_json::to_string(&append_state)?,source])?;
        Ok(())
    }
}

fn refresh_dependencies(
    db: &Connection,
    origin: &Origin,
    source: i64,
    companions: &[PathBuf],
) -> Result<()> {
    let mut current = BTreeSet::new();
    for companion in companions {
        let original = origin.original(companion)?.to_string_lossy().into_owned();
        let identity = file_identity(companion)?;
        db.execute("INSERT INTO dependency(source_id,path,local_path,kind,identity,present,origin_host) VALUES(?1,?2,?3,'companion',?4,?5,?6) ON CONFLICT(source_id,path) DO UPDATE SET identity=excluded.identity,present=excluded.present WHERE dependency.identity IS NOT excluded.identity",params![source,original,companion.to_string_lossy(),identity,identity.is_some(),origin.host])?;
        current.insert(original);
    }
    let stored: Vec<(String, String, String)> = db
        .prepare("SELECT path,local_path,kind FROM dependency WHERE source_id=?1")?
        .query_map([source], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
        .collect::<rusqlite::Result<_>>()?;
    for (path, local, kind) in stored {
        if kind == "companion" && !current.contains(&path) {
            db.execute(
                "DELETE FROM dependency WHERE source_id=?1 AND path=?2",
                params![source, path],
            )?;
        } else if kind != "companion" {
            let identity = file_identity(Path::new(&local))?;
            db.execute("UPDATE dependency SET identity=?1,present=?2 WHERE source_id=?3 AND path=?4 AND identity IS NOT ?1",params![identity,identity.is_some(),source,path])?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sessions_record_hash_includes_discarded_oversized_bytes() {
        let oversized = format!("{}\n", "x".repeat(129));
        let complete = "accepted\n";
        let mut reader = RecordReader::new(std::io::Cursor::new(format!("{oversized}{complete}")));
        let mut line = Vec::new();
        let (count, kind) = read_bounded_line(&mut reader, &mut line, 64).unwrap();
        assert_eq!(kind, LineKind::Oversized);
        assert_eq!(count, oversized.len() as u64);
        assert!(line.is_empty());
        assert_eq!(reader.hash.finalize(), blake3::hash(oversized.as_bytes()));
        reader.hash.reset();
        let (_, kind) = read_bounded_line(&mut reader, &mut line, 64).unwrap();
        assert_eq!(kind, LineKind::Complete);
        assert_eq!(line, complete.as_bytes());
        assert_eq!(reader.hash.finalize(), blake3::hash(complete.as_bytes()));
    }
}
