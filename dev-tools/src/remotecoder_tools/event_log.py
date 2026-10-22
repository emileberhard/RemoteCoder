import asyncio
import queue
import threading
from contextlib import asynccontextmanager
from pathlib import Path

from .file_io import finish_thread_io
from .rpc import _json


class EventLogError(RuntimeError):
    pass


class _EventLogWriter:
    def __init__(self, path: str) -> None:
        self.path = path
        self.loop = asyncio.get_running_loop()
        self.ready = self.loop.create_future()
        self.queue: queue.Queue[str | None] = queue.Queue(maxsize=513)
        self.lock = threading.Lock()
        self.closed = False
        self.pending_records = 0
        self.pending_bytes = 0
        self.failure: EventLogError | None = None

    def record(self, message: dict) -> None:
        line = _json(message) + "\n"
        with self.lock:
            if self.failure is not None:
                raise self.failure
            if self.closed:
                raise EventLogError("Event log admission is closed")
            if self.pending_records >= 512 or self.pending_bytes + len(line) > 32 * 1024 * 1024:
                self.failure = EventLogError("Event log cannot keep up: pending evidence exceeds 512 records or 32 MiB; use a faster log destination")
                raise self.failure
            self.pending_records += 1
            self.pending_bytes += len(line)
            self.queue.put_nowait(line)

    def close(self) -> None:
        with self.lock:
            if not self.closed:
                self.closed = True
                self.queue.put_nowait(None)

    def signal_ready(self) -> None:
        if not self.ready.done():
            self.ready.set_result(None)

    def write(self) -> None:
        try:
            path = Path(self.path).expanduser()
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("w", encoding="utf-8") as handle:
                self.loop.call_soon_threadsafe(self.signal_ready)
                while (line := self.queue.get()) is not None:
                    handle.write(line)
                    handle.flush()
                    with self.lock:
                        self.pending_records -= 1
                        self.pending_bytes -= len(line)
        except OSError as error:
            with self.lock:
                self.failure = EventLogError(f"Cannot write event log {self.path}: {error}")
            raise self.failure from error
        finally:
            self.loop.call_soon_threadsafe(self.signal_ready)


def _ignore_record(message: dict) -> None:
    pass


@asynccontextmanager
async def event_log(path: str | None):
    if not path:
        yield _ignore_record
        return
    writer = _EventLogWriter(path)
    try:
        async with asyncio.TaskGroup() as group:
            group.create_task(finish_thread_io(writer.write))
            try:
                await writer.ready
                if writer.failure is not None:
                    raise writer.failure
                yield writer.record
            finally:
                writer.close()
        if writer.failure is not None:
            raise writer.failure
    except BaseExceptionGroup as error:
        if writer.failure is not None:
            raise writer.failure from None
        if len(error.exceptions) == 1:
            raise error.exceptions[0] from None
        raise
