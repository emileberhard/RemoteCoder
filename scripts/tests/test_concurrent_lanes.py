import gc
import io
import os
import signal
import sys
import tempfile
import time
import unittest
import warnings
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from concurrent_lanes import lane_streams, run_lanes  # noqa: E402
from hang_guard import HANG_SECONDS  # noqa: E402


def python(code):
    return [sys.executable, "-c", code]


class ConcurrentLanesTests(unittest.TestCase):
    def test_a_failure_stops_the_other_lane_and_returns_its_status(self):
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "started"
            records = []
            output = io.BytesIO()
            started = time.monotonic()
            status = run_lanes(
                {
                    "slow": [
                        ("long", python(f"import time; time.sleep({HANG_SECONDS})")),
                        ("after", python(f"open({str(marker)!r}, 'w')")),
                    ],
                    "fast": [("broken", python("print('boom'); raise SystemExit(3)"))],
                },
                temporary,
                lambda step, _seconds, code: records.append((step, code)),
                output,
            )
            self.assertEqual(status, 3)
            self.assertLess(time.monotonic() - started, HANG_SECONDS)
            self.assertFalse(marker.exists())
            self.assertIn(("broken", 3), records)
            self.assertIn(b"[fast] boom\n", output.getvalue())
            self.assertIn(b"[fast] broken failed with exit status 3\n", output.getvalue())

    def test_a_failure_does_not_wait_for_a_sibling_descendant_holding_the_pipe(self):
        with tempfile.TemporaryDirectory() as temporary:
            holder = Path(temporary) / "holder"
            try:
                status = run_lanes(
                    {
                        "slow": [
                            (
                                "spawns",
                                python(
                                    "import os, pathlib, subprocess, time; "
                                    f"pid = subprocess.Popen(['sleep', '{HANG_SECONDS}']).pid; "
                                    f"pathlib.Path({str(holder)!r} + '.new').write_text(str(pid)); "
                                    f"os.replace({str(holder)!r} + '.new', {str(holder)!r}); "
                                    f"time.sleep({HANG_SECONDS})"
                                ),
                            )
                        ],
                        "fast": [
                            (
                                "broken",
                                python(
                                    "import pathlib, time\n"
                                    f"deadline = time.monotonic() + {HANG_SECONDS}\n"
                                    f"while not pathlib.Path({str(holder)!r}).exists() and time.monotonic() < deadline: time.sleep(0.01)\n"
                                    "raise SystemExit(2)"
                                ),
                            )
                        ],
                    },
                    ".",
                    output=io.BytesIO(),
                )
            finally:
                try:
                    os.kill(int(holder.read_text()), signal.SIGKILL)
                    holder_outlived_run = True
                except (FileNotFoundError, ProcessLookupError):
                    holder_outlived_run = False
            self.assertEqual(status, 2)
            self.assertTrue(holder_outlived_run, "run_lanes waited for the pipe holder to exit")

    def test_a_finished_lane_closes_its_output_pipe(self):
        gc.collect()
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always", ResourceWarning)
            status = run_lanes(
                {"only": [("print", python("print('done')"))]}, ".", output=io.BytesIO()
            )
            gc.collect()
        self.assertEqual(status, 0)
        self.assertEqual(
            [str(w.message) for w in caught if issubclass(w.category, ResourceWarning)], []
        )

    def test_a_step_that_cannot_start_fails_the_run(self):
        output = io.BytesIO()
        status = run_lanes(
            {
                "only": [("missing", ["/nonexistent/remotecoder-tool"])],
                "other": [("wait", python("import time; time.sleep(30)"))],
            },
            ".",
            output=output,
        )
        self.assertEqual(status, 1)
        self.assertIn(b"[only] lane stopped:", output.getvalue())
        self.assertIn(b"/nonexistent/remotecoder-tool", output.getvalue())

    def test_lanes_overlap_and_pass_together(self):
        names = ("first", "second", "third")
        meet = (
            "import pathlib, sys, time\n"
            "pathlib.Path(sys.argv[1]).touch()\n"
            f"deadline = time.monotonic() + {HANG_SECONDS}\n"
            f"while not all(pathlib.Path(n).exists() for n in {names!r}):\n"
            "    if time.monotonic() > deadline: sys.exit(1)\n"
            "    time.sleep(0.01)\n"
        )
        with tempfile.TemporaryDirectory() as temporary:
            status = run_lanes(
                {name: [("meet", python(meet) + [name])] for name in names},
                temporary,
                output=io.BytesIO(),
            )
            self.assertEqual(status, 0)


    def test_lane_streams_keep_each_lanes_lines_adjacent_when_output_interleaves(self):
        self.assertEqual(
            sorted(
                lane_streams(
                    "[apps] error: first\n"
                    "[gateway] [cargo] Compiling\n"
                    "[apps] second\n"
                    "[gateway] [tooling] ok\n"
                )
            ),
            ["Compiling\n", "error: first\nsecond\n", "ok\n"],
        )


if __name__ == "__main__":
    unittest.main()
