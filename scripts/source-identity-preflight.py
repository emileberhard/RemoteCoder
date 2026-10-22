import errno
import fcntl
import json
import os
import resource
import stat
from contextlib import ExitStack
from pathlib import Path

from build_support import cache_root


class DescriptorLimitError(RuntimeError):
    pass


def check_descriptor_failure(error: OSError):
    if error.errno in (errno.EMFILE, errno.ENFILE):
        raise DescriptorLimitError(
            "Descriptor capacity exhausted. Raise the process hard/host descriptor "
            "limit or release descriptors, then rerun the preflight."
        ) from error


def reserve_descriptors(lock_count: int):
    required = lock_count + len(os.listdir("/dev/fd"))
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if soft == resource.RLIM_INFINITY or required <= soft:
        return
    requested = required if hard == resource.RLIM_INFINITY else min(required, hard)
    try:
        if requested > soft:
            resource.setrlimit(resource.RLIMIT_NOFILE, (requested, hard))
    except (OSError, ValueError) as error:
        raise DescriptorLimitError(
            f"Cannot reserve {required} descriptors (soft limit {soft}, hard limit "
            f"{hard}). Raise the process hard/host descriptor limit and rerun the preflight."
        ) from error
    if requested < required:
        raise DescriptorLimitError(
            f"Preflight needs {required} descriptors but the hard limit is {hard}. "
            "Raise the process hard descriptor limit and rerun the preflight."
        )


def main() -> int:
    try:
        root = cache_root()
    except OSError as error:
        check_descriptor_failure(error)
        print(
            json.dumps(
                {
                    "heldLeases": [],
                    "unverifiedLeases": [str(error.filename or Path.home())],
                }
            )
        )
        return 1
    held = set()
    unverified = set()

    def children(directory: Path) -> list[Path]:
        try:
            return list(directory.iterdir())
        except FileNotFoundError:
            return []
        except OSError as error:
            check_descriptor_failure(error)
            unverified.add(str(directory))
            return []

    paths = {
        path
        for directory in (root / "local-installs", root / "leases/worktrees")
        for path in children(directory)
        if path.name.endswith(".lock")
    }
    for mirror in children(root / "worktrees"):
        if mirror.is_symlink():
            unverified.add(str(mirror))
            continue
        if not mirror.is_dir():
            continue
        for group in ("ios", "gateway"):
            paths.update(
                path for path in children(mirror / group) if path.name == "build.lock"
            )
    try:
        reserve_descriptors(len(paths))
    except OSError as error:
        check_descriptor_failure(error)
        raise
    with ExitStack() as ownership:
        for path in sorted(paths):
            try:
                descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                ownership.callback(os.close, descriptor)
                if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                    unverified.add(str(path))
                    continue
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    held.add(str(path))
            except OSError as error:
                check_descriptor_failure(error)
                unverified.add(str(path))
        print(
            json.dumps(
                {"heldLeases": sorted(held), "unverifiedLeases": sorted(unverified)}
            )
        )
    return int(bool(held or unverified))


if __name__ == "__main__":
    try:
        status = main()
    except DescriptorLimitError as error:
        print(json.dumps({"error": {"kind": "descriptorLimit", "message": str(error)}}))
        status = 2
    raise SystemExit(status)
