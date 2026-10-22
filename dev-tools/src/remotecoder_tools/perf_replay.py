import asyncio
import copy
import hashlib
import json
import statistics
import tempfile
import time
from pathlib import Path

from .config import _resolve_config
from .rpc import GatewayRPCError, _initialize, _open_gateway, _timed_rpc


def captured_conversation(source: dict) -> dict:
    thread = copy.deepcopy(source)
    turns = thread.pop("turns")
    settled = [turn for turn in turns if turn.get("status") == "completed"][-20:]
    if not settled:
        raise ValueError(f"{thread['id']}: no completed history")
    items = [{"turnId": turn["id"], "item": item, "isComplete": True}
             for turn in settled for item in turn.get("items", [])]
    if len(items) > 1000:
        raise ValueError(f"{thread['id']}: captured history exceeds 1,000 items")
    for ordinal, item in enumerate(items):
        item["startedAtOrdinal"] = ordinal
    thread["status"] = {"type": "idle"}
    return {"thread": thread, "items": items,
            "turns": [{**turn, "items": [], "itemsView": "notLoaded"} for turn in settled]}


def scenario_from_threads(threads: list[dict], responses: dict, errors: dict, http: dict) -> dict:
    if not 2 <= len(threads) <= 6:
        raise ValueError("capture between two and six conversations")
    conversations = []
    events = []
    captured_at = int(time.time())

    def emit(thread_id: str, at: float, method: str, params: dict) -> None:
        events.append({"at": round(at, 6), "frame": {"method": method, "params": {"threadId": thread_id, **params}}})

    for index, source in enumerate(threads):
        conversation = captured_conversation(source)
        thread = conversation["thread"]
        conversations.append(conversation)
        selected = next((turn for turn in reversed(source["turns"]) if turn.get("status") == "completed"
                         and any(item.get("type") == "agentMessage" for item in turn.get("items", []))), None)
        if selected is None:
            raise ValueError(f"{thread['id']}: no completed assistant turn to replay")
        items = copy.deepcopy(selected["items"])
        for ordinal, item in enumerate(items):
            item["id"] = f"replay-item-{index}-{ordinal}"
            if item["type"] == "userMessage" and "clientId" in item:
                item["clientId"] = f"replay-user-{index}-{ordinal}"
        if any("![" in item.get("text", "") or "rc-visual:" in item.get("text", "")
               for item in items if item["type"] == "agentMessage"):
            raise ValueError(f"{thread['id']}: select a text/code turn without external visual assets")
        turn_id = f"replay-turn-{index}"
        begin, end = 2 + index * 4, 39 + index * 4
        turn = {**selected, "id": turn_id, "items": [], "itemsView": "full", "status": "inProgress", "error": None,
                "startedAt": captured_at + begin, "completedAt": None, "durationMs": None}
        emit(thread["id"], begin, "turn/started", {"turn": turn})
        chunks_by_item = []
        for item in items:
            chunks = []
            fields = [("text", "item/agentMessage/delta", None)] if item["type"] == "agentMessage" else []
            if item["type"] == "reasoning":
                fields = [("summary", "item/reasoning/summaryTextDelta", "summaryIndex"),
                          ("content", "item/reasoning/textDelta", "contentIndex")]
            for field, method, index_key in fields:
                texts = item.get(field, []) if index_key else [item.get(field, "")]
                for text_index, text in enumerate(texts):
                    for offset in range(0, len(text), 8):
                        params = {"turnId": turn_id, "itemId": item["id"], "delta": text[offset:offset + 8]}
                        if index_key:
                            params[index_key] = text_index
                        chunks.append((method, params))
            chunks_by_item.append(chunks)
        count = sum(len(chunks) + 2 for chunks in chunks_by_item)
        step = min(0.03, (end - begin - 0.1) / (count + 1))
        gap = max(0, (end - begin - 0.1 - count * step) / len(items))
        at = begin + 0.01
        for item, chunks in zip(items, chunks_by_item, strict=True):
            initial = copy.deepcopy(item)
            if item["type"] == "agentMessage":
                initial["text"] = ""
            elif item["type"] == "reasoning":
                initial["summary"], initial["content"] = [], []
            elif item["type"] in {"commandExecution", "dynamicToolCall", "fileChange"}:
                initial["status"] = "inProgress"
                if item["type"] == "commandExecution":
                    initial["aggregatedOutput"], initial["exitCode"] = "", None
            emit(thread["id"], at, "item/started", {"turnId": turn_id, "item": initial})
            for method, params in chunks:
                at += step
                emit(thread["id"], at, method, params)
            at += step
            emit(thread["id"], at, "item/completed", {"turnId": turn_id, "item": item})
            at += step + gap
        emit(thread["id"], end, "turn/completed", {"turn": {**turn, "status": "completed", "items": items,
             "completedAt": captured_at + end, "durationMs": int((end - begin) * 1000)}})
        for at, count in [(begin + 0.001, 4_000), (end + 0.001, 5_000)]:
            emit(thread["id"], at, "thread/tokenUsage/updated", {"turnId": turn_id,
                 "tokenUsage": {"total": {"totalTokens": count}, "last": {"totalTokens": count - 3_000}, "modelContextWindow": 200_000}})
    for event in sorted(events, key=lambda event: event["at"]):
        frame = event["frame"]
        if frame["method"] in {"turn/started", "turn/completed"}:
            emit(frame["params"]["threadId"], event["at"] + 0.0001, "daemon/activeTurns/changed", {})
    ids = [conversation["thread"]["id"] for conversation in conversations]
    actions = []
    for at, kind, selected, message in [
        (1, "open", 0, None), (5, "scroll", 0, 0), (9, "toggleSidebar", 0, None),
        (10, "open", 1, None), (12, "toggleSidebar", 1, None), (16, "scroll", 1, 0),
        (21, "open", 2 % len(ids), None), (26, "scroll", 2 % len(ids), 0),
        (31, "open", 0, None), (36, "scroll", 0, 1), (42, "open", 1, None),
        (48, "open", 2 % len(ids), None), (54, "open", 0, None),
    ]:
        action = {"at": at, "kind": kind, "threadID": ids[selected]}
        if message is not None:
            action["message"] = message
        actions.append(action)
    events.sort(key=lambda event: event["at"])
    if len(events) > 20_000:
        raise ValueError("selected complete turns exceed 20,000 replay events; choose shorter turns")
    return {"version": 1, "capturedAt": captured_at, "name": f"everyday-{len(threads)}-conversations-v1", "duration": 60,
            "conversations": conversations, "events": events, "actions": actions,
            "responses": responses, "errors": errors, "httpResponses": http,
            "provenance": {"content": "captured completed conversation history and real assistant text",
                           "pacing": "complete captured turns; 8-character deltas in at-most-30ms bursts, 37s per turn, staggered by 4s",
                           "usage": "fixed synthetic token counters exercise usage updates; not captured provider usage",
                           "scope": "text, code, tables and captured tool history; no voice or remote visual assets"}}


