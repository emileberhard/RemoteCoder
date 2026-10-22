import asyncio
import base64
import hashlib
import json
import threading
from contextlib import asynccontextmanager
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest

from remotecoder_tools import gateway_cli, probes
from remotecoder_tools.config import GatewayConfig
from remotecoder_tools.event_log import EventLogError, event_log


@pytest.mark.parametrize("provider", ["codex", "claude"])
async def test_turn_log_and_image_io_leave_the_loop_and_preserve_evidence(tmp_path, monkeypatch, provider):
    loop_thread = threading.get_ident()
    image = tmp_path / "input.jpg"
    image.write_bytes(b"fixture-jpeg")
    log = tmp_path / "nested" / "events.jsonl"
    config = GatewayConfig("127.0.0.1", 1, "synthetic", "ws")
    observed_inputs = []
    observer = SimpleNamespace(callback=None)
    frame = {"method": "fixture/notification", "params": {"sequence": 1}}

    @asynccontextmanager
    async def connection(cfg, timeout_s, record):
        yield object(), {"method": "daemon/ready"}

    def observe(callback):
        observer.callback = callback

    async def turn(ws, **kwargs):
        observed_inputs.extend(kwargs["input_items"])
        kwargs["on_thread"]("exact-thread")
        kwargs["on_turn"]("exact-turn")
        if observer.callback:
            observer.callback(frame)
        kwargs["on_event"](frame)
        return SimpleNamespace(thread_id="exact-thread", turn_id="exact-turn", status="completed", error=None, assistant="")

    original_open = Path.open
    file_threads = []

    def checked_open(path, *args, **kwargs):
        file_threads.append(threading.get_ident())
        assert threading.get_ident() != loop_thread, "file I/O ran on the event loop"
        return original_open(path, *args, **kwargs)

    command = ["turn", "--prompt", "fixture"] if provider == "codex" else ["claude-turn", "fixture"]
    args = gateway_cli.build_parser().parse_args(command + ["--image-path", str(image), "--event-log", str(log)])
    with monkeypatch.context() as patches:
        patches.setattr(gateway_cli, "_resolve_config", lambda args: config)
        patches.setattr(gateway_cli, "_turn_connection", connection)
        patches.setattr(gateway_cli, "_reader", lambda ws: SimpleNamespace(observe=observe))
        patches.setattr(gateway_cli, "_run_gateway_turn", turn)
        patches.setattr(Path, "open", checked_open)
        operation = gateway_cli.cmd_turn if provider == "codex" else gateway_cli.cmd_claude_turn
        assert await operation(args) == 0
    assert len(file_threads) == 2
    assert observed_inputs[1] == {"type": "image", "url": "data:image/jpeg;base64," + base64.b64encode(b"fixture-jpeg").decode()}
    assert [json.loads(line) for line in log.read_text().splitlines()] == [
        {"type": "thread.started", "thread_id": "exact-thread"},
        {"type": "turn.started", "thread_id": "exact-thread", "turn_id": "exact-turn"},
        frame,
    ]
    image.write_bytes(b"")
    with monkeypatch.context() as patches:
        patches.setattr(gateway_cli, "_resolve_config", lambda args: config)
        with pytest.raises(RuntimeError, match="image is empty"):
            await operation(args)
    assert log.read_text() == ""


async def test_event_log_drains_ordered_snapshots_and_closes_after_cancellation(tmp_path, monkeypatch):
    path = tmp_path / "events.jsonl"
    entered = asyncio.Event()
    blocked = asyncio.Event()
    release = threading.Event()
    loop = asyncio.get_running_loop()
    opened = []
    original_open = Path.open

    class Handle:
        def __init__(self, handle):
            self.handle = handle

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return self.handle.__exit__(*args)

        def write(self, line):
            loop.call_soon_threadsafe(blocked.set)
            assert release.wait(5), "test writer was not released"
            return self.handle.write(line)

        def flush(self):
            self.handle.flush()

    def open_log(path, *args, **kwargs):
        handle = original_open(path, *args, **kwargs)
        opened.append(handle)
        return Handle(handle)

    async def operation():
        async with event_log(str(path)) as record:
            message = {"sequence": 1}
            record(message)
            message["sequence"] = 99
            record({"sequence": 2})
            entered.set()
            await asyncio.Event().wait()

    with monkeypatch.context() as patches:
        patches.setattr(Path, "open", open_log)
        task = asyncio.create_task(operation())
        try:
            await asyncio.wait_for(entered.wait(), 2)
            await asyncio.wait_for(blocked.wait(), 2)
            task.cancel()
            with pytest.raises(TimeoutError):
                await asyncio.wait_for(asyncio.shield(task), 0.05)
            release.set()
            with pytest.raises(asyncio.CancelledError):
                await task
        finally:
            release.set()
            await asyncio.gather(task, return_exceptions=True)
    assert len(opened) == 1 and opened[0].closed
    assert [json.loads(line) for line in path.read_text().splitlines()] == [{"sequence": 1}, {"sequence": 2}]


@pytest.mark.parametrize("limit", ["records", "bytes"])
async def test_event_log_rejects_overflow_and_drains_admitted_records(tmp_path, monkeypatch, limit):
    path = tmp_path / "events.jsonl"
    release = threading.Event()
    original_open = Path.open

    class Handle:
        def __init__(self, handle):
            self.handle = handle

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return self.handle.__exit__(*args)

        def write(self, line):
            assert release.wait(5), "test writer was not released"
            return self.handle.write(line)

        def flush(self):
            self.handle.flush()

    with monkeypatch.context() as patches:
        patches.setattr(Path, "open", lambda path, *args, **kwargs: Handle(original_open(path, *args, **kwargs)))
        with pytest.raises(EventLogError, match="512 records or 32 MiB"):
            async with event_log(str(path)) as record:
                try:
                    if limit == "records":
                        for sequence in range(512):
                            record({"sequence": sequence})
                        record({"sequence": 512})
                    else:
                        record({"sequence": 0})
                        record({"payload": "x" * (32 * 1024 * 1024)})
                finally:
                    release.set()
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    assert rows == [{"sequence": sequence} for sequence in range(512 if limit == "records" else 1)]


