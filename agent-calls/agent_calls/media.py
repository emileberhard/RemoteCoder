import asyncio
import base64
import contextlib
import hmac
import json
import signal
import sys
import time
import traceback
from collections import Counter, deque
from collections.abc import Awaitable, Callable
from fractions import Fraction
from pathlib import Path
from typing import Any, Protocol
from uuid import UUID, uuid4

import httpx
from aiortc import (
    AudioStreamTrack,
    RTCConfiguration,
    RTCPeerConnection,
    RTCSessionDescription,
)
from aiortc.mediastreams import MediaStreamError
from av import AudioFrame, AudioResampler
from pydantic import BaseModel, ConfigDict
from websockets.asyncio.server import ServerConnection, serve

from .carrier import (
    TERMINAL_STATES,
    CarrierAPI,
    CarrierHello,
    CarrierMessage,
    CarrierReceipt,
    CarrierSettings,
    ReceiptState,
    load_credentials,
    parse_boundary,
)
from .rpc import GatewayConnection, GatewayRPC, ignore_notification

FRAME_BYTES = 960  # 20 ms, mono s16 at 24 kHz.
PCM_BYTES_PER_SECOND = 48_000


def next_audio_deadline(deadline: float, size: int, now: float) -> float:
    following = deadline + size / PCM_BYTES_PER_SECOND
    # Timer overshoot is jitter, not additional audio duration. Only re-anchor
    # after a real stall; otherwise the per-frame overshoot accumulates forever.
    return now if following < now - 1.0 else following


class WorkerInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    callId: UUID
    originGatewayHostId: UUID
    gateway: GatewayConnection
    configPath: Path


class CallMediaDetails(BaseModel):
    callId: UUID
    hostId: UUID
    to: str
    expiresAt: float


class CallStatus(BaseModel):
    state: str


class AccountInfo(BaseModel):
    type: str


class AccountRead(BaseModel):
    account: AccountInfo | None = None


class ControlEvent(BaseModel):
    type: str | None = None
    turn: dict[str, Any] | None = None
    usage: Any = None


class StopSignal:
    def __init__(self):
        self.event = asyncio.Event()
        self.reason: str | None = None
        self.failure: dict[str, Any] | None = None

    def set(self, reason: str):
        if self.reason is None:
            self.reason = reason
            self.event.set()

    def fail(self, stage: str, error: Exception):
        if self.reason is not None:
            return
        self.failure = {
            "stage": stage,
            "type": f"{type(error).__module__}.{type(error).__name__}",
            "code": getattr(error, "errno", None) or getattr(error, "code", None),
            "frames": [
                {"file": frame.filename, "line": frame.lineno, "function": frame.name}
                for frame in traceback.extract_tb(error.__traceback__, limit=8)
            ],
        }
        self.set(f"{stage} failed ({type(error).__name__})")


class TelephoneInput(AudioStreamTrack):
    def __init__(self):
        super().__init__()
        self.buffer = bytearray()
        self.samples = 0
        self.started: float | None = None
        self.received_bytes = 0
        self.silence_bytes = 0
        self.maximum_buffered_bytes = 0
        self.overruns = 0
        self.dropped_bytes = 0

    def feed(self, pcm: bytes):
        if len(pcm) % 2:
            raise ValueError("Carrier PCM has an incomplete sample")
        self.buffer.extend(pcm)
        self.received_bytes += len(pcm)
        if len(self.buffer) > PCM_BYTES_PER_SECOND:
            dropped = len(self.buffer) - PCM_BYTES_PER_SECOND
            del self.buffer[:dropped]
            self.overruns += 1
            self.dropped_bytes += dropped
        self.maximum_buffered_bytes = max(self.maximum_buffered_bytes, len(self.buffer))

    async def recv(self):
        if self.started is None:
            self.started = time.monotonic()
        await asyncio.sleep(
            max(0.0, self.started + self.samples / 24_000 - time.monotonic())
        )
        received = bytes(self.buffer[:FRAME_BYTES])
        self.silence_bytes += FRAME_BYTES - len(received)
        pcm = received.ljust(FRAME_BYTES, b"\0")
        del self.buffer[:FRAME_BYTES]
        frame = AudioFrame(format="s16", layout="mono", samples=480)
        frame.planes[0].update(pcm)
        frame.sample_rate = 24_000
        frame.time_base = Fraction(1, 24_000)
        frame.pts = self.samples
        self.samples += 480
        return frame


