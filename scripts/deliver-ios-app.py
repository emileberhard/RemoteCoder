#!/usr/bin/env python3
"""Deliver one verified device artifact, preserving its source identity."""

import argparse
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager, redirect_stdout
from pathlib import Path

from build_support import atomic_json
from maintainer_config import load as maintainer_config

CATALOG_COORDINATOR_HOST = maintainer_config().get("catalogCoordinatorHost", "local")

SCRIPTS = Path(__file__).resolve().parent
CONFIGS = Path.home() / "configs"


class ManagedAppNotConfigured(RuntimeError):
    pass


def load_script(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def mdm_api(method, endpoint, *arguments):
    wrapper = CONFIGS / "skills/simplemdm/scripts/simplemdm"
    result = subprocess.run(
        [str(wrapper), method, endpoint, *arguments],
        capture_output=True,
        check=False,
        text=True,
        timeout=30,
        env=os.environ | {"SIMPLEMDM_RETRY_COUNT": "0", "SIMPLEMDM_TRACE": "0"},
    )
    if result.returncode:
        raise RuntimeError("SimpleMDM lookup failed; check its authenticated CLI")
    return json.loads(result.stdout)


def enrolled_device(requested):
    devices = mdm_api("GET", "/devices", "--all")
    matches = []
    for device in devices:
        attrs = device["attributes"]
        if attrs.get("status") != "enrolled":
            continue
        identifiers = {
            str(device["id"]),
            attrs.get("name"),
            attrs.get("unique_identifier"),
        }
        if requested:
            if requested not in identifiers:
                continue
        elif not str(attrs.get("model_name", "")).startswith("iPhone"):
            continue
        matches.append(device)
    if not matches:
        raise ManagedAppNotConfigured(
            "No matching enrolled iPhone is configured for managed delivery"
        )
    if len(matches) != 1:
        raise RuntimeError(
            "Select exactly one enrolled iPhone with --device <UDID or name>"
        )
    if not matches[0]["attributes"].get("unique_identifier"):
        raise RuntimeError("The enrolled target has no exact device UDID")
    return matches[0]


def mdm_target(requested, bundle, *, device=None):
    device = device or enrolled_device(requested)
    catalog = catalog_app(bundle)
    if catalog is None:
        raise ManagedAppNotConfigured(
            "This app needs its one-time SimpleMDM managed installation; use the apple-devops iPhone iteration workflow"
        )
    installed = mdm_api("GET", f"/devices/{device['id']}/installed_apps", "--all")
    installed = [
        app for app in installed if app["attributes"].get("identifier") == bundle
    ]
    if len(installed) > 1:
        raise RuntimeError(
            "Multiple installed apps match this bundle; refresh the device inventory"
        )
    if not installed or installed[0]["attributes"].get("managed") is not True:
        raise ManagedAppNotConfigured(
            "Accept this app's initial SimpleMDM managed installation before using automatic updates"
        )
    attributes = installed[0]["attributes"]
    if store_build(attributes):
        raise ManagedAppNotConfigured(
            f"the iPhone runs the TestFlight build {attributes['short_version']} ({attributes['version']}), "
            "which iOS refuses to replace through SimpleMDM; one direct install with the iPhone unlocked "
            "near this Mac returns it to managed updates"
        )
    return device, catalog, installed[0]


def store_build(attributes):
    release_cache = load_script("release_cache", SCRIPTS / "release-cache.py")
    try:
        direct = release_cache.build_number(attributes.get("short_version"))
    except ValueError:
        return False
    build = attributes.get("version")
    return isinstance(build, str) and build.isdigit() and build != direct


def catalog_app(bundle):
    catalogs = [
        app
        for app in mdm_api("GET", "/apps", "--all")
        if app["attributes"].get("app_type") == "custom"
        and app["attributes"].get("bundle_identifier") == bundle
    ]
    if len(catalogs) > 1:
        raise RuntimeError(
            "Multiple custom catalog apps match this bundle; resolve the duplicate before delivery"
        )
    return catalogs[0] if catalogs else None


def normalize_device(requested):
    if not re.fullmatch(
        r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", requested
    ):
        return requested
    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPTS / "install-built-app.py"),
            "identify-device",
            "--device",
            requested,
        ],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    fields = result.stdout.strip().split("|", 2)
    if result.returncode or len(fields) != 3 or not fields[1]:
        raise RuntimeError(
            "Cannot resolve the requested CoreDevice identifier to its paired UDID"
        )
    return fields[1]


