#!/usr/bin/env python3
"""Run deterministic gateway gates, reusing a verified identical worker input."""

import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

from concurrent_lanes import run_lanes

ROOT = Path(__file__).resolve().parents[1]
TOOLING = (
    ("scripts", ["just", "gateway-script-check"]),
    ("pythonTests", ["just", "scripts-test-local"]),
    ("devToolsTests", ["just", "dev-tools-test-local"]),
    ("agentCallTests", ["just", "agent-calls-test-local"]),
)
CARGO = (
    (
        "format",
        ["cargo", "fmt", "--manifest-path", "host-daemon-rs/Cargo.toml", "--check"],
    ),
    (
        "clippy",
        [
            "cargo",
            "clippy",
            "--manifest-path",
            "host-daemon-rs/Cargo.toml",
            "--locked",
            "--all-targets",
            "--all-features",
            "--",
            "-D",
            "warnings",
        ],
    ),
    (
        "rustTests",
        ["cargo", "test", "--manifest-path", "host-daemon-rs/Cargo.toml", "--locked"],
    ),
)


def tool_identities(environment):
    identities = {}
    for name in ("just", "git", "bash", "zsh", "plutil", "uv"):
        executable = shutil.which(name, path=environment.get("PATH"))
        if executable is None:
            raise ValueError(f"Required gateway check tool is unavailable: {name}")
        path = Path(executable).resolve()
        identities[name] = {
            "path": str(path),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }
    return identities


def input_key(provenance, environment):
    # Only a worker-verified immutable snapshot can produce reusable evidence.
    if not provenance or not environment.get("CARGO_TARGET_DIR"):
        return None
    manifest = json.loads(Path(provenance).read_text())
    cargo_home = Path(environment.get("CARGO_HOME", str(Path.home() / ".cargo")))
    configuration = []
    for name in ("config", "config.toml"):
        path = cargo_home / name
        configuration.append(
            hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
        )
    compiler_environment = {
        key: value
        for key, value in environment.items()
        if key.startswith(("CARGO_", "RUST", "SCCACHE_"))
        or key
        in (
            "DEVELOPER_DIR",
            "SDKROOT",
            "PATH",
            "CC",
            "CXX",
            "CFLAGS",
            "CXXFLAGS",
            "LDFLAGS",
            "RC_RELEASE_VERSION",
            "RC_SOURCE_COMMIT",
            "RC_SOURCE_MODIFIED",
        )
    }
    payload = {
        "source": manifest["sourceFingerprint"],
        "tools": tool_identities(environment),
        "commands": {"tooling": TOOLING, "cargo": CARGO},
        "python": sys.version,
        "platform": platform.platform(),
        "rustc": subprocess.check_output(["rustc", "-Vv"], text=True),
        "cargo": subprocess.check_output(["cargo", "-V"], text=True),
        "clippy": subprocess.check_output(["cargo", "clippy", "-V"], text=True),
        "configuration": configuration,
        "environment": compiler_environment,
    }
    # Environment/configuration content never reaches a log or receipt.
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


def main():
    os.environ.setdefault("RUST_TEST_THREADS", os.environ.get("EMIL_BUILD_JOBS", "4"))
    key = input_key(os.environ.get("RC_BUILD_PROVENANCE"), os.environ)
    cache = (
        Path(os.environ.get("CARGO_TARGET_DIR", ROOT / "host-daemon-rs/target"))
        / "gateway-check.json"
    )
    stages_path = os.environ.get("RC_BUILD_STAGES")

    def record(value):
        if stages_path:
            with Path(stages_path).open("a") as stream:
                stream.write(json.dumps(value) + "\n")

    try:
        previous = json.loads(cache.read_text())
    except (OSError, ValueError):
        previous = {}
    if (
        key
        and os.environ.get("RC_FORCE_CHECKS") != "1"
        and previous.get("inputKey") == key
    ):
        print(
            "Reusing successful gateway checks for this exact source and toolchain",
            flush=True,
        )
        record({"stage": "gatewayChecks", "reused": True, "evidence": previous})
        return 0
    # A forced or changed-input failure must invalidate older success evidence.
    cache.unlink(missing_ok=True)
    status = run_lanes(
        {"tooling": TOOLING, "cargo": CARGO},
        ROOT,
        lambda name, seconds, code: record(
            {"stage": name, "seconds": seconds, "exitCode": code}
        ),
    )
    if status:
        return status
    if key:
        cache.parent.mkdir(parents=True, exist_ok=True)
        temporary = cache.with_suffix(".tmp")
        evidence = {
            "inputKey": key,
            "passedAt": time.time(),
            "buildId": json.loads(Path(os.environ["RC_BUILD_PROVENANCE"]).read_text())[
                "buildId"
            ],
        }
        temporary.write_text(json.dumps(evidence) + "\n")
        temporary.replace(cache)
        record({"stage": "gatewayChecks", "reused": False, "evidence": evidence})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
