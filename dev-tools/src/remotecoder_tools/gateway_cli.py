import argparse
import asyncio
import base64
import json
import mimetypes
import subprocess
import sys
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from .compaction_probe import cmd_e2e_compact_live
from .config import (
    DEFAULT_CODEX_PROBE_MODEL,
    _redact_token,
    _resolve_config,
    add_connection_arguments,
)
from .device_tools_probe import cmd_e2e_device_tools_live
from .diagnostics import (
    DEFAULT_DESKTOP_DIR,
    DEFAULT_JOURNAL_DIR,
    cmd_desktop_journal,
    cmd_e2e_journal_live,
    cmd_journal,
)
from .event_log import event_log
from .file_io import finish_thread_io
from .performance import cmd_e2e_reads
from .probes import (
    cmd_e2e_agent_tools_live,
    cmd_e2e_claude_steer_live,
    cmd_e2e_claude_wake_live,
    cmd_e2e_files_live,
    cmd_e2e_fork_live,
    cmd_e2e_questions_live,
    cmd_e2e_thread_name_live,
    cmd_e2e_upload_live,
    cmd_upload,
)
from .queue_probe import cmd_e2e_queue_live
from . import proxy
from .rpc import (
    EX_TEMPFAIL,
    RETRYABLE_CLOSE_CODES,
    GatewayRPCError,
    _claude_health,
    _drain_ready,
    _event_thread_id,
    _initialize,
    _json,
    _open_gateway,
    _reader,
    _timed_rpc,
    _ws_connect,
    _ws_recv_json,
)
from .turns import PURPOSES, _completed_turn_exit_code, _run_gateway_turn


async def cmd_config(args: argparse.Namespace) -> int:
    cfg = _resolve_config(args)
    print("gateway:")
    print(f"  ws_url={cfg.ws_url}")
    if args.reveal_token:
        print(f"  token={cfg.token}")
    else:
        print(f"  token={_redact_token(cfg.token)}")
    return 0


async def cmd_health(args: argparse.Namespace) -> int:
    cfg = _resolve_config(args)
    if args.provider == "claude":
        claude = await _claude_health(cfg)
        print(json.dumps(claude, indent=2, ensure_ascii=True))
        if not claude.get("enabled"):
            print("claude provider is disabled on this gateway", file=sys.stderr)
            return 1
        if not claude.get("ok"):
            print(f"claude preflight failed: {claude.get('error')}", file=sys.stderr)
            return 1
        return 0
    url = f"{cfg.http_base}/health"
    headers = {"Authorization": f"Bearer {cfg.token}"}
    async with cfg.http_client(timeout=10.0) as client:
        r = await client.get(url, headers=headers)
    print(f"GET {url} -> {r.status_code}")
    ct = r.headers.get("content-type", "")
    if "application/json" in ct:
        try:
            print(json.dumps(r.json(), indent=2, ensure_ascii=True))
        except Exception:
            print(r.text.strip())
    else:
        print(r.text.strip())
    return 0


def _transient_connection_failure(error: Exception, *, sent: bool) -> bool:
    from websockets.exceptions import ConnectionClosed, InvalidStatus

    if isinstance(error, ConnectionClosed):
        if error.rcvd is None:
            return not sent
        return error.rcvd.code in RETRYABLE_CLOSE_CODES
    if sent:
        return False
    if isinstance(error, InvalidStatus):
        status = error.response.status_code
        return status >= 500
    return isinstance(error, (TimeoutError, OSError))


async def cmd_rpc(args: argparse.Namespace) -> int:
    method = args.method.strip()
    if not method:
        raise SystemExit("--method is required")
    try:
        cfg = _resolve_config(args)
    except SystemExit as error:
        raise SystemExit(f"Gateway RPC {method} configuration: {error}") from error
    except Exception as error:
        raise RuntimeError(f"Gateway RPC {method} configuration: {error}") from error

    params: object | None = {}
    if args.params_json is not None:
        params = json.loads(sys.stdin.read() if args.params_json == "-" else args.params_json)

    sent = False
    stage = "connection opening"
    try:
        async with _open_gateway(cfg, timeout_s=args.timeout, method=method) as ws:
            stage = "initialize"
            await _initialize(ws, timeout_s=args.timeout)
            req_id = 1
            payload: dict[str, Any] = {"id": req_id, "method": method, "params": params}
            stage = "RPC send"
            sent = True
            await ws.send(_json(payload))

            stage = "RPC response"
            while True:
                msg = await _ws_recv_json(ws, timeout_s=args.timeout)
                if msg.get("id") != req_id:
                    # Ignore notifications.
                    continue
                print(json.dumps(msg, indent=2, ensure_ascii=True))
                return 0
    except Exception as error:
        from websockets.exceptions import InvalidStatus

        if isinstance(error, InvalidStatus) and error.response.status_code == 409:
            detail = error.response.body.decode("utf-8", errors="replace")[:1000]
            raise RuntimeError(f"Gateway connection rejected (HTTP 409): {detail}") from error
        if getattr(args, "debug", False):
            raise
        detail = str(error) or "timed out connecting to the gateway"
        if isinstance(error, TimeoutError):
            detail = f"Gateway RPC {method}, stage={stage}, target={cfg.host}:{cfg.port}: {detail}"
        if not _transient_connection_failure(error, sent=sent):
            if isinstance(error, TimeoutError):
                raise TimeoutError(detail) from error
            raise
        print(f"error: {detail} (transient; retry)", file=sys.stderr)
        return EX_TEMPFAIL


async def cmd_proxy(args: argparse.Namespace) -> int:
    cfg = _resolve_config(args)
    try:
        async with _open_gateway(cfg, timeout_s=args.timeout, method="proxy") as ws:
            stdin, stdout = await proxy.stdio_streams(sys.stdin.buffer, sys.stdout.buffer)
            return await proxy.bridge(ws, stdin, stdout)
    except Exception as error:
        if not _transient_connection_failure(error, sent=False):
            raise
        print(f"error: gateway proxy connection to {cfg.host}:{cfg.port}: {error} (transient; retry)", file=sys.stderr)
        return EX_TEMPFAIL


