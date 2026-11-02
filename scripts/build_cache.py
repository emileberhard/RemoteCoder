import fcntl
import hashlib
import json
import os
import shlex
import shutil
import socket
import stat
import subprocess
import tempfile
import time
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path

from build_support import (
    atomic_json,
    canonical_path,
    file_lease,
    source_lease_path,
)


@dataclass(frozen=True)
class CachePolicy:
    max_runs: int
    run_retention_seconds: int
    evidence_protection_seconds: int
    compiler_protection_seconds: int
    compilation_budget_bytes: int
    retained_completed_directories: int
    eviction_target_free_bytes: int
    eviction_enabled: bool
    retired_worktree_seconds: int


def load_policy() -> CachePolicy:
    source = Path.home() / "configs/build/compilation-cache-policy.json"
    try:
        policy = read_policy(source)
    except FileNotFoundError:
        return CachePolicy(128, 3 * 86400, 48 * 3600, 2 * 3600, 40 * 1024**3, 2, 20 * 1024**3, True, 24 * 3600)
    activation = source.with_name("compilation-cache-eviction.json")
    try:
        enabled = json.loads(activation.read_text())
    except FileNotFoundError:
        enabled = False
    if type(enabled) is not bool:
        raise ValueError(f"Invalid compilation eviction activation: {activation}")
    return replace(policy, eviction_enabled=enabled)


def read_policy(source: Path) -> CachePolicy:
    values = json.loads(source.read_text())
    host_budgets = values.pop("hostCompilationBudgetGiB", {})
    if not isinstance(host_budgets, dict) or any(
        not isinstance(host, str) or not host or type(budget) is not int or budget <= 0
        for host, budget in host_budgets.items()
    ):
        raise ValueError(f"Invalid host compilation budgets: {source}")
    required = {
        "maxRuns",
        "runRetentionDays",
        "evidenceProtectionHours",
        "compilerProtectionHours",
        "compilationBudgetGiB",
        "retainedCompletedDirectories",
        "evictionTargetFreeGiB",
        "evictionEnabled",
        "retiredWorktreeIdleHours",
    }
    if set(values) != required or type(values["evictionEnabled"]) is not bool:
        raise ValueError(f"Invalid build cache policy: {source}")
    if any(
        type(v) is not int or v <= 0
        for k, v in values.items()
        if k != "evictionEnabled"
    ):
        raise ValueError(f"Invalid build cache policy: {source}")
    if values["evidenceProtectionHours"] < 48:
        raise ValueError(
            f"Build evidence requires at least 48 hours of protection: {source}"
        )
    return CachePolicy(
        values["maxRuns"],
        values["runRetentionDays"] * 86400,
        values["evidenceProtectionHours"] * 3600,
        values["compilerProtectionHours"] * 3600,
        host_budgets.get(socket.gethostname().split(".")[0], values["compilationBudgetGiB"]) * 1024**3,
        values["retainedCompletedDirectories"],
        values["evictionTargetFreeGiB"] * 1024**3,
        values["evictionEnabled"],
        values["retiredWorktreeIdleHours"] * 3600,
    )


@dataclass(frozen=True)
class CompilationDirectory:
    path: Path
    worktree: str
    leases: tuple[Path, ...]
    source: Path | None
    kind: str


def compilation_record(root: Path, path: Path) -> Path:
    key = hashlib.sha256(str(canonical_path(path)).encode()).hexdigest()
    return root / "leases/compilation" / (key + ".json")


def record_compilation(
    root: Path, paths: list[Path], build_id: str, active: bool, source: dict
):
    now = time.time()
    for path in paths:
        path = canonical_path(path)
        compilation_record(root, path).parent.mkdir(parents=True, exist_ok=True)
        atomic_json(
            compilation_record(root, path),
            {
                "schemaVersion": 2,
                "path": str(path.absolute()),
                "buildId": build_id,
                "active": active,
                "lastUsed": now,
                "completedAt": None if active else now,
                "sourceCommit": source["sourceCommit"],
                "sourceModified": source["sourceModified"],
            },
        )


def record_mirror_source(root: Path, manifest: dict):
    if "sourceHost" not in manifest or "sourceRoot" not in manifest:
        return
    mirror = root / "worktrees" / manifest["worktreeId"]
    mirror.mkdir(parents=True, exist_ok=True)
    atomic_json(
        mirror / "source.json",
        {key: manifest[key] for key in ("worktreeId", "sourceHost", "sourceRoot")},
    )


def _mirror_source(root: Path, entry: CompilationDirectory) -> tuple[str, str] | None:
    if not entry.worktree.startswith("mirror:"):
        return None
    identity = entry.worktree.removeprefix("mirror:")
    record = root / "worktrees" / identity / "source.json"
    try:
        if record.is_symlink():
            return None
        owner = json.loads(record.read_text())
        host, source = owner["sourceHost"], owner["sourceRoot"]
        if (
            not isinstance(host, str)
            or not host
            or host.startswith("-")
            or not isinstance(source, str)
            or not Path(source).is_absolute()
            or owner["worktreeId"] != identity
            or hashlib.sha256((host + ":" + source).encode()).hexdigest()[:16]
            != identity
        ):
            return None
        return host, source
    except (OSError, ValueError, KeyError, TypeError):
        return None


def _removed_mirror_source(
    root: Path, entry: CompilationDirectory, *, check_remote: bool
) -> bool:
    owner = _mirror_source(root, entry)
    if owner is None:
        return False
    host, source = owner
    try:
        if host == socket.gethostname():
            try:
                Path(source).stat()
            except FileNotFoundError:
                return True
            return False
        if not check_remote:
            return False
        probe = "import os,sys\ntry: os.stat(sys.argv[1])\nexcept FileNotFoundError: sys.exit(44)"
        result = subprocess.run(
            [
                "ssh",
                "-oBatchMode=yes",
                "-oConnectTimeout=3",
                host,
                "python3 -c " + shlex.quote(probe) + " " + shlex.quote(source),
            ],
            capture_output=True,
            timeout=5,
            check=False,
        )
        return result.returncode == 44
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        return False


def _real_directory(path: Path) -> bool:
    return path.is_dir() and not path.is_symlink() and path.absolute() == path.resolve()


def compilation_directories(
    root: Path, worktrees: list[Path], derived_data: Path
) -> list[CompilationDirectory]:
    root = canonical_path(root)
    entries = []
    mirrors = root / "worktrees"
    if mirrors.is_symlink():
        entries.append(
            CompilationDirectory(mirrors, "unknown-mirrors", (), None, "protected")
        )
    if _real_directory(mirrors):
        for mirror in mirrors.iterdir():
            if not _real_directory(mirror):
                continue
            leases = (
                lease_path(root, "worktrees", mirror.name),
                *_legacy_locks(mirror),
            )
            for group in ("ios", "gateway"):
                folder = mirror / group
                if not _real_directory(folder):
                    continue
                for path in folder.iterdir():
                    if path.name.startswith("derived-"):
                        kind = "xcode"
                    elif path.name.startswith("swift-"):
                        kind = "swift"
                    elif path.name == "cargo":
                        kind = "cargo"
                    else:
                        continue
                    entries.append(
                        CompilationDirectory(
                            path, "mirror:" + mirror.name, leases, None, kind
                        )
                    )
    home = canonical_path(root.parents[2])
    for source in dict.fromkeys(canonical_path(path) for path in worktrees):
        if not source.is_relative_to(home) or not _real_directory(source):
            continue
        identity = "local:" + str(source)
        leases = (source_lease_path(source),)
        build = source / "build"
        if build.is_symlink():
            entries.append(
                CompilationDirectory(build, identity, leases, source, "protected")
            )
        if _real_directory(build):
            for path in build.iterdir():
                if not path.is_dir() and not path.is_symlink():
                    continue
                kind = (
                    "xcode"
                    if path.name.endswith("-derived")
                    else "swift"
                    if path.name.startswith("swift-")
                    else "protected"
                )
                entries.append(
                    CompilationDirectory(path, identity, leases, source, kind)
                )
        target = source / "host-daemon-rs/target"
        if target.exists() or target.is_symlink():
            entries.append(
                CompilationDirectory(target, identity, leases, source, "cargo")
            )
    if derived_data.is_symlink():
        entries.append(
            CompilationDirectory(derived_data, "unowned-xcode", (), None, "protected")
        )
    if _real_directory(derived_data):
        entries.extend(
            CompilationDirectory(
                path, "unowned-xcode:" + path.name, (), None, "protected"
            )
            for path in derived_data.iterdir()
            if path.is_dir() or path.is_symlink()
        )
    return entries


