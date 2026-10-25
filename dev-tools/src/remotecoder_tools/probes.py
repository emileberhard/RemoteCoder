import argparse
import asyncio
import base64
import datetime
import hashlib
import json
import math
import re
import secrets
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import quote, unquote, urlsplit

from .config import DEFAULT_CODEX_PROBE_MODEL, GatewayConfig, _resolve_config
from .diagnostics import _journal_read
from .file_io import file_chunks, finish_thread_io, write_receipt
from .performance import _native_page_entries
from .rpc import (
    _drain_ready,
    _event_thread_id,
    _initialize,
    _json,
    _timed_rpc,
    _ws_connect,
    _ws_recv_json,
)
from .turns import (
    _assert_e2e,
    _norm_turn_id,
    _probe_turn,
    _run_probe_turn,
    _sandbox_policy,
    _thread_text,
    mark_purpose,
    purpose_params,
)
from .verdict import cleanup_after


async def _fork_probe_history(ws, *, next_id, thread_id: str, timeout_s: float) -> tuple[list[str | None], str]:
    result, _elapsed, _byte_count = await _timed_rpc(
        ws, req_id=next_id(), method="thread/turns/list",
        params={"threadId": thread_id, "limit": 10, "sortDirection": "asc", "itemsView": "notLoaded"},
        timeout_s=timeout_s,
    )
    turns = _native_page_entries(result, limit=10)
    _assert_e2e(result.get("nextCursor") is None, "fork fixture exceeded bounded turn probe budget")
    items = []
    cursor = None
    for _ in range(20):
        page, _elapsed, _bytes = await _timed_rpc(
            ws, req_id=next_id(), method="thread/items/list",
            params={"threadId": thread_id, "limit": 20, "sortDirection": "asc", "cursor": cursor},
            timeout_s=timeout_s,
        )
        items.extend(entry["item"] for entry in _native_page_entries(page, limit=20))
        cursor = page.get("nextCursor")
        if cursor is None:
            break
    _assert_e2e(cursor is None, "fork fixture exceeded bounded item probe budget")
    return [_norm_turn_id(turn["id"]) for turn in turns], _thread_text({"turns": [{"items": items}]})


async def cmd_e2e_fork_live(args: argparse.Namespace) -> int:
    cfg = _resolve_config(args)
    req_id = 1

    def next_id() -> int:
        nonlocal req_id
        value = req_id
        req_id += 1
        return value

    def report(label: str, detail: str) -> None:
        print(f"PASS {label}: {detail}")

    run_id = uuid.uuid4().hex[:8].upper()
    marker_a = f"RCFORK-{run_id}-A"
    marker_b = f"RCFORK-{run_id}-B"
    source_name = f"rc-fork-{run_id}"
    async with await _ws_connect(cfg) as ws:
        _ = await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)

        async def fork(last_turn_id: str | None) -> dict[str, Any]:
            result, elapsed, _byte_count = await _timed_rpc(
                ws,
                req_id=next_id(),
                method="thread/fork",
                params={
                    "threadId": first.thread_id,
                    "lastTurnId": last_turn_id,
                    "persistExtendedHistory": True,
                    "excludeTurns": True,
                    "threadSource": "user",
                },
                timeout_s=args.timeout,
            )
            thread = result.get("thread")
            _assert_e2e(isinstance(thread, dict), "thread/fork returned no thread")
            fork_id = str(thread.get("id") or "")
            _assert_e2e(fork_id not in ("", first.thread_id), "thread/fork returned no new thread id")
            _assert_e2e(thread.get("forkedFromId") == first.thread_id, "fork did not name its source thread")
            _assert_e2e(thread.get("name") == source_name, f"fork name was {thread.get('name')!r}, expected the source name")
            await mark_purpose(ws, next_id=next_id, thread_id=fork_id, purpose="probe", timeout_s=args.timeout)
            report("fork", f"thread={fork_id} through={last_turn_id or 'latest'} elapsed={elapsed:.2f}s")
            return thread

        first = await _run_probe_turn(
            ws,
            next_id=next_id,
            prompt=(
                "RemoteCoder live fork integration test. "
                f"Remember marker {marker_a}. Reply exactly: ACK {marker_a}. Do not use tools."
            ),
            resume=None,
            provider=args.provider,
            model=args.model,
            cwd=args.cwd,
            approval_policy=args.approval_policy,
            sandbox=args.sandbox,
            network_access=not args.no_network_access,
            timeout_s=args.timeout,
        )
        _assert_e2e(
            first.status == "completed",
            f"first turn status was {first.status!r}: {first.error or 'no error detail'}",
        )
        report("source turn 1", f"thread={first.thread_id} turn={first.turn_id}")

        second = await _run_probe_turn(
            ws,
            next_id=next_id,
            prompt=(
                f"Now remember marker {marker_b}. "
                f"Reply exactly: ACK {marker_b}. Do not use tools."
            ),
            resume=first.thread_id,
            provider=args.provider,
            model=None,
            cwd=args.cwd,
            approval_policy=args.approval_policy,
            sandbox=args.sandbox,
            network_access=not args.no_network_access,
            timeout_s=args.timeout,
        )
        _assert_e2e(
            second.status == "completed",
            f"second turn status was {second.status!r}: {second.error or 'no error detail'}",
        )
        report("source turn 2", f"thread={second.thread_id} turn={second.turn_id}")

        source_turns, source_text = await _fork_probe_history(
            ws, next_id=next_id, thread_id=first.thread_id, timeout_s=args.timeout,
        )
        expected_turns = [_norm_turn_id(first.turn_id), _norm_turn_id(second.turn_id)]
        _assert_e2e(source_turns == expected_turns, f"source turns were {source_turns}, expected {expected_turns}")
        _assert_e2e(marker_a in source_text, f"source history did not contain {marker_a}")
        _assert_e2e(marker_b in source_text, f"source history did not contain {marker_b}")
        report("source history", f"turns={len(source_turns)}")

        await _timed_rpc(
            ws, req_id=next_id(), method="thread/name/set",
            params={"threadId": first.thread_id, "name": source_name}, timeout_s=args.timeout,
        )

        fork_id = str((await fork(first.turn_id))["id"])
        fork_turns, fork_text = await _fork_probe_history(
            ws, next_id=next_id, thread_id=fork_id, timeout_s=args.timeout,
        )
        _assert_e2e(fork_turns == expected_turns[:1], "bounded fork must contain exactly its first canonical turn")
        _assert_e2e(marker_a in fork_text, f"bounded fork did not contain {marker_a}")
        _assert_e2e(marker_b not in fork_text, f"bounded fork still contained {marker_b}")
        report("bounded fork history", f"turns={len(fork_turns)}")

        whole_id = str((await fork(None))["id"])
        whole_turns, whole_text = await _fork_probe_history(
            ws, next_id=next_id, thread_id=whole_id, timeout_s=args.timeout,
        )
        _assert_e2e(whole_turns == expected_turns, f"whole fork turns were {whole_turns}, expected {expected_turns}")
        _assert_e2e(marker_a in whole_text and marker_b in whole_text, "whole fork lost source history")
        report("whole fork history", f"thread={whole_id} turns={len(whole_turns)}")

        if not args.skip_model_probe:
            probe = await _run_probe_turn(
                ws,
                next_id=next_id,
                prompt=(
                    "Without using tools, what exact marker from the earlier message is still "
                    f"in this conversation? It starts with RCFORK-{run_id}. "
                    "Reply exactly the full marker and nothing else."
                ),
                resume=fork_id,
                provider=args.provider,
                model=args.model,
                cwd=args.cwd,
                approval_policy=args.approval_policy,
                sandbox=args.sandbox,
                network_access=not args.no_network_access,
                timeout_s=args.timeout,
            )
            _assert_e2e(
                probe.status == "completed",
                f"probe turn status was {probe.status!r}: {probe.error or 'no error detail'}",
            )
            _assert_e2e(marker_a in probe.assistant, f"probe assistant did not see {marker_a}: {probe.assistant!r}")
            _assert_e2e(marker_b not in probe.assistant, f"probe assistant still saw {marker_b}: {probe.assistant!r}")
            report("model context", f"assistant={probe.assistant!r}")

    print(f"OK live {args.provider} fork e2e passed source={first.thread_id} fork={fork_id} whole={whole_id}")
    return 0


