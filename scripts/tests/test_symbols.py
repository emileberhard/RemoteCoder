import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import symbols


class SymbolFileTests(unittest.TestCase):
    def test_retained_symbols_are_found_by_uuid_after_the_build_is_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dwarf = "symbols/RemoteCoder.app.dSYM/Contents/Resources/DWARF/RemoteCoder"
            old = root / symbols.BUILD_RUN_ROOT / "old" / dwarf
            current = root / symbols.DSYM_ROOT / "testflight-ios-3.66.10-3066010" / dwarf
            local = root / symbols.BUILD_WORKTREE_ROOT / "source/ios/derived-debug/device-artifacts/build" / dwarf
            for path in (old, current, local):
                path.parent.mkdir(parents=True)
                path.write_bytes(b"fixture debug information")
            identities = {
                old: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                current: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                local: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            }

            def dwarfdump(command, **kwargs):
                return subprocess.CompletedProcess(
                    command, 0,
                    stdout="\n".join(f"UUID: {identities[Path(path)]} (arm64) {path}" for path in command[3:]),
                )

            with (
                patch.object(Path, "home", return_value=root),
                patch.object(symbols.subprocess, "run", side_effect=dwarfdump),
            ):
                found = symbols.symbol_files([str(root / "removed-product/RemoteCoder")], [])
            self.assertEqual(found[identities[old]], symbols.SymbolFile(old, "arm64"))
            self.assertEqual(found[identities[current]], symbols.SymbolFile(current, "arm64"))
            self.assertEqual(found[identities[local]], symbols.SymbolFile(local, "arm64"))

    def test_atos_keeps_inlined_names_and_drops_unknown_addresses(self):
        separator = symbols.ATOS_SEPARATOR
        output = (
            f"inner (in RemoteCoder) (Parser.swift:10)\nouter (in RemoteCoder) (Chat.swift:3)\n{separator}\n"
            f"0x100004000 (in RemoteCoder)\n{separator}\n"
        )
        with patch.object(symbols.subprocess, "run",
                          return_value=subprocess.CompletedProcess([], 0, stdout=output)) as run:
            names = symbols.atos(symbols.SymbolFile(Path("/x/RemoteCoder"), "arm64"), 0x100000000,
                                 [0x100003000, 0x100004000])
        self.assertEqual(names, [("inner (in RemoteCoder) (Parser.swift:10)", "outer (in RemoteCoder) (Chat.swift:3)"), ()])
        self.assertIn("0x100000000", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
