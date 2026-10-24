import contextlib
import fcntl
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import types
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
bench_lab = importlib.import_module("bench_lab")


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


module = load("release_cache", SCRIPTS / "release-cache.py")
install_mac = load("install_mac", SCRIPTS / "install-mac")


class PreparedRuntimePackageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "build-package"
        self.source.mkdir()
        (self.source / "NOTICE").write_text("upstream attribution")
        self.releases = self.root / "releases"
        self.release = self.releases / "3.65.0"
        self.release.mkdir(parents=True)
        (self.release / "commit").write_text("a" * 40)
        compatibility = self.root / "docs/codex/compatibility.json"
        compatibility.parent.mkdir(parents=True)
        compatibility.write_text(json.dumps({"runtimePackageSHA256": module.tree_digest(self.source)}))
        self.enterContext(patch.object(module, "ROOT", self.root))
        self.enterContext(patch.object(module, "RELEASES", self.releases))
        self.enterContext(patch.object(module, "cache_root", return_value=self.root / "cache"))
        self.resolve = self.enterContext(patch.object(module.subprocess, "check_output", return_value=str(self.source)))
        self.enterContext(patch.object(module.subprocess, "run"))

    def test_release_retains_exact_bytes_after_build_cache_retirement(self):
        retained = module.prepare_package("3.65.0")
        shutil.rmtree(self.source)
        self.assertEqual(module.prepare_package("3.65.0"), retained)
        self.assertEqual((retained / "NOTICE").read_text(), "upstream attribution")
        self.resolve.assert_called_once()

    def test_changed_retained_resources_are_rejected(self):
        retained = module.prepare_package("3.65.0")
        (retained / "NOTICE").write_text("different attribution")
        with self.assertRaisesRegex(ValueError, "differs from its approved fingerprint"):
            module.prepare_package("3.65.0")


class PublishedMacReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.releases = self.root / "releases"
        self.releases.mkdir()
        self.enterContext(patch.object(module, "TEAM", "EXAMPLETEAM"))
        self.enterContext(patch.object(module, "APP_IDENTIFIER", "com.example.RemoteCoder"))
        self.app = self.release("3.34.0")
        self.run = self.root / "run"
        self.run.mkdir()
        self.enterContext(patch.object(module, "RELEASES", self.releases))
        self.enterContext(patch.object(install_mac, "load", return_value=module))
        self.enterContext(
            patch.object(
                install_mac, "TARGET", self.root / "Applications/RemoteCoder.app"
            )
        )
        self.codesign = self.enterContext(
            patch.object(module.subprocess, "run", side_effect=self.signing_result)
        )

    def release(self, version):
        directory = self.releases / version
        app = directory / "RemoteCoderMac-direct.app"
        (app / "Contents/Resources").mkdir(parents=True)
        (directory / "commit").write_text("a" * 40)
        (directory / "RemoteCoderMac.pkg").touch()
        major, minor, patch_number = map(int, version.split("."))
        (app / "Contents/Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "com.example.RemoteCoder",
                    "CFBundleShortVersionString": version,
                    "CFBundleVersion": str(
                        major * 1000000 + minor * 1000 + patch_number
                    ),
                    "RemoteCoderSourceCommit": "a" * 40,
                    "RemoteCoderSourceModified": "false",
                }
            )
        )
        (app / module.CONFIG).write_text(
            json.dumps({"macBookHostname": "fixture-book"})
        )
        (app / "Contents/embedded.provisionprofile").write_bytes(b"fixture profile")
        return app

    def signing_result(self, command, **kwargs):
        return subprocess.CompletedProcess(
            command,
            0,
            stderr=(
                "Authority=Developer ID Application: Fixture\nTeamIdentifier=EXAMPLETEAM\nCDHash=abc123\n"
            ),
        )

    def test_selects_the_latest_complete_publication_and_holds_its_reader_lease(self):
        newer = self.release("3.35.0")
        (newer.parent / "RemoteCoderMac.pkg").unlink()
        with module.reference() as reference:
            self.assertEqual(reference["version"], "3.34.0")
            self.assertEqual(reference["commit"], "a" * 40)
            with (
                (self.releases.parent / "release-reference.lock").open("a") as other,
                self.assertRaises(BlockingIOError),
            ):
                fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_copies_signing_inputs_without_reading_the_installed_bench_app(self):
        installed = install_mac.TARGET
        (installed / "Contents/Resources").mkdir(parents=True)
        (installed / module.CONFIG).write_text(
            json.dumps({"codexGatewayAuthToken": "fixture-token"})
        )
        entitlements = plistlib.dumps({"fixture.entitlement": True})
        with patch.object(
            install_mac.subprocess, "check_output", return_value=entitlements
        ):
            release = install_mac.published_release(self.run)
        (self.app / "Contents/embedded.provisionprofile").unlink()
        self.assertEqual(release.profile.read_bytes(), b"fixture profile")
        self.assertEqual(
            plistlib.loads(release.entitlements.read_bytes()),
            {"fixture.entitlement": True},
        )
        self.assertEqual(
            json.loads(release.config.read_text()), {"macBookHostname": "fixture-book"}
        )
        self.assertEqual(
            json.loads((self.run / "release-reference.json").read_text())["version"],
            "3.34.0",
        )

    def test_refuses_private_fields_in_a_published_reference(self):
        (self.app / module.CONFIG).write_text(
            json.dumps({"codexGatewayAuthToken": "fixture-token"})
        )
        with (
            self.assertRaisesRegex(
                ValueError, "non-public fields: codexGatewayAuthToken"
            ),
            module.reference(),
        ):
            self.fail("accepted development configuration")

    def test_refuses_a_mismatched_commit_instead_of_falling_back_to_an_older_release(
        self,
    ):
        self.release("3.33.0")
        (self.app.parent / "commit").write_text("b" * 40)
        with (
            self.assertRaisesRegex(ValueError, "RemoteCoderSourceCommit"),
            module.reference(),
        ):
            self.fail("accepted a mismatched release")

    def test_missing_app_in_a_marked_publication_does_not_select_an_older_release(self):
        newer = self.release("3.35.0")
        newer.rename(newer.with_name("moved.app"))
        with self.assertRaises(FileNotFoundError), module.reference():
            self.fail("fell back from a corrupt marked publication")

    def test_propagates_signature_verification_failure(self):
        self.codesign.side_effect = subprocess.CalledProcessError(1, ["codesign"])
        with self.assertRaises(subprocess.CalledProcessError), module.reference():
            self.fail("accepted a failed signature")

    def test_missing_publication_names_the_release_pipeline(self):
        (self.app.parent / "RemoteCoderMac.pkg").unlink()
        with (
            self.assertRaisesRegex(ValueError, "complete the release pipeline"),
            module.reference(),
        ):
            self.fail("accepted an incomplete publication")

    def test_pruning_keeps_three_versions_and_recently_used_releases(self):
        for version in ("3.30.0", "3.31.0", "3.32.0", "3.33.0"):
            self.release(version)
        old = time.time() - 49 * 3600
        for directory in self.releases.iterdir():
            os.utime(directory, (old, old))
        (self.releases / "3.31.0").touch()
        self.assertEqual(module.prune(), {"removed": ["3.30.0"]})
        self.assertEqual(
            sorted(path.name for path in self.releases.iterdir()),
            [
                "3.31.0",
                "3.32.0",
                "3.33.0",
                "3.34.0",
            ],
        )


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


