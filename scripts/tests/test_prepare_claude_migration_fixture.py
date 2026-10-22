import hashlib
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "prepare_claude_migration_fixture",
    Path(__file__).resolve().parents[1] / "prepare-claude-migration-fixture.py",
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ClaudeMigrationFixtureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name).resolve()
        self.home = self.parent / "source"
        self.projects = self.home / ".claude" / "projects"
        self.projects.mkdir(parents=True)

    def prepare(self):
        return module.prepare_fixture(self.home, self.parent)

    def test_links_preserve_topology_without_copying_their_targets(self):
        workspace = self.projects / "workspace"
        workspace.mkdir()
        transcript = workspace / "thread.jsonl"
        transcript.write_text("history\n")
        (self.projects / "directory-link").symlink_to("workspace")
        (self.projects / "file-link").symlink_to("workspace/thread.jsonl")
        (self.projects / "dangling").symlink_to("missing")
        (self.projects / "absolute-link").symlink_to(workspace)
        external = self.parent / "external"
        external.mkdir()
        (external / "must-not-be-copied").write_text("outside source")
        (self.projects / "external-link").symlink_to(external)
        (self.home / ".claude" / "skills").symlink_to(self.home / "configs" / "skills")
        debug = self.home / ".claude" / "debug"
        debug.mkdir()
        (debug / "latest").symlink_to(debug / "not-copied.log")
        (debug / "not-copied.log").write_text("private debug output")

        manifest = self.prepare()
        fixture = Path(manifest["fixture"])
        for name, expected in {
            "directory-link": "workspace", "file-link": "workspace/thread.jsonl",
            "dangling": "missing", "absolute-link": str(fixture / ".claude/projects/workspace"),
            "external-link": str(external),
        }.items():
            with self.subTest(link=name):
                copied = fixture / ".claude/projects" / name
                self.assertTrue(copied.is_symlink())
                self.assertEqual(os.readlink(copied), expected)
                entry = manifest["entries"][str(copied.relative_to(fixture))]
                self.assertEqual(entry["type"], "symlink")
                self.assertEqual(entry["target"], expected)
        self.assertEqual(os.readlink(fixture / ".claude/skills"), str(fixture / "configs/skills"))
        self.assertEqual(os.readlink(fixture / ".claude/debug/latest"), str(fixture / ".claude/debug/not-copied.log"))
        self.assertFalse((fixture / ".claude/debug/not-copied.log").exists())
        self.assertNotIn(".claude/projects/external-link/must-not-be-copied", manifest["entries"])
        self.assertEqual(transcript.read_text(), "history\n")

    def test_profiles_state_and_hashes_are_copied_without_credentials(self):
        payload = b"history" * 200000
        (self.projects / "thread.jsonl").write_bytes(payload)
        for relative in (
            ".claude/.credentials.json", ".claude/projects/.credentials.json",
            ".claude/settings.json", ".claude/debug/raw.log", ".claude.json",
            ".remote-coder/llm-router-key", ".remote-coder/llm-router.key",
            ".remote-coder/speech-credentials.json",
            ".rca/account/claude/.credentials.json", ".rca/account/handoff-backups/credentials.json",
        ):
            target = self.home / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("synthetic credential or excluded data")
        for relative in (
            ".remote-coder/account-enrollments.json", ".remote-coder/conversation-handoffs.json",
            ".remote-coder/claude-profile-migration.json", ".remote-coder/claude-profile-conflicts/history.jsonl",
            ".rca/account/claude/memory/MEMORY.md", ".rca/account/state/questions/session.json",
            ".rca/account/handoff-backups/transcript.jsonl",
        ):
            target = self.home / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("fixture data")
        with patch.object(module, "clone_file", return_value=False):
            manifest = self.prepare()
        fixture = Path(manifest["fixture"])
        self.assertEqual(manifest["profiles"], ["account"])
        entry = manifest["entries"][".claude/projects/thread.jsonl"]
        self.assertEqual(entry["sha256"], hashlib.sha256(payload).hexdigest())
        self.assertEqual(entry["bytes"], len(payload))
        self.assertEqual((fixture / ".claude/projects/thread.jsonl").read_bytes(), payload)
        self.assertEqual(json.loads((fixture / ".fixture-manifest.json").read_text()), manifest)
        for path in fixture.rglob("*"):
            self.assertNotIn(path.name, module.CREDENTIAL_NAMES)
        self.assertFalse((fixture / ".claude/settings.json").exists())
        self.assertFalse((fixture / ".claude/debug/raw.log").exists())
        self.assertTrue((fixture / ".rca/account/state/questions/session.json").is_file())
        self.assertTrue((fixture / ".remote-coder/claude-profile-migration.json").is_file())
        self.assertTrue((fixture / ".remote-coder/claude-profile-conflicts/history.jsonl").is_file())
        self.assertEqual(fixture.stat().st_mode & 0o777, 0o700)
        self.assertEqual((fixture / ".fixture-manifest.json").stat().st_mode & 0o777, 0o600)

    def test_debug_directory_link_is_preserved_without_inspecting_logs(self):
        external = self.parent / "external-debug"
        external.mkdir()
        (external / "latest").write_text("must not read")
        (self.home / ".claude/debug").symlink_to(external)
        manifest = self.prepare()
        fixture = Path(manifest["fixture"])
        self.assertTrue((fixture / ".claude/debug").is_symlink())
        self.assertEqual(os.readlink(fixture / ".claude/debug"), str(external))
        self.assertNotIn(".claude/debug/latest", manifest["entries"])

    def test_fixtures_are_fresh_and_cannot_be_created_inside_source_home(self):
        first, second = self.prepare(), self.prepare()
        self.assertNotEqual(first["fixture"], second["fixture"])
        for result in (first, second):
            self.assertNotEqual(result["fixture"], str(self.home))
            self.assertTrue((Path(result["fixture"]) / ".migration-fixture").is_file())
        with self.assertRaisesRegex(ValueError, "outside the source home"):
            module.prepare_fixture(self.home, self.home)

    def test_atomic_clone_stays_valid_when_source_appends_after_capture(self):
        original = b"captured history\n"
        transcript = self.projects / "thread.jsonl"
        transcript.write_bytes(original)
        clone = module.clone_file

        def append_after_clone(descriptor, target):
            if not clone(descriptor, target):
                self.skipTest("Atomic file cloning is unavailable on this filesystem")
            with transcript.open("ab") as stream:
                stream.write(b"streamed later\n")
            return True

        with patch.object(module, "clone_file", side_effect=append_after_clone):
            manifest = self.prepare()
        copied = Path(manifest["fixture"]) / ".claude/projects/thread.jsonl"
        self.assertEqual(copied.read_bytes(), original)
        self.assertEqual(transcript.read_bytes(), original + b"streamed later\n")
        entry = manifest["entries"][".claude/projects/thread.jsonl"]
        self.assertEqual(entry["bytes"], len(original))
        self.assertEqual(entry["sha256"], hashlib.sha256(original).hexdigest())

    def test_source_parent_links_are_not_traversed(self):
        external = self.parent / "external-state"
        external.mkdir()
        (external / "account-enrollments.json").write_text("must not read")
        (self.home / ".remote-coder").symlink_to(external)
        with self.assertRaises(OSError):
            self.prepare()
        self.assertEqual(list(self.parent.glob("claude-migration-fixture-*")), [])

    def test_nonregular_entries_fail_without_opening_or_blocking(self):
        os.mkfifo(self.projects / "fifo")
        with self.assertRaisesRegex(RuntimeError, "Unsupported fixture entry.*fifo"):
            self.prepare()
        self.assertEqual(list(self.parent.glob("claude-migration-fixture-*")), [])
