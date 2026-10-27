use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, UNIX_EPOCH};

use anyhow::{Context, Result, anyhow};
use nix::errno::Errno;
use nix::sys::socket::getsockopt;
#[cfg(not(target_os = "macos"))]
use nix::unistd::Pid;
use serde::Deserialize;
use tokio::net::UnixStream;
use tokio::process::Command;
use tokio::sync::RwLock;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::{WebSocketStream, client_async_with_config};
use tracing::info;

use crate::config::REQUIRED_CODEX_VERSION;

use super::package;

pub(crate) const MAX_WEBSOCKET_BYTES: usize = 32 * 1024 * 1024;

pub(crate) fn websocket_config() -> WebSocketConfig {
    WebSocketConfig {
        max_message_size: Some(MAX_WEBSOCKET_BYTES),
        max_frame_size: Some(MAX_WEBSOCKET_BYTES),
        ..WebSocketConfig::default()
    }
}

const STARTUP_TIMEOUT: Duration = Duration::from_secs(60);
const STOP_TIMEOUT: Duration = Duration::from_secs(90);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);

pub(crate) type CodexWebSocket = WebSocketStream<UnixStream>;

#[derive(Debug, Clone)]
pub(crate) struct CodexAppServerInfo {
    pub pid: i32,
    pub started_at_unix_seconds: f64,
    pub socket_path: PathBuf,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LifecycleOutput {
    pub(crate) backend: Option<String>,
    pub(crate) pid: Option<u32>,
    pub(crate) managed_codex_version: Option<String>,
    pub(crate) managed_codex_path: Option<PathBuf>,
    pub(crate) app_server_version: Option<String>,
    pub(crate) socket_path: PathBuf,
}

#[derive(Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
struct PidRecord {
    pid: u32,
    #[serde(alias = "linuxProcessIdentity")]
    process_identity: ProcessIdentity,
    executable_identity: Option<ExecutableIdentity>,
}

#[derive(Debug, serde::Serialize, Deserialize, Eq, PartialEq)]
#[serde(untagged, rename_all_fields = "camelCase")]
enum ProcessIdentity {
    Linux {
        boot_id: String,
        start_ticks: u64,
    },
    MacOsUnique {
        boot_id: String,
        unique_id: u64,
        start_seconds: u64,
        start_microseconds: u64,
    },
}

#[derive(Debug, Deserialize, Eq, PartialEq)]
struct ExecutableIdentity {
    digest: [u8; 32],
}

pub(crate) struct CodexAppServer {
    codex_path: PathBuf,
    expected_version: String,
    child_env: HashMap<String, String>,
    isolated_environment: bool,
    socket_path: PathBuf,
    pid_file: PathBuf,
    info: RwLock<Option<CodexAppServerInfo>>,
    #[cfg(test)]
    expected_pid_override: Option<i32>,
}

impl CodexAppServer {
    pub fn new(codex_path: PathBuf, child_env: HashMap<String, String>) -> Self {
        let codex_home = child_env
            .get("CODEX_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("CODEX_HOME").map(PathBuf::from))
            .or_else(|| {
                crate::config::HostPaths::from_env()
                    .ok()
                    .map(|paths| paths.home().join(".codex"))
            })
            .expect("HOME or CODEX_HOME must be set for the shared Codex daemon");
        Self::with_codex_home(codex_path, child_env, codex_home)
    }

    fn with_codex_home(
        codex_path: PathBuf,
        child_env: HashMap<String, String>,
        codex_home: PathBuf,
    ) -> Self {
        Self {
            codex_path,
            expected_version: REQUIRED_CODEX_VERSION.to_owned(),
            child_env,
            isolated_environment: false,
            socket_path: codex_home
                .join("app-server-control")
                .join("app-server-control.sock"),
            pid_file: codex_home.join("app-server-daemon").join("app-server.pid"),
            info: RwLock::new(None),
            #[cfg(test)]
            expected_pid_override: None,
        }
    }

    #[cfg(test)]
    pub(crate) fn new_for_test_socket(codex_home: PathBuf) -> Self {
        let mut app_server =
            Self::with_codex_home(PathBuf::from("/bin/true"), HashMap::new(), codex_home);
        app_server.expected_pid_override =
            Some(i32::try_from(std::process::id()).expect("test process id must fit in i32"));
        app_server
    }

    pub(crate) fn for_runtime(
        codex_path: PathBuf,
        child_env: HashMap<String, String>,
    ) -> Result<Self> {
        let identity = crate::runtime::identity::PackageIdentity::read(&codex_path)?;
        let mut server = Self::new(codex_path, child_env);
        server.expected_version = identity.version;
        Ok(server)
    }

    pub(crate) fn isolated_for_runtime(
        codex_path: PathBuf,
        child_env: HashMap<String, String>,
    ) -> Result<Self> {
        let mut server = Self::for_runtime(codex_path, child_env)?;
        server.isolated_environment = true;
        Ok(server)
    }

    pub(crate) fn expected_version(&self) -> &str {
        &self.expected_version
    }

    pub(crate) fn executable_path(&self) -> &Path {
        &self.codex_path
    }

    pub(crate) fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    pub(crate) fn provider_home(&self) -> Result<&Path> {
        self.pid_file
            .parent()
            .and_then(Path::parent)
            .context("Codex daemon state has no provider home")
    }

    pub(crate) fn child_environment(&self) -> &HashMap<String, String> {
        &self.child_env
    }

    pub(crate) fn prepare_selected_package(&self) -> Result<()> {
        let parent = self
            .codex_path
            .parent()
            .context("Codex executable has no parent")?;
        let approved = if parent.file_name().is_some_and(|name| name == "bin") {
            parent.parent().context("Codex package has no root")?
        } else {
            parent
        };
        let codex_home = self
            .pid_file
            .parent()
            .and_then(Path::parent)
            .context("Codex daemon state has no home")?;
        package::prepare(codex_home, approved)
    }

    pub(crate) async fn info(&self) -> Result<CodexAppServerInfo> {
        let expected_pid = self.verified_lifecycle_pid().await?;
        if let Some(info) = self.info.read().await.clone()
            && info.pid == expected_pid
        {
            match process_exists(info.pid) {
                ProcessState::Running => return Ok(info),
                ProcessState::Exited => {}
                ProcessState::Unknown(error) => {
                    return Err(error).context("Codex process state is unknown");
                }
            }
        }
        self.refresh_info_for_pid(expected_pid).await
    }

    pub(crate) async fn verify_ready(&self) -> Result<()> {
        let expected_pid = self.verified_lifecycle_pid().await?;
        let mut websocket = self.connect_ws_to_pid(expected_pid).await?;
        websocket.close(None).await.ok();
        let info = self.refresh_info_for_pid(expected_pid).await?;
        info!(
            pid = info.pid,
            socket_path = %info.socket_path.display(),
            "verified existing Codex app-server daemon"
        );
        Ok(())
    }

    pub(crate) async fn connect_ws(&self) -> Result<CodexWebSocket> {
        let expected_pid = self.verified_lifecycle_pid().await?;
        self.connect_ws_to_pid(expected_pid).await
    }

    async fn connect_ws_to_pid(&self, expected_pid: i32) -> Result<CodexWebSocket> {
        let stream = tokio::time::timeout(CONNECT_TIMEOUT, UnixStream::connect(&self.socket_path))
            .await
            .with_context(|| {
                format!(
                    "timed out connecting to Codex socket {}",
                    self.socket_path.display()
                )
            })?
            .with_context(|| {
                format!(
                    "failed to connect to Codex socket {}",
                    self.socket_path.display()
                )
            })?;
        let peer_pid = unix_peer_pid(&stream)?;
        if peer_pid != expected_pid {
            return Err(anyhow!(
                "Codex socket peer pid {peer_pid} does not match managed daemon pid {expected_pid}"
            ));
        }
        let (websocket, _) = tokio::time::timeout(
            CONNECT_TIMEOUT,
            client_async_with_config("ws://localhost/", stream, Some(websocket_config())),
        )
        .await
        .context("Codex WebSocket upgrade timed out")?
        .context("Codex WebSocket upgrade failed")?;
        Ok(websocket)
    }

    pub(crate) async fn verify_identity(&self) -> Result<()> {
        self.verified_lifecycle_pid().await.map(|_| ())
    }

    pub(crate) async fn verify_package_provenance(&self) -> Result<()> {
        let output = self.run_lifecycle("version").await?;
        self.validate_lifecycle(&output)?;
        let selected = output
            .managed_codex_path
            .as_ref()
            .context("Codex daemon lifecycle omitted its managed executable path")?;
        if tokio::fs::canonicalize(selected).await?
            != tokio::fs::canonicalize(&self.codex_path).await?
        {
            return Err(anyhow!("Codex daemon selected a different runtime package"));
        }
        let expected_pid = output
            .pid
            .context("Codex daemon lifecycle omitted its managed pid")?;
        let (pid_path, record) = self
            .live_pid_record()
            .await?
            .context("Codex daemon has no live managed pid record")?;
        if record.pid != expected_pid {
            return Err(anyhow!(
                "Codex daemon record differs from its verified lifecycle pid"
            ));
        }
        let running = record
            .executable_identity
            .as_ref()
            .context("Codex daemon record omitted its running executable identity")?
            .digest;
        let codex_path = self.codex_path.clone();
        let expected = tokio::task::spawn_blocking(move || {
            let file = std::fs::File::open(&codex_path).with_context(|| {
                format!("opening managed Codex executable {}", codex_path.display())
            })?;
            let mut hasher = blake3::Hasher::new();
            hasher
                .update_reader(file)
                .context("hashing managed Codex executable")?;
            Ok::<_, anyhow::Error>(*hasher.finalize().as_bytes())
        })
        .await
        .context("Codex executable identity task failed")??;
        if running != expected {
            return Err(anyhow!(
                "running Codex executable does not match the selected runtime package"
            ));
        }
        let expected_pid = i32::try_from(expected_pid).context("Codex daemon pid exceeds i32")?;
        let mut websocket = self.connect_ws_to_pid(expected_pid).await?;
        websocket.close(None).await.ok();
        let current = self
            .live_pid_record()
            .await?
            .context("Codex daemon lost its managed pid record")?;
        if current != (pid_path, record) {
            return Err(anyhow!(
                "Codex daemon changed during package provenance verification"
            ));
        }
        Ok(())
    }

    pub(crate) async fn probe_ready_info(&self) -> Result<CodexAppServerInfo> {
        let (mut websocket, expected_pid) = self.connect_ws_to_recorded_pid().await?;
        websocket.close(None).await.ok();
        self.refresh_info_for_pid(expected_pid).await
    }

    async fn connect_ws_to_recorded_pid(&self) -> Result<(CodexWebSocket, i32)> {
        let expected_pid = self.pid_file_pid().await?;
        let websocket = self.connect_ws_to_pid(expected_pid).await?;
        let current_pid = self.pid_file_pid().await?;
        if current_pid != expected_pid {
            return Err(anyhow!(
                "Codex pid record changed from {expected_pid} to {current_pid} during readiness probe"
            ));
        }
        Ok((websocket, expected_pid))
    }

    pub(crate) async fn run_lifecycle(&self, action: &str) -> Result<LifecycleOutput> {
        self.run_lifecycle_with_env(action, &[]).await
    }

    pub(crate) async fn run_lifecycle_with_env(
        &self,
        action: &str,
        extra_env: &[(&str, &std::ffi::OsStr)],
    ) -> Result<LifecycleOutput> {
        self.run_lifecycle_with_env_and_timeout(action, extra_env, STARTUP_TIMEOUT)
            .await
    }

    pub(crate) async fn stop(&self) -> Result<LifecycleOutput> {
        self.run_lifecycle_with_env_and_timeout("stop", &[], STOP_TIMEOUT)
            .await
    }

    async fn run_lifecycle_with_env_and_timeout(
        &self,
        action: &str,
        extra_env: &[(&str, &std::ffi::OsStr)],
        timeout: Duration,
    ) -> Result<LifecycleOutput> {
        let mut command = Command::new(&self.codex_path);
        #[cfg(target_os = "macos")]
        crate::platform::macos::scheduling::prepare_agent_command(&mut command);
        command
            .args(["app-server", "daemon", action])
            .stdin(Stdio::null())
            .stderr(Stdio::piped())
            .stdout(Stdio::piped())
            .kill_on_drop(true);
        if self.isolated_environment {
            command.env_clear();
            command.args([
                "-c",
                "forced_login_method=\"chatgpt\"",
                "-c",
                "cli_auth_credentials_store=\"file\"",
                "-c",
                "model_provider=\"openai\"",
            ]);
        }
        for (key, value) in &self.child_env {
            command.env(key, value);
        }
        for (key, value) in extra_env {
            command.env(key, value);
        }

        let output = tokio::time::timeout(timeout, command.output())
            .await
            .with_context(|| format!("Codex daemon {action} timed out"))?
            .with_context(|| format!("failed to run Codex daemon {action}"))?;
        if !output.status.success() {
            return Err(anyhow!(
                "Codex daemon {action} failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        serde_json::from_slice(&output.stdout)
            .with_context(|| format!("Codex daemon {action} returned invalid JSON"))
    }

    pub(crate) async fn set_remote_control_enabled(&self, enabled: bool) -> Result<()> {
        self.run_lifecycle(if enabled {
            "enable-remote-control"
        } else {
            "disable-remote-control"
        })
        .await
        .map(|_| ())
    }

    async fn verified_lifecycle_pid(&self) -> Result<i32> {
        #[cfg(test)]
        if let Some(pid) = self.expected_pid_override {
            return Ok(pid);
        }
        let output = self.run_lifecycle("version").await?;
        self.validate_lifecycle(&output)?;
        let pid = output
            .pid
            .context("Codex daemon lifecycle omitted its managed pid")?;
        i32::try_from(pid).context("Codex daemon pid exceeds i32")
    }

    fn validate_lifecycle(&self, output: &LifecycleOutput) -> Result<()> {
        if output.socket_path != self.socket_path {
            return Err(anyhow!(
                "Codex daemon reported unexpected socket {} (expected {})",
                output.socket_path.display(),
                self.socket_path.display()
            ));
        }
        if output.backend.as_deref() != Some("pid") {
            return Err(anyhow!(
                "Codex daemon reported an unverified app-server owner ({})",
                output.backend.as_deref().unwrap_or("missing backend")
            ));
        }
        for (label, version) in [
            ("managed Codex", output.managed_codex_version.as_deref()),
            ("app-server", output.app_server_version.as_deref()),
        ] {
            if version != Some(self.expected_version.as_str()) {
                return Err(anyhow!(
                    "{label} version {} does not match required {}",
                    version.unwrap_or("<missing>"),
                    self.expected_version
                ));
            }
        }
        Ok(())
    }

    async fn refresh_info_for_pid(&self, expected_pid: i32) -> Result<CodexAppServerInfo> {
        let (pid_path, record) = self
            .live_pid_record()
            .await?
            .context("Codex daemon has no live managed pid record")?;
        let pid = i32::try_from(record.pid).context("Codex daemon pid exceeds i32")?;
        if pid != expected_pid {
            return Err(anyhow!(
                "Codex pid record {pid} does not match managed daemon pid {expected_pid}"
            ));
        }
        match process_exists(pid) {
            ProcessState::Running => {}
            ProcessState::Exited => return Err(anyhow!("Codex daemon pid {pid} is not running")),
            ProcessState::Unknown(error) => {
                return Err(error).context("Codex process state is unknown");
            }
        }
        let started_at_unix_seconds = tokio::fs::metadata(&pid_path)
            .await
            .with_context(|| {
                format!(
                    "failed to read Codex pid record metadata at {}",
                    pid_path.display()
                )
            })?
            .modified()
            .context("Codex pid record has no modification time")?
            .duration_since(UNIX_EPOCH)
            .context("Codex pid record modification time predates the Unix epoch")?
            .as_secs_f64();
        let info = CodexAppServerInfo {
            pid,
            started_at_unix_seconds,
            socket_path: self.socket_path.clone(),
        };
        *self.info.write().await = Some(info.clone());
        Ok(info)
    }

    pub(crate) async fn recorded_daemon_is_live(&self) -> Result<bool> {
        Ok(self.live_pid_record().await?.is_some())
    }

    async fn pid_file_pid(&self) -> Result<i32> {
        let (_, record) = self
            .live_pid_record()
            .await?
            .context("Codex daemon has no live managed pid record")?;
        i32::try_from(record.pid).context("Codex daemon pid exceeds i32")
    }

    async fn live_pid_record(&self) -> Result<Option<(PathBuf, PidRecord)>> {
        let mut live = None;
        for path in [&self.pid_file, &self.pid_file.with_file_name("daemon.pid")] {
            let bytes = match tokio::fs::read(path).await {
                Ok(bytes) => bytes,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("failed to read {}", path.display()));
                }
            };
            let record: PidRecord = serde_json::from_slice(&bytes)
                .with_context(|| format!("failed to parse {}", path.display()))?;
            if !pid_record_matches_process(&record).await? {
                continue;
            }
            if live.is_some() {
                return Err(anyhow!(
                    "multiple live Codex daemon pid records claim this home"
                ));
            }
            live = Some((path.clone(), record));
        }
        Ok(live)
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn unix_peer_pid(stream: &UnixStream) -> Result<i32> {
    getsockopt(stream, nix::sys::socket::sockopt::LocalPeerPid)
        .context("failed to read Codex Unix socket peer pid")
}

#[cfg(target_os = "linux")]
pub(crate) fn unix_peer_pid(stream: &UnixStream) -> Result<i32> {
    Ok(
        getsockopt(stream, nix::sys::socket::sockopt::PeerCredentials)
            .context("failed to read Codex Unix socket peer credentials")?
            .pid(),
    )
}

#[cfg(target_os = "macos")]
fn process_exists(pid: i32) -> ProcessState {
    if pid <= 0 {
        return ProcessState::Exited;
    }
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::uninit();
    let expected_size = std::mem::size_of::<libc::proc_bsdinfo>();
    // SAFETY: proc_pidinfo receives a correctly sized writable proc_bsdinfo
    // buffer and initializes it only when it returns that exact byte count.
    let written = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            1,
            info.as_mut_ptr().cast(),
            i32::try_from(expected_size).unwrap_or(i32::MAX),
        )
    };
    if usize::try_from(written).ok() != Some(expected_size) {
        return missing_process_info_state(Errno::last(), written, pid);
    }
    // SAFETY: the exact-size return above guarantees full initialization.
    if unsafe { info.assume_init().pbi_status } == libc::SZOMB {
        ProcessState::Exited
    } else {
        ProcessState::Running
    }
}

#[derive(Debug)]
enum ProcessState {
    Running,
    Exited,
    Unknown(std::io::Error),
}

#[cfg(not(target_os = "macos"))]
fn process_state_from_kill(result: std::result::Result<(), Errno>) -> ProcessState {
    match result {
        Ok(()) | Err(Errno::EPERM) => ProcessState::Running,
        Err(Errno::ESRCH) => ProcessState::Exited,
        Err(error) => ProcessState::Unknown(std::io::Error::from_raw_os_error(error as i32)),
    }
}

#[cfg(target_os = "macos")]
fn missing_process_info_state(errno: Errno, written: i32, pid: i32) -> ProcessState {
    match (written, errno) {
        (..=0, Errno::ESRCH) => ProcessState::Exited,
        (_, errno) => ProcessState::Unknown(std::io::Error::other(format!(
            "proc_pidinfo returned {written} bytes for process {pid}: {errno}"
        ))),
    }
}

#[cfg(target_os = "macos")]
fn confirm_exited_or_uncertain(pid: i32, context: &str) -> Result<bool> {
    match process_exists(pid) {
        ProcessState::Exited => Ok(false),
        ProcessState::Running => Err(anyhow!("{context}")),
        ProcessState::Unknown(error) => Err(error).context(context.to_owned()),
    }
}

async fn pid_record_matches_process(record: &PidRecord) -> Result<bool> {
    let pid = i32::try_from(record.pid).context("Codex daemon pid exceeds i32")?;
    match process_exists(pid) {
        ProcessState::Running => {}
        ProcessState::Exited => return Ok(false),
        ProcessState::Unknown(error) => {
            return Err(error).context("Codex pid record process state is unknown");
        }
    }
    process_identity_matches(pid, &record.process_identity).await
}

#[cfg(target_os = "macos")]
async fn process_identity_matches(pid: i32, identity: &ProcessIdentity) -> Result<bool> {
    let (start_seconds, start_microseconds, expected_boot, expected_unique) = match identity {
        ProcessIdentity::MacOsUnique {
            boot_id,
            unique_id,
            start_seconds,
            start_microseconds,
        } => (
            *start_seconds,
            *start_microseconds,
            boot_id.as_str(),
            *unique_id,
        ),
        ProcessIdentity::Linux { .. } => return Ok(false),
    };
    let mut boot = [0u8; 37];
    let mut size = boot.len();
    // SAFETY: sysctlbyname writes into the sized boot UUID buffer.
    let result = unsafe {
        libc::sysctlbyname(
            c"kern.bootsessionuuid".as_ptr(),
            boot.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if result != 0 || size != boot.len() {
        return Err(std::io::Error::last_os_error()).context("reading macOS boot identity");
    }
    let actual = std::ffi::CStr::from_bytes_with_nul(&boot)?.to_str()?;
    if actual != expected_boot {
        return Ok(false);
    }
    #[repr(C)]
    struct UniqueInfo {
        executable_uuid: [u8; 16],
        unique_id: u64,
        parent_unique_id: u64,
        reserved: [u64; 3],
    }
    let mut unique_info = std::mem::MaybeUninit::<UniqueInfo>::uninit();
    let unique_size = std::mem::size_of::<UniqueInfo>() as libc::c_int;
    // SAFETY: proc_pidinfo receives a correctly sized writable unique-ID buffer.
    let unique_read =
        unsafe { libc::proc_pidinfo(pid, 17, 1, unique_info.as_mut_ptr().cast(), unique_size) };
    if unique_read != unique_size {
        return confirm_exited_or_uncertain(pid, "Codex process identity could not be verified");
    }
    // SAFETY: the exact-size return above guarantees initialization.
    let unique = unsafe { unique_info.assume_init() }.unique_id;
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::uninit();
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: proc_pidinfo receives a correctly sized writable process buffer.
    let read = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            1,
            info.as_mut_ptr().cast(),
            size,
        )
    };
    if read != size {
        return confirm_exited_or_uncertain(pid, "Codex process start time could not be verified");
    }
    // SAFETY: the exact-size return above guarantees initialization.
    let info = unsafe { info.assume_init() };
    Ok(info.pbi_status != libc::SZOMB
        && info.pbi_start_tvsec == start_seconds
        && info.pbi_start_tvusec == start_microseconds
        && unique == expected_unique)
}

#[cfg(target_os = "linux")]
async fn process_identity_matches(pid: i32, identity: &ProcessIdentity) -> Result<bool> {
    let ProcessIdentity::Linux {
        boot_id,
        start_ticks,
    } = identity
    else {
        return Ok(false);
    };
    let actual_boot = tokio::fs::read_to_string("/proc/sys/kernel/random/boot_id").await?;
    if actual_boot.trim() != boot_id {
        return Ok(false);
    }
    let stat = tokio::fs::read_to_string(format!("/proc/{pid}/stat")).await?;
    let Some((_, fields)) = stat.rsplit_once(") ") else {
        return Ok(false);
    };
    Ok(fields
        .split_whitespace()
        .nth(19)
        .and_then(|value| value.parse::<u64>().ok())
        == Some(*start_ticks))
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
async fn process_identity_matches(_pid: i32, _identity: &ProcessIdentity) -> Result<bool> {
    Ok(false)
}

#[cfg(not(target_os = "macos"))]
fn process_exists(pid: i32) -> ProcessState {
    if pid <= 0 {
        return ProcessState::Exited;
    }
    process_state_from_kill(nix::sys::signal::kill(Pid::from_raw(pid), None))
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;
    use crate::test_support::current_process_identity;

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn reused_pid_record_with_old_boot_is_not_live() {
        let home = tempfile::tempdir().expect("Codex home");
        let server = CodexAppServer::with_codex_home(
            PathBuf::from("/tmp/codex"),
            HashMap::new(),
            home.path().to_path_buf(),
        );
        std::fs::create_dir_all(server.pid_file.parent().expect("pid directory"))
            .expect("pid directory");
        std::fs::write(
            &server.pid_file,
            serde_json::to_vec(&serde_json::json!({
                "pid": std::process::id(),
                "processIdentity": {
                    "bootId": "old-boot", "uniqueId": 1,
                    "startSeconds": 1, "startMicroseconds": 1,
                },
            }))
            .expect("pid JSON"),
        )
        .expect("pid record");
        assert!(
            !server
                .recorded_daemon_is_live()
                .await
                .expect("identity check")
        );
    }

    #[test]
    fn lifecycle_validation_rejects_an_unmanaged_socket_owner() {
        let server = CodexAppServer::with_codex_home(
            PathBuf::from("/tmp/codex"),
            HashMap::new(),
            PathBuf::from("/tmp/codex-home"),
        );
        let output = LifecycleOutput {
            backend: None,
            pid: Some(42),
            managed_codex_version: Some(REQUIRED_CODEX_VERSION.to_string()),
            managed_codex_path: None,
            app_server_version: Some(REQUIRED_CODEX_VERSION.to_string()),
            socket_path: server.socket_path.clone(),
        };

        let error = server
            .validate_lifecycle(&output)
            .expect_err("unmanaged owner must fail validation");
        assert!(error.to_string().contains("unverified app-server owner"));
    }

    #[test]
    fn current_process_is_live_and_invalid_pids_are_not() {
        assert!(matches!(
            process_exists(i32::try_from(std::process::id()).unwrap()),
            ProcessState::Running
        ));
        assert!(matches!(process_exists(-1), ProcessState::Exited));
    }

    #[test]
    fn process_probe_errors_do_not_become_exits() {
        #[cfg(not(target_os = "macos"))]
        {
            assert!(matches!(
                process_state_from_kill(Ok(())),
                ProcessState::Running
            ));
            assert!(matches!(
                process_state_from_kill(Err(Errno::EPERM)),
                ProcessState::Running
            ));
            assert!(matches!(
                process_state_from_kill(Err(Errno::ESRCH)),
                ProcessState::Exited
            ));
            assert!(matches!(
                process_state_from_kill(Err(Errno::EIO)),
                ProcessState::Unknown(_)
            ));
        }
        #[cfg(target_os = "macos")]
        {
            assert!(matches!(
                missing_process_info_state(Errno::ESRCH, 0, 42),
                ProcessState::Exited
            ));
            assert!(matches!(
                missing_process_info_state(Errno::EPERM, 0, 42),
                ProcessState::Unknown(_)
            ));
            assert!(matches!(
                missing_process_info_state(Errno::ESRCH, 8, 42),
                ProcessState::Unknown(_)
            ));
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn exited_unreaped_child_is_not_live() {
        let mut child = std::process::Command::new("/usr/bin/true")
            .spawn()
            .expect("spawn child");
        let pid = i32::try_from(child.id()).expect("child pid");
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while matches!(process_exists(pid), ProcessState::Running)
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(
            matches!(process_exists(pid), ProcessState::Exited),
            "zombie child was reported as live"
        );
        child.wait().expect("reap child");
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[tokio::test]
    async fn readiness_needs_only_the_socket_handshake() {
        let codex_home = tempfile::tempdir().expect("Codex home");
        let socket_dir = codex_home.path().join("app-server-control");
        let pid_dir = codex_home.path().join("app-server-daemon");
        tokio::fs::create_dir_all(&socket_dir)
            .await
            .expect("socket directory");
        tokio::fs::create_dir_all(&pid_dir)
            .await
            .expect("pid directory");
        let socket_path = socket_dir.join("app-server-control.sock");
        let listener = tokio::net::UnixListener::bind(&socket_path).expect("Unix listener");
        let expected_pid = i32::try_from(std::process::id()).expect("test pid");
        tokio::fs::write(
            pid_dir.join("app-server.pid"),
            serde_json::to_vec(&serde_json::json!({
                "pid": expected_pid,
                "processIdentity": current_process_identity(),
            }))
            .expect("pid JSON"),
        )
        .await
        .expect("pid record");
        let server = CodexAppServer::with_codex_home(
            PathBuf::from("/usr/bin/false"),
            HashMap::new(),
            codex_home.path().to_path_buf(),
        );

        let peer = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("accept");
            let mut websocket = tokio_tungstenite::accept_async(stream)
                .await
                .expect("WebSocket handshake");
            while let Some(frame) = futures_util::StreamExt::next(&mut websocket).await {
                if matches!(
                    frame.expect("frame"),
                    tokio_tungstenite::tungstenite::Message::Close(_)
                ) {
                    break;
                }
            }
        });

        tokio::time::timeout(Duration::from_secs(1), server.probe_ready_info())
            .await
            .expect("readiness timeout")
            .expect("readiness");
        peer.await.expect("peer task");
    }

    #[tokio::test]
    async fn connection_rejects_a_socket_peer_that_is_not_the_managed_pid() {
        let codex_home = tempfile::tempdir().expect("Codex home");
        let socket_dir = codex_home.path().join("app-server-control");
        tokio::fs::create_dir_all(&socket_dir)
            .await
            .expect("socket directory");
        let socket_path = socket_dir.join("app-server-control.sock");
        let listener = tokio::net::UnixListener::bind(&socket_path).expect("Unix listener");
        let codex = codex_home.path().join("codex");
        write_fake_lifecycle_codex(&codex, &socket_path, "1");
        let server =
            CodexAppServer::with_codex_home(codex, HashMap::new(), codex_home.path().to_path_buf());

        let peer = tokio::spawn(async move {
            let _ = listener.accept().await.expect("accept");
        });
        let error = server
            .connect_ws()
            .await
            .expect_err("replacement socket owner must be rejected");
        assert!(
            error
                .to_string()
                .contains("does not match managed daemon pid")
        );
        peer.await.expect("peer task");
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[tokio::test]
    async fn cached_info_must_match_the_current_lifecycle_pid() {
        let codex_home = tempfile::tempdir().expect("Codex home");
        let pid_dir = codex_home.path().join("app-server-daemon");
        tokio::fs::create_dir_all(&pid_dir)
            .await
            .expect("pid directory");
        let expected_pid = i32::try_from(std::process::id()).expect("test pid");
        tokio::fs::write(
            pid_dir.join("app-server.pid"),
            serde_json::to_vec(&serde_json::json!({
                "pid": expected_pid,
                "processIdentity": current_process_identity(),
            }))
            .expect("pid JSON"),
        )
        .await
        .expect("pid record");
        let server = CodexAppServer::new_for_test_socket(codex_home.path().to_path_buf());
        *server.info.write().await = Some(CodexAppServerInfo {
            pid: 1,
            started_at_unix_seconds: 0.0,
            socket_path: server.socket_path.clone(),
        });

        assert_eq!(
            server.info().await.expect("refreshed info").pid,
            expected_pid
        );
    }

    #[tokio::test]
    async fn lifecycle_timeout_kills_the_spawned_process() {
        use std::os::unix::fs::PermissionsExt;

        let codex_home = tempfile::tempdir().expect("Codex home");
        let codex = codex_home.path().join("codex");
        let pid_file = codex_home.path().join("lifecycle.pid");
        std::fs::write(
            &codex,
            "#!/bin/sh\nprintf '%s' \"$$\" > \"$LIFECYCLE_PID_FILE\"\nexec /bin/sleep 30\n",
        )
        .expect("write fake Codex");
        let mut permissions = std::fs::metadata(&codex)
            .expect("fake Codex metadata")
            .permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&codex, permissions).expect("chmod fake Codex");
        let server = CodexAppServer::with_codex_home(
            codex,
            HashMap::from([(
                "LIFECYCLE_PID_FILE".to_string(),
                pid_file.display().to_string(),
            )]),
            codex_home.path().to_path_buf(),
        );

        let error = server
            .run_lifecycle_with_env_and_timeout("version", &[], Duration::from_secs(2))
            .await
            .expect_err("lifecycle call must time out");
        assert!(error.to_string().contains("timed out"));
        let pid = std::fs::read_to_string(&pid_file)
            .expect("lifecycle pid")
            .parse::<i32>()
            .expect("numeric lifecycle pid");
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while matches!(process_exists(pid), ProcessState::Running)
            && std::time::Instant::now() < deadline
        {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(
            matches!(process_exists(pid), ProcessState::Exited),
            "timed-out lifecycle process survived"
        );
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[tokio::test]
    async fn package_provenance_rejects_same_version_replacement_and_unknown_identity() {
        use std::os::unix::fs::PermissionsExt;

        let home = tempfile::tempdir().expect("Codex home");
        let codex = home.path().join("codex");
        let reply = home.path().join("lifecycle.json");
        std::fs::write(&codex, "#!/bin/sh\nexec /bin/cat \"$PROVENANCE_REPLY\"\n")
            .expect("fake Codex");
        std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755))
            .expect("executable permission");
        let server = CodexAppServer::with_codex_home(
            codex.clone(),
            HashMap::from([("PROVENANCE_REPLY".into(), reply.display().to_string())]),
            home.path().to_path_buf(),
        );
        std::fs::create_dir_all(server.socket_path.parent().expect("socket parent"))
            .expect("socket directory");
        std::fs::create_dir_all(server.pid_file.parent().expect("pid parent"))
            .expect("pid directory");
        let pid_file = server.pid_file.with_file_name("daemon.pid");
        let identity = *blake3::hash(&std::fs::read(&codex).expect("binary")).as_bytes();
        let mut record = serde_json::json!({
            "pid": std::process::id(),
            "processIdentity": current_process_identity(),
            "executableIdentity": {"digest": identity},
        });
        std::fs::write(&pid_file, serde_json::to_vec(&record).expect("pid record"))
            .expect("write pid record");
        let output = serde_json::json!({
            "backend": "pid", "pid": std::process::id(),
            "managedCodexPath": codex,
            "managedCodexVersion": REQUIRED_CODEX_VERSION,
            "appServerVersion": REQUIRED_CODEX_VERSION,
            "socketPath": server.socket_path,
        });
        std::fs::write(
            &reply,
            serde_json::to_vec(&output).expect("lifecycle reply"),
        )
        .expect("write reply");
        let listener = tokio::net::UnixListener::bind(&server.socket_path).expect("listener");
        let peer = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("accept");
            let mut websocket = tokio_tungstenite::accept_async(stream)
                .await
                .expect("handshake");
            let _ = futures_util::StreamExt::next(&mut websocket).await;
        });
        server
            .verify_package_provenance()
            .await
            .expect("same package reattaches");
        peer.await.expect("peer task");

        std::fs::write(&codex, "#!/bin/sh\n\nexec /bin/cat \"$PROVENANCE_REPLY\"\n")
            .expect("same version replacement");
        let error = server
            .verify_package_provenance()
            .await
            .expect_err("changed binary");
        assert!(
            error
                .to_string()
                .contains("does not match the selected runtime package")
        );

        record
            .as_object_mut()
            .expect("object")
            .remove("executableIdentity");
        std::fs::write(
            &pid_file,
            serde_json::to_vec(&record).expect("legacy record"),
        )
        .expect("write legacy record");
        let error = server
            .verify_package_provenance()
            .await
            .expect_err("unknown identity");
        assert!(
            error
                .to_string()
                .contains("omitted its running executable identity")
        );
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[tokio::test]
    async fn native_pid_layouts_require_one_unambiguous_live_owner() {
        let home = tempfile::tempdir().expect("Codex home");
        let server = CodexAppServer::new_for_test_socket(home.path().to_path_buf());
        std::fs::create_dir_all(server.pid_file.parent().expect("pid parent"))
            .expect("pid directory");
        let record = serde_json::to_vec(&serde_json::json!({
            "pid": std::process::id(),
            "processIdentity": current_process_identity(),
        }))
        .expect("pid JSON");
        for path in [
            &server.pid_file,
            &server.pid_file.with_file_name("daemon.pid"),
        ] {
            std::fs::write(path, &record).expect("pid record");
            assert_eq!(
                server.pid_file_pid().await.expect("live owner"),
                std::process::id() as i32
            );
            std::fs::remove_file(path).expect("remove record");
        }
        std::fs::write(&server.pid_file, &record).expect("legacy record");
        std::fs::write(server.pid_file.with_file_name("daemon.pid"), &record)
            .expect("dedicated record");
        assert!(
            server
                .live_pid_record()
                .await
                .expect_err("ambiguous owner")
                .to_string()
                .contains("multiple live")
        );
        std::fs::remove_file(&server.pid_file).expect("remove legacy record");
        std::fs::write(server.pid_file.with_file_name("daemon.pid"), b"invalid")
            .expect("invalid native record");
        assert!(server.recorded_daemon_is_live().await.is_err());
        std::fs::remove_file(server.pid_file.with_file_name("daemon.pid"))
            .expect("remove invalid record");
        std::fs::write(
            &server.pid_file,
            format!("{{\"pid\":{}}}", std::process::id()),
        )
        .expect("identity-less record");
        assert!(server.recorded_daemon_is_live().await.is_err());
    }

    fn write_fake_lifecycle_codex(path: &Path, socket_path: &Path, pid: &str) {
        use std::os::unix::fs::PermissionsExt;

        std::fs::write(
            path,
            format!(
                "#!/bin/sh\nprintf '{{\"backend\":\"pid\",\"pid\":%s,\"managedCodexVersion\":\"{}\",\"appServerVersion\":\"{}\",\"socketPath\":\"{}\"}}\\n' {pid}\n",
                REQUIRED_CODEX_VERSION,
                REQUIRED_CODEX_VERSION,
                socket_path.display(),
            ),
        )
        .expect("write fake Codex");
        let mut permissions = std::fs::metadata(path).expect("metadata").permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(path, permissions).expect("chmod fake Codex");
    }
}
