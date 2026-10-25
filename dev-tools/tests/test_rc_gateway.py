import asyncio
import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from remotecoder_tools import config as gateway_config, diagnostics, gateway_cli, performance, probes, rpc as gateway_rpc, turns, verdict


class GatewayTransportTests(unittest.TestCase):
    def test_unattributed_null_payload_preserves_stream_thread_filtering(self) -> None:
        for frame, expected in (
            ({"method": "daemon/liveActivity/changed", "params": None}, None),
            ({"id": 1, "result": {}}, None),
            ({"method": "item/completed", "params": {"threadId": "thread-1"}}, "thread-1"),
            ({"method": "codex/event", "params": {"msg": {"thread_id": "thread-2"}}}, "thread-2"),
        ):
            with self.subTest(frame=frame):
                self.assertEqual(gateway_rpc._event_thread_id(frame), expected)

    def test_health_and_websocket_share_the_selected_transport(self) -> None:
        secure = gateway_config.GatewayConfig("example.test", 443, "synthetic", "wss")
        self.assertEqual(secure.http_base, "https://example.test:443")
        self.assertEqual(secure.ws_url, "wss://example.test:443/ws")
        local = gateway_config.GatewayConfig("localhost", 8787, "synthetic", "ws")
        self.assertEqual(local.http_base, "http://localhost:8787")

    def test_default_diagnostics_do_not_expose_credential_fragments(self) -> None:
        args = gateway_cli.build_parser().parse_args(["config"])
        output = io.StringIO()
        config = gateway_config.GatewayConfig("localhost", 8787, "synthetic-secret", "ws")
        with (
            patch.object(gateway_cli, "_resolve_config", return_value=config),
            redirect_stdout(output),
        ):
            self.assertEqual(asyncio.run(gateway_cli.cmd_config(args)), 0)
        self.assertIn("token=<configured>", output.getvalue())
        self.assertNotIn("synthetic-secret", output.getvalue())


class TimedRPCTests(unittest.IsolatedAsyncioTestCase):
    async def test_interleaved_notification_is_available_to_the_next_reader(self) -> None:
        socket = AsyncMock()
        socket.recv.side_effect = [
            json.dumps({"method": "turn/completed", "params": {"turnId": "turn-1"}}),
            json.dumps({"id": 7, "result": {"ok": True}}),
        ]
        result, _, _ = await gateway_rpc._timed_rpc(
            socket, req_id=7, method="probe", params={}, timeout_s=1
        )
        self.assertEqual(result, {"ok": True})
        self.assertEqual(
            await gateway_rpc._ws_recv_json(socket, timeout_s=1),
            {"method": "turn/completed", "params": {"turnId": "turn-1"}},
        )

    async def test_notifications_do_not_extend_the_rpc_deadline(self) -> None:
        socket = AsyncMock()

        async def notify_forever():
            await asyncio.sleep(0.005)
            return json.dumps({"method": "turn/started", "params": {}})

        socket.recv.side_effect = notify_forever
        with self.assertRaises(TimeoutError):
            await gateway_rpc._timed_rpc(
                socket, req_id=7, method="probe", params={}, timeout_s=0.03
            )

    async def test_an_observer_sees_every_frame_in_arrival_order(self) -> None:
        frames: asyncio.Queue[str] = asyncio.Queue()
        socket = AsyncMock()
        socket.recv.side_effect = frames.get
        frames.put_nowait(json.dumps({"method": "thread/started", "params": {"index": 1}}))
        frames.put_nowait(json.dumps({"id": 7, "result": {"ok": True}}))
        await gateway_rpc._timed_rpc(socket, req_id=7, method="first", params={}, timeout_s=1)
        seen: list[dict] = []
        gateway_rpc._reader(socket).observe(seen.append)
        frames.put_nowait(json.dumps({"method": "turn/started", "params": {"index": 2}}))
        frames.put_nowait(json.dumps({"id": 8, "result": {"ok": True}}))
        await gateway_rpc._timed_rpc(socket, req_id=8, method="second", params={}, timeout_s=1)
        self.assertEqual(
            seen,
            [
                {"method": "thread/started", "params": {"index": 1}},
                {"method": "turn/started", "params": {"index": 2}},
                {"id": 8, "result": {"ok": True}},
            ],
        )

    async def test_a_request_after_the_reader_failed_raises_its_failure(self) -> None:
        socket = AsyncMock()
        payload = '{"token":"sk-token-like-private-' + "x" * 200 + '"'
        socket.recv.side_effect = [payload]
        with self.assertRaisesRegex(RuntimeError, "invalid json from gateway") as failure:
            await gateway_rpc._ws_recv_json(socket, timeout_s=1)
        diagnostic = str(failure.exception)
        self.assertIn(f"bytes={len(payload.encode('utf-8'))}", diagnostic)
        self.assertIn("stage=json", diagnostic)
        self.assertNotIn("sk-token-like-private", diagnostic)
        prefix = diagnostic.split("prefix=", 1)[1]
        self.assertLessEqual(len(prefix), 64)
        self.assertTrue(set(prefix) <= set('_{}[]:," '))
        binary = '{"id":{},"x":"\\"{}[]:, "}'.encode("utf-16-le")
        binary_socket = AsyncMock()
        binary_socket.recv.side_effect = [binary]
        with self.assertRaises(RuntimeError) as binary_failure:
            await gateway_rpc._ws_recv_json(binary_socket, timeout_s=1)
        self.assertIn(f"bytes={len(binary)}", str(binary_failure.exception))
        self.assertEqual(str(binary_failure.exception).split("prefix=", 1)[1], "_" * min(64, len(binary)))
        with self.assertRaisesRegex(RuntimeError, "invalid json from gateway"):
            await gateway_rpc._timed_rpc(socket, req_id=7, method="probe", params={}, timeout_s=0.5)
        socket.send.assert_not_awaited()

    async def test_overflowing_pending_notifications_fail_only_their_reader(self) -> None:
        socket = AsyncMock()
        socket.recv.side_effect = [
            json.dumps({"method": "turn/started", "params": {"index": 1}}),
            json.dumps({"method": "turn/started", "params": {"index": 2}}),
            json.dumps({"id": 7, "result": {"ok": True}}),
        ]
        with patch.object(gateway_rpc, "_MAX_PENDING_MESSAGES", 1):
            result, _, _ = await gateway_rpc._timed_rpc(
                socket, req_id=7, method="probe", params={}, timeout_s=1
            )
            self.assertEqual(result, {"ok": True})
            with self.assertRaisesRegex(RuntimeError, "1 gateway messages were dropped"):
                await gateway_rpc._ws_recv_json(socket, timeout_s=1)


