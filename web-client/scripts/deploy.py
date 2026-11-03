import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
from urllib.request import Request, urlopen
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from maintainer_config import load as maintainer_config, path as maintainer_path


WEB = maintainer_config().get("web", {})
SERVICE_PLIST = maintainer_path().parent / WEB.get("servicePlist", "web/service.plist")
ROOT = Path.home() / "Library/Application Support/RemoteCoder/web-client"
RELEASES = ROOT / "releases"
LABEL = WEB.get("label", "com.remotecoder.web")
PLIST = Path.home() / f"Library/LaunchAgents/{LABEL}.plist"
DOMAIN = f"gui/{os.getuid()}"
ORIGIN = WEB.get("origin", "")
PORT = WEB.get("port", 19763)
MAX_RELEASE_BYTES = 128 * 1024 * 1024


def run(*arguments, **options):
    return subprocess.run([str(value) for value in arguments], check=True, **options)


def point(name, target):
    temporary = ROOT / f".{name}.tmp"
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(target)
    temporary.replace(ROOT / name)


def size(directory):
    return sum(path.stat().st_size for path in directory.rglob("*") if path.is_file())


def prune(keep):
    for path in RELEASES.iterdir():
        if path.name not in keep:
            shutil.rmtree(path)
    total = size(RELEASES)
    if total > 2 * MAX_RELEASE_BYTES:
        raise RuntimeError(f"Release retention exceeds 256 MiB: {total} bytes")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def release_identity(revision, bun_version, bun_hash, service_bytes):
    inputs = json.dumps([revision, bun_version, bun_hash], separators=(",", ":")).encode()
    return hashlib.sha256(inputs + service_bytes).hexdigest()


