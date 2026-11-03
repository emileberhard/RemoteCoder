import math
import statistics
from collections import Counter, defaultdict

from .app_telemetry_analysis import MIN_MEASURED_MINUTES
from .app_telemetry_builds import Build, run_build
from .app_telemetry_summary import sample_intervals

MIB = 1024 * 1024
LOW_WORKLOAD_MAX_AVERAGE_TURNS = 2
STALL_THRESHOLDS_MS = ("100", "250")
RELEASES_NOTE = (
    "One row per build from this device's sampler. Rates come from measured intervals while the app was active; "
    "mixed, gap, background and incomplete intervals are excluded. Each group names the minutes it covers, and "
    "lowData marks a build with fewer active minutes than a comparison needs. null means not measured, never zero: "
    "builds before the responsiveness and workload fields report those groups with 0 minutes. "
    "Running turns are the turns the app tracks across its loaded hosts; streamed counters count routed text "
    "notifications, including replays. chat.lowWorkload keeps intervals whose time-averaged running turns stay at "
    "most maxAverageRunningTurns. mainThread.blockedPercent is main run loop busy time minus main-thread CPU. "
    "A drawer visit is a contiguous drawer stretch with at least one active measured interval. History-open "
    "percentiles are the upper bound of the bin holding that share of opens. intervalPeakFootprintMiB takes each "
    "interval's larger endpoint footprint; p95 is nearest-rank."
)


def _minutes(intervals: list[dict]) -> float:
    return round(sum(interval["seconds"] for interval in intervals) / 60, 1)


def _rate(intervals: list[dict], key: str, scale: float = 1.0) -> float | None:
    seconds = sum(interval["seconds"] for interval in intervals)
    return round(sum(interval[key] for interval in intervals) / seconds * scale, 2) if seconds else None


def _nearest_rank(values: list[float], share: float) -> float:
    return sorted(values)[math.ceil(share * len(values)) - 1]


def _cpu(intervals: list[dict]) -> dict:
    return {"minutes": _minutes(intervals), "cpuPercent": _rate(intervals, "cpuSeconds", 100)}


def _drawer_visits(intervals: list[dict]) -> int:
    visits = 0
    counted = False
    for interval in intervals:
        if interval["context"].get("surface") != "drawer":
            counted = False
        elif not counted and _active_measured(interval):
            visits += 1
            counted = True
    return visits


def _average_turns(interval: dict) -> float | None:
    turn_seconds = interval.get("runningTurnSeconds")
    return turn_seconds / interval["seconds"] if turn_seconds is not None else None


def _workload(active: list[dict]) -> dict:
    known = [interval for interval in active
             if interval.get("runningTurnSeconds") is not None and interval.get("streamedBytes") is not None]
    seconds = sum(interval["seconds"] for interval in known)
    return {
        "minutes": _minutes(known),
        "averageRunningTurns": round(sum(interval["runningTurnSeconds"] for interval in known) / seconds, 2)
        if seconds else None,
        "streamedDeltasPerMinute": _rate(known, "streamedDeltas", 60),
        "streamedKBPerMinute": _rate(known, "streamedBytes", 60 / 1000),
    }


def _main_thread(active: list[dict]) -> dict:
    known = [interval for interval in active
             if interval.get("mainThreadCpuSeconds") is not None and interval.get("mainRunLoop") is not None]
    seconds = sum(interval["seconds"] for interval in known)
    if not seconds:
        return {"minutes": 0, "cpuPercent": None, "busyPercent": None, "blockedPercent": None,
                "stallsPerActiveHour": {f"atLeast{bound}Ms": None for bound in STALL_THRESHOLDS_MS},
                "hangSecondsPerActiveHour": None}
    cpu = sum(interval["mainThreadCpuSeconds"] for interval in known) / seconds * 100
    busy = sum(interval["mainRunLoop"]["busySeconds"] for interval in known) / seconds * 100
    hours = seconds / 3600
    return {
        "minutes": _minutes(known),
        "cpuPercent": round(cpu, 2),
        "busyPercent": round(busy, 2),
        "blockedPercent": round(busy - cpu, 2),
        "stallsPerActiveHour": {
            f"atLeast{bound}Ms": round(sum(interval["mainRunLoop"]["busyPeriodsAtLeastMs"].get(bound, 0)
                                           for interval in known) / hours, 1)
            for bound in STALL_THRESHOLDS_MS},
        "hangSecondsPerActiveHour": round(sum(interval["mainRunLoop"]["hangSeconds"] for interval in known) / hours, 2),
    }