class CarrierSender(Protocol):
    async def send(self, message: str, /) -> None: ...


class CarrierPlayback:
    """One ordered sender owns audio, interruption reset and terminal drain."""

    def __init__(self, socket: CarrierSender):
        self.socket = socket
        self.pending: deque[bytes] = deque()
        self.changed = asyncio.Event()
        self.sync_received = asyncio.Event()
        self.bye_received = asyncio.Event()
        self.interrupted = False
        self.finishing = False
        self.finished = asyncio.Event()
        self.sent_frames = 0
        self.pending_bytes = 0
        self.maximum_pending_bytes = 0
        self.overruns = 0
        self.dropped_bytes = 0
        self.maximum_send_lag_ms = 0.0

    def audio(self, pcm: bytes):
        if self.finishing:
            return
        if self.pending_bytes + len(pcm) > PCM_BYTES_PER_SECOND:
            self.overruns += 1
            self.dropped_bytes += self.pending_bytes + max(
                0, len(pcm) - PCM_BYTES_PER_SECOND
            )
            # A stalled playout can recover at live time. Mark the discontinuity
            # and reset the carrier queue instead of disconnecting the person.
            self.interrupt()
            pcm = pcm[-PCM_BYTES_PER_SECOND:]
        self.pending.append(pcm)
        self.pending_bytes += len(pcm)
        self.maximum_pending_bytes = max(self.maximum_pending_bytes, self.pending_bytes)
        self.changed.set()

    def interrupt(self):
        if not self.finishing:
            self.pending.clear()
            self.pending_bytes = 0
            self.interrupted = True
            self.changed.set()

    async def send(self, message: dict[str, Any]):
        await asyncio.wait_for(self.socket.send(json.dumps(message)), 1)

    async def run(self):
        try:
            await self.send({"t": "sending", "format": "pcm_24000"})
            await self.send({"t": "listening", "format": "pcm_24000"})
            next_frame_at: float | None = None
            while True:
                await self.changed.wait()
                self.changed.clear()
                if self.interrupted:
                    self.interrupted = False
                    await self.send({"t": "interrupt"})
                    await self.send({"t": "sending", "format": "pcm_24000"})
                    next_frame_at = None
                if self.pending:
                    pcm = self.pending.popleft()
                    self.pending_bytes -= len(pcm)
                    if next_frame_at is None:
                        next_frame_at = time.monotonic()
                    await asyncio.sleep(max(0.0, next_frame_at - time.monotonic()))
                    if self.interrupted:
                        self.changed.set()
                        continue
                    await self.send(
                        {"t": "audio", "data": base64.b64encode(pcm).decode()}
                    )
                    self.sent_frames += 1
                    now = time.monotonic()
                    self.maximum_send_lag_ms = max(
                        self.maximum_send_lag_ms, (now - next_frame_at) * 1_000
                    )
                    next_frame_at = next_audio_deadline(next_frame_at, len(pcm), now)
                    if self.pending or self.finishing:
                        self.changed.set()
                elif self.finishing:
                    self.sync_received.clear()
                    await self.send({"t": "sync"})
                    with contextlib.suppress(TimeoutError):
                        await asyncio.wait_for(self.sync_received.wait(), 2)
                    await self.send({"t": "bye"})
                    with contextlib.suppress(TimeoutError):
                        await asyncio.wait_for(self.bye_received.wait(), 3)
                    return
        finally:
            self.finished.set()

    async def finish(self):
        self.finishing = True
        self.changed.set()
        await asyncio.wait_for(self.finished.wait(), 7)


def authentic_hello(
    hello: CarrierHello, provider_call_id: str, websocket_number: str
) -> bool:
    return (
        hello.t == "hello"
        and hello.callid == provider_call_id
        and hello.to == websocket_number
    )


