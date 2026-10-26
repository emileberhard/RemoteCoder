import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from process_group import process_identity, terminate_group

CHILD = """import json,os,select,sys
from pathlib import Path
sys.path.insert(0, sys.argv[3])
from process_group import own_identity
root = Path(sys.argv[1])
release = os.open(root / 'release', os.O_RDWR | os.O_NONBLOCK)
p = root / 'child.tmp'; p.write_text(json.dumps(own_identity())); p.replace(root / 'child.json')
while True:
    ready, _, _ = select.select([release, sys.stdin], [], [])
    if release in ready or sys.stdin in ready and not os.read(sys.stdin.fileno(), 1):
        break
sys.exit(int(sys.argv[2]))
"""
OWNER = """import json,sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import build_support as b
root = Path(sys.argv[2])
command = [sys.executable, '-c', sys.argv[3], str(root), sys.argv[4], sys.argv[1]]
try:
    status = b.run_owned(command, root, __import__('os').environ, sys.stdout, termination_grace_seconds=0.2) if sys.argv[5] == 'owned' else b.run_connected(command).returncode
except SystemExit as error:
    status = error.code
p = root / 'returned.tmp'; p.write_text(json.dumps({'status': status})); p.replace(root / 'returned.json')
sys.stdin.read(1)
"""

ENTRY = r"""import contextlib,importlib.util,json,os,sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
root = Path(sys.argv[2])
sys.path.insert(0,sys.argv[1])
sys.path.insert(0,str(Path(sys.argv[1]).parent/'dev-tools/src'))
def pause(stage):
    p=root/'stage.tmp'; p.write_text(json.dumps({'stage':stage})); p.replace(root/'stage.json')
    sys.stdin.read(1)
kind=sys.argv[3]
if kind in ('remote-build','codex-build'):
    s=importlib.util.spec_from_file_location('entry',str(Path(sys.argv[1])/(kind+'.py')))
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
    receipt={'kind':'tools-test','worktreeId':'fixture','buildId':'fixture','sourceCommit':'fixture','sourceFingerprint':'fixture','exitCode':0,'log':'fixture','package':str(root),'packageSHA256':'fixture'}
    if kind=='remote-build':
        m.source_manifest=lambda *a: receipt|{'files':[],'arguments':[]}
        m.transfer_source=lambda *a:pause('transfer')
        m.run_connected=lambda *a: (pause('worker') or SimpleNamespace(stdout=json.dumps(receipt),returncode=0))
        m.subprocess.check_output=lambda *a,**k:json.dumps(str(root))
        m.atomic_json=lambda *a:pause('readback')
        os.environ['RC_GATEWAY_BUILD_HOST']='local'
        sys.argv=['remote-build','tools-test']
    else:
        def output(command,**kwargs):
            if command[0]=='git':
                if command[-1]=='--porcelain': return ''
                if command[-1]=='HEAD': return 'a'*40
                return '[workspace.package]\nversion="1.2.3"'
            if command[0]=='mkdir': return ''
            if 'hasCommit' in command[2]: return json.dumps({'base':None,'hasCommit':True})
            return json.dumps(str(root))
        m.output=output
        m.subprocess.run=lambda *a,**k: (pause('transfer') or SimpleNamespace(returncode=0))
        @contextlib.contextmanager
        def collecting(*a):
            pause('worker'); yield receipt
        m.collecting_worker=collecting
        m.run_connected=lambda *a: (pause('transfer') or SimpleNamespace(returncode=0))
        m.valid_package=lambda *a: (pause('readback') or True)
        m.socket.gethostname=lambda:'fixture-macbook'
        os.environ['RC_GATEWAY_BUILD_HOST']='fixture-macbook'
        sys.argv=['codex-build',str(root),str(root)]
else:
    from remotecoder_tools import perf_harness as m
    m.require_macbook=lambda:None
    device=SimpleNamespace(udid='fixture',prepare=lambda:None,put=lambda *a:None)
    m.target=lambda *a:device
    m.fresh_open=lambda *a:None
    m.fresh_launch=lambda *a:None
    def send(*a,**k):
        pause('measurement'); return {'activeThroughout':True,'conservedEnergy':False,'frames':1}
    m.send=send
    m.device_lease=lambda *a:contextlib.nullcontext()
    recording=root/'recording.jsonl'; recording.write_text('{"t":0}\n')
    sys.argv=['perf-sim',kind]
    if kind=='cmd': sys.argv += ['{}']
    else:
        sys.argv += ['--host','fixture','--thread','fixture','--label','fixture','--runs','1','--settle','0']
        if kind=='stream': sys.argv += ['--recording',str(recording)]
try: m.main()
except SystemExit as error:
    if error.code: raise
p=root/'returned.tmp'; p.write_text('{}'); p.replace(root/'returned.json')
sys.stdin.read(1)
"""

