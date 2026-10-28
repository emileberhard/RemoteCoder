import argparse
import base64
import json
import os
import shlex
import socket
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

from .transport import (
    GatewayIdentityError,
    GatewayTLSIdentity,
    http_client,
    require_secure_transport,
)

DEFAULT_CODEX_PROBE_MODEL = "gpt-6-sol"


@dataclass(frozen=True)
class GatewayConfig:
    host: str
    port: int
    token: str
    scheme: str  # "ws" or "wss"
    account_id: str | None = None
    account_generation: int | None = None
    tls_identity: GatewayTLSIdentity | None = None

    def http_client(self, timeout: float):
        return http_client(self, timeout)

    @property
    def ws_url(self) -> str:
        url = f"{self.scheme}://{self.host}:{self.port}/ws"
        if self.account_id is not None:
            url += "?" + urlencode({"accountId": self.account_id, "accountGeneration": self.account_generation})
        return url

    @property
    def http_base(self) -> str:
        scheme = "https" if self.scheme == "wss" else "http"
        return f"{scheme}://{self.host}:{self.port}"


def add_connection_arguments(parser: argparse.ArgumentParser) -> None:
    conn = parser.add_argument_group("connection", "gateway connection and config discovery")
    conn.add_argument("--debug", action="store_true", help="print full stack traces on errors")
    conn.add_argument("--host", default=None, help="gateway host (overrides discovery)")
    conn.add_argument("--port", type=int, default=None, help="gateway port (overrides discovery)")
    conn.add_argument("--scheme", default=None, choices=["ws", "wss"], help="websocket scheme (default: discover pinned TLS)")
    conn.add_argument("--spki-sha256", help="base64 SPKI SHA-256 pin for an explicitly configured WSS endpoint")
    conn.add_argument("--token", default=None, help="bearer token (overrides discovery)")
    conn.add_argument(
        "--ssh-host",
        default=None,
        help="explicit SSH target for discovery and journals; always uses SSH",
    )
    conn.add_argument("--ssh-env-path", default="~/.remote-coder/codex-gateway.env", help="remote env file path")
    conn.add_argument("--no-ssh-env", action="store_true", help="skip SSH-based config discovery")
    conn.add_argument(
        "--local-config",
        default="RemoteCoder/Resources/RemoteCoderLocalConfig.json",
        help="ignored app-local config JSON for fallback discovery",
    )


def _redact_token(token: str) -> str:
    return "<configured>" if token.strip() else ""


