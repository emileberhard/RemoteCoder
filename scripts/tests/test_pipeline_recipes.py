import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class PipelineRecipesTests(unittest.TestCase):
    def test_fork_noop_command_refreshes_usage_and_preserves_exit_status(self):
        recipe = (ROOT / "justfile").read_text().split("<<'OWNED'\n", 1)[1].split("    OWNED", 1)[0]
        for status in (0, 7):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                tools = root / "tools"
                tools.mkdir()
                for name in ("rsync-source.py", "codex-cache.py", "rusty-v8-artifacts.py"):
                    (tools / name).write_text("")
                (root / "src/codex-rs").mkdir(parents=True)
                lock = root / "build.lock"
                lock.touch()
                result = subprocess.run(
                    ["bash", "-s", "--", str(root), str(tools), "run", sys.executable,
                     "-c", "import os,sys; os.utime(sys.argv[1], (1,1)); sys.exit(int(sys.argv[2]))",
                     str(lock), str(status)],
                    input=recipe, capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertGreater(lock.stat().st_mtime, 1)

    def test_fork_command_runs_locally_without_ssh(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("justfile", ".xcode-version"):
                shutil.copy2(ROOT / name, root / name)
            tools = root / "scripts"
            tools.mkdir()
            for name in ("build-host", "build_hosts.py", "maintainer_config.py", "build_support.py", "job_power.py", "process_group.py", "codex-cache.py", "rsync-source.py"):
                shutil.copy2(ROOT / "scripts" / name, tools / name)
            (tools / "rusty-v8-artifacts.py").write_text("")
            source = root / "fork/codex-rs"
            source.mkdir(parents=True)
            (source / "fixture.txt").write_text("local fork source")
            home = root / "home"
            home.mkdir()
            result_path = root / "result.txt"
            bin_dir = root / "bin"
            bin_dir.mkdir()
            (bin_dir / "bash").symlink_to("/bin/bash")
            result = subprocess.run(
                ["just", "codex-fork-run", str(source.parent), sys.executable, "-c",
                 "from pathlib import Path; import sys; Path(sys.argv[1]).write_text(Path('fixture.txt').read_text())", str(result_path)],
                cwd=root,
                env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "HOME": str(home), "RC_GATEWAY_BUILD_HOST": "local", "ZDOTDIR": str(root)},
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result_path.is_file(), result.stdout + result.stderr)
            self.assertEqual(result_path.read_text(), "local fork source")
            cache = home / "Library/Caches/RemoteCoder-Build/codex-fork-check"
            self.assertTrue((cache / "build.lock").is_file())
            self.assertEqual(list((cache / "runs").iterdir()), [])

    def test_build_gates_preserve_architecture_status_and_per_invocation_evidence(self):
        fixture = ROOT / "scripts/tests/fixtures/xcode/exit-zero.txt"
        for recipe, mode, expected in (
            ("ios-build-local", "fresh", 0),
            ("ios-build-local", "stale", 1),
            ("ios-build-local", "native-failure", 65),
            ("ios-build-local", "nonquiet", 0),
            ("mac-build-local", "nonquiet", 0),
            ("mac-harness-build-local", "nonquiet", 0),
        ):
            with (
                self.subTest(recipe=recipe, mode=mode),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                for name in ("justfile", ".xcode-version", ".tuist-version"):
                    shutil.copy2(ROOT / name, root / name)
                (root / "scripts").mkdir()
                for name in ("build-host", "xcode_build.py", "maintainer_config.py"):
                    shutil.copy2(ROOT / "scripts" / name, root / "scripts" / name)
                bin_dir = root / "bin"
                bin_dir.mkdir()
                (bin_dir / "tuist").write_text(
                    '#!/bin/sh\nif [ "$1" = version ]; then cat .tuist-version; fi\n'
                )
                (bin_dir / "xcodebuild").write_text(
                    f"#!{sys.executable}\n"
                    + """import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path('arguments.jsonl').open('a') as stream:
    stream.write(json.dumps(args) + '\\n')
scheme = args[args.index('-scheme') + 1]
derived = Path(args[args.index('-derivedDataPath') + 1])
product = derived / 'Build/Products/Debug-iphonesimulator/RemoteCoder.app/PlugIns/RemoteCoderTests.xctest/RemoteCoderTests'
if os.environ['FIXTURE_MODE'] != 'stale' or scheme == 'RemoteCoder':
    product.parent.mkdir(parents=True, exist_ok=True)
    product.write_text(scheme)
log = Path(os.environ['XCODE_LOG_FIXTURE']).read_text().replace('/recorded/', str(Path.cwd()) + '/')
print(log, end='')
sys.exit(65 if os.environ['FIXTURE_MODE'] == 'native-failure' and scheme == 'RemoteCoderUITests' else 0)
"""
                )
                for path in bin_dir.iterdir():
                    path.chmod(0o755)
                derived = root / "derived"
                stages_path = root / "stages.jsonl"
                environment = {
                    k: v for k, v in os.environ.items() if k not in ("BASH_ENV", "ENV")
                } | {
                    "ZDOTDIR": str(root),
                    "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                    "RC_DERIVED_DATA": str(derived),
                    "RC_COMPILATION_OWNER": "1",
                    "RC_BUILD_STAGES": str(stages_path),
                    "XCODE_LOG_FIXTURE": str(
                        ROOT / "scripts/tests/fixtures/xcode/warning-success.txt"
                        if mode == "nonquiet"
                        else fixture
                    ),
                    "FIXTURE_MODE": mode,
                }
                result = subprocess.run(
                    ["just", recipe],
                    cwd=root,
                    env=environment,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                commands = [
                    json.loads(line)
                    for line in (root / "arguments.jsonl").read_text().splitlines()
                ]
                ios = recipe == "ios-build-local"
                self.assertEqual(len(commands), 2 if ios else 1)
                for command in commands:
                    self.assertNotIn("-quiet", command)
                    if ios:
                        self.assertIn("ARCHS=arm64", command)
                        self.assertIn("build-for-testing", command)
                    else:
                        self.assertIn("build", command)
                    self.assertEqual(
                        command[command.index("-destination") + 1],
                        "generic/platform=iOS Simulator"
                        if ios
                        else "generic/platform=macOS",
                    )
                if expected == 65:
                    self.assertNotEqual(result.returncode, 0)
                else:
                    self.assertEqual(result.returncode, expected, result.stderr)
                stages = [
                    json.loads(line) for line in stages_path.read_text().splitlines()
                ]
                self.assertEqual(
                    [stage["exitCode"] for stage in stages],
                    [0, expected] if ios else [0],
                )
                self.assertEqual(
                    [stage["stage"] for stage in stages],
                    ["iosCompile"] * 2 if ios else ["macCompile"],
                )
                self.assertEqual(
                    len(stages[0]["xcodeExitZeroDiagnostics"]),
                    0 if mode == "nonquiet" else 7,
                )
                if mode == "stale":
                    self.assertIn("missing or stale", result.stderr)
                    self.assertLess(
                        next(
                            Path(path)
                            for path in stages[0]["verifiedProducts"]
                            if path.endswith(".xctest/RemoteCoderTests")
                        )
                        .stat()
                        .st_mtime,
                        stages[1]["startedAt"],
                    )

    def test_multiple_simulator_selectors_reach_one_verified_test_invocation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copy2(ROOT / "justfile", root / "justfile")
            shutil.copy2(ROOT / ".xcode-version", root / ".xcode-version")
            shutil.copy2(ROOT / ".tuist-version", root / ".tuist-version")
            (root / "scripts").mkdir(exist_ok=True)
            shutil.copy2(ROOT / "scripts/build-host", root / "scripts/build-host")
            shutil.copy2(ROOT / "scripts/maintainer_config.py", root / "scripts/maintainer_config.py")
            shutil.copy2(ROOT / "scripts/run-logged", root / "scripts/run-logged")
            for helper in (
                "hosted-tests.py",
                "test_execution.py",
                "xcode_build.py",
                "verify-simulator-app.py",
                "xcode_settings.py",
            ):
                shutil.copy2(ROOT / "scripts" / helper, root / "scripts" / helper)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            extensions = [
                "RemoteCoderLiveActivities",
                "RemoteCoderNotificationService",
                "RemoteCoderLocationPushService",
            ]
            (root / "project.json").write_text(
                json.dumps(
                    {
                        "targets": [
                            {
                                "name": "RemoteCoder",
                                "bundleId": "$(RC_BUNDLE_ID)",
                                "dependencies": [
                                    {"target": {"name": name}} for name in extensions
                                ],
                            },
                            *[
                                {
                                    "name": name,
                                    "product": "app_extension",
                                    "bundleId": "$(RC_BUNDLE_ID)." + name,
                                }
                                for name in extensions
                            ],
                        ]
                    }
                )
            )
            (bin_dir / "tuist").write_text(
                '#!/bin/sh\nif [ "$1" = version ]; then cat .tuist-version; elif [ "$1" = dump ]; then cat project.json; fi\n'
            )
            for target in (
                "RemoteCoder",
                "RemoteCoderLiveActivities",
                "RemoteCoderNotificationService",
                "RemoteCoderLocationPushService",
            ):
                source = ROOT / (
                    "RemoteCoder/Entitlements/RemoteCoder.Debug.entitlements"
                    if target == "RemoteCoder"
                    else f"{target}/{target}.entitlements"
                )
                destination = root / source.relative_to(ROOT)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
            (bin_dir / "xcodebuild").write_text(
                f"#!{sys.executable}\n"
                + """import json, os, plistlib, re, shutil, sys
from pathlib import Path
args = sys.argv[1:]
with Path('arguments.jsonl').open('a') as output:
    output.write(json.dumps(args) + '\\n')
settings = {'RC_BUNDLE_ID': 'example.fixture', 'RC_APP_GROUP': 'group.example.fixture', 'RC_ICLOUD_CONTAINER': 'iCloud.example.fixture'}
if '-showBuildSettings' in args:
    targets = json.loads(Path('project.json').read_text())['targets']
    targets.append(targets[0])
    if '-alltargets' not in args:
        targets = [targets[0]]
    entries = [{'target': target['name'], 'buildSettings': settings} for target in targets]
    if os.environ.get('SIGNING_FIXTURE_FAILURE') == 'conflictingSettings':
        entries[-1] = {'target': 'RemoteCoder', 'buildSettings': settings | {'RC_BUNDLE_ID': 'conflicting.identity'}}
    print(json.dumps(entries))
    sys.exit(0)
if 'build-for-testing' in args:
    app = Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products/Debug-iphonesimulator/RemoteCoder.app'
    shutil.rmtree(app, ignore_errors=True)
    failure = os.environ.get('SIGNING_FIXTURE_FAILURE')
    targets = ['RemoteCoder', 'RemoteCoderLiveActivities', 'RemoteCoderNotificationService', 'RemoteCoderLocationPushService']
    if failure == 'unexpectedExtension':
        targets.append('Unexpected')
    for target in targets:
        bundle = app if target == 'RemoteCoder' else app / 'PlugIns' / (target + '.appex')
        if failure == 'missingExtension:' + target:
            shutil.rmtree(bundle, ignore_errors=True)
            continue
        bundle.mkdir(parents=True, exist_ok=True)
        info = {'CFBundleIdentifier': settings['RC_BUNDLE_ID'] + ('' if target == 'RemoteCoder' else '.' + target), 'CFBundleExecutable': target}
        if failure == 'wrongBundleId:' + target:
            info['CFBundleIdentifier'] = 'incorrect.bundle.' + target
        if target == 'RemoteCoder':
            info['NSSupportsLiveActivities'] = failure != 'liveActivities'
            if failure == 'bundleId':
                info.pop('CFBundleIdentifier')
        if target == 'RemoteCoderLiveActivities':
            info['NSExtension'] = {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}
        (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
        declaration = Path('RemoteCoder/Entitlements/RemoteCoder.Debug.entitlements') if target == 'RemoteCoder' else Path(target) / (target + '.entitlements')
        if target == 'Unexpected':
            declaration.parent.mkdir(parents=True, exist_ok=True)
            declaration.write_bytes(plistlib.dumps({}))
        resolved = re.sub(r'\\$\\(([^)]+)\\)', lambda match: settings[match[1]], declaration.read_text())
        signed = plistlib.loads(resolved.encode())
        if failure == 'aps' and target == 'RemoteCoder':
            signed.pop('aps-environment')
        if failure == 'extensionEntitlements' and target == 'RemoteCoderLiveActivities':
            signed.clear()
        (bundle / 'simulator-entitlements.plist').write_bytes(plistlib.dumps(signed) + b'\\0' * 8)
if '-resultBundlePath' in args:
    Path('test-launched').touch()
    bundle = Path(args[args.index('-resultBundlePath') + 1])
    bundle.mkdir()
    (bundle / 'summary.json').write_text(json.dumps(dict(totalTestCount=int(os.environ.get('TEST_TOTAL_TESTS', '1')), skippedTests=0, failedTests=0, result='Passed')))
"""
            )
            (bin_dir / "codesign").write_text(
                f"#!{sys.executable}\n"
                + """import os, plistlib, sys
from pathlib import Path
bundle = Path(sys.argv[-1])
if '--entitlements' in sys.argv:
    sys.stdout.buffer.write(plistlib.dumps({}))
elif '--display' in sys.argv:
    identifier = plistlib.loads((bundle / 'Info.plist').read_bytes())['CFBundleIdentifier']
    print('Identifier=' + identifier, file=sys.stderr)
    print('Signature=adhoc', file=sys.stderr)
    if os.environ.get('SIGNING_FIXTURE_FAILURE') == 'signature':
        print('Info.plist=not bound', file=sys.stderr)
"""
            )
            (bin_dir / "xcrun").write_text(
                f"#!{sys.executable}\n"
                + """import sys
from pathlib import Path
if sys.argv[1] == 'llvm-objcopy':
    section = Path(sys.argv[sys.argv.index('--dump-section') + 1].split('=', 1)[1])
    section.write_bytes((Path(sys.argv[-2]).parent / 'simulator-entitlements.plist').read_bytes())
else:
    print(Path(sys.argv[sys.argv.index('--path') + 1]).joinpath('summary.json').read_text())
"""
            )
            for p in bin_dir.iterdir():
                p.chmod(0o755)
            selectors = [
                "RemoteCoderTests/AccountIsolationTests",
                "RemoteCoderTests/ChatSettingsTests",
            ]
            environment = {
                k: v for k, v in os.environ.items() if k not in ("BASH_ENV", "ENV")
            } | {
                "HOME": str(root),
                "ZDOTDIR": str(root),
                "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                "RC_IOS_SIMULATOR": "Fixture iPhone",
                "RC_BUILD_PROVENANCE": str(root / "source.json"),
                "RC_DERIVED_DATA": str(root / "derived"),
                "RC_COMPILATION_OWNER": "1",
            }
            for recipe in ("ios-simulator-test-local", "ios-ui-test-local"):
                with self.subTest(recipe=recipe):
                    (root / "arguments.jsonl").unlink(missing_ok=True)
                    subprocess.run(
                        ["just", recipe, *selectors],
                        cwd=root,
                        env=environment,
                        capture_output=True,
                        check=True,
                    )
                    commands = [
                        json.loads(line)
                        for line in (root / "arguments.jsonl").read_text().splitlines()
                    ]
                    arguments = commands[-1]
                    if recipe == "ios-simulator-test-local":
                        self.assertEqual(len(commands), 3)
                        self.assertIn("build-for-testing", commands[0])
                        self.assertIn("-showBuildSettings", commands[1])
                        self.assertIn("-alltargets", commands[1])
                        self.assertEqual(commands[1][commands[1].index("-project") + 1], "RemoteCoder.xcodeproj")
                        self.assertIn("test-without-building", commands[2])
                        for command in commands:
                            self.assertEqual(
                                command[command.index("-configuration") + 1], "Debug"
                            )
                            if "-showBuildSettings" not in command:
                                self.assertTrue(
                                    command[command.index("-destination") + 1].startswith(
                                        "platform=iOS Simulator,"
                                    )
                                )
                            self.assertIn("CODE_SIGNING_ALLOWED=YES", command)
                            self.assertIn("CODE_SIGN_IDENTITY=-", command)
                    else:
                        self.assertEqual(len(commands), 1)
                        self.assertIn("test", arguments)
                    self.assertEqual(
                        [a for a in arguments if a.startswith("-only-testing:")],
                        ["-only-testing:" + s for s in selectors],
                    )
                    self.assertEqual(
                        arguments[arguments.index("-workspace") + 1],
                        "RemoteCoder.xcworkspace",
                    )
                    self.assertEqual(
                        arguments[arguments.index("-collect-test-diagnostics") + 1],
                        "never",
                    )
                    negative = subprocess.run(
                        [
                            "just",
                            recipe,
                            "RemoteCoderTests/ChatHistoryReadTests/notATest",
                        ],
                        cwd=root,
                        env=environment | {"TEST_TOTAL_TESTS": "0"},
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertNotEqual(negative.returncode, 0)
                    self.assertIn("No test execution was verified", negative.stdout)
            for failure in (
                "aps",
                "missingExtension:RemoteCoderLiveActivities",
                "missingExtension:RemoteCoderNotificationService",
                "missingExtension:RemoteCoderLocationPushService",
                "unexpectedExtension",
                "wrongBundleId:RemoteCoder",
                "wrongBundleId:RemoteCoderLiveActivities",
                "bundleId",
                "liveActivities",
                "signature",
                "extensionEntitlements",
                "conflictingSettings",
            ):
                with self.subTest(failure=failure):
                    (root / "test-launched").unlink(missing_ok=True)
                    rejected = subprocess.run(
                        ["just", "ios-simulator-test-local", *selectors],
                        cwd=root,
                        env=environment | {"SIGNING_FIXTURE_FAILURE": failure},
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertNotEqual(rejected.returncode, 0, rejected.stdout)
                    self.assertFalse((root / "test-launched").exists())
                    self.assertIn(
                        "Hosted simulator app validation failed", rejected.stderr
                    )
                    self.assertIn("tests were not launched", rejected.stderr)

    def test_app_has_one_lock_with_only_linked_package_pins(self):
        resolved = json.loads((ROOT / ".package.resolved").read_text())
        self.assertEqual(
            {pin["identity"] for pin in resolved["pins"]},
            {"ios-maps-sdk", "ios-navigation-sdk", "speechkit", "webrtc"},
        )

    def test_controllers_resolve_their_helpers_with_safe_python_imports(self):
        for name in ("codex-build.py", "remote-build.py"):
            with self.subTest(name=name):
                result = subprocess.run(
                    [sys.executable, str(ROOT / "scripts" / name), "--help"],
                    cwd=Path(tempfile.gettempdir()),
                    env=os.environ | {"PYTHONSAFEPATH": "1"},
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_legacy_app_hosted_selector_fails_before_a_native_run_is_queued(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copy2(ROOT / "justfile", root / "justfile")
            shutil.copy2(ROOT / ".xcode-version", root / ".xcode-version")
            (root / "scripts").mkdir()
            shutil.copy2(ROOT / "scripts/build-host", root / "scripts/build-host")
            shutil.copy2(ROOT / "scripts/maintainer_config.py", root / "scripts/maintainer_config.py")
            bin_dir = root / "bin"
            bin_dir.mkdir()
            python = bin_dir / "python3"
            python.write_text("#!/bin/sh\ntouch python3-called\n")
            python.chmod(0o755)
            result = subprocess.run(
                ["just", "core-test", "RemoteCoderTests/AccountIsolationTests"],
                cwd=root,
                env={
                    k: v for k, v in os.environ.items() if k not in ("BASH_ENV", "ENV")
                }
                | {
                    "HOME": str(root),
                    "ZDOTDIR": str(root),
                    "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                },
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "App-hosted selectors require just ios-simulator-test", result.stderr
            )
            self.assertFalse((root / "python3-called").exists())
