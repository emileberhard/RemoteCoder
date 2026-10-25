import argparse
import asyncio
import base64
import hashlib
import itertools
import json
import re
import shlex
import subprocess
import time
import uuid
from contextlib import asynccontextmanager
from dataclasses import replace
from pathlib import Path

from .config import GatewayConfig, _resolve_config
from .diagnostics import _journal_quote, _journal_read, _journal_shell
from .rpc import _drain_ready, _initialize, _reader, _timed_rpc, _ws_connect
from .turns import _assert_e2e, _run_probe_turn, release_claude_runtime
from .verdict import cleanup_after

FIXTURE = Path(__file__).resolve().parents[2] / "fixtures/device-photo.jpg"
PROMPT = (
    "Call take_photo in the remotecoder tool set exactly once, with camera=back "
    "and lens=wide. Then describe the colors, shapes and relative positions in "
    "the returned image, and state the saved original path. Use the image from "
    "the tool; do not use shell commands or read files."
)


class FakeDevice:
    def __init__(
        self, ws, config: GatewayConfig, group: asyncio.TaskGroup, next_id
    ) -> None:
        self.ws = ws
        self.config = config
        self.group = group
        self.next_id = next_id
        self.running: dict[str, asyncio.Task] = {}
        self.operations: list[str] = []

    def observe(self, message: dict) -> None:
        method = message.get("method")
        params = message.get("params", {})
        if method == "device/tool/cancel":
            task = self.running.get(params["operationId"])
            if task is not None:
                task.cancel()
        if method != "device/tool/invoke":
            return
        operation_id = params["operationId"]
        if operation_id in self.operations or self.running or len(self.operations) >= 8:
            raise RuntimeError(
                "Fake device received a duplicate or overlapping operation"
            )
        self.operations.append(operation_id)
        self.running[operation_id] = self.group.create_task(self.answer(params))

    async def answer(self, params: dict) -> None:
        operation_id = params["operationId"]
        try:
            _assert_e2e(
                params["tool"] == "take_photo" and params["version"] == 1,
                "Unexpected device tool/version",
            )
            _assert_e2e(
                params["arguments"] == {"camera": "back", "lens": "wide"},
                "Unexpected photo arguments",
            )
            _assert_e2e(
                params["deadlineUnixMs"] > time.time() * 1000,
                "Expired fake-device invoke",
            )
            photo = await asyncio.to_thread(FIXTURE.read_bytes)
            digest = hashlib.sha256(photo).hexdigest()
            async with self.config.http_client(timeout=20.0) as client:
                upload = await client.put(
                    f"{self.config.http_base}/uploads/{uuid.uuid4()}",
                    params={"name": "device-tool-fixture.jpg"},
                    headers={
                        "Authorization": f"Bearer {self.config.token}",
                        "X-RemoteCoder-Upload-Offset": "0",
                        "X-RemoteCoder-Upload-Length": str(len(photo)),
                        "X-RemoteCoder-SHA256": digest,
                    },
                    content=photo,
                )
            upload.raise_for_status()
            stored = upload.json()
            _assert_e2e(
                stored["sha256"] == digest and stored["bytes"] == len(photo),
                "Fixture upload failed readback",
            )
            result, _, _ = await _timed_rpc(
                self.ws,
                req_id=self.next_id(),
                method="device/tool/result",
                timeout_s=20,
                params={
                    "operationId": operation_id,
                    "outcome": "succeeded",
                    "content": [
                        {
                            "type": "image",
                            "mimeType": "image/jpeg",
                            "data": base64.b64encode(photo).decode("ascii"),
                        }
                    ],
                    "originals": [
                        {
                            "path": stored["path"],
                            "sha256": digest,
                            "bytes": len(photo),
                            "camera": "back",
                            "lens": "wide",
                            "width": 320,
                            "height": 240,
                        }
                    ],
                },
            )
            _assert_e2e(
                result["accepted"] is True,
                "Gateway did not accept the fake device result",
            )
        finally:
            self.running.pop(operation_id, None)


def assert_fixture_description(text: str) -> None:
    text = text.lower()
    for term in ("red", "rectang", "blue", "circl", "left", "right"):
        _assert_e2e(
            term in text, f"Agent did not describe the fixture's {term} feature"
        )


def read_original_digest(args: argparse.Namespace, path: str) -> str:
    command = "shasum -a 256 " + shlex.quote(path)
    result = subprocess.run(
        _journal_shell(args, command),
        capture_output=True,
        text=True,
        timeout=15,
        check=True,
    )
    return result.stdout.split()[0]


