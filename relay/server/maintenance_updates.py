import os
import subprocess
from pathlib import Path

REBOOT_REQUIRED = Path("/run/reboot-required")
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


def process_uses_replaced_file(pid):
    process = PROC / str(pid)
    try:
        maps = (process / "maps").read_text()
    except FileNotFoundError:
        if not process.exists():
            return False
        raise
    for line in maps.splitlines():
        fields = line.split(maxsplit=5)
        if len(fields) == 6:
            path = fields[5]
            if path.endswith(" (deleted)") and path.startswith(("/usr/lib/", "/lib/")):
                return True
    try:
        executable = (process / "exe").readlink()
    except FileNotFoundError:
        if not maps or not process.exists():
            return False
        raise
    return str(executable).endswith(" (deleted)")


def update_requires_reboot():
    if REBOOT_REQUIRED.exists():
        return True
    processes = set()
    for unit in SERVICES:
        processes.update(service_processes(unit, optional=False))
    for unit in OPTIONAL_SERVICES:
        processes.update(service_processes(unit, optional=True))
    return any(process_uses_replaced_file(pid) for pid in processes)
