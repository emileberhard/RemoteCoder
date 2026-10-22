use anyhow::{Context, Result, bail, ensure};
use serde::Serialize;
use std::ffi::{CStr, CString, OsStr, OsString};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_TEMPORARY: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum EntryKind {
    File,
    Directory,
    Symlink,
    Other,
}

pub(crate) struct Root {
    path: PathBuf,
    directory: File,
}

impl Root {
    pub(crate) fn open(path: &Path) -> Result<Self> {
        Self::open_root(path, true)
            .with_context(|| format!("opening filesystem root {}", path.display()))
    }

    pub(crate) fn open_existing(path: &Path) -> Result<Self> {
        Self::open_root(path, false)
            .with_context(|| format!("opening existing filesystem root {}", path.display()))
    }

    fn open_root(path: &Path, create: bool) -> Result<Self> {
        ensure!(
            path.is_absolute(),
            "filesystem root must be absolute: {}",
            path.display()
        );
        ensure!(
            path.components()
                .all(|part| matches!(part, Component::RootDir | Component::Normal(_))),
            "invalid filesystem root: {}",
            path.display()
        );
        let mut suffix = Vec::new();
        let mut ancestor = path;
        if let Some(parent) = path.parent() {
            suffix.push(
                path.file_name()
                    .context("filesystem root has no name")?
                    .to_owned(),
            );
            ancestor = parent;
        }
        let canonical = if !create {
            ancestor.to_owned()
        } else {
            loop {
                match ancestor.canonicalize() {
                    Ok(canonical) => break canonical,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                        suffix.push(
                            ancestor
                                .file_name()
                                .context("filesystem root has no existing ancestor")?
                                .to_owned(),
                        );
                        ancestor = ancestor
                            .parent()
                            .context("filesystem root has no existing ancestor")?;
                    }
                    Err(error) => {
                        return Err(error).with_context(|| {
                            format!("resolving filesystem root {}", path.display())
                        });
                    }
                }
            }
        };
        let mut directory = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open("/")?;
        for part in canonical.components() {
            if let Component::Normal(name) = part {
                directory = open_directory(&directory, name, false)?
                    .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::NotFound))?;
            }
        }
        for name in suffix.iter().rev() {
            directory = open_directory(&directory, name, create)?
                .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::NotFound))?;
        }
        Ok(Self {
            path: path.to_owned(),
            directory,
        })
    }

    pub(crate) fn entry_kind(&self, path: &Path) -> Result<Option<EntryKind>> {
        let result = (|| -> Result<Option<EntryKind>> {
            if path == self.path.as_path() {
                return Ok(Some(EntryKind::Directory));
            }
            let Some((parent, name)) = self.parent(path, false)? else {
                return Ok(None);
            };
            Ok(entry_metadata(&parent, &name)?.map(|metadata| kind(&metadata)))
        })();
        result.with_context(|| format!("examining {} without following symlinks", path.display()))
    }

    pub(crate) fn read_directory(&self, path: &Path) -> Result<Vec<OsString>> {
        self.read_directory_bounded(path, usize::MAX)
    }

    pub(crate) fn read_directory_bounded(
        &self,
        path: &Path,
        maximum: usize,
    ) -> Result<Vec<OsString>> {
        let result = (|| -> Result<Vec<OsString>> {
            let mut directory = self.directory.try_clone()?;
            for name in self.parts(path)? {
                let Some(child) = open_directory(&directory, &name, false)? else {
                    return Ok(Vec::new());
                };
                directory = child;
            }
            directory_names(directory, maximum)
        })();
        result.with_context(|| format!("listing {} without following symlinks", path.display()))
    }

    pub(crate) fn read_link(&self, path: &Path) -> Result<PathBuf> {
        let result = (|| -> Result<PathBuf> {
            let (parent, name) = self
                .parent(path, false)?
                .context("symlink parent is absent")?;
            let name = cstring(&name)?;
            let mut bytes = vec![0u8; 256];
            loop {
                let count = unsafe {
                    libc::readlinkat(
                        parent.as_raw_fd(),
                        name.as_ptr(),
                        bytes.as_mut_ptr().cast(),
                        bytes.len(),
                    )
                };
                ensure!(
                    count >= 0,
                    "reading symlink failed: {}",
                    std::io::Error::last_os_error()
                );
                let count = usize::try_from(count)?;
                if count < bytes.len() {
                    bytes.truncate(count);
                    return Ok(PathBuf::from(OsString::from_vec(bytes)));
                }
                ensure!(bytes.len() < 1_048_576, "symlink target is too long");
                bytes.resize(bytes.len() * 2, 0);
            }
        })();
        result.with_context(|| format!("reading symlink {}", path.display()))
    }

    pub(crate) fn create_link(&self, path: &Path, target: &Path) -> Result<()> {
        let result = (|| -> Result<()> {
            let (parent, name) = self
                .parent(path, true)?
                .context("symlink destination parent is absent")?;
            ensure!(
                entry_metadata(&parent, &name)?.is_none(),
                "symlink destination already exists"
            );
            let name = cstring(&name)?;
            let target = cstring(target.as_os_str())?;
            let status =
                unsafe { libc::symlinkat(target.as_ptr(), parent.as_raw_fd(), name.as_ptr()) };
            if status != 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            parent.sync_all()?;
            Ok(())
        })();
        result.with_context(|| format!("creating symlink {}", path.display()))
    }

    pub(crate) fn remove_file(&self, path: &Path) -> Result<()> {
        let Some((parent, name)) = self.parent(path, false)? else {
            return Ok(());
        };
        reject_non_regular(&parent, &name)?;
        let name = cstring(&name)?;
        let status = unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), 0) };
        if status != 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::NotFound {
                return Err(error).context("removing regular file without following symlinks");
            }
        }
        parent.sync_all()?;
        Ok(())
    }

    pub(crate) fn remove_tree(&self, path: &Path) -> Result<()> {
        let result = (|| -> Result<()> {
            let Some((parent, name)) = self.parent(path, false)? else {
                return Ok(());
            };
            remove_entry(&parent, &name)
        })();
        result.with_context(|| {
            format!(
                "removing entry tree {} without following symlinks",
                path.display()
            )
        })
    }

    pub(crate) fn rename_directory(&self, source: &Path, target: &Path) -> Result<()> {
        let result = (|| -> Result<()> {
            let (source_parent, source_name) = self
                .parent(source, false)?
                .context("rename source parent is absent")?;
            ensure!(
                entry_metadata(&source_parent, &source_name)?
                    .is_some_and(|metadata| kind(&metadata) == EntryKind::Directory),
                "rename source is not a directory"
            );
            let (target_parent, target_name) = self
                .parent(target, true)?
                .context("rename destination parent is absent")?;
            ensure!(
                entry_metadata(&target_parent, &target_name)?.is_none(),
                "rename destination already exists"
            );
            let source_name = cstring(&source_name)?;
            let target_name = cstring(&target_name)?;
            let status = unsafe {
                libc::renameat(
                    source_parent.as_raw_fd(),
                    source_name.as_ptr(),
                    target_parent.as_raw_fd(),
                    target_name.as_ptr(),
                )
            };
            if status != 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            source_parent.sync_all()?;
            target_parent.sync_all()?;
            Ok(())
        })();
        result.with_context(|| {
            format!(
                "renaming directory {} to {} without following symlinks",
                source.display(),
                target.display()
            )
        })
    }

    pub(crate) fn read(&self, path: &Path) -> Result<Option<Vec<u8>>> {
        self.read_file(path)
            .with_context(|| format!("reading {} without following symlinks", path.display()))
    }

    fn read_file(&self, path: &Path) -> Result<Option<Vec<u8>>> {
        let Some(mut file) = self.open_file(path)? else {
            return Ok(None);
        };
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)?;
        Ok(Some(bytes))
    }

    pub(crate) fn open_file(&self, path: &Path) -> Result<Option<File>> {
        let result = (|| -> Result<Option<File>> {
            let Some((parent, name)) = self.parent(path, false)? else {
                return Ok(None);
            };
            open_regular(&parent, &name, libc::O_RDONLY)
        })();
        result.with_context(|| format!("opening {} without following symlinks", path.display()))
    }

    pub(crate) fn lock_file(&self, path: &Path) -> Result<File> {
        let result = (|| -> Result<File> {
            let (parent, name) = self.parent(path, true)?.context("lock parent is absent")?;
            reject_non_regular(&parent, &name)?;
            let name = cstring(&name)?;
            let descriptor = unsafe {
                libc::openat(
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDWR
                        | libc::O_CREAT
                        | libc::O_NOFOLLOW
                        | libc::O_CLOEXEC
                        | libc::O_NONBLOCK,
                    0o600,
                )
            };
            if descriptor < 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            let file = unsafe { File::from_raw_fd(descriptor) };
            ensure!(file.metadata()?.is_file(), "lock is not a regular file");
            file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
            file.lock()?;
            Ok(file)
        })();
        result.with_context(|| format!("locking {} without following symlinks", path.display()))
    }

    pub(crate) fn validate_path(&self, path: &Path) -> Result<()> {
        let result = (|| -> Result<()> {
            if path == self.path.as_path() {
                return Ok(());
            }
            let Some((parent, name)) = self.parent(path, false)? else {
                return Ok(());
            };
            if let Some(metadata) = entry_metadata(&parent, &name)? {
                ensure!(
                    metadata.st_mode & libc::S_IFMT != libc::S_IFLNK,
                    "entry is a symlink"
                );
            }
            Ok(())
        })();
        result.with_context(|| format!("validating {} without following symlinks", path.display()))
    }

    pub(crate) fn write_json(&self, path: &Path, value: &impl Serialize) -> Result<()> {
        self.write(path, |file| {
            serde_json::to_writer(&mut *file, value)?;
            file.write_all(b"\n")?;
            Ok(())
        })
    }

    pub(crate) fn replace(&self, path: &Path, contents: &[u8]) -> Result<()> {
        self.write(path, |file| Ok(file.write_all(contents)?))
    }

    pub(crate) fn write_read_only(&self, path: &Path, contents: &[u8]) -> Result<()> {
        self.write(path, |file| {
            file.write_all(contents)?;
            file.set_permissions(std::fs::Permissions::from_mode(0o400))?;
            Ok(())
        })
    }

    fn write(&self, path: &Path, write: impl FnOnce(&mut File) -> Result<()>) -> Result<()> {
        let result = (|| -> Result<()> {
            let (parent, name) = self
                .parent(path, true)?
                .context("destination parent is absent")?;
            reject_non_regular(&parent, &name)?;
            let temporary = Temporary::create(&parent)?;
            let mut file = temporary.file()?;
            write(&mut file)?;
            file.sync_all()?;
            temporary.commit(&name)
        })();
        result.with_context(|| format!("writing {} without following symlinks", path.display()))
    }

    pub(crate) fn clone_from(
        &self,
        source_root: &Root,
        source: &Path,
        target: &Path,
    ) -> Result<()> {
        let result = (|| -> Result<()> {
            let (source_parent, source_name) = source_root
                .parent(source, false)?
                .context("clone source parent is absent")?;
            let mut source_file = open_regular(&source_parent, &source_name, libc::O_RDONLY)?
                .context("clone source is absent")?;
            let (parent, name) = self
                .parent(target, true)?
                .context("clone destination parent is absent")?;
            reject_non_regular(&parent, &name)?;
            let temporary = Temporary::clone(&parent, &mut source_file)?;
            temporary.commit(&name)
        })();
        result.with_context(|| {
            format!(
                "cloning {} to {} without following symlinks",
                source.display(),
                target.display()
            )
        })
    }

    pub(crate) fn ensure_directory(&self, path: &Path) -> Result<()> {
        let result = (|| -> Result<()> {
            let mut directory = self.directory.try_clone()?;
            for name in self.parts(path)? {
                directory = open_directory(&directory, &name, true)?
                    .context("directory could not be created")?;
            }
            Ok(())
        })();
        result.with_context(|| {
            format!(
                "creating directory {} without following symlinks",
                path.display()
            )
        })
    }

    fn parts(&self, path: &Path) -> Result<Vec<OsString>> {
        ensure!(
            path.is_absolute(),
            "path must be absolute: {}",
            path.display()
        );
        let relative = path.strip_prefix(&self.path).with_context(|| {
            format!(
                "{} is outside filesystem root {}",
                path.display(),
                self.path.display()
            )
        })?;
        relative
            .components()
            .map(|part| match part {
                Component::Normal(name) => Ok(name.to_owned()),
                _ => bail!("invalid path beneath filesystem root: {}", path.display()),
            })
            .collect()
    }

    fn parent(&self, path: &Path, create: bool) -> Result<Option<(File, OsString)>> {
        let mut parts = self.parts(path)?;
        let name = parts
            .pop()
            .context("operation requires a file beneath filesystem root")?;
        let mut parent = self.directory.try_clone()?;
        for component in parts {
            match open_directory(&parent, &component, create)? {
                Some(directory) => parent = directory,
                None => return Ok(None),
            }
        }
        Ok(Some((parent, name)))
    }
}

