use super::launchd::LaunchdService;
use crate::config::GatewayEndpoint;
use crate::platform::process as mac_app;
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use std::collections::BTreeSet;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command as TokioCommand;

const PROBE_TIMEOUT: Duration = Duration::from_secs(6);
const NOFILE_FLOOR: u128 = 8192;
pub(super) const MIN_SCHEDULING_PRIORITY: u32 = 31;

#[derive(Debug, Eq, PartialEq)]
pub(super) struct HealthReport {
    pub(super) codex_pid: u32,
    codex_code_mode_host_path: PathBuf,
}

impl HealthReport {
    pub(super) fn parse(body: &str) -> Result<Self> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Body {
            status: String,
            codex_pid: u32,
            codex_code_mode_host_path: PathBuf,
        }
        let body: Body =
            serde_json::from_str(body).context("gateway health is not the expected contract")?;
        ensure!(
            body.status == "ok",
            "gateway health status is {}",
            body.status
        );
        Ok(Self {
            codex_pid: body.codex_pid,
            codex_code_mode_host_path: body.codex_code_mode_host_path,
        })
    }

    pub(super) fn code_mode_host_is_executable(&self) -> bool {
        std::fs::metadata(&self.codex_code_mode_host_path)
            .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
    }
}

#[derive(Debug, Eq, PartialEq)]
pub(super) struct ActivityReport {
    active_turn_count: u64,
    inventory_available: bool,
}

