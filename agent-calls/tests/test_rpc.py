import asyncio
import base64
import hashlib
import json
import ssl
from datetime import UTC, datetime

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from remotecoder_tools.config import GatewayConfig
from remotecoder_tools.transport import GatewayIdentityError
from websockets.asyncio.server import serve

from agent_calls.rpc import GatewayConnection, GatewayError, GatewayRPC


async def test_gateway_handshake_notifications_and_out_of_order_responses():
    seen = []

    async def gateway(socket):
        assert socket.request.headers["Authorization"] == "Bearer test-token"
        await socket.send(json.dumps({"method": "daemon/ready", "params": {}}))
        await socket.send(
            json.dumps({"method": "remoteControl/status/changed", "params": {}})
        )
        initialize = json.loads(await socket.recv())
        seen.append(initialize["method"])
        assert initialize["params"]["capabilities"]["experimentalApi"]
        await socket.send(json.dumps({"id": initialize["id"], "result": {}}))
        seen.append(json.loads(await socket.recv())["method"])
        first, second = [json.loads(await socket.recv()) for _ in range(2)]
        await socket.send(
            json.dumps(
                {"id": first["id"], "method": "unexpected/request", "params": {}}
            )
        )
        rejected = json.loads(await socket.recv())
        assert rejected["id"] == first["id"]
        assert rejected["error"]["code"] == -32601
        await socket.send(
            json.dumps({"method": "calls/changed", "params": {"state": "connected"}})
        )
        for request in [second, first]:
            await socket.send(
                json.dumps({"id": request["id"], "result": request["params"]})
            )
        await socket.wait_closed()

    async with serve(gateway, "127.0.0.1", 0) as server:
        port = next(iter(server.sockets)).getsockname()[1]
        config = GatewayConfig("127.0.0.1", port, "test-token", "ws")
        async with GatewayRPC.connect(config) as rpc:
            notifications = []
            rpc.on_notification = notifications.append
            assert await asyncio.gather(
                rpc.call("one", {"n": 1}), rpc.call("two", {"n": 2})
            ) == [{"n": 1}, {"n": 2}]
            assert notifications[0]["params"]["state"] == "connected"
            assert not rpc.pending
    assert seen == ["initialize", "initialized"]


async def test_gateway_disconnect_fails_pending_request():
    async def gateway(socket):
        await socket.send(json.dumps({"method": "daemon/ready"}))
        initialize = json.loads(await socket.recv())
        await socket.send(json.dumps({"id": initialize["id"], "result": {}}))
        await socket.recv()
        await socket.recv()
        await socket.close()

    async with serve(gateway, "127.0.0.1", 0) as server:
        port = next(iter(server.sockets)).getsockname()[1]
        async with GatewayRPC.connect(
            GatewayConfig("127.0.0.1", port, "test", "ws")
        ) as rpc:
            with pytest.raises(GatewayError, match="connection closed"):
                await rpc.call("wait", {})
            assert rpc.closed.is_set()
            assert not rpc.pending


async def test_gateway_errors_keep_their_code_and_results_must_be_objects():
    async def gateway(socket):
        await socket.send(json.dumps({"method": "daemon/ready"}))
        initialize = json.loads(await socket.recv())
        await socket.send(json.dumps({"id": initialize["id"], "result": {}}))
        await socket.recv()
        for _ in range(2):
            request = json.loads(await socket.recv())
            if request["method"] == "rejected":
                reply = {"id": request["id"], "error": {"code": -32602, "message": "bad params"}}
            else:
                reply = {"id": request["id"], "result": None}
            await socket.send(json.dumps(reply))
        await socket.wait_closed()

    async with serve(gateway, "127.0.0.1", 0) as server:
        port = next(iter(server.sockets)).getsockname()[1]
        async with GatewayRPC.connect(
            GatewayConfig("127.0.0.1", port, "test", "ws")
        ) as rpc:
            with pytest.raises(GatewayError, match="bad params") as rejected:
                await rpc.call("rejected", {})
            assert rejected.value.code == -32602
            with pytest.raises(GatewayError, match="no result object"):
                await rpc.call("empty", {})


async def test_call_worker_handoff_verifies_the_origin_pin_before_bearer_or_rpc(tmp_path):
    key = ec.derive_private_key(1, ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "origin.fixture.local")])
    certificate = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                   .public_key(key.public_key()).serial_number(1)
                   .not_valid_before(datetime(2020, 1, 1, tzinfo=UTC))
                   .not_valid_after(datetime(2040, 1, 1, tzinfo=UTC))
                   .sign(key, hashes.SHA256()))
    cert_file, key_file = tmp_path / "cert.pem", tmp_path / "key.pem"
    cert_file.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
    key_file.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                         serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert_file, key_file)
    server_names = []
    context.set_servername_callback(lambda socket, server_name, ssl_context: server_names.append(server_name))
    received = []

    async def gateway(socket):
        received.append((socket.request.path, socket.request.headers.get("Authorization")))
        await socket.send(json.dumps({"method": "daemon/ready"}))
        initialize = json.loads(await socket.recv())
        assert initialize["method"] == "initialize"
        await socket.send(json.dumps({"id": initialize["id"], "result": {}}))
        assert json.loads(await socket.recv())["method"] == "initialized"
        await socket.wait_closed()

    async with serve(gateway, "127.0.0.1", 0, ssl=context) as server:
        port = server.sockets[0].getsockname()[1]
        payload = {"wsUrl": f"wss://127.0.0.1:{port}/ws?accountId=owned&accountGeneration=7",
                   "bearer": "synthetic", "tlsIdentity": {"serverName": "origin.fixture.local",
                   "spkiSha256": base64.b64encode(bytes(32)).decode()}}
        wrong = GatewayConnection.model_validate_json(json.dumps(payload)).gateway_config()
        with pytest.raises(GatewayIdentityError, match="pin mismatch"):
            async with GatewayRPC.connect(wrong):
                pass
        assert received == []
        spki = key.public_key().public_bytes(serialization.Encoding.DER,
                                            serialization.PublicFormat.SubjectPublicKeyInfo)
        payload["tlsIdentity"]["spkiSha256"] = base64.b64encode(hashlib.sha256(spki).digest()).decode()
        correct = GatewayConnection.model_validate_json(json.dumps(payload)).gateway_config()
        async with GatewayRPC.connect(correct):
            pass
        payload["wsUrl"] = payload["wsUrl"].replace("wss:", "ws:")
        with pytest.raises(GatewayIdentityError, match="pinned WSS"):
            GatewayConnection.model_validate_json(json.dumps(payload)).gateway_config()
    assert received == [("/ws?accountId=owned&accountGeneration=7", "Bearer synthetic")]
    assert server_names == ["origin.fixture.local", "origin.fixture.local"]
