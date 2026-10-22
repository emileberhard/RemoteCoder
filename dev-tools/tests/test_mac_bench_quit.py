import signal
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from remotecoder_tools import mac_bench


@pytest.mark.parametrize("replacement_at", ["term", "kill", "none", "acquisition", "hung"])
def test_quit_retains_audit_identity_through_term_and_escalation(monkeypatch, replacement_at):
    monkeypatch.syspath_prepend(str(Path(__file__).resolve().parents[2] / "scripts"))
    import process_group as processes

    captured = {"pid": 100, "pgid": 100, "startedAtMicroseconds": 1000000, "pidVersion": 1,
                "auditToken": [0, 501, 20, 501, 20, 100, 0, 1]}
    replacement = captured | {"startedAtMicroseconds": 1000001, "pidVersion": 2,
                              "auditToken": [0, 501, 20, 501, 20, 100, 0, 2]}
    identities = iter([captured, replacement] if replacement_at == "term"
                      else [captured, captured, replacement] if replacement_at == "kill"
                      else [captured, captured, captured] if replacement_at == "hung"
                      else [captured, captured])
    monkeypatch.setattr(processes, "process_identity", lambda _pid: next(identities))
    executable = mac_bench.TARGET / "Contents/MacOS/RemoteCoder"
    monkeypatch.setattr(processes, "audit_path", lambda _identity:
                        Path("/other/application") if replacement_at == "acquisition" else executable)
    monkeypatch.setattr(processes, "audit_alive", lambda _identity: replacement_at in {"kill", "hung"})
    times = iter([0, 20])
    monkeypatch.setattr(mac_bench.time, "monotonic", lambda: next(times))
    monkeypatch.setattr(mac_bench, "running_pids", lambda: [captured["pid"]])
    bare_signal = Mock()
    monkeypatch.setattr(mac_bench.os, "kill", bare_signal)
    pinned_signals = []

    def native_signal(token, signum):
        pinned_signals.append((list(token._obj), signum))
        return 0

    monkeypatch.setattr(processes, "_libproc", lambda: SimpleNamespace(proc_signal_with_audittoken=native_signal))

    mac_bench.quit_app()

    bare_signal.assert_not_called()
    expected = [] if replacement_at in {"term", "acquisition"} else [(captured["auditToken"], signal.SIGTERM)]
    if replacement_at == "hung":
        expected.append((captured["auditToken"], signal.SIGKILL))
    assert pinned_signals == expected
