#!/usr/bin/env python3
"""Snapshot source and run RemoteCoder's existing build recipes under worktree-scoped leases."""

import argparse
import fcntl
import hashlib
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from contextlib import ExitStack, nullcontext
from datetime import UTC, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_hosts
import gateway_bundle
from maintainer_config import configure
from bench_lab import reject_unsafe_location
from build_artifacts import tree_digest
from build_cache import (
    cache_allocated_bytes,
    cargo_seed_key,
    compilation_admission,
    compilation_directories,
    lease_path,
    load_policy,
    local_worktrees,
    prune_caches,
    purge_xcode_environments,
    read_policy,
    record_compilation,
    record_mirror_source,
    seed_cargo,
    seed_source_packages,
    shared_compilation_directories,
    touch_usage,
)
from build_support import (
    Timings,
    atomic_json,
    build_capacity,
    build_environment,
    canonical_path,
    connected_cancellation,
    file_lease,
    job_sleep_assertion,
    require_build_space,
    run_connected,
    run_owned,
    source_lease_path,
    source_sync_command,
)
from concurrent_lanes import lane_streams
from job_power import host_job_assertion
from xcode_build import (
    verify_xcode_evidence,
    xcode_exit_zero_diagnostics,
)


def ios_device_variant(arguments):
    modes = set(arguments) & {"--optimized", "--incremental-optimized", "--unoptimized"}
    if len(modes) > 1:
        raise ValueError("Select only one optimization mode")
    if "--unoptimized" in modes:
        return "-ios-unoptimized"
    if "--optimized" in modes:
        return ""
    return "-ios-incremental-optimized"


ROOT = canonical_path(Path(__file__).resolve().parents[1])
KINDS = (
    "ios-install",
    "ios-build",
    "mac-build",
    "mac-harness-build",
    "mac-install",
    "mac-bench",
    "ios-simulator-test",
    "ios-ui-test",
    "core-test",
    "gateway",
    "gateway-release",
    "gateway-check",
    "gateway-test",
    "tools-test",
    "verify",
    "verify-all",
)
SSH = [
    "ssh",
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=5",
    "-o",
    "ServerAliveInterval=5",
    "-o",
    "ServerAliveCountMax=3",
]
SIMULATOR_KINDS = frozenset(
    ("ios-simulator-test", "ios-ui-test", "verify-all")
)
GATEWAY_ARTIFACT_KINDS = frozenset(("gateway", "gateway-release"))
IOS_KINDS = frozenset(
    (
        "ios-install",
        "ios-build",
        "mac-build",
        "mac-harness-build",
        "mac-install",
        "mac-bench",
        "ios-simulator-test",
        "ios-ui-test",
        "core-test",
        "verify",
        "verify-all",
    )
)
UNSIGNED_WORKER_KINDS = frozenset(KINDS) - {"ios-install"}
MAC_APP_KINDS = frozenset(("mac-install", "mac-bench"))


def selected_build_host(kind: str, environment) -> str:
    variable = (
        "RC_IOS_BUILD_HOST"
        if kind.startswith("ios-") or kind == "verify-all"
        else "RC_GATEWAY_BUILD_HOST"
    )
    default = build_hosts.MAC_GUI_HOST if kind in MAC_APP_KINDS else build_hosts.build_host(ROOT)
    return environment.get(variable, default)

LAB_VALIDATION = """import json,pathlib,sys,types
payload=json.load(sys.stdin)
for name in ['process_group','release_config','bench_lab']:
 module=types.ModuleType(name)
 module.__file__=str(pathlib.Path(payload['snapshotRoot'])/'scripts'/name)
 sys.modules[name]=module
 exec(payload['modules'][name],module.__dict__)
sys.modules['bench_lab'].load_config(pathlib.Path(payload['config']),pathlib.Path(payload['snapshotRoot']),sys.modules['release_config'].validate_development)
print(json.dumps({'validated':True}))
"""


def validate_lab_request(arguments: list[str], shell: list[str]) -> None:
    parser = argparse.ArgumentParser(prog="mac-bench build")
    parser.add_argument("--lab-config", type=Path)
    path = parser.parse_args(arguments).lab_config
    if path is None:
        return
    if not path.is_absolute():
        raise ValueError("Lab configuration needs an absolute MacBook path.")
    reject_unsafe_location(path.parent, ROOT)
    files = {"process_group": "process_group.py", "release_config": "release-config.py", "bench_lab": "bench_lab.py"}
    payload = {"config": str(path), "snapshotRoot": str(ROOT),
               "modules": {name: (ROOT / "scripts" / filename).read_text() for name, filename in files.items()}}
    result = subprocess.run([*shell, shlex.join(["python3", "-c", LAB_VALIDATION])],
                            input=json.dumps(payload), capture_output=True, text=True, timeout=30, check=False)
    if result.returncode != 0 or result.stdout.strip() != '{"validated": true}':
        raise ValueError("MacBook lab validation failed; start the isolated gateway owner and check the private configuration.")


def fingerprint(root: Path, files: list[str]) -> str:
    digest = hashlib.sha256()
    for name in files:
        path = root / name
        digest.update(name.encode() + b"\0")
        digest.update(str(path.lstat().st_mode & 0o111).encode() + b"\0")
        if path.is_symlink():
            digest.update(b"link\0" + os.readlink(path).encode())
        else:
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
        digest.update(b"\0")
    return digest.hexdigest()


