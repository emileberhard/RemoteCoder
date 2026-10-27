#!/usr/bin/env python3
"""Own this Mac's release cache: admission, the Mini's published release, the MacBook catch-up and the Mac release reference."""

import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import gateway_bundle
from build_artifacts import reuse_installed, tree_digest
from build_support import cache_root, file_lease
from maintainer_config import load as maintainer_config
from release_tag import require_main_ancestor

RELEASES_IN_HOME = Path("Library/Caches/RemoteCoder-Build/releases")
RELEASES = Path.home() / RELEASES_IN_HOME
DEPLOYMENTS = Path.home() / "Library/Logs/remote-coder/deployments"
INSTALLED_GATEWAY = Path.home() / "localbin/remote-coder-gateway/remote-coder-codex-gateway"
CONFIG = "Contents/Resources/RemoteCoderLocalConfig.json"
VERSION = r"(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})"
COMMIT = r"[0-9a-f]{40}"
FINGERPRINT = r"(tree|sha256):[0-9a-f]{64}"
TEAM = maintainer_config().get("xcodeSettings", {}).get("DEVELOPMENT_TEAM", "")
APP_IDENTIFIER = maintainer_config().get("xcodeSettings", {}).get("RC_BUNDLE_ID", "com.example.RemoteCoder")
MAC_APP = "RemoteCoderMac-direct.app"
MAC_PACKAGE = "RemoteCoderMac.pkg"
MIRRORED = ("build-numbers", "gateway", "mac-app", "mac-package", "ios-symbols", "mac-symbols")
COMPONENTS = ("gateway", "app")
SYMBOL_DIRECTORY = rf"testflight-(?:ios|mac)-({VERSION})-[0-9]+"
SYMBOL_WINDOW_SECONDS = 7 * 24 * 3600
SYMBOL_BYTE_CAP = 5 * 1024**3


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def version_key(version: str) -> tuple[int, ...]:
    if not isinstance(version, str) or re.fullmatch(VERSION, version) is None:
        raise ValueError(f"{version} is not X.Y.Z with each part 0-999 and no leading zeros")
    return tuple(map(int, version.split(".")))


def release_build_number(version: str, platform: str) -> str:
    key = version_key(version)
    if key <= (3, 73, 0):
        major, minor, patch = key
        return str(major * 1000000 + minor * 1000 + patch)
    directory = RELEASES / version
    record = json.loads((directory / "build-numbers.json").read_text())
    if (set(record) != {"version", "commit", "ios", "mac"}
        or record["version"] != version or record["commit"] != (directory / "commit").read_text().strip()
        or any(not isinstance(record[name], str) or re.fullmatch(r"[1-9][0-9]*", record[name]) is None for name in ("ios", "mac"))):
        raise ValueError("The release build-number receipt does not match its source")
    return record[platform]


def git(*arguments: str) -> str:
    return subprocess.check_output(["git", *arguments], cwd=ROOT, text=True)


def release_directories() -> list[Path]:
    return sorted(
        (
            path
            for path in RELEASES.iterdir()
            if path.is_dir() and re.fullmatch(VERSION, path.name)
        ),
        key=lambda path: version_key(path.name),
        reverse=True,
    )


@contextlib.contextmanager
def cache_lease(exclusive: bool):
    RELEASES.mkdir(parents=True, exist_ok=True)
    with (RELEASES.parent / "release-reference.lock").open("a") as lease:
        mode = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
        fcntl.flock(lease, mode)
        yield


def write_json(path: Path, value) -> None:
    with tempfile.NamedTemporaryFile(
        "w", dir=path.parent, prefix=f".{path.name}.", delete=False
    ) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream, indent=2)
            stream.write("\n")
        except BaseException:
            temporary.unlink()
            raise
    os.replace(temporary, path)


