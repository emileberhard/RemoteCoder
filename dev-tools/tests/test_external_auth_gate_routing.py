import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
from test_gateway_local_host import identity_health


@pytest.fixture
def auth_gate_fixture(tmp_path):
    root = Path(__file__).resolve().parents[2]
    repo = tmp_path / "repo"
    (repo / "scripts").mkdir(parents=True)
    (repo / "docs/codex").mkdir(parents=True)
    (repo / "dev-tools").mkdir()
    for name in ("build_support.py", "process_group.py", "job_power.py"):
        shutil.copy2(root / "scripts" / name, repo / "scripts" / name)
    for name in (
        "pyproject.toml",
        "uv.lock",
        "src/remotecoder_tools/__init__.py",
        "src/remotecoder_tools/external_auth_identity.py",
        "src/remotecoder_tools/external_auth_probe.py",
    ):
        (repo / "dev-tools" / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / "dev-tools" / name, repo / "dev-tools" / name)
    (repo / "scripts/build-host").write_text("laptop\n")
    (repo / "docs/codex/compatibility.json").write_text(
        json.dumps({"codexCliVersion": "0.159.2"})
    )
    log = tmp_path / "commands.jsonl"
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    stub = f"""#!{sys.executable}
import json, os, sys, shutil, subprocess
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["GATE_TEST_LOG"], "a") as stream:
    stream.write(json.dumps([name, args]) + "\\n")
if name == "ssh":
    if "-G" in args:
        print("hostname 127.0.0.1")
    else:
        command = args[-1]
        if "external-auth/passed/" in command and "external_auth_probe" not in command:
            sys.exit(subprocess.run(["bash", "-c", command]).returncode)
        if "runtime desktop mode" in command:
            print("ChatGPT Desktop: disabled")
        elif "curl --fail" in command:
            print(json.dumps({{"status":"ok", "draining":False, "codexVersion":"0.159.2", "codexPid":123, "activeTurnInventoryAvailable":True, "fullDiskAccess":{{"required":True, "state":"granted"}}}}))
        elif "external_auth_identity.py" in command and "--managed-pid" in command:
            if os.environ["GATE_TEST_IDENTITY_FAILURE"] == "1":
                sys.exit(7)
            print(json.dumps({{"requestedHost":"workstation", "packageSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}))
elif name == "uuidgen":
    print("fixture-stage")
elif name == "hostname":
    print("gate-test-host")
elif name == "rsync" and "scripts/build_support.py" in args:
    stage = Path(os.environ["GATE_TEST_STAGE"])
    for source in args[1:-1]:
        path = Path(source)
        if path.is_file():
            destination = stage / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
    result = subprocess.run([sys.executable, str(stage / "scripts/build_support.py"), "--help"], capture_output=True)
    sys.exit(result.returncode)
"""
    stub = stub.replace('if name == "ssh":', 'if name in ("ssh", "zsh"):')
    for command in ("ssh", "zsh", "rsync", "uuidgen", "hostname"):
        path = bin_dir / command
        path.write_text(stub)
        path.chmod(0o755)
    gateway = repo / "dev-tools/rc-gateway"
    gateway.write_text(stub)
    gateway.chmod(0o755)
    script = (root / "scripts/shared-codex-host").read_text().replace("/bin/zsh", str(bin_dir / "zsh"))
    (repo / "scripts/shared-codex-host").write_text(script)
    environment = {
        **os.environ,
        "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
        "GATE_TEST_LOG": str(log),
        "GATE_TEST_IDENTITY_FAILURE": "0",
        "GATE_TEST_STAGE": str(tmp_path / "actual-stage"),
        "TMPDIR": str(tmp_path),
        "HOME": str(tmp_path / "home"),
    }
    return SimpleNamespace(repo=repo, log=log, environment=environment, gateway=gateway)


@pytest.mark.parametrize("identity_failure", [False, True])
@pytest.mark.parametrize("requested_host", ["workstation", "laptop"])
def test_gate_executes_matrix_only_on_build_host(auth_gate_fixture, identity_failure, requested_host):
    fixture = auth_gate_fixture
    fixture.environment["GATE_TEST_IDENTITY_FAILURE"] = "1" if identity_failure else "0"
    result = subprocess.run(
        ["bash", str(fixture.repo / "scripts/shared-codex-host"), "check", requested_host],
        env=fixture.environment,
        capture_output=True,
        text=True,
        timeout=10,
    )
    records = [json.loads(line) for line in fixture.log.read_text().splitlines()]
    matrix = [
        args
        for name, args in records
        if name == "ssh" and "-m remotecoder_tools.external_auth_probe" in args[-1]
    ]
    if identity_failure:
        assert result.returncode == 7, result.stderr
        assert matrix == []
        assert not any(name == "rc-gateway" for name, _ in records)
    else:
        assert result.returncode == 0, result.stderr
        assert len(matrix) == 1
        assert matrix[0][-2] == "laptop"
        assert "build_support.py" in matrix[0][-1]
        assert "--requested-host-identity" in matrix[0][-1]
        assert '--package "$HOME/' in matrix[0][-1]
        assert any(name == "rc-gateway" for name, _ in records)
    for name, args in records:
        if name == "ssh" and len(args) >= 2 and args[-2] == "workstation":
            assert "uv run" not in args[-1]
            assert "external_auth_probe" not in args[-1]
        if name == "rsync":
            assert not any("auth.json" in arg or "gateway.env" in arg for arg in args)


