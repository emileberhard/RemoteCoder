import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("core_test", SCRIPTS / "core-test.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NativeTestSelectionTests(unittest.TestCase):
    def setUp(self):
        streams = ExitStack()
        self.addCleanup(streams.close)
        streams.enter_context(redirect_stdout(io.StringIO()))
        streams.enter_context(redirect_stderr(io.StringIO()))

    def test_a_typo_or_absent_report_cannot_create_successful_verification(self):
        for xml in (None, '<testsuites><testsuite tests="0"/></testsuites>'):

            def swift(command, check, xml=xml):
                if xml is not None:
                    path = Path(command[command.index("--xunit-output") + 1])
                    path.write_text(xml)
                    path.with_name("tests-swift-testing.xml").write_text(xml)
                return subprocess.CompletedProcess(command, 0)

            with (
                patch.object(
                    sys, "argv", ["core-test.py", "DefinitelyMisspelledTests"]
                ),
                patch.object(module.subprocess, "run", side_effect=swift),
            ):
                self.assertEqual(module.main(), 1)

    def test_swift_testing_sidecar_is_counted_and_failure_status_is_preserved(self):
        def swift(command, check):
            path = Path(command[command.index("--xunit-output") + 1])
            path.write_text('<testsuites><testsuite tests="0"/></testsuites>')
            path.with_name("tests-swift-testing.xml").write_text(
                '<testsuites><testsuite><testcase name="actual"/><testcase name="gated"><skipped/></testcase></testsuite></testsuites>'
            )
            return subprocess.CompletedProcess(command, 0)

        with (
            redirect_stdout(io.StringIO()) as output,
            patch.object(sys, "argv", ["core-test.py", "ActualTests"]),
            patch.object(module.subprocess, "run", side_effect=swift),
        ):
            self.assertEqual(module.main(), 0)
            self.assertIn("1 tests executed, 1 skipped", output.getvalue())
        with (
            patch.object(sys, "argv", ["core-test.py", "ActualTests"]),
            patch.object(
                module.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 65),
            ),
        ):
            self.assertEqual(module.main(), 65)

    def test_skipped_cases_and_malformed_reports_are_not_executed_tests(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "tests.xml"
            report.write_text("<testsuite><testcase><skipped/></testcase></testsuite>")
            self.assertEqual(module.test_counts(report), (0, 1))
            report.write_text("malformed")
            with self.assertRaises(ET.ParseError):
                module.test_counts(report)

    def test_malformed_sidecar_cannot_be_hidden_by_another_executed_report(self):
        def swift(command, check):
            path = Path(command[command.index("--xunit-output") + 1])
            path.write_text('<testsuite><testcase name="actual"/></testsuite>')
            path.with_name("tests-swift-testing.xml").write_text("truncated")
            return subprocess.CompletedProcess(command, 0)

        with patch.object(module.subprocess, "run", side_effect=swift):
            self.assertEqual(module.main(), 1)

    def test_a_missing_required_report_cannot_be_hidden_by_the_other(self):
        for missing in ("tests.xml", "tests-swift-testing.xml"):
            with self.subTest(missing=missing):

                def swift(command, check, missing=missing):
                    report = Path(command[command.index("--xunit-output") + 1])
                    for name in ("tests.xml", "tests-swift-testing.xml"):
                        if name != missing:
                            report.with_name(name).write_text(
                                '<testsuite><testcase name="actual"/></testsuite>'
                            )
                    return subprocess.CompletedProcess(command, 0)

                with patch.object(module.subprocess, "run", side_effect=swift):
                    self.assertEqual(module.main(), 1)
