"""Opt-in native queued-message acceptance; receipts contain identities, never content."""

import argparse
import asyncio
import json
import sys
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from .config import _resolve_config
from .rpc import _drain_ready, _event_thread_id, _initialize, _timed_rpc, _ws_connect, _ws_recv_json
from .turns import _assert_e2e, _sandbox_policy, mark_purpose

HELD_OBSERVATION_SECONDS = 25.0
IDLE_DEADLINE_SECONDS = 15.0


@dataclass
class ObservedTurn:
    turn_id: str
    client_ids: list[str] = field(default_factory=list)
    status: str | None = None


@dataclass
class QueueEvidence:
    thread_id: str
    turns: list[ObservedTurn] = field(default_factory=list)

    def turn(self, turn_id: str | None) -> ObservedTurn | None:
        return next((turn for turn in self.turns if turn.turn_id == turn_id), None)

    def begin(self, turn_id: str) -> ObservedTurn:
        observed = self.turn(turn_id)
        if observed is None:
            observed = ObservedTurn(turn_id)
            self.turns.append(observed)
        return observed

    def accept(self, message: dict) -> None:
        if _event_thread_id(message) != self.thread_id:
            return
        method = message.get("method")
        params = message.get("params", {})
        if method == "turn/started" and params.get("turn", {}).get("id"):
            self.begin(params["turn"]["id"])
        elif method in ("item/started", "item/completed"):
            item = params.get("item", {})
            observed = self.turn(params.get("turnId"))
            client_id = item.get("clientId")
            if item.get("type") == "userMessage" and observed and client_id and client_id not in observed.client_ids:
                observed.client_ids.append(client_id)
        elif method == "turn/completed":
            turn = params.get("turn", {})
            observed = self.turn(turn.get("id"))
            if observed is not None:
                observed.status = turn.get("status")

    def successors(self, turn_id: str) -> list[ObservedTurn]:
        index = next(i for i, turn in enumerate(self.turns) if turn.turn_id == turn_id)
        return self.turns[index + 1:]

    def verify_fifo(self, running_turn_id: str, client_ids: list[str]) -> list[str]:
        running = self.turn(running_turn_id)
        _assert_e2e(running is not None and running.status == "completed",
                    f"running turn {running_turn_id} ended {running.status if running else None!r}")
        _assert_e2e(not set(running.client_ids) & set(client_ids), "a queued message joined the running turn")
        successors = self.successors(running_turn_id)
        _assert_e2e(len(successors) == len(client_ids),
                    f"expected {len(client_ids)} queued turns after {running_turn_id}, saw {len(successors)}")
        for successor, client_id in zip(successors, client_ids):
            _assert_e2e(successor.client_ids == [client_id],
                        f"turn {successor.turn_id} carried {successor.client_ids}, expected [{client_id!r}]")
            _assert_e2e(successor.status == "completed", f"queued turn {successor.turn_id} ended {successor.status!r}")
        return [successor.turn_id for successor in successors]


