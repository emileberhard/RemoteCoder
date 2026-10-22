import fcntl
import importlib.util
import io
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import ExitStack, contextmanager, nullcontext, redirect_stdout
from itertools import product
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("codex_build", SCRIPTS / "codex-build.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


from process_group import (
    audit_alive,
    process_identity,
    same_process,
    signal_process,
)


def _drain_upload_case(process):
    identity = process_identity(process.pid)
    if (
        identity is None
        or identity["ppid"] != os.getpid()
        or identity["pgid"] != process.pid
    ):
        raise ValueError(
            "Upload fixture lost its owned process identity before cleanup"
        )
    owned = {}
    deadline = time.monotonic() + 5
    pending = [identity]
    try:
        while pending:
            for actor in pending:
                if len(owned) >= 64 or time.monotonic() >= deadline:
                    raise TimeoutError(
                        "Upload fixture process drain exceeded its ownership bound"
                    )
                owned[actor["pid"]] = actor
                if not signal_process(actor, signal.SIGSTOP):
                    owned.pop(actor["pid"])
                    continue
                while True:
                    current = process_identity(actor["pid"])
                    if not same_process(current, actor):
                        owned.pop(actor["pid"])
                        break
                    if current["state"] == 4:
                        break
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError(
                            f"Upload fixture PID {actor['pid']} did not acknowledge suspension within the cleanup budget"
                        )
                    time.sleep(min(0.01, remaining))
            if identity["pid"] not in owned:
                raise ValueError("Upload fixture owner could not be suspended")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(
                    "Upload fixture process inventory exceeded its cleanup budget"
                )
            try:
                rows = subprocess.check_output(
                    ["ps", "-axo", "pid=,ppid="], text=True, timeout=remaining
                )
            except subprocess.TimeoutExpired as error:
                raise TimeoutError(
                    "Upload fixture process inventory exceeded its cleanup budget"
                ) from error
            pending = []
            for line in rows.splitlines():
                pid, parent = map(int, line.split())
                if parent in owned and pid not in owned:
                    actor = process_identity(pid)
                    if actor is not None and actor["ppid"] == parent:
                        pending.append(actor)
    finally:
        for actor in reversed(tuple(owned.values())):
            signal_process(actor, signal.SIGKILL)
    while any(audit_alive(actor) for actor in owned.values()):
        if time.monotonic() >= deadline:
            raise TimeoutError("Upload fixture still has live processes after cleanup")
        time.sleep(0.01)
    return list(owned.values())


def _run_upload_case(root, local, stalled):
    program = "import importlib.util,sys; from pathlib import Path; s=importlib.util.spec_from_file_location('upload_fixture',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m._real_upload_case(Path(sys.argv[2]),sys.argv[3]=='local',sys.argv[4]=='stalled')"
    process = subprocess.Popen(
        [
            sys.executable,
            "-c",
            program,
            str(Path(__file__).resolve()),
            str(root),
            "local" if local else "remote",
            "stalled" if stalled else "copy",
        ],
        start_new_session=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        owner = process_identity(process.pid)
        try:
            output, errors = process.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            if not stalled:
                raise
            try:
                child = json.loads((root / "stalled-child.json").read_text())
                receiver = json.loads((root / "stalled-receiver.json").read_text())
                actors = [owner, child, receiver]
                for actor in (child, receiver):
                    signal_process(actor, signal.SIGKILL)
                process.communicate(timeout=10)
                if any(audit_alive(actor) for actor in actors):
                    raise RuntimeError("Stalled upload fixture still has live owners")
                with (Path(receiver["run"]) / "collection.lock").open("a") as lease:
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                (root / "drained.json").write_text(json.dumps(actors))
            except Exception as error:
                raise RuntimeError("Stalled upload fixture cleanup failed") from error
            raise
        if process.returncode:
            raise AssertionError(
                f"Upload fixture failed: {output.decode()} {errors.decode()}"
            )
    finally:
        try:
            if process.returncode is None:
                actors = _drain_upload_case(process)
                (root / "drained.json").write_text(json.dumps(actors))
        finally:
            try:
                if process.returncode is None:
                    process.kill()
                    process.wait(timeout=5)
            finally:
                process.stdout.close()
                process.stderr.close()


def _real_upload_case(root, local, stalled):
    original_output = module.output
    checks = unittest.TestCase()
    scripts = root / "scripts"
    scripts.mkdir()
    for name in module.TOOLS:
        shutil.copy2(SCRIPTS / name, scripts / name)
    (root / ".xcode-version").write_text("27.0")
    source = root / "source"
    (source / "codex-rs").mkdir(parents=True)
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
    bridge = root / "ssh-bridge.py"
    bridge.write_text(
        "import os,sys\nos.execv('/bin/bash',['bash','-c',' '.join(sys.argv[2:])])\n"
    )

    def output(command, **kwargs):
        if any("Path.home" in part for part in command):
            return json.dumps(str(root))
        return original_output(command, **kwargs)

    @contextmanager
    def worker(command):
        run = Path(command[-1]) if local else Path(shlex.split(command[-1])[-1])
        for name in module.TOOLS:
            checks.assertEqual(
                (run / "tools" / name).read_bytes(),
                (SCRIPTS / name).read_bytes(),
            )
        request = json.loads((run / "request.json").read_text())
        checks.assertEqual(
            request["commit"],
            original_output(["git", "-C", str(source), "rev-parse", "HEAD"]),
        )
        checks.assertTrue((run / "source.bundle").is_file())
        checks.assertTrue((run / "rsync-upload.py").is_file())
        checks.assertTrue((run / "collection.lock").is_file())
        yield {
            "exitCode": 1,
            "log": str(run / "fixture.log"),
            "error": "fixture stops before compilation",
        }

    original_prepare = module.prepare_upload_receiver

    def prepare(shell, run):
        original_prepare(shell, run)
        if stalled:
            child_code = "import json,signal,sys; from pathlib import Path; from process_group import own_identity; signal.signal(signal.SIGTERM,signal.SIG_IGN); Path(sys.argv[1]).write_text(json.dumps(own_identity())); sys.stdin.read()"
            receiver = f"""import fcntl,json,os,signal,subprocess,sys
from pathlib import Path
sys.path.insert(0,{str(scripts)!r})
from process_group import own_identity
signal.signal(signal.SIGTERM,signal.SIG_IGN)
run=Path(sys.argv[1])
with (run/'collection.lock').open('a') as lease:
 fcntl.flock(lease,fcntl.LOCK_EX)
 child=subprocess.Popen([sys.executable,'-c',{child_code!r},{str(root / "stalled-child.json")!r}],stdin=subprocess.PIPE,start_new_session=True,env=os.environ|{{'PYTHONPATH':{str(scripts)!r}}})
 Path({str(root / "stalled-receiver.json")!r}).write_text(json.dumps(own_identity()|{{'run':str(run)}}))
 reader,writer=os.pipe(); os.read(reader,1)
"""
            (run / "rsync-upload.py").write_text(receiver)

    with (
        patch.object(module, "prepare_upload_receiver", side_effect=prepare),
        patch.object(sys, "argv", ["codex-build.py", str(source)]),
        patch.dict(os.environ, {"RC_GATEWAY_BUILD_HOST": "fixture-macbook"}),
        patch.object(
            module.socket,
            "gethostname",
            return_value="fixture-macbook" if local else "fixture-mini",
        ),
        patch.object(module, "__file__", str(scripts / "codex-build.py")),
        patch.object(module, "SSH", [sys.executable, str(bridge)]),
        patch.object(module, "output", side_effect=output),
        patch.object(module, "collecting_worker", side_effect=worker) as collected,
    ):
        checks.assertEqual(module.main(), 1)
        collected.assert_called_once()


class CodexPackageReuseTests(unittest.TestCase):
    def test_client_default_output_preserves_existing_outputs(self):
        version = json.loads(
            (SCRIPTS.parent / "docs/codex/compatibility.json").read_text()
        )["codexCliVersion"]
        default = Path("/tmp/remotecoder-codex-package-" + version).resolve()
        real_exists = Path.exists

        def exists(path, **kwargs):
            return path == default or real_exists(path, **kwargs)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in module.TOOLS:
                (scripts / name).write_text("fixture helper")
            (root / ".xcode-version").write_text("27.0")
            chosen = root / "chosen-package"
            chosen.mkdir()
            receipt = {
                "exitCode": 0,
                "package": "/remote/package",
                "packageSHA256": "exact-digest",
            }
            replies = (
                ("--porcelain", ""),
                ("cat-file", json.dumps({"base": "a" * 40, "hasCommit": True})),
                ("rev-parse", "a" * 40),
                (
                    "Cargo.toml",
                    '[workspace.package]\nversion="' + version + '"',
                ),
                ("Path.home", json.dumps(str(root))),
                ("mkdir", ""),
            )

            def output(command, **kwargs):
                text = " ".join(command)
                return next(reply for token, reply in replies if token in text)

            for local, explicit, matching in product(
                (False, True), (None, chosen), (True, False)
            ):
                expected = explicit.resolve() if explicit else default
                with self.subTest(local=local, explicit=explicit, matching=matching):
                    arguments = ["codex-build.py", str(root / "source")]
                    if explicit:
                        arguments.append(str(explicit))
                    destinations = []

                    def valid(
                        path, digest, destinations=destinations, matching=matching
                    ):
                        destinations.append(path)
                        self.assertEqual(digest, "exact-digest")
                        return matching or path.name == "package"

                    with (
                        patch.object(sys, "argv", arguments),
                        patch.dict(
                            os.environ, {"RC_GATEWAY_BUILD_HOST": "fixture-macbook"}
                        ),
                        patch.object(
                            module.socket,
                            "gethostname",
                            return_value="fixture-macbook" if local else "fixture-mini",
                        ),
                        patch.object(
                            module, "__file__", str(scripts / "codex-build.py")
                        ),
                        patch.object(module, "output", side_effect=output),
                        patch.object(
                            module,
                            "host_job_assertion",
                            return_value=nullcontext(0),
                        ),
                        patch.object(
                            module,
                            "collecting_worker",
                            return_value=nullcontext(receipt),
                        ),
                        patch.object(module, "prepare_upload_receiver") as prepare,
                        patch.object(
                            module,
                            "run_connected",
                            return_value=subprocess.CompletedProcess([], 0),
                        ) as uploads,
                        patch.object(module.subprocess, "run") as transfer,
                        patch.object(Path, "exists", exists),
                        patch.object(module, "valid_package", side_effect=valid),
                        patch.object(Path, "replace") as publish,
                        redirect_stdout(io.StringIO()) as printed,
                    ):
                        if matching:
                            self.assertEqual(module.main(), 0)
                            self.assertIn(
                                "codex_package=" + str(expected),
                                printed.getvalue(),
                            )
                        else:
                            with self.assertRaisesRegex(
                                ValueError,
                                "Output already contains another package",
                            ):
                                module.main()
                        self.assertEqual(destinations[0], expected)
                        prepare.assert_called_once()
                        if local:
                            self.assertEqual(
                                [
                                    Path(call.args[0][-2]).name
                                    for call in uploads.call_args_list
                                ],
                                [*module.TOOLS, "request.json"],
                            )
                            self.assertTrue(
                                all(
                                    Path(call.args[0][1]).name == "rsync-upload.py"
                                    for call in uploads.call_args_list
                                )
                            )
                        else:
                            uploads.assert_not_called()
                        publish.assert_not_called()
                        self.assertTrue(
                            all(
                                call.args[0][0] == "rsync"
                                for call in transfer.call_args_list
                            )
                        )

    def test_client_prepares_and_uploads_through_both_real_receivers(self):
        for local in (False, True):
            with self.subTest(local=local), tempfile.TemporaryDirectory() as temporary:
                _run_upload_case(Path(temporary), local, False)

    def test_stalled_upload_deadline_drains_receivers_and_separate_child_groups(self):
        for local in (False, True):
            with self.subTest(local=local), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                with self.assertRaises(subprocess.TimeoutExpired) as stalled:
                    _run_upload_case(root, local, True)
                self.assertEqual(stalled.exception.timeout, 15)
                receiver = json.loads((root / "stalled-receiver.json").read_text())
                child = json.loads((root / "stalled-child.json").read_text())
                self.assertNotEqual(receiver["pgid"], child["pgid"])
                actors = json.loads((root / "drained.json").read_text())
                self.assertGreaterEqual(len(actors), 3)
                self.assertTrue(all(not audit_alive(actor) for actor in actors))
                self.assertFalse(audit_alive(receiver))
                self.assertFalse(audit_alive(child))
                with (Path(receiver["run"]) / "collection.lock").open("a") as lease:
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_unacknowledged_suspension_obeys_cleanup_budget_and_kills_its_actor(self):
        import select

        original_identity = process_identity
        with subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import sys; print('ready',flush=True); sys.stdin.read()",
            ],
            start_new_session=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        ) as child:
            retained = original_identity(child.pid)
            expired = threading.Event()

            def safety_expiry():
                expired.set()
                signal_process(retained, signal.SIGKILL)

            def never_stopped(pid):
                current = original_identity(pid)
                return current | {"state": 2} if current is not None else None

            safety = threading.Timer(6, safety_expiry)
            try:
                self.assertTrue(select.select([child.stdout], [], [], 5)[0])
                self.assertEqual(child.stdout.readline(), b"ready\n")
                retained = original_identity(child.pid)
                safety.start()
                started = time.monotonic()
                with (
                    patch(__name__ + ".process_identity", side_effect=never_stopped),
                    patch("process_group.process_identity", side_effect=never_stopped),
                    self.assertRaisesRegex(TimeoutError, "suspension"),
                ):
                    _drain_upload_case(child)
                self.assertFalse(
                    expired.is_set(), "Cleanup required the test safety watchdog"
                )
                self.assertLess(time.monotonic() - started, 6)
                child.communicate(timeout=1)
                self.assertFalse(audit_alive(retained))
            finally:
                safety.cancel()
                if safety.ident is not None:
                    safety.join(timeout=1)
                signal_process(retained, signal.SIGKILL)
                child.communicate(timeout=5)

    def test_identical_inputs_reuse_verified_package_and_corruption_rebuilds(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "codex-runtime/repo/.git").mkdir(parents=True)

            def build(command, cwd, environment, log, leases):
                self.assertEqual(len(leases), 2)
                package = current_run / "package"
                package.mkdir()
                (package / "codex-package.json").write_text("{}")
                (package / "codex").write_bytes(b"verified binary")
                return 0

            with (
                patch.object(module, "cache_root", return_value=root),
                patch.object(
                    module,
                    "build_inputs",
                    return_value={"source": "exact", "profile": "release"},
                ),
                patch.object(module, "build_capacity", return_value=nullcontext(0)),
                patch.object(
                    module,
                    "output",
                    side_effect=lambda command, **kw: (
                        "exact" if "rev-parse" in command else ""
                    ),
                ),
                patch.object(module.subprocess, "run"),
                patch.object(module, "run_owned", side_effect=build) as compile,
            ):
                for number in range(3):
                    current_run = root / str(number)
                    current_run.mkdir()
                    (current_run / "request.json").write_text(
                        json.dumps(
                            {
                                "buildId": str(number),
                                "commit": "exact",
                                "profile": "release",
                                "developerDirectory": "/test/Xcode",
                            }
                        )
                    )
                    marker = root / "codex-runtime/build.lock"
                    marker.touch()
                    os.utime(marker, (1, 1))
                    result = module.worker(current_run)
                    self.assertGreater(marker.stat().st_mtime, 1)
                    self.assertEqual(result["exitCode"], 0)
                    self.assertEqual(result["reused"], number == 1)
                    if number == 1:
                        (Path(result["package"]) / "codex").write_bytes(b"corrupt")
                self.assertEqual(compile.call_count, 2)

    def test_build_failure_never_publishes_a_package_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "codex-runtime/repo/.git").mkdir(parents=True)
            run = root / "run"
            run.mkdir()
            (run / "request.json").write_text(
                json.dumps(
                    {
                        "buildId": "failed",
                        "commit": "exact",
                        "profile": "release",
                        "developerDirectory": "/test/Xcode",
                    }
                )
            )

            def failing_build(command, cwd, environment, log, leases):
                staged = run / "package"
                staged.mkdir()
                (staged / "codex-package.json").write_text("{}")
                (staged / "codex").write_bytes(b"partial binary")
                return 1

            with (
                patch.object(module, "cache_root", return_value=root),
                patch.object(module, "build_inputs", return_value={"source": "exact"}),
                patch.object(module, "build_capacity", return_value=nullcontext(0)),
                patch.object(
                    module,
                    "output",
                    side_effect=lambda command, **kw: (
                        "exact" if "rev-parse" in command else ""
                    ),
                ),
                patch.object(module.subprocess, "run"),
                patch.object(module, "run_owned", side_effect=failing_build),
            ):
                result = module.worker(run)
            package = Path(result["package"])
            self.assertEqual(result["exitCode"], 1)
            self.assertFalse(package.exists())
            self.assertFalse(package.with_suffix(".json").exists())

    def test_cache_full_fails_until_a_live_reader_releases_its_lease(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as leases:
            root = Path(temporary)
            packages = root / "packages"
            packages.mkdir()
            names = ("a" * 64, "b" * 64)
            for name in names:
                (packages / name).mkdir()
                (packages / (name + ".json")).write_text("{}")
                run = root / "runs" / name
                run.mkdir(parents=True)
                (run / "receipt.json").write_text(
                    json.dumps({"exitCode": 0, "package": str(packages / name)})
                )
                leases.enter_context(module.file_lease(run / "collection.lock"))
            with patch.object(module, "MAX_CACHED_PACKAGES", 2):
                self.assertFalse(module.make_cache_room(root, packages / ("c" * 64)))
                self.assertFalse(module.make_cache_room(root, packages / names[0]))
                self.assertEqual(len(list(packages.glob("*/"))), 2)
                leases.close()
                # No durable collected marker is required after process/lease exit.
                self.assertTrue(module.make_cache_room(root, packages / ("c" * 64)))
            self.assertEqual(len(list(packages.glob("*/"))), 1)

    def test_cache_admission_preserves_warm_packages_when_retirement_cannot_fit(self):
        for legacy_count, pinned_count in ((8, 0), (6, 2), (6, 0)):
            with (
                self.subTest(legacy=legacy_count, pinned=pinned_count),
                tempfile.TemporaryDirectory() as temporary,
                ExitStack() as leases,
            ):
                root = Path(temporary)
                packages = root / "packages"
                packages.mkdir()
                for number in range(legacy_count):
                    (packages / f"{number:012x}").mkdir()
                for number in range(pinned_count):
                    p = packages / f"{number:064x}"
                    p.mkdir()
                    run = root / "runs" / p.name
                    run.mkdir(parents=True)
                    (run / "receipt.json").write_text(
                        json.dumps({"exitCode": 0, "package": str(p)})
                    )
                    leases.enter_context(module.file_lease(run / "collection.lock"))
                oldest, newest = packages / ("a" * 64), packages / ("b" * 64)
                for p, timestamp in ((oldest, 10), (newest, 20)):
                    p.mkdir()
                    (p / "binary").write_bytes(b"warm package")
                    p.with_suffix(".json").write_text("receipt")
                    os.utime(p, (timestamp, timestamp))
                admitted = module.make_cache_room(root, packages / ("c" * 64))
                self.assertEqual(admitted, legacy_count + pinned_count < 8)
                self.assertEqual(oldest.exists(), not admitted)
                self.assertEqual(oldest.with_suffix(".json").exists(), not admitted)
                self.assertEqual((newest / "binary").read_bytes(), b"warm package")
                self.assertEqual(newest.with_suffix(".json").read_text(), "receipt")
                self.assertEqual(
                    len(list(packages.glob("*/"))),
                    legacy_count + pinned_count + (1 if admitted else 2),
                )

    def test_early_worker_failure_reaches_collector_and_durable_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary)
            (run / "request.json").write_text(json.dumps({"commit": "exact-source"}))
            (run / "progress.json").write_text(
                json.dumps({"phasesSeconds": {"source": 0.2}, "elapsedSeconds": 0.3})
            )
            bootstrap = """import importlib.util,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('controller',sys.argv[1])
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
def fail(run):
 raise ValueError('legacy package capacity requires reviewed retirement')
module.worker=fail
raise SystemExit(module.serve_worker(Path(sys.argv[2])))
"""
            with module.collecting_worker(
                [
                    sys.executable,
                    "-c",
                    bootstrap,
                    str(SCRIPTS / "codex-build.py"),
                    str(run),
                ]
            ) as receipt:
                self.assertEqual(receipt["exitCode"], 1)
                self.assertEqual(receipt["sourceCommit"], "exact-source")
                self.assertIn("legacy package capacity", receipt["error"])
                self.assertEqual(receipt["phasesSeconds"], {"source": 0.2})
                self.assertNotIn("package", receipt)
                self.assertEqual(
                    json.loads((run / "receipt.json").read_text()), receipt
                )
                self.assertIn(receipt["error"], (run / "build.log").read_text())

    def test_interrupted_build_staging_is_removed_before_cache_admission(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run = root / "runs/interrupted"
            (run / "package").mkdir(parents=True)
            (run / "package/partial").write_bytes(b"interrupted package bytes")
            self.assertTrue(
                module.make_cache_room(root, root / "packages" / ("a" * 64))
            )
            self.assertFalse((run / "package").exists())
            with self.assertRaises(RuntimeError), module.staged_package(run) as stage:
                stage.mkdir()
                (stage / "partial").write_bytes(b"failed package bytes")
                raise RuntimeError("compiler failed")
            self.assertFalse((run / "package").exists())

    def test_failed_collection_closes_the_worker_pipe_and_releases_its_pin(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            worker = self.reader_worker(root)
            with (
                self.assertRaisesRegex(RuntimeError, "transfer failed"),
                module.collecting_worker([sys.executable, str(worker)]),
            ):
                with (
                    (root / "collection.lock").open("a") as lock,
                    self.assertRaises(BlockingIOError),
                ):
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                raise RuntimeError("transfer failed")
            self.assertTrue((root / "released").exists())
            with (root / "collection.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_cancelled_collector_releases_reader_without_a_cleanup_command(self):
        for cancellation in ("terminate", "kill"):
            with self.subTest(cancellation=cancellation):
                self.assert_collector_cancellation(cancellation)

    def assert_collector_cancellation(self, cancellation):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            worker = self.reader_worker(root)
            bootstrap = """import importlib.util,sys,time
from pathlib import Path
spec=importlib.util.spec_from_file_location('controller',sys.argv[1])
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
with module.collecting_worker([sys.executable,sys.argv[2]]):
 Path(sys.argv[3]).touch()
 time.sleep(30)
"""
            client = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    bootstrap,
                    str(SCRIPTS / "codex-build.py"),
                    str(worker),
                    str(root / "collecting"),
                ]
            )
            try:
                deadline = time.monotonic() + 5
                while (
                    not (root / "collecting").exists() and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                self.assertTrue((root / "collecting").exists())
                getattr(client, cancellation)()
                client.wait(timeout=5)
                deadline = time.monotonic() + 5
                while not (root / "released").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((root / "released").exists())
                with (root / "collection.lock").open("a") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                if client.poll() is None:
                    client.kill()
                    client.wait()

    @staticmethod
    def reader_worker(root):
        worker = root / "reader.py"
        worker.write_text(
            "import importlib.util,json\nfrom pathlib import Path\n"
            + f"spec=importlib.util.spec_from_file_location('controller',{str(SCRIPTS / 'codex-build.py')!r})\n"
            + "module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)\n"
            + "root=Path(__file__).parent\n"
            + "module.worker=lambda run: {'exitCode':0}\n"
            + "module.serve_worker(root)\n"
            + "(root/'released').touch()\n"
        )
        return worker

    def test_toolchain_identity_uses_the_forks_cargo_working_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in module.TOOLS:
                (root / name).write_text("helper")
            with patch.object(module, "output", return_value="compiler") as command:
                first = module.build_inputs(
                    "exact", "release", {"CARGO_HOME": str(root)}, root, root
                )
                rust_calls = [
                    call
                    for call in command.call_args_list
                    if call.args[0][0] in ("rustc", "cargo")
                ]
                self.assertEqual(len(rust_calls), 2)
                for call in rust_calls:
                    self.assertEqual(call.kwargs["cwd"], root / "codex-rs")
                (root / "config.toml").write_text(
                    '[build]\nrustflags=["-Copt-level=2"]\n'
                )
                self.assertNotEqual(
                    first,
                    module.build_inputs(
                        "exact", "release", {"CARGO_HOME": str(root)}, root, root
                    ),
                )
