import asyncio
import fcntl
import json
import os
import subprocess
import time
from collections.abc import Callable, Mapping
from concurrent.futures import ThreadPoolExecutor
from enum import StrEnum
from pathlib import Path
from types import MappingProxyType
from typing import Any, Literal
from urllib.parse import urlsplit
from uuid import UUID

import httpx
from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    SecretStr,
    ValidationError,
    field_validator,
)

API_BASE = "https://api.46elks.com/a1"
TERMINAL_STATES = {"success", "busy", "failed"}


class CarrierSettings(BaseModel):
    model_config = ConfigDict(extra="forbid")
    voiceNumberId: str = Field(pattern=r"^n[0-9a-f]+$")
    websocketNumberId: str = Field(pattern=r"^n[0-9a-f]+$")
    publicBaseURL: str
    bindHost: Literal["127.0.0.1"]
    bindPort: int = Field(ge=1024, le=65535)
    stateDirectory: Path
    credentialSource: Path

    @field_validator("publicBaseURL")
    @classmethod
    def public_url(cls, value: str) -> str:
        url = urlsplit(value)
        if (
            url.scheme != "wss"
            or not url.hostname
            or url.path not in {"", "/"}
            or url.query
            or url.fragment
            or url.username
            or url.password
        ):
            raise ValueError("publicBaseURL must be a wss origin without a path")
        return value.rstrip("/")


class CarrierCredentials(BaseModel):
    username: SecretStr
    password: SecretStr
    mediaSecret: SecretStr

    @field_validator("username", "password", "mediaSecret")
    @classmethod
    def not_empty(cls, value: SecretStr) -> SecretStr:
        if not value.get_secret_value():
            raise ValueError("carrier credentials are not provisioned")
        return value


class CarrierNumber(BaseModel):
    number: str
    active: str
    capabilities: list[str]
    websocket_url: str | None = None


class CarrierCall(BaseModel):
    id: str
    state: str | None = None
    duration: int | float | None = None
    cost: int | float | None = None


class CarrierHello(BaseModel):
    t: str
    callid: str
    to: str


class CarrierMessage(BaseModel):
    t: str | None = None
    data: str | None = None
    reason: str | None = None
    message: str | None = None


def parse_boundary[Model: BaseModel](model: type[Model], payload: object, source: str) -> Model:
    try:
        return model.model_validate(payload)
    except ValidationError:
        raise RuntimeError(f"{source} returned an unexpected result") from None


def load_credentials(source: Path) -> CarrierCredentials:
    # The existing shared environment owns these secrets; capture only the
    # three needed values, never an environment dump or shell trace.
    result = subprocess.run(
        [
            "/bin/zsh",
            "-f",
            "-c",
            'source "$1" || exit; printf "%s\\0%s\\0%s" "$PHONE_CALL_AGENT_46ELKS_USERNAME" "$PHONE_CALL_AGENT_46ELKS_PASSWORD" "$AGENT_CALL_MEDIA_SECRET"',
            "agent-call-media",
            str(source),
        ],
        capture_output=True,
        timeout=10,
        check=True,
    )
    fields = result.stdout.decode().split("\0")
    if len(fields) != 3:
        raise RuntimeError("Shared credential source returned an invalid envelope")
    credentials = CarrierCredentials(
        username=fields[0], password=fields[1], mediaSecret=fields[2]
    )
    secret = credentials.mediaSecret.get_secret_value()
    if len(secret) < 32 or not all(char.isalnum() or char in "-_" for char in secret):
        raise RuntimeError(
            "Media credential must contain at least 32 URL-safe characters"
        )
    return credentials


class CarrierAPI:
    def __init__(self, credentials: CarrierCredentials):
        self.client = httpx.AsyncClient(
            base_url=API_BASE,
            auth=(
                credentials.username.get_secret_value(),
                credentials.password.get_secret_value(),
            ),
            timeout=15,
            limits=httpx.Limits(max_connections=4),
            follow_redirects=False,
        )

    async def request(self, method: str, path: str, data: dict[str, str] | None = None):
        response = await self.client.request(method, path, data=data)
        if response.status_code not in range(200, 300):
            # Provider error bodies can repeat phone numbers or credentials.
            raise RuntimeError(f"46elks request returned HTTP {response.status_code}")
        try:
            return response.json()
        except ValueError:
            raise RuntimeError("46elks returned a response that is not JSON") from None

    async def numbers(self, settings: CarrierSettings, public_url: str):
        voice = parse_boundary(
            CarrierNumber, await self.request("GET", f"/numbers/{settings.voiceNumberId}"), "46elks number lookup"
        )
        websocket = parse_boundary(
            CarrierNumber, await self.request("GET", f"/numbers/{settings.websocketNumberId}"), "46elks number lookup"
        )
        for number, capability in [(voice, "voice"), (websocket, "websocket")]:
            if number.active != "yes" or capability not in number.capabilities:
                raise RuntimeError(
                    f"Configured carrier number lacks active {capability}"
                )
            if not number.number.startswith("+"):
                raise RuntimeError("Carrier returned no E.164 number")
        if websocket.websocket_url != public_url:
            raise RuntimeError(
                "Carrier media URL is not provisioned; run configure once"
            )
        return voice.number, websocket.number

    async def dial(
        self, from_number: str, to_number: str, websocket_number: str, ring_seconds: int
    ) -> CarrierCall:
        return parse_boundary(
            CarrierCall,
            await self.request(
                "POST",
                "/calls",
                {
                    "from": from_number,
                    "to": to_number,
                    "timeout": str(ring_seconds),
                    "voice_start": json.dumps({"connect": websocket_number}),
                },
            ),
            "46elks dial",
        )

    async def call(self, call_id: str) -> CarrierCall:
        return parse_boundary(CarrierCall, await self.request("GET", f"/calls/{call_id}"), "46elks call lookup")


