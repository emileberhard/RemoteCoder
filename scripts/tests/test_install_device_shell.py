import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "install-device"


class InstallDeviceShellTests(unittest.TestCase):
    def test_modes_select_real_compiler_flags_and_reject_conflicts(self):
        source = SCRIPT.read_text()
        parsing = (
            "usage() {" + source.split("usage() {", 1)[1].split("\nphase_start()", 1)[0]
        )
        function = (
            "run_xcodebuild_build() {"
            + source.split("run_xcodebuild_build() {", 1)[1].split("\nbuild_app()", 1)[
                0
            ]
        )
        modes = [
            ([], "true", "singlefile", "-ios-incremental-optimized"),
            (["--optimized"], "true", "wholemodule", ""),
            (
                ["--incremental-optimized"],
                "true",
                "singlefile",
                "-ios-incremental-optimized",
            ),
            (["--unoptimized"], "false", "singlefile", "-ios-unoptimized"),
        ]
        for arguments, optimized, compilation, suffix in modes:
            with (
                self.subTest(arguments=arguments),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                environment = os.environ | {
                    "OPTIMIZED": "true",
                    "COMPILATION_MODE": "singlefile",
                    "MODE_FLAG": "",
                    "DERIVED_DATA": str(root / "derived"),
                    "RC_IOS_DEVICE_VARIANT_SET": "0",
                    "BUILD_LOG": str(root / "build.log"),
                    "BUILD_IDENTITY": "fixture",
                    "RC_BUILD_SETTINGS_EVIDENCE": "fixture",
                    "SCHEME": "RemoteCoder",
                    "CALLS": str(root / "calls"),
                }
                parsed = subprocess.run(
                    [
                        "/bin/bash",
                        "-c",
                        "set -eu\n"
                        + parsing
                        + '\nprintf "%s|%s|%s" "$OPTIMIZED" "$COMPILATION_MODE" "$DERIVED_DATA"',
                        "--",
                        *arguments,
                    ],
                    env=environment,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(parsed.returncode, 0, parsed.stderr)
                self.assertEqual(
                    parsed.stdout,
                    optimized
                    + "|"
                    + compilation
                    + "|"
                    + str(root / "derived")
                    + suffix,
                )
                shell = (
                    """set -eu
xcode_auth_flags() { :; }
phase_start() { printf 0; }
phase_finish() { :; }
python3() { :; }
xcodebuild() { printf '%s\\n' "$@" >> "$CALLS"; printf 'BUILD SUCCEEDED\\n'; }
BUILD_IDENTITY_FLAGS=(CURRENT_PROJECT_VERSION=1.0.1)
"""
                    + function
                    + "\nrun_xcodebuild_build"
                )
                built = subprocess.run(
                    ["/bin/bash", "-c", shell],
                    env=environment
                    | {"OPTIMIZED": optimized, "COMPILATION_MODE": compilation},
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(built.returncode, 0, built.stderr)
                flags = (root / "calls").read_text().splitlines()
                self.assertIn(
                    "SWIFT_OPTIMIZATION_LEVEL="
                    + ("-O" if optimized == "true" else "-Onone"),
                    flags,
                )
                self.assertIn("SWIFT_COMPILATION_MODE=" + compilation, flags)
        for arguments in (
            ["--optimized", "--unoptimized"],
            ["--unoptimized", "--incremental-optimized"],
            ["--incremental-optimized", "--optimized"],
        ):
            rejected = subprocess.run(
                ["/bin/bash", "-c", "set -eu\n" + parsing, "--", *arguments],
                env=os.environ | {"MODE_FLAG": ""},
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(rejected.returncode, 2, rejected.stderr)
            self.assertIn("Select only one", rejected.stderr)

    def test_artifact_dispatch_under_system_bash_nounset(self):
        # Execute the real dispatch block with only its external effects replaced.
        dispatch = SCRIPT.read_text().split(
            "# Build admission is independent of phone reachability; delivery owns its transport.\n",
            1,
        )[1]
        for optimized, compilation, force in (
            ("true", "wholemodule", "false"),
            ("true", "singlefile", "false"),
            ("false", "singlefile", "false"),
            ("true", "wholemodule", "true"),
        ):
            with (
                self.subTest(optimized=optimized, force=force),
                tempfile.TemporaryDirectory() as temporary,
            ):
                log = Path(temporary) / "calls"
                shell = (
                    """set -eu
build_app() { printf 'build\\n' >> "$CALLS"; }
python3() {
  printf '%s' "$1" >> "$CALLS"
  shift
  printf ' <%s>' "$@" >> "$CALLS"
  printf '\\n' >> "$CALLS"
  case "${1:-}" in
    reuse) return 3 ;;
    publish) printf '/fixture/artifact.json\\n' ;;
  esac
}
"""
                    + dispatch
                )
                result = subprocess.run(
                    ["/bin/bash", "-c", shell],
                    capture_output=True,
                    text=True,
                    check=False,
                    env=os.environ
                    | {
                        "CALLS": str(log),
                        "OPTIMIZED": optimized,
                        "COMPILATION_MODE": compilation,
                        "FORCE_BUILD": force,
                        "BUILD_ONLY": "true",
                        "APP_PATH": "/fixture/app",
                        "RC_BUILD_SETTINGS_EVIDENCE": "/fixture/settings",
                    },
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = log.read_text()
                self.assertIn("build\n", calls)
                self.assertIn("<publish>", calls)
                self.assertEqual("<--unoptimized>" in calls, optimized == "false")
                self.assertEqual(
                    "<--incremental-optimized>" in calls,
                    optimized == "true" and compilation == "singlefile",
                )
                self.assertEqual("<reuse>" in calls, force == "false")
                self.assertIn("/fixture/artifact.json", result.stdout)


if __name__ == "__main__":
    unittest.main()
