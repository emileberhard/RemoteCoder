import argparse
import asyncio
import datetime
import json
import sys
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

from . import app_telemetry_store as store
from .app_telemetry_analysis import (
    MIN_MEASURED_MINUTES,
    aggregate_states,
    compare,
    group_diagnostics,
)
from .app_telemetry_builds import (
    Attribution,
    BuildSelectionError,
    RunSpan,
    attribute_window,
    parse_instant,
    run_spans,
    select_build,
    span_extent,
)
from .app_telemetry_summary import (
    ACTIVITY_FIELDS,
    ASSOCIATION_NOTE,
    CONTEXT_FIELDS,
    INTERVAL_KINDS,
    TIMELINE_FIELDS,
    activity,
    call_stack_tree,
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
from .app_telemetry_symbols import Capture, annotate_heaviest, profile, symbolicate
from .diagnostics import _parse_since

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
    command("states", "MetricKit state entries per domain, label, attributed build and device model, with "
            "diagnostics grouped by the states active before them", "14d").set_defaults(func=cmd_states)
    child = command("compare", "what changed between two builds, per device model and app state", "14d")
    child.add_argument("--before", required=True, help="build number, version or source commit prefix")
    child.add_argument("--after", required=True, help="build number, version or source commit prefix")
    child.add_argument("--by", action="append", choices=CONTEXT_FIELDS,
                       help=f"state fields to compare by (repeatable; default: {' '.join(ACTIVITY_FIELDS)})")
    child.add_argument("--min-minutes", type=float, default=MIN_MEASURED_MINUTES,
                       help=f"measured minutes each side needs per device model (default: {MIN_MEASURED_MINUTES:g})")
    child.set_defaults(func=cmd_compare)
    child = command("diagnostics", "MetricKit crash, hang, CPU, memory and disk-write diagnostics", "14d")
    child.add_argument("--symbolicate", action="store_true",
                       help="name every frame of every call stack tree with atos from retained dSYMs and "
                            "DeviceSupport symbols that match the binary UUID")
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


def _select(args: argparse.Namespace, kind: str, listings: list[store.StoreListing] | None = None,
            window: tuple[float, float] | None = None) -> tuple[list[tuple[store.Segment, dict]], dict]:
    since, until = window or _window(args)
    listings = _listings(args) if listings is None else listings
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


def _emit(value: dict, code: int = 0) -> int:
    json.dump(value, sys.stdout, indent=1)
    sys.stdout.write("\n")
    return code


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


def _iso_window(window: tuple[float, float]) -> tuple[str, str]:
    return (iso(datetime.datetime.fromtimestamp(window[0], datetime.UTC)),
            iso(datetime.datetime.fromtimestamp(window[1], datetime.UTC)))


def _window_iso(args: argparse.Namespace) -> tuple[str, str]:
    return _iso_window(_window(args))


def _metrickit_records(entries: list[tuple[store.Segment, dict]], kind: str) -> list[tuple[store.Segment, dict]]:
    seen: set[str] = set()
    records = []
    for segment, entry in entries:
        for record in entry.get("metrickit", []):
            if record.get("kind") == kind and record.get("reportID") not in seen:
                seen.add(record.get("reportID"))
                records.append((segment, record))
    return records


def _attributed_runs(args: argparse.Namespace, listings: list[store.StoreListing],
                     windows: list[tuple[str | None, object]]) -> tuple[list[dict], list[RunSpan], dict]:
    since, until = _window(args)
    for start, seconds in windows:
        if isinstance(start, str) and isinstance(seconds, (int, float)):
            begin = parse_instant(start)
            since = min(since, begin.timestamp())
            until = max(until, (begin + datetime.timedelta(seconds=seconds)).timestamp())
    runs, coverage = _telemetry(args, listings, (since, until))
    spans = run_spans(runs)
    return runs, spans, {
        "note": "Builds come from the run headers of this device: a run lasts from its startedAt to its last record.",
        "window": coverage["window"], **span_extent(spans), "losses": coverage["losses"],
        **({"unreadableSegments": coverage["unreadableSegments"]} if "unreadableSegments" in coverage else {}),
    }


def _metrickit_window(args: argparse.Namespace, listings: list[store.StoreListing]
                      ) -> tuple[dict, list[tuple[dict, dict]], list[tuple[dict, dict]]]:
    entries, coverage = _select(args, "metrickit", listings)
    since, until = _window_iso(args)
    metrics = [(summary, record["report"]) for segment, record in _metrickit_records(entries, "metrics")
               if _overlaps(summary := metrickit_report(record, segment.host, segment.device), since, until)]
    diagnostics = [(item, record) for segment, record in _metrickit_records(entries, "diagnostic")
                   if _overlaps(item := diagnostic(record, segment.host, segment.device), since, until)]
    diagnostics.sort(key=lambda pair: pair[0].get("coverageStart") or pair[0].get("receivedAt") or "")
    return coverage, metrics, diagnostics


def _coverages(pairs: list[tuple[dict, dict]]) -> list[tuple[str | None, object]]:
    return [(summary.get("coverageStart"), summary.get("coverageSeconds")) for summary, _ in pairs]


def _attributed(spans: list[RunSpan], report: dict) -> Attribution:
    return attribute_window(spans, report.get("coverageStart"), report.get("coverageSeconds"))


async def cmd_metrickit(args: argparse.Namespace) -> int:
    listings = _listings(args)
    coverage, metrics, _ = _metrickit_window(args, listings)
    _, spans, builds = _attributed_runs(args, listings, _coverages(metrics))
    reports = [summary for summary, _ in metrics]
    for report in reports:
        attribution = _attributed(spans, report)
        report["attributedBuild"] = attribution.as_json()
        if "subintervals" in report:
            report["subintervals"]["attributedBuild"] = attribution.status
            report["subintervals"]["buildNote"] = ("Entries carry no start time, so each one has the build status of "
                                                   "the whole report coverage.")
    if not args.full:
        for report in reports:
            report.pop("subintervals", None)
            report.pop("stateEntries", None)
            report.pop("states", None)
    since, until = _window_iso(args)
    reports.sort(key=lambda report: (report.get("coverageStart") or "", report.get("coverageSeconds") or 0))
    return _emit({"coverage": coverage, "builds": builds, "reports": reports,
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


async def cmd_diagnostics(args: argparse.Namespace) -> int:
    listings = _listings(args)
    coverage, _, pairs = _metrickit_window(args, listings)
    _, spans, builds = _attributed_runs(args, listings, _coverages(pairs))
    for item, _ in pairs:
        item["attributedBuild"] = _attributed(spans, item).as_json()
    items = [item for item, _ in pairs]
    result: dict = {"coverage": coverage, "builds": builds, "diagnostics": items}
    if args.symbolicate:
        captures = [Capture(call_stack_tree(record), item["attributedBuild"]["label"], item["symbolSource"])
                    for item, record in pairs]
        symbols = await asyncio.to_thread(symbolicate, captures)
        for (item, _), capture in zip(pairs, captures, strict=True):
            annotate_heaviest(item["heaviestStack"], capture.tree, symbols)
            item["profile"] = profile(capture.tree, symbols)
        result["symbolication"] = symbols.summary()
    return _emit(result)


async def cmd_states(args: argparse.Namespace) -> int:
    listings = _listings(args)
    coverage, metrics, pairs = _metrickit_window(args, listings)
    _, spans, builds = _attributed_runs(args, listings, _coverages(metrics) + _coverages(pairs))
    attributed = [(summary, report, _attributed(spans, summary)) for summary, report in metrics]
    items = [item for item, _ in pairs]
    for item in items:
        item["attributedBuild"] = _attributed(spans, item).as_json()
    return _emit({"coverage": coverage, "builds": builds, **aggregate_states(attributed),
                  "diagnostics": {"total": len(items), "byActiveStates": group_diagnostics(items)}})


async def cmd_compare(args: argparse.Namespace) -> int:
    listings = _listings(args)
    coverage, metrics, _ = _metrickit_window(args, listings)
    runs, spans, builds = _attributed_runs(args, listings, _coverages(metrics))
    since, until = _window_iso(args)
    start, end = parse_instant(since), parse_instant(until)
    present = [span.build for span in spans if span.end >= start and span.start <= end]
    try:
        before, after = select_build(present, args.before), select_build(present, args.after)
    except BuildSelectionError as error:
        return _emit({"error": str(error), "builds": [build.label for build in error.candidates]}, 2)
    if before == after:
        return _emit({"error": "--before and --after name the same build", "builds": [before.label]}, 2)
    attributed = [(summary, report, _attributed(spans, summary)) for summary, report in metrics]
    result = compare(runs, {span.run_id: span for span in spans}, attributed, before, after,
                     tuple(args.by or ACTIVITY_FIELDS), since, until, args.min_minutes)
    result["reportsByAttribution"] = dict(Counter(attribution.status for _, _, attribution in attributed))
    return _emit({"coverage": coverage, "builds": builds, **result}, 3 if result["refused"] else 0)


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


def _telemetry(args: argparse.Namespace, listings: list[store.StoreListing] | None = None,
               window: tuple[float, float] | None = None) -> tuple[list[dict], dict]:
    entries, coverage = _select(args, "telemetry", listings, window)
    since, until = _iso_window(window or _window(args))
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