HOST_OWNER = r"""import json,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from job_power import host_job_assertion
root=Path(sys.argv[2])
try:
    with host_job_assertion(['bash','-c'],root/'job.lock') as pid:
        p=root/'host.tmp'; p.write_text(json.dumps({'pid':pid})); p.replace(root/'host.json')
        sys.stdin.read(1)
        if sys.argv[3]=='failed': raise ValueError('fixture failure')
except (ValueError,SystemExit): pass
p=root/'returned.tmp'; p.write_text('{}'); p.replace(root/'returned.json')
sys.stdin.read(1)
"""
DELETED_SOURCE_OWNER = r"""import shutil,sys
from pathlib import Path
root=Path(sys.argv[2])
copy=root/'scripts'; copy.mkdir()
shutil.copy(Path(sys.argv[1])/'job_power.py',copy)
sys.path.insert(0,str(copy))
from job_power import host_job_assertion
shutil.rmtree(copy)
with host_job_assertion(['bash','-c'],root/'job.lock') as pid:
    print(pid,flush=True)
"""
HOLDER = r"""import fcntl,sys
from pathlib import Path
root=Path(sys.argv[1])
with (root/'job.lock').open('a') as lease:
    fcntl.flock(lease,fcntl.LOCK_EX)
    print('ready',flush=True)
    sys.stdin.read(1)
"""

UPLOAD_SSH = r"""#!/usr/bin/env python3
import json,os,select,signal,subprocess,sys,time
from pathlib import Path
root=Path(os.environ['H217_UPLOAD_ROOT'])
a=sys.argv[1:]; i=a.index('fixture-upload-host'); command=' '.join(a[i+1:])
if '--server' not in a and 'serve_host_job' not in command: os.execvp('bash',['bash','-c',command])
child=subprocess.Popen(['bash','-c',command],stdin=subprocess.PIPE,stdout=subprocess.PIPE,start_new_session=True)
def stop(signum,_frame): raise SystemExit(128+signum)
for sig in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP): signal.signal(sig,stop)
try:
    if '--server' in a:
        child.stdin.write(sys.stdin.buffer.read(4)); child.stdin.flush()
        sys.stdout.buffer.write(child.stdout.read(4)); sys.stdout.buffer.flush()
        p=root/'upload.tmp'; p.write_text(json.dumps({'pid':child.pid})); p.replace(root/'upload.json')
        fifo=os.open(root/'upload-release',os.O_RDWR); os.read(fifo,1); os.close(fifo)
        child.stdin.close()
        sys.stdout.buffer.write(child.stdout.read()); sys.stdout.buffer.flush()
    else:
        line=child.stdout.readline()
        p=root/'guard.tmp'; p.write_bytes(line); p.replace(root/'guard.json')
        sys.stdout.buffer.write(line); sys.stdout.buffer.flush()
        cut=os.open(root/'control-cut',os.O_RDWR|os.O_NONBLOCK)
        closed=False
        while child.poll() is None:
            ready,_,_=select.select([sys.stdin,cut],[],[],0.05)
            if cut in ready:
                os.read(cut,1); child.stdin.close(); closed=True
                (root/'cut-observed').touch()
            if sys.stdin in ready:
                data=os.read(sys.stdin.fileno(),1)
                if not data:
                    if not closed: child.stdin.close(); closed=True
                elif not closed:
                    child.stdin.write(data); child.stdin.flush()
        os.close(cut)
    sys.exit(child.wait(timeout=5))
finally:
    if child.poll() is None:
        child.terminate()
        try: child.wait(timeout=5)
        except subprocess.TimeoutExpired: child.kill(); child.wait()
"""
UPLOAD_ENTRY = r"""import importlib.util,json,os,sys
from pathlib import Path
from types import SimpleNamespace
s=importlib.util.spec_from_file_location('codex_build',str(Path(sys.argv[1])/'codex-build.py'))
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
root=Path(sys.argv[2]); original=m.output
def output(command,**kwargs):
    if command[0]=='ssh' and 'Path.home' in command[-1]: return json.dumps(str(root))
    return original(command,**kwargs)
m.output=output; m.uuid.uuid4=lambda:SimpleNamespace(hex='upload')
os.environ['RC_GATEWAY_BUILD_HOST']='fixture-upload-host'
sys.argv=['codex-build',str(root/'source')]
sys.exit(m.main())
"""


