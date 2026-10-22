use super::codex::codex_writers;
use super::transcript::tail_boundary;
use super::*;
use crate::time::parse_rfc3339_seconds;
use serde_json::{Value, json};
use std::path::Path;

fn claude_boundary(records: &[Value], owner: u64) -> Option<ActivityState> {
    records
        .iter()
        .filter_map(|value| claude::boundary(value.to_string().as_bytes()).unwrap())
        .next_back()
        .and_then(|boundary| boundary.state_since(owner as i64))
}

fn codex_boundary(records: &[Value], owner: i64) -> ActivityState {
    records
        .iter()
        .filter_map(|value| codex::boundary(value.to_string().as_bytes()).unwrap())
        .next_back()
        .and_then(|boundary| boundary.state_since(owner))
        .unwrap_or(ActivityState::Unknown)
}

fn claude(kind: &str, reason: Option<&str>) -> Value {
    json!({"type": kind, "timestamp": "2026-09-05T12:00:00Z", "message": {"content": "text", "stop_reason": reason}})
}

#[test]
fn completed_claude_turn_is_idle_even_if_followed_by_metadata() {
    let records = vec![
        claude("assistant", Some("tool_use")),
        claude("assistant", Some("end_turn")),
        json!({"type":"ai-title","aiTitle":"renamed"}),
    ];
    assert_eq!(claude_boundary(&records, 0), Some(ActivityState::Idle));
}

#[test]
fn claude_tool_work_stays_active_without_an_activity_timeout() {
    assert_eq!(
        claude_boundary(
            &[claude("assistant", Some("tool_use")), claude("user", None)],
            0
        ),
        Some(ActivityState::Working)
    );
}

#[test]
fn claude_resume_does_not_revive_an_old_unfinished_turn() {
    let started = parse_rfc3339_seconds("2026-09-05T12:00:01Z").unwrap() as u64;
    assert_eq!(
        claude_boundary(&[claude("assistant", Some("tool_use"))], started),
        None
    );
    assert_eq!(
        claude_boundary(&[claude("assistant", Some("end_turn"))], started),
        Some(ActivityState::Idle)
    );
}

#[test]
fn sidechains_and_context_injections_do_not_reopen_claude_turns() {
    let mut records = vec![claude("assistant", Some("end_turn"))];
    let mut sidechain = claude("assistant", Some("tool_use"));
    sidechain["isSidechain"] = json!(true);
    records.push(sidechain);
    let mut meta = claude("user", None);
    meta["isMeta"] = json!(true);
    records.push(meta);
    let mut injection = claude("user", None);
    injection["message"]["content"] = json!("<system-reminder>context</system-reminder>");
    records.push(injection);
    assert_eq!(claude_boundary(&records, 0), Some(ActivityState::Idle));
}

#[test]
fn claude_abort_and_duration_are_terminal() {
    let mut abort = claude("user", None);
    abort["message"]["content"] =
        json!([{ "type":"text", "text":"[Request interrupted by user]" }]);
    assert_eq!(
        claude_boundary(&[claude("assistant", Some("tool_use")), abort], 0),
        Some(ActivityState::Idle)
    );
    let mut duration = claude("system", None);
    duration["subtype"] = json!("turn_duration");
    assert_eq!(claude_boundary(&[duration], 0), Some(ActivityState::Idle));
}

#[test]
fn torn_or_invalid_transcripts_are_unavailable() {
    let file = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(file.path(), b"{\"type\":\"user\"}\n{\"type\":").unwrap();
    assert!(tail_boundary(file.path(), claude::boundary).is_err());
    std::fs::write(file.path(), b"broken\n").unwrap();
    assert!(tail_boundary(file.path(), claude::boundary).is_err());
}

#[test]
fn codex_requires_a_current_owner_and_explicit_boundary() {
    let start = json!({"type":"event_msg","timestamp":"2026-09-05T12:00:00Z","payload":{"type":"task_started"}});
    assert_eq!(
        codex_boundary(std::slice::from_ref(&start), 0),
        ActivityState::Working
    );
    let resumed = parse_rfc3339_seconds("2026-09-05T12:00:01Z").unwrap();
    assert_eq!(
        codex_boundary(std::slice::from_ref(&start), resumed),
        ActivityState::Unknown
    );
    for end in ["task_complete", "turn_aborted"] {
        let stop =
            json!({"type":"event_msg","timestamp":"2026-09-05T12:00:02Z","payload":{"type":end}});
        assert_eq!(
            codex_boundary(&[start.clone(), stop], 0),
            ActivityState::Idle
        );
    }
}

#[test]
fn only_external_writable_codex_rollouts_establish_ownership() {
    let inventory = "p10\nccodex\nf5\naw\ntREG\nn/home/.codex/sessions/managed.jsonl\np20\nccodex\nf6\nar\ntREG\nn/home/.codex/sessions/read.jsonl\nf7\naw\ntREG\nn/home/.codex/sessions/owned.jsonl\nf8\naw\ntREG\nn/elsewhere/foreign.jsonl\np30\nccodex-code-mode\nf9\naw\ntREG\nn/home/.codex/sessions/tool.jsonl\n";
    let files = codex_writers(inventory, Path::new("/home/.codex"), 10);
    assert_eq!(files.len(), 1);
    assert_eq!(
        files[&20],
        vec![PathBuf::from("/home/.codex/sessions/owned.jsonl")]
    );
}

