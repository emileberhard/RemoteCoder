"""Drive RemoteCoder's perf harness in a dedicated iOS simulator or on a perf device.

Run from the worktree on the Mac that builds it and hosts the simulator or iPad. A device build is the Release
configuration, signed with the release lane's ad hoc profiles, so it measures what ships; a simulator build is
Debug optimized (-O, whole module). Both compile `RC_PERF_HARNESS`, which compiles the
harness in and keeps the build from enrolling push, VoIP, Live Activity or
live-navigation registrations with the shared gateways, however it is launched.
It is installed into a dedicated simulator, or with `--device <name|UDID>` onto
a physical perf device. Commands reach the app through a JSON file in its data
container plus a Darwin notification; results come back as JSON lines.
"""

import argparse
import asyncio
import contextlib
import functools
import gzip
import hashlib
import importlib.util
import json
import math
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DRIVER_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
sys.path.insert(0, str(ROOT / "scripts"))
from build_support import (  # noqa: E402
    MAX_MEASUREMENT_SECONDS,
    atomic_json,
    build_capacity,
    device_lease_path,
    file_lease,
    job_sleep_assertion,
    measurement_capacity,
    measurement_record_lease,
    require_build_space,
    run_owned,
    source_lease_path,
)

BUNDLE = "com.example.RemoteCoder"
PROCESS = "RemoteCoder"
SIM_NAME = "RemoteCoder Perf"
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
NOTIFICATION = "com.remotecoder.perf.command"
PERF_DIR = "Library/Caches/perf"
SWITCHES = {
    "growth", "readingFrames", "geometryProjections", "visibility",
    "scrollTargets", "scrollPosition", "geometryGroup", "latestEdge",
    "contextMenu", "textSelection", "tooltips", "growthGate", "resourceSampler",
}
TRACE_WARMUP = 10
TRACE_COMPLETE = "Time limit reached"
CLOCK_SLACK = 0.5
SIGNING_KEYCHAIN = Path.home() / "configs/skills/apple-devops/scripts/ensure-signing-keychain"
TEAM_ID = ""
DEVICE_BUNDLES = {
    "RC_PROFILE_REMOTECODER_APP": BUNDLE,
    "RC_PROFILE_NOTIFICATION_SERVICE": f"{BUNDLE}.RemoteCoderNotificationService",
    "RC_PROFILE_LIVE_ACTIVITIES": f"{BUNDLE}.RemoteCoderLiveActivities",
    "RC_PROFILE_LOCATION_PUSH_SERVICE": f"{BUNDLE}.RemoteCoderLocationPushService",
    "RC_PROFILE_SHARE_EXTENSION": f"{BUNDLE}.RemoteCoderShareExtension",
    "RC_PROFILE_CAPTURE_EXTENSION": f"{BUNDLE}.RemoteCoderCaptureExtension",
}
TRACE_DIR = Path.home() / "perf-traces/remotecoder"


def developer_dir() -> str:
    version = (ROOT / ".xcode-version").read_text().strip()
    return os.environ.get("DEVELOPER_DIR") or f"/Applications/Xcode-{version}.app/Contents/Developer"


ENV = {**os.environ, "DEVELOPER_DIR": developer_dir()}


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(command, env=ENV, check=True, **kwargs)


def output(command: list[str]) -> str:
    return subprocess.check_output(command, env=ENV, text=True).strip()


def source_lease() -> contextlib.AbstractContextManager[int]:
    return file_lease(source_lease_path(ROOT))


def device_lease(udid: str) -> contextlib.AbstractContextManager[int]:
    return file_lease(device_lease_path(udid))


def simulator() -> str:
    devices = json.loads(output(["xcrun", "simctl", "list", "devices", "-j"]))["devices"]
    for device in devices.get(RUNTIME, []):
        if device["name"] == SIM_NAME and device["isAvailable"]:
            return device["udid"]
    return output(["xcrun", "simctl", "create", SIM_NAME, DEVICE_TYPE, RUNTIME])


class Simulator:
    derived = ROOT / "build/perf-sim-derived"
    app = derived / "Build/Products/Debug-iphonesimulator/RemoteCoder.app"

    def __init__(self, launch_arguments: list[str]) -> None:
        self.udid = simulator()
        self.launch_arguments = launch_arguments

    def build_settings(self) -> list[str]:
        return ["-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={self.udid}",
                "SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule"]

    def prepare(self) -> None:
        subprocess.run(["xcrun", "simctl", "boot", self.udid], env=ENV, capture_output=True)
        run(["xcrun", "simctl", "bootstatus", self.udid, "-b"], stdout=subprocess.DEVNULL)

    def install(self) -> None:
        run(["xcrun", "simctl", "install", self.udid, str(self.app)])

    def uninstall(self) -> None:
        command = ["xcrun", "simctl", "uninstall", self.udid, BUNDLE]
        result = subprocess.run(command, env=ENV, capture_output=True)
        if result.returncode:
            listing = output(["xcrun", "simctl", "listapps", self.udid])
            converted = run(["plutil", "-convert", "json", "-o", "-", "--", "-"], input=listing, text=True, capture_output=True)
            if BUNDLE in json.loads(converted.stdout):
                raise subprocess.CalledProcessError(result.returncode, command, result.stdout, result.stderr)

    def terminate(self) -> None:
        subprocess.run(["xcrun", "simctl", "terminate", self.udid, BUNDLE], env=ENV, capture_output=True)

    def launch(self) -> str:
        return output(["xcrun", "simctl", "launch", self.udid, BUNDLE, *self.launch_arguments])

    def perf_dir(self) -> Path:
        path = Path(output(["xcrun", "simctl", "get_app_container", self.udid, BUNDLE, "data"])) / PERF_DIR
        path.mkdir(parents=True, exist_ok=True)
        return path

    def put(self, name: str, data: bytes) -> None:
        directory = self.perf_dir()
        temporary = directory / f"{name}.tmp"
        temporary.write_bytes(data)
        temporary.replace(directory / name)

    def results(self) -> str:
        path = self.perf_dir() / "results.jsonl"
        return path.read_text() if path.exists() else ""

    def clear_results(self) -> None:
        (self.perf_dir() / "results.jsonl").unlink(missing_ok=True)

    def notify(self) -> None:
        run(["xcrun", "simctl", "spawn", self.udid, "notifyutil", "-p", NOTIFICATION])

    def screenshot(self, path: str) -> None:
        run(["xcrun", "simctl", "io", self.udid, "screenshot", path], stdout=subprocess.DEVNULL)


