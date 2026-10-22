import argparse
import contextlib
import fcntl
import hashlib
import io
import json
import subprocess
import sys
import tempfile
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

    def test_scenario_owns_its_artifact_before_entering_device_work(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.object(build_support, "cache_root", return_value=Path(directory)):
            identity = hashlib.sha256(str(perf_harness.ROOT.resolve()).encode()).hexdigest()[:16]
            with patch.object(perf_harness, "run_scenario", side_effect=lambda _: self.assertTrue(
                held(Path(directory) / "local-installs" / f"{identity}.lock"))):
                perf_harness.scenario(SimpleNamespace())


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
            patch.object(perf_harness, "ROOT", Path(self.directory.name)),
            patch.object(perf_harness, "target", return_value=self.device),
            patch.object(perf_harness, "source_lease", source_lease),
            patch.object(perf_harness, "build_capacity", capacity),
            patch.object(perf_harness, "build_source_identity", return_value={"sourceFingerprint": "fixture"}),
            patch.object(perf_harness, "write_build_identity"),
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
        self.run_build([0, 0])
        self.assertEqual(
            self.events,
            ["source", ("capacity", True), "space", ("tuist", (11, 12)), ("xcodebuild", (11, 12))],
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
    def test_positive_accepts_finite_positive_numbers(self) -> None:
        self.assertEqual(perf_harness.positive(int)("3"), 3)
        self.assertEqual(perf_harness.positive(float)("0.5"), 0.5)

    def test_positive_rejects_zero_negative_and_non_finite_values(self) -> None:
        for kind, text in ((int, "0"), (int, "-1"), (float, "0"), (float, "-2.5"), (float, "nan"), (float, "inf")):
            with self.subTest(text=text), self.assertRaises(argparse.ArgumentTypeError):
                perf_harness.positive(kind)(text)


class ScenarioTests(unittest.TestCase):
    def test_invalid_windows_and_trace_failures_keep_identity_and_diagnostics(self) -> None:
        for failure in ("inactive", "trace", "cleanup"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app = root / "app"
                app.mkdir()
                (app / perf_harness.PROCESS).write_bytes(b"binary")
                identity = {"appExecutableSHA256": hashlib.sha256(b"binary").hexdigest(), "signing": "development"}
                (root / "perf-build-identity.json").write_text(json.dumps(identity))
                fixture = {"duration": 10, "actions": [], "events": []}
                data = json.dumps(fixture).encode()
                (root / "fixture.json").write_bytes(data)
                device = Mock(derived=root, app=app, udid="test-ipad")
                result = {"valid": True, "activeThroughout": failure != "inactive", "conservedEnergy": False,
                          "frames": 120, "fixtureSHA256": hashlib.sha256(data).hexdigest(), "actions": [],
                          "appliedFrames": 0, "diagnostic": "preserve me"}
                args = SimpleNamespace(fixture=root / "fixture.json", trace_template="Time Profiler",
                                       trace_seconds=20, runs=1, settle=0, trace_dir=str(root), label="run",
                                       instrument=[], log=str(root / "reports.jsonl"))
                if failure == "cleanup":
                    def uninstall():
                        raise RuntimeError("disconnected")
                    device.uninstall = uninstall
                recorder = Mock()
                recorder.poll.return_value = None
                with patch.object(perf_harness, "fresh_launch"), patch.object(perf_harness, "send", side_effect=[{}, result]), \
                        patch.object(perf_harness.time, "sleep"), \
                        patch.object(perf_harness, "tracing", return_value=contextlib.nullcontext(recorder)), \
                        patch.object(perf_harness, "finish_trace", side_effect=SystemExit("incomplete trace") if failure == "trace" else None), \
                        self.assertRaises(SystemExit):
                    perf_harness.run_scenario.__wrapped__(args, device)
                device.prepare.assert_called_once()
                device.terminate.assert_called_once()
                failed = json.loads((root / "reports.failed-1.json").read_text())
                self.assertFalse(failed["valid"])
                self.assertEqual(failed["signing"], "development")
                self.assertEqual(failed["driverSHA256"], perf_harness.DRIVER_SHA256)
                self.assertEqual(failed["diagnostic"], "preserve me")
                if failure == "cleanup":
                    self.assertIn("uninstall: disconnected", failed["cleanupFailures"])
                    self.assertFalse((root / "reports.jsonl").exists())
                else:
                    self.assertIn("validationError", failed)


if __name__ == "__main__":
    unittest.main()
