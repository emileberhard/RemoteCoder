import asyncio
import base64
import hashlib
import time

import httpx
import pytest

from remotecoder_tools import device_tools_probe as probe
from remotecoder_tools.config import GatewayConfig


@pytest.mark.asyncio
async def test_fake_device_uploads_the_fixture_and_returns_image_and_original_on_the_invoking_socket(
    monkeypatch,
):
    fixture = probe.FIXTURE.read_bytes()
    digest = hashlib.sha256(fixture).hexdigest()
    requests = []
    results = []

    def upload(request):
        requests.append(request)
        return httpx.Response(
            201,
            json={
                "path": "/fixture/uploads/1/photo.jpg",
                "bytes": len(fixture),
                "sha256": digest,
            },
        )

    client = httpx.AsyncClient(transport=httpx.MockTransport(upload))
    monkeypatch.setattr(GatewayConfig, "http_client", lambda self, timeout: client)
    socket = object()

    async def rpc(ws, **request):
        assert ws is socket
        results.append(request)
        return {"accepted": True}, 0, 0

    monkeypatch.setattr(probe, "_timed_rpc", rpc)
    async with asyncio.TaskGroup() as group:
        fake = probe.FakeDevice(
            socket,
            GatewayConfig("fixture", 80, "installation-test", "ws"),
            group,
            lambda: 42,
        )
        fake.observe(
            {
                "method": "device/tool/invoke",
                "params": {
                    "operationId": "operation-1",
                    "tool": "take_photo",
                    "version": 1,
                    "arguments": {"camera": "back", "lens": "wide"},
                    "deadlineUnixMs": int(time.time() * 1000) + 60000,
                },
            }
        )
    assert requests[0].method == "PUT"
    assert requests[0].content == fixture
    assert requests[0].headers["X-RemoteCoder-Upload-Length"] == str(len(fixture))
    assert requests[0].headers["X-RemoteCoder-SHA256"] == digest
    assert requests[0].headers["Authorization"] == "Bearer installation-test"
    result = results[0]
    assert result["method"] == "device/tool/result"
    assert result["params"]["operationId"] == "operation-1"
    assert base64.b64decode(result["params"]["content"][0]["data"]) == fixture
    assert result["params"]["originals"] == [
        {
            "path": "/fixture/uploads/1/photo.jpg",
            "sha256": digest,
            "bytes": len(fixture),
            "camera": "back",
            "lens": "wide",
            "width": 320,
            "height": 240,
        }
    ]
    assert fake.running == {}
    with pytest.raises(RuntimeError, match="duplicate"):
        fake.observe(
            {"method": "device/tool/invoke", "params": {"operationId": "operation-1"}}
        )


def test_visual_acceptance_requires_the_shapes_colors_and_positions():
    probe.assert_fixture_description(
        "A red rectangle on the left and a blue circle on the right"
    )
    for text in [
        "Photo received",
        "A red rectangle and a blue circle",
        "A blue rectangle on the left and red square on the right",
    ]:
        with pytest.raises(RuntimeError):
            probe.assert_fixture_description(text)


@pytest.mark.asyncio
@pytest.mark.parametrize("lost_issuance_reply", [False, True])
async def test_temporary_installation_is_revoked_and_its_token_removed_even_when_the_probe_or_issuance_fails(
    monkeypatch, lost_issuance_reply
):
    from argparse import Namespace

    operations = []
    files = {}
    installation = "temporary"

    def credentials(args, operation):
        operations.append(operation)
        if operation.startswith("issue"):
            files["token"] = "rc1.temporary.secret"
            if lost_issuance_reply:
                raise RuntimeError("Lost issuance reply")
            return {"installationId": installation}
        if operation == "revoke temporary":
            return {"installationId": installation, "revoked": True}
        raise AssertionError(operation)

    def token_file(args, path, operation):
        operations.append(operation)
        if operation == "read":
            return files.get("token", "")
        assert operation == "remove"
        files.pop("token", None)
        return ""

    monkeypatch.setattr(probe, "credential_command", credentials)
    monkeypatch.setattr(probe, "token_file_operation", token_file)
    with pytest.raises(
        RuntimeError,
        match="Lost issuance reply" if lost_issuance_reply else "Probe failed",
    ):
        async with probe.temporary_installation(
            Namespace(ssh_host="fixture"),
            GatewayConfig("fixture", 80, "operator", "ws"),
        ) as cfg:
            assert cfg.token == "rc1.temporary.secret"
            raise RuntimeError("Probe failed")
    assert "revoke temporary" in operations
    assert operations[-1] == "remove"
    assert files == {}