class Device:
    """A physical perf device reached through CoreDevice; its file transfers
    and notifications cost device work, so result polling backs off during a
    measured window."""

    derived = ROOT / "build/perf-device-derived"
    app = derived / "Build/Products/Release-iphoneos/RemoteCoder.app"

    def __init__(self, name: str, launch_arguments: list[str], signing: str) -> None:
        self.udid = self.resolve(name)
        self.launch_arguments = launch_arguments
        self.signing = signing

    @staticmethod
    def resolve(name: str) -> str:
        with tempfile.NamedTemporaryFile(suffix=".json") as handle:
            run(["xcrun", "devicectl", "list", "devices", "--json-output", handle.name, "--quiet"])
            devices = json.loads(Path(handle.name).read_text())["result"]["devices"]
        for device in devices:
            hardware = device.get("hardwareProperties", {})
            if hardware.get("reality") != "physical":
                continue
            if name in {device.get("identifier"), hardware.get("udid"), device.get("deviceProperties", {}).get("name")}:
                if hardware.get("deviceType") != "iPad":
                    raise SystemExit(f"{name} is not an iPad; harness builds never go on a phone the gateways notify")
                if device.get("connectionProperties", {}).get("tunnelState") in (None, "unavailable"):
                    raise SystemExit(f"{name} is paired but not reachable; connect and unlock it")
                return hardware["udid"]
        raise SystemExit(f"no physical device named {name}")

    def devicectl(self, subcommand: str, action: str, *arguments: str) -> None:
        run(["xcrun", "devicectl", "device", subcommand, action, "--device", self.udid, "--quiet", *arguments],
            stdout=subprocess.DEVNULL)

    def build_settings(self) -> list[str]:
        run([str(SIGNING_KEYCHAIN)])
        keychain = output([str(SIGNING_KEYCHAIN), "--path"])
        suffix = "Development" if self.signing == "development" else "AdHoc"
        return ["-configuration", "Release", "-destination", "generic/platform=iOS",
                f"DEVELOPMENT_TEAM={TEAM_ID}", f"OTHER_CODE_SIGN_FLAGS=--keychain {keychain}",
                *(f"{setting}={bundle} {suffix}" for setting, bundle in DEVICE_BUNDLES.items())]

    def prepare(self) -> None:
        pass

    def install(self) -> None:
        self.devicectl("install", "app", str(self.app))

    def uninstall(self) -> None:
        command = ["xcrun", "devicectl", "device", "uninstall", "app", "--device", self.udid, BUNDLE, "--quiet"]
        result = subprocess.run(command, env=ENV, capture_output=True)
        if result.returncode:
            with tempfile.NamedTemporaryFile(suffix=".json") as handle:
                self.devicectl("info", "apps", "--include-all-apps", "--json-output", handle.name)
                apps = json.loads(Path(handle.name).read_text())["result"]["apps"]
            if any(app["bundleIdentifier"] == BUNDLE for app in apps):
                raise subprocess.CalledProcessError(result.returncode, command, result.stdout, result.stderr)

    def terminate(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".json") as handle:
            self.devicectl("info", "processes", "--json-output", handle.name)
            processes = json.loads(Path(handle.name).read_text())["result"]["runningProcesses"]
        for process in processes:
            if "/RemoteCoder.app/" in process.get("executable", ""):
                self.devicectl("process", "terminate", "--pid", str(process["processIdentifier"]))

    def launch(self) -> str:
        self.devicectl("process", "launch", "--terminate-existing", BUNDLE, "--", *self.launch_arguments)
        return "launched"

    def copy_to(self, source: Path, destination: str) -> None:
        self.devicectl("copy", "to", "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                       "--source", str(source), "--destination", destination)

    def put(self, name: str, data: bytes) -> None:
        TRACE_DIR.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=TRACE_DIR, prefix="replay-transfer-") as directory:
            source = Path(directory) / name
            source.write_bytes(data)
            source.chmod(0o600)
            self.copy_to(source, f"{PERF_DIR}/{name}")

    def results(self) -> str:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "results.jsonl"
            status = subprocess.run(
                ["xcrun", "devicectl", "device", "copy", "from", "--device", self.udid, "--domain-type",
                 "appDataContainer", "--domain-identifier", BUNDLE, "--source", f"{PERF_DIR}/results.jsonl",
                 "--destination", str(destination), "--quiet"], env=ENV, capture_output=True).returncode
            return destination.read_text() if status == 0 and destination.exists() else ""

    def clear_results(self) -> None:
        self.put("results.jsonl", b"")

    def notify(self) -> None:
        self.devicectl("notification", "post", "--name", NOTIFICATION)

    def screenshot(self, path: str) -> None:
        self.devicectl("capture", "screenshot", "--destination", path)


def target(args) -> Simulator | Device:
    if unknown := set(filter(None, (args.disable or "").split(","))) - SWITCHES:
        raise SystemExit(f"unknown --disable switch {sorted(unknown)}; known: {sorted(SWITCHES)}")
    launch_arguments = ["-rcPerfDisable", args.disable] if args.disable else []
    if getattr(args, "command", None) == "scenario":
        launch_arguments += ["-rcPerfOffline"]
    return Device(args.device, launch_arguments, getattr(args, "signing", "distribution")) if args.device else Simulator(launch_arguments)


