import copy
import importlib.util
import io
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from contextlib import nullcontext, redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "install_built_app", SCRIPTS / "install-built-app.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
FIXTURES = SCRIPTS / "tests/fixtures/devicectl"


def device(identifier, kind, reality="physical", tunnel="connected", paired="paired"):
    return {
        "identifier": identifier,
        "hardwareProperties": {
            "deviceType": kind,
            "platform": "iOS",
            "reality": reality,
            "udid": f"udid-{identifier}",
        },
        "connectionProperties": {"pairingState": paired, "tunnelState": tunnel},
        "deviceProperties": {"name": f"name-{identifier}"},
    }


class DeviceSelectionTests(unittest.TestCase):
    def setUp(self):
        self.devices = [
            device("tablet", "iPad"),
            device("phone", "iPhone"),
            device("other-phone", "iPhone"),
        ]

        def listed(command, **kwargs):
            output = Path(command[command.index("--json-output") + 1])
            output.write_text(json.dumps({"result": {"devices": self.devices}}))
            return subprocess.CompletedProcess(command, 0)

        mock = patch.object(module.subprocess, "run", side_effect=listed)
        mock.start()
        self.addCleanup(mock.stop)

    def test_explicit_target_resolves_ipad_and_iphone_by_each_identity(self):
        for identifier in ("tablet", "other-phone"):
            for requested in (identifier, f"udid-{identifier}", f"name-{identifier}"):
                with self.subTest(requested=requested):
                    selected = module.find_device(requested)
                    self.assertIsNotNone(selected)
                    self.assertEqual(selected["identifier"], identifier)

    def test_implicit_target_keeps_the_first_reachable_iphone(self):
        self.assertEqual(module.find_device("")["identifier"], "phone")
        self.devices = [device("tablet", "iPad")]
        self.assertIsNone(module.find_device(""))

    def test_unavailable_or_unmatched_explicit_target_never_falls_back(self):
        self.devices = [
            device("simulator", "iPad", reality="simulated"),
            device("offline", "iPad", tunnel="unavailable"),
            device("unpaired", "iPad", paired="unpaired"),
            device("phone", "iPhone"),
        ]
        for requested in ("simulator", "offline", "unpaired", "missing"):
            with self.subTest(requested=requested):
                self.assertIsNone(module.find_device(requested))

    def test_offline_paired_identity_resolves_without_changing_reachable_discovery(self):
        self.devices = [device("offline", "iPhone", tunnel="unavailable")]
        self.assertIsNone(module.find_device("offline"))
        self.assertEqual(module.find_device("offline", reachable_only=False)["hardwareProperties"]["udid"], "udid-offline")

    def test_ambiguous_explicit_name_requires_exact_identity(self):
        self.devices[2]["deviceProperties"]["name"] = "name-phone"
        with self.assertRaisesRegex(RuntimeError, "exact UDID"):
            module.find_device("name-phone")


class DeviceInstallTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.run = Path(temporary.name)
        self.info = {
            "CFBundleIdentifier": "com.example.RemoteCoder",
            "CFBundleShortVersionString": "3.36.1",
            "CFBundleVersion": "3036001",
        }
        self.receipt = {"installed": False, "readBack": False, "launched": False}
        self.responses = {
            operation: json.loads((FIXTURES / f"{fixture}.json").read_text())
            for operation, fixture in (
                ("install", "install-success"),
                ("info", "apps-readback"),
                ("process", "launch-locked"),
            )
        }
        self.responses["before"] = copy.deepcopy(self.responses["info"])
        self.responses["before"]["result"]["apps"] = []
        self.operations = []
        real_run = subprocess.run

        def recorded(command, **kwargs):
            if command[0] == "ditto":
                return real_run(command, **kwargs)
            operation = command[3]
            self.operations.append(operation)
            response = self.responses[operation]
            output = Path(command[command.index("--json-output") + 1])
            if output.name == "before.json":
                response = self.responses["before"]
            output.write_text(json.dumps(response))
            code = 1 if response["info"]["outcome"] == "failed" else 0
            return subprocess.CompletedProcess(
                command,
                code,
                stderr="Recorded devicectl failure: device locked" if code else "",
            )

        mock = patch.object(module.subprocess, "run", side_effect=recorded)
        mock.start()
        self.addCleanup(mock.stop)

    def install(self):
        module.install_and_launch(
            "recorded-device",
            self.run / "RemoteCoder.app",
            self.info,
            self.run,
            self.receipt,
            123,
        )

    def test_verified_install_succeeds_when_launch_is_denied_by_the_device_lock(self):
        self.install()
        self.assertTrue(self.receipt["installed"])
        self.assertTrue(self.receipt["readBack"])
        self.assertFalse(self.receipt["launched"])
        self.assertEqual(self.receipt["deviceVersion"], "3.36.1")
        self.assertEqual(self.receipt["deviceBuild"], "3036001")
        self.assertEqual(self.receipt["launchSkipped"], "device locked")

    def test_other_typed_launch_errors_stay_fatal_despite_locked_message_text(self):
        original = self.responses["process"]
        for level, key, value in (
            (0, "domain", "OtherErrorDomain"),
            (0, "code", 10003),
            (1, "domain", "OtherErrorDomain"),
            (1, "code", 2),
            (1, "code", True),
            (2, "domain", "OtherErrorDomain"),
            (2, "code", 6),
        ):
            with self.subTest(level=level, key=key):
                response = copy.deepcopy(original)
                error = response["error"]
                for _ in range(level):
                    error = error["userInfo"]["NSUnderlyingError"]["error"]
                error[key] = value
                self.responses["process"] = response
                with self.assertRaises(RuntimeError):
                    self.install()
                self.assertNotIn("launchSkipped", self.receipt)
                self.assertFalse(self.receipt["launched"])

    def test_unavailable_typed_launch_errors_are_not_classified_from_stderr(self):
        for error in (None, "device locked", {}, {"userInfo": []}):
            with self.subTest(error=error):
                self.responses["process"]["error"] = error
                with self.assertRaises(RuntimeError):
                    self.install()
                self.assertNotIn("launchSkipped", self.receipt)

    def test_recorded_install_failure_stops_before_readback_and_launch(self):
        self.responses["install"] = json.loads(
            (FIXTURES / "install-ddi-failure.json").read_text()
        )
        with self.assertRaises(RuntimeError):
            self.install()
        self.assertEqual(self.operations, ["info", "install"])
        self.assertFalse(self.receipt["installed"])
        self.assertNotIn("launchSkipped", self.receipt)

    def test_both_version_and_build_must_read_back_before_launch(self):
        installed = self.responses["info"]["result"]["apps"][0]
        for key, value in (("version", "3.36.0"), ("bundleVersion", "3036000")):
            with self.subTest(key=key):
                original = installed[key]
                installed[key] = value
                self.operations.clear()
                with self.assertRaisesRegex(RuntimeError, "version and build number"):
                    self.install()
                self.assertEqual(self.operations, ["info", "install", "info"])
                self.assertNotIn("launchSkipped", self.receipt)
                installed[key] = original

    def test_superseded_development_install_is_rejected_before_mutation(self):
        self.info.update(CFBundleShortVersionString="0.0.0", CFBundleVersion="1.2.3")
        self.responses["before"]["result"]["apps"] = [
            {"bundleIdentifier": self.info["CFBundleIdentifier"], "version": "0.0.0", "bundleVersion": "1.2.4"}]
        with self.assertRaisesRegex(RuntimeError, "newer development"):
            self.install()
        self.assertEqual(self.operations, ["info"])

    def test_release_number_does_not_block_development_domain(self):
        self.responses["before"]["result"]["apps"] = copy.deepcopy(self.responses["info"]["result"]["apps"])
        self.info.update(CFBundleShortVersionString="0.0.0", CFBundleVersion="1.2.3")
        self.responses["info"]["result"]["apps"][0].update(version="0.0.0", bundleVersion="1.2.3")
        self.install()
        self.assertTrue(self.receipt["readBack"])

    def test_coordinator_loss_prevents_install_after_preflight(self):
        calls = []
        def guard():
            calls.append(True)
            if len(calls) == 2:
                raise RuntimeError("lease lost")
        with self.assertRaisesRegex(RuntimeError, "lease lost"):
            module.install_and_launch("recorded-device", self.run / "RemoteCoder.app",
                                      self.info, self.run, self.receipt, 123, delivery_guard=guard)
        self.assertEqual(self.operations, ["info"])

    def test_unlocked_launch_still_records_success(self):
        self.responses["process"] = json.loads(
            (FIXTURES / "launch-success.json").read_text()
        )
        self.install()
        self.assertTrue(self.receipt["launched"])
        self.assertNotIn("launchSkipped", self.receipt)

    def test_release_cli_records_verified_readback_for_installs_and_current_skips(self):
        spec = importlib.util.spec_from_file_location(
            "install_release", SCRIPTS / "install-release.py"
        )
        release = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(release)
        with zipfile.ZipFile(self.run / "RemoteCoder-direct.ipa", "w") as ipa:
            ipa.writestr(
                "Payload/RemoteCoder.app/Info.plist", plistlib.dumps(self.info)
            )
        delivery = SimpleNamespace(
            automatic_route=lambda requested: (
                None,
                requested,
                ["recorded-device", "", "Fixture iPhone"],
            ),
            direct_install_lease=lambda _bundle, _udid: nullcontext(),
        )
        for name, apps, notice, installed, skipped in (
            ("install", [], "launch skipped: device locked", True, "device locked"),
            (
                "current",
                self.responses["info"]["result"]["apps"],
                "already has 3.36.1 (3036001)",
                False,
                None,
            ),
        ):
            with self.subTest(name=name):
                self.responses["before"]["result"]["apps"] = apps
                self.operations.clear()
                (self.run / "iphone-install.txt").unlink(missing_ok=True)
                deployments = self.run / name
                output = io.StringIO()
                errors = io.StringIO()
                with (
                    patch.object(release, "load_installer", return_value=module),
                    patch.object(release, "load_script", return_value=delivery),
                    patch.object(module, "DEPLOYMENTS", deployments),
                    patch.object(module, "device_lease", return_value=nullcontext(123)),
                    patch.object(
                        release.sys, "argv", ["install-release.py", "ios", str(self.run)]
                    ),
                    redirect_stdout(output),
                    redirect_stderr(errors),
                ):
                    release.main()
                self.assertIn(notice, output.getvalue())
                self.assertEqual(errors.getvalue(), "")
                receipt = json.loads(
                    next(deployments.glob("*/receipt.json")).read_text()
                )
                self.assertTrue(receipt["readBack"])
                self.assertEqual(receipt["installed"], installed)
                self.assertFalse(receipt["launched"])
                self.assertEqual(receipt["deviceVersion"], "3.36.1")
                self.assertEqual(receipt["deviceBuild"], "3036001")
                self.assertEqual(receipt.get("launchSkipped"), skipped)
                if not installed:
                    self.assertEqual(self.operations, ["info"])


