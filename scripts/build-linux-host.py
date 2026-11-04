#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path, PurePosixPath

from build_artifacts import tree_digest

ROOT = Path(__file__).resolve().parent.parent
CODEX_TARGET = "x86_64-unknown-linux-musl"
GATEWAY_TARGET = "x86_64-unknown-linux-gnu"
NAME = "remote-coder-host"
MAXIMUM_BYTES = 2 << 30
MAXIMUM_ENTRIES = 50_000


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def pins():
    codex = json.loads((ROOT / "docs/codex/compatibility.json").read_text())
    claude = json.loads((ROOT / "docs/claude/compatibility.json").read_text())
    return codex["runtimeTargets"][CODEX_TARGET], claude


def approval_record(codex):
    compatibility = json.loads((ROOT / "docs/codex/compatibility.json").read_text())
    return {
        "codexCliVersion": compatibility["codexCliVersion"],
        "codexForkCommit": codex["sourceCommit"],
        "runtimeHashes": codex["runtimeHashes"],
    }


def verify_claude_provenance(path, claude):
    provenance = json.loads(path.read_text())
    if (
        provenance.get("version") != claude["version"]
        or provenance.get("sha256") != claude["linuxX64"]["sha256"]
        or provenance.get("manifestSignature", {}).get("fingerprint")
        != claude["linuxX64"]["manifestSigningFingerprint"]
    ):
        raise ValueError(
            "Linux Claude provenance differs from reviewed vendor identity"
        )


def verify_codex_sandbox(package):
    manifest = json.loads((package / "codex-package.json").read_text())
    fallback = package / "codex-resources/bwrap"
    if manifest.get("linuxSandbox") != "system":
        raise ValueError(
            "Linux Codex package must explicitly require system bubblewrap"
        )
    try:
        fallback.lstat()
    except FileNotFoundError:
        return
    raise ValueError("Linux Codex package must not bundle a bubblewrap fallback")


def inventory(root):
    records = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if relative == "manifest.json" or path.is_dir() and not path.is_symlink():
            continue
        if path.is_symlink():
            path.resolve(strict=True).relative_to(root.resolve())
            records[relative] = {"type": "link", "target": str(path.readlink())}
        elif path.is_file():
            records[relative] = {
                "type": "file",
                "sha256": sha256(path),
                "mode": path.stat().st_mode & 0o777,
            }
        else:
            raise ValueError(f"unsupported bundle entry {relative}")
    return records


def verify_tree(root, version, commit):
    manifest_path = root / "manifest.json"
    if manifest_path.is_symlink() or manifest_path.stat().st_size > 16 << 20:
        raise ValueError("Linux artifact manifest is not a bounded regular file")
    manifest = json.loads(manifest_path.read_text())
    codex, claude = pins()
    expected = {
        "schemaVersion": 1,
        "version": version,
        "sourceCommit": commit,
        "gatewayTarget": GATEWAY_TARGET,
        "codexTarget": CODEX_TARGET,
        "codexSourceCommit": codex["sourceCommit"],
        "codexPackageSHA256": codex["runtimePackageSHA256"],
        "claudeVersion": claude["version"],
        "claudeSHA256": claude["linuxX64"]["sha256"],
    }
    if {key: value for key, value in manifest.items() if key != "files"} != expected:
        raise ValueError(
            "Linux artifact identity differs from the admitted release and runtime pins"
        )
    if manifest.get("files") != inventory(root):
        raise ValueError("Linux artifact file inventory differs")
    if tree_digest(root / "runtime/codex") != codex["runtimePackageSHA256"]:
        raise ValueError("Linux Codex package tree differs from approval")
    verify_codex_sandbox(root / "runtime/codex")
    if sha256(root / "runtime/claude/claude") != claude["linuxX64"]["sha256"]:
        raise ValueError("Linux Claude executable differs from approval")
    approval = (
        root
        / "runtime/approvals"
        / (sha256(root / "runtime/codex/codex-package.json") + ".json")
    )
    if (
        approval.is_symlink()
        or not approval.is_file()
        or approval.stat().st_mode & 0o777 != 0o444
        or json.loads(approval.read_text()) != approval_record(codex)
    ):
        raise ValueError(
            "Linux package approval differs from the selected flat runtime approval"
        )
    if set((root / "runtime/approvals").iterdir()) != {approval}:
        raise ValueError("Linux artifact contains unexpected package approvals")
    verify_claude_provenance(root / "runtime/claude/provenance.json", claude)
    for required in [
        "bin/remote-coder-codex-gateway",
        "runtime/claude/claude",
        "systemd/remote-coder-gateway.service",
    ]:
        if required not in manifest["files"]:
            raise ValueError(f"Linux artifact is missing {required}")
    for executable in ["bin/remote-coder-codex-gateway", "runtime/claude/claude"]:
        if not (root / executable).stat().st_mode & 0o111:
            raise ValueError(f"Linux artifact executable cannot run: {executable}")
    return manifest


