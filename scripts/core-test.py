#!/usr/bin/env python3
"""Run native Swift tests and require executed cases, including filtered runs."""

import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from test_execution import require_executed_tests


def test_counts(report: Path) -> tuple[int, int]:
    cases = list(ET.parse(report).iter("testcase"))
    skipped = sum(case.find("skipped") is not None for case in cases)
    return len(cases) - skipped, skipped


def main():
    root = Path(__file__).resolve().parents[1]
    scratch = os.environ.get("RC_SWIFT_BUILD_PATH", str(root / "build/swift-core"))
    selected = sys.argv[1] if len(sys.argv) > 1 else ""
    with tempfile.TemporaryDirectory(prefix="swift-test-report-") as temporary:
        report = Path(temporary) / "tests.xml"
        command = [
            "xcrun",
            "swift",
            "test",
            "--package-path",
            str(root / "Core"),
            "--scratch-path",
            scratch,
            "--parallel",
            "--xunit-output",
            str(report),
        ]
        if selected:
            command.extend(["--filter", selected])
        status = subprocess.run(command, check=False).returncode
        if status:
            return status
        # SwiftPM writes a separate *-swift-testing.xml when XCTest is enabled.
        try:
            counts = [
                test_counts(report),
                test_counts(report.with_name("tests-swift-testing.xml")),
            ]
        except (OSError, ET.ParseError) as error:
            print(
                f"Native Swift test report could not be read: {error}", file=sys.stderr
            )
            return 1
        executed = sum(count[0] for count in counts)
        skipped = sum(count[1] for count in counts)
        try:
            require_executed_tests(executed, selected)
        except ValueError as error:
            print(str(error), file=sys.stderr)
            return 1
        print(
            f"Native Swift verification: {executed} tests executed, {skipped} skipped",
            flush=True,
        )
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
