import argparse
import datetime
import gzip
import json
import subprocess
from pathlib import Path

import pytest

from remotecoder_tools import app_telemetry, app_telemetry_store, app_telemetry_symbols
from remotecoder_tools.app_telemetry_analysis import (
    aggregate_states,
    compare,
    group_diagnostics,
)
from remotecoder_tools.app_telemetry_builds import (
    Attribution,
    Build,
    BuildSelectionError,
    attribute,
    attribute_window,
    run_spans,
    select_build,
)
from remotecoder_tools.app_telemetry_summary import (
    diagnostic,
    metrickit_report,
    telemetry_runs,
)

UTC = datetime.UTC
DAY = datetime.datetime(2026, 10, 23, tzinfo=UTC)
REPORT_START = DAY - datetime.timedelta(hours=2)


def stamp(moment: datetime.datetime) -> str:
    return moment.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def header(run_id: str, started: datetime.datetime, version: str, build: str, commit: str | None = None,
           model: str = "iPhone18,1") -> dict:
    return {"recordType": "run", "runID": run_id, "appVersion": version, "build": build, "model": model,
            "startedAt": stamp(started), "installationID": "install-1", "flushedThroughSeq": 1,
            **({"sourceCommit": commit} if commit else {})}


def sampled_run(run_id: str, started: datetime.datetime, minutes: int, version: str, build: str,
                commit: str | None = None, cpu_ns_per_sample: int = 300_000_000,
                model: str = "iPhone18,1", scene: str = "active") -> list[dict]:
    records = [header(run_id, started, version, build, commit, model)]
    for seq in range(1, minutes * 2 + 2):
        moment = started + datetime.timedelta(seconds=30 * (seq - 1))
        record = {
            "recordType": "sample", "runID": run_id, "seq": seq, "reason": "interval", "mixed": False,
            "ts": stamp(moment), "monoNs": 30_000_000_000 * seq, "cpuUserNs": cpu_ns_per_sample * seq,
            "cpuSystemNs": 0, "interruptWakeups": 100 * seq, "idleWakeups": 0, "timerWakeups": 10 * seq,
            "footprintBytes": 1000,
            "persistence": {"checkpoints": {"writes": 2 * seq, "bytes": 1000 * seq}},
            "context": {"scene": scene, "surface": "chat", "turnRunningVisible": False, "voiceCall": False},
        }
        records.append(record)
    return records


def spans_of(records: list[dict]):
    return run_spans(telemetry_runs(records))


def test_a_reports_delivery_build_label_does_not_decide_which_build_ran():
    records = [
        *sampled_run("run-a", DAY, 60, "3.68.2", "3068002"),
        *sampled_run("run-b", DAY + datetime.timedelta(hours=1, minutes=30), 30, "3.69.0", "3069000", "abcdef0123456789"),
    ]
    spans = spans_of(records)

    single = attribute(spans, DAY + datetime.timedelta(minutes=10), DAY + datetime.timedelta(minutes=50))
    mixed = attribute(spans, DAY, DAY + datetime.timedelta(hours=2))
    unknown = attribute(spans, DAY + datetime.timedelta(hours=5), DAY + datetime.timedelta(hours=8))

    assert (single.status, single.label) == ("single", "3.68.2 (3068002)")
    assert (mixed.status, mixed.label) == ("mixed", "mixed")
    assert [build.label for build, _ in mixed.builds] == ["3.68.2 (3068002)", "3.69.0 (3069000) abcdef012"]
    assert (unknown.status, unknown.builds, unknown.covered_seconds) == ("unknown", (), 0.0)

    report = metrickit_report({
        "kind": "metrics", "reportID": "r", "coverage": {"start": 0, "duration": 7200},
        "report": {"environment": {"applicationBuildVersion": "3069000", "latestApplicationVersion": "3.69.0"}},
    }, "local", "iPhone-test")
    assert report["reportedBuild"]["build"] == "3069000"
    assert "appVersion" not in report and "build" not in report
    day = attribute_window(spans, stamp(DAY), 7200)
    assert day.status == "mixed" and day.as_json()["label"] == "mixed"
    assert attribute_window(spans, None, None).status == "unknown"


