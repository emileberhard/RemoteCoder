import argparse
import asyncio
import itertools
import json
import math
import subprocess
import sys
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from .config import _resolve_config, add_connection_arguments
from .rpc import _drain_ready, _initialize, _json, _ws_connect, request_response


MAPS_LOOKUP_TIMEOUT_S = 20.0

MAX_WAIT_SECONDS = 60


def _emit(value: object, *, compact: bool) -> None:
    if compact:
        print(json.dumps(value, separators=(",", ":"), ensure_ascii=True))
    else:
        print(json.dumps(value, indent=2, ensure_ascii=True))


class NavigationClient:
    def __init__(self, websocket) -> None:
        self._websocket = websocket
        self._request_ids = itertools.count(1)

    async def call(self, method: str, params: dict[str, Any], *, deadline_s: float) -> dict[str, Any]:
        request_id = next(self._request_ids)
        message, _, _ = await request_response(
            self._websocket, req_id=request_id,
            payload=_json({"id": request_id, "method": method, "params": params}),
            timeout_s=deadline_s, send_timeout_s=deadline_s,
        )
        if "error" in message:
            error = message["error"]
            detail = error.get("message", error) if isinstance(error, dict) else error
            raise RuntimeError(f"{method} failed: {detail}")
        result = message.get("result")
        if not isinstance(result, dict):
            raise RuntimeError(f"{method} returned no result object")
        return result


@asynccontextmanager
async def _connected(args: argparse.Namespace) -> AsyncIterator[NavigationClient]:
    config = _resolve_config(args)
    async with await _ws_connect(config) as websocket:
        await _drain_ready(websocket, timeout_s=args.timeout)
        await _initialize(websocket, timeout_s=args.timeout)
        yield NavigationClient(websocket)


async def _rpc(args: argparse.Namespace, method: str, params: dict[str, Any], *, deadline_s: float) -> dict[str, Any]:
    async with _connected(args) as client:
        return await client.call(method, params, deadline_s=deadline_s)


def _coordinate(value: object, *, name: str, limit: float) -> float:
    if isinstance(value, bool) or not isinstance(value, int | float) or not math.isfinite(value) or abs(value) > limit:
        raise RuntimeError(f"invalid destination {name}: {value!r}")
    return float(value)


