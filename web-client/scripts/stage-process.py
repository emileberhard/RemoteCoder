import os
import select
import signal
import subprocess
import sys
import time


limit = float(sys.argv[1])
lock_fd = int(sys.argv[2])
command = sys.argv[3:]
CONTROLLER_CLOSED = 125
interrupted = False


def interrupt(signum, frame):
    global interrupted
    interrupted = True


for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
    signal.signal(signum, interrupt)

process = subprocess.Popen(command, stdin=subprocess.DEVNULL, start_new_session=True, pass_fds=(lock_fd,))
deadline = time.monotonic() + limit
failed = False
controller_closed = False


def group_exists():
    process.poll()
    try:
        os.killpg(process.pid, 0)
        return True
    except ProcessLookupError:
        return False


def signal_group(signum):
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


try:
    while process.poll() is None:
        if interrupted:
            failed = True
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print(f"Staging command exceeded {limit:g} seconds", file=sys.stderr)
            failed = True
            break
        ready, _, _ = select.select([sys.stdin], [], [], min(remaining, 0.25))
        if ready and not os.read(sys.stdin.fileno(), 1):
            failed = True
            controller_closed = True
            break
    if interrupted:
        failed = True
    if process.poll() is not None and group_exists():
        print("Staging command left processes running", file=sys.stderr)
        failed = True
finally:
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, signal.SIG_IGN)
    if group_exists():
        signal_group(signal.SIGTERM)
        grace = time.monotonic() + 1
        while group_exists() and time.monotonic() < grace:
            time.sleep(0.05)
        if group_exists():
            signal_group(signal.SIGKILL)
            report_at = time.monotonic() + 10
            reported = False
            while group_exists():
                if not reported and time.monotonic() >= report_at:
                    print("Staging process group has not retired; the staging lock remains held", file=sys.stderr)
                    reported = True
                time.sleep(0.05)
    process.wait()
if controller_closed and not interrupted:
    sys.exit(CONTROLLER_CLOSED)
if failed or process.returncode == CONTROLLER_CLOSED:
    sys.exit(1)
sys.exit(process.returncode if process.returncode >= 0 else 128 - process.returncode)
