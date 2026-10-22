import argparse
import importlib.util
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from unittest.mock import Mock, patch

import pytest

from remotecoder_tools import mac_bench


@pytest.fixture(autouse=True)
def benchmark_operator_settings(monkeypatch):
    monkeypatch.setattr(mac_bench, "maintainer_settings", lambda: {
        "macGUIHost": "gui-host", "macBenchmarkGatewayId": "11111111-2222-4333-8444-555555555555",
    })


ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def build_cache(tmp_path, monkeypatch):
    monkeypatch.syspath_prepend(str(ROOT / "scripts"))
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    policy = tmp_path / "configs/build/compilation-cache-policy.json"
    policy.parent.mkdir(parents=True)
    policy.write_text(
        json.dumps(
            {
                "maxRuns": 512,
                "runRetentionDays": 3,
                "evidenceProtectionHours": 48,
                "compilerProtectionHours": 2,
                "retiredWorktreeIdleHours": 24,
                "compilationBudgetGiB": 80,
                "retainedCompletedDirectories": 2,
                "evictionTargetFreeGiB": 100,
                "evictionEnabled": False,
            }
        )
    )
    return mac_bench.bench_runs().parent


def test_later_remote_build_preserves_failed_bench_evidence(build_cache, monkeypatch):
    with pytest.raises(RuntimeError, match="failed interaction"):
        with mac_bench.bench_output({"label": "failed-zoom"}) as output:
            (output / "plan.json").write_text("plan evidence")
            (output / "stdout.jsonl").write_text("failed check evidence")
            raise RuntimeError("failed interaction")
    bench_receipt = json.loads((output / "receipt.json").read_text())
    assert bench_receipt["exitCode"] == 1
    assert bench_receipt["outputDirectory"] == str(output)
    assert output.parent == build_cache / "runs"

    spec = importlib.util.spec_from_file_location(
        "remote_build", ROOT / "scripts/remote-build.py"
    )
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    run = build_cache / "runs/later-build"
    source = run / "repo"
    source.mkdir(parents=True)
    (source / ".xcode-version").write_text("27.0")
    manifest = {
        "kind": "mac-build",
        "arguments": [],
        "environment": {},
        "worktreeId": "fixture",
        "buildId": "later-build",
        "sourceCommit": "fixture",
        "sourceModified": False,
        "files": [".xcode-version"],
        "sourceFingerprint": runner.fingerprint(source, [".xcode-version"]),
    }
    (run / "source.json").write_text(json.dumps(manifest))
    mirror = build_cache / "worktrees/fixture/ios/repo"
    mirror.mkdir(parents=True)
    obsolete = mirror / "build/mac-bench/runs/old/stdout.jsonl"
    obsolete.parent.mkdir(parents=True)
    obsolete.write_text("obsolete mirror payload")
    monkeypatch.setattr(runner, "run_owned", lambda *args: 0)
    receipt = runner.worker(run)
    assert receipt["exitCode"] == 0
    assert not obsolete.exists()
    assert (output / "plan.json").read_text() == "plan evidence"
    assert (output / "stdout.jsonl").read_text() == "failed check evidence"
    assert json.loads((output / "receipt.json").read_text()) == bench_receipt


def test_repeated_labels_keep_separate_receipts_and_failed_exit_status(build_cache):
    previous = {
        signum: signal.getsignal(signum)
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    }
    with mac_bench.bench_output({"label": "same"}) as first:
        (first / "stdout.jsonl").write_text("first")
    with pytest.raises(SystemExit) as failure:
        with mac_bench.bench_output({"label": "same"}) as second:
            raise SystemExit(65)
    assert failure.value.code == 65
    assert first != second
    assert (first / "stdout.jsonl").read_text() == "first"
    assert json.loads((first / "receipt.json").read_text())["exitCode"] == 0
    assert json.loads((second / "receipt.json").read_text())["exitCode"] == 65
    assert {signum: signal.getsignal(signum) for signum in previous} == previous