impl ActivityReport {
    pub(super) fn parse(body: &str) -> Result<Self> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Body {
            active_turn_count: u64,
            active_turn_inventory_available: bool,
        }
        let body: Body = serde_json::from_str(body)
            .context("gateway health does not report its active-turn inventory")?;
        Ok(Self {
            active_turn_count: body.active_turn_count,
            inventory_available: body.active_turn_inventory_available,
        })
    }

    pub(super) fn require_idle(&self) -> Result<()> {
        ensure!(
            self.active_turn_count == 0,
            "gateway has {} active turn(s); wait for them before uninstalling",
            self.active_turn_count
        );
        ensure!(
            self.inventory_available,
            "gateway active-turn inventory is unknown; refusing an unchecked uninstall"
        );
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum NofileLimit {
    Unlimited,
    Finite(u128),
}

impl NofileLimit {
    fn finite(decimal: &str) -> Result<Self> {
        ensure!(
            !decimal.is_empty() && decimal.bytes().all(|byte| byte.is_ascii_digit()),
            "NOFILE soft limit {decimal:?} is not a decimal number"
        );
        Ok(Self::Finite(decimal.parse().unwrap_or(u128::MAX)))
    }

    fn meets_floor(self) -> bool {
        match self {
            Self::Unlimited => true,
            Self::Finite(value) => value >= NOFILE_FLOOR,
        }
    }
}

impl std::fmt::Display for NofileLimit {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unlimited => formatter.write_str("unlimited"),
            Self::Finite(value) => write!(formatter, "{value}"),
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
pub(super) struct ResourceDiagnostics {
    pub(super) codex_pid: u32,
    pub(super) process_id: u32,
    pub(super) nofile_soft: NofileLimit,
}

impl ResourceDiagnostics {
    pub(super) fn parse(body: &str) -> Result<Self> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Body {
            codex_pid: u32,
            codex_diagnostics: Diagnostics,
        }
        #[derive(Deserialize)]
        struct Diagnostics {
            process: Process,
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Process {
            id: u32,
            file_descriptor_limits: Limits,
        }
        #[derive(Deserialize)]
        struct Limits {
            soft: SoftLimit,
        }
        #[derive(Deserialize)]
        #[serde(tag = "type", rename_all = "camelCase")]
        enum SoftLimit {
            Unlimited,
            Finite { value: String },
        }
        let body: Body = serde_json::from_str(body)
            .context("app-server resource diagnostics do not carry the process identity and NOFILE soft limit")?;
        let process = body.codex_diagnostics.process;
        let nofile_soft = match process.file_descriptor_limits.soft {
            SoftLimit::Unlimited => NofileLimit::Unlimited,
            SoftLimit::Finite { value } => NofileLimit::finite(&value)?,
        };
        Ok(Self {
            codex_pid: body.codex_pid,
            process_id: process.id,
            nofile_soft,
        })
    }

    pub(super) fn verify(&self) -> Result<()> {
        ensure!(
            self.process_id == self.codex_pid,
            "app-server diagnostics pid {} does not match managed Codex pid {}",
            self.process_id,
            self.codex_pid
        );
        ensure!(
            self.nofile_soft.meets_floor(),
            "app-server pid {} has insufficient NOFILE soft limit ({} < {NOFILE_FLOOR})",
            self.process_id,
            self.nofile_soft
        );
        Ok(())
    }
}

fn listener_pids(lsof_output: &str) -> BTreeSet<u32> {
    lsof_output
        .lines()
        .filter_map(|line| line.trim().parse().ok())
        .collect()
}

pub(super) fn priority_is_default_or_higher(priority: u32) -> bool {
    priority >= MIN_SCHEDULING_PRIORITY
}

struct GatewayOwnerObservation {
    launchd_pid: Option<u32>,
    process: Option<mac_app::ProcessIdentity>,
    listener_pids: BTreeSet<u32>,
}

impl GatewayOwnerObservation {
    fn require_installed_owner(&self, installed: &Path) -> Result<u32> {
        let pid = self.launchd_pid.context("gateway launchd job has no pid")?;
        let identity = self
            .process
            .as_ref()
            .with_context(|| format!("gateway pid {pid} is not running"))?;
        ensure!(
            std::fs::canonicalize(&identity.executable)? == std::fs::canonicalize(installed)?,
            "gateway pid {pid} does not run the installed binary"
        );
        ensure!(
            self.listener_pids == BTreeSet::from([pid]),
            "gateway pid {pid} does not exclusively own the listener"
        );
        Ok(pid)
    }

    fn require_healthy_installed_owner(
        &self,
        health: HealthReport,
        installed: &Path,
    ) -> Result<HealthReport> {
        ensure!(
            health.code_mode_host_is_executable(),
            "gateway health reports an unavailable code-mode host"
        );
        self.require_installed_owner(installed)?;
        Ok(health)
    }
}

pub(super) struct GatewayProbe {
    client: reqwest::Client,
    endpoint: GatewayEndpoint,
}

impl GatewayProbe {
    pub(super) fn new(endpoint: GatewayEndpoint) -> Result<Self> {
        Ok(Self {
            client: reqwest::Client::builder()
                .timeout(PROBE_TIMEOUT)
                .no_proxy()
                .build()?,
            endpoint,
        })
    }

    pub(super) fn port(&self) -> u16 {
        self.endpoint.port()
    }

    pub(super) async fn worker_hash(&self) -> Result<String> {
        let version: serde_json::Value = serde_json::from_str(&self.get("version").await?)?;
        version["workerHash"]
            .as_str()
            .map(str::to_owned)
            .context("Gateway version has no worker content hash")
    }

    pub(super) async fn health(&self) -> Result<HealthReport> {
        HealthReport::parse(&self.get("health").await?)
    }

    pub(super) async fn launchd_owned_gateway_pid(
        &self,
        service: &LaunchdService,
        installed: &Path,
    ) -> Result<u32> {
        self.owner_observation(service)
            .await?
            .require_installed_owner(installed)
    }

    pub(super) async fn healthy_installed_gateway(
        &self,
        service: &LaunchdService,
        installed: &Path,
    ) -> Result<HealthReport> {
        let health = self.health().await?;
        self.owner_observation(service)
            .await?
            .require_healthy_installed_owner(health, installed)
    }

    async fn owner_observation(&self, service: &LaunchdService) -> Result<GatewayOwnerObservation> {
        let launchd_pid = service.job().await?.and_then(|job| job.pid);
        let process = match launchd_pid {
            Some(pid) => mac_app::identify(i32::try_from(pid)?)?,
            None => None,
        };
        Ok(GatewayOwnerObservation {
            launchd_pid,
            process,
            listener_pids: tcp_listener_pids(self.port()).await?,
        })
    }

    pub(super) async fn activity(&self) -> Result<ActivityReport> {
        ActivityReport::parse(&self.get("health").await?)
    }

    pub(super) async fn diagnostics(&self) -> Result<ResourceDiagnostics> {
        ResourceDiagnostics::parse(&self.get("diagnostics").await?)
    }

    async fn get(&self, path: &str) -> Result<String> {
        self.client
            .get(self.endpoint.url(path))
            .bearer_auth(self.endpoint.bearer())
            .send()
            .await?
            .error_for_status()?
            .text()
            .await
            .map_err(Into::into)
    }
}

pub(super) async fn process_priority(pid: u32) -> Result<u32> {
    let output = TokioCommand::new("ps")
        .args(["-o", "pri=", "-p", &pid.to_string()])
        .stdin(Stdio::null())
        .output()
        .await
        .context("failed to run ps")?;
    ensure!(output.status.success(), "ps could not read pid {pid}");
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse()
        .with_context(|| format!("could not read priority for pid {pid}"))
}

pub(super) async fn tcp_listener_pids(port: u16) -> Result<BTreeSet<u32>> {
    let output = TokioCommand::new("lsof")
        .args(["-nP", "-t", &format!("-iTCP:{port}"), "-sTCP:LISTEN"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .await
        .context("failed to run lsof")?;
    Ok(listener_pids(&String::from_utf8_lossy(&output.stdout)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn diagnostics(process_id: u32, soft: &str) -> String {
        format!(
            r#"{{"codexPid":42,"codexDiagnostics":{{"process":{{"id":{process_id},"fileDescriptorLimits":{{"soft":{soft}}}}}}}}}"#
        )
    }

    fn finite(value: &str) -> String {
        format!(r#"{{"type":"finite","value":"{value}"}}"#)
    }

    #[test]
    fn nofile_limits_at_or_above_the_floor_pass_including_values_beyond_u64() {
        for value in ["8192", "008192", "9000", "184467440737095516160"] {
            let parsed =
                ResourceDiagnostics::parse(&diagnostics(42, &finite(value))).expect("parse");
            parsed
                .verify()
                .unwrap_or_else(|error| panic!("{value}: {error:#}"));
        }
        let unlimited =
            ResourceDiagnostics::parse(&diagnostics(42, r#"{"type":"unlimited"}"#)).expect("parse");
        unlimited.verify().expect("unlimited passes");
    }

    #[test]
    fn nofile_limits_below_the_floor_or_not_decimal_are_refused() {
        let below = ResourceDiagnostics::parse(&diagnostics(42, &finite("8191"))).expect("parse");
        assert!(below.verify().is_err());
        assert!(ResourceDiagnostics::parse(&diagnostics(42, &finite("81x2"))).is_err());
        assert!(ResourceDiagnostics::parse(&diagnostics(42, &finite(""))).is_err());
        assert!(ResourceDiagnostics::parse(&diagnostics(42, r#"{"type":"other"}"#)).is_err());
        assert!(ResourceDiagnostics::parse(r#"{"codexPid":42}"#).is_err());
        assert!(
            ResourceDiagnostics::parse(
                r#"{"codexPid":42,"codexDiagnostics":{"process":{"id":42}}}"#
            )
            .is_err()
        );
    }

    #[test]
    fn diagnostics_about_another_process_are_refused() {
        let other =
            ResourceDiagnostics::parse(&diagnostics(43, r#"{"type":"unlimited"}"#)).expect("parse");
        assert!(other.verify().is_err());
    }

    #[test]
    fn health_requires_an_ok_status_a_numeric_codex_pid_and_an_executable_host() {
        let directory = tempfile::tempdir().expect("temp dir");
        let host = directory.path().join("codex-code-mode-host");
        std::fs::write(&host, "#!/bin/sh\n").expect("host file");
        let body = |status: &str, pid: &str| {
            format!(
                r#"{{"status":"{status}","codexPid":{pid},"codexCodeModeHostPath":"{}"}}"#,
                host.display()
            )
        };

        let report = HealthReport::parse(&body("ok", "5151")).expect("healthy body");
        assert_eq!(report.codex_pid, 5151);
        assert!(!report.code_mode_host_is_executable());
        std::fs::set_permissions(&host, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        assert!(report.code_mode_host_is_executable());

        assert!(HealthReport::parse(&body("degraded", "5151")).is_err());
        assert!(HealthReport::parse(&body("ok", "null")).is_err());
    }

    #[test]
    fn healthy_normal_gateway_requires_installed_launchd_and_exclusive_listener_ownership() {
        let directory = tempfile::tempdir().expect("isolated gateway");
        let installed = directory.path().join("gateway");
        let foreign = directory.path().join("foreign-gateway");
        for executable in [&installed, &foreign] {
            std::fs::write(executable, "#!/bin/sh\n").expect("executable");
            std::fs::set_permissions(executable, std::fs::Permissions::from_mode(0o755))
                .expect("permission");
        }
        let health = || HealthReport {
            codex_pid: 22,
            codex_code_mode_host_path: installed.clone(),
        };
        let normal = GatewayOwnerObservation {
            launchd_pid: Some(11),
            process: Some(mac_app::ProcessIdentity {
                started_micros: 1,
                executable: installed.clone(),
            }),
            listener_pids: BTreeSet::from([11]),
        };
        normal
            .require_healthy_installed_owner(health(), &installed)
            .expect("proved normal owner preserves ordinary reconcile");
        for (launchd_pid, executable, listeners) in [
            (None, installed.clone(), BTreeSet::from([11])),
            (Some(11), installed.clone(), BTreeSet::new()),
            (Some(11), foreign, BTreeSet::from([11])),
            (Some(11), installed.clone(), BTreeSet::from([33])),
            (Some(11), installed.clone(), BTreeSet::from([11, 33])),
        ] {
            let observation = GatewayOwnerObservation {
                launchd_pid,
                process: Some(mac_app::ProcessIdentity {
                    started_micros: 1,
                    executable,
                }),
                listener_pids: listeners,
            };
            assert!(
                observation
                    .require_healthy_installed_owner(health(), &installed)
                    .is_err()
            );
        }
        let unavailable_host = HealthReport {
            codex_pid: 22,
            codex_code_mode_host_path: directory.path().join("missing"),
        };
        assert!(
            normal
                .require_healthy_installed_owner(unavailable_host, &installed)
                .is_err()
        );
    }

    #[test]
    fn an_uninstall_needs_a_known_empty_gateway_inventory() {
        let report = |count: u64, available: bool| {
            ActivityReport::parse(&format!(
                r#"{{"status":"ok","activeTurnCount":{count},"activeTurnInventoryAvailable":{available}}}"#
            ))
            .expect("activity report")
        };

        report(0, true).require_idle().expect("idle and known");
        assert!(report(1, true).require_idle().is_err());
        assert!(report(0, false).require_idle().is_err());
        assert!(ActivityReport::parse(r#"{"status":"ok"}"#).is_err());
    }

    #[test]
    fn listener_output_reduces_to_the_distinct_pids() {
        assert_eq!(
            listener_pids("4242\n4242\nnoise\n77\n"),
            BTreeSet::from([77, 4242])
        );
        assert!(listener_pids("").is_empty());
    }

    #[test]
    fn scheduling_priority_below_default_is_refused() {
        assert!(priority_is_default_or_higher(31));
        assert!(!priority_is_default_or_higher(30));
    }
}