fn kind(metadata: &libc::stat) -> EntryKind {
    match metadata.st_mode & libc::S_IFMT {
        libc::S_IFREG => EntryKind::File,
        libc::S_IFDIR => EntryKind::Directory,
        libc::S_IFLNK => EntryKind::Symlink,
        _ => EntryKind::Other,
    }
}

struct DirectoryStream(*mut libc::DIR);

impl Drop for DirectoryStream {
    fn drop(&mut self) {
        unsafe {
            libc::closedir(self.0);
        }
    }
}

fn directory_names(directory: File, maximum: usize) -> Result<Vec<OsString>> {
    let directory = open_directory(&directory, OsStr::new("."), false)?
        .context("opened directory disappeared")?;
    let descriptor = directory.into_raw_fd();
    let stream = unsafe { libc::fdopendir(descriptor) };
    if stream.is_null() {
        let error = std::io::Error::last_os_error();
        drop(unsafe { File::from_raw_fd(descriptor) });
        return Err(error.into());
    }
    let stream = DirectoryStream(stream);
    let mut names = Vec::new();
    loop {
        nix::errno::Errno::clear();
        let entry = unsafe { libc::readdir(stream.0) };
        if entry.is_null() {
            let error = nix::errno::Errno::last_raw();
            ensure!(
                error == 0,
                "reading directory entries failed: {}",
                std::io::Error::from_raw_os_error(error)
            );
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
        if name.to_bytes() != b"." && name.to_bytes() != b".." {
            ensure!(names.len() < maximum, "directory entry capacity exceeded");
            names.push(OsString::from_vec(name.to_bytes().to_vec()));
        }
    }
    names.sort();
    Ok(names)
}

fn remove_entry(parent: &File, name: &OsStr) -> Result<()> {
    let Some(metadata) = entry_metadata(parent, name)? else {
        return Ok(());
    };
    let flags = if kind(&metadata) == EntryKind::Directory {
        let directory =
            open_directory(parent, name, false)?.context("directory disappeared during removal")?;
        for child in directory_names(directory.try_clone()?, usize::MAX)? {
            remove_entry(&directory, &child)?;
        }
        libc::AT_REMOVEDIR
    } else {
        0
    };
    let name = cstring(name)?;
    let status = unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), flags) };
    if status != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    parent.sync_all()?;
    Ok(())
}

