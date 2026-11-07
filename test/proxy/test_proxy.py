import http.client
import http.server
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest


HERE = Path(__file__).resolve().parent
MITMDUMP = os.environ.get("MITMDUMP", "mitmdump")


class Origin(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_GET(self):
        self.calls.append((self.command, self.path))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"local origin response")

    def do_POST(self):
        self.calls.append((self.command, self.path))
        self.send_response(201)
        self.end_headers()
        self.wfile.write(b"created")

    def log_message(self, format, *args):
        pass


class ProxyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        Origin.calls = []
        self.origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin)
        threading.Thread(target=self.origin.serve_forever, daemon=True).start()
        self.addCleanup(self.origin.server_close)
        self.addCleanup(self.origin.shutdown)

    def start_proxy(self, mode, recording=None, extra=()):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env = dict(os.environ, OP_PROXY_MODE=mode)
        if recording is not None:
            env["OP_PROXY_RECORDING"] = str(recording)
        proc = subprocess.Popen([MITMDUMP, "--listen-host", "127.0.0.1", "--listen-port", str(port), "--set", f"confdir={self.tmp.name}/mitm", "-s", str(HERE / "proxy.py"), *extra], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: (proc.terminate(), proc.wait(timeout=10)) if proc.poll() is None else None)
        self.proxy_process = proc
        for _ in range(200):
            if proc.poll() is not None:
                self.fail("mitmdump exited before becoming ready")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.1):
                    return port
            except OSError:
                time.sleep(.05)
        self.fail("mitmdump did not start")

    def request(self, port, method="GET", path="/item", body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        self.addCleanup(conn.close)
        conn.request(method, f"http://127.0.0.1:{self.origin.server_port}{path}", body=body, headers=headers or {})
        response = conn.getresponse()
        return response.status, response.read()

    def test_replay_serves_recorded_get_without_origin(self):
        recording = Path(self.tmp.name) / "local.mitm"
        forward = self.start_proxy("forward", extra=("-w", str(recording)))
        self.assertEqual(self.request(forward)[0], 200)
        self.proxy_process.terminate()
        self.proxy_process.wait(timeout=10)
        Origin.calls.clear()
        replay = self.start_proxy("replay", recording)
        self.assertEqual(self.request(replay), (200, b"local origin response"))
        self.assertEqual(Origin.calls, [])

    def test_replay_accepts_changed_timestamp_and_request_mac(self):
        recording = Path(self.tmp.name) / "local.mitm"
        forward = self.start_proxy("forward", extra=("-w", str(recording)))
        self.assertEqual(self.request(forward, path="/item?__t=1", headers={"X-AgileBits-MAC": "one", "X-First": "1", "X-Second": "2"})[0], 200)
        self.proxy_process.terminate()
        self.proxy_process.wait(timeout=10)
        Origin.calls.clear()
        replay = self.start_proxy("replay", recording)
        headers = {"x-second": "2", "x-first": "1", "X-AgileBits-MAC": "two"}
        self.assertEqual(self.request(replay, path="/item?__t=2", headers=headers), (200, b"local origin response"))
        self.assertEqual(self.request(replay, path="/item?__t=2&other=1", headers=headers)[0], 502)
        self.assertEqual(Origin.calls, [])

    def test_replay_refuses_missing_recording(self):
        try:
            self.start_proxy("replay", Path(self.tmp.name) / "missing.mitm")
        except AssertionError as exc:
            self.assertIn("exited before becoming ready", str(exc))
        self.assertNotEqual(self.proxy_process.wait(timeout=10), 0)
        self.assertEqual(Origin.calls, [])

    def test_replay_rejects_even_recorded_writes_and_unmatched_reads(self):
        recording = Path(self.tmp.name) / "local.mitm"
        forward = self.start_proxy("forward", extra=("-w", str(recording)))
        self.assertEqual(self.request(forward)[0], 200)
        self.assertEqual(self.request(forward, "POST", body=b"original")[0], 201)
        self.proxy_process.terminate()
        self.proxy_process.wait(timeout=10)
        Origin.calls.clear()
        replay = self.start_proxy("replay", recording)
        self.assertEqual(self.request(replay, "POST", body=b"original")[0], 502)
        self.assertEqual(self.request(replay, "POST", body=b"changed")[0], 502)
        self.assertEqual(self.request(replay, path="/unrecorded")[0], 502)
        self.assertEqual(self.request(replay, headers={"Authorization": "different"})[0], 502)
        self.assertEqual(self.request(replay), (200, b"local origin response"))
        self.assertEqual(Origin.calls, [])

    def test_forward_reaches_real_local_origin(self):
        port = self.start_proxy("forward")
        self.assertEqual(self.request(port), (200, b"local origin response"))
        self.assertEqual(Origin.calls, [("GET", "/item")])


if __name__ == "__main__":
    unittest.main()