@unittest.skipUnless(sys.platform == "darwin", "IOPM assertions are a macOS contract")
class JobSleepAssertionTests(unittest.TestCase):
    def held_by(self, pid):
        output = subprocess.check_output(
            ["pmset", "-g", "assertions"], text=True, errors="replace", timeout=5
        )
        return any(
            re.search(rf"\bpid {pid}\(", line)
            and 'PreventUserIdleSystemSleep named: "RemoteCoder owned job"' in line
            for line in output.splitlines()
        )

    def wait_for_record(self, owner, path):
        deadline = time.monotonic() + 15
        while not path.exists():
            self.assertIsNone(owner.poll(), f"Owner exited before {path.name}")
            self.assertLess(time.monotonic(), deadline, path.name)
            time.sleep(0.01)
        return json.loads(path.read_text())

    def wait_for_release(self, pid):
        deadline = time.monotonic() + 5
        while self.held_by(pid):
            self.assertLess(
                time.monotonic(),
                deadline,
                "Owner retained its completed job sleep assertion",
            )
            time.sleep(0.02)

    def test_fleet_entry_points_keep_one_host_owner_through_stage_handoffs(self):
        for entry in ("remote-build", "codex-build", "stream", "open-bench", "cmd"):
            with self.subTest(entry=entry), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                with subprocess.Popen(
                    [sys.executable, "-c", ENTRY, str(SCRIPTS), str(root), entry],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    start_new_session=True,
                ) as owner:
                    host_pid = None
                    try:
                        while not (root / "returned.json").exists():
                            record = self.wait_for_record(owner, root / "stage.json")
                            if entry in ("remote-build", "codex-build"):
                                output = subprocess.check_output(
                                    ["pmset", "-g", "assertions"], text=True, errors="replace"
                                )
                                candidates = []
                                for line in output.splitlines():
                                    match = re.search(
                                        r'pid (\d+)\(.*PreventUserIdleSystemSleep named: "RemoteCoder owned job"',
                                        line,
                                    )
                                    if not match:
                                        continue
                                    pid = int(match[1])
                                    identity = process_identity(pid)
                                    if (
                                        identity is not None
                                        and identity["ppid"] == owner.pid
                                    ):
                                        candidates.append(pid)
                                self.assertEqual(
                                    len(candidates),
                                    1,
                                    f"{entry} {record['stage']} has no connected build-host assertion",
                                )
                                if host_pid is None:
                                    host_pid = candidates[0]
                                self.assertEqual(
                                    candidates,
                                    [host_pid],
                                    "A handoff replaced the whole-job assertion owner",
                                )
                            else:
                                host_pid = owner.pid
                                self.assertTrue(
                                    self.held_by(host_pid),
                                    f"{entry} bypassed power ownership",
                                )
                            (root / "stage.json").unlink()
                            owner.stdin.write(b".")
                            owner.stdin.flush()
                            deadline = time.monotonic() + 5
                            while (
                                not (root / "stage.json").exists()
                                and not (root / "returned.json").exists()
                            ):
                                self.assertIsNone(owner.poll())
                                self.assertLess(time.monotonic(), deadline)
                                time.sleep(0.01)
                        self.assertIsNotNone(host_pid)
                        self.wait_for_release(host_pid)
                    finally:
                        if owner.poll() is None:
                            owner.stdin.close()
                            owner.stdin = None
                        try:
                            owner.communicate(timeout=5)
                        except subprocess.TimeoutExpired:
                            owner.kill()
                            owner.communicate(timeout=5)
                    self.assertEqual(owner.returncode, 0)

    def test_host_assertion_starts_after_its_source_is_deleted(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, "-c", DELETED_SOURCE_OWNER, str(SCRIPTS), directory],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.strip().isdigit())

    def test_connected_host_assertion_drains_a_live_writer_after_client_death(self):
        for ending in ("normal", "failed", "cancelled", "owner-killed"):
            with (
                self.subTest(ending=ending),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                with subprocess.Popen(
                    [sys.executable, "-c", HOST_OWNER, str(SCRIPTS), str(root), ending],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    start_new_session=True,
                ) as owner:
                    pid = None
                    try:
                        pid = self.wait_for_record(owner, root / "host.json")["pid"]
                        self.assertTrue(self.held_by(pid))
                        with subprocess.Popen(
                            [sys.executable, "-c", HOLDER, str(root)],
                            stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                        ) as holder:
                            self.assertEqual(holder.stdout.readline(), b"ready\n")
                            if ending == "owner-killed":
                                owner.kill()
                                owner.wait(timeout=5)
                            elif ending == "cancelled":
                                owner.send_signal(signal.SIGTERM)
                            else:
                                owner.stdin.write(b".")
                                owner.stdin.flush()
                            for _ in range(5):
                                self.assertTrue(
                                    self.held_by(pid),
                                    "Client loss released power protection before the writer drained",
                                )
                                time.sleep(0.02)
                            holder.stdin.write(b".")
                            holder.stdin.flush()
                            holder.communicate(timeout=5)
                        self.wait_for_release(pid)
                        if ending != "owner-killed":
                            self.wait_for_record(owner, root / "returned.json")
                    finally:
                        if owner.poll() is None:
                            owner.stdin.close()
                            owner.stdin = None
                        try:
                            owner.communicate(timeout=5)
                        except subprocess.TimeoutExpired:
                            owner.kill()
                            owner.communicate(timeout=5)
                        if pid is not None:
                            self.wait_for_release(pid)

    def test_codex_upload_protocol_keeps_power_after_guard_control_disconnect(self):
        import fcntl

        from process_group import signal_process

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "codex-rs").mkdir()
            (source / "codex-rs/Cargo.toml").write_text(
                '[workspace.package]\nversion="1.2.3"\n'
            )
            for command in (
                ["git", "init", "-q", str(source)],
                ["git", "-C", str(source), "add", "."],
                [
                    "git",
                    "-C",
                    str(source),
                    "-c",
                    "user.name=Fixture",
                    "-c",
                    "user.email=fixture@example.invalid",
                    "commit",
                    "-qm",
                    "fixture",
                ],
            ):
                subprocess.run(command, check=True)
            binary = root / "bin"
            binary.mkdir()
            bridge = binary / "ssh"
            bridge.write_text(UPLOAD_SSH)
            bridge.chmod(0o700)
            for name in ("control-cut", "upload-release"):
                os.mkfifo(root / name, 0o600)
            with subprocess.Popen(
                [sys.executable, "-c", UPLOAD_ENTRY, str(SCRIPTS), str(root)],
                env=os.environ
                | {
                    "PATH": str(binary) + os.pathsep + os.environ["PATH"],
                    "H217_UPLOAD_ROOT": str(root),
                },
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            ) as client:
                receiver = None
                guard = None
                try:
                    guard_pid = self.wait_for_record(client, root / "guard.json")["pid"]
                    guard = process_identity(guard_pid)
                    receiver_pid = self.wait_for_record(client, root / "upload.json")[
                        "pid"
                    ]
                    receiver = process_identity(receiver_pid)
                    self.assertTrue(self.held_by(guard_pid))
                    lock = (
                        root
                        / "Library/Caches/RemoteCoder-Build/codex-runtime/runs/upload/collection.lock"
                    )
                    cut = os.open(root / "control-cut", os.O_WRONLY | os.O_NONBLOCK)
                    os.write(cut, b".")
                    os.close(cut)
                    deadline = time.monotonic() + 5
                    while not (root / "cut-observed").exists():
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(0.01)
                    for _ in range(10):
                        self.assertTrue(
                            self.held_by(guard_pid),
                            "A dropped control channel released power during the real upload",
                        )
                        time.sleep(0.05)
                    with lock.open("a") as available:
                        with self.assertRaises(
                            BlockingIOError,
                            msg="The real upload receiver has not joined collection ownership",
                        ):
                            fcntl.flock(available, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    release = os.open(
                        root / "upload-release", os.O_WRONLY | os.O_NONBLOCK
                    )
                    os.write(release, b".")
                    os.close(release)
                    client.communicate(timeout=10)
                    self.assertNotEqual(client.returncode, 0)
                    self.wait_for_release(guard_pid)
                finally:
                    if receiver is not None:
                        terminate_group(receiver, 0.2)
                    if guard is not None:
                        signal_process(guard, signal.SIGTERM)
                    if client.poll() is None:
                        terminate_group(process_identity(client.pid), 0.2)
                    client.communicate(timeout=5)

    def test_owned_runner_assertion_covers_dispatch_and_releases_before_owner_exit(
        self,
    ):
        for runner in ["owned", "connected"]:
            for ending in ["normal", "failed", "cancelled", "owner-killed"]:
                with (
                    self.subTest(runner=runner, ending=ending),
                    tempfile.TemporaryDirectory() as temporary,
                ):
                    root = Path(temporary)
                    os.mkfifo(root / "release", 0o600)
                    status = 7 if ending == "failed" else 0
                    with subprocess.Popen(
                        [
                            sys.executable,
                            "-c",
                            OWNER,
                            str(SCRIPTS),
                            str(root),
                            CHILD,
                            str(status),
                            runner,
                        ],
                        stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        start_new_session=True,
                    ) as owner:
                        child = None
                        release = None
                        try:
                            child = self.wait_for_record(owner, root / "child.json")
                            self.assertTrue(
                                self.held_by(owner.pid),
                                "Dispatched job has no idle-system-sleep assertion",
                            )
                            if ending == "owner-killed":
                                owner.kill()
                                owner.wait(timeout=5)
                            else:
                                if ending == "cancelled":
                                    owner.send_signal(signal.SIGTERM)
                                else:
                                    release = os.open(
                                        root / "release", os.O_WRONLY | os.O_NONBLOCK
                                    )
                                    os.write(release, b".")
                                result = self.wait_for_record(
                                    owner, root / "returned.json"
                                )
                                self.assertEqual(
                                    result["status"],
                                    128 + signal.SIGTERM
                                    if ending == "cancelled"
                                    else status,
                                )
                                self.assertIsNone(owner.poll())
                            self.wait_for_release(owner.pid)
                        finally:
                            if release is not None:
                                os.close(release)
                            if child is not None:
                                terminate_group(child, 0.2)
                            if owner.poll() is None:
                                owner.stdin.write(b".")
                                owner.stdin.flush()
                            try:
                                owner.communicate(timeout=5)
                            except subprocess.TimeoutExpired:
                                owner.kill()
                                owner.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
