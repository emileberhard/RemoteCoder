"""Measure transcript scrolling in the Mac app on the MacBook.

`build` compiles and signs the `RC_PERF_HARNESS` app on the MacBook
(`scripts/remote-build.py mac-bench`) and returns it here; `install` places it in
/Applications. `run` launches it with a scroll plan: the app opens one
conversation, synthesizes trackpad gestures with momentum from a wall-clock-paced
thread, and records per-frame main-thread pacing, scroll offsets and, through
ScreenCaptureKit, every presented window frame (optionally a movie). The run's
raw report and summary remain in the owned build-cache run directory.
"""

import argparse
import json
import math
import os
import plistlib
import re
import shutil
import signal
import statistics
import subprocess
import sys
import time
import uuid
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from uuid import uuid4

from remotecoder_tools.mac_sample import (
    focus_sample,
    read_sample,
    summarize_sample,
    summarize_stacks,
)

ROOT = Path(__file__).resolve().parents[3]
TARGET = Path("/Applications/RemoteCoder.app")
WORK = ROOT / "build/mac-bench"
FRAME_COMPLETE = 0


def gesture(velocity: float, drag: float, momentum: bool = True, pause: float = 0.35, eased: bool = False) -> dict:
    return {"velocity": velocity, "dragSeconds": drag, "eased": eased, "momentum": momentum, "pauseSeconds": pause}


def stroke(velocity: float, seconds: float, pause: float = 0.3) -> dict:
    return gesture(velocity, seconds, momentum=False, pause=pause, eased=True)


PATTERNS = {
    "idle": [],
    "standard": [stroke(2600, 1.0)] * 4 + [stroke(-2600, 1.0)] * 2 + [stroke(2600, 0.8)] * 2,
    "flings": [gesture(2600, 0.12)] * 4 + [gesture(-2600, 0.12)] * 4,
    "drag": [gesture(900, 2.5, momentum=False), gesture(-900, 2.5, momentum=False)],
    "deep": [stroke(3200, 1.0, pause=0.2)] * 8 + [stroke(-3200, 1.0, pause=0.2)] * 8,
}
WARMUP = [gesture(4200, 0.12, pause=0.1)] * 4 + [gesture(-4200, 0.12, pause=0.1)] * 4
BRIDGED_STILL_TICKS = 3
WORST_STALLS = 5
SLOW_PASSES = 12


def run_command(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(command, check=True, **kwargs)


def running_pids() -> list[int]:
    listed = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True, check=True).stdout
    executable = str(TARGET / "Contents/MacOS/RemoteCoder")
    return [int(line.split(None, 1)[0]) for line in listed.splitlines() if line.split(None, 1)[1:] == [executable]]


def quit_app() -> None:
    sys.path.insert(0, str(ROOT / "scripts"))
    from process_group import audit_alive, audit_path, process_identity, signal_process

    executable = TARGET / "Contents/MacOS/RemoteCoder"
    owned = []
    for pid in running_pids():
        identity = process_identity(pid)
        if identity is not None and audit_path(identity) == executable:
            owned.append(identity)
    for identity in owned:
        signal_process(identity, signal.SIGTERM)
    deadline = time.monotonic() + 10
    while live := [identity for identity in owned if audit_alive(identity)]:
        if time.monotonic() > deadline:
            for identity in live:
                signal_process(identity, signal.SIGKILL)
            break
        time.sleep(0.1)


def build(args: argparse.Namespace) -> None:
    arguments = []
    if args.lab_config is not None:
        if not args.lab_config.is_absolute():
            raise SystemExit("--lab-config must be an absolute path on the MacBook")
        arguments = ["--lab-config", str(args.lab_config)]
    result = subprocess.run([sys.executable, "scripts/remote-build.py", "mac-bench", *arguments], cwd=ROOT,
                            stdout=subprocess.PIPE, text=True)
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    if result.returncode or not lines:
        raise SystemExit(result.returncode or 1)
    receipt = json.loads(lines[-1])
    print(json.dumps({key: receipt.get(key) for key in ("app", "buildId", "sourceCommit", "elapsedSeconds")}))


def latest_build() -> Path:
    builds = sorted(WORK.glob("*/RemoteCoder.app"), key=lambda path: path.parent.stat().st_birthtime)
    if not builds:
        raise SystemExit("No bench build; run `mac-bench build` first")
    return builds[-1]


def install(args: argparse.Namespace) -> None:
    require_gui_host(args)
    app = args.app or latest_build()
    run_command(["codesign", "--verify", "--deep", "--strict", str(app)])
    quit_app()
    stage = TARGET.parent / ".RemoteCoder-bench.app"
    shutil.rmtree(stage, ignore_errors=True)
    run_command(["ditto", str(app), str(stage)])
    if TARGET.exists():
        shutil.rmtree(TARGET)
    stage.rename(TARGET)
    info = plistlib.loads((TARGET / "Contents/Info.plist").read_bytes())
    print(json.dumps({"installed": str(TARGET), "from": str(app), "build": info.get("CFBundleVersion"),
                      "commit": info.get("RemoteCoderSourceCommit"), "modified": info.get("RemoteCoderSourceModified")}))