async def _device_turn(args: argparse.Namespace, cfg: GatewayConfig, provider: str):
    next_id = itertools.count(10).__next__
    ws = await _ws_connect(cfg)
    thread_id = None

    def remember_thread(thread: str) -> None:
        nonlocal thread_id
        thread_id = thread

    async def release() -> None:
        if thread_id is not None and thread_id.startswith("claude_"):
            await release_claude_runtime(
                ws, next_id=next_id, thread_id=thread_id, timeout_s=args.timeout
            )

    async with ws:
        await _drain_ready(ws, timeout_s=args.timeout)
        await _initialize(ws, timeout_s=args.timeout)
        await _timed_rpc(
            ws,
            req_id=next_id(),
            method="device/tools/declare",
            params={"tools": [{"name": "take_photo", "version": 1}]},
            timeout_s=args.timeout,
        )
        try:
            async with (
                cleanup_after("release Claude runtime", release),
                asyncio.TaskGroup() as group,
            ):
                fake = FakeDevice(ws, cfg, group, next_id)
                _reader(ws).observe(fake.observe)
                run = await _run_probe_turn(
                    ws,
                    next_id=next_id,
                    prompt=PROMPT,
                    resume=None,
                    model=args.codex_model
                    if provider == "codex"
                    else args.claude_model,
                    cwd=args.cwd,
                    approval_policy="never",
                    sandbox="readOnly",
                    network_access=False,
                    timeout_s=args.timeout,
                    provider=provider,
                    purpose="probe",
                    on_thread=remember_thread,
                )
                _assert_e2e(
                    run.status == "completed", f"{provider} turn ended {run.status}"
                )
                _assert_e2e(
                    len(fake.operations) == 1,
                    f"{provider} did not invoke exactly one photo",
                )
                assert_fixture_description(run.assistant)
        finally:
            _reader(ws).observer = None
    return run, fake.operations


def credential_command(args: argparse.Namespace, operation: str) -> object:
    binary = '"$HOME/localbin/remote-coder-gateway/remote-coder-codex-gateway"'
    result = subprocess.run(
        _journal_shell(args, binary + " credentials " + operation),
        capture_output=True,
        text=True,
        timeout=15,
    )
    if result.returncode != 0:
        raise RuntimeError("Credential CLI failed on the configured gateway SSH host")
    return json.loads(result.stdout)


async def revoke_installation(args: argparse.Namespace, installation: str) -> None:
    failure = None
    for attempt in range(3):
        try:
            receipt = await asyncio.to_thread(
                credential_command, args, "revoke " + shlex.quote(installation)
            )
            if (
                not isinstance(receipt, dict)
                or receipt.get("installationId") != installation
                or receipt.get("revoked") is not True
            ):
                raise RuntimeError(
                    "Revocation receipt did not match the temporary installation"
                )
            return
        except (RuntimeError, subprocess.SubprocessError, OSError) as error:
            failure = error
            try:
                inventory = await asyncio.to_thread(credential_command, args, "list")
            except RuntimeError, subprocess.SubprocessError, OSError:
                inventory = None
            if isinstance(inventory, list) and all(
                isinstance(entry, dict)
                and isinstance(entry.get("installationId"), str)
                and isinstance(entry.get("revoked"), bool)
                for entry in inventory
            ):
                matching = [
                    entry
                    for entry in inventory
                    if entry.get("installationId") == installation
                ]
                if not matching or all(
                    entry.get("revoked") is True for entry in matching
                ):
                    return
            if attempt < 2:
                await asyncio.sleep(attempt + 1)
    raise RuntimeError(
        f"Could not revoke temporary installation {installation} on {args.ssh_host}"
    ) from failure


def token_file_operation(args: argparse.Namespace, path: str, operation: str) -> str:
    quoted = _journal_quote(path)
    command = (
        f"if [ -f {quoted} ]; then cat {quoted}; fi"
        if operation == "read"
        else "rm -f " + quoted
    )
    result = subprocess.run(
        _journal_shell(args, command), capture_output=True, text=True, timeout=15
    )
    if result.returncode != 0:
        raise RuntimeError("Temporary installation credential file operation failed")
    return result.stdout.strip()


