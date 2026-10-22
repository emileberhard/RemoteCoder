"""Opt-in native compaction acceptance; receipts contain identities, never content."""

import argparse
import asyncio
import json
import uuid
from dataclasses import dataclass
from pathlib import Path

from .config import _resolve_config
from .rpc import (
    _drain_ready,
    _event_thread_id,
    _initialize,
    _json,
    _timed_rpc,
    _ws_connect,
    _ws_recv_json,
    request_response,
)
from .turns import _assert_e2e, _run_probe_turn, _sandbox_policy


@dataclass
class CompactionEvidence:
    thread_id: str
    turn_id: str | None = None
    item_id: str | None = None
    started: bool = False
    completed: bool = False
    terminal: str | None = None

    def accept(self, message: dict) -> None:
        if _event_thread_id(message) != self.thread_id:
            return
        method = message.get("method")
        params = message.get("params", {})
        turn = params.get("turn", {})
        event_turn = params.get("turnId") or turn.get("id")
        if method == "turn/started" and self.turn_id is None:
            self.turn_id = event_turn
        if not event_turn or event_turn != self.turn_id:
            return
        item = params.get("item", {})
        if method == "item/started" and item.get("type") == "contextCompaction":
            self.item_id = item.get("id")
            self.started = bool(self.item_id)
        if method == "item/completed" and item.get("type") == "contextCompaction":
            if self.started and item.get("id") == self.item_id:
                self.completed = True
        if method == "turn/completed":
            self.terminal = turn.get("status")

    def verify(self) -> None:
        _assert_e2e(self.started and self.completed, "matching native compaction start/completion absent")
        _assert_e2e(self.terminal == "completed", f"compaction turn ended {self.terminal!r}")


async def _until(ws, predicate, deadline_seconds: float) -> None:
    async with asyncio.timeout(deadline_seconds):
        while True:
            message = await _ws_recv_json(ws, timeout_s=deadline_seconds)
            if predicate(message):
                return