def source_manifest(root: Path, kind: str, arguments: list[str]) -> dict:
    root = canonical_path(root)
    if kind in IOS_KINDS:
        configure(root)
    output = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
    )
    files = set(output.decode().rstrip("\0").split("\0"))
    identity_config = "Config/Local.xcconfig"
    if kind in IOS_KINDS and (root / identity_config).is_file():
        files.add(identity_config)
    private_config = "RemoteCoder/Resources/RemoteCoderLocalConfig.json"
    includes_private_config = kind == "ios-install" or (
        kind == "ios-simulator-test" and os.environ.get("RC_LIVE_GATEWAY") == "1"
    )
    if includes_private_config and (root / private_config).exists():
        files.add(private_config)
    else:
        files.discard(private_config)
    files = sorted(
        name
        for name in files
        if name and ((root / name).exists() or (root / name).is_symlink())
    )
    identity = hashlib.sha256(
        (socket.gethostname() + ":" + str(root)).encode()
    ).hexdigest()[:16]
    return {
        "kind": kind,
        "arguments": arguments,
        "background": os.environ.get("CI") == "true",
        "worktreeId": identity,
        "sourceHost": socket.gethostname(),
        "sourceRoot": str(root),
        "buildId": uuid.uuid4().hex,
        "sourceCommit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True
        ).strip(),
        "sourceFingerprint": fingerprint(root, files),
        "sourceModified": bool(
            subprocess.check_output(["git", "status", "--porcelain"], cwd=root)
        ),
        "files": files,
        "callWorkerFiles": sorted(subprocess.check_output(
            ["git", "ls-files", "--cached", "-z", "agent-calls/agent_calls", "dev-tools/src",
             "agent-calls/pyproject.toml", "agent-calls/uv.lock", "dev-tools/pyproject.toml", "dev-tools/uv.lock", "dev-tools/agent-call"],
            cwd=root,
        ).decode().rstrip("\0").split("\0")),
        "environment": {
            key: os.environ[key]
            for key in (
                "RC_XCODE_DEVELOPER_DIR",
                "DEVELOPER_DIR",
                "RC_IOS_SIMULATOR",
                "RC_FORCE_CHECKS",
                "RC_RELEASE_VERSION",
                "RC_CLAUDE_MIGRATION_FIXTURE_HOME",
                "RC_LIVE_GATEWAY",
                "COMPILATION_CACHE_ENABLE_CACHING_DEFAULT",
                "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS",
                "SWIFT_ENABLE_PREFIX_MAPPING",
                "SWIFT_ENABLE_PROJECT_PREFIX_MAPPING",
                "CompilationCachingCASPath",
                "CompilationCachingDiskSizeLimit",
            )
            if key in os.environ
        },
    }


def build_command(kind: str, arguments: list[str]) -> list[str]:
    if kind == "ios-install":
        return ["./scripts/install-device", *arguments]
    if kind in ("ios-simulator-test", "ios-ui-test"):
        return ["just", kind + "-local", *arguments]
    if kind == "ios-build":
        return ["just", "ios-build-local"]
    if kind == "mac-build":
        return ["just", "mac-build-local", *arguments]
    if kind == "mac-harness-build":
        return ["just", "mac-harness-build-local"]
    if kind == "mac-install":
        return ["./scripts/install-mac"]
    if kind == "mac-bench":
        return ["./scripts/install-mac", "--bench", *arguments]
    if kind == "gateway":
        return ["just", "gateway-candidate-local"]
    if kind == "gateway-release":
        return ["just", "gateway-release-local"]
    if kind in ("core-test", "gateway-check", "gateway-test", "tools-test"):
        return ["just", kind + "-local", *arguments]
    if kind == "verify-all":
        return ["just", kind + "-local"]
    if kind == "verify":
        return ["just", "verify-local"]
    raise ValueError(f"Unsupported build kind: {kind}")


TRANSFER_RECEIVER = """import os,pathlib,sys
run=pathlib.Path(sys.argv[1])
bootstrap=run/'receiver-bootstrap'
if not all((bootstrap/name).is_file() for name in ['build_support.py','process_group.py','job_power.py']):
 raise SystemExit('Rsync job owner is missing')
sys.path.insert(0,str(bootstrap))
from build_support import file_lease,job_sleep_assertion,run_owned
path=run.parent.parent/'leases/runs'/f'{run.name}.lock'
with job_sleep_assertion(),file_lease(path) as lease:
 status=run_owned(['rsync',*sys.argv[2:]],run,os.environ,sys.stdout,(lease,),termination_grace_seconds=30,error_output=sys.stderr)
sys.exit(status)
"""

TRANSFER_FAILURE = """import fcntl,json,os,pathlib,sys,tempfile,time
run=pathlib.Path(sys.argv[1])
if not run.is_dir(): sys.exit(0)
path=run.parent.parent/'leases/runs'/f'{run.name}.lock'
path.parent.mkdir(parents=True,exist_ok=True)
with path.open('a') as lease:
 fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
 if any((run/name).exists() for name in ('receipt.json','outcome.json')): sys.exit(1)
 fd,name=tempfile.mkstemp(dir=run,prefix='.outcome.')
 try:
  with os.fdopen(fd,'w') as stream: json.dump({'exitCode':1,'phase':'sourceTransfer','finishedAt':time.time()},stream)
  os.replace(name,run/'outcome.json')
 finally:
  pathlib.Path(name).unlink(missing_ok=True)
 path.with_suffix('.used').touch()
"""


def record_transfer_failure(shell: list[str], run: Path):
    command = shlex.join(["python3", "-c", TRANSFER_FAILURE, str(run)])
    try:
        result = subprocess.run(
            [*shell, command],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=15,
            check=False,
        )
        recorded = result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        recorded = False
    if not recorded:
        print(
            f"Transfer failure could not be recorded under the run lease; {run} remains protected as unknown",
            file=sys.stderr,
        )