#[test]
fn transcript_cache_rechecks_rewrites_and_drops_dead_owners() {
    let file = tempfile::NamedTempFile::new().unwrap();
    let mut cache = TranscriptCache::default();
    let write = |reason| {
        std::fs::write(
            file.path(),
            format!("{}\n", claude("assistant", Some(reason))),
        )
        .unwrap()
    };
    let classify = claude::boundary;
    let state = |boundary: Option<transcript::Boundary>, owner| {
        boundary.and_then(|boundary| boundary.state_since(owner))
    };
    write("end_turn");
    assert_eq!(
        state(cache.boundary(file.path(), classify).unwrap(), 0),
        Some(ActivityState::Idle)
    );
    assert_eq!(
        state(
            cache
                .boundary(file.path(), |_| panic!("unchanged file must stay cached"))
                .unwrap(),
            0
        ),
        Some(ActivityState::Idle)
    );
    write("tool_use");
    let boundary = cache.boundary(file.path(), classify).unwrap();
    assert_eq!(state(boundary, 0), Some(ActivityState::Working));
    let asked = parse_rfc3339_seconds("2026-09-05T12:00:00Z").unwrap();
    assert_eq!(
        boundary.and_then(|boundary| boundary.timestamp),
        Some(asked)
    );
    assert_eq!(state(boundary, asked + 1), None);
    cache.seen.clear();
    cache.finish();
    let recomputed = std::cell::Cell::new(false);
    cache
        .boundary(file.path(), |bytes| {
            recomputed.set(true);
            classify(bytes)
        })
        .unwrap();
    assert!(recomputed.get());
}

#[test]
fn bounded_codex_tail_reports_uncertainty_until_a_boundary_is_visible() {
    let file = tempfile::NamedTempFile::new().unwrap();
    let start = json!({"type":"event_msg","timestamp":"2026-09-05T12:00:00Z","payload":{"type":"task_started"}});
    let large = json!({"type":"response_item","payload":{"type":"function_call_output","output":"x".repeat(8 * 1024 * 1024)}});
    std::fs::write(file.path(), format!("{start}\n{large}\n")).unwrap();
    assert!(
        tail_boundary(file.path(), codex::boundary)
            .unwrap()
            .is_none()
    );
    let complete = json!({"type":"event_msg","timestamp":"2026-09-05T13:00:00Z","payload":{"type":"task_complete"}});
    std::fs::write(file.path(), format!("{start}\n{large}\n{complete}\n")).unwrap();
    assert_eq!(
        tail_boundary(file.path(), codex::boundary)
            .unwrap()
            .unwrap()
            .state_since(0),
        Some(ActivityState::Idle)
    );
}

#[test]
fn invalid_boundary_timestamp_cannot_inherit_previous_idle_state() {
    let mut invalid = claude("user", None);
    invalid["timestamp"] = json!("invalid");
    assert_eq!(
        claude_boundary(&[claude("assistant", Some("end_turn")), invalid], 0),
        Some(ActivityState::Unknown)
    );
}

fn shell(script: &str) -> Command {
    let mut command = Command::new("/bin/sh");
    command.args(["-c", script]);
    command
}

#[tokio::test]
async fn command_output_within_the_limits_is_returned() {
    assert_eq!(output(shell("printf ready")).await.unwrap(), b"ready");
}

#[tokio::test]
async fn command_output_past_the_stdout_limit_fails_without_collecting_it() {
    let script = format!("head -c {} /dev/zero", MAXIMUM_STDOUT_BYTES + 1);
    let error = output(shell(&script)).await.unwrap_err();
    assert!(error.to_string().contains("inventory exceeds size limit"));
}

#[tokio::test]
async fn command_diagnostics_are_bounded_and_mark_coverage_incomplete() {
    let script = format!("head -c {} /dev/zero >&2", MAXIMUM_STDERR_BYTES + 1);
    let error = output(shell(&script)).await.unwrap_err();
    assert!(error.to_string().contains("diagnostics exceeds size limit"));
    let error = output(shell("echo skipped >&2")).await.unwrap_err();
    assert!(error.to_string().contains("incomplete coverage"));
}

#[test]
fn an_inventory_above_the_session_limit_is_unavailable_not_truncated() {
    assert!(ensure_inventory_within_limit(MAXIMUM_INVENTORY_SESSIONS).is_ok());
    assert!(ensure_inventory_within_limit(MAXIMUM_INVENTORY_SESSIONS + 1).is_err());
}

#[test]
fn only_a_process_outside_the_gateway_owns_a_session_elsewhere() {
    let session = |thread_id: &str, pid: Option<i32>| SessionActivity {
        thread_id: thread_id.into(),
        state: ActivityState::Idle,
        owner: pid.map(|pid| SessionOwner::Client { pid }),
        waiting_since: None,
    };
    let claude = "claude_11111111-2222-4333-8444-555555555555";
    let mut snapshot = Snapshot {
        sessions: vec![
            session(claude, Some(41)),
            session(claude, Some(42)),
            session("0199-codex", Some(43)),
            session("claude_background", None),
        ],
        claude_available: true,
        codex_available: false,
    };

    snapshot.attribute_to_gateway(&HashSet::from([41]));

    assert_eq!(snapshot.client_owners(claude).unwrap(), vec![42]);
    assert_eq!(
        serde_json::to_value(&snapshot.sessions[0]).unwrap()["owner"],
        "gateway"
    );
    assert_eq!(
        serde_json::to_value(&snapshot.sessions[1]).unwrap()["owner"],
        "client"
    );
    assert!(
        snapshot
            .client_owners("claude_background")
            .unwrap()
            .is_empty()
    );
    assert!(
        snapshot.client_owners("0199-codex").is_err(),
        "an unreadable inventory never proves a session is free"
    );
}