def shared_compilation_directories(root: Path) -> list[CompilationDirectory]:
    entries = []
    for owner in ("codex-fork-check", "codex-runtime"):
        target = root / owner / "target"
        if _real_directory(target):
            entries.append(
                CompilationDirectory(
                    target, "shared:" + owner,
                    (root / owner / "build.lock",), None, "cargo",
                )
            )
    return entries


def local_worktrees(source: Path) -> list[Path]:
    result = subprocess.check_output(
        ["git", "worktree", "list", "--porcelain", "-z"], cwd=source
    )
    return [
        canonical_path(Path(part[9:].decode()))
        for part in result.split(b"\0")
        if part.startswith(b"worktree ")
    ]


def _owner_device(root: Path, entry: CompilationDirectory) -> int:
    owner = entry.source or (
        root.parents[2] if entry.worktree.startswith("unowned-xcode") else root
    )
    if entry.path == owner or not entry.path.is_relative_to(owner):
        raise ValueError(
            f"Compilation cache is outside its enclosing owner: {entry.path}"
        )
    with _directory_descriptor(owner) as directory:
        return os.fstat(directory).st_dev


def _allocated_bytes(path: Path, deadline: float, device: int) -> int:
    with _directory_descriptor(path) as directory:
        return _tree_bytes(directory, deadline, device, exclude_linked=False)


def _reclaimable_bytes(path: Path, deadline: float, device: int) -> int:
    with _directory_descriptor(path) as directory:
        return _tree_bytes(directory, deadline, device, exclude_linked=True)


@dataclass(frozen=True)
class CacheInventory:
    allocated_bytes: int | None
    directories: dict[Path, int]
    error: str | None


def cache_inventory(root: Path) -> CacheInventory:
    if not _real_directory(root):
        raise ValueError(f"Unsafe cache root: {root}")
    error = None
    try:
        measured = subprocess.run(
            ["du", "-kx", "-d", "4", str(root)], capture_output=True,
            timeout=120, check=True,
        )
        output = measured.stdout
    except subprocess.TimeoutExpired as failure:
        if failure.stderr:
            return CacheInventory(None, {}, str(failure))
        output = failure.stdout or b""
        error = str(failure)
    except subprocess.CalledProcessError as failure:
        return CacheInventory(None, {}, str(failure))
    directories = {}
    for line in output.splitlines():
        count, separator, name = line.partition(b"\t")
        if not separator or not count.isdigit():
            continue
        path = Path(os.fsdecode(name))
        if path.is_absolute() and path.is_relative_to(root):
            directories[path] = int(count) * 1024
    total = directories.get(root) if error is None else None
    if total is None and error is None:
        error = "du returned no cache allocation"
    return CacheInventory(total, directories, error)


def cache_allocated_bytes(root: Path) -> int:
    inventory = cache_inventory(root)
    if inventory.allocated_bytes is None:
        raise ValueError(inventory.error)
    return inventory.allocated_bytes


def maintain_cache(root: Path, policy: CachePolicy) -> dict:
    return _cache_maintenance(root, policy, preview=False)


def preview_cache(root: Path, policy: CachePolicy) -> dict:
    return _cache_maintenance(root, policy, preview=True)


def _publish_maintenance(root: Path, policy: CachePolicy, manifest: dict, used: int | None, reason: str):
    status = {
        "version": 1,
        "owner": "remotecoder-build",
        "observed_at": datetime.now(UTC).isoformat(),
        "unmet": None if used is None else used > policy.compilation_budget_bytes,
        "used_bytes": used,
        "cap_bytes": policy.compilation_budget_bytes,
        "reason": reason,
    }
    manifest["capStatus"] = status
    destination = Path.home() / ".local/state/disk-cap-status/remotecoder-build.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    atomic_json(root / "maintenance.json", manifest)
    atomic_json(destination, status)


def _cache_maintenance(root: Path, policy: CachePolicy, *, preview: bool) -> dict:
    with try_lease(root / "leases/maintenance.lock") as maintenance:
        if maintenance is None:
            return {"maintenanceDeferred": "maintenance-held", "message": "skipped: maintenance held", "exitCode": 0}
        try:
            inventory = cache_inventory(root)
            root_bytes = inventory.allocated_bytes
            entries = compilation_directories(root, [], Path.home() / "Library/Developer/Xcode/DerivedData")
            if root_bytes is None or root_bytes > policy.compilation_budget_bytes or shutil.disk_usage(root).free < policy.eviction_target_free_bytes:
                entries += shared_compilation_directories(root)
            manifest = _compilation_admission(root, policy, entries, set(), maintenance=maintenance, preview=preview, root_bytes=root_bytes, directory_bytes=inventory.directories)
            if inventory.error:
                manifest["rootAllocationError"] = inventory.error
            manifest["evidenceRetention"] = _prune_caches(root, policy, "", "", maintenance=maintenance, preview=preview)
            manifest["snapshotRetention"] = _retire_snapshots(root, preview=preview or not policy.eviction_enabled)
            manifest["retentionClasses"] = [
                {"class": name, "allocatedBytes": inventory.directories.get(root / name), "retention": retention}
                for name, retention in (
                    ("worktrees", "compiler 2h; two clean package seeds per resolution; source/evidence 48h minimum"),
                    ("runs", "3 days; 48h minimum; active/unknown completion retained"),
                    ("releases", "newest three plus published and every version used within 48h"),
                    ("rollback", "7 days; installed/referenced/open/unknown snapshots retained"),
                    ("deploy", "7 days; active installer/referenced/open/unknown snapshots retained"),
                    ("codex-runtime", "eight keyed packages; live collectors and runtime seed pinned"),
                    ("release", "compiler 2h; receipts/symbols protected by owning retention"),
                )
            ]
            if preview:
                return manifest
            try:
                after = cache_inventory(root)
                remaining = after.allocated_bytes
                if remaining is None:
                    raise ValueError(after.error or "Cache allocation unavailable")
                for item in manifest["retentionClasses"]:
                    item["remainingBytes"] = after.directories.get(root / item["class"])
                reason = (
                    "Total cap unmet after bounded reclamation; inspect RemoteCoder-Build/maintenance.json for protected data or failures"
                    if remaining > policy.compilation_budget_bytes
                    else "Total cache cap met"
                )
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                remaining = None
                reason = str(error)
            manifest["rootRemainingBytes"] = remaining
            manifest["rootInventoryComplete"] = remaining is not None
            manifest["projectedBytes"] = remaining
            manifest["remainingBytes"] = remaining
            manifest["unsatisfiedBudgetBytes"] = None if remaining is None else max(0, remaining - policy.compilation_budget_bytes)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            if not preview:
                _publish_maintenance(root, policy, {"maintenanceError": str(error), "inventoryComplete": False, "rootInventoryComplete": False}, None, str(error))
            raise
        _publish_maintenance(root, policy, manifest, remaining, reason)
        return manifest


def _tree_bytes(directory: int, deadline: float, device: int, *, exclude_linked: bool) -> int:
    info = os.fstat(directory)
    if info.st_dev != device:
        raise ValueError("Foreign mount in cache inventory")
    total = info.st_blocks * 512
    for name in os.listdir(directory):
        if time.monotonic() >= deadline:
            raise TimeoutError("Cache inventory deadline exceeded")
        info = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if info.st_dev != device:
            raise ValueError(f"Foreign mount in cache inventory: {name}")
        if stat.S_ISDIR(info.st_mode):
            child = _opened_child(directory, name, info)
            try:
                total += _tree_bytes(child, deadline, device, exclude_linked=exclude_linked)
            finally:
                os.close(child)
        elif not exclude_linked or info.st_nlink == 1:
            total += info.st_blocks * 512
    return total


def _legacy_compilation_records(
    root: Path, deadline: float
) -> tuple[dict[Path, list[Path]], str]:
    records = {}
    coverage = "complete"
    try:
        directory = root / "leases/compilation"
        if directory.is_symlink():
            return records, "unreadable"
        for record in directory.iterdir():
            if time.monotonic() >= deadline:
                return records, "deadline"
            if record.suffix != ".json":
                continue
            try:
                if record.is_symlink():
                    raise ValueError("Compilation record is a symlink")
                value = json.loads(record.read_text())
                if (
                    not isinstance(value, dict)
                    or not isinstance(value.get("path"), str)
                    or not Path(value["path"]).is_absolute()
                ):
                    raise ValueError("Compilation record has no path association")
                path = canonical_path(Path(value["path"]))
                if value.get("schemaVersion") == 2:
                    if record != compilation_record(root, path):
                        raise ValueError(
                            "Canonical compilation record has the wrong key"
                        )
                    continue
                records.setdefault(path, []).append(record)
            except (OSError, ValueError):
                coverage = "unreadable"
    except FileNotFoundError:
        pass
    except OSError:
        coverage = "unreadable"
    return records, coverage