async def cmd_e2e_questions_live(args: argparse.Namespace) -> int:
    """Two ordinary turns, a partial reply, a durable dismissal, and a cold reader."""
    cfg = _resolve_config(args)
    request_id = 100
    receipt: dict[str, Any] = {"gateway": f"{cfg.host}:{cfg.port}", "checks": []}

    def next_id() -> int:
        nonlocal request_id
        request_id += 1
        return request_id

    async def rpc(ws, method: str, params: dict[str, Any]) -> dict[str, Any]:
        result, _, _ = await _timed_rpc(ws, req_id=next_id(), method=method, params=params, timeout_s=args.timeout)
        return result

    async def questions(ws, thread: str, item: str | None = None) -> dict[str, Any]:
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            result = await rpc(ws, "conversation/questions/read", {"queries": [{"threadId": thread, "itemIds": [item] if item else []}]})
            snapshot = result["threads"][0]
            if snapshot["coverage"] == "ready":
                return snapshot
            await asyncio.sleep(0.2)
        raise RuntimeError("Question history did not become ready")

    def passed(name: str) -> None:
        receipt["checks"].append(name)
        print(f"PASS {name}", flush=True)

    async with await _ws_connect(cfg) as ws:
        await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)
        first = await _run_probe_turn(ws, next_id=next_id,
            prompt=(f"RCQ_ASK_MULTI_{uuid.uuid4().hex}: This is a harmless integration test, not a coding task. "
                    "Call request_user_input_async once with exactly two multiple-choice questions: "
                    "Which deployment should this test use? (Internal, External), and Which note style? (Brief, Detailed). "
                    "Then finish this turn. Do not use any other tools, change files, or perform deployment. "
                    "When answered later, only acknowledge the answer."),
            resume=None, model=args.model, cwd=args.cwd, approval_policy="never", sandbox="readOnly",
            network_access=False, timeout_s=args.timeout)
        _assert_e2e(first.status == "completed", f"question turn ended as {first.status}: {first.error}")
        snapshot = await questions(ws, first.thread_id)
        _assert_e2e(len(snapshot["pendingItemIds"]) == 1, "expected one outstanding question set")
        item = snapshot["pendingItemIds"][0]
        record = next(record for record in snapshot["records"] if record["itemId"] == item)
        _assert_e2e(len(record["questions"]) == 2, "expected two original question slots")
        receipt.update(threadId=first.thread_id, itemId=item, firstTurnId=first.turn_id)
        passed("asked question survives turn completion")
        reply = [{"questionItemId": _json(["request_user_input_async", item, 0]),
                  "question": record["questions"][0]["title"], "answer": "External"}]
        envelope = "<send_user_message_question_reply>" + _json(reply) + "</send_user_message_question_reply>"
        second = await _run_probe_turn(ws, next_id=next_id, prompt=envelope,
            resume=first.thread_id, model=None, cwd=args.cwd, approval_policy="never", sandbox="readOnly",
            network_access=False, timeout_s=args.timeout)
        _assert_e2e(second.status == "completed", f"answer turn ended as {second.status}: {second.error}")
        snapshot = await questions(ws, first.thread_id, item)
        record = next(record for record in snapshot["records"] if record["itemId"] == item)
        _assert_e2e([slot["resolution"] for slot in record["questions"]] == ["answered", "pending"],
                    "a partial answer must resolve only its original slot")
        passed("canonical partial answer preserves remaining slot")
        newest = await rpc(ws, "thread/items/list", {"threadId": first.thread_id, "limit": 1, "sortDirection": "desc"})
        _assert_e2e(all(entry["item"]["type"] != "userMessage" for entry in newest["data"]),
                    "the bounded viewport must exclude the answer for this check")
        dismissal = {"threadId": first.thread_id, "itemId": item, "expectedRecordRevision": record["revision"], "expectedEpoch": snapshot["epoch"], "mutationId": str(uuid.uuid4())}
        applied = await rpc(ws, "conversation/question/dismiss", dismissal)
        replayed = await rpc(ws, "conversation/question/dismiss", dismissal)
        _assert_e2e(applied["status"] == "applied" and applied["record"] == replayed["record"], "dismissal retry was not idempotent")
        _assert_e2e([slot["resolution"] for slot in applied["record"]["questions"]] == ["answered", "dismissed"],
                    "dismissal must retain accepted answers")
        unchanged = await rpc(ws, "thread/items/list", {"threadId": first.thread_id, "limit": 1, "sortDirection": "desc"})
        _assert_e2e(newest["data"] == unchanged["data"], "dismissal unexpectedly changed model history")
        passed("dismissal is idempotent and does not send model input")
        receipt["secondTurnId"] = second.turn_id
        receipt["dismissal"] = dismissal
    async with await _ws_connect(cfg) as ws:
        await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)
        snapshot = await questions(ws, receipt["threadId"], receipt["itemId"])
        _assert_e2e(snapshot["pendingItemIds"] == [], "a cold reader resurrected attention")
        record = next(record for record in snapshot["records"] if record["itemId"] == receipt["itemId"])
        _assert_e2e([slot["resolution"] for slot in record["questions"]] == ["answered", "dismissed"], "a cold reader lost lifecycle facts")
        passed("fresh connection recovers resolved state outside the viewport")
        receipt["finalSnapshot"] = snapshot
    if args.receipt:
        await finish_thread_io(write_receipt, args.receipt, receipt)
    print(f"Question probe passed: thread={receipt['threadId']} item={receipt['itemId']}")
    return 0


