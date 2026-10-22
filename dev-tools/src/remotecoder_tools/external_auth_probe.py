import argparse
import asyncio
import base64
import json
import re
import shutil
import socket
import tempfile
import threading
import time
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from websockets.asyncio.client import connect

from remotecoder_tools.external_auth_identity import (
    package_identity,
    require,
    verify_package,
    verify_requested_identity,
)

ACCOUNT = "phase0-account"
REFRESH = "account/chatgptAuthTokens/refresh"
NETWORK_POLICY = '(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))'


def token(label, account=ACCOUNT, expired=False):
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

    now = int(time.time())
    return ".".join(
        [
            encode({"alg": "none"}),
            encode(
                {
                    "email": f"{label}@example.invalid",
                    "iat": now - 7200 if expired else now,
                    "exp": now - 60 if expired else now + 3600,
                    "https://api.openai.com/auth": {
                        "chatgpt_user_id": "phase0-user",
                        "chatgpt_account_id": account,
                        "chatgpt_plan_type": "pro",
                    },
                }
            ),
            "c3ludGhldGlj",
        ]
    )


def token_label(value: str | None):
    if value is None or value == "":
        return "absent"
    try:
        claims = json.loads(base64.urlsafe_b64decode(value.split(".")[1] + "==="))
        return claims["email"].split("@")[0]
    except IndexError, ValueError, KeyError:
        return "unrecognized"


