import argparse
import json
import math
import os
import select
import signal
import socket
import subprocess
import sys
import time
from datetime import datetime
from contextlib import ExitStack
from pathlib import Path
from uuid import uuid4

from build_cache import lease_path, touch_usage
from build_hosts import MAC_GUI_HOST, is_local
from build_support import (
    MAX_MEASUREMENT_SECONDS,
    atomic_json,
    cache_root,
    connected_cancellation,
    file_lease,
    measurement_capacity,
    measurement_actor_path,
    measurement_record_lease,
    run_connected,
    run_owned,
)
from process_group import (
    group_has_live_members,
    own_identity,
    audit_alive,
    terminate_group,
)


def reserve(source: Path, hold_seconds: float, command: list[str]) -> int:
    if (
        not math.isfinite(hold_seconds)
        or not 0 < hold_seconds <= MAX_MEASUREMENT_SECONDS
    ):
        raise ValueError(
            f"Measurement hold must be finite, positive, and at most {MAX_MEASUREMENT_SECONDS} seconds"
        )
    root = cache_root()
    identity = "measurement-" + uuid4().hex
    run = root / "runs" / identity
    run.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    receipt = {
        "kind": "measurement-reservation",
        "runId": identity,
        "source": str(source.resolve()),
        "ownerPid": os.getpid(),
        "outputDirectory": str(run),
        "queuedAt": datetime.now().astimezone().isoformat(),
        "queueLimitSeconds": MAX_MEASUREMENT_SECONDS,
        "holdLimitSeconds": hold_seconds,
        "exitCode": None,
    }
    with (
        connected_cancellation() as cancellation,
        file_lease(lease_path(root, "runs", identity)) as run_fd,
    ):
        cancelled = None

        def cancel(signum, _frame):
            nonlocal cancelled
            cancelled = signum
            cancellation.set()

        previous = {
            signum: signal.signal(signum, cancel)
            for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
        }
        try:
            run.mkdir()
            touch_usage(root, "runs", identity)
            atomic_json(run / "receipt.json", receipt)
            print(
                f"Measurement reservation {identity}: {run / 'receipt.json'}",
                file=sys.stderr,
                flush=True,
            )
            with measurement_capacity(
                source, MAX_MEASUREMENT_SECONDS, cancellation
            ) as capacity:
                receipt["queueWaitSeconds"] = round(time.monotonic() - started, 3)
                receipt["acquiredAt"] = datetime.now().astimezone().isoformat()
                receipt["reservationRecord"] = str(capacity.record)
                with measurement_record_lease(capacity.record):
                    holder = json.loads(capacity.record.read_text())
                    if time.monotonic() >= holder["deadline"]:
                        raise TimeoutError(
                            "Measurement queue deadline expired before activation"
                        )
                    holder["deadline"] = time.monotonic() + hold_seconds + 30
                    atomic_json(capacity.record, holder)
                atomic_json(run / "receipt.json", receipt)
                environment = os.environ | {
                    "RC_MEASUREMENT_RECEIPT": str(run / "receipt.json")
                }
                result_path = run / "command-result.json"
                try:
                    sender, receiver = socket.socketpair()
                    with sender, receiver:
                        sender.settimeout(
                            max(0.01, holder["deadline"] - time.monotonic())
                        )

                        def prepare(child):
                            receiver.close()
                            while not select.select([sender], [], [], 0.05)[0]:
                                if cancellation.is_set():
                                    child.kill()
                                    raise SystemExit(128 + (cancelled or signal.SIGHUP))
                                if time.monotonic() >= holder["deadline"]:
                                    child.kill()
                                    raise TimeoutError(
                                        "Guard registration exceeded its deadline"
                                    )
                            if sender.recv(1) != b".":
                                raise ValueError(
                                    "Guard exited before lease registration"
                                )
                            registered = json.loads(capacity.record.read_text())[
                                "guard"
                            ]
                            if (
                                registered is None
                                or registered["pid"] != child.pid
                                or not audit_alive(registered)
                            ):
                                raise ValueError(
                                    "Guard identity was not registered before lease handoff"
                                )
                            socket.send_fds(
                                sender, [b"."], [run_fd, *capacity.descriptors]
                            )

                        result = run_connected(
                            [
                                sys.executable,
                                str(Path(__file__).resolve()),
                                "_guard",
                                "--source",
                                str(source),
                                "--hold-seconds",
                                str(hold_seconds),
                                "--result",
                                str(result_path),
                                "--record",
                                str(capacity.record),
                                "--control-fd",
                                str(receiver.fileno()),
                                "--",
                                *command,
                            ],
                            environment=environment,
                            lease_fds=(receiver.fileno(),),
                            cancellation=cancellation,
                            prepare=prepare,
                        )
                    print(result.stdout, end="", flush=True)
                    command_result = json.loads(result_path.read_text())
                    if command_result["exitCode"] != result.returncode:
                        raise ValueError(
                            "Measurement command guard and result disagree"
                        )
                    receipt.update(command_result)
                finally:
                    holder = json.loads(capacity.record.read_text())
                    receipt["commandIdentity"] = holder["command"]
                    receipt["deadlineMonotonic"] = holder["deadline"]
                    if holder["command"] is not None:
                        terminate_group(holder["command"], 30)
        except (
            OSError,
            ValueError,
            subprocess.SubprocessError,
            SystemExit,
            KeyboardInterrupt,
        ) as error:
            receipt["exitCode"] = (
                128 + cancelled
                if cancelled is not None
                else error.code
                if isinstance(error, SystemExit) and type(error.code) is int
                else 124
                if isinstance(error, (TimeoutError, subprocess.TimeoutExpired))
                else 1
            )
            receipt["errorType"] = type(error).__name__
            print(
                f"Measurement ended: {type(error).__name__}; see {run / 'receipt.json'}",
                file=sys.stderr,
            )
        finally:
            for signum in previous:
                signal.signal(signum, signal.SIG_IGN)
            try:
                if receipt["exitCode"] is None:
                    receipt["exitCode"] = 1
                    receipt["errorType"] = type(sys.exception()).__name__
                receipt["releasedAt"] = datetime.now().astimezone().isoformat()
                receipt.setdefault(
                    "queueWaitSeconds", round(time.monotonic() - started, 3)
                )
                touch_usage(root, "runs", identity)
                atomic_json(run / "receipt.json", receipt)
            finally:
                for signum, handler in previous.items():
                    signal.signal(signum, handler)
    return receipt["exitCode"]


