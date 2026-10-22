from __future__ import annotations

import base64
import contextlib
import fcntl
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path

MAX_SOURCE_BYTES = 4 * 1024 * 1024
MAX_ORIGIN_HOSTS = 8
MAX_PROTECTED_WORKERS = 2 * MAX_ORIGIN_HOSTS
WORKER_LEASE_WAIT_SECONDS = 5


def content_hash(identity: dict, files: dict[str, bytes]) -> str:
    if not files or len(files) > 128 or sum(map(len, files.values())) > MAX_SOURCE_BYTES:
        raise RuntimeError("Worker source table exceeds its capacity")
    digest = hashlib.sha256(b"RemoteCoder call worker v1\0")
    digest.update(json.dumps(identity, sort_keys=True, separators=(",", ":")).encode() + b"\0")
    for name, data in sorted(files.items()):
        if "\0" in name or "\\" in name or any(part in {"", ".", ".."} for part in name.split("/")):
            raise RuntimeError("Invalid worker source path")
        digest.update(name.encode() + b"\0" + len(data).to_bytes(8, "big") + data)
    return digest.hexdigest()


def artifact_contract(root: Path) -> dict:
    with (root / "worker-artifact.json").open("rb") as handle:
        data = handle.read(65537)
    if len(data) > 65536:
        raise RuntimeError("Worker manifest exceeds its capacity")
    manifest = json.loads(data)
    files = {}
    remaining = MAX_SOURCE_BYTES
    if len(manifest["files"]) > 128:
        raise RuntimeError("Worker source table exceeds its capacity")
    for name in manifest["files"]:
        if "\0" in name or "\\" in name or any(part in {"", ".", ".."} for part in name.split("/")):
            raise RuntimeError("Invalid worker source path")
        path = root / name
        if path.is_symlink():
            raise RuntimeError("Worker sources cannot be links")
        with path.open("rb") as handle:
            data = handle.read(remaining + 1)
        remaining -= len(data)
        if remaining < 0:
            raise RuntimeError("Worker source table exceeds its capacity")
        files[name] = data
    actual = content_hash(manifest["identity"], files)
    if actual != manifest["workerHash"]:
        raise RuntimeError("Worker content hash mismatch")
    return {"workerHash": actual, "identity": manifest["identity"], "protocolVersion": 1}


def installed_contract() -> dict:
    return artifact_contract(Path(__file__).resolve().parents[2])


def worker_lease():
    root = Path(__file__).resolve().parents[2]
    return _lease(root / "worker.lease", fcntl.LOCK_SH)


@contextlib.contextmanager
def _lease(path: Path, operation: int):
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "a+b") as handle:
        fcntl.flock(handle, operation)
        yield descriptor


def _lease_holders(path: Path) -> str:
    try:
        result = subprocess.run(["lsof", "-t", "--", str(path)], capture_output=True,
                                text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return "unavailable (lsof failed or timed out)"
    values = result.stdout.split()
    if result.returncode not in {0, 1} or len(result.stdout) > 4096 or any(not value.isascii() or not value.isdigit() for value in values):
        return "unavailable (lsof returned an invalid PID list)"
    if not values:
        return "unavailable (the holder exited during inspection)"
    return ", ".join(str(value) for value in sorted({int(value) for value in values}))


@contextlib.contextmanager
def _exclusive_worker_lease(path: Path):
    lease_path = path / "worker.lease"
    deadline = time.monotonic() + WORKER_LEASE_WAIT_SECONDS
    while True:
        with contextlib.ExitStack() as stack:
            try:
                descriptor = stack.enter_context(_lease(lease_path, fcntl.LOCK_EX | fcntl.LOCK_NB))
            except BlockingIOError as error:
                if time.monotonic() >= deadline:
                    holders = _lease_holders(lease_path)
                    raise RuntimeError(f"Worker lease did not become available within {WORKER_LEASE_WAIT_SECONDS}s; "
                                       f"holder PIDs: {holders}. Wait for the build or call processes to exit, then retry") from error
            else:
                yield descriptor
                return
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))


def _remove_worker(path: Path) -> None:
    with _exclusive_worker_lease(path):
        shutil.rmtree(path)


