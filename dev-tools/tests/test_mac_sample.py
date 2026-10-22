import argparse
import json
import re
from pathlib import Path

import pytest

from remotecoder_tools import mac_bench
from remotecoder_tools.mac_sample import focus_sample, read_sample, summarize_sample


@pytest.fixture(autouse=True)
def benchmark_operator_settings(monkeypatch):
    monkeypatch.setattr(mac_bench, "maintainer_settings", lambda: {
        "macGUIHost": "gui-host", "macBenchmarkGatewayId": "11111111-2222-4333-8444-555555555555",
    })


FIXTURE = Path(__file__).parent / "fixtures/mac-sample.txt"


def by_name(rows):
    return {row["name"]: row for row in rows}


def test_main_attribution_partitions_busy_stacks_and_keeps_inclusive_shares():
    summary = summarize_sample(FIXTURE)
    assert (summary["mainSamples"], summary["busySamples"], summary["idleSamples"]) == (100, 90, 10)
    assert summary["intervalMs"] == 5
    categories = by_name(summary["categories"])
    assert {name: row["samples"] for name, row in categories.items()} == {
        "displayCycle": 40, "eventDispatch": 15, "runLoopSources": 10,
        "appCode": 10, "textLayout": 5, "swiftuiGraph": 5, "other": 5,
    }
    assert sum(row["busyShare"] for row in categories.values()) == pytest.approx(1)
    assert sum(row["mainShare"] for row in categories.values()) == pytest.approx(0.9)
    assert {row["name"]: row["samples"] for row in categories["displayCycle"]["children"]} == {
        "swiftuiLayout": 20, "cursorHitTest": 10, "constraintLayout": 5, "render": 3, "other": 2,
    }
    assert {row["name"]: row["samples"] for row in categories["eventDispatch"]["children"]} == {
        "hitTest": 6, "scrollWheel": 4, "other": 5,
    }
    assert {row["name"]: row["samples"] for row in categories["runLoopSources"]["children"]} == {
        "swiftTasks": 6, "mainQueue": 4,
    }
    worker = by_name(categories["appCode"]["children"])["Worker"]
    assert worker["samples"] == 10
    app = {row["symbol"]: row for row in summary["appFrames"]}
    assert app["Worker.compute() [RemoteCoder]"]["samples"] == 14
    assert app["Worker.compute() [RemoteCoder]"]["busyShare"] == pytest.approx(14 / 90)
    assert dict(summary["selfTop"])["??? [AppKit]"] == 5


def test_focus_combines_call_sites_without_counting_recursive_matches_twice():
    focus = focus_sample(read_sample(FIXTURE), re.compile(r"Worker\.compute"), 2)
    assert focus["samples"] == 14
    assert focus["mainShare"] == 0.14
    assert focus["selfSamples"] == 8
    callers = by_name(focus["callers"])
    assert callers["main [RemoteCoder]"]["samples"] == 10
    assert callers["_dispatch_main_queue_callback_4CF [libdispatch.dylib]"]["samples"] == 4
    callees = by_name(focus["callees"])
    recursive = callees["Worker.compute() [RemoteCoder]"]
    assert recursive["samples"] == 6
    assert recursive["focusShare"] == pytest.approx(6 / 14)
    assert recursive["children"][0]["name"] == "malloc [libsystem_malloc.dylib]"
    assert not recursive["children"][0]["children"]


@pytest.mark.parametrize("text, expected", [
    ("No call graph", "no main thread"),
    ("    2 Thread_1: Main Thread\n    + 3 work  (in RemoteCoder)\n", "child counts exceed parent"),
    ("    2 Thread_1: Main Thread\n    + not a counted frame\n", "unrecognized main-thread sample line"),
])
def test_invalid_sample_reports_an_error_instead_of_inventing_coverage(tmp_path, text, expected):
    path = tmp_path / "sample.txt"
    path.write_text(text)
    assert expected in summarize_sample(path)["error"]


def test_only_run_loop_waits_are_idle_and_unwound_samples_stay_other(tmp_path):
    path = tmp_path / "sample.txt"
    path.write_text("""    10 Thread_1: Main Thread
    + 8 main  (in RemoteCoder)
    + ! 5 __CFRunLoopServiceMachPort  (in CoreFoundation)
    + ! : 5 mach_msg2_trap  (in libsystem_kernel.dylib)
    + ! 3 blockingRPC  (in RemoteCoder)
    + ! : 3 mach_msg2_trap  (in libsystem_kernel.dylib)
""")
    summary = summarize_sample(path)
    assert summary["idleSamples"] == 5
    assert summary["busySamples"] == 5
    assert by_name(summary["categories"])["other"]["samples"] == 5
    assert summary["intervalMs"] is None
    path.write_text("""    5 Thread_1: Main Thread
    + 5 __CFRunLoopServiceMachPort  (in CoreFoundation)
    + ! 5 mach_msg2_trap  (in libsystem_kernel.dylib)
""")
    summary = summarize_sample(path)
    assert summary["busySamples"] == 0
    assert summary["categories"] == [{"name": "other", "samples": 0, "mainShare": 0, "busyShare": None, "children": []}]


