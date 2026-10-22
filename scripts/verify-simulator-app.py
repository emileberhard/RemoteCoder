import argparse
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from xcode_settings import resolve

ROOT = Path(__file__).resolve().parents[1]


def declared_bundles(settings: dict) -> tuple[str, dict[str, str]]:
    manifest = json.loads(
        subprocess.run(
            ["tuist", "dump", "--path", str(ROOT)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    )
    targets = {target["name"]: target for target in manifest["targets"]}
    app = targets["RemoteCoder"]
    extensions = {}
    for dependency in app["dependencies"]:
        if "target" in dependency:
            target = targets[dependency["target"]["name"]]
            if target["product"] == "app_extension":
                extensions[target["name"] + ".appex"] = resolve(
                    target["bundleId"], settings[target["name"]]
                )
    return resolve(app["bundleId"], settings[app["name"]]), extensions


def verified_bundle(
    bundle: Path, declared_entitlements: Path, expected_identifier: str, settings: dict
) -> dict:
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    identifier = info.get("CFBundleIdentifier")
    if identifier != expected_identifier:
        raise ValueError(
            f"{bundle}: CFBundleIdentifier must be {expected_identifier!r}; got {identifier!r}"
        )
    subprocess.run(
        ["codesign", "--verify", "--strict", str(bundle)],
        capture_output=True,
        check=True,
    )
    signature = subprocess.run(
        ["codesign", "--display", "--verbose=4", str(bundle)],
        capture_output=True,
        text=True,
        check=True,
    ).stderr
    if (
        f"Identifier={identifier}" not in signature.splitlines()
        or "Signature=adhoc" not in signature.splitlines()
        or "Info.plist=not bound" in signature
        or "linker-signed" in signature
    ):
        raise ValueError(f"{bundle}: requires a bundle-bound ad hoc signature")
    result = subprocess.run(
        ["codesign", "--display", "--entitlements", "-", "--xml", str(bundle)],
        capture_output=True,
        check=True,
    )
    signed_entitlements = plistlib.loads(result.stdout)
    executable = bundle / info["CFBundleExecutable"]
    with tempfile.TemporaryDirectory() as temporary:
        section = Path(temporary) / "entitlements.plist"
        subprocess.run(
            [
                "xcrun",
                "llvm-objcopy",
                "--dump-section",
                f"__TEXT,__entitlements={section}",
                str(executable),
                str(Path(temporary) / "executable"),
            ],
            capture_output=True,
            check=True,
        )
        entitlements = plistlib.loads(section.read_bytes().rstrip(b"\0"))
    declared = resolve(plistlib.loads(declared_entitlements.read_bytes()), settings)
    for name, value in declared.items():
        if entitlements.get(name) != value:
            raise ValueError(f"{bundle}: signed entitlement {name} must be {value!r}")
    return {
        "path": str(bundle),
        "bundleId": identifier,
        "signedEntitlements": signed_entitlements,
        "simulatorEntitlements": entitlements,
    }


def verify_app(app: Path, settings: dict) -> dict:
    identifier, expected_extensions = declared_bundles(settings)
    evidence = verified_bundle(
        app,
        ROOT / "RemoteCoder/Entitlements/RemoteCoder.Debug.entitlements",
        identifier,
        settings["RemoteCoder"],
    )
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("NSSupportsLiveActivities") is not True:
        raise ValueError(f"{app}: NSSupportsLiveActivities must be true")
    evidence["supportsLiveActivities"] = True
    embedded = {path.name for path in (app / "PlugIns").glob("*.appex")}
    if embedded != expected_extensions.keys():
        raise ValueError(
            f"{app}: embedded extensions differ from Project.swift; missing={sorted(expected_extensions.keys() - embedded)}, unexpected={sorted(embedded - expected_extensions.keys())}"
        )
    widget = app / "PlugIns/RemoteCoderLiveActivities.appex"
    widget_info = plistlib.loads((widget / "Info.plist").read_bytes())
    if (
        widget_info.get("NSExtension", {}).get("NSExtensionPointIdentifier")
        != "com.apple.widgetkit-extension"
    ):
        raise ValueError(f"{widget}: embedded WidgetKit extension is missing")
    extensions = []
    for name, identifier in sorted(expected_extensions.items()):
        bundle = app / "PlugIns" / name
        extensions.append(
            verified_bundle(
                bundle,
                ROOT / bundle.stem / f"{bundle.stem}.entitlements",
                identifier,
                settings[bundle.stem],
            )
        )
    evidence["extensions"] = extensions
    return evidence


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--settings", type=Path, required=True)
    args = parser.parse_args()
    started = time.monotonic()
    try:
        entries = json.loads(args.settings.read_text())
        settings = {}
        for entry in entries:
            name, values = entry["target"], entry["buildSettings"]
            if name in settings and settings[name] != values:
                raise ValueError(f"Xcode settings conflict for target {name}")
            settings[name] = values
        evidence = verify_app(args.app, settings)
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.CalledProcessError,
    ) as error:
        detail = str(error)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            detail = (
                error.stderr
                if isinstance(error.stderr, str)
                else error.stderr.decode(errors="replace")
            )
        print(
            f"Hosted simulator app validation failed: {detail}. Rebuild Debug with CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- and the declared target entitlements; tests were not launched.",
            file=sys.stderr,
        )
        return 1
    print("Hosted simulator app verified: " + json.dumps(evidence), flush=True)
    if stages := os.environ.get("RC_BUILD_STAGES"):
        with Path(stages).open("a") as output:
            output.write(
                json.dumps(
                    {
                        "stage": "simulatorAppValidation",
                        "exitCode": 0,
                        "seconds": round(time.monotonic() - started, 3),
                        **evidence,
                    }
                )
                + "\n"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