async def cmd_thread_read(args: argparse.Namespace) -> int:
    cfg = _resolve_config(args)
    thread_id = args.thread_id.strip()
    if not thread_id:
        raise SystemExit("--thread-id is required")

    async with await _ws_connect(cfg) as ws:
        _ = await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)
        req_id = 1
        await ws.send(
            _json(
                {
                    "id": req_id,
                    "method": "thread/read",
                    "params": {"threadId": thread_id, "includeTurns": bool(args.include_turns)},
                }
            )
        )
        while True:
            msg = await _ws_recv_json(ws, timeout_s=args.timeout)
            if msg.get("id") != req_id:
                continue
            print(json.dumps(msg, indent=2, ensure_ascii=True))
            return 0


async def cmd_listen(args: argparse.Namespace) -> int:
    cfg = _resolve_config(args)
    filter_tid = (args.thread_id or "").strip() or None
    async with await _ws_connect(cfg) as ws:
        ready = await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)
        print(json.dumps(ready, indent=2, ensure_ascii=True))
        while True:
            msg = await _ws_recv_json(ws, timeout_s=args.timeout)
            if filter_tid:
                evt_tid = _event_thread_id(msg)
                if evt_tid is not None and evt_tid != filter_tid:
                    continue
            if args.methods_only:
                method = msg.get("method")
                if isinstance(method, str):
                    print(method)
                else:
                    print("(no method)")
            else:
                print(json.dumps(msg, indent=2, ensure_ascii=True))


async def cmd_active_turns(args: argparse.Namespace) -> int:
    cfg = _resolve_config(args)
    async with await _ws_connect(cfg) as ws:
        _ = await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)
        req_id = 1
        await ws.send(_json({"id": req_id, "method": "daemon/activeTurns", "params": {}}))
        while True:
            msg = await _ws_recv_json(ws, timeout_s=args.timeout)
            if msg.get("id") != req_id:
                continue
            if "error" in msg:
                raise RuntimeError(msg["error"].get("message", "daemon/activeTurns failed"))
            result = msg.get("result", {})
            break

        if args.json:
            print(json.dumps(result, indent=2, ensure_ascii=True))
            return 0

        active = result.get("activeTurns") or []
        coverage = result.get("coverage") or {}
        for provider in ("codex", "claude"):
            print(f"coverage.{provider}={str(coverage.get(provider) is True).lower()}")
        print(f"activeTurns={len(active)}")
        for entry in active:
            print(
                "  active: "
                f"threadId={entry.get('threadId', '?')} "
                f"turnId={entry.get('turnId', '?')} "
                f"source={entry.get('source', '?')} "
                f"cwd={entry.get('cwd') or '-'}"
            )
        return 0


@asynccontextmanager
async def _turn_connection(cfg, timeout_s: float, record):
    try:
        socket = await _ws_connect(cfg)
    except Exception as error:
        record({"type": "dispatch.not_started", "retryable": _transient_connection_failure(error, sent=False)})
        raise
    async with socket as ws:
        try:
            ready = await _drain_ready(ws, timeout_s=timeout_s)
            await _initialize(ws, timeout_s=timeout_s)
        except Exception as error:
            record({"type": "dispatch.not_started", "retryable": _transient_connection_failure(error, sent=False)})
            raise
        try:
            yield ws, ready
        except GatewayRPCError as error:
            if error.refused_before_dispatch:
                record({"type": "dispatch.not_started", "retryable": error.retryable})
            raise


async def cmd_turn(args: argparse.Namespace) -> int:
    cfg = _resolve_config(args)
    if args.prompt is None:
        raise SystemExit("--prompt is required")
    counts: dict[str, int] = {}

    def bump(method: str | None) -> None:
        if method:
            counts[method] = counts.get(method, 0) + 1

    def show(msg: dict[str, Any]) -> None:
        method = msg.get("method")
        bump(method if isinstance(method, str) else None)
        if args.show_all:
            print(json.dumps(msg, indent=2, ensure_ascii=True))
        if method == "item/agentMessage/delta" and args.show_deltas:
            delta = msg.get("params", {}).get("delta")
            if isinstance(delta, str):
                print(delta, end="", flush=True)

    async with event_log(args.event_log) as record:
        input_items: list[dict[str, Any]] = [{"type": "text", "text": args.prompt.strip("\n")}]
        for raw in args.image_path or []:
            input_items.append({"type": "image", "url": await finish_thread_io(_data_url_for_image_path, Path(raw))})

        async with _turn_connection(cfg, args.timeout, record) as (ws, ready):
            if args.event_log:
                _reader(ws).observe(record)
            bump(ready.get("method"))
            ids = iter(range(1, 1_000_000))
            thread_id = ""

            def thread_started(value: str) -> None:
                nonlocal thread_id
                thread_id = value
                record({"type": "thread.started", "thread_id": value})

            def turn_started(turn_id: str) -> None:
                record({"type": "turn.started", "thread_id": thread_id, "turn_id": turn_id})

            run = await _run_gateway_turn(
                ws, next_id=ids.__next__, prompt=args.prompt.strip("\n"), resume=args.resume,
                model=args.model.strip(), cwd=args.cwd, approval_policy=args.approval_policy.strip(),
                sandbox=args.sandbox, network_access=not args.no_network_access,
                timeout_s=args.timeout, input_items=input_items, effort=args.effort,
                service_tier="priority" if args.service_tier == "fast" else None,
                exclude_turns=False, purpose=args.purpose, on_event=show,
                on_thread=thread_started, on_turn=turn_started,
            )

    if args.show_deltas:
        print()
    print(f"threadId={run.thread_id} turnId={run.turn_id}")
    if args.show_counts:
        print("top events:")
        for method, count in sorted(counts.items(), key=lambda pair: (-pair[1], pair[0]))[:20]:
            print(f"  {method}: {count}")
    if args.print_assistant:
        print("\nassistant:")
        print(run.assistant or "(empty)")
    if run.status != "completed":
        detail = f": {run.error}" if run.error else ""
        print(f"turn ended with status {run.status or 'unknown'}{detail}", file=sys.stderr)
    return _completed_turn_exit_code(run.status)


