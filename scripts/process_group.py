import ctypes
import errno
import os
import signal
import subprocess
import time
from functools import cache
from contextlib import contextmanager
from pathlib import Path
from uuid import UUID


class _BSDInfo(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint32),
        ("status", ctypes.c_uint32),
        ("xstatus", ctypes.c_uint32),
        ("pid", ctypes.c_uint32),
        ("ppid", ctypes.c_uint32),
        ("uid", ctypes.c_uint32),
        ("gid", ctypes.c_uint32),
        ("ruid", ctypes.c_uint32),
        ("rgid", ctypes.c_uint32),
        ("svuid", ctypes.c_uint32),
        ("svgid", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("comm", ctypes.c_char * 16),
        ("name", ctypes.c_char * 32),
        ("nfiles", ctypes.c_uint32),
        ("pgid", ctypes.c_uint32),
        ("jobc", ctypes.c_uint32),
        ("tdev", ctypes.c_uint32),
        ("tpgid", ctypes.c_uint32),
        ("nice", ctypes.c_int32),
        ("start_seconds", ctypes.c_uint64),
        ("start_microseconds", ctypes.c_uint64),
    ]


class _UniqueInfo(ctypes.Structure):
    _fields_ = [
        ("uuid", ctypes.c_uint8 * 16),
        ("unique_id", ctypes.c_uint64),
        ("parent_unique_id", ctypes.c_uint64),
        ("pid_version", ctypes.c_int32),
        ("parent_pid_version", ctypes.c_int32),
        ("reserved", ctypes.c_uint64 * 2),
    ]


class _ProcessInfo(ctypes.Structure):
    _fields_ = [("bsd", _BSDInfo), ("unique", _UniqueInfo)]


_AuditToken = ctypes.c_uint32 * 8


@cache
def _libproc():
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    library.proc_pidinfo.restype = ctypes.c_int
    library.proc_signal_with_audittoken.argtypes = [
        ctypes.POINTER(_AuditToken),
        ctypes.c_int,
    ]
    library.proc_signal_with_audittoken.restype = ctypes.c_int
    library.proc_pidpath_audittoken.argtypes = [
        ctypes.POINTER(_AuditToken),
        ctypes.c_void_p,
        ctypes.c_uint32,
    ]
    library.proc_pidpath_audittoken.restype = ctypes.c_int
    return library


def own_identity() -> dict:
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    system.task_info.argtypes = [
        ctypes.c_uint32,
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint32),
    ]
    system.task_info.restype = ctypes.c_int
    token = _AuditToken()
    count = ctypes.c_uint32(8)
    result = system.task_info(
        ctypes.c_uint32.in_dll(system, "mach_task_self_").value,
        15,
        token,
        ctypes.byref(count),
    )
    if result or count.value != 8:
        raise OSError(result, "Cannot read own task audit token")
    identity = process_identity(os.getpid())
    if token[5] != identity["pid"] or token[7] != identity["pidVersion"]:
        raise ValueError("Task audit token and process identity disagree")
    return identity | {"auditToken": list(token)}


@cache
def boot_identity() -> str:
    value = subprocess.check_output(["sysctl", "-n", "kern.bootsessionuuid"], text=True)
    return str(UUID(value.strip()))


def process_identity(pid: int) -> dict | None:
    info = _ProcessInfo()
    size = _libproc().proc_pidinfo(pid, 18, 0, ctypes.byref(info), ctypes.sizeof(info))
    if not size:
        error = ctypes.get_errno()
        if error == errno.ESRCH:
            return None
        if error == errno.EPERM:
            rows = subprocess.check_output(["ps", "-axo", "pid=,stat="], text=True)
            if any(
                int(parts[0]) == pid and parts[1].startswith("Z")
                for line in rows.splitlines()
                if len(parts := line.split()) == 2
            ):
                return None
        raise OSError(error, "Cannot read process identity", pid)
    if size != ctypes.sizeof(info) or info.bsd.pid != pid:
        raise ValueError(f"Incomplete process identity for PID {pid}")
    bsd = info.bsd
    version = info.unique.pid_version & 0xFFFFFFFF
    return {
        "pid": pid,
        "ppid": bsd.ppid,
        "pgid": bsd.pgid,
        "state": bsd.status,
        "startedAtMicroseconds": bsd.start_seconds * 1_000_000 + bsd.start_microseconds,
        "pidVersion": version,
        "auditToken": [0, bsd.uid, bsd.gid, bsd.ruid, bsd.rgid, pid, 0, version],
    }