def _resolve_destination(query: str) -> dict[str, Any]:
    tool = Path.home() / "configs/skills/places-search/scripts/maps-route"
    if not tool.is_file():
        raise RuntimeError(f"places-search CLI not found at {tool}")
    body = json.dumps({"textQuery": query, "maxResultCount": 1})
    command = [
        str(tool),
        "request",
        "--url",
        "https://places.googleapis.com/v1/places:searchText",
        "--method",
        "POST",
        "--field-mask",
        "places.id,places.displayName,places.formattedAddress,places.location",
        "--json",
        body,
    ]
    try:
        process = subprocess.run(
            command, check=False, capture_output=True, text=True,
            stdin=subprocess.DEVNULL, timeout=MAPS_LOOKUP_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"destination lookup timed out after {MAPS_LOOKUP_TIMEOUT_S:.0f} seconds") from exc
    if process.returncode != 0:
        detail = process.stderr.strip() or process.stdout.strip()
        raise RuntimeError(f"destination lookup failed: {detail}")
    try:
        payload = json.loads(process.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("destination lookup returned invalid JSON") from exc
    places = payload.get("places", []) if isinstance(payload, dict) else None
    if not isinstance(places, list):
        raise RuntimeError("destination lookup returned an unexpected shape")
    if not places:
        raise RuntimeError(f"destination lookup returned no place for {query!r}")
    place = places[0]
    location = place.get("location") if isinstance(place, dict) else None
    if not isinstance(location, dict):
        raise RuntimeError("destination lookup returned a place without a location")
    display_name = place.get("displayName")
    title = (
        (display_name.get("text") if isinstance(display_name, dict) else None)
        or place.get("formattedAddress")
        or query
    )
    return {
        "latitude": _coordinate(location.get("latitude"), name="latitude", limit=90.0),
        "longitude": _coordinate(location.get("longitude"), name="longitude", limit=180.0),
        "title": title,
        "placeId": place.get("id"),
    }


def _destination(args: argparse.Namespace) -> dict[str, Any] | None:
    if args.destination:
        if args.latitude is not None or args.longitude is not None:
            raise RuntimeError(
                "use either --destination or --latitude/--longitude, not both"
            )
        return _resolve_destination(args.destination)
    if args.latitude is None and args.longitude is None:
        return None
    if args.latitude is None or args.longitude is None:
        raise RuntimeError("--latitude and --longitude must be provided together")
    return {
        "latitude": _coordinate(args.latitude, name="latitude", limit=90.0),
        "longitude": _coordinate(args.longitude, name="longitude", limit=180.0),
        "title": args.title or "Destination",
        "placeId": args.place_id,
    }


async def command_start(args: argparse.Namespace) -> int:
    result = await _rpc(
        args,
        "navigation/start",
        {
            "destination": _destination(args),
            "profile": {
                "mode": args.mode,
                "avoidHighways": args.avoid_highways,
                "avoidTolls": args.avoid_tolls,
            },
        },
        deadline_s=args.timeout,
    )
    _emit(result, compact=args.json)
    return 0


async def command_status(args: argparse.Namespace) -> int:
    result = await _rpc(args, "navigation/status", {"sessionId": args.session_id}, deadline_s=args.timeout)
    _emit(result, compact=args.json)
    return 0


def _next_params(args: argparse.Namespace, after_sequence: int) -> dict[str, Any]:
    return {
        "sessionId": args.session_id,
        "afterSequence": after_sequence,
        "timeoutSeconds": args.wait,
    }


async def command_next(args: argparse.Namespace) -> int:
    result = await _rpc(
        args, "navigation/next", _next_params(args, args.after_sequence),
        deadline_s=args.timeout + args.wait,
    )
    _emit(result, compact=args.json)
    return 0


async def command_watch(args: argparse.Namespace) -> int:
    sequence = args.after_sequence
    async with _connected(args) as client:
        while True:
            result = await client.call(
                "navigation/next", _next_params(args, sequence), deadline_s=args.timeout + args.wait,
            )
            event = result.get("event")
            if event is not None and not isinstance(event, dict):
                raise RuntimeError("navigation/next returned a malformed event")
            if event:
                _emit(event, compact=True)
                event_sequence = event.get("sequence")
                if isinstance(event_sequence, int):
                    sequence = event_sequence
            elif result.get("state") == "stopRequested":
                _emit(result, compact=True)
                return 0


async def command_stop(args: argparse.Namespace) -> int:
    result = await _rpc(args, "navigation/stop", {"sessionId": args.session_id}, deadline_s=args.timeout)
    _emit(result, compact=args.json)
    return 0


def _wait_seconds(value: str) -> int:
    seconds = int(value)
    if not 1 <= seconds <= MAX_WAIT_SECONDS:
        raise argparse.ArgumentTypeError(f"must be between 1 and {MAX_WAIT_SECONDS} seconds")
    return seconds


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="live-navigation",
        description="Start and stream agent-facing live-location sessions through RemoteCoder.",
    )
    add_connection_arguments(parser)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--json", action="store_true", help="emit compact machine-readable JSON")
    commands = parser.add_subparsers(dest="command", required=True)

    start = commands.add_parser("start", help="start tracking; destination is optional")
    start.add_argument(
        "--mode", required=True, choices=["driving", "cycling", "walking", "taxi"]
    )
    start.add_argument(
        "--destination", help="place or address resolved through places-search"
    )
    start.add_argument("--latitude", type=float)
    start.add_argument("--longitude", type=float)
    start.add_argument("--title")
    start.add_argument("--place-id")
    start.add_argument("--avoid-highways", action="store_true")
    start.add_argument("--avoid-tolls", action="store_true")
    start.set_defaults(handler=command_start)

    status = commands.add_parser("status", help="show a session or the latest session")
    status.add_argument("--session-id")
    status.set_defaults(handler=command_status)

    next_event = commands.add_parser("next", help="long-poll for one event")
    next_event.add_argument("--session-id", required=True)
    next_event.add_argument("--after-sequence", type=int, default=0)
    next_event.add_argument("--wait", type=_wait_seconds, default=20)
    next_event.set_defaults(handler=command_next)

    watch = commands.add_parser("watch", help="stream JSONL events until stopped")
    watch.add_argument("--session-id", required=True)
    watch.add_argument("--after-sequence", type=int, default=0)
    watch.add_argument("--wait", type=_wait_seconds, default=20)
    watch.set_defaults(handler=command_watch)

    stop = commands.add_parser("stop", help="request that the iPhone stop tracking")
    stop.add_argument("--session-id", required=True)
    stop.set_defaults(handler=command_stop)
    return parser


async def _main() -> int:
    args = build_parser().parse_args()
    try:
        return await args.handler(args)
    except KeyboardInterrupt:
        return 130
    except Exception as error:
        if args.debug:
            raise
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_main()))
