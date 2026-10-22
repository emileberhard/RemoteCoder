#!/usr/bin/env python3
"""Build exact Codex commits through the same leased build-host cache from either Mac."""

import argparse
import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import tomllib
import uuid
from contextlib import ExitStack, contextmanager
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_hosts
from build_artifacts import tree_digest, valid_package
from build_support import (
    Timings,
    build_capacity,
    build_environment,
    cache_root,
    file_lease,
    job_sleep_assertion,
    require_build_space,
    run_connected,
    run_owned,
)
from job_power import host_job_assertion

SSH = [
    "ssh",
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=5",
    "-o",
    "ServerAliveInterval=15",
    "-o",
    "ServerAliveCountMax=3",
]
TOOLS = (
    "codex-build.py",
    "build_hosts.py",
    "maintainer_config.py",
    "build_support.py",
    "job_power.py",
    "process_group.py",
    "build_artifacts.py",
    "rusty-v8-artifacts.py",
)
MAX_CACHED_PACKAGES = 8


def output(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs).strip()


def make_cache_room(root: Path, keep: Path) -> bool:
    """Reserve room before building; only live collectors can pin package bytes."""
    pinned = set()
    abandoned_packages = []
    for run in (root / "runs").glob("*"):
        if not run.is_dir():
            continue
        with (run / "collection.lock").open("a") as reader:
            try:
                fcntl.flock(reader, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                receipt_path = run / "receipt.json"
                if not receipt_path.exists():
                    continue  # A queued worker has not published a package yet.
                try:
                    receipt = json.loads(receipt_path.read_text())
                except (OSError, ValueError):
                    return False
                if receipt.get("exitCode") == 0:
                    pinned.add(receipt["package"])
            else:
                # An interrupted build has no live owner. The caller holds the
                # source lease, including any still-running compiler child.
                abandoned = run / "package"
                if abandoned.exists():
                    abandoned_packages.append(abandoned)
    if str(keep) in pinned:
        return False
    packages = root / "packages"
    packages.mkdir(parents=True, exist_ok=True)
    entries = sorted(
        (p for p in packages.iterdir() if p.is_dir() and p != keep),
        key=lambda p: p.stat().st_mtime,
    )
    eligible = [
        p
        for p in entries
        if str(p) not in pinned and re.fullmatch(r"[0-9a-f]{64}", p.name)
    ]
    # Refuse before deleting anything when readers/legacy entries alone fill
    # the cache. Otherwise retire only enough oldest packages to reserve one slot.
    if len(entries) - len(eligible) >= MAX_CACHED_PACKAGES:
        return False
    retire_count = max(0, len(entries) - MAX_CACHED_PACKAGES + 1)
    for abandoned in abandoned_packages:
        shutil.rmtree(abandoned)
    if keep.exists():
        shutil.rmtree(keep)
    keep.with_suffix(".json").unlink(missing_ok=True)
    for disposable in eligible[:retire_count]:
        shutil.rmtree(disposable)
        disposable.with_suffix(".json").unlink(missing_ok=True)
    return True


@contextmanager
def staged_package(run: Path):
    staged = run / "package"
    try:
        yield staged
    finally:
        if staged.exists():
            shutil.rmtree(staged)


@contextmanager
def collecting_worker(command):
    """Keep the worker's reader lease alive until collection succeeds or fails."""
    process = subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    )
    ready = False

    def cancel(signum, _frame):
        raise SystemExit(128 + signum)

    previous = {
        sig: signal.signal(sig, cancel)
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    }
    try:
        line = process.stdout.readline()
        if not line:
            raise ValueError(
                "Codex worker returned no receipt; inspect its recorded run"
            )
        receipt = json.loads(line)
        ready = True
        yield receipt
    finally:
        # EOF is the collection acknowledgement, on success and every failure.
        process.stdin.close()
        if not ready and process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        finally:
            process.stdout.close()
            for sig, handler in previous.items():
                signal.signal(sig, handler)


