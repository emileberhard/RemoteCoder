import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import xcode_build as module

WARNING = "error: the following command failed with exit code 0 but produced no further output\nLd /recorded/RemoteCoder.app/Contents/MacOS/RemoteCoder normal arm64 (in target 'RemoteCoderMac' from project 'RemoteCoder')\n"
EXTENSION_WARNING = (
    Path(__file__).parent / "fixtures/xcode-extensions/exit-zero.txt"
).read_text()


class XcodeDiagnosticProductTests(unittest.TestCase):
    def test_capture_extension_requires_the_extensionkit_embedded_product(self):
        target = "RemoteCoderCaptureExtension"
        with tempfile.TemporaryDirectory() as temporary:
            derived = Path(temporary)
            products = derived / "Build/Products/Debug-iphonesimulator"
            standalone = products / f"{target}.appex/{target}"
            standalone.parent.mkdir(parents=True)
            standalone.write_bytes(b"capture-extension")
            os.utime(standalone, (110, 110))
            diagnostics = [f"Ld capture (in target '{target}' from project 'RemoteCoder')"]
            with self.assertRaisesRegex(ValueError, "missing or stale"):
                module.verify_xcode_products("ios-build", derived, 100, diagnostics)

    def test_mac_bench_verifies_its_release_product_and_mac_install_its_debug_product(self):
        diagnostics = module.xcode_exit_zero_diagnostics(WARNING)
        for kind, configuration in (("mac-bench", "Release"), ("mac-install", "Debug")):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                derived = Path(temporary) / "derived"
                app = Path(f"{derived}-mac-optimized/Build/Products/{configuration}/RemoteCoder.app/Contents/MacOS/RemoteCoder")
                app.parent.mkdir(parents=True)
                app.write_bytes(b"mac-app")
                os.utime(app, (110, 110))
                self.assertEqual(module.verify_xcode_products(kind, derived, 100, diagnostics), [str(app)])

    def test_a_fresh_app_cannot_cover_a_missing_or_stale_extension(self):
        for kind, platform in (
            ("ios-build", "Debug-iphonesimulator"),
            ("ios-install", "Debug-iphoneos"),
        ):
            for target in (
                "RemoteCoderNotificationService",
                "RemoteCoderLocationPushService",
                "RemoteCoderLiveActivities",
            ):
                for modified in (None, 90, 110):
                    with (
                        self.subTest(kind=kind, target=target, modified=modified),
                        tempfile.TemporaryDirectory() as temporary,
                    ):
                        derived = Path(temporary)
                        products = derived / "Build/Products" / platform
                        app = products / "RemoteCoder.app/RemoteCoder"
                        expected = [app]
                        for extension in (
                            "RemoteCoderNotificationService",
                            "RemoteCoderLocationPushService",
                            "RemoteCoderLiveActivities",
                        ):
                            product = products / f"{extension}.appex/{extension}"
                            expected.append(product)
                            stamp = modified if extension == target else 110
                            if stamp is not None:
                                product.parent.mkdir(parents=True)
                                product.write_bytes(b"extension")
                                os.utime(product, (stamp, stamp))
                        app.parent.mkdir(parents=True)
                        app.write_bytes(b"fresh-app")
                        os.utime(app, (110, 110))
                        diagnostics = module.xcode_exit_zero_diagnostics(
                            EXTENSION_WARNING
                        )
                        if modified is None or modified < 100:
                            with self.assertRaisesRegex(
                                ValueError,
                                f"missing or stale: .*{target}.appex/{target}",
                            ):
                                module.verify_xcode_products(
                                    kind, derived, 100, diagnostics
                                )
                        else:
                            self.assertEqual(
                                module.verify_xcode_products(
                                    kind, derived, 100, diagnostics
                                ),
                                sorted(map(str, expected)),
                            )

    def test_unknown_or_unattributed_diagnostics_fail_closed_even_with_a_fresh_app(
        self,
    ):
        for diagnostic in (
            "SwiftCompile normal arm64 (in target 'SpeechKit' from project 'SpeechKit')",
            "SwiftCompile normal arm64",
        ):
            with (
                self.subTest(diagnostic=diagnostic),
                tempfile.TemporaryDirectory() as temporary,
            ):
                derived = Path(temporary)
                app = (
                    derived
                    / "Build/Products/Debug-iphonesimulator/RemoteCoder.app/RemoteCoder"
                )
                app.parent.mkdir(parents=True)
                app.write_bytes(b"fresh-app")
                os.utime(app, (110, 110))
                with self.assertRaisesRegex(ValueError, "target"):
                    module.verify_xcode_products(
                        "ios-build",
                        derived,
                        100,
                        [
                            "SwiftCompile normal arm64 (in target 'RemoteCoder' from project 'RemoteCoder')",
                            diagnostic,
                        ],
                    )


