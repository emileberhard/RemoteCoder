#!/usr/bin/env python3
"""Install one exact built app under the physical device's installation lease."""

import argparse
import fcntl
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
import uuid
from contextlib import contextmanager
from pathlib import Path

DEPLOYMENTS = Path.home() / "Library/Logs/remote-coder/deployments"
DEPLOYMENT_RETENTION_SECONDS = 7 * 24 * 60 * 60
PER_RUN_ENTRY = re.compile(
    r"[a-z0-9-]+-([0-9a-f]{32}|\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z\.log)"
)
SYMBOL_DEPLOYMENT = re.compile(r"(ios|mac)-[0-9a-f]{32}")


class DevicectlError(RuntimeError):
    def __init__(self, message: str, report: object):
        super().__init__(message)
        self.report = report

    def is_locked_launch(self) -> bool:
        if not isinstance(self.report, dict):
            return False
        info = self.report.get("info")
        if (
            not isinstance(info, dict)
            or info.get("commandType") != "devicectl.device.process.launch"
            or info.get("outcome") != "failed"
        ):
            return False
        error = self.report.get("error")
        for domain, code in (
            ("com.apple.dt.CoreDeviceError", 10002),
            ("FBSOpenApplicationServiceErrorDomain", 1),
            ("FBSOpenApplicationErrorDomain", 7),
        ):
            if (
                not isinstance(error, dict)
                or error.get("domain") != domain
                or type(error.get("code")) is not int
                or error["code"] != code
            ):
                return False
            user_info = error.get("userInfo")
            underlying = (
                user_info.get("NSUnderlyingError")
                if isinstance(user_info, dict)
                else None
            )
            error = underlying.get("error") if isinstance(underlying, dict) else None
        return error is None


def invoke(arguments: list[str], output: Path, lease_fd: int) -> dict:
    result = subprocess.run(
        ["xcrun", "devicectl", *arguments, "--json-output", str(output), "--quiet"],
        pass_fds=(lease_fd,),
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode:
        message = result.stderr.strip() or "devicectl failed; inspect " + str(output)
        try:
            report = json.loads(output.read_text())
        except (OSError, ValueError):
            raise RuntimeError(message) from None
        raise DevicectlError(message, report)
    return json.loads(output.read_text())["result"]


def find_device(requested: str, *, reachable_only: bool = True) -> dict | None:
    """Return an explicit reachable physical iOS device, or the first reachable iPhone."""
    with tempfile.TemporaryDirectory() as temporary:
        output = Path(temporary) / "devices.json"
        listed = subprocess.run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", str(output), "--quiet"],
            capture_output=True,
            check=False,
        )
        if listed.returncode:
            return None
        devices = json.loads(output.read_text()).get("result", {}).get("devices", [])
    # Previously paired devices stay listed with tunnelState=unavailable.
    candidates = [
        device
        for device in devices
        if device.get("hardwareProperties", {}).get("reality") == "physical"
        and device.get("hardwareProperties", {}).get("platform") == "iOS"
        and (
            requested
            or device.get("hardwareProperties", {}).get("deviceType") == "iPhone"
        )
        and device.get("connectionProperties", {}).get("pairingState") == "paired"
        and (not reachable_only or device.get("connectionProperties", {}).get("tunnelState")
             not in (None, "unavailable"))
        and device.get("identifier")
    ]
    if not requested:
        return candidates[0] if candidates else None
    matches = [
            device
            for device in candidates
            if requested
            in {
                device["identifier"],
                device.get("hardwareProperties", {}).get("udid", ""),
                device.get("deviceProperties", {}).get("name", ""),
            }
    ]
    if len(matches) > 1:
        raise RuntimeError("More than one paired device matches; select its exact UDID")
    return matches[0] if matches else None


@contextmanager
def device_lease(device: str):
    locks = Path.home() / "Library/Caches/RemoteCoder-Build/device-locks"
    locks.mkdir(parents=True, exist_ok=True)
    lock_path = locks / (hashlib.sha256(device.encode()).hexdigest() + ".lock")
    with lock_path.open("a") as lease:
        fcntl.flock(lease, fcntl.LOCK_EX)
        yield lease.fileno()


