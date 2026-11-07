#!/usr/bin/env python3
"""Run the integration suite against disposable data through mitmproxy."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
from typing import Any
import uuid
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
SECRET = "fixture-only-not-a-secret"


class AmbiguousCreationError(RuntimeError):
    """A create request may have succeeded despite a failed response."""


def check_proxy():
    upper, lower = os.getenv("HTTPS_PROXY"), os.getenv("https_proxy")
    proxy = upper or lower
    if not proxy or (upper and lower and upper != lower):
        raise RuntimeError("Configure one loopback HTTPS proxy in both proxy variables")
    parsed = urlsplit(proxy)
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "::1", "localhost"} or not parsed.port or parsed.path not in {"", "/"} or parsed.username or parsed.query or parsed.fragment:
        raise RuntimeError("The HTTPS proxy must be a loopback HTTP proxy")
    if os.getenv("NO_PROXY") or os.getenv("no_proxy"):
        raise RuntimeError("Clear NO_PROXY and no_proxy so traffic cannot bypass the loopback proxy")
    probe = subprocess.run(["curl", "--silent", "--show-error", "--fail", "--max-time", "3", "--proxy", proxy, "--noproxy", "", "http://mitm.it/"], capture_output=True)
    if probe.returncode or b"<title>mitmproxy</title>" not in probe.stdout:
        raise RuntimeError("The loopback proxy did not identify itself as mitmproxy")
    if not os.getenv("SSL_CERT_FILE") or not Path(os.environ["SSL_CERT_FILE"]).is_file():
        raise RuntimeError("Set SSL_CERT_FILE to the mitmproxy CA certificate")


def op(*args: str, parse: bool = True, input_data: bytes | None = None) -> Any:
    if not args:
        raise ValueError("An op command is required")
    creating = len(args) > 1 and args[1] == "create"
    try:
        p = subprocess.run(["op", "--no-color", *args], input=input_data, stdin=subprocess.DEVNULL if input_data is None else None, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90)
    except subprocess.TimeoutExpired as exc:
        error = AmbiguousCreationError if creating else RuntimeError
        raise error(f"op {args[0]} timed out; details suppressed") from exc
    if p.returncode:
        error = AmbiguousCreationError if creating else RuntimeError
        raise error(f"op {args[0]} failed (exit {p.returncode}); details suppressed")
    try:
        response = json.loads(p.stdout) if parse and p.stdout.strip() else None
    except ValueError as exc:
        if creating:
            raise AmbiguousCreationError(f"op {args[0]} returned invalid output") from exc
        raise
    if creating and (not isinstance(response, dict) or not response.get("id")):
        raise AmbiguousCreationError(f"op {args[0]} returned no identifier")
    return response


def run():
    check_proxy()
    account = op("whoami", "--format=json")["account_uuid"]
    suffix = uuid.uuid4().hex[:16]
    vault_name = "op-el-test-" + suffix
    tag = "opeltest" + suffix
    vault_id = None
    creation_attempted = False
    cleanup_safe = True
    item_ids = []
    result = 1
    try:
        creation_attempted = True
        vault_id = op("vault", "create", vault_name, "--format=json")["id"]
        print(f"Disposable vault created: {vault_name} ({vault_id})", file=sys.stderr, flush=True)
        for index, title in enumerate(("op-el-test", "op-el-test-duplicate", "op-el-Production/with slash", "op-el-test", "--reveal")):
            template = {"title": title, "category": "LOGIN", "tags": [tag] if index < 2 else [], "fields": [
                {"id": "username", "type": "STRING", "purpose": "USERNAME", "label": "username", "value": "fixture@example.invalid"},
                {"id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password", "value": SECRET},
                {"id": "host", "type": "STRING", "label": "host", "value": "fixture.invalid"},
                {"id": "port", "type": "STRING", "label": "port", "value": "993"}]}
            if index == 4:
                template["sections"] = [{"id": "demosection", "label": "Demo Section"}]
                template["fields"].append({"id": "api_key", "type": "CONCEALED", "label": "api/token", "section": {"id": "demosection"}, "value": SECRET})
            item = op("item", "create", "--vault", vault_id, "--format=json", "-", input_data=json.dumps(template).encode())
            item_ids.append(item["id"])
            if op("item", "get", item["id"], "--vault", vault_id, "--format=json").get("title") != title:
                raise RuntimeError("Created item did not read back correctly")
        env = dict(os.environ, OP_TEST_VAULT_ID=vault_id, OP_TEST_ITEM_ID=item_ids[0], OP_TEST_COMPLETION_ITEM_ID=item_ids[2], OP_TEST_DUPLICATE_TITLE_ID=item_ids[3], OP_AUTH_TEST_ACCOUNT=account, OP_AUTH_TEST_VAULT=vault_id, OP_AUTH_TEST_ITEM=item_ids[0], OP_AUTH_TEST_DUPLICATE_ITEM=item_ids[1], OP_AUTH_TEST_TAG=tag, OP_AUTH_TEST_HOST="fixture.invalid", OP_AUTH_TEST_USER="fixture@example.invalid", OP_AUTH_TEST_PORT="993", OP_AUTH_TEST_SECRET=SECRET)
        cleanup_safe = False
        try:
            tests = run_suite(["make", "test"], env, timeout=300)
        except subprocess.TimeoutExpired:
            raise RuntimeError("Live test suite timed out; its descendants may still be running")
        cleanup_safe = True
        output = tests.stdout.decode(errors="replace")
        output = re.sub(r"\x1b\[[0-9;]*m", "", output)
        summaries = re.findall(r"Ran (\d+)(?: out of (\d+))? specs, (\d+) failed[^\n]*", output)
        if tests.returncode or not summaries or summaries[-1][1] or summaries[-1][2] != "0":
            fd, log = tempfile.mkstemp(prefix="op-el-live-test-", suffix=".log")
            with os.fdopen(fd, "wb") as f:
                f.write(tests.stdout)
            raise RuntimeError(f"Live suite failed or skipped specs; private diagnostic log: {log}")
        print(f"Live suite: {summaries[-1][0]} specs passed, none skipped")
        result = 0
    except (AmbiguousCreationError, KeyboardInterrupt):
        cleanup_safe = False
        raise
    finally:
        if creation_attempted and not vault_id:
            print(f"Vault creation outcome unknown; inspect the disposable account for {vault_name}", file=sys.stderr)
        if vault_id and not cleanup_safe:
            print(f"Vault retained for safe manual cleanup after stopping test processes: {vault_name} ({vault_id})", file=sys.stderr)
        if vault_id and cleanup_safe:
            try:
                items = op("item", "list", "--vault", vault_id, "--format=json")
                remaining = {item["id"] for item in items}
                def owned(item):
                    return item["id"] in item_ids or (
                        tag in item.get("tags", []) and
                        (item.get("title") in {"op-el-test", "op-el-test-duplicate"} or
                         re.fullmatch(r"op-el-[0-9]+-[a-z0-9]{16}\.invalid", item.get("title", ""))))
                if not all(owned(item) for item in items):
                    raise RuntimeError("Vault has unexpected items; refusing to delete it")
                for item_id in remaining:
                    op("item", "delete", item_id, "--vault", vault_id, parse=False)
                if op("item", "list", "--vault", vault_id, "--format=json"):
                    raise RuntimeError("Vault is not empty after item deletion")
                op("vault", "delete", vault_id, parse=False)
                if any(v["id"] == vault_id for v in op("vault", "list", "--format=json")):
                    raise RuntimeError("Vault remains after deletion")
                print("Disposable vault and items removed and verified absent")
            except Exception as exc:
                print(f"Cleanup failed for disposable vault {vault_name} ({vault_id}): {exc}", file=sys.stderr)
                result = 1
    return result


def run_suite(command, env, timeout):
    """Stop the test process group on timeout or interruption."""
    process = subprocess.Popen(command, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
        if process.stdout:
            process.stdout.close()
        raise
    return subprocess.CompletedProcess(command, process.returncode, output)


if __name__ == "__main__":
    try:
        sys.exit(run())
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
        print(f"Live test error: {exc}", file=sys.stderr)
        sys.exit(1)