class ReleasePublicationTests(unittest.TestCase):
    commit = "c" * 40

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.copied = []
        self.enterContext(patch.object(module.subprocess, "run", side_effect=self.transport))

    def on(self, host):
        home = self.root / host
        stack = contextlib.ExitStack()
        stack.enter_context(patch.object(module, "RELEASES", home / module.RELEASES_IN_HOME))
        stack.enter_context(patch.object(module, "DEPLOYMENTS", home / "Library/Logs/remote-coder/deployments"))
        stack.enter_context(patch("build_artifacts.Path.home", return_value=home))
        return stack

    def transport(self, command, **kwargs):
        if command[0] == "ssh":
            record = self.root / "mini" / module.RELEASES_IN_HOME / "published.json"
            return subprocess.CompletedProcess(command, 0, record.read_text() if record.exists() else "", "")
        self.assertEqual(command[:2], ["rsync", "-a"])
        source, destination = command[2].removeprefix("mini:"), command[3]
        self.copied.append(source.rstrip("/"))
        if source.endswith("/"):
            shutil.copytree(source, destination, symlinks=True)
        else:
            shutil.copy2(source, destination)
        return subprocess.CompletedProcess(command, 0, "", "")

    def publish_on_mini(self, version):
        with self.on("mini"):
            directory = module.admit(version, self.commit)
            gateway = directory / module.gateway_bundle.NAME
            write(gateway / "Contents/MacOS/gateway", f"gateway {version}".encode())
            package = self.root / "mini/.codex/packages/standalone/releases/0.1.0"
            write(package / "bin/codex", b"codex")
            write(package / "codex-package.json", b"{}")
            module.publish(version, gateway, package)
            write(directory / module.MAC_APP / "Contents/Info.plist", f"app {version}".encode())
            write(directory / module.MAC_PACKAGE, f"pkg {version}".encode())
            write(module.symbol_directory("mac", version) / "symbols/RemoteCoder.app.dSYM/Contents/Info.plist", b"dsym")
            return module.attach(version, "mac")

    def catch_up(self, installed):
        with self.on("book"), patch.object(module, "installed", return_value=installed):
            return module.catch_up("mini")

    def test_republication_keeps_attachments_and_an_older_release_cannot_replace_it(self):
        attached = self.publish_on_mini("3.45.0")
        with self.on("mini"):
            gateway = module.RELEASES / "3.45.0" / module.gateway_bundle.NAME
            package = Path(attached["artifacts"]["codex-package"]["path"])
            republished = module.publish("3.45.0", gateway, package)
            self.assertEqual(republished["artifacts"], attached["artifacts"])
            older = module.admit("3.44.0", self.commit)
            write(older / module.MAC_APP / "Contents/Info.plist", b"app 3.44.0")
            write(older / module.MAC_PACKAGE, b"pkg 3.44.0")
            with self.assertRaisesRegex(ValueError, "3.45.0 is already published"):
                module.publish("3.44.0", gateway, package)
            with self.assertRaisesRegex(ValueError, "3.44.0 is not the published release"):
                module.attach("3.44.0", "mac")
            self.assertEqual(module.read_published()["version"], "3.45.0")

    def test_catch_up_mirrors_the_published_release_with_verified_fingerprints(self):
        record = self.publish_on_mini("3.45.0")
        plan = self.catch_up({"gateway": "3.44.1", "app": "development"})
        directory = Path(plan["releaseDir"])
        self.assertEqual((plan["version"], plan["commit"]), ("3.45.0", self.commit))
        self.assertEqual((plan["gateway"], plan["app"]), ("deliver", "deliver"))
        self.assertEqual(plan["codexPackage"], str(directory / "codex-package"))
        with self.on("book"):
            copies = {
                "gateway": Path(plan["gatewayBundle"]),
                "codex-package": directory / "codex-package",
                "mac-app": directory / module.MAC_APP,
                "mac-package": directory / module.MAC_PACKAGE,
                "mac-symbols": module.symbol_directory("mac", "3.45.0"),
            }
            for name, copy in copies.items():
                self.assertEqual(module.fingerprint(copy), record["artifacts"][name]["fingerprint"], name)
            self.assertEqual((directory / "commit").read_text().strip(), self.commit)

    def test_catch_up_snapshots_the_installed_package_despite_the_installer_link(self):
        record = self.publish_on_mini("3.45.0")
        standalone = self.root / "book/.codex/packages/standalone"
        shutil.copytree(self.root / "mini/.codex/packages/standalone/releases/0.1.0", standalone / "releases/0.1.0", symlinks=True)
        (standalone / "releases/0.1.0/codex").symlink_to("bin/codex")
        (standalone / "current").symlink_to("releases/0.1.0")
        plan = self.catch_up({"gateway": "3.44.1", "app": "3.44.1"})
        package = Path(plan["releaseDir"]) / "codex-package"
        self.assertEqual(plan["codexPackage"], str(package))
        self.assertEqual(module.fingerprint(package), record["artifacts"]["codex-package"]["fingerprint"])
        self.assertNotIn(record["artifacts"]["codex-package"]["path"], self.copied)

    def test_settled_release_keeps_later_development_builds_and_never_downgrades(self):
        self.publish_on_mini("3.45.0")
        self.catch_up({"gateway": "3.44.1", "app": "3.44.1"})
        copied = len(self.copied)
        with self.on("book"), patch.object(module, "installed", return_value={"gateway": "3.45.0", "app": "3.45.0"}):
            self.assertEqual(module.settle("3.45.0"), ["app", "gateway"])
        plan = self.catch_up({"gateway": "development", "app": "development"})
        self.assertEqual((plan["gateway"], plan["app"], plan["codexPackage"]), ("keep", "keep", None))
        plan = self.catch_up({"gateway": "3.46.0", "app": "3.45.0"})
        self.assertEqual((plan["gateway"], plan["app"]), ("newer", "current"))
        self.assertEqual(len(self.copied), copied)

    def test_a_changed_artifact_is_rejected_before_the_mac_publication_is_complete(self):
        self.publish_on_mini("3.45.0")
        write(self.root / "mini" / module.RELEASES_IN_HOME / "3.45.0" / module.MAC_APP / "Contents/Info.plist", b"changed")
        with self.assertRaisesRegex(ValueError, "mac-app from mini does not match its published fingerprint"):
            self.catch_up({"gateway": "3.44.1", "app": "3.44.1"})
        directory = self.root / "book" / module.RELEASES_IN_HOME / "3.45.0"
        self.assertEqual(
            {path.name for path in directory.iterdir()}, {"commit", module.gateway_bundle.NAME}
        )

    def test_failed_newer_admissions_keep_the_published_release_for_catch_up(self):
        self.publish_on_mini("3.45.0")
        with self.on("mini"):
            old = time.time() - 49 * 3600
            for version in ("3.46.0", "3.47.0", "3.48.0"):
                os.utime(module.admit(version, self.commit), (old, old))
            os.utime(module.RELEASES / "3.45.0", (old, old))
            for index in range(module.RETAINED_RELEASE_SYMBOLS):
                newer = module.symbol_directory("ios", f"3.46.{index}")
                newer.mkdir(parents=True)
            os.utime(module.symbol_directory("mac", "3.45.0"), (1, 1))
            module.admit("3.49.0", self.commit)
            module.prune_symbols()
            self.assertTrue((module.RELEASES / "3.45.0" / module.gateway_bundle.NAME).is_dir())
            self.assertTrue(module.symbol_directory("mac", "3.45.0").is_dir())
        plan = self.catch_up({"gateway": "3.44.1", "app": "3.44.1"})
        self.assertEqual((plan["version"], plan["gateway"], plan["app"]), ("3.45.0", "deliver", "deliver"))

    def test_nothing_published_plans_nothing(self):
        self.assertEqual(self.catch_up({"gateway": "3.44.1", "app": "3.44.1"}), {"version": None})

    def test_symbol_retention_keeps_the_newest_ten_release_archives(self):
        with self.on("mini"):
            for index in range(10):
                old = module.symbol_directory("ios", f"3.40.{index}")
                old.mkdir(parents=True)
                os.utime(old, (1_000 + index, 1_000 + index))
            unrelated = module.DEPLOYMENTS / ("ios-" + "1" * 32)
            unrelated.mkdir()
            os.utime(unrelated, (1, 1))
            archive = self.root / "RemoteCoder.xcarchive"
            write(archive / "dSYMs/RemoteCoder.app.dSYM/Contents/Info.plist", b"dsym")
            result = module.retain_symbols("mac", "3.45.0", archive)
            self.assertEqual(result["removed"], ["testflight-ios-3.40.0-3040000"])
            self.assertTrue((module.symbol_directory("mac", "3.45.0") / "symbols/RemoteCoder.app.dSYM").is_dir())
            self.assertTrue(unrelated.is_dir())

    def test_tag_admission_requires_the_highest_peeled_release_tag_on_a_clean_checkout(self):
        tags = "\n".join([
            f"{'1' * 40}\trefs/tags/3.45.0",
            f"{self.commit}\trefs/tags/3.45.0^{{}}",
            f"{'2' * 40}\trefs/tags/3.44.9",
            f"{'3' * 40}\trefs/tags/pre-rebase-native",
        ])
        outputs = {"ls-remote": tags, "rev-parse": self.commit + "\n", "status": ""}
        with self.on("mini"), patch.object(module, "require_main_ancestor"), patch.object(module, "git", side_effect=lambda command, *_: outputs[command]):
            self.assertEqual(module.admit_tag("3.45.0", self.commit).name, "3.45.0")
            with self.assertRaisesRegex(ValueError, "3.45.0 is newer than 3.44.9"):
                module.admit_tag("3.44.9", "2" * 40)
            outputs["status"] = " M scripts/release-cache.py\n"
            with self.assertRaisesRegex(ValueError, "not clean"):
                module.admit_tag("3.45.0", self.commit)


