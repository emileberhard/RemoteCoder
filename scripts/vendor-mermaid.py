#!/usr/bin/env python3
"""Refresh the reviewed, offline Mermaid runtime without npm or install scripts."""
import base64
import hashlib
import io
from pathlib import Path
import tarfile
import urllib.request

VERSION = "12.0.0"  # Published 2026-09-10; reviewed 2026-09-20.
INTEGRITY = "/wQXC9iBxoGV8p3erbvaXs9h77VyLDBH6GdayVjj3hEcSQhFU4N1WUhUppotCEqlIxI2pRMwjwBSwTB1MfZBgQ=="
ROOT = Path(__file__).resolve().parents[1] / "RemoteCoder/Resources/Mermaid"


def main() -> None:
    with urllib.request.urlopen(
        f"https://registry.npmjs.org/mermaid/-/mermaid-{VERSION}.tgz", timeout=30
    ) as response:
        archive = response.read(32 * 1024 * 1024 + 1)
    if base64.b64encode(hashlib.sha512(archive).digest()).decode() != INTEGRITY:
        raise ValueError("Mermaid archive does not match the reviewed SHA-512 integrity")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as package:
        for source, target in (
            ("package/dist/mermaid.min.js", f"mermaid-{VERSION}.min.js"),
            ("package/LICENSE", f"mermaid-{VERSION}-LICENSE.txt"),
        ):
            member = package.extractfile(source)
            if member is None:
                raise ValueError(f"Missing reviewed resource: {source}")
            data = member.read()
            ROOT.mkdir(parents=True, exist_ok=True)
            (ROOT / target).write_bytes(data)
            print(f"{target}: {len(data)} bytes, SHA-256 {hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    main()
