import argparse
import asyncio
import json
import shlex
import subprocess
import sys
from pathlib import Path

from remotecoder_tools.config import GatewayConfig, resolve_gateway_config

from .carrier import CarrierAPI, CarrierSettings, load_credentials, parse_boundary
from .media import AccountRead, worker_main
from .rpc import GatewayRPC
from .trace import collect_trace
from .worker_artifact import installed_contract, worker_lease

REPO_ROOT = Path(__file__).resolve().parents[2]


def ssh_network_host(host: str) -> str:
    result = subprocess.run(
        ["ssh", "-G", "--", host],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    for line in result.stdout.splitlines():
        name, _, value = line.partition(" ")
        if name == "hostname" and value.strip():
            return value.strip()
    raise RuntimeError("SSH configuration did not resolve the gateway hostname")


def gateway_connection(host: str | None) -> GatewayConfig:
    # Reuse this repository's maintained gateway discovery, including its
    # credential boundary. Never put bearer tokens in child process arguments.
    return resolve_gateway_config(
        ssh_network_host(host) if host else None,
        host,
        REPO_ROOT / "RemoteCoder/Resources/RemoteCoderLocalConfig.json",
    )


async def carrier_command(path: Path, configure: bool):
    settings = CarrierSettings.model_validate_json(
        await asyncio.to_thread(path.read_text)
    )
    credentials = await asyncio.to_thread(load_credentials, settings.credentialSource)
    api = CarrierAPI(credentials)
    try:
        public_url = (
            f"{settings.publicBaseURL}/{credentials.mediaSecret.get_secret_value()}"
        )
        if configure:
            await api.request(
                "POST",
                f"/numbers/{settings.websocketNumberId}",
                {"websocket_url": public_url},
            )
        voice, websocket = await api.numbers(settings, public_url)
        return {
            "ready": True,
            "voiceLast4": voice[-4:],
            "websocketLast4": websocket[-4:],
        }
    finally:
        await api.client.aclose()


async def run(args: argparse.Namespace):
    if args.command in {"carrier-check", "carrier-configure"}:
        return await carrier_command(args.config, args.command == "carrier-configure")
    if args.command == "trace" and args.host:
        command = shlex.join(
            [
                str(REPO_ROOT / "dev-tools/agent-call"),
                "trace",
                args.call_id,
            ]
        )
        result = await asyncio.to_thread(
            subprocess.run,
            [
                "ssh",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=5",
                "--",
                args.host,
                command,
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=45,
        )
        return json.loads(result.stdout)
    config = await asyncio.to_thread(gateway_connection, args.host)
    async with GatewayRPC.connect(config) as rpc:
        match args.command:
            case "check":
                identity = await rpc.call("calls/host", {})
                account = parse_boundary(
                    AccountRead,
                    await rpc.call("account/read", {"refreshToken": False}),
                    "account/read",
                )
                subscription = account.account is not None and account.account.type in {
                    "chatgpt",
                    "chatgptAuthTokens",
                }
                if not subscription:
                    raise RuntimeError("Gateway has no ChatGPT subscription login")
                return identity | {
                    "subscription": True,
                    "voice": await rpc.call("voice/session/status", {}),
                }
            case "request":
                brief = json.loads(args.brief.read_text())
                return await rpc.call(
                    "calls/request",
                    {
                        "conversationThreadId": args.thread,
                        "request": {
                            "requestId": args.request_id,
                            "to": args.to,
                            "brief": brief,
                        },
                    },
                )
            case "status":
                return await rpc.call("calls/status", {"callId": args.call_id})
            case "trace":
                status = await rpc.call("calls/status", {"callId": args.call_id})
                return await asyncio.to_thread(
                    collect_trace,
                    status,
                    Path.home() / "Library/Logs/remote-coder",
                    Path.home() / ".local/state/agent-calls",
                )
            case "end":
                return await rpc.call("calls/stop", {"callId": args.call_id})
            case "steer":
                return await rpc.call(
                    "calls/steer", {"callId": args.call_id, "message": args.message}
                )
            case _:
                raise ValueError("Unknown command")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Calls from an existing RemoteCoder agent: self uses the iPhone app; E.164 uses 46elks. Both use subscription GPT Live."
    )
    result.add_argument(
        "--host",
        help="Originating gateway SSH host; defaults to local gateway discovery",
    )
    sub = result.add_subparsers(dest="command", required=True)
    sub.add_parser(
        "check", help="Non-dial gateway identity, subscription and active-media check"
    )
    request = sub.add_parser(
        "request", help="Persist one call request and return its stable ID"
    )
    request.add_argument(
        "--thread",
        required=True,
        help="Exact managed conversation on the selected host",
    )
    request.add_argument(
        "--to",
        default="self",
        help="self (RemoteCoder) or an authorized E.164 recipient",
    )
    request.add_argument(
        "--brief",
        type=Path,
        required=True,
        help="JSON: purpose, language, context, scope, stopConditions, opening",
    )
    request.add_argument(
        "--request-id",
        required=True,
        help="Stable idempotency key; reuse only for the same intended attempt",
    )
    for name in ("status", "end", "steer", "trace"):
        command = sub.add_parser(name)
        command.add_argument("call_id")
        if name == "steer":
            command.add_argument(
                "message", help="Short extra guidance to the live voice partner"
            )
    for name in ("carrier-check", "carrier-configure"):
        command = sub.add_parser(
            name, help="Check / provision the Mini-owned carrier route; never dials"
        )
        command.add_argument("--config", type=Path, required=True)
    return result


def main():
    worker = sys.argv[1:] == ["--worker"]
    try:
        if sys.argv[1:] == ["--worker-contract"]:
            print(json.dumps(installed_contract()))
        elif worker:
            with worker_lease():
                installed_contract()
                asyncio.run(worker_main())
        else:
            print(
                json.dumps(asyncio.run(run(parser().parse_args())), ensure_ascii=False)
            )
    except Exception as error:
        # HTTP/Pydantic exceptions may contain the private carrier URL or input
        # token. Emit an actionable boundary without a sensitive traceback.
        message = (
            str(error) if isinstance(error, RuntimeError) else type(error).__name__
        )
        if worker:
            print(
                json.dumps({"event": "failed", "status": type(error).__name__}),
                flush=True,
            )
        else:
            print(json.dumps({"error": message}), file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
