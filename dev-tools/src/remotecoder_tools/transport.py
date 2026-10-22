import hashlib
import hmac
import ipaddress
import ssl
import time
from dataclasses import dataclass
from functools import partial
from typing import TYPE_CHECKING

import httpx
from cryptography import x509
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from websockets.asyncio.client import ClientConnection, connect
from websockets.exceptions import InvalidStatus

if TYPE_CHECKING:
    from .config import GatewayConfig


class GatewayIdentityError(RuntimeError):
    pass


class GatewayOpeningTimeout(TimeoutError):
    def __init__(self, stage: str, target: str, elapsed: float, timeout_s: float) -> None:
        super().__init__(f"Gateway {stage} timed out for {target} after {timeout_s:g} seconds")
        self.stage = stage
        self.target = target
        self.elapsed = elapsed
        self.timeout_s = timeout_s


@dataclass(frozen=True)
class GatewayTLSIdentity:
    server_name: str
    spki_sha256: bytes

    def __post_init__(self) -> None:
        if (not self.server_name or len(self.server_name) > 253
                or any(not (c.isascii() and (c.isalnum() or c in "-.")) for c in self.server_name)
                or len(self.spki_sha256) != 32):
            raise GatewayIdentityError("Gateway TLS identity requires a DNS name and a 32-byte SPKI pin")

    def context(self) -> ssl.SSLContext:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        context.minimum_version = ssl.TLSVersion.TLSv1_3
        return context

    def verify(self, peer: ssl.SSLObject | ssl.SSLSocket | None) -> None:
        if peer is None:
            raise GatewayIdentityError("Gateway connection has no TLS peer identity")
        certificate = peer.getpeercert(binary_form=True)
        if not certificate:
            raise GatewayIdentityError("Gateway connection has no TLS certificate")
        key = x509.load_der_x509_certificate(certificate).public_key()
        spki = key.public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
        if not hmac.compare_digest(hashlib.sha256(spki).digest(), self.spki_sha256):
            raise GatewayIdentityError("Gateway TLS SPKI pin mismatch")


def require_secure_transport(cfg: GatewayConfig) -> None:
    if cfg.scheme == "wss":
        return
    if cfg.tls_identity is not None:
        raise GatewayIdentityError("A pinned gateway requires WSS/HTTPS")
    try:
        loopback = ipaddress.ip_address(cfg.host).is_loopback
    except ValueError:
        loopback = cfg.host == "localhost"
    if cfg.scheme != "ws" or not loopback:
        raise GatewayIdentityError("Plain gateway transport is permitted only on loopback; use WSS with verified identity")


class _GatewayConnection(ClientConnection):
    def __init__(self, *args, identity: GatewayTLSIdentity | None, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.identity = identity

    async def handshake(self, *args, **kwargs) -> None:
        if self.identity is not None:
            self.identity.verify(self.transport.get_extra_info("ssl_object"))
        try:
            await super().handshake(*args, **kwargs)
        except InvalidStatus as error:
            if 300 <= error.response.status_code < 400:
                raise GatewayIdentityError("Gateway WebSocket redirects are not permitted") from None
            raise


async def websocket(cfg: GatewayConfig):
    require_secure_transport(cfg)
    options = {"create_connection": partial(_GatewayConnection, identity=cfg.tls_identity)}
    if identity := cfg.tls_identity:
        options.update(ssl=identity.context(), server_hostname=identity.server_name)
    started = time.perf_counter()
    try:
        return await connect(cfg.ws_url, additional_headers={"Authorization": f"Bearer {cfg.token}"},
                             max_size=32 * 1024 * 1024, open_timeout=5, proxy=None, **options)
    except TimeoutError as error:
        raise GatewayOpeningTimeout("WebSocket opening handshake", f"{cfg.host}:{cfg.port}",
                                    time.perf_counter() - started, 5) from error


class _PinnedHTTPTransport(httpx.AsyncBaseTransport):
    def __init__(self, identity: GatewayTLSIdentity) -> None:
        self.identity = identity
        self.transport = httpx.AsyncHTTPTransport(verify=identity.context())

    async def _verify_tls(self, event: str, info: dict) -> None:
        if event == "connection.start_tls.complete":
            stream = info["return_value"]
            try:
                self.identity.verify(stream.get_extra_info("ssl_object"))
            except BaseException:
                await stream.aclose()
                raise

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        if request.url.scheme != "https":
            raise GatewayIdentityError("A pinned gateway requires HTTPS")
        request.extensions["sni_hostname"] = self.identity.server_name
        request.extensions["trace"] = self._verify_tls
        return await self.transport.handle_async_request(request)

    async def aclose(self) -> None:
        await self.transport.aclose()


def http_client(cfg: GatewayConfig, timeout: float) -> httpx.AsyncClient:
    require_secure_transport(cfg)
    transport = _PinnedHTTPTransport(cfg.tls_identity) if cfg.tls_identity is not None else None
    return httpx.AsyncClient(timeout=timeout, transport=transport, trust_env=False)
