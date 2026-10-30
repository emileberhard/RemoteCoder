use super::claude_state::ClaudeStateBackup;
use super::package::{commit_runtime_swap, remove_path};
use super::uninstall::require_running_from;
use crate::config::host_profile::DesktopMode;
use crate::config::{ConfigSources, GatewayEndpoint, HostPaths};
use crate::runtime::bootstrap::RuntimeLease;
use crate::runtime::desktop::{check_desktop, stop_desktop};
use crate::runtime::gateway_probe::{
    GatewayProbe, MIN_SCHEDULING_PRIORITY, priority_is_default_or_higher, process_priority,
};
use crate::runtime::launchd::{
    DESKTOP_LABEL, GATEWAY_LABEL, LaunchdService, clear_chatgpt_launchctl_environment,
};
use crate::runtime::require_gateway_env;
use crate::runtime::transaction::RecoveryTransaction;
use anyhow::{Context, Result, anyhow, bail, ensure};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tracing::warn;

const GATEWAY_HEALTH_TIMEOUT: Duration = Duration::from_secs(180);
const DESKTOP_HEALTH_TIMEOUT: Duration = Duration::from_secs(60);
const LIFECYCLE_TIMEOUT: Duration = Duration::from_secs(180);
const LIFECYCLE_PROBE_TIMEOUT: Duration = Duration::from_secs(6);
const LIFECYCLE_STABLE_PROBES: usize = 3;
const HEALTH_POLL_INTERVAL: Duration = Duration::from_secs(5);
const DESKTOP_ATTACH_ATTEMPTS: usize = 6;
const DESKTOP_ATTACH_INTERVAL: Duration = Duration::from_secs(10);
pub(super) const LEGACY_DESKTOP_LAUNCHER: &str = "launch-chatgpt-with-shared-codex";

pub(in crate::runtime) struct Artifact {
    installed: PathBuf,
    staged: PathBuf,
    previous: PathBuf,
    had_previous: bool,
}

impl Artifact {
    pub(in crate::runtime) fn at(directory: &Path, name: &str, stage_id: u32) -> Self {
        Self {
            installed: directory.join(name),
            staged: directory.join(format!("{name}.new.{stage_id}")),
            previous: directory.join(format!("{name}.previous")),
            had_previous: false,
        }
    }

    pub(in crate::runtime) fn back_up(&mut self) -> Result<()> {
        self.had_previous = self.installed.exists();
        if self.had_previous {
            std::fs::copy(&self.installed, &self.previous)
                .with_context(|| format!("failed to back up {}", self.installed.display()))?;
        } else {
            remove_path(&self.previous)?;
        }
        Ok(())
    }

    pub(in crate::runtime) fn activate(&self) -> Result<()> {
        std::fs::rename(&self.staged, &self.installed)
            .with_context(|| format!("failed to activate {}", self.installed.display()))
    }

    async fn activate_launchagent(&self, service: &LaunchdService) -> Result<()> {
        self.activate()?;
        service.bootstrap().await
    }

    pub(in crate::runtime) fn restore(&self) -> Result<()> {
        if !self.had_previous {
            return remove_path(&self.installed);
        }
        std::fs::copy(&self.previous, &self.staged)
            .with_context(|| format!("failed to read back {}", self.previous.display()))?;
        self.activate()
    }

    fn discard_previous(&self) -> Result<()> {
        remove_path(&self.previous)
    }
}

pub(in crate::runtime) struct InstallationTransaction<'a> {
    recovery: RecoveryTransaction<'a>,
    env_file: &'a Path,
    probe: GatewayProbe,
    gateway: LaunchdService,
    desktop: LaunchdService,
    staged_bundle: PathBuf,
    launcher: Artifact,
    gateway_plist: Artifact,
    desktop_plist: Artifact,
    pair: Option<super::pair::Pair>,
    _installation_lease: super::call_worker::Lease,
    paths: HostPaths,
    legacy_desktop_launcher: PathBuf,
    claude_state: ClaudeStateBackup,
    claude_home: PathBuf,
}