def _record_completion(
    value: object, entry: CompilationDirectory
) -> tuple[dict | None, str]:
    try:
        if (
            not isinstance(value, dict)
            or value.get("schemaVersion") not in (None, 2)
            or not isinstance(value.get("path"), str)
            or not Path(value["path"]).is_absolute()
            or canonical_path(Path(value["path"])) != canonical_path(entry.path)
        ):
            return None, "invalid"
    except (OSError, ValueError):
        return None, "unreadable"
    if value.get("active") is True:
        return None, "active"
    if value.get("active") is not False or any(
        type(value.get(k)) not in (int, float) or not 0 < value[k] <= time.time()
        for k in ("lastUsed", "completedAt")
    ):
        return None, "invalid"
    return value, "complete"


def _completion(
    root: Path,
    entry: CompilationDirectory,
    legacy: tuple[dict[Path, list[Path]], str],
) -> tuple[dict | None, str]:
    try:
        path = canonical_path(entry.path)
        record = compilation_record(root, path)
    except (OSError, ValueError):
        return None, "unreadable"
    missing = object()
    try:
        if record.is_symlink():
            return None, "unreadable"
        value = json.loads(record.read_text())
    except FileNotFoundError:
        value = missing
    except (OSError, ValueError):
        return None, "unreadable"
    if value is not missing:
        completion, state = _record_completion(value, entry)
        if state != "complete" or completion.get("schemaVersion") == 2:
            return completion, state
    records, coverage = legacy
    if coverage != "complete":
        return None, coverage
    related = records.get(path, [])
    if not related:
        return (None, "missing") if value is missing else (completion, "complete")
    completions = []
    for record in related:
        try:
            value = json.loads(record.read_text())
        except (OSError, ValueError):
            return None, "unreadable"
        completion, state = _record_completion(value, entry)
        if state != "complete":
            return None, state
        completions.append(completion)
    latest = max(value["lastUsed"] for value in completions)
    newest = [value for value in completions if value["lastUsed"] == latest]
    evidence = [
        {key: value for key, value in item.items() if key != "path"} for item in newest
    ]
    if any(item != evidence[0] for item in evidence):
        return None, "invalid"
    return newest[0], "complete"


def _historical_completion(
    root: Path, entry: CompilationDirectory
) -> tuple[dict | None, str]:
    if entry.kind == "protected":
        return None, "not-compiler-owned"
    if entry.source is None:
        return _mirror_completion(root, entry)
    try:
        witnesses = (
            list(entry.path.glob("Build/Intermediates.noindex/XCBuildData/build.db"))
            if entry.kind == "xcode"
            else list(entry.path.glob("debug/.fingerprint/*/invoked.timestamp"))
            if entry.kind == "cargo"
            else list(entry.path.glob("build.db"))
        )
        if not witnesses:
            return None, "missing-witness"
        if any(w.is_symlink() or w.resolve() != w.absolute() for w in witnesses):
            return None, "unsafe-witness"
        finished = max(w.stat().st_mtime for w in witnesses)
    except OSError:
        return None, "unreadable-witness"
    return {
        "completedAt": finished,
        "lastUsed": finished,
        "historical": True,
    }, "complete"


def _unrelated_noncompiler_run(
    root: Path, run: Path, entry: CompilationDirectory
) -> bool:
    source = run / "source.json"
    if source.exists() or source.is_symlink():
        return False
    try:
        receipt = json.loads((run / "receipt.json").read_text())
        if (
            not isinstance(receipt, dict)
            or receipt.get("runId") != run.name
            or receipt.get("outputDirectory") != str(run.absolute())
        ):
            return False
        if receipt.get("kind") == "mac-bench-run":
            return True
        if receipt.get("kind") != "measurement-reservation":
            return False
        source = receipt.get("source")
        if not isinstance(source, str) or not Path(source).is_absolute():
            return False
        recorded = Path(source)
        mirror = (
            root / "worktrees" / entry.worktree.removeprefix("mirror:")
        ).absolute()
        if recorded.is_relative_to(mirror) or Path(
            str(recorded).casefold()
        ).is_relative_to(Path(str(mirror).casefold())):
            return False
        if recorded.is_symlink() or recorded.resolve() != recorded:
            return False
        anchor = mirror.stat()
        for ancestor in (recorded, *recorded.parents):
            info = ancestor.stat()
            if (info.st_dev, info.st_ino) == (anchor.st_dev, anchor.st_ino):
                return False
        return True
    except (OSError, ValueError):
        return False


def _mirror_completion(
    root: Path, entry: CompilationDirectory
) -> tuple[dict | None, str]:
    identity = entry.worktree.removeprefix("mirror:")
    evidence = []
    uses = []
    for run in (root / "runs").glob("*"):
        if _unrelated_noncompiler_run(root, run, entry):
            continue
        used = time.time()
        try:
            used = last_used(run, root, "runs")
            source = json.loads((run / "source.json").read_text())
            if not isinstance(source, dict) or not isinstance(
                source.get("worktreeId"), str
            ):
                raise TypeError("Unknown historical source identity")
            if source["worktreeId"] != identity:
                continue
            outcome = json.loads((run / "outcome.json").read_text())
            receipt = json.loads((run / "receipt.json").read_text())
            if not isinstance(outcome, dict) or not isinstance(receipt, dict):
                raise TypeError("Unknown historical result")
            finished = outcome["finishedAt"]
            if type(finished) not in (float, int) or not 0 < finished <= time.time():
                raise ValueError("Unknown historical completion time")
            used = max(used, finished)
            if (
                type(outcome.get("exitCode")) is not int
                or type(source.get("sourceModified")) is not bool
                or not isinstance(source.get("sourceCommit"), str)
            ):
                raise ValueError("Unknown historical source or completion")
            uses.append((used, source))
            directory = receipt.get("developerDirectory")
            if entry.kind != "cargo" and (
                not isinstance(directory, str)
                or hashlib.sha256(directory.encode()).hexdigest()[:12]
                not in entry.path.name
            ):
                continue
            evidence.append(finished)
        except (OSError, ValueError, KeyError, TypeError):
            uses.append((used, None))
    if not uses:
        return None, "no-associated-uses"
    latest = max(used for used, _ in uses)
    newest = [source for used, source in uses if used == latest]
    if any(source is None for source in newest):
        return None, "unknown-latest-use"
    if any(source != newest[0] for source in newest):
        return None, "ambiguous-latest-use"
    if not evidence:
        return None, "no-matching-toolchain"
    return {
        "completedAt": max(evidence),
        "lastUsed": max(latest, last_used(entry.path.parents[1], root, "worktrees")),
        "sourceCommit": newest[0]["sourceCommit"],
        "sourceModified": newest[0]["sourceModified"],
        "historical": True,
    }, "complete"


def _idle_compiler_use(root: Path, entry: CompilationDirectory) -> float | None:
    owner = entry.worktree.removeprefix("shared:")
    if owner in {"codex-fork-check", "codex-runtime"} and entry.path == root / owner / "target":
        try:
            paths = [entry.path, *entry.leases, *_compiler_payloads(entry)]
            return max(path.stat().st_mtime for path in paths if path.exists())
        except OSError:
            return None
    if _mirror_source(root, entry) is None:
        return None
    mirror = root / "worktrees" / entry.worktree.removeprefix("mirror:")
    try:
        marker = compilation_record(root, entry.path)
        return max(
            last_used(mirror, root, "worktrees"),
            marker.stat().st_mtime if marker.exists() else 0,
        )
    except OSError:
        return None