def prepare_transfer(shell: list[str], run: Path, scripts: Path):
    prepare = ("import json,pathlib,sys; run=pathlib.Path(sys.argv[1]); "
               "run.joinpath('repo').mkdir(parents=True,exist_ok=True); "
               "bootstrap=run/'receiver-bootstrap'; bootstrap.mkdir(exist_ok=True); "
               "payload=json.load(sys.stdin); "
               "[bootstrap.joinpath(name).write_text(payload[name]) for name in ['build_support.py','process_group.py','job_power.py']]; "
               "run.joinpath('rsync-receiver.py').write_text(payload['receiver'])")
    payload = {name: (scripts / name).read_text()
               for name in ["build_support.py", "process_group.py", "job_power.py"]}
    payload["receiver"] = TRANSFER_RECEIVER
    subprocess.run([*shell, "umask 077; " + shlex.join(["python3", "-c", prepare, str(run)])],
                   input=json.dumps(payload), text=True, check=True)


def owned_rsync_options(destination: str, run: Path) -> list[str]:
    return ["-e", shlex.join(SSH), "--rsync-path=" + shlex.join(
        ["python3", str(run / "rsync-receiver.py"), str(run)])] if destination else []


SYMBOL_MIRROR_FINALIZE = """import json,pathlib,sys,time
run=pathlib.Path(sys.argv[1])
sys.path.insert(0,str(run/'receiver-bootstrap'))
from build_support import atomic_json,file_lease
namespace={}
payload=json.loads(sys.stdin.readline())
exec(payload['build_artifacts.py'],namespace)
(run/'receiver-bootstrap/build_cache.py').write_text(payload['build_cache.py'])
from build_cache import load_policy,prune_caches
expected=json.loads(sys.stdin.readline())
with file_lease(run.parent.parent/'leases/runs'/f'{run.name}.lock'):
 if namespace['tree_digest'](run/'symbols') != expected: raise SystemExit('Mirrored dSYM fingerprint mismatch')
 atomic_json(run/'outcome.json',{'exitCode':0,'finishedAt':time.time(),'kind':'device-symbols'})
policy=load_policy()
retention=prune_caches(run.parent.parent,policy,'',run.name)
evidence={'retention':retention,'allocatedBytes':None,'unavailableReason':'Whole-cache accounting is owned by maintenance'}
atomic_json(run/'symbol-cache.json',evidence)

"""


def mirror_device_symbols(artifact: dict, manifest: dict, scripts: Path) -> dict:
    host = build_hosts.TEST_DEVICE_HOST
    local = build_hosts.is_local(host)
    shell = ["bash", "-c"] if local else [*SSH, host]
    destination = "" if local else host + ":"
    home = json.loads(subprocess.check_output(
        [*shell, "python3 -c 'import json,pathlib; print(json.dumps(str(pathlib.Path.home())))'"], text=True))
    run = Path(home) / "Library/Caches/RemoteCoder-Build/runs" / ("symbols-" + manifest["buildId"])
    try:
        prepare_transfer(shell, run, scripts)
        with host_job_assertion(shell, lease_path(run.parent.parent, "runs", run.name)):
            source = Path(artifact["symbols"][0]["path"])
            with file_lease(lease_path(run.parent.parent, "runs", run.name)) if local else nullcontext():
                subprocess.run(["rsync", "-a", *owned_rsync_options(destination, run),
                                str(source) + "/", destination + str(run / "symbols") + "/"], check=True)
            payload = json.dumps({name: (scripts / name).read_text()
                                  for name in ("build_artifacts.py", "build_cache.py")})
            subprocess.run([*shell, shlex.join(["python3", "-c", SYMBOL_MIRROR_FINALIZE, str(run)])],
                           input=payload + "\n" + json.dumps(artifact["symbols"][0]["sha256"]) + "\n",
                           text=True, check=True)
    except BaseException:
        record_transfer_failure(shell, run)
        raise
    return {"host": host, "directory": str(run / "symbols")}


def transfer_source(shell: list[str], destination: str, run: Path, manifest: dict):
    try:
        prepare_transfer(shell, run, Path(__file__).parent)
        ownership = (
            nullcontext()
            if destination
            else file_lease(lease_path(run.parent.parent, "runs", run.name))
        )
        with (
            ownership,
            tempfile.TemporaryDirectory(prefix="remotecoder-build-") as temporary,
        ):
            file_list = Path(temporary) / "files"
            file_list.write_bytes(
                b"\0".join(name.encode() for name in manifest["files"]) + b"\0"
            )
            metadata = Path(temporary) / "source.json"
            metadata.write_text(json.dumps(manifest))
            receiver = owned_rsync_options(destination, run)
            subprocess.run(
                [
                    "rsync",
                    "-a",
                    *receiver,
                    "--from0",
                    "--files-from=" + str(file_list),
                    str(ROOT) + "/",
                    destination + str(run / "repo") + "/",
                ],
                check=True,
            )
            if (
                source_manifest(ROOT, manifest["kind"], manifest["arguments"])[
                    "sourceFingerprint"
                ]
                != manifest["sourceFingerprint"]
            ):
                raise ValueError(
                    "Source changed while making the build snapshot; rerun from settled inputs"
                )
            subprocess.run(
                [
                    "rsync",
                    "-a",
                    *receiver,
                    str(metadata),
                    destination + str(run / "source.json"),
                ],
                check=True,
            )
    except (OSError, ValueError, subprocess.CalledProcessError, KeyboardInterrupt):
        record_transfer_failure(shell, run)
        raise