@job_sleep_assertion()
def serve_worker(run: Path):
    with file_lease(run / "collection.lock"):
        try:
            receipt = worker(run)
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            # Admission/source failures happen before the normal artifact receipt.
            # Keep their identity and diagnostics available to the collector too.
            receipt = {
                "buildId": run.name,
                "sourceCommit": None,
                "exitCode": 1,
                "error": str(error),
                "host": socket.gethostname(),
                "log": str(run / "build.log"),
            }
            try:
                request = json.loads((run / "request.json").read_text())
                receipt["sourceCommit"] = request.get("commit")
            except (OSError, ValueError):
                pass
            try:
                progress = json.loads((run / "progress.json").read_text())
                receipt["phasesSeconds"] = progress.get("phasesSeconds", {})
                receipt["elapsedSeconds"] = progress.get("elapsedSeconds")
            except (OSError, ValueError):
                pass
            with (run / "build.log").open("a") as log:
                log.write(str(error) + "\n")
            temporary = run / "receipt.tmp"
            temporary.write_text(json.dumps(receipt, indent=2) + "\n")
            temporary.replace(run / "receipt.json")
        print(json.dumps(receipt), flush=True)
        if receipt["exitCode"] == 0:
            # The caller keeps this stdin pipe open throughout rsync/readback.
            # EOF, cancellation or process death releases the live reader lease.
            sys.stdin.read(1)
        return receipt["exitCode"]


def build_inputs(commit, profile, environment, scripts, repo):
    # The commit includes the package builder and resource manifests. Host flags
    # and toolchain identity additionally distinguish otherwise identical sources.
    return {
        "commit": commit,
        "target": "aarch64-apple-darwin",
        "profile": profile,
        "rustc": output(["rustc", "-Vv"], env=environment, cwd=repo / "codex-rs"),
        "cargo": output(["cargo", "-V"], env=environment, cwd=repo / "codex-rs"),
        "python": sys.version,
        "xcode": output(["xcodebuild", "-version"], env=environment),
        "cargoConfig": {
            name: hashlib.sha256(
                (
                    Path(environment.get("CARGO_HOME", str(Path.home() / ".cargo")))
                    / name
                ).read_bytes()
            ).hexdigest()
            for name in ("config", "config.toml")
            if (
                Path(environment.get("CARGO_HOME", str(Path.home() / ".cargo"))) / name
            ).is_file()
        },
        "scripts": {
            name: hashlib.sha256((scripts / name).read_bytes()).hexdigest()
            for name in TOOLS
        },
        "flagsHash": hashlib.sha256(
            json.dumps(
                {
                    k: v
                    for k, v in environment.items()
                    if k.startswith(("RUST", "CARGO_"))
                    or k
                    in (
                        "SDKROOT",
                        "DEVELOPER_DIR",
                        "CC",
                        "CXX",
                        "CFLAGS",
                        "CXXFLAGS",
                        "LDFLAGS",
                        "PATH",
                    )
                },
                sort_keys=True,
            ).encode()
        ).hexdigest(),
    }


