use std::io::Read;
use std::path::Path;

use anyhow::{Context, Result, ensure};

use super::{ProcessIdentity, ProcessLink};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Stat {
    parent: i32,
    start_ticks: u64,
}

fn read(path: &Path) -> Result<Option<String>> {
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error).with_context(|| format!("reading {}", path.display())),
    };
    let mut bytes = Vec::new();
    file.take(1_048_577).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= 1_048_576,
        "process information exceeds its bound"
    );
    Ok(Some(String::from_utf8(bytes)?))
}

fn parse_stat(pid: i32, text: &str) -> Result<Option<Stat>> {
    let (prefix, fields) = text
        .rsplit_once(") ")
        .context("process stat has no command boundary")?;
    let (actual, _) = prefix.split_once(" (").context("process stat has no pid")?;
    ensure!(
        actual.parse::<i32>()? == pid,
        "process stat belongs to another pid"
    );
    let fields = fields.split_whitespace().collect::<Vec<_>>();
    ensure!(fields.len() >= 20, "process stat is incomplete");
    if matches!(fields[0], "Z" | "X" | "x") {
        return Ok(None);
    }
    Ok(Some(Stat {
        parent: fields[1].parse()?,
        start_ticks: fields[19].parse()?,
    }))
}

fn stat(pid: i32) -> Result<Option<Stat>> {
    ensure!(pid > 0, "pid {pid} does not name an application process");
    read(Path::new(&format!("/proc/{pid}/stat")))?
        .map(|text| parse_stat(pid, &text))
        .transpose()
        .map(Option::flatten)
}

fn start_micros(stat: Stat) -> Result<u64> {
    let text = read(Path::new("/proc/stat"))?.context("kernel boot time is unavailable")?;
    let seconds = text
        .lines()
        .find_map(|line| line.strip_prefix("btime "))
        .context("kernel boot time is absent")?
        .parse::<u64>()?;
    // SAFETY: sysconf reads a process-independent integer without a pointer.
    let ticks = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    ensure!(ticks > 0, "kernel clock tick frequency is unavailable");
    seconds
        .checked_mul(1_000_000)
        .and_then(|boot| {
            stat.start_ticks
                .checked_mul(1_000_000)
                .map(|start| (boot, start))
        })
        .and_then(|(boot, start)| boot.checked_add(start / ticks as u64))
        .context("kernel start time is unrepresentable")
}

pub(super) fn process_link(pid: i32) -> Result<Option<ProcessLink>> {
    stat(pid)?
        .map(|value| {
            Ok(ProcessLink {
                started_micros: start_micros(value)?,
                parent_pid: value.parent,
            })
        })
        .transpose()
}

pub(super) fn identify(pid: i32) -> Result<Option<ProcessIdentity>> {
    let Some(before) = stat(pid)? else {
        return Ok(None);
    };
    let executable = match std::fs::read_link(format!("/proc/{pid}/exe")) {
        Ok(path) => path,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error).context("reading process executable"),
    };
    let started_micros = start_micros(before)?;
    Ok((stat(pid)? == Some(before)).then_some(ProcessIdentity {
        started_micros,
        executable,
    }))
}

pub(crate) fn kernel_identity(pid: i32) -> Result<Option<(String, u64)>> {
    let Some(value) = stat(pid)? else {
        return Ok(None);
    };
    let boot = read(Path::new("/proc/sys/kernel/random/boot_id"))?
        .context("kernel boot identity is unavailable")?;
    Ok(Some((boot.trim().to_owned(), value.start_ticks)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_boundaries_do_not_change_the_process_birth_or_parent() {
        let fields = "S 40 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1234";
        assert_eq!(
            parse_stat(42, &format!("42 (a ) tricky name) {fields}")).unwrap(),
            Some(Stat {
                parent: 40,
                start_ticks: 1234
            })
        );
        assert!(parse_stat(41, &format!("42 (name) {fields}")).is_err());
        assert_eq!(
            parse_stat(42, &format!("42 (name) {}", fields.replacen('S', "Z", 1))).unwrap(),
            None
        );
        assert!(parse_stat(42, "42 (name) S 40").is_err());
    }

    #[tokio::test]
    async fn socket_caller_is_the_actual_kernel_peer() {
        let (client, server) = tokio::net::UnixStream::pair().unwrap();
        let (pid, identity) = super::super::unix_peer_identity(&server).unwrap();
        assert_eq!(pid as u32, std::process::id());
        assert_eq!(Some(identity), identify(pid).unwrap());
        drop(client);
    }
}
