mod accounts;
mod activity;
mod agents;
mod auth;
mod automations;
mod build_identity;
mod call_worker;
mod config;
mod conversation_marks;
mod conversation_projects;
mod conversations;
mod devices;
mod directory_favorites;
mod files;
mod gateway;
mod http;
mod ids;
mod identity;
mod navigation;
mod notifications;
mod observability;
mod platform;
mod prompt_summary;
mod providers;
mod push;
mod questions;
mod rpc;
mod runtime;
mod sessions;
mod storage;
mod tasks;
#[cfg(test)]
mod test_support;
mod time;
mod turns;
mod user_preferences;
mod voice;
mod wire;

use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use clap::Parser;
use tracing::{error, info};
use tracing_subscriber::EnvFilter;

use crate::config::{Args, ConfigSources, DEFAULT_LOG_RETENTION_DAYS, Settings};
use crate::devices::DeviceRegistry;
use crate::files::upload::UploadStore;
use crate::gateway::Gateway;
use crate::http::lan::LanListener;
use crate::http::relay::{RelayEndpoint, RelayRoute};
use crate::http::server::{HttpState, RequestAdmission, run_http_server};
use crate::observability::app_logs::{APP_LOG_BYTE_CAP, APP_LOG_RETENTION_DAYS, AppLogStore};
use crate::observability::journal::Journal;
use crate::providers::codex::daemon::CodexAppServer;
use crate::push::PushService;

const JOURNAL_DRAIN_DEADLINE: Duration = Duration::from_secs(2);

fn main() -> Result<()> {
    // Parse args before tracing init so we can optionally bootstrap logging from the env-file.
    let args = Args::parse();
    if args.version {
        println!("{}", serde_json::to_string(&build_identity::IDENTITY)?);
        return Ok(());
    }
    if let Some(config::Command::Sessions(command)) = args.command.clone() {
        std::process::exit(
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?
                .block_on(agents::client::sessions::run(
                    *command,
                    args.env_file.as_deref(),
                ))?,
        );
    }
    if let Some(config::Command::Agent { command }) = args.command.clone() {
        let code = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?
            .block_on(agents::client::run(*command, args.env_file.as_deref()))?;
        std::process::exit(code);
    }
    if let Some(config::Command::ClaudeNotificationHook {
        mcp_config,
        session_id,
    }) = &args.command
    {
        // Hooks must emit no startup/logging text and never load gateway secrets.
        std::process::exit(
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?
                .block_on(providers::claude::notification_hook::run(
                    mcp_config, session_id,
                )),
        );
    }
    if let Some(config::Command::ClaudeSessionContext) = &args.command {
        std::process::exit(providers::claude::session_context::run());
    }
    #[cfg(target_os = "macos")]
    let startup_scheduling = platform::macos::scheduling::leave_darwin_background();
    let mut builder = tokio::runtime::Builder::new_multi_thread();
    builder.enable_all();
    #[cfg(target_os = "macos")]
    {
        platform::macos::scheduling::set_gateway_thread_qos();
        builder.on_thread_start(platform::macos::scheduling::set_gateway_thread_qos);
    }
    let runtime = builder.build()?;
    #[cfg(target_os = "macos")]
    {
        runtime.block_on(run(args, startup_scheduling))
    }
    #[cfg(not(target_os = "macos"))]
    {
        runtime.block_on(run(args))
    }
}

