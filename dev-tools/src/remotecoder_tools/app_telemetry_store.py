import gzip
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import zlib
from collections.abc import Iterable, Iterator
from concurrent.futures import FIRST_COMPLETED, Future, ProcessPoolExecutor, wait
from dataclasses import dataclass
from pathlib import Path
from typing import IO

from .app_telemetry_summary import summarize_segment
from .config import _matches_local_identity

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
import maintainer_config  # noqa: E402

APP_LOG_DIRECTORY = "Library/Logs/remote-coder/app-logs"
RETENTION_MARKER = "retention.json"
LISTING_SEPARATOR = "--retention--"
INDEX_ROOT = Path.home() / "Library/Caches/RemoteCoder/app-telemetry/index"
INDEX_VERSION = 1
INDEX_BYTE_CAP = 256 * 1024 * 1024
LOCAL = "local"
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5",
       "-o", "ServerAliveCountMax=3"]
LIST_TIMEOUT_SECONDS = 20
FETCH_TIMEOUT_SECONDS = 600
PARSE_WORKERS = 4
OUTSTANDING_SEGMENTS = 2 * PARSE_WORKERS
STALE_TEMPORARY_SECONDS = 3600
EXPANDED_SEGMENT_BYTE_CAP = 50 * 1024 * 1024


@dataclass(frozen=True)
class Segment:
    host: str
    device: str
    name: str
    size: int
    mtime: int

    @property
    def stamp_ms(self) -> int | None:
        parts = self.name.split("-")
        return int(parts[1]) if len(parts) > 2 and parts[1].isdigit() else None

    @property
    def kind(self) -> str:
        if "-mk-" in self.name:
            return "metrickit"
        return "telemetry" if self.name.endswith("-telemetry") else "logs"

    @property
    def index_path(self) -> Path:
        return INDEX_ROOT / host_key(self.host) / self.device / f"{self.name}.json"


@dataclass(frozen=True)
class StoreListing:
    host: str
    segments: tuple[Segment, ...] | None
    error: str | None
    retention: dict | None = None


def _retention(text: str) -> dict | None:
    try:
        marker = json.loads(text)
    except ValueError:
        return None
    return marker if isinstance(marker, dict) else None


def host_key(host: str) -> str:
    return "".join(character if character.isalnum() or character in ".-_" else "_" for character in host)


def configured_hosts() -> list[str]:
    release = maintainer_config.load().get("releaseConfig", {})
    hosts = [LOCAL]
    for field in ("macMiniHostname", "macBookHostname"):
        if isinstance(name := release.get(field), str) and name and not _matches_local_identity(name):
            hosts.append(_tailnet_host_name(name))
    return hosts


def _tailnet_host_name(address: str) -> str:
    try:
        result = subprocess.run(["tailscale", "status", "--json"], stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, timeout=5, check=True)
        peers = json.loads(result.stdout).get("Peer") or {}
    except (OSError, subprocess.SubprocessError, ValueError):
        return address
    wanted = address.casefold().removesuffix(".")
    for peer in peers.values():
        names = [*(peer.get("TailscaleIPs") or []), str(peer.get("DNSName", "")).removesuffix(".")]
        if wanted in (name.casefold() for name in names) and peer.get("HostName"):
            return peer["HostName"]
    return address


