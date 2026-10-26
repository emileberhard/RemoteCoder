import json
from types import SimpleNamespace

from remotecoder_tools import perf_calibration
from remotecoder_tools.perf_calibration import calibration_sources


def test_calibration_mapping_keeps_conversation_order_when_first_open_is_another_stream():
    scenario = {"conversations": [{"thread": {"id": thread}} for thread in ("first", "second", "third", "sidebar-only")],
                "actions": [{"kind": "toggleSidebar", "threadID": "first"},
                            {"kind": "open", "threadID": "second"},
                            {"kind": "open", "threadID": "first"},
                            {"kind": "open", "threadID": "third"}]}
    assert calibration_sources(scenario) == ["first", "second", "third"]


def test_calibration_preflight_uses_initial_action_target(tmp_path, monkeypatch):
    prompt = tmp_path / "prompt.txt"
    prompt.write_text("Synthetic calibration input")
    fixture = tmp_path / "scenario.json"
    fixture.write_text(json.dumps({"conversations": [{"thread": {"id": thread}} for thread in ("initial", "other")],
                                   "actions": [{"kind": "scroll", "threadID": "initial"},
                                               {"kind": "open", "threadID": "other"}]}))
    args = SimpleNamespace(out=str(tmp_path / "output"), prompt_file=str(prompt), fixture=str(fixture),
                           thread=["source-initial", "source-other"])
    monkeypatch.setattr(perf_calibration, "_resolve_config", lambda _: "synthetic-config")
    assert perf_calibration.prepare(args) == (tmp_path / "output", "synthetic-config", prompt.read_text(), fixture.read_bytes())
