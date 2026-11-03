from collections import Counter, defaultdict

from .app_telemetry_analysis import MIN_MEASURED_MINUTES
from .app_telemetry_builds import Build, run_build
from .app_telemetry_summary import sample_intervals

MIB = 1024 * 1024
RELEASES_NOTE = (
    "One row per build from this device's sampler. Rates come from measured intervals while the app was active; "
    "mixed, gap, background and incomplete intervals are excluded. Each group names the minutes it covers, and "
    "lowData marks a build with fewer active minutes than a comparison needs. null means not measured, never zero."
)


def _minutes(intervals: list[dict]) -> float:
    return round(sum(interval["seconds"] for interval in intervals) / 60, 1)


def _rate(intervals: list[dict], key: str, scale: float = 1.0) -> float | None:
    seconds = sum(interval["seconds"] for interval in intervals)
    return round(sum(interval[key] for interval in intervals) / seconds * scale, 2) if seconds else None


def _percentile(values: list[float], share: float) -> float | None:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(share * len(ordered)))] if ordered else None


def _cpu(intervals: list[dict]) -> dict:
    return {"minutes": _minutes(intervals), "cpuPercent": _rate(intervals, "cpuSeconds", 100)}


def _drawer_visits(intervals: list[dict]) -> int:
    visits = 0
    previous_surface = None
    for interval in intervals:
        surface = interval["context"].get("surface")
        if surface == "drawer" and previous_surface != "drawer" and _active_measured(interval):
            visits += 1
        previous_surface = surface
    return visits


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
        },
        "drawer": {
            **_cpu(drawer),
            "visits": visits,
            "cpuSecondsPerVisit": round(sum(interval["cpuSeconds"] for interval in drawer) / visits, 3)
            if visits else None,
        },
        "footprintMiB": {
            "intervals": len(footprints),
            "median": round(median, 1) if (median := _percentile(footprints, 0.5)) is not None else None,
            "p95": round(p95, 1) if (p95 := _percentile(footprints, 0.95)) is not None else None,
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