async def capture(args) -> dict:
    config = _resolve_config(args)
    threads, parents, responses, errors, http, thread_responses = [], [], {}, {}, {}, {}
    async with _open_gateway(config, timeout_s=30, method="thread/read") as ws:
        await _initialize(ws, timeout_s=30)
        request_id = 10

        async def read(method, params):
            nonlocal request_id
            request_id += 1
            result, _, _ = await _timed_rpc(ws, req_id=request_id, method=method, params=params, timeout_s=30)
            return result

        for thread_id in args.thread:
            result = await read("thread/read", {"threadId": thread_id, "includeTurns": True})
            threads.append(result["thread"])
        for method, params in {
            "model/list": {}, "account/read": {}, "account/rateLimits/read": {},
            "conversation/metadata/read": {}, "conversation/marks/read": {},
            "host/info": {}, "directory/favorites/read": {},
            "conversation/agents/classify": {"threadIds": args.thread},
            "conversation/projects/resolve": {"directories": sorted({thread["cwd"] for thread in threads})},
            "conversation/questions/read": {"queries": [{"threadId": thread["id"], "itemIds": []} for thread in threads]},
        }.items():
            try:
                responses[method] = await read(method, params)
            except GatewayRPCError as error:
                errors[method] = {"code": error.code, "message": "Captured unavailable optional service"}
        if "host/info" in responses:
            responses["fs/readDirectory"] = await read("fs/readDirectory", {"path": responses["host/info"]["homeDirectory"]})
        for thread in threads:
            try:
                reply = {"result": await read("conversation/agents/list", {"threadId": thread["id"]})}
            except GatewayRPCError as error:
                reply = {"error": {"code": error.code, "message": "Captured unavailable optional service"}}
            thread_responses[thread["id"]] = {"conversation/agents/list": reply}
        relations = responses.get("conversation/agents/classify", {}).get("relations", {})
        related = {relation["parentThreadId"] for relation in relations.values()} - set(args.thread)
        for thread_id in sorted(related):
            result = await read("thread/read", {"threadId": thread_id, "includeTurns": True})
            parents.append(captured_conversation(result["thread"]))
            thread_responses[thread_id] = {"conversation/agents/list": {"result": await read("conversation/agents/list", {"threadId": thread_id})}}
    async with config.http_client(timeout=15) as client:
        for path in ["/accounts", "/claude/accounts"]:
            response = await client.get(config.http_base + path, headers={"Authorization": f"Bearer {config.token}"})
            http["GET " + path] = {"status": response.status_code, "body": response.json()}
    if "conversation/metadata/read" in responses:
        responses["conversation/metadata/read"]["entries"] = [entry for entry in responses["conversation/metadata/read"]["entries"]
                                                              if entry["sessionID"] in args.thread]
    if "conversation/marks/read" in responses:
        responses["conversation/marks/read"]["threads"] = {key: value for key, value in responses["conversation/marks/read"]["threads"].items()
                                                           if key in args.thread}
    http["POST /app-logs"] = {"status": 200, "body": {"stored": "offline-replay.jsonl.gz"}}
    scenario = scenario_from_threads(threads, responses, errors, http)
    scenario["conversations"] += parents
    if len(scenario["conversations"]) > 6:
        raise ValueError("selected conversations and referenced parents exceed six histories")
    return {**scenario, "threadResponses": thread_responses}


