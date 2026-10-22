import asyncio
import json
from collections.abc import Callable
from contextlib import asynccontextmanager
from typing import Any
from urllib.parse import parse_qs, urlsplit

from pydantic import Base64Bytes, BaseModel, ConfigDict, SecretStr
from remotecoder_tools.config import GatewayConfig
from remotecoder_tools.rpc import _reader, _ws_recv_json, request_response
from remotecoder_tools.transport import (
    GatewayIdentityError,
    GatewayTLSIdentity,
    websocket,
)
from websockets.asyncio.client import ClientConnection
from websockets.exceptions import ConnectionClosed


def ignore_notification(_: dict[str, Any]) -> None:
    return None


class GatewayPeerIdentity(BaseModel):
    model_config = ConfigDict(extra="forbid")
    serverName: str
    spkiSha256: Base64Bytes


class GatewayConnection(BaseModel):
    model_config = ConfigDict(extra="forbid")
    wsUrl: str
    bearer: SecretStr
    tlsIdentity: GatewayPeerIdentity

    def gateway_config(self) -> GatewayConfig:
        url = urlsplit(self.wsUrl)
        if (url.scheme != "wss" or not url.hostname or url.path != "/ws"
                or url.username or url.password or url.fragment):
            raise GatewayIdentityError("Call worker requires the originating gateway's pinned WSS endpoint")
        query = parse_qs(url.query, keep_blank_values=True, strict_parsing=True)
        if query and (set(query) != {"accountId", "accountGeneration"}
                      or any(len(values) != 1 or not values[0] for values in query.values())):
            raise GatewayIdentityError("Call worker requires an exact gateway account route")
        identity = GatewayTLSIdentity(self.tlsIdentity.serverName, self.tlsIdentity.spkiSha256)
        account_id = query["accountId"][0] if query else None
        generation = int(query["accountGeneration"][0]) if query else None
        if generation is not None and generation < 0:
            raise GatewayIdentityError("Call worker account generation cannot be negative")
        return GatewayConfig(url.hostname, url.port or 443, self.bearer.get_secret_value(), "wss",
                             account_id=account_id, account_generation=generation, tls_identity=identity)


class GatewayError(RuntimeError):
    def __init__(self, message: str, code: int | None = None):
        super().__init__(message)
        self.code = code


class GatewayRPC:
    def __init__(self, socket: ClientConnection):
        self.socket = socket
        self.pending = _reader(socket).pending
        self.sequence = 0
        self.on_notification: Callable[[dict[str, Any]], None] = ignore_notification
        self.closed = asyncio.Event()

    @classmethod
    @asynccontextmanager
    async def connect(cls, config: GatewayConfig):
        async with await websocket(config) as socket:
            rpc = cls(socket)
            reader = asyncio.create_task(rpc.receive())
            try:
                await rpc.call(
                    "initialize",
                    {
                        "clientInfo": {
                            "name": "remotecoder-agent-calls",
                            "title": "RemoteCoder agent calls",
                            "version": "0.1.0",
                        },
                        "capabilities": {"experimentalApi": True},
                    },
                    deadline_seconds=10,
                )
                await socket.send(json.dumps({"method": "initialized", "params": {}}))
                yield rpc
            finally:
                reader.cancel()
                await asyncio.gather(reader, return_exceptions=True)

    async def receive(self):
        try:
            while True:
                message = await _ws_recv_json(self.socket, timeout_s=None)
                request_id = message.get("id")
                if "method" in message:
                    if request_id is not None:
                        await asyncio.wait_for(
                            self.socket.send(
                                json.dumps(
                                    {
                                        "id": request_id,
                                        "error": {
                                            "code": -32601,
                                            "message": "Server requests are not supported by the call media client",
                                        },
                                    }
                                )
                            ),
                            5,
                        )
                    else:
                        self.on_notification(message)
        except ConnectionClosed:
            pass
        except Exception:
            await self.socket.close()
            raise
        finally:
            self.closed.set()

    async def call(
        self, method: str, params: dict[str, Any], deadline_seconds: float = 35
    ):
        self.sequence += 1
        request_id = self.sequence
        try:
            response, _, _ = await request_response(
                self.socket,
                req_id=request_id,
                payload=json.dumps({"id": request_id, "method": method, "params": params}),
                timeout_s=deadline_seconds,
                send_timeout_s=5,
            )
        except ConnectionClosed as error:
            self.closed.set()
            raise GatewayError("Gateway connection closed") from error
        if (error := response.get("error")) is not None:
            detail = error if isinstance(error, dict) else {}
            code = detail.get("code")
            raise GatewayError(
                f"{method}: {detail.get('message', 'request rejected')}",
                code if isinstance(code, int) else None,
            )
        result = response.get("result")
        if not isinstance(result, dict):
            raise GatewayError(f"{method}: the response carried no result object")
        return result