def build_commands(device: Simulator | Device) -> list[list[str]]:
    return [
        ["tuist", "generate", "--no-open"],
        [
            "xcodebuild", "-jobs", os.environ.get("EMIL_BUILD_JOBS", "6"),
            "-workspace", "RemoteCoder.xcworkspace", "-scheme", "RemoteCoder",
            *device.build_settings(),
            "-derivedDataPath", str(device.derived), "-onlyUsePackageVersionsFromResolvedFile",
            "-skipPackagePluginValidation", "-skipMacroValidation",
            "COMPILER_INDEX_STORE_ENABLE=NO", "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) RC_PERF_HARNESS",
            "build",
        ],
    ]


def build(args) -> None:
    device = target(args)
    env = {**ENV, "TUIST_REMOTE_CODER_BUNDLE_LOCAL_CONFIG": "1",
           "TUIST_REMOTE_CODER_PERF_SIGNING": getattr(device, "signing", "distribution")}
    commands = build_commands(device)
    log = ROOT / f"build/{device.derived.name}-build.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    status = 0
    with source_lease() as lease, build_capacity(background=True) as capacity:
        identity = build_source_identity()
        try:
            require_build_space(ROOT)
        except ValueError as error:
            raise SystemExit(str(error)) from error
        with log.open("w") as handle:
            for command in commands:
                status = run_owned(command, ROOT, env, handle, (lease, capacity))
                if status != 0:
                    break
        if status == 0:
            write_build_identity(device, identity)
    lines = log.read_text(errors="replace").splitlines()
    for line in [line for line in lines if "error:" in line][:40] or lines[-5:]:
        print(line)
    if status != 0:
        sys.exit(status)
    print(f"app={device.app}")