def test_builds_are_keyed_by_commit_when_the_header_has_one():
    records = [
        *sampled_run("run-a", DAY, 5, "3.69.0", "3069000", "aaaa111122223333"),
        *sampled_run("run-b", DAY + datetime.timedelta(hours=1), 5, "3.69.0", "3069000", "bbbb111122223333"),
        *sampled_run("run-c", DAY + datetime.timedelta(hours=2), 5, "3.69.0", "3069000"),
    ]
    builds = {span.build for span in spans_of(records)}
    assert len(builds) == 3
    assert select_build(builds, "bbbb11").source_commit == "bbbb111122223333"
    with pytest.raises(BuildSelectionError, match="ambiguous") as ambiguous:
        select_build(builds, "3069000")
    assert len(ambiguous.value.candidates) == 3
    with pytest.raises(BuildSelectionError, match="no run"):
        select_build(builds, "abc")
    assert select_build([Build("0.0.0", "1.5.78", None), Build("0.0.0", "1.5.77", None)], "1.5.78").build == "1.5.78"


def measured(value: float, unit: str = "s") -> dict:
    return {"value": {"unit": unit, "value": value}}


def state_entry(domain: str, label: str, seconds: float, foreground: float, extra: list[dict] | None = None) -> dict:
    return {"state": {"domain": f"emileberhard.RemoteCoder.{domain}", "label": label, "duration": {"unit": "s", "value": seconds},
                      "stableMetadata": {}},
            "values": [{"totalForegroundTimeMetric": measured(foreground)}, *(extra or [])]}


def signpost(count: int, cpu: float, writes: float, memory: float, upper_ms: int) -> dict:
    return {"signpostIntervalMetric": {
        "signpostName": "HistorySelectionToFirstContent", "signpostCategory": "History", "totalCount": count,
        "cpuTime": {"unit": "s", "value": cpu}, "logicalWrites": {"unit": "MB", "value": writes},
        "averageMemory": {"average": {"unit": "MB", "value": memory}, "count": count},
        "signpostDuration": {"buckets": [{"count": count, "lowerBound": {"unit": "ms", "value": upper_ms - 99},
                                           "upperBound": {"unit": "ms", "value": upper_ms}}]}}}


def metrics_record(report_id: str, state_entries: list[dict], foreground: float = 1000, seconds: int = 86400,
                   exceeded: bool | None = False) -> dict:
    environment = {"applicationBuildVersion": "3069000", "latestApplicationVersion": "3.69.0", "deviceType": "iPhone18,1"}
    if exceeded is not None:
        environment["hasExceededStateLimit"] = exceeded
    return {
        "recordType": "metrickit", "kind": "metrics", "reportID": report_id, "ts": "2026-10-24T09:00:00.000Z",
        "coverage": {"start": (REPORT_START - datetime.datetime(2001, 1, 1, tzinfo=UTC)).total_seconds(), "duration": seconds},
        "report": {
            "environment": environment,
            "intervalEntries": [
                {"duration": {"unit": "s", "value": seconds}, "states": [],
                 "values": [{"totalForegroundTimeMetric": measured(foreground)}, {"cpuTimeMetric": measured(600)},
                            {"gpuTimeMetric": measured(120)}, {"logicalDiskWritesMetric": measured(36, "MB")}]},
                {"duration": {"unit": "s", "value": 10800}, "states": [], "values": []},
            ],
            "stateEntries": state_entries,
        },
    }


def aggregated(record: dict, attribution: Attribution | None = None) -> dict:
    summary = metrickit_report(record, "local", "iPhone-test")
    unknown = attribute([], DAY, DAY + datetime.timedelta(hours=1))
    return aggregate_states([(summary, record["report"], attribution or unknown)])


def test_state_time_beyond_the_entry_total_and_stuck_foreground_states_are_flagged():
    record = metrics_record("r1", [
        state_entry("connection", "connected", 50_000, 700),
        state_entry("connection", "connecting", 100, 400),
        state_entry("route", "lan", 50_000, 700),
        state_entry("history", "opening", 86_417, 600),
        state_entry("history", "paging", 4.65, 2),
    ])
    result = aggregated(record)
    [report] = result["reports"]
    rows = {(row["domain"].rsplit(".", 1)[-1], row["label"]): row for row in result["states"]}

    assert report["hasExceededStateLimit"] is False
    assert report["entryForegroundSeconds"] == 1000
    assert report["domainForegroundExceedsEntryTotal"] == [
        {"domain": "emileberhard.RemoteCoder.connection", "stateForegroundSeconds": 1100.0, "entryForegroundSeconds": 1000.0}]
    assert rows[("history", "opening")]["flags"] == ["stateExceedsCoverage", "suspectedStuck"]
    assert rows[("history", "paging")]["flags"] == []
    assert rows[("connection", "connected")]["flags"] == []
    assert rows[("route", "lan")]["flags"] == ["suspectedStuck"]
    assert rows[("history", "opening")]["longestEntrySeconds"] == 86_417
    assert aggregated(metrics_record("r2", [], exceeded=None))["reports"][0]["hasExceededStateLimit"] is None
    assert aggregated(metrics_record("r3", [], exceeded=True))["reports"][0]["hasExceededStateLimit"] is True


