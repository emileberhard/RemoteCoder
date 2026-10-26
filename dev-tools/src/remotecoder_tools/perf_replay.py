import asyncio
import copy
import hashlib
import json
import math
import statistics
import tempfile
import time
import uuid
from pathlib import Path

from .config import _resolve_config
from .rpc import GatewayRPCError, _initialize, _open_gateway, _timed_rpc

MAX_PAGE_BYTES = 16 * 1_048_576
MAX_RECORD_BYTES = 8 * 1_048_576
MAX_HISTORY_BYTES = 24 * 1_048_576
MAX_BUNDLE_BYTES = 512 * 1_048_576
MAX_CONVERSATIONS = 1024
MAX_EVENTS = 20_000


def encoded(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def journey_actions(ids: list[str], duration: float) -> list[dict]:
    actions = []
    for at in range(35, int(duration) - 5, 75):
        index = (at // 75 + 1) % len(ids)
        actions.extend([{"at": at, "kind": "toggleSidebar", "threadID": ids[0]},
                        {"at": at + 2, "kind": "open", "threadID": ids[index]},
                        {"at": at + 3, "kind": "toggleSidebar", "threadID": ids[index]},
                        {"at": at + 5, "kind": "scroll", "threadID": ids[index], "message": 0},
                        {"at": at + 8, "kind": "open", "threadID": ids[0]}])
    return [action for action in actions if action["at"] < duration]


def load_recording(path: Path) -> dict:
    if path.stat().st_size > MAX_PAGE_BYTES:
        raise ValueError("arrival recording exceeds 16 MiB")
    data = path.read_bytes()
    try:
        value = json.loads(data)
    except json.JSONDecodeError:
        value = None
    if isinstance(value, dict) and isinstance(value.get("events"), list):
        return value
    events = []
    for line in data.splitlines():
        if not line.strip():
            continue
        entry = json.loads(line)
        frame = json.loads(entry["raw"])
        if isinstance(frame.get("method"), str) and isinstance(frame.get("params"), dict):
            events.append({"at": entry["t"], "frame": frame})
        if len(events) > MAX_EVENTS:
            raise ValueError("arrival recording exceeds bounded event count")
    return {"events": events}


def assign_item_ordinals(events: list[dict], last_ordinals: dict[str, int]) -> None:
    if any(type(value) is not int or not 0 <= value <= 2**63 - 1 - MAX_EVENTS for value in last_ordinals.values()):
        raise ValueError("history ordinals must leave room for the bounded replay")
    next_ordinals = dict(last_ordinals)
    assigned = {}
    for event in events:
        params = event["frame"].get("params", {})
        thread = params.get("threadId")
        item = params.get("item", {}).get("id") or params.get("itemId")
        if thread not in next_ordinals or not item:
            continue
        key = (thread, item)
        if key not in assigned:
            next_ordinals[thread] += 1
            assigned[key] = next_ordinals[thread]
        if event["frame"].get("method") in {"item/started", "item/completed"}:
            params["startedAtOrdinal"] = assigned[key]


def replay_recording(recording: dict, last_ordinals: dict[str, int], duration: float) -> list[dict]:
    ids = list(last_ordinals)
    source = recording.get("events", [])
    if any(not isinstance(event.get("at"), (int, float)) or not math.isfinite(event["at"]) or event["at"] < 0
           or not isinstance(event.get("frame"), dict) for event in source):
        raise ValueError("recording requires finite nonnegative arrival offsets and frames")
    if not source:
        raise ValueError("recording has no arrival-timed events")
    observed_turns = recording_turn_ids(recording)
    if any(len(turn_ids) != 1 for turn_ids in observed_turns.values()):
        raise ValueError("recording has inconsistent turn identities within a stream")
    sources = list(observed_turns)
    if not sources or len(sources) > len(ids):
        raise ValueError("recorded stream count must fit the selected idle histories")
    mapping = dict(zip(sources, ids, strict=False))
    first = min(event["at"] for event in source)
    last = max(event["at"] for event in source)
    period = last - first
    if not math.isfinite(period) or period <= 0:
        raise ValueError("recorded arrival span must be positive")
    methods = {event["frame"].get("method") for event in source}
    if "item/agentMessage/delta" not in methods:
        raise ValueError("recording has no assistant streaming deltas")
    events = []
    observed_starts = {event["frame"].get("params", {}).get("threadId") for event in source
                       if event["frame"].get("method") == "turn/started"}
    inferred = set(sources) - observed_starts
    started = set()
    for original in inferred:
        at = 2 + min(event["at"] for event in source if event["frame"].get("params", {}).get("threadId") == original) - first
        turn = {"id": f"replay-turn-{sources.index(original)}", "status": "inProgress", "items": [],
                "itemsView": "full", "error": None, "startedAt": int(time.time() + at), "completedAt": None, "durationMs": None}
        events.append({"at": round(at, 6), "frame": {"method": "turn/started", "params": {"threadId": mapping[original], "turn": turn}}})
        started.add(original)
    for cycle in range(math.ceil((duration - 2) / period)):
        for entry in source:
            at = 2 + cycle * period + entry["at"] - first
            if at >= duration:
                continue
            frame = copy.deepcopy(entry["frame"])
            frame.pop("rcSequence", None)
            params = frame.get("params", {})
            original = params.get("threadId")
            if original not in mapping:
                continue
            method = frame.get("method", "")
            if method in {"turn/completed", "daemon/activeTurns/changed"} or (method == "thread/status/changed" and params.get("status", {}).get("type") == "idle"):
                continue
            if method == "turn/started":
                if original in started:
                    continue
                started.add(original)
            params["threadId"] = mapping[original]
            turn_id = f"replay-turn-{sources.index(original)}"
            if "turnId" in params:
                params["turnId"] = turn_id
            if isinstance(params.get("turn"), dict):
                params["turn"].update(id=turn_id, status="inProgress", items=[], completedAt=None, durationMs=None,
                                      startedAt=int(time.time() + at))
            if "itemId" in params:
                params["itemId"] = f"replay-{cycle}-{params['itemId']}"
            if isinstance(params.get("item"), dict):
                params["item"]["id"] = f"replay-{cycle}-{params['item']['id']}"
                if "clientId" in params["item"]:
                    params["item"]["clientId"] = f"replay-{cycle}-{params['item']['clientId']}"
            events.append({"at": round(at, 6), "frame": frame})
            if len(events) > MAX_EVENTS:
                raise ValueError("recording exceeds bounded replay event budget")
    events.sort(key=lambda event: event["at"])
    assign_item_ordinals(events, last_ordinals)
    published = []
    for event in events:
        published.append(event)
        if event["frame"]["method"] == "turn/started":
            published.append({"at": event["at"], "frame": {"method": "daemon/activeTurns/changed",
                              "params": {"threadId": event["frame"]["params"]["threadId"]}}})
    if len(published) > MAX_EVENTS:
        raise ValueError("recording exceeds bounded replay event budget")
    return published


def recording_turn_ids(recording: dict) -> dict[str, set[str]]:
    turns = {}
    for event in recording.get("events", []):
        params = event["frame"].get("params", {})
        turn_id = params.get("turnId") or params.get("turn", {}).get("id")
        if turn_id and params.get("threadId"):
            turns.setdefault(params["threadId"], set()).add(turn_id)
    return turns


def scenario_from_conversations(conversations: list[dict], responses: dict, errors: dict, http: dict,
                          *, recording: dict | None = None, duration: float = 300) -> dict:
    if not 1 <= len(conversations) <= MAX_CONVERSATIONS:
        raise ValueError("capture between one and 1,024 conversations")
    if not 60 <= duration <= 900 or not math.isfinite(duration):
        raise ValueError("duration must be between 60 and 900 seconds")
    ids = [conversation["thread"]["id"] for conversation in conversations]
    last_ordinals = {}
    for conversation in conversations:
        if "itemFile" in conversation and "lastStartedAtOrdinal" not in conversation:
            raise ValueError("indexed histories require their captured final item ordinal")
        last_ordinals[conversation["thread"]["id"]] = conversation.get("lastStartedAtOrdinal",
            max((item.get("startedAtOrdinal") or 0 for item in conversation["items"]), default=0))
    events = replay_recording(recording, last_ordinals, duration) if recording is not None else []
    return {"version": 2, "capturedAt": int(time.time()), "name": "field-state-v2", "duration": duration,
            "conversations": conversations, "events": events, "actions": journey_actions(ids[:3], duration),
            "responses": responses, "errors": errors, "httpResponses": http,
            "provenance": {"content": "captured idle conversation histories and recorded notifications",
                           "pacing": "recorded host arrival offsets, repeated with distinct items and continuous turns"
                                     if recording is not None else "history-only preparation; no stream timing supplied",
                           "turnCompletion": "recorded completion and idle notifications omitted to keep measured agent turns continuous",
                           "initialState": "streams missing turn/started begin at first observed activity; original start is unknown",
                           "recordedTurnIDs": {thread_id: next(iter(turn_ids)) for thread_id, turn_ids in recording_turn_ids(recording).items()} if recording else {},
                           "scope": "offline text, tools and persisted state; external assets remain blocked"}}


def write_history(root: Path, records: list[dict], kind: str) -> dict:
    offsets = [0]
    digest = hashlib.sha256()
    directory = root / "history"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=directory, delete=False) as output:
        temporary = Path(output.name)
        try:
            for record in records:
                line = encoded(record) + b"\n"
                if len(line) > min(MAX_RECORD_BYTES, MAX_PAGE_BYTES) or offsets[-1] + len(line) > MAX_HISTORY_BYTES:
                    raise ValueError("captured history exceeds bounded record or file bytes")
                output.write(line)
                digest.update(line)
                offsets.append(offsets[-1] + len(line))
            output.flush()
            temporary.chmod(0o600)
            relative = f"history/{digest.hexdigest()}-{kind}.jsonl"
            temporary.replace(root / relative)
        finally:
            temporary.unlink(missing_ok=True)
    return {"path": relative, "offsets": offsets, "sha256": digest.hexdigest()}


def local_submission(thread_id: str, items: list[dict]) -> dict | None:
    for entry in reversed(items):
        item = entry["item"]
        if item.get("type") != "userMessage" or not entry.get("turnId"):
            continue
        content = item.get("content", [])
        if not content or any(part.get("type") != "text" for part in content):
            continue
        text = "\n".join(part["text"] for part in content)
        if not text.strip() or len(text.encode()) > 1_048_576:
            continue
        original = item.get("clientId")
        try:
            message_id = str(uuid.UUID(original)) if original else None
        except (ValueError, TypeError, AttributeError):
            message_id = None
        message_id = message_id or str(uuid.uuid5(uuid.NAMESPACE_URL, f"remotecoder-replay:{thread_id}:{item['id']}"))
        item["clientId"] = message_id
        return {"messageID": message_id, "turnID": entry["turnId"], "text": text}
    return None


def private_destination(path) -> Path:
    destination = Path(path).expanduser().resolve()
    root = (Path.home() / "perf-traces/remotecoder").resolve()
    if not destination.is_relative_to(root) or any((parent / ".git").exists() for parent in destination.parents):
        raise ValueError("real replay data must stay under ~/perf-traces/remotecoder outside Git checkouts")
    return destination


def idle_threads(activity: dict) -> tuple[set[str], dict]:
    coverage = activity.get("coverage", {})
    external = activity.get("externalActivity", {})
    excluded = {turn["threadId"] for turn in activity.get("activeTurns", [])}
    excluded.update(entry["threadId"] for entry in external.get("sessions", []) if entry.get("state") != "idle")
    authoritative = {provider: coverage.get(provider) is True and external.get(provider + "Available") is True
                     for provider in ("codex", "claude")}
    return excluded, authoritative


async def capture_batched_services(read, ids: list[str], responses: dict, errors: dict) -> None:
    for method, limit, parameter, keys in (
        ("conversation/agents/classify", 200, "threadIds", {"relations": {}, "knownRoots": [], "warnings": []}),
        ("conversation/questions/read", 16, "queries", {"threads": []}),
    ):
        combined = copy.deepcopy(keys)
        try:
            for offset in range(0, len(ids), limit):
                batch = ids[offset:offset + limit]
                values = batch if parameter == "threadIds" else [{"threadId": thread_id, "itemIds": []} for thread_id in batch]
                page = await read(method, {parameter: values})
                for key, collection in combined.items():
                    if isinstance(collection, dict):
                        collection.update(page.get(key, {}))
                    else:
                        collection.extend(page.get(key, []))
            responses[method] = combined
            errors.pop(method, None)
        except GatewayRPCError as error:
            errors[method] = {"code": error.code, "message": "Captured unavailable optional service"}
            responses.pop(method, None)


def preparation_roots(known_roots: set[str], marks: dict, journey_targets: set[str]) -> set[str]:
    return {thread_id for thread_id in known_roots
            if marks.get(thread_id, {}).get("purpose") is None
            or (thread_id in journey_targets and marks.get(thread_id, {}).get("purpose") in {"probe", "automation"})}


async def capture(args) -> dict:
    config = _resolve_config(args)
    destination = private_destination(args.out)
    root = destination.parent if destination.suffix else destination
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    sidebar_limit = getattr(args, "sidebar_limit", 1024)
    history_count = getattr(args, "history_count", 700 if hasattr(args, "recording") else len(args.thread))
    if not 1 <= history_count <= sidebar_limit <= MAX_CONVERSATIONS:
        raise ValueError("require 1 <= history count <= sidebar limit <= 1,024")
    selected = list(dict.fromkeys(args.thread))
    if len(selected) > history_count:
        raise ValueError("selected histories exceed history count")
    recording_path = getattr(args, "recording", None)
    if hasattr(args, "recording") and not recording_path:
        raise ValueError("capture requires --recording with real host arrival timing")
    recording = load_recording(private_destination(recording_path)) if recording_path else None
    responses, errors, http, thread_responses = {}, {}, {}, {}
    headers, conversations, skipped = {}, [], {"activeOrUnknown": 0, "boundedOrUnavailable": 0}
    total_bytes = 0
    completion_times = None
    async with _open_gateway(config, timeout_s=30, method="thread/list") as ws:
        await _initialize(ws, timeout_s=30)
        request_id = 10

        async def read(method, params):
            nonlocal request_id
            request_id += 1
            result, _, size = await _timed_rpc(ws, req_id=request_id, method=method, params=params, timeout_s=30)
            if size > MAX_PAGE_BYTES:
                raise ValueError("gateway page exceeds 16 MiB")
            return result

        async def activity_state():
            activity = await read("daemon/activeTurns", {})
            excluded, coverage = idle_threads(activity)
            external = activity.get("externalActivity", {})
            evidence = {"snapshotSHA256": hashlib.sha256(encoded(activity)).hexdigest(),
                        "providerCoverage": activity.get("coverage", {}),
                        "externalAvailability": {provider: external.get(provider + "Available") for provider in ("codex", "claude")},
                        "activeTurns": len(activity.get("activeTurns", [])),
                        "externalSessions": len(external.get("sessions", []))}
            return excluded, coverage, evidence

        excluded, coverage, _ = await activity_state()
        completion_metadata_started_at = int(time.time())
        inventory = {"thread/list": {"cursor": None, "seen": set()},
                     "claude/thread/list": {"cursor": None, "seen": set()}}
        while inventory and len(headers) < sidebar_limit:
            for method in list(inventory):
                if len(headers) >= sidebar_limit:
                    break
                state = inventory[method]
                params = {"limit": min(100, sidebar_limit - len(headers)), "cursor": state["cursor"]}
                if method == "thread/list":
                    params["includeCompletionTimes"] = True
                page = await read(method, params)
                if method == "thread/list" and isinstance(page.get("completionTimes"), dict):
                    if completion_times is None:
                        completion_times = {}
                    completion_times.update(page["completionTimes"])
                for thread in page["data"]:
                    headers[thread["id"]] = {**thread, "turns": []}
                cursor = page.get("nextCursor")
                if cursor is None:
                    del inventory[method]
                elif cursor in state["seen"]:
                    raise ValueError("thread inventory cursor did not advance")
                else:
                    state["seen"].add(cursor)
                    state["cursor"] = cursor
        completion_metadata_ended_at = int(time.time())
        for thread_id in selected:
            if thread_id not in headers:
                if len(headers) >= MAX_CONVERSATIONS:
                    removable = next(key for key in reversed(headers) if key not in selected)
                    del headers[removable]
                headers[thread_id] = (await read("thread/read", {"threadId": thread_id, "includeTurns": False}))["thread"]
        if len(headers) > MAX_CONVERSATIONS:
            raise ValueError("explicit histories exceed bounded sidebar inventory")

        await capture_batched_services(read, list(headers), responses, errors)
        classification = responses.get("conversation/agents/classify")
        if classification is None:
            raise ValueError("authoritative root classification is unavailable")
        known_roots = set(classification.get("knownRoots", []))
        responses["conversation/marks/read"] = await read("conversation/marks/read", {})
        marks = responses["conversation/marks/read"].get("threads")
        if not isinstance(marks, dict):
            raise ValueError("authoritative conversation purposes are unavailable")
        journey_targets = set(selected[:min(3, len(recording_turn_ids(recording)))]) if recording else set()
        eligible_roots = preparation_roots(known_roots, marks, journey_targets)
        root_candidates = sorted((thread_id for thread_id in headers if thread_id in known_roots),
                                 key=lambda thread_id: marks.get(thread_id, {}).get("purpose") is not None)
        candidates = list(dict.fromkeys(selected + root_candidates))

        async def page_history(thread_id, method):
            records, cursor, seen = [], None, set()
            size = 0
            pages = hashlib.sha256()
            while True:
                params = {"threadId": thread_id, "limit": 100, "sortDirection": "asc", "cursor": cursor}
                if method == "thread/turns/list":
                    params["itemsView"] = "notLoaded"
                page = await read(method, params)
                pages.update(encoded({"cursor": cursor, "page": page}))
                for record in page["data"]:
                    size += len(encoded(record)) + 1
                    if len(encoded(record)) + 1 > MAX_RECORD_BYTES or size > MAX_HISTORY_BYTES or len(records) >= 20_000:
                        raise ValueError("history exceeds 24 MiB")
                    records.append(record)
                cursor = page.get("nextCursor")
                if cursor is None:
                    return records, pages.hexdigest()
                if cursor in seen:
                    raise ValueError("history cursor did not advance")
                seen.add(cursor)

        for thread_id in candidates:
            if len(conversations) >= history_count:
                break
            provider = "claude" if thread_id.startswith("claude_") else "codex"
            if thread_id in excluded or coverage.get(provider) is not True:
                skipped["activeOrUnknown"] += 1
                if thread_id in selected:
                    raise ValueError("selected thread is active or activity coverage is unknown")
                continue
            try:
                for attempt in range(3):
                    before = await activity_state()
                    if thread_id in before[0] or before[1].get(provider) is not True:
                        raise ValueError("candidate activity changed before capture")
                    turns, turn_pages = await page_history(thread_id, "thread/turns/list")
                    items, item_pages = await page_history(thread_id, "thread/items/list")
                    verified_turns, verified_turn_pages = await page_history(thread_id, "thread/turns/list")
                    _, verified_item_pages = await page_history(thread_id, "thread/items/list")
                    after = await activity_state()
                    if thread_id in after[0] or after[1].get(provider) is not True:
                        raise ValueError("candidate activity changed during capture")
                    turn_ids = {turn["id"] for turn in turns}
                    consistent = (turn_pages == verified_turn_pages and item_pages == verified_item_pages
                                  and len(turn_ids) == len(turns)
                                  and all(item.get("turnId") in turn_ids for item in items)
                                  and not any(turn.get("status") == "inProgress" for turn in turns + verified_turns))
                    if consistent:
                        break
                else:
                    raise ValueError("history changed during bounded capture revalidation")
                submission = local_submission(thread_id, items) if thread_id in eligible_roots else None
                size = sum(len(encoded(record)) + 1 for record in items + turns)
                if total_bytes + size > MAX_BUNDLE_BYTES - MAX_PAGE_BYTES:
                    raise ValueError("fixture bundle exceeds 512 MiB")
                conversation = {"thread": {**headers[thread_id], "turns": [], "status": {"type": "idle"}},
                                "items": [], "turns": [],
                                "captureActivityEvidence": {"provider": provider, "before": before[2], "after": after[2],
                                                            "historyValidation": {"attempts": attempt + 1, "turnPagesSHA256": turn_pages,
                                                                                  "itemPagesSHA256": item_pages, "turns": len(turns), "items": len(items)}},
                                "lastStartedAtOrdinal": max((item.get("startedAtOrdinal") or 0 for item in items), default=0),
                                "itemFile": write_history(root, items, "items"),
                                "turnFile": write_history(root, turns, "turns")}
                if submission is not None:
                    conversation["localSubmission"] = submission
                conversations.append(conversation)
                total_bytes += size
            except (GatewayRPCError, ValueError):
                skipped["boundedOrUnavailable"] += 1
                if thread_id in selected:
                    raise ValueError("selected history is unavailable, active or exceeds fixture bounds") from None
        if not conversations:
            raise ValueError("no idle histories with authoritative activity coverage were captured")
        for thread_id, thread in headers.items():
            if thread_id not in {conversation["thread"]["id"] for conversation in conversations}:
                conversations.append({"thread": {**thread, "turns": [], "status": {"type": "idle"}}, "items": [], "turns": []})
        ids = [conversation["thread"]["id"] for conversation in conversations]
        for method, params in {
            "model/list": {}, "account/read": {}, "account/rateLimits/read": {},
            "conversation/metadata/read": {},
            "host/info": {}, "directory/favorites/read": {},
            "conversation/projects/resolve": {"directories": sorted({thread.get("cwd", "") for thread in headers.values()})},
        }.items():
            try:
                responses[method] = await read(method, params)
            except GatewayRPCError as error:
                errors[method] = {"code": error.code, "message": "Captured unavailable optional service"}
        if "host/info" in responses:
            responses["fs/readDirectory"] = await read("fs/readDirectory", {"path": responses["host/info"]["homeDirectory"]})
        relations = responses.get("conversation/agents/classify", {}).get("relations", {})
        related = {relation["parentThreadId"] for relation in relations.values()} - set(ids)
        for thread_id in sorted(related):
            if len(conversations) >= MAX_CONVERSATIONS:
                removable = next((index for index in range(len(conversations) - 1, -1, -1)
                                  if "itemFile" not in conversations[index] and conversations[index]["thread"]["id"] not in related), None)
                if removable is None:
                    raise ValueError("referenced parent headers exceed fixture conversation limit")
                conversations.pop(removable)
            thread = (await read("thread/read", {"threadId": thread_id, "includeTurns": False}))["thread"]
            conversations.append({"thread": {**thread, "turns": []}, "items": [], "turns": []})
        for conversation in conversations:
            thread_id = conversation["thread"]["id"]
            try:
                reply = {"result": await read("conversation/agents/list", {"threadId": thread_id})}
            except GatewayRPCError as error:
                reply = {"error": {"code": error.code, "message": "Captured unavailable optional service"}}
            thread_responses[thread_id] = {"conversation/agents/list": reply}
    async with config.http_client(timeout=15) as client:
        for path in ["/accounts", "/claude/accounts"]:
            response = await client.get(config.http_base + path, headers={"Authorization": f"Bearer {config.token}"})
            http["GET " + path] = {"status": response.status_code, "body": response.json()}
    if "conversation/metadata/read" in responses:
        responses["conversation/metadata/read"]["entries"] = [entry for entry in responses["conversation/metadata/read"]["entries"]
                                                              if entry["sessionID"] in ids]
    if "conversation/marks/read" in responses:
        responses["conversation/marks/read"]["threads"] = {key: value for key, value in responses["conversation/marks/read"]["threads"].items()
                                                           if key in ids}
    http["POST /app-logs"] = {"status": 200, "body": {"stored": "offline-replay.jsonl.gz"}}
    history_ids = [conversation["thread"]["id"] for conversation in conversations if "itemFile" in conversation]
    scenario = scenario_from_conversations(conversations, responses, errors, http,
                                           recording=recording, duration=getattr(args, "duration", 300))
    captured_ids = {conversation["thread"]["id"] for conversation in conversations}
    if completion_times is not None:
        scenario["completionTimes"] = {key: value for key, value in completion_times.items() if key in captured_ids}
    scenario["provenance"]["historySelection"] = "explicit stream targets, ordinary authoritative known roots, then remaining root histories; other child and unresolved conversations retain headers only"
    scenario["provenance"]["localPreparation"] = "all eligible ordinary known roots; at most three explicit recorded journey purpose exceptions; actual phone ownership is unknown"
    scenario["provenance"]["completionMetadata"] = {"startedAtUnixSeconds": completion_metadata_started_at,
        "capturedAtUnixSeconds": completion_metadata_ended_at,
        "source": "thread/list completionTimes sibling map", "includeCompletionTimes": True,
        "mapAvailable": completion_times is not None}
    return {**scenario, "threadResponses": thread_responses,
            "captureSummary": {"sidebarConversations": len(conversations), "histories": len(history_ids),
                               "knownRootHistories": sum(thread_id in known_roots for thread_id in history_ids),
                               "inventoryKnownRoots": len(known_roots),
                               "historyBytes": total_bytes, "skipped": skipped,
                               "idleEvidence": {"contractVersion": 2, "capturedHistories": len(history_ids),
                                                "beforeAndAfterChecks": sum(isinstance(conversation.get("captureActivityEvidence", {}).get(phase), dict)
                                                    for conversation in conversations for phase in ("before", "after")),
                                                "requiresProviderCoverage": True, "requiresExternalAvailability": True}}}


def capture_command(args) -> None:
    destination = private_destination(args.out)
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    scenario = asyncio.run(capture(args))
    data = encoded(scenario)
    if len(data) > MAX_PAGE_BYTES:
        raise ValueError("fixture manifest exceeds 16 MiB")
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(data)
            output.flush()
            temporary.chmod(0o600)
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)
    print(json.dumps({"fixture": str(destination), "sha256": hashlib.sha256(data).hexdigest(),
                      "events": len(scenario["events"]), "manifestBytes": len(data), **scenario["captureSummary"]}))


