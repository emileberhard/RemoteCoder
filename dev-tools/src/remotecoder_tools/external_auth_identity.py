import argparse
import ctypes
import hashlib
import json
import socket
from pathlib import Path


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def package_identity(package):
    package = package.resolve(strict=True)
    manifest = json.loads((package / "codex-package.json").read_text())
    tree = hashlib.sha256()
    files = {}
    for path in sorted(package.rglob("*")):
        relative = path.relative_to(package).as_posix()
        if path.is_symlink():
            path.resolve(strict=True).relative_to(package)
            if relative == "codex" and path.readlink() == Path("bin/codex"):
                continue
            contents = str(path.readlink()).encode()
            kind = b"link"
        elif path.is_file():
            with path.open("rb") as stream:
                file_hash = hashlib.file_digest(stream, "sha256")
            files[relative] = file_hash.hexdigest()
            contents = file_hash.digest()
            kind = b"file"
        else:
            continue
        tree.update(relative.encode() + b"\0" + kind + b"\0")
        tree.update(str(path.stat().st_mode & 0o111).encode() + b"\0" + contents)
    return {
        "packagePath": str(package),
        "sourceCommit": manifest["sourceCommit"],
        "version": manifest["version"],
        "runtimeHashes": {
            name: files[name] for name in ("bin/codex", "bin/codex-code-mode-host")
        },
        "manifestSHA256": files["codex-package.json"],
        "packageSHA256": tree.hexdigest(),
    }


def verify_package(package, approval):
    package = package.resolve(strict=True)
    manifest = json.loads((package / "codex-package.json").read_text())
    require(
        manifest["sourceCommit"] == approval["codexForkCommit"],
        "Package source differs from approved fork",
    )
    require(
        manifest["version"] == approval["codexCliVersion"],
        "Package version differs from approval",
    )
    for relative, expected in approval["runtimeHashes"].items():
        artifact = (package / relative).resolve(strict=True)
        artifact.relative_to(package)
        with artifact.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        require(digest == expected, f"Approved package hash mismatch: {relative}")
        require(
            manifest["binaries"][relative]["sha256"] == expected,
            f"Package manifest hash mismatch: {relative}",
        )
    binary = (package / manifest["entrypoint"]).resolve(strict=True)
    require(
        binary == (package / "bin/codex").resolve(strict=True),
        "Unexpected package entrypoint",
    )
    return binary


def verify_requested_identity(actual, requested):
    for key in (
        "sourceCommit",
        "version",
        "runtimeHashes",
        "manifestSHA256",
        "packageSHA256",
    ):
        require(
            actual[key] == requested[key],
            f"Execution package differs from requested host: {key}",
        )


def managed_executable(pid):
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        raise OSError(
            ctypes.get_errno(), f"Cannot read managed daemon executable for PID {pid}"
        )
    return Path(buffer.value.decode()).resolve(strict=True)


def main():
    parser = argparse.ArgumentParser(
        description="Read installed package identity without starting a runtime or accessing credentials."
    )
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--approval", type=Path, required=True)
    parser.add_argument("--requested-host", required=True)
    parser.add_argument("--managed-pid", type=int, required=True)
    args = parser.parse_args()
    package = args.package.resolve(strict=True)
    binary = verify_package(package, json.loads(args.approval.read_text()))
    require(
        managed_executable(args.managed_pid) == binary,
        "Managed daemon executable differs from selected approved package",
    )
    identity = package_identity(package)
    identity.update(
        requestedHost=args.requested_host,
        requestedHostName=socket.gethostname(),
        managedPid=args.managed_pid,
    )
    print(json.dumps(identity))


if __name__ == "__main__":
    main()
