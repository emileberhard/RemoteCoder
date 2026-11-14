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
NFT_UNIT = Path(
    os.environ.get("RC_RELAY_TEST_NFT_UNIT", "/lib/systemd/system/nftables.service")
)


class RelaySystemdTests(unittest.TestCase):
    def test_rendered_haproxy_unit_and_maintenance_dropin_verify(self):
        required = os.environ.get("RC_RELAY_REQUIRE_SYSTEMD") == "1"
        missing = [
            name
            for name in ("bwrap", "systemd-analyze", HAPROXY, NFT)
            if not shutil.which(name)
        ]
        if (
            sys.platform != "linux"
            or missing
            or not UNIT.is_file()
            or not NFT_UNIT.is_file()
        ):
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
            nft_dropin = units / "nftables.service.d"
            nft_dropin.mkdir()
            shutil.copyfile(NFT_UNIT, units / "nftables.service")
            shutil.copyfile(
                SERVER / "nftables-maintenance.conf", nft_dropin / "maintenance.conf"
            )
            for name in (
                "remote-coder-relay-maintenance-recover.service",
                "remote-coder-relay-hosts.service",
            ):
                shutil.copyfile(SERVER / name, units / name)
            startup = fixture / "maintenance-startup"
            shutil.copyfile(SERVER / "maintenance-startup", startup)
            startup.chmod(0o755)
            recovery = fixture / "maintenance-recover"
            shutil.copyfile(SERVER / "maintenance-recover", recovery)
            recovery.chmod(0o755)
            hosts = fixture / "remote-coder-relay-hosts"
            shutil.copyfile(SERVER / "remote-coder-relay-hosts", hosts)
            hosts.chmod(0o755)
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
                "--ro-bind",
                str(recovery),
                "/usr/local/lib/remote-coder-relay/maintenance-recover",
                "--tmpfs",
                "/usr/local/sbin",
                "--ro-bind",
                str(hosts),
                "/usr/local/sbin/remote-coder-relay-hosts",
                "/usr/bin/env",
                "SYSTEMD_UNIT_PATH=/tmp/fixture/units:",
                "systemd-analyze",
                "--man=no",
                "verify",
                "/tmp/fixture/units/haproxy.service",
                "/tmp/fixture/units/nftables.service",
                "/tmp/fixture/units/remote-coder-relay-maintenance-recover.service",
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
            shutil.copyfile(
                SERVER / "haproxy-maintenance.conf", dropin / "maintenance.conf"
            )
            (nft_dropin / "maintenance.conf").write_text(
                "[Service]\nExecStop=/nonexistent-nft-check\n"
            )
            invalid_nft = subprocess.run(
                command, capture_output=True, text=True, timeout=20, check=False
            )
            self.assertNotEqual(
                invalid_nft.returncode, 0, "the nftables drop-in was not verified"
            )
            self.assertIn("nonexistent-nft-check", invalid_nft.stderr)


if __name__ == "__main__":
    unittest.main()
