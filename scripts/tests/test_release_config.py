import importlib.util
import json
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "release_config", Path(__file__).resolve().parents[1] / "release-config.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseConfigurationTests(unittest.TestCase):
    def test_public_client_configuration_is_allowed(self):
        module.validate(
            json.dumps(
                {"googleMapsAPIKey": "restricted-client-key", "codexGatewayPort": 8787}
            ).encode()
        )

    def test_tracked_release_configuration_is_public(self):
        module.validate((Path(__file__).resolve().parents[2] / "Config/release-config.json").read_bytes())

    def test_private_and_unknown_fields_fail_closed(self):
        for key in (
            "codexGatewayAuthToken",
            "openAIAPIKey",
            "azureSpeechAPIKey",
            "futureProviderKey",
        ):
            with (
                self.subTest(key=key),
                self.assertRaises((TypeError, ValueError)) as failure,
            ):
                module.validate(json.dumps({key: "synthetic-secret-value"}).encode())
            self.assertNotIn("synthetic-secret-value", str(failure.exception))

    def test_development_configuration_allows_only_the_gateway_token_beyond_public_fields(self):
        module.validate_development(
            json.dumps(
                {"codexGatewayAuthToken": "synthetic-token", "googleMapsAPIKey": "k"}
            ).encode()
        )
        speech_fields = (
            "openAIAPIKey",
            "elevenLabsAPIKey",
            "geminiAPIKey",
            "assemblyAIAPIKey",
            "azureSpeechEndpoint",
            "azureSpeechAPIKey",
        )
        with self.assertRaises(ValueError) as failure:
            module.validate_development(
                json.dumps(dict.fromkeys(speech_fields, "synthetic-secret-value")).encode()
            )
        message = str(failure.exception)
        self.assertNotIn("synthetic-secret-value", message)
        for field in speech_fields:
            self.assertIn(field, message)

    def test_invalid_structure_and_port_fail(self):
        for value in ([], {"codexGatewayPort": 0}, {"codexGatewayPort": 65536}):
            with self.subTest(value=value), self.assertRaises((TypeError, ValueError)):
                module.validate(json.dumps(value).encode())