fn cstring(name: &OsStr) -> Result<CString> {
    CString::new(name.as_bytes()).context("filename contains a NUL byte")
}

fn open_directory(parent: &File, name: &OsStr, create: bool) -> Result<Option<File>> {
    let name = cstring(name)?;
    let open = || unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    let mut descriptor = open();
    if descriptor < 0
        && create
        && std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound
    {
        let status = unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) };
        if status != 0
            && std::io::Error::last_os_error().kind() != std::io::ErrorKind::AlreadyExists
        {
            return Err(std::io::Error::last_os_error().into());
        }
        parent.sync_all()?;
        descriptor = open();
    }
    if descriptor < 0 {
        let error = std::io::Error::last_os_error();
        if !create && error.kind() == std::io::ErrorKind::NotFound {
            return Ok(None);
        }
        return Err(error).with_context(|| {
            format!(
                "opening directory {} without following symlinks",
                name.to_string_lossy()
            )
        });
    }
    Ok(Some(unsafe { File::from_raw_fd(descriptor) }))
}

fn open_regular(parent: &File, name: &OsStr, flags: libc::c_int) -> Result<Option<File>> {
    let name = cstring(name)?;
    let descriptor = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
        )
    };
    if descriptor < 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::NotFound {
            return Ok(None);
        }
        return Err(error.into());
    }
    let file = unsafe { File::from_raw_fd(descriptor) };
    ensure!(
        file.metadata()?.is_file(),
        "entry is not a regular file: {}",
        name.to_string_lossy()
    );
    Ok(Some(file))
}