def build_source_identity() -> dict:
    spec = importlib.util.spec_from_file_location("perf_remote_build", ROOT / "scripts/remote-build.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    manifest = module.source_manifest(ROOT, "ios-install", [])
    return {key: manifest[key] for key in ["sourceCommit", "sourceFingerprint", "sourceModified"]}


def write_build_identity(device: Simulator | Device, identity: dict) -> None:
    if build_source_identity() != identity:
        raise SystemExit("source changed during the performance build; rebuild from settled inputs")
    identity = {**identity, "appExecutableSHA256": hashlib.sha256((device.app / PROCESS).read_bytes()).hexdigest(),
                "toolchain": output(["xcodebuild", "-version"]),
                "signing": device.signing if isinstance(device, Device) else "simulator",
                "configuration": "Release" if isinstance(device, Device) else "Debug optimized"}
    if isinstance(device, Device):
        entitlements = run(["codesign", "--display", "--entitlements", "-", "--xml", str(device.app)], capture_output=True).stdout
        identity["debuggerAllowed"] = plistlib.loads(entitlements).get("get-task-allow", False)
        if identity["debuggerAllowed"] != (device.signing == "development"):
            raise SystemExit("built app entitlements do not match the requested profiling signing mode")
    (device.derived / "perf-build-identity.json").write_text(json.dumps(identity, sort_keys=True))


def leased(command):
    @functools.wraps(command)
    def run_leased(args, *arguments) -> None:
        device = target(args)
        with device_lease(device.udid):
            command(args, device, *arguments)

    return run_leased


@leased
def install(args, device: Simulator | Device) -> None:
    device.prepare()
    device.install()
    print(f"installed udid={device.udid}")


@leased
def launch(args, device: Simulator | Device) -> None:
    device.prepare()
    device.terminate()
    print(device.launch())
    if args.clear_results:
        device.clear_results()


def send(device: Simulator | Device, command: dict, timeout: float, quiet_seconds: float = 0) -> dict | None:
    """Deliver one command and wait for its result line. `quiet_seconds` skips
    polling while a measured window is known to be running."""
    command.setdefault("id", uuid.uuid4().hex[:12])
    device.put("command.json", json.dumps(command).encode())
    device.notify()
    deadline = time.monotonic() + timeout
    time.sleep(min(quiet_seconds, timeout))
    interval = 0.2 if isinstance(device, Simulator) else 1.5
    while time.monotonic() < deadline:
        for line in device.results().splitlines():
            if line.strip():
                entry = json.loads(line)
                if entry.get("id") == command["id"]:
                    return entry
        time.sleep(interval)
    return None


@leased
def cmd(args, device: Simulator | Device) -> None:
    result = send(device, json.loads(args.json), args.timeout)
    print(json.dumps(result, indent=2) if result else "no result before timeout")
    if result is None:
        sys.exit(3)
    if "error" in result:
        sys.exit(1)


def swipe(args) -> None:
    udid = simulator()
    x = args.x
    top, bottom = args.top, args.bottom
    start, end = (bottom, top) if args.direction == "up" else (top, bottom)
    for _ in range(args.count):
        run(["axe", "swipe", "--start-x", str(x), "--start-y", str(start), "--end-x", str(x),
             "--end-y", str(end), "--duration", str(args.duration), "--udid", udid], stdout=subprocess.DEVNULL)
        time.sleep(args.pause)


def tap(args) -> None:
    run(["axe", "tap", "-x", str(args.x), "-y", str(args.y), "--udid", simulator()], stdout=subprocess.DEVNULL)


@leased
def screenshot(args, device: Simulator | Device) -> None:
    device.screenshot(args.path)
    print(args.path)


def instrumentation(device: Simulator | Device, template: str | None, instruments: list[str] | None) -> dict:
    instruments = instruments or []
    app_only = not isinstance(device, Device) or template == "Allocations"
    return {"template": template, "instruments": instruments,
            "scope": ("app" if app_only else "allProcesses") if template else None}


@contextlib.contextmanager
def tracing(device: Simulator | Device, template: str, instruments: list[str] | None, seconds: int, path: str):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    scope = ["--attach", PROCESS] if instrumentation(device, template, instruments)["scope"] == "app" else ["--all-processes"]
    command = ["xcrun", "xctrace", "record", "--template", template, "--device", device.udid, *scope,
               "--time-limit", f"{seconds}s", "--output", path, "--no-prompt"]
    for instrument in instruments or []:
        command += ["--instrument", instrument]
    recorder = subprocess.Popen(command, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        yield recorder
    finally:
        if recorder.poll() is None:
            recorder.terminate()
        if not recorder.stdout.closed:
            log = recorder.communicate()[0]
            with private_open(Path(path).with_suffix(".recording.log"), "w") as handle:
                handle.write(log)


def finish_trace(recorder: subprocess.Popen, path: str, window: dict | None = None) -> None:
    log = recorder.communicate()[0].strip()
    with private_open(Path(path).with_suffix(".recording.log"), "w") as handle:
        handle.write(log)
    if recorder.returncode != 0:
        raise SystemExit(f"xctrace failed ({recorder.returncode}): {log[-500:]}")
    toc = subprocess.run(["xcrun", "xctrace", "export", "--input", path, "--toc"], env=ENV, check=True,
                         capture_output=True).stdout
    with private_open(Path(path).with_suffix(".toc.xml"), "wb") as handle:
        handle.write(toc)
    summary = ET.fromstring(toc).find("run/info/summary")
    if summary is None:
        raise SystemExit(f"{path} has no recorded run; xctrace said: {log[-500:]}")
    start = datetime.fromisoformat(summary.findtext("start-date")).timestamp()
    end = datetime.fromisoformat(summary.findtext("end-date")).timestamp()
    reason = summary.findtext("end-reason")
    if reason != TRACE_COMPLETE:
        raise SystemExit(f"{path} stopped after {end - start:.1f} s: {reason}. Keep the device connected, "
                         "unlocked and awake, then rerun")
    if window and window["startedAt"] < start - CLOCK_SLACK:
        raise SystemExit(f"{path} began {start - window['startedAt']:.1f} s after the window did: xctrace took "
                         f"longer than the {TRACE_WARMUP} s warmup to start; rerun")
    if window and window["endedAt"] > end + CLOCK_SLACK:
        raise SystemExit(f"{path} ended {window['endedAt'] - end:.1f} s before the window did; raise "
                         "--trace-seconds")


@leased
def trace(args, device: Simulator | Device) -> None:
    with tracing(device, args.template, args.instrument, args.seconds, args.out) as recorder:
        time.sleep(args.warmup)
        if args.scenario:
            subprocess.run(args.scenario, shell=True, env=ENV, check=False)
        finish_trace(recorder, args.out)
    print(f"trace={args.out}")


def fresh_launch(device: Simulator | Device) -> dict:
    device.terminate()
    device.uninstall()
    device.install()
    device.launch()
    deadline = time.monotonic() + 30
    while True:
        ready = send(device, {"cmd": "status"}, 1)
        if ready is not None:
            return ready["status"]
        if time.monotonic() > deadline:
            raise SystemExit("the harness did not start")


def fresh_open(device: Simulator | Device, host: str, thread: str, settle: float) -> None:
    fresh_launch(device)
    opened = send(device, {"cmd": "open", "host": host, "thread": thread}, 35)
    if opened is None or "error" in opened:
        raise SystemExit(f"open failed: {opened['error'] if opened else 'timed out'}")
    time.sleep(settle)


def measured(device: Simulator | Device, command: dict, timeout: float, quiet_seconds: float) -> dict:
    result = send(device, command, timeout, quiet_seconds=quiet_seconds)
    if result is None or "error" in result:
        raise SystemExit(f"{command['cmd']} failed: {result['error'] if result else 'timed out'}")
    if not result["activeThroughout"] or result["conservedEnergy"] or not result["frames"]:
        raise SystemExit("invalid window: the app left the active state, conserved energy or drew no frames "
                         f"(activeThroughout={result['activeThroughout']}, "
                         f"conservedEnergy={result['conservedEnergy']}, frames={result['frames']})")
    return result


def report(result: dict, device: Simulator | Device, load: float, log: str | None) -> None:
    result["hostLoad1m"] = round(load, 1)
    result["target"] = "device" if isinstance(device, Device) else "simulator"
    line = json.dumps(result, sort_keys=True)
    print(line, flush=True)
    if log:
        with private_open(Path(log), "a") as handle:
            handle.write(line + "\n")


def private_open(path: Path, mode: str):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | (os.O_APPEND if mode == "a" else os.O_TRUNC), 0o600)
    os.fchmod(descriptor, 0o600)
    return os.fdopen(descriptor, mode)


def scenario_outputs(args) -> None:
    from .perf_replay import private_destination
    args.log = str(private_destination(args.log))
    args.trace_dir = str(private_destination(args.trace_dir))
    if not args.label or Path(args.label).name != args.label or args.label in (".", ".."):
        raise ValueError("scenario label must be one filename component")
    for directory in (Path(args.log).parent, Path(args.trace_dir)):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        directory.chmod(0o700)


@contextlib.contextmanager
def scenario_signals():
    def interrupt(signum, _frame):
        raise SystemExit(128 + signum)
    previous = {signum: signal.signal(signum, interrupt) for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)}
    try:
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


