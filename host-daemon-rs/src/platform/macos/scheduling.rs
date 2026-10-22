use nix::errno::Errno;
use serde::Serialize;
use std::io::{self, Write};
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::Duration;
use tokio_util::task::AbortOnDropHandle;
use tracing::{error, warn};

use crate::observability::journal::Journal;

const DEFAULT_BASE_PRIORITY: i32 = 31;
const CHECK_INTERVAL: Duration = Duration::from_secs(1);
const TASK_INFO_SIZE: i32 = std::mem::size_of::<libc::proc_taskinfo>() as i32;
const _: () = assert!(TASK_INFO_SIZE as usize == std::mem::size_of::<libc::proc_taskinfo>());
static FIRST_QOS_ERROR: AtomicI32 = AtomicI32::new(0);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Scheduling {
    darwin_background: bool,
    base_priority: i32,
}

impl Scheduling {
    fn is_demoted(self) -> bool {
        self.darwin_background || self.base_priority < DEFAULT_BASE_PRIORITY
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SchedulingCheck {
    Observed(Scheduling),
    LeftDarwinBackground {
        before: Scheduling,
        after: Scheduling,
    },
}

pub(crate) struct GatewayLogWriter<W> {
    writer: W,
    configured: bool,
}

impl<W> GatewayLogWriter<W> {
    pub(crate) fn new(writer: W) -> Self {
        Self {
            writer,
            configured: false,
        }
    }

    fn configure_thread(&mut self) {
        if !self.configured {
            set_gateway_thread_qos();
            self.configured = true;
        }
    }
}

impl<W: Write> Write for GatewayLogWriter<W> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.configure_thread();
        self.writer.write(bytes)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.configure_thread();
        self.writer.flush()
    }
}

pub(crate) fn prepare_agent_command(command: &mut tokio::process::Command) {
    // SAFETY: after fork the closure only calls allocation-free, async-signal-safe
    // setpriority on the child process and returns without touching shared state.
    unsafe {
        command.pre_exec(|| {
            libc::setpriority(libc::PRIO_DARWIN_PROCESS, 0, 0);
            Ok(())
        });
    }
}

pub(crate) fn set_gateway_thread_qos() {
    // SAFETY: pthread_set_qos_class_self_np changes only the calling thread.
    let status = unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INITIATED, 0)
    };
    if status != 0 {
        let _ = FIRST_QOS_ERROR.compare_exchange(0, status, Ordering::Relaxed, Ordering::Relaxed);
    }
}