def installed_app(device: str, bundle: str, output: Path, lease_fd: int) -> dict | None:
    apps = invoke(["device", "info", "apps", "--device", device], output, lease_fd)
    return next(
        (app for app in apps["apps"] if app.get("bundleIdentifier") == bundle), None
    )


def install_and_launch(
    device: str, app: Path, info: dict, run: Path, receipt: dict, lease_fd: int,
    delivery_guard=None,
) -> None:
    bundle = info["CFBundleIdentifier"]
    if delivery_guard:
        delivery_guard()
    before = installed_app(device, bundle, run / "before.json", lease_fd)
    if before and before.get("version") == info["CFBundleShortVersionString"] == "0.0.0":
        def development_number(value):
            if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
                raise RuntimeError("Cannot order the installed development build number")
            return tuple(map(int, value.split("."))) + (0,) * (3 - len(value.split(".")))
        if development_number(before.get("bundleVersion")) > development_number(info["CFBundleVersion"]):
            raise RuntimeError("A newer development build is already installed; refusing superseded delivery")
    if delivery_guard:
        delivery_guard()
    invoke(
        ["device", "install", "app", "--device", device, str(app)],
        run / "install.json",
        lease_fd,
    )
    receipt["installed"] = True
    if delivery_guard:
        delivery_guard()
    installed = installed_app(device, bundle, run / "apps.json", lease_fd)
    if installed is None:
        raise RuntimeError("The installed bundle was not returned by device readback")
    if (
        installed.get("version") != info["CFBundleShortVersionString"]
        or installed.get("bundleVersion") != info["CFBundleVersion"]
    ):
        raise RuntimeError(
            "Device readback does not match the built version and build number"
        )
    receipt["readBack"] = True
    receipt["deviceVersion"] = installed.get("version")
    receipt["deviceBuild"] = installed.get("bundleVersion")
    receipt["launched"] = False
    if delivery_guard:
        delivery_guard()
    try:
        receipt["launch"] = invoke(
            ["device", "process", "launch", "--terminate-existing", "--device", device, bundle],
            run / "launch.json",
            lease_fd,
        )
    except DevicectlError as error:
        if not error.is_locked_launch():
            raise
        receipt["launchSkipped"] = "device locked"
        return
    receipt["launched"] = True


def binary_identities(path: Path) -> set[tuple[str, str]]:
    output = subprocess.check_output(
        ["xcrun", "dwarfdump", "--uuid", str(path)], text=True
    )
    identities = {
        (value.upper(), arch)
        for value, arch in re.findall(r"UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)", output)
    }
    if not identities:
        raise RuntimeError(f"No Mach-O UUIDs found for {path.name}")
    return identities


def retain_symbols(binaries: Path, products: Path, destination: Path) -> list[dict]:
    destination.mkdir()
    retained = []
    identities = {}
    for binary in [binaries / "RemoteCoder", binaries / "RemoteCoder.debug.dylib"]:
        if not binary.exists():
            continue
        values = binary_identities(binary)
        identities[binary.name] = values
        target = destination / binary.name
        shutil.copy2(binary, target)
        retained.append(
            {
                "file": str(target),
                "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
                "uuids": [
                    {"uuid": value, "architecture": arch}
                    for value, arch in sorted(values)
                ],
            }
        )
    # Debug's executable can be only a launch shim: require symbols for the
    # image containing the app code, not merely any stale dSYM in DerivedData.
    code_image = (
        "RemoteCoder.debug.dylib"
        if "RemoteCoder.debug.dylib" in identities
        else "RemoteCoder"
    )
    required = identities.get(code_image, set())
    matched = set()
    for symbols in sorted(products.glob("RemoteCoder*.dSYM")):
        values = binary_identities(symbols)
        if not required.intersection(values):
            continue
        shutil.copytree(symbols, destination / symbols.name)
        matched.update(values)
    if not required or not required.issubset(matched):
        raise RuntimeError(
            "Refusing an untraceable device install: app code has no UUID-matching dSYM"
        )
    return retained


def installed_with_symbols(deployment: Path) -> bool:
    try:
        receipt = json.loads((deployment / "receipt.json").read_text())
    except (OSError, ValueError):
        return False
    return (
        isinstance(receipt, dict)
        and receipt.get("installed") is True
        and (deployment / "symbols").is_dir()
    )


