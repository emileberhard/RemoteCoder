use super::desktop::control::{DesktopControl, chatgpt_app_pids, current_app, listed_apps};
use super::desktop::environment::{
    ChatGptEnvironment, EnvironmentObservation, app_server_websocket_url, classify_probe_output,
};
use super::desktop::observe::{decide_desktop_action, record_observation};
use super::desktop::reconcile::{reconcile_desktop_state, report_desktop_state};
use super::desktop::stop::{Delivery, DesktopStopAuthority, StopMethod, stop_chatgpt};
use super::desktop::{CHATGPT_EXECUTABLE, DesktopApp, DesktopReason};
use super::install::transaction::Artifact;
use super::install::uninstall::{require_running_from, uninstall_refusal};
use super::transaction::{mark_recovery_failed_closed, write_planned_handoff_ticket};
use super::*;
use crate::config::REQUIRED_CODEX_VERSION;
use crate::platform::process as mac_app;
use crate::runtime::recovery::{RecoveryTask, RecoveryTaskStatus, RuntimeSwap};
use crate::runtime::transaction::complete_aborted_capture;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::HashMap;
use tokio_tungstenite::tungstenite::Message;

use std::collections::HashSet;
use std::sync::Mutex;

/// A scripted host. Every operation reconciliation performs against macOS
/// is answered from this state, so the quit, escalation, launch and
/// stabilization paths are exercised without touching a real process.
#[derive(Default)]
struct FakeDesktopState {
    apps: Vec<DesktopApp>,
    /// A full `ps` pid/command listing. App instances derived from it
    /// through the production filter are listed before `apps`.
    process_lines: Option<Vec<(i32, String)>>,
    observations: HashMap<i32, EnvironmentObservation>,
    /// Pids whose quit request cannot be sent.
    quit_failures: HashSet<i32>,
    /// Pids that accept a quit request but keep running.
    ignores_quit: HashSet<i32>,
    /// Pids whose SIGKILL cannot be delivered.
    kill_failures: HashSet<i32>,
    /// An instance that starts as soon as a quit request is handled.
    starts_during_stop: Option<DesktopApp>,
    /// A process that takes over a target's pid after the target was
    /// selected and before its request is delivered.
    replaces_before_delivery: Option<DesktopApp>,
    /// Once any request is sent, listing fails as an unreadable identity
    /// would.
    listing_fails_after_request: Option<String>,
    /// What appears the next time Launch Services is asked to open the app.
    launch_spawns: Option<(DesktopApp, EnvironmentObservation)>,
    open_error: Option<String>,
    list_error: Option<String>,
    requests: Vec<(i32, StopMethod)>,
    opens: usize,
}

struct FakeDesktop {
    state: Mutex<FakeDesktopState>,
}

impl FakeDesktop {
    fn new(state: FakeDesktopState) -> FakeDesktop {
        FakeDesktop {
            state: Mutex::new(state),
        }
    }

    fn requests(&self) -> Vec<(i32, StopMethod)> {
        self.state.lock().expect("fake state").requests.clone()
    }

    fn opens(&self) -> usize {
        self.state.lock().expect("fake state").opens
    }

    fn listed(state: &FakeDesktopState) -> Vec<DesktopApp> {
        state
            .process_lines
            .as_deref()
            .map(chatgpt_app_pids)
            .unwrap_or_default()
            .into_iter()
            .map(app)
            .chain(state.apps.clone())
            .collect()
    }

    fn remove(state: &mut FakeDesktopState, pid: i32) {
        state.apps.retain(|app| app.pid != pid);
        if let Some(lines) = state.process_lines.as_mut() {
            lines.retain(|(listed, _)| *listed != pid);
        }
        state.observations.remove(&pid);
    }
}

impl DesktopControl for FakeDesktop {
    async fn processes(&self) -> Result<Vec<DesktopApp>> {
        let state = self.state.lock().expect("fake state");
        if let Some(error) = state.list_error.as_ref() {
            bail!("{error}");
        }
        if !state.requests.is_empty()
            && let Some(error) = state.listing_fails_after_request.as_ref()
        {
            bail!("{error}");
        }
        Ok(FakeDesktop::listed(&state))
    }

    fn observe_environment(
        &self,
        observed: DesktopApp,
        _environment: &ChatGptEnvironment,
    ) -> EnvironmentObservation {
        self.state
            .lock()
            .expect("fake state")
            .observations
            .get(&observed.pid)
            .cloned()
            .unwrap_or(EnvironmentObservation::Vanished)
    }

    fn deliver(&self, target: DesktopApp, method: StopMethod) -> Result<Delivery> {
        let mut state = self.state.lock().expect("fake state");
        let pid = target.pid;
        if let Some(replacement) = state
            .replaces_before_delivery
            .take_if(|replacement| replacement.pid == pid)
        {
            FakeDesktop::remove(&mut state, pid);
            state.apps.push(replacement);
        }
        if !FakeDesktop::listed(&state).contains(&target) {
            return Ok(Delivery::TargetGone);
        }
        state.requests.push((pid, method));
        match method {
            StopMethod::Quit => {
                if state.quit_failures.contains(&pid) {
                    bail!("pid {pid} is not a running application (OSStatus -600)");
                }
                if !state.ignores_quit.contains(&pid) {
                    FakeDesktop::remove(&mut state, pid);
                    if let Some(started) = state.starts_during_stop.take() {
                        state.apps.push(started);
                    }
                }
            }
            StopMethod::Kill => {
                if state.kill_failures.contains(&pid) {
                    bail!("failed to send SIGKILL to pid {pid}");
                }
                FakeDesktop::remove(&mut state, pid);
            }
        }
        Ok(Delivery::Sent)
    }

    async fn open_application(&self, _environment: &ChatGptEnvironment) -> Result<()> {
        let mut state = self.state.lock().expect("fake state");
        state.opens += 1;
        if let Some(error) = state.open_error.as_ref() {
            bail!("{error}");
        }
        if let Some((started, observation)) = state.launch_spawns.clone() {
            state.apps.push(started);
            state.observations.insert(started.pid, observation);
        }
        Ok(())
    }
}

/// An instance with a start time derived from its pid, so tests can make
/// a different process reuse the same pid.
fn app(pid: i32) -> DesktopApp {
    DesktopApp {
        pid,
        started_micros: u64::from(pid.unsigned_abs()) * 1_000,
    }
}

fn test_environment() -> ChatGptEnvironment {
    ChatGptEnvironment {
        app_server_ws_url: "ws+unix://localhost/tmp/codex.sock:/rpc".to_string(),
    }
}

async fn reconcile_scenario(state: FakeDesktopState) -> (FakeDesktop, Vec<Value>, Result<()>) {
    let directory = tempfile::tempdir().expect("temp dir");
    let journal = DesktopJournal::in_dir(directory.path(), "launch", "periodic");
    let control = FakeDesktop::new(state);
    let result = reconcile_desktop_state(&control, &journal, &test_environment()).await;
    (control, journal.records(), result)
}

fn managed_command() -> String {
    format!(
        "{CHATGPT_EXECUTABLE} SSL_CERT_FILE=/etc/ssl/cert.pem \
         CODEX_APP_SERVER_WS_URL=ws+unix://localhost/tmp/codex.sock:/rpc"
    )
}

fn attached() -> EnvironmentObservation {
    EnvironmentObservation::Matches
}

fn detached() -> EnvironmentObservation {
    EnvironmentObservation::Differs(test_environment().observe(
        "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT \
             SSL_CERT_FILE=/etc/ssl/cert.pem \
             CODEX_APP_SERVER_WS_URL=ws+unix://localhost/tmp/private.sock:/rpc",
    ))
}

fn events<'a>(records: &'a [Value], event: &str) -> Vec<&'a Value> {
    records
        .iter()
        .filter(|record| record["event"] == event)
        .collect()
}

fn decisions(records: &[Value]) -> Vec<(String, String)> {
    events(records, "desktop/decision")
        .into_iter()
        .map(|decision| {
            (
                decision["reason"].as_str().unwrap_or_default().to_string(),
                decision["action"].as_str().unwrap_or_default().to_string(),
            )
        })
        .collect()
}

fn only_decision(records: &[Value]) -> (String, String) {
    let decisions = decisions(records);
    assert_eq!(decisions.len(), 1, "expected one decision: {records:#?}");
    decisions[0].clone()
}

/// The host at the 16 September incident, plus the other owners a bundled
/// app-server can have. Only 89865 is a ChatGPT app instance.
fn incident_process_lines() -> Vec<(i32, String)> {
    [
        (1, "/sbin/launchd".to_string()),
        (
            9726,
            "/Users/developer/localbin/remote-coder-gateway/remote-coder-codex-gateway \
             --env-file /Users/developer/.remote-coder/codex-gateway.env"
                .to_string(),
        ),
        (
            9768,
            "/Users/developer/.codex/packages/standalone/current/codex app-server \
             --listen unix:///managed.sock"
                .to_string(),
        ),
        (89865, CHATGPT_EXECUTABLE.to_string()),
        (
            89870,
            "/Applications/ChatGPT.app/Contents/Resources/native/bare-modifier-monitor".to_string(),
        ),
        // The standalone Computer Use bridge and its native REPL.
        (
            15598,
            "/Users/developer/computer-use-bridge/.venv/bin/python \
             /Users/developer/computer-use-bridge/.venv/bin/native-cua serve"
                .to_string(),
        ),
        (
            73161,
            "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node launch.mjs".to_string(),
        ),
        (
            73163,
            "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl".to_string(),
        ),
        // The bridge-owned authentication helper that was killed.
        (
            90514,
            "/Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://".to_owned(),
        ),
        // A helper beneath the managed daemon, and one with an unknown
        // owner and another transport.
        (
            84423,
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex app-server --listen stdio://".to_owned(),
        ),
        (
            90000,
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex app-server --listen unix:///other.sock".to_owned(),
        ),
        // A ChatGPT app path with arguments is not the app instance.
        (91000, format!("{CHATGPT_EXECUTABLE} --type=renderer")),
    ]
    .into()
}

#[tokio::test(start_paused = true)]
async fn helpers_of_any_owner_never_restart_or_stop_chatgpt() {
    let (control, records, result) = reconcile_scenario(FakeDesktopState {
        process_lines: Some(incident_process_lines()),
        observations: HashMap::from([(89865, attached())]),
        ..Default::default()
    })
    .await;

    result.expect("a correctly attached app is healthy whatever else runs");

    assert!(control.requests().is_empty(), "nothing may be stopped");
    assert_eq!(control.opens(), 0, "nothing may be relaunched");
    assert_eq!(only_decision(&records), ("healthy".into(), "none".into()));
    let observed = events(&records, "desktop/observed");
    assert_eq!(observed[0]["appPids"], json!([89865]));
    assert_eq!(observed[0]["processes"][0]["observation"], "matches");
    assert_eq!(
        observed[0]["processes"][0]["startedMicros"],
        json!(app(89865).started_micros)
    );
}

