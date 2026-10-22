#!/usr/bin/env python3
"""Check this Mac's memory pressure before a heavy build, or sample pressure, free memory and swap while one runs."""

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import UTC, datetime

PRESSURE_LEVELS = {1: "normal", 2: "warn", 4: "critical"}


def swap_used_mb() -> float:
    usage = subprocess.check_output(["sysctl", "-n", "vm.swapusage"], text=True)
    used = re.search(r"\bused = ([0-9]+(?:\.[0-9]+)?)M\b", usage)
    if used is None:
        raise RuntimeError(f"Unrecognized vm.swapusage: {usage.strip()}")
    return float(used[1])


def free_memory_percent() -> int:
    return int(subprocess.check_output(["sysctl", "-n", "kern.memorystatus_level"], text=True))


def pressure() -> str:
    level = subprocess.check_output(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], text=True).strip()
    if not level.isdigit() or int(level) not in PRESSURE_LEVELS:
        raise RuntimeError(f"Unrecognized kern.memorystatus_vm_pressure_level: {level}")
    return PRESSURE_LEVELS[int(level)]


def check() -> None:
    level = pressure()
    if level != "normal":
        raise SystemExit(
            f"Memory pressure is {level}. Stop stale processes before a heavy build (largest compressed first: "
            "top -l 1 -o cmprs -n 10), then re-run."
        )
    print(f"Memory pressure is normal: {free_memory_percent()}% free, {swap_used_mb() / 1024:.1f} GB swap in use.")


def sample(every: float) -> None:
    while True:
        print(
            json.dumps(
                {
                    "at": datetime.now(UTC).isoformat(timespec="seconds"),
                    "pressure": pressure(),
                    "swapUsedMB": swap_used_mb(),
                    "freeMemoryPercent": free_memory_percent(),
                }
            ),
            flush=True,
        )
        time.sleep(every)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    operations = parser.add_subparsers(dest="operation", required=True)
    operations.add_parser("check", help="fail unless memory pressure is normal")
    sampling = operations.add_parser("sample", help="print one JSON line per interval until interrupted")
    sampling.add_argument("--every", type=float, default=30, metavar="SECONDS")
    args = parser.parse_args()
    if args.operation == "check":
        check()
    else:
        sample(args.every)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