def worker(run: Path):
    request = json.loads((run / "request.json").read_text())
    root = cache_root() / "codex-runtime"
    root.mkdir(parents=True, exist_ok=True)
    timings = Timings(run)
    environment = build_environment("codex", os.environ, run)
    environment["DEVELOPER_DIR"] = request["developerDirectory"]
    environment.update(
        {
            "CARGO_TARGET_DIR": str(root / "target"),
            "RUSTC_WRAPPER": "/opt/homebrew/bin/sccache",
        }
    )
    with ExitStack() as ownership:
        with timings.phase("worktreeWait"):
            lease = ownership.enter_context(file_lease(root / "build.lock"))
            os.utime(lease, None)
            ownership.callback(os.utime, lease, None)
        repo = root / "repo"
        with timings.phase("source"):
            bundle = run / "source.bundle"
            if not (repo / ".git").is_dir():
                subprocess.run(
                    ["git", "clone", "--quiet", str(bundle), str(repo)],
                    check=True,
                    pass_fds=(lease,),
                )
            else:
                if output(["git", "-C", str(repo), "status", "--porcelain"]):
                    raise ValueError("Codex build mirror has uncommitted changes")
                if bundle.exists():
                    subprocess.run(
                        [
                            "git",
                            "-C",
                            str(repo),
                            "fetch",
                            "--quiet",
                            str(bundle),
                            "HEAD",
                        ],
                        check=True,
                        pass_fds=(lease,),
                    )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repo),
                    "switch",
                    "--quiet",
                    "--detach",
                    request["commit"],
                ],
                check=True,
                pass_fds=(lease,),
            )
            if (
                output(["git", "-C", str(repo), "rev-parse", "HEAD"])
                != request["commit"]
            ):
                raise ValueError("Codex source identity changed")
            subprocess.run(
                ["git", "-C", str(repo), "clean", "-ffdx", "--quiet"],
                check=True,
                pass_fds=(lease,),
                env=environment,
            )
            bundle.unlink(missing_ok=True)
        inputs = build_inputs(
            request["commit"], request["profile"], environment, run / "tools", repo
        )
        key = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
        package = root / "packages" / key
        record = root / "packages" / (key + ".json")
        receipt = {
            "buildId": request["buildId"],
            "sourceCommit": request["commit"],
            "inputs": inputs,
            "inputKey": key,
            "package": str(package),
            "reused": False,
            "host": socket.gethostname(),
            "log": str(run / "build.log"),
        }
        with timings.phase("packageLookup"):
            try:
                previous = json.loads(record.read_text())
                hit = previous["inputKey"] == key and valid_package(
                    package, previous["packageSHA256"]
                )
            except (OSError, ValueError, KeyError):
                hit = False
        if hit:
            receipt.update(
                {
                    "reused": True,
                    "packageSHA256": previous["packageSHA256"],
                    "exitCode": 0,
                }
            )
            record.touch()
            package.touch()
        else:
            if not make_cache_room(root, package):
                raise ValueError(
                    f"Codex package cache {root / 'packages'} is full with active readers or legacy/unowned entries; "
                    "wait for collection or review legacy cache ownership before retirement"
                )
            with timings.phase("capacityWait"):
                capacity = ownership.enter_context(build_capacity(background=True))
            require_build_space(root)
            environment.update(
                {"CODEX_REPO_ROOT": str(repo), "CODEX_SOURCE_COMMIT": request["commit"]}
            )
            with timings.phase("v8"):
                # The existing resolver returns shell assignments. Evaluate them
                # only in the build shell; never copy provider credentials into receipts.
                exports = output(
                    [
                        sys.executable,
                        str(run / "tools/rusty-v8-artifacts.py"),
                        "--codex-repo",
                        str(repo),
                        "--cache-dir",
                        str(cache_root() / "rusty_v8"),
                    ],
                    env=environment,
                )
            staged = ownership.enter_context(staged_package(run))
            command = [
                sys.executable,
                "scripts/build_codex_package.py",
                "--target",
                "aarch64-apple-darwin",
                "--variant",
                "codex",
                "--package-dir",
                str(staged),
                "--cargo-profile",
                request["profile"],
            ]
            with (
                timings.phase("compileAndPackage"),
                (run / "build.log").open("w") as log,
            ):
                status = run_owned(
                    ["bash", "-c", exports + "\nexec " + shlex.join(command)],
                    repo,
                    environment,
                    log,
                    (lease, capacity),
                )
            receipt["exitCode"] = status
            if status == 0:
                with timings.phase("publish"):
                    receipt["packageSHA256"] = tree_digest(staged)
                    package.parent.mkdir(parents=True, exist_ok=True)
                    staged.replace(package)
                    temporary = record.with_suffix(".tmp")
                    temporary.write_text(json.dumps(receipt, indent=2) + "\n")
                    temporary.replace(record)
        # Publish the package association while the serving process holds its reader lease.
        receipt.update(
            {
                "phasesSeconds": timings.durations,
                "elapsedSeconds": round(time.monotonic() - timings.started, 3),
            }
        )
        temporary_receipt = run / "receipt.tmp"
        temporary_receipt.write_text(json.dumps(receipt, indent=2) + "\n")
        temporary_receipt.replace(run / "receipt.json")
    return receipt


