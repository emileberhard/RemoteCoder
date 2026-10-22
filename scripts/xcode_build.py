import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def xcode_exit_zero_diagnostics(output: str) -> list[str]:
    return re.findall(
        r"(?m)^error: the following command failed with exit code 0 but produced no further output\n([^\n]*)",
        output,
    )


def verify_xcode_products(
    kind: str, derived: Path, started: float, diagnostics: list[str]
) -> list[str]:
    targets = set()
    for diagnostic in diagnostics:
        target = re.search(r"in target '([^']+)'", diagnostic)
        if target is None:
            raise ValueError(
                "Xcode emitted an exit-zero task diagnostic without a target identity"
            )
        targets.add(target[1])
    if kind in {"mac-install", "mac-bench"}:
        derived = derived.with_name(derived.name + "-mac-optimized")
    products = derived / "Build/Products"
    paths = []
    for target in targets:
        if target == "RemoteCoderMac":
            configuration = "Release" if kind == "mac-bench" else "Debug"
            paths.append(products / configuration / "RemoteCoder.app/Contents/MacOS/RemoteCoder")
        elif target == "RemoteCoder":
            platform = (
                "Debug-iphoneos" if kind == "ios-install" else "Debug-iphonesimulator"
            )
            paths.append(products / platform / "RemoteCoder.app/RemoteCoder")
        elif target == "RemoteCoderTests":
            paths.append(
                products
                / "Debug-iphonesimulator/RemoteCoder.app/PlugIns/RemoteCoderTests.xctest/RemoteCoderTests"
            )
        elif target == "RemoteCoderUITests":
            paths.append(
                products
                / "Debug-iphonesimulator/RemoteCoderUITests-Runner.app/PlugIns/RemoteCoderUITests.xctest/RemoteCoderUITests"
            )
        elif target in {
            "RemoteCoderNotificationService",
            "RemoteCoderLocationPushService",
            "RemoteCoderLiveActivities",
            "RemoteCoderShareExtension",
            "RemoteCoderCaptureExtension",
        }:
            platform = (
                "Debug-iphoneos" if kind == "ios-install" else "Debug-iphonesimulator"
            )
            paths.append(products / platform / f"{target}.appex/{target}")
            if target == "RemoteCoderCaptureExtension":
                paths.append(
                    products
                    / platform
                    / f"RemoteCoder.app/Extensions/{target}.appex/{target}"
                )
        else:
            raise ValueError(
                f"Cannot verify the product for Xcode diagnostic target '{target}'"
            )
    for path in paths:
        if not path.is_file() or path.stat().st_mtime < started:
            raise ValueError(
                f"Xcode emitted an exit-zero task diagnostic, but its expected product is missing or stale: {path}"
            )
    return sorted({str(path) for path in paths})


def verify_xcode_evidence(kind, derived, started, diagnostics, stages):
    remaining = list(diagnostics)
    products = set()
    for stage in stages:
        if stage["stage"] not in {"macCompile", "iosCompile"}:
            continue
        if stage["exitCode"] != 0:
            raise ValueError("Xcode compilation failed despite a successful recipe")
        for diagnostic in stage["xcodeExitZeroDiagnostics"]:
            remaining.remove(diagnostic)
        products.update(stage["verifiedProducts"])
    if remaining:
        products.update(verify_xcode_products(kind, derived, started, remaining))
    return sorted(products)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("mac-build", "ios-build"))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    try:
        derived = Path(command[command.index("-derivedDataPath") + 1])
    except (ValueError, IndexError):
        print(
            "Xcode compilation requires an explicit -derivedDataPath", file=sys.stderr
        )
        return 2
    started = time.time()
    timer = time.monotonic()
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as output:
        status = subprocess.run(
            command, stdout=output, stderr=subprocess.STDOUT, check=False
        ).returncode
        if status < 0:
            status = 128 - status
        output.seek(0)
        shutil.copyfileobj(output, sys.stdout)
        output.seek(0)
        warnings = xcode_exit_zero_diagnostics(output.read())
    products = []
    if status == 0 and warnings:
        try:
            products = verify_xcode_products(args.kind, derived, started, warnings)
        except ValueError as error:
            print(error, file=sys.stderr)
            status = 1
    if stages := os.environ.get("RC_BUILD_STAGES"):
        with Path(stages).open("a", encoding="utf-8") as stream:
            stream.write(
                json.dumps(
                    {
                        "stage": "macCompile"
                        if args.kind == "mac-build"
                        else "iosCompile",
                        "startedAt": started,
                        "seconds": round(time.monotonic() - timer, 3),
                        "exitCode": status,
                        "xcodeExitZeroDiagnostics": warnings,
                        "verifiedProducts": products,
                    }
                )
                + "\n"
            )
    return status


if __name__ == "__main__":
    raise SystemExit(main())