class DeploymentRetentionTests(unittest.TestCase):
    def test_expired_runs_go_but_installed_symbols_and_owned_logs_stay(self):
        now = 2_000_000_000.0
        entries = {
            "ios-" + "1" * 32: (9, True),
            "ios-" + "2" * 32: (8, True),
            "ios-" + "3" * 32: (1, False),
            "ios-" + "4" * 32: (7.5, False),
            "ios-release-" + "5" * 32: (30, True),
            "mac-" + "6" * 32: (10, True),
            "mac-bench-" + "7" * 32: (9, None),
            "testflight-ios-3.30.0-3030000": (40, None),
            "shared-codex-install.out.log": (20, None),
            "ios-simulator-tests-2026-09-01T10-00-00Z.log": (8, None),
            "ios-device-build-2026-10-08T10-00-00Z.log": (1, None),
        }
        expired = {
            "ios-" + "1" * 32,
            "ios-" + "4" * 32,
            "ios-release-" + "5" * 32,
            "mac-bench-" + "7" * 32,
            "ios-simulator-tests-2026-09-01T10-00-00Z.log",
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, (days, installed) in entries.items():
                entry = root / name
                if name.endswith(".log"):
                    entry.write_text("log\n")
                else:
                    (entry / "symbols").mkdir(parents=True)
                    if installed is not None:
                        (entry / "receipt.json").write_text(
                            json.dumps({"installed": installed})
                        )
                os.utime(entry, (now - days * 86400, now - days * 86400))

            removed = module.prune_deployments(root, now)

            self.assertEqual({entry.name for entry in removed}, expired)
            self.assertEqual(
                {entry.name for entry in root.iterdir()}, set(entries) - expired
            )

if __name__ == "__main__":
    unittest.main()
