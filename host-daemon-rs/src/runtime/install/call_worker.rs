use crate::config::HostPaths;
use crate::gateway::calls::CallDeliveryConfig;
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::Value;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

const INSTALLER: &str = include_str!("../../../../agent-calls/agent_calls/worker_artifact.py");

#[derive(Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Installed {
    worker_hash: String,
    worker_path: String,
    identity: Value,
    protocol_version: u32,
    reservation: String,
}

#[derive(Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Reservation {
    host: String,
    origin: String,
    generation: String,
    source_hash: Option<String>,
    target_hash: String,
}

pub(crate) struct Lease(std::fs::File);

impl Lease {
    pub(crate) fn try_acquire(paths: &HostPaths) -> Result<Option<Self>> {
        use std::os::unix::fs::OpenOptionsExt;
        crate::storage::private_state::ensure_private_directory(&paths.state_directory())?;
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOFOLLOW)
            .mode(0o600)
            .open(paths.state("gateway-installation.lock"))?;
        match file.try_lock() {
            Ok(()) => Ok(Some(Self(file))),
            Err(std::fs::TryLockError::WouldBlock) => Ok(None),
            Err(std::fs::TryLockError::Error(error)) => Err(error.into()),
        }
    }

    pub(crate) fn acquire(paths: &HostPaths) -> Result<Self> {
        Self::try_acquire(paths)?.context("Another gateway installation owns this host")
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

pub(crate) async fn settle(paths: &HostPaths) -> Result<()> {
    let path = paths.state("worker-activation.json");
    let Some(bytes) = crate::storage::private_state::read_bounded(&path, 4096)
        .map_err(|error| anyhow::anyhow!("Cannot read worker activation: {error:?}"))?
    else {
        return Ok(());
    };
    let reservation: Reservation = serde_json::from_slice(&bytes)?;
    let selected = super::pair::selected_worker(paths)?;
    ensure!(
        selected.as_ref() == Some(&reservation.target_hash) || selected == reservation.source_hash,
        "Worker activation does not match the selected gateway pair"
    );
    install_on(&reservation.host, &serde_json::to_vec(&serde_json::json!({
        "operation": "finish", "originHost": reservation.origin, "reservation": reservation.generation,
        "selectedHash": selected, "sourceHash": reservation.source_hash, "targetHash": reservation.target_hash,
    }))?).await?;
    std::fs::remove_file(path)?;
    std::fs::File::open(paths.state_directory())?.sync_all()?;
    Ok(())
}

pub(crate) async fn stage(
    paths: &HostPaths,
    worker_host: Option<&str>,
) -> Result<(Option<CallDeliveryConfig>, Installed)> {
    if let Some(host) = worker_host {
        CallDeliveryConfig::validate_worker_host(host)?;
    }
    settle(paths).await?;
    let config = CallDeliveryConfig::read_for_install(paths)?;
    let source_hash = super::pair::selected_worker(paths)?;
    let mut bundle = crate::call_worker::bundle(source_hash.as_deref())?;
    let origin = nix::unistd::gethostname()?
        .to_string_lossy()
        .split('.')
        .next()
        .context("Origin hostname is unavailable")?
        .to_owned();
    bundle["originHost"] = Value::String(origin.clone());
    let generation = crate::ids::new_session_uuid();
    bundle["reservation"] = Value::String(generation.clone());
    let worker_host = worker_host.unwrap_or_else(|| {
        config
            .as_ref()
            .map_or("localhost", CallDeliveryConfig::worker_host)
    });
    let reservation = Reservation {
        host: worker_host.to_owned(),
        origin,
        generation: generation.clone(),
        source_hash: super::pair::selected_worker(paths)?,
        target_hash: crate::build_identity::IDENTITY.worker_hash.to_owned(),
    };
    crate::storage::private_state::write_json(
        &paths.state("worker-activation.json"),
        &reservation,
    )?;
    let output = install_on(worker_host, &serde_json::to_vec(&bundle)?).await?;
    let installed: Installed = serde_json::from_slice(&output)
        .context("Installed worker readback is not the expected contract")?;
    ensure!(
        installed.worker_hash == crate::build_identity::IDENTITY.worker_hash
            && installed.identity == bundle["identity"]
            && installed.protocol_version == 1
            && installed.reservation == generation,
        "Installed worker hash or protocol does not match the gateway"
    );
    Ok((config, installed))
}

pub(super) async fn prepare(paths: &HostPaths) -> Result<Option<Vec<u8>>> {
    let (config, installed) = stage(paths, None).await?;
    let Some(config) = config else {
        return Ok(None);
    };
    let config = config.select_worker(installed.worker_path)?;
    Ok(Some(serde_json::to_vec_pretty(&config)?))
}

pub(crate) async fn confirm_current(paths: &HostPaths) -> Result<()> {
    let path = paths.state("worker-activation.json");
    let Some(bytes) = crate::storage::private_state::read_bounded(&path, 4096)
        .map_err(|error| anyhow::anyhow!("Cannot read worker activation: {error:?}"))?
    else {
        return Ok(());
    };
    let reservation: Reservation = serde_json::from_slice(&bytes)?;
    install_on(&reservation.host, &serde_json::to_vec(&serde_json::json!({
        "operation": "finish", "originHost": reservation.origin, "reservation": reservation.generation,
        "selectedHash": crate::build_identity::IDENTITY.worker_hash,
        "sourceHash": reservation.source_hash, "targetHash": reservation.target_hash,
    }))?).await?;
    std::fs::remove_file(path)?;
    std::fs::File::open(paths.state_directory())?.sync_all()?;
    Ok(())
}

async fn install_on(host: &str, input: &[u8]) -> Result<Vec<u8>> {
    let local = matches!(host, "localhost" | "127.0.0.1")
        || nix::unistd::gethostname()?
            .to_string_lossy()
            .split('.')
            .next()
            == Some(host);
    let mut command = if local {
        let mut command = Command::new("python3");
        command.args(["-I", "-c", INSTALLER]);
        command
    } else {
        let mut command = Command::new("/usr/bin/ssh");
        command.args(["-T", "-oBatchMode=yes", "-oConnectTimeout=10", host]);
        command.arg(format!(
            "python3 -I -c '{}'",
            INSTALLER.replace('\'', "'\\''")
        ));
        command
    };
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .context("Starting pinned telephone worker installation")?;
    let (result, write_result) = tokio::time::timeout(Duration::from_secs(600), async move {
        let write_result = {
            let mut input_pipe = child
                .stdin
                .take()
                .context("Worker installer stdin unavailable")?;
            input_pipe.write_all(input).await
        };
        let output = child.wait_with_output().await?;
        Ok::<_, anyhow::Error>((output, write_result))
    })
    .await
    .context("Worker installation timed out before gateway activation")??;
    ensure!(
        result.status.success(),
        "Worker installation failed before gateway activation: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    write_result.context("Delivering the complete worker artifact to the installer")?;
    ensure!(
        result.stdout.len() <= 65536,
        "Worker installation readback exceeds its capacity"
    );
    Ok(result.stdout)
}