def _retired_worktree(
    root: Path, entry: CompilationDirectory, completion: dict
) -> bool:
    if entry.source is not None:
        source = entry.source
        command = ["git", "merge-base", "--is-ancestor", "HEAD", "origin/main"]
    else:
        source = Path.home() / "RemoteCoder"
        commit = completion.get("sourceCommit")
        if not isinstance(commit, str) or completion.get("sourceModified") is not False:
            return False
        command = ["git", "merge-base", "--is-ancestor", commit, "origin/main"]
    try:
        if subprocess.run(
            command,
            cwd=source,
            timeout=5,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode:
            return False
        return entry.source is None or not subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=no"],
            cwd=source,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return False


def _open_files(path: Path, snapshot: tuple[list[str], str | None]) -> bool:
    opened, error = snapshot
    prefix = str(path).casefold()
    return error is not None or any(
        name == prefix or name.startswith(prefix + "/") for name in opened
    )


def _open_file_snapshot() -> tuple[list[str], str | None]:
    try:
        result = subprocess.run(
            ["lsof", "-nP", "-Fn"], capture_output=True, timeout=15, check=False,
        )
    except subprocess.TimeoutExpired:
        return [], "open-file-probe-timeout"
    except (OSError, subprocess.SubprocessError):
        return [], "open-file-probe-unknown"
    if result.returncode != 0 or result.stderr:
        return [], "open-file-probe-unknown"
    return [os.fsdecode(line[1:]).casefold() for line in result.stdout.splitlines() if line.startswith(b"n/")], None


def _compiler_payloads(entry: CompilationDirectory) -> list[Path]:
    path = entry.path
    if entry.kind == "xcode":
        return [
            path / name
            for name in (
                "Build/Intermediates.noindex",
                "ModuleCache.noindex",
                "Index.noindex",
                "SDKExplicitPrecompiledModules",
                "SDKStatCaches.noindex",
            )
        ]
    if entry.kind == "cargo":
        profiles = [path / mode for mode in ("debug", "release")]
        profiles += [*path.glob("*/debug"), *path.glob("*/release")]
        return [
            profile / name
            for profile in dict.fromkeys(profiles)
            for name in ("incremental", "build", "deps", ".fingerprint")
        ]
    if entry.kind == "swift":
        return list(path.glob("*/*/*.build"))
    return []


def purge_xcode_environments(root: Path, worktrees: list[Path]) -> dict:
    derived = Path.home() / "Library/Developer/Xcode/DerivedData"
    entries = [entry for entry in compilation_directories(root, worktrees, derived) if entry.kind == "xcode"]
    for source in worktrees:
        lease = source_lease_path(source)
        for path in derived.glob(f"RemoteCoder-*-{lease.stem}"):
            entries.append(CompilationDirectory(path, "unowned-xcode:" + path.name, (lease,), None, "xcode"))
    for name in ("derived-ios", "derived-mac"):
        entries.append(CompilationDirectory(root / "release" / name, "release", (root / "release/build.lock",), None, "xcode"))
    result = {"removed": [], "protected": []}
    with file_lease(root / "leases/maintenance.lock"):
        opened, error = _open_file_snapshot()
        if error:
            raise ValueError(f"Cannot safely purge Xcode state: {error}")
        for entry in dict.fromkeys(entries):
            if not entry.path.exists():
                continue
            with ExitStack() as ownership:
                if any(ownership.enter_context(try_lease(lease)) is None for lease in entry.leases):
                    result["protected"].append({"path": str(entry.path), "reason": "leased"})
                    continue
                prefix = str(entry.path).casefold()
                if any(path == prefix or path.startswith(prefix + "/") for path in opened):
                    result["protected"].append({"path": str(entry.path), "reason": "open-files"})
                    continue
                device = _owner_device(root, entry)
                for relative in ("Build/Intermediates.noindex/XCBuildData", "XCBuildData", "Logs/Build"):
                    path = entry.path / relative
                    if path.exists():
                        _remove_cache_directory(path, device, _protected_name)
                        result["removed"].append(str(path))
    return result


@contextmanager
def _directory_descriptor(path: Path):
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.absolute().parts[1:]:
            next_fd = os.open(
                part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd
            )
            os.close(fd)
            fd = next_fd
        yield fd
    finally:
        os.close(fd)


def _protected_name(name: str) -> bool:
    return name in {
        "Products",
        "symbols",
        "perf-evidence",
        "receipt.json",
        "outcome.json",
    } or name.endswith((".app", ".xctest", ".dSYM", ".xcresult", ".trace"))


def _opened_child(parent: int, name: str, expected) -> int:
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    try:
        actual = os.fstat(fd)
        if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
            raise ValueError(f"Compilation directory replaced before opening: {name}")
        return fd
    except BaseException:
        os.close(fd)
        raise


def _product_evidence_name(name: str) -> bool:
    return _protected_name(name) and not name.endswith((".app", ".xctest", ".dSYM"))


def _protected_contents(directory: int, deadline: float, device: int, preserve) -> bool:
    if os.fstat(directory).st_dev != device:
        raise ValueError("Foreign mount in compilation payload")
    for name in os.listdir(directory):
        if time.monotonic() >= deadline:
            raise TimeoutError("Payload protection inventory timed out")
        if preserve(name):
            return True
        info = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if info.st_dev != device:
            raise ValueError("Foreign mount in compilation payload")
        if stat.S_ISDIR(info.st_mode):
            child = _opened_child(directory, name, info)
            try:
                if _protected_contents(child, deadline, device, preserve):
                    return True
            finally:
                os.close(child)
    return False


def _protected_payload(path: Path, deadline: float, device: int, preserve) -> bool:
    with _directory_descriptor(path) as directory:
        return _protected_contents(directory, deadline, device, preserve)


def _remove_contents(directory: int, device: int, preserve):
    if os.fstat(directory).st_dev != device:
        raise ValueError("Foreign mount during cache removal")
    for name in os.listdir(directory):
        info = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if info.st_dev != device or preserve(name):
            raise ValueError(f"Protected or foreign payload: {name}")
        if not stat.S_ISDIR(info.st_mode):
            os.unlink(name, dir_fd=directory)
            continue
        child = _opened_child(directory, name, info)
        try:
            _remove_contents(child, device, preserve)
            after = os.stat(name, dir_fd=directory, follow_symlinks=False)
            if (after.st_dev, after.st_ino) != (info.st_dev, info.st_ino):
                raise ValueError(f"Cache directory changed during eviction: {name}")
            os.rmdir(name, dir_fd=directory)
        finally:
            os.close(child)


def _evict_payload(entry: CompilationDirectory, path: Path, device: int):
    products = entry.path / "Build/Products"
    owned = _compiler_payloads(entry)
    if entry.kind == "xcode":
        owned.extend((products, entry.path / "SourcePackages"))
    if path not in owned or not path.is_relative_to(entry.path):
        raise ValueError(f"Unowned compilation payload: {path}")
    with _directory_descriptor(entry.path) as directory:
        if os.fstat(directory).st_dev != device:
            raise ValueError(f"Foreign mount at compilation directory: {entry.path}")

    preserve = _product_evidence_name if path == products else _protected_name
    _remove_cache_directory(path, device, preserve)


def _remove_cache_directory(path: Path, device: int, preserve):
    with _directory_descriptor(path.parent) as parent:
        info = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if info.st_dev != device or not stat.S_ISDIR(info.st_mode):
            raise ValueError(f"Unsafe compilation payload: {path}")
        child = _opened_child(parent, path.name, info)
        try:
            if _protected_contents(
                child, time.monotonic() + 20, device, preserve
            ):
                raise ValueError(f"Protected product or evidence in payload: {path}")
            after = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            if (after.st_dev, after.st_ino) != (info.st_dev, info.st_ino):
                raise ValueError(f"Compilation payload changed before deletion: {path}")
            _remove_contents(
                child, device, preserve
            )
            after = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            if (after.st_dev, after.st_ino) != (info.st_dev, info.st_ino):
                raise ValueError(f"Compilation payload changed during eviction: {path}")
            os.rmdir(path.name, dir_fd=parent)
        finally:
            os.close(child)


def compilation_admission(
    root: Path,
    policy: CachePolicy,
    entries: list[CompilationDirectory],
    current: set[Path],
    *,
    preview: bool,
    root_bytes: int | None = None,
    directory_bytes: dict[Path, int] | None = None,
) -> dict:
    with try_lease(root / "leases/maintenance.lock") as maintenance:
        return _compilation_admission(
            root, policy, entries, current, maintenance=maintenance, preview=preview,
            root_bytes=root_bytes, directory_bytes=directory_bytes,
        )


def _products_rebuildable(entry: CompilationDirectory, completion: dict, deadline: float) -> bool:
    commit = completion.get("sourceCommit")
    if (
        entry.kind != "xcode"
        or completion.get("sourceModified") is not False
        or not isinstance(commit, str)
        or len(commit) != 40
        or any(character not in "0123456789abcdef" for character in commit)
        or time.monotonic() >= deadline
    ):
        return False
    repository = entry.source or Path(__file__).resolve().parents[1]
    try:
        return (
            subprocess.run(
                ["git", "cat-file", "-e", commit + "^{commit}"],
                cwd=repository,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=min(2, max(0.001, deadline - time.monotonic())),
                check=False,
            ).returncode
            == 0
        )
    except (OSError, subprocess.SubprocessError):
        return False


def _package_resolution(derived: Path, deadline: float) -> bytes | None:
    packages = derived / "SourcePackages"
    resolution = (
        derived.parent
        / "repo/RemoteCoder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    )
    try:
        if (
            not _real_directory(packages)
            or resolution.is_symlink()
            or not {path.name for path in packages.iterdir()}
            <= {"artifacts", "checkouts", "repositories", "workspace-state.json"}
        ):
            return None
        data = resolution.read_bytes()
        pins = json.loads(data)["pins"]
        expected = {
            pin["identity"].casefold(): pin["state"]["revision"] for pin in pins
        }
        checkouts = packages / "checkouts"
        if not expected or not _real_directory(checkouts):
            return None
        paths = list(checkouts.iterdir())
        if {path.name.casefold() for path in paths} != set(expected):
            return None
        for path in paths:
            if not _real_directory(path) or time.monotonic() >= deadline:
                return None
            command = [
                "git",
                "--no-optional-locks",
                "-C",
                str(path),
                "-c",
                "core.fsmonitor=false",
            ]
            for arguments, output in (
                (["rev-parse", "HEAD"], expected[path.name.casefold()].encode()),
                (
                    ["status", "--porcelain=v1", "--untracked-files=all", "--ignored"],
                    b"",
                ),
            ):
                result = subprocess.run(
                    command + arguments,
                    capture_output=True,
                    timeout=min(2, max(0.001, deadline - time.monotonic())),
                    check=True,
                )
                if result.stdout.strip() != output:
                    return None
        return data
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        subprocess.SubprocessError,
    ):
        return None


def _snapshot_expired(
    directory: int, cutoff: float, device: int, deadline: float
) -> bool:
    if os.fstat(directory).st_dev != device or os.fstat(directory).st_mtime > cutoff:
        return False
    for name in os.listdir(directory):
        if time.monotonic() >= deadline:
            raise TimeoutError("Snapshot age inventory timed out")
        info = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if info.st_dev != device or info.st_mtime > cutoff:
            return False
        if stat.S_ISDIR(info.st_mode):
            child = _opened_child(directory, name, info)
            try:
                if not _snapshot_expired(child, cutoff, device, deadline):
                    return False
            finally:
                os.close(child)
    return True


def _retire_snapshots(root: Path, *, preview: bool) -> dict:
    result = {"retentionDays": 7, "candidates": [], "removed": [], "protected": []}
    home = root.parents[2]
    try:
        pointers = [
            home / "localbin/remote-coder-gateway" / name
            for name in ("current", "previous", "remote-coder-codex-gateway")
        ]
        pointers += [
            home / ".codex/packages/standalone/current",
            Path("/Applications/ChatGPT.app"),
            Path(__file__),
        ]
        pins = [path.resolve() for path in pointers]
        job = subprocess.run(
            [
                "launchctl",
                "print",
                f"gui/{os.getuid()}/com.remote-coder.shared-codex-install",
            ],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        idle = (
            job.returncode == 0
            and any(
                line.strip() == "state = not running"
                for line in job.stdout.splitlines()
            )
        ) or (job.returncode != 0 and "Could not find service" in job.stderr)
        opened = _open_file_snapshot()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        return {**result, "deferred": str(error)}
    cutoff = time.time() - 7 * 86400
    deadline = time.monotonic() + 20
    for category in ("rollback", "deploy"):
        directory = root / category
        if not _real_directory(directory):
            continue
        for path in directory.iterdir():
            try:
                if not _real_directory(path):
                    raise ValueError("unknown snapshot path")
                children = {item.name for item in path.iterdir()}
                known = (
                    children == {"source", "package", "gateway"}
                    if category == "deploy"
                    else bool(children)
                    and children
                    <= {
                        "codex-package",
                        "ChatGPT.app",
                        "ChatGPT-host.app",
                        "RemoteCoderGateway.app",
                        "remote-coder-codex-gateway",
                        "compatibility.json",
                        "receipt.json",
                    }
                )
                if not known or (category == "deploy" and not idle):
                    raise ValueError("unknown layout or active/unknown installer")
                if (
                    any(pin == path or pin.is_relative_to(path) for pin in pins)
                    or (category == "deploy" and str(path) in job.stdout)
                    or _open_files(path, opened)
                ):
                    raise ValueError("referenced or open snapshot")
                with try_lease(lease_path(root, category, path.name)) as lease:
                    if lease is None:
                        raise ValueError("leased snapshot")
                    with _directory_descriptor(path) as descriptor:
                        device = os.fstat(descriptor).st_dev
                        if device != root.stat().st_dev or not _snapshot_expired(
                            descriptor, cutoff, device, deadline
                        ):
                            raise ValueError("recent, changed or unknown snapshot")
                        expected = os.fstat(descriptor)
                    current = path.stat(follow_symlinks=False)
                    if (current.st_dev, current.st_ino) != (
                        expected.st_dev,
                        expected.st_ino,
                    ):
                        raise ValueError("replaced snapshot")
                    result["candidates"].append(str(path))
                    if not preview:
                        _remove_cache_directory(path, device, lambda _: False)
                        result["removed"].append(str(path))
            except (OSError, ValueError, TimeoutError) as error:
                result["protected"].append({"path": str(path), "reason": str(error)})
    return result


def _compilation_admission(
    root: Path,
    policy: CachePolicy,
    entries: list[CompilationDirectory],
    current: set[Path],
    *,
    maintenance: int | None,
    preview: bool,
    root_bytes: int | None = None,
    directory_bytes: dict[Path, int] | None = None,
) -> dict:
    current = {canonical_path(path) for path in current}
    started = time.monotonic()
    result = {
        "capturedAt": datetime.now().astimezone().isoformat(),
        "budgetBytes": policy.compilation_budget_bytes,
        "budgetScope": str(root) if root_bytes is not None else "compiler-estimate",
        "allocatedBytes": root_bytes if root_bytes is not None else 0,
        "rootAllocatedBytes": root_bytes,
        "rootInventoryComplete": root_bytes is not None,
        "compilerAllocatedBytes": 0,
        "inventoryComplete": True,
        "inventory": [],
        "candidates": [],
        "evicted": [],
        "protected": [],
        "preview": preview or not policy.eviction_enabled,
    }
    proofs = {}
    devices = {}

    def merged(entry, completion):
        key = (
            entry.worktree,
            entry.source,
            completion.get("sourceCommit"),
            completion.get("sourceModified"),
        )
        if key not in proofs:
            if time.monotonic() >= deadline:
                proofs[key] = False, "deadline"
            else:
                retired = _retired_worktree(root, entry, completion)
                proofs[key] = retired, "proven" if retired else "not-proven"
        return proofs[key]

    with ExitStack() as ownership:
        deadline = time.monotonic() + 20
        result["freeBytesBefore"] = shutil.disk_usage(root).free
        deferred = (
            "maintenance-lease-contended" if maintenance is None else
            "eviction-disabled-and-free-space-target-met"
            if not preview and not policy.eviction_enabled
            and result["freeBytesBefore"] >= policy.eviction_target_free_bytes
            else None
        )
        if deferred:
            result.update(
                {
                    "inventoryDeferred": deferred,
                    "inventoryComplete": False,
                    "allocatedBytes": None,
                    "knownAllocatedBytes": None,
                    "projectedBytes": None,
                    "initialKnownOverflowBytes": None,
                    "unsatisfiedBudgetBytes": None,
                    "successfullyEvictedBytes": 0,
                    "remainingBytes": None,
                    "warning": f"Compilation cache inventory deferred: {deferred}; allocation and soft-budget status are unknown. Admission continues subject to the free-space floor.",
                }
            )
            for entry in entries:
                result["inventory"].append(
                    {
                        "path": str(entry.path),
                        "kind": entry.kind,
                        "worktree": entry.worktree,
                        "allocatedBytes": None,
                        "allocationCoverage": "not-evaluated",
                        "completionRecord": str(compilation_record(root, entry.path)),
                        "completionCoverage": {
                            "record": "not-evaluated",
                            "historical": "not-evaluated",
                            "sourceRetirement": "not-evaluated",
                        },
                    }
                )
                result["protected"].append(
                    {
                        "path": str(entry.path),
                        "allocatedBytes": None,
                        "reason": "inventory-deferred",
                    }
                )
            result["freeBytesAfter"] = shutil.disk_usage(root).free
            result["elapsedSeconds"] = round(time.monotonic() - started, 3)
            return result
        legacy = _legacy_compilation_records(root, deadline)
        ordered = []
        for index, entry in enumerate(entries):
            if not entry.path.is_relative_to(root):
                result["inventory"].append(
                    {
                        "path": str(entry.path),
                        "kind": entry.kind,
                        "worktree": entry.worktree,
                        "allocatedBytes": None,
                        "allocationCoverage": "outside-budget",
                        "completionCoverage": {
                            "record": "not-evaluated",
                            "historical": "not-evaluated",
                            "sourceRetirement": "not-evaluated",
                        },
                    }
                )
                result["protected"].append(
                    {
                        "path": str(entry.path),
                        "allocatedBytes": None,
                        "reason": "outside-build-cache",
                    }
                )
                continue
            try:
                devices[entry] = _owner_device(root, entry)
                if not _real_directory(entry.path):
                    size, allocation = None, "unsafe-or-missing"
                elif directory_bytes is not None and entry.path in directory_bytes:
                    size, allocation = directory_bytes[entry.path], "complete"
                else:
                    now = time.monotonic()
                    allocation_deadline = now + max(0, deadline - now) / (len(entries) - index)
                    size = _allocated_bytes(entry.path, allocation_deadline, devices[entry])
                    allocation = "complete"
            except TimeoutError:
                size = None
                allocation = "deadline"
            except (OSError, ValueError):
                size = None
                allocation = "unavailable"
            if size is None:
                result["inventoryComplete"] = False
            else:
                result["compilerAllocatedBytes"] += size
                if not result["rootInventoryComplete"]:
                    result["allocatedBytes"] += size
            completion, record = _completion(root, entry, legacy)
            coverage = {"record": record, "historical": None, "sourceRetirement": None}
            if completion is None and record == "missing":
                if size is None or time.monotonic() >= deadline:
                    coverage["historical"] = "not-evaluated"
                else:
                    completion, coverage["historical"] = _historical_completion(
                        root, entry
                    )
                    if completion is not None:
                        proven, coverage["sourceRetirement"] = merged(entry, completion)
                        if not proven:
                            completion = None
            if completion is None and record in {"missing", "active"}:
                used = _idle_compiler_use(root, entry)
                if (
                    used is not None
                    and time.time() - used >= policy.compiler_protection_seconds
                ):
                    completion = {
                        "lastUsed": used,
                        "completedAt": used,
                        "abandoned": True,
                    }
                    coverage["abandonment"] = (
                        "idle-owned-compiler-requires-lease-and-open-file-check"
                    )
            result["inventory"].append(
                {
                    "path": str(entry.path),
                    "kind": entry.kind,
                    "worktree": entry.worktree,
                    "allocatedBytes": size,
                    "allocationCoverage": allocation,
                    "completionRecord": str(compilation_record(root, entry.path)),
                    "completionCoverage": coverage,
                }
            )
            ordered.append((entry, size, completion))
        owned_leases = {}
        for entry, size, completion in ordered:
            if (
                size is None or completion is None
                or canonical_path(entry.path) in current
                or time.time() - completion["lastUsed"] < policy.compiler_protection_seconds
            ):
                continue
            for lease in entry.leases:
                if lease not in owned_leases:
                    owned_leases[lease] = ownership.enter_context(try_lease(lease))
        opened = _open_file_snapshot() if any(fd is not None for fd in owned_leases.values()) else ([], None)
        lease_names = {str(path).casefold() for path, fd in owned_leases.items() if fd is not None}
        opened = ([name for name in opened[0] if name not in lease_names], opened[1])
        removed = set()
        pressure = (
            result["allocatedBytes"] > policy.compilation_budget_bytes
            or result["freeBytesBefore"] < policy.eviction_target_free_bytes
        )
        package_resolutions = {}
        if pressure:
            package_deadline = time.monotonic() + 20
            for entry, _, completion in sorted(
                ordered,
                key=lambda item: item[2]["lastUsed"] if item[2] else 0,
                reverse=True,
            ):
                if (
                    entry.kind == "xcode"
                    and (entry.path / "SourcePackages").exists()
                    and completion is not None
                    and entry.leases
                    and all(
                        owned_leases.get(lease) is not None for lease in entry.leases
                    )
                    and not _open_files(entry.path, opened)
                ):
                    resolution = _package_resolution(entry.path, package_deadline)
                    if resolution is not None:
                        package_resolutions[entry.path] = resolution
        package_seeds = {}
        for path, resolution in package_resolutions.items():
            package_seeds.setdefault(resolution, []).append(path)
        retained_packages = {path for paths in package_seeds.values() for path in paths[:policy.retained_completed_directories]}
        representatives = {entry.worktree: entry for entry, _, _ in ordered}
        for worktree, entry in representatives.items():
            if time.monotonic() < deadline and _removed_mirror_source(
                root, entry, check_remote=not pressure
            ):
                removed.add(worktree)
        newest = {}
        for entry, size, completion in ordered:
            if completion is not None:
                newest.setdefault(entry.worktree, []).append(
                    (completion["completedAt"], entry.path)
                )
        worktree_entries = {}
        unknown_worktrees = set()
        for entry, _, completion in ordered:
            if completion is None and entry.kind != "protected":
                unknown_worktrees.add(entry.worktree)
            if completion is not None:
                worktree_entries.setdefault(entry.worktree, []).append(
                    (entry, completion)
                )
        retired = {
            worktree
            for worktree, group in worktree_entries.items()
            if worktree not in unknown_worktrees
            and not any(c.get("abandoned") for _, c in group)
            and time.time() - max(c["lastUsed"] for _, c in group)
            > policy.retired_worktree_seconds
            and all(
                merged(entry, completion)[0]
                for entry, completion in group
                if completion["lastUsed"] == max(c["lastUsed"] for _, c in group)
            )
        }
        for worktree in tuple(retired):
            representative = next(
                entry for entry, _, _ in ordered if entry.worktree == worktree
            )
            source = representative.source or representative.path.parents[1]
            if time.monotonic() >= deadline or _open_files(source, opened):
                retired.remove(worktree)
        retained = {
            path
            for worktree, group in newest.items()
            if worktree not in retired and worktree not in removed
            for _, path in sorted(group, reverse=True)[
                : policy.retained_completed_directories
            ]
        }
        projected = result["allocatedBytes"]
        deadline = time.monotonic() + 20
        for entry, size, completion in sorted(
            ordered,
            key=lambda item: (
                item[0].path in retained,
                item[2]["lastUsed"] if item[2] else float("inf"),
            ),
        ):
            reason = (
                "unknown-completion"
                if completion is None
                else "retained-newest"
                if entry.path in retained
                and projected <= policy.compilation_budget_bytes
                and result["freeBytesBefore"] >= policy.eviction_target_free_bytes
                else "recent"
                if time.time() - completion["lastUsed"]
                < policy.compiler_protection_seconds
                else "current"
                if canonical_path(entry.path) in current
                else "unknown-size"
                if size is None
                else None
            )
            if reason is None and (
                not entry.leases
                or any(
                    owned_leases.get(lease) is None
                    for lease in entry.leases
                )
            ):
                reason = "leased"
            if reason is None and time.monotonic() >= deadline:
                reason = "reclamation-deadline"
            if reason is None and (
                not _real_directory(entry.path)
                or (not entry.worktree.startswith("shared:") and _open_files(entry.path, opened))
            ):
                reason = "open-or-unknown-files"
            if reason is None and entry.worktree in retired:
                group = worktree_entries[entry.worktree]
                last = max(c["lastUsed"] for _, c in group)
                if not all(
                    _retired_worktree(root, e, c)
                    for e, c in group
                    if c["lastUsed"] == last
                ):
                    reason = "changed-retirement-evidence"
            if (
                reason is None
                and completion.get("historical")
                and (
                    _historical_completion(root, entry)[0] != completion
                    or not _retired_worktree(root, entry, completion)
                )
            ):
                reason = "changed-historical-evidence"
            if (
                reason is None
                and not completion.get("historical")
                and not completion.get("abandoned")
                and _completion(root, entry, legacy)[0] != completion
            ):
                reason = "changed-completion"
            if (
                reason is None
                and completion.get("abandoned")
                and _idle_compiler_use(root, entry) != completion["lastUsed"]
            ):
                reason = "changed-abandonment-evidence"
            if reason is not None:
                result["protected"].append(
                    {
                        "path": str(entry.path),
                        "allocatedBytes": size,
                        "reason": reason,
                    }
                )
                continue
            removed_source = entry.worktree in removed and _removed_mirror_source(
                root, entry, check_remote=not pressure
            )
            payloads = _compiler_payloads(entry)
            products = entry.path / "Build/Products"
            if pressure and _products_rebuildable(entry, completion, deadline):
                payloads.append(products)
            if entry.path in package_resolutions and entry.path not in retained_packages and _package_resolution(entry.path, deadline) == package_resolutions[entry.path]:
                payloads.append(entry.path / "SourcePackages")
            for payload in payloads:
                if not payload.exists() and not payload.is_symlink():
                    continue
                try:
                    if not _real_directory(payload):
                        raise ValueError(f"Unsafe payload: {payload}")
                    state = opened[1] or ("open-files" if _open_files(payload, opened) else None)
                    if state:
                        result["protected"].append({"path": str(payload), "allocatedBytes": None, "reason": state})
                        continue
                    payload_bytes = _allocated_bytes(
                        payload, deadline, devices[entry]
                    )
                    reclaimable_bytes = _reclaimable_bytes(payload, deadline, devices[entry])
                    preserve = _product_evidence_name if payload == products else _protected_name
                    if _protected_payload(payload, deadline, devices[entry], preserve):
                        raise ValueError(
                            f"Protected product or evidence in payload: {payload}"
                        )
                except TimeoutError:
                    result["protected"].append(
                        {
                            "path": str(payload),
                            "allocatedBytes": None,
                            "reason": "reclamation-deadline",
                        }
                    )
                    continue
                except (OSError, ValueError):
                    result["protected"].append(
                        {
                            "path": str(payload),
                            "allocatedBytes": None,
                            "reason": "unsafe-or-incomplete-payload",
                        }
                    )
                    continue
                if (
                    not removed_source
                    and projected <= policy.compilation_budget_bytes
                    and (
                        result["freeBytesBefore"]
                        + result["allocatedBytes"]
                        - projected
                        if result["preview"]
                        else shutil.disk_usage(root).free
                    )
                    >= policy.eviction_target_free_bytes
                ):
                    continue
                candidate = {
                    "path": str(payload),
                    "allocatedBytes": payload_bytes,
                    "worktree": entry.worktree,
                    "lastUsed": completion["lastUsed"],
                    "estimatedReclaimedBytes": reclaimable_bytes,
                }
                result["candidates"].append(candidate)
                if result["preview"]:
                    projected -= reclaimable_bytes
                else:
                    try:
                        _evict_payload(entry, payload, devices[entry])
                    except (OSError, ValueError, TimeoutError) as error:
                        result.setdefault("evictionFailures", []).append(
                            {
                                "path": str(payload),
                                "error": str(error),
                                "partialRemovalPossible": True,
                            }
                        )
                        result["inventoryComplete"] = False
                    else:
                        projected -= reclaimable_bytes
                        result["evicted"].append(candidate)
                        if entry.kind == "cargo" and payload.name == "deps":
                            (entry.path.parent / "cargo-seed-key").unlink(
                                missing_ok=True
                            )
        result["knownAllocatedBytes"] = result["allocatedBytes"]
        result["projectedBytes"] = projected if result["inventoryComplete"] else None
        if not result["inventoryComplete"]:
            result["allocatedBytes"] = None
        result["initialKnownOverflowBytes"] = max(
            0, result["knownAllocatedBytes"] - policy.compilation_budget_bytes
        )
        result["unsatisfiedBudgetBytes"] = (
            max(0, projected - policy.compilation_budget_bytes)
            if result["inventoryComplete"]
            else None
        )
        result["successfullyEvictedBytes"] = sum(
            c["estimatedReclaimedBytes"] for c in result["evicted"]
        )
        result["remainingBytes"] = (
            (result["knownAllocatedBytes"] if result["preview"] else projected)
            if result["inventoryComplete"]
            else None
        )
        if result["unsatisfiedBudgetBytes"] or not result["inventoryComplete"]:
            scope = "RemoteCoder-Build total cap" if root_bytes is not None else "Compiler allocation estimate"
            result["warning"] = (
                scope + " is unsatisfied or incomplete; protected data was preserved. Admission continues subject to the free-space floor."
            )
        result["freeBytesAfter"] = shutil.disk_usage(root).free
        result["elapsedSeconds"] = round(time.monotonic() - started, 3)
        return result


def lease_path(root: Path, category: str, identity: str) -> Path:
    return root / "leases" / category / (identity + ".lock")


@contextmanager
def try_lease(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield None
        else:
            yield stream.fileno()


def last_used(path: Path, root: Path, category: str) -> float:
    marker = lease_path(root, category, path.name).with_suffix(".used")
    paths = [path, marker, *path.glob("*/build.lock"), *path.glob("*/repo")]
    paths.extend(
        path.glob("*/derived-*/Build/Intermediates.noindex/XCBuildData/build.db")
    )
    paths.extend(path.glob("*/swift-*/build.db"))
    return max(p.stat().st_mtime for p in paths if p.exists())


def touch_usage(root: Path, category: str, identity: str):
    marker = lease_path(root, category, identity).with_suffix(".used")
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.touch()


def _legacy_locks(path: Path) -> list[Path]:
    return [
        group / "build.lock"
        for group in path.iterdir()
        if _real_directory(group)
        and not (group / "build.lock").is_symlink()
        and (group / "build.lock").is_file()
    ]


def _run_is_terminal(path: Path) -> bool:
    found = False
    for name in ("receipt.json", "outcome.json"):
        record = path / name
        if not record.exists():
            continue
        try:
            value = json.loads(record.read_text())
        except (OSError, ValueError):
            return False
        if not isinstance(value, dict) or type(value.get("exitCode")) is not int:
            return False
        found = True
    return found


def _prune_removed_mirrors(
    root: Path, policy: CachePolicy, current: str, *, preview: bool
) -> dict:
    result = {"mirrorCandidates": [], "mirrors": []}
    mirrors = root / "worktrees"
    if not _real_directory(mirrors):
        return result
    deadline = time.monotonic() + 20
    with ExitStack() as ownership:
        candidates = []
        for mirror in mirrors.iterdir():
            if mirror.name == current or not _real_directory(mirror):
                continue
            payloads = [
                path
                for group in ("ios", "gateway")
                if _real_directory(mirror / group)
                for path in (mirror / group).iterdir()
                if path.name in {"repo", "cargo"}
                or path.name.startswith(("derived-", "swift-"))
            ]
            if not payloads:
                continue
            try:
                if time.time() - last_used(mirror, root, "worktrees") < policy.evidence_protection_seconds:
                    continue
            except OSError:
                continue
            entry = CompilationDirectory(mirror, "mirror:" + mirror.name, (), None, "protected")
            if time.monotonic() >= deadline or not _removed_mirror_source(root, entry, check_remote=True):
                continue
            locks = (lease_path(root, "worktrees", mirror.name), *_legacy_locks(mirror))
            if any(ownership.enter_context(try_lease(lock)) is None for lock in locks):
                continue
            candidates.append((mirror, entry, payloads))
        opened = _open_file_snapshot() if candidates else ([], None)
        deadline = time.monotonic() + 20
        for mirror, entry, payloads in candidates:
            try:
                used = last_used(mirror, root, "worktrees")
                if time.time() - used < policy.evidence_protection_seconds:
                    continue
                with _directory_descriptor(root) as cache:
                    device = os.fstat(cache).st_dev
                if (
                    not _removed_mirror_source(root, entry, check_remote=True)
                    or last_used(mirror, root, "worktrees") != used
                ):
                    continue
                for payload in payloads:
                    if not _real_directory(payload) or _open_files(payload, opened):
                        continue
                    payload_bytes = _allocated_bytes(payload, deadline, device)
                    candidate = {"path": str(payload), "allocatedBytes": payload_bytes, "lastUsed": used}
                    result["mirrorCandidates"].append(candidate)
                    if policy.eviction_enabled and not preview:
                        _remove_cache_directory(payload, device, lambda _: False)
                        result["mirrors"].append(candidate)
            except (OSError, ValueError, TimeoutError) as error:
                result.setdefault("evictionFailures", []).append({"path": str(mirror), "error": str(error)})
    return result


def prune_caches(
    root: Path, policy: CachePolicy, worktree: str, run: str, *, preview: bool = False
) -> dict:
    with try_lease(root / "leases/maintenance.lock") as maintenance:
        return _prune_caches(root, policy, worktree, run, maintenance=maintenance, preview=preview)


def _prune_caches(
    root: Path, policy: CachePolicy, worktree: str, run: str, *, maintenance: int | None, preview: bool
) -> dict:
    removed = {"runs": []}
    with ExitStack() as ownership:
        if maintenance is None:
            return {"runs": [], "retentionDeferred": "maintenance-lease-contended"}
        deadline = time.monotonic() + 20
        directory = root / "runs"
        paths = []
        if _real_directory(directory):
            with os.scandir(directory) as listing:
                paths = [Path(item.path) for item in listing if item.is_dir(follow_symlinks=False)]
        count = len(paths)
        measured = []
        for index, path in enumerate(paths):
            if time.monotonic() >= deadline:
                removed["unprobedRuns"] = [item.name for item in paths[index:]]
                break
            if path.name == run or not _real_directory(path):
                continue
            with ExitStack() as candidate:
                lease = candidate.enter_context(try_lease(lease_path(root, "runs", path.name)))
                if lease is None:
                    removed.setdefault("leasedRuns", []).append(path.name)
                    continue
                used = last_used(path, root, "runs")
                if time.monotonic() >= deadline:
                    removed["unprobedRuns"] = [item.name for item in paths[index:]]
                    break
                if time.time() - used < policy.evidence_protection_seconds:
                    continue
                if not _run_is_terminal(path):
                    removed.setdefault("unknownRuns", []).append(path.name)
                    continue
                ownership.enter_context(candidate.pop_all())
                measured.append((used, path))
        deadline = time.monotonic() + 20
        for used, path in sorted(measured):
            age = time.time() - used
            if count <= policy.max_runs and age < policy.run_retention_seconds:
                continue
            if time.monotonic() >= deadline:
                removed.setdefault("unreclaimedRuns", []).append(path.name)
                continue
            with _directory_descriptor(root) as cache:
                deleting = False
                try:
                    with (
                        _directory_descriptor(path.parent) as parent,
                    ):
                        device = os.fstat(cache).st_dev
                        info = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
                        if info.st_dev != device or os.fstat(parent).st_dev != device:
                            raise ValueError("Foreign mount in run evidence")
                        child = _opened_child(parent, path.name, info)
                        try:
                            _tree_bytes(child, deadline, device, exclude_linked=False)
                            after = os.stat(
                                path.name, dir_fd=parent, follow_symlinks=False
                            )
                            if (after.st_dev, after.st_ino) != (
                                info.st_dev,
                                info.st_ino,
                            ):
                                raise ValueError(
                                    "Run evidence replaced before deletion"
                                )
                            removed.setdefault("runCandidates", []).append(str(path))
                            if not preview:
                                deleting = True
                                _remove_contents(child, device, lambda _: False)
                                after = os.stat(
                                    path.name, dir_fd=parent, follow_symlinks=False
                                )
                                if (after.st_dev, after.st_ino) != (
                                    info.st_dev,
                                    info.st_ino,
                                ):
                                    raise ValueError(
                                        "Run evidence replaced during deletion"
                                    )
                                os.rmdir(path.name, dir_fd=parent)
                                removed["runs"].append(path.name)
                                count -= 1
                        finally:
                            os.close(child)
                except (OSError, ValueError, TimeoutError) as error:
                    removed.setdefault("unknownRuns", []).append(path.name)
                    removed.setdefault("evictionFailures", []).append(
                        {
                            "path": str(path),
                            "error": str(error),
                            "partialRemovalPossible": deleting,
                        }
                    )
        if count > policy.max_runs:
            removed["protectedOverBudget"] = {"runs": count - policy.max_runs}
        mirrors = _prune_removed_mirrors(root, policy, worktree, preview=preview)
        for key, values in mirrors.items():
            if values:
                removed.setdefault(key, []).extend(values)
    return removed


def seed_source_packages(
    root: Path, current: str, source: Path, derived: Path
) -> dict | None:
    resolution = source / "RemoteCoder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    target = derived / "SourcePackages"
    if target.exists() or not resolution.is_file():
        return None
    with try_lease(root / "leases/maintenance.lock") as maintenance:
        if maintenance is None:
            return None
        return _seed_packages_locked(root, current, resolution, derived, target)


def _seed_packages_locked(
    root: Path, current: str, resolution: Path, derived: Path, target: Path
) -> dict | None:
    worktrees = root / "worktrees"
    candidates = [
        p
        for p in worktrees.iterdir()
        if p.name != current and p.is_dir() and not p.is_symlink()
    ]
    candidates.sort(key=lambda p: last_used(p, root, "worktrees"), reverse=True)
    for sibling in candidates:
        with ExitStack() as locks:
            if (
                locks.enter_context(
                    try_lease(lease_path(root, "worktrees", sibling.name))
                )
                is None
            ):
                continue
            if locks.enter_context(try_lease(sibling / "ios/build.lock")) is None:
                continue
            sibling_resolution = sibling / "ios/repo/RemoteCoder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            if (
                not sibling_resolution.is_file()
                or sibling_resolution.read_bytes() != resolution.read_bytes()
            ):
                continue
            packages = next(
                (
                    p / "SourcePackages"
                    for p in (sibling / "ios").glob("derived-*")
                    if _package_resolution(p, time.monotonic() + 5) == resolution.read_bytes()
                ),
                None,
            )
            if packages is None:
                continue
            started = time.monotonic()
            derived.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(
                prefix="packages-", dir=derived
            ) as staging:
                clone = Path(staging) / "SourcePackages"
                subprocess.run(["cp", "-cR", str(packages), str(clone)], check=True)
                (clone / "workspace-state.json").unlink(missing_ok=True)
                clone.rename(target)
            touch_usage(root, "worktrees", sibling.name)
            return {
                "sourceWorktree": sibling.name,
                "seconds": round(time.monotonic() - started, 3),
            }
    return None


def cargo_seed_key(source: Path, environment: dict[str, str]) -> str | None:
    if not (source / "host-daemon-rs/Cargo.lock").is_file():
        return None
    digest = hashlib.sha256(
        subprocess.check_output(["rustc", "-Vv"], cwd=source, env=environment)
    )
    for path in (
        source / "host-daemon-rs/Cargo.lock",
        source / "host-daemon-rs/Cargo.toml",
        source / "rust-toolchain.toml",
        source / ".cargo/config.toml",
        Path.home() / ".cargo/config.toml",
    ):
        digest.update(path.name.encode() + b"\0")
        digest.update(path.read_bytes() if path.is_file() else b"absent")
    return digest.hexdigest()


def seed_cargo(
    root: Path,
    current: str,
    key: str | None,
    target: Path,
    manifest: Path,
    environment: dict[str, str],
) -> dict | None:
    if key is None or target.exists():
        return None
    with try_lease(root / "leases/maintenance.lock") as maintenance:
        if maintenance is None:
            return None
        return _seed_cargo_locked(root, current, key, target, manifest, environment)


def _seed_cargo_locked(
    root: Path,
    current: str,
    key: str,
    target: Path,
    manifest: Path,
    environment: dict[str, str],
) -> dict | None:
    siblings = [
        p
        for p in (root / "worktrees").iterdir()
        if p.name != current and p.is_dir() and not p.is_symlink()
    ]
    siblings.sort(key=lambda p: last_used(p, root, "worktrees"), reverse=True)
    for sibling in siblings:
        with ExitStack() as locks:
            if (
                locks.enter_context(
                    try_lease(lease_path(root, "worktrees", sibling.name))
                )
                is None
            ):
                continue
            if any(
                locks.enter_context(try_lease(p)) is None
                for p in sibling.glob("*/build.lock")
            ):
                continue
            marker = sibling / "gateway/cargo-seed-key"
            source = sibling / "gateway/cargo"
            if (
                not marker.is_file()
                or marker.read_text().strip() != key
                or not source.is_dir()
                or source.is_symlink()
            ):
                continue
            started = time.monotonic()
            published = False
            cleanup_warning = None
            try:
                operation = "prepare"
                target.parent.mkdir(parents=True, exist_ok=True)
                with tempfile.TemporaryDirectory(
                    prefix="cargo-", dir=target.parent
                ) as staging:
                    clone = Path(staging) / "cargo"
                    operation = "copy"
                    subprocess.run(["cp", "-cR", str(source), str(clone)], check=True)
                    profiles = ("dev", "release")
                    operation = "clean"
                    for profile in profiles:
                        subprocess.run(
                            [
                                "cargo",
                                "clean",
                                "--offline",
                                "--locked",
                                "--manifest-path",
                                str(manifest),
                                "--target-dir",
                                str(clone),
                                "--package",
                                "remote-coder-codex-gateway",
                                "--profile",
                                profile,
                            ],
                            cwd=manifest.parent,
                            env=dict(
                                environment,
                                CARGO_TARGET_DIR=str(clone),
                                CARGO_BUILD_BUILD_DIR=str(clone),
                            ),
                            check=True,
                        )
                    operation = "publish"
                    clone.rename(target)
                    published = True
                    operation = "cleanup"
            except (OSError, subprocess.CalledProcessError) as error:
                if not published:
                    return {
                        "status": "unseeded",
                        "sourceWorktree": sibling.name,
                        "seconds": round(time.monotonic() - started, 3),
                        "failure": {
                            "operation": operation,
                            "cause": str(error),
                            "exitCode": getattr(error, "returncode", None),
                        },
                    }
                cleanup_warning = str(error)
            touch_usage(root, "worktrees", sibling.name)
            result = {
                "sourceWorktree": sibling.name,
                "seconds": round(time.monotonic() - started, 3),
                "workspaceProfilesInvalidated": list(profiles),
                "status": "seeded",
            }
            if cleanup_warning is not None:
                result["cleanupWarning"] = cleanup_warning
            return result
    return None
