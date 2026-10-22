use serde_json::{Value, json};

use super::NOTIFICATION_PERMIT_FIELD;
use crate::agents::tools as agent_tools;

pub(crate) const PROTOCOL_VERSION: &str = "2026-07-28";

const META_VERSION_KEY: &str = "io.modelcontextprotocol/protocolVersion";

/// Header mismatch or a missing required header.
const HEADER_MISMATCH: i64 = -32020;
/// The requested protocol revision is not one we speak.
const UNSUPPORTED_VERSION: i64 = -32022;
/// No such RPC.
const METHOD_NOT_FOUND: i64 = -32601;
/// Malformed body.
const PARSE_ERROR: i64 = -32700;

/// What the transport should do with one request.
#[derive(Debug, PartialEq)]
pub(crate) enum Action {
    /// Send this status and JSON body.
    Respond { status: u16, body: Value },
    /// A notification we accept: 202 with no body.
    Accepted,
    /// Dispatch this tool, then finish with [`tool_response`].
    CallTool {
        id: Value,
        name: String,
        arguments: Value,
    },
}

/// One inbound POST, reduced to what the protocol cares about.
pub(crate) struct Incoming<'a> {
    pub protocol_version: Option<&'a str>,
    pub method_header: Option<&'a str>,
    pub name_header: Option<&'a str>,
    pub origin: Option<&'a str>,
    pub body: &'a Value,
}

/// Validates one request and decides what happens to it.
pub(crate) fn route(incoming: &Incoming) -> Action {
    if let Some(origin) = incoming.origin
        && !origin_is_local(origin)
    {
        // DNS-rebinding defence: a browser page must not be able to drive the
        // gateway's tools. Non-browser clients send no Origin at all.
        return error(403, Value::Null, HEADER_MISMATCH, "origin not allowed");
    }

    let Some(body) = incoming.body.as_object() else {
        return error(
            400,
            Value::Null,
            PARSE_ERROR,
            "body must be a JSON-RPC object",
        );
    };

    let id = body.get("id").cloned().unwrap_or(Value::Null);
    if id.is_null() {
        // A notification. This revision defines no client-to-server
        // notifications over HTTP, but accepting one is cheaper than arguing.
        return Action::Accepted;
    }

    let method = body
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if method.is_empty() {
        return error(400, id, PARSE_ERROR, "request is missing \"method\"");
    }

    let params = body.get("params").cloned().unwrap_or_else(|| json!({}));
    let meta_version = params
        .get("_meta")
        .and_then(|meta| meta.get(META_VERSION_KEY))
        .and_then(Value::as_str);

    // The header mirrors the body so intermediaries can route without parsing
    // it; if the two disagree, one of them is lying and the request is refused.
    let Some(header_version) = incoming.protocol_version else {
        return error(
            400,
            id,
            HEADER_MISMATCH,
            "missing MCP-Protocol-Version header",
        );
    };
    if let Some(meta_version) = meta_version
        && meta_version != header_version
    {
        return error(
            400,
            id,
            HEADER_MISMATCH,
            &format!(
                "MCP-Protocol-Version header value '{header_version}' does not match body value '{meta_version}'"
            ),
        );
    }
    if header_version != PROTOCOL_VERSION {
        return Action::Respond {
            status: 400,
            body: json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": {
                    "code": UNSUPPORTED_VERSION,
                    "message": "Unsupported protocol version",
                    "data": {
                        "supported": [PROTOCOL_VERSION],
                        "requested": header_version,
                    }
                }
            }),
        };
    }

    let Some(method_header) = incoming.method_header else {
        return error(400, id, HEADER_MISMATCH, "missing Mcp-Method header");
    };
    if method_header != method {
        return error(
            400,
            id,
            HEADER_MISMATCH,
            &format!(
                "Mcp-Method header value '{method_header}' does not match body value '{method}'"
            ),
        );
    }

    match method {
        "server/discover" => Action::Respond {
            status: 200,
            body: result(
                id,
                json!({
                    "resultType": "complete",
                    "supportedVersions": [PROTOCOL_VERSION],
                    "capabilities": { "tools": {} },
                    "_meta": {
                        "io.modelcontextprotocol/serverInfo": {
                            "name": "remotecoder-gateway",
                            "version": crate::build_identity::IDENTITY.version,
                        }
                    },
                    "instructions": "RemoteCoder tools for inline HTML visuals, iPhone photos, authorized voice calls and user notifications.",
                    "ttlMs": 3_600_000,
                    "cacheScope": "public",
                }),
            ),
        },
        "tools/list" => Action::Respond {
            status: 200,
            body: result(
                id,
                json!({
                    "resultType": "complete",
                    "tools": mcp_tools(),
                    // The registry is static, so the list is cacheable and
                    // there is nothing for a client to subscribe to.
                    "ttlMs": 3_600_000,
                    "cacheScope": "public",
                }),
            ),
        },
        "tools/call" => {
            let name = params
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if name.is_empty() {
                return error(400, id, PARSE_ERROR, "tools/call is missing \"name\"");
            }
            // Registry tool names are plain ASCII by construction (asserted in
            // tests), so a conformant client always sends this header
            // unencoded — the base64 sentinel form is only permitted for values
            // that plain ASCII cannot represent.
            let Some(name_header) = incoming.name_header else {
                return error(400, id, HEADER_MISMATCH, "missing Mcp-Name header");
            };
            if name_header != name {
                return error(
                    400,
                    id,
                    HEADER_MISMATCH,
                    &format!(
                        "Mcp-Name header value '{name_header}' does not match body value '{name}'"
                    ),
                );
            }
            Action::CallTool {
                id,
                name: name.to_string(),
                arguments: params
                    .get("arguments")
                    .cloned()
                    .unwrap_or_else(|| json!({})),
            }
        }
        other => Action::Respond {
            // A modern client distinguishes this from a legacy server's 404 by
            // the JSON-RPC error body.
            status: 404,
            body: json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": METHOD_NOT_FOUND, "message": format!("Method not found: {other}") }
            }),
        },
    }
}

