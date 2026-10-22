import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("xcrun"), "the voice probe assertions compile with the Xcode toolchain")
class VoiceProbeAssertionTests(unittest.TestCase):
    def test_swift_assertions_hold(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "assertions"
            subprocess.run(
                ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                 str(TOOLS / "realtime_probe_assertions.swift"),
                 str(TOOLS / "realtime_probe_options.swift"),
                 str(TOOLS / "tests/voice_probe_assertions_tests.swift"),
                 "-o", str(executable)],
                check=True, capture_output=True, text=True, timeout=300,
            )
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