class GatewayJournalFailureTests(unittest.TestCase):
    def test_review_trace_filter_and_summary_preserve_identity_without_dumping_payloads(self) -> None:
        args = gateway_cli.build_parser().parse_args(["journal", "--kind", "review", "--trace", "run-1"])
        record = {"kind":"review", "event":"request", "traceId":"run-1", "threadId":"thread", "turnId":"turn",
                  "operation":"judge", "body":{"state":{"messages":[{"text":"LONG PRIVATE INPUT"}]}},
                  "ts":"2026-10-03T01:00:00Z"}
        self.assertTrue(diagnostics._journal_matches(record, args, None))
        self.assertFalse(diagnostics._journal_matches({**record, "traceId":"run-10"}, args, None))
        summary = diagnostics._journal_summary(record)
        self.assertIn("trace=run-1", summary)
        self.assertIn("thread/turn", summary)
        self.assertIn("operation=judge", summary)
        self.assertNotIn("LONG PRIVATE INPUT", summary)

    def test_failed_day_read_is_not_empty_evidence(self) -> None:
        args = gateway_cli.build_parser().parse_args(["journal"])
        with patch.object(
            gateway_config.subprocess,
            "run",
            return_value=Mock(returncode=4, stderr="unreadable journal day", stdout=""),
        ):
            with self.assertRaisesRegex(RuntimeError, "unreadable journal day"):
                diagnostics._journal_read(args, None)


class SteerDiscoveryTests(unittest.IsolatedAsyncioTestCase):
    async def test_quiet_turn_uses_exact_inventory_identity(self) -> None:
        args = gateway_cli.build_parser().parse_args(
            ["steer", "--thread-id", "thread-1", "--text", "continue", "--probe", "0"]
        )
        socket = AsyncMock()
        socket.__aenter__.return_value = socket
        config = gateway_config.GatewayConfig("localhost", 8787, "synthetic", "ws")
        inventory = {
            "activeTurns": [
                {"threadId": "thread-10", "turnId": "turn-1"},
                {"threadId": "thread-1", "turnId": "turn_1"},
            ],
            "coverage": {"codex": True, "claude": True},
        }
        with (
            patch.object(gateway_cli, "_resolve_config", return_value=config),
            patch.object(gateway_cli, "_ws_connect", AsyncMock(return_value=socket)),
            patch.object(gateway_cli, "_drain_ready", AsyncMock()),
            patch.object(gateway_cli, "_initialize", AsyncMock()),
            patch.object(gateway_cli, "_timed_rpc", AsyncMock(return_value=(inventory, 0, 0))),
            patch.object(
                gateway_cli,
                "_ws_recv_json",
                AsyncMock(return_value={"id": 2, "result": {}}),
            ),
        ):
            await gateway_cli.cmd_steer(args)

        steer = json.loads(socket.send.await_args.args[0])
        self.assertEqual(steer["params"]["threadId"], "thread-1")
        self.assertEqual(steer["params"]["expectedTurnId"], "turn_1")
        self.assertNotEqual(turns._norm_turn_id("turn_1"), turns._norm_turn_id("turn-1"))


class ReplayProbeTests(unittest.IsolatedAsyncioTestCase):
    async def test_pages_from_through_sequence_until_complete(self) -> None:
        args = Mock(max_replay_pages=3, timeout=1, max_read_seconds=1)
        rpc = AsyncMock(
            side_effect=[
                ({"notifications": [{"sequence": 1}], "epoch": "epoch-1", "throughSequence": 1, "hasMore": True, "latestSequence": 9}, 0, 80),
                ({"notifications": [{"sequence": 2}], "epoch": "epoch-1", "throughSequence": 2, "hasMore": False, "latestSequence": 9}, 0, 80),
            ]
        )
        with patch.object(performance, "_timed_rpc", rpc):
            cursor = await performance._probe_replay_notifications(
                object(), next_id=iter((1, 2)).__next__, thread_id="thread-1",
                args=args, report=lambda *values: None,
            )
        self.assertEqual(cursor, 2)
        self.assertEqual(rpc.await_count, 2)
        self.assertEqual(rpc.await_args_list[1].kwargs["params"]["afterSequence"], 1)
        self.assertEqual(rpc.await_args_list[1].kwargs["params"]["epoch"], "epoch-1")

    async def test_legacy_replay_uses_latest_sequence_once(self) -> None:
        args = Mock(max_replay_pages=3, timeout=1, max_read_seconds=1)
        rpc = AsyncMock(return_value=({"notifications": [], "latestSequence": 7}, 0, 30))
        with patch.object(performance, "_timed_rpc", rpc):
            cursor = await performance._probe_replay_notifications(
                object(), next_id=lambda: 1, thread_id="thread-1",
                args=args, report=lambda *values: None,
            )
        self.assertEqual(cursor, 7)
        rpc.assert_awaited_once()


class InitializeRequestTests(unittest.TestCase):
    def test_declares_experimental_api_for_dynamic_tools(self) -> None:
        request = gateway_rpc._initialize_request(42)

        self.assertEqual(request["id"], 42)
        self.assertIs(request["params"]["capabilities"]["experimentalApi"], True)


class TurnArgumentTests(unittest.TestCase):
    def test_only_completed_turns_return_success(self) -> None:
        self.assertEqual(turns._completed_turn_exit_code("completed"), 0)
        self.assertEqual(turns._completed_turn_exit_code("failed"), 1)
        self.assertEqual(turns._completed_turn_exit_code("interrupted"), 1)
        self.assertEqual(turns._completed_turn_exit_code(None), 1)

    def test_codex_live_probes_share_one_default_model(self) -> None:
        parser = gateway_cli.build_parser()
        self.assertEqual(
            parser.parse_args(["e2e-fork-live"]).model,
            gateway_config.DEFAULT_CODEX_PROBE_MODEL,
        )
        for command in ("e2e-agent-tools-live", "e2e-upload-live", "e2e-files-live"):
            with self.subTest(command=command):
                self.assertEqual(
                    parser.parse_args([command]).codex_model,
                    gateway_config.DEFAULT_CODEX_PROBE_MODEL,
                )


