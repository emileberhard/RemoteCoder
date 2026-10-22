import socket
from pathlib import Path

from maintainer_config import load

MAC_GUI_HOST = load().get("macGUIHost", "local")
TEST_DEVICE_HOST = load().get("testDeviceHost", "local")


def build_host(root: Path) -> str:
    return load().get("buildHost", (root / "scripts/build-host").read_text().strip())


def is_local(host: str) -> bool:
    return host.split(".")[0].lower() in ("local", socket.gethostname().split(".")[0].lower())