def load_coordinator():
    loader = importlib.machinery.SourceFileLoader(
        "ios_mdm_delivery_lease",
        str(CONFIGS / "skills/simplemdm/scripts/ios-mdm-install"),
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    coordinator = importlib.util.module_from_spec(spec)
    loader.exec_module(coordinator)
    return coordinator


@contextmanager
def direct_install_lease(bundle, udid):
    catalog = catalog_app(bundle)
    key = (
        str(catalog["id"])
        if catalog
        else "direct-" + hashlib.sha256((bundle + "\0" + udid).encode()).hexdigest()
    )
    coordinator = load_coordinator()
    try:
        with coordinator.CatalogLease(
            CATALOG_COORDINATOR_HOST, key, time.monotonic() + 900
        ) as lease:
            lease.verify()
            yield lease
            lease.verify()
    except coordinator.InstallError as error:
        raise RuntimeError(str(error)) from error


def direct_install(artifact, device, bundle):
    if not device[1]:
        raise RuntimeError("The paired device has no stable UDID")
    installer = load_script(
        "direct_artifact_installer", SCRIPTS / "install-built-app.py"
    )
    output = io.StringIO()
    with direct_install_lease(bundle, device[1]) as lease:
        environment = {
            "RC_BUILD_PROVENANCE": artifact["provenance"],
            "RC_BUILD_SETTINGS_EVIDENCE": artifact["settings"],
        }
        original = {key: os.environ.get(key) for key in environment}
        try:
            os.environ.update(environment)
            with redirect_stdout(output):
                installer.main(
                    [
                        "install",
                        device[0],
                        artifact["app"],
                        "--symbols",
                        artifact["symbols"][0]["path"],
                    ],
                    delivery_guard=lease.verify,
                )
        finally:
            for key, value in original.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
    return json.loads(output.getvalue())


def direct_device(requested):
    try:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPTS / "install-built-app.py"),
                "find-device",
                "--device",
                requested,
            ],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None
    if result.returncode == 2:
        return None
    if result.returncode:
        raise RuntimeError("CoreDevice discovery failed")
    fields = result.stdout.strip().split("|", 2)
    if len(fields) != 3 or not fields[0] or not fields[1]:
        raise RuntimeError("CoreDevice discovery returned no exact paired identity")
    return fields