@contextlib.contextmanager
def scenario_window(seconds: float):
    if not math.isfinite(seconds) or not 0 < seconds <= MAX_MEASUREMENT_SECONDS:
        raise ValueError(f"measurement duration must fit within {MAX_MEASUREMENT_SECONDS} seconds")
    with measurement_capacity(ROOT, 1800, threading.Event()) as capacity:
        with measurement_record_lease(capacity.record):
            holder = json.loads(capacity.record.read_text())
            if time.monotonic() >= holder["deadline"]:
                raise TimeoutError("measurement queue deadline expired before activation")
            holder["deadline"] = time.monotonic() + seconds + 30
            atomic_json(capacity.record, holder)
        def expired(_signum, _frame):
            raise TimeoutError("scenario measurement deadline expired")
        previous = signal.signal(signal.SIGALRM, expired)
        previous_timer = signal.setitimer(signal.ITIMER_REAL, seconds)
        try:
            yield holder["deadline"] - 30
        finally:
            signal.setitimer(signal.ITIMER_REAL, *previous_timer)
            signal.signal(signal.SIGALRM, previous)


def scenario(args) -> None:
    scenario_outputs(args)
    with scenario_signals():
        for index in range(args.runs):
            with scenario_window(MAX_MEASUREMENT_SECONDS) as deadline:
                run_scenario(args, index, deadline)


def stage_scenario(device: Simulator | Device, source: Path, fixture: dict) -> None:
    root = source.parent.resolve()
    indexes = [conversation[key] for conversation in fixture.get("conversations", [])
               for key in ("itemFile", "turnFile") if conversation.get(key)]
    total = source.stat().st_size
    TRACE_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=TRACE_DIR, prefix="replay-transfer-") as temporary:
        directory = Path(temporary) / "history"
        directory.mkdir(mode=0o700)
        for index in indexes:
            path = (root / index["path"]).resolve()
            if not path.is_relative_to(root) or Path(index["path"]).parts[0] != "history":
                raise SystemExit("history file escapes fixture directory")
            data = path.read_bytes()
            total += len(data)
            if total > 512 * 1_048_576 or len(data) != index["offsets"][-1] \
                    or hashlib.sha256(data).hexdigest() != index["sha256"]:
                raise SystemExit("history size or digest does not match fixture")
            destination = directory / path.name
            destination.write_bytes(data)
            destination.chmod(0o600)
        if indexes:
            if isinstance(device, Device):
                device.copy_to(directory, f"{PERF_DIR}/history")
            else:
                shutil.copytree(directory, device.perf_dir() / "history", dirs_exist_ok=True)
        device.put("scenario.json", source.read_bytes())


