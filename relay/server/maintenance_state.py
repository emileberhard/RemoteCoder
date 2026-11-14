import fcntl
import json
import os
import stat
import tempfile
import uuid
from contextlib import ExitStack, contextmanager
from pathlib import Path

DIRECTORY = Path("/var/lib/remote-coder-relay")
MARKER = DIRECTORY / "maintenance.json"
BOOT_ID = Path("/proc/sys/kernel/random/boot_id")
DPKG_LOCKS = (Path("/var/lib/dpkg/lock-frontend"), Path("/var/lib/dpkg/lock"))


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
        or type(marker.get("schema")) is not int
        or marker["schema"] != 1
    ):
        raise ValueError("unsupported marker schema")
    if marker["phase"] not in ("preparing", "committed"):
        raise ValueError("unknown maintenance phase")
    marker["boot_id"] = str(uuid.UUID(marker["boot_id"]))
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


class RelayTransaction:
    def __init__(self):
        self._locks = None
        self._operation_id = None

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

    def commit(self):
        if self._locks is None or self._operation_id is None:
            raise RuntimeError("relay preparation is not active")
        marker = read_marker()
        if (
            marker["phase"] != "preparing"
            or marker["boot_id"] != boot_id()
            or marker.get("operation_id") != self._operation_id
        ):
            raise RuntimeError("relay preparation identity changed")
        for name in ("master", "worker"):
            if worker_identity(marker[name]["pid"]) != marker[name]:
                raise RuntimeError("relay worker identity changed")
        marker["phase"] = "committed"
        _write_marker(marker)