#[tokio::test(start_paused = true)]
async fn an_explicit_stop_quits_only_the_app_instance() {
    let dir = tempfile::tempdir().expect("temp dir");
    let journal = DesktopJournal::in_dir(dir.path(), "stop", "install");
    let control = FakeDesktop::new(FakeDesktopState {
        process_lines: Some(incident_process_lines()),
        ..Default::default()
    });

    stop_chatgpt(&control, &journal, DesktopStopAuthority::Requested)
        .await
        .expect("the app quits");

    assert_eq!(control.requests(), vec![(89865, StopMethod::Quit)]);
    let state = control.state.lock().expect("fake state");
    let survivors = state.process_lines.as_ref().expect("listing");
    for helper in [89870, 15598, 73161, 73163, 90514, 84423, 90000, 91000] {
        assert!(
            survivors.iter().any(|(pid, _)| *pid == helper),
            "{helper} must be untouched"
        );
    }
    drop(state);
    let records = journal.records();
    let stop = events(&records, "desktop/stop");
    assert_eq!(stop.len(), 1, "a clean quit needs no escalation");
    assert_eq!(stop[0]["method"], "quit");
    assert_eq!(stop[0]["authority"], "requested");
    assert_eq!(
        stop[0]["targets"],
        json!([{
            "pid": 89865,
            "startedMicros": app(89865).started_micros,
            "evidence": "requested",
        }])
    );
    let waits = events(&records, "desktop/stopWait");
    assert_eq!(waits[0]["method"], "quit");
    assert_eq!(waits[0]["exited"], json!(true));
}

#[tokio::test(start_paused = true)]
async fn an_absent_app_is_launched() {
    let (control, records, result) = reconcile_scenario(FakeDesktopState {
        launch_spawns: Some((app(4242), attached())),
        ..Default::default()
    })
    .await;

    result.expect("an absent app is launched");

    assert!(control.requests().is_empty(), "nothing was running to stop");
    assert_eq!(control.opens(), 1);
    assert_eq!(
        only_decision(&records),
        ("app-absent".into(), "launch".into())
    );
    assert_eq!(
        events(&records, "desktop/launchResult")[0]["appPids"],
        json!([4242])
    );
    assert_eq!(events(&records, "desktop/stabilized")[0]["ok"], json!(true));
}

#[tokio::test(start_paused = true)]
async fn a_confirmed_mismatch_quits_and_relaunches_with_safe_field_evidence() {
    let (control, records, result) = reconcile_scenario(FakeDesktopState {
        process_lines: Some(incident_process_lines()),
        observations: HashMap::from([(89865, detached())]),
        launch_spawns: Some((app(67483), attached())),
        ..Default::default()
    })
    .await;

    result.expect("a mismatched app is replaced");

    assert_eq!(control.requests(), vec![(89865, StopMethod::Quit)]);
    assert_eq!(control.opens(), 1);
    assert_eq!(
        decisions(&records),
        vec![
            ("environment-mismatch".into(), "stop-mismatched".into()),
            ("app-absent".into(), "launch".into()),
        ]
    );

    // The exact field that differed is retained, so a restart can be
    // attributed without re-reading a process that no longer exists.
    let observed = &events(&records, "desktop/observed")[0]["processes"][0]["observed"];
    assert_eq!(observed["appServerWsUrlMatches"], json!(false));
    assert!(observed.get("sslCertFileMatches").is_none());
    assert_eq!(
        observed["appServerWsUrl"],
        "ws+unix://localhost/tmp/private.sock:/rpc"
    );

    // Intent precedes the request, and both name the same target with the
    // observation that selected it.
    let stop = events(&records, "desktop/stop");
    assert_eq!(stop[0]["authority"], "environment-mismatch");
    assert_eq!(stop[0]["method"], "quit");
    assert_eq!(stop[0]["targets"][0]["pid"], json!(89865));
    assert_eq!(stop[0]["targets"][0]["evidence"], "differs");
    let requested = events(&records, "desktop/signal");
    assert_eq!(requested.len(), 1);
    assert_eq!(requested[0]["pid"], json!(89865));
    assert_eq!(requested[0]["method"], "quit");
    assert_eq!(requested[0]["outcome"], "sent");
}

#[tokio::test(start_paused = true)]
async fn an_unreadable_process_is_never_treated_as_a_mismatch() {
    let (control, records, result) = reconcile_scenario(FakeDesktopState {
        apps: vec![app(84038)],
        observations: HashMap::from([(
            84038,
            EnvironmentObservation::Unreadable {
                detail: "ps exited with exit status: 1".to_string(),
            },
        )]),
        ..Default::default()
    })
    .await;

    let error = result.expect_err("an unobservable host aborts");
    assert!(
        format!("{error:#}").contains("could not be observed"),
        "unexpected error: {error:#}"
    );

    assert!(
        control.requests().is_empty(),
        "an unreadable process must never be stopped"
    );
    assert_eq!(
        control.opens(),
        0,
        "an unreadable process must never be relaunched"
    );
    assert_eq!(
        only_decision(&records),
        ("observation-failed".into(), "abort".into())
    );
    assert_eq!(
        events(&records, "desktop/observed")[0]["processes"][0]["detail"],
        "ps exited with exit status: 1"
    );
}

#[tokio::test(start_paused = true)]
async fn a_quit_that_times_out_escalates_to_kill() {
    let dir = tempfile::tempdir().expect("temp dir");
    let journal = DesktopJournal::in_dir(dir.path(), "stop", "manual");
    let control = FakeDesktop::new(FakeDesktopState {
        apps: vec![app(777)],
        ignores_quit: HashSet::from([777]),
        ..Default::default()
    });

    stop_chatgpt(&control, &journal, DesktopStopAuthority::Requested)
        .await
        .expect("escalation stops the app");

    assert_eq!(
        control.requests(),
        vec![(777, StopMethod::Quit), (777, StopMethod::Kill)]
    );
    let records = journal.records();
    let waits = events(&records, "desktop/stopWait");
    assert_eq!(waits[0]["method"], "quit");
    assert_eq!(waits[0]["exited"], json!(false));
    assert_eq!(waits[0]["remainingAppPids"], json!([777]));
    assert!(
        waits[0]["waitedMs"].as_u64().unwrap_or_default() >= 10_000,
        "the whole quit window elapses first: {waits:#?}"
    );
    assert_eq!(waits[1]["method"], "SIGKILL");
    assert_eq!(waits[1]["exited"], json!(true));
    let stops = events(&records, "desktop/stop");
    assert_eq!(stops[1]["method"], "SIGKILL");
    assert_eq!(stops[1]["targets"][0]["evidence"], "requested");
}

#[tokio::test(start_paused = true)]
async fn undeliverable_requests_are_recorded_and_the_stop_fails() {
    let dir = tempfile::tempdir().expect("temp dir");
    let journal = DesktopJournal::in_dir(dir.path(), "stop", "manual");
    let control = FakeDesktop::new(FakeDesktopState {
        apps: vec![app(888)],
        quit_failures: HashSet::from([888]),
        kill_failures: HashSet::from([888]),
        ..Default::default()
    });

    let error = stop_chatgpt(&control, &journal, DesktopStopAuthority::Requested)
        .await
        .expect_err("a process that cannot be stopped must not be reported stopped");
    assert!(format!("{error:#}").contains("did not stop"), "{error:#}");

    let records = journal.records();
    let requested = events(&records, "desktop/signal");
    assert_eq!(requested.len(), 2);
    assert!(requested.iter().all(|record| record["outcome"] == "failed"));
    assert!(
        requested.iter().all(|record| record["detail"]
            .as_str()
            .is_some_and(|detail| detail.contains("888"))),
        "the failing target must be named: {requested:#?}"
    );
    let failed = events(&records, "desktop/stopFailed");
    assert_eq!(failed[0]["reason"], "targets-survived");
    assert_eq!(failed[0]["appPids"], json!([888]));
}

#[tokio::test(start_paused = true)]
async fn a_process_reusing_a_target_pid_is_never_killed() {
    let dir = tempfile::tempdir().expect("temp dir");
    let journal = DesktopJournal::in_dir(dir.path(), "stop", "transition");
    let replacement = DesktopApp {
        pid: 777,
        started_micros: app(777).started_micros + 1,
    };
    let control = FakeDesktop::new(FakeDesktopState {
        apps: vec![app(777)],
        starts_during_stop: Some(replacement),
        ..Default::default()
    });

    let error = stop_chatgpt(&control, &journal, DesktopStopAuthority::Requested)
        .await
        .expect_err("an instance that was never selected keeps the stop incomplete");
    assert!(format!("{error:#}").contains("left running"), "{error:#}");

    assert_eq!(
        control.requests(),
        vec![(777, StopMethod::Quit)],
        "the replacement shares the pid but is another process"
    );
    let records = journal.records();
    assert_eq!(
        events(&records, "desktop/stopWait")[0]["exited"],
        json!(true)
    );
    let failed = events(&records, "desktop/stopFailed");
    assert_eq!(failed[0]["reason"], "unselected-instance");
    assert_eq!(failed[0]["appPids"], json!([777]));
}

#[tokio::test(start_paused = true)]
async fn reconciliation_stops_only_the_instances_it_observed() {
    let dir = tempfile::tempdir().expect("temp dir");
    let journal = DesktopJournal::in_dir(dir.path(), "launch", "periodic");
    let observations = [
        (app(10), detached()),
        (app(11), EnvironmentObservation::Vanished),
        (app(13), attached()),
    ];
    // 12 started after the observation; 11 exited and its pid is reused;
    // 13 is a retained matching sibling.
    let control = FakeDesktop::new(FakeDesktopState {
        apps: vec![
            app(10),
            app(12),
            DesktopApp {
                pid: 11,
                started_micros: 1,
            },
            app(13),
        ],
        ..Default::default()
    });

    let error = stop_chatgpt(
        &control,
        &journal,
        DesktopStopAuthority::Reconciled {
            reason: DesktopReason::EnvironmentMismatch,
            observations: &observations,
        },
    )
    .await
    .expect_err("unobserved instances keep the stop incomplete");
    assert!(format!("{error:#}").contains("left running"), "{error:#}");

    assert_eq!(control.requests(), vec![(10, StopMethod::Quit)]);
    let records = journal.records();
    assert_eq!(
        events(&records, "desktop/stop")[0]["targets"],
        json!([{
            "pid": 10,
            "startedMicros": app(10).started_micros,
            "evidence": "differs",
        }])
    );
    assert_eq!(
        events(&records, "desktop/stopFailed")[0]["appPids"],
        json!([12, 11])
    );
}

#[tokio::test(start_paused = true)]
async fn a_failed_launch_is_recorded() {
    let (_control, records, result) = reconcile_scenario(FakeDesktopState {
        open_error: Some("Launch Services failed to open ChatGPT".to_string()),
        ..Default::default()
    })
    .await;

    result.expect_err("a failed launch surfaces");

    assert_eq!(
        only_decision(&records),
        ("app-absent".into(), "launch".into())
    );
    let result = events(&records, "desktop/launchResult");
    assert_eq!(result[0]["ok"], json!(false));
    assert!(
        result[0]["detail"]
            .as_str()
            .is_some_and(|detail| detail.contains("Launch Services")),
        "{result:#?}"
    );
}