async fn run(
    args: Args,
    #[cfg(target_os = "macos")] startup_scheduling: std::io::Result<
        platform::macos::scheduling::SchedulingCheck,
    >,
) -> Result<()> {
    if matches!(args.command, Some(config::Command::CheckConfig)) {
        let sources = ConfigSources::load(args.env_file.as_deref())?;
        let settings = Settings::load(&sources)?;
        let authority = config::host_profile::AutomationAuthority::authority()?;
        let desktop = config::host_profile::DesktopMode::for_this_host()?;
        let full_disk_access = config::host_profile::FullDiskAccessRequirement::for_this_host()?;
        println!(
            "{}",
            serde_json::json!({"valid":true,"routerConfigured":settings.router.is_some(),"userNameConfigured":settings.user_name.is_some(),"claudeAuthentication":if settings.router.is_some() { "router" } else { "native" },"automationsAuthority":authority,"desktopMode":desktop.as_str(),"fullDiskAccessRequired":full_disk_access})
        );
        return Ok(());
    }
    if let Some(config::Command::Credentials { command }) = args.command.clone() {
        return auth::installation_credentials::run(command).await;
    }
    if let Some(config::Command::Runtime { command }) = &args.command
        && matches!(
            command,
            config::RuntimeCommand::PrepareGatewayStage { .. }
                | config::RuntimeCommand::ClearGatewayStage { .. }
        )
    {
        anyhow::ensure!(
            !args.recovery_only,
            "--recovery-only cannot be combined with a runtime command"
        );
        let paths = config::HostPaths::from_env()?;
        let parent = u32::try_from(nix::unistd::getppid().as_raw())?;
        match command {
            config::RuntimeCommand::PrepareGatewayStage { stage_id } => {
                runtime::install::staging::prepare(&paths, *stage_id, parent)?
            }
            config::RuntimeCommand::ClearGatewayStage { stage_id } => {
                runtime::install::staging::clear(&paths, *stage_id, parent)?
            }
            _ => unreachable!("only staging commands enter staging admission"),
        }
        return Ok(());
    }
    if let Some(config::Command::Runtime {
        command: config::RuntimeCommand::InstallCallWorker { worker_host },
    }) = &args.command
    {
        anyhow::ensure!(
            !args.recovery_only,
            "--recovery-only cannot be combined with a runtime command"
        );
        let paths = config::HostPaths::from_env()?;
        let _lease = runtime::install::call_worker::Lease::acquire(&paths)?;
        runtime::install::pair::require_current_binary(&paths)?;
        let (_, installed) =
            runtime::install::call_worker::stage(&paths, worker_host.as_deref()).await?;
        runtime::install::call_worker::confirm_current(&paths).await?;
        println!("{}", serde_json::to_string(&installed)?);
        return Ok(());
    }
    if matches!(
        &args.command,
        Some(config::Command::Runtime {
            command: config::RuntimeCommand::ConfigureCallDelivery
        })
    ) {
        use std::io::Read;
        anyhow::ensure!(
            !args.recovery_only,
            "--recovery-only cannot be combined with a runtime command"
        );
        let paths = config::HostPaths::from_env()?;
        let _lease = runtime::install::call_worker::Lease::acquire(&paths)?;
        runtime::install::pair::require_current_binary(&paths)?;
        runtime::install::call_worker::settle(&paths).await?;
        let mut config_bytes = Vec::new();
        std::io::stdin()
            .take(65537)
            .read_to_end(&mut config_bytes)?;
        let path = runtime::install::pair::configure(&paths, &config_bytes)?;
        println!("{}", serde_json::json!({"deliveryConfig": path}));
        return Ok(());
    }
    if let Some(config::Command::Runtime {
        command:
            config::RuntimeCommand::Desktop {
                action: config::DesktopAction::Mode,
            },
    }) = &args.command
    {
        println!(
            "{}",
            config::host_profile::DesktopMode::for_this_host()?.as_str()
        );
        return Ok(());
    }
    let recovery_only = args.recovery_only;
    if recovery_only && args.command.is_some() {
        anyhow::bail!("--recovery-only cannot be combined with a runtime command");
    }
    let uninstalling = matches!(
        &args.command,
        Some(config::Command::Runtime {
            command: config::RuntimeCommand::Uninstall
        })
    );
    let sources = ConfigSources::load(
        args.env_file
            .as_deref()
            .filter(|path| !uninstalling || path.is_file()),
    )?;
    let configured_filter = config::tracing_filter(&sources);

    // Tracing goes to daily rolling files; launchd's redirect keeps only the
    // startup banner and panics so those files stay small forever.
    let filter =
        EnvFilter::new(configured_filter.unwrap_or_default()).add_directive("info".parse()?);
    let subscriber = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_ansi(false)
        .with_file(true)
        .with_line_number(true)
        .with_thread_ids(true)
        .with_thread_names(true)
        .with_target(true);
    let _log_guard = match config::rolling_log_appender() {
        Ok((appender, path)) => {
            #[cfg(target_os = "macos")]
            let appender = platform::macos::scheduling::GatewayLogWriter::new(appender);
            let (writer, guard) = tracing_appender::non_blocking(appender);
            subscriber.with_writer(writer).init();
            println!("logging to {path}");
            Some(guard)
        }
        Err(error) => {
            subscriber.init();
            eprintln!("rolling log files unavailable ({error:?}); logging to stderr");
            None
        }
    };

    // Ensure any panics are captured in our logs (launchd may drop stderr).
    std::panic::set_hook(Box::new(|info| {
        let msg = if let Some(s) = info.payload().downcast_ref::<&str>() {
            (*s).to_string()
        } else if let Some(s) = info.payload().downcast_ref::<String>() {
            s.clone()
        } else {
            "<non-string panic payload>".to_string()
        };
        if let Some(loc) = info.location() {
            eprintln!(
                "panic: {msg} ({}:{}:{})",
                loc.file(),
                loc.line(),
                loc.column()
            );
            error!(
                panic_message = %msg,
                file = loc.file(),
                line = loc.line(),
                column = loc.column(),
                "panic"
            );
        } else {
            eprintln!("panic: {msg}");
            error!(panic_message = %msg, "panic");
        }
    }));

    println!(
        "remote-coder-codex-gateway {} starting",
        build_identity::IDENTITY
    );
    info!(
        version = build_identity::IDENTITY.version,
        commit = ?build_identity::IDENTITY.commit,
        modified = ?build_identity::IDENTITY.modified,
        "remote-coder-codex-gateway starting"
    );

    if let Some(config::Command::Runtime { command }) = args.command.clone() {
        #[cfg(target_os = "macos")]
        platform::macos::scheduling::log_startup(&startup_scheduling);
        return runtime::run(command, args, &sources).await;
    }

    let settings = if recovery_only {
        Settings::load_for_recovery(&sources)?
    } else {
        Settings::load(&sources)?
    };

    info!(
        bind_host = %settings.bind_host,
        port = settings.port,
        lan_port = ?settings.lan_port,
        codex_path = %settings.codex_path.display(),
        codex_version = %settings.codex_version,
        codex_code_mode_host_path = %settings.codex_code_mode_host_path.display(),
        codex_child_env_keys = settings.codex_child_env.len(),
        push_broker_enabled = settings.push_broker_enabled,
        claude_path = %settings.claude.claude_path.display(),
        "loaded settings"
    );

    let _control_owner = runtime::ControlOwnerLease::acquire(
        &runtime::recovery::RecoveryStore::new(runtime::recovery::RecoveryStore::default_path()?),
    )?;
    if !recovery_only {
        tokio::task::spawn_blocking({
            let home = settings.host_paths.home().to_path_buf();
            let claude_home = settings.claude.claude_home.clone();
            move || accounts::claude_migration::run(&home, &claude_home)
        })
        .await??;
    }
    if !recovery_only {
        runtime::retire_codex_accounts(&settings).await?;
    }
    runtime::bootstrap(&settings, recovery_only).await?;
    let codex = Arc::new(if recovery_only {
        CodexAppServer::for_runtime(
            settings.codex_path.clone(),
            settings.codex_child_env.clone(),
        )?
    } else {
        CodexAppServer::new(
            settings.codex_path.clone(),
            settings.codex_child_env.clone(),
        )
    });
    let journal = Journal::open_in(
        settings.host_paths.logs("journal"),
        DEFAULT_LOG_RETENTION_DAYS,
    );
    #[cfg(target_os = "macos")]
    let _scheduling_guard = platform::macos::scheduling::spawn_darwin_background_guard(
        journal.clone(),
        startup_scheduling,
    );
    let devices = Arc::new(DeviceRegistry::open(&settings.host_paths)?);
    let apns = Arc::new(PushService::new(
        settings.push_broker_enabled,
        journal.clone(),
        devices,
        Some(settings.host_paths.state("live-activity.json")),
    ));
    let router = Arc::new(providers::router::Router::new(settings.router.clone())?);
    let codex_router = Arc::new(providers::codex::router::Router::new(Arc::clone(&router)));
    let gateway = Gateway::with_notifier(
        codex,
        apns,
        settings.claude.clone(),
        journal.clone(),
        settings.host_paths.state_directory(),
        if recovery_only {
            None
        } else {
            gateway::calls::CallDeliveryConfig::load(&settings.auth_token, &settings.host_paths)?
        },
        settings.router.as_ref().map(|router| {
            gateway::ExternalAuth::new(Arc::clone(&codex_router), router.codex_account().to_owned())
        }),
        providers::codex::external::ExternalProviders::new(
            settings.external_providers.clone(),
            &settings.host_paths.state_directory(),
        )?,
        settings.user_name.clone(),
    );
    gateway.start().await?;

    let served = serve_started(&settings, &gateway, router, journal.clone(), recovery_only).await;
    let _ = gateway.stop().await;
    info!("gateway stopped");
    journal.drain(JOURNAL_DRAIN_DEADLINE).await;
    served
}