def measured_display_mode() -> dict:
    profile = json.loads(subprocess.check_output(["system_profiler", "SPDisplaysDataType", "-json"], text=True))
    main = [screen for device in profile["SPDisplaysDataType"] for screen in device.get("spdisplays_ndrvs", [])
            if screen.get("spdisplays_main") == "spdisplays_yes"]
    if len(main) != 1:
        raise SystemExit("Cannot establish the main display measurement mode")
    resolution = re.fullmatch(r"(\d+) x (\d+) @ ([\d.]+)Hz", main[0].get("_spdisplays_resolution", ""))
    pixels = re.fullmatch(r"(\d+) x (\d+)", main[0].get("_spdisplays_pixels", ""))
    if resolution is None or pixels is None:
        raise SystemExit("Cannot establish display resolution, refresh or backing scale")
    width, height = int(resolution[1]), int(resolution[2])
    if width <= 0 or height <= 0:
        raise SystemExit("Invalid display point dimensions")
    scale = int(pixels[1]) / width
    if scale not in (1, 2) or scale != int(pixels[2]) / height:
        raise SystemExit("Cannot establish the display backing scale")
    return {"width": width, "height": height, "scale": scale, "maximumFramesPerSecond": float(resolution[3])}


def display(_: argparse.Namespace) -> None:
    print(json.dumps(measured_display_mode()))


def plan(args: argparse.Namespace, label: str) -> dict:
    host = args.host or maintainer_settings().get("macBenchmarkGatewayId")
    try:
        host = str(uuid.UUID(host)).upper()
    except (ValueError, TypeError, AttributeError):
        raise SystemExit("Set --host UUID or maintainer macBenchmarkGatewayId to the GUI host gateway UUID") from None
    if args.fixture == "cold-table" and (args.stream is not None or args.check_interaction or args.pattern == "idle"):
        raise SystemExit("--fixture requires scrolling with no stream or interaction check")
    if args.fixture == "horizontal-overflow" or args.check_interaction == "horizontal-displacement":
        if (args.fixture != "horizontal-overflow" or args.check_interaction != "horizontal-displacement"
                or args.stream is not None or args.warmup or args.pattern != "idle"):
            raise SystemExit("horizontal-overflow requires --check-interaction horizontal-displacement --pattern idle without stream or warmup")
    if args.stream is None and (args.stream_scroll or args.stream_kind != "mixed"):
        raise SystemExit("--stream-kind and --stream-scroll require --stream SECONDS")
    pattern = "standard" if args.stream_scroll else args.pattern
    width, height = (float(part) for part in args.size.split("x"))
    if args.fixture == "horizontal-overflow" and height < 500:
        raise SystemExit("horizontal-overflow requires a window at least 500 points high")
    if pattern == "idle" and args.warmup:
        raise SystemExit("--pattern idle does not allow --warmup")
    if args.check_interaction and (pattern != "idle" or args.delivery != "app"):
        raise SystemExit("--check-interaction requires --pattern idle and --delivery app")
    if args.check_interaction == "tracking" and args.stream is None:
        raise SystemExit("--check-interaction tracking requires --stream")
    if args.check_interaction in {"reading-growth", "narrow-zoom"} and (args.stream_kind != "paragraph" or args.stream is None or args.stream < 8):
        raise SystemExit(f"--check-interaction {args.check_interaction} requires --stream-kind paragraph and --stream of at least 8 seconds")
    if args.check_interaction == "table-selection" and (args.stream_kind not in {"wide-table", "wide-table-then-prose"} or args.stream is None or args.stream < 8):
        raise SystemExit("--check-interaction table-selection requires a wide-table stream of at least 8 seconds")
    if args.check_interaction in {"cancelled-momentum", "composer-typing", "composer-editing", "horizontal-displacement"} and args.stream is not None:
        raise SystemExit(f"--check-interaction {args.check_interaction} does not support --stream")
    tail_seconds = args.idle_seconds * args.repeat if pattern == "idle" and args.stream is None else 0.6
    if args.tail is not None:
        tail_seconds = args.tail
    if not math.isfinite(tail_seconds) or tail_seconds <= 0:
        raise SystemExit("idle duration must be finite and positive")
    result = {
        "label": label,
        "host": host,
        "thread": args.thread,
        "fixture": args.fixture,
        "appearance": args.appearance,
        "scrollbars": args.scrollbars,
        "width": width,
        "height": height,
        "expectedDisplay": args.expected_display,
        "pointerX": 0.45,
        "pointerY": 0.5,
        "settleSeconds": args.settle,
        "tailSeconds": tail_seconds,
        "warmup": WARMUP if args.warmup else [],
        "gestures": PATTERNS[pattern] * args.repeat,
        "capture": args.capture,
        "delivery": args.delivery,
        "quit": False,
        "checkInteraction": args.check_interaction,
    }
    if args.stream is not None:
        result["stream"] = {"kind": args.stream_kind, "seconds": args.stream, "charsPerTick": 60, "tickMs": 30}
    if args.switches:
        result["switches"] = True
    if args.persistence:
        result["persistence"] = True
    return result


