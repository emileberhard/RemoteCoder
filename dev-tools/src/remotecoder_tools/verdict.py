import sys
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager


class ProbeCleanupError(RuntimeError):
    pass


@asynccontextmanager
async def cleanup_after(step: str, release: Callable[[], Awaitable[None]]) -> AsyncIterator[None]:
    try:
        yield
    except BaseException:
        try:
            await release()
        except Exception as exc:
            print(f"FAIL {step}: {exc}", file=sys.stderr)
        raise
    try:
        await release()
    except Exception as exc:
        print(f"FAIL {step}: {exc}", file=sys.stderr)
        raise ProbeCleanupError(f"{step} failed: {exc}") from exc