async def cmd_steer(args: argparse.Namespace) -> int:
    """Inject user input into an actively running turn (turn/steer)."""
    cfg = _resolve_config(args)
    thread_id = args.thread_id.strip()
    if not thread_id:
        raise SystemExit("--thread-id is required")
    text = args.text
    if not text or not text.strip():
        raise SystemExit("--text is required")

    turn_id: str | None = args.turn_id
    probe_s: float = args.probe
    if probe_s < 0:
        raise SystemExit("--probe must be >= 0")

    async with await _ws_connect(cfg) as ws:
        _ = await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)

        req_id = 0
        if not turn_id:
            deadline = asyncio.get_running_loop().time() + probe_s
            inventory_available = True
            while True:
                req_id += 1
                remaining = deadline - asyncio.get_running_loop().time()
                snapshot, _, _ = await _timed_rpc(
                    ws,
                    req_id=req_id,
                    method="daemon/activeTurns",
                    params={},
                    timeout_s=min(args.timeout, max(remaining, 0.1)),
                )
                active = snapshot.get("activeTurns")
                if not isinstance(active, list):
                    raise RuntimeError("daemon/activeTurns returned no activeTurns array")
                matches = [
                    entry.get("turnId")
                    for entry in active
                    if isinstance(entry, dict) and entry.get("threadId") == thread_id
                ]
                if len(matches) > 1 or (matches and not isinstance(matches[0], str)):
                    raise RuntimeError("daemon/activeTurns returned ambiguous turn identity")
                if matches:
                    turn_id = matches[0]
                    break
                provider = "claude" if thread_id.startswith("claude_") else "codex"
                coverage = snapshot.get("coverage")
                inventory_available = isinstance(coverage, dict) and coverage.get(provider) is True
                if asyncio.get_running_loop().time() >= deadline:
                    break
                await asyncio.sleep(min(0.25, deadline - asyncio.get_running_loop().time()))
            if not turn_id:
                if not inventory_available:
                    raise SystemExit("cannot discover active turn: app-server inventory unavailable")
                raise SystemExit(
                    "no active turn found in the gateway inventory.\n"
                    "hint: start a turn first with `rc-gateway turn`, or pass --turn-id explicitly."
                )

        # Send the steer
        req_id += 1
        input_items: list[dict[str, Any]] = [{"type": "text", "text": text}]
        await ws.send(
            _json(
                {
                    "id": req_id,
                    "method": "turn/steer",
                    "params": {
                        "threadId": thread_id,
                        "expectedTurnId": turn_id,
                        "input": input_items,
                    },
                }
            )
        )

        while True:
            msg = await _ws_recv_json(ws, timeout_s=args.timeout)
            if msg.get("id") != req_id:
                continue
            if "error" in msg:
                err = msg["error"]
                code = err.get("code", "?")
                message = err.get("message", "unknown error")
                data = err.get("data")
                if isinstance(data, dict) and data.get("kind") == "turnNotRunning":
                    raise SystemExit(
                        f"steer rejected: {message}\n"
                        "hint: the turn may have completed before the steer arrived."
                    )
                raise RuntimeError(f"[{code}] {message}")
            resp_turn = msg.get("result", {}).get("turnId", "?")
            print(f"steered turn {resp_turn} on thread {thread_id[:12]}…")
            return 0


async def cmd_thread_list(args: argparse.Namespace) -> int:
    cfg = _resolve_config(args)
    async with await _ws_connect(cfg) as ws:
        _ = await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)
        if args.provider == "claude":
            result, _elapsed, _byte_count = await _timed_rpc(
                ws, req_id=1, method="claude/thread/list", params={"limit": args.limit},
                timeout_s=args.timeout,
            )
            threads = result.get("data") or []
            if not threads:
                print("(no claude threads)")
                return 0
            for thread in threads:
                cwd = str(thread.get("cwd") or "").replace(str(Path.home()), "~")
                preview = str(thread.get("preview") or "")
                short = preview[:60] + ("\u2026" if len(preview) > 60 else "")
                print(f"{thread.get('id', '?')}  {cwd}  \"{short}\"")
            return 0
        req_id = 1
        await ws.send(
            _json({"id": req_id, "method": "thread/list", "params": {}})
        )
        while True:
            msg = await _ws_recv_json(ws, timeout_s=args.timeout)
            if msg.get("id") != req_id:
                continue
            if "error" in msg:
                raise RuntimeError(msg["error"].get("message"))
            threads = msg.get("result", {}).get("data", [])
            if not threads:
                print("(no threads)")
                return 0
            for t in threads:
                tid = t.get("id", "?")
                cwd = t.get("cwd", "")
                preview = t.get("preview", "")
                source = t.get("source", "")
                label = cwd.replace(str(Path.home()), "~") if cwd else ""
                parts = [tid]
                if label:
                    parts.append(label)
                if source:
                    parts.append(f"[{source}]")
                if preview:
                    short = preview[:60] + ("…" if len(preview) > 60 else "")
                    parts.append(f'"{short}"')
                print("  ".join(parts))
            return 0


