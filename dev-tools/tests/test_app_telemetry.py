import datetime
import gzip
import json
import subprocess
from pathlib import Path

from remotecoder_tools import app_telemetry, app_telemetry_store, config
from remotecoder_tools.app_telemetry_summary import (
    activity,
    export_costs,
    heaviest_path,
    metrickit_report,
    persistence_runs,
    sample_intervals,
    summarize_segment,
    telemetry_runs,
)


def line(**record) -> bytes:
    return json.dumps(record).encode()


def log(ts: str, subsystem: str, category: str, message: str, level: str = "notice") -> bytes:
    return line(ts=ts, subsystem=subsystem, category=category, level=level, message=message,
                process="RemoteCoder", thread=1)


def persistence(ts: str, owner: str, writes: int, size: int) -> bytes:
    return log(ts, "RemoteCoder", "PersistenceMetrics",
               f"persistence owner={owner} writes={writes} bytes={size} skipped=0 failures=0 "
               f"writesWithoutByteCount=0 milliseconds={writes * 1.5}")


def measured(value: float, unit: str) -> dict:
    return {"value": {"unit": unit, "value": value}}


def daily_report() -> dict:
    def entry(seconds: int, cpu: float, foreground: float) -> dict:
        return {"duration": {"unit": "s", "value": seconds}, "states": [],
                "values": [{"cpuTimeMetric": measured(cpu, "s")}, {"gpuTimeMetric": measured(cpu / 2, "s")},
                           {"totalForegroundTimeMetric": measured(foreground, "s")}]}

    return {
        "recordType": "metrickit", "kind": "metrics", "reportID": "daily", "ts": "2026-10-24T09:38:39.943Z",
        "coverage": {"start": 814399200, "duration": 86400},
        "report": {
            "environment": {"latestApplicationVersion": "3.66.10", "applicationBuildVersion": "3066010",
                            "deviceType": "iPhone18,1", "hasExceededStateLimit": True,
                            "osVersion": {"number": "27.0.1", "buildNumber": "24A446"}},
            "intervalEntries": [entry(86400, 600, 1200), entry(10800, 400, 600), entry(10800, 200, 600)],
            "stateEntries": [],
        },
    }


def test_a_segment_summary_counts_minutes_and_parses_owned_lines():
    summary = summarize_segment([
        log("2026-10-24T10:00:01.000Z", "com.apple.network", "tcp", "x", "info"),
        log("2026-10-24T10:00:59.000Z", "com.apple.network", "tcp", "y", "info"),
        log("2026-10-24T10:01:00.000Z", "RemoteCoder", "Energy", "Energy policy lowPower=false thermalState=2 conserves=true"),
        persistence("2026-10-24T10:01:00.000Z", "checkpoints", 3, 300),
        line(recordType="metrickit", kind="metrics", reportID="r"),
        line(recordType="sample", runID="run", seq=1),
        b"not json",
    ])
    assert summary["records"] == 4
    assert summary["minutes"]["2026-10-24T10:00"] == {"com.apple.network\ttcp\tinfo": 2}
    assert summary["energy"] == [{"ts": "2026-10-24T10:01:00.000Z", "lowPower": False, "thermalState": 2,
                                  "conservesEnergy": True}]
    assert summary["persistence"][0]["bytes"] == 300
    assert [record["recordType"] for record in summary["metrickit"] + summary["telemetry"]] == ["metrickit", "sample"]


def test_daily_rates_come_from_the_daily_entry_and_subintervals_get_no_clock_times():
    report = metrickit_report(daily_report(), "local", "iPhone-test")
    assert report["coverageStart"] == "2026-10-22T22:00:00.000Z"
    assert report["totals"]["cpuTime"] == {"value": 600, "unit": "s"}
    assert report["perForegroundMinute"]["cpuTimeSeconds"] == 30
    assert report["perForegroundMinute"]["gpuTimeSeconds"] == 15
    assert "normalization" in report["perForegroundMinute"]["note"]
    assert [entry["cpuTime"]["value"] for entry in report["subintervals"]["entries"]] == [400, 200]
    assert all("start" not in entry for entry in report["subintervals"]["entries"])
    assert report["flags"] == {"hasExceededStateLimit": True}