class TelephoneMedia:
    def __init__(
        self,
        rpc: GatewayRPC,
        call_id: str,
        stop: StopSignal,
        receipt: CarrierReceipt,
        websocket_number: str,
    ):
        self.rpc = rpc
        self.call_id = call_id
        self.stop = stop
        self.receipt = receipt
        self.websocket_number = websocket_number
        self.peer = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        self.input = TelephoneInput()
        self.peer.addTrack(self.input)
        self.channel = self.peer.createDataChannel("oai-events")
        self.connected = asyncio.Event()
        self.submitted = asyncio.Event()
        self.sdp = asyncio.get_running_loop().create_future()
        self.playback: CarrierPlayback | None = None
        self.playback_task: asyncio.Task | None = None
        self.tasks: list[asyncio.Task] = []
        self.received_frames = 0
        self.maximum_decoded_frame_samples = 0
        self.interruptions = 0
        self.event_types: Counter[str] = Counter()
        self.usage: dict[str, Any] | None = None
        self.output_enabled = False
        self.rpc.on_notification = self.notification
        self.channel.on("message", self.channel_message)
        self.peer.on("track", self.remote_track)
        self.peer.on("connectionstatechange", self.peer_state)

    def notification(self, message: dict[str, Any]):
        method = message.get("method")
        params = message.get("params", {})
        if method == "thread/realtime/sdp" and not self.sdp.done():
            self.sdp.set_result(params["sdp"])
        elif method == "calls/changed" and params.get("callId") == self.call_id:
            if params.get("state") in {"ending", "ended", "unresolved"}:
                self.stop.set("agent ended the call")
        elif method in {"voice/session/agentEnded", "voice/session/preempted"}:
            if params.get("realtimeSessionId") == self.call_id:
                self.stop.set("voice call ended or preempted")
        elif method in {"thread/realtime/closed", "thread/realtime/error"}:
            self.stop.set("voice transport closed")

    def channel_message(self, raw: str | bytes):
        try:
            event = ControlEvent.model_validate_json(raw)
        except ValueError:
            self.stop.set("invalid voice control event")
            return
        kind = event.type
        if (
            isinstance(kind, str)
            and len(kind) <= 64
            and all(char.isalnum() or char in "._" for char in kind)
        ):
            if kind in self.event_types or len(self.event_types) < 32:
                self.event_types[kind] += 1
        # These are observed subscription Live V3 events, not legacy Realtime VAD.
        if kind == "turn.created" and (event.turn or {}).get("role") == "user":
            if self.playback is not None:
                self.playback.interrupt()
                self.interruptions += 1
        elif kind == "session.usage.updated":
            if isinstance(event.usage, dict) and len(json.dumps(event.usage)) <= 16_000:
                self.usage = event.usage
        elif kind == "error":
            self.stop.set("voice service error")

    async def peer_state(self):
        if self.peer.connectionState == "connected":
            self.connected.set()
        elif self.peer.connectionState == "failed":
            self.stop.set("voice peer failed")

    def remote_track(self, track):
        self.tasks.append(asyncio.create_task(self.receive_audio(track)))

    async def receive_audio(self, track):
        resampler = AudioResampler(format="s16", layout="mono", rate=24_000)
        try:
            while True:
                frame = await track.recv()
                self.received_frames += 1
                self.maximum_decoded_frame_samples = max(
                    self.maximum_decoded_frame_samples, frame.samples
                )
                for converted in resampler.resample(frame):
                    pcm = bytes(converted.planes[0])[: converted.samples * 2]
                    if self.output_enabled and self.playback is not None:
                        self.playback.audio(pcm)
        except MediaStreamError:
            if not self.stop.event.is_set():
                self.stop.set("voice audio stream ended")
        except Exception as error:
            self.stop.fail("voice audio decoding or playback", error)
            await self.receipt.failed(self.stop.failure)

    async def prepare(self):
        await self.peer.setLocalDescription(await self.peer.createOffer())
        if self.peer.localDescription is None:
            raise RuntimeError("WebRTC offer is unavailable")
        await self.rpc.call(
            "calls/media/attach",
            {
                "callId": self.call_id,
                "sdp": self.peer.localDescription.sdp,
                "voice": None,
            },
            deadline_seconds=90,
        )
        answer = await asyncio.wait_for(self.sdp, 10)
        await self.peer.setRemoteDescription(RTCSessionDescription(answer, "answer"))
        await asyncio.wait_for(self.connected.wait(), 15)

    async def accept(self, socket: ServerConnection):
        try:
            hello = CarrierHello.model_validate_json(await asyncio.wait_for(socket.recv(), 10))
            await asyncio.wait_for(self.submitted.wait(), 15)
            provider_id = self.receipt.provider_call_id or ""
            if self.playback is not None or not authentic_hello(
                hello, provider_id, self.websocket_number
            ):
                await socket.close(code=1008, reason="Unrecognized call")
                return
        except ValueError, TimeoutError:
            await socket.close(code=1008, reason="Invalid call handshake")
            return
        playback = CarrierPlayback(socket)
        self.playback = playback
        self.playback_task = asyncio.create_task(playback.run())
        receiver = asyncio.create_task(self.receive_carrier(socket, playback))
        try:
            if self.stop.event.is_set():
                await playback.finish()
                return
            self.output_enabled = True
            await self.rpc.call(
                "calls/media/event",
                {
                    "callId": self.call_id,
                    "event": "answered",
                    "providerCallId": provider_id,
                },
            )
            await self.receipt.answered(self.input.silence_bytes)
            done, _ = await asyncio.wait(
                [receiver, self.playback_task], return_when=asyncio.FIRST_COMPLETED
            )
            for task in done:
                task.result()
        except Exception as error:
            self.stop.fail("carrier media", error)
            await self.receipt.failed(self.stop.failure)
        finally:
            self.output_enabled = False
            self.stop.set("carrier media ended")
            receiver.cancel()
            self.playback_task.cancel()
            await asyncio.gather(receiver, self.playback_task, return_exceptions=True)

    async def receive_carrier(
        self, socket: ServerConnection, playback: CarrierPlayback
    ):
        async for raw in socket:
            message = CarrierMessage.model_validate_json(raw)
            if message.t == "audio" and not self.stop.event.is_set():
                if message.data is None:
                    raise ValueError("Carrier audio frame has no data")
                pcm = base64.b64decode(message.data, validate=True)
                self.input.feed(pcm)
            elif message.t == "sync":
                playback.sync_received.set()
                await self.receipt.carrier_drain_observed()
            elif message.t == "bye":
                playback.bye_received.set()
                await self.receipt.carrier_bye_observed(message.reason, message.message)
                return

    async def close(self):
        self.output_enabled = False
        self.rpc.on_notification = ignore_notification
        try:
            if self.playback is not None and not self.playback.bye_received.is_set():
                with contextlib.suppress(TimeoutError, ConnectionError):
                    await self.playback.finish()
        finally:
            try:
                await self.peer.close()
            finally:
                self.input.stop()
                for task in self.tasks:
                    task.cancel()
                await asyncio.gather(*self.tasks, return_exceptions=True)

    def statistics(self) -> dict[str, Any]:
        playback = self.playback
        return {
            "voiceFrames": self.received_frames,
            "maximumDecodedFrameSamples": self.maximum_decoded_frame_samples,
            "interruptions": self.interruptions,
            "inputReceivedBytes": self.input.received_bytes,
            "inputSilenceBytes": self.input.silence_bytes,
            "inputMaximumBufferedBytes": self.input.maximum_buffered_bytes,
            "inputOverruns": self.input.overruns,
            "inputDroppedBytes": self.input.dropped_bytes,
            "playbackSentFrames": playback.sent_frames if playback else 0,
            "playbackMaximumBufferedBytes": playback.maximum_pending_bytes
            if playback
            else 0,
            "playbackOverruns": playback.overruns if playback else 0,
            "playbackDroppedBytes": playback.dropped_bytes if playback else 0,
            "playbackMaximumSendLagMs": playback.maximum_send_lag_ms if playback else 0,
            "liveEventTypes": dict(self.event_types),
            "subscriptionUsage": self.usage,
        }

    async def record_statistics(self):
        while not self.stop.event.is_set():
            await self.receipt.statistics(self.statistics())
            await asyncio.sleep(10)


