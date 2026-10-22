#!/usr/bin/env python3
"""Install a release's direct exports on this Mac, or on the iPhone directly or through SimpleMDM."""

import argparse
import contextlib
import importlib.util
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile
from pathlib import Path

MAC_APP = Path("/Applications/RemoteCoder.app")
QUIT_SECONDS = 90
RELAUNCH_SECONDS = 10


def load_script(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_installer():
    return load_script("install_built_app", "install-built-app.py")


def version(info: dict) -> str:
    return f"{info['CFBundleShortVersionString']} ({info['CFBundleVersion']})"


def install_iphone(ipa: Path) -> str:
    completed = ipa.with_name("iphone-install.txt")
    if completed.exists():
        return "skipped, an earlier attempt " + completed.read_text().strip()
    result, installed = deliver_iphone(ipa)
    if installed:
        completed.write_text(result + "\n")
    return result


def deliver_iphone(ipa: Path) -> tuple[str, bool]:
    delivery = load_script("deliver_ios_app", "deliver-ios-app.py")
    info = ipa_info(ipa)
    enrolled, udid, paired = delivery.automatic_route("")
    if paired:
        with delivery.direct_install_lease(info["CFBundleIdentifier"], paired[1]):
            return install_iphone_directly(load_installer(), ipa, paired[0], paired[2]), True
    try:
        device, catalog, installed = delivery.mdm_target(udid, info["CFBundleIdentifier"], device=enrolled)
    except delivery.ManagedAppNotConfigured as error:
        raise RuntimeError(f"no reachable iPhone, and managed delivery is unavailable: {error}") from error
    verified = delivery.mdm_install(
        ipa, device, catalog, installed, info, ipa.with_name("mdm-install-receipt.json")
    )
    name = device["attributes"].get("name") or device["attributes"]["unique_identifier"]
    if verified.get("status") == "installed":
        return f"installed {version(info)} on {name} through SimpleMDM", True
    if verified.get("upload_state") == "accepted" and verified.get("install_request_state") == "accepted":
        return f"requested {version(info)} on {name} through SimpleMDM; the iPhone has not confirmed it yet", False
    raise RuntimeError(verified.get("error", "SimpleMDM did not verify the installation"))


def ipa_info(ipa: Path) -> dict:
    with zipfile.ZipFile(ipa) as archive:
        return plistlib.loads(archive.read("Payload/RemoteCoder.app/Info.plist"))


def install_iphone_directly(installer, ipa: Path, identifier: str, name: str) -> str:
    with tempfile.TemporaryDirectory() as temporary:
        subprocess.run(["ditto", "-x", "-k", str(ipa), temporary], check=True)
        app = Path(temporary) / "Payload/RemoteCoder.app"
        info = plistlib.loads((app / "Info.plist").read_bytes())
        run = installer.DEPLOYMENTS / ("ios-release-" + uuid.uuid4().hex)
        run.mkdir(parents=True)
        installer.retire_expired_deployments()
        receipt = {
            "device": identifier,
            "version": version(info),
            "installed": False,
            "readBack": False,
            "launched": False,
        }
        try:
            with installer.device_lease(identifier) as lease:
                current = installer.installed_app(
                    identifier, info["CFBundleIdentifier"], run / "before.json", lease
                )
                if current and (current.get("version"), current.get("bundleVersion")) == (
                    info["CFBundleShortVersionString"],
                    info["CFBundleVersion"],
                ):
                    receipt["readBack"] = True
                    receipt["deviceVersion"] = current["version"]
                    receipt["deviceBuild"] = current["bundleVersion"]
                    return f"skipped, {name} already has {version(info)}"
                installer.install_and_launch(identifier, app, info, run, receipt, lease)
        finally:
            (run / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    result = f"installed {version(info)} on {name} directly"
    if receipt.get("launchSkipped") == "device locked":
        result += ", launch skipped: device locked"
    return result


def running_pids(target: Path) -> list[int]:
    found = subprocess.run(
        ["ps", "-axo", "pid=,comm="],
        capture_output=True,
        text=True,
        check=True,
    )
    executable = str(target / "Contents/MacOS/RemoteCoder")
    return [int(parts[0]) for line in found.stdout.splitlines()
            if (parts := line.split(None, 1))[1:] == [executable]]


def launch_services_lists(target: Path) -> bool:
    found = subprocess.run(
        ["lsappinfo", "find", f"bundlepath={target}"], capture_output=True, text=True, check=True
    )
    return bool(found.stdout.strip())


def quit_in_time(target: Path) -> bool:
    deadline = time.monotonic() + QUIT_SECONDS
    while running_pids(target) or launch_services_lists(target):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.2)
    return True


def launchd_exit_code(service: str) -> int | None:
    deadline = time.monotonic() + RELAUNCH_SECONDS
    while time.monotonic() < deadline:
        printed = subprocess.run(["launchctl", "print", service], capture_output=True, text=True, check=True)
        exited = re.search(r"^\tlast exit code = (\d+)", printed.stdout, re.MULTILINE)
        if exited:
            return int(exited[1])
        time.sleep(0.2)
    return None


def open_in_login_session(target: Path) -> None:
    domain = f"gui/{os.getuid()}"
    service = f"{domain}/com.remotecoder.relaunch.{uuid.uuid4().hex}"
    with tempfile.TemporaryDirectory() as temporary:
        errors = Path(temporary) / "open.log"
        job = Path(temporary) / "relaunch.plist"
        job.write_bytes(
            plistlib.dumps(
                {
                    "Label": service.removeprefix(f"{domain}/"),
                    "ProgramArguments": ["/usr/bin/open", "-g", str(target)],
                    "RunAtLoad": True,
                    "StandardErrorPath": str(errors),
                }
            )
        )
        subprocess.run(["launchctl", "bootstrap", domain, str(job)], check=True)
        try:
            code = launchd_exit_code(service)
        finally:
            subprocess.run(["launchctl", "bootout", service], check=True)
        if code is None:
            raise RuntimeError(f"open {target} had not finished after {RELAUNCH_SECONDS} s")
        if code != 0:
            detail = errors.read_text().strip() if errors.exists() else "no output"
            raise RuntimeError(f"open {target} exited with {code}: {detail}")


@contextlib.contextmanager
def mac_target_lease(target: Path):
    with load_installer().device_lease(f"mac:{target}"):
        yield


def install_mac_release(app: Path, target: Path) -> str:
    with mac_target_lease(target):
        if target.exists():
            current = plistlib.loads((target / "Contents/Info.plist").read_bytes())
            candidate = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            if mac_version_order(current) > mac_version_order(candidate):
                raise RuntimeError(f"Refusing to downgrade {target} from {version(current)} to {version(candidate)}")
        return replace_mac_app(app, target)


def mac_app_digest(app: Path) -> str:
    details = subprocess.run(
        ["codesign", "--display", "--verbose=3", str(app)], capture_output=True, text=True, check=True,
    ).stderr
    digest = re.search(r"^CDHash=([0-9a-f]+)$", details, re.MULTILINE)
    if digest is None:
        raise RuntimeError(f"{app} has no signed code digest")
    return digest[1]


def mac_version_order(info: dict) -> tuple[int, ...]:
    marketing = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", marketing):
        raise RuntimeError("Mac app has an invalid release version")
    return tuple(map(int, marketing.split(".")))


def replace_mac_app(app: Path, target: Path) -> str:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    digest = mac_app_digest(app)
    if target.exists():
        current = plistlib.loads((target / "Contents/Info.plist").read_bytes())
        if version(current) == version(info):
            verified = subprocess.run(
                ["codesign", "--verify", "--deep", "--strict", str(target)], capture_output=True, check=False,
            )
            if verified.returncode == 0 and mac_app_digest(target) == digest:
                return f"skipped, {target} already has {version(info)}"
        if target.stat().st_uid != os.getuid():
            raise RuntimeError(
                f"{target} belongs to another user, as TestFlight installs do; "
                "delete it once with administrator rights so releases can replace it"
            )
    running = running_pids(target)
    stage = Path(tempfile.mkdtemp(prefix=".RemoteCoder-", dir=target.parent))
    try:
        subprocess.run(["ditto", str(app), str(stage / target.name)], check=True)
        if target.exists():
            target.rename(stage / "previous.app")
        (stage / target.name).rename(target)
    finally:
        shutil.rmtree(stage)
    installed = plistlib.loads((target / "Contents/Info.plist").read_bytes())
    if version(installed) != version(info):
        raise RuntimeError(f"{target} reads back {version(installed)}, not {version(info)}")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(target)], check=True)
    if mac_app_digest(target) != digest:
        raise RuntimeError(f"{target} does not match the installed app's signed code digest")
    if not running:
        return f"installed {version(info)}"
    for pid in running:
        os.kill(pid, signal.SIGTERM)
    if not quit_in_time(target):
        raise RuntimeError(
            f"installed {version(info)}, but the previous app had not quit after {QUIT_SECONDS} s, "
            "so it was not relaunched"
        )
    open_in_login_session(target)
    return f"installed {version(info)} and relaunched it"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("ios", "mac"))
    parser.add_argument("release", type=Path)
    args = parser.parse_args()
    name, install = {
        "ios": ("iPhone", lambda: install_iphone(args.release / "RemoteCoder-direct.ipa")),
        "mac": ("Mac", lambda: install_mac_release(args.release / "RemoteCoderMac-direct.app", MAC_APP)),
    }[args.platform]
    try:
        print(f"{name}: {install()}")
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"{name}: failed: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
