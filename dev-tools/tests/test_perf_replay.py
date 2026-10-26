import argparse
import copy
import hashlib
import json
from contextlib import asynccontextmanager

import pytest

from remotecoder_tools import perf_replay
from remotecoder_tools.perf_calibration import evidence, recorded_events
from remotecoder_tools.perf_replay import (
    compare,
    local_submission,
    private_destination,
    replay_recording,
    scenario_from_conversations,
    state_metrics,
    write_history,
)


def recording():
    def event(at, method, params):
        return {"at": at, "frame": {"method": method, "params": {"threadId": "recorded", **params}}}
    return {"events": [event(1, "turn/started", {"turn": {"id": "old-turn"}}),
                       event(2, "item/started", {"turnId": "old-turn", "item": {"id": "message", "type": "agentMessage", "text": ""}}),
                       event(2.2, "item/agentMessage/delta", {"turnId": "old-turn", "itemId": "message", "delta": "captured"}),
                       event(5.5, "item/agentMessage/delta", {"turnId": "old-turn", "itemId": "message", "delta": " timing"}),
                       event(6, "item/completed", {"turnId": "old-turn", "item": {"id": "message", "type": "agentMessage", "text": "captured timing"}}),
                       event(8, "turn/completed", {"turn": {"id": "old-turn"}})]}


def test_recording_preserves_arrival_offsets_and_keeps_one_turn_running():
    source = recording()
    frozen = copy.deepcopy(source)
    events = replay_recording(source, ["fixture"], 60)
    deltas = [event for event in events if event["frame"]["method"] == "item/agentMessage/delta"]
    assert deltas[1]["at"] - deltas[0]["at"] == pytest.approx(3.3)
    assert all(event["frame"]["params"]["threadId"] == "fixture" for event in events)
    assert sum(event["frame"]["method"] == "turn/started" for event in events) == 1
    assert all(event["frame"]["method"] != "turn/completed" for event in events)
    assert len({event["frame"]["params"]["itemId"] for event in deltas}) > 1
    assert {event["frame"]["params"]["turnId"] for event in deltas} == {"replay-turn-0"}
    assert source == frozen


def test_history_is_not_trimmed_to_twenty_turns_or_fixed_paced():
    turns = [{"id": f"turn-{index}", "status": "completed", "items": [
        {"id": f"item-{index}", "type": "agentMessage", "text": "synthetic"}]} for index in range(50)]
    scenario = scenario_from_conversations([{"thread": {"id": "thread"}, "turns": turns, "items": []}], {}, {}, {})
    assert len(scenario["conversations"][0]["turns"]) == 50
    assert scenario["events"] == []
    assert scenario["duration"] == 300


def test_history_index_addresses_exact_records_and_is_private(tmp_path):
    records = [{"text": "åäö"}, {"nested": {"value": 4}}]
    index = write_history(tmp_path, records, "items")
    path = tmp_path / index["path"]
    data = path.read_bytes()
    assert index["sha256"] == hashlib.sha256(data).hexdigest()
    assert path.stat().st_mode & 0o777 == 0o600
    assert [json.loads(data[start:end]) for start, end in zip(index["offsets"], index["offsets"][1:], strict=False)] == records


def test_oversized_record_leaves_no_partial_file(tmp_path, monkeypatch):
    monkeypatch.setattr(perf_replay, "MAX_PAGE_BYTES", 10)
    with pytest.raises(ValueError, match="bounded"):
        write_history(tmp_path, [{"text": "too much data"}], "items")
    assert list((tmp_path / "history").iterdir()) == []


def test_local_submission_retains_actual_text_with_reconcilable_identity():
    items = [{"turnId": "turn", "item": {"id": "message", "type": "userMessage", "content": [{"type": "text", "text": "synthetic request"}]}}]
    submission = local_submission("thread", items)
    assert submission["text"] == "synthetic request"
    assert submission["messageID"] == items[0]["item"]["clientId"]
    assert local_submission("thread", items) == submission
    assert submission["turnID"] == "turn"


def test_fixture_placement_rejects_worktrees_and_other_private_roots(tmp_path):
    with pytest.raises(ValueError, match="perf-traces"):
        private_destination(tmp_path / "fixture.json")


