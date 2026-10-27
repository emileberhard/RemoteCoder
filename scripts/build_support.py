"""Shared build admission, cancellation, and timing ownership."""

import argparse
import fcntl
import hashlib
import json
import math
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass
from pathlib import Path

from job_power import job_sleep_assertion
from process_group import (
    audit_alive,
    boot_identity,
    group_has_live_members,
    own_identity,
    suspended_processes,
    terminate_group,
    terminate_process,
)

BUILD_ENV_NAMES = frozenset(
    (
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "PATH",
        "TMPDIR",
        "TMP",
        "TEMP",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "LC_MESSAGES",
        "TERM",
        "CARGO_HOME",
        "RUSTUP_HOME",
        "RUSTUP_TOOLCHAIN",
        "RUSTC_WRAPPER",
        "SCCACHE_DIR",
        "SCCACHE_CACHE_SIZE",
        "COMPILATION_CACHE_ENABLE_CACHING_DEFAULT",
        "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS",
        "SWIFT_ENABLE_PREFIX_MAPPING",
        "SWIFT_ENABLE_PROJECT_PREFIX_MAPPING",
        "CompilationCachingCASPath",
        "CompilationCachingDiskSizeLimit",
        "EMIL_BUILD_JOBS",
        "CARGO_BUILD_JOBS",
        "RUST_TEST_THREADS",
        "CI",
        "DEVELOPER_DIR",
        "CARGO_TARGET_DIR",
        "CODE_SIGN_IDENTITY",
        "CODE_SIGN_STYLE",
        "DEVELOPMENT_TEAM",
        "PROVISIONING_PROFILE",
        "PROVISIONING_PROFILE_SPECIFIER",
        "RC_XCODE_DEVELOPER_DIR",
        "RC_MAINTAINER_CONFIG",
        "RC_DERIVED_DATA",
        "RC_SWIFT_BUILD_PATH",
        "RC_BUILD_STAGES",
        "RC_RELEASE_VERSION",
        "RC_SOURCE_COMMIT",
        "RC_SOURCE_MODIFIED",
        "RC_BUILD_PROVENANCE",
        "RC_COMPILATION_OWNER",
        "RC_INSTALL_SOURCE_LEASED",
        "RC_IOS_DEVICE_VARIANT_SET",
        "RC_DEPLOY_LOG_DIR",
        "RC_IOS_BUILD_LOG",
        "RC_CLAUDE_MIGRATION_FIXTURE_HOME",
        "RC_LIVE_GATEWAY",
        "RC_IOS_SIMULATOR",
        "RC_FORCE_CHECKS",
        "RC_FORCE_GENERATE",
    )
)


def build_environment(
    kind: str, inherited: dict[str, str], run: Path
) -> dict[str, str]:
    names = BUILD_ENV_NAMES
    if kind == "ios-install":
        names |= frozenset(("REMOTE_CODER_GOOGLE_MAPS_API_KEY", "GOOGLE_MAPS_IOS_API_KEY", "APP_STORE_CONNECT_KEY_ID", "APP_STORE_CONNECT_ISSUER_ID", "APP_STORE_CONNECT_KEY_PATH"))
    environment = {
        key: value for key, value in inherited.items() if key in names
    }
    # zsh reads .zshenv even for noninteractive children. Bash's BASH_ENV and
    # POSIX ENV are not admitted by the allowlist.
    environment["ZDOTDIR"] = tempfile.mkdtemp(prefix="empty-shell-", dir=run)
    return environment


def canonical_path(path: Path) -> Path:
    path = path.resolve()
    if sys.platform != "darwin":
        return path
    parent = path
    missing = []
    while True:
        try:
            parent.stat()
            break
        except FileNotFoundError:
            missing.append(parent.name)
            parent = parent.parent
    descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        actual = fcntl.fcntl(descriptor, fcntl.F_GETPATH, b"\0" * 1024)
        return Path(os.fsdecode(actual.split(b"\0", 1)[0])).joinpath(*reversed(missing))
    finally:
        os.close(descriptor)


def cache_root() -> Path:
    return canonical_path(Path.home() / "Library/Caches/RemoteCoder-Build")