async fn serve_started(
    settings: &Settings,
    gateway: &Arc<Gateway>,
    router: Arc<providers::router::Router>,
    journal: Journal,
    recovery_only: bool,
) -> Result<()> {
    let accounts = accounts::Accounts::open(
        &settings.host_paths,
        Arc::clone(gateway),
        settings.claude.clone(),
    )
    .await?;
    let accounts = Some(accounts);
    let served = serve_http(
        settings,
        gateway,
        router,
        accounts.clone(),
        journal,
        recovery_only,
    )
    .await;
    if let Some(accounts) = accounts {
        accounts.stop().await;
        info!("account gateways stopped");
    }
    served
}

async fn serve_http(
    settings: &Settings,
    gateway: &Arc<Gateway>,
    router: Arc<providers::router::Router>,
    accounts: Option<Arc<accounts::Accounts>>,
    journal: Journal,
    recovery_only: bool,
) -> Result<()> {
    if recovery_only {
        return runtime::install::wait_for_recovery_completion().await;
    }

    info!(
        bind_host = %settings.bind_host,
        port = settings.port,
        "http server starting"
    );
    let installation_credentials = auth::installation_credentials::InstallationCredentials::new(
        settings.host_paths.state("installation-credentials.json"),
    );
    let speech = voice::speech::SpeechRelay::new(
        settings.auth_token.clone(),
        installation_credentials.clone(),
        settings.router.clone(),
        settings.speech_clients.clone(),
        journal.clone(),
    )?;
    let lan = match settings.lan_port {
        Some(lan_port) => match LanListener::bind(lan_port).await {
            Ok(lan) => Some(lan),
            Err(error) => {
                error!(
                    lan_port,
                    "LAN TLS listener unavailable; serving only the plaintext listener: {error:#}"
                );
                None
            }
        },
        None => None,
    };
    if let Some(listener) = &lan {
        gateway.configure_call_tls_endpoint(listener.endpoint().clone())?;
    }
    let relay_route = match (settings.lan_port, &lan) {
        (None, _) => RelayRoute::Absent,
        (Some(_), None) => RelayRoute::Unavailable,
        (Some(_), Some(_)) => {
            match RelayEndpoint::load(&settings.host_paths.state("relay").join("relay.json")) {
                Ok(Some(endpoint)) => {
                    info!(target = %endpoint.target(), "publishing the relay route");
                    RelayRoute::Published(endpoint)
                }
                Ok(None) => RelayRoute::Absent,
                Err(error) => {
                    error!("relay route unavailable: {error:#}");
                    RelayRoute::Unavailable
                }
            }
        }
    };
    let uploads = UploadStore::open_in(settings.host_paths.state("uploads"))?;
    gateway.configure_device_photos(
        uploads.clone(),
        settings.host_paths.home().join("Pictures/RemoteCoder"),
    )?;
    let full_disk_access = platform::macos::full_disk_access::probe(
        std::path::Path::new(platform::macos::full_disk_access::SYSTEM_TCC_DATABASE),
        config::host_profile::FullDiskAccessRequirement::for_this_host()?,
    )
    .await;
    if full_disk_access.required
        && full_disk_access.state != platform::macos::full_disk_access::FullDiskAccess::Granted
    {
        error!(
            state = ?full_disk_access.state,
            detail = ?full_disk_access.detail,
            "this host requires Full Disk Access for the gateway's signing identity; agents will hit privacy prompts"
        );
    }
    journal.runtime("full_disk_access", serde_json::to_value(&full_disk_access)?);
    let app_logs = AppLogStore::new_in(
        settings.host_paths.logs("app-logs"),
        APP_LOG_RETENTION_DAYS,
        APP_LOG_BYTE_CAP,
    );
    app_logs.start_sweeping(journal.clone());
    let state = HttpState {
        full_disk_access,
        router,
        accounts: accounts.clone(),
        auth_token: settings.auth_token.clone(),
        installation_credentials,
        speech,
        gateway: Arc::clone(gateway),
        codex_version: settings.codex_version.clone(),
        codex_code_mode_host_path: settings.codex_code_mode_host_path.clone(),
        app_logs: app_logs.clone(),
        uploads,
        files: crate::files::FileDownloads::default(),
        requests: RequestAdmission::default(),
        journal,
        lan_endpoint: lan.as_ref().map(|lan| lan.endpoint().clone()),
        relay_route,
    };
    let server_res = run_http_server(settings.bind_host.clone(), settings.port, state, lan).await;
    app_logs.stop_sweeping(JOURNAL_DRAIN_DEADLINE).await;

    info!("http server stopped, shutting down");
    if let Err(err) = &server_res {
        error!("http server exited with error: {err:?}");
    }
    server_res
}