def _bin_percentile(within: Counter, count: int, share: float) -> int | str | None:
    if not count:
        return None
    bounds = sorted(within, key=int)
    for bound in bounds:
        if within[bound] >= share * count:
            return int(bound)
    return f">{bounds[-1]}" if bounds else None


def _history_opens(runs: list[list[dict]]) -> dict:
    known = [interval["historyOpens"] for run in runs for interval in run if interval.get("historyOpens") is not None]
    if not known:
        return {"intervals": 0, "completed": None, "abandoned": None, "p50Ms": None, "p90Ms": None}
    completed = sum(opens["completed"] for opens in known)
    within: Counter = Counter()
    for opens in known:
        within.update(opens["completedWithinMs"])
    return {
        "intervals": len(known),
        "completed": completed,
        "abandoned": sum(opens["abandoned"] for opens in known),
        "p50Ms": _bin_percentile(within, completed, 0.5),
        "p90Ms": _bin_percentile(within, completed, 0.9),
    }


def _active_measured(interval: dict) -> bool:
    return interval["kind"] == "measured" and interval["context"].get("scene") == "active"


def _row(build: Build, runs: list[list[dict]]) -> dict:
    active = [interval for run in runs for interval in run if _active_measured(interval)]
    chat = [interval for interval in active if interval["context"].get("surface") == "chat"]
    drawer = [interval for interval in active if interval["context"].get("surface") == "drawer"]
    visits = sum(_drawer_visits(run) for run in runs)
    footprints = [interval["footprintBytes"] / MIB for interval in active if interval["footprintBytes"]]
    disk: Counter = Counter()
    for interval in active:
        disk.update(interval["persistenceBytes"])
    hours = sum(interval["seconds"] for interval in active) / 3600
    starts = [interval["start"] for run in runs for interval in run]
    ends = [interval["end"] for run in runs for interval in run]
    return {
        "build": build.as_json(),
        "runs": len(runs),
        "first": min(starts, default=None),
        "last": max(ends, default=None),
        "activeMinutes": _minutes(active),
        "lowData": _minutes(active) < MIN_MEASURED_MINUTES,
        "chat": {
            **_cpu(chat),
            "interruptWakeupsPerSecond": _rate(chat, "interruptWakeups"),
            "turnVisible": _cpu([interval for interval in chat if interval["context"].get("turnRunningVisible")]),
            "noTurnVisible": _cpu([interval for interval in chat
                                   if interval["context"].get("turnRunningVisible") is False]),
            "lowWorkload": {"maxAverageRunningTurns": LOW_WORKLOAD_MAX_AVERAGE_TURNS, **_cpu([
                interval for interval in chat
                if (turns := _average_turns(interval)) is not None and turns <= LOW_WORKLOAD_MAX_AVERAGE_TURNS])},
        },
        "workload": _workload(active),
        "mainThread": _main_thread(active),
        "historyOpens": _history_opens(runs),
        "drawer": {
            **_cpu(drawer),
            "visits": visits,
            "cpuSecondsPerVisit": round(sum(interval["cpuSeconds"] for interval in drawer) / visits, 3)
            if visits else None,
        },
        "intervalPeakFootprintMiB": {
            "intervals": len(footprints),
            "median": round(statistics.median(footprints), 1) if footprints else None,
            "p95": round(_nearest_rank(footprints, 0.95), 1) if footprints else None,
        },
        "diskMBPerActiveHour": {
            "total": round(sum(disk.values()) / 1e6 / hours, 1) if hours else None,
            "byOwner": {owner: round(value / 1e6 / hours, 1) for owner, value in sorted(disk.items()) if value}
            if hours else {},
        },
    }


def release_rows(runs: list[dict]) -> list[dict]:
    by_build: defaultdict[Build, list[list[dict]]] = defaultdict(list)
    for run in runs:
        if (build := run_build(run["header"])) is not None and (intervals := sample_intervals(run["records"])):
            by_build[build].append(intervals)
    rows = [_row(build, runs) for build, runs in by_build.items()]
    return sorted(rows, key=lambda row: row["first"] or "")