def _guard(
    source: Path,
    hold_seconds: float,
    result_path: Path,
    record_path: Path,
    command: list[str],
    control: socket.socket | None = None,
) -> int:
    result = {"exitCode": None}
    with connected_cancellation() as cancellation, ExitStack() as leases:
        try:
            registration = {
                "identity": own_identity(),
                "deadline": json.loads(record_path.read_text())["deadline"],
            }
            atomic_json(measurement_actor_path(record_path, "guard"), registration)
            with measurement_record_lease(record_path):
                holder = json.loads(record_path.read_text())
                if time.monotonic() >= registration["deadline"]:
                    raise TimeoutError("Guard registration exceeded its deadline")
                holder["guard"] = registration["identity"]
                atomic_json(record_path, holder)
            if control is not None:
                control.sendall(b".")
                message, descriptors, _, _ = socket.recv_fds(control, 1, 16)
                for descriptor in descriptors:
                    leases.callback(os.close, descriptor)
                if message != b"." or not descriptors:
                    raise ValueError("Guard lost its supervisor before lease handoff")
            result["exitCode"] = run_owned(
                [
                    sys.executable,
                    str(Path(__file__).resolve()),
                    "_command",
                    "--record",
                    str(record_path),
                    "--",
                    *command,
                ],
                source,
                os.environ,
                sys.stdout,
                cancellation=cancellation,
                timeout_seconds=hold_seconds,
                termination_grace_seconds=30,
                error_output=sys.stderr,
            )
        except BaseException as error:
            result["exitCode"] = (
                error.code
                if isinstance(error, SystemExit) and type(error.code) is int
                else 124
                if isinstance(error, subprocess.TimeoutExpired)
                else 1
            )
            result["errorType"] = type(error).__name__
        finally:
            holder = json.loads(record_path.read_text())
            if (
                (
                    result["exitCode"] == 128 + signal.SIGKILL
                    or result.get("errorType") == "TimeoutExpired"
                )
                and "completedStatus" in holder
                and holder["completedAt"] <= holder["deadline"] - 30
            ):
                result = {"exitCode": holder["completedStatus"]}
            atomic_json(result_path, result)
    return result["exitCode"]


def _guard_main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--hold-seconds", type=float, required=True)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--record", type=Path, required=True)
    parser.add_argument("--control-fd", type=int, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(sys.argv[2:])
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    with socket.socket(fileno=args.control_fd) as control:
        raise SystemExit(
            _guard(
                args.source,
                args.hold_seconds,
                args.result,
                args.record,
                command,
                control,
            )
        )


def _command_main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--record", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(sys.argv[2:])
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    registration = {
        "identity": own_identity(),
        "deadline": json.loads(args.record.read_text())["deadline"],
    }
    atomic_json(measurement_actor_path(args.record, "command"), registration)
    with measurement_record_lease(args.record):
        holder = json.loads(args.record.read_text())
        if not audit_alive(holder["guard"]) or time.monotonic() >= holder["deadline"]:
            raise SystemExit(1)
        holder["command"] = registration["identity"]
        if holder["command"]["pgid"] != os.getpid():
            raise ValueError("Measurement command must own its process group")
        atomic_json(args.record, holder)
    if not audit_alive(holder["guard"]) or time.monotonic() >= holder["deadline"]:
        raise SystemExit(1)
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, lambda *_: None)
    with subprocess.Popen(command, stdin=subprocess.DEVNULL) as child:
        os.close(1)
        status = child.wait()
    status = 128 - status if status < 0 else status
    holder["completedStatus"] = status
    holder["completedAt"] = time.monotonic()
    with measurement_record_lease(args.record):
        atomic_json(args.record, holder)
    if group_has_live_members(os.getpgrp(), os.getpid()):
        os.killpg(os.getpgrp(), signal.SIGTERM)
    deadline = time.monotonic() + 30
    while group_has_live_members(os.getpgrp(), os.getpid()):
        if time.monotonic() >= deadline:
            os.killpg(os.getpgrp(), signal.SIGKILL)
        time.sleep(0.05)
    raise SystemExit(status)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--hold-seconds", type=float, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not is_local(MAC_GUI_HOST):
        parser.error(f"Measurements require {MAC_GUI_HOST}")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a measured command is required")
    raise SystemExit(reserve(args.source, args.hold_seconds, command))


if __name__ == "__main__":
    if sys.argv[1:2] == ["_guard"]:
        _guard_main()
    elif sys.argv[1:2] == ["_command"]:
        _command_main()
    else:
        main()
