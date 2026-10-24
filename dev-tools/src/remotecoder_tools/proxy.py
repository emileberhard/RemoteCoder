import asyncio
import os
import select
import sys
from typing import BinaryIO

from websockets.exceptions import ConnectionClosed

from .rpc import EX_TEMPFAIL, RETRYABLE_CLOSE_CODES, _json, _reader

LINE_LIMIT = 32 * 1024 * 1024
FLUSH_GRACE_S = 5.0


async def stdio_streams(
    stdin: BinaryIO, stdout: BinaryIO
) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=LINE_LIMIT)
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), stdin)
    transport, protocol = await loop.connect_write_pipe(
        lambda: asyncio.StreamReaderProtocol(asyncio.StreamReader()), stdout
    )
    return reader, asyncio.StreamWriter(transport, protocol, None, loop)


async def bridge(ws, stdin: asyncio.StreamReader, stdout: asyncio.StreamWriter) -> int:
    requests = asyncio.create_task(_forward_requests(stdin, ws))
    messages = asyncio.create_task(_forward_messages(ws, stdout))
    closed = asyncio.create_task(ws.wait_closed())
    tasks = (requests, messages, closed)
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        if _finished_cleanly(requests) or _client_gone(messages):
            await ws.close()
            return 0
        await asyncio.wait({messages}, timeout=FLUSH_GRACE_S)
        status, diagnostic = _gateway_failure(ws, requests, messages)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await _close_output(stdout)
    _report(diagnostic)
    return status


def _report(diagnostic: str) -> None:
    line = diagnostic.encode("utf-8")[: select.PIPE_BUF - 1] + b"\n"
    try:
        _, writable, _ = select.select([], [sys.stderr], [], FLUSH_GRACE_S)
        if writable:
            os.write(sys.stderr.fileno(), line)
    except OSError:
        pass


async def _close_output(stdout: asyncio.StreamWriter) -> None:
    stdout.close()
    try:
        async with asyncio.timeout(FLUSH_GRACE_S):
            await stdout.wait_closed()
    except (TimeoutError, OSError):
        stdout.transport.abort()


async def _forward_requests(stdin: asyncio.StreamReader, ws) -> None:
    while line := await stdin.readline():
        if frame := line.strip():
            await ws.send(frame.decode("utf-8"))


async def _forward_messages(ws, stdout: asyncio.StreamWriter) -> None:
    reader = _reader(ws)
    while True:
        message = await reader.next_message(None)
        stdout.write(_json(message).encode("utf-8") + b"\n")
        await stdout.drain()


def _finished_cleanly(task: asyncio.Task[None]) -> bool:
    return task.done() and not task.cancelled() and task.exception() is None


def _client_gone(task: asyncio.Task[None]) -> bool:
    return (
        task.done()
        and not task.cancelled()
        and isinstance(task.exception(), (BrokenPipeError, ConnectionResetError))
    )


def _gateway_failure(ws, *tasks: asyncio.Task[None]) -> tuple[int, str]:
    for task in tasks:
        if task.done() and not task.cancelled():
            error = task.exception()
            if error is not None and not isinstance(error, ConnectionClosed):
                return 2, f"error: gateway proxy failed: {error}"
    code = ws.close_code
    status = EX_TEMPFAIL if code in RETRYABLE_CLOSE_CODES else 2
    return status, f"error: gateway closed the proxy connection (code {code})"
