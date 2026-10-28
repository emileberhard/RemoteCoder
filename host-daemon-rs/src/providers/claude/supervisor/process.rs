use super::{
    ClaudeRuntime, ClaudeRuntimeSettings, ClaudeSupervisor, McpRuntimeAccess, ProcessAdmission,
    ProcessRegistry, SpawnedRuntime, TurnStartError, claude_stream_args, runtime_settings_path,
    write_private_file,
};
use crate::ids::is_session_uuid;
use crate::providers::claude::exec::ClaudeCommand;
use crate::providers::claude::supervisor::input_writer::InputWriter;
use crate::providers::claude::translate::narration::SEND_USER_MESSAGE_ENV;
use crate::providers::claude::wake_hold::WakeHold;
use crate::providers::claude::{ClaudeTurnRequest, claude_thread_id, exec as claude_exec};
use crate::rpc::error::RpcCode;
use serde_json::json;
use std::collections::HashMap;
use std::fs;
use std::process::Stdio;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::process::{ChildStderr, ChildStdin, ChildStdout};
use tokio::sync::Mutex;
use tracing::warn;

impl ClaudeSupervisor {
    fn session_launch_error(&self, request: &ClaudeTurnRequest) -> Option<String> {
        let account = "the host-default profile";
        if !is_session_uuid(&request.session_uuid) {
            return Some(format!(
                "Claude session id {} is not a UUID; refusing to launch it in {account}",
                request.session_uuid
            ));
        }
        if request.first_turn {
            return match self.is_minted(&claude_thread_id(&request.session_uuid)) {
                Ok(true) => None,
                Ok(false) => Some(format!(
                    "Claude history for session {} is missing from {account} ({}) and this gateway did not create that session; refusing to start a new conversation under an existing id",
                    request.session_uuid,
                    self.settings.claude_home.display()
                )),
                Err(error) => Some(format!(
                    "Claude session {} has an unreadable creation record in {account}: {error:#}; refusing to launch it",
                    request.session_uuid
                )),
            };
        }
        self.session_history(&request.cwd, &request.session_uuid)
            .is_none()
            .then(|| {
                format!(
                    "Claude history for session {} is missing from {account}: expected {} for cwd {}; refusing to start a new conversation",
                    request.session_uuid,
                    crate::providers::claude::timeline::session_path_for_cwd(
                        &self.settings.claude_home,
                        &request.cwd,
                        &request.session_uuid
                    )
                    .display(),
                    request.cwd
                )
            })
    }

    /// Spawns `command` as the leader of its own process group, registered
    /// so shutdown reaches it and reaped when it exits. The returned admission
    /// kills the group when dropped unless the caller accepts it.
    pub(super) fn spawn_group(
        &self,
        registry: &mut ProcessRegistry,
        mut command: ClaudeCommand,
    ) -> std::io::Result<OwnedGroup> {
        if registry.closing {
            return Err(std::io::Error::other("Claude runtime owner is stopping"));
        }
        command.kill_on_drop(false);
        // Own the whole tree so an interrupt reaches the agent's tool children.
        unsafe {
            command.pre_exec(|| {
                nix::unistd::setsid().map_err(std::io::Error::other)?;
                Ok(())
            });
        }
        let mut child = command.spawn()?;
        let process_group_id = child
            .id()
            .ok_or_else(|| std::io::Error::other("claude exited before it could be tracked"))?
            as i32;
        let admission = ProcessAdmission::new(process_group_id, Arc::clone(&self.process_registry));
        #[cfg(target_os = "macos")]
        let identity = crate::platform::process::identify(process_group_id)
            .map(|identity| identity.map(|identity| identity.started_micros));
        #[cfg(not(target_os = "macos"))]
        let identity: anyhow::Result<Option<u64>> = Ok(None);
        let (reaped, reap_state) = tokio::sync::watch::channel(ReapState::Running);
        let stdin = child.stdin.take();
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        registry.groups.insert(process_group_id);
        let processes = Arc::clone(&self.process_registry);
        self.reapers.spawn(async move {
            let outcome = match child.wait().await {
                Ok(status) => ReapState::Exited(status),
                Err(error) => {
                    warn!(process_group_id, %error, "reaping Claude child failed");
                    ReapState::Failed(error.to_string())
                }
            };
            reaped.send_replace(outcome);
            processes
                .lock()
                .expect("Claude process registry poisoned")
                .groups
                .remove(&process_group_id);
        });
        let group = OwnedGroup {
            admission,
            process_group_id,
            process_started_micros: identity.map_err(std::io::Error::other)?,
            reaped: reap_state,
            stdin,
            stdout,
            stderr,
        };
        Ok(group)
    }

