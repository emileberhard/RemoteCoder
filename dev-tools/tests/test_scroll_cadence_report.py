import runpy
import unittest
from pathlib import Path

import numpy as np

report = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scroll-cadence-report"))


class ScrollCadenceReportTests(unittest.TestCase):
    def setUp(self):
        lines = np.random.default_rng(7).integers(0, 255, (24, 300)).astype(np.float32)
        self.image = np.repeat(lines, 20, axis=0)

    def test_shifts_in_both_directions_beyond_a_line_height(self):
        for shift in (7, -15, 45, -90):
            moved = np.roll(self.image, shift, axis=0)
            self.assertEqual(report["vertical_shift"](self.image, moved, 200)[0], shift)

    def test_identical_and_faded_frames_do_not_move(self):
        self.assertEqual(report["vertical_shift"](self.image, self.image.copy(), 200)[0], 0)
        self.assertEqual(report["vertical_shift"](self.image, self.image * 0.6, 200)[0], 0)

    def test_skipped_vsyncs_and_judder_are_counted(self):
        vsync = 1 / 120
        times = [index * vsync for index in range(10)] + [12 * vsync, 14 * vsync]
        frames = [{"t": t, "shift": 8} for t in times]
        frames[11]["shift"] = 24
        summary = report["summarize"](frames, 120)
        self.assertEqual(summary["intervalsByVsyncs"], {"1": 9, "3": 1, "2": 1})
        self.assertEqual(summary["skippedFrames"], 3)
        self.assertEqual(summary["judderShare"], round(2 / 11, 3))


if __name__ == "__main__":
    unittest.main()