#[tokio::test(start_paused = true)]
async fn a_launch_that_never_stabilizes_names_its_last_observation() {
    let (_control, records, result) = reconcile_scenario(FakeDesktopState {
        launch_spawns: Some((app(999), detached())),
        ..Default::default()
    })
    .await;

    let error = result.expect_err("an app that never attaches fails");
    let message = format!("{error:#}");
    assert!(message.contains("did not stabilize"), "{message}");
    assert!(message.contains("environment-mismatch"), "{message}");

    let stabilized = events(&records, "desktop/stabilized");
    assert_eq!(stabilized[0]["ok"], json!(false));
    assert_eq!(stabilized[0]["reason"], "environment-mismatch");
    assert_eq!(stabilized[0]["appPids"], json!([999]));
    assert!(
        stabilized[0]["waitedMs"].as_u64().unwrap_or_default() >= 60_000,
        "the stabilization window must be exhausted: {stabilized:#?}"
    );
}

#[tokio::test(start_paused = true)]
async fn a_mismatch_stops_only_its_own_instance_and_keeps_a_matching_sibling() {
    let (control, records, result) = reconcile_scenario(FakeDesktopState {
        apps: vec![app(20), app(21)],
        observations: HashMap::from([(20, detached()), (21, attached())]),
        // The mismatched instance ignores the quit, so escalation runs too.
        ignores_quit: HashSet::from([20]),
        launch_spawns: Some((app(4242), attached())),
        ..Default::default()
    })
    .await;

    result.expect("the matching sibling is left as the healthy instance");

    assert_eq!(
        control.requests(),
        vec![(20, StopMethod::Quit), (20, StopMethod::Kill)]
    );
    assert_eq!(control.opens(), 0, "opening would only activate 21");
    assert!(
        control
            .state
            .lock()
            .expect("fake state")
            .apps
            .contains(&app(21))
    );
    assert_eq!(
        decisions(&records),
        vec![
            ("environment-mismatch".into(), "stop-mismatched".into()),
            ("healthy".into(), "none".into()),
        ]
    );
    for stop in events(&records, "desktop/stop") {
        assert_eq!(stop["targets"].as_array().map(Vec::len), Some(1), "{stop}");
        assert_eq!(stop["targets"][0]["pid"], json!(20));
    }
    assert!(events(&records, "desktop/stopFailed").is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_mismatch_never_stops_an_unreadable_sibling_or_relaunches_past_it() {
    let unreadable = EnvironmentObservation::Unreadable {
        detail: "ps could not run".to_string(),
    };
    let (control, records, result) = reconcile_scenario(FakeDesktopState {
        apps: vec![app(31), app(30)],
        observations: HashMap::from([(30, detached()), (31, unreadable)]),
        launch_spawns: Some((app(4242), attached())),
        ..Default::default()
    })
    .await;

    let error = result.expect_err("an unreadable sibling cannot be declared healthy");
    let message = format!("{error:#}");
    assert!(message.contains("observation-failed"), "{message}");
    assert!(message.contains("left running"), "{message}");

    assert_eq!(control.requests(), vec![(30, StopMethod::Quit)]);
    assert_eq!(control.opens(), 0);
    assert_eq!(
        decisions(&records),
        vec![
            ("environment-mismatch".into(), "stop-mismatched".into()),
            ("observation-failed".into(), "abort".into()),
        ]
    );
}

#[tokio::test(start_paused = true)]
async fn a_target_replaced_before_delivery_is_never_signalled() {
    let dir = tempfile::tempdir().expect("temp dir");
    let journal = DesktopJournal::in_dir(dir.path(), "stop", "install");
    let replacement = DesktopApp {
        pid: 40,
        started_micros: app(40).started_micros + 1,
    };
    let control = FakeDesktop::new(FakeDesktopState {
        apps: vec![app(40)],
        replaces_before_delivery: Some(replacement),
        ..Default::default()
    });

    let error = stop_chatgpt(&control, &journal, DesktopStopAuthority::Requested)
        .await
        .expect_err("the replacement was never selected");
    assert!(format!("{error:#}").contains("left running"), "{error:#}");

    assert!(control.requests().is_empty(), "nothing may be sent to 40");
    assert!(
        control
            .state
            .lock()
            .expect("fake state")
            .apps
            .contains(&replacement)
    );
    let records = journal.records();
    let signals = events(&records, "desktop/signal");
    assert_eq!(signals.len(), 1);
    assert_eq!(signals[0]["outcome"], "target-gone");
    assert_eq!(
        signals[0]["startedMicros"],
        json!(app(40).started_micros),
        "the record names the selected identity, not the replacement"
    );
    assert_eq!(
        events(&records, "desktop/stopFailed")[0]["reason"],
        "unselected-instance"
    );
}

#[tokio::test(start_paused = true)]
async fn an_unreadable_identity_during_a_stop_never_succeeds_or_escalates() {
    let dir = tempfile::tempdir().expect("temp dir");
    let journal = DesktopJournal::in_dir(dir.path(), "stop", "manual");
    let control = FakeDesktop::new(FakeDesktopState {
        apps: vec![app(50)],
        ignores_quit: HashSet::from([50]),
        listing_fails_after_request: Some(
            "could not read the start time of pid 50: Operation not permitted".to_string(),
        ),
        ..Default::default()
    });

    let error = stop_chatgpt(&control, &journal, DesktopStopAuthority::Requested)
        .await
        .expect_err("an unknown outcome is not a completed stop");
    assert!(format!("{error:#}").contains("pid 50"), "{error:#}");

    assert_eq!(control.requests(), vec![(50, StopMethod::Quit)]);
    let records = journal.records();
    assert!(events(&records, "desktop/stopWait").is_empty());
    assert_eq!(
        only_decision(&records),
        ("observation-failed".into(), "abort".into())
    );
}

fn identity(executable: &str, started_micros: u64) -> mac_app::ProcessIdentity {
    mac_app::ProcessIdentity {
        started_micros,
        executable: PathBuf::from(executable),
    }
}

#[test]
fn listing_revalidates_each_pid_and_never_turns_an_unreadable_one_into_absence() {
    let identify = |pid: i32| -> Result<Option<mac_app::ProcessIdentity>> {
        match pid {
            1 => Ok(Some(identity(CHATGPT_EXECUTABLE, 11))),
            // Exited after `ps` listed it.
            2 => Ok(None),
            // The pid now runs something else.
            3 => Ok(Some(identity("/bin/sleep", 33))),
            _ => bail!("could not read the start time of pid {pid}"),
        }
    };
    assert_eq!(
        listed_apps(&[1, 2, 3], &identify).expect("readable"),
        vec![DesktopApp {
            pid: 1,
            started_micros: 11
        }]
    );
    let error = listed_apps(&[1, 4], &identify).expect_err("unknown is not absent");
    assert!(format!("{error:#}").contains("pid 4"), "{error:#}");
    assert!(current_app(4, &identify).is_err());
}

#[test]
fn a_vanished_process_is_neither_a_mismatch_nor_a_reason_to_wait() {
    assert_eq!(
        decide_desktop_action(&[
            (app(1), EnvironmentObservation::Vanished),
            (app(2), EnvironmentObservation::Matches),
        ]),
        DesktopReason::Healthy
    );
    assert_eq!(
        decide_desktop_action(&[
            (app(1), EnvironmentObservation::Vanished),
            (app(2), EnvironmentObservation::Vanished),
        ]),
        DesktopReason::AppAbsent
    );
}

#[tokio::test(start_paused = true)]
async fn a_read_only_check_never_stops_or_launches_in_any_branch() {
    let unreadable = EnvironmentObservation::Unreadable {
        detail: "ps could not run".to_string(),
    };
    for (observation, expected) in [
        (Some(attached()), "healthy"),
        (Some(detached()), "environment-mismatch"),
        (Some(unreadable), "observation-failed"),
        (None, "app-absent"),
    ] {
        let dir = tempfile::tempdir().expect("temp dir");
        let journal = DesktopJournal::in_dir(dir.path(), "check", "manual");
        let mut lines = incident_process_lines();
        if observation.is_none() {
            lines.retain(|(pid, _)| *pid != 89865);
        }
        let control = FakeDesktop::new(FakeDesktopState {
            process_lines: Some(lines),
            observations: observation
                .map(|observation| HashMap::from([(89865, observation)]))
                .unwrap_or_default(),
            launch_spawns: Some((app(4242), attached())),
            ..Default::default()
        });

        let reason = report_desktop_state(&control, &journal, &test_environment())
            .await
            .expect("listing succeeds");

        assert_eq!(reason.as_str(), expected);
        assert_eq!(
            only_decision(&journal.records()),
            (expected.to_string(), "report-only".to_string()),
            "a check must not claim it acted"
        );
        assert!(control.requests().is_empty(), "{expected}");
        assert_eq!(control.opens(), 0, "{expected}");
    }
}

#[test]
fn observed_environments_never_carry_the_process_environment() {
    let secrets = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT \
         SSL_CERT_FILE=/etc/ssl/cert.pem \
         CODEX_APP_SERVER_WS_URL=ws+unix://localhost/tmp/private.sock:/rpc \
         CODEX_APP_SERVER_FORCE_CLI=1 \
         CODEX_APP_SERVER_USE_LOCAL_DAEMON=1 \
         OPENAI_API_KEY=sk-live-must-never-be-logged \
         RC_CODEX_GATEWAY_AUTH_TOKEN=bearer-must-never-be-logged \
         AWS_SECRET_ACCESS_KEY=also-secret";
    let observed = test_environment().observe(secrets);
    assert!(observed.force_cli_present);
    assert!(observed.use_local_daemon_present);
    assert!(!observed.matches());

    let dir = tempfile::tempdir().expect("temp dir");
    let journal = DesktopJournal::in_dir(dir.path(), "launch", "periodic");
    record_observation(
        &journal,
        &[(app(7), EnvironmentObservation::Differs(observed))],
        &test_environment(),
    );
    let emitted = serde_json::to_string(&journal.records()).expect("records");
    for secret in [
        "sk-live-must-never-be-logged",
        "bearer-must-never-be-logged",
        "also-secret",
        "OPENAI_API_KEY",
        "AWS_SECRET_ACCESS_KEY",
    ] {
        assert!(
            !emitted.contains(secret),
            "{secret} leaked into a desktop record: {emitted}"
        );
    }
}

#[tokio::test(start_paused = true)]
async fn an_unlistable_host_records_why_it_aborted() {
    let (control, records, result) = reconcile_scenario(FakeDesktopState {
        list_error: Some("ps failed with exit status: 1".to_string()),
        ..Default::default()
    })
    .await;

    result.expect_err("a host that cannot be listed aborts");

    assert!(control.requests().is_empty());
    assert_eq!(control.opens(), 0);
    assert_eq!(
        only_decision(&records),
        ("observation-failed".into(), "abort".into()),
        "an abort with no recorded reason is the gap this journal exists to close"
    );
    let decision = events(&records, "desktop/decision")[0];
    assert_eq!(decision["stage"], "process-list");
    assert!(
        decision["detail"]
            .as_str()
            .is_some_and(|detail| detail.contains("ps failed")),
        "{decision}"
    );
}

#[test]
fn unusable_probe_output_is_unknown_rather_than_a_mismatch() {
    let environment = test_environment();
    for unusable in ["", "   ", "\n", "ps: process id too large: 999999", "?? ??"] {
        let classified = classify_probe_output(unusable.as_bytes(), &environment);
        assert!(
            classified.is_err(),
            "{unusable:?} must not classify as an attachment verdict: {classified:?}"
        );
    }
}

#[test]
fn a_recognizable_command_line_without_the_managed_variables_stays_a_mismatch() {
    // ChatGPT opened outside the managed launch path carries neither
    // variable. That is a real mismatch and must keep restarting it.
    let observation = classify_probe_output(
        format!("{CHATGPT_EXECUTABLE} OSLogRateLimit=64").as_bytes(),
        &test_environment(),
    )
    .expect("a recognizable command line classifies");
    assert!(matches!(observation, EnvironmentObservation::Differs(_)));

    let attached = classify_probe_output(managed_command().as_bytes(), &test_environment())
        .expect("a recognizable command line classifies");
    assert_eq!(attached, EnvironmentObservation::Matches);
}

#[test]
fn desktop_uses_the_managed_unix_websocket_directly() {
    assert_eq!(
        app_server_websocket_url(Path::new(
            "/Users/developer/.codex/app-server-control/app-server-control.sock"
        ))
        .expect("websocket URL"),
        "ws+unix://localhost/Users/developer/.codex/app-server-control/app-server-control.sock:/rpc"
    );
    assert!(app_server_websocket_url(Path::new("relative.sock")).is_err());
    assert!(app_server_websocket_url(Path::new("/tmp/invalid:socket")).is_err());
}

#[test]
fn desktop_process_must_carry_the_exact_managed_connection() {
    let environment = ChatGptEnvironment {
        app_server_ws_url: "ws+unix:///tmp/codex.sock:/rpc".to_string(),
    };
    for (command, attached) in [
        (
            "ChatGPT CODEX_APP_SERVER_WS_URL=ws+unix:///tmp/codex.sock:/rpc",
            true,
        ),
        (
            "ChatGPT SSL_CERT_FILE=/etc/ssl/cert.pem \
             CODEX_APP_SERVER_WS_URL=ws+unix:///tmp/codex.sock:/rpc",
            true,
        ),
        (
            "ChatGPT SSL_CERT_FILE=/etc/ssl/cert.pem \
             CODEX_APP_SERVER_WS_URL=ws+unix:///tmp/codex.sock:/rpc \
             CODEX_APP_SERVER_USE_LOCAL_DAEMON=1",
            true,
        ),
        (
            "ChatGPT SSL_CERT_FILE=/etc/ssl/cert.pem \
             CODEX_APP_SERVER_WS_URL=ws+unix:///tmp/other.sock:/rpc",
            false,
        ),
        (
            "ChatGPT SSL_CERT_FILE=/etc/ssl/cert.pem \
             CODEX_APP_SERVER_WS_URL=ws+unix:///tmp/codex.sock:/rpc \
             CODEX_APP_SERVER_FORCE_CLI=anything",
            false,
        ),
        (
            "ChatGPT SSL_CERT_FILE=/different/host-policy.pem \
             CODEX_APP_SERVER_WS_URL=ws+unix:///tmp/codex.sock:/rpc",
            true,
        ),
        (
            "ChatGPT SSL_CERT_FILE=/etc/ssl/cert.pem \
             CODEX_APP_SERVER_WS_URL=ws+unix:///tmp/codex.sock:/rpc-v2",
            false,
        ),
    ] {
        assert_eq!(
            environment.observe(command).matches(),
            attached,
            "{command}"
        );
    }
}

#[tokio::test]
async fn an_in_process_shutdown_handoff_leaves_unfinished_recovery_to_bootstrap() {
    let directory = tempfile::tempdir().expect("recovery directory");
    let store = RecoveryStore::new(directory.path().join("recovery.json"));
    let journal = RecoveryJournal::new(
        "generation-1".to_string(),
        "0123456789abcdef0123456789abcdef".to_string(),
        vec![RecoveryTask {
            thread_id: "thread-1".to_string(),
            turn_id: "turn-1".to_string(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 0,
            status: RecoveryTaskStatus::Suspended,
            error: None,
        }],
    )
    .expect("recovery journal");
    store.write(&journal).expect("write recovery journal");
    let app_server = CodexAppServer::new(PathBuf::from("/bin/false"), HashMap::new());

    let unfinished = RecoveryTransaction::new(&app_server, &store)
        .prepare_handoff_for_shutdown()
        .await
        .expect_err("an unfinished journal is not replaced");
    let lease = RuntimeLease::try_acquire(&store)
        .expect("lease")
        .expect("free lease");
    let contended = RecoveryTransaction::new(&app_server, &store)
        .prepare_handoff_for_shutdown()
        .await
        .expect_err("a held lease is not bypassed");
    drop(lease);

    assert!(
        unfinished.to_string().contains("generation-1"),
        "{unfinished:#}"
    );
    assert!(
        contended.to_string().contains("holds the lease"),
        "{contended:#}"
    );
    assert_eq!(store.load().expect("load").expect("journal"), journal);
}

#[test]
fn safe_reopen_closes_an_untouched_capture_journal() {
    let directory = tempfile::tempdir().expect("recovery directory");
    let store = RecoveryStore::new(directory.path().join("recovery.json"));
    let journal = RecoveryJournal::new(
        "generation-1".to_string(),
        "0123456789abcdef0123456789abcdef".to_string(),
        vec![RecoveryTask {
            thread_id: "thread-1".to_string(),
            turn_id: "turn-1".to_string(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 0,
            status: RecoveryTaskStatus::Captured,
            error: None,
        }],
    )
    .expect("recovery journal");
    store.write(&journal).expect("write recovery journal");

    complete_aborted_capture(&store).expect("complete aborted capture");

    let completed = store
        .load()
        .expect("load recovery journal")
        .expect("journal exists");
    assert_eq!(completed.phase, RecoveryPhase::Completed);
    assert_eq!(
        completed.error.as_deref(),
        Some("restart aborted before ownership transfer")
    );
}

#[test]
fn failed_replacement_returns_nonterminal_tasks_to_stopped_recovery() {
    let mut journal = RecoveryJournal::new(
        "generation-1".to_string(),
        "0123456789abcdef0123456789abcdef".to_string(),
        vec![RecoveryTask {
            thread_id: "thread-1".to_string(),
            turn_id: "turn-1".to_string(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 0,
            status: RecoveryTaskStatus::Running,
            error: None,
        }],
    )
    .expect("recovery journal");
    journal.phase = RecoveryPhase::Recovered;

    mark_recovery_failed_closed(&mut journal, true, "local completion failed");

    assert_eq!(journal.phase, RecoveryPhase::DaemonStopped);
    assert_eq!(journal.tasks[0].status, RecoveryTaskStatus::Suspended);
    assert_eq!(
        journal.error.as_deref(),
        Some("recovery failed closed: local completion failed")
    );
}

#[tokio::test(start_paused = true)]
async fn runtime_rpc_trickle_does_not_extend_its_operation_deadline() {
    let directory = tempfile::tempdir().expect("runtime socket dir");
    let socket = directory.path().join("app-server.sock");
    let listener = tokio::net::UnixListener::bind(&socket).expect("fake app-server");
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("client");
        let mut websocket = tokio_tungstenite::accept_async(stream)
            .await
            .expect("websocket");
        let _request = websocket
            .next()
            .await
            .expect("request")
            .expect("request frame");
        for index in 0..4 {
            tokio::time::sleep(Duration::from_secs(6)).await;
            if websocket
                .send(Message::Text(
                    json!({"method":"unrelated","params":{"index":index}}).to_string(),
                ))
                .await
                .is_err()
            {
                break;
            }
        }
    });
    let stream = tokio::net::UnixStream::connect(&socket)
        .await
        .expect("connect");
    let (websocket, _) = tokio_tungstenite::client_async("ws://localhost/", stream)
        .await
        .expect("client websocket");
    let mut client = RpcClient {
        websocket,
        next_id: 0,
    };
    let error = client
        .request::<_, Value>("slow/request", json!({}))
        .await
        .expect_err("unrelated frames must not restart the deadline");
    assert!(format!("{error:#}").contains("slow/request timed out"));
    server.abort();
}

#[tokio::test]
async fn restart_capture_requires_fresh_idle_evidence_for_ephemeral_threads() {
    for (ephemeral, status, readback_id, code, succeeds) in [
        (
            json!(true),
            json!({"type": "idle"}),
            "ephemeral",
            -32600,
            true,
        ),
        (
            json!(true),
            json!({"type": "active"}),
            "ephemeral",
            -32600,
            false,
        ),
        (json!(true), Value::Null, "ephemeral", -32600, false),
        (
            Value::Null,
            json!({"type": "idle"}),
            "ephemeral",
            -32600,
            false,
        ),
        (
            json!(false),
            json!({"type": "idle"}),
            "ephemeral",
            -32600,
            false,
        ),
        (
            json!(true),
            json!({"type": "idle"}),
            "different",
            -32600,
            false,
        ),
        (
            json!(true),
            json!({"type": "idle"}),
            "ephemeral",
            -32603,
            false,
        ),
    ] {
        let directory = tempfile::tempdir().expect("runtime socket dir");
        let socket = directory.path().join("app-server.sock");
        let listener = tokio::net::UnixListener::bind(&socket).expect("fake app-server");
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("client");
            let mut websocket = tokio_tungstenite::accept_async(stream)
                .await
                .expect("websocket");
            let mut ephemeral_reads = 0;
            while let Some(Ok(Message::Text(raw))) = websocket.next().await {
                let request: Value = serde_json::from_str(&raw).expect("request");
                let Some(id) = request.get("id") else {
                    continue;
                };
                let thread = request["params"]["threadId"].as_str().unwrap_or_default();
                let reply = match request["method"].as_str().expect("method") {
                    "initialize" => json!({"result": {}}),
                    "thread/loaded/list" => json!({"result": {
                        "data": ["parent", "child", "ephemeral"], "nextCursor": null
                    }}),
                    "thread/read" if thread == "ephemeral" => {
                        ephemeral_reads += 1;
                        if ephemeral_reads == 1 {
                            json!({"result": {"thread": {
                                "id": "ephemeral", "ephemeral": true,
                                "status": {"type": "active"}
                            }}})
                        } else {
                            json!({"result": {"thread": {
                                "id": readback_id, "ephemeral": ephemeral, "status": status
                            }}})
                        }
                    }
                    "thread/read" => json!({"result": {"thread": {
                        "id": thread, "ephemeral": false,
                        "parentThreadId": if thread == "child" { Some("parent") } else { None },
                        "status": {"type": "active"}
                    }}}),
                    "thread/turns/list" if thread == "ephemeral" => json!({"error": {
                        "code": code,
                        "message": "ephemeral threads do not support thread/turns/list"
                    }}),
                    "thread/turns/list" => json!({"result": {"data": [{
                        "id": format!("turn-{thread}"), "status": "inProgress"
                    }]}}),
                    other => panic!("unexpected request {other}"),
                };
                let mut response = reply;
                response["id"] = id.clone();
                websocket
                    .send(Message::Text(response.to_string()))
                    .await
                    .expect("response");
            }
        });
        let stream = tokio::net::UnixStream::connect(&socket)
            .await
            .expect("connect");
        let (websocket, _) = tokio_tungstenite::client_async("ws://localhost/", stream)
            .await
            .expect("client websocket");
        let mut rpc = RpcClient::initialize(websocket).await.expect("runtime RPC");
        let result = super::rpc::snapshot_active_tasks(&mut rpc).await;
        assert_eq!(result.is_ok(), succeeds, "{result:?}");
        if succeeds {
            let mut tasks = result.expect("complete durable capture");
            tasks.sort_by(|left, right| left.thread_id.cmp(&right.thread_id));
            assert_eq!(
                tasks
                    .iter()
                    .map(|task| (
                        task.thread_id.as_str(),
                        task.turn_id.as_str(),
                        task.parent_thread_id.as_deref(),
                        task.depth,
                    ))
                    .collect::<Vec<_>>(),
                vec![
                    ("child", "turn-child", Some("parent"), 1),
                    ("parent", "turn-parent", None, 0),
                ]
            );
        } else {
            assert!(format!("{:#}", result.expect_err("unsafe capture")).contains("ephemeral"));
        }
        drop(rpc);
        server.await.expect("fake server");
    }
}

#[tokio::test]
async fn partial_account_capture_rolls_back_exact_tree_leaf_first() {
    let directory = tempfile::tempdir().expect("runtime state");
    let socket = directory.path().join("app-server.sock");
    let listener = tokio::net::UnixListener::bind(&socket).expect("fake app-server");
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("client");
        let mut websocket = tokio_tungstenite::accept_async(stream)
            .await
            .expect("websocket");
        let mut suspended = Vec::new();
        while let Some(Ok(Message::Text(raw))) = websocket.next().await {
            let request: Value = serde_json::from_str(&raw).expect("request");
            let Some(id) = request.get("id") else {
                continue;
            };
            let method = request["method"].as_str().expect("method");
            let thread = request["params"]["threadId"].as_str().unwrap_or_default();
            let result = match method {
                "initialize" => json!({}),
                "thread/loaded/list" => {
                    json!({"data": ["parent", "child"], "nextCursor": null})
                }
                "thread/read" => json!({"thread": {
                    "id": thread,
                    "parentThreadId": if thread == "child" { Some("parent") } else { None },
                    "status": {"type": "active"}
                }}),
                "thread/turns/list" => json!({"data": [{
                    "id": format!("turn-{thread}"), "status": "inProgress"
                }]}),
                "thread/restart/suspend" => {
                    suspended.push(thread.to_owned());
                    json!({"outcome": {"status": "suspended", "turnId": format!("turn-{thread}")}})
                }
                other => panic!("unexpected request {other}"),
            };
            websocket
                .send(Message::Text(
                    json!({"jsonrpc": "2.0", "id": id, "result": result}).to_string(),
                ))
                .await
                .expect("response");
        }
        suspended
    });
    let stream = tokio::net::UnixStream::connect(&socket)
        .await
        .expect("connect");
    let (websocket, _) = tokio_tungstenite::client_async("ws://localhost/", stream)
        .await
        .expect("client websocket");
    let mut rpc = RpcClient::initialize(websocket).await.expect("runtime RPC");
    let store = RecoveryStore::new(directory.path().join("account-recovery.json"));
    let previous = "b".repeat(64);
    let candidate = "a".repeat(64);
    let mut journal = RecoveryJournal::new(
        "generation-1".to_owned(),
        "0123456789abcdef0123456789abcdef".to_owned(),
        vec![RecoveryTask {
            thread_id: "parent".to_owned(),
            turn_id: "turn-parent".to_owned(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 0,
            status: RecoveryTaskStatus::Captured,
            error: None,
        }],
    )
    .expect("partial account journal");
    journal.account = Some(crate::runtime::recovery::AccountRecovery {
        account_id: "11111111-1111-1111-1111-111111111111".to_owned(),
        enrollment_generation: 7,
        native_directory: directory.path().join("c"),
        source_sha256: previous.clone(),
        target_sha256: candidate,
    });
    store
        .write(&journal)
        .expect("persist before resumed capture");
    accounts::finish_account_capture(&mut rpc, &store, "generation-1")
        .await
        .expect("exact rollback suspension");
    drop(rpc);
    assert_eq!(server.await.expect("fake server"), vec!["child", "parent"]);
    store
        .update("generation-1", |journal| {
            journal.phase = RecoveryPhase::DaemonStopped;
            Ok(())
        })
        .expect("old daemon stopped");
    let journal = store
        .load()
        .expect("read journal")
        .expect("retained journal");
    assert!(journal.is_prepared_handoff());
    assert_eq!(journal.tasks.len(), 2);
    assert!(
        journal
            .tasks
            .iter()
            .all(|task| task.status == RecoveryTaskStatus::Suspended)
    );
    assert_eq!(
        journal
            .tasks
            .iter()
            .find(|task| task.thread_id == "child")
            .expect("child")
            .turn_id,
        "turn-child"
    );
    assert_eq!(
        journal
            .tasks
            .iter()
            .find(|task| task.thread_id == "child")
            .expect("child")
            .depth,
        1
    );
    let grant_path = write_grant(store.path(), &journal).expect("exact recovery grant");
    let grant: Value = serde_json::from_slice(&std::fs::read(grant_path).expect("grant bytes"))
        .expect("grant JSON");
    let targets = grant["targets"].as_array().expect("recovery targets");
    assert!(targets.contains(&json!({"threadId": "parent", "turnId": "turn-parent"})));
    assert!(targets.contains(&json!({"threadId": "child", "turnId": "turn-child"})));
}

