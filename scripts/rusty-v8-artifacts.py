#!/usr/bin/env python3
import argparse
import hashlib
import shlex
import subprocess
import sys
import urllib.request
from pathlib import Path

PROFILE = "ptrcomp_sandbox_release"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def download(url: str, destination: Path) -> None:
    partial = destination.with_name(destination.name + ".partial")
    with urllib.request.urlopen(url, timeout=120) as response, partial.open("wb") as output:
        while chunk := response.read(1 << 20):
            output.write(chunk)
    partial.replace(destination)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Fetch and verify the Codex-built rusty_v8 artifacts a Codex source tree pins, "
        "then print the Cargo environment exports that select them."
    )
    parser.add_argument("--codex-repo", type=Path, required=True)
    parser.add_argument("--target", default="aarch64-apple-darwin")
    parser.add_argument("--cache-dir", type=Path, required=True)
    args = parser.parse_args()

    repo = args.codex_repo.resolve()
    version = subprocess.run(
        [sys.executable, str(repo / ".github/scripts/rusty_v8_bazel.py"), "resolved-v8-crate-version"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    trusted_manifest = repo / f"third_party/v8/rusty_v8_{version.replace('.', '_')}_release_manifests.sha256"

    archive_name = f"librusty_v8_{PROFILE}_{args.target}.a.gz"
    binding_name = f"src_binding_{PROFILE}_{args.target}.rs"
    checksums_name = f"rusty_v8_{PROFILE}_{args.target}.sha256"
    base_url = f"https://github.com/openai/codex/releases/download/rusty-v8-v{version}"

    directory = args.cache_dir.resolve() / version / args.target
    directory.mkdir(parents=True, exist_ok=True)

    expected_manifest = next(
        (line.split()[0] for line in trusted_manifest.read_text().splitlines() if line.endswith(f"  {checksums_name}")),
        None,
    )
    if expected_manifest is None:
        raise SystemExit(f"{trusted_manifest} does not list {checksums_name}")

    checksums_path = directory / checksums_name
    if not checksums_path.exists() or sha256(checksums_path) != expected_manifest:
        download(f"{base_url}/{checksums_name}", checksums_path)
    if sha256(checksums_path) != expected_manifest:
        raise SystemExit(f"Checksum mismatch for {checksums_name}")

    expected = {}
    for line in checksums_path.read_text().replace("\r", "").splitlines():
        digest, name = line.split(maxsplit=1)
        expected[name.lstrip("*")] = digest
    if set(expected) != {archive_name, binding_name}:
        raise SystemExit(f"{checksums_name} must list exactly {archive_name} and {binding_name}")

    for name, digest in expected.items():
        path = directory / name
        if not path.exists() or sha256(path) != digest:
            download(f"{base_url}/{name}", path)
        if sha256(path) != digest:
            raise SystemExit(f"Checksum mismatch for {name}")

    print(f"export RUSTY_V8_ARCHIVE={shlex.quote(str(directory / archive_name))}")
    print(f"export RUSTY_V8_SRC_BINDING_PATH={shlex.quote(str(directory / binding_name))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
