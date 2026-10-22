import base64
import contextlib
import fcntl
import json
import multiprocessing
import os
import signal
import subprocess
import sys
import time

import pytest
from test_worker_artifact import _finish, bundle, old_worker

from agent_calls import worker_artifact

BACKEND = '''import json, os, zipfile
from pathlib import Path

def build_editable(wheel_directory, config_settings=None, metadata_directory=None):
    root = Path(__file__).resolve().parent.parent
    release = Path(os.environ["RC_TEST_BUILD_RELEASE"])
    if not release.with_suffix(".done").exists():
        lease = root / "worker.lease"
        identity = lease.stat() if lease.exists() else None
        descriptors = []
        for name in os.listdir("/dev/fd"):
            try:
                descriptor = int(name)
                value = os.fstat(descriptor)
                if identity is not None and (value.st_dev, value.st_ino) == (identity.st_dev, identity.st_ino):
                    descriptors.append(descriptor)
            except OSError:
                continue
        (root / "writer-active").write_text("sync in progress")
        ready = Path(os.environ["RC_TEST_BUILD_READY"])
        temporary = ready.with_suffix(".tmp")
        temporary.write_text(json.dumps({"writerPid": os.getpid(), "uvPid": os.getppid(), "leaseFds": descriptors}))
        temporary.replace(ready)
        with release.open("rb") as handle:
            handle.read(1)
        (root / "writer-finished").write_text("sync completed")
        release.with_suffix(".done").touch()
    name = "writer_fixture-0.1.0-py3-none-any.whl"
    with zipfile.ZipFile(Path(wheel_directory) / name, "w") as wheel:
        wheel.writestr("writer_fixture-0.1.0.dist-info/METADATA", "Metadata-Version: 2.1\\nName: writer-fixture\\nVersion: 0.1.0\\n")
        wheel.writestr("writer_fixture-0.1.0.dist-info/WHEEL", "Wheel-Version: 1.0\\nGenerator: fixture\\nRoot-Is-Purelib: true\\nTag: py3-none-any\\n")
        wheel.writestr("writer_fixture-0.1.0.dist-info/RECORD", "writer_fixture-0.1.0.dist-info/METADATA,,\\nwriter_fixture-0.1.0.dist-info/WHEEL,,\\nwriter_fixture-0.1.0.dist-info/RECORD,,\\n")
    return name
'''


def _real_install(candidate, root, environment):
    os.setsid()
    os.environ.update(environment)
    worker_artifact.install(candidate, root)


def _recover_install(candidate, root, environment, progress):
    original = worker_artifact._lease
    reported = False

    @contextlib.contextmanager
    def observed_lease(path, operation):
        nonlocal reported
        with contextlib.ExitStack() as stack:
            try:
                descriptor = stack.enter_context(original(path, operation))
            except BlockingIOError:
                if path == root / candidate["workerHash"] / "worker.lease" and not reported:
                    progress.send({"waiting": True})
                    reported = True
                raise
            yield descriptor

    worker_artifact._lease = observed_lease
    try:
        _real_install(candidate, root, environment)
        progress.send({"completed": True})
    except Exception as error:
        progress.send({"error": str(error)})
        raise


def _wait_for_ready(path, installer):
    deadline = time.monotonic() + 10
    while not path.exists():
        assert installer.is_alive(), "Installer exited before its real sync writer started"
        assert time.monotonic() < deadline, "Real sync writer did not start"
        time.sleep(0.01)
    return json.loads(path.read_text())


def _wait_for_lease(path):
    deadline = time.monotonic() + 5
    while True:
        try:
            with worker_artifact._lease(path / "worker.lease", fcntl.LOCK_EX | fcntl.LOCK_NB):
                return
        except BlockingIOError:
            assert time.monotonic() < deadline, "Surviving sync writer did not release its artifact lease"
            time.sleep(0.01)