fn entry_metadata(parent: &File, name: &OsStr) -> Result<Option<libc::stat>> {
    let name = cstring(name)?;
    let mut metadata = std::mem::MaybeUninit::<libc::stat>::uninit();
    let status = unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            metadata.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if status != 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::NotFound {
            return Ok(None);
        }
        return Err(error.into());
    }
    Ok(Some(unsafe { metadata.assume_init() }))
}

fn reject_non_regular(parent: &File, name: &OsStr) -> Result<()> {
    if let Some(metadata) = entry_metadata(parent, name)? {
        ensure!(
            metadata.st_mode & libc::S_IFMT == libc::S_IFREG,
            "entry is not a regular file: {}",
            name.to_string_lossy()
        );
    }
    Ok(())
}

struct Temporary<'a> {
    parent: &'a File,
    name: CString,
    file: File,
    committed: bool,
}

impl<'a> Temporary<'a> {
    fn name() -> Result<CString> {
        Ok(CString::new(format!(
            ".migration.{}.{}.new",
            std::process::id(),
            NEXT_TEMPORARY.fetch_add(1, Ordering::Relaxed)
        ))?)
    }

    fn create(parent: &'a File) -> Result<Self> {
        let name = Self::name()?;
        let descriptor = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if descriptor < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(Self {
            parent,
            name,
            file: unsafe { File::from_raw_fd(descriptor) },
            committed: false,
        })
    }