def state_metrics(report: dict) -> dict:
    groups = {}
    excluded = {"mixed": 0, "gap": 0}
    samples = report["samples"]
    has_fixture = any("fixtureCPUms" in sample for sample in samples)
    fixture_measured = has_fixture and all(isinstance(sample.get("fixtureCPUms"), (int, float))
        and math.isfinite(sample["fixtureCPUms"]) for sample in samples)
    for start, end in zip(samples, samples[1:], strict=False):
        seconds = end["at"] - start["at"]
        if seconds <= 0:
            raise ValueError("sample elapsed time must increase")
        if seconds > 45:
            excluded["gap"] += 1
            continue
        if end.get("mixed"):
            excluded["mixed"] += 1
            continue
        context = start["context"]
        if context["scene"] != "active":
            state = "background" if context["scene"] == "background" else "inactive"
        elif context["voiceCall"]:
            state = "voiceCall"
        elif context["surface"] == "chat" and context["turnRunningVisible"] is True:
            state = "agentWorking"
        elif context["surface"] == "chat" and context["turnRunningVisible"] is False:
            state = "chatIdle"
        else:
            state = context["surface"]
        counters = {metric: end[metric] - start[metric] for metric in ("processCPUms", "mainThreadCPUms")}
        counters["checkpointBytes"] = end["persistence"]["checkpoints"]["bytes"] - start["persistence"]["checkpoints"]["bytes"]
        if fixture_measured:
            counters["fixtureCPUms"] = end["fixtureCPUms"] - start["fixtureCPUms"]
        if any(value < 0 or not math.isfinite(value) for value in counters.values()):
            raise ValueError("sample counters reset or are nonfinite")
        group = groups.setdefault(state, {"seconds": 0, "processCPUms": 0, "mainThreadCPUms": 0, "checkpointBytes": 0,
                                          **({"fixtureCPUms": 0} if fixture_measured else {})})
        group["seconds"] += seconds
        for metric, value in counters.items():
            group[metric] += value
    if not groups.get("agentWorking", {}).get("seconds"):
        raise ValueError("comparison has no measured agent-working interval")
    result = {"excludedIntervals": excluded}
    for state, group in groups.items():
        seconds = group["seconds"]
        result[state] = {"seconds": seconds, "processCPUPercent": group["processCPUms"] / seconds / 10,
                         "mainThreadCPUPercent": group["mainThreadCPUms"] / seconds / 10,
                         "checkpointBytesPerMinute": group["checkpointBytes"] / seconds * 60}
        if has_fixture:
            result[state].update({"measuredFixtureCPUPercent": group["fixtureCPUms"] / seconds / 10 if fixture_measured else None,
                "processCPUWithoutMeasuredFixturePercent": (group["processCPUms"] - group["fixtureCPUms"]) / seconds / 10 if fixture_measured else None,
                "measuredFixtureCPUSharePercent": group["fixtureCPUms"] / group["processCPUms"] * 100
                    if fixture_measured and group["processCPUms"] > 0 else None})
    return result


