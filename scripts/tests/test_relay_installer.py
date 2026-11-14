import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "relay/server"


class RelayInstallerTests(unittest.TestCase):
    def setUp(self):
        if sys.platform != "linux" or not shutil.which("bwrap"):
            if os.environ.get("RC_RELAY_REQUIRE_SANDBOX") == "1":
                self.fail("Linux bubblewrap is required for the installer test")
            self.skipTest("Linux bubblewrap is unavailable")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in (
            "etc",
            "varlib",
            "home",
            "sbin",
            "local/sbin",
            "shared/bin",
            "shared/src",
            "shared/state",
            "shared/runtime",
        ):
            (self.root / name).mkdir(parents=True)
        self.shared = self.root / "shared"
        self.src = self.shared / "src"
        for name in (
            "apply.sh",
            "policy-rc.d",
            "maintenance-fence-check",
            "dpkg-maintenance.conf",
            "maintenance-firewall.nft",
            "maintenance-startup",
            "maintenance-recover",
            "maintenance_state.py",
            "maintenance_drain.py",
            "haproxy-maintenance.conf",
            "nftables-maintenance.conf",
            "remote-coder-relay-maintenance-recover.service",
            "config-activation.sh",
            "nftables.conf",
            "haproxy.cfg",
            "unattended-upgrades.conf",
            "remote-coder-relay-hosts",
            "remote-coder-relay-hosts.service",
        ):
            shutil.copyfile(SERVER / name, self.src / name)
        for name, value in {
            "relay.pem": "synthetic certificate and key",
            "tinyproxy.conf": "tinyproxy configuration A",
            "filter": "synthetic filter",
            "hosts-block": "127.0.0.1 synthetic.relay.test\n",
            "sshd.conf": "synthetic ssh configuration",
            "authorized_keys": "synthetic key",
            "credential": "synthetic credential",
            "username": "relay",
        }.items():
            (self.src / name).write_text(value)
        (self.root / "etc/ssh").mkdir(parents=True)
        (self.root / "etc/systemd/system").mkdir(parents=True)
        (self.root / "etc/ssh/ssh_host_ed25519_key.pub").write_text(
            "ssh-ed25519 synthetic\n"
        )
        self.fake(
            "install",
            r"""
args=()
while (($#)); do
    case "$1" in
        -o|-g) shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
exec /usr/bin/install "${args[@]}"
""",
        )
        self.fake(
            "apt-get",
            r"""
printf 'apt-get %s\n' "$*" >> "$TEST_LOG"
test -x /usr/sbin/policy-rc.d
set +e
/usr/sbin/policy-rc.d haproxy restart
result=$?
set -e
test "$result" -eq 101
if [[ "$1" == install && ! -e /tmp/fixture/apt-installed ]]; then
    mkdir -p /etc/haproxy /etc/tinyproxy /etc/ssh/sshd_config.d /etc/apt/apt.conf.d
    touch /tmp/fixture/state/haproxy /tmp/fixture/state/tinyproxy /tmp/fixture/state/ssh /tmp/fixture/apt-installed
fi
""",
        )
        self.fake(
            "systemctl",
            r"""
printf 'systemctl %s\n' "$*" >> "$TEST_LOG"
action=$1
shift
case "$action" in
    is-active)
        [[ "${1:-}" != --quiet ]] || shift
        test -e "/tmp/fixture/state/$1"
        ;;
    start|restart|reload)
        unit=$1
        if [[ "${TEST_FAIL:-}" == "$action:$unit" ]]; then
            rm -f "/tmp/fixture/state/$unit"
            exit 1
        fi
        touch "/tmp/fixture/state/$unit"
        if [[ "$unit" == haproxy ]]; then
            cp /etc/haproxy/haproxy.cfg /tmp/fixture/runtime/haproxy
        fi
        ;;
    enable)
        for arg in "$@"; do
            if [[ "$arg" == --now ]]; then
                touch /tmp/fixture/state/apt-daily.timer /tmp/fixture/state/apt-daily-upgrade.timer
            fi
        done
        ;;
esac
""",
        )
        self.fake(
            "sshd",
            r"""
if [[ "$1" == -T ]]; then
    printf '%s\n' 'pubkeyauthentication yes' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'permitrootlogin without-password'
fi
""",
        )
        self.fake(
            "openssl",
            r"""
case "$1" in
    dgst) exec /usr/bin/openssl "$@" ;;
    x509) printf 'synthetic' ;;
    pkey) cat >/dev/null; printf 'synthetic' ;;
    *) exit 1 ;;
esac
""",
        )
        for name in ("nft", "haproxy", "id"):
            self.fake(name, ":")

    def fake(self, name, body):
        path = self.shared / "bin" / name
        path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def run_installer(self, failure=""):
        log = self.shared / "calls"
        log.unlink(missing_ok=True)
        command = [
            "bwrap",
            "--unshare-all",
            "--die-with-parent",
            "--ro-bind",
            "/usr",
            "/usr",
            "--symlink",
            "usr/bin",
            "/bin",
            "--symlink",
            "usr/sbin",
            "/sbin",
            "--symlink",
            "usr/lib",
            "/lib",
            "--symlink",
            "usr/lib64",
            "/lib64",
            "--dir",
            "/var",
            "--tmpfs",
            "/tmp",
        ]
        for source, target in (
            ("etc", "/etc"),
            ("varlib", "/var/lib"),
            ("home", "/home"),
            ("sbin", "/usr/sbin"),
            ("local", "/usr/local"),
            ("shared", "/tmp/fixture"),
        ):
            command += ["--bind", str(self.root / source), target]
        command += [
            "--dev",
            "/dev",
            "--proc",
            "/proc",
            "--chdir",
            "/tmp/fixture",
            "--setenv",
            "PATH",
            "/tmp/fixture/bin:/usr/bin:/bin",
            "--setenv",
            "TEST_LOG",
            "/tmp/fixture/calls",
            "--setenv",
            "TEST_FAIL",
            failure,
            "--unsetenv",
            "SSH_CONNECTION",
            "--",
            "/bin/bash",
            "/tmp/fixture/src/apply.sh",
            "/tmp/fixture/src",
        ]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        return result, log.read_text().splitlines() if log.exists() else []

    def test_install_reapply_changes_and_recovery(self):
        result, first = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            first[:2],
            [
                "apt-get update -qq",
                "apt-get install -y -qq conntrack haproxy iptables tinyproxy nftables unattended-upgrades",
            ],
        )
        self.assertTrue((self.root / "sbin/policy-rc.d").is_symlink())
        self.assertIn(
            "systemctl enable --quiet remote-coder-relay-maintenance-recover", first
        )
        self.assertNotIn(
            "systemctl start remote-coder-relay-maintenance-recover", first
        )
        self.assertLess(
            first.index("systemctl daemon-reload"),
            first.index("systemctl start nftables"),
        )
        self.assertEqual(
            (
                self.root
                / "etc/systemd/system/nftables.service.d/10-relay-maintenance.conf"
            ).read_bytes(),
            (SERVER / "nftables-maintenance.conf").read_bytes(),
        )
        self.assertEqual(
            (
                self.root / "etc/dpkg/dpkg.cfg.d/remote-coder-relay-maintenance"
            ).read_text(),
            (SERVER / "dpkg-maintenance.conf").read_text(),
        )
        self.assertEqual(
            (
                self.root / "local/lib/remote-coder-relay/maintenance-fence-check"
            ).read_bytes(),
            (SERVER / "maintenance-fence-check").read_bytes(),
        )
        self.assertIn("systemctl restart haproxy", first)
        self.assertIn("systemctl restart tinyproxy", first)
        self.assertIn("systemctl reload ssh", first)

        result, identical = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(
            any(
                line.startswith(
                    (
                        "systemctl restart ",
                        "systemctl reload ",
                        "systemctl daemon-reload",
                    )
                )
                for line in identical
            )
        )

        (self.src / "tinyproxy.conf").write_text("tinyproxy configuration B")
        result, changed = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [
                line
                for line in changed
                if line.startswith(("systemctl restart ", "systemctl reload "))
            ],
            ["systemctl restart tinyproxy"],
        )

        original = (self.src / "haproxy.cfg").read_text()
        (self.src / "haproxy.cfg").write_text(original + "\nsynthetic change\n")
        result, failed = self.run_installer("restart:haproxy")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("systemctl restart haproxy", failed)
        self.assertTrue(
            (
                self.root / "varlib/remote-coder-relay/activation/haproxy/attempted"
            ).exists()
        )
        self.assertFalse((self.shared / "state/haproxy").exists())
        (self.src / "haproxy.cfg").write_text(original)
        result, recovered = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("systemctl restart haproxy", recovered)
        self.assertEqual((self.shared / "runtime/haproxy").read_text(), original)
        self.assertFalse(
            (self.root / "varlib/remote-coder-relay/activation/haproxy").exists()
        )

    def test_foreign_policy_stops_before_apt(self):
        policy = self.root / "sbin/policy-rc.d"
        policy.write_text("foreign policy")
        result, calls = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("another owner", result.stderr)
        self.assertEqual(policy.read_text(), "foreign policy")
        self.assertFalse(any(line.startswith("apt-get ") for line in calls))

    def test_pending_maintenance_stops_before_apt_or_policy_changes(self):
        directory = self.root / "varlib/remote-coder-relay"
        directory.mkdir()
        marker = directory / "maintenance.json"
        for content in ('{"phase":"preparing"}', '{"phase":"committed"}', "invalid"):
            with self.subTest(content=content):
                marker.write_text(content)
                result, calls = self.run_installer()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Relay maintenance is pending", result.stderr)
                self.assertEqual(calls, [])
                self.assertFalse((self.root / "sbin/policy-rc.d").exists())
                self.assertEqual(marker.read_text(), content)

    def test_maintenance_guard_refuses_even_an_invalid_marker(self):
        directory = self.root / "varlib/remote-coder-relay"
        directory.mkdir()
        marker = directory / "maintenance.json"

        def run_guard():
            return subprocess.run(
                [
                    "bwrap",
                    "--unshare-all",
                    "--die-with-parent",
                    "--ro-bind",
                    "/",
                    "/",
                    "--bind",
                    str(self.root / "varlib"),
                    "/var/lib",
                    "--",
                    "/bin/sh",
                    str(self.src / "maintenance-fence-check"),
                ],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(run_guard().returncode, 0)
        marker.write_text("invalid")
        self.assertNotEqual(run_guard().returncode, 0)
        marker.unlink()
        marker.symlink_to("missing")
        self.assertNotEqual(run_guard().returncode, 0)

    def test_haproxy_startup_applies_a_pending_fence_and_propagates_failure(self):
        directory = self.root / "varlib/remote-coder-relay"
        directory.mkdir()
        marker = directory / "maintenance.json"
        nft = self.root / "sbin/nft"
        nft.write_text(
            '#!/bin/sh\nprintf "%s\\n" "$*" >> /tmp/fixture/nft-calls\n'
            "test ! -e /tmp/fixture/fail-nft\n"
        )
        nft.chmod(0o755)

        def startup_command():
            return [
                "bwrap",
                "--unshare-all",
                "--die-with-parent",
                "--ro-bind",
                "/",
                "/",
                "--tmpfs",
                "/tmp",
                "--bind",
                str(self.root / "varlib"),
                "/var/lib",
                "--bind",
                str(self.root / "sbin"),
                "/usr/sbin",
                "--bind",
                str(self.shared),
                "/tmp/fixture",
                "--",
                "/bin/sh",
                "/tmp/fixture/src/maintenance-startup",
            ]

        def start():
            return subprocess.run(
                startup_command(),
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(start().returncode, 0)
        self.assertFalse((self.shared / "nft-calls").exists())
        marker.write_text("invalid")
        self.assertEqual(start().returncode, 0)
        self.assertEqual(
            (self.shared / "nft-calls").read_text().splitlines(),
            ["-f /usr/local/lib/remote-coder-relay/maintenance-firewall.nft"],
        )
        with (directory / "admission.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            process = subprocess.Popen(
                startup_command(), stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            try:
                time.sleep(0.2)
                self.assertIsNone(process.poll())
                self.assertEqual(
                    len((self.shared / "nft-calls").read_text().splitlines()), 1
                )
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
                process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0)
        (self.shared / "fail-nft").touch()
        self.assertNotEqual(start().returncode, 0)

    def test_recovery_reopens_only_an_abandoned_same_boot_preparation(self):
        directory = self.root / "varlib/remote-coder-relay"
        directory.mkdir(mode=0o700)
        marker = directory / "maintenance.json"
        boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        nft = self.root / "sbin/nft"
        nft.write_text(
            "#!/bin/sh\ncat >> /tmp/fixture/nft-input\n"
            "test ! -e /tmp/fixture/fail-nft\n"
        )
        nft.chmod(0o755)

        def write_marker(phase, boot=boot_id):
            marker.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "phase": phase,
                        "boot_id": boot,
                        "operation_id": "00000000-0000-4000-8000-000000000001",
                        "master": {"pid": 101, "start_ticks": 10},
                        "worker": {"pid": 102, "start_ticks": 11},
                    }
                )
            )
            marker.chmod(0o600)

        def recover():
            return subprocess.run(
                [
                    "bwrap",
                    "--unshare-all",
                    "--uid",
                    "0",
                    "--gid",
                    "0",
                    "--die-with-parent",
                    "--ro-bind",
                    "/",
                    "/",
                    "--tmpfs",
                    "/tmp",
                    "--bind",
                    str(self.root / "varlib"),
                    "/var/lib",
                    "--bind",
                    str(self.root / "sbin"),
                    "/usr/sbin",
                    "--bind",
                    str(self.shared),
                    "/tmp/fixture",
                    "--proc",
                    "/proc",
                    "--",
                    "/usr/bin/python3",
                    "/tmp/fixture/src/maintenance-recover",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(recover().returncode, 0)
        for phase, boot in (
            ("committed", boot_id),
            ("preparing", "00000000-0000-0000-0000-000000000000"),
        ):
            with self.subTest(phase=phase, boot=boot):
                write_marker(phase, boot)
                self.assertNotEqual(recover().returncode, 0)
                self.assertTrue(marker.exists())
                self.assertFalse((self.shared / "nft-input").exists())

        marker.write_text("invalid")
        marker.chmod(0o600)
        self.assertNotEqual(recover().returncode, 0)
        self.assertFalse((self.shared / "nft-input").exists())
        marker.write_text(
            json.dumps({"schema": 1, "phase": "preparing", "boot_id": boot_id})
        )
        self.assertNotEqual(recover().returncode, 0)
        self.assertTrue(marker.exists())
        self.assertFalse((self.shared / "nft-input").exists())
        for field, value in (
            ("operation_id", None),
            ("master", {"pid": True, "start_ticks": 10}),
            ("worker", {"pid": 101, "start_ticks": 11}),
        ):
            with self.subTest(invalid_field=field):
                write_marker("preparing")
                document = json.loads(marker.read_text())
                document[field] = value
                marker.write_text(json.dumps(document))
                self.assertNotEqual(recover().returncode, 0)
                self.assertTrue(marker.exists())
                self.assertFalse((self.shared / "nft-input").exists())
        marker.write_text(
            '{"schema":1,"phase":"committed","phase":"preparing",'
            f'"boot_id":"{boot_id}"' + "}"
        )
        self.assertNotEqual(recover().returncode, 0)
        self.assertFalse((self.shared / "nft-input").exists())
        write_marker("preparing")
        marker.chmod(0o644)
        self.assertNotEqual(recover().returncode, 0)
        self.assertFalse((self.shared / "nft-input").exists())

        write_marker("preparing")
        with (directory / "provision.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(recover().returncode, 0)
        with (directory / "admission.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(recover().returncode, 0)
        self.assertTrue(marker.exists())
        (self.shared / "fail-nft").touch()
        self.assertNotEqual(recover().returncode, 0)
        self.assertTrue(marker.exists())
        (self.shared / "fail-nft").unlink()
        result = recover()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assertEqual(
            (self.shared / "nft-input").read_text().splitlines(),
            ["destroy table inet remote_coder_relay_maintenance"] * 2,
        )


if __name__ == "__main__":
    unittest.main()