class GatewayDiscoveryTests(unittest.TestCase):
    def test_remote_lookup_preserves_piped_rpc_input(self) -> None:
        import os
        import subprocess
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            ssh = Path(directory) / "ssh"
            ssh.write_text("#!/bin/sh\ncat >/dev/null\nprintf 'synthetic-config'\n")
            ssh.chmod(0o700)
            source = (
                "import sys; import remotecoder_tools.config as gateway_config; "
                "assert gateway_config._ssh_read_env('probe-remote', '/probe') == 'synthetic-config'; "
                "print(sys.stdin.read(), end='')"
            )
            result = subprocess.run(
                [sys.executable, "-c", source],
                cwd=Path(gateway_config.__file__).parent,
                env={**os.environ, "PATH": f"{directory}:/usr/bin:/bin"},
                input='{"deliveryId":"callback-probe"}',
                capture_output=True,
                text=True,
                timeout=15,
                check=True,
            )
        self.assertEqual(result.stdout, '{"deliveryId":"callback-probe"}')

    def test_remote_lookup_has_an_overall_deadline(self) -> None:
        from unittest.mock import patch
        with patch.object(gateway_config.socket, "gethostname", return_value="workstation"), \
             patch.object(gateway_config.subprocess, "run", side_effect=gateway_config.subprocess.TimeoutExpired("ssh", 10)) as run:
            with self.assertRaisesRegex(TimeoutError, "timed out after 10 seconds"):
                gateway_config._ssh_read_env("laptop", "~/.remote-coder/codex-gateway.env")
        self.assertEqual(run.call_args.kwargs["timeout"], 10)

    def test_missing_configuration_preserves_discovery_failure(self) -> None:
        from unittest.mock import patch
        args = gateway_cli.build_parser().parse_args(["--ssh-host", "laptop", "config"])
        with patch.dict(gateway_config.os.environ, {}, clear=True), \
             patch.object(gateway_config, "_ssh_read_env", side_effect=RuntimeError("Gateway lookup timed out")), \
             patch.object(gateway_config, "_read_local_config", return_value={}):
            with self.assertRaisesRegex(SystemExit, "Gateway lookup timed out"):
                gateway_config._resolve_config(args)


class DesktopJournalCoverageTests(unittest.TestCase):
    """Unreadable or corrupt coverage must never read as an empty journal."""

    def _args(self, **overrides):
        args = gateway_cli.build_parser().parse_args(["desktop-journal"])
        for key, value in overrides.items():
            setattr(args, key, value)
        return args

    def _completed(self, stdout: str, stderr: str = "", returncode: int = 0):
        from unittest.mock import Mock

        return Mock(stdout=stdout, stderr=stderr, returncode=returncode)

    def test_transport_failure_is_an_error_not_an_empty_result(self) -> None:
        from unittest.mock import patch

        with patch.object(
            gateway_config.subprocess,
            "run",
            return_value=self._completed("", "ssh: connect to host port 22: No route to host", 255),
        ):
            with self.assertRaisesRegex(SystemExit, "could not read the desktop journal"):
                diagnostics._desktop_read(self._args(ssh_host="workstation"), None)

    def test_partial_coverage_is_reported_and_returns_two(self) -> None:
        import asyncio
        from unittest.mock import patch

        marker = diagnostics.DESKTOP_UNREADABLE_MARKER
        stdout = (
            f"{marker}~/a/desktop-20260908.jsonl\n"
            '{"ts":"2026-09-09T15:22:07.089Z","event":"desktop/decision",'
            '"invocation":"abc","operation":"check","trigger":"manual",'
            '"reason":"healthy","action":"report-only"}\n'
        )
        with patch.object(gateway_config.subprocess, "run", return_value=self._completed(stdout)):
            code = asyncio.run(diagnostics.cmd_desktop_journal(self._args()))
        self.assertEqual(code, 2, "a partial view must not report success")

    def test_corrupt_records_are_counted_rather_than_skipped_silently(self) -> None:
        import asyncio
        from unittest.mock import patch

        stdout = 'not json at all\n[]\n'
        with patch.object(gateway_config.subprocess, "run", return_value=self._completed(stdout)):
            code = asyncio.run(diagnostics.cmd_desktop_journal(self._args()))
        self.assertEqual(code, 2)

    def test_clean_read_with_no_matches_is_distinct_from_degraded(self) -> None:
        import asyncio
        from unittest.mock import patch

        stdout = (
            '{"ts":"2026-09-09T15:22:07.089Z","event":"desktop/decision",'
            '"invocation":"abc","reason":"healthy"}\n'
        )
        with patch.object(gateway_config.subprocess, "run", return_value=self._completed(stdout)):
            code = asyncio.run(diagnostics.cmd_desktop_journal(self._args(invocation="zzz")))
        self.assertEqual(code, 1, "an empty but readable journal is not a coverage failure")