def remove(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


def fingerprint(path: Path) -> str:
    if path.is_dir():
        return "tree:" + tree_digest(path)
    with path.open("rb") as stream:
        return "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest()


def entry(path: Path) -> dict:
    path = path.resolve(strict=True)
    return {"path": str(path), "fingerprint": fingerprint(path)}


def admit(version: str, commit: str) -> Path:
    version_key(version)
    if not isinstance(commit, str) or re.fullmatch(COMMIT, commit) is None:
        raise ValueError(f"{commit} is not a full commit")
    directory = RELEASES / version
    directory.mkdir(parents=True, exist_ok=True)
    recorded = directory / "commit"
    if not recorded.exists():
        recorded.write_text(commit + "\n")
    elif recorded.read_text().strip() != commit:
        raise ValueError(f"{directory} belongs to another commit")
    prune()
    return directory


def admit_tag(version: str, commit: str) -> Path:
    version_key(version)
    tags = {}
    for line in git("ls-remote", "--tags", "origin").splitlines():
        sha, ref = line.split("\t")
        name = ref.removeprefix("refs/tags/").removesuffix("^{}")
        if re.fullmatch(VERSION, name) and (ref.endswith("^{}") or name not in tags):
            tags[name] = sha
    if version not in tags:
        raise ValueError(f"{version} is not a release tag on origin")
    highest = max(tags, key=version_key)
    if highest != version:
        raise ValueError(f"{highest} is newer than {version}; release the next version instead")
    if tags[version] != commit or git("rev-parse", "HEAD").strip() != commit:
        raise ValueError(f"Tag {version} no longer points at {commit}")
    if git("status", "--porcelain"):
        raise ValueError("The release checkout is not clean")
    require_main_ancestor(ROOT, commit)
    return admit(version, commit)


def published_path() -> Path:
    return RELEASES / "published.json"


def validated(record) -> dict:
    if not isinstance(record, dict) or set(record) != {"version", "commit", "artifacts"}:
        raise ValueError("The published release record is malformed")
    version_key(record["version"])
    if not isinstance(record["commit"], str) or re.fullmatch(COMMIT, record["commit"]) is None:
        raise ValueError("The published release names no full commit")
    artifacts = record["artifacts"]
    if (
        not isinstance(artifacts, dict)
        or not {"gateway", "codex-package"} <= set(artifacts)
        or not set(artifacts) <= {"codex-package", *MIRRORED}
    ):
        raise ValueError("The published release names unknown or missing artifacts")
    for name, artifact in artifacts.items():
        if (
            not isinstance(artifact, dict)
            or set(artifact) != {"path", "fingerprint"}
            or not isinstance(artifact["path"], str)
            or re.fullmatch(r"/[A-Za-z0-9_.+/-]+", artifact["path"]) is None
            or not isinstance(artifact["fingerprint"], str)
            or re.fullmatch(FINGERPRINT, artifact["fingerprint"]) is None
        ):
            raise ValueError(f"The published release has a malformed {name}")
    return record


def read_published() -> dict | None:
    try:
        return validated(json.loads(published_path().read_text()))
    except FileNotFoundError:
        return None


def prepare_package(version: str) -> Path:
    version_key(version)
    directory = RELEASES / version
    if not (directory / "commit").is_file():
        raise ValueError(f"release {version} has not been admitted")
    approval = ROOT / "scripts/codex-runtime-approval"
    expected = json.loads((ROOT / "docs/codex/compatibility.json").read_text())["runtimePackageSHA256"]
    destination = directory / "codex-package"
    with file_lease(cache_root() / "codex-runtime/build.lock"), cache_lease(True):
        if not destination.exists():
            source = Path(subprocess.check_output([str(approval), "resolve"], text=True).strip())
            with tempfile.TemporaryDirectory(prefix="codex-package-", dir=directory) as temporary:
                staged = Path(temporary) / "package"
                shutil.copytree(source, staged, symlinks=True)
                if tree_digest(staged) != expected:
                    raise ValueError("approved package changed while preparing the release")
                staged.replace(destination)
        if tree_digest(destination) != expected:
            raise ValueError("retained release package differs from its approved fingerprint")
        subprocess.run([str(approval), "check", "--package", str(destination), "--json"], check=True, stdout=subprocess.DEVNULL)
    return destination


def publish(version: str, gateway: Path, package: Path) -> dict:
    commit = (RELEASES / version / "commit").read_text().strip()
    artifacts = {"gateway": entry(gateway), "codex-package": entry(package)}
    with cache_lease(True):
        current = read_published()
        if current is not None and current["version"] == version:
            if current["commit"] != commit:
                raise ValueError(f"{version} was published from {current['commit']}, not {commit}")
            artifacts = current["artifacts"] | artifacts
        elif current is not None and version_key(current["version"]) > version_key(version):
            raise ValueError(f"{current['version']} is already published; {version} cannot replace it")
        record = {"version": version, "commit": commit, "artifacts": artifacts}
        write_json(published_path(), record)
    return record


def symbol_directory(platform: str, version: str) -> Path:
    return DEPLOYMENTS / f"testflight-{platform}-{version}-{release_build_number(version, platform)}"


def attach(version: str, platform: str) -> dict:
    directory = RELEASES / version
    required = {"mac-app": directory / MAC_APP, "mac-package": directory / MAC_PACKAGE} if platform == "mac" else {}
    if version_key(version) > (3, 73, 0):
        release_build_number(version, platform)
        required["build-numbers"] = directory / "build-numbers.json"
    artifacts = {name: entry(path) for name, path in required.items()}
    symbols = symbol_directory(platform, version)
    if symbols.is_dir():
        artifacts[f"{platform}-symbols"] = entry(symbols)
    with cache_lease(True):
        record = read_published()
        if record is None or record["version"] != version:
            raise ValueError(f"{version} is not the published release")
        record["artifacts"] |= artifacts
        write_json(published_path(), record)
    return record


def allocated_bytes(path: Path) -> int:
    total = 0
    for current, directories, files in os.walk(path):
        for name in (".", *directories, *files):
            with contextlib.suppress(FileNotFoundError):
                total += os.lstat(Path(current) / name).st_blocks * 512
    return total


def prune_symbols(published: str | None) -> dict:
    by_version: dict[str, list[Path]] = {}
    for path in DEPLOYMENTS.glob("testflight-*"):
        if match := re.fullmatch(SYMBOL_DIRECTORY, path.name):
            by_version.setdefault(match[1], []).append(path)
    newest_first = sorted(by_version, key=version_key, reverse=True)
    cutoff = time.time() - SYMBOL_WINDOW_SECONDS
    recent = [v for v in newest_first if max(p.stat().st_mtime for p in by_version[v]) >= cutoff]
    older = [v for v in newest_first if v not in recent]
    kept = {*recent, *older[:1], *({published} & by_version.keys())}
    removed = []

    def evict(version: str) -> None:
        for path in by_version[version]:
            with contextlib.suppress(FileNotFoundError):
                shutil.rmtree(path)
                removed.append(path.name)
        kept.discard(version)

    for version in newest_first:
        if version not in kept:
            evict(version)
    sizes = {v: sum(allocated_bytes(p) for p in by_version[v]) for v in kept}
    total = sum(sizes.values())
    for version in reversed(newest_first):
        if total <= SYMBOL_BYTE_CAP:
            break
        if version in kept and version != published:
            evict(version)
            total -= sizes[version]
    over = max(0, total - SYMBOL_BYTE_CAP)
    if over:
        print(
            f"Release symbols use {total} bytes, {over} over the {SYMBOL_BYTE_CAP}-byte cap; "
            f"only the published release {published} remains to evict.",
            file=sys.stderr,
        )
    return {"removed": removed, "bytes": total, "overCapBytes": over}


def retain_symbols(platform: str, version: str, archive: Path) -> dict:
    symbols = sorted((archive / "dSYMs").glob("*.dSYM"))
    destination = symbol_directory(platform, version)
    if not symbols:
        print(f"{archive.name} has no dSYMs; traces of {platform} {version} cannot be symbolicated.", file=sys.stderr)
        return {"retained": None}
    remove(destination)
    (destination / "symbols").mkdir(parents=True)
    for path in symbols:
        shutil.copytree(path, destination / "symbols" / path.name, symlinks=True)
    return {"retained": str(destination), **prune_symbols(published_version())}


def installed_gateway() -> str:
    if not INSTALLED_GATEWAY.exists():
        return "absent"
    identity = json.loads(
        subprocess.check_output([str(INSTALLED_GATEWAY), "--version"], text=True, timeout=10)
    )
    version = identity.get("version")
    if identity.get("modified") is False and isinstance(version, str) and re.fullmatch(VERSION, version):
        return version
    return "development"


def installed_app(app: Path) -> str:
    plist = app / "Contents/Info.plist"
    if not plist.exists():
        return "absent"
    info = plistlib.loads(plist.read_bytes())
    version = info.get("CFBundleShortVersionString")
    if (
        isinstance(version, str)
        and re.fullmatch(VERSION, version)
        and isinstance(info.get("CFBundleVersion"), str)
        and re.fullmatch(r"[1-9][0-9]*", info["CFBundleVersion"])
        and info.get("RemoteCoderSourceModified") == "false"
    ):
        return version
    return "development"


def installed() -> dict[str, str]:
    app = load("install_release", "install-release.py").MAC_APP
    return {"gateway": installed_gateway(), "app": installed_app(app)}


def decision(installed: str, published: str, settled: bool) -> str:
    if installed == "development":
        return "keep" if settled else "deliver"
    if installed == "absent" or version_key(installed) < version_key(published):
        return "deliver"
    return "current" if installed == published else "newer"


def settled(directory: Path) -> set[str]:
    path = directory / "settled.json"
    if not path.exists():
        return set()
    components = json.loads(path.read_text())
    if not isinstance(components, list) or not set(components) <= set(COMPONENTS):
        raise ValueError(f"{path} is malformed")
    return set(components)


def settle(version: str) -> list[str]:
    directory = RELEASES / version
    components = settled(directory) | {
        name
        for name, value in installed().items()
        if value not in ("absent", "development") and version_key(value) >= version_key(version)
    }
    write_json(directory / "settled.json", sorted(components))
    return sorted(components)


def remote_record(host: str) -> dict | None:
    path = shlex.quote(str(RELEASES_IN_HOME / "published.json"))
    read = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, f"test ! -e {path} || cat {path}"],
        capture_output=True,
        text=True,
    )
    if read.returncode:
        raise ValueError(f"Reading the published release on {host} failed: {read.stderr.strip()[-400:]}")
    return validated(json.loads(read.stdout)) if read.stdout else None


