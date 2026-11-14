import importlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SERVER = Path(__file__).resolve().parents[2] / "relay/server"
sys.path.insert(0, str(SERVER))
drain = importlib.import_module("maintenance_drain")


class RelayDrainTests(unittest.TestCase):
    def test_candidate_waits_with_admission_open_until_idle(self):
        clock = [0.0]
        checks = []

        def snapshot(identity, deadline):
            checks.append((identity, deadline, clock[0]))
            return len(checks) < 3

        def sleep(seconds):
            clock[0] += seconds

        with (
            patch.object(drain.time, "monotonic", side_effect=lambda: clock[0]),
            patch.object(drain.time, "sleep", side_effect=sleep),
            patch.object(drain, "candidate_snapshot", side_effect=snapshot),
        ):
            drain.wait_for_candidate({"worker": 7}, 5)
        self.assertEqual(checks, [({"worker": 7}, 5, n) for n in (0, 1, 2)])

    def test_candidate_deadline_does_not_accept_a_late_idle_result(self):
        clock = [0.0]

        def late_snapshot(_identity, _deadline):
            clock[0] = 4
            return False

        with (
            patch.object(drain.time, "monotonic", side_effect=lambda: clock[0]),
            patch.object(drain, "candidate_snapshot", side_effect=late_snapshot),
            self.assertRaises(TimeoutError),
        ):
            drain.wait_for_candidate({}, 3)

    def test_two_clean_passes_follow_grace_and_a_busy_pass_resets_progress(self):
        clock = [0.0]
        passes = []

        def sleep(seconds):
            clock[0] += seconds

        def snapshot(identity, deadline):
            self.assertEqual(identity, {"worker": 7})
            self.assertEqual(deadline, 10)
            passes.append(clock[0])
            return len(passes) == 2

        with (
            patch.object(drain.time, "monotonic", side_effect=lambda: clock[0]),
            patch.object(drain.time, "sleep", side_effect=sleep),
            patch.object(drain, "snapshot", side_effect=snapshot),
        ):
            drain.wait_for_drain({"worker": 7}, 10)
        self.assertEqual(passes, [1, 2, 3, 4])

    def test_busy_or_slow_inspection_cannot_outlive_the_deadline_and_succeed(self):
        def check_timeout(inspection_cost):
            clock = [0.0]

            def sleep(seconds):
                clock[0] += seconds

            def snapshot(_identity, _deadline):
                clock[0] += inspection_cost
                return not inspection_cost

            with (
                patch.object(drain.time, "monotonic", side_effect=lambda: clock[0]),
                patch.object(drain.time, "sleep", side_effect=sleep),
                patch.object(drain, "snapshot", side_effect=snapshot),
                self.assertRaises(TimeoutError),
            ):
                drain.wait_for_drain({}, 3)

        for inspection_cost in (0, 4):
            with self.subTest(inspection_cost=inspection_cost):
                check_timeout(inspection_cost)

    def test_ports_are_read_from_tinyproxy_and_invalid_configuration_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "tinyproxy.conf"
            with patch.object(drain, "TINYPROXY_CONFIG", config):
                config.write_text("ConnectPort 2222\nConnectPort 3333\n")
                self.assertEqual(drain.tracked_ports(), {443, 8888, 2222, 3333})
                for value in ("", "ConnectPort 0\n", "ConnectPort 22 extra\n"):
                    config.write_text(value)
                    with self.assertRaises(RuntimeError):
                        drain.tracked_ports()

    def test_nonterminal_entries_block_in_both_families_and_unknown_state_fails(self):
        calls = []

        def command(args, _deadline):
            calls.append(args)
            if args[3] == "ipv6" and args[-1] == "8888":
                return "tcp 6 90 ESTABLISHED\n"
            return "tcp 6 10 TIME_WAIT\ntcp 6 10 CLOSE\n"

        with patch.object(drain, "command", side_effect=command):
            self.assertTrue(drain.active_conntrack({443, 8888}))
        self.assertEqual(len(calls), 4)
        with (
            patch.object(drain, "command", return_value="tcp 6 3 NEW_STATE\n"),
            self.assertRaises(RuntimeError),
        ):
            drain.active_conntrack({443})


if __name__ == "__main__":
    unittest.main()
