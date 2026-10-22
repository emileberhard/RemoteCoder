#!/usr/bin/env python3
"""Prepare and verify the Navigation SDK key without logging credentials."""

import argparse
import json
import os
import subprocess
from pathlib import Path
import sys
import tempfile
import zipfile


CONFIG_NAME = "RemoteCoderLocalConfig.json"
KEY_FIELD = "googleMapsAPIKey"


def read_config(path: Path) -> dict:
    config = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise ValueError("App configuration must be a JSON object.")
    return config


def maps_key(config: dict) -> str | None:
    value = config.get(KEY_FIELD)
    if value is None or isinstance(value, str) and not value.strip():
        return None
    if (
        not isinstance(value, str)
        or not value.strip()
        or value.strip() == "required-for-live-navigation"
    ):
        raise ValueError(
            "Missing Google Maps iOS key. Set REMOTE_CODER_GOOGLE_MAPS_API_KEY "
            "(or GOOGLE_MAPS_IOS_API_KEY) to the iOS-restricted Navigation SDK key."
        )
    return value.strip()


def sync(path: Path) -> None:
    config = read_config(path) if path.exists() else {}
    value = os.environ.get("REMOTE_CODER_GOOGLE_MAPS_API_KEY") or os.environ.get(
        "GOOGLE_MAPS_IOS_API_KEY"
    )
    source = Path.home() / "configs/shared-env.sh"
    if value is None and source.is_file():
        value = subprocess.check_output(
            ["bash", "--noprofile", "--norc", "-c", 'source "$1" >/dev/null; printf %s "${REMOTE_CODER_GOOGLE_MAPS_API_KEY:-${GOOGLE_MAPS_IOS_API_KEY:-}}"', "maps-config", str(source)],
            text=True,
        ).strip() or None
    if value is not None:
        config[KEY_FIELD] = value
    key = maps_key(config)
    if key is None:
        config.pop(KEY_FIELD, None)
    else:
        config[KEY_FIELD] = key
    path.parent.mkdir(parents=True, exist_ok=True)
    file = tempfile.NamedTemporaryFile(
        mode="w", dir=path.parent, delete=False, encoding="utf-8"
    )
    temporary = Path(file.name)
    try:
        with file:
            json.dump(config, file, indent=2)
            file.write("\n")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    print("Google Maps iOS key configured." if key else "Navigation is disabled; no Google Maps key configured.")


def verify(path: Path, app: Path | None, ipa: Path | None) -> None:
    expected = maps_key(read_config(path))
    if app is not None:
        bundled = read_config(app / CONFIG_NAME)
    elif ipa is not None:
        with zipfile.ZipFile(ipa) as archive:
            bundled = json.loads(archive.read(f"Payload/RemoteCoder.app/{CONFIG_NAME}"))
        if not isinstance(bundled, dict):
            raise ValueError("Bundled app configuration must be a JSON object.")
    else:
        print("Google Maps iOS key preflight passed.")
        return
    if maps_key(bundled) != expected:
        raise ValueError(
            "Bundled Google Maps iOS key does not match the build configuration."
        )
    print("Verified Google Maps iOS key in built app.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    sync_parser = commands.add_parser("sync")
    sync_parser.add_argument("config", type=Path)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("config", type=Path)
    artifact = verify_parser.add_mutually_exclusive_group()
    artifact.add_argument("--app", type=Path)
    artifact.add_argument("--ipa", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "sync":
            sync(args.config)
        else:
            verify(args.config, args.app, args.ipa)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f"Google Maps configuration failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
