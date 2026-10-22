import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True, slots=True)
class SampleFrame:
    name: str
    module: str

    @property
    def symbol(self) -> str:
        return f"{self.name} [{self.module}]"


@dataclass(frozen=True, slots=True)
class SampleStack:
    frames: tuple[SampleFrame, ...]
    samples: int

    @property
    def idle(self) -> bool:
        return self.frames[-1].name in IDLE_FRAMES and any(
            frame.name == "__CFRunLoopServiceMachPort" for frame in self.frames
        )


@dataclass(frozen=True, slots=True)
class Sample:
    main_samples: int
    interval_ms: float | None
    stacks: list[SampleStack]


@dataclass(slots=True)
class PendingFrame:
    depth: int
    frame: SampleFrame
    samples: int
    child_samples: int = 0


@dataclass(slots=True)
class CountTree:
    samples: int = 0
    children: dict[str, CountTree] = field(default_factory=dict)

    def add(self, names: list[str], samples: int) -> None:
        node = self
        node.samples += samples
        for name in names:
            node = node.children.setdefault(name, CountTree())
            node.samples += samples

    def rows(self, total: int, denominator: int, share_key: str) -> list[dict]:
        return [
            {"name": name, "samples": node.samples, "mainShare": share(node.samples, total),
             share_key: share(node.samples, denominator), "children": node.rows(total, denominator, share_key)}
            for name, node in sorted(self.children.items(), key=lambda pair: (-pair[1].samples, pair[0]))
        ]


SAMPLE_LINE = re.compile(r"^([\s+!:|]*)(\d+) (.+)$")
SAMPLE_MODULE = re.compile(r"^(.*?)  \(in ([^)]+)\)")
SAMPLE_INTERVAL = re.compile(r"every ([\d.]+) milliseconds?\b")
IDLE_FRAMES = {"mach_msg2_trap", "mach_msg2_internal", "__CFRunLoopServiceMachPort", "mach_msg_overwrite", "mach_msg"}
CATEGORY_RULES = [
    ("", "displayCycle", "root", r"NSDisplayCycle"),
    ("", "eventDispatch", "root", r"(?:NSApplication|NSWindow).* (?:_reallySendEvent|sendEvent):|_routeScrollWheelEvent"),
    ("", "swiftuiLayout", "root", r"NSHostingView\.layout\(|ViewGraph\.updateOutputs\("),
    ("", "textLayout", "leaf", r"\[CoreText\]|NSTextLayout|NSLayoutManager|NSCoreTypesetter|NSTypesetter"),
    ("", "swiftuiGraph", "leaf", r"\[AttributeGraph\]"),
    ("", "render", "leaf", r"\[QuartzCore\]|\[CoreGraphics\]"),
    ("", "runLoopSources", "root", r"__CFRunLoopDoSource|__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__|_dispatch_main_queue|swift_job_run|swift::runJob"),
    ("", "appCode/{type}", "leaf", r"\b(?P<type>[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)[.<( ].*\[RemoteCoder\]$"),
    ("", "other", "leaf", r"."),
    ("displayCycle", "cursorHitTest", "root", r"setCursorForMouseLocation:"),
    ("displayCycle", "swiftuiLayout", "root", r"NSHostingView\.layout\(|ViewGraph\.updateOutputs\("),
    ("displayCycle", "constraintLayout", "leaf", r"NSConstraint|NSISEngine|NSView.*[Ll]ayout|_NSViewLayout|UpdateConstraints"),
    ("displayCycle", "render", "leaf", r"\[QuartzCore\]|\[CoreGraphics\]|[Dd]isplayIfNeeded|[Dd]rawRect:"),
    ("displayCycle", "other", "leaf", r"."),
    ("eventDispatch", "hitTest", "leaf", r"[Hh]itTest|containsGlobalPoints"),
    ("eventDispatch", "scrollWheel", "leaf", r"[Ss]crollWheel|_routeScrollWheelEvent"),
    ("eventDispatch", "other", "leaf", r"."),
    ("runLoopSources", "swiftTasks", "leaf", r"swift_job_run|swift::runJob|swift_task_|\[libswift_Concurrency.dylib\]"),
    ("runLoopSources", "mainQueue", "root", r"_dispatch_main_queue|__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__"),
    ("runLoopSources", "other", "leaf", r"."),
]
COMPILED_RULES = [(parent, name, direction, re.compile(pattern)) for parent, name, direction, pattern in CATEGORY_RULES]


