from collections import Counter, defaultdict
from collections.abc import Iterable
from dataclasses import dataclass, field

from .app_telemetry_builds import Attribution, Build
from .app_telemetry_summary import WAKEUPS, sample_intervals, scalar

FOREGROUND_TOLERANCE_SECONDS = 1.0
FOREGROUND_ONLY_DOMAINS = frozenset({"history"})
MIN_MEASURED_MINUTES = 30.0
MIN_SPREAD_MINUTES = 1.0
LAUNCH_METRICS = ("timeToFirstDraw", "optimizedTimeToFirstDraw", "applicationResume", "extendedLaunch")
RATE_METRICS = ("cpuSeconds", "gpuSeconds", *WAKEUPS, "persistenceWrites", "persistenceBytes")
UNMEASURED_RESOURCES = "not measured: cpuTime, logicalWrites and averageMemory are all exactly 0"
STATES_NOTE = (
    "suspectedStuck: a history state lasting longer than the report's whole foreground time; history states clear "
    "when the load finishes. stateExceedsCoverage: one state entry longer than the report's coverage. "
    "domainForegroundExceedsEntryTotal: a domain's per-state foreground times add up to more than the full-day "
    "entry's foreground time, so per-state foreground figures are not additive with it. "
    "State entries aggregate per domain, label, attributed build and device model. attributedBuild is the build the "
    "run headers place in the report's coverage; a mixed report cannot be split because MetricKit entries carry no "
    "start times. null and unknown mean not reported, never zero."
)
COMPARE_NOTE = (
    "Sampler numbers are per measured minute in each state, from intervals that held one state; mixed, gap, "
    "background and incomplete intervals are excluded. MetricKit numbers come from the full-day entry of reports "
    "whose coverage ran exactly one build, divided by foreground hours: a normalization, since the day's totals "
    "include background work."
)


@dataclass
class Total:
    value: float = 0.0
    count: int = 0

    def add(self, value: float | None) -> None:
        if value is not None:
            self.value += value
            self.count += 1

    @property
    def known(self) -> float | None:
        return self.value if self.count else None


@dataclass
class Histogram:
    unit: str | None = None
    buckets: Counter = field(default_factory=Counter)

    def add(self, buckets: Iterable[dict]) -> None:
        for bucket in buckets:
            lower, upper = bucket.get("lowerBound") or {}, bucket.get("upperBound") or {}
            if not isinstance(upper.get("value"), (int, float)):
                continue
            self.unit = self.unit or upper.get("unit")
            self.buckets[(lower.get("value"), upper["value"])] += int(bucket.get("count") or 0)

    def percentile(self, share: float) -> float | None:
        total = sum(self.buckets.values())
        seen = 0
        for (_, upper), count in sorted(self.buckets.items(), key=lambda item: (item[0][1], item[0][0] or 0)):
            seen += count
            if total and seen >= share * total:
                return upper
        return None

    def summary(self) -> dict:
        count = sum(self.buckets.values())
        if not count:
            return {"count": 0}
        return {
            "count": count, "unit": self.unit,
            "p50UpperBound": self.percentile(0.5), "p95UpperBound": self.percentile(0.95),
            "maxUpperBound": max(upper for _, upper in self.buckets),
            "totalAtLeast": sum((lower or 0) * number for (lower, _), number in self.buckets.items()),
        }


@dataclass
class SignpostGroup:
    count: int = 0
    entries: int = 0
    duration: Histogram = field(default_factory=Histogram)
    cpu_seconds: float = 0.0
    logical_writes_mb: float = 0.0
    memory_weighted: float = 0.0
    memory_samples: int = 0
    measured_entries: int = 0

    def add(self, payload: dict) -> None:
        self.entries += 1
        self.count += int(payload.get("totalCount") or 0)
        self.duration.add((payload.get("signpostDuration") or {}).get("buckets", []))
        memory = payload.get("averageMemory") or {}
        cpu, writes = scalar(payload.get("cpuTime")), scalar(payload.get("logicalWrites"))
        average = scalar(memory.get("average"))
        if not any((cpu, writes, average)):
            return
        self.measured_entries += 1
        self.cpu_seconds += cpu or 0.0
        self.logical_writes_mb += writes or 0.0
        if average is not None:
            weight = int(memory.get("count") or 0)
            self.memory_weighted += average * weight
            self.memory_samples += weight

    def summary(self, category: str, name: str) -> dict:
        resources: dict = {"status": "unknown", "reason": UNMEASURED_RESOURCES}
        if self.measured_entries:
            resources = {
                "cpuTimeSeconds": round(self.cpu_seconds, 3), "logicalWritesMB": round(self.logical_writes_mb, 3),
                "averageMemoryMB": round(self.memory_weighted / self.memory_samples, 2) if self.memory_samples else None,
                "measuredEntries": self.measured_entries, "unmeasuredEntries": self.entries - self.measured_entries,
            }
        return {"category": category, "name": name, "count": self.count, "duration": self.duration.summary(),
                "resources": resources}