def test_signpost_resources_that_are_all_zero_are_unknown_not_zero():
    record = metrics_record("r1", [
        state_entry("history", "opening", 10, 10, [signpost(3, 0, 0, 0, 199)]),
        state_entry("history", "opening", 10, 10, [signpost(1, 0, 0, 0, 4399)]),
    ])
    [row] = aggregated(record)["states"]
    [post] = row["signposts"]
    assert post["count"] == 4
    assert post["resources"]["status"] == "unknown"
    assert (post["duration"]["p50UpperBound"], post["duration"]["p95UpperBound"]) == (199, 4399)

    record = metrics_record("r2", [
        state_entry("history", "opening", 10, 10, [signpost(3, 0, 0, 0, 199)]),
        state_entry("history", "opening", 10, 10, [signpost(2, 1.5, 4.0, 80, 299)]),
    ])
    [post] = aggregated(record)["states"][0]["signposts"]
    assert post["resources"] == {"cpuTimeSeconds": 1.5, "logicalWritesMB": 4.0, "averageMemoryMB": 80.0,
                                 "measuredEntries": 1, "unmeasuredEntries": 1}


def test_signpost_hitches_survive_state_aggregation_and_weight_by_animation_time():
    posts = [signpost(1, 0, 0, 0, 199) for _ in range(3)]
    for post, hitch, animation, ratio in zip(posts[:2], (20, 240), (10_000, 30_000), (2, 8), strict=True):
        post["signpostIntervalMetric"].update({
            "totalHitchTime": {"unit": "ms", "value": hitch},
            "totalAnimationTime": {"unit": "ms", "value": animation},
            "hitchTimeRatio": {"unit": "ms per s", "value": ratio},
        })
    record = metrics_record("r1", [state_entry("surface", "chat", 10, 10, [post]) for post in posts])
    [post] = aggregated(record)["states"][0]["signposts"]
    assert post["hitch"] == {"totalHitchMs": 260, "totalAnimationMs": 40_000, "hitchTimeRatio": 6.5,
                             "unit": "ms per s, weighted by animation time"}
    assert post["resources"]["status"] == "unknown"
    absent = metrics_record("r2", [state_entry("surface", "chat", 10, 10, [posts[2]])])
    [post] = aggregated(absent)["states"][0]["signposts"]
    assert post["hitch"] == {"totalHitchMs": None, "totalAnimationMs": None, "hitchTimeRatio": None}
    posts[2]["signpostIntervalMetric"]["totalHitchTime"] = {"unit": "ms", "value": 0}
    [post] = aggregated(absent)["states"][0]["signposts"]
    assert post["hitch"]["totalHitchMs"] == 0
    assert post["hitch"]["totalAnimationMs"] is None


def test_states_group_by_attributed_build_and_hitch_ratio_weights_by_animation_time():
    def hitch(ratio, hitch_ms, animation_ms):
        return {"hitchTimeMetric": {
            "ratio": {"unit": "ms per s", "value": ratio}, "totalHitchTime": {"unit": "ms", "value": hitch_ms},
            "totalAnimationTime": {"unit": "ms", "value": animation_ms}}}
    record = metrics_record("r1", [state_entry("history", "opening", 10, 10, [hitch(2.0, 20, 10_000), hitch(8.0, 240, 30_000)])])
    spans = spans_of(sampled_run("run-a", REPORT_START, 120, "3.69.0", "3069000", "abcdef0123456789"))
    single = attribute_window(spans, stamp(REPORT_START), 3600)
    [row] = aggregated(record, single)["states"]
    assert row["build"] == "3.69.0 (3069000) abcdef012"
    assert row["hitch"]["hitchTimeRatio"] == 6.5 and row["hitch"]["totalHitchMs"] == 260
    assert aggregated(record)["states"][0]["build"] == "unknown"


