import hashlib
import importlib.util
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location(
    "mdm_package", SCRIPTS / "deliver-ios-app.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ManagedPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "RemoteCoder.app"
        self.app.mkdir()
        self.original_config = json.dumps(
            {
                "macMiniHostname": "test-host",
                "codexGatewayAuthToken": "private-test-token",
            }
        ).encode()
        (self.app / "RemoteCoderLocalConfig.json").write_bytes(self.original_config)
        (self.app / "Info.plist").write_bytes(
            plistlib.dumps({"RemoteCoderAPNSEnvironment": "development"})
        )
        self.artifact = {
            "app": str(self.app),
            "buildId": "original-build",
            "appSHA256": "original-app-hash",
        }

    def package_process(self, command, **_kwargs):
        staged = Path(command[command.index("--app") + 1])
        output = Path(command[command.index("--output") + 1])
        self.assertEqual(
            json.loads((staged / "RemoteCoderLocalConfig.json").read_bytes()),
            {"macMiniHostname": "test-host"},
        )
        self.assertEqual(
            plistlib.loads((staged / "Info.plist").read_bytes())[
                "RemoteCoderAPNSEnvironment"
            ],
            "production",
        )
        output.write_bytes(b"signed-ipa-fixture")
        return subprocess.CompletedProcess(
            command,
            0,
            stdout=json.dumps(
                {"sha256": hashlib.sha256(output.read_bytes()).hexdigest()}
            ),
        )

    def package(self):
        with (
            patch.object(module.subprocess, "run", side_effect=self.package_process),
            patch.object(module, "verify_public_ipa"),
        ):
            return module.package_for_mdm(self.artifact, "device-udid")

    def test_sanitized_copy_preserves_original_and_cached_payload_is_bound(self):
        output = self.package()
        self.assertEqual(
            (self.app / "RemoteCoderLocalConfig.json").read_bytes(),
            self.original_config,
        )
        self.assertEqual(
            plistlib.loads((self.app / "Info.plist").read_bytes())[
                "RemoteCoderAPNSEnvironment"
            ],
            "development",
        )
        with (
            patch.object(module.subprocess, "run") as run,
            patch.object(module, "verify_public_ipa") as verify,
        ):
            self.assertEqual(
                module.package_for_mdm(self.artifact, "device-udid"), output
            )
            run.assert_not_called()
            verify.assert_called_once_with(output)
            for artifact, udid in (
                (self.artifact, "other-device"),
                (self.artifact | {"buildId": "other-build"}, "device-udid"),
                (self.artifact | {"appSHA256": "changed"}, "device-udid"),
            ):
                with self.assertRaisesRegex(RuntimeError, "does not match"):
                    module.package_for_mdm(artifact, udid)
            output.write_bytes(b"tampered")
            with self.assertRaisesRegex(RuntimeError, "does not match"):
                module.package_for_mdm(self.artifact, "device-udid")

    def test_failed_distribution_check_never_publishes_cached_package(self):
        with (
            patch.object(module.subprocess, "run", side_effect=self.package_process),
            patch.object(
                module,
                "verify_public_ipa",
                side_effect=RuntimeError("private configuration"),
            ),
            self.assertRaisesRegex(RuntimeError, "private configuration"),
        ):
            module.package_for_mdm(self.artifact, "device-udid")
        output = self.app.parent / "mdm" / "RemoteCoder.ipa"
        self.assertFalse(output.exists())
        self.assertFalse(output.with_name("package-receipt.json").exists())
        self.assertEqual(
            (self.app / "RemoteCoderLocalConfig.json").read_bytes(),
            self.original_config,
        )


if __name__ == "__main__":
    unittest.main()
