import asyncio
import base64
import json
import threading
from collections import Counter
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, Mock, patch
from uuid import uuid4

import pytest
from pydantic import ValidationError

from agent_calls import media
from agent_calls.carrier import (
    CarrierAPI,
    CarrierCall,
    CarrierCredentials,
    CarrierHello,
    CarrierReceipt,
    ReceiptState,
)
from agent_calls.media import (
    CarrierPlayback,
    StopSignal,
    TelephoneInput,
    TelephoneMedia,
    authentic_hello,
    lease_input,
    next_audio_deadline,
    reconcile_carrier,
    supervised,
)
from agent_calls.rpc import GatewayError


async def test_input_sends_continuous_silence_and_preserves_caller_pcm():
    source = TelephoneInput()
    first = await source.recv()
    assert (first.sample_rate, first.samples, first.pts) == (24_000, 480, 0)
    assert bytes(first.planes[0]) == bytes(960)
    source.feed(b"\x34\x12" * 120)
    second = await source.recv()
    assert second.pts == 480
    assert bytes(second.planes[0]) == b"\x34\x12" * 120 + bytes(720)
    with pytest.raises(ValueError, match="incomplete sample"):
        source.feed(b"\x01")
    source.feed(b"\x01\x00" * 24_001)
    assert source.overruns == 1
    assert source.dropped_bytes == 2
    assert source.buffer == b"\x01\x00" * 24_000
    source.stop()


class CarrierSocket:
    def __init__(self):
        self.messages = []
        self.playback = CarrierPlayback(self)
        self.sent_audio = asyncio.Event()
        self.ready = asyncio.Event()

    async def send(self, raw):
        message = json.loads(raw)
        self.messages.append(message)
        match message["t"]:
            case "listening":
                self.ready.set()
            case "audio":
                self.sent_audio.set()
            case "sync":
                self.playback.sync_received.set()
            case "bye":
                self.playback.bye_received.set()


@pytest.mark.parametrize(
    ("trigger", "old_frames", "old_audio", "current_audio", "overruns", "dropped_bytes"),
    [
        ("interrupt", 30, b"old" * 320, bytes(960), 0, 0),
        ("overrun", 50, bytes(960), b"\x01\x00" * 480, 1, 48_000),
    ],
    ids=["explicit-interrupt", "queue-overrun"],
)
async def test_playback_resets_carrier_before_current_audio_and_drains(
    trigger, old_frames, old_audio, current_audio, overruns, dropped_bytes
):
    socket = CarrierSocket()
    playback = socket.playback
    for _ in range(old_frames):
        playback.audio(old_audio)
    if trigger == "interrupt":
        playback.interrupt()
    playback.audio(current_audio)
    sender = asyncio.create_task(playback.run())
    await asyncio.wait_for(socket.sent_audio.wait(), 1)
    await playback.finish()
    await sender
    assert [message["t"] for message in socket.messages] == [
        "sending",
        "listening",
        "interrupt",
        "sending",
        "audio",
        "sync",
        "bye",
    ]
    assert base64.b64decode(socket.messages[4]["data"]) == current_audio
    assert playback.bye_received.is_set()
    assert playback.overruns == overruns
    assert playback.dropped_bytes == dropped_bytes


def test_playback_clock_does_not_accumulate_timer_and_send_overhead():
    deadline = 10.0
    for _ in range(5_000):
        deadline = next_audio_deadline(deadline, 960, deadline + 0.003)
    assert deadline == pytest.approx(110.0)
    assert next_audio_deadline(10, 960, 12) == 12


async def test_playback_clock_starts_with_first_audio_not_carrier_handshake(
    monkeypatch,
):
    clock = Mock()
    clock.monotonic.return_value = 10.0
    monkeypatch.setattr(media, "time", clock)
    socket = CarrierSocket()
    sender = asyncio.create_task(socket.playback.run())
    await asyncio.wait_for(socket.ready.wait(), 1)
    clock.monotonic.return_value = 10.9
    socket.playback.audio(bytes(960))
    await asyncio.wait_for(socket.sent_audio.wait(), 1)
    await socket.playback.finish()
    await sender
    assert socket.playback.maximum_send_lag_ms == 0


def test_first_media_failure_keeps_its_type_and_source_frame():
    signal = StopSignal()
    try:
        raise BufferError("do not serialize arbitrary exception input")
    except BufferError as error:
        signal.fail("playback", error)
    signal.set("generic teardown")
    assert signal.reason == "playback failed (BufferError)"
    assert signal.failure is not None
    assert signal.failure["type"] == "builtins.BufferError"
    assert (
        signal.failure["frames"][-1]["function"]
        == "test_first_media_failure_keeps_its_type_and_source_frame"
    )
    assert "do not serialize" not in json.dumps(signal.failure)


def test_a_gateway_error_keeps_its_code_in_the_failure_record():
    signal = StopSignal()
    signal.fail("gateway", GatewayError("calls/status: rejected", -32602))
    assert signal.failure is not None
    assert signal.failure["code"] == -32602


