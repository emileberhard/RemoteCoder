import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SERVER = Path(__file__).resolve().parents[2] / "relay/server"


class RelayTransactionTests(unittest.TestCase):
    def setUp(self):
        if sys.platform != "linux" or not shutil.which("bwrap"):
            if os.environ.get("RC_RELAY_REQUIRE_SANDBOX") == "1":
                self.fail("Linux bubblewrap is required for relay transaction tests")
            self.skipTest("Linux bubblewrap is unavailable")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.varlib = self.root / "varlib"
        self.directory = self.varlib / "remote-coder-relay"
        self.directory.mkdir(parents=True, mode=0o700)
        self.dpkg = self.varlib / "dpkg"
        self.dpkg.mkdir()
        for name in ("lock-frontend", "lock"):
            (self.dpkg / name).touch()
        self.src = self.root / "src"
        self.src.mkdir()
        shutil.copyfile(
            SERVER / "maintenance_state.py", self.src / "maintenance_state.py"
        )
        shutil.copyfile(
            SERVER / "maintenance_drain.py", self.src / "maintenance_drain.py"
        )
        self.sbin = self.root / "sbin"
        self.sbin.mkdir()
        nft = self.sbin / "nft"
        nft.write_text(
            "#!/bin/sh\ntest -f /var/lib/remote-coder-relay/maintenance.json || exit 1\n"
            'printf "%s\\n" "$*" >> /tmp/fixture/nft-calls\n'
            "test ! -e /tmp/fixture/fail-nft\n"
        )
        nft.chmod(0o755)

    def run_owner(self, code):
        return subprocess.run(
            [
                "bwrap",
                "--unshare-all",
                "--uid",
                "0",
                "--gid",
                "0",
                "--die-with-parent",
                "--ro-bind",
                "/",
                "/",
                "--tmpfs",
                "/tmp",
                "--bind",
                str(self.varlib),
                "/var/lib",
                "--bind",
                str(self.src),
                "/tmp/fixture",
                "--bind",
                str(self.sbin),
                "/usr/sbin",
                "--proc",
                "/proc",
                "--",
                "/usr/bin/python3",
                "-c",
                code,
            ],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_every_flock_and_dpkg_lock_excludes_marker_creation(self):
        code = (
            "import sys; sys.path.insert(0, '/tmp/fixture'); from maintenance_state import RelayTransaction; "
            "t=RelayTransaction(); t.__enter__()"
        )
        locks = [
            (self.directory / "provision.lock", fcntl.flock),
            (self.directory / "admission.lock", fcntl.flock),
            (self.dpkg / "lock-frontend", fcntl.lockf),
            (self.dpkg / "lock", fcntl.lockf),
        ]
        for path, acquire in locks:
            with self.subTest(lock=path.name), path.open("a+") as holder:
                acquire(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = self.run_owner(code)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("already held", result.stderr)
                self.assertFalse((self.directory / "maintenance.json").exists())

    def test_marker_transitions_are_atomic_and_keep_process_identity(self):
        stale = self.directory / ".maintenance-deadbeef.tmp"
        stale.write_text("interrupted temporary")
        stale.chmod(0o600)
        code = r"""
import json, os, subprocess, sys
from unittest.mock import patch
sys.path.insert(0, "/tmp/fixture")
import maintenance_state as state
child = subprocess.Popen(["/bin/sleep", "10"])
try:
    with state.RelayTransaction() as transaction:
        transaction.prepare(os.getpid(), child.pid)
        original = state.MARKER.read_bytes()
        before = json.loads(original)
        assert before["phase"] == "preparing"
        assert before["master"]["pid"] == os.getpid()
        assert before["worker"]["pid"] == child.pid
        assert state.MARKER.stat().st_mode & 0o777 == 0o600
        try:
            transaction.commit()
        except RuntimeError:
            pass
        else:
            raise AssertionError("commit without a fence was accepted")
        transaction.fence()
        try:
            transaction.commit()
        except RuntimeError:
            pass
        else:
            raise AssertionError("commit before drain was accepted")
        with patch("maintenance_drain.wait_for_drain") as wait:
            transaction.drain(300)
            assert wait.call_args.args == ({"master": before["master"], "worker": before["worker"]}, 300)
        for path, kind in [
            (state.DIRECTORY / "provision.lock", "flock"),
            (state.DIRECTORY / "admission.lock", "flock"),
            (state.DPKG_LOCKS[0], "lockf"),
            (state.DPKG_LOCKS[1], "lockf"),
        ]:
            probe = subprocess.run(
                [sys.executable, "-c", "import fcntl,sys; f=open(sys.argv[1], 'r+'); getattr(fcntl,sys.argv[2])(f,fcntl.LOCK_EX|fcntl.LOCK_NB)", str(path), kind],
                capture_output=True, text=True, check=False,
            )
            assert probe.returncode != 0 and "BlockingIOError" in probe.stderr
        with patch.object(state.os, "replace", side_effect=OSError("synthetic failure")):
            try:
                transaction.commit()
            except OSError:
                pass
            else:
                raise AssertionError("the failed replace was ignored")
        assert state.MARKER.read_bytes() == original
        assert not list(state.DIRECTORY.glob(".maintenance-*"))
        transaction.commit()
        after = state.read_marker()
        assert after["phase"] == "committed"
        assert after["operation_id"] == before["operation_id"]
        assert after["master"] == before["master"] and after["worker"] == before["worker"]
        try:
            transaction.abort()
        except RuntimeError:
            pass
        else:
            raise AssertionError("a committed fence was reopened")
    try:
        transaction.commit()
    except RuntimeError:
        pass
    else:
        raise AssertionError("commit after releasing locks was accepted")
    with state.RelayTransaction() as another:
        try:
            another.prepare(os.getpid(), child.pid)
        except RuntimeError:
            pass
        else:
            raise AssertionError("an existing marker was overwritten")
finally:
    child.terminate()
    child.wait(timeout=5)
"""
        result = self.run_owner(code)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(stale.exists())
        marker = json.loads((self.directory / "maintenance.json").read_text())
        self.assertEqual(marker["phase"], "committed")
        self.assertNotEqual(marker["master"]["pid"], marker["worker"]["pid"])

    def test_untrusted_temporary_blocks_the_transaction(self):
        target = self.root / "unrelated"
        target.write_text("preserve")
        (self.directory / ".maintenance-foreign.tmp").symlink_to(target)
        code = (
            "import sys; sys.path.insert(0, '/tmp/fixture'); "
            "from maintenance_state import RelayTransaction; RelayTransaction().__enter__()"
        )
        result = self.run_owner(code)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid relay maintenance temporary", result.stderr)
        self.assertEqual(target.read_text(), "preserve")
        self.assertFalse((self.directory / "maintenance.json").exists())

    def test_failed_sync_or_a_retired_worker_cannot_commit(self):
        code = r"""
import os, subprocess, sys
from unittest.mock import patch
sys.path.insert(0, "/tmp/fixture")
import maintenance_state as state
child = subprocess.Popen(["/bin/sleep", "10"])
try:
    with state.RelayTransaction() as transaction:
        with patch.object(state.os, "fsync", side_effect=OSError("synthetic failure")):
            try:
                transaction.prepare(os.getpid(), child.pid)
            except OSError:
                pass
            else:
                raise AssertionError("the failed sync was ignored")
        assert not state.MARKER.exists()
        assert not list(state.DIRECTORY.glob(".maintenance-*"))
        transaction.prepare(os.getpid(), child.pid)
        transaction.fence()
        with patch("maintenance_drain.wait_for_drain"):
            transaction.drain(300)
        child.terminate()
        child.wait(timeout=5)
        try:
            transaction.commit()
        except (FileNotFoundError, RuntimeError):
            pass
        else:
            raise AssertionError("a retired worker was committed")
        assert state.read_marker()["phase"] == "preparing"
finally:
    if child.poll() is None:
        child.terminate()
        child.wait(timeout=5)
"""
        result = self.run_owner(code)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            json.loads((self.directory / "maintenance.json").read_text())["phase"],
            "preparing",
        )

    def test_abort_reopens_and_retains_marker_if_reopening_fails(self):
        code = r"""
import os, subprocess, sys
from pathlib import Path
sys.path.insert(0, "/tmp/fixture")
import maintenance_state as state
child = subprocess.Popen(["/bin/sleep", "10"])
try:
    with state.RelayTransaction() as transaction:
        transaction.prepare(os.getpid(), child.pid)
        transaction.fence()
        failure = Path("/tmp/fixture/fail-nft")
        failure.touch()
        try:
            transaction.abort()
        except RuntimeError:
            pass
        else:
            raise AssertionError("a failed reopen was ignored")
        assert state.read_marker()["phase"] == "preparing"
        failure.unlink()
        transaction.abort()
        assert not state.MARKER.exists()
finally:
    child.terminate()
    child.wait(timeout=5)
"""
        result = self.run_owner(code)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.directory / "maintenance.json").exists())
        self.assertEqual(
            (self.src / "nft-calls").read_text().splitlines(),
            [
                "-f /usr/local/lib/remote-coder-relay/maintenance-firewall.nft",
                "-f -",
                "-f -",
            ],
        )

    def test_drain_failure_reopens_and_a_failed_reopen_preserves_the_marker(self):
        code = r"""
import os, subprocess, sys
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, "/tmp/fixture")
import maintenance_state as state
child = subprocess.Popen(["/bin/sleep", "10"])
try:
    with state.RelayTransaction() as transaction:
        for reopening_fails in (False, True):
            transaction.prepare(os.getpid(), child.pid)
            transaction.fence()
            failure = Path("/tmp/fixture/fail-nft")
            if reopening_fails:
                failure.touch()
            with patch("maintenance_drain.wait_for_drain", side_effect=TimeoutError("busy")):
                try:
                    transaction.drain(3)
                except (TimeoutError, RuntimeError):
                    pass
                else:
                    raise AssertionError("drain failure was ignored")
            assert state.MARKER.exists() == reopening_fails
            if reopening_fails:
                assert state.read_marker()["phase"] == "preparing"
                failure.unlink()
                transaction.abort()
finally:
    child.terminate()
    child.wait(timeout=5)
"""
        result = self.run_owner(code)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.directory / "maintenance.json").exists())


if __name__ == "__main__":
    unittest.main()
