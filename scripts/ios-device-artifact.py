#!/usr/bin/env python3
"""Retain and reuse an exact, signed development app without requiring a phone."""

import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import UTC, datetime
from pathlib import Path

from build_artifacts import tree_digest
from build_support import atomic_json


def load_script(name, filename):
    spec = importlib.util.spec_from_file_location(
        name, Path(__file__).with_name(filename)
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


identity = load_script("device_build_identity", "device-build-identity.py")
installer = load_script("install_built_app", "install-built-app.py")


def inputs(source, optimized, compilation_mode):
    developer = os.environ["DEVELOPER_DIR"]
    return {
        "schemaVersion": 1,
        "source": {
            key: source[key]
            for key in ("sourceCommit", "sourceFingerprint", "sourceModified")
        },
        "optimized": optimized,
        "compilationMode": compilation_mode,
        "developerDirectory": developer,
        "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
        "privateConfigSHA256": hashlib.sha256(
            Path("RemoteCoder/Resources/RemoteCoderLocalConfig.json").read_bytes()
        ).hexdigest(),
        "signing": signing_inputs(),
        "environment": {
            key: os.environ.get(key)
            for key in (
                "COMPILATION_CACHE_ENABLE_CACHING_DEFAULT",
                "SWIFT_ENABLE_PREFIX_MAPPING",
                "SWIFT_ENABLE_PROJECT_PREFIX_MAPPING",
                "CompilationCachingCASPath",
            )
        },
    }


def signing_inputs():
    identities = subprocess.check_output(
        ["security", "find-identity", "-v", "-p", "codesigning"], text=True
    )
    profiles = {}
    for directory in (
        Path.home() / "Library/MobileDevice/Provisioning Profiles",
        Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
    ):
        for path in sorted(directory.glob("*")):
            if (
                path.suffix in {".mobileprovision", ".provisionprofile"}
                and path.is_file()
            ):
                profiles[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
    return {
        "identitiesSHA256": hashlib.sha256(identities.encode()).hexdigest(),
        "profiles": profiles,
        "selectors": {
            key: os.environ.get(key)
            for key in (
                "CODE_SIGN_IDENTITY",
                "PROVISIONING_PROFILE_SPECIFIER",
                "PROVISIONING_PROFILE",
                "CODE_SIGN_STYLE",
                "DEVELOPMENT_TEAM",
            )
        },
    }


def retire_artifacts(root, current):
    """The source lease owns this variant's completed candidates; retain two."""
    completed = []
    for path in root.iterdir():
        if (
            path.is_symlink()
            or not path.is_dir()
            or not re.fullmatch(r"[0-9a-f]{32}", path.name)
        ):
            continue
        descriptor = path / "artifact.json"
        if descriptor.is_symlink():
            continue
        try:
            value = json.loads(descriptor.read_text())
            if value["schemaVersion"] != 1 or value["buildId"] != path.name:
                continue
            if (
                Path(value["app"]).parent != path
                or Path(value["provenance"]).parent != path
            ):
                continue
            owned = {
                Path(value["app"]).name,
                "symbols",
                "source.json",
                "build-settings.json",
                "artifact.json",
            }
            direct = path / "direct-install-receipt.json"
            if direct.exists() or direct.is_symlink():
                if direct.is_symlink() or not direct.is_file():
                    continue
                proof = json.loads(direct.read_text())
                if (
                    proof.get("schemaVersion") != 1
                    or proof.get("sourceBuildId") != value["buildId"]
                    or proof.get("sourceAppSHA256") != value["appSHA256"]
                    or not all(
                        isinstance(proof.get(key), str) and proof[key]
                        for key in (
                            "deviceUDID",
                            "bundleIdentifier",
                            "version",
                            "build",
                            "directReceipt",
                        )
                    )
                    or not re.fullmatch(
                        r"[0-9a-f]{64}", proof.get("directReceiptSHA256", "")
                    )
                    or (
                        proof.get("deviceId") is not None
                        and type(proof["deviceId"]) is not int
                    )
                ):
                    continue
                owned.add("direct-install-receipt.json")
            managed = path / "mdm"
            if managed.exists() or managed.is_symlink():
                if managed.is_symlink() or not managed.is_dir():
                    continue
                files = {entry.name for entry in managed.iterdir()}
                required = {"RemoteCoder.ipa", "package-receipt.json"}
                if files not in (required, required | {"install-receipt.json"}):
                    continue
                if any(
                    entry.is_symlink() or not entry.is_file()
                    for entry in managed.iterdir()
                ):
                    continue
                packaged = json.loads((managed / "package-receipt.json").read_text())
                if (
                    packaged["sourceBuildId"] != value["buildId"]
                    or packaged["sourceAppSHA256"] != value["appSHA256"]
                    or packaged.get("transformationVersion") != 1
                    or not re.fullmatch(r"[0-9a-f]{64}", packaged.get("sha256", ""))
                ):
                    continue
                owned.add("mdm")
            if {entry.name for entry in path.iterdir()} != owned:
                continue
        except (OSError, ValueError, KeyError, TypeError):
            continue
        completed.append(path)
    previous = sorted(
        (path for path in completed if path != current),
        key=lambda path: (path / "artifact.json").stat().st_mtime,
        reverse=True,
    )
    for path in previous[1:]:
        shutil.rmtree(path)


def verify_profiles(app):
    profiles = [
        app / "embedded.mobileprovision",
        *(p / "embedded.mobileprovision" for p in app.glob("**/*.appex")),
    ]
    for profile in profiles:
        if not profile.is_file():
            raise ValueError(
                "Signed device artifact has no embedded provisioning profile"
            )
        content = subprocess.check_output(
            ["security", "cms", "-D", "-i", str(profile)], stderr=subprocess.DEVNULL
        )
        expiration = plistlib.loads(content)["ExpirationDate"]
        if expiration.replace(tzinfo=UTC) <= datetime.now(UTC):
            raise ValueError("Signed device artifact provisioning profile expired")
    with tempfile.TemporaryDirectory(prefix="device-signature-") as temporary:
        prefix = str(Path(temporary) / "certificate")
        subprocess.run(
            ["codesign", "-d", "--extract-certificates=" + prefix, str(app)],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [
                "openssl",
                "x509",
                "-inform",
                "DER",
                "-in",
                prefix + "0",
                "-checkend",
                "0",
                "-noout",
            ],
            check=True,
            capture_output=True,
        )


def validate(descriptor):
    app = Path(descriptor["app"])
    if tree_digest(app) != descriptor["appSHA256"]:
        raise ValueError("Signed device artifact contents changed")
    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(app)],
        check=True,
        capture_output=True,
    )
    verify_profiles(app)
    settings = json.loads(Path(descriptor["settings"]).read_text())
    source = json.loads(Path(descriptor["provenance"]).read_text())
    if source != descriptor["source"] or settings != descriptor["buildSettings"]:
        raise ValueError("Signed device artifact evidence changed")
    identity.verify_bundle(plistlib.loads((app / "Info.plist").read_bytes()), settings)
    for symbol in descriptor["symbols"]:
        if tree_digest(Path(symbol["path"])) != symbol["sha256"]:
            raise ValueError("Signed device artifact symbols changed")