class OptimizedMacCompilationTests(unittest.TestCase):
    def test_install_and_bench_compiles_keep_normal_xcode_output(self):
        for bench in (False, True):
            with self.subTest(bench=bench), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                settings = json.dumps(
                    [
                        {
                            "target": "RemoteCoderMac",
                            "buildSettings": {
                                "TARGET_BUILD_DIR": str(root),
                                "FULL_PRODUCT_NAME": "RemoteCoder.app",
                            },
                        }
                    ]
                )
                commands = []

                def sdk(command, _commands=commands, **kwargs):
                    _commands.append(command)
                    if command[:3] == [
                        "python3",
                        "scripts/device-build-identity.py",
                        "verify",
                    ]:
                        Path(command[5]).write_text("{}")
                    return subprocess.CompletedProcess(command, 0)

                with (
                    patch.dict(os.environ, {"RC_DERIVED_DATA": str(root / "derived")}),
                    patch.object(
                        install_mac.subprocess,
                        "check_output",
                        side_effect=["", settings],
                    ),
                    patch.object(install_mac.subprocess, "run", side_effect=sdk),
                ):
                    self.assertEqual(
                        install_mac.build(root, bench), (root / "RemoteCoder.app", {})
                    )
                command = next(
                    command for command in commands if command[0] == "xcodebuild"
                )
                self.assertEqual(command[-1], "build")
                self.assertNotIn("-quiet", command)


