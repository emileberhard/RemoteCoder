use serde_json::{Map, Value};

use super::error::{RpcCode, RpcData, RpcError};

pub(crate) const MAX_REQUEST_ID_BYTES: usize = 512;

pub(crate) fn validate_request_id(id: &Value) -> Result<(), RpcError> {
    match id {
        Value::Null => Ok(()),
        Value::Number(number) if number.is_i64() => Ok(()),
        Value::String(id) if id.len() <= MAX_REQUEST_ID_BYTES => Ok(()),
        Value::String(id) => Err(RpcError::new(
            RpcCode::Capacity,
            "Request identifier exceeds the byte limit",
        )
        .with_data(RpcData::ByteCapacity {
            resource: "request identifier bytes",
            actual_bytes: id.len(),
            limit: MAX_REQUEST_ID_BYTES,
        })),
        _ => Err(RpcError::new(
            RpcCode::InvalidRequest,
            "Request identifier must be a string or signed integer",
        )),
    }
}

/// Decides whether a client request belongs to the Claude provider.
///
/// Only the thread-scoped methods are eligible. `command/exec`,
/// `fs/readDirectory`, `daemon/*`, and `initialize` stay Codex-only regardless
/// of what the params say, so a mislabelled request cannot lose the shared
/// upstream.
pub(crate) fn claude_route(method: &str, obj: &serde_json::Map<String, Value>) -> bool {
    match method_spec(method).claude {
        Some(ClaudeSpec {
            scope: ClaudeScope::Always,
            ..
        }) => true,
        None => false,
        Some(ClaudeSpec {
            scope: ClaudeScope::ThreadScoped,
            ..
        }) => {
            let Some(params) = obj.get("params").and_then(Value::as_object) else {
                return false;
            };
            if let Some(thread_id) = params.get("threadId").and_then(Value::as_str) {
                return crate::providers::claude::is_claude_thread_id(thread_id);
            }
            params.get("provider").and_then(Value::as_str) == Some("claude")
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RequestLifetime {
    Connection,
    Query,
    Status,
    Command,
    Urgent,
}

#[derive(Clone, Copy)]
pub(crate) enum ClaudeScope {
    Always,
    ThreadScoped,
}

#[derive(Clone, Copy)]
pub(crate) struct ClaudeSpec {
    pub(crate) scope: ClaudeScope,
    pub(crate) lifetime: RequestLifetime,
    pub(crate) method: ClaudeMethod,
}

#[derive(Clone, Copy)]
pub(crate) enum ClaudeMethod {
    Status,
    ThreadList,
    ThreadStart,
    ThreadFork,
    ThreadRead,
    ThreadResume,
    ThreadRelease,
    Message,
    TurnStart,
    ThreadCompactStart,
    TurnSteer,
    TurnInterrupt,
    ItemsPage,
    TurnsPage,
}

#[derive(Clone, Copy)]
pub(crate) enum OwnedRoute {
    Native,
    NativeMutation,
    NativeQueue,
    NativeCompaction,
    Agents,
    AgentJobs,
    Sessions,
    Cluster,
    AgentRoutes,
    Calls,
    Voice,
    VoiceSession,
    Navigation,
    Devices,
    DeviceTools,
    Questions,
    Metadata,
    Marks,
    Favorites,
    Preferences,
    Projects,
    Settings,
    Interrupt,
    ActiveTurns,
    Execution,
    LiveActivity,
    ReplayNotifications,
    HostInfo,
    Rename,
    RegenerateTitle,
    Subscriptions,
    ClaudeLiveCheckpoint,
    Automations,
    TakeOver,
    ModelList,
}

#[derive(Clone, Copy)]
pub(crate) struct MethodSpec {
    method: MethodMatch,
    pub(crate) route: OwnedRoute,
    pub(crate) lifetime: Option<RequestLifetime>,
    pub(crate) claude: Option<ClaudeSpec>,
    pub(crate) new_work: bool,
    pub(crate) admission: bool,
    pub(crate) identity: bool,
}

#[derive(Clone, Copy)]
enum MethodMatch {
    Exact(&'static str),
    Prefix(&'static str),
}

const NEW_WORK: u8 = 1;
const ADMISSION: u8 = 2;
const IDENTITY: u8 = 4;

macro_rules! spec {
    ($method:literal, $route:ident, $lifetime:expr, $scope:ident, $claude_lifetime:expr, $flags:expr, $handler:ident) => {
        MethodSpec {
            method: MethodMatch::Exact($method),
            route: OwnedRoute::$route,
            lifetime: $lifetime,
            claude: Some(ClaudeSpec {
                scope: ClaudeScope::$scope,
                lifetime: $claude_lifetime,
                method: ClaudeMethod::$handler,
            }),
            new_work: $flags & NEW_WORK != 0,
            admission: $flags & ADMISSION != 0,
            identity: $flags & IDENTITY != 0,
        }
    };
    ($method:literal, $route:ident, $lifetime:expr, $flags:expr) => {
        MethodSpec {
            method: MethodMatch::Exact($method),
            route: OwnedRoute::$route,
            lifetime: $lifetime,
            claude: None,
            new_work: $flags & NEW_WORK != 0,
            admission: $flags & ADMISSION != 0,
            identity: $flags & IDENTITY != 0,
        }
    };
}

macro_rules! prefix_spec {
    ($method:literal, $route:ident, $lifetime:expr) => {
        MethodSpec {
            method: MethodMatch::Prefix($method),
            route: OwnedRoute::$route,
            lifetime: $lifetime,
            claude: None,
            new_work: false,
            admission: false,
            identity: false,
        }
    };
}

const METHOD_SPECS: &[MethodSpec] = &[
    prefix_spec!("cluster/", Cluster, Some(RequestLifetime::Command)),
    prefix_spec!("agent/cluster/", Cluster, Some(RequestLifetime::Command)),
    prefix_spec!("agent/parent/", Cluster, Some(RequestLifetime::Command)),
    prefix_spec!(
        "agent/conversation/",
        Cluster,
        Some(RequestLifetime::Command)
    ),
    spec!(
        "agent/jobs/admit",
        Cluster,
        Some(RequestLifetime::Command),
        NEW_WORK
    ),
    spec!(
        "agent/jobs/deliver",
        Cluster,
        Some(RequestLifetime::Command),
        0
    ),
    spec!(
        "agent/routes/register",
        AgentRoutes,
        Some(RequestLifetime::Connection),
        0
    ),
    spec!(
        "agent/routes/ack",
        AgentRoutes,
        Some(RequestLifetime::Connection),
        0
    ),
    spec!(
        "agent/context/capture",
        AgentJobs,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "agent/context/read",
        AgentJobs,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "agent/context/setTitle",
        AgentJobs,
        Some(RequestLifetime::Command),
        0
    ),
    spec!(
        "agent/jobs/start",
        AgentJobs,
        Some(RequestLifetime::Command),
        NEW_WORK
    ),
    spec!(
        "agent/jobs/continue",
        AgentJobs,
        Some(RequestLifetime::Command),
        NEW_WORK
    ),
    spec!(
        "agent/jobs/read",
        AgentJobs,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "agent/jobs/list",
        AgentJobs,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "agent/messages/read",
        AgentJobs,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "agent/jobs/message",
        AgentJobs,
        Some(RequestLifetime::Command),
        NEW_WORK
    ),
    spec!(
        "agent/jobs/stop",
        AgentJobs,
        Some(RequestLifetime::Urgent),
        0
    ),
    spec!(
        "agent/jobs/dismiss",
        AgentJobs,
        Some(RequestLifetime::Command),
        0
    ),
    spec!("turn/inspect", Execution, Some(RequestLifetime::Query), 0),
    spec!(
        "device/tools/declare",
        DeviceTools,
        Some(RequestLifetime::Command),
        0
    ),
    spec!(
        "device/tool/result",
        DeviceTools,
        Some(RequestLifetime::Command),
        0
    ),
    spec!(
        "claude/status",
        Native,
        None,
        Always,
        RequestLifetime::Query,
        0,
        Status
    ),
    spec!(
        "claude/thread/list",
        Native,
        None,
        Always,
        RequestLifetime::Query,
        0,
        ThreadList
    ),
    spec!(
        "thread/start",
        Native,
        None,
        ThreadScoped,
        RequestLifetime::Command,
        NEW_WORK | ADMISSION | IDENTITY,
        ThreadStart
    ),
    spec!(
        "thread/resume",
        Native,
        None,
        ThreadScoped,
        RequestLifetime::Command,
        NEW_WORK | ADMISSION | IDENTITY,
        ThreadResume
    ),
    spec!(
        "thread/fork",
        Native,
        None,
        ThreadScoped,
        RequestLifetime::Command,
        NEW_WORK | ADMISSION | IDENTITY,
        ThreadFork
    ),
    spec!(
        "thread/read",
        Native,
        None,
        ThreadScoped,
        RequestLifetime::Query,
        0,
        ThreadRead
    ),
    spec!(
        "thread/items/list",
        Native,
        None,
        ThreadScoped,
        RequestLifetime::Query,
        0,
        ItemsPage
    ),
    spec!(
        "thread/turns/list",
        Native,
        None,
        ThreadScoped,
        RequestLifetime::Query,
        0,
        TurnsPage
    ),
    spec!("thread/name/set", Rename, Some(RequestLifetime::Command), 0),
    spec!(
        "conversation/title/regenerate",
        RegenerateTitle,
        Some(RequestLifetime::Command),
        NEW_WORK | ADMISSION
    ),
    spec!(
        "conversation/subscriptions/set",
        Subscriptions,
        Some(RequestLifetime::Connection),
        0
    ),
    spec!(
        "claude/thread/liveCheckpoint",
        ClaudeLiveCheckpoint,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "claude/thread/release",
        Native,
        None,
        ThreadScoped,
        RequestLifetime::Command,
        0,
        ThreadRelease
    ),
    spec!(
        "claude/message",
        Native,
        None,
        ThreadScoped,
        RequestLifetime::Command,
        NEW_WORK | ADMISSION | IDENTITY,
        Message
    ),
    spec!(
        "turn/start",
        Native,
        None,
        ThreadScoped,
        RequestLifetime::Command,
        NEW_WORK | ADMISSION | IDENTITY,
        TurnStart
    ),
    spec!(
        "turn/steer",
        Native,
        None,
        ThreadScoped,
        RequestLifetime::Command,
        ADMISSION | IDENTITY,
        TurnSteer
    ),
    spec!(
        "turn/interrupt",
        Interrupt,
        Some(RequestLifetime::Urgent),
        ThreadScoped,
        RequestLifetime::Urgent,
        0,
        TurnInterrupt
    ),
    spec!(
        "thread/goal/set",
        NativeMutation,
        Some(RequestLifetime::Command),
        NEW_WORK | ADMISSION
    ),
    spec!(
        "thread/inject_items",
        NativeMutation,
        Some(RequestLifetime::Command),
        ADMISSION
    ),
    spec!(
        "thread/queue/add",
        NativeQueue,
        Some(RequestLifetime::Command),
        NEW_WORK | ADMISSION | IDENTITY
    ),
    spec!(
        "thread/queue/start",
        NativeQueue,
        Some(RequestLifetime::Command),
        NEW_WORK | ADMISSION | IDENTITY
    ),
    spec!(
        "thread/queue/delete",
        NativeQueue,
        Some(RequestLifetime::Command),
        ADMISSION | IDENTITY
    ),
    spec!("thread/queue/list", Native, None, 0),
    spec!(
        "thread/compact/start",
        NativeCompaction,
        Some(RequestLifetime::Command),
        ThreadScoped,
        RequestLifetime::Command,
        NEW_WORK | ADMISSION | IDENTITY,
        ThreadCompactStart
    ),
    spec!("thread/realtime/start", Native, None, NEW_WORK),
    spec!("review/start", Native, None, ADMISSION | IDENTITY),
    spec!(
        "conversation/agents/list",
        Agents,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "conversation/agents/read",
        Agents,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "conversation/agents/classify",
        Agents,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "conversation/agents/action",
        Agents,
        Some(RequestLifetime::Command),
        ADMISSION | IDENTITY
    ),
    spec!(
        "conversation/questions/read",
        Questions,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "conversation/question/dismiss",
        Questions,
        Some(RequestLifetime::Command),
        0
    ),
    spec!(
        "conversation/metadata/read",
        Metadata,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "conversation/metadata/update",
        Metadata,
        Some(RequestLifetime::Command),
        NEW_WORK | ADMISSION
    ),
    spec!(
        "conversation/marks/read",
        Marks,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "conversation/marks/update",
        Marks,
        Some(RequestLifetime::Command),
        0
    ),
    spec!(
        "directory/favorites/read",
        Favorites,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "directory/favorites/update",
        Favorites,
        Some(RequestLifetime::Command),
        0
    ),
    spec!(
        "preferences/read",
        Preferences,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "preferences/update",
        Preferences,
        Some(RequestLifetime::Command),
        0
    ),
    spec!(
        "conversation/projects/resolve",
        Projects,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "conversation/settings/update",
        Settings,
        Some(RequestLifetime::Command),
        NEW_WORK | ADMISSION
    ),
    spec!(
        "voice/session/status",
        Voice,
        Some(RequestLifetime::Query),
        0
    ),
    spec!("voice/listVoices", Voice, Some(RequestLifetime::Query), 0),
    spec!(
        "voice/session/connected",
        Voice,
        Some(RequestLifetime::Command),
        0
    ),
    spec!(
        "voice/session/start",
        VoiceSession,
        Some(RequestLifetime::Command),
        NEW_WORK | ADMISSION | IDENTITY
    ),
    spec!(
        "voice/session/stop",
        VoiceSession,
        Some(RequestLifetime::Urgent),
        0
    ),
    spec!(
        "devices/register",
        Devices,
        Some(RequestLifetime::Command),
        0
    ),
    spec!(
        "devices/unregister",
        Devices,
        Some(RequestLifetime::Urgent),
        0
    ),
    spec!("calls/host", Calls, Some(RequestLifetime::Query), 0),
    spec!("calls/status", Calls, Some(RequestLifetime::Query), 0),
    spec!(
        "calls/media/details",
        Calls,
        Some(RequestLifetime::Query),
        0
    ),
    spec!("calls/stop", Calls, Some(RequestLifetime::Urgent), 0),
    spec!("calls/end", Calls, Some(RequestLifetime::Urgent), 0),
    spec!(
        "calls/device/unregister",
        Calls,
        Some(RequestLifetime::Urgent),
        0
    ),
    spec!(
        "calls/request",
        Calls,
        Some(RequestLifetime::Command),
        NEW_WORK | ADMISSION
    ),
    spec!(
        "calls/answer",
        Calls,
        Some(RequestLifetime::Command),
        NEW_WORK | ADMISSION
    ),
    spec!(
        "calls/device/register",
        Calls,
        Some(RequestLifetime::Command),
        NEW_WORK | ADMISSION
    ),
    spec!(
        "calls/media/attach",
        Calls,
        Some(RequestLifetime::Command),
        NEW_WORK | ADMISSION
    ),
    spec!(
        "navigation/status",
        Navigation,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "navigation/stop",
        Navigation,
        Some(RequestLifetime::Urgent),
        0
    ),
    spec!(
        "navigation/start",
        Navigation,
        Some(RequestLifetime::Command),
        NEW_WORK | ADMISSION
    ),
    spec!(
        "navigation/device/register",
        Navigation,
        Some(RequestLifetime::Command),
        NEW_WORK | ADMISSION
    ),
    spec!(
        "navigation/next",
        Navigation,
        Some(RequestLifetime::Command),
        NEW_WORK | ADMISSION
    ),
    spec!(
        "daemon/liveActivity",
        LiveActivity,
        Some(RequestLifetime::Status),
        0
    ),
    spec!(
        "daemon/activeTurns",
        ActiveTurns,
        Some(RequestLifetime::Status),
        0
    ),
    spec!(
        "daemon/replayNotifications",
        ReplayNotifications,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "automations/status",
        Automations,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "automations/list",
        Automations,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "automations/show",
        Automations,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "automations/history",
        Automations,
        Some(RequestLifetime::Query),
        0
    ),
    spec!(
        "automations/set",
        Automations,
        Some(RequestLifetime::Command),
        NEW_WORK
    ),
    spec!(
        "automations/remove",
        Automations,
        Some(RequestLifetime::Command),
        NEW_WORK
    ),
    spec!(
        "automations/restore",
        Automations,
        Some(RequestLifetime::Command),
        NEW_WORK
    ),
    spec!(
        "automations/run",
        Automations,
        Some(RequestLifetime::Command),
        NEW_WORK
    ),
    spec!("host/info", HostInfo, Some(RequestLifetime::Status), 0),
    spec!("model/list", ModelList, Some(RequestLifetime::Query), 0),
    spec!(
        "conversation/takeOver",
        TakeOver,
        Some(RequestLifetime::Command),
        ADMISSION
    ),
    spec!(
        "sessions/mirror/set",
        Sessions,
        Some(RequestLifetime::Command),
        0
    ),
    prefix_spec!("sessions/", Sessions, Some(RequestLifetime::Query)),
    prefix_spec!("conversation/agents/", Agents, None),
    prefix_spec!(
        "conversation/metadata/",
        Metadata,
        Some(RequestLifetime::Command)
    ),
    prefix_spec!("calls/", Calls, Some(RequestLifetime::Command)),
    prefix_spec!("navigation/", Navigation, Some(RequestLifetime::Command)),
    prefix_spec!("voice/", Voice, None),
];

pub(crate) fn method_spec(method: &str) -> MethodSpec {
    METHOD_SPECS
        .iter()
        .find(|spec| match spec.method {
            MethodMatch::Exact(name) => method == name,
            MethodMatch::Prefix(prefix) => method.starts_with(prefix),
        })
        .copied()
        .unwrap_or(spec!("", Native, None, 0))
}

#[derive(Clone, Copy)]
pub(crate) enum OwnedTarget {
    Claude(ClaudeMethod),
    Gateway(OwnedRoute),
}

#[derive(Clone, Copy)]
pub(crate) struct OwnedRequest {
    pub(crate) target: OwnedTarget,
    pub(crate) lifetime: RequestLifetime,
}

fn owned_request(method: &str, object: &Map<String, Value>) -> Option<OwnedRequest> {
    let spec = method_spec(method);
    if claude_route(method, object) {
        let claude = spec.claude?;
        return Some(OwnedRequest {
            target: OwnedTarget::Claude(claude.method),
            lifetime: claude.lifetime,
        });
    }
    spec.lifetime.map(|lifetime| OwnedRequest {
        target: OwnedTarget::Gateway(spec.route),
        lifetime,
    })
}

fn is_claude_queue_request(method: &str, object: &Map<String, Value>) -> bool {
    method.starts_with("thread/queue/")
        && object
            .get("params")
            .and_then(|params| params.get("threadId"))
            .and_then(Value::as_str)
            .is_some_and(crate::providers::claude::is_claude_thread_id)
}

pub(crate) fn starts_new_work(method: &str) -> bool {
    method_spec(method).new_work
}

pub(crate) struct ClientRequest {
    pub(crate) object: Map<String, Value>,
    pub(crate) method: String,
    pub(crate) starts_new_work: bool,
    pub(crate) owned: Option<OwnedRequest>,
}

pub(crate) enum DispatchPlan {
    Refuse { id: Value, error: RpcError },
    ForwardResponse,
    Request(ClientRequest),
}

impl DispatchPlan {
    pub(crate) fn parse(raw: &str) -> Self {
        let object = match serde_json::from_str::<Value>(raw) {
            Ok(Value::Object(object)) => object,
            Ok(_) => {
                return Self::refuse(
                    Value::Null,
                    RpcCode::InvalidRequest,
                    "JSON-RPC envelope must be an object",
                );
            }
            Err(_) => {
                return Self::refuse(Value::Null, RpcCode::ParseError, "Invalid JSON-RPC JSON");
            }
        };
        let request_id = object.get("id").unwrap_or(&Value::Null);
        if let Err(error) = validate_request_id(request_id) {
            return Self::Refuse {
                id: Value::Null,
                error,
            };
        }
        let id = request_id.clone();
        let Some(method) = object.get("method") else {
            return if object.contains_key("id")
                && (object.contains_key("result") || object.contains_key("error"))
            {
                Self::ForwardResponse
            } else {
                Self::refuse(
                    id,
                    RpcCode::InvalidRequest,
                    "JSON-RPC method or response is required",
                )
            };
        };
        let Some(method) = method.as_str().map(str::to_owned) else {
            return Self::refuse(
                id,
                RpcCode::InvalidRequest,
                "JSON-RPC method must be a string",
            );
        };
        if is_claude_queue_request(&method, &object) {
            return Self::Refuse {
                id,
                error: RpcError::queue_unsupported(),
            };
        }
        let owned = owned_request(&method, &object);
        if id.is_null() && owned.is_some() {
            return Self::refuse(
                Value::Null,
                RpcCode::InvalidRequest,
                "A non-null id is required for this gateway method",
            );
        }

        Self::Request(ClientRequest {
            starts_new_work: starts_new_work(&method)
                && !(method == "automations/run"
                    && object.get("params").is_some_and(|params| {
                        params["runId"].as_str().is_some_and(|id| !id.is_empty())
                            && (params["cancel"] == true
                                || params["acknowledge"] == true
                                || params["message"].is_string()
                                || params["resolution"].is_string())
                    })),
            object,
            method,
            owned,
        })
    }

    fn refuse(id: Value, code: RpcCode, message: &str) -> Self {
        Self::Refuse {
            id,
            error: RpcError::new(code, message),
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn request(plan: DispatchPlan) -> ClientRequest {
        match plan {
            DispatchPlan::Request(request) => request,
            _ => panic!("expected a client request"),
        }
    }

    fn refusal(plan: DispatchPlan) -> (Value, RpcError) {
        match plan {
            DispatchPlan::Refuse { id, error } => (id, error),
            _ => panic!("expected a refusal"),
        }
    }

    #[test]
    fn rpc_capacity_oversized_request_id_is_refused_before_owned_or_native_admission() {
        for method in ["host/info", "thread/read"] {
            let (id, error) = refusal(DispatchPlan::parse(
                &json!({"id":"é".repeat(257),
                "method":method,"params":{"threadId":"native"}})
                .to_string(),
            ));
            assert!(id.is_null());
            assert_eq!(error.code, RpcCode::Capacity);
            let wire = error.response(&id);
            assert_eq!(wire["error"]["data"]["kind"], "capacity");
            assert_eq!(
                wire["error"]["data"]["resource"],
                "request identifier bytes"
            );
            assert_eq!(wire["error"]["data"]["limit"], 512);
            assert_eq!(wire["error"]["data"]["retryable"], false);
            let accepted = request(DispatchPlan::parse(
                &json!({"id":"é".repeat(256),
                "method":method,"params":{"threadId":"native"}})
                .to_string(),
            ));
            assert_eq!(accepted.object["id"].as_str().unwrap().len(), 512);
        }
    }

    #[test]
    fn an_escaped_method_key_gets_the_same_policy_as_a_literal_one() {
        for raw in [
            r#"{"id":1,"method":"turn/start","params":{"threadId":"claude_a"}}"#,
            r#"{"id":1,"\u006dethod":"turn/start","params":{"threadId":"claude_a"}}"#,
        ] {
            let request = request(DispatchPlan::parse(raw));
            assert_eq!(request.method, "turn/start");
            assert!(request.starts_new_work);
            assert!(matches!(
                request.owned,
                Some(OwnedRequest {
                    target: OwnedTarget::Claude(ClaudeMethod::TurnStart),
                    lifetime: RequestLifetime::Command,
                })
            ));
        }
    }

    #[test]
    fn owned_methods_need_a_non_null_id_and_native_ones_do_not() {
        for raw in [
            r#"{"method":"daemon/activeTurns"}"#,
            r#"{"id":null,"method":"voice/session/stop"}"#,
            r#"{"method":"turn/start","params":{"threadId":"claude_a"}}"#,
        ] {
            let (id, error) = refusal(DispatchPlan::parse(raw));
            assert!(id.is_null(), "{raw}");
            assert_eq!(error.code, RpcCode::InvalidRequest, "{raw}");
        }
        let native = request(DispatchPlan::parse(
            r#"{"method":"turn/start","params":{"threadId":"0199-codex"}}"#,
        ));
        assert!(native.owned.is_none());
        assert!(
            request(DispatchPlan::parse(r#"{"id":3,"method":"thread/list"}"#))
                .owned
                .is_none()
        );
    }

    #[test]
    fn queue_mutations_are_governed_native_changes_and_reads_pass_through() {
        for (method, new_work) in [
            ("thread/queue/add", true),
            ("thread/queue/start", true),
            ("thread/queue/delete", false),
        ] {
            let raw = json!({"id": 1, "method": method, "params": {"threadId": "0199-codex"}})
                .to_string();
            let request = request(DispatchPlan::parse(&raw));
            let spec = method_spec(method);
            assert_eq!(request.starts_new_work, new_work, "{method}");
            assert!(spec.admission && spec.identity, "{method}");
            assert!(matches!(
                request.owned,
                Some(OwnedRequest {
                    target: OwnedTarget::Gateway(OwnedRoute::NativeQueue),
                    lifetime: RequestLifetime::Command,
                })
            ));
        }
        for method in [
            "thread/queue/list",
            "thread/queue/update",
            "thread/queue/reorder",
        ] {
            let raw = json!({"id": 1, "method": method, "params": {"threadId": "0199-codex"}})
                .to_string();
            let request = request(DispatchPlan::parse(&raw));
            let spec = method_spec(method);
            assert!(request.owned.is_none(), "{method}");
            assert!(
                !spec.new_work && !spec.admission && !spec.identity,
                "{method}"
            );
        }
    }

    #[test]
    fn queue_methods_on_a_claude_thread_are_refused_before_any_route() {
        for method in [
            "thread/queue/add",
            "thread/queue/list",
            "thread/queue/start",
            "thread/queue/delete",
            "thread/queue/update",
            "thread/queue/reorder",
        ] {
            let raw =
                json!({"id": 7, "method": method, "params": {"threadId": "claude_a"}}).to_string();
            let (id, error) = refusal(DispatchPlan::parse(&raw));
            assert_eq!(id, json!(7), "{method}");
            assert_eq!(error, RpcError::queue_unsupported(), "{method}");
        }
    }

    #[test]
    fn voice_start_and_stop_are_owned_with_their_budgets() {
        for (method, lifetime) in [
            ("voice/session/start", RequestLifetime::Command),
            ("voice/session/stop", RequestLifetime::Urgent),
        ] {
            let raw = json!({"id": 1, "method": method}).to_string();
            let owned = request(DispatchPlan::parse(&raw))
                .owned
                .expect("voice sessions are gateway-owned");
            assert_eq!(owned.lifetime, lifetime);
            assert!(matches!(
                owned.target,
                OwnedTarget::Gateway(OwnedRoute::VoiceSession)
            ));
        }
    }

    #[test]
    fn malformed_envelopes_are_refused_and_responses_pass_through() {
        for (raw, code) in [
            ("[]", RpcCode::InvalidRequest),
            (
                r#"{"id":11,"method":"daemon/activeTurns""#,
                RpcCode::ParseError,
            ),
            (r#"{"id":10,"method":13}"#, RpcCode::InvalidRequest),
            (r#"{"id":10}"#, RpcCode::InvalidRequest),
        ] {
            assert_eq!(refusal(DispatchPlan::parse(raw)).1.code, code, "{raw}");
        }
        assert_eq!(
            refusal(DispatchPlan::parse(r#"{"id":10,"method":13}"#)).0,
            json!(10)
        );
        assert!(matches!(
            DispatchPlan::parse(r#"{"id":99,"result":{}}"#),
            DispatchPlan::ForwardResponse
        ));
        assert!(matches!(
            DispatchPlan::parse(r#"{"id":99,"error":{"code":1,"message":"x"}}"#),
            DispatchPlan::ForwardResponse
        ));
    }
}
