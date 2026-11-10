use std::sync::Arc;
use std::time::Duration;

use anyhow::{Result, ensure};

use crate::config::{CodexSettings, ConfigSources, DEFAULT_LOG_RETENTION_DAYS, HostPaths};
use crate::devices::DeviceRegistry;
use crate::gateway::{ExternalAuth, Gateway};
use crate::observability::journal::Journal;
use crate::providers::claude::settings::ClaudeSettings;
use crate::providers::codex::daemon::CodexAppServer;
use crate::providers::{codex, router};
use crate::push::{PushConfiguration, PushService};

pub(super) async fn run(sources: &ConfigSources) -> Result<()> {
    for key in [
        "RC_CODEX_GATEWAY_BIND_HOST",
        "RC_CODEX_GATEWAY_PORT",
        "RC_CODEX_GATEWAY_LAN_PORT",
        "RC_CODEX_GATEWAY_AUTH_TOKEN",
        crate::cluster::routes::ENV_KEY,
        "RC_AGENT_JOB_SOCKET",
    ] {
        ensure!(
            sources.raw(key).is_none(),
            "runtime serve does not accept {key}"
        );
    }
    let paths = HostPaths::from_env()?;
    let settings = CodexSettings::load(sources)?;
    let router_config = router::RouterConfig::load(sources)?;
    let router = Arc::new(router::Router::new(router_config.clone())?);
    let codex_router = Arc::new(codex::router::Router::new(router));
    let codex = Arc::new(CodexAppServer::new(
        settings.codex_path,
        settings.codex_child_env,
    ));
    let store =
        super::recovery::RecoveryStore::new(super::recovery::RecoveryStore::default_path()?);
    let _owner = super::ControlOwnerLease::acquire(&store)?;
    super::bootstrap(&codex, false).await?;
    let journal = Journal::open_in(paths.logs("journal"), DEFAULT_LOG_RETENTION_DAYS);
    let devices = Arc::new(DeviceRegistry::open(&paths, sources)?);
    let push = Arc::new(PushService::new(
        PushConfiguration::Disabled,
        journal.clone(),
        devices,
        None,
    ));
    let gateway = Gateway::with_notifier(
        codex,
        push,
        ClaudeSettings::disabled(&paths),
        journal.clone(),
        crate::gateway::GatewayState::host(&paths),
        None,
        router_config
            .map(|config| ExternalAuth::new(codex_router, config.codex_account().to_owned())),
        None,
        None,
        None,
    );
    gateway.start_runtime().await?;
    tracing::info!("managed Codex runtime started without gateway ingress");
    crate::http::server::wait_for_shutdown_signal().await;
    gateway.shutdown_for_restart().await;
    let stopped = gateway.stop().await;
    journal.drain(Duration::from_secs(2)).await;
    stopped
}
