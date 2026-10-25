import datetime
from collections import defaultdict
from collections.abc import Iterable
from dataclasses import dataclass

from .app_telemetry_summary import iso

COMMIT_PREFIX_MINIMUM = 4


@dataclass(frozen=True)
class Build:
    app_version: str
    build: str
    source_commit: str | None

    @property
    def label(self) -> str:
        label = f"{self.app_version} ({self.build})"
        return f"{label} {self.source_commit[:9]}" if self.source_commit else label

    def as_json(self) -> dict:
        return {"appVersion": self.app_version, "build": self.build, "sourceCommit": self.source_commit,
                "label": self.label}

    def matches(self, selector: str) -> bool:
        wanted = selector.strip().lower()
        if wanted in (self.app_version.lower(), self.build.lower(), self.label.lower()):
            return True
        return (self.source_commit is not None and len(wanted) >= COMMIT_PREFIX_MINIMUM
                and self.source_commit.lower().startswith(wanted))


@dataclass(frozen=True)
class RunSpan:
    run_id: str
    build: Build
    model: str | None
    installation: str | None
    start: datetime.datetime
    end: datetime.datetime


@dataclass(frozen=True)
class Attribution:
    status: str
    builds: tuple[tuple[Build, float], ...]
    covered_seconds: float
    window_seconds: float

    @property
    def build(self) -> Build | None:
        return self.builds[0][0] if self.status == "single" else None

    @property
    def label(self) -> str:
        return self.builds[0][0].label if self.status == "single" else self.status

    def as_json(self) -> dict:
        return {
            "status": self.status, "label": self.label,
            "builds": [{**build.as_json(), "seconds": round(seconds, 1)} for build, seconds in self.builds],
            "coveredSeconds": round(self.covered_seconds, 1),
            "windowSeconds": round(self.window_seconds, 1),
        }


class BuildSelectionError(Exception):
    def __init__(self, message: str, candidates: list[Build]):
        super().__init__(message)
        self.candidates = candidates


def parse_instant(stamp: str) -> datetime.datetime:
    return datetime.datetime.fromisoformat(stamp)


def run_build(header: dict | None) -> Build | None:
    if not header:
        return None
    version, build, commit = header.get("appVersion"), header.get("build"), header.get("sourceCommit")
    if not isinstance(version, str) or not isinstance(build, str):
        return None
    return Build(version, build, commit if isinstance(commit, str) and commit else None)


def run_span(run: dict) -> RunSpan | None:
    build = run_build(run["header"])
    stamps = [parse_instant(record["ts"]) for record in run["records"] if isinstance(record.get("ts"), str)]
    started = (run["header"] or {}).get("startedAt")
    if started:
        stamps.append(parse_instant(started))
    if build is None or not stamps:
        return None
    header = run["header"]
    return RunSpan(run["runID"], build, header.get("model"), header.get("installationID"), min(stamps), max(stamps))


def run_spans(runs: Iterable[dict]) -> list[RunSpan]:
    return sorted((span for run in runs if (span := run_span(run)) is not None), key=lambda span: span.start)


def attribute(spans: Iterable[RunSpan], start: datetime.datetime, end: datetime.datetime) -> Attribution:
    seconds: defaultdict[Build, float] = defaultdict(float)
    instant = end <= start
    for span in spans:
        if instant:
            if span.start <= start <= span.end:
                seconds[span.build] += 0.0
        elif (overlap := (min(end, span.end) - max(start, span.start)).total_seconds()) > 0:
            seconds[span.build] += overlap
    builds = tuple(sorted(seconds.items(), key=lambda item: (-item[1], item[0].label)))
    status = "unknown" if not builds else "single" if len(builds) == 1 else "mixed"
    return Attribution(status, builds, sum(seconds.values()), max(0.0, (end - start).total_seconds()))


def attribute_window(spans: Iterable[RunSpan], start: str | None, seconds: object) -> Attribution:
    if not isinstance(start, str) or not isinstance(seconds, (int, float)):
        return Attribution("unknown", (), 0.0, 0.0)
    begin = parse_instant(start)
    return attribute(spans, begin, begin + datetime.timedelta(seconds=seconds))


def select_build(builds: Iterable[Build], selector: str) -> Build:
    known = sorted(set(builds), key=lambda build: build.label)
    matches = [build for build in known if build.matches(selector)]
    if not matches:
        raise BuildSelectionError(f"no run of build {selector!r} in the window", known)
    if len(matches) > 1:
        raise BuildSelectionError(f"build {selector!r} is ambiguous; use a build number or longer commit prefix",
                                  matches)
    return matches[0]


def span_extent(spans: list[RunSpan]) -> dict:
    return {"runs": len(spans),
            "first": iso(min(span.start for span in spans)) if spans else None,
            "last": iso(max(span.end for span in spans)) if spans else None}