def test_profile_cli_reads_saved_label_and_limits_focus_depth(tmp_path, monkeypatch, capsys):
    run = tmp_path / "runs/mac-bench-fixture"
    run.mkdir(parents=True)
    (run / "sample.txt").write_bytes(FIXTURE.read_bytes())
    (run / "receipt.json").write_text(json.dumps({"label": "fixture"}))
    monkeypatch.setattr(mac_bench, "bench_runs", lambda: tmp_path / "runs")
    monkeypatch.setattr("sys.argv", ["mac-bench", "profile", "fixture", "--focus", "Worker.compute", "--depth", "1"])
    mac_bench.main()
    output = capsys.readouterr().out
    assert "100 main samples, 90 busy, 10 idle; 5 ms" in output
    assert "44.4% busy   40.0% main      40  displayCycle" in output
    assert "14 samples (14.0% main), 8 self" in output
    assert "malloc" not in output
    assert not (run / "summary.json").exists()


@pytest.mark.parametrize("stream", [None, {
    "kind": "code", "seconds": 10, "charsPerTick": 60, "tickMs": 30,
    "expectedTicks": 334, "expectedCharacters": 20040,
}])
@pytest.mark.parametrize("metric", [1, 0, None])
def test_analyze_preserves_sample_attribution_and_metric_availability(tmp_path, capsys, stream, metric):
    (tmp_path / "sample.txt").write_bytes(FIXTURE.read_bytes())
    report = {
        "label": "fixture", "build": "test", "messages": 1, "loadMs": 1,
        "display": {"width": 1797, "height": 1162, "scale": 2, "maximumFramesPerSecond": 100},
        "measurementHost": "fixture-macbook", "window": {}, "transcript": {}, "measureStart": 0,
        "measureEnd": 0.02, "analysisScope": "window", "events": [], "stream": stream,
        "frames": [[0, 0.01, 0.001, 0.001, 0.001, 0, 0, 100], [0.01, 0.02, 0.001, 0.001, 0.001, 0, 0, 100]],
        "processCPUms": metric, "mainThreadCPUms": metric,
        "footprintStartMB": metric, "footprintEndMB": metric, "thermalState": 0,
        "launchEnvironment": {"SENTINEL_SECRET": "fixture-secret-must-not-reach-summary"},
    }
    (tmp_path / "report.json").write_text(json.dumps(report))
    mac_bench.analyze(argparse.Namespace(runs=[tmp_path]))
    summary = json.loads((tmp_path / "summary.json").read_text())
    assert summary["sample"]["intervalMs"] == 5
    assert summary["stream"] == stream
    assert summary["processCPUms"] == metric
    assert summary["mainThreadCPUms"] == metric
    assert summary["footprintMB"] == [metric, metric]
    spread = mac_bench.spread([summary])
    if metric is None:
        assert "mainCPUms" not in spread
    else:
        assert spread["mainCPUms"] == {"mean": metric, "min": metric, "max": metric}
    assert by_name(summary["sample"]["categories"])["displayCycle"]["samples"] == 40
    output = capsys.readouterr()
    assert json.loads(output.out)["label"] == "fixture"
    assert "displayCycle 44.4%" in output.err
    assert "fixture-secret-must-not-reach-summary" not in output.out + output.err
    assert "SENTINEL_SECRET" not in (tmp_path / "summary.json").read_text()


@pytest.mark.parametrize(("field", "changed"), [
    ("width", 1920), ("height", 1080), ("scale", 1), ("maximumFramesPerSecond", 60),
])
def test_comparison_rejects_a_different_display_condition(field, changed):
    mode = mac_bench.expected_display("1797x1162@120/2")
    before = {"display": mode, "refreshHz": 120, "measurementHost": "fixture-macbook"}
    after = before | {"display": mode | {field: changed}}
    with pytest.raises(SystemExit, match="different or unknown display"):
        mac_bench.require_matching_displays([before, after])


@pytest.mark.parametrize("changed", [
    {"measurementHost": "fixture-mini"}, {"measurementHost": None},
    {"refreshHz": 60}, {"display": {}},
])
def test_comparison_rejects_unknown_or_inconsistent_measurement_context(changed):
    before = {"display": mac_bench.expected_display("1797x1162@120/2"),
              "refreshHz": 120, "measurementHost": "fixture-macbook"}
    with pytest.raises(SystemExit):
        mac_bench.require_matching_displays([before, before | changed])