async def cmd_e2e_claude_steer_live(args: argparse.Namespace) -> int:
    """Prove that steering completes one Claude turn without leaving it active."""
    cfg = _resolve_config(args)
    request_id = 0

    def next_id() -> int:
        nonlocal request_id
        request_id += 1
        return request_id

    async with await _ws_connect(cfg) as ws:
        _ = await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)

        start_id = next_id()
        await ws.send(
            _json(
                {
                    "id": start_id,
                    "method": "thread/start",
                    "params": {
                        "provider": "claude",
                        "model": args.model,
                        "cwd": args.cwd,
                    },
                }
            )
        )
        while True:
            message = await _ws_recv_json(ws, timeout_s=args.timeout)
            if message.get("id") != start_id:
                continue
            if "error" in message:
                raise RuntimeError(f"thread/start failed: {message['error']}")
            thread_id = str(message.get("result", {}).get("thread", {}).get("id") or "")
            break
        _assert_e2e(bool(thread_id), "thread/start returned no Claude thread id")
        await mark_purpose(ws, next_id=next_id, thread_id=thread_id, purpose="probe", timeout_s=args.timeout)

        completion_count = 0
        active_turns: list[dict[str, Any]] = []

        async def release() -> None:
            nonlocal completion_count
            release_id = next_id()
            await ws.send(
                _json(
                    {
                        "id": release_id,
                        "method": "claude/thread/release",
                        "params": {"threadId": thread_id},
                    }
                )
            )
            while True:
                message = await _ws_recv_json(ws, timeout_s=args.timeout)
                if (
                    message.get("method") == "turn/completed"
                    and _event_thread_id(message) == thread_id
                ):
                    completion_count += 1
                    continue
                if message.get("id") != release_id:
                    continue
                if "error" in message:
                    raise RuntimeError(f"claude/thread/release failed: {message['error']}")
                break

        async with cleanup_after("release Claude runtime", release):
            turn_start_id = next_id()
            await ws.send(
                _json(
                    {
                        "id": turn_start_id,
                        "method": "turn/start",
                        "params": {
                            "threadId": thread_id,
                            "input": [
                                {
                                    "type": "text",
                                    "text": "Run /bin/sleep 2, then reply with only ORIGINAL.",
                                }
                            ],
                            "model": args.model,
                            "effort": "medium",
                            "cwd": args.cwd,
                        },
                    }
                )
            )
            while True:
                message = await _ws_recv_json(ws, timeout_s=args.timeout)
                if message.get("id") != turn_start_id:
                    continue
                if "error" in message:
                    raise RuntimeError(f"turn/start failed: {message['error']}")
                turn_id = str(message.get("result", {}).get("turn", {}).get("id") or "")
                break
            _assert_e2e(bool(turn_id), "turn/start returned no Claude turn id")

            steer_id = next_id()
            await ws.send(
                _json(
                    {
                        "id": steer_id,
                        "method": "turn/steer",
                        "params": {
                            "threadId": thread_id,
                            "expectedTurnId": turn_id,
                            "input": [{"type": "text", "text": "Instead reply with only STEERED."}],
                        },
                    }
                )
            )

            assistant = ""
            steer_accepted = False
            while completion_count == 0 or not steer_accepted:
                message = await _ws_recv_json(ws, timeout_s=args.timeout)
                if message.get("id") == steer_id:
                    if "error" in message:
                        raise RuntimeError(f"turn/steer failed: {message['error']}")
                    steer_accepted = True
                    continue
                if _event_thread_id(message) not in (None, thread_id):
                    continue
                method = message.get("method")
                params = message.get("params") or {}
                if method == "item/completed":
                    item = params.get("item") or {}
                    if item.get("type") == "agentMessage" and isinstance(item.get("text"), str):
                        assistant = item["text"]
                elif method == "turn/completed":
                    turn = params.get("turn") or {}
                    if _norm_turn_id(turn.get("id")) == _norm_turn_id(turn_id):
                        completion_count += 1
                        _assert_e2e(
                            turn.get("status") == "completed",
                            f"steered Claude turn ended with status {turn.get('status')}",
                        )

            active_id = next_id()
            await ws.send(_json({"id": active_id, "method": "daemon/activeTurns", "params": {}}))
            while True:
                message = await _ws_recv_json(ws, timeout_s=args.timeout)
                if message.get("id") != active_id:
                    if (
                        message.get("method") == "turn/completed"
                        and _event_thread_id(message) == thread_id
                    ):
                        completion_count += 1
                    continue
                if "error" in message:
                    raise RuntimeError(f"daemon/activeTurns failed: {message['error']}")
                active_turns = message.get("result", {}).get("activeTurns") or []
                break

    active_for_thread = [turn for turn in active_turns if turn.get("threadId") == thread_id]
    _assert_e2e(completion_count == 1, f"expected one turn/completed, got {completion_count}")
    _assert_e2e(not active_for_thread, "steered Claude turn remained active after completion")
    _assert_e2e("STEERED" in assistant.upper(), f"steered response was not observed: {assistant!r}")
    print(f"OK Claude steer completed once and became idle thread={thread_id} turn={turn_id}")
    return 0