def stream_seconds(value: str) -> float:
    seconds = float(value)
    if not math.isfinite(seconds) or not 0 < seconds <= 120:
        raise argparse.ArgumentTypeError("stream duration must be greater than 0 and at most 120 seconds")
    return seconds


def sample_seconds(value: str) -> float:
    seconds = float(value)
    if not math.isfinite(seconds) or not 0 < seconds <= 60:
        raise argparse.ArgumentTypeError("sample duration must be greater than 0 and at most 60 seconds")
    return seconds


def maintainer_settings() -> dict:
    sys.path.insert(0, str(ROOT / "scripts"))
    from maintainer_config import load

    return load()


def require_gui_host(args: argparse.Namespace) -> None:
    expected = args.gui_host or maintainer_settings().get("macGUIHost")
    if not isinstance(expected, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,62}", expected):
        raise SystemExit("Set --gui-host or maintainer macGUIHost to the dedicated GUI host")
    host = subprocess.check_output(["scutil", "--get", "LocalHostName"], text=True).strip()
    if host.lower() != expected.lower():
        raise SystemExit(f"Mac app installs and benchmark runs require the configured GUI host: {expected}")


def require_hid_idle() -> None:
    idle = subprocess.check_output(["ioreg", "-c", "IOHIDSystem"], text=True)
    idle_time = re.search(r'"HIDIdleTime" = (\d+)', idle)
    if idle_time is None or int(idle_time[1]) < 120_000_000_000:
        raise SystemExit("MacBook HID idle must be at least 120 seconds immediately before launch")


def quit_installed_app(args: argparse.Namespace) -> None:
    require_gui_host(args)
    require_hid_idle()
    quit_app()


def measurement_hold_seconds(args: argparse.Namespace) -> float:
    sys.path.insert(0, str(ROOT / "scripts"))
    from build_support import MAX_MEASUREMENT_SECONDS

    if not 1 <= args.runs <= MAX_MEASUREMENT_SECONDS // 50 or not math.isfinite(args.timeout) or args.timeout <= 0:
        raise SystemExit("--runs and --timeout must be positive, with a finite timeout")
    limit = args.runs * (args.timeout + (60 if args.sample else 0) + 50)
    if limit > MAX_MEASUREMENT_SECONDS:
        raise SystemExit(f"The measurement reservation must fit within {MAX_MEASUREMENT_SECONDS} seconds; reduce --runs or --timeout")
    return limit


def run(args: argparse.Namespace) -> None:
    require_gui_host(args)
    if not TARGET.exists():
        raise SystemExit(f"{TARGET} is missing; run `mac-bench install`")
    hold = measurement_hold_seconds(args)
    plan(args, args.label or "measurement")
    sys.path.insert(0, str(ROOT / "scripts"))
    from build_support import run_connected

    result = run_connected([
        sys.executable, str(ROOT / "scripts/measurement.py"),
        "--source", str(ROOT), "--hold-seconds", str(hold), "--",
        sys.executable, str(Path(__file__).resolve()), "_measure", *sys.argv[2:],
    ])
    print(result.stdout, end="", flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)


def run_admitted(args: argparse.Namespace) -> None:
    require_gui_host(args)
    receipt_path = os.environ.get("RC_MEASUREMENT_RECEIPT")
    if receipt_path is None:
        raise SystemExit("Use `mac-bench run` to acquire the measurement reservation")
    receipt = json.loads(Path(receipt_path).read_text())
    if receipt.get("kind") != "measurement-reservation" or not receipt.get("acquiredAt") or receipt.get("exitCode") is not None:
        raise SystemExit("The measurement reservation is not active")
    label = args.label or datetime.now().strftime("%m%d-%H%M%S")
    if args.runs == 1:
        print_summary(run_once(args, label))
        return
    summaries = [run_once(args, f"{label}-{index}") for index in range(1, args.runs + 1)]
    for summary in summaries:
        print_summary(summary)
    print(json.dumps({"spread": spread(summaries)}))


def bench_runs() -> Path:
    sys.path.insert(0, str(ROOT / "scripts"))
    from build_support import cache_root

    return cache_root() / "runs"