class MacCompilationBoundaryTests(unittest.TestCase):
    def test_a_production_fresh_product_cannot_cover_a_stale_harness_compile(self):
        for modified, expected in ((None, 1), (90, 1), (110, 0)):
            with (
                self.subTest(modified=modified),
                tempfile.TemporaryDirectory() as temporary,
            ):
                derived = Path(temporary)
                product = (
                    derived
                    / "Build/Products/Debug/RemoteCoder.app/Contents/MacOS/RemoteCoder"
                )
                if modified is not None:
                    product.parent.mkdir(parents=True)
                    product.write_bytes(b"production")
                    os.utime(product, (modified, modified))
                stages = derived / "stages.jsonl"

                def compile(command, stdout, **kwargs):
                    stdout.write(WARNING)
                    return subprocess.CompletedProcess(command, 0)

                with (
                    redirect_stdout(io.StringIO()),
                    redirect_stderr(io.StringIO()) as error,
                    patch.object(
                        sys,
                        "argv",
                        [
                            "xcode_build.py",
                            "mac-build",
                            "xcodebuild",
                            "-derivedDataPath",
                            str(derived),
                            "SWIFT_ACTIVE_COMPILATION_CONDITIONS=RC_PERF_HARNESS",
                            "build",
                        ],
                    ),
                    patch.object(module.time, "time", return_value=100),
                    patch.dict(os.environ, {"RC_BUILD_STAGES": str(stages)}),
                    patch.object(module.subprocess, "run", side_effect=compile),
                ):
                    self.assertEqual(module.main(), expected)
                receipt = json.loads(stages.read_text())
                self.assertEqual(receipt["startedAt"], 100)
                self.assertEqual(receipt["exitCode"], expected)
                self.assertEqual(
                    receipt["xcodeExitZeroDiagnostics"],
                    module.xcode_exit_zero_diagnostics(WARNING),
                )
                self.assertEqual(
                    receipt["verifiedProducts"],
                    [str(product)] if expected == 0 else [],
                )
                if expected:
                    self.assertIn("missing or stale", error.getvalue())

    def test_normal_exit_status_remains_authoritative_without_the_diagnostic(self):
        for status, expected in ((0, 0), (65, 65), (-15, 143)):
            with (
                self.subTest(status=status),
                tempfile.TemporaryDirectory() as temporary,
                patch.object(
                    sys,
                    "argv",
                    [
                        "xcode_build.py",
                        "mac-build",
                        "xcodebuild",
                        "-derivedDataPath",
                        temporary,
                        "build",
                    ],
                ),
                patch.object(
                    module.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess([], status),
                ),
                patch.dict(os.environ, {}, clear=True),
                redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(module.main(), expected)

    def test_the_worker_consumes_compile_validation_once_and_retains_other_diagnostics(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            derived = Path(temporary)
            diagnostics = module.xcode_exit_zero_diagnostics(WARNING)
            stage = {
                "stage": "macCompile",
                "exitCode": 0,
                "xcodeExitZeroDiagnostics": diagnostics,
                "verifiedProducts": ["verified-mac-product"],
            }
            for name in ("macCompile", "iosCompile"):
                with self.subTest(stage=name):
                    stage["stage"] = name
                    with patch.object(module, "verify_xcode_products") as verify:
                        self.assertEqual(
                            module.verify_xcode_evidence(
                                "verify", derived, 50, diagnostics, [stage]
                            ),
                            ["verified-mac-product"],
                        )
                        verify.assert_not_called()
                        verify.return_value = ["verified-ios-product"]
                        self.assertEqual(
                            module.verify_xcode_evidence(
                                "verify",
                                derived,
                                50,
                                [*diagnostics, "ios-warning"],
                                [stage],
                            ),
                            ["verified-ios-product", "verified-mac-product"],
                        )
                        verify.assert_called_once_with(
                            "verify", derived, 50, ["ios-warning"]
                        )
                    with self.assertRaisesRegex(ValueError, "compilation failed"):
                        module.verify_xcode_evidence(
                            "verify", derived, 50, [], [stage | {"exitCode": 65}]
                        )
