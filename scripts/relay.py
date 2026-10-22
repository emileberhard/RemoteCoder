#!/usr/bin/env python3
"""Provision the Tailscale-independent relay and connect this Mac's gateway to it (docs/relay-route.md)."""

import argparse
import base64
import hashlib
import io
import json
import os
import plistlib
import secrets
import subprocess
import sys
import tarfile
import time
from pathlib import Path

from maintainer_config import load as maintainer_config, path as maintainer_path

REPO = Path(__file__).resolve().parent.parent
RELAY = REPO / "relay"
STATE = Path.home() / ".remote-coder" / "relay"
SERVER_STATE = STATE / "server"
GATEWAY_ENV = Path.home() / ".remote-coder" / "codex-gateway.env"
LAUNCH_AGENT_LABEL = "com.remote-coder.relay-tunnel"
LAUNCH_AGENT = Path.home() / "Library" / "LaunchAgents" / f"{LAUNCH_AGENT_LABEL}.plist"
TUNNEL_LOG = Path.home() / "Library" / "Logs" / "remote-coder" / "relay-tunnel.log"
OPERATOR_TOPOLOGY = maintainer_config().get("relayTopology")
TOPOLOGY = Path(os.environ.get("RC_RELAY_TOPOLOGY", maintainer_path().parent / OPERATOR_TOPOLOGY if OPERATOR_TOPOLOGY else STATE / "topology.json"))
KEYS = TOPOLOGY.parent / "keys"
TUNNEL_USER = "relay-tunnel"
PROXY_USER = "relay"
TINYPROXY_PORT = 8888
CLIENT_RECORD = "/etc/remote-coder-relay/client.json"


class RelayError(Exception):
    pass


def topology() -> dict:
    data = json.loads(TOPOLOGY.read_text())
    if not data["server"]["address"]:
        raise RelayError(f"{TOPOLOGY} has no server address yet")
    return data


def this_host() -> str:
    return subprocess.run(["/usr/sbin/scutil", "--get", "LocalHostName"], check=True, capture_output=True, text=True).stdout.strip()


