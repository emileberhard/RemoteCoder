use crate::config::HostPaths;
use crate::storage::private_state;
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Owner {
    pid: u32,
    birth: String,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Claim {
    stage_id: u32,
    parent: Owner,
    worker: Option<Owner>,
}

fn owner(pid: u32) -> Result<Option<Owner>> {
    let pid = i32::try_from(pid)?;
    ensure!(pid > 0, "Invalid staging owner PID");
    match nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None) {
        Err(nix::errno::Errno::ESRCH) => return Ok(None),
        Err(error) => return Err(error.into()),
        Ok(()) => {}
    }
    let output = std::process::Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "pid=,lstart=,comm="])
        .env("LC_ALL", "C")
        .env("TZ", "UTC")
        .output()?;
    ensure!(
        output.status.success() && output.stdout.len() <= 4096,
        "Staging process identity is unavailable"
    );
    let text = String::from_utf8(output.stdout)?;
    let birth = text
        .split_whitespace()
        .skip(1)
        .take(5)
        .collect::<Vec<_>>()
        .join(" ");
    ensure!(!birth.is_empty(), "Staging process identity is unknown");
    Ok(Some(Owner {
        pid: u32::try_from(pid)?,
        birth,
    }))
}

fn live(value: &Owner) -> Result<bool> {
    Ok(owner(value.pid)?.is_some_and(|owner| owner.birth == value.birth))
}

fn paths(paths: &HostPaths, stage_id: u32) -> Vec<PathBuf> {
    let bin = super::pair::directory(paths);
    let agents = paths.home().join("Library/LaunchAgents");
    [
        super::bundle::NAME,
        "remote-coder-codex-gateway",
        "launch-codex-gateway",
        "launch-chatgpt-with-shared-codex",
    ]
    .into_iter()
    .map(|name| bin.join(format!("{name}.new.{stage_id}")))
    .chain(
        [
            "com.remote-coder.codex-gateway.plist",
            "com.remote-coder.chatgpt-shared-codex.plist",
        ]
        .into_iter()
        .map(|name| agents.join(format!("{name}.new.{stage_id}"))),
    )
    .collect()
}

fn remove(paths: &HostPaths, stage_id: u32) -> Result<()> {
    for path in self::paths(paths, stage_id) {
        super::package::remove_path(&path)?;
    }
    Ok(())
}

fn transaction<T>(
    paths: &HostPaths,
    operation: impl FnOnce(&mut Option<Claim>) -> Result<T>,
) -> Result<T> {
    private_state::transaction(
        &paths.state("gateway-staging.json"),
        "Staging state has no parent",
        |path| {
            let bytes = private_state::read_bounded(path, 4096)
                .map_err(|error| anyhow::anyhow!("Cannot read staging owner: {error:?}"))?;
            Ok(match bytes {
                Some(bytes) => serde_json::from_slice(&bytes)?,
                None => None,
            })
        },
        |claim| Ok((operation(claim)?, true)),
        private_state::write_json,
    )
}

pub(crate) fn prepare(paths: &HostPaths, stage_id: u32, parent: u32) -> Result<()> {
    transaction(paths, |claim| {
        if let Some(prior) = claim {
            ensure!(
                !live(&prior.parent)? && prior.worker.as_ref().map(live).transpose()? != Some(true),
                "Another live process owns gateway staging"
            );
            remove(paths, prior.stage_id)?;
        }
        let mut ids = std::collections::BTreeSet::new();
        for directory in [
            super::pair::directory(paths),
            paths.home().join("Library/LaunchAgents"),
        ] {
            if !directory.exists() {
                continue;
            }
            for entry in std::fs::read_dir(directory)? {
                let name = entry?.file_name().to_string_lossy().into_owned();
                if let Some((prefix, id)) = name.rsplit_once(".new.")
                    && [
                        super::bundle::NAME,
                        "remote-coder-codex-gateway",
                        "launch-codex-gateway",
                        "launch-chatgpt-with-shared-codex",
                        "com.remote-coder.codex-gateway.plist",
                        "com.remote-coder.chatgpt-shared-codex.plist",
                    ]
                    .contains(&prefix)
                {
                    ids.insert(id.parse::<u32>()?);
                    ensure!(
                        ids.len() <= 64,
                        "Gateway staging exceeds reclamation capacity"
                    );
                }
            }
        }
        let processes = if ids.is_empty() {
            String::new()
        } else {
            let output = std::process::Command::new("ps")
                .args(["-axo", "pid=,lstart=,comm="])
                .output()?;
            ensure!(
                output.status.success() && output.stdout.len() <= 1024 * 1024,
                "Staging process scan is unavailable"
            );
            String::from_utf8(output.stdout)?
        };
        for id in ids {
            for staged in self::paths(paths, id) {
                ensure!(
                    !processes.lines().any(|line| {
                        let command = line.trim_end();
                        command.ends_with(staged.to_string_lossy().as_ref())
                            || command.ends_with(
                                super::bundle::executable(&staged)
                                    .to_string_lossy()
                                    .as_ref(),
                            )
                    }),
                    "A live process still uses orphaned gateway staging"
                );
            }
            ensure!(
                owner(id)?.is_none(),
                "Unclaimed staging has a live or reused owner PID"
            );
            remove(paths, id)?;
        }
        *claim = Some(Claim {
            stage_id,
            parent: owner(parent)?.context("Staging parent exited")?,
            worker: None,
        });
        Ok(())
    })
}

