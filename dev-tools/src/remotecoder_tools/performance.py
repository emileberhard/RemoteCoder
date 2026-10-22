import argparse
import time
from typing import Any

from .config import GatewayConfig, _resolve_config
from .rpc import _claude_health, _initialize, _open_gateway, _timed_rpc
from .turns import _assert_e2e


def _check_elapsed(label: str, elapsed: float, max_seconds: float) -> None:
    _assert_e2e(
        elapsed <= max_seconds,
        f"{label} took {elapsed:.2f}s, expected <= {max_seconds:.2f}s",
    )


def _check_size(label: str, byte_count: int, max_bytes: int) -> None:
    _assert_e2e(
        byte_count <= max_bytes,
        f"{label} response was {byte_count} bytes, expected <= {max_bytes} bytes",
    )


def _native_page_entries(result: dict[str, Any], *, limit: int, turn_id: str | None = None) -> list[dict[str, Any]]:
    entries = result.get("data")
    _assert_e2e(isinstance(entries, list), "native page returned no data array")
    _assert_e2e(len(entries) <= limit, "native page exceeded requested count")
    identities = []
    for entry in entries:
        _assert_e2e(isinstance(entry, dict), "native page has invalid entry")
        if "item" in entry:
            item = entry.get("item")
            _assert_e2e(isinstance(item, dict), "item page has invalid item")
            _assert_e2e(isinstance(entry.get("turnId"), str), "item page is missing turn identity")
            if turn_id is not None:
                _assert_e2e(entry["turnId"] == turn_id, "item page escaped its canonical turn filter")
            identity = (entry["turnId"], item.get("id"))
        else:
            identity = entry.get("id")
            _assert_e2e(entry.get("itemsView") in ("summary", "notLoaded", "full"), "turn page lacks explicit coverage")
        _assert_e2e(bool(identity) and (not isinstance(identity, tuple) or bool(identity[1])), "page entry has no canonical identity")
        identities.append(identity)
    _assert_e2e(len(set(identities)) == len(identities), "native page contains duplicate identities")
    return entries


async def _probe_native_history_pages(ws, *, next_id, thread_id: str, args, report) -> None:
    cold = True

    async def read(method: str, params: dict[str, Any], label: str):
        nonlocal cold
        result, elapsed, byte_count = await _timed_rpc(
            ws, req_id=next_id(), method=method, params={"threadId": thread_id, **params}, timeout_s=args.timeout,
        )
        _check_elapsed(label, elapsed, args.max_cold_read_seconds if cold else args.max_read_seconds)
        cold = False
        _check_size(label, byte_count, args.max_native_page_bytes)
        entries = _native_page_entries(result, limit=params["limit"], turn_id=params.get("turnId"))
        report(label, elapsed, byte_count, f"entries={len(entries)} continuation={bool(result.get('nextCursor'))}")
        return result, entries

    headers, turns = await read("thread/turns/list", {"limit": 10, "sortDirection": "desc", "itemsView": "notLoaded"}, "native turn headers")
    _assert_e2e(all(turn.get("itemsView") == "notLoaded" and not turn.get("items") for turn in turns), "headers unexpectedly contain item payloads")
    if args.expect_nonempty:
        _assert_e2e(bool(turns), "native history has no turns")
    await read("thread/turns/list", {"limit": 10, "sortDirection": "desc", "itemsView": "summary"}, "native turn summaries")
    if headers.get("nextCursor"):
        _, older = await read("thread/turns/list", {"limit": 10, "sortDirection": "desc", "itemsView": "notLoaded", "cursor": headers["nextCursor"]}, "native older turns")
        _assert_e2e(not ({turn["id"] for turn in turns} & {turn["id"] for turn in older}), "turn cursor repeated an earlier page")
    if not turns:
        return
    turn_id = turns[0]["id"]
    page, items = await read("thread/items/list", {"turnId": turn_id, "limit": 20, "sortDirection": "desc"}, "native recent items")
    if page.get("nextCursor"):
        _, older = await read("thread/items/list", {"turnId": turn_id, "limit": 20, "sortDirection": "desc", "cursor": page["nextCursor"]}, "native older items")
        _assert_e2e(not ({entry["item"]["id"] for entry in items} & {entry["item"]["id"] for entry in older}), "item cursor repeated an earlier page")
    if page.get("backwardsCursor"):
        await read("thread/items/list", {"turnId": turn_id, "limit": 20, "sortDirection": "asc", "cursor": page["backwardsCursor"]}, "native newer items")


