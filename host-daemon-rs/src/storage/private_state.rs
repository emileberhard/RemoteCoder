//! Durable replacement for acknowledged host state, not high-frequency caches.
use std::fs::{File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result};
use serde::Serialize;

static NEXT_TEMPORARY: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Creation {
    Created,
    AlreadyExists,
}

#[derive(Debug)]
pub(crate) enum ReadError {
    Io(std::io::Error),
    NotRegular,
    TooLargeBeforeRead,
    TooLargeAfterRead,
}

pub(crate) fn read_bounded(
    path: &Path,
    max_bytes: u64,
) -> std::result::Result<Option<Vec<u8>>, ReadError> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(ReadError::Io(error)),
    };
    let metadata = file.metadata().map_err(ReadError::Io)?;
    if !metadata.is_file() {
        return Err(ReadError::NotRegular);
    }
    if metadata.len() > max_bytes {
        return Err(ReadError::TooLargeBeforeRead);
    }
    read_bounded_open(file, max_bytes).map(Some)
}

pub(crate) fn read_bounded_open(
    file: File,
    max_bytes: u64,
) -> std::result::Result<Vec<u8>, ReadError> {
    let mut bytes = Vec::new();
    file.take(max_bytes + 1)
        .read_to_end(&mut bytes)
        .map_err(ReadError::Io)?;
    if bytes.len() as u64 > max_bytes {
        return Err(ReadError::TooLargeAfterRead);
    }
    Ok(bytes)
}

pub(crate) fn transaction<D, T>(
    path: &Path,
    parent_error: &'static str,
    load: impl FnOnce(&Path) -> Result<D>,
    operation: impl FnOnce(&mut D) -> Result<(T, bool)>,
    save: impl FnOnce(&Path, &D) -> Result<()>,
) -> Result<T> {
    let parent = path.parent().context(parent_error)?;
    ensure_private_directory(parent)?;
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .custom_flags(libc::O_NOFOLLOW)
        .mode(0o600)
        .open(path.with_extension("lock"))?;
    lock.lock()?;
    let mut document = load(path)?;
    let (result, changed) = operation(&mut document)?;
    if changed {
        save(path, &document)?;
    }
    Ok(result)
}

pub(crate) fn write_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let parent = path.parent().context("state path has no parent")?;
    let temporary = write_temporary(path, |file| {
        serde_json::to_writer(&mut *file, value)?;
        file.write_all(b"\n")?;
        Ok(())
    })
    .with_context(|| format!("persisting {}", path.display()))?;
    commit(&temporary, path, parent).with_context(|| format!("persisting {}", path.display()))
}

pub(crate) fn replace(path: &Path, contents: &[u8]) -> Result<()> {
    let parent = path.parent().context("state path has no parent")?;
    let temporary = write_temporary(path, |file| Ok(file.write_all(contents)?))
        .with_context(|| format!("replacing {}", path.display()))?;
    commit(&temporary, path, parent).with_context(|| format!("replacing {}", path.display()))
}