@pytest.mark.asyncio
@pytest.mark.parametrize("role", ["root", "child", "unresolved"])
@pytest.mark.parametrize("prioritize_roots", [False, True])
async def test_capture_paginates_native_history_and_reads_only_parent_headers(tmp_path, monkeypatch, role, prioritize_roots):
    calls = []
    active = {"coverage": {"codex": True, "claude": True}, "activeTurns": [], "externalActivity": {"sessions": [], "codexAvailable": True, "claudeAvailable": True}}

    @asynccontextmanager
    async def gateway(*args, **kwargs):
        yield object()

    class Response:
        status_code = 200

        def json(self):
            return {}

    class Client:
        async def get(self, *args, **kwargs):
            return Response()

    @asynccontextmanager
    async def http_client(**kwargs):
        yield Client()

    async def initialize(*args, **kwargs):
        pass

    async def rpc(ws, *, method, params, **kwargs):
        calls.append((method, params))
        if method == "daemon/activeTurns":
            result = active
        elif method == "thread/list":
            assert params["includeCompletionTimes"] is True
            result = {"data": [{"id": name, "cwd": "/synthetic", "updatedAt": 1800000000} for name in ("chosen", "known-null", "missing")],
                      "completionTimes": {"chosen": 1700000000, "known-null": None, "not-captured": 1800000000}}
        elif method == "claude/thread/list":
            assert "includeCompletionTimes" not in params
            result = {"data": []}
        elif method == "thread/items/list":
            result = {"data": [{"turnId": "turn", "item": {"id": "user", "type": "userMessage", "content": [{"type": "text", "text": "synthetic"}]}}], "nextCursor": "page2"} if params["cursor"] is None else {"data": [{"turnId": "turn", "item": {"id": "answer", "type": "agentMessage", "text": "synthetic"}}]}
        elif method == "thread/turns/list":
            result = {"data": [{"id": "turn", "status": "completed", "items": [], "itemsView": "notLoaded"}]}
        elif method == "conversation/agents/classify":
            relations = {"chosen": {"parentThreadId": "parent"}} if role == "child" else {}
            if prioritize_roots:
                relations["known-null"] = {"parentThreadId": "parent"}
            result = {"relations": relations,
                      "knownRoots": (["chosen"] if role == "root" else []) + (["missing"] if prioritize_roots else [])}
        elif method == "thread/read":
            assert params == {"threadId": "parent", "includeTurns": False}
            result = {"thread": {"id": "parent", "cwd": "/synthetic"}}
        elif method == "host/info":
            result = {"homeDirectory": "/synthetic"}
        elif method == "conversation/metadata/read":
            result = {"entries": []}
        elif method == "conversation/marks/read":
            result = {"threads": {}}
        else:
            result = {}
        return result, 0.01, len(json.dumps(result))

    monkeypatch.setattr(perf_replay, "_resolve_config", lambda args: argparse.Namespace(http_client=http_client, http_base="http://synthetic", token="synthetic"))
    monkeypatch.setattr(perf_replay, "private_destination", lambda path: tmp_path / "scenario.json")
    monkeypatch.setattr(perf_replay, "_open_gateway", gateway)
    monkeypatch.setattr(perf_replay, "_initialize", initialize)
    monkeypatch.setattr(perf_replay, "_timed_rpc", rpc)
    expected_histories = 2 if prioritize_roots else 1
    args = argparse.Namespace(out="scenario.json", thread=["chosen"], sidebar_limit=10, history_count=expected_histories)
    result = await perf_replay.capture(args)
    assert result["captureSummary"]["histories"] == expected_histories
    assert len(result["conversations"]) == (4 if role == "child" or prioritize_roots else 3)
    if prioritize_roots:
        assert {conversation["thread"]["id"] for conversation in result["conversations"] if "itemFile" in conversation} == {"chosen", "missing"}
        assert not any(method == "thread/items/list" and params["threadId"] == "known-null" for method, params in calls)
        assert next(index for index, (method, _) in enumerate(calls) if method == "conversation/agents/classify") < next(index for index, (method, _) in enumerate(calls) if method == "thread/turns/list")
    conversation = result["conversations"][0]
    assert ("localSubmission" in conversation) == (role == "root")
    records = [json.loads(line) for line in (tmp_path / conversation["itemFile"]["path"]).read_bytes().splitlines()]
    assert records[0]["item"]["content"] == [{"type": "text", "text": "synthetic"}]
    assert records[1]["item"]["text"] == "synthetic"
    if role == "root":
        assert conversation["localSubmission"]["messageID"] == records[0]["item"]["clientId"]
    assert result["completionTimes"] == {"chosen": 1700000000, "known-null": None}
    assert "missing" not in result["completionTimes"]
    assert result["conversations"][0]["itemFile"]["offsets"][-1] > 0
    evidence = result["conversations"][0]["captureActivityEvidence"]
    assert evidence["provider"] == "codex"
    for phase in ("before", "after"):
        assert evidence[phase]["providerCoverage"]["codex"] is True
        assert evidence[phase]["externalAvailability"]["codex"] is True
        assert len(evidence[phase]["snapshotSHA256"]) == 64
    assert result["captureSummary"]["idleEvidence"]["beforeAndAfterChecks"] == expected_histories * 2
    assert len([call for call in calls if call[0] == "thread/items/list"]) == expected_histories * 2
    assert all(params.get("includeTurns") is not True for _, params in calls)
    active["activeTurns"] = [{"threadId": "chosen"}]
    with pytest.raises(ValueError, match="selected thread is active"):
        await perf_replay.capture(args)