def connected_worker(run: Path) -> int:
    root = run.parent.parent
    with (
        connected_cancellation() as cancellation,
        file_lease(lease_path(root, "runs", run.name)) as lease,
    ):
        touch_usage(root, "runs", run.name)
        try:
            with (run / "worker.log").open("w") as output:
                status = run_owned(
                    [sys.executable, str(Path(__file__).resolve()), "worker", str(run)],
                    run,
                    os.environ,
                    output,
                    (lease,),
                    cancellation=cancellation,
                    termination_grace_seconds=30,
                    stdin=subprocess.DEVNULL,
                )
        except SystemExit as error:
            status = error.code
        finally:
            touch_usage(root, "runs", run.name)
        receipt_path = run / "receipt.json"
        if receipt_path.is_file():
            receipt = json.loads(receipt_path.read_text())
            if receipt["exitCode"] != status:
                raise ValueError("Worker receipt disagrees with its process exit")
        else:
            manifest = json.loads((run / "source.json").read_text())
            receipt = {
                key: manifest[key]
                for key in (
                    "kind",
                    "worktreeId",
                    "buildId",
                    "sourceCommit",
                    "sourceFingerprint",
                )
            }
            receipt.update(
                {
                    "exitCode": status or 1,
                    "log": str(run / "worker.log"),
                    "error": "Build worker ended before producing a receipt",
                }
            )
            status = receipt["exitCode"]
        admission = run / "cache-admission.json"
        if admission.is_file():
            receipt["compilationCache"] = json.loads(admission.read_text())
        atomic_json(
            run / "outcome.json", {"exitCode": status, "finishedAt": time.time()}
        )
        print(json.dumps(receipt), flush=True)
        return status


def mirror_source_command(source: Path, repository: Path) -> list[str]:
    return source_sync_command(
        [
            "--delete",
            str(source) + "/",
            str(repository) + "/",
        ]
    )