def unpack(archive, temporary):
    with tarfile.open(archive, "r:gz") as stream:
        entries = []
        names = set()
        total = 0
        for entry in stream:
            parts = PurePosixPath(entry.name).parts
            if (
                not parts
                or parts[0] != NAME
                or any(part in {"..", "."} for part in parts)
                or entry.name.rstrip("/") != "/".join(parts)
                or entry.name in names
            ):
                raise ValueError("unsafe or duplicate Linux archive path")
            if (
                not (entry.isfile() or entry.isdir() or entry.issym())
                or entry.mode & ~0o777
                or not entry.issym()
                and entry.mode & 0o022
            ):
                raise ValueError("unsupported Linux archive entry")
            total += entry.size
            names.add(entry.name)
            entries.append(entry)
            if len(entries) > MAXIMUM_ENTRIES or total > MAXIMUM_BYTES:
                raise ValueError("Linux archive exceeds its extraction bound")
            tarfile.data_filter(entry, temporary)

        def release_filter(member, destination):
            filtered = tarfile.data_filter(member, destination)
            return filtered.replace(mode=member.mode) if member.isfile() else filtered

        stream.extractall(temporary, members=entries, filter=release_filter)
    return temporary / NAME


def verify(args):
    parent = (
        args.destination.parent if args.command == "extract" else args.archive.parent
    )
    parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="linux-host-verify-", dir=parent
    ) as temporary:
        root = unpack(args.archive, Path(temporary))
        manifest = verify_tree(root, args.version, args.commit)
        if args.command == "extract":
            if args.destination.exists() or args.destination.is_symlink():
                raise ValueError("Linux extraction destination already exists")
            root.rename(args.destination)
    return manifest


