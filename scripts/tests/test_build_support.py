import fcntl
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from build_support import Timings, atomic_json, build_environment
from process_group import process_identity, terminate_group


class BuildAdmissionTests(unittest.TestCase):
    def test_workers_keep_job_caps_without_inheriting_retired_qos(self):
        caps = {
            "EMIL_BUILD_JOBS": "4",
            "CARGO_BUILD_JOBS": "4",
            "RUST_TEST_THREADS": "4",
        }
        with tempfile.TemporaryDirectory() as temporary:
            environment = build_environment(
                "verify",
                caps | {"EMIL_BUILD_QOS": "utility", "GH_TOKEN_PERSONAL": "fake-token"},
                Path(temporary),
            )
        self.assertEqual({key: environment.get(key) for key in caps}, caps)
        self.assertNotIn("GH_TOKEN_PERSONAL", environment)
        self.assertNotIn("EMIL_BUILD_QOS", environment)

    def test_failed_terminal_publication_preserves_the_previous_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "receipt.json"
            path.write_text('{"exitCode": 0}')
            with (
                patch(
                    "build_support.json.dump", side_effect=ValueError("invalid data")
                ),
                self.assertRaises(ValueError),
            ):
                atomic_json(path, {"exitCode": 1})
            self.assertEqual(json.loads(path.read_text()), {"exitCode": 0})
            self.assertEqual(
                [entry.name for entry in path.parent.iterdir()], ["receipt.json"]
            )

    def test_cancellation_keeps_ownership_until_descendant_dies_after_leader_exit(self):
        for inherited_lease in (False, True):
            with (
                self.subTest(inherited_lease=inherited_lease),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                descendant = """import os,signal,sys
from pathlib import Path
root = Path(sys.argv[1])
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pending = root / 'descendant.tmp'
pending.write_text(str(os.getpid()))
pending.replace(root / 'descendant.pid')
while True:
    signal.pause()
"""
                leader = """import os,signal,subprocess,sys
from pathlib import Path
root = Path(sys.argv[1])
signal.signal(signal.SIGTERM, lambda *_: (root.joinpath('leader-exited').touch(), sys.exit(0)))
pending = root / 'leader.tmp'
pending.write_text(str(os.getpid()))
pending.replace(root / 'leader.pid')
if not sys.stdin.buffer.read(1):
    sys.exit(0)
subprocess.Popen([sys.executable, '-c', sys.argv[2], str(root)], pass_fds=(int(os.environ['OWNED_TEST_FD']),) if sys.argv[3] == 'True' else ())
while True:
    signal.pause()
"""
                bootstrap = """import os,sys,time,types
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import build_support as b
root = Path(sys.argv[2])
observed_exit = 0
def step(_seconds):
    global observed_exit
    root.joinpath('owner-ready').touch()
    leader = root / 'leader.pid'
    if leader.exists() and os.waitid(os.P_PID, int(leader.read_text()), os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None:
        observed_exit += 1
        if observed_exit >= 2:
            root.joinpath('owner-after-leader').touch()
    time.sleep(0.01)
b.time = types.SimpleNamespace(monotonic=lambda: 2 if root.joinpath('allow-escalation').exists() else 0, sleep=step)
with b.file_lease(root / 'source.lock') as fd:
    env = os.environ | {'OWNED_TEST_FD': str(fd)}
    sys.exit(b.run_owned([sys.executable, '-c', sys.argv[3], str(root), sys.argv[4], sys.argv[5]], root, env, sys.stdout, (fd,), termination_grace_seconds=1))
"""
                owner = subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        bootstrap,
                        str(SCRIPTS),
                        str(root),
                        leader,
                        descendant,
                        str(inherited_lease),
                    ],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                pid = None
                group = None

                def wait_for_event(owner, path):
                    deadline = time.monotonic() + 60
                    while not path.exists():
                        self.assertIsNone(
                            owner.poll(), f"Owner exited before {path.name}"
                        )
                        self.assertLess(time.monotonic(), deadline, path.name)
                        time.sleep(0.01)

                def assert_descendant_exited(pid):
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

                def terminate_group(group, root):
                    recorded = root / "leader.pid"
                    owned_group = group
                    if owned_group is None and recorded.exists():
                        owned_group = int(recorded.read_text())
                    if owned_group is None:
                        return
                    rows = subprocess.check_output(
                        ["ps", "-axo", "pgid=,args="], text=True
                    )
                    if any(
                        int(parts[0]) == owned_group and str(root) in parts[1]
                        for row in rows.splitlines()
                        if len(parts := row.split(None, 1)) == 2
                    ):
                        try:
                            os.killpg(owned_group, signal.SIGKILL)
                        except ProcessLookupError:
                            pass

                try:
                    wait_for_event(owner, root / "owner-ready")
                    wait_for_event(owner, root / "leader.pid")
                    group = int((root / "leader.pid").read_text())
                    owner.stdin.write(b".")
                    owner.stdin.flush()
                    wait_for_event(owner, root / "descendant.pid")
                    pid = int((root / "descendant.pid").read_text())
                    with (
                        (root / "source.lock").open("a") as lease,
                        self.assertRaises(BlockingIOError),
                    ):
                        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    owner.send_signal(signal.SIGTERM)
                    wait_for_event(owner, root / "owner-after-leader")
                    self.assertIsNone(owner.poll())
                    leader_state = subprocess.run(
                        ["ps", "-p", str(group), "-o", "stat="],
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertTrue(
                        leader_state.stdout.strip().startswith("Z"), leader_state.stdout
                    )
                    descendant_state = subprocess.run(
                        ["ps", "-p", str(pid), "-o", "stat="],
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(descendant_state.returncode, 0)
                    self.assertFalse(descendant_state.stdout.strip().startswith("Z"))
                    with (
                        (root / "source.lock").open("a") as lease,
                        self.assertRaises(BlockingIOError),
                    ):
                        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    (root / "allow-escalation").touch()
                    owner.stdin.close()
                    owner.stdin = None
                    output, errors = owner.communicate(timeout=60)
                    self.assertEqual(
                        owner.returncode, 128 + signal.SIGTERM, output + errors
                    )
                    assert_descendant_exited(pid)
                    with (root / "source.lock").open("a") as lease:
                        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    if owner.stdin is not None:
                        owner.stdin.close()
                        owner.stdin = None
                    if owner.poll() is None:
                        owner.terminate()
                    terminate_group(group, root)
                    try:
                        owner.communicate(timeout=60)
                    except subprocess.TimeoutExpired:
                        owner.kill()
                        terminate_group(group, root)
                        owner.communicate(timeout=60)

    def test_normal_failed_leader_exit_drains_a_term_ignoring_lease_holder(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            child = """import json,os,signal,sys
from pathlib import Path
root = Path(sys.argv[1])
signal.signal(signal.SIGTERM, signal.SIG_IGN)
sys.path.insert(0,os.environ['OWNED_TEST_SCRIPTS'])
from process_group import own_identity
p = root / 'descendant.tmp'; p.write_text(json.dumps(own_identity())); p.replace(root / 'descendant.json')
while True: signal.pause()
"""
            leader = """import os,subprocess,sys,time
from pathlib import Path
root = Path(sys.argv[1])
p = root / 'leader.tmp'; p.write_text(str(os.getpid())); p.replace(root / 'leader.pid')
subprocess.Popen([sys.executable, '-c', sys.argv[2], str(root)], pass_fds=(int(os.environ['OWNED_TEST_FD']),))
while not root.joinpath('descendant.json').exists(): time.sleep(0.01)
sys.exit(7)
"""
            bootstrap = """import os,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import build_support as b
root = Path(sys.argv[2])
with b.file_lease(root / 'source.lock') as fd:
    result=b.run_owned([sys.executable,'-c',sys.argv[3],str(root),sys.argv[4]],root,os.environ|{'OWNED_TEST_FD':str(fd),'OWNED_TEST_SCRIPTS':sys.argv[1]},sys.stdout,(fd,),termination_grace_seconds=0.2)
sys.exit(result)
"""
            owner = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    bootstrap,
                    str(SCRIPTS),
                    str(root),
                    leader,
                    child,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            try:
                self.assertEqual(owner.wait(timeout=60), 7)
                identity = json.loads((root / "descendant.json").read_text())
                pid = identity["pid"]
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
                with (root / "source.lock").open("a") as lease:
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                if (root / "descendant.json").exists():
                    from process_group import signal_process

                    identity = json.loads((root / "descendant.json").read_text())
                    signal_process(identity, signal.SIGKILL)
                if owner.poll() is None:
                    owner.kill()
                owner.communicate(timeout=60)

    def leased_job(self, root: Path, mode: str):
        leader = """import os,subprocess,sys,time
from pathlib import Path
root, mode = Path(sys.argv[1]), sys.argv[2]
root.joinpath('leader.pid').write_text(str(os.getpid()))
descendant = "import os,sys,time; from pathlib import Path; p=Path(sys.argv[1]); t=p.with_suffix('.tmp'); t.write_text(str(os.getpid())); t.replace(p); time.sleep(600)"
subprocess.Popen([sys.executable, '-c', descendant, str(root / 'descendant.pid')], close_fds=False, start_new_session=mode == 'daemon')
while not root.joinpath('descendant.pid').exists(): time.sleep(0.01)
if mode == 'child': time.sleep(600)
"""
        return subprocess.Popen(
            [
                sys.executable,
                str(SCRIPTS / "build_support.py"),
                "--lease",
                str(root / "build.lock"),
                "--",
                sys.executable,
                "-c",
                leader,
                str(root),
                mode,
            ],
            env=os.environ | {"HOME": str(root)},
            stdout=subprocess.DEVNULL,
            stderr=(root / "owner.err").open("w"),
        )

    def assert_lease_available(self, path: Path, available: bool):
        with path.open("a") as lease:
            if available:
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            else:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_a_daemon_that_leaves_the_job_does_not_keep_its_leases(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            owner = self.leased_job(root, "daemon")
            try:
                self.assertEqual(
                    owner.wait(timeout=60), 0, (root / "owner.err").read_text()
                )
                daemon = int((root / "descendant.pid").read_text())
                os.kill(daemon, 0)
                self.assert_lease_available(root / "build.lock", True)
                self.assert_lease_available(
                    root / "Library/Caches/RemoteCoder-Build/capacity/0.lock", True
                )
            finally:
                if owner.poll() is None:
                    owner.kill()
                if (root / "descendant.pid").exists():
                    try:
                        os.kill(int((root / "descendant.pid").read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_a_killed_owner_leaves_its_lease_with_the_running_job(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            owner = self.leased_job(root, "child")
            job = None
            try:
                deadline = time.monotonic() + 60
                while not (root / "descendant.pid").exists():
                    self.assertIsNone(owner.poll(), (root / "owner.err").read_text())
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.01)
                job = process_identity(int((root / "leader.pid").read_text()))
                self.assertIsNotNone(job)
                owner.kill()
                owner.wait(timeout=60)
                self.assert_lease_available(root / "build.lock", False)
                terminate_group(job, 0.2)
                deadline = time.monotonic() + 10
                while True:
                    try:
                        self.assert_lease_available(root / "build.lock", True)
                        break
                    except BlockingIOError:
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(0.05)
            finally:
                if owner.poll() is None:
                    owner.kill()
                if job is not None:
                    terminate_group(job, 0.2)

    def test_waiting_worktree_does_not_reserve_an_interactive_slot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cache = root / "Library/Caches/RemoteCoder-Build"
            cache.mkdir(parents=True)
            lock = root / "source.lock"
            environment = os.environ | {"HOME": str(root)}
            with lock.open("a") as lease:
                fcntl.flock(lease, fcntl.LOCK_EX)
                # A real blocked source owner must not occupy capacity slot 0.
                bootstrap = """import sys, types
from pathlib import Path
sys.path.insert(0, sys.argv.pop(1))
import build_support as b
b.os.uname = lambda: types.SimpleNamespace(nodename="synthetic-macbook")
source_lease = b.file_lease
def requested_lease(path):
    Path(f"{path}.requested").touch()
    return source_lease(path)
b.file_lease = requested_lease
raise SystemExit(b.main())
"""
                waiting = subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        bootstrap,
                        str(SCRIPTS),
                        "--lease",
                        str(lock),
                        "--",
                        sys.executable,
                        "-c",
                        "pass",
                    ],
                    env=environment,
                )
                try:
                    requested = root / "source.lock.requested"
                    deadline = time.monotonic() + 10
                    while not requested.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(requested.exists())
                    self.assertIsNone(waiting.poll())
                    slot = cache / "capacity/0.lock"
                    slot.parent.mkdir(exist_ok=True)
                    with slot.open("a") as available:
                        fcntl.flock(available, fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    waiting.terminate()
                    waiting.wait(timeout=5)

    def test_background_work_leaves_interactive_capacity_available(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            environment = os.environ | {"HOME": str(root)}
            code = "from pathlib import Path; import time; Path.home().joinpath('started').touch(); time.sleep(20)"
            # Invoke the admission primitive directly; the CLI deliberately rejects Mini builds.
            bootstrap = "import sys; sys.path.insert(0,sys.argv[1]); from build_support import build_capacity; exec(sys.argv[2])"
            worker = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    bootstrap,
                    str(SCRIPTS),
                    "with build_capacity(True):\n " + code,
                ],
                env=environment,
            )
            try:
                deadline = time.monotonic() + 5
                while not (root / "started").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((root / "started").exists())
                with (root / "Library/Caches/RemoteCoder-Build/capacity/0.lock").open(
                    "a"
                ) as slot:
                    fcntl.flock(slot, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                worker.terminate()
                worker.wait(timeout=5)

    def test_phase_state_is_readable_while_waiting_and_after_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary)
            timings = Timings(run)
            with self.assertRaises(ValueError), timings.phase("capacityWait"):
                self.assertEqual(
                    json.loads((run / "progress.json").read_text())["phase"],
                    "capacityWait",
                )
                raise ValueError("cancelled")
            final = json.loads((run / "progress.json").read_text())
            self.assertIsNone(final["phase"])
            self.assertIn("capacityWait", final["phasesSeconds"])