async def _provider_probe(args, cfg, provider: str) -> dict:
    sequence = 0

    def next_id():
        nonlocal sequence
        sequence += 1
        return sequence

    model = args.claude_model if provider == "claude" else args.codex_model
    async with await _ws_connect(cfg) as ws:
        await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)
        marker = uuid.uuid4().hex[:12]
        context = "\n".join(f"Fixture fact {i}: blue square {marker}, safe local context." for i in range(120))
        async with asyncio.timeout(args.timeout):
            seed = await _run_probe_turn(
                ws, next_id=next_id, provider=provider, model=model, cwd=args.cwd,
                approval_policy="never", sandbox="readOnly", network_access=False,
                prompt=f"RemoteCoder compaction probe. Remember these harmless fixture facts; reply ACK only. Do not use tools.\n{context}",
                resume=None, timeout_s=args.timeout,
            )
        _assert_e2e(seed.status == "completed",
                    f"seed turn {seed.turn_id} in {seed.thread_id} ended {seed.status}: {seed.error or seed.assistant[:300] or 'no provider detail'}")
        thread_id = seed.thread_id
        evidence = CompactionEvidence(thread_id)
        compact_accepted = False
        busy_turn_id = None
        interrupted_by_probe = False
        try:
            await _timed_rpc(ws, req_id=next_id(), method="thread/compact/start",
                             params={"threadId": thread_id}, timeout_s=args.timeout)
            compact_accepted = True

            def compact_finished(message):
                evidence.accept(message)
                return evidence.terminal is not None

            await _until(ws, compact_finished, args.timeout)
            evidence.verify()
            compact_accepted = False

            policy = {} if provider == "claude" else {
                "approvalPolicy": "never", "sandboxPolicy": _sandbox_policy(sandbox_type="readOnly", network_access=False),
            }
            busy, _, _ = await _timed_rpc(
                ws, req_id=next_id(), method="turn/start", timeout_s=args.timeout,
                params={"threadId": thread_id, "model": model, "cwd": args.cwd, **policy,
                        "input": [{"type": "text", "text": "RemoteCoder active-turn compaction safety probe. Run exactly sleep 30 using your shell tool, then reply ACK. Do not read or write files and do not run any other command."}]},
            )
            busy_turn_id = busy.get("turn", {}).get("id")
            _assert_e2e(bool(busy_turn_id), "busy probe returned no exact turn id")

            def shell_started(message):
                if _event_thread_id(message) != thread_id:
                    return False
                params = message.get("params", {})
                if message.get("method") == "turn/completed" and params.get("turn", {}).get("id") == busy_turn_id:
                    raise RuntimeError("busy fixture ended before the shell command; rejection was not exercised")
                return (message.get("method") == "item/started" and params.get("turnId") == busy_turn_id
                        and params.get("item", {}).get("type") == "commandExecution")

            await _until(ws, shell_started, args.timeout)
            compact_request_id = next_id()
            rejection, _, _ = await request_response(
                ws, req_id=compact_request_id, payload=_json({"id": compact_request_id, "method": "thread/compact/start", "params": {"threadId": thread_id}}),
                timeout_s=args.timeout, send_timeout_s=args.timeout,
            )
            _assert_e2e(rejection.get("error", {}).get("code") in (-32009, -32002), "running compaction was not rejected as busy")
            active, _, _ = await _timed_rpc(ws, req_id=next_id(), method="daemon/activeTurns", params={}, timeout_s=args.timeout)
            _assert_e2e(any(turn.get("threadId") == thread_id and turn.get("turnId") == busy_turn_id
                            for turn in active.get("activeTurns", [])), "rejection did not preserve the exact original active turn")
            await _timed_rpc(ws, req_id=next_id(), method="turn/interrupt",
                             params={"threadId": thread_id, "turnId": busy_turn_id}, timeout_s=args.timeout)
            interrupted_by_probe = True

            def intentionally_stopped(message):
                if _event_thread_id(message) != thread_id or message.get("method") != "turn/completed":
                    return False
                turn = message.get("params", {}).get("turn", {})
                if turn.get("id") != busy_turn_id:
                    return False
                _assert_e2e(turn.get("status") == "interrupted", "probe Stop did not interrupt its exact busy turn")
                return True

            await _until(ws, intentionally_stopped, args.timeout)
            stopped_turn_id = busy_turn_id
            busy_turn_id = None
            return {"provider": provider, "threadId": thread_id, "seedTurnId": seed.turn_id,
                    "compactionTurnId": evidence.turn_id, "compactionItemId": evidence.item_id,
                    "compactionStatus": evidence.terminal, "busyRejectionCode": rejection["error"]["code"],
                    "busyTurnId": stopped_turn_id, "originalTurnPreserved": True, "cleanupStatus": "interrupted"}
        finally:
            # Never stop guessed work: only the probe's captured native identities.
            cleanup_id = busy_turn_id or (evidence.turn_id if compact_accepted else None)
            if cleanup_id and not interrupted_by_probe:
                await _timed_rpc(ws, req_id=next_id(), method="turn/interrupt",
                                 params={"threadId": thread_id, "turnId": cleanup_id}, timeout_s=10)


def _write_receipt(path: str, rendered: str) -> None:
    Path(path).expanduser().write_text(rendered + "\n", encoding="utf-8")


async def cmd_e2e_compact_live(args: argparse.Namespace) -> int:
    cfg = _resolve_config(args)
    providers = ["codex", "claude"] if args.provider == "both" else [args.provider]
    results = []
    for provider in providers:
        results.append(await _provider_probe(args, cfg, provider))
    receipt = {"ok": True, "probes": results}
    rendered = json.dumps(receipt, indent=2)
    if args.receipt:
        await asyncio.to_thread(_write_receipt, args.receipt, rendered)
    print(rendered)
    return 0