class Backend:
    def __init__(self, models):
        self.models = models
        self.requests = []
        self.inference = []
        self.accept_initial = False
        self.hold_started = threading.Event()
        self.hold_release = threading.Event()
        self.initial_barrier = None
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:
                pass

            def reply(self, status, body, content_type="application/json"):
                raw = (
                    body.encode()
                    if isinstance(body, str)
                    else json.dumps(body).encode()
                )
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_CONNECT(self):
                owner.requests.append({"method": "CONNECT", "path": self.path})
                self.reply(502, {"error": "external network forbidden"})

            def do_GET(self):
                label = token_label(
                    self.headers.get("Authorization", "").removeprefix("Bearer ")
                )
                owner.requests.append(
                    {"method": "GET", "path": self.path, "token": label}
                )
                if self.path.split("?")[0].endswith("/accounts/check"):
                    self.reply(
                        200,
                        {
                            "accounts": [
                                {
                                    "id": self.headers.get(
                                        "chatgpt-account-id", ACCOUNT
                                    ),
                                    "workspace_backend_origin": "https://chatgpt.com",
                                    "account_routing_override": "NO_CONSTRAINT",
                                }
                            ]
                        },
                    )
                elif "/models" in self.path:
                    self.reply(200, owner.models)
                elif self.path.split("?")[0].endswith("/usage"):
                    if label == "initial":
                        self.reply(
                            401, {"error": {"message": "expired synthetic token"}}
                        )
                    else:
                        self.reply(
                            200,
                            {
                                "plan_type": "pro",
                                "rate_limit": {
                                    "allowed": True,
                                    "limit_reached": False,
                                    "primary_window": {
                                        "used_percent": 17,
                                        "limit_window_seconds": 18000,
                                        "reset_after_seconds": 120,
                                        "reset_at": int(time.time()) + 120,
                                    },
                                },
                            },
                        )
                elif "rate-limit-reset-credits" in self.path:
                    self.reply(200, {"credits": [], "available_count": 0})
                elif self.path.endswith("/settings/user"):
                    self.reply(200, {"commit_attribution_enabled": False})
                else:
                    self.reply(200, {})

            def do_POST(self):
                body = json.loads(
                    self.rfile.read(int(self.headers.get("Content-Length", "0")))
                )
                label = token_label(
                    self.headers.get("Authorization", "").removeprefix("Bearer ")
                )
                owner.requests.append(
                    {"method": "POST", "path": self.path, "token": label}
                )
                if not self.path.endswith("/responses"):
                    self.reply(200, {})
                    return
                has_output = any(
                    item.get("type") == "function_call_output"
                    for item in body.get("input", [])
                )
                hold = (
                    "hold_sibling" in json.dumps(body.get("input", []))
                    and not has_output
                )
                owner.inference.append(
                    {"token": label, "toolOutput": has_output, "hold": hold}
                )
                if label == "absent" or label == "initial" and not owner.accept_initial:
                    if owner.initial_barrier:
                        try:
                            owner.initial_barrier.wait(timeout=5)
                        except threading.BrokenBarrierError:
                            pass
                    self.reply(
                        401, {"error": {"message": "unauthorized synthetic token"}}
                    )
                    return
                rid = f"phase0-response-{len(owner.inference)}"
                events: list[dict[str, object]] = [
                    {"type": "response.created", "response": {"id": rid}}
                ]
                if hold:
                    owner.hold_started.set()
                    owner.hold_release.wait(timeout=20)
                    item = {
                        "type": "function_call",
                        "call_id": "phase0-tool-call",
                        "name": "phase0_pause",
                        "arguments": "{}",
                    }
                else:
                    item = {
                        "type": "message",
                        "role": "assistant",
                        "id": "phase0-message",
                        "content": [{"type": "output_text", "text": "phase0 ok"}],
                    }
                events += [
                    {"type": "response.output_item.done", "item": item},
                    {
                        "type": "response.completed",
                        "response": {
                            "id": rid,
                            "usage": {
                                "input_tokens": 1,
                                "output_tokens": 1,
                                "total_tokens": 2,
                            },
                        },
                    },
                ]
                self.reply(
                    200,
                    "".join("data: " + json.dumps(event) + "\n\n" for event in events),
                    "text/event-stream",
                )

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(
            target=lambda: self.server.serve_forever(poll_interval=0.05), daemon=True
        )
        self.server.timeout = 0.1
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.hold_release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class Client:
    def __init__(self, ws, name, handler):
        self.ws = ws
        self.name = name
        self.handler = handler
        self.pending = {}
        self.events = []
        self.requests = []
        self.replies = []
        self.sequence = 100
        self.tasks = set()
        self.pump = asyncio.create_task(self.receive())

    async def receive(self):
        async for raw in self.ws:
            message = json.loads(raw)
            if "method" in message and "id" in message:
                self.requests.append(message)
                task = asyncio.create_task(self.handle(message))
                self.tasks.add(task)
                task.add_done_callback(self.tasks.discard)
            elif "id" in message:
                future = self.pending.pop(message["id"], None)
                if future and not future.done():
                    future.set_result(message)
            else:
                self.events.append(message)

    async def handle(self, message):
        if message["method"] == "item/tool/call":
            answer = {
                "result": {
                    "contentItems": [{"type": "inputText", "text": "phase0 tool ok"}],
                    "success": True,
                }
            }
        else:
            answer = await self.handler(message)
        if answer:
            await self.ws.send(json.dumps({"id": message["id"], **answer}))
            self.replies.append(
                {
                    "method": message["method"],
                    "id": message["id"],
                    "kind": "error" if "error" in answer else "result",
                    "errorCode": answer.get("error", {}).get("code"),
                }
            )

    async def rpc(self, method, params=None):
        self.sequence += 1
        rid = self.sequence
        future = asyncio.get_running_loop().create_future()
        self.pending[rid] = future
        await self.ws.send(json.dumps({"id": rid, "method": method, "params": params}))
        return await asyncio.wait_for(future, timeout=20)

    async def notification(self, method, thread=None):
        async def wait():
            while True:
                for index, message in enumerate(self.events):
                    if message.get("method") == method and (
                        thread is None
                        or message.get("params", {}).get("threadId") == thread
                    ):
                        return self.events.pop(index)
                await asyncio.sleep(0.01)

        return await asyncio.wait_for(wait(), 20)

    async def close(self):
        await self.ws.close()
        await asyncio.gather(self.pump, return_exceptions=True)
        for task in self.tasks:
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)