def prune_deployments(root: Path, now: float) -> list[Path]:
    entries = [entry for entry in root.iterdir() if PER_RUN_ENTRY.fullmatch(entry.name)]
    newest = {}
    for entry in entries:
        match = SYMBOL_DEPLOYMENT.fullmatch(entry.name)
        if match and installed_with_symbols(entry) and (
            match[1] not in newest
            or entry.lstat().st_mtime > newest[match[1]].lstat().st_mtime
        ):
            newest[match[1]] = entry
    expired = [
        entry
        for entry in entries
        if entry not in newest.values()
        and now - entry.lstat().st_mtime > DEPLOYMENT_RETENTION_SECONDS
    ]
    for entry in expired:
        if entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry)
        else:
            entry.unlink()
    return expired


def retire_expired_deployments() -> None:
    try:
        removed = prune_deployments(DEPLOYMENTS, time.time())
    except OSError as error:
        print(f"warning: deployment log retention failed: {error}", file=sys.stderr)
        return
    if removed:
        print(f"Removed {len(removed)} deployment logs older than 7 days", file=sys.stderr)


def main(arguments=None, *, delivery_guard=None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    find = commands.add_parser("find-device")
    find.add_argument("--device", default="")
    identify = commands.add_parser("identify-device")
    identify.add_argument("--device", required=True)
    install = commands.add_parser("install")
    install.add_argument("device")
    install.add_argument("app", type=Path)
    install.add_argument("--symbols", type=Path, help="Retained matching dSYM directory for an immutable artifact")
    args = parser.parse_args(arguments)
    if args.command in {"find-device", "identify-device"}:
        device = find_device(args.device, reachable_only=args.command == "find-device")
        if device is None:
            sys.exit(2)
        print(
            "|".join(
                (
                    device["identifier"],
                    device.get("hardwareProperties", {}).get("udid", ""),
                    device.get("deviceProperties", {}).get("name", ""),
                )
            )
        )
        return
    os.umask(0o077)
    info = plistlib.loads((args.app / "Info.plist").read_bytes())
    evidence_path = os.environ.get("RC_BUILD_SETTINGS_EVIDENCE")
    if not evidence_path:
        raise RuntimeError(
            "Missing verified Xcode build-settings evidence; use the device installer"
        )
    evidence = json.loads(Path(evidence_path).read_text())
    spec = importlib.util.spec_from_file_location(
        "device_build_identity", Path(__file__).with_name("device-build-identity.py")
    )
    identity_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(identity_module)
    identity_module.verify_bundle(info, evidence)
    bundle = info["CFBundleIdentifier"]
    executable = args.app / info["CFBundleExecutable"]
    run = DEPLOYMENTS / ("ios-" + uuid.uuid4().hex)
    run.mkdir(parents=True)
    retire_expired_deployments()
    symbols = retain_symbols(args.app, args.symbols or args.app.parent, run / "symbols")
    (run / "build-settings.json").write_text(json.dumps(evidence, indent=2) + "\n")
    receipt = {
        "device": args.device,
        "bundleIdentifier": bundle,
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "installed": False,
        "readBack": False,
        "launched": False,
        "optimizedDevelopmentBuild": evidence["settings"]["SWIFT_OPTIMIZATION_LEVEL"]
        == "-O",
        "buildSettings": evidence["settings"],
        "retainedSymbols": symbols,
    }
    provenance_path = os.environ.get("RC_BUILD_PROVENANCE")
    if provenance_path:
        source = json.loads(Path(provenance_path).read_text())
        receipt["source"] = {
            key: source[key] for key in ("sourceCommit", "sourceFingerprint", "buildId")
        }
        if any(
            source[key] != evidence["identity"][key]
            for key in ("sourceCommit", "sourceFingerprint", "buildId")
        ):
            raise RuntimeError(
                "Source provenance does not match the verified built candidate"
            )
    try:
        with device_lease(args.device) as lease:
            install_and_launch(args.device, args.app, info, run, receipt, lease,
                               delivery_guard=delivery_guard)
    finally:
        (run / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if receipt.get("launchSkipped") == "device locked":
        print("installed, launch skipped: device locked", file=sys.stderr)
    print(
        json.dumps(
            {key: value for key, value in receipt.items() if key != "launch"}
            | {"receipt": str(run / "receipt.json")}
        )
    )


if __name__ == "__main__":
    main()
