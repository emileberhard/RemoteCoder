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

    def test_audit_path_is_the_executable_image_of_the_process(self):
        with subprocess.Popen(["/bin/sleep", "60"]) as child:
            try:
                self.assertEqual(
                    groups.audit_path(process_snapshot(child.pid)).resolve(),
                    Path("/bin/sleep").resolve(),
                )
            finally:
                child.kill()

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


class GroupMembershipTests(unittest.TestCase):
    def test_member_forked_after_the_listing_keeps_the_group_live(self):
        listings = iter(([101], [101, 102]))
        with (
            patch.object(groups, "_group_pids", side_effect=lambda _: next(listings)),
            patch.object(groups, "_is_live_member", side_effect=lambda pid, _: pid == 102),
        ):
            self.assertTrue(groups.group_has_live_members(100))

    def test_reused_pid_of_a_dead_member_keeps_the_group_live(self):
        inspections = iter((False, True))
        with (
            patch.object(groups, "_group_pids", return_value=[101]),
            patch.object(groups, "_is_live_member", side_effect=lambda *_: next(inspections)),
        ):
            self.assertTrue(groups.group_has_live_members(100))

    def test_settled_listing_without_other_live_members_is_drained(self):
        listings = iter(([100, 101, 102], [100, 101]))
        with (
            patch.object(groups, "_group_pids", side_effect=lambda _: next(listings)),
            patch.object(groups, "_is_live_member", side_effect=lambda pid, _: pid == 100),
        ):
            self.assertFalse(groups.group_has_live_members(100, exclude_pid=100))

    def test_zombie_member_is_not_live_and_a_running_one_is(self):
        leader = subprocess.Popen([sys.executable, "-c", "pass"], start_new_session=True)
        try:
            os.waitid(os.P_PID, leader.pid, os.WEXITED | os.WNOWAIT)
            self.assertFalse(groups.group_has_live_members(leader.pid))
        finally:
            leader.wait(timeout=60)
        self.assertFalse(groups.group_has_live_members(leader.pid))
        self.assertTrue(groups.group_has_live_members(os.getpgrp()))