def _prune(root: Path, keep: set[str]) -> None:
    for path in root.iterdir():
        if not path.is_dir() or path.name in keep:
            continue
        if len(path.name) != 64 or any(character not in "0123456789abcdef" for character in path.name) or path.is_symlink():
            raise RuntimeError("Unknown worker cache entry; refusing to remove it")
        artifact_contract(path)
        _remove_worker(path)


def _configured_hash(root: Path) -> str | None:
    current = root.parent.parent / "localbin/remote-coder-gateway/current"
    if current.is_symlink():
        path = current.resolve() / "pair.json"
        with path.open("rb") as handle:
            data = handle.read(4097)
        if len(data) > 4096:
            raise RuntimeError("Gateway pair identity exceeds its capacity")
        return json.loads(data)["workerHash"]
    binary = current.parent / "remote-coder-codex-gateway"
    if not binary.exists() and not binary.is_symlink():
        return None
    data = subprocess.check_output([str(binary), "--version"], timeout=5)
    if len(data) > 4096:
        raise RuntimeError("Gateway worker identity exceeds its capacity")
    return json.loads(data).get("workerHash")


def _save_json(path: Path, value: dict) -> None:
    owner = _process_owner(os.getpid())
    if owner is None:
        raise RuntimeError("Worker metadata owner exited")
    temporary = path.with_name(f"{path.name}.{owner['pid']}.{owner['birth']}.{uuid.uuid4()}")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(value, handle)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(path)
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        temporary.unlink(missing_ok=True)


def _valid_origin(origin: str) -> bool:
    return isinstance(origin, str) and 0 < len(origin) <= 253 and all(
        character.isascii() and (character.isalnum() or character == "-") for character in origin)


def _references(root: Path, origin: str, previous: str | None) -> dict:
    if not _valid_origin(origin):
        raise RuntimeError("Worker deployment requires a valid originating hostname")
    path = root / "references.json"
    if path.exists():
        with path.open("rb") as handle:
            data = handle.read(16385)
        if len(data) > 16384:
            raise RuntimeError("Worker references exceed their capacity")
        references = json.loads(data)
        if not isinstance(references, dict) or len(references) > MAX_ORIGIN_HOSTS or not all(map(_valid_origin, references)):
            raise RuntimeError("Worker reference owners are invalid")
        _protected(references)
    else:
        references = {}
        local = socket.gethostname().split(".")[0]
        selected = _configured_hash(root)
        if selected is not None:
            references[local] = {"selected": selected, "pending": None, "generation": None}
    if origin not in references:
        if len(references) >= MAX_ORIGIN_HOSTS:
            raise RuntimeError("Worker reference owners exceed their capacity")
        references[origin] = {"selected": previous, "pending": None, "generation": None}
    return references


def _protected(references: dict) -> set[str]:
    hashes = set()
    for reference in references.values():
        values = [reference["selected"]]
        if reference["pending"] is not None:
            values.extend([reference["pending"]["hash"], reference["pending"]["rollback"]])
        for value in values:
            if value is not None:
                if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
                    raise RuntimeError("Worker reference hash is invalid")
                hashes.add(value)
    if len(hashes) > MAX_PROTECTED_WORKERS:
        raise RuntimeError("Finish the pending worker rollout before staging another artifact")
    return hashes


def _committed(references: dict) -> set[str | None]:
    hashes = {reference["selected"] for reference in references.values()}
    hashes.update(reference["pending"]["rollback"] for reference in references.values()
                  if reference["pending"] is not None)
    return hashes


def _ensure_cache(root: Path) -> None:
    if root.is_symlink():
        raise RuntimeError("Worker cache cannot be a link")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)


def _process_owner(pid: int) -> dict | None:
    if pid <= 0:
        raise RuntimeError("Worker staging owner PID is invalid")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    output = subprocess.check_output(["ps", "-p", str(pid), "-o", "pid=,lstart=,comm="],
                                     text=True, env={**os.environ, "LC_ALL": "C", "TZ": "UTC"}, timeout=5)
    fields = output.split()
    if len(output) > 4096 or len(fields) < 6 or fields[0] != str(pid):
        raise RuntimeError("Worker staging process identity is unavailable")
    birth = hashlib.sha256(" ".join(fields[1:6]).encode()).hexdigest()
    return {"pid": pid, "birth": birth}