impl<'a> InstallationTransaction<'a> {
    pub(in crate::runtime) fn new(
        recovery: RecoveryTransaction<'a>,
        env_file: Option<&'a Path>,
        sources: &ConfigSources,
        stage_id: u32,
    ) -> Result<Self> {
        let env_file = env_file.context("gateway install requires the gateway env file")?;
        require_gateway_env(env_file)?;
        let paths = HostPaths::from_env()?;
        let bin_dir = paths.home().join("localbin/remote-coder-gateway");
        let agents_dir = paths.home().join("Library/LaunchAgents");
        let staged_bundle = bin_dir.join(format!("{}.new.{stage_id}", super::bundle::NAME));
        require_running_from(&super::bundle::executable(&staged_bundle))?;
        Ok(Self {
            recovery,
            env_file,
            probe: GatewayProbe::new(GatewayEndpoint::load(sources)?)?,
            gateway: LaunchdService::new(GATEWAY_LABEL, &paths),
            desktop: LaunchdService::new(DESKTOP_LABEL, &paths),
            launcher: Artifact::at(&bin_dir, "launch-codex-gateway", stage_id),
            gateway_plist: Artifact::at(&agents_dir, &format!("{GATEWAY_LABEL}.plist"), stage_id),
            desktop_plist: Artifact::at(&agents_dir, &format!("{DESKTOP_LABEL}.plist"), stage_id),
            pair: None,
            _installation_lease: super::call_worker::Lease::acquire(&paths)?,
            paths: paths.clone(),
            legacy_desktop_launcher: bin_dir.join(LEGACY_DESKTOP_LAUNCHER),
            claude_state: ClaudeStateBackup::for_host()?,
            claude_home: sources
                .optional_string("RC_CLAUDE_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| paths.home().join(".claude")),
            staged_bundle,
        })
    }

    pub(in crate::runtime) async fn run(mut self) -> Result<()> {
        let config = super::call_worker::prepare(&self.paths).await?;
        self.pair = Some(super::pair::Pair::prepare(
            &self.paths,
            &self.staged_bundle,
            config.as_deref(),
        )?);
        let desktop_mode =
            DesktopMode::for_codex_home(self.recovery.app_server.provider_home()?)?.context(
                "gateway installation manages this user's ChatGPT Desktop and requires the user's own Codex home",
            )?;
        self.back_up()?;
        if let Err(error) = self.prepare_handoff().await {
            self.discard_backups()?;
            return Err(error);
        }
        if let Err(error) = self.cut_over(desktop_mode).await {
            return Err(self.roll_back(error).await);
        }
        self.commit(desktop_mode).await
    }

    fn artifacts_mut(&mut self) -> impl Iterator<Item = &mut Artifact> {
        [
            &mut self.launcher,
            &mut self.gateway_plist,
            &mut self.desktop_plist,
        ]
        .into_iter()
    }

    fn back_up(&mut self) -> Result<()> {
        for artifact in self.artifacts_mut() {
            artifact.back_up()?;
        }
        Ok(())
    }

    fn discard_backups(&self) -> Result<()> {
        for artifact in [&self.launcher, &self.gateway_plist, &self.desktop_plist].into_iter() {
            artifact.discard_previous()?;
        }
        Ok(())
    }

    async fn prepare_handoff(&self) -> Result<()> {
        let _lease = RuntimeLease::acquire(self.recovery.store)?;
        self.recovery.prepare_handoff().await
    }

    async fn cut_over(&self, desktop_mode: DesktopMode) -> Result<()> {
        let started = std::time::Instant::now();
        let mark = |phase: &str| {
            println!(
                "cutover phase={phase} elapsedMs={}",
                started.elapsed().as_millis()
            )
        };
        self.desktop.bootout().await?;
        stop_desktop(self.recovery.app_server, "install").await?;
        mark("desktopStopped");
        self.gateway.bootout().await?;
        mark("gatewayUnloaded");
        crate::runtime::control_owner::wait_for_control_owner_exit(
            self.recovery.store,
            super::RECOVERY_GATEWAY_EXIT_TIMEOUT,
        )
        .await?;
        mark("controlOwnerReleased");
        self.claude_state
            .capture(&self.claude_home, self.recovery.app_server.provider_home()?)?;
        self.activate_gateway_artifacts()?;
        self.gateway_plist
            .activate_launchagent(&self.gateway)
            .await?;
        self.gateway.kickstart().await?;
        mark("gatewayLaunched");

        self.wait_for_stable_health(GATEWAY_HEALTH_TIMEOUT, 1)
            .await
            .context("gateway did not become healthy")?;
        mark("gatewayHealthy");
        self.wait_for_stable_codex_lifecycle()
            .await
            .context("shared Codex lifecycle did not stabilize before Desktop launch")?;
        self.verify_scheduling_policy()
            .await
            .context("shared Codex scheduling policy did not activate")?;
        self.verify_file_descriptor_policy()
            .await
            .context("shared Codex app-server resource-limit policy did not activate")?;
        self.attach_desktop(desktop_mode).await
    }

    async fn commit(&self, desktop_mode: DesktopMode) -> Result<()> {
        {
            let _lease = RuntimeLease::acquire(self.recovery.store)?;
            commit_runtime_swap(self.recovery.store)?;
        }
        super::call_worker::settle(&self.paths).await?;
        self.pair
            .as_ref()
            .context("Gateway pair was not prepared")?
            .prune()?;
        self.claude_state.discard()?;
        self.discard_backups()?;
        remove_path(&self.legacy_desktop_launcher)?;
        match desktop_mode {
            DesktopMode::Disabled => println!(
                "gateway initial health checks passed; ChatGPT Desktop is disabled on this host; installation committed"
            ),
            DesktopMode::Shared => println!(
                "gateway initial health and Desktop attachment checks passed; installation committed"
            ),
        }
        Ok(())
    }

    fn activate_gateway_artifacts(&self) -> Result<()> {
        self.launcher.activate()?;
        self.pair
            .as_ref()
            .context("Gateway pair was not prepared")?
            .activate()
    }

    fn restore_gateway_artifacts(&self) -> Result<()> {
        if let Some(pair) = &self.pair {
            pair.restore()?;
        }
        self.launcher.restore()
    }

    async fn wait_for_stable_codex_lifecycle(&self) -> Result<()> {
        let deadline = tokio::time::Instant::now() + LIFECYCLE_TIMEOUT;
        let mut successes = 0;
        while tokio::time::Instant::now() < deadline {
            let probe = tokio::time::timeout(
                LIFECYCLE_PROBE_TIMEOUT,
                self.recovery.app_server.run_lifecycle("version"),
            )
            .await;
            if matches!(probe, Ok(Ok(_))) {
                successes += 1;
                if successes >= LIFECYCLE_STABLE_PROBES {
                    return Ok(());
                }
            } else {
                successes = 0;
            }
            tokio::time::sleep(HEALTH_POLL_INTERVAL).await;
        }
        bail!("Codex daemon lifecycle did not answer {LIFECYCLE_STABLE_PROBES} consecutive probes")
    }

    async fn gateway_is_healthy(&self) -> bool {
        if !self
            .probe
            .worker_hash()
            .await
            .is_ok_and(|hash| hash == crate::build_identity::IDENTITY.worker_hash)
        {
            return false;
        }
        self.probe
            .healthy_installed_gateway(
                &self.gateway,
                &super::pair::directory(&self.paths).join(super::bundle::BINARY),
            )
            .await
            .is_ok()
    }

    async fn wait_for_stable_health(&self, timeout: Duration, required: usize) -> Result<()> {
        let deadline = tokio::time::Instant::now() + timeout;
        let mut successes = 0;
        while tokio::time::Instant::now() < deadline {
            if self.gateway_is_healthy().await {
                successes += 1;
                if successes >= required {
                    return Ok(());
                }
            } else {
                successes = 0;
            }
            tokio::time::sleep(HEALTH_POLL_INTERVAL).await;
        }
        bail!("gateway health did not hold for {required} consecutive checks within {timeout:?}")
    }

    async fn verify_scheduling_policy(&self) -> Result<()> {
        let job = self
            .gateway
            .job()
            .await?
            .context("gateway launchd job is not loaded")?;
        ensure!(
            job.spawn_type.as_deref() == Some("interactive"),
            "gateway launchd spawn type is {}, expected interactive",
            job.spawn_type.as_deref().unwrap_or("unknown")
        );
        let gateway_pid = self
            .probe
            .launchd_owned_gateway_pid(
                &self.gateway,
                &super::pair::directory(&self.paths).join(super::bundle::BINARY),
            )
            .await?;
        let app_server_pid = self.probe.health().await?.codex_pid;
        for (name, pid) in [("gateway", gateway_pid), ("app-server", app_server_pid)] {
            let priority = process_priority(pid).await?;
            ensure!(
                priority_is_default_or_higher(priority),
                "{name} pid {pid} is still below default scheduling priority ({priority} < {MIN_SCHEDULING_PRIORITY})"
            );
            println!("scheduling {name}Pid={pid} priority={priority}");
        }
        Ok(())
    }

    async fn verify_file_descriptor_policy(&self) -> Result<()> {
        let diagnostics = self
            .probe
            .diagnostics()
            .await
            .context("candidate app-server resource diagnostics are unavailable")?;
        diagnostics.verify()?;
        println!(
            "resource appServerPid={} nofileSoft={}",
            diagnostics.process_id, diagnostics.nofile_soft
        );
        Ok(())
    }

    async fn attach_desktop(&self, desktop_mode: DesktopMode) -> Result<()> {
        match desktop_mode {
            DesktopMode::Disabled => {
                self.desktop.bootout().await?;
                remove_path(&self.desktop_plist.installed)
            }
            DesktopMode::Shared => {
                stop_desktop(self.recovery.app_server, "install").await?;
                self.desktop.bootout().await?;
                self.desktop_plist
                    .activate_launchagent(&self.desktop)
                    .await?;
                if let Err(error) = self.desktop.wait_until_idle().await {
                    warn!(%error, "Desktop helper did not settle after its first launch");
                }
                self.wait_for_desktop_attachment().await?;
                if let Err(error) = self
                    .wait_for_stable_health(DESKTOP_HEALTH_TIMEOUT, LIFECYCLE_STABLE_PROBES)
                    .await
                {
                    eprintln!(
                        "warning: gateway health did not stabilize after ChatGPT attached; Desktop attachment already passed, so transient application latency will not trigger rollback: {error:#}"
                    );
                }
                Ok(())
            }
        }
    }

    async fn wait_for_desktop_attachment(&self) -> Result<()> {
        let mut last_error = anyhow!("no Desktop attachment check ran");
        for attempt in 0..DESKTOP_ATTACH_ATTEMPTS {
            if attempt > 0 {
                tokio::time::sleep(DESKTOP_ATTACH_INTERVAL).await;
            }
            match check_desktop(self.recovery.app_server, "install").await {
                Ok(()) => return Ok(()),
                Err(error) => last_error = error,
            }
        }
        Err(last_error).context("ChatGPT did not attach to the shared Codex app-server")
    }

    async fn roll_back(&self, error: anyhow::Error) -> anyhow::Error {
        eprintln!("gateway installation failed; restoring the previous installation: {error:#}");
        match self.restore_previous_installation().await {
            Ok(()) => error.context("installation failed and the previous installation was restored"),
            Err(restore_error) => error.context(format!(
                "installation failed and restoring the previous installation also failed: {restore_error:#}"
            )),
        }
    }

    async fn restore_previous_installation(&self) -> Result<()> {
        let released = async {
            self.desktop.bootout().await?;
            self.gateway.bootout().await
        }
        .await;
        released.context("could not release gateway ownership for Codex runtime rollback")?;
        crate::runtime::control_owner::wait_for_control_owner_exit(
            self.recovery.store,
            super::RECOVERY_GATEWAY_EXIT_TIMEOUT,
        )
        .await?;
        let rollback = async {
            let _lease = RuntimeLease::acquire(self.recovery.store)?;
            self.recovery.rollback(Some(self.env_file)).await
        }
        .await;
        if let Err(error) = rollback {
            log_step(
                "release the desktop service after a failed rollback",
                self.desktop.bootout().await,
            );
            log_step(
                "release the gateway service after a failed rollback",
                self.gateway.bootout().await,
            );
            return Err(error).context(
                "Codex runtime rollback failed; leaving the candidate installation fenced for explicit recovery",
            );
        }
        self.claude_state.restore()?;
        self.restore_gateway_artifacts()?;
        self.restore_gateway_service().await?;
        self.restore_desktop_integration().await?;
        super::call_worker::settle(&self.paths).await?;
        if let Some(pair) = &self.pair {
            pair.prune()?;
        }
        self.discard_backups()
    }

    async fn restore_gateway_service(&self) -> Result<()> {
        if !self.gateway_plist.had_previous {
            return remove_path(&self.gateway_plist.installed);
        }
        self.gateway_plist.restore()?;
        log_step(
            "bootstrap the restored gateway service",
            self.gateway.bootstrap().await,
        );
        log_step(
            "kickstart the restored gateway service",
            self.gateway.kickstart().await,
        );
        Ok(())
    }

    async fn restore_desktop_integration(&self) -> Result<()> {
        log_step("release the desktop service", self.desktop.bootout().await);
        log_step(
            "stop ChatGPT",
            stop_desktop(self.recovery.app_server, "rollback").await,
        );
        clear_chatgpt_launchctl_environment().await;
        if !self.desktop_plist.had_previous {
            return remove_path(&self.desktop_plist.installed);
        }
        self.desktop_plist.restore()?;
        log_step(
            "bootstrap the restored desktop service",
            self.desktop.bootstrap().await,
        );
        Ok(())
    }
}

pub(super) fn log_step(step: &str, result: Result<()>) {
    if let Err(error) = result {
        warn!(%error, "could not {step}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, Read};
    use std::process::{Child, Command, Stdio};

    struct Owner(Child);

    impl Drop for Owner {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    fn plist(label: &str, revision: &str) -> String {
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>Label</key><string>{label}</string><key>ProgramArguments</key><array><string>/usr/bin/true</string></array><key>EnvironmentVariables</key><dict><key>RC_INSTALL_FIXTURE_VERSION</key><string>{revision}</string></dict></dict></plist>"
        )
    }

    #[tokio::test]
    async fn plist_activation_child() {
        let Ok(directory) = std::env::var("RC_PLIST_FIXTURE_DIRECTORY") else {
            return;
        };
        let label = match std::env::var("RC_PLIST_FIXTURE_LABEL").unwrap().as_str() {
            GATEWAY_LABEL => GATEWAY_LABEL,
            DESKTOP_LABEL => DESKTOP_LABEL,
            _ => panic!("Unexpected fixture service"),
        };
        let phase = std::env::var("RC_PLIST_FIXTURE_PHASE").unwrap();
        let paths = HostPaths::from_home(directory.into()).unwrap();
        let service = LaunchdService::new(label, &paths);
        let mut artifact = Artifact::at(
            service.plist().parent().unwrap(),
            &format!("{label}.plist"),
            std::process::id(),
        );
        std::fs::write(&artifact.staged, plist(label, "candidate")).unwrap();
        artifact.back_up().unwrap();
        if phase == "after" {
            artifact.activate_launchagent(&service).await.unwrap();
        } else if phase == "failed-rename" {
            std::fs::remove_file(&artifact.staged).unwrap();
            assert!(artifact.activate_launchagent(&service).await.is_err());
        }
        println!("PLIST_READY");
        std::io::stdin().read_exact(&mut [0_u8]).unwrap();
    }

    #[test]
    fn killed_plist_activation_keeps_a_valid_old_or_new_launchagent() {
        for label in [GATEWAY_LABEL, DESKTOP_LABEL] {
            for (phase, expected) in [
                ("before", "source"),
                ("after", "candidate"),
                ("failed-rename", "source"),
            ] {
                let directory = tempfile::tempdir().unwrap();
                let agents = directory.path().join("Library/LaunchAgents");
                std::fs::create_dir_all(&agents).unwrap();
                let installed = agents.join(format!("{label}.plist"));
                std::fs::write(&installed, plist(label, "source")).unwrap();
                let commands = directory.path().join("commands");
                std::fs::create_dir(&commands).unwrap();
                let launchctl = commands.join("launchctl");
                std::fs::write(&launchctl, "#!/bin/sh\nexit 0\n").unwrap();
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&launchctl, std::fs::Permissions::from_mode(0o755))
                    .unwrap();
                let mut owner = Owner(
                    Command::new(std::env::current_exe().unwrap())
                        .args([
                            "--exact",
                            "runtime::install::transaction::tests::plist_activation_child",
                            "--nocapture",
                        ])
                        .env("RC_PLIST_FIXTURE_DIRECTORY", directory.path())
                        .env("RC_PLIST_FIXTURE_LABEL", label)
                        .env("RC_PLIST_FIXTURE_PHASE", phase)
                        .env("PATH", format!("{}:/usr/bin:/bin", commands.display()))
                        .stdin(Stdio::piped())
                        .stdout(Stdio::piped())
                        .spawn()
                        .unwrap(),
                );
                let output = owner.0.stdout.take().unwrap();
                let (sender, receiver) = std::sync::mpsc::sync_channel(1);
                let reader = std::thread::spawn(move || {
                    for line in std::io::BufReader::new(output).lines() {
                        if line.unwrap() == "PLIST_READY" {
                            sender.send(()).unwrap();
                            return;
                        }
                    }
                });
                receiver
                    .recv_timeout(std::time::Duration::from_secs(5))
                    .unwrap();
                owner.0.kill().unwrap();
                assert!(!owner.0.wait().unwrap().success());
                reader.join().unwrap();
                let restarted = Command::new("/usr/bin/plutil")
                    .args([
                        "-extract",
                        "EnvironmentVariables.RC_INSTALL_FIXTURE_VERSION",
                        "raw",
                        "-o",
                        "-",
                    ])
                    .arg(&installed)
                    .output()
                    .unwrap();
                assert!(restarted.status.success(), "{label}/{phase}: {restarted:?}");
                assert_eq!(
                    String::from_utf8(restarted.stdout).unwrap().trim(),
                    expected,
                    "{label}/{phase}"
                );
            }
        }
    }
}
