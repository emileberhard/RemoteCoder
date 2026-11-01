//! Exact-instance operations on a macOS application process.
//!
//! A pid alone does not name a process: it can be reused as soon as the
//! original exits. Callers pair it with the kernel start time from
//! [`identify`] and revalidate that identity immediately before acting.
//! macOS has no way to signal or address a process by that identity, so a
//! replacement in the instant between the check and the request remains
//! possible; revalidation makes the window microseconds, not a whole stop.

use std::path::PathBuf;

use anyhow::Result;

#[cfg(target_os = "linux")]
#[path = "process_linux.rs"]
pub(crate) mod linux;

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct LinuxBirth {
    #[serde(with = "boot_id")]
    pub boot_id: [u8; 36],
    pub start_ticks: u64,
}

pub(super) mod boot_id {
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(value: &[u8; 36], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(std::str::from_utf8(value).map_err(serde::ser::Error::custom)?)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<[u8; 36], D::Error> {
        let value = String::deserialize(deserializer)?;
        parse(&value).ok_or_else(|| serde::de::Error::custom("invalid Linux boot UUID"))
    }

    pub fn parse(value: &str) -> Option<[u8; 36]> {
        let bytes: [u8; 36] = value.as_bytes().try_into().ok()?;
        for (index, byte) in bytes.iter().enumerate() {
            if [8, 13, 18, 23].contains(&index) {
                if *byte != b'-' {
                    return None;
                }
            } else if !byte.is_ascii_digit() && !(b'a'..=b'f').contains(byte) {
                return None;
            }
        }
        Some(bytes)
    }
}

/// A live process's kernel identity and current executable.
#[derive(Debug, Clone)]
pub(crate) struct ProcessIdentity {
    /// Kernel start time in microseconds since the epoch.
    pub started_micros: u64,
    #[cfg(target_os = "linux")]
    pub linux_birth: LinuxBirth,
    pub executable: PathBuf,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct ProcessInstance {
    pub pid: i32,
    #[cfg(not(target_os = "linux"))]
    pub started_micros: u64,
    #[cfg(target_os = "linux")]
    pub started_micros: Option<u64>,
    #[cfg(target_os = "linux")]
    pub linux_birth: LinuxBirth,
}

impl PartialEq for ProcessIdentity {
    fn eq(&self, other: &Self) -> bool {
        self.executable == other.executable && {
            #[cfg(target_os = "linux")]
            {
                self.linux_birth == other.linux_birth
            }
            #[cfg(not(target_os = "linux"))]
            {
                self.started_micros == other.started_micros
            }
        }
    }
}
impl Eq for ProcessIdentity {}

impl ProcessIdentity {
    #[cfg(any(not(target_os = "linux"), test))]
    pub fn instance(&self, pid: i32) -> ProcessInstance {
        ProcessInstance {
            pid,
            #[cfg(not(target_os = "linux"))]
            started_micros: self.started_micros,
            #[cfg(target_os = "linux")]
            started_micros: Some(self.started_micros),
            #[cfg(target_os = "linux")]
            linux_birth: self.linux_birth,
        }
    }
}

impl PartialEq for ProcessInstance {
    fn eq(&self, other: &Self) -> bool {
        self.pid == other.pid && {
            #[cfg(target_os = "linux")]
            {
                self.linux_birth == other.linux_birth
            }
            #[cfg(not(target_os = "linux"))]
            {
                self.started_micros == other.started_micros
            }
        }
    }
}
impl Eq for ProcessInstance {}

#[cfg(target_os = "macos")]
pub(crate) fn unix_peer_identity(
    stream: &tokio::net::UnixStream,
) -> Result<(i32, ProcessIdentity)> {
    use anyhow::Context;
    let pid = nix::sys::socket::getsockopt(stream, nix::sys::socket::sockopt::LocalPeerPid)
        .context("Unix socket peer process identity is unavailable")?;
    let identity = identify(pid)?.context("Unix socket peer process exited")?;
    Ok((pid, identity))
}

#[cfg(target_os = "linux")]
pub(crate) fn unix_peer_identity(
    stream: &tokio::net::UnixStream,
) -> Result<(i32, ProcessIdentity)> {
    use anyhow::{Context, ensure};
    let peer = nix::sys::socket::getsockopt(stream, nix::sys::socket::sockopt::PeerCredentials)
        .context("Unix socket peer credentials are unavailable")?;
    ensure!(
        peer.uid() == nix::unistd::geteuid().as_raw(),
        "Unix socket peer belongs to another user"
    );
    let pid = peer.pid();
    let identity = identify(pid)?.context("Unix socket peer process exited")?;
    Ok((pid, identity))
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(crate) fn unix_peer_identity(_: &tokio::net::UnixStream) -> Result<(i32, ProcessIdentity)> {
    anyhow::bail!("verified Unix socket peer identity is unavailable on this platform")
}

#[cfg(target_os = "linux")]
pub(crate) fn identify_instance(pid: i32) -> Result<Option<ProcessInstance>> {
    linux::identify_instance(pid)
}

#[cfg(not(target_os = "linux"))]
pub(crate) fn identify_instance(pid: i32) -> Result<Option<ProcessInstance>> {
    Ok(identify(pid)?.map(|identity| identity.instance(pid)))
}

#[cfg(target_os = "linux")]
pub(crate) fn unix_peer_instance(stream: &tokio::net::UnixStream) -> Result<ProcessInstance> {
    use anyhow::{Context, ensure};
    let peer = nix::sys::socket::getsockopt(stream, nix::sys::socket::sockopt::PeerCredentials)
        .context("Unix socket peer credentials are unavailable")?;
    ensure!(
        peer.uid() == nix::unistd::geteuid().as_raw(),
        "Unix socket peer belongs to another user"
    );
    identify_instance(peer.pid())?.context("Unix socket peer process exited")
}

#[cfg(not(target_os = "linux"))]
pub(crate) fn unix_peer_instance(stream: &tokio::net::UnixStream) -> Result<ProcessInstance> {
    unix_peer_identity(stream).map(|(pid, identity)| identity.instance(pid))
}

#[cfg(target_os = "macos")]
pub(crate) fn ancestry(process: ProcessInstance) -> impl Iterator<Item = Result<ProcessInstance>> {
    walk_ancestry(process, |pid| {
        process_info(pid)?
            .map(|info| {
                Ok(ProcessLink {
                    started_micros: info_start(&info)?,
                    parent_pid: i32::try_from(info.pbi_ppid)?,
                })
            })
            .transpose()
    })
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[derive(Clone, Copy)]
struct ProcessLink {
    #[cfg(not(target_os = "linux"))]
    started_micros: u64,
    #[cfg(target_os = "linux")]
    started_micros: Option<u64>,
    parent_pid: i32,
    #[cfg(target_os = "linux")]
    linux_birth: LinuxBirth,
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
impl ProcessLink {
    fn instance(self, pid: i32) -> ProcessInstance {
        ProcessInstance {
            pid,
            started_micros: self.started_micros,
            #[cfg(target_os = "linux")]
            linux_birth: self.linux_birth,
        }
    }
    fn same(self, other: Self, pid: i32) -> bool {
        self.parent_pid == other.parent_pid && self.instance(pid) == other.instance(pid)
    }
    fn precedes(self, child: ProcessInstance) -> bool {
        #[cfg(target_os = "linux")]
        {
            self.linux_birth.boot_id == child.linux_birth.boot_id
                && self.linux_birth.start_ticks <= child.linux_birth.start_ticks
        }
        #[cfg(not(target_os = "linux"))]
        {
            self.started_micros <= child.started_micros
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn walk_ancestry(
    process: ProcessInstance,
    mut read: impl FnMut(i32) -> Result<Option<ProcessLink>>,
) -> impl Iterator<Item = Result<ProcessInstance>> {
    use anyhow::{Context, ensure};
    let mut first = Some(process);
    let mut previous: Option<(ProcessInstance, ProcessLink)> = None;
    let mut chain = Vec::new();
    let mut ended = false;
    std::iter::from_fn(move || {
        if ended {
            return None;
        }
        let step = (|| -> Result<Option<ProcessInstance>> {
            let next_pid = first
                .map(|process| process.pid)
                .or_else(|| previous.map(|(_, info)| info.parent_pid))
                .context("process ancestry lost its next instance")?;
            if next_pid <= 1 {
                return Ok(None);
            }
            ensure!(
                chain.len() < 64,
                "caller process ancestry exceeds its bounded proof"
            );
            let (current, info) = if let Some(current) = first.take() {
                let info = read(current.pid)?
                    .context("caller process exited during ancestry verification")?;
                ensure!(
                    info.instance(current.pid) == current,
                    "caller process identity is stale"
                );
                (current, info)
            } else {
                let (child, child_info) =
                    previous.context("process ancestry lost its previous instance")?;
                let parent = read(child_info.parent_pid)?
                    .context("caller parent exited during ancestry verification")?;
                let recheck = read(child.pid)?
                    .context("caller process exited during ancestry verification")?;
                ensure!(
                    recheck.same(child_info, child.pid) && parent.precedes(child),
                    "caller process ancestry changed during verification"
                );
                (parent.instance(child_info.parent_pid), parent)
            };
            ensure!(
                !chain.contains(&current),
                "caller process ancestry exceeds its bounded proof"
            );
            chain.push(current);
            previous = Some((current, info));
            Ok(Some(current))
        })();
        match step {
            Ok(Some(process)) => Some(Ok(process)),
            Ok(None) => {
                ended = true;
                None
            }
            Err(error) => {
                ended = true;
                Some(Err(error))
            }
        }
    })
}

#[cfg(target_os = "linux")]
pub(crate) fn ancestry(process: ProcessInstance) -> impl Iterator<Item = Result<ProcessInstance>> {
    walk_ancestry(process, linux::process_link)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(crate) fn ancestry(_: ProcessInstance) -> impl Iterator<Item = Result<ProcessInstance>> {
    std::iter::once(Err(anyhow::anyhow!(
        "verified caller process ancestry is unavailable on this platform"
    )))
}

/// Reads `pid`'s identity. `Ok(None)` means the process no longer runs (it
/// exited, is a zombie, or was replaced while being read). Every other
/// failure is an error: an unreadable process is unknown, never absent.
#[cfg(target_os = "macos")]
pub(crate) fn identify(pid: i32) -> Result<Option<ProcessIdentity>> {
    let Some(started_micros) = start_micros(pid)? else {
        return Ok(None);
    };
    let Some(executable) = executable_path(pid)? else {
        return Ok(None);
    };
    // The same start time on both sides of the path read proves the path
    // belongs to that process, not to a successor that reused the pid.
    Ok(
        (start_micros(pid)? == Some(started_micros)).then_some(ProcessIdentity {
            started_micros,
            executable,
        }),
    )
}

#[cfg(target_os = "linux")]
pub(crate) fn identify(pid: i32) -> Result<Option<ProcessIdentity>> {
    linux::identify(pid)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(crate) fn identify(pid: i32) -> Result<Option<ProcessIdentity>> {
    anyhow::bail!("process identity is unavailable on this platform (pid {pid})")
}

#[cfg(target_os = "macos")]
fn start_micros(pid: i32) -> Result<Option<u64>> {
    process_info(pid)?.map(|info| info_start(&info)).transpose()
}

#[cfg(target_os = "macos")]
fn process_info(pid: i32) -> Result<Option<libc::proc_bsdinfo>> {
    use anyhow::bail;

    if pid <= 0 {
        bail!("pid {pid} does not name an application process");
    }
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::uninit();
    let expected_size = std::mem::size_of::<libc::proc_bsdinfo>();
    // SAFETY: proc_pidinfo receives a correctly sized writable proc_bsdinfo
    // buffer and initializes it only when it returns that exact byte count.
    let written = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            info.as_mut_ptr().cast(),
            i32::try_from(expected_size)?,
        )
    };
    if written <= 0 {
        return absent_or_error(pid, "start time");
    }
    if usize::try_from(written).ok() != Some(expected_size) {
        bail!("pid {pid} returned {written} of {expected_size} process-information bytes");
    }
    // SAFETY: the exact-size return above guarantees full initialization.
    let info = unsafe { info.assume_init() };
    if info.pbi_status == libc::SZOMB {
        return Ok(None);
    }
    Ok(Some(info))
}

#[cfg(target_os = "macos")]
fn info_start(info: &libc::proc_bsdinfo) -> Result<u64> {
    use anyhow::Context;
    info.pbi_start_tvsec
        .checked_mul(1_000_000)
        .and_then(|micros| micros.checked_add(info.pbi_start_tvusec))
        .with_context(|| {
            format!(
                "pid {} reported an unrepresentable start time",
                info.pbi_pid
            )
        })
}

#[cfg(target_os = "macos")]
fn executable_path(pid: i32) -> Result<Option<PathBuf>> {
    use std::os::unix::ffi::OsStringExt;

    let mut buffer = vec![0_u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: the buffer is writable for the length passed.
    let written = unsafe {
        libc::proc_pidpath(
            pid,
            buffer.as_mut_ptr().cast(),
            u32::try_from(buffer.len())?,
        )
    };
    if written <= 0 {
        return absent_or_error(pid, "executable path");
    }
    buffer.truncate(usize::try_from(written)?);
    Ok(Some(PathBuf::from(std::ffi::OsString::from_vec(buffer))))
}

/// Resolves a failed libproc read: only `ESRCH` proves the process is gone.
#[cfg(target_os = "macos")]
fn absent_or_error<T>(pid: i32, what: &str) -> Result<Option<T>> {
    let error = std::io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        return Ok(None);
    }
    Err(anyhow::Error::new(error).context(format!("could not read the {what} of pid {pid}")))
}

#[cfg(all(test, any(target_os = "macos", target_os = "linux")))]
mod tests {
    use super::*;
    #[cfg(target_os = "macos")]
    use crate::platform::macos::application::request_quit;

    #[test]
    #[cfg(target_os = "macos")]
    fn claude_owner_stops_before_privileged_launchers_without_hiding_proof_errors() {
        let caller = ProcessInstance {
            pid: 40,
            started_micros: 400,
        };
        let owner = ProcessInstance {
            pid: 30,
            started_micros: 300,
        };
        let table = |pid| match pid {
            40 => Ok(Some(ProcessLink {
                started_micros: 400,
                parent_pid: 35,
            })),
            35 => Ok(Some(ProcessLink {
                started_micros: 350,
                parent_pid: 30,
            })),
            30 => Ok(Some(ProcessLink {
                started_micros: 300,
                parent_pid: 20,
            })),
            20 => anyhow::bail!("could not read the start time of pid 20: Operation not permitted"),
            _ => panic!("unexpected process {pid}"),
        };
        let mut reads = Vec::new();
        let mut proof = Vec::new();
        for candidate in walk_ancestry(caller, |pid| {
            reads.push(pid);
            table(pid)
        }) {
            let candidate = candidate.unwrap();
            proof.push(candidate);
            if candidate == owner {
                break;
            }
        }
        let middle = ProcessInstance {
            pid: 35,
            started_micros: 350,
        };
        assert_eq!(proof, [caller, middle, owner]);
        assert!(!reads.contains(&20));
        assert_eq!(
            walk_ancestry(caller, table)
                .collect::<Result<Vec<_>>>()
                .unwrap_err()
                .to_string(),
            "could not read the start time of pid 20: Operation not permitted"
        );
        for unreadable in [40, 35, 30] {
            let error = walk_ancestry(caller, |pid| {
                if pid == unreadable {
                    anyhow::bail!("unreadable process {pid}");
                }
                table(pid)
            })
            .collect::<Result<Vec<_>>>()
            .unwrap_err();
            assert_eq!(
                error.to_string(),
                format!("unreadable process {unreadable}")
            );
        }
        let chain = walk_ancestry(caller, |pid| {
            if pid == 20 {
                Ok(Some(ProcessLink {
                    started_micros: 200,
                    parent_pid: 1,
                }))
            } else {
                table(pid)
            }
        })
        .collect::<Result<Vec<_>>>()
        .unwrap();
        assert_eq!(
            chain,
            [
                caller,
                middle,
                owner,
                ProcessInstance {
                    pid: 20,
                    started_micros: 200
                }
            ]
        );
    }

    #[test]
    fn a_live_process_has_a_stable_identity_and_a_missing_one_has_none() {
        let pid = i32::try_from(std::process::id()).expect("pid fits i32");
        let first = identify(pid)
            .expect("readable")
            .expect("this test process is running");
        assert_eq!(
            first.executable,
            std::fs::canonicalize(std::env::current_exe().expect("test binary"))
                .expect("canonical test binary")
        );
        assert_eq!(identify(pid).expect("readable"), Some(first));
        assert_eq!(identify(i32::MAX).expect("absence is not an error"), None);
    }

    #[test]
    fn lazy_ancestry_verifies_live_parent_links_and_stale_instances() {
        let pid = std::process::id() as i32;
        let owner = identify(pid).unwrap().unwrap().instance(pid);
        assert_eq!(ancestry(owner).next().transpose().unwrap(), Some(owner));
        let mut child = std::process::Command::new("/bin/cat")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let child_pid = child.id() as i32;
        let child_instance = identify(child_pid).unwrap().unwrap().instance(child_pid);
        let proof = ancestry(child_instance).take(2).collect::<Result<Vec<_>>>();
        child.kill().unwrap();
        child.wait().unwrap();
        assert_eq!(proof.unwrap(), vec![child_instance, owner]);
        let mut stale = owner;
        #[cfg(target_os = "linux")]
        {
            stale.linux_birth.start_ticks += 1;
        }
        #[cfg(target_os = "macos")]
        {
            stale.started_micros += 1;
        }
        assert!(ancestry(stale).next().unwrap().is_err());
    }

    #[test]
    fn a_pid_that_names_no_application_is_an_error_not_absence() {
        assert!(identify(0).is_err());
        assert!(identify(-1).is_err());
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn a_quit_request_to_a_process_that_is_not_an_app_fails_without_signalling() {
        // Exercises the whole descriptor/event/send ABI against a pid that
        // cannot exist, so nothing on the host receives the event.
        let error = request_quit(i32::MAX).expect_err("no such application");
        assert!(format!("{error:#}").contains("-600"), "{error:#}");
        assert!(request_quit(0).is_err());
    }
}
