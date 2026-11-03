import importlib.util
import json
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import plistlib
import select
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("web_deploy", Path(__file__).with_name("deploy.py"))
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


class ReleaseTests(unittest.TestCase):
    def test_legacy_release_keeps_its_runtime_after_source_disappears(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            releases = root / "releases"
            releases.mkdir()
            old = releases / "legacy"
            (old / "dist").mkdir(parents=True)
            bun = root / "bun"
            bun.write_text("#!/bin/sh\necho 1.4.3\n")
            bun.chmod(0o755)
            (old / "service.plist").write_bytes(plistlib.dumps({"ProgramArguments": [str(bun), "service.js"]}))
            (old / "dist/deployment.json").write_text(json.dumps({"revision": "old", "bun": "1.4.3"}))
            with patch.object(deploy, "ROOT", root), patch.object(deploy, "RELEASES", releases):
                retained = deploy.snapshot_legacy(old)
                bun.unlink()
                self.assertEqual(subprocess.check_output([deploy.runtime(retained), "--version"], text=True).strip(), "1.4.3")
                (retained / "bun").write_text("changed")
                with self.assertRaisesRegex(RuntimeError, "does not match"):
                    deploy.runtime(retained)

    def test_release_identity_changes_with_runtime_and_service_inputs(self):
        identity = deploy.release_identity("commit", "1.4.4", "bytes", b"service")
        for inputs in [("commit2", "1.4.4", "bytes", b"service"), ("commit", "1.4.5", "bytes", b"service"), ("commit", "1.4.4", "other", b"service"), ("commit", "1.4.4", "bytes", b"other")]:
            self.assertNotEqual(identity, deploy.release_identity(*inputs))


class StageTests(unittest.TestCase):
    def test_deploy_stages_with_retained_bun_without_touching_service(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            repo = base / "repo"
            scripts = repo / "web-client/scripts"
            scripts.mkdir(parents=True)
            (scripts / "deploy.py").write_text("fixture")
            (repo / "THIRD_PARTY_NOTICES.md").write_text("fixture")
            (repo / "LICENSES").mkdir()
            (repo / "LICENSES/license").write_text("fixture")
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"], check=True)
            bun = base / "bun"
            bun.write_text("""#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
if args == ['--version']:
    print('1.4.4')
else:
    with open(os.environ['STAGE_TEST_LOG'], 'a') as output:
        output.write(sys.argv[0] + ' ' + args[0] + '\\n')
    if args[0] == 'scripts/build.ts':
        pathlib.Path('dist').mkdir()
        pathlib.Path('dist/index.html').write_text('fixture')
    elif args[0] == 'build':
        pathlib.Path(args[args.index('--outfile') + 1]).write_text('fixture')
""")
            bun.chmod(0o755)
            log = base / "calls"
            root = base / "web"
            releases = root / "releases"
            current = releases / "legacy"
            (current / "dist").mkdir(parents=True)
            old_bun = base / "old-bun"
            old_bun.write_text("#!/bin/sh\necho 1.4.3\n")
            old_bun.chmod(0o755)
            (current / "service.js").write_text("old service")
            (current / "dist/deployment.json").write_text(json.dumps({"revision": "old", "bun": "1.4.3"}))
            (current / "service.plist").write_bytes(plistlib.dumps({"ProgramArguments": [str(old_bun), "old-service"]}))
            (root / "current").symlink_to(current)
            service = base / "service.plist"
            service.write_bytes(plistlib.dumps({"EnvironmentVariables": {}}))
            settings = {"host": "fixture-host", "bunPath": str(bun), "bunVersion": "1.4.4"}
            output = io.StringIO()
            with patch.object(deploy, "ROOT", root), patch.object(deploy, "RELEASES", releases), patch.object(deploy, "WEB", settings), patch.object(deploy, "SERVICE_PLIST", service), patch.object(deploy, "__file__", str(scripts / "deploy.py")), patch.object(deploy.socket, "gethostname", return_value="fixture-host"), patch.object(deploy, "candidate") as smoke, patch.dict(os.environ, {"STAGE_TEST_LOG": str(log)}), patch.object(sys, "argv", ["deploy.py", "deploy"]), redirect_stdout(output):
                exit_code = deploy.main()
            self.assertEqual(exit_code, 2)
            result = json.loads(output.getvalue().splitlines()[-1])
            self.assertEqual(result["status"], "staged")
            self.assertEqual(result["activation"], "pending")
            self.assertEqual((root / "current").resolve(), current)
            staged = (root / "staged").resolve()
            prior = (root / "staged-previous").resolve()
            old_bun.unlink()
            self.assertEqual(subprocess.check_output([prior / "bun", "--version"], text=True).strip(), "1.4.3")
            definition = plistlib.loads((staged / "service.plist").read_bytes())
            self.assertEqual(definition["ProgramArguments"], [str(staged / "bun"), str(staged / "service.js")])
            self.assertIn(" scripts/build.ts", log.read_text())
            self.assertTrue(all("/.build-" in line for line in log.read_text().splitlines()))
            smoke.assert_called_once()
            self.assertFalse(list(root.glob(".build-*")))

    def test_budget_counts_releases_and_staging_and_preserves_pins(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            releases = root / "releases"
            pinned = releases / "pinned"
            pinned.mkdir(parents=True)
            (pinned / "data").write_bytes(b"1234")
            (root / "current").symlink_to(pinned)
            staging = root / ".build-test"
            staging.mkdir()
            (staging / "data").write_bytes(b"5678")
            with patch.object(deploy, "ROOT", root), patch.object(deploy, "RELEASES", releases), patch.object(deploy, "MAX_TOTAL_BYTES", 7):
                with self.assertRaisesRegex(RuntimeError, "budget"):
                    deploy.prune()
            self.assertTrue(pinned.exists())

    def test_staging_process_stops_after_controller_group_termination(self):
        controller = subprocess.Popen(
            [sys.executable, "-u", "-c", """
import subprocess, sys
child = subprocess.Popen([sys.executable, sys.argv[1], '30', sys.executable, '-u', '-c', "import time; print('ready', flush=True); time.sleep(30)"], stdin=subprocess.PIPE, start_new_session=True)
sys.stdin.read()
""", str(deploy.WORKER)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            ready, _, _ = select.select([controller.stdout], [], [], 5)
            self.assertTrue(ready, "staging child did not start")
            self.assertEqual(controller.stdout.readline().strip(), b"ready")
            os.killpg(controller.pid, signal.SIGTERM)
            controller.wait(timeout=5)
            ready, _, _ = select.select([controller.stdout], [], [], 10)
            self.assertTrue(ready, "staging child remained running after controller termination")
            self.assertEqual(os.read(controller.stdout.fileno(), 1), b"")
        finally:
            if controller.poll() is None:
                os.killpg(controller.pid, signal.SIGKILL)
                controller.wait(timeout=5)
            controller.stdin.close()
            controller.stdout.close()

    def test_staging_process_has_its_own_deadline(self):
        with tempfile.TemporaryFile() as lock:
            with self.assertRaises(subprocess.CalledProcessError):
                deploy.staged_run([sys.executable, "-c", "import time; time.sleep(30)"], lock, 0.1, stderr=subprocess.DEVNULL)

    def test_rollback_refuses_before_any_mutation(self):
        with patch.object(sys, "argv", ["deploy.py", "rollback"]):
            with self.assertRaisesRegex(RuntimeError, "call-safe admission fencing"):
                deploy.main()


if __name__ == "__main__":
    unittest.main()