class DesktopJournalShellBoundaryTests(unittest.TestCase):
    """The classification runs in `sh`, so it is tested through a real shell
    against real probes. A day the host never wrote must not look like lost
    coverage, and a read that fails after the readability check must not be
    hidden by a later file that succeeds."""

    RECORD = (
        '{"ts":"2026-09-09T15:22:07.089Z","event":"desktop/decision",'
        '"invocation":"abc","operation":"check","trigger":"manual",'
        '"reason":"healthy","action":"report-only"}'
    )

    def setUp(self) -> None:
        from unittest.mock import patch

        self.enterContext(patch.dict(gateway_config.os.environ, {}))
        for name in ("RC_CODEX_GATEWAY_HOST", "RC_CODEX_GATEWAY_SSH_HOST"):
            gateway_config.os.environ.pop(name, None)

    def _day_paths(self, directory) -> tuple[Path, Path]:
        import datetime

        today = datetime.datetime.now(datetime.timezone.utc).date()
        yesterday = today - datetime.timedelta(days=1)
        return (
            directory / f"desktop-{yesterday.strftime('%Y%m%d')}.jsonl",
            directory / f"desktop-{today.strftime('%Y%m%d')}.jsonl",
        )

    def _args(self, directory):
        args = gateway_cli.build_parser().parse_args(["desktop-journal"])
        args.desktop_dir = str(directory)
        config_directory = directory if directory.is_dir() else directory.parent
        configuration = config_directory / "gateway-config.json"
        configuration.write_text(json.dumps({"macMiniHostname": gateway_config.socket.gethostname()}))
        args.local_config = str(configuration)
        return args

    def test_an_absent_prior_day_reads_cleanly(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _, today = self._day_paths(directory)
            today.write_text(self.RECORD + "\n")

            lines, unreadable = diagnostics._desktop_read(self._args(directory), None)

        self.assertEqual(lines, [self.RECORD])
        self.assertEqual(unreadable, [], "a day the host never wrote is not lost coverage")

    def test_a_present_but_unreadable_day_file_is_reported(self) -> None:
        import os
        import tempfile

        if os.geteuid() == 0:
            self.skipTest("root ignores the permission bits this asserts on")
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            yesterday, today = self._day_paths(directory)
            yesterday.write_text(self.RECORD + "\n")
            yesterday.chmod(0o000)
            today.write_text(self.RECORD + "\n")

            lines, unreadable = diagnostics._desktop_read(self._args(directory), None)

        self.assertEqual(lines, [self.RECORD])
        self.assertEqual(unreadable, [str(yesterday)])

    def test_a_read_failing_after_the_check_survives_a_later_success(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            yesterday, today = self._day_paths(directory)
            # Readable by `[ -r ]`, but `cat` fails on it.
            yesterday.mkdir()
            today.write_text(self.RECORD + "\n")

            lines, unreadable = diagnostics._desktop_read(self._args(directory), None)

        self.assertEqual(lines, [self.RECORD])
        self.assertEqual(
            unreadable,
            [str(yesterday)],
            "a later successful file must not absorb an earlier read failure",
        )

    def test_a_missing_journal_directory_is_an_error(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as raw:
            missing = Path(raw) / "never-created"
            with self.assertRaisesRegex(SystemExit, "no desktop journal directory"):
                diagnostics._desktop_read(self._args(missing), None)

    def test_every_present_day_file_unreadable_is_an_error(self) -> None:
        import os
        import tempfile

        if os.geteuid() == 0:
            self.skipTest("root ignores the permission bits this asserts on")
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _, today = self._day_paths(directory)
            today.write_text(self.RECORD + "\n")
            today.chmod(0o000)

            with self.assertRaisesRegex(SystemExit, "no readable desktop journal"):
                diagnostics._desktop_read(self._args(directory), None)


class NativeHistoryPageTests(unittest.TestCase):
    def test_partial_turn_coverage_and_filtered_item_identity(self) -> None:
        page = {"data": [{"id": "turn-1", "itemsView": "summary", "items": []}]}
        self.assertEqual(len(performance._native_page_entries(page, limit=10)), 1)
        page = {"data": [{"turnId": "turn-1", "item": {"id": "item-1"}}]}
        self.assertEqual(len(performance._native_page_entries(page, limit=20, turn_id="turn-1")), 1)
        with self.assertRaisesRegex(RuntimeError, "escaped"):
            performance._native_page_entries(page, limit=20, turn_id="different-turn")

    def test_duplicate_missing_identity_and_coverage_are_rejected(self) -> None:
        for entries in (
            [{"id": "turn-1", "itemsView": "summary"}] * 2,
            [{"id": "turn-1"}],
            [{"turnId": "turn-1", "item": {}}],
        ):
            with self.assertRaises(RuntimeError):
                performance._native_page_entries({"data": entries}, limit=10)


class UploadProbeTests(unittest.TestCase):
    def test_attached_files_block_matches_the_shared_fixture(self) -> None:
        fixture = json.loads((Path(__file__).resolve().parents[2] / "protocol-fixtures/attached-files-block.json").read_text())

        for case in fixture["cases"]:
            with self.subTest(case["name"]):
                self.assertEqual(probes.attached_files_block(case["paths"]), case["block"])

    def test_probe_pdf_is_a_readable_pdf_carrying_the_codeword(self) -> None:
        import subprocess
        import tempfile

        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "probe.pdf"
            probes.write_probe_pdf(path, "ZEBRA-4242")
            data = path.read_bytes()

            self.assertTrue(data.startswith(b"%PDF-1.4"))
            self.assertTrue(data.endswith(b"%%EOF\n"))
            self.assertIn(b"The codeword is ZEBRA-4242.", data)
            # Byte offsets in the xref table must point at each object header.
            startxref = int(data[data.rindex(b"startxref") + len(b"startxref") :].split()[0])
            self.assertTrue(data[startxref:].startswith(b"xref"))
            xref_rows = data[startxref:].split(b"\n")[3:8]
            for index, row in enumerate(xref_rows, start=1):
                offset = int(row.split()[0])
                self.assertTrue(data[offset:].startswith(f"{index} 0 obj".encode()))
            try:
                text = subprocess.run(
                    ["pdftotext", str(path), "-"], capture_output=True, text=True, check=True
                ).stdout
            except FileNotFoundError:
                self.skipTest("pdftotext is not installed")
            self.assertIn("The codeword is ZEBRA-4242.", text)


class FileProbeTests(unittest.TestCase):
    def test_only_tappable_exact_file_links_count_as_provider_acceptance(self) -> None:
        paths = {"PDF": "/tmp/år final:12.pdf", "Markdown": "/tmp/reader.md", "Binary": "/tmp/file.rcpreview"}
        links = {
            label: f"file://{probes.quote(path, safe='/')}"
            for label, path in paths.items()
        }
        text = "\n".join(f"[{label}]({url})" for label, url in links.items())
        self.assertEqual(probes._file_probe_links(text, paths), links)
        for invalid in [
            f"```markdown\n{text}\n```",
            text.replace("file:///tmp/reader.md", "file:///tmp/other.md"),
            text.replace("file:///tmp/reader.md", "file://remote/tmp/reader.md"),
            text.replace("file:///tmp/reader.md", "file:///tmp/reader.md#L1"),
            text.replace("[Binary]", "[PDF]"),
        ]:
            with self.subTest(invalid=invalid), self.assertRaises(RuntimeError):
                probes._file_probe_links(invalid, paths)

    def test_large_binary_fixture_crosses_the_websocket_limit_with_bounded_writes(self) -> None:
        import io
        from unittest.mock import patch

        class CountingFile(io.BytesIO):
            def __init__(self):
                super().__init__()
                self.bytes_written = 0
                self.largest_write = 0

            def write(self, data):
                self.bytes_written += len(data)
                self.largest_write = max(self.largest_write, len(data))
                return len(data)

        output = CountingFile()
        with patch.object(Path, "open", return_value=output):
            probes._write_file_probe_binary(Path("/unused/fixture"))
        self.assertEqual(output.bytes_written, 40 * 1024 * 1024)
        self.assertLessEqual(output.largest_write, 64 * 1024)


class FileProbeTransportTests(unittest.IsolatedAsyncioTestCase):
    async def _response(self, *, status=200, body=b"first\x00second\xff", metadata_changes=None, header_changes=None):
        import base64
        import json
        import httpx
        from unittest.mock import patch

        config = gateway_config.GatewayConfig("gateway.test", 8787, "synthetic-secret", "ws")
        path = "/tmp/probe.rcpreview"
        metadata = {"path": path, "name": "probe.rcpreview", "bytes": len(body), "modifiedAt": 1.25, "revision": "revision-1"}
        metadata.update(metadata_changes or {})
        headers = {
            "X-RemoteCoder-File-Metadata": base64.b64encode(json.dumps(metadata).encode()).decode(),
            "Content-Length": str(metadata["bytes"]),
            "Content-Type": "application/octet-stream",
        }
        headers.update(header_changes or {})

        class Chunks(httpx.AsyncByteStream):
            async def __aiter__(self):
                for offset in range(0, len(body), 3):
                    yield body[offset:offset + 3]

        def respond(request):
            self.assertEqual(str(request.url), "http://gateway.test:8787/files/download")
            self.assertEqual(request.headers["Authorization"], "Bearer synthetic-secret")
            self.assertEqual(json.loads(request.content)["path"], path)
            return httpx.Response(status, headers=headers, stream=Chunks())

        client = httpx.AsyncClient(transport=httpx.MockTransport(respond))
        with patch.object(gateway_config.GatewayConfig, "http_client", return_value=client), \
             patch.object(httpx.Response, "aread", side_effect=AssertionError("whole-body buffering is forbidden")):
            return await probes._probe_file_response(
                config, path, "revision-1" if status == 204 else None, timeout_s=1,
            )

    async def test_streamed_body_hashes_original_binary_bytes(self) -> None:
        import hashlib

        body = b"first\x00second\xff"
        result = await self._response(body=body)
        self.assertEqual(result["bytes"], len(body))
        self.assertEqual(result["sha256"], hashlib.sha256(body).hexdigest())

    async def test_incomplete_or_inconsistent_responses_cannot_pass(self) -> None:
        cases = [
            {"metadata_changes": {"bytes": 100}},
            {"metadata_changes": {"path": "/different/file"}},
            {"metadata_changes": {"modifiedAt": float("nan")}},
            {"header_changes": {"Content-Length": "100"}},
        ]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(RuntimeError):
                await self._response(**case)

    async def test_204_requires_the_requested_revision_and_no_body(self) -> None:
        result = await self._response(status=204, body=b"", metadata_changes={"bytes": 42})
        self.assertEqual(result["status"], 204)
        self.assertEqual(result["bytes"], 0)
        with self.assertRaisesRegex(RuntimeError, "known revision"):
            await self._response(status=204, body=b"", metadata_changes={"revision": "different"})
        with self.assertRaisesRegex(RuntimeError, "declared size"):
            await self._response(status=204, body=b"unexpected")

    async def test_error_bodies_remain_bounded(self) -> None:
        result = await self._response(status=404, body=b'{"kind":"missing","message":"gone"}')
        self.assertEqual(result["error"]["kind"], "missing")
        with self.assertRaisesRegex(RuntimeError, "8192 bytes"):
            await self._response(status=500, body=b"x" * 8193)


class FileProbeResumeTests(unittest.IsolatedAsyncioTestCase):
    async def test_claude_resume_uses_exact_thread_and_releases_its_runtime(self) -> None:
        from unittest.mock import AsyncMock, patch

        config = gateway_config.GatewayConfig("gateway.test", 8787, "synthetic", "ws")
        args = gateway_cli.build_parser().parse_args(["e2e-files-live"])
        socket = AsyncMock()
        socket.__aenter__.return_value = socket
        rpc = AsyncMock(side_effect=[
            ({"thread": {"id": "claude_exact"}}, 0, 0),
            ({"turn": {"id": "new-turn"}}, 0, 0),
            ({}, 0, 0),
        ])
        events = AsyncMock(side_effect=[
            {"method": "item/completed", "params": {"threadId": "claude_exact", "item": {"type": "agentMessage", "text": "links"}}},
            {"method": "turn/completed", "params": {"threadId": "claude_exact", "turn": {"id": "new-turn", "status": "completed"}}},
        ])
        with patch.object(turns, "_ws_connect", AsyncMock(return_value=socket)), \
             patch.object(turns, "_drain_ready", AsyncMock()), \
             patch.object(turns, "_initialize", AsyncMock()), \
             patch.object(turns, "_timed_rpc", rpc), \
             patch.object(turns, "_ws_recv_json", events):
            result = await turns._probe_turn(args, config, "claude", "again", resume="claude_exact")
        self.assertEqual(result["threadId"], "claude_exact")
        self.assertEqual(rpc.call_args_list[0].kwargs["method"], "thread/resume")
        self.assertEqual(rpc.call_args_list[0].kwargs["params"]["threadId"], "claude_exact")
        self.assertEqual(rpc.call_args_list[-1].kwargs["method"], "claude/thread/release")
        for request in rpc.call_args_list[:2]:
            self.assertNotIn("serviceTier", request.kwargs["params"])

    async def test_codex_resume_refuses_a_different_thread_before_starting_a_turn(self) -> None:
        from unittest.mock import AsyncMock, patch

        rpc = AsyncMock(return_value=({"thread": {"id": "wrong"}}, 0, 0))
        with patch.object(turns, "_timed_rpc", rpc), self.assertRaisesRegex(RuntimeError, "different thread"):
            await turns._run_gateway_turn(
                object(), next_id=lambda: 1, prompt="again", resume="exact", model="gpt-6-sol",
                cwd="/tmp", approval_policy="never", sandbox="readOnly", network_access=False, timeout_s=1,
            )
        self.assertEqual(rpc.call_count, 1)

    async def test_cancelling_a_probe_interrupts_only_its_exact_owned_turn(self) -> None:
        import asyncio
        from unittest.mock import AsyncMock, patch

        rpc = AsyncMock(side_effect=[
            ({"thread": {"id": "exact-thread"}}, 0, 0),
            ({"delta": None}, 0, 0),
            ({"turn": {"id": "exact-turn"}}, 0, 0),
            ({}, 0, 0),
        ])
        with patch.object(turns, "_timed_rpc", rpc), \
             patch.object(turns, "_ws_recv_json", AsyncMock(side_effect=asyncio.CancelledError)), \
             self.assertRaises(asyncio.CancelledError):
            await turns._run_probe_turn(
                object(), next_id=lambda: 1, prompt="links", resume=None, model="gpt-6-sol",
                cwd="/tmp", approval_policy="never", sandbox="readOnly", network_access=False, timeout_s=1,
            )
        self.assertEqual([call.kwargs["method"] for call in rpc.call_args_list],
                         ["thread/start", "conversation/marks/update", "turn/start", "turn/interrupt"])
        self.assertEqual(rpc.call_args_list[1].kwargs["params"], {
            "changes": [{"op": "setPurpose", "threadId": "exact-thread", "purpose": "probe"}],
        })
        self.assertEqual(rpc.call_args.kwargs["params"], {"threadId": "exact-thread", "turnId": "exact-turn"})

    async def test_a_failed_purpose_mark_still_starts_the_turn(self) -> None:
        import contextlib
        import io
        from unittest.mock import AsyncMock, patch

        rpc = AsyncMock(side_effect=[
            ({"thread": {"id": "exact-thread"}}, 0, 0),
            RuntimeError("conversation/marks/update failed"),
            ({"turn": {"id": "exact-turn"}}, 0, 0),
        ])
        stderr = io.StringIO()
        with patch.object(turns, "_timed_rpc", rpc), \
             patch.object(turns, "_ws_recv_json", AsyncMock(side_effect=TimeoutError)), \
             contextlib.redirect_stderr(stderr), \
             self.assertRaises(TimeoutError):
            await turns._run_gateway_turn(
                object(), next_id=lambda: 1, prompt="links", resume=None, model="gpt-6-sol",
                cwd="/tmp", approval_policy="never", sandbox="readOnly", network_access=False, timeout_s=1,
                purpose="automation",
            )
        self.assertEqual([call.kwargs["method"] for call in rpc.call_args_list],
                         ["thread/start", "conversation/marks/update", "turn/start"])
        self.assertIn("exact-thread was not marked as automation", stderr.getvalue())

    async def test_an_ordinary_turn_that_times_out_leaves_the_remote_turn_running(self) -> None:
        from unittest.mock import AsyncMock, patch

        rpc = AsyncMock(side_effect=[
            ({"thread": {"id": "exact-thread"}}, 0, 0),
            ({"turn": {"id": "exact-turn"}}, 0, 0),
        ])
        with patch.object(turns, "_timed_rpc", rpc), \
             patch.object(turns, "_ws_recv_json", AsyncMock(side_effect=TimeoutError)), \
             self.assertRaises(TimeoutError):
            await turns._run_gateway_turn(
                object(), next_id=lambda: 1, prompt="links", resume=None, model="gpt-6-sol",
                cwd="/tmp", approval_policy="never", sandbox="readOnly", network_access=False, timeout_s=1,
            )
        self.assertEqual([call.kwargs["method"] for call in rpc.call_args_list], ["thread/start", "turn/start"])


class RpcExitStatusTests(unittest.IsolatedAsyncioTestCase):
    async def _rpc(self, port: int) -> tuple[int, str, str]:
        import contextlib

        args = gateway_cli.build_parser().parse_args(["rpc", "--method", "thread/list", "--timeout", "2"])
        config = gateway_config.GatewayConfig(
            "127.0.0.1", port, "synthetic", "ws",
        )
        stdout, stderr = io.StringIO(), io.StringIO()
        with (
            patch.object(gateway_cli, "_resolve_config", return_value=config),
            redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            status = await gateway_cli.cmd_rpc(args)
        return status, stdout.getvalue(), stderr.getvalue()

    async def _serve(self, handler=None, process_request=None):
        from websockets.asyncio.server import serve

        async def idle(connection) -> None:
            await connection.wait_closed()

        server = await serve(handler or idle, "127.0.0.1", 0, process_request=process_request)
        self.addAsyncCleanup(server.wait_closed)
        self.addCleanup(server.close)
        return server.sockets[0].getsockname()[1]

    async def test_a_refused_connection_is_transient(self) -> None:
        import socket

        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        status, stdout, stderr = await self._rpc(port)
        self.assertEqual(status, gateway_cli.EX_TEMPFAIL)
        self.assertEqual(stdout, "")
        self.assertTrue(stderr.startswith("error: "), stderr)

    async def test_a_try_again_later_close_is_transient(self) -> None:
        async def overloaded(connection) -> None:
            await connection.close(1013, "try again later")

        status, _, stderr = await self._rpc(await self._serve(overloaded))
        self.assertEqual(status, gateway_cli.EX_TEMPFAIL)
        self.assertIn("1013", stderr)

    async def test_upgrade_statuses_distinguish_unavailable_changing_and_rejected(self) -> None:
        cases = [(503, True), (409, False), (401, False)]
        for status, transient in cases:
            with self.subTest(status=status):
                def reject(connection, request, status=status):
                    return connection.respond(status, "unavailable")

                port = await self._serve(process_request=reject)
                if transient:
                    exit_status, _, stderr = await self._rpc(port)
                    self.assertEqual(exit_status, gateway_cli.EX_TEMPFAIL)
                    self.assertIn(str(status), stderr)
                elif status == 409:
                    with self.assertRaisesRegex(RuntimeError, "Gateway connection rejected \\(HTTP 409\\): unavailable"):
                        await self._rpc(port)
                else:
                    with self.assertRaises(Exception):
                        await self._rpc(port)

    async def test_a_json_rpc_error_keeps_its_response_on_stdout(self) -> None:
        import json

        async def respond(connection) -> None:
            await connection.send(json.dumps({"method": "ready", "params": {}}))
            async for raw in connection:
                message = json.loads(raw)
                if message.get("method") == "initialize":
                    await connection.send(json.dumps({"id": message["id"], "result": {}}))
                elif message.get("method") == "thread/list":
                    error = {"code": -32603, "message": "spawn failed"}
                    await connection.send(json.dumps({"id": message["id"], "error": error}))

        status, stdout, _ = await self._rpc(await self._serve(respond))
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(stdout)["error"]["code"], -32603)


class ProbeVerdictTests(unittest.IsolatedAsyncioTestCase):
    async def test_a_failed_cleanup_fails_an_otherwise_passing_probe(self) -> None:
        async def release() -> None:
            raise RuntimeError("release refused")

        stderr = io.StringIO()
        with patch("sys.stderr", stderr), self.assertRaisesRegex(verdict.ProbeCleanupError, "release refused"):
            async with verdict.cleanup_after("release the runtime", release):
                pass
        self.assertIn("FAIL release the runtime", stderr.getvalue())

    async def test_a_failed_cleanup_never_masks_the_probe_failure(self) -> None:
        async def release() -> None:
            raise RuntimeError("release refused")

        stderr = io.StringIO()
        with patch("sys.stderr", stderr), self.assertRaisesRegex(RuntimeError, "assertion failed"):
            async with verdict.cleanup_after("release the runtime", release):
                raise RuntimeError("assertion failed")
        self.assertIn("FAIL release the runtime: release refused", stderr.getvalue())

    async def test_a_claude_probe_turn_fails_when_its_runtime_release_fails(self) -> None:
        config = gateway_config.GatewayConfig("gateway.test", 8787, "synthetic", "ws")
        args = gateway_cli.build_parser().parse_args(["e2e-files-live"])
        socket = AsyncMock()
        socket.__aenter__.return_value = socket
        rpc = AsyncMock(side_effect=[
            ({"thread": {"id": "claude_exact"}}, 0, 0),
            ({"delta": None}, 0, 0),
            ({"turn": {"id": "new-turn"}}, 0, 0),
            RuntimeError("claude/thread/release failed"),
        ])
        events = AsyncMock(side_effect=[
            {"method": "turn/completed", "params": {"threadId": "claude_exact", "turn": {"id": "new-turn", "status": "completed"}}},
        ])
        with patch.object(turns, "_ws_connect", AsyncMock(return_value=socket)), \
             patch.object(turns, "_drain_ready", AsyncMock()), \
             patch.object(turns, "_initialize", AsyncMock()), \
             patch.object(turns, "_timed_rpc", rpc), \
             patch.object(turns, "_ws_recv_json", events), \
             patch("sys.stderr", io.StringIO()), \
             self.assertRaises(verdict.ProbeCleanupError):
            await turns._probe_turn(args, config, "claude", "again")


class JournalProbeTests(unittest.IsolatedAsyncioTestCase):
    async def _run(self, response_client: int, *, status: str = "completed") -> int:
        config = gateway_config.GatewayConfig("gateway.test", 8787, "synthetic", "ws")
        args = gateway_cli.build_parser().parse_args(["e2e-journal-live", "--journal-timeout", "0.01"])
        socket = AsyncMock()
        socket.__aenter__.return_value = socket
        rpc = AsyncMock(side_effect=[
            ({"thread": {"id": "thread-1"}}, 0, 0),
            ({"delta": None}, 0, 0),
            ({"turn": {"id": "turn-1"}}, 0, 0),
            ({}, 0, 0),
        ])
        events = AsyncMock(return_value={
            "method": "turn/completed",
            "params": {"threadId": "thread-1", "turn": {"id": "turn-1", "status": status}},
        })
        thread = {"threadId": "thread-1"}
        records = [
            {**thread, "kind": "notify", "method": "turn/started", "turnId": "turn-1", "payload": {}},
            {**thread, "kind": "notify", "method": "turn/completed", "turnId": "turn-1", "payload": {}},
            {**thread, "kind": "rpc", "direction": "request", "method": "turn/start", "clientId": 1, "id": 5},
            {"kind": "rpc", "direction": "response", "method": "turn/start", "clientId": response_client, "id": 5, "ok": True},
            {**thread, "kind": "runtime", "event": "spawn"},
        ]
        with patch.object(diagnostics, "_resolve_config", return_value=config), \
             patch.object(diagnostics, "_ws_connect", AsyncMock(return_value=socket)), \
             patch.object(diagnostics, "_drain_ready", AsyncMock()), \
             patch.object(diagnostics, "_initialize", AsyncMock()), \
             patch.object(diagnostics, "_timed_rpc", rpc), \
             patch.object(turns, "_timed_rpc", rpc), \
             patch.object(diagnostics, "_ws_recv_json", events), \
             patch.object(diagnostics, "_journal_read", return_value=[("", record) for record in records]), \
             patch.object(diagnostics.asyncio, "sleep", AsyncMock()), \
             redirect_stdout(io.StringIO()):
            return await diagnostics.cmd_e2e_journal_live(args)

    async def test_the_probes_own_turn_start_response_passes(self) -> None:
        self.assertEqual(await self._run(response_client=1), 0)

    async def test_another_clients_turn_start_response_is_not_evidence(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "rpc response turn/start"):
            await self._run(response_client=2)

    async def test_a_turn_that_did_not_complete_fails_the_probe(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "status failed"):
            await self._run(response_client=1, status="failed")


class TurnSetupReceiptTests(unittest.IsolatedAsyncioTestCase):
    async def test_configuration_failures_record_non_submission_for_both_providers(self) -> None:
        import tempfile

        for command, handler in (("turn", gateway_cli.cmd_turn), ("claude-turn", gateway_cli.cmd_claude_turn)):
            for failure in ("environment_timeout", "hostname_timeout", "unavailable"):
                timeout = failure != "unavailable"
                with self.subTest(command=command, failure=failure), tempfile.TemporaryDirectory() as directory:
                    path = Path(directory) / "gateway.jsonl"
                    arguments = ["--ssh-host", "unreachable", "--scheme", "ws", "--local-config", str(Path(directory) / "missing.json"), command]
                    arguments += ["--prompt", "run"] if command == "turn" else ["run"]
                    args = gateway_cli.build_parser().parse_args([*arguments, "--event-log", str(path)])
                    error = gateway_config.subprocess.TimeoutExpired("ssh", 10) if timeout else FileNotFoundError("ssh unavailable")
                    if failure == "hostname_timeout":
                        environment = "RC_CODEX_GATEWAY_BIND_HOST=127.0.0.1\nRC_CODEX_GATEWAY_PORT=8787\nRC_CODEX_GATEWAY_AUTH_TOKEN=synthetic\n"
                        error = [gateway_config.subprocess.CompletedProcess("ssh", 0, stdout=environment), gateway_config.subprocess.TimeoutExpired("ssh -G", 5)]
                    with patch.dict(gateway_config.os.environ, {}, clear=True), \
                         patch.object(gateway_config.subprocess, "run", side_effect=error), \
                         patch.object(gateway_cli, "_ws_connect", AsyncMock()) as connect:
                        with self.assertRaises(TimeoutError if timeout else SystemExit):
                            await handler(args)
                    connect.assert_not_called()
                    rows = [json.loads(line) for line in path.read_text().splitlines()]
                    self.assertEqual(rows, [{"type": "dispatch.not_started", "retryable": timeout}])

    async def test_setup_timeout_is_retryable_but_submitted_requests_stay_uncertain(self) -> None:
        import tempfile
        from websockets.asyncio.server import serve

        for blocked_method in ("initialize", "thread/start", "turn/start"):
            with self.subTest(blocked_method=blocked_method), tempfile.TemporaryDirectory() as directory:
                received = []

                async def respond(connection) -> None:
                    await connection.send(json.dumps({"method": "ready", "params": {}}))
                    async for raw in connection:
                        request = json.loads(raw)
                        method = request["method"]
                        received.append(method)
                        if "id" not in request:
                            continue
                        if method == blocked_method:
                            continue
                        result = {"thread": {"id": "claude_exact"}} if method == "thread/start" else {}
                        await connection.send(json.dumps({"id": request["id"], "result": result}))

                async with serve(respond, "127.0.0.1", 0) as server:
                    port = server.sockets[0].getsockname()[1]
                    config = gateway_config.GatewayConfig("127.0.0.1", port, "synthetic", "ws")
                    event_log = Path(directory) / "gateway.jsonl"
                    args = gateway_cli.build_parser().parse_args(
                        ["claude-turn", "run", "--timeout", "0.05", "--event-log", str(event_log)]
                    )
                    with patch.object(gateway_cli, "_resolve_config", return_value=config):
                        with self.assertRaises(TimeoutError):
                            await gateway_cli.cmd_claude_turn(args)
                    self.assertIn(blocked_method, received)
                    rows = [json.loads(line) for line in event_log.read_text().splitlines()]
                    markers = [row for row in rows if row.get("type") == "dispatch.not_started"]
                    self.assertEqual(markers, [{"type": "dispatch.not_started", "retryable": True}] if blocked_method == "initialize" else [])

    async def test_gateway_refusals_are_not_started_but_other_errors_stay_uncertain(self) -> None:
        import tempfile
        from websockets.asyncio.server import serve

        signed_out = {"code": -32003, "message": "Account is changing or requires sign-in"}
        refused = {"code": -32003, "message": "Account changed or was disabled; reopen the account", "data": {"retryable": False}}
        busy = {"code": -32003, "message": "This conversation has a pending command; retry after it finishes", "data": {"kind": "conversationBusy", "retryable": True, "retryAfterMs": 2000}}
        internal = {"code": -32603, "message": "failed writing Claude prompt"}
        unknown = {"code": -32003, "message": "unknown", "data": {"kind": "queueChangeUncertain", "threadId": "claude_exact"}}
        cases = [
            ("turn/start", signed_out, [{"type": "dispatch.not_started", "retryable": True}]),
            ("thread/start", signed_out, [{"type": "dispatch.not_started", "retryable": True}]),
            ("turn/start", refused, [{"type": "dispatch.not_started", "retryable": False}]),
            ("turn/start", busy, [{"type": "dispatch.not_started", "retryable": True}]),
            ("turn/start", internal, []),
            ("turn/start", unknown, []),
        ]
        for failing_method, error, expected in cases:
            with self.subTest(method=failing_method, error=error["message"]), tempfile.TemporaryDirectory() as directory:

                async def respond(connection) -> None:
                    await connection.send(json.dumps({"method": "ready", "params": {}}))
                    async for raw in connection:
                        request = json.loads(raw)
                        if "id" not in request:
                            continue
                        if request["method"] == failing_method:
                            await connection.send(json.dumps({"id": request["id"], "error": error}))
                            continue
                        result = {"thread": {"id": "claude_exact"}} if request["method"] == "thread/start" else {}
                        await connection.send(json.dumps({"id": request["id"], "result": result}))

                async with serve(respond, "127.0.0.1", 0) as server:
                    port = server.sockets[0].getsockname()[1]
                    config = gateway_config.GatewayConfig("127.0.0.1", port, "synthetic", "ws")
                    event_log = Path(directory) / "gateway.jsonl"
                    args = gateway_cli.build_parser().parse_args(
                        ["claude-turn", "run", "--timeout", "1", "--event-log", str(event_log)]
                    )
                    with patch.object(gateway_cli, "_resolve_config", return_value=config):
                        with self.assertRaisesRegex(RuntimeError, error["message"]):
                            await gateway_cli.cmd_claude_turn(args)
                    rows = [json.loads(line) for line in event_log.read_text().splitlines()]
                    self.assertEqual([row for row in rows if row.get("type") == "dispatch.not_started"], expected)

    async def test_codex_dispatch_tier_and_exact_lifecycle(self) -> None:
        import tempfile
        from websockets.asyncio.server import serve

        requests = []

        async def respond(connection) -> None:
            await connection.send(json.dumps({"method": "ready", "params": {}}))
            async for raw in connection:
                request = json.loads(raw)
                if "id" not in request:
                    continue
                requests.append(request)
                results = {"thread/start": {"thread": {"id": "codex_exact"}},
                           "thread/resume": {"thread": {"id": "codex_exact"}},
                           "turn/start": {"turn": {"id": "turn_exact"}}}
                await connection.send(json.dumps({"id": request["id"], "result": results.get(request["method"], {})}))
                if request["method"] == "turn/start":
                    await connection.send(json.dumps({
                        "method": "turn/completed",
                        "params": {"threadId": "codex_exact", "turn": {"id": "turn_exact", "status": "completed"}},
                    }))

        for resume in (False, True):
            for tier in (None, "standard", "fast"):
                with self.subTest(resume=resume, tier=tier), tempfile.TemporaryDirectory() as directory:
                    requests.clear()
                    async with serve(respond, "127.0.0.1", 0) as server:
                        port = server.sockets[0].getsockname()[1]
                        config = gateway_config.GatewayConfig("127.0.0.1", port, "synthetic", "ws")
                        event_log = Path(directory) / "gateway.jsonl"
                        flags = ["turn", "--prompt", "run", "--purpose", "automation", "--timeout", "1", "--event-log", str(event_log)]
                        if resume:
                            flags += ["--resume", "codex_exact"]
                        if tier:
                            flags += ["--service-tier", tier]
                        args = gateway_cli.build_parser().parse_args(flags)
                        with patch.object(gateway_cli, "_resolve_config", return_value=config), redirect_stdout(io.StringIO()):
                            self.assertEqual(await gateway_cli.cmd_turn(args), 0)
                    dispatches = [r for r in requests if r["method"] in {"thread/start", "thread/resume", "turn/start"}]
                    self.assertEqual(len(dispatches), 2)
                    for request in dispatches:
                        # Missing differs from null: omission inherits the user's Fast setting.
                        self.assertIn("serviceTier", request["params"])
                        self.assertEqual(request["params"]["serviceTier"], "priority" if tier == "fast" else None)
                    rows = [json.loads(line) for line in event_log.read_text().splitlines()]
                    lifecycle = [row for row in rows if row.get("type") in ("thread.started", "turn.started")]
                    self.assertEqual(lifecycle, [
                        {"type": "thread.started", "thread_id": "codex_exact"},
                        {"type": "turn.started", "thread_id": "codex_exact", "turn_id": "turn_exact"},
                    ])


if __name__ == "__main__":
    unittest.main()
