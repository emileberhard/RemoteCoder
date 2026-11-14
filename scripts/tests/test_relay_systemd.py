import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SERVER = Path(__file__).resolve().parents[2] / "relay/server"
HAPROXY = os.environ.get("RC_RELAY_TEST_HAPROXY", "/usr/sbin/haproxy")
NFT = os.environ.get("RC_RELAY_TEST_NFT", "/usr/sbin/nft")
UNIT = Path(
    os.environ.get("RC_RELAY_TEST_HAPROXY_UNIT", "/lib/systemd/system/haproxy.service")
)


class RelaySystemdTests(unittest.TestCase):
    def test_rendered_haproxy_unit_and_maintenance_dropin_verify(self):
        required = os.environ.get("RC_RELAY_REQUIRE_SYSTEMD") == "1"
        missing = [
            name
            for name in ("bwrap", "systemd-analyze", HAPROXY, NFT)
            if not shutil.which(name)
        ]
        if sys.platform != "linux" or missing or not UNIT.is_file():
            if required:
                self.fail(f"systemd verification prerequisites are missing: {missing}")
            self.skipTest("systemd verification prerequisites are unavailable")
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            units = fixture / "units"
            dropin = units / "haproxy.service.d"
            dropin.mkdir(parents=True)
            shutil.copyfile(UNIT, units / "haproxy.service")
            shutil.copyfile(
                SERVER / "haproxy-maintenance.conf", dropin / "maintenance.conf"
            )
            startup = fixture / "maintenance-startup"
            shutil.copyfile(SERVER / "maintenance-startup", startup)
            startup.chmod(0o755)
            command = [
                "bwrap",
                "--unshare-all",
                "--die-with-parent",
                "--ro-bind",
                "/",
                "/",
                "--tmpfs",
                "/tmp",
                "--tmpfs",
                "/run",
                "--tmpfs",
                "/etc",
                "--proc",
                "/proc",
                "--dev",
                "/dev",
                "--ro-bind",
                str(fixture),
                "/tmp/fixture",
                "--tmpfs",
                "/usr/sbin",
                "--ro-bind",
                HAPROXY,
                "/usr/sbin/haproxy",
                "--ro-bind",
                NFT,
                "/usr/sbin/nft",
                "--tmpfs",
                "/usr/local/lib",
                "--dir",
                "/usr/local/lib/remote-coder-relay",
                "--ro-bind",
                str(startup),
                "/usr/local/lib/remote-coder-relay/maintenance-startup",
                "/usr/bin/env",
                "SYSTEMD_UNIT_PATH=/tmp/fixture/units:",
                "systemd-analyze",
                "--man=no",
                "verify",
                "/tmp/fixture/units/haproxy.service",
            ]
            result = subprocess.run(
                command, capture_output=True, text=True, timeout=20, check=False
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            (dropin / "maintenance.conf").write_text(
                "[Service]\nExecStartPre=/nonexistent-relay-check\n"
            )
            invalid = subprocess.run(
                command, capture_output=True, text=True, timeout=20, check=False
            )
            self.assertNotEqual(invalid.returncode, 0, "the drop-in was not verified")
            self.assertIn("nonexistent-relay-check", invalid.stderr)


if __name__ == "__main__":
    unittest.main()
