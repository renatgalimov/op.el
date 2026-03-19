#!/usr/bin/env python3
"""Mock op CLI executor for testing.

Modes (via OP_MODE env var):
  mock   (default) - return saved fixture data from test/fixtures/
  real   - pass through to the real op binary
  verify - call real op, save output as fixtures, return output

OP_FIXTURE_DIR - override fixture directory (default: test/fixtures)
"""

import json
import logging
import os
import subprocess
import sys
import tempfile
from pathlib import Path

logging.basicConfig(
    level=os.environ.get("OP_LOG_LEVEL", "WARNING").upper(),
    format="op.py: %(levelname)s: %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger(__name__)

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent

MODE = os.environ.get("OP_MODE", "mock")
FIXTURE_DIR = Path(os.environ.get("OP_FIXTURE_DIR", PROJECT_DIR / "test" / "fixtures"))

GLOBAL_FLAGS = {"--config", "--encoding", "--session", "--cache", "--iso-timestamps"}


def extract_account(argv):
    """Extract --account value from argv, returning (account, remaining_argv)."""
    account = None
    remaining = []
    it = iter(argv)
    for arg in it:
        if arg == "--account":
            account = next(it, None)
        elif arg.startswith("--account="):
            account = arg.split("=", 1)[1]
        else:
            remaining.append(arg)
    return account, remaining


def strip_global_flags(argv):
    """Remove global op flags (--config, etc.) from argv for fixture lookup."""
    args = []
    it = iter(argv)
    for arg in it:
        if arg in GLOBAL_FLAGS:
            next(it, None)
        elif any(arg.startswith(f + "=") for f in GLOBAL_FLAGS):
            continue
        else:
            args.append(arg)
    return args


def args_to_suffix(args):
    """Turn remaining args/flags into a filename-safe suffix."""
    parts = []
    for a in args:
        parts.append(a.lstrip("-").replace("=", "-"))
    return "-".join(parts) if parts else ""


def fixture_path(argv):
    """Map op arguments to a fixture file path. Returns (path, stdin_data)."""
    account, argv_no_account = extract_account(argv)
    args = strip_global_flags(argv_no_account)
    log.debug("stripped args: %s (account=%s)", args, account)
    cmd = f"{args[0]}/{args[1]}" if len(args) >= 2 else ""
    rest = args[2:]  # everything after the subcommand
    stdin_data = None
    account_prefix = f"account-{account}-" if account else ""

    if cmd == "account/list":
        suffix = args_to_suffix(rest)
        name = "account-list"
        if suffix:
            name += f"-{suffix}"
        return FIXTURE_DIR / f"{name}.json", stdin_data

    if cmd == "item/list":
        suffix = args_to_suffix(rest)
        if not suffix:
            print("item list: need at least --tags", file=sys.stderr)
            sys.exit(1)
        return FIXTURE_DIR / f"{account_prefix}item-list-{suffix}.json", stdin_data

    if cmd == "item/get":
        item_id = rest[0] if rest else None
        if not item_id:
            print("item get: no id", file=sys.stderr)
            sys.exit(1)
        extra = args_to_suffix(rest[1:])
        ext = "json" if "--format" in args and "json" in args else "txt"
        if item_id == "-":
            stdin_data = sys.stdin.read()
            items = json.loads(stdin_data)
            titles = ",".join(sorted(i["title"] for i in items))
            name = f"item-get---{titles}"
        else:
            name = f"item-get-{item_id}"
        if extra:
            name += f"-{extra}"
        return FIXTURE_DIR / f"{account_prefix}{name}.{ext}", stdin_data

    if cmd.startswith("read/"):
        ref = args[1] if len(args) > 1 else None
        if not ref:
            print("read: no path", file=sys.stderr)
            sys.exit(1)
        ref = ref.removeprefix("op://").replace("/", "-").replace(":", "-")
        rest_suffix = args_to_suffix(args[2:])
        name = f"read-{ref}"
        if rest_suffix:
            name += f"-{rest_suffix}"
        return FIXTURE_DIR / f"{name}.txt", stdin_data

    print(f"op.py: unrecognized command: {' '.join(args)}", file=sys.stderr)
    sys.exit(1)


def mock(argv):
    log.info("mode=mock argv=%s", argv)
    fpath, _ = fixture_path(argv)
    log.info("fixture path: %s", fpath)
    errpath = fpath.with_suffix(".err")
    if errpath.exists():
        lines = errpath.read_text().splitlines(keepends=True)
        exit_code = int(lines[0].strip()) if lines else 1
        sys.stderr.writelines(lines[1:])
        sys.exit(exit_code)
    if fpath.exists():
        sys.stdout.write(fpath.read_text())
    else:
        print(
            f"Fixture not found: {fpath}\n"
            f"To generate it, run:\n"
            f"  OP_MODE=verify bin/op.py {' '.join(argv)}",
            file=sys.stderr,
        )
        sys.exit(1)


def real(argv):
    os.execvp("op", ["op"] + argv)


def verify(argv):
    log.info("mode=verify argv=%s", argv)
    FIXTURE_DIR.mkdir(parents=True, exist_ok=True)
    fpath, stdin_data = fixture_path(argv)
    log.info("fixture path: %s", fpath)
    if stdin_data:
        log.debug("stdin_data length: %d", len(stdin_data))
    errpath = fpath.with_suffix(".err")

    cmd = ["op"] + argv
    log.info("running: %s", cmd)
    result = subprocess.run(
        cmd,
        input=stdin_data,
        capture_output=True,
        text=True,
    )
    log.info("exit code: %d", result.returncode)
    if result.stderr:
        log.debug("stderr: %s", result.stderr[:200])

    if result.returncode == 0:
        fpath.write_text(result.stdout)
        errpath.unlink(missing_ok=True)
        sys.stdout.write(result.stdout)
    else:
        errpath.write_text(f"{result.returncode}\n{result.stderr}")
        fpath.unlink(missing_ok=True)
        sys.stderr.write(errpath.read_text())
        sys.exit(result.returncode)


def main():
    argv = sys.argv[1:]
    log.info("mode=%s argv=%s", MODE, argv)
    if MODE == "mock":
        mock(argv)
    elif MODE == "real":
        real(argv)
    elif MODE == "verify":
        verify(argv)
    else:
        print(f"op.py: unknown OP_MODE={MODE}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
