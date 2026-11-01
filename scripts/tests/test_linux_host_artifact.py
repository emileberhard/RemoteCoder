import importlib.util
import io
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("linux_host", SCRIPTS / "build-linux-host.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LinuxArchiveTests(unittest.TestCase):
    def test_unsafe_entries_are_refused_without_writing_their_payload(self):
        for name, kind, target in [
            ("../escaped", tarfile.REGTYPE, ""),
            ("remote-coder-host/../escaped", tarfile.REGTYPE, ""),
            ("remote-coder-host//file", tarfile.REGTYPE, ""),
            ("remote-coder-host/link", tarfile.SYMTYPE, "../../escaped"),
            ("remote-coder-host/device", tarfile.CHRTYPE, ""),
        ]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = root / "host.tar.gz"
                with tarfile.open(archive, "w:gz") as stream:
                    entry = tarfile.TarInfo(name)
                    entry.type = kind
                    entry.linkname = target
                    entry.size = 7 if kind == tarfile.REGTYPE else 0
                    stream.addfile(entry, io.BytesIO(b"payload") if entry.size else None)
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