def test_old_terminal_bench_runs_use_the_shared_retention_and_active_lease(build_cache):
    from build_cache import lease_path, load_policy, prune_caches, try_lease

    with mac_bench.bench_output({"label": "old"}) as old:
        (old / "stdout.jsonl").write_text("old")
    aged = time.time() - 4 * 86400
    os.utime(old, (aged, aged))
    os.utime(
        lease_path(build_cache, "runs", old.name).with_suffix(".used"), (aged, aged)
    )
    with mac_bench.bench_output({"label": "active"}) as active:
        assert not old.exists()
        with try_lease(lease_path(build_cache, "runs", active.name)) as lease:
            assert lease is None
        os.utime(active, (aged, aged))
        os.utime(
            lease_path(build_cache, "runs", active.name).with_suffix(".used"),
            (aged, aged),
        )
        result = prune_caches(build_cache, load_policy(), "", "other")
        assert active.exists()
        assert active.name not in result["runs"]


def test_repeated_profile_labels_require_the_exact_output_path(build_cache):
    with mac_bench.bench_output({"label": "same"}):
        pass
    with mac_bench.bench_output({"label": "same"}):
        pass
    with pytest.raises(SystemExit, match="missing or repeated"):
        mac_bench.profile(argparse.Namespace(label="same", focus=None, depth=5))


@pytest.mark.parametrize(
    "failure",
    [None, "interaction", "copy", "sample-term", "sample-kill", "sample-exit"],
)
def test_captures_are_copied_before_scope_teardown_and_failures_still_quit(
    build_cache, tmp_path, monkeypatch, failure
):
    source = tmp_path / "app-temporary-scope/Caches/perf/bench/fixture"
    mode = mac_bench.expected_display("1797x1162@120/2")
    args = argparse.Namespace(
        expected_display=mode,
        disable=None,
        mount_cap=None,
        scrollbars=None,
        timeout=180,
        sample=10 if failure in {"sample-term", "sample-kill", "sample-exit"} else None,
        sample_interval=5,
    )
    bench = {"label": "fixture", "quit": False}
    quits = []

    def quit_app():
        quits.append(source.exists())
        if source.exists():
            if failure != "copy":
                assert (output / "capture.png").read_bytes() == b"capture"
                assert (output / "switch/milestones.json").read_text() == "milestones"
            shutil.rmtree(source.parent.parent.parent.parent)

    def launch(command, **kwargs):
        sent = json.loads(command[command.index("-rcPerfBench") + 1])
        assert sent["quit"] is False
        source.mkdir(parents=True)
        (source / "capture.png").write_bytes(b"capture")
        (source / "switch").mkdir()
        (source / "switch/milestones.json").write_text("milestones")
        (output / "stdout.jsonl").write_text(
            json.dumps({"bench": "measuring", "pid": 42})
            + "\n"
            + json.dumps(
                {
                    "bench": "done",
                    "dir": str(source),
                    "error": "failed interaction" if failure == "interaction" else None,
                }
            )
            + "\n"
        )

    monkeypatch.setattr(mac_bench, "quit_app", quit_app)
    monkeypatch.setattr(mac_bench, "running_pids", lambda: [])
    monkeypatch.setattr(mac_bench, "run_command", launch)
    monkeypatch.setattr(
        mac_bench.subprocess,
        "check_output",
        lambda *args, **kwargs: '"HIDIdleTime" = 120000000000',
    )
    monkeypatch.setattr(mac_bench.time, "sleep", lambda _: None)
    monkeypatch.setattr(mac_bench, "measured_display_mode", lambda: mode)
    monkeypatch.setattr(
        mac_bench,
        "analyze_run",
        lambda directory: {
            "display": mode,
            "refreshHz": 120,
            "measurementHost": "fixture-macbook",
            "outputDirectory": str(directory),
        },
    )
    if failure == "copy":

        def fail_copy(*args):
            raise OSError("copy failed")

        monkeypatch.setattr(mac_bench.shutil, "copy2", fail_copy)
    if failure in {"sample-term", "sample-kill", "sample-exit"}:
        sampler = Mock()
        sampler.poll.return_value = 1 if failure == "sample-exit" else None
        waits = (
            [1]
            if failure == "sample-exit"
            else [subprocess.TimeoutExpired("sample", 60)]
        )
        if failure == "sample-kill":
            waits.append(subprocess.TimeoutExpired("sample", 5))
        if failure != "sample-exit":
            waits.append(-9 if failure == "sample-kill" else -15)
        sampler.wait.side_effect = waits
        monkeypatch.setattr(
            mac_bench.subprocess, "Popen", lambda *args, **kwargs: sampler
        )
    if failure:
        expected = (
            SystemExit
            if failure in {"interaction", "sample-exit"}
            else subprocess.TimeoutExpired
            if failure in {"sample-term", "sample-kill"}
            else OSError
        )
        with pytest.raises(expected):
            with mac_bench.bench_output(bench) as output:
                mac_bench.measure_run(args, bench, output)
    else:
        with mac_bench.bench_output(bench) as output:
            summary = mac_bench.measure_run(args, bench, output)
        assert summary["outputDirectory"] == str(output)
    assert quits == [True]
    assert not source.exists()
    if failure in {"sample-term", "sample-kill"}:
        sampler.terminate.assert_called_once()
        assert sampler.kill.called == (failure == "sample-kill")
        assert sampler.wait.call_count == len(waits)
    if failure == "sample-exit":
        sampler.terminate.assert_not_called()
        sampler.kill.assert_not_called()
    assert (output / "stdout.jsonl").exists()
    assert json.loads((output / "receipt.json").read_text())["exitCode"] == (
        1 if failure else 0
    )


