import fcntl
import importlib.util
import json
import os
import select
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import build_support as support
from process_group import (
    audit_alive,
    process_identity,
    signal_process,
    terminate_process,
)

spec = importlib.util.spec_from_file_location("measurement", SCRIPTS / "measurement.py")
measurement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measurement)


class MeasurementTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.cache = self.root / "Library/Caches/RemoteCoder-Build"
        self.environment = os.environ | {"HOME": str(self.root)}

    def start(self, code, *arguments):
        bootstrap = "import sys; sys.path.insert(0,sys.argv.pop(1)); " + code
        process = subprocess.Popen(
            [sys.executable, "-c", bootstrap, str(SCRIPTS), *map(str, arguments)],
            env=self.environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            start_new_session=True,
        )

        def cleanup():
            child = self.root / "child.pid"
            if child.exists():
                pid = int(child.read_text())
                identity = subprocess.run(
                    ["ps", "-p", str(pid), "-o", "args="],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                if identity.returncode == 0 and str(self.root) in identity.stdout:
                    try:
                        group_file = self.root / "group.pid"
                        group = (
                            int(group_file.read_text())
                            if group_file.exists()
                            else os.getpgid(pid)
                        )
                        os.killpg(group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=60)

        self.addCleanup(cleanup)
        return process

    def line(self, process):
        self.assertTrue(select.select([process.stdout], [], [], 60)[0])
        value = process.stdout.readline().decode().strip()
        self.assertTrue(
            value, process.stderr.read() if process.poll() is not None else "No event"
        )
        return value

    def reservation(self, hold_seconds, command):
        supervisor = (
            "import sys; sys.path.insert(0,"
            + repr(str(SCRIPTS))
            + "); from pathlib import Path; from measurement import reserve; sys.exit(reserve(Path(sys.argv[1]),"
            + str(hold_seconds)
            + ",[sys.executable,'-c',sys.argv[2]]))"
        )
        return self.start(
            "from build_support import run_connected; r=run_connected([sys.executable,'-c',"
            + repr(supervisor)
            + ",sys.argv[1],sys.argv[2]]); print(r.stdout,end=''); sys.exit(r.returncode)",
            self.source,
            command,
        )

    def holder(self):
        receipt = json.loads(
            max(
                (self.cache / "runs").glob("*/receipt.json"),
                key=lambda path: path.stat().st_mtime_ns,
            ).read_text()
        )
        owner = process_identity(receipt["ownerPid"])
        rows = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
        guards = [
            int(parts[0])
            for line in rows.splitlines()
            if len(parts := line.split()) == 2 and int(parts[1]) == owner["pid"]
        ]
        self.assertEqual(len(guards), 1)
        return owner, process_identity(guards[0])

    def wait_file(self, path, process):
        deadline = time.monotonic() + 60
        while not path.exists():
            self.assertIsNone(process.poll(), "Owner exited before readiness")
            self.assertLess(time.monotonic(), deadline, f"No event: {path}")
            time.sleep(0.01)

    def assert_locked(self, path):
        with path.open("a") as lease, self.assertRaises(BlockingIOError):
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def assert_capacity_free(self):
        with ExitStack() as ownership:
            for name in ("admission.lock", "0.lock", "1.lock"):
                lease = ownership.enter_context(
                    (self.cache / "capacity" / name).open("a")
                )
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_pending_reservation_drains_earlier_jobs_before_admitting_later_work(self):
        code = "from build_support import build_capacity; exec(\"with build_capacity():\\n print('admitted',flush=True)\\n sys.stdin.read(1)\")"
        earlier = []
        for _ in range(2):
            process = self.start(code)
            self.assertEqual(self.line(process), "admitted")
            earlier.append(process)
        reserver = self.start(
            "import threading; from pathlib import Path; import build_support as b; from contextlib import contextmanager; exec(\"original=b._lease_before\\n@contextmanager\\ndef observed(path,deadline,cancellation):\\n with original(path,deadline,cancellation) as fd:\\n  print(path.name,flush=True)\\n  yield fd\\nb._lease_before=observed\\nwith b.measurement_capacity(Path(sys.argv[1]),60,threading.Event()):\\n print('reserved',flush=True)\\n sys.stdin.read(1)\")",
            self.source,
        )
        self.assertEqual(
            self.line(reserver), support.source_lease_path(self.source).name
        )
        self.assertEqual(self.line(reserver), "admission.lock")
        self.assert_locked(self.cache / "capacity/admission.lock")
        later = self.start(
            "import build_support as b; from contextlib import contextmanager; exec(\"original=b.file_lease\\n@contextmanager\\ndef observed(path):\\n print('gate-requested',flush=True)\\n with original(path) as fd:\\n  yield fd\\nb.file_lease=observed\\nwith b.build_capacity():\\n print('admitted',flush=True)\\n sys.stdin.read(1)\")"
        )
        self.assertEqual(self.line(later), "gate-requested")
        earlier[0].stdin.write(b".")
        earlier[0].stdin.flush()
        earlier[0].communicate(timeout=60)
        self.assertEqual(earlier[0].returncode, 0)
        self.assertEqual(self.line(reserver), "0.lock")
        self.assert_locked(self.cache / "capacity/admission.lock")
        earlier[1].stdin.write(b".")
        earlier[1].stdin.flush()
        earlier[1].communicate(timeout=60)
        self.assertEqual(earlier[1].returncode, 0)
        self.assertEqual(self.line(reserver), "1.lock")
        self.assertEqual(self.line(reserver), "reserved")
        self.assertIsNone(later.poll())
        for name in ("0.lock", "1.lock"):
            self.assert_locked(self.cache / "capacity" / name)
        reserver.stdin.write(b".")
        reserver.stdin.flush()
        reserver.communicate(timeout=60)
        self.assertEqual(reserver.returncode, 0)
        self.assertEqual(self.line(later), "admitted")
        later.communicate(b".", timeout=60)
        self.assertEqual(later.returncode, 0)
        self.assert_capacity_free()

    def test_pending_reservation_prevents_overtaking_before_it_acquires_the_gate(self):
        pending = self.root / "pending"
        retry = self.root / "retry"
        self.cache.joinpath("capacity").mkdir(parents=True)
        with support.file_lease(self.cache / "capacity/admission.lock"):
            reserver = self.start(
                "import threading,time; from pathlib import Path; import build_support as b; from contextlib import contextmanager; exec(\"original=b._lease_before\\n@contextmanager\\ndef observed(path,deadline,cancellation):\\n if path.name=='admission.lock':\\n  Path(sys.argv[2]).touch()\\n  while not Path(sys.argv[3]).exists():\\n   time.sleep(.01)\\n with original(path,deadline,cancellation) as fd:\\n  yield fd\\nb._lease_before=observed\\nwith b.measurement_capacity(Path(sys.argv[1]),60,threading.Event()):\\n print('reserved',flush=True)\\n sys.stdin.read(1)\")",
                self.source,
                pending,
                retry,
            )
            self.wait_file(pending, reserver)
            later = [
                self.start(
                    "import build_support as b; from contextlib import contextmanager; exec(\"original=b.file_lease\\n@contextmanager\\ndef observed(path):\\n with original(path) as fd:\\n  yield fd\\n print('gate-passed',flush=True)\\nb.file_lease=observed\\nwith b.build_capacity():\\n print('admitted',flush=True)\\n sys.stdin.read(1)\")"
                )
                for _ in range(3)
            ]
        for worker in later:
            self.assertEqual(self.line(worker), "gate-passed")
        for name in ("0.lock", "1.lock"):
            with (self.cache / "capacity" / name).open("a") as lease:
                try:
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    self.fail(f"A later build overtook the pending reservation: {name}")
        retry.touch()
        self.assertEqual(self.line(reserver), "reserved")
        for name in ("0.lock", "1.lock"):
            self.assert_locked(self.cache / "capacity" / name)
        reserver.communicate(b".", timeout=60)
        self.assertEqual(reserver.returncode, 0)
        for worker in later:
            worker.stdin.write(b".")
            worker.stdin.flush()
        for worker in later:
            output, errors = worker.communicate(timeout=60)
            self.assertEqual(worker.returncode, 0, output + errors)
            self.assertIn(b"admitted", output)
        self.assert_capacity_free()

    def test_timeout_and_cancellation_release_partial_reservations(self):
        with patch("build_support.cache_root", return_value=self.cache):
            self.cache.joinpath("capacity").mkdir(parents=True)
            with support.file_lease(self.cache / "capacity/1.lock"):
                with (
                    self.assertRaises(TimeoutError),
                    support.measurement_capacity(self.source, 0.02, threading.Event()),
                ):
                    self.fail("Busy slot must block")
                for name in ("admission.lock", "0.lock"):
                    with (self.cache / "capacity" / name).open("a") as lease:
                        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                cancelled = threading.Event()
                cancelled.set()
                with (
                    self.assertRaises(SystemExit),
                    support.measurement_capacity(self.source, 60, cancelled),
                ):
                    self.fail("Cancelled reservation must not start")
            self.assert_capacity_free()

    def test_mirror_source_keeps_both_legacy_locks_and_stable_worktree_lease(self):
        from build_cache import lease_path

        source = self.cache / "worktrees/fixture/ios/repo"
        source.mkdir(parents=True)
        with patch("build_support.cache_root", return_value=self.cache):
            with support.measurement_capacity(source, 60, threading.Event()):
                self.assert_locked(lease_path(self.cache, "worktrees", "fixture"))
                for group in ("ios", "gateway"):
                    self.assert_locked(
                        self.cache / "worktrees/fixture" / group / "build.lock"
                    )
            self.assert_capacity_free()

    def test_process_exit_releases_capacity_and_source_ownership(self):
        owner = self.start(
            "import threading; from pathlib import Path; from build_support import measurement_capacity; exec(\"with measurement_capacity(Path(sys.argv[1]),60,threading.Event()):\\n print('reserved',flush=True)\\n sys.stdin.read(1)\")",
            self.source,
        )
        self.assertEqual(self.line(owner), "reserved")
        owner.kill()
        owner.communicate(timeout=60)
        self.assert_capacity_free()
        source_lock = (
            self.cache / "local-installs" / support.source_lease_path(self.source).name
        )
        with source_lock.open("a") as lease:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with patch("build_support.cache_root", return_value=self.cache):
            with support.build_capacity():
                self.assertFalse(
                    list((self.cache / "capacity").glob("measurement-*.lock"))
                )

    def test_supervisor_sigkill_still_terminates_the_inheriting_command_before_releasing_capacity(
        self,
    ):
        child = self.root / "child.pid"
        terminated = self.root / "terminated"
        code = "\n".join(
            (
                "import os,signal,time",
                "from pathlib import Path",
                "def terminate(*_):",
                f" Path({str(terminated)!r}).touch()",
                " while True: time.sleep(1)",
                "signal.signal(signal.SIGTERM,terminate)",
                f"p=Path({str(child)!r})",
                "t=p.with_suffix('.tmp'); t.write_text(str(os.getpid())); t.replace(p)",
                "signal.pause()",
            )
        )
        worker = self.start(
            "from pathlib import Path; import measurement as m; sys.exit(m.reserve(Path(sys.argv[1]),10,[sys.executable,'-c',sys.argv[2]]))",
            self.source,
            code,
        )
        self.wait_file(child, worker)
        pid = int(child.read_text())
        worker.kill()
        worker.wait(timeout=60)
        deadline = time.monotonic() + 60
        while not terminated.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(
            terminated.exists(), "Command survived its reservation supervisor"
        )
        for name in ("admission.lock", "0.lock", "1.lock"):
            self.assert_locked(self.cache / "capacity" / name)
        source_lock = (
            self.cache / "local-installs" / support.source_lease_path(self.source).name
        )
        self.assert_locked(source_lock)
        worker.communicate(timeout=60)
        state = subprocess.run(
            ["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True
        )
        self.assertTrue(
            state.returncode or state.stdout.strip().startswith("Z"), state.stdout
        )
        self.assert_capacity_free()

    def test_receipt_records_queue_and_success_without_changing_stdout(self):
        child = "import os,json; print(json.dumps({'reservation':os.environ['RC_MEASUREMENT_RECEIPT']}))"
        supervisor = (
            "import sys; sys.path.insert(0,"
            + repr(str(SCRIPTS))
            + "); from pathlib import Path; from measurement import reserve; sys.exit(reserve(Path(sys.argv[1]),60,[sys.executable,'-c',"
            + repr(child)
            + "]))"
        )
        client = (
            "from build_support import run_connected; r=run_connected([sys.executable,'-c',"
            + repr(supervisor)
            + ",sys.argv[1]]); print(r.stdout,end=''); sys.exit(r.returncode)"
        )
        worker = self.start(client, self.source)
        output, errors = worker.communicate(b".", timeout=60)
        self.assertEqual(worker.returncode, 0, errors)
        receipt = json.loads(Path(json.loads(output)["reservation"]).read_text())
        self.assertEqual(receipt["exitCode"], 0)
        self.assertGreaterEqual(receipt["queueWaitSeconds"], 0)
        self.assertTrue(receipt["acquiredAt"])
        self.assertTrue(receipt["releasedAt"])
        self.assertEqual(receipt["holdLimitSeconds"], 60)
        self.assert_capacity_free()

    def test_guard_sigkill_cannot_strand_capacity_with_an_open_or_closed_command_stdout(
        self,
    ):
        for closes_stdout in (False, True):
            with self.subTest(closes_stdout=closes_stdout):
                child = self.root / "child.pid"
                child.unlink(missing_ok=True)
                code = (
                    "import os,signal; from pathlib import Path; "
                    + ("os.close(1); " if closes_stdout else "")
                    + "p=Path("
                    + repr(str(child))
                    + "); t=p.with_suffix('.tmp'); t.write_text(str(os.getpid())); t.replace(p); signal.pause()"
                )
                worker = self.reservation(60, code)
                self.wait_file(child, worker)
                owner, guard = self.holder()
                try:
                    terminate_process(guard)
                    worker.wait(timeout=60)
                    self.assertNotEqual(worker.returncode, 0)
                    pid = int(child.read_text())
                    state = subprocess.run(
                        ["ps", "-p", str(pid), "-o", "stat="],
                        capture_output=True,
                        text=True,
                    )
                    self.assertTrue(
                        state.returncode or state.stdout.strip().startswith("Z"),
                        state.stdout,
                    )
                    worker.communicate(timeout=60)
                    self.assert_capacity_free()
                finally:
                    terminate_process(owner)
                    terminate_process(guard)

    def test_contender_reclaims_a_deadline_after_both_supervisors_are_killed(self):
        child = self.root / "child.pid"
        code = (
            "import os,signal; from pathlib import Path; p=Path("
            + repr(str(child))
            + "); t=p.with_suffix('.tmp'); t.write_text(str(os.getpid())); t.replace(p); signal.pause()"
        )
        worker = self.reservation(60, code)
        self.wait_file(child, worker)
        owner, guard = self.holder()
        record_path = next((self.cache / "capacity").glob("measurement-*.json"))
        holder = json.loads(record_path.read_text())
        try:
            terminate_process(owner)
            terminate_process(guard)
            worker.wait(timeout=60)
            expire = self.root / "expire-holder"
            contender = self.start(
                "import types,time; from pathlib import Path; import build_support as b; from contextlib import contextmanager; original_time=time.monotonic; b.time=types.SimpleNamespace(monotonic=lambda:float(sys.argv[2]) if Path(sys.argv[3]).exists() else original_time(),sleep=time.sleep); exec(\"original=b.file_lease\\n@contextmanager\\ndef observed(path):\\n with original(path) as fd:\\n  yield fd\\n if path.name=='admission.lock':\\n  print('attempted',flush=True)\\nb.file_lease=observed\\nwith b.file_lease(b.source_lease_path(Path(sys.argv[1]))), b.build_capacity():\\n print('admitted',flush=True)\\n sys.stdin.read(1)\")",
                self.source,
                holder["deadline"] + 1,
                expire,
            )
            self.assertEqual(self.line(contender), "attempted")
            self.assertIsNotNone(process_identity(int(child.read_text())))
            expire.touch()
            while self.line(contender) != "admitted":
                pass
            state = subprocess.run(
                ["ps", "-p", child.read_text(), "-o", "stat="],
                capture_output=True,
                text=True,
            )
            self.assertTrue(
                state.returncode or state.stdout.strip().startswith("Z"), state.stdout
            )
            self.assertFalse(record_path.exists())
            self.assertFalse(list((self.cache / "capacity").glob("*measurement*")))
            contender.communicate(b".", timeout=60)
            self.assertEqual(contender.returncode, 0)
            worker.communicate(timeout=60)
            self.assert_capacity_free()
        finally:
            terminate_process(owner)
            terminate_process(guard)

    def test_expired_record_does_not_signal_a_reused_process_identity(self):
        unrelated = self.start(
            "import signal; print('ready',flush=True); signal.pause()"
        )
        self.assertEqual(self.line(unrelated), "ready")
        stale = process_identity(unrelated.pid) | {"startedAtMicroseconds": 1}
        self.cache.joinpath("capacity").mkdir(parents=True)
        record = self.cache / "capacity/measurement-stale.json"
        record.with_suffix(".lock").touch()
        support.atomic_json(
            record,
            {
                "owner": stale,
                "boot": support.boot_identity(),
                "guard": None,
                "command": stale,
                "deadline": time.monotonic() - 1,
            },
        )
        with patch("build_support.cache_root", return_value=self.cache):
            with support.build_capacity():
                self.assertIsNone(unrelated.poll())
                self.assertFalse(record.exists())

    def test_registration_stall_never_inherits_leases_and_expiry_recovers_both_mutex_boundaries(
        self,
    ):
        for phase in ("before", "after"):
            with self.subTest(phase=phase):
                ready = self.root / "registration.json"
                ready.unlink(missing_ok=True)
                shim = self.root / "guard-shim.py"
                shim.write_text(
                    "import sys,os,signal,json; sys.path.insert(0,"
                    + repr(str(SCRIPTS))
                    + "); import measurement as m; import build_support as b; from contextlib import contextmanager; from pathlib import Path; from process_group import process_identity; exec("
                    + repr(
                        "original=m.measurement_record_lease\n"
                        "def stop(path):\n"
                        f" p=Path({str(ready)!r}); t=p.with_suffix('.tmp'); t.write_text(json.dumps(dict(pid=os.getpid(),mutex=str(b._record_mutex(path))))); t.replace(p)\n"
                        " os.kill(os.getpid(),signal.SIGSTOP)\n"
                        "@contextmanager\n"
                        "def observed(path):\n"
                        + (" stop(path)\n" if phase == "before" else "")
                        + " with original(path):\n"
                        + ("  stop(path)\n" if phase == "after" else "")
                        + "  yield\n"
                        "m.measurement_record_lease=observed\n"
                        "m._guard_main()"
                    )
                    + ")"
                )
                supervisor = (
                    "import sys; sys.path.insert(0,"
                    + repr(str(SCRIPTS))
                    + "); import measurement as m; from pathlib import Path; m.__file__="
                    + repr(str(shim))
                    + "; sys.exit(m.reserve(Path(sys.argv[1]),60,[sys.executable,'-c','raise SystemExit(99)']))"
                )
                worker = self.start(
                    "from build_support import run_connected; r=run_connected([sys.executable,'-c',"
                    + repr(supervisor)
                    + ",sys.argv[1]]); sys.exit(r.returncode)",
                    self.source,
                )
                self.wait_file(ready, worker)
                registration = json.loads(ready.read_text())
                guard = process_identity(registration["pid"])
                owner = process_identity(guard["ppid"])
                mutex = Path(registration["mutex"])
                inode = mutex.stat().st_ino
                record_path = next((self.cache / "capacity").glob("measurement-*.json"))
                holder = json.loads(record_path.read_text())
                try:
                    deadline = time.monotonic() + 60
                    while process_identity(guard["pid"])["state"] != 4:
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(0.01)
                    terminate_process(owner)
                    worker.wait(timeout=60)
                    self.assert_capacity_free()
                    contender = self.start(
                        "import types,time; from build_support import build_capacity; import build_support as b; b.time=types.SimpleNamespace(monotonic=lambda:float(sys.argv[1]),sleep=time.sleep); exec(\"with build_capacity():\\n print('admitted',flush=True)\")",
                        holder["deadline"] + 1,
                    )
                    output, errors = contender.communicate(timeout=60)
                    self.assertEqual(contender.returncode, 0, output + errors)
                    self.assertIn(b"admitted", output)
                    self.assertFalse(audit_alive(guard))
                    self.assertFalse(record_path.exists())
                    self.assertEqual(mutex.stat().st_ino, inode)
                    self.assert_capacity_free()
                    worker.communicate(timeout=60)
                finally:
                    terminate_process(owner)
                    terminate_process(guard)

    def test_stalled_activation_writer_is_reclaimed_at_committed_deadline(
        self,
    ):
        owner = self.start(
            'import threading; from pathlib import Path; import build_support as b; exec("with b.measurement_capacity(Path(sys.argv[1]),60,threading.Event()) as capacity:\\n with b.measurement_record_lease(capacity.record):\\n  print(str(capacity.record),flush=True)\\n  sys.stdin.read(1)")',
            self.source,
        )
        record_path = Path(self.line(owner))
        record = json.loads(record_path.read_text())
        signal_process(record["owner"], signal.SIGSTOP)
        contender = self.start(
            "import types,time; from pathlib import Path; import build_support as b; b.time=types.SimpleNamespace(monotonic=lambda:float(sys.argv[2]),sleep=time.sleep); exec(\"with b.file_lease(b.source_lease_path(Path(sys.argv[1]))), b.build_capacity():\\n print('admitted',flush=True)\")",
            self.source,
            record["deadline"] + 1,
        )
        output, errors = contender.communicate(timeout=60)
        self.assertEqual(contender.returncode, 0, output + errors)
        self.assertIn(b"admitted", output)
        owner.communicate(timeout=60)
        self.assertEqual(owner.returncode, -signal.SIGKILL)
        self.assertFalse(record_path.exists())
        self.assert_capacity_free()

    def test_expired_snapshot_does_not_reclaim_a_renewed_operation(self):
        owner = self.start(
            "import threading,json; from pathlib import Path; import build_support as b; exec(\"with b.measurement_capacity(Path(sys.argv[1]),60,threading.Event()) as capacity:\\n with b.measurement_record_lease(capacity.record):\\n  print(str(capacity.record),flush=True)\\n  sys.stdin.read(1)\\n  record=json.loads(capacity.record.read_text()); record['deadline']+=120; b.atomic_json(capacity.record,record)\\n  print('renewed',flush=True)\\n  sys.stdin.read(1)\")",
            self.source,
        )
        record_path = Path(self.line(owner))
        record = json.loads(record_path.read_text())
        contender = self.start(
            "import types,time; from contextlib import contextmanager; import build_support as b; b.time=types.SimpleNamespace(monotonic=lambda:float(sys.argv[1]),sleep=time.sleep); exec(\"original=b.suspended_processes\\n@contextmanager\\ndef observed(identities):\\n print('before-freeze',flush=True)\\n sys.stdin.read(1)\\n with original(identities):\\n  yield\\nb.suspended_processes=observed\\nb.reclaim_expired_measurements()\\nprint('checked',flush=True)\")",
            record["deadline"] + 1,
        )
        self.assertEqual(self.line(contender), "before-freeze")
        owner.stdin.write(b".")
        owner.stdin.flush()
        self.assertEqual(self.line(owner), "renewed")
        output, errors = contender.communicate(b".", timeout=60)
        self.assertEqual(contender.returncode, 0, output + errors)
        self.assertIn(b"checked", output)
        self.assertTrue(record_path.exists())
        self.assertTrue(audit_alive(record["owner"]))
        self.assert_locked(self.cache / "capacity/0.lock")
        owner.communicate(b".", timeout=60)
        self.assertEqual(owner.returncode, 0)
        self.assert_capacity_free()

    def test_disconnect_cancels_owned_descendant_and_releases_all_leases(self):
        child = self.root / "child.pid"
        code = (
            "import os,signal; from pathlib import Path; p=Path("
            + repr(str(child))
            + "); t=p.with_suffix('.tmp'); t.write_text(str(os.getpid())); t.replace(p); signal.pause()"
        )
        worker = self.start(
            "from pathlib import Path; import measurement as m; sys.exit(m.reserve(Path(sys.argv[1]),60,[sys.executable,'-c',sys.argv[2]]))",
            self.source,
            code,
        )
        self.wait_file(child, worker)
        pid = int(child.read_text())
        self.assert_locked(self.cache / "capacity/admission.lock")
        output, errors = worker.communicate(timeout=60)
        self.assertEqual(worker.returncode, 128 + signal.SIGHUP, output + errors)
        state = subprocess.run(
            ["ps", "-p", str(pid), "-o", "stat="],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertTrue(
            state.returncode or state.stdout.strip().startswith("Z"), state.stdout
        )
        receipt = json.loads(
            next((self.cache / "runs").glob("*/receipt.json")).read_text()
        )
        self.assertEqual(receipt["exitCode"], 128 + signal.SIGHUP)
        self.assert_capacity_free()

    def test_invalid_limits_fail_before_creating_capacity(self):
        with patch("build_support.cache_root", return_value=self.cache):
            for value in (0, -1, float("nan"), float("inf"), 1801):
                with (
                    self.subTest(value=value),
                    self.assertRaises(ValueError),
                    support.measurement_capacity(self.source, value, threading.Event()),
                ):
                    self.fail("Invalid limit admitted")
        self.assertFalse(self.cache.exists())

    def test_guard_monitor_failure_terminates_its_group_before_releasing_capacity(self):
        child = self.root / "child.pid"
        descendant = (
            "import os,signal; from pathlib import Path; Path("
            + repr(str(self.root / "group.pid"))
            + ").write_text(str(os.getpgrp())); p=Path("
            + repr(str(child))
            + "); t=p.with_suffix('.tmp'); t.write_text(str(os.getpid())); t.replace(p); print('ready',flush=True); signal.pause()"
        )
        leader = (
            "import subprocess,sys; p=subprocess.Popen([sys.executable,'-c',"
            + repr(descendant)
            + "],stdout=subprocess.PIPE); p.stdout.readline()"
        )
        worker = self.start(
            "import threading; from pathlib import Path; import build_support as b; import measurement as m; exec(\"original=b._group_has_live_members\\ndef fail_once(group):\\n b._group_has_live_members=original\\n raise RuntimeError('fixture monitor failure')\\nb._group_has_live_members=fail_once\\nwith b.measurement_capacity(Path(sys.argv[1]),60,threading.Event()):\\n sys.exit(m._guard(Path(sys.argv[1]),60,Path(sys.argv[3]),next((b.cache_root()/'capacity').glob('measurement-*.json')),[sys.executable,'-c',sys.argv[2]]))\")",
            self.source,
            leader,
            self.root / "command-result.json",
        )
        self.wait_file(child, worker)
        worker.wait(timeout=60)
        self.assertEqual(worker.returncode, 1)
        pid = int(child.read_text())
        state = subprocess.run(
            ["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True
        )
        self.assertTrue(
            state.returncode or state.stdout.strip().startswith("Z"), state.stdout
        )
        worker.communicate(timeout=60)
        result = json.loads((self.root / "command-result.json").read_text())
        self.assertEqual(result, {"exitCode": 1, "errorType": "RuntimeError"})
        self.assert_capacity_free()

    def test_hold_deadline_kills_the_owned_command_and_records_timeout(self):
        child = self.root / "child.pid"
        expire = self.root / "expire"
        code = (
            "import os,signal; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); p=Path("
            + repr(str(child))
            + "); t=p.with_suffix('.tmp'); t.write_text(str(os.getpid())); t.replace(p); signal.pause()"
        )
        worker = self.start(
            "import types,time; from pathlib import Path; import threading; import build_support as b; import measurement as m; original=m.run_owned; m.run_owned=lambda *a,**k:original(*a,**(k|{'termination_grace_seconds':0})); base=time.monotonic(); b.time=types.SimpleNamespace(monotonic=lambda:base+10000 if Path(sys.argv[3]).exists() else base,sleep=time.sleep); exec(\"with b.measurement_capacity(Path(sys.argv[1]),60,threading.Event()):\\n sys.exit(m._guard(Path(sys.argv[1]),60,Path(sys.argv[4]),next((b.cache_root()/'capacity').glob('measurement-*.json')),[sys.executable,'-c',sys.argv[2]]))\")",
            self.source,
            code,
            expire,
            self.root / "command-result.json",
        )
        self.wait_file(child, worker)
        pid = int(child.read_text())
        self.assert_locked(self.cache / "capacity/admission.lock")
        expire.touch()
        worker.wait(timeout=60)
        output, errors = worker.communicate(timeout=60)
        self.assertEqual(worker.returncode, 124, output + errors)
        state = subprocess.run(
            ["ps", "-p", str(pid), "-o", "stat="],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertTrue(
            state.returncode or state.stdout.strip().startswith("Z"), state.stdout
        )
        receipt = json.loads((self.root / "command-result.json").read_text())
        self.assertEqual(receipt["exitCode"], 124)
        self.assertEqual(receipt["errorType"], "TimeoutExpired")
        self.assert_capacity_free()

    def test_client_disconnect_during_drain_releases_the_gate_and_partial_slot(self):
        gate_event = self.root / "gated"
        self.cache.joinpath("capacity").mkdir(parents=True)
        with support.file_lease(self.cache / "capacity/1.lock"):
            worker = self.start(
                "from pathlib import Path; from contextlib import contextmanager; import build_support as b; import measurement as m; exec(\"original=b._lease_before\\n@contextmanager\\ndef observed(path,deadline,cancellation):\\n with original(path,deadline,cancellation) as fd:\\n  if path.name=='admission.lock':\\n   Path(sys.argv[2]).touch()\\n  yield fd\\nb._lease_before=observed\\nsys.exit(m.reserve(Path(sys.argv[1]),60,[sys.executable,'-c','raise SystemExit(99)']))\")",
                self.source,
                gate_event,
            )
            self.wait_file(gate_event, worker)
            self.assert_locked(self.cache / "capacity/admission.lock")
            output, errors = worker.communicate(timeout=60)
            self.assertEqual(worker.returncode, 128 + signal.SIGHUP, output + errors)
            receipt = json.loads(
                next((self.cache / "runs").glob("*/receipt.json")).read_text()
            )
            self.assertNotIn("acquiredAt", receipt)
            self.assertGreaterEqual(receipt["queueWaitSeconds"], 0)
            for name in ("admission.lock", "0.lock"):
                with (self.cache / "capacity" / name).open("a") as lease:
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assert_capacity_free()

    def test_queued_build_does_not_prune_or_seed_caches_during_measurement(self):
        spec = importlib.util.spec_from_file_location(
            "remote", SCRIPTS / "remote-build.py"
        )
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        run = self.cache / "runs/queued-build"
        source = run / "repo"
        source.mkdir(parents=True)
        (source / ".xcode-version").write_text("27.0")
        manifest = {
            "kind": "mac-build",
            "arguments": [],
            "environment": {},
            "worktreeId": "fixture",
            "buildId": "queued-build",
            "sourceCommit": "fixture",
            "sourceModified": False,
            "files": [".xcode-version"],
            "sourceFingerprint": runner.fingerprint(source, [".xcode-version"]),
        }
        (run / "source.json").write_text(json.dumps(manifest))
        marker = self.root / "cache-io"
        with patch("build_support.cache_root", return_value=self.cache):
            with support.measurement_capacity(self.source, 60, threading.Event()):
                worker = self.start(
                    "import importlib.util; from pathlib import Path; from contextlib import contextmanager; s=importlib.util.spec_from_file_location('remote',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); exec(\"original=m.build_capacity\\n@contextmanager\\ndef observed(background):\\n print('capacity-requested',flush=True)\\n with original(background) as fd:\\n  yield fd\\nm.build_capacity=observed\\ndef cache_io(*_):\\n Path(sys.argv[3]).touch()\\n return {}\\nm.admit_compilation=m.prune_caches=m.seed_source_packages=m.seed_cargo=cache_io\\nm.load_policy=lambda:None\\nm.run_owned=lambda *a:0\\nprint(m.worker(Path(sys.argv[2]))['exitCode'],flush=True)\")",
                    SCRIPTS / "remote-build.py",
                    run,
                    marker,
                )
                self.assertEqual(self.line(worker), "capacity-requested")
                self.assertFalse(marker.exists())
            self.assertEqual(self.line(worker), "0")
            output, errors = worker.communicate(timeout=60)
            self.assertEqual(worker.returncode, 0, output + errors)
            self.assertTrue(marker.exists())

    def test_failed_recipe_cannot_leave_a_descendant_holding_measurement_slots(self):
        child = self.root / "child.pid"
        group = self.root / "group.pid"
        descendant = (
            "import os,signal; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); p=Path("
            + repr(str(child))
            + "); t=p.with_suffix('.tmp'); t.write_text(str(os.getpid())); t.replace(p); Path("
            + repr(str(group))
            + ").write_text(str(os.getpgrp())); print('ready',flush=True); signal.pause()"
        )
        leader = (
            "import subprocess,sys; p=subprocess.Popen([sys.executable,'-c',"
            + repr(descendant)
            + "],stdout=subprocess.PIPE,close_fds=False); p.stdout.readline(); sys.exit(23)"
        )
        supervisor = (
            "import sys; sys.path.insert(0,"
            + repr(str(SCRIPTS))
            + "); from pathlib import Path; import measurement as m; sys.exit(m.reserve(Path(sys.argv[1]),60,[sys.executable,'-c',sys.argv[2]]))"
        )
        worker = self.start(
            "from build_support import run_connected; r=run_connected([sys.executable,'-c',"
            + repr(supervisor)
            + ",sys.argv[1],sys.argv[2]]); print(r.stdout,end=''); sys.exit(r.returncode)",
            self.source,
            leader,
        )
        worker.wait(timeout=60)
        self.assertTrue(child.exists())
        pid = int(child.read_text())
        state = subprocess.run(
            ["ps", "-p", str(pid), "-o", "stat="],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertTrue(
            state.returncode or state.stdout.strip().startswith("Z"), state.stdout
        )
        output, errors = worker.communicate(timeout=60)
        self.assertEqual(worker.returncode, 23, output + errors)
        receipt = json.loads(
            next((self.cache / "runs").glob("*/receipt.json")).read_text()
        )
        self.assertEqual(receipt["exitCode"], 23)
        self.assert_capacity_free()


if __name__ == "__main__":
    unittest.main()