def report():
    return {"valid": True, "seconds": 20, "fixtureSHA256": "first", "target": "device", "deviceUDID": "ipad",
            "appExecutableSHA256": "executable", "sourceCommit": "commit", "sourceFingerprint": "source",
            "operatingSystem": "27", "display": {"width": 800}, "instrumentation": {"instruments": []},
            "locale": "en", "toolchain": "27.1", "configuration": "Release", "signing": "distribution",
            "driverSHA256": "driver", "disabled": [], "mode": "offlineReplay", "workloadVersion": 2,
            "captureAuthority": {"contractVersion": 2, "requiresExternalAvailability": True, "requiresProviderCoverage": True,
                "beforeAndAfterChecks": 200, "capturedHistories": 100},
            "preparationContractVersion": 2, "preparation": {"conversations": 100, "sidebarConversations": 1000,
                "capturedSidebarConversations": 1000,
                "preservedCheckpointCount": 100, "owner": {"records": 100, "primaryPayloadBytes": 1000,
                    "cacheLimitBytes": 64_000_000, "evictionBytes": 80_000_000, "primaryLimitBytes": 512_000_000, "unknownProtectionRecords": 0}},
            "preMeasurementOwner": {"records": 100, "protectedRecords": 100, "unknownProtectionRecords": 0,
                "recordBytes": 90_000_000, "primaryPayloadBytes": 1000, "cacheBytes": 80_000_000,
                "evictionBytes": 80_000_000, "cacheLimitBytes": 64_000_000, "primaryLimitBytes": 512_000_000},
            "postMeasurementOwner": {"records": 100, "protectedRecords": 100, "unknownProtectionRecords": 0,
                "recordBytes": 90_000_000, "primaryPayloadBytes": 1000, "cacheBytes": 80_000_000,
                "evictionBytes": 80_000_000, "cacheLimitBytes": 64_000_000, "primaryLimitBytes": 512_000_000},
            "samples": [{"at": at, "thermalState": 0, "lowPowerMode": False, "processCPUms": at * 500,
                         "mainThreadCPUms": at * 100, "persistence": {"checkpoints": {"bytes": at * 1000}},
                         "context": {"scene": "active", "surface": "chat", "turnRunningVisible": True, "voiceCall": False}}
                        for at in (0, 10, 20)]}


@pytest.mark.parametrize("change", [{"display": {"width": 900}}, {"samples": [{**sample, "thermalState": 1} for sample in report()["samples"]]}])
def test_comparison_rejects_different_display_or_energy_state(tmp_path, change):
    before = tmp_path / "before.jsonl"
    after = tmp_path / "after.jsonl"
    before.write_text(json.dumps(report()) + "\n")
    after.write_text(json.dumps({**report(), **change}) + "\n")
    with pytest.raises(ValueError, match="differs"):
        compare(argparse.Namespace(before=before, after=after))