def worker(run: Path) -> dict:
    timings = Timings(run)
    manifest = json.loads((run / "source.json").read_text())
    source = run / "repo"
    if fingerprint(source, manifest["files"]) != manifest["sourceFingerprint"]:
        raise ValueError(
            "The transferred build snapshot does not match its source fingerprint"
        )
    group = "ios" if manifest["kind"] in IOS_KINDS else "gateway"
    cache = (
        Path.home()
        / "Library/Caches/RemoteCoder-Build/worktrees"
        / manifest["worktreeId"]
        / group
    )
    cache.mkdir(parents=True, exist_ok=True)
    artifact = run / "artifacts" / gateway_bundle.NAME
    artifact.parent.mkdir(parents=True, exist_ok=True)
    environment = build_environment(manifest["kind"], os.environ, run)
    environment.update(manifest["environment"])
    environment.setdefault("RUST_TEST_THREADS", environment.get("EMIL_BUILD_JOBS", "4"))
    developer = environment.get("RC_XCODE_DEVELOPER_DIR") or environment.get(
        "DEVELOPER_DIR"
    )
    if not developer:
        developer = (
            "/Applications/Xcode-"
            + (source / ".xcode-version").read_text().strip()
            + ".app/Contents/Developer"
        )
    environment["DEVELOPER_DIR"] = developer
    environment.setdefault("COMPILATION_CACHE_ENABLE_CACHING_DEFAULT", "YES")
    environment.setdefault("SWIFT_ENABLE_PREFIX_MAPPING", "YES")
    environment.setdefault("SWIFT_ENABLE_PROJECT_PREFIX_MAPPING", "YES")
    toolchain = hashlib.sha256(developer.encode()).hexdigest()[:12]
    environment.update(
        {
            "RC_DERIVED_DATA": str(cache / ("derived-" + toolchain)),
            "CARGO_TARGET_DIR": str(cache.parent / "gateway" / "cargo"),
            "RC_GATEWAY_CANDIDATE_OUTPUT": str(artifact),
            "RC_BUILD_PROVENANCE": str(run / "source.json"),
            "RC_SWIFT_BUILD_PATH": str(cache / ("swift-" + toolchain)),
            "RC_BUILD_STAGES": str(run / "stages.jsonl"),
            "RC_COMPILATION_OWNER": "1",
        }
    )
    if manifest["kind"] == "ios-install":
        suffix = ios_device_variant(manifest["arguments"])
        if suffix:
            environment["RC_DERIVED_DATA"] += suffix
            environment["RC_IOS_DEVICE_VARIANT_SET"] = "1"
    root = cache.parents[2]
    with ExitStack() as ownership:
        with timings.phase("worktreeWait"):
            worktree_fd = ownership.enter_context(
                file_lease(lease_path(root, "worktrees", manifest["worktreeId"]))
            )
            legacy_fds = tuple(
                ownership.enter_context(file_lease(cache.parent / group / "build.lock"))
                for group in ("ios", "gateway")
            )
            touch_usage(root, "worktrees", manifest["worktreeId"])
        record_mirror_source(root, manifest)
        policy = load_policy()
        current_caches = compiler_paths(manifest["kind"], environment)
        with timings.phase("capacityWait"):
            capacity_fd = ownership.enter_context(
                build_capacity(
                    manifest["kind"] in SIMULATOR_KINDS
                    or manifest.get("background", False)
                )
            )
        with timings.phase("cacheAdmission"):
            compilation = admit_compilation(root, policy, current_caches)
            atomic_json(run / "cache-admission.json", compilation)
            cache_retired = prune_caches(root, policy, manifest["worktreeId"], run.name)
            if cache_retired.get("evictionFailures"):
                print(
                    "WARNING: Run-evidence retention failed partially; admission continues. See cacheRetired in the receipt.",
                    file=sys.stderr,
                    flush=True,
                )
        with timings.phase("packageSeed"):
            derived = Path(environment["RC_DERIVED_DATA"])
            if manifest["kind"] in {"mac-install", "mac-bench"}:
                derived = derived.with_name(derived.name + "-mac-optimized")
            package_seed = (
                seed_source_packages(root, manifest["worktreeId"], source, derived)
                if manifest["kind"] in IOS_KINDS
                else None
            )
        with timings.phase("cargoSeed"):
            cargo = Path(environment["CARGO_TARGET_DIR"])
            cargo_key = (
                cargo_seed_key(source, environment)
                if manifest["kind"]
                in {"gateway", "gateway-check", "gateway-test", "verify", "verify-all"}
                else None
            )
            cargo_seed = seed_cargo(
                root,
                manifest["worktreeId"],
                cargo_key,
                cargo,
                source / "host-daemon-rs/Cargo.toml",
                environment,
            )
            if cargo_seed is not None and cargo_seed.get("status") == "unseeded":
                print(
                    "WARNING: Cargo cache seed failed; continuing unseeded. See cargoSeed.failure in the build receipt.",
                    file=sys.stderr,
                    flush=True,
                )
            elif cargo_seed is not None and cargo_seed.get("cleanupWarning"):
                print(
                    "WARNING: Cargo cache seed was published, but staging cleanup failed. See cargoSeed.cleanupWarning in the build receipt.",
                    file=sys.stderr,
                    flush=True,
                )
        require_build_space(cache)
        repository = cache / "repo"
        repository.mkdir(exist_ok=True)
        with timings.phase("prepareMirror"):
            subprocess.run(
                mirror_source_command(source, repository),
                check=True,
                pass_fds=(worktree_fd, *legacy_fds, capacity_fd),
            )
        shutil.rmtree(source)
        simulator = None
        try:
            if manifest["kind"] in SIMULATOR_KINDS and not environment.get(
                "RC_IOS_SIMULATOR"
            ):
                with timings.phase("simulatorSetup"):
                    name = "RemoteCoder build " + manifest["buildId"]
                    simulator = subprocess.check_output(
                        [
                            "xcrun",
                            "simctl",
                            "create",
                            name,
                            "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                            "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                        ],
                        env=environment,
                        text=True,
                    ).strip()
                    environment["RC_IOS_SIMULATOR"] = name
                    for operation in (
                        ["boot", simulator],
                        ["bootstatus", simulator, "-b"],
                    ):
                        subprocess.run(
                            ["xcrun", "simctl", *operation],
                            env=environment,
                            check=True,
                            stdout=subprocess.DEVNULL,
                        )
            commands_started = time.time()
            xcode_warnings = []
            verified_products = []
            record_compilation(
                root, current_caches, manifest["buildId"], True, manifest
            )
            with timings.phase("commands"), (run / "build.log").open("w") as output:
                command = build_command(manifest["kind"], manifest["arguments"])
                status = run_owned(
                    command,
                    repository,
                    recipe_environment(repository, environment),
                    output,
                    (worktree_fd, *legacy_fds, capacity_fd),
                )
            record_compilation(
                root, current_caches, manifest["buildId"], False, manifest
            )
            stages_path = run / "stages.jsonl"
            stages = (
                [json.loads(line) for line in stages_path.read_text().splitlines()]
                if stages_path.is_file()
                else []
            )
            ios_artifact = run / "ios-artifact.json"
            if status == 0 and manifest["kind"] == "ios-install":
                artifact_evidence = json.loads(ios_artifact.read_text())
                subprocess.run(
                    [
                        "python3",
                        str(repository / "scripts/ios-device-artifact.py"),
                        "validate",
                        "--artifact",
                        str(ios_artifact),
                    ],
                    check=True,
                    env=environment,
                )
            if status == 0 and manifest["kind"] in IOS_KINDS:
                xcode_warnings = [
                    diagnostic
                    for stream in lane_streams((run / "build.log").read_text())
                    for diagnostic in xcode_exit_zero_diagnostics(stream)
                ]
                verified_products = verify_xcode_evidence(
                    manifest["kind"],
                    Path(environment["RC_DERIVED_DATA"]),
                    commands_started,
                    xcode_warnings,
                    stages,
                )
        finally:
            touch_usage(root, "worktrees", manifest["worktreeId"])
            if simulator:
                with timings.phase("simulatorCleanup"):
                    for operation in ("shutdown", "delete"):
                        subprocess.run(
                            ["xcrun", "simctl", operation, simulator],
                            env=environment,
                            capture_output=True,
                            check=False,
                        )
        receipt = {
            key: manifest[key]
            for key in (
                "kind",
                "worktreeId",
                "buildId",
                "sourceCommit",
                "sourceFingerprint",
            )
        }
        if status == 0 and cargo_key is not None and cargo.is_dir():
            (cargo.parent / "cargo-seed-key").write_text(cargo_key + "\n")
        receipt.update(
            {
                "exitCode": status,
                "host": socket.gethostname(),
                "log": str(run / "build.log"),
                "repository": str(repository),
                "developerDirectory": developer,
                "simulatorId": simulator,
                "phasesSeconds": timings.durations,
                "cacheRetired": cache_retired,
                "compilationCache": compilation,
                "packageSeed": package_seed,
                "cargoSeed": cargo_seed,
                "xcodeExitZeroDiagnostics": xcode_warnings,
                "verifiedProducts": verified_products,
            }
        )
        if manifest["kind"] == "ios-install" and status == 0:
            receipt["iosArtifact"] = str(ios_artifact)
            receipt["iosBuild"] = artifact_evidence
            receipt["profilingSymbols"] = mirror_device_symbols(artifact_evidence, manifest, repository / "scripts")
            receipt["deliveryRequested"] = "--build-only" not in manifest["arguments"]
        if stages_path.is_file():
            receipt["stages"] = stages
            for stage in receipt["stages"]:
                if stage.get("stage") == "gatewayChecks":
                    evidence = stage["evidence"]
                    receipt["checks"] = {
                        "reused": stage["reused"],
                        "evidenceBuildId": evidence["buildId"],
                        "inputKey": evidence["inputKey"],
                        "passedAt": evidence["passedAt"],
                    }
        if status == 0 and manifest["kind"] in GATEWAY_ARTIFACT_KINDS:
            receipt.update(
                {
                    "artifact": str(artifact),
                    "artifactSHA256": tree_digest(artifact),
                    "gatewaySHA256": hashlib.sha256(
                        gateway_bundle.executable(artifact).read_bytes()
                    ).hexdigest(),
                }
            )
        if status == 0 and manifest["kind"] == "mac-bench":
            receipt.update(json.loads((run / "bench.json").read_text()))
        receipt["elapsedSeconds"] = round(time.monotonic() - timings.started, 3)
        atomic_json(run / "receipt.json", receipt)
    return receipt


