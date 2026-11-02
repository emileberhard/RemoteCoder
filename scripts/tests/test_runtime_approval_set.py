import copy
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
ADOPTION = Path("host-daemon-rs/src/accounts/codex_migration")


class AtomicApprovalTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.git("init", "-q")
        self.git(
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "--allow-empty",
            "-qm",
            "previous",
        )
        previous = self.git("rev-parse", "HEAD")
        self.git(
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "--allow-empty",
            "-qm",
            "common",
        )
        self.protocol = self.git("rev-parse", "HEAD")
        self.path = self.root / "docs/codex/compatibility.json"
        self.path.parent.mkdir(parents=True)
        compatibility = json.loads(
            (SCRIPTS.parent / "docs/codex/compatibility.json").read_text()
        )
        self.targets = ["aarch64-apple-darwin", "x86_64-unknown-linux-musl"]
        initial = next(iter(compatibility["runtimeTargets"].values()))
        compatibility["runtimeTargets"] = {
            target: {**initial, "sourceCommit": previous} for target in self.targets
        }
        compatibility["protocolSourceCommit"] = previous
        self.path.write_text(json.dumps(compatibility))
        pins = self.root / ADOPTION / "schema.json"
        pins.parent.mkdir(parents=True)
        pins.write_bytes((SCRIPTS.parent / ADOPTION / "schema.json").read_bytes())
        self.receipts = [
            {
                "schema_version": 1,
                "approval": {
                    "version": "9.9.0",
                    "target": target,
                    "source_commit": self.protocol,
                    "codex_sha256": "1" * 64,
                    "code_mode_host_sha256": "2" * 64,
                },
                "package_sha256": "3" * 64,
                "adoption_pins_sha256": hashlib.sha256(pins.read_bytes()).hexdigest(),
                "adoption_migrations": {
                    name: 1 for name in json.loads(pins.read_text())
                },
            }
            for target in self.targets
        ]

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-C", str(self.source), *args], text=True
        ).strip()

    def apply(self, receipts):
        paths = []
        for index, receipt in enumerate(receipts):
            path = self.root / f"evaluation-{index}.json"
            path.write_text(json.dumps(receipt))
            paths.append(path)
        command = [
            "uv",
            "run",
            "--script",
            str(SCRIPTS / "codex-runtime-approval"),
            "apply-set",
            "--repo-root",
            str(self.root),
            "--protocol-source-commit",
            self.protocol,
            "--source-dir",
            str(self.source),
            "--json",
        ]
        for path in paths:
            command.extend(["--receipt", str(path)])
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        payload = json.loads(result.stdout)
        if result.returncode:
            self.assertFalse(payload["ok"])
            raise RuntimeError(payload["error"])
        return payload["compatibility"]

    def test_complete_native_set_moves_the_common_pin_and_all_targets_together(self):
        actual = self.apply(self.receipts)
        self.assertEqual(actual, json.loads(self.path.read_text()))
        self.assertEqual(actual["protocolSourceCommit"], self.protocol)
        self.assertEqual(actual["codexCliVersion"], "9.9.0")
        self.assertEqual(set(actual["runtimeTargets"]), set(self.targets))
        self.assertTrue(
            all(
                record["sourceCommit"] == self.protocol
                for record in actual["runtimeTargets"].values()
            )
        )

    def test_partial_duplicate_or_disagreeing_evaluations_leave_the_record_untouched(
        self,
    ):
        cases = [self.receipts[:1], [self.receipts[0], self.receipts[0]]]
        for field, value in [("version", "9.8.0"), ("source_commit", "f" * 40)]:
            receipts = copy.deepcopy(self.receipts)
            receipts[1]["approval"][field] = value
            cases.append(receipts)
        for field, value in [
            ("adoption_pins_sha256", "0" * 64),
            ("adoption_migrations", {}),
        ]:
            receipts = copy.deepcopy(self.receipts)
            receipts[1][field] = value
            cases.append(receipts)
        before = self.path.read_bytes()
        for receipts in cases:
            with self.subTest(receipts=receipts), self.assertRaises(RuntimeError):
                self.apply(receipts)
            self.assertEqual(self.path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
