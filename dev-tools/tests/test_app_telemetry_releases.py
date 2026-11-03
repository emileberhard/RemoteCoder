import json
import os
import platform
import subprocess
from pathlib import Path

from remotecoder_tools import app_telemetry_store, host_logs
from remotecoder_tools.app_telemetry_releases import MIB, release_rows
from remotecoder_tools.app_telemetry_summary import telemetry_runs


def header(run_id: str, version: str) -> dict:
    return {"recordType": "run", "runID": run_id, "appVersion": version, "build": version.replace(".", ""),
            "sourceCommit": "abc12345"}


def sample(run_id: str, seq: int, seconds: int, cpu_ms: int, footprint_mib: int, checkpoint_bytes: int,
           **context) -> dict:
    state = {"scene": "active", "surface": "chat", "turnRunningVisible": False, "voiceCall": False,
             "lowPower": False, **context}
    return {"recordType": "sample", "runID": run_id, "seq": seq, "reason": "interval", "mixed": False,
            "ts": f"2026-11-03T10:{seconds // 60:02d}:{seconds % 60:02d}.000Z", "monoNs": seconds * 1_000_000_000,
            "cpuUserNs": cpu_ms * 1_000_000, "cpuSystemNs": 0, "interruptWakeups": seconds * 2, "idleWakeups": 0,
            "timerWakeups": 0, "footprintBytes": footprint_mib * MIB,
            "persistence": {"checkpoints": {"writes": seq, "bytes": checkpoint_bytes}}, "context": state}


def test_releases_split_each_build_by_surface_and_count_drawer_visits():
    records = [
        header("a", "3.92.0"),
        sample("a", 1, 0, 0, 100, 0),
        sample("a", 2, 30, 3000, 110, 1_000_000, turnRunningVisible=True),
        sample("a", 3, 60, 6000, 120, 2_000_000, surface="drawer"),
        sample("a", 4, 70, 8000, 130, 2_000_000),
        sample("a", 5, 100, 9500, 140, 2_000_000, surface="drawer"),
        sample("a", 6, 105, 10000, 140, 3_000_000),
        header("b", "3.93.0"),
        sample("b", 1, 200, 0, 90, 0, scene="background"),
        sample("b", 2, 230, 500, 90, 0),
    ]

    first, second = release_rows(telemetry_runs(records))

    assert first["build"]["appVersion"] == "3.92.0"
    assert first["lowData"] is True
    assert first["chat"]["minutes"] == 1.5
    assert first["chat"]["cpuPercent"] == 8.33
    assert first["chat"]["turnVisible"] == {"minutes": 0.5, "cpuPercent": 10.0}
    assert first["chat"]["noTurnVisible"] == {"minutes": 1.0, "cpuPercent": 7.5}
    assert first["chat"]["interruptWakeupsPerSecond"] == 2.0
    assert first["drawer"]["visits"] == 2
    assert first["drawer"]["cpuSecondsPerVisit"] == 1.25
    assert first["footprintMiB"] == {"intervals": 5, "median": 130.0, "p95": 140.0}
    assert first["diskMBPerActiveHour"] == {"total": 102.9, "byOwner": {"checkpoints": 102.9}}

    assert second["build"]["appVersion"] == "3.93.0"
    assert second["activeMinutes"] == 0
    assert second["chat"]["cpuPercent"] is None
    assert second["drawer"] == {"minutes": 0, "cpuPercent": None, "visits": 0, "cpuSecondsPerVisit": None}
    assert second["footprintMiB"]["median"] is None
    assert second["diskMBPerActiveHour"] == {"total": None, "byOwner": {}}


RUN_LOOP_BOUNDS = ("17", "33", "50", "100", "250", "500", "1000", "2000")
SWITCH_BOUNDS = ("50", "100", "150", "200", "300", "500", "750", "1000", "2000", "4000")


def responsive_sample(seq: int, seconds: int, cpu_ms: int, main_ms: int, busy_ms: int, hang_ms: int,
                      at_least: list[int], turn_seconds: int | None, streamed: tuple[int, int],
                      switches: list[int]) -> dict:
    record = sample("c", seq, seconds, cpu_ms, 100, 0)
    workload = {"streamedDeltas": streamed[0], "streamedBytes": streamed[1]}
    if turn_seconds is not None:
        workload |= {"runningTurns": 1, "runningTurnNs": turn_seconds * 1_000_000_000}
    return record | {
        "mainThreadCpuNs": main_ms * 1_000_000,
        "runLoop": {"busyNs": busy_ms * 1_000_000, "busyPeriods": seq * 50, "hangNs": hang_ms * 1_000_000,
                    "busyPeriodsAtLeastMs": dict(zip(RUN_LOOP_BOUNDS, at_least, strict=True))},
        "switches": {"completed": switches[-1], "abandoned": 0, "completedNs": 0,
                     "completedWithinMs": dict(zip(SWITCH_BOUNDS, switches, strict=True))},
        "workload": workload,
    }