def test_compare_reports_field_state_cpu_and_checkpoint_rates(tmp_path, capsys):
    before, after = tmp_path / "before.jsonl", tmp_path / "after.jsonl"
    a, b = report(), report()
    b["preparation"]["seconds"] = 70
    b["appExecutableSHA256"] = "different-executable"
    b["sourceCommit"] = "different-commit"
    b["sourceFingerprint"] = "different-source"
    for sample in b["samples"]:
        sample["processCPUms"] /= 2
        sample["persistence"]["checkpoints"]["bytes"] //= 4
    before.write_text(json.dumps(a))
    after.write_text(json.dumps(b))
    compare(argparse.Namespace(before=before, after=after))
    result = json.loads(capsys.readouterr().out)
    assert result["buildIdentity"]["before"]["sourceCommit"] == "commit"
    assert result["buildIdentity"]["after"]["sourceCommit"] == "different-commit"
    assert result["metrics"]["agentWorking.processCPUPercent"]["changePercent"] == -50
    assert result["metrics"]["agentWorking.checkpointBytesPerMinute"]["changePercent"] == -75


@pytest.mark.parametrize("key", ["appExecutableSHA256", "sourceCommit", "sourceFingerprint"])
@pytest.mark.parametrize("side", ["before", "after"])
def test_comparison_rejects_mixed_builds_within_each_side(tmp_path, key, side):
    before, after = tmp_path / "before.jsonl", tmp_path / "after.jsonl"
    before.write_text(json.dumps(report()))
    after.write_text(json.dumps(report()))
    mixed = report()
    mixed[key] = "different"
    path = before if side == "before" else after
    path.write_text(json.dumps(report()) + "\n" + json.dumps(mixed))
    with pytest.raises(ValueError, match="exactly one build identity per side"):
        compare(argparse.Namespace(before=before, after=after))


@pytest.mark.parametrize("change", [{"evictionBytes": 64_000_000}, {"unknownProtectionRecords": 1}, {"protectedRecords": 99}])
def test_comparison_rejects_pressure_or_preservation_lost_before_measurement(tmp_path, change):
    value = report()
    value["preMeasurementOwner"].update(change)
    path = tmp_path / "lost-pressure.jsonl"
    path.write_text(json.dumps(value))
    with pytest.raises(ValueError, match="immediately before measurement"):
        compare(argparse.Namespace(before=path, after=path))


def test_comparison_preserves_post_measurement_pressure_changes_as_results(tmp_path, capsys):
    value = report()
    value["postMeasurementOwner"]["evictionBytes"] = 1
    value["postMeasurementOwner"]["protectedRecords"] = 99
    path = tmp_path / "changed-pressure.jsonl"
    path.write_text(json.dumps(value))
    compare(argparse.Namespace(before=path, after=path))
    result = json.loads(capsys.readouterr().out)
    assert result["preMeasurementOwner"]["before"][0] == value["preMeasurementOwner"]
    assert result["postMeasurementOwner"]["after"][0] == value["postMeasurementOwner"]


@pytest.mark.parametrize("key", ["preMeasurementOwner", "postMeasurementOwner"])
def test_comparison_rejects_missing_measurement_owner_evidence(tmp_path, key):
    value = report()
    del value[key]
    path = tmp_path / "missing-owner.jsonl"
    path.write_text(json.dumps(value))
    with pytest.raises(ValueError, match="metadata missing"):
        compare(argparse.Namespace(before=path, after=path))


def test_mixed_intervals_are_excluded_instead_of_assigned_to_a_state():
    value = report()
    value["samples"][1]["mixed"] = True
    result = state_metrics(value)
    assert result["agentWorking"]["seconds"] == 10
    assert result["excludedIntervals"]["mixed"] == 1


def test_comparison_rejects_legacy_metadata_and_missing_counters(tmp_path):
    path = tmp_path / "legacy.jsonl"
    path.write_text(json.dumps({"valid": True, "fixtureSHA256": "fixture"}) + "\n")
    with pytest.raises(ValueError, match="metadata missing:.*signing.*driverSHA256"):
        compare(argparse.Namespace(before=path, after=path))
    value = report()
    del value["samples"][0]["persistence"]
    path.write_text(json.dumps(value))
    with pytest.raises(ValueError, match="checkpoint byte counters"):
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


