import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import process_group as groups
from process_group import process_identity as process_snapshot


class ProcessIdentityTests(unittest.TestCase):
    def test_clock_adjustment_does_not_change_boot_identity(self):
        values = iter(("{ sec = 100, usec = 0 }", "{ sec = 105, usec = 0 }"))

        def sysctl(command, **_):
            return (
                "00000000-0000-4000-8000-000000000001\n"
                if command[-1] == "kern.bootsessionuuid"
                else next(values)
            )

        with patch.object(groups.subprocess, "check_output", side_effect=sysctl):
            self.assertEqual(
                groups.boot_identity.__wrapped__(), groups.boot_identity.__wrapped__()
            )

    def test_parent_and_start_are_from_the_native_process_snapshot(self):
        identity = groups.own_identity()
        self.assertEqual(identity["pid"], os.getpid())
        self.assertEqual(identity["ppid"], os.getppid())
        self.assertEqual(identity["pgid"], os.getpgrp())
        self.assertTrue(groups.audit_alive(identity))
        executable = subprocess.check_output(['ps', '-p', str(os.getpid()), '-o', 'comm='], text=True).strip()
        self.assertEqual(groups.audit_path(identity).resolve(), Path(executable).resolve())

    def test_lookup_to_signal_race_cannot_kill_replacement(self):
        with subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import sys; print('ready',flush=True); sys.stdin.read(1); print('alive',flush=True)",
            ],
            start_new_session=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        ) as replacement:
            try:
                self.assertEqual(replacement.stdout.readline(), b"ready\n")
                recorded = process_snapshot(replacement.pid)
                recorded["pidVersion"] ^= 1
                recorded["auditToken"][7] = recorded["pidVersion"]
                with patch.object(groups, "process_identity", return_value=recorded):
                    groups.terminate_process(recorded)
                output, _ = replacement.communicate(b".", timeout=60)
                self.assertEqual(
                    replacement.returncode,
                    0,
                    "A replacement PID received the stale owner's signal",
                )
                self.assertEqual(output, b"alive\n")
            finally:
                replacement.kill()
                replacement.wait(timeout=60)