@dataclass
class StateGroup:
    reports: set = field(default_factory=set)
    entries: int = 0
    state_seconds: Total = field(default_factory=Total)
    foreground: Total = field(default_factory=Total)
    background: Total = field(default_factory=Total)
    hitch_ms: Total = field(default_factory=Total)
    animation_ms: Total = field(default_factory=Total)
    ratio_weighted: float = 0.0
    ratio_weight: float = 0.0
    hang: Histogram = field(default_factory=Histogram)
    launch: dict = field(default_factory=lambda: defaultdict(Histogram))
    signposts: dict = field(default_factory=lambda: defaultdict(SignpostGroup))
    longest_entry_seconds: float = 0.0
    flags: set = field(default_factory=set)

    def summary(self, domain: str, label: str, build: str, model: str | None, candidates: list[str]) -> dict:
        animation = self.animation_ms.known
        hitch: dict = {"totalHitchMs": None, "totalAnimationMs": None, "hitchTimeRatio": None}
        if self.hitch_ms.count:
            hitch = {"totalHitchMs": round(self.hitch_ms.value, 3), "totalAnimationMs": round(animation or 0.0, 3),
                     "hitchTimeRatio": round(self.ratio_weighted / self.ratio_weight, 3) if self.ratio_weight else None,
                     "unit": "ms per s, weighted by animation time"}
        row = {
            "domain": domain, "label": label, "build": build, "model": model, "reports": len(self.reports),
            "entries": self.entries,
            "stateSeconds": _round(self.state_seconds.known), "longestEntrySeconds": round(self.longest_entry_seconds, 1),
            "foregroundSeconds": _round(self.foreground.known), "backgroundSeconds": _round(self.background.known),
            "hitch": hitch, "hang": self.hang.summary() if self.hang.buckets else None,
            "signposts": [group.summary(category, name)
                          for (category, name), group in sorted(self.signposts.items())],
            "flags": sorted(self.flags),
        }
        if self.launch:
            row["launch"] = {name: histogram.summary() for name, histogram in sorted(self.launch.items())}
        if candidates:
            row["candidateBuilds"] = candidates
        return row


def _round(value: float | None) -> float | None:
    return None if value is None else round(value, 1)


def _values(values: Iterable[dict]) -> Iterable[tuple[str, dict]]:
    for item in values:
        for name, payload in item.items():
            if isinstance(payload, dict):
                yield name.removesuffix("Metric"), payload


def _metric_seconds(values: Iterable[dict], name: str) -> float | None:
    for metric, payload in _values(values):
        if metric == name:
            return scalar(payload.get("value"))
    return None


def full_day_entry(report: dict) -> dict | None:
    entries = [entry for entry in report.get("intervalEntries") or [] if isinstance(entry, dict)]
    return max(entries, key=lambda entry: scalar(entry.get("duration")) or 0.0, default=None)


def _domain_name(domain: str) -> str:
    return domain.rsplit(".", 1)[-1]