def mirror(host: str, name: str, artifact: dict, target: Path) -> None:
    expected = artifact["fingerprint"]
    if target.exists() and fingerprint(target) == expected:
        return
    partial = target.with_name(target.name + ".partial")
    remove(partial)
    target.parent.mkdir(parents=True, exist_ok=True)
    suffix = "/" if expected.startswith("tree:") else ""
    copied = subprocess.run(
        ["rsync", "-a", f"{host}:{artifact['path']}{suffix}", f"{partial}{suffix}"],
        capture_output=True,
        text=True,
    )
    if copied.returncode:
        remove(partial)
        raise ValueError(f"Copying {name} from {host}:{artifact['path']} failed: {copied.stderr.strip()[-400:]}")
    if fingerprint(partial) != expected:
        remove(partial)
        raise ValueError(f"{name} from {host} does not match its published fingerprint")
    remove(target)
    partial.rename(target)


def catch_up(host: str) -> dict:
    record = remote_record(host)
    if record is None:
        return {"version": None}
    version, artifacts = record["version"], record["artifacts"]
    directory = admit(version, record["commit"])
    if "build-numbers" in artifacts:
        mirror(host, "build-numbers", artifacts["build-numbers"], directory / "build-numbers.json")
    facts, done = installed(), settled(directory)
    plan = {name: decision(facts[name], version, name in done) for name in COMPONENTS}
    if plan["app"] == "deliver" and "mac-app" not in artifacts:
        plan["app"] = "unpublished"
    targets = {
        "gateway": directory / gateway_bundle.NAME,
        "mac-app": directory / MAC_APP,
        "mac-package": directory / MAC_PACKAGE,
        "ios-symbols": symbol_directory("ios", version),
        "mac-symbols": symbol_directory("mac", version),
    }
    for name, target in targets.items():
        if name in artifacts:
            mirror(host, name, artifacts[name], target)
    pruned = prune_symbols(version)
    package = None
    if plan["gateway"] == "deliver":
        package = directory / "codex-package"
        published = artifacts["codex-package"]
        if package.exists() or not reuse_installed(package, published["fingerprint"].removeprefix("tree:")):
            mirror(host, "codex-package", published, package)
    return {
        "version": version,
        "commit": record["commit"],
        "releaseDir": str(directory),
        "gatewayBundle": str(targets["gateway"]),
        "codexPackage": None if package is None else str(package),
        "installed": facts,
        "symbols": pruned,
        **plan,
    }