    fn clone(parent: &'a File, source: &mut File) -> Result<Self> {
        #[cfg(target_os = "macos")]
        {
            let name = Self::name()?;
            let status = unsafe {
                libc::fclonefileat(source.as_raw_fd(), parent.as_raw_fd(), name.as_ptr(), 0)
            };
            if status == 0 {
                let opened =
                    open_regular(parent, OsStr::from_bytes(name.as_bytes()), libc::O_WRONLY)
                        .and_then(|file| file.context("cloned temporary file disappeared"));
                let file = match opened {
                    Ok(file) => file,
                    Err(error) => {
                        unsafe {
                            libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), 0);
                        }
                        return Err(error);
                    }
                };
                let temporary = Self {
                    parent,
                    name,
                    file,
                    committed: false,
                };
                temporary
                    .file
                    .set_permissions(std::fs::Permissions::from_mode(0o600))?;
                temporary.file.sync_all()?;
                return Ok(temporary);
            }
            let error = std::io::Error::last_os_error();
            if !matches!(
                error.raw_os_error(),
                Some(libc::EXDEV | libc::ENOTSUP | libc::EINVAL | libc::ENOSYS)
            ) {
                return Err(error.into());
            }
        }
        let temporary = Self::create(parent)?;
        let mut file = temporary.file()?;
        std::io::copy(source, &mut file)?;
        file.sync_all()?;
        Ok(temporary)
    }

    fn file(&self) -> Result<File> {
        Ok(self.file.try_clone()?)
    }

    fn commit(mut self, target: &OsStr) -> Result<()> {
        reject_non_regular(self.parent, target)?;
        let target = cstring(target)?;
        let status = unsafe {
            libc::renameat(
                self.parent.as_raw_fd(),
                self.name.as_ptr(),
                self.parent.as_raw_fd(),
                target.as_ptr(),
            )
        };
        if status != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        self.committed = true;
        self.parent.sync_all()?;
        Ok(())
    }
}