def collect_telemetry(device: Simulator | Device, result: dict, log: str) -> None:
    from .perf_replay import private_destination
    destination = private_destination(Path(log).with_suffix(".telemetry") / result["label"])
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    destination.chmod(0o700)
    exports = []
    runs = {}
    for name in result.get("telemetryFiles", []):
        if Path(name).name != name or not name.endswith(".jsonl.gz"):
            raise SystemExit("invalid telemetry capture filename")
        path = destination / name
        if isinstance(device, Device):
            device.devicectl("copy", "from", "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                            "--source", f"{PERF_DIR}/telemetry/{name}", "--destination", str(path))
        else:
            shutil.copyfile(device.perf_dir() / "telemetry" / name, path)
        path.chmod(0o600)
        with gzip.open(path, "rb") as handle:
            data = handle.read(4 * 1_048_576 + 1)
        if len(data) > 4 * 1_048_576:
            raise SystemExit("telemetry capture exceeds decoded segment bound")
        for line in data.splitlines():
            record = json.loads(line)
            if record.get("recordType") == "export":
                exports.append(record)
            elif record.get("recordType") == "run":
                runs[record["runID"]] = record
    unique = {(entry["runID"], entry["seq"]): entry for entry in exports}
    result["capturedExports"] = list(unique.values())
    result["capturedTelemetryRuns"] = list(runs.values())
    result["exportsInWindow"] = export_window(list(unique.values()), bool(runs), result)
    ages = [result["startedAt"] - datetime.fromisoformat(run["startedAt"]).timestamp()
            for run in runs.values() if run.get("startedAt")]
    result["processAgeAtWindowStartSeconds"] = ages[0] if len(ages) == 1 and ages[0] >= 0 else None
    result["telemetryDirectory"] = str(destination)


def retain_returned_telemetry(device: Simulator | Device, result: dict, log: str) -> None:
    def expired(_signum, _frame):
        raise TimeoutError("telemetry collection exceeded 30 seconds")
    previous = signal.signal(signal.SIGALRM, expired)
    previous_timer = signal.setitimer(signal.ITIMER_REAL, 30)
    try:
        collect_telemetry(device, result, log)
    except (Exception, SystemExit) as error:
        result.setdefault("telemetryCollectionFailures", []).append(str(error))
    finally:
        signal.setitimer(signal.ITIMER_REAL, *previous_timer)
        signal.signal(signal.SIGALRM, previous)


def export_window(exports: list[dict], evidence: bool, result: dict) -> dict:
    contained, crossing, unknown = [], [], []
    for entry in exports:
        duration = entry.get("totalMs")
        if not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration < 0:
            unknown.append(entry)
            continue
        ended = datetime.fromisoformat(entry["ts"]).timestamp()
        started = ended - duration / 1000
        if started >= result["startedAt"] and ended <= result["endedAt"]:
            contained.append(entry)
        elif started < result["endedAt"] and ended > result["startedAt"]:
            crossing.append(entry)
    measured_cpu = [entry["processCpuNs"] for entry in contained
                    if isinstance(entry.get("processCpuNs"), (int, float)) and math.isfinite(entry["processCpuNs"]) and entry["processCpuNs"] >= 0]
    cpu_ns = sum(measured_cpu) if evidence and len(measured_cpu) == len(contained) else None
    return {"count": len(contained) if evidence else None, "telemetryEvidence": evidence,
        "coverage": "lowerBound" if evidence else "unavailable",
        "cpuScope": "fullyContainedExportOperations",
        "coverageReason": "completed captured exports only; final pending export interval is unavailable",
        "cpuMeasuredCount": len(measured_cpu), "cpuUnmeasuredCount": len(contained) - len(measured_cpu),
        "boundaryCrossingCount": len(crossing) if evidence else None, "boundaryCrossingOverlapCPUms": None,
        "unknownIntervalCount": len(unknown) if evidence else None,
        "outsideWindowCount": len(exports) - len(contained) - len(crossing) - len(unknown) if evidence else None,
        "wholeProcessCPUms": cpu_ns / 1e6 if cpu_ns is not None else None,
        "wholeProcessCPUSharePercent": cpu_ns / (result["processCPUms"] * 1e6) * 100 if cpu_ns is not None and result.get("processCPUms") else None,
        "scanMs": sum(entry["scanMs"] for entry in contained) if contained and all("scanMs" in entry for entry in contained) else None,
        "scannedRecords": sum(entry["scanned"] for entry in contained) if contained and all("scanned" in entry for entry in contained) else None}


def calibrate(args) -> None:
    with source_lease():
        run_calibration(args)


@leased
def run_calibration(args, device: Simulator | Device) -> None:
    from . import perf_calibration
    if not isinstance(device, Device):
        raise SystemExit("live calibration requires the explicit test iPad")
    identity = json.loads((device.derived / "perf-build-identity.json").read_text())
    if hashlib.sha256((device.app / PROCESS).read_bytes()).hexdigest() != identity["appExecutableSHA256"]:
        raise SystemExit("app artifact changed; rebuild before calibration")
    asyncio.run(perf_calibration.run(args, device, sys.modules[__name__]))


def verify_scenario_artifact(device, identity: dict) -> None:
    if hashlib.sha256((device.app / PROCESS).read_bytes()).hexdigest() != identity["appExecutableSHA256"]:
        raise SystemExit("app artifact changed while preparing or queuing the measurement")


def wait_for_signposts(device: Simulator | Device, recorder: subprocess.Popen, trace_path: str) -> None:
    deadline = time.monotonic() + TRACE_WARMUP
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SystemExit("Instruments did not enable replay signposts before measurement")
        if recorder.poll() is not None:
            finish_trace(recorder, trace_path)
            raise SystemExit("Instruments stopped before replay signposts became ready")
        ready = send(device, {"cmd": "signposting-status"}, min(1, remaining))
        if ready and ready.get("enabled") is True:
            return
        time.sleep(0.2)


@leased
def run_scenario(args, device: Simulator | Device, index: int, deadline: float) -> None:
    scenario_outputs(args)
    identity = json.loads((device.derived / "perf-build-identity.json").read_text())
    if hashlib.sha256((device.app / PROCESS).read_bytes()).hexdigest() != identity["appExecutableSHA256"]:
        raise SystemExit("the app artifact no longer matches its performance build identity; rebuild")
    data = Path(args.fixture).expanduser().read_bytes()
    fixture = json.loads(data)
    duration = fixture["duration"]
    if not isinstance(duration, (int, float)) or not math.isfinite(duration) or not 10 <= duration <= 900:
        raise SystemExit("scenario duration must be 10–900 seconds")
    if args.trace_template and args.trace_seconds < duration + TRACE_WARMUP + 3:
        raise SystemExit("--trace-seconds must cover warmup, scenario and three seconds of tail")
    hold_seconds = max(duration + 90, args.trace_seconds + 30 if args.trace_template else 0)
    if hold_seconds > MAX_MEASUREMENT_SECONDS:
        raise ValueError("trace and scenario must fit within the measurement duration limit")
    device.prepare()
    result = {"valid": False}
    try:
        verify_scenario_artifact(device, identity)
        fresh_launch(device)
        stage_scenario(device, Path(args.fixture).expanduser(), fixture)
        preparation_started = time.monotonic()
        preparation_timeout = deadline - time.monotonic() - hold_seconds - 30
        if preparation_timeout <= 0:
            raise TimeoutError("repeat has no preparation budget remaining")
        loaded = send(device, {"cmd": "scenario-load"}, preparation_timeout)
        if loaded is None or "error" in loaded:
            raise SystemExit(f"scenario-load failed: {loaded}")
        print(f"preparation complete run={index + 1} seconds={time.monotonic() - preparation_started:.1f}", file=sys.stderr, flush=True)
        time.sleep(args.settle)
        load = os.getloadavg()[0]
        trace_path = f"{args.trace_dir}/{args.label}-{index + 1}.trace" if args.trace_template else None
        verify_scenario_artifact(device, identity)
        print(f"measuring run={index + 1} seconds={duration}", file=sys.stderr, flush=True)
        with (tracing(device, args.trace_template, args.instrument, args.trace_seconds, trace_path)
              if trace_path else contextlib.nullcontext()) as recorder:
            if recorder:
                if "Points of Interest" in (args.instrument or []):
                    wait_for_signposts(device, recorder, trace_path)
                else:
                    time.sleep(TRACE_WARMUP)
                    if recorder.poll() is not None:
                        finish_trace(recorder, trace_path)
            result = send(device, {"cmd": "scenario-run"}, duration + 90, quiet_seconds=duration + 1)
            result = result if result is not None else {"error": "scenario-run timed out"}
            result.update(identity)
            result.update(deviceUDID=device.udid, driverSHA256=DRIVER_SHA256,
                          instrumentation=instrumentation(device, args.trace_template, args.instrument),
                          target="device" if isinstance(device, Device) else "simulator",
                          label=f"{args.label}-{index + 1}", hostLoad1m=round(load, 1))
            if trace_path:
                result["trace"] = trace_path
            if result.get("error") or not result.get("valid") or not result.get("activeThroughout") \
                    or result.get("conservedEnergy") or not result.get("frames"):
                failures = [key for key in ["error", "serverFailures", "unsupportedRPCs", "uncapturedHTTP", "cleanupFailures"] if result.get(key)]
                failures += ["finalContent"] if any(not item.get("matches") for item in result.get("finalContent", [])) else []
                failures += [key for key in ["activeThroughout", "frames"] if not result.get(key)]
                failures += ["conservedEnergy"] if result.get("conservedEnergy") else []
                raise SystemExit("invalid scenario window: " + ", ".join(failures or ["app validity check"]))
            if result.get("fixtureSHA256") != hashlib.sha256(data).hexdigest():
                raise SystemExit("the app loaded a different fixture")
            if len(result["actions"]) != len(fixture["actions"]) or result["appliedFrames"] != len(fixture["events"]):
                raise SystemExit("scenario omitted actions or input frames")
            if result.get("telemetryCaptureFailures"):
                raise SystemExit("telemetry capture failed")
            if recorder:
                finish_trace(recorder, trace_path, result)
    except BaseException as error:
        result["valid"] = False
        result["validationError"] = str(error)
        raise
    finally:
        handlers = {signum: signal.signal(signum, signal.SIG_IGN)
                    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGALRM)}
        try:
            if result.get("telemetryFiles") or result.get("valid") is True:
                retain_returned_telemetry(device, result, args.log)
            cleanup = result.setdefault("cleanupFailures", [])
            for operation in [device.terminate, device.uninstall]:
                try:
                    operation()
                except Exception as error:
                    cleanup.append(f"{operation.__name__}: {error}")
            result["valid"] = result.get("valid") is True and not cleanup and not result.get("telemetryCollectionFailures")
            if not result["valid"]:
                result.update(identity)
                result.update(deviceUDID=device.udid, driverSHA256=DRIVER_SHA256)
                failed = Path(args.log).with_suffix(f".failed-{index + 1}.json")
                with private_open(failed, "w") as handle:
                    handle.write(json.dumps(result, sort_keys=True))
                print(f"full diagnostic report: {failed}", file=sys.stderr)
        finally:
            for signum, handler in handlers.items():
                signal.signal(signum, handler)
    if not result["valid"]:
        raise SystemExit("scenario cleanup or telemetry collection failed")
    report(result, device, load, args.log)
    print(f"completed run={index + 1} seconds={result.get('seconds')}", file=sys.stderr, flush=True)


