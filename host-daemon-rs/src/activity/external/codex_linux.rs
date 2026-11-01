use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{self, Read};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};

use crate::platform::process::{self, ProcessInstance};

const MAX_PROCESSES: usize = 32_768;
const MAX_FDS: usize = 65_536;
const MAX_PROCESS_FDS: usize = 4_096;
const MAX_BYTES: usize = 16 * 1024 * 1024;

pub(super) struct Writer {
    pub identity: ProcessInstance,
    pub paths: Vec<PathBuf>,
}

struct Candidate {
    identity: ProcessInstance,
    parent: i32,
    paths: Vec<PathBuf>,
}

struct Budget {
    bytes: usize,
    fds: usize,
}

fn vanished(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(libc::ENOENT | libc::ESRCH))
}

impl Budget {
    fn read(&mut self, path: &Path, limit: u64) -> Result<Option<Vec<u8>>> {
        let file = match File::open(path) {
            Ok(file) => file,
            Err(error) if vanished(&error) => return Ok(None),
            Err(error) => return Err(error).with_context(|| format!("read {}", path.display())),
        };
        let mut bytes = Vec::new();
        match file.take(limit + 1).read_to_end(&mut bytes) {
            Ok(_) => {}
            Err(error) if vanished(&error) => return Ok(None),
            Err(error) => return Err(error.into()),
        }
        ensure!(
            bytes.len() <= limit as usize,
            "{} exceeds read limit",
            path.display()
        );
        self.add_bytes(bytes.len())?;
        Ok(Some(bytes))
    }

    fn link(&mut self, path: &Path) -> Result<Option<PathBuf>> {
        match fs::read_link(path) {
            Ok(target) => {
                self.add_bytes(target.as_os_str().len())?;
                Ok(Some(target))
            }
            Err(error) if vanished(&error) => Ok(None),
            Err(error) => Err(error).with_context(|| format!("read link {}", path.display())),
        }
    }

    fn add_bytes(&mut self, count: usize) -> Result<()> {
        self.bytes = self
            .bytes
            .checked_add(count)
            .context("proc inventory byte overflow")?;
        ensure!(self.bytes <= MAX_BYTES, "proc inventory exceeds byte limit");
        Ok(())
    }
}

fn candidate(pid: i32, stat: &[u8]) -> Result<Option<Candidate>> {
    let close = stat
        .windows(2)
        .rposition(|pair| pair == b") ")
        .context("invalid process stat")?;
    let open = stat
        .iter()
        .position(|byte| *byte == b'(')
        .context("invalid process command")?;
    ensure!(
        std::str::from_utf8(&stat[..open])?.trim().parse::<i32>()? == pid,
        "process stat PID changed"
    );
    if &stat[open + 1..close] != b"codex" {
        return Ok(None);
    }
    let fields = std::str::from_utf8(&stat[close + 2..])?
        .split_whitespace()
        .collect::<Vec<_>>();
    ensure!(fields.len() >= 20, "process stat is incomplete");
    if matches!(fields[0], "Z" | "X" | "x") {
        return Ok(None);
    }
    Ok(Some(Candidate {
        identity: ProcessInstance {
            pid,
            started_micros: None,
            linux_birth: process::linux::birth_from_ticks(fields[19].parse()?)?,
        },
        parent: fields[1].parse()?,
        paths: Vec::new(),
    }))
}

fn descriptor_info(info: &[u8]) -> Result<(u64, u64)> {
    let text = std::str::from_utf8(info)?;
    let value = |name| {
        text.lines()
            .find_map(|line| line.strip_prefix(name))
            .map(str::trim)
            .context("descriptor flags or inode missing")
    };
    Ok((
        u64::from_str_radix(value("flags:")?, 8)?,
        value("ino:")?.parse()?,
    ))
}

fn writable(flags: u64) -> bool {
    matches!(flags & libc::O_ACCMODE as u64, x if x == libc::O_WRONLY as u64 || x == libc::O_RDWR as u64)
}