def capture_command(args) -> None:
    destination = Path(args.out).expanduser().resolve()
    if any((parent / ".git").exists() for parent in destination.parents):
        raise ValueError("real conversation fixtures must be saved outside Git checkouts")
    scenario = asyncio.run(capture(args))
    data = json.dumps(scenario, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    if len(data) > 16 * 1_048_576:
        raise ValueError("captured fixture exceeds 16 MiB; choose shorter conversations")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as directory:
        temporary = Path(directory) / "scenario.json"
        temporary.write_bytes(data)
        temporary.chmod(0o600)
        temporary.replace(destination)
    print(json.dumps({"fixture": str(destination), "sha256": hashlib.sha256(data).hexdigest(),
                      "conversations": len(scenario["conversations"]), "events": len(scenario["events"]), "bytes": len(data)}))


def compare(args) -> None:
    def reports(path):
        values = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
        if not values or any(value.get("valid") is not True for value in values):
            raise ValueError("comparison requires nonempty valid scenario reports")
        required = ("fixtureSHA256", "target", "deviceUDID", "operatingSystem", "display", "locale", "toolchain",
                    "configuration", "signing", "driverSHA256", "instrumentation", "mode")
        for value in values:
            missing = [key for key in required if not value.get(key)]
            if "disabled" not in value:
                missing.append("disabled")
            if missing:
                raise ValueError("comparison metadata missing: " + ", ".join(missing))
            if value["mode"] != "offlineReplay":
                raise ValueError("controlled comparison requires offline replay reports")
            samples = value.get("samples", [])
            if not samples or any("thermalState" not in sample or "lowPowerMode" not in sample for sample in samples):
                raise ValueError("comparison requires sampled thermal and power states")
        return values

    before, after = reports(args.before), reports(args.after)
    signatures = {(value["mode"], value["fixtureSHA256"], value["target"], value.get("deviceUDID"), value["operatingSystem"],
                   json.dumps(value.get("display"), sort_keys=True), value.get("locale"),
                   value.get("toolchain"), value.get("configuration"), value.get("signing"),
                   value.get("driverSHA256"),
                   json.dumps(value.get("disabled"), sort_keys=True),
                   json.dumps(value.get("instrumentation"), sort_keys=True),
                   tuple(sorted({(sample["thermalState"], sample["lowPowerMode"]) for sample in value["samples"]})))
                  for value in before + after}
    if len(signatures) != 1:
        raise ValueError("fixture, device, OS, energy state or instrumentation differs")
    output = {"beforeRuns": len(before), "afterRuns": len(after), "fixtureSHA256": before[0]["fixtureSHA256"], "metrics": {}}
    for metric in ["processCPUms", "mainThreadCPUms", "peakSampledFootprintMiB"]:
        groups = [[value[metric] for value in values] for values in [before, after]]
        if any(value is None for group in groups for value in group):
            raise ValueError(f"{metric} was unavailable")
        a, b = [statistics.median(group) for group in groups]
        output["metrics"][metric] = {"beforeMedian": a, "afterMedian": b,
            "changePercent": (b / a - 1) * 100 if a else None,
            "beforeRange": [min(groups[0]), max(groups[0])], "afterRange": [min(groups[1]), max(groups[1])]}
    print(json.dumps(output, indent=2))