class Runtime:
    def __init__(self, binary, backend, root, pinned=False):
        self.binary = binary
        self.backend = backend
        self.root = root
        self.home = root / "home"
        self.codex = self.home / "codex"
        self.codex.mkdir(parents=True, mode=0o700)
        self.home.chmod(0o700)
        (self.home / "tmp").mkdir()
        (self.codex / "config.toml").write_text(f'''
model = "mock-model"
model_provider = "phase0"
approval_policy = "never"
sandbox_mode = "read-only"
cli_auth_credentials_store = "file"
chatgpt_base_url = "{backend.url}/backend-api"
{'forced_chatgpt_workspace_id = "' + ACCOUNT + '"' if pinned else ""}
[features]
plugins = false
apps = false
enable_request_compression = false
[model_providers.phase0]
name = "OpenAI"
base_url = "{backend.url}/v1"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
''')
        self.clients = []
        self.logs = []

    async def start(self):
        env = {
            "HOME": str(self.home),
            "CODEX_HOME": str(self.codex),
            "CODEX_APP_SERVER_MANAGED_CONFIG_PATH": str(
                self.codex / "managed_config.toml"
            ),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "TMPDIR": str(self.home / "tmp"),
            "RUST_LOG": "warn",
            "HTTP_PROXY": self.backend.url,
            "HTTPS_PROXY": self.backend.url,
            "NO_PROXY": "127.0.0.1,localhost",
        }
        self.env_keys = sorted(env)
        self.process = await asyncio.create_subprocess_exec(
            "/usr/bin/sandbox-exec",
            "-p",
            NETWORK_POLICY,
            str(self.binary),
            "app-server",
            "--listen",
            "ws://127.0.0.1:0",
            cwd=self.root,
            env=env,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        stderr = self.process.stderr
        if stderr is None:
            raise RuntimeError("App-server stderr pipe is unavailable")
        while True:
            line = await asyncio.wait_for(stderr.readline(), timeout=20)
            if not line:
                raise RuntimeError("app-server startup failed: " + "\n".join(self.logs))
            text = re.sub(r"\x1b\[[0-9;]*m", "", line.decode())
            self.logs.append(text)
            match = re.search(r"ws://127\.0\.0\.1:\d+", text)
            if match:
                self.url = match.group()
                break

        async def drain():
            async for line in stderr:
                self.logs.append(line.decode())

        self.drain = asyncio.create_task(drain())

    async def connect(self, name, handler):
        client = Client(await connect(self.url, proxy=None), name, handler)
        self.clients.append(client)
        response = await client.rpc(
            "initialize",
            {
                "clientInfo": {"name": name, "version": "phase0"},
                "capabilities": {"experimentalApi": True},
            },
        )
        require("result" in response, f"RPC failed: {safe(response)}")
        await client.ws.send(json.dumps({"method": "initialized"}))
        return client

    async def stop(self):
        for client in self.clients:
            await client.close()
        self.clients.clear()
        if not hasattr(self, "process"):
            return
        if self.process.returncode is None:
            self.process.terminate()
        try:
            await asyncio.wait_for(self.process.wait(), timeout=10)
        except TimeoutError:
            self.process.kill()
            await self.process.wait()
        if hasattr(self, "drain"):
            await self.drain
        require(
            not (self.codex / "auth.json").exists(), "External auth persisted to disk"
        )
        require(
            not any(r["method"] == "CONNECT" for r in self.backend.requests),
            "Attempted nonlocal network",
        )


async def reject(message):
    return {"error": {"code": -32601, "message": "unhandled server request"}}


async def login(client, access, account=ACCOUNT):
    response = await client.rpc(
        "account/login/start",
        {
            "type": "chatgptAuthTokens",
            "accessToken": access,
            "chatgptAccountId": account,
            "chatgptPlanType": "pro",
        },
    )
    require(
        response.get("result") == {"type": "chatgptAuthTokens"},
        f"External login failed: {safe(response)}",
    )
    return response


async def start_thread(client, dynamic=False):
    params = {"model": "mock-model"}
    if dynamic:
        params["dynamicTools"] = [
            {
                "type": "function",
                "name": "phase0_pause",
                "description": "Deterministic pause tool",
                "inputSchema": {"type": "object", "properties": {}},
                "deferLoading": False,
            }
        ]
    response = await client.rpc("thread/start", params)
    require("result" in response, f"RPC failed: {safe(response)}")
    return response["result"]["thread"]["id"]


async def start_turn(client, thread, text="Hello"):
    return await client.rpc(
        "turn/start", {"threadId": thread, "input": [{"type": "text", "text": text}]}
    )


async def completed(client, thread):
    return (await client.notification("turn/completed", thread))["params"]["turn"]


def safe(value):
    if isinstance(value, dict):
        return {
            key: ("present" if val else None)
            if key in ["authToken", "accessToken"]
            else safe(val)
            for key, val in value.items()
        }
    if isinstance(value, list):
        return [safe(item) for item in value]
    return value


async def case(binary, models, name):
    backend = Backend(models)
    row = {"case": name}
    with tempfile.TemporaryDirectory(prefix="codex-external-auth-phase0-") as raw_root:
        root = Path(raw_root)
        runtime = Runtime(binary, backend, root, pinned=name == "wrong_account")
        initial = token("initial", expired=name == "expired_reads")
        renewed = token(
            "renewed", account="wrong-account" if name == "wrong_account" else ACCOUNT
        )
        refresh_seen = asyncio.Event()
        release_refresh = asyncio.Event()
        delay = (
            0.5
            if name in ["race", "concurrent"]
            else 11
            if name == "timeout_late"
            else 0
        )

        async def renew(message):
            if message["method"] != REFRESH:
                return await reject(message)
            refresh_seen.set()
            if name in ("refresh_then_relogin", "owner_disconnect"):
                await release_refresh.wait()
            await asyncio.sleep(delay)
            return {
                "result": {
                    "accessToken": renewed,
                    "chatgptAccountId": "wrong-account"
                    if name == "wrong_account"
                    else ACCOUNT,
                    "chatgptPlanType": "pro",
                }
            }

        try:
            await runtime.start()
            owner = await runtime.connect("phase0_auth_owner", renew)
            consumer = await runtime.connect("phase0_autoreject", reject)
            if name == "restart":
                row["beforeInstall"] = safe(
                    await consumer.rpc("account/read", {"refreshToken": False})
                )
                await runtime.stop()
                await runtime.start()
                owner = await runtime.connect("phase0_auth_owner", renew)
                consumer = await runtime.connect("phase0_autoreject", reject)
                row["restartBeforeInstall"] = safe(
                    await consumer.rpc("account/read", {"refreshToken": False})
                )
            await login(owner, initial)
            if name == "expired_reads":
                row["accountRead"] = safe(
                    await consumer.rpc("account/read", {"refreshToken": True})
                )
                status = await consumer.rpc(
                    "getAuthStatus", {"includeToken": True, "refreshToken": True}
                )
                row["authStatus"] = safe(status)
                row["exposesExactBearer"] = (
                    status.get("result", {}).get("authToken") == initial
                )
                row["rateLimitsExpired"] = safe(
                    await consumer.rpc(
                        "account/rateLimits/read", {"excludeResetCreditDetails": True}
                    )
                )
                await login(owner, token("renewed"))
                row["rateLimitsRenewed"] = safe(
                    await consumer.rpc(
                        "account/rateLimits/read", {"excludeResetCreditDetails": True}
                    )
                )
            elif name == "restart":
                backend.accept_initial = True
                thread = await start_thread(consumer)
                await start_turn(consumer, thread)
                row["sourceTurn"] = safe(await completed(consumer, thread))
                backend.accept_initial = False
                row["thread"] = thread
                row["installed"] = safe(
                    await consumer.rpc("account/read", {"refreshToken": False})
                )
                await runtime.stop()
                await runtime.start()
                owner = await runtime.connect("phase0_auth_owner", renew)
                consumer = await runtime.connect("phase0_autoreject", reject)
                row["restartAfterInstall"] = safe(
                    await consumer.rpc("account/read", {"refreshToken": False})
                )
                resumed = await consumer.rpc("thread/resume", {"threadId": thread})
                row["resumeBeforeLogin"] = (
                    "result" if "result" in resumed else safe(resumed)
                )
                row["turnBeforeLogin"] = safe(await start_turn(consumer, thread))
                if "result" in row["turnBeforeLogin"]:
                    row["unauthenticatedTurn"] = safe(await completed(consumer, thread))
                await login(owner, token("renewed"))
                restarted_turn = await start_turn(consumer, thread)
                require(
                    "result" in restarted_turn,
                    f"Restarted turn failed: {safe(restarted_turn)}",
                )
                row["turnAfterLogin"] = safe(await completed(consumer, thread))
            elif name == "sibling_relogin":
                backend.accept_initial = True
                sibling = await start_thread(consumer, dynamic=True)
                other = await start_thread(consumer)
                await start_turn(consumer, sibling, "hold_sibling")
                require(
                    await asyncio.to_thread(backend.hold_started.wait, 10),
                    "Sibling inference did not reach barrier",
                )
                row["siblingLiveDuringLogin"] = True
                await login(owner, token("renewed"))
                await start_turn(consumer, other)
                row["otherTurn"] = safe(await completed(consumer, other))
                backend.hold_release.set()
                row["siblingTurn"] = safe(await completed(consumer, sibling))
            else:
                threads = [await start_thread(consumer)]
                if name == "concurrent":
                    threads.append(await start_thread(consumer))
                    backend.initial_barrier = threading.Barrier(2)
                if name == "owner_gone":
                    await owner.close()
                    runtime.clients.remove(owner)
                started = time.monotonic()
                await asyncio.gather(
                    *[start_turn(consumer, thread) for thread in threads]
                )
                if name == "owner_disconnect":
                    await asyncio.wait_for(refresh_seen.wait(), 10)
                    await owner.close()
                    runtime.clients.remove(owner)
                if name == "refresh_then_relogin":
                    await asyncio.wait_for(refresh_seen.wait(), 10)
                    await login(owner, token("proactive"))
                    release_refresh.set()
                row["turns"] = [
                    safe(await completed(consumer, thread)) for thread in threads
                ]
                row["elapsedSeconds"] = round(time.monotonic() - started, 3)
                if name == "timeout_late":
                    await asyncio.sleep(1.5)
                    status = await consumer.rpc("getAuthStatus", {"includeToken": True})
                    row["lateSuccessInstalled"] = (
                        status.get("result", {}).get("authToken") == renewed
                    )
                    await login(owner, token("proactive"))
                    await start_turn(consumer, threads[0])
                    row["afterExplicitLogin"] = safe(
                        await completed(consumer, threads[0])
                    )
                if name in ["wrong_account", "refresh_then_relogin"]:
                    status = await consumer.rpc("getAuthStatus", {"includeToken": True})
                    row["authStatusAfter"] = safe(status)
                    row["finalTokenLabel"] = token_label(
                        status.get("result", {}).get("authToken", "")
                    )
                    row["accountAfter"] = safe(
                        await consumer.rpc("account/read", {"refreshToken": False})
                    )
            row["refreshRequests"] = {
                "owner": len([r for r in owner.requests if r["method"] == REFRESH]),
                "consumer": len(
                    [r for r in consumer.requests if r["method"] == REFRESH]
                ),
            }
            row["refreshReplies"] = {
                "owner": [
                    reply for reply in owner.replies if reply["method"] == REFRESH
                ],
                "consumer": [
                    reply for reply in consumer.replies if reply["method"] == REFRESH
                ],
            }
            row["previousAccountIds"] = [
                request["params"].get("previousAccountId")
                for request in owner.requests
                if request["method"] == REFRESH
            ]
            row["inference"] = backend.inference
            row["backendRequests"] = backend.requests
            row["environmentKeys"] = runtime.env_keys
            row["diskAuthAbsent"] = not (runtime.codex / "auth.json").exists()
            row["networkRestriction"] = NETWORK_POLICY
        finally:
            release_refresh.set()
            backend.hold_release.set()
            try:
                await runtime.stop()
            finally:
                await asyncio.to_thread(backend.close)
    validate_case(row)
    row["status"] = "passed"
    return row


CASES = (
    "race",
    "owner_gone",
    "owner_disconnect",
    "concurrent",
    "timeout_late",
    "wrong_account",
    "expired_reads",
    "restart",
    "sibling_relogin",
    "refresh_then_relogin",
)


def validate_case(row):
    name = row["case"]
    require(name in CASES, f"Unknown external auth case: {name}")
    require(row["diskAuthAbsent"], f"{name}: external auth persisted to disk")
    require(
        row["refreshRequests"]["consumer"] == 0, f"{name}: refresh reached consumer"
    )
    require(
        not any(request["method"] == "CONNECT" for request in row["backendRequests"]),
        f"{name}: attempted nonlocal network",
    )
    require(
        all(account == ACCOUNT for account in row["previousAccountIds"]),
        f"{name}: callback account changed",
    )
    inference = row["inference"]
    statuses = [turn["status"] for turn in row.get("turns", [])]
    if name in ("race", "concurrent", "refresh_then_relogin"):
        require(
            statuses == ["completed"] * (2 if name == "concurrent" else 1),
            f"{name}: turn failed",
        )
        require(row["refreshRequests"]["owner"] >= 1, f"{name}: owner callback absent")
        expected = "proactive" if name == "refresh_then_relogin" else "renewed"
        require(
            sum(request["token"] == expected for request in inference) == len(statuses),
            f"{name}: retry used wrong token",
        )
        if name == "refresh_then_relogin":
            require(
                row["finalTokenLabel"] == "proactive",
                "Old callback superseded proactive login",
            )
    elif name in ("owner_gone", "owner_disconnect", "timeout_late", "wrong_account"):
        require(statuses == ["failed"], f"{name}: failed auth admitted inference")
        require(
            not any(
                request["token"] in ("renewed", "wrong-account")
                for request in inference
            ),
            f"{name}: rejected token used",
        )
        if name in ("owner_gone", "owner_disconnect"):
            require(
                row["elapsedSeconds"] < 3,
                "Disconnected owner retained pending callback until timeout",
            )
        if name == "owner_gone":
            require(
                row["refreshRequests"]["owner"] == 0 and len(inference) == 1,
                "Disconnected owner caused callback or retry",
            )
        elif name == "owner_disconnect":
            require(
                row["refreshRequests"]["owner"] == 1 and len(inference) == 1,
                "Owner disconnect did not cancel pending refresh",
            )
        elif name == "timeout_late":
            require(
                row["refreshRequests"]["owner"] == 1,
                "Timeout case did not exercise callback",
            )
            require(
                "timed out" in row["turns"][0]["error"]["message"],
                "Failed turn did not exercise native refresh timeout",
            )
            require(
                not row["lateSuccessInstalled"], "Late refresh installed after timeout"
            )
            require(
                row["afterExplicitLogin"]["status"] == "completed",
                "Explicit login did not recover timeout",
            )
        else:
            require(
                row["accountAfter"]["result"]["account"] is None,
                "Wrong account left authenticated state",
            )
            require(row["finalTokenLabel"] == "absent", "Wrong account retained bearer")
    elif name == "expired_reads":
        require(
            row["refreshRequests"]["owner"] == 0,
            "Quota read unexpectedly refreshed auth",
        )
        require(
            row["accountRead"]["result"]["account"]["type"] == "chatgpt",
            "Expired metadata unreadable",
        )
        require(
            row["rateLimitsExpired"].get("error", {}).get("code") == -32603,
            "Expired quota did not fail",
        )
        require(
            "result" in row["rateLimitsRenewed"], "Fresh login did not restore quota"
        )
        require(
            "401" in row["rateLimitsExpired"]["error"]["message"],
            "Expired quota did not reach unauthorized mock",
        )
        require(
            row["rateLimitsRenewed"]["result"]["rateLimits"]["primary"]["usedPercent"]
            == 17,
            "Fresh quota did not read mock snapshot",
        )
    elif name == "restart":
        for key in ("beforeInstall", "restartBeforeInstall", "restartAfterInstall"):
            require(
                row[key]["result"]["account"] is None, f"{key}: auth survived restart"
            )
        require(row["sourceTurn"]["status"] == "completed", "Source thread failed")
        require(row["resumeBeforeLogin"] == "result", "Persisted thread did not resume")
        require(
            row["unauthenticatedTurn"]["status"] == "failed",
            "Restart admitted unauthenticated inference",
        )
        require(
            row["turnAfterLogin"]["status"] == "completed",
            "Login did not recover resumed thread",
        )
    elif name == "sibling_relogin":
        require(row["siblingLiveDuringLogin"], "Token swap did not overlap sibling")
        require(
            row["otherTurn"]["status"] == row["siblingTurn"]["status"] == "completed",
            "Sibling token swap failed",
        )
        require(
            any(
                request["toolOutput"] and request["token"] == "renewed"
                for request in inference
            ),
            "Sibling continuation used old token",
        )


async def main():
    parser = argparse.ArgumentParser(
        description="Mandatory synthetic external-token matrix; no live credentials or gateway connections."
    )
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--approval", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--requested-host-identity", type=Path, required=True)
    args = parser.parse_args()
    requested = json.loads(args.requested_host_identity.read_text())
    approval = json.loads(args.approval.read_text())
    receipt = {
        "schemaVersion": 1,
        "observedAtUtc": datetime.now(UTC).isoformat(),
        "requestedHost": requested["requestedHost"],
        "executionHost": socket.gethostname(),
        "requestedHostIdentity": requested,
        "sourceCommit": approval["codexForkCommit"],
        "runtimeHashes": approval["runtimeHashes"],
        "cases": [],
        "status": "running",
    }
    with tempfile.TemporaryDirectory(
        prefix="codex-external-auth-package-"
    ) as temporary:
        package = Path(temporary) / "package"
        shutil.copytree(args.package.resolve(strict=True), package, symlinks=True)
        binary = verify_package(package, approval)
        actual = package_identity(package)
        verify_requested_identity(actual, requested)
        receipt["packageSHA256"] = actual["packageSHA256"]
        try:
            for name in CASES:
                async with asyncio.timeout(60):
                    row = await case(binary, {"models": []}, name)
                receipt["cases"].append(row)
                args.output.write_text(json.dumps(receipt, indent=2) + "\n")
                print(json.dumps({"case": name, "status": "passed"}), flush=True)
        except Exception:
            receipt["status"] = "failed"
            args.output.write_text(json.dumps(receipt, indent=2) + "\n")
            raise
    receipt["status"] = "passed"
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print("PASS approved external-token matrix", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
