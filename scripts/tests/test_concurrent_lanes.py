import io
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from concurrent_lanes import lane_streams, run_lanes  # noqa: E402


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
                        ("long", python("import time; time.sleep(30)")),
                        ("after", python(f"open({str(marker)!r}, 'w')")),
                    ],
                    "fast": [("broken", python("print('boom'); raise SystemExit(3)"))],
                },
                temporary,
                lambda step, _seconds, code: records.append((step, code)),
                output,
            )
            self.assertEqual(status, 3)
            self.assertLess(time.monotonic() - started, 10)
            self.assertFalse(marker.exists())
            self.assertIn(("broken", 3), records)
            self.assertIn(b"[fast] boom\n", output.getvalue())
            self.assertIn(b"[fast] broken failed with exit status 3\n", output.getvalue())

    def test_a_failure_does_not_wait_for_a_sibling_descendant_holding_the_pipe(self):
        started = time.monotonic()
        status = run_lanes(
            {
                "slow": [
                    (
                        "spawns",
                        python(
                            "import subprocess, time; subprocess.Popen(['sleep', '4']); time.sleep(30)"
                        ),
                    )
                ],
                "fast": [("broken", python("import time; time.sleep(0.5); raise SystemExit(2)"))],
            },
            ".",
            output=io.BytesIO(),
        )
        self.assertEqual(status, 2)
        self.assertLess(time.monotonic() - started, 3)

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
        with tempfile.TemporaryDirectory() as temporary:
            started = time.monotonic()
            status = run_lanes(
                {
                    name: [("wait", python("import time; time.sleep(1)"))]
                    for name in ("first", "second", "third")
                },
                temporary,
                output=io.BytesIO(),
            )
            self.assertEqual(status, 0)
            self.assertLess(time.monotonic() - started, 2.5)


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
