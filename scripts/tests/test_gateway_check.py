import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location(
    "gateway_check", SCRIPTS / "gateway-check.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class GatewayEvidenceTests(unittest.TestCase):
    def test_changed_compiler_configuration_or_source_invalidates_evidence(self):
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(module.platform, "platform", return_value="test-host"),
        ):
            root = Path(temporary)
            provenance = root / "source.json"
            provenance.write_text(json.dumps({"sourceFingerprint": "first"}))
            env = {"CARGO_HOME": str(root), "CARGO_TARGET_DIR": str(root / "target")}
            with patch.object(
                module.subprocess, "check_output", return_value="compiler-1"
            ):
                original = module.input_key(provenance, env)
                (root / "config.toml").write_text(
                    '[build]\nrustflags=["-Copt-level=2"]\n'
                )
                self.assertNotEqual(original, module.input_key(provenance, env))
                (root / "config.toml").unlink()
                provenance.write_text(json.dumps({"sourceFingerprint": "second"}))
                self.assertNotEqual(original, module.input_key(provenance, env))
                provenance.write_text(json.dumps({"sourceFingerprint": "first"}))
            with patch.object(
                module.subprocess, "check_output", return_value="compiler-2"
            ):
                self.assertNotEqual(original, module.input_key(provenance, env))

    def test_forced_failure_removes_previous_success(self):
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(module.platform, "platform", return_value="test-host"),
        ):
            root = Path(temporary)
            cache = root / "gateway-check.json"
            cache.write_text(json.dumps({"inputKey": "same", "passedAt": 1}))
            with (
                patch.dict(
                    os.environ,
                    {"CARGO_TARGET_DIR": str(root), "RC_FORCE_CHECKS": "1"},
                    clear=True,
                ),
                patch.object(module, "input_key", return_value="same"),
                patch.object(module, "run_lanes", return_value=1),
            ):
                self.assertEqual(module.main(), 1)
                self.assertFalse(cache.exists())
