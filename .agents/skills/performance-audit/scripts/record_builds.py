import argparse
import datetime
import json
import sys
from pathlib import Path


def record_name(build: dict) -> str:
    name = f"{build['appVersion']}+{build['build']}"
    return f"{name}-{build['sourceCommit'][:9]}" if build.get("sourceCommit") else name


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Keep one record per build from `just app-telemetry releases` output on stdin. "
                    "A record is replaced only when the new row covers more active minutes.",
        epilog="example: just app-telemetry releases --device iPhone-1234abcd > releases.json && "
               "python3 record_builds.py --into records/iPhone-1234abcd < releases.json")
    parser.add_argument("--into", type=Path, required=True, help="directory holding this device's records")
    arguments = parser.parse_args()

    report = json.load(sys.stdin)
    if not isinstance(report, dict) or not isinstance(report.get("builds"), list):
        print("stdin is not `app-telemetry releases` output: expected an object with a `builds` list",
              file=sys.stderr)
        return 2
    arguments.into.mkdir(parents=True, exist_ok=True)
    recorded = {"at": datetime.datetime.now(datetime.UTC).isoformat(timespec="seconds"),
                "stores": report.get("coverage", {}).get("stores")}
    written, kept = [], []
    for row in report["builds"]:
        path = arguments.into / f"{record_name(row['build'])}.json"
        if path.exists() and json.loads(path.read_text())["activeMinutes"] >= row["activeMinutes"]:
            kept.append(path.name)
            continue
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(row | {"recorded": recorded}, indent=1, sort_keys=True) + "\n")
        temporary.replace(path)
        written.append(path.name)
    print(json.dumps({"into": str(arguments.into), "written": written, "kept": kept}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
