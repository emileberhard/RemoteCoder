import asyncio
import json
from pathlib import Path


async def finish_thread_io(operation, *args, **kwargs):
    task = asyncio.create_task(asyncio.to_thread(operation, *args, **kwargs))
    try:
        return await asyncio.shield(task)
    except asyncio.CancelledError:
        while not task.done():
            try:
                await asyncio.shield(task)
            except asyncio.CancelledError:
                continue
        task.result()
        raise


def file_chunks(path: Path):
    with path.open("rb") as handle:
        while chunk := handle.read(1 << 20):
            yield chunk


def write_receipt(raw_path: str, value: dict) -> None:
    path = Path(raw_path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