def test_persistence_runs_split_at_a_counter_reset_and_count_from_zero_after_it():
    snapshots = summarize_segment([
        persistence("2026-10-24T10:00:00.000Z", "checkpoints", 10, 1_000),
        persistence("2026-10-24T10:00:00.000Z", "drafts", 4, 0),
        persistence("2026-10-24T10:05:00.000Z", "checkpoints", 12, 1_500),
        persistence("2026-10-24T10:05:00.000Z", "drafts", 5, 0),
        persistence("2026-10-24T11:00:00.000Z", "drafts", 9, 0),
        persistence("2026-10-24T11:00:00.000Z", "checkpoints", 2, 200),
    ])["persistence"]
    runs = persistence_runs(snapshots)
    assert [(run["from"], run["startObserved"]) for run in runs] == [
        ("2026-10-24T10:00:00.000Z", False), ("2026-10-24T11:00:00.000Z", True)]
    assert runs[0]["owners"]["checkpoints"]["bytes"] == 500
    assert runs[1]["owners"]["checkpoints"]["bytes"] == 200
    assert runs[1]["owners"]["drafts"]["writes"] == 9


def test_a_crash_follows_its_attributed_thread():
    tree = {"callStackPerThread": True, "callStackThreads": [
        {"threadAttributed": False, "rootFrames": [{"sampleCount": 5, "offsetIntoBinaryTextSegment": 1}]},
        {"threadAttributed": True, "rootFrames": [{"sampleCount": 1, "offsetIntoBinaryTextSegment": 2,
                                                    "subFrames": [{"sampleCount": 1, "offsetIntoBinaryTextSegment": 3}]}]},
    ]}
    assert [frame["offsetIntoBinaryTextSegment"] for frame in heaviest_path(tree)] == [2, 3]


def segment(tmp_path: Path, device: str, name: str, lines: list[bytes]) -> app_telemetry_store.Segment:
    path = tmp_path / "store" / device / f"{name}.jsonl.gz"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(gzip.compress(b"\n".join(lines)))
    status = path.stat()
    return app_telemetry_store.Segment("local", device, name, status.st_size, int(status.st_mtime))


def test_index_entries_go_with_their_source_and_the_oldest_go_first_over_the_cap(tmp_path, monkeypatch):
    monkeypatch.setattr(app_telemetry_store, "INDEX_ROOT", tmp_path / "index")
    old = segment(tmp_path, "iPhone-a", "20261020-001792500000000-aaaaaaaa", [log("2026-10-20T10:00:00.000Z", "s", "c", "m")])
    new = segment(tmp_path, "iPhone-a", "20261024-001792850000000-bbbbbbbb", [log("2026-10-24T10:00:00.000Z", "s", "c", "m")])
    gone = segment(tmp_path, "iPhone-b", "20261024-001792850000000-cccccccc", [log("2026-10-24T10:00:00.000Z", "s", "c", "m")])
    for item in (old, new, gone):
        app_telemetry_store.write_index(item, summarize_segment([]))
    listing = app_telemetry_store.StoreListing("local", (old, new), None)
    reclaimed = app_telemetry_store.reclaim_index([listing])
    assert reclaimed.stale_entries == 1 and not gone.index_path.exists()
    monkeypatch.setattr(app_telemetry_store, "INDEX_BYTE_CAP", new.index_path.stat().st_size)
    reclaimed = app_telemetry_store.reclaim_index([listing])
    assert reclaimed.evicted_entries == 1 and not old.index_path.exists() and new.index_path.exists()


def test_a_failed_listing_keeps_its_index(tmp_path, monkeypatch):
    monkeypatch.setattr(app_telemetry_store, "INDEX_ROOT", tmp_path / "index")
    item = segment(tmp_path, "iPhone-a", "20261024-001792850000000-aaaaaaaa", [])
    app_telemetry_store.write_index(item, summarize_segment([]))
    app_telemetry_store.reclaim_index([app_telemetry_store.StoreListing("local", None, "unreachable")])
    assert item.index_path.exists()


def test_a_changed_segment_is_indexed_again(tmp_path, monkeypatch):
    monkeypatch.setattr(app_telemetry_store, "INDEX_ROOT", tmp_path / "index")
    item = segment(tmp_path, "iPhone-a", "20261024-001792850000000-aaaaaaaa", [])
    app_telemetry_store.write_index(item, summarize_segment([]))
    changed = app_telemetry_store.Segment(item.host, item.device, item.name, item.size + 1, item.mtime)
    assert app_telemetry_store.read_index(item) is not None
    assert app_telemetry_store.read_index(changed) is None


