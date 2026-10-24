import asyncio
import collections
import json
import sys
import time
import weakref
from contextlib import ExitStack, asynccontextmanager
from typing import Any

import httpx

from .config import GatewayConfig
from .transport import GatewayOpeningTimeout, websocket

_readers: weakref.WeakKeyDictionary = weakref.WeakKeyDictionary()


EX_TEMPFAIL = 75


RETRYABLE_CLOSE_CODES = frozenset({1001, 1012, 1013, 4012})


_MAX_PENDING_MESSAGES = 1024


_MAX_PENDING_BYTES = 8 * 1024 * 1024


_REFUSAL_CODES = {-32600, -32601, -32602, -32001, -32002, -32003, -32009}
_RETRYABLE_REFUSAL_CODES = {-32001, -32002, -32003, -32009}


def _masked_frame_prefix(data: bytes) -> str:
    data = data[:64]
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return "_" * len(data)
    if 0 in data:
        return "_" * len(data)
    prefix = bytearray()
    quoted = False
    escaped = False
    for byte in data:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
                prefix.append(byte)
                continue
            prefix.append(95)
        else:
            if byte == 34:
                quoted = True
            prefix.append(byte if byte in b'{}[]:," ' else 95)
    return prefix.decode("ascii")


class GatewayRPCError(RuntimeError):
    def __init__(self, method: str, error: Any, elapsed: float) -> None:
        super().__init__(f"{method} failed after {elapsed:.2f}s: {error}")
        details = error if isinstance(error, dict) else {}
        data = details.get("data")
        self.method = method
        self.code = details.get("code")
        self.data: dict[str, Any] = data if isinstance(data, dict) else {}

    @property
    def refused_before_dispatch(self) -> bool:
        kind = self.data.get("kind")
        uncertain = isinstance(kind, str) and kind.endswith(("Uncertain", "Unknown"))
        return self.code in _REFUSAL_CODES and not uncertain

    @property
    def retryable(self) -> bool:
        retryable = self.data.get("retryable")
        if isinstance(retryable, bool):
            return retryable
        return self.code in _RETRYABLE_REFUSAL_CODES


class _RpcReader:
    def __init__(self, ws) -> None:
        self.socket = weakref.ref(ws)
        self.pending: dict[int, asyncio.Future[tuple[dict[str, Any], int]]] = {}
        self.frames: collections.deque[tuple[dict[str, Any], int]] = collections.deque()
        self.size = 0
        self.dropped = 0
        self.ready = asyncio.Event()
        self.failure: BaseException | None = None
        self.task: asyncio.Task[None] | None = None
        self.observer = None

    def start(self) -> None:
        if self.task is None:
            self.task = asyncio.create_task(self._read())

    async def _read(self) -> None:
        try:
            while True:
                ws = self.socket()
                if ws is None:
                    return
                raw = await ws.recv()
                data = raw if isinstance(raw, bytes) else raw.encode("utf-8")
                if isinstance(raw, bytes):
                    raw = raw.decode("utf-8", errors="replace")
                try:
                    message = json.loads(raw)
                except json.JSONDecodeError:
                    raise RuntimeError(f"invalid json from gateway bytes={len(data)} stage=json prefix={_masked_frame_prefix(data)}") from None
                if not isinstance(message, dict):
                    raise RuntimeError(f"unexpected message shape: {type(message)}")
                if self.observer is not None:
                    self.observer(message)
                byte_count = len(data)
                request_id = message.get("id")
                is_response = "method" not in message and isinstance(request_id, int)
                pending = self.pending.get(request_id) if is_response else None
                if pending is not None and not pending.done():
                    pending.set_result((message, byte_count))
                    continue
                self.frames.append((message, byte_count))
                self.size += byte_count
                while self.frames and (
                    len(self.frames) > _MAX_PENDING_MESSAGES or self.size > _MAX_PENDING_BYTES
                ):
                    _, removed_bytes = self.frames.popleft()
                    self.size -= removed_bytes
                    self.dropped += 1
                self.ready.set()
        except BaseException as exc:
            self.failure = exc
            for pending in self.pending.values():
                if not pending.done():
                    pending.set_exception(exc)
            self.ready.set()

    def observe(self, callback) -> None:
        for message, _ in self.frames:
            callback(message)
        self.observer = callback

    async def next_message(self, timeout_s: float | None) -> dict[str, Any]:
        self.start()
        while True:
            if self.dropped:
                raise RuntimeError(
                    f"{self.dropped} gateway messages were dropped while waiting for RPC responses; the event evidence is incomplete"
                )
            if self.frames:
                message, byte_count = self.frames.popleft()
                self.size -= byte_count
                return message
            if self.failure is not None:
                raise self.failure
            self.ready.clear()
            await asyncio.wait_for(self.ready.wait(), timeout=timeout_s)


