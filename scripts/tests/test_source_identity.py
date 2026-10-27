import fcntl
import hashlib
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import build_cache as cache
import build_support as support

spec = importlib.util.spec_from_file_location(
    "identity_remote_build", SCRIPTS / "remote-build.py"
)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SourceIdentityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.source = self.root / "SourceCase"
        self.source.mkdir()
        self.alias = self.root / "sourcecase"
        if not self.alias.exists() or not self.alias.samefile(self.source):
            self.skipTest("Requires a case-insensitive filesystem")
        self.enterContext(patch.object(Path, "home", return_value=self.root))
        self.cache = self.root / "Library/Caches/RemoteCoder-Build"
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        subprocess.run(["git", "-C", str(self.source), "config", "maintenance.auto", "false"], check=True)
        subprocess.run(["git", "-C", str(self.source), "config", "gc.auto", "0"], check=True)
        (self.source / ".xcode-version").write_text("27.0")
        subprocess.run(
            ["git", "-C", str(self.source), "add", ".xcode-version"], check=True
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(self.source),
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.test",
                "commit",
                "-q",
                "-m",
                "fixture",
            ],
            check=True,
        )

    def test_private_config_is_carried_only_for_install_or_explicit_live_tests(self):
        relative = "RemoteCoder/Resources/RemoteCoderLocalConfig.json"
        config = self.source / relative
        config.parent.mkdir(parents=True)
        config.write_text('{"codexGatewayAuthToken":"synthetic-fixture"}')
        (self.source / ".gitignore").write_text(relative + "\n")
        for enabled in ("0", "1"):
            with patch.dict(os.environ, {"RC_LIVE_GATEWAY": enabled}):
                for kind in ("ios-install", "ios-simulator-test", "mac-build", "ios-archive"):
                    manifest = runner.source_manifest(self.source, kind, [])
                    allowed = kind == "ios-install" or (kind == "ios-simulator-test" and enabled == "1")
                    self.assertEqual(relative in manifest["files"], allowed, (kind, enabled))

    def test_a_case_alias_cannot_acquire_a_second_source_lease(self):
        with support.file_lease(support.source_lease_path(self.source)):
            alias_lease = support.source_lease_path(self.alias)
            with (
                alias_lease.open("a") as descriptor,
                self.assertRaises(BlockingIOError),
            ):
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual(support.source_lease_path(self.source), alias_lease)
        other = self.root / "DifferentCheckout"
        other.mkdir()
        self.assertNotEqual(support.source_lease_path(other), alias_lease)

    def test_case_aliases_reuse_one_worker_mirror_and_receipt_identity(self):
        policy = cache.CachePolicy(
            512, 259200, 172800, 7200, 80 * 1024**3, 2, 0, False, 86400
        )
        mirrors = []
        identities = []

        def sync(command, **kwargs):
            self.assertEqual(command[0], "rsync")
            shutil.copytree(command[-2], command[-1], dirs_exist_ok=True)
            return subprocess.CompletedProcess(command, 0)

        def compile(command, repository, environment, output, descriptors):
            mirrors.append(repository)
            return 0

        for source in (self.source, self.alias):
            manifest = runner.source_manifest(source, "tools-test", [])
            run = self.cache / "runs" / manifest["buildId"]
            snapshot = run / "repo"
            snapshot.mkdir(parents=True)
            shutil.copy2(source / ".xcode-version", snapshot / ".xcode-version")
            (run / "source.json").write_text(json.dumps(manifest))
            with (
                patch.object(runner, "load_policy", return_value=policy),
                patch.object(runner, "local_worktrees", return_value=[]),
                patch.object(runner.subprocess, "run", side_effect=sync),
                patch.object(runner, "run_owned", side_effect=compile),
            ):
                receipt = runner.worker(run)
            identities.append(receipt["worktreeId"])
            self.assertEqual(receipt["exitCode"], 0)
        self.assertEqual(identities[0], identities[1])
        self.assertEqual(mirrors[0], mirrors[1])
        other = self.root / "DifferentCheckout"
        shutil.copytree(self.source, other)
        self.assertNotEqual(
            runner.source_manifest(other, "tools-test", [])["worktreeId"], identities[0]
        )

    def test_case_aliases_share_compilation_records_and_inventory(self):
        path = self.source / "build/ios-build-derived"
        path.mkdir(parents=True)
        alias = self.alias / "build/ios-build-derived"
        cache.record_compilation(
            self.cache,
            [alias],
            "fixture",
            False,
            {"sourceCommit": "fixture", "sourceModified": False},
        )
        record = cache.compilation_record(self.cache, path)
        self.assertEqual(record, cache.compilation_record(self.cache, alias))
        self.assertEqual(json.loads(record.read_text())["path"], str(path))
        entries = cache.compilation_directories(
            self.cache, [self.source, self.alias], self.root / "unowned"
        )
        self.assertEqual([entry.path for entry in entries], [path])
        environment = {"CARGO_TARGET_DIR": str(self.alias / "host-daemon-rs/target")}
        self.assertEqual(
            runner.recipe_environment(self.source, environment)["CARGO_TARGET_DIR"],
            "host-daemon-rs/target",
        )

    def test_current_cache_is_protected_when_requested_through_a_case_alias(self):
        source = self.cache / "owned/SourceCase"
        alias = self.cache / "owned/sourcecase"
        shutil.copytree(self.source, source)
        old = time.time() - 86400
        paths = []
        for name in ("ios-build-derived", "mac-build-derived"):
            path = source / "build" / name
            payload = path / "Build/Intermediates.noindex"
            payload.mkdir(parents=True)
            (payload / "object.o").write_bytes(b"compiler" * 1024)
            paths.append(path)
        with patch.object(cache.time, "time", return_value=old):
            cache.record_compilation(
                self.cache,
                [paths[0]],
                "one",
                False,
                {"sourceCommit": "fixture", "sourceModified": True},
            )
        with patch.object(cache.time, "time", return_value=old + 1):
            cache.record_compilation(
                self.cache,
                [paths[1]],
                "two",
                False,
                {"sourceCommit": "fixture", "sourceModified": True},
            )
        entries = cache.compilation_directories(
            self.cache, [source], self.root / "unowned"
        )
        policy = cache.CachePolicy(512, 259200, 172800, 7200, 1, 1, 0, True, 86400)
        with patch.object(cache, "_open_files", return_value=False):
            result = cache.compilation_admission(
                self.cache,
                policy,
                entries,
                {alias / "build/ios-build-derived"},
                preview=False,
            )
        self.assertTrue((paths[0] / "Build/Intermediates.noindex/object.o").is_file())
        self.assertIn(
            {
                "path": str(paths[0]),
                "allocatedBytes": next(
                    item["allocatedBytes"]
                    for item in result["protected"]
                    if item["path"] == str(paths[0])
                ),
                "reason": "current",
            },
            result["protected"],
        )

    def test_old_alias_records_protect_against_timestamp_fallback_until_superseded(
        self,
    ):
        now = time.time()
        old = now - 3 * 86400
        policy = cache.CachePolicy(512, 259200, 172800, 7200, 1, 1, 0, True, 86400)
        for guard in ("active", "recent", "invalid", "unreadable", "ambiguous"):
            with (
                self.subTest(guard=guard),
                tempfile.TemporaryDirectory(dir=self.root) as temporary,
            ):
                home = Path(temporary).resolve()
                cache_root = home / "Library/Caches/RemoteCoder-Build"
                source = cache_root / "owned/SourceCase"
                alias_source = cache_root / "owned/sourcecase"
                shutil.copytree(self.source, source)
                with patch.object(Path, "home", return_value=home):
                    subprocess.run(
                        [
                            "git",
                            "-C",
                            str(source),
                            "update-ref",
                            "refs/remotes/origin/main",
                            "HEAD",
                        ],
                        check=True,
                    )
                    commit = subprocess.check_output(
                        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
                    ).strip()
                    name = "legacy-" + guard + "-derived"
                    path = source / "build" / name
                    alias = alias_source / "build" / name
                    payload = path / "Build/Intermediates.noindex/object.o"
                    witness = payload.parent / "XCBuildData/build.db"
                    witness.parent.mkdir(parents=True)
                    payload.write_bytes(b"legacy compiler artifact")
                    witness.write_bytes(b"old timestamp witness")
                    os.utime(witness, (old, old))
                    key = hashlib.sha256(str(alias.absolute()).encode()).hexdigest()
                    record = cache_root / "leases/compilation" / (key + ".json")
                    record.parent.mkdir(parents=True, exist_ok=True)
                    value = {
                        "path": str(alias),
                        "buildId": "old-owner",
                        "active": guard == "active",
                        "lastUsed": now if guard == "recent" else old,
                        "completedAt": None if guard == "invalid" else old,
                        "sourceCommit": commit,
                        "sourceModified": False,
                    }
                    record.write_text(
                        "{" if guard == "unreadable" else json.dumps(value)
                    )
                    if guard == "active":
                        canonical_key = hashlib.sha256(
                            str(path.absolute()).encode()
                        ).hexdigest()
                        record.with_name(canonical_key + ".json").write_text(
                            json.dumps(
                                value
                                | {
                                    "path": str(path),
                                    "active": False,
                                    "lastUsed": old - 1,
                                }
                            )
                        )
                    if guard == "ambiguous":
                        other = cache_root / "owned/SOURCECASE/build" / name
                        other_key = hashlib.sha256(
                            str(other.absolute()).encode()
                        ).hexdigest()
                        record.with_name(other_key + ".json").write_text(
                            json.dumps(
                                value
                                | {"path": str(other), "buildId": "conflicting-owner"}
                            )
                        )
                    entries = cache.compilation_directories(
                        cache_root, [source], home / "unowned"
                    )
                    entries = [entry for entry in entries if entry.path == path]
                    with patch.object(cache, "_open_files", return_value=False):
                        result = cache.compilation_admission(
                            cache_root, policy, entries, set(), preview=False
                        )
                    self.assertTrue(payload.exists(), guard)
                    self.assertFalse(result["evicted"], guard)
                    if guard == "recent":
                        with (
                            patch.object(
                                cache.time, "time", return_value=now + 3 * 86400
                            ),
                            patch.object(cache, "_open_files", return_value=False),
                        ):
                            result = cache.compilation_admission(
                                cache_root, policy, entries, set(), preview=False
                            )
                        self.assertFalse(payload.exists(), guard)
                        self.assertTrue(result["evicted"], guard)
                        continue
                    cache.record_compilation(
                        cache_root,
                        [path],
                        "canonical-owner",
                        False,
                        {"sourceCommit": commit, "sourceModified": False},
                    )
                    with (
                        patch.object(cache.time, "time", return_value=now + 3 * 86400),
                        patch.object(cache, "_open_files", return_value=False),
                    ):
                        result = cache.compilation_admission(
                            cache_root, policy, entries, set(), preview=False
                        )
                    self.assertFalse(payload.exists(), guard)
                    self.assertTrue(result["evicted"], guard)

    def test_local_install_cache_ignores_alias_spelled_inherited_pwd(self):
        provenance = self.root / "provenance.json"
        provenance.write_text("{}")
        selected = []
        original_run = subprocess.run

        def install(command, cwd, environment, output, leases):
            selected.append(
                original_run(
                    [
                        "/bin/bash",
                        "-c",
                        'printf "%s" "${RC_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/RemoteCoder-27A-fixture-$(printf %s "$PWD" | shasum -a 256 | cut -c1-16)}"',
                    ],
                    cwd=cwd,
                    env=environment,
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout
            )
            return 0

        for source in (self.source, self.alias):
            with (
                patch.dict(
                    os.environ,
                    {
                        "HOME": str(self.root),
                        "PWD": str(source),
                        "RC_BUILD_PROVENANCE": str(provenance),
                    },
                    clear=True,
                ),
                patch.object(runner, "ROOT", support.canonical_path(source)),
                patch.object(
                    runner.socket, "gethostname", return_value="laptop"
                ),
                patch.object(
                    runner.subprocess,
                    "check_output",
                    return_value="Xcode 27\nBuild version 27A-fixture\n",
                ),
                patch.object(runner, "run_owned", side_effect=install),
                patch.object(sys, "argv", ["remote-build.py", "local-install"]),
                self.assertRaises(SystemExit) as status,
            ):
                runner.main()
            self.assertEqual(status.exception.code, 0)
        self.assertEqual(selected[0], selected[1])
        self.assertEqual(
            selected[0],
            str(
                self.root
                / "Library/Developer/Xcode/DerivedData"
                / (
                    "RemoteCoder-27A-fixture-"
                    + hashlib.sha256(str(self.source).encode()).hexdigest()[:16]
                )
            ),
        )

    def test_legacy_spelling_mirror_keeps_its_lease_and_retirement_evidence(self):
        legacy = hashlib.sha256(
            (socket.gethostname() + ":" + str(self.alias)).encode()
        ).hexdigest()[:16]
        self.assertNotEqual(
            legacy, runner.source_manifest(self.source, "tools-test", [])["worktreeId"]
        )
        (self.root / "RemoteCoder").symlink_to(self.source, target_is_directory=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(self.source),
                "update-ref",
                "refs/remotes/origin/main",
                "HEAD",
            ],
            check=True,
        )
        commit = subprocess.check_output(
            ["git", "-C", str(self.source), "rev-parse", "HEAD"], text=True
        ).strip()
        path = self.cache / "worktrees" / legacy / "ios/derived-old"
        payload = path / "Build/Intermediates.noindex/object.o"
        payload.parent.mkdir(parents=True)
        payload.write_bytes(b"old compiler artifact")
        with patch.object(cache.time, "time", return_value=time.time() - 3 * 86400):
            cache.record_compilation(
                self.cache,
                [path],
                "legacy",
                False,
                {"sourceCommit": commit, "sourceModified": False},
            )
        entries = cache.compilation_directories(self.cache, [], self.root / "unowned")
        policy = cache.CachePolicy(512, 259200, 172800, 7200, 1, 1, 0, True, 86400)
        lease = cache.lease_path(self.cache, "worktrees", legacy)
        with patch.object(cache, "_open_files", return_value=False):
            with support.file_lease(lease):
                result = cache.compilation_admission(
                    self.cache, policy, entries, set(), preview=False
                )
                self.assertTrue(payload.is_file())
                self.assertEqual(
                    [item["reason"] for item in result["protected"]], ["leased"]
                )
            result = cache.compilation_admission(
                self.cache, policy, entries, set(), preview=False
            )
        self.assertFalse(payload.exists())
        self.assertTrue(result["evicted"])