def result(descriptor, source, reused, started):
    phases_path = Path(os.environ["RC_BUILD_PROVENANCE"]).parent / "ios-phases.json"
    phases = json.loads(phases_path.read_text()) if phases_path.exists() else {}
    value = descriptor | {
        "requestBuildId": source["buildId"],
        "reused": reused,
        "phasesSeconds": phases
        | {
            "artifactReuse" if reused else "artifactPublish": round(
                time.monotonic() - started, 3
            )
        },
    }
    destination = Path(os.environ["RC_BUILD_PROVENANCE"]).parent / "ios-artifact.json"
    atomic_json(destination, value)
    print(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("reuse", "publish", "validate", "phase"))
    parser.add_argument("--phase")
    parser.add_argument("--started", type=float)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--optimized", action="store_true")
    mode.add_argument("--incremental-optimized", action="store_true")
    mode.add_argument("--unoptimized", action="store_true")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--settings", type=Path)
    parser.add_argument("--artifact", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == "phase":
        path = Path(os.environ["RC_BUILD_PROVENANCE"]).parent / "ios-phases.json"
        phases = json.loads(path.read_text()) if path.exists() else {}
        phases[args.phase] = round(time.monotonic() - args.started, 3)
        atomic_json(path, phases)
        return
    if args.command == "validate":
        validate(json.loads(args.artifact.read_text()))
        return
    if os.environ.get("RC_INSTALL_SOURCE_LEASED") != "1":
        raise ValueError(
            "Device artifact reuse/publication requires the installation source lease"
        )
    started = time.monotonic()
    provenance = Path(os.environ["RC_BUILD_PROVENANCE"])
    source = json.loads(provenance.read_text())
    compilation_mode = "wholemodule" if args.optimized else "singlefile"
    key = inputs(source, not args.unoptimized, compilation_mode)
    derived = Path(os.environ["RC_DERIVED_DATA"])
    pointer = derived / "device-artifact.json"
    if args.command == "reuse":
        try:
            descriptor = json.loads(pointer.read_text())
            if descriptor["inputs"] != key:
                raise ValueError("Build inputs changed")
            expected = derived / "device-artifacts" / descriptor["buildId"]
            if (
                expected.parent.is_symlink()
                or expected.is_symlink()
                or Path(descriptor["app"]).parent != expected
            ):
                raise ValueError("Device artifact is outside its owned variant")
            validate(descriptor)
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            print(f"Device artifact cache miss: {error}", file=sys.stderr)
            raise SystemExit(3)
        result(descriptor, source, True, started)
        return
    evidence = json.loads(args.settings.read_text())
    expected_mode = {
        "SWIFT_OPTIMIZATION_LEVEL": "-O" if not args.unoptimized else "-Onone",
        "SWIFT_COMPILATION_MODE": compilation_mode,
    }
    if any(
        evidence["settings"].get(name) != value for name, value in expected_mode.items()
    ):
        raise ValueError(
            "Artifact optimization mode does not match verified Xcode settings"
        )
    identity.verify_bundle(
        plistlib.loads((args.app / "Info.plist").read_bytes()), evidence
    )
    verify_profiles(args.app)
    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(args.app)],
        check=True,
        capture_output=True,
    )
    root = derived / "device-artifacts"
    if root.is_symlink():
        raise ValueError("Device artifact directory must not be a symlink")
    root.mkdir(parents=True, exist_ok=True)
    destination = root / source["buildId"]
    # No existing immutable candidate is ever replaced or repurposed.
    if destination.exists():
        raise ValueError("Device artifact build identity already exists")
    with tempfile.TemporaryDirectory(prefix=".publish-", dir=root) as temporary:
        staged = Path(temporary)
        shutil.copytree(args.app, staged / args.app.name, symlinks=True)
        installer.retain_symbols(args.app, args.app.parent, staged / "symbols")
        shutil.copy2(provenance, staged / "source.json")
        shutil.copy2(args.settings, staged / "build-settings.json")
        descriptor = {
            "schemaVersion": 1,
            "buildId": source["buildId"],
            "inputs": key,
            "app": str(destination / args.app.name),
            "appSHA256": tree_digest(staged / args.app.name),
            "source": source,
            "provenance": str(destination / "source.json"),
            "settings": str(destination / "build-settings.json"),
            "buildSettings": evidence,
            "symbols": [
                {
                    "path": str(destination / "symbols"),
                    "sha256": tree_digest(staged / "symbols"),
                }
            ],
        }
        atomic_json(staged / "artifact.json", descriptor)
        staged.rename(destination)
    derived.mkdir(parents=True, exist_ok=True)
    atomic_json(pointer, descriptor)
    retire_artifacts(root, destination)
    result(descriptor, source, False, started)


if __name__ == "__main__":
    main()
