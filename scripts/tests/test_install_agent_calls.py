import importlib.machinery
import importlib.util
import json
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch


class InstallAgentCallsTests(unittest.TestCase):
    def test_delivery_configuration_uses_the_discovered_wss_listener_without_persisting_the_pin(self):
        source = Path(__file__).resolve().parents[1] / "install-agent-calls"
        loader = importlib.machinery.SourceFileLoader("install_agent_calls_fixture", str(source))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        discovery = []
        configured = []

        def command(arguments, **kwargs):
            output = ""
            if arguments[:2] == ["tailscale", "status"]:
                output = json.dumps({"Self": {"DNSName": "origin.fixture.ts.net.", "HostName": "gateway-primary"}})
            elif "-c" in arguments:
                discovery.append(arguments[-3:])
                output = json.dumps({"url": "wss://origin.fixture.ts.net:9789/ws", "workerHash": "a" * 64})
            elif arguments[-1] == "--version":
                output = json.dumps({"workerHash": "a" * 64})
            elif "install-call-worker" in arguments:
                output = json.dumps({"workerHash": "a" * 64,
                                     "workerPath": "/fixture/call-workers/" + "a" * 64 + "/dev-tools/agent-call"})
            elif arguments[-1] == "configure-call-delivery":
                configured.append(json.loads(kwargs["input"]))
                output = json.dumps({"deliveryConfig": "/fixture/gateway/versions/pair/call-delivery.json"})
            return subprocess.CompletedProcess(arguments, 0, output)

        with TemporaryDirectory() as directory:
            home = Path(directory)
            with (patch.object(module.socket, "gethostname", return_value="gateway-primary"),
                  patch.object(module.Path, "home", return_value=home),
                  patch.object(module.subprocess, "run", side_effect=command),
                  patch("sys.argv", [str(source), "--origin-host", "gateway-primary", "--worker-host", "carrier-host", "--worker-config", "/fixture/carrier.json"])):
                module.main()
            self.assertFalse((home / ".remote-coder/call-delivery.json").exists())
            delivery = configured[0]
        self.assertEqual(delivery["workerHost"], "carrier-host")
        self.assertEqual(delivery["workerConfigPath"], "/fixture/carrier.json")
        self.assertEqual(delivery["originGatewayUrl"], "wss://origin.fixture.ts.net:9789/ws")
        self.assertEqual(delivery["workerPath"], "/fixture/call-workers/" + "a" * 64 + "/dev-tools/agent-call")
        self.assertEqual(discovery[0][:2], ["origin.fixture.ts.net", "gateway-primary"])
        self.assertNotIn("tlsIdentity", delivery)
        self.assertNotIn("bearer", delivery)