pub(super) fn writers(home: &Path, managed: ProcessInstance) -> Result<HashMap<i32, Writer>> {
    scan(
        Path::new("/proc"),
        home,
        managed,
        nix::unistd::geteuid().as_raw(),
        process::identify_instance,
    )
}

fn scan<F>(
    proc_root: &Path,
    home: &Path,
    managed: ProcessInstance,
    user: u32,
    identify: F,
) -> Result<HashMap<i32, Writer>>
where
    F: Fn(i32) -> Result<Option<ProcessInstance>>,
{
    let sessions_root = match home.join("sessions").canonicalize() {
        Ok(root) => root,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(HashMap::new()),
        Err(error) => return Err(error).context("resolve Codex sessions root"),
    };
    ensure!(
        identify(managed.pid)? == Some(managed),
        "managed Codex birth proof changed"
    );
    let mut budget = Budget { bytes: 0, fds: 0 };
    let mut processes = 0;
    let mut sessions = 0;
    let mut candidates = HashMap::new();
    for entry in fs::read_dir(proc_root)? {
        let entry = entry?;
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|name| name.parse::<i32>().ok())
            .filter(|pid| *pid > 0)
        else {
            continue;
        };
        processes += 1;
        ensure!(
            processes <= MAX_PROCESSES,
            "proc inventory exceeds process limit"
        );
        let dir = entry.path();
        let metadata = match fs::metadata(&dir) {
            Ok(metadata) => metadata,
            Err(error) if vanished(&error) => continue,
            Err(error) => return Err(error).context("read process owner"),
        };
        if metadata.uid() != user {
            continue;
        }
        let Some(stat) = budget.read(&dir.join("stat"), 4096)? else {
            continue;
        };
        let Some(mut owner) = candidate(pid, &stat)? else {
            continue;
        };
        let Some(exe) = budget.link(&dir.join("exe"))? else {
            continue;
        };
        let descriptors = match fs::read_dir(dir.join("fd")) {
            Ok(descriptors) => descriptors,
            Err(error) if vanished(&error) => continue,
            Err(error) => return Err(error).context("read Codex descriptors"),
        };
        for (count, descriptor) in descriptors.enumerate() {
            let descriptor = descriptor?;
            budget.fds += 1;
            ensure!(
                count < MAX_PROCESS_FDS && budget.fds <= MAX_FDS,
                "proc inventory exceeds descriptor limit"
            );
            let link = descriptor.path();
            let Some(path) = budget.link(&link)? else {
                continue;
            };
            if !path.starts_with(&sessions_root)
                || path.extension().is_none_or(|ext| ext != "jsonl")
            {
                continue;
            }
            let fd_metadata = match fs::metadata(&link) {
                Ok(metadata) => metadata,
                Err(error) if vanished(&error) => continue,
                Err(error) => return Err(error).context("stat Codex descriptor"),
            };
            if !fd_metadata.is_file() {
                continue;
            }
            let info_path = dir.join("fdinfo").join(descriptor.file_name());
            let Some(info) = budget.read(&info_path, 4096)? else {
                continue;
            };
            let (flags, inode) = descriptor_info(&info)?;
            ensure!(inode == fd_metadata.ino(), "Codex descriptor inode changed");
            if !writable(flags) {
                continue;
            }
            let Some(after_info) = budget.read(&info_path, 4096)? else {
                continue;
            };
            let after_metadata = match fs::metadata(&link) {
                Ok(metadata) => metadata,
                Err(error) if vanished(&error) => continue,
                Err(error) => return Err(error).context("recheck Codex descriptor"),
            };
            let Some(after_path) = budget.link(&link)? else {
                continue;
            };
            ensure!(
                descriptor_info(&after_info)? == (flags, inode)
                    && after_metadata.dev() == fd_metadata.dev()
                    && after_metadata.ino() == inode
                    && after_path == path,
                "Codex descriptor changed during inventory"
            );
            sessions += 1;
            super::super::ensure_inventory_within_limit(sessions)?;
            owner.paths.push(path);
        }
        let Some(after) = budget.read(&dir.join("stat"), 4096)? else {
            continue;
        };
        let Some(after) = candidate(pid, &after)? else {
            continue;
        };
        ensure!(
            after.identity == owner.identity && after.parent == owner.parent,
            "Codex process changed during inventory"
        );
        if identify(pid)?.is_none() {
            continue;
        }
        ensure!(
            identify(pid)? == Some(owner.identity),
            "Codex birth proof changed during inventory"
        );
        ensure!(
            budget.link(&dir.join("exe"))?.as_deref() == Some(exe.as_path()),
            "Codex executable changed during inventory"
        );
        ensure!(
            fs::metadata(&dir)?.uid() == user,
            "Codex process owner changed during inventory"
        );
        candidates.insert(pid, owner);
    }
    let mut writers = HashMap::new();
    for (pid, owner) in &candidates {
        if owner.identity == managed {
            continue;
        }
        let inherited = candidates.get(&owner.parent).filter(|parent| {
            parent.identity.linux_birth.boot_id == owner.identity.linux_birth.boot_id
                && parent.identity.linux_birth.start_ticks <= owner.identity.linux_birth.start_ticks
        });
        let mut paths: HashSet<_> = owner.paths.iter().cloned().collect();
        if let Some(parent) = inherited {
            ensure!(
                identify(parent.identity.pid)? == Some(parent.identity),
                "Codex parent changed during inventory"
            );
            paths.retain(|path| !parent.paths.contains(path));
        }
        if !paths.is_empty() {
            ensure!(
                identify(*pid)? == Some(owner.identity),
                "Codex writer changed after inventory"
            );
            writers.insert(
                *pid,
                Writer {
                    identity: owner.identity,
                    paths: paths.into_iter().collect(),
                },
            );
        }
    }
    ensure!(
        identify(managed.pid)? == Some(managed),
        "managed Codex changed during inventory"
    );
    Ok(writers)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::os::unix::fs::symlink;

    fn identity(pid: i32) -> ProcessInstance {
        ProcessInstance {
            pid,
            started_micros: None,
            linux_birth: process::linux::birth_from_ticks(pid as u64).unwrap(),
        }
    }

    fn process(root: &Path, pid: i32, parent: i32, transcript: &Path) {
        let dir = root.join(pid.to_string());
        fs::create_dir_all(dir.join("fd")).unwrap();
        fs::create_dir_all(dir.join("fdinfo")).unwrap();
        fs::write(
            dir.join("stat"),
            format!("{pid} (codex) S {parent} 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 {pid}"),
        )
        .unwrap();
        symlink("/some/standalone/codex", dir.join("exe")).unwrap();
        symlink(transcript, dir.join("fd/7")).unwrap();
        fs::write(
            dir.join("fdinfo/7"),
            format!(
                "flags:\t0100001\nino:\t{}\n",
                fs::metadata(transcript).unwrap().ino()
            ),
        )
        .unwrap();
    }

    fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let proc_root = root.path().join("proc");
        let home = root.path().join("home");
        fs::create_dir_all(home.join("sessions")).unwrap();
        let transcript = home.join("sessions/thread.jsonl");
        fs::write(&transcript, "{}\n").unwrap();
        process(&proc_root, 123, 1, &transcript);
        (root, proc_root, home)
    }

    fn scan_fixture(proc_root: &Path, home: &Path) -> Result<HashMap<i32, Writer>> {
        scan(
            proc_root,
            home,
            identity(999),
            nix::unistd::geteuid().as_raw(),
            |pid| Ok(Some(identity(pid))),
        )
    }

    #[test]
    fn only_writable_regular_same_user_sessions_establish_ownership() {
        let (_root, proc_root, home) = fixture();
        assert_eq!(
            scan_fixture(&proc_root, &home).unwrap()[&123].paths,
            [home.join("sessions/thread.jsonl")]
        );
        let user = nix::unistd::geteuid().as_raw();
        assert!(
            scan(&proc_root, &home, identity(999), user + 1, |pid| Ok(Some(
                identity(pid)
            )))
            .unwrap()
            .is_empty()
        );
        let info = proc_root.join("123/fdinfo/7");
        let writable = fs::read_to_string(&info).unwrap();
        fs::write(&info, writable.replace("0100001", "0100000")).unwrap();
        assert!(scan_fixture(&proc_root, &home).unwrap().is_empty());
        fs::write(&info, writable).unwrap();
        fs::write(proc_root.join("123/stat"), "123 (other) S 1").unwrap();
        assert!(scan_fixture(&proc_root, &home).unwrap().is_empty());
    }

    #[test]
    fn symlinked_home_and_inherited_descriptors_preserve_one_owner() {
        let (root, proc_root, home) = fixture();
        process(&proc_root, 124, 123, &home.join("sessions/thread.jsonl"));
        let alias = root.path().join("alias");
        symlink(&home, &alias).unwrap();
        let writers = scan_fixture(&proc_root, &alias).unwrap();
        assert_eq!(writers.len(), 1);
        assert!(writers.contains_key(&123));
        assert!(
            scan(
                &proc_root,
                &home,
                identity(123),
                nix::unistd::geteuid().as_raw(),
                |pid| Ok(Some(identity(pid)))
            )
            .unwrap()
            .is_empty()
        );
    }

    #[test]
    fn descriptor_inode_and_birth_mismatches_fail_closed() {
        let (_root, proc_root, home) = fixture();
        let info = proc_root.join("123/fdinfo/7");
        let valid = fs::read(&info).unwrap();
        fs::write(&info, "flags:\t0100001\nino:\t0\n").unwrap();
        assert!(scan_fixture(&proc_root, &home).is_err());
        fs::write(&info, valid).unwrap();
        let reads = Cell::new(0);
        let changed = |pid| {
            let mut owner = identity(pid);
            if pid == 123 {
                reads.set(reads.get() + 1);
                owner.linux_birth.start_ticks += reads.get();
            }
            Ok(Some(owner))
        };
        assert!(
            scan(
                &proc_root,
                &home,
                identity(999),
                nix::unistd::geteuid().as_raw(),
                changed
            )
            .is_err()
        );
        assert!(descriptor_info(b"flags:\t8\nino:\t1\n").is_err());
        assert!(descriptor_info(b"flags:\t01\n").is_err());
    }

    #[test]
    fn closed_descriptors_disappeared_processes_and_bounds_are_explicit() {
        let (_root, proc_root, home) = fixture();
        fs::remove_file(proc_root.join("123/fdinfo/7")).unwrap();
        assert!(scan_fixture(&proc_root, &home).unwrap().is_empty());
        fs::remove_file(proc_root.join("123/stat")).unwrap();
        assert!(scan_fixture(&proc_root, &home).unwrap().is_empty());
        let mut budget = Budget {
            bytes: MAX_BYTES,
            fds: 0,
        };
        assert!(budget.add_bytes(1).is_err());
    }

    #[test]
    fn inventory_finds_a_live_standalone_codex_writer() {
        struct Child(std::process::Child);
        impl Drop for Child {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        fs::create_dir_all(home.join("sessions")).unwrap();
        let transcript = home.join("sessions/live.jsonl");
        let output = File::create(&transcript).unwrap();
        let executable = root.path().join("codex");
        fs::copy("/usr/bin/sleep", &executable).unwrap();
        let child = Child(
            std::process::Command::new(executable)
                .arg("30")
                .stdout(std::process::Stdio::from(output))
                .spawn()
                .unwrap(),
        );
        let pid = i32::try_from(child.0.id()).unwrap();
        let managed = process::identify_instance(i32::try_from(std::process::id()).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(writers(&home, managed).unwrap()[&pid].paths, [transcript]);
    }
}