@pytest.mark.parametrize("release_while_waiting", [False, True])
def test_real_sync_writer_retains_lease_after_installer_is_killed(tmp_path, monkeypatch, release_while_waiting):
    specification = tmp_path / "specification"
    specification.mkdir()
    project = '''[project]
name = "writer-fixture"
version = "0.1.0"
requires-python = ">=3.14,<3.15"
dependencies = []
[build-system]
requires = []
build-backend = "lease_backend"
backend-path = ["."]
[dependency-groups]
worker-build = []
'''
    (specification / "pyproject.toml").write_text(project)
    (specification / "lease_backend.py").write_text(BACKEND)
    environment = {"UV_CACHE_DIR": str(tmp_path / "uv-cache"), "UV_OFFLINE": "1", "UV_PYTHON": sys.executable}
    subprocess.run(["uv", "lock", "--project", str(specification), "--offline"],
                   env=os.environ | environment, capture_output=True, text=True, check=True, timeout=30)
    root = tmp_path / "call-workers"
    source = bundle()
    selected = old_worker(root, source)
    worker_artifact._save_json(root / "references.json", {
        host: {"selected": source["workerHash"], "pending": None, "generation": None}
        for host in ["gateway-primary", "gateway-secondary"]
    })
    entry = '''#!/usr/bin/env python3
import json
from pathlib import Path
manifest = json.loads((Path(__file__).resolve().parents[1] / "worker-artifact.json").read_text())
print(json.dumps({"workerHash": manifest["workerHash"], "identity": manifest["identity"], "protocolVersion": 1}))
'''
    files = {"agent-calls/pyproject.toml": project.encode(), "agent-calls/lease_backend.py": BACKEND.encode(),
             "agent-calls/uv.lock": (specification / "uv.lock").read_bytes(), "dev-tools/agent-call": entry.encode()}
    candidate = bundle(source["workerHash"])
    candidate["files"] = {name: base64.b64encode(data).decode() for name, data in files.items()}
    candidate["workerHash"] = worker_artifact.content_hash(candidate["identity"], files)
    destination = root / candidate["workerHash"]
    ready, release = tmp_path / "writer-ready.json", tmp_path / "writer-release.fifo"
    os.mkfifo(release, 0o600)
    environment.update({"RC_TEST_BUILD_READY": str(ready), "RC_TEST_BUILD_RELEASE": str(release),
                        "UV_PROJECT_ENVIRONMENT": str(destination / "agent-calls/.venv")})
    installer = multiprocessing.get_context("spawn").Process(target=_real_install, args=(candidate, root, environment))
    uv_owner = None
    recovery = None
    reader = writer = None
    try:
        installer.start()
        evidence = _wait_for_ready(ready, installer)
        uv_owner = worker_artifact._process_owner(evidence["uvPid"])
        assert uv_owner is not None
        assert os.getpgid(evidence["uvPid"]) == installer.pid
        installer.kill()
        installer.join(5)
        assert installer.exitcode is not None and installer.exitcode < 0
        assert worker_artifact._owner_alive(uv_owner)
        worker_artifact.finish_reference(_finish(candidate, source["workerHash"]), root)
        claim = (root / "worker-build.json").read_bytes()
        for name, value in environment.items():
            monkeypatch.setenv(name, value)
        assert evidence["leaseFds"], "Real uv build backend did not inherit the artifact lease"
        if release_while_waiting:
            reader, writer = multiprocessing.get_context("spawn").Pipe(duplex=False)
            recovery = multiprocessing.get_context("spawn").Process(
                target=_recover_install, args=(candidate, root, environment, writer))
            recovery.start()
            assert reader.poll(5)
            assert reader.recv() == {"waiting": True}
            assert recovery.is_alive()
            assert not reader.poll()
        else:
            monkeypatch.setattr(worker_artifact, "WORKER_LEASE_WAIT_SECONDS", 0.2)
            started = time.monotonic()
            with pytest.raises(RuntimeError, match="holder PIDs:") as failure:
                worker_artifact.install(candidate, root)
            assert 0.2 <= time.monotonic() - started < 8
            assert str(evidence["uvPid"]) in str(failure.value)
            assert str(evidence["writerPid"]) in str(failure.value)
            assert "then retry" in str(failure.value)
        assert (root / "worker-build.json").read_bytes() == claim
        assert (destination / "writer-active").read_text() == "sync in progress"
        assert not (destination / "writer-finished").exists()
        descriptor = os.open(release, os.O_WRONLY | os.O_NONBLOCK)
        try:
            os.write(descriptor, b"x")
        finally:
            os.close(descriptor)
        if recovery is not None:
            assert reader.poll(10)
            assert reader.recv() == {"completed": True}
            recovery.join(5)
            assert recovery.exitcode == 0
        else:
            _wait_for_lease(destination)
            assert (destination / "writer-finished").exists()
            result = worker_artifact.install(candidate, root)
            assert result["workerHash"] == candidate["workerHash"]
        assert release.with_suffix(".done").exists()
        assert worker_artifact.artifact_contract(selected)["workerHash"] == source["workerHash"]
    finally:
        if recovery is not None:
            if recovery.is_alive():
                os.killpg(recovery.pid, signal.SIGKILL)
            recovery.join(5)
        if uv_owner is not None and worker_artifact._owner_alive(uv_owner):
            assert os.getpgid(uv_owner["pid"]) == installer.pid
            os.killpg(installer.pid, signal.SIGKILL)
        if installer.pid is not None:
            if installer.is_alive():
                os.killpg(installer.pid, signal.SIGKILL)
            installer.join(5)
        if destination.exists():
            _wait_for_lease(destination)
        if reader is not None:
            reader.close()
        if writer is not None:
            writer.close()
