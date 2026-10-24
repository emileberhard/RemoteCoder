import datetime
import json
import re
from collections import Counter, defaultdict
from collections.abc import Iterable

REFERENCE_DATE = datetime.datetime(2001, 1, 1, tzinfo=datetime.UTC)
TELEMETRY_RECORD_TYPES = frozenset({"run", "sample", "context", "export", "counts", "loss"})
PERSISTENCE = re.compile(
    r"persistence owner=(?P<owner>\w+) writes=(?P<writes>\d+) bytes=(?P<bytes>\d+) skipped=(?P<skipped>\d+) "
    r"failures=(?P<failures>\d+) writesWithoutByteCount=(?P<unsized>\d+) milliseconds=(?P<milliseconds>[\d.]+)"
)
ENERGY = re.compile(r"Energy policy lowPower=(?P<low>true|false) thermalState=(?P<thermal>\d+) conserves=(?P<conserves>true|false)")
PERSISTENCE_COUNTERS = ("writes", "bytes", "skipped", "failures", "unsized", "milliseconds")
NORMALIZED_NOTE = (
    "Daily totals divided by foreground minutes. The totals include background work, "
    "so this is a normalization, not measured foreground utilization."
)
SUBINTERVAL_NOTE = "Subintervals in report order. MetricKit gives no start times, so their clock placement is unknown."


def summarize_segment(lines: Iterable[bytes]) -> dict:
    minutes: defaultdict[str, Counter] = defaultdict(Counter)
    persistence: list[dict] = []
    energy: list[dict] = []
    metrickit: list[dict] = []
    telemetry: list[dict] = []
    records = 0
    first = last = None
    for line in lines:
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict):
            continue
        record_type = record.get("recordType")
        if record_type == "metrickit":
            metrickit.append(record)
            continue
        if record_type in TELEMETRY_RECORD_TYPES:
            telemetry.append(record)
            continue
        stamp = record.get("ts")
        if record_type is not None or not isinstance(stamp, str):
            continue
        records += 1
        first = stamp if first is None or stamp < first else first
        last = stamp if last is None or stamp > last else last
        key = f"{record.get('subsystem', '')}\t{record.get('category', '')}\t{record.get('level', '')}"
        minutes[stamp[:16]][key] += 1
        if record.get("subsystem") != "RemoteCoder":
            continue
        message = record.get("message", "")
        if record.get("category") == "PersistenceMetrics" and (match := PERSISTENCE.fullmatch(message)):
            persistence.append({"ts": stamp, "owner": match["owner"],
                                **{name: float(match[name]) if name == "milliseconds" else int(match[name])
                                   for name in PERSISTENCE_COUNTERS}})
        elif record.get("category") == "Energy" and (match := ENERGY.fullmatch(message)):
            energy.append({"ts": stamp, "lowPower": match["low"] == "true",
                           "thermalState": int(match["thermal"]), "conservesEnergy": match["conserves"] == "true"})
    return {
        "records": records, "first": first, "last": last,
        "minutes": {minute: dict(counts) for minute, counts in sorted(minutes.items())},
        "persistence": persistence, "energy": energy, "metrickit": metrickit, "telemetry": telemetry,
    }


def reference_date(seconds: float) -> str:
    return iso(REFERENCE_DATE + datetime.timedelta(seconds=seconds))


