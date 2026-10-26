import ctypes
import fcntl
import json
import os
import select
import shlex
import signal
import subprocess
import sys
import threading
import time
from contextlib import ExitStack, contextmanager
from contextvars import ContextVar
from functools import cache
from pathlib import Path

_sleep_owner: ContextVar[int | None] = ContextVar("owned_job_sleep_pid", default=None)


@cache
def _sleep_libraries():
    core = ctypes.CDLL(
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
    )
    power = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
    core.CFStringCreateWithCString.argtypes = [
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_uint32,
    ]
    core.CFStringCreateWithCString.restype = ctypes.c_void_p
    core.CFRelease.argtypes = [ctypes.c_void_p]
    core.CFRelease.restype = None
    power.IOPMAssertionCreateWithName.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint32),
    ]
    power.IOPMAssertionCreateWithName.restype = ctypes.c_int32
    power.IOPMAssertionRelease.argtypes = [ctypes.c_uint32]
    power.IOPMAssertionRelease.restype = ctypes.c_int32
    return core, power


@contextmanager
def job_sleep_assertion():
    if sys.platform != "darwin" or _sleep_owner.get() == os.getpid():
        yield
        return
    core, power = _sleep_libraries()
    with ExitStack() as ownership:
        strings = []
        for value in [b"PreventUserIdleSystemSleep", b"RemoteCoder owned job"]:
            reference = core.CFStringCreateWithCString(None, value, 0x08000100)
            if not reference:
                raise RuntimeError("Cannot allocate the owned job sleep assertion")
            ownership.callback(core.CFRelease, reference)
            strings.append(reference)
        assertion = ctypes.c_uint32()
        status = power.IOPMAssertionCreateWithName(
            strings[0], 255, strings[1], ctypes.byref(assertion)
        )
        if status != 0:
            raise RuntimeError(
                f"Cannot prevent idle sleep for the owned job: IOKit status {status}"
            )

        def release():
            status = power.IOPMAssertionRelease(assertion)
            if status != 0:
                raise RuntimeError(
                    f"Cannot release the owned job sleep assertion: IOKit status {status}"
                )

        ownership.callback(release)
        token = _sleep_owner.set(os.getpid())
        ownership.callback(_sleep_owner.reset, token)
        yield


HEARTBEAT_SECONDS = 5
CLIENT_LOST_SECONDS = 20


def serve_host_job(lease_path: Path):
    stopped = False

    def stop(_signum, _frame):
        nonlocal stopped
        stopped = True

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, stop)
    with job_sleep_assertion():
        lease_path.parent.mkdir(parents=True, exist_ok=True)
        with lease_path.open("a") as lease:
            print(json.dumps({"pid": os.getpid()}), flush=True)
            last_heartbeat = time.monotonic()
            while not stopped:
                ready, _, _ = select.select([sys.stdin], [], [], 0.1)
                if ready:
                    if not os.read(sys.stdin.fileno(), 1):
                        break
                    last_heartbeat = time.monotonic()
                elif time.monotonic() - last_heartbeat >= CLIENT_LOST_SECONDS:
                    break
            fcntl.flock(lease, fcntl.LOCK_EX)


@contextmanager
def host_job_assertion(shell: list[str], lease_path: Path):
    command = shlex.join(["python3", "-c", _source, str(lease_path)])
    process = subprocess.Popen(
        [*shell, command],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        start_new_session=True,
    )
    input_stream = process.stdin
    output_stream = process.stdout
    assert input_stream is not None and output_stream is not None
    stopped = threading.Event()
    watcher = None

    def heartbeat():
        while not stopped.wait(HEARTBEAT_SECONDS):
            try:
                if process.poll() is not None:
                    raise BrokenPipeError("Build-host sleep owner exited")
                input_stream.write(b".")
                input_stream.flush()
            except (BrokenPipeError, OSError):
                if not stopped.is_set():
                    os.kill(os.getpid(), signal.SIGTERM)
                return

    def cancel(signum, _frame):
        raise SystemExit(128 + signum)

    previous = {
        sig: signal.signal(sig, cancel)
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    }
    try:
        if not select.select([output_stream], [], [], 15)[0]:
            raise RuntimeError(
                "Build-host sleep owner did not acknowledge acquisition within 15 seconds"
            )
        line = output_stream.readline()
        if not line:
            raise RuntimeError("Build-host sleep owner exited before acquisition")
        owner = json.loads(line)
        watcher = threading.Thread(target=heartbeat)
        watcher.start()
        yield owner["pid"]
    finally:
        stopped.set()
        if watcher is not None:
            watcher.join()
        try:
            try:
                input_stream.close()
            except BrokenPipeError:
                pass
            status = process.wait(timeout=60)
            if status != 0:
                raise RuntimeError(f"Build-host sleep owner failed with exit {status}")
        finally:
            output_stream.close()
            for sig, handler in previous.items():
                signal.signal(sig, handler)


if __name__ == "__main__":
    serve_host_job(Path(sys.argv[1]))
else:
    _source = Path(__file__).read_text()