def run(command: list[str], *, input: bytes | None = None) -> bytes:
    result = subprocess.run(command, input=input, capture_output=True)
    if result.returncode != 0:
        raise RelayError(f"{command[0]} exited with {result.returncode}: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def admin_ssh(address: str, remote_command: str, *, input: bytes | None = None) -> bytes:
    return run(
        ["/usr/bin/ssh", "-F", "/dev/null", "-i", str(Path(topology()["server"]["adminKeyFile"]).expanduser()), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
         "-o", "ConnectTimeout=10", "-o", f"UserKnownHostsFile={STATE / 'admin_known_hosts'}",
         "-o", "StrictHostKeyChecking=accept-new", f"root@{address}", remote_command],
        input=input,
    )


def write_private(path: Path, content: bytes) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_bytes(content)
    temporary.chmod(0o600)
    temporary.replace(path)


def spki_sha256(certificate_pem: bytes) -> str:
    public_key = run(["/usr/bin/openssl", "x509", "-pubkey", "-noout"], input=certificate_pem)
    der = run(["/usr/bin/openssl", "pkey", "-pubin", "-outform", "der"], input=public_key)
    return base64.b64encode(hashlib.sha256(der).digest()).decode()


def server_secrets(certificate_name: str) -> tuple[bytes, bytes, str]:
    SERVER_STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    key, certificate, credential = SERVER_STATE / "relay.key", SERVER_STATE / "relay.crt", SERVER_STATE / "credential"
    if not key.exists():
        print(f"creating a new relay key in {SERVER_STATE}; every Mac must rerun `just relay-install-client` afterwards")
        run(["/usr/bin/openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
             "-pkeyopt", "ec_param_enc:named_curve", "-nodes",
             "-keyout", str(key), "-out", str(certificate), "-days", "36500", "-subj", f"/CN={certificate_name}",
             "-addext", f"subjectAltName=DNS:{certificate_name}"])
        key.chmod(0o600)
    if not credential.exists():
        write_private(credential, secrets.token_urlsafe(32).encode())
    return key.read_bytes(), certificate.read_bytes(), credential.read_text().strip()


def tracked_tunnel_keys(hosts: dict) -> dict[str, str]:
    keys = {}
    for host in hosts:
        path = KEYS / f"{host}.pub"
        if path.exists():
            keys[host] = path.read_text().strip()
        else:
            print(f"{host} gets no tunnel login until `just relay-install-client` there writes {path}")
    return keys


def provision(_: argparse.Namespace) -> None:
    layout = topology()
    if this_host() != layout["server"]["provisioner"]:
        raise RelayError(f"only {layout['server']['provisioner']} provisions the relay; it owns the relay key and credential")
    address = layout["server"]["address"]
    key, certificate, credential = server_secrets(layout["server"]["certificateName"])
    hosts = layout["hosts"]
    authorized_keys = "".join(
        f'restrict,port-forwarding,permitlisten="127.0.0.1:{hosts[host]["port"]}" {key}\n'
        for host, key in tracked_tunnel_keys(hosts).items()
    )
    tinyproxy = "\n".join([
        "User tinyproxy", "Group tinyproxy", f"Port {TINYPROXY_PORT}", "Listen 127.0.0.1", "Timeout 3600",
        "MaxClients 64", "LogLevel Notice", "Syslog On", "Allow 127.0.0.1", "DisableViaHeader Yes",
        f'BasicAuth {PROXY_USER} {credential}',
        *[f"ConnectPort {entry['port']}" for entry in hosts.values()],
        'Filter "/etc/tinyproxy/filter"', "FilterType ere", "FilterDefaultDeny Yes", "",
    ])
    filter_rules = "".join(f"^{entry['target'].replace('.', '[.]')}$\n" for entry in hosts.values())
    hosts_block = "".join(f"127.0.0.1 {entry['target']}\n" for entry in hosts.values())
    files = {
        "haproxy.cfg": (RELAY / "server" / "haproxy.cfg").read_bytes(),
        "relay.pem": certificate + key,
        "tinyproxy.conf": tinyproxy.encode(),
        "filter": filter_rules.encode(),
        "hosts-block": hosts_block.encode(),
        "nftables.conf": (RELAY / "server" / "nftables.conf").read_bytes(),
        "sshd.conf": (RELAY / "server" / "sshd-remote-coder-relay.conf").read_text().replace(
            "@PERMIT_LISTEN@", " ".join(f"127.0.0.1:{entry['port']}" for entry in hosts.values())).encode(),
        "unattended-upgrades.conf": (RELAY / "server" / "unattended-upgrades.conf").read_bytes(),
        "authorized_keys": authorized_keys.encode(),
        "credential": credential.encode(),
        "username": PROXY_USER.encode(),
        "remote-coder-relay-hosts": (RELAY / "server" / "remote-coder-relay-hosts").read_bytes(),
        "remote-coder-relay-hosts.service": (RELAY / "server" / "remote-coder-relay-hosts.service").read_bytes(),
        "apply.sh": (RELAY / "server" / "apply.sh").read_bytes(),
    }
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode="w") as archive:
        for name, content in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(content)
            info.mode = 0o600
            archive.addfile(info, io.BytesIO(content))
    output = admin_ssh(address, 'set -euo pipefail; d="$(mktemp -d)"; trap \'rm -rf "$d"\' EXIT; tar -x -C "$d"; bash "$d/apply.sh" "$d"',
                       input=payload.getvalue())
    sys.stdout.write(output.decode())
    print(f"relay provisioned at {address}; proxy pin {spki_sha256(certificate)}")


