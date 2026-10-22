import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location(
    "hosted_tests", SCRIPTS / "hosted-tests.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class HostedTestExecutionTests(unittest.TestCase):
    def test_mistyped_filters_and_unverified_results_cannot_pass(self):
        for summary in (
            {
                "totalTestCount": 0,
                "skippedTests": 0,
                "failedTests": 0,
                "result": "Passed",
            },
            {
                "totalTestCount": 1,
                "skippedTests": 1,
                "failedTests": 0,
                "result": "Skipped",
            },
            {
                "totalTestCount": 1,
                "skippedTests": 0,
                "failedTests": 1,
                "result": "Failed",
            },
            {"totalTestCount": 1, "skippedTests": 0},
            {
                "totalTestCount": False,
                "skippedTests": 0,
                "failedTests": 0,
                "result": "Passed",
            },
            "truncated",
        ):
            with (
                self.subTest(summary=summary),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                stages = root / "stages.jsonl"
                report = json.dumps(summary) if isinstance(summary, dict) else summary
                with (
                    patch.object(
                        sys,
                        "argv",
                        [
                            "hosted-tests.py",
                            "xcodebuild",
                            "-derivedDataPath",
                            str(root),
                            "-only-testing:RemoteCoderTests/ChatHistoryReadTests/notATest",
                        ],
                    ),
                    patch.dict(
                        os.environ,
                        {
                            "RC_BUILD_STAGES": str(stages),
                            "RC_BUILD_PROVENANCE": str(root / "source.json"),
                        },
                    ),
                    patch.object(
                        module.subprocess,
                        "run",
                        side_effect=[
                            subprocess.CompletedProcess([], 0),
                            subprocess.CompletedProcess([], 0, stdout=report),
                        ],
                    ),
                    redirect_stdout(io.StringIO()),
                    redirect_stderr(io.StringIO()),
                ):
                    self.assertEqual(module.main(), 1)
                evidence = json.loads(stages.read_text())
                self.assertEqual(evidence["exitCode"], 1)
                self.assertEqual(
                    evidence["filters"],
                    ["RemoteCoderTests/ChatHistoryReadTests/notATest"],
                )
                self.assertEqual(Path(evidence["xcresult"]).parent, root)

    def test_real_failure_status_is_preserved_without_reinterpreting_partial_results(
        self,
    ):
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(
                sys,
                "argv",
                ["hosted-tests.py", "xcodebuild", "-derivedDataPath", temporary],
            ),
            patch.object(
                module.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 65),
            ) as run,
            patch.dict(
                os.environ,
                {"RC_BUILD_PROVENANCE": str(Path(temporary) / "source.json")},
                clear=True,
            ),
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(module.main(), 65)
            run.assert_called_once()

    def test_a_verified_run_counts_executed_cases_and_uses_a_fresh_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stages = root / "stages.jsonl"
            bundles = []

            def run(command, **kwargs):
                if command[0] == "xcodebuild":
                    bundle = Path(command[command.index("-resultBundlePath") + 1])
                    self.assertFalse(bundle.exists())
                    bundle.mkdir()
                    bundles.append(bundle)
                    return subprocess.CompletedProcess(command, 0)
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout=json.dumps(
                        {
                            "totalTestCount": 3,
                            "skippedTests": 1,
                            "failedTests": 0,
                            "result": "Passed",
                        }
                    ),
                )

            with (
                patch.object(
                    sys,
                    "argv",
                    [
                        "hosted-tests.py",
                        "xcodebuild",
                        "-derivedDataPath",
                        str(root),
                        "-only-testing:RemoteCoderTests/ChatHistoryReadTests",
                    ],
                ),
                patch.dict(
                    os.environ,
                    {
                        "RC_BUILD_STAGES": str(stages),
                        "RC_BUILD_PROVENANCE": str(root / "source.json"),
                    },
                ),
                patch.object(module.subprocess, "run", side_effect=run),
                redirect_stdout(io.StringIO()) as output,
            ):
                self.assertEqual(module.main(), 0)
                self.assertEqual(module.main(), 0)
            self.assertEqual(len(set(bundles)), 2)
            self.assertIn("2 tests executed, 1 skipped", output.getvalue())
            for line in stages.read_text().splitlines():
                evidence = json.loads(line)
                self.assertEqual(
                    (evidence["executed"], evidence["skipped"], evidence["exitCode"]),
                    (2, 1, 0),
                )