def compare(args) -> None:
    identity_keys = ("appExecutableSHA256", "sourceCommit", "sourceFingerprint")

    def reports(path):
        values = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
        if not values or any(value.get("valid") is not True for value in values):
            raise ValueError("comparison requires nonempty valid scenario reports")
        required = ("fixtureSHA256", "target", "deviceUDID", "operatingSystem", "display", "locale", "toolchain",
                    "configuration", "signing", "driverSHA256", "instrumentation", "mode",
                    "workloadVersion", "preparationContractVersion", "preparation", "captureAuthority",
                    "preMeasurementOwner", "postMeasurementOwner", *identity_keys)
        for value in values:
            missing = [key for key in required if not value.get(key)]
            if "disabled" not in value:
                missing.append("disabled")
            if missing:
                raise ValueError("comparison metadata missing: " + ", ".join(missing))
            if value["mode"] != "offlineReplay" or value["workloadVersion"] != 2 or value["preparationContractVersion"] != 2:
                raise ValueError("controlled comparison requires version-two prepared offline replay reports")
            authority = value["captureAuthority"]
            if (authority.get("contractVersion") != 2 or authority.get("requiresExternalAvailability") is not True
                    or authority.get("requiresProviderCoverage") is not True
                    or authority.get("beforeAndAfterChecks") != authority.get("capturedHistories", 0) * 2):
                raise ValueError("comparison requires authoritative idle capture evidence")
            preparation = value["preparation"]
            if (not isinstance(preparation, dict)
                    or not isinstance(preparation.get("conversations"), int)
                    or not isinstance(preparation.get("sidebarConversations"), int)
                    or not 1 <= preparation["conversations"] <= preparation.get("capturedSidebarConversations", 0) <= MAX_CONVERSATIONS
                    or not 1 <= preparation["sidebarConversations"] <= preparation["capturedSidebarConversations"]):
                raise ValueError("comparison requires nonzero bounded preparation counts")
            owner = preparation.get("owner", {})
            if (not isinstance(preparation.get("preservedCheckpointCount"), int)
                    or preparation["preservedCheckpointCount"] < preparation["conversations"]
                    or not all(isinstance(owner.get(key), int) and owner[key] > 0
                               for key in ("records", "primaryPayloadBytes", "cacheLimitBytes", "primaryLimitBytes"))
                    or owner.get("unknownProtectionRecords") != 0
                    or owner.get("evictionBytes", 0) <= owner.get("cacheLimitBytes", 0)):
                raise ValueError("comparison requires verified preserved checkpoints and owner accounting")
            before_owner = value["preMeasurementOwner"]
            after_owner = value["postMeasurementOwner"]
            for inventory in (before_owner, after_owner):
                if (not isinstance(inventory, dict)
                        or not all(type(inventory.get(key)) is int and inventory[key] >= 0
                                   for key in ("records", "protectedRecords", "unknownProtectionRecords", "recordBytes",
                                               "primaryPayloadBytes", "cacheBytes", "evictionBytes"))
                        or not all(type(inventory.get(key)) is int and inventory[key] > 0
                                   for key in ("cacheLimitBytes", "primaryLimitBytes"))):
                    raise ValueError("comparison requires complete pre/post measurement owner inventories")
            if (before_owner["evictionBytes"] <= before_owner["cacheLimitBytes"]
                    or before_owner["unknownProtectionRecords"] != 0
                    or before_owner["protectedRecords"] < preparation["conversations"]):
                raise ValueError("comparison requires verified preserved state under pressure immediately before measurement")
            samples = value.get("samples", [])
            if len(samples) < 2 or any("thermalState" not in sample or "lowPowerMode" not in sample for sample in samples):
                raise ValueError("comparison requires sampled thermal and power states")
            for sample in samples:
                context = sample.get("context", {})
                if any(key not in context for key in ("scene", "surface", "turnRunningVisible", "voiceCall")):
                    raise ValueError("comparison requires sampled field activity context")
                if any(not isinstance(sample.get(key), (float, int)) or not math.isfinite(sample[key])
                       for key in ("at", "processCPUms", "mainThreadCPUms")):
                    raise ValueError("comparison requires elapsed time and cumulative CPU counters")
                checkpoints = sample.get("persistence", {}).get("checkpoints", {})
                if not isinstance(checkpoints.get("bytes"), int):
                    raise ValueError("comparison requires cumulative checkpoint byte counters")
                if not isinstance(context["voiceCall"], bool) or context["turnRunningVisible"] not in (True, False, None):
                    raise ValueError("invalid sampled field activity context")
        if any(not isinstance(value[key], str) or not value[key] for value in values for key in identity_keys):
            raise ValueError("comparison requires complete build identity")
        if len({tuple(value[key] for key in identity_keys) for value in values}) != 1:
            raise ValueError("comparison requires exactly one build identity per side")
        return values

    before, after = reports(args.before), reports(args.after)
    signatures = {(value["mode"], value["fixtureSHA256"], value["target"], value.get("deviceUDID"), value["operatingSystem"],
                   json.dumps(value.get("display"), sort_keys=True), value.get("locale"),
                   value.get("toolchain"), value.get("configuration"), value.get("signing"),
                   value.get("driverSHA256"), value["workloadVersion"], value["preparationContractVersion"],
                   json.dumps(value.get("disabled"), sort_keys=True),
                   json.dumps(value.get("instrumentation"), sort_keys=True),
                   tuple(sorted({(sample["thermalState"], sample["lowPowerMode"]) for sample in value["samples"]})))
                  for value in before + after}
    if len(signatures) != 1:
        raise ValueError("fixture, device, OS, energy state or instrumentation differs")
    states = [[state_metrics(value) for value in values] for values in (before, after)]
    for values, measurements in zip((before, after), states, strict=True):
        for value, measured in zip(values, measurements, strict=True):
            seconds = value.get("seconds")
            if not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or seconds <= 0:
                raise ValueError("comparison requires measured report seconds")
            working = measured["agentWorking"]["seconds"]
            if working < seconds * 0.8:
                raise ValueError(f"unrepresentative replay: agent-working context covered {working:.3f} of {seconds:.3f} seconds; at least 80% is required after mixed/gap exclusions")
    output = {"beforeRuns": len(before), "afterRuns": len(after), "fixtureSHA256": before[0]["fixtureSHA256"],
              "buildIdentity": {"before": {key: before[0][key] for key in identity_keys},
                                "after": {key: after[0][key] for key in identity_keys}},
              "metrics": {}, "activity": {"before": states[0], "after": states[1]},
              "preparation": {"before": [value["preparation"] for value in before],
                              "after": [value["preparation"] for value in after]},
              "preMeasurementOwner": {"before": [value["preMeasurementOwner"] for value in before],
                                      "after": [value["preMeasurementOwner"] for value in after]},
              "postMeasurementOwner": {"before": [value["postMeasurementOwner"] for value in before],
                                       "after": [value["postMeasurementOwner"] for value in after]}}

    def metric(name, groups):
        if any(not isinstance(value, (int, float)) or not math.isfinite(value) for group in groups for value in group):
            raise ValueError(f"{name} was unavailable")
        a, b = [statistics.median(group) for group in groups]
        output["metrics"][name] = {"beforeMedian": a, "afterMedian": b,
            "changePercent": (b / a - 1) * 100 if a else None,
            "beforeRange": [min(groups[0]), max(groups[0])], "afterRange": [min(groups[1]), max(groups[1])]}

    for name in ("processCPUPercent", "mainThreadCPUPercent", "checkpointBytesPerMinute"):
        metric("agentWorking." + name, [[value["agentWorking"][name] for value in group] for group in states])
    for name in ("processCPUms", "mainThreadCPUms", "peakSampledFootprintMiB"):
        if any(name in value for value in before + after):
            metric(name, [[value.get(name) for value in values] for values in (before, after)])
    print(json.dumps(output, indent=2))