@contextmanager
def _bench_signals(handler):
    previous = {signum: signal.signal(signum, handler) for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
    try:
        yield
    finally:
        for signum, prior in previous.items():
            signal.signal(signum, prior)


@contextmanager
def _bench_acquisition():
    pending = None

    def defer(signum, _frame):
        nonlocal pending
        if pending is None:
            pending = signum

    try:
        with _bench_signals(defer):
            yield
    finally:
        if pending is not None:
            signal.raise_signal(pending)


@contextmanager
def bench_output(bench: dict):
    directory = bench_runs()
    from build_cache import lease_path, load_policy, prune_caches, touch_usage
    from build_support import atomic_json, file_lease

    identity = "mac-bench-" + uuid4().hex
    output = directory / identity
    directory.mkdir(parents=True, exist_ok=True)
    root = directory.parent

    def cancel(signum, _frame):
        raise SystemExit(128 + signum)

    with file_lease(lease_path(root, "runs", identity)), _bench_signals(cancel):
        output.mkdir()
        touch_usage(root, "runs", identity)
        receipt = {
            "kind": "mac-bench-run",
            "runId": identity,
            "label": bench["label"],
            "outputDirectory": str(output),
            "startedAt": datetime.now().astimezone().isoformat(),
            "exitCode": None,
            "measurementReservation": os.environ.get("RC_MEASUREMENT_RECEIPT"),
        }
        atomic_json(output / "receipt.json", receipt)
        print(f"Bench run {identity}: {output}", file=sys.stderr, flush=True)
        try:
            receipt["cacheRetired"] = prune_caches(root, load_policy(), "", identity)
            yield output
        except BaseException as error:
            receipt["exitCode"] = (
                error.code if isinstance(error, SystemExit) and type(error.code) is int
                else 130 if isinstance(error, KeyboardInterrupt) else 1
            )
            receipt["errorType"] = type(error).__name__
            raise
        else:
            receipt["exitCode"] = 0
        finally:
            with _bench_signals(signal.SIG_IGN):
                receipt["endedAt"] = datetime.now().astimezone().isoformat()
                touch_usage(root, "runs", identity)
                atomic_json(output / "receipt.json", receipt)


def run_once(args: argparse.Namespace, label: str) -> dict:
    bench = plan(args, label)
    expected_mode = args.expected_display
    mode = measured_display_mode()
    if mode != expected_mode:
        raise SystemExit(f"Display is {mode}; expected {expected_mode}")
    with bench_output(bench) as output:
        return measure_run(args, bench, output)


def measure_run(args: argparse.Namespace, bench: dict, output: Path) -> dict:
    expected_mode = args.expected_display
    (output / "plan.json").write_text(json.dumps(bench, indent=2) + "\n")
    stdout, stderr = output / "stdout.jsonl", output / "stderr.log"
    launch = ["/usr/bin/open", "-n", "--stdout", str(stdout), "--stderr", str(stderr), str(TARGET), "--args",
              "-rcPerfBench", json.dumps(bench), "-ApplePersistenceIgnoreState", "YES",
              "-NSQuitAlwaysKeepsWindows", "NO"]
    if args.disable:
        launch += ["-rcPerfDisable", args.disable]
    if args.mount_cap:
        launch += ["-rcPerfMountCap", str(args.mount_cap)]
    if args.scrollbars:
        launch += ["-AppleShowScrollBars", args.scrollbars]
    started = time.monotonic()
    require_hid_idle()
    if running_pids():
        raise SystemExit("RemoteCoder is already running; use `mac-bench quit` before starting a measurement")
    require_hid_idle()
    sampler = None
    environment = {name: os.environ[name] for name in (
        "HOME", "USER", "LOGNAME", "TMPDIR", "__CF_USER_TEXT_ENCODING", "LANG", "LC_CTYPE", "LC_ALL",
    ) if name in os.environ}
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    try:
        with _bench_acquisition():
            run_command(launch, env=environment)
        done = None
        while done is None:
            if time.monotonic() - started > args.timeout:
                raise SystemExit(f"bench did not finish in {args.timeout} s; see {output}")
            time.sleep(0.05 if args.sample and sampler is None else 0.25)
            lines = [json.loads(line) for line in stdout.read_text().splitlines() if line.startswith("{")] if stdout.exists() else []
            measuring = next((line for line in lines if line.get("bench") == "measuring"), None)
            if args.sample and sampler is None and measuring:
                with _bench_acquisition():
                    sampler = subprocess.Popen(["/usr/bin/sample", str(measuring["pid"]), str(args.sample), str(args.sample_interval), "-mayDie",
                                                "-file", str(output / "sample.txt")],
                                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            done = next((line for line in lines if line.get("bench") == "done" or "error" in line), None)
            if done is None and time.monotonic() - started > 5 and not running_pids():
                raise SystemExit(f"the app exited without a result; see {output}")
        if "dir" in done:
            source = Path(done["dir"])
            for item in source.iterdir():
                if item.is_dir():
                    shutil.copytree(item, output / item.name, dirs_exist_ok=True)
                else:
                    shutil.copy2(item, output / item.name)
        if sampler and sampler.wait(timeout=60) != 0:
            raise SystemExit(f"stack sampling failed; see {output}")
    finally:
        with _bench_signals(signal.SIG_IGN):
            try:
                if sampler is not None and sampler.poll() is None:
                    sampler.terminate()
                    try:
                        sampler.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        sampler.kill()
                        sampler.wait(timeout=5)
            finally:
                quit_app()
    if done.get("error"):
        raise SystemExit(f"bench failed: {done['error']}; see {output}")
    summary = analyze_run(output)
    if summary["display"] != expected_mode:
        raise SystemExit(f"Recorded display mode{summary['display']} differs from requested{expected_mode}")
    require_matching_displays([summary])
    if measured_display_mode() != expected_mode:
        raise SystemExit("Display mode changed during the measurement")
    summary["wallSeconds"] = round(time.monotonic() - started, 1)
    if reservation := os.environ.get("RC_MEASUREMENT_RECEIPT"):
        receipt = json.loads(Path(reservation).read_text())
        summary["measurementReservation"] = {"receipt": reservation, "queueWaitSeconds": receipt["queueWaitSeconds"]}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    if (summary.get("validation") or {}).get("error"):
        raise SystemExit(f"switch validation failed: {summary['validation']['error']}; see {output}")
    return summary


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(fraction * len(ordered)) - 1))]