impl Drop for Temporary<'_> {
    fn drop(&mut self) {
        if !self.committed {
            unsafe {
                libc::unlinkat(self.parent.as_raw_fd(), self.name.as_ptr(), 0);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn opening_existing_roots_never_creates_missing_directories() {
        let home = tempfile::tempdir().unwrap();
        let path = home.path().canonicalize().unwrap();
        for path in [path.join("missing"), path.join("absent/nested")] {
            assert!(Root::open_existing(&path).is_err());
            assert!(!path.exists());
        }
        assert!(!path.join("absent").exists());
        assert!(Root::open_existing(&path).is_ok());
        let outside = tempfile::tempdir().unwrap();
        std::fs::create_dir(outside.path().join("report")).unwrap();
        symlink(outside.path(), path.join("replaced-ancestor")).unwrap();
        assert!(Root::open_existing(&path.join("replaced-ancestor/report")).is_err());
    }

    #[test]
    fn no_follow_rejects_file_and_directory_aliases_without_changing_outside_files() {
        let home = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let outside_file = outside.path().join("history.json");
        std::fs::write(&outside_file, b"outside original").unwrap();
        let root = Root::open(home.path()).unwrap();
        let file_link = home.path().join("history.json");
        let directory_link = home.path().join("projects");
        symlink(&outside_file, &file_link).unwrap();
        symlink(outside.path(), &directory_link).unwrap();
        for path in [&file_link, &directory_link.join("history.json")] {
            assert!(root.read(path).is_err());
            assert!(root.replace(path, b"replacement").is_err());
            assert!(
                root.write_json(path, &serde_json::json!({"changed": true}))
                    .is_err()
            );
            assert!(root.validate_path(path).is_err());
            assert!(root.lock_file(path).is_err());
        }
        assert!(root.ensure_directory(&directory_link).is_err());
        let source = home.path().join("source");
        root.replace(&source, b"source").unwrap();
        assert!(root.clone_from(&root, &source, &file_link).is_err());
        assert!(
            root.clone_from(&root, &file_link, &home.path().join("copied"))
                .is_err()
        );
        assert_eq!(std::fs::read(outside_file).unwrap(), b"outside original");
        assert!(
            std::fs::symlink_metadata(&file_link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert!(
            std::fs::symlink_metadata(&directory_link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert!(!home.path().join("copied").exists());
        assert!(Root::open(&directory_link).is_err());
    }

    #[test]
    fn no_follow_restore_refuses_a_parent_replaced_with_a_symlink() {
        let home = tempfile::tempdir().unwrap();
        let snapshot = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let root = Root::open(home.path()).unwrap();
        let saved = Root::open(snapshot.path()).unwrap();
        let parent = home.path().join("projects");
        root.ensure_directory(&parent).unwrap();
        let history = parent.join("session.jsonl");
        root.replace(&history, b"original").unwrap();
        let backup = snapshot.path().join("session.jsonl");
        saved.clone_from(&root, &history, &backup).unwrap();
        std::fs::rename(&parent, home.path().join("original-projects")).unwrap();
        symlink(outside.path(), &parent).unwrap();
        let outside_history = outside.path().join("session.jsonl");
        std::fs::write(&outside_history, b"outside").unwrap();
        assert!(root.clone_from(&saved, &backup, &history).is_err());
        assert_eq!(std::fs::read(outside_history).unwrap(), b"outside");
        assert_eq!(
            std::fs::read(home.path().join("original-projects/session.jsonl")).unwrap(),
            b"original"
        );
    }

    #[test]
    fn no_follow_commit_uses_the_opened_parent_after_a_concurrent_alias_swap() {
        let home = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let root = Root::open(home.path()).unwrap();
        let parent = home.path().join("projects");
        root.ensure_directory(&parent).unwrap();
        let destination = parent.join("session.jsonl");
        let outside_file = outside.path().join("session.jsonl");
        std::fs::write(&outside_file, b"outside").unwrap();
        let moved = home.path().join("original-projects");
        root.write(&destination, |file| {
            std::fs::rename(&parent, &moved)?;
            symlink(outside.path(), &parent)?;
            file.write_all(b"owned directory")?;
            Ok(())
        })
        .unwrap();
        assert_eq!(std::fs::read(outside_file).unwrap(), b"outside");
        assert_eq!(
            std::fs::read(moved.join("session.jsonl")).unwrap(),
            b"owned directory"
        );
        assert!(root.read(&destination).is_err());
    }

    #[test]
    fn no_follow_commit_refuses_a_terminal_link_created_during_write() {
        let home = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let root = Root::open(home.path()).unwrap();
        let destination = home.path().join("history.json");
        let outside_file = outside.path().join("history.json");
        std::fs::write(&outside_file, b"outside").unwrap();
        let result = root.write(&destination, |file| {
            symlink(&outside_file, &destination)?;
            file.write_all(b"replacement")?;
            Ok(())
        });
        assert!(result.is_err());
        assert_eq!(std::fs::read(outside_file).unwrap(), b"outside");
        assert!(
            std::fs::symlink_metadata(&destination)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 1);
    }

    #[test]
    fn no_follow_clone_is_private_and_independent_and_paths_cannot_escape() {
        let home = tempfile::tempdir().unwrap();
        let boundary = home.path().join("new/profile");
        let root = Root::open(&boundary).unwrap();
        let source = boundary.join("original");
        let target = boundary.join("nested/copy");
        root.replace(&source, b"original").unwrap();
        root.clone_from(&root, &source, &target).unwrap();
        root.replace(&source, b"changed").unwrap();
        assert_eq!(root.read(&target).unwrap().unwrap(), b"original");
        assert_eq!(
            std::fs::metadata(&target).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(target.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert!(
            root.replace(&boundary.join("../escaped"), b"escape")
                .is_err()
        );
        assert!(root.read(&home.path().join("outside")).is_err());
        assert!(root.read(&boundary.join("missing/file")).unwrap().is_none());
        root.validate_path(&boundary.join("missing/file")).unwrap();
        assert!(!boundary.join("missing").exists());
        let lock = root.lock_file(&boundary.join("migration.lock")).unwrap();
        assert_eq!(lock.metadata().unwrap().permissions().mode() & 0o777, 0o600);
    }

    #[test]
    fn no_follow_directory_listing_repeats_and_tree_removal_never_follows_links() {
        let home = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let root = Root::open(home.path()).unwrap();
        let tree = home.path().join("snapshot");
        root.replace(&tree.join("nested/file"), b"owned").unwrap();
        let outside_file = outside.path().join("keep");
        std::fs::write(&outside_file, b"outside").unwrap();
        root.create_link(&tree.join("alias"), outside.path())
            .unwrap();
        root.create_link(&tree.join("dangling"), &outside.path().join("missing"))
            .unwrap();
        let first = root.read_directory(home.path()).unwrap();
        assert_eq!(first, root.read_directory(home.path()).unwrap());
        assert_eq!(first, vec![OsString::from("snapshot")]);
        assert_eq!(
            root.entry_kind(&tree.join("alias")).unwrap(),
            Some(EntryKind::Symlink)
        );
        assert!(root.read_directory(&tree.join("alias")).is_err());
        assert!(root.read_directory_bounded(&tree, 1).is_err());
        root.remove_tree(&tree).unwrap();
        assert_eq!(root.entry_kind(&tree).unwrap(), None);
        assert_eq!(std::fs::read(outside_file).unwrap(), b"outside");
    }
}