@pytest.mark.asyncio
async def test_optional_service_batches_obey_gateway_limits():
    ids = [f"thread-{index}" for index in range(217)]
    calls = []

    async def read(method, params):
        calls.append((method, params))
        if method == "conversation/agents/classify":
            assert len(params["threadIds"]) <= 200
            return {"relations": {}, "knownRoots": params["threadIds"], "warnings": []}
        assert len(params["queries"]) <= 16
        return {"threads": [{"threadId": query["threadId"]} for query in params["queries"]]}

    responses, errors = {}, {}
    await perf_replay.capture_batched_services(read, ids, responses, errors)
    assert responses["conversation/agents/classify"]["knownRoots"] == ids
    assert [entry["threadId"] for entry in responses["conversation/questions/read"]["threads"]] == ids
    assert errors == {}
    assert len(calls) == 16


def test_partial_recording_retains_background_stream_and_marks_inferred_start():
    source = recording()
    source["events"].extend([
        {"at": 2.5, "frame": {"method": "item/started", "params": {"threadId": "background", "turnId": "ongoing", "item": {"id": "background-item", "type": "agentMessage", "text": ""}}}},
        {"at": 3.5, "frame": {"method": "item/agentMessage/delta", "params": {"threadId": "background", "turnId": "ongoing", "itemId": "background-item", "delta": "synthetic"}}},
    ])
    events = replay_recording(source, ["visible", "hidden"], 60)
    starts = [event for event in events if event["frame"]["method"] == "turn/started"]
    assert {event["frame"]["params"]["threadId"] for event in starts} == {"visible", "hidden"}
    inferred = next(event for event in starts if event["frame"]["params"]["threadId"] == "hidden")
    assert inferred["at"] == 3.5
    assert any(event["frame"]["params"].get("delta") == "synthetic" for event in events)
    scenario = scenario_from_conversations([{"thread": {"id": value}, "items": [], "turns": []} for value in ("visible", "hidden")], {}, {}, {}, recording=source)
    assert "original start is unknown" in scenario["provenance"]["initialState"]


def test_recording_with_conflicting_turn_identities_is_rejected():
    source = recording()
    source["events"][-1]["frame"]["params"]["turn"]["id"] = "different-turn"
    with pytest.raises(ValueError, match="inconsistent turn identities"):
        replay_recording(source, ["fixture"], 60)


def test_every_stream_start_publishes_inventory_without_a_subscription():
    source = recording()
    source["events"].append({"at": 4, "frame": {"method": "item/started", "params": {
        "threadId": "unopened-background", "turnId": "background-turn", "item": {
            "id": "background-message", "type": "agentMessage", "text": ""}}}})
    events = replay_recording(source, ["visible", "background"], 60)
    starts = [index for index, event in enumerate(events) if event["frame"]["method"] == "turn/started"]
    assert len(starts) == 2
    for index in starts:
        start, inventory = events[index:index + 2]
        assert inventory["at"] == start["at"]
        assert inventory["frame"] == {"method": "daemon/activeTurns/changed",
                                      "params": {"threadId": start["frame"]["params"]["threadId"]}}
    assert sum(event["frame"]["method"] == "daemon/activeTurns/changed" for event in events) == 2


def test_comparison_rejects_preparation_without_preserved_state(tmp_path):
    value = report()
    value["preparation"]["preservedCheckpointCount"] = 0
    path = tmp_path / "unpreserved.jsonl"
    path.write_text(json.dumps(value))
    with pytest.raises(ValueError, match="verified preserved checkpoints"):
        compare(argparse.Namespace(before=path, after=path))


@pytest.mark.parametrize("provider", ["codex", "claude"])
@pytest.mark.parametrize("available", [False, None])
def test_idle_evidence_requires_external_discovery_for_each_provider(provider, available):
    activity = {"coverage": {"codex": True, "claude": True}, "activeTurns": [],
                "externalActivity": {"sessions": [], "codexAvailable": True, "claudeAvailable": True}}
    if available is None:
        del activity["externalActivity"][provider + "Available"]
    else:
        activity["externalActivity"][provider + "Available"] = available
    excluded, authoritative = perf_replay.idle_threads(activity)
    assert excluded == set()
    assert authoritative[provider] is False
    assert authoritative["claude" if provider == "codex" else "codex"] is True