async def _walk_items_to_start(ws, *, next_id, thread_id: str, args, report) -> None:
    started = time.perf_counter()
    seen: set[tuple[str, str]] = set()
    cursor = None
    pages = 0
    total_bytes = 0
    slowest = 0.0
    while True:
        params: dict[str, Any] = {"threadId": thread_id, "limit": args.walk_page_size, "sortDirection": "desc"}
        if cursor:
            params["cursor"] = cursor
        result, elapsed, byte_count = await _timed_rpc(
            ws, req_id=next_id(), method="thread/items/list", params=params, timeout_s=args.timeout,
        )
        pages += 1
        label = f"items walk page {pages}"
        _check_elapsed(label, elapsed, args.max_read_seconds)
        _check_size(label, byte_count, args.max_native_page_bytes)
        entries = _native_page_entries(result, limit=args.walk_page_size)
        identities = {(entry["turnId"], entry["item"]["id"]) for entry in entries}
        _assert_e2e(not (identities & seen), f"{label} repeated an item from a newer page")
        seen |= identities
        total_bytes += byte_count
        slowest = max(slowest, elapsed)
        cursor = result.get("nextCursor")
        if not cursor:
            break
        _assert_e2e(bool(entries), f"{label} is empty but continues")
        _assert_e2e(pages < args.max_walk_pages, f"items walk passed {args.max_walk_pages} pages before the start")
    if args.expect_nonempty:
        _assert_e2e(bool(seen), "items walk found no items")
    report(
        "native items walk to start",
        time.perf_counter() - started,
        total_bytes,
        f"thread={thread_id} pages={pages} items={len(seen)} slowestPage={slowest:.2f}s",
    )


async def _newest_claude_thread(ws, cfg: GatewayConfig, *, next_id, args) -> str | None:
    if args.claude_thread_id:
        return args.claude_thread_id
    if not (await _claude_health(cfg)).get("enabled"):
        return None
    result, _, _ = await _timed_rpc(
        ws, req_id=next_id(), method="claude/thread/list", params={"limit": 1}, timeout_s=args.timeout,
    )
    threads = result.get("data") or []
    if not threads:
        return None
    return str(threads[0].get("id") or "") or None


async def _probe_replay_notifications(ws, *, next_id, thread_id: str, args, report) -> int:
    cursor = 0
    epoch: str | None = None
    for page_number in range(args.max_replay_pages):
        params: dict[str, Any] = {"afterSequence": cursor, "threadId": thread_id, "limit": 2000}
        if epoch is not None:
            params["epoch"] = epoch
        result, elapsed, byte_count = await _timed_rpc(
            ws,
            req_id=next_id(),
            method="daemon/replayNotifications",
            params=params,
            timeout_s=args.timeout,
        )
        _check_elapsed("daemon/replayNotifications", elapsed, args.max_read_seconds)
        notifications = result.get("notifications")
        _assert_e2e(isinstance(notifications, list), "replay returned no notifications array")
        has_more = result.get("hasMore")
        through = result.get("throughSequence")
        if has_more is None and through is None:
            latest = result.get("latestSequence")
            _assert_e2e(type(latest) is int, "legacy replay returned no latestSequence")
            report("daemon/replayNotifications", elapsed, byte_count, f"thread={thread_id} legacy cursor={latest}")
            return latest
        _assert_e2e(type(has_more) is bool and type(through) is int, "replay continuation is incomplete")
        _assert_e2e(through >= cursor, "replay cursor moved backward")
        next_epoch = result.get("epoch")
        _assert_e2e(isinstance(next_epoch, str) and bool(next_epoch), "replay returned no epoch")
        _assert_e2e(epoch is None or epoch == next_epoch, "replay epoch changed during pagination")
        _assert_e2e(not has_more or through > cursor, "replay page made no progress")
        epoch = next_epoch
        cursor = through
        if not has_more:
            report("daemon/replayNotifications", elapsed, byte_count, f"thread={thread_id} pages={page_number + 1} cursor={cursor}")
            return cursor
    raise RuntimeError(f"daemon/replayNotifications exceeded {args.max_replay_pages} pages for {thread_id}")