pub(crate) fn adopt(paths: &HostPaths, stage_id: u32) -> Result<()> {
    transaction(paths, |claim| {
        let claim = claim.as_mut().context("Gateway staging was not claimed")?;
        ensure!(
            claim.stage_id == stage_id
                && claim.parent.pid == u32::try_from(nix::unistd::getppid().as_raw())?
                && live(&claim.parent)?,
            "Gateway staging owner changed"
        );
        claim.worker = owner(std::process::id())?;
        Ok(())
    })
}

pub(crate) fn clear(paths: &HostPaths, stage_id: u32, parent: u32) -> Result<()> {
    transaction(paths, |claim| {
        if let Some(value) = claim {
            ensure!(
                value.stage_id == stage_id && value.parent.pid == parent && live(&value.parent)?,
                "Gateway staging cleanup owner changed"
            );
            ensure!(
                value.worker.as_ref().map(live).transpose()? != Some(true),
                "Gateway staging worker has not exited"
            );
            remove(paths, stage_id)?;
            *claim = None;
        }
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, Read};
    use std::process::{Child, Command, Stdio};

    struct Worker(Child);
    impl Drop for Worker {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    fn write_stage(path: &std::path::Path, value: &[u8]) {
        if path
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with(super::super::bundle::NAME)
        {
            let binary = super::super::bundle::executable(path);
            std::fs::create_dir_all(binary.parent().unwrap()).unwrap();
            std::fs::write(binary, value).unwrap();
        } else {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, value).unwrap();
        }
    }

    #[test]
    fn staging_owner_child() {
        let Ok(home) = std::env::var("RC_STAGE_FIXTURE_HOME") else {
            return;
        };
        let home = HostPaths::from_home(home.into()).unwrap();
        let id = std::process::id();
        prepare(&home, id, id).unwrap();
        for file in paths(&home, id) {
            write_stage(&file, b"old staging without a version command");
        }
        println!("STAGE_READY");
        std::io::stdin().read_exact(&mut [0_u8]).unwrap();
    }

    #[test]
    fn dead_staging_owner_is_reclaimed_and_failure_cleanup_removes_only_its_stage() {
        let home = tempfile::tempdir().unwrap();
        let host = HostPaths::from_home(home.path().to_owned()).unwrap();
        let mut child = Worker(
            Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "runtime::install::staging::tests::staging_owner_child",
                    "--nocapture",
                ])
                .env("RC_STAGE_FIXTURE_HOME", home.path())
                .env("TZ", "UTC")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .unwrap(),
        );
        let output = child.0.stdout.take().unwrap();
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        let reader = std::thread::spawn(move || {
            for line in std::io::BufReader::new(output).lines() {
                if line.unwrap() == "STAGE_READY" {
                    sender.send(()).unwrap();
                    return;
                }
            }
        });
        receiver
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
        let old_id = child.0.id();
        assert!(prepare(&host, std::process::id(), std::process::id()).is_err());
        assert!(paths(&host, old_id).iter().all(|path| path.exists()));
        child.0.kill().unwrap();
        child.0.wait().unwrap();
        reader.join().unwrap();
        prepare(&host, std::process::id(), std::process::id()).unwrap();
        assert!(paths(&host, old_id).iter().all(|path| !path.exists()));
        let installed = super::super::pair::directory(&host).join("remote-coder-codex-gateway");
        std::fs::write(&installed, b"active gateway").unwrap();
        for file in paths(&host, std::process::id()) {
            write_stage(&file, b"failed stage");
        }
        clear(&host, std::process::id(), std::process::id()).unwrap();
        assert!(
            paths(&host, std::process::id())
                .iter()
                .all(|path| !path.exists())
        );
        assert_eq!(std::fs::read(installed).unwrap(), b"active gateway");
        for file in paths(&host, old_id) {
            write_stage(&file, b"unclaimed legacy staging");
        }
        prepare(&host, std::process::id(), std::process::id()).unwrap();
        assert!(paths(&host, old_id).iter().all(|path| !path.exists()));
        clear(&host, std::process::id(), std::process::id()).unwrap();
    }
}
