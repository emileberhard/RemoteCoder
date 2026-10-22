use std::collections::HashMap;
use std::net::SocketAddr;
use std::ops::Deref;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use tokio::sync::mpsc;

use crate::gateway::Gateway;
use crate::gateway::calls::CallRecord;
use crate::observability::journal::Journal;
use crate::providers::claude::settings::{ClaudeSettings, ClaudeTestSettings};
use crate::providers::codex::daemon::CodexAppServer;

pub(crate) async fn with_manual_time(test: impl std::future::Future<Output = ()>) {
    tokio::time::pause();
    let (release, held) = std::sync::mpsc::channel::<()>();
    let (expired, deadline) = tokio::sync::oneshot::channel();
    let watchdog = tokio::task::spawn_blocking(move || {
        if held.recv_timeout(std::time::Duration::from_secs(60))
            == Err(std::sync::mpsc::RecvTimeoutError::Timeout)
        {
            let _ = expired.send(());
        }
    });
    tokio::select! {
        biased;
        () = test => {}
        _ = deadline => panic!("test did not finish within the wall-clock hang guard"),
    }
    drop(release);
    watchdog.await.unwrap();
    tokio::time::resume();
}

pub(crate) async fn wait_until(
    what: &'static str,
    mut ready: impl FnMut() -> bool + Send + 'static,
) {
    tokio::task::spawn_blocking(move || {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while !ready() {
            assert!(
                std::time::Instant::now() < deadline,
                "timed out waiting for {what}"
            );
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    })
    .await
    .unwrap();
}

pub(crate) enum ClaudeCliMode {
    RestartAbortedStreaming,
    SuspendLogsInterrupt,
    MessagesAcknowledgeInterrupt(PathBuf),
}

pub(crate) fn write_claude_cli_stub(path: &Path, mode: ClaudeCliMode) {
    use std::os::unix::fs::PermissionsExt;

    let (mode, history) = match mode {
        ClaudeCliMode::RestartAbortedStreaming => ("restart", None),
        ClaudeCliMode::SuspendLogsInterrupt => ("suspend", None),
        ClaudeCliMode::MessagesAcknowledgeInterrupt(history) => ("messages", Some(history)),
    };
    let history = history.map_or_else(
        || "None".to_owned(),
        |path| format!("{:?}", path.to_string_lossy()),
    );
    let script =
        format!("#!/usr/bin/env python3\nMODE = {mode:?}\nHISTORY = {history}\n{CLAUDE_CLI_STUB}");
    std::fs::write(path, script).expect("Claude CLI stub");
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
        .expect("executable Claude CLI stub");
}

const CLAUDE_CLI_STUB: &str = r#"import json, os, signal, sys, time
from pathlib import Path
root = Path(os.environ['CLAUDE_CONFIG_DIR'])
state = Path(os.environ.get('RC_TEST_STATE_DIR', root))
args = sys.argv[1:]
def emit(value):
    print(json.dumps(value), flush=True)
def append(path, value):
    with path.open('a') as log:
        log.write(json.dumps(value) + '\n')
if '--no-session-persistence' in args:
    append(root / 'detached.jsonl', {'argv': args, 'cwd': os.getcwd()})
    if args[-1] == 'hang':
        import subprocess
        child = subprocess.Popen(['sleep', '600'])
        (root / 'detached-child.pid').write_text(str(child.pid))
        time.sleep(600)
    if args[-1] == 'flood':
        sys.stdout.write('x' * (2 * 1024 * 1024))
        sys.exit(0)
    emit({'type': 'system', 'subtype': 'init', 'apiKeySource': 'none', 'fast_mode_state': 'off', 'permissionMode': 'bypassPermissions'})
    emit({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'Detached title'})
    sys.exit(0)
if MODE == 'suspend':
    if '--version' in args:
        print('2.1.282 (Claude Code)')
        sys.exit(0)
session = sys.argv[-1]
cwd = os.environ.get('RC_TEST_CWD', os.getcwd())
slug = ''.join(c if c.isascii() and c.isalnum() else '-' for c in cwd)
settings = json.loads(Path(args[args.index('--settings') + 1]).read_text()) if '--settings' in args else {}
transcript = Path(HISTORY) if MODE == 'messages' else root / 'projects' / slug / (session + '.jsonl')
if MODE == 'restart':
    append(state / 'launches.jsonl', {'argv': args, 'cwd': os.getcwd(), 'configDir': str(root), 'context': json.loads(os.environ['REMOTE_CODER_PARENT_CONTEXT'])})
if MODE == 'messages':
    append(root / 'launches.jsonl', {'argv': args, 'cwd': os.getcwd(), 'fastMode': settings['fastMode'], 'context': json.loads(os.environ['REMOTE_CODER_PARENT_CONTEXT'])})
    orphaned = root / 'orphaned-task'
def record(value):
    append(transcript, value)
def stamp():
    return time.strftime('%Y-%m-%dT%H:%M:%S.000Z', time.gmtime())
if MODE == 'suspend':
    def stop(*_):
        record({'type': 'system', 'subtype': 'exit', 'session_id': session})
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
def call(tool, name, arguments):
    message = {'id': 'msg_' + tool, 'role': 'assistant', 'content': [{'type': 'tool_use', 'id': tool, 'name': name, 'input': arguments}]}
    record({'type': 'assistant', 'isSidechain': False, 'timestamp': stamp(), 'sessionId': session, 'message': message})
    emit({'type': 'assistant', 'session_id': session, 'parent_tool_use_id': None, 'message': message})
def answer(tool, result):
    message = {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': tool, 'content': 'ok'}]}
    record({'type': 'user', 'isSidechain': False, 'timestamp': stamp(), 'sessionId': session, 'message': message, 'toolUseResult': result})
    emit({'type': 'user', 'session_id': session, 'parent_tool_use_id': None, 'message': message, 'tool_use_result': result})
tasks = []
def announce():
    emit({'type': 'system', 'subtype': 'background_tasks_changed', 'session_id': session, 'tasks': tasks})
emit({'type': 'system', 'subtype': 'init', 'session_id': session, 'apiKeySource': 'none', 'fast_mode_state': 'on' if settings.get('fastMode') else 'off', 'permissionMode': 'bypassPermissions'})
if MODE == 'messages' and '--resume' in args and orphaned.exists():
    orphaned.unlink()
    emit({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': session, 'result': '', 'num_turns': 0, 'origin': {'kind': 'task-notification'}})
for line in sys.stdin:
    frame = json.loads(line)
    if frame.get('type') == 'control_cancel_request':
        append(root / 'controls.jsonl', frame)
        continue
    if frame.get('type') == 'control_request':
        request = frame['request']
        if MODE == 'restart':
            append(state / 'controls.jsonl', {'request': request, 'journalPersisted': (state / 'claude-restart-recovery.json').exists()})
            if request['subtype'] == 'interrupt':
                emit({'type': 'result', 'subtype': 'error_during_execution', 'is_error': True, 'terminal_reason': 'aborted_streaming', 'session_id': session})
        elif MODE == 'suspend':
            append(state / 'controls.jsonl', request)
        else:
            append(root / 'controls.jsonl', request)
            if request.get('subtype') == 'interrupt':
                orphaned.touch()
            response = {}
            if request.get('subtype') == 'side_question':
                emit({'type': 'system', 'subtype': 'control_request_progress', 'request_id': frame['request_id'], 'status': 'started', 'session_id': session})
                if request['question'] == 'unanswered':
                    continue
                response = {'response': 'Answer to ' + request['question'], 'synthetic': False}
            emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': frame['request_id'], 'response': response}})
        continue
    if frame.get('shouldQuery') is False:
        continue
    if MODE == 'restart':
        record({'type': 'user', 'uuid': frame['uuid'], 'message': frame['message']})
        append(state / 'received.jsonl', frame)
        emit(frame)
        continue
    if MODE == 'messages':
        append(root / 'received.jsonl', frame)
        record({'type': 'user', 'uuid': frame['uuid'], 'message': frame['message']})
        emit(frame)
        content = frame['message']['content']
        if content == 'initial':
            emit({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': session, 'result': 'ready'})
        elif isinstance(content, str) and content.startswith('reply: '):
            reply = content.removeprefix('reply: ')
            emit({'type': 'assistant', 'uuid': 'reply-' + frame['uuid'], 'message': {'id': 'msg-' + frame['uuid'], 'role': 'assistant', 'content': [{'type': 'text', 'text': reply}]}})
            emit({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': session, 'result': reply, 'user_message_uuids': [frame['uuid']]})
        continue
    record({'type': 'user', 'uuid': frame['uuid'], 'message': frame['message']})
    emit(frame)
    content = frame['message'].get('content')
    text = content if isinstance(content, str) else ' '.join(block.get('text', '') for block in content if isinstance(block, dict))
    if 'start background work' in text:
        call('toolu_agent', 'Agent', {'description': 'Review the diff', 'prompt': 'review', 'run_in_background': True})
        emit({'type': 'system', 'subtype': 'task_started', 'session_id': session, 'task_id': 'agent-task', 'task_type': 'local_agent', 'tool_use_id': 'toolu_agent', 'description': 'Review the diff'})
        answer('toolu_agent', {'agentId': 'agent-task'})
        tasks = [
            {'task_id': 'agent-task', 'task_type': 'local_agent', 'description': 'Review the diff'},
            {'task_id': 'shell-task', 'task_type': 'local_bash', 'description': 'npm run dev'},
            {'task_id': 'ambient-task', 'task_type': 'local_agent', 'description': 'memory', 'ambient': True},
        ]
        announce()
    if 'schedule a wakeup' in text:
        call('toolu_wake', 'ScheduleWakeup', {'delaySeconds': 1200, 'prompt': 'check CI'})
        answer('toolu_wake', {'scheduledFor': int((time.time() + 1200) * 1000), 'clampedDelaySeconds': 1200, 'wasClamped': False})
    if 'create a cron' in text:
        call('toolu_cron', 'CronCreate', {'cron': '*/10 * * * *', 'prompt': 'Check CI', 'recurring': True})
        answer('toolu_cron', {'id': 'cron-1', 'humanSchedule': 'Every 10 minutes', 'recurring': True})
    if 'stall' in text:
        signal.pause()
    if 'hold' in text:
        continue
    emit({'type': 'assistant', 'session_id': session, 'parent_tool_use_id': None, 'message': {'id': 'msg_done', 'role': 'assistant', 'content': [{'type': 'text', 'text': 'done'}]}})
    emit({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'done', 'session_id': session})
"#;

#[derive(Clone)]
pub(crate) struct TestGateway {
    gateway: Arc<Gateway>,
    _claude_settings: Arc<ClaudeTestSettings>,
}

impl TestGateway {
    pub(crate) fn new() -> Self {
        Self::with_codex(
            Arc::new(CodexAppServer::new(
                PathBuf::from("/bin/true"),
                HashMap::new(),
            )),
            None,
        )
    }

    pub(crate) fn with_codex(codex: Arc<CodexAppServer>, turn_state_path: Option<PathBuf>) -> Self {
        Self::with_codex_journal(codex, turn_state_path, Journal::disabled())
    }

    fn with_codex_journal(
        codex: Arc<CodexAppServer>,
        turn_state_path: Option<PathBuf>,
        journal: Journal,
    ) -> Self {
        let claude_settings = Arc::new(ClaudeSettings::isolated_for_test());
        let gateway = Gateway::with_turn_state(
            codex,
            claude_settings.settings.clone(),
            journal,
            turn_state_path,
        );
        Self {
            gateway,
            _claude_settings: claude_settings,
        }
    }

    pub(crate) fn with_native_runtime(directory: &Path) -> Self {
        Self::with_native_runtime_journal(directory, Journal::disabled())
    }

    pub(crate) fn with_native_runtime_journal(directory: &Path, journal: Journal) -> Self {
        let pid_dir = directory.join("codex/app-server-daemon");
        std::fs::create_dir_all(&pid_dir).expect("Codex daemon directory");
        std::fs::write(
            pid_dir.join("app-server.pid"),
            serde_json::json!({
                "pid": std::process::id(),
                "processIdentity": current_process_identity(),
            })
            .to_string(),
        )
        .expect("Codex daemon pid record");
        Self::with_codex_journal(
            Arc::new(CodexAppServer::new_for_test_socket(directory.join("codex"))),
            Some(directory.join("active-codex-turns.json")),
            journal,
        )
    }

    pub(crate) fn with_settings(
        codex: Arc<CodexAppServer>,
        settings: ClaudeSettings,
        claude_settings: Arc<ClaudeTestSettings>,
    ) -> Self {
        Self::with_journal(codex, settings, claude_settings, Journal::disabled())
    }

    pub(crate) fn with_journal(
        codex: Arc<CodexAppServer>,
        settings: ClaudeSettings,
        claude_settings: Arc<ClaudeTestSettings>,
        journal: Journal,
    ) -> Self {
        let gateway = Gateway::with_turn_state(codex, settings, journal, None);
        Self {
            gateway,
            _claude_settings: claude_settings,
        }
    }
}

impl Deref for TestGateway {
    type Target = Arc<Gateway>;

    fn deref(&self) -> &Self::Target {
        &self.gateway
    }
}

pub(crate) struct FakeControl {
    pub(crate) requests: mpsc::Receiver<String>,
}

impl FakeControl {
    pub(crate) async fn attach(gateway: &Gateway, capacity: usize) -> Self {
        let (tx, requests) = mpsc::channel(capacity);
        gateway.attach_fake_control(tx).await;
        Self { requests }
    }
}

pub(crate) async fn serve(router: axum::Router) -> (SocketAddr, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("test listener");
    let address = listener.local_addr().expect("test address");
    let task = tokio::spawn(async move {
        axum::serve(listener, router).await.expect("test server");
    });
    (address, task)
}

pub(crate) async fn seed_call(gateway: &Gateway, record: CallRecord) {
    gateway.seed_call_for_test(record).await;
}

pub(crate) enum LifecycleMode {
    CaptureGrant,
    RecordFencedActions,
    RecordActions,
}

pub(crate) struct FakeLifecycleCodex {
    pub(crate) path: PathBuf,
    pub(crate) reply: PathBuf,
    pub(crate) actions: PathBuf,
    pub(crate) grant_capture: PathBuf,
}

impl FakeLifecycleCodex {
    pub(crate) fn new(directory: &Path, mode: LifecycleMode) -> Self {
        use std::os::unix::fs::PermissionsExt;

        let path = directory.join("codex");
        let script = match mode {
            LifecycleMode::CaptureGrant => {
                "#!/bin/sh\nif [ \"$3\" = start ]; then /bin/cp \"$CODEX_INTERNAL_RESTART_RECOVERY_GRANT_FILE\" \"$GRANT_CAPTURE\"; fi\nexec /bin/cat \"$LIFECYCLE_REPLY\"\n"
            }
            LifecycleMode::RecordFencedActions => {
                "#!/bin/sh\nprintf '%s:%s\\n' \"$3\" \"${CODEX_APP_SERVER_START_FENCED:-0}\" >> \"$LIFECYCLE_ACTIONS\"\nexec /bin/cat \"$LIFECYCLE_REPLY\"\n"
            }
            LifecycleMode::RecordActions => {
                "#!/bin/sh\nprintf '%s\\n' \"$3\" >> \"$LIFECYCLE_ACTIONS\"\nexec /bin/cat \"$LIFECYCLE_REPLY\"\n"
            }
        };
        std::fs::write(&path, script).expect("fake native Codex");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755))
            .expect("executable");
        Self {
            path,
            reply: directory.join("lifecycle.json"),
            actions: directory.join("actions.log"),
            grant_capture: directory.join("captured-grant.json"),
        }
    }

    pub(crate) fn server(&self, native: &Path) -> CodexAppServer {
        let environment = HashMap::from([
            ("CODEX_HOME".to_owned(), native.display().to_string()),
            (
                "LIFECYCLE_REPLY".to_owned(),
                self.reply.display().to_string(),
            ),
            (
                "LIFECYCLE_ACTIONS".to_owned(),
                self.actions.display().to_string(),
            ),
            (
                "GRANT_CAPTURE".to_owned(),
                self.grant_capture.display().to_string(),
            ),
        ]);
        CodexAppServer::new(self.path.clone(), environment)
    }

    pub(crate) fn write_reply(&self, server: &CodexAppServer) {
        std::fs::write(
            &self.reply,
            serde_json::to_vec(&serde_json::json!({
                "backend": "pid", "pid": std::process::id(),
                "managedCodexPath": self.path,
                "managedCodexVersion": crate::config::REQUIRED_CODEX_VERSION,
                "appServerVersion": crate::config::REQUIRED_CODEX_VERSION,
                "socketPath": server.socket_path(),
            }))
            .expect("lifecycle JSON"),
        )
        .expect("lifecycle reply");
    }
}

#[test]
fn gateway_fixture_owns_its_claude_home_until_the_last_clone_is_dropped() {
    let fixture = TestGateway::new();
    let home = fixture._claude_settings.root_path().to_path_buf();
    let clone = fixture.clone();
    drop(fixture);
    assert!(home.exists());
    drop(clone);
    assert!(!home.exists());
}

#[cfg(target_os = "macos")]
pub(crate) fn current_process_identity() -> serde_json::Value {
    let pid = std::process::id() as i32;
    let mut boot = [0u8; 37];
    let mut boot_size = boot.len();
    assert_eq!(
        unsafe {
            libc::sysctlbyname(
                c"kern.bootsessionuuid".as_ptr(),
                boot.as_mut_ptr().cast(),
                &mut boot_size,
                std::ptr::null_mut(),
                0,
            )
        },
        0
    );
    assert_eq!(boot_size, boot.len());
    let boot_id = std::ffi::CStr::from_bytes_with_nul(&boot)
        .expect("macOS boot UUID")
        .to_str()
        .expect("UTF-8 boot UUID");
    #[repr(C)]
    struct UniqueInfo {
        executable_uuid: [u8; 16],
        unique_id: u64,
        parent_unique_id: u64,
        reserved: [u64; 3],
    }
    let mut unique = std::mem::MaybeUninit::<UniqueInfo>::uninit();
    let unique_size = std::mem::size_of::<UniqueInfo>() as libc::c_int;
    assert_eq!(
        unsafe { libc::proc_pidinfo(pid, 17, 1, unique.as_mut_ptr().cast(), unique_size) },
        unique_size
    );
    let unique_id = unsafe { unique.assume_init() }.unique_id;
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::uninit();
    let info_size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    assert_eq!(
        unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                1,
                info.as_mut_ptr().cast(),
                info_size,
            )
        },
        info_size
    );
    let info = unsafe { info.assume_init() };
    serde_json::json!({
        "bootId": boot_id,
        "uniqueId": unique_id,
        "startSeconds": info.pbi_start_tvsec,
        "startMicroseconds": info.pbi_start_tvusec,
    })
}

#[cfg(target_os = "linux")]
pub(crate) fn current_process_identity() -> serde_json::Value {
    let boot_id =
        std::fs::read_to_string("/proc/sys/kernel/random/boot_id").expect("Linux boot UUID");
    let stat = std::fs::read_to_string(format!("/proc/{}/stat", std::process::id()))
        .expect("current process stat");
    let (_, fields) = stat.rsplit_once(") ").expect("process stat fields");
    let start_ticks: u64 = fields
        .split_whitespace()
        .nth(19)
        .expect("process start ticks")
        .parse()
        .expect("numeric process start ticks");
    serde_json::json!({"bootId": boot_id.trim(), "startTicks": start_ticks})
}

pub(crate) struct LiveActivityProbe {
    pub(crate) service: Arc<crate::push::PushService>,
    pub(crate) requests: Arc<std::sync::Mutex<Vec<serde_json::Value>>>,
    server: tokio::task::JoinHandle<()>,
}

impl LiveActivityProbe {
    pub(crate) async fn new(path: Option<PathBuf>) -> Self {
        use axum::{Json, Router, extract::State, routing::post};
        let requests = Arc::new(std::sync::Mutex::new(Vec::new()));
        let app = Router::new()
            .route(
                "/v1/internal/live-activity",
                post(
                    |State(requests): State<Arc<std::sync::Mutex<Vec<serde_json::Value>>>>,
                     Json(body): Json<serde_json::Value>| async move {
                        requests.lock().unwrap().push(body);
                        Json(serde_json::json!({"apns_id":"fixture"}))
                    },
                ),
            )
            .with_state(requests.clone());
        let (address, server) = serve(app).await;
        let service = Arc::new(
            crate::push::PushService::fixture_broker(
                format!("http://{address}"),
                Journal::disabled(),
                path,
            )
            .await,
        );
        Self {
            service,
            requests,
            server,
        }
    }
}

impl Drop for LiveActivityProbe {
    fn drop(&mut self) {
        self.server.abort();
    }
}

pub(crate) fn claude_event(
    notification: crate::providers::claude::ClaudeNotification,
) -> serde_json::Value {
    match notification {
        crate::providers::claude::ClaudeNotification::Event(value) => value,
        crate::providers::claude::ClaudeNotification::IngressBarrier(_) => {
            panic!("Provider fixture expected a Claude event")
        }
    }
}