async def supervised(stop: StopSignal, stage: str, work: Callable[[], Awaitable[None]]):
    try:
        await work()
    except Exception as error:
        stop.fail(stage, error)


async def lease_input(reader: asyncio.StreamReader, stop: StopSignal):
    try:
        while line := await reader.readline():
            if json.loads(line).get("command") == "stop":
                stop.set("call owner requested stop")
                return
    except ValueError, OSError, AttributeError:
        stop.set("call owner control input failed")
    finally:
        stop.set("call owner connection closed")


async def carrier_poll(api: CarrierAPI, receipt: CarrierReceipt, stop: StopSignal):
    provider_call_id = receipt.provider_call_id
    if provider_call_id is None:
        raise RuntimeError("Carrier polling needs a submitted provider call")
    failures = 0
    while not stop.event.is_set():
        await asyncio.sleep(2)
        try:
            record = await api.call(provider_call_id)
            failures = 0
            if record.state in TERMINAL_STATES:
                await receipt.terminal(record)
                stop.set("carrier confirmed call completion")
        except httpx.HTTPError, RuntimeError:
            failures += 1
            if failures == 3:
                stop.set("carrier status is unavailable")


async def reconcile_carrier(
    api: CarrierAPI, receipt: CarrierReceipt, media: TelephoneMedia, expires_at: float
):
    media.output_enabled = False
    if media.playback is not None:
        with contextlib.suppress(Exception):
            await media.playback.finish()
    if receipt.state == ReceiptState.COMPLETED:
        return
    provider_call_id = receipt.provider_call_id
    if provider_call_id is None:
        raise RuntimeError("Carrier reconciliation needs a submitted provider call")
    # 46elks documents no pre-answer cancellation API. Keep accepting only this
    # call so a late answer gets an immediate bye, then wait for its ring timeout.
    deadline = max(time.time() + 8, min(expires_at + 8, time.time() + 68))
    while time.time() < deadline:
        try:
            record = await api.call(provider_call_id)
            if record.state in TERMINAL_STATES:
                await receipt.terminal(record)
                return
        except httpx.HTTPError, RuntimeError:
            pass
        await asyncio.sleep(1)
    await receipt.uncertain("carrier termination not confirmed")