class QueueProbe:
    def __init__(self, ws, args) -> None:
        self.ws = ws
        self.args = args
        self.sequence = 0
        self.marker = uuid.uuid4().hex[:12]
        self.evidence: QueueEvidence | None = None
        self.queued_ids: dict[str, str] = {}

    def next_id(self) -> int:
        self.sequence += 1
        return self.sequence

    async def call(self, method: str, params: dict) -> dict:
        result, _, _ = await _timed_rpc(self.ws, req_id=self.next_id(), method=method, params=params,
                                        timeout_s=self.args.timeout)
        return result

    async def follow(self, condition, seconds: float) -> None:
        async with asyncio.timeout(seconds):
            while not condition():
                self.evidence.accept(await _ws_recv_json(self.ws, timeout_s=seconds))

    def client_id(self, label: str) -> str:
        return f"rc-queue-probe-{self.marker}-{label}"

    async def start_thread(self) -> str:
        result = await self.call("thread/start", self.thread_params())
        thread_id = str((result.get("thread") or {}).get("id") or "")
        _assert_e2e(bool(thread_id), "thread/start returned no thread id")
        await mark_purpose(self.ws, next_id=self.next_id, thread_id=thread_id, purpose="probe",
                           timeout_s=self.args.timeout)
        self.evidence = QueueEvidence(thread_id)
        return thread_id

    def thread_params(self) -> dict:
        return {"model": self.args.codex_model, "cwd": self.args.cwd, "approvalPolicy": "never",
                "sandboxPolicy": _sandbox_policy(sandbox_type="readOnly", network_access=False)}

    async def start_busy_turn(self, label: str, seconds: int) -> str:
        thread_id = self.evidence.thread_id
        result = await self.call("turn/start", {
            "threadId": thread_id, **self.thread_params(), "clientUserMessageId": self.client_id(label),
            "input": [{"type": "text", "text": f"RemoteCoder queued-message probe. Run exactly sleep {seconds} using your shell tool, then reply ACK. Do not read or write files and do not run any other command."}],
        })
        turn_id = str((result.get("turn") or {}).get("id") or "")
        _assert_e2e(bool(turn_id), "turn/start returned no exact turn id")
        self.evidence.begin(turn_id)
        shell_started = False

        def running_shell(message: dict) -> None:
            nonlocal shell_started
            params = message.get("params", {})
            if (_event_thread_id(message) == thread_id and message.get("method") == "item/started"
                    and params.get("turnId") == turn_id and params.get("item", {}).get("type") == "commandExecution"):
                shell_started = True

        def shell_or_end() -> bool:
            return shell_started or self.evidence.turn(turn_id).status is not None

        async with asyncio.timeout(self.args.timeout):
            while not shell_or_end():
                message = await _ws_recv_json(self.ws, timeout_s=self.args.timeout)
                self.evidence.accept(message)
                running_shell(message)
        _assert_e2e(shell_started, f"busy turn {turn_id} ended before its shell command; queueing was not exercised")
        return turn_id

    async def enqueue(self, label: str) -> str:
        client_id = self.client_id(label)
        result = await self.call("thread/queue/add", {
            "threadId": self.evidence.thread_id, "clientUserMessageId": client_id,
            "input": [{"type": "text", "text": f"RemoteCoder queued-message probe {label}. Reply QUEUED only. Do not use tools."}],
        })
        submission = result.get("queuedSubmission") or {}
        _assert_e2e(submission.get("clientUserMessageId") == client_id, "thread/queue/add did not echo the canonical clientUserMessageId")
        _assert_e2e(bool(submission.get("id")), "thread/queue/add returned no queued submission id")
        self.queued_ids[client_id] = submission["id"]
        return client_id

    async def listed_client_ids(self) -> list[str]:
        result = await self.call("thread/queue/list", {"threadId": self.evidence.thread_id, "limit": 100})
        _assert_e2e(result.get("nextCursor") is None, "the probe thread has more queued messages than one page")
        return [entry.get("clientUserMessageId") for entry in result.get("data", [])]

    async def interrupt(self, turn_id: str) -> None:
        await self.call("turn/interrupt", {"threadId": self.evidence.thread_id, "turnId": turn_id})

    async def ends_idle(self) -> None:
        thread_id = self.evidence.thread_id
        async with asyncio.timeout(IDLE_DEADLINE_SECONDS):
            while True:
                active = await self.call("daemon/activeTurns", {})
                _assert_e2e((active.get("coverage") or {}).get("codex") is True, "Codex activity coverage is unavailable")
                if not any(turn.get("threadId") == thread_id for turn in active.get("activeTurns", [])):
                    return
                await asyncio.sleep(1)

    async def fifo_phase(self) -> dict:
        running_turn_id = await self.start_busy_turn("running", 20)
        queued = [await self.enqueue("first"), await self.enqueue("second")]
        _assert_e2e(await self.listed_client_ids() == queued, "the native queue does not list both messages in FIFO order")
        evidence = self.evidence

        def both_finished() -> bool:
            successors = evidence.successors(running_turn_id)
            return len(successors) >= len(queued) and all(turn.status for turn in successors[:len(queued)])

        await self.follow(both_finished, self.args.timeout)
        queued_turn_ids = evidence.verify_fifo(running_turn_id, queued)
        for client_id in queued:
            self.queued_ids.pop(client_id)
        _assert_e2e(await self.listed_client_ids() == [], "the native queue still lists messages after both ran")
        await self.ends_idle()
        return {"runningTurnId": running_turn_id, "queuedClientIds": queued, "queuedTurnIds": queued_turn_ids}

    async def held_phase(self) -> dict:
        stopped_turn_id = await self.start_busy_turn("stopped", 30)
        held = await self.enqueue("held")
        await self.interrupt(stopped_turn_id)
        stopped = self.evidence.turn(stopped_turn_id)
        await self.follow(lambda: stopped.status is not None, self.args.timeout)
        _assert_e2e(stopped.status == "interrupted", f"Stop ended turn {stopped_turn_id} as {stopped.status!r}")
        turns_at_stop = len(self.evidence.turns)
        try:
            await self.follow(lambda: len(self.evidence.turns) > turns_at_stop, HELD_OBSERVATION_SECONDS)
        except TimeoutError:
            pass
        _assert_e2e(len(self.evidence.turns) == turns_at_stop, "a queued message started after Stop instead of being held")
        _assert_e2e(await self.listed_client_ids() == [held], "the held message is no longer queued")
        result = await self.call("thread/queue/start", {"threadId": self.evidence.thread_id,
                                                        "queuedSubmissionId": self.queued_ids[held]})
        started_turn_id = str((result.get("turn") or {}).get("id") or "")
        _assert_e2e(bool(started_turn_id), "thread/queue/start returned no exact turn id")
        started = self.evidence.begin(started_turn_id)
        await self.follow(lambda: started.status is not None, self.args.timeout)
        _assert_e2e(started.client_ids == [held], f"Send Now turn carried {started.client_ids}, expected [{held!r}]")
        _assert_e2e(started.status == "completed", f"Send Now turn ended {started.status!r}")
        _assert_e2e(held not in stopped.client_ids, "the held message joined the stopped turn")
        self.queued_ids.pop(held)
        _assert_e2e(await self.listed_client_ids() == [], "the native queue still lists the held message after Send Now")
        await self.ends_idle()
        return {"stoppedTurnId": stopped_turn_id, "heldClientId": held,
                "heldSeconds": HELD_OBSERVATION_SECONDS, "sendNowTurnId": started_turn_id}

    async def clean_up(self) -> None:
        if self.evidence is None:
            return
        thread_id = self.evidence.thread_id
        cleanup = [("thread/queue/delete", {"threadId": thread_id, "queuedSubmissionId": queued_submission_id})
                   for queued_submission_id in self.queued_ids.values()]
        cleanup += [("turn/interrupt", {"threadId": thread_id, "turnId": turn.turn_id})
                    for turn in self.evidence.turns if turn.status is None]
        for method, params in cleanup:
            try:
                await _timed_rpc(self.ws, req_id=self.next_id(), method=method, params=params, timeout_s=10)
            except Exception as error:
                print(f"warning: probe cleanup {method} {params} failed: {error}", file=sys.stderr)


async def _queue_probe(args, cfg) -> dict:
    async with await _ws_connect(cfg) as ws:
        await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)
        probe = QueueProbe(ws, args)
        completed = False
        try:
            thread_id = await probe.start_thread()
            fifo = await probe.fifo_phase()
            held = await probe.held_phase()
            completed = True
            return {"threadId": thread_id, **fifo, **held, "finalActivity": "idle"}
        finally:
            if not completed:
                await probe.clean_up()


def _write_receipt(path: str, rendered: str) -> None:
    Path(path).expanduser().write_text(rendered + "\n", encoding="utf-8")


async def cmd_e2e_queue_live(args: argparse.Namespace) -> int:
    cfg = _resolve_config(args)
    receipt = {"ok": True, "probe": await _queue_probe(args, cfg)}
    rendered = json.dumps(receipt, indent=2)
    if args.receipt:
        await asyncio.to_thread(_write_receipt, args.receipt, rendered)
    print(rendered)
    return 0
