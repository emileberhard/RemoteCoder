//! The gateway's own MCP server: protocol revision 2026-07-28, tools only.
//!
//! That revision removed the `initialize`/`initialized` handshake, the GET/SSE
//! endpoint, and protocol-level sessions — every request carries its version
//! and client info in `_meta`, and the server answers each one independently.
//! A stateless request/response server is exactly what this gateway is, so
//! there is no legacy handshake path: a client speaking an older revision gets
//! a typed version error instead of a silent half-working session.
//!
//! Verified against Claude Code 2.1.238 on this host, which sends
//! `server/discover` → `tools/list` → `tools/call` with `mcp-protocol-version`,
//! `mcp-method`, and (on calls) `mcp-name` headers, and no `Origin`.
//!
//! This module is pure: it validates and routes, and hands tool calls back to
//! the caller to dispatch. `http_server` owns the axum wiring.

mod protocol;
mod tokens;

#[cfg(test)]
pub(crate) use protocol::PROTOCOL_VERSION;
pub(crate) use protocol::{Action, Incoming, method_not_allowed, route, tool_response};
pub(crate) use tokens::{
    McpIdentity, McpTokens, NOTIFICATION_PERMIT_FIELD, config_file_id, remove_notification_permit,
};
