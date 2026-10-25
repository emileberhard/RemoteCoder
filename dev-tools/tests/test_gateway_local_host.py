import base64
import json
import os
import sys
import threading
import time
from contextlib import contextmanager
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace

import pytest

from remotecoder_tools import config, gateway_cli

LOCAL_NAME = "laptop.local"
TAILSCALE_NAME = "laptop.tail000000.ts.net"
REMOTE_NAME = "workstation.tail000000.ts.net"
SSH_ALIAS = "workstation"


@pytest.fixture
def host_fixture(tmp_path, monkeypatch):
    fixture = SimpleNamespace(local=tmp_path / "local", remote=tmp_path / "remote",
                              configuration=tmp_path / "local-config.json", connections=tmp_path / "ssh-connections.json",
                              tailscale_binary=tmp_path / "tailscale", tailscale_answer=tmp_path / "tailscale-status.json")
    fixture.local.mkdir()
    fixture.remote.mkdir()
    fixture.configuration.write_text("{}")
    binary = tmp_path / "ssh"
    binary.write_text(f"""#!{sys.executable}
import json, subprocess, sys
from pathlib import Path
arguments = sys.argv[1:]
if arguments[0] == '-G':
    print('hostname ' + {{{SSH_ALIAS!r}: {REMOTE_NAME!r}}}.get(arguments[1], arguments[1].rpartition('@')[2]))
    raise SystemExit(0)
connections = Path({str(fixture.connections)!r})
calls = json.loads(connections.read_text()) if connections.exists() else []
calls.append(arguments)
connections.write_text(json.dumps(calls))
command = [value.replace({str(fixture.local)!r}, {str(fixture.remote)!r}) for value in arguments[5:]]
if command[0] == 'cat' and command[1].startswith('~/'):
    command[1] = {str(fixture.remote)!r} + '/' + command[1][2:]
raise SystemExit(subprocess.call(['/bin/sh', '-c', command[0]] if len(command) == 1 else command))
""")
    binary.chmod(0o700)
    fixture.tailscale_answer.write_text(json.dumps({"Self": {"DNSName": TAILSCALE_NAME + "."},
                                                   "Peer": {"mini": {"DNSName": REMOTE_NAME + "."}}}))
    fixture.tailscale_binary.write_text(f"""#!{sys.executable}
import json, time
from pathlib import Path
answer = json.loads(Path({str(fixture.tailscale_answer)!r}).read_text())
if isinstance(answer, dict) and answer.get('stall'):
    time.sleep(30)
print(answer.get('stdout', json.dumps(answer)) if isinstance(answer, dict) else json.dumps(answer))
raise SystemExit(answer.get('status', 0) if isinstance(answer, dict) else 0)
""")
    fixture.tailscale_binary.chmod(0o700)
    for name in ("RC_CODEX_GATEWAY_HOST", "RC_CODEX_GATEWAY_SSH_HOST", "RC_CODEX_GATEWAY_PORT", "RC_CODEX_GATEWAY_AUTH_TOKEN"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ["PATH"])
    monkeypatch.setattr(config.socket, "gethostname", lambda: LOCAL_NAME)
    return fixture


def journal_records(fixture, prefix):
    now = datetime.now(UTC)
    for source, directory in (("local", fixture.local), ("remote", fixture.remote)):
        record = {"ts": now.isoformat(), "event": "fixture/read", "kind": "rpc", "method": "fixture/read", "source": source}
        (directory / f"{prefix}-{now:%Y%m%d}.jsonl").write_text(json.dumps(record) + "\n")


