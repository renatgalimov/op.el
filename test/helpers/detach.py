#!/usr/bin/env python3
"""Run a command outside the caller's process tree, for authorization tests.

Forks, lets the parent exit so the child is reparented to init, then runs the
command and writes its output and exit code to a file.  Used to prove op-shim
refuses callers that do not descend from Emacs.
"""

import os
import subprocess
import sys
import time

REPARENT_TIMEOUT_SECONDS = 5


def main():
    output_path, command = sys.argv[1], sys.argv[2:]
    if os.fork():
        os._exit(0)
    os.setsid()
    deadline = time.time() + REPARENT_TIMEOUT_SECONDS
    while os.getppid() != 1 and time.time() < deadline:
        time.sleep(0.01)
    finished = subprocess.run(command, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    with open(output_path, "wb") as output:
        output.write(finished.stdout)
        output.write(b"\nEXIT:%d\n" % finished.returncode)


if __name__ == "__main__":
    main()
