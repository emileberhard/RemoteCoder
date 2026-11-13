import os
import shutil
import subprocess
import sys
import tempfile
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
    x509|pkey) printf 'synthetic' ;;
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
            "/",
            "/",
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
                "apt-get install -y -qq haproxy tinyproxy nftables unattended-upgrades",
            ],
        )
        self.assertTrue((self.root / "sbin/policy-rc.d").is_symlink())
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


if __name__ == "__main__":
    unittest.main()
