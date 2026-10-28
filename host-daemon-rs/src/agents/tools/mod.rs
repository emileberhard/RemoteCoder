//! The canonical registry of RemoteCoder's own agent tools, and the one
//! function that runs them.
//!
//! Both providers reach the same `dispatch`: Claude through the gateway-hosted
//! MCP endpoint (`http_server::mcp`), Codex through `dynamicTools` declared on
//! its threads and `item/tool/call` requests answered upstream. Keeping the
//! definitions and the execution in one place is what stops the two surfaces
//! drifting into different tools with the same names.
//!
//! Tools are deliberately few and static: they are always present on
//! RemoteCoder threads, describe themselves precisely, and fail with text the
//! model can act on rather than being added and removed at runtime.

pub(crate) mod claims;
mod codex;
mod dispatch;
mod registry;

pub(crate) use codex::codex_dynamic_tools;
pub(crate) use codex::{CodexToolCall, codex_tool_call, declare_on_codex_request};
pub(crate) use dispatch::{Caller, ToolContent, ToolOutcome, dispatch};
#[cfg(test)]
pub(crate) use registry::END_VOICE_CALL;
pub(crate) use registry::{NAMESPACE, NOTIFY_USER, PUBLISH_VISUAL, definitions};