    pub(super) fn spawn_runtime(
        &self,
        request: &ClaudeTurnRequest,
        launch: &super::jobs::LaunchPolicy,
    ) -> Result<SpawnedRuntime, TurnStartError> {
        if let Some(message) = self.session_launch_error(request) {
            self.journal.runtime(
                "spawn_refused",
                json!({
                    "threadId": request.thread_id,
                    "sessionUuid": request.session_uuid,
                    "cwd": request.cwd,
                    "firstTurn": request.first_turn,
                    "error": message,
                }),
            );
            return Err(TurnStartError {
                data: None,
                code: RpcCode::InvalidParams,
                message,
            });
        }
        self.spawn_process(request, launch)
            .map_err(|err| TurnStartError {
                data: None,
                code: RpcCode::Internal,
                message: format!("failed to spawn claude: {err}"),
            })
    }

    fn spawn_process(
        &self,
        request: &ClaudeTurnRequest,
        launch: &super::jobs::LaunchPolicy,
    ) -> std::io::Result<SpawnedRuntime> {
        let wakes = if request.first_turn {
            WakeHold::default()
        } else {
            WakeHold::resuming(
                self.session_history(&request.cwd, &request.session_uuid)
                    .and_then(|path| fs::metadata(path).ok())
                    .map_or(0, |metadata| metadata.len()),
            )
        };
        let mut registry = self
            .process_registry
            .lock()
            .expect("Claude process registry poisoned");
        if registry.closing {
            return Err(std::io::Error::other("Claude runtime owner is stopping"));
        }
        // Tools ride each spawn: nothing is written to Claude's own config, so
        // they follow the runtime's dimensions and vanish when it retires.
        let mcp = match launch.scope() {
            crate::agents::jobs::model::ToolScope::Full => self.prepare_mcp_access(request),
            crate::agents::jobs::model::ToolScope::ReadOnly { .. } => None,
        };
        let mut args = claude_stream_args(
            request,
            mcp.as_ref().map(|access| access.config_path.as_path()),
        );
        launch.apply_args(&mut args);
        let mut command = claude_exec::command(&self.settings, &args)?;
        launch.apply_env(&mut command);
        command.env(SEND_USER_MESSAGE_ENV, "1");
        if !self.settings.mcp_endpoint.is_empty() {
            let endpoint =
                reqwest::Url::parse(&self.settings.mcp_endpoint).map_err(std::io::Error::other)?;
            let port = endpoint
                .port_or_known_default()
                .ok_or_else(|| std::io::Error::other("Gateway callback port is unavailable"))?;
            command.env(
                "REMOTE_CODER_PARENT_CONTEXT",
                json!({
                    "thread_id": request.thread_id,
                    "port": port,
                })
                .to_string(),
            );
        }
        command
            .current_dir(&request.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let OwnedGroup {
            admission,
            process_group_id,
            process_started_micros,
            reaped,
            stdin,
            stdout,
            stderr,
        } = self.spawn_group(&mut registry, command)?;
        let stdin = stdin.ok_or_else(|| std::io::Error::other("Claude stdin was not piped"))?;
        let stdout = stdout.ok_or_else(|| std::io::Error::other("Claude stdout was not piped"))?;
        let stderr_ring = Arc::new(Mutex::new(Vec::new()));

        Ok(SpawnedRuntime {
            admission,
            runtime: ClaudeRuntime {
                input: InputWriter::spawn(stdin),
                pending_controls: HashMap::new(),
                process_group_id,
                process_started_micros,
                reaped,
                launch: launch.clone(),
                session_uuid: request.session_uuid.clone(),
                settings: Some(ClaudeRuntimeSettings::requested(request)),
                cwd: request.cwd.clone(),
                initialized: false,
                active_turn: None,
                background_tasks: Vec::new(),
                children: crate::agents::claude::Projection::default(),
                children_generation: SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos(),
                lifecycle_generation: 1,
                stderr_ring,
                _mcp: mcp,
                idle: None,
                wakes,
            },
            process_group_id,
            stdout,
            stderr,
        })
    }

    /// Mints this runtime's MCP token and writes the `--mcp-config` file it is
    /// passed. Returns `None` when the file cannot be written, in which case the
    /// turn still runs — without RemoteCoder's tools and session context rather
    /// than not at all.
    pub(super) fn prepare_mcp_access(
        &self,
        request: &ClaudeTurnRequest,
    ) -> Option<McpRuntimeAccess> {
        let token = self
            .mcp_tokens
            .mint(&request.thread_id, &request.session_uuid);
        // The file name is unrelated to both the session and the token: a
        // retiring runtime deletes its own file by path, and two runtimes for
        // one session must never collide on it.
        let config_path = self
            .settings
            .mcp_config_dir
            .join(format!("{}.json", crate::agents::mcp::config_file_id()));
        let config = json!({
            "mcpServers": {
                crate::agents::tools::NAMESPACE: {
                    "type": "http",
                    "url": self.settings.mcp_endpoint,
                    // In the file, not in argv: the token must not show up in ps.
                    "headers": { "Authorization": format!("Bearer {token}") },
                }
            }
        });

        let prepared = (|| {
            let executable = crate::providers::claude::notification_hook::validated_executable(
                &std::env::current_exe()?,
            )?;
            let settings = json!({"fastMode":request.selection.fast,"hooks":{
                "PreToolUse":crate::providers::claude::notification_hook::hooks(
                    &executable,
                    &config_path,
                    &request.session_uuid,
                ),
                "SessionStart":crate::providers::claude::session_context::hooks(&executable),
            }});
            write_private_file(&runtime_settings_path(&config_path), &settings.to_string())?;
            write_private_file(&config_path, &config.to_string())
        })();
        if let Err(error) = prepared {
            self.journal.runtime(
                "notificationToolsUnavailable",
                json!({
                    "threadId":request.thread_id,"reason":"runtimeNotificationSetupFailed"
                }),
            );
            warn!(
                path = %config_path.display(),
                %error,
                "could not write the Claude MCP config; this turn runs without RemoteCoder tools or session context"
            );
            self.mcp_tokens.revoke_token(&token);
            let _ = fs::remove_file(&config_path);
            let _ = fs::remove_file(runtime_settings_path(&config_path));
            return None;
        }

        Some(McpRuntimeAccess {
            tokens: self.mcp_tokens.clone(),
            token,
            config_path,
        })
    }

    pub(super) fn start_runtime_tasks(
        self: &Arc<Self>,
        thread_id: String,
        process_group_id: i32,
        stdout: ChildStdout,
        stderr: Option<ChildStderr>,
    ) {
        if let Some(stderr) = stderr {
            let agent = Arc::clone(self);
            let thread_id = thread_id.clone();
            self.io_tasks
                .spawn_graceful("Claude stderr", move |shutdown| async move {
                    agent
                        .read_stderr(thread_id, process_group_id, stderr, shutdown)
                        .await;
                    Ok(())
                });
        }
        self.schedule_runtime_start_timeout(thread_id.clone(), process_group_id);
        let agent = Arc::clone(self);
        self.io_tasks
            .spawn_graceful("Claude stdout", move |shutdown| async move {
                agent
                    .read_runtime_stream(thread_id, process_group_id, stdout, shutdown)
                    .await;
                Ok(())
            });
    }
}

pub(super) struct OwnedGroup {
    pub(super) admission: ProcessAdmission,
    pub(super) process_group_id: i32,
    pub(super) process_started_micros: Option<u64>,
    pub(super) reaped: tokio::sync::watch::Receiver<ReapState>,
    pub(super) stdin: Option<ChildStdin>,
    pub(super) stdout: Option<ChildStdout>,
    pub(super) stderr: Option<ChildStderr>,
}

#[derive(Clone, Debug)]
pub(super) enum ReapState {
    Running,
    Exited(std::process::ExitStatus),
    Failed(String),
}
