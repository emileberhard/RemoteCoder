import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

from . import app_telemetry_store as store
from .app_telemetry_summary import tree_roots

sys.path.insert(0, str(store.ROOT / "scripts"))
from symbols import DEVICE_SUPPORT_ROOT, atos, symbol_files  # noqa: E402

ATOS_WORKERS = 8
PROFILE_ROWS = 15
INSTRUCTION_OFFSET = re.compile(r" \+ \d+$")
NO_SYMBOLS = "no retained dSYM or DeviceSupport symbols match this UUID"


@dataclass(frozen=True)
class Capture:
    tree: dict
    build: str
    source: dict


@dataclass
class Symbols:
    lookup: dict = field(default_factory=dict)
    missing: list = field(default_factory=list)
    binaries: int = 0
    frames: int = 0
    unsymbolicated_frames: int = 0

    def summary(self) -> dict:
        return {"symbolicatedBinaries": self.binaries, "frames": self.frames,
                "unsymbolicatedFrames": self.unsymbolicated_frames, "missingSymbols": self.missing}


def all_frames(tree: dict) -> Iterator[dict]:
    stack = [frame for thread in tree.get("callStackThreads", []) for frame in thread.get("rootFrames", [])]
    while stack:
        frame = stack.pop()
        yield frame
        stack.extend(frame.get("subFrames") or [])


def _usable(frame: dict) -> bool:
    return (isinstance(frame.get("binaryUUID"), str) and isinstance(frame.get("address"), int)
            and isinstance(frame.get("offsetIntoBinaryTextSegment"), int))


def load_bases(tree: dict) -> dict[str, int]:
    differences: defaultdict[str, Counter] = defaultdict(Counter)
    for frame in all_frames(tree):
        if _usable(frame):
            differences[frame["binaryUUID"]][frame["address"] - frame["offsetIntoBinaryTextSegment"]] += 1
    return {uuid: counts.most_common(1)[0][0] for uuid, counts in differences.items()}


def _system_candidates(names: set[str], sources: list[dict]) -> list[Path]:
    candidates = []
    for source in sources:
        pattern = f"{source.get('deviceType')} {source.get('osVersion')} ({source.get('osBuild')})/*/Symbols"
        for root in (Path.home() / DEVICE_SUPPORT_ROOT).glob(pattern):
            candidates += [Path(directory) / name for directory, _, files in os.walk(root)
                           for name in files if name in names]
    return candidates


def _atos_batch(file, uuid: str, base: int, offsets: list[int]) -> tuple[str, int, list | str]:
    try:
        return uuid, base, atos(file, base, [base + offset for offset in offsets])
    except (subprocess.SubprocessError, RuntimeError, OSError) as error:
        return uuid, base, f"{type(error).__name__}: {error}"


def symbolicate(captures: list[Capture]) -> Symbols:
    wanted: defaultdict[tuple[str, int], set[int]] = defaultdict(set)
    names: dict[str, str | None] = {}
    builds: defaultdict[str, set[str]] = defaultdict(set)
    frames: Counter = Counter()
    for capture in captures:
        binaries = {binary.get("uuid"): binary.get("name") for binary in capture.tree.get("binaryInfo", [])}
        bases = load_bases(capture.tree)
        for frame in all_frames(capture.tree):
            if not _usable(frame):
                continue
            uuid = frame["binaryUUID"]
            wanted[(uuid, bases[uuid])].add(frame["offsetIntoBinaryTextSegment"])
            names.setdefault(uuid, binaries.get(uuid))
            builds[uuid].add(capture.build)
            frames[uuid] += 1
    sources = [dict(item) for item in {tuple(sorted(capture.source.items())) for capture in captures}]
    files = symbol_files([], _system_candidates({name for name in names.values() if name}, sources))
    result = Symbols(frames=sum(frames.values()))
    failures: dict[str, str] = {}
    batches = [(files[uuid], uuid, base, sorted(offsets)) for (uuid, base), offsets in sorted(wanted.items())
               if uuid in files]
    if batches:
        with ThreadPoolExecutor(max_workers=min(ATOS_WORKERS, len(batches))) as pool:
            for uuid, base, answer in pool.map(lambda batch: _atos_batch(*batch), batches):
                if isinstance(answer, str):
                    failures[uuid] = answer
                    continue
                offsets = sorted(wanted[(uuid, base)])
                for offset, symbols in zip(offsets, answer, strict=True):
                    result.lookup[(uuid, base, offset)] = symbols
    resolved = {uuid for uuid, _, _ in result.lookup} - failures.keys()
    result.binaries = len(resolved)
    for uuid in sorted(names, key=lambda uuid: (names[uuid] or "", uuid)):
        if uuid in resolved:
            continue
        result.unsymbolicated_frames += frames[uuid]
        result.missing.append({"binary": names[uuid], "uuid": uuid, "builds": sorted(builds[uuid]),
                               "frames": frames[uuid], "reason": failures.get(uuid, NO_SYMBOLS)})
    return result


def annotate_heaviest(stack: list[dict], tree: dict, symbols: Symbols) -> None:
    bases = load_bases(tree)
    for frame in stack:
        base = bases.get(frame.get("uuid"))
        if base is not None and isinstance(frame.get("offset"), int):
            if found := symbols.lookup.get((frame["uuid"], base, frame["offset"])):
                frame["symbols"] = list(found)


def _function(symbol: str) -> str:
    return INSTRUCTION_OFFSET.sub("", symbol)


def profile(tree: dict, symbols: Symbols) -> dict:
    binaries = {binary.get("uuid"): binary.get("name") for binary in tree.get("binaryInfo", [])}
    bases = load_bases(tree)
    inclusive: Counter = Counter()
    own: Counter = Counter()
    where: dict[str, str | None] = {}
    innermost_first = bool(tree.get("callStackPerThread"))
    stack = [(frame, frozenset()) for frame in tree_roots(tree)]
    while stack:
        frame, path = stack.pop()
        uuid, offset = frame.get("binaryUUID"), frame.get("offsetIntoBinaryTextSegment")
        found = symbols.lookup.get((uuid, bases.get(uuid), offset))
        name = _function(found[0]) if found else f"{binaries.get(uuid) or uuid}+0x{offset:x}" if isinstance(offset, int) else "?"
        count = int(frame.get("sampleCount") or 0)
        children = frame.get("subFrames") or []
        where.setdefault(name, binaries.get(uuid))
        if name not in path:
            inclusive[name] += count
        if not innermost_first:
            own[name] += max(0, count - sum(int(child.get("sampleCount") or 0) for child in children))
        elif not path:
            own[name] += count
        stack.extend((child, path | {name}) for child in children)

    def rows(counter: Counter) -> list[dict]:
        return [{"symbol": name, "binary": where[name], "inclusiveSamples": inclusive[name], "selfSamples": own[name]}
                for name, count in counter.most_common(PROFILE_ROWS) if count]

    return {"byInclusiveSamples": rows(inclusive), "bySelfSamples": rows(own)}
