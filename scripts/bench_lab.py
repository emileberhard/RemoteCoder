import argparse
import hashlib
import json
import os
import stat
import subprocess
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from process_group import audit_path, process_identity, same_process

METADATA = "isolated-gateway.json"


class LabConfigError(ValueError):
    pass


@dataclass(frozen=True)
class LabConfiguration:
    directory: Path
    data: bytes


def reject_unsafe_location(directory: Path, snapshot_root: Path) -> None:
    original = directory.absolute()
    directory = original.resolve()
    if any(path.is_relative_to(snapshot_root.resolve()) or "RemoteCoder-Build" in path.parts
           for path in (original, directory)):
        raise LabConfigError("Lab placement must be outside source snapshots and RemoteCoder build caches.")
    probes = {directory, *(path.parent for path in (original, *original.parents) if path.is_symlink())}
    for existing in probes:
        while not existing.exists():
            existing = existing.parent
        result = subprocess.run(["git", "-C", str(existing), "rev-parse", "--absolute-git-dir"],
                                capture_output=True, text=True, timeout=10,
                                env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(Path.home()),
                                     "LC_ALL": "C", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"})
        if result.returncode == 0:
            raise LabConfigError("Lab placement must be outside every Git worktree.")
        if result.returncode != 128 or "not a git repository" not in result.stderr:
            raise LabConfigError("Cannot establish that the lab is outside a Git worktree.")


def private_file(path: Path) -> bytes:
    with path.open("rb") as source:
        file = os.fstat(source.fileno())
        directory = path.parent.stat()
        if not stat.S_ISREG(file.st_mode) or file.st_size > 64 * 1024:
            raise LabConfigError("Lab files must be regular JSON files of at most 64 KiB.")
        if any(entry.st_uid != os.geteuid() or entry.st_mode & 0o077 for entry in (file, directory)):
            raise LabConfigError("The lab file and directory must be owner-only.")
        data = source.read(64 * 1024 + 1)
        if len(data) > 64 * 1024:
            raise LabConfigError("Lab files must be at most 64 KiB.")
        return data


def record_gateway(root: Path, port: int, token_sha256: str, executable: Path, pid: int, parent_pid: int) -> None:
    root = root.resolve(strict=True)
    directory = root.stat()
    if directory.st_uid != os.geteuid() or directory.st_mode & 0o077:
        raise LabConfigError("The isolated gateway root must be owner-only.")
    if not 1 <= port <= 65535 or len(token_sha256) != 64 or any(character not in "0123456789abcdef" for character in token_sha256):
        raise LabConfigError("The isolated gateway port or token fingerprint is invalid.")
    executable = executable.resolve(strict=True)
    identity = process_identity(pid)
    if identity is None or identity["ppid"] != parent_pid or audit_path(identity) != executable:
        raise LabConfigError("The gateway is not the live child launched by the isolated owner.")
    metadata = {"version": 1, "root": str(root), "port": port, "tokenSHA256": token_sha256,
                "gateway": identity, "executable": str(executable)}
    with tempfile.NamedTemporaryFile(mode="w", dir=root, delete=False) as output:
        temporary = Path(output.name)
        try:
            json.dump(metadata, output)
            output.flush()
            os.replace(temporary, root / METADATA)
        finally:
            temporary.unlink(missing_ok=True)


def load_config(path: Path, snapshot_root: Path, validate_fields: Callable[[bytes], None]) -> LabConfiguration:
    try:
        if not path.is_absolute():
            raise LabConfigError("Supply an absolute MacBook lab configuration path.")
        reject_unsafe_location(path.parent, snapshot_root)
        path = path.resolve(strict=True)
        root = path.parent
        reject_unsafe_location(root, snapshot_root)
        data = private_file(path)
        validate_fields(data)
        configuration = json.loads(data)
        token = configuration.get("codexGatewayAuthToken")
        if configuration.get("macBookHostname") != "127.0.0.1" or configuration.get("macMiniHostname") not in (None, ""):
            raise LabConfigError("The lab configuration must name only its MacBook loopback gateway.")
        if any(configuration.get(key) is not None and not isinstance(configuration[key], str)
               for key in ("codexWorkdir", "googleMapsAPIKey")):
            raise LabConfigError("Lab configuration string fields are invalid.")
        if type(configuration.get("codexGatewayPort")) is not int:
            raise LabConfigError("The lab configuration needs an explicit gateway port.")
        if not isinstance(token, str) or not token.strip() or any(character.isspace() for character in token):
            raise LabConfigError("The lab configuration needs its owned gateway token.")
        metadata = json.loads(private_file(root / METADATA))
        if metadata["version"] != 1 or metadata["root"] != str(root):
            raise LabConfigError("The configuration is outside its recorded isolated gateway root.")
        if metadata["port"] != configuration["codexGatewayPort"] or metadata["tokenSHA256"] != hashlib.sha256(token.encode()).hexdigest():
            raise LabConfigError("The port and token must match the isolated gateway owner's metadata.")
        identity = metadata["gateway"]
        current = process_identity(identity["pid"])
        if not same_process(current, identity) or current["ppid"] != identity["ppid"]:
            raise LabConfigError("The recorded isolated gateway is no longer the live owned process.")
        if audit_path(identity) != Path(metadata["executable"]):
            raise LabConfigError("The recorded isolated gateway executable no longer matches.")
        return LabConfiguration(root, data)
    except LabConfigError:
        raise
    except (OSError, TypeError, ValueError, KeyError, subprocess.SubprocessError):
        raise LabConfigError("Missing or invalid isolated gateway configuration/metadata; start the isolated owner first.") from None


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("port", type=int)
    parser.add_argument("token_sha256")
    parser.add_argument("executable", type=Path)
    parser.add_argument("pid", type=int)
    parser.add_argument("parent_pid", type=int)
    args = parser.parse_args()
    record_gateway(args.root, args.port, args.token_sha256, args.executable, args.pid, args.parent_pid)
