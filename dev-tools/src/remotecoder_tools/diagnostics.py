import argparse
import asyncio
import collections
import datetime
import json
import shlex
import subprocess
import sys
import time
from typing import Any

from .config import _gateway_read_host, _resolve_config
from .rpc import (
    _drain_ready,
    _event_thread_id,
    _initialize,
    _timed_rpc,
    _ws_connect,
    _ws_recv_json,
)
from .turns import _assert_e2e, _norm_turn_id, mark_purpose, release_claude_runtime
from .verdict import cleanup_after


DEFAULT_JOURNAL_DIR = "~/Library/Logs/remote-coder/journal"


DEFAULT_DESKTOP_DIR = "~/Library/Logs/remote-coder/desktop"


def _parse_since(value: str) -> float:
    """A duration like `90s`, `30m`, `6h`, `3d`, or an ISO-8601 timestamp."""
    text = value.strip()
    units = {"s": 1.0, "m": 60.0, "h": 3600.0, "d": 86400.0}
    if text and text[-1] in units:
        try:
            return time.time() - float(text[:-1]) * units[text[-1]]
        except ValueError:
            pass
    try:
        stamp = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as exc:
        raise SystemExit(f"invalid --since {value!r}: use 30m/6h/3d or an ISO timestamp") from exc
    if stamp.tzinfo is None:
        stamp = stamp.astimezone()
    return stamp.timestamp()


def _journal_day_files(directory: str, since_epoch: float | None) -> list[str]:
    """Day files to read, oldest first. UTC days, matching the gateway."""
    end = datetime.datetime.now(datetime.timezone.utc).date()
    start = (
        datetime.datetime.fromtimestamp(since_epoch, datetime.timezone.utc).date()
        if since_epoch is not None
        else end - datetime.timedelta(days=1)
    )
    days: list[str] = []
    day = start
    while day <= end:
        days.append(f"{directory}/gateway-{day.strftime('%Y%m%d')}.jsonl")
        day += datetime.timedelta(days=1)
    return days


def _journal_quote(path: str) -> str:
    """Quotes a path for `sh -c`, letting a leading `~` expand on the far end."""
    if path.startswith("~/"):
        return '"$HOME/' + path[2:] + '"'
    return shlex.quote(path)


def _journal_shell(args: argparse.Namespace, command: str) -> list[str]:
    host = _gateway_read_host(args)
    if host is None:
        return ["sh", "-c", command]
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, command]


def _journal_matches(record: dict[str, Any], args: argparse.Namespace, since_epoch: float | None) -> bool:
    if args.kind:
        wanted = {k.strip() for part in args.kind for k in part.split(",") if k.strip()}
        if record.get("kind") not in wanted:
            return False
    if getattr(args, "trace", None) and record.get("traceId") != args.trace:
        return False
    if args.method:
        method = record.get("method")
        if not isinstance(method, str) or args.method not in method:
            return False
    if args.thread:
        thread_id = record.get("threadId")
        if not isinstance(thread_id, str) or args.thread not in thread_id:
            return False
    if since_epoch is not None:
        stamp = record.get("ts")
        if isinstance(stamp, str):
            try:
                parsed = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
            except ValueError:
                return True
            if parsed.timestamp() < since_epoch:
                return False
    return True