async def cmd_e2e_thread_name_live(args: argparse.Namespace) -> int:
    """Prove that thread/name/set names a live and an idle thread, announces each name and reads it back."""
    cfg = _resolve_config(args)
    claude = args.provider == "claude"
    model = args.model or ("claude-sonnet-5" if claude else DEFAULT_CODEX_PROBE_MODEL)
    run_id = uuid.uuid4().hex[:8]
    names = [f"rc-name-{run_id}-live", f"rc-name-{run_id}-idle"]
    request_id = 0
    thread_id = ""
    announced: list[str] = []
    completed_turns: set[str] = set()

    def observe(message: dict[str, Any]) -> None:
        if not thread_id or _event_thread_id(message) != thread_id:
            return
        params = message.get("params") or {}
        if message.get("method") == "thread/name/updated":
            announced.append(params.get("threadName"))
        elif message.get("method") == "turn/completed":
            completed_turns.add(_norm_turn_id((params.get("turn") or {}).get("id")))

    async def call(ws, method: str, params: dict[str, Any]) -> dict[str, Any]:
        nonlocal request_id
        request_id += 1
        sent_id = request_id
        await ws.send(_json({"id": sent_id, "method": method, "params": params}))
        while True:
            message = await _ws_recv_json(ws, timeout_s=args.timeout)
            if message.get("id") == sent_id:
                return message
            observe(message)

    async def ok(ws, method: str, params: dict[str, Any]) -> dict[str, Any]:
        message = await call(ws, method, params)
        if "error" in message:
            raise RuntimeError(f"{method} failed: {message['error']}")
        return message.get("result") or {}

    async def observe_until(ws, done) -> None:
        while not done():
            observe(await _ws_recv_json(ws, timeout_s=args.timeout))

    codex_policy = {
        "approvalPolicy": "never",
        "sandboxPolicy": _sandbox_policy(sandbox_type="readOnly", network_access=False),
    }
    async with await _ws_connect(cfg) as ws:
        _ = await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)

        started = await ok(ws, "thread/start", {
            "model": model, "cwd": args.cwd, **({"provider": "claude"} if claude else codex_policy),
        })
        thread_id = str((started.get("thread") or {}).get("id") or "")
        _assert_e2e(bool(thread_id), "thread/start returned no thread id")
        await ok(ws, "conversation/marks/update", purpose_params(thread_id, "probe"))
        released = False

        async def clean_up() -> None:
            if claude and not released:
                await ok(ws, "claude/thread/release", {"threadId": thread_id})
            elif not claude:
                await ok(ws, "thread/archive", {"threadId": thread_id})

        async with cleanup_after("release the probe thread", clean_up):
            if claude:
                early = await call(ws, "thread/name/set", {"threadId": thread_id, "name": names[0]})
                _assert_e2e((early.get("error") or {}).get("code") == -32602,
                            f"naming a Claude thread before its first turn must be rejected: {early}")
                print("PASS a Claude thread without a turn rejects a name")

            turn = await ok(ws, "turn/start", {
                "threadId": thread_id,
                "input": [{"type": "text", "text": "Reply with only READY. Do not use tools."}],
                "model": model, "effort": "low", "cwd": args.cwd, **({} if claude else codex_policy),
            })
            turn_id = _norm_turn_id((turn.get("turn") or {}).get("id"))
            _assert_e2e(bool(turn_id), "turn/start returned no turn id")

            await ok(ws, "thread/name/set", {"threadId": thread_id, "name": names[0]})
            await observe_until(ws, lambda: turn_id in completed_turns and names[0] in announced)
            print(f"PASS live thread named and announced name={names[0]}")

            if claude:
                await ok(ws, "claude/thread/release", {"threadId": thread_id})
                released = True
            await ok(ws, "thread/name/set", {"threadId": thread_id, "name": names[1]})
            await observe_until(ws, lambda: names[1] in announced)
            print(f"PASS idle thread named and announced name={names[1]}")

            read = await ok(ws, "thread/read", {"threadId": thread_id, "includeTurns": False})
            read_name = (read.get("thread") or {}).get("name")
            _assert_e2e(read_name == names[1], f"thread/read returned name {read_name!r}, expected {names[1]!r}")
            _assert_e2e(announced == names, f"expected one announcement per rename, got {announced}")

    print(f"OK {args.provider} thread names announced and read back thread={thread_id}")
    return 0