@asynccontextmanager
async def temporary_installation(args: argparse.Namespace, cfg: GatewayConfig):
    probe_id = uuid.uuid4().hex
    token_path = "~/.remote-coder/device-tools-probe-" + probe_id + ".token"
    label = "Device tools live fixture " + probe_id
    installation = None

    async def revoke() -> None:
        nonlocal installation
        try:
            if installation is None:
                token = await asyncio.to_thread(
                    token_file_operation, args, token_path, "read"
                )
                if token:
                    fields = token.split(".")
                    if len(fields) != 3 or fields[0] != "rc1":
                        raise RuntimeError(
                            "Unrecognized temporary installation credential"
                        )
                    installation = fields[1]
                else:
                    inventory = await asyncio.to_thread(
                        credential_command, args, "list"
                    )
                    if not isinstance(inventory, list) or not all(
                        isinstance(entry, dict)
                        and isinstance(entry.get("installationId"), str)
                        and isinstance(entry.get("label"), str)
                        for entry in inventory
                    ):
                        raise RuntimeError(
                            "Temporary installation issuance could not be reconciled"
                        )
                    matching = [entry for entry in inventory if entry["label"] == label]
                    if len(matching) > 1:
                        raise RuntimeError(
                            "Temporary installation identity is ambiguous"
                        )
                    if matching:
                        installation = matching[0]["installationId"]
            if installation is not None:
                await revoke_installation(args, installation)
        finally:
            await asyncio.to_thread(token_file_operation, args, token_path, "remove")

    async with cleanup_after("revoke temporary device-tools installation", revoke):
        receipt = await asyncio.to_thread(
            credential_command,
            args,
            "issue --label "
            + shlex.quote(label)
            + " --output "
            + _journal_quote(token_path),
        )
        if not isinstance(receipt, dict) or not isinstance(
            receipt.get("installationId"), str
        ):
            raise RuntimeError(
                "The credential issuer did not return an installation identity"
            )
        installation = receipt["installationId"]
        token = await asyncio.to_thread(token_file_operation, args, token_path, "read")
        if not token.startswith("rc1." + installation + "."):
            raise RuntimeError(
                "Temporary installation credential does not match its receipt"
            )
        yield replace(cfg, token=token)


async def cmd_e2e_device_tools_live(args: argparse.Namespace) -> int:
    cfg = await asyncio.to_thread(_resolve_config, args)
    async with temporary_installation(args, cfg) as installed:
        summaries = await run_device_probes(args, installed)
    print(json.dumps({"ok": True, "probes": summaries}, indent=2))
    return 0


async def run_device_probes(args: argparse.Namespace, cfg: GatewayConfig) -> list[dict]:
    summaries = []
    started = time.time()
    for provider in ["claude", "codex"] if args.provider == "both" else [args.provider]:
        run, operations = await _device_turn(args, cfg, provider)
        thread_id = run.thread_id
        deadline = time.monotonic() + args.journal_timeout
        dispatches = []
        sent = []
        while time.monotonic() < deadline:
            records = await asyncio.to_thread(_journal_read, args, started - 1)
            relevant = [
                record
                for _, record in records
                if record.get("kind") == "tool"
                and record.get("threadId") == thread_id
                and record.get("tool") == "take_photo"
            ]
            dispatches = [
                record for record in relevant if record.get("event") == "dispatch"
            ]
            sent = [
                record for record in relevant if record.get("event") == "device_sent"
            ]
            if dispatches:
                break
            await asyncio.sleep(0.2)
        _assert_e2e(
            len(dispatches) == 1 and len(sent) == 1,
            f"{provider} journal did not prove one dispatch and one invoke",
        )
        _assert_e2e(
            dispatches[0]["source"] == provider and dispatches[0]["imageCount"] == 1,
            "Incorrect image dispatch attribution",
        )
        photo_text = dispatches[0]["text"]
        match = re.search(r"Full-size original saved at (.+)\.$", photo_text)
        if match is None:
            raise RuntimeError("Full-size original was not saved")
        path = match.group(1)
        digest = await asyncio.to_thread(read_original_digest, args, path)
        expected = hashlib.sha256(
            await asyncio.to_thread(FIXTURE.read_bytes)
        ).hexdigest()
        _assert_e2e(
            digest == expected, "Saved original differs from the uploaded fixture"
        )
        serialized = json.dumps(records)
        encoded = base64.b64encode(await asyncio.to_thread(FIXTURE.read_bytes)).decode(
            "ascii"
        )
        _assert_e2e(encoded[:80] not in serialized, "Journal contains image data")
        summaries.append(
            {
                "provider": provider,
                "threadId": thread_id,
                "turnId": run.turn_id,
                "operationId": operations[0],
                "dispatches": 1,
                "originalPath": path,
                "sha256": digest,
                "assistant": run.assistant,
            }
        )
    return summaries