def test_diagnostics_group_by_active_states_and_keep_unreported_states_apart():
    def item(kind: str, states: list[dict] | None, build: str) -> dict:
        return {"type": kind, "activeStates": states, "attributedBuild": {"label": build}}

    stuck = {"domain": "emileberhard.RemoteCoder.history", "label": "opening", "duration": {"unit": "s", "value": 3000}}
    groups = group_diagnostics([
        item("hang", [stuck], "3.69.0 (3069000)"), item("crash", [stuck], "3.69.0 (3069000)"),
        item("hang", [], "unknown"), item("hang", None, "unknown"),
    ])
    by_states = {json.dumps(group["states"]): group for group in groups}
    opening = by_states[json.dumps([{"domain": "emileberhard.RemoteCoder.history", "label": "opening"}])]
    assert opening["counts"] == {"hang": 1, "crash": 1}
    assert opening["longestStateSecondsBeforeEvent"] == {"emileberhard.RemoteCoder.history/opening": 3000.0}
    assert by_states["[]"]["total"] == 1 and by_states['"not reported"']["total"] == 1


def reports_for(*records: dict, spans) -> list:
    return [(summary := metrickit_report(record, "local", "iPhone-test"), record["report"],
             attribute_window(spans, summary["coverageStart"], summary["coverageSeconds"])) for record in records]


def run_compare(records: list[dict], minimum: float = 30.0, metrics: list[dict] | None = None) -> dict:
    runs = telemetry_runs(records)
    spans = run_spans(runs)
    before, after = sorted({span.build for span in spans}, key=lambda build: build.label)
    return compare(runs, {span.run_id: span for span in spans}, reports_for(*(metrics or []), spans=spans),
                   before, after, ("scene", "surface"), "2026-10-01T00:00:00.000Z", "2026-12-01T00:00:00.000Z", minimum)


def test_compare_refuses_a_side_below_the_minimum_exposure():
    result = run_compare([
        *sampled_run("run-a", DAY, 60, "3.68.2", "3068002"),
        *sampled_run("run-b", DAY + datetime.timedelta(hours=2), 10, "3.69.0", "3069000"),
    ])
    assert result["refused"] is True
    assert result["refusals"] == [{"model": "iPhone18,1", "reason": "after has 10.0 measured minutes, below the minimum 30"}]
    assert "states" not in result["strata"][0]
    assert run_compare([
        *sampled_run("run-a", DAY, 60, "3.68.2", "3068002"),
        *sampled_run("run-b", DAY + datetime.timedelta(hours=2), 10, "3.69.0", "3069000"),
    ], minimum=10)["refused"] is False


def test_compare_reports_rates_per_state_and_exposure_per_model():
    metrics = [metrics_record("day", [])]
    result = run_compare([
        *sampled_run("run-a", DAY, 60, "3.68.2", "3068002", cpu_ns_per_sample=600_000_000),
        *sampled_run("run-b", DAY + datetime.timedelta(hours=26), 40, "3.69.0", "3069000", "abcdef0123456789",
                     cpu_ns_per_sample=300_000_000),
        *sampled_run("run-c", DAY + datetime.timedelta(hours=28), 40, "3.69.0", "3069000", "abcdef0123456789",
                     cpu_ns_per_sample=300_000_000),
        *sampled_run("run-d", DAY, 60, "3.68.2", "3068002", model="iPhone17,1"),
    ], metrics=metrics)

    assert result["refused"] is False
    strata = {stratum["model"]: stratum for stratum in result["strata"]}
    assert strata["iPhone17,1"]["refused"].startswith("after has 0.0 measured minutes")
    stratum = strata["iPhone18,1"]
    assert stratum["measuredMinutes"] == {"before": 60.0, "after": 80.0}
    assert stratum["exposure"] == {"before": {"runs": 1, "installations": 1}, "after": {"runs": 2, "installations": 1}}
    [row] = stratum["states"]
    assert row["state"] == {"scene": "active", "surface": "chat"}
    assert row["before"]["perMinute"]["cpuSeconds"] == 1.2
    assert row["after"]["perMinute"]["cpuSeconds"] == 0.6
    assert row["after"]["perMinute"]["persistenceWrites"] == 4.0
    assert row["after"]["persistenceOwners"]["checkpoints"]["bytesPerMinute"] == 2000.0
    assert row["after"]["spreadAcrossRuns"]["cpuSeconds"] == {"runs": 2, "min": 0.6, "p50": 0.6, "max": 0.6}
    assert row["change"]["cpuSeconds"] == {"difference": -0.6, "relative": -0.5}


