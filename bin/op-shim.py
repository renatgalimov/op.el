#!/usr/bin/env python3
"""Forward an op invocation to the authenticated PTY that Emacs keeps open.

1Password CLI caches its biometric session per terminal, so op invoked from an
Emacs vterm gets a fresh terminal and prompts for a fingerprint.  Installed as
`op' on PATH for Emacs's children, this forwards the call over a unix socket to
op.el, which runs it in a terminal that is already authenticated.

Commands that need the caller's own terminal are not forwarded; they exec the
real op instead.  stdout comes back through a file rather than the socket
because op can emit arbitrary bytes.
"""

import json
import os
import shutil
import socket
import sys
import tempfile

# Subcommands that must run in the caller's terminal: they spawn a child
# process, or prompt for input that only the caller can supply.
PASSTHROUGH_SUBCOMMANDS = {"run", "plugin", "signin", "signout", "update"}
PASSTHROUGH_PAIRS = {("account", "add"), ("account", "forget")}
GLOBAL_FLAGS_WITH_VALUE = {"--account", "--config", "--encoding", "--session", "--cache"}
RESPONSE_LIMIT_BYTES = 1 << 20


def main(argv):
    if should_passthrough(argv):
        exec_real_op(argv)
    socket_path = os.environ.get("OP_SHIM_SOCKET")
    if not socket_path or not os.path.exists(socket_path):
        exec_real_op(argv)
    return forward(argv, socket_path)


def should_passthrough(argv):
    """Return whether ARGV must run against the caller's own terminal."""
    if os.environ.get("OP_SHIM_DISABLE"):
        return True
    subcommand, rest = split_subcommand(argv)
    if subcommand is None:
        return True
    if subcommand in PASSTHROUGH_SUBCOMMANDS:
        return True
    following, _ = split_subcommand(rest)
    return (subcommand, following) in PASSTHROUGH_PAIRS


def split_subcommand(argv):
    """Return the first subcommand in ARGV and the arguments after it.

    Skips global flags and the values they consume, so `op --account X item
    get' reports `item' rather than `X'.
    """
    index = 0
    while index < len(argv):
        token = argv[index]
        if token in GLOBAL_FLAGS_WITH_VALUE:
            index += 2
        elif token.startswith("-"):
            index += 1
        else:
            return token, argv[index + 1:]
    return None, []


def exec_real_op(argv):
    """Replace this process with the real op CLI."""
    executable = os.environ.get("OP_SHIM_REAL_OP") or find_real_op()
    if not executable:
        sys.stderr.write("op-shim: cannot find the real op executable\n")
        raise SystemExit(127)
    os.execv(executable, [executable] + argv)


def find_real_op():
    """Return the path of the op CLI, ignoring this shim's own directory."""
    own_directory = os.path.dirname(os.path.abspath(sys.argv[0]))
    directories = [entry for entry in os.environ.get("PATH", "").split(os.pathsep)
                   if entry and os.path.abspath(entry) != own_directory]
    return shutil.which("op", path=os.pathsep.join(directories))


def forward(argv, socket_path):
    """Run ARGV through the Emacs PTY and reproduce its output locally."""
    workspace = tempfile.mkdtemp(prefix="op-shim-")
    try:
        stdout_path = os.path.join(workspace, "stdout")
        open(stdout_path, "wb").close()
        os.chmod(stdout_path, 0o600)
        request = {"cwd": os.getcwd(), "argv": argv, "stdout": stdout_path,
                   "stdin": write_stdin(workspace)}
        response = exchange(socket_path, request)
        if "error" in response:
            sys.stderr.write("op-shim: %s\n" % response["error"])
            return 1
        with open(stdout_path, "rb") as stdout_file:
            shutil.copyfileobj(stdout_file, sys.stdout.buffer)
        sys.stdout.buffer.flush()
        sys.stderr.write(response.get("stderr", ""))
        return response["exit_code"]
    finally:
        shutil.rmtree(workspace, ignore_errors=True)


def write_stdin(workspace):
    """Spool piped stdin to a file, or return None when stdin is a terminal."""
    if sys.stdin.isatty():
        return None
    data = sys.stdin.buffer.read()
    if not data:
        return None
    stdin_path = os.path.join(workspace, "stdin")
    with open(os.open(stdin_path, os.O_WRONLY | os.O_CREAT, 0o600), "wb") as stdin_file:
        stdin_file.write(data)
    return stdin_path


def exchange(socket_path, request):
    """Send REQUEST as one JSON line and return the decoded reply."""
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.connect(socket_path)
        # No shutdown(SHUT_WR) here: Emacs treats a half-closed connection as
        # finished and deletes it, so the reply would never arrive.  The
        # request is newline-delimited, so the server does not need EOF.
        connection.sendall(json.dumps(request).encode("utf-8") + b"\n")
        reply = b""
        while b"\n" not in reply and len(reply) < RESPONSE_LIMIT_BYTES:
            chunk = connection.recv(4096)
            if not chunk:
                break
            reply += chunk
    finally:
        connection.close()
    if not reply.strip():
        return {"error": "no response from Emacs"}
    return json.loads(reply.split(b"\n")[0].decode("utf-8"))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
