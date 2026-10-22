#!/usr/bin/env python3
"""Give one source-transfer process the descriptor limit its host supports."""

import os
import resource
import subprocess
import sys

from build_support import source_sync_command


def transfer_limit(soft, hard, host_max):
    maximum = min(65536, host_max)
    if hard != resource.RLIM_INFINITY:
        maximum = min(maximum, hard)
    return max(soft, maximum)


def main():
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    host_max = int(
        subprocess.check_output(["sysctl", "-n", "kern.maxfilesperproc"], text=True)
    )
    requested = transfer_limit(soft, hard, host_max)
    if requested > soft:
        resource.setrlimit(resource.RLIMIT_NOFILE, (requested, hard))
    arguments = sys.argv[1:]
    if arguments[:1] == ["sync"]:
        command = source_sync_command(arguments[1:])
    else:
        command = ["rsync", *arguments]
    os.execvp(command[0], command)


if __name__ == "__main__":
    main()
