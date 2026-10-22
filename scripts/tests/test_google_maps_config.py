import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/google-maps-config.py"
TEST_KEY = "test-ios-navigation-key"


class GoogleMapsConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = self.root / "RemoteCoderLocalConfig.json"
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.root)}

    def run_helper(self, *args):
        result = subprocess.run(
            [sys.executable, str(HELPER), *map(str, args)],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertNotIn(TEST_KEY, result.stdout + result.stderr)
        return result

    def write_config(self, key):
        self.config.write_text(
            json.dumps({"googleMapsAPIKey": key, "codexGatewayPort": 8787})
        )

    def test_placeholder_or_invalid_key_blocks_build_without_overwriting_config(self):
        for key in ("required-for-live-navigation", 42):
            with self.subTest(key=key):
                self.write_config(key)
                original = self.config.read_bytes()
                self.assertNotEqual(self.run_helper("sync", self.config).returncode, 0)
                self.assertEqual(self.config.read_bytes(), original)

    def test_no_key_disables_navigation_and_keeps_basic_chat_buildable(self):
        for key in (None, "", "  "):
            self.write_config(key)
            self.assertEqual(self.run_helper("sync", self.config).returncode, 0)
            self.assertEqual(json.loads(self.config.read_text()), {"codexGatewayPort": 8787})
            self.assertEqual(self.run_helper("verify", self.config).returncode, 0)

    def test_sync_preserves_local_settings_and_replaces_key_from_environment(self):
        self.write_config("old-key")
        self.env["REMOTE_CODER_GOOGLE_MAPS_API_KEY"] = TEST_KEY
        self.assertEqual(self.run_helper("sync", self.config).returncode, 0)
        self.assertEqual(
            json.loads(self.config.read_text()),
            {
                "googleMapsAPIKey": TEST_KEY,
                "codexGatewayPort": 8787,
            },
        )
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    def test_sync_accepts_ios_alias_and_retains_it_without_environment(self):
        self.env["GOOGLE_MAPS_IOS_API_KEY"] = TEST_KEY
        self.assertEqual(self.run_helper("sync", self.config).returncode, 0)
        del self.env["GOOGLE_MAPS_IOS_API_KEY"]
        self.assertEqual(self.run_helper("sync", self.config).returncode, 0)
        self.assertEqual(
            json.loads(self.config.read_text())["googleMapsAPIKey"], TEST_KEY
        )

    def test_device_artifact_must_contain_the_expected_key(self):
        self.write_config(TEST_KEY)
        app = self.root / "RemoteCoder.app"
        app.mkdir()
        command = ("verify", self.config, "--app", app)
        self.assertNotEqual(self.run_helper(*command).returncode, 0)
        bundled = app / self.config.name
        bundled.write_text(json.dumps({"googleMapsAPIKey": "wrong-key"}))
        self.assertNotEqual(self.run_helper(*command).returncode, 0)
        shutil.copyfile(self.config, bundled)
        self.assertEqual(self.run_helper(*command).returncode, 0)

    def test_exported_ipa_must_contain_the_expected_key(self):
        self.write_config(TEST_KEY)
        ipa = self.root / "RemoteCoder.ipa"
        for key, expected_status in (("wrong-key", 1), (TEST_KEY, 0)):
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr(
                    f"Payload/RemoteCoder.app/{self.config.name}",
                    json.dumps({"googleMapsAPIKey": key}),
                )
            self.assertEqual(
                self.run_helper("verify", self.config, "--ipa", ipa).returncode,
                expected_status,
            )


if __name__ == "__main__":
    unittest.main()
