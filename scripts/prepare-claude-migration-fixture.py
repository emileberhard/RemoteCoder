#!/usr/bin/env python3
import argparse
import ctypes
import errno
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path


CLAUDE_DIRECTORIES = (
    "projects", "remotecoder-agents", "session-env", "remotecoder-history", "memory",
)
STATE_NAMES = (
    "account-enrollments.json", "conversation-handoffs.json", "session-metadata-v2.json",
    "agent-calls.json", "conversation-marks.json", "claude-restart-recovery.json", "questions",
    "claude-profile-migration.json", "claude-profile-conflicts",
)
CREDENTIAL_NAMES = {
    ".credentials.json", "credentials.json", ".claude.json", "llm-router-key", "llm-router.key",
    "speech-credentials.json",
}
CHUNK_SIZE = 1024 * 1024


def open_directory(path):
    absolute = Path(os.path.abspath(path))
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in absolute.parts[1:]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def clone_file(source_fd, target):
    if sys.platform != "darwin":
        return False
    libc = ctypes.CDLL(None, use_errno=True)
    clone = getattr(libc, "fclonefileat", None)
    if clone is None:
        return False
    clone.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    clone.restype = ctypes.c_int
    parent_fd = open_directory(target.parent)
    try:
        if clone(source_fd, parent_fd, os.fsencode(target.name), 0) == 0:
            return True
        code = ctypes.get_errno()
        if code in {errno.EXDEV, errno.ENOTSUP, errno.EINVAL, errno.ENOSYS}:
            return False
        raise OSError(code, os.strerror(code), str(target))
    finally:
        os.close(parent_fd)


def bounded_hash(descriptor, size):
    digest = hashlib.sha256()
    offset = 0
    while offset < size:
        chunk = os.pread(descriptor, min(CHUNK_SIZE, size - offset), offset)
        if not chunk:
            raise RuntimeError("Fixture file changed while hashing")
        digest.update(chunk)
        offset += len(chunk)
    return digest.hexdigest()


class FixtureCopy:
    def __init__(self, home, fixture):
        if home == fixture or not stat.S_ISREG((fixture / ".migration-fixture").lstat().st_mode):
            raise ValueError("Fixture requires its marker and a distinct home")
        self.home = home
        self.fixture = fixture
        self.entries = {}
        self.excluded = []

    def copy(self, relative):
        source = self.home / relative
        try:
            parent_fd = open_directory(source.parent)
        except FileNotFoundError:
            return
        try:
            self.copy_entry(parent_fd, source.name, relative)
        except OSError as error:
            raise RuntimeError(f"Fixture source {source}: {error}") from error
        finally:
            os.close(parent_fd)

    def copy_entry(self, parent_fd, name, relative):
        if name in CREDENTIAL_NAMES:
            self.excluded.append(str(relative))
            return
        try:
            info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        target = self.fixture / relative
        if stat.S_ISLNK(info.st_mode):
            link = os.readlink(name, dir_fd=parent_fd)
            remapped = link
            if os.path.isabs(link):
                try:
                    inside = Path(os.path.normpath(link)).relative_to(self.home)
                except ValueError:
                    pass
                else:
                    remapped = str(self.fixture / inside)
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            target.symlink_to(remapped)
            self.entries[str(relative)] = {"type": "symlink", "sourceTarget": link, "target": remapped}
        elif stat.S_ISDIR(info.st_mode):
            source_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
            try:
                target.mkdir(parents=True, mode=0o700)
                self.entries[str(relative)] = {"type": "directory"}
                for child in sorted(os.listdir(source_fd)):
                    self.copy_entry(source_fd, child, relative / child)
            finally:
                os.close(source_fd)
        elif stat.S_ISREG(info.st_mode):
            source_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
            try:
                original = os.fstat(source_fd)
                if not stat.S_ISREG(original.st_mode) or (original.st_dev, original.st_ino) != (info.st_dev, info.st_ino):
                    raise RuntimeError(f"Fixture source changed: {self.home / relative}")
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                cloned = clone_file(source_fd, target)
                if not cloned:
                    target_fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                    try:
                        offset = 0
                        while offset < original.st_size:
                            chunk = os.pread(source_fd, min(CHUNK_SIZE, original.st_size - offset), offset)
                            if not chunk:
                                raise RuntimeError(f"Fixture source shrank: {self.home / relative}")
                            written = 0
                            while written < len(chunk):
                                count = os.write(target_fd, chunk[written:])
                                if count == 0:
                                    raise RuntimeError(f"Fixture write made no progress: {target}")
                                written += count
                            offset += len(chunk)
                    finally:
                        os.close(target_fd)
                target_fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    os.fchmod(target_fd, 0o600)
                    captured_size = os.fstat(target_fd).st_size
                    digest = bounded_hash(target_fd, captured_size)
                    if os.fstat(target_fd).st_size != captured_size:
                        raise RuntimeError(f"Fixture size mismatch: {relative}")
                finally:
                    os.close(target_fd)
                latest = os.fstat(source_fd)
                if not cloned and (original.st_size, original.st_mtime_ns, original.st_ctime_ns) != (latest.st_size, latest.st_mtime_ns, latest.st_ctime_ns):
                    raise RuntimeError(f"Fixture source changed while copying: {self.home / relative}")
                self.entries[str(relative)] = {"type": "file", "bytes": captured_size, "sha256": digest, "copy": "clone" if cloned else "copy"}
            finally:
                os.close(source_fd)
        else:
            raise RuntimeError(f"Unsupported fixture entry: {self.home / relative} (mode {stat.S_IFMT(info.st_mode):o})")

    def profile(self, relative):
        for name in CLAUDE_DIRECTORIES:
            self.copy(relative / name)
        try:
            profile_fd = open_directory(self.home / relative)
        except FileNotFoundError:
            return False
        try:
            for name in sorted(os.listdir(profile_fd)):
                mode = os.stat(name, dir_fd=profile_fd, follow_symlinks=False).st_mode
                if name not in CLAUDE_DIRECTORIES and stat.S_ISLNK(mode):
                    self.copy_entry(profile_fd, name, relative / name)
                elif name == "debug" and stat.S_ISDIR(mode):
                    debug_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=profile_fd)
                    try:
                        try:
                            latest = os.stat("latest", dir_fd=debug_fd, follow_symlinks=False)
                        except FileNotFoundError:
                            continue
                        if stat.S_ISLNK(latest.st_mode):
                            self.copy_entry(debug_fd, "latest", relative / "debug" / "latest")
                    finally:
                        os.close(debug_fd)
        finally:
            os.close(profile_fd)
        return True


