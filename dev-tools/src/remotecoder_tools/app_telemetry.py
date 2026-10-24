import argparse
import datetime
import json
import os
import sys
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import app_telemetry_store as store
from .app_telemetry_summary import (
    ACTIVITY_FIELDS,
    ASSOCIATION_NOTE,
    CONTEXT_FIELDS,
    INTERVAL_KINDS,
    TIMELINE_FIELDS,
    activity,
    diagnostic,
    export_costs,
    iso,
    losses,
    metrickit_report,
    minute_counts,
    persistence_runs,
    sample_intervals,
    telemetry_runs,
    timeline,
)
from .diagnostics import _parse_since

sys.path.insert(0, str(store.ROOT / "scripts"))
from symbols import DEVICE_SUPPORT_ROOT, atos, symbol_files  # noqa: E402

SEGMENT_SLACK_MS = 3_600_000
METRICKIT_REPORT_DUE = datetime.timedelta(hours=36)


def add_parser(sub: argparse._SubParsersAction) -> None:
    parser = sub.add_parser(
        "app-telemetry",
        help="query the app logs and MetricKit reports uploaded to the gateway hosts",
        description=(
            "Reads the app-log stores on this host and the configured gateway hosts over SSH,\n"
            "indexes each segment once into a capped local cache, and prints JSON. Every result\n"
            "names the stores it read and the ones it could not. Run `stores` first to find the\n"
            "exact --device name."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    commands = parser.add_subparsers(dest="telemetry_cmd", required=True, metavar="command")

    def command(name: str, help_text: str, since: str | None) -> argparse.ArgumentParser:
        child = commands.add_parser(name, help=help_text)
        child.add_argument("--store", action="append", default=[],
                           help="store host to read: `local` or an SSH target (repeatable; default: "
                                "this host and the configured gateway hosts)")
        if since is not None:
            child.add_argument("--device", required=True, help="exact device directory, as `stores` lists it")
            child.add_argument("--since", default=since, help=f"30m / 6h / 3d, or an ISO timestamp (default: {since})")
            child.add_argument("--until", help="ISO timestamp or duration ago (default: now)")
        return child

    command("stores", "list devices, segment counts, bytes and coverage per store", None).set_defaults(
        func=cmd_stores)
    child = command("metrickit", "MetricKit daily reports: totals, normalized rates, signposts, flags", "14d")
    child.add_argument("--full", action="store_true", help="include subintervals, states and state entries")
    child.set_defaults(func=cmd_metrickit)
    child = command("diagnostics", "MetricKit crash, hang, CPU, memory and disk-write diagnostics", "14d")
    child.add_argument("--symbolicate", action="store_true",
                       help="name frames with atos from retained dSYMs that match the binary UUID")
    child.set_defaults(func=cmd_diagnostics)
    child = command("counts", "log record counts per minute or hour by subsystem, category or level", "24h")
    child.add_argument("--by", choices=["subsystem", "category", "level"], default="subsystem")
    child.add_argument("--bucket", choices=["minute", "hour"], default="hour")
    child.add_argument("--top", type=int, default=10, help="keys kept per bucket (default: 10)")
    child.set_defaults(func=cmd_counts)
    command("persistence", "disk writes per owner for each app run, from the cumulative counters", "24h").set_defaults(
        func=cmd_persistence)
    child = command("timeline", "process CPU, wakeups, memory and battery per stretch of unchanged state", "6h")
    child.add_argument("--by", action="append", choices=CONTEXT_FIELDS,
                       help=f"state fields that start a new stretch (repeatable; default: {' '.join(TIMELINE_FIELDS)})")
    child.set_defaults(func=cmd_timeline)
    child = command("activity", "process use summed per app state, with background and gaps kept apart", "24h")
    child.add_argument("--by", action="append", choices=CONTEXT_FIELDS,
                       help=f"state fields to group by (repeatable; default: {' '.join(ACTIVITY_FIELDS)})")
    child.set_defaults(func=cmd_activity)
    command("export-cost", "what the log export and the sampler cost on the device", "24h").set_defaults(
        func=cmd_export_cost)


def _window(args: argparse.Namespace) -> tuple[float, float]:
    since = _parse_since(args.since)
    until = _parse_since(args.until) if args.until else datetime.datetime.now(datetime.UTC).timestamp()
    return since, until


def _listings(args: argparse.Namespace) -> list[store.StoreListing]:
    hosts = args.store or store.configured_hosts()
    with ThreadPoolExecutor(max_workers=len(hosts)) as pool:
        return list(pool.map(store.list_store, hosts))


def _iso_ms(value: object) -> str | None:
    return iso(datetime.datetime.fromtimestamp(value / 1000, datetime.UTC)) if isinstance(value, int) else None


def _cap_state(listing: store.StoreListing) -> dict:
    marker = listing.retention or {}
    state = {"capEvictedThrough": cut} if (cut := _iso_ms(marker.get("evictedThroughMs"))) else {}
    if marker.get("met") is False:
        state["capUnmet"] = {"checkedAt": _iso_ms(marker.get("atMs")), "retainedBytes": marker.get("retainedBytes"),
                             "capBytes": marker.get("capBytes"), "unreadableEntries": marker.get("unreadableEntries")}
    return state


def _coverage(listings: list[store.StoreListing], failures: dict[str, str], reclaimed: store.Reclaimed) -> dict:
    return {
        "stores": [
            {"host": listing.host, "status": "failed" if listing.error or listing.host in failures else "read",
             "error": listing.error or failures.get(listing.host), **_cap_state(listing)}
            for listing in listings
        ],
        "index": {"bytes": reclaimed.index_bytes, "capBytes": reclaimed.cap_bytes,
                  "staleEntriesRemoved": reclaimed.stale_entries, "evictedForCap": reclaimed.evicted_entries},
    }


def _wanted(segment: store.Segment, since: float, until: float) -> bool:
    if segment.kind == "metrickit":
        return True
    stamp = segment.stamp_ms
    return stamp is not None and since * 1000 <= stamp <= until * 1000 + SEGMENT_SLACK_MS


def _select(args: argparse.Namespace, kind: str) -> tuple[list[tuple[store.Segment, dict]], dict]:
    since, until = _window(args)
    listings = _listings(args)
    wanted = [
        segment
        for listing in listings for segment in listing.segments or ()
        if segment.device == args.device and segment.kind == kind and _wanted(segment, since, until)
    ]
    entries, failures = store.indexed(sorted(wanted, key=lambda segment: segment.name))
    coverage = _coverage(listings, failures, store.reclaim_index(listings))
    coverage["window"] = {"since": iso(datetime.datetime.fromtimestamp(since, datetime.UTC)),
                          "until": iso(datetime.datetime.fromtimestamp(until, datetime.UTC))}
    unreadable = [{"host": segment.host, "segment": segment.name, "error": entry["unreadable"]}
                  for segment, entry in entries if "unreadable" in entry]
    coverage["segments"] = len(entries) - len(unreadable)
    if unreadable:
        coverage["unreadableSegments"] = unreadable
    return entries, coverage


def _emit(value: dict) -> int:
    json.dump(value, sys.stdout, indent=1)
    sys.stdout.write("\n")
    return 0


async def cmd_stores(args: argparse.Namespace) -> int:
    listings = _listings(args)
    reclaimed = store.reclaim_index(listings)
    devices: defaultdict[str, dict] = defaultdict(lambda: {"segments": 0, "metrickit": 0, "telemetry": 0, "bytes": 0,
                                                           "hosts": set(), "first": None, "latest": None})
    for listing in listings:
        for segment in listing.segments or ():
            device = devices[segment.device]
            device["segments"] += 1
            device["metrickit"] += segment.kind == "metrickit"
            device["telemetry"] += segment.kind == "telemetry"
            device["bytes"] += segment.size
            device["hosts"].add(segment.host)
            if (stamp := segment.stamp_ms) is not None:
                moment = iso(datetime.datetime.fromtimestamp(stamp / 1000, datetime.UTC))
                device["first"] = min(filter(None, (device["first"], moment)))
                device["latest"] = max(filter(None, (device["latest"], moment)))
    ordered = sorted(devices.items(), key=lambda item: item[1]["latest"] or "", reverse=True)
    return _emit({
        "coverage": _coverage(listings, {}, reclaimed),
        "devices": [{"device": name, **{key: sorted(value) if key == "hosts" else value for key, value in info.items()}}
                    for name, info in ordered],
    })


def _overlaps(report: dict, since: str, until: str) -> bool:
    start, seconds = report.get("coverageStart"), report.get("coverageSeconds")
    if isinstance(start, str) and isinstance(seconds, (int, float)):
        end = iso(datetime.datetime.fromisoformat(start) + datetime.timedelta(seconds=seconds))
        return start < until and end > since
    return since <= str(report.get("receivedAt") or "") <= until


def _window_iso(args: argparse.Namespace) -> tuple[str, str]:
    since, until = _window(args)
    return (iso(datetime.datetime.fromtimestamp(since, datetime.UTC)),
            iso(datetime.datetime.fromtimestamp(until, datetime.UTC)))


def _metrickit_records(entries: list[tuple[store.Segment, dict]], kind: str) -> list[tuple[store.Segment, dict]]:
    seen: set[str] = set()
    records = []
    for segment, entry in entries:
        for record in entry.get("metrickit", []):
            if record.get("kind") == kind and record.get("reportID") not in seen:
                seen.add(record.get("reportID"))
                records.append((segment, record))
    return records


async def cmd_metrickit(args: argparse.Namespace) -> int:
    entries, coverage = _select(args, "metrickit")
    since, until = _window_iso(args)
    reports = [report for segment, record in _metrickit_records(entries, "metrics")
               if _overlaps(report := metrickit_report(record, segment.host, segment.device), since, until)]
    if not args.full:
        for report in reports:
            report.pop("subintervals", None)
            report.pop("stateEntries", None)
            report.pop("states", None)
    reports.sort(key=lambda report: (report.get("coverageStart") or "", report.get("coverageSeconds") or 0))
    return _emit({"coverage": coverage, "reports": reports,
                  "uncovered": _uncovered(reports, since, until, datetime.datetime.now(datetime.UTC))})


def _uncovered(reports: list[dict], since: str, until: str, now: datetime.datetime) -> dict:
    start, end = datetime.datetime.fromisoformat(since), datetime.datetime.fromisoformat(until)
    spans = []
    for report in reports:
        begin, seconds = report.get("coverageStart"), report.get("coverageSeconds")
        if isinstance(begin, str) and isinstance(seconds, (int, float)):
            moment = datetime.datetime.fromisoformat(begin)
            spans.append((moment, moment + datetime.timedelta(seconds=seconds)))
    spans.sort()
    gaps, cursor = [], start
    for begin, finish in spans:
        if begin > cursor:
            gaps.append((cursor, min(begin, end)))
        cursor = max(cursor, finish)
        if cursor >= end:
            break
    if cursor < end:
        gaps.append((cursor, end))
    due = now - METRICKIT_REPORT_DUE
    missing, not_yet_due = [], []
    for begin, finish in gaps:
        if begin < due:
            missing.append({"from": iso(begin), "until": iso(min(finish, due))})
        if finish > due:
            not_yet_due.append({"from": iso(max(begin, due)), "until": iso(finish)})
    return {"missing": missing, "notYetDue": not_yet_due,
            "note": "Spans of the window no MetricKit report covers; a report normally arrives within a day."}


def _system_symbol_candidates(diagnostics: list[dict]) -> list[Path]:
    names = {frame["binary"] for item in diagnostics for frame in item["heaviestStack"] if frame.get("binary")}
    sources = {tuple(item["symbolSource"].values()) for item in diagnostics}
    candidates = []
    for device_type, version, build in sources:
        for root in (Path.home() / DEVICE_SUPPORT_ROOT).glob(f"{device_type} {version} ({build})/*/Symbols"):
            candidates += [Path(directory) / name for directory, _, files in os.walk(root)
                           for name in files if name in names]
    return candidates


def _symbolicate(diagnostics: list[dict]) -> dict:
    frames = [frame for item in diagnostics for frame in item["heaviestStack"]
              if isinstance(frame.get("address"), int) and isinstance(frame.get("offset"), int)]
    uuids = {frame["uuid"] for frame in frames}
    files = symbol_files([], _system_symbol_candidates(diagnostics))
    for uuid in uuids & files.keys():
        binary_frames = [frame for frame in frames if frame["uuid"] == uuid]
        base = Counter(frame["address"] - frame["offset"] for frame in binary_frames).most_common(1)[0][0]
        names = atos(files[uuid], base, [base + frame["offset"] for frame in binary_frames])
        for frame, symbols in zip(binary_frames, names, strict=True):
            frame["symbols"] = list(symbols)
    missing = sorted({frame["binary"] or frame["uuid"] for frame in frames if frame["uuid"] not in files})
    return {"symbolicatedBinaries": len(uuids & files.keys()), "binariesWithoutSymbols": missing}


async def cmd_diagnostics(args: argparse.Namespace) -> int:
    entries, coverage = _select(args, "metrickit")
    since, until = _window_iso(args)
    items = [item for segment, record in _metrickit_records(entries, "diagnostic")
             if _overlaps(item := diagnostic(record, segment.host, segment.device), since, until)]
    items.sort(key=lambda item: item.get("coverageStart") or item.get("receivedAt") or "")
    result: dict = {"coverage": coverage, "diagnostics": items}
    if args.symbolicate:
        result["symbolication"] = _symbolicate(items)
    return _emit(result)


async def cmd_counts(args: argparse.Namespace) -> int:
    entries, coverage = _select(args, "logs")
    since, until = _window_iso(args)
    minutes = [(minute, counts) for _, entry in entries for minute, counts in entry.get("minutes", {}).items()]
    result = minute_counts(minutes, since, until, args.by, args.bucket)
    result["buckets"] = {name: dict(Counter(counts).most_common(args.top)) for name, counts in result["buckets"].items()}
    total = sum(result["totals"].values())
    result["share"] = {key: round(count / total, 4) for key, count in result["totals"].items()} if total else {}
    return _emit({"coverage": coverage, "records": total, **result})


async def cmd_persistence(args: argparse.Namespace) -> int:
    entries, coverage = _select(args, "logs")
    since, until = _window_iso(args)
    snapshots = [snapshot for _, entry in entries for snapshot in entry.get("persistence", [])
                 if since <= snapshot["ts"] <= until]
    runs = persistence_runs(snapshots)
    totals: defaultdict[str, Counter] = defaultdict(Counter)
    for run in runs:
        for owner, counters in run["owners"].items():
            totals[owner].update(counters)
    return _emit({
        "coverage": coverage,
        "note": "Counters are cumulative per app run. A run whose start precedes the window counts from its "
                "first snapshot in the window; runs are split where any counter decreases.",
        "totals": {owner: {name: round(value, 3) for name, value in counters.items()}
                   for owner, counters in sorted(totals.items())},
        "runs": runs,
    })


def _telemetry(args: argparse.Namespace) -> tuple[list[dict], dict]:
    entries, coverage = _select(args, "telemetry")
    since, until = _window_iso(args)
    records = [record for _, entry in entries for record in entry.get("telemetry", [])
               if record.get("recordType") == "run" or since <= str(record.get("ts", "")) <= until]
    runs = telemetry_runs(records)
    coverage["runs"] = []
    for run in runs:
        if not run["records"]:
            continue
        samples = [record["ts"] for record in run["records"] if record.get("recordType") == "sample"]
        coverage["runs"].append({
            "runID": run["runID"], **(run["header"] or {"header": "not read"}),
            "records": len(run["records"]), "missingRecords": run["missingRecords"],
            "sampledFrom": samples[0] if samples else None, "sampledUntil": samples[-1] if samples else None,
        })
    coverage["losses"] = losses(record for run in runs for record in run["records"])
    return runs, coverage


async def cmd_timeline(args: argparse.Namespace) -> int:
    runs, coverage = _telemetry(args)
    fields = args.by or TIMELINE_FIELDS
    return _emit({
        "coverage": coverage, "note": ASSOCIATION_NOTE, "kinds": INTERVAL_KINDS,
        "runs": [{"runID": run["runID"], "stretches": timeline(sample_intervals(run["records"]), fields)}
                 for run in runs if run["records"]],
    })


async def cmd_activity(args: argparse.Namespace) -> int:
    runs, coverage = _telemetry(args)
    intervals = [interval for run in runs for interval in sample_intervals(run["records"])]
    return _emit({"coverage": coverage, "note": ASSOCIATION_NOTE, "kinds": INTERVAL_KINDS,
                  "states": activity(intervals, args.by or ACTIVITY_FIELDS)})


async def cmd_export_cost(args: argparse.Namespace) -> int:
    runs, coverage = _telemetry(args)
    return _emit({"coverage": coverage, **export_costs(runs)})
