import importlib.util
import io
import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(
        name, Path(__file__).resolve().parents[1] / filename
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


identity = load("device_build_identity", "device-build-identity.py")
installer = load("install_built_app", "install-built-app.py")


class DeviceSelectionTests(unittest.TestCase):
    devices = [
        {
            "identifier": "ipad-core",
            "hardwareProperties": {"reality": "physical", "platform": "iOS", "deviceType": "iPad", "udid": "IPAD"},
            "connectionProperties": {"pairingState": "paired", "tunnelState": "connected"},
            "deviceProperties": {"name": "iPad"},
        },
        {
            "identifier": "iphone-core",
            "hardwareProperties": {"reality": "physical", "platform": "iOS", "deviceType": "iPhone", "udid": "IPHONE"},
            "connectionProperties": {"pairingState": "paired", "tunnelState": "disconnected"},
            "deviceProperties": {"name": "Phone"},
        },
    ]

    def find(self, requested):
        def listed(command, **_):
            output = Path(command[command.index("--json-output") + 1])
            output.write_text(json.dumps({"result": {"devices": self.devices}}))
            return subprocess.CompletedProcess(command, 0)

        with patch.object(installer.subprocess, "run", side_effect=listed):
            device = installer.find_device(requested)
        return device and device["identifier"]

    def test_implicit_selection_stays_on_the_iphone(self):
        self.assertEqual(self.find(""), "iphone-core")

    def test_an_explicitly_named_ipad_is_selectable(self):
        self.assertEqual(self.find("IPAD"), "ipad-core")
        self.assertEqual(self.find("iPad"), "ipad-core")


class DeviceBuildIdentityTests(unittest.TestCase):
    def test_counter_produces_distinct_valid_build_numbers(self):
        with tempfile.TemporaryDirectory() as temporary:
            counter = Path(temporary) / "counter"
            self.assertEqual(identity.next_build_number(counter), "1.0.1")
            self.assertEqual(identity.next_build_number(counter), "1.0.2")
            counter.write_text("9999")
            self.assertEqual(identity.next_build_number(counter), "2.0.0")
            self.assertEqual(identity.next_build_number(counter, 10004), "2.0.5")

    def test_remote_reservation_migrates_local_floor_and_uses_one_coordinator_counter(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            local = root / "builder-counter"
            local.write_text("129")
            coordinator = root / "coordinator"
            coordinator.mkdir()

            def remote(command, **_):
                # Execute the exact SSH python payload in an isolated coordinator home.
                program = shlex.split(command[-1])[2]
                completed = subprocess.run([sys.executable, "-c", program],
                    env=os.environ | {"HOME": str(coordinator)}, capture_output=True, text=True, check=True)
                return completed.stdout

            with patch.object(identity.socket, "gethostname", return_value="laptop"), \
                 patch.object(identity, "maintainer_config", return_value={"buildNumberCoordinatorHost": "coordinator"}), \
                 patch.object(identity.subprocess, "check_output", side_effect=remote):
                self.assertEqual(identity.reserve_build_number(local), "1.1.30")
                self.assertEqual(identity.reserve_build_number(local), "1.1.31")
            self.assertEqual(local.read_text(), "131")
            self.assertEqual((coordinator / "Library/Caches/RemoteCoder-Build/device-build-counter").read_text(), "131")

    def test_coordinator_failure_never_consumes_a_local_fallback_number(self):
        with tempfile.TemporaryDirectory() as temporary:
            counter = Path(temporary) / "counter"
            counter.write_text("42")
            with (
                patch.object(
                    identity.socket, "gethostname", return_value="laptop"
                ),
                patch.object(
                    identity, "maintainer_config",
                    return_value={"buildNumberCoordinatorHost": "coordinator"},
                ),
                patch.object(
                    identity.subprocess,
                    "check_output",
                    side_effect=subprocess.TimeoutExpired("ssh", 30),
                ),
                self.assertRaisesRegex(RuntimeError, "no local numbering fallback"),
            ):
                identity.reserve_build_number(counter)
            self.assertEqual(counter.read_text(), "42")

    def test_actual_settings_and_bundle_must_match_requested_candidate(self):
        candidate = {
            "buildId": "fixture",
            "sourceCommit": "abc",
            "sourceFingerprint": "def",
            "sourceModified": True,
            "buildNumber": "1.0.1",
            "configuration": "Debug",
            "optimized": True,
            "compilationMode": "wholemodule",
        }
        settings = {
            "CONFIGURATION": "Debug",
            "PRODUCT_BUNDLE_IDENTIFIER": "com.example.RemoteCoder",
            "SWIFT_OPTIMIZATION_LEVEL": "-O",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "CURRENT_PROJECT_VERSION": "1.0.1",
            "RC_BUILD_ID": "fixture",
            "RC_SOURCE_COMMIT": "abc",
            "RC_SOURCE_FINGERPRINT": "def",
            "RC_SOURCE_MODIFIED": "true",
        }
        verified = identity.verify_settings(
            [{"target": "RemoteCoder", "buildSettings": settings}],
            candidate,
            "RemoteCoder",
        )
        incremental_candidate = candidate | {"compilationMode": "singlefile"}
        incremental_settings = settings | {"SWIFT_COMPILATION_MODE": "singlefile"}
        incremental_verified = identity.verify_settings(
            [{"target": "RemoteCoder", "buildSettings": incremental_settings}],
            incremental_candidate,
            "RemoteCoder",
        )
        self.assertEqual(incremental_verified["SWIFT_OPTIMIZATION_LEVEL"], "-O")
        with self.assertRaisesRegex(ValueError, "SWIFT_COMPILATION_MODE"):
            identity.verify_settings(
                [{"target": "RemoteCoder", "buildSettings": settings}],
                incremental_candidate,
                "RemoteCoder",
            )
        bundle = {
            "CFBundleIdentifier": "com.example.RemoteCoder",
            "CFBundleVersion": "1.0.1",
            "RemoteCoderBuildID": "fixture",
            "RemoteCoderSourceCommit": "abc",
            "RemoteCoderSourceFingerprint": "def",
            "RemoteCoderSourceModified": "true",
            "RemoteCoderBuildOptimization": "-O",
        }
        evidence = {"identity": candidate, "settings": verified}
        identity.verify_bundle(bundle, evidence)
        with self.assertRaises(ValueError):
            identity.verify_settings(
                [
                    {
                        "target": "RemoteCoder",
                        "buildSettings": settings
                        | {"SWIFT_OPTIMIZATION_LEVEL": "-Onone"},
                    }
                ],
                candidate,
                "RemoteCoder",
            )
        with self.assertRaises(ValueError):
            identity.verify_bundle(bundle | {"RemoteCoderBuildID": "stale"}, evidence)
        with self.assertRaises(ValueError):
            identity.verify_settings([], candidate, "RemoteCoder")

    def test_modified_stamp_must_match_settings_and_bundle(self):
        for modified in (True, False):
            with self.subTest(modified=modified):
                candidate = {
                    "buildId": "fixture",
                    "sourceCommit": "abc",
                    "sourceFingerprint": "def",
                    "sourceModified": modified,
                    "buildNumber": "1.0.1",
                    "configuration": "Debug",
                    "optimized": True,
                    "compilationMode": "wholemodule",
                }
                stamp = "true" if modified else "false"
                settings = {
                    "CONFIGURATION": "Debug",
                    "PRODUCT_BUNDLE_IDENTIFIER": "com.example.RemoteCoder",
                    "SWIFT_OPTIMIZATION_LEVEL": "-O",
                    "SWIFT_COMPILATION_MODE": "wholemodule",
                    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                    "CURRENT_PROJECT_VERSION": "1.0.1",
                    "RC_BUILD_ID": "fixture",
                    "RC_SOURCE_COMMIT": "abc",
                    "RC_SOURCE_FINGERPRINT": "def",
                    "RC_SOURCE_MODIFIED": stamp,
                }
                evidence = {"identity": candidate, "settings": settings}
                bundle = {
                    "CFBundleIdentifier": "com.example.RemoteCoder",
                    "CFBundleVersion": "1.0.1",
                    "RemoteCoderBuildID": "fixture",
                    "RemoteCoderSourceCommit": "abc",
                    "RemoteCoderSourceFingerprint": "def",
                    "RemoteCoderSourceModified": stamp,
                    "RemoteCoderBuildOptimization": "-O",
                }
                identity.verify_settings(
                    [{"target": "RemoteCoder", "buildSettings": settings}], candidate, "RemoteCoder"
                )
                identity.verify_bundle(bundle, evidence)
                for invalid in (None, "unrecorded", "false" if modified else "true"):
                    with self.assertRaisesRegex(ValueError, "RC_SOURCE_MODIFIED"):
                        identity.verify_settings(
                            [
                                {
                                    "target": "RemoteCoder",
                                    "buildSettings": settings
                                    | {"RC_SOURCE_MODIFIED": invalid},
                                }
                            ],
                            candidate, "RemoteCoder",
                        )
                    with self.assertRaisesRegex(
                        ValueError, "RemoteCoderSourceModified"
                    ):
                        identity.verify_bundle(
                            bundle | {"RemoteCoderSourceModified": invalid}, evidence
                        )

    def test_prepare_emits_snapshot_modified_flag(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.json"
            output = Path(temporary) / "identity.json"
            for modified, mode_flags, optimized, compilation, configuration in (
                (True, [], True, "singlefile", "Debug"),
                (False, ["--optimized"], True, "wholemodule", "Debug"),
                (True, ["--incremental-optimized"], True, "singlefile", "Debug"),
                (False, ["--unoptimized"], False, "singlefile", "Debug"),
                (True, ["--release"], True, "wholemodule", "Release"),
                ("false", [], True, "wholemodule", "Debug"),
                (None, [], True, "wholemodule", "Debug"),
            ):
                source.write_text(
                    json.dumps(
                        {
                            "buildId": "12345678-1234-1234-1234-123456789abc",
                            "sourceCommit": "a" * 40,
                            "sourceFingerprint": "fingerprint",
                            "sourceModified": modified,
                        }
                    )
                )
                stdout = io.StringIO()
                with (
                    patch.dict(os.environ, {"RC_BUILD_PROVENANCE": str(source)}),
                    patch(
                        "sys.argv", ["device-build-identity.py", "prepare", str(output), *mode_flags]
                    ),
                    patch.object(identity, "reserve_build_number", return_value="1.0.1"),
                    redirect_stdout(stdout),
                ):
                    if isinstance(modified, bool):
                        identity.main()
                        prepared = json.loads(output.read_text())
                        self.assertEqual(prepared["optimized"], optimized)
                        self.assertEqual(prepared["compilationMode"], compilation)
                        self.assertEqual(prepared["configuration"], configuration)
                        self.assertIs(
                            json.loads(output.read_text())["sourceModified"], modified
                        )
                        self.assertIn(
                            "RC_SOURCE_MODIFIED=" + ("true" if modified else "false"),
                            stdout.getvalue(),
                        )
                    else:
                        with self.assertRaisesRegex(
                            TypeError, "sourceModified must be a boolean"
                        ):
                            identity.main()

    def test_generation_cache_tracks_manifests_and_globbed_paths_not_generated_files(
        self,
    ):
        script = Path(__file__).resolve().parents[1] / "install-device"
        source = script.read_text()
        function = (
            "project_generate_fingerprint() {"
            + source.split("project_generate_fingerprint() {", 1)[1].split("\n}\n", 1)[
                0
            ]
            + "\n}\n"
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in (
                "RemoteCoder",
                "RemoteCoder/Resources",
                "RemoteCoder/Assets.xcassets",
                "RemoteCoderLiveActivities",
                "RemoteCoderLocationPushService",
                "RemoteCoderNotificationService",
                "RemoteCoderShareExtension",
                "RemoteCoderCaptureExtension",
                "Shared",
                "protocol-fixtures",
                "Core",
                "scripts",
                "Derived/InfoPlists",
                "RemoteCoder.xcodeproj",
            ):
                (root / name).mkdir(parents=True, exist_ok=True)
            for name in (
                "Project.swift",
                "Tuist.swift",
                ".package.resolved",
                "Core/Package.swift",
                ".tuist-version",
                "scripts/install-device",
                "RemoteCoder.xcodeproj/project.pbxproj",
            ):
                (root / name).write_text("fixture")
            info = root / "Derived/InfoPlists/RemoteCoder-Info.plist"
            info.write_text("new build identity fields")
            swift = root / "RemoteCoder/App.swift"
            swift.write_text("first")

            def fingerprint():
                return subprocess.check_output(
                    [
                        "bash",
                        "-c",
                        "set -euo pipefail; PROJECT=RemoteCoder.xcodeproj; tuist() { printf fixture; };\n"
                        + function
                        + "project_generate_fingerprint",
                    ],
                    cwd=root,
                    text=True,
                ).strip()

            first = fingerprint()
            (root / ".tuist-version").write_text("different toolchain")
            self.assertNotEqual(first, fingerprint())
            (root / ".tuist-version").write_text("fixture")
            swift.write_text("ordinary source edit")
            self.assertEqual(first, fingerprint())
            (root / "Shared/Added.swift").write_text("struct Added {}")
            self.assertNotEqual(first, fingerprint())
            (root / "Shared/Added.swift").unlink()
            self.assertEqual(first, fingerprint())
            capture = root / "RemoteCoderCaptureExtension/Capture.swift"
            capture.write_text("struct Capture {}")
            self.assertNotEqual(first, fingerprint())
            capture.unlink()
            self.assertEqual(first, fingerprint())
            info.write_text("stale generated file from a later source snapshot")
            self.assertEqual(first, fingerprint())
            (root / "RemoteCoder/Resources/RemoteCoderLocalConfig.json").write_text(
                "{}"
            )
            self.assertNotEqual(first, fingerprint())

    def test_symbols_must_match_real_code_not_only_the_debug_shim(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "RemoteCoder.app"
            app.mkdir()
            for name in ("RemoteCoder", "RemoteCoder.debug.dylib"):
                (app / name).write_bytes(b"synthetic Mach-O")
            dsym = root / "RemoteCoder.app.dSYM"
            dsym.mkdir()
            shim = {("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "arm64")}
            code = {("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", "arm64")}

            def actual(path):
                return (
                    code
                    if path.name in ("RemoteCoder.debug.dylib", "RemoteCoder.app.dSYM")
                    else shim
                )

            with patch.object(installer, "binary_identities", side_effect=actual):
                retained = installer.retain_symbols(app, root, root / "good")
                self.assertEqual(len(retained), 2)
                self.assertTrue((root / "good" / dsym.name).is_dir())
            with (
                patch.object(
                    installer,
                    "binary_identities",
                    side_effect=lambda path: (
                        code if path.name == "RemoteCoder.debug.dylib" else shim
                    ),
                ),
                self.assertRaisesRegex(RuntimeError, "UUID-matching"),
            ):
                installer.retain_symbols(app, root, root / "wrong")


if __name__ == "__main__":
    unittest.main()