def passcode_locked(identifier):
    with tempfile.TemporaryDirectory() as temporary:
        output = Path(temporary) / "lock-state.json"
        try:
            result = subprocess.run(
                [
                    "xcrun",
                    "devicectl",
                    "device",
                    "info",
                    "lockState",
                    "--device",
                    identifier,
                    "--quiet",
                    "--timeout",
                    "5",
                    "--json-output",
                    str(output),
                ],
                capture_output=True,
                timeout=10,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return None
        if result.returncode or not output.exists():
            return None
        return json.loads(output.read_text()).get("result", {}).get("passcodeRequired")


def save_direct_proof(artifact, device, enrolled, info, verified):
    if not verified.get("installed") or not verified.get("readBack"):
        raise RuntimeError("Direct delivery did not verify installation")
    path = Path(verified["receipt"])
    content = path.read_bytes()
    actual = json.loads(content)
    expected = {
        "device": device[0],
        "bundleIdentifier": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "installed": True,
        "readBack": True,
    }
    if (
        any(actual.get(key) != value for key, value in expected.items())
        or actual.get("source", {}).get("buildId") != artifact["buildId"]
    ):
        raise RuntimeError(
            "Direct receipt does not prove this original signed artifact"
        )
    proof = {
        "schemaVersion": 1,
        "sourceBuildId": artifact["buildId"],
        "sourceAppSHA256": artifact["appSHA256"],
        "deviceUDID": device[1],
        "deviceId": enrolled["id"] if enrolled else None,
        "bundleIdentifier": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "directReceipt": str(path),
        "directReceiptSHA256": hashlib.sha256(content).hexdigest(),
    }
    atomic_json(Path(artifact["app"]).parent / "direct-install-receipt.json", proof)


def direct_proof(artifact, device, info):
    path = Path(artifact["app"]).parent / "direct-install-receipt.json"
    if not path.exists():
        return None
    try:
        proof = json.loads(path.read_text())
        expected = {
            "schemaVersion": 1,
            "sourceBuildId": artifact["buildId"],
            "sourceAppSHA256": artifact["appSHA256"],
            "deviceId": device["id"],
            "deviceUDID": device["attributes"]["unique_identifier"],
            "bundleIdentifier": info["CFBundleIdentifier"],
            "version": info["CFBundleShortVersionString"],
            "build": info["CFBundleVersion"],
        }
        if path.is_symlink() or any(
            proof.get(key) != value for key, value in expected.items()
        ):
            return None
        actual_path = Path(proof["directReceipt"])
        content = actual_path.read_bytes()
        if hashlib.sha256(content).hexdigest() != proof["directReceiptSHA256"]:
            return None
        actual = json.loads(content)
        if (
            actual.get("installed") is not True
            or actual.get("readBack") is not True
            or actual.get("source", {}).get("buildId") != artifact["buildId"]
            or any(
                actual.get(key) != expected[key]
                for key in ("bundleIdentifier", "version", "build")
            )
        ):
            return None
        return proof
    except (OSError, ValueError, KeyError, TypeError):
        return None


def verify_direct_inventory(device, catalog, info, proof, receipt):
    helper = load_coordinator()
    deadline = time.monotonic() + 300
    api = helper.SimpleMDM(deadline)
    bundle = info["CFBundleIdentifier"]
    desired = helper.build_number(info["CFBundleVersion"])

    def check_catalog():
        current = helper.resource(api.request("GET", f"/apps/{catalog['id']}"))
        attributes = current["attributes"]
        if (
            current["id"] != catalog["id"]
            or attributes.get("bundle_identifier") != bundle
            or attributes.get("app_type") != "custom"
            or attributes.get("processing_status") != "processed"
            or (
                helper.catalog_version(api, current, info["CFBundleShortVersionString"])
                == info["CFBundleShortVersionString"]
                and helper.build_number(attributes.get("version")) > desired
            )
        ):
            raise RuntimeError(
                "Catalog changed, is pending, or superseded this direct build"
            )

    try:
        with helper.CatalogLease(
            CATALOG_COORDINATOR_HOST, str(catalog["id"]), deadline
        ) as lease:
            api.lease = lease
            check_catalog()
            initial = helper.installed_app(api, device["id"], bundle)["attributes"]
            baseline = helper.inventory_time(initial.get("last_seen_at"))
            if (
                initial.get("version") != info["CFBundleVersion"]
                or initial.get("short_version") != info["CFBundleShortVersionString"]
            ):
                raise RuntimeError(
                    "Device inventory changed before verifying the direct build"
                )
            next_refresh = 0.0
            while True:
                if time.monotonic() >= next_refresh:
                    api.request("POST", f"/devices/{device['id']}/refresh")
                    next_refresh = time.monotonic() + 30
                row = helper.installed_app(
                    api, device["id"], bundle, allow_pending=True
                )
                if row is not None:
                    current = row["attributes"]
                    if helper.build_number(current["version"]) > desired:
                        raise RuntimeError(
                            "A newer installed build superseded the direct proof"
                        )
                    if (
                        current["version"] == info["CFBundleVersion"]
                        and current["short_version"]
                        == info["CFBundleShortVersionString"]
                        and helper.inventory_time(current.get("last_seen_at"))
                        > baseline
                    ):
                        check_catalog()
                        lease.verify()
                        receipt.update(
                            installed=True,
                            readBack=True,
                            alreadyInstalled=True,
                            directReceipt=proof["directReceipt"],
                            verification="freshManagedInventoryOfDirectBuild",
                            serverInventoryLastSeenAt=current["last_seen_at"],
                        )
                        return
                helper.wait_interval(deadline)
    except helper.InstallError as error:
        raise RuntimeError(str(error)) from error


def package_for_mdm(artifact, udid):
    app = Path(artifact["app"])
    output = app.parent / "mdm" / "RemoteCoder.ipa"
    receipt_path = output.parent / "package-receipt.json"
    expected = {
        "sourceBuildId": artifact["buildId"],
        "sourceAppSHA256": artifact["appSHA256"],
        "targetUDID": udid,
        "transformationVersion": 1,
    }
    if output.exists():
        cached = json.loads(receipt_path.read_text())
        with output.open("rb") as binary:
            digest = hashlib.file_digest(binary, "sha256").hexdigest()
        if (
            any(cached.get(key) != value for key, value in expected.items())
            or cached.get("sha256") != digest
        ):
            raise RuntimeError(
                "Cached managed IPA does not match this signed artifact and device; rebuild with --force-build"
            )
        verify_public_ipa(output)
        return output
    output.parent.mkdir(mode=0o700, exist_ok=True)
    configuration = load_script("release_config", SCRIPTS / "release-config.py")
    with tempfile.TemporaryDirectory(
        prefix="mdm-package-", dir=output.parent
    ) as temporary:
        staged = Path(temporary) / app.name
        shutil.copytree(app, staged, symlinks=True)
        config_path = staged / "RemoteCoderLocalConfig.json"
        config_bytes = config_path.read_bytes()
        configuration.validate_development(config_bytes)
        public = {
            key: value
            for key, value in json.loads(config_bytes).items()
            if key in configuration.PUBLIC_FIELDS
        }
        sanitized = (json.dumps(public, indent=2) + "\n").encode()
        configuration.validate(sanitized)
        config_path.write_bytes(sanitized)
        info_path = staged / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["RemoteCoderAPNSEnvironment"] = "production"
        info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        staged_ipa = Path(temporary) / "RemoteCoder.ipa"
        helper = CONFIGS / "skills/apple-devops/scripts/package-ios-adhoc"
        result = subprocess.run(
            [
                str(helper),
                "--app",
                str(staged),
                "--output",
                str(staged_ipa),
                "--udid",
                udid,
                "--apns-channel-key",
                "RemoteCoderAPNSEnvironment",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode:
            raise RuntimeError("Ad hoc packaging failed: " + result.stderr.strip())
        packaged = json.loads(result.stdout)
        verify_public_ipa(staged_ipa)
        # Publish the IPA last: every visible cached IPA has completed evidence.
        atomic_json(receipt_path, packaged | expected | {"output": str(output)})
        os.link(staged_ipa, output)
    return output


def verify_public_ipa(output):
    subprocess.run(
        [sys.executable, str(SCRIPTS / "release-config.py"), "verify-ipa", str(output)],
        check=True,
        stdout=sys.stderr,
    )


def automatic_route(requested):
    try:
        enrolled = enrolled_device(requested)
    except ManagedAppNotConfigured as error:
        print(str(error), file=sys.stderr)
        enrolled = None
    exact_udid = enrolled["attributes"]["unique_identifier"] if enrolled else requested
    paired = direct_device(exact_udid)
    if paired and enrolled and paired[1] != exact_udid:
        raise RuntimeError(
            "CoreDevice discovery selected a different iPhone than the enrolled target"
        )
    if paired and enrolled and passcode_locked(paired[0]):
        print("The iPhone is locked; delivering through SimpleMDM", file=sys.stderr)
        paired = None
    return enrolled, exact_udid, paired


def deliver(artifact, requested, route, receipt):
    requested = normalize_device(requested)
    info = plistlib.loads((Path(artifact["app"]) / "Info.plist").read_bytes())
    receipt.update(
        build=info["CFBundleVersion"],
        bundleIdentifier=info["CFBundleIdentifier"],
        source={
            key: artifact["source"][key]
            for key in ("buildId", "sourceCommit", "sourceFingerprint")
        },
    )
    target = None
    enrolled = None
    paired = None
    if route == "auto":
        enrolled, exact_udid, paired = automatic_route(requested)
        route = "direct" if paired else "mdm"
        if route == "mdm":
            target = mdm_target(exact_udid, info["CFBundleIdentifier"], device=enrolled)
    receipt["route"] = route
    if route == "direct":
        device = paired or direct_device(requested)
        if device is None:
            raise RuntimeError(
                "No paired iPhone is reachable. Complete this app's one-time SimpleMDM adoption for delivery anywhere."
            )
        verified = direct_install(artifact, device, info["CFBundleIdentifier"])
        if enrolled is None:
            try:
                enrolled = enrolled_device(device[1])
            except ManagedAppNotConfigured:
                pass
        save_direct_proof(artifact, device, enrolled, info, verified)
        receipt.update(
            installed=verified["installed"],
            readBack=verified["readBack"],
            launched=verified["launched"],
            directReceipt=verified["receipt"],
        )
        return
    device, catalog, installed = target or mdm_target(
        requested, info["CFBundleIdentifier"]
    )
    receipt.update(deviceId=device["id"], catalogAppId=catalog["id"])
    proof = direct_proof(artifact, device, info) if artifact.get("reused") else None
    if (
        proof
        and installed["attributes"].get("version") == info["CFBundleVersion"]
        and installed["attributes"].get("short_version")
        == info["CFBundleShortVersionString"]
    ):
        verify_direct_inventory(device, catalog, info, proof, receipt)
        return
    previous = Path(artifact["app"]).parent / "mdm" / "install-receipt.json"
    started = time.monotonic()
    ipa = package_for_mdm(artifact, device["attributes"]["unique_identifier"])
    receipt["phasesSeconds"]["package"] = round(time.monotonic() - started, 3)
    verified = mdm_install(ipa, device, catalog, installed, info, previous)
    receipt["mdmReceipt"] = str(previous)
    if verified.get("status") != "installed":
        receipt["mdmAttempt"] = verified
        raise RuntimeError(
            verified.get("error", "Managed installation was not verified")
        )
    receipt.update(installed=True, readBack=True)


def mdm_install(ipa, device, catalog, installed, info, previous):
    helper = CONFIGS / "skills/simplemdm/scripts/ios-mdm-install"
    result = subprocess.run(
        [
            str(helper),
            str(ipa),
            "--device-id",
            str(device["id"]),
            "--app-id",
            str(catalog["id"]),
            *(["--previous-receipt", str(previous)] if previous.exists() else []),
            *(
                ["--replace-version"]
                if installed["attributes"].get("short_version")
                != info["CFBundleShortVersionString"]
                else []
            ),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if not result.stdout.strip():
        raise RuntimeError(
            "Managed delivery returned no receipt: " + result.stderr.strip()
        )
    verified = json.loads(result.stdout)
    # A failed refresh/recovery attempt must not destroy accepted/completed proof.
    if verified.get("status") == "installed" or (
        verified.get("upload_state") == "accepted"
        and verified.get("install_request_state") == "accepted"
    ):
        atomic_json(previous, verified)
    return verified

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--delivery", choices=("auto", "direct", "mdm"), default="auto")
    parser.add_argument("--device", default="")
    args = parser.parse_args()
    if os.environ.get("RC_INSTALL_SOURCE_LEASED") != "1":
        raise RuntimeError("Use just install-dev so artifact ownership covers delivery")
    os.umask(0o077)
    started = time.monotonic()
    receipt = {
        "installed": False,
        "readBack": False,
        "launched": False,
        "phasesSeconds": {},
    }
    try:
        subprocess.run(
            [
                sys.executable,
                str(SCRIPTS / "ios-device-artifact.py"),
                "validate",
                "--artifact",
                str(args.artifact),
            ],
            check=True,
        )
        deliver(
            json.loads(args.artifact.read_text()), args.device, args.delivery, receipt
        )
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        receipt["error"] = str(error)
    finally:
        receipt["elapsedSeconds"] = round(time.monotonic() - started, 3)
        destination = args.artifact.parent / "ios-delivery.json"
        atomic_json(destination, receipt)
    print(json.dumps(receipt | {"receipt": str(destination)}))
    return 0 if receipt["installed"] and receipt["readBack"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
