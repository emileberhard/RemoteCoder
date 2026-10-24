import asyncio
import json
import os
import socket
import sys
import threading
import time
import unittest
from unittest.mock import patch

from websockets.asyncio.server import serve

from remotecoder_tools import proxy
from remotecoder_tools.config import GatewayConfig
from remotecoder_tools.rpc import _open_gateway

READY = {"method": "ready", "params": {}}


class GatewayProxyTests(unittest.IsolatedAsyncioTestCase):
    async def gateway(self, handler):
        server = await serve(handler, "127.0.0.1", 0)
        self.addAsyncCleanup(server.wait_closed)
        self.addCleanup(server.close)
        return server.sockets[0].getsockname()[1]

    async def start_proxy(self, port, stderr=asyncio.subprocess.PIPE):
        process = await asyncio.create_subprocess_exec(
            sys.executable, "-m", "remotecoder_tools.gateway_cli",
            "--host", "127.0.0.1", "--port", str(port), "--scheme", "ws", "--no-ssh-env",
            "--token", "private-fixture-bearer", "proxy", "--timeout", "5",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=stderr,
        )
        self.addCleanup(lambda: process.returncode is None and process.kill())
        return process

    async def test_relays_both_directions_verbatim_and_closes_normally_on_stdin_eof(self):
        received = []
        close_codes = []
        server_request = {"id": 7, "method": "item/tool/requestUserInput", "params": {"threadId": "t1", "questions": []}}
        notification = {"method": "thread/started", "params": {"thread": {"id": "t1"}}}

        async def handler(connection):
            await connection.send(json.dumps(READY))
            async for frame in connection:
                message = json.loads(frame)
                received.append(message)
                if message.get("method") == "initialize":
                    await connection.send(json.dumps({"id": message["id"], "result": {"userAgent": "fixture"}}))
                elif message.get("method") == "thread/start":
                    await connection.send(json.dumps({"id": message["id"], "result": {"thread": {"id": "t1"}}}))
                    await connection.send(json.dumps(notification))
                    await connection.send(json.dumps(server_request))
            close_codes.append(connection.close_code)

        process = await self.start_proxy(await self.gateway(handler))
        client = [
            {"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "fixture"}}},
            {"method": "initialized", "params": {}},
            {"id": 2, "method": "thread/start", "params": {"model": "copilot/gemini-4-argon", "cwd": "/tmp"}},
        ]
        for message in client:
            process.stdin.write(json.dumps(message).encode() + b"\n")
        await process.stdin.drain()
        lines = [json.loads(await asyncio.wait_for(process.stdout.readline(), 5)) for _ in range(4)]
        process.stdin.write(json.dumps({"id": 7, "result": {"answers": {}}}).encode() + b"\n")
        process.stdin.close()

        status = await asyncio.wait_for(process.wait(), 15)
        self.assertEqual(status, 0, await process.stderr.read())
        self.assertEqual(lines, [
            {"id": 1, "result": {"userAgent": "fixture"}},
            {"id": 2, "result": {"thread": {"id": "t1"}}},
            notification,
            server_request,
        ])
        self.assertEqual(received, [*client, {"id": 7, "result": {"answers": {}}}])
        self.assertEqual(close_codes, [1000])
        self.assertEqual(await process.stdout.read(), b"")

    async def test_gateway_restart_close_flushes_queued_messages_to_a_slow_reader_before_its_diagnostic(self):
        gateway_closed = asyncio.Event()

        async def handler(connection):
            await connection.send(json.dumps(READY))
            for sequence in range(64):
                await connection.send(json.dumps({"method": "item/updated", "params": {"sequence": sequence, "text": "x" * 16384}}))
            await connection.close(1012, "planned restart")
            gateway_closed.set()

        process = await self.start_proxy(await self.gateway(handler), stderr=asyncio.subprocess.STDOUT)
        await asyncio.wait_for(gateway_closed.wait(), 5)
        output, status = await asyncio.wait_for(asyncio.gather(process.stdout.read(), process.wait()), 15)
        *messages, diagnostic = output.splitlines()

        self.assertEqual(status, 75, output[-500:])
        self.assertEqual([json.loads(line)["params"]["sequence"] for line in messages], list(range(64)))
        self.assertEqual(diagnostic, b"error: gateway closed the proxy connection (code 1012)")
        process.stdin.close()

    async def test_client_closing_its_reader_ends_the_session_and_closes_the_gateway_connection(self):
        close_codes = []
        reader_closed = asyncio.Event()

        async def handler(connection):
            await connection.send(json.dumps(READY))
            await reader_closed.wait()
            try:
                while True:
                    await connection.send(json.dumps({"method": "item/updated", "params": {"text": "x" * 4096}}))
                    await asyncio.sleep(0.01)
            except Exception:
                pass
            await connection.wait_closed()
            close_codes.append(connection.close_code)

        process = await self.start_proxy(await self.gateway(handler))
        process._transport.get_pipe_transport(1).close()
        reader_closed.set()

        status = await asyncio.wait_for(process.wait(), 15)
        self.assertEqual(status, 0, await process.stderr.read())
        await asyncio.sleep(0.1)
        self.assertEqual(close_codes, [1000])
        process.stdin.close()

    async def test_unreachable_gateway_is_a_transient_failure(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        process = await self.start_proxy(port)
        status = await asyncio.wait_for(process.wait(), 15)
        stderr = await process.stderr.read()

        self.assertEqual(status, 75, stderr)
        self.assertIn(b"transient; retry", stderr)
        self.assertEqual(await process.stdout.read(), b"")
        process.stdin.close()

    async def test_blocked_stdout_cannot_keep_the_proxy_alive_after_the_gateway_closes(self):
        async def handler(connection):
            await connection.send(json.dumps(READY))
            for sequence in range(64):
                await connection.send(json.dumps({"method": "item/updated", "params": {"sequence": sequence, "text": "x" * 8192}}))
            await connection.close(1012, "planned restart")

        port = await self.gateway(handler)
        stdin_read, stdin_write = os.pipe()
        stdout_read, stdout_write = os.pipe()
        self.addCleanup(os.close, stdin_write)
        self.addCleanup(os.close, stdout_read)
        threads = set(threading.enumerate())
        config = GatewayConfig(host="127.0.0.1", port=port, token="private-fixture-bearer", scheme="ws")

        with patch.object(proxy, "FLUSH_GRACE_S", 0.2):
            stdin, stdout = await proxy.stdio_streams(os.fdopen(stdin_read, "rb"), os.fdopen(stdout_write, "wb"))
            async with asyncio.timeout(5):
                async with _open_gateway(config, timeout_s=5, method="proxy") as ws:
                    status = await proxy.bridge(ws, stdin, stdout)

        self.assertEqual(status, 75)
        self.assertEqual(set(threading.enumerate()), threads)


    async def test_diagnostic_after_an_abort_waits_for_a_reader_sharing_the_output_pipe(self):
        async def handler(connection):
            await connection.send(json.dumps(READY))
            for sequence in range(64):
                await connection.send(json.dumps({"method": "item/updated", "params": {"sequence": sequence, "text": "x" * 16384}}))
            await connection.close(1012, "planned restart")

        port = await self.gateway(handler)
        stdin_read, stdin_write = os.pipe()
        output_read, output_write = os.pipe()
        self.addCleanup(os.close, stdin_write)
        merged_stderr = os.fdopen(os.dup(output_write), "w")
        self.addCleanup(merged_stderr.close)
        received = bytearray()

        def read_late():
            time.sleep(1.0)
            with os.fdopen(output_read, "rb") as output:
                received.extend(output.read())

        reader = threading.Thread(target=read_late)
        reader.start()
        config = GatewayConfig(host="127.0.0.1", port=port, token="private-fixture-bearer", scheme="ws")
        with patch.object(proxy, "FLUSH_GRACE_S", 0.2), patch.object(proxy.sys, "stderr", merged_stderr):
            stdin, stdout = await proxy.stdio_streams(os.fdopen(stdin_read, "rb"), os.fdopen(output_write, "wb"))
            async with _open_gateway(config, timeout_s=5, method="proxy") as ws:
                status = await proxy.bridge(ws, stdin, stdout)
        merged_stderr.close()
        await asyncio.to_thread(reader.join, 5)

        self.assertEqual(status, 75)
        self.assertTrue(received.endswith(b"error: gateway closed the proxy connection (code 1012)\n"))

if __name__ == "__main__":
    unittest.main()