def compiler_paths(kind: str, environment: dict[str, str]) -> list[Path]:
    paths = []
    if kind in IOS_KINDS - {"core-test"}:
        derived = Path(environment["RC_DERIVED_DATA"])
        if kind in {"mac-install", "mac-bench"}:
            derived = derived.with_name(derived.name + "-mac-optimized")
        paths.append(derived)
    if kind in {"core-test", "verify", "verify-all"}:
        paths.append(Path(environment["RC_SWIFT_BUILD_PATH"]))
    if kind in {"gateway", "gateway-release", "gateway-check", "gateway-test", "verify", "verify-all"}:
        paths.append(Path(environment["CARGO_TARGET_DIR"]))
    return [canonical_path(path) for path in paths]


def recipe_environment(repository: Path, environment: dict[str, str]) -> dict[str, str]:
    return environment | {
        "CARGO_TARGET_DIR": os.path.relpath(
            canonical_path(Path(environment["CARGO_TARGET_DIR"])),
            canonical_path(repository),
        )
    }


def admit_compilation(root, policy, current, *, preview=False):
    home = canonical_path(Path.home())
    source = (
        ROOT
        if ROOT.is_relative_to(home) and (ROOT / ".git").exists()
        else home / "RemoteCoder"
    )
    discovery_error = None
    try:
        worktrees = local_worktrees(source)
    except (OSError, subprocess.SubprocessError) as error:
        worktrees = []
        discovery_error = str(error)
    directories = compilation_directories(
        root, worktrees, Path.home() / "Library/Developer/Xcode/DerivedData"
    )
    result = compilation_admission(
        root, policy, directories, set(current), preview=preview
    )
    if discovery_error:
        result["localDiscoveryError"] = discovery_error
    if result.get("warning"):
        print("WARNING: " + result["warning"], file=sys.stderr, flush=True)
    return result


