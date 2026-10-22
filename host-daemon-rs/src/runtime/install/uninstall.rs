use super::package::remove_path;
use super::transaction::{LEGACY_DESKTOP_LAUNCHER, log_step};
use crate::config::{CodexSettings, ConfigSources, GatewayEndpoint, HostPaths};
use crate::providers::codex::daemon::CodexAppServer;
use crate::runtime::bootstrap::RuntimeLease;
use crate::runtime::desktop::control::{chatgpt_app_pids, process_lines};
use crate::runtime::gateway_probe::GatewayProbe;
use crate::runtime::launchd::{
    DESKTOP_LABEL, GATEWAY_LABEL, LaunchdService, clear_chatgpt_launchctl_environment,
};
use crate::runtime::recovery::{RecoveryPhase, RecoveryStore};
use crate::runtime::rpc::{RpcClient, snapshot_active_tasks};
use anyhow::{Context, Result, bail, ensure};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub(in crate::runtime) fn require_running_from(staged_binary: &Path) -> Result<()> {
    let running = std::fs::canonicalize(std::env::current_exe()?)?;
    let expected = std::fs::canonicalize(staged_binary).with_context(|| {
        format!(
            "staged gateway binary is missing: {}",
            staged_binary.display()
        )
    })?;
    ensure!(
        running == expected,
        "install-gateway must run from its staged binary {}",
        staged_binary.display()
    );
    Ok(())
}

pub(in crate::runtime) fn uninstall_refusal(processes: &[(i32, String)]) -> Option<&'static str> {
    if !chatgpt_app_pids(processes).is_empty() {
        return Some(
            "ChatGPT is running; inventory its active tasks and quit it before uninstalling",
        );
    }
    processes
        .iter()
        .any(|(_, command)| is_codex_proxy_command(command))
        .then_some("a Codex daemon client is still connected; stop it before uninstalling")
}

fn is_codex_proxy_command(command: &str) -> bool {
    command
        .split_once(' ')
        .is_some_and(|(executable, arguments)| {
            Path::new(executable)
                .file_name()
                .is_some_and(|name| name == "codex")
                && arguments.starts_with("app-server proxy --sock ")
        })
}

fn is_unix_socket(path: &Path) -> Result<bool> {
    use std::os::unix::fs::FileTypeExt;
    match std::fs::symlink_metadata(path) {
        Ok(metadata) => Ok(metadata.file_type().is_socket()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error).with_context(|| format!("failed to inspect {}", path.display())),
    }
}

pub(in crate::runtime) struct UninstallTransaction<'a> {
    env_file: Option<&'a Path>,
    sources: &'a ConfigSources,
    paths: HostPaths,
    gateway: LaunchdService,
    desktop: LaunchdService,
    removable: [PathBuf; 4],
}

impl<'a> UninstallTransaction<'a> {
    pub(in crate::runtime) fn new(
        env_file: Option<&'a Path>,
        sources: &'a ConfigSources,
    ) -> Result<Self> {
        let paths = HostPaths::from_env()?;
        let gateway = LaunchdService::new(GATEWAY_LABEL, &paths);
        let desktop = LaunchdService::new(DESKTOP_LABEL, &paths);
        let bin_dir = paths.home().join("localbin/remote-coder-gateway");
        let removable = [
            gateway.plist().to_path_buf(),
            desktop.plist().to_path_buf(),
            bin_dir.join("launch-codex-gateway"),
            bin_dir.join(LEGACY_DESKTOP_LAUNCHER),
        ];
        Ok(Self {
            env_file,
            sources,
            paths,
            gateway,
            desktop,
            removable,
        })
    }

    pub(in crate::runtime) async fn run(self) -> Result<()> {
        if let Some(refusal) = uninstall_refusal(&process_lines()?) {
            bail!("{refusal}");
        }
        match self.env_file.filter(|env| env.is_file()) {
            Some(_) => self.stop_daemon_behind_fence().await?,
            None => ensure!(
                !is_unix_socket(CodexAppServer::new(PathBuf::new(), HashMap::new()).socket_path())?,
                "gateway environment is missing while the managed Codex socket is live; restore the environment and inventory active turns before uninstalling"
            ),
        }
        self.gateway.bootout().await?;
        self.desktop.bootout().await?;
        for path in &self.removable {
            remove_path(path)?;
        }
        clear_chatgpt_launchctl_environment().await;
        Ok(())
    }

    async fn stop_daemon_behind_fence(&self) -> Result<()> {
        let settings = CodexSettings::load(self.sources)?;
        let app_server = CodexAppServer::new(settings.codex_path, settings.codex_child_env);
        let store = RecoveryStore::new(RecoveryStore::default_path()?);
        let _lease = RuntimeLease::acquire(&store)?;

        GatewayProbe::new(GatewayEndpoint::load(self.sources)?)?
            .activity()
            .await
            .context("gateway health is unavailable; refusing an unchecked uninstall")?
            .require_idle()?;
        self.require_no_admitted_work(&app_server, &store).await?;

        let gateway_was_loaded = self.gateway.is_loaded().await?;
        let desktop_was_loaded = self.desktop.is_loaded().await?;
        let fenced = async {
            self.desktop.bootout().await?;
            self.gateway.bootout().await?;
            self.require_no_admitted_work(&app_server, &store)
                .await
                .context("work was admitted before the gateway stopped accepting it")?;
            app_server.stop().await?;
            ensure!(
                !is_unix_socket(app_server.socket_path())?,
                "managed Codex socket remained after stop; refusing to unset desktop attachment"
            );
            Ok::<(), anyhow::Error>(())
        }
        .await;
        if let Err(error) = fenced {
            if gateway_was_loaded {
                log_step(
                    "restore the gateway service",
                    self.gateway.bootstrap().await,
                );
            }
            if desktop_was_loaded {
                log_step(
                    "restore the desktop service",
                    self.desktop.bootstrap().await,
                );
            }
            return Err(error)
                .context("uninstall refused; the gateway and Desktop services were restored");
        }
        Ok(())
    }

    async fn require_no_admitted_work(
        &self,
        app_server: &CodexAppServer,
        store: &RecoveryStore,
    ) -> Result<()> {
        ensure!(
            store
                .load()?
                .is_none_or(|journal| journal.phase == RecoveryPhase::Completed),
            "an unfinished Codex restart transaction must recover before uninstalling"
        );
        let claude = crate::providers::claude::restart::Store::beside(
            &self.paths.state("active-codex-turns.json"),
        )
        .load()?;
        ensure!(
            claude
                .iter()
                .flat_map(|journal| &journal.items)
                .all(|item| !item.status.is_pending()),
            "a captured Claude task is waiting to resume; wait for it before uninstalling"
        );
        if !app_server.recorded_daemon_is_live().await? {
            return Ok(());
        }
        let mut rpc = RpcClient::connect(app_server).await.context(
            "app-server active-turn inventory is unknown; refusing an unchecked uninstall",
        )?;
        let active = snapshot_active_tasks(&mut rpc).await.context(
            "app-server active-turn inventory is unknown; refusing an unchecked uninstall",
        )?;
        ensure!(
            active.is_empty(),
            "the app-server has {} active turn(s); wait for them before uninstalling",
            active.len()
        );
        Ok(())
    }
}