def test_a_tailscale_address_of_this_mac_is_local(monkeypatch):
    answer = json.dumps({"Self": {"DNSName": "mini.tail.ts.net.", "TailscaleIPs": ["100.64.0.1"]}})
    monkeypatch.setattr(config.socket, "gethostname", lambda: "mini.local")
    monkeypatch.setattr(config.subprocess, "run",
                        lambda *args, **kwargs: subprocess.CompletedProcess(args, 0, stdout=answer))
    assert config._matches_local_identity("100.64.0.1")
    assert not config._matches_local_identity("100.64.0.2")


def sample(seq: int, seconds: float, cpu_ms: int, reason: str = "interval", battery: int = 80, mixed: bool = False,
           **context) -> dict:
    state = {"scene": "active", "surface": "chat", "turnRunningVisible": False, "voiceCall": False,
             "lowPower": False, "charging": False, "batteryPercent": battery, **context}
    return {"recordType": "sample", "runID": "run-1", "seq": seq, "reason": reason, "mixed": mixed,
            "ts": f"2026-10-24T10:{int(seconds) // 60:02d}:{int(seconds) % 60:02d}.000Z",
            "monoNs": int(seconds * 1e9), "cpuUserNs": cpu_ms * 1_000_000, "cpuSystemNs": 0,
            "interruptWakeups": seq * 10, "idleWakeups": 0, "timerWakeups": 0, "footprintBytes": 100 + seq,
            "persistence": {"checkpoints": {"writes": seq, "bytes": seq * 1000}}, "context": state}


def run_records() -> list[dict]:
    return [
        {"recordType": "run", "runID": "run-1", "appVersion": "3.67.0", "flushedThroughSeq": 2},
        sample(1, 0, 0, "launch"),
        sample(2, 30, 3000, battery=79),
        sample(2, 30, 3000, battery=79),
        sample(3, 40, 3500, "context", battery=79, turnRunningVisible=True),
        sample(4, 41, 3700, "context", battery=79, mixed=True),
        sample(5, 60, 4000, "background", battery=79, scene="background"),
        sample(6, 660, 4600, "foreground", battery=75),
        sample(8, 690, 5000, battery=75),
        sample(9, 790, 5100, battery=75),
        {"recordType": "export", "runID": "run-1", "seq": 10, "ts": "2026-10-24T10:10:00.000Z", "reason": "interval",
         "totalMs": 120.0, "scanMs": 80.0, "processCpuNs": 510_000_000, "footprintBefore": 100,
         "footprintSampledMax": 150},
        {"recordType": "export", "runID": "run-1", "seq": 11, "ts": "2026-10-24T10:13:20.000Z", "reason": "interval",
         "totalMs": 100.0, "processCpuNs": 9_000_000_000},
    ]


def test_sample_intervals_keep_background_gaps_and_mixed_states_apart():
    [run] = telemetry_runs(run_records())
    intervals = sample_intervals(run["records"])

    assert run["missingRecords"] == 1
    assert run["header"] == {"runID": "run-1", "appVersion": "3.67.0"}
    assert [interval["kind"] for interval in intervals] == [
        "measured", "measured", "mixed", "measured", "background", "incomplete", "gap"]
    assert intervals[0]["cpuSeconds"] == 3.0
    assert intervals[0]["persistenceBytes"] == {"checkpoints": 1000}
    assert intervals[2]["context"]["turnRunningVisible"] is True
    assert intervals[4]["seconds"] == 600 and intervals[4]["cpuSeconds"] == 0.6


def test_missing_records_outrank_a_background_start():
    records = [sample(1, 0, 0, "background", scene="background"), sample(3, 600, 900, "foreground")]
    assert [interval["kind"] for interval in sample_intervals(records)] == ["incomplete"]


def test_activity_sums_each_state_kind_apart():
    [run] = telemetry_runs(run_records())
    rows = {(row["kind"], row["state"]["turnRunningVisible"]): row
            for row in activity(sample_intervals(run["records"]))}

    idle = rows[("measured", False)]
    assert (idle["intervals"], idle["seconds"], idle["cpuSeconds"]) == (3, 59.0, 3.8)
    assert idle["cpuPercent"] == round(3.8 / 59 * 100, 2)
    assert idle["wakeupsPerSecond"]["interruptWakeups"] == round(30 / 59, 2)
    assert rows[("mixed", True)]["seconds"] == 1.0
    assert rows[("background", False)]["cpuSeconds"] == 0.6


