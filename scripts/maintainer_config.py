import argparse
import json
import os
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def path() -> Path:
    return Path(os.environ.get("RC_MAINTAINER_CONFIG", Path.home() / "RemoteCoder-deploy/maintainer.json"))


def load() -> dict:
    source = path()
    try:
        value = json.loads(source.read_text())
    except FileNotFoundError:
        if "RC_MAINTAINER_CONFIG" in os.environ:
            raise
        return {}
    if not isinstance(value, dict):
        raise ValueError(f"Maintainer configuration must be an object: {source}")
    return value


def configure(root: Path, *, required: bool = False) -> None:
    settings = load().get("xcodeSettings", {})
    if not settings:
        if required:
            raise ValueError("Signed releases require maintainer xcodeSettings")
        return
    if required:
        team = settings.get("DEVELOPMENT_TEAM", "")
        bundle = settings.get("RC_BUNDLE_ID", "")
        if not re.fullmatch(r"[A-Z0-9]{10}", team) or not bundle or bundle.startswith(("com.example.", "org.example.")):
            raise ValueError("Signed releases require a real development team and bundle identifier")
    destination = root / "Config/Local.xcconfig"
    if destination.exists() and not required:
        return
    lines = []
    for key, value in settings.items():
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or not isinstance(value, str) or any(c in value for c in "\r\n"):
            raise ValueError("Invalid maintainer Xcode setting")
        lines.append(f"{key} = {value.replace('://', ':/$()/')}\n")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("".join(lines))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("configure", "show"))
    parser.add_argument("--required", action="store_true")
    arguments = parser.parse_args()
    if arguments.action == "configure":
        configure(ROOT, required=arguments.required)
    else:
        print(json.dumps(load()))


if __name__ == "__main__":
    main()