async def cmd_e2e_reads(args: argparse.Namespace) -> int:
    cfg = _resolve_config(args)
    if args.timeout is None:
        args.timeout = 30.0 if args.provider == "claude" else 12.0
    if args.provider == "claude":
        claude = await _claude_health(cfg)
        _assert_e2e(bool(claude.get("enabled")), "claude provider is disabled")
        _assert_e2e(bool(claude.get("ok")), f"claude preflight failed: {claude.get('error')}")
        # `ok` already requires all three, but assert them by name so a regression
        # reports which part of the subscription contract broke.
        _assert_e2e(claude.get("loggedIn") is True, "claude is not logged in")
        _assert_e2e(claude.get("authMethod") == "claude.ai", "claude auth is not the subscription login")
        _assert_e2e(claude.get("apiProvider") == "firstParty", "claude would bill a third-party provider")
        print(f"ok  health.claude  version={claude.get('version')}")

        ids = iter(range(1, 1_000_000))

        def next_id() -> int:
            return next(ids)

        async with _open_gateway(cfg, timeout_s=args.timeout, method="claude/thread/list") as ws:
            await _initialize(ws, timeout_s=args.timeout)

            result, elapsed, byte_count = await _timed_rpc(
                ws, req_id=next_id(), method="claude/thread/list", params={"limit": 30}, timeout_s=args.timeout
            )
            threads = result.get("data") or []
            _check_elapsed("claude/thread/list", elapsed, 10.0)
            _check_size("claude/thread/list", byte_count, 4 * 1024 * 1024)
            print(f"ok  claude/thread/list  {len(threads)} threads in {elapsed:.2f}s")
            if not threads:
                print("no claude threads yet; read checks skipped")
                return 0

            thread_id = args.claude_thread_id or str(threads[0].get("id") or "")
            _assert_e2e(bool(thread_id), "no thread id to read")

            result, elapsed, byte_count = await _timed_rpc(
                ws, req_id=next_id(), method="thread/read", params={"threadId": thread_id}, timeout_s=args.timeout
            )
            _assert_e2e(isinstance(result.get("thread"), dict), "thread/read returned no thread")
            _assert_e2e(result.get("modelProvider") == "claude", "thread/read lost the claude provider")
            _check_elapsed("thread/read", elapsed, 10.0)
            print(f"ok  thread/read  {thread_id} in {elapsed:.2f}s")

            def report(label: str, elapsed: float, byte_count: int, detail: str) -> None:
                print(f"ok  {label}  {byte_count / 1024:.0f} KiB in {elapsed:.2f}s {detail}")

            await _probe_native_history_pages(ws, next_id=next_id, thread_id=thread_id, args=args, report=report)

        print("all claude read checks passed")
        return 0

    req_id = 1

    def next_id() -> int:
        nonlocal req_id
        value = req_id
        req_id += 1
        return value

    def report(label: str, elapsed: float, byte_count: int, detail: str) -> None:
        print(f"PASS {label}: {elapsed:.2f}s {byte_count} bytes {detail}")

    async with _open_gateway(cfg, timeout_s=args.timeout, method="thread/list") as ws:
        await _initialize(ws, timeout_s=args.timeout)

        result, elapsed, byte_count = await _timed_rpc(
            ws,
            req_id=next_id(),
            method="thread/list",
            params={"limit": args.thread_list_limit},
            timeout_s=args.timeout,
        )
        _check_elapsed("thread/list", elapsed, args.max_list_seconds)
        threads = result.get("data")
        _assert_e2e(isinstance(threads, list), "thread/list returned no data array")
        _assert_e2e(len(threads) > 0, "thread/list returned no conversations to read")
        report("thread/list", elapsed, byte_count, f"threads={len(threads)}")

        selected = None
        if args.thread_id:
            for thread in threads:
                if isinstance(thread, dict) and thread.get("id") == args.thread_id:
                    selected = thread
                    break
            if selected is None:
                result, elapsed, byte_count = await _timed_rpc(
                    ws,
                    req_id=next_id(),
                    method="thread/read",
                    params={"threadId": args.thread_id, "includeTurns": False},
                    timeout_s=args.timeout,
                )
                _check_elapsed("thread/read target", elapsed, args.max_read_seconds)
                selected = result.get("thread")
                _assert_e2e(isinstance(selected, dict), "thread/read target returned no thread")
                report("thread/read target", elapsed, byte_count, f"thread={args.thread_id}")
        else:
            selected = next((thread for thread in threads if isinstance(thread, dict)), None)

        _assert_e2e(isinstance(selected, dict), "could not select a thread for read tests")
        thread_id = str(selected.get("id") or "").strip()
        _assert_e2e(thread_id != "", "selected thread has no id")

        result, elapsed, byte_count = await _timed_rpc(
            ws,
            req_id=next_id(),
            method="thread/read",
            params={"threadId": thread_id, "includeTurns": False},
            timeout_s=args.timeout,
        )
        _check_elapsed("thread/read", elapsed, args.max_read_seconds)
        selected = result.get("thread")
        _assert_e2e(isinstance(selected, dict), "thread/read returned no thread")
        report("thread/read", elapsed, byte_count, f"thread={thread_id}")

        if args.expect_fork:
            _assert_e2e(bool(selected.get("forkedFromId")), "selected thread is not a canonical fork")
        await _probe_native_history_pages(ws, next_id=next_id, thread_id=thread_id, args=args, report=report)

        await _walk_items_to_start(ws, next_id=next_id, thread_id=thread_id, args=args, report=report)
        await _probe_replay_notifications(ws, next_id=next_id, thread_id=thread_id, args=args, report=report)

        claude_thread_id = await _newest_claude_thread(ws, cfg, next_id=next_id, args=args)
        if claude_thread_id is None:
            print("SKIP claude native pages: provider disabled or no Claude threads")
        else:
            await _probe_native_history_pages(ws, next_id=next_id, thread_id=claude_thread_id, args=args, report=report)
            await _walk_items_to_start(ws, next_id=next_id, thread_id=claude_thread_id, args=args, report=report)
            await _probe_replay_notifications(ws, next_id=next_id, thread_id=claude_thread_id, args=args, report=report)

        result, elapsed, byte_count = await _timed_rpc(
            ws,
            req_id=next_id(),
            method="daemon/activeTurns",
            params={},
            timeout_s=args.timeout,
        )
        _check_elapsed("daemon/activeTurns", elapsed, args.max_read_seconds)
        active_turns = result.get("activeTurns", [])
        _assert_e2e(isinstance(active_turns, list), "daemon/activeTurns returned no activeTurns array")
        report("daemon/activeTurns", elapsed, byte_count, f"active={len(active_turns)}")

    print(f"OK read e2e passed for thread={thread_id}")
    return 0
