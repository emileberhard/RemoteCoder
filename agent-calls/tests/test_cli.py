import json
from contextlib import nullcontext
from subprocess import CompletedProcess

import pytest
from remotecoder_tools.config import GatewayConfig
from remotecoder_tools.transport import GatewayTLSIdentity

from agent_calls import cli
from agent_calls.cli import ssh_network_host


def test_worker_failure_reaches_the_gateway_without_printing_sensitive_input(
    monkeypatch, capsys
):
    async def fail():
        raise RuntimeError("a private URL or bearer must not appear")

    monkeypatch.setattr(cli.sys, "argv", ["agent-call", "--worker"])
    monkeypatch.setattr(cli, "worker_main", fail)
    monkeypatch.setattr(cli, "installed_contract", lambda: {})
    monkeypatch.setattr(cli, "worker_lease", nullcontext)
    with pytest.raises(SystemExit) as exit_info:
        cli.main()
    assert exit_info.value.code == 1
    output = capsys.readouterr()
    assert json.loads(output.out) == {"event": "failed", "status": "RuntimeError"}
    assert output.err == ""


def test_ssh_alias_uses_configured_network_name(monkeypatch):
    def resolve(arguments, **kwargs):
        assert arguments == ["ssh", "-G", "--", "build-mac"]
        assert kwargs["timeout"] == 10
        return CompletedProcess(
            arguments, 0, "user test\nhostname build-mac.example.ts.net\n"
        )

    monkeypatch.setattr("agent_calls.cli.subprocess.run", resolve)
    assert ssh_network_host("build-mac") == "build-mac.example.ts.net"


def test_ssh_alias_without_hostname_fails(monkeypatch):
    monkeypatch.setattr(
        "agent_calls.cli.subprocess.run",
        lambda *args, **kwargs: CompletedProcess(args, 0, "user test\n"),
    )
    with pytest.raises(RuntimeError, match="did not resolve"):
        ssh_network_host("build-mac")


def test_gateway_connection_uses_shared_discovery_for_the_selected_host(monkeypatch):
    observed = []
    monkeypatch.setattr(cli, "ssh_network_host", lambda host: "build-mac.example.ts.net")

    def resolve(host, ssh_host, local_config):
        observed.append((host, ssh_host, local_config))
        return GatewayConfig(host, 8789, "synthetic", "wss",
                             tls_identity=GatewayTLSIdentity("build-mac.local", bytes(32)))

    monkeypatch.setattr(cli, "resolve_gateway_config", resolve)
    connection = cli.gateway_connection("build-mac")
    assert observed == [(
        "build-mac.example.ts.net", "build-mac",
        cli.REPO_ROOT / "RemoteCoder/Resources/RemoteCoderLocalConfig.json",
    )]
    assert connection.ws_url == "wss://build-mac.example.ts.net:8789/ws"
    assert connection.tls_identity == GatewayTLSIdentity("build-mac.local", bytes(32))
    assert connection.token == "synthetic"
