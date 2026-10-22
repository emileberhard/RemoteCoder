#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import secrets
import shlex

parser = argparse.ArgumentParser(description="Create a private gateway environment with a random operator token")
parser.add_argument("--codex", type=Path, required=True)
parser.add_argument("--env-file", type=Path, default=Path.home() / ".remote-coder/codex-gateway.env")
args = parser.parse_args()
codex = args.codex.expanduser().resolve(strict=True)
if not codex.is_file() or not os.access(codex, os.X_OK):
    parser.error("--codex must name the managed Codex executable")
if any(character in str(codex) for character in "'\r\n"):
    parser.error("--codex path must not contain single quotes or line breaks")
path = args.env_file.expanduser().absolute()
path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
values = {
    "RC_CODEX_GATEWAY_BIND_HOST": "127.0.0.1",
    "RC_CODEX_GATEWAY_PORT": "8787",
    "RC_CODEX_GATEWAY_CODEX_PATH": str(codex),
    "RC_CODEX_GATEWAY_AUTH_TOKEN": secrets.token_hex(32),
    "RC_CODEX_GATEWAY_PUSH_BROKER_ENABLED": "false",
}
try:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
except FileExistsError:
    parser.error("The gateway environment already exists; refusing to replace it")
with os.fdopen(descriptor, "w") as handle:
    for key, value in values.items():
        handle.write(f"{key}={shlex.quote(value)}\n")
    handle.flush()
    os.fsync(handle.fileno())
print(json.dumps({"status": "created", "envFile": str(path), "restartPerformed": False}))