def _journal_summary(record: dict[str, Any]) -> str:
    stamp = str(record.get("ts", ""))[11:23] or "-"
    kind = record.get("kind", "?")
    thread_id = record.get("threadId") or ""
    turn_id = record.get("turnId") or ""
    where = f" {thread_id}" + (f"/{turn_id}" if turn_id else "") if thread_id else ""
    if kind in {"title", "review"}:
        detail = " ".join(
            f"{key}={record[key]}" for key in
            ("operation", "status", "outcome", "reason", "elapsedMs", "doneProbability", "doneThreshold", "probablyDone")
            if record.get(key) is not None
        )
        if record.get("probabilities") is not None:
            detail += " scores=" + json.dumps(record["probabilities"], separators=(",", ":"))
        return f"{stamp} {kind:<8} {record.get('event', '?')}{where} trace={record.get('traceId', '?')} {detail}".rstrip()
    if kind == "notify":
        clients = record.get("clients")
        client = record.get("clientId")
        target = f"client={client}" if client is not None else f"clients={clients}"
        return f"{stamp} notify   {record.get('source', '?'):<7} {record.get('method', '?')}{where} {target}"
    if kind == "rpc":
        direction = "->" if record.get("direction") == "request" else "<-"
        tail = ""
        if record.get("direction") == "response":
            elapsed = record.get("elapsedMs")
            tail = " ok" if record.get("ok") else " ERROR"
            if isinstance(elapsed, (int, float)):
                tail += f" {elapsed:.0f}ms"
        identifier = f" id={record['id']}" if record.get("id") is not None else ""
        return (
            f"{stamp} rpc {direction}   client={record.get('clientId')} "
            f"{record.get('method', '?')}{identifier}{where}{tail}"
        )
    if kind == "deliver_drop":
        return (
            f"{stamp} DROP     client={record.get('clientId')} "
            f"{record.get('method', '?')}{where} ({record.get('reason')})"
        )
    if kind == "client":
        return (
            f"{stamp} client   {record.get('event')} client={record.get('clientId')} "
            f"connected={record.get('clients')}"
        )
    if kind in ("runtime", "push", "journal_drop", "upload", "speech"):
        fields = {
            key: value
            for key, value in record.items()
            if key not in ("ts", "kind", "event") and value is not None
        }
        rendered = " ".join(
            f"{key}={value if isinstance(value, str) else json.dumps(value)}"
            for key, value in fields.items()
        )
        return f"{stamp} {kind:<8} {record.get('event', '')} {rendered}".rstrip()
    return f"{stamp} {kind} {json.dumps(record, ensure_ascii=True)}"


def _journal_emit(line: str, args: argparse.Namespace, since_epoch: float | None) -> bool:
    stripped = line.strip()
    if not stripped.startswith("{"):
        return False
    try:
        record = json.loads(stripped)
    except json.JSONDecodeError:
        return False
    if not isinstance(record, dict) or not _journal_matches(record, args, since_epoch):
        return False
    print(stripped if args.json else _journal_summary(record))
    return True


def _journal_read(
    args: argparse.Namespace, since_epoch: float | None
) -> list[tuple[str, dict[str, Any]]]:
    """Every journal record in the day files covering `since_epoch`, in order."""
    directory = getattr(args, "journal_dir", DEFAULT_JOURNAL_DIR).rstrip("/")
    files = " ".join(_journal_quote(path) for path in _journal_day_files(directory, since_epoch))
    command = (
        f"if [ ! -d {_journal_quote(directory)} ]; then exit 3; fi; "
        f"for f in {files}; do if [ -e \"$f\" ]; then cat \"$f\" || exit 4; fi; done"
    )
    result = subprocess.run(
        _journal_shell(args, command),
        capture_output=True,
        text=True,
        timeout=15,
    )
    if result.returncode != 0:
        where = (getattr(args, "ssh_host", "") or "this host").strip() or "this host"
        detail = (result.stderr or "").strip() or f"exit status {result.returncode}"
        raise RuntimeError(f"could not read the gateway journal on {where}: {detail}")
    records: list[tuple[str, dict[str, Any]]] = []
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped.startswith("{"):
            continue
        try:
            record = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict):
            records.append((stripped, record))
    return records


