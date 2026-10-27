import importlib.util
import io
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import nullcontext, redirect_stdout
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_cache import CachePolicy
from git_fixtures import init_repository

HELPER = Path(__file__).resolve().parents[1] / "remote-build.py"
spec = importlib.util.spec_from_file_location("remote_build", HELPER)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProfilingSymbolsTests(unittest.TestCase):
    def test_symbols_remain_discoverable_on_the_tracing_host_after_source_removal(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            source = home / "source-symbols"
            dwarf = source / "RemoteCoder.app.dSYM/Contents/Resources/DWARF/RemoteCoder"
            dwarf.parent.mkdir(parents=True)
            dwarf.write_bytes(b"debug information")
            artifact = {"symbols": [{"path": str(source), "sha256": module.tree_digest(source)}]}
            real_run = subprocess.run

            def target_process(*args, **kwargs):
                if "input" in kwargs and "build_cache.py" in kwargs["input"]:
                    payload, digest, _ = kwargs["input"].split("\n")
                    payload = json.loads(payload)
                    payload["build_cache.py"] += "\ndef cache_allocated_bytes(*args):\n    raise TimeoutError('whole-cache scan must not run during delivery')\n"
                    kwargs["input"] = json.dumps(payload) + "\n" + digest + "\n"
                return real_run(*args, **(kwargs | {"env": os.environ | {"HOME": str(home)}}))

            with (patch.object(module.subprocess, "run", side_effect=target_process),
                  patch.object(module.build_hosts, "TEST_DEVICE_HOST", "local"),
                  patch.object(module.subprocess, "check_output", return_value=json.dumps(str(home))),
                  patch.object(module, "host_job_assertion", return_value=nullcontext())):
                mirrored = module.mirror_device_symbols(artifact, {"buildId": "fixture-symbols"}, HELPER.parent)
            shutil.rmtree(source)
            copied = Path(mirrored["directory"])
            self.assertEqual((copied / dwarf.relative_to(source)).read_bytes(), b"debug information")
            self.assertEqual(json.loads((copied.parent / "outcome.json").read_text())["exitCode"], 0)
            accounting = json.loads((copied.parent / "symbol-cache.json").read_text())
            self.assertIsNone(accounting["allocatedBytes"])
            self.assertIn("maintenance", accounting["unavailableReason"])
            self.assertIn("retention", accounting)


def worker_snapshot(
    run, *, kind, worktree_id, build_id, source_commit, xcode_version, environment
):
    source = run / "repo"
    source.mkdir(parents=True)
    (source / ".xcode-version").write_text(xcode_version)
    manifest = {
        "kind": kind,
        "arguments": [],
        "worktreeId": worktree_id,
        "buildId": build_id,
        "sourceCommit": source_commit,
        "sourceModified": False,
        "files": [".xcode-version"],
        "environment": environment,
        "sourceFingerprint": module.fingerprint(source, [".xcode-version"]),
    }
    (run / "source.json").write_text(json.dumps(manifest))
    return source, manifest


def write_cache_policy(home):
    policy = home / "configs/build/compilation-cache-policy.json"
    policy.parent.mkdir(parents=True)
    policy.write_text(
        json.dumps(
            {
                "compilationBudgetGiB": 80,
                "retainedCompletedDirectories": 2,
                "evictionEnabled": True,
                "retiredWorktreeIdleHours": 24,
                "maxRuns": 512,
                "compilerProtectionHours": 2,
                "runRetentionDays": 3,
                "evidenceProtectionHours": 48,
                "evictionTargetFreeGiB": 1,
            }
        )
    )


class RemoteBuildTests(unittest.TestCase):
    def test_device_compilation_variants_keep_optimized_incremental_caches_separate(
        self,
    ):
        self.assertEqual(module.ios_device_variant([]), "-ios-incremental-optimized")
        self.assertEqual(module.ios_device_variant(["--optimized"]), "")
        self.assertEqual(
            module.ios_device_variant(["--build-only", "--incremental-optimized"]),
            "-ios-incremental-optimized",
        )
        self.assertEqual(
            module.ios_device_variant(["--unoptimized"]), "-ios-unoptimized"
        )
        for options in (
            ["--optimized", "--incremental-optimized"],
            ["--incremental-optimized", "--unoptimized"],
            ["--unoptimized", "--optimized"],
        ):
            with (
                self.subTest(options=options),
                self.assertRaisesRegex(ValueError, "Select only one"),
            ):
                module.ios_device_variant(options)

    def test_builds_default_to_the_build_host_and_mac_app_installs_to_the_macbook(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            (root / "scripts/build-host").write_text("fixture-builder\n")
            with (patch.object(module, "ROOT", root),
                  patch.object(module.build_hosts, "load", return_value={}),
                  patch.object(module.build_hosts, "MAC_GUI_HOST", "laptop")):
                for kind in ("ios-install", "ios-build", "verify", "verify-all", "release-gate", "gateway", "core-test"):
                    self.assertEqual(module.selected_build_host(kind, {}), "fixture-builder")
                for kind in ("mac-install", "mac-bench"):
                    self.assertEqual(module.selected_build_host(kind, {}), module.build_hosts.MAC_GUI_HOST)
                explicit = {"RC_IOS_BUILD_HOST": "fixture-phone-builder", "RC_GATEWAY_BUILD_HOST": "fixture-other"}
                self.assertEqual(module.selected_build_host("ios-install", explicit), "fixture-phone-builder")
                self.assertEqual(module.selected_build_host("verify-all", explicit), "fixture-phone-builder")
                self.assertEqual(module.selected_build_host("release-gate", explicit), "fixture-phone-builder")
                self.assertEqual(module.selected_build_host("verify", explicit), "fixture-other")
                self.assertEqual(module.selected_build_host("mac-install", explicit), "fixture-other")

    def test_mirror_retains_only_generated_outputs_and_deletes_removed_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, mirror = root / "source", root / "mirror"
            source.mkdir()
            mirror.mkdir()
            (source / "new.swift").write_text("source")
            (mirror / "removed.swift").write_text("stale")
            for name in ("RemoteCoder.xcworkspace", "Derived"):
                (mirror / name).mkdir()
                (mirror / name / "generated").write_text("retained")
            subprocess.run(module.mirror_source_command(source, mirror), check=True)
            self.assertFalse((mirror / "removed.swift").exists())
            self.assertEqual((mirror / "new.swift").read_text(), "source")
            for name in ("RemoteCoder.xcworkspace", "Derived"):
                self.assertEqual((mirror / name / "generated").read_text(), "retained")


    def test_gateway_return_preserves_the_bundle_and_rejects_a_changed_resource_seal(self):
        import hashlib

        for corrupt in (False, True):
            with self.subTest(corrupt=corrupt), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                (root / "scripts").mkdir()
                (root / "scripts/build-host").write_text("gateway-secondary")
                bundle = root / "remote" / module.gateway_bundle.NAME
                binary = module.gateway_bundle.executable(bundle)
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"gateway fixture")
                (bundle / "Contents/Info.plist").write_bytes(b"info fixture")
                seal = bundle / "Contents/_CodeSignature/CodeResources"
                seal.parent.mkdir()
                seal.write_bytes(b"sealed resources")
                receipt = {
                    "exitCode": 0,
                    "artifact": str(bundle),
                    "artifactSHA256": module.tree_digest(bundle),
                    "gatewaySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                }

                def transfer(command, **kwargs):
                    if command[0] == "rsync":
                        source = Path(command[-2].split(":", 1)[-1])
                        destination = Path(command[-1])
                        shutil.copytree(source, destination)
                        if corrupt:
                            (destination / "Contents/_CodeSignature/CodeResources").write_bytes(b"changed")
                    return subprocess.CompletedProcess(command, 0)

                output = io.StringIO()
                with (
                    patch.object(module, "ROOT", root),
                    patch.object(module, "source_manifest", return_value={"buildId": "gateway-build"}),
                    patch.object(module, "transfer_source"),
                    patch.object(module, "host_job_assertion", return_value=nullcontext(1000)),
                    patch.object(module.subprocess, "check_output", return_value=json.dumps(str(root / "book"))),
                    patch.object(module.subprocess, "run", side_effect=transfer),
                    patch.object(module, "run_connected", return_value=subprocess.CompletedProcess([], 0, json.dumps(receipt))),
                    patch.object(sys, "argv", [str(HELPER), "gateway"]),
                    redirect_stdout(output),
                ):
                    if corrupt:
                        with self.assertRaisesRegex(ValueError, "artifact fingerprint mismatch"):
                            module.main()
                    else:
                        with self.assertRaises(SystemExit) as result:
                            module.main()
                        self.assertEqual(result.exception.code, 0)
                        returned = Path(json.loads(output.getvalue())["artifact"])
                        self.assertEqual((returned / "Contents/Info.plist").read_bytes(), b"info fixture")
                        self.assertEqual((returned / "Contents/_CodeSignature/CodeResources").read_bytes(), b"sealed resources")
                        self.assertEqual(module.gateway_bundle.executable(returned).read_bytes(), b"gateway fixture")

    def test_lab_bench_keeps_the_private_artifact_on_the_build_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / "scripts").mkdir()
            (root / "scripts/build-host").write_text("gateway-secondary")
            lab = "/tmp/private-lab"
            receipt = {"exitCode": 0, "app": lab + "/bench-fixture/RemoteCoder.app", "cdhash": "fixture",
                       "artifactLocation": "lab"}
            output = io.StringIO()
            with (
                patch.object(module, "ROOT", root),
                patch.object(module, "source_manifest", return_value={"buildId": "lab-build"}),
                patch.object(module, "transfer_source"),
                patch.object(module, "validate_lab_request"),
                patch.object(module, "host_job_assertion", return_value=nullcontext(1000)),
                patch.object(module.subprocess, "check_output", return_value=json.dumps("/synthetic/book")),
                patch.object(module.subprocess, "run") as transfer,
                patch.object(module, "run_connected", return_value=subprocess.CompletedProcess([], 0, json.dumps(receipt))),
                patch.object(sys, "argv", [str(HELPER), "mac-bench", "--lab-config", lab + "/config.json"]),
                redirect_stdout(output),
                self.assertRaises(SystemExit) as result,
            ):
                module.main()
            self.assertEqual(result.exception.code, 0)
            transfer.assert_not_called()
            self.assertFalse((root / "build/mac-bench").exists())
            self.assertEqual(json.loads(output.getvalue())["app"], receipt["app"])
            saved = json.loads((root / "build/receipts/lab-build/receipt.json").read_text())
            self.assertEqual(saved["app"], receipt["app"])

    def test_lab_placement_is_rejected_before_snapshot_or_transfer(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            (source / "scripts").mkdir(parents=True)
            (source / "scripts/build-host").write_text("local")
            other = root / "other-worktree"
            other.mkdir()
            subprocess.run(["git", "init", "-q", str(other)], check=True)
            placements = [source / "bench-lab", root / "Library/Caches/RemoteCoder-Build/runs/lab",
                          other / "bench-lab"]
            for directory in placements:
                directory.mkdir(parents=True, mode=0o700)
                config = directory / "config.json"
                config.write_text(json.dumps({"macBookHostname": "127.0.0.1", "codexGatewayPort": 8787,
                                              "codexGatewayAuthToken": "production-fixture-token"}))
                config.chmod(0o600)
                with (
                    self.subTest(directory=directory),
                    patch.object(module, "ROOT", source),
                    patch.object(module, "source_manifest", side_effect=ValueError("snapshot reached")) as snapshot,
                    patch.object(module, "transfer_source") as transfer,
                    patch.object(sys, "argv", [str(HELPER), "mac-bench", "--lab-config", str(config)]),
                    self.assertRaisesRegex(ValueError, "Lab placement"),
                ):
                    module.main()
                snapshot.assert_not_called()
                transfer.assert_not_called()

    def test_failed_seed_clean_is_recorded_and_worker_builds_unseeded(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            root = home / "Library/Caches/RemoteCoder-Build"
            run = root / "runs/current"
            source, manifest = worker_snapshot(
                run,
                kind="gateway-check",
                worktree_id="candidate",
                build_id="current",
                source_commit="fixture",
                xcode_version="27.0",
                environment={},
            )
            sibling = root / "worktrees/warm/gateway"
            dependency = sibling / "cargo/debug/deps/dep"
            dependency.parent.mkdir(parents=True)
            dependency.write_text("dependency")
            (sibling / "cargo-seed-key").write_text("matching")
            original_run = subprocess.run
            built = []

            def transfer_or_fail_clean(command, **kwargs):
                if command[0] == "cargo":
                    raise subprocess.CalledProcessError(101, command)
                if command[0] == "cp":
                    return original_run(command, **kwargs)
                self.assertEqual(command[0], "rsync")
                shutil.copytree(source, Path(command[-1]), dirs_exist_ok=True)
                return subprocess.CompletedProcess(command, 0)

            def build_unseeded(command, cwd, environment, output, leases):
                self.assertFalse(Path(environment["CARGO_TARGET_DIR"]).is_absolute())
                target = (cwd / environment["CARGO_TARGET_DIR"]).resolve()
                self.assertFalse(target.exists())
                target.mkdir()
                (target / "built-from-candidate").touch()
                built.append(command)
                return 0

            with (
                patch.object(module.Path, "home", return_value=home),
                patch.object(
                    module,
                    "load_policy",
                    return_value=CachePolicy(
                        512, 259200, 172800, 7200, 80 * 1024**3, 2, 0, True, 86400
                    ),
                ),
                patch.object(module, "cargo_seed_key", return_value="matching"),
                patch.object(module, "local_worktrees", return_value=[]),
                patch.object(
                    module.subprocess, "run", side_effect=transfer_or_fail_clean
                ),
                patch.object(module, "run_owned", side_effect=build_unseeded),
            ):
                receipt = module.worker(run)
            self.assertEqual(receipt["exitCode"], 0)
            self.assertEqual(built, [["just", "gateway-check-local"]])
            self.assertEqual(receipt["cargoSeed"]["status"], "unseeded")
            self.assertEqual(receipt["cargoSeed"]["failure"]["exitCode"], 101)
            self.assertEqual(dependency.read_text(), "dependency")
            self.assertEqual(
                [
                    p
                    for p in (root / "worktrees/candidate/gateway").glob("cargo-*")
                    if p.is_dir()
                ],
                [],
            )

    def test_unsigned_workers_do_not_pass_inherited_credentials_to_recipes(self):
        inherited = {
            "HOME": "/synthetic/home",
            "PATH": "/synthetic/bin",
            "CARGO_HOME": "/synthetic/cargo",
            "RUSTUP_HOME": "/synthetic/rustup",
            "RUSTC_WRAPPER": "/synthetic/sccache",
            "SCCACHE_DIR": "/synthetic/cache",
            "SCCACHE_CACHE_SIZE": "25G",
            "RC_PUSH_BROKER_TOKEN": "fake-push-token",
            "RC_CODEX_GATEWAY_AUTH_TOKEN": "fake-gateway-token",
            "OPENAI_API_KEY": "fake-provider-key",
            "SOME_VENDOR_API_KEY": "fake-other-provider-key",
            "GH_TOKEN_PERSONAL": "fake-personal-token",
            "TS_AUTHKEY": "fake-tailnet-key",
            "OVSX_PAT": "fake-extension-token",
            "APP_STORE_CONNECT_KEY_ID": "fake-signing-key-id",
            "MATCH_PASSWORD": "fake-signing-password",
            "REMOTE_CODER_GOOGLE_MAPS_API_KEY": "fake-maps-key",
            "BASH_ENV": "/synthetic/bash-startup",
            "ENV": "/synthetic/posix-startup",
            "ZDOTDIR": "/synthetic/zsh-startup",
        }
        for kind in sorted(module.UNSIGNED_WORKER_KINDS):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                run = root / "run"
                source, manifest = worker_snapshot(
                    run,
                    kind=kind,
                    worktree_id="synthetic",
                    build_id="synthetic-build",
                    source_commit="synthetic",
                    xcode_version="27.0",
                    environment={
                        "RC_XCODE_DEVELOPER_DIR": "/synthetic/Xcode.app/Contents/Developer",
                        "RC_IOS_SIMULATOR": "synthetic-simulator",
                        "RC_CLAUDE_MIGRATION_FIXTURE_HOME": "/tmp/claude-migration-fixture-synthetic",
                    },
                )

                def copy_snapshot(command, _source=source, **_kwargs):
                    self.assertEqual(command[0], "rsync")
                    shutil.copytree(_source, Path(command[-1]), dirs_exist_ok=True)

                def run_recipe(
                    command,
                    cwd,
                    environment,
                    output,
                    leases,
                    _kind=kind,
                    _manifest=manifest,
                    _run=run,
                ):
                    self.assertEqual(environment["HOME"], inherited["HOME"])
                    self.assertEqual(environment["PATH"], inherited["PATH"])
                    for key in (
                        "CARGO_HOME",
                        "RUSTUP_HOME",
                        "RUSTC_WRAPPER",
                        "SCCACHE_DIR",
                        "SCCACHE_CACHE_SIZE",
                    ):
                        self.assertEqual(environment[key], inherited[key])
                    self.assertEqual(
                        environment["DEVELOPER_DIR"],
                        _manifest["environment"]["RC_XCODE_DEVELOPER_DIR"],
                    )
                    self.assertEqual(
                        environment["RC_IOS_SIMULATOR"], "synthetic-simulator"
                    )
                    self.assertEqual(
                        environment["RC_CLAUDE_MIGRATION_FIXTURE_HOME"],
                        "/tmp/claude-migration-fixture-synthetic",
                    )
                    self.assertNotEqual(environment["ZDOTDIR"], inherited["ZDOTDIR"])
                    self.assertEqual(list(Path(environment["ZDOTDIR"]).iterdir()), [])
                    retained = {
                        "HOME",
                        "PATH",
                        "CARGO_HOME",
                        "RUSTUP_HOME",
                        "RUSTC_WRAPPER",
                        "SCCACHE_DIR",
                        "SCCACHE_CACHE_SIZE",
                        "ZDOTDIR",
                    }
                    for key in inherited.keys() - retained:
                        self.assertNotIn(key, environment)
                    if _kind in module.GATEWAY_ARTIFACT_KINDS:
                        bundle = _run / "artifacts" / module.gateway_bundle.NAME
                        binary = module.gateway_bundle.executable(bundle)
                        binary.parent.mkdir(parents=True)
                        binary.write_bytes(b"synthetic-gateway")
                        (bundle / "Contents/Info.plist").write_bytes(b"synthetic-info")
                        seal = bundle / "Contents/_CodeSignature/CodeResources"
                        seal.parent.mkdir()
                        seal.write_bytes(b"synthetic-seal")
                    if _kind == "mac-bench":
                        (_run / "bench.json").write_text("{}")
                    return 0

                with (
                    patch.dict(os.environ, inherited, clear=True),
                    patch.object(module.Path, "home", return_value=root),
                    patch.object(module, "build_capacity", return_value=nullcontext(0)),
                    patch.object(module, "local_worktrees", return_value=[]),
                    patch.object(
                        module,
                        "load_policy",
                        return_value=CachePolicy(
                            512, 259200, 172800, 7200, 80 * 1024**3, 2, 0, True, 86400
                        ),
                    ),
                    patch.object(module.subprocess, "run", side_effect=copy_snapshot),
                    patch.object(module, "run_owned", side_effect=run_recipe),
                ):
                    self.assertEqual(module.worker(run)["exitCode"], 0)

    def test_maintenance_reports_total_cap_overflow_then_clears_and_preserves_unknown(self):
        policy = CachePolicy(512, 259200, 172800, 7200, 64 * 1024, 2, 0, True, 86400)
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            source = home / "RemoteCoder"
            init_repository(source)
            root = home / "Library/Caches/RemoteCoder-Build"
            pinned = root / "releases/pinned/archive.bin"
            pinned.parent.mkdir(parents=True)
            pinned.write_bytes(b"p" * 256 * 1024)
            status_path = home / ".local/state/disk-cap-status/remotecoder-build.json"
            with (
                patch.object(Path, "home", return_value=home),
                patch.object(module, "ROOT", source),
                patch.object(module, "load_policy", return_value=policy),
                patch.object(sys, "argv", ["remote-build.py", "cache-maintain"]),
                redirect_stdout(io.StringIO()),
            ):
                with self.assertRaises(SystemExit) as overflow:
                    module.main()
                self.assertEqual(overflow.exception.code, 1)
                status = json.loads(status_path.read_text())
                self.assertTrue(status["unmet"])
                self.assertGreater(status["used_bytes"], status["cap_bytes"])
                self.assertTrue(pinned.exists())
                pinned.unlink()
                module.main()
                status = json.loads(status_path.read_text())
                self.assertFalse(status["unmet"])
                self.assertEqual(status["version"], 1)
                self.assertEqual(status["owner"], "remotecoder-build")
                self.assertTrue(status["observed_at"].endswith("+00:00"))
                with (
                    patch.object(module, "cache_allocated_bytes", side_effect=TimeoutError("du unavailable")),
                    self.assertRaises(SystemExit),
                ):
                    module.main()
                status = json.loads(status_path.read_text())
                self.assertIsNone(status["unmet"])
                self.assertIsNone(status["used_bytes"])
                self.assertEqual(status["reason"], "du unavailable")

    def test_local_lane_owns_private_paths_and_records_a_failed_build_completion(self):
        import fcntl

        from build_cache import compilation_record

        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            source = home / "repo"
            init_repository(source)
            tools = home / "bin"
            tools.mkdir()
            helper = tools / "just"
            helper.write_text(
                "#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\np=Path(os.environ['RC_DERIVED_DATA']);p.mkdir(parents=True)\ncargo=Path(os.environ['CARGO_TARGET_DIR']);cargo.mkdir(parents=True);cargo.joinpath('private-product').write_text('candidate')\np.joinpath('invocation.json').write_text(json.dumps({'args':sys.argv[1:],'owned':os.environ['RC_COMPILATION_OWNER'],'cargo':str(cargo)}))\nsys.exit(2)\n"
            )
            helper.chmod(0o755)
            policy = CachePolicy(
                512, 259200, 172800, 7200, 80 * 1024**3, 2, 0, False, 86400
            )
            with (
                patch.dict(
                    os.environ,
                    {
                        "HOME": str(home),
                        "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                    },
                    clear=True,
                ),
                patch.object(module, "ROOT", source),
                patch.object(module.Path, "home", return_value=home),
                patch.object(module, "load_policy", return_value=policy),
            ):
                source_lock = module.source_lease_path(source)
                self.assertEqual(module.local_build("mac-build", ["SETTING=value"]), 2)
            derived = source / "build/mac-build-derived"
            invocation = json.loads((derived / "invocation.json").read_text())
            self.assertEqual(
                invocation,
                {
                    "args": ["mac-build-local", "SETTING=value"],
                    "owned": "1",
                    "cargo": "host-daemon-rs/target",
                },
            )
            self.assertEqual(
                (source / "host-daemon-rs/target/private-product").read_text(),
                "candidate",
            )
            cache = home / "Library/Caches/RemoteCoder-Build"
            record = json.loads(compilation_record(cache, derived).read_text())
            self.assertFalse(record["active"])
            self.assertGreater(record["completedAt"], 0)
            receipts = list((cache / "runs").glob("*/receipt.json"))
            self.assertEqual(len(receipts), 1)
            self.assertEqual(json.loads(receipts[0].read_text())["exitCode"], 2)
            with source_lock.open("a") as available:
                fcntl.flock(available, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_optional_eviction_failure_keeps_manifest_and_allows_local_build(self):
        from build_cache import compilation_record

        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            source = home / "repo"
            init_repository(source)
            cache = home / "Library/Caches/RemoteCoder-Build"
            for i in range(3):
                directory = cache / "worktrees/other/ios" / ("derived-" + str(i))
                payload = directory / "Build/Intermediates.noindex"
                payload.mkdir(parents=True)
                (payload / "object.o").write_bytes(b"compiler" * 1024)
                record = compilation_record(cache, directory)
                record.parent.mkdir(parents=True, exist_ok=True)
                finished = time.time() - 2 * 86400 + i
                record.write_text(
                    json.dumps(
                        {
                            "path": str(directory),
                            "active": False,
                            "lastUsed": finished,
                            "completedAt": finished,
                        }
                    )
                )
            policy = CachePolicy(512, 259200, 172800, 7200, 1, 2, 0, True, 86400)
            with (
                patch.dict(os.environ, {"HOME": str(home)}, clear=True),
                patch.object(module, "ROOT", source),
                patch.object(module.Path, "home", return_value=home),
                patch.object(module, "load_policy", return_value=policy),
                patch("build_cache._open_files", return_value=False),
                patch(
                    "build_cache._evict_payload",
                    side_effect=PermissionError("fixture eviction denied"),
                ),
                patch.object(module, "run_owned", return_value=0),
            ):
                self.assertEqual(module.local_build("mac-build", []), 0)
            receipts = list((cache / "runs").glob("*/receipt.json"))
            self.assertEqual(len(receipts), 1)
            receipt = json.loads(receipts[0].read_text())
            self.assertEqual(receipt["exitCode"], 0)
            manifest = json.loads(
                (receipts[0].parent / "cache-admission.json").read_text()
            )
            self.assertEqual(manifest, receipt["compilationCache"])
            self.assertEqual(manifest["evicted"], [])
            self.assertEqual(len(manifest["evictionFailures"]), 3)
            self.assertFalse(manifest["inventoryComplete"])
            self.assertIn("warning", manifest)

    def test_real_bash_and_zsh_children_cannot_reload_synthetic_credentials(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            home = root / "home"
            home.mkdir()
            (home / ".zshenv").write_text("export GH_TOKEN_PERSONAL=fake-zsh-token\n")
            bash_startup = root / "bash-startup"
            bash_startup.write_text("export RC_PUSH_BROKER_TOKEN=fake-bash-token\n")
            inherited = {
                "HOME": str(home),
                "PATH": os.environ["PATH"],
                "BASH_ENV": str(bash_startup),
                "ENV": str(bash_startup),
                "ZDOTDIR": str(home),
                "GH_TOKEN_PERSONAL": "fake-inherited-token",
                "TS_AUTHKEY": "fake-tailnet-key",
            }
            # Prove both synthetic startup files would reload credentials.
            for shell, name, value in (
                ("bash", "RC_PUSH_BROKER_TOKEN", "fake-bash-token"),
                ("zsh", "GH_TOKEN_PERSONAL", "fake-zsh-token"),
            ):
                result = subprocess.run(
                    [shell, "-c", f'test "${{{name}}}" = {shlex.quote(value)}'],
                    env=inherited,
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(
                    result.returncode, 0,
                    f"{shell} ({shutil.which(shell, path=inherited['PATH'])}): "
                    f"stdout={result.stdout!r}, stderr={result.stderr!r}",
                )

            environment = module.build_environment("core-test", inherited, root)
            check = (
                "import os,sys; sys.exit(any(key in os.environ for key in "
                "('RC_PUSH_BROKER_TOKEN','GH_TOKEN_PERSONAL','TS_AUTHKEY','BASH_ENV','ENV')))"
            )
            logged = subprocess.run(
                [
                    str(HELPER.parent / "run-logged"),
                    "synthetic-env-check",
                    sys.executable,
                    "-c",
                    check,
                ],
                cwd=root,
                env=environment,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                check=False,
            )
            self.assertEqual(logged.returncode, 0)
            zsh = subprocess.run(
                ["zsh", "-c", shlex.join([sys.executable, "-c", check])],
                cwd=root,
                env=environment,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                check=False,
            )
            self.assertEqual(zsh.returncode, 0)

    def test_shell_credential_check_does_not_inherit_socket_stdin(self):
        left, right = socket.socketpair()
        with left, right:
            result = subprocess.run(
                [sys.executable, "-m", "unittest",
                 "test_remote_build.RemoteBuildTests.test_real_bash_and_zsh_children_cannot_reload_synthetic_credentials"],
                cwd=HELPER.parent / "tests",
                stdin=left,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_device_install_keeps_development_configuration_and_signing_inputs(self):
        inherited = {
            "REMOTE_CODER_GOOGLE_MAPS_API_KEY": "fake-maps-key",
            "APP_STORE_CONNECT_KEY_ID": "fake-signing-key-id",
            "APP_STORE_CONNECT_ISSUER_ID": "fake-signing-issuer-id",
            "APP_STORE_CONNECT_KEY_PATH": "/synthetic/signing-key.p8",
        }
        with tempfile.TemporaryDirectory() as temporary:
            environment = module.build_environment(
                "ios-install", inherited | {"UNRELATED_PRIVATE_CREDENTIAL": "sentinel"}, Path(temporary)
            )
            self.assertEqual({key: environment[key] for key in inherited}, inherited)
            self.assertNotIn("UNRELATED_PRIVATE_CREDENTIAL", environment)

    def test_worker_commands_pass_their_arguments_through_exactly(self):
        selectors = [
            "RemoteCoderTests/AccountIsolationTests",
            "RemoteCoderTests/ConversationHandoffTests",
        ]
        ui = ["RemoteCoderUITests/ReasoningPickerUITests"]
        install = ["--optimized", "--device", "synthetic-iphone"]
        for kind, arguments, command in (
            (
                "ios-simulator-test",
                selectors,
                ["just", "ios-simulator-test-local", *selectors],
            ),
            ("ios-ui-test", ui, ["just", "ios-ui-test-local", *ui]),
            ("ios-install", install, ["./scripts/install-device", *install]),
            ("ios-install", [], ["./scripts/install-device"]),
            ("mac-install", [], ["./scripts/install-mac"]),
            ("mac-bench", [], ["./scripts/install-mac", "--bench"]),
            ("mac-bench", ["--lab-config", "/tmp/private-lab/config.json"],
             ["./scripts/install-mac", "--bench", "--lab-config", "/tmp/private-lab/config.json"]),
            ("tools-test", [], ["just", "tools-test-local"]),
            ("verify", [], ["just", "verify-local"]),
            ("verify-all", [], ["just", "verify-all-local"]),
            ("release-gate", [], ["just", "release-gate-local"]),
        ):
            with self.subTest(kind=kind, arguments=arguments):
                self.assertEqual(module.build_command(kind, arguments), command)
        self.assertEqual(
            module.SIMULATOR_KINDS,
            {"ios-simulator-test", "ios-ui-test", "verify-all", "release-gate"},
        )

    def test_fingerprint_checks_file_contents_and_symlink_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / "file").write_text("first")
            (root / "link").symlink_to("file")
            initial = module.fingerprint(root, ["file", "link"])
            (root / "file").write_text("second")
            self.assertNotEqual(initial, module.fingerprint(root, ["file", "link"]))
            initial = module.fingerprint(root, ["file", "link"])
            (root / "link").unlink()
            (root / "link").symlink_to("elsewhere")
            self.assertNotEqual(initial, module.fingerprint(root, ["file", "link"]))

    def test_two_builds_of_one_worktree_do_not_overlap_mutable_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            bin_dir = root / "bin"
            bin_dir.mkdir()
            fake = bin_dir / "just"
            fake.write_text(
                "#!/usr/bin/env python3\nimport time\nfrom pathlib import Path\np=Path.home()/'order'\nname=Path('.xcode-version').read_text().strip()\nwith p.open('a') as f: f.write('start-'+name+'\\n')\ntime.sleep(0.1)\nassert Path('.xcode-version').read_text().strip()==name\nwith p.open('a') as f: f.write('end-'+name+'\\n')\n"
            )
            fake.chmod(0o755)
            environment = os.environ | {
                "HOME": str(root),
                "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
            }
            write_cache_policy(root)
            processes = []
            for name, kind in (("one", "verify"), ("two", "gateway-check")):
                run = root / name
                source, manifest = worker_snapshot(
                    run,
                    kind=kind,
                    worktree_id="shared",
                    build_id=name,
                    source_commit="synthetic",
                    xcode_version=name,
                    environment={},
                )
                processes.append(
                    subprocess.Popen(
                        [sys.executable, str(HELPER), "worker", str(run)],
                        env=environment,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                )
            for process in processes:
                output, error = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, output + error)
                self.assertEqual(json.loads(output)["exitCode"], 0)
            lines = (root / "order").read_text().splitlines()
            self.assertEqual(len(lines), 4)
            self.assertEqual(
                lines[0].replace("start-", ""), lines[1].replace("end-", "")
            )
            self.assertEqual(
                lines[2].replace("start-", ""), lines[3].replace("end-", "")
            )

    def test_local_installs_supply_provenance_and_preserve_worker_identity(self):
        for inherited in (False, True):
            with (
                self.subTest(inherited=inherited),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary).resolve()
                (root / ".xcode-version").write_text("27.0")
                manifest = {
                    "buildId": "synthetic-build",
                    "sourceCommit": "abc",
                    "sourceFingerprint": "def",
                }
                provenance = root / "worker-source.json"
                provenance.write_text(json.dumps(manifest))
                environment = {"HOME": str(root)}
                if inherited:
                    environment["RC_BUILD_PROVENANCE"] = str(provenance)

                def run(
                    command,
                    cwd,
                    env,
                    output,
                    leases,
                    manifest=manifest,
                    inherited=inherited,
                    provenance=provenance,
                ):
                    self.assertEqual(
                        command, ["./scripts/install-device", "--optimized"]
                    )
                    self.assertEqual(env["RC_INSTALL_SOURCE_LEASED"], "1")
                    self.assertEqual(
                        json.loads(Path(env["RC_BUILD_PROVENANCE"]).read_text()),
                        manifest,
                    )
                    if inherited:
                        self.assertEqual(env["RC_BUILD_PROVENANCE"], str(provenance))
                    return 0

                with (
                    patch.dict(os.environ, environment, clear=True),
                    patch.object(
                        module.socket, "gethostname", return_value="gateway-secondary"
                    ),
                    patch.object(module, "ROOT", root),
                    patch.object(
                        module.subprocess,
                        "check_output",
                        return_value="Xcode 27\nBuild version 27A-fixture\n",
                    ),
                    patch.object(
                        module, "source_manifest", return_value=manifest
                    ) as capture,
                    patch.object(module, "run_owned", side_effect=run),
                    patch.object(
                        sys, "argv", [str(HELPER), "local-install", "--optimized"]
                    ),
                    self.assertRaises(SystemExit) as exit_context,
                ):
                    module.main()
                self.assertEqual(exit_context.exception.code, 0)
                if inherited:
                    capture.assert_not_called()
                else:
                    capture.assert_called_once_with(
                        root, "ios-install", ["--optimized"]
                    )


class TransferLifecycleTests(unittest.TestCase):
    def test_tiny_snapshot_uses_real_ssh_and_rsync_to_the_selected_host(self):
        host = os.environ.get("RC_SSH_TEST_HOST")
        if not host:
            self.skipTest("Set RC_SSH_TEST_HOST for the isolated SSH transfer check")
        shell = [*module.SSH, host]
        try:
            ready = subprocess.run(
                [*shell, "true"],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            self.skipTest(f"SSH test host preflight unavailable: {type(error).__name__}")
        if ready.returncode:
            detail = ready.stderr.strip().splitlines()
            self.skipTest(
                "SSH test host preflight unavailable: "
                + (detail[0][:160] if detail else "nonzero SSH exit")
            )
        remote = subprocess.check_output(
            [
                *shell,
                "python3 -c 'import tempfile; print(tempfile.mkdtemp(prefix=\"rc-transfer-e2e-\"))'",
            ],
            text=True,
            timeout=10,
        ).strip()
        run = Path(remote) / "cache/runs/tiny"
        try:
            with tempfile.TemporaryDirectory() as temporary:
                source = Path(temporary)
                payload = b"real SSH and rsync fixture\n"
                (source / "payload").write_bytes(payload)
                manifest = {
                    "kind": "verify",
                    "arguments": [],
                    "files": ["payload"],
                    "sourceFingerprint": module.fingerprint(source, ["payload"]),
                }
                with (
                    patch.object(module, "ROOT", source),
                    patch.object(module, "source_manifest", return_value=manifest),
                ):
                    module.transfer_source(shell, host + ":", run, manifest)
                inspect = "import hashlib,json,pathlib,sys; run=pathlib.Path(sys.argv[1]); print(json.dumps({'payloadSHA256':hashlib.sha256(run.joinpath('repo/payload').read_bytes()).hexdigest(),'manifest':json.loads(run.joinpath('source.json').read_text())}))"
                result = json.loads(
                    subprocess.check_output(
                        [*shell, shlex.join(["python3", "-c", inspect, str(run)])],
                        text=True,
                        timeout=10,
                    )
                )
                self.assertEqual(
                    result["payloadSHA256"], module.hashlib.sha256(payload).hexdigest()
                )
                self.assertEqual(result["manifest"], manifest)
        finally:
            cleanup = "import fcntl,pathlib,shutil,sys; root=pathlib.Path(sys.argv[1]); lock=root/'cache/leases/runs/tiny.lock'; lock.parent.mkdir(parents=True,exist_ok=True); lease=lock.open('a'); fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB); shutil.rmtree(root)"
            result = subprocess.run(
                [*shell, shlex.join(["python3", "-c", cleanup, remote])],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                timeout=10,
                check=False,
            )
            self.assertEqual(
                result.returncode,
                0,
                "Owned transfer fixture cleanup deferred; inspect " + remote,
            )

    def test_known_source_change_and_rsync_failure_become_evictable_terminal_runs(self):
        from build_cache import prune_caches

        for failure in ("source-change", "rsync"):
            with (
                self.subTest(failure=failure),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary).resolve()
                source = root / "input"
                source.mkdir()
                (source / "payload").write_text("source")
                run = root / "cache/runs/failed"
                manifest = {
                    "kind": "verify",
                    "arguments": [],
                    "sourceFingerprint": "before",
                    "files": ["payload" if failure == "source-change" else "missing"],
                }
                with (
                    patch.object(module, "ROOT", source),
                    patch.object(
                        module,
                        "source_manifest",
                        return_value={"sourceFingerprint": "after"},
                    ),
                    self.assertRaises((ValueError, subprocess.CalledProcessError)),
                ):
                    module.transfer_source(["bash", "-c"], "", run, manifest)
                outcome = json.loads((run / "outcome.json").read_text())
                self.assertEqual(outcome["exitCode"], 1)
                self.assertEqual(outcome["phase"], "sourceTransfer")
                old = module.time.time() - 8 * 86400
                os.utime(run, (old, old))
                os.utime(
                    module.lease_path(run.parent.parent, "runs", run.name).with_suffix(
                        ".used"
                    ),
                    (old, old),
                )
                result = prune_caches(
                    run.parent.parent,
                    CachePolicy(
                        1, 259200, 172800, 7200, 80 * 1024**3, 2, 0, True, 86400
                    ),
                    "current",
                    "current",
                )
                self.assertEqual(result["runs"], ["failed"])

    def test_unavailable_failure_writer_preserves_unknown_inputs(self):
        from build_cache import prune_caches

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            run = root / "runs/unknown"
            (run / "repo").mkdir(parents=True)
            with patch.object(
                module.subprocess,
                "run",
                side_effect=subprocess.TimeoutExpired("ssh", 15),
            ):
                module.record_transfer_failure(["ssh", "unreachable"], run)
            old = module.time.time() - 8 * 86400
            os.utime(run, (old, old))
            result = prune_caches(
                root,
                CachePolicy(1, 259200, 172800, 7200, 80 * 1024**3, 2, 0, True, 86400),
                "current",
                "current",
            )
            self.assertEqual(result["unknownRuns"], ["unknown"])
            self.assertTrue((run / "repo").exists())

    def test_remote_transfer_receiver_keeps_ownership_through_transfer_and_cleanup(self):
        import fcntl
        import select

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            run = root / "cache/runs/receiver"
            module.prepare_transfer(["bash", "-c"], run, HELPER.parent)
            receiver = subprocess.Popen(
                [
                    sys.executable,
                    str(run / "rsync-receiver.py"),
                    str(run),
                    "--server",
                    "-r",
                    ".",
                    str(run / "repo"),
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                receiver.stdin.write((29).to_bytes(4, "little"))
                receiver.stdin.flush()
                self.assertTrue(select.select([receiver.stdout], [], [], 5)[0])
                self.assertEqual(len(receiver.stdout.read(4)), 4)
                self.assertIsNone(receiver.poll())
                if sys.platform == "darwin":
                    assertions = subprocess.check_output(["pmset", "-g", "assertions"], text=True, errors="replace", timeout=5)
                    self.assertTrue(any(f"pid {receiver.pid}(" in line and
                                        'PreventUserIdleSystemSleep named: "RemoteCoder owned job"' in line
                                        for line in assertions.splitlines()))
                with module.lease_path(run.parent.parent, "runs", run.name).open(
                    "a"
                ) as lease:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    receiver.terminate()
                    receiver.communicate(timeout=5)
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                if receiver.poll() is None:
                    receiver.kill()
                    receiver.communicate(timeout=5)


class ConnectedBuildTests(unittest.TestCase):
    def test_build_child_cannot_read_or_change_the_heartbeat_pipe(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary) / "runs/isolated-stdin"
            run.mkdir(parents=True)
            manifest = {
                "kind": "verify",
                "worktreeId": "isolated-stdin",
                "buildId": "isolated-stdin",
                "sourceCommit": "fixture",
                "sourceFingerprint": "fixture",
            }
            (run / "source.json").write_text(json.dumps(manifest))
            child = run / "child.py"
            child.write_text(
                "import json,os,sys\n"
                "from pathlib import Path\n"
                "os.set_blocking(0,False)\n"
                "try:\n"
                " value=os.read(0,1).hex()\n"
                "except BlockingIOError:\n"
                " value='would-block'\n"
                "Path(sys.argv[2]).joinpath('stdin.json').write_text(json.dumps(value))\n"
            )
            bootstrap = (
                "import importlib.util,sys; "
                "s=importlib.util.spec_from_file_location('remote',sys.argv[1]); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                "m.__file__=sys.argv[2]; "
                "sys.exit(m.connected_worker(m.Path(sys.argv[3])))"
            )
            reader, writer = os.pipe()
            with os.fdopen(reader, "rb") as heartbeat, os.fdopen(writer, "wb") as client:
                client.write(b".")
                client.flush()
                result = subprocess.run(
                    [sys.executable, "-c", bootstrap, str(HELPER), str(child), str(run)],
                    stdin=heartbeat,
                    capture_output=True,
                    text=True,
                    timeout=10,
                    check=False,
                )
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertTrue(os.get_blocking(heartbeat.fileno()))
            self.assertEqual(json.loads((run / "stdin.json").read_text()), "")

    def test_zero_exit_without_a_receipt_records_the_same_failure_returned_to_the_client(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary) / "runs/missing"
            run.mkdir(parents=True)
            manifest = {
                "kind": "verify",
                "worktreeId": "missing",
                "buildId": "missing",
                "sourceCommit": "fixture",
                "sourceFingerprint": "fixture",
            }
            (run / "source.json").write_text(json.dumps(manifest))
            bootstrap = "import importlib.util,sys; s=importlib.util.spec_from_file_location('remote',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.run_owned=lambda *args,**kwargs:0; sys.exit(m.connected_worker(m.Path(sys.argv[2])))"
            result = subprocess.run(
                [sys.executable, "-c", bootstrap, str(HELPER), str(run)],
                input="",
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(json.loads(result.stdout)["exitCode"], 1)
            self.assertEqual(
                json.loads((run / "outcome.json").read_text())["exitCode"], 1
            )

    def test_completed_worker_can_close_stdin_before_receipt_is_drained(self):
        result = module.run_connected(
            [
                sys.executable,
                "-c",
                "import os,time; os.close(0); print('receipt',flush=True); time.sleep(0.05)",
            ]
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "receipt\n")

    def test_client_interrupt_and_death_release_remote_work_and_leases(self):
        import fcntl
        import signal
        import time

        for signum, ignores_term in (
            (signal.SIGINT, False),
            (signal.SIGKILL, False),
            (signal.SIGINT, True),
            (None, False),
        ):
            with (
                self.subTest(signal=signum, ignores_term=ignores_term),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary).resolve()
                cache = root / "Library/Caches/RemoteCoder-Build"
                run = cache / "runs/owned"
                source, manifest = worker_snapshot(
                    run,
                    kind="verify",
                    worktree_id="owned",
                    build_id="owned",
                    source_commit="synthetic",
                    xcode_version="27.0",
                    environment={},
                )
                write_cache_policy(root)
                bin_dir = root / "bin"
                bin_dir.mkdir()
                fake = bin_dir / "just"
                fake.write_text(
                    "#!/usr/bin/env python3\nimport os,time,signal\nfrom pathlib import Path\n"
                    + (
                        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                        if ignores_term
                        else ""
                    )
                    + "Path.home().joinpath('started').write_text(str(os.getpid()))\ntime.sleep(60)\n"
                )
                fake.chmod(0o755)
                environment = os.environ | {
                    "HOME": str(root),
                    "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                }
                code = "import importlib.util,sys; s=importlib.util.spec_from_file_location('remote',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); r=m.run_connected([sys.executable,sys.argv[1],'connected-worker',sys.argv[2]]); sys.exit(r.returncode)"
                if signum is None:
                    code = "import importlib.util,sys; s=importlib.util.spec_from_file_location('remote',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); import build_support; build_support.CLIENT_LOST_SECONDS=2; sys.exit(m.connected_worker(m.Path(sys.argv[2])))"
                client = subprocess.Popen(
                    [sys.executable, "-c", code, str(HELPER), str(run)],
                    env=environment,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                try:
                    deadline = time.monotonic() + 60
                    while (
                        not (root / "started").exists() and time.monotonic() < deadline
                    ):
                        if signum is None:
                            client.stdin.write(b".")
                            client.stdin.flush()
                        time.sleep(0.01)
                    self.assertTrue((root / "started").exists())
                    if signum is None:
                        client.wait(timeout=60)
                    else:
                        client.send_signal(signum)
                    client.communicate(timeout=40)
                    deadline = time.monotonic() + 60
                    while (
                        not (run / "outcome.json").exists()
                        and time.monotonic() < deadline
                    ):
                        time.sleep(0.02)
                    outcome = json.loads((run / "outcome.json").read_text())
                    self.assertNotEqual(outcome["exitCode"], 0)
                    for lock in (
                        cache / "capacity/0.lock",
                        cache / "leases/worktrees/owned.lock",
                        cache / "worktrees/owned/ios/build.lock",
                        cache / "worktrees/owned/gateway/build.lock",
                    ):
                        with lock.open("a") as available:
                            fcntl.flock(available, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    pid = int((root / "started").read_text())
                    state = subprocess.run(
                        ["ps", "-p", str(pid), "-o", "stat="],
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertTrue(
                        state.returncode != 0 or state.stdout.strip().startswith("Z"),
                        state.stdout,
                    )
                finally:
                    if client.poll() is None:
                        client.kill()
                        client.communicate(timeout=5)

    def test_startup_failure_returns_one_failure_receipt_with_worker_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary) / "runs/invalid"
            (run / "repo").mkdir(parents=True)
            manifest = {
                "kind": "mac-build",
                "worktreeId": "invalid",
                "buildId": "invalid",
                "sourceCommit": "abc",
                "sourceFingerprint": "wrong",
                "files": [],
            }
            (run / "source.json").write_text(json.dumps(manifest))
            with subprocess.Popen(
                [sys.executable, str(HELPER), "connected-worker", str(run)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            ) as process:
                process.stdin.write(".")
                process.stdin.flush()
                process.wait(timeout=60)
                output, error = process.communicate()
                self.assertNotEqual(process.returncode, 0, error)
            receipt = json.loads(output)
            self.assertNotEqual(receipt["exitCode"], 0)
            self.assertIn("fingerprint", Path(receipt["log"]).read_text())
