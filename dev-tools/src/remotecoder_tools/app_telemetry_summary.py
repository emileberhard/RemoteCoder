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
REPORTED_BUILD_NOTE = (
    "The build installed when MetricKit delivered the report, not necessarily the one that ran in its coverage; "
    "attributedBuild comes from the run headers."
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
        "reportedBuild": {
            "appVersion": environment.get("latestApplicationVersion") or environment.get("applicationVersion"),
            "build": environment.get("applicationBuildVersion"),
            "note": REPORTED_BUILD_NOTE,
        },
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


def tree_roots(call_stack_tree: dict) -> list[dict]:
    threads = call_stack_tree.get("callStackThreads", [])
    if call_stack_tree.get("callStackPerThread"):
        threads = [thread for thread in threads if thread.get("threadAttributed")] or threads
    return [frame for thread in threads for frame in thread.get("rootFrames", [])]


def call_stack_tree(record: dict) -> dict:
    report = record.get("report") or {}
    kind = diagnostic_kind(report)
    return (report.get(kind) or {}).get("callStackTree") or {} if kind else {}


def heaviest_path(call_stack_tree: dict) -> list[dict]:
    frames = tree_roots(call_stack_tree)
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
        "activeStates": environment.get("states"),
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


SAMPLE_GAP_SECONDS = 45.0
CONTEXT_FIELDS = ("scene", "surface", "turnRunningVisible", "voiceCall", "route", "network", "thermal", "lowPower",
                  "charging", "batteryPercent", "brightnessPercent")
TIMELINE_FIELDS = ("scene", "surface", "turnRunningVisible", "voiceCall", "route", "network", "thermal", "lowPower",
                   "charging")
ACTIVITY_FIELDS = ("scene", "surface", "turnRunningVisible", "voiceCall")
WAKEUPS = ("interruptWakeups", "idleWakeups", "timerWakeups")
INTERVAL_KINDS = {
    "measured": "one state held from sample to sample",
    "mixed": "the state changed without a sample of its own, so the interval holds more than one state",
    "background": "from the background sample to the next foreground one; the sampler is stopped, so all use in "
                  "between is attributed to the background",
    "gap": f"no sample for more than {SAMPLE_GAP_SECONDS:.0f} s while not backgrounded",
    "incomplete": "records between the two samples are missing, so a state change inside may be unseen",
}
ASSOCIATION_NOTE = (
    "Process use is attributed to the state that held while it was measured: association, not causation. Work "
    "started in one state and finished in the next counts toward the next. Battery levels cover the whole device."
)


def telemetry_runs(records: Iterable[dict]) -> list[dict]:
    headers: dict[str, dict] = {}
    lines: defaultdict[str, dict[int, dict]] = defaultdict(dict)
    for record in records:
        run_id = record.get("runID")
        if not isinstance(run_id, str):
            continue
        if record.get("recordType") == "run":
            known = headers.get(run_id)
            if known is None or record.get("flushedThroughSeq", 0) > known.get("flushedThroughSeq", 0):
                headers[run_id] = record
        elif isinstance(seq := record.get("seq"), int):
            lines[run_id].setdefault(seq, record)
    runs = []
    for run_id in set(headers) | set(lines):
        received = lines[run_id]
        span = max(received) - min(received) + 1 if received else 0
        header = {key: value for key, value in headers.get(run_id, {}).items()
                  if key not in ("recordType", "schemaVersion", "flushedThroughSeq")}
        runs.append({"runID": run_id, "header": header or None,
                     "records": [received[seq] for seq in sorted(received)],
                     "missingRecords": span - len(received)})
    return sorted(runs, key=lambda run: (run["records"][0]["ts"] if run["records"] else ""))


def _counter(record: dict, *names: str) -> int:
    return sum(int(record.get(name) or 0) for name in names)


def sample_intervals(records: list[dict]) -> list[dict]:
    samples = [record for record in records
               if record.get("recordType") == "sample" and isinstance(record.get("context"), dict)]
    seqs = {record["seq"] for record in records}
    intervals = []
    for start, end in zip(samples, samples[1:], strict=False):
        seconds = (end["monoNs"] - start["monoNs"]) / 1e9
        if seconds <= 0:
            continue
        if any(seq not in seqs for seq in range(start["seq"] + 1, end["seq"])):
            kind = "incomplete"
        elif start["context"].get("scene") == "background":
            kind = "background"
        elif seconds > SAMPLE_GAP_SECONDS:
            kind = "gap"
        elif end.get("mixed"):
            kind = "mixed"
        else:
            kind = "measured"
        start_persistence, end_persistence = start.get("persistence") or {}, end.get("persistence") or {}
        intervals.append({
            "start": start["ts"], "end": end["ts"], "seconds": seconds, "kind": kind,
            "context": start["context"], "endContext": end["context"],
            "cpuSeconds": (_counter(end, "cpuUserNs", "cpuSystemNs") - _counter(start, "cpuUserNs", "cpuSystemNs")) / 1e9,
            **{name: _counter(end, name) - _counter(start, name) for name in WAKEUPS},
            "footprintBytes": max(_counter(start, "footprintBytes"), _counter(end, "footprintBytes")),
            "persistenceBytes": {owner: int(counters.get("bytes", 0)) - int(start_persistence.get(owner, {}).get("bytes", 0))
                                 for owner, counters in end_persistence.items()},
            "persistenceWrites": {owner: int(counters.get("writes", 0)) - int(start_persistence.get(owner, {}).get("writes", 0))
                                  for owner, counters in end_persistence.items()},
        })
    return intervals


def _totals(intervals: list[dict]) -> dict:
    seconds = sum(interval["seconds"] for interval in intervals)
    cpu = sum(interval["cpuSeconds"] for interval in intervals)
    persistence: Counter = Counter()
    for interval in intervals:
        persistence.update(interval["persistenceBytes"])
    return {
        "seconds": round(seconds, 3),
        "cpuSeconds": round(cpu, 3),
        "cpuPercent": round(cpu / seconds * 100, 2) if seconds else None,
        "wakeupsPerSecond": {name: round(sum(interval[name] for interval in intervals) / seconds, 2) if seconds else None
                             for name in WAKEUPS},
        "peakSampledFootprintBytes": max((interval["footprintBytes"] for interval in intervals), default=None),
        "persistenceBytes": {owner: value for owner, value in sorted(persistence.items()) if value},
    }


def _project(context: dict, fields: Iterable[str]) -> dict:
    return {field: context.get(field) for field in fields}


def timeline(intervals: list[dict], fields: Iterable[str] = TIMELINE_FIELDS) -> list[dict]:
    fields = tuple(fields)
    stretches: list[tuple[tuple, list[dict]]] = []
    for interval in intervals:
        key = (interval["kind"], tuple(interval["context"].get(field) for field in fields))
        if stretches and stretches[-1][0] == key:
            stretches[-1][1].append(interval)
        else:
            stretches.append((key, [interval]))
    result = []
    for (kind, _), members in stretches:
        battery = [value for interval in members for value in (interval["context"].get("batteryPercent"),
                                                                interval["endContext"].get("batteryPercent"))
                   if isinstance(value, int)]
        brightness = {interval["context"].get("brightnessPercent") for interval in members} - {None}
        result.append({
            "start": members[0]["start"], "end": members[-1]["end"], "kind": kind,
            "state": _project(members[0]["context"], fields), **_totals(members),
            "peakIntervalCpuPercent": round(max(interval["cpuSeconds"] / interval["seconds"] * 100
                                                for interval in members), 2),
            "battery": [battery[0], battery[-1]] if battery else None,
            "brightnessPercent": [min(brightness), max(brightness)] if brightness else None,
        })
    return result


def activity(intervals: list[dict], fields: Iterable[str] = ACTIVITY_FIELDS) -> list[dict]:
    fields = tuple(fields)
    groups: defaultdict[tuple, list[dict]] = defaultdict(list)
    for interval in intervals:
        groups[(interval["kind"], tuple(interval["context"].get(field) for field in fields))].append(interval)
    rows = [{"kind": kind, "state": dict(zip(fields, values, strict=True)), "intervals": len(members),
             **_totals(members)}
            for (kind, values), members in groups.items()]
    return sorted(rows, key=lambda row: row["cpuSeconds"], reverse=True)


def _distribution(values: list[float]) -> dict:
    ordered = sorted(values)
    if not ordered:
        return {}

    def percentile(share: float) -> float:
        return round(ordered[min(len(ordered) - 1, int(share * len(ordered)))], 2)

    return {"sum": round(sum(ordered), 2), "p50": percentile(0.5), "p95": percentile(0.95), "max": round(ordered[-1], 2)}


def _parse(stamp: str) -> datetime.datetime:
    return datetime.datetime.fromisoformat(stamp)


def export_costs(runs: list[dict]) -> dict:
    exports = [record for run in runs for record in run["records"] if record.get("recordType") == "export"]
    samples = [record for run in runs for record in run["records"] if record.get("recordType") == "sample"]
    by_reason: defaultdict[str, list[dict]] = defaultdict(list)
    for record in exports:
        by_reason[str(record.get("reason"))].append(record)
    reasons = {}
    for reason, items in sorted(by_reason.items()):
        growth = [record["footprintSampledMax"] - record["footprintBefore"] for record in items
                  if isinstance(record.get("footprintSampledMax"), int) and isinstance(record.get("footprintBefore"), int)]
        reasons[reason] = {
            "exports": len(items),
            "collections": dict(sorted(Counter(str(record.get("collection", "unknown")) for record in items).items())),
            "totalMs": _distribution([float(record.get("totalMs", 0)) for record in items]),
            "stageMs": {stage: round(sum(float(record.get(f"{stage}Ms", 0)) for record in items), 2)
                        for stage in ("scan", "encode", "write", "compress", "upload")},
            **{name: sum(int(record.get(name, 0)) for record in items)
               for name in ("scanned", "kept", "segments", "bytes", "flushedRecords", "uploadedSegments",
                            "uploadedBytes")},
            "processCpuSecondsDuringExports": round(sum(int(record.get("processCpuNs") or 0) for record in items) / 1e9, 3),
            "sampledFootprintGrowthBytes": max(growth, default=None),
        }
    covered_cpu = sampled_cpu = 0.0
    uncovered = 0
    for run in runs:
        intervals = sample_intervals(run["records"])
        sampled_cpu += sum(interval["cpuSeconds"] for interval in intervals)
        if not intervals:
            uncovered += sum(record.get("recordType") == "export" for record in run["records"])
            continue
        first, last = _parse(intervals[0]["start"]), _parse(intervals[-1]["end"])
        for record in run["records"]:
            if record.get("recordType") != "export":
                continue
            finished = _parse(record["ts"])
            started = finished - datetime.timedelta(milliseconds=float(record.get("totalMs", 0)))
            if first <= started and finished <= last:
                covered_cpu += int(record.get("processCpuNs") or 0) / 1e9
            else:
                uncovered += 1
    read_ns = [int(record.get("readNs") or 0) for record in samples]
    return {
        "reasons": reasons,
        "sampledProcessCpuSeconds": round(sampled_cpu, 3),
        "processCpuSecondsDuringCoveredExports": round(covered_cpu, 3),
        "exportShareOfSampledCpu": round(covered_cpu / sampled_cpu, 4) if sampled_cpu else None,
        "exportsOutsideSampledCoverage": uncovered,
        "shareNote": "Whole-process CPU while each export ran, over the CPU sampled in the same runs; only exports "
                     "that lie entirely between a run's first and last sample count, and concurrent work inflates it.",
        "sampler": {"samples": len(samples), "readMicroseconds": _distribution([value / 1000 for value in read_ns])},
    }


def losses(records: Iterable[dict]) -> list[dict]:
    totals: defaultdict[tuple[str, str], Counter] = defaultdict(Counter)
    for record in records:
        if record.get("recordType") == "loss":
            totals[(str(record.get("what")), str(record.get("reason")))].update(
                {"records": 1, "count": int(record.get("count") or 0), "bytes": int(record.get("bytes") or 0)})
    return [{"what": what, "reason": reason, **counts} for (what, reason), counts in sorted(totals.items())]
