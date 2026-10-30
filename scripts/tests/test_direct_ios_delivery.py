import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location(
    "direct_delivery", SCRIPTS / "deliver-ios-app.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DirectDeliveryTests(unittest.TestCase):
    def test_only_an_app_store_connect_build_number_reads_as_testflight(self):
        for build, testflight in (("3073012", True), ("3076006", False), ("1.2.3", False)):
            with self.subTest(build=build):
                self.assertEqual(
                    module.store_build({"short_version": "3.76.6", "version": build}),
                    testflight,
                )

    def test_testflight_refusal_requires_inventory_refreshed_under_the_lease(self):
        real = module.load_coordinator()

        def row(build, seen, managed=True):
            return {
                "id": 98,
                "attributes": {
                    "identifier": "bundle",
                    "managed": managed,
                    "short_version": "3.76.6",
                    "version": build,
                    "last_seen_at": seen,
                },
            }

        testflight = row("3073012", "2026-10-30T01:00:00Z")
        later = "2026-10-30T01:01:00Z"
        for name, observed, outcome in (
            ("advanced while waiting for the lease", [row("3076006", later)], "accepted"),
            ("refreshed to the direct build", [testflight, row("3076006", later)], "accepted"),
            ("still TestFlight", [testflight, row("3073012", later)], "TestFlight build"),
            ("lost management", [testflight, row("3076006", later, managed=False)], "initial SimpleMDM"),
            ("never refreshed", [testflight] * 3, "did not refresh"),
        ):
            with self.subTest(name):
                observations = iter(observed)
                lease = Mock()
                lease.__enter__ = Mock(return_value=lease)
                lease.__exit__ = Mock(return_value=False)
                api = Mock()
                api.request = Mock(side_effect=lambda *_: [next(observations)])
                helper = SimpleNamespace(
                    CatalogLease=Mock(return_value=lease),
                    SimpleMDM=Mock(return_value=api),
                    InventoryRefresh=Mock(return_value=Mock()),
                    resource=real.resource,
                    inventory_time=real.inventory_time,
                    InstallError=real.InstallError,
                )
                clock = iter(range(0, 1000, 50))
                with (
                    patch.object(module, "load_coordinator", return_value=helper),
                    patch.object(
                        module,
                        "time",
                        SimpleNamespace(monotonic=lambda: next(clock), sleep=Mock()),
                    ),
                ):
                    if outcome == "accepted":
                        installed = module.replaceable_install({"id": 27}, {"id": 19}, "bundle")
                        self.assertEqual(installed, observed[-1])
                    else:
                        with self.assertRaisesRegex(module.ManagedAppNotConfigured, outcome):
                            module.replaceable_install({"id": 27}, {"id": 19}, "bundle")

    def test_automatic_managed_target_uses_model_name_not_hardware_product_code(self):
        phone = {
            "id": 27,
            "attributes": {
                "status": "enrolled",
                "name": "Personal phone",
                "model": "MG8J4QN",
                "model_name": "iPhone 17 Pro",
                "unique_identifier": "phone-udid",
            },
        }
        mac = {
            "id": 28,
            "attributes": {
                "status": "enrolled",
                "model": "Mac18,5",
                "model_name": "Mac mini (M6)",
            },
        }
        app = {"id": 98, "attributes": {"identifier": "bundle", "managed": True}}
        with (
            patch.object(module, "mdm_api", side_effect=[[mac, phone], [app]]),
            patch.object(module, "catalog_app", return_value={"id": 19}),
        ):
            device, _, installed = module.mdm_target("", "bundle")
        self.assertEqual(device["id"], 27)
        self.assertEqual(installed["id"], 98)

    def test_coredevice_identity_uses_paired_udid_or_fails_without_fallback(self):
        identifier = "01234567-1234-1234-1234-012345678901"
        with patch.object(
            module.subprocess,
            "run",
            return_value=subprocess.CompletedProcess(
                [], 0, stdout=identifier + "|exact-udid|phone"
            ),
        ) as run:
            self.assertEqual(module.normalize_device(identifier), "exact-udid")
            self.assertIn("identify-device", run.call_args.args[0])
        with (
            patch.object(
                module.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 2, stdout=""),
            ),
            self.assertRaisesRegex(RuntimeError, "requested CoreDevice"),
        ):
            module.normalize_device(identifier)
        self.assertEqual(module.normalize_device("exact-udid"), "exact-udid")

    def test_direct_uses_catalog_coordinator_through_install_and_restores_environment(
        self,
    ):
        artifact = {
            "app": "/app",
            "provenance": "/original/source",
            "settings": "/original/settings",
            "symbols": [{"path": "/symbols"}],
        }
        for catalog in ({"id": 19}, None):
            with self.subTest(catalog=catalog):
                lease = Mock()
                lease.__enter__ = Mock(return_value=lease)
                lease.__exit__ = Mock(return_value=False)
                coordinator = SimpleNamespace(
                    CatalogLease=Mock(return_value=lease),
                    InstallError=type("InstallError", (Exception,), {}),
                )

                def install(arguments, *, delivery_guard):
                    delivery_guard()
                    self.assertEqual(
                        os.environ["RC_BUILD_PROVENANCE"], artifact["provenance"]
                    )
                    self.assertEqual(
                        arguments,
                        ["install", "core-id", "/app", "--symbols", "/symbols"],
                    )
                    print(json.dumps({"installed": True}))

                with (
                    patch.object(module, "CATALOG_COORDINATOR_HOST", "workstation"),
                    patch.object(module, "catalog_app", return_value=catalog),
                    patch.object(module, "load_coordinator", return_value=coordinator),
                    patch.object(
                        module,
                        "load_script",
                        return_value=SimpleNamespace(main=install),
                    ),
                    patch.dict(os.environ, {"RC_BUILD_PROVENANCE": "request-source"}),
                ):
                    self.assertTrue(
                        module.direct_install(
                            artifact, ["core-id", "stable-udid", "name"], "bundle"
                        )["installed"]
                    )
                    self.assertEqual(
                        os.environ["RC_BUILD_PROVENANCE"], "request-source"
                    )
                args = coordinator.CatalogLease.call_args.args
                self.assertEqual(args[0], "workstation")
                self.assertEqual(
                    args[1],
                    "19"
                    if catalog
                    else "direct-"
                    + module.hashlib.sha256(b"bundle\0stable-udid").hexdigest(),
                )
                self.assertEqual(lease.verify.call_count, 3)
                lease.__exit__.assert_called_once()

    def test_catalog_api_failure_cannot_bypass_shared_lock(self):
        with (
            patch.object(
                module, "mdm_api", side_effect=RuntimeError("API unavailable")
            ),
            self.assertRaisesRegex(RuntimeError, "API unavailable"),
        ):
            module.direct_install({}, ["core", "udid", "phone"], "bundle")


class ArtifactDeliveryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        app = self.root / "RemoteCoder.app"
        app.mkdir()
        self.info = {
            "CFBundleIdentifier": "bundle",
            "CFBundleShortVersionString": "0.0.0",
            "CFBundleVersion": "2",
        }
        (app / "Info.plist").write_bytes(plistlib.dumps(self.info))
        self.artifact = {
            "app": str(app),
            "buildId": "original",
            "appSHA256": "a" * 64,
            "source": {
                "buildId": "original",
                "sourceCommit": "commit",
                "sourceFingerprint": "fingerprint",
            },
            "reused": True,
        }
        self.device = {"id": 27, "attributes": {"unique_identifier": "exact-udid"}}
        self.catalog = {"id": 19}
        self.installed = {
            "attributes": {"version": "2", "short_version": "0.0.0", "managed": True}
        }
        actual = {
            "device": "core-id",
            "bundleIdentifier": "bundle",
            "version": "0.0.0",
            "build": "2",
            "installed": True,
            "readBack": True,
            "source": self.artifact["source"],
        }
        self.actual = self.root / "actual-install.json"
        self.actual.write_text(json.dumps(actual))
        self.verified = {
            "installed": True,
            "readBack": True,
            "launched": True,
            "receipt": str(self.actual),
        }
        (self.root / "mdm").mkdir()

    def save_proof(self):
        module.save_direct_proof(
            self.artifact,
            ["core-id", "exact-udid", "phone"],
            self.device,
            self.info,
            self.verified,
        )

    def test_auto_prefers_exact_reachable_enrolled_phone_without_mdm_fallback_on_failure(
        self,
    ):
        for fail in (False, True):
            with (
                self.subTest(fail=fail),
                patch.object(module, "enrolled_device", return_value=self.device),
                patch.object(
                    module,
                    "direct_device",
                    return_value=["core-id", "exact-udid", "phone"],
                ) as probe,
                patch.object(module, "passcode_locked", return_value=False),
                patch.object(
                    module,
                    "direct_install",
                    side_effect=RuntimeError("uncertain install") if fail else None,
                    return_value=self.verified,
                ),
                patch.object(module, "mdm_target") as mdm,
            ):
                receipt = {"phasesSeconds": {}}
                if fail:
                    with self.assertRaisesRegex(RuntimeError, "uncertain install"):
                        module.deliver(self.artifact, "named phone", "auto", receipt)
                else:
                    module.deliver(self.artifact, "named phone", "auto", receipt)
                    self.assertTrue(receipt["installed"])
                    self.assertEqual(receipt["route"], "direct")
                    self.assertEqual(
                        module.direct_proof(self.artifact, self.device, self.info)[
                            "sourceBuildId"
                        ],
                        "original",
                    )
                probe.assert_called_once_with("exact-udid")
                mdm.assert_not_called()

    def test_auto_routes_a_locked_reachable_enrolled_phone_through_mdm(self):
        with (
            patch.object(module, "enrolled_device", return_value=self.device),
            patch.object(
                module,
                "direct_device",
                return_value=["core-id", "exact-udid", "phone"],
            ),
            patch.object(module, "passcode_locked", return_value=True) as locked,
        ):
            enrolled, udid, paired = module.automatic_route("named phone")
        locked.assert_called_once_with("core-id")
        self.assertEqual((enrolled, udid, paired), (self.device, "exact-udid", None))

    def test_auto_rejects_coredevice_discovery_of_another_phone(self):
        with (
            patch.object(module, "enrolled_device", return_value=self.device),
            patch.object(
                module,
                "direct_device",
                return_value=["other-core", "other-udid", "other"],
            ),
            patch.object(module, "direct_install") as install,
            self.assertRaisesRegex(RuntimeError, "different iPhone"),
        ):
            module.deliver(self.artifact, "", "auto", {})
        install.assert_not_called()

    def test_direct_proof_rejects_source_or_device_mismatch_and_actual_receipt_changes(
        self,
    ):
        self.save_proof()
        self.assertIsNotNone(module.direct_proof(self.artifact, self.device, self.info))
        for artifact, device in (
            (self.artifact | {"appSHA256": "b" * 64}, self.device),
            (self.artifact, self.device | {"id": 28}),
            (self.artifact, {"id": 27, "attributes": {"unique_identifier": "other"}}),
        ):
            self.assertIsNone(module.direct_proof(artifact, device, self.info))
        self.actual.write_text("{}")
        self.assertIsNone(module.direct_proof(self.artifact, self.device, self.info))

    def test_away_exact_reuse_uses_direct_proof_without_packaging_or_upload(self):
        self.save_proof()

        def verified(device, catalog, info, proof, receipt):
            receipt.update(installed=True, readBack=True, alreadyInstalled=True)

        with (
            patch.object(module, "enrolled_device", return_value=self.device),
            patch.object(module, "direct_device", return_value=None) as probe,
            patch.object(
                module,
                "mdm_target",
                return_value=(self.device, self.catalog, self.installed),
            ),
            patch.object(
                module, "verify_direct_inventory", side_effect=verified
            ) as fresh,
            patch.object(module, "package_for_mdm") as package,
        ):
            receipt = {"phasesSeconds": {}}
            module.deliver(self.artifact, "", "auto", receipt)
        fresh.assert_called_once()
        package.assert_not_called()
        probe.assert_called_once_with("exact-udid")
        self.assertEqual(receipt["source"]["buildId"], "original")
        self.assertTrue(receipt["alreadyInstalled"])

    def test_repeated_failed_recovery_keeps_previous_accepted_request_proof(self):
        previous = self.root / "mdm/install-receipt.json"
        accepted = {
            "status": "failed",
            "upload_state": "accepted",
            "install_request_state": "accepted",
        }
        previous.write_text(json.dumps(accepted))
        failed = {"status": "failed", "error": "inventory pending"}
        with (
            patch.object(
                module,
                "mdm_target",
                return_value=(self.device, self.catalog, self.installed),
            ),
            patch.object(module, "package_for_mdm", return_value=self.root / "app.ipa"),
            patch.object(
                module.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(
                    [], 1, stdout=json.dumps(failed)
                ),
            ) as run,
        ):
            for _ in range(2):
                receipt = {"phasesSeconds": {}}
                with self.assertRaisesRegex(RuntimeError, "inventory pending"):
                    module.deliver(self.artifact, "exact-udid", "mdm", receipt)
                self.assertEqual(json.loads(previous.read_text()), accepted)
                self.assertEqual(receipt["mdmAttempt"], failed)
                self.assertIn("--previous-receipt", run.call_args.args[0])