def iso(moment: datetime.datetime) -> str:
    return moment.astimezone(datetime.UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def measurement(value: object) -> object:
    if isinstance(value, dict) and set(value) == {"unit", "value"}:
        return {"value": value["value"], "unit": value["unit"]}
    return value


def histogram(buckets: list[dict]) -> dict:
    total = sum(bucket.get("count", 0) for bucket in buckets)
    summary: dict = {"count": total}
    if not buckets:
        return summary
    unit = buckets[0].get("upperBound", {}).get("unit")
    halfway = total / 2
    seen = 0
    for bucket in buckets:
        seen += bucket.get("count", 0)
        if seen >= halfway:
            summary["medianUpperBound"] = bucket.get("upperBound", {}).get("value")
            break
    summary["maxUpperBound"] = buckets[-1].get("upperBound", {}).get("value")
    summary["unit"] = unit
    return summary


def metric_values(values: list[dict]) -> dict:
    flattened: dict = {}
    for item in values:
        for name, payload in item.items():
            key = name.removesuffix("Metric")
            if not isinstance(payload, dict):
                flattened[key] = payload
            elif set(payload) == {"value"}:
                flattened[key] = measurement(payload["value"])
            elif "histogram" in payload and isinstance(payload["histogram"], dict):
                flattened[key] = histogram(payload["histogram"].get("buckets", []))
            elif name == "signpostIntervalMetric":
                flattened.setdefault("signposts", []).append(signpost(payload))
            else:
                flattened[key] = {field: measurement(value) for field, value in payload.items()}
    return flattened


def signpost(payload: dict) -> dict:
    summary = {field: measurement(value) for field, value in payload.items() if field != "signpostDuration"}
    if isinstance(duration := payload.get("signpostDuration"), dict):
        summary["duration"] = histogram(duration.get("buckets", []))
    return summary


def state(entry: dict) -> dict:
    metadata = {
        key: next(iter(value.values())) if isinstance(value, dict) and len(value) == 1 else value
        for key, value in (entry.get("stableMetadata") or {}).items()
    }
    return {"domain": entry.get("domain"), "label": entry.get("label"), "metadata": metadata,
            "duration": measurement(entry.get("duration"))}


def scalar(value: object) -> float | None:
    if isinstance(value, dict) and isinstance(value.get("value"), (int, float)):
        return float(value["value"])
    return None


def metrickit_report(record: dict, host: str, device: str) -> dict:
    report = record.get("report") or {}
    environment = report.get("environment") or {}
    os_version = environment.get("osVersion") or {}
    coverage = record.get("coverage") or {}
    summary = {
        "host": host, "device": device, "kind": record.get("kind"), "reportID": record.get("reportID"),
        "receivedAt": record.get("ts"),
        "coverageStart": reference_date(coverage["start"]) if isinstance(coverage.get("start"), (int, float)) else None,
        "coverageSeconds": coverage.get("duration"),
        "appVersion": environment.get("latestApplicationVersion") or environment.get("applicationVersion"),
        "build": environment.get("applicationBuildVersion"),
        "deviceType": environment.get("deviceType"),
        "os": f"{os_version.get('number')} ({os_version.get('buildNumber')})" if os_version else None,
        "flags": {field: environment[field] for field in (
            "hasExceededStateLimit", "includesMultipleApplicationVersions", "lowPowerModeEnabled", "isTestFlightApp",
        ) if field in environment},
    }
    if record.get("kind") != "metrics":
        return summary
    entries = report.get("intervalEntries") or []
    whole, subintervals = (entries[0], entries[1:]) if entries else ({}, [])
    totals = metric_values(whole.get("values", []))
    summary["totals"] = totals
    summary["states"] = [state(entry) for entry in whole.get("states", [])]
    foreground = scalar(totals.get("totalForegroundTime"))
    if foreground:
        rates = {"cpuTimeSeconds": "cpuTime", "gpuTimeSeconds": "gpuTime", "logicalDiskWritesMB": "logicalDiskWrites"}
        summary["perForegroundMinute"] = {
            "note": NORMALIZED_NOTE,
            **{label: round(value / (foreground / 60), 2) for label, name in rates.items()
               if (value := scalar(totals.get(name))) is not None},
        }
    summary["subintervals"] = {
        "note": SUBINTERVAL_NOTE,
        "entries": [{"seconds": scalar(entry.get("duration")), **metric_values(entry.get("values", [])),
                     "states": [state(item) for item in entry.get("states", [])]} for entry in subintervals],
    }
    summary["stateEntries"] = [
        {**state(entry.get("state") or {}), **metric_values(entry.get("values", []))}
        for entry in report.get("stateEntries") or []
    ]
    return summary


def diagnostic_kind(report: dict) -> str | None:
    return next((key for key in report if key.endswith("Diagnostic")), None)


def heaviest_path(call_stack_tree: dict) -> list[dict]:
    threads = call_stack_tree.get("callStackThreads", [])
    if call_stack_tree.get("callStackPerThread"):
        threads = [thread for thread in threads if thread.get("threadAttributed")] or threads
    frames = [frame for thread in threads for frame in thread.get("rootFrames", [])]
    path = []
    while frames:
        frame = max(frames, key=lambda candidate: candidate.get("sampleCount", 0))
        path.append(frame)
        frames = frame.get("subFrames") or []
    return path


def diagnostic(record: dict, host: str, device: str) -> dict:
    report = record.get("report") or {}
    kind = diagnostic_kind(report)
    body = dict(report.get(kind) or {}) if kind else {}
    tree = body.pop("callStackTree", None) or {}
    environment = report.get("environment") or {}
    binaries = {binary.get("uuid"): binary.get("name") for binary in tree.get("binaryInfo", [])}
    return {
        **metrickit_report(record, host, device),
        "type": kind.removesuffix("Diagnostic") if kind else None,
        "pid": environment.get("pid"),
        "symbolSource": {"deviceType": environment.get("deviceType"),
                         "osVersion": (environment.get("osVersion") or {}).get("number"),
                         "osBuild": (environment.get("osVersion") or {}).get("buildNumber")},
        "details": {field: measurement(value) for field, value in body.items()},
        "signpostData": environment.get("signpostData") or [],
        "activeStates": environment.get("states") or [],
        "stackOrder": "innermostFirst" if tree.get("callStackPerThread") else "outermostFirst",
        "heaviestStack": [
            {"binary": binaries.get(frame.get("binaryUUID")), "uuid": frame.get("binaryUUID"),
             "offset": frame.get("offsetIntoBinaryTextSegment"), "address": frame.get("address"),
             "samples": frame.get("sampleCount")}
            for frame in heaviest_path(tree)
        ],
    }


def minute_counts(minutes: Iterable[tuple[str, dict]], since: str, until: str, by: str, bucket: str) -> dict:
    width = 16 if bucket == "minute" else 13
    fields = {"subsystem": 1, "category": 2, "level": 3}[by]
    totals: Counter = Counter()
    buckets: defaultdict[str, Counter] = defaultdict(Counter)
    for minute, counts in minutes:
        if not since[:16] <= minute <= until[:16]:
            continue
        for key, count in counts.items():
            label = "/".join(key.split("\t")[:fields])
            totals[label] += count
            buckets[minute[:width]][label] += count
    return {"totals": dict(totals.most_common()), "buckets": {name: dict(counts.most_common())
                                                               for name, counts in sorted(buckets.items())}}


def persistence_runs(snapshots: list[dict]) -> list[dict]:
    reports: defaultdict[str, list[dict]] = defaultdict(list)
    for snapshot in snapshots:
        reports[snapshot["ts"]].append(snapshot)
    runs: list[dict] = []
    current: dict | None = None
    for stamp, report in sorted(reports.items()):
        if current is not None and any(
            (previous := current["last"].get(snapshot["owner"])) is not None
            and any(snapshot[name] < previous[name] for name in PERSISTENCE_COUNTERS)
            for snapshot in report
        ):
            current = None
        if current is None:
            current = {"started": bool(runs), "first": {}, "last": {}, "from": stamp}
            runs.append(current)
        for snapshot in report:
            current["first"].setdefault(snapshot["owner"], snapshot)
            current["last"][snapshot["owner"]] = snapshot
        current["to"] = stamp
    return [
        {
            "from": run["from"], "to": run["to"], "startObserved": run["started"],
            "owners": {
                owner: {
                    name: round(last[name] - (0 if run["started"] else run["first"][owner][name]), 3)
                    for name in PERSISTENCE_COUNTERS
                }
                for owner, last in sorted(run["last"].items())
            },
        }
        for run in runs
    ]