#[tokio::test]
async fn lost_first_suspend_reply_keeps_exact_account_turn_for_retry() {
    let directory = tempfile::tempdir().expect("runtime state");
    let socket = directory.path().join("app-server.sock");
    let listener = tokio::net::UnixListener::bind(&socket).expect("fake app-server");
    let server = tokio::spawn(async move {
        let mut suspension_count = 0;
        for connection in 0..2 {
            let (stream, _) = listener.accept().await.expect("client");
            let mut websocket = tokio_tungstenite::accept_async(stream)
                .await
                .expect("websocket");
            while let Some(Ok(Message::Text(raw))) = websocket.next().await {
                let request: Value = serde_json::from_str(&raw).expect("request");
                let Some(id) = request.get("id") else {
                    continue;
                };
                let result = match request["method"].as_str().expect("method") {
                    "initialize" => json!({}),
                    "thread/loaded/list" => json!({
                        "data": if connection == 0 { vec!["thread-1"] } else { vec![] },
                        "nextCursor": null
                    }),
                    "thread/read" => json!({"thread": {
                        "id": "thread-1", "parentThreadId": null,
                        "status": {"type": "active"}
                    }}),
                    "thread/turns/list" => json!({"data": [{
                        "id": "turn-1", "status": "inProgress"
                    }]}),
                    "thread/restart/suspend" => {
                        suspension_count += 1;
                        if connection == 0 {
                            // The native mutation happened, but its reply was lost.
                            break;
                        }
                        json!({"outcome": {"status": "suspended", "turnId": "turn-1"}})
                    }
                    other => panic!("unexpected request {other}"),
                };
                websocket
                    .send(Message::Text(
                        json!({
                            "jsonrpc": "2.0", "id": id, "result": result
                        })
                        .to_string(),
                    ))
                    .await
                    .expect("response");
            }
        }
        suspension_count
    });
    let store = RecoveryStore::new(directory.path().join("account-recovery.json"));
    let mut journal = RecoveryJournal::new(
        "generation-1".to_owned(),
        "0123456789abcdef0123456789abcdef".to_owned(),
        vec![RecoveryTask {
            thread_id: "thread-1".to_owned(),
            turn_id: "turn-1".to_owned(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 0,
            status: RecoveryTaskStatus::Captured,
            error: None,
        }],
    )
    .expect("journal");
    journal.phase = RecoveryPhase::Suspending;
    store.write(&journal).expect("durable mutation boundary");
    for attempt in 0..2 {
        let stream = tokio::net::UnixStream::connect(&socket)
            .await
            .expect("connect");
        let (websocket, _) = tokio_tungstenite::client_async("ws://localhost/", stream)
            .await
            .expect("client websocket");
        let mut rpc = RpcClient::initialize(websocket).await.expect("runtime RPC");
        let result = accounts::finish_account_capture(&mut rpc, &store, "generation-1").await;
        if attempt == 0 {
            assert!(result.is_err(), "lost reply must fail closed");
        } else {
            result.expect("retry exact suspension");
        }
        drop(rpc);
        let persisted = store.load().expect("read journal").expect("journal");
        if attempt == 0 {
            assert_eq!(persisted.phase, RecoveryPhase::Suspending);
            assert_eq!(persisted.tasks[0].status, RecoveryTaskStatus::Captured);
        } else {
            assert_eq!(persisted.phase, RecoveryPhase::Suspended);
            assert_eq!(persisted.tasks[0].status, RecoveryTaskStatus::Suspended);
            assert_eq!(persisted.tasks[0].turn_id, "turn-1");
        }
    }
    assert_eq!(server.await.expect("fake server"), 2);
}

#[tokio::test]
async fn failed_retry_publication_restores_only_an_uncommitted_generation() {
    for failure in ["before-write", "after-rename", "concurrent-stop"] {
        let directory = tempfile::tempdir().unwrap();
        let fake = crate::test_support::FakeLifecycleCodex::new(
            directory.path(),
            crate::test_support::LifecycleMode::RecordActions,
        );
        let server = fake.server(&directory.path().join("native"));
        fake.write_reply(&server);
        let store = RecoveryStore::new(directory.path().join("recovery.json"));
        let mut original = RecoveryJournal::new(
            "original-generation".to_owned(),
            "0123456789abcdef0123456789abcdef".to_owned(),
            vec![
                RecoveryTask {
                    thread_id: "thread-1".to_owned(),
                    turn_id: "turn-1".to_owned(),
                    parent_thread_id: None,
                    depth: 0,
                    recovery_attempts: 1,
                    status: RecoveryTaskStatus::Failed,
                    error: Some("restart recovery is not authorized".to_owned()),
                },
                RecoveryTask {
                    thread_id: "running-thread".to_owned(),
                    turn_id: "running-turn".to_owned(),
                    parent_thread_id: None,
                    depth: 0,
                    recovery_attempts: 0,
                    status: RecoveryTaskStatus::Running,
                    error: None,
                },
            ],
        )
        .unwrap();
        original.phase = RecoveryPhase::Completed;
        store.write(&original).unwrap();
        let mut prepared = original.clone();
        let mut captured = original.tasks[1].clone();
        captured.status = RecoveryTaskStatus::Captured;
        prepared.prepare_failed_retry(vec![captured]).unwrap();
        let expected = match failure {
            "before-write" => {
                store.fail_next_write();
                original.clone()
            }
            "after-rename" => {
                store.fail_after_next_rename();
                prepared.clone()
            }
            "concurrent-stop" => store
                .update(&original.generation_id, |current| {
                    current.tasks[1].update_status(RecoveryTaskStatus::Completed, None);
                    Ok(())
                })
                .unwrap(),
            _ => unreachable!(),
        };
        let error = RecoveryTransaction::new(&server, &store)
            .persist_failed_retry(&original, prepared)
            .await
            .expect_err("publication failure must remain visible");

        assert_eq!(store.load().unwrap().unwrap(), expected, "{failure}");
        let actions = std::fs::read_to_string(&fake.actions).unwrap_or_default();
        if failure == "after-rename" {
            assert!(actions.is_empty());
            assert!(error.to_string().contains("admission remains fenced"));
        } else {
            assert_eq!(actions, "cancel-restart\n", "{failure}");
            assert!(error.to_string().contains("admission was restored"));
        }
    }
}

#[tokio::test]
async fn recovery_start_does_not_reuse_an_ungranted_live_daemon() {
    let directory = tempfile::tempdir().expect("recovery state");
    let fake = crate::test_support::FakeLifecycleCodex::new(
        directory.path(),
        crate::test_support::LifecycleMode::CaptureGrant,
    );
    let native = directory.path().join("native");
    let server = fake.server(&native);
    fake.write_reply(&server);
    std::fs::create_dir_all(native.join("app-server-daemon")).unwrap();
    std::fs::write(
        native.join("app-server-daemon/app-server.pid"),
        serde_json::to_vec(&json!({
            "pid": std::process::id(),
            "processIdentity": crate::test_support::current_process_identity()
        }))
        .unwrap(),
    )
    .unwrap();
    let store = RecoveryStore::new(directory.path().join("recovery.json"));
    let mut journal = RecoveryJournal::new(
        "generation-1".to_owned(),
        "0123456789abcdef0123456789abcdef".to_owned(),
        vec![RecoveryTask {
            thread_id: "transferred-thread".to_owned(),
            turn_id: "original-turn".to_owned(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 0,
            status: RecoveryTaskStatus::Suspended,
            error: None,
        }],
    )
    .unwrap();
    journal.phase = RecoveryPhase::DaemonStopped;
    store.write(&journal).unwrap();

    let error = RecoveryTransaction::new(&server, &store)
        .start_recovery_daemon(&journal)
        .await
        .expect_err("an existing daemon cannot acquire a startup grant");

    assert!(error.to_string().contains("requires a stopped daemon"));
    assert_eq!(store.load().unwrap().unwrap(), journal);
    assert!(!fake.grant_capture.exists());
}

#[tokio::test]
async fn failed_recovery_retry_requires_the_exact_unfinished_native_turn() {
    let directory = tempfile::Builder::new()
        .prefix("rc-retry-")
        .tempdir_in("/tmp")
        .unwrap();
    let socket = directory.path().join("rpc.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let cases = [
        (
            json!({"id":"original-turn","status":"interrupted","completedAt":null}),
            true,
        ),
        (json!({"id":"original-turn","status":"inProgress"}), true),
        (json!({"id":"other-turn","status":"inProgress"}), false),
        (
            json!({"id":"original-turn","status":"interrupted","completedAt":123}),
            false,
        ),
        (
            json!({"id":"original-turn","status":"completed","completedAt":123}),
            false,
        ),
        (json!({"id":"original-turn","status":"failed"}), false),
    ];
    let replies = cases
        .iter()
        .map(|(turn, _)| turn.clone())
        .collect::<Vec<_>>();
    let peer = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut websocket = tokio_tungstenite::accept_async(stream).await.unwrap();
        let mut replies = replies.into_iter();
        while let Some(Ok(Message::Text(raw))) = websocket.next().await {
            let request: Value = serde_json::from_str(&raw).unwrap();
            let Some(id) = request.get("id") else {
                continue;
            };
            let result = match request["method"].as_str().unwrap() {
                "initialize" => json!({}),
                "thread/turns/list" => {
                    assert_eq!(request["params"]["threadId"], "failed-thread");
                    json!({"data": [replies.next().expect("one read per failed target")]})
                }
                method => panic!("retry preflight unexpectedly mutated native state: {method}"),
            };
            websocket
                .send(Message::Text(json!({"id":id,"result":result}).to_string()))
                .await
                .unwrap();
        }
        assert!(replies.next().is_none());
    });
    let stream = tokio::net::UnixStream::connect(&socket).await.unwrap();
    let (websocket, _) = tokio_tungstenite::client_async("ws://localhost/", stream)
        .await
        .unwrap();
    let mut rpc = RpcClient::initialize(websocket).await.unwrap();
    let journal = RecoveryJournal::new(
        "generation-1".to_owned(),
        "0123456789abcdef0123456789abcdef".to_owned(),
        vec![RecoveryTask {
            thread_id: "failed-thread".to_owned(),
            turn_id: "original-turn".to_owned(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 1,
            status: RecoveryTaskStatus::Failed,
            error: Some("restart recovery is not authorized".to_owned()),
        }],
    )
    .unwrap();
    for (turn, expected) in cases {
        assert_eq!(
            super::rpc::verify_failed_recovery_targets(&mut rpc, &journal)
                .await
                .is_ok(),
            expected,
            "{turn}"
        );
    }
    drop(rpc);
    peer.await.unwrap();
}

#[tokio::test]
async fn stopped_account_reconcile_reuses_generation_and_exact_grant() {
    let directory = tempfile::Builder::new()
        .prefix("rc-account-")
        .tempdir_in("/tmp")
        .expect("account state with a short socket path");
    let native = directory.path().join("c");
    let mut fake = crate::test_support::FakeLifecycleCodex::new(
        directory.path(),
        crate::test_support::LifecycleMode::CaptureGrant,
    );
    let script = std::fs::read_to_string(&fake.path).expect("native lifecycle script");
    fake.path = identity::write_test_package(
        &directory.path().join("package"),
        REQUIRED_CODEX_VERSION,
        &format!(
            "if [ \"$3\" = start ]; then /bin/cp \"$CODEX_HOME/pid-template.json\" \"$CODEX_HOME/app-server-daemon/app-server.pid\"; fi\n{}",
            script
                .strip_prefix("#!/bin/sh\n")
                .expect("native script body")
        ),
    );
    let codex = &fake.path;
    let grant_capture = &fake.grant_capture;
    let server = fake.server(&native);
    std::fs::create_dir_all(server.socket_path().parent().expect("socket parent"))
        .expect("socket directory");
    std::fs::create_dir_all(native.join("app-server-daemon")).expect("pid directory");
    let identity = *blake3::hash(&std::fs::read(codex).expect("binary")).as_bytes();
    std::fs::write(
        native.join("pid-template.json"),
        serde_json::to_vec(&json!({
            "pid": std::process::id(),
            "processIdentity": crate::test_support::current_process_identity(),
            "executableIdentity": {"digest": identity}
        }))
        .expect("pid JSON"),
    )
    .expect("startup pid template");
    fake.write_reply(&server);
    let listener = tokio::net::UnixListener::bind(server.socket_path()).expect("socket listener");
    let peer = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept");
        let mut websocket = tokio_tungstenite::accept_async(stream)
            .await
            .expect("handshake");
        let _ = websocket.next().await;
    });
    let store = RecoveryStore::new(directory.path().join("state/codex-restart-recovery.json"));
    let mut journal = RecoveryJournal::new(
        "original-generation".to_owned(),
        "0123456789abcdef0123456789abcdef".to_owned(),
        vec![RecoveryTask {
            thread_id: "thread-1".to_owned(),
            turn_id: "turn-1".to_owned(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 0,
            status: RecoveryTaskStatus::Suspended,
            error: None,
        }],
    )
    .expect("account journal");
    let target = sha256_file(codex).expect("target package hash");
    journal.account = Some(crate::runtime::recovery::AccountRecovery {
        account_id: "11111111-1111-1111-1111-111111111111".to_owned(),
        enrollment_generation: 4,
        native_directory: native,
        source_sha256: target.clone(),
        target_sha256: target,
    });
    journal.phase = RecoveryPhase::DaemonStopped;
    journal.error = Some("previous recovery failed closed".to_owned());
    store.write(&journal).expect("persist stopped recovery");

    RecoveryTransaction::new(&server, &store)
        .prepare_incomplete_recovery(&journal)
        .await
        .expect("retry same package");
    let grant: Value =
        serde_json::from_slice(&std::fs::read(grant_capture).expect("grant captured"))
            .expect("grant JSON");
    assert_eq!(grant["generationId"], "original-generation");
    assert_eq!(
        grant["targets"],
        json!([{"threadId": "thread-1", "turnId": "turn-1"}])
    );
    let started = store.load().expect("read journal").expect("journal");
    assert_eq!(started.phase, RecoveryPhase::DaemonStarted);
    assert_eq!(started.generation_id, "original-generation");
    store
        .update("original-generation", |journal| {
            journal.tasks[0].status = RecoveryTaskStatus::Completed;
            journal.phase = RecoveryPhase::Recovered;
            Ok(())
        })
        .expect("gateway recovered exact turn");
    RecoveryTransaction::new(&server, &store)
        .complete_recovery_inner("original-generation")
        .await
        .expect("lift account fence");
    peer.await.expect("socket peer");
    let completed = store.load().expect("read completed").expect("journal");
    assert_eq!(completed.phase, RecoveryPhase::Completed);
    assert_eq!(completed.generation_id, "original-generation");
    assert_eq!(completed.tasks[0].turn_id, "turn-1");
}

