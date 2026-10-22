#!/usr/bin/env python3
"""Verify distributable app configuration, and verify that development installs carry no provider credentials."""

import argparse
import json
import sys
import zipfile
from pathlib import Path

PUBLIC_FIELDS = frozenset(
    {
        "codexWorkdir",
        "macMiniHostname",
        "macBookHostname",
        "codexGatewayPort",
        "googleMapsAPIKey",
    }
)
DEVELOPMENT_FIELDS = PUBLIC_FIELDS | {"codexGatewayAuthToken"}


def validate(data: bytes) -> None:
    check(data, PUBLIC_FIELDS, "release configuration contains non-public fields")


def validate_development(data: bytes) -> None:
    check(
        data,
        DEVELOPMENT_FIELDS,
        "development configuration contains fields the app no longer reads; speech"
        " runs through the gateway's llm-router relay. Remove",
    )


def check(data: bytes, allowed: frozenset[str], rejection: str) -> None:
    config = json.loads(data)
    if not isinstance(config, dict):
        raise TypeError("app configuration must be an object")
    forbidden = set(config) - allowed
    if forbidden:
        raise ValueError(rejection + ": " + ", ".join(sorted(forbidden)))
    if (
        type(config.get("codexGatewayPort", 8787)) is not int
        or not 1 <= config.get("codexGatewayPort", 8787) <= 65535
    ):
        raise ValueError("gateway port must be between 1 and 65535")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action", choices=("verify", "verify-ipa", "verify-development")
    )
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    if args.action == "verify":
        validate(args.path.read_bytes())
    elif args.action == "verify-development":
        validate_development(args.path.read_bytes())
        print("Development configuration verified: no speech-provider credentials.")
        return
    else:
        with zipfile.ZipFile(args.path) as archive:
            names = [
                name
                for name in archive.namelist()
                if name.startswith("Payload/")
                and name.endswith("/RemoteCoderLocalConfig.json")
            ]
            if not names:
                raise ValueError("IPA has no release configuration to verify")
            for name in names:
                if archive.getinfo(name).file_size > 64 * 1024:
                    raise ValueError("release configuration is oversized")
                validate(archive.read(name))
    print("Release configuration verified: no gateway or speech-provider credentials.")


if __name__ == "__main__":
    try:
        main()
    except (TypeError, ValueError, OSError, zipfile.BadZipFile) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