def read_sample(path: Path) -> Sample:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    first = next((i for i, line in enumerate(lines) if "com.apple.main-thread" in line or ": Main Thread" in line), None)
    if first is None or (thread := SAMPLE_LINE.match(lines[first])) is None:
        raise ValueError("no main thread in sample")
    total = int(thread[2])
    thread_depth = len(thread[1])
    pending = [PendingFrame(thread_depth, SampleFrame("<unwound>", "?"), total)]
    stacks = []

    def close() -> None:
        entry = pending.pop()
        count = entry.samples - entry.child_samples
        if count < 0:
            raise ValueError(f"sample child counts exceed parent: {entry.frame.symbol}")
        if count:
            frames = tuple(item.frame for item in pending[1:]) + (entry.frame,)
            stacks.append(SampleStack(frames, count))

    for line in lines[first + 1:]:
        match = SAMPLE_LINE.match(line)
        if match is None:
            if line.strip():
                raise ValueError(f"unrecognized main-thread sample line: {line.strip()[:160]}")
            break
        depth, count = len(match[1]), int(match[2])
        if depth <= thread_depth:
            break
        while pending[-1].depth >= depth:
            close()
        if module := SAMPLE_MODULE.match(match[3]):
            frame = SampleFrame(module[1].strip(), module[2])
        else:
            frame = SampleFrame(re.split(r" \+ \d+|  \[", match[3])[0].strip(), "?")
        pending[-1].child_samples += count
        pending.append(PendingFrame(depth, frame, count))
    while pending:
        close()
    interval = next((match for line in lines[:first] if (match := SAMPLE_INTERVAL.search(line))), None)
    return Sample(total, float(interval[1]) if interval else None, stacks)


def category_path(frames: tuple[SampleFrame, ...]) -> list[str]:
    path = []
    parent = ""
    while True:
        for scope, name, direction, pattern in COMPILED_RULES:
            if scope != parent:
                continue
            ordered = range(len(frames)) if direction == "root" else reversed(range(len(frames)))
            found = next(((i, match) for i in ordered if (match := pattern.search(frames[i].symbol))), None)
            if found:
                index, match = found
                frames = frames[index:]
                path.extend(name.format(**match.groupdict()).split("/"))
                parent = "/".join(path)
                break
        else:
            return path


def share(samples: int, total: int) -> float | None:
    return samples / total if total else None


def summarize_sample(path: Path, top: int = 40) -> dict:
    try:
        sample = read_sample(path)
    except ValueError as error:
        return {"error": str(error)}
    return summarize_stacks(sample, top)


def summarize_stacks(sample: Sample, top: int) -> dict:
    self_counts = Counter()
    inclusive = Counter()
    busy_inclusive = Counter()
    categories = CountTree()
    categories.children["other"] = CountTree()
    idle = 0
    for stack in sample.stacks:
        self_counts[stack.frames[-1].symbol] += stack.samples
        symbols = {frame.symbol for frame in stack.frames}
        for symbol in symbols:
            inclusive[symbol] += stack.samples
        if stack.idle:
            idle += stack.samples
        else:
            categories.add(category_path(stack.frames), stack.samples)
            for symbol in symbols:
                busy_inclusive[symbol] += stack.samples
    busy = sample.main_samples - idle
    app = {symbol: count for symbol, count in inclusive.items() if symbol.endswith(" [RemoteCoder]")}

    def ranked(counts: dict[str, int]) -> list[list]:
        return [[symbol, count] for symbol, count in sorted(counts.items(), key=lambda pair: (-pair[1], pair[0]))[:top]]

    return {
        "mainSamples": sample.main_samples, "idleSamples": idle, "busySamples": busy,
        "busyShare": share(busy, sample.main_samples), "intervalMs": sample.interval_ms,
        "categories": categories.rows(sample.main_samples, busy, "busyShare"),
        "selfTop": ranked(self_counts), "inclusiveTop": ranked(inclusive), "appInclusiveTop": ranked(app),
        "appFrames": [
            {"symbol": symbol, "samples": count, "mainShare": share(count, sample.main_samples),
             "busySamples": busy_inclusive[symbol], "busyShare": share(busy_inclusive[symbol], busy)}
            for symbol, count in ranked(app)
        ],
    }


def focus_sample(sample: Sample, pattern: re.Pattern, depth: int) -> dict:
    callers, callees = CountTree(), CountTree()
    matched = 0
    self_samples = 0
    for stack in sample.stacks:
        index = next((i for i, frame in enumerate(stack.frames) if pattern.search(frame.symbol)), None)
        if index is None:
            continue
        matched += stack.samples
        if index == len(stack.frames) - 1:
            self_samples += stack.samples
        callers.add([frame.symbol for frame in reversed(stack.frames[max(0, index - depth):index])], stack.samples)
        callees.add([frame.symbol for frame in stack.frames[index + 1:index + 1 + depth]], stack.samples)
    return {
        "samples": matched, "mainShare": share(matched, sample.main_samples), "selfSamples": self_samples,
        "callers": callers.rows(sample.main_samples, matched, "focusShare"), "callees": callees.rows(sample.main_samples, matched, "focusShare"),
    }
