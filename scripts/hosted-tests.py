import json
import os
import subprocess
import sys
from pathlib import Path
from uuid import uuid4

from test_execution import require_executed_tests


def verified_counts(summary: dict) -> tuple[int, int]:
    total, skipped, failed = (
        summary[name] for name in ("totalTestCount", "skippedTests", "failedTests")
    )
    if (
        any(type(count) is not int or count < 0 for count in (total, skipped, failed))
        or skipped + failed > total
    ):
        raise ValueError("Xcode test summary has invalid execution counts")
    if failed or summary["result"] == "Failed":
        raise ValueError("Xcode test summary reports failed tests")
    return total - skipped, skipped


def main():
    command = sys.argv[1:]
    provenance = os.environ.get("RC_BUILD_PROVENANCE")
    if not provenance:
        print(
            "Use just ios-simulator-test or just ios-ui-test to provide the owned result directory",
            file=sys.stderr,
        )
        return 2
    bundle = Path(provenance).parent / ("Test-" + uuid4().hex + ".xcresult")
    bundle.parent.mkdir(parents=True, exist_ok=True)
    selected = [
        value.removeprefix("-only-testing:")
        for value in command
        if value.startswith("-only-testing:")
    ]
    evidence = {
        "stage": "testExecution",
        "filters": selected,
        "xcresult": str(bundle),
        "executed": None,
        "skipped": None,
        "exitCode": None,
    }
    print(f"Xcode test results: {bundle}", flush=True)
    status = subprocess.run(
        [*command, "-resultBundlePath", str(bundle)], check=False
    ).returncode
    evidence["exitCode"] = status
    if status == 0:
        try:
            report = subprocess.run(
                [
                    "xcrun",
                    "xcresulttool",
                    "get",
                    "test-results",
                    "summary",
                    "--path",
                    str(bundle),
                    "--compact",
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            bundle.with_suffix(".summary.json").write_text(report.stdout)
            executed, skipped = verified_counts(json.loads(report.stdout))
            evidence.update({"executed": executed, "skipped": skipped})
            require_executed_tests(executed, " ".join(selected))
        except (
            OSError,
            subprocess.CalledProcessError,
            ValueError,
            KeyError,
            TypeError,
        ) as error:
            print(
                f"Xcode test execution could not be verified: {error}; results: {bundle}",
                file=sys.stderr,
            )
            status = 1
            evidence["exitCode"] = status
        else:
            print(
                f"Xcode test verification: {executed} tests executed, {skipped} skipped",
                flush=True,
            )
    stages = os.environ.get("RC_BUILD_STAGES")
    if stages:
        with Path(stages).open("a") as output:
            output.write(json.dumps(evidence) + "\n")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