async def cmd_e2e_claude_wake_live(args: argparse.Namespace) -> int:
    """Prove that Claude output with no dispatched turn opens an agent-initiated turn.

    A background subagent outlives the turn that spawned it, so its completion
    reaches the CLI while nothing is dispatched — the same stream shape as a peer
    message or a scheduled wake, without needing a second live session.
    """
    cfg = _resolve_config(args)
    marker = f"WAKE-{uuid.uuid4().hex[:6].upper()}"
    request_id = 0

    def next_id() -> int:
        nonlocal request_id
        request_id += 1
        return request_id

    thread_id = ""
    dispatched_turn_id: str | None = None
    dispatched_status: str | None = None
    wake_turn_id: str | None = None
    wake_reason: Any = None
    wake_text = ""
    wake_status: str | None = None
    starts: list[tuple[str | None, dict[str, Any]]] = []
    responses: dict[int, dict[str, Any]] = {}

    def observe(message: dict[str, Any]) -> None:
        nonlocal dispatched_status, wake_turn_id, wake_reason, wake_text, wake_status
        if message.get("id") is not None:
            responses[message["id"]] = message
            return
        if _event_thread_id(message) not in (None, thread_id):
            return
        method = message.get("method")
        params = message.get("params") or {}
        turn = params.get("turn") or {}
        turn_id = _norm_turn_id(turn.get("id"))
        item_turn_id = _norm_turn_id(params.get("turnId"))

        if method == "turn/started":
            starts.append((turn_id, params))
            if params.get("agentInitiated") is True and turn_id != dispatched_turn_id:
                wake_turn_id = turn_id
                wake_reason = params.get("wakeReason")
        elif method == "turn/completed" and turn_id is not None:
            if turn_id == dispatched_turn_id:
                dispatched_status = str(turn.get("status"))
            elif turn_id == wake_turn_id:
                wake_status = str(turn.get("status"))
        elif method == "item/agentMessage/delta" and item_turn_id == wake_turn_id:
            delta = params.get("delta")
            if isinstance(delta, str):
                wake_text += delta
        elif method == "item/completed" and item_turn_id == wake_turn_id:
            item = params.get("item") or {}
            if item.get("type") == "agentMessage" and isinstance(item.get("text"), str):
                wake_text = item["text"]

    async with await _ws_connect(cfg) as ws:

        async def pump_until(done, *, budget_s: float, waiting_for: str) -> None:
            deadline = time.monotonic() + budget_s
            while not done():
                remaining = deadline - time.monotonic()
                _assert_e2e(
                    remaining > 0,
                    f"timed out after {budget_s:.0f}s waiting for {waiting_for}",
                )
                try:
                    observe(await _ws_recv_json(ws, timeout_s=min(remaining, 30.0)))
                except TimeoutError:
                    continue

        async def call(method: str, params: dict[str, Any], *, timeout_s: float) -> dict[str, Any]:
            req_id = next_id()
            await ws.send(_json({"id": req_id, "method": method, "params": params}))
            await pump_until(
                lambda: req_id in responses,
                budget_s=timeout_s,
                waiting_for=f"the {method} response",
            )
            message = responses.pop(req_id)
            if "error" in message:
                raise RuntimeError(f"{method} failed: {message['error']}")
            return message.get("result") or {}

        _ = await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)

        result = await call(
            "thread/start",
            {"provider": "claude", "model": args.model, "cwd": args.cwd},
            timeout_s=args.timeout,
        )
        thread_id = str((result.get("thread") or {}).get("id") or "")
        _assert_e2e(bool(thread_id), "thread/start returned no Claude thread id")
        await call("conversation/marks/update", purpose_params(thread_id, "probe"), timeout_s=args.timeout)

        async def release() -> None:
            await call("claude/thread/release", {"threadId": thread_id}, timeout_s=args.timeout)

        async with cleanup_after("release Claude runtime", release):
            result = await call(
                "turn/start",
                {
                    "threadId": thread_id,
                    "model": args.model,
                    "effort": "medium",
                    "cwd": args.cwd,
                    "input": [
                        {
                            "type": "text",
                            "text": (
                                "Use the Agent tool to spawn ONE background subagent "
                                "(subagent_type general-purpose, model sonnet, effort medium) with exactly this prompt: "
                                f"'Run the Bash command sleep {args.sleep_seconds}, then reply "
                                f"with exactly {marker}'. Do NOT wait for its result: as soon "
                                "as it is spawned, end your turn with the single word SPAWNED. "
                                "Later, when the subagent's completion arrives, reply with "
                                f"exactly {marker} and nothing else."
                            ),
                        }
                    ],
                },
                timeout_s=args.timeout,
            )
            dispatched_turn_id = _norm_turn_id((result.get("turn") or {}).get("id"))
            _assert_e2e(bool(dispatched_turn_id), "turn/start returned no Claude turn id")

            await pump_until(
                lambda: dispatched_status is not None,
                budget_s=args.dispatch_timeout,
                waiting_for="the dispatched turn to spawn the subagent and end",
            )
            _assert_e2e(
                dispatched_status == "completed",
                f"the dispatched turn ended with status {dispatched_status}",
            )

            await pump_until(
                lambda: wake_status is not None,
                budget_s=args.wake_timeout,
                waiting_for=(
                    f"an agent-initiated turn carrying {marker} "
                    f"(subagent sleeps {args.sleep_seconds}s)"
                ),
            )

    dispatched_starts = [params for turn_id, params in starts if turn_id == dispatched_turn_id]
    _assert_e2e(bool(dispatched_starts), "the dispatched turn never announced turn/started")
    _assert_e2e(
        all("agentInitiated" not in params for params in dispatched_starts),
        "the dispatched turn was announced as agent-initiated",
    )
    _assert_e2e(
        wake_status == "completed",
        f"the agent-initiated turn ended with status {wake_status}",
    )
    _assert_e2e(
        marker in wake_text,
        f"the agent-initiated turn did not carry {marker}: {wake_text.strip()[:200]!r}",
    )
    print(
        f"OK agent-initiated Claude turn delivered {marker} "
        f"thread={thread_id} turn={wake_turn_id} wakeReason={wake_reason}"
    )
    return 0


TOOL_PROBE_PROMPT = (
    "Call the end_voice_call tool exactly once, right now, without asking for "
    "confirmation. It is in the remotecoder tool set. Then reply with the tool's "
    "result text and nothing else."
)


def _tool_dispatch_records(
    args: argparse.Namespace, since_epoch: float, thread_id: str, tool: str
) -> list[dict[str, Any]]:
    return [
        record
        for _, record in _journal_read(args, since_epoch)
        if record.get("kind") == "tool"
        and record.get("event") == "dispatch"
        and record.get("tool") == tool
        and record.get("threadId") == thread_id
    ]


