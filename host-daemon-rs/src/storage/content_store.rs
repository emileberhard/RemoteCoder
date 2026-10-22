use std::path::{Path, PathBuf};
use std::time::SystemTime;

use anyhow::{Context, Result, ensure};

use super::no_follow::{EntryKind, Root};

pub(super) struct Limits {
    pub(super) bytes: u64,
    pub(super) entries: usize,
}

pub(super) struct StoreEntry {
    path: PathBuf,
    modified: SystemTime,
    bytes: u64,
}

pub(super) fn is_digest(name: &str) -> bool {
    name.len() == 64
        && name
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub(super) fn inventory(
    root: &Root,
    directory: &Path,
    limits: &Limits,
    extensions: &[&str],
) -> Result<Vec<StoreEntry>> {
    let mut entries = Vec::new();
    for name in root.read_directory_bounded(directory, limits.entries + 1)? {
        let Some(name) = name.to_str() else { continue };
        let path = directory.join(name);
        if abandoned_temporary(name) {
            if root.entry_kind(&path)? == Some(EntryKind::File) {
                root.remove_file(&path)?;
            }
            continue;
        }
        let Some((digest, extension)) = name.rsplit_once('.') else {
            continue;
        };
        if !extensions.contains(&extension) || !is_digest(digest) {
            continue;
        }
        let file = root
            .open_file(&path)?
            .context("stored content disappeared")?;
        let metadata = file.metadata()?;
        entries.push(StoreEntry {
            path,
            modified: metadata.modified()?,
            bytes: metadata.len(),
        });
    }
    Ok(entries)
}

fn abandoned_temporary(name: &str) -> bool {
    let Some(suffix) = name
        .strip_prefix(".migration.")
        .and_then(|suffix| suffix.strip_suffix(".new"))
    else {
        return false;
    };
    let Some((pid, sequence)) = suffix.split_once('.') else {
        return false;
    };
    pid.parse::<u32>()
        .is_ok_and(|value| value > 0 && value.to_string() == pid)
        && sequence
            .parse::<u64>()
            .is_ok_and(|value| value > 0 && value.to_string() == sequence)
}

pub(super) fn retain(
    root: &Root,
    mut entries: Vec<StoreEntry>,
    protected: &[PathBuf],
    incoming_bytes: u64,
    incoming_entries: usize,
    limits: &Limits,
) -> Result<()> {
    let mut total = incoming_bytes;
    for entry in &entries {
        total = total
            .checked_add(entry.bytes)
            .context("content storage size overflow")?;
    }
    entries.sort_by(|a, b| {
        a.modified
            .cmp(&b.modified)
            .then_with(|| a.path.cmp(&b.path))
    });
    let mut count = entries.len() + incoming_entries;
    for entry in entries {
        if total <= limits.bytes && count <= limits.entries {
            break;
        }
        if protected.contains(&entry.path) {
            continue;
        }
        root.remove_file(&entry.path)?;
        total -= entry.bytes;
        count -= 1;
    }
    ensure!(
        total <= limits.bytes && count <= limits.entries,
        "content store capacity exhausted"
    );
    Ok(())
}