async def cmd_e2e_journal_live(args: argparse.Namespace) -> int:
    """Prove a dispatched turn lands in the gateway journal, end to end."""
    cfg = _resolve_config(args)
    started_at = time.time() - 60.0
    request_id = 0

    def next_id() -> int:
        nonlocal request_id
        request_id += 1
        return request_id

    async with await _ws_connect(cfg) as ws:
        _ = await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)

        started, _, _ = await _timed_rpc(
            ws, req_id=next_id(), method="thread/start",
            params={"provider": "claude", "model": args.model, "cwd": args.cwd},
            timeout_s=args.timeout,
        )
        thread_id = str((started.get("thread") or {}).get("id") or "")
        _assert_e2e(bool(thread_id), "thread/start returned no Claude thread id")
        await mark_purpose(ws, next_id=next_id, thread_id=thread_id, purpose="probe", timeout_s=args.timeout)

        async def release() -> None:
            await release_claude_runtime(ws, next_id=next_id, thread_id=thread_id, timeout_s=args.timeout)

        async with cleanup_after("release Claude runtime", release):
            turn, _, _ = await _timed_rpc(
                ws, req_id=next_id(), method="turn/start",
                params={
                    "threadId": thread_id,
                    "input": [{"type": "text", "text": "Reply with only JOURNALED."}],
                    "model": args.model,
                    "cwd": args.cwd,
                },
                timeout_s=args.timeout,
            )
            turn_id = str((turn.get("turn") or {}).get("id") or "")
            _assert_e2e(bool(turn_id), "turn/start returned no Claude turn id")
            status: Any = None
            while status is None:
                message = await _ws_recv_json(ws, timeout_s=args.timeout)
                if _event_thread_id(message) != thread_id or message.get("method") != "turn/completed":
                    continue
                completed = message.get("params", {}).get("turn") or {}
                if _norm_turn_id(completed.get("id")) == _norm_turn_id(turn_id):
                    status = completed.get("status")
            _assert_e2e(status == "completed", f"the turn ended with status {status}")

    # The journal writer is asynchronous by design, so give it a moment to land.
    deadline = time.time() + args.journal_timeout
    missing: list[str] = []
    while time.time() < deadline:
        records = [record for _, record in _journal_read(args, started_at)]
        mine = [record for record in records if record.get("threadId") == thread_id]
        notified = {
            record.get("method")
            for record in mine
            if record.get("kind") == "notify"
            and _norm_turn_id(record.get("turnId")) == _norm_turn_id(turn_id)
        }
        turn_requests = [
            record
            for record in mine
            if record.get("kind") == "rpc"
            and record.get("direction") == "request"
            and record.get("method") == "turn/start"
        ]
        request_keys = {(record.get("clientId"), record.get("id")) for record in turn_requests}
        responses = [
            record
            for record in records
            if record.get("kind") == "rpc"
            and record.get("direction") == "response"
            and record.get("method") == "turn/start"
            and record.get("ok") is True
            and (record.get("clientId"), record.get("id")) in request_keys
        ]
        spawned = [
            record
            for record in mine
            if record.get("kind") == "runtime" and record.get("event") in ("spawn", "stop")
        ]
        missing = []
        if "turn/started" not in notified:
            missing.append("notify turn/started")
        if "turn/completed" not in notified:
            missing.append("notify turn/completed")
        if not turn_requests:
            missing.append("rpc request turn/start")
        if not responses:
            missing.append("rpc response turn/start")
        if not spawned:
            missing.append("runtime lifecycle")
        if not missing:
            payloads = [
                record
                for record in mine
                if record.get("kind") == "notify" and record.get("method") == "turn/started"
            ]
            _assert_e2e(
                any(isinstance(record.get("payload"), dict) for record in payloads),
                "journal notify lines carry no payload",
            )
            print(
                json.dumps(
                    {
                        "ok": True,
                        "threadId": thread_id,
                        "turnId": turn_id,
                        "journalRecordsForThread": len(mine),
                        "notifyMethods": sorted(method for method in notified if method),
                    },
                    indent=2,
                )
            )
            return 0
        await asyncio.sleep(1.0)

    _assert_e2e(False, f"journal never recorded: {', '.join(missing)}")
    return 1


def _desktop_day_files(directory: str, since_epoch: float | None) -> list[str]:
    """Desktop day files to read, oldest first. UTC days, like the gateway's."""
    end = datetime.datetime.now(datetime.timezone.utc).date()
    start = (
        datetime.datetime.fromtimestamp(since_epoch, datetime.timezone.utc).date()
        if since_epoch is not None
        else end - datetime.timedelta(days=1)
    )
    days: list[str] = []
    day = start
    while day <= end:
        days.append(f"{directory}/desktop-{day.strftime('%Y%m%d')}.jsonl")
        day += datetime.timedelta(days=1)
    return days


