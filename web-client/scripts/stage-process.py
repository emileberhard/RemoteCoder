import os
import select
import signal
import subprocess
import sys
import time


limit = float(sys.argv[1])
command = sys.argv[2:]
process = subprocess.Popen(command, stdin=subprocess.DEVNULL, start_new_session=True)
deadline = time.monotonic() + limit
try:
    while process.poll() is None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print(f"Staging command exceeded {limit:g} seconds", file=sys.stderr)
            break
        ready, _, _ = select.select([sys.stdin], [], [], min(remaining, 0.25))
        if ready and not os.read(sys.stdin.fileno(), 1):
            break
finally:
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
sys.exit(process.returncode if process.returncode >= 0 else 1)