@pytest.mark.parametrize(
    "hello",
    [
        {"t": "hello", "callid": "cforeign", "to": "+46000000001"},
        {"t": "hello", "callid": "cowned", "to": "+46000000002"},
        {"t": "audio", "callid": "cowned", "to": "+46000000001"},
    ],
)
def test_carrier_identity_is_bound_to_submission_and_websocket_number(hello):
    assert not authentic_hello(CarrierHello(**hello), "cowned", "+46000000001")
    assert authentic_hello(
        CarrierHello(t="hello", callid="cowned", to="+46000000001"),
        "cowned",
        "+46000000001",
    )


@pytest.mark.parametrize("data", [b"", b'{"command":"stop"}\n'])
async def test_lease_loss_and_stop_both_end_worker(data):
    reader = asyncio.StreamReader()
    reader.feed_data(data)
    reader.feed_eof()
    stop = StopSignal()
    await lease_input(reader, stop)
    assert stop.event.is_set()
    original = stop.reason
    stop.set("later cleanup")
    assert stop.reason == original


async def test_malformed_owner_control_still_cancels_the_call():
    reader = asyncio.StreamReader()
    reader.feed_data(b"not-json\n")
    stop = StopSignal()
    await lease_input(reader, stop)
    assert stop.event.is_set()
    assert stop.reason == "call owner control input failed"


async def test_listener_entry_failure_closes_media():
    call_id = uuid4()
    host_id = uuid4()
    config = Mock(callId=call_id, originGatewayHostId=host_id)
    config.configPath.read_text.return_value = "{}"
    settings = Mock(
        credentialSource="unused",
        publicBaseURL="wss://example.test",
        bindHost="127.0.0.1",
        bindPort=0,
    )
    credentials = Mock()
    credentials.mediaSecret.get_secret_value.return_value = "synthetic"
    rpc = Mock()

    async def call(method, params):
        if method == "calls/media/details":
            return {
                "callId": str(call_id),
                "hostId": str(host_id),
                "to": "+46000000003",
                "expiresAt": 4_102_444_800,
            }
        if method == "account/read":
            return {"account": {"type": "chatgpt"}}
        raise AssertionError(method)

    rpc.call = AsyncMock(side_effect=call)
    connection = AsyncMock()
    connection.__aenter__.return_value = rpc
    api = Mock()
    api.numbers = AsyncMock(return_value=("+46000000001", "+46000000002"))
    api.client.aclose = AsyncMock()
    receipt = MagicMock()
    receipt.__enter__.return_value = receipt
    telephone = Mock()
    telephone.close = AsyncMock()
    listener = AsyncMock()
    listener.__aenter__.side_effect = OSError("listener entry failed")
    reader = asyncio.StreamReader()
    reader.feed_eof()

    with (
        patch.object(media.CarrierSettings, "model_validate_json", return_value=settings),
        patch.object(media, "load_credentials", return_value=credentials),
        patch.object(media.GatewayRPC, "connect", return_value=connection),
        patch.object(media, "CarrierAPI", return_value=api),
        patch.object(media, "CarrierReceipt", return_value=receipt),
        patch.object(media, "TelephoneMedia", return_value=telephone),
        patch.object(media, "serve", return_value=listener),
    ):
        with pytest.raises(OSError, match="listener entry failed"):
            await media.run_worker(config, reader)

    telephone.close.assert_awaited_once()
    api.client.aclose.assert_awaited_once()
    assert [call.args[0] for call in rpc.call.await_args_list] == ["calls/media/details", "account/read"]


async def test_confirmed_carrier_completion_survives_a_later_provider_outage(tmp_path):
    with CarrierReceipt(tmp_path, str(uuid4())) as receipt:
        await receipt.attempted("+46000001709")
        await receipt.submitted("c1234")
        await receipt.terminal(
            CarrierCall(id="c1234", state="success", duration=12, cost=10)
        )
        api = Mock(spec=CarrierAPI)
        api.call = AsyncMock(side_effect=RuntimeError("provider unavailable"))
        media = Mock(spec=TelephoneMedia)
        media.playback = Mock()
        media.playback.finish = AsyncMock()
        await reconcile_carrier(api, receipt, media, 0)
        assert not media.output_enabled
        media.playback.finish.assert_awaited_once()
        api.call.assert_not_awaited()
        assert receipt.state == ReceiptState.COMPLETED
        assert receipt.provider_state == "success"
        assert receipt.snapshot["durationSeconds"] == 12


async def test_receipt_serializes_carrier_and_never_replays_an_attempt(tmp_path):
    call_id = str(uuid4())
    with CarrierReceipt(tmp_path, call_id) as receipt:
        await receipt.attempted("+46000001709")
        assert json.loads(receipt.path.read_text())["state"] == "attempted"
        assert receipt.path.stat().st_mode & 0o777 == 0o600
        with pytest.raises(BlockingIOError):
            with CarrierReceipt(tmp_path, str(uuid4())):
                pytest.fail("second physical call acquired the lease")
        with pytest.raises(RuntimeError, match="already attempted"):
            await receipt.attempted("+46000001709")
        await receipt.submitted("c123456")
        with pytest.raises(RuntimeError, match="different provider"):
            await receipt.terminal(CarrierCall(id="cforeign", state="success"))
        with pytest.raises(RuntimeError, match="not confirmed"):
            await receipt.terminal(CarrierCall(id="c123456", state="ongoing"))
        await receipt.terminal(CarrierCall(id="c123456", state="busy", cost=0))
        assert receipt.state == ReceiptState.COMPLETED
    with pytest.raises(RuntimeError, match="never replay"):
        with CarrierReceipt(tmp_path, call_id):
            pytest.fail("replayed")