HOST_SELECTIONS = [
    pytest.param(["--ssh-host", LOCAL_NAME], {"macMiniHostname": LOCAL_NAME}, {}, LOCAL_NAME, id="explicit-own-ssh"),
    pytest.param(["--ssh-host", "localhost"], {"macMiniHostname": LOCAL_NAME}, {}, "localhost", id="explicit-loopback-ssh"),
    pytest.param([], {"macMiniHostname": LOCAL_NAME}, {"RC_CODEX_GATEWAY_SSH_HOST": LOCAL_NAME}, LOCAL_NAME, id="environment-ssh"),
    pytest.param(["--ssh-host", "other-user@" + LOCAL_NAME], {"macMiniHostname": LOCAL_NAME}, {}, "other-user@" + LOCAL_NAME, id="explicit-other-account"),
    pytest.param(["--host", LOCAL_NAME], {"macMiniHostname": LOCAL_NAME}, {}, None, id="registered-os-identity"),
    pytest.param(["--host", LOCAL_NAME], {"macMiniHostname": REMOTE_NAME, "macBookHostname": LOCAL_NAME}, {}, None, id="selected-book"),
    pytest.param([], {"macMiniHostname": REMOTE_NAME, "macBookHostname": LOCAL_NAME}, {"RC_CODEX_GATEWAY_HOST": LOCAL_NAME}, None, id="environment-selected-book"),
    pytest.param(["--host", LOCAL_NAME.upper() + "."], {"macMiniHostname": LOCAL_NAME}, {}, None, id="case-and-dot"),
    pytest.param(["--host", TAILSCALE_NAME.upper() + "."], {"macMiniHostname": TAILSCALE_NAME.upper() + "."}, {}, None, id="registered-tailscale-self"),
    pytest.param(["--host", REMOTE_NAME], {"macMiniHostname": REMOTE_NAME}, {}, REMOTE_NAME, id="registered-remote"),
    pytest.param(["--host", "laptop.other.example"], {"macMiniHostname": "laptop.other.example"}, {}, "laptop.other.example", id="different-prefix-domain"),
    pytest.param(["--host", LOCAL_NAME], {}, {}, LOCAL_NAME, id="unregistered-own-name"),
    pytest.param([], {}, {}, None, id="missing-host-fields"),
    pytest.param([], {"macMiniHostname": 123}, {}, None, id="invalid-host-field"),
    pytest.param(["--host", LOCAL_NAME], {"macMiniHostname": LOCAL_NAME, "macBookHostname": LOCAL_NAME}, {}, LOCAL_NAME, id="ambiguous-entries"),
    pytest.param(["--host", "localhost"], {"macMiniHostname": "localhost"}, {}, "localhost", id="loopback-is-not-stable-identity"),
    pytest.param([], {"macBookHostname": LOCAL_NAME}, {}, None, id="default-local-with-book-entry"),
    pytest.param([], {"macMiniHostname": REMOTE_NAME, "macBookHostname": LOCAL_NAME}, {}, None, id="default-local-with-remote-mini"),
    pytest.param(["--host", TAILSCALE_NAME], {"macMiniHostname": REMOTE_NAME}, {}, TAILSCALE_NAME, id="unregistered-tailscale-self"),
]


@pytest.mark.parametrize("flags, entries, environment, read_host", HOST_SELECTIONS)
@pytest.mark.parametrize("command, directory_flag, prefix", [("journal", "--journal-dir", "gateway"),
                                                            ("desktop-journal", "--desktop-dir", "desktop")])
async def test_journal_selection_uses_registered_identity_and_preserves_explicit_ssh(
    monkeypatch, capsys, host_fixture, flags, entries, environment, read_host, command, directory_flag, prefix
):
    journal_records(host_fixture, prefix)
    host_fixture.configuration.write_text(json.dumps(entries))
    for name, value in environment.items():
        monkeypatch.setenv(name, value)
    monkeypatch.setattr(sys, "argv", ["rc-gateway", "--local-config", str(host_fixture.configuration), *flags,
                                     command, directory_flag, str(host_fixture.local), "--json"])
    assert await gateway_cli._amain() == 0
    assert json.loads(capsys.readouterr().out)["source"] == ("local" if read_host is None else "remote")
    if read_host is None:
        assert not host_fixture.connections.exists()
    else:
        assert all(arguments[:5] == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", read_host]
                   for arguments in json.loads(host_fixture.connections.read_text()))


@pytest.mark.parametrize("answer", [{"status": 1}, {"stdout": "not json"}, [], {"Self": None},
                                    {"Self": {}}, {"Self": {"DNSName": ""}}, {"Self": {"DNSName": 123}}, {"stall": True}, None],
                         ids=["nonzero", "invalid-json", "non-object", "invalid-self", "missing-dns", "empty-dns", "invalid-dns", "timeout", "unavailable"])
async def test_unavailable_tailscale_identity_retains_ssh(monkeypatch, capsys, host_fixture, answer):
    journal_records(host_fixture, "gateway")
    host_fixture.configuration.write_text(json.dumps({"macMiniHostname": TAILSCALE_NAME}))
    if answer is None:
        host_fixture.tailscale_binary.unlink()
        for name in ("sh", "cat"):
            (host_fixture.local.parent / name).symlink_to(f"/bin/{name}")
        monkeypatch.setenv("PATH", str(host_fixture.local.parent))
    else:
        host_fixture.tailscale_answer.write_text(json.dumps(answer))
    monkeypatch.setattr(sys, "argv", ["rc-gateway", "--local-config", str(host_fixture.configuration), "--host", TAILSCALE_NAME, "journal",
                                     "--journal-dir", str(host_fixture.local), "--json"])
    started = time.perf_counter()
    assert await gateway_cli._amain() == 0
    assert time.perf_counter() - started < 3
    assert json.loads(capsys.readouterr().out)["source"] == "remote"
    assert json.loads(host_fixture.connections.read_text())[-1][4] == TAILSCALE_NAME


@contextmanager
def identity_health(server_name, tls_port):
    endpoint = {"host": server_name, "port": tls_port, "spkiSha256": base64.b64encode(bytes(32)).decode()}
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append((self.path, self.headers.get("Authorization")))
            payload = json.dumps({"lanEndpoint": endpoint}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *args):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
        worker.start()
        try:
            yield server.server_port, requests
        finally:
            server.shutdown()
            worker.join()