async def cmd_e2e_agent_tools_live(args: argparse.Namespace) -> int:
    """Prove a live agent can actually CALL a RemoteCoder tool, per provider.

    Registration alone is not evidence: a protocol-negotiation or projection
    regression would still advertise the tools and silently never deliver a call.
    So the probe asserts the gateway journalled a real dispatch, and that the turn
    then completed — an unanswered `item/tool/call` stalls a Codex turn forever.

    `end_voice_call` is the probe because it has no side effect outside a live
    call: with no call up it answers "No active voice call to end.", which is a
    successful round trip reporting nothing to do, not a failed dispatch.
    """
    cfg = _resolve_config(args)
    providers = ["claude", "codex"] if args.provider == "both" else [args.provider]
    started_at = time.time() - 60.0
    summaries: list[dict[str, Any]] = []

    for provider in providers:
        summary = await _probe_turn(args, cfg, provider, TOOL_PROBE_PROMPT)
        _assert_e2e(
            summary["status"] == "completed",
            f"the {provider} turn ended with status {summary['status']}",
        )

        # The journal writer is asynchronous by design, so give it a moment.
        deadline = time.time() + args.journal_timeout
        dispatches: list[dict[str, Any]] = []
        while time.time() < deadline:
            dispatches = _tool_dispatch_records(
                args, started_at, summary["threadId"], "end_voice_call"
            )
            if dispatches:
                break
            await asyncio.sleep(1.0)

        _assert_e2e(
            bool(dispatches),
            f"the {provider} agent never called end_voice_call "
            f"(thread {summary['threadId']}); the tools were advertised but never reached",
        )
        _assert_e2e(
            all(record.get("source") == provider for record in dispatches),
            f"a dispatch on the {provider} thread was attributed to another provider",
        )
        summary["dispatches"] = len(dispatches)
        summary["outcome"] = dispatches[0].get("outcome")
        summary["toolText"] = dispatches[0].get("text")
        summaries.append(summary)

    print(json.dumps({"ok": True, "probes": summaries}, indent=2))
    return 0


UPLOAD_SHA256_HEADER = "X-RemoteCoder-SHA256"
UPLOAD_OFFSET_HEADER = "X-RemoteCoder-Upload-Offset"
UPLOAD_LENGTH_HEADER = "X-RemoteCoder-Upload-Length"


def _sha256_of_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


async def _upload_file(cfg: GatewayConfig, path: Path, name: str, *, timeout_s: float) -> dict[str, Any]:
    """Upload one local file as a fresh `/uploads/<id>` session in a single PUT
    and return its stored identity.

    The body streams from disk; the declared length and SHA-256 are what the
    gateway verifies against, so a truncated or corrupted transfer is an error
    here rather than a silently wrong file on the host.
    """
    size = (await finish_thread_io(path.stat)).st_size
    sha256 = await finish_thread_io(_sha256_of_file, path)

    async def body():
        chunks = file_chunks(path)
        try:
            while chunk := await finish_thread_io(next, chunks, None):
                yield chunk
        finally:
            await finish_thread_io(chunks.close)

    headers = {
        "Authorization": f"Bearer {cfg.token}",
        "Content-Length": str(size),
        UPLOAD_OFFSET_HEADER: "0",
        UPLOAD_LENGTH_HEADER: str(size),
        UPLOAD_SHA256_HEADER: sha256,
    }
    content = body()
    try:
        async with cfg.http_client(timeout=timeout_s) as client:
            response = await client.put(
                f"{cfg.http_base}/uploads/{uuid.uuid4()}", params={"name": name}, headers=headers, content=content
            )
    finally:
        await content.aclose()
    if response.status_code != 201:
        try:
            detail = response.json().get("error")
        except ValueError:
            detail = response.text.strip()
        raise RuntimeError(f"upload rejected with HTTP {response.status_code}: {detail}")
    stored = response.json()
    _assert_e2e(stored.get("bytes") == size, f"gateway stored {stored.get('bytes')} bytes, sent {size}")
    _assert_e2e(stored.get("sha256") == sha256, "gateway reported a different SHA-256 than sent")
    _assert_e2e(str(stored.get("path", "")).startswith("/"), "gateway returned a relative path")
    return stored


async def cmd_upload(args: argparse.Namespace) -> int:
    """Upload one local file through the gateway and print where it landed."""
    cfg = _resolve_config(args)
    path = await finish_thread_io(Path(args.file).expanduser)
    if not await finish_thread_io(path.is_file):
        print(f"not a file: {path}", file=sys.stderr)
        return 2
    stored = await _upload_file(cfg, path, args.name or path.name, timeout_s=args.timeout)
    print(json.dumps(stored, indent=2))
    return 0


def attached_files_block(paths: list[str]) -> str:
    """The plain-text block the iOS composer appends after a message with uploads.

    This mirrors `AttachedFilesPromptBlock` in the app byte for byte: the probe
    sends exactly what the app sends, so a drift between the two shows up here.
    """
    lines = ["Attached files (uploaded to this host; use these absolute paths):"]
    lines.extend(f"- {path}" for path in paths)
    return "\n".join(lines)


def write_probe_pdf(path: Path, codeword: str) -> None:
    """One uncompressed single-page PDF whose only text names the codeword.

    Uncompressed on purpose: Claude reads PDF pages natively, while a Codex agent
    reaches for `pdftotext`, Python, or `strings`; all of them find this text.
    """
    text = f"The codeword is {codeword}."
    content = f"BT /F1 24 Tf 72 700 Td ({text}) Tj ET".encode("ascii")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length " + str(len(content)).encode("ascii") + b" >>\nstream\n" + content + b"\nendstream",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for index, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{index} 0 obj\n".encode("ascii") + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n".encode("ascii")
    out += b"0000000000 65535 f \n"
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode("ascii")
    out += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode("ascii")
    path.write_bytes(bytes(out))


UPLOAD_PROBE_PROMPT = (
    "Read the attached file and reply with only the codeword it contains, nothing else."
)