def runtime(release):
    definition = plistlib.loads((release / "service.plist").read_bytes())
    bun = Path(definition["ProgramArguments"][0])
    metadata = json.loads((release / "dist/deployment.json").read_text())
    if (bun != release / "bun" or metadata["release"] != release.name
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
    version = run(bun, "--version", capture_output=True, text=True).stdout.strip()
    if version != metadata["bun"]:
        raise RuntimeError(f"Legacy release {release.name} requires Bun {metadata['bun']}, found {version}")
    bun_hash = digest(bun)
    identity = hashlib.sha256((release.name + bun_hash).encode() + (release / "service.plist").read_bytes()).hexdigest()
    snapshot = RELEASES / identity
    if not snapshot.exists():
        with tempfile.TemporaryDirectory(prefix=".build-", dir=ROOT) as temporary:
            built = Path(temporary) / "release"
            shutil.copytree(release, built)
            shutil.copy2(bun, built / "bun")
            if digest(built / "bun") != bun_hash:
                raise RuntimeError("Bun changed while retaining the legacy release")
            definition["ProgramArguments"][0] = str(snapshot / "bun")
            (built / "service.plist").write_bytes(plistlib.dumps(definition))
            metadata["bunSha256"] = bun_hash
            metadata["release"] = identity
            metadata["serviceSha256"] = digest(built / "service.plist")
            (built / "dist/deployment.json").write_text(json.dumps(metadata) + "\n")
            if size(built) > MAX_RELEASE_BYTES:
                raise RuntimeError("Retained release exceeds 128 MiB")
            built.rename(snapshot)
    runtime(snapshot)
    return snapshot


def smoke(release, address, mode):
    return json.loads(run(runtime(release), release / "smoke.js", address, ORIGIN, mode, stdout=subprocess.PIPE, text=True, timeout=35).stdout)


def candidate(release, environment, mode):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(
            [str(runtime(release)), str(release / "server.js")],
            cwd=release,
            env={**environment, "RC_WEB_PORT": str(port), "RC_WEB_STATIC_DIR": str(release / "dist")},
            stdin=subprocess.DEVNULL,
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
            result = smoke(release, f"http://127.0.0.1:{port}", mode)
            print(f"Candidate verified: {json.dumps(result)}", flush=True)
        except BaseException:
            output.seek(0, 2)
            output.seek(max(0, output.tell() - 4096))
            print(output.read().decode(errors="replace"), file=sys.stderr)
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def job_loaded():
    result = subprocess.run(["launchctl", "print", f"{DOMAIN}/{LABEL}"], capture_output=True, text=True)
    if result.returncode == 0:
        return True
    if f'Could not find service "{LABEL}"' in result.stderr:
        return False
    raise RuntimeError(f"Cannot read the bridge LaunchAgent: {result.stderr.strip()}")


class BridgeBusy(RuntimeError):
    pass


@contextmanager
def idle_bridge():
    if not job_loaded():
        sockets = subprocess.run(["lsof", "-nP", "-t", f"-iTCP:{PORT}"], capture_output=True, text=True)
        if sockets.returncode != 1 or sockets.stdout or sockets.stderr:
            raise BridgeBusy("Cannot prove the stopped bridge port has no connections")
        yield None
        return
    job = run("launchctl", "print", f"{DOMAIN}/{LABEL}", capture_output=True, text=True).stdout
    matches = re.findall(r"^\s*pid = ([0-9]+)$", job, re.MULTILINE)
    listeners = run("lsof", "-nP", "-t", f"-iTCP:{PORT}", "-sTCP:LISTEN", capture_output=True, text=True).stdout.split()
    if len(matches) != 1 or len(listeners) != 1:
        raise RuntimeError("Cannot establish the bridge supervisor and listener identities")
    listener = int(listeners[0])
    parent = run("ps", "-o", "ppid=", "-p", listener, capture_output=True, text=True).stdout.strip()
    birth = run("ps", "-o", "lstart=", "-p", listener, capture_output=True, text=True).stdout.strip()
    if parent != matches[0] or not birth:
        raise RuntimeError("The bridge listener is not owned by its LaunchAgent")
    watchdog = subprocess.Popen(
        [sys.executable, "-c",
         "import os, signal, subprocess, sys\n"
         "pid = int(sys.argv[1]); birth = sys.argv[2]\n"
         "stopped = False\n"
         "try:\n"
         " current = subprocess.run(['ps', '-o', 'lstart=', '-p', str(pid)], capture_output=True, text=True)\n"
         " if current.returncode != 0 or current.stdout.strip() != birth: raise RuntimeError('Listener changed')\n"
         " os.kill(pid, signal.SIGSTOP)\n"
         " stopped = True\n"
         " print('stopped', flush=True)\n"
         " sys.stdin.buffer.read(1)\n"
         "finally:\n"
         " current = subprocess.run(['ps', '-o', 'lstart=', '-p', str(pid)], capture_output=True, text=True)\n"
         " if stopped and current.returncode == 0 and current.stdout.strip() == birth:\n"
         "  try: os.kill(pid, signal.SIGCONT)\n"
         "  except ProcessLookupError: pass\n", str(listener), birth],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    )
    try:
        if watchdog.stdout.readline().strip() != "stopped":
            raise RuntimeError("Could not fence the bridge listener")
        state = run("ps", "-o", "stat=", "-p", listener, capture_output=True, text=True).stdout.strip()
        if "T" not in state:
            raise RuntimeError("The bridge listener did not stop")
        sockets = run("lsof", "-nP", "-a", "-p", listener, "-iTCP", "-F", "fT", capture_output=True, text=True).stdout
        fields = sockets.splitlines()
        descriptors = sum(line.startswith("f") for line in fields)
        states = [line[4:] for line in fields if line.startswith("TST=")]
        if descriptors != len(states) or states.count("LISTEN") != 1:
            raise RuntimeError("Cannot establish all bridge TCP socket states")
        if any(state != "LISTEN" for state in states):
            raise BridgeBusy("Bridge has active TCP connections; retry after browser calls and speech finish")
        yield (listener, birth)
    finally:
        watchdog.stdin.close()
        watchdog.wait(timeout=10)
        watchdog.stdout.close()


def activate(release):
    admitted = False
    try:
        with idle_bridge() as fenced:
            admitted = True
            activate_idle(release, fenced)
    except BaseException as error:
        if not admitted and not isinstance(error, BridgeBusy):
            raise BridgeBusy(f"Cannot prove the bridge is idle: {error}") from error
        raise


def activate_idle(release, fenced):
    if job_loaded():
        run("launchctl", "bootout", f"{DOMAIN}/{LABEL}")
        if fenced:
            listener, birth = fenced
            current = subprocess.run(["ps", "-o", "lstart=", "-p", str(listener)], capture_output=True, text=True)
            if current.returncode == 0 and current.stdout.strip() == birth:
                try:
                    os.kill(listener, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        for attempt in range(50):
            if not job_loaded():
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("The previous bridge LaunchAgent did not retire within five seconds")
        for attempt in range(50):
            probe = subprocess.run(["lsof", "-nP", "-t", f"-iTCP:{PORT}", "-sTCP:LISTEN"], capture_output=True, text=True)
            if probe.returncode == 1 and not probe.stdout and not probe.stderr:
                break
            if probe.returncode != 0:
                raise RuntimeError("Cannot verify retirement of the bridge listener")
            time.sleep(0.1)
        else:
            raise RuntimeError("The previous bridge listener did not retire within five seconds")
    point("current", release)
    temporary = PLIST.with_suffix(".tmp")
    shutil.copyfile(release / "service.plist", temporary)
    temporary.replace(PLIST)
    run("launchctl", "bootstrap", DOMAIN, PLIST)
    expected = json.loads((release / "dist/deployment.json").read_text())
    for attempt in range(50):
        try:
            request = Request(f"http://127.0.0.1:{PORT}/deployment.json", headers={"Host": urlparse(ORIGIN).netloc})
            with urlopen(request, timeout=0.2) as response:
                if json.load(response) == expected:
                    break
        except (OSError, ValueError):
            pass
        time.sleep(0.2)
    else:
        raise RuntimeError("The activated bridge did not report its expected revision")
    result = smoke(release, f"http://127.0.0.1:{PORT}", "local")
    if result["revision"] != expected["revision"]:
        raise RuntimeError("The running revision differs from the candidate")
    print(f"Running: {json.dumps(result)}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=["deploy", "rollback"])
    operation = parser.parse_args().operation
    if not WEB or not SERVICE_PLIST.is_file():
        raise RuntimeError("Configure the web deployment and servicePlist in RC_MAINTAINER_CONFIG")
    if socket.gethostname().split(".")[0] != WEB["host"]:
        raise RuntimeError(f"Run this installer on the configured web host: {WEB['host']}")
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    RELEASES.mkdir(exist_ok=True)
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    with (ROOT / "deploy.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for stale in ROOT.glob(".build-*"):
            shutil.rmtree(stale)
        port_owner = Path.home() / "configs/scripts/mac-mini-service-ports"
        if port_owner.is_file():
            run(port_owner, "claim", "remote-coder-web", "127.0.0.1", str(PORT))
        current = (ROOT / "current").resolve() if (ROOT / "current").exists() else None
        previous = (ROOT / "previous").resolve() if (ROOT / "previous").exists() else None
        prune({path.name for path in [current, previous] if path})
        current = snapshot_legacy(current)
        if operation == "rollback":
            if not previous:
                raise RuntimeError("No previous release is retained")
            release = snapshot_legacy(previous)
        else:
            bun_path = WEB.get("bunPath")
            bun_version = WEB.get("bunVersion")
            if not isinstance(bun_path, str) or not Path(bun_path).expanduser().is_absolute() or not isinstance(bun_version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", bun_version):
                raise RuntimeError("Configure an absolute bunPath and exact bunVersion in web maintainer configuration")
            bun = Path(bun_path).expanduser().resolve(strict=True)
            actual_version = run(bun, "--version", capture_output=True, text=True).stdout.strip()
            if actual_version != bun_version:
                raise RuntimeError(f"Expected Bun {bun_version}, found {actual_version}")
            bun_hash = digest(bun)
            service_bytes = SERVICE_PLIST.read_bytes()
            repository = Path(__file__).resolve().parents[2]
            dirty = run("git", "-C", repository, "status", "--porcelain", "--", "web-client", "justfile", capture_output=True, text=True).stdout
            if dirty:
                raise RuntimeError("Commit web-client and justfile changes before deployment")
            revision = run("git", "-C", repository, "rev-parse", "HEAD", capture_output=True, text=True).stdout.strip()
            identity = release_identity(revision, bun_version, bun_hash, service_bytes)
            release = RELEASES / identity
            if not release.exists():
                with tempfile.TemporaryDirectory(prefix=".build-", dir=ROOT) as temporary:
                    staging = Path(temporary)
                    archive = staging / "source.tar"
                    run(
                        "git", "-C", repository, "archive", "--output", archive, revision,
                        "web-client", "THIRD_PARTY_NOTICES.md", "LICENSES",
                    )
                    with tarfile.open(archive) as source:
                        source.extractall(staging, filter="data")
                    web = staging / "web-client"
                    run(bun, "install", "--frozen-lockfile", cwd=web)
                    run(bun, "run", "build", cwd=web, env={**os.environ, "RC_WEB_REVISION": revision})
                    built = staging / "release"
                    built.mkdir()
                    shutil.copytree(web / "dist", built / "dist")
                    for source, destination in [("server/index.ts", "server.js"), ("scripts/service.ts", "service.js"), ("scripts/smoke.ts", "smoke.js")]:
                        run(bun, "build", source, "--target=bun", "--outfile", built / destination, cwd=web)
                    shutil.copy2(bun, built / "bun")
                    if digest(built / "bun") != bun_hash:
                        raise RuntimeError("Bun changed during the build")
                    definition = plistlib.loads(service_bytes)
                    definition["ProgramArguments"] = [str(release / "bun"), str(ROOT / "current/service.js")]
                    (built / "service.plist").write_bytes(plistlib.dumps(definition))
                    (built / "dist/deployment.json").write_text(json.dumps({"revision": revision, "bun": bun_version, "bunSha256": bun_hash, "release": identity, "serviceSha256": digest(built / "service.plist")}) + "\n")
                    if size(built) > MAX_RELEASE_BYTES:
                        raise RuntimeError("Built release exceeds 128 MiB")
                    built.rename(release)
            metadata = json.loads((release / "dist/deployment.json").read_text())
            if (metadata["revision"], metadata["bun"], metadata["bunSha256"], metadata["release"]) != (revision, bun_version, bun_hash, identity):
                raise RuntimeError("Retained release metadata does not match its inputs")
            runtime(release)
        try:
            definition = plistlib.loads((release / "service.plist").read_bytes())
            environment = {"HOME": str(Path.home())}
            environment.update(definition["EnvironmentVariables"])
            candidate(release, environment, "local" if operation == "rollback" else "primary")
            try:
                activate(release)
            except BridgeBusy:
                raise
            except BaseException:
                signal.signal(signal.SIGINT, signal.SIG_IGN)
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                if current:
                    try:
                        activate(current)
                    except BridgeBusy:
                        point("previous", current)
                        raise
                else:
                    subprocess.run(["launchctl", "bootout", f"{DOMAIN}/{LABEL}"], capture_output=True)
                    (ROOT / "current").unlink(missing_ok=True)
                    PLIST.unlink(missing_ok=True)
                raise
            if current and current != release:
                point("previous", current)
            retained = current if current != release else previous
            prune({path.name for path in [release, retained] if path})
        finally:
            active = {(ROOT / name).resolve().name for name in ["current", "previous"] if (ROOT / name).exists()}
            if release.name not in active:
                shutil.rmtree(release)


if __name__ == "__main__":
    def cancel(signum, frame):
        raise KeyboardInterrupt(f"Deployment canceled by signal {signum}")

    signal.signal(signal.SIGTERM, cancel)
    main()