pub(crate) fn leave_darwin_background() -> io::Result<SchedulingCheck> {
    let before = current()?;
    if !before.darwin_background {
        return Ok(SchedulingCheck::Observed(before));
    }
    // SAFETY: setpriority changes only this process's own Darwin background
    // request, which its future children inherit.
    if unsafe { libc::setpriority(libc::PRIO_DARWIN_PROCESS, 0, 0) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(SchedulingCheck::LeftDarwinBackground {
        before,
        after: current()?,
    })
}

pub(crate) fn log_startup(check: &io::Result<SchedulingCheck>) {
    match check {
        Ok(SchedulingCheck::Observed(_)) => {}
        Ok(SchedulingCheck::LeftDarwinBackground { before, after }) => {
            warn!(
                ?before,
                ?after,
                "started in Darwin background scheduling; left it"
            );
        }
        Err(error) => error!(%error, "Darwin background scheduling check failed"),
    }
}

pub(crate) fn spawn_darwin_background_guard(
    journal: Journal,
    startup: io::Result<SchedulingCheck>,
) -> AbortOnDropHandle<()> {
    AbortOnDropHandle::new(tokio::spawn(stay_out_of_darwin_background(
        journal, startup,
    )))
}

async fn stay_out_of_darwin_background(journal: Journal, startup: io::Result<SchedulingCheck>) {
    let mut check = startup;
    let mut demoted = false;
    let mut qos_warned = false;
    loop {
        let qos_error = FIRST_QOS_ERROR.load(Ordering::Relaxed);
        if !qos_warned && qos_error != 0 {
            qos_warned = true;
            let error = io::Error::from_raw_os_error(qos_error);
            warn!(%error, "gateway thread QoS unavailable; continuing with inherited scheduling");
            journal.runtime(
                "scheduling_qos_failed",
                serde_json::json!({ "qosClass": "userInitiated", "error": error.to_string() }),
            );
        }
        let state = match check {
            Ok(SchedulingCheck::Observed(state)) => state,
            Ok(SchedulingCheck::LeftDarwinBackground { before, after }) => {
                warn!(?before, ?after, "left Darwin background scheduling");
                journal.runtime(
                    "scheduling_restored",
                    serde_json::json!({ "before": before, "after": after }),
                );
                after
            }
            Err(error) => {
                error!(%error, "scheduling guard stopped");
                journal.runtime(
                    "scheduling_guard_failed",
                    serde_json::json!({ "error": error.to_string() }),
                );
                return;
            }
        };
        if state.is_demoted() != demoted {
            demoted = state.is_demoted();
            warn!(?state, demoted, "gateway scheduling changed");
            journal.runtime(
                if demoted {
                    "scheduling_demoted"
                } else {
                    "scheduling_recovered"
                },
                serde_json::json!({ "state": state }),
            );
        }
        tokio::time::sleep(CHECK_INTERVAL).await;
        check = leave_darwin_background();
    }
}

fn current() -> io::Result<Scheduling> {
    Errno::clear();
    // SAFETY: getpriority reads this process's own Darwin background request.
    let background = unsafe { libc::getpriority(libc::PRIO_DARWIN_PROCESS, 0) };
    if background == -1 && Errno::last_raw() != 0 {
        return Err(io::Error::last_os_error());
    }
    let mut info = std::mem::MaybeUninit::<libc::proc_taskinfo>::uninit();
    // SAFETY: proc_pidinfo receives a correctly sized writable proc_taskinfo
    // buffer and initializes it only when it returns that exact byte count.
    let written = unsafe {
        libc::proc_pidinfo(
            nix::unistd::getpid().as_raw(),
            libc::PROC_PIDTASKINFO,
            0,
            info.as_mut_ptr().cast(),
            TASK_INFO_SIZE,
        )
    };
    if written <= 0 {
        return Err(io::Error::last_os_error());
    }
    if written != TASK_INFO_SIZE {
        return Err(io::Error::other(format!(
            "proc_pidinfo returned {written} of {TASK_INFO_SIZE} task info bytes"
        )));
    }
    // SAFETY: the exact-size return above guarantees full initialization.
    let base_priority = unsafe { info.assume_init() }.pti_priority;
    Ok(Scheduling {
        darwin_background: background != 0,
        base_priority,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const INHERITED_BACKGROUND_TEST: &str =
        "platform::macos::scheduling::tests::an_inherited_background_request_is_left";

    #[test]
    fn a_process_started_in_darwin_background_leaves_it() {
        let output = std::process::Command::new("/usr/sbin/taskpolicy")
            .arg("-b")
            .arg(std::env::current_exe().unwrap())
            .args(["--exact", INHERITED_BACKGROUND_TEST, "--ignored"])
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            output.status.success() && stdout.contains("1 passed"),
            "{stdout}{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    #[ignore = "runs only inside the taskpolicy -b child of the test above"]
    fn an_inherited_background_request_is_left() {
        let SchedulingCheck::LeftDarwinBackground { before, after } =
            leave_darwin_background().unwrap()
        else {
            panic!("the inherited background request was not observed");
        };
        assert_eq!(
            before,
            Scheduling {
                darwin_background: true,
                base_priority: 4
            }
        );
        assert!(!after.darwin_background);
        assert_eq!(
            leave_darwin_background().unwrap(),
            SchedulingCheck::Observed(after)
        );
    }
}