async def test_a_malformed_carrier_record_fails_without_echoing_its_body():
    api = CarrierAPI(CarrierCredentials(username="u", password="p", mediaSecret="s"))
    try:
        api.request = AsyncMock(return_value=["+46000001709"])
        with pytest.raises(RuntimeError, match="46elks call lookup returned an unexpected result") as failure:
            await api.call("c123456")
    finally:
        await api.client.aclose()
    assert "46000001709" not in str(failure.value)
    assert failure.value.__cause__ is None
    assert failure.value.__suppress_context__


async def test_a_non_object_carrier_hello_is_refused_as_an_invalid_handshake():
    socket = Mock()
    socket.recv = AsyncMock(return_value="[]")
    socket.close = AsyncMock()
    await TelephoneMedia.accept(Mock(), socket)
    socket.close.assert_awaited_once_with(code=1008, reason="Invalid call handshake")


def test_control_events_interrupt_playback_record_usage_and_reject_non_objects():
    telephone = Mock(event_types=Counter(), interruptions=0, usage=None)
    TelephoneMedia.channel_message(
        telephone, json.dumps({"type": "turn.created", "turn": {"role": "user"}})
    )
    telephone.playback.interrupt.assert_called_once()
    assert telephone.interruptions == 1
    TelephoneMedia.channel_message(
        telephone, json.dumps({"type": "session.usage.updated", "usage": {"total": 3}})
    )
    assert telephone.usage == {"total": 3}
    telephone.stop.set.assert_not_called()
    TelephoneMedia.channel_message(telephone, "[]")
    telephone.stop.set.assert_called_once_with("invalid voice control event")


async def test_concurrent_receipt_updates_are_serialized_and_all_durable(tmp_path):
    with CarrierReceipt(tmp_path, str(uuid4())) as receipt:
        await receipt.attempted("+46000001709")
        await asyncio.gather(
            receipt.statistics({"first": 1}),
            receipt.carrier_drain_observed(),
            receipt.statistics({"second": 2}),
        )
        saved = json.loads(receipt.path.read_text())
    assert saved["state"] == "attempted"
    assert saved["first"] == 1
    assert saved["second"] == 2
    assert "carrierDrainObservedAt" in saved


async def test_a_failed_supervised_task_stops_the_call_with_its_stage():
    stop = StopSignal()

    async def broken():
        raise OSError(5, "receipt disk failure")

    await supervised(stop, "call statistics", broken)
    assert stop.event.is_set()
    assert stop.reason == "call statistics failed (OSError)"
    assert stop.failure is not None
    assert stop.failure["code"] == 5
    assert "receipt disk failure" not in json.dumps(stop.failure)


async def test_cancelled_supervisor_does_not_create_unowned_coroutine_before_start():
    work = AsyncMock()
    task = asyncio.create_task(supervised(StopSignal(), "control input", work))
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)
    work.assert_not_called()


async def test_media_close_releases_every_resource_when_the_carrier_drain_fails():
    telephone = Mock(tasks=[])
    telephone.playback.bye_received.is_set.return_value = False
    telephone.playback.finish = AsyncMock(side_effect=RuntimeError("drain failed"))
    telephone.peer.close = AsyncMock()
    with pytest.raises(RuntimeError, match="drain failed"):
        await TelephoneMedia.close(telephone)
    telephone.peer.close.assert_awaited_once()
    telephone.input.stop.assert_called_once()
    assert telephone.rpc.on_notification is media.ignore_notification


async def test_worker_reads_carrier_configuration_off_the_event_loop(tmp_path, monkeypatch):
    loop_thread = threading.get_ident()
    observed = []
    config = media.WorkerInput.model_validate({
        "callId": "00000000-0000-0000-0000-000000000001",
        "originGatewayHostId": "00000000-0000-0000-0000-000000000002",
        "configPath": str(tmp_path / "carrier.json"),
        "gateway": {"wsUrl": "wss://127.0.0.1:1/ws", "bearer": "synthetic",
                    "tlsIdentity": {"serverName": "origin.fixture.local",
                                    "spkiSha256": base64.b64encode(bytes(32)).decode()}}
    })

    def read_settings(path):
        observed.append(path)
        assert threading.get_ident() != loop_thread, "carrier settings read on the event loop"
        return "{}"

    monkeypatch.setattr(Path, "read_text", read_settings)
    with pytest.raises(ValidationError):
        await media.run_worker(config, asyncio.StreamReader())
    assert observed == [config.configPath]