def test_export_share_counts_only_exports_inside_the_sampled_coverage():
    cost = export_costs(telemetry_runs(run_records()))

    assert cost["reasons"]["interval"]["exports"] == 2
    assert cost["reasons"]["interval"]["stageMs"]["scan"] == 80.0
    assert cost["reasons"]["interval"]["sampledFootprintGrowthBytes"] == 50
    assert cost["sampledProcessCpuSeconds"] == 5.1
    assert cost["exportShareOfSampledCpu"] == 0.1
    assert cost["exportsOutsideSampledCoverage"] == 1
    assert cost["sampler"]["samples"] == 8


def test_metrickit_reports_are_selected_and_checked_by_coverage():
    received_next_day = {"coverageStart": "2026-10-22T22:00:00.000Z", "coverageSeconds": 86400,
                         "receivedAt": "2026-10-24T09:38:39.943Z"}
    assert app_telemetry._overlaps(received_next_day, "2026-10-23T00:00:00.000Z", "2026-10-24T00:00:00.000Z")
    assert not app_telemetry._overlaps(received_next_day, "2026-10-24T00:00:00.000Z", "2026-10-25T00:00:00.000Z")
    received_days_later = app_telemetry_store.Segment("local", "iPhone-a", "20261029-001792500000000-mk-r1", 10, 0)
    assert app_telemetry._wanted(received_days_later, 1_792_000_000, 1_792_100_000)
    log_then = app_telemetry_store.Segment("local", "iPhone-a", "20261029-001792500000000-aaaaaaaa", 10, 0)
    assert not app_telemetry._wanted(log_then, 1_792_000_000, 1_792_100_000)

    stockholm_day = app_telemetry._uncovered([received_next_day], "2026-10-22T22:00:00.000Z",
                                             "2026-10-23T22:00:00.000Z", datetime.datetime(2026, 10, 25, tzinfo=datetime.UTC))
    assert stockholm_day["missing"] == stockholm_day["notYetDue"] == []
    later = app_telemetry._uncovered([received_next_day], "2026-10-21T00:00:00.000Z", "2026-10-25T00:00:00.000Z",
                                     datetime.datetime(2026, 10, 25, 15, tzinfo=datetime.UTC))
    assert later["missing"] == [{"from": "2026-10-21T00:00:00.000Z", "until": "2026-10-22T22:00:00.000Z"},
                                {"from": "2026-10-23T22:00:00.000Z", "until": "2026-10-24T03:00:00.000Z"}]
    assert later["notYetDue"] == [{"from": "2026-10-24T03:00:00.000Z", "until": "2026-10-25T00:00:00.000Z"}]


def test_an_oversized_segment_is_reported_unreadable(monkeypatch):
    monkeypatch.setattr(app_telemetry_store, "EXPANDED_SEGMENT_BYTE_CAP", 64)
    summary = app_telemetry_store._summarize_bytes(gzip.compress(b"x" * 100 + b"\n"))
    assert summary["unreadable"].startswith("UnreadableSegment")
    assert "records" in app_telemetry_store._summarize_bytes(gzip.compress(b"{}\n" * 10))


def test_a_local_listing_reads_the_gateway_cap_marker(tmp_path, monkeypatch):
    monkeypatch.setattr(app_telemetry_store.Path, "home", lambda: tmp_path)
    root = tmp_path / app_telemetry_store.APP_LOG_DIRECTORY
    (root / "iPhone-a").mkdir(parents=True)
    (root / "iPhone-a" / "20261024-001792850000000-aaaaaaaa-telemetry.jsonl.gz").write_bytes(gzip.compress(b""))
    (root / "retention.json").write_text(json.dumps({"evictedThroughMs": 1_792_850_000_000, "files": 0, "met": False,
                                                     "atMs": 1_792_850_000_000, "retainedBytes": None,
                                                     "capBytes": 1024, "unreadableEntries": 1}))

    listing = app_telemetry_store.list_store("local")

    assert [segment.kind for segment in listing.segments] == ["telemetry"]
    assert app_telemetry._cap_state(listing) == {
        "capEvictedThrough": "2026-10-24T13:53:20.000Z",
        "capUnmet": {"checkedAt": "2026-10-24T13:53:20.000Z", "retainedBytes": None, "capBytes": 1024,
                     "unreadableEntries": 1},
    }
