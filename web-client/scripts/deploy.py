import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from maintainer_config import load as maintainer_config, path as maintainer_path


WEB = maintainer_config().get("web", {})
SERVICE_PLIST = maintainer_path().parent / WEB.get("servicePlist", "web/service.plist")
ROOT = (Path.home() / "Library/Application Support/RemoteCoder/web-client").resolve()
RELEASES = ROOT / "releases"
ORIGIN = WEB.get("origin", "")
MAX_TOTAL_BYTES = 1536 * 1024 * 1024
WORKER = Path(__file__).resolve().with_name("stage-process.py")


def run(*arguments, **options):
    return subprocess.run([str(value) for value in arguments], check=True, **options)


def point(name, target):
    temporary = ROOT / f".{name}.tmp"
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(target)
    temporary.replace(ROOT / name)


def size(directory):
    return sum(path.stat().st_size for path in directory.rglob("*") if path.is_file())


def check_budget(additional=0):
    total = size(RELEASES) + sum(size(path) for path in ROOT.glob(".build-*") if path.is_dir())
    if total + additional > MAX_TOTAL_BYTES:
        raise RuntimeError(f"Web staging exceeds 1.5 GiB budget: {total} bytes used, {additional} bytes required")


def retained():
    keep = set()
    for name in ("current", "previous", "staged", "staged-previous"):
        pointer = ROOT / name
        if pointer.is_symlink():
            target = pointer.resolve(strict=True)
            if target.parent != RELEASES or not target.is_dir():
                raise RuntimeError(f"Invalid web release pointer: {name}")
            keep.add(target.name)
        elif pointer.exists():
            raise RuntimeError(f"Web release pointer is not a symlink: {name}")
    return keep


def prune():
    keep = retained()
    for path in RELEASES.iterdir():
        if path.name not in keep:
            shutil.rmtree(path)
    check_budget()


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def release_identity(revision, bun_version, bun_hash, service_bytes):
    inputs = json.dumps([revision, bun_version, bun_hash], separators=(",", ":")).encode()
    return hashlib.sha256(inputs + service_bytes).hexdigest()


def copy_runtime(source, destination, expected):
    shutil.copy2(source, destination)
    version = run(destination, "--version", capture_output=True, text=True, timeout=5).stdout.strip()
    if version != expected:
        raise RuntimeError(f"Expected Bun {expected}, found {version}")
    return version, digest(destination)


def release_files(release):
    files = {}
    for path in release.rglob("*"):
        if path.is_symlink():
            raise RuntimeError(f"Release contains a symlink: {path}")
        if path.is_file() and path != release / "manifest.json":
            files[str(path.relative_to(release))] = digest(path)
    return files


def write_manifest(release):
    (release / "manifest.json").write_text(json.dumps(release_files(release), sort_keys=True) + "\n")


def runtime(release):
    manifest = json.loads((release / "manifest.json").read_text())
    if not isinstance(manifest, dict) or manifest != release_files(release):
        raise RuntimeError(f"Retained release files do not match manifest: {release.name}")
    definition = plistlib.loads((release / "service.plist").read_bytes())
    bun = Path(definition["ProgramArguments"][0])
    metadata = json.loads((release / "dist/deployment.json").read_text())
    if (definition["ProgramArguments"] != [str(release / "bun"), str(release / "service.js")]
            or metadata["release"] != release.name
            or digest(bun) != metadata["bunSha256"]
            or digest(release / "service.plist") != metadata["serviceSha256"]):
        raise RuntimeError(f"Retained runtime or service does not match release {release.name}")
    return bun


def snapshot_legacy(release):
    if not release:
        return None
    metadata = json.loads((release / "dist/deployment.json").read_text())
    if "bunSha256" in metadata:
        runtime(release)
        return release
    definition = plistlib.loads((release / "service.plist").read_bytes())
    bun = Path(definition["ProgramArguments"][0])
    check_budget(size(release) + bun.stat().st_size + 65536)
    with tempfile.TemporaryDirectory(prefix=".build-", dir=ROOT) as temporary:
        built = Path(temporary) / "release"
        shutil.copytree(release, built)
        copied_bun = built / "bun"
        _, bun_hash = copy_runtime(bun, copied_bun, metadata["bun"])
        identity = hashlib.sha256((release.name + bun_hash).encode() + (release / "service.plist").read_bytes()).hexdigest()
        snapshot = RELEASES / identity
        if not snapshot.exists():
            definition["ProgramArguments"] = [str(snapshot / "bun"), str(snapshot / "service.js")]
            (built / "service.plist").write_bytes(plistlib.dumps(definition))
            metadata["bunSha256"] = bun_hash
            metadata["release"] = identity
            metadata["serviceSha256"] = digest(built / "service.plist")
            (built / "dist/deployment.json").write_text(json.dumps(metadata) + "\n")
            write_manifest(built)
            check_budget()
            built.rename(snapshot)
    runtime(snapshot)
    return snapshot


