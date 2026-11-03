import json
import os
import platform
import subprocess
from pathlib import Path

from remotecoder_tools import host_logs
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