def _add_state_entry(group: StateGroup, entry: dict, coverage_seconds: float | None,
                     entry_foreground: float | None, report_id: str) -> None:
    state = entry.get("state") or {}
    seconds = scalar(state.get("duration"))
    group.reports.add(report_id)
    group.entries += 1
    group.state_seconds.add(seconds)
    values = entry.get("values") or []
    foreground = _metric_seconds(values, "totalForegroundTime")
    group.foreground.add(foreground)
    group.background.add(_metric_seconds(values, "totalBackgroundTime"))
    if seconds is not None:
        group.longest_entry_seconds = max(group.longest_entry_seconds, seconds)
        if coverage_seconds is not None and seconds > coverage_seconds + FOREGROUND_TOLERANCE_SECONDS:
            group.flags.add("stateExceedsCoverage")
        if (_domain_name(state.get("domain", "")) in FOREGROUND_ONLY_DOMAINS and entry_foreground is not None
                and seconds > entry_foreground + FOREGROUND_TOLERANCE_SECONDS):
            group.flags.add("suspectedStuck")
    for metric, payload in _values(values):
        if metric == "hitchTime":
            hitch, animation = scalar(payload.get("totalHitchTime")), scalar(payload.get("totalAnimationTime"))
            ratio = scalar(payload.get("ratio"))
            group.hitch_ms.add(hitch)
            group.animation_ms.add(animation)
            if ratio is not None and animation:
                group.ratio_weighted += ratio * animation
                group.ratio_weight += animation
        elif metric == "hangTime":
            group.hang.add((payload.get("histogram") or {}).get("buckets", []))
        elif metric in LAUNCH_METRICS:
            group.launch[metric].add((payload.get("histogram") or {}).get("buckets", []))
        elif metric == "signpostInterval":
            group.signposts[(payload.get("signpostCategory", ""), payload.get("signpostName", ""))].add(payload)


def _report_flags(report: dict, coverage_seconds: float | None) -> dict:
    environment = report.get("environment") or {}
    full_day = full_day_entry(report)
    total = _metric_seconds(full_day.get("values") or [], "totalForegroundTime") if full_day else None
    per_domain: defaultdict[str, Total] = defaultdict(Total)
    for entry in report.get("stateEntries") or []:
        per_domain[(entry.get("state") or {}).get("domain", "")].add(
            _metric_seconds(entry.get("values") or [], "totalForegroundTime"))
    exceeding = [
        {"domain": domain, "stateForegroundSeconds": round(summed.value, 1), "entryForegroundSeconds": total}
        for domain, summed in sorted(per_domain.items())
        if total is not None and summed.count and summed.value > total + FOREGROUND_TOLERANCE_SECONDS
    ]
    return {
        "hasExceededStateLimit": environment.get("hasExceededStateLimit"),
        "entryForegroundSeconds": total,
        "domainForegroundExceedsEntryTotal": exceeding,
    }


def aggregate_states(reports: list[tuple[dict, dict, Attribution]]) -> dict:
    groups: defaultdict[tuple, StateGroup] = defaultdict(StateGroup)
    candidates: defaultdict[tuple, set] = defaultdict(set)
    summaries = []
    for summary, report, attribution in reports:
        model = summary.get("deviceType")
        coverage_seconds = summary.get("coverageSeconds")
        flags = _report_flags(report, coverage_seconds)
        summaries.append({
            "reportID": summary["reportID"], "coverageStart": summary["coverageStart"],
            "coverageSeconds": coverage_seconds, "deviceType": model,
            "reportedBuild": summary["reportedBuild"], "attributedBuild": attribution.as_json(),
            "stateEntries": len(report.get("stateEntries") or []),
            **flags,
        })
        for entry in report.get("stateEntries") or []:
            state = entry.get("state") or {}
            key = (state.get("domain"), state.get("label"), attribution.label, model)
            _add_state_entry(groups[key], entry, coverage_seconds, flags["entryForegroundSeconds"],
                             summary["reportID"])
            if attribution.status == "mixed":
                candidates[key].update(build.label for build, _ in attribution.builds)
    rows = [group.summary(domain, label, build, model, sorted(candidates.get((domain, label, build, model), ())))
            for (domain, label, build, model), group in
            sorted(groups.items(), key=lambda item: tuple(str(part) for part in item[0]))]
    return {"note": STATES_NOTE, "reports": summaries, "states": rows}


def group_diagnostics(items: list[dict]) -> list[dict]:
    groups: defaultdict[tuple, dict] = defaultdict(lambda: {"counts": Counter(), "builds": Counter(), "longest": {}})
    for item in items:
        active = item.get("activeStates")
        key = None if active is None else tuple(sorted({(state.get("domain"), state.get("label")) for state in active}))
        group = groups[key]
        group["counts"][item.get("type") or "unknown"] += 1
        group["builds"][item["attributedBuild"]["label"]] += 1
        for state in active or ():
            name = f"{state.get('domain')}/{state.get('label')}"
            seconds = scalar(state.get("duration"))
            if seconds is not None:
                group["longest"][name] = max(group["longest"].get(name, 0.0), round(seconds, 1))
    return [
        {"states": "not reported" if key is None else [{"domain": domain, "label": label} for domain, label in key],
         "total": sum(group["counts"].values()),
         "counts": dict(group["counts"].most_common()), "builds": dict(group["builds"].most_common()),
         "longestStateSecondsBeforeEvent": group["longest"]}
        for key, group in sorted(groups.items(), key=lambda item: -sum(item[1]["counts"].values()))
    ]