@pytest.mark.parametrize("flags, entries, environment, read_host", HOST_SELECTIONS)
async def test_configuration_and_tls_identity_follow_the_selected_read_host(
    monkeypatch, capsys, host_fixture, flags, entries, environment, read_host
):
    host_fixture.configuration.write_text(json.dumps(entries))
    for name, value in environment.items():
        monkeypatch.setenv(name, value)
    with identity_health("local.gateway.fixture", 42424) as (local_port, local_requests), \
         identity_health("remote.gateway.fixture", 42425) as (remote_port, remote_requests):
        for owner, directory, health_port in (("local", host_fixture.local, local_port), ("remote", host_fixture.remote, remote_port)):
            (directory / "gateway.env").write_text(f"RC_CODEX_GATEWAY_BIND_HOST=127.0.0.1\nRC_CODEX_GATEWAY_PORT={health_port}\n"
                                                   f"RC_CODEX_GATEWAY_AUTH_TOKEN={owner}-fixture-bearer\n")
        monkeypatch.setattr(sys, "argv", ["rc-gateway", "--local-config", str(host_fixture.configuration), *flags,
                                         "--ssh-env-path", str(host_fixture.local / "gateway.env"), "config"])
        assert await gateway_cli._amain() == 0
    output = capsys.readouterr().out
    assert f":{42424 if read_host is None else 42425}/ws" in output
    assert "token=<configured>" in output
    assert "fixture-bearer" not in output
    assert local_requests == ([("/health", "Bearer local-fixture-bearer")] if read_host is None else [])
    assert remote_requests == ([("/health", "Bearer remote-fixture-bearer")] if read_host is not None else [])
    if read_host is None:
        assert not host_fixture.connections.exists()
    else:
        arguments = json.loads(host_fixture.connections.read_text())[-1]
        assert arguments[:5] == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=none", read_host]
        assert "fixture-bearer" not in arguments[5]


async def test_ssh_alias_connects_to_its_effective_hostname(monkeypatch, capsys, host_fixture):
    (host_fixture.remote / "gateway.env").write_text("RC_CODEX_GATEWAY_BIND_HOST=0.0.0.0\nRC_CODEX_GATEWAY_PORT=42425\n"
                                                     "RC_CODEX_GATEWAY_AUTH_TOKEN=remote-fixture-bearer\n")
    monkeypatch.setattr(sys, "argv", ["rc-gateway", "--ssh-host", SSH_ALIAS, "--spki-sha256", base64.b64encode(bytes(32)).decode(),
                                     "--ssh-env-path", str(host_fixture.local / "gateway.env"), "config"])
    assert await gateway_cli._amain() == 0
    assert f"ws_url=wss://{REMOTE_NAME}:42425/ws" in capsys.readouterr().out


async def test_default_endpoint_stays_local_with_partial_env_and_remote_app_config(monkeypatch, capsys, host_fixture):
    host_fixture.configuration.write_text(json.dumps({"macMiniHostname": REMOTE_NAME}))
    with identity_health("local.gateway.fixture", 42424) as (health_port, requests):
        (host_fixture.local / "gateway.env").write_text(f"RC_CODEX_GATEWAY_PORT={health_port}\n"
                                                       "RC_CODEX_GATEWAY_AUTH_TOKEN=local-fixture-bearer\n")
        monkeypatch.setattr(sys, "argv", ["rc-gateway", "--local-config", str(host_fixture.configuration),
                                         "--ssh-env-path", str(host_fixture.local / "gateway.env"), "config"])
        assert await gateway_cli._amain() == 0
    assert "ws_url=wss://127.0.0.1:42424/ws" in capsys.readouterr().out
    assert requests == [("/health", "Bearer local-fixture-bearer")]
    assert not host_fixture.connections.exists()


async def test_default_endpoint_stays_local_with_discovery_disabled_and_remote_app_config(monkeypatch, capsys, host_fixture):
    host_fixture.configuration.write_text(json.dumps({"macMiniHostname": REMOTE_NAME, "macBookHostname": REMOTE_NAME,
                                                     "codexGatewayPort": 42426, "codexGatewayAuthToken": "fixture-bearer"}))
    monkeypatch.setattr(sys, "argv", ["rc-gateway", "--local-config", str(host_fixture.configuration),
                                     "--no-ssh-env", "--scheme", "wss", "config"])
    assert await gateway_cli._amain() == 0
    assert "ws_url=wss://127.0.0.1:42426/ws" in capsys.readouterr().out
    assert not host_fixture.connections.exists()


def test_programmatic_ssh_target_to_own_name_retains_ssh(host_fixture):
    host_fixture.configuration.write_text(json.dumps({"macMiniHostname": LOCAL_NAME}))
    with identity_health("remote.gateway.fixture", 42425) as (health_port, requests):
        directory = host_fixture.remote / ".remote-coder"
        directory.mkdir()
        (directory / "codex-gateway.env").write_text(f"RC_CODEX_GATEWAY_BIND_HOST=127.0.0.1\nRC_CODEX_GATEWAY_PORT={health_port}\n"
                                                    "RC_CODEX_GATEWAY_AUTH_TOKEN=remote-fixture-bearer\n")
        result = config.resolve_gateway_config(None, LOCAL_NAME, host_fixture.configuration)
    assert result.port == 42425
    assert requests == [("/health", "Bearer remote-fixture-bearer")]
    assert json.loads(host_fixture.connections.read_text())[-1][4] == LOCAL_NAME