/// The `tools/call` response for a completed dispatch.
pub(crate) fn tool_response(id: &Value, outcome: &agent_tools::ToolOutcome) -> Value {
    result(
        id.clone(),
        json!({
            "resultType": "complete",
            "content": outcome.content.iter().map(|content| match content {
                agent_tools::ToolContent::Text { text } => json!({"type": "text", "text": text}),
                agent_tools::ToolContent::Image { mime_type, base64 } => json!({"type": "image", "mimeType": mime_type, "data": base64}),
            }).collect::<Vec<_>>(),
            "isError": outcome.is_error,
        }),
    )
}

/// The body for a GET, which this revision has no use for.
pub(crate) fn method_not_allowed() -> Value {
    json!({
        "jsonrpc": "2.0",
        "error": {
            "code": METHOD_NOT_FOUND,
            "message": "this MCP endpoint accepts POST only"
        }
    })
}

fn result(id: Value, result: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": result })
}

fn error(status: u16, id: Value, code: i64, message: &str) -> Action {
    Action::Respond {
        status,
        body: json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": code, "message": message }
        }),
    }
}

fn origin_is_local(origin: &str) -> bool {
    let authority = origin
        .strip_prefix("http://")
        .or_else(|| origin.strip_prefix("https://"))
        .unwrap_or(origin);
    let authority = authority.split('/').next().unwrap_or_default();
    let (host, port) = if let Some(bracketed) = authority.strip_prefix('[') {
        let Some((host, suffix)) = bracketed.split_once(']') else {
            return false;
        };
        let port = if suffix.is_empty() {
            None
        } else {
            let Some(port) = suffix.strip_prefix(':') else {
                return false;
            };
            Some(port)
        };
        (host, port)
    } else if authority == "::1" {
        (authority, None)
    } else {
        match authority.split_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (authority, None),
        }
    };
    port.is_none_or(|port| port.parse::<u16>().is_ok())
        && matches!(host, "localhost" | "127.0.0.1" | "::1")
}