fn commit(temporary: &Path, path: &Path, parent: &Path) -> Result<()> {
    let result = (|| -> Result<()> {
        std::fs::rename(temporary, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temporary);
    }
    result
}

pub(crate) fn create_new(path: &Path, contents: &[u8]) -> Result<Creation> {
    create_new_with(path, |file| Ok(file.write_all(contents)?))
}

pub(crate) fn create_new_with(
    path: &Path,
    write: impl FnOnce(&mut File) -> Result<()>,
) -> Result<Creation> {
    let parent = path.parent().context("state path has no parent")?;
    let temporary =
        write_temporary(path, write).with_context(|| format!("creating {}", path.display()))?;
    let linked = std::fs::hard_link(&temporary, path);
    let removed = std::fs::remove_file(&temporary);
    let creation = match linked {
        Ok(()) => Creation::Created,
        Err(error) if error.kind() == ErrorKind::AlreadyExists => Creation::AlreadyExists,
        Err(error) => {
            return Err(error).with_context(|| format!("creating {}", path.display()));
        }
    };
    removed.with_context(|| format!("removing {}", temporary.display()))?;
    if creation == Creation::Created {
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .with_context(|| format!("syncing {}", parent.display()))?;
    }
    Ok(creation)
}

fn write_temporary(path: &Path, write: impl FnOnce(&mut File) -> Result<()>) -> Result<PathBuf> {
    let parent = path.parent().context("state path has no parent")?;
    std::fs::create_dir_all(parent)?;
    let name = path
        .file_name()
        .context("state path has no filename")?
        .to_string_lossy();
    let temporary = parent.join(format!(
        ".{name}.{}.{}.new",
        std::process::id(),
        NEXT_TEMPORARY.fetch_add(1, Ordering::Relaxed)
    ));
    // Only unlink a temporary file after this call successfully created it.
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .custom_flags(libc::O_NOFOLLOW)
        .mode(0o600)
        .open(&temporary)?;
    let written = write(&mut file).and_then(|()| Ok(file.sync_all()?));
    if let Err(error) = written {
        let _ = std::fs::remove_file(&temporary);
        return Err(error);
    }
    Ok(temporary)
}

pub(crate) fn remove_dead_writer_temporaries(path: &Path) -> Result<usize> {
    use nix::errno::Errno;
    use nix::sys::signal::kill;
    use nix::unistd::Pid;

    let parent = path.parent().context("state path has no parent")?;
    let name = path
        .file_name()
        .context("state path has no filename")?
        .to_string_lossy();
    let legacy_prefix = format!("{name}.new.");
    let prefix = format!(".{name}.");
    let entries = match std::fs::read_dir(parent) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error).context("reading private-state temporary directory"),
    };
    let mut removed = 0;
    for entry in entries {
        let entry = entry?;
        let filename = entry.file_name();
        let Some(filename) = filename.to_str() else {
            continue;
        };
        let owner = if let Some(pid) = filename.strip_prefix(&legacy_prefix) {
            pid
        } else if let Some(suffix) = filename
            .strip_prefix(&prefix)
            .and_then(|suffix| suffix.strip_suffix(".new"))
        {
            let Some((pid, sequence)) = suffix.split_once('.') else {
                continue;
            };
            if !sequence
                .parse::<u64>()
                .is_ok_and(|number| number > 0 && number.to_string() == sequence)
            {
                continue;
            }
            pid
        } else {
            continue;
        };
        let Some(pid) = owner
            .parse::<i32>()
            .ok()
            .filter(|pid| *pid > 0 && pid.to_string() == owner)
        else {
            continue;
        };
        let kind = match entry.file_type() {
            Ok(kind) => kind,
            Err(error) if error.kind() == ErrorKind::NotFound => continue,
            Err(error) => return Err(error).context("reading private-state temporary type"),
        };
        if !kind.is_file() || kill(Pid::from_raw(pid), None) != Err(Errno::ESRCH) {
            continue;
        }
        match std::fs::remove_file(entry.path()) {
            Ok(()) => removed += 1,
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(error).context("removing abandoned private-state temporary"),
        }
    }
    if removed > 0 {
        File::open(parent)?.sync_all()?;
    }
    Ok(removed)
}

pub(crate) fn ensure_private_directory(path: &Path) -> Result<()> {
    std::fs::create_dir_all(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct CannotSerialize;
    impl Serialize for CannotSerialize {
        fn serialize<S: serde::Serializer>(&self, _: S) -> Result<S::Ok, S::Error> {
            Err(serde::ser::Error::custom("injected serialization failure"))
        }
    }

    #[test]
    fn serialization_failure_preserves_original_and_removes_its_temporary() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("state.json");
        std::fs::write(&path, b"original").unwrap();
        assert!(write_json(&path, &CannotSerialize).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"original");
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
    }

    #[test]
    fn failed_rename_preserves_the_existing_path_and_removes_its_temporary() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("state.json");
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("original"), b"original").unwrap();
        assert!(write_json(&path, &serde_json::json!({"accepted": true})).is_err());
        assert_eq!(std::fs::read(path.join("original")).unwrap(), b"original");
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
        std::fs::remove_dir_all(&path).unwrap();
        write_json(&path, &serde_json::json!({"accepted": true})).unwrap();
        assert_eq!(
            std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn create_new_never_replaces_an_existing_file_and_leaves_no_temporary() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("identity");

        assert_eq!(create_new(&path, b"first").unwrap(), Creation::Created);
        assert_eq!(
            create_new(&path, b"second").unwrap(),
            Creation::AlreadyExists
        );

        assert_eq!(std::fs::read(&path).unwrap(), b"first");
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
    }

    #[test]
    fn bounded_read_rejects_oversized_files_and_symlinks() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("state.json");
        std::fs::write(&path, b"12345").unwrap();
        assert!(matches!(
            read_bounded(&path, 4),
            Err(ReadError::TooLargeBeforeRead)
        ));
        assert_eq!(read_bounded(&path, 5).unwrap(), Some(b"12345".to_vec()));
        let link = directory.path().join("link.json");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(matches!(read_bounded(&link, 5), Err(ReadError::Io(_))));
    }
}