def test_compare_withholds_the_change_of_a_state_measured_for_less_than_a_minute():
    result = run_compare([
        *sampled_run("run-a", DAY, 60, "3.68.2", "3068002"),
        *sampled_run("run-b", DAY + datetime.timedelta(hours=2), 1, "3.68.2", "3068002", scene="inactive")[:-1],
        *sampled_run("run-c", DAY + datetime.timedelta(hours=26), 60, "3.69.0", "3069000"),
        *sampled_run("run-d", DAY + datetime.timedelta(hours=28), 1, "3.69.0", "3069000", scene="inactive"),
    ])
    rows = {row["state"]["scene"]: row for row in result["strata"][0]["states"]}
    assert rows["active"]["change"] is not None and "changeRefused" not in rows["active"]
    assert rows["inactive"]["change"] is None
    assert rows["inactive"]["changeRefused"] == "before has 0.5 measured minutes, below 1"


def test_state_rows_keep_stable_metadata_apart():
    opening = state_entry("history", "opening", 10, 10)
    claude = {**opening, "state": {**opening["state"], "stableMetadata": {"provider": "claude"}}}
    codex = {**opening, "state": {**opening["state"], "stableMetadata": {"provider": "codex"}}}
    rows = aggregated(metrics_record("r1", [claude, codex]))["states"]
    assert sorted(row["stableMetadata"]["provider"] for row in rows) == ["claude", "codex"]


def test_compare_uses_metrickit_days_with_one_build_only():
    day = metrics_record("day", [])
    records = [*sampled_run("run-a", REPORT_START, 60, "3.68.2", "3068002"),
               *sampled_run("run-b", DAY + datetime.timedelta(hours=26), 40, "3.69.0", "3069000")]
    single = run_compare(records, minimum=10, metrics=[day])["strata"][0]["metrickit"]
    assert single["before"]["perForegroundHour"] == {"cpuSeconds": 2160.0, "gpuSeconds": 432.0, "logicalWritesMB": 129.6}
    assert single["after"] is None

    mixed = [*records, *sampled_run("run-c", REPORT_START + datetime.timedelta(hours=3), 10, "3.69.0", "3069000")]
    assert run_compare(mixed, minimum=10, metrics=[day])["strata"][0]["metrickit"] == {"before": None, "after": None}


def tree(binaries: dict[str, str], roots: list[dict]) -> dict:
    return {"binaryInfo": [{"name": name, "uuid": uuid} for uuid, name in binaries.items()],
            "callStackPerThread": False, "callStackThreads": [{"rootFrames": roots}]}


def frame(uuid: str, address: int, offset: int, samples: int, *children: dict) -> dict:
    return {"binaryUUID": uuid, "address": address, "offsetIntoBinaryTextSegment": offset, "sampleCount": samples,
            "subFrames": list(children)}