def _reader(ws) -> _RpcReader:
    reader = _readers.get(ws)
    if reader is None:
        reader = _RpcReader(ws)
        _readers[ws] = reader
    return reader


def _json(obj: object) -> str:
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=True)


def _event_thread_id(msg: dict[str, Any]) -> str | None:
    params = msg.get("params")
    if not isinstance(params, dict):
        return None
    tid = params.get("threadId") or params.get("conversationId")
    if tid:
        return tid
    nested = params.get("msg")
    if isinstance(nested, dict):
        tid = nested.get("thread_id")
    return tid


async def _ws_recv_json(ws, *, timeout_s: float | None) -> dict[str, Any]:
    try:
        return await _reader(ws).next_message(timeout_s)
    except TimeoutError as error:
        raise TimeoutError(f"Gateway frame wait timed out for {_peer_target(ws)} (timeout={timeout_s})") from error


def _peer_target(ws) -> str:
    address = ws.remote_address
    if isinstance(address, tuple) and len(address) >= 2:
        return f"{address[0]}:{address[1]}"
    return "unknown gateway peer"


async def _ws_connect(cfg: GatewayConfig):
    return await websocket(cfg)


@asynccontextmanager
async def _open_gateway(cfg: GatewayConfig, *, timeout_s: float, method: str):
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout_s
    budget = asyncio.timeout_at(deadline)
    target = f"{cfg.host}:{cfg.port}"
    retry_delay_s = 0.1
    minimum_retry_budget_s = 0.1
    stage = "WebSocket opening handshake"
    phase_started = time.perf_counter()
    phase_timeout_s = min(5, timeout_s)
    try:
        async with budget:
            for attempt in range(2):
                started = time.perf_counter()
                try:
                    with ExitStack() as setup:
                        stage = "WebSocket opening handshake"
                        phase_started = time.perf_counter()
                        phase_timeout_s = min(5, max(0, deadline - loop.time()))
                        try:
                            async with asyncio.timeout(phase_timeout_s):
                                ws = await _ws_connect(cfg)
                        except TimeoutError as error:
                            raise GatewayOpeningTimeout(stage, target, time.perf_counter() - phase_started,
                                                        phase_timeout_s) from error
                        setup.callback(ws.transport.abort)
                        stage = "ready notification"
                        phase_started = time.perf_counter()
                        phase_timeout_s = max(0, deadline - loop.time())
                        await _drain_ready(ws, timeout_s=phase_timeout_s)
                        setup.pop_all()
                except GatewayOpeningTimeout as error:
                    remaining = deadline - loop.time()
                    if attempt == 1 or remaining <= retry_delay_s + minimum_retry_budget_s:
                        raise TimeoutError(f"Gateway opening before {method}: {error}") from error
                    print(json.dumps({"event": "gateway_opening_retry", "attempt": 1, "method": method,
                                      "stage": error.stage, "target": error.target,
                                      "elapsedSeconds": round(error.elapsed, 6), "timeoutSeconds": error.timeout_s}),
                          file=sys.stderr)
                    stage = "retry backoff"
                    phase_started = time.perf_counter()
                    phase_timeout_s = retry_delay_s
                    await asyncio.sleep(retry_delay_s)
                    if deadline - loop.time() < minimum_retry_budget_s:
                        raise TimeoutError(f"Gateway opening before {method}: {error} (insufficient remaining setup budget)") from error
                else:
                    break
    except TimeoutError as error:
        if not budget.expired():
            raise
        failure = GatewayOpeningTimeout(stage, target, time.perf_counter() - phase_started, phase_timeout_s)
        raise TimeoutError(f"Gateway opening before {method}: {failure} (setup budget {timeout_s:g} seconds exhausted)") from error
    async with ws:
        if attempt == 1:
            print(json.dumps({"event": "gateway_opening_recovered", "attempt": 2, "method": method,
                              "target": target,
                              "elapsedSeconds": round(time.perf_counter() - started, 6)}), file=sys.stderr)
        yield ws