async def cmd_claude_turn(args: argparse.Namespace) -> int:
    cfg = _resolve_config(args)

    async with event_log(args.event_log) as record:
        input_items: list[dict[str, Any]] = []
        if args.prompt:
            input_items.append({"type": "text", "text": args.prompt})
        for raw in args.image_path or []:
            input_items.append({"type": "image", "url": await finish_thread_io(_data_url_for_image_path, Path(raw))})

        def thread_started(thread_id: str) -> None:
            record({"type": "thread.started", "thread_id": thread_id})
            print(f"thread: {thread_id}")

        def turn_started(turn_id: str) -> None:
            record({"type": "turn.started", "thread_id": thread_id, "turn_id": turn_id})
            print(f"turn: {turn_id}")

        def show(msg: dict[str, Any]) -> None:
            record(msg)
            method = msg.get("method")
            params = msg.get("params") or {}
            if args.show_all:
                print(_json(msg))
            elif method == "item/agentMessage/delta":
                delta = params.get("delta")
                if isinstance(delta, str) and args.show_deltas:
                    sys.stdout.write(delta)
                    sys.stdout.flush()
            elif method in ("item/started", "item/completed") and args.show_items:
                item = params.get("item") or {}
                print(f"  [{method}] {item.get('type')} {str(item.get('id') or '')}")

        async with _turn_connection(cfg, args.timeout, record) as (ws, _ready):
            ids = iter(range(1, 1_000_000))
            thread_id = ""

            def set_thread(value: str) -> None:
                nonlocal thread_id
                thread_id = value
                thread_started(value)

            run = await _run_gateway_turn(
                ws, next_id=ids.__next__, prompt=args.prompt, resume=args.resume,
                model=args.model, cwd=args.cwd, approval_policy="never", sandbox="readOnly",
                network_access=False, timeout_s=args.timeout, provider="claude",
                input_items=input_items, effort=args.effort, resume_rpc=False, purpose=args.purpose,
                on_thread=set_thread, on_turn=turn_started, on_event=show,
            )

    print()
    print(f"status: {run.status}")
    if run.error:
        print(f"error: {run.error}")
    if run.assistant:
        print("--- assistant ---")
        print(run.assistant)
    return _completed_turn_exit_code(run.status)


def _data_url_for_image_path(path: Path) -> str:
    path = path.expanduser()
    # Codex tends to be more reliable with JPEG inputs. In particular, the
    # app-server websocket transport in newer versions has been observed to
    # drop connections on PNG data URLs. Convert PNG -> JPEG when possible.
    #
    # This is a dev tool; keep the conversion best-effort and avoid extra deps.
    mime, _enc = mimetypes.guess_type(str(path))
    suffix = path.suffix.lower()
    if mime is None:
        if suffix == ".png":
            mime = "image/png"
        elif suffix in (".jpg", ".jpeg"):
            mime = "image/jpeg"
        else:
            raise RuntimeError(f"unsupported image extension: {path}")

    data: bytes | None = None
    if mime == "image/png":
        try:
            import tempfile

            with tempfile.TemporaryDirectory(prefix="rc-gateway-img-") as td:
                out = Path(td) / (path.stem + ".jpg")
                subprocess.run(
                    ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "82", str(path), "--out", str(out)],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                # Read inside the block: the temp dir is gone once it exits.
                data = out.read_bytes()
                mime = "image/jpeg"
        except Exception:
            # Fall back to the raw PNG data URL.
            data = None

    if data is None:
        data = path.read_bytes()
    if not data:
        raise RuntimeError(f"image is empty: {path}")

    encoded = base64.b64encode(data).decode("ascii")
    if not encoded:
        raise RuntimeError(f"failed to base64-encode image: {path}")

    return f"data:{mime};base64,{encoded}"


def _add_native_page_flags(s: argparse.ArgumentParser) -> None:
    s.add_argument("--max-native-page-bytes", type=int, default=4 * 1024 * 1024)
    s.add_argument("--max-read-seconds", type=float, default=3.0)
    s.add_argument(
        "--max-cold-read-seconds",
        type=float,
        default=10.0,
        help="first page of a thread, which may parse its whole Claude session (default: 10)",
    )
    s.add_argument("--walk-page-size", type=int, default=100)
    s.add_argument("--max-walk-pages", type=int, default=2000)


