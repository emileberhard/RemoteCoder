import contextlib
import importlib.util
import io
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
spec = importlib.util.spec_from_file_location(
    "ios_device_artifact",
    Path(__file__).resolve().parents[1] / "ios-device-artifact.py",
)
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


class DeviceArtifactTests(unittest.TestCase):
    def test_expired_profile_rejects_a_signed_candidate_before_certificate_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "RemoteCoder.app"
            app.mkdir()
            (app / "embedded.mobileprovision").write_bytes(b"signed profile fixture")
            content = b'<?xml version="1.0"?><plist version="1.0"><dict><key>ExpirationDate</key><date>2000-01-01T00:00:00Z</date></dict></plist>'
            with (
                patch.object(artifact.subprocess, "check_output", return_value=content),
                self.assertRaisesRegex(ValueError, "profile expired"),
            ):
                artifact.verify_profiles(app)

    def test_retention_keeps_current_previous_and_unowned_or_linked_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            completed = []
            for number in range(4):
                path = artifacts / (str(number) * 32)
                path.mkdir()
                (path / "RemoteCoder.app").mkdir()
                (path / "symbols").mkdir()
                (path / "source.json").write_text("{}")
                (path / "build-settings.json").write_text("{}")
                descriptor = path / "artifact.json"
                descriptor.write_text(
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "buildId": path.name,
                            "app": str(path / "RemoteCoder.app"),
                            "provenance": str(path / "source.json"),
                            "appSHA256": "a" * 64,
                        }
                    )
                )
                managed = path / "mdm"
                managed.mkdir()
                (managed / "RemoteCoder.ipa").write_bytes(b"owned package")
                (managed / "package-receipt.json").write_text(
                    json.dumps(
                        {
                            "sourceBuildId": path.name,
                            "sourceAppSHA256": "a" * 64,
                            "transformationVersion": 1,
                            "sha256": "b" * 64,
                        }
                    )
                )
                (path / "direct-install-receipt.json").write_text(
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "sourceBuildId": path.name,
                            "sourceAppSHA256": "a" * 64,
                            "deviceUDID": "phone-udid",
                            "deviceId": 27,
                            "bundleIdentifier": "bundle",
                            "version": "0.0.0",
                            "build": "2",
                            "directReceipt": "/original/receipt.json",
                            "directReceiptSHA256": "c" * 64,
                        }
                    )
                )
                (managed / "install-receipt.json").write_text('{"status":"installed"}')
                os.utime(descriptor, (100 + number, 100 + number))
                completed.append(path)
            unknown = artifacts / ("a" * 32)
            unknown.mkdir()
            (unknown / "unrelated-user-file").write_text("preserve")
            outside = root / "outside"
            outside.mkdir()
            linked = artifacts / ("b" * 32)
            linked.symlink_to(outside, target_is_directory=True)
            incomplete = artifacts / ("c" * 32)
            shutil.copytree(completed[0], incomplete)
            descriptor = json.loads((incomplete / "artifact.json").read_text())
            descriptor.update(
                buildId=incomplete.name,
                app=str(incomplete / "RemoteCoder.app"),
                provenance=str(incomplete / "source.json"),
            )
            (incomplete / "artifact.json").write_text(json.dumps(descriptor))
            package = json.loads((incomplete / "mdm/package-receipt.json").read_text())
            package["sourceBuildId"] = incomplete.name
            (incomplete / "mdm/package-receipt.json").write_text(json.dumps(package))
            (incomplete / "mdm/packaging.tmp").write_text("unfinished; preserve")
            artifact.retire_artifacts(artifacts, completed[-1])
            self.assertFalse(completed[0].exists())
            self.assertFalse(completed[1].exists())
            self.assertTrue(completed[2].exists())
            self.assertTrue(completed[3].exists())
            self.assertTrue((unknown / "unrelated-user-file").exists())
            self.assertTrue(linked.is_symlink())
            self.assertTrue(outside.exists())
            self.assertTrue((incomplete / "mdm/packaging.tmp").exists())

    def test_published_product_survives_mutable_build_and_reuse_keeps_identity(self):
        with (
            tempfile.TemporaryDirectory() as temporary,
            contextlib.ExitStack() as stack,
        ):
            root = Path(temporary)
            app = root / "products/RemoteCoder.app"
            app.mkdir(parents=True)
            (app / "resource.txt").write_text("original")
            source = {
                "buildId": "0" * 32,
                "sourceCommit": "abc",
                "sourceFingerprint": "source",
                "sourceModified": True,
            }
            candidate = source | {
                "optimized": True,
                "compilationMode": "singlefile",
                "buildNumber": "1.0.1",
            }
            settings = {
                "identity": candidate,
                "settings": {
                    "SWIFT_OPTIMIZATION_LEVEL": "-O",
                    "SWIFT_COMPILATION_MODE": "singlefile",
                    "PRODUCT_BUNDLE_IDENTIFIER": "com.example.RemoteCoder",
                },
            }
            info = {
                "CFBundleIdentifier": "com.example.RemoteCoder",
                "CFBundleVersion": "1.0.1",
                "RemoteCoderBuildID": "0" * 32,
                "RemoteCoderSourceCommit": "abc",
                "RemoteCoderSourceFingerprint": "source",
                "RemoteCoderSourceModified": "true",
                "RemoteCoderBuildOptimization": "-O",
            }
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            provenance = root / "source.json"
            provenance.write_text(json.dumps(source))
            evidence = root / "settings.json"
            evidence.write_text(json.dumps(settings))
            config = root / "RemoteCoder/Resources/RemoteCoderLocalConfig.json"
            config.parent.mkdir(parents=True)
            config.write_text('{"maps":"first"}')
            previous = Path.cwd()
            os.chdir(root)
            stack.callback(os.chdir, previous)
            stack.enter_context(patch.object(Path, "home", return_value=root))
            stack.enter_context(
                patch.dict(
                    os.environ,
                    {
                        "RC_BUILD_PROVENANCE": str(provenance),
                        "RC_DERIVED_DATA": str(root / "derived"),
                        "DEVELOPER_DIR": "/fixture/Xcode",
                        "RC_INSTALL_SOURCE_LEASED": "1",
                    },
                )
            )
            stack.enter_context(patch.object(artifact, "verify_profiles"))
            stack.enter_context(
                patch.object(
                    artifact.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess([], 0),
                )
            )
            stack.enter_context(
                patch.object(
                    artifact.subprocess,
                    "check_output",
                    return_value="fixture toolchain",
                )
            )

            def retain(_app, _products, destination):
                destination.mkdir()
                (destination / "code.dSYM").write_bytes(b"symbols")

            stack.enter_context(
                patch.object(artifact.installer, "retain_symbols", side_effect=retain)
            )

            def command(*arguments):
                output = io.StringIO()
                with (
                    patch.object(sys, "argv", ["artifact", *arguments]),
                    contextlib.redirect_stdout(output),
                ):
                    artifact.main()
                return output.getvalue().strip()

            with self.assertRaisesRegex(ValueError, "optimization mode"):
                command(
                    "publish",
                    "--optimized",
                    "--app",
                    str(app),
                    "--settings",
                    str(evidence),
                )
            published = Path(
                command("publish", "--app", str(app), "--settings", str(evidence))
            )
            original = json.loads(published.read_text())
            (app / "resource.txt").write_text("later build")
            source["buildId"] = "f" * 32
            provenance.write_text(json.dumps(source))
            reused = json.loads(Path(command("reuse")).read_text())
            self.assertEqual(reused["buildId"], "0" * 32)
            self.assertEqual(reused["requestBuildId"], "f" * 32)
            self.assertTrue(reused["reused"])
            self.assertEqual(
                (Path(reused["app"]) / "resource.txt").read_text(), "original"
            )
            self.assertEqual(
                json.loads(Path(reused["provenance"]).read_text())["buildId"],
                "0" * 32,
            )

            for kind in ("source", "toolchain", "mode", "compilation", "signing"):
                with self.subTest(mismatch=kind), contextlib.ExitStack() as mismatch:
                    arguments = ["reuse"]
                    if kind == "source":
                        provenance.write_text(
                            json.dumps(source | {"sourceFingerprint": "changed"})
                        )
                        mismatch.callback(provenance.write_text, json.dumps(source))
                    elif kind == "toolchain":
                        mismatch.enter_context(
                            patch.dict(
                                os.environ, {"DEVELOPER_DIR": "/different/Xcode"}
                            )
                        )
                    elif kind == "mode":
                        arguments.append("--unoptimized")
                    elif kind == "compilation":
                        arguments.append("--optimized")
                    else:
                        profile = (
                            root
                            / "Library/MobileDevice/Provisioning Profiles/explicit.mobileprovision"
                        )
                        profile.parent.mkdir(parents=True)
                        profile.write_bytes(b"new installed signing profile")
                        mismatch.callback(profile.unlink)
                    with self.assertRaises(SystemExit) as missed:
                        command(*arguments)
                    self.assertEqual(missed.exception.code, 3)
            settings_path = Path(original["settings"])
            saved_settings = settings_path.read_text()
            settings_path.write_text(
                json.dumps(
                    settings | {"identity": candidate | {"buildNumber": "changed"}}
                )
            )
            with self.assertRaises(SystemExit) as stale_settings:
                command("reuse")
            self.assertEqual(stale_settings.exception.code, 3)
            settings_path.write_text(saved_settings)

            # A changed private configuration is an input miss even with identical tracked source.
            config.write_text('{"maps":"changed"}')
            with self.assertRaises(SystemExit) as missed:
                command("reuse")
            self.assertEqual(missed.exception.code, 3)
            config.write_text('{"maps":"first"}')
            # Resources are part of artifact identity, not merely the main executable.
            (Path(original["app"]) / "resource.txt").write_text("corrupted")
            with self.assertRaises(SystemExit) as corrupted:
                command("reuse")
            self.assertEqual(corrupted.exception.code, 3)


if __name__ == "__main__":
    unittest.main()
