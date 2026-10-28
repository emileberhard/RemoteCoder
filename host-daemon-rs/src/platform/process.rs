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

/// A live process's kernel identity and current executable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ProcessIdentity {
    /// Kernel start time in microseconds since the epoch.
    pub started_micros: u64,
    pub executable: PathBuf,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ProcessInstance {
    pub pid: i32,
    pub started_micros: u64,
}

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

#[cfg(not(target_os = "macos"))]
pub(crate) fn unix_peer_identity(_: &tokio::net::UnixStream) -> Result<(i32, ProcessIdentity)> {
    anyhow::bail!("verified Unix socket peer identity is unavailable on this platform")
}

#[cfg(target_os = "macos")]
pub(crate) fn ancestry(process: ProcessInstance) -> Result<Vec<ProcessInstance>> {
    use anyhow::{Context, ensure};
    let mut chain = Vec::new();
    let mut current = process;
    while current.pid > 1 {
        ensure!(
            chain.len() < 64 && !chain.contains(&current),
            "caller process ancestry exceeds its bounded proof"
        );
        let child = process_info(current.pid)?
            .context("caller process exited during ancestry verification")?;
        ensure!(
            info_start(&child)? == current.started_micros,
            "caller process identity is stale"
        );
        chain.push(current);
        let parent_pid = i32::try_from(child.pbi_ppid)?;
        if parent_pid <= 1 {
            break;
        }
        let parent = process_info(parent_pid)?
            .context("caller parent exited during ancestry verification")?;
        let parent_start = info_start(&parent)?;
        let recheck = process_info(current.pid)?
            .context("caller process exited during ancestry verification")?;
        ensure!(
            info_start(&recheck)? == current.started_micros
                && recheck.pbi_ppid == child.pbi_ppid
                && parent_start <= current.started_micros,
            "caller process ancestry changed during verification"
        );
        current = ProcessInstance {
            pid: parent_pid,
            started_micros: parent_start,
        };
    }
    Ok(chain)
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn ancestry(_: ProcessInstance) -> Result<Vec<ProcessInstance>> {
    anyhow::bail!("verified caller process ancestry is unavailable on this platform")
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

#[cfg(not(target_os = "macos"))]
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

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use crate::platform::macos::application::request_quit;

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
    fn a_pid_that_names_no_application_is_an_error_not_absence() {
        assert!(identify(0).is_err());
        assert!(identify(-1).is_err());
    }

    #[test]
    fn a_quit_request_to_a_process_that_is_not_an_app_fails_without_signalling() {
        // Exercises the whole descriptor/event/send ABI against a pid that
        // cannot exist, so nothing on the host receives the event.
        let error = request_quit(i32::MAX).expect_err("no such application");
        assert!(format!("{error:#}").contains("-600"), "{error:#}");
        assert!(request_quit(0).is_err());
    }
}