async def _claude_health(cfg: GatewayConfig) -> dict[str, Any]:
    headers = {"Authorization": f"Bearer {cfg.token}"}
    try:
        async with cfg.http_client(timeout=10.0) as client:
            r = await client.get(f"{cfg.http_base}/health", headers=headers)
    except httpx.TimeoutException as error:
        raise TimeoutError(f"Gateway Claude health request timed out for {cfg.host}:{cfg.port} after 10 seconds") from error
    r.raise_for_status()
    body = r.json()
    claude = body.get("claude")
    if not isinstance(claude, dict):
        raise RuntimeError("/health carries no claude block (daemon too old?)")
    return claude


async def _drain_ready(ws, *, timeout_s: float) -> dict[str, Any]:
    # The daemon typically sends a "ready" notification immediately after connect.
    started = time.perf_counter()
    try:
        msg = await _ws_recv_json(ws, timeout_s=timeout_s)
    except TimeoutError as error:
        raise GatewayOpeningTimeout("ready notification", _peer_target(ws),
                                    time.perf_counter() - started, timeout_s) from error
    return msg


def _initialize_request(request_id: int) -> dict[str, Any]:
    return {
        "id": request_id,
        "method": "initialize",
        "params": {
            "clientInfo": {
                "name": "rc-gateway",
                "title": "RemoteCoder dev-tools/rc-gateway",
                "version": "0.1.0",
            },
            "capabilities": {"experimentalApi": True},
        },
    }


async def _initialize(ws, *, timeout_s: float) -> None:
    init_id = 9_000_001
    await ws.send(_json(_initialize_request(init_id)))
    while True:
        try:
            msg = await _ws_recv_json(ws, timeout_s=timeout_s)
        except TimeoutError as error:
            raise TimeoutError(f"Gateway initialize response timed out for {_peer_target(ws)} after {timeout_s:g} seconds") from error
        if msg.get("id") != init_id:
            continue
        if "error" in msg:
            raise RuntimeError(f"initialize failed: {msg['error']}")
        break

    await ws.send(_json({"method": "initialized", "params": {}}))


async def request_response(
    ws,
    *,
    req_id: int,
    payload: str,
    timeout_s: float,
    send_timeout_s: float,
) -> tuple[dict[str, Any], float, int]:
    started = time.perf_counter()
    reader = _reader(ws)
    if req_id in reader.pending:
        raise RuntimeError(f"request id {req_id} is already pending")
    if len(reader.pending) >= _MAX_PENDING_MESSAGES:
        raise RuntimeError("too many gateway requests are pending")
    if reader.failure is not None:
        raise reader.failure
    pending = asyncio.get_running_loop().create_future()
    reader.pending[req_id] = pending
    reader.start()
    stage = "RPC send"
    deadline = send_timeout_s
    try:
        async with asyncio.timeout(timeout_s):
            async with asyncio.timeout(send_timeout_s):
                await ws.send(payload)
            stage = "RPC response"
            deadline = timeout_s
            msg, raw_bytes = await pending
    except TimeoutError as error:
        method = json.loads(payload).get("method")
        raise TimeoutError(f"Gateway {stage} for {method} (request {req_id}) timed out for {_peer_target(ws)} after {deadline:g} seconds") from error
    finally:
        reader.pending.pop(req_id, None)
        if not pending.done():
            pending.cancel()

    elapsed = time.perf_counter() - started
    return msg, elapsed, raw_bytes


async def _timed_rpc(
    ws,
    *,
    req_id: int,
    method: str,
    params: dict[str, Any],
    timeout_s: float,
) -> tuple[dict[str, Any], float, int]:
    msg, elapsed, raw_bytes = await request_response(
        ws, req_id=req_id, payload=_json({"id": req_id, "method": method, "params": params}),
        timeout_s=timeout_s, send_timeout_s=timeout_s,
    )
    if "error" in msg:
        raise GatewayRPCError(method, msg["error"], elapsed)
    result = msg.get("result")
    if not isinstance(result, dict):
        raise RuntimeError(f"{method}: missing object result")
    return result, elapsed, raw_bytes