def _desktop_summary(record: dict[str, Any]) -> str:
    """One line per record, chosen so a decision and its consequences read in
    sequence without opening the raw JSON."""
    stamp = str(record.get("ts", ""))[11:23]
    invocation = str(record.get("invocation", ""))[:8]
    event = str(record.get("event", "")).removeprefix("desktop/")
    trigger = record.get("trigger", "")
    detail = ""
    if event == "started":
        detail = f"host={record.get('host')} pid={record.get('pid')}"
    elif event == "observed":
        detail = f"app={record.get('appPids')}"
        for process in record.get("processes") or []:
            detail += f" [{process.get('pid')}:{process.get('observation')}]"
    elif event == "decision":
        detail = f"reason={record.get('reason')} action={record.get('action')}"
    elif event == "version":
        detail = f"bundled={record.get('bundledCodexVersion')} required={record.get('requiredCodexVersion')}"
    elif event in ("stop", "signal", "stopWait", "stopFailed"):
        detail = " ".join(
            f"{key}={record[key]}"
            for key in (
                "method",
                "authority",
                "targets",
                "pid",
                "outcome",
                "exited",
                "waitedMs",
                "reason",
                "skipped",
                "appPids",
            )
            if key in record
        )
    elif event in ("launchRequest", "launchResult", "stabilized"):
        detail = " ".join(
            f"{key}={record[key]}"
            for key in ("ok", "reason", "appPids", "waitedMs", "consecutiveSuccesses")
            if key in record
        )
    elif event == "finished":
        detail = f"ok={record.get('ok')} durationMs={record.get('durationMs')}"
    if record.get("detail"):
        detail += f" :: {record['detail']}"
    return f"{stamp} {invocation} {record.get('operation', '')}/{trigger} {event:<14} {detail}".rstrip()


# Markers the read shell emits per day file, chosen so they cannot collide with
# JSON. The three states are deliberately distinct: a day the host simply never
# wrote is ordinary, a day file that exists but cannot be read is missing
# coverage, and an absent journal directory means there is no journal at all.


DESKTOP_UNREADABLE_MARKER = "\x1funreadable\x1f"


DESKTOP_ABSENT_MARKER = "\x1fabsent\x1f"


DESKTOP_MISSING_DIR_MARKER = "\x1fnodir\x1f"


def _desktop_read_command(directory: str, paths: list[str]) -> str:
    """The shell that classifies every candidate day file.

    `cat` can still fail after `-r` succeeds — the path may be a directory, or
    the file may be replaced or lose permissions between the test and the read
    — and the loop's exit status only reflects its last iteration, so a later
    success would otherwise hide that failure. Each `cat` is therefore checked
    individually and demoted to unreadable, which keeps the command's own
    nonzero exit reserved for a transport failure.
    """
    listing = " ".join(_journal_quote(path) for path in paths)
    quoted_dir = _journal_quote(directory)
    return (
        f"if [ ! -d {quoted_dir} ] || [ ! -x {quoted_dir} ]; then "
        f"printf '{DESKTOP_MISSING_DIR_MARKER}%s\\n' {quoted_dir}; else "
        f"for f in {listing}; do "
        f'if [ -r "$f" ]; then '
        f'cat "$f" || printf \'{DESKTOP_UNREADABLE_MARKER}%s\\n\' "$f"; '
        f'elif [ -e "$f" ]; then printf \'{DESKTOP_UNREADABLE_MARKER}%s\\n\' "$f"; '
        f'else printf \'{DESKTOP_ABSENT_MARKER}%s\\n\' "$f"; fi; '
        f"done; fi"
    )


