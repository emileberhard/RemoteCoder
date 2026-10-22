#!/usr/bin/env python3
"""Admit a fork build without discarding reusable compiler artifacts."""

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_support import require_build_space

# A measured full workspace produces 77k entries; the warm shared target had
# 107k at this change. Leave room for multiple configurations, not just one pass.
MAX_DEPS_ENTRIES = 250000


def check_cache(target: Path):
    require_build_space(target.parent)
    directories = [*target.glob("*/deps"), *target.glob("*/*/deps")]
    for deps in directories:
        with os.scandir(deps) as entries:
            count = sum(1 for _ in entries)
        if count > MAX_DEPS_ENTRIES:
            raise ValueError(
                f"Fork cache has {count} entries in {deps}, above {MAX_DEPS_ENTRIES}; retire owned stale artifacts under its lease before retrying. Cache preserved."
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=Path)
    args = parser.parse_args()
    if args.target.name != "target" or args.target.is_symlink():
        parser.error("expected the owned, non-symlink fork target directory")
    check_cache(args.target)
    args.target.mkdir(parents=True, exist_ok=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