def _add_turn_flags(s: argparse.ArgumentParser) -> None:
    s.add_argument("--cwd", default=str(Path.cwd()), help="working directory for the codex session")
    s.add_argument("--model", default=DEFAULT_CODEX_PROBE_MODEL, help=f"model name (default: {DEFAULT_CODEX_PROBE_MODEL})")
    s.add_argument(
        "--effort",
        choices=["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"],
        default=None,
        help="reasoning effort override for this turn",
    )
    s.add_argument("--approval-policy", default="never", help="tool-call approval policy (default: never)")
    s.add_argument(
        "--sandbox",
        choices=["dangerFullAccess", "workspaceWrite", "readOnly"],
        default="dangerFullAccess",
        help="sandbox type (default: dangerFullAccess)",
    )
    s.add_argument("--no-network-access", action="store_true", help="disable network inside sandbox")
    s.add_argument("--timeout", type=float, default=20.0, help="per-message recv timeout in seconds")
    s.add_argument("--show-deltas", action="store_true", help="stream assistant text deltas to stdout")
    s.add_argument("--show-all", action="store_true", help="print every JSON-RPC message (filtered to this thread)")
    s.add_argument("--show-counts", action="store_true", help="print event-type frequency table at end")
    s.add_argument("--print-assistant", action="store_true", help="print the final assistant message at end")
    s.add_argument(
        "--event-log",
        default=None,
        metavar="PATH",
        help="write received thread/turn messages as JSONL",
    )


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="rc-gateway",
        description="Debug CLI for the RemoteCoder Codex gateway (JSON-RPC over WebSocket).",
        epilog=(
            "config discovery (in order):\n"
            "  1. explicit --host/--port/--token flags\n"
            "  2. RC_CODEX_GATEWAY_* env vars\n"
            "  3. read the selected host's ~/.remote-coder/codex-gateway.env\n"
            "  4. ignored RemoteCoderLocalConfig.json\n"
            "\n"
            "examples:\n"
            "  rc-gateway config                            # show resolved config\n"
            "  rc-gateway health                            # HTTP health check\n"
            "  rc-gateway thread-list                       # list all threads\n"
            "  rc-gateway turn --prompt 'hello'             # new thread + turn, stream to completion\n"
            "  rc-gateway turn --resume THREAD --prompt ..  # resume existing thread\n"
            "  rc-gateway steer --thread-id THREAD --text 'hey'  # inject into active turn\n"
            "  rc-gateway listen --thread-id THREAD         # tail events for one thread\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    add_connection_arguments(p)

    sub = p.add_subparsers(dest="cmd", required=True, metavar="command")

    # -- config --
    s = sub.add_parser(
        "config",
        help="show resolved gateway config",
        description="Print the resolved gateway connection config. Token is redacted by default.",
    )
    s.add_argument("--reveal-token", action="store_true", help="show the full token")
    s.set_defaults(func=cmd_config)

    # -- health --
    s = sub.add_parser(
        "health",
        help="HTTP health check",
        description="GET /health on the gateway HTTP endpoint.",
    )
    s.add_argument("--provider", choices=["gateway", "claude"], default="gateway", help="gateway health or Claude preflight")
    s.set_defaults(func=cmd_health)

    # -- thread-list --
    s = sub.add_parser(
        "thread-list",
        help="list all threads",
        description="Call thread/list and print a summary of each thread.",
    )
    s.add_argument("--provider", choices=["all", "claude"], default="all", help="all threads or Claude sessions (default: all)")
    s.add_argument("--limit", type=int, default=30, help="max Claude threads to return (default: 30)")
    s.add_argument("--timeout", type=float, default=20.0, help="recv timeout in seconds")
    s.set_defaults(func=cmd_thread_list)

    # -- proxy --
    s = sub.add_parser(
        "proxy",
        help="bridge line-delimited JSON-RPC on stdin/stdout to the gateway",
        description=(
            "Relay JSON-RPC between stdin/stdout and one gateway connection, so a client of "
            "`codex app-server proxy` reaches the gateway and its admission instead. The client sends "
            "initialize itself. Each stdout line is one gateway message; diagnostics go to stderr. "
            "Exits 0 when the client closes stdin or stdout, 75 for a transient connection failure or a "
            "retryable gateway close, and 2 otherwise."
        ),
    )
    s.add_argument("--timeout", type=float, default=10.0, help="connection setup budget in seconds")
    s.set_defaults(func=cmd_proxy)

    # -- thread-read --
    s = sub.add_parser(
        "thread-read",
        help="read a thread (optionally with turn history)",
        description="Call thread/read and print the full JSON response.",
        epilog="example: rc-gateway thread-read --thread-id THREAD_ID --include-turns",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    s.add_argument("--thread-id", required=True, help="thread UUID")
    s.add_argument("--include-turns", action="store_true", help="include turn items in the response")
    s.add_argument("--timeout", type=float, default=20.0)
    s.set_defaults(func=cmd_thread_read)

    # -- rpc --
    s = sub.add_parser(
        "rpc",
        help="send a raw JSON-RPC request",
        description=(
            "Send one JSON-RPC request and print the response.\n"
            "Notifications are silently skipped; only the matching response is printed."
        ),
        epilog=(
            "examples:\n"
            "  rc-gateway rpc --method thread/list --params '{}'\n"
            "  rc-gateway rpc --method thread/read --params '{\"threadId\":\"...\",\"includeTurns\":true}'\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    s.add_argument("--method", required=True, help="JSON-RPC method name")
    s.add_argument("--params", dest="params_json", default=None, help="JSON string for params object, or - to read stdin")
    s.add_argument("--timeout", type=float, default=20.0)
    s.set_defaults(func=cmd_rpc)

    # -- e2e-reads --
    s = sub.add_parser(
        "e2e-reads",
        help="run live read/fetch integration checks without creating turns",
        description=(
            "Exercise the same read-only gateway operations the iOS client uses when\n"
            "opening the history drawer and selecting a conversation. The command does\n"
            "not start threads or send messages."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    s.add_argument("--thread-id", default=None, help="specific thread to read; defaults to latest listed thread")
    s.add_argument("--provider", choices=["both", "claude"], default="both", help="read both providers or run the Claude-only checks")
    s.add_argument("--thread-list-limit", type=int, default=30, help="thread/list limit (default: 30)")
    s.add_argument("--max-replay-pages", type=int, default=2000, help="maximum replay pages per thread (default: 2000)")
    s.add_argument("--timeout", type=float, default=None, help="per-message timeout in seconds (default: 12; 30 with --provider claude)")
    s.add_argument("--expect-nonempty", action="store_true", help="require the selected conversation to have turns")
    s.add_argument("--expect-fork", action="store_true", help="require canonical fork metadata and exercise its native pagination")
    s.add_argument("--claude-thread-id", default=None, help="Claude thread to page; defaults to the newest listed one")
    # Generous on purpose: this asserts thread/list still works, not an SLO. The
    # journal is the latency instrument — query it when a call feels slow.
    s.add_argument("--max-list-seconds", type=float, default=10.0)
    _add_native_page_flags(s)
    s.set_defaults(func=cmd_e2e_reads)

    s = sub.add_parser("e2e-questions-live", help="opt-in async question, partial-answer, dismissal, and reconnect probe")
    s.add_argument("--model", default="gpt-6-astra")
    s.add_argument("--cwd", required=True, help="harmless test working directory on the gateway host")
    s.add_argument("--timeout", type=float, default=90.0)
    s.add_argument("--receipt", help="write the exact test identities and final lifecycle snapshot")
    s.set_defaults(func=cmd_e2e_questions_live)

    # -- e2e-fork-live --
    s = sub.add_parser(
        "e2e-fork-live",
        help="run a mutating live bounded-fork/context integration check",
        description=(
            "Create a real thread through the gateway, add two turns, name it, fork it\n"
            "at the first turn and at its latest turn using the same thread/fork params\n"
            "as the iOS app, and verify fork identity, name, history pages and\n"
            "model-visible context."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    s.add_argument("--provider", choices=["codex", "claude"], default="codex", help="thread provider (default: codex)")
    s.add_argument("--skip-model-probe", action="store_true", help="skip the final model-visible context probe")
    _add_turn_flags(s)
    s.set_defaults(func=cmd_e2e_fork_live, timeout=120.0)

    # -- listen --
    s = sub.add_parser(
        "listen",
        help="stream live notifications",
        description=(
            "Connect and print every notification as it arrives.\n"
            "Use --thread-id to filter to a single thread.\n"
            "Use --methods-only for a compact event-name-only stream."
        ),
        epilog=(
            "examples:\n"
            "  rc-gateway listen                                 # all events\n"
            "  rc-gateway listen --thread-id THREAD              # one thread only\n"
            "  rc-gateway listen --thread-id THREAD --methods-only\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    s.add_argument("--thread-id", default=None, help="only show events for this thread")
    s.add_argument("--timeout", type=float, default=60.0, help="per-message recv timeout in seconds")
    s.add_argument("--methods-only", action="store_true", help="print only method names (one per line)")
    s.set_defaults(func=cmd_listen)

    # -- active-turns --
    s = sub.add_parser(
        "active-turns",
        help="authoritative list of threads with in-progress turns",
        description=(
            "Reads the daemon's passive app-server inventory plus gateway-owned turns.\n"
            "The result explicitly reports when the app-server inventory is unavailable."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    s.add_argument("--timeout", type=float, default=10.0, help="recv timeout in seconds")
    s.add_argument("--json", action="store_true", help="print a machine-readable JSON payload")
    s.set_defaults(func=cmd_active_turns)

    # -- turn --
    s = sub.add_parser(
        "turn",
        help="start a new turn (thread/start + turn/start) and stream to completion",
        description=(
            "Start or resume a thread, send a user prompt, and stream events until\n"
            "the turn completes.  All events are filtered to this thread only.\n"
            "\n"
            "Output is minimal by default; add flags to see more:\n"
            "  --show-deltas     stream assistant text as it arrives\n"
            "  --show-all        print every JSON-RPC message\n"
            "  --print-assistant print the final assembled response\n"
            "  --show-counts     event frequency summary at end"
        ),
        epilog=(
            "examples:\n"
            "  rc-gateway turn --prompt 'explain this code' --show-deltas\n"
            "  rc-gateway turn --prompt 'hello' --show-all > events.jsonl\n"
            "  rc-gateway turn --resume THREAD_ID --prompt 'continue' --print-assistant\n"
            "  rc-gateway turn --prompt 'fix the bug' --image-path screenshot.png\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    s.add_argument("--resume", default=None, metavar="THREAD_ID", help="resume an existing thread instead of starting a new one")
    s.add_argument("--prompt", required=True, help="user message text")
    s.add_argument(
        "--image-path",
        action="append",
        default=None,
        metavar="PATH",
        help="attach an image (repeatable); auto-converts PNG to JPEG",
    )
    _add_turn_flags(s)
    s.add_argument(
        "--service-tier", choices=["standard", "fast"], default="standard",
        help="Codex service tier for this dispatch; standard clears inherited Fast mode (default: standard)",
    )
    s.add_argument(
        "--purpose",
        choices=PURPOSES,
        default=None,
        help="mark a new thread as a probe (hidden from the drawer) or an automation (never unread)",
    )
    s.set_defaults(func=cmd_turn)

    # -- steer --
    s = sub.add_parser(
        "steer",
        help="inject input into an active turn (turn/steer)",
        description=(
            "Send additional user input to a running turn without interrupting it.\n"
            "The agent sees the steer as new context and can adjust its response.\n"
            "\n"
            "IMPORTANT: turn/steer only works while a turn is actively running.\n"
            "If the turn completes before the steer arrives, it will be rejected.\n"
            "\n"
            "By default the command reads the gateway's active-turn inventory.\n"
            "If no active turn appears within --probe seconds\n"
            "it exits with a clear error instead of sending a steer that would fail."
        ),
        epilog=(
            "examples:\n"
            "  rc-gateway steer --thread-id THREAD --text 'also check the tests'\n"
            "  rc-gateway steer --thread-id THREAD --text 'stop, use python instead'\n"
            "  rc-gateway steer --thread-id THREAD --turn-id 1 --text 'hurry up'\n"
            "\n"
            "how to find the thread ID:\n"
            "  rc-gateway thread-list                # lists all threads\n"
            "  rc-gateway listen --methods-only      # watch live events\n"
            "  # the iOS app shows it in conversation history\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    s.add_argument("--thread-id", required=True, help="thread UUID to steer")
    s.add_argument("--text", required=True, help="message to inject into the running turn")
    s.add_argument(
        "--turn-id",
        default=None,
        help="explicit expectedTurnId (auto-discovered if omitted)",
    )
    s.add_argument("--probe", type=float, default=5.0, help="seconds to wait for an active turn before giving up (default: 5)")
    s.add_argument("--timeout", type=float, default=10.0, help="recv timeout in seconds")
    s.set_defaults(func=cmd_steer)

    s = sub.add_parser("claude-turn", help="run one Claude turn and stream its notifications")
    s.add_argument("prompt", nargs="?", default="", help="prompt text (optional when --image-path is given)")
    s.add_argument(
        "--image-path",
        action="append",
        default=None,
        metavar="PATH",
        help="attach an image (repeatable); auto-converts PNG to JPEG",
    )
    s.add_argument("--resume", default=None, help="existing claude_<uuid> thread id")
    s.add_argument("--cwd", default=str(Path.cwd()), help="working directory for the turn")
    s.add_argument("--model", default="claude-fable-5", help="model (default: claude-fable-5)")
    s.add_argument(
        "--effort",
        choices=["low", "medium", "high", "xhigh", "max"],
        default=None,
        help="reasoning effort",
    )
    s.add_argument("--timeout", type=float, default=180.0, help="recv timeout in seconds")
    s.add_argument("--show-deltas", action="store_true", help="stream assistant text as it arrives")
    s.add_argument("--show-items", action="store_true", help="print item/started and item/completed")
    s.add_argument("--show-all", action="store_true", help="print every JSON-RPC message")
    s.add_argument(
        "--event-log",
        default=None,
        metavar="PATH",
        help="write the thread/turn lifecycle and received messages as JSONL",
    )
    s.add_argument(
        "--purpose",
        choices=PURPOSES,
        default=None,
        help="mark a new thread as a probe (hidden from the drawer) or an automation (never unread)",
    )
    s.set_defaults(func=cmd_claude_turn)

    s = sub.add_parser(
        "e2e-claude-steer-live",
        help="run a live Claude steering/completion lifecycle regression",
    )
    s.add_argument("--cwd", default=str(Path.cwd()), help="working directory for the test turn")
    s.add_argument("--model", default="claude-sonnet-5", help="Claude model (default: claude-sonnet-5)")
    s.add_argument("--timeout", type=float, default=120.0, help="per-message timeout in seconds")
    s.set_defaults(func=cmd_e2e_claude_steer_live)

    s = sub.add_parser(
        "e2e-thread-name-live",
        help="name a live and an idle thread and read the announced name back",
    )
    s.add_argument("--provider", choices=["claude", "codex"], default="claude", help="thread provider (default: claude)")
    s.add_argument("--cwd", default=str(Path.cwd()), help="working directory for the test turn")
    s.add_argument("--model", default=None, help=f"model (default: claude-sonnet-5 or {DEFAULT_CODEX_PROBE_MODEL})")
    s.add_argument("--timeout", type=float, default=120.0, help="per-message timeout in seconds")
    s.set_defaults(func=cmd_e2e_thread_name_live)

    s = sub.add_parser(
        "e2e-claude-wake-live",
        help="run a live agent-initiated (wake) Claude turn regression",
    )
    s.add_argument("--cwd", default=str(Path.cwd()), help="working directory for the test turn")
    s.add_argument("--model", default="claude-sonnet-5", help="Claude model (default: claude-sonnet-5)")
    s.add_argument(
        "--sleep-seconds",
        type=int,
        default=15,
        help="how long the background subagent sleeps before reporting (default: 15)",
    )
    s.add_argument("--timeout", type=float, default=60.0, help="per-request timeout in seconds")
    s.add_argument(
        "--dispatch-timeout",
        type=float,
        default=180.0,
        help="budget for the dispatched turn to spawn the subagent (default: 180)",
    )
    s.add_argument(
        "--wake-timeout",
        type=float,
        default=300.0,
        help="budget for the agent-initiated turn to arrive and finish (default: 300)",
    )
    s.set_defaults(func=cmd_e2e_claude_wake_live)

    s = sub.add_parser(
        "e2e-journal-live",
        help="run one live Claude turn and assert it lands in the gateway journal",
    )
    s.add_argument("--cwd", default=str(Path.cwd()), help="working directory for the test turn")
    s.add_argument("--model", default="claude-sonnet-5", help="Claude model (default: claude-sonnet-5)")
    s.add_argument("--timeout", type=float, default=180.0, help="per-message timeout in seconds")
    s.add_argument(
        "--journal-timeout",
        type=float,
        default=20.0,
        help="how long to wait for the journal writer to flush (default: 20)",
    )
    s.add_argument(
        "--journal-dir",
        default=DEFAULT_JOURNAL_DIR,
        help=f"journal directory on the gateway host (default: {DEFAULT_JOURNAL_DIR})",
    )
    s.set_defaults(func=cmd_e2e_journal_live)

    s = sub.add_parser(
        "e2e-compact-live",
        help="prove native compaction completion and active-turn refusal for both providers",
        description="Creates hidden probe conversations; seeds harmless context, compacts it, then proves a live shell sleep is preserved when compaction is refused. Stops only its own exact busy turn. No files are edited. Run only after the compaction gateway is deployed.",
    )
    s.add_argument("--provider", choices=["both", "codex", "claude"], default="both")
    s.add_argument("--cwd", default=str(Path.cwd()), help="existing harmless directory on the gateway host")
    s.add_argument("--codex-model", default=DEFAULT_CODEX_PROBE_MODEL)
    s.add_argument("--claude-model", default="claude-sonnet-5")
    s.add_argument("--timeout", type=float, default=180.0, help="bounded deadline for each phase in seconds")
    s.add_argument("--receipt", metavar="PATH", help="write credential-free JSON acceptance receipt")
    s.set_defaults(func=cmd_e2e_compact_live)

    s = sub.add_parser(
        "e2e-queue-live",
        help="prove native queued messages run as FIFO turns and hold after Stop",
        description="Creates a hidden Codex probe conversation; queues two messages behind a live shell sleep and proves they run as separate FIFO turns with their canonical clientUserMessageId, then queues a third, stops the busy turn, proves the queue holds and starts it with Send Now. Stops and removes only its own exact turns and queued messages. No files are edited. Run only after the queued-send gateway is deployed.",
    )
    s.add_argument("--cwd", default=str(Path.cwd()), help="existing harmless directory on the gateway host")
    s.add_argument("--codex-model", default=DEFAULT_CODEX_PROBE_MODEL)
    s.add_argument("--timeout", type=float, default=180.0, help="bounded deadline for each phase in seconds")
    s.add_argument("--receipt", metavar="PATH", help="write credential-free JSON acceptance receipt")
    s.set_defaults(func=cmd_e2e_queue_live)

    s = sub.add_parser(
        "e2e-agent-tools-live",
        help="make a live agent call a RemoteCoder tool and assert the gateway dispatched it",
    )
    s.add_argument(
        "--provider",
        choices=["claude", "codex", "both"],
        default="both",
        help="which agent projection to exercise (default: both)",
    )
    s.add_argument("--cwd", default=str(Path.cwd()), help="working directory for the test turn")
    s.add_argument(
        "--claude-model", default="claude-sonnet-5", help="Claude model (default: claude-sonnet-5)"
    )
    s.add_argument("--codex-model", default=DEFAULT_CODEX_PROBE_MODEL, help=f"Codex model (default: {DEFAULT_CODEX_PROBE_MODEL})")
    s.add_argument("--timeout", type=float, default=180.0, help="per-message timeout in seconds")
    s.add_argument(
        "--journal-timeout",
        type=float,
        default=20.0,
        help="how long to wait for the journal writer to flush (default: 20)",
    )
    s.add_argument(
        "--journal-dir",
        default=DEFAULT_JOURNAL_DIR,
        help=f"journal directory on the gateway host (default: {DEFAULT_JOURNAL_DIR})",
    )
    s.set_defaults(func=cmd_e2e_agent_tools_live)

    s = sub.add_parser("e2e-device-tools-live", help="call take_photo on live Claude and Codex through a fake device")
    s.add_argument("--provider", choices=["claude", "codex", "both"], default="both")
    s.add_argument("--cwd", default=str(Path.cwd()))
    s.add_argument("--claude-model", default="claude-sonnet-5")
    s.add_argument("--codex-model", default=DEFAULT_CODEX_PROBE_MODEL)
    s.add_argument("--timeout", type=float, default=180.0)
    s.add_argument("--journal-timeout", type=float, default=20.0)
    s.add_argument("--journal-dir", default=DEFAULT_JOURNAL_DIR)
    s.set_defaults(func=cmd_e2e_device_tools_live)

    s = sub.add_parser("upload", help="upload one local file through the gateway's /uploads route")
    s.add_argument("file", help="local file to upload")
    s.add_argument("--name", help="file name on the host (default: the local file name)")
    s.add_argument("--timeout", type=float, default=600.0, help="HTTP timeout in seconds (default: 600)")
    s.set_defaults(func=cmd_upload)

    s = sub.add_parser(
        "e2e-upload-live",
        help="upload a PDF with a random codeword and make a live agent read it back, per provider",
    )
    s.add_argument(
        "--provider",
        choices=["claude", "codex", "both"],
        default="both",
        help="which provider reads the upload (default: both)",
    )
    s.add_argument("--cwd", default=str(Path.cwd()), help="working directory for the test turn")
    s.add_argument(
        "--claude-model", default="claude-sonnet-5", help="Claude model (default: claude-sonnet-5)"
    )
    s.add_argument("--codex-model", default=DEFAULT_CODEX_PROBE_MODEL, help=f"Codex model (default: {DEFAULT_CODEX_PROBE_MODEL})")
    s.add_argument("--timeout", type=float, default=180.0, help="per-message timeout in seconds")
    s.add_argument(
        "--journal-timeout",
        type=float,
        default=20.0,
        help="how long to wait for the journal writer to flush (default: 20)",
    )
    s.add_argument(
        "--journal-dir",
        default=DEFAULT_JOURNAL_DIR,
        help=f"journal directory on the gateway host (default: {DEFAULT_JOURNAL_DIR})",
    )
    s.set_defaults(func=cmd_e2e_upload_live)

    s = sub.add_parser("e2e-files-live", help="verify streamed file bytes and retain fresh/resumed provider links for phone acceptance")
    s.add_argument("--provider", choices=["claude", "codex", "both"], default="both")
    s.add_argument("--cwd", default=str(Path.cwd()), help="working directory on the gateway host")
    s.add_argument("--claude-model", default="claude-sonnet-5")
    s.add_argument("--codex-model", default=DEFAULT_CODEX_PROBE_MODEL)
    s.add_argument("--timeout", type=float, default=180.0, help="HTTP and control-operation deadline in seconds")
    s.add_argument("--turn-timeout", type=float, default=180.0, help="overall deadline for each live provider turn")
    s.add_argument("--receipt", help="write JSON evidence, including partial evidence on failure")
    s.set_defaults(func=cmd_e2e_files_live)

    s = sub.add_parser(
        "journal",
        help="query the gateway observability journal (daily JSONL on the gateway host)",
    )
    s.add_argument("--thread", help="only records whose threadId contains this")
    s.add_argument("--trace", help="only records with this exact conversation review traceId")
    s.add_argument("--method", help="only records whose method contains this")
    s.add_argument(
        "--kind",
        action="append",
        default=[],
        help="only these kinds (repeatable or comma-separated): notify, rpc, deliver_drop, client, runtime, transport, push, tool, question, upload, speech, review, title, journal_drop",
    )
    s.add_argument("--since", help="30m / 6h / 3d, or an ISO timestamp (default: yesterday onward)")
    s.add_argument("--last", type=int, help="print only the last N matching records")
    s.add_argument("--follow", action="store_true", help="stream new records as they are written")
    s.add_argument("--json", action="store_true", help="print raw JSONL instead of summaries")
    s.add_argument(
        "--journal-dir",
        default=DEFAULT_JOURNAL_DIR,
        help=f"journal directory on the gateway host (default: {DEFAULT_JOURNAL_DIR})",
    )
    s.set_defaults(func=cmd_journal)

    s = sub.add_parser(
        "desktop-journal",
        help="query the ChatGPT desktop reconciliation journal (why the launcher acted)",
        description=(
            "Every shared-Codex reconciliation records what it observed, the reason it\n"
            "chose, and any signal or relaunch that followed, correlated by one\n"
            "invocation id. Use this to explain an unexpected ChatGPT quit/reopen."
        ),
        epilog=(
            "examples:\n"
            "  rc-gateway desktop-journal --since 6h\n"
            "  rc-gateway desktop-journal --since 3d --event decision\n"
            "  rc-gateway desktop-journal --reason environment-mismatch --json\n"
            "  rc-gateway desktop-journal --invocation 4f1c9a2b --json   # one decision end to end\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    s.add_argument("--invocation", help="only records whose invocation id starts with this")
    s.add_argument(
        "--reason",
        help="only decisions with this reason: healthy, app-absent, environment-mismatch, incompatible-version, observation-failed, not-installed, disabled",
    )
    s.add_argument("--event", help="only records whose event contains this (decision, signal, stabilized, ...)")
    s.add_argument("--since", help="30m / 6h / 3d, or an ISO timestamp (default: yesterday onward)")
    s.add_argument("--last", type=int, help="print only the last N matching records")
    s.add_argument("--json", action="store_true", help="print raw JSONL instead of summaries")
    s.add_argument(
        "--desktop-dir",
        default=DEFAULT_DESKTOP_DIR,
        help=f"desktop journal directory on the gateway host (default: {DEFAULT_DESKTOP_DIR})",
    )
    s.set_defaults(func=cmd_desktop_journal)

    return p


async def _amain() -> int:
    parser = build_parser()
    args = parser.parse_args()

    func = getattr(args, "func", None)
    if func is None:
        raise SystemExit("missing subcommand")

    try:
        return await func(args)
    except KeyboardInterrupt:
        return 130
    except SystemExit:
        raise
    except TimeoutError as exc:
        if getattr(args, "debug", False):
            raise
        detail = str(exc) or f"{args.cmd} timed out for gateway {args.host or args.ssh_host} during an unattributed stage"
        print(f"error: {detail}", file=sys.stderr)
        return 2
    except Exception as exc:
        if getattr(args, "debug", False):
            raise
        print(f"error: {exc}", file=sys.stderr)
        return 2


def main() -> int:
    return asyncio.run(_amain())


if __name__ == "__main__":
    raise SystemExit(main())