def _owner_alive(owner: dict) -> bool:
    if set(owner) != {"pid", "birth"} or not isinstance(owner["pid"], int) or not isinstance(owner["birth"], str):
        raise RuntimeError("Worker staging owner is invalid")
    if len(owner["birth"]) != 64 or any(c not in "0123456789abcdef" for c in owner["birth"]):
        raise RuntimeError("Worker staging owner birth identity is invalid")
    return _process_owner(owner["pid"]) == owner


def _clear_build(root: Path) -> None:
    (root / "worker-build.json").unlink(missing_ok=True)
    descriptor = os.open(root, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _recover_build(root: Path, references: dict) -> None:
    temporary = []
    for path in root.iterdir():
        for prefix in ["references.json.", "worker-build.json."]:
            if path.name.startswith(prefix):
                pid, birth, unique = path.name.removeprefix(prefix).split(".")
                if str(uuid.UUID(unique)) != unique or path.is_symlink() or not path.is_file():
                    raise RuntimeError("Unknown worker metadata staging entry")
                if _owner_alive({"pid": int(pid), "birth": birth}):
                    raise RuntimeError("A live process owns worker metadata staging")
                temporary.append(path)
                if len(temporary) > 64:
                    raise RuntimeError("Worker metadata staging exceeds its capacity")
    for path in temporary:
        path.unlink()
    claim = root / "worker-build.json"
    if not claim.exists():
        return
    with claim.open("rb") as handle:
        data = handle.read(65537)
    if len(data) > 65536:
        raise RuntimeError("Worker build claim exceeds its capacity")
    ownership = json.loads(data)
    if _owner_alive(ownership["owner"]):
        raise RuntimeError("A live process owns the pending worker build")
    manifest = ownership["manifest"]
    worker_hash = manifest["workerHash"]
    if not isinstance(worker_hash, str) or len(worker_hash) != 64 or any(c not in "0123456789abcdef" for c in worker_hash):
        raise RuntimeError("Worker build ownership hash is invalid")
    destination = root / worker_hash
    if destination.is_symlink():
        raise RuntimeError("Worker artifact cannot be a link")
    if worker_hash in _committed(references):
        contract = artifact_contract(destination)
        if contract != {"workerHash": worker_hash, "identity": manifest["identity"], "protocolVersion": 1}:
            raise RuntimeError("Referenced worker build has an invalid contract")
    elif destination.exists():
        _remove_worker(destination)
    _clear_build(root)


def finish_reference(request: dict, root: Path) -> None:
    _ensure_cache(root)
    with _lease(root / "install.lock", fcntl.LOCK_EX):
        references = _references(root, request["originHost"], request["sourceHash"])
        _protected(references)
        reference = references[request["originHost"]]
        if reference["generation"] != request["reservation"]:
            if reference["pending"] is None and reference["selected"] == request["selectedHash"] == request["sourceHash"]:
                _save_json(root / "references.json", references)
                return
            raise RuntimeError("Worker activation acknowledgement is stale")
        if reference["pending"] is not None:
            pending = reference["pending"]
            if pending != {"hash": request["targetHash"], "rollback": request["sourceHash"]}:
                raise RuntimeError("Worker acknowledgement does not match its reserved intent")
            if request["selectedHash"] not in {pending["hash"], pending["rollback"]}:
                raise RuntimeError("Worker acknowledgement does not match its reserved selection")
            reference["selected"] = request["selectedHash"]
            reference["pending"] = None
            _save_json(root / "references.json", references)
        elif reference["selected"] != request["selectedHash"]:
            raise RuntimeError("Worker acknowledgement conflicts with the settled selection")


def install(bundle: dict, root: Path) -> dict:
    files = {name: base64.b64decode(data, validate=True) for name, data in bundle["files"].items()}
    expected = bundle["workerHash"]
    if content_hash(bundle["identity"], files) != expected:
        raise RuntimeError("Worker content hash mismatch")
    origin = bundle["originHost"]
    if not _valid_origin(origin):
        raise RuntimeError("Worker deployment requires a positively identified originating host")
    _ensure_cache(root)
    with _lease(root / "install.lock", fcntl.LOCK_EX):
        references = _references(root, origin, bundle["previousHash"])
        _recover_build(root, references)
        reference = references[origin]
        prior = dict(reference)
        if reference["pending"] is not None:
            if reference["pending"]["hash"] != expected or reference["pending"]["rollback"] != bundle["previousHash"]:
                raise RuntimeError("This origin has an unsettled worker activation")
        else:
            if reference["selected"] != bundle["previousHash"]:
                raise RuntimeError("Worker source selection changed before reservation")
            reference["generation"] = bundle["reservation"]
            reference["pending"] = {"hash": expected, "rollback": bundle["previousHash"]}
        protected = _protected(references)
        _save_json(root / "references.json", references)
        destination = root / expected
        if destination.is_symlink():
            raise RuntimeError("Worker artifact cannot be a link")
        manifest = {"workerHash": expected, "identity": bundle["identity"], "files": sorted(files)}
        if destination.exists() and not (destination / "worker-artifact.json").exists():
            with (destination / "worker-build.json").open("rb") as handle:
                claim_data = handle.read(65537)
            if len(claim_data) > 65536:
                raise RuntimeError("Worker build claim exceeds its capacity")
            claim = json.loads(claim_data)
            if claim != manifest or expected in _committed(references):
                raise RuntimeError("Incomplete worker artifact is referenced or has unknown ownership")
            _remove_worker(destination)
        created = not destination.exists()
        if not created:
            contract = artifact_contract(destination)
        else:
            if sum(path.is_dir() for path in root.iterdir()) > MAX_PROTECTED_WORKERS:
                raise RuntimeError("Worker cache has no bounded staging capacity")
            owner = _process_owner(os.getpid())
            if owner is None:
                raise RuntimeError("Worker build owner exited")
            _save_json(root / "worker-build.json", {"owner": owner, "manifest": manifest})
            try:
                destination.mkdir(mode=0o700)
                with _exclusive_worker_lease(destination) as lease_fd:
                    _save_json(destination / "worker-build.json", manifest)
                    for name, data in files.items():
                        path = destination / name
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(data)
                    (destination / "dev-tools/agent-call").chmod(0o755)
                    project = destination / "agent-calls"
                    base = ["uv", "sync", "--project", str(project), "--frozen", "--no-dev", "--group", "worker-build"]
                    for options in [["--no-install-local", "--no-build"], ["--no-build-isolation"]]:
                        result = subprocess.run(base + options, capture_output=True, text=True,
                                                timeout=240, pass_fds=(lease_fd,))
                        if result.returncode:
                            raise RuntimeError("Locked worker dependency sync failed: " + result.stderr[-512:])
                    (destination / "worker-build.json").replace(destination / "worker-artifact.json")
                    result = subprocess.run([str(destination / "dev-tools/agent-call"), "--worker-contract"],
                                            capture_output=True, text=True, check=True, timeout=30, pass_fds=(lease_fd,))
                    contract = json.loads(result.stdout)
            except BaseException:
                if destination.exists():
                    _remove_worker(destination)
                _clear_build(root)
                references[origin] = prior
                _save_json(root / "references.json", references)
                raise
        if not created:
            result = subprocess.run([str(destination / "dev-tools/agent-call"), "--worker-contract"],
                                    capture_output=True, text=True, check=True, timeout=30)
            contract = json.loads(result.stdout)
        if contract != {"workerHash": expected, "identity": bundle["identity"], "protocolVersion": 1}:
            if created:
                _remove_worker(destination)
                _clear_build(root)
            raise RuntimeError("Installed worker contract mismatch")
        try:
            keep = set(protected)
            candidates = sorted((p for p in root.iterdir() if p.is_dir()), key=lambda p: p.stat().st_mtime, reverse=True)
            for candidate in candidates:
                if len(keep) < 2:
                    keep.add(candidate.name)
            _prune(root, keep)
        except BaseException:
            if created:
                _remove_worker(destination)
                _clear_build(root)
            raise
        if created:
            with _exclusive_worker_lease(destination):
                _clear_build(root)
        return contract | {"workerPath": str(destination / "dev-tools/agent-call"), "reservation": reference["generation"]}


def main() -> None:
    data = sys.stdin.buffer.read(8 * 1024 * 1024 + 1)
    if len(data) > 8 * 1024 * 1024:
        raise RuntimeError("Worker installation input exceeds its capacity")
    request = json.loads(data)
    root = Path.home() / ".remote-coder/call-workers"
    if request.get("operation") == "finish":
        finish_reference(request, root)
        print("{}")
    else:
        print(json.dumps(install(request, root)))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error)[:1024], file=sys.stderr)
        raise SystemExit(1) from None