@pytest.mark.parametrize("duration", ["0", "-1", "60.01", "nan", "inf"])
def test_sample_cli_rejects_unbounded_durations(duration, monkeypatch):
    monkeypatch.setattr(
        "sys.argv", ["mac-bench", "run", "--thread", "fixture", "--sample", duration]
    )
    with pytest.raises(SystemExit) as error:
        mac_bench.main()
    assert error.value.code == 2


def test_measurement_launch_does_not_inherit_caller_secrets(tmp_path, monkeypatch, capsys):
    mode = mac_bench.expected_display("1797x1162@120/2")
    args = argparse.Namespace(
        expected_display=mode, disable=None, mount_cap=None, scrollbars=None,
        timeout=180, sample=None,
    )
    spawn = subprocess.run
    probe = """import json,os,sys
from pathlib import Path
directory = Path(sys.argv[1])
observed = {
    'secretPresent': any(name in os.environ for name in ('SENTINEL_SECRET', 'RC_SENTINEL_SECRET', 'RC_CODEX_GATEWAY_AUTH_TOKEN', 'DYLD_INSERT_LIBRARIES')),
    'systemHome': os.environ.get('HOME') == '/fixture-home',
    'systemPath': os.environ.get('PATH') == '/usr/bin:/bin:/usr/sbin:/sbin',
    'systemTemp': os.environ.get('TMPDIR') == str(directory),
}
(directory / 'observed.json').write_text(json.dumps(observed))
(directory / 'stdout.jsonl').write_text(json.dumps({'bench': 'done'}) + '\\n')
"""

    def launch(command, **kwargs):
        assert "-rcPerfBench" in command
        return spawn([sys.executable, "-c", probe, str(tmp_path)], **kwargs)

    monkeypatch.setattr(mac_bench.subprocess, "run", launch)
    monkeypatch.setattr(mac_bench, "require_hid_idle", lambda: None)
    monkeypatch.setattr(mac_bench, "running_pids", lambda: [])
    monkeypatch.setattr(mac_bench, "quit_app", lambda: None)
    monkeypatch.setattr(mac_bench.time, "sleep", lambda _: None)
    monkeypatch.setattr(mac_bench, "measured_display_mode", lambda: mode)
    monkeypatch.setattr(mac_bench, "analyze_run", lambda _: {
        "display": mode, "refreshHz": 120, "measurementHost": "fixture-macbook",
    })
    sentinel = "fixture-secret-must-not-reach-measurement"
    with patch.dict(os.environ, {
        "HOME": "/fixture-home", "TMPDIR": str(tmp_path), "PATH": "/fixture-bin",
        "SENTINEL_SECRET": sentinel, "RC_SENTINEL_SECRET": sentinel,
        "RC_CODEX_GATEWAY_AUTH_TOKEN": sentinel, "DYLD_INSERT_LIBRARIES": "",
    }, clear=True):
        summary = mac_bench.measure_run(args, {"label": "fixture", "quit": False}, tmp_path)
    observed = json.loads((tmp_path / "observed.json").read_text())
    assert observed["secretPresent"] is False
    assert observed["systemHome"] is True
    assert observed["systemPath"] is True
    assert observed["systemTemp"] is True
    captured = capsys.readouterr()
    assert sentinel not in captured.out + captured.err + json.dumps(summary)
    assert sentinel not in (tmp_path / "summary.json").read_text()


