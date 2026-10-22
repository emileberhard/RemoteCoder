import contextlib
import hashlib
import importlib.util
import os
import plistlib
import subprocess
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location(
    "install_release", SCRIPTS / "install-release.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
DELIVERY = module.load_script("deliver_ios_app", "deliver-ios-app.py")


def bundle(path: Path, version: str, build: str) -> Path:
    (path / "Contents").mkdir(parents=True)
    (path / "Contents/Info.plist").write_bytes(
        plistlib.dumps(
            {"CFBundleShortVersionString": version, "CFBundleVersion": build}
        )
    )
    return path


def build_of(app: Path) -> str:
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"]


class InstallMacTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.release = bundle(
            root / "release/RemoteCoderMac-direct.app", "3.21.0", "3021000"
        )
        self.applications = root / "Applications"
        self.applications.mkdir()
        self.target = self.applications / "RemoteCoder.app"
        real_run = subprocess.run

        # The fixture bundles are unsigned; ditto stays real.
        def run(command, **kwargs):
            if command[0] != "codesign":
                return real_run(command, **kwargs)
            app = Path(command[-1])
            contents = b"".join(
                path.read_bytes() for path in sorted(app.rglob("*")) if path.is_file()
            )
            digest = hashlib.sha256(contents).hexdigest()
            return subprocess.CompletedProcess(command, 0, stderr=f"CDHash={digest}\n")

        self.run = patch.object(module.subprocess, "run", side_effect=run)
        self.run.start()
        self.addCleanup(self.run.stop)

    def test_replaces_an_owned_older_app_and_removes_its_staging(self):
        bundle(self.target, "3.20.0", "3020000")
        with patch.object(module, "running_pids", return_value=[]):
            self.assertEqual(
                module.install_mac_release(self.release, self.target),
                "installed 3.21.0 (3021000)",
            )
        self.assertEqual(build_of(self.target), "3021000")
        self.assertEqual(
            [path.name for path in self.applications.iterdir()], ["RemoteCoder.app"]
        )

    def test_installs_when_no_app_exists(self):
        with patch.object(module, "running_pids", return_value=[]):
            module.install_mac_release(self.release, self.target)
        self.assertEqual(build_of(self.target), "3021000")

    def test_relaunches_only_after_launch_services_releases_the_old_app(self):
        bundle(self.target, "3.20.0", "3020000")
        registrations = iter([True, False])
        opened_before_check = []

        def launch_services_lists(target):
            opened_before_check.append(relaunch.called)
            return next(registrations)

        with (
            patch.object(module, "running_pids", side_effect=[[4242], [], []]),
            patch.object(
                module, "launch_services_lists", side_effect=launch_services_lists
            ),
            patch.object(module.os, "kill") as kill,
            patch.object(module.time, "sleep"),
            patch.object(module, "open_in_login_session") as relaunch,
        ):
            result = module.install_mac_release(self.release, self.target)
        kill.assert_called_once_with(4242, module.signal.SIGTERM)
        self.assertEqual(opened_before_check, [False, False])
        relaunch.assert_called_once_with(self.target)
        self.assertEqual(result, "installed 3.21.0 (3021000) and relaunched it")

    def test_leaves_an_app_with_the_same_release_alone(self):
        bundle(self.target, "3.21.0", "3021000")
        with patch.object(module.os, "getuid", return_value=os.getuid() + 1):
            result = module.install_mac_release(self.release, self.target)
        self.assertTrue(result.startswith("skipped"))

    def test_refuses_an_older_app_owned_by_another_user(self):
        bundle(self.target, "3.20.0", "3020000")
        with (
            patch.object(module.os, "getuid", return_value=os.getuid() + 1),
            self.assertRaisesRegex(RuntimeError, "administrator rights"),
        ):
            module.install_mac_release(self.release, self.target)
        self.assertEqual(build_of(self.target), "3020000")

    def test_restores_the_public_app_over_a_same_version_bench_candidate(self):
        bundle(self.target, "3.21.0", "3021000")
        (self.target / "Contents/bench-config").write_text("development fixture")
        with patch.object(module, "running_pids", return_value=[]):
            result = module.install_mac_release(self.release, self.target)
        self.assertTrue(result.startswith("installed"))
        self.assertFalse((self.target / "Contents/bench-config").exists())

    def test_refuses_to_downgrade_a_newer_installed_app(self):
        bundle(self.target, "3.22.0", "3022000")
        with (
            self.assertRaisesRegex(RuntimeError, "Refusing to downgrade"),
            patch.object(module, "running_pids") as running,
        ):
            module.install_mac_release(self.release, self.target)
        running.assert_not_called()
        self.assertEqual(build_of(self.target), "3022000")

    def test_explicit_development_replacement_accepts_the_actual_zero_marketing_version(
        self,
    ):
        bundle(self.target, "3.34.0", "3034000")
        development = bundle(
            self.applications.parent / "development.app", "0.0.0", "0.2.100"
        )
        with (
            module.mac_target_lease(self.target),
            patch.object(module, "running_pids", return_value=[]),
        ):
            result = module.replace_mac_app(development, self.target)
        self.assertTrue(result.startswith("installed"))
        self.assertEqual(build_of(self.target), "0.2.100")


class InstallIPhoneTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.ipa = Path(temporary.name) / "RemoteCoder-direct.ipa"
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr(
                "Payload/RemoteCoder.app/Info.plist",
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": "com.example.RemoteCoder",
                        "CFBundleShortVersionString": "3.45.0",
                        "CFBundleVersion": "3045000",
                    }
                ),
            )
        self.enrolled = {"id": 7, "attributes": {"unique_identifier": "UDID-1", "name": "Test iPhone"}}
        self.installed = {"attributes": {"short_version": "0.0.0", "version": "1.4.90"}}
        self.paired = None
        for patcher in (
            patch.object(module, "load_script", return_value=DELIVERY),
            patch.object(DELIVERY, "enrolled_device", side_effect=lambda requested: self.enrolled),
            patch.object(DELIVERY, "direct_device", side_effect=lambda udid: self.paired),
            patch.object(
                DELIVERY,
                "mdm_target",
                side_effect=lambda udid, bundle, device: (device, {"id": 11}, self.installed),
            ),
            patch.object(DELIVERY, "direct_install_lease", return_value=contextlib.nullcontext()),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)

    def mdm_results(self, *receipts):
        return patch.object(
            module.subprocess,
            "run",
            side_effect=[
                subprocess.CompletedProcess(
                    [], 0 if receipt["status"] == "installed" else 1, stdout=json.dumps(receipt), stderr=""
                )
                for receipt in receipts
            ],
        )

    def test_a_reachable_enrolled_iphone_installs_directly_under_the_catalog_lease(self):
        self.paired = ["core-1", "UDID-1", "Test iPhone"]
        with (
            patch.object(module, "install_iphone_directly", return_value="installed directly") as direct,
            patch.object(module.subprocess, "run") as run,
        ):
            self.assertEqual(module.install_iphone(self.ipa), "installed directly")
        self.assertEqual(direct.call_args.args[2:], ("core-1", "Test iPhone"))
        DELIVERY.direct_install_lease.assert_called_once_with("com.example.RemoteCoder", "UDID-1")
        run.assert_not_called()

    def test_an_unreachable_iphone_gets_the_release_through_simplemdm(self):
        receipt = {"status": "installed", "installed_build": "3045000"}
        with self.mdm_results(receipt) as run:
            result = module.install_iphone(self.ipa)
        self.assertEqual(result, "installed 3.45.0 (3045000) on Test iPhone through SimpleMDM")
        command = run.call_args.args[0]
        self.assertEqual(command[1:6], [str(self.ipa), "--device-id", "7", "--app-id", "11"])
        self.assertIn("--replace-version", command)
        saved = json.loads((self.ipa.parent / "mdm-install-receipt.json").read_text())
        self.assertEqual(saved, receipt)

    def test_an_accepted_request_the_iphone_has_not_confirmed_is_pending_not_failed(self):
        accepted = {
            "status": "failed",
            "upload_state": "accepted",
            "install_request_state": "accepted",
            "error": "Timed out waiting for managed installation",
        }
        installed = {"status": "installed", "installed_build": "3045000"}
        with self.mdm_results(accepted, installed) as run:
            self.assertEqual(
                module.install_iphone(self.ipa),
                "requested 3.45.0 (3045000) on Test iPhone through SimpleMDM; the iPhone has not confirmed it yet",
            )
            self.assertFalse((self.ipa.parent / "iphone-install.txt").exists())
            module.install_iphone(self.ipa)
        self.assertIn("--previous-receipt", run.call_args.args[0])
        self.assertTrue((self.ipa.parent / "iphone-install.txt").exists())

    def test_a_failure_before_upload_leaves_no_receipt_that_would_block_the_retry(self):
        failed = {
            "status": "failed",
            "upload_state": "not_started",
            "install_request_state": "not_started",
            "error": "SimpleMDM unavailable",
        }
        installed = {"status": "installed", "installed_build": "3045000"}
        with self.mdm_results(failed, installed) as run:
            with self.assertRaisesRegex(RuntimeError, "SimpleMDM unavailable"):
                module.install_iphone(self.ipa)
            self.assertFalse((self.ipa.parent / "mdm-install-receipt.json").exists())
            module.install_iphone(self.ipa)
        self.assertNotIn("--previous-receipt", run.call_args.args[0])

    def test_a_rerun_after_a_completed_install_does_not_deliver_again(self):
        self.paired = ["core-1", "UDID-1", "Test iPhone"]
        with patch.object(
            module, "install_iphone_directly", return_value="installed 3.45.0 (3045000) on Test iPhone directly"
        ) as direct:
            module.install_iphone(self.ipa)
            self.assertEqual(
                module.install_iphone(self.ipa),
                "skipped, an earlier attempt installed 3.45.0 (3045000) on Test iPhone directly",
            )
        direct.assert_called_once()

    def test_an_unreachable_unmanaged_iphone_fails_instead_of_skipping(self):
        def unmanaged(*_arguments, **_keywords):
            raise DELIVERY.ManagedAppNotConfigured("No matching enrolled iPhone")

        DELIVERY.enrolled_device.side_effect = unmanaged
        DELIVERY.mdm_target.side_effect = unmanaged
        with self.assertRaisesRegex(RuntimeError, "no reachable iPhone, and managed delivery is unavailable"):
            module.install_iphone(self.ipa)


if __name__ == "__main__":
    unittest.main()
