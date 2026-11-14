import contextlib
import importlib.machinery
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SERVER = Path(__file__).resolve().parents[2] / "relay/server"
sys.path.insert(0, str(SERVER))
loader = importlib.machinery.SourceFileLoader(
    "relay_recover_fixture", str(SERVER / "maintenance-recover")
)
spec = importlib.util.spec_from_loader(loader.name, loader)
recover = importlib.util.module_from_spec(spec)
loader.exec_module(recover)


class RelayBootRecoveryTests(unittest.TestCase):
    def test_retry_after_bounded_attempt_recovers_a_late_tunnel(self):
        clock = [0.0]
        attempts = []

        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "maintenance.json"
            marker.touch()

            class Transaction:
                def __enter__(self):
                    return self

                def __exit__(self, *_args):
                    return None

                def reopen_after_new_boot(self, _timeout):
                    attempts.append(clock[0])
                    if clock[0] < 240:
                        raise RuntimeError("tunnel unavailable")
                    marker.unlink()

            with (
                patch.object(recover, "MARKER", marker),
                patch.object(recover, "RelayTransaction", Transaction),
                patch.object(recover.time, "monotonic", side_effect=lambda: clock[0]),
                patch.object(
                    recover.time,
                    "sleep",
                    side_effect=lambda value: clock.__setitem__(0, clock[0] + value),
                ),
                contextlib.redirect_stdout(io.StringIO()),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                with self.assertRaises(RuntimeError):
                    recover.recover_new_boot(180)
                self.assertTrue(marker.exists())
                clock[0] += 10
                recover.recover_new_boot(180)
            self.assertFalse(marker.exists())
        self.assertEqual(attempts[-1], 240)

    def test_retries_unready_services_then_reopens_under_the_owner(self):
        clock = [0.0]
        attempts = []

        class Transaction:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return None

            def reopen_after_new_boot(self, timeout):
                attempts.append((clock[0], timeout))
                if len(attempts) < 3:
                    raise RuntimeError("tunnel unavailable")

        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "maintenance.json"
            marker.touch()
            with (
                patch.object(recover, "MARKER", marker),
                patch.object(recover, "RelayTransaction", Transaction),
                patch.object(recover.time, "monotonic", side_effect=lambda: clock[0]),
                patch.object(
                    recover.time,
                    "sleep",
                    side_effect=lambda value: clock.__setitem__(0, clock[0] + value),
                ),
                contextlib.redirect_stdout(io.StringIO()),
                contextlib.redirect_stderr(io.StringIO()) as errors,
            ):
                recover.recover_new_boot(25)
        self.assertEqual(attempts, [(0, 10), (10, 10), (20, 5)])
        self.assertEqual(errors.getvalue().count("tunnel unavailable; retrying"), 2)

    def test_timeout_keeps_marker_and_reports_the_last_failure(self):
        clock = [0.0]

        class Transaction:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return None

            def reopen_after_new_boot(self, _timeout):
                raise RuntimeError("missing firewall fence")

        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "maintenance.json"
            marker.touch()
            with (
                patch.object(recover, "MARKER", marker),
                patch.object(recover, "RelayTransaction", Transaction),
                patch.object(recover.time, "monotonic", side_effect=lambda: clock[0]),
                patch.object(
                    recover.time,
                    "sleep",
                    side_effect=lambda value: clock.__setitem__(0, clock[0] + value),
                ),
                contextlib.redirect_stderr(io.StringIO()),
                self.assertRaisesRegex(RuntimeError, "missing firewall fence"),
            ):
                recover.recover_new_boot(2)
            self.assertTrue(marker.exists())


if __name__ == "__main__":
    unittest.main()
