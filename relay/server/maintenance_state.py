import fcntl
import json
import os
import stat
import subprocess
import tempfile
import time
import uuid
from contextlib import ExitStack, contextmanager
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

DIRECTORY = Path("/var/lib/remote-coder-relay")
MARKER = DIRECTORY / "maintenance.json"
BOOT_ID = Path("/proc/sys/kernel/random/boot_id")
DPKG_LOCKS = (Path("/var/lib/dpkg/lock-frontend"), Path("/var/lib/dpkg/lock"))
FIREWALL = Path("/usr/local/lib/remote-coder-relay/maintenance-firewall.nft")


def check_directory():
    if os.geteuid() != 0:
        raise RuntimeError("relay maintenance requires root")
    directory = DIRECTORY.lstat()
    if (
        not stat.S_ISDIR(directory.st_mode)
        or directory.st_uid != 0
        or directory.st_mode & 0o077
    ):
        raise RuntimeError("invalid relay maintenance directory")


@contextmanager
def owner_locks():
    check_directory()
    with ExitStack() as stack:
        for name in ("provision.lock", "admission.lock"):
            lock = stack.enter_context((DIRECTORY / name).open("a"))
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise RuntimeError(f"relay {name} is already held") from error
        yield


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate marker field")
        result[key] = value
    return result


def read_marker():
    marker_stat = MARKER.lstat()
    if (
        not stat.S_ISREG(marker_stat.st_mode)
        or marker_stat.st_uid != 0
        or marker_stat.st_mode & 0o077
    ):
        raise ValueError("invalid marker ownership or permissions")
    marker = json.loads(MARKER.read_text(), object_pairs_hook=unique_fields)
    if (
        not isinstance(marker, dict)
        or set(marker)
        != {"schema", "phase", "boot_id", "operation_id", "master", "worker"}
        or type(marker.get("schema")) is not int
        or marker["schema"] != 1
    ):
        raise ValueError("unsupported marker schema")
    if marker["phase"] not in ("preparing", "committed"):
        raise ValueError("unknown maintenance phase")
    for name in ("boot_id", "operation_id"):
        if not isinstance(marker[name], str):
            raise TypeError("invalid maintenance identity")
        marker[name] = str(uuid.UUID(marker[name]))
    for name in ("master", "worker"):
        identity = marker[name]
        if (
            not isinstance(identity, dict)
            or set(identity) != {"pid", "start_ticks"}
            or type(identity["pid"]) is not int
            or identity["pid"] <= 0
            or type(identity["start_ticks"]) is not int
            or identity["start_ticks"] < 0
        ):
            raise ValueError("invalid maintenance process identity")
    if marker["master"]["pid"] == marker["worker"]["pid"]:
        raise ValueError("maintenance process identities are not distinct")
    return marker


def boot_id():
    return str(uuid.UUID(BOOT_ID.read_text().strip()))


def worker_identity(pid):
    if type(pid) is not int or pid <= 0:
        raise ValueError("invalid process identity")
    contents = Path(f"/proc/{pid}/stat").read_text()
    _, separator, fields = contents.rpartition(")")
    if not separator:
        raise ValueError("invalid process stat")
    start_ticks = int(fields.split()[19])
    return {"pid": pid, "start_ticks": start_ticks}


def _reboot_window():
    current = datetime.now(ZoneInfo("Europe/Stockholm"))
    return current.hour == 6 and current.minute == 33


