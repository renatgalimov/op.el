import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


class LiveRunnerSafetyTests(unittest.TestCase):
    def test_timeout_stops_child_processes_before_returning(self):
        spec = importlib.util.spec_from_file_location("live_runner", Path(__file__).with_name("run-live.py"))
        assert spec is not None and spec.loader is not None
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "child-ran"
            child = "import pathlib,time; time.sleep(2); pathlib.Path(%r).touch()" % str(marker)
            parent = "import subprocess,sys,time; subprocess.Popen([sys.executable, '-c', %r]); time.sleep(30)" % child
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.run_suite([sys.executable, "-c", parent], os.environ.copy(), timeout=0.5)
            time.sleep(2.5)
            self.assertFalse(marker.exists())

    def test_refuses_non_loopback_proxy_before_invoking_op(self):
        env = dict(os.environ, HTTPS_PROXY="http://proxy.example:8080", https_proxy="http://proxy.example:8080", NO_PROXY="", no_proxy="")
        runner = Path(__file__).with_name("run-live.py")
        result = subprocess.run([sys.executable, str(runner)], env=env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("loopback", result.stderr)


if __name__ == "__main__":
    unittest.main()