def verify(directory: Path) -> dict:
    app = directory / MAC_APP
    commit = (directory / "commit").read_text().strip()
    if (
        re.fullmatch(VERSION, directory.name) is None
        or re.fullmatch(COMMIT, commit) is None
    ):
        raise ValueError(f"{directory} has an invalid release version or commit")
    if not (directory / MAC_PACKAGE).is_file():
        raise ValueError(f"{directory} has no completed Mac release publication")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {
        "CFBundleIdentifier": APP_IDENTIFIER,
        "CFBundleShortVersionString": directory.name,
        "CFBundleVersion": release_build_number(directory.name, "mac"),
        "RemoteCoderSourceCommit": commit,
        "RemoteCoderSourceModified": "false",
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"{app} does not match its release {key}")
    if not (app / "Contents/embedded.provisionprofile").is_file():
        raise ValueError(f"{app} has no embedded provisioning profile")
    load("release_config", "release-config.py").validate((app / CONFIG).read_bytes())
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    details = subprocess.run(
        ["codesign", "--display", "--verbose=3", str(app)],
        capture_output=True,
        text=True,
        check=True,
    ).stderr
    if (
        f"TeamIdentifier={TEAM}\n" not in details
        or "Authority=Developer ID Application: " not in details
    ):
        raise ValueError(f"{app} is not a Developer ID release for team {TEAM}")
    digest = re.search(r"^CDHash=([0-9a-f]+)$", details, re.MULTILINE)
    if digest is None:
        raise ValueError(f"{app} has no signed code digest")
    return {
        "app": str(app),
        "version": directory.name,
        "commit": commit,
        "team": TEAM,
        "cdhash": digest[1],
    }