#[tokio::test]
async fn interrupted_default_handoffs_finish_stopped_without_starting_recovery() {
    for phase in [
        RecoveryPhase::Captured,
        RecoveryPhase::Suspending,
        RecoveryPhase::Suspended,
    ] {
        let directory = tempfile::tempdir().expect("isolated default handoff");
        let fake = crate::test_support::FakeLifecycleCodex::new(
            directory.path(),
            crate::test_support::LifecycleMode::RecordActions,
        );
        let server = fake.server(&directory.path().join("codex-home"));
        fake.write_reply(&server);
        let store = RecoveryStore::new(directory.path().join("state/recovery.json"));
        let mut journal = RecoveryJournal::new(
            "original-default-generation".to_owned(),
            "0123456789abcdef0123456789abcdef".to_owned(),
            if phase == RecoveryPhase::Captured {
                Vec::new()
            } else {
                vec![RecoveryTask {
                    thread_id: "thread-1".to_owned(),
                    turn_id: "turn-1".to_owned(),
                    parent_thread_id: None,
                    depth: 0,
                    recovery_attempts: 0,
                    status: RecoveryTaskStatus::Suspended,
                    error: None,
                }]
            },
        )
        .expect("captured default work");
        journal.phase = phase;
        store.write(&journal).expect("persist interrupted handoff");
        RecoveryTransaction::new(&server, &store)
            .prepare_stopped_handoff(&journal)
            .await
            .expect("complete stopped handoff");
        let stopped = store
            .load()
            .expect("read stopped journal")
            .expect("journal");
        assert!(stopped.is_prepared_handoff());
        assert_eq!(stopped.generation_id, journal.generation_id);
        assert_eq!(
            serde_json::to_value(&stopped.tasks).unwrap(),
            serde_json::to_value(&journal.tasks).unwrap()
        );
        RecoveryTransaction::new(&server, &store)
            .prepare_stopped_handoff(&stopped)
            .await
            .expect("repeat stopped handoff");
        if fake.actions.exists() {
            let actions = std::fs::read_to_string(&fake.actions).expect("lifecycle actions");
            assert!(
                !actions.lines().any(|action| action == "start"),
                "{actions}"
            );
        }
    }
}