def test_releases_read_main_thread_workload_and_switches_and_keep_older_builds_unknown():
    records = [
        header("old", "3.92.0"),
        sample("old", 1, 0, 0, 100, 0),
        sample("old", 2, 30, 300, 100, 0),
        header("c", "3.94.0"),
        responsive_sample(1, 0, 0, 0, 0, 0, [0] * 8, None, (0, 0), [0] * 10),
        responsive_sample(2, 30, 3000, 1500, 3000, 300, [10, 5, 3, 2, 1, 0, 0, 0], 0, (10, 1000),
                          [0, 0, 1, 1, 1, 1, 1, 1, 1, 1]),
        responsive_sample(3, 60, 4500, 2100, 3900, 300, [11, 5, 3, 2, 1, 0, 0, 0], 90, (40, 7000),
                          [0, 1, 2, 2, 2, 3, 3, 3, 3, 3]),
        responsive_sample(4, 90, 5400, 2400, 4200, 300, [11, 5, 3, 2, 1, 0, 0, 0], 120, (40, 7000),
                          [0, 1, 2, 2, 2, 3, 3, 3, 3, 3]),
    ]

    rows = {row["build"]["appVersion"]: row for row in release_rows(telemetry_runs(records))}
    old, new = rows["3.92.0"], rows["3.94.0"]

    assert new["mainThread"] == {"minutes": 1.5, "cpuPercent": 2.67, "busyPercent": 4.67, "blockedPercent": 2.0,
                                 "stallsPerActiveHour": {"atLeast100Ms": 80.0, "atLeast250Ms": 40.0},
                                 "hangSecondsPerActiveHour": 12.0}
    assert new["workload"] == {"minutes": 1.0, "averageRunningTurns": 2.0, "streamedDeltasPerMinute": 30.0,
                               "streamedKBPerMinute": 6.0}
    assert new["chat"]["likeForLike"] == {"maxRunningTurns": 2, "minutes": 0.5, "cpuPercent": 3.0}
    assert new["switches"] == {"intervals": 3, "completed": 3, "abandoned": 0, "p50Ms": 150, "p90Ms": 500}

    assert old["mainThread"]["minutes"] == 0
    assert old["mainThread"]["cpuPercent"] is None
    assert old["mainThread"]["stallsPerActiveHour"] == {"atLeast100Ms": None, "atLeast250Ms": None}
    assert old["workload"] == {"minutes": 0, "averageRunningTurns": None, "streamedDeltasPerMinute": None,
                               "streamedKBPerMinute": None}
    assert old["chat"]["likeForLike"]["cpuPercent"] is None
    assert old["switches"] == {"intervals": 0, "completed": 0, "abandoned": 0, "p50Ms": None, "p90Ms": None}


def resolve_root(tmp_path: Path, path: str) -> subprocess.CompletedProcess:
    command = host_logs.log_root_shell() + f'printf %s "${host_logs.LOG_ROOT_VARIABLE}"'
    return subprocess.run(["sh", "-c", command], env={"HOME": str(tmp_path), "PATH": path},
                          capture_output=True, text=True, check=False)


def test_the_shell_resolves_the_same_log_root_as_python(tmp_path, monkeypatch):
    monkeypatch.setattr(host_logs.Path, "home", lambda: tmp_path)
    roots = json.loads(host_logs.LOG_ROOTS.read_text())["logRoots"]

    result = resolve_root(tmp_path, os.environ["PATH"])

    assert result.returncode == 0, result.stderr
    assert result.stdout == str(tmp_path / roots[platform.system()])
    assert host_logs.local_log_root() == tmp_path / roots[platform.system()]


def test_an_os_without_a_log_root_fails_instead_of_guessing(tmp_path):
    fake = tmp_path / "bin"
    fake.mkdir()
    (fake / "uname").write_text("#!/bin/sh\necho Plan9\n")
    (fake / "uname").chmod(0o755)

    result = resolve_root(tmp_path, f"{fake}:{os.environ['PATH']}")

    assert result.returncode == host_logs.UNSUPPORTED_OS_EXIT
    assert "Plan9" in result.stderr


def test_stores_come_from_every_cluster_gateway_except_this_host(tmp_path, monkeypatch):
    (tmp_path / "gateway").mkdir()
    (tmp_path / "gateway/routes.json").write_text(json.dumps({"routes": {
        "a": "wss://this-mac.example.ts.net:8789/ws",
        "b": "wss://linux-box.example.ts.net:8788/ws",
        "c": "wss://other-mac.example.ts.net:8789/ws",
    }}))
    (tmp_path / "maintainer.json").write_text(json.dumps({"clusterRoutes": "gateway/routes.json"}))
    monkeypatch.setenv("RC_MAINTAINER_CONFIG", str(tmp_path / "maintainer.json"))
    monkeypatch.setattr(app_telemetry_store, "_matches_local_identity", lambda name: name.startswith("this-mac."))
    monkeypatch.setattr(app_telemetry_store, "_tailnet_host_name", lambda name: name.split(".")[0])

    assert app_telemetry_store.configured_hosts() == [app_telemetry_store.LOCAL, "linux-box", "other-mac"]