def vsync_histogram(intervals: list[float], period: float) -> dict[str, int]:
    counts: dict[str, int] = {}
    for interval in intervals:
        key = str(max(1, round(interval / period)))
        counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items(), key=lambda item: int(item[0])))


def rounded(value: float | None, digits: int = 2) -> float | None:
    return None if value is None else round(value, digits)


def motion_windows(frames: list[list[float]]) -> list[tuple[float, float]]:
    windows: list[list[float]] = []
    still = BRIDGED_STILL_TICKS + 1
    for previous, row in zip(frames, frames[1:], strict=False):
        if row[5] != previous[5]:
            if windows and still <= BRIDGED_STILL_TICKS:
                windows[-1][1] = row[0]
            else:
                windows.append([previous[0], row[0]])
            still = 0
        else:
            still += 1
    return [(start, end) for start, end in windows if end > start]


def inside(windows: list[tuple[float, float]], time: float) -> int | None:
    for index, (start, end) in enumerate(windows):
        if start <= time <= end:
            return index
    return None


def analyze_run(directory: Path) -> dict:
    report = json.loads((directory / "report.json").read_text())
    frames = report["frames"]
    events = report["events"]
    period = statistics.median(row[1] - row[0] for row in frames)
    hz = round(1 / period)
    motion = motion_windows(frames)
    moving_seconds = sum(end - start for start, end in motion)
    origin = report["measureStart"]
    scope = report.get("analysisScope", "motion")
    if scope not in ("motion", "window"):
        raise ValueError(f"Unknown analysis scope: {scope}")
    windows = [(origin, report["measureEnd"])] if scope == "window" else motion
    analyzed_seconds = sum(end - start for start, end in windows)
    ticks = [(previous, row) for previous, row in zip(frames, frames[1:], strict=False)
             if scope == "window" or inside(windows, row[0]) is not None]
    analyzed_frames = frames if scope == "window" else [row for _, row in ticks]
    intervals = [row[0] - previous[0] for previous, row in ticks]
    busy = [row[3] for row in analyzed_frames]
    longest = [row[4] for row in analyzed_frames]
    stalls = sorted(((row[0] - previous[0], previous[0]) for previous, row in ticks), reverse=True)[:WORST_STALLS]
    lateness = [(event[1] - event[0]) * 1000 for event in events]
    queued = [(event[6] - event[1]) * 1000 for event in events if len(event) > 6 and event[6]]
    posted = sum(abs(event[2]) for event in events)
    moved = sum(abs(row[5] - previous[5]) for previous, row in zip(frames, frames[1:], strict=False))
    spans = report.get("spans")
    summary: dict = {
        "label": report["label"],
        "build": report["build"],
        "messages": report["messages"],
        "loadMs": rounded(report["loadMs"], 0),
        "refreshHz": hz,
        "display": report["display"],
        "measurementHost": report.get("measurementHost"),
        "outputDirectory": str(directory),
        "window": report["window"],
        "transcript": report["transcript"],
        "movingSeconds": rounded(moving_seconds, 2),
        "motionWindows": len(motion),
        "analysisScope": scope,
        "stream": report.get("stream"),
        "fixture": report.get("fixture"),
        "analyzedSeconds": rounded(analyzed_seconds, 2),
        "mainRunLoop": {
            "intervalsByVsyncs": vsync_histogram(intervals, period),
            "missedVsyncs": sum(max(0, round(interval / period) - 1) for interval in intervals),
            "onTimeShare": rounded(sum(1 for i in intervals if i < 1.5 * period) / len(intervals), 4) if intervals else None,
            "busyP50ms": rounded(percentile(busy, 0.5)),
            "busyP95ms": rounded(percentile(busy, 0.95)),
            "busyP99ms": rounded(percentile(busy, 0.99)),
            "busyShare": rounded(sum(busy) / 1000 / analyzed_seconds, 3) if analyzed_seconds else None,
            "longestPassMs": rounded(max(longest) if longest else None),
            "framesOverBudget": sum(1 for value in busy if value > period * 1000),
            "worstStalls": [{"ms": rounded(gap * 1000, 1), "atS": rounded(at - origin, 2)} for gap, at in stalls],
        },
        "input": {
            "events": len(events),
            "postedPixels": round(posted),
            "movedPixels": round(moved),
            "contentHeight": [round(frames[0][7]), round(max(row[7] for row in frames))] if frames else None,
            "producerLatenessP99ms": rounded(percentile(lateness, 0.99)),
            "queuedP50ms": rounded(percentile(queued, 0.5)),
            "queuedP99ms": rounded(percentile(queued, 0.99)),
        },
        "processCPUms": rounded(report["processCPUms"], 0),
        "mainThreadCPUms": rounded(report["mainThreadCPUms"], 0),
        "footprintMB": [rounded(report["footprintStartMB"], 0), rounded(report["footprintEndMB"], 0)],
        "thermalState": report["thermalState"],
        "counters": report.get("counters"),
        "gauges": report.get("gauges"),
        "spans": sorted(spans, key=lambda span: (-span["totalMs"], span["name"])) if spans is not None else None,
        "spanRecording": report.get("spanRecording"),
        "switches": report.get("switches"),
        "persistence": report.get("persistence"),
        "windowOcclusionVisible": report.get("windowOcclusionVisible"),
        "validation": report.get("validation"),
    }
    span_recording = report.get("spanRecording")
    unmarked_spans = [] if span_recording is not None and span_recording.get("truncated") is False else None
    marks = report.get("marks") or []
    frame_marks = {mark["t"]: mark for mark in marks}
    slowest = sorted(((row[3], row[0]) for row in analyzed_frames), reverse=True)[:SLOW_PASSES]
    summary["slowPasses"] = [
        {"atS": rounded(at - origin, 3), "busyMs": rounded(ms, 1),
         "marks": {name: delta for mark in marks if at - 2 * period <= mark["t"] <= at + period
                   for name, delta in mark["d"].items()},
         "spans": frame_marks.get(at, {}).get("spans", unmarked_spans)}
        for ms, at in slowest
    ]
    recording = report.get("recording")
    if recording and "frames" in recording:
        complete = [sample[0] for sample in recording["frames"] if sample[2] == FRAME_COMPLETE]
        gaps = [b - a for a, b in zip(complete, complete[1:], strict=False)
                if inside(windows, b) is not None and inside(windows, b) == inside(windows, a)]
        presented = sum(1 for time in complete if inside(windows, time) is not None)
        histogram = vsync_histogram(gaps, period)
        summary["presented"] = {
            "frames": presented,
            "fpsInAnalysisWindow": rounded(presented / analyzed_seconds, 1) if analyzed_seconds else None,
            "fpsWhileMoving": rounded(sum(1 for time in complete if inside(motion, time) is not None) / moving_seconds, 1)
                              if moving_seconds else None,
            "intervalsByVsyncs": histogram,
            "skippedVsyncs": sum((int(key) - 1) * count for key, count in histogram.items()),
            "oneVsyncShare": rounded(histogram.get("1", 0) / len(gaps), 4) if gaps else None,
            "atMostTwoVsyncShare": rounded((histogram.get("1", 0) + histogram.get("2", 0)) / len(gaps), 4) if gaps else None,
            "worstGapMs": rounded(max(gaps) * 1000 if gaps else None),
        }
        video = directory / "video.mov"
        if video.exists():
            summary["video"] = str(video)
    if (directory / "sample.txt").exists():
        summary["sample"] = summarize_sample(directory / "sample.txt")
    return summary