def build(args):
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise ValueError("Linux host artifacts must build natively on x86_64 Linux")
    if (
        subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True
        ).strip()
        != args.commit
    ):
        raise ValueError("Linux builder source differs from the admitted commit")
    subprocess.run(
        ["git", "-C", str(ROOT), "diff", "--exit-code", "HEAD", "--"], check=True
    )
    codex, claude = pins()
    if tree_digest(args.codex_package) != codex["runtimePackageSHA256"]:
        raise ValueError("Linux Codex seed differs from approval")
    verify_codex_sandbox(args.codex_package)
    if sha256(args.claude) != claude["linuxX64"]["sha256"]:
        raise ValueError("Linux Claude seed differs from approval")
    verify_claude_provenance(args.claude_provenance, claude)
    environment = os.environ | {
        "RC_RELEASE_VERSION": args.version,
        "RC_SOURCE_COMMIT": args.commit,
        "RC_SOURCE_MODIFIED": "false",
    }
    subprocess.run(
        [
            "cargo",
            "build",
            "--locked",
            "--release",
            "--target",
            GATEWAY_TARGET,
            "--target-dir",
            str(args.target_dir),
            "--manifest-path",
            str(ROOT / "host-daemon-rs/Cargo.toml"),
        ],
        env=environment,
        check=True,
    )
    gateway = args.target_dir / GATEWAY_TARGET / "release/remote-coder-codex-gateway"
    identity = json.loads(
        subprocess.check_output([str(gateway), "--version"], text=True)
    )
    if (
        identity["version"] != args.version
        or identity["commit"] != args.commit
        or identity["modified"] is not False
    ):
        raise ValueError("Linux gateway binary reports a different build identity")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="linux-host-build-", dir=args.output.parent
    ) as temporary:
        root = Path(temporary) / NAME
        (root / "bin").mkdir(parents=True)
        (root / "runtime/claude").mkdir(parents=True)
        (root / "systemd").mkdir()
        shutil.copy2(gateway, root / "bin" / gateway.name)
        (root / "bin" / gateway.name).chmod(0o755)
        shutil.copytree(args.codex_package, root / "runtime/codex", symlinks=True)
        (root / "runtime/approvals").mkdir()
        approval = (
            root
            / "runtime/approvals"
            / (sha256(root / "runtime/codex/codex-package.json") + ".json")
        )
        approval.write_text(json.dumps(approval_record(codex), indent=2) + "\n")
        approval.chmod(0o444)
        shutil.copy2(args.claude, root / "runtime/claude/claude")
        (root / "runtime/claude/claude").chmod(0o755)
        shutil.copy2(args.claude_provenance, root / "runtime/claude/provenance.json")
        (root / "runtime/claude/provenance.json").chmod(0o644)
        shutil.copy2(
            ROOT / "host-daemon-rs/systemd/remote-coder-gateway.service",
            root / "systemd",
        )
        shutil.copytree(ROOT / "LICENSES", root / "licenses")
        shutil.copy2(ROOT / "LICENSE", root / "LICENSE")
        shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", root / "THIRD_PARTY_NOTICES.md")
        for path in root.rglob("*"):
            if not path.is_symlink():
                path.chmod(path.stat().st_mode & 0o755)
        manifest = {
            "schemaVersion": 1,
            "version": args.version,
            "sourceCommit": args.commit,
            "gatewayTarget": GATEWAY_TARGET,
            "codexTarget": CODEX_TARGET,
            "codexSourceCommit": codex["sourceCommit"],
            "codexPackageSHA256": codex["runtimePackageSHA256"],
            "claudeVersion": claude["version"],
            "claudeSHA256": claude["linuxX64"]["sha256"],
            "files": inventory(root),
        }
        (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        verify_tree(root, args.version, args.commit)
        with tarfile.open(args.output, "x:gz", compresslevel=3) as archive:
            archive.add(root, arcname=NAME)
    return manifest


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(
        description="Build and verify an immutable native Linux host bundle; callers own release admission."
    )
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ["build", "verify", "extract"]:
        current = commands.add_parser(command)
        current.add_argument("--version", required=True)
        current.add_argument("--commit", required=True)
        if command == "build":
            for field in [
                "codex-package",
                "claude",
                "claude-provenance",
                "target-dir",
                "output",
            ]:
                current.add_argument("--" + field, type=Path, required=True)
        else:
            current.add_argument("--archive", type=Path, required=True)
            if command == "extract":
                current.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(
        r"(?:0|[1-9][0-9]{0,2})\.(?:0|[1-9][0-9]{0,2})\.(?:0|[1-9][0-9]{0,2})",
        args.version,
    ) or not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        parser.error("a stable release version and exact source commit are required")
    try:
        print(
            json.dumps(
                build(args) if args.command == "build" else verify(args), sort_keys=True
            )
        )
    except (
        OSError,
        ValueError,
        KeyError,
        tarfile.TarError,
        subprocess.SubprocessError,
    ) as error:
        parser.exit(1, f"Linux host artifact refused: {error}\n")


if __name__ == "__main__":
    main()