def test_sample_cli_accepts_the_duration_limit(monkeypatch):
    captured = []
    monkeypatch.setattr(mac_bench, "run", captured.append)
    monkeypatch.setattr(
        "sys.argv", ["mac-bench", "run", "--thread", "fixture", "--sample", "60"]
    )
    mac_bench.main()
    assert captured[0].sample == 60


def test_cli_queues_the_measurement_without_losing_options_or_stdout(
    build_cache, monkeypatch, capsys
):
    import build_support

    app = build_cache / "fixture.app"
    app.mkdir(parents=True)
    monkeypatch.setattr(mac_bench, "TARGET", app)
    monkeypatch.setattr(mac_bench, "require_gui_host", lambda args: None)
    captured = []

    def connected(command):
        captured.append(command)
        return subprocess.CompletedProcess(
            command, 0, '{"outputDirectory":"owned-run"}\n'
        )

    monkeypatch.setattr(build_support, "run_connected", connected)
    options = [
        "--thread",
        "fixture",
        "--pattern",
        "idle",
        "--stream",
        "12",
        "--sample",
        "60",
        "--runs",
        "2",
    ]
    monkeypatch.setattr("sys.argv", ["mac-bench", "run", *options])
    mac_bench.main()
    command = captured[0]
    assert command[1:5] == [
        str(mac_bench.ROOT / "scripts/measurement.py"),
        "--source",
        str(mac_bench.ROOT),
        "--hold-seconds",
    ]
    assert float(command[5]) == 580
    assert command[9:] == ["_measure", *options]
    assert capsys.readouterr().out == '{"outputDirectory":"owned-run"}\n'


@pytest.mark.parametrize(
    "runs, timeout, sample",
    [
        (0, 180, None),
        (1, float("nan"), None),
        (1, float("inf"), None),
        (8, 180, None),
        (7, 180, 60),
    ],
)
def test_reservation_rejects_unbounded_measurements(runs, timeout, sample):
    with pytest.raises(SystemExit):
        mac_bench.measurement_hold_seconds(
            argparse.Namespace(runs=runs, timeout=timeout, sample=sample)
        )


def test_internal_measurement_requires_an_active_reservation(monkeypatch):
    monkeypatch.setattr(mac_bench, "require_gui_host", lambda args: None)
    monkeypatch.delenv("RC_MEASUREMENT_RECEIPT", raising=False)
    with pytest.raises(SystemExit, match="acquire the measurement reservation"):
        mac_bench.run_admitted(argparse.Namespace())


@pytest.mark.parametrize("idle_reads", [["0"], ["120000000000", "0"]])
def test_busy_hid_preflight_does_not_quit_or_launch_an_app(
    build_cache, monkeypatch, idle_reads
):
    quit_app, launch = Mock(), Mock()
    monkeypatch.setattr(mac_bench, "quit_app", quit_app)
    monkeypatch.setattr(mac_bench, "run_command", launch)
    monkeypatch.setattr(mac_bench, "running_pids", lambda: [])
    idle = iter(idle_reads)
    monkeypatch.setattr(
        mac_bench.subprocess,
        "check_output",
        lambda *args, **kwargs: f'"HIDIdleTime" = {next(idle)}',
    )
    args = argparse.Namespace(expected_display={}, disable=None, mount_cap=None, scrollbars=None)
    with pytest.raises(SystemExit, match="HID idle"):
        with mac_bench.bench_output({"label": "busy"}) as output:
            mac_bench.measure_run(args, {"label": "busy", "quit": False}, output)
    quit_app.assert_not_called()
    launch.assert_not_called()
    assert json.loads((output / "receipt.json").read_text())["exitCode"] == 1