def install_client(_: argparse.Namespace) -> None:
    layout = topology()
    host = this_host()
    entry = layout["hosts"].get(host)
    if entry is None:
        raise RelayError(f"{host} is not a relay host in {TOPOLOGY}")
    address, server = layout["server"]["address"], layout["server"]
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    tunnel_key = STATE / "tunnel_ed25519"
    if not tunnel_key.exists():
        run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", f"{host} relay tunnel", "-f", str(tunnel_key)])
    public_key = (STATE / "tunnel_ed25519.pub").read_text().strip()
    tracked = KEYS / f"{host}.pub"
    if not tracked.exists() or tracked.read_text().strip() != public_key:
        tracked.parent.mkdir(parents=True, exist_ok=True)
        tracked.write_text(public_key + "\n")
        raise RelayError(f"wrote {tracked}; commit it, run `just relay-provision`, then rerun this")

    record = json.loads(admin_ssh(address, f"cat {CLIENT_RECORD}"))
    lan_port = gateway_env().get("RC_CODEX_GATEWAY_LAN_PORT")
    if not lan_port:
        raise RelayError("the relay forwards to the gateway's LAN listener; set RC_CODEX_GATEWAY_LAN_PORT first")
    known_hosts = f"{address} {record['sshHostKey']}\n" if server["sshPort"] == 22 else f"[{address}]:{server['sshPort']} {record['sshHostKey']}\n"
    write_private(STATE / "known_hosts", known_hosts.encode())
    write_private(STATE / "ssh_config", "\n".join([
        f"Host {TUNNEL_USER}",
        f"  HostName {address}",
        f"  Port {server['sshPort']}",
        f"  User {TUNNEL_USER}",
        f"  IdentityFile {tunnel_key}",
        "  IdentitiesOnly yes",
        f"  UserKnownHostsFile {STATE / 'known_hosts'}",
        "  StrictHostKeyChecking yes",
        "  BatchMode yes",
        "  ConnectTimeout 10",
        "  ServerAliveInterval 10",
        "  ServerAliveCountMax 3",
        "  TCPKeepAlive yes",
        "  ExitOnForwardFailure yes",
        "  RequestTTY no",
        "  LogLevel ERROR",
        f"  RemoteForward 127.0.0.1:{entry['port']} 127.0.0.1:{lan_port}",
        "",
    ]).encode())
    write_private(STATE / "relay.json", json.dumps({
        "proxyHost": address,
        "proxyPort": server["proxyPort"],
        "proxySpkiSha256": record["proxySpkiSha256"],
        "targetHost": entry["target"],
        "targetPort": entry["port"],
        "username": record["username"],
        "password": record["password"],
    }, indent=2).encode())
    install_launch_agent()
    print(f"{host} tunnels {entry['target']}:{entry['port']} to 127.0.0.1:{lan_port}; restart the gateway to publish the route")


def install_launch_agent() -> None:
    TUNNEL_LOG.parent.mkdir(parents=True, exist_ok=True)
    agent = {
        "Label": LAUNCH_AGENT_LABEL,
        "ProgramArguments": ["/usr/bin/ssh", "-F", str(STATE / "ssh_config"), "-N", TUNNEL_USER],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 10,
        "ProcessType": "Interactive",
        "StandardOutPath": str(TUNNEL_LOG),
        "StandardErrorPath": str(TUNNEL_LOG),
    }
    LAUNCH_AGENT.write_bytes(plistlib.dumps(agent))
    domain = f"gui/{os.getuid()}"
    subprocess.run(["/bin/launchctl", "bootout", f"{domain}/{LAUNCH_AGENT_LABEL}"], capture_output=True)
    run(["/bin/launchctl", "bootstrap", domain, str(LAUNCH_AGENT)])


