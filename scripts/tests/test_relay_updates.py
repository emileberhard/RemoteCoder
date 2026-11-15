import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch

SERVER = Path(__file__).resolve().parents[2] / "relay/server"
sys.path.insert(0, str(SERVER))
import maintenance_updates as updates


class RelayUpdatesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.proc = root / "proc"
        self.cgroup = root / "cgroup"
        self.flag = root / "reboot-required"
        self.proc.mkdir()
        for unit, pid in zip(updates.SERVICES, (11, 12, 13)):
            group = self.cgroup / "system.slice" / unit
            group.mkdir(parents=True)
            (group / "cgroup.procs").write_text(f"{pid}\n")
            process = self.proc / str(pid)
            process.mkdir()
            (process / "maps").write_text(
                "1000-2000 r-xp 0000 00:00 0 /usr/lib/libcurrent.so\n"
            )
            (process / "exe").symlink_to("/usr/sbin/service")
        self.patches = (
            patch.object(updates, "PROC", self.proc),
            patch.object(updates, "CGROUP", self.cgroup),
            patch.object(updates, "REBOOT_REQUIRED", self.flag),
            patch.object(updates.subprocess, "run", side_effect=self.systemctl),
        )
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def systemctl(self, command, **_kwargs):
        unit = command[2]
        if unit == "tailscaled.service":
            return CompletedProcess(
                command, 0, "LoadState=not-found\nActiveState=inactive\nControlGroup=\n"
            )
        return CompletedProcess(
            command,
            0,
            f"LoadState=loaded\nActiveState=active\nControlGroup=/system.slice/{unit}\n",
        )

    def test_flag_and_replaced_library_or_executable_request_reboot(self):
        self.assertFalse(updates.update_requires_reboot())
        self.flag.touch()
        self.assertTrue(updates.update_requires_reboot())
        self.flag.unlink()
        maps = self.proc / "12" / "maps"
        maps.write_text("1000-2000 r-xp 0000 00:00 0 /usr/lib/libssl.so.3 (deleted)\n")
        self.assertTrue(updates.update_requires_reboot())
        maps.write_text("1000-2000 r-xp 0000 00:00 0 /tmp/not-a-library (deleted)\n")
        self.assertFalse(updates.update_requires_reboot())
        exe = self.proc / "13" / "exe"
        exe.unlink()
        exe.symlink_to("/usr/sbin/sshd (deleted)")
        self.assertTrue(updates.update_requires_reboot())

    def test_child_control_group_is_counted(self):
        group = self.cgroup / "system.slice" / "ssh.service" / "child"
        group.mkdir()
        (group / "cgroup.procs").write_text("14\n")
        process = self.proc / "14"
        process.mkdir()
        (process / "maps").write_text(
            "1000-2000 r-xp 0000 00:00 0 /lib/libcrypto.so (deleted)\n"
        )
        self.assertTrue(updates.update_requires_reboot())

    def test_unreadable_or_missing_service_state_aborts(self):
        (self.cgroup / "system.slice" / "haproxy.service" / "cgroup.procs").unlink()
        with self.assertRaisesRegex(RuntimeError, "unreadable control group"):
            updates.update_requires_reboot()

    def test_optional_service_load_failure_is_not_reported_as_absent(self):
        result = CompletedProcess(
            [], 0, "LoadState=error\nActiveState=inactive\nControlGroup=\n"
        )
        with (
            patch.object(updates.subprocess, "run", return_value=result),
            self.assertRaisesRegex(RuntimeError, "not active and loaded"),
        ):
            updates.service_processes("tailscaled.service", optional=True)

    def test_real_deleted_library_mapping_and_executable_in_sandbox(self):
        if sys.platform != "linux" or not shutil.which("bwrap"):
            if os.environ.get("RC_RELAY_REQUIRE_HAPROXY") == "1":
                self.fail("Linux bubblewrap is required")
            self.skipTest("Linux bubblewrap is unavailable")
        self.patches[-1].stop()
        fixture = Path(self.temporary.name) / "sandbox"
        fixture.mkdir()
        shutil.copyfile("/usr/bin/sleep", fixture / "sleep")
        (fixture / "sleep").chmod(0o755)
        code = r"""
import mmap, os, subprocess, sys
sys.path.insert(0, '/tmp/source')
import maintenance_updates as updates
path = '/usr/lib/locale/libtest.so'
with open(path, 'wb') as source:
    source.write(b'x' * 4096)
with open(path, 'rb') as source:
    mapping = mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ)
    os.unlink(path)
    assert updates.process_uses_replaced_file(os.getpid())
    mapping.close()
process = subprocess.Popen(['/usr/lib/locale/sleep', '10'])
try:
    os.unlink('/usr/lib/locale/sleep')
    assert updates.process_uses_replaced_file(process.pid)
finally:
    process.terminate()
    process.wait(timeout=5)
"""
        result = subprocess.run(
            [
                "bwrap",
                "--unshare-all",
                "--die-with-parent",
                "--ro-bind",
                "/",
                "/",
                "--tmpfs",
                "/tmp",
                "--proc",
                "/proc",
                "--dev",
                "/dev",
                "--ro-bind",
                str(SERVER),
                "/tmp/source",
                "--bind",
                str(fixture),
                "/usr/lib/locale",
                "/usr/bin/python3",
                "-c",
                code,
            ],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