def test_running_installed_app_is_preserved_when_a_measurement_is_refused(
    build_cache, monkeypatch
):
    quit_app, launch = Mock(), Mock()
    monkeypatch.setattr(mac_bench, "quit_app", quit_app)
    monkeypatch.setattr(mac_bench, "run_command", launch)
    monkeypatch.setattr(mac_bench, "running_pids", lambda: [42])
    monkeypatch.setattr(mac_bench, "require_hid_idle", lambda: None)
    args = argparse.Namespace(expected_display={}, disable=None, mount_cap=None, scrollbars=None)
    with pytest.raises(SystemExit, match="already running"):
        with mac_bench.bench_output({"label": "running"}) as output:
            mac_bench.measure_run(args, {"label": "running", "quit": False}, output)
    quit_app.assert_not_called()
    launch.assert_not_called()
    assert json.loads((output / "receipt.json").read_text())["exitCode"] == 1


@pytest.mark.parametrize("signum", [signal.SIGTERM, signal.SIGHUP, signal.SIGINT])
@pytest.mark.parametrize("cancel_stage", ["active", "acquisition"])
def test_cancellation_signals_clean_up_owned_processes_and_publish_failure(
    build_cache, tmp_path, signum, cancel_stage
):
    bootstrap = """import argparse,json,os,subprocess,sys
from pathlib import Path
from remotecoder_tools import mac_bench as b
root = Path(sys.argv[1])
Path.home = lambda: root
spawn = subprocess.Popen
app = None
sampler = None
announced = False
sleep = b.time.sleep
def quit_app():
    if app is not None and app.poll() is None:
        app.terminate()
        app.wait(timeout=10)
def launch(_command, **kwargs):
    global app
    app = spawn([sys.executable, '-c', 'import signal; signal.pause()', str(root)], **kwargs)
    (output / 'stdout.jsonl').write_text(json.dumps({'bench': 'measuring', 'pid': app.pid}) + '\\n')
def sample(*_args, **_kwargs):
    global sampler
    sampler = spawn([sys.executable, '-c', 'import signal; signal.pause()', str(root)])
    pending = root / 'started.tmp'
    pending.write_text(json.dumps({'output': str(output), 'pids': [app.pid, sampler.pid]}))
    pending.replace(root / 'started.json')
    if sys.argv[3] == 'acquisition':
        os.kill(os.getpid(), int(sys.argv[2]))
    return sampler
def step(seconds):
    global announced
    if sampler is not None and not announced:
        print(json.dumps({'output': str(output), 'pids': [app.pid, sampler.pid]}), flush=True)
        announced = True
    sleep(seconds)
b.quit_app = quit_app
b.running_pids = lambda: [app.pid] if app is not None and app.poll() is None else []
b.run_command = launch
b.subprocess.check_output = lambda *_args, **_kwargs: '\"HIDIdleTime\" = 120000000000'
b.subprocess.Popen = sample
b.time.sleep = step
args = argparse.Namespace(expected_display={}, disable=None, mount_cap=None, scrollbars=None, timeout=180, sample=60, sample_interval=5)
with b.bench_output({'label': 'signal'}) as output:
    b.measure_run(args, {'label': 'signal', 'quit': False}, output)
"""
    owner = subprocess.Popen(
        [sys.executable, "-c", bootstrap, str(tmp_path), str(signum), cancel_stage],
        env=os.environ
        | {
            "PYTHONPATH": os.pathsep.join(
                (str(ROOT / "dev-tools/src"), str(ROOT / "scripts"))
            )
        },
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
        text=True,
    )
    try:
        if cancel_stage == "active":
            assert select.select([owner.stdout], [], [], 60)[0], (
                "benchmark did not publish readiness"
            )
            json.loads(owner.stdout.readline())
            owner.send_signal(signum)
        owner.wait(timeout=60)
        ready = json.loads((tmp_path / "started.json").read_text())
        assert owner.returncode == 128 + signum
        receipt = json.loads((Path(ready["output"]) / "receipt.json").read_text())
        assert receipt["exitCode"] == 128 + signum
        for pid in ready["pids"]:
            state = subprocess.run(
                ["ps", "-p", str(pid), "-o", "stat="],
                capture_output=True,
                text=True,
                check=False,
            )
            assert state.returncode != 0 or state.stdout.strip().startswith("Z"), (
                state.stdout
            )
    finally:
        rows = subprocess.check_output(["ps", "-axo", "pgid=,args="], text=True)
        if any(
            int(parts[0]) == owner.pid and str(tmp_path) in parts[1]
            for row in rows.splitlines()
            if len(parts := row.split(None, 1)) == 2
        ):
            try:
                os.killpg(owner.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        owner.communicate(timeout=60)