def gateway_env() -> dict[str, str]:
    values = {}
    for line in GATEWAY_ENV.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def probe(_: argparse.Namespace) -> None:
    relay = json.loads((STATE / "relay.json").read_text())
    env = gateway_env()
    token = env["RC_CODEX_GATEWAY_AUTH_TOKEN"]
    authorization = [f"Authorization: Bearer {token}"]
    health = json.loads(curl(local_gateway_url(env, "/health"), authorization))
    published = json.loads(curl(local_gateway_url(env, "/relay"), authorization))
    url = f"https://{relay['targetHost']}:{relay['targetPort']}/health"
    proxy = {"proxy": f"https://{relay['proxyHost']}:{relay['proxyPort']}", "proxy-insecure": None,
             "proxy-pinnedpubkey": f"sha256//{relay['proxySpkiSha256']}", "insecure": None, "max-time": "10"}
    good_user = f"{relay['username']}:{relay['password']}"
    gateway_pin = f"sha256//{health['lanEndpoint']['spkiSha256']}"
    wrong_pin = "sha256//" + base64.b64encode(bytes(32)).decode()
    failed = False
    started = time.monotonic()
    result = curl_status(url, {**proxy, "proxy-user": good_user, "pinnedpubkey": gateway_pin}, authorization)
    failed |= report("relay route", result, result == "http 200", started)
    refusals = [
        ("wrong relay password", {"proxy-user": f"{relay['username']}:wrong", "pinnedpubkey": gateway_pin}, url),
        ("unlisted target", {"proxy-user": good_user}, f"https://example.com:{relay['targetPort']}/"),
        ("wrong gateway pin", {"proxy-user": good_user, "pinnedpubkey": wrong_pin}, url),
    ]
    for name, options, target in refusals:
        started = time.monotonic()
        result = curl_status(target, {**proxy, **options}, [])
        failed |= report(name, result, result.startswith("curl exit") and "http" not in result, started)
    matches = published == relay
    print(f"{'ok  ' if matches else 'FAIL'} the gateway publishes this relay route on /relay")
    if failed or not matches:
        raise RelayError("relay probe failed")


def report(name: str, result: str, ok: bool, started: float) -> bool:
    print(f"{'ok  ' if ok else 'FAIL'} {name}: {result} in {int((time.monotonic() - started) * 1000)} ms")
    return not ok


def curl_config(options: dict[str, str | None], headers: list[str]) -> str:
    lines = [name if value is None else f'{name} = "{value}"' for name, value in options.items()]
    lines += [f'header = "{header}"' for header in headers]
    return "\n".join(lines) + "\n"


def curl(url: str, headers: list[str]) -> str:
    return run(["/usr/bin/curl", "--fail", "--silent", "--show-error", "--max-time", "6", "--config", "-", url],
               input=curl_config({}, headers).encode()).decode()


def curl_status(url: str, options: dict[str, str | None], headers: list[str]) -> str:
    result = subprocess.run(["/usr/bin/curl", "--silent", "--output", "/dev/null", "--write-out", "%{http_code}",
                             "--config", "-", url], input=curl_config(options, headers), capture_output=True, text=True)
    return f"http {result.stdout}" if result.returncode == 0 else f"curl exit {result.returncode}" if result.stdout in ("", "000") else f"curl exit {result.returncode}, http {result.stdout}"


def local_gateway_url(env: dict[str, str], path: str) -> str:
    host = env.get("RC_CODEX_GATEWAY_BIND_HOST", "127.0.0.1")
    host = "127.0.0.1" if host in ("0.0.0.0", "::") else host
    return f"http://{host}:{env.get('RC_CODEX_GATEWAY_PORT', '8787')}{path}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("provision", help="configure the relay server from the operator topology (run on its configured provisioner)").set_defaults(run=provision)
    commands.add_parser("install-client", help="install this Mac's tunnel and gateway relay file").set_defaults(run=install_client)
    commands.add_parser("probe", help="check this Mac's gateway through the relay").set_defaults(run=probe)
    arguments = parser.parse_args()
    try:
        arguments.run(arguments)
    except RelayError as error:
        print(f"relay: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
