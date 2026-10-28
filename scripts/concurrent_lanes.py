#!/usr/bin/env python3
"""Run named command lanes concurrently, prefixing their output and failing fast."""

import argparse
import re
import shlex
import subprocess
import sys
import threading
import time
from pathlib import Path

LANE_PREFIXES = re.compile(r"^((?:\[[a-z][a-z-]*\] )*)(.*)$")


def lane_streams(text):
    streams = {}
    for line in text.splitlines():
        prefix, content = LANE_PREFIXES.match(line).groups()
        streams.setdefault(prefix, []).append(content + "\n")
    return ["".join(lines) for lines in streams.values()]


def run_lanes(lanes, cwd, record=lambda *_: None, output=None):
    output = output or sys.stdout.buffer
    write_lock = threading.Lock()
    state_lock = threading.Lock()
    muted = threading.Event()
    finished = threading.Semaphore(0)
    running = {}
    failure = []

    def emit(prefix, line):
        with write_lock:
            if not muted.is_set():
                output.write(prefix + line)
                output.flush()

    def fail(prefix, status, message):
        if not failure:
            failure.append(status)
            emit(prefix, message.encode())
            for other in running.values():
                other.terminate()

    def run_steps(name, prefix, steps):
        for step, command in steps:
            with state_lock:
                if failure:
                    return
                started = time.monotonic()
                process = subprocess.Popen(
                    command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
                )
                running[name] = process
            with process:
                for line in iter(process.stdout.readline, b""):
                    emit(prefix, line if line.endswith(b"\n") else line + b"\n")
                status = process.wait()
            with state_lock:
                del running[name]
                if failure:
                    return
                record(step, round(time.monotonic() - started, 3), status)
                if status:
                    fail(prefix, status, f"{step} failed with exit status {status}\n")
                    return

    def lane(name, steps):
        prefix = f"[{name}] ".encode()
        try:
            run_steps(name, prefix, steps)
        except Exception as error:
            with state_lock:
                running.pop(name, None)
                fail(prefix, 1, f"lane stopped: {error}\n")
        finally:
            finished.release()

    for item in lanes.items():
        threading.Thread(target=lane, args=item, daemon=True).start()
    for _ in lanes:
        finished.acquire()
        with state_lock:
            if failure:
                break
    with write_lock:
        muted.set()
    return failure[0] if failure else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--lane",
        nargs="+",
        action="append",
        required=True,
        metavar=("NAME", "COMMAND"),
        help="a lane name followed by shell-quoted commands run in order",
    )
    lanes = {}
    for name, *commands in parser.parse_args().lane:
        if name in lanes or not commands:
            parser.error(f"lane {name} must be unique and have at least one command")
        lanes[name] = [(command, shlex.split(command)) for command in commands]
    return run_lanes(lanes, Path.cwd())


if __name__ == "__main__":
    raise SystemExit(main())