def _parse_env_lines(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.strip()
        if not k:
            continue
        # Support common .env quoting.
        if len(v) >= 2 and ((v[0] == v[-1] == '"') or (v[0] == v[-1] == "'")):
            v = v[1:-1]
        out[k] = v
    return out


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _read_local_config(local_config_path: Path) -> dict[str, Any]:
    try:
        raw = _read_text(local_config_path)
    except FileNotFoundError:
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def _matches_local_identity(hostname: str) -> bool:
    name = hostname.casefold().removesuffix(".")
    if name == socket.gethostname().casefold().removesuffix("."):
        return True
    try:
        result = subprocess.run(["tailscale", "status", "--json", "--peers=false"], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=2, check=False)
        if result.returncode != 0:
            return False
        status = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return False
    if not isinstance(status, dict) or not isinstance(status.get("Self"), dict):
        return False
    addresses = status["Self"].get("TailscaleIPs")
    if isinstance(addresses, list) and name in (address.casefold() for address in addresses if isinstance(address, str)):
        return True
    dns_name = status["Self"].get("DNSName")
    if not isinstance(dns_name, str):
        return False
    dns_name = dns_name.casefold().removesuffix(".")
    return bool(dns_name) and name == dns_name


def _gateway_read_host(args: argparse.Namespace) -> str | None:
    ssh_host = getattr(args, "ssh_host", None)
    if ssh_host is None:
        ssh_host = os.environ.get("RC_CODEX_GATEWAY_SSH_HOST")
    if ssh_host is not None:
        return ssh_host
    selected = (getattr(args, "host", None) or os.environ.get("RC_CODEX_GATEWAY_HOST") or "").strip()
    if not selected:
        return None
    path = getattr(args, "local_config", None)
    try:
        configuration = _read_local_config(Path(path)) if path else {}
    except (OSError, UnicodeError):
        configuration = {}
    entries = [hostname for field in ("macMiniHostname", "macBookHostname")
               if isinstance(hostname := configuration.get(field), str) and hostname]
    matches = [hostname for hostname in entries
               if hostname.casefold().removesuffix(".") == selected.casefold().removesuffix(".")]
    if len(matches) == 1 and _matches_local_identity(matches[0]):
        return None
    return selected


def _ssh_read_env(ssh_host: str, env_path: str) -> str:
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=none", ssh_host, "cat", env_path]
    try:
        res = subprocess.run(cmd, stdin=subprocess.DEVNULL, check=True, capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired as exc:
        raise TimeoutError(f"Gateway configuration read through SSH to {ssh_host} timed out after 10 seconds") from exc
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        msg = f"ssh failed: {shlex.join(cmd)}"
        if stderr:
            msg += f"\n{stderr}"
        raise RuntimeError(msg) from exc
    return res.stdout


def _ssh_hostname(ssh_host: str) -> str:
    try:
        result = subprocess.run(["ssh", "-G", ssh_host], capture_output=True, text=True, timeout=5, check=True)
    except subprocess.TimeoutExpired as exc:
        raise TimeoutError(f"Resolving SSH host {ssh_host} with ssh -G timed out after 5 seconds") from exc
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError(f"Resolving SSH host {ssh_host} with ssh -G failed: {exc}") from exc
    for line in result.stdout.splitlines():
        key, _, value = line.partition(" ")
        if key == "hostname" and value:
            return value
    raise RuntimeError(f"ssh -G {ssh_host} printed no hostname")


def _gateway_tls_identity(ssh_host: str | None, token: str, health_port: int) -> tuple[int, GatewayTLSIdentity]:
    script = """import contextlib, http.client, json, sys
values = json.load(sys.stdin)
try:
    with contextlib.closing(http.client.HTTPConnection('127.0.0.1', values['port'], timeout=5)) as connection:
        connection.request('GET', '/health', headers={'Authorization': 'Bearer ' + values['token']})
        response = connection.getresponse()
        if response.status >= 500:
            raise SystemExit(76)
        if response.status != 200:
            raise RuntimeError('Gateway identity health request did not succeed')
        data = response.read(65537)
except TimeoutError:
    raise SystemExit(75)
except ConnectionError:
    raise SystemExit(76)
if len(data) > 65536:
    raise RuntimeError('Gateway health response exceeds the identity lookup limit')
print(json.dumps(json.loads(data)['lanEndpoint']))
"""
    command = ["python3", "-c", script]
    location = "on this host" if ssh_host is None else f"through SSH to {ssh_host}"
    if ssh_host is not None:
        command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=none", ssh_host, shlex.join(command)]
    try:
        result = subprocess.run(command, input=json.dumps({"token": token, "port": health_port}), capture_output=True,
                                text=True, check=True, timeout=10)
        endpoint = json.loads(result.stdout)
        port = endpoint["port"]
        if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
            raise ValueError("Invalid LAN TLS port")
        return port, GatewayTLSIdentity(endpoint["host"], base64.b64decode(endpoint["spkiSha256"], validate=True))
    except subprocess.TimeoutExpired as error:
        raise TimeoutError(f"Gateway TLS identity discovery {location} timed out after 10 seconds") from error
    except subprocess.CalledProcessError as error:
        if error.returncode == 75:
            raise TimeoutError(f"Gateway TLS identity health request to 127.0.0.1:{health_port} on {ssh_host or 'this host'} timed out after 5 seconds") from error
        if error.returncode == 76:
            raise ConnectionError(f"Gateway TLS identity health request to 127.0.0.1:{health_port} on {ssh_host or 'this host'} is unavailable") from error
        raise GatewayIdentityError(f"Cannot establish the gateway TLS identity {location}") from error
    except (subprocess.SubprocessError, KeyError, TypeError, ValueError, GatewayIdentityError) as error:
        raise GatewayIdentityError(f"Cannot establish the gateway TLS identity {location}") from error


def _resolve_config(args: argparse.Namespace) -> GatewayConfig:
    # 1) Explicit CLI flags.
    host_from_flags = args.host is not None
    host_from_env = False
    host_from_ssh = False
    discovery_error = None
    env = {}
    host = (args.host or "").strip() or None
    port = args.port
    token = (args.token or "").strip() or None
    scheme = (args.scheme or "").strip() or None

    # 2) Env vars (convenient in shells/CI).
    if host is None:
        env_host = os.environ.get("RC_CODEX_GATEWAY_HOST")
        if env_host:
            host = env_host
            host_from_env = True
    if port is None:
        env_port = os.environ.get("RC_CODEX_GATEWAY_PORT")
        if env_port:
            try:
                port = int(env_port)
            except ValueError:
                pass
    if token is None:
        token = os.environ.get("RC_CODEX_GATEWAY_AUTH_TOKEN")
    if (host is None and getattr(args, "ssh_host", None) is None
            and os.environ.get("RC_CODEX_GATEWAY_SSH_HOST") is None):
        host = "127.0.0.1"

    # 3) Host-owned configuration discovery.
    needs_tls_identity = scheme != "ws" and not getattr(args, "spki_sha256", None)
    read_host = _gateway_read_host(args) if not args.no_ssh_env else None
    if (host is None or port is None or token is None or needs_tls_identity) and args.no_ssh_env is False:
        try:
            raw = (_ssh_read_env(read_host, args.ssh_env_path) if read_host is not None
                   else Path(args.ssh_env_path).expanduser().read_text(encoding="utf-8"))
            env = _parse_env_lines(raw)
            if host is None:
                host = env.get("RC_CODEX_GATEWAY_BIND_HOST")
                host_from_ssh = host is not None
            if port is None:
                try:
                    port = int(env.get("RC_CODEX_GATEWAY_PORT", ""))
                except ValueError:
                    port = None
            token = token or env.get("RC_CODEX_GATEWAY_AUTH_TOKEN")
        except Exception as error:
            # Keep going; dev tool should still be usable with explicit flags.
            discovery_error = error

    # If discovery only gives us a bind host, connect through the selected remote host
    # or this machine's loopback for a local read.
    # If the user explicitly provided --host or RC_CODEX_GATEWAY_HOST, respect it verbatim.
    if (
        host_from_ssh
        and (not host_from_flags)
        and (not host_from_env)
        and host in ("0.0.0.0", "127.0.0.1", "::")
    ):
        host = _ssh_hostname(read_host) if read_host else "127.0.0.1"

    # 4) Ignored local app config fallback (best-effort).
    if (host is None or port is None or token is None) and args.local_config:
        local_config = _read_local_config(Path(args.local_config))
        if host is None:
            host = local_config.get("macMiniHostname") or local_config.get("macBookHostname")
        if port is None:
            try:
                port = int(local_config.get("codexGatewayPort", ""))
            except (TypeError, ValueError):
                port = None
        token = token or local_config.get("codexGatewayAuthToken")

    if (host is None or port is None or token is None or (needs_tls_identity and not env)) and isinstance(discovery_error, TimeoutError):
        raise discovery_error

    if host is None:
        raise SystemExit(discovery_error or "missing gateway host (use --host or enable SSH discovery)")
    if port is None:
        raise SystemExit(discovery_error or "missing gateway port (use --port or enable SSH discovery)")
    if token is None:
        raise SystemExit(discovery_error or "missing gateway token (use --token, SSH discovery, or local config)")
    identity = None
    if pin := getattr(args, "spki_sha256", None):
        try:
            identity = GatewayTLSIdentity(host, base64.b64decode(pin, validate=True))
        except (ValueError, GatewayIdentityError) as error:
            raise SystemExit("Invalid gateway SPKI pin") from error
        scheme = scheme or "wss"
    elif not args.no_ssh_env and scheme != "ws":
        try:
            health_port = int(env["RC_CODEX_GATEWAY_PORT"])
        except (KeyError, ValueError) as error:
            raise GatewayIdentityError(discovery_error or "Trusted gateway configuration has no health port") from error
        tls_port, identity = _gateway_tls_identity(read_host, token, health_port)
        if args.port is not None and args.port != tls_port:
            raise GatewayIdentityError("Explicit port does not match the gateway's trusted TLS listener")
        port = tls_port
        scheme = "wss"
    else:
        scheme = scheme or "ws"
    if scheme not in ("ws", "wss"):
        raise SystemExit("invalid --scheme (expected ws or wss)")

    cfg = GatewayConfig(host=host, port=int(port), token=token, scheme=scheme, tls_identity=identity)
    require_secure_transport(cfg)
    return cfg


def resolve_gateway_config(host: str | None, ssh_host: str | None, local_config: Path) -> GatewayConfig:
    return _resolve_config(argparse.Namespace(
        host=host,
        port=None,
        token=None,
        scheme=None,
        no_ssh_env=False,
        ssh_host=ssh_host,
        ssh_env_path="~/.remote-coder/codex-gateway.env",
        local_config=str(local_config),
    ))