def same_process(left: dict | None, right: dict) -> bool:
    return left is not None and all(
        left[key] == right[key]
        for key in ("pid", "pgid", "startedAtMicroseconds", "pidVersion")
    )


def _token(identity: dict):
    token = _AuditToken(*identity["auditToken"])
    if token[5] != identity["pid"] or token[7] != identity["pidVersion"]:
        raise ValueError("Recorded audit token and process identity disagree")
    return token


def audit_path(identity: dict) -> Path | None:
    token = _token(identity)
    buffer = ctypes.create_string_buffer(4096)
    size = _libproc().proc_pidpath_audittoken(ctypes.byref(token), buffer, len(buffer))
    if size:
        return Path(os.fsdecode(buffer.value))
    error = ctypes.get_errno()
    if error == errno.ESRCH:
        return None
    raise OSError(error, "Cannot verify process audit token", identity["pid"])


def audit_alive(identity: dict) -> bool:
    return audit_path(identity) is not None


def signal_process(identity: dict, signum: int) -> bool:
    if not same_process(process_identity(identity["pid"]), identity):
        return False
    token = _token(identity)
    result = _libproc().proc_signal_with_audittoken(ctypes.byref(token), signum)
    if result == errno.ESRCH:
        return False
    if result:
        raise OSError(result, "Cannot signal process audit token", identity["pid"])
    return True


def _suspend_process(identity: dict) -> bool:
    current = process_identity(identity["pid"])
    if not same_process(current, identity) or current["state"] == 4:
        return False
    if not signal_process(identity, signal.SIGSTOP):
        return False
    while audit_alive(identity):
        current = process_identity(identity["pid"])
        if same_process(current, identity) and current["state"] == 4:
            return True
        time.sleep(0.01)
    return False


@contextmanager
def suspended_processes(identities: list[dict]):
    suspended = []
    try:
        for identity in identities:
            if identity["pid"] != os.getpid() and _suspend_process(identity):
                suspended.append(identity)
        yield
    finally:
        for identity in suspended:
            if audit_alive(identity):
                signal_process(identity, signal.SIGCONT)


def group_has_live_members(group: int, exclude_pid: int = 0) -> bool:
    rows = subprocess.check_output(
        ["ps", "-axo", "pid=,pgid=,stat="], text=True, start_new_session=True
    )
    return any(
        int(parts[1]) == group
        and int(parts[0]) != exclude_pid
        and not parts[2].startswith("Z")
        for line in rows.splitlines()
        if len(parts := line.split()) == 3
    )


def terminate_group(identity: dict, grace_seconds: float):
    if not group_has_live_members(identity["pgid"]):
        return
    current = process_identity(identity["pid"])
    if current is None:
        if group_has_live_members(identity["pgid"]):
            raise ValueError(
                f"Cannot verify measurement group {identity['pgid']}: its identity anchor is absent"
            )
        return
    if not same_process(current, identity):
        return
    if identity["pid"] != identity["pgid"]:
        raise ValueError("Measurement command must own its process group")
    with suspended_processes([identity]):
        deadline = time.monotonic() + grace_seconds
        while audit_alive(identity):
            rows = subprocess.check_output(
                ["ps", "-axo", "pid=,pgid=,stat="], text=True, start_new_session=True
            )
            members = []
            for line in rows.splitlines():
                parts = line.split()
                if (
                    len(parts) == 3
                    and int(parts[1]) == identity["pgid"]
                    and int(parts[0]) != identity["pid"]
                    and not parts[2].startswith("Z")
                ):
                    member = process_identity(int(parts[0]))
                    if member is not None and member["pgid"] == identity["pgid"]:
                        members.append(member)
            if not audit_alive(identity):
                if group_has_live_members(identity["pgid"]):
                    raise ValueError(
                        f"Measurement anchor {identity['pid']} died during group cleanup"
                    )
                return
            if not members:
                signal_process(identity, signal.SIGKILL)
                while audit_alive(identity):
                    time.sleep(0.01)
                return
            signum = signal.SIGTERM if time.monotonic() < deadline else signal.SIGKILL
            for member in members:
                signal_process(member, signum)
            time.sleep(0.05)


def terminate_process(identity: dict):
    signal_process(identity, signal.SIGKILL)