def staged_process(arguments, lock, timeout, **options):
    return subprocess.Popen(
        [sys.executable, str(WORKER), str(timeout), str(lock.fileno()), *(str(value) for value in arguments)],
        stdin=subprocess.PIPE, start_new_session=True, pass_fds=(lock.fileno(),), **options,
    )


def staged_run(arguments, lock, timeout, **options):
    process = staged_process(arguments, lock, timeout, **options)
    try:
        status = process.wait(timeout=timeout + 10)
        if status:
            raise subprocess.CalledProcessError(status, arguments)
    finally:
        process.stdin.close()
        if process.poll() is None:
            process.wait(timeout=10)


def smoke(release, address, mode, lock, temporary):
    command = [runtime(release), release / "smoke.js", address, ORIGIN, mode]
    environment = {**os.environ, "TMPDIR": str(temporary), "BUN_RUNTIME_TRANSPILER_CACHE_PATH": "0"}
    process = staged_process(command, lock, 35, stdout=subprocess.PIPE, env=environment)
    deadline = time.monotonic() + 45
    output = bytearray()
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Smoke output did not close within 45 seconds")
            ready, _, _ = select.select([process.stdout], [], [], remaining)
            if not ready:
                raise TimeoutError("Smoke output did not close within 45 seconds")
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > 1024 * 1024:
                raise RuntimeError("Smoke output exceeds 1 MiB")
        status = process.wait(timeout=10)
        if status:
            raise subprocess.CalledProcessError(status, command)
        return json.loads(output)
    finally:
        process.stdout.close()
        process.stdin.close()
        if process.poll() is None:
            process.wait(timeout=10)