def headline(summary: dict) -> dict:
    loop = summary["mainRunLoop"]
    line = {
        "label": summary["label"], "hz": summary["refreshHz"], "display": summary["display"], "messages": summary["messages"],
        "outputDirectory": summary["outputDirectory"],
        "scope": summary["analysisScope"], "analyzedS": summary["analyzedSeconds"],
        "movingS": summary["movingSeconds"], "rlOnTime": loop["onTimeShare"], "rlMissed": loop["missedVsyncs"],
        "busyP50": loop["busyP50ms"], "busyP95": loop["busyP95ms"], "busyP99": loop["busyP99ms"],
        "busyShare": loop["busyShare"], "longestPass": loop["longestPassMs"],
        "worstStallMs": loop["worstStalls"][0]["ms"] if loop["worstStalls"] else None,
        "moved": summary["input"]["movedPixels"], "height": summary["input"].get("contentHeight"), "rows": (summary.get("gauges") or {}).get("transcriptSubviews"), "mainCPUms": summary["mainThreadCPUms"],
    }
    if presented := summary.get("presented"):
        line.update({"fps": presented["fpsInAnalysisWindow"], "pres1v": presented["oneVsyncShare"],
                     "pres2v": presented["atMostTwoVsyncShare"], "presSkipped": presented["skippedVsyncs"],
                     "presWorstMs": presented["worstGapMs"]})
    return line


def print_summary(summary: dict) -> None:
    print(json.dumps(headline(summary)))
    if sample := summary.get("sample"):
        if "error" in sample:
            print(f"Sample: {sample['error']}", file=sys.stderr)
        else:
            breakdown = ", ".join(f"{row['name']} {percent(row['busyShare'])}" for row in sample["categories"])
            interval = f"{sample['intervalMs']:g} ms" if sample["intervalMs"] is not None else "unknown interval"
            print(f"Main busy samples: {breakdown} ({interval})", file=sys.stderr)
    spans = summary.get("spans")
    if spans is None:
        return
    print(f"{summary['label']}: inclusive phase wall time (ms)", file=sys.stderr)
    print(f"{'phase':<26} {'count':>7} {'total':>9} {'p50':>8} {'p95':>8} {'max':>8} {'main':>6}", file=sys.stderr)
    for span in spans[:12]:
        print(f"{span['name']:<26} {span['count']:>7} {span['totalMs']:>9.2f} "
              f"{span['p50Ms']:>8.3f} {span['p95Ms']:>8.3f} {span['maxMs']:>8.3f} "
              f"{span['mainThreadShare']:>6.0%}", file=sys.stderr)
    recording = summary.get("spanRecording")
    if recording and recording["truncated"]:
        print(f"Span coverage truncated: {recording['overwritten']} spans overwritten, "
              f"{recording['busyIntervalsDropped']} busy intervals dropped", file=sys.stderr)


