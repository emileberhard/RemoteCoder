import argparse
from types import SimpleNamespace

import pytest

from remotecoder_tools import mac_bench

IDLE = '"HIDIdleTime" = 120000000000'


def settings(monkeypatch, **values):
    monkeypatch.setattr(mac_bench, "maintainer_settings", lambda: values)


def processes(monkeypatch, statuses):
    seen = []

    def run(command, **_kwargs):
        seen.append(command)
        return SimpleNamespace(returncode=statuses[command[-1]])

    monkeypatch.setattr(mac_bench.subprocess, "run", run)
    monkeypatch.setattr(mac_bench.subprocess, "check_output", lambda *_args, **_kwargs: IDLE)
    return seen


@pytest.mark.parametrize(("flag", "role", "local", "error"), [
    (None, "bench-host", "Bench-Host", None),
    ("other-host", "bench-host", "other-host", None),
    (None, "bench-host", "laptop", "require the configured bench host: bench-host"),
    (None, None, "bench-host", "Set --bench-host or maintainer macBenchHost"),
])
def test_bench_host_comes_from_the_flag_or_its_own_maintainer_role(monkeypatch, flag, role, local, error):
    settings(monkeypatch, macGUIHost="laptop", **({"macBenchHost": role} if role else {}))
    monkeypatch.setattr(mac_bench.subprocess, "check_output", lambda *_args, **_kwargs: local + "\n")
    args = argparse.Namespace(bench_host=flag)
    if error is None:
        mac_bench.require_bench_host(args)
    else:
        with pytest.raises(SystemExit, match=error):
            mac_bench.require_bench_host(args)


def test_idle_host_without_configured_busy_processes_is_unused(monkeypatch):
    settings(monkeypatch)
    assert processes(monkeypatch, {}) == []
    mac_bench.require_unused_host()


def test_a_running_configured_process_marks_the_bench_host_in_use(monkeypatch):
    settings(monkeypatch, macBenchBusyProcesses=["Editor", "Stream"])
    seen = processes(monkeypatch, {"Editor": 1, "Stream": 0})
    with pytest.raises(SystemExit, match="in use: Stream is running"):
        mac_bench.require_unused_host()
    assert seen == [["/usr/bin/pgrep", "-x", "Editor"], ["/usr/bin/pgrep", "-x", "Stream"]]


def test_an_unreadable_process_state_is_not_treated_as_unused(monkeypatch):
    settings(monkeypatch, macBenchBusyProcesses=["Stream"])
    processes(monkeypatch, {"Stream": 3})
    with pytest.raises(SystemExit, match="Cannot establish whether Stream is running"):
        mac_bench.require_unused_host()


@pytest.mark.parametrize("value", ["Stream", [""], [1]])
def test_invalid_busy_process_configuration_is_rejected(monkeypatch, value):
    settings(monkeypatch, macBenchBusyProcesses=value)
    processes(monkeypatch, {})
    with pytest.raises(SystemExit, match="must list process names"):
        mac_bench.require_unused_host()


def test_recent_input_still_blocks_a_host_with_no_busy_process(monkeypatch):
    settings(monkeypatch, macBenchBusyProcesses=["Stream"])
    processes(monkeypatch, {"Stream": 1})
    monkeypatch.setattr(mac_bench.subprocess, "check_output", lambda *_args, **_kwargs: '"HIDIdleTime" = 5000000000')
    with pytest.raises(SystemExit, match="HID idle"):
        mac_bench.require_unused_host()