@pytest.mark.parametrize("provider", ["codex", "claude"])
def test_external_discovery_does_not_replace_provider_coverage(provider):
    activity = {"coverage": {"codex": True, "claude": True}, "activeTurns": [],
                "externalActivity": {"sessions": [], "codexAvailable": True, "claudeAvailable": True}}
    activity["coverage"][provider] = False
    assert perf_replay.idle_threads(activity)[1][provider] is False


def test_recorded_and_inferred_turn_start_timestamps_are_wire_integers():
    source = recording()
    source["events"].append({"at": 3.25, "frame": {"method": "item/started", "params": {
        "threadId": "background", "turnId": "existing-turn", "item": {
            "id": "item", "type": "agentMessage", "text": ""}}}})
    events = replay_recording(source, ["visible", "background"], 60)
    starts = [event for event in events if event["frame"]["method"] == "turn/started"]
    assert len(starts) == 2
    assert all(isinstance(event["frame"]["params"]["turn"]["startedAt"], int) for event in starts)
    assert any(event["at"] % 1 for event in starts)


def test_preparation_seeds_all_ordinary_roots_and_only_explicit_journey_purpose_exceptions():
    known_roots = {"ordinary", "null-purpose", "probe", "automation", "journey-probe", "journey-automation", "unknown-purpose"}
    marks = {"null-purpose": {"purpose": None}, "probe": {"purpose": "probe"}, "automation": {"purpose": "automation"},
             "journey-probe": {"purpose": "probe"}, "journey-automation": {"purpose": "automation"},
             "unknown-purpose": {"purpose": "future"}}
    allowed = perf_replay.preparation_roots(known_roots, marks, {"journey-probe", "journey-automation", "child"})
    assert allowed == {"ordinary", "null-purpose", "journey-probe", "journey-automation"}
    assert perf_replay.preparation_roots(known_roots, marks, set()) == {"ordinary", "null-purpose"}
    with pytest.raises(ValueError, match="at most three"):
        perf_replay.preparation_roots(known_roots, marks, {"one", "two", "three", "four"})


@pytest.mark.parametrize("duration, expected_count", [(300, 20), (900, 60)])
def test_journey_visits_close_the_drawer_and_return_to_the_main_stream(duration, expected_count):
    actions = perf_replay.journey_actions(["main", "second", "third"], duration)
    assert len(actions) == expected_count
    assert actions[0]["at"] == 35
    selected, drawer = "main", False
    for visit in range(0, len(actions), 5):
        opening, switch, closing, scroll, returning = actions[visit:visit + 5]
        assert [action["kind"] for action in (opening, switch, closing, scroll, returning)] == ["toggleSidebar", "open", "toggleSidebar", "scroll", "open"]
        assert closing["at"] - opening["at"] == 3
        assert returning["at"] - opening["at"] == 8
        for action in actions[visit:visit + 5]:
            if action["kind"] == "open":
                selected = action["threadID"]
            else:
                assert action["threadID"] == selected
            if action["kind"] == "toggleSidebar":
                drawer = not drawer
        assert selected == "main" and drawer is False


def test_comparison_rejects_the_previous_half_drawer_context_mix(tmp_path):
    value = report()
    value["samples"][1]["context"]["surface"] = "drawer"
    path = tmp_path / "half-drawer.jsonl"
    path.write_text(json.dumps(value))
    with pytest.raises(ValueError, match="unrepresentative replay:.*at least 80%"):
        compare(argparse.Namespace(before=path, after=path))


def test_comparison_does_not_hide_missing_working_time_by_excluding_mixed_intervals(tmp_path):
    value = report()
    value["samples"][1]["mixed"] = True
    path = tmp_path / "half-mixed.jsonl"
    path.write_text(json.dumps(value))
    with pytest.raises(ValueError, match="unrepresentative replay:.*at least 80%"):
        compare(argparse.Namespace(before=path, after=path))