def candidate(release, environment, mode, lock):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix=".build-", dir=ROOT) as temporary, (Path(temporary) / "candidate.log").open("w+b") as output:
        process = staged_process(
            [runtime(release), release / "server.js"], lock, 45,
            cwd=release,
            env={**environment, "RC_WEB_PORT": str(port), "RC_WEB_STATIC_DIR": str(release / "dist")},
            stdout=output,
            stderr=output,
        )
        try:
            for attempt in range(30):
                if process.poll() is not None:
                    raise RuntimeError("Candidate exited before readiness")
                with socket.socket() as probe:
                    if probe.connect_ex(("127.0.0.1", port)) == 0:
                        break
                time.sleep(0.1)
            else:
                raise RuntimeError("Candidate did not open its listener within three seconds")
            result = smoke(release, f"http://127.0.0.1:{port}", mode, lock, Path(temporary))
            expected = json.loads((release / "dist/deployment.json").read_text())
            if any(result.get(key) != value for key, value in expected.items()):
                raise RuntimeError("Candidate did not report its expected release identity")
            print(f"Candidate verified: {json.dumps(result)}", flush=True)
        except BaseException:
            output.seek(0, 2)
            output.seek(max(0, output.tell() - 4096))
            print(output.read().decode(errors="replace"), file=sys.stderr)
            raise
        finally:
            process.stdin.close()
            process.wait(timeout=10)
        check_budget()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=["stage"])
    parser.parse_args()
    if not WEB or not SERVICE_PLIST.is_file():
        raise RuntimeError("Configure the web deployment and servicePlist in RC_MAINTAINER_CONFIG")
    if socket.gethostname().split(".")[0] != WEB["host"]:
        raise RuntimeError(f"Run this installer on the configured web host: {WEB['host']}")
    bun_path = WEB.get("bunPath")
    bun_version = WEB.get("bunVersion")
    if not isinstance(bun_path, str) or not Path(bun_path).expanduser().is_absolute() or not isinstance(bun_version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", bun_version):
        raise RuntimeError("Configure an absolute bunPath and exact bunVersion in web maintainer configuration")
    bun = Path(bun_path).expanduser().resolve(strict=True)
    service_bytes = SERVICE_PLIST.read_bytes()
    repository = Path(__file__).resolve().parents[2]
    dirty = run("git", "-C", repository, "status", "--porcelain", "--", "web-client", "justfile", capture_output=True, text=True).stdout
    if dirty:
        raise RuntimeError("Commit web-client and justfile changes before staging")
    revision = run("git", "-C", repository, "rev-parse", "HEAD", capture_output=True, text=True).stdout.strip()
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    RELEASES.mkdir(exist_ok=True)
    with (ROOT / "deploy.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Web staging lock is held; inspect deploy.lock for a running or orphaned staging command before cleanup") from error
        for stale in ROOT.glob(".build-*"):
            shutil.rmtree(stale)
        prune()
        current = (ROOT / "current").resolve() if (ROOT / "current").exists() else None
        snapshot = snapshot_legacy(current)
        if snapshot:
            point("staged-previous", snapshot)
        release = None
        try:
            with tempfile.TemporaryDirectory(prefix=".build-", dir=ROOT) as temporary:
                staging = Path(temporary)
                check_budget(bun.stat().st_size)
                staged_bun = staging / "bun"
                actual_version, bun_hash = copy_runtime(bun, staged_bun, bun_version)
                identity = release_identity(revision, actual_version, bun_hash, service_bytes)
                release = RELEASES / identity
                if not release.exists():
                    archive = staging / "source.tar"
                    staged_run(["git", "-C", repository, "archive", "--output", archive, revision, "web-client", "THIRD_PARTY_NOTICES.md", "LICENSES"], lock, 60)
                    check_budget()
                    with tarfile.open(archive) as source:
                        source.extractall(staging, filter="data")
                    archive.unlink()
                    check_budget()
                    web = staging / "web-client"
                    temporary_dir = staging / "tmp"
                    temporary_dir.mkdir()
                    cache = staging / "cache"
                    environment = {**os.environ, "BUN_INSTALL_CACHE_DIR": str(cache), "BUN_RUNTIME_TRANSPILER_CACHE_PATH": "0", "TMPDIR": str(temporary_dir), "RC_WEB_REVISION": revision}
                    staged_run([staged_bun, "install", "--frozen-lockfile"], lock, 600, cwd=web, env=environment)
                    check_budget()
                    if cache.exists():
                        shutil.rmtree(cache)
                    staged_run([staged_bun, "scripts/build.ts"], lock, 300, cwd=web, env=environment)
                    check_budget()
                    built = staging / "release"
                    built.mkdir()
                    check_budget(size(web / "dist"))
                    shutil.copytree(web / "dist", built / "dist")
                    check_budget()
                    for source, destination in [("server/index.ts", "server.js"), ("scripts/service.ts", "service.js"), ("scripts/smoke.ts", "smoke.js")]:
                        staged_run([staged_bun, "build", source, "--target=bun", "--outfile", built / destination], lock, 300, cwd=web, env=environment)
                        check_budget()
                    staged_bun.rename(built / "bun")
                    if digest(built / "bun") != bun_hash:
                        raise RuntimeError("Bun changed during the build")
                    definition = plistlib.loads(service_bytes)
                    definition["ProgramArguments"] = [str(release / "bun"), str(release / "service.js")]
                    (built / "service.plist").write_bytes(plistlib.dumps(definition))
                    (built / "dist/deployment.json").write_text(json.dumps({"revision": revision, "bun": actual_version, "bunSha256": bun_hash, "release": identity, "serviceSha256": digest(built / "service.plist")}) + "\n")
                    write_manifest(built)
                    check_budget()
                    built.rename(release)
        except BaseException:
            if release and release.exists() and release.name not in retained():
                shutil.rmtree(release)
            raise
        try:
            metadata = json.loads((release / "dist/deployment.json").read_text())
            if (metadata["revision"], metadata["bun"], metadata["bunSha256"], metadata["release"]) != (revision, actual_version, bun_hash, identity):
                raise RuntimeError("Retained release metadata does not match its inputs")
            runtime(release)
            definition = plistlib.loads((release / "service.plist").read_bytes())
            environment = {"HOME": str(Path.home()), **definition["EnvironmentVariables"]}
            candidate(release, environment, "primary", lock)
            check_budget()
            point("staged", release)
        except BaseException:
            if release.exists() and release.name not in retained():
                shutil.rmtree(release)
            raise
        prune()
        print(json.dumps({"status": "staged", "release": identity, "revision": revision, "bun": actual_version, "bunSha256": bun_hash, "rollbackSnapshot": snapshot.name if snapshot else None, "retainedBytes": size(RELEASES), "budgetBytes": MAX_TOTAL_BYTES, "activation": "pending", "reason": "The bridge needs call-safe admission fencing and crash recovery before switching"}), flush=True)
        return 0


if __name__ == "__main__":
    def cancel(signum, frame):
        raise KeyboardInterrupt(f"Deployment canceled by signal {signum}")

    signal.signal(signal.SIGTERM, cancel)
    sys.exit(main())