def test_every_frame_is_symbolicated_in_one_batch_per_binary_and_missing_binaries_name_uuid_and_build(monkeypatch):
    calls = []
    files = {"SYS": Path("/x/Foundation"), "OLD": Path("/x/RemoteCoder-old"), "BAD": Path("/x/Broken")}

    def fake_atos(file, base, addresses):
        calls.append((file.name, base, addresses))
        if file.name == "Broken":
            raise subprocess.CalledProcessError(1, "atos")
        return [(f"{file.name}@{address:x} + 8",) for address in addresses]

    monkeypatch.setattr(app_telemetry_symbols, "symbol_files", lambda paths, extra: files)
    monkeypatch.setattr(app_telemetry_symbols, "atos", fake_atos)
    names = {"SYS": "Foundation", "OLD": "RemoteCoder", "NEW": "RemoteCoder", "BAD": "Broken"}
    source = {"deviceType": "iPhone0,0", "osVersion": "0", "osBuild": "0"}
    first = tree(names, [
        frame("OLD", 0x100003000, 0x3000, 5,
              frame("SYS", 0x180000010, 0x10, 3, frame("NEW", 0x200001000, 0x1000, 1)),
              frame("SYS", 0x180000020, 0x20, 2)),
        frame("BAD", 0x300000040, 0x40, 1),
    ])
    second = tree(names, [frame("OLD", 0x110003000, 0x3000, 4, frame("SYS", 0x180000010, 0x10, 4)),
                          frame("NEW", 0x210001000, 0x1000, 1)])

    symbols = app_telemetry_symbols.symbolicate([
        app_telemetry_symbols.Capture(first, "3.68.2 (3068002)", source),
        app_telemetry_symbols.Capture(second, "3.69.0 (3069000)", source),
    ])

    assert sorted(calls) == [("Broken", 0x300000000, [0x300000040]), ("Foundation", 0x180000000, [0x180000010, 0x180000020]),
                             ("RemoteCoder-old", 0x100000000, [0x100003000]), ("RemoteCoder-old", 0x110000000, [0x110003000])]
    assert symbols.lookup[("SYS", 0x180000000, 0x20)] == ("Foundation@180000020 + 8",)
    summary = symbols.summary()
    assert summary["symbolicatedBinaries"] == 2 and summary["frames"] == 8 and summary["unsymbolicatedFrames"] == 3
    assert summary["missingSymbols"] == [
        {"binary": "Broken", "uuid": "BAD", "builds": ["3.68.2 (3068002)"], "frames": 1,
         "reason": "CalledProcessError: Command 'atos' returned non-zero exit status 1."},
        {"binary": "RemoteCoder", "uuid": "NEW", "builds": ["3.68.2 (3068002)", "3.69.0 (3069000)"], "frames": 2,
         "reason": app_telemetry_symbols.NO_SYMBOLS},
    ]

    heaviest = [{"binary": "Foundation", "uuid": "SYS", "address": 0x180000010, "offset": 0x10},
                {"binary": "RemoteCoder", "uuid": "NEW", "address": 0x200001000, "offset": 0x1000}]
    app_telemetry_symbols.annotate_heaviest(heaviest, first, symbols)
    assert heaviest[0]["symbols"] == ["Foundation@180000010 + 8"] and "symbols" not in heaviest[1]
    profile = app_telemetry_symbols.profile(first, symbols)
    assert {"symbol": "Foundation@180000010", "binary": "Foundation", "inclusiveSamples": 3, "selfSamples": 2} in profile[
        "bySelfSamples"]


def test_a_crash_stack_gives_its_self_samples_to_the_innermost_frame():
    crash = {**tree({"CORE": "libswiftCore", "APP": "RemoteCoder", "DYLD": "dyld"}, [
        frame("CORE", 0x190000100, 0x100, 1, frame("APP", 0x100002000, 0x2000, 1, frame("DYLD", 0x1a0000050, 0x50, 1))),
    ]), "callStackPerThread": True}
    profile = app_telemetry_symbols.profile(crash, app_telemetry_symbols.Symbols())
    assert [row["symbol"] for row in profile["bySelfSamples"]] == ["libswiftCore+0x100"]
    assert {row["symbol"]: row["inclusiveSamples"] for row in profile["byInclusiveSamples"]} == {
        "libswiftCore+0x100": 1, "RemoteCoder+0x2000": 1, "dyld+0x50": 1}


def test_a_frame_whose_address_is_off_by_one_keeps_the_binarys_shared_load_address():
    stack = tree({"APP": "RemoteCoder"}, [frame("APP", 0x100003000, 0x3000, 1, frame("APP", 0x100004001, 0x4000, 1),
                                               frame("APP", 0x100005000, 0x5000, 1))])
    assert app_telemetry_symbols.load_bases(stack) == {"APP": 0x100000000}


def diagnostic_record(kind: str, start: datetime.datetime, states: list[dict] | None) -> dict:
    environment = {"applicationBuildVersion": "3069000", "deviceType": "iPhone18,1"}
    if states is not None:
        environment["states"] = states
    return {"recordType": "metrickit", "kind": "diagnostic", "reportID": f"{kind}-{start.timestamp()}", "ts": stamp(start),
            "coverage": {"start": (start - datetime.datetime(2001, 1, 1, tzinfo=UTC)).total_seconds(), "duration": 0},
            "report": {"environment": environment, f"{kind}Diagnostic": {}}}