@contextlib.contextmanager
def reference():
    with cache_lease(False):
        complete = [
            directory
            for directory in release_directories()
            if (directory / MAC_PACKAGE).is_file()
        ]
        if not complete:
            raise ValueError(
                f"No published Mac release in {RELEASES}; complete the release pipeline first"
            )
        release = verify(complete[0])
        complete[0].touch()
        yield release


def published_version() -> str | None:
    record = read_published()
    return None if record is None else record["version"]


def prune() -> dict:
    with cache_lease(True):
        published = published_version()
        removed = []
        for directory in release_directories()[3:]:
            if directory.name == published or time.time() - directory.stat().st_mtime < 48 * 3600:
                continue
            shutil.rmtree(directory)
            removed.append(directory.name)
        return {"removed": removed}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    operations = parser.add_subparsers(dest="operation", required=True)
    admission = operations.add_parser("admit-tag", help="admit the checked-out release tag and print its release directory")
    admission.add_argument("version")
    admission.add_argument("commit")
    preparation = operations.add_parser("prepare-package", help="retain the exact approved build package for a release")
    preparation.add_argument("version")
    publication = operations.add_parser("publish", help="record the release this Mac's gateway now runs")
    publication.add_argument("version")
    publication.add_argument("gateway", type=Path)
    publication.add_argument("package", type=Path)
    attachment = operations.add_parser("attach", help="add a platform's verified artifacts to the published release")
    attachment.add_argument("version")
    attachment.add_argument("platform", choices=("ios", "mac"))
    symbols = operations.add_parser("retain-symbols", help="keep a release archive's dSYMs for perf-trace")
    symbols.add_argument("platform", choices=("ios", "mac"))
    symbols.add_argument("version")
    symbols.add_argument("archive", type=Path)
    catching_up = operations.add_parser("catch-up", help="mirror another Mac's published release and plan what this Mac deploys")
    catching_up.add_argument("host")
    settlement = operations.add_parser("settle", help="record which components run the published release or newer")
    settlement.add_argument("version")
    operations.add_parser("inspect", help="verify the newest published Mac release")
    operations.add_parser("restore", help="install the newest published Mac release on this Mac")
    args = parser.parse_args()
    if args.operation == "admit-tag":
        print(admit_tag(args.version, args.commit))
    elif args.operation == "prepare-package":
        print(prepare_package(args.version))
    elif args.operation == "publish":
        print(json.dumps(publish(args.version, args.gateway, args.package)))
    elif args.operation == "attach":
        print(json.dumps(attach(args.version, args.platform)))
    elif args.operation == "retain-symbols":
        print(json.dumps(retain_symbols(args.platform, args.version, args.archive)))
    elif args.operation == "catch-up":
        print(json.dumps(catch_up(args.host)))
    elif args.operation == "settle":
        print(json.dumps({"settled": settle(args.version)}))
    else:
        with reference() as release:
            if args.operation == "restore":
                installer = load("install_release", "install-release.py")
                release["result"] = installer.install_mac_release(
                    Path(release["app"]), installer.MAC_APP
                )
            print(json.dumps(release))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