/// `tools/list` entries for the MCP projection.
fn mcp_tools() -> Value {
    Value::Array(
        agent_tools::definitions()
            .iter()
            .map(|tool| {
                let mut schema = (tool.input_schema)();
                if tool.name == agent_tools::NOTIFY_USER {
                    schema["properties"][NOTIFICATION_PERMIT_FIELD] = json!({
                        "type":"string", "description":"Reserved for the runtime notification hook; omit this field."
                    });
                }
                let mut declaration = json!({
                    "name": tool.name,
                    "title": tool.title,
                    "description": tool.description,
                    "inputSchema": schema,
                });
                if tool.name == agent_tools::PUBLISH_VISUAL {
                    declaration["_meta"] = json!({"anthropic/alwaysLoad": true});
                }
                declaration
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inline_visual_tool_is_visible_without_search_and_fits_description_limit() {
        let tools = mcp_tools();
        let visual = tools
            .as_array()
            .unwrap()
            .iter()
            .find(|tool| tool["name"] == agent_tools::PUBLISH_VISUAL)
            .unwrap();
        assert_eq!(visual["_meta"]["anthropic/alwaysLoad"], true);
        assert!(visual["description"].as_str().unwrap().chars().count() <= 2048);
        assert_eq!(visual["inputSchema"]["additionalProperties"], false);
    }

    fn body(method: &str, params: Value) -> Value {
        json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params })
    }

    fn meta() -> Value {
        json!({ "_meta": { META_VERSION_KEY: PROTOCOL_VERSION } })
    }

    fn incoming<'a>(body: &'a Value, method: &'a str) -> Incoming<'a> {
        Incoming {
            protocol_version: Some(PROTOCOL_VERSION),
            method_header: Some(method),
            name_header: None,
            origin: None,
            body,
        }
    }

    fn respond(action: Action) -> (u16, Value) {
        match action {
            Action::Respond { status, body } => (status, body),
            other => panic!("expected a response, got {other:?}"),
        }
    }

    #[test]
    fn discover_reports_only_the_canonical_revision() {
        let request = body("server/discover", meta());
        let (status, response) = respond(route(&incoming(&request, "server/discover")));
        assert_eq!(status, 200);
        assert_eq!(
            response["result"]["supportedVersions"],
            json!([PROTOCOL_VERSION])
        );
        assert_eq!(response["result"]["capabilities"]["tools"], json!({}));
        assert_eq!(response["result"]["resultType"], "complete");
    }

    #[test]
    fn tools_list_returns_the_registry() {
        let request = body("tools/list", meta());
        let (status, response) = respond(route(&incoming(&request, "tools/list")));
        assert_eq!(status, 200);
        let names: Vec<&str> = response["result"]["tools"]
            .as_array()
            .expect("array")
            .iter()
            .map(|tool| tool["name"].as_str().expect("name"))
            .collect();
        assert_eq!(
            names,
            agent_tools::definitions()
                .iter()
                .map(|tool| tool.name)
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn a_tool_call_is_handed_back_for_dispatch() {
        let request = body(
            "tools/call",
            json!({
                "name": agent_tools::NOTIFY_USER,
                "arguments": { "title": "t", "body": "b" },
                "_meta": { META_VERSION_KEY: PROTOCOL_VERSION }
            }),
        );
        let mut incoming = incoming(&request, "tools/call");
        incoming.name_header = Some(agent_tools::NOTIFY_USER);

        match route(&incoming) {
            Action::CallTool {
                name, arguments, ..
            } => {
                assert_eq!(name, agent_tools::NOTIFY_USER);
                assert_eq!(arguments["title"], "t");
            }
            other => panic!("expected a dispatch, got {other:?}"),
        }
    }

    #[test]
    fn contradictory_or_missing_headers_are_refused() {
        let cases = [
            (
                "method differs",
                body("tools/list", meta()),
                Some(PROTOCOL_VERSION),
                Some("tools/call"),
                None,
            ),
            (
                "tool name differs",
                body(
                    "tools/call",
                    json!({"name": agent_tools::END_VOICE_CALL, "_meta": { META_VERSION_KEY: PROTOCOL_VERSION }}),
                ),
                Some(PROTOCOL_VERSION),
                Some("tools/call"),
                Some(agent_tools::NOTIFY_USER),
            ),
            (
                "version differs from metadata",
                body(
                    "tools/list",
                    json!({"_meta": { META_VERSION_KEY: "2025-11-25" }}),
                ),
                Some(PROTOCOL_VERSION),
                Some("tools/list"),
                None,
            ),
            // The whole point of one canonical revision: a legacy client gets a
            // typed error, never a silently half-working session.
            (
                "legacy initialize has no version",
                body("initialize", json!({})),
                None,
                Some("initialize"),
                None,
            ),
            (
                "method header is missing",
                body("tools/list", meta()),
                Some(PROTOCOL_VERSION),
                None,
                None,
            ),
        ];
        for (label, request, protocol_version, method_header, name_header) in cases {
            let (status, response) = respond(route(&Incoming {
                protocol_version,
                method_header,
                name_header,
                origin: None,
                body: &request,
            }));
            assert_eq!(status, 400, "{label}");
            assert_eq!(response["error"]["code"], HEADER_MISMATCH, "{label}");
        }
    }

    #[test]
    fn an_unsupported_version_lists_what_we_speak() {
        let request = body(
            "tools/list",
            json!({ "_meta": { META_VERSION_KEY: "2025-06-18" } }),
        );
        let mut incoming = incoming(&request, "tools/list");
        incoming.protocol_version = Some("2025-06-18");
        let (status, response) = respond(route(&incoming));
        assert_eq!(status, 400);
        assert_eq!(response["error"]["code"], UNSUPPORTED_VERSION);
        assert_eq!(
            response["error"]["data"]["supported"],
            json!([PROTOCOL_VERSION])
        );
        assert_eq!(response["error"]["data"]["requested"], "2025-06-18");
    }

    #[test]
    fn a_notification_is_accepted_without_a_body() {
        let request = json!({ "jsonrpc": "2.0", "method": "notifications/whatever" });
        assert_eq!(
            route(&incoming(&request, "notifications/whatever")),
            Action::Accepted
        );
    }

    #[test]
    fn an_unknown_method_is_404_with_a_jsonrpc_body() {
        let request = body("resources/list", meta());
        let (status, response) = respond(route(&incoming(&request, "resources/list")));
        assert_eq!(status, 404);
        assert_eq!(response["error"]["code"], METHOD_NOT_FOUND);
    }

    #[test]
    fn a_browser_origin_is_rejected_and_a_local_one_is_not() {
        let request = body("tools/list", meta());
        let mut incoming = incoming(&request, "tools/list");
        incoming.origin = Some("https://evil.example.com");
        let (status, _) = respond(route(&incoming));
        assert_eq!(status, 403, "DNS rebinding must not reach the tools");

        let mut incoming = self::incoming(&request, "tools/list");
        incoming.origin = Some("http://127.0.0.1:8787");
        let (status, _) = respond(route(&incoming));
        assert_eq!(status, 200);
    }

    #[test]
    fn bracketed_ipv6_origin_keeps_its_address_when_the_port_is_parsed() {
        assert!(origin_is_local("http://[::1]:8787"));
        assert!(origin_is_local("https://[::1]"));
        assert!(origin_is_local("::1"));
        assert!(!origin_is_local("http://[::2]:8787"));
        assert!(!origin_is_local("http://[::1]:not-a-port"));
    }

    #[test]
    fn registry_tool_names_never_need_header_encoding() {
        // Justifies comparing Mcp-Name without base64-sentinel decoding.
        for tool in agent_tools::definitions() {
            assert!(
                tool.name
                    .chars()
                    .all(|character| character.is_ascii_alphanumeric() || character == '_'),
                "{} would need sentinel encoding in Mcp-Name",
                tool.name
            );
        }
    }

    #[test]
    fn both_projections_describe_the_same_tools() {
        let mcp: Vec<String> = mcp_tools()
            .as_array()
            .expect("array")
            .iter()
            .map(|tool| tool["name"].as_str().expect("name").to_string())
            .collect();
        let codex_spec = agent_tools::codex_dynamic_tools();
        let namespace = &codex_spec[0];
        let codex: Vec<String> = namespace["tools"]
            .as_array()
            .expect("array")
            .iter()
            .map(|tool| tool["name"].as_str().expect("name").to_string())
            .collect();

        assert_eq!(mcp, codex, "the two projections drifted apart");
    }

    #[test]
    fn only_claudes_mcp_schema_exposes_the_hook_transport_field() {
        let mcp = mcp_tools();
        let tool = mcp
            .as_array()
            .unwrap()
            .iter()
            .find(|tool| tool["name"] == agent_tools::NOTIFY_USER)
            .unwrap();
        assert!(tool["inputSchema"]["properties"][NOTIFICATION_PERMIT_FIELD].is_object());
        assert!(
            !agent_tools::codex_dynamic_tools()
                .to_string()
                .contains(NOTIFICATION_PERMIT_FIELD)
        );
    }
}