UPLOAD_RECEIVER = """import pathlib,sys,os
run=pathlib.Path(sys.argv[1]); sys.path.insert(0,str(run/'receiver-bootstrap'))
from build_support import file_lease,job_sleep_assertion,run_owned
with job_sleep_assertion(),file_lease(run/'collection.lock') as lease:
 status=run_owned(['rsync',*sys.argv[2:]],run,os.environ,sys.stdout,(lease,),termination_grace_seconds=30,error_output=sys.stderr)
sys.exit(status)
"""


def prepare_upload_receiver(shell: list[str], run: Path):
    prepare = """import fcntl,json,pathlib,sys
run=pathlib.Path(sys.argv[1]); run.mkdir(parents=True,exist_ok=True)
with (run/'collection.lock').open('a') as lease:
 fcntl.flock(lease,fcntl.LOCK_EX)
 payload=json.load(sys.stdin); bootstrap=run/'receiver-bootstrap'; bootstrap.mkdir(exist_ok=True)
 for name in ['build_support.py','process_group.py','job_power.py']: bootstrap.joinpath(name).write_text(payload[name])
 run.joinpath('rsync-upload.py').write_text(payload['receiver'])
"""
    payload = {name: Path(__file__).with_name(name).read_text() for name in ("build_support.py", "process_group.py", "job_power.py")}
    payload["receiver"] = UPLOAD_RECEIVER
    subprocess.run([*shell, "umask 077; " + shlex.join(["python3", "-c", prepare, str(run)])],
                   input=json.dumps(payload), text=True, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", nargs="?", type=Path)
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--profile", default="release")
    args = parser.parse_args()
    if args.worker:
        return serve_worker(args.source)
    source = args.source.resolve()
    if output(["git", "-C", str(source), "status", "--porcelain"]):
        raise ValueError("Codex source must be clean for an exact-commit build")
    commit = output(["git", "-C", str(source), "rev-parse", "HEAD"])
    cargo_manifest = output(
        ["git", "-C", str(source), "show", commit + ":codex-rs/Cargo.toml"]
    )
    version = tomllib.loads(cargo_manifest)["workspace"]["package"]["version"]
    if not isinstance(version, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9.+-]*", version
    ):
        raise ValueError("Codex workspace version is not a safe package version")
    host = os.environ.get("RC_GATEWAY_BUILD_HOST") or build_hosts.build_host(
        Path(__file__).resolve().parents[1]
    )
    local = build_hosts.is_local(host)

    def host_output(command):
        return output(command if local else [*SSH, host, shlex.join(command)])

    home = json.loads(
        host_output(
            [
                "python3",
                "-c",
                "import json; from pathlib import Path; print(json.dumps(str(Path.home())))",
            ]
        )
    )
    build_id = uuid.uuid4().hex
    root = Path(home) / "Library/Caches/RemoteCoder-Build/codex-runtime"
    run = root / "runs" / build_id
    shell = ["bash", "-c"] if local else [*SSH, host]
    with host_job_assertion(shell, run / "collection.lock") as power_pid:
        print(f"Build-host sleep owner: {host} PID {power_pid}", file=sys.stderr)
        host_output(["mkdir", "-p", str(run / "tools")])
        print(f"Codex build {build_id}: {host}:{run}", file=sys.stderr)
        with tempfile.TemporaryDirectory(prefix="codex-build-") as temporary:
            staging = Path(temporary)
            for name in TOOLS:
                shutil.copy2(Path(__file__).parent / name, staging / name)
            request = {
                "buildId": build_id,
                "commit": commit,
                "profile": args.profile,
                "developerDirectory": os.environ.get("RC_XCODE_DEVELOPER_DIR")
                or os.environ.get("DEVELOPER_DIR")
                or "/Applications/Xcode-"
                + (Path(__file__).resolve().parents[1] / ".xcode-version")
                .read_text()
                .strip()
                + ".app/Contents/Developer",
            }
            (staging / "request.json").write_text(json.dumps(request))
            # A previous worker may still be compiling. Read Git object availability
            # without changing that checkout; its objects remain in the shared store.
            probe = "import subprocess,json,sys; r=sys.argv[1]; c=sys.argv[2]; p=subprocess.run(['git','-C',r,'rev-parse','HEAD'],capture_output=True,text=True); q=subprocess.run(['git','-C',r,'cat-file','-e',c+'^{commit}'],capture_output=True); print(json.dumps({'base':p.stdout.strip() if p.returncode==0 else None,'hasCommit':q.returncode==0}))"
            known = json.loads(
                host_output(["python3", "-c", probe, str(root / "repo"), commit])
            )
            if not known["hasCommit"]:
                command = [
                    "git",
                    "-C",
                    str(source),
                    "bundle",
                    "create",
                    str(staging / "source.bundle"),
                    "HEAD",
                ]
                base = known["base"]
                if (
                    base
                    and subprocess.run(
                        [
                            "git",
                            "-C",
                            str(source),
                            "merge-base",
                            "--is-ancestor",
                            base,
                            commit,
                        ],
                        capture_output=True,
                        check=False,
                    ).returncode
                    == 0
                ):
                    command.append("^" + base)
                subprocess.run(command, check=True)

            prepare_upload_receiver(shell, run)

            def transfer(src, dest):
                if local:
                    command = ["python3", str(run / "rsync-upload.py"), str(run), "-a", str(src), str(dest)]
                    result = run_connected(command)
                    if result.returncode != 0:
                        raise subprocess.CalledProcessError(result.returncode, command)
                    return
                subprocess.run(
                    [
                        "rsync", "-a", "-e", shlex.join(SSH),
                        "--rsync-path=" + shlex.join(["python3", str(run / "rsync-upload.py"), str(run)]),
                        str(src), host + ":" + str(dest),
                    ],
                    check=True,
                )

            for name in TOOLS:
                transfer(staging / name, run / "tools" / name)
            transfer(staging / "request.json", run / "request.json")
            if (staging / "source.bundle").exists():
                transfer(staging / "source.bundle", run / "source.bundle")
        command = ["python3", str(run / "tools/codex-build.py"), "--worker", str(run)]
        with collecting_worker(
            command if local else [*SSH, host, shlex.join(command)]
        ) as receipt:
            receipts = Path(__file__).resolve().parents[1] / "build/receipts" / build_id
            receipts.mkdir(parents=True, exist_ok=True)
            (receipts / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
            if receipt["exitCode"]:
                print(
                    f"Codex build failed: {host}:{receipt['log']}"
                    + (f" — {receipt['error']}" if receipt.get("error") else ""),
                    file=sys.stderr,
                )
                return receipt["exitCode"]
            destination = (
                args.destination or Path("/tmp") / ("remotecoder-codex-package-" + version)
            ).resolve()
            if destination.exists() and valid_package(
                destination, receipt["packageSHA256"]
            ):
                print(f"codex_package={destination}")
                return 0
            destination.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(
                prefix="codex-package-", dir=destination.parent
            ) as temporary:
                copied = Path(temporary) / "package"
                subprocess.run(
                    [
                        "rsync",
                        "-a",
                        ("" if local else host + ":") + receipt["package"] + "/",
                        str(copied) + "/",
                    ],
                    check=True,
                )
                if not valid_package(copied, receipt["packageSHA256"]):
                    raise ValueError("Returned Codex package identity does not match")
                if destination.exists():
                    raise ValueError(
                        f"Output already contains another package; choose a new path: {destination}"
                    )
                copied.replace(destination)
            print(f"codex_package={destination}")
            return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
