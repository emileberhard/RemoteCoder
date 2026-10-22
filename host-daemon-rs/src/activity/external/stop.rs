use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use nix::errno::Errno;
use nix::sys::signal::{Signal, kill, killpg};
use nix::unistd::{Pid, getpgid};

use crate::platform::process::identify;

const SIGNAL_GRACE: Duration = Duration::from_secs(5);
const EXIT_POLL_INTERVAL: Duration = Duration::from_millis(100);

pub(crate) async fn stop_client(pid: i32) -> Result<()> {
    anyhow::ensure!(
        u32::try_from(pid).is_ok_and(|pid| pid > 1 && pid != std::process::id()),
        "pid {pid} cannot be stopped as another client"
    );
    let Some(identity) = identify(pid)? else {
        return Ok(());
    };
    let started = identity.started_micros;
    let target = Pid::from_raw(pid);
    let own_group = getpgid(None).context("reading the gateway's process group failed")?;
    let leads_group =
        getpgid(Some(target)).is_ok_and(|group| group == target && group != own_group);
    for signal in [Signal::SIGTERM, Signal::SIGKILL] {
        if !still_running(pid, started)? {
            return Ok(());
        }
        let sent = if leads_group {
            killpg(target, signal)
        } else {
            kill(target, signal)
        };
        match sent {
            Ok(()) | Err(Errno::ESRCH) => {}
            Err(error) => {
                return Err(error).with_context(|| format!("sending {signal} to pid {pid} failed"));
            }
        }
        let deadline = Instant::now() + SIGNAL_GRACE;
        while Instant::now() < deadline {
            if !still_running(pid, started)? {
                return Ok(());
            }
            tokio::time::sleep(EXIT_POLL_INTERVAL).await;
        }
    }
    bail!("the other client's process {pid} is still running after SIGKILL")
}

fn still_running(pid: i32, started_micros: u64) -> Result<bool> {
    Ok(identify(pid)?.is_some_and(|identity| identity.started_micros == started_micros))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_client_process_stops_on_term() {
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .expect("sleep");
        let pid = i32::try_from(child.id()).expect("pid");
        let reaper = std::thread::spawn(move || child.wait());

        stop_client(pid).await.expect("stop");

        assert!(!reaper.join().expect("reaper").expect("wait").success());
    }

    #[tokio::test]
    async fn the_gateway_never_stops_itself() {
        let own = i32::try_from(std::process::id()).expect("pid");
        assert!(stop_client(own).await.is_err());
        assert!(stop_client(1).await.is_err());
    }
}
