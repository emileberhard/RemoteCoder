import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "protocol-fixtures"
MANIFEST = "fixture-manifest.json"


def manifest() -> list[dict]:
    return json.loads((FIXTURES / MANIFEST).read_text())["fixtures"]


class ProtocolFixtureManifestTests(unittest.TestCase):
    def test_manifest_lists_exactly_the_fixture_files(self) -> None:
        on_disk = {str(path.relative_to(FIXTURES)) for path in FIXTURES.rglob("*.json")} - {MANIFEST}
        listed = [entry["path"] for entry in manifest()]
        self.assertEqual(len(listed), len(set(listed)))
        self.assertEqual(set(listed), on_disk)

    def test_every_fixture_is_valid_json_and_names_its_contract_and_consumers(self) -> None:
        for entry in manifest():
            with self.subTest(path=entry["path"]):
                json.loads((FIXTURES / entry["path"]).read_text())
                self.assertTrue(entry["contract"].strip())
                self.assertTrue(entry["consumers"])

    def test_every_listed_consumer_reads_its_fixture(self) -> None:
        for entry in manifest():
            stem = Path(entry["path"]).stem
            for consumer in entry["consumers"]:
                with self.subTest(path=entry["path"], consumer=consumer):
                    source = (ROOT / consumer).read_text()
                    self.assertTrue(
                        f"protocol-fixtures/{entry['path']}" in source
                        or f'"{entry["path"]}"' in source
                        or f'"{stem}"' in source,
                        f"{consumer} does not read {entry['path']}",
                    )


if __name__ == "__main__":
    unittest.main()
