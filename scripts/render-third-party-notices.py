#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def render(source: Path, destination: Path, title: str) -> None:
    data = json.loads(source.read_text())
    crates = [entry["package"] for entry in data["crates"] if entry["package"]["source"]]
    lines = [f"# {title}", "", "Generated with cargo-about 0.9.2 for aarch64-apple-darwin, including build dependencies and excluding development dependencies.", "", "Unmodified registry source is available from each versioned source archive below. Git dependencies link to their exact source revision. MPL-2.0 covered source remains under MPL-2.0; no restriction in RemoteCoder's license limits rights granted by third-party licenses.", "", "## Inventory", "", "| Component | License expression | Source |", "| --- | --- | --- |"]
    for crate in sorted(crates, key=lambda item: (item["name"], item["version"])):
        name, version = crate["name"], crate["version"]
        source_id = crate["source"]
        if source_id.startswith("registry+"):
            url = f"https://static.crates.io/crates/{name}/{name}-{version}.crate"
        else:
            url = source_id.removeprefix("git+").split("?", 1)[0].split("#", 1)[0].removesuffix(".git") + "/tree/" + source_id.rsplit("#", 1)[1]
        lines.append(f"| {name} {version} | {crate.get('license') or 'See notice below'} | [Source]({url}) |")
    lines.extend(["", "## License texts and attribution", ""])
    for notice in data["licenses"]:
        users = sorted({f"{entry['crate']['name']} {entry['crate']['version']}" for entry in notice["used_by"] if entry["crate"]["source"]})
        if not users:
            continue
        lines.extend([f"### {notice['id']}", "", "Used by: " + ", ".join(users), "", notice["text"].strip(), ""])
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("\n".join(lines))


def main() -> None:
    parser = argparse.ArgumentParser(description="Render cargo-about JSON without local paths or build metadata.")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--title", required=True)
    args = parser.parse_args()
    render(args.source, args.destination, args.title)


if __name__ == "__main__":
    main()