@contextlib.asynccontextmanager
async def _closing_media(media: TelephoneMedia):
    try:
        yield media
    finally:
        await media.close()


async def run_worker(config: WorkerInput, reader: asyncio.StreamReader):
    def phase(name: str) -> str:
        print(json.dumps({"event": "phase", "status": name}), flush=True)
        return name

    current_phase = phase("configuration")
    settings = CarrierSettings.model_validate_json(await asyncio.to_thread(config.configPath.read_text))
    current_phase = phase("carrier credentials")
    credentials = await asyncio.to_thread(load_credentials, settings.credentialSource)
    media_secret = credentials.mediaSecret.get_secret_value()
    expected_path = f"/{media_secret}"
    public_url = f"{settings.publicBaseURL}{expected_path}"
    stop = StopSignal()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        loop.add_signal_handler(sig, stop.set, "worker interrupted")
    lease = asyncio.create_task(
        supervised(stop, "call owner control input", lambda: lease_input(reader, stop))
    )
    api = CarrierAPI(credentials)
    try:
        current_phase = phase("origin gateway connection")
        async with GatewayRPC.connect(config.gateway.gateway_config()) as rpc:
            current_phase = phase("origin and call identity")
            details = parse_boundary(
                CallMediaDetails,
                await rpc.call("calls/media/details", {"callId": str(config.callId)}),
                "calls/media/details",
            )
            if (
                details.callId != config.callId
                or details.hostId != config.originGatewayHostId
            ):
                raise RuntimeError("Call record identity does not match its owner")
            current_phase = phase("subscription account")
            account = parse_boundary(
                AccountRead,
                await rpc.call("account/read", {"refreshToken": False}),
                "account/read",
            )
            if account.account is None or account.account.type not in {
                "chatgpt",
                "chatgptAuthTokens",
            }:
                raise RuntimeError("Subscription voice login is required")
            current_phase = phase("carrier inventory and media URL")
            voice_number, websocket_number = await api.numbers(settings, public_url)
            current_phase = phase("exclusive carrier lease")
            with CarrierReceipt(settings.stateDirectory, str(config.callId)) as receipt:
                challenge = uuid4().hex

                async def process_request(connection, request):
                    if hmac.compare_digest(request.path, f"/health/{challenge}"):
                        return connection.respond(200, challenge)
                    if not hmac.compare_digest(request.path, expected_path):
                        return connection.respond(404, "Not found")
                    return None

                current_phase = phase("media listener")
                async with _closing_media(
                    TelephoneMedia(
                        rpc, str(config.callId), stop, receipt, websocket_number
                    )
                ) as media, serve(
                    media.accept,
                    settings.bindHost,
                    settings.bindPort,
                    process_request=process_request,
                    open_timeout=10,
                    close_timeout=3,
                    max_size=256 * 1024,
                    max_queue=8,
                ):
                    tasks: list[asyncio.Task] = []
                    try:
                        current_phase = phase("public media ingress")
                        async with httpx.AsyncClient(timeout=10) as public:
                            response = await public.get(
                                f"{settings.publicBaseURL.replace('wss:', 'https:', 1)}/health/{challenge}"
                            )
                            if (
                                response.status_code != 200
                                or response.text != challenge
                            ):
                                raise RuntimeError(
                                    "Public media ingress did not reach this worker"
                                )
                        current_phase = phase("subscription voice attachment")
                        await media.prepare()
                        current_phase = phase("pre-dial call admission")
                        status = parse_boundary(
                            CallStatus,
                            await rpc.call(
                                "calls/status", {"callId": str(config.callId)}
                            ),
                            "calls/status",
                        )
                        remaining = int(details.expiresAt - time.time())
                        if (
                            stop.event.is_set()
                            or status.state != "connecting"
                            or remaining < 1
                        ):
                            raise RuntimeError(
                                "Call was stopped or expired before dialing"
                            )
                        current_phase = phase("carrier submission")
                        await receipt.attempted(details.to)
                        provider_call = await api.dial(
                            voice_number,
                            details.to,
                            websocket_number,
                            min(remaining, 60),
                        )
                        await receipt.submitted(provider_call.id)
                        media.submitted.set()
                        await rpc.call(
                            "calls/media/event",
                            {
                                "callId": str(config.callId),
                                "event": "submitted",
                                "providerCallId": provider_call.id,
                            },
                        )
                        print(
                            json.dumps({"event": "submitted", "status": "accepted"}),
                            flush=True,
                        )
                        tasks.append(
                            asyncio.create_task(
                                supervised(
                                    stop,
                                    "carrier status polling",
                                    lambda: carrier_poll(api, receipt, stop),
                                )
                            )
                        )
                        tasks.append(
                            asyncio.create_task(
                                supervised(
                                    stop,
                                    "call statistics",
                                    media.record_statistics,
                                )
                            )
                        )

                        async def gateway_closed():
                            await rpc.closed.wait()
                            stop.set("origin gateway disconnected")

                        tasks.append(asyncio.create_task(gateway_closed()))
                        current_phase = phase("live call")
                        try:
                            await asyncio.wait_for(
                                stop.event.wait(), 30 * 60 + remaining
                            )
                        except TimeoutError:
                            stop.set("maximum call duration reached")
                    except Exception as error:
                        stop.fail(current_phase, error)
                        raise
                    finally:
                        stop.set("call execution finished")
                        for task in tasks:
                            task.cancel()
                        await asyncio.gather(*tasks, return_exceptions=True)
                        if receipt.provider_call_id:
                            await reconcile_carrier(
                                api, receipt, media, details.expiresAt
                            )
                        elif receipt.state == ReceiptState.ATTEMPTED:
                            await receipt.uncertain(
                                "provider submission acknowledgment missing"
                            )
                            # Hold the slot through an acknowledgment-lost dial's ring deadline.
                            await asyncio.sleep(
                                max(
                                    0,
                                    min(details.expiresAt + 8 - time.time(), 68),
                                )
                            )
                        if receipt.path.exists():
                            await receipt.stopped(stop.reason, stop.failure, media.statistics())
                        event = (
                            "completed"
                            if receipt.state == ReceiptState.COMPLETED
                            else "uncertain"
                        )
                        with contextlib.suppress(Exception):
                            await rpc.call(
                                "calls/media/event",
                                {
                                    "callId": str(config.callId),
                                    "event": event,
                                    "providerCallId": receipt.provider_call_id,
                                    "providerState": receipt.provider_state,
                                    "reason": stop.reason,
                                },
                            )
                        print(
                            json.dumps(
                                {"event": "finished", "status": receipt.state}
                            ),
                            flush=True,
                        )
    finally:
        lease.cancel()
        await asyncio.gather(lease, return_exceptions=True)
        await api.client.aclose()


async def worker_main():
    reader = asyncio.StreamReader(limit=256 * 1024)
    transport, _ = await asyncio.get_running_loop().connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer
    )
    try:
        config = WorkerInput.model_validate_json(
            await asyncio.wait_for(reader.readline(), 15)
        )
        await run_worker(config, reader)
    finally:
        transport.close()