#[tokio::test]
async fn dead_source_capture_restarts_fenced_and_keeps_exact_task_on_rpc_failure() {
    let directory = tempfile::Builder::new()
        .prefix("rc-dead-capture-")
        .tempdir_in("/tmp")
        .expect("short socket path");
    let native = directory.path().join("c");
    let fake = crate::test_support::FakeLifecycleCodex::new(
        directory.path(),
        crate::test_support::LifecycleMode::RecordFencedActions,
    );
    let server = fake.server(&native);
    fake.write_reply(&server);
    let store = RecoveryStore::new(directory.path().join("state/recovery.json"));
    let mut journal = RecoveryJournal::new(
        "dead-generation".to_owned(),
        "0123456789abcdef0123456789abcdef".to_owned(),
        vec![RecoveryTask {
            thread_id: "root".to_owned(),
            turn_id: "turn-1".to_owned(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 0,
            status: RecoveryTaskStatus::Captured,
            error: None,
        }],
    )
    .expect("exact capture");
    journal.phase = RecoveryPhase::Suspending;
    store.write(&journal).expect("durable mutation intent");

    assert!(
        RecoveryTransaction::new(&server, &store)
            .prepare_incomplete_recovery(&journal)
            .await
            .is_err()
    );
    let persisted = store.load().expect("read journal").expect("journal");
    assert_eq!(persisted.phase, RecoveryPhase::Suspending);
    assert_eq!(persisted.tasks[0].turn_id, "turn-1");
    assert_eq!(persisted.tasks[0].status, RecoveryTaskStatus::Captured);
    let actions = std::fs::read_to_string(&fake.actions).expect("lifecycle actions");
    assert!(actions.contains("\nstart:1\n"), "{actions}");
    assert!(!actions.contains("cancel-restart"), "{actions}");
}

#[tokio::test]
async fn retrying_recovering_default_keeps_native_admission_fenced() {
    let directory = tempfile::Builder::new()
        .prefix("rc-default-fence-")
        .tempdir_in("/tmp")
        .expect("short socket path");
    let native = directory.path().join("c");
    let fake = crate::test_support::FakeLifecycleCodex::new(
        directory.path(),
        crate::test_support::LifecycleMode::RecordActions,
    );
    let server = fake.server(&native);
    std::fs::create_dir_all(server.socket_path().parent().expect("socket parent"))
        .expect("socket directory");
    std::fs::create_dir_all(native.join("app-server-daemon")).expect("pid directory");
    std::fs::write(
        native.join("app-server-daemon/app-server.pid"),
        serde_json::to_vec(&json!({
            "pid": std::process::id(),
            "processIdentity": crate::test_support::current_process_identity(),
        }))
        .expect("pid JSON"),
    )
    .expect("pid record");
    fake.write_reply(&server);
    let listener = tokio::net::UnixListener::bind(server.socket_path()).expect("socket listener");
    let peer = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("connection");
        let mut websocket = tokio_tungstenite::accept_async(stream)
            .await
            .expect("handshake");
        let _ = websocket.next().await;
    });
    let store = RecoveryStore::new(directory.path().join("state/recovery.json"));
    let mut journal = RecoveryJournal::new(
        "default-generation".to_owned(),
        "0123456789abcdef0123456789abcdef".to_owned(),
        vec![RecoveryTask {
            thread_id: "root".to_owned(),
            turn_id: "turn-1".to_owned(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 0,
            status: RecoveryTaskStatus::Running,
            error: None,
        }],
    )
    .expect("journal");
    journal.phase = RecoveryPhase::Recovering;
    store.write(&journal).expect("persist recovering default");
    RecoveryTransaction::new(&server, &store)
        .prepare_incomplete_recovery(&journal)
        .await
        .expect("keep existing fenced daemon");
    peer.await.expect("socket peer");
    assert_eq!(store.load().expect("journal"), Some(journal));
    let actions = std::fs::read_to_string(&fake.actions).expect("lifecycle actions");
    assert_eq!(actions.lines().collect::<Vec<_>>(), ["version"]);
}

