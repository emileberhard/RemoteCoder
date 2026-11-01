use std::io::Read;
use std::path::Path;
use std::sync::OnceLock;

use anyhow::{Context, Result, ensure};

use super::{LinuxBirth, ProcessIdentity, ProcessInstance, ProcessLink};

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

pub(crate) fn display_start_micros(start_ticks: u64) -> Result<u64> {
    let text = read(Path::new("/proc/stat"))?.context("kernel boot time is unavailable")?;
    let seconds = text
        .lines()
        .find_map(|line| line.strip_prefix("btime "))
        .context("kernel boot time is absent")?
        .parse::<u64>()?;
    static CLOCK_TICKS: OnceLock<u64> = OnceLock::new();
    let ticks = if let Some(ticks) = CLOCK_TICKS.get() {
        *ticks
    } else {
        // SAFETY: sysconf reads a process-independent integer without a pointer.
        let ticks = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
        ensure!(ticks > 0, "kernel clock tick frequency is unavailable");
        let ticks = ticks as u64;
        *CLOCK_TICKS.get_or_init(|| ticks)
    };
    seconds
        .checked_mul(1_000_000)
        .and_then(|boot| {
            start_ticks
                .checked_mul(1_000_000)
                .map(|start| (boot, start))
        })
        .and_then(|(boot, start)| boot.checked_add(start / ticks))
        .context("kernel start time is unrepresentable")
}

pub(super) fn process_link(pid: i32) -> Result<Option<ProcessLink>> {
    stat(pid)?
        .map(|value| {
            Ok(ProcessLink {
                started_micros: None,
                linux_birth: birth(value)?,
                parent_pid: value.parent,
            })
        })
        .transpose()
}

pub(super) fn identify_instance(pid: i32) -> Result<Option<ProcessInstance>> {
    let Some(before) = stat(pid)? else {
        return Ok(None);
    };
    let linux_birth = birth(before)?;
    Ok((stat(pid)? == Some(before)).then_some(ProcessInstance {
        pid,
        started_micros: None,
        linux_birth,
    }))
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
    let started_micros = display_start_micros(before.start_ticks)?;
    let linux_birth = birth(before)?;
    Ok((stat(pid)? == Some(before)).then_some(ProcessIdentity {
        started_micros,
        linux_birth,
        executable,
    }))
}

fn birth(stat: Stat) -> Result<LinuxBirth> {
    birth_from_ticks(stat.start_ticks)
}

pub(crate) fn birth_from_ticks(start_ticks: u64) -> Result<LinuxBirth> {
    static BOOT_ID: OnceLock<[u8; 36]> = OnceLock::new();
    let boot_id = if let Some(boot_id) = BOOT_ID.get() {
        *boot_id
    } else {
        let boot = read(Path::new("/proc/sys/kernel/random/boot_id"))?
            .context("kernel boot identity is unavailable")?;
        let boot_id =
            super::boot_id::parse(boot.trim()).context("kernel boot identity is invalid")?;
        *BOOT_ID.get_or_init(|| boot_id)
    };
    Ok(LinuxBirth {
        boot_id,
        start_ticks,
    })
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
        let fields = "S 40 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1234";
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

    #[test]
    fn ancestry_uses_boot_and_ticks_across_wall_clock_steps() {
        use super::super::{ProcessInstance, walk_ancestry};
        let boot_id = *b"01234567-89ab-cdef-0123-456789abcdef";
        let birth = |ticks| LinuxBirth {
            boot_id,
            start_ticks: ticks,
        };
        let caller = ProcessInstance {
            pid: 40,
            started_micros: Some(1_000_000),
            linux_birth: birth(400),
        };
        let mut reads = 0;
        let proof = walk_ancestry(caller, |pid| {
            reads += 1;
            let (ticks, parent) = match pid {
                40 => (400, 30),
                30 => (300, 1),
                _ => unreachable!(),
            };
            Ok(Some(ProcessLink {
                started_micros: Some(2_000_000 + reads),
                linux_birth: birth(ticks),
                parent_pid: parent,
            }))
        })
        .collect::<Result<Vec<_>>>()
        .unwrap();
        assert_eq!(proof.iter().map(|p| p.pid).collect::<Vec<_>>(), [40, 30]);
        let changed_ticks = ProcessInstance {
            linux_birth: birth(401),
            ..caller
        };
        assert!(
            walk_ancestry(changed_ticks, |pid| Ok(Some(ProcessLink {
                started_micros: None,
                linux_birth: birth(400),
                parent_pid: pid - 1
            })))
            .next()
            .unwrap()
            .is_err()
        );
        let mut changed_boot = birth(400);
        changed_boot.boot_id[0] = b'1';
        assert!(
            walk_ancestry(
                ProcessInstance {
                    linux_birth: changed_boot,
                    ..caller
                },
                |_| Ok(Some(ProcessLink {
                    started_micros: None,
                    linux_birth: birth(400),
                    parent_pid: 1
                }))
            )
            .next()
            .unwrap()
            .is_err()
        );
    }

    #[tokio::test]
    async fn socket_caller_is_the_actual_kernel_peer() {
        let (client, server) = tokio::net::UnixStream::pair().unwrap();
        let identity = super::super::unix_peer_instance(&server).unwrap();
        assert_eq!(identity.pid as u32, std::process::id());
        assert_eq!(Some(identity), identify_instance(identity.pid).unwrap());
        assert_eq!(identity.started_micros, None);
        drop(client);
    }
}
