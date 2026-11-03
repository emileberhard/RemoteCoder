import argparse
import datetime
import fcntl
import json
import sys
from pathlib import Path

RUN_BUILD_FIELDS = ("appVersion", "build", "sourceCommit")


def record_name(build: dict) -> str:
    name = f"{build['appVersion']}+{build['build']}"
    return f"{name}-{build['sourceCommit']}" if build.get("sourceCommit") else name


def snapshot(row: dict, coverage: dict, recorded_at: str) -> dict:
    identity = tuple(row["build"].get(field) for field in RUN_BUILD_FIELDS)
    return {
        "recordedAt": recorded_at,
        "coverage": {
            "window": coverage.get("window"),
            "stores": coverage.get("stores"),
            "unreadableSegments": coverage.get("unreadableSegments", []),
            "losses": coverage.get("losses", []),
            "runs": [run for run in coverage.get("runs", [])
                     if tuple(run.get(field) for field in RUN_BUILD_FIELDS) == identity],
        },
        "row": row,
    }


def evidence(entry: dict) -> dict:
    return {"row": entry["row"], "coverage": {key: value for key, value in entry["coverage"].items() if key != "window"}}


def append_if_new(path: Path, entry: dict) -> bool:
    with path.open("a+b") as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        file.seek(0)
        content = file.read()
        complete = content[:content.rfind(b"\n") + 1]
        if len(complete) != len(content):
            print(f"{path}: dropping an incomplete final line left by an interrupted append", file=sys.stderr)
            file.truncate(len(complete))
        recorded = []
        for number, line in enumerate(complete.splitlines(), start=1):
            if not line.strip():
                continue
            try:
                recorded.append(evidence(json.loads(line)))
            except (json.JSONDecodeError, KeyError, TypeError, AttributeError) as error:
                raise SystemExit(f"{path}:{number}: malformed record line ({error!r}); repair or remove it") from error
        if evidence(entry) in recorded:
            return False
        try:
            file.write((json.dumps(entry, sort_keys=True) + "\n").encode())
            file.flush()
        except BaseException:
            file.truncate(len(complete))
            raise
        return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Append each build's row from `just app-telemetry releases` output on stdin to that build's "
                    "record, one JSON line per distinct snapshot with its coverage. A snapshot whose row and "
                    "coverage, apart from the read window, match a recorded one is skipped, so reruns are no-ops.",
        epilog="example: just app-telemetry releases --device iPhone-1234abcd > releases.json && "
               "python3 record_builds.py --into records/iPhone-1234abcd < releases.json")
    parser.add_argument("--into", type=Path, required=True, help="directory holding this device's records")
    arguments = parser.parse_args()

    report = json.load(sys.stdin)
    if not isinstance(report, dict) or not isinstance(report.get("builds"), list) \
            or not isinstance(report.get("coverage"), dict):
        print("stdin is not `app-telemetry releases` output: expected an object with `builds` and `coverage`",
              file=sys.stderr)
        return 2
    arguments.into.mkdir(parents=True, exist_ok=True)
    recorded_at = datetime.datetime.now(datetime.UTC).isoformat(timespec="seconds")
    appended, unchanged = [], []
    for row in report["builds"]:
        path = arguments.into / f"{record_name(row['build'])}.jsonl"
        new = append_if_new(path, snapshot(row, report["coverage"], recorded_at))
        (appended if new else unchanged).append(path.name)
    print(json.dumps({"into": str(arguments.into), "appended": appended, "unchanged": unchanged}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
