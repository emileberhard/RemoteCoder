import argparse
import json

import pytest

from remotecoder_tools.perf_calibration import evidence, recorded_events
from remotecoder_tools.perf_replay import compare, scenario_from_threads


def test_captured_message_is_replayed_once_and_history_is_preserved():
    text = "Real captured prose with a code block.\n" * 12
    threads = [{"id": name, "cwd": "/replay", "turns": [{"id": "past", "status": "completed", "items": [
        {"id": "tool", "type": "commandExecution", "status": "completed", "aggregatedOutput": "actual output"},
        {"id": "thought", "type": "reasoning", "summary": ["Captured reasoning"], "content": []},
        {"id": "source", "type": "agentMessage", "text": text}]}]} for name in ["a", "b", "c"]]
    scenario = scenario_from_threads(threads, {}, {}, {})
    assert len(scenario["actions"]) == 13
    for index, name in enumerate(["a", "b", "c"]):
        frames = [event["frame"] for event in scenario["events"] if event["frame"]["params"]["threadId"] == name]
        assert "".join(frame["params"]["delta"] for frame in frames if frame["method"] == "item/agentMessage/delta") == text
        started = next(frame for frame in frames if frame["method"] == "item/started" and frame["params"]["item"]["type"] == "agentMessage")
        assert started["params"]["item"]["text"] == ""
        assert scenario["conversations"][index]["items"][-1]["item"]["text"] == text
        assert sum(frame["method"] == "item/completed" for frame in frames) == 3
        assert any(frame["method"] == "item/reasoning/summaryTextDelta" for frame in frames)
        assert sum(frame["method"] == "thread/tokenUsage/updated" for frame in frames) == 2
        assert sum(frame["method"] == "daemon/activeTurns/changed" for frame in frames) == 2
        deltas = [event for event in scenario["events"] if event["frame"]["method"] == "item/agentMessage/delta"
                  and event["frame"]["params"]["threadId"] == name]
        assert max(b["at"] - a["at"] for a, b in zip(deltas, deltas[1:], strict=False)) < 0.031
        assert sum(frame["method"] == "turn/completed" for frame in frames) == 1
        turn_start = next(frame["params"]["turn"] for frame in frames if frame["method"] == "turn/started")
        turn_end = next(frame["params"]["turn"] for frame in frames if frame["method"] == "turn/completed")
        assert turn_start["completedAt"] is None
        assert turn_start["startedAt"] == scenario["capturedAt"] + 2 + index * 4
        assert turn_end["completedAt"] == scenario["capturedAt"] + 39 + index * 4
    assert [event["at"] for event in scenario["events"]] == sorted(event["at"] for event in scenario["events"])


@pytest.mark.parametrize("change", [{"display": {"width": 900}}, {"samples": [{"thermalState": 1, "lowPowerMode": False}]}])
def test_comparison_rejects_different_display_or_energy_state(tmp_path, change):
    before = tmp_path / "before.jsonl"
    after = tmp_path / "after.jsonl"
    report = {"valid": True, "fixtureSHA256": "first", "target": "device", "deviceUDID": "ipad",
              "operatingSystem": "27", "display": {"width": 800}, "instrumentation": {"instruments": []},
              "locale": "en", "toolchain": "27.1", "configuration": "Release", "signing": "distribution",
              "driverSHA256": "driver", "disabled": [], "mode": "offlineReplay",
              "samples": [{"thermalState": 0, "lowPowerMode": False}]}
    before.write_text(json.dumps(report) + "\n")
    after.write_text(json.dumps({**report, **change}) + "\n")
    with pytest.raises(ValueError, match="differs"):
        compare(argparse.Namespace(before=before, after=after))


def test_comparison_rejects_matching_reports_without_configuration_evidence(tmp_path):
    path = tmp_path / "legacy.jsonl"
    path.write_text(json.dumps({"valid": True, "fixtureSHA256": "fixture"}) + "\n")
    with pytest.raises(ValueError, match="metadata missing:.*signing.*driverSHA256"):
        compare(argparse.Namespace(before=path, after=path))


def test_live_calibration_requires_overlapping_turns_and_deltas_in_the_window():
    def stream(start, end, delta):
        return [{"atUnix": at, "frame": {"method": method, "params": {"delta": "text"}}}
                for at, method in [(start, "turn/started"), (delta, "item/agentMessage/delta"), (end, "turn/completed")]]
    window = {"startedAt": 10, "endedAt": 70}
    assert evidence(window, [stream(12, 50, 20), stream(16, 60, 30), stream(20, 65, 40)])[0]
    assert not evidence(window, [stream(12, 14, 13), stream(16, 60, 30)])[0]
    assert not evidence(window, [stream(12, 50, 20), stream(16, 80, 75)])[0]


def test_recorded_streams_preserve_hidden_turn_activity_and_time_order():
    def frame(thread, method):
        return {"method": method, "params": {"threadId": thread}}
    streams = [[{"atUnix": 12, "frame": frame("a", "turn/started")},
                {"atUnix": 30, "frame": frame("a", "turn/completed")}],
               [{"atUnix": 11, "frame": frame("b", "turn/started")},
                {"atUnix": 15, "frame": frame("b", "item/agentMessage/delta")}]]
    events = recorded_events(streams, 10, 10)
    assert [event["at"] for event in events] == [1, 1, 2, 2, 5]
    assert {event["frame"]["params"]["threadId"] for event in events
            if event["frame"]["method"] == "daemon/activeTurns/changed"} == {"a", "b"}
