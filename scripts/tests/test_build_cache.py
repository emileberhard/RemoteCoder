import fcntl
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_cache import (
    CachePolicy,
    lease_path,
    prune_caches,
    seed_cargo,
    seed_source_packages,
)
from git_fixtures import init_repository, point_origin_main_at_head


class CacheAdmissionTests(unittest.TestCase):
    def test_package_retention_keeps_two_clean_seeds_and_preserves_dirty_unknown_and_leased_trees(
        self,
    ):
        import json
        import shutil
        import subprocess
        from build_cache import compilation_admission

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            origin = root / "dependency"
            init_repository(origin)
            (origin / "source").write_text("dependency")
            (origin / "source\nS name").write_text("tracked unusual filename")
            subprocess.run(
                ["git", "add", "."], cwd=origin, check=True, capture_output=True
            )
            subprocess.run(
                ["git", "commit", "-m", "dependency"],
                cwd=origin,
                check=True,
                capture_output=True,
            )
            revision = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=origin, text=True
            ).strip()
            old = time.time() - 86400
            entries = [
                self.entry(root, "derived", old + i, tree=str(i)) for i in range(8)
            ]
            for entry in entries:
                checkout = entry.path / "SourcePackages/checkouts/dependency"
                shutil.copytree(origin, checkout)
                resolution = (
                    entry.path.parent
                    / "repo/RemoteCoder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
                )
                resolution.parent.mkdir(parents=True)
                resolution.write_text(
                    json.dumps(
                        {
                            "pins": [
                                {
                                    "identity": "dependency",
                                    "state": {"revision": revision},
                                }
                            ]
                        }
                    )
                )
            (entries[3].path / "SourcePackages/checkouts/dependency/source").write_text(
                "personal edit"
            )
            (
                entries[4].path.parent
                / "repo/RemoteCoder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            ).unlink()
            for entry, flag in zip(entries[6:], ("--assume-unchanged", "--skip-worktree")):
                checkout = entry.path / "SourcePackages/checkouts/dependency"
                subprocess.run(["git", "-C", str(checkout), "update-index", flag, "source"], check=True)
                (checkout / "source").write_text("hidden personal edit")
                self.assertEqual(subprocess.check_output(["git", "-C", str(checkout), "status", "--porcelain"]), b"")
            held = entries[5].leases[0]
            held.parent.mkdir(parents=True, exist_ok=True)
            with (
                held.open("a") as lease,
                patch("build_cache._open_file_snapshot", return_value=([], None)),
            ):
                fcntl.flock(lease, fcntl.LOCK_EX)
                result = compilation_admission(
                    root, self.policy(), entries, set(), preview=False
                )
            self.assertFalse((entries[0].path / "SourcePackages").exists())
            for entry in entries[1:]:
                self.assertTrue((entry.path / "SourcePackages").exists())
            self.assertEqual(
                (
                    entries[3].path / "SourcePackages/checkouts/dependency/source"
                ).read_text(),
                "personal edit",
            )
            for entry in entries[6:]:
                self.assertEqual((entry.path / "SourcePackages/checkouts/dependency/source").read_text(), "hidden personal edit")
            self.assertTrue(
                any(
                    item["path"].endswith("SourcePackages")
                    for item in result["evicted"]
                )
            )

    def test_snapshot_retirement_preserves_references_activity_recent_children_and_unknown_layouts(
        self,
    ):
        import subprocess
        from build_cache import _retire_snapshots

        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            root = home / "Library/Caches/RemoteCoder-Build"
            root.mkdir(parents=True)
            old = time.time() - 8 * 86400
            paths = {}
            for name in ("expired", "pinned", "opened", "recent", "unknown"):
                path = root / "rollback" / name
                path.mkdir(parents=True)
                (path / "remote-coder-codex-gateway").write_text("binary")
                os.utime(path / "remote-coder-codex-gateway", (old, old))
                os.utime(path, (old, old))
                paths[name] = path
            (paths["recent"] / "remote-coder-codex-gateway").touch()
            (paths["unknown"] / "personal").write_text("unclassified")
            pointer = home / "localbin/remote-coder-gateway/current"
            pointer.parent.mkdir(parents=True)
            pointer.symlink_to(paths["pinned"], target_is_directory=True)
            job = subprocess.CompletedProcess([], 0, "state = not running\n", "")
            with (
                patch("build_cache.subprocess.run", return_value=job),
                patch(
                    "build_cache._open_file_snapshot",
                    return_value=(
                        [
                            str(
                                paths["opened"] / "remote-coder-codex-gateway"
                            ).casefold()
                        ],
                        None,
                    ),
                ),
            ):
                preview = _retire_snapshots(root, preview=True)
                self.assertEqual(preview["candidates"], [str(paths["expired"])])
                self.assertTrue(paths["expired"].exists())
                result = _retire_snapshots(root, preview=False)
            self.assertEqual(result["removed"], [str(paths["expired"])])
            for name in ("pinned", "opened", "recent", "unknown"):
                self.assertTrue(paths[name].exists())

    def test_public_cache_defaults_are_bounded_and_allow_rebuildable_eviction(self):
        from build_cache import load_policy

        with tempfile.TemporaryDirectory() as temporary:
            with patch("build_cache.Path.home", return_value=Path(temporary)):
                policy = load_policy()
            self.assertEqual(policy.compilation_budget_bytes, 40 * 1024**3)
            self.assertEqual(policy.evidence_protection_seconds, 48 * 3600)
            self.assertTrue(policy.eviction_enabled)

    def test_activation_is_separate_from_the_legacy_eviction_flag(self):
        import json

        from build_cache import load_policy

        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            source = home / "configs/build/compilation-cache-policy.json"
            source.parent.mkdir(parents=True)
            source.write_text(
                json.dumps(
                    {
                        "maxRuns": 512,
                        "runRetentionDays": 3,
                        "evidenceProtectionHours": 48,
                        "compilerProtectionHours": 2,
                        "compilationBudgetGiB": 80,
                        "retainedCompletedDirectories": 2,
                        "evictionTargetFreeGiB": 100,
                        "evictionEnabled": True,
                        "retiredWorktreeIdleHours": 24,
                    }
                )
            )
            activation = source.with_name("compilation-cache-eviction.json")
            with patch("build_cache.Path.home", return_value=home):
                self.assertFalse(load_policy().eviction_enabled)
                activation.write_text("true")
                self.assertTrue(load_policy().eviction_enabled)
                activation.write_text('"true"')
                with self.assertRaisesRegex(ValueError, "activation"):
                    load_policy()

    def test_host_budget_override_keeps_other_hosts_on_the_shared_budget(self):
        import json

        from build_cache import read_policy

        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "policy.json"
            values = {
                "maxRuns": 128, "runRetentionDays": 3, "evidenceProtectionHours": 48,
                "compilerProtectionHours": 2, "compilationBudgetGiB": 80,
                "retainedCompletedDirectories": 2, "evictionTargetFreeGiB": 20,
                "evictionEnabled": True, "retiredWorktreeIdleHours": 24,
                "hostCompilationBudgetGiB": {"small-host": 30},
            }
            source.write_text(json.dumps(values))
            for host, expected in (("small-host.local", 30), ("other-host", 80)):
                with patch("build_cache.socket.gethostname", return_value=host):
                    self.assertEqual(read_policy(source).compilation_budget_bytes, expected * 1024**3)
            values["hostCompilationBudgetGiB"]["small-host"] = True
            source.write_text(json.dumps(values))
            with self.assertRaisesRegex(ValueError, "host compilation budgets"):
                read_policy(source)

    def policy(self, *, enabled=True, budget=1, retained=2, free_target=0):
        return CachePolicy(
            1, 259200, 172800, 7200, budget, retained, free_target, enabled, 86400
        )

    def entry(self, root, name, completed, tree="tree"):
        import json

        from build_cache import CompilationDirectory, compilation_record

        path = root / "worktrees" / tree / "ios" / name
        payload = path / "Build/Intermediates.noindex"
        payload.mkdir(parents=True)
        (payload / "object.o").write_bytes(b"compiler" * 1024)
        product = path / "Build/Products/RemoteCoder.app"
        product.mkdir(parents=True)
        (product / "binary").write_text("product")
        lock = lease_path(root, "worktrees", tree)
        record = compilation_record(root, path)
        record.parent.mkdir(parents=True, exist_ok=True)
        record.write_text(
            json.dumps(
                {
                    "path": str(path),
                    "active": False,
                    "completedAt": completed,
                    "lastUsed": completed,
                }
            )
        )
        return CompilationDirectory(path, tree, (lock,), None, "xcode")

    def test_budget_overrides_newest_retention_but_preserves_products_and_evidence(
        self,
    ):
        from build_cache import compilation_admission

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            old = time.time() - 86400
            entries = [
                self.entry(root, "derived-" + str(i), old + i, tree=str(i))
                for i in range(4)
            ]
            for entry in entries:
                (entry.path / "Build/Products/RemoteCoder.app.dSYM").mkdir()
                (entry.path / "receipt.json").write_text("evidence")
            with patch("build_cache._open_files", return_value=False):
                result = compilation_admission(
                    root, self.policy(), list(reversed(entries)), set(), preview=False
                )
            self.assertEqual(
                [Path(v["path"]).parents[1].name for v in result["evicted"]],
                ["derived-0", "derived-1", "derived-2", "derived-3"],
            )
            self.assertGreater(result["unsatisfiedBudgetBytes"], 0)
            for index, entry in enumerate(entries):
                self.assertEqual(
                    (entry.path / "Build/Intermediates.noindex").exists(), False
                )
                self.assertEqual(
                    (entry.path / "Build/Products/RemoteCoder.app/binary").read_text(),
                    "product",
                )
                self.assertTrue(
                    (entry.path / "Build/Products/RemoteCoder.app.dSYM").is_dir()
                )
                self.assertEqual((entry.path / "receipt.json").read_text(), "evidence")

    def test_pressure_reclaims_only_products_with_available_unmodified_source(self):
        import json
        from dataclasses import replace

        from build_cache import compilation_admission, compilation_record, record_compilation

        for case in ("rebuildable", "modified", "missing-commit", "evidence"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                repository = Path(temporary).resolve() / "repository"
                commit = init_repository(repository)
                root = repository / "cache"
                entry = replace(self.entry(root, "derived", time.time() - 10800), source=repository)
                record_compilation(root, [entry.path], "finished", False, {
                    "sourceCommit": "0" * 40 if case == "missing-commit" else commit,
                    "sourceModified": case == "modified",
                })
                record = compilation_record(root, entry.path)
                completion = json.loads(record.read_text())
                completion["completedAt"] = completion["lastUsed"] = time.time() - 10800
                record.write_text(json.dumps(completion))
                products = entry.path / "Build/Products"
                if case == "evidence":
                    (products / "receipt.json").write_text("retained proof")
                (entry.path / "source.json").write_text("source identity")
                with patch("build_cache._open_file_snapshot", return_value=([], None)):
                    result = compilation_admission(root, self.policy(), [entry], set(), preview=False)
                self.assertEqual(products.exists(), case != "rebuildable")
                self.assertEqual((entry.path / "source.json").read_text(), "source identity")
                self.assertEqual(
                    any(Path(candidate["path"]) == products for candidate in result["evicted"]),
                    case == "rebuildable",
                )
                if case == "evidence":
                    self.assertEqual((products / "receipt.json").read_text(), "retained proof")

    def test_rebuildable_products_remain_without_cache_pressure(self):
        import json
        from dataclasses import replace

        from build_cache import compilation_admission, compilation_record, record_compilation

        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary).resolve() / "repository"
            commit = init_repository(repository)
            root = repository / "cache"
            entry = replace(self.entry(root, "derived", time.time() - 10800), source=repository)
            record_compilation(root, [entry.path], "finished", False, {
                "sourceCommit": commit, "sourceModified": False,
            })
            record = compilation_record(root, entry.path)
            completion = json.loads(record.read_text())
            completion["completedAt"] = completion["lastUsed"] = time.time() - 10800
            record.write_text(json.dumps(completion))
            with patch("build_cache._open_file_snapshot", return_value=([], None)):
                result = compilation_admission(root, self.policy(budget=1 << 30), [entry], set(), preview=False)
            self.assertEqual(result["evicted"], [])
            self.assertTrue((entry.path / "Build/Products/RemoteCoder.app/binary").exists())

    def test_total_cap_counts_pinned_and_unclassified_subowners(self):
        from build_cache import cache_allocated_bytes, compilation_admission

        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            root = base / "RemoteCoder-Build"
            entry = self.entry(root, "derived-newest", time.time() - 86400)
            pinned = []
            for owner in ("experiments", "releases/pinned", "runs/active", "codex-runtime/packages"):
                path = root / owner / "preserve.bin"
                path.parent.mkdir(parents=True)
                path.write_bytes(b"p" * 128 * 1024)
                pinned.append(path)
            outside = base / "outside.bin"
            outside.write_bytes(b"e" * 2 * 1024 * 1024)
            with patch("build_cache._open_files", return_value=False):
                result = compilation_admission(
                    root, self.policy(budget=256 * 1024), [entry], set(), preview=False,
                    root_bytes=cache_allocated_bytes(root)
                )
            self.assertGreaterEqual(result["rootAllocatedBytes"], 512 * 1024)
            self.assertLess(result["rootAllocatedBytes"], outside.stat().st_size)
            self.assertEqual(len(result["evicted"]), 1)
            self.assertGreater(result["unsatisfiedBudgetBytes"], 0)
            self.assertTrue(all(path.exists() for path in pinned))

    def test_hardlinked_payload_does_not_prematurely_satisfy_the_total_cap(self):
        from build_cache import cache_allocated_bytes, compilation_admission

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            first = self.entry(root, "derived-first", time.time() - 86400)
            second = self.entry(root, "derived-second", time.time() - 80000, tree="other")
            for entry in (first, second):
                (entry.path / "Build/Intermediates.noindex/object.o").write_bytes(b"c" * 256 * 1024)
            product = root / "releases/pinned"
            product.parent.mkdir()
            os.link(first.path / "Build/Intermediates.noindex/object.o", product)
            before = cache_allocated_bytes(root)
            with patch("build_cache._open_files", return_value=False):
                result = compilation_admission(
                    root, self.policy(budget=before - 128 * 1024),
                    [first, second], set(), preview=False, root_bytes=before,
                )
            self.assertEqual(len(result["evicted"]), 2)
            self.assertLessEqual(cache_allocated_bytes(root), result["budgetBytes"])
            self.assertEqual(result["unsatisfiedBudgetBytes"], 0)
            self.assertEqual(result["remainingBytes"], cache_allocated_bytes(root))
            self.assertEqual(product.stat().st_size, 256 * 1024)

    def test_shared_codex_targets_use_their_real_owner_lock_and_open_file_boundary(self):
        from build_cache import (
            cache_allocated_bytes,
            compilation_admission,
            shared_compilation_directories,
        )
        from build_support import file_lease

        for owner in ("codex-fork-check", "codex-runtime"):
            with self.subTest(owner=owner), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                target = root / owner / "target"
                deps = target / "aarch64-apple-darwin/release/deps"
                deps.mkdir(parents=True)
                (deps / "compiler.o").write_bytes(b"c" * 64 * 1024)
                package = root / owner / "packages/retained"
                package.parent.mkdir()
                package.write_bytes(b"product")
                lock = root / owner / "build.lock"
                lock.touch()
                old = time.time() - 3 * 86400
                for path in (target, deps, lock):
                    os.utime(path, (old, old))
                entries = shared_compilation_directories(root)
                self.assertEqual(len(entries), 1)
                with file_lease(lock):
                    result = compilation_admission(root, self.policy(), entries, set(), preview=False, root_bytes=cache_allocated_bytes(root))
                self.assertEqual(result["protected"][0]["reason"], "leased")
                self.assertTrue(deps.exists())
                with (deps / "compiler.o").open("rb"):
                    result = compilation_admission(root, self.policy(), entries, set(), preview=False, root_bytes=cache_allocated_bytes(root))
                self.assertTrue(deps.exists())
                self.assertIn("open-files", [item["reason"] for item in result["protected"]])
                result = compilation_admission(root, self.policy(), entries, set(), preview=False, root_bytes=cache_allocated_bytes(root))
                self.assertEqual(len(result["evicted"]), 1)
                self.assertFalse(deps.exists())
                self.assertEqual(package.read_bytes(), b"product")

    def test_each_protection_guard_preserves_its_own_eligible_cache(self):
        import json
        from contextlib import nullcontext

        from build_cache import compilation_admission, compilation_record

        for guard in ("active", "unknown", "recent", "current", "leased"):
            with self.subTest(guard=guard), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                old = time.time() - 86400
                entry = self.entry(
                    root,
                    "derived-case",
                    time.time() - 100 if guard == "recent" else old,
                )
                controls = [
                    self.entry(root, "derived-control-" + str(i), time.time() - 2 + i)
                    for i in range(2)
                ]
                record = compilation_record(root, entry.path)
                if guard == "active":
                    value = json.loads(record.read_text())
                    value["active"] = True
                    record.write_text(json.dumps(value))
                elif guard == "unknown":
                    record.unlink()
                entry.leases[0].parent.mkdir(parents=True, exist_ok=True)
                with (
                    entry.leases[0].open("a")
                    if guard == "leased"
                    else nullcontext() as held,
                    patch("build_cache._open_files", return_value=False),
                ):
                    if held is not None:
                        fcntl.flock(held, fcntl.LOCK_EX)
                    result = compilation_admission(
                        root,
                        self.policy(),
                        [entry, *controls],
                        {entry.path} if guard == "current" else set(),
                        preview=False,
                    )
                self.assertTrue(
                    (entry.path / "Build/Intermediates.noindex/object.o").exists()
                )
                reasons = {p["path"]: p["reason"] for p in result["protected"]}
                expected = (
                    "unknown-completion" if guard in ("active", "unknown") else guard
                )
                self.assertEqual(reasons[str(entry.path)], expected)
                self.assertGreater(result["unsatisfiedBudgetBytes"], 0)

    def test_inventory_distinguishes_completion_coverage_from_allocation_deadlines(
        self,
    ):
        import json
        from contextlib import nullcontext
        from functools import partial
        from unittest.mock import Mock

        import build_cache
        from build_cache import compilation_admission, compilation_record

        expected = {
            "complete": ("complete", None, None, "complete"),
            "active": ("active", None, None, "complete"),
            "invalid": ("invalid", None, None, "complete"),
            "unreadable": ("unreadable", None, None, "complete"),
            "missing": ("missing", "no-associated-uses", None, "complete"),
            "deadline": ("missing", "not-evaluated", None, "deadline"),
            "historical": ("missing", "complete", "not-proven", "complete"),
            "retirement-deadline": ("missing", "complete", "deadline", "complete"),
        }

        def exhaust_inventory(clock, history, *arguments):
            completion = history(*arguments)
            clock.return_value = 21
            return completion

        for state, coverage in expected.items():
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                entry = self.entry(root, "derived-case", time.time() - 3 * 86400)
                record = compilation_record(root, entry.path)
                if state in ("active", "invalid"):
                    value = json.loads(record.read_text())
                    value["active" if state == "active" else "path"] = (
                        True if state == "active" else "different"
                    )
                    record.write_text(json.dumps(value))
                elif state == "unreadable":
                    record.write_text("{")
                elif state in (
                    "missing",
                    "deadline",
                    "historical",
                    "retirement-deadline",
                ):
                    record.unlink()
                if state in ("historical", "retirement-deadline"):
                    entry = type(entry)(
                        entry.path, "mirror:tree", entry.leases, None, "cargo"
                    )
                    run = root / "runs/build"
                    run.mkdir(parents=True)
                    (run / "source.json").write_text(
                        json.dumps(
                            {
                                "worktreeId": "tree",
                                "sourceCommit": "unavailable",
                                "sourceModified": False,
                            }
                        )
                    )
                    (run / "receipt.json").write_text("{}")
                    (run / "outcome.json").write_text(
                        json.dumps({"exitCode": 0, "finishedAt": time.time() - 86400})
                    )
                clock = Mock(return_value=0)
                original_history = build_cache._historical_completion

                with (
                    patch("build_cache.Path.home", return_value=root),
                    patch("build_cache._open_files", return_value=False),
                    patch("build_cache.time.monotonic", side_effect=clock)
                    if state == "retirement-deadline"
                    else nullcontext(),
                    patch(
                        "build_cache._historical_completion",
                        side_effect=partial(exhaust_inventory, clock, original_history),
                    )
                    if state == "retirement-deadline"
                    else nullcontext(),
                    patch(
                        "build_cache._retired_worktree",
                        side_effect=AssertionError("Skipped Git check ran"),
                    )
                    if state == "retirement-deadline"
                    else nullcontext(),
                    patch("build_cache._allocated_bytes", side_effect=TimeoutError)
                    if state == "deadline"
                    else nullcontext(),
                ):
                    result = compilation_admission(
                        root, self.policy(enabled=False), [entry], set(), preview=True
                    )
                item = result["inventory"][0]
                self.assertEqual(item["path"], str(entry.path))
                self.assertEqual(item["kind"], entry.kind)
                evidence = item["completionCoverage"]
                self.assertEqual(
                    (
                        evidence["record"],
                        evidence["historical"],
                        evidence["sourceRetirement"],
                        item["allocationCoverage"],
                    ),
                    coverage,
                )
                if state == "deadline":
                    self.assertIsNone(item["allocatedBytes"])
                else:
                    self.assertGreater(item["allocatedBytes"], 0)
                self.assertTrue((entry.path / "Build/Intermediates.noindex").exists())

    def test_slow_inventory_leaves_a_fresh_reclamation_budget(self):
        import build_cache

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            entry = self.entry(root, "derived-idle", time.time() - 86400)
            clock = [0]
            allocate = build_cache._allocated_bytes

            def slow_allocation(*arguments):
                size = allocate(*arguments)
                clock[0] = 21
                return size

            with (
                patch("build_cache.time.monotonic", side_effect=lambda: clock[0]),
                patch("build_cache._allocated_bytes", side_effect=slow_allocation),
                patch("build_cache._open_files", return_value=False),
            ):
                result = build_cache.compilation_admission(
                    root, self.policy(), [entry], set(), preview=False
                )
            self.assertEqual(len(result["evicted"]), 1)
            self.assertFalse((entry.path / "Build/Intermediates.noindex").exists())
            self.assertTrue((entry.path / "Build/Products/RemoteCoder.app/binary").exists())

    def test_contended_maintenance_and_one_slow_tree_do_not_starve_other_worktrees(self):
        from contextlib import contextmanager

        import build_cache
        from build_support import file_lease

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            entries = [
                self.entry(root, "derived-cache", time.time() - 3 * 3600, tree=str(index))
                for index in range(131)
            ]
            clock = [0]
            allocate = build_cache._allocated_bytes
            real_try_lease = build_cache.try_lease

            @contextmanager
            def contended_lease(path):
                with real_try_lease(path) as lease:
                    if path.name == "maintenance.lock":
                        clock[0] += 25
                    yield lease

            def one_slow_tree(path, deadline, device):
                if path == entries[0].path:
                    clock[0] = max(clock[0], deadline)
                    raise TimeoutError("One compiler tree exhausted its inventory slice")
                return allocate(path, deadline, device)

            with (
                file_lease(entries[-1].leases[0]),
                patch("build_cache.try_lease", side_effect=contended_lease),
                patch("build_cache.time.monotonic", side_effect=lambda: clock[0]),
                patch("build_cache._allocated_bytes", side_effect=one_slow_tree),
                patch("build_cache._open_file_snapshot", return_value=([], None)) as snapshot,
                patch("build_cache._open_files", return_value=False),
            ):
                result = build_cache.compilation_admission(
                    root, self.policy(), entries, set(), preview=False
                )
            self.assertEqual(len(result["evicted"]), 129)
            self.assertEqual(snapshot.call_count, 1)
            self.assertIn("leased", [item["reason"] for item in result["protected"]])
            self.assertIsNone(result["allocatedBytes"])
            self.assertIsNone(result["inventory"][0]["allocatedBytes"])
            self.assertEqual(result["inventory"][0]["allocationCoverage"], "deadline")
            for index, entry in enumerate(entries):
                self.assertEqual(
                    (entry.path / "Build/Intermediates.noindex/object.o").exists(),
                    index in (0, 130),
                )
                self.assertEqual(
                    (entry.path / "Build/Products/RemoteCoder.app/binary").read_text(),
                    "product",
                )

    def test_native_inventory_timeout_retains_completed_children_without_a_root_total(self):
        import subprocess

        import build_cache
        from build_cache import cache_inventory, compilation_admission

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            entry = self.entry(root, "derived-old", time.time() - 3 * 3600)
            deeper = self.entry(root, "derived-deeper", time.time() - 3 * 3600, tree="nested/deeper")
            native_run = subprocess.run

            def interrupted_scan(*args, **kwargs):
                measured = native_run(*args, **kwargs)
                children = b"\n".join(measured.stdout.splitlines()[:-1]) + b"\n"
                raise subprocess.TimeoutExpired(args[0], 120, output=children)

            with patch("build_cache.subprocess.run", side_effect=interrupted_scan):
                inventory = cache_inventory(root)
            self.assertIsNone(inventory.allocated_bytes)
            self.assertIn("timed out", inventory.error)
            self.assertGreater(inventory.directories[entry.path], 0)
            self.assertNotIn(deeper.path, inventory.directories)
            allocate = build_cache._allocated_bytes

            def payload_allocation(path, *args):
                if path == entry.path:
                    raise AssertionError("Native directory inventory was repeated")
                return allocate(path, *args)

            with (
                patch("build_cache._open_files", return_value=False),
                patch("build_cache._allocated_bytes", side_effect=payload_allocation),
            ):
                result = compilation_admission(
                    root, self.policy(), [entry, deeper], set(), preview=True,
                    directory_bytes=inventory.directories,
                )
            self.assertEqual(len(result["candidates"]), 2)
            self.assertTrue(result["inventoryComplete"])
            self.assertTrue((entry.path / "Build/Intermediates.noindex/object.o").exists())

    def test_candidate_leases_are_released_after_deadline_probe_failure_and_exception(self):
        from contextlib import nullcontext

        import build_cache

        for failure in ("deadline", "probe-error", "exception"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                entries = [self.entry(root, "derived-cache", time.time() - 3 * 3600, tree=str(index)) for index in range(2)]
                clock = [0]
                check_open = build_cache._open_files

                def slow_probe(path, snapshot):
                    clock[0] = 21
                    return check_open(path, snapshot)

                with (
                    patch("build_cache.time.monotonic", side_effect=lambda: clock[0]),
                    patch("build_cache._open_file_snapshot", side_effect=OSError("probe failed"))
                    if failure == "exception"
                    else patch("build_cache._open_file_snapshot", return_value=([], "probe-error" if failure == "probe-error" else None)),
                    patch("build_cache._open_files", side_effect=slow_probe) if failure == "deadline" else nullcontext(),
                    self.assertRaisesRegex(OSError, "probe failed") if failure == "exception" else nullcontext(),
                ):
                    result = build_cache.compilation_admission(root, self.policy(), entries, set(), preview=False)
                    self.assertEqual(result["evicted"], [])
                for entry in entries:
                    with build_cache.try_lease(entry.leases[0]) as lease:
                        self.assertIsNotNone(lease)
                    self.assertTrue((entry.path / "Build/Intermediates.noindex/object.o").exists())

    def test_owned_legacy_lock_does_not_change_retired_mirror_eviction_priority(self):
        from build_cache import CompilationDirectory, cache_allocated_bytes, compilation_admission

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            retired = self.entry(root, "derived-retired", time.time() - 3 * 86400, tree="retired")
            live = self.entry(root, "derived-live", time.time() - 4 * 86400, tree="live")
            legacy = retired.path.parent / "build.lock"
            legacy.touch()
            retired = CompilationDirectory(retired.path, "mirror:retired", (*retired.leases, legacy), None, retired.kind)
            payload = retired.path / "Build/Intermediates.noindex"
            reclaimable = sum(p.stat().st_blocks * 512 for p in (payload, payload / "object.o"))
            budget = cache_allocated_bytes(root) - reclaimable
            with (
                patch("build_cache._retired_worktree", side_effect=lambda root, entry, completion: entry == retired),
                patch("build_cache._open_file_snapshot", return_value=([str(legacy)], None)),
            ):
                result = compilation_admission(root, self.policy(budget=budget), [live, retired], set(), preview=False, root_bytes=budget + reclaimable)
            self.assertEqual([item["worktree"] for item in result["evicted"]], ["mirror:retired"])
            self.assertFalse(payload.exists())
            self.assertTrue((live.path / "Build/Intermediates.noindex/object.o").exists())

    def test_mirror_discovery_and_snapshot_leave_a_fresh_reclamation_budget(self):
        import build_cache

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            mirrors = []
            old = time.time() - 8 * 86400
            for identity in ("first", "second"):
                mirror = root / "worktrees" / identity
                repo = mirror / "ios/repo"
                repo.mkdir(parents=True)
                (repo / "source.swift").write_text("rebuildable snapshot")
                for path in (mirror, repo):
                    os.utime(path, (old, old))
                mirrors.append(repo)
            clock = [0]

            def source_probe(*args, **kwargs):
                clock[0] += 5
                return True

            def snapshot():
                clock[0] += 14
                return [], None

            with (
                patch("build_cache.time.monotonic", side_effect=lambda: clock[0]),
                patch("build_cache._removed_mirror_source", side_effect=source_probe),
                patch("build_cache._open_file_snapshot", side_effect=snapshot),
            ):
                result = prune_caches(root, self.policy(), "", "")
            self.assertEqual({item["path"] for item in result["mirrors"]}, {str(path) for path in mirrors})
            self.assertTrue(all(not path.exists() for path in mirrors))

    def test_reclamation_deadline_preserves_payloads_and_reports_skipped_checks(self):
        from build_cache import compilation_admission

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            entries = [
                self.entry(root, "derived-first", time.time() - 86400),
                self.entry(root, "derived-second", time.time() - 80000, tree="other"),
            ]
            clock = [0]

            def slow_open_probe(path, snapshot):
                clock[0] = 21
                return False

            with (
                patch("build_cache.time.monotonic", side_effect=lambda: clock[0]),
                patch("build_cache._open_files", side_effect=slow_open_probe),
            ):
                result = compilation_admission(
                    root, self.policy(), entries, set(), preview=False
                )
            self.assertEqual(result["evicted"], [])
            self.assertEqual(
                [item["reason"] for item in result["protected"]],
                ["reclamation-deadline", "reclamation-deadline"],
            )
            for entry in entries:
                self.assertTrue((entry.path / "Build/Intermediates.noindex/object.o").exists())

    def test_real_open_file_protects_a_cache_without_any_held_lease(self):
        from build_cache import compilation_admission

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            entry = self.entry(root, "derived-open", time.time() - 86400)
            controls = [
                self.entry(root, "derived-control-" + str(i), time.time() - 2 + i)
                for i in range(2)
            ]
            payload = entry.path / "Build/Intermediates.noindex/object.o"
            with payload.open("rb"):
                result = compilation_admission(
                    root, self.policy(), [entry, *controls], set(), preview=False
                )
            self.assertTrue(payload.exists())
            self.assertIn(
                "open-or-unknown-files",
                [
                    p["reason"]
                    for p in result["protected"]
                    if p["path"] == str(entry.path)
                ],
            )

    def test_directory_replacement_before_open_preserves_replacement_symbols(self):
        import build_cache

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            entry = self.entry(root, "derived-case", time.time() - 86400)
            controls = [
                self.entry(root, "derived-control-" + str(i), time.time() - 2 + i)
                for i in range(2)
            ]
            payload = entry.path / "Build/Intermediates.noindex"
            replacement = root / "replacement"
            symbols = replacement / "retained.dSYM"
            symbols.mkdir(parents=True)
            (symbols / "binary").write_text("must survive")
            opened = build_cache.os.open
            replaced = False
            armed = False
            evict = build_cache._evict_payload

            def arm_eviction(entry, path, device):
                nonlocal armed
                armed = True
                return evict(entry, path, device)

            def replace_at_open(name, flags, **kwargs):
                nonlocal replaced
                if armed and name == "Intermediates.noindex" and not replaced:
                    replaced = True
                    payload.rename(payload.with_name("retired-original"))
                    replacement.rename(payload)
                return opened(name, flags, **kwargs)

            with (
                patch("build_cache._open_files", return_value=False),
                patch("build_cache.os.open", side_effect=replace_at_open),
                patch("build_cache._evict_payload", side_effect=arm_eviction),
            ):
                result = build_cache.compilation_admission(
                    root, self.policy(), [entry, *controls], set(), preview=False
                )
            self.assertTrue(replaced)
            self.assertEqual(
                (payload / "retained.dSYM/binary").read_text(), "must survive"
            )
            self.assertEqual(result["evicted"], [])
            self.assertTrue(result["evictionFailures"])
            self.assertFalse(result["inventoryComplete"])

    def test_compiler_mount_is_rejected_before_inventory_and_after_inspection(self):
        from types import SimpleNamespace

        import build_cache

        def check_mount(owner, boundary):
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                entry = self.entry(root, "derived-mounted", time.time() - 86400)
                if owner == "local":
                    entry = build_cache.CompilationDirectory(
                        entry.path,
                        entry.worktree,
                        entry.leases,
                        entry.path.parents[1],
                        entry.kind,
                    )
                controls = [
                    self.entry(root, "derived-control-" + str(i), time.time() - 2 + i)
                    for i in range(2)
                ]
                sentinel = entry.path / "Build/Intermediates.noindex/object.o"
                foreign_inodes = {
                    p.stat().st_ino for p in [entry.path, *entry.path.rglob("*")]
                }
                original_stat, original_fstat = os.stat, os.fstat
                device = entry.path.stat().st_dev
                mounted = boundary == "before-inventory"
                evict = build_cache._evict_payload

                def mount_info(info):
                    if (
                        not mounted
                        or info.st_dev != device
                        or info.st_ino not in foreign_inodes
                    ):
                        return info
                    values = {
                        key: getattr(info, key)
                        for key in dir(info)
                        if key.startswith("st_")
                    }
                    values["st_dev"] = device + 1
                    return SimpleNamespace(**values)

                def mount_before_delete(*args):
                    nonlocal mounted
                    if boundary == "after-inspection":
                        mounted = True
                    return evict(*args)

                with (
                    patch(
                        "build_cache.os.stat",
                        side_effect=lambda *a, **k: mount_info(original_stat(*a, **k)),
                    ),
                    patch(
                        "build_cache.os.fstat",
                        side_effect=lambda fd: mount_info(original_fstat(fd)),
                    ),
                    patch("build_cache._open_files", return_value=False),
                    patch(
                        "build_cache._evict_payload", side_effect=mount_before_delete
                    ),
                ):
                    result = build_cache.compilation_admission(
                        root, self.policy(), [entry, *controls], set(), preview=False
                    )
                self.assertEqual(sentinel.read_bytes(), b"compiler" * 1024)
                self.assertEqual(result["evicted"], [])
                self.assertFalse(result["inventoryComplete"])

        for owner in ("mirror", "local"):
            for boundary in ("before-inventory", "after-inspection"):
                with self.subTest(owner=owner, boundary=boundary):
                    check_mount(owner, boundary)

    def test_a_new_build_waits_for_the_cache_lease_until_eviction_finishes(self):
        import select
        import subprocess

        import build_cache

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            entry = self.entry(root, "derived-case", time.time() - 86400)
            controls = [
                self.entry(root, "derived-control-" + str(i), time.time() - 2 + i)
                for i in range(2)
            ]
            acquired = root / "acquired"
            contenders = []
            evict = build_cache._evict_payload

            def checked_eviction(current, payload, device):
                command = "import sys\nfrom pathlib import Path\nsys.path.insert(0,sys.argv[1])\nfrom build_support import file_lease\nprint('waiting',flush=True)\nwith file_lease(Path(sys.argv[2])): Path(sys.argv[3]).touch()\n"
                child = subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        command,
                        str(Path(build_cache.__file__).parent),
                        str(entry.leases[0]),
                        str(acquired),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                contenders.append(child)
                self.assertTrue(select.select([child.stdout], [], [], 60)[0])
                self.assertEqual(child.stdout.readline(), b"waiting\n")
                self.assertFalse(acquired.exists())
                with (
                    entry.leases[0].open("a") as reader,
                    self.assertRaises(BlockingIOError),
                ):
                    fcntl.flock(reader, fcntl.LOCK_EX | fcntl.LOCK_NB)
                evict(current, payload, device)
                self.assertFalse(acquired.exists())

            try:
                with (
                    patch("build_cache._open_files", return_value=False),
                    patch("build_cache._evict_payload", side_effect=checked_eviction),
                ):
                    result = build_cache.compilation_admission(
                        root, self.policy(), [entry, *controls], set(), preview=False
                    )
                self.assertEqual(len(result["evicted"]), 1)
                self.assertEqual(len(contenders), 1)
                _, error = contenders[0].communicate(timeout=60)
                self.assertEqual(contenders[0].returncode, 0, error)
                self.assertTrue(acquired.exists())
            finally:
                for child in contenders:
                    if child.poll() is None:
                        child.terminate()
                    child.communicate(timeout=60)

    def test_symlink_escape_and_evidence_inside_payload_survive(self):
        from build_cache import compilation_admission

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            entry = self.entry(root, "derived-old", time.time() - 86400)
            payload = entry.path / "Build/Intermediates.noindex"
            external = root / "external"
            external.mkdir()
            (external / "sentinel").write_text("external")
            (payload / "outside").symlink_to(external, target_is_directory=True)
            (payload / "trace.trace").mkdir()
            with patch("build_cache._open_files", return_value=False):
                result = compilation_admission(
                    root, self.policy(retained=0), [entry], set(), preview=False
                )
            self.assertEqual(result["evicted"], [])
            self.assertEqual((external / "sentinel").read_text(), "external")
            (payload / "trace.trace").rmdir()
            with patch("build_cache._open_files", return_value=False):
                compilation_admission(
                    root, self.policy(retained=0), [entry], set(), preview=False
                )
            self.assertEqual((external / "sentinel").read_text(), "external")
            self.assertFalse(payload.exists())
            payload.symlink_to(external, target_is_directory=True)
            with patch("build_cache._open_files", return_value=False):
                result = compilation_admission(
                    root, self.policy(retained=0), [entry], set(), preview=False
                )
            self.assertEqual(result["evicted"], [])
            self.assertTrue(payload.is_symlink())
            self.assertEqual((external / "sentinel").read_text(), "external")

    def test_disabled_eviction_and_preview_preserve_eligible_compilation_caches(self):
        from build_cache import compilation_admission

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            entry = self.entry(root, "derived-old", time.time() - 86400)
            usage = type("DiskUsage", (), {"free": 40 * 1024**3})()
            for enabled, preview in ((True, True), (False, True), (False, False)):
                with (
                    self.subTest(enabled=enabled, preview=preview),
                    patch("build_cache._open_files", return_value=False),
                    patch("build_cache.shutil.disk_usage", return_value=usage),
                ):
                    result = compilation_admission(
                        root,
                        self.policy(
                            enabled=enabled,
                            retained=0,
                            free_target=0 if preview else 100 * 1024**3,
                        ),
                        [entry],
                        set(),
                        preview=preview,
                    )
                    self.assertEqual(len(result["candidates"]), 1)
                    self.assertEqual(result["evicted"], [])
                    self.assertTrue(
                        (entry.path / "Build/Intermediates.noindex").exists()
                    )
            with patch("build_cache._allocated_bytes", side_effect=TimeoutError):
                result = compilation_admission(
                    root, self.policy(), [entry], set(), preview=False
                )
            self.assertFalse(result["inventoryComplete"])
            self.assertIsNone(result["protected"][0]["allocatedBytes"])

    def test_disabled_inventory_defers_allocation_without_inventing_budget_evidence(
        self,
    ):
        from build_cache import compilation_admission, compilation_record

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            entry = self.entry(root, "derived-old", time.time() - 86400)
            compilation_record(root, entry.path).write_text("unreadable record")
            usage = type("DiskUsage", (), {"free": 444 * 1024**3})()
            with (
                patch("build_cache.shutil.disk_usage", return_value=usage),
                patch(
                    "build_cache._allocated_bytes",
                    side_effect=AssertionError("Admission traversed compiler files"),
                ),
            ):
                result = compilation_admission(
                    root,
                    self.policy(enabled=False, free_target=100 * 1024**3),
                    [entry],
                    {entry.path},
                    preview=False,
                )
            self.assertFalse(result["inventoryComplete"])
            self.assertEqual(result["freeBytesBefore"], usage.free)
            self.assertEqual(result["freeBytesAfter"], usage.free)
            for key in (
                "allocatedBytes",
                "knownAllocatedBytes",
                "projectedBytes",
                "initialKnownOverflowBytes",
                "unsatisfiedBudgetBytes",
                "remainingBytes",
            ):
                self.assertIsNone(result[key], key)
            self.assertEqual(result["candidates"], [])
            self.assertEqual(result["evicted"], [])
            self.assertEqual(result["protected"][0]["reason"], "inventory-deferred")
            self.assertEqual(
                result["inventory"][0]["allocationCoverage"], "not-evaluated"
            )
            self.assertEqual(
                result["inventory"][0]["completionCoverage"]["record"],
                "not-evaluated",
            )
            self.assertTrue((entry.path / "Build/Intermediates.noindex").is_dir())

    def test_merged_clean_worktree_idle_for_24_hours_can_evict_its_only_cache(self):
        import subprocess

        from build_cache import CompilationDirectory, compilation_admission

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            init_repository(source)
            point_origin_main_at_head(source)
            path = source / "build/mac-build-derived"
            witness = path / "Build/Intermediates.noindex/XCBuildData/build.db"
            witness.parent.mkdir(parents=True)
            witness.write_text("compiler state")
            old = time.time() - 2 * 86400
            os.utime(witness, (old, old))
            entry = CompilationDirectory(
                path, str(source), (root / "source.lock",), source, "xcode"
            )
            with patch("build_cache._open_files", return_value=False):
                result = compilation_admission(
                    root, self.policy(), [entry], set(), preview=False
                )
            self.assertEqual(len(result["evicted"]), 1)
            self.assertFalse(witness.exists())
            witness.parent.mkdir(parents=True)
            witness.write_text("state")
            os.utime(witness, (old, old))
            (source / "tracked").write_text("clean")
            subprocess.run(["git", "-C", str(source), "add", "tracked"], check=True)
            with patch("build_cache._open_files", return_value=False):
                result = compilation_admission(
                    root, self.policy(), [entry], set(), preview=False
                )
            self.assertEqual(result["evicted"], [])
            self.assertTrue(witness.exists())

    def test_external_caches_do_not_consume_the_owned_budget(self):
        from build_cache import CompilationDirectory, compilation_admission

        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            root = base / "RemoteCoder-Build"
            root.mkdir()
            owned = self.entry(root, "derived-newest", time.time() - 86400)
            outside = base / "unrelated-derived"
            outside.mkdir()
            (outside / "object.o").write_bytes(b"a" * 1024**2)
            external = CompilationDirectory(outside, "unrelated", (), None, "protected")
            result = compilation_admission(
                root,
                self.policy(budget=256 * 1024),
                [owned, external],
                set(),
                preview=False,
            )
            self.assertEqual(result["evicted"], [])
            self.assertEqual(result["unsatisfiedBudgetBytes"], 0)
            self.assertTrue(
                (owned.path / "Build/Intermediates.noindex/object.o").exists()
            )
            self.assertTrue((outside / "object.o").exists())
            self.assertLess(result["allocatedBytes"], 256 * 1024)

    def test_pressure_eviction_does_not_probe_remote_source(self):
        import hashlib

        from build_cache import (
            CompilationDirectory,
            compilation_admission,
            record_mirror_source,
        )

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            host, source = "offline-build-source", "/removed/checkout"
            identity = hashlib.sha256((host + ":" + source).encode()).hexdigest()[:16]
            base = self.entry(
                root, "derived-offline", time.time() - 86400, tree=identity
            )
            entry = CompilationDirectory(
                base.path, "mirror:" + identity, base.leases, None, "xcode"
            )
            record_mirror_source(
                root, {"worktreeId": identity, "sourceHost": host, "sourceRoot": source}
            )
            with (
                patch("build_cache._open_files", return_value=False),
                patch("build_cache._open_file_snapshot", return_value=([], None)),
                patch(
                    "build_cache.subprocess.run",
                    side_effect=AssertionError("remote probe during pressure eviction"),
                ),
            ):
                result = compilation_admission(
                    root, self.policy(), [entry], set(), preview=False
                )
            self.assertEqual(len(result["evicted"]), 1)

    def test_abandoned_mirror_reclaims_payload_without_completion(self):
        import hashlib
        import socket

        from build_cache import (
            CompilationDirectory,
            compilation_admission,
            compilation_record,
            record_mirror_source,
        )

        for state in ("missing", "active"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                old = time.time() - 86400
                host, source = socket.gethostname(), str(root / "checkout")
                identity = hashlib.sha256((host + ":" + source).encode()).hexdigest()[
                    :16
                ]
                base = self.entry(root, "derived-abandoned", old, tree=identity)
                entry = CompilationDirectory(
                    base.path, "mirror:" + identity, base.leases, None, "xcode"
                )
                record_mirror_source(
                    root,
                    {"worktreeId": identity, "sourceHost": host, "sourceRoot": source},
                )
                record = compilation_record(root, entry.path)
                if state == "missing":
                    record.unlink()
                else:
                    import json

                    value = json.loads(record.read_text())
                    value.update(active=True, completedAt=None)
                    record.write_text(json.dumps(value))
                    os.utime(record, (old, old))
                os.utime(root / "worktrees" / identity, (old, old))
                with patch("build_cache._open_files", return_value=False):
                    result = compilation_admission(
                        root, self.policy(), [entry], set(), preview=False
                    )
                self.assertEqual(len(result["evicted"]), 1)
                self.assertTrue(
                    (entry.path / "Build/Products/RemoteCoder.app/binary").exists()
                )

    def test_removed_mirror_expires_only_after_evidence_window(self):
        import hashlib
        import socket

        from build_cache import record_mirror_source

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            host, source = socket.gethostname(), str(root / "checkout")
            identity = hashlib.sha256((host + ":" + source).encode()).hexdigest()[:16]
            entry = self.entry(
                root, "derived-orphan", time.time() - 86400, tree=identity
            )
            record_mirror_source(
                root, {"worktreeId": identity, "sourceHost": host, "sourceRoot": source}
            )
            mirror = root / "worktrees" / identity
            group_lock = mirror / "ios/build.lock"
            group_lock.touch()
            gateway_lock = mirror / "gateway/build.lock"
            gateway_lock.parent.mkdir()
            gateway_lock.touch()
            lock_inodes = [path.stat().st_ino for path in (group_lock, gateway_lock)]
            result = prune_caches(root, self.policy(), "", "")
            self.assertEqual(result.get("mirrors", []), [])
            old = time.time() - 3 * 86400
            os.utime(mirror, (old, old))
            os.utime(group_lock, (old, old))
            os.utime(gateway_lock, (old, old))
            preview = prune_caches(root, self.policy(), "", "", preview=True)
            self.assertEqual(len(preview["mirrorCandidates"]), 1)
            self.assertTrue(
                (entry.path / "Build/Products/RemoteCoder.app/binary").exists()
            )
            result = prune_caches(root, self.policy(), "", "")
            self.assertEqual(len(result["mirrors"]), 1)
            self.assertFalse(entry.path.exists())
            self.assertTrue((mirror / "source.json").exists())
            self.assertEqual(
                [path.stat().st_ino for path in (group_lock, gateway_lock)], lock_inodes
            )
            with patch(
                "build_cache._removed_mirror_source",
                side_effect=AssertionError("empty mirror shell was probed"),
            ):
                self.assertEqual(
                    prune_caches(root, self.policy(), "", ""), {"runs": []}
                )

    def test_removed_source_retires_newest_cache_below_budget(self):
        import hashlib
        import socket

        from build_cache import (
            CompilationDirectory,
            compilation_admission,
            record_mirror_source,
        )

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "deleted-checkout"
            host = socket.gethostname()
            identity = hashlib.sha256((host + ":" + str(source)).encode()).hexdigest()[
                :16
            ]
            old = time.time() - 86400
            base = self.entry(root, "derived-orphan", old, tree=identity)
            entry = CompilationDirectory(
                base.path, "mirror:" + identity, base.leases, None, "xcode"
            )
            record_mirror_source(
                root,
                {"worktreeId": identity, "sourceHost": host, "sourceRoot": str(source)},
            )
            with patch("build_cache._open_files", return_value=False):
                result = compilation_admission(
                    root, self.policy(budget=1024**3), [entry], set(), preview=False
                )
            self.assertEqual(len(result["evicted"]), 1)
            self.assertFalse((entry.path / "Build/Intermediates.noindex").exists())
            self.assertTrue(
                (entry.path / "Build/Products/RemoteCoder.app/binary").exists()
            )

    def test_discovery_never_includes_worktrees_outside_the_effective_home(self):
        from build_cache import compilation_directories

        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            home = base / "home"
            cache = home / "Library/Caches/RemoteCoder-Build"
            cache.mkdir(parents=True)
            external = base / "other/build/mac-build-derived"
            external.mkdir(parents=True)
            entries = compilation_directories(
                cache, [external.parents[1]], home / "DerivedData"
            )
            self.assertEqual(entries, [])

    def test_historical_mirror_uses_newer_dirty_or_incomplete_evidence(self):
        import json

        from build_cache import CompilationDirectory, compilation_admission

        for state in (
            "clean",
            "dirty",
            "incomplete",
            "unreadable",
            "unrelated-reservation",
            "associated-reservation",
            "symlinked-reservation",
            "case-reservation",
            "case-symlinked-reservation",
            "invalid-reservation",
            "bench-output",
        ):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                source = root / "RemoteCoder"
                commit = init_repository(source)
                point_origin_main_at_head(source)
                cache = root / "worktrees/tree/gateway/cargo"
                payload = cache / "debug/incremental"
                payload.mkdir(parents=True)
                sentinel = payload / "object.o"
                sentinel.write_text("private compiler state")
                old = time.time() - 3 * 86400
                for index in range(2):
                    run = root / "runs" / str(index)
                    run.mkdir(parents=True)
                    (run / "source.json").write_text(
                        json.dumps(
                            {
                                "worktreeId": "tree",
                                "sourceCommit": commit,
                                "sourceModified": index == 1 and state == "dirty",
                            }
                        )
                    )
                    (run / "receipt.json").write_text("{}")
                    (run / "outcome.json").write_text(
                        json.dumps(
                            {
                                "exitCode": 0,
                                "finishedAt": old + index * 3600,
                            }
                        )
                    )
                    if index == 1 and state == "incomplete":
                        (run / "outcome.json").unlink()
                    if index == 1 and state == "unreadable":
                        (run / "source.json").write_text("{")
                    for path in [*run.iterdir(), run]:
                        os.utime(path, (old + index * 3600, old + index * 3600))
                if state.endswith("reservation") or state == "bench-output":
                    extra = root / "runs" / "noncompiler"
                    extra.mkdir()
                    receipt = {
                        "kind": "mac-bench-run"
                        if state == "bench-output"
                        else "measurement-reservation",
                        "runId": extra.name,
                        "outputDirectory": str(extra),
                        "source": str(
                            root
                            / "worktrees"
                            / (
                                "tree"
                                if state
                                in (
                                    "associated-reservation",
                                    "symlinked-reservation",
                                    "case-reservation",
                                    "case-symlinked-reservation",
                                )
                                else "other"
                            )
                            / "gateway/repo"
                        ),
                        "exitCode": 0,
                    }
                    if state == "invalid-reservation":
                        receipt["source"] = None
                    elif receipt["kind"] == "measurement-reservation":
                        if state.startswith("case-"):
                            receipt["source"] = str(
                                root / "Worktrees/TREE/GATEWAY/REPO"
                            )
                        recorded = Path(receipt["source"])
                        recorded.mkdir(parents=True)
                        os.utime(recorded, (old, old))
                        receipt["source"] = str(recorded.resolve())
                    (extra / "receipt.json").write_text(json.dumps(receipt))
                    if state in ("symlinked-reservation", "case-symlinked-reservation"):
                        external = root / "external-source"
                        external.mkdir()
                        os.utime(external, (old, old))
                        recorded.rename(recorded.with_name("old-repo"))
                        recorded.symlink_to(external, target_is_directory=True)
                    os.utime(extra, (old + 2 * 3600, old + 2 * 3600))
                os.utime(cache.parents[1], (old, old))
                entry = CompilationDirectory(
                    cache,
                    "mirror:tree",
                    (root / "tree.lock",),
                    None,
                    "cargo",
                )
                with (
                    patch("build_cache.Path.home", return_value=root),
                    patch("build_cache._open_files", return_value=False),
                ):
                    result = compilation_admission(
                        root,
                        self.policy(),
                        [entry],
                        set(),
                        preview=False,
                    )
                eligible = state in ("clean", "unrelated-reservation", "bench-output")
                self.assertEqual(len(result["candidates"]), int(eligible))
                self.assertEqual(len(result["evicted"]), int(eligible))
                self.assertEqual(sentinel.exists(), not eligible)

    def test_run_retention_never_descends_into_a_foreign_device(self):
        from contextlib import contextmanager
        from types import SimpleNamespace

        import build_cache

        def check_retention(preview, boundary):
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                run = root / "runs/old"
                foreign = run / "mounted-volume"
                foreign.mkdir(parents=True)
                sentinel = foreign / "external-sentinel"
                sentinel.write_text("foreign data")
                (run / "receipt.json").write_text('{"exitCode":0}')
                old = time.time() - 8 * 86400
                os.utime(run, (old, old))
                device, inode = foreign.stat().st_dev, foreign.stat().st_ino
                real_stat, real_fstat, real_scandir = os.stat, os.fstat, os.scandir
                run_inode = run.stat().st_ino
                mounted = boundary == "stable"
                tree_bytes = build_cache._tree_bytes

                def mount_after_inventory(fd, deadline, device, *, exclude_linked):
                    nonlocal mounted
                    size = tree_bytes(fd, deadline, device, exclude_linked=exclude_linked)
                    if (
                        boundary == "after-preview"
                        and real_fstat(fd).st_ino == run_inode
                    ):
                        mounted = True
                    return size

                def mount_identity(info):
                    if not mounted or (info.st_dev, info.st_ino) != (device, inode):
                        return info
                    values = {
                        key: getattr(info, key)
                        for key in dir(info)
                        if key.startswith("st_")
                    }
                    values["st_dev"] = device + 1
                    return SimpleNamespace(**values)

                class MountedEntry:
                    def __init__(self, entry):
                        self.entry = entry
                        self.name = entry.name

                    def stat(self, **kwargs):
                        return mount_identity(self.entry.stat(**kwargs))

                    def is_dir(self, **kwargs):
                        return self.entry.is_dir(**kwargs)

                    def __getattr__(self, name):
                        return getattr(self.entry, name)

                @contextmanager
                def mounted_scandir(path):
                    with real_scandir(path) as entries:
                        yield (MountedEntry(entry) for entry in entries)

                with (
                    patch(
                        "build_cache.os.stat",
                        side_effect=lambda *a, **k: mount_identity(real_stat(*a, **k)),
                    ),
                    patch(
                        "build_cache.os.fstat",
                        side_effect=lambda fd: mount_identity(real_fstat(fd)),
                    ),
                    patch("build_cache.os.scandir", side_effect=mounted_scandir),
                    patch("build_cache._tree_bytes", side_effect=mount_after_inventory),
                ):
                    result = prune_caches(
                        root, self.policy(), "tree", "current", preview=preview
                    )
                if boundary == "same-device":
                    self.assertFalse(sentinel.exists())
                    self.assertEqual(result["runs"], ["old"])
                    return
                self.assertEqual(sentinel.read_text(), "foreign data")
                self.assertEqual(result["runs"], [])
                if boundary == "stable":
                    self.assertNotIn(str(run), result.get("runCandidates", []))
                self.assertIn("old", result["unknownRuns"])

        for preview, boundary in (
            (False, "stable"),
            (True, "stable"),
            (False, "after-preview"),
            (False, "same-device"),
        ):
            with self.subTest(preview=preview, boundary=boundary):
                check_retention(preview, boundary)

    def test_retention_never_removes_an_entire_compiler_mirror(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            old = time.time() - 8 * 86400
            mirror = root / "worktrees/old"
            mirror.mkdir(parents=True)
            product = mirror / "product.app"
            product.mkdir()
            (product / "binary").write_text("must survive")
            os.utime(mirror, (old, old))
            result = prune_caches(root, self.policy(), "current", "run")
            self.assertEqual((product / "binary").read_text(), "must survive")
            self.assertEqual(result["runs"], [])

    def test_unknown_runs_and_evidence_younger_than_48_hours_are_protected(self):
        for data in ("", "{", "{}", '{"exitCode": false}', "[]", '{"exitCode": 0}'):
            with self.subTest(data=data), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                run = root / "runs/evidence"
                run.mkdir(parents=True)
                (run / "receipt.json").write_text(data)
                result = prune_caches(root, self.policy(), "tree", "current")
                self.assertEqual(result["runs"], [])
                self.assertTrue(run.exists())

    def test_run_retention_bounds_key_probes_and_preserves_unprobed_runs(self):
        import json
        import build_cache

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            paths = []
            for index in range(5):
                path = root / "runs" / str(index)
                path.mkdir(parents=True)
                (path / "receipt.json").write_text(json.dumps({"exitCode": 0}))
                paths.append(path)
            clock = [0]
            probed = []
            old = time.time() - 8 * 86400

            def usage(path, owner, category):
                self.assertLess(clock[0], 20)
                probed.append(path)
                clock[0] += 6
                return old

            with (
                patch("build_cache.time.monotonic", side_effect=lambda: clock[0]),
                patch("build_cache.last_used", side_effect=usage),
            ):
                result = prune_caches(root, self.policy(), "", "")
            self.assertEqual(len(probed), 4)
            self.assertEqual(len(set(probed)), 4)
            self.assertEqual(set(result["runs"]), {path.name for path in probed[:3]})
            self.assertEqual(set(result["unprobedRuns"]), {path.name for path in paths} - set(result["runs"]))
            for path in paths:
                self.assertEqual(path.exists(), path.name in result["unprobedRuns"])
                with build_cache.try_lease(lease_path(root, "runs", path.name)) as lease:
                    self.assertIsNotNone(lease)

    def test_build_cache_operations_never_wait_on_maintenance(self):
        import json
        import build_cache
        from build_support import file_lease

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            entry = self.entry(root, "derived-cache", time.time() - 86400)
            source = root / "source"
            source.mkdir()
            (source / ".package.resolved").write_text("{}")
            manifest = {"worktreeId": "tree", "sourceHost": "host", "sourceRoot": str(source)}
            with (
                file_lease(root / "leases/maintenance.lock"),
                file_lease(entry.leases[0]),
                patch("build_cache.file_lease", side_effect=AssertionError("Maintenance wait is forbidden")),
                patch("build_cache._allocated_bytes", side_effect=AssertionError("Contended admission must not scan")),
            ):
                result = build_cache.compilation_admission(root, self.policy(), [entry], set(), preview=False)
                self.assertEqual(result["inventoryDeferred"], "maintenance-lease-contended")
                self.assertFalse(result["inventoryComplete"])
                self.assertIsNone(result["allocatedBytes"])
                self.assertEqual(result["evicted"], [])
                self.assertEqual(prune_caches(root, self.policy(), "", "")["retentionDeferred"], "maintenance-lease-contended")
                self.assertIsNone(seed_source_packages(root, "tree", source, root / "derived"))
                self.assertIsNone(seed_cargo(root, "tree", "key", root / "target", source / "Cargo.toml", {}))
                build_cache.record_mirror_source(root, manifest)
                build_cache.record_compilation(root, [entry.path], "build", True, {"sourceCommit": "commit", "sourceModified": False})
            self.assertEqual(json.loads((root / "worktrees/tree/source.json").read_text()), manifest)
            self.assertTrue(json.loads(build_cache.compilation_record(root, entry.path).read_text())["active"])

    def test_maintenance_holds_one_lease_through_inventory_and_shared_publication(self):
        import json
        import build_cache
        from build_support import atomic_json

        for failure in (False, True):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                home = Path(temporary).resolve()
                root = home / "Library/Caches/RemoteCoder-Build"
                status = home / ".local/state/disk-cap-status/remotecoder-build.json"
                deferred = []
                writes = []

                def confirm_exclusion():
                    with build_cache.try_lease(root / "leases/maintenance.lock") as lease:
                        self.assertIsNone(lease)
                    before = inventory.call_count
                    result = build_cache.maintain_cache(root, self.policy())
                    self.assertEqual(result["message"], "skipped: maintenance held")
                    self.assertEqual(result["exitCode"], 0)
                    self.assertEqual(inventory.call_count, before)
                    deferred.append(result)

                def inventory_probe(path):
                    confirm_exclusion()
                    if failure:
                        raise ValueError("synthetic inventory failure")
                    return build_cache.CacheInventory(4096, {root: 4096}, None)

                def publish(path, value):
                    confirm_exclusion()
                    writes.append(path)
                    atomic_json(path, value)

                with (
                    patch.object(Path, "home", return_value=home),
                    patch("build_cache.cache_inventory", side_effect=inventory_probe) as inventory,
                    patch("build_cache.atomic_json", side_effect=publish),
                ):
                    if failure:
                        with self.assertRaisesRegex(ValueError, "synthetic inventory failure"):
                            build_cache.maintain_cache(root, self.policy())
                    else:
                        build_cache.maintain_cache(root, self.policy())
                self.assertEqual(writes, [root / "maintenance.json", status])
                self.assertTrue(deferred)
                self.assertEqual(json.loads((root / "maintenance.json").read_text())["capStatus"], json.loads(status.read_text()))
                with build_cache.try_lease(root / "leases/maintenance.lock") as lease:
                    self.assertIsNotNone(lease)

    def test_approval_preview_includes_old_run_evidence_and_never_deletes_or_rejects_low_space(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            run = root / "runs/old"
            symbols = run / "symbols"
            symbols.mkdir(parents=True)
            (run / "receipt.json").write_text('{"exitCode":0}')
            (symbols / "binary.dSYM").mkdir()
            old = time.time() - 8 * 86400
            os.utime(run, (old, old))
            usage = type("DiskUsage", (), {"free": 10 * 1024**3})()
            with patch("build_cache.shutil.disk_usage", return_value=usage):
                manifest = prune_caches(root, self.policy(), "", "", preview=True)
            self.assertEqual(manifest["runCandidates"], [str(run)])
            self.assertEqual(manifest["runs"], [])
            self.assertTrue((symbols / "binary.dSYM").is_dir())

    def test_hard_floor_remains_the_only_admission_disk_failure(self):
        from build_cache import compilation_admission

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            usage = type("DiskUsage", (), {"free": 40 * 1024**3})()
            with patch("build_cache.shutil.disk_usage", return_value=usage):
                result = compilation_admission(
                    root, self.policy(enabled=False), [], set(), preview=False
                )
                self.assertIn("inventoryDeferred", result)
                self.assertEqual(
                    prune_caches(root, self.policy(), "tree", "run"), {"runs": []}
                )
            usage.free = 10 * 1024**3
            with patch("build_cache.shutil.disk_usage", return_value=usage):
                self.assertEqual(
                    prune_caches(root, self.policy(), "tree", "run"), {"runs": []}
                )


class DependencySeedTests(unittest.TestCase):
    def test_seed_rebuilds_older_invalid_workspace_source_in_debug_and_release(self):
        import hashlib
        import json
        import shutil
        import subprocess

        if not shutil.which("cargo"):
            self.skipTest("Cargo is required for the native seeding regression")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            warm = root / "worktrees/warm/gateway"
            target = warm / "cargo"
            candidate = root / "candidate"
            dependency = root / "dependency"
            (dependency / "src").mkdir(parents=True)
            (dependency / "Cargo.toml").write_text(
                '[package]\nname="seed-dependency"\nversion="0.0.0"\nedition="2024"\n'
            )
            (dependency / "src/lib.rs").write_text("pub fn value() -> u32 { 7 }")
            for folder, program, age in (
                (
                    warm / "repo",
                    'fn main() { println!("{}", seed_dependency::value()); }',
                    60,
                ),
                (candidate, "NOT A PROGRAM", 120),
            ):
                package = folder / "host-daemon-rs"
                (package / "src").mkdir(parents=True)
                (package / "Cargo.toml").write_text(
                    '[package]\nname="remote-coder-codex-gateway"\nversion="0.0.0"\nedition="2024"\n'
                    "[dependencies]\nseed-dependency={path="
                    + json.dumps(str(dependency))
                    + "}\n"
                )
                source = package / "src/main.rs"
                source.write_text(program)
                os.utime(source, (time.time() - age, time.time() - age))
            environment = dict(
                os.environ, RUSTC_WRAPPER="", CARGO_TARGET_DIR=str(target)
            )
            environment.pop("CARGO_BUILD_BUILD_DIR", None)
            for profile in ("dev", "release"):
                compiled = subprocess.run(
                    [
                        "cargo",
                        "build",
                        "--offline",
                        "--profile",
                        profile,
                        "--manifest-path",
                        str(warm / "repo/host-daemon-rs/Cargo.toml"),
                    ],
                    env=environment,
                    capture_output=True,
                    text=True,
                    timeout=120,
                    check=False,
                )
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
            dependency_files = {
                str(path.relative_to(target)): hashlib.sha256(
                    path.read_bytes()
                ).hexdigest()
                for path in target.glob("*/deps/libseed_dependency-*.rlib")
            }
            self.assertEqual(len(dependency_files), 2)
            shutil.copy2(
                warm / "repo/host-daemon-rs/Cargo.lock",
                candidate / "host-daemon-rs/Cargo.lock",
            )
            (warm / "cargo-seed-key").write_text("matching-key")
            destination = root / "worktrees/new/gateway/cargo"
            outside = root / "outside-build"
            shutil.copytree(target, outside)
            environment["CARGO_BUILD_BUILD_DIR"] = str(outside)
            result = seed_cargo(
                root,
                "new",
                "matching-key",
                destination,
                candidate / "host-daemon-rs/Cargo.toml",
                environment,
            )
            self.assertEqual(result["sourceWorktree"], "warm")
            self.assertTrue((outside / "debug/remote-coder-codex-gateway").is_file())
            self.assertTrue((outside / "release/remote-coder-codex-gateway").is_file())
            for name, digest in dependency_files.items():
                self.assertEqual(
                    hashlib.sha256((destination / name).read_bytes()).hexdigest(),
                    digest,
                )
            environment["CARGO_TARGET_DIR"] = str(destination)
            environment["CARGO_BUILD_BUILD_DIR"] = str(destination)
            for profile in ("dev", "release"):
                with self.subTest(profile=profile):
                    compiled = subprocess.run(
                        [
                            "cargo",
                            "run",
                            "--offline",
                            "--profile",
                            profile,
                            "--manifest-path",
                            str(candidate / "host-daemon-rs/Cargo.toml"),
                        ],
                        env=environment,
                        capture_output=True,
                        text=True,
                        timeout=120,
                        check=False,
                    )
                    self.assertNotEqual(compiled.returncode, 0, compiled.stdout)
                    self.assertIn("NOT A PROGRAM", compiled.stderr)

    def test_package_clone_matches_resolution_respects_locks_and_mutates_independently(
        self,
    ):
        import json
        import subprocess

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            sibling = root / "worktrees/warm/ios"
            packages = sibling / "derived-toolchain/SourcePackages"
            checkout = packages / "checkouts/dependency"
            checkout.mkdir(parents=True)
            init_repository(checkout)
            (checkout / "source").write_text("original")
            subprocess.run(["git", "add", "."], cwd=checkout, check=True, capture_output=True)
            subprocess.run(["git", "commit", "-m", "source"], cwd=checkout, check=True, capture_output=True)
            revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
            (packages / "workspace-state.json").write_text("old-path-state")
            (sibling / "repo").mkdir()
            resolution = sibling / "repo/RemoteCoder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            resolution.parent.mkdir(parents=True)
            resolution.write_text(json.dumps({"pins": [{"identity": "dependency", "state": {"revision": revision}}]}))
            source = root / "input"
            source.mkdir()
            requested = source / "RemoteCoder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            requested.parent.mkdir(parents=True)
            requested.write_text("different")
            derived = root / "worktrees/new/ios/derived-toolchain"
            self.assertIsNone(seed_source_packages(root, "new", source, derived))
            requested.write_bytes(resolution.read_bytes())
            with (sibling / "build.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                self.assertIsNone(seed_source_packages(root, "new", source, derived))
            for flags in (("--assume-unchanged",), ("--skip-worktree",), ("--assume-unchanged", "--skip-worktree")):
                with self.subTest(flags=flags):
                    for flag in flags:
                        subprocess.run(["git", "-C", str(checkout), "update-index", flag, "source"], check=True)
                    (checkout / "source").write_text("hidden personal edit")
                    self.assertEqual(subprocess.check_output(["git", "-C", str(checkout), "status", "--porcelain"]), b"")
                    index = (checkout / ".git/index").read_bytes()
                    self.assertIsNone(seed_source_packages(root, "new", source, derived))
                    self.assertEqual((checkout / ".git/index").read_bytes(), index)
                    self.assertFalse(derived.exists())
                    for flag in ("--no-assume-unchanged", "--no-skip-worktree"):
                        subprocess.run(["git", "-C", str(checkout), "update-index", flag, "source"], check=True)
                    (checkout / "source").write_text("original")
            result = seed_source_packages(root, "new", source, derived)
            self.assertEqual(result["sourceWorktree"], "warm")
            clone = derived / "SourcePackages/checkouts/dependency/source"
            clone.write_text("independent")
            self.assertEqual((checkout / "source").read_text(), "original")
            self.assertFalse((derived / "SourcePackages/workspace-state.json").exists())
            self.assertIsNone(seed_source_packages(root, "new", source, derived))

    def test_cargo_clone_requires_matching_toolchain_and_configuration_and_idle_owner(
        self,
    ):
        import subprocess
        from contextlib import contextmanager

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            gateway = root / "worktrees/warm/gateway"
            (gateway / "cargo/debug/deps").mkdir(parents=True)
            (gateway / "cargo/debug/deps/artifact").write_text("warm")
            (gateway / "cargo-seed-key").write_text("matching-key")
            target = root / "worktrees/new/gateway/cargo"
            manifest = root / "candidate/Cargo.toml"
            self.assertIsNone(
                seed_cargo(root, "new", "different-key", target, manifest, {})
            )
            lock = lease_path(root, "worktrees", "warm")
            lock.parent.mkdir(parents=True, exist_ok=True)
            with lock.open("a") as stream:
                fcntl.flock(stream, fcntl.LOCK_EX)
                self.assertIsNone(
                    seed_cargo(root, "new", "matching-key", target, manifest, {})
                )
            run = subprocess.run

            def copy_with_failed_clean(command, **kwargs):
                if command[0] == "cp":
                    return run(command, **kwargs)
                raise subprocess.CalledProcessError(101, command)

            with patch(
                "build_cache.subprocess.run", side_effect=copy_with_failed_clean
            ):
                result = seed_cargo(root, "new", "matching-key", target, manifest, {})
            self.assertEqual(result["status"], "unseeded")
            self.assertEqual(result["failure"]["operation"], "clean")
            self.assertEqual(result["failure"]["exitCode"], 101)
            self.assertFalse(target.exists())
            self.assertEqual(
                (gateway / "cargo/debug/deps/artifact").read_text(), "warm"
            )

            def copy_with_successful_clean(command, **kwargs):
                return (
                    run(command, **kwargs)
                    if command[0] == "cp"
                    else subprocess.CompletedProcess(command, 0)
                )

            temporary_directory = tempfile.TemporaryDirectory

            @contextmanager
            def failed_staging_cleanup(**kwargs):
                with temporary_directory(**kwargs) as staging:
                    yield staging
                raise OSError("staging cleanup failed")

            with (
                patch(
                    "build_cache.subprocess.run",
                    side_effect=copy_with_successful_clean,
                ),
                patch(
                    "build_cache.tempfile.TemporaryDirectory",
                    side_effect=failed_staging_cleanup,
                ),
            ):
                result = seed_cargo(root, "new", "matching-key", target, manifest, {})
            self.assertEqual(result["status"], "seeded")
            self.assertEqual(result["sourceWorktree"], "warm")
            self.assertEqual(result["workspaceProfilesInvalidated"], ["dev", "release"])
            self.assertEqual(result["cleanupWarning"], "staging cleanup failed")
            self.assertEqual((target / "debug/deps/artifact").read_text(), "warm")
            (target / "debug/deps/artifact").write_text("new")
            self.assertEqual(
                (gateway / "cargo/debug/deps/artifact").read_text(), "warm"
            )


class XcodeEnvironmentPurgeTests(unittest.TestCase):
    def test_rebuildable_environment_state_is_removed_under_its_lease(self):
        from build_cache import CompilationDirectory, purge_xcode_environments

        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            root = home / 'Library/Caches/RemoteCoder-Build'
            derived = root / 'worktrees/fixture/ios/derived-fixture'
            state = derived / 'Build/Intermediates.noindex/XCBuildData'
            state.mkdir(parents=True)
            (state / 'manifest.json').write_text('private-environment-sentinel')
            product = derived / 'Build/Products/app'
            product.parent.mkdir(parents=True)
            product.write_text('preserve')
            lease = root / 'leases/worktrees/fixture.lock'
            entry = CompilationDirectory(derived, 'fixture', (lease,), None, 'xcode')
            with patch('build_cache.Path.home', return_value=home), patch('build_cache.compilation_directories', return_value=[entry]), patch('build_cache._open_file_snapshot', return_value=([], None)):
                result = purge_xcode_environments(root, [])
            self.assertEqual(result['removed'], [str(state)])
            self.assertFalse(state.exists())
            self.assertEqual(product.read_text(), 'preserve')

    def test_active_source_lease_protects_environment_state(self):
        from build_cache import CompilationDirectory, purge_xcode_environments

        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            root = home / 'Library/Caches/RemoteCoder-Build'
            derived = root / 'worktrees/fixture/ios/derived-fixture'
            state = derived / 'Build/Intermediates.noindex/XCBuildData'
            state.mkdir(parents=True)
            lease = root / 'leases/worktrees/fixture.lock'
            lease.parent.mkdir(parents=True)
            entry = CompilationDirectory(derived, 'fixture', (lease,), None, 'xcode')
            with lease.open('a') as held, patch('build_cache.Path.home', return_value=home), patch('build_cache.compilation_directories', return_value=[entry]), patch('build_cache._open_file_snapshot', return_value=([], None)):
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = purge_xcode_environments(root, [])
            self.assertEqual(result['removed'], [])
            self.assertEqual(result['protected'][0]['reason'], 'leased')
            self.assertTrue(state.exists())