def list_store(host: str) -> StoreListing:
    if host == LOCAL:
        root = Path.home() / APP_LOG_DIRECTORY
        if not root.is_dir():
            return StoreListing(host, None, f"{root} does not exist")
        segments = []
        for device in sorted(entry for entry in root.iterdir() if entry.is_dir()):
            for file in device.iterdir():
                if file.name.endswith(".jsonl.gz") and file.is_file():
                    status = file.stat()
                    segments.append(Segment(host, device.name, file.name.removesuffix(".jsonl.gz"),
                                            status.st_size, int(status.st_mtime)))
        marker = root / RETENTION_MARKER
        return StoreListing(host, tuple(segments), None, _retention(marker.read_text()) if marker.is_file() else None)
    command = (
        f'cd "$HOME/{APP_LOG_DIRECTORY}" || exit 3; '
        "find . -mindepth 2 -maxdepth 2 -type f -name '*.jsonl.gz' -exec stat -f '%z %m %N' {} + || exit 4; "
        f"echo {LISTING_SEPARATOR}; cat {RETENTION_MARKER} 2>/dev/null; exit 0"
    )
    try:
        result = subprocess.run([*SSH, host, command], stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, timeout=LIST_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        return StoreListing(host, None, f"listing timed out after {LIST_TIMEOUT_SECONDS} s")
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit status {result.returncode}"
        return StoreListing(host, None, detail)
    listing, _, marker = result.stdout.partition(f"{LISTING_SEPARATOR}\n")
    segments = []
    for line in listing.splitlines():
        size, mtime, path = line.split(" ", 2)
        _, device, file = path.split("/", 2)
        segments.append(Segment(host, device, file.removesuffix(".jsonl.gz"), int(size), int(mtime)))
    return StoreListing(host, tuple(segments), None, _retention(marker) if marker.strip() else None)


def read_index(segment: Segment) -> dict | None:
    try:
        entry = json.loads(segment.index_path.read_text())
    except (OSError, ValueError):
        return None
    if (entry.get("version"), entry.get("size"), entry.get("mtime")) != (INDEX_VERSION, segment.size, segment.mtime):
        return None
    return entry


def write_index(segment: Segment, summary: dict) -> dict:
    entry = {"version": INDEX_VERSION, "size": segment.size, "mtime": segment.mtime, **summary}
    path = segment.index_path
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=f".{path.name}.", suffix=".tmp",
                                     delete=False) as temporary:
        temporary.write(json.dumps(entry, separators=(",", ":")))
    os.replace(temporary.name, path)
    return entry


class UnreadableSegment(Exception):
    pass


def _bounded_lines(stream: IO[bytes]) -> Iterator[bytes]:
    remaining = EXPANDED_SEGMENT_BYTE_CAP
    while line := stream.readline(remaining + 1):
        remaining -= len(line)
        if remaining < 0:
            raise UnreadableSegment(f"expands beyond {EXPANDED_SEGMENT_BYTE_CAP} bytes")
        yield line


def _summarize(stream: IO[bytes]) -> dict:
    try:
        return summarize_segment(_bounded_lines(stream))
    except (UnreadableSegment, gzip.BadGzipFile, EOFError, zlib.error) as error:
        return {"unreadable": f"{type(error).__name__}: {error}"}


def _summarize_bytes(compressed: bytes) -> dict:
    with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
        return _summarize(stream)


def _summarize_file(path: str) -> dict:
    with gzip.open(path, "rb") as stream:
        return _summarize(stream)