@job_sleep_assertion()
def local_build(kind: str, arguments: list[str]) -> int:
    if kind not in {
        "ios-build",
        "mac-build",
        "mac-harness-build",
        "core-test",
        "gateway-check",
        "gateway-test",
        "gateway",
    }:
        raise ValueError(f"Unsupported local compiler lane: {kind}")
    root = canonical_path(Path.home() / "Library/Caches/RemoteCoder-Build")
    root.mkdir(parents=True, exist_ok=True)
    environment = os.environ | {"RC_COMPILATION_OWNER": "1"}
    if environment.get("RC_BUILD_PROVENANCE"):
        raise ValueError(
            "An existing build owner must call the owned local recipe directly"
        )
    environment.setdefault(
        "RC_DERIVED_DATA",
        str(
            ROOT
            / "build"
            / ("ios-build-derived" if kind == "ios-build" else "mac-build-derived")
        ),
    )
    environment.setdefault("RC_SWIFT_BUILD_PATH", str(ROOT / "build/swift-core"))
    environment.setdefault("CARGO_TARGET_DIR", str(ROOT / "host-daemon-rs/target"))
    paths = compiler_paths(kind, environment)
    allowed = {
        canonical_path(ROOT / path)
        for path in (
            "build/ios-build-derived",
            "build/mac-build-derived",
            "build/swift-core",
            "host-daemon-rs/target",
        )
    }
    if any(path not in allowed for path in paths):
        raise ValueError(
            "Local cache overrides must use the canonical private worktree paths; use the remote worker for isolated overrides"
        )
    build_id = uuid.uuid4().hex
    run = root / "runs" / build_id
    run.mkdir(parents=True)
    environment = build_environment(kind, environment, run)
    started = time.time()
    source = {
        "sourceCommit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip(),
        "sourceModified": bool(
            subprocess.check_output(
                ["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT
            )
        ),
    }
    with (
        file_lease(source_lease_path(ROOT)) as source_fd,
        file_lease(lease_path(root, "runs", build_id)) as run_fd,
        build_capacity() as capacity_fd,
    ):
        compilation = None
        retained = None
        status = 1
        try:
            compilation = admit_compilation(root, load_policy(), paths)
            atomic_json(run / "cache-admission.json", compilation)
            retained = prune_caches(root, load_policy(), "", build_id)
            if retained.get("evictionFailures"):
                print(
                    "WARNING: Run-evidence retention failed partially; admission continues. See cacheRetired in the receipt.",
                    file=sys.stderr,
                    flush=True,
                )
            require_build_space(ROOT)
            record_compilation(root, paths, build_id, True, source)
            status = run_owned(
                build_command(kind, arguments),
                ROOT,
                recipe_environment(ROOT, environment),
                sys.stdout,
                (source_fd, run_fd, capacity_fd),
            )
            record_compilation(root, paths, build_id, False, source)
            return status
        except SystemExit as error:
            status = error.code if type(error.code) is int else 1
            raise
        except BaseException:
            status = 1
            raise
        finally:
            atomic_json(
                run / "receipt.json",
                {
                    "buildId": build_id,
                    "kind": kind,
                    "repository": str(ROOT),
                    "startedAt": started,
                    "finishedAt": time.time(),
                    "exitCode": status,
                    "compilationCache": compilation,
                    "cacheRetired": retained,
                },
            )


def publish_cache_cap(policy, used, reason):
    status = {
        "version": 1,
        "owner": "remotecoder-build",
        "observed_at": datetime.now(UTC).isoformat(),
        "unmet": None if used is None else used > policy.compilation_budget_bytes,
        "used_bytes": used,
        "cap_bytes": policy.compilation_budget_bytes,
        "reason": reason,
    }
    destination = Path.home() / ".local/state/disk-cap-status/remotecoder-build.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    atomic_json(destination, status)
    return status


@job_sleep_assertion()
def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "kind",
        choices=(
            *KINDS,
            "worker",
            "connected-worker",
            "local-install",
            "local-build",
            "cache-preview",
            "cache-maintain",
            "cache-purge-xcode-environments",
        ),
    )
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.kind == "cache-purge-xcode-environments":
        root = Path.home() / "Library/Caches/RemoteCoder-Build"
        print(json.dumps(purge_xcode_environments(root, local_worktrees(ROOT)), indent=2))
        return
    if args.kind == "local-build":
        raise SystemExit(local_build(args.arguments[0], args.arguments[1:]))
    if args.kind in {"cache-preview", "cache-maintain"}:
        if args.kind == "cache-maintain" and args.arguments:
            parser.error("cache-maintain uses the active cache policy; no arguments are accepted")
        root = Path.home() / "Library/Caches/RemoteCoder-Build"
        policy = (
            read_policy(Path(args.arguments[0])) if args.arguments else load_policy()
        )
        preview = args.kind == "cache-preview"
        try:
            root.mkdir(parents=True, exist_ok=True)
            root_error = None
            try:
                root_bytes = cache_allocated_bytes(root)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                root_bytes = None
                root_error = str(error)
            entries = compilation_directories(root, [], Path.home() / "Library/Developer/Xcode/DerivedData")
            if root_bytes is None or root_bytes > policy.compilation_budget_bytes or shutil.disk_usage(root).free < policy.eviction_target_free_bytes:
                entries += shared_compilation_directories(root)
            manifest = compilation_admission(root, policy, entries, set(), preview=preview, root_bytes=root_bytes)
            if root_error:
                manifest["rootAllocationError"] = root_error
            manifest["evidenceRetention"] = prune_caches(root, policy, "", "", preview=preview)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            if not preview:
                publish_cache_cap(policy, None, str(error))
            raise
        if preview:
            print(json.dumps(manifest, indent=2))
        else:
            try:
                remaining = cache_allocated_bytes(root)
                reason = (
                    "Total cap unmet after bounded reclamation; inspect RemoteCoder-Build/maintenance.json for protected data or failures"
                    if remaining > policy.compilation_budget_bytes
                    else "Total cache cap met"
                )
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                remaining = None
                reason = str(error)
            status = publish_cache_cap(policy, remaining, reason)
            manifest["rootRemainingBytes"] = remaining
            manifest["rootInventoryComplete"] = remaining is not None
            manifest["projectedBytes"] = remaining
            manifest["remainingBytes"] = remaining
            manifest["unsatisfiedBudgetBytes"] = (
                None if remaining is None else max(0, remaining - policy.compilation_budget_bytes)
            )
            manifest["capStatus"] = status
            atomic_json(root / "maintenance.json", manifest)
            print(json.dumps({
                "receipt": str(root / "maintenance.json"),
                "allocatedBytes": manifest.get("rootAllocatedBytes"),
                "remainingBytes": remaining,
                "unsatisfiedBudgetBytes": manifest["unsatisfiedBudgetBytes"],
                "evictedPayloads": len(manifest["evicted"]),
                "expiredMirrorPayloads": len(manifest["evidenceRetention"].get("mirrors", [])),
                "inventoryComplete": manifest["inventoryComplete"],
                "capStatus": status,
            }))
            if status["unmet"] is not False:
                raise SystemExit(1)
        return
    if args.kind == "connected-worker":
        raise SystemExit(connected_worker(Path(args.arguments[0])))
    if args.kind == "local-install":
        install_lease = source_lease_path(ROOT)
        directory = install_lease.parent
        directory.mkdir(parents=True, exist_ok=True)
        with install_lease.open("a") as lease, tempfile.TemporaryDirectory(prefix="install-shell-", dir=directory) as shell_directory:
            fcntl.flock(lease, fcntl.LOCK_EX)
            environment = build_environment("ios-install", os.environ, Path(shell_directory))
            environment["RC_INSTALL_SOURCE_LEASED"] = "1"
            if not environment.get("RC_DERIVED_DATA"):
                developer = environment.get(
                    "RC_XCODE_DEVELOPER_DIR"
                ) or environment.get("DEVELOPER_DIR")
                if not developer:
                    developer = (
                        "/Applications/Xcode-"
                        + (ROOT / ".xcode-version").read_text().strip()
                        + ".app/Contents/Developer"
                    )
                version = subprocess.check_output(
                    ["xcodebuild", "-version"],
                    env=environment | {"DEVELOPER_DIR": developer},
                    text=True,
                )
                build = next(
                    (
                        line.removeprefix("Build version ").strip()
                        for line in version.splitlines()
                        if line.startswith("Build version ")
                    ),
                    "",
                )
                if not build:
                    raise ValueError(
                        "Selected Xcode toolchain did not report its build version"
                    )
                environment["RC_DERIVED_DATA"] = str(
                    canonical_path(Path.home() / "Library/Developer/Xcode/DerivedData")
                    / ("RemoteCoder-" + build + "-" + install_lease.stem)
                )
            if not environment.get("RC_BUILD_PROVENANCE"):
                manifest = source_manifest(ROOT, "ios-install", args.arguments)
                run = directory / manifest["buildId"]
                run.mkdir(mode=0o700)
                provenance = run / "source.json"
                provenance.write_text(json.dumps(manifest, indent=2) + "\n")
                environment["RC_BUILD_PROVENANCE"] = str(provenance)
            status = run_owned(
                ["./scripts/install-device", *args.arguments],
                ROOT,
                environment,
                sys.stdout,
                (lease.fileno(),),
            )
        raise SystemExit(status)
    if args.kind == "worker":
        receipt = worker(Path(args.arguments[0]))
        print(json.dumps(receipt))
        raise SystemExit(receipt["exitCode"])
    started = time.monotonic()
    # Host selection is deliberate policy, never a fallback after a failed build.
    build_host = selected_build_host(args.kind, os.environ)
    local = build_hosts.is_local(build_host)
    shell = ["bash", "-c"] if local else [*SSH, build_host]
    destination = "" if local else build_host + ":"
    if args.kind == "mac-bench":
        validate_lab_request(args.arguments, shell)
    manifest = source_manifest(ROOT, args.kind, args.arguments)
    client_phases = {"snapshot": round(time.monotonic() - started, 3)}
    transfer_started = time.monotonic()
    remote_home = json.loads(
        subprocess.check_output(
            [
                *shell,
                "python3 -c 'import json,pathlib; print(json.dumps(str(pathlib.Path.home())))'",
            ],
            text=True,
        )
    )
    remote_run = (
        Path(remote_home)
        / "Library/Caches/RemoteCoder-Build/runs"
        / manifest["buildId"]
    )
    with host_job_assertion(shell, lease_path(remote_run.parent.parent, "runs", remote_run.name)) as power_pid:
        print(f"Build-host sleep owner: {build_host} PID {power_pid}", file=sys.stderr)
        transfer_source(shell, destination, remote_run, manifest)
        client_phases["sourceTransfer"] = round(time.monotonic() - transfer_started, 3)
        print(
            f"Build {manifest['buildId']}: {build_host}:{remote_run}/progress.json",
            file=sys.stderr,
        )
        command = shlex.join(
            [
                "python3",
                str(remote_run / "repo/scripts/remote-build.py"),
                "connected-worker",
                str(remote_run),
            ]
        )
        wait_started = time.monotonic()
        result = run_connected([*shell, command])
        if not result.stdout.strip():
            raise RuntimeError(
                "Build worker returned no receipt; inspect " + str(remote_run)
            )
        client_phases["worker"] = round(time.monotonic() - wait_started, 3)
        receipt = json.loads(result.stdout)
        artifact_started = time.monotonic()
        receiver = owned_rsync_options(destination, remote_run)
        output = ROOT / "build/receipts" / manifest["buildId"]
        output.mkdir(parents=True, exist_ok=True)
        if receipt["exitCode"] == 0 and args.kind in GATEWAY_ARTIFACT_KINDS:
            artifact = (
                ROOT
                / "host-daemon-rs/target/deploy"
                / manifest["buildId"]
                / gateway_bundle.NAME
            )
            artifact.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                [
                    "rsync", "-a", "--delete", *receiver,
                    destination + receipt["artifact"] + "/", str(artifact) + "/",
                ],
                check=True,
            )
            if (
                tree_digest(artifact) != receipt["artifactSHA256"]
                or hashlib.sha256(
                    gateway_bundle.executable(artifact).read_bytes()
                ).hexdigest()
                != receipt["gatewaySHA256"]
            ):
                raise ValueError("Returned gateway artifact fingerprint mismatch")
            subprocess.run(
                ["codesign", "--verify", "--strict", str(artifact)], check=True
            )
            receipt["artifact"] = str(artifact)
        if receipt["exitCode"] == 0 and args.kind == "mac-bench" and receipt.get("artifactLocation") != "lab":
            app = ROOT / "build/mac-bench" / manifest["buildId"] / "RemoteCoder.app"
            app.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                [
                    "rsync",
                    "-a",
                    "--delete",
                    *receiver,
                    destination + receipt["app"] + "/",
                    str(app) + "/",
                ],
                check=True,
            )
            details = subprocess.run(
                ["codesign", "--display", "--verbose=3", str(app)],
                capture_output=True,
                text=True,
                check=True,
            ).stderr
            if "CDHash=" + receipt["cdhash"] not in details.splitlines():
                raise ValueError("Returned bench app CDHash mismatch")
            subprocess.run(
                ["codesign", "--verify", "--deep", "--strict", str(app)], check=True
            )
            receipt["app"] = str(app)
        client_phases["artifactReturn"] = round(time.monotonic() - artifact_started, 3)
        receipt.update(
            {
                "clientPhasesSeconds": client_phases,
                "totalElapsedSeconds": round(time.monotonic() - started, 3),
            }
        )
        atomic_json(output / "receipt.json", receipt)
        print(json.dumps(receipt))
        if receipt["exitCode"] != 0:
            print(
                "Build failed. Inspect the recorded worker log: " + receipt["log"],
                file=sys.stderr,
            )
        raise SystemExit(receipt["exitCode"])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