def recording_seconds(recording: Path) -> float:
    last = 0.0
    with recording.open() as handle:
        for line in handle:
            if line.strip():
                last = max(last, json.loads(line)["t"])
    return last


@leased
def stream(args, device: Simulator | Device) -> None:
    device.prepare()
    recording = Path(args.recording).expanduser()
    duration = recording_seconds(recording) / args.speed
    for index in range(args.runs):
        fresh_open(device, args.host, args.thread, args.settle)
        device.put(recording.name, recording.read_bytes())
        loaded = send(device, {"cmd": "load", "file": recording.name}, 60)
        if loaded is None or "error" in loaded:
            raise SystemExit(f"load failed: {loaded['error'] if loaded else 'timed out'}")
        load = os.getloadavg()[0]
        trace_path = f"{args.trace_dir}/{args.label}-{index + 1}.trace" if args.trace_template else None
        with (tracing(device, args.trace_template, args.instrument, args.trace_seconds, trace_path)
              if trace_path else contextlib.nullcontext()) as recorder:
            if recorder:
                time.sleep(TRACE_WARMUP)
            result = measured(device, {"cmd": "replay", "speed": args.speed, "label": f"{args.label}-{index + 1}"},
                              600, quiet_seconds=duration)
            if recorder:
                finish_trace(recorder, trace_path, result)
                result["trace"] = trace_path
        report(result, device, load, args.log)


@leased
def open_bench(args, device: Simulator | Device) -> None:
    device.prepare()
    for index in range(args.runs):
        fresh_launch(device)
        time.sleep(args.settle)
        load = os.getloadavg()[0]
        trace_path = f"{args.trace_dir}/{args.label}-{index + 1}.trace" if args.trace_template else None
        with (tracing(device, args.trace_template, args.instrument, args.trace_seconds, trace_path)
              if trace_path else contextlib.nullcontext()) as recorder:
            if recorder:
                time.sleep(TRACE_WARMUP)
            result = measured(device, {"cmd": "measure-open", "host": args.host, "thread": args.thread,
                                       "tail": args.tail, "label": f"{args.label}-{index + 1}"},
                              60, quiet_seconds=args.tail)
            if recorder:
                finish_trace(recorder, trace_path, result)
                result["trace"] = trace_path
        report(result, device, load, args.log)


def positive(kind: type[int] | type[float]):
    def parse(text: str):
        value = kind(text)
        if not math.isfinite(value) or value <= 0:
            raise argparse.ArgumentTypeError("must be greater than zero")
        return value

    return parse