#[tokio::test]
async fn live_unready_recovery_is_not_relabelled_as_dead() {
    let directory = tempfile::Builder::new()
        .prefix("rc-live-unready-")
        .tempdir_in("/tmp")
        .expect("short socket path");
    let native = directory.path().join("c");
    let fake = crate::test_support::FakeLifecycleCodex::new(
        directory.path(),
        crate::test_support::LifecycleMode::RecordActions,
    );
    let server = fake.server(&native);
    let pid_file = native.join("app-server-daemon/app-server.pid");
    std::fs::create_dir_all(pid_file.parent().expect("pid parent")).expect("pid directory");
    std::fs::write(
        &pid_file,
        serde_json::to_vec(&json!({
            "pid": std::process::id(),
            "processIdentity": crate::test_support::current_process_identity(),
        }))
        .expect("pid JSON"),
    )
    .expect("live recorded PID");
    fake.write_reply(&server);
    let store = RecoveryStore::new(directory.path().join("state/recovery.json"));
    let mut journal = RecoveryJournal::new(
        "exact-generation".to_owned(),
        "0123456789abcdef0123456789abcdef".to_owned(),
        vec![RecoveryTask {
            thread_id: "thread-1".to_owned(),
            turn_id: "turn-1".to_owned(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 1,
            status: RecoveryTaskStatus::Running,
            error: None,
        }],
    )
    .expect("exact recovery journal");
    for phase in [
        RecoveryPhase::DaemonStarted,
        RecoveryPhase::Recovering,
        RecoveryPhase::Recovered,
    ] {
        journal.phase = phase;
        store.write(&journal).expect("persist live recovery");
        let failure = RecoveryTransaction::new(&server, &store)
            .prepare_incomplete_recovery(&journal)
            .await
            .expect_err("slow socket cannot prove daemon death");
        assert!(
            failure.to_string().contains("live but not ready"),
            "{failure:#}"
        );
        assert_eq!(store.load().expect("journal"), Some(journal.clone()));
    }
    let live_actions = std::fs::read_to_string(&fake.actions).expect("lifecycle actions");
    assert_eq!(live_actions.lines().collect::<Vec<_>>(), ["version"; 3]);

    std::fs::remove_file(&pid_file).expect("confirm recorded daemon death");
    RecoveryTransaction::new(&server, &store)
        .prepare_incomplete_recovery(&journal)
        .await
        .expect("dead daemon can reuse exact recovery grant");
    let restarted = store
        .load()
        .expect("journal")
        .expect("restarted generation");
    assert_eq!(restarted.generation_id, "exact-generation");
    assert_eq!(restarted.tasks[0].turn_id, "turn-1");
    assert_eq!(restarted.tasks[0].status, RecoveryTaskStatus::Suspended);
    assert_eq!(restarted.phase, RecoveryPhase::DaemonStarted);
    let actions = std::fs::read_to_string(&fake.actions).expect("lifecycle actions");
    assert_eq!(
        actions.lines().collect::<Vec<_>>(),
        ["version", "version", "version", "version", "start"]
    );
}

#[tokio::test]
async fn account_failure_does_not_stop_a_partly_running_default_turn() {
    use std::os::unix::fs::PermissionsExt;

    let directory = tempfile::tempdir().expect("runtime state");
    let codex = directory.path().join("codex");
    let stopped = directory.path().join("stop-called");
    std::fs::write(&codex, "#!/bin/sh\ntouch \"$STOP_MARKER\"\nexit 0\n")
        .expect("fake Codex executable");
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).expect("executable");
    let server = CodexAppServer::new(
        codex,
        HashMap::from([
            (
                "CODEX_HOME".to_owned(),
                directory.path().join("c").display().to_string(),
            ),
            ("STOP_MARKER".to_owned(), stopped.display().to_string()),
        ]),
    );
    let store = RecoveryStore::new(directory.path().join("recovery.json"));
    let mut journal = RecoveryJournal::new(
        "default-generation".to_owned(),
        "0123456789abcdef0123456789abcdef".to_owned(),
        vec![RecoveryTask {
            thread_id: "root".to_owned(),
            turn_id: "turn-1".to_owned(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 1,
            status: RecoveryTaskStatus::Running,
            error: None,
        }],
    )
    .expect("journal");
    journal.phase = RecoveryPhase::Recovering;
    for status in [RecoveryTaskStatus::Running, RecoveryTaskStatus::Suspended] {
        journal.tasks[0].status = status;
        store.write(&journal).expect("persist in-flight default");
        let failure = RecoveryTransaction::new(&server, &store)
            .fail_recovery_closed(
                "default-generation",
                anyhow::anyhow!("enrolled account recovery child exited"),
            )
            .await
            .expect_err("preserve possibly resumed native work");
        assert!(
            failure
                .to_string()
                .contains("default daemon remains fenced")
        );
        assert_eq!(store.load().expect("journal"), Some(journal.clone()));
    }
    assert!(
        !stopped.exists(),
        "no plain daemon stop without exact suspension"
    );
}

#[tokio::test]
async fn recovered_turn_remains_live_across_finalization_uncertainty() {
    use std::os::unix::fs::PermissionsExt;

    let directory = tempfile::tempdir().expect("runtime state");
    let codex = directory.path().join("codex");
    let actions = directory.path().join("actions");
    std::fs::write(
        &codex,
        "#!/bin/sh\nprintf '%s\\n' \"$3\" >> \"$ACTIONS\"\nif [ \"$3\" = cancel-restart ]; then exit 1; fi\nprintf '%s\\n' '{\"socketPath\":\"/tmp/fake-app-server.sock\"}'\n",
    )
    .expect("fake Codex executable");
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).expect("executable");
    let server = CodexAppServer::new(
        codex.clone(),
        HashMap::from([("ACTIONS".to_owned(), actions.display().to_string())]),
    );
    let store = RecoveryStore::new(directory.path().join("state/recovery.json"));
    let mut journal = RecoveryJournal::new(
        "default-generation".to_owned(),
        "0123456789abcdef0123456789abcdef".to_owned(),
        vec![RecoveryTask {
            thread_id: "thread-1".to_owned(),
            turn_id: "turn-1".to_owned(),
            parent_thread_id: None,
            depth: 0,
            recovery_attempts: 1,
            status: RecoveryTaskStatus::Running,
            error: None,
        }],
    )
    .expect("journal");
    journal.phase = RecoveryPhase::Recovered;
    store.write(&journal).expect("persist recovered generation");

    let failure = RecoveryTransaction::new(&server, &store)
        .complete_recovery("default-generation")
        .await
        .expect_err("lost completion reply must retain native turn");
    assert!(
        failure.to_string().contains("daemon remains fenced"),
        "{failure:#}"
    );
    assert_eq!(store.load().expect("journal"), Some(journal.clone()));
    assert_eq!(
        std::fs::read_to_string(&actions).expect("lifecycle actions"),
        "cancel-restart\nprepare-restart\n"
    );

    std::fs::write(
        &codex,
        "#!/bin/sh\nprintf '%s\\n' \"$3\" >> \"$ACTIONS\"\nprintf '%s\\n' '{\"socketPath\":\"/tmp/fake-app-server.sock\"}'\n",
    )
    .expect("successful cancellation fixture");
    std::fs::write(&actions, "").expect("clear lifecycle log");
    store
        .write(&journal)
        .expect("retry finalization from recovered phase");
    store.fail_next_write();
    let failure = RecoveryTransaction::new(&server, &store)
        .complete_recovery("default-generation")
        .await
        .expect_err("failed completion write must retain native turn");
    assert!(
        failure.to_string().contains("daemon remains fenced"),
        "{failure:#}"
    );
    assert_eq!(store.load().expect("journal"), Some(journal.clone()));
    assert_eq!(
        std::fs::read_to_string(&actions).expect("lifecycle actions"),
        "cancel-restart\nprepare-restart\n"
    );

    std::fs::write(&actions, "").expect("clear lifecycle log");
    store.fail_after_next_rename();
    let failure = RecoveryTransaction::new(&server, &store)
        .complete_recovery("default-generation")
        .await
        .expect_err("post-rename sync failure must retain native turn");
    assert!(
        failure.to_string().contains("daemon remains fenced"),
        "{failure:#}"
    );
    let persisted = store
        .load()
        .expect("journal")
        .expect("recovered generation");
    assert_eq!(persisted.phase, RecoveryPhase::Recovered);
    assert_eq!(persisted.tasks, journal.tasks);
    assert!(
        persisted
            .error
            .as_deref()
            .is_some_and(|error| error.contains("directory-sync failure after rename"))
    );
    assert_eq!(
        std::fs::read_to_string(&actions).expect("lifecycle actions"),
        "cancel-restart\nprepare-restart\n",
        "published Completed must be re-fenced and restored to retryable Recovered"
    );

    std::fs::write(&actions, "").expect("clear lifecycle log");
    RecoveryTransaction::new(&server, &store)
        .complete_native_finalization("default-generation")
        .await
        .expect("retry the same exact generation after re-fencing");
    let retried = store
        .load()
        .expect("journal")
        .expect("completed generation");
    assert_eq!(retried.generation_id, persisted.generation_id);
    assert_eq!(retried.capability, persisted.capability);
    assert_eq!(retried.tasks, persisted.tasks);
    assert_eq!(retried.phase, RecoveryPhase::Completed);
    assert_eq!(
        std::fs::read_to_string(&actions).expect("lifecycle actions"),
        "cancel-restart\n"
    );
}