async def cmd_e2e_upload_live(args: argparse.Namespace) -> int:
    """Prove an uploaded file reaches a live agent by path, per provider.

    A stored file and a 201 are not evidence that the handoff works: the agent
    must find the absolute path the prompt names and read the file behind it.
    So the probe uploads a fresh PDF carrying a random codeword, sends each
    provider the same attached-files block the app sends, and asserts the reply
    contains that codeword. It also asserts the gateway journalled the store.
    """
    cfg = _resolve_config(args)
    providers = ["claude", "codex"] if args.provider == "both" else [args.provider]
    started_at = time.time() - 60.0
    codeword = f"{secrets.token_hex(2).upper()}-{secrets.randbelow(9000) + 1000}"

    with tempfile.TemporaryDirectory(prefix="rc-upload-probe-") as scratch:
        local = Path(scratch) / "upload probe (codeword).pdf"
        write_probe_pdf(local, codeword)
        stored = await _upload_file(cfg, local, local.name, timeout_s=args.timeout)
    remote_path = str(stored["path"])
    _assert_e2e(
        remote_path.endswith("/upload-probe-codeword.pdf"),
        f"the gateway stored the file under an unexpected name: {remote_path}",
    )
    print(f"ok  uploaded  {remote_path} ({stored['bytes']} bytes)")

    deadline = time.time() + args.journal_timeout
    stores: list[dict[str, Any]] = []
    while time.time() < deadline and not stores:
        stores = [
            record
            for _, record in _journal_read(args, started_at)
            if record.get("kind") == "upload"
            and record.get("event") == "stored"
            and record.get("path") == remote_path
        ]
        if not stores:
            await asyncio.sleep(1.0)
    _assert_e2e(bool(stores), f"the journal never recorded the stored upload {remote_path}")
    print("ok  journal   kind=upload event=stored")

    prompt = f"{UPLOAD_PROBE_PROMPT}\n\n{attached_files_block([remote_path])}"
    summaries: list[dict[str, Any]] = []
    for provider in providers:
        summary = await _probe_turn(args, cfg, provider, prompt)
        _assert_e2e(
            summary["status"] == "completed",
            f"the {provider} turn ended with status {summary['status']}",
        )
        _assert_e2e(
            codeword.lower() in summary["assistant"].lower(),
            f"the {provider} agent never read the codeword {codeword} from {remote_path}; "
            f"it replied: {summary['assistant'][:300]!r}",
        )
        print(f"ok  {provider:<6}    thread={summary['threadId']} read the codeword")
        summaries.append(summary)

    print(json.dumps({"ok": True, "path": remote_path, "codeword": codeword, "probes": summaries}, indent=2))
    return 0


FILE_PROBE_MAX_BYTES = 64 * 1024 * 1024


def _write_file_probe_binary(path: Path) -> None:
    chunk = bytes(range(256)) * 256
    with path.open("wb") as output:
        for _ in range(640):
            output.write(chunk)


async def _probe_file_response(
    cfg: GatewayConfig, path: str, known_revision: str | None, *, timeout_s: float,
) -> dict[str, Any]:
    request = {"path": path}
    if known_revision is not None:
        request["knownRevision"] = known_revision
    async with asyncio.timeout(timeout_s), cfg.http_client(timeout=timeout_s) as client:
        async with client.stream(
            "POST", f"{cfg.http_base}/files/download", json=request,
            headers={"Authorization": f"Bearer {cfg.token}", "Accept-Encoding": "identity"},
        ) as response:
            if response.status_code not in (200, 204):
                body = bytearray()
                async for chunk in response.aiter_bytes(chunk_size=8192):
                    _assert_e2e(len(body) + len(chunk) <= 8192, "file error body exceeded 8192 bytes")
                    body.extend(chunk)
                error = json.loads(body)
                _assert_e2e(isinstance(error, dict), "file error response is not an object")
                return {"status": response.status_code, "error": error}

            encoded = response.headers.get("X-RemoteCoder-File-Metadata", "")
            _assert_e2e(0 < len(encoded) <= 16384, "file metadata header is missing or oversized")
            metadata = json.loads(base64.b64decode(encoded, validate=True))
            _assert_e2e(isinstance(metadata, dict), "file metadata is not an object")
            _assert_e2e(metadata.get("path") == path, "download metadata changed the requested path")
            _assert_e2e(metadata.get("name") == Path(path).name, "download metadata changed the filename")
            size = metadata.get("bytes")
            _assert_e2e(type(size) is int and 0 <= size <= FILE_PROBE_MAX_BYTES, "invalid probe file size")
            modified = metadata.get("modifiedAt")
            _assert_e2e(type(modified) in (int, float) and math.isfinite(modified), "invalid file modifiedAt")
            revision = metadata.get("revision")
            _assert_e2e(isinstance(revision, str) and bool(revision), "file metadata omitted its revision")
            if response.status_code == 204:
                _assert_e2e(known_revision is not None and revision == known_revision, "204 changed the known revision")
            else:
                _assert_e2e(response.headers.get("Content-Type") == "application/octet-stream", "file response changed its content type")
                _assert_e2e(response.headers.get("Content-Length") == str(size), "file Content-Length disagrees with metadata")

            digest = hashlib.sha256()
            received = 0
            async for chunk in response.aiter_bytes(chunk_size=64 * 1024):
                received += len(chunk)
                _assert_e2e(received <= (size if response.status_code == 200 else 0), "file response exceeded its declared size")
                digest.update(chunk)
            _assert_e2e(received == (size if response.status_code == 200 else 0), "file response was truncated")
            return {
                "status": response.status_code, "metadata": metadata, "bytes": received,
                "sha256": digest.hexdigest() if response.status_code == 200 else None,
            }


def _file_probe_links(assistant: str, paths: dict[str, str]) -> dict[str, str]:
    links: dict[str, str] = {}
    lines = [line.strip() for line in assistant.splitlines() if line.strip()]
    _assert_e2e(len(lines) == len(paths), "provider did not return exactly one Markdown link per fixture")
    for line in lines:
        match = re.fullmatch(r"\[([^\]\r\n]+)\]\((file:///[^\s)]+)\)", line)
        _assert_e2e(match is not None, "provider returned text or code instead of a tappable Markdown file link")
        label, destination = match.groups()
        _assert_e2e(label in paths and label not in links, "provider changed or duplicated a fixture label")
        _assert_e2e(destination.isascii(), "provider did not percent-encode the Unicode file URL")
        parsed = urlsplit(destination)
        _assert_e2e(not parsed.netloc and not parsed.query and not parsed.fragment, "provider changed the file URL authority or suffix")
        _assert_e2e(unquote(parsed.path, errors="strict") == paths[label], "provider linked to a different host path")
        links[label] = destination
    return links


async def _name_file_probe_thread(cfg: GatewayConfig, thread_id: str, name: str, timeout_s: float) -> None:
    async with asyncio.timeout(timeout_s), await _ws_connect(cfg) as ws:
        await _drain_ready(ws, timeout_s=timeout_s)
        await _initialize(ws, timeout_s=timeout_s)
        await _timed_rpc(
            ws, req_id=1, method="thread/name/set",
            params={"threadId": thread_id, "name": name}, timeout_s=timeout_s,
        )


