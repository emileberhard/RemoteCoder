import argparse
import contextlib
import fcntl
import gzip
import hashlib
import io
import json
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import build_support  # noqa: E402

from remotecoder_tools import perf_harness  # noqa: E402


def held(path: Path) -> bool:
    with path.open("a") as lease:
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False


class LeaseTests(unittest.TestCase):
    def test_saved_template_identity_changes_when_the_same_path_changes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            template = Path(directory) / "Immediate.tracetemplate"
            template.write_bytes(b"saved immediate template")
            before = perf_harness.instrumentation(SimpleNamespace(), str(template), [])
            self.assertEqual(before["templateSHA256"], hashlib.sha256(template.read_bytes()).hexdigest())
            template.write_bytes(b"saved deferred template")
            after = perf_harness.instrumentation(SimpleNamespace(), str(template), [])
            self.assertNotEqual(before, after)
            template.write_bytes(b"x" * (4 * 1_048_576 + 1))
            with self.assertRaisesRegex(ValueError, "exceeds 4 MiB"):
                perf_harness.instrumentation(SimpleNamespace(), str(template), [])

    def test_device_lease_is_the_installers_per_device_lock(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.object(build_support, "cache_root", return_value=Path(directory)):
            expected = Path(directory) / "device-locks" / (hashlib.sha256(b"UDID-1").hexdigest() + ".lock")
            with perf_harness.device_lease("UDID-1"):
                self.assertTrue(held(expected))
                other = Path(directory) / "device-locks" / (hashlib.sha256(b"UDID-2").hexdigest() + ".lock")
                self.assertFalse(held(other))
            self.assertFalse(held(expected))

    def test_source_lease_is_the_worktree_lock_install_dev_takes(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.object(build_support, "cache_root", return_value=Path(directory)):
            identity = hashlib.sha256(str(perf_harness.ROOT.resolve()).encode()).hexdigest()[:16]
            with perf_harness.source_lease():
                self.assertTrue(held(Path(directory) / "local-installs" / f"{identity}.lock"))

    def test_device_commands_run_under_the_device_lease(self) -> None:
        events: list[str] = []

        @contextlib.contextmanager
        def lease(udid: str):
            events.append(f"acquire {udid}")
            yield 0
            events.append(f"release {udid}")

        @perf_harness.leased
        def command(args, device) -> None:
            events.append(f"run {device.udid}")

        with patch.object(perf_harness, "target", return_value=SimpleNamespace(udid="UDID-1")), \
                patch.object(perf_harness, "device_lease", lease):
            command(SimpleNamespace())
        self.assertEqual(events, ["acquire UDID-1", "run UDID-1", "release UDID-1"])

    def test_scenario_validates_paths_before_device_work(self) -> None:
        args = SimpleNamespace(log="/tmp/private-report.jsonl", trace_dir="/tmp/traces", label="run")
        with patch.object(perf_harness, "run_scenario") as run, self.assertRaises(ValueError):
            perf_harness.scenario(args)
        run.assert_not_called()

    def test_scenario_orders_source_capacity_device_after_a_contending_installer(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.object(build_support, "cache_root", return_value=Path(directory)):
            compiler = Path(directory) / "capacity/0.lock"
            compiler.parent.mkdir()
            device_path = build_support.device_lease_path("test-ipad")
            device_path.parent.mkdir(parents=True)
            delivered = Path(directory) / "delivered"
            program = "import fcntl,sys; from pathlib import Path; c=open(sys.argv[1],'a'); fcntl.flock(c,fcntl.LOCK_EX); print('capacity',flush=True); sys.stdin.read(1); d=open(sys.argv[2],'a'); fcntl.flock(d,fcntl.LOCK_EX); Path(sys.argv[3]).touch()"
            installer = subprocess.Popen([sys.executable, "-c", program, str(compiler), str(device_path), str(delivered)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(installer.stdout.readline().strip(), "capacity")
                @perf_harness.leased
                def probe(args, device, index, deadline):
                    self.assertTrue(delivered.exists())
                    for path in (compiler, compiler.with_name("1.lock"), device_path, build_support.source_lease_path(perf_harness.ROOT)):
                        self.assertTrue(held(path))
                    self.assertGreater(deadline, perf_harness.time.monotonic())
                def release():
                    installer.stdin.write(".")
                    installer.stdin.flush()
                timer = threading.Timer(0.05, release)
                timer.start()
                try:
                    with patch.object(perf_harness, "scenario_outputs"), patch.object(perf_harness, "run_scenario", probe), \
                            patch.object(perf_harness, "target", return_value=SimpleNamespace(udid="test-ipad")):
                        perf_harness.scenario(SimpleNamespace(runs=2))
                finally:
                    timer.cancel()
                    timer.join()
                self.assertFalse(held(compiler))
                self.assertFalse(held(device_path))
            finally:
                if installer.poll() is None:
                    installer.kill()
                installer.communicate(timeout=2)

    def test_window_activates_separate_deadline_after_queue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            record = Path(directory) / "reservation.json"
            record.write_text(json.dumps({"deadline": 1900, "owner": "unchanged"}))
            capacity = SimpleNamespace(record=record)
            with patch.object(perf_harness, "measurement_capacity", return_value=contextlib.nullcontext(capacity)) as reserve, \
                    patch.object(perf_harness.time, "monotonic", return_value=100), \
                    patch.object(perf_harness.signal, "setitimer", return_value=(0, 0)) as timer:
                with perf_harness.scenario_window(400):
                    self.assertEqual(json.loads(record.read_text())["deadline"], 530)
                self.assertEqual(reserve.call_args.args[1], 1800)
                self.assertEqual(timer.call_args_list[0].args, (signal.ITIMER_REAL, 400))
                self.assertEqual(timer.call_args_list[-1].args, (signal.ITIMER_REAL, 0, 0))

    def test_expired_queue_is_not_reactivated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            record = Path(directory) / "reservation.json"
            record.write_text(json.dumps({"deadline": 99}))
            with patch.object(perf_harness, "measurement_capacity", return_value=contextlib.nullcontext(SimpleNamespace(record=record))), \
                    patch.object(perf_harness.time, "monotonic", return_value=100), self.assertRaises(TimeoutError):
                with perf_harness.scenario_window(400):
                    self.fail("expired queue activated")


class DeviceCleanupTests(unittest.TestCase):
    def test_failed_uninstall_requires_proven_absence(self) -> None:
        device = object.__new__(perf_harness.Device)
        device.udid = "test-ipad"
        for present in [False, True]:
            def apps(*arguments, present=present):
                Path(arguments[-1]).write_text(json.dumps({"result": {"apps":
                    [{"bundleIdentifier": perf_harness.BUNDLE}] if present else []}}))
            with self.subTest(present=present), patch.object(device, "devicectl", side_effect=apps), \
                    patch.object(perf_harness.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)):
                if present:
                    with self.assertRaises(subprocess.CalledProcessError):
                        device.uninstall()
                else:
                    device.uninstall()
        with patch.object(device, "devicectl", side_effect=RuntimeError("disconnected")), \
                patch.object(perf_harness.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)), \
                self.assertRaisesRegex(RuntimeError, "disconnected"):
            device.uninstall()

    @unittest.skipUnless(sys.platform == "darwin", "requires Apple's property-list converter")
    def test_simulator_absence_uses_the_openstep_app_inventory(self) -> None:
        device = object.__new__(perf_harness.Simulator)
        device.udid = "test-simulator"
        original = subprocess.run

        def invoke(command, **kwargs):
            if command[:3] == ["xcrun", "simctl", "uninstall"]:
                return subprocess.CompletedProcess(command, 1)
            return original(command, **kwargs)

        for bundle in ["other.app", perf_harness.BUNDLE]:
            listing = '{ "' + bundle + '" = { CFBundleIdentifier = "' + bundle + '"; }; }'
            with self.subTest(bundle=bundle), patch.object(perf_harness, "output", return_value=listing), \
                    patch.object(perf_harness.subprocess, "run", side_effect=invoke):
                if bundle == perf_harness.BUNDLE:
                    with self.assertRaises(subprocess.CalledProcessError):
                        device.uninstall()
                else:
                    device.uninstall()

    def test_failed_process_inventory_is_not_successful_termination(self) -> None:
        device = object.__new__(perf_harness.Device)
        device.udid = "test-ipad"
        with patch.object(device, "devicectl", side_effect=RuntimeError("disconnected")), \
                self.assertRaisesRegex(RuntimeError, "disconnected"):
            device.terminate()


class BuildTests(unittest.TestCase):
    def setUp(self) -> None:
        self.events: list[object] = []
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.device = SimpleNamespace(
            derived=Path("build/perf-sim-derived"), app=Path("RemoteCoder.app"), build_settings=lambda: ["-destination", "sim"],
        )

        @contextlib.contextmanager
        def source_lease():
            self.events.append("source")
            yield 11

        @contextlib.contextmanager
        def capacity(background: bool = False):
            self.events.append(("capacity", background))
            yield 12

        self.patches = [
            patch.object(perf_harness, "ENV", {}),
            patch.object(perf_harness, "ROOT", Path(self.directory.name)),
            patch.object(perf_harness, "target", return_value=self.device),
            patch.object(perf_harness, "source_lease", source_lease),
            patch.object(perf_harness, "build_capacity", capacity),
            patch.object(perf_harness, "build_source_identity", return_value={"sourceFingerprint": "fixture"}),
            patch.object(perf_harness, "write_build_identity"),
            patch.object(perf_harness, "harness_source_identity", return_value={"harnessSHA256": "a" * 64}),
            patch.object(perf_harness, "output", side_effect=["Xcode test", json.dumps([{"target": "RemoteCoder", "buildSettings": {"SWIFT_OPTIMIZATION_LEVEL": "-O"}}])]),
        ]
        for started in self.patches:
            started.start()
            self.addCleanup(started.stop)

    def run_build(self, statuses: list[int], space_error: ValueError | None = None) -> None:
        results = iter(statuses)

        def run_owned(command, cwd, environment, output, lease_fds=()):
            self.events.append((command[0], lease_fds))
            return next(results)

        def require_space(path: Path) -> None:
            self.events.append("space")
            if space_error:
                raise space_error

        with patch.object(perf_harness, "run_owned", run_owned), patch.object(perf_harness, "require_build_space", require_space), \
                contextlib.redirect_stdout(io.StringIO()):
            perf_harness.build(SimpleNamespace(device=None, disable=None))

    def test_generation_and_build_run_under_source_lease_then_capacity_with_both_inherited(self) -> None:
        self.run_build([0, 0, 0])
        self.assertEqual(
            self.events,
            ["source", ("capacity", True), "space", ("tuist", (11, 12)), ("tuist", (11, 12)), ("xcodebuild", (11, 12))],
        )

    def test_failed_generation_stops_before_xcodebuild_and_propagates_its_status(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.run_build([7])
        self.assertEqual(raised.exception.code, 7)
        self.assertNotIn(("xcodebuild", (11, 12)), self.events)

    def test_low_disk_space_stops_before_any_command(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.run_build([0, 0], space_error=ValueError("Build volume has 3.0 GiB free"))
        self.assertIn("3.0 GiB", str(raised.exception))
        self.assertEqual(self.events, ["source", ("capacity", True), "space"])


class ArgumentTests(unittest.TestCase):
    def test_template_names_exclude_registered_custom_templates(self) -> None:
        output = "== Standard Templates ==\nTime Profiler\nAllocations\n== Custom Templates ==\nMy Template\n"
        with patch.object(perf_harness.subprocess, "run", return_value=SimpleNamespace(stdout=output)):
            names = perf_harness.built_in_templates.__wrapped__()
        self.assertEqual(names, frozenset({"Time Profiler", "Allocations"}))
        with patch.object(perf_harness, "built_in_templates", return_value=names), self.assertRaisesRegex(ValueError, "explicit saved template"):
            perf_harness.instrumentation(SimpleNamespace(), "My Template", [])

    def test_positive_accepts_finite_positive_numbers(self) -> None:
        self.assertEqual(perf_harness.positive(int)("3"), 3)
        self.assertEqual(perf_harness.positive(float)("0.5"), 0.5)

    def test_positive_rejects_zero_negative_and_non_finite_values(self) -> None:
        for kind, text in ((int, "0"), (int, "-1"), (float, "0"), (float, "-2.5"), (float, "nan"), (float, "inf")):
            with self.subTest(text=text), self.assertRaises(argparse.ArgumentTypeError):
                perf_harness.positive(kind)(text)


class ScenarioTests(unittest.TestCase):
    def setUp(self) -> None:
        templates = patch.object(perf_harness, "built_in_templates", return_value=frozenset({"Time Profiler", "Allocations"}))
        templates.start()
        self.addCleanup(templates.stop)

    def test_notification_cleanup_failure_preserves_the_original_failure(self) -> None:
        notify = Mock()
        notify.notify_register_file_descriptor.return_value = 0
        notify.notify_cancel.return_value = 1
        original = ValueError("original window failure")
        with patch.object(perf_harness.ctypes, "CDLL", return_value=notify):
            with self.assertRaises(ValueError) as raised, perf_harness._trace_notification("test"):
                raise original
            self.assertIs(raised.exception, original)
            self.assertIn("Could not cancel", original.__notes__[0])
            with self.assertRaisesRegex(RuntimeError, "Could not cancel"), perf_harness._trace_notification("test"):
                pass

    def test_trace_uses_a_private_frozen_template_and_keeps_its_identity(self) -> None:
        for failure in (False, True):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                original = root / "Immediate.tracetemplate"
                original.write_bytes(b"template A")
                recorder = Mock()
                recorder.poll.return_value = None
                recorder.communicate.return_value = ("", None)
                snapshots = []
                def launch(command, snapshots=snapshots, original=original, recorder=recorder, **kwargs):
                    snapshot = Path(command[command.index("--template") + 1])
                    snapshots.append(snapshot)
                    self.assertNotEqual(snapshot, original)
                    self.assertEqual(snapshot.stat().st_mode & 0o777, 0o600)
                    original.write_bytes(b"template B")
                    self.assertEqual(snapshot.read_bytes(), b"template A")
                    return recorder
                with patch.object(perf_harness, "_trace_notification", return_value=contextlib.nullcontext((91, 17))), \
                        patch.object(perf_harness.subprocess, "Popen", side_effect=launch), \
                        patch.object(perf_harness.select, "select", return_value=([91], [], [])), \
                        patch.object(perf_harness.os, "read", return_value=(17).to_bytes(4, "big")), \
                        patch.object(perf_harness.time, "sleep"):
                    try:
                        with perf_harness.tracing(SimpleNamespace(udid="ipad"), str(original), [], 315, str(root / "run.trace")) as active:
                            self.assertEqual(active.perf_instrumentation["template"], str(original))
                            self.assertEqual(active.perf_instrumentation["templateSHA256"], hashlib.sha256(b"template A").hexdigest())
                            original.write_bytes(b"template C")
                            self.assertEqual(snapshots[0].read_bytes(), b"template A")
                            if failure:
                                raise RuntimeError("measured window failed")
                    except RuntimeError:
                        if not failure:
                            raise
                self.assertFalse(snapshots[0].exists())
                recorder.terminate.assert_called_once()

    def test_synchronous_trace_notification_registration_precedes_producer_and_cancels(self) -> None:
        for outcome in ("ready", "timeout", "recorder-failed", "registration-failed", "launch-failed", "token-mismatch", "truncated", "late"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory:
                clock, events = [0.0], []
                notify, recorder = Mock(), Mock()
                notify.notify_cancel.return_value = 0
                recorder.communicate.return_value = ("recorder output", None)
                recorder.poll.return_value = 1 if outcome == "recorder-failed" else None
                def register(name, descriptor, flags, token, outcome=outcome, events=events):
                    events.append("register")
                    self.assertEqual(flags, 0)
                    descriptor._obj.value = 91
                    token._obj.value = 17
                    return 1 if outcome == "registration-failed" else 0
                notify.notify_register_file_descriptor.side_effect = register
                def launch(command, outcome=outcome, events=events, recorder=recorder, **kwargs):
                    events.append("producer")
                    self.assertEqual(events, ["register", "producer"])
                    self.assertIn("--notify-tracing-started", command)
                    if outcome == "launch-failed":
                        raise OSError("recorder launch failed")
                    return recorder
                def select(readers, writers, errors, timeout, outcome=outcome, clock=clock):
                    self.assertEqual(readers, [91])
                    self.assertLessEqual(timeout, 0.1)
                    if outcome == "timeout":
                        clock[0] += timeout
                        return [], [], []
                    if outcome == "late":
                        clock[0] = 31
                    return [91], [], []
                def sleep(seconds, clock=clock):
                    clock[0] += seconds
                payload = (18 if outcome == "token-mismatch" else 17).to_bytes(4, "big")
                if outcome == "truncated":
                    payload = payload[:3]
                with patch.object(perf_harness.ctypes, "CDLL", return_value=notify), \
                        patch.object(perf_harness.subprocess, "Popen", side_effect=launch) as producer, \
                        patch.object(perf_harness.select, "select", side_effect=select), \
                        patch.object(perf_harness.os, "read", return_value=payload), \
                        patch.object(perf_harness.os, "close") as close, \
                        patch.object(perf_harness.time, "monotonic", side_effect=lambda clock=clock: clock[0]), \
                        patch.object(perf_harness.time, "sleep", side_effect=sleep):
                    if outcome == "ready":
                        with perf_harness.tracing(SimpleNamespace(udid="ipad"), "Time Profiler", ["Points of Interest"], 315, str(Path(directory) / "run.trace")) as active:
                            self.assertIs(active, recorder)
                            self.assertEqual(clock[0] - recorder.perf_started_monotonic, perf_harness.TRACE_WARMUP)
                    else:
                        with self.assertRaises((SystemExit, OSError, RuntimeError)):
                            with perf_harness.tracing(SimpleNamespace(udid="ipad"), "Time Profiler", [], 315, str(Path(directory) / "run.trace")):
                                self.fail("failed tracing startup yielded a recorder")
                    close.assert_not_called()
                if outcome == "registration-failed":
                    producer.assert_not_called()
                    notify.notify_cancel.assert_not_called()
                else:
                    notify.notify_cancel.assert_called_once_with(17)
                if outcome not in ("launch-failed", "registration-failed"):
                    recorder.communicate.assert_called_once_with(timeout=5)
                if outcome == "timeout":
                    self.assertLessEqual(clock[0], 30.1)
                    recorder.terminate.assert_called_once()

    def test_native_trace_cleanup_kills_processes_that_ignore_termination(self) -> None:
        process = Mock()
        process.poll.return_value = None
        process.communicate.side_effect = [subprocess.TimeoutExpired("owned trace", 5), ("output", None)]
        self.assertEqual(perf_harness.stop_trace_process(process), "output")
        process.terminate.assert_called_once()
        process.kill.assert_called_once()

    def test_trace_rejects_insufficient_remaining_journey_and_tail(self) -> None:
        recorder = Mock(perf_started_monotonic=0)
        recorder.poll.return_value = None
        with patch.object(perf_harness.time, "monotonic", return_value=12), self.assertRaisesRegex(SystemExit, "raise --trace-seconds"):
            perf_harness.require_trace_time(recorder, 314, 300)

    def test_invalid_windows_and_trace_failures_keep_identity_and_diagnostics(self) -> None:
        for failure in ("inactive", "trace", "cleanup", "interrupt", "artifact", "content", "trace-telemetry", "harness"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app = root / "app"
                app.mkdir()
                (app / perf_harness.PROCESS).write_bytes(b"binary")
                identity = {"appExecutableSHA256": hashlib.sha256(b"binary").hexdigest(), "signing": "development", "harnessSHA256": "a" * 64}
                (root / "perf-build-identity.json").write_text(json.dumps(identity))
                fixture = {"duration": 10, "actions": [], "events": []}
                data = json.dumps(fixture).encode()
                (root / "fixture.json").write_bytes(data)
                device = Mock(derived=root, app=app, udid="test-ipad")
                result = {"valid": failure != "content", "activeThroughout": failure != "inactive", "conservedEnergy": False,
                          "frames": 120, "fixtureSHA256": hashlib.sha256(data).hexdigest(), "harnessSHA256": "a" * 64, "actions": [],
                          "appliedFrames": 0, "diagnostic": "preserve me", "telemetryFiles": ["segment.jsonl.gz"]}
                if failure == "harness":
                    result["harnessSHA256"] = "b" * 64
                args = SimpleNamespace(fixture=root / "fixture.json", trace_template="Time Profiler",
                                       trace_seconds=100, runs=1, settle=0, trace_dir=str(root), label="run",
                                       instrument=[], log=str(root / "reports.jsonl"))
                events = []
                def uninstall(failure=failure, events=events):
                    events.append("uninstall")
                    if failure == "cleanup":
                        raise RuntimeError("disconnected")
                device.uninstall.side_effect = uninstall
                device.uninstall.__name__ = "uninstall"
                def collect(*_, failure=failure, events=events):
                    events.append("telemetry")
                    if failure == "trace-telemetry":
                        raise ValueError("copy failed")
                recorder = Mock()
                recorder.perf_instrumentation = perf_harness.instrumentation(device, args.trace_template, args.instrument)
                recorder.poll.return_value = None
                ownership = {"source": True, "measurement": True}
                def send(device, command, *args, ownership=ownership, failure=failure, result=result, app=app, **kwargs):
                    if command["cmd"] == "scenario-load":
                        self.assertGreater(args[0], 0)
                        self.assertLessEqual(args[0], 1800 - 100 - 30 - perf_harness.TRACE_WARMUP - 10 - 30)
                        self.assertTrue(ownership["source"])
                        self.assertTrue(ownership["measurement"])
                        if failure == "artifact":
                            (app / perf_harness.PROCESS).write_bytes(b"changed")
                        return {}
                    self.assertTrue(ownership["measurement"])
                    self.assertTrue(ownership["source"])
                    if failure == "interrupt":
                        signal.raise_signal(signal.SIGTERM)
                    return result
                with perf_harness.scenario_signals(), patch.object(perf_harness, "scenario_outputs"), \
                        patch.object(perf_harness, "collect_telemetry", side_effect=collect) as telemetry, \
                        patch.object(perf_harness, "fresh_launch"), patch.object(perf_harness, "send", side_effect=send), \
                        patch.object(perf_harness.time, "sleep"), \
                        patch.object(perf_harness, "tracing", return_value=contextlib.nullcontext(recorder)), \
                        patch.object(perf_harness, "require_trace_time"), \
                        patch.object(perf_harness, "finish_trace", side_effect=SystemExit("incomplete trace") if failure.startswith("trace") else None), \
                        self.assertRaises(SystemExit):
                    perf_harness.run_scenario.__wrapped__(args, device, 0, perf_harness.time.monotonic() + 1800)
                device.prepare.assert_called_once()
                device.terminate.assert_called_once()
                failed = json.loads((root / "reports.failed-1.json").read_text())
                self.assertFalse(failed["valid"])
                self.assertEqual(failed["signing"], "development")
                self.assertEqual(failed["driverSHA256"], perf_harness.DRIVER_SHA256)
                if failure not in ("interrupt", "artifact"):
                    self.assertEqual(failed["diagnostic"], "preserve me")
                    self.assertEqual(events, ["telemetry", "uninstall"])
                    telemetry.assert_called_once()
                if failure == "trace-telemetry":
                    self.assertEqual(failed["validationError"], "incomplete trace")
                    self.assertEqual(failed["telemetryCollectionFailures"], ["copy failed"])
                self.assertTrue(ownership["measurement"])
                self.assertEqual((root / "reports.failed-1.json").stat().st_mode & 0o777, 0o600)
                if failure == "cleanup":
                    self.assertIn("uninstall: disconnected", failed["cleanupFailures"])
                    self.assertFalse((root / "reports.jsonl").exists())
                else:
                    self.assertIn("validationError", failed)


class TelemetryEvidenceTests(unittest.TestCase):
    def test_missing_export_cpu_stays_unknown_and_empty_capture_is_distinct(self) -> None:
        for exports, header, expected in [([{"processCpuNs": 1000000}, {}], True, None),
                                           ([], False, None), ([], True, 0),
                                           ([{"processCpuNs": 2000000}], True, 2)]:
            with self.subTest(exports=exports, header=header), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                telemetry = root / "telemetry"
                telemetry.mkdir()
                records = ([{"recordType": "run", "runID": "run", "startedAt": "2026-01-01T00:00:00+00:00"}] if header else [])
                records += [{"recordType": "export", "runID": "run", "seq": index, "ts": "2026-01-01T00:00:20+00:00", "totalMs": 1000, **entry}
                            for index, entry in enumerate(exports)]
                (telemetry / "segment.jsonl.gz").write_bytes(gzip.compress(b"\n".join(json.dumps(entry).encode() for entry in records)))
                device = Mock()
                device.perf_dir.return_value = root
                result = {"label": "test", "telemetryFiles": ["segment.jsonl.gz"], "startedAt": 1767225610,
                          "endedAt": 1767225630, "processCPUms": 10}
                with patch("remotecoder_tools.perf_replay.private_destination", side_effect=Path):
                    perf_harness.collect_telemetry(device, result, str(root / "reports.jsonl"))
                self.assertEqual(result["exportsInWindow"]["wholeProcessCPUms"], expected)
                self.assertEqual(result["exportsInWindow"]["telemetryEvidence"], header)
                self.assertEqual(result["exportsInWindow"]["cpuUnmeasuredCount"], sum("processCpuNs" not in entry for entry in exports))
                self.assertEqual(result["processAgeAtWindowStartSeconds"], 10 if header else None)
                self.assertEqual((root / "reports.telemetry/test/segment.jsonl.gz").stat().st_mode & 0o777, 0o600)

    def test_telemetry_collection_timeout_is_separate_from_original_validation(self) -> None:
        result = {"valid": False, "validationError": "content mismatch"}
        with patch.object(perf_harness, "collect_telemetry", side_effect=lambda *_: signal.raise_signal(signal.SIGALRM)):
            perf_harness.retain_returned_telemetry(Mock(), result, "unused")
        self.assertEqual(result["validationError"], "content mismatch")
        self.assertEqual(result["telemetryCollectionFailures"], ["telemetry collection exceeded 30 seconds"])

    def test_export_cpu_excludes_boundary_crossings_and_unknown_intervals(self) -> None:
        result = {"startedAt": 1767225610, "endedAt": 1767225630, "processCPUms": 100}
        records = [{"ts": "2026-01-01T00:00:12+00:00", "totalMs": 5000, "processCpuNs": 9000000},
                   {"ts": "2026-01-01T00:00:20+00:00", "totalMs": 5000, "processCpuNs": 2000000},
                   {"ts": "2026-01-01T00:00:32+00:00", "totalMs": 5000, "processCpuNs": 8000000},
                   {"ts": "2026-01-01T00:00:22+00:00", "processCpuNs": 6000000}]
        summary = perf_harness.export_window(records, True, result)
        self.assertEqual(summary["count"], 1)
        self.assertEqual(summary["wholeProcessCPUms"], 2)
        self.assertEqual(summary["boundaryCrossingCount"], 2)
        self.assertIsNone(summary["boundaryCrossingOverlapCPUms"])
        self.assertEqual(summary["unknownIntervalCount"], 1)
        self.assertEqual(summary["coverage"], "lowerBound")

    def test_private_report_restricts_existing_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.json"
            report.write_text("previous")
            report.chmod(0o644)
            with perf_harness.private_open(report, "w") as handle:
                handle.write("result")
            self.assertEqual(report.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()


class HarnessIdentityTests(unittest.TestCase):
    def test_compiled_harness_identity_ignores_production_changes_and_tracks_guarded_code(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(perf_harness, "ROOT", Path(directory)):
            root = Path(directory)
            (root / "Core/Sources").mkdir(parents=True)
            (root / "RemoteCoder").mkdir()
            owner = root / "Core/Sources/Owner.swift"
            owner.write_text("let production = 1\n#if RC_PERF_HARNESS\n#if os(iOS)\nlet fixture = 1\n#endif\n#endif\n")
            harness = root / "RemoteCoder/PerformanceReplayRun.swift"
            harness.write_text("#if RC_PERF_HARNESS\nlet replay = 1\n#endif\n")
            before = perf_harness.harness_source_identity(["-configuration", "Release"], "Xcode 27")
            owner.write_text(owner.read_text().replace("production = 1", "production = 2"))
            self.assertEqual(perf_harness.harness_source_identity(["-configuration", "Release"], "Xcode 27"), before)
            owner.write_text(owner.read_text().replace("fixture = 1", "fixture = 2"))
            self.assertNotEqual(perf_harness.harness_source_identity(["-configuration", "Release"], "Xcode 27"), before)
            changed = perf_harness.harness_source_identity(["-configuration", "Release"], "Xcode 27")
            self.assertNotEqual(perf_harness.harness_source_identity(["-configuration", "Debug"], "Xcode 27"), changed)
            self.assertNotEqual(perf_harness.harness_source_identity(["-configuration", "Release"], "Xcode 28"), changed)
            harness.write_text(harness.read_text().replace("replay = 1", "replay = 2"))
            self.assertNotEqual(perf_harness.harness_source_identity(["-configuration", "Release"], "Xcode 27"), changed)


class CompilerIdentityTests(unittest.TestCase):
    def test_resolved_compiler_flags_are_identified_without_cache_locations(self):
        root = perf_harness.ROOT
        before = perf_harness.effective_compiler_settings([{"target": "RemoteCoder", "buildSettings": {
            "SWIFT_OPTIMIZATION_LEVEL": "-O", "SWIFT_INCLUDE_PATHS": str(root / "build/one/include"), "TARGET_NAME": "RemoteCoder"
        }}], root / "build/one")
        after = perf_harness.effective_compiler_settings([{"target": "RemoteCoder", "buildSettings": {
            "SWIFT_OPTIMIZATION_LEVEL": "-O", "SWIFT_INCLUDE_PATHS": str(root / "build/two/include"), "TARGET_NAME": "RemoteCoder"
        }}], root / "build/two")
        self.assertEqual(before, after)
        after["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone"
        self.assertNotEqual(perf_harness.harness_source_identity(before, "Xcode"), perf_harness.harness_source_identity(after, "Xcode"))

    def test_action_hookup_is_identified_under_mixed_or_unconditional_production_views(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(perf_harness, "ROOT", Path(directory)):
            root = Path(directory)
            (root / "RemoteCoder").mkdir()
            (root / "Core/Sources").mkdir(parents=True)
            path = root / "RemoteCoder/ChatRootView.swift"
            call = "    ChatWindowActionsPublisher(\n        toggleSidebar: toggleHistory\n    )\n"
            path.write_text(call)
            before = perf_harness.harness_source_identity([], "Xcode")
            path.write_text("#if os(macOS) || RC_PERF_HARNESS\n" + call + "#endif\n")
            self.assertEqual(perf_harness.harness_source_identity([], "Xcode"), before)
            path.write_text(path.read_text().replace("toggleHistory", "differentAction"))
            self.assertNotEqual(perf_harness.harness_source_identity([], "Xcode"), before)
