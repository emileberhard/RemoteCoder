import re
from pathlib import Path


NON_CODE = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"')


def code_only(source: str) -> str:
    return NON_CODE.sub(lambda match: "\n" * match.group().count("\n"), source)


SOURCE_ROOTS = (
    "Core/Sources",
    "Core/Tests",
    "RemoteCoder",
    "RemoteCoderLiveActivities",
    "RemoteCoderLocationPushService",
    "RemoteCoderNotificationService",
    "RemoteCoderShareExtension",
    "RemoteCoderCaptureExtension",
    "RemoteCoderTests",
    "RemoteCoderUITests",
    "Shared",
)


def source_files(root: Path) -> list[Path]:
    return sorted(
        path.relative_to(root)
        for name in SOURCE_ROOTS
        for path in (root / name).rglob("*.swift")
    )
