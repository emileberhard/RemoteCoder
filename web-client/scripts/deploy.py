import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
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


BUN = Path(shutil.which("bun") or "bun")
WEB = maintainer_config().get("web", {})
SERVICE_PLIST = maintainer_path().parent / WEB.get("servicePlist", "web/service.plist")
ROOT = Path.home() / "Library/Application Support/RemoteCoder/web-client"
RELEASES = ROOT / "releases"
LABEL = WEB.get("label", "com.remotecoder.web")
PLIST = Path.home() / f"Library/LaunchAgents/{LABEL}.plist"
DOMAIN = f"gui/{os.getuid()}"
ORIGIN = WEB.get("origin", "")
PORT = WEB.get("port", 19763)
MAX_RELEASE_BYTES = 32 * 1024 * 1024


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
        raise RuntimeError(f"Release retention exceeds 64 MiB: {total} bytes")


def smoke(release, address, mode):
    return json.loads(run(BUN, release / "smoke.js", address, ORIGIN, mode, stdout=subprocess.PIPE, text=True, timeout=35).stdout)


def candidate(release, environment, mode):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(
            [str(BUN), str(release / "server.js")],
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


def activate(release):
    if job_loaded():
        run("launchctl", "bootout", f"{DOMAIN}/{LABEL}")
        for attempt in range(50):
            if not job_loaded():
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("The previous bridge LaunchAgent did not retire within five seconds")
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
    if run(BUN, "--version", capture_output=True, text=True).stdout.strip() != "1.4.3":
        raise RuntimeError("Expected Bun 1.4.3")
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
        if operation == "rollback":
            if not previous:
                raise RuntimeError("No previous release is retained")
            release = previous
        else:
            repository = Path(__file__).resolve().parents[2]
            dirty = run("git", "-C", repository, "status", "--porcelain", "--", "web-client", "justfile", capture_output=True, text=True).stdout
            if dirty:
                raise RuntimeError("Commit web-client and justfile changes before deployment")
            revision = run("git", "-C", repository, "rev-parse", "HEAD", capture_output=True, text=True).stdout.strip()
            release = RELEASES / revision
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
                    run(BUN, "install", "--frozen-lockfile", cwd=web)
                    run(BUN, "run", "build", cwd=web, env={**os.environ, "RC_WEB_REVISION": revision})
                    built = staging / "release"
                    built.mkdir()
                    shutil.copytree(web / "dist", built / "dist")
                    for source, destination in [("server/index.ts", "server.js"), ("scripts/service.ts", "service.js"), ("scripts/smoke.ts", "smoke.js")]:
                        run(BUN, "build", source, "--target=bun", "--outfile", built / destination, cwd=web)
                    definition = plistlib.loads(SERVICE_PLIST.read_bytes())
                    definition["ProgramArguments"] = [str(BUN), str(ROOT / "current/service.js")]
                    (built / "service.plist").write_bytes(plistlib.dumps(definition))
                    (built / "dist/deployment.json").write_text(json.dumps({"revision": revision, "bun": "1.4.3"}) + "\n")
                    if size(built) > MAX_RELEASE_BYTES:
                        raise RuntimeError("Built release exceeds 32 MiB")
                    built.rename(release)
        try:
            definition = plistlib.loads((release / "service.plist").read_bytes())
            environment = {"HOME": str(Path.home())}
            environment.update(definition["EnvironmentVariables"])
            candidate(release, environment, "local" if operation == "rollback" else "primary")
            try:
                activate(release)
            except BaseException:
                signal.signal(signal.SIGINT, signal.SIG_IGN)
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                if current:
                    activate(current)
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