def configure_identity() -> None:
    global BUNDLE, TEAM_ID, DEVICE_BUNDLES
    from maintainer_config import load

    settings = load().get("xcodeSettings", {})
    BUNDLE = settings.get("RC_BUNDLE_ID", "com.example.RemoteCoder")
    TEAM_ID = settings.get("DEVELOPMENT_TEAM", "")
    DEVICE_BUNDLES = {
        setting: BUNDLE + ("" if setting == "RC_PROFILE_REMOTECODER_APP" else f".{bundle.rsplit('.', 1)[-1]}")
        for setting, bundle in DEVICE_BUNDLES.items()
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="physical perf device name or UDID instead of the perf simulator")
    parser.add_argument("--disable", help="comma-separated costs the harness build switches off for an A/B run, e.g. growth")
    commands = parser.add_subparsers(dest="command", required=True)
    from .config import add_connection_arguments
    from .perf_replay import capture_command, compare
    capture_parser = commands.add_parser("capture", help="capture real history into a private offline scenario; never starts a turn")
    add_connection_arguments(capture_parser)
    capture_parser.add_argument("--thread", action="append", required=True)
    capture_parser.add_argument("--out", required=True)
    capture_parser.add_argument("--sidebar-limit", type=positive(int), default=1024)
    capture_parser.add_argument("--history-count", type=positive(int), default=700)
    capture_parser.add_argument("--recording")
    capture_parser.add_argument("--duration", type=positive(float), default=300)
    capture_parser.set_defaults(func=capture_command)
    compare_parser = commands.add_parser("compare", help="compare repeated reports with matching fixture/device/instrumentation")
    compare_parser.add_argument("--before", required=True)
    compare_parser.add_argument("--after", required=True)
    compare_parser.set_defaults(func=compare)
    calibration_parser = commands.add_parser("calibrate", help="run cheap real agents in read-only probe forks and measure the replay journey")
    add_connection_arguments(calibration_parser)
    calibration_parser.add_argument("--fixture", required=True)
    calibration_parser.add_argument("--thread", action="append", required=True)
    calibration_parser.add_argument("--model", required=True)
    calibration_parser.add_argument("--cwd", required=True)
    calibration_parser.add_argument("--app-host-name", required=True)
    calibration_parser.add_argument("--prompt-file", required=True)
    calibration_parser.add_argument("--out", required=True)
    calibration_parser.set_defaults(func=calibrate)
    build_parser = commands.add_parser("build")
    build_parser.add_argument("--signing", choices=["distribution", "development"], default="distribution",
                              help="development keeps Release optimization and permits allocation profiling")
    build_parser.set_defaults(func=build)
    commands.add_parser("install").set_defaults(func=install)
    launch_parser = commands.add_parser("launch")
    launch_parser.add_argument("--clear-results", action="store_true")
    launch_parser.set_defaults(func=launch)
    cmd_parser = commands.add_parser("cmd")
    cmd_parser.add_argument("json")
    cmd_parser.add_argument("--timeout", type=positive(float), default=120)
    cmd_parser.set_defaults(func=cmd)
    swipe_parser = commands.add_parser("swipe")
    swipe_parser.add_argument("direction", choices=("up", "down"))
    swipe_parser.add_argument("--count", type=int, default=1)
    swipe_parser.add_argument("--duration", type=float, default=0.25)
    swipe_parser.add_argument("--pause", type=float, default=0.6)
    swipe_parser.add_argument("--x", type=int, default=200)
    swipe_parser.add_argument("--top", type=int, default=250)
    swipe_parser.add_argument("--bottom", type=int, default=650)
    swipe_parser.set_defaults(func=swipe)
    tap_parser = commands.add_parser("tap")
    tap_parser.add_argument("x", type=int)
    tap_parser.add_argument("y", type=int)
    tap_parser.set_defaults(func=tap)
    shot = commands.add_parser("screenshot")
    shot.add_argument("path")
    shot.set_defaults(func=screenshot)
    trace_parser = commands.add_parser("trace")
    trace_parser.add_argument("--template", default="Time Profiler")
    trace_parser.add_argument("--instrument", action="append")
    trace_parser.add_argument("--seconds", type=positive(int), default=20)
    trace_parser.add_argument("--warmup", type=float, default=3)
    trace_parser.add_argument("--out", required=True)
    trace_parser.add_argument("--scenario", help="shell command run while recording")
    trace_parser.set_defaults(func=trace)
    stream_parser = commands.add_parser("stream", help="fresh install, open a thread, replay a recording; repeat")
    stream_parser.add_argument("--recording", required=True)
    stream_parser.add_argument("--host", required=True)
    stream_parser.add_argument("--thread", required=True)
    stream_parser.add_argument("--label", required=True)
    stream_parser.add_argument("--runs", type=positive(int), default=3)
    stream_parser.add_argument("--speed", type=positive(float), default=1)
    stream_parser.add_argument("--settle", type=float, default=3)
    stream_parser.add_argument("--log")
    stream_parser.add_argument("--trace-template")
    stream_parser.add_argument("--instrument", action="append")
    stream_parser.add_argument("--trace-seconds", type=positive(int), default=95)
    stream_parser.add_argument("--trace-dir", default=str(TRACE_DIR))
    stream_parser.set_defaults(func=stream)
    open_parser = commands.add_parser(
        "open-bench", help="fresh install, then open a thread inside a window that ends --tail s after it loads; repeat")
    open_parser.add_argument("--host", required=True)
    open_parser.add_argument("--thread", required=True)
    open_parser.add_argument("--label", required=True)
    open_parser.add_argument("--runs", type=positive(int), default=3)
    open_parser.add_argument("--settle", type=float, default=5, help="seconds the launch settles before the window")
    open_parser.add_argument("--tail", type=positive(float), default=2, help="seconds measured after the transcript loads")
    open_parser.add_argument("--log")
    open_parser.add_argument("--trace-template")
    open_parser.add_argument("--instrument", action="append")
    open_parser.add_argument("--trace-seconds", type=positive(int), default=20)
    open_parser.add_argument("--trace-dir", default=str(TRACE_DIR))
    open_parser.set_defaults(func=open_bench)
    scenario_parser = commands.add_parser("scenario", help="prepare production persistence, then replay an offline working journey")
    scenario_parser.add_argument("--fixture", required=True)
    scenario_parser.add_argument("--label", required=True)
    scenario_parser.add_argument("--runs", type=positive(int), default=3)
    scenario_parser.add_argument("--settle", type=positive(float), default=3)
    scenario_parser.add_argument("--log", required=True)
    scenario_parser.add_argument("--trace-template")
    scenario_parser.add_argument("--instrument", action="append")
    scenario_parser.add_argument("--trace-seconds", type=positive(int), default=75)
    scenario_parser.add_argument("--trace-dir", default=str(TRACE_DIR))
    scenario_parser.set_defaults(func=scenario)
    commands.add_parser("udid").set_defaults(func=lambda _args: print(simulator()))
    args = parser.parse_args()
    configure_identity()
    with job_sleep_assertion():
        args.func(args)


if __name__ == "__main__":
    main()