def prepare_fixture(home, temp_parent=None):
    home = Path(os.path.abspath(home))
    home_fd = open_directory(home)
    os.close(home_fd)
    parent = Path(temp_parent or tempfile.gettempdir()).resolve()
    if parent == home or home in parent.parents:
        raise ValueError("Fixture temporary parent must be outside the source home")
    fixture = Path(tempfile.mkdtemp(prefix="claude-migration-fixture-", dir=parent))
    fixture.chmod(0o700)
    try:
        marker = fixture / ".migration-fixture"
        marker.touch(mode=0o600, exist_ok=False)
        if fixture == home or not marker.is_file():
            raise ValueError("Fixture requires its marker and a distinct home")
        copier = FixtureCopy(home, fixture)
        copier.profile(Path(".claude"))
        for name in STATE_NAMES:
            copier.copy(Path(".remote-coder") / name)
        profiles = []
        try:
            accounts_fd = open_directory(home / ".rca")
        except FileNotFoundError:
            pass
        else:
            try:
                for name in sorted(os.listdir(accounts_fd)):
                    if not stat.S_ISDIR(os.stat(name, dir_fd=accounts_fd, follow_symlinks=False).st_mode):
                        continue
                    relative = Path(".rca") / name
                    if not copier.profile(relative / "claude"):
                        continue
                    profiles.append(name)
                    for state in STATE_NAMES:
                        copier.copy(relative / "state" / state)
                    copier.copy(relative / "handoff-backups")
            finally:
                os.close(accounts_fd)
        manifest = {"schemaVersion": 1, "sourceHome": str(home), "fixture": str(fixture), "profiles": profiles, "entries": copier.entries, "excluded": copier.excluded}
        manifest_path = fixture / ".fixture-manifest.json"
        with manifest_path.open("x", encoding="utf-8") as stream:
            json.dump(manifest, stream, sort_keys=True, indent=2)
            stream.write("\n")
        manifest_path.chmod(0o600)
        return manifest
    except BaseException:
        shutil.rmtree(fixture)
        raise


def main():
    parser = argparse.ArgumentParser(description="Prepare an isolated Claude migration fixture without following links or copying credentials.")
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--temp-parent", type=Path)
    args = parser.parse_args()
    manifest = prepare_fixture(args.home, args.temp_parent)
    counts = {kind: sum(entry["type"] == kind for entry in manifest["entries"].values()) for kind in ("file", "directory", "symlink")}
    print(json.dumps({"fixture": manifest["fixture"], "manifest": str(Path(manifest["fixture"]) / ".fixture-manifest.json"), "profiles": manifest["profiles"], "counts": counts, "excluded": manifest["excluded"]}))


if __name__ == "__main__":
    main()
