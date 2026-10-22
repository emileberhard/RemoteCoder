#!/usr/bin/env python3
"""Stamp development builds and verify the actual Xcode optimization settings."""

import argparse
import fcntl
import inspect
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_hosts import is_local
from maintainer_config import load as maintainer_config


def next_build_number(counter: Path, floor: int = 0) -> str:
    counter.parent.mkdir(parents=True, exist_ok=True)
    with counter.open("a+") as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        file.seek(0)
        count = max(int(file.read() or "0"), floor) + 1
        file.seek(0)
        file.truncate()
        file.write(str(count))
        file.flush()
        os.fsync(file.fileno())
    return f"{1 + count // 10000}.{count // 100 % 100}.{count % 100}"


def reserve_build_number(counter: Path) -> str:
    """One configured counter orders development builds from every compiler."""
    coordinator = maintainer_config().get("buildNumberCoordinatorHost", "local")
    if is_local(coordinator):
        return next_build_number(counter)
    try:
        floor = int(counter.read_text() or "0")
    except FileNotFoundError:
        floor = 0
    program = (
        "import fcntl, os\nfrom pathlib import Path\n"
        + inspect.getsource(next_build_number)
        + "\nprint(next_build_number(Path.home() / 'Library/Caches/RemoteCoder-Build/device-build-counter', "
        + str(floor) + "))\n"
    )
    try:
        reserved = subprocess.check_output(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
             "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
             coordinator, "python3 -c " + shlex.quote(program)],
            text=True, timeout=30, stderr=subprocess.PIPE,
        ).strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError(
            f"Cannot reserve the development build number on {coordinator}. Restore its SSH connection and retry; no local numbering fallback is used."
        ) from error
    match = re.fullmatch(r"([1-9][0-9]*)\.([0-9]{1,2})\.([0-9]{1,2})", reserved)
    if match is None:
        raise ValueError("The coordinator returned an invalid development build number")
    major, minor, patch = map(int, match.groups())
    count = (major - 1) * 10000 + minor * 100 + patch
    if count <= floor:
        raise ValueError("The coordinator development build number did not exceed the local migration floor")
    counter.parent.mkdir(parents=True, exist_ok=True)
    with counter.open("a+") as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        file.seek(0)
        remembered = max(int(file.read() or "0"), count)
        file.seek(0)
        file.truncate()
        file.write(str(remembered))
        file.flush()
        os.fsync(file.fileno())
    return reserved


def modified_setting(identity: dict) -> str:
    modified = identity["sourceModified"]
    if not isinstance(modified, bool):
        raise TypeError("Source snapshot sourceModified must be a boolean")
    return "true" if modified else "false"


def verify_settings(settings: list[dict], identity: dict, target: str) -> dict:
    targets = [
        entry["buildSettings"]
        for entry in settings
        if entry.get("target") == target
    ]
    if len(targets) != 1:
        raise ValueError(f"Expected exactly one {target} target in Xcode settings")
    settings = targets[0]
    expected = {
        "CONFIGURATION": identity["configuration"],
        "SWIFT_OPTIMIZATION_LEVEL": "-O" if identity["optimized"] else "-Onone",
        "SWIFT_COMPILATION_MODE": identity["compilationMode"],
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "CURRENT_PROJECT_VERSION": identity["buildNumber"],
        "RC_BUILD_ID": identity["buildId"],
        "RC_SOURCE_COMMIT": identity["sourceCommit"],
        "RC_SOURCE_MODIFIED": modified_setting(identity),
        "RC_SOURCE_FINGERPRINT": identity["sourceFingerprint"],
    }
    for name, value in expected.items():
        if settings.get(name) != value:
            raise ValueError(
                f"Build setting {name} did not match the recorded candidate"
            )
    identifier = settings.get("PRODUCT_BUNDLE_IDENTIFIER")
    if not isinstance(identifier, str) or not identifier:
        raise ValueError("Build settings contain no PRODUCT_BUNDLE_IDENTIFIER")
    return expected | {"PRODUCT_BUNDLE_IDENTIFIER": identifier}


def verify_bundle(info: dict, evidence: dict) -> None:
    identity = evidence["identity"]
    expected = {
        "CFBundleIdentifier": evidence["settings"]["PRODUCT_BUNDLE_IDENTIFIER"],
        "CFBundleVersion": identity["buildNumber"],
        "RemoteCoderBuildID": identity["buildId"],
        "RemoteCoderSourceCommit": identity["sourceCommit"],
        "RemoteCoderSourceModified": modified_setting(identity),
        "RemoteCoderSourceFingerprint": identity["sourceFingerprint"],
        "RemoteCoderBuildOptimization": evidence["settings"][
            "SWIFT_OPTIMIZATION_LEVEL"
        ],
    }
    for name, value in expected.items():
        if info.get(name) != value:
            raise ValueError(
                f"Built bundle {name} does not match verified build settings"
            )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare")
    prepare.add_argument("output", type=Path)
    mode = prepare.add_mutually_exclusive_group()
    mode.add_argument("--optimized", action="store_true")
    mode.add_argument("--incremental-optimized", action="store_true")
    mode.add_argument("--unoptimized", action="store_true")
    mode.add_argument("--release", action="store_true")
    verify = commands.add_parser("verify")
    verify.add_argument("identity", type=Path)
    verify.add_argument("settings", type=Path)
    verify.add_argument("output", type=Path)
    verify.add_argument("--target", required=True)
    arguments = parser.parse_args()
    os.umask(0o077)
    if arguments.command == "prepare":
        source_path = os.environ.get("RC_BUILD_PROVENANCE")
        if not source_path:
            raise SystemExit(
                "Device builds require the source snapshot's RC_BUILD_PROVENANCE"
            )
        source = json.loads(Path(source_path).read_text())
        identity = {
            key: source[key]
            for key in (
                "buildId",
                "sourceCommit",
                "sourceFingerprint",
                "sourceModified",
            )
        }
        modified_setting(identity)
        uuid.UUID(identity["buildId"])
        identity["configuration"] = "Release" if arguments.release else "Debug"
        identity["optimized"] = not arguments.unoptimized
        identity["compilationMode"] = (
            "wholemodule" if arguments.optimized or arguments.release else "singlefile"
        )
        identity["buildNumber"] = reserve_build_number(
            Path.home() / "Library/Caches/RemoteCoder-Build/device-build-counter"
        )
        arguments.output.write_text(json.dumps(identity, indent=2) + "\n")
        for name, value in {
            "CURRENT_PROJECT_VERSION": identity["buildNumber"],
            "RC_BUILD_ID": identity["buildId"],
            "RC_SOURCE_COMMIT": identity["sourceCommit"],
            "RC_SOURCE_MODIFIED": modified_setting(identity),
            "RC_SOURCE_FINGERPRINT": identity["sourceFingerprint"],
        }.items():
            print(f"{name}={value}")
    else:
        identity = json.loads(arguments.identity.read_text())
        evidence = {
            "identity": identity,
            "settings": verify_settings(
                json.loads(arguments.settings.read_text()), identity, arguments.target
            ),
        }
        arguments.output.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
