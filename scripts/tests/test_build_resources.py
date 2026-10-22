import importlib.util
import os
import resource
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import build_support


def load(name):
    spec = importlib.util.spec_from_file_location(
        name.replace("-", "_"), SCRIPTS / (name + ".py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


transfer = load("rsync-source")
cache = load("codex-cache")


class BuildResourceTests(unittest.TestCase):
    def test_transfer_limit_obeys_host_and_hard_limits(self):
        self.assertEqual(transfer.transfer_limit(256, 8192, 61440), 8192)
        self.assertEqual(
            transfer.transfer_limit(256, resource.RLIM_INFINITY, 61440), 61440
        )
        self.assertEqual(
            transfer.transfer_limit(8192, resource.RLIM_INFINITY, 245760), 65536
        )

    def test_real_transfer_command_starts_under_an_8192_hard_limit(self):
        code = """import os,resource,sys
soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE)
hard=min(8192,hard) if hard!=resource.RLIM_INFINITY else 8192
resource.setrlimit(resource.RLIMIT_NOFILE,(min(256,hard),hard))
os.execv(sys.executable,[sys.executable,sys.argv[1],'--version'])
"""
        result = subprocess.run(
            [sys.executable, "-c", code, str(SCRIPTS / "rsync-source.py")],
            env=os.environ.copy(),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rsync", result.stdout.lower())

    def test_exceeding_a_measured_budget_preserves_the_warm_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "target"
            deps = target / "debug/deps"
            deps.mkdir(parents=True)
            for index in range(3):
                (deps / str(index)).write_bytes(b"reusable artifact")
            with (
                patch.object(cache, "require_build_space"),
                patch.object(cache, "MAX_DEPS_ENTRIES", 2),
                self.assertRaisesRegex(ValueError, "Cache preserved"),
            ):
                cache.check_cache(target)
            self.assertEqual(len(list(deps.iterdir())), 3)

    def test_free_space_floor_refuses_work_without_deleting_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "artifact").write_bytes(b"owned bytes")
            with (
                patch.object(
                    build_support.shutil,
                    "disk_usage",
                    return_value=SimpleNamespace(free=10 * 1024**3),
                ),
                self.assertRaisesRegex(ValueError, "15 GiB"),
            ):
                build_support.require_build_space(root)
            self.assertEqual((root / "artifact").read_bytes(), b"owned bytes")