def test_local_post_deploy_check_uses_the_default_local_gateway(auth_gate_fixture, tmp_path):
    fixture = auth_gate_fixture
    configuration = fixture.repo / "RemoteCoder/Resources/RemoteCoderLocalConfig.json"
    configuration.parent.mkdir(parents=True)
    configuration.write_text(json.dumps({"macMiniHostname": "another-machine.fixture"}))
    env_file = tmp_path / "gateway.env"
    fixture.gateway.write_text(f"""#!{sys.executable}
import json, os, sys
from pathlib import Path
with open(os.environ['GATE_TEST_LOG'], 'a') as stream:
    stream.write(json.dumps(['rc-gateway', sys.argv[1:]]) + '\\n')
from remotecoder_tools import config, gateway_cli
args = gateway_cli.build_parser().parse_args(sys.argv[1:])
args.ssh_env_path = {str(env_file)!r}
cfg = config._resolve_config(args)
print(json.dumps({{'host': cfg.host, 'port': cfg.port, 'scheme': cfg.scheme}}))
""")
    source = Path(__file__).resolve().parents[1] / "src"
    fixture.environment["PYTHONPATH"] = str(source)
    for name in ("RC_CODEX_GATEWAY_HOST", "RC_CODEX_GATEWAY_SSH_HOST", "RC_CODEX_GATEWAY_PORT", "RC_CODEX_GATEWAY_AUTH_TOKEN"):
        fixture.environment.pop(name, None)
    with identity_health("local.gateway.fixture", 42424) as (port, requests):
        env_file.write_text(f"RC_CODEX_GATEWAY_BIND_HOST=127.0.0.1\nRC_CODEX_GATEWAY_PORT={port}\n"
                            "RC_CODEX_GATEWAY_AUTH_TOKEN=local-fixture-bearer\n")
        result = subprocess.run(["bash", str(fixture.repo / "scripts/shared-codex-host"), "check", "local"],
                                cwd=fixture.repo, env=fixture.environment, capture_output=True, text=True, timeout=10)
    records = [json.loads(line) for line in fixture.log.read_text().splitlines()]
    assert [args for name, args in records if name == "rc-gateway"] == [["e2e-reads"]]
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout.splitlines()[-1]) == {"host": "127.0.0.1", "port": 42424, "scheme": "wss"}
    assert requests == [("/health", "Bearer local-fixture-bearer")]
    assert not any(name == "ssh" and args[5:6] == ["cat"] for name, args in records)


def test_a_passed_matrix_is_reused_only_for_identical_package_and_probe_inputs(auth_gate_fixture):
    fixture = auth_gate_fixture

    def check():
        fixture.log.write_text("")
        result = subprocess.run(
            ["bash", str(fixture.repo / "scripts/shared-codex-host"), "check", "workstation"],
            env=fixture.environment, capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == 0, result.stderr
        records = [json.loads(line) for line in fixture.log.read_text().splitlines()]
        matrix = [args for name, args in records if name == "ssh" and "external_auth_probe" in args[-1]]
        lookups = [args[-1] for name, args in records if name == "ssh" and "external-auth/passed/" in args[-1]]
        return result, matrix, lookups

    _, matrix, lookups = check()
    assert len(matrix) == 1
    evidence = lookups[0].split('$HOME/', 1)[1].split('"', 1)[0]
    home = Path(fixture.environment["HOME"])
    receipt = home / "Library/Logs/remote-coder/compatibility/external-auth-PASSED.json"
    receipt.parent.mkdir(parents=True)
    receipt.write_text("{}")
    (home / evidence).parent.mkdir(parents=True)
    (home / evidence).write_text(f"{receipt}\n")

    result, matrix, _ = check()
    assert matrix == []
    assert f"already passed for this package on laptop: {receipt}" in result.stdout

    probe = fixture.repo / "dev-tools/src/remotecoder_tools/external_auth_probe.py"
    probe.write_text(probe.read_text() + "\n")
    _, matrix, _ = check()
    assert len(matrix) == 1


def test_a_build_host_check_probes_its_installed_package_in_place(auth_gate_fixture):
    fixture = auth_gate_fixture
    (fixture.repo / "scripts/build-host").write_text("gate-test-host\n")
    result = subprocess.run(
        ["bash", str(fixture.repo / "scripts/shared-codex-host"), "check", "local"],
        cwd=fixture.repo, env=fixture.environment, capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 0, result.stderr
    records = [json.loads(line) for line in fixture.log.read_text().splitlines()]
    matrix = [args for _, args in records if args and "-m remotecoder_tools.external_auth_probe" in args[-1]]
    assert len(matrix) == 1
    assert matrix[0][0] == "-lc"
    assert '--package "$HOME/.codex/packages/standalone/current"' in matrix[0][-1]
    assert not any(
        name == "rsync" and any("packages/standalone/current" in arg for arg in args)
        for name, args in records
    )
