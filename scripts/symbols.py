import subprocess
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

DSYM_ROOT = "Library/Logs/remote-coder/deployments"
BUILD_RUN_ROOT = "Library/Caches/RemoteCoder-Build/runs"
BUILD_WORKTREE_ROOT = "Library/Caches/RemoteCoder-Build/worktrees"
DEVICE_SUPPORT_ROOT = "Library/Developer/Xcode/iOS DeviceSupport"
ATOS_SEPARATOR = "\x1e"


@dataclass(frozen=True)
class SymbolFile:
    path: Path
    arch: str


def symbol_files(binary_paths: Iterable[str], extra: Iterable[Path]) -> dict[str, SymbolFile]:
    home = Path.home()
    device_support = home / DEVICE_SUPPORT_ROOT
    roots = [*device_support.glob("*/Symbols"), *device_support.glob("*/*/Symbols")]
    candidates = [*(home / DSYM_ROOT).glob("*/symbols/*.dSYM/Contents/Resources/DWARF/*")]
    candidates += (home / BUILD_RUN_ROOT).glob("*/symbols/*.dSYM/Contents/Resources/DWARF/*")
    candidates += (home / BUILD_WORKTREE_ROOT).glob("*/ios/derived*/device-artifacts/*/symbols/*.dSYM/Contents/Resources/DWARF/*")
    candidates += [path for path in extra if path.is_file()]
    for binary_path in binary_paths:
        local = Path(binary_path)
        candidates += [local] if local.is_file() else []
        candidates += [path for root in roots if (path := root / binary_path.lstrip("/")).is_file()]
    if not candidates:
        return {}
    output = subprocess.run(
        ["xcrun", "dwarfdump", "--uuid", *map(str, candidates)],
        stdout=subprocess.PIPE, text=True, check=False,
    ).stdout
    files: dict[str, SymbolFile] = {}
    for line in output.splitlines():
        _, uuid, arch, path = line.split(" ", 3)
        files.setdefault(uuid, SymbolFile(Path(path), arch.strip("()")))
    return files


def atos(file: SymbolFile, load_address: int, addresses: list[int]) -> list[tuple[str, ...]]:
    output = subprocess.run(
        ["xcrun", "atos", "-i", "-d", ATOS_SEPARATOR, "-o", str(file.path), "-arch", file.arch,
         "-l", hex(load_address)],
        input="\n".join(map(hex, addresses)), stdout=subprocess.PIPE, text=True, check=True,
    ).stdout
    blocks = output.split(f"{ATOS_SEPARATOR}\n")[:-1]
    if len(blocks) != len(addresses):
        raise RuntimeError(f"atos returned {len(blocks)} results for {len(addresses)} addresses in {file.path}")
    return [
        tuple(line for line in block.splitlines() if is_symbol(line))
        for block in blocks
    ]


def is_symbol(name: str) -> bool:
    return bool(name) and not name.startswith(("0x", "<"))
