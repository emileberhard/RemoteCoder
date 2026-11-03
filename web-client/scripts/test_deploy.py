import importlib.util
import json
import os
from pathlib import Path
import plistlib
import socket
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


class BridgeFenceTests(unittest.TestCase):
    def setUp(self):
        self.server = subprocess.Popen([sys.executable, "-u", "-c", '''
import socket
server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen()
print(server.getsockname()[1], flush=True)
while True:
    client, _ = server.accept()
    with client:
        client.sendall(b"ready")
        while data := client.recv(1024):
            client.sendall(data)
'''], stdout=subprocess.PIPE, text=True)
        self.port = int(self.server.stdout.readline())
        self.real_run = deploy.run
        self.patches = [patch.object(deploy, "PORT", self.port), patch.object(deploy, "job_loaded", return_value=True), patch.object(deploy, "run", side_effect=self.run_command)]
        for item in self.patches:
            item.start()

    def run_command(self, *args, **kwargs):
        if args[:2] == ("launchctl", "print"):
            return subprocess.CompletedProcess(args, 0, stdout=f"pid = {os.getpid()}\n")
        return self.real_run(*args, **kwargs)

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.server.terminate()
        self.server.wait(timeout=5)
        self.server.stdout.close()

    def test_fence_prevents_admission_until_released(self):
        with deploy.idle_bridge():
            with socket.create_connection(("127.0.0.1", self.port), timeout=1) as client:
                client.settimeout(0.1)
                with self.assertRaises(TimeoutError):
                    client.recv(5)
        with socket.create_connection(("127.0.0.1", self.port), timeout=1) as client:
            self.assertEqual(client.recv(5), b"ready")

    def test_fence_resumes_after_deployer_is_killed(self):
        controller = subprocess.Popen(
            [sys.executable, "-u", "-c", """
import importlib.util, os, subprocess, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('deploy', sys.argv[1])
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)
deploy.PORT = int(sys.argv[2])
deploy.job_loaded = lambda: True
original = deploy.run
def run(*args, **kwargs):
    if args[:2] == ('launchctl', 'print'):
        return subprocess.CompletedProcess(args, 0, stdout='pid = ' + sys.argv[3] + '\\n')
    return original(*args, **kwargs)
deploy.run = run
with deploy.idle_bridge():
    print('held', flush=True)
    sys.stdin.read()
""", str(Path(__file__).with_name("deploy.py")), str(self.port), str(os.getpid())],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )
        try:
            self.assertEqual(controller.stdout.readline().strip(), "held")
            controller.kill()
            controller.wait(timeout=5)
            with socket.create_connection(("127.0.0.1", self.port), timeout=5) as client:
                client.settimeout(5)
                self.assertEqual(client.recv(5), b"ready")
        finally:
            if controller.poll() is None:
                controller.kill()
                controller.wait(timeout=5)
            controller.stdin.close()
            controller.stdout.close()

    def test_unowned_listener_refuses_activation(self):
        with patch.object(deploy, "job_loaded", return_value=False):
            with self.assertRaises(deploy.BridgeBusy):
                deploy.activate(Path("unused"))
        with socket.create_connection(("127.0.0.1", self.port), timeout=1) as client:
            self.assertEqual(client.recv(5), b"ready")

    def test_active_connection_refuses_and_resumes(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=1) as client:
            self.assertEqual(client.recv(5), b"ready")
            with self.assertRaises(deploy.BridgeBusy):
                with deploy.idle_bridge():
                    self.fail("active connection was admitted")
            client.sendall(b"alive")
            self.assertEqual(client.recv(5), b"alive")


if __name__ == "__main__":
    unittest.main()
