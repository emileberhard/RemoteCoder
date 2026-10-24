import gzip
import json
import subprocess
from pathlib import Path

from symbols import SymbolFile

from remotecoder_tools import app_telemetry, app_telemetry_store, config
from remotecoder_tools.app_telemetry_summary import (
    heaviest_path,
    metrickit_report,
    persistence_runs,
    summarize_segment,
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


def test_symbolication_uses_the_load_address_shared_by_a_binarys_frames(monkeypatch):
    calls = []
    monkeypatch.setattr(app_telemetry, "symbol_files",
                        lambda paths, extra: {"APP": SymbolFile(Path("/x/RemoteCoder"), "arm64")})
    monkeypatch.setattr(app_telemetry, "atos",
                        lambda file, base, addresses: calls.append((base, addresses)) or [("f",)] * len(addresses))
    stack = [
        {"binary": "RemoteCoder", "uuid": "APP", "address": 0x100003000, "offset": 0x3000},
        {"binary": "RemoteCoder", "uuid": "APP", "address": 0x100004001, "offset": 0x4000},
        {"binary": "RemoteCoder", "uuid": "APP", "address": 0x100005000, "offset": 0x5000},
        {"binary": "Foundation", "uuid": "SYS", "address": 0x180000010, "offset": 0x10},
    ]
    item = {"heaviestStack": stack, "symbolSource": {"deviceType": "iPhone0,0", "osVersion": "0", "osBuild": "0"}}
    result = app_telemetry._symbolicate([item])
    assert calls == [(0x100000000, [0x100003000, 0x100004000, 0x100005000])]
    assert result == {"symbolicatedBinaries": 1, "binariesWithoutSymbols": ["Foundation"]}
    assert stack[0]["symbols"] == ["f"] and "symbols" not in stack[3]


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