def _write_marker(marker):
    fd, temporary = tempfile.mkstemp(
        prefix=".maintenance-", suffix=".tmp", dir=DIRECTORY
    )
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(marker, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, MARKER)
        directory_fd = os.open(DIRECTORY, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _remove_stale_temporaries():
    removed = False
    for path in DIRECTORY.glob(".maintenance-*.tmp"):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
            raise RuntimeError("invalid relay maintenance temporary file")
        path.unlink()
        removed = True
    if removed:
        directory_fd = os.open(DIRECTORY, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)


def remove_fence_and_marker():
    try:
        result = subprocess.run(
            ["/usr/sbin/nft", "-f", "-"],
            input="destroy table inet remote_coder_relay_maintenance\n",
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(
            "reopening relay admission timed out; keep the marker"
        ) from error
    if result.returncode:
        raise RuntimeError("could not reopen relay admission; keep the marker")
    MARKER.unlink()
    directory_fd = os.open(DIRECTORY, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


class RelayTransaction:
    def __init__(self):
        self._locks = None
        self._operation_id = None
        self._fenced = False
        self._drained = False

    def __enter__(self):
        if self._locks is not None:
            raise RuntimeError("relay transaction is already active")
        self._locks = ExitStack()
        try:
            self._locks.enter_context(owner_locks())
            for path in DPKG_LOCKS:
                lock = self._locks.enter_context(path.open("r+"))
                lock_stat = os.fstat(lock.fileno())
                if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_uid != 0:
                    raise RuntimeError(f"invalid package lock {path}")
                try:
                    fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as error:
                    raise RuntimeError(
                        f"package lock {path} is already held"
                    ) from error
            _remove_stale_temporaries()
            return self
        except BaseException:
            self._locks.close()
            self._locks = None
            raise

    def __exit__(self, *exception):
        self._locks.close()
        self._locks = None
        self._operation_id = None
        self._fenced = False
        self._drained = False

    def prepare(self, master_pid, worker_pid):
        if self._locks is None:
            raise RuntimeError("relay transaction is not active")
        try:
            MARKER.lstat()
        except FileNotFoundError:
            pass
        else:
            raise RuntimeError("relay maintenance marker already exists")
        if master_pid == worker_pid:
            raise ValueError("master and worker must be distinct")
        marker = {
            "schema": 1,
            "phase": "preparing",
            "boot_id": boot_id(),
            "operation_id": str(uuid.uuid4()),
            "master": worker_identity(master_pid),
            "worker": worker_identity(worker_pid),
        }
        _write_marker(marker)
        self._operation_id = marker["operation_id"]

    def prepare_idle(self, candidate_timeout, drain_timeout):
        from maintenance_drain import haproxy_identity, wait_for_candidate

        if self._locks is None or self._operation_id is not None:
            raise RuntimeError("relay transaction is not ready for preparation")
        identity = haproxy_identity()
        wait_for_candidate(identity, candidate_timeout)
        self.prepare(identity["master"]["pid"], identity["worker"]["pid"])
        try:
            marker = self._preparing_marker()
            if any(marker[name] != identity[name] for name in ("master", "worker")):
                raise RuntimeError("HAProxy generation changed before admission closed")
        except BaseException:
            self.abort()
            raise
        self.fence()
        self.drain(drain_timeout)

    def check_new_boot_prerequisites(self, timeout_seconds):
        from maintenance_drain import verify_local_boot_prerequisites

        if self._locks is None or self._operation_id is not None:
            raise RuntimeError("relay transaction is not ready for recovery")
        marker = read_marker()
        current_boot = boot_id()
        if marker["boot_id"] == current_boot:
            raise RuntimeError("relay has not booted since maintenance began")
        identity = verify_local_boot_prerequisites(timeout_seconds)
        if boot_id() != current_boot:
            raise RuntimeError("relay boot identity changed during verification")
        return identity

    def reopen_after_new_boot(self, timeout_seconds):
        from maintenance_drain import fence_is_configured

        if self._locks is None or self._operation_id is not None:
            raise RuntimeError("relay transaction is not ready for recovery")
        marker = read_marker()
        identity = self.check_new_boot_prerequisites(timeout_seconds)
        if read_marker() != marker:
            raise RuntimeError("relay maintenance marker changed during verification")
        fence_is_configured(time.monotonic() + 5)
        remove_fence_and_marker()
        return identity

    def commit(self):
        marker = self._preparing_marker()
        if not self._fenced:
            raise RuntimeError("relay admission has not been fenced")
        if not self._drained:
            raise RuntimeError("relay admission has not drained")
        for name in ("master", "worker"):
            if worker_identity(marker[name]["pid"]) != marker[name]:
                raise RuntimeError("relay worker identity changed")
        marker["phase"] = "committed"
        _write_marker(marker)

    def enqueue_reboot(self):
        from maintenance_drain import snapshot

        marker = self._preparing_marker()
        if not self._drained:
            raise RuntimeError("relay admission has not drained")
        identity = {name: marker[name] for name in ("master", "worker")}
        try:
            if not _reboot_window():
                raise RuntimeError("relay reboot window is not open")
            if snapshot(identity, time.monotonic() + 10):
                raise RuntimeError("relay has new or remaining connections")
            if not _reboot_window():
                raise RuntimeError("relay reboot window elapsed")
        except BaseException:
            self.abort()
            raise
        self.commit()
        if not _reboot_window():
            raise RuntimeError(
                "relay reboot window elapsed after commit; keep the fence"
            )
        try:
            result = subprocess.run(
                ["/usr/bin/systemctl", "reboot"],
                capture_output=True,
                timeout=15,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise RuntimeError("reboot request is uncertain; keep the fence") from error
        if result.returncode:
            raise RuntimeError("reboot request failed or is uncertain; keep the fence")

    def _preparing_marker(self):
        if self._locks is None or self._operation_id is None:
            raise RuntimeError("relay preparation is not active")
        marker = read_marker()
        if (
            marker["phase"] != "preparing"
            or marker["boot_id"] != boot_id()
            or marker.get("operation_id") != self._operation_id
        ):
            raise RuntimeError("relay preparation identity changed")
        return marker

    def fence(self):
        self._preparing_marker()
        if self._fenced:
            raise RuntimeError("relay admission is already fenced")
        try:
            result = subprocess.run(
                ["/usr/sbin/nft", "-f", str(FIREWALL)],
                capture_output=True,
                timeout=10,
                check=False,
            )
            if result.returncode:
                raise RuntimeError("could not fence relay admission")
        except BaseException:
            self.abort()
            raise
        self._fenced = True

    def drain(self, timeout_seconds):
        from maintenance_drain import wait_for_drain

        marker = self._preparing_marker()
        if not self._fenced or self._drained:
            raise RuntimeError("relay admission is not awaiting drain")
        identity = {name: marker[name] for name in ("master", "worker")}
        try:
            wait_for_drain(identity, timeout_seconds)
        except BaseException:
            self.abort()
            raise
        self._drained = True

    def abort(self):
        self._preparing_marker()
        remove_fence_and_marker()
        self._operation_id = None
        self._fenced = False
        self._drained = False