class SourceIdentityPreflightTests(unittest.TestCase):
    def test_preflight_reserves_descriptors_and_distinguishes_a_hard_limit(self):
        bootstrap = """import os,resource,sys
resource.setrlimit(resource.RLIMIT_NOFILE,(32,int(sys.argv[2])))
os.execv(sys.executable,[sys.executable,sys.argv[1]])
"""
        for hard, busy in ((512, False), (512, True), (32, False)):
            with (
                self.subTest(hard=hard, busy=busy),
                tempfile.TemporaryDirectory() as temporary,
            ):
                home = Path(temporary).resolve()
                directory = home / "Library/Caches/RemoteCoder-Build/local-installs"
                directory.mkdir(parents=True)
                for index in range(64):
                    (directory / f"{index:03}.lock").touch()
                held = directory / "063.lock"
                with held.open("rb") as descriptor:
                    if busy:
                        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    result = subprocess.run(
                        [
                            sys.executable,
                            "-c",
                            bootstrap,
                            str(SCRIPTS / "source-identity-preflight.py"),
                            str(hard),
                        ],
                        env=os.environ | {"HOME": str(home)},
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                report = json.loads(result.stdout)
                if hard == 32:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(report["error"]["kind"], "descriptorLimit")
                    self.assertIn("hard", report["error"]["message"])
                    self.assertIn("rerun", report["error"]["message"])
                    self.assertNotIn("unverifiedLeases", report)
                else:
                    self.assertEqual(result.returncode, int(busy), result.stderr)
                    self.assertEqual(
                        report,
                        {
                            "heldLeases": [str(held)] if busy else [],
                            "unverifiedLeases": [],
                        },
                    )

    def test_preflight_reports_held_legacy_and_worktree_leases_without_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            root = home / "Library/Caches/RemoteCoder-Build"
            paths = [
                root / "local-installs/old-spelling.lock",
                root / "leases/worktrees/old-mirror.lock",
                root / "worktrees/old-mirror/ios/build.lock",
                root / "worktrees/old-mirror/gateway/build.lock",
            ]
            for path in paths:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"unchanged")
            before = {
                path: (path.read_bytes(), path.stat().st_mtime_ns) for path in paths
            }
            for held in paths:
                with held.open("rb") as descriptor:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    result = subprocess.run(
                        [sys.executable, str(SCRIPTS / "source-identity-preflight.py")],
                        env=os.environ | {"HOME": str(home)},
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual(
                        json.loads(result.stdout),
                        {"heldLeases": [str(held)], "unverifiedLeases": []},
                    )
                    with held.open("rb") as second, self.assertRaises(BlockingIOError):
                        fcntl.flock(second, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = subprocess.run(
                [sys.executable, str(SCRIPTS / "source-identity-preflight.py")],
                env=os.environ | {"HOME": str(home)},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(result.stdout), {"heldLeases": [], "unverifiedLeases": []}
            )
            self.assertEqual(
                {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in paths},
                before,
            )
            self.assertEqual(set(root.rglob("*.lock")), set(paths))
