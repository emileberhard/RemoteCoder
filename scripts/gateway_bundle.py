import plistlib
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "host-daemon-rs/RemoteCoderGateway.template"
NAME = SOURCE.with_suffix(".app").name
with (SOURCE / "Contents/Info.plist").open("rb") as stream:
    EXECUTABLE = plistlib.load(stream)["CFBundleExecutable"]


def executable(bundle: Path) -> Path:
    return bundle / "Contents/MacOS" / EXECUTABLE