@dataclass
class Acc:
    seconds: float = 0.0
    sums: Counter = field(default_factory=Counter)
    gpu_seconds_known: float = 0.0
    writes: Counter = field(default_factory=Counter)
    bytes: Counter = field(default_factory=Counter)
    per_run: dict = field(default_factory=dict)

    def add(self, interval: dict, run_id: str) -> None:
        self.take(interval)
        self.per_run.setdefault(run_id, Acc()).take(interval)

    def take(self, interval: dict) -> None:
        self.seconds += interval["seconds"]
        self.sums["cpuSeconds"] += interval["cpuSeconds"]
        for name in WAKEUPS:
            self.sums[name] += interval[name]
        if interval["gpuSeconds"] is not None:
            self.sums["gpuSeconds"] += interval["gpuSeconds"]
            self.gpu_seconds_known += interval["seconds"]
        self.writes.update(interval["persistenceWrites"])
        self.bytes.update(interval["persistenceBytes"])
        self.sums["persistenceWrites"] += sum(interval["persistenceWrites"].values())
        self.sums["persistenceBytes"] += sum(interval["persistenceBytes"].values())

    def rates(self) -> dict:
        minutes = self.seconds / 60
        gpu_minutes = self.gpu_seconds_known / 60
        return {name: (round(self.sums[name] / gpu_minutes, 4) if gpu_minutes else None) if name == "gpuSeconds"
                else (round(self.sums[name] / minutes, 4) if minutes else None)
                for name in RATE_METRICS}


