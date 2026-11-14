import argparse
import contextlib
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / "relay/server/policy-rc.d"
ACTIVATION = ROOT / "relay/server/config-activation.sh"


class RelayProvisioningTests(unittest.TestCase):
    def test_provisioning_transports_the_policy_and_activation_owner(self):
        maintainer = types.ModuleType("maintainer_config")
        maintainer.load = dict
        maintainer.path = lambda: Path("/unused/maintainer.json")
        spec = importlib.util.spec_from_file_location(
            "relay_fixture", ROOT / "scripts/relay.py"
        )
        relay = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"maintainer_config": maintainer}):
            spec.loader.exec_module(relay)
        layout = {
            "server": {
                "provisioner": "fixture",
                "address": "192.0.2.1",
                "certificateName": "relay.test",
            },
            "hosts": {"fixture": {"port": 20001, "target": "fixture.relay.test"}},
        }
        with (
            patch.object(relay, "topology", return_value=layout),
            patch.object(relay, "this_host", return_value="fixture"),
            patch.object(
                relay,
                "server_secrets",
                return_value=(b"key", b"certificate", "credential"),
            ),
            patch.object(relay, "tracked_tunnel_keys", return_value={}),
            patch.object(relay, "spki_sha256", return_value="pin"),
            patch.object(relay, "admin_ssh", return_value=b"") as transport,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            relay.provision(argparse.Namespace())
        with tarfile.open(
            fileobj=io.BytesIO(transport.call_args.kwargs["input"])
        ) as archive:
            self.assertEqual(
                archive.extractfile("policy-rc.d").read(), POLICY.read_bytes()
            )
            self.assertEqual(
                archive.extractfile("config-activation.sh").read(),
                ACTIVATION.read_bytes(),
            )
            for name in ("maintenance-fence-check", "dpkg-maintenance.conf"):
                self.assertEqual(
                    archive.extractfile(name).read(),
                    (ROOT / "relay/server" / name).read_bytes(),
                )


class RelayPolicyTests(unittest.TestCase):
    def test_relay_actions_are_fenced_without_blocking_other_services(self):
        for service in (
            "haproxy",
            "haproxy.service",
            "tinyproxy.service",
            "ssh",
            "ssh.service",
            "ssh.socket",
            "sshd.service",
            "ssh@42.service",
        ):
            for action in (
                "stop",
                "restart",
                "reload",
                "force-reload",
                "try-restart",
                "reload-or-restart",
                "try-reload-or-restart",
                "(restart)",
            ):
                with self.subTest(service=service, action=action):
                    result = subprocess.run(
                        ["/bin/sh", str(POLICY), service, action], check=False
                    )
                    self.assertEqual(result.returncode, 101)
            for action in ("start", "status"):
                with self.subTest(service=service, action=action):
                    result = subprocess.run(
                        ["/bin/sh", str(POLICY), service, action], check=False
                    )
                    self.assertEqual(result.returncode, 0)
        self.assertEqual(
            subprocess.run(
                ["/bin/sh", str(POLICY), "--quiet", "ssh", "restart"], check=False
            ).returncode,
            101,
        )
        self.assertEqual(
            subprocess.run(
                ["/bin/sh", str(POLICY), "unrelated.service", "restart"], check=False
            ).returncode,
            0,
        )
        self.assertEqual(
            subprocess.run(
                ["/bin/sh", str(POLICY), "unrelated", "(start)"], check=False
            ).returncode,
            101,
        )

    def test_debian_helper_observes_the_policy_before_systemctl(self):
        required = os.environ.get("RC_RELAY_REQUIRE_DEBIAN") == "1"
        if not Path("/usr/bin/deb-systemd-invoke").exists():
            if required:
                self.fail("Debian service helper is required")
            self.skipTest("Debian service helper is unavailable")
        invoke = Path("/usr/sbin/invoke-rc.d")
        if required and (
            not invoke.exists() or not Path("/run/systemd/system").is_dir()
        ):
            self.fail("invoke-rc.d and its systemd query fixture are required")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy = root / "usr/sbin/policy-rc.d"
            policy.parent.mkdir(parents=True)
            shutil.copyfile(POLICY, policy)
            policy.chmod(0o755)
            commands = root / "bin"
            commands.mkdir()
            systemctl = commands / "systemctl"
            systemctl.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_CALLS"\ncase "$*" in *is-enabled*) echo enabled ;; esac\n'
            )
            systemctl.chmod(0o755)
            calls = root / "calls"
            environment = os.environ | {
                "DPKG_ROOT": str(root),
                "PATH": f"{commands}:/usr/bin:/bin",
                "TEST_CALLS": str(calls),
            }
            for service, action in (
                ("haproxy.service", "reload"),
                ("tinyproxy.service", "restart"),
                ("ssh.service", "stop"),
            ):
                with self.subTest(service=service, action=action):
                    result = subprocess.run(
                        ["/usr/bin/deb-systemd-invoke", action, service],
                        env=environment,
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("returned 101", result.stderr)
                    self.assertFalse(calls.exists())
            result = subprocess.run(
                ["/usr/bin/deb-systemd-invoke", "start", "haproxy.service"],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("start haproxy.service", calls.read_text())

            if invoke.exists() and Path("/run/systemd/system").is_dir():
                for action in ("stop", "restart", "reload", "force-reload"):
                    with self.subTest(helper="invoke-rc.d", action=action):
                        result = subprocess.run(
                            [str(invoke), "--query", "--quiet", "ssh", action],
                            env=environment,
                            capture_output=True,
                            text=True,
                            check=False,
                        )
                        self.assertEqual(result.returncode, 101, result.stderr)
                result = subprocess.run(
                    [str(invoke), "--query", "--quiet", "ssh", "start"],
                    env=environment,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 104, result.stderr)


class RelayConfigActivationTests(unittest.TestCase):
    def test_rollback_after_uncertain_activation_reactivates_current_configuration(
        self,
    ):
        for failure in ("interrupted", "stopped", "damaged"):
            with (
                self.subTest(failure=failure),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                incoming, installed = root / "incoming", root / "installed"
                runtime, running, calls = (
                    root / "runtime",
                    root / "running",
                    root / "calls",
                )
                for path in (incoming, installed, runtime):
                    path.write_text("A")
                running.touch()
                incoming.write_text("B")
                shell = r"""
set -eu
activation_dir=$2
source "$1"
systemctl() {
    printf '%s\n' "$*" >> "$CALLS"
    case "$FAILURE" in
        interrupted) cp "$INSTALLED" "$RUNTIME"; kill -TERM $$ ;;
        stopped) rm -f "$RUNNING"; return 1 ;;
        *) cp "$INSTALLED" "$RUNTIME"; : > "$RUNNING" ;;
    esac
}
record_config_change "$INCOMING" "$INSTALLED" haproxy
cp "$INCOMING" "$INSTALLED"
activate_config_change haproxy restart
"""
                pending = root / "pending"
                pending.mkdir()
                command = [
                    "/bin/bash",
                    "-c",
                    shell,
                    "--",
                    str(ACTIVATION),
                    str(pending),
                ]
                environment = os.environ | {
                    "INCOMING": str(incoming),
                    "INSTALLED": str(installed),
                    "RUNTIME": str(runtime),
                    "RUNNING": str(running),
                    "CALLS": str(calls),
                    "FAILURE": "interrupted" if failure == "damaged" else failure,
                }
                result = subprocess.run(
                    command,
                    env=environment,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                if failure == "damaged":
                    for record in (pending / "haproxy").iterdir():
                        if record.name != "attempted":
                            record.write_text("")
                incoming.write_text("A")
                result = subprocess.run(
                    command,
                    env=environment | {"FAILURE": "none"},
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(running.exists())
                self.assertEqual(runtime.read_text(), "A")
                self.assertEqual(
                    calls.read_text().splitlines(),
                    ["restart haproxy", "restart haproxy"],
                )
                self.assertFalse((pending / "haproxy").exists())

    def test_only_changed_configuration_triggers_activation_and_failed_action_is_retried(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, installed, calls = (
                root / "incoming",
                root / "installed",
                root / "calls",
            )
            incoming.write_text("old")
            installed.write_text("old")
            shell = r"""
set -eu
activation_dir=$2
calls=$5
mkdir -p "$activation_dir"
source "$1"
systemctl() { printf '%s\n' "$*" >> "$calls"; return "${FAIL_ACTION:-0}"; }
record_config_change "$3" "$4" haproxy
cp "$3" "$4"
activate_config_change haproxy restart
"""
            command = [
                "/bin/bash",
                "-c",
                shell,
                "--",
                str(ACTIVATION),
                str(root / "pending"),
                str(incoming),
                str(installed),
                str(calls),
            ]
            result = subprocess.run(
                command, capture_output=True, text=True, check=False
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(calls.exists())

            incoming.write_text("new")
            result = subprocess.run(
                command,
                env=os.environ | {"FAIL_ACTION": "1"},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((root / "pending/haproxy").exists())
            installed.write_text("new")
            result = subprocess.run(
                command, capture_output=True, text=True, check=False
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                calls.read_text().splitlines(), ["restart haproxy", "restart haproxy"]
            )
            self.assertFalse((root / "pending/haproxy").exists())

    def test_canceled_change_does_not_restart_an_unchanged_service(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, installed, calls = (
                root / "incoming",
                root / "installed",
                root / "calls",
            )
            incoming.write_text("new")
            installed.write_text("old")
            shell = r"""
set -eu
activation_dir=$2
calls=$5
mkdir -p "$activation_dir"
source "$1"
systemctl() { printf '%s\n' "$*" >> "$calls"; }
record_config_change "$3" "$4" haproxy
activate_config_change haproxy restart
"""
            command = [
                "/bin/bash",
                "-c",
                shell,
                "--",
                str(ACTIVATION),
                str(root / "pending"),
                str(incoming),
                str(installed),
                str(calls),
            ]
            result = subprocess.run(
                command, capture_output=True, text=True, check=False
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(calls.exists())
            self.assertFalse((root / "pending/haproxy").exists())

    def test_removing_a_managed_config_marks_its_service(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            old = root / "old.conf"
            shell = 'set -eu; activation_dir=$2; source "$1"; record_config_removal "$3" ssh'
            command = [
                "/bin/bash",
                "-c",
                shell,
                "--",
                str(ACTIVATION),
                str(root),
                str(old),
            ]
            subprocess.run(command, check=True)
            self.assertFalse((root / "ssh").exists())
            old.write_text("old")
            subprocess.run(command, check=True)
            self.assertTrue((root / "ssh").exists())


if __name__ == "__main__":
    unittest.main()