def source_sync_command(arguments: list[str]) -> list[str]:
    return ["rsync", "-a", "--checksum", "--no-times", *arguments]


def source_lease_path(root: Path) -> Path:
    identity = hashlib.sha256(str(canonical_path(root)).encode()).hexdigest()[:16]
    return cache_root() / "local-installs" / f"{identity}.lock"


def device_lease_path(device: str) -> Path:
    return (
        cache_root()
        / "device-locks"
        / (hashlib.sha256(device.encode()).hexdigest() + ".lock")
    )


def atomic_json(path: Path, value):
    descriptor, name = tempfile.mkstemp(dir=path.parent, prefix="." + path.name + ".")
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


MIN_BUILD_FREE_BYTES = 15 * 1024**3
MAX_MEASUREMENT_SECONDS = 1800


def require_build_space(path: Path):
    free = shutil.disk_usage(path).free
    if free < MIN_BUILD_FREE_BYTES:
        raise ValueError(
            f"Build volume has {free / 1024**3:.1f} GiB free; at least 15 GiB is required. Preserve active caches and reclaim owned artifacts before retrying."
        )


@contextmanager
def file_lease(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as lease:
        while True:
            try:
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                reclaim_expired_measurements()
                time.sleep(0.05)
        yield lease.fileno()
        fcntl.flock(lease, fcntl.LOCK_UN)


def reclaim_expired_measurements():
    directory = cache_root() / "capacity"
    for path in directory.glob("measurement-*.json"):
        try:
            snapshot = json.loads(path.read_text())
        except FileNotFoundError:
            continue
        with _record_mutex(path).open("a") as mutex:
            try:
                fcntl.flock(mutex, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                if (
                    snapshot["boot"] == boot_identity()
                    and time.monotonic() >= snapshot["deadline"]
                ):
                    actors = _measurement_actors(path, snapshot)
                    with suspended_processes(
                        [actor for actor in actors if actor is not None]
                    ):
                        try:
                            current = json.loads(path.read_text())
                        except FileNotFoundError:
                            continue
                        if time.monotonic() >= current["deadline"]:
                            _terminate_measurement(path, current)
                continue
            try:
                record = json.loads(path.read_text())
            except FileNotFoundError:
                continue
            deadline = record["deadline"]
            if not isinstance(deadline, (int, float)) or not math.isfinite(deadline):
                raise ValueError(f"Invalid measurement deadline: {path}")
            if record["boot"] != boot_identity():
                _remove_measurement_record(path)
                continue
            if time.monotonic() < deadline:
                continue
            _terminate_measurement(path, record)
            if any(
                record[actor] is not None and record[actor]["pid"] == os.getpid()
                for actor in ("owner", "guard", "command")
            ):
                continue
            _remove_measurement_record(path)


def measurement_actor_path(path: Path, actor: str) -> Path:
    return path.with_suffix("." + actor)


def _actor_record(path: Path, actor: str) -> dict | None:
    try:
        return json.loads(measurement_actor_path(path, actor).read_text())
    except FileNotFoundError:
        return None


def _terminate_measurement(path: Path, record: dict):
    guard, owner, command = _measurement_actors(path, record)
    for holder in (guard, owner):
        if holder is not None and holder["pid"] != os.getpid():
            terminate_process(holder)
    if command is not None and command["pid"] != os.getpid():
        terminate_group(command, 0)


def _measurement_actors(path: Path, record: dict) -> tuple:
    return tuple(
        registration["identity"]
        if (registration := _actor_record(path, actor)) is not None
        else record[actor]
        for actor in ("guard", "owner", "command")
    )


def _record_mutex(path: Path) -> Path:
    return path.parent / "state.lock"


def _remove_measurement_record(path: Path):
    path.with_suffix(".lock").unlink(missing_ok=True)
    path.unlink(missing_ok=True)
    for actor in ("guard", "command"):
        measurement_actor_path(path, actor).unlink(missing_ok=True)


@contextmanager
def measurement_record_lease(path: Path):
    with file_lease(_record_mutex(path)):
        yield


@contextmanager
def build_capacity(background: bool = False):
    """Bulk/simulator work uses slot 1, leaving slot 0 for interactive work."""
    directory = cache_root() / "capacity"
    directory.mkdir(parents=True, exist_ok=True)
    while True:
        reclaim_expired_measurements()
        lease = None
        with file_lease(directory / "admission.lock"):
            pending = False
            for request in directory.glob("measurement-*.lock"):
                try:
                    with request.open("r") as intent:
                        fcntl.flock(intent, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        record_path = request.with_suffix(".json")
                        with _record_mutex(record_path).open("a") as mutex:
                            fcntl.flock(mutex, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            if record_path.exists():
                                record = json.loads(record_path.read_text())
                                actors = [record["guard"], record["command"]]
                                actors.extend(
                                    registration["identity"]
                                    for actor in ("guard", "command")
                                    if (
                                        registration := _actor_record(
                                            record_path, actor
                                        )
                                    )
                                    is not None
                                )
                                if any(
                                    actor is not None and audit_alive(actor)
                                    for actor in actors
                                ):
                                    pending = True
                                    continue
                                _remove_measurement_record(record_path)
                            request.unlink(missing_ok=True)
                except FileNotFoundError:
                    continue
                except BlockingIOError:
                    pending = True
            for index in () if pending else (1,) if background else (0, 1):
                candidate = (directory / f"{index}.lock").open("a")
                try:
                    fcntl.flock(candidate, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    candidate.close()
                    continue
                lease = candidate
                break
        if lease is not None:
            try:
                yield lease.fileno()
                fcntl.flock(lease, fcntl.LOCK_UN)
            finally:
                lease.close()
            return
        time.sleep(0.2)


@contextmanager
def _lease_before(path: Path, deadline: float, cancellation):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as lease:
        while True:
            if cancellation.is_set():
                raise SystemExit(128 + signal.SIGHUP)
            try:
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                reclaim_expired_measurements()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(
                        f"Measurement reservation timed out waiting for {path}"
                    )
                time.sleep(min(0.05, remaining))
            else:
                yield lease.fileno()
                return


@contextmanager
def _measurement_request(directory: Path, deadline: float):
    descriptor, name = tempfile.mkstemp(dir=directory, prefix=".measurement-")
    temporary = Path(name)
    request = directory / (temporary.name[1:] + ".lock")
    record = request.with_suffix(".json")
    try:
        with os.fdopen(descriptor, "w") as intent:
            fcntl.flock(intent, fcntl.LOCK_EX)
            atomic_json(
                record,
                {
                    "owner": own_identity(),
                    "boot": boot_identity(),
                    "guard": None,
                    "command": None,
                    "deadline": deadline,
                },
            )
            temporary.replace(request)
            yield intent.fileno(), record
    finally:
        with measurement_record_lease(record):
            try:
                command = json.loads(record.read_text())["command"]
                preserve = command is not None and group_has_live_members(
                    command["pgid"]
                )
            except FileNotFoundError:
                preserve = False
            if not preserve:
                _remove_measurement_record(record)
        temporary.unlink(missing_ok=True)


@dataclass(frozen=True)
class _MeasurementCapacity:
    descriptors: tuple[int, ...]
    record: Path


@contextmanager
def measurement_capacity(source: Path, wait_seconds: float, cancellation):
    if (
        not math.isfinite(wait_seconds)
        or not 0 < wait_seconds <= MAX_MEASUREMENT_SECONDS
    ):
        raise ValueError(
            f"Measurement queue limit must be finite, positive, and at most {MAX_MEASUREMENT_SECONDS} seconds"
        )
    deadline = time.monotonic() + wait_seconds
    root = canonical_path(cache_root())
    directory = root / "capacity"
    directory.mkdir(parents=True, exist_ok=True)
    source = canonical_path(source)
    relative = (
        source.relative_to(root / "worktrees")
        if source.is_relative_to(root / "worktrees")
        else None
    )
    if relative is not None:
        if len(relative.parts) != 3 or relative.parts[1:] not in (
            ("ios", "repo"),
            ("gateway", "repo"),
        ):
            raise ValueError(
                f"Unsupported measurement source within the mutable mirror cache: {source}"
            )
        from build_cache import lease_path, touch_usage

        identity = relative.parts[0]
        mirror = root / "worktrees" / identity
        paths = [
            lease_path(root, "worktrees", identity),
            mirror / "ios/build.lock",
            mirror / "gateway/build.lock",
        ]
    else:
        paths = [source_lease_path(source)]
    with ExitStack() as ownership:
        descriptors = [
            ownership.enter_context(_lease_before(path, deadline, cancellation))
            for path in paths
        ]
        intent, record = ownership.enter_context(
            _measurement_request(directory, deadline)
        )
        descriptors.append(intent)
        descriptors.extend(
            ownership.enter_context(
                _lease_before(directory / name, deadline, cancellation)
            )
            for name in ("admission.lock", "0.lock", "1.lock")
        )
        try:
            if relative is not None:
                touch_usage(root, "worktrees", identity)
            yield _MeasurementCapacity(tuple(descriptors), record)
        finally:
            if relative is not None:
                touch_usage(root, "worktrees", identity)


CLIENT_HEARTBEAT_SECONDS = 5
CLIENT_LOST_SECONDS = 20


@contextmanager
def connected_cancellation():
    with job_sleep_assertion():
        cancellation = threading.Event()
        reader, writer = os.pipe()

        def watch_client():
            try:
                while True:
                    ready, _, _ = select.select(
                        [sys.stdin, reader], [], [], CLIENT_LOST_SECONDS
                    )
                    if reader in ready:
                        return
                    if not ready or not os.read(sys.stdin.fileno(), 1):
                        cancellation.set()
                        return
            except OSError:
                cancellation.set()

        watcher = threading.Thread(target=watch_client)
        watcher.start()
        try:
            yield cancellation
        finally:
            os.write(writer, b".")
            watcher.join()
            os.close(writer)
            os.close(reader)


@job_sleep_assertion()
def run_connected(
    command: list[str],
    *,
    environment=None,
    lease_fds=(),
    cancellation=None,
    prepare=None,
) -> subprocess.CompletedProcess:
    cancel_reader, cancel_writer = os.pipe()
    cancelled = None

    def cancel(signum, _frame):
        nonlocal cancelled
        if cancelled is None:
            cancelled = signum
            os.write(cancel_writer, b".")

    previous = {
        sig: signal.signal(sig, cancel)
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    }
    process = None
    output = bytearray()
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            env=environment,
            pass_fds=lease_fds,
            start_new_session=True,
        )
        if prepare is not None:
            prepare(process)
        heartbeat_at = 0
        output_closed = False
        while cancelled is None:
            if (
                os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                is not None
            ):
                drain_until = time.monotonic() + 0.1
                while (
                    not output_closed
                    and time.monotonic() < drain_until
                    and select.select([process.stdout], [], [], 0)[0]
                ):
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    output.extend(chunk)
                break
            if cancellation is not None and cancellation.is_set():
                cancel(signal.SIGHUP, None)
                break
            if time.monotonic() >= heartbeat_at:
                try:
                    process.stdin.write(b".")
                    process.stdin.flush()
                except BrokenPipeError:
                    pass
                heartbeat_at = time.monotonic() + CLIENT_HEARTBEAT_SECONDS
            ready, _, _ = select.select(
                [cancel_reader] if output_closed else [process.stdout, cancel_reader],
                [],
                [],
                0.05,
            )
            if cancelled is not None:
                break
            if process.stdout in ready:
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    output_closed = True
                else:
                    output.extend(chunk)
    finally:
        try:
            if process is not None:
                try:
                    process.stdin.close()
                except BrokenPipeError:
                    pass
                try:
                    process.wait(timeout=35)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                finally:
                    process.stdout.close()
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
            os.close(cancel_writer)
            os.close(cancel_reader)
    if cancelled is not None:
        raise SystemExit(128 + cancelled)
    return subprocess.CompletedProcess(command, process.returncode, output.decode())


class Timings:
    def __init__(self, run: Path):
        self.run = run
        self.started = time.monotonic()
        self.durations = {}

    @contextmanager
    def phase(self, name: str):
        start = time.monotonic()
        self.publish(name)
        try:
            yield
        finally:
            self.durations[name] = round(time.monotonic() - start, 3)
            self.publish(None)

    def publish(self, current):
        value = {
            "phase": current,
            "updatedAt": time.time(),
            "elapsedSeconds": round(time.monotonic() - self.started, 3),
            "phasesSeconds": self.durations,
        }
        temporary = self.run / "progress.tmp"
        temporary.write_text(json.dumps(value, indent=2) + "\n")
        temporary.replace(self.run / "progress.json")


def _group_has_live_members(group):
    return group_has_live_members(group)


def _signal_owned_group(group, signum):
    try:
        os.killpg(group, signum)
    except ProcessLookupError:
        pass
    except PermissionError:
        if _group_has_live_members(group):
            raise


@job_sleep_assertion()
def run_owned(
    command,
    cwd,
    environment,
    output,
    lease_fds=(),
    cancellation=None,
    termination_grace_seconds=15,
    timeout_seconds=None,
    error_output=subprocess.STDOUT,
    stdin=None,
):
    if timeout_seconds is not None and (
        not math.isfinite(timeout_seconds) or timeout_seconds <= 0
    ):
        raise ValueError("Owned command timeout must be finite and positive")
    started = time.monotonic()
    cancelled = None
    termination_sent = False
    kill_sent = False
    timed_out = False
    completed_status = None
    child = None
    reaped = False

    def stop(signum, _frame):
        nonlocal cancelled
        if cancelled is None:
            cancelled = (signum, time.monotonic())
        # Never signal/reap from the handler: the interrupted wait may have
        # just reaped its child. The owner loop only signals an unreaped leader.
        # Never call Popen.wait from its signal handler: the interrupted wait
        # may hold Python's waitpid lock. The normal owner loop reaps the child.

    previous = {
        s: signal.signal(s, stop)
        for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    }
    try:
        child = subprocess.Popen(
            command,
            cwd=cwd,
            env=environment,
            stdin=stdin,
            stdout=output,
            stderr=error_output,
            start_new_session=True,
            pass_fds=lease_fds,
        )
        while True:
            if cancellation is not None and cancellation.is_set() and not cancelled:
                stop(signal.SIGHUP, None)
            exited = os.waitid(
                os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT
            )
            if (
                not cancelled
                and exited is None
                and timeout_seconds is not None
                and time.monotonic() - started >= timeout_seconds
            ):
                timed_out = True
                stop(signal.SIGTERM, None)
            if (
                not cancelled
                and exited is not None
                and _group_has_live_members(child.pid)
            ):
                completed_status = (
                    exited.si_status
                    if exited.si_code == os.CLD_EXITED
                    else 128 + exited.si_status
                    if timeout_seconds is not None
                    else -exited.si_status
                )
                stop(signal.SIGTERM, None)
            if cancelled:
                if exited is not None and not _group_has_live_members(child.pid):
                    child.wait()
                    reaped = True
                    if completed_status is not None:
                        return completed_status
                    if timed_out:
                        raise subprocess.TimeoutExpired(command, timeout_seconds)
                    raise SystemExit(128 + cancelled[0])
                if not termination_sent:
                    _signal_owned_group(child.pid, signal.SIGTERM)
                    termination_sent = True
                if (
                    not kill_sent
                    and time.monotonic() - cancelled[1] >= termination_grace_seconds
                ):
                    _signal_owned_group(child.pid, signal.SIGKILL)
                    kill_sent = True
            elif exited is not None:
                status = child.wait()
                reaped = True
                return (
                    128 - status
                    if timeout_seconds is not None and status < 0
                    else status
                )
            time.sleep(0.05)

    finally:
        try:
            if child is not None and not reaped:
                if _group_has_live_members(child.pid):
                    _signal_owned_group(child.pid, signal.SIGKILL)
                while _group_has_live_members(child.pid):
                    time.sleep(0.05)
                child.wait()
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--background", action="store_true")
    parser.add_argument("--lease", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required")
    # Acquire mutable-input ownership BEFORE consuming scarce compiler capacity.
    with job_sleep_assertion(), file_lease(args.lease) as lease, build_capacity(args.background) as capacity:
        require_build_space(args.lease.parent)
        return run_owned(command, Path.cwd(), os.environ, sys.stdout, (lease, capacity))


if __name__ == "__main__":
    raise SystemExit(main())
