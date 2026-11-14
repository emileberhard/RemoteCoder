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
        shutil.copyfile(
            SERVER / "maintenance-prepare", self.src / "maintenance-prepare"
        )
        systemctl = self.src / "systemctl"
        systemctl.write_text(
            "#!/bin/sh\n"
            'test "$1" = reboot || exit 1\n'
            'grep -q \'"phase":"reboot-requesting"\' /var/lib/remote-coder-relay/maintenance.json || exit 1\n'
            'printf "%s\\n" "$1" >> /tmp/fixture/systemctl-calls\n'
            "test ! -e /tmp/fixture/fail-systemctl\n"
        )
        systemctl.chmod(0o755)
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
                "/usr",
                "/usr",
                "--symlink",
                "usr/bin",
                "/bin",
                "--symlink",
                "usr/sbin",
                "/sbin",
                "--symlink",
                "usr/lib",
                "/lib",
                "--symlink",
                "usr/lib64",
                "/lib64",
                "--dir",
                "/etc",
                "--dir",
                "/var",
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
                "--ro-bind",
                str(self.src / "systemctl"),
                "/usr/bin/systemctl",
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

    def test_ambiguous_fence_failure_reopens_or_keeps_the_marker(self):
        code = r"""
import os, subprocess, sys
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, "/tmp/fixture")
import maintenance_state as state
child = subprocess.Popen(["/bin/sleep", "10"])
original_run = subprocess.run
def interrupted(command, **kwargs):
    if command[-1] == str(state.FIREWALL):
        raise subprocess.TimeoutExpired(command, 10)
    return original_run(command, **kwargs)
try:
    with state.RelayTransaction() as transaction:
        for reopening_fails in (False, True):
            transaction.prepare(os.getpid(), child.pid)
            failure = Path("/tmp/fixture/fail-nft")
            if reopening_fails:
                failure.touch()
            with patch.object(state.subprocess, "run", side_effect=interrupted):
                try:
                    transaction.fence()
                except (subprocess.TimeoutExpired, RuntimeError):
                    pass
                else:
                    raise AssertionError("an uncertain fence was accepted")
            assert state.MARKER.exists() == reopening_fails
            if reopening_fails:
                failure.unlink()
                transaction.abort()
finally:
    child.terminate()
    child.wait(timeout=5)
"""
        result = self.run_owner(code)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.directory / "maintenance.json").exists())

    def test_idle_preparation_orders_candidate_marker_fence_and_drain(self):
        code = r"""
import os, subprocess, sys
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, "/tmp/fixture")
import maintenance_drain as drain
import maintenance_state as state
child = subprocess.Popen(["/bin/sleep", "10"])
identity = {"master": state.worker_identity(os.getpid()), "worker": state.worker_identity(child.pid)}
def candidate(observed, timeout):
    assert observed == identity and timeout == 20
    assert not state.MARKER.exists()
    assert not Path("/tmp/fixture/nft-calls").exists()
def completed(observed, timeout):
    assert observed == identity and timeout == 30
    assert state.read_marker()["phase"] == "preparing"
    assert (state.DIRECTORY / "maintenance.json").exists()
    assert open("/tmp/fixture/nft-calls").read().splitlines()[-1].endswith("maintenance-firewall.nft")
try:
    with state.RelayTransaction() as transaction:
        with patch.object(drain, "haproxy_identity", return_value=identity), patch.object(drain, "wait_for_candidate", side_effect=candidate), patch.object(drain, "wait_for_drain", side_effect=completed):
            transaction.prepare_idle(20, 30)
        assert state.read_marker()["phase"] == "preparing"
        transaction.abort()
        assert not state.MARKER.exists()
        with patch.object(drain, "haproxy_identity", return_value=identity), patch.object(drain, "wait_for_candidate", side_effect=TimeoutError("busy")):
            try:
                transaction.prepare_idle(20, 30)
            except TimeoutError:
                pass
            else:
                raise AssertionError("busy candidate was accepted")
        assert not state.MARKER.exists()
finally:
    child.terminate()
    child.wait(timeout=5)
"""
        result = self.run_owner(code)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.directory / "maintenance.json").exists())

    def test_new_boot_reopens_only_after_local_checks_and_fence_recheck(self):
        code = r"""
import os, subprocess, sys
from unittest.mock import patch
sys.path.insert(0, "/tmp/fixture")
import maintenance_drain as drain
import maintenance_state as state
child = subprocess.Popen(["/bin/sleep", "10"])
try:
    with state.RelayTransaction() as transaction:
        transaction.prepare(os.getpid(), child.pid)
    original = state.MARKER.read_bytes()
    with state.RelayTransaction() as transaction:
        try:
            transaction.reopen_after_new_boot(10)
        except RuntimeError:
            pass
        else:
            raise AssertionError("same boot reopened admission")
        with patch.object(state, "boot_id", return_value="00000000-0000-4000-8000-000000000001"), patch.object(drain, "verify_local_boot_prerequisites", side_effect=RuntimeError("unhealthy")):
            try:
                transaction.reopen_after_new_boot(10)
            except RuntimeError:
                pass
            else:
                raise AssertionError("unhealthy boot reopened admission")
        assert state.MARKER.read_bytes() == original
        with patch.object(state, "boot_id", return_value="00000000-0000-4000-8000-000000000001"), patch.object(drain, "verify_local_boot_prerequisites", return_value={"worker": 7}), patch.object(drain, "fence_is_configured", side_effect=RuntimeError("missing fence")):
            try:
                transaction.reopen_after_new_boot(10)
            except RuntimeError:
                pass
            else:
                raise AssertionError("a missing fence was accepted")
        assert state.MARKER.read_bytes() == original
        with patch.object(state, "boot_id", return_value="00000000-0000-4000-8000-000000000001"), patch.object(drain, "verify_local_boot_prerequisites", return_value={"worker": 7}), patch.object(drain, "fence_is_configured"):
            assert transaction.reopen_after_new_boot(10) == {"worker": 7}
        assert not state.MARKER.exists()
finally:
    child.terminate()
    child.wait(timeout=5)
"""
        result = self.run_owner(code)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.directory / "maintenance.json").exists())
        self.assertEqual((self.src / "nft-calls").read_text().splitlines(), ["-f -"])

    def test_same_boot_owner_recovers_unsubmitted_but_preserves_uncertain_reboot(self):
        code = r"""
import os, subprocess, sys
from unittest.mock import patch
sys.path.insert(0, "/tmp/fixture")
import maintenance_drain as drain
import maintenance_state as state
child = subprocess.Popen(["/bin/sleep", "10"])
try:
    for phase in ("preparing", "committed", "reboot-requesting"):
        with state.RelayTransaction() as transaction:
            transaction.prepare(os.getpid(), child.pid)
            if phase != "preparing":
                transaction.fence()
                with patch.object(drain, "wait_for_drain"):
                    transaction.drain(30)
                if phase == "committed":
                    transaction.commit()
                else:
                    with patch.object(state, "_reboot_window", return_value=True), patch.object(drain, "snapshot", return_value=False):
                        transaction.enqueue_reboot()
        assert state.read_marker()["phase"] == phase
        with state.RelayTransaction() as recovery:
            if phase != "reboot-requesting":
                if phase == "committed":
                    with patch.object(drain, "fence_is_configured", side_effect=RuntimeError("missing fence")):
                        try:
                            recovery.reconcile_pending(10)
                        except RuntimeError as error:
                            assert "missing fence" in str(error)
                        else:
                            raise AssertionError("a missing committed fence was ignored")
                    assert state.MARKER.exists()
                with patch.object(drain, "fence_is_configured"):
                    assert "abandoned" in recovery.reconcile_pending(10)
                assert not state.MARKER.exists()
            else:
                for _ in range(2):
                    try:
                        recovery.reconcile_pending(10)
                    except RuntimeError as error:
                        assert "uncertain" in str(error)
                    else:
                        raise AssertionError("uncertain reboot was reopened")
                    assert state.read_marker()["phase"] == "reboot-requesting"
                with patch.object(state, "boot_id", return_value="00000000-0000-4000-8000-000000000001"), patch.object(drain, "verify_local_boot_prerequisites", return_value={"worker": 7}), patch.object(drain, "fence_is_configured"):
                    assert "new-boot" in recovery.reconcile_pending(10)
                assert not state.MARKER.exists()
finally:
    child.terminate()
    child.wait(timeout=5)
"""
        result = self.run_owner(code)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_reboot_enqueue_requires_idle_window_and_persists_uncertainty(self):
        code = r"""
import contextlib, os, subprocess, sys
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, "/tmp/fixture")
import maintenance_drain as drain
import maintenance_state as state
child = subprocess.Popen(["/bin/sleep", "10"])
try:
    for case in ("wrong_time", "busy", "elapsed_before_commit", "elapsed_after_commit", "commit_uncertain", "intent_before_write", "intent_after_write", "timeout", "failed", "success"):
        with state.RelayTransaction() as transaction:
            transaction.prepare(os.getpid(), child.pid)
            transaction.fence()
            with patch.object(drain, "wait_for_drain"):
                transaction.drain(30)
            failure = Path("/tmp/fixture/fail-systemctl")
            if case == "failed":
                failure.touch()
            windows = {"wrong_time": [False], "elapsed_before_commit": [True, False], "elapsed_after_commit": [True, True, False]}.get(case, [True, True, True])
            original_write = state._write_marker
            def uncertain_write(marker):
                original_write(marker)
                raise OSError("lost completion after durable write")
            def interrupted_intent(marker):
                if marker["phase"] == "reboot-requesting":
                    if case == "intent_after_write":
                        original_write(marker)
                    raise OSError("interrupted request intent")
                original_write(marker)
            if case == "commit_uncertain":
                writer = patch.object(state, "_write_marker", side_effect=uncertain_write)
            elif case in ("intent_before_write", "intent_after_write"):
                writer = patch.object(state, "_write_marker", side_effect=interrupted_intent)
            else:
                writer = contextlib.nullcontext()
            request = patch.object(state.subprocess, "run", side_effect=subprocess.TimeoutExpired("systemctl", 15)) if case == "timeout" else contextlib.nullcontext()
            with patch.object(state, "_reboot_window", side_effect=windows), patch.object(drain, "snapshot", return_value=case == "busy"), writer, request:
                try:
                    transaction.enqueue_reboot()
                except (RuntimeError, OSError):
                    if case == "success":
                        raise
                else:
                    assert case == "success"
            if case in ("wrong_time", "busy", "elapsed_before_commit"):
                assert not state.MARKER.exists()
                assert not Path("/tmp/fixture/systemctl-calls").exists()
            else:
                expected_phase = "committed" if case in ("elapsed_after_commit", "commit_uncertain", "intent_before_write") else "reboot-requesting"
                assert state.read_marker()["phase"] == expected_phase
                try:
                    transaction.abort()
                except RuntimeError:
                    pass
                else:
                    raise AssertionError("committed admission reopened")
                failure.unlink(missing_ok=True)
        if state.MARKER.exists():
            state.MARKER.unlink()
finally:
    child.terminate()
    child.wait(timeout=5)
"""
        result = self.run_owner(code)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            (self.src / "systemctl-calls").read_text().splitlines(),
            ["reboot", "reboot"],
        )

    def test_prepare_entrypoint_fences_drains_and_enqueues_only_after_commit(self):
        code = r"""
import importlib.machinery, importlib.util, os, subprocess, sys
from unittest.mock import patch
sys.path.insert(0, "/tmp/fixture")
import maintenance_drain as drain
import maintenance_state as state
loader = importlib.machinery.SourceFileLoader("prepare_fixture", "/tmp/fixture/maintenance-prepare")
spec = importlib.util.spec_from_loader(loader.name, loader)
prepare = importlib.util.module_from_spec(spec)
loader.exec_module(prepare)
child = subprocess.Popen(["/bin/sleep", "10"])
try:
    identity = {"master": state.worker_identity(os.getpid()), "worker": state.worker_identity(child.pid)}
    with patch.object(prepare, "_reboot_window", return_value=True), patch.object(state, "_reboot_window", return_value=True), patch.object(drain, "haproxy_identity", return_value=identity), patch.object(drain, "wait_for_candidate"), patch.object(drain, "wait_for_drain"), patch.object(drain, "snapshot", return_value=False):
        prepare.prepare()
    assert state.read_marker()["phase"] == "reboot-requesting"
finally:
    child.terminate()
    child.wait(timeout=5)
"""
        result = self.run_owner(code)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            (self.src / "systemctl-calls").read_text().splitlines(), ["reboot"]
        )
        self.assertEqual(
            json.loads((self.directory / "maintenance.json").read_text())["phase"],
            "reboot-requesting",
        )


if __name__ == "__main__":
    unittest.main()
