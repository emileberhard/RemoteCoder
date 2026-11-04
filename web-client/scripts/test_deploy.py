import fcntl
import importlib.util
import json
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import plistlib
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("web_deploy", Path(__file__).with_name("deploy.py"))
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


class ReleaseTests(unittest.TestCase):
    def test_legacy_release_keeps_its_runtime_after_source_disappears(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            releases = root / "releases"
            releases.mkdir()
            old = releases / "legacy"
            (old / "dist").mkdir(parents=True)
            bun = root / "bun"
            bun.write_text("#!/bin/sh\necho 1.4.3\n")
            bun.chmod(0o755)
            (old / "service.js").write_text("service")
            (old / "service.plist").write_bytes(plistlib.dumps({"ProgramArguments": [str(bun), "service.js"]}))
            (old / "dist/deployment.json").write_text(json.dumps({"revision": "old", "bun": "1.4.3"}))
            with patch.object(deploy, "ROOT", root), patch.object(deploy, "RELEASES", releases), tempfile.TemporaryFile() as lock:
                retained = deploy.snapshot_legacy(old, lock)
                bun.unlink()
                self.assertEqual(subprocess.check_output([deploy.runtime(retained), "--version"], text=True).strip(), "1.4.3")
                (retained / "service.js").write_text("changed")
                with self.assertRaisesRegex(RuntimeError, "do not match"):
                    deploy.runtime(retained)
                (retained / "service.js").write_text("service")
                (retained / "bun").write_text("changed")
                with self.assertRaisesRegex(RuntimeError, "do not match"):
                    deploy.runtime(retained)

    def test_version_is_verified_on_copied_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.write_text("#!/bin/sh\necho 1.4.4\n")
            source.chmod(0o755)
            original = deploy.shutil.copy2
            def replace_on_copy(src, destination):
                original(src, destination)
                Path(destination).write_text("#!/bin/sh\necho 1.4.5\n")
            with patch.object(deploy.shutil, "copy2", side_effect=replace_on_copy), tempfile.TemporaryFile() as lock:
                with self.assertRaisesRegex(RuntimeError, "Expected Bun 1.4.4, found 1.4.5"):
                    deploy.copy_runtime(source, root / "copy", "1.4.4", lock)

    def test_release_identity_changes_with_runtime_and_service_inputs(self):
        identity = deploy.release_identity("commit", "1.4.4", "bytes", b"service")
        for inputs in [("commit2", "1.4.4", "bytes", b"service"), ("commit", "1.4.5", "bytes", b"service"), ("commit", "1.4.4", "other", b"service"), ("commit", "1.4.4", "bytes", b"other")]:
            self.assertNotEqual(identity, deploy.release_identity(*inputs))


class StageTests(unittest.TestCase):
    def test_deploy_stages_with_retained_bun_without_touching_service(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            repo = base / "repo"
            scripts = repo / "web-client/scripts"
            scripts.mkdir(parents=True)
            (scripts / "deploy.py").write_text("fixture")
            (repo / "THIRD_PARTY_NOTICES.md").write_text("fixture")
            (repo / "LICENSES").mkdir()
            (repo / "LICENSES/license").write_text("fixture")
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"], check=True)
            bun = base / "bun"
            bun.write_text("""#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
if args == ['--version']:
    print('1.4.4')
else:
    with open(os.environ['STAGE_TEST_LOG'], 'a') as output:
        output.write(sys.argv[0] + ' ' + args[0] + '\\n')
    if args[0] == 'scripts/build.ts':
        pathlib.Path('dist').mkdir()
        pathlib.Path('dist/index.html').write_text('fixture')
    elif args[0] == 'build':
        pathlib.Path(args[args.index('--outfile') + 1]).write_text('fixture')
""")
            bun.chmod(0o755)
            log = base / "calls"
            root = base / "web"
            releases = root / "releases"
            current = releases / "legacy"
            (current / "dist").mkdir(parents=True)
            old_bun = base / "old-bun"
            old_bun.write_text("#!/bin/sh\necho 1.4.3\n")
            old_bun.chmod(0o755)
            (current / "service.js").write_text("old service")
            (current / "dist/deployment.json").write_text(json.dumps({"revision": "old", "bun": "1.4.3"}))
            (current / "service.plist").write_bytes(plistlib.dumps({"ProgramArguments": [str(old_bun), "old-service"]}))
            (root / "current").symlink_to(current)
            service = base / "service.plist"
            service.write_bytes(plistlib.dumps({"EnvironmentVariables": {}}))
            settings = {"host": "fixture-host", "bunPath": str(bun), "bunVersion": "1.4.4"}
            output = io.StringIO()
            with patch.object(deploy, "ROOT", root), patch.object(deploy, "RELEASES", releases), patch.object(deploy, "WEB", settings), patch.object(deploy, "SERVICE_PLIST", service), patch.object(deploy, "__file__", str(scripts / "deploy.py")), patch.object(deploy.socket, "gethostname", return_value="fixture-host"), patch.object(deploy, "candidate") as smoke, patch.dict(os.environ, {"STAGE_TEST_LOG": str(log)}), patch.object(sys, "argv", ["deploy.py", "stage"]), redirect_stdout(output):
                exit_code = deploy.main()
            self.assertEqual(exit_code, 0)
            result = json.loads(output.getvalue().splitlines()[-1])
            self.assertEqual(result["status"], "staged")
            self.assertEqual(result["activation"], "pending")
            self.assertEqual((root / "current").resolve(), current)
            staged = (root / "staged").resolve()
            prior = (root / "staged-previous").resolve()
            old_bun.unlink()
            self.assertEqual(subprocess.check_output([prior / "bun", "--version"], text=True).strip(), "1.4.3")
            definition = plistlib.loads((staged / "service.plist").read_bytes())
            self.assertEqual(definition["ProgramArguments"], [str(staged / "bun"), str(staged / "service.js")])
            self.assertIn(" scripts/build.ts", log.read_text())
            self.assertTrue(all("/.build-" in line for line in log.read_text().splitlines()))
            smoke.assert_called_once()
            self.assertFalse(list(root.glob(".build-*")))

    def test_budget_counts_releases_and_staging_and_preserves_pins(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            releases = root / "releases"
            pinned = releases / "pinned"
            pinned.mkdir(parents=True)
            (pinned / "data").write_bytes(b"1234")
            (root / "current").symlink_to(pinned)
            staging = root / ".build-test"
            staging.mkdir()
            (staging / "data").write_bytes(b"5678")
            with patch.object(deploy, "ROOT", root), patch.object(deploy, "RELEASES", releases), patch.object(deploy, "MAX_TOTAL_BYTES", 7):
                with self.assertRaisesRegex(RuntimeError, "budget"):
                    deploy.prune()
            self.assertTrue(pinned.exists())

    def test_smoke_uses_owned_process_and_retained_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            release = root / "release"
            (release / "dist").mkdir(parents=True)
            bun = release / "bun"
            bun.write_text("#!/bin/sh\nprintf '{\"revision\":\"fixture\"}\\n'\n")
            bun.chmod(0o755)
            definition = {"ProgramArguments": [str(bun), str(release / "service.js")]}
            (release / "service.plist").write_bytes(plistlib.dumps(definition))
            metadata = {"release": release.name, "bunSha256": deploy.digest(bun), "serviceSha256": deploy.digest(release / "service.plist")}
            (release / "dist/deployment.json").write_text(json.dumps(metadata))
            deploy.write_manifest(release)
            with tempfile.TemporaryFile() as lock:
                result = deploy.smoke(release, "http://127.0.0.1", "local", lock, root)
            self.assertEqual(result, {"revision": "fixture"})

    def test_staging_process_stops_after_controller_group_termination(self):
        controller = subprocess.Popen(
            [sys.executable, "-u", "-c", """
import os, subprocess, sys
lock_fd = os.open(sys.argv[2], os.O_CREAT | os.O_RDWR, 0o600)
child = subprocess.Popen([sys.executable, sys.argv[1], '30', str(lock_fd), sys.executable, '-u', '-c', "import time; print('ready', flush=True); time.sleep(30)"], stdin=subprocess.PIPE, start_new_session=True, pass_fds=(lock_fd,))
sys.stdin.read()
""", str(deploy.WORKER), str(Path(tempfile.gettempdir()) / f"web-stage-test-{os.getpid()}-lock")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            ready, _, _ = select.select([controller.stdout], [], [], 5)
            self.assertTrue(ready, "staging child did not start")
            self.assertEqual(controller.stdout.readline().strip(), b"ready")
            os.killpg(controller.pid, signal.SIGTERM)
            controller.wait(timeout=5)
            ready, _, _ = select.select([controller.stdout], [], [], 10)
            self.assertTrue(ready, "staging child remained running after controller termination")
            self.assertEqual(os.read(controller.stdout.fileno(), 1), b"")
        finally:
            if controller.poll() is None:
                os.killpg(controller.pid, signal.SIGKILL)
                controller.wait(timeout=5)
            controller.stdin.close()
            controller.stdout.close()
            (Path(tempfile.gettempdir()) / f"web-stage-test-{os.getpid()}-lock").unlink(missing_ok=True)

    def test_command_leader_exit_kills_descendant_ignoring_term(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryFile() as lock:
            ready = Path(directory) / "ready"
            program = """
import os, pathlib, signal, sys, time
pid = os.fork()
if pid == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
    time.sleep(30)
else:
    while not pathlib.Path(sys.argv[1]).exists():
        time.sleep(0.01)
"""
            with self.assertRaises(subprocess.CalledProcessError):
                deploy.staged_run([sys.executable, "-c", program, str(ready)], lock, 10, stderr=subprocess.DEVNULL)
            self.assertTrue(ready.exists())
            with self.assertRaises(ProcessLookupError):
                os.kill(int(ready.read_text()), 0)

    def test_deadline_fails_when_term_handler_exits_zero(self):
        program = "import signal, sys, time; signal.signal(signal.SIGTERM, lambda *args: sys.exit(0)); time.sleep(30)"
        with tempfile.TemporaryFile() as lock:
            with self.assertRaises(subprocess.CalledProcessError):
                deploy.staged_run([sys.executable, "-c", program], lock, 0.5, stderr=subprocess.DEVNULL)

    def test_worker_termination_cleans_its_term_ignoring_command(self):
        program = "import os, signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print(os.getpid(), flush=True); time.sleep(30)"
        with tempfile.TemporaryFile() as lock:
            worker = deploy.staged_process([sys.executable, "-u", "-c", program], lock, 30, stdout=subprocess.PIPE)
            child = None
            try:
                ready, _, _ = select.select([worker.stdout], [], [], 5)
                self.assertTrue(ready)
                child = int(worker.stdout.readline())
                worker.terminate()
                self.assertNotEqual(worker.wait(timeout=10), 0)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child, 0)
            finally:
                if worker.poll() is None:
                    worker.kill()
                    worker.wait(timeout=5)
                if child:
                    try:
                        os.kill(child, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                worker.stdin.close()
                worker.stdout.close()

    def test_killed_worker_leaves_lock_with_its_command(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lock"
            lock = path.open("w")
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            program = "import os, time; print(os.getpid(), flush=True); time.sleep(30)"
            worker = deploy.staged_process([sys.executable, "-u", "-c", program], lock, 30, stdout=subprocess.PIPE)
            child = None
            try:
                ready, _, _ = select.select([worker.stdout], [], [], 5)
                self.assertTrue(ready)
                child = int(worker.stdout.readline())
                worker.kill()
                worker.wait(timeout=5)
                lock.close()
                with path.open("w") as contender:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                if child:
                    try:
                        os.kill(child, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if worker.poll() is None:
                    worker.kill()
                    worker.wait(timeout=5)
                worker.stdin.close()
                worker.stdout.close()
                if not lock.closed:
                    lock.close()

    def test_killed_candidate_worker_cannot_publish_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release = root / "release"
            (release / "dist").mkdir(parents=True)
            (release / "dist/deployment.json").write_text('{"revision":"fixture"}')
            (release / "server.js").write_text("""
import os, pathlib, socket, time
listener = socket.socket()
listener.bind(('127.0.0.1', int(os.environ['RC_WEB_PORT'])))
pathlib.Path(os.environ['TEST_PID']).write_text(str(os.getpid()))
listener.listen()
while True:
    time.sleep(1)
""")
            lock_path = root / "lock"
            pid_path = root / "server-pid"
            original = deploy.staged_process
            workers = []

            def start_worker(*args, **kwargs):
                worker = original(*args, **kwargs)
                workers.append(worker)
                return worker

            def kill_worker_after_readiness(*args):
                workers[0].kill()
                workers[0].wait(timeout=5)
                return {"revision": "fixture"}

            with lock_path.open("w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                try:
                    with patch.object(deploy, "ROOT", root), patch.object(deploy, "runtime", return_value=sys.executable), patch.object(deploy, "smoke", return_value={"revision": "fixture"}), redirect_stdout(io.StringIO()):
                        deploy.candidate(release, {"TEST_PID": str(pid_path)}, "primary", lock)
                    self.assertFalse(list(root.glob(".build-*")))
                    pid_path.unlink()
                    with patch.object(deploy, "ROOT", root), patch.object(deploy, "runtime", return_value=sys.executable), patch.object(deploy, "staged_process", side_effect=start_worker), patch.object(deploy, "smoke", side_effect=kill_worker_after_readiness):
                        with self.assertRaises(subprocess.CalledProcessError) as error:
                            deploy.candidate(release, {"TEST_PID": str(pid_path)}, "primary", lock)
                    self.assertEqual(error.exception.returncode, -signal.SIGKILL)
                    self.assertTrue(list(root.glob(".build-*/candidate.log")))
                    self.assertTrue(release.exists())
                finally:
                    if pid_path.exists():
                        try:
                            os.kill(int(pid_path.read_text()), signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    if workers and workers[0].poll() is None:
                        workers[0].kill()
                        workers[0].wait(timeout=5)

    def test_natural_command_failure_preserves_exit_status(self):
        with tempfile.TemporaryFile() as lock:
            with self.assertRaises(subprocess.CalledProcessError) as error:
                deploy.staged_run([sys.executable, "-c", "raise SystemExit(37)"], lock, 10)
            self.assertEqual(error.exception.returncode, 37)

    def test_killed_worker_preserves_staging_until_command_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock_path = root / "lock"
            ready = threading.Event()
            child_pid = []
            original = deploy.staged_process

            def kill_worker(*args, **kwargs):
                worker = original(*args, stdout=subprocess.PIPE, **kwargs)
                def kill_after_ready():
                    child_pid.append(int(worker.stdout.readline()))
                    worker.kill()
                    ready.set()
                    worker.stdout.close()
                threading.Thread(target=kill_after_ready, daemon=True).start()
                return worker

            program = """
import os, pathlib, sys, time
staging, proceed, result = map(pathlib.Path, sys.argv[1:])
print(os.getpid(), flush=True)
while not proceed.exists():
    time.sleep(0.02)
result.write_text(str(staging.exists()))
"""
            proceed = root / "proceed"
            result = root / "result"
            try:
                with patch.object(deploy, "ROOT", root), patch.object(deploy, "staged_process", side_effect=kill_worker):
                    with lock_path.open("w") as lock:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        with self.assertRaises(subprocess.CalledProcessError):
                            with deploy.staging_directory() as staging:
                                (staging / "in-use").write_text("data")
                                deploy.staged_run([sys.executable, "-u", "-c", program, str(staging / "in-use"), str(proceed), str(result)], lock, 30)
                    self.assertTrue(ready.wait(5))
                    self.assertTrue((staging / "in-use").exists())
                    with lock_path.open("w") as contender:
                        with self.assertRaises(BlockingIOError):
                            fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    proceed.touch()
                    deadline = time.monotonic() + 5
                    while not result.exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertEqual(result.read_text(), "True")
                    with lock_path.open("w") as contender:
                        while True:
                            try:
                                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                                break
                            except BlockingIOError:
                                if time.monotonic() >= deadline:
                                    raise
                                time.sleep(0.02)
                        child_pid.clear()
                        shutil.rmtree(staging)
                    self.assertFalse(staging.exists())
            finally:
                if child_pid:
                    try:
                        os.kill(child_pid[0], signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_smoke_rejects_excessive_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            release = root / "release"
            (release / "dist").mkdir(parents=True)
            bun = release / "bun"
            bun.write_text("#!/bin/sh\nhead -c 1048577 /dev/zero\n")
            bun.chmod(0o755)
            (release / "service.plist").write_bytes(plistlib.dumps({"ProgramArguments": [str(bun), str(release / "service.js")]}))
            metadata = {"release": release.name, "bunSha256": deploy.digest(bun), "serviceSha256": deploy.digest(release / "service.plist")}
            (release / "dist/deployment.json").write_text(json.dumps(metadata))
            deploy.write_manifest(release)
            with tempfile.TemporaryFile() as lock:
                with self.assertRaisesRegex(RuntimeError, "exceeds 1 MiB"):
                    deploy.smoke(release, "http://127.0.0.1", "local", lock, root)

    def test_staging_process_has_its_own_deadline(self):
        with tempfile.TemporaryFile() as lock:
            with self.assertRaises(subprocess.CalledProcessError):
                deploy.staged_run([sys.executable, "-c", "import time; time.sleep(30)"], lock, 0.1, stderr=subprocess.DEVNULL)

    def test_rollback_is_not_an_operation(self):
        with patch.object(sys, "argv", ["deploy.py", "rollback"]), patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as error:
                deploy.main()
            self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