class BenchSymbolOwnershipTests(unittest.TestCase):
    def test_signed_bench_keeps_matching_symbols_after_products_are_removed(self):
        installer = load("install_built_app", SCRIPTS / "install-built-app.py")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run = root / "Library/Caches/RemoteCoder-Build/runs/bench-build"
            run.mkdir(parents=True)
            provenance = run / "source.json"
            provenance.write_text("{}")
            products = root / "products"
            built = products / "RemoteCoder.app"
            (built / "Contents/MacOS").mkdir(parents=True)
            (built / "Contents/Resources").mkdir()
            (built / "Contents/MacOS/RemoteCoder").write_bytes(b"fixture executable")
            (built / "Contents/Info.plist").write_bytes(
                plistlib.dumps({"CFBundleVersion": "1.0.1"})
            )
            dwarf = (
                products / "RemoteCoder.app.dSYM/Contents/Resources/DWARF/RemoteCoder"
            )
            dwarf.parent.mkdir(parents=True)
            dwarf.write_bytes(b"fixture matching debug information")
            config = root / "config.json"
            config.write_text("{}")
            release = install_mac.Release(
                "fixture-team",
                root / "entitlements",
                root / "profile",
                config,
                {"version": "3.35.0"},
            )
            uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"

            def sdk(command, **kwargs):
                self.assertEqual(command[0], "ditto")
                shutil.copytree(command[1], command[2])
                return subprocess.CompletedProcess(command, 0)

            def helper(name, filename):
                if name == "install_built_app":
                    return installer
                if name == "device_build_identity":
                    return types.SimpleNamespace(verify_bundle=lambda *_args: None)
                self.fail(f"bench must not enter the installed-app stage: {name}")

            with (
                patch.object(sys, "argv", ["install-mac", "--bench"]),
                patch.dict(os.environ, {"RC_BUILD_PROVENANCE": str(provenance)}),
                patch.object(
                    install_mac, "signing_keychain", return_value=root / "keychain"
                ),
                patch.object(install_mac, "published_release", return_value=release),
                patch.object(install_mac, "signer", return_value="fixture identity"),
                patch.object(install_mac, "build", return_value=(built, {})),
                patch.object(install_mac, "bench_config", return_value=config),
                patch.object(install_mac, "sign", return_value=None),
                patch.object(install_mac, "cdhash", return_value="fixture-cdhash"),
                patch.object(install_mac, "load", side_effect=helper),
                patch.object(install_mac.subprocess, "run", side_effect=sdk),
                patch.object(
                    installer, "binary_identities", return_value={(uuid, "arm64")}
                ),
                redirect_stdout(io.StringIO()),
            ):
                install_mac.main()
            shutil.rmtree(products)
            receipt = json.loads((run / "bench.json").read_text())
            self.assertEqual(receipt["symbolsDirectory"], str(run / "symbols"))
            self.assertEqual(
                receipt["retainedSymbols"][0]["uuids"],
                [{"uuid": uuid, "architecture": "arm64"}],
            )
            retained = (
                run
                / "symbols/RemoteCoder.app.dSYM/Contents/Resources/DWARF/RemoteCoder"
            )
            self.assertEqual(
                retained.read_bytes(), b"fixture matching debug information"
            )
            self.assertEqual(
                Path(receipt["retainedSymbols"][0]["file"]).read_bytes(),
                b"fixture executable",
            )


class BenchLabConfigurationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.run = self.root / "run"
        self.run.mkdir()
        self.provenance = self.run / "source.json"
        self.provenance.write_text("{}")
        self.canonical = self.root / "canonical.json"
        self.canonical.write_bytes(b'{ "macBookHostname": "canonical-book", "codexGatewayAuthToken": "fixture-canonical" }\n')
        self.lab = self.root / "lab"
        self.lab.mkdir(mode=0o700)
        self.configuration = self.lab / "config.json"
        self.lab_bytes = b'{ "macBookHostname": "127.0.0.1", "codexGatewayPort": 18001, "codexGatewayAuthToken": "fixture-lab" }\n'
        self.configuration.write_bytes(self.lab_bytes)
        self.configuration.chmod(0o600)
        self.gateway = self.root / "fixture-gateway"
        self.gateway.write_text("fixture gateway executable")
        self.gateway_identity = {"pid": 123, "ppid": 7, "pgid": 7, "startedAtMicroseconds": 100,
                                 "pidVersion": 1, "auditToken": [0, 501, 20, 501, 20, 123, 0, 1]}
        self.enterContext(patch.object(bench_lab, "process_identity", return_value=self.gateway_identity))
        self.enterContext(patch.object(bench_lab, "audit_path", return_value=self.gateway))
        bench_lab.record_gateway(self.lab, 18001, hashlib.sha256(b"fixture-lab").hexdigest(), self.gateway, 123, 7)
        self.built = self.root / "products/RemoteCoder.app"
        (self.built / "Contents/MacOS").mkdir(parents=True)
        (self.built / "Contents/Resources").mkdir()
        (self.built / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "1.0.1"}))
        self.release_config = self.root / "release.json"
        self.release_config.write_bytes(b'{"macBookHostname":"public-book"}')
        release = install_mac.Release("fixture-team", self.root / "entitlements", self.root / "profile",
                                      self.release_config, {"version": "fixture-release"})
        self.enterContext(patch.dict(os.environ, {"RC_BUILD_PROVENANCE": str(self.provenance)}))
        self.enterContext(patch.object(install_mac, "DEVELOPMENT_CONFIG", self.canonical))
        self.enterContext(patch.object(install_mac, "signing_keychain", return_value=self.root / "keychain"))
        self.enterContext(patch.object(install_mac, "published_release", return_value=release))
        self.enterContext(patch.object(install_mac, "signer", return_value="fixture identity"))
        self.build = self.enterContext(patch.object(install_mac, "build", return_value=(self.built, {})))
        self.sign = self.enterContext(patch.object(install_mac, "sign"))
        self.enterContext(patch.object(install_mac, "cdhash", return_value="fixture-cdhash"))
        original_load = install_mac.load

        def helper(name, filename):
            if name == "device_build_identity":
                return types.SimpleNamespace(verify_bundle=lambda *_args: None)
            if name == "install_built_app":
                return types.SimpleNamespace(retain_symbols=lambda *_args: [])
            return original_load(name, filename)

        original_run = subprocess.run

        def sdk(command, **kwargs):
            if command[0] == "git":
                return original_run(command, **kwargs)
            if command[0] == "ditto":
                shutil.copytree(command[1], command[2])
            elif command[:2] == ["python3", "scripts/release-config.py"]:
                original_load("release_config", "release-config.py").validate_development(Path(command[-1]).read_bytes())
            else:
                self.fail(f"Unexpected SDK operation: {command[0]}")
            return subprocess.CompletedProcess(command, 0)

        self.enterContext(patch.object(install_mac, "load", side_effect=helper))
        self.enterContext(patch.object(install_mac.subprocess, "run", side_effect=sdk))

    def invoke(self, options):
        output = io.StringIO()
        with patch.object(sys, "argv", ["install-mac", *options]), redirect_stdout(output):
            install_mac.main()
        return json.loads(output.getvalue())

    def test_default_bench_keeps_canonical_bytes_and_artifact_location(self):
        before = self.canonical.read_bytes()
        result = self.invoke(["--bench"])
        self.assertEqual(Path(result["app"]), self.run / "RemoteCoder.app")
        self.assertEqual((Path(result["app"]) / install_mac.CONFIG).read_bytes(), before)
        self.assertEqual(self.canonical.read_bytes(), before)
        self.assertEqual(self.release_config.read_bytes(), b'{"macBookHostname":"public-book"}')

    def test_lab_bench_uses_only_private_config_and_keeps_token_out_of_cache_and_output(self):
        self.canonical.unlink()
        result = self.invoke(["--bench", "--lab-config", str(self.configuration)])
        app = Path(result["app"])
        self.assertEqual(app.parent.parent, self.lab)
        self.assertEqual(app.parent.stat().st_mode & 0o077, 0)
        self.assertEqual((app / install_mac.CONFIG).read_bytes(), self.lab_bytes)
        self.assertEqual((app / install_mac.CONFIG).stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.configuration.read_bytes(), self.lab_bytes)
        self.assertFalse((self.run / "RemoteCoderLocalConfig.json").exists())
        self.assertFalse((self.run / "RemoteCoder.app").exists())
        self.assertNotIn("fixture-lab", json.dumps(result))
        self.assertNotIn("fixture-lab", (self.run / "bench.json").read_text())
        self.assertEqual(json.loads((self.run / "bench.json").read_text())["artifactLocation"], "lab")
        self.sign.assert_called_once()

    def test_missing_invalid_or_public_lab_config_fails_before_building(self):
        variants = [None, b"not json", b"[]", b"{}",
                    b'{"macBookHostname":"live-book","codexGatewayPort":18001,"codexGatewayAuthToken":"fixture-lab"}',
                    b'{"macBookHostname":"127.0.0.1","codexGatewayPort":0,"codexGatewayAuthToken":"fixture-lab"}',
                    b'{"macBookHostname":"127.0.0.1","codexGatewayPort":18001,"codexGatewayAuthToken":""}',
                    b'{"macBookHostname":"127.0.0.1","macMiniHostname":"mini","codexGatewayPort":18001,"codexGatewayAuthToken":"fixture-lab"}',
                    b'{"macBookHostname":"127.0.0.1","codexGatewayPort":18001,"codexGatewayAuthToken":"fixture-lab","providerKey":"fixture-secret"}']
        for value in variants:
            with self.subTest(value=value):
                if value is None:
                    self.configuration.unlink()
                else:
                    self.configuration.write_bytes(value)
                    self.configuration.chmod(0o600)
                with self.assertRaisesRegex(SystemExit, "Invalid lab configuration") as failure:
                    self.invoke(["--bench", "--lab-config", str(self.configuration)])
                self.assertNotIn("fixture-secret", str(failure.exception))
                self.assertNotIn("fixture-lab", str(failure.exception))
        self.configuration.write_bytes(self.lab_bytes)
        for public in (self.configuration, self.lab):
            with self.subTest(public=public):
                public.chmod(0o644 if public == self.configuration else 0o755)
                with self.assertRaisesRegex(SystemExit, "Invalid lab configuration"):
                    self.invoke(["--bench", "--lab-config", str(self.configuration)])
                public.chmod(0o600 if public == self.configuration else 0o700)
        self.build.assert_not_called()
        self.sign.assert_not_called()

    def test_lab_option_cannot_enter_the_production_install_path(self):
        with self.assertRaises(SystemExit) as failure:
            self.invoke(["--lab-config", str(self.configuration)])
        self.assertEqual(failure.exception.code, 2)
        self.build.assert_not_called()

    def test_production_loopback_config_requires_matching_live_lab_metadata(self):
        variants = [None, "wrong-port", "wrong-token", "replaced-process", "wrong-executable"]
        metadata_path = self.lab / bench_lab.METADATA
        original = metadata_path.read_bytes()
        for variant in variants:
            with self.subTest(variant=variant):
                metadata_path.write_bytes(original)
                metadata = json.loads(original)
                if variant is None:
                    metadata_path.unlink()
                    self.configuration.write_text(json.dumps({"macBookHostname": "127.0.0.1",
                        "codexGatewayPort": 8787, "codexGatewayAuthToken": "production-fixture-token"}))
                else:
                    self.configuration.write_bytes(self.lab_bytes)
                    if variant == "wrong-port":
                        metadata["port"] = 8787
                    elif variant == "wrong-token":
                        metadata["tokenSHA256"] = hashlib.sha256(b"production-fixture-token").hexdigest()
                    elif variant == "replaced-process":
                        metadata["gateway"]["pidVersion"] = 2
                        metadata["gateway"]["auditToken"][7] = 2
                    else:
                        metadata["executable"] = "/other/gateway"
                    metadata_path.write_text(json.dumps(metadata))
                    metadata_path.chmod(0o600)
                with self.assertRaisesRegex(SystemExit, "Invalid lab configuration") as failure:
                    self.invoke(["--bench", "--lab-config", str(self.configuration)])
                self.assertNotIn("production-fixture-token", str(failure.exception))
        self.build.assert_not_called()
        self.sign.assert_not_called()


if __name__ == "__main__":
    unittest.main()
