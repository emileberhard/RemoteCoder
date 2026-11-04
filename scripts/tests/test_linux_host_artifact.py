import importlib.util
import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location(
    "linux_host", SCRIPTS / "build-linux-host.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LinuxArchiveTests(unittest.TestCase):
    def test_build_from_group_writable_inputs_passes_its_archive_verifier(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            (source / "LICENSES").mkdir(parents=True)
            (source / "host-daemon-rs/systemd").mkdir(parents=True)
            for name in [
                "LICENSE",
                "THIRD_PARTY_NOTICES.md",
                "LICENSES/notice",
                "host-daemon-rs/systemd/remote-coder-gateway.service",
            ]:
                path = source / name
                path.write_text("source payload")
                path.chmod(0o664)
            (source / "LICENSES").chmod(0o775)
            package = root / "codex"
            (package / "bin").mkdir(parents=True)
            (package / "codex-package.json").write_text(
                json.dumps({"linuxSandbox": "system"})
            )
            (package / "bin/codex").write_bytes(b"codex payload")
            (package / "bin/codex").chmod(0o775)
            claude = root / "claude"
            claude.write_bytes(b"claude payload")
            provenance = root / "provenance.json"
            claude_pin = {
                "version": "2.1.311",
                "linuxX64": {
                    "sha256": module.sha256(claude),
                    "manifestSigningFingerprint": "signature",
                },
            }
            provenance.write_text(
                json.dumps(
                    {
                        "version": claude_pin["version"],
                        "sha256": claude_pin["linuxX64"]["sha256"],
                        "manifestSignature": {"fingerprint": "signature"},
                    }
                )
            )
            codex_pin = {
                "sourceCommit": "b" * 40,
                "runtimePackageSHA256": module.tree_digest(package),
                "runtimeHashes": {"bin/codex": module.sha256(package / "bin/codex")},
            }
            (source / "docs/codex").mkdir(parents=True)
            (source / "docs/codex/compatibility.json").write_text(
                json.dumps(
                    {
                        "codexCliVersion": "0.166.0-alpha.6",
                    }
                )
            )
            target = root / "target"
            gateway = (
                target / module.GATEWAY_TARGET / "release/remote-coder-codex-gateway"
            )
            gateway.parent.mkdir(parents=True)
            gateway.write_bytes(b"gateway payload")
            commit = "a" * 40
            identity = {"version": "0.0.0", "commit": commit, "modified": False}
            args = SimpleNamespace(
                version="0.0.0",
                commit=commit,
                codex_package=package,
                claude=claude,
                claude_provenance=provenance,
                target_dir=target,
                output=root / "host.tar.gz",
            )

            def output(command, **options):
                return commit if command[0] == "git" else json.dumps(identity)

            with (
                patch.object(module, "ROOT", source),
                patch.object(module, "pins", return_value=(codex_pin, claude_pin)),
                patch.object(module.platform, "system", return_value="Linux"),
                patch.object(module.platform, "machine", return_value="x86_64"),
                patch.object(module.subprocess, "run"),
                patch.object(module.subprocess, "check_output", side_effect=output),
            ):
                expected = module.build(args)
                extracted = module.unpack(args.output, root / "extracted")
                self.assertEqual(
                    module.verify_tree(extracted, args.version, commit), expected
                )
            self.assertEqual((extracted / "LICENSE").stat().st_mode & 0o777, 0o644)
            self.assertEqual(
                (extracted / "runtime/codex/bin/codex").stat().st_mode & 0o777, 0o755
            )
            self.assertEqual(
                module.tree_digest(extracted / "runtime/codex"),
                codex_pin["runtimePackageSHA256"],
            )
            self.assertEqual((source / "LICENSE").stat().st_mode & 0o777, 0o664)
            self.assertEqual((package / "bin/codex").stat().st_mode & 0o777, 0o775)

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
