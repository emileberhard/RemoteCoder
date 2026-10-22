import runpy
import unittest
from pathlib import Path

import numpy as np

report = runpy.run_path(str(Path(__file__).resolve().parents[1] / "streaming-motion-report"))


class MotionReportTests(unittest.TestCase):
    def setUp(self):
        random = np.random.default_rng(12)
        self.image = np.repeat(random.integers(10, 200, (400, 1), dtype=np.uint8), 60, axis=1)
        self.image[:80] = 0
        self.image[-80:] = 0

    def test_opacity_ramp_is_not_a_jump(self):
        faded = (self.image.astype(float) * 0.65).astype(np.uint8)
        self.assertEqual(report["vertical_shift"](self.image, faded)[0], 0)

    def test_fourteen_pixel_jump_and_snap_back_are_detected(self):
        shifted = np.roll(self.image, 14, axis=0)
        forward = report["vertical_shift"](self.image, shifted)[0]
        backward = report["vertical_shift"](shifted, self.image)[0]
        self.assertEqual((forward, backward), (14, -14))
        self.assertEqual(report["oscillations"]([0, forward, 0, backward, 0]), [(1, 3)])

    def test_shift_survives_partial_glyph_reflow(self):
        noise = np.repeat(np.random.default_rng(20).integers(0, 255, (400, 1)), 60, axis=1)
        changed = (0.4 * np.roll(self.image, 14, axis=0) + 0.6 * noise).astype(np.uint8)
        shift, correlation = report["vertical_shift"](self.image, changed)
        self.assertEqual(shift, 14)
        self.assertGreater(correlation, 0.45)

    def test_a_return_several_frames_later_is_detected(self):
        twitch = [0, 6] + [0] * 7 + [-6] + [0] * 68
        shifts = twitch + twitch
        self.assertEqual(report["oscillations"](shifts), [(1, 9), (79, 87)])

    def test_a_return_beyond_the_window_is_not_paired(self):
        self.assertEqual(report["oscillations"]([0, 6] + [0] * 30 + [-6]), [])

    def test_monotonic_scroll_does_not_count_as_oscillation(self):
        self.assertEqual(report["oscillations"]([0, 14, 14, 0, 12, 0]), [])


if __name__ == "__main__":
    unittest.main()