async def test_event_log_write_failure_stops_the_owner_with_an_actionable_error(tmp_path, monkeypatch):
    path = tmp_path / "events.jsonl"
    closed = []

    class FailingFile:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            closed.append(True)

        def write(self, line):
            raise OSError("fixture disk write failure")

    monkeypatch.setattr(Path, "open", lambda *args, **kwargs: FailingFile())
    with pytest.raises(EventLogError, match="Cannot write event log.*fixture disk write failure"):
        async with event_log(str(path)) as record:
            record({"sequence": 1})
            await asyncio.Event().wait()
    assert closed == [True]


async def test_upload_io_leaves_the_loop_and_closes_a_partially_consumed_body(tmp_path, monkeypatch):
    path = tmp_path / "file.bin"
    payload = b"fixture" * 200_000
    path.write_bytes(payload)
    loop_thread = threading.get_ident()
    opened = []
    original_open = Path.open
    original_stat = Path.stat

    def open_file(path, *args, **kwargs):
        assert threading.get_ident() != loop_thread, "upload file opened on the event loop"
        handle = original_open(path, *args, **kwargs)
        opened.append(handle)
        return handle

    def stat_file(path, *args, **kwargs):
        assert threading.get_ident() != loop_thread, "upload stat ran on the event loop"
        return original_stat(path, *args, **kwargs)

    class Client:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            pass

        async def put(self, url, *, params, headers, content):
            assert headers["Content-Length"] == str(len(payload))
            assert headers[probes.UPLOAD_LENGTH_HEADER] == str(len(payload))
            assert headers[probes.UPLOAD_SHA256_HEADER] == hashlib.sha256(payload).hexdigest()
            assert await anext(content) == payload[:1 << 20]
            return httpx.Response(400, json={"error": "fixture rejection"})

    config = GatewayConfig("127.0.0.1", 1, "synthetic", "ws")
    with monkeypatch.context() as patches:
        patches.setattr(Path, "open", open_file)
        patches.setattr(Path, "stat", stat_file)
        patches.setattr(GatewayConfig, "http_client", lambda cfg, timeout: Client())
        with pytest.raises(RuntimeError, match="fixture rejection"):
            await probes._upload_file(config, path, path.name, timeout_s=1)
    assert len(opened) == 2 and all(handle.closed for handle in opened)


async def test_buffered_completion_cannot_hide_an_event_log_admission_failure(tmp_path, monkeypatch):
    path = tmp_path / "events.jsonl"
    config = GatewayConfig("127.0.0.1", 1, "synthetic", "ws")
    overflow = asyncio.Event()
    buffered_completion = []
    release = threading.Event()
    original_open = Path.open

    class Socket:
        def __init__(self):
            self.frames = asyncio.Queue()

        async def recv(self):
            return await self.frames.get()

        async def send(self, raw):
            request = json.loads(raw)
            result = {"thread": {"id": "exact-thread"}} if request["method"] == "thread/start" else {"turn": {"id": "exact-turn"}}
            self.frames.put_nowait(json.dumps({"id": request["id"], "result": result}))

    socket = Socket()

    class Handle:
        def __init__(self, handle):
            self.handle = handle

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return self.handle.__exit__(*args)

        def write(self, line):
            assert release.wait(5), "test writer was not released"
            return self.handle.write(line)

        def flush(self):
            self.handle.flush()

    @asynccontextmanager
    async def connection(cfg, timeout_s, record):
        yield socket, {"method": "daemon/ready"}

    @asynccontextmanager
    async def log_boundary(path):
        async with event_log(path) as record:
            def callback(message):
                try:
                    record(message)
                except EventLogError:
                    buffered_completion.append(any(frame[0].get("method") == "turn/completed"
                                                   for frame in gateway_cli._reader(socket).frames))
                    overflow.set()
                    raise
                if message.get("type") == "turn.started":
                    socket.frames.put_nowait(json.dumps({"method": "turn/completed", "params": {
                        "threadId": "exact-thread", "turn": {"id": "exact-turn", "status": "completed"}}}))
                    for sequence in range(512):
                        socket.frames.put_nowait(json.dumps({"method": "fixture/notification", "params": {"sequence": sequence}}))
            yield callback

    args = gateway_cli.build_parser().parse_args(["turn", "--prompt", "fixture", "--event-log", str(path)])
    with monkeypatch.context() as patches:
        patches.setattr(gateway_cli, "_resolve_config", lambda args: config)
        patches.setattr(gateway_cli, "_turn_connection", connection)
        patches.setattr(gateway_cli, "event_log", log_boundary)
        patches.setattr(Path, "open", lambda path, *args, **kwargs: Handle(original_open(path, *args, **kwargs)))
        task = asyncio.create_task(gateway_cli.cmd_turn(args))
        try:
            await asyncio.wait_for(overflow.wait(), 2)
            reader = gateway_cli._reader(socket)
            assert isinstance(reader.failure, EventLogError)
            assert buffered_completion == [True]
            release.set()
            with pytest.raises(EventLogError, match="cannot keep up"):
                await task
        finally:
            release.set()
            await asyncio.gather(task, return_exceptions=True)
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    assert len(rows) == 512
    assert any(row.get("method") == "turn/completed" for row in rows)
