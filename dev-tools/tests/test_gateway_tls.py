import base64
import hashlib
import socket
import ssl
import threading
from datetime import UTC, datetime
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from websockets.asyncio.server import serve

from remotecoder_tools.config import (
    GatewayConfig,
    _gateway_tls_identity,
    _resolve_config,
)
from remotecoder_tools.gateway_cli import _transient_connection_failure, build_parser
from remotecoder_tools.rpc import _ws_connect
from remotecoder_tools.transport import GatewayIdentityError, GatewayTLSIdentity


@pytest.mark.parametrize("channel", ["websocket", "http"])
async def test_tls_pin_is_checked_before_bearer_bytes_on_the_actual_connection(tmp_path, channel):
    key = ec.derive_private_key(1, ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "gateway.fixture")])
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

    async def request(connection, incoming):
        received.append(incoming.headers.get("Authorization"))
        if incoming.path == "/health":
            return connection.respond(HTTPStatus.OK, '{"status":"ok"}')

    async def handle(connection):
        await connection.wait_closed()

    async with serve(handle, "127.0.0.1", 0, ssl=context, process_request=request) as server:
        port = server.sockets[0].getsockname()[1]
        spki = key.public_key().public_bytes(serialization.Encoding.DER,
                                            serialization.PublicFormat.SubjectPublicKeyInfo)
        pin = hashlib.sha256(spki).digest()
        wrong = GatewayConfig("127.0.0.1", port, "synthetic-bearer", "wss",
                              tls_identity=GatewayTLSIdentity("gateway.fixture", bytes(32)))

        async def connect(cfg):
            if channel == "websocket":
                async with await _ws_connect(cfg):
                    pass
            else:
                async with cfg.http_client(timeout=2) as client:
                    response = await client.get(cfg.http_base + "/health",
                                                headers={"Authorization": "Bearer " + cfg.token})
                    assert response.json() == {"status": "ok"}

        with pytest.raises(GatewayIdentityError, match="SPKI pin mismatch"):
            await connect(wrong)
        assert received == []
        correct = GatewayConfig("127.0.0.1", port, "synthetic-bearer", "wss",
                                tls_identity=GatewayTLSIdentity("gateway.fixture", pin))
        await connect(correct)
        assert received == ["Bearer synthetic-bearer"]
        assert server_names == ["gateway.fixture", "gateway.fixture"]


def test_same_host_dial_address_keeps_the_canonical_tls_identity(monkeypatch):
    identity = GatewayTLSIdentity("workstation.local", bytes(32))
    calls = []

    def lookup(host, token, health_port):
        calls.append((host, token, health_port))
        return 8789, identity

    monkeypatch.setattr("remotecoder_tools.config._gateway_tls_identity", lookup)
    monkeypatch.setattr("remotecoder_tools.config._ssh_read_env", lambda host, path: "RC_CODEX_GATEWAY_PORT=8787")
    args = build_parser().parse_args(["--ssh-host", "workstation", "--host", "127.0.0.1",
                                     "--port", "8789", "--token", "synthetic", "config"])
    cfg = _resolve_config(args)
    assert cfg.ws_url == "wss://127.0.0.1:8789/ws"
    assert cfg.http_base == "https://127.0.0.1:8789"
    assert cfg.tls_identity == identity
    assert calls == [("workstation", "synthetic", 8787)]


def test_remote_plain_transport_and_malformed_pins_fail_before_dialing():
    for extra in [[], ["--scheme", "ws"], ["--scheme", "wss", "--spki-sha256", base64.b64encode(b"short").decode()]]:
        args = build_parser().parse_args(["--no-ssh-env", "--host", "remote.fixture", "--port", "8787",
                                         "--token", "synthetic", *extra, "config"])
        with pytest.raises((GatewayIdentityError, SystemExit)):
            _resolve_config(args)


async def test_gateway_redirect_is_rejected_before_the_second_endpoint_upgrade():
    upgrades = []
    payloads = []

    async def target(connection):
        upgrades.append(connection.request.path)
        async for payload in connection:
            payloads.append(payload)

    async with serve(target, "127.0.0.1", 0) as destination:
        destination_port = destination.sockets[0].getsockname()[1]

        async def redirect(connection, request):
            response = connection.respond(HTTPStatus.TEMPORARY_REDIRECT, "Redirect refused by the client")
            response.headers["Location"] = f"ws://127.0.0.1:{destination_port}/redirected"
            return response

        async with serve(target, "127.0.0.1", 0, process_request=redirect) as origin:
            cfg = GatewayConfig("127.0.0.1", origin.sockets[0].getsockname()[1], "synthetic", "ws")
            with pytest.raises(GatewayIdentityError, match="redirects are not permitted"):
                async with await _ws_connect(cfg) as connection:
                    await connection.send('{"params":{"token":"private-fixture"}}')
    assert upgrades == []
    assert payloads == []


def test_identity_discovery_connection_refusal_remains_retryable():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    with pytest.raises(ConnectionError, match="TLS identity health request.*unavailable") as raised:
        _gateway_tls_identity(None, "private-fixture-bearer", port)
    assert _transient_connection_failure(raised.value, sent=False)
    assert "private-fixture-bearer" not in str(raised.value)


@pytest.mark.parametrize(("status", "body", "retryable"), [
    (None, b"", True),
    (503, b"unavailable", True),
    (401, b"unauthorized", False),
    (200, b'{"lanEndpoint":{"host":"fixture.local","port":8789,"spkiSha256":"short"}}', False),
])
def test_identity_discovery_distinguishes_unavailable_health_from_invalid_identity(status, body, retryable):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if status is None:
                return
            self.send_response(status)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):
            pass

    with HTTPServer(("127.0.0.1", 0), Handler) as server:
        server.timeout = 2
        thread = threading.Thread(target=server.handle_request)
        thread.start()
        try:
            with pytest.raises((ConnectionError, GatewayIdentityError)) as raised:
                _gateway_tls_identity(None, "private-fixture-bearer", server.server_port)
            assert _transient_connection_failure(raised.value, sent=False) is retryable
            assert "private-fixture-bearer" not in str(raised.value)
        finally:
            thread.join(timeout=5)
        assert not thread.is_alive()