async def cmd_e2e_files_live(args: argparse.Namespace) -> int:
    cfg = _resolve_config(args)
    _assert_e2e(args.timeout > 0 and args.turn_timeout > 0, "probe timeouts must be positive")
    providers = ["codex", "claude"] if args.provider == "both" else [args.provider]
    run_id = secrets.token_hex(4)
    started = datetime.datetime.now().astimezone()
    report: dict[str, Any] = {
        "ok": False, "runId": run_id, "startedAt": started.isoformat(),
        "host": cfg.host, "fixtures": {}, "checks": {}, "probes": [],
    }
    try:
        with tempfile.TemporaryDirectory(prefix="rc-files-probe-") as scratch:
            directory = Path(scratch)
            binary = directory / "preview Å binary.rcpreview"
            pdf = directory / "preview Å document.pdf"
            markdown = directory / "preview Å reader.md"
            await asyncio.to_thread(_write_file_probe_binary, binary)
            await asyncio.to_thread(write_probe_pdf, pdf, f"FILES-{run_id.upper()}")
            for label, local in [("PDF", pdf), ("Binary", binary)]:
                async with asyncio.timeout(args.timeout):
                    report["fixtures"][label] = await _upload_file(cfg, local, local.name, timeout_s=args.timeout)
            pdf_path = Path(report["fixtures"]["PDF"]["path"])
            relative_pdf = quote(f"../{pdf_path.parent.name}/{pdf_path.name}", safe="/")
            markdown_text = (
                f"# RemoteCoder file preview\n\nAcceptance fixture `{run_id}`.\n\n"
                "This paragraph is deliberately wrapped\nacross two source lines.\n\n"
                "## Native reading and export\n\n- Select text\n- Share the original\n- Save to Files\n\n"
                "An intentional hard break follows.  \nThis is its next line.\n\n"
                "| File | Purpose |\n| --- | --- |\n| PDF | Native preview |\n| Binary | Original export |\n\n"
                f"[Relative PDF]({relative_pdf})\n\n"
                "```text\nThe exported bytes should match the downloaded original.\n```\n"
            )
            await asyncio.to_thread(markdown.write_text, markdown_text, encoding="utf-8")
            async with asyncio.timeout(args.timeout):
                report["fixtures"]["Markdown"] = await _upload_file(cfg, markdown, markdown.name, timeout_s=args.timeout)

        for fixture in report["fixtures"].values():
            downloaded = await _probe_file_response(cfg, fixture["path"], None, timeout_s=args.timeout)
            _assert_e2e(downloaded["status"] == 200, "fixture download was rejected")
            _assert_e2e(downloaded["sha256"] == fixture["sha256"], "download changed the original SHA-256")
            _assert_e2e(downloaded["bytes"] == fixture["bytes"], "download changed the original length")
            cached = await _probe_file_response(
                cfg, fixture["path"], downloaded["metadata"]["revision"], timeout_s=args.timeout,
            )
            _assert_e2e(cached["status"] == 204, "unchanged file did not return 204")
            _assert_e2e(cached["metadata"] == downloaded["metadata"], "204 changed the file metadata")
            fixture["download"] = downloaded
            fixture["revalidated"] = True

        binary_path = report["fixtures"]["Binary"]["path"]
        for label, path, expected_status, kind in [
            ("missing", f"{binary_path}-missing-{run_id}", 404, "missing"),
            ("directory", str(Path(binary_path).parent), 400, "notFile"),
        ]:
            result = await _probe_file_response(cfg, path, None, timeout_s=args.timeout)
            _assert_e2e(result["status"] == expected_status, f"{label} returned the wrong HTTP status")
            _assert_e2e(result["error"].get("kind") == kind, f"{label} returned the wrong error kind")
            report["checks"][label] = result

        paths = {label: report["fixtures"][label]["path"] for label in ("PDF", "Markdown", "Binary")}
        prompt = (
            "This is a RemoteCoder file-link acceptance check. Do not read, modify, or execute files, "
            "call tools, or ask questions. Return exactly three ordinary Markdown links, one per line, "
            "with the labels below and file:/// URLs for their absolute host paths. Encode spaces and "
            "non-ASCII characters in each URL. Do not use code fences, bullets, or additional text.\n\n"
            + "\n".join(f"{label}: {path}" for label, path in paths.items())
        )
        for provider in providers:
            name = f"File previews · {provider} · {started:%Y-%m-%d %H:%M} · {run_id}"
            async with asyncio.timeout(args.turn_timeout):
                fresh = await _probe_turn(args, cfg, provider, f"Acceptance conversation: {name}\n\n{prompt}",
                                          purpose=None)
            candidate = {"provider": provider, "label": name, "threadNameSet": False, "fresh": fresh}
            report["probes"].append(candidate)
            if provider == "codex":
                await _name_file_probe_thread(cfg, fresh["threadId"], name, args.timeout)
                candidate["threadNameSet"] = True
            _assert_e2e(fresh["status"] == "completed", f"fresh {provider} turn did not complete")
            fresh["links"] = _file_probe_links(fresh["assistant"], paths)
            async with asyncio.timeout(args.turn_timeout):
                resumed = await _probe_turn(
                    args, cfg, provider,
                    "Return the same three file Markdown links from the preceding turn again, "
                    "with their exact labels and destinations. No tools, code fences, or additional text.",
                    resume=fresh["threadId"],
                )
            candidate["resumed"] = resumed
            _assert_e2e(resumed["threadId"] == fresh["threadId"], f"{provider} resumed a different conversation")
            _assert_e2e(resumed["turnId"] != fresh["turnId"], f"{provider} did not produce a new resumed turn")
            _assert_e2e(resumed["status"] == "completed", f"resumed {provider} turn did not complete")
            resumed["links"] = _file_probe_links(resumed["assistant"], paths)
            if provider == "codex":
                await _name_file_probe_thread(cfg, fresh["threadId"], name, args.timeout)
        report["ok"] = True
    finally:
        report["finishedAt"] = datetime.datetime.now().astimezone().isoformat()
        if args.receipt:
            await finish_thread_io(write_receipt, args.receipt, report)
    print(json.dumps(report, indent=2))
    return 0