SPREAD_KEYS = ("fps", "pres1v", "rlOnTime", "busyP95", "busyP99", "busyShare", "mainCPUms", "worstStallMs")


def spread(summaries: list[dict]) -> dict:
    require_matching_displays(summaries)
    lines = [headline(summary) for summary in summaries]
    result = {}
    for key in SPREAD_KEYS:
        values = [line[key] for line in lines if line.get(key) is not None]
        if values:
            result[key] = {"mean": rounded(statistics.fmean(values), 3), "min": min(values), "max": max(values)}
    return result


def analyze(args: argparse.Namespace) -> None:
    summaries = [analyze_run(directory) for directory in args.runs]
    require_matching_displays(summaries)
    for directory, summary in zip(args.runs, summaries, strict=True):
        (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print_summary(summary)


def require_matching_displays(summaries: list[dict]) -> None:
    fields = ("width", "height", "scale", "maximumFramesPerSecond")
    modes = {tuple(summary["display"].get(field) for field in fields) for summary in summaries}
    if len(modes) != 1 or any(value is None or value <= 0 for mode in modes for value in mode):
        raise SystemExit("Cannot compare runs with different or unknown display resolution, scale or refresh")
    if any(summary["refreshHz"] != summary["display"]["maximumFramesPerSecond"] for summary in summaries):
        raise SystemExit("Measured display cadence differs from the recorded refresh rate")
    hosts = {summary.get("measurementHost") for summary in summaries}
    if len(hosts) != 1 or None in hosts or "" in hosts:
        raise SystemExit("Cannot compare runs from different or unknown measurement hosts")


def expected_display(value: str) -> dict:
    match = re.fullmatch(r"([1-9]\d*)x([1-9]\d*)@([1-9]\d*)/([12])", value)
    if match is None:
        raise argparse.ArgumentTypeError("expected WIDTHxHEIGHT@HZ/SCALE, with scale1 or2")
    width, height, hz, scale = map(int, match.groups())
    return {"width": width, "height": height, "scale": scale, "maximumFramesPerSecond": hz}


def positive_int(value: str) -> int:
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def percent(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.1%}"


def print_tree(rows: list[dict], depth: int, share_label: str, indent: int) -> None:
    for row in rows[:10]:
        print(f"{'  ' * indent}{percent(row[f'{share_label}Share']):>6} {share_label}  {percent(row['mainShare']):>6} main  "
              f"{row['samples']:>6}  {row['name']}")
        if row["children"] and depth > 1:
            print_tree(row["children"], depth - 1, share_label, indent + 1)
    if len(rows) > 10:
        print(f"{'  ' * indent}... {len(rows) - 10} more branches ({sum(row['samples'] for row in rows[10:])} samples)")


def profile(args: argparse.Namespace) -> None:
    directory = Path(args.label)
    if not directory.is_dir():
        matches = [
            path.parent for path in bench_runs().glob("mac-bench-*/receipt.json")
            if json.loads(path.read_text())["label"] == args.label
        ]
        if len(matches) != 1:
            raise SystemExit("Provide the saved output directory when a bench label is missing or repeated")
        directory = matches[0]
    try:
        sample = read_sample(directory / "sample.txt")
        pattern = re.compile(args.focus) if args.focus is not None else None
    except (OSError, ValueError, re.PatternError) as error:
        raise SystemExit(str(error)) from error
    summary = summarize_stacks(sample, 10)
    interval = f"{sample.interval_ms:g} ms" if sample.interval_ms is not None else "unknown interval"
    print(f"{directory.name}: {summary['mainSamples']} main samples, {summary['busySamples']} busy, "
          f"{summary['idleSamples']} idle; {interval}")
    print("Categories (children partition parents; busy excludes idle run-loop waits):")
    print_tree(summary["categories"], args.depth, "busy", 0)
    print("RemoteCoder frames (inclusive; rows overlap):")
    for row in summary["appFrames"]:
        print(f"{percent(row['busyShare']):>6} busy  {percent(row['mainShare']):>6} main  "
              f"{row['samples']:>6}  {row['symbol']}")
    if pattern is not None:
        focus = focus_sample(sample, pattern, args.depth)
        print(f"Focus {args.focus!r}: {focus['samples']} samples ({percent(focus['mainShare'])} main), "
              f"{focus['selfSamples']} self; first root-to-leaf match per stack")
        if not focus["samples"]:
            print("No main-thread frames matched.")
            return
        print("Callers (nearest first; shares are of matching samples and all main samples):")
        print_tree(focus["callers"], args.depth, "focus", 0)
        print("Callees (shares are of matching samples and all main samples):")
        print_tree(focus["callees"], args.depth, "focus", 0)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    building = commands.add_parser("build", help="build and sign the bench app on the MacBook and return it")
    building.add_argument("--lab-config", type=Path,
                          help="private configuration on the MacBook for an isolated loopback gateway; the signed "
                          "app stays in that lab directory")
    building.set_defaults(handler=build)
    installing = commands.add_parser("install", help="install the newest returned bench app into /Applications")
    installing.add_argument("--app", type=Path)
    installing.add_argument("--gui-host")
    installing.set_defaults(handler=install)
    quitting = commands.add_parser("quit", help="explicitly quit the installed app on the idle GUI host")
    quitting.add_argument("--gui-host")
    quitting.set_defaults(handler=quit_installed_app)
    displaying = commands.add_parser("display", help="report the current display mode without changing it")
    displaying.set_defaults(handler=display)
    running = commands.add_parser("run", help="run one scroll bench and summarize it")
    running.add_argument("--thread", required=True)
    running.add_argument("--switches", action="store_true", help="measure cold and cached short/long fixture switches")
    running.add_argument("--persistence", action="store_true", help="measure durable sends and checkpoint writes with isolated fixtures")
    running.add_argument("--host", help="GUI host gateway UUID (default: maintainer macBenchmarkGatewayId)")
    running.add_argument("--gui-host", help="dedicated GUI hostname (default: maintainer macGUIHost)")
    running.add_argument("--label")
    running.add_argument("--appearance", choices=("light", "dark"), help="override appearance only in the benchmark app")
    running.add_argument("--scrollbars", choices=("Automatic", "Always"), help="override scrollbar preference in this launch's argument domain")
    running.add_argument("--tail", type=stream_seconds, help="seconds to hold the settled fixture for acceptance before quitting (maximum 120)")
    running.add_argument("--fixture", choices=("cold-table", "horizontal-overflow"), help="prepare a local settled transcript corpus")
    running.add_argument("--pattern", choices=sorted(PATTERNS), default="standard")
    running.add_argument("--idle-seconds", type=float, default=10, help="seconds per repeat for the idle pattern")
    running.add_argument("--stream", type=stream_seconds, metavar="SECONDS",
                         help="stream synthetic Markdown at 60 characters every 30 ms; idle measures this duration")
    running.add_argument("--stream-kind", choices=("mixed", "paragraph", "code", "table", "conversation", "fit-table", "table-appearance", "wide-table", "wide-table-then-prose"), default="mixed",
                         help="stream mixed passages, a paragraph, code, a table, or interleaved conversation rows")
    running.add_argument("--stream-scroll", action="store_true",
                         help="run standard scroll gestures concurrently with --stream (overrides --pattern)")
    running.add_argument("--check-interaction", choices=("tracking", "cancelled-momentum", "reading-growth", "table-selection", "narrow-zoom", "composer-typing", "composer-editing", "horizontal-displacement"),
                         help="check native tracking during growth or momentum cancellation outside the transcript")
    running.add_argument("--repeat", type=int, default=1)
    running.add_argument("--capture", choices=("none", "frames", "video"), default="frames")
    running.add_argument("--delivery", choices=("app", "send", "queue"), default="app",
                         help="dispatch through NSApplication (app), directly to NSWindow (send), or through the app event queue (queue)")
    running.add_argument("--size", default="1512x945")
    running.add_argument("--expected-display", type=expected_display, default="2560x1440@120/1",
                         help="required display resolution, refresh and backing scale (default:2560x1440@120/1)")
    running.add_argument("--settle", type=float, default=1.5)
    running.add_argument("--warmup", action="store_true", help="scroll the history once before measuring")
    running.add_argument("--runs", type=int, default=1, help="repeat the run and report the spread")
    running.add_argument("--disable", help="comma-separated PerfBuild A/B switches")
    running.add_argument("--timeout", type=float, default=180)
    running.add_argument("--mount-cap", type=int, help="mount at most this many transcript rows (harness experiment)")
    running.add_argument("--sample", type=sample_seconds, help="sample the app's stacks for up to 60 seconds while measuring")
    running.add_argument("--sample-interval", type=positive_int, default=5, metavar="MS",
                         help="stack sampling interval in milliseconds (default: 5; 1 is more intrusive)")
    running.set_defaults(handler=run)
    commands.add_parser("_measure", parents=[running], add_help=False, help=argparse.SUPPRESS).set_defaults(handler=run_admitted)
    analyzing = commands.add_parser("analyze", help="recompute summaries for existing runs")
    analyzing.add_argument("runs", nargs="+", type=Path)
    analyzing.set_defaults(handler=analyze)
    profiling = commands.add_parser("profile", help="attribute a saved main-thread sample and inspect matching stacks")
    profiling.add_argument("label", help="run label or path to an existing run directory")
    profiling.add_argument("--focus", help="case-sensitive regular expression matching frame names or modules")
    profiling.add_argument("--depth", type=positive_int, default=5, help="maximum category/caller/callee tree depth (default: 5)")
    profiling.set_defaults(handler=profile)
    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