class DirectFreshnessTests(unittest.TestCase):
    @unittest.skipUnless((module.CONFIGS / 'skills/simplemdm/scripts/ios-mdm-install').is_file(), 'Operator MDM coordinator is not installed')
    def test_inventory_must_advance_and_pending_or_newer_catalog_cannot_be_ignored(
        self,
    ):
        real = module.load_coordinator()
        for catalog_state in ("older", "release", "newer", "pending", "stale"):
            with self.subTest(catalog_state=catalog_state):
                calls = []
                timestamps = iter(
                    [
                        "2026-10-16T00:00:00Z",
                        "2026-10-16T00:00:00Z",
                        "2026-10-16T00:00:01Z",
                    ]
                )
                lease = Mock()
                lease.__enter__ = Mock(return_value=lease)
                lease.__exit__ = Mock(return_value=False)
                lease.catalog = (
                    {"build": "3044000", "version": "3.44.0"}
                    if catalog_state == "release"
                    else None
                )

                class API:
                    def __init__(self, state, timestamps, calls):
                        self.state = state
                        self.timestamps = timestamps
                        self.calls = calls

                    def request(self, method, endpoint, *arguments):
                        self.calls.append((method, endpoint))
                        if endpoint == "/apps/19":
                            return {
                                "data": {
                                    "id": 19,
                                    "attributes": {
                                        "bundle_identifier": "bundle",
                                        "app_type": "custom",
                                        "processing_status": "processing"
                                        if self.state == "pending"
                                        else "processed",
                                        "version": {
                                            "newer": "3",
                                            "release": "3044000",
                                        }.get(self.state, "1"),
                                    },
                                }
                            }
                        if method == "POST":
                            return None
                        return [
                            {
                                "id": 98,
                                "attributes": {
                                    "identifier": "bundle",
                                    "managed": True,
                                    "version": "2",
                                    "short_version": "0.0.0",
                                    "last_seen_at": next(self.timestamps),
                                },
                            }
                        ]

                api = API(catalog_state, timestamps, calls)
                helper = SimpleNamespace(
                    CatalogLease=Mock(return_value=lease),
                    SimpleMDM=Mock(return_value=api),
                    build_number=real.build_number,
                    catalog_version=real.catalog_version,
                    resource=real.resource,
                    installed_app=real.installed_app,
                    inventory_time=real.inventory_time,
                    InstallError=real.InstallError,
                    wait_interval=Mock(
                        side_effect=real.InstallError(
                            "Timed out waiting for fresh inventory"
                        )
                        if catalog_state == "stale"
                        else None
                    ),
                )
                with patch.object(module, "load_coordinator", return_value=helper):
                    receipt = {}
                    arguments = (
                        {"id": 27},
                        {"id": 19},
                        {
                            "CFBundleIdentifier": "bundle",
                            "CFBundleVersion": "2",
                            "CFBundleShortVersionString": "0.0.0",
                        },
                        {"directReceipt": "/original/direct.json"},
                        receipt,
                    )
                    if catalog_state in ("older", "release"):
                        module.verify_direct_inventory(*arguments)
                        self.assertTrue(receipt["alreadyInstalled"])
                        self.assertEqual(helper.wait_interval.call_count, 1)
                        self.assertEqual(
                            [call for call in calls if call[0] != "GET"],
                            [("POST", "/devices/27/refresh")],
                        )
                        lease.verify.assert_called_once()
                    elif catalog_state == "stale":
                        with self.assertRaisesRegex(
                            RuntimeError, "Timed out waiting for fresh inventory"
                        ):
                            module.verify_direct_inventory(*arguments)
                        self.assertNotIn("alreadyInstalled", receipt)
                    else:
                        with self.assertRaisesRegex(
                            RuntimeError, "pending, or superseded"
                        ):
                            module.verify_direct_inventory(*arguments)
                        self.assertTrue(all(method == "GET" for method, _ in calls))


if __name__ == "__main__":
    unittest.main()