def _spread(accs: list[Acc], name: str) -> dict:
    values = sorted(rate for acc in accs if acc.seconds >= MIN_SPREAD_MINUTES * 60
                    and (rate := acc.rates()[name]) is not None)
    if not values:
        return {"runs": 0}
    return {"runs": len(values), "min": values[0], "p50": values[len(values) // 2], "max": values[-1]}


def _side(acc: Acc | None) -> dict | None:
    if acc is None:
        return None
    runs = list(acc.per_run.values())
    minutes = acc.seconds / 60
    return {
        "minutes": round(minutes, 2), "runs": len(acc.per_run),
        "gpuKnownMinutes": round(acc.gpu_seconds_known / 60, 2),
        "perMinute": acc.rates(),
        "persistenceOwners": {owner: {"writesPerMinute": round(acc.writes[owner] / minutes, 4),
                                      "bytesPerMinute": round(acc.bytes[owner] / minutes, 2)}
                              for owner in sorted(set(acc.writes) | set(acc.bytes))} if minutes else {},
        "spreadAcrossRuns": {name: _spread(runs, name) for name in RATE_METRICS},
    }


def _change(before: dict | None, after: dict | None) -> dict | None:
    if before is None or after is None:
        return None
    result = {}
    for name in before:
        old, new = before[name], after.get(name)
        result[name] = None if old is None or new is None else {
            "difference": round(new - old, 4), "relative": round(new / old - 1, 4) if old else None}
    return result


def _state_key(interval: dict, fields: tuple[str, ...]) -> tuple:
    return tuple(interval["context"].get(name) for name in fields)


@dataclass
class Exposure:
    acc: Acc = field(default_factory=Acc)
    runs: set = field(default_factory=set)
    installations: set = field(default_factory=set)
    states: defaultdict = field(default_factory=lambda: defaultdict(Acc))


def sampler_exposure(runs: list[dict], spans_by_run: dict, build: Build, fields: tuple[str, ...], since: str,
                     until: str) -> dict[str | None, Exposure]:
    by_model: defaultdict[str | None, Exposure] = defaultdict(Exposure)
    for run in runs:
        span = spans_by_run.get(run["runID"])
        if span is None or span.build != build:
            continue
        for interval in sample_intervals(run["records"]):
            if interval["kind"] != "measured" or not since <= interval["start"] <= until:
                continue
            exposure = by_model[span.model]
            exposure.acc.add(interval, run["runID"])
            exposure.states[_state_key(interval, fields)].add(interval, run["runID"])
            exposure.runs.add(run["runID"])
            exposure.installations.add(span.installation)
    return by_model


def metrickit_exposure(reports: list[tuple[dict, dict, Attribution]], build: Build) -> dict[str | None, dict]:
    by_model: defaultdict[str | None, dict] = defaultdict(lambda: {
        "reports": 0, "foregroundHours": 0.0, "perReport": defaultdict(list),
        "sums": defaultdict(lambda: [0.0, 0.0, 0])})
    for summary, report, attribution in reports:
        if attribution.build != build:
            continue
        full_day = full_day_entry(report)
        if full_day is None:
            continue
        foreground = _metric_seconds(full_day.get("values") or [], "totalForegroundTime")
        if not foreground:
            continue
        side = by_model[summary.get("deviceType")]
        side["reports"] += 1
        side["foregroundHours"] += foreground / 3600
        for label, metric in (("cpuSeconds", "cpuTime"), ("gpuSeconds", "gpuTime"), ("logicalWritesMB", "logicalDiskWrites")):
            value = _metric_seconds(full_day.get("values") or [], metric)
            if value is None:
                continue
            side["sums"][label][0] += value
            side["sums"][label][1] += foreground / 3600
            side["sums"][label][2] += 1
            side["perReport"][label].append(round(value / (foreground / 3600), 3))
    return by_model


def _metrickit_side(side: dict | None) -> dict | None:
    if side is None:
        return None
    rates = {label: round(total / hours, 3) if hours else None for label, (total, hours, _) in side["sums"].items()}
    spread = {}
    for label, values in side["perReport"].items():
        ordered = sorted(values)
        spread[label] = {"reports": len(ordered), "min": ordered[0], "p50": ordered[len(ordered) // 2], "max": ordered[-1]}
    return {"reports": side["reports"], "foregroundHours": round(side["foregroundHours"], 2),
            "perForegroundHour": rates, "spreadAcrossReports": spread}


def compare(runs: list[dict], spans_by_run: dict, reports: list[tuple[dict, dict, Attribution]], before: Build,
            after: Build, fields: tuple[str, ...], since: str, until: str, minimum_minutes: float) -> dict:
    sides = {name: sampler_exposure(runs, spans_by_run, build, fields, since, until)
             for name, build in (("before", before), ("after", after))}
    metrickit = {name: metrickit_exposure(reports, build) for name, build in (("before", before), ("after", after))}
    models = sorted(set(sides["before"]) | set(sides["after"]), key=str)
    strata, refusals = [], []
    for model in models:
        exposures = {name: sides[name].get(model) for name in sides}
        minutes = {name: round(exposure.acc.seconds / 60, 2) if exposure else 0.0 for name, exposure in exposures.items()}
        short = [name for name, value in minutes.items() if value < minimum_minutes]
        if short:
            reason = "; ".join(f"{name} has {minutes[name]} measured minutes, below the minimum {minimum_minutes:g}"
                               for name in short)
            refusals.append({"model": model, "reason": reason})
            strata.append({"model": model, "refused": reason, "measuredMinutes": minutes})
            continue
        state_keys = sorted(set(exposures["before"].states) | set(exposures["after"].states), key=str)
        rows = []
        for key in state_keys:
            old, new = (_side(exposures[name].states.get(key)) for name in ("before", "after"))
            rows.append({"state": dict(zip(fields, key, strict=True)), "before": old, "after": new,
                         "change": _change(old and old["perMinute"], new and new["perMinute"])})
        strata.append({
            "model": model, "measuredMinutes": minutes,
            "exposure": {name: {"runs": len(exposure.runs), "installations": len(exposure.installations - {None})}
                         for name, exposure in exposures.items()},
            "overall": {name: _side(exposure.acc) for name, exposure in exposures.items()},
            "states": rows,
            "metrickit": {"before": _metrickit_side(metrickit["before"].get(model)),
                          "after": _metrickit_side(metrickit["after"].get(model))},
        })
    refused = not any("refused" not in stratum for stratum in strata)
    if not strata:
        refusals.append({"model": None, "reason": "no measured sampler time for either build in the window"})
    return {"note": COMPARE_NOTE, "minimumMeasuredMinutes": minimum_minutes,
            "before": before.as_json(), "after": after.as_json(), "fields": list(fields),
            "refused": refused, "refusals": refusals, "strata": strata}

