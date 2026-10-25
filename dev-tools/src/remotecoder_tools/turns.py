import argparse
import asyncio
import sys
from dataclasses import dataclass
from typing import Any

from .config import GatewayConfig
from .rpc import (
    _drain_ready,
    _event_thread_id,
    _initialize,
    _timed_rpc,
    _ws_connect,
    _ws_recv_json,
)
from .verdict import cleanup_after


def _assert_e2e(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


@dataclass(frozen=True)
class TurnRunResult:
    thread_id: str
    turn_id: str
    assistant: str
    status: str | None
    error: str | None


def _sandbox_policy(*, sandbox_type: str, network_access: bool) -> dict[str, Any]:
    return {"type": sandbox_type, "networkAccess": bool(network_access)}


PURPOSES = ("probe", "automation")


def purpose_params(thread_id: str, purpose: str) -> dict[str, Any]:
    return {"changes": [{"op": "setPurpose", "threadId": thread_id, "purpose": purpose}]}


async def mark_purpose(ws, *, next_id, thread_id: str, purpose: str, timeout_s: float) -> None:
    try:
        await _timed_rpc(
            ws,
            req_id=next_id(),
            method="conversation/marks/update",
            params=purpose_params(thread_id, purpose),
            timeout_s=timeout_s,
        )
    except (RuntimeError, TimeoutError) as error:
        print(f"warning: {thread_id} was not marked as {purpose}: {error}", file=sys.stderr)


def _norm_turn_id(value: Any) -> str | None:
    return value if isinstance(value, str) else None


def _completed_turn_exit_code(status: Any) -> int:
    return 0 if status == "completed" else 1


def _thread_text(thread: dict[str, Any]) -> str:
    chunks: list[str] = []
    turns = thread.get("turns")
    if not isinstance(turns, list):
        return ""

    for turn in turns:
        if not isinstance(turn, dict):
            continue
        items = turn.get("items")
        if not isinstance(items, list):
            continue
        for item in items:
            if not isinstance(item, dict):
                continue
            item_type = item.get("type")
            if item_type == "agentMessage":
                text = item.get("text")
                if isinstance(text, str):
                    chunks.append(text)
            elif item_type == "userMessage":
                content = item.get("content")
                if not isinstance(content, list):
                    continue
                for entry in content:
                    if not isinstance(entry, dict):
                        continue
                    text = entry.get("text")
                    if isinstance(text, str):
                        chunks.append(text)

    return "\n".join(chunks)


async def _interrupt_probe_turn(ws, *, next_id, thread_id: str, turn_id: str, timeout_s: float) -> None:
    try:
        async with asyncio.timeout(min(timeout_s, 10.0)):
            await _timed_rpc(
                ws, req_id=next_id(), method="turn/interrupt",
                params={"threadId": thread_id, "turnId": turn_id}, timeout_s=timeout_s,
            )
    except Exception as exc:
        print(f"warning: interrupting probe turn {thread_id}/{turn_id} failed: {exc}", file=sys.stderr)


async def release_claude_runtime(ws, *, next_id, thread_id: str, timeout_s: float) -> None:
    async with asyncio.timeout(min(timeout_s, 10.0)):
        await _timed_rpc(
            ws, req_id=next_id(), method="claude/thread/release",
            params={"threadId": thread_id}, timeout_s=timeout_s,
        )


async def _run_probe_turn(
    ws, *, next_id, timeout_s: float, on_thread=None, purpose: str | None = "probe", **turn: Any,
) -> TurnRunResult:
    started: dict[str, str] = {}

    def record_thread(thread_id: str) -> None:
        started["thread"] = thread_id
        if on_thread is not None:
            on_thread(thread_id)
        actual_provider = "claude" if thread_id.startswith("claude_") else "codex"
        if actual_provider != turn.get("provider", "codex"):
            raise RuntimeError(f"Probe requested {turn.get('provider', 'codex')} but gateway admitted {actual_provider}")

    def record_turn(turn_id: str) -> None:
        started["turn"] = turn_id

    try:
        return await _run_gateway_turn(
            ws, next_id=next_id, timeout_s=timeout_s, on_thread=record_thread, on_turn=record_turn,
            purpose=purpose, **turn,
        )
    except BaseException:
        if "turn" in started:
            await _interrupt_probe_turn(
                ws, next_id=next_id, thread_id=started["thread"], turn_id=started["turn"], timeout_s=timeout_s,
            )
        raise


async def _run_gateway_turn(
    ws,
    *,
    next_id,
    prompt: str,
    resume: str | None,
    model: str | None,
    cwd: str,
    approval_policy: str,
    sandbox: str,
    network_access: bool,
    timeout_s: float,
    provider: str = "codex",
    input_items: list[dict[str, Any]] | None = None,
    effort: str | None = None,
    service_tier: str | None = None,
    exclude_turns: bool = True,
    resume_rpc: bool = True,
    purpose: str | None = None,
    on_event=None,
    on_thread=None,
    on_turn=None,
) -> TurnRunResult:
    policy = (
        {
            "approvalPolicy": approval_policy,
            "sandboxPolicy": _sandbox_policy(
                sandbox_type=sandbox, network_access=network_access,
            ),
        }
        if provider == "codex" else {}
    )
    thread_params = {"cwd": cwd, **policy}
    if model is not None:
        thread_params["model"] = model
    if provider == "codex":
        # Explicit null clears a saved/configured Fast tier for this dispatch.
        thread_params["serviceTier"] = service_tier
    if resume and resume_rpc:
        resume_params = {"threadId": resume, **thread_params}
        if provider == "codex" and exclude_turns:
            resume_params["excludeTurns"] = True
        if provider != "codex":
            resume_params["provider"] = provider
        result, _elapsed, _byte_count = await _timed_rpc(
            ws,
            req_id=next_id(),
            method="thread/resume",
            params=resume_params,
            timeout_s=timeout_s,
        )
        _assert_e2e(
            (result.get("thread") or {}).get("id") == resume,
            "thread/resume returned a different thread identity",
        )
        thread_id = resume
    elif resume:
        thread_id = resume
    else:
        start_params = {**thread_params, "acceptProviderFallback": True}
        if effort:
            start_params["config"] = {"model_reasoning_effort": effort}
        if provider != "codex":
            start_params["provider"] = provider
        result, _elapsed, _byte_count = await _timed_rpc(
            ws,
            req_id=next_id(),
            method="thread/start",
            params=start_params,
            timeout_s=timeout_s,
        )
        thread = result.get("thread")
        if not isinstance(thread, dict):
            raise RuntimeError("thread/start returned no thread")
        thread_id = str(thread.get("id") or "")
        actual_provider = "claude" if thread_id.startswith("claude_") else "codex"
        if actual_provider == "claude" and provider == "codex" and (
            sandbox != "dangerFullAccess" or not network_access or approval_policy != "never"
        ):
            raise RuntimeError("Admitted Claude thread cannot preserve the requested execution restrictions; no turn was submitted")
        thread_params = {"cwd": cwd}
        actual_model = result.get("model", thread.get("model"))
        if isinstance(actual_model, str):
            thread_params["model"] = actual_model
        if actual_provider == "codex":
            thread_params.update(
                approvalPolicy=approval_policy,
                sandboxPolicy=_sandbox_policy(sandbox_type=sandbox, network_access=network_access),
                serviceTier=service_tier,
            )
            actual_model_provider = result.get("modelProvider", thread.get("modelProvider"))
            if isinstance(actual_model_provider, str):
                thread_params["modelProvider"] = actual_model_provider
                if actual_model_provider != "openai":
                    thread_params["serviceTier"] = None
        changed_route = actual_provider != provider or (isinstance(actual_model, str) and model is not None and actual_model != model)
        actual_effort = result.get("reasoningEffort")
        if isinstance(actual_effort, str) and (effort is not None or changed_route):
            effort = actual_effort
        elif actual_provider != provider:
            effort = None
        if thread_id and purpose:
            await mark_purpose(ws, next_id=next_id, thread_id=thread_id, purpose=purpose, timeout_s=timeout_s)

    if not thread_id:
        raise RuntimeError("missing thread id")
    if on_thread is not None:
        on_thread(thread_id)
    if input_items is not None and not input_items:
        raise RuntimeError("give a prompt, an --image-path, or both")

    turn_params: dict[str, Any] = {
        "threadId": thread_id,
        "input": input_items if input_items is not None else [{"type": "text", "text": prompt}],
        **thread_params,
    }
    if effort:
        turn_params["effort"] = effort
    result, _elapsed, _byte_count = await _timed_rpc(
        ws,
        req_id=next_id(),
        method="turn/start",
        params=turn_params,
        timeout_s=timeout_s,
    )
    turn = result.get("turn")
    if not isinstance(turn, dict):
        raise RuntimeError("turn/start returned no turn")
    turn_id = str(turn.get("id") or "")
    if not turn_id:
        raise RuntimeError("missing turn id")
    if on_turn is not None:
        on_turn(turn_id)

    assistant = ""
    status: str | None = None
    error: str | None = None
    while True:
        msg = await _ws_recv_json(ws, timeout_s=timeout_s)
        evt_tid = _event_thread_id(msg)
        if evt_tid is not None and evt_tid != thread_id:
            continue
        if on_event is not None:
            on_event(msg)

        method = msg.get("method")
        if method == "item/agentMessage/delta":
            delta = msg.get("params", {}).get("delta")
            if isinstance(delta, str):
                assistant += delta

        if method == "item/completed":
            item = msg.get("params", {}).get("item", {})
            if isinstance(item, dict) and item.get("type") == "agentMessage":
                text = item.get("text")
                if isinstance(text, str) and text.strip():
                    assistant = text

        if method == "turn/completed":
            completed_turn = msg.get("params", {}).get("turn", {})
            if _norm_turn_id(completed_turn.get("id")) == _norm_turn_id(turn_id):
                candidate_status = completed_turn.get("status")
                if isinstance(candidate_status, str):
                    status = candidate_status
                candidate_error = completed_turn.get("error")
                if isinstance(candidate_error, dict):
                    message = candidate_error.get("message")
                    if isinstance(message, str):
                        error = message
                break

    return TurnRunResult(
        thread_id=thread_id,
        turn_id=turn_id,
        assistant=assistant.strip(),
        status=status,
        error=error,
    )


async def _probe_turn(
    args: argparse.Namespace, cfg: GatewayConfig, provider: str, prompt: str,
    *, resume: str | None = None, purpose: str | None = "probe",
) -> dict[str, Any]:
    request_id = 0

    def next_id() -> int:
        nonlocal request_id
        request_id += 1
        return request_id

    thread_id: str | None = None

    def set_thread(value: str) -> None:
        nonlocal thread_id
        thread_id = value

    async with await _ws_connect(cfg) as ws:
        _ = await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)

        async def release() -> None:
            if thread_id is not None and thread_id.startswith("claude_"):
                await release_claude_runtime(ws, next_id=next_id, thread_id=thread_id, timeout_s=args.timeout)

        async with cleanup_after("release Claude runtime", release):
            run = await _run_probe_turn(
                ws, next_id=next_id, prompt=prompt, resume=resume,
                model=None if resume else (args.codex_model if provider == "codex" else args.claude_model),
                cwd=args.cwd, approval_policy="never", sandbox="readOnly",
                network_access=False, timeout_s=args.timeout, provider=provider,
                purpose=purpose, on_thread=set_thread,
            )
        return {
            "provider": provider,
            "threadId": run.thread_id,
            "turnId": run.turn_id,
            "status": run.status,
            "assistant": run.assistant,
        }
