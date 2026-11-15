import hashlib
import json
import os
import re
import stat
import subprocess
import uuid
from pathlib import Path

from maintenance_state import DIRECTORY, boot_id, unique_fields

REBOOT_REQUIRED = Path("/run/reboot-required")
ATTEMPT = DIRECTORY / "update-attempt.json"
DPKG_STATUS = Path("/var/lib/dpkg/status")
DPKG_LOG = Path("/var/log/dpkg.log")
CGROUP = Path("/sys/fs/cgroup")
PROC = Path("/proc")
SERVICES = ("haproxy.service", "tinyproxy.service", "ssh.service")
OPTIONAL_SERVICES = ("tailscaled.service",)


def service_processes(unit, optional):
    result = subprocess.run(
        [
            "/usr/bin/systemctl",
            "show",
            unit,
            "-p",
            "LoadState",
            "-p",
            "ActiveState",
            "-p",
            "ControlGroup",
        ],
        capture_output=True,
        text=True,
        timeout=5,
        check=True,
    )
    properties = dict(line.split("=", 1) for line in result.stdout.splitlines())
    if optional and (
        properties.get("LoadState") == "not-found"
        or (
            properties.get("LoadState") == "loaded"
            and properties.get("ActiveState") == "inactive"
        )
    ):
        return set()
    if (
        properties.get("LoadState") != "loaded"
        or properties.get("ActiveState") != "active"
    ):
        raise RuntimeError(f"{unit} is not active and loaded")
    group = properties.get("ControlGroup", "")
    if not group.startswith("/") or ".." in Path(group).parts:
        raise RuntimeError(f"{unit} has no valid control group")
    directory = CGROUP / group.lstrip("/")
    processes = set()

    def fail_walk(error):
        raise error

    for root, _directories, files in os.walk(directory, onerror=fail_walk):
        if "cgroup.procs" not in files:
            raise RuntimeError(f"{unit} has an unreadable control group")
        processes.update(
            int(line) for line in (Path(root) / "cgroup.procs").read_text().splitlines()
        )
    if not processes:
        raise RuntimeError(f"{unit} has no processes in its control group")
    return processes


def process_replaced_files(pid):
    process = PROC / str(pid)
    try:
        maps = (process / "maps").read_text()
    except FileNotFoundError:
        if not process.exists():
            return set()
        raise
    replaced = set()
    for line in maps.splitlines():
        fields = line.split(maxsplit=5)
        if len(fields) == 6:
            path = fields[5]
            if (
                fields[1].startswith("r-x")
                and path.endswith(" (deleted)")
                and path.startswith(("/usr/lib/", "/lib/"))
            ):
                replaced.add(path)
    try:
        executable = (process / "exe").readlink()
    except FileNotFoundError:
        if not maps or not process.exists():
            return replaced
        raise
    if str(executable).endswith(" (deleted)"):
        replaced.add(str(executable))
    return replaced


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def package_generation():
    status = DPKG_STATUS.stat()
    generation = digest(f"{status.st_ino}:{status.st_mtime_ns}:{status.st_size}")
    try:
        with DPKG_LOG.open("rb") as log:
            log.seek(0, os.SEEK_END)
            length = log.tell()
            log.seek(max(0, length - 65536))
            lines = log.read().decode(errors="replace").splitlines()
    except FileNotFoundError:
        lines = []
    starts = [line for line in lines if " startup " in line]
    return generation, digest(starts[-1]) if starts else None


def previous_attempt():
    try:
        info = ATTEMPT.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
        raise RuntimeError("invalid relay update attempt ownership or permissions")
    data = json.loads(ATTEMPT.read_text(), object_pairs_hook=unique_fields)
    if (
        not isinstance(data, dict)
        or set(data)
        != {"schema", "boot_id", "fingerprint", "status_generation", "dpkg_startup"}
        or type(data["schema"]) is not int
        or data["schema"] != 1
    ):
        raise ValueError("invalid relay update attempt")
    if not isinstance(data["boot_id"], str):
        raise TypeError("invalid relay update boot identity")
    data["boot_id"] = str(uuid.UUID(data["boot_id"]))
    for name in ("fingerprint", "status_generation"):
        if not isinstance(data[name], str) or not re.fullmatch(
            r"[0-9a-f]{64}", data[name]
        ):
            raise ValueError("invalid relay update fingerprint")
    if data["dpkg_startup"] is not None and (
        not isinstance(data["dpkg_startup"], str)
        or not re.fullmatch(r"[0-9a-f]{64}", data["dpkg_startup"])
    ):
        raise ValueError("invalid relay dpkg generation")
    return data


def reboot_evidence():
    replaced = set()
    for unit in SERVICES:
        for pid in service_processes(unit, optional=False):
            replaced.update((unit, path) for path in process_replaced_files(pid))
    for unit in OPTIONAL_SERVICES:
        for pid in service_processes(unit, optional=True):
            replaced.update((unit, path) for path in process_replaced_files(pid))
    required = REBOOT_REQUIRED.exists()
    if not required and not replaced:
        return None
    generation, startup = package_generation()
    evidence = {
        "schema": 1,
        "boot_id": boot_id(),
        "fingerprint": digest(json.dumps(sorted(replaced), separators=(",", ":"))),
        "status_generation": generation,
        "dpkg_startup": startup,
    }
    if not required:
        previous = previous_attempt()
        if (
            previous is not None
            and previous["boot_id"] != evidence["boot_id"]
            and previous["fingerprint"] == evidence["fingerprint"]
            and previous["status_generation"] == generation
            and (startup is None or startup == previous["dpkg_startup"])
        ):
            raise RuntimeError(
                "relay update evidence persisted after reboot; automatic reboot inhibited"
            )
    return evidence
