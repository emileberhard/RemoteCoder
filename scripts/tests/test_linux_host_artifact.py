import importlib.util
import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location(
    "linux_host", SCRIPTS / "build-linux-host.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LinuxArchiveTests(unittest.TestCase):
    def test_approved_read_only_and_executable_modes_survive_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "host.tar.gz"
            with tarfile.open(archive, "w:gz") as stream:
                for name, mode in [
                    ("approval", 0o444),
                    ("private-cli", 0o500),
                    ("cli", 0o755),
                ]:
                    entry = tarfile.TarInfo("remote-coder-host/" + name)
                    entry.mode = mode
                    entry.size = 7
                    stream.addfile(entry, io.BytesIO(b"payload"))
            extracted = module.unpack(archive, root / "extracted")
            for name, mode in [
                ("approval", 0o444),
                ("private-cli", 0o500),
                ("cli", 0o755),
            ]:
                self.assertEqual((extracted / name).stat().st_mode & 0o777, mode)
                self.assertEqual((extracted / name).read_bytes(), b"payload")

    def test_system_bubblewrap_dependency_and_absent_fallback_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            resources = root / "codex-resources"
            resources.mkdir()
            manifest = root / "codex-package.json"
            manifest.write_text("{}")
            with self.assertRaises(ValueError):
                module.verify_codex_sandbox(root)
            manifest.write_text(json.dumps({"linuxSandbox": "system"}))
            module.verify_codex_sandbox(root)
            (resources / "bwrap").symlink_to("missing")
            with self.assertRaises(ValueError):
                module.verify_codex_sandbox(root)

    def test_unsafe_entries_are_refused_without_writing_their_payload(self):
        for name, kind, target, mode in [
            ("../escaped", tarfile.REGTYPE, "", 0o644),
            ("remote-coder-host/../escaped", tarfile.REGTYPE, "", 0o644),
            ("remote-coder-host//file", tarfile.REGTYPE, "", 0o644),
            ("remote-coder-host/link", tarfile.SYMTYPE, "../../escaped", 0o755),
            ("remote-coder-host/device", tarfile.CHRTYPE, "", 0o644),
            ("remote-coder-host/writable", tarfile.REGTYPE, "", 0o666),
        ]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = root / "host.tar.gz"
                with tarfile.open(archive, "w:gz") as stream:
                    entry = tarfile.TarInfo(name)
                    entry.type = kind
                    entry.mode = mode
                    entry.linkname = target
                    entry.size = 7 if kind == tarfile.REGTYPE else 0
                    stream.addfile(
                        entry, io.BytesIO(b"payload") if entry.size else None
                    )
                destination = root / "extract"
                destination.mkdir()
                with self.assertRaises((ValueError, tarfile.TarError)):
                    module.unpack(archive, destination)
                self.assertEqual(list(destination.iterdir()), [])
                self.assertFalse((root / "escaped").exists())

    def test_valid_package_links_survive_and_duplicate_members_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "host.tar.gz"
            with tarfile.open(archive, "w:gz") as stream:
                binary = tarfile.TarInfo("remote-coder-host/bin/codex")
                binary.size = 7
                binary.mode = 0o755
                stream.addfile(binary, io.BytesIO(b"payload"))
                link = tarfile.TarInfo("remote-coder-host/codex")
                link.type = tarfile.SYMTYPE
                link.mode = 0o777
                link.linkname = "bin/codex"
                stream.addfile(link)
            extracted = module.unpack(archive, root / "extract")
            self.assertEqual((extracted / "codex").read_bytes(), b"payload")
            with tarfile.open(archive, "w:gz") as stream:
                stream.addfile(binary, io.BytesIO(b"payload"))
                stream.addfile(binary, io.BytesIO(b"changed"))
            with self.assertRaisesRegex(ValueError, "duplicate"):
                module.unpack(archive, root / "duplicate")


if __name__ == "__main__":
    unittest.main()
