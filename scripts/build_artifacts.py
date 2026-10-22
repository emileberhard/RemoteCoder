"""Content identity for immutable build packages (including resources and modes)."""

import argparse
import hashlib
import shutil
import tempfile
from pathlib import Path


def tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            # Package links must resolve within the package being verified.
            path.resolve(strict=True).relative_to(root.resolve())
            contents = str(path.readlink()).encode()
            kind = b"link"
        elif path.is_file():
            kind = b"file"
            file_hash = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    file_hash.update(chunk)
            contents = file_hash.digest()
        else:
            continue
        digest.update(path.relative_to(root).as_posix().encode() + b"\0" + kind + b"\0")
        digest.update(str(path.stat().st_mode & 0o111).encode() + b"\0" + contents)
    return digest.hexdigest()


def valid_package(root: Path, expected: str) -> bool:
    try:
        return (root / "codex-package.json").is_file() and tree_digest(root) == expected
    except (OSError, ValueError):
        return False


def reuse_installed(destination: Path, expected: str) -> bool:
    """Snapshot an installed package; a version directory is mutable during upgrades."""
    current = Path.home() / ".codex/packages/standalone/current"
    if not current.exists():
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="package-reuse-", dir=destination.parent
    ) as temporary:
        staged = Path(temporary) / "package"
        try:
            shutil.copytree(current.resolve(strict=True), staged, symlinks=True)
        except OSError:
            return False
        if not valid_package(staged, expected):
            # The runtime installer adds this convenience link to the original
            # package. Remove only that known addition, then check every byte.
            shim = staged / "codex"
            if shim.is_symlink() and shim.readlink() == Path("bin/codex"):
                shim.unlink()
            if not valid_package(staged, expected):
                return False
        if destination.exists():
            destination.rmdir()  # The caller owns an empty run directory only.
        staged.replace(destination)
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path, nargs="?")
    parser.add_argument("--expect")
    parser.add_argument("--reuse-installed", type=Path)
    args = parser.parse_args()
    if args.reuse_installed:
        if not args.expect:
            parser.error("--reuse-installed requires --expect")
        if reuse_installed(args.reuse_installed, args.expect):
            print("reused")
        raise SystemExit(0)
    if args.package is None:
        parser.error("a package path is required")
    actual = tree_digest(args.package)
    if args.expect and actual != args.expect:
        raise SystemExit("Package content identity does not match")
    print(actual)