def _remote_members(host: str, segments: list[Segment]) -> Iterator[tuple[str, bytes]]:
    names = "\n".join(f"{segment.device}/{segment.name}.jsonl.gz" for segment in segments)
    command = f'cd "$HOME/{APP_LOG_DIRECTORY}" && tar -cf - -T -'
    process = subprocess.Popen([*SSH, host, command], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    assert process.stdin is not None and process.stdout is not None
    expired = threading.Event()

    def expire() -> None:
        expired.set()
        process.kill()

    deadline = threading.Timer(FETCH_TIMEOUT_SECONDS, expire)
    deadline.start()
    try:
        process.stdin.write(names.encode())
        process.stdin.close()
        with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
            for member in archive:
                if member.isfile() and (stream := archive.extractfile(member)) is not None:
                    yield member.name, stream.read()
        process.wait()
    except (OSError, EOFError, tarfile.TarError) as error:
        if expired.is_set():
            raise RuntimeError(f"fetching segments from {host} exceeded {FETCH_TIMEOUT_SECONDS} s") from error
        raise
    finally:
        deadline.cancel()
        if process.poll() is None:
            process.kill()
            process.wait()
    if expired.is_set():
        raise RuntimeError(f"fetching segments from {host} exceeded {FETCH_TIMEOUT_SECONDS} s")
    if process.returncode != 0:
        detail = process.stderr.read().decode(errors="replace").strip() if process.stderr else ""
        raise RuntimeError(f"fetching segments from {host} failed: {detail or process.returncode}")


def _index_remote(pool: ProcessPoolExecutor, host: str, pending: list[Segment], entries: dict[Segment, dict]) -> None:
    by_member = {f"{segment.device}/{segment.name}.jsonl.gz": segment for segment in pending}
    running: dict[Future, Segment] = {}

    def publish(done: Iterable[Future]) -> None:
        for future in done:
            segment = running.pop(future)
            entries[segment] = write_index(segment, future.result())

    for member, body in _remote_members(host, pending):
        if (segment := by_member.get(member.removeprefix("./"))) is not None:
            running[pool.submit(_summarize_bytes, body)] = segment
        if len(running) >= OUTSTANDING_SEGMENTS:
            publish(wait(running, return_when=FIRST_COMPLETED).done)
    publish(wait(running).done)


def indexed(segments: Iterable[Segment]) -> tuple[list[tuple[Segment, dict]], dict[str, str]]:
    wanted = list(segments)
    entries: dict[Segment, dict] = {}
    missing: dict[str, list[Segment]] = {}
    failures: dict[str, str] = {}
    for segment in wanted:
        if (entry := read_index(segment)) is not None:
            entries[segment] = entry
        else:
            missing.setdefault(segment.host, []).append(segment)
    if missing:
        with ProcessPoolExecutor(max_workers=PARSE_WORKERS) as pool:
            for host, pending in missing.items():
                try:
                    if host == LOCAL:
                        root = Path.home() / APP_LOG_DIRECTORY
                        paths = [str(root / segment.device / f"{segment.name}.jsonl.gz") for segment in pending]
                        summaries = pool.map(_summarize_file, paths, chunksize=16)
                        for segment, summary in zip(pending, summaries, strict=True):
                            entries[segment] = write_index(segment, summary)
                        continue
                    _index_remote(pool, host, pending, entries)
                except (OSError, EOFError, RuntimeError, tarfile.TarError, subprocess.SubprocessError) as error:
                    failures[host] = f"{type(error).__name__}: {error}"
    return [(segment, entries[segment]) for segment in wanted if segment in entries], failures


@dataclass(frozen=True)
class Reclaimed:
    stale_entries: int
    evicted_entries: int
    index_bytes: int
    cap_bytes: int


def reclaim_index(listings: Iterable[StoreListing]) -> Reclaimed:
    stale = 0
    for listing in listings:
        if listing.segments is None:
            continue
        live = {(segment.device, f"{segment.name}.json"): segment for segment in listing.segments}
        host_root = INDEX_ROOT / host_key(listing.host)
        if not host_root.is_dir():
            continue
        for device in host_root.iterdir():
            if device.is_dir() and not any(key[0] == device.name for key in live):
                stale += sum(1 for _ in device.glob("*.json"))
                shutil.rmtree(device, ignore_errors=True)
                continue
            for file in device.glob("*.json"):
                segment = live.get((device.name, file.name))
                if segment is None:
                    file.unlink(missing_ok=True)
                    stale += 1
    cutoff = time.time() - STALE_TEMPORARY_SECONDS
    for temporary in INDEX_ROOT.glob("*/*/.*.tmp") if INDEX_ROOT.is_dir() else ():
        try:
            if temporary.stat().st_mtime < cutoff:
                temporary.unlink(missing_ok=True)
        except FileNotFoundError:
            continue
    files = sorted(INDEX_ROOT.glob("*/*/*.json"), key=lambda path: path.name) if INDEX_ROOT.is_dir() else []
    sizes = {}
    for file in files:
        try:
            sizes[file] = file.stat().st_size
        except FileNotFoundError:
            continue
    files = [file for file in files if file in sizes]
    total = sum(sizes.values())
    evicted = 0
    for file in files:
        if total <= INDEX_BYTE_CAP:
            break
        file.unlink(missing_ok=True)
        total -= sizes[file]
        evicted += 1
    return Reclaimed(stale, evicted, total, INDEX_BYTE_CAP)