#[test]
fn installed_package_check_accepts_only_a_completed_matching_swap() {
    let directory = tempfile::tempdir().expect("runtime state");
    let root = directory.path();
    let package = root.join("package");
    let current = root.join("current");
    for location in [&package, &current] {
        std::fs::create_dir_all(location.join("bin")).expect("package bins");
        std::fs::write(location.join("codex-package.json"), "approved manifest").expect("manifest");
        std::fs::write(location.join("bin/codex"), "approved codex").expect("codex");
        std::fs::write(location.join("bin/codex-code-mode-host"), "approved host").expect("host");
    }
    let paths = RuntimePaths {
        release: root.join("release"),
        staging: root.join("staging"),
        previous_release: root.join("previous-release"),
        current,
        previous_current: root.join("previous-current"),
        gateway_env: root.join("gateway.env"),
        previous_gateway_env: root.join("previous-gateway.env"),
    };
    let store = RecoveryStore::new(root.join("state/recovery.json"));
    let mut journal = RecoveryJournal::new(
        "generation-1".to_owned(),
        "0123456789abcdef0123456789abcdef".to_owned(),
        Vec::new(),
    )
    .expect("journal");
    journal.phase = RecoveryPhase::Completed;
    journal.runtime_swap = Some(RuntimeSwap {
        source_identity: None,
        target_identity: None,
        had_release: true,
        had_current: true,
        previous_current_target: Some(paths.release.clone()),
        had_gateway_env: true,
    });
    store.write(&journal).expect("pending commit journal");
    std::fs::write(&paths.previous_release, "prior package").expect("rollback artifact");

    check_install_state(&paths, &store, &package, true)
        .expect("matching completed swap may reach gateway health gate");
    let replacement = check_install_state(&paths, &store, &package, false)
        .expect_err("replacement must not consume pending swap");
    assert!(
        replacement
            .to_string()
            .contains("health-gated gateway commit")
    );
    std::fs::write(package.join("bin/codex"), "different codex").expect("different bytes");
    let mismatch = check_install_state(&paths, &store, &package, true)
        .expect_err("mismatched package cannot commit prior swap");
    assert!(mismatch.to_string().contains("differs from candidate"));
    assert_eq!(store.load().expect("journal"), Some(journal.clone()));

    std::fs::write(package.join("bin/codex"), "approved codex").expect("restore bytes");
    journal.phase = RecoveryPhase::Recovering;
    store.write(&journal).expect("unfinished generation");
    let unfinished = check_install_state(&paths, &store, &package, true)
        .expect_err("unfinished exact recovery cannot reach gateway commit");
    assert!(
        unfinished
            .to_string()
            .contains("unfinished runtime recovery")
    );
}

#[tokio::test]
async fn candidate_check_rejects_unapproved_same_version_package_before_handoff() {
    let directory = tempfile::tempdir().expect("candidate fixture");
    let package = directory.path().join("package");
    std::fs::create_dir_all(&package).expect("package directory");
    std::fs::write(
        package.join("codex-package.json"),
        serde_json::to_vec(&json!({
            "layoutVersion": 1,
            "version": REQUIRED_CODEX_VERSION,
            "sourceCommit": "unapproved-source",
            "target": "aarch64-apple-darwin",
            "variant": "codex",
            "entrypoint": "bin/codex",
            "resourcesDir": "codex-resources",
            "pathDir": "codex-path",
            "binaries": {},
        }))
        .expect("manifest JSON"),
    )
    .expect("manifest");
    let source = directory.path().join("source-codex");
    let server = CodexAppServer::new(source.clone(), HashMap::new());
    let store = RecoveryStore::new(directory.path().join("state/recovery.json"));
    let failure = check_install_candidate(&server, &store, &package, &source, None, false)
        .await
        .expect_err("unapproved candidate must fail before env checks");
    assert!(failure.to_string().contains("not approved"), "{failure:#}");
    assert!(store.load().expect("recovery journal").is_none());
}

#[test]
fn a_planned_handoff_ticket_is_private_and_names_its_generation() {
    use std::os::unix::fs::PermissionsExt;

    let root = tempfile::tempdir().expect("temp dir");
    let ticket = root.path().join("gateway-launch-state/planned-handoff");

    write_planned_handoff_ticket(&ticket, "generation-1").expect("ticket written");
    write_planned_handoff_ticket(&ticket, "generation-2").expect("ticket replaced");

    assert_eq!(
        std::fs::read_to_string(&ticket).expect("read"),
        "generation-2"
    );
    let mode = |path: &Path| {
        std::fs::metadata(path)
            .expect("metadata")
            .permissions()
            .mode()
            & 0o777
    };
    assert_eq!(mode(&ticket), 0o600);
    assert_eq!(mode(ticket.parent().expect("parent")), 0o700);
}

#[test]
fn an_artifact_restores_its_previous_bytes_or_removes_what_it_installed() {
    let directory = tempfile::tempdir().expect("temp dir");
    let write = |name: &str, contents: &str| {
        std::fs::write(directory.path().join(name), contents).expect("write");
    };
    let read = |name: &str| std::fs::read_to_string(directory.path().join(name));

    write("gateway", "previous");
    let mut existing = Artifact::at(directory.path(), "gateway", 7);
    existing.back_up().expect("back up");
    write("gateway.new.7", "candidate");
    existing.activate().expect("activate");
    assert_eq!(read("gateway").expect("installed"), "candidate");
    existing.restore().expect("restore");
    assert_eq!(read("gateway").expect("restored"), "previous");
    assert!(!directory.path().join("gateway.new.7").exists());

    let mut fresh = Artifact::at(directory.path(), "launcher", 7);
    write("launcher.previous", "stale backup from an aborted run");
    fresh.back_up().expect("back up nothing");
    assert!(!directory.path().join("launcher.previous").exists());
    write("launcher.new.7", "candidate");
    fresh.activate().expect("activate");
    fresh.restore().expect("remove");
    assert!(!directory.path().join("launcher").exists());
}

#[test]
fn install_gateway_refuses_to_run_from_any_other_binary() {
    let directory = tempfile::tempdir().expect("temp dir");
    let other = directory.path().join("gateway.new.9");
    std::fs::write(&other, "not this test binary").expect("write");

    let error = require_running_from(&other).expect_err("a different binary is refused");
    assert!(format!("{error:#}").contains("staged binary"));
    assert!(require_running_from(&directory.path().join("missing")).is_err());
}

#[test]
fn an_uninstall_is_refused_while_chatgpt_or_a_codex_proxy_client_runs() {
    let process = |command: &str| (1, command.to_string());

    assert_eq!(uninstall_refusal(&[process("/usr/bin/ssh host")]), None);
    assert_eq!(
        uninstall_refusal(&[process(CHATGPT_EXECUTABLE)]),
        Some("ChatGPT is running; inventory its active tasks and quit it before uninstalling")
    );
    assert_eq!(
        uninstall_refusal(&[process(
            "/tmp/codex app-server proxy --sock /tmp/control.sock"
        )]),
        Some("a Codex daemon client is still connected; stop it before uninstalling")
    );
    assert_eq!(
        uninstall_refusal(&[process("/tmp/codex app-server daemon version")]),
        None
    );
    assert_eq!(
        uninstall_refusal(&[process(
            "/tmp/not-codex app-server proxy --sock /tmp/control.sock"
        )]),
        None
    );
}