def write_store(tmp_path: Path, monkeypatch, segments: dict[str, list[dict]]) -> None:
    root = tmp_path / app_telemetry_store.APP_LOG_DIRECTORY / "iPhone-test"
    root.mkdir(parents=True)
    for index, (name, records) in enumerate(segments.items()):
        (root / f"20261023-{int(DAY.timestamp() * 1000) + index:015d}-{name}.jsonl.gz").write_bytes(
            gzip.compress(b"\n".join(json.dumps(record).encode() for record in records)))
    monkeypatch.setattr(app_telemetry_store.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(app_telemetry_store, "INDEX_ROOT", tmp_path / "index")


def arguments(**overrides) -> argparse.Namespace:
    values = {"store": ["local"], "device": "iPhone-test", "since": "2026-10-20T00:00:00Z", "until": "2026-10-30T00:00:00Z",
              "before": "3.68.2", "after": "3.69.0", "by": None, "min_minutes": 30.0, "full": False, "symbolicate": False}
    return argparse.Namespace(**{**values, **overrides})


def run_command(function, capsys, **overrides) -> tuple[int, dict]:
    import asyncio

    code = asyncio.run(function(arguments(**overrides)))
    return code, json.loads(capsys.readouterr().out)


def telemetry_store(tmp_path, monkeypatch, after_minutes: int = 40) -> None:
    write_store(tmp_path, monkeypatch, {
        "aaaaaaaa-telemetry": sampled_run("run-a", DAY, 60, "3.68.2", "3068002"),
        "bbbbbbbb-telemetry": sampled_run("run-b", DAY + datetime.timedelta(hours=26), after_minutes, "3.69.0", "3069000",
                                          "abcdef0123456789"),
        "mk-cccccccc": [metrics_record("day", []), diagnostic_record("hang", DAY + datetime.timedelta(minutes=5), []),
                        diagnostic_record("hang", DAY + datetime.timedelta(hours=26, minutes=5), None)],
    })


def test_compare_command_exit_codes_distinguish_refusal_ambiguity_and_success(tmp_path, monkeypatch, capsys):
    telemetry_store(tmp_path, monkeypatch, after_minutes=10)
    code, refused = run_command(app_telemetry.cmd_compare, capsys)
    assert code == 3 and refused["refused"] is True and "below the minimum 30" in refused["refusals"][0]["reason"]

    code, forced = run_command(app_telemetry.cmd_compare, capsys, min_minutes=5.0)
    assert code == 0 and forced["strata"][0]["measuredMinutes"] == {"before": 60.0, "after": 10.0}
    assert forced["reportsByAttribution"] == {"single": 1}

    code, ambiguous = run_command(app_telemetry.cmd_compare, capsys, before="3.6", after="3.69.0")
    assert code == 2 and "no run" in ambiguous["error"]
    code, same = run_command(app_telemetry.cmd_compare, capsys, before="3.69.0", after="abcdef")
    assert code == 2 and "same build" in same["error"]


def test_states_and_diagnostics_commands_attribute_builds_from_run_headers(tmp_path, monkeypatch, capsys):
    telemetry_store(tmp_path, monkeypatch)
    code, states = run_command(app_telemetry.cmd_states, capsys)
    assert code == 0
    [report] = states["reports"]
    assert report["attributedBuild"]["label"] == "3.68.2 (3068002)"
    assert report["reportedBuild"]["build"] == "3069000"
    groups = {json.dumps(group["states"]): group["builds"] for group in states["diagnostics"]["byActiveStates"]}
    assert groups == {"[]": {"3.68.2 (3068002)": 1}, '"not reported"': {"3.69.0 (3069000) abcdef012": 1}}

    code, listing = run_command(app_telemetry.cmd_diagnostics, capsys)
    assert [item["attributedBuild"]["label"] for item in listing["diagnostics"]] == [
        "3.68.2 (3068002)", "3.69.0 (3069000) abcdef012"]
    code, metrics = run_command(app_telemetry.cmd_metrickit, capsys, full=True)
    assert metrics["reports"][0]["attributedBuild"]["status"] == "single"
    assert metrics["reports"][0]["subintervals"]["attributedBuild"] == "single"
    assert diagnostic(diagnostic_record("hang", DAY, []), "local", "d")["activeStates"] == []