def _desktop_read(args: argparse.Namespace, since_epoch: float | None) -> tuple[list[str], list[str]]:
    """Returns the day files' lines and the day files that could not be read.

    A day the host never wrote is normal and reported as nothing; an
    unreachable host, an absent journal directory, and a day file that exists
    but cannot be read are not. The shell always exits 0 and names what it
    found, so a transport failure stays distinguishable from an empty journal.
    """
    directory = args.desktop_dir.rstrip("/")
    paths = _desktop_day_files(directory, since_epoch)
    command = _desktop_read_command(directory, paths)
    result = subprocess.run(
        _journal_shell(args, command),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        where = (getattr(args, "ssh_host", "") or "this host").strip() or "this host"
        detail = (result.stderr or "").strip() or f"exit status {result.returncode}"
        raise SystemExit(f"could not read the desktop journal on {where}: {detail}")

    lines: list[str] = []
    unreadable: list[str] = []
    absent: list[str] = []
    missing_dir: list[str] = []
    for line in result.stdout.splitlines():
        if line.startswith(DESKTOP_UNREADABLE_MARKER):
            unreadable.append(line[len(DESKTOP_UNREADABLE_MARKER) :])
        elif line.startswith(DESKTOP_ABSENT_MARKER):
            absent.append(line[len(DESKTOP_ABSENT_MARKER) :])
        elif line.startswith(DESKTOP_MISSING_DIR_MARKER):
            missing_dir.append(line[len(DESKTOP_MISSING_DIR_MARKER) :])
        else:
            lines.append(line)

    where = (getattr(args, "ssh_host", "") or "this host").strip() or "this host"
    if missing_dir:
        raise SystemExit(
            f"no desktop journal directory on {where}: {', '.join(missing_dir)} "
            "is missing or unreadable"
        )
    present = len(paths) - len(absent)
    if unreadable and len(unreadable) == present:
        raise SystemExit(
            f"no readable desktop journal on {where}: none of "
            f"{', '.join(unreadable)} could be read"
        )
    return lines, unreadable


def _desktop_matches(record: dict[str, Any], args: argparse.Namespace, since_epoch: float | None) -> bool:
    if args.invocation and not str(record.get("invocation", "")).startswith(args.invocation):
        return False
    if args.reason and record.get("reason") != args.reason:
        return False
    if args.event and args.event not in str(record.get("event", "")):
        return False
    if since_epoch is not None:
        stamp = record.get("ts")
        if not isinstance(stamp, str):
            return False
        try:
            parsed = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        except ValueError:
            return False
        if parsed.timestamp() < since_epoch:
            return False
    return True


async def cmd_desktop_journal(args: argparse.Namespace) -> int:
    """Reads the ChatGPT desktop reconciliation journal.

    Every invocation of the shared-Codex launcher records what it observed,
    which reason it chose, and every signal or relaunch that followed, all
    under one `invocation` id. Filter to that id to follow a single decision
    from observation to outcome.

    Exit status separates coverage from content: 0 matched, 1 read cleanly but
    matched nothing, 2 read partially or found corrupt records. A journal that
    could not be read at all is an error, never an empty result.
    """
    since_epoch = _parse_since(args.since) if args.since else None
    lines, unreadable = _desktop_read(args, since_epoch)

    matched: list[tuple[str, dict[str, Any]]] = []
    corrupt = 0
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        try:
            record = json.loads(stripped)
        except json.JSONDecodeError:
            corrupt += 1
            continue
        if not isinstance(record, dict):
            corrupt += 1
            continue
        if _desktop_matches(record, args, since_epoch):
            matched.append((stripped, record))

    if args.last:
        matched = matched[-args.last :]
    for raw, record in matched:
        print(raw if args.json else _desktop_summary(record))

    degraded = False
    if unreadable:
        degraded = True
        print(
            f"warning: {len(unreadable)} day file(s) could not be read, so this view is "
            f"incomplete: {', '.join(unreadable)}",
            file=sys.stderr,
        )
    if corrupt:
        degraded = True
        print(f"warning: skipped {corrupt} unparsable record(s)", file=sys.stderr)
    if not matched:
        print("no matching desktop records", file=sys.stderr)
        return 2 if degraded else 1
    return 2 if degraded else 0


async def cmd_journal(args: argparse.Namespace) -> int:
    """Reads the gateway's observability journal (see AGENTS.md, Observability)."""
    since_epoch = _parse_since(args.since) if args.since else None

    if args.follow:
        directory = args.journal_dir.rstrip("/")
        today = datetime.datetime.now(datetime.timezone.utc).date()
        files = " ".join(
            _journal_quote(
                f"{directory}/gateway-{(today + datetime.timedelta(days=offset)).strftime('%Y%m%d')}.jsonl"
            )
            for offset in (0, 1)
        )
        command = f"tail -n 0 -F {files} 2>/dev/null"
        process = subprocess.Popen(
            _journal_shell(args, command), stdout=subprocess.PIPE, text=True
        )
        try:
            assert process.stdout is not None
            for line in process.stdout:
                _journal_emit(line, args, since_epoch)
                sys.stdout.flush()
        except KeyboardInterrupt:
            pass
        finally:
            process.terminate()
        return 0

    matching = [
        raw
        for raw, record in _journal_read(args, since_epoch)
        if _journal_matches(record, args, since_epoch)
    ]
    if args.last:
        matching = list(collections.deque(matching, maxlen=args.last))
    for raw in matching:
        _journal_emit(raw, args, since_epoch)
    if not matching:
        print("no matching journal records", file=sys.stderr)
        return 1
    return 0
