import asyncio
import io
import subprocess
import sys
import unittest
from contextlib import redirect_stderr, suppress
from unittest.mock import AsyncMock, patch

import httpx

from remotecoder_tools import config, gateway_cli, rpc, transport


class GatewayTimeoutTests(unittest.IsolatedAsyncioTestCase):
    async def test_opening_handshake_timeout_names_the_configured_target(self):
        cfg = config.GatewayConfig("fixture.test", 9443, "private-fixture-bearer", "wss")
        with patch.object(transport, "connect", AsyncMock(side_effect=TimeoutError)):
            with self.assertRaisesRegex(TimeoutError, "WebSocket opening handshake.*fixture.test:9443") as raised:
                await transport.websocket(cfg)
        self.assertNotIn(cfg.token, str(raised.exception))

    async def test_frame_ready_initialize_and_rpc_timeouts_name_the_stage_and_peer(self):
        for stage in ("frame wait", "ready notification", "initialize response", "RPC send", "RPC response"):
            with self.subTest(stage=stage):
                socket = AsyncMock()
                socket.remote_address = ("fixture.test", 9443)

                async def blocked(*args):
                    await asyncio.Event().wait()

                socket.recv.side_effect = blocked
                if stage == "RPC send":
                    socket.send.side_effect = blocked
                try:
                    with self.assertRaisesRegex(TimeoutError, stage + ".*fixture.test:9443"):
                        if stage == "frame wait":
                            await rpc._ws_recv_json(socket, timeout_s=0.005)
                        elif stage == "ready notification":
                            await rpc._drain_ready(socket, timeout_s=0.005)
                        elif stage == "initialize response":
                            await rpc._initialize(socket, timeout_s=0.005)
                        elif stage == "RPC send":
                            await rpc.request_response(socket, req_id=7, payload='{"method":"thread/list"}',
                                                       timeout_s=1, send_timeout_s=0.005)
                        else:
                            await rpc._timed_rpc(socket, req_id=7, method="thread/list", params={}, timeout_s=0.005)
                finally:
                    task = rpc._reader(socket).task
                    if task is not None:
                        task.cancel()
                        with suppress(asyncio.CancelledError):
                            await task

    async def test_claude_health_timeout_names_the_http_target_without_credentials(self):
        cfg = config.GatewayConfig("fixture.test", 9443, "private-fixture-bearer", "wss")
        client = AsyncMock()
        client.get.side_effect = httpx.ReadTimeout("private-fixture-bearer")
        manager = AsyncMock()
        manager.__aenter__.return_value = client
        with patch.object(config.GatewayConfig, "http_client", return_value=manager):
            with self.assertRaisesRegex(TimeoutError, "Claude health request.*fixture.test:9443") as raised:
                await rpc._claude_health(cfg)
        self.assertNotIn(cfg.token, str(raised.exception))

    async def test_cli_preserves_timeout_context_and_identifies_unattributed_timeouts(self):
        for detail in ("Gateway ready notification timed out for fixture.test:9443 after 12 seconds", ""):
            with self.subTest(detail=detail):
                stderr = io.StringIO()
                with patch.object(sys, "argv", ["rc-gateway", "--host", "fixture.test", "rpc", "--method", "thread/list"]), \
                     patch.object(gateway_cli, "cmd_rpc", AsyncMock(side_effect=TimeoutError(detail))), redirect_stderr(stderr):
                    self.assertEqual(await gateway_cli._amain(), 2)
                self.assertIn(detail or "rpc timed out for gateway fixture.test during an unattributed stage", stderr.getvalue())


class GatewayIdentityTimeoutTests(unittest.TestCase):
    def test_identity_discovery_distinguishes_ssh_and_owning_host_health_deadlines(self):
        for failure, stage in (
            (subprocess.TimeoutExpired("ssh", 10), "TLS identity discovery through SSH to fixture-host.*10 seconds"),
            (subprocess.CalledProcessError(75, "ssh"), "TLS identity health request to 127.0.0.1:8787 on fixture-host.*5 seconds"),
        ):
            with self.subTest(stage=stage), patch.object(config.subprocess, "run", side_effect=failure):
                with self.assertRaisesRegex(TimeoutError, stage) as raised:
                    config._gateway_tls_identity("fixture-host", "private-fixture-bearer", 8787)
                self.assertNotIn("private-fixture-bearer", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