class ReceiptState(StrEnum):
    PREPARED = "prepared"
    ATTEMPTED = "attempted"
    SUBMITTED = "submitted"
    UNCERTAIN = "uncertain"
    COMPLETED = "completed"


class CarrierReceipt:
    def __init__(self, root: Path, call_id: str):
        self.root = root
        self.call_id = str(UUID(call_id))
        self.path = root / self.call_id / "receipt.json"
        self._data: dict[str, Any] = {"callId": self.call_id, "state": ReceiptState.PREPARED}
        self.lock_file = None
        self._writer: ThreadPoolExecutor | None = None

    def __enter__(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lock_file = (self.root / "carrier.lock").open("a+")
        try:
            fcntl.flock(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if self.path.exists():
                self._data = json.loads(self.path.read_text())
                raise RuntimeError(
                    "Carrier receipt already exists; never replay a dial"
                )
            self.path.parent.mkdir(mode=0o700)
            self._writer = ThreadPoolExecutor(max_workers=1, thread_name_prefix="carrier-receipt")
            return self
        except BaseException:
            self.lock_file.close()
            self.lock_file = None
            raise

    def __exit__(self, *_):
        if self._writer is not None:
            self._writer.shutdown(wait=True)
            self._writer = None
        if self.lock_file is not None:
            self.lock_file.close()
            self.lock_file = None

    @property
    def state(self) -> ReceiptState:
        return ReceiptState(self._data["state"])

    @property
    def provider_call_id(self) -> str | None:
        return self._data.get("providerCallId")

    @property
    def provider_state(self) -> str | None:
        return self._data.get("providerState")

    @property
    def snapshot(self) -> Mapping[str, Any]:
        return MappingProxyType(dict(self._data))

    def _write(self, change: Callable[[dict[str, Any]], dict[str, Any]]):
        next_data = self._data | change(self._data) | {"updatedAt": time.time()}
        staged = self.path.with_suffix(".new")
        with os.fdopen(
            os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w"
        ) as file:
            json.dump(next_data, file)
            file.flush()
            os.fsync(file.fileno())
        os.replace(staged, self.path)
        directory = os.open(self.path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        self._data = next_data

    async def _save(self, change: Callable[[dict[str, Any]], dict[str, Any]]):
        if self._writer is None:
            raise RuntimeError("Carrier receipt is not open")
        await asyncio.get_running_loop().run_in_executor(self._writer, self._write, change)

    async def _set(self, **fields: Any):
        await self._save(lambda _: fields)

    async def attempted(self, to_number: str):
        def change(data: dict[str, Any]) -> dict[str, Any]:
            if data["state"] != ReceiptState.PREPARED:
                raise RuntimeError("This request already attempted a provider submission")
            return {
                "state": ReceiptState.ATTEMPTED,
                "attemptedAt": time.time(),
                "recipientLast4": to_number[-4:],
            }

        await self._save(change)

    async def submitted(self, provider_call_id: str):
        def change(data: dict[str, Any]) -> dict[str, Any]:
            if data["state"] != ReceiptState.ATTEMPTED or not provider_call_id.startswith("c"):
                raise RuntimeError("Unexpected provider submission receipt")
            return {"state": ReceiptState.SUBMITTED, "providerCallId": provider_call_id}

        await self._save(change)

    async def terminal(self, provider_record: CarrierCall):
        def change(data: dict[str, Any]) -> dict[str, Any]:
            if provider_record.id != data.get("providerCallId"):
                raise RuntimeError("Terminal receipt belongs to a different provider call")
            if provider_record.state not in TERMINAL_STATES:
                raise RuntimeError("Carrier has not confirmed a terminal state")
            return {
                "state": ReceiptState.COMPLETED,
                "providerState": provider_record.state,
                "durationSeconds": provider_record.duration,
                "costTenThousandths": provider_record.cost,
            }

        await self._save(change)

    async def uncertain(self, reason: str):
        await self._set(state=ReceiptState.UNCERTAIN, reason=reason)

    async def answered(self, input_silence_bytes: int):
        await self._set(answeredAt=time.time(), inputSilenceBytesAtAnswer=input_silence_bytes)

    async def carrier_drain_observed(self):
        await self._set(carrierDrainObservedAt=time.time())

    async def carrier_bye_observed(self, reason: str | None, message: str | None):
        await self._set(
            carrierByeObservedAt=time.time(), carrierByeReason=reason, carrierByeMessage=message
        )

    async def failed(self, failure: Mapping[str, Any] | None):
        await self._set(failure=failure)

    async def statistics(self, statistics: Mapping[str, Any]):
        await self._set(**statistics)

    async def stopped(
        self,
        reason: str | None,
        failure: Mapping[str, Any] | None,
        statistics: Mapping[str, Any],
    ):
        await self._set(stopReason=reason, failure=failure, **statistics)
