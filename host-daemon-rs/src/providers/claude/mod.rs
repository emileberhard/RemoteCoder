pub(crate) mod auth;
mod capacity;
pub(crate) mod conversation_index;
mod delivery_evidence;
pub(crate) mod exec;
pub(crate) mod fork;
pub(crate) mod history;
mod input;
pub(crate) mod native_parent;
pub(crate) mod notification_hook;
pub(crate) mod projection;
pub(crate) mod records;
pub(crate) mod restart;
pub(crate) mod restart_driver;
pub(crate) mod session_context;
pub(crate) mod settings;
mod supervisor;
#[cfg(test)]
pub(crate) use supervisor::tests::runtime_stderr_frame;
pub(crate) mod timeline;
pub(crate) mod translate;
pub(crate) mod wake_hold;

pub(crate) use capacity::CapacityExceeded;
pub(crate) use input::{ClaudeSelection, ClaudeTurnRequest, ClaudeUserInput};
pub(crate) use supervisor::{
    ClaudeJobInspection, ClaudeNotification, ClaudeSupervisor, ParentMessage, ResumeDelivery,
    SessionRename, TurnControlError,
};

/// Claude thread ids are prefixed so daemon routing is a pure string test.
const CLAUDE_THREAD_PREFIX: &str = "claude_";

pub(crate) fn is_claude_thread_id(thread_id: &str) -> bool {
    thread_id.starts_with(CLAUDE_THREAD_PREFIX)
}

pub(crate) fn claude_thread_id(session_uuid: &str) -> String {
    format!("{CLAUDE_THREAD_PREFIX}{session_uuid}")
}

pub(crate) fn session_uuid_from_thread_id(thread_id: &str) -> Option<&str> {
    thread_id
        .strip_prefix(CLAUDE_THREAD_PREFIX)
        .filter(|uuid| !uuid.is_empty())
}

/// Session directory for a working directory.
///
/// Claude slugs a cwd by replacing every character outside `[A-Za-z0-9]` with
/// `-`, preserving case. Verified against a real run in a directory containing
/// `_`, a space, `.` and `+`. The mapping is lossy, so it is only ever applied
/// forward (cwd to slug), never inverted.
pub(crate) fn project_slug(cwd: &str) -> String {
    cwd.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thread_ids_round_trip_through_the_claude_prefix() {
        let thread_id = claude_thread_id("abc-123");

        assert_eq!(thread_id, "claude_abc-123");
        assert!(is_claude_thread_id(&thread_id));
        assert!(!is_claude_thread_id("0199abcd-codex-thread"));
        assert_eq!(session_uuid_from_thread_id(&thread_id), Some("abc-123"));
        assert_eq!(session_uuid_from_thread_id("claude_"), None);
    }

    /// Pinned against real `~/.claude/projects` directory names.
    #[test]
    fn project_slug_matches_the_cli_encoding() {
        assert_eq!(
            project_slug("/Users/developer/RemoteCoder"),
            "-Users-developer-RemoteCoder"
        );
        assert_eq!(project_slug("/Users/developer"), "-Users-developer");
        assert_eq!(
            project_slug("/tmp/we_ird dir.v2+x/Sub_Dir"),
            "-tmp-we-ird-dir-v2-x-Sub-Dir"
        );
        assert_eq!(
            project_slug("/private/tmp/claude-501/-Users-developer/scratchpad"),
            "-private-tmp-claude-501--Users-developer-scratchpad"
        );
        assert_eq!(
            project_slug("/Users/developer/actions-runners/configs/_work/configs"),
            "-Users-developer-actions-runners-configs--work-configs"
        );
    }
}
