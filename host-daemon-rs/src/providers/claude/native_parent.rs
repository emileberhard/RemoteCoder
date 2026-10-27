use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use tokio::net::UnixStream;

use crate::ids::is_session_uuid;
use crate::platform::process::{identify, unix_peer_identity};
use crate::providers::claude::records::read_record;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct NativeSessionOwner {
    pub pid: i32,
    pub started_micros: u64,
    pub session_uuid: String,
    pub cwd: PathBuf,
    pub socket_path: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OwnerRecord {
    pid: i32,
    session_id: String,
    cwd: PathBuf,
    messaging_socket_path: Option<PathBuf>,
    pid_domain: String,
    proc_start: String,
}

pub(crate) async fn prove_owner(
    claude_home: &Path,
    pid: i32,
    started_micros: u64,
) -> Result<Option<NativeSessionOwner>> {
    let home = claude_home.to_owned();
    let candidate =
        tokio::task::spawn_blocking(move || read_owner(&home, pid, started_micros)).await??;
    let Some(owner) = candidate else {
        return Ok(None);
    };
    let stream = tokio::time::timeout(
        Duration::from_secs(3),
        UnixStream::connect(&owner.socket_path),
    )
    .await
    .context("Claude's recorded native socket did not connect within 3 seconds")??;
    let (peer_pid, identity) = unix_peer_identity(&stream)?;
    ensure!(
        peer_pid == pid && identity.started_micros == started_micros,
        "Claude's recorded native socket belongs to a different process instance"
    );
    drop(stream);
    let home = claude_home.to_owned();
    let current =
        tokio::task::spawn_blocking(move || read_owner(&home, pid, started_micros)).await??;
    ensure!(
        current.as_ref() == Some(&owner),
        "Claude's native session ownership changed while being verified"
    );
    Ok(Some(owner))
}

fn read_owner(home: &Path, pid: i32, started_micros: u64) -> Result<Option<NativeSessionOwner>> {
    ensure!(pid > 0, "Claude process identity is invalid");
    let Some(identity) = identify(pid)? else {
        return Ok(None);
    };
    if identity.started_micros != started_micros {
        return Ok(None);
    }
    let path = home.join("sessions").join(format!("{pid}.json"));
    let Some(bytes) = read_record(&path, 64 * 1024)? else {
        return Ok(None);
    };
    let record: OwnerRecord =
        serde_json::from_slice(&bytes).context("Claude native session owner record is invalid")?;
    ensure!(
        record.pid == pid && record.pid_domain == "darwin",
        "Claude native session owner has an incompatible process identity"
    );
    ensure!(
        is_session_uuid(&record.session_id),
        "Claude native session owner has an invalid session UUID"
    );
    let format = time::format_description::parse_owned::<3>(
        "[weekday repr:short] [month repr:short] [day padding:space] [hour]:[minute]:[second] [year]",
    )?;
    let started =
        time::OffsetDateTime::from_unix_timestamp(i64::try_from(started_micros / 1_000_000)?)?
            .format(&format)?;
    if record.proc_start != started {
        return Ok(None);
    }
    let socket_path = record
        .messaging_socket_path
        .context("Claude native session has no inbox socket")?;
    ensure!(
        socket_path.is_absolute(),
        "Claude native inbox path is not absolute"
    );
    let metadata = std::fs::symlink_metadata(&socket_path)
        .context("Claude native inbox metadata is unavailable")?;
    ensure!(
        metadata.file_type().is_socket() && metadata.uid() == nix::unistd::Uid::current().as_raw(),
        "Claude native inbox is not a socket owned by this user"
    );
    Ok(Some(NativeSessionOwner {
        pid,
        started_micros,
        session_uuid: record.session_id,
        cwd: record.cwd,
        socket_path,
    }))
}
