import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from contextlib import redirect_stdout
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from remotecoder_tools import navigation as live_navigation


class DestinationLookupTests(unittest.TestCase):
    def test_uses_places_search_route_cli_and_returns_its_destination(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            tool = home / "configs/skills/places-search/scripts/maps-route"
            tool.parent.mkdir(parents=True)
            tool.touch()
            result = Mock(
                returncode=0,
                stdout=json.dumps(
                    {
                        "places": [
                            {
                                "id": "place-1",
                                "displayName": {"text": "Lund Central"},
                                "location": {"latitude": 55.7047, "longitude": 13.1872},
                            }
                        ]
                    }
                ),
            )
            with patch.object(live_navigation.Path, "home", return_value=home), patch.object(
                live_navigation.subprocess, "run", return_value=result
            ) as run:
                destination = live_navigation._resolve_destination("Lund Central")

        self.assertEqual(run.call_args.args[0][:2], [str(tool), "request"])
        self.assertEqual(
            destination,
            {
                "latitude": 55.7047,
                "longitude": 13.1872,
                "title": "Lund Central",
                "placeId": "place-1",
            },
        )


    def _lookup(self, run) -> dict:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            tool = home / "configs/skills/places-search/scripts/maps-route"
            tool.parent.mkdir(parents=True)
            tool.touch()
            with patch.object(live_navigation.Path, "home", return_value=home), patch.object(
                live_navigation.subprocess, "run", run
            ):
                return live_navigation._resolve_destination("Lund Central")

    def test_a_hung_lookup_is_bounded(self) -> None:
        run = Mock(side_effect=subprocess.TimeoutExpired("maps-route", live_navigation.MAPS_LOOKUP_TIMEOUT_S))
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            self._lookup(run)
        self.assertEqual(run.call_args.kwargs["timeout"], live_navigation.MAPS_LOOKUP_TIMEOUT_S)

    def test_malformed_lookup_results_are_errors(self) -> None:
        for stdout in (
            "not json",
            json.dumps({"places": {"id": "x"}}),
            json.dumps({"places": [{"id": "x"}]}),
            json.dumps({"places": [{"location": {"latitude": "55.7", "longitude": 13.1}}]}),
            json.dumps({"places": [{"location": {"latitude": 91, "longitude": 13.1}}]}),
        ):
            with self.subTest(stdout=stdout), self.assertRaises(RuntimeError):
                self._lookup(Mock(return_value=Mock(returncode=0, stdout=stdout)))


class NavigationRPCTests(unittest.IsolatedAsyncioTestCase):
    async def test_rpc_error_keeps_the_navigation_message(self) -> None:
        socket = AsyncMock()
        socket.__aenter__.return_value = socket
        with (
            patch.object(live_navigation, "_resolve_config", return_value=Mock()),
            patch.object(live_navigation, "_ws_connect", AsyncMock(return_value=socket)),
            patch.object(live_navigation, "_drain_ready", AsyncMock()),
            patch.object(live_navigation, "_initialize", AsyncMock()),
            patch.object(
                live_navigation,
                "request_response",
                AsyncMock(return_value=({"error": {"message": "denied"}}, 0, 0)),
            ),
            self.assertRaisesRegex(RuntimeError, "navigation/status failed: denied"),
        ):
            await live_navigation._rpc(Mock(timeout=1), "navigation/status", {}, deadline_s=1)

    async def test_a_non_object_result_is_an_error(self) -> None:
        client = live_navigation.NavigationClient(AsyncMock())
        with (
            patch.object(live_navigation, "request_response", AsyncMock(return_value=({"result": []}, 0, 0))),
            self.assertRaisesRegex(RuntimeError, "no result object"),
        ):
            await client.call("navigation/next", {}, deadline_s=1)


class WatchTests(unittest.IsolatedAsyncioTestCase):
    async def test_watch_streams_events_on_one_connection_until_stop(self) -> None:
        args = live_navigation.build_parser().parse_args(["--timeout", "5", "watch", "--session-id", "s", "--wait", "7"])
        socket = AsyncMock()
        socket.__aenter__.return_value = socket
        responses = [
            {"result": {"event": {"sequence": 3, "kind": "location"}}},
            {"result": {"event": None, "state": "waiting"}},
            {"result": {"event": None, "state": "stopRequested"}},
        ]
        request = AsyncMock(side_effect=[(response, 0, 0) for response in responses])
        connect = AsyncMock(return_value=socket)
        output = io.StringIO()
        with (
            patch.object(live_navigation, "_resolve_config", return_value=Mock()),
            patch.object(live_navigation, "_ws_connect", connect),
            patch.object(live_navigation, "_drain_ready", AsyncMock()),
            patch.object(live_navigation, "_initialize", AsyncMock()),
            patch.object(live_navigation, "request_response", request),
            redirect_stdout(output),
        ):
            self.assertEqual(await live_navigation.command_watch(args), 0)
        self.assertEqual(connect.call_count, 1)
        self.assertEqual([call.kwargs["timeout_s"] for call in request.call_args_list], [12, 12, 12])
        after = [json.loads(call.kwargs["payload"])["params"]["afterSequence"] for call in request.call_args_list]
        self.assertEqual(after, [0, 3, 3])
        self.assertEqual(len(output.getvalue().splitlines()), 2)


class WaitBoundTests(unittest.TestCase):
    def test_a_wait_beyond_the_gateway_clamp_is_rejected(self) -> None:
        parser = live_navigation.build_parser()
        for wait in ("0", "61"):
            with self.subTest(wait=wait), patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
                parser.parse_args(["next", "--session-id", "s", "--wait", wait])
        self.assertEqual(parser.parse_args(["next", "--session-id", "s", "--wait", "60"]).wait, 60)
