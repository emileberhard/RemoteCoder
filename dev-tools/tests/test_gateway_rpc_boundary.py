import asyncio
import base64
import io
import json
import ssl
import sys
import tempfile
import time
import unittest
from contextlib import nullcontext, redirect_stderr, redirect_stdout
from datetime import UTC, datetime
from http import HTTPStatus
from pathlib import Path
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from websockets.asyncio.server import serve

from remotecoder_tools import gateway_cli, transport


class GatewayRPCBoundaryTests(unittest.IsolatedAsyncioTestCase):
    async def run_cli(self, scenario, command, method, *, timeout_s=0.5):
        requests = []
        connections = 0
        upgrades = 0
        release = asyncio.Event()

        async def upgrade(connection, request):
            nonlocal upgrades
            upgrades += 1
            if scenario == "opening timeout always" or (scenario == "opening timeout once" and upgrades == 1):
                await release.wait()
                return connection.respond(HTTPStatus.SERVICE_UNAVAILABLE, "fixture opening cancelled")
            if scenario == "authentication failure":
                return connection.respond(HTTPStatus.UNAUTHORIZED, "fixture authentication rejection")

        async def handler(connection):
            nonlocal connections
            connections += 1
            if scenario == "ready and close stall":
                connection.transport.pause_reading()
                await release.wait()
                connection.transport.resume_reading()
                await connection.wait_closed()
                return
            if scenario == "ready timeout always":
                await connection.wait_closed()
                return
            await connection.send(json.dumps({"method": "ready", "params": {}}))
            async for frame in connection:
                request = json.loads(frame)
                operation = request.get("method")
                requests.append(operation)
                if operation == "initialize":
                    if scenario == "initialize timeout":
                        continue
                    response = {"result": {}}
                elif operation == method:
                    if scenario == "response timeout":
                        continue
                    response = ({"error": {"code": -32602, "message": "fixture rejection"}}
                                if scenario == "rejection" else {"result": {"accepted": True}})
                else:
                    continue
                await connection.send(json.dumps({"id": request["id"], **response}))

        stdout, stderr = io.StringIO(), io.StringIO()
        async with serve(handler, "127.0.0.1", 0, process_request=upgrade) as server:
            port = server.sockets[0].getsockname()[1]
            operation = ["rpc", "--method", method] if command == "rpc" else [command]
            argv = ["rc-gateway", "--host", "127.0.0.1", "--port", str(port),
                    "--scheme", "ws", "--no-ssh-env", "--token", "private-fixture-bearer",
                    *operation, "--timeout", str(timeout_s)]
            send = transport._GatewayConnection.send

            async def uncertain_send(connection, frame, *args, **kwargs):
                await send(connection, frame, *args, **kwargs)
                if json.loads(frame).get("method") == method:
                    raise TimeoutError("fixture application-send acknowledgement lost")

            write = (patch.object(transport._GatewayConnection, "send", uncertain_send)
                     if scenario == "uncertain send" else nullcontext())
            with patch.object(sys, "argv", argv), redirect_stdout(stdout), redirect_stderr(stderr), write:
                try:
                    status = await gateway_cli._amain()
                finally:
                    release.set()
        return status, stdout.getvalue(), stderr.getvalue(), requests, connections, port, upgrades

    async def test_setup_stall_exhausts_one_shared_deadline_without_dispatch(self):
        timeout_s = 0.2
        for scenario, stage, expected_connections in (("ready timeout always", "ready notification", 1),
                                                       ("ready and close stall", "ready notification", 1),
                                                       ("opening timeout once", "WebSocket opening handshake", 0)):
            for command, method, expected_status in (("rpc", "claude/message", 75),
                                                      ("e2e-reads", "thread/list", 2)):
                with self.subTest(command=command, stage=stage, scenario=scenario):
                    started = time.perf_counter()
                    status, stdout, stderr, requests, connections, port, upgrades = await self.run_cli(
                        scenario, command, method, timeout_s=timeout_s)
                    elapsed = time.perf_counter() - started
                    self.assertLess(elapsed, timeout_s + 0.1, f"setup exceeded its {timeout_s}s budget: {elapsed}s")
                    self.assertEqual(status, expected_status)
                    self.assertEqual(stdout, "")
                    self.assertIn(stage, stderr)
                    self.assertIn(method, stderr)
                    self.assertIn(f"127.0.0.1:{port}", stderr)
                    self.assertNotIn("private-fixture-bearer", stderr)
                    self.assertNotIn("gateway_opening_retry", stderr)
                    self.assertEqual(requests, [])
                    self.assertEqual(connections, expected_connections)
                    self.assertEqual(upgrades, 1)

    async def test_plain_rpc_response_timeout_names_the_sent_method_and_preserves_exit_2(self):
        for method in ("claude/message", "thread/list"):
            with self.subTest(method=method):
                status, stdout, stderr, requests, connections, port, upgrades = await self.run_cli("response timeout", "rpc", method)
                self.assertEqual(status, 2)
                self.assertEqual(stdout, "")
                self.assertIn(method, stderr)
                self.assertIn("response", stderr)
                self.assertIn(f"127.0.0.1:{port}", stderr)
                self.assertNotIn("private-fixture-bearer", stderr)
                self.assertEqual(requests, ["initialize", "initialized", method])
                self.assertEqual(connections, 1)
                self.assertEqual(upgrades, 1)
                self.assertNotIn("gateway_opening_retry", stderr)

    async def test_initialize_timeout_names_the_pending_method_and_preserves_exit_75(self):
        status, stdout, stderr, requests, connections, port, upgrades = await self.run_cli("initialize timeout", "rpc", "claude/message")
        self.assertEqual(status, 75)
        self.assertEqual(stdout, "")
        self.assertIn("claude/message", stderr)
        self.assertIn("initialize", stderr)
        self.assertIn(f"127.0.0.1:{port}", stderr)
        self.assertNotIn("private-fixture-bearer", stderr)
        self.assertEqual(requests, ["initialize"])
        self.assertEqual(connections, 1)
        self.assertEqual(upgrades, 1)
        self.assertNotIn("gateway_opening_retry", stderr)

    async def test_json_rpc_rejection_stays_raw_stdout_with_exit_0(self):
        status, stdout, stderr, requests, connections, port, upgrades = await self.run_cli("rejection", "rpc", "claude/message")
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(stdout), {"id": 1, "error": {"code": -32602, "message": "fixture rejection"}})
        self.assertEqual(stderr, "")
        self.assertEqual(requests.count("claude/message"), 1)
        self.assertEqual(connections, 1)

    async def test_opening_timeout_retries_once_with_remaining_budget_before_sending_the_application_method(self):
        timeout_s = 6
        started = time.perf_counter()
        status, stdout, stderr, requests, connections, port, upgrades = await self.run_cli(
            "opening timeout once", "rpc", "claude/message", timeout_s=timeout_s)
        self.assertLess(time.perf_counter() - started, timeout_s)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(json.loads(stdout), {"id": 1, "result": {"accepted": True}})
        events = [json.loads(line) for line in stderr.splitlines() if line.startswith("{")]
        self.assertEqual([event["event"] for event in events], ["gateway_opening_retry", "gateway_opening_recovered"])
        self.assertEqual(events[0]["stage"], "WebSocket opening handshake")
        self.assertEqual(events[0]["target"], f"127.0.0.1:{port}")
        self.assertEqual(events[0]["method"], "claude/message")
        self.assertGreater(events[0]["elapsedSeconds"], 0)
        self.assertEqual(events[0]["timeoutSeconds"], 5)
        self.assertNotIn("private-fixture-bearer", stderr)
        self.assertEqual(requests, ["initialize", "initialized", "claude/message"])
        self.assertEqual(upgrades, 2)

    async def test_two_opening_timeouts_stop_after_one_logged_retry_within_the_budget_without_sending_any_request(self):
        timeout_s = 6
        started = time.perf_counter()
        status, stdout, stderr, requests, connections, port, upgrades = await self.run_cli(
            "opening timeout always", "rpc", "claude/message", timeout_s=timeout_s)
        self.assertLess(time.perf_counter() - started, timeout_s + 0.1)
        self.assertEqual(status, 75)
        self.assertEqual(stdout, "")
        events = [json.loads(line) for line in stderr.splitlines() if line.startswith("{")]
        self.assertEqual([event["event"] for event in events], ["gateway_opening_retry"])
        self.assertEqual(events[0]["stage"], "WebSocket opening handshake")
        self.assertIn("claude/message", stderr)
        self.assertIn("WebSocket opening handshake", stderr)
        self.assertIn(f"127.0.0.1:{port}", stderr)
        self.assertEqual(requests, [])
        self.assertEqual(connections, 0)
        self.assertEqual(upgrades, 2)

    async def test_authentication_rejection_is_not_retried(self):
        status, stdout, stderr, requests, connections, port, upgrades = await self.run_cli("authentication failure", "rpc", "claude/message")
        self.assertEqual(status, 2)
        self.assertEqual(stdout, "")
        self.assertNotIn("gateway_opening_retry", stderr)
        self.assertNotIn("private-fixture-bearer", stderr)
        self.assertEqual(requests, [])
        self.assertEqual(connections, 0)
        self.assertEqual(upgrades, 1)

    async def test_application_send_timeout_is_uncertain_and_never_retried(self):
        status, stdout, stderr, requests, connections, port, upgrades = await self.run_cli("uncertain send", "rpc", "claude/message")
        self.assertEqual(status, 2)
        self.assertEqual(stdout, "")
        self.assertIn("claude/message", stderr)
        self.assertIn("RPC send", stderr)
        self.assertIn(f"127.0.0.1:{port}", stderr)
        self.assertNotIn("gateway_opening_retry", stderr)
        self.assertEqual(requests, ["initialize", "initialized", "claude/message"])
        self.assertEqual(connections, 1)
        self.assertEqual(upgrades, 1)

    async def test_read_probe_retries_only_opening_and_never_replays_a_sent_read(self):
        for scenario, upgrades, requests in (("ready timeout always", 1, []),
                                             ("response timeout", 1, ["initialize", "initialized", "thread/list"])):
            with self.subTest(scenario=scenario):
                status, stdout, stderr, actual_requests, connections, port, actual_upgrades = await self.run_cli(scenario, "e2e-reads", "thread/list")
                self.assertEqual(status, 2)
                self.assertEqual(stdout, "")
                self.assertIn("thread/list", stderr)
                self.assertIn(f"127.0.0.1:{port}", stderr)
                self.assertEqual(actual_requests, requests)
                self.assertEqual(actual_upgrades, upgrades)
                self.assertEqual(stderr.count('"event": "gateway_opening_retry"'), upgrades - 1)

    async def test_wrong_tls_pin_fails_before_bearer_upgrade_without_retry(self):
        key = ec.derive_private_key(1, ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "gateway.fixture")])
        certificate = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                       .public_key(key.public_key()).serial_number(1)
                       .not_valid_before(datetime(2020, 1, 1, tzinfo=UTC))
                       .not_valid_after(datetime(2040, 1, 1, tzinfo=UTC)).sign(key, hashes.SHA256()))
        handshakes, upgrades = [], []

        async def upgrade(connection, request):
            upgrades.append(request.headers.get("Authorization"))

        async def handler(connection):
            await connection.wait_closed()

        with tempfile.TemporaryDirectory() as directory:
            cert_file, key_file = Path(directory) / "cert.pem", Path(directory) / "key.pem"
            cert_file.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
            key_file.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                  serialization.NoEncryption()))
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert_file, key_file)
            context.set_servername_callback(lambda connection, name, context: handshakes.append(name))
            async with serve(handler, "127.0.0.1", 0, ssl=context, process_request=upgrade) as server:
                port = server.sockets[0].getsockname()[1]
                argv = ["rc-gateway", "--host", "127.0.0.1", "--port", str(port), "--scheme", "wss",
                        "--spki-sha256", base64.b64encode(bytes(32)).decode(), "--no-ssh-env",
                        "--token", "private-fixture-bearer", "rpc", "--method", "claude/message", "--timeout", "0.5"]
                stdout, stderr = io.StringIO(), io.StringIO()
                with patch.object(sys, "argv", argv), redirect_stdout(stdout), redirect_stderr(stderr):
                    self.assertEqual(await gateway_cli._amain(), 2)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("Gateway TLS SPKI pin mismatch", stderr.getvalue())
        self.assertNotIn("gateway_opening_retry", stderr.getvalue())
        self.assertNotIn("private-fixture-bearer", stderr.getvalue())
        self.assertEqual(len(handshakes), 1)
        self.assertEqual(upgrades, [])


if __name__ == "__main__":
    unittest.main()
