import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_artifacts import reuse_installed, tree_digest, valid_package


class PackageIdentityTests(unittest.TestCase):
    def test_resources_executability_and_extra_files_participate_in_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            package = Path(temporary)
            (package / "codex-package.json").write_text("{}")
            binary = package / "codex"
            binary.write_bytes(b"binary")
            digest = tree_digest(package)
            self.assertTrue(valid_package(package, digest))
            binary.chmod(0o755)
            self.assertFalse(valid_package(package, digest))
            digest = tree_digest(package)
            (package / "resource").write_bytes(b"resource")
            self.assertFalse(valid_package(package, digest))

    def test_links_cannot_hide_untracked_external_package_contents(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "package"
            package.mkdir()
            (root / "outside").write_bytes(b"unowned")
            (package / "resource").symlink_to("../outside")
            with self.assertRaises(ValueError):
                tree_digest(package)

    def test_installed_reuse_returns_an_independent_exact_package_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            installed = root / ".codex/packages/standalone/release"
            (installed / "bin").mkdir(parents=True)
            (installed / "codex-package.json").write_text("{}")
            (installed / "bin/codex").write_bytes(b"approved")
            expected = tree_digest(installed)
            approvals = installed.parent / "approvals"
            approvals.mkdir()
            (approvals / "approved-binary.json").write_text('{"codexForkCommit":"approved"}')
            self.assertEqual(tree_digest(installed), expected)
            (installed / "codex").symlink_to("bin/codex")
            (installed.parent / "current").symlink_to("release")
            with patch("build_artifacts.Path.home", return_value=root):
                self.assertTrue(reuse_installed(root / "returned", expected))
                (installed / "bin/codex").write_bytes(b"next release")
                self.assertTrue(valid_package(root / "returned", expected))
                self.assertFalse(reuse_installed(root / "mismatch", expected))
                self.assertFalse((root / "mismatch").exists())