@pytest.mark.parametrize(("options", "kind", "gesture_count"), [
    ([], None, 8),
    (["--stream", "10", "--pattern", "idle"], "mixed", 0),
    (["--stream", "10", "--pattern", "idle", "--stream-kind", "paragraph"], "paragraph", 0),
    (["--stream", "10", "--pattern", "idle", "--stream-kind", "code"], "code", 0),
    (["--stream", "10", "--pattern", "idle", "--stream-kind", "table"], "table", 0),
    (["--stream", "10", "--pattern", "idle", "--stream-kind", "fit-table"], "fit-table", 0),
    (["--stream", "10", "--pattern", "idle", "--stream-kind", "table-appearance"], "table-appearance", 0),
    (["--stream", "10", "--stream-scroll", "--pattern", "idle"], "mixed", 8),
    (["--stream", "10", "--pattern", "deep", "--stream-scroll", "--stream-kind", "code", "--repeat", "2"], "code", 16),
])
def test_stream_cli_builds_deterministic_plan(options, kind, gesture_count, monkeypatch):
    captured = {}
    monkeypatch.setattr(mac_bench, "run", lambda args: captured.update(mac_bench.plan(args, "fixture")))
    monkeypatch.setattr("sys.argv", ["mac-bench", "run", "--thread", "thread-1", *options])
    mac_bench.main()
    assert captured["thread"] == "thread-1"
    assert len(captured["gestures"]) == gesture_count
    if gesture_count:
        assert {gesture["velocity"] for gesture in captured["gestures"]} == {-2600, 2600}
    if kind is None:
        assert "stream" not in captured
    else:
        assert captured["stream"] == {"kind": kind, "seconds": 10, "charsPerTick": 60, "tickMs": 30}
        assert captured["tailSeconds"] == 0.6


def test_cli_keeps_measurement_mode_explicit(monkeypatch):
    captured = {}
    monkeypatch.setattr(mac_bench, "run", lambda args: captured.update(mac_bench.plan(args, "fixture")))
    monkeypatch.setattr("sys.argv", ["mac-bench", "run", "--thread", "owned-probe",
                                   "--expected-display", "1797x1162@120/2", "--appearance", "dark", "--tail", "45",
                                   "--scrollbars", "Always"])
    mac_bench.main()
    assert captured["host"] == "11111111-2222-4333-8444-555555555555"
    assert captured["expectedDisplay"] == {"width": 1797, "height": 1162, "scale": 2, "maximumFramesPerSecond": 120}
    assert captured["appearance"] == "dark"
    assert captured["scrollbars"] == "Always"
    assert captured["tailSeconds"] == 45


@pytest.mark.parametrize("host", ["", "other-gateway", "not-a-uuid"])
def test_cli_rejects_invalid_gateway_identity_before_a_run(host, monkeypatch):
    monkeypatch.setattr(mac_bench, "run", lambda args: mac_bench.plan(args, "fixture"))
    monkeypatch.setattr("sys.argv", ["mac-bench", "run", "--thread", "owned-probe", "--host", host])
    with pytest.raises(SystemExit, match="gateway UUID"):
        monkeypatch.setattr(mac_bench, "maintainer_settings", lambda: {})
        mac_bench.main()


def test_cold_table_fixture_plan_keeps_scroll_gestures_without_stream(monkeypatch):
    captured = {}
    monkeypatch.setattr(mac_bench, "run", lambda args: captured.update(mac_bench.plan(args, "fixture")))
    monkeypatch.setattr("sys.argv", ["mac-bench", "run", "--thread", "owned-probe",
                                   "--fixture", "cold-table", "--pattern", "deep"])
    mac_bench.main()
    assert captured["fixture"] == "cold-table"
    assert "stream" not in captured
    assert captured["checkInteraction"] is None
    assert captured["gestures"] == mac_bench.PATTERNS["deep"]


@pytest.mark.parametrize(("options", "error"), [
    (["--stream-kind", "paragraph"], "require --stream SECONDS"),
    (["--stream-scroll"], "require --stream SECONDS"),
    (["--pattern", "idle", "--check-interaction", "cancelled-momentum", "--stream", "6"], "does not support --stream"),
    (["--fixture", "cold-table", "--stream", "10"], "--fixture requires scrolling"),
    (["--fixture", "cold-table", "--pattern", "idle"], "--fixture requires scrolling"),
    (["--fixture", "cold-table", "--check-interaction", "cancelled-momentum"], "--fixture requires scrolling"),
])
def test_stream_options_reject_unsupported_combinations(options, error, monkeypatch):
    monkeypatch.setattr(mac_bench, "run", lambda args: mac_bench.plan(args, "fixture"))
    monkeypatch.setattr("sys.argv", ["mac-bench", "run", "--thread", "thread-1", *options])
    with pytest.raises(SystemExit, match=error):
        mac_bench.main()
